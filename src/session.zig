const std = @import("std");
const provider = @import("provider.zig");
const runtime = @import("runtime.zig");
const ModelCapabilitiesOverride = @import("models.zig").CapabilitiesOverride;
const extensibility = @import("extensibility.zig");
const event_payloads = @import("session_event_payloads.zig");
const session_events = @import("session_event_generated.zig");

pub const SessionEventTypes = session_events;

pub const ReasoningEffort = enum {
    low,
    medium,
    high,
    xhigh,
    max,
};

pub const CustomAgentConfig = struct {
    name: []const u8,
    display_name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    tools: ?[]const []const u8 = null,
    prompt: []const u8,
    mcp_servers: ?[]const extensibility.McpServer = null,
    infer: ?bool = null,
    skills: ?[]const []const u8 = null,
    model: ?[]const u8 = null,
    reasoning_effort: ?ReasoningEffort = null,
};

pub const DefaultAgentConfig = struct {
    excluded_tools: ?[]const []const u8 = null,
};

pub const InitialAgent = union(enum) {
    default_agent,
    custom_agent: []const u8,
};

pub const RemoteSessionMode = enum {
    off,
    @"export",
    on,

    pub fn wireValue(self: RemoteSessionMode) []const u8 {
        return switch (self) {
            .off => "off",
            .@"export" => "export",
            .on => "on",
        };
    }
};

pub const CreateSessionConfig = struct {
    session_id: ?[]const u8 = null,
    model: ?[]const u8 = null,
    provider: ?provider.ProviderConfig = null,
    providers: []const provider.NamedProviderConfig = &.{},
    models: []const provider.ProviderModelConfig = &.{},
    model_capabilities: ?ModelCapabilitiesOverride = null,
    working_directory: ?[]const u8 = null,
    streaming: bool = false,
    tools: []const Tool = &.{},
    available_tools: ?[]const []const u8 = null,
    excluded_tools: ?[]const []const u8 = null,
    custom_agents: ?[]const CustomAgentConfig = null,
    default_agent: ?DefaultAgentConfig = null,
    agent: InitialAgent = .default_agent,
    custom_agents_local_only: ?bool = null,
    excluded_builtin_agents: ?[]const []const u8 = null,
    system_message: ?SystemMessageConfig = null,
    request_permission: bool = false,
    enable_config_discovery: ?bool = null,
    skill_directories: ?[]const []const u8 = null,
    enable_skills: ?bool = null,
    instruction_directories: ?[]const []const u8 = null,
    skip_custom_instructions: ?bool = null,
    enable_on_demand_instruction_discovery: ?bool = null,
    enable_managed_settings: bool = false,
    managed_settings: ?ManagedSettings = null,
    on_permission_request: ?PermissionHandler = null,
    permission_context: ?*anyopaque = null,
    on_user_input_request: ?UserInputHandler = null,
    user_input_context: ?*anyopaque = null,
    remote_session: ?RemoteSessionMode = null,
    create_session_filesystem_provider: ?runtime.SessionFilesystemProviderFactory = null,
    extensions: extensibility.CreateExtensions = .{},
};

pub const ResumeSessionConfig = struct {
    model: ?[]const u8 = null,
    provider: ?provider.ProviderConfig = null,
    providers: []const provider.NamedProviderConfig = &.{},
    models: []const provider.ProviderModelConfig = &.{},
    model_capabilities: ?ModelCapabilitiesOverride = null,
    working_directory: ?[]const u8 = null,
    streaming: bool = false,
    tools: []const Tool = &.{},
    available_tools: ?[]const []const u8 = null,
    excluded_tools: ?[]const []const u8 = null,
    custom_agents: ?[]const CustomAgentConfig = null,
    default_agent: ?DefaultAgentConfig = null,
    agent: InitialAgent = .default_agent,
    custom_agents_local_only: ?bool = null,
    excluded_builtin_agents: ?[]const []const u8 = null,
    system_message: ?SystemMessageConfig = null,
    request_permission: bool = false,
    enable_config_discovery: ?bool = null,
    skill_directories: ?[]const []const u8 = null,
    enable_skills: ?bool = null,
    instruction_directories: ?[]const []const u8 = null,
    skip_custom_instructions: ?bool = null,
    enable_on_demand_instruction_discovery: ?bool = null,
    enable_managed_settings: bool = false,
    managed_settings: ?ManagedSettings = null,
    on_permission_request: ?PermissionHandler = null,
    permission_context: ?*anyopaque = null,
    on_user_input_request: ?UserInputHandler = null,
    user_input_context: ?*anyopaque = null,
    suppress_resume_event: bool = false,
    continue_pending_work: bool = false,
    remote_session: ?RemoteSessionMode = null,
    create_session_filesystem_provider: ?runtime.SessionFilesystemProviderFactory = null,
    extensions: extensibility.ResumeExtensions = .{},
};

pub const JoinSessionConfig = struct {
    model: ?[]const u8 = null,
    provider: ?provider.ProviderConfig = null,
    providers: []const provider.NamedProviderConfig = &.{},
    models: []const provider.ProviderModelConfig = &.{},
    model_capabilities: ?ModelCapabilitiesOverride = null,
    working_directory: ?[]const u8 = null,
    streaming: bool = false,
    tools: []const Tool = &.{},
    available_tools: ?[]const []const u8 = null,
    excluded_tools: ?[]const []const u8 = null,
    custom_agents: ?[]const CustomAgentConfig = null,
    default_agent: ?DefaultAgentConfig = null,
    agent: InitialAgent = .default_agent,
    custom_agents_local_only: ?bool = null,
    excluded_builtin_agents: ?[]const []const u8 = null,
    system_message: ?SystemMessageConfig = null,
    request_permission: bool = false,
    enable_config_discovery: ?bool = null,
    skill_directories: ?[]const []const u8 = null,
    enable_skills: ?bool = null,
    instruction_directories: ?[]const []const u8 = null,
    skip_custom_instructions: ?bool = null,
    enable_on_demand_instruction_discovery: ?bool = null,
    enable_managed_settings: bool = false,
    managed_settings: ?ManagedSettings = null,
    on_permission_request: ?PermissionHandler = null,
    permission_context: ?*anyopaque = null,
    on_user_input_request: ?UserInputHandler = null,
    user_input_context: ?*anyopaque = null,
    suppress_resume_event: bool = true,
    continue_pending_work: bool = false,
    remote_session: ?RemoteSessionMode = null,
    create_session_filesystem_provider: ?runtime.SessionFilesystemProviderFactory = null,
    extensions: extensibility.JoinExtensions = .{},
};

/// Compatibility alias for callers constructing create-session options.
/// Use `CreateSessionConfig` in new code.
pub const SessionConfig = CreateSessionConfig;

/// Message options borrow all caller-provided data until the call returns.
/// No deinit is required.
pub const MessageOptions = struct {
    prompt: []const u8,
    attachments: ?[]const Attachment = null,
};

/// A borrowed attachment sent with a user message. No deinit is required.
pub const Attachment = union(enum) {
    file: File,
    directory: Directory,
    selection: Selection,
    blob: Blob,
    github_reference: GitHubReference,
    github_commit: GitHubCommit,
    github_release: GitHubRelease,
    github_actions_job: GitHubActionsJob,
    github_repository: GitHubRepository,
    github_file_diff: GitHubFileDiff,
    github_tree_comparison: GitHubTreeComparison,
    github_url: GitHubUrl,
    github_file: GitHubFile,
    github_snippet: GitHubSnippet,

    pub const LineRange = struct {
        start: u32,
        end: u32,
    };

    pub const SelectionPosition = struct {
        line: u32,
        character: u32,
    };

    pub const SelectionRange = struct {
        start: SelectionPosition,
        end: SelectionPosition,
    };

    pub const GitHubReferenceType = enum {
        issue,
        pr,
        discussion,
    };

    pub const GitHubRepoPointer = struct {
        id: ?i64 = null,
        name: []const u8,
        owner: []const u8,
    };

    pub const GitHubFileDiffSide = struct {
        path: []const u8,
        git_ref: []const u8,
        repo: GitHubRepoPointer,
    };

    pub const GitHubTreeComparisonSide = struct {
        repo: GitHubRepoPointer,
        revision: []const u8,
    };

    pub const GitHubSnippetLineRange = struct {
        start: i64,
        end: i64,
    };

    pub const File = struct {
        path: []const u8,
        display_name: ?[]const u8 = null,
        line_range: ?LineRange = null,
    };

    pub const Directory = struct {
        path: []const u8,
        display_name: ?[]const u8 = null,
    };

    pub const Selection = struct {
        file_path: []const u8,
        text: []const u8,
        display_name: ?[]const u8 = null,
        selection: SelectionRange,
    };

    pub const Blob = struct {
        data: []const u8,
        mime_type: []const u8,
        display_name: ?[]const u8 = null,
    };

    pub const GitHubReference = struct {
        number: u64,
        title: []const u8,
        reference_type: GitHubReferenceType,
        state: []const u8,
        url: []const u8,
    };

    pub const GitHubCommit = struct {
        message: []const u8,
        oid: []const u8,
        repo: GitHubRepoPointer,
        url: []const u8,
    };

    pub const GitHubRelease = struct {
        name: []const u8,
        repo: GitHubRepoPointer,
        tag_name: []const u8,
        url: []const u8,
    };

    pub const GitHubActionsJob = struct {
        conclusion: ?[]const u8 = null,
        job_id: i64,
        job_name: []const u8,
        repo: GitHubRepoPointer,
        url: []const u8,
        workflow_name: []const u8,
    };

    pub const GitHubRepository = struct {
        description: ?[]const u8 = null,
        git_ref: ?[]const u8 = null,
        repo: GitHubRepoPointer,
        url: []const u8,
    };

    pub const GitHubFileDiff = struct {
        sides: Sides,
        url: []const u8,

        pub const Sides = union(enum) {
            added: GitHubFileDiffSide,
            deleted: GitHubFileDiffSide,
            modified: struct {
                base: GitHubFileDiffSide,
                head: GitHubFileDiffSide,
            },
        };
    };

    pub const GitHubTreeComparison = struct {
        base: GitHubTreeComparisonSide,
        head: GitHubTreeComparisonSide,
        url: []const u8,
    };

    pub const GitHubUrl = struct {
        url: []const u8,
    };

    pub const GitHubFile = struct {
        path: []const u8,
        git_ref: []const u8,
        repo: GitHubRepoPointer,
        url: []const u8,
    };

    pub const GitHubSnippet = struct {
        line_range: GitHubSnippetLineRange,
        path: []const u8,
        git_ref: []const u8,
        repo: GitHubRepoPointer,
        url: []const u8,
    };
};

pub const AutoTier = enum {
    efficiency,
    balance,
    intelligence,
    fast,
};

pub const ReasoningSummary = enum {
    none,
    concise,
    detailed,
};

pub const ContextTier = enum {
    default,
    long_context,
};

pub const ModelSwitchOptions = struct {
    reasoning_effort: ?[]const u8 = null,
    reasoning_summary: ?ReasoningSummary = null,
    context_tier: ?ContextTier = null,
    auto_tier: ?AutoTier = null,
    compaction_decision: ?[]const u8 = null,
    run_compaction_preflight: ?bool = null,
};

pub const ModelSwitchConfirmation = struct {
    targetModelDisplayName: []const u8,
    currentTokens: f64,
    targetLimit: f64,
};

pub const CurrentModel = struct {
    modelId: ?[]const u8 = null,
    reasoningEffort: ?[]const u8 = null,
    contextTier: ?ContextTier = null,
    autoTier: ?AutoTier = null,
    pendingAutoTier: ?AutoTier = null,
    activatingAutoTier: ?AutoTier = null,
};

pub const ModelSwitchResult = struct {
    modelId: ?[]const u8 = null,
    deferred: ?bool = null,
    status: ?[]const u8 = null,
    confirmation: ?ModelSwitchConfirmation = null,
    persistenceError: ?[]const u8 = null,
    message: ?[]const u8 = null,
    warning: ?[]const u8 = null,
    deprecationWarnings: ?[]const []const u8 = null,
    modelState: ?CurrentModel = null,
};

pub const AbortResult = struct {
    success: bool,
    @"error": ?[]const u8 = null,
};

pub const LogLevel = enum {
    info,
    warning,
    @"error",
};

pub const LogOptions = struct {
    level: LogLevel = .info,
    log_type: ?[]const u8 = null,
    ephemeral: bool = false,
    url: ?[]const u8 = null,
    tip: ?[]const u8 = null,
};

pub const AutoTierSwitchStatus = enum {
    unchanged,
    pending,
};

pub const AutoTierSwitchResult = struct {
    status: AutoTierSwitchStatus,
    effectiveAutoTier: ?AutoTier = null,
    pendingAutoTier: ?AutoTier = null,
    activatingAutoTier: ?AutoTier = null,
    supersededAutoTier: ?AutoTier = null,
};

pub const Tool = struct {
    name: []const u8,
    description: []const u8 = "",
    parameters_json: []const u8 = "{}",
    overrides_built_in_tool: bool = false,
    skip_permission: bool = false,
    defer_loading: ToolLoading = .auto,
    metadata_json: ?[]const u8 = null,
    is_terminal: bool = false,
    handler: ?ToolHandler = null,
    context: ?*anyopaque = null,
};

pub const ToolLoading = enum {
    auto,
    never,
};

pub const ToolHandler = *const fn (
    allocator: std.mem.Allocator,
    arguments_json: []const u8,
    context: ?*anyopaque,
) anyerror![]u8;

pub const UserInputRequest = struct {
    session_id: []const u8,
    question: []const u8,
    choices: ?[]const []const u8 = null,
    allow_freeform: ?bool = null,
};

pub const UserInputResponse = struct {
    answer: []u8,
    was_freeform: bool,
};

/// Returns an answer allocated with `allocator`. The SDK frees the answer
/// after sending the response to Copilot.
pub const UserInputHandler = *const fn (
    allocator: std.mem.Allocator,
    request: UserInputRequest,
    context: ?*anyopaque,
) anyerror!UserInputResponse;

pub const SystemMessageMode = enum {
    append,
    replace,
};

pub const SystemMessageConfig = struct {
    mode: SystemMessageMode = .append,
    content: []const u8,
};

pub const ManagedSettings = struct {
    permissions: ?ManagedSettingsPermissions = null,
};

pub const ManagedSettingsPermissions = struct {
    disable_bypass_permissions_mode: ?[]const u8 = null,
    deny: ?[]const []const u8 = null,
    ask: ?[]const []const u8 = null,
    allow: ?[]const []const u8 = null,
};

pub const AssistantMessage = session_events.AssistantMessage;
pub const AssistantMessageDelta = session_events.AssistantMessageDelta;
pub const AssistantReasoning = session_events.AssistantReasoning;
pub const AssistantReasoningDelta = session_events.AssistantReasoningDelta;
pub const SessionError = session_events.SessionError;
pub const SessionIdle = session_events.SessionIdle;

/// Result of automatic permission handling before `Session.nextEvent` returns
/// the permission event.
pub const AutomaticPermissionHandling = event_payloads.AutomaticPermissionHandling;
pub const PermissionRequested = session_events.PermissionRequested;

pub const PermissionDecision = union(enum) {
    approve_once,
    reject: ?[]const u8,
    /// Sends an advanced upstream decision shape. The JSON must describe an
    /// object accepted by `session.permissions.handlePendingPermissionRequest`.
    json: []const u8,
    /// Leaves the permission request pending for manual resolution.
    no_result,
};

pub const PermissionInvocation = struct {
    session_id: []const u8,
    managed_settings_enabled: bool,
};

pub const PermissionHandler = *const fn (
    request: PermissionRequested,
    invocation: PermissionInvocation,
    context: ?*anyopaque,
) anyerror!PermissionDecision;

/// Approves requests unless managed settings require the host or a person to
/// make the decision.
pub fn approveAll(
    request: PermissionRequested,
    invocation: PermissionInvocation,
    _: ?*anyopaque,
) anyerror!PermissionDecision {
    if (invocation.managed_settings_enabled) {
        return error.ApproveAllWithManagedSettings;
    }
    if (request.managed_approval_required) return .no_result;
    return .approve_once;
}

pub fn defaultJoinSessionPermissionHandler(
    _: PermissionRequested,
    _: PermissionInvocation,
    _: ?*anyopaque,
) anyerror!PermissionDecision {
    return .no_result;
}

pub const ExternalToolRequested = session_events.ExternalToolRequested;
pub const PermissionRequestKind = event_payloads.PermissionRequestKind;
pub const RawEvent = event_payloads.RawEvent;
pub const UnknownEvent = event_payloads.UnknownEvent;
pub const SessionEvent = session_events.SessionEvent;
pub const SessionEventTag = session_events.SessionEventTag;
pub const parseEvent = session_events.parseEvent;

test "known and unknown events retain owned data" {
    const allocator = std.testing.allocator;
    const known_json = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"assistant.message_delta","data":{"deltaContent":"hi","messageId":"m1"}}
    ,
        .{},
    );
    defer known_json.deinit();
    var known = try parseEvent(allocator, known_json.value);
    defer known.deinit(allocator);

    try std.testing.expectEqualStrings("hi", known.assistant_message_delta.delta_content);
    try std.testing.expectEqualStrings("m1", known.assistant_message_delta.message_id);

    const reasoning_json = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"assistant.reasoning","data":{"reasoningId":"r1","content":"I should inspect the source.","rte":true}}
    ,
        .{},
    );
    defer reasoning_json.deinit();
    var reasoning = try parseEvent(allocator, reasoning_json.value);
    defer reasoning.deinit(allocator);
    try std.testing.expectEqualStrings("r1", reasoning.assistant_reasoning.reasoning_id);
    try std.testing.expectEqualStrings(
        "I should inspect the source.",
        reasoning.assistant_reasoning.content,
    );
    try std.testing.expect(reasoning.assistant_reasoning.rte.?);

    const reasoning_delta_json = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"assistant.reasoning_delta","data":{"reasoningId":"r1","deltaContent":"Inspect."}}
    ,
        .{},
    );
    defer reasoning_delta_json.deinit();
    var reasoning_delta = try parseEvent(allocator, reasoning_delta_json.value);
    defer reasoning_delta.deinit(allocator);
    try std.testing.expectEqualStrings("r1", reasoning_delta.assistant_reasoning_delta.reasoning_id);
    try std.testing.expectEqualStrings(
        "Inspect.",
        reasoning_delta.assistant_reasoning_delta.delta_content,
    );

    const unknown_json = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"future.event","data":{"answer":42}}
    ,
        .{},
    );
    defer unknown_json.deinit();
    var unknown = try parseEvent(allocator, unknown_json.value);
    defer unknown.deinit(allocator);

    try std.testing.expectEqualStrings("future.event", unknown.unknown.event_type);
    try std.testing.expectEqualStrings("{\"answer\":42}", unknown.unknown.data_json);
}

test "raw rich and unknown events outlive the source JSON tree" {
    const allocator = std.testing.allocator;

    var raw_json = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"session.start","data":{"sessionId":"s1","version":1,"producer":"test","copilotVersion":"1.0","startTime":"2026-01-01T00:00:00Z","selectedModel":"raw-secret","contextTier":null}}
    ,
        .{},
    );
    var raw = try parseEvent(allocator, raw_json.value);
    raw_json.deinit();
    defer raw.deinit(allocator);
    try std.testing.expectEqual(.session_start, std.meta.activeTag(raw));
    try std.testing.expectEqualStrings("s1", raw.session_start.data.session_id);
    try std.testing.expectEqual(@as(u64, 1), raw.session_start.data.version);
    try std.testing.expectEqualStrings("raw-secret", raw.session_start.data.selected_model.?);
    try std.testing.expectEqual(null, raw.session_start.data.context_tier);
    try std.testing.expectEqualStrings(
        "{\"sessionId\":\"s1\",\"version\":1,\"producer\":\"test\",\"copilotVersion\":\"1.0\",\"startTime\":\"2026-01-01T00:00:00Z\",\"selectedModel\":\"raw-secret\",\"contextTier\":null}",
        raw.rawData(),
    );

    var rich_json = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"assistant.message","data":{"content":"owned","messageId":"m1"}}
    ,
        .{},
    );
    var rich = try parseEvent(allocator, rich_json.value);
    rich_json.deinit();
    defer rich.deinit(allocator);
    try std.testing.expectEqual(.assistant_message, std.meta.activeTag(rich));
    try std.testing.expectEqualStrings("owned", rich.assistant_message.content);
    try std.testing.expectEqualStrings(
        "{\"content\":\"owned\",\"messageId\":\"m1\"}",
        rich.rawData(),
    );

    var future_json = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"future.event","data":{"answer":42}}
    ,
        .{},
    );
    var future = try parseEvent(allocator, future_json.value);
    future_json.deinit();
    defer future.deinit(allocator);
    try std.testing.expectEqual(.unknown, std.meta.activeTag(future));
    try std.testing.expectEqualStrings("future.event", future.unknown.event_type);
    try std.testing.expectEqualStrings("{\"answer\":42}", future.rawData());
}

test "generated payloads expose nested arrays enums unions and opaque values" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"tool.execution_complete","data":{"toolCallId":"tool-1","success":true,"model":"gpt-test","result":{"content":"done","binaryResultsForLlm":[{"type":"image","assetId":"sha256:abc","mimeType":"image/png","byteLength":4,"metadata":{"trace":{"id":"abc"}}}],"structuredContent":{"answer":42}}}}
    ,
        .{},
    );
    var event = try parseEvent(allocator, parsed.value);
    parsed.deinit();
    defer event.deinit(allocator);

    const payload = event.tool_execution_complete.data;
    try std.testing.expectEqualStrings("tool-1", payload.tool_call_id);
    try std.testing.expect(payload.success);
    try std.testing.expectEqualStrings("gpt-test", payload.model.?);
    const result = payload.result.?;
    try std.testing.expectEqualStrings("done", result.content);
    try std.testing.expectEqual(@as(usize, 1), result.binary_results_for_llm.?.len);
    switch (result.binary_results_for_llm.?[0]) {
        .asset_id => |asset| {
            try std.testing.expectEqual(
                SessionEventTypes.BinaryAssetReferenceType.image,
                asset.type,
            );
            try std.testing.expectEqualStrings("sha256:abc", asset.asset_id);
            try std.testing.expectEqual(@as(u64, 4), asset.byte_length);
            try std.testing.expectEqualStrings(
                "abc",
                asset.metadata.?.map.get("trace").?.object.get("id").?.string,
            );
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(
        @as(i64, 42),
        result.structured_content.?.object.get("answer").?.integer,
    );
}

test "generated integers accept full u64 range and raw data keeps future fields" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"session.start","data":{"sessionId":"s1","version":9223372036854775808,"producer":"test","copilotVersion":"1.0","startTime":"2026-01-01T00:00:00Z","futureField":{"enabled":true}}}
    ,
        .{},
    );
    defer parsed.deinit();
    var event = try parseEvent(allocator, parsed.value);
    defer event.deinit(allocator);

    try std.testing.expectEqual(
        @as(u64, 9_223_372_036_854_775_808),
        event.session_start.data.version,
    );
    try std.testing.expectEqualStrings(
        "{\"sessionId\":\"s1\",\"version\":9223372036854775808,\"producer\":\"test\",\"copilotVersion\":\"1.0\",\"startTime\":\"2026-01-01T00:00:00Z\",\"futureField\":{\"enabled\":true}}",
        event.rawData(),
    );
}

test "generated string bounds count code points and numbers accept large integer tokens" {
    const allocator = std.testing.allocator;

    var preview: [512]u8 = undefined;
    for (0..256) |index| {
        @memcpy(preview[index * 2 ..][0..2], "\xc3\xa9");
    }
    const notification_json = try std.fmt.allocPrint(
        allocator,
        \\{{"type":"system.notification","data":{{"content":"","kind":{{"type":"factory_completed","runId":"run-1","factoryName":"factory","status":"completed","consumedSubagents":0,"elapsedMs":0,"consumedNanoAiu":0,"attempt":1,"resultPreview":"{s}"}}}}}}
    ,
        .{preview},
    );
    defer allocator.free(notification_json);
    const parsed_notification = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        notification_json,
        .{},
    );
    defer parsed_notification.deinit();
    var notification = try parseEvent(allocator, parsed_notification.value);
    defer notification.deinit(allocator);

    try std.testing.expectEqual(
        @as(usize, 512),
        notification.system_notification.data.kind.factory_completed.result_preview.?.len,
    );

    const parsed_usage = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"session.usage_checkpoint","data":{"totalNanoAiu":9223372036854775808}}
    ,
        .{},
    );
    defer parsed_usage.deinit();
    var usage = try parseEvent(allocator, parsed_usage.value);
    defer usage.deinit(allocator);

    try std.testing.expectEqual(
        @as(f64, 9_223_372_036_854_775_808),
        usage.session_usage_checkpoint.data.total_nano_aiu,
    );
}

test "failed generated parsing wipes initialized fields" {
    const source_allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        source_allocator,
        \\{"type":"session.start","data":{"sessionId":"s1","version":1,"producer":"test","copilotVersion":"1.0","startTime":"2026-01-01T00:00:00Z","selectedModel":"wipe-me","reasoningSummary":"invalid"}}
    ,
        .{},
    );
    defer parsed.deinit();

    var storage = [_]u8{0xaa} ** 16_384;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    try std.testing.expectError(
        error.InvalidSessionEvent,
        parseEvent(fixed.allocator(), parsed.value),
    );
    try std.testing.expectEqual(
        null,
        std.mem.indexOf(u8, &storage, "wipe-me"),
    );
}

fn rejectGeneratedEventForAllocationFailures(allocator: std.mem.Allocator) !void {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"session.start","data":{"sessionId":"s1","version":1,"producer":"test","copilotVersion":"1.0","startTime":"2026-01-01T00:00:00Z","selectedModel":"wipe-me","reasoningSummary":"invalid"}}
    ,
        .{},
    );
    defer parsed.deinit();
    if (parseEvent(allocator, parsed.value)) |event_value| {
        var event = event_value;
        event.deinit(allocator);
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.InvalidSessionEvent => {},
        else => return err,
    }
}

test "failed generated parsing handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        rejectGeneratedEventForAllocationFailures,
        .{},
    );
}

test "focused payloads include schema required fields" {
    const allocator = std.testing.allocator;
    const error_json = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"session.error","data":{"errorType":"authentication","message":"sign in"}}
    ,
        .{},
    );
    defer error_json.deinit();
    var session_error = try parseEvent(allocator, error_json.value);
    defer session_error.deinit(allocator);
    try std.testing.expectEqualStrings(
        "authentication",
        session_error.session_error.error_type,
    );

    const tool_json = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"external_tool.requested","data":{"requestId":"r1","sessionId":"session-7","toolCallId":"t1","toolName":"lookup","arguments":{"id":"alpha"}}}
    ,
        .{},
    );
    defer tool_json.deinit();
    var tool = try parseEvent(allocator, tool_json.value);
    defer tool.deinit(allocator);
    try std.testing.expectEqualStrings(
        "session-7",
        tool.external_tool_requested.session_id,
    );
}

test "malformed known rich events return an error" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"assistant.message","data":{"messageId":"m1"}}
    ,
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectError(
        error.InvalidSessionEvent,
        parseEvent(allocator, parsed.value),
    );
}

test "schema-required generated and focused fields reject malformed events" {
    const allocator = std.testing.allocator;
    const samples = [_][]const u8{
        \\{"type":"session.start","data":{"version":1,"producer":"test","copilotVersion":"1.0","startTime":"2026-01-01T00:00:00Z"}}
        ,
        \\{"type":"session.error","data":{"message":"missing category"}}
        ,
        \\{"type":"external_tool.requested","data":{"requestId":"r1","toolCallId":"t1","toolName":"lookup"}}
        ,
    };
    for (samples) |sample| {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, sample, .{});
        defer parsed.deinit();
        try std.testing.expectError(error.InvalidSessionEvent, parseEvent(allocator, parsed.value));
    }
}

fn parseAndDeinitForAllocationFailures(
    allocator: std.mem.Allocator,
    json: []const u8,
    expected_tag: SessionEventTag,
) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    var event = try parseEvent(allocator, parsed.value);
    defer event.deinit(allocator);
    try std.testing.expectEqual(expected_tag, std.meta.activeTag(event));
}

test "generated event ownership handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        parseAndDeinitForAllocationFailures,
        .{
            \\{"type":"session.start","data":{"sessionId":"s1","version":1,"producer":"test","copilotVersion":"1.0","startTime":"2026-01-01T00:00:00Z","selectedModel":"raw-secret"}}
            ,
            SessionEventTag.session_start,
        },
    );
}

test "rich event ownership handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        parseAndDeinitForAllocationFailures,
        .{
            \\{"type":"assistant.message","data":{"content":"owned","messageId":"m1"}}
            ,
            SessionEventTag.assistant_message,
        },
    );
}

test "unknown event ownership handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        parseAndDeinitForAllocationFailures,
        .{
            \\{"type":"future.event","data":{"answer":42}}
            ,
            SessionEventTag.unknown,
        },
    );
}

test "session idle retains autopilot mode" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"session.idle","data":{"aborted":false,"mode":"autopilot"}}
    ,
        .{},
    );
    defer parsed.deinit();
    var event = try parseEvent(allocator, parsed.value);
    defer event.deinit(allocator);

    try std.testing.expectEqual(false, event.session_idle.aborted.?);
    try std.testing.expectEqualStrings("autopilot", event.session_idle.mode.?);
}

test "permission and external tool events retain opaque payloads" {
    const allocator = std.testing.allocator;
    const permission_json = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"permission.requested","data":{"requestId":"p1","permissionRequest":{"kind":"shell","fullCommandText":"pwd","intention":"show directory","commands":[],"possiblePaths":[],"possibleUrls":[],"hasWriteFileRedirection":false,"canOfferSessionApproval":false}}}
    ,
        .{},
    );
    defer permission_json.deinit();
    var permission = try parseEvent(allocator, permission_json.value);
    defer permission.deinit(allocator);

    try std.testing.expectEqualStrings("p1", permission.permission_requested.request_id);
    try std.testing.expect(!permission.permission_requested.managed_approval_required);
    try std.testing.expect(
        permission.permission_requested.automatic_handling == .not_configured,
    );
    try std.testing.expectEqualStrings(
        "{\"kind\":\"shell\",\"fullCommandText\":\"pwd\",\"intention\":\"show directory\",\"commands\":[],\"possiblePaths\":[],\"possibleUrls\":[],\"hasWriteFileRedirection\":false,\"canOfferSessionApproval\":false}",
        permission.permission_requested.permission_request_json,
    );
    switch (permission.permission_requested.permission_request.?) {
        .shell => |request| {
            try std.testing.expectEqualStrings("pwd", request.full_command_text);
            try std.testing.expectEqual(@as(usize, 0), request.commands.len);
        },
        else => return error.TestUnexpectedResult,
    }

    const tool_json = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"external_tool.requested","data":{"requestId":"r1","sessionId":"s1","toolCallId":"t1","toolName":"lookup","arguments":{"id":"alpha"}}}
    ,
        .{},
    );
    defer tool_json.deinit();
    var tool = try parseEvent(allocator, tool_json.value);
    defer tool.deinit(allocator);

    try std.testing.expectEqualStrings("lookup", tool.external_tool_requested.tool_name);
    try std.testing.expectEqualStrings(
        "{\"id\":\"alpha\"}",
        tool.external_tool_requested.arguments_json,
    );

    const Arguments = struct { id: []const u8 };
    const arguments = try tool.external_tool_requested.parseArguments(Arguments, allocator);
    defer arguments.deinit();
    try std.testing.expectEqualStrings("alpha", arguments.value.id);
    try std.testing.expectEqual(PermissionRequestKind.shell, try permission.permission_requested.kind());
}

test "permission event parses managed approval metadata" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"permission.requested","data":{"requestId":"p1","permissionRequest":{"kind":"future-kind","managedApprovalRequired":true}}}
    ,
        .{},
    );
    defer parsed.deinit();
    var event = try parseEvent(allocator, parsed.value);
    defer event.deinit(allocator);

    try std.testing.expect(event.permission_requested.managed_approval_required);
}

test "permission event rejects invalid managed approval metadata" {
    const allocator = std.testing.allocator;
    const invalid_values = [_][]const u8{
        "null",
        "\"true\"",
        "1",
        "[]",
        "{}",
    };

    for (invalid_values) |invalid_value| {
        const json = try std.fmt.allocPrint(
            allocator,
            "{{\"type\":\"permission.requested\",\"data\":{{\"requestId\":\"p1\",\"permissionRequest\":{{\"managedApprovalRequired\":{s}}}}}}}",
            .{invalid_value},
        );
        defer allocator.free(json);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
        defer parsed.deinit();
        try std.testing.expectError(error.InvalidSessionEvent, parseEvent(allocator, parsed.value));
    }
}

test "permission event rejects non-object request" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"permission.requested","data":{"requestId":"p1","permissionRequest":"invalid"}}
    ,
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidSessionEvent, parseEvent(allocator, parsed.value));
}

test "approveAll matches official permission semantics" {
    const ordinary = PermissionRequested{
        .request_id = @constCast("p1"),
        .permission_request_json = @constCast("{}"),
    };
    try std.testing.expectEqual(
        PermissionDecision.approve_once,
        try approveAll(ordinary, .{
            .session_id = "session-1",
            .managed_settings_enabled = false,
        }, null),
    );

    const unknown_kind = PermissionRequested{
        .request_id = @constCast("p2"),
        .permission_request_json = @constCast("{\"kind\":\"future-kind\"}"),
    };
    try std.testing.expectEqual(
        PermissionDecision.approve_once,
        try approveAll(unknown_kind, .{
            .session_id = "session-1",
            .managed_settings_enabled = false,
        }, null),
    );

    const managed = PermissionRequested{
        .request_id = @constCast("p3"),
        .permission_request_json = @constCast("{}"),
        .managed_approval_required = true,
    };
    try std.testing.expectEqual(
        PermissionDecision.no_result,
        try approveAll(managed, .{
            .session_id = "session-1",
            .managed_settings_enabled = false,
        }, null),
    );

    try std.testing.expectError(
        error.ApproveAllWithManagedSettings,
        approveAll(ordinary, .{
            .session_id = "session-1",
            .managed_settings_enabled = true,
        }, null),
    );
}

test "default join permission handler leaves requests pending" {
    const request = PermissionRequested{
        .request_id = @constCast("p1"),
        .permission_request_json = @constCast("{}"),
    };
    try std.testing.expectEqual(
        PermissionDecision.no_result,
        try defaultJoinSessionPermissionHandler(request, .{
            .session_id = "session-1",
            .managed_settings_enabled = false,
        }, null),
    );
}
