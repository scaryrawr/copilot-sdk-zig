const std = @import("std");

pub const RawEvent = struct {
    data_json: []u8 = @constCast(&[_]u8{}),

    pub fn deinit(self: *RawEvent, allocator: std.mem.Allocator) void {
        if (self.data_json.len == 0) return;
        @memset(self.data_json, 0);
        allocator.free(self.data_json);
        self.data_json = @constCast(&[_]u8{});
    }

    pub fn take(self: *RawEvent) RawEvent {
        const result = self.*;
        self.* = .{};
        return result;
    }
};

pub const UnknownEvent = struct {
    event_type: []u8,
    data_json: []u8,

    pub fn deinit(self: *UnknownEvent, allocator: std.mem.Allocator) void {
        @memset(self.event_type, 0);
        allocator.free(self.event_type);
        @memset(self.data_json, 0);
        allocator.free(self.data_json);
    }
};

pub const AssistantMessage = struct {
    content: []u8,
    message_id: ?[]u8,
    raw: RawEvent = .{},

    pub fn deinit(self: AssistantMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        if (self.message_id) |message_id| allocator.free(message_id);
        var raw = self.raw;
        raw.deinit(allocator);
    }
};

pub const AssistantMessageDelta = struct {
    delta_content: []u8,
    message_id: []u8,
    raw: RawEvent = .{},

    pub fn deinit(self: AssistantMessageDelta, allocator: std.mem.Allocator) void {
        allocator.free(self.delta_content);
        allocator.free(self.message_id);
        var raw = self.raw;
        raw.deinit(allocator);
    }
};

pub const AssistantReasoning = struct {
    reasoning_id: []u8,
    content: []u8,
    rte: ?bool = null,
    raw: RawEvent = .{},

    pub fn deinit(self: AssistantReasoning, allocator: std.mem.Allocator) void {
        allocator.free(self.reasoning_id);
        allocator.free(self.content);
        var raw = self.raw;
        raw.deinit(allocator);
    }
};

pub const AssistantReasoningDelta = struct {
    reasoning_id: []u8,
    delta_content: []u8,
    raw: RawEvent = .{},

    pub fn deinit(self: AssistantReasoningDelta, allocator: std.mem.Allocator) void {
        allocator.free(self.reasoning_id);
        allocator.free(self.delta_content);
        var raw = self.raw;
        raw.deinit(allocator);
    }
};

pub const SessionError = struct {
    message: []u8,
    raw: RawEvent = .{},

    pub fn deinit(self: SessionError, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        var raw = self.raw;
        raw.deinit(allocator);
    }
};

pub const SessionIdle = struct {
    aborted: ?bool = null,
    mode: ?[]u8 = null,
    raw: RawEvent = .{},

    pub fn deinit(self: SessionIdle, allocator: std.mem.Allocator) void {
        if (self.mode) |mode| allocator.free(mode);
        var raw = self.raw;
        raw.deinit(allocator);
    }
};

pub const AutomaticPermissionHandling = union(enum) {
    not_configured,
    handled,
    no_result,
    handler_failed: anyerror,
    delivery_failed: anyerror,
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

pub const PermissionRequested = struct {
    request_id: []u8,
    permission_request_json: []u8,
    managed_approval_required: bool = false,
    automatic_handling: AutomaticPermissionHandling = .not_configured,
    raw: RawEvent = .{},

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

    pub fn deinit(self: PermissionRequested, allocator: std.mem.Allocator) void {
        allocator.free(self.request_id);
        allocator.free(self.permission_request_json);
        var raw = self.raw;
        raw.deinit(allocator);
    }
};

pub const ExternalToolRequested = struct {
    request_id: []u8,
    tool_call_id: []u8,
    tool_name: []u8,
    arguments_json: []u8,
    raw: RawEvent = .{},

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

    pub fn deinit(self: ExternalToolRequested, allocator: std.mem.Allocator) void {
        allocator.free(self.request_id);
        allocator.free(self.tool_call_id);
        allocator.free(self.tool_name);
        allocator.free(self.arguments_json);
        var raw = self.raw;
        raw.deinit(allocator);
    }
};

pub fn requiredObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.InvalidSessionEvent,
    };
}

pub fn requiredString(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
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

pub fn ownRawData(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !RawEvent {
    return .{
        .data_json = try std.json.Stringify.valueAlloc(allocator, value, .{}),
    };
}

pub fn parseAssistantMessage(
    allocator: std.mem.Allocator,
    data: std.json.ObjectMap,
) !AssistantMessage {
    const content = try allocator.dupe(u8, try requiredString(data, "content"));
    errdefer allocator.free(content);
    const raw_message_id = try optionalString(data, "messageId");
    return .{
        .content = content,
        .message_id = if (raw_message_id) |id| try allocator.dupe(u8, id) else null,
    };
}

pub fn parseAssistantMessageDelta(
    allocator: std.mem.Allocator,
    data: std.json.ObjectMap,
) !AssistantMessageDelta {
    const delta_content = try allocator.dupe(u8, try requiredString(data, "deltaContent"));
    errdefer allocator.free(delta_content);
    return .{
        .delta_content = delta_content,
        .message_id = try allocator.dupe(u8, try requiredString(data, "messageId")),
    };
}

pub fn parseAssistantReasoning(
    allocator: std.mem.Allocator,
    data: std.json.ObjectMap,
) !AssistantReasoning {
    const reasoning_id = try allocator.dupe(u8, try requiredString(data, "reasoningId"));
    errdefer allocator.free(reasoning_id);
    return .{
        .reasoning_id = reasoning_id,
        .content = try allocator.dupe(u8, try requiredString(data, "content")),
        .rte = try optionalBool(data, "rte"),
    };
}

pub fn parseAssistantReasoningDelta(
    allocator: std.mem.Allocator,
    data: std.json.ObjectMap,
) !AssistantReasoningDelta {
    const reasoning_id = try allocator.dupe(u8, try requiredString(data, "reasoningId"));
    errdefer allocator.free(reasoning_id);
    return .{
        .reasoning_id = reasoning_id,
        .delta_content = try allocator.dupe(u8, try requiredString(data, "deltaContent")),
    };
}

pub fn parseSessionIdle(
    allocator: std.mem.Allocator,
    data: std.json.ObjectMap,
) !SessionIdle {
    const raw_mode = try optionalString(data, "mode");
    return .{
        .aborted = try optionalBool(data, "aborted"),
        .mode = if (raw_mode) |mode| try allocator.dupe(u8, mode) else null,
    };
}

pub fn parseSessionError(
    allocator: std.mem.Allocator,
    data: std.json.ObjectMap,
) !SessionError {
    return .{
        .message = try allocator.dupe(u8, try requiredString(data, "message")),
    };
}

pub fn parsePermissionRequested(
    allocator: std.mem.Allocator,
    data: std.json.ObjectMap,
) !PermissionRequested {
    const permission_request = data.get("permissionRequest") orelse
        return error.InvalidSessionEvent;
    const permission_request_object = try requiredObject(permission_request);
    const managed_approval_required = if (permission_request_object.get(
        "managedApprovalRequired",
    )) |managed_value| switch (managed_value) {
        .bool => |boolean| boolean,
        else => return error.InvalidSessionEvent,
    } else false;
    const request_id = try allocator.dupe(u8, try requiredString(data, "requestId"));
    errdefer allocator.free(request_id);
    return .{
        .request_id = request_id,
        .managed_approval_required = managed_approval_required,
        .permission_request_json = try std.json.Stringify.valueAlloc(
            allocator,
            permission_request,
            .{},
        ),
    };
}

pub fn parseExternalToolRequested(
    allocator: std.mem.Allocator,
    data: std.json.ObjectMap,
) !ExternalToolRequested {
    const request_id = try allocator.dupe(u8, try requiredString(data, "requestId"));
    errdefer allocator.free(request_id);
    const tool_call_id = try allocator.dupe(u8, try requiredString(data, "toolCallId"));
    errdefer allocator.free(tool_call_id);
    const tool_name = try allocator.dupe(u8, try requiredString(data, "toolName"));
    errdefer allocator.free(tool_name);
    return .{
        .request_id = request_id,
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .arguments_json = try std.json.Stringify.valueAlloc(
            allocator,
            data.get("arguments") orelse .null,
            .{},
        ),
    };
}
