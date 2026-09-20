const std = @import("std");
const session = @import("session.zig");

pub const JsonView = struct {
    bytes: []const u8,

    pub fn init(bytes: []const u8) !JsonView {
        const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, bytes, .{}) catch
            return error.InvalidJson;
        defer parsed.deinit();
        return .{ .bytes = bytes };
    }

    pub fn parse(
        self: JsonView,
        comptime T: type,
        allocator: std.mem.Allocator,
    ) !std.json.Parsed(T) {
        return std.json.parseFromSlice(T, allocator, self.bytes, .{
            .allocate = .alloc_always,
        });
    }

    pub fn clone(self: JsonView, allocator: std.mem.Allocator) !Json {
        return Json.init(allocator, self.bytes);
    }
};

pub const Json = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,

    pub fn init(allocator: std.mem.Allocator, bytes: []const u8) !Json {
        _ = try JsonView.init(bytes);
        return .{ .allocator = allocator, .bytes = try allocator.dupe(u8, bytes) };
    }

    pub fn initValue(allocator: std.mem.Allocator, value: anytype) !Json {
        const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{
            .emit_null_optional_fields = false,
        });
        errdefer allocator.free(bytes);
        _ = try JsonView.init(bytes);
        return .{ .allocator = allocator, .bytes = bytes };
    }

    pub fn view(self: *const Json) JsonView {
        return .{ .bytes = self.bytes };
    }

    pub fn deinit(self: *Json) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub fn deinitOptionalJsonSlice(allocator: std.mem.Allocator, values: []?Json) void {
    for (values) |*value| if (value.*) |*json| json.deinit();
    allocator.free(values);
}

pub fn LimitOverride(comptime T: type) type {
    return union(enum) {
        inherit,
        unlimited,
        value: T,
    };
}

pub const FactoryDeclaredLimits = struct {
    max_concurrent_subagents: ?u32 = null,
    max_total_subagents: ?u64 = null,
    timeout_seconds: ?f64 = null,
    max_ai_credits: ?f64 = null,
};

pub const FactoryLimitOverrides = struct {
    max_concurrent_subagents: LimitOverride(u32) = .inherit,
    max_total_subagents: LimitOverride(u64) = .inherit,
    timeout_seconds: LimitOverride(f64) = .inherit,
    max_ai_credits: LimitOverride(f64) = .inherit,
};

pub const FactoryPhase = struct {
    title: []const u8,
    detail: ?[]const u8 = null,
};

pub const FactoryMeta = struct {
    name: []const u8,
    description: []const u8,
    phases: []const FactoryPhase = &.{},
    args_schema: ?JsonView = null,
    limits: ?FactoryDeclaredLimits = null,
};

pub const AgentFactory = struct {
    meta: FactoryMeta,
    run: *const fn (
        allocator: std.mem.Allocator,
        context: *FactoryContext,
        user_context: ?*anyopaque,
    ) anyerror!?Json,
    context: ?*anyopaque = null,
};

pub const FactoryAgentOptions = struct {
    label: ?[]const u8 = null,
    schema: ?JsonView = null,
    model: ?[]const u8 = null,
    reasoning_effort: ?[]const u8 = null,
    context_tier: ?session.ContextTier = null,
    agent: ?[]const u8 = null,
};

pub const FactoryStepOptions = struct {
    is_volatile: bool = false,
};

pub const FactoryProducer = struct {
    context: ?*anyopaque = null,
    produce: *const fn (std.mem.Allocator, ?*anyopaque) anyerror!Json,
};

pub const FactoryTask = struct {
    context: ?*anyopaque = null,
    run: *const fn (
        allocator: std.mem.Allocator,
        branch: *FactoryBranch,
        context: ?*anyopaque,
    ) anyerror!?Json,
    deinit_context: ?*const fn (std.mem.Allocator, ?*anyopaque) void = null,

    pub fn deinit(self: *FactoryTask, allocator: std.mem.Allocator) void {
        if (self.deinit_context) |deinit_context| deinit_context(allocator, self.context);
        self.* = undefined;
    }
};

pub const FactoryStage = struct {
    context: ?*anyopaque = null,
    run: *const fn (
        allocator: std.mem.Allocator,
        branch: *FactoryBranch,
        previous: JsonView,
        original: JsonView,
        index: usize,
        context: ?*anyopaque,
    ) anyerror!?Json,
};

pub const FactoryCancellation = struct {
    event: *std.Io.Event,
    io: std.Io,

    pub fn isCancelled(self: FactoryCancellation) bool {
        return self.event.isSet();
    }

    pub fn wait(self: FactoryCancellation) !void {
        try self.event.wait(self.io);
    }
};

pub const JournalLookup = union(enum) {
    miss,
    value: Json,
};

pub const FactoryExecution = struct {
    state: *anyopaque,
    io: std.Io,
    agent_fn: *const fn (
        *anyopaque,
        std.mem.Allocator,
        []const u8,
        FactoryAgentOptions,
    ) anyerror!?Json,
    journal_get_fn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!JournalLookup,
    journal_put_fn: *const fn (*anyopaque, []const u8, JsonView) anyerror!void,
    pause_fn: *const fn (*anyopaque, []const u8) anyerror!void,
    progress_fn: *const fn (*anyopaque, FactoryLogKind, []const u8) anyerror!void,
};

pub const FactoryLogKind = enum { log, phase };

pub const FactoryBranch = struct {
    execution: *FactoryExecution,
    cancel: FactoryCancellation,

    pub fn agent(
        self: *FactoryBranch,
        allocator: std.mem.Allocator,
        prompt: []const u8,
        options: FactoryAgentOptions,
    ) !?Json {
        if (self.cancel.isCancelled()) return error.FactoryCancelled;
        return self.execution.agent_fn(self.execution.state, allocator, prompt, options);
    }

    pub fn step(
        self: *FactoryBranch,
        allocator: std.mem.Allocator,
        key: []const u8,
        producer: FactoryProducer,
        options: FactoryStepOptions,
    ) !Json {
        if (key.len == 0) return error.InvalidFactoryStepKey;
        if (self.cancel.isCancelled()) return error.FactoryCancelled;
        if (!options.is_volatile) {
            switch (try self.execution.journal_get_fn(
                self.execution.state,
                allocator,
                key,
            )) {
                .value => |value| return value,
                .miss => {},
            }
        }
        var value = try producer.produce(allocator, producer.context);
        errdefer value.deinit();
        if (!options.is_volatile)
            try self.execution.journal_put_fn(self.execution.state, key, value.view());
        return value;
    }

    pub fn log(self: *FactoryBranch, message: []const u8) !void {
        if (self.cancel.isCancelled()) return error.FactoryCancelled;
        return self.execution.progress_fn(self.execution.state, .log, message);
    }
};

pub const FactoryContext = struct {
    run_id: []const u8,
    args: JsonView,
    cancel: FactoryCancellation,
    execution: FactoryExecution,

    fn branch(self: *FactoryContext) FactoryBranch {
        return .{ .execution = &self.execution, .cancel = self.cancel };
    }

    pub fn agent(
        self: *FactoryContext,
        allocator: std.mem.Allocator,
        prompt: []const u8,
        options: FactoryAgentOptions,
    ) !?Json {
        var value = self.branch();
        return value.agent(allocator, prompt, options);
    }

    pub fn step(
        self: *FactoryContext,
        allocator: std.mem.Allocator,
        key: []const u8,
        producer: FactoryProducer,
        options: FactoryStepOptions,
    ) !Json {
        var value = self.branch();
        return value.step(allocator, key, producer, options);
    }

    pub fn pause(self: *FactoryContext, key: []const u8) !void {
        if (key.len == 0) return error.InvalidFactoryCheckpointKey;
        if (self.cancel.isCancelled()) return error.FactoryCancelled;
        return self.execution.pause_fn(self.execution.state, key);
    }

    pub fn phase(self: *FactoryContext, title: []const u8) !void {
        if (title.len == 0) return error.InvalidFactoryPhase;
        if (self.cancel.isCancelled()) return error.FactoryCancelled;
        return self.execution.progress_fn(self.execution.state, .phase, title);
    }

    pub fn log(self: *FactoryContext, message: []const u8) !void {
        var value = self.branch();
        return value.log(message);
    }

    pub fn parallel(
        self: *FactoryContext,
        allocator: std.mem.Allocator,
        tasks: []const FactoryTask,
    ) ![]?Json {
        if (tasks.len > 4096) return error.FactoryFanoutTooLarge;
        const states = try allocator.alloc(TaskState, tasks.len);
        defer allocator.free(states);
        const futures = try allocator.alloc(std.Io.Future(void), tasks.len);
        defer allocator.free(futures);
        var started: usize = 0;
        errdefer {
            for (futures[0..started]) |*future| future.await(self.execution.io);
            for (states[0..started]) |*state| if (state.result) |*value| value.deinit();
        }
        for (tasks, 0..) |task, index| {
            states[index] = .{
                .allocator = allocator,
                .branch = self.branch(),
                .task = task,
            };
            futures[index] = try self.execution.io.concurrent(runTask, .{&states[index]});
            started += 1;
        }
        for (futures) |*future| future.await(self.execution.io);

        for (states) |state| if (state.failure) |failure| return failure;
        const results = try allocator.alloc(?Json, tasks.len);
        errdefer allocator.free(results);
        for (states, 0..) |*state, index| {
            results[index] = state.result;
            state.result = null;
        }
        return results;
    }

    pub fn pipeline(
        self: *FactoryContext,
        allocator: std.mem.Allocator,
        items: []const JsonView,
        stages: []const FactoryStage,
    ) ![]?Json {
        if (items.len > 4096) return error.FactoryFanoutTooLarge;
        const states = try allocator.alloc(PipelineState, items.len);
        defer allocator.free(states);
        const futures = try allocator.alloc(std.Io.Future(void), items.len);
        defer allocator.free(futures);
        var started: usize = 0;
        errdefer {
            for (futures[0..started]) |*future| future.await(self.execution.io);
            for (states[0..started]) |*state| if (state.result) |*value| value.deinit();
        }
        for (items, 0..) |item, index| {
            states[index] = .{
                .allocator = allocator,
                .branch = self.branch(),
                .item = item,
                .index = index,
                .stages = stages,
            };
            futures[index] = try self.execution.io.concurrent(runPipeline, .{&states[index]});
            started += 1;
        }
        for (futures) |*future| future.await(self.execution.io);

        for (states) |state| if (state.failure) |failure| return failure;
        const results = try allocator.alloc(?Json, items.len);
        errdefer allocator.free(results);
        for (states, 0..) |*state, index| {
            results[index] = state.result;
            state.result = null;
        }
        return results;
    }
};

const TaskState = struct {
    allocator: std.mem.Allocator,
    branch: FactoryBranch,
    task: FactoryTask,
    result: ?Json = null,
    failure: ?anyerror = null,
};

fn runTask(state: *TaskState) void {
    state.result = state.task.run(
        state.allocator,
        &state.branch,
        state.task.context,
    ) catch |err| {
        if (isFatal(err)) state.failure = err;
        return;
    };
}

const PipelineState = struct {
    allocator: std.mem.Allocator,
    branch: FactoryBranch,
    item: JsonView,
    index: usize,
    stages: []const FactoryStage,
    result: ?Json = null,
    failure: ?anyerror = null,
};

fn runPipeline(state: *PipelineState) void {
    var previous = state.item.clone(state.allocator) catch |err| {
        state.failure = err;
        return;
    };
    for (state.stages) |stage| {
        const next = stage.run(
            state.allocator,
            &state.branch,
            previous.view(),
            state.item,
            state.index,
            stage.context,
        ) catch |err| {
            previous.deinit();
            if (isFatal(err)) state.failure = err;
            return;
        };
        previous.deinit();
        previous = next orelse return;
    }
    state.result = previous;
}

fn isFatal(err: anyerror) bool {
    return switch (err) {
        error.OutOfMemory,
        error.FactoryCancelled,
        error.FactoryTransportFailure,
        error.FactoryDurableFailure,
        error.FactoryLimitReached,
        => true,
        else => false,
    };
}

pub const JsonPresence = union(enum) {
    absent,
    value: JsonView,
};

pub const FactoryRunStatus = enum {
    pending,
    running,
    completed,
    halted,
    paused,
    cancelled,
    @"error",
};

pub const FactoryPauseInfo = union(enum) {
    user,
    checkpoint: []const u8,
};

pub const FactoryFailureKind = enum {
    max_total_subagents,
    timeout_seconds,
    max_ai_credits,
};

pub const FactoryDurableOperation = enum {
    create_run,
    mark_run_started,
    finish_run,
    reserve_agent,
    release_agent,
    charge_credit,
    add_elapsed,
    reconcile_credit_total,
    journal_get,
    journal_put,
    refresh_lease,
};

pub const FactoryFailure = union(enum) {
    limit_reached: struct {
        kind: FactoryFailureKind,
        value: f64,
        suggested_value: ?f64,
        run_id: []const u8,
    },
    resume_declined: struct { run_id: []const u8, reason: []const u8 },
    durable_failure: struct {
        code: []const u8,
        operation: FactoryDurableOperation,
        run_id: []const u8,
    },
    accounting_incomplete: struct { run_id: []const u8, drained_nano_aiu: i64 },
    provider_disconnected: struct { run_id: []const u8 },
};

pub const FactoryRunError = struct {
    message: ?[]const u8 = null,
    failure: ?FactoryFailure = null,
};

pub const FactoryHalt = struct {
    reason: ?[]const u8 = null,
    failure: ?FactoryFailure = null,
};

pub const FactoryOutcome = union(enum) {
    pending,
    running,
    completed: JsonPresence,
    halted: FactoryHalt,
    paused: FactoryPauseInfo,
    cancelled: ?[]const u8,
    @"error": FactoryRunError,
};

pub const FactoryRun = struct {
    arena: std.heap.ArenaAllocator,
    run_id: []const u8,
    attempt: ?u32,
    snapshot: ?JsonView,
    outcome: FactoryOutcome,

    pub fn deinit(self: *FactoryRun) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn isTerminal(self: FactoryRun) bool {
        return switch (self.outcome) {
            .pending, .running => false,
            else => true,
        };
    }
};

pub const FactoryRunOptions = struct {
    args: ?JsonView = null,
    limits: ?FactoryLimitOverrides = null,
    notify_on_complete: ?bool = null,
    log_phase_names: ?bool = null,
    resume_from_run_id: ?[]const u8 = null,
};

pub const FactoryResumeOptions = struct {
    limits: ?FactoryLimitOverrides = null,
    notify_on_complete: ?bool = null,
    log_phase_names: ?bool = null,
};

pub const FactoryListRunsOptions = struct {
    after_seq: ?i64 = null,
    before_seq: ?i64 = null,
    limit: ?u16 = null,
};

pub const FactoryProgressOptions = struct {
    phase_id: ?[]const u8 = null,
    after_seq: ?i64 = null,
    before_seq: ?i64 = null,
    limit: ?u16 = null,
};

pub const FactoryWaitOptions = struct {
    poll_interval_ns: u64 = 5 * std.time.ns_per_s,
    timeout_ns: ?u64 = null,
    cancellation: ?*session.Cancellation = null,
};

pub const FactoryRunsPage = struct {
    value: Json,

    pub fn deinit(self: *FactoryRunsPage) void {
        self.value.deinit();
        self.* = undefined;
    }
};

pub const FactoryProgressPage = struct {
    value: Json,

    pub fn deinit(self: *FactoryProgressPage) void {
        self.value.deinit();
        self.* = undefined;
    }
};

pub const FactoryRunDetail = struct {
    value: Json,

    pub fn deinit(self: *FactoryRunDetail) void {
        self.value.deinit();
        self.* = undefined;
    }
};

pub fn FactoryApi(comptime SessionType: type) type {
    return struct {
        session: SessionType,

        const Self = @This();

        pub fn run(
            self: Self,
            allocator: std.mem.Allocator,
            name: []const u8,
            options: FactoryRunOptions,
        ) !FactoryRun {
            return self.session.factoryRun(allocator, name, options);
        }

        pub fn @"resume"(
            self: Self,
            allocator: std.mem.Allocator,
            run_id: []const u8,
            options: FactoryResumeOptions,
        ) !FactoryRun {
            return self.session.factoryResume(allocator, run_id, options);
        }

        pub fn getRun(self: Self, allocator: std.mem.Allocator, run_id: []const u8) !FactoryRun {
            return self.session.factoryGetRun(allocator, run_id);
        }

        pub fn waitForRun(
            self: Self,
            allocator: std.mem.Allocator,
            run_id: []const u8,
            options: FactoryWaitOptions,
        ) !FactoryRun {
            return self.session.factoryWaitForRun(allocator, run_id, options);
        }

        pub fn listRuns(
            self: Self,
            allocator: std.mem.Allocator,
            options: FactoryListRunsOptions,
        ) !FactoryRunsPage {
            return self.session.factoryListRuns(allocator, options);
        }

        pub fn getRunDetail(
            self: Self,
            allocator: std.mem.Allocator,
            run_id: []const u8,
        ) !FactoryRunDetail {
            return self.session.factoryGetRunDetail(allocator, run_id);
        }

        pub fn getRunProgress(
            self: Self,
            allocator: std.mem.Allocator,
            run_id: []const u8,
            options: FactoryProgressOptions,
        ) !FactoryProgressPage {
            return self.session.factoryGetRunProgress(allocator, run_id, options);
        }

        pub fn pause(self: Self, allocator: std.mem.Allocator, run_id: []const u8) !FactoryRun {
            return self.session.factoryPause(allocator, run_id);
        }

        pub fn cancel(self: Self, allocator: std.mem.Allocator, run_id: []const u8) !FactoryRun {
            return self.session.factoryCancel(allocator, run_id);
        }
    };
}

pub fn validateFactories(factories: []const AgentFactory) !void {
    for (factories, 0..) |definition, index| {
        if (std.mem.trim(u8, definition.meta.name, " \t\r\n").len == 0)
            return error.InvalidFactoryName;
        for (factories[0..index]) |previous| {
            if (std.mem.eql(u8, previous.meta.name, definition.meta.name))
                return error.DuplicateFactoryName;
        }
        for (definition.meta.phases, 0..) |phase, phase_index| {
            if (std.mem.trim(u8, phase.title, " \t\r\n").len == 0)
                return error.InvalidFactoryPhase;
            for (definition.meta.phases[0..phase_index]) |previous| {
                if (std.mem.eql(u8, previous.title, phase.title))
                    return error.DuplicateFactoryPhase;
            }
        }
        if (definition.meta.args_schema) |schema| {
            const parsed = std.json.parseFromSlice(
                std.json.Value,
                std.heap.page_allocator,
                schema.bytes,
                .{},
            ) catch return error.InvalidFactoryArgsSchema;
            defer parsed.deinit();
            switch (parsed.value) {
                .object, .bool => {},
                else => return error.InvalidFactoryArgsSchema,
            }
        }
        if (definition.meta.limits) |limits| try validateDeclaredLimits(limits);
    }
}

pub fn validateDeclaredLimits(limits: FactoryDeclaredLimits) !void {
    if (limits.max_concurrent_subagents) |value|
        if (value == 0) return error.InvalidFactoryLimit;
    if (limits.max_total_subagents) |value|
        if (value == 0) return error.InvalidFactoryLimit;
    if (limits.timeout_seconds) |value|
        if (!std.math.isFinite(value) or value <= 0 or value > 2_147_483.647)
            return error.InvalidFactoryLimit;
    if (limits.max_ai_credits) |value| {
        const nano = value * 1_000_000_000;
        if (!std.math.isFinite(value) or value <= 0 or
            nano < 1 or nano > @as(f64, @floatFromInt(std.math.maxInt(i64))))
            return error.InvalidFactoryLimit;
    }
}

pub fn validateLimitOverrides(limits: FactoryLimitOverrides) !void {
    switch (limits.max_concurrent_subagents) {
        .value => |value| if (value == 0) return error.InvalidFactoryLimit,
        else => {},
    }
    switch (limits.max_total_subagents) {
        .value => |value| if (value == 0 or value > std.math.maxInt(i64))
            return error.InvalidFactoryLimit,
        else => {},
    }
    switch (limits.timeout_seconds) {
        .value => |value| if (!std.math.isFinite(value) or
            value <= 0 or value > 2_147_483.647)
            return error.InvalidFactoryLimit,
        else => {},
    }
    switch (limits.max_ai_credits) {
        .value => |value| {
            const nano = value * 1_000_000_000;
            if (!std.math.isFinite(value) or value <= 0 or
                nano < 1 or nano > @as(f64, @floatFromInt(std.math.maxInt(i64))))
                return error.InvalidFactoryLimit;
        },
        else => {},
    }
}

test "owned JSON preserves null and arbitrary top-level values" {
    for ([_][]const u8{ "null", "42", "\"value\"", "[1,false]", "{\"x\":1}" }) |source| {
        var value = try Json.init(std.testing.allocator, source);
        defer value.deinit();
        try std.testing.expectEqualStrings(source, value.bytes);
    }
    try std.testing.expectError(error.InvalidJson, Json.init(std.testing.allocator, "{} trailing"));
}

test "factory registration rejects duplicate names and phase titles" {
    const run = struct {
        fn callback(_: std.mem.Allocator, _: *FactoryContext, _: ?*anyopaque) !?Json {
            return null;
        }
    }.callback;
    try std.testing.expectError(error.DuplicateFactoryName, validateFactories(&.{
        .{ .meta = .{ .name = "same", .description = "one" }, .run = run },
        .{ .meta = .{ .name = "same", .description = "two" }, .run = run },
    }));
    try std.testing.expectError(error.DuplicateFactoryPhase, validateFactories(&.{
        .{
            .meta = .{
                .name = "phases",
                .description = "duplicate",
                .phases = &.{ .{ .title = "Review" }, .{ .title = "Review" } },
            },
            .run = run,
        },
    }));

    try validateFactories(&.{
        .{
            .meta = .{
                .name = "boolean-schema",
                .description = "Accepts every JSON value.",
                .args_schema = try JsonView.init("true"),
            },
            .run = run,
        },
    });
    try std.testing.expectError(error.InvalidFactoryArgsSchema, validateFactories(&.{
        .{
            .meta = .{
                .name = "invalid-schema",
                .description = "Uses a non-schema JSON value.",
                .args_schema = try JsonView.init("42"),
            },
            .run = run,
        },
    }));
}

test "limit override preserves three distinct states" {
    const inherited = FactoryLimitOverrides{};
    try std.testing.expect(inherited.max_ai_credits == .inherit);
    const unlimited = FactoryLimitOverrides{ .max_ai_credits = .unlimited };
    try std.testing.expect(unlimited.max_ai_credits == .unlimited);
    const bounded = FactoryLimitOverrides{ .max_ai_credits = .{ .value = 2.5 } };
    try std.testing.expectEqual(@as(f64, 2.5), bounded.max_ai_credits.value);
    try std.testing.expectError(
        error.InvalidFactoryLimit,
        validateLimitOverrides(.{ .max_concurrent_subagents = .{ .value = 0 } }),
    );
    try std.testing.expectError(
        error.InvalidFactoryLimit,
        validateLimitOverrides(.{
            .max_total_subagents = .{ .value = @as(u64, std.math.maxInt(i64)) + 1 },
        }),
    );
}

test "parallel and pipeline return owned results" {
    const callbacks = struct {
        fn agent(
            _: *anyopaque,
            _: std.mem.Allocator,
            _: []const u8,
            _: FactoryAgentOptions,
        ) !?Json {
            return null;
        }

        fn journalGet(
            _: *anyopaque,
            _: std.mem.Allocator,
            _: []const u8,
        ) !JournalLookup {
            return .miss;
        }

        fn journalPut(_: *anyopaque, _: []const u8, _: JsonView) !void {}
        fn pause(_: *anyopaque, _: []const u8) !void {}
        fn progress(_: *anyopaque, _: FactoryLogKind, _: []const u8) !void {}

        fn task(
            allocator: std.mem.Allocator,
            _: *FactoryBranch,
            _: ?*anyopaque,
        ) !?Json {
            return try Json.init(allocator, "{\"task\":true}");
        }

        fn failTask(
            _: std.mem.Allocator,
            _: *FactoryBranch,
            _: ?*anyopaque,
        ) !?Json {
            return error.FactoryLimitReached;
        }

        fn stage(
            allocator: std.mem.Allocator,
            _: *FactoryBranch,
            _: JsonView,
            _: JsonView,
            index: usize,
            _: ?*anyopaque,
        ) !?Json {
            if (index == 1) return error.FactoryLimitReached;
            return try Json.initValue(allocator, .{ .index = index });
        }
    };

    var cancellation: std.Io.Event = .unset;
    var state: u8 = 0;
    var context = FactoryContext{
        .run_id = "run-1",
        .args = try JsonView.init("{}"),
        .cancel = .{ .event = &cancellation, .io = std.testing.io },
        .execution = .{
            .state = &state,
            .io = std.testing.io,
            .agent_fn = callbacks.agent,
            .journal_get_fn = callbacks.journalGet,
            .journal_put_fn = callbacks.journalPut,
            .pause_fn = callbacks.pause,
            .progress_fn = callbacks.progress,
        },
    };

    const parallel = try context.parallel(std.testing.allocator, &.{
        .{ .run = callbacks.task },
    });
    defer deinitOptionalJsonSlice(std.testing.allocator, parallel);
    try std.testing.expectEqualStrings("{\"task\":true}", parallel[0].?.bytes);

    const pipeline = try context.pipeline(
        std.testing.allocator,
        &.{try JsonView.init("{\"input\":true}")},
        &.{.{ .run = callbacks.stage }},
    );
    defer deinitOptionalJsonSlice(std.testing.allocator, pipeline);
    try std.testing.expectEqualStrings("{\"index\":0}", pipeline[0].?.bytes);

    try std.testing.expectError(
        error.FactoryLimitReached,
        context.parallel(std.testing.allocator, &.{
            .{ .run = callbacks.task },
            .{ .run = callbacks.failTask },
        }),
    );
    try std.testing.expectError(
        error.FactoryLimitReached,
        context.pipeline(
            std.testing.allocator,
            &.{
                try JsonView.init("{\"input\":1}"),
                try JsonView.init("{\"input\":2}"),
            },
            &.{.{ .run = callbacks.stage }},
        ),
    );
}
