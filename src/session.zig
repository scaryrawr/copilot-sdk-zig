const std = @import("std");
const ProviderConfig = @import("provider.zig").ProviderConfig;

pub const SessionConfig = struct {
    session_id: ?[]const u8 = null,
    model: ?[]const u8 = null,
    provider: ?ProviderConfig = null,
    working_directory: ?[]const u8 = null,
    streaming: bool = false,
    tools: []const Tool = &.{},
    system_message: ?SystemMessageConfig = null,
    request_permission: bool = false,
};

pub const MessageOptions = struct {
    prompt: []const u8,
};

pub const CommandListOptions = struct {
    include_builtins: bool = true,
    include_skills: bool = true,
    include_client_commands: bool = true,
};

pub const CommandKind = enum {
    builtin,
    skill,
    client,
    unknown,

    pub fn fromString(value: []const u8) CommandKind {
        if (std.mem.eql(u8, value, "builtin")) return .builtin;
        if (std.mem.eql(u8, value, "skill")) return .skill;
        if (std.mem.eql(u8, value, "client")) return .client;
        return .unknown;
    }
};

pub const CommandInfo = struct {
    name: []u8,
    description: []u8,
    kind: CommandKind,
    allow_during_agent_execution: bool,

    fn deinit(self: *CommandInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        self.* = undefined;
    }
};

pub const CommandList = struct {
    allocator: std.mem.Allocator,
    commands: []CommandInfo,

    pub fn deinit(self: *CommandList) void {
        for (self.commands) |*command| command.deinit(self.allocator);
        self.allocator.free(self.commands);
        self.* = undefined;
    }
};

pub const AutoTier = enum {
    efficiency,
    balance,
    intelligence,
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

pub const SystemMessageMode = enum {
    append,
    replace,
};

pub const SystemMessageConfig = struct {
    mode: SystemMessageMode = .append,
    content: []const u8,
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

pub const PermissionRequested = struct {
    request_id: []u8,
    permission_request_json: []u8,

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
    session_idle: SessionIdle,
    session_error: SessionError,
    permission_requested: PermissionRequested,
    external_tool_requested: ExternalToolRequested,
    commands_changed,
    unknown: UnknownEvent,

    pub fn deinit(self: *SessionEvent, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .assistant_message => |value| value.deinit(allocator),
            .assistant_message_delta => |value| {
                allocator.free(value.delta_content);
                allocator.free(value.message_id);
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
            .commands_changed => {},
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
        return .{ .permission_requested = .{
            .request_id = try allocator.dupe(u8, try requiredString(data, "requestId")),
            .permission_request_json = try std.json.Stringify.valueAlloc(
                allocator,
                data.get("permissionRequest") orelse return error.InvalidSessionEvent,
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
    if (std.mem.eql(u8, event_type, "commands.changed")) {
        return .commands_changed;
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

test "commands changed is a typed event" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"commands.changed","data":{}}
    ,
        .{},
    );
    defer parsed.deinit();
    var event = try parseEvent(allocator, parsed.value);
    defer event.deinit(allocator);

    try std.testing.expect(event == .commands_changed);
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
