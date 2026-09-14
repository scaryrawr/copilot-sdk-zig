const std = @import("std");
const errors = @import("errors.zig");
const session = @import("session.zig");
const turn_tracker = @import("turn_tracker.zig");

pub const SubscriberToken = struct {
    slot: u16,
    generation: u64,
};

pub const ReadAction = union(enum) {
    event: session.SessionEvent,
    wait: *std.Io.Event,
    overflow,
    failure: anyerror,
    closed,
};

pub const DetailedReceiptRead = struct {
    read: turn_tracker.ReceiptRead,
    failure: ?errors.Failure = null,
};

const Entry = struct {
    sequence: u64,
    event: session.SessionEvent,
};

const Subscriber = struct {
    active: bool = false,
    generation: u64 = 0,
    next_sequence: u64 = 0,
    overflowed: bool = false,
    ready: std.Io.Event = .unset,
};

const TurnFailureDetail = struct {
    id: u64,
    remaining: usize,
    failure: errors.Failure,
};

pub const EventLog = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    session_id: []u8,
    generation: u64,
    mutex: std.Io.Mutex = .init,
    tracker: turn_tracker.TurnTracker,
    entries: []?Entry,
    subscribers: []Subscriber,
    base_sequence: u64 = 0,
    next_sequence: u64 = 0,
    terminal_error: ?anyerror = null,
    terminal_detail: ?errors.Failure = null,
    turn_failure_details: std.ArrayList(TurnFailureDetail) = .empty,
    next_turn_failure_id: u64 = 1,
    pending_terminal_turn_failure_id: ?u64 = null,
    accepting_ingress: bool = true,
    ingress_count: usize = 0,
    operation_references: usize = 0,
    ingress_drained: std.Io.Event = .is_set,
    is_closed: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        session_id: []const u8,
        generation: u64,
        capacity: usize,
        subscriber_limit: usize,
    ) !EventLog {
        if (capacity == 0 or subscriber_limit == 0) return error.InvalidEventLogCapacity;
        const owned_session_id = try allocator.dupe(u8, session_id);
        errdefer allocator.free(owned_session_id);
        const entries = try allocator.alloc(?Entry, capacity);
        errdefer allocator.free(entries);
        @memset(entries, null);
        const subscribers = try allocator.alloc(Subscriber, subscriber_limit);
        errdefer allocator.free(subscribers);
        var tracker = try turn_tracker.TurnTracker.init(allocator, io, 32, 64);
        errdefer tracker.deinit();
        @memset(subscribers, .{});
        subscribers[0] = .{
            .active = true,
            .generation = 1,
        };
        return .{
            .allocator = allocator,
            .io = io,
            .session_id = owned_session_id,
            .generation = generation,
            .tracker = tracker,
            .entries = entries,
            .subscribers = subscribers,
        };
    }

    pub fn deinit(self: *EventLog) void {
        for (self.entries) |*entry| {
            if (entry.*) |*value| value.event.deinit(self.allocator);
        }
        self.tracker.deinit();
        if (self.terminal_detail) |*failure| failure.deinit();
        for (self.turn_failure_details.items) |*detail| detail.failure.deinit();
        self.turn_failure_details.deinit(self.allocator);
        self.allocator.free(self.session_id);
        self.allocator.free(self.entries);
        self.allocator.free(self.subscribers);
        self.* = undefined;
    }

    pub fn compatibilityToken(self: *EventLog) SubscriberToken {
        return .{ .slot = 0, .generation = self.subscribers[0].generation };
    }

    pub fn beginIngress(self: *EventLog) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.accepting_ingress) return error.SessionDisconnected;
        self.ingress_count += 1;
        self.ingress_drained.reset();
    }

    pub fn finishIngress(self: *EventLog) void {
        self.mutex.lockUncancelable(self.io);
        std.debug.assert(self.ingress_count > 0);
        self.ingress_count -= 1;
        var terminal_error: ?anyerror = null;
        if (self.ingress_count == 0) {
            if (self.pending_terminal_turn_failure_id) |failure_detail_id| {
                self.publishTurnFailureLocked(failure_detail_id, true);
                self.pending_terminal_turn_failure_id = null;
            } else {
                terminal_error = self.terminal_error;
            }
            self.ingress_drained.set(self.io);
            for (self.subscribers) |*subscriber| {
                if (subscriber.active) subscriber.ready.set(self.io);
            }
        }
        self.mutex.unlock(self.io);
        if (terminal_error) |err| self.tracker.failAll(err);
    }

    pub fn retainOperation(self: *EventLog) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.operation_references += 1;
    }

    pub fn retainOperationIfAccepting(self: *EventLog) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.accepting_ingress) return false;
        self.operation_references += 1;
        return true;
    }

    pub fn releaseOperation(self: *EventLog) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.operation_references > 0);
        self.operation_references -= 1;
    }

    pub fn beginClose(self: *EventLog) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.accepting_ingress = false;
        if (self.ingress_count == 0) self.ingress_drained.set(self.io);
    }

    pub fn waitIngressDrained(self: *EventLog) !void {
        try self.ingress_drained.wait(self.io);
    }

    pub fn reserveTurn(
        self: *EventLog,
        kind: turn_tracker.ReceiptKind,
    ) !turn_tracker.ReceiptToken {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.tracker.reserve(kind);
    }

    pub fn bindTurnMessage(
        self: *EventLog,
        token: turn_tracker.ReceiptToken,
        message_id: []const u8,
    ) !void {
        return self.tracker.bindMessageId(token, message_id);
    }

    pub fn failTurn(
        self: *EventLog,
        token: turn_tracker.ReceiptToken,
        err: anyerror,
    ) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.tracker.failReceipt(token, err)) |failure_detail_id|
            self.discardTurnFailureLocked(failure_detail_id);
    }

    pub fn detachTurnWaiter(
        self: *EventLog,
        token: turn_tracker.ReceiptToken,
    ) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.tracker.detachWaiter(token)) |failure_detail_id|
            self.discardTurnFailureLocked(failure_detail_id);
    }

    pub fn abandonTurn(self: *EventLog, token: turn_tracker.ReceiptToken) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.tracker.abandon(token)) |failure_detail_id|
            self.discardTurnFailureLocked(failure_detail_id);
    }

    pub fn inspectTurn(
        self: *EventLog,
        token: turn_tracker.ReceiptToken,
    ) !turn_tracker.ReceiptRead {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const inspection = try self.tracker.inspectDetailed(token);
        if (inspection.failure_detail_id) |failure_detail_id|
            self.discardTurnFailureLocked(failure_detail_id);
        return inspection.read;
    }

    pub fn inspectTurnDetailed(
        self: *EventLog,
        token: turn_tracker.ReceiptToken,
    ) !DetailedReceiptRead {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const inspection = try self.tracker.inspectDetailed(token);
        const failure = if (inspection.failure_detail_id) |failure_detail_id|
            self.takeTurnFailureLocked(failure_detail_id) catch |err| {
                self.discardTurnFailureLocked(failure_detail_id);
                return err;
            }
        else
            null;
        return .{
            .read = inspection.read,
            .failure = failure,
        };
    }

    pub fn observeTurnEvent(
        self: *EventLog,
        event: session.SessionEvent,
    ) !void {
        return self.tracker.observe(event);
    }

    pub fn subscribe(self: *EventLog) !SubscriberToken {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        for (self.subscribers[1..], 1..) |*subscriber, index| {
            if (subscriber.active) continue;
            subscriber.generation +%= 1;
            if (subscriber.generation == 0) subscriber.generation = 1;
            subscriber.* = .{
                .active = true,
                .generation = subscriber.generation,
                .next_sequence = self.next_sequence,
            };
            return .{
                .slot = @intCast(index),
                .generation = subscriber.generation,
            };
        }
        return error.TooManyEventSubscribers;
    }

    pub fn unsubscribe(self: *EventLog, token: SubscriberToken) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const subscriber = self.getSubscriber(token) orelse return;
        if (token.slot == 0) return;
        subscriber.active = false;
        subscriber.ready.set(self.io);
        self.reclaimConsumed();
    }

    pub fn append(self: *EventLog, event: session.SessionEvent) !void {
        return self.appendImpl(event, false);
    }

    pub fn appendCompatibilityConsumed(
        self: *EventLog,
        event: session.SessionEvent,
    ) !void {
        return self.appendImpl(event, true);
    }

    fn appendImpl(
        self: *EventLog,
        event: session.SessionEvent,
        compatibility_consumed: bool,
    ) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.is_closed) return error.SessionDisconnected;
        self.reclaimConsumed();
        if (self.next_sequence - self.base_sequence == self.entries.len) {
            self.evictOldest();
        }
        const index = self.indexFor(self.next_sequence);
        std.debug.assert(self.entries[index] == null);
        self.entries[index] = .{
            .sequence = self.next_sequence,
            .event = event,
        };
        const appended_sequence = self.next_sequence;
        self.next_sequence += 1;
        if (compatibility_consumed) {
            self.subscribers[0].next_sequence = self.next_sequence;
        }
        for (self.subscribers) |*subscriber| {
            if (subscriber.active and subscriber.next_sequence <= appended_sequence) {
                subscriber.ready.set(self.io);
            }
        }
        self.reclaimConsumed();
    }

    pub fn inspect(self: *EventLog, token: SubscriberToken) !ReadAction {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const subscriber = self.getSubscriber(token) orelse
            return error.InvalidEventSubscriber;
        if (subscriber.overflowed) {
            subscriber.overflowed = false;
            return .overflow;
        }
        if (subscriber.next_sequence < self.base_sequence) {
            subscriber.next_sequence = self.base_sequence;
            return .overflow;
        }
        if (subscriber.next_sequence >= self.next_sequence) {
            if (self.ingress_count != 0) {
                subscriber.ready.reset();
                return .{ .wait = &subscriber.ready };
            }
            if (self.terminal_error) |err| return .{ .failure = err };
            if (self.is_closed) return .closed;
            subscriber.ready.reset();
            return .{ .wait = &subscriber.ready };
        }

        const sequence = subscriber.next_sequence;
        const entry = &(self.entries[self.indexFor(sequence)] orelse unreachable);
        std.debug.assert(entry.sequence == sequence);
        var cloned = try session.cloneEvent(self.allocator, entry.event);
        errdefer cloned.deinit(self.allocator);
        subscriber.next_sequence += 1;
        self.reclaimConsumed();
        self.signalIfReady(subscriber);
        return .{ .event = cloned };
    }

    pub fn fail(self: *EventLog, err: anyerror) void {
        self.mutex.lockUncancelable(self.io);
        if (self.terminal_error == null) self.terminal_error = err;
        const fail_tracker = self.ingress_count == 0;
        if (fail_tracker) for (self.subscribers) |*subscriber| {
            if (subscriber.active) subscriber.ready.set(self.io);
        };
        self.mutex.unlock(self.io);
        if (fail_tracker) self.tracker.failAll(err);
    }

    pub fn failAdmitted(self: *EventLog, err: anyerror) void {
        self.mutex.lockUncancelable(self.io);
        self.terminal_error = err;
        if (self.terminal_detail) |*failure| failure.deinit();
        self.terminal_detail = null;
        for (self.turn_failure_details.items) |*detail| detail.failure.deinit();
        self.turn_failure_details.clearRetainingCapacity();
        self.pending_terminal_turn_failure_id = null;
        const fail_tracker = self.ingress_count == 0;
        if (fail_tracker) for (self.subscribers) |*subscriber| {
            if (subscriber.active) subscriber.ready.set(self.io);
        };
        self.mutex.unlock(self.io);
        if (fail_tracker) self.tracker.failAll(err);
    }

    pub fn failDetailed(self: *EventLog, failure_value: errors.Failure) void {
        var failure = failure_value;
        const native_error = failure.native_error;
        self.mutex.lockUncancelable(self.io);
        if (self.terminal_error == null) self.terminal_error = native_error;
        if (self.terminal_detail == null) {
            self.terminal_detail = failure;
        } else {
            failure.deinit();
        }
        const fail_tracker = self.ingress_count == 0;
        if (fail_tracker) for (self.subscribers) |*subscriber| {
            if (subscriber.active) subscriber.ready.set(self.io);
        };
        self.mutex.unlock(self.io);
        if (fail_tracker) self.tracker.failAll(native_error);
    }

    pub fn failTurnsDetailed(self: *EventLog, failure_value: errors.Failure) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.storeTurnFailureLocked(failure_value, false);
    }

    fn storeTurnFailureLocked(
        self: *EventLog,
        failure_value: errors.Failure,
        terminal: bool,
    ) !void {
        var failure = failure_value;
        errdefer failure.deinit();
        const failure_detail_id = self.next_turn_failure_id;
        self.next_turn_failure_id +%= 1;
        if (self.next_turn_failure_id == 0) self.next_turn_failure_id = 1;
        try self.turn_failure_details.append(self.allocator, .{
            .id = failure_detail_id,
            .remaining = 0,
            .failure = failure,
        });
        if (terminal and self.ingress_count != 0) {
            std.debug.assert(self.pending_terminal_turn_failure_id == null);
            self.pending_terminal_turn_failure_id = failure_detail_id;
        } else {
            self.publishTurnFailureLocked(failure_detail_id, terminal);
        }
    }

    fn publishTurnFailureLocked(
        self: *EventLog,
        failure_detail_id: u64,
        terminal: bool,
    ) void {
        for (self.turn_failure_details.items, 0..) |*detail, index| {
            if (detail.id != failure_detail_id) continue;
            detail.remaining = if (terminal)
                self.tracker.failTerminalDetailed(
                    detail.failure.native_error,
                    failure_detail_id,
                )
            else
                self.tracker.failActiveDetailed(
                    detail.failure.native_error,
                    failure_detail_id,
                );
            if (detail.remaining == 0) {
                var removed = self.turn_failure_details.orderedRemove(index);
                removed.failure.deinit();
            }
            return;
        }
        unreachable;
    }

    pub fn failPumpDetailed(
        self: *EventLog,
        terminal_failure_value: errors.Failure,
        turn_failure_value: errors.Failure,
    ) !void {
        var terminal_failure = terminal_failure_value;
        errdefer terminal_failure.deinit();
        const turn_failure = turn_failure_value;
        const native_error = terminal_failure.native_error;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        try self.storeTurnFailureLocked(turn_failure, true);

        if (self.terminal_error == null) self.terminal_error = native_error;
        if (self.terminal_detail == null) {
            self.terminal_detail = terminal_failure;
            terminal_failure = undefined;
        } else {
            terminal_failure.deinit();
            terminal_failure = undefined;
        }
        for (self.subscribers) |*subscriber| {
            if (subscriber.active) subscriber.ready.set(self.io);
        }
    }

    pub fn detailedFailure(self: *EventLog) !?errors.Failure {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.cloneTerminalFailureLocked();
    }

    fn cloneTerminalFailureLocked(self: *EventLog) !?errors.Failure {
        const failure = if (self.terminal_detail) |*value| value else return null;
        return try failure.clone(self.allocator);
    }

    fn takeTurnFailureLocked(
        self: *EventLog,
        failure_detail_id: u64,
    ) !?errors.Failure {
        for (self.turn_failure_details.items, 0..) |*detail, index| {
            if (detail.id != failure_detail_id) continue;
            const cloned = try detail.failure.clone(self.allocator);
            detail.remaining -= 1;
            if (detail.remaining == 0) {
                var removed = self.turn_failure_details.orderedRemove(index);
                removed.failure.deinit();
            }
            return cloned;
        }
        return null;
    }

    fn discardTurnFailureLocked(
        self: *EventLog,
        failure_detail_id: u64,
    ) void {
        for (self.turn_failure_details.items, 0..) |*detail, index| {
            if (detail.id != failure_detail_id) continue;
            detail.remaining -= 1;
            if (detail.remaining == 0) {
                var removed = self.turn_failure_details.orderedRemove(index);
                removed.failure.deinit();
            }
            return;
        }
    }

    pub fn close(self: *EventLog) void {
        self.mutex.lockUncancelable(self.io);
        self.operation_references += 1;
        self.is_closed = true;
        self.accepting_ingress = false;
        for (self.subscribers) |*subscriber| {
            if (subscriber.active) subscriber.ready.set(self.io);
        }
        self.mutex.unlock(self.io);
        self.tracker.failAll(error.SessionDisconnected);
        self.releaseOperation();
    }

    pub fn drainAndClose(self: *EventLog) void {
        self.beginClose();
        self.ingress_drained.waitUncancelable(self.io);
        self.close();
    }

    pub fn isDiscardableClosed(self: *EventLog) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.is_closed or
            self.ingress_count != 0 or
            self.operation_references != 0)
        {
            return false;
        }
        for (self.subscribers[1..]) |subscriber| {
            if (subscriber.active) return false;
        }
        return true;
    }

    fn getSubscriber(self: *EventLog, token: SubscriberToken) ?*Subscriber {
        if (token.slot >= self.subscribers.len) return null;
        const subscriber = &self.subscribers[token.slot];
        if (!subscriber.active or subscriber.generation != token.generation) return null;
        return subscriber;
    }

    fn indexFor(self: *const EventLog, sequence: u64) usize {
        return @intCast(sequence % self.entries.len);
    }

    fn evictOldest(self: *EventLog) void {
        const sequence = self.base_sequence;
        for (self.subscribers) |*subscriber| {
            if (subscriber.active and subscriber.next_sequence <= sequence) {
                subscriber.next_sequence = sequence + 1;
                subscriber.overflowed = true;
                subscriber.ready.set(self.io);
            }
        }
        const index = self.indexFor(sequence);
        var entry = self.entries[index].?;
        entry.event.deinit(self.allocator);
        self.entries[index] = null;
        self.base_sequence += 1;
    }

    fn reclaimConsumed(self: *EventLog) void {
        while (self.base_sequence < self.next_sequence) {
            for (self.subscribers) |subscriber| {
                if (subscriber.active and subscriber.next_sequence <= self.base_sequence) return;
            }
            const index = self.indexFor(self.base_sequence);
            var entry = self.entries[index].?;
            entry.event.deinit(self.allocator);
            self.entries[index] = null;
            self.base_sequence += 1;
        }
    }

    fn signalIfReady(self: *EventLog, subscriber: *Subscriber) void {
        if (subscriber.next_sequence < self.next_sequence or
            self.terminal_error != null or self.is_closed)
        {
            subscriber.ready.set(self.io);
        } else {
            subscriber.ready.reset();
        }
    }
};

fn parsedEvent(allocator: std.mem.Allocator, content: []const u8) !session.SessionEvent {
    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"assistant.message\",\"data\":{{\"content\":\"{s}\",\"messageId\":\"{s}\"}}}}",
        .{ content, content },
    );
    defer allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    return session.parseEvent(allocator, parsed.value);
}

fn parsedEventJson(
    allocator: std.mem.Allocator,
    json: []const u8,
) !session.SessionEvent {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    return session.parseEvent(allocator, parsed.value);
}

fn readProcessed(log: *EventLog, token: SubscriberToken) !session.SessionEvent {
    switch (try log.inspect(token)) {
        .event => |event| return event,
        .overflow => return error.EventLogOverflow,
        .failure => |err| return err,
        .closed => return error.SessionDisconnected,
        .wait => return error.TestUnexpectedWait,
    }
}

test "retained events reach independent subscribers in order" {
    var log = try EventLog.init(std.testing.allocator, std.testing.io, "s1", 1, 4, 3);
    defer log.deinit();
    const first = try log.subscribe();
    const second = try log.subscribe();
    defer log.unsubscribe(first);
    defer log.unsubscribe(second);

    try log.append(try parsedEvent(std.testing.allocator, "one"));
    try log.append(try parsedEvent(std.testing.allocator, "two"));

    var first_one = try readProcessed(&log, first);
    defer first_one.deinit(std.testing.allocator);
    var first_two = try readProcessed(&log, first);
    defer first_two.deinit(std.testing.allocator);
    var second_one = try readProcessed(&log, second);
    defer second_one.deinit(std.testing.allocator);
    var second_two = try readProcessed(&log, second);
    defer second_two.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("one", first_one.assistant_message.content);
    try std.testing.expectEqualStrings("two", first_two.assistant_message.content);
    try std.testing.expectEqualStrings("one", second_one.assistant_message.content);
    try std.testing.expectEqualStrings("two", second_two.assistant_message.content);
    try std.testing.expect(
        first_one.assistant_message.content.ptr !=
            second_one.assistant_message.content.ptr,
    );
}

test "overflow is reported once before retained delivery resumes" {
    var log = try EventLog.init(std.testing.allocator, std.testing.io, "s1", 1, 2, 2);
    defer log.deinit();
    const observer = try log.subscribe();
    defer log.unsubscribe(observer);

    try log.append(try parsedEvent(std.testing.allocator, "one"));
    try log.append(try parsedEvent(std.testing.allocator, "two"));
    try log.append(try parsedEvent(std.testing.allocator, "three"));

    try std.testing.expect((try log.inspect(observer)) == .overflow);
    var two = try readProcessed(&log, observer);
    defer two.deinit(std.testing.allocator);
    var three = try readProcessed(&log, observer);
    defer three.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("two", two.assistant_message.content);
    try std.testing.expectEqualStrings("three", three.assistant_message.content);
    try std.testing.expect((try log.inspect(observer)) == .wait);
}

test "subscriber slots are bounded and generation checked" {
    var log = try EventLog.init(std.testing.allocator, std.testing.io, "s1", 1, 2, 2);
    defer log.deinit();
    const first = try log.subscribe();
    try std.testing.expectError(error.TooManyEventSubscribers, log.subscribe());
    log.unsubscribe(first);
    const second = try log.subscribe();
    defer log.unsubscribe(second);
    try std.testing.expect(first.generation != second.generation);
    try std.testing.expectError(error.InvalidEventSubscriber, log.inspect(first));
}

test "close drains retained events and overflow before disconnect" {
    var log = try EventLog.init(std.testing.allocator, std.testing.io, "s1", 1, 2, 2);
    defer log.deinit();
    const observer = try log.subscribe();
    defer log.unsubscribe(observer);

    try log.append(try parsedEvent(std.testing.allocator, "one"));
    try log.append(try parsedEvent(std.testing.allocator, "two"));
    try log.append(try parsedEvent(std.testing.allocator, "three"));
    log.close();

    try std.testing.expect((try log.inspect(observer)) == .overflow);
    var two = try readProcessed(&log, observer);
    defer two.deinit(std.testing.allocator);
    var three = try readProcessed(&log, observer);
    defer three.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("two", two.assistant_message.content);
    try std.testing.expectEqualStrings("three", three.assistant_message.content);
    try std.testing.expect((try log.inspect(observer)) == .closed);
}

test "close waits for admitted work before exposing disconnect" {
    var log = try EventLog.init(std.testing.allocator, std.testing.io, "s1", 1, 2, 2);
    defer log.deinit();
    const observer = try log.subscribe();
    defer log.unsubscribe(observer);
    try log.beginIngress();
    log.beginClose();

    var event = try parsedEvent(std.testing.allocator, "queued");
    try log.append(event);
    event = undefined;
    log.finishIngress();
    try log.waitIngressDrained();
    log.close();

    var retained = try readProcessed(&log, observer);
    defer retained.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("queued", retained.assistant_message.content);
    try std.testing.expect((try log.inspect(observer)) == .closed);
}

test "closed log ignores unread compatibility events when deciding reclamation" {
    var log = try EventLog.init(std.testing.allocator, std.testing.io, "s1", 1, 2, 2);
    defer log.deinit();

    try log.append(try parsedEvent(std.testing.allocator, "unread"));
    log.close();

    try std.testing.expect(log.isDiscardableClosed());
}

test "session agent diagnostics can be cloned for multiple detailed waiters" {
    const allocator = std.testing.allocator;
    var log = try EventLog.init(allocator, std.testing.io, "s1", 1, 2, 2);
    defer log.deinit();
    log.failDetailed(.{
        .allocator = allocator,
        .native_error = error.CopilotSessionError,
        .detail = .{ .session = .{ .agent = .{
            .session_id = try allocator.dupe(u8, "s1"),
            .error_type = try allocator.dupe(u8, "provider"),
            .error_code = try allocator.dupe(u8, "rate_limit"),
            .message = try allocator.dupe(u8, "retry later"),
            .status_code = 429,
            .provider_call_id = try allocator.dupe(u8, "call-1"),
            .service_request_id = try allocator.dupe(u8, "request-1"),
            .remediation_json = try allocator.dupe(u8, "{\"retry\":true}"),
            .url = try allocator.dupe(u8, "https://example.invalid"),
            .stack = try allocator.dupe(u8, "stack"),
            .eligible_for_auto_switch = true,
        } } },
    });

    var first = (try log.detailedFailure()).?;
    defer first.deinit();
    var second = (try log.detailedFailure()).?;
    defer second.deinit();

    const first_agent = first.detail.session.agent;
    const second_agent = second.detail.session.agent;
    try std.testing.expectEqualStrings("rate_limit", first_agent.error_code.?);
    try std.testing.expectEqualStrings("rate_limit", second_agent.error_code.?);
    try std.testing.expect(first_agent.message.ptr != second_agent.message.ptr);
    try std.testing.expectEqualStrings(
        "{\"retry\":true}",
        second_agent.remediation_json.?,
    );
}

fn testSessionFailure(
    allocator: std.mem.Allocator,
    message: []const u8,
) !errors.Failure {
    const session_id = try allocator.dupe(u8, "s1");
    errdefer allocator.free(session_id);
    const error_type = try allocator.dupe(u8, "provider");
    errdefer allocator.free(error_type);
    const owned_message = try allocator.dupe(u8, message);
    errdefer allocator.free(owned_message);
    return .{
        .allocator = allocator,
        .native_error = error.CopilotSessionError,
        .detail = .{ .session = .{ .agent = .{
            .session_id = session_id,
            .error_type = error_type,
            .error_code = null,
            .message = owned_message,
            .status_code = null,
            .provider_call_id = null,
            .service_request_id = null,
            .remediation_json = null,
            .url = null,
            .stack = null,
            .eligible_for_auto_switch = null,
        } } },
    };
}

test "turn diagnostics remain correlated with their failed receipts" {
    const allocator = std.testing.allocator;
    var log = try EventLog.init(allocator, std.testing.io, "s1", 1, 2, 2);
    defer log.deinit();

    const first = try log.reserveTurn(.waited);
    try log.failTurnsDetailed(try testSessionFailure(allocator, "first"));
    const second = try log.reserveTurn(.waited);
    try log.failTurnsDetailed(try testSessionFailure(allocator, "second"));

    var first_read = try log.inspectTurnDetailed(first);
    defer if (first_read.failure) |*failure| failure.deinit();
    var second_read = try log.inspectTurnDetailed(second);
    defer if (second_read.failure) |*failure| failure.deinit();

    try std.testing.expect(first_read.read == .failure);
    try std.testing.expect(second_read.read == .failure);
    try std.testing.expectEqualStrings(
        "first",
        first_read.failure.?.detail.session.agent.message,
    );
    try std.testing.expectEqualStrings(
        "second",
        second_read.failure.?.detail.session.agent.message,
    );
}

test "discarded waiters release retained turn diagnostics" {
    const allocator = std.testing.allocator;
    var log = try EventLog.init(allocator, std.testing.io, "s1", 1, 2, 2);
    defer log.deinit();

    const detached = try log.reserveTurn(.waited);
    try log.failTurnsDetailed(try testSessionFailure(allocator, "detached"));
    try std.testing.expectEqual(@as(usize, 1), log.turn_failure_details.items.len);
    log.detachTurnWaiter(detached);
    try std.testing.expectEqual(@as(usize, 0), log.turn_failure_details.items.len);

    const legacy = try log.reserveTurn(.waited);
    try log.failTurnsDetailed(try testSessionFailure(allocator, "legacy"));
    const legacy_read = try log.inspectTurn(legacy);
    try std.testing.expect(legacy_read == .failure);
    try std.testing.expectEqual(@as(usize, 0), log.turn_failure_details.items.len);
}

test "failed diagnostic clones release the consumed receipt share" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var log = try EventLog.init(failing.allocator(), std.testing.io, "s1", 1, 2, 2);
    defer log.deinit();

    const receipt = try log.reserveTurn(.waited);
    try log.failTurnsDetailed(try testSessionFailure(failing.allocator(), "failure"));
    try std.testing.expectEqual(@as(usize, 1), log.turn_failure_details.items.len);

    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, log.inspectTurnDetailed(receipt));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), log.turn_failure_details.items.len);
}

test "pump diagnostic publication rolls back on allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var log = try EventLog.init(failing.allocator(), std.testing.io, "s1", 1, 2, 2);
    defer log.deinit();

    const receipt = try log.reserveTurn(.waited);
    const terminal_failure = try testSessionFailure(failing.allocator(), "terminal");
    const turn_failure = try testSessionFailure(failing.allocator(), "turn");
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(
        error.OutOfMemory,
        log.failPumpDetailed(terminal_failure, turn_failure),
    );
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(log.terminal_detail == null);
    try std.testing.expectEqual(@as(usize, 0), log.turn_failure_details.items.len);
    try std.testing.expect((try log.inspectTurn(receipt)) == .pending);
}

test "pump failure waits for admitted turn completion" {
    const allocator = std.testing.allocator;
    var log = try EventLog.init(allocator, std.testing.io, "s1", 1, 2, 2);
    defer log.deinit();

    const receipt = try log.reserveTurn(.waited);
    try log.bindTurnMessage(receipt, "message-1");
    try log.beginIngress();
    try log.failPumpDetailed(
        try testSessionFailure(allocator, "terminal"),
        try testSessionFailure(allocator, "turn"),
    );
    try std.testing.expect((try log.inspectTurn(receipt)) == .pending);

    var user = try parsedEventJson(
        allocator,
        "{\"type\":\"user.message\",\"data\":{\"content\":\"prompt\",\"messageId\":\"message-1\",\"turnId\":\"turn-1\"}}",
    );
    defer user.deinit(allocator);
    try log.observeTurnEvent(user);

    var assistant = try parsedEventJson(
        allocator,
        "{\"type\":\"assistant.message\",\"data\":{\"content\":\"answer\",\"messageId\":\"assistant-1\",\"turnId\":\"turn-1\"}}",
    );
    defer assistant.deinit(allocator);
    try log.observeTurnEvent(assistant);

    var turn_end = try parsedEventJson(
        allocator,
        "{\"type\":\"assistant.turn_end\",\"data\":{\"turnId\":\"turn-1\"}}",
    );
    defer turn_end.deinit(allocator);
    try log.observeTurnEvent(turn_end);
    log.finishIngress();

    var result = try log.inspectTurnDetailed(receipt);
    defer if (result.failure) |*failure| failure.deinit();
    try std.testing.expect(result.failure == null);
    switch (result.read) {
        .completed => |maybe_message| {
            var message = maybe_message.?;
            defer message.deinit(allocator);
            try std.testing.expectEqualStrings("answer", message.content);
        },
        else => return error.TestExpectedCompletedTurn,
    }
}

test "admitted failure clears deferred pump diagnostic" {
    const allocator = std.testing.allocator;
    var log = try EventLog.init(allocator, std.testing.io, "s1", 1, 2, 2);
    defer log.deinit();

    const receipt = try log.reserveTurn(.waited);
    try log.beginIngress();
    try log.failPumpDetailed(
        try testSessionFailure(allocator, "terminal"),
        try testSessionFailure(allocator, "turn"),
    );
    log.failAdmitted(error.TestAdmittedFailure);
    log.finishIngress();

    var result = try log.inspectTurnDetailed(receipt);
    defer if (result.failure) |*failure| failure.deinit();
    try std.testing.expect(result.failure == null);
    switch (result.read) {
        .failure => |err| try std.testing.expectEqual(error.TestAdmittedFailure, err),
        else => return error.TestExpectedAdmittedFailure,
    }
}

test "turn diagnostics clone for every detailed waiter" {
    const allocator = std.testing.allocator;
    var log = try EventLog.init(allocator, std.testing.io, "s1", 1, 2, 2);
    defer log.deinit();

    const first = try log.reserveTurn(.waited);
    const second = try log.reserveTurn(.waited);
    try log.failTurnsDetailed(.{
        .allocator = allocator,
        .native_error = error.MissingContentLength,
        .detail = .{ .protocol = .missing_content_length },
    });

    var first_read = try log.inspectTurnDetailed(first);
    defer if (first_read.failure) |*failure| failure.deinit();
    var second_read = try log.inspectTurnDetailed(second);
    defer if (second_read.failure) |*failure| failure.deinit();
    try std.testing.expect(first_read.failure != null);
    try std.testing.expect(second_read.failure != null);
    try std.testing.expect(first_read.read == .failure);
    try std.testing.expect(second_read.read == .failure);
    try std.testing.expectEqual(
        error.MissingContentLength,
        first_read.failure.?.native_error,
    );
    try std.testing.expectEqual(
        error.MissingContentLength,
        second_read.failure.?.native_error,
    );
}
