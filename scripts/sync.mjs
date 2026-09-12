import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import {
  cpSync,
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  checkSchemaSnapshot,
  schemaContract,
  writeSchemaSnapshot,
} from "./schema-snapshot.mjs";

const repository = "github/copilot-sdk";
const ref = "main";
const schemaNames = ["api.schema.json", "session-events.schema.json"];
const root = dirname(dirname(fileURLToPath(import.meta.url)));
const vendorDirectory = join(root, "vendor", "copilot");
const schemaDirectory = join(vendorDirectory, "schemas");
const metadataPath = join(vendorDirectory, "upstream.json");
const generatedPath = join(root, "src", "protocol_version.zig");
const compatibilityPath = join(root, "sync", "compatibility.json");
const publicRpcSurfacePath = join(root, "sync", "public-rpc-surface.json");
const extensibilityContractPath = join(root, "sync", "extensibility-contract.json");
const workDirectory = join(root, ".sync-work");
const cliReleaseRepository = "github/copilot-cli";
const cliReleasePlatform = "linux-x64";

function parseJson(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

function digest(bytes) {
  return `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function validateMetadata(metadata) {
  const expectedKeys = [
    "cliPackageVersion",
    "cliReleaseAsset",
    "cliReleaseAssetDigest",
    "schemaDigests",
    "sdkProtocolVersion",
    "upstreamCommit",
    "upstreamRef",
    "upstreamRepository",
  ];
  assert(Object.keys(metadata).sort().join(",") === expectedKeys.join(","), "metadata fields are invalid");
  assert(metadata.upstreamRepository === repository, "metadata repository is invalid");
  assert(metadata.upstreamRef === ref, "metadata ref is invalid");
  assert(/^[0-9a-f]{40}$/.test(metadata.upstreamCommit), "metadata commit is invalid");
  assert(Number.isSafeInteger(metadata.sdkProtocolVersion) && metadata.sdkProtocolVersion >= 0, "metadata protocol version is invalid");
  assert(/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(metadata.cliPackageVersion), "metadata CLI package version is invalid");
  assert(
    metadata.cliReleaseAsset ===
      `github-copilot-${metadata.cliPackageVersion}-${cliReleasePlatform}.tgz`,
    "metadata CLI release asset is invalid",
  );
  assert(
    /^sha256:[0-9a-f]{64}$/.test(metadata.cliReleaseAssetDigest),
    "metadata CLI release asset digest is invalid",
  );
  assert(metadata.schemaDigests && Object.keys(metadata.schemaDigests).sort().join(",") === schemaNames.sort().join(","), "metadata schema digests are invalid");
  for (const name of schemaNames) {
    assert(/^sha256:[0-9a-f]{64}$/.test(metadata.schemaDigests[name]), `metadata digest for ${name} is invalid`);
  }
}

function directRpcMethods(...sources) {
  const methods = new Set();
  const pattern = /sendRequest\(\s*["']([^"']+)/g;
  for (const source of sources) {
    for (const match of source.matchAll(pattern)) methods.add(match[1]);
  }
  return [...methods].sort();
}

function writePublicRpcSurface(upstreamCommit, ...sources) {
  writeFileSync(
    publicRpcSurfacePath,
    `${JSON.stringify({
      upstreamCommit,
      directMethods: directRpcMethods(...sources),
    }, null, 2)}\n`,
  );
}

const extensibilityMethods = [
  "plugins.builtin.set",
  "hooks.invoke",
  "session.canvas.open",
  "session.canvas.close",
  "session.canvas.action.invoke",
  "canvas.open",
  "canvas.close",
  "canvas.action.invoke",
  "session.mcp.oauth.handlePendingRequest",
  "session.mcp.apps.listTools",
  "session.mcp.apps.callTool",
  "session.mcp.apps.readResource",
];

function expectedExtensibilityContract(upstreamCommit) {
  return {
    upstreamCommit,
    startup: {
      builtinPluginDirectories: { status: "typed", wireMethod: "plugins.builtin.set" },
    },
    lifecycle: {
      create: {
        wireMethod: "session.create",
        fields: [
          "pluginDirectories", "skillDirectories", "disabledSkills", "includedBuiltinSkills",
          "enableSkills", "hooks", "mcpServers", "mcpOAuthTokenStorage",
          "authClientIdMetadataUrl", "disabledMcpServers", "canvases",
          "requestCanvasRenderer", "requestExtensions", "extensionSdkPath",
          "extensionInfo", "canvasProvider", "requestMcpApps",
        ],
      },
      resume: {
        wireMethod: "session.resume",
        fields: [
          "pluginDirectories", "skillDirectories", "disabledSkills", "includedBuiltinSkills",
          "enableSkills", "hooks", "mcpServers", "mcpOAuthTokenStorage",
          "authClientIdMetadataUrl", "disabledMcpServers", "canvases",
          "requestCanvasRenderer", "requestExtensions", "extensionSdkPath",
          "extensionInfo", "canvasProvider", "requestMcpApps", "openCanvases",
          "disableResume", "continuePendingWork",
        ],
      },
      extensionJoin: {
        wireMethod: "session.resume",
        fields: ["requestedEnvironmentVariables"],
        responseFields: ["grantedEnvironmentVariables"],
        ownership: "owned-result",
        redeclared: ["onPermissionRequest"],
        omitted: ["extensionSdkPath"],
      },
    },
    callbacks: {
      hooks: { status: "typed", method: "hooks.invoke" },
      canvasProvider: {
        status: "typed",
        methods: ["canvas.open", "canvas.close", "canvas.action.invoke"],
      },
      mcpOAuth: {
        status: "typed",
        event: "mcp.oauth_required",
        responseMethod: "session.mcp.oauth.handlePendingRequest",
        tokenStorage: "runtime-owned",
      },
    },
    capabilities: {
      path: "capabilities.ui",
      fields: ["canvases", "mcpApps"],
      status: "typed-tristate",
      liveEvent: "capabilities.changed",
    },
    experimentalMcpApps: {
      status: "typed-opaque-results",
      reason: "The pinned schemas mark MCP Apps experimental; request arguments are typed and evolving result JSON is owned.",
      methods: [
        "session.mcp.apps.listTools",
        "session.mcp.apps.callTool",
        "session.mcp.apps.readResource",
      ],
    },
    deferred: {
      extensionsCapability: "The pinned lifecycle response has no extension-management acknowledgement bit.",
      hostTokenStoreCallback: "The pinned contract exposes runtime-owned persistent or in-memory token storage, not an SDK token-store callback.",
      mcpAppsHostContextAndDiagnose: "Not required for the verified list/call/read parity slice; schemas remain experimental.",
    },
  };
}

function sourceSection(source, startMarker, endMarker, owner) {
  const start = source.indexOf(startMarker);
  assert(start >= 0, `upstream ${owner} declaration is missing: ${startMarker}`);
  const end = source.indexOf(endMarker, start + startMarker.length);
  assert(end >= 0, `upstream ${owner} declaration has no boundary: ${endMarker}`);
  return source.slice(start, end);
}

function requireSourceFragments(source, fragments, owner) {
  for (const fragment of fragments) {
    assert(source.includes(fragment), `upstream ${owner} declaration is missing: ${fragment}`);
  }
}

function verifyLifecycleContract(contract, clientSource, typesSource, extensionSource) {
  const base = sourceSection(
    typesSource,
    "export interface SessionConfigBase {",
    "export interface SessionConfig extends SessionConfigBase {",
    "SessionConfigBase",
  );
  const create = sourceSection(
    typesSource,
    "export interface SessionConfig extends SessionConfigBase {",
    "export interface ResumeSessionConfig extends SessionConfigBase {",
    "SessionConfig",
  );
  const resume = sourceSection(
    typesSource,
    "export interface ResumeSessionConfig extends SessionConfigBase {",
    "export interface ExtensionJoinOptions {",
    "ResumeSessionConfig",
  );
  const join = sourceSection(
    extensionSource,
    "export type JoinSessionConfig = Omit<",
    "export async function joinSession",
    "JoinSessionConfig",
  );
  const extensionResume = sourceSection(
    clientSource,
    "    private async resumeSessionInternal(",
    "    async ping(",
    "resumeSessionInternal",
  );

  const commonDeclarations = {
    pluginDirectories: "pluginDirectories?: string[]",
    skillDirectories: "skillDirectories?: string[]",
    disabledSkills: "disabledSkills?: string[]",
    includedBuiltinSkills: "includedBuiltinSkills?: string[]",
    enableSkills: "enableSkills?: boolean",
    hooks: "hooks?: SessionHooks",
    mcpServers: "mcpServers?: Record<string, MCPServerConfig>",
    mcpOAuthTokenStorage: 'mcpOAuthTokenStorage?: "persistent" | "in-memory"',
    authClientIdMetadataUrl: "authClientIdMetadataUrl?: string",
    disabledMcpServers: "disabledMcpServers?: string[]",
    canvases: "canvases?: Canvas[]",
    requestCanvasRenderer: "requestCanvasRenderer?: boolean",
    requestExtensions: "requestExtensions?: boolean",
    extensionSdkPath: "extensionSdkPath?: string",
    extensionInfo: "extensionInfo?: ExtensionInfo",
    canvasProvider: "canvasProvider?: CanvasProviderIdentity",
    requestMcpApps: "enableMcpApps?: boolean",
  };
  const resumeDeclarations = {
    openCanvases: "openCanvases?: OpenCanvasInstance[]",
    disableResume: "suppressResumeEvent?: boolean",
    continuePendingWork: "continuePendingWork?: boolean",
  };
  const assertFieldsOwnedBy = (fields, declarations, source, owner) => {
    for (const field of fields) {
      const declaration = declarations[field];
      assert(declaration, `no upstream ${owner} declaration mapping for lifecycle field: ${field}`);
      requireSourceFragments(source, [declaration], owner);
    }
  };

  requireSourceFragments(base, ["onMcpAuthRequest?: McpAuthHandler"], "SessionConfigBase");
  assertFieldsOwnedBy(contract.lifecycle.create.fields, commonDeclarations, base, "SessionConfigBase");
  assert(create.startsWith("export interface SessionConfig extends SessionConfigBase {"), "upstream SessionConfig no longer extends SessionConfigBase");
  for (const field of contract.lifecycle.resume.fields) {
    if (commonDeclarations[field]) {
      requireSourceFragments(base, [commonDeclarations[field]], "SessionConfigBase");
    } else {
      assertFieldsOwnedBy([field], resumeDeclarations, resume, "ResumeSessionConfig");
    }
  }
  assert(resume.startsWith("export interface ResumeSessionConfig extends SessionConfigBase {"), "upstream ResumeSessionConfig no longer extends SessionConfigBase");

  assertFieldsOwnedBy(
    contract.lifecycle.extensionJoin.fields,
    { requestedEnvironmentVariables: "requestedEnvironmentVariables?: string[]" },
    join,
    "JoinSessionConfig",
  );
  assertFieldsOwnedBy(
    contract.lifecycle.extensionJoin.responseFields,
    { grantedEnvironmentVariables: "grantedEnvironmentVariables?: Record<string, string>" },
    extensionResume,
    "resumeSessionInternal response",
  );
  assertFieldsOwnedBy(
    contract.lifecycle.extensionJoin.redeclared,
    { onPermissionRequest: "onPermissionRequest?: PermissionHandler" },
    join,
    "JoinSessionConfig",
  );
  for (const field of contract.lifecycle.extensionJoin.omitted) {
    assert(field === "extensionSdkPath", `no upstream JoinSessionConfig omission check for: ${field}`);
    assert(
      /Omit<\s*ResumeSessionConfig,\s*"onPermissionRequest"\s*\|\s*"extensionSdkPath"\s*>/.test(join),
      "upstream JoinSessionConfig no longer omits extensionSdkPath",
    );
    assert(
      !/extensionSdkPath\s*\?:/.test(join),
      "upstream JoinSessionConfig directly declares extensionSdkPath",
    );
  }
}

function writeExtensibilityContract(upstreamCommit, clientSource, typesSource, extensionSource) {
  const clientOptions = sourceSection(
    typesSource,
    "export interface CopilotClientOptions {",
    'export type ToolResultType = "success"',
    "CopilotClientOptions",
  );
  const clientConstructor = sourceSection(
    clientSource,
    "    constructor(options: CopilotClientOptions = {}) {",
    "    private connectionExtraArgs: string[] = [];",
    "CopilotClient constructor",
  );
  const clientStartup = sourceSection(
    clientSource,
    "    private async doStart(): Promise<void> {",
    "    async stop(): Promise<Error[]> {",
    "CopilotClient startup",
  );
  const contract = expectedExtensibilityContract(upstreamCommit);
  requireSourceFragments(
    clientOptions,
    ["builtinPluginDirectories?: readonly string[]"],
    "CopilotClientOptions",
  );
  requireSourceFragments(
    clientConstructor,
    ["this.builtinPluginDirectories = [...options.builtinPluginDirectories]"],
    "CopilotClient constructor",
  );
  requireSourceFragments(
    clientStartup,
    ['sendRequest("plugins.builtin.set"'],
    "CopilotClient startup",
  );
  verifyLifecycleContract(contract, clientSource, typesSource, extensionSource);
  writeFileSync(extensibilityContractPath, `${JSON.stringify(contract, null, 2)}\n`);
}

function collectPropertyValues(value, property, output = new Set()) {
  if (Array.isArray(value)) {
    for (const item of value) collectPropertyValues(item, property, output);
  } else if (value && typeof value === "object") {
    if (typeof value[property] === "string") output.add(value[property]);
    for (const item of Object.values(value)) collectPropertyValues(item, property, output);
  }
  return output;
}

function findObjectByProperty(value, property, expected) {
  if (Array.isArray(value)) {
    for (const item of value) {
      const found = findObjectByProperty(item, property, expected);
      if (found) return found;
    }
  } else if (value && typeof value === "object") {
    if (value[property] === expected) return value;
    for (const item of Object.values(value)) {
      const found = findObjectByProperty(item, property, expected);
      if (found) return found;
    }
  }
  return null;
}

function requireProperties(value, names, label) {
  assert(value?.properties, `${label} has no properties`);
  for (const name of names) {
    assert(value.properties[name], `${label} is missing property: ${name}`);
  }
}

function requireExactStrings(actual, expected, label) {
  assert(Array.isArray(expected), `${label} compatibility must be an array`);
  assert(
    [...actual].sort().join(",") === [...expected].sort().join(","),
    `${label} changed`,
  );
}

function requireSchemaContract(actual, expected, label) {
  assert(expected && typeof expected === "object", `${label} contract is missing`);
  assert(
    JSON.stringify(schemaContract(actual)) === JSON.stringify(expected),
    `${label} contract changed`,
  );
}

function schemaSignature(value) {
  if (typeof value?.$ref === "string") {
    return `ref:${value.$ref.split("/").at(-1)}`;
  }
  if (value?.type === "array") {
    return `array:${schemaSignature(value.items)}`;
  }
  if (value?.type === "object" && value.additionalProperties?.["x-opaque-json"] === true) {
    return "object:opaque-values";
  }
  if (typeof value?.type === "string") return value.type;
  throw new Error("unsupported schema signature");
}

function definitionCompatibility(schema, name) {
  const value = schema.definitions?.[name];
  assert(value, `missing schema definition: ${name}`);
  let properties = value.properties;
  if (name === "ModelsListRequest") {
    properties = value.anyOf?.find((variant) => variant.properties)?.properties;
  }
  assert(properties, `${name} has no properties`);
  return {
    properties: Object.fromEntries(
      Object.entries(properties)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([property, propertySchema]) => [property, schemaSignature(propertySchema)]),
    ),
    required: [...(value.required ?? [])].sort(),
  };
}

function stringEnum(schema, name) {
  const values = schema.definitions?.[name]?.enum;
  assert(
    Array.isArray(values) && values.every((value) => typeof value === "string"),
    `${name} has no string enum`,
  );
  return [...values].sort();
}

function eventDiscriminators(schema) {
  const values = new Set();
  for (const definition of Object.values(schema.definitions ?? {})) {
    const discriminator = definition?.properties?.type?.const;
    if (typeof discriminator === "string") values.add(discriminator);
  }
  return values;
}

function verifyCompatibility(apiSchema, eventSchema) {
  const compatibility = parseJson(compatibilityPath);
  assert(Array.isArray(compatibility.wireMethods), "wireMethods must be an array");
  assert(Array.isArray(compatibility.sessionEventDiscriminators), "sessionEventDiscriminators must be an array");
  assert(compatibility.directRpcMethods, "directRpcMethods compatibility is missing");
  assert(compatibility.modelDefinitions, "modelDefinitions compatibility is missing");
  assert(compatibility.modelEnums, "modelEnums compatibility is missing");
  assert(compatibility.providerConfig, "providerConfig compatibility is missing");

  const methods = collectPropertyValues(apiSchema, "rpcMethod");
  const scopeMethods = {
    outboundGlobal: collectPropertyValues(apiSchema.server, "rpcMethod"),
    outboundSession: collectPropertyValues(apiSchema.session, "rpcMethod"),
    inboundGlobal: collectPropertyValues(apiSchema.clientGlobal, "rpcMethod"),
    inboundSession: collectPropertyValues(apiSchema.clientSession, "rpcMethod"),
  };
  const coveredMethods = new Set(
    Object.values(scopeMethods).flatMap((scope) => [...scope]),
  );
  requireExactStrings(methods, [...coveredMethods], "RPC scope coverage");
  assert(
    Object.values(scopeMethods).reduce((count, scope) => count + scope.size, 0) ===
      methods.size,
    "RPC methods must belong to exactly one scope",
  );
  const clientSource = readFileSync(join(root, "src", "client.zig"), "utf8");
  for (const symbol of ["callRpc", "registerRpcHandler", "unregisterRpcHandler"]) {
    assert(clientSource.includes(`pub fn ${symbol}`), `missing generic RPC API: ${symbol}`);
  }
  requireExactStrings(
    Object.keys(compatibility.directRpcMethods),
    parseJson(publicRpcSurfacePath).directMethods,
    "direct RPC method classifications",
  );
  for (const [method, coverage] of Object.entries(compatibility.directRpcMethods)) {
    assert(
      coverage === "typed" || coverage === "generic",
      `invalid direct RPC coverage for ${method}`,
    );
  }
  for (const [name, expected] of Object.entries(compatibility.modelDefinitions)) {
    assert(
      JSON.stringify(definitionCompatibility(apiSchema, name)) === JSON.stringify(expected),
      `${name} model contract changed`,
    );
  }
  for (const [name, expected] of Object.entries(compatibility.modelEnums)) {
    requireExactStrings(stringEnum(apiSchema, name), expected, `${name} model enum`);
  }
  requireExactStrings(
    stringEnum(eventSchema, "AutoTier"),
    ["balance", "efficiency", "fast", "intelligence"],
    "AutoTier enum",
  );
  const modelDiscountPercent =
    apiSchema.definitions?.ModelBilling?.properties?.discountPercent;
  assert(
    modelDiscountPercent?.type === "integer" &&
      modelDiscountPercent.minimum === 0 &&
      modelDiscountPercent.maximum === 100,
    "ModelBilling.discountPercent range changed",
  );
  for (const method of compatibility.wireMethods) {
    assert(typeof method.name === "string", "wire method name is invalid");
    if (method.declaredBy === "api.schema.json") {
      assert(methods.has(method.name), `required schema RPC method is missing: ${method.name}`);
    } else if (method.declaredBy === "src/client.zig") {
      assert(clientSource.includes(`"${method.name}"`), `required SDK wire method is missing: ${method.name}`);
    } else {
      throw new Error(`unsupported wire method source: ${method.declaredBy}`);
    }
  }

  const discriminators = eventDiscriminators(eventSchema);
  for (const discriminator of compatibility.sessionEventDiscriminators) {
    assert(discriminators.has(discriminator), `required session event is missing: ${discriminator}`);
  }

  requireProperties(
    apiSchema.definitions?.ConnectClientInfo,
    ["editorName", "editorVersion", "extensionName", "extensionVersion"],
    "ConnectClientInfo",
  );
  requireProperties(
    findObjectByProperty(apiSchema, "rpcMethod", "session.send")?.params,
    ["sessionId", "prompt"],
    "session.send params",
  );
  requireProperties(
    findObjectByProperty(apiSchema, "rpcMethod", "session.permissions.handlePendingPermissionRequest")
      ?.params,
    ["sessionId", "requestId", "result", "decisionContext"],
    "permission response params",
  );
  requireProperties(
    findObjectByProperty(apiSchema, "rpcMethod", "session.tools.handlePendingToolCall")?.params,
    ["sessionId", "requestId", "result", "error"],
    "tool response params",
  );
  requireProperties(
    eventSchema.definitions?.IdleData,
    ["aborted", "mode"],
    "session.idle data",
  );
  requireProperties(
    eventSchema.definitions?.ExternalToolRequestedData,
    ["requestId", "toolCallId", "toolName", "arguments"],
    "external_tool.requested data",
  );
  requireProperties(
    eventSchema.definitions?.PermissionRequestedData,
    ["requestId", "permissionRequest"],
    "permission.requested data",
  );

  const provider = apiSchema.definitions?.ProviderConfig;
  const providerCompatibility = compatibility.providerConfig;
  assert(provider?.properties, "ProviderConfig has no properties");
  assert(providerCompatibility.properties, "ProviderConfig property classifications are missing");

  const providerProperties = Object.keys(provider.properties).sort();
  const classifiedProperties = Object.keys(providerCompatibility.properties).sort();
  requireExactStrings(
    providerProperties,
    classifiedProperties,
    "ProviderConfig properties",
  );
  for (const name of providerProperties) {
    const classification = providerCompatibility.properties[name];
    assert(
      classification?.status === "supported" || classification?.status === "deferred",
      `ProviderConfig property has an invalid classification: ${name}`,
    );
    if (classification.status === "deferred") {
      assert(
        typeof classification.reason === "string" && classification.reason.length > 0,
        `deferred ProviderConfig property needs a reason: ${name}`,
      );
    }
    requireSchemaContract(
      provider.properties[name],
      classification.contract,
      `ProviderConfig.${name}`,
    );
  }

  requireExactStrings(
    provider.required ?? [],
    providerCompatibility.required,
    "ProviderConfig required fields",
  );
  requireExactStrings(
    apiSchema.definitions?.ProviderConfigType?.enum ?? [],
    providerCompatibility.families,
    "ProviderConfig family enum",
  );
  requireExactStrings(
    apiSchema.definitions?.ProviderConfigWireApi?.enum ?? [],
    providerCompatibility.wireApis,
    "ProviderConfig wire API enum",
  );
  requireExactStrings(
    apiSchema.definitions?.ProviderConfigTransport?.enum ?? [],
    providerCompatibility.transports,
    "ProviderConfig transport enum",
  );
  const azureProperties = apiSchema.definitions?.ProviderConfigAzure?.properties ?? {};
  requireExactStrings(
    Object.keys(azureProperties),
    Object.keys(providerCompatibility.azureProperties ?? {}),
    "ProviderConfig Azure option fields",
  );
  for (const name of Object.keys(azureProperties)) {
    requireSchemaContract(
      azureProperties[name],
      providerCompatibility.azureProperties[name],
      `ProviderConfigAzure.${name}`,
    );
  }
}

function verify() {
  const metadata = parseJson(metadataPath);
  validateMetadata(metadata);
  const publicRpcSurface = parseJson(publicRpcSurfacePath);
  assert(
    publicRpcSurface.upstreamCommit === metadata.upstreamCommit,
    "public RPC surface is from a different upstream commit",
  );
  requireExactStrings(
    publicRpcSurface.directMethods,
    [...new Set(publicRpcSurface.directMethods)].sort(),
    "public direct RPC methods",
  );
  assert(
    publicRpcSurface.directMethods.includes("models.list"),
    "public RPC surface is missing models.list",
  );
  const schemas = {};

  for (const name of schemaNames) {
    const path = join(schemaDirectory, name);
    const bytes = readFileSync(path);
    assert(digest(bytes) === metadata.schemaDigests[name], `${name} does not match its recorded digest`);
    schemas[name] = JSON.parse(bytes);
  }

  const expectedGenerated = `pub const sdk_protocol_version: u64 = ${metadata.sdkProtocolVersion};\n`;
  assert(readFileSync(generatedPath, "utf8") === expectedGenerated, "generated Zig protocol version is stale");
  checkSchemaSnapshot();
  verifyCompatibility(schemas["api.schema.json"], schemas["session-events.schema.json"]);
  const extensibility = parseJson(extensibilityContractPath);
  assert(
    JSON.stringify(extensibility) === JSON.stringify(expectedExtensibilityContract(metadata.upstreamCommit)),
    "extensibility contract is stale",
  );
  const methods = collectPropertyValues(schemas["api.schema.json"], "rpcMethod");
  for (const method of extensibilityMethods) {
    assert(methods.has(method), `extensibility RPC method is missing: ${method}`);
  }
  const events = eventDiscriminators(schemas["session-events.schema.json"]);
  for (const event of ["mcp.oauth_required", "capabilities.changed", "session.canvas.opened", "session.canvas.closed"]) {
    assert(events.has(event), `extensibility event is missing: ${event}`);
  }
  assert(
    extensibility.capabilities.path === "capabilities.ui",
    "unsupported capabilities compatibility path",
  );
  const capabilitiesData = schemas["session-events.schema.json"].definitions?.CapabilitiesChangedData;
  assert(
    capabilitiesData?.properties?.ui?.$ref === "#/definitions/CapabilitiesChangedUI",
    "CapabilitiesChangedData.ui contract changed",
  );
  const capabilitiesUi = schemas["session-events.schema.json"].definitions?.CapabilitiesChangedUI;
  requireProperties(
    capabilitiesUi,
    extensibility.capabilities.fields,
    "CapabilitiesChangedUI",
  );
  for (const field of extensibility.capabilities.fields) {
    assert(
      capabilitiesUi.properties[field].type === "boolean",
      `CapabilitiesChangedUI.${field} is no longer boolean`,
    );
  }
  for (const [feature, reason] of Object.entries(extensibility.deferred ?? {})) {
    assert(typeof reason === "string" && reason.length > 0, `deferred ${feature} needs a reason`);
  }
  console.log(
    `Verified ${metadata.upstreamCommit} with Copilot CLI ${metadata.cliPackageVersion} (${metadata.cliReleaseAsset})`,
  );
}

function requestHeaders() {
  const headers = {
    Accept: "application/vnd.github+json",
    "User-Agent": "copilot-sdk-zig-sync",
  };
  if (process.env.GITHUB_TOKEN) headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
  return headers;
}

async function fetchJson(url) {
  const response = await fetch(url, { headers: requestHeaders() });
  if (!response.ok) throw new Error(`request failed with ${response.status}: ${url}`);
  return response.json();
}

async function fetchText(url) {
  const response = await fetch(url, { headers: requestHeaders() });
  if (!response.ok) throw new Error(`request failed with ${response.status}: ${url}`);
  return response.text();
}

async function resolveCommit(explicitCommit) {
  if (explicitCommit) {
    assert(/^[0-9a-f]{40}$/.test(explicitCommit), "--commit requires a 40-character lowercase SHA");
    return explicitCommit;
  }
  const commit = await fetchJson(`https://api.github.com/repos/${repository}/commits/${ref}`);
  assert(/^[0-9a-f]{40}$/.test(commit.sha), "GitHub returned an invalid commit SHA");
  return commit.sha;
}

function rawUrl(commit, path) {
  return `https://raw.githubusercontent.com/${repository}/${commit}/${path}`;
}

function releaseAssetName(version) {
  return `github-copilot-${version}-${cliReleasePlatform}.tgz`;
}

async function fetchReleaseFile(url, ifPublished) {
  const response = await fetch(url, { headers: requestHeaders() });
  if (ifPublished && response.status === 404) return null;
  if (!response.ok) throw new Error(`request failed with ${response.status}: ${url}`);
  return response;
}

async function installSchemaPackage(version, ifPublished) {
  rmSync(workDirectory, { force: true, recursive: true });
  mkdirSync(workDirectory, { recursive: true });
  const assetName = releaseAssetName(version);
  const releaseBase = `https://github.com/${cliReleaseRepository}/releases/download/v${version}`;
  const checksumsResponse = await fetchReleaseFile(`${releaseBase}/SHA256SUMS.txt`, ifPublished);
  if (checksumsResponse === null) {
    console.log(`Deferred sync because Copilot CLI ${version} is not published`);
    return null;
  }
  const checksumLine = (await checksumsResponse.text())
    .split(/\r?\n/)
    .find((line) => line.trim().split(/\s+/, 2)[1]?.replace(/^\*/, "") === assetName);
  const expectedChecksum = checksumLine?.trim().split(/\s+/, 2)[0]?.toLowerCase();
  assert(/^[0-9a-f]{64}$/.test(expectedChecksum), `release checksums do not contain ${assetName}`);

  const archiveResponse = await fetchReleaseFile(`${releaseBase}/${assetName}`, ifPublished);
  if (archiveResponse === null) {
    console.log(`Deferred sync because Copilot CLI ${version} is not published`);
    return null;
  }
  const archive = Buffer.from(await archiveResponse.arrayBuffer());
  const actualChecksum = createHash("sha256").update(archive).digest("hex");
  assert(actualChecksum === expectedChecksum, `checksum mismatch for ${assetName}`);

  const archivePath = join(workDirectory, assetName);
  writeFileSync(archivePath, archive);
  execFileSync("tar", ["-xzf", archivePath, "-C", workDirectory]);
  const sourceDirectory = join(workDirectory, "package", "schemas");
  assert(
    schemaNames.every((name) => existsSync(join(sourceDirectory, name))),
    `${assetName} does not contain the required schemas`,
  );
  return {
    sourceDirectory,
    assetName,
    assetDigest: `sha256:${actualChecksum}`,
  };
}

async function synchronize(explicitCommit, ifPublished = false) {
  const commit = await resolveCommit(explicitCommit);
  const [protocol, packageManifest, lock, nodeClient, nodeSession, nodeTypes, nodeExtension] = await Promise.all([
    fetchJson(rawUrl(commit, "sdk-protocol-version.json")),
    fetchJson(rawUrl(commit, "nodejs/package.json")),
    fetchJson(rawUrl(commit, "nodejs/package-lock.json")),
    fetchText(rawUrl(commit, "nodejs/src/client.ts")),
    fetchText(rawUrl(commit, "nodejs/src/session.ts")),
    fetchText(rawUrl(commit, "nodejs/src/types.ts")),
    fetchText(rawUrl(commit, "nodejs/src/extension.ts")),
  ]);
  const cliPackageVersion =
    packageManifest.copilotCliVersion ??
    lock.packages?.["node_modules/@github/copilot"]?.version;
  assert(Number.isSafeInteger(protocol.version), "upstream protocol version is invalid");
  assert(
    /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(cliPackageVersion),
    "upstream package manifest has no exact Copilot CLI version",
  );

  try {
    const schemaPackage = await installSchemaPackage(cliPackageVersion, ifPublished);
    if (schemaPackage === null) return;
    mkdirSync(schemaDirectory, { recursive: true });
    const schemaDigests = {};
    for (const name of schemaNames) {
      const destination = join(schemaDirectory, name);
      cpSync(join(schemaPackage.sourceDirectory, name), destination);
      schemaDigests[name] = digest(readFileSync(destination));
    }

    const metadata = {
      upstreamRepository: repository,
      upstreamRef: ref,
      upstreamCommit: commit,
      sdkProtocolVersion: protocol.version,
      cliPackageVersion,
      cliReleaseAsset: schemaPackage.assetName,
      cliReleaseAssetDigest: schemaPackage.assetDigest,
      schemaDigests,
    };
    validateMetadata(metadata);
    writeFileSync(metadataPath, `${JSON.stringify(metadata, null, 2)}\n`);
    writeFileSync(generatedPath, `pub const sdk_protocol_version: u64 = ${protocol.version};\n`);
    writePublicRpcSurface(commit, nodeClient, nodeSession);
    writeExtensibilityContract(commit, nodeClient, nodeTypes, nodeExtension);
    writeSchemaSnapshot();
  } finally {
    rmSync(workDirectory, { force: true, recursive: true });
  }

  verify();
}

const args = process.argv.slice(2);
if (args.includes("--check")) {
  assert(args.length === 1, "--check does not accept other arguments");
  verify();
} else {
  const commitIndex = args.indexOf("--commit");
  const explicitCommit = commitIndex === -1 ? undefined : args[commitIndex + 1];
  const ifPublished = args.length === 1 && args[0] === "--if-published";
  assert(ifPublished || args.length === (explicitCommit ? 2 : 0), "usage: npm run sync -- [--commit <sha> | --if-published]");
  await synchronize(explicitCommit, ifPublished);
}
