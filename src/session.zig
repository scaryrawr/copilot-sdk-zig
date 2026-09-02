const std = @import("std");

pub const SessionConfig = struct {
    session_id: ?[]const u8 = null,
    model: ?[]const u8 = null,
    working_directory: ?[]const u8 = null,
    streaming: bool = false,
};

pub const MessageOptions = struct {
    prompt: []const u8,
};

pub const AssistantMessage = struct {
    content: []u8,
    message_id: ?[]u8,
};

pub const AssistantMessageDelta = struct {
    delta_content: []u8,
    message_id: []u8,
};

pub const SessionError = struct {
    message: []u8,
};

pub const UnknownEvent = struct {
    event_type: []u8,
    data_json: []u8,
};

pub const SessionEvent = union(enum) {
    assistant_message: AssistantMessage,
    assistant_message_delta: AssistantMessageDelta,
    session_idle,
    session_error: SessionError,
    unknown: UnknownEvent,

    pub fn deinit(self: *SessionEvent, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .assistant_message => |value| {
                allocator.free(value.content);
                if (value.message_id) |message_id| allocator.free(message_id);
            },
            .assistant_message_delta => |value| {
                allocator.free(value.delta_content);
                allocator.free(value.message_id);
            },
            .session_idle => {},
            .session_error => |value| allocator.free(value.message),
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
    if (std.mem.eql(u8, event_type, "session.idle")) return .session_idle;
    if (std.mem.eql(u8, event_type, "session.error")) {
        return .{ .session_error = .{
            .message = try allocator.dupe(u8, try requiredString(data, "message")),
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
