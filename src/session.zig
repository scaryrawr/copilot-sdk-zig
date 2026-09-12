const std = @import("std");
const ProviderConfig = @import("provider.zig").ProviderConfig;
const ModelCapabilitiesOverride = @import("models.zig").CapabilitiesOverride;
const extensibility = @import("extensibility.zig");
const event_payloads = @import("session_event_payloads.zig");
const session_events = @import("session_event_generated.zig");

pub const CreateSessionConfig = struct {
    session_id: ?[]const u8 = null,
    model: ?[]const u8 = null,
    provider: ?ProviderConfig = null,
    model_capabilities: ?ModelCapabilitiesOverride = null,
    working_directory: ?[]const u8 = null,
    streaming: bool = false,
    tools: []const Tool = &.{},
    available_tools: ?[]const []const u8 = null,
    excluded_tools: ?[]const []const u8 = null,
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
    extensions: extensibility.CreateExtensions = .{},
};

pub const ResumeSessionConfig = struct {
    model: ?[]const u8 = null,
    provider: ?ProviderConfig = null,
    model_capabilities: ?ModelCapabilitiesOverride = null,
    working_directory: ?[]const u8 = null,
    streaming: bool = false,
    tools: []const Tool = &.{},
    available_tools: ?[]const []const u8 = null,
    excluded_tools: ?[]const []const u8 = null,
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
    extensions: extensibility.ResumeExtensions = .{},
};

pub const JoinSessionConfig = struct {
    model: ?[]const u8 = null,
    provider: ?ProviderConfig = null,
    model_capabilities: ?ModelCapabilitiesOverride = null,
    working_directory: ?[]const u8 = null,
    streaming: bool = false,
    tools: []const Tool = &.{},
    available_tools: ?[]const []const u8 = null,
    excluded_tools: ?[]const []const u8 = null,
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
    extensions: extensibility.JoinExtensions = .{},
};

/// Compatibility alias for callers constructing create-session options.
/// Use `CreateSessionConfig` in new code.
pub const SessionConfig = CreateSessionConfig;

pub const MessageOptions = struct {
    prompt: []const u8,
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

pub const AssistantMessage = event_payloads.AssistantMessage;
pub const AssistantMessageDelta = event_payloads.AssistantMessageDelta;
pub const AssistantReasoning = event_payloads.AssistantReasoning;
pub const AssistantReasoningDelta = event_payloads.AssistantReasoningDelta;
pub const SessionError = event_payloads.SessionError;
pub const SessionIdle = event_payloads.SessionIdle;

/// Result of automatic permission handling before `Session.nextEvent` returns
/// the permission event.
pub const AutomaticPermissionHandling = event_payloads.AutomaticPermissionHandling;
pub const PermissionRequested = event_payloads.PermissionRequested;

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

pub const ExternalToolRequested = event_payloads.ExternalToolRequested;
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
        \\{"type":"session.start","data":{"token":"raw-secret"}}
    ,
        .{},
    );
    var raw = try parseEvent(allocator, raw_json.value);
    raw_json.deinit();
    defer raw.deinit(allocator);
    try std.testing.expectEqual(.session_start, std.meta.activeTag(raw));
    try std.testing.expectEqualStrings("{\"token\":\"raw-secret\"}", raw.rawData());

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

test "raw event ownership handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        parseAndDeinitForAllocationFailures,
        .{
            \\{"type":"session.start","data":{"token":"raw-secret"}}
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
        \\{"type":"permission.requested","data":{"requestId":"p1","permissionRequest":{"kind":"shell","fullCommandText":"pwd"}}}
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
        "{\"kind\":\"shell\",\"fullCommandText\":\"pwd\"}",
        permission.permission_requested.permission_request_json,
    );

    const tool_json = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"external_tool.requested","data":{"requestId":"r1","toolCallId":"t1","toolName":"lookup","arguments":{"id":"alpha"}}}
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
