const std = @import("std");
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

pub const EventLog = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    session_id: []u8,
    generation: u64,
    mutex: std.Io.Mutex = .init,
    processing_mutex: std.Io.Mutex = .init,
    tracker: turn_tracker.TurnTracker,
    entries: []?Entry,
    subscribers: []Subscriber,
    base_sequence: u64 = 0,
    next_sequence: u64 = 0,
    terminal_error: ?anyerror = null,
    accepting_ingress: bool = true,
    ingress_count: usize = 0,
    operation_references: usize = 0,
    active_callbacks: usize = 0,
    ingress_drained: std.Io.Event = .is_set,
    callbacks_drained: std.Io.Event = .is_set,
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
        const terminal_error = if (self.ingress_count == 0) self.terminal_error else null;
        if (self.ingress_count == 0) {
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

    pub fn releaseOperation(self: *EventLog) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.operation_references > 0);
        self.operation_references -= 1;
    }

    pub fn retainCallback(self: *EventLog, admitted: bool) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (!admitted and (!self.accepting_ingress or self.is_closed))
            return error.SessionDisconnected;
        self.active_callbacks += 1;
        self.callbacks_drained.reset();
    }

    pub fn releaseCallback(self: *EventLog) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.active_callbacks > 0);
        self.active_callbacks -= 1;
        if (self.active_callbacks == 0) self.callbacks_drained.set(self.io);
    }

    pub fn waitCallbacksDrainedUncancelable(self: *EventLog) void {
        self.callbacks_drained.waitUncancelable(self.io);
    }

    pub fn hasActiveCallbacks(self: *EventLog) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.active_callbacks != 0;
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

    pub fn waitIngressDrainedUncancelable(self: *EventLog) void {
        self.ingress_drained.waitUncancelable(self.io);
    }

    pub fn reserveTurn(
        self: *EventLog,
        kind: turn_tracker.ReceiptKind,
    ) !turn_tracker.ReceiptToken {
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
        self.tracker.failReceipt(token, err);
    }

    pub fn detachTurnWaiter(
        self: *EventLog,
        token: turn_tracker.ReceiptToken,
    ) void {
        self.tracker.detachWaiter(token);
    }

    pub fn abandonTurn(self: *EventLog, token: turn_tracker.ReceiptToken) void {
        self.tracker.abandon(token);
    }

    pub fn inspectTurn(
        self: *EventLog,
        token: turn_tracker.ReceiptToken,
    ) !turn_tracker.ReceiptRead {
        return self.tracker.inspect(token);
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
        for (self.subscribers) |*subscriber| {
            if (subscriber.active and subscriber.next_sequence <= appended_sequence) {
                subscriber.ready.set(self.io);
            }
        }
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

    pub fn close(self: *EventLog) void {
        self.mutex.lockUncancelable(self.io);
        self.is_closed = true;
        self.accepting_ingress = false;
        for (self.subscribers) |*subscriber| {
            if (subscriber.active) subscriber.ready.set(self.io);
        }
        self.mutex.unlock(self.io);
        self.tracker.failAll(error.SessionDisconnected);
    }

    pub fn isReclaimable(self: *EventLog) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.is_closed or
            self.base_sequence != self.next_sequence or
            self.ingress_count != 0 or
            self.operation_references != 0 or
            self.active_callbacks != 0)
        {
            return false;
        }
        for (self.subscribers[1..]) |subscriber| {
            if (subscriber.active) return false;
        }
        return true;
    }

    pub fn isDiscardableClosed(self: *EventLog) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.is_closed or
            self.ingress_count != 0 or
            self.operation_references != 0 or
            self.active_callbacks != 0)
        {
            return false;
        }
        for (self.subscribers[1..]) |subscriber| {
            if (subscriber.active) return false;
        }
        return true;
    }

    pub fn isAcceptingIngress(self: *EventLog) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.accepting_ingress and !self.is_closed;
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
