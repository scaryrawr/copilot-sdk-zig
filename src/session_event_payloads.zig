const std = @import("std");

var empty_raw_data: [0]u8 = .{};

pub const RawEvent = struct {
    data_json: []u8 = empty_raw_data[0..],
    owns_data: bool = false,

    pub fn deinit(self: *RawEvent, allocator: std.mem.Allocator) void {
        if (!self.owns_data) return;
        @memset(self.data_json, 0);
        allocator.free(self.data_json);
        self.data_json = empty_raw_data[0..];
        self.owns_data = false;
    }

    pub fn take(self: *RawEvent) RawEvent {
        const result = self.*;
        self.data_json = empty_raw_data[0..];
        self.owns_data = false;
        return result;
    }

    pub fn takeData(self: *RawEvent) []u8 {
        std.debug.assert(self.owns_data);
        const data_json = self.data_json;
        self.data_json = empty_raw_data[0..];
        self.owns_data = false;
        return data_json;
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

pub const AutomaticPermissionHandling = union(enum) {
    not_configured,
    handled,
    no_result,
    handler_failed: anyerror,
    delivery_failed: anyerror,
};

pub const AutomaticInteractionHandling = union(enum) {
    not_configured,
    handled,
    handler_failed: anyerror,
    invalid_result,
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

pub fn ownRawData(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !RawEvent {
    return .{
        .data_json = try std.json.Stringify.valueAlloc(allocator, value, .{}),
        .owns_data = true,
    };
}

test "raw event move clears ownership without double cleanup" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"secret\":true}", .{});
    defer parsed.deinit();

    var raw = try ownRawData(allocator, parsed.value);
    const data_json = raw.takeData();
    defer {
        @memset(data_json, 0);
        allocator.free(data_json);
    }

    try std.testing.expectEqual(@as(usize, 0), raw.data_json.len);
    raw.deinit(allocator);
    raw.deinit(allocator);
    try std.testing.expectEqualStrings("{\"secret\":true}", data_json);
}
