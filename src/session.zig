const std = @import("std");
const ProviderConfig = @import("provider.zig").ProviderConfig;
const ModelCapabilitiesOverride = @import("models.zig").CapabilitiesOverride;

pub const SessionConfig = struct {
    session_id: ?[]const u8 = null,
    model: ?[]const u8 = null,
    provider: ?ProviderConfig = null,
    model_capabilities: ?ModelCapabilitiesOverride = null,
    working_directory: ?[]const u8 = null,
    streaming: bool = false,
    tools: []const Tool = &.{},
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
};

pub const MessageOptions = struct {
    prompt: []const u8,
};

pub const AutoTier = enum {
    efficiency,
    balance,
    intelligence,
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

pub const AssistantMessage = struct {
    content: []u8,
    message_id: ?[]u8,

    pub fn deinit(self: AssistantMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        if (self.message_id) |message_id| allocator.free(message_id);
    }
};

pub const AssistantMessageDelta = struct {
    delta_content: []u8,
    message_id: []u8,
};

pub const AssistantReasoning = struct {
    reasoning_id: []u8,
    content: []u8,
    rte: ?bool = null,
};

pub const AssistantReasoningDelta = struct {
    reasoning_id: []u8,
    delta_content: []u8,
};

pub const SessionError = struct {
    message: []u8,
};

pub const SessionIdle = struct {
    aborted: ?bool = null,
    mode: ?[]u8 = null,

    pub fn deinit(self: SessionIdle, allocator: std.mem.Allocator) void {
        if (self.mode) |mode| allocator.free(mode);
    }
};

/// Result of automatic permission handling before `Session.nextEvent` returns
/// the permission event.
pub const AutomaticPermissionHandling = union(enum) {
    /// No automatic permission handler was configured.
    not_configured,
    /// The handler's decision was accepted by the runtime.
    handled,
    /// The handler deliberately left the request pending for manual handling.
    no_result,
    /// The handler failed before a response was attempted.
    handler_failed: anyerror,
    /// Preparing or delivering the response failed. Callers must not blindly
    /// retry because the runtime may already have received the decision.
    delivery_failed: anyerror,
};

pub const PermissionRequested = struct {
    request_id: []u8,
    permission_request_json: []u8,
    managed_approval_required: bool = false,
    automatic_handling: AutomaticPermissionHandling = .not_configured,

    pub fn kind(self: PermissionRequested) !PermissionRequestKind {
        const parsed = try std.json.parseFromSlice(
            struct { kind: []const u8 },
            std.heap.page_allocator,
            self.permission_request_json,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();
        return PermissionRequestKind.fromString(parsed.value.kind);
    }

    pub fn parseRequest(
        self: PermissionRequested,
        comptime T: type,
        allocator: std.mem.Allocator,
    ) !std.json.Parsed(T) {
        return std.json.parseFromSlice(T, allocator, self.permission_request_json, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
    }
};

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

pub const ExternalToolRequested = struct {
    request_id: []u8,
    tool_call_id: []u8,
    tool_name: []u8,
    arguments_json: []u8,

    pub fn parseArguments(
        self: ExternalToolRequested,
        comptime T: type,
        allocator: std.mem.Allocator,
    ) !std.json.Parsed(T) {
        return std.json.parseFromSlice(T, allocator, self.arguments_json, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
    }
};

pub const PermissionRequestKind = enum {
    shell,
    write,
    read,
    path,
    mcp,
    url,
    memory,
    custom_tool,
    hook,
    extension_management,
    factory,
    extension_permission_access,
    extension_env_access,
    unknown,

    pub fn fromString(value: []const u8) PermissionRequestKind {
        const mappings = .{
            .{ "shell", PermissionRequestKind.shell },
            .{ "write", PermissionRequestKind.write },
            .{ "read", PermissionRequestKind.read },
            .{ "path", PermissionRequestKind.path },
            .{ "mcp", PermissionRequestKind.mcp },
            .{ "url", PermissionRequestKind.url },
            .{ "memory", PermissionRequestKind.memory },
            .{ "custom-tool", PermissionRequestKind.custom_tool },
            .{ "hook", PermissionRequestKind.hook },
            .{ "extension-management", PermissionRequestKind.extension_management },
            .{ "factory", PermissionRequestKind.factory },
            .{ "extension-permission-access", PermissionRequestKind.extension_permission_access },
            .{ "extension-env-access", PermissionRequestKind.extension_env_access },
        };
        inline for (mappings) |mapping| {
            if (std.mem.eql(u8, value, mapping[0])) return mapping[1];
        }
        return .unknown;
    }
};

pub const UnknownEvent = struct {
    event_type: []u8,
    data_json: []u8,
};

pub const SessionEvent = union(enum) {
    assistant_message: AssistantMessage,
    assistant_message_delta: AssistantMessageDelta,
    assistant_reasoning: AssistantReasoning,
    assistant_reasoning_delta: AssistantReasoningDelta,
    session_idle: SessionIdle,
    session_error: SessionError,
    permission_requested: PermissionRequested,
    external_tool_requested: ExternalToolRequested,
    unknown: UnknownEvent,

    pub fn deinit(self: *SessionEvent, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .assistant_message => |value| value.deinit(allocator),
            .assistant_message_delta => |value| {
                allocator.free(value.delta_content);
                allocator.free(value.message_id);
            },
            .assistant_reasoning => |value| {
                allocator.free(value.reasoning_id);
                allocator.free(value.content);
            },
            .assistant_reasoning_delta => |value| {
                allocator.free(value.reasoning_id);
                allocator.free(value.delta_content);
            },
            .session_idle => |value| value.deinit(allocator),
            .session_error => |value| allocator.free(value.message),
            .permission_requested => |value| {
                allocator.free(value.request_id);
                allocator.free(value.permission_request_json);
            },
            .external_tool_requested => |value| {
                allocator.free(value.request_id);
                allocator.free(value.tool_call_id);
                allocator.free(value.tool_name);
                allocator.free(value.arguments_json);
            },
            .unknown => |value| {
                allocator.free(value.event_type);
                allocator.free(value.data_json);
            },
        }
    }
};

fn requiredString(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = object.get(name) orelse return error.InvalidSessionEvent;
    return switch (value) {
        .string => |string| string,
        else => error.InvalidSessionEvent,
    };
}

fn optionalString(object: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |string| string,
        .null => null,
        else => error.InvalidSessionEvent,
    };
}

fn optionalBool(object: std.json.ObjectMap, name: []const u8) !?bool {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .bool => |boolean| boolean,
        .null => null,
        else => error.InvalidSessionEvent,
    };
}

pub fn parseEvent(allocator: std.mem.Allocator, value: std.json.Value) !SessionEvent {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidSessionEvent,
    };
    const event_type = try requiredString(object, "type");
    const data_value: std.json.Value = object.get("data") orelse .{ .object = .empty };
    const data = switch (data_value) {
        .object => |data| data,
        else => return error.InvalidSessionEvent,
    };

    if (std.mem.eql(u8, event_type, "assistant.message")) {
        const content = try allocator.dupe(u8, try requiredString(data, "content"));
        errdefer allocator.free(content);
        const raw_message_id = try optionalString(data, "messageId");
        return .{ .assistant_message = .{
            .content = content,
            .message_id = if (raw_message_id) |id| try allocator.dupe(u8, id) else null,
        } };
    }
    if (std.mem.eql(u8, event_type, "assistant.message_delta")) {
        const delta_content = try allocator.dupe(u8, try requiredString(data, "deltaContent"));
        errdefer allocator.free(delta_content);
        return .{ .assistant_message_delta = .{
            .delta_content = delta_content,
            .message_id = try allocator.dupe(u8, try requiredString(data, "messageId")),
        } };
    }
    if (std.mem.eql(u8, event_type, "assistant.reasoning")) {
        const reasoning_id = try allocator.dupe(u8, try requiredString(data, "reasoningId"));
        errdefer allocator.free(reasoning_id);
        return .{ .assistant_reasoning = .{
            .reasoning_id = reasoning_id,
            .content = try allocator.dupe(u8, try requiredString(data, "content")),
            .rte = try optionalBool(data, "rte"),
        } };
    }
    if (std.mem.eql(u8, event_type, "assistant.reasoning_delta")) {
        const reasoning_id = try allocator.dupe(u8, try requiredString(data, "reasoningId"));
        errdefer allocator.free(reasoning_id);
        return .{ .assistant_reasoning_delta = .{
            .reasoning_id = reasoning_id,
            .delta_content = try allocator.dupe(u8, try requiredString(data, "deltaContent")),
        } };
    }
    if (std.mem.eql(u8, event_type, "session.idle")) {
        const raw_mode = try optionalString(data, "mode");
        return .{ .session_idle = .{
            .aborted = try optionalBool(data, "aborted"),
            .mode = if (raw_mode) |mode| try allocator.dupe(u8, mode) else null,
        } };
    }
    if (std.mem.eql(u8, event_type, "session.error")) {
        return .{ .session_error = .{
            .message = try allocator.dupe(u8, try requiredString(data, "message")),
        } };
    }
    if (std.mem.eql(u8, event_type, "permission.requested")) {
        const permission_request = data.get("permissionRequest") orelse
            return error.InvalidSessionEvent;
        const permission_request_object = switch (permission_request) {
            .object => |request_object| request_object,
            else => return error.InvalidSessionEvent,
        };
        const managed_approval_required = if (permission_request_object.get(
            "managedApprovalRequired",
        )) |managed_value| switch (managed_value) {
            .bool => |boolean| boolean,
            else => return error.InvalidSessionEvent,
        } else false;
        const request_id = try allocator.dupe(u8, try requiredString(data, "requestId"));
        errdefer allocator.free(request_id);
        return .{ .permission_requested = .{
            .request_id = request_id,
            .managed_approval_required = managed_approval_required,
            .permission_request_json = try std.json.Stringify.valueAlloc(
                allocator,
                permission_request,
                .{},
            ),
        } };
    }
    if (std.mem.eql(u8, event_type, "external_tool.requested")) {
        const request_id = try allocator.dupe(u8, try requiredString(data, "requestId"));
        errdefer allocator.free(request_id);
        const tool_call_id = try allocator.dupe(u8, try requiredString(data, "toolCallId"));
        errdefer allocator.free(tool_call_id);
        const tool_name = try allocator.dupe(u8, try requiredString(data, "toolName"));
        errdefer allocator.free(tool_name);
        return .{ .external_tool_requested = .{
            .request_id = request_id,
            .tool_call_id = tool_call_id,
            .tool_name = tool_name,
            .arguments_json = try std.json.Stringify.valueAlloc(
                allocator,
                data.get("arguments") orelse .null,
                .{},
            ),
        } };
    }

    const owned_event_type = try allocator.dupe(u8, event_type);
    errdefer allocator.free(owned_event_type);
    return .{ .unknown = .{
        .event_type = owned_event_type,
        .data_json = try std.json.Stringify.valueAlloc(allocator, data_value, .{}),
    } };
}

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
