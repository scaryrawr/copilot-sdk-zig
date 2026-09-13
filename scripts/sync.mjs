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
import { generateSessionEvents } from "./generate-session-events.mjs";
import {
  exportedStringUnionValues,
  inheritedInterfacePropertySignatures,
  interfaceBase,
  interfaceMemberSignatures,
  interfacePropertySignatures,
  omitIntersectionAlias,
  plainOmitAlias,
  requireExactInterfaceSignatures,
  requireExactPropertySignatures,
  requireExactTypeImportBinding,
  requireSourceFragments,
  sourceSection,
  zigEnumValues,
  zigStructFields,
} from "./source-contract.mjs";

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
  },
};

const expectedJoinSessionTypeScriptContract = {
  base: "ResumeSessionConfig",
  excluded: ["onPermissionRequest", "extensionSdkPath"],
  properties: {
    onPermissionRequest: "optional:PermissionHandler",
    requestedEnvironmentVariables: "optional:string[]",
    factories: "optional:FactoryHandle[]",
  },
};

const expectedSessionRuntimeTypeScriptContract = {
  fields: {
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
    createSessionFsProvider:
      "optional:(session:CopilotSession)=>SessionFsProvider",
  },
  largeOutput: {
    enabled: "optional:boolean",
    maxSizeBytes: "optional:number",
    outputDirectory: "optional:string",
  },
  infiniteSessions: {
    enabled: "optional:boolean",
    backgroundCompactionThreshold: "optional:number",
    bufferExhaustionThreshold: "optional:number",
  },
  memory: {
    enabled: "required:boolean",
  },
  capi: {
    autoTier: "optional:AutoTier",
    enableWebSocketResponses: "optional:boolean",
  },
  lowering: [
    "clientName: config.clientName",
    "reasoningEffort: config.reasoningEffort",
    "reasoningSummary: config.reasoningSummary",
    "isExperimentalMode: this.experimentalModeForMode(config.enableExperimentalMode)",
    "contextTier: config.contextTier",
    "largeOutput: toWireLargeOutput(config.largeOutput)",
    "configDir: config.configDirectory",
    "capi: config.capi",
    "additionalDirectories: config.additionalDirectories",
    "infiniteSessions: config.infiniteSessions",
    "memory: config.memory",
    "skipEmbeddingRetrieval: config.skipEmbeddingRetrieval",
    "embeddingCacheStorage: config.embeddingCacheStorage",
    "organizationCustomInstructions: config.organizationCustomInstructions",
    "enableFileHooks: config.enableFileHooks",
    "enableHostGitOperations: config.enableHostGitOperations",
    "enableSessionStore: config.enableSessionStore",
  ],
};

const expectedSessionRuntimeZigContract = {
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
  create_session_fs_provider: {
    type: "?SessionFsProviderFactory",
    default: "null",
  },
};

const expectedLifecycleBaseTypeScriptContract = {
  onMcpAuthRequest: "optional:McpAuthHandler",
  pluginDirectories: "optional:string[]",
  skillDirectories: "optional:string[]",
  disabledSkills: "optional:string[]",
  includedBuiltinSkills: "optional:string[]",
  enableSkills: "optional:boolean",
  hooks: "optional:SessionHooks",
  mcpServers: "optional:Record<string,MCPServerConfig>",
  mcpOAuthTokenStorage: 'optional:"persistent"|"in-memory"',
  authClientIdMetadataUrl: "optional:string",
  disabledMcpServers: "optional:string[]",
  canvases: "optional:Canvas[]",
  requestCanvasRenderer: "optional:boolean",
  requestExtensions: "optional:boolean",
  extensionSdkPath: "optional:string",
  extensionInfo: "optional:ExtensionInfo",
  canvasProvider: "optional:CanvasProviderIdentity",
  enableMcpApps: "optional:boolean",
};

const expectedExistingSessionConfigBaseTypeScriptContract = {
  model: "optional:string",
  modelCapabilities: "optional:ModelCapabilitiesOverride",
  enableConfigDiscovery: "optional:boolean",
  tools: "optional:Tool<any>[]",
  commands: "optional:CommandDefinition[]",
  systemMessage: "optional:SystemMessageConfig",
  toolSearch: "optional:ToolSearchConfig",
  availableTools: "optional:string[]|ToolSet",
  excludedTools: "optional:string[]|ToolSet",
  provider: "optional:ProviderConfig",
  providers: "optional:NamedProviderConfig[]",
  models: "optional:ProviderModelConfig[]",
  enableSessionTelemetry: "optional:boolean",
  enableCitations: "optional:boolean",
  enableFileChangeTracking: "optional:boolean",
  sessionLimits: "optional:SessionLimitsConfig",
  skipCustomInstructions: "optional:boolean",
  coauthorEnabled: "optional:boolean",
  manageScheduleEnabled: "optional:boolean",
  onPermissionRequest: "optional:PermissionHandler",
  onUserInputRequest: "optional:UserInputHandler",
  askUserVariant: "optional:AskUserVariant",
  onElicitationRequest: "optional:ElicitationHandler",
  githubMcpToolConfig: "optional:GitHubMcpToolConfig",
  onExitPlanModeRequest: "optional:ExitPlanModeHandler",
  onAutoModeSwitchRequest: "optional:AutoModeSwitchHandler",
  workingDirectory: "optional:string",
  streaming: "optional:boolean",
  includeSubAgentStreamingEvents: "optional:boolean",
  instructionDirectories: "optional:string[]",
  gitHubToken: "optional:string",
  gitHubTokenProvider: "optional:GitHubTokenProvider",
  enableManagedSettings: "optional:boolean",
  managedSettings: "optional:ManagedSettings",
  enableOnDemandInstructionDiscovery: "optional:boolean",
  remoteSession: "optional:RemoteSessionMode",
  onEvent: "optional:SessionEventHandler",
  featureFlags: "optional:Record<string,boolean>",
  expAssignments: "optional:CopilotExpAssignmentResponse",
};

const expectedSessionConfigBaseTypeScriptContract = {
  ...expectedExistingSessionConfigBaseTypeScriptContract,
  ...expectedSessionRuntimeTypeScriptContract.fields,
  ...expectedCustomAgentSourceContract.lifecycle.base,
  ...expectedLifecycleBaseTypeScriptContract,
};

const expectedInheritedSessionTypeScriptContract = {
  SessionConfig: {
    sessionId: "optional:string",
    cloud: "optional:CloudSessionOptions",
  },
  ResumeSessionConfig: {
    suppressResumeEvent: "optional:boolean",
    continuePendingWork: "optional:boolean",
    openCanvases: "optional:OpenCanvasInstance[]",
  },
};

const expectedSessionFsStringUnionContract = {
  SessionFsErrorCode: ["ENOENT", "UNKNOWN"],
  SessionFsReaddirWithTypesEntryType: ["file", "directory"],
  SessionFsSetProviderConventions: ["windows", "posix"],
  SessionFsSqliteQueryType: ["exec", "query", "run"],
  SessionFsSqliteTransactionErrorClass: [
    "busyOrLocked",
    "fatal",
    "postCommitAmbiguous",
  ],
};

const sessionFsQueryWireToZig = {
  exec: "exec",
  query: "query",
  run: "run",
};

const sessionFsTransactionWireToZig = {
  busyOrLocked: "busy_or_locked",
  fatal: "fatal",
  postCommitAmbiguous: "post_commit_ambiguous",
};

function parseSessionSourceContract(extensionSource, sessionSource) {
  return {
    join: omitIntersectionAlias(extensionSource, "JoinSessionConfig"),
    zig: {
      create: zigStructFields(sessionSource, "CreateSessionConfig"),
      resume: zigStructFields(sessionSource, "ResumeSessionConfig"),
      join: zigStructFields(sessionSource, "JoinSessionConfig"),
    },
  };
}

function verifyPinnedSourceContracts({
  upstreamCommit,
  clientSource,
  typesSource,
  extensionSource,
  rpcSource,
  sessionFsProviderSource,
}) {
  const sourceContract = parseSessionSourceContract(
    extensionSource,
    zigSessionSource,
  );
  verifyCustomAgentSourceContract(
    clientSource,
    typesSource,
    zigSessionSource,
  );
  verifySessionRuntimeSourceContract(clientSource, typesSource, sourceContract);
  verifySessionFsSourceContract(
    clientSource,
    typesSource,
    rpcSource,
    sessionFsProviderSource,
  );
  verifyExtensibilitySourceContract(
    expectedExtensibilityContract(upstreamCommit),
    clientSource,
    typesSource,
    sourceContract,
  );
}

function verifyJoinSessionSourceContract(join, lifecycle) {
  const expected = expectedJoinSessionTypeScriptContract;
  assert(join.base === expected.base, "JoinSessionConfig base changed");
  requireExactStrings(
    join.excluded,
    expected.excluded,
    "JoinSessionConfig exclusions",
  );
  requireExactPropertySignatures(
    join.properties,
    expected.properties,
    "JoinSessionConfig",
  );
  for (const field of lifecycle.redeclared) {
    assert(
      join.excluded.includes(field),
      `JoinSessionConfig redeclared field is not omitted: ${field}`,
    );
    assert(
      Object.hasOwn(join.properties, field),
      `JoinSessionConfig omitted field is not redeclared: ${field}`,
    );
  }
  for (const field of lifecycle.omitted) {
    assert(
      join.excluded.includes(field),
      `JoinSessionConfig permanently omitted field is not omitted: ${field}`,
    );
    assert(
      !Object.hasOwn(join.properties, field),
      `JoinSessionConfig permanently omitted field is redeclared: ${field}`,
    );
  }
}

function verifyCustomAgentSourceContract(
  clientSource,
  typesSource,
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

  assert(
    interfaceBase(typesSource, "SessionConfig") === expected.lifecycle.createExtends,
    "upstream SessionConfig inheritance changed",
  );
  assert(
    interfaceBase(typesSource, "ResumeSessionConfig") === expected.lifecycle.resumeExtends,
    "upstream ResumeSessionConfig inheritance changed",
  );
  const customAgentLowering = sourceSection(
    clientSource,
    "function toWireCustomAgents(",
    "function clientInfoToWire(",
    "toWireCustomAgents",
  );
  requireSourceFragments(
    customAgentLowering,
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

function verifySessionFsSourceContract(
  clientSource,
  typesSource,
  rpcSource,
  sessionFsProviderSource,
) {
  const fileInfo = plainOmitAlias(
    sessionFsProviderSource,
    "SessionFsFileInfo",
  );
  assert(
    fileInfo.base === "SessionFsStatResult",
    "SessionFsFileInfo base changed",
  );
  requireExactStrings(
    fileInfo.excluded,
    ["error"],
    "SessionFsFileInfo exclusions",
  );

  const sqliteQueryResult = plainOmitAlias(
    sessionFsProviderSource,
    "SessionFsSqliteQueryResult",
  );
  assert(
    sqliteQueryResult.base === "GeneratedSqliteQueryResult",
    "SessionFsSqliteQueryResult base changed",
  );
  requireExactStrings(
    sqliteQueryResult.excluded,
    ["error"],
    "SessionFsSqliteQueryResult exclusions",
  );
  requireExactTypeImportBinding(
    sessionFsProviderSource,
    {
      imported: "SessionFsSqliteQueryResult",
      local: "GeneratedSqliteQueryResult",
      module: "./generated/rpc.js",
    },
    "SessionFS provider generated SQLite result import",
  );

  const aliases = Object.fromEntries(
    Object.keys(expectedSessionFsStringUnionContract).map((name) => [
      name,
      exportedStringUnionValues(rpcSource, name),
    ]),
  );
  for (const [name, expected] of Object.entries(
    expectedSessionFsStringUnionContract,
  )) {
    requireExactStrings(aliases[name], expected, `upstream ${name} values`);
  }
  requireExactStrings(
    aliases.SessionFsReaddirWithTypesEntryType,
    zigEnumValues(zigSessionSource, "SessionFsEntryType"),
    "SessionFS entry type values",
  );
  requireExactStrings(
    aliases.SessionFsSetProviderConventions,
    zigEnumValues(zigSessionSource, "SessionFsConventions"),
    "SessionFS convention values",
  );
  requireExactStrings(
    Object.keys(sessionFsQueryWireToZig),
    aliases.SessionFsSqliteQueryType,
    "SessionFS SQLite query wire mapping keys",
  );
  requireExactStrings(
    aliases.SessionFsSqliteQueryType.map(
      (value) => sessionFsQueryWireToZig[value],
    ),
    zigEnumValues(zigSessionSource, "SessionFsSqliteQueryType"),
    "SessionFS SQLite query type values",
  );
  requireExactStrings(
    Object.keys(sessionFsTransactionWireToZig),
    aliases.SessionFsSqliteTransactionErrorClass,
    "SessionFS transaction wire mapping keys",
  );
  requireExactStrings(
    aliases.SessionFsSqliteTransactionErrorClass.map(
      (value) => sessionFsTransactionWireToZig[value],
    ),
    zigEnumValues(zigSessionSource, "SessionFsSqliteTransactionErrorClass"),
    "SessionFS transaction error class values",
  );

  requireExactPropertySignatures(
    interfacePropertySignatures(typesSource, "SessionFsConfig"),
    {
      initialCwd: "required:string",
      sessionStatePath: "required:string",
      conventions: 'required:"windows"|"posix"',
      capabilities: "optional:{sqlite?:boolean;}",
    },
    "SessionFsConfig",
  );
  requireSourceFragments(
    typesSource,
    ["sessionFs?: SessionFsConfig"],
    "CopilotClientOptions",
  );
  requireSourceFragments(
    clientSource,
    [
      "this.sessionFsConfig = options.sessionFs ?? null",
      'await this.connection!.sendRequest("sessionFs.setProvider", {',
      "initialCwd: this.sessionFsConfig.initialCwd",
      "sessionStatePath: this.sessionFsConfig.sessionStatePath",
      "conventions: this.sessionFsConfig.conventions",
      "capabilities: this.sessionFsConfig.capabilities",
      "if (!config.createSessionFsProvider)",
      "this.sessionFsConfig.capabilities?.sqlite && !provider.sqlite",
    ],
    "SessionFS client lifecycle",
  );

  requireExactInterfaceSignatures(
    interfaceMemberSignatures(rpcSource, "SessionFsHandler"),
    {
      methods: {
        readFile:
          "required:(params:SessionFsReadFileRequest)=>Promise<SessionFsReadFileResult>",
        writeFile:
          "required:(params:SessionFsWriteFileRequest)=>Promise<SessionFsError|undefined>",
        appendFile:
          "required:(params:SessionFsAppendFileRequest)=>Promise<SessionFsError|undefined>",
        exists:
          "required:(params:SessionFsExistsRequest)=>Promise<SessionFsExistsResult>",
        stat:
          "required:(params:SessionFsStatRequest)=>Promise<SessionFsStatResult>",
        mkdir:
          "required:(params:SessionFsMkdirRequest)=>Promise<SessionFsError|undefined>",
        readdir:
          "required:(params:SessionFsReaddirRequest)=>Promise<SessionFsReaddirResult>",
        readdirWithTypes:
          "required:(params:SessionFsReaddirWithTypesRequest)=>Promise<SessionFsReaddirWithTypesResult>",
        rm:
          "required:(params:SessionFsRmRequest)=>Promise<SessionFsError|undefined>",
        rename:
          "required:(params:SessionFsRenameRequest)=>Promise<SessionFsError|undefined>",
        sqliteQuery:
          "required:(params:SessionFsSqliteQueryRequest)=>Promise<SessionFsSqliteQueryResult>",
        sqliteTransaction:
          "required:(params:SessionFsSqliteTransactionRequest)=>Promise<SessionFsSqliteTransactionResult>",
        sqliteExists:
          "required:(params:SessionFsSqliteExistsRequest)=>Promise<SessionFsSqliteExistsResult>",
      },
      properties: {},
    },
    "SessionFsHandler",
  );

  const rpcProperties = {
    SessionFsAppendFileRequest: {
      sessionId: "required:string",
      path: "required:string",
      content: "required:string",
      mode: "optional:number",
    },
    SessionFsError: {
      code: "required:SessionFsErrorCode",
      message: "optional:string",
    },
    SessionFsExistsRequest: {
      sessionId: "required:string",
      path: "required:string",
    },
    SessionFsExistsResult: {
      exists: "required:boolean",
    },
    SessionFsMkdirRequest: {
      sessionId: "required:string",
      path: "required:string",
      recursive: "optional:boolean",
      mode: "optional:number",
    },
    SessionFsReaddirRequest: {
      sessionId: "required:string",
      path: "required:string",
    },
    SessionFsReaddirResult: {
      entries: "required:string[]",
      error: "optional:SessionFsError",
    },
    SessionFsReaddirWithTypesEntry: {
      name: "required:string",
      type: "required:SessionFsReaddirWithTypesEntryType",
    },
    SessionFsReaddirWithTypesRequest: {
      sessionId: "required:string",
      path: "required:string",
    },
    SessionFsReaddirWithTypesResult: {
      entries: "required:SessionFsReaddirWithTypesEntry[]",
      error: "optional:SessionFsError",
    },
    SessionFsReadFileRequest: {
      sessionId: "required:string",
      path: "required:string",
    },
    SessionFsReadFileResult: {
      content: "required:string",
      error: "optional:SessionFsError",
    },
    SessionFsRenameRequest: {
      sessionId: "required:string",
      src: "required:string",
      dest: "required:string",
    },
    SessionFsRmRequest: {
      sessionId: "required:string",
      path: "required:string",
      recursive: "optional:boolean",
      force: "optional:boolean",
    },
    SessionFsSetProviderCapabilities: {
      sqlite: "optional:boolean",
    },
    SessionFsSetProviderRequest: {
      initialCwd: "required:string",
      sessionStatePath: "required:string",
      conventions: "required:SessionFsSetProviderConventions",
      capabilities: "optional:SessionFsSetProviderCapabilities",
    },
    SessionFsSetProviderResult: {
      success: "required:boolean",
    },
    SessionFsSqliteExistsRequest: {
      sessionId: "required:string",
    },
    SessionFsSqliteExistsResult: {
      exists: "required:boolean",
    },
    SessionFsSqliteQueryRequest: {
      sessionId: "required:string",
      query: "required:string",
      queryType: "required:SessionFsSqliteQueryType",
      params: "optional:{[k:string]:JsonValue|undefined;}",
    },
    SessionFsSqliteQueryResult: {
      rows: "required:{[k:string]:JsonValue|undefined;}[]",
      columns: "required:string[]",
      rowsAffected: "required:number",
      lastInsertRowid: "optional:number",
      error: "optional:SessionFsError",
    },
    SessionFsSqliteTransactionError: {
      errorClass: "required:SessionFsSqliteTransactionErrorClass",
      message: "required:string",
    },
    SessionFsSqliteTransactionRequest: {
      sessionId: "required:string",
      statements: "required:SessionFsSqliteTransactionStatement[]",
    },
    SessionFsSqliteTransactionStatement: {
      query: "required:string",
      queryType: "required:SessionFsSqliteQueryType",
      params: "optional:{[k:string]:JsonValue|undefined;}",
    },
    SessionFsSqliteTransactionResult: {
      results: "required:SessionFsSqliteQueryResult[]",
      error: "optional:SessionFsSqliteTransactionError",
    },
    SessionFsStatRequest: {
      sessionId: "required:string",
      path: "required:string",
    },
    SessionFsStatResult: {
      isFile: "required:boolean",
      isDirectory: "required:boolean",
      size: "required:number",
      mtime: "required:string",
      birthtime: "required:string",
      error: "optional:SessionFsError",
    },
    SessionFsWriteFileRequest: {
      sessionId: "required:string",
      path: "required:string",
      content: "required:string",
      mode: "optional:number",
    },
  };
  for (const [name, expected] of Object.entries(rpcProperties)) {
    requireExactPropertySignatures(
      interfacePropertySignatures(rpcSource, name),
      expected,
      name,
    );
  }

  requireExactInterfaceSignatures(
    interfaceMemberSignatures(
      sessionFsProviderSource,
      "SessionFsSqliteProvider",
    ),
    {
      methods: {
        query:
          "required:(queryType:SessionFsSqliteQueryType,query:string,params?:Record<string,string|number|null>)=>Promise<SessionFsSqliteQueryResult|undefined>",
        transaction:
          "optional:(statements:SessionFsSqliteStatement[])=>Promise<SessionFsSqliteQueryResult[]>",
        exists: "required:()=>Promise<boolean>",
      },
      properties: {},
    },
    "SessionFsSqliteProvider",
  );

  requireExactPropertySignatures(
    zigStructFields(zigSessionSource, "SessionFsStat", { allowMethods: true }),
    {
      is_file: { type: "bool", default: null },
      is_directory: { type: "bool", default: null },
      size: { type: "u64", default: null },
      mtime: { type: "[]u8", default: null },
      birthtime: { type: "[]u8", default: null },
    },
    "Zig SessionFsStat",
  );
  requireExactPropertySignatures(
    zigStructFields(zigSessionSource, "SessionFsSqliteQueryResult", {
      allowMethods: true,
    }),
    {
      rows: { type: "[]SessionFsSqliteRow", default: null },
      columns: { type: "SessionFsOwnedStrings", default: null },
      rows_affected: { type: "u64", default: null },
      last_insert_rowid: { type: "?i64", default: "null" },
    },
    "Zig SessionFsSqliteQueryResult",
  );
  const sqliteProviderVTableSource = sourceSection(
    zigSessionSource,
    "    pub const VTable = struct {",
    "pub const SessionFsProvider = struct {",
    "Zig SessionFsSqliteProvider.VTable",
  );
  requireExactPropertySignatures(
    zigStructFields(sqliteProviderVTableSource, "VTable"),
    {
      query: {
        type: "*const fn(allocator:std.mem.Allocator,query_type:SessionFsSqliteQueryType,query:[]const u8,params:?[]const SessionFsSqliteParameter,context:?*anyopaque,)anyerror!?SessionFsSqliteQueryResult",
        default: null,
      },
      transaction: {
        type: "?*const fn(allocator:std.mem.Allocator,statements:[]const SessionFsSqliteStatement,context:?*anyopaque,)anyerror!SessionFsSqliteTransactionOutcome",
        default: "null",
      },
      exists: {
        type: "*const fn(context:?*anyopaque)anyerror!bool",
        default: null,
      },
    },
    "Zig SessionFsSqliteProvider.VTable",
  );
  requireExactInterfaceSignatures(
    interfaceMemberSignatures(sessionFsProviderSource, "SessionFsProvider"),
    {
      methods: {
        readFile: "required:(path:string)=>Promise<string>",
        writeFile:
          "required:(path:string,content:string,mode?:number)=>Promise<void>",
        appendFile:
          "required:(path:string,content:string,mode?:number)=>Promise<void>",
        exists: "required:(path:string)=>Promise<boolean>",
        stat: "required:(path:string)=>Promise<SessionFsFileInfo>",
        mkdir:
          "required:(path:string,recursive:boolean,mode?:number)=>Promise<void>",
        readdir: "required:(path:string)=>Promise<string[]>",
        readdirWithTypes:
          "required:(path:string)=>Promise<SessionFsReaddirWithTypesEntry[]>",
        rm:
          "required:(path:string,recursive:boolean,force:boolean)=>Promise<void>",
        rename: "required:(src:string,dest:string)=>Promise<void>",
      },
      properties: {
        sqlite: "optional:SessionFsSqliteProvider",
      },
    },
    "SessionFsProvider",
  );
  requireExactPropertySignatures(
    interfacePropertySignatures(
      sessionFsProviderSource,
      "SessionFsSqliteStatement",
    ),
    {
      queryType: "required:SessionFsSqliteQueryType",
      query: "required:string",
      params: "optional:Record<string,string|number|null>",
    },
    "SessionFsSqliteStatement",
  );
  requireSourceFragments(
    sessionFsProviderSource,
    [
      "sqliteQuery: async",
      "sqliteTransaction: async",
      "sqliteExists: async",
      'const code = e.code === "ENOENT" ? "ENOENT" : "UNKNOWN"',
      'errorClass: "fatal"',
      "return result ?? { rows: [], columns: [], rowsAffected: 0 }",
    ],
    "SessionFS adapter",
  );
  requireExactStrings(
    zigEnumValues(zigClientSource, "SessionFsMethod", { visibility: "optional" }),
    [
      "read_file",
      "write_file",
      "append_file",
      "exists",
      "stat",
      "mkdir",
      "readdir",
      "readdir_with_types",
      "rm",
      "rename",
      "sqlite_query",
      "sqlite_transaction",
      "sqlite_exists",
    ],
    "Zig SessionFsMethod values",
  );
  requireSourceFragments(
    zigClientSource,
    [
      ...Object.entries(sessionFsQueryWireToZig).map(
        ([wire, zig]) =>
          `if (std.mem.eql(u8, name, "${wire}")) return .${zig};`,
      ),
      '.code = if (err == error.FileNotFound) "ENOENT" else "UNKNOWN"',
      '.busy_or_locked => "busyOrLocked"',
      '.fatal => "fatal"',
      '.post_commit_ambiguous => "postCommitAmbiguous"',
      "session_fs: ?session_types.SessionFsConfig = null",
      'try self.setSessionFsProvider(value)',
      '.initialCwd = config.initial_cwd',
      '.sessionStatePath = config.session_state_path',
      '.conventions = config.conventions',
      '.capabilities = config.capabilities',
      "if (self.registered_session_fs == null and factory != null)",
      "if (self.registered_session_fs != null and factory == null)",
      "if (registration.sqlite and created.sqlite == null)",
    ],
    "Zig SessionFS client lifecycle",
  );
}

function verifySessionRuntimeSourceContract(
  clientSource,
  typesSource,
  sourceContract,
) {
  const expected = expectedSessionRuntimeTypeScriptContract;
  requireExactPropertySignatures(
    interfacePropertySignatures(typesSource, "SessionConfigBase"),
    expectedSessionConfigBaseTypeScriptContract,
    "SessionConfigBase",
  );
  for (const [name, fields] of Object.entries(
    expectedInheritedSessionTypeScriptContract,
  )) {
    requireExactPropertySignatures(
      inheritedInterfacePropertySignatures(
        typesSource,
        name,
        "SessionConfigBase",
      ),
      fields,
      name,
    );
  }

  for (const [name, fields] of [
    ["LargeToolOutputConfig", expected.largeOutput],
    ["InfiniteSessionConfig", expected.infiniteSessions],
    ["MemoryConfiguration", expected.memory],
    ["CapiSessionOptions", expected.capi],
  ]) {
    requireExactPropertySignatures(
      interfacePropertySignatures(typesSource, name),
      fields,
      name,
    );
  }

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
    requireSourceFragments(source, expected.lowering, owner);
    requireSourceFragments(
      source,
      ["workspacePath", 'session["_workspacePath"] = workspacePath'],
      owner,
    );
  }

  for (const [owner, fields] of [
    ["Zig CreateSessionConfig", sourceContract.zig.create],
    ["Zig ResumeSessionConfig", sourceContract.zig.resume],
    ["Zig JoinSessionConfig", sourceContract.zig.join],
  ]) {
    for (const [name, expectedField] of Object.entries(expectedSessionRuntimeZigContract)) {
      assert(fields[name]?.type === expectedField.type, `${owner}.${name} type changed`);
      assert(fields[name]?.default === expectedField.default, `${owner}.${name} default changed`);
    }
  }

  const zigLowering = sourceSection(
    zigClientSource,
    "fn lowerSessionOptions(options: NormalizedSessionOptions) WireSessionOptions {",
    "const ExtensionWireValues = struct {",
    "Zig lowerSessionOptions",
  );
  requireSourceFragments(
    zigLowering,
    [
      ".clientName = options.client_name",
      ".reasoningEffort = options.reasoning_effort",
      ".reasoningSummary = options.reasoning_summary",
      ".isExperimentalMode = options.enable_experimental_mode",
      ".contextTier = options.context_tier",
      ".largeOutput = if (options.large_output)",
      ".maxSizeBytes = value.max_size_bytes",
      ".outputDir = value.output_directory",
      ".configDir = options.config_directory",
      ".capi = if (options.capi)",
      ".autoTier = value.auto_tier",
      ".enableWebSocketResponses = value.enable_websocket_responses",
      ".additionalDirectories = options.additional_directories",
      ".infiniteSessions = if (options.infinite_sessions)",
      ".backgroundCompactionThreshold = value.background_compaction_threshold",
      ".bufferExhaustionThreshold = value.buffer_exhaustion_threshold",
      ".memory = if (options.memory)",
      ".skipEmbeddingRetrieval = options.skip_embedding_retrieval",
      ".embeddingCacheStorage = if (options.embedding_cache_storage)",
      '.in_memory => .@"in-memory"',
      ".organizationCustomInstructions = options.organization_custom_instructions",
      ".enableFileHooks = options.enable_file_hooks",
      ".enableHostGitOperations = options.enable_host_git_operations",
      ".enableSessionStore = options.enable_session_store",
    ],
    "Zig lowerSessionOptions",
  );
}

function verifyLifecycleContract(
  contract,
  clientSource,
  typesSource,
  sourceContract,
) {
  const { join, zig } = sourceContract;
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
  assert(
    zig.resume.suppress_resume_event?.type === "bool" &&
      zig.resume.suppress_resume_event.default === "false",
    "Zig ResumeSessionConfig.suppress_resume_event changed",
  );
  assert(
    zig.resume.continue_pending_work?.type === "bool" &&
      zig.resume.continue_pending_work.default === "false",
    "Zig ResumeSessionConfig.continue_pending_work changed",
  );
  assert(
    zig.join.suppress_resume_event?.type === "bool" &&
      zig.join.suppress_resume_event.default === "true",
    "Zig JoinSessionConfig.suppress_resume_event changed",
  );
  assert(
    zig.join.continue_pending_work?.type === "bool" &&
      zig.join.continue_pending_work.default === "false",
    "Zig JoinSessionConfig.continue_pending_work changed",
  );

  verifyJoinSessionSourceContract(join, contract.lifecycle.extensionJoin);
  for (const field of contract.lifecycle.extensionJoin.fields) {
    assert(
      Object.hasOwn(join.properties, field),
      `JoinSessionConfig is missing lifecycle field: ${field}`,
    );
  }
  assertFieldsOwnedBy(
    contract.lifecycle.extensionJoin.responseFields,
    { grantedEnvironmentVariables: "grantedEnvironmentVariables?: Record<string, string>" },
    extensionResume,
    "resumeSessionInternal response",
  );
}

function verifyHookContract(contract, typesSource) {
  const hooks = sourceSection(
    typesSource,
    "export interface SessionHooks {",
    "// ============================================================================\n// MCP Server Configuration Types",
    "SessionHooks",
  );
  const declarations = Object.fromEntries(
    [...hooks.matchAll(/^\s+(\w+)\?:\s+(\w+);$/gm)]
      .map((match) => [match[1], match[2]]),
  );
  const expected = contract.callbacks.hooks.handlers;
  requireExactStrings(
    Object.keys(declarations),
    Object.keys(expected),
    "SessionHooks callback inventory",
  );
  for (const [name, handler] of Object.entries(expected)) {
    assert(
      declarations[name] === handler,
      `SessionHooks.${name} changed from ${handler}`,
    );
  }
}

function verifyExtensibilitySourceContract(
  contract,
  clientSource,
  typesSource,
  sourceContract,
) {
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
  verifyLifecycleContract(contract, clientSource, typesSource, sourceContract);
  verifyHookContract(contract, typesSource);
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
  const [protocol, packageManifest, lock, nodeClient, nodeSession, nodeTypes, nodeExtension, nodeRpc, nodeSessionFsProvider] = await Promise.all([
    fetchJson(rawUrl(commit, "sdk-protocol-version.json")),
    fetchJson(rawUrl(commit, "nodejs/package.json")),
    fetchJson(rawUrl(commit, "nodejs/package-lock.json")),
    fetchText(rawUrl(commit, "nodejs/src/client.ts")),
    fetchText(rawUrl(commit, "nodejs/src/session.ts")),
    fetchText(rawUrl(commit, "nodejs/src/types.ts")),
    fetchText(rawUrl(commit, "nodejs/src/extension.ts")),
    fetchText(rawUrl(commit, "nodejs/src/generated/rpc.ts")),
    fetchText(rawUrl(commit, "nodejs/src/sessionFsProvider.ts")),
  ]);
  const cliPackageVersion =
    packageManifest.copilotCliVersion ??
    lock.packages?.["node_modules/@github/copilot"]?.version;
  assert(Number.isSafeInteger(protocol.version), "upstream protocol version is invalid");
  assert(
    /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(cliPackageVersion),
    "upstream package manifest has no exact Copilot CLI version",
  );
  verifyPinnedSourceContracts({
    upstreamCommit: commit,
    clientSource: nodeClient,
    typesSource: nodeTypes,
    extensionSource: nodeExtension,
    rpcSource: nodeRpc,
    sessionFsProviderSource: nodeSessionFsProvider,
  });

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
    const extensibilityContract = expectedExtensibilityContract(commit);
    writeFileSync(
      extensibilityContractPath,
      `${JSON.stringify(extensibilityContract, null, 2)}\n`,
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
  const [nodeClient, nodeTypes, nodeExtension, nodeRpc, nodeSessionFsProvider] = await Promise.all([
    fetchText(rawUrl(metadata.upstreamCommit, "nodejs/src/client.ts")),
    fetchText(rawUrl(metadata.upstreamCommit, "nodejs/src/types.ts")),
    fetchText(rawUrl(metadata.upstreamCommit, "nodejs/src/extension.ts")),
    fetchText(rawUrl(metadata.upstreamCommit, "nodejs/src/generated/rpc.ts")),
    fetchText(rawUrl(metadata.upstreamCommit, "nodejs/src/sessionFsProvider.ts")),
  ]);
  verifyPinnedSourceContracts({
    upstreamCommit: metadata.upstreamCommit,
    clientSource: nodeClient,
    typesSource: nodeTypes,
    extensionSource: nodeExtension,
    rpcSource: nodeRpc,
    sessionFsProviderSource: nodeSessionFsProvider,
  });
  verify();
} else {
  const commitIndex = args.indexOf("--commit");
  const explicitCommit = commitIndex === -1 ? undefined : args[commitIndex + 1];
  const ifPublished = args.length === 1 && args[0] === "--if-published";
  assert(ifPublished || args.length === (explicitCommit ? 2 : 0), "usage: npm run sync -- [--commit <sha> | --if-published]");
  await synchronize(explicitCommit, ifPublished);
}
