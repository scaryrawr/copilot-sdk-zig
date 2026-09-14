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
import ts from "typescript";
import {
  checkSchemaSnapshot,
  schemaContract,
  writeSchemaSnapshot,
} from "./schema-snapshot.mjs";
import { generateSessionEvents } from "./generate-session-events.mjs";
import {
  exportedStringUnionValues,
  inheritedInterfacePropertySignatures,
  interfaceBase,
  interfacePropertySignatures,
  omitIntersectionAlias,
  requireExactPropertySignatures,
  requireSourceFragments,
  schemaValidationShape,
  sourceSection,
  zigEnumValues,
  zigStructFields,
} from "./source-contract.mjs";
import {
  eventTypeBranch,
  namedClassConstructor,
  requireCallbackReturnsCall,
  requireCallOutsideNestedFunctions,
  registeredStringCallbacks,
} from "./typescript-contract.mjs";

const repository = "github/copilot-sdk";
const ref = "main";
const schemaNames = ["api.schema.json", "session-events.schema.json"];
const root = dirname(dirname(fileURLToPath(import.meta.url)));
const vendorDirectory = join(root, "vendor", "copilot");
const schemaDirectory = join(vendorDirectory, "schemas");
const metadataPath = join(vendorDirectory, "upstream.json");
const generatedPath = join(root, "src", "protocol_version.zig");
const zigSessionSource = readFileSync(join(root, "src", "session.zig"), "utf8");
const zigClientSource = readFileSync(join(root, "src", "client.zig"), "utf8");
const zigRuntimeSource = readFileSync(join(root, "src", "runtime.zig"), "utf8");
const compatibilityPath = join(root, "sync", "compatibility.json");
const publicRpcSurfacePath = join(root, "sync", "public-rpc-surface.json");
const extensibilityContractPath = join(root, "sync", "extensibility-contract.json");
const stableParityContractPath = join(root, "sync", "stable-parity-contract.json");
const workDirectory = join(root, ".sync-work");
const cliReleaseRepository = "github/copilot-cli";
const cliReleasePlatform = "linux-x64";
const publicSdkCommit = "f45c46fd1812f8bed5b4cbc250f47177c83068f0";

function parseJson(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

function digest(bytes) {
  return `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function parseTypeScript(source, owner) {
  const parsed = ts.createSourceFile(
    `${owner}.ts`,
    source,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TS,
  );
  assert(parsed.parseDiagnostics.length === 0, `upstream ${owner} has TypeScript parse errors`);
  return parsed;
}

function nodeName(node, sourceFile) {
  if (!node.name) return null;
  if (ts.isIdentifier(node.name) || ts.isStringLiteralLike(node.name)) return node.name.text;
  return node.name.getText(sourceFile);
}

function findNamedNode(source, name, predicate, owner) {
  const sourceFile = parseTypeScript(source, owner);
  let found = null;
  function visit(node) {
    if (found === null && predicate(node) && nodeName(node, sourceFile) === name) found = node;
    if (found === null) ts.forEachChild(node, visit);
  }
  visit(sourceFile);
  assert(found !== null, `upstream ${owner} declaration is missing: ${name}`);
  return { node: found, sourceFile };
}

function findFunctionLike(source, name, owner = name) {
  return findNamedNode(
    source,
    name,
    (node) => ts.isFunctionDeclaration(node) || ts.isMethodDeclaration(node),
    owner,
  );
}

function findTypeAlias(source, name, owner = name) {
  return findNamedNode(source, name, ts.isTypeAliasDeclaration, owner);
}

function compactNode(node, sourceFile) {
  return node.getText(sourceFile).replace(/\s+/g, "").replace(/;$/, "");
}

function requireAstNodes(root, sourceFile, fragments, owner) {
  const available = new Set();
  function visit(node) {
    available.add(compactNode(node, sourceFile));
    ts.forEachChild(node, visit);
  }
  visit(root);
  for (const fragment of fragments) {
    assert(
      available.has(fragment.replace(/\s+/g, "").replace(/;$/, "")),
      `upstream ${owner} AST is missing: ${fragment}`,
    );
  }
}

function requireStringLiterals(root, values, owner) {
  const literals = new Set();
  function visit(node) {
    if (ts.isStringLiteralLike(node)) literals.add(node.text);
    ts.forEachChild(node, visit);
  }
  visit(root);
  for (const value of values) {
    assert(literals.has(value), `upstream ${owner} string literal is missing: ${value}`);
  }
}

function requireCalls(root, sourceFile, callees, owner) {
  const called = new Set();
  function visit(node) {
    if (ts.isCallExpression(node)) called.add(compactNode(node.expression, sourceFile));
    ts.forEachChild(node, visit);
  }
  visit(root);
  for (const callee of callees) {
    assert(called.has(callee), `upstream ${owner} call is missing: ${callee}`);
  }
}

function requireObjectAssignment(root, sourceFile, target, propertyName, callee, owner) {
  let matched = false;
  function visit(node) {
    if (
      !matched &&
      ts.isBinaryExpression(node) &&
      node.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
      compactNode(node.left, sourceFile) === target &&
      ts.isObjectLiteralExpression(node.right)
    ) {
      const property = node.right.properties.find(
        (candidate) =>
          ts.isPropertyAssignment(candidate) &&
          nodeName(candidate, sourceFile) === propertyName,
      );
      if (property && ts.isPropertyAssignment(property)) {
        requireCalls(property.initializer, sourceFile, [callee], owner);
        matched = true;
      }
    }
    if (!matched) ts.forEachChild(node, visit);
  }
  visit(root);
  assert(matched, `upstream ${owner} object assignment changed: ${target}.${propertyName}`);
}

function findSendRequestObject(root, sourceFile, method, owner) {
  let found = null;
  function visit(node) {
    if (found === null && ts.isCallExpression(node) && node.arguments.length >= 2) {
      const expression = node.expression;
      const calledSendRequest =
        (ts.isIdentifier(expression) && expression.text === "sendRequest") ||
        (ts.isPropertyAccessExpression(expression) && expression.name.text === "sendRequest");
      const methodArgument = node.arguments[0];
      const paramsArgument = node.arguments[1];
      if (
        calledSendRequest &&
        ts.isStringLiteralLike(methodArgument) &&
        methodArgument.text === method &&
        ts.isObjectLiteralExpression(paramsArgument)
      ) {
        found = paramsArgument;
      }
    }
    if (found === null) ts.forEachChild(node, visit);
  }
  visit(root);
  assert(found !== null, `upstream ${owner} does not call ${method} with an object request`);
  return found;
}

function requestProperties(source, functionName, method, owner) {
  const { node, sourceFile } = findFunctionLike(source, functionName, owner);
  const object = findSendRequestObject(node, sourceFile, method, owner);
  const properties = {};
  const spreads = [];
  for (const property of object.properties) {
    if (ts.isSpreadAssignment(property)) {
      spreads.push(`...${compactNode(property.expression, sourceFile)}`);
      continue;
    }
    if (ts.isPropertyAssignment(property)) {
      properties[nodeName(property, sourceFile)] = compactNode(property.initializer, sourceFile);
      continue;
    }
    if (ts.isShorthandPropertyAssignment(property)) {
      properties[property.name.text] = property.name.text;
      continue;
    }
    throw new Error(`upstream ${owner} has an unsupported request property: ${property.getText(sourceFile)}`);
  }
  return { properties, spreads };
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
      hooks: {
        status: "typed",
        method: "hooks.invoke",
        handlers: {
          onPreToolUse: "PreToolUseHandler",
          onPreMcpToolCall: "PreMcpToolCallHandler",
          onPostToolUse: "PostToolUseHandler",
          onPostToolUseFailure: "PostToolUseFailureHandler",
          onUserPromptSubmitted: "UserPromptSubmittedHandler",
          onUserPromptTransformed: "UserPromptTransformedHandler",
          onSessionStart: "SessionStartHandler",
          onSessionEnd: "SessionEndHandler",
          onErrorOccurred: "ErrorOccurredHandler",
          onAgentStop: "AgentStopHandler",
        },
      },
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

const expectedCustomAgentSourceContract = {
  customAgent: {
    name: "required:string",
    displayName: "optional:string",
    description: "optional:string",
    tools: "optional:string[]|null",
    prompt: "required:string",
    mcpServers: "optional:Record<string,MCPServerConfig>",
    infer: "optional:boolean",
    skills: "optional:string[]",
    model: "optional:string",
    reasoningEffort: "optional:ReasoningEffort",
  },
  defaultAgent: {
    excludedTools: "optional:string[]",
  },
  reasoningEffort: ["low", "medium", "high", "xhigh", "max"],
  lifecycle: {
    base: {
      customAgents: "optional:CustomAgentConfig[]",
      defaultAgent: "optional:DefaultAgentConfig",
      agent: "optional:string",
      customAgentsLocalOnly: "optional:boolean",
      excludedBuiltinAgents: "optional:string[]",
    },
    createExtends: "SessionConfigBase",
    resumeExtends: "SessionConfigBase",
    lowering: {
      customAgents: "toWireCustomAgents(config.customAgents)",
      defaultAgent: "config.defaultAgent",
      agent: "config.agent",
      customAgentsLocalOnly: "config.customAgentsLocalOnly",
      excludedBuiltinAgents: "config.excludedBuiltinAgents",
    },
    join: {
      base: "ResumeSessionConfig",
      excluded: ["onPermissionRequest", "extensionSdkPath"],
      properties: {
        onPermissionRequest: "optional:PermissionHandler",
        requestedEnvironmentVariables: "optional:string[]",
        factories: "optional:FactoryHandle[]",
      },
    },
  },
};

const expectedStableSessionRuntimeFields = {
  clientName: "optional:string",
  reasoningEffort: "optional:ReasoningEffort",
  reasoningSummary: "optional:ReasoningSummary",
  enableExperimentalMode: "optional:boolean",
  contextTier: "optional:ContextTier",
  largeOutput: "optional:LargeToolOutputConfig",
  configDirectory: "optional:string",
  capi: "optional:CapiSessionOptions",
  additionalDirectories: "optional:string[]",
  infiniteSessions: "optional:InfiniteSessionConfig",
  memory: "optional:MemoryConfiguration",
  skipEmbeddingRetrieval: "optional:boolean",
  embeddingCacheStorage: 'optional:"persistent"|"in-memory"',
  organizationCustomInstructions: "optional:string",
  enableFileHooks: "optional:boolean",
  enableHostGitOperations: "optional:boolean",
  enableSessionStore: "optional:boolean",
};

const expectedStableSessionRuntimeZigFields = {
  client_name: { type: "?[]const u8", default: "null" },
  reasoning_effort: { type: "?ReasoningEffort", default: "null" },
  reasoning_summary: { type: "?ReasoningSummary", default: "null" },
  enable_experimental_mode: { type: "?bool", default: "null" },
  context_tier: { type: "?ContextTier", default: "null" },
  large_output: { type: "?LargeOutputConfig", default: "null" },
  config_directory: { type: "?[]const u8", default: "null" },
  capi: { type: "?CapiSessionOptions", default: "null" },
  additional_directories: { type: "?[]const[]const u8", default: "null" },
  infinite_sessions: { type: "?InfiniteSessionConfig", default: "null" },
  memory: { type: "?MemoryConfiguration", default: "null" },
  skip_embedding_retrieval: { type: "?bool", default: "null" },
  embedding_cache_storage: { type: "?EmbeddingCacheStorage", default: "null" },
  organization_custom_instructions: { type: "?[]const u8", default: "null" },
  enable_file_hooks: { type: "?bool", default: "null" },
  enable_host_git_operations: { type: "?bool", default: "null" },
  enable_session_store: { type: "?bool", default: "null" },
};

function verifyCustomAgentSourceContract(
  clientSource,
  typesSource,
  extensionSource,
  zigSessionSource,
) {
  const expected = expectedCustomAgentSourceContract;
  requireExactPropertySignatures(
    interfacePropertySignatures(typesSource, "CustomAgentConfig"),
    expected.customAgent,
    "CustomAgentConfig",
  );

  requireExactPropertySignatures(
    interfacePropertySignatures(typesSource, "DefaultAgentConfig"),
    expected.defaultAgent,
    "DefaultAgentConfig",
  );
  requireExactStrings(
    exportedStringUnionValues(typesSource, "ReasoningEffort"),
    expected.reasoningEffort,
    "upstream ReasoningEffort values",
  );
  requireExactStrings(
    zigEnumValues(zigSessionSource, "ReasoningEffort"),
    expected.reasoningEffort,
    "Zig ReasoningEffort values",
  );
  const baseProperties = interfacePropertySignatures(typesSource, "SessionConfigBase");
  for (const [name, signature] of Object.entries(expected.lifecycle.base)) {
    assert(baseProperties[name] === signature, `SessionConfigBase.${name} changed`);
  }
  assert(
    interfaceBase(typesSource, "SessionConfig") === expected.lifecycle.createExtends,
    "upstream SessionConfig inheritance changed",
  );
  assert(
    interfaceBase(typesSource, "ResumeSessionConfig") === expected.lifecycle.resumeExtends,
    "upstream ResumeSessionConfig inheritance changed",
  );
  const joinShape = omitIntersectionAlias(extensionSource, "JoinSessionConfig");
  assert(joinShape.base === expected.lifecycle.join.base, "JoinSessionConfig base changed");
  requireExactStrings(
    joinShape.excluded,
    expected.lifecycle.join.excluded,
    "JoinSessionConfig exclusions",
  );
  requireExactPropertySignatures(
    joinShape.properties,
    expected.lifecycle.join.properties,
    "JoinSessionConfig",
  );

  const customAgentLowering = findFunctionLike(
    clientSource,
    "toWireCustomAgents",
  );
  requireAstNodes(
    customAgentLowering.node,
    customAgentLowering.sourceFile,
    [
      "if (!agents) return undefined",
      "if (!agent.mcpServers) return agent",
      "return { ...rest, mcpServers: toWireMcpServers(mcpServers) }",
    ],
    "toWireCustomAgents",
  );
  const create = sourceSection(
    clientSource,
    "    async createSession(",
    "    async resumeSession(",
    "createSession",
  );
  const resume = sourceSection(
    clientSource,
    "    private async resumeSessionInternal(",
    "    async ping(",
    "resumeSessionInternal",
  );
  for (const [owner, source] of [
    ["createSession", create],
    ["resumeSessionInternal", resume],
  ]) {
    requireSourceFragments(
      source,
      Object.entries(expected.lifecycle.lowering)
        .map(([name, value]) => `${name}: ${value}`),
      owner,
    );
  }
}

function verifyStableSessionRuntimeSourceContract(clientSource, typesSource) {
  const base = interfacePropertySignatures(typesSource, "SessionConfigBase");
  for (const [name, signature] of Object.entries(expectedStableSessionRuntimeFields)) {
    assert(base[name] === signature, `SessionConfigBase.${name} changed`);
  }

  for (const [name, fields] of [
    ["LargeToolOutputConfig", {
      enabled: "optional:boolean",
      maxSizeBytes: "optional:number",
      outputDirectory: "optional:string",
    }],
    ["InfiniteSessionConfig", {
      enabled: "optional:boolean",
      backgroundCompactionThreshold: "optional:number",
      bufferExhaustionThreshold: "optional:number",
    }],
    ["MemoryConfiguration", { enabled: "required:boolean" }],
    ["CapiSessionOptions", {
      autoTier: "optional:AutoTier",
      enableWebSocketResponses: "optional:boolean",
    }],
  ]) {
    requireExactPropertySignatures(
      interfacePropertySignatures(typesSource, name),
      fields,
      name,
    );
  }

  for (const [owner, fields] of [
    ["Zig CreateSessionConfig", zigStructFields(zigSessionSource, "CreateSessionConfig")],
    ["Zig ResumeSessionConfig", zigStructFields(zigSessionSource, "ResumeSessionConfig")],
    ["Zig JoinSessionConfig", zigStructFields(zigSessionSource, "JoinSessionConfig")],
  ]) {
    for (const [name, expected] of Object.entries(expectedStableSessionRuntimeZigFields)) {
      assert(fields[name]?.type === expected.type, `${owner}.${name} type changed`);
      assert(fields[name]?.default === expected.default, `${owner}.${name} default changed`);
    }
  }
  requireExactStrings(
    zigEnumValues(zigSessionSource, "EmbeddingCacheStorage"),
    ["persistent", "in_memory"],
    "Zig EmbeddingCacheStorage values",
  );

  for (const [owner, source] of [
    [
      "Zig buildPreparedCreateSessionRequest",
      sourceSection(
        zigClientSource,
        "fn buildPreparedCreateSessionRequest(",
        "fn buildResumeSessionRequest(",
        "Zig buildPreparedCreateSessionRequest",
      ),
    ],
    [
      "Zig buildPreparedResumeSessionRequest",
      sourceSection(
        zigClientSource,
        "fn buildPreparedResumeSessionRequest(",
        "fn optionalSlice(",
        "Zig buildPreparedResumeSessionRequest",
      ),
    ],
  ]) {
    requireSourceFragments(source, [
      ".clientName = config.client_name",
      ".reasoningEffort = config.reasoning_effort",
      ".reasoningSummary = config.reasoning_summary",
      ".contextTier = config.context_tier",
      ".largeOutput = if (config.large_output)",
      ".maxSizeBytes = value.max_size_bytes",
      ".outputDir = value.output_directory",
      ".configDir = config.config_directory",
      ".capi = if (config.capi)",
      ".autoTier = value.auto_tier",
      ".enableWebSocketResponses = value.enable_websocket_responses",
      ".additionalDirectories = config.additional_directories",
      ".infiniteSessions = if (config.infinite_sessions)",
      ".backgroundCompactionThreshold = value.background_compaction_threshold",
      ".bufferExhaustionThreshold = value.buffer_exhaustion_threshold",
      ".memory = if (config.memory)",
      ".skipEmbeddingRetrieval = config.skip_embedding_retrieval",
      ".embeddingCacheStorage = if (config.embedding_cache_storage)",
      ".persistent => .persistent",
      '.in_memory => .@"in-memory"',
      ".organizationCustomInstructions = config.organization_custom_instructions",
      ".enableFileHooks = config.enable_file_hooks",
      ".enableHostGitOperations = config.enable_host_git_operations",
      ".enableSessionStore = config.enable_session_store",
    ], owner);
  }

  for (const [owner, source] of [
    [
      "createSession",
      sourceSection(
        clientSource,
        "    async createSession(",
        "    async resumeSession(",
        "createSession",
      ),
    ],
    [
      "resumeSessionInternal",
      sourceSection(
        clientSource,
        "    private async resumeSessionInternal(",
        "    async ping(",
        "resumeSessionInternal",
      ),
    ],
  ]) {
    requireSourceFragments(
      source,
      ["workspacePath", 'session["_workspacePath"] = workspacePath'],
      owner,
    );
  }

  requireSourceFragments(
    zigClientSource,
    [
      "workspacePath: ?[]const u8 = null",
      "self.prepareSessionCommit(returned_id, parsed.value.workspacePath) catch",
      "self.prepareSessionCommit(runtime_session_id, parsed.value.workspacePath) catch",
      "pub fn workspacePath(self: Session) !?[]const u8",
    ],
    "Zig workspacePath lifecycle",
  );
}

function verifyLifecycleContract(contract, clientSource, typesSource, extensionSource) {
  const base = interfacePropertySignatures(typesSource, "SessionConfigBase");
  inheritedInterfacePropertySignatures(
    typesSource,
    "SessionConfig",
    "SessionConfigBase",
  );
  const resume = inheritedInterfacePropertySignatures(
    typesSource,
    "ResumeSessionConfig",
    "SessionConfigBase",
  );
  const join = omitIntersectionAlias(extensionSource, "JoinSessionConfig");
  const extensionResume = sourceSection(
    clientSource,
    "    private async resumeSessionInternal(",
    "    async ping(",
    "resumeSessionInternal",
  );

  const commonDeclarations = {
    pluginDirectories: ["pluginDirectories", "optional:string[]"],
    skillDirectories: ["skillDirectories", "optional:string[]"],
    disabledSkills: ["disabledSkills", "optional:string[]"],
    includedBuiltinSkills: ["includedBuiltinSkills", "optional:string[]"],
    enableSkills: ["enableSkills", "optional:boolean"],
    hooks: ["hooks", "optional:SessionHooks"],
    mcpServers: ["mcpServers", "optional:Record<string,MCPServerConfig>"],
    mcpOAuthTokenStorage: ["mcpOAuthTokenStorage", 'optional:"persistent"|"in-memory"'],
    authClientIdMetadataUrl: ["authClientIdMetadataUrl", "optional:string"],
    disabledMcpServers: ["disabledMcpServers", "optional:string[]"],
    canvases: ["canvases", "optional:Canvas[]"],
    requestCanvasRenderer: ["requestCanvasRenderer", "optional:boolean"],
    requestExtensions: ["requestExtensions", "optional:boolean"],
    extensionSdkPath: ["extensionSdkPath", "optional:string"],
    extensionInfo: ["extensionInfo", "optional:ExtensionInfo"],
    canvasProvider: ["canvasProvider", "optional:CanvasProviderIdentity"],
    requestMcpApps: ["enableMcpApps", "optional:boolean"],
  };
  const resumeDeclarations = {
    openCanvases: ["openCanvases", "optional:OpenCanvasInstance[]"],
    disableResume: ["suppressResumeEvent", "optional:boolean"],
    continuePendingWork: ["continuePendingWork", "optional:boolean"],
  };
  const assertFieldsOwnedBy = (fields, declarations, properties, owner) => {
    for (const field of fields) {
      const declaration = declarations[field];
      assert(declaration, `no upstream ${owner} declaration mapping for lifecycle field: ${field}`);
      const [name, signature] = declaration;
      assert(properties[name] === signature, `upstream ${owner}.${name} changed`);
    }
  };

  assert(
    base.onMcpAuthRequest === "optional:McpAuthHandler",
    "upstream SessionConfigBase.onMcpAuthRequest changed",
  );
  assertFieldsOwnedBy(contract.lifecycle.create.fields, commonDeclarations, base, "SessionConfigBase");
  for (const field of contract.lifecycle.resume.fields) {
    if (commonDeclarations[field]) {
      assertFieldsOwnedBy([field], commonDeclarations, base, "SessionConfigBase");
    } else {
      assertFieldsOwnedBy([field], resumeDeclarations, resume, "ResumeSessionConfig");
    }
  }

  assertFieldsOwnedBy(
    contract.lifecycle.extensionJoin.fields,
    { requestedEnvironmentVariables: ["requestedEnvironmentVariables", "optional:string[]"] },
    join.properties,
    "JoinSessionConfig",
  );
  for (const field of contract.lifecycle.extensionJoin.responseFields) {
    assert(
      field === "grantedEnvironmentVariables",
      `no upstream response declaration mapping for lifecycle field: ${field}`,
    );
    requireSourceFragments(
      extensionResume,
      ["grantedEnvironmentVariables?: Record<string, string>"],
      "resumeSessionInternal response",
    );
  }
  assertFieldsOwnedBy(
    contract.lifecycle.extensionJoin.redeclared,
    { onPermissionRequest: ["onPermissionRequest", "optional:PermissionHandler"] },
    join.properties,
    "JoinSessionConfig",
  );
  requireExactStrings(join.excluded, contract.lifecycle.extensionJoin.omitted.concat(
    contract.lifecycle.extensionJoin.redeclared,
  ), "JoinSessionConfig exclusions");
  assert(
    !Object.hasOwn(join.properties, "extensionSdkPath"),
    "upstream JoinSessionConfig directly declares extensionSdkPath",
  );
}

function verifyHookContract(contract, typesSource) {
  const declarations = interfacePropertySignatures(typesSource, "SessionHooks");
  const expected = contract.callbacks.hooks.handlers;
  requireExactStrings(
    Object.keys(declarations),
    Object.keys(expected),
    "SessionHooks callback inventory",
  );
  for (const [name, handler] of Object.entries(expected)) {
    assert(
      declarations[name] === `optional:${handler}`,
      `SessionHooks.${name} changed from ${handler}`,
    );
  }
}

function verifyExtensibilitySourceContract(
  contract,
  clientSource,
  typesSource,
  extensionSource,
) {
  const clientOptions = interfacePropertySignatures(typesSource, "CopilotClientOptions");
  const clientConstructor = namedClassConstructor(
    clientSource,
    "CopilotClient",
    "CopilotClient constructor",
  );
  const clientStartup = sourceSection(
    clientSource,
    "    private async doStart(): Promise<void> {",
    "    async stop(): Promise<Error[]> {",
    "CopilotClient startup",
  );
  assert(
    clientOptions.builtinPluginDirectories === "optional:readonly string[]",
    "upstream CopilotClientOptions.builtinPluginDirectories changed",
  );
  const constructorParameters = clientConstructor.node.parameters;
  assert(
    constructorParameters.length === 1 &&
      constructorParameters[0].name.getText(clientConstructor.sourceFile) === "options" &&
      constructorParameters[0].type?.getText(clientConstructor.sourceFile) === "CopilotClientOptions" &&
      constructorParameters[0].initializer?.getText(clientConstructor.sourceFile) === "{}",
    "upstream CopilotClient constructor signature changed",
  );
  requireAstNodes(
    clientConstructor.node,
    clientConstructor.sourceFile,
    ["this.builtinPluginDirectories = [...options.builtinPluginDirectories]"],
    "CopilotClient constructor",
  );
  requireSourceFragments(
    clientStartup,
    ['sendRequest("plugins.builtin.set"'],
    "CopilotClient startup",
  );
  verifyLifecycleContract(contract, clientSource, typesSource, extensionSource);
  verifyHookContract(contract, typesSource);
}

function verifyOutboundMessageEnumContract(typesSource, zigSessionSource) {
  requireExactPropertySignatures(
    interfacePropertySignatures(typesSource, "MessageOptions"),
    {
      prompt: "required:string",
      source: "optional:MessageSource",
      attachments:
        'optional:Array<|{type:"file";path:string;displayName?:string;}|{type:"directory";path:string;displayName?:string;}|{type:"selection";filePath:string;displayName:string;selection?:{start:{line:number;character:number};end:{line:number;character:number};};text?:string;}|{type:"blob";data:string;mimeType:string;displayName?:string;}>',
      mode: 'optional:"enqueue"|"immediate"',
      agentMode: 'optional:"interactive"|"plan"|"autopilot"|"shell"',
      requestHeaders: "optional:Record<string,string>",
      displayPrompt: "optional:string",
    },
    "MessageOptions",
  );

  const messageSource = findTypeAlias(
    typesSource,
    "MessageSource",
    "MessageSource",
  );
  const messageSourceType = messageSource.node.type;

  assert(
    ts.isUnionTypeNode(messageSourceType) &&
      messageSourceType.types.length === 3,
    "upstream MessageSource union changed",
  );

  const [userSource, systemSource, agentSource] = messageSourceType.types;

  assert(
    ts.isLiteralTypeNode(userSource) &&
      ts.isStringLiteralLike(userSource.literal) &&
      userSource.literal.text === "user",
    "upstream MessageSource.user changed",
  );
  assert(
    ts.isLiteralTypeNode(systemSource) &&
      ts.isStringLiteralLike(systemSource.literal) &&
      systemSource.literal.text === "system",
    "upstream MessageSource.system changed",
  );
  assert(
    ts.isTemplateLiteralTypeNode(agentSource) &&
      agentSource.head.text === "agent-" &&
      agentSource.templateSpans.length === 1 &&
      agentSource.templateSpans[0].type.kind === ts.SyntaxKind.StringKeyword &&
      ts.isTemplateTail(agentSource.templateSpans[0].literal) &&
      agentSource.templateSpans[0].literal.text === "",
    "upstream MessageSource agent template changed",
  );

  requireExactPropertySignatures(
    zigStructFields(zigSessionSource, "MessageOptions"),
    {
      prompt: {
        type: "[]const u8",
        default: null,
      },
      source: {
        type: "?MessageSource",
        default: "null",
      },
      attachments: {
        type: "?[]const Attachment",
        default: "null",
      },
      message_attachments: {
        type: "?[]const MessageAttachment",
        default: "null",
      },
      mode: {
        type: "?MessageDeliveryMode",
        default: "null",
      },
      agent_mode: {
        type: "?AgentMode",
        default: "null",
      },
      request_headers: {
        type: "?[]const RequestHeader",
        default: "null",
      },
      display_prompt: {
        type: "?[]const u8",
        default: "null",
      },
    },
    "Zig MessageOptions",
  );

  requireExactPropertySignatures(
    zigStructFields(zigSessionSource, "RequestHeader"),
    {
      name: {
        type: "[]const u8",
        default: null,
      },
      value: {
        type: "[]const u8",
        default: null,
      },
    },
    "Zig RequestHeader",
  );

  const zigMessageSourceSection = sourceSection(
    zigSessionSource,
    "pub const MessageSource = union(enum) {",
    "pub const MessageDeliveryMode = enum {",
    "Zig MessageSource",
  );
  const zigMessageSourceAsStruct = zigMessageSourceSection
    .replace("union(enum)", "struct")
    .replace(/\buser\s*,/, "user: void,")
    .replace(/\bsystem\s*,/, "system: void,");

  requireExactPropertySignatures(
    zigStructFields(zigMessageSourceAsStruct, "MessageSource"),
    {
      user: {
        type: "void",
        default: null,
      },
      system: {
        type: "void",
        default: null,
      },
      agent: {
        type: "[]const u8",
        default: null,
      },
    },
    "Zig MessageSource",
  );

  const zigMessageAttachmentSection = sourceSection(
    zigSessionSource,
    "pub const MessageAttachment = union(enum) {",
    "pub const Attachment = union(enum) {",
    "Zig MessageAttachment",
  );

  const zigMessageAttachmentVariants = sourceSection(
    zigMessageAttachmentSection,
    "pub const MessageAttachment = union(enum) {",
    "    pub const SelectionPosition = struct {",
    "Zig MessageAttachment variants",
  )
    .replace("union(enum)", "struct")
    .concat("};");

  requireExactPropertySignatures(
    zigStructFields(zigMessageAttachmentVariants, "MessageAttachment"),
    {
      file: {
        type: "File",
        default: null,
      },
      directory: {
        type: "Directory",
        default: null,
      },
      selection: {
        type: "Selection",
        default: null,
      },
      blob: {
        type: "Blob",
        default: null,
      },
    },
    "Zig MessageAttachment variants",
  );

  const selectionPositionSource = sourceSection(
    zigMessageAttachmentSection,
    "    pub const SelectionPosition = struct {",
    "    pub const SelectionRange = struct {",
    "Zig MessageAttachment.SelectionPosition",
  );
  requireExactPropertySignatures(
    zigStructFields(selectionPositionSource, "SelectionPosition"),
    {
      line: {
        type: "u32",
        default: null,
      },
      character: {
        type: "u32",
        default: null,
      },
    },
    "Zig MessageAttachment.SelectionPosition",
  );

  const selectionRangeSource = sourceSection(
    zigMessageAttachmentSection,
    "    pub const SelectionRange = struct {",
    "    pub const File = struct {",
    "Zig MessageAttachment.SelectionRange",
  );
  requireExactPropertySignatures(
    zigStructFields(selectionRangeSource, "SelectionRange"),
    {
      start: {
        type: "SelectionPosition",
        default: null,
      },
      end: {
        type: "SelectionPosition",
        default: null,
      },
    },
    "Zig MessageAttachment.SelectionRange",
  );

  const fileAttachmentSource = sourceSection(
    zigMessageAttachmentSection,
    "    pub const File = struct {",
    "    pub const Directory = struct {",
    "Zig MessageAttachment.File",
  );
  requireExactPropertySignatures(
    zigStructFields(fileAttachmentSource, "File"),
    {
      path: {
        type: "[]const u8",
        default: null,
      },
      display_name: {
        type: "?[]const u8",
        default: "null",
      },
    },
    "Zig MessageAttachment.File",
  );

  const directoryAttachmentSource = sourceSection(
    zigMessageAttachmentSection,
    "    pub const Directory = struct {",
    "    pub const Selection = struct {",
    "Zig MessageAttachment.Directory",
  );
  requireExactPropertySignatures(
    zigStructFields(directoryAttachmentSource, "Directory"),
    {
      path: {
        type: "[]const u8",
        default: null,
      },
      display_name: {
        type: "?[]const u8",
        default: "null",
      },
    },
    "Zig MessageAttachment.Directory",
  );

  const selectionAttachmentSource = sourceSection(
    zigMessageAttachmentSection,
    "    pub const Selection = struct {",
    "    pub const Blob = struct {",
    "Zig MessageAttachment.Selection",
  );
  requireExactPropertySignatures(
    zigStructFields(selectionAttachmentSource, "Selection"),
    {
      file_path: {
        type: "[]const u8",
        default: null,
      },
      display_name: {
        type: "[]const u8",
        default: null,
      },
      selection: {
        type: "?SelectionRange",
        default: "null",
      },
      text: {
        type: "?[]const u8",
        default: "null",
      },
    },
    "Zig MessageAttachment.Selection",
  );

  const blobAttachmentSource = sourceSection(
    zigMessageAttachmentSection,
    "    pub const Blob = struct {",
    "\n};\n\n",
    "Zig MessageAttachment.Blob",
  );
  requireExactPropertySignatures(
    zigStructFields(blobAttachmentSource, "Blob"),
    {
      data: {
        type: "[]const u8",
        default: null,
      },
      mime_type: {
        type: "[]const u8",
        default: null,
      },
      display_name: {
        type: "?[]const u8",
        default: "null",
      },
    },
    "Zig MessageAttachment.Blob",
  );

  for (const contract of [
    {
      zig: "MessageDeliveryMode",
      values: ["enqueue", "immediate"],
    },
    {
      zig: "AgentMode",
      values: ["interactive", "plan", "autopilot", "shell"],
    },
  ]) {
    requireExactStrings(
      zigEnumValues(zigSessionSource, contract.zig),
      contract.values,
      `Zig ${contract.zig} values`,
    );
  }
}

function verifyPinnedSourceContracts(
  upstreamCommit,
  clientSource,
  typesSource,
  extensionSource,
  publicTypesSource,
) {
  verifyCustomAgentSourceContract(
    clientSource,
    typesSource,
    extensionSource,
    zigSessionSource,
  );
  verifyOutboundMessageEnumContract(publicTypesSource, zigSessionSource);
  verifyStableSessionRuntimeSourceContract(clientSource, typesSource);
  verifyExtensibilitySourceContract(
    expectedExtensibilityContract(upstreamCommit),
    clientSource,
    typesSource,
    extensionSource,
  );
}

function writeExtensibilityContract(upstreamCommit, clientSource, typesSource, extensionSource) {
  const contract = expectedExtensibilityContract(upstreamCommit);
  writeFileSync(extensibilityContractPath, `${JSON.stringify(contract, null, 2)}\n`);
}

function expectedStableParityContract(protocolCommit) {
  return {
    publicSdkCommit,
    protocolCommit,
    lifecycle: {
      createOnly: ["cloud"],
      createResumeJoin: [
        "commands",
        "toolSearch",
        "askUserVariant",
        "onElicitationRequest",
        "githubMcpToolConfig",
        "onExitPlanModeRequest",
        "onAutoModeSwitchRequest",
        "gitHubToken",
        "gitHubTokenProvider",
        "remoteSession",
        "enableSessionTelemetry",
        "enableFileChangeTracking",
        "coauthorEnabled",
        "manageScheduleEnabled",
        "includeSubAgentStreamingEvents",
        "featureFlags",
        "expAssignments",
      ],
      postLifecycleUpdate: ["coauthorEnabled", "manageScheduleEnabled"],
      joinOmissions: ["extensionSdkPath"],
    },
    callbacks: {
      commands: {
        event: "command.execute",
        responseMethod: "session.commands.handlePendingCommand",
      },
      elicitation: {
        event: "elicitation.requested",
        responseMethod: "session.ui.handlePendingElicitation",
      },
      exitPlanMode: { method: "exitPlanMode.request" },
      autoModeSwitch: { method: "autoModeSwitch.request" },
      gitHubToken: {
        method: "gitHubToken.getToken",
        reasons: ["initial", "refresh"],
        results: ["token", "cancelled"],
        minimumExpiresIn: 3601,
      },
    },
    ui: {
      method: "session.ui.elicitation",
      capability: "capabilities.ui.elicitation",
      helpers: ["confirm", "select", "input"],
    },
    enums: {
      askUserVariant: ["legacy", "elicitation"],
      remoteSession: ["off", "export", "on"],
      autoModeSwitch: ["yes", "yes_always", "no"],
      exitPlanMode: ["exit_only", "interactive", "autopilot", "autopilot_fleet"],
    },
  };
}

function verifyStableParitySourceContract(
  authority,
  clientSource,
  sessionSource,
  typesSource,
  extensionSource,
) {
  const contract = expectedStableParityContract(authority.commit);
  const baseProperties = interfacePropertySignatures(
    typesSource,
    "SessionConfigBase",
    `${authority.name} SessionConfigBase`,
  );
  const createProperties = inheritedInterfacePropertySignatures(
    typesSource,
    "SessionConfig",
    "SessionConfigBase",
    `${authority.name} SessionConfig`,
  );
  const resumeProperties = inheritedInterfacePropertySignatures(
    typesSource,
    "ResumeSessionConfig",
    "SessionConfigBase",
    `${authority.name} ResumeSessionConfig`,
  );
  const stableBaseProperties = {
    commands: "optional:CommandDefinition[]",
    toolSearch: "optional:ToolSearchConfig",
    askUserVariant: "optional:AskUserVariant",
    onElicitationRequest: "optional:ElicitationHandler",
    githubMcpToolConfig: "optional:GitHubMcpToolConfig",
    onExitPlanModeRequest: "optional:ExitPlanModeHandler",
    onAutoModeSwitchRequest: "optional:AutoModeSwitchHandler",
    gitHubToken: "optional:string",
    gitHubTokenProvider: "optional:GitHubTokenProvider",
    remoteSession: "optional:RemoteSessionMode",
    enableSessionTelemetry: "optional:boolean",
    enableFileChangeTracking: "optional:boolean",
    coauthorEnabled: "optional:boolean",
    manageScheduleEnabled: "optional:boolean",
    includeSubAgentStreamingEvents: "optional:boolean",
    featureFlags: "optional:Record<string,boolean>",
    expAssignments: "optional:CopilotExpAssignmentResponse",
  };
  requireExactStrings(
    contract.lifecycle.createResumeJoin,
    Object.keys(stableBaseProperties),
    `${authority.name} stable SessionConfigBase inventory`,
  );
  for (const [field, signature] of Object.entries(stableBaseProperties)) {
    assert(
      baseProperties[field] === signature,
      `${authority.name} SessionConfigBase.${field} changed or moved`,
    );
    assert(
      createProperties[field] === undefined,
      `${authority.name} SessionConfig.${field} must be inherited, not redeclared`,
    );
    assert(
      resumeProperties[field] === undefined,
      `${authority.name} ResumeSessionConfig.${field} must be inherited, not redeclared`,
    );
  }
  requireExactStrings(
    contract.lifecycle.createOnly,
    ["cloud"],
    `${authority.name} create-only stable inventory`,
  );
  assert(
    createProperties.cloud === "optional:CloudSessionOptions",
    `${authority.name} SessionConfig.cloud changed or moved`,
  );
  assert(
    baseProperties.cloud === undefined && resumeProperties.cloud === undefined,
    `${authority.name} cloud must be owned only by SessionConfig`,
  );
  assert(
    interfaceBase(typesSource, "SessionConfig") === "SessionConfigBase",
    `${authority.name} SessionConfig inheritance changed`,
  );
  assert(
    interfaceBase(typesSource, "ResumeSessionConfig") === "SessionConfigBase",
    `${authority.name} ResumeSessionConfig inheritance changed`,
  );
  requireExactStrings(
    exportedStringUnionValues(typesSource, "AskUserVariant"),
    contract.enums.askUserVariant,
    `${authority.name} AskUserVariant values`,
  );
  const expFlagValueDeclaration = findTypeAlias(
    typesSource,
    "ExpFlagValue",
    `${authority.name} ExpFlagValue`,
  );
  const expFlagValue = compactNode(
    expFlagValueDeclaration.node.type,
    expFlagValueDeclaration.sourceFile,
  );
  assert(
    expFlagValue === "string|number|boolean|null",
    `${authority.name} ExpFlagValue changed`,
  );
  requireExactPropertySignatures(
    interfacePropertySignatures(
      typesSource,
      "ExpConfigEntry",
      `${authority.name} ExpConfigEntry`,
    ),
    {
      Id: "required:string",
      Parameters: "required:Record<string,ExpFlagValue>",
    },
    `${authority.name} ExpConfigEntry`,
  );
  requireExactPropertySignatures(
    interfacePropertySignatures(
      typesSource,
      "CopilotExpAssignmentResponse",
      `${authority.name} CopilotExpAssignmentResponse`,
    ),
    {
      Features: "required:string[]",
      Flights: "required:Record<string,string>",
      Configs: "required:ExpConfigEntry[]",
      ParameterGroups: "optional:unknown",
      FlightingVersion: "optional:number",
      ImpressionId: "optional:string",
      AssignmentContext: "required:string",
    },
    `${authority.name} CopilotExpAssignmentResponse`,
  );

  const joinShape = omitIntersectionAlias(extensionSource, "JoinSessionConfig");
  assert(
    joinShape.base === "ResumeSessionConfig",
    `${authority.name} JoinSessionConfig base changed`,
  );
  requireExactStrings(
    joinShape.excluded,
    ["onPermissionRequest", "extensionSdkPath"],
    `${authority.name} JoinSessionConfig exclusions`,
  );
  for (const field of Object.keys(stableBaseProperties)) {
    assert(
      joinShape.properties[field] === undefined,
      `${authority.name} JoinSessionConfig.${field} must be inherited through ResumeSessionConfig`,
    );
  }
  assert(
    joinShape.properties.cloud === undefined,
    `${authority.name} JoinSessionConfig must not acquire create-only cloud`,
  );
  const joinLowering = findFunctionLike(
    extensionSource,
    "joinSession",
    `${authority.name} joinSession`,
  );
  requireAstNodes(joinLowering.node, joinLowering.sourceFile, [
    "extensionSdkPath: _stripped",
    "...rest",
    "suppressResumeEvent: config.suppressResumeEvent ?? true",
  ], `${authority.name} joinSession`);
  requireCalls(
    joinLowering.node,
    joinLowering.sourceFile,
    ["client.resumeSessionForExtension"],
    `${authority.name} joinSession`,
  );

  const create = findFunctionLike(
    clientSource,
    "createSession",
    `${authority.name} createSession`,
  );
  const resume = findFunctionLike(
    clientSource,
    "resumeSessionInternal",
    `${authority.name} resumeSessionInternal`,
  );
  const commonLowering = {
    toolSearch: "config.toolSearch",
    commands:
      'config.commands?.map((cmd)=>({name:cmd.name,description:cmd.description??"",}))',
    enableSessionTelemetry: "config.enableSessionTelemetry",
    enableFileChangeTracking: "config.enableFileChangeTracking",
    requestElicitation: "!!config.onElicitationRequest",
    askUserVariant: "config.askUserVariant",
    requestExitPlanMode: "!!config.onExitPlanModeRequest",
    requestAutoModeSwitch: "!!config.onAutoModeSwitchRequest",
    includeSubAgentStreamingEvents: "config.includeSubAgentStreamingEvents??true",
    gitHubToken: "config.gitHubToken",
    gitHubTokenProviderRegistrationId: "gitHubTokenProviderRegistrationId",
    remoteSession: "config.remoteSession",
    featureFlags: "config.featureFlags",
    expAssignments: "config.expAssignments",
  };
  const createRequest = requestProperties(
    clientSource,
    "createSession",
    "session.create",
    `${authority.name} createSession`,
  );
  const resumeRequest = requestProperties(
    clientSource,
    "resumeSessionInternal",
    "session.resume",
    `${authority.name} resumeSessionInternal`,
  );
  for (const [owner, request] of [
    ["createSession", createRequest],
    ["resumeSessionInternal", resumeRequest],
  ]) {
    for (const [field, expression] of Object.entries(commonLowering)) {
      assert(
        request.properties[field] === expression.replace(/\s+/g, ""),
        `${authority.name} ${owner} ${field} lowering changed`,
      );
    }
    assert(
      request.spreads.includes(
        "...(config.githubMcpToolConfig!=null?{githubMcpToolConfig:config.githubMcpToolConfig}:{})",
      ),
      `${authority.name} ${owner} githubMcpToolConfig lowering changed`,
    );
    const functionNode = owner === "createSession" ? create : resume;
    const sessionVariable = owner === "createSession" ? "s" : "session";
    requireAstNodes(functionNode.node, functionNode.sourceFile, [
      `${sessionVariable}.registerCommands(config.commands)`,
      `${sessionVariable}.registerElicitationHandler(config.onElicitationRequest)`,
      `${sessionVariable}.registerExitPlanModeHandler(config.onExitPlanModeRequest)`,
      `${sessionVariable}.registerAutoModeSwitchHandler(config.onAutoModeSwitchRequest)`,
      "config.gitHubTokenProvider",
      "await this.updateSessionOptionsForMode(session, config)",
    ], `${authority.name} ${owner} callback setup`);
  }
  assert(
    createRequest.properties.cloud === "config.cloud",
    `${authority.name} createSession cloud lowering changed`,
  );
  requireAstNodes(create.node, create.sourceFile, [
    "const gitHubTokenProviderRegistrationId = this.registerGitHubTokenProvider(config.gitHubTokenProvider, localSessionId);",
    "this.commitGitHubTokenProvider(returnedSessionId, gitHubTokenProviderRegistrationId);",
  ], `${authority.name} createSession GitHub token lifecycle`);
  assert(
    resumeRequest.properties.cloud === undefined,
    `${authority.name} resumeSessionInternal must not lower create-only cloud`,
  );
  requireAstNodes(resume.node, resume.sourceFile, [
    "const gitHubTokenProviderRegistrationId = this.registerGitHubTokenProvider(config.gitHubTokenProvider, sessionId);",
    "this.commitGitHubTokenProvider(sessionId, gitHubTokenProviderRegistrationId);",
  ], `${authority.name} resumeSessionInternal GitHub token lifecycle`);

  const optionsUpdate = findFunctionLike(
    clientSource,
    "updateSessionOptionsForMode",
    `${authority.name} updateSessionOptionsForMode`,
  );
  requireExactStrings(
    contract.lifecycle.postLifecycleUpdate,
    ["coauthorEnabled", "manageScheduleEnabled"],
    `${authority.name} post-lifecycle option inventory`,
  );
  requireAstNodes(optionsUpdate.node, optionsUpdate.sourceFile, [
    "patch.coauthorEnabled = config.coauthorEnabled ?? false",
    "patch.manageScheduleEnabled = config.manageScheduleEnabled ?? false",
    "patch.coauthorEnabled = config.coauthorEnabled",
    "patch.manageScheduleEnabled = config.manageScheduleEnabled",
    "await session.rpc.options.update(patch)",
  ], `${authority.name} post-lifecycle option lowering`);
  for (const field of contract.lifecycle.postLifecycleUpdate) {
    assert(
      createRequest.properties[field] === undefined &&
        resumeRequest.properties[field] === undefined,
      `${authority.name} ${field} must remain post-lifecycle only`,
    );
  }

  const globalHandlers = findFunctionLike(
    clientSource,
    "setupClientGlobalHandlers",
    `${authority.name} client-global callback setup`,
  );
  requireObjectAssignment(
    globalHandlers.node,
    globalHandlers.sourceFile,
    "handlers.gitHubToken",
    "getToken",
    "this.acquireGitHubToken",
    `${authority.name} client-global callback setup`,
  );
  const directCallbacks = findFunctionLike(
    clientSource,
    "attachConnectionHandlers",
    `${authority.name} direct callback setup`,
  );
  const directRegistrations = registeredStringCallbacks(
    directCallbacks.node,
    directCallbacks.sourceFile,
    "this.connection.onRequest",
    `${authority.name} direct callback setup`,
  );
  for (const [method, callee] of [
    ["exitPlanMode.request", "this.handleExitPlanModeRequest"],
    ["autoModeSwitch.request", "this.handleAutoModeSwitchRequest"],
  ]) {
    const callback = directRegistrations.get(method);
    assert(
      callback !== undefined,
      `upstream ${authority.name} direct callback setup is missing ${method}`,
    );
    requireCallbackReturnsCall(
      callback,
      directCallbacks.sourceFile,
      callee,
      "params",
      `${authority.name} ${method} callback`,
    );
  }
  const broadcastCallbacks = findFunctionLike(
    sessionSource,
    "_handleBroadcastEvent",
    `${authority.name} session event callback setup`,
  );
  requireAstNodes(broadcastCallbacks.node, broadcastCallbacks.sourceFile, [
    "this._executeCommandAndRespond(requestId, commandName, command, args)",
  ], `${authority.name} session event callback setup`);
  const elicitationBranch = eventTypeBranch(
    broadcastCallbacks.node,
    broadcastCallbacks.sourceFile,
    "elicitation.requested",
    `${authority.name} elicitation event dispatch`,
  );
  const elicitationCall = requireCallOutsideNestedFunctions(
    elicitationBranch,
    broadcastCallbacks.sourceFile,
    "this._handleElicitationRequest",
    `${authority.name} elicitation event dispatch`,
  );
  assert(
    compactNode(elicitationCall, broadcastCallbacks.sourceFile) ===
      'this._handleElicitationRequest({sessionId:this.sessionId,message,requestedSchema:requestedSchemaasElicitationContext["requestedSchema"],mode,elicitationSource,url,},requestId)',
    `upstream ${authority.name} elicitation event dispatch arguments changed`,
  );
  requireStringLiterals(
    broadcastCallbacks.node,
    ["command.execute"],
    `${authority.name} session event callback setup`,
  );
  const commandResponder = findFunctionLike(
    sessionSource,
    "_executeCommandAndRespond",
    `${authority.name} command response`,
  );
  requireCalls(
    commandResponder.node,
    commandResponder.sourceFile,
    ["this.rpc.commands.handlePendingCommand"],
    `${authority.name} command response`,
  );
  const interactionCallbacks = findFunctionLike(
    sessionSource,
    "registerCommands",
    `${authority.name} session interaction callbacks`,
  );
  const elicitationHandler = findFunctionLike(
    sessionSource,
    "registerElicitationHandler",
    `${authority.name} elicitation callback`,
  );
  const exitPlanHandler = findFunctionLike(
    sessionSource,
    "registerExitPlanModeHandler",
    `${authority.name} exit-plan callback`,
  );
  const autoModeHandler = findFunctionLike(
    sessionSource,
    "registerAutoModeSwitchHandler",
    `${authority.name} auto-mode callback`,
  );
  requireAstNodes(interactionCallbacks.node, interactionCallbacks.sourceFile, [
    "this.commandHandlers.set(cmd.name, cmd.handler)",
  ], `${authority.name} command callbacks`);
  requireAstNodes(elicitationHandler.node, elicitationHandler.sourceFile, [
    "this.elicitationHandler = handler",
  ], `${authority.name} elicitation callback`);
  const elicitationResponder = findFunctionLike(
    sessionSource,
    "_handleElicitationRequest",
    `${authority.name} elicitation response`,
  );
  requireCalls(
    elicitationResponder.node,
    elicitationResponder.sourceFile,
    ["this.rpc.ui.handlePendingElicitation"],
    `${authority.name} elicitation response`,
  );
  requireAstNodes(exitPlanHandler.node, exitPlanHandler.sourceFile, [
    "this.exitPlanModeHandler = handler",
  ], `${authority.name} exit-plan callback`);
  requireAstNodes(autoModeHandler.node, autoModeHandler.sourceFile, [
    "this.autoModeSwitchHandler = handler",
  ], `${authority.name} auto-mode callback`);
  const assertElicitation = findFunctionLike(
    sessionSource,
    "assertElicitation",
    `${authority.name} session UI helpers`,
  );
  requireAstNodes(assertElicitation.node, assertElicitation.sourceFile, [
    "this._capabilities.ui?.elicitation",
  ], `${authority.name} session UI capability`);
  for (const helper of ["_elicitation", "_confirm", "_select", "_input"]) {
    const method = findFunctionLike(sessionSource, helper, `${authority.name} ${helper}`);
    requireAstNodes(method.node, method.sourceFile, [
      "this.rpc.ui.elicitation",
    ], `${authority.name} ${helper}`);
  }
}

function verifyStableParitySchema(schema, eventsSchema) {
  const methods = collectPropertyValues(schema, "rpcMethod");
  for (const method of [
    "gitHubToken.getToken",
    "session.commands.handlePendingCommand",
    "session.ui.elicitation",
    "session.ui.handlePendingElicitation",
    "session.options.update",
  ]) {
    assert(methods.has(method), `stable parity RPC method is missing: ${method}`);
  }
  requireExactStrings(
    stringEnum(schema, "GitHubTokenAcquireReason"),
    ["initial", "refresh"],
    "GitHubTokenAcquireReason",
  );
  const tokenResult = schema.definitions?.GitHubTokenAcquireResult;
  assert(
    JSON.stringify(schemaValidationShape(tokenResult)) === JSON.stringify(
      schemaValidationShape({
        anyOf: [
          {
            type: "object",
            properties: {
              accessToken: { type: "string" },
              tokenType: { type: "string" },
              expiresIn: { type: "integer", minimum: 3601 },
              kind: { type: "string", const: "token" },
            },
            required: ["kind", "accessToken", "expiresIn"],
          },
          {
            type: "object",
            properties: {
              kind: { type: "string", const: "cancelled" },
            },
            required: ["kind"],
          },
        ],
      }),
    ),
    "GitHubTokenAcquireResult validation contract changed",
  );
  const events = eventDiscriminators(eventsSchema);
  for (const event of [
    "command.execute",
    "elicitation.requested",
    "exit_plan_mode.requested",
    "auto_mode_switch.requested",
    "session.workspace_file_changed",
    "session.schedule_created",
    "session.schedule_rearmed",
    "session.schedule_cancelled",
  ]) {
    assert(events.has(event), `stable parity event is missing: ${event}`);
  }
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
  const autoTiers = ["balance", "efficiency", "fast", "intelligence"];
  requireExactStrings(stringEnum(apiSchema, "AutoTier"), autoTiers, "API AutoTier enum");
  requireExactStrings(stringEnum(eventSchema, "AutoTier"), autoTiers, "event AutoTier enum");
  for (const contract of [
    {
      schema: "SessionFsSetProviderConventions",
      zig: "SessionFilesystemConventions",
      tags: ["posix", "windows"],
    },
    {
      schema: "SessionFsReaddirWithTypesEntryType",
      zig: "SessionFilesystemEntryType",
      tags: ["file", "directory"],
    },
    {
      schema: "SessionFsSqliteQueryType",
      zig: "SessionFilesystemSqliteQueryType",
      tags: ["exec", "query", "run"],
    },
  ]) {
    requireExactStrings(
      stringEnum(apiSchema, contract.schema),
      contract.tags,
      `${contract.schema} values`,
    );
    requireExactStrings(
      zigEnumValues(zigRuntimeSource, contract.zig),
      contract.tags,
      `Zig ${contract.zig} values`,
    );
  }
  for (const contract of [
    {
      schema: "RemoteSessionMode",
      zig: "RemoteSessionMode",
      tags: ["off", "export", "on"],
    },
    {
      schema: "UIAutoModeSwitchResponse",
      zig: "AutoModeSwitchResponse",
      tags: ["yes", "yes_always", "no"],
    },
    {
      schema: "UIExitPlanModeAction",
      zig: "ExitPlanModeAction",
      tags: ["exit_only", "interactive", "autopilot", "autopilot_fleet"],
    },
  ]) {
    requireExactStrings(
      stringEnum(apiSchema, contract.schema),
      contract.tags,
      `${contract.schema} values`,
    );
    requireExactStrings(
      zigEnumValues(zigSessionSource, contract.zig),
      contract.tags,
      `Zig ${contract.zig} values`,
    );
  }
  requireExactStrings(
    stringEnum(apiSchema, "SessionFsSqliteTransactionErrorClass"),
    ["busyOrLocked", "fatal", "postCommitAmbiguous"],
    "SessionFsSqliteTransactionErrorClass values",
  );
  requireExactStrings(
    zigEnumValues(zigRuntimeSource, "SessionFilesystemSqliteTransactionErrorClass"),
    ["busyOrLocked", "fatal", "postCommitAmbiguous"],
    "Zig SessionFilesystemSqliteTransactionErrorClass values",
  );
  requireExactStrings(
    stringEnum(apiSchema, "SessionFsErrorCode"),
    ["ENOENT", "UNKNOWN"],
    "SessionFsErrorCode values",
  );
  requireExactStrings(
    zigEnumValues(clientSource, "SessionFilesystemErrorCode", {
      visibility: "optional",
    }),
    ["ENOENT", "UNKNOWN"],
    "Zig SessionFilesystemErrorCode values",
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
  generateSessionEvents({ check: true });
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
  const stableParity = parseJson(stableParityContractPath);
  assert(
    JSON.stringify(stableParity) === JSON.stringify(expectedStableParityContract(metadata.upstreamCommit)),
    "stable parity contract is stale",
  );
  verifyStableParitySchema(schemas["api.schema.json"], schemas["session-events.schema.json"]);
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
  const [
    protocol,
    packageManifest,
    lock,
    nodeClient,
    nodeSession,
    nodeTypes,
    nodeExtension,
    publicClient,
    publicSession,
    publicTypes,
    publicExtension,
  ] = await Promise.all([
    fetchJson(rawUrl(commit, "sdk-protocol-version.json")),
    fetchJson(rawUrl(commit, "nodejs/package.json")),
    fetchJson(rawUrl(commit, "nodejs/package-lock.json")),
    fetchText(rawUrl(commit, "nodejs/src/client.ts")),
    fetchText(rawUrl(commit, "nodejs/src/session.ts")),
    fetchText(rawUrl(commit, "nodejs/src/types.ts")),
    fetchText(rawUrl(commit, "nodejs/src/extension.ts")),
    fetchText(rawUrl(publicSdkCommit, "nodejs/src/client.ts")),
    fetchText(rawUrl(publicSdkCommit, "nodejs/src/session.ts")),
    fetchText(rawUrl(publicSdkCommit, "nodejs/src/types.ts")),
    fetchText(rawUrl(publicSdkCommit, "nodejs/src/extension.ts")),
  ]);
  const cliPackageVersion =
    packageManifest.copilotCliVersion ??
    lock.packages?.["node_modules/@github/copilot"]?.version;
  assert(Number.isSafeInteger(protocol.version), "upstream protocol version is invalid");
  assert(
    /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(cliPackageVersion),
    "upstream package manifest has no exact Copilot CLI version",
  );
  verifyPinnedSourceContracts(
    commit,
    nodeClient,
    nodeTypes,
    nodeExtension,
    publicTypes,
  );
  verifyStableParitySourceContract(
    { name: "protocol commit", commit },
    nodeClient,
    nodeSession,
    nodeTypes,
    nodeExtension,
  );
  verifyStableParitySourceContract(
    { name: "public SDK commit", commit: publicSdkCommit },
    publicClient,
    publicSession,
    publicTypes,
    publicExtension,
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
    writeFileSync(
      stableParityContractPath,
      `${JSON.stringify(expectedStableParityContract(commit), null, 2)}\n`,
    );
    writeSchemaSnapshot();
    generateSessionEvents();
  } finally {
    rmSync(workDirectory, { force: true, recursive: true });
  }

  verify();
}

const args = process.argv.slice(2);
if (args.includes("--check")) {
  assert(args.length === 1, "--check does not accept other arguments");
  const metadata = parseJson(metadataPath);
  validateMetadata(metadata);
  const [
    nodeClient,
    nodeSession,
    nodeTypes,
    nodeExtension,
    publicClient,
    publicSession,
    publicTypes,
    publicExtension,
  ] = await Promise.all([
    fetchText(rawUrl(metadata.upstreamCommit, "nodejs/src/client.ts")),
    fetchText(rawUrl(metadata.upstreamCommit, "nodejs/src/session.ts")),
    fetchText(rawUrl(metadata.upstreamCommit, "nodejs/src/types.ts")),
    fetchText(rawUrl(metadata.upstreamCommit, "nodejs/src/extension.ts")),
    fetchText(rawUrl(publicSdkCommit, "nodejs/src/client.ts")),
    fetchText(rawUrl(publicSdkCommit, "nodejs/src/session.ts")),
    fetchText(rawUrl(publicSdkCommit, "nodejs/src/types.ts")),
    fetchText(rawUrl(publicSdkCommit, "nodejs/src/extension.ts")),
  ]);
  verifyPinnedSourceContracts(
    metadata.upstreamCommit,
    nodeClient,
    nodeTypes,
    nodeExtension,
    publicTypes,
  );
  verifyStableParitySourceContract(
    { name: "protocol commit", commit: metadata.upstreamCommit },
    nodeClient,
    nodeSession,
    nodeTypes,
    nodeExtension,
  );
  verifyStableParitySourceContract(
    { name: "public SDK commit", commit: publicSdkCommit },
    publicClient,
    publicSession,
    publicTypes,
    publicExtension,
  );
  verify();
} else {
  const commitIndex = args.indexOf("--commit");
  const explicitCommit = commitIndex === -1 ? undefined : args[commitIndex + 1];
  const ifPublished = args.length === 1 && args[0] === "--if-published";
  assert(ifPublished || args.length === (explicitCommit ? 2 : 0), "usage: npm run sync -- [--commit <sha> | --if-published]");
  await synchronize(explicitCommit, ifPublished);
}
