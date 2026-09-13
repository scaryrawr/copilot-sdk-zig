const std = @import("std");

pub const lifecycle_queue_capacity: usize = 256;

fn freeOptional(allocator: std.mem.Allocator, value: ?[]u8) void {
    if (value) |slice| allocator.free(slice);
}

fn dupeOptional(
    allocator: std.mem.Allocator,
    value: ?[]const u8,
) std.mem.Allocator.Error!?[]u8 {
    return if (value) |slice| try allocator.dupe(u8, slice) else null;
}

pub const SessionId = struct {
    allocator: std.mem.Allocator,
    value: []u8,

    pub fn deinit(self: *SessionId) void {
        self.allocator.free(self.value);
        self.* = undefined;
    }
};

pub const PingResponse = struct {
    allocator: std.mem.Allocator,
    message: []u8,
    timestamp: []u8,
    protocol_version: ?u64,

    pub fn deinit(self: *PingResponse) void {
        self.allocator.free(self.message);
        self.allocator.free(self.timestamp);
        self.* = undefined;
    }
};

pub const ClientStatus = struct {
    allocator: std.mem.Allocator,
    version: []u8,
    protocol_version: u64,

    pub fn deinit(self: *ClientStatus) void {
        self.allocator.free(self.version);
        self.* = undefined;
    }
};

pub const AuthStatus = struct {
    allocator: std.mem.Allocator,
    is_authenticated: bool,
    auth_type: ?[]u8,
    host: ?[]u8,
    login: ?[]u8,
    status_message: ?[]u8,

    pub fn deinit(self: *AuthStatus) void {
        freeOptional(self.allocator, self.auth_type);
        freeOptional(self.allocator, self.host);
        freeOptional(self.allocator, self.login);
        freeOptional(self.allocator, self.status_message);
        self.* = undefined;
    }
};

pub const SessionListFilter = struct {
    cwd: ?[]const u8 = null,
    git_root: ?[]const u8 = null,
    repository: ?[]const u8 = null,
    branch: ?[]const u8 = null,
};

pub const SessionContext = struct {
    allocator: std.mem.Allocator,
    cwd: []u8,
    git_root: ?[]u8,
    repository: ?[]u8,
    branch: ?[]u8,

    pub fn deinit(self: *SessionContext) void {
        self.allocator.free(self.cwd);
        freeOptional(self.allocator, self.git_root);
        freeOptional(self.allocator, self.repository);
        freeOptional(self.allocator, self.branch);
        self.* = undefined;
    }
};

pub const SessionMetadata = struct {
    allocator: std.mem.Allocator,
    session_id: []u8,
    start_time: []u8,
    modified_time: []u8,
    summary: ?[]u8,
    is_remote: bool,
    context: ?SessionContext,

    pub fn deinit(self: *SessionMetadata) void {
        self.allocator.free(self.session_id);
        self.allocator.free(self.start_time);
        self.allocator.free(self.modified_time);
        freeOptional(self.allocator, self.summary);
        if (self.context) |*context| context.deinit();
        self.* = undefined;
    }
};

pub const SessionCatalog = struct {
    allocator: std.mem.Allocator,
    sessions: []SessionMetadata,

    pub fn deinit(self: *SessionCatalog) void {
        for (self.sessions) |*metadata| metadata.deinit();
        self.allocator.free(self.sessions);
        self.* = undefined;
    }
};

pub const SessionLifecycleType = union(enum) {
    created,
    deleted,
    updated,
    foreground,
    background,
    unknown: []u8,
};

pub const SessionLifecycleMetadata = struct {
    allocator: std.mem.Allocator,
    start_time: []u8,
    modified_time: []u8,
    summary: ?[]u8,

    pub fn deinit(self: *SessionLifecycleMetadata) void {
        self.allocator.free(self.start_time);
        self.allocator.free(self.modified_time);
        freeOptional(self.allocator, self.summary);
        self.* = undefined;
    }
};

pub const SessionLifecycleEvent = struct {
    allocator: std.mem.Allocator,
    event_type: SessionLifecycleType,
    session_id: []u8,
    metadata: ?SessionLifecycleMetadata,

    pub fn deinit(self: *SessionLifecycleEvent) void {
        switch (self.event_type) {
            .unknown => |name| self.allocator.free(name),
            else => {},
        }
        self.allocator.free(self.session_id);
        if (self.metadata) |*metadata| metadata.deinit();
        self.* = undefined;
    }
};

pub const SessionLifecycleOverflow = struct {
    dropped_count: usize,
};

pub const SessionLifecycleDelivery = union(enum) {
    event: SessionLifecycleEvent,
    overflow: SessionLifecycleOverflow,

    pub fn deinit(self: *SessionLifecycleDelivery) void {
        switch (self.*) {
            .event => |*event| event.deinit(),
            .overflow => {},
        }
        self.* = undefined;
    }
};

pub const LifecycleQueue = struct {
    items: [lifecycle_queue_capacity]SessionLifecycleEvent = undefined,
    head: usize = 0,
    len: usize = 0,
    dropped_count: usize = 0,

    pub fn push(self: *LifecycleQueue, event_value: SessionLifecycleEvent) void {
        var event = event_value;
        if (self.dropped_count != 0 or self.len == lifecycle_queue_capacity) {
            event.deinit();
            self.dropped_count +|= 1;
            return;
        }
        const index = (self.head + self.len) % lifecycle_queue_capacity;
        self.items[index] = event;
        self.len += 1;
    }

    pub fn popDelivery(self: *LifecycleQueue) ?SessionLifecycleDelivery {
        if (self.len != 0) {
            const event = self.items[self.head];
            self.head = (self.head + 1) % lifecycle_queue_capacity;
            self.len -= 1;
            return .{ .event = event };
        }
        if (self.dropped_count != 0) {
            const count = self.dropped_count;
            self.dropped_count = 0;
            return .{ .overflow = .{ .dropped_count = count } };
        }
        return null;
    }

    pub fn deinit(self: *LifecycleQueue) void {
        while (self.len != 0) {
            var delivery = self.popDelivery().?;
            delivery.deinit();
        }
        self.dropped_count = 0;
        self.* = .{};
    }
};

pub const PingParams = struct {
    message: ?[]const u8 = null,
};

pub const EmptyParams = struct {};

pub const PingResult = struct {
    message: []const u8,
    timestamp: []const u8,
    protocolVersion: ?u64 = null,
};

pub const StatusGetResult = struct {
    version: []const u8,
    protocolVersion: u64,
};

pub const AuthGetStatusResult = struct {
    isAuthenticated: bool,
    authType: ?[]const u8 = null,
    host: ?[]const u8 = null,
    login: ?[]const u8 = null,
    statusMessage: ?[]const u8 = null,
};

pub const SessionListFilterWire = struct {
    cwd: ?[]const u8 = null,
    gitRoot: ?[]const u8 = null,
    repository: ?[]const u8 = null,
    branch: ?[]const u8 = null,
};

pub const SessionListParams = struct {
    filter: ?SessionListFilterWire = null,
};

pub const SessionContextWire = struct {
    cwd: []const u8,
    gitRoot: ?[]const u8 = null,
    repository: ?[]const u8 = null,
    branch: ?[]const u8 = null,
};

pub const SessionMetadataWire = struct {
    sessionId: []const u8,
    startTime: []const u8,
    modifiedTime: []const u8,
    summary: ?[]const u8 = null,
    isRemote: bool,
    context: ?SessionContextWire = null,
};

pub const SessionListResult = struct {
    sessions: []const SessionMetadataWire,
};

pub const SessionIdParams = struct {
    sessionId: []const u8,
};

pub const SessionGetMetadataResult = struct {
    session: ?SessionMetadataWire = null,
};

pub const OptionalSessionIdResult = struct {
    sessionId: ?[]const u8 = null,
};

pub const SuccessResult = struct {
    success: bool,
    @"error": ?[]const u8 = null,
};

pub const SessionGetMessagesResult = struct {
    events: []const std.json.Value,
};

pub fn lowerFilter(filter: ?SessionListFilter) SessionListParams {
    return .{ .filter = if (filter) |value| .{
        .cwd = value.cwd,
        .gitRoot = value.git_root,
        .repository = value.repository,
        .branch = value.branch,
    } else null };
}

pub fn ownPing(allocator: std.mem.Allocator, wire: PingResult) !PingResponse {
    const message = try allocator.dupe(u8, wire.message);
    errdefer allocator.free(message);
    const timestamp = try allocator.dupe(u8, wire.timestamp);
    return .{
        .allocator = allocator,
        .message = message,
        .timestamp = timestamp,
        .protocol_version = wire.protocolVersion,
    };
}

pub fn ownStatus(allocator: std.mem.Allocator, wire: StatusGetResult) !ClientStatus {
    return .{
        .allocator = allocator,
        .version = try allocator.dupe(u8, wire.version),
        .protocol_version = wire.protocolVersion,
    };
}

pub fn ownAuthStatus(
    allocator: std.mem.Allocator,
    wire: AuthGetStatusResult,
) !AuthStatus {
    const auth_type = try dupeOptional(allocator, wire.authType);
    errdefer freeOptional(allocator, auth_type);
    const host = try dupeOptional(allocator, wire.host);
    errdefer freeOptional(allocator, host);
    const login = try dupeOptional(allocator, wire.login);
    errdefer freeOptional(allocator, login);
    const status_message = try dupeOptional(allocator, wire.statusMessage);
    return .{
        .allocator = allocator,
        .is_authenticated = wire.isAuthenticated,
        .auth_type = auth_type,
        .host = host,
        .login = login,
        .status_message = status_message,
    };
}

pub fn ownSessionId(
    allocator: std.mem.Allocator,
    wire: OptionalSessionIdResult,
) !?SessionId {
    return if (wire.sessionId) |value| .{
        .allocator = allocator,
        .value = try allocator.dupe(u8, value),
    } else null;
}

fn ownContext(
    allocator: std.mem.Allocator,
    wire: SessionContextWire,
) !SessionContext {
    const cwd = try allocator.dupe(u8, wire.cwd);
    errdefer allocator.free(cwd);
    const git_root = try dupeOptional(allocator, wire.gitRoot);
    errdefer freeOptional(allocator, git_root);
    const repository = try dupeOptional(allocator, wire.repository);
    errdefer freeOptional(allocator, repository);
    const branch = try dupeOptional(allocator, wire.branch);
    return .{
        .allocator = allocator,
        .cwd = cwd,
        .git_root = git_root,
        .repository = repository,
        .branch = branch,
    };
}

pub fn ownMetadata(
    allocator: std.mem.Allocator,
    wire: SessionMetadataWire,
) !SessionMetadata {
    const session_id = try allocator.dupe(u8, wire.sessionId);
    errdefer allocator.free(session_id);
    const start_time = try allocator.dupe(u8, wire.startTime);
    errdefer allocator.free(start_time);
    const modified_time = try allocator.dupe(u8, wire.modifiedTime);
    errdefer allocator.free(modified_time);
    const summary = try dupeOptional(allocator, wire.summary);
    errdefer freeOptional(allocator, summary);
    var context = if (wire.context) |value| try ownContext(allocator, value) else null;
    errdefer if (context) |*value| value.deinit();
    return .{
        .allocator = allocator,
        .session_id = session_id,
        .start_time = start_time,
        .modified_time = modified_time,
        .summary = summary,
        .is_remote = wire.isRemote,
        .context = context,
    };
}

pub fn ownOptionalMetadata(
    allocator: std.mem.Allocator,
    wire: SessionGetMetadataResult,
) !?SessionMetadata {
    return if (wire.session) |value| try ownMetadata(allocator, value) else null;
}

pub fn ownCatalog(
    allocator: std.mem.Allocator,
    wire: SessionListResult,
) !SessionCatalog {
    const sessions = try allocator.alloc(SessionMetadata, wire.sessions.len);
    var initialized: usize = 0;
    errdefer {
        for (sessions[0..initialized]) |*metadata| metadata.deinit();
        allocator.free(sessions);
    }
    for (wire.sessions, sessions) |source, *target| {
        target.* = try ownMetadata(allocator, source);
        initialized += 1;
    }
    return .{ .allocator = allocator, .sessions = sessions };
}

pub const LifecycleParseError = error{
    MissingField,
    MalformedFieldType,
};

fn requiredString(
    object: std.json.ObjectMap,
    name: []const u8,
) LifecycleParseError![]const u8 {
    return switch (object.get(name) orelse return error.MissingField) {
        .string => |value| value,
        else => error.MalformedFieldType,
    };
}

fn optionalString(
    object: std.json.ObjectMap,
    name: []const u8,
) LifecycleParseError!?[]const u8 {
    return switch (object.get(name) orelse return null) {
        .string => |value| value,
        .null => null,
        else => error.MalformedFieldType,
    };
}

fn ownLifecycleType(
    allocator: std.mem.Allocator,
    name: []const u8,
) !SessionLifecycleType {
    if (std.mem.eql(u8, name, "session.created")) return .created;
    if (std.mem.eql(u8, name, "session.deleted")) return .deleted;
    if (std.mem.eql(u8, name, "session.updated")) return .updated;
    if (std.mem.eql(u8, name, "session.foreground")) return .foreground;
    if (std.mem.eql(u8, name, "session.background")) return .background;
    return .{ .unknown = try allocator.dupe(u8, name) };
}

fn ownLifecycleMetadata(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !SessionLifecycleMetadata {
    const object = switch (value) {
        .object => |object| object,
        else => return error.MalformedFieldType,
    };
    const start_time_value = try requiredString(object, "startTime");
    const modified_time_value = try requiredString(object, "modifiedTime");
    const summary_value = try optionalString(object, "summary");
    const start_time = try allocator.dupe(u8, start_time_value);
    errdefer allocator.free(start_time);
    const modified_time = try allocator.dupe(u8, modified_time_value);
    errdefer allocator.free(modified_time);
    const summary = try dupeOptional(allocator, summary_value);
    return .{
        .allocator = allocator,
        .start_time = start_time,
        .modified_time = modified_time,
        .summary = summary,
    };
}

pub fn parseLifecycleEvent(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) (LifecycleParseError || std.mem.Allocator.Error)!SessionLifecycleEvent {
    const object = switch (value) {
        .object => |object| object,
        else => return error.MalformedFieldType,
    };
    const type_name = try requiredString(object, "type");
    const session_id_value = try requiredString(object, "sessionId");
    const event_type = try ownLifecycleType(allocator, type_name);
    errdefer switch (event_type) {
        .unknown => |name| allocator.free(name),
        else => {},
    };
    const session_id = try allocator.dupe(u8, session_id_value);
    errdefer allocator.free(session_id);
    var metadata: ?SessionLifecycleMetadata = switch (object.get("metadata") orelse .null) {
        .null => null,
        else => |metadata_value| try ownLifecycleMetadata(allocator, metadata_value),
    };
    errdefer if (metadata) |*value_metadata| value_metadata.deinit();
    return .{
        .allocator = allocator,
        .event_type = event_type,
        .session_id = session_id,
        .metadata = metadata,
    };
}

test "lifecycle queue preserves prefix overflow marker and next epoch" {
    const allocator = std.testing.allocator;
    var queue: LifecycleQueue = .{};
    defer queue.deinit();

    for (0..lifecycle_queue_capacity + 2) |index| {
        queue.push(.{
            .allocator = allocator,
            .event_type = .created,
            .session_id = try std.fmt.allocPrint(allocator, "s-{d}", .{index}),
            .metadata = null,
        });
    }

    for (0..lifecycle_queue_capacity) |index| {
        var delivery = queue.popDelivery().?;
        defer delivery.deinit();
        try std.testing.expect(delivery == .event);
        const expected = try std.fmt.allocPrint(allocator, "s-{d}", .{index});
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, delivery.event.session_id);
    }
    const overflow = queue.popDelivery().?;
    try std.testing.expectEqual(@as(usize, 2), overflow.overflow.dropped_count);

    queue.push(.{
        .allocator = allocator,
        .event_type = .updated,
        .session_id = try allocator.dupe(u8, "next"),
        .metadata = null,
    });
    var next = queue.popDelivery().?;
    defer next.deinit();
    try std.testing.expectEqualStrings("next", next.event.session_id);
}

test "lifecycle queue dropped count saturates" {
    var queue: LifecycleQueue = .{ .dropped_count = std.math.maxInt(usize) };
    const allocator = std.testing.allocator;
    queue.push(.{
        .allocator = allocator,
        .event_type = .{ .unknown = try allocator.dupe(u8, "future") },
        .session_id = try allocator.dupe(u8, "s1"),
        .metadata = null,
    });
    const delivery = queue.popDelivery().?;
    try std.testing.expectEqual(std.math.maxInt(usize), delivery.overflow.dropped_count);
}

fn exerciseOwnedAdministration(allocator: std.mem.Allocator) !void {
    var ping = try ownPing(allocator, .{
        .message = "pong",
        .timestamp = "now",
        .protocolVersion = null,
    });
    defer ping.deinit();
    var auth = try ownAuthStatus(allocator, .{
        .isAuthenticated = true,
        .authType = "future-auth",
        .host = "github.com",
        .login = "octocat",
        .statusMessage = "ready",
    });
    defer auth.deinit();
    var catalog = try ownCatalog(allocator, .{ .sessions = &.{.{
        .sessionId = "session",
        .startTime = "start",
        .modifiedTime = "modified",
        .summary = "summary",
        .isRemote = false,
        .context = .{
            .cwd = "/work",
            .gitRoot = "/work",
            .repository = "owner/repo",
            .branch = "main",
        },
    }} });
    defer catalog.deinit();
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"type\":\"future\",\"sessionId\":\"session\"}",
        .{},
    );
    defer parsed.deinit();
    var lifecycle = try parseLifecycleEvent(allocator, parsed.value);
    defer lifecycle.deinit();
}

test "owned administration conversion rolls back every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseOwnedAdministration,
        .{},
    );
}

test "optional administration values preserve absence" {
    const allocator = std.testing.allocator;
    try std.testing.expect((try ownSessionId(allocator, .{})) == null);
    try std.testing.expect((try ownOptionalMetadata(allocator, .{})) == null);
    var auth = try ownAuthStatus(allocator, .{ .isAuthenticated = false });
    defer auth.deinit();
    try std.testing.expect(auth.auth_type == null);
    try std.testing.expect(auth.host == null);
    try std.testing.expect(auth.login == null);
    try std.testing.expect(auth.status_message == null);
}

test "full lifecycle wire values map to public tags" {
    const cases = [_]struct {
        wire: []const u8,
        tag: std.meta.Tag(SessionLifecycleType),
    }{
        .{ .wire = "session.created", .tag = .created },
        .{ .wire = "session.deleted", .tag = .deleted },
        .{ .wire = "session.updated", .tag = .updated },
        .{ .wire = "session.foreground", .tag = .foreground },
        .{ .wire = "session.background", .tag = .background },
    };

    for (cases) |case| {
        const event_type = try ownLifecycleType(std.testing.allocator, case.wire);
        defer switch (event_type) {
            .unknown => |name| std.testing.allocator.free(name),
            else => {},
        };
        try std.testing.expectEqual(case.tag, std.meta.activeTag(event_type));
    }
}
