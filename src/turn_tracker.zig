const std = @import("std");
const session = @import("session.zig");

pub const ReceiptToken = struct {
    slot: u16,
    generation: u64,
};

pub const ReceiptKind = enum {
    raw,
    waited,
};

pub const ReceiptRead = union(enum) {
    pending: *std.Io.Event,
    completed: ?session.AssistantMessage,
    failure: anyerror,
};

const Receipt = struct {
    active: bool = false,
    generation: u64 = 0,
    waiter_attached: bool = false,
    message_id: ?[]u8 = null,
    turn_id: ?[]u8 = null,
    latest_assistant: ?session.AssistantMessage = null,
    completed: bool = false,
    failure: ?anyerror = null,
    ready: std.Io.Event = .unset,
};

const UserTurn = struct {
    message_id: []u8,
    turn_id: []u8,
};

const TurnFacts = struct {
    turn_id: []u8,
    latest_assistant: ?session.AssistantMessage = null,
    completed: bool = false,
};

pub const TurnTracker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    receipts: []Receipt,
    orphan_users: std.ArrayList(UserTurn) = .empty,
    orphan_turns: std.ArrayList(TurnFacts) = .empty,
    orphan_limit: usize,
    terminal_error: ?anyerror = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        receipt_limit: usize,
        orphan_limit: usize,
    ) !TurnTracker {
        if (receipt_limit == 0 or orphan_limit == 0) return error.InvalidTurnTrackerCapacity;
        const receipts = try allocator.alloc(Receipt, receipt_limit);
        @memset(receipts, .{});
        return .{
            .allocator = allocator,
            .io = io,
            .receipts = receipts,
            .orphan_limit = orphan_limit,
        };
    }

    pub fn deinit(self: *TurnTracker) void {
        for (self.receipts) |*receipt| self.clearReceipt(receipt);
        self.allocator.free(self.receipts);
        for (self.orphan_users.items) |item| {
            self.allocator.free(item.message_id);
            self.allocator.free(item.turn_id);
        }
        self.orphan_users.deinit(self.allocator);
        for (self.orphan_turns.items) |*item| self.deinitTurnFacts(item);
        self.orphan_turns.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn reserve(self: *TurnTracker, kind: ReceiptKind) !ReceiptToken {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.terminal_error) |err| return err;
        for (self.receipts, 0..) |*receipt, index| {
            if (receipt.active) continue;
            const generation = nextGeneration(receipt.generation);
            receipt.* = .{
                .active = true,
                .generation = generation,
                .waiter_attached = kind == .waited,
            };
            return .{ .slot = @intCast(index), .generation = generation };
        }
        return error.TooManyOutstandingTurns;
    }

    pub fn hasActiveReceipts(self: *TurnTracker) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.receipts) |receipt| {
            if (receipt.active) return true;
        }
        return false;
    }

    pub fn bindMessageId(
        self: *TurnTracker,
        token: ReceiptToken,
        message_id: []const u8,
    ) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const receipt = self.getReceipt(token) orelse return error.InvalidTurnReceipt;
        if (receipt.message_id != null) return error.TurnReceiptAlreadyBound;
        receipt.message_id = try self.allocator.dupe(u8, message_id);
        if (self.takeUserTurn(message_id)) |user_turn| {
            defer {
                self.allocator.free(user_turn.message_id);
                self.allocator.free(user_turn.turn_id);
            }
            try self.bindTurn(receipt, user_turn.turn_id);
        }
        self.clearOrphansIfNoUnboundReceipt();
    }

    pub fn failReceipt(
        self: *TurnTracker,
        token: ReceiptToken,
        err: anyerror,
    ) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const receipt = self.getReceipt(token) orelse return;
        receipt.failure = err;
        receipt.ready.set(self.io);
        if (!receipt.waiter_attached) self.clearReceipt(receipt);
    }

    pub fn detachWaiter(self: *TurnTracker, token: ReceiptToken) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const receipt = self.getReceipt(token) orelse return;
        receipt.waiter_attached = false;
        if (receipt.completed or receipt.failure != null) self.clearReceipt(receipt);
    }

    pub fn abandon(self: *TurnTracker, token: ReceiptToken) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const receipt = self.getReceipt(token) orelse return;
        self.clearReceipt(receipt);
    }

    pub fn inspect(self: *TurnTracker, token: ReceiptToken) !ReceiptRead {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const receipt = self.getReceipt(token) orelse return error.InvalidTurnReceipt;
        if (receipt.failure) |err| {
            self.clearReceipt(receipt);
            return .{ .failure = err };
        }
        if (receipt.completed) {
            const result = receipt.latest_assistant;
            receipt.latest_assistant = null;
            self.clearReceipt(receipt);
            return .{ .completed = result };
        }
        receipt.ready.reset();
        return .{ .pending = &receipt.ready };
    }

    pub fn observe(self: *TurnTracker, event: session.SessionEvent) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        switch (event) {
            .user_message => |payload| {
                const message_id = payload.data.message_id orelse return;
                const turn_id = payload.data.turn_id orelse return;
                if (self.findByMessage(message_id)) |receipt| {
                    try self.bindTurn(receipt, turn_id);
                    self.clearOrphansIfNoUnboundReceipt();
                } else if (self.hasUnboundReceipt()) {
                    try self.storeUserTurn(message_id, turn_id);
                }
            },
            .assistant_message => |message| {
                const turn_id = message.turn_id orelse return;
                for (self.receipts) |*receipt| {
                    if (!receipt.active) continue;
                    const candidate = receipt.turn_id orelse continue;
                    if (!std.mem.eql(u8, candidate, turn_id)) continue;
                    try self.replaceAssistant(receipt, event);
                }
                if (self.hasUnboundReceipt()) {
                    try self.storeAssistant(turn_id, event);
                }
            },
            .assistant_turn_end => |payload| {
                const turn_id = payload.data.turn_id;
                for (self.receipts) |*receipt| {
                    if (!receipt.active) continue;
                    const candidate = receipt.turn_id orelse continue;
                    if (!std.mem.eql(u8, candidate, turn_id)) continue;
                    self.completeReceipt(receipt);
                }
                if (self.hasUnboundReceipt()) {
                    try self.storeTurnEnd(turn_id);
                }
            },
            .session_error => self.failAllLocked(error.CopilotSessionError),
            else => {},
        }
    }

    pub fn failAll(self: *TurnTracker, err: anyerror) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.terminal_error == null) self.terminal_error = err;
        self.failAllLocked(err);
    }

    pub fn failActive(self: *TurnTracker, err: anyerror) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.failAllLocked(err);
    }

    fn failAllLocked(self: *TurnTracker, err: anyerror) void {
        for (self.receipts) |*receipt| {
            if (!receipt.active) continue;
            if (receipt.completed) continue;
            receipt.failure = err;
            receipt.ready.set(self.io);
            if (!receipt.waiter_attached) self.clearReceipt(receipt);
        }
    }

    fn bindTurn(self: *TurnTracker, receipt: *Receipt, turn_id: []const u8) !void {
        if (receipt.turn_id) |existing| {
            if (!std.mem.eql(u8, existing, turn_id)) {
                receipt.failure = error.InvalidTurnCorrelation;
                receipt.ready.set(self.io);
                if (!receipt.waiter_attached) self.clearReceipt(receipt);
            }
            return;
        }
        receipt.turn_id = try self.allocator.dupe(u8, turn_id);
        if (self.findOrphanTurn(turn_id)) |facts| {
            if (facts.latest_assistant) |message| {
                const event = session.SessionEvent{ .assistant_message = message };
                try self.replaceAssistant(receipt, event);
            }
            if (facts.completed) self.completeReceipt(receipt);
        }
    }

    fn replaceAssistant(
        self: *TurnTracker,
        receipt: *Receipt,
        event: session.SessionEvent,
    ) !void {
        const cloned = try session.cloneEvent(self.allocator, event);
        if (receipt.latest_assistant) |previous| previous.deinit(self.allocator);
        receipt.latest_assistant = cloned.assistant_message;
    }

    fn completeReceipt(self: *TurnTracker, receipt: *Receipt) void {
        receipt.completed = true;
        receipt.ready.set(self.io);
        if (!receipt.waiter_attached) self.clearReceipt(receipt);
    }

    fn storeUserTurn(
        self: *TurnTracker,
        message_id: []const u8,
        turn_id: []const u8,
    ) !void {
        for (self.orphan_users.items) |item| {
            if (!std.mem.eql(u8, item.message_id, message_id)) continue;
            if (!std.mem.eql(u8, item.turn_id, turn_id)) return error.InvalidTurnCorrelation;
            return;
        }
        if (self.orphan_users.items.len == self.orphan_limit) {
            const evicted = self.orphan_users.orderedRemove(0);
            self.allocator.free(evicted.message_id);
            self.allocator.free(evicted.turn_id);
        }
        const owned_message_id = try self.allocator.dupe(u8, message_id);
        errdefer self.allocator.free(owned_message_id);
        try self.orphan_users.append(self.allocator, .{
            .message_id = owned_message_id,
            .turn_id = try self.allocator.dupe(u8, turn_id),
        });
    }

    fn storeAssistant(
        self: *TurnTracker,
        turn_id: []const u8,
        event: session.SessionEvent,
    ) !void {
        if (self.findOrphanTurn(turn_id)) |facts| {
            const cloned = try session.cloneEvent(self.allocator, event);
            if (facts.latest_assistant) |previous| previous.deinit(self.allocator);
            facts.latest_assistant = cloned.assistant_message;
            return;
        }
        if (self.orphan_turns.items.len == self.orphan_limit) {
            var evicted = self.orphan_turns.orderedRemove(0);
            self.deinitTurnFacts(&evicted);
        }
        const owned_turn_id = try self.allocator.dupe(u8, turn_id);
        errdefer self.allocator.free(owned_turn_id);
        var cloned = try session.cloneEvent(self.allocator, event);
        errdefer cloned.deinit(self.allocator);
        try self.orphan_turns.append(self.allocator, .{
            .turn_id = owned_turn_id,
            .latest_assistant = cloned.assistant_message,
        });
    }

    fn storeTurnEnd(self: *TurnTracker, turn_id: []const u8) !void {
        if (self.findOrphanTurn(turn_id)) |facts| {
            facts.completed = true;
            return;
        }
        if (self.orphan_turns.items.len == self.orphan_limit) {
            var evicted = self.orphan_turns.orderedRemove(0);
            self.deinitTurnFacts(&evicted);
        }
        try self.orphan_turns.append(self.allocator, .{
            .turn_id = try self.allocator.dupe(u8, turn_id),
            .completed = true,
        });
    }

    fn findByMessage(self: *TurnTracker, message_id: []const u8) ?*Receipt {
        for (self.receipts) |*receipt| {
            if (!receipt.active) continue;
            const candidate = receipt.message_id orelse continue;
            if (std.mem.eql(u8, candidate, message_id)) return receipt;
        }
        return null;
    }

    fn hasUnboundReceipt(self: *TurnTracker) bool {
        for (self.receipts) |receipt| {
            if (receipt.active and receipt.turn_id == null) return true;
        }
        return false;
    }

    fn clearOrphansIfNoUnboundReceipt(self: *TurnTracker) void {
        if (self.hasUnboundReceipt()) return;
        for (self.orphan_users.items) |item| {
            self.allocator.free(item.message_id);
            self.allocator.free(item.turn_id);
        }
        self.orphan_users.clearRetainingCapacity();
        for (self.orphan_turns.items) |*item| self.deinitTurnFacts(item);
        self.orphan_turns.clearRetainingCapacity();
    }

    fn findOrphanTurn(self: *TurnTracker, turn_id: []const u8) ?*TurnFacts {
        for (self.orphan_turns.items) |*facts| {
            if (std.mem.eql(u8, facts.turn_id, turn_id)) return facts;
        }
        return null;
    }

    fn takeUserTurn(self: *TurnTracker, message_id: []const u8) ?UserTurn {
        for (self.orphan_users.items, 0..) |item, index| {
            if (std.mem.eql(u8, item.message_id, message_id))
                return self.orphan_users.orderedRemove(index);
        }
        return null;
    }

    fn getReceipt(self: *TurnTracker, token: ReceiptToken) ?*Receipt {
        if (token.slot >= self.receipts.len) return null;
        const receipt = &self.receipts[token.slot];
        if (!receipt.active or receipt.generation != token.generation) return null;
        return receipt;
    }

    fn clearReceipt(self: *TurnTracker, receipt: *Receipt) void {
        const generation = receipt.generation;
        if (receipt.message_id) |value| self.allocator.free(value);
        if (receipt.turn_id) |value| self.allocator.free(value);
        if (receipt.latest_assistant) |value| value.deinit(self.allocator);
        receipt.* = .{ .generation = generation };
    }

    fn deinitTurnFacts(self: *TurnTracker, facts: *TurnFacts) void {
        self.allocator.free(facts.turn_id);
        if (facts.latest_assistant) |message| message.deinit(self.allocator);
    }
};

fn nextGeneration(current: u64) u64 {
    const next = current +% 1;
    return if (next == 0) 1 else next;
}

fn parseEvent(allocator: std.mem.Allocator, json: []const u8) !session.SessionEvent {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    return session.parseEvent(allocator, parsed.value);
}

fn observeTurn(
    tracker: *TurnTracker,
    message_id: []const u8,
    turn_id: []const u8,
    answer: []const u8,
) !void {
    const allocator = tracker.allocator;
    const user_json = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"user.message\",\"data\":{{\"content\":\"p\",\"messageId\":\"{s}\",\"turnId\":\"{s}\"}}}}",
        .{ message_id, turn_id },
    );
    defer allocator.free(user_json);
    var user = try parseEvent(allocator, user_json);
    defer user.deinit(allocator);
    try tracker.observe(user);

    const assistant_json = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"assistant.message\",\"data\":{{\"content\":\"{s}\",\"messageId\":\"a-{s}\",\"turnId\":\"{s}\"}}}}",
        .{ answer, turn_id, turn_id },
    );
    defer allocator.free(assistant_json);
    var assistant = try parseEvent(allocator, assistant_json);
    defer assistant.deinit(allocator);
    try tracker.observe(assistant);

    const end_json = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"assistant.turn_end\",\"data\":{{\"turnId\":\"{s}\"}}}}",
        .{turn_id},
    );
    defer allocator.free(end_json);
    var turn_end = try parseEvent(allocator, end_json);
    defer turn_end.deinit(allocator);
    try tracker.observe(turn_end);
}

test "timeout then retry keeps turns isolated" {
    var tracker = try TurnTracker.init(std.testing.allocator, std.testing.io, 4, 8);
    defer tracker.deinit();

    const timed_out = try tracker.reserve(.waited);
    try tracker.bindMessageId(timed_out, "message-old");
    tracker.detachWaiter(timed_out);

    const retry = try tracker.reserve(.waited);
    try tracker.bindMessageId(retry, "message-new");

    try observeTurn(&tracker, "message-old", "turn-old", "old");
    try std.testing.expect((try tracker.inspect(retry)) == .pending);

    try observeTurn(&tracker, "message-new", "turn-new", "new");
    const result = try tracker.inspect(retry);
    var message = result.completed.?;
    defer message.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("new", message.content);
}

test "a prior raw send cannot satisfy a later waiter" {
    var tracker = try TurnTracker.init(std.testing.allocator, std.testing.io, 4, 8);
    defer tracker.deinit();

    const raw = try tracker.reserve(.raw);
    try tracker.bindMessageId(raw, "message-raw");
    const waited = try tracker.reserve(.waited);
    try tracker.bindMessageId(waited, "message-waited");

    try observeTurn(&tracker, "message-raw", "turn-raw", "raw");
    try std.testing.expect((try tracker.inspect(waited)) == .pending);

    try observeTurn(&tracker, "message-waited", "turn-waited", "waited");
    const result = try tracker.inspect(waited);
    var message = result.completed.?;
    defer message.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("waited", message.content);
}

test "shared turn facts fan out to every matching receipt" {
    var tracker = try TurnTracker.init(std.testing.allocator, std.testing.io, 4, 8);
    defer tracker.deinit();

    const first = try tracker.reserve(.waited);
    try tracker.bindMessageId(first, "message-first");
    const second = try tracker.reserve(.waited);
    try tracker.bindMessageId(second, "message-second");

    var assistant = try parseEvent(std.testing.allocator,
        \\{"type":"assistant.message","data":{"content":"shared","messageId":"assistant","turnId":"turn-shared"}}
    );
    defer assistant.deinit(std.testing.allocator);
    try tracker.observe(assistant);
    var turn_end = try parseEvent(std.testing.allocator,
        \\{"type":"assistant.turn_end","data":{"turnId":"turn-shared"}}
    );
    defer turn_end.deinit(std.testing.allocator);
    try tracker.observe(turn_end);

    var first_user = try parseEvent(std.testing.allocator,
        \\{"type":"user.message","data":{"content":"p","messageId":"message-first","turnId":"turn-shared"}}
    );
    defer first_user.deinit(std.testing.allocator);
    try tracker.observe(first_user);
    var second_user = try parseEvent(std.testing.allocator,
        \\{"type":"user.message","data":{"content":"p","messageId":"message-second","turnId":"turn-shared"}}
    );
    defer second_user.deinit(std.testing.allocator);
    try tracker.observe(second_user);

    const first_result = try tracker.inspect(first);
    var first_message = first_result.completed.?;
    defer first_message.deinit(std.testing.allocator);
    const second_result = try tracker.inspect(second);
    var second_message = second_result.completed.?;
    defer second_message.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("shared", first_message.content);
    try std.testing.expectEqualStrings("shared", second_message.content);
    try std.testing.expect(first_message.content.ptr != second_message.content.ptr);
}

test "shared turn facts remain available for a later correlation" {
    var tracker = try TurnTracker.init(std.testing.allocator, std.testing.io, 4, 8);
    defer tracker.deinit();

    const first = try tracker.reserve(.waited);
    try tracker.bindMessageId(first, "message-first");
    const second = try tracker.reserve(.waited);
    try tracker.bindMessageId(second, "message-second");

    var first_user = try parseEvent(std.testing.allocator,
        \\{"type":"user.message","data":{"content":"p","messageId":"message-first","turnId":"turn-shared"}}
    );
    defer first_user.deinit(std.testing.allocator);
    try tracker.observe(first_user);
    var assistant = try parseEvent(std.testing.allocator,
        \\{"type":"assistant.message","data":{"content":"shared","messageId":"assistant","turnId":"turn-shared"}}
    );
    defer assistant.deinit(std.testing.allocator);
    try tracker.observe(assistant);
    var turn_end = try parseEvent(std.testing.allocator,
        \\{"type":"assistant.turn_end","data":{"turnId":"turn-shared"}}
    );
    defer turn_end.deinit(std.testing.allocator);
    try tracker.observe(turn_end);

    var second_user = try parseEvent(std.testing.allocator,
        \\{"type":"user.message","data":{"content":"p","messageId":"message-second","turnId":"turn-shared"}}
    );
    defer second_user.deinit(std.testing.allocator);
    try tracker.observe(second_user);

    const first_result = try tracker.inspect(first);
    var first_message = first_result.completed.?;
    defer first_message.deinit(std.testing.allocator);
    const second_result = try tracker.inspect(second);
    var second_message = second_result.completed.?;
    defer second_message.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("shared", first_message.content);
    try std.testing.expectEqualStrings("shared", second_message.content);
    try std.testing.expect(first_message.content.ptr != second_message.content.ptr);
}

test "unrelated completed turns are bounded and do not fail active waits" {
    var tracker = try TurnTracker.init(std.testing.allocator, std.testing.io, 2, 2);
    defer tracker.deinit();

    const waiting = try tracker.reserve(.waited);
    try observeTurn(&tracker, "other-1", "turn-1", "one");
    try observeTurn(&tracker, "other-2", "turn-2", "two");
    try observeTurn(&tracker, "message-3", "turn-3", "three");
    try std.testing.expectEqual(@as(usize, 2), tracker.orphan_users.items.len);
    try std.testing.expectEqual(@as(usize, 2), tracker.orphan_turns.items.len);

    try tracker.bindMessageId(waiting, "message-3");
    const result = try tracker.inspect(waiting);
    var message = result.completed.?;
    defer message.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("three", message.content);
    try std.testing.expectEqual(@as(usize, 0), tracker.orphan_users.items.len);
    try std.testing.expectEqual(@as(usize, 0), tracker.orphan_turns.items.len);
}

test "failing active receipts does not reject future reservations" {
    var tracker = try TurnTracker.init(
        std.testing.allocator,
        std.testing.io,
        2,
        2,
    );
    defer tracker.deinit();

    const failed = try tracker.reserve(.waited);
    tracker.failActive(error.CopilotSessionError);
    switch (try tracker.inspect(failed)) {
        .failure => |err| try std.testing.expectEqual(
            error.CopilotSessionError,
            err,
        ),
        else => return error.TestUnexpectedResult,
    }

    const next = try tracker.reserve(.raw);
    tracker.abandon(next);
}

test "conflicting raw turn correlation releases its receipt" {
    var tracker = try TurnTracker.init(std.testing.allocator, std.testing.io, 2, 8);
    defer tracker.deinit();

    const raw = try tracker.reserve(.raw);
    try tracker.bindMessageId(raw, "message-raw");
    var first = try parseEvent(std.testing.allocator,
        \\{"type":"user.message","data":{"content":"p","messageId":"message-raw","turnId":"turn-1"}}
    );
    defer first.deinit(std.testing.allocator);
    try tracker.observe(first);
    var conflicting = try parseEvent(std.testing.allocator,
        \\{"type":"user.message","data":{"content":"p","messageId":"message-raw","turnId":"turn-2"}}
    );
    defer conflicting.deinit(std.testing.allocator);
    try tracker.observe(conflicting);

    const first_reused = try tracker.reserve(.raw);
    const second_reused = try tracker.reserve(.raw);
    try std.testing.expectError(
        error.TooManyOutstandingTurns,
        tracker.reserve(.raw),
    );
    tracker.abandon(first_reused);
    tracker.abandon(second_reused);
}
