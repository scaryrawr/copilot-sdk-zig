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

pub const WorkflowDeclaredLimits = struct {
    max_concurrent_subagents: ?u32 = null,
    max_total_subagents: ?u64 = null,
    timeout_seconds: ?f64 = null,
    max_ai_credits: ?f64 = null,
};

pub const WorkflowLimitOverrides = struct {
    max_concurrent_subagents: LimitOverride(u32) = .inherit,
    max_total_subagents: LimitOverride(u64) = .inherit,
    timeout_seconds: LimitOverride(f64) = .inherit,
    max_ai_credits: LimitOverride(f64) = .inherit,
};

pub const WorkflowPhase = struct {
    title: []const u8,
    detail: ?[]const u8 = null,
};

pub const WorkflowMeta = struct {
    name: []const u8,
    description: []const u8,
    phases: []const WorkflowPhase = &.{},
    args_schema: ?JsonView = null,
    limits: ?WorkflowDeclaredLimits = null,
};

pub const WorkflowDefinition = struct {
    meta: WorkflowMeta,
    run: *const fn (
        allocator: std.mem.Allocator,
        context: *WorkflowContext,
        user_context: ?*anyopaque,
    ) anyerror!?Json,
    context: ?*anyopaque = null,
};

pub const WorkflowAgentOptions = struct {
    label: ?[]const u8 = null,
    schema: ?JsonView = null,
    model: ?[]const u8 = null,
    reasoning_effort: ?[]const u8 = null,
    context_tier: ?session.ContextTier = null,
    agent: ?[]const u8 = null,
};

pub const WorkflowStepOptions = struct {
    is_volatile: bool = false,
};

pub const WorkflowProducer = struct {
    context: ?*anyopaque = null,
    produce: *const fn (std.mem.Allocator, ?*anyopaque) anyerror!Json,
};

pub const WorkflowTask = struct {
    context: ?*anyopaque = null,
    run: *const fn (
        allocator: std.mem.Allocator,
        branch: *WorkflowBranch,
        context: ?*anyopaque,
    ) anyerror!?Json,
    deinit_context: ?*const fn (std.mem.Allocator, ?*anyopaque) void = null,

    pub fn deinit(self: *WorkflowTask, allocator: std.mem.Allocator) void {
        if (self.deinit_context) |deinit_context| deinit_context(allocator, self.context);
        self.* = undefined;
    }
};

pub const WorkflowStage = struct {
    context: ?*anyopaque = null,
    run: *const fn (
        allocator: std.mem.Allocator,
        branch: *WorkflowBranch,
        previous: JsonView,
        original: JsonView,
        index: usize,
        context: ?*anyopaque,
    ) anyerror!?Json,
};

pub const WorkflowCancellation = struct {
    event: *std.Io.Event,
    io: std.Io,

    pub fn isCancelled(self: WorkflowCancellation) bool {
        return self.event.isSet();
    }

    pub fn wait(self: WorkflowCancellation) !void {
        try self.event.wait(self.io);
    }
};

pub const JournalLookup = union(enum) {
    miss,
    value: Json,
};

pub const WorkflowExecution = struct {
    state: *anyopaque,
    io: std.Io,
    agent_fn: *const fn (
        *anyopaque,
        std.mem.Allocator,
        []const u8,
        WorkflowAgentOptions,
    ) anyerror!?Json,
    journal_get_fn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!JournalLookup,
    journal_put_fn: *const fn (*anyopaque, []const u8, JsonView) anyerror!void,
    pause_fn: *const fn (*anyopaque, []const u8) anyerror!void,
    progress_fn: *const fn (*anyopaque, WorkflowLogKind, []const u8) anyerror!void,
};

pub const WorkflowLogKind = enum { log, phase };

pub const WorkflowBranch = struct {
    execution: *WorkflowExecution,
    cancel: WorkflowCancellation,

    pub fn agent(
        self: *WorkflowBranch,
        allocator: std.mem.Allocator,
        prompt: []const u8,
        options: WorkflowAgentOptions,
    ) !?Json {
        if (self.cancel.isCancelled()) return error.WorkflowCancelled;
        return self.execution.agent_fn(self.execution.state, allocator, prompt, options);
    }

    pub fn step(
        self: *WorkflowBranch,
        allocator: std.mem.Allocator,
        key: []const u8,
        producer: WorkflowProducer,
        options: WorkflowStepOptions,
    ) !Json {
        if (key.len == 0) return error.InvalidWorkflowStepKey;
        if (self.cancel.isCancelled()) return error.WorkflowCancelled;
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

    pub fn log(self: *WorkflowBranch, message: []const u8) !void {
        if (self.cancel.isCancelled()) return error.WorkflowCancelled;
        return self.execution.progress_fn(self.execution.state, .log, message);
    }
};

pub const WorkflowContext = struct {
    run_id: []const u8,
    args: JsonView,
    cancel: WorkflowCancellation,
    execution: WorkflowExecution,

    fn branch(self: *WorkflowContext) WorkflowBranch {
        return .{ .execution = &self.execution, .cancel = self.cancel };
    }

    pub fn agent(
        self: *WorkflowContext,
        allocator: std.mem.Allocator,
        prompt: []const u8,
        options: WorkflowAgentOptions,
    ) !?Json {
        var value = self.branch();
        return value.agent(allocator, prompt, options);
    }

    pub fn step(
        self: *WorkflowContext,
        allocator: std.mem.Allocator,
        key: []const u8,
        producer: WorkflowProducer,
        options: WorkflowStepOptions,
    ) !Json {
        var value = self.branch();
        return value.step(allocator, key, producer, options);
    }

    pub fn pause(self: *WorkflowContext, key: []const u8) !void {
        if (key.len == 0) return error.InvalidWorkflowCheckpointKey;
        if (self.cancel.isCancelled()) return error.WorkflowCancelled;
        return self.execution.pause_fn(self.execution.state, key);
    }

    pub fn phase(self: *WorkflowContext, title: []const u8) !void {
        if (title.len == 0) return error.InvalidWorkflowPhase;
        if (self.cancel.isCancelled()) return error.WorkflowCancelled;
        return self.execution.progress_fn(self.execution.state, .phase, title);
    }

    pub fn log(self: *WorkflowContext, message: []const u8) !void {
        var value = self.branch();
        return value.log(message);
    }

    pub fn parallel(
        self: *WorkflowContext,
        allocator: std.mem.Allocator,
        tasks: []const WorkflowTask,
    ) ![]?Json {
        if (tasks.len > 4096) return error.WorkflowFanoutTooLarge;
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
        self: *WorkflowContext,
        allocator: std.mem.Allocator,
        items: []const JsonView,
        stages: []const WorkflowStage,
    ) ![]?Json {
        if (items.len > 4096) return error.WorkflowFanoutTooLarge;
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
    branch: WorkflowBranch,
    task: WorkflowTask,
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
    branch: WorkflowBranch,
    item: JsonView,
    index: usize,
    stages: []const WorkflowStage,
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
        error.WorkflowCancelled,
        error.WorkflowTransportFailure,
        error.WorkflowDurableFailure,
        error.WorkflowLimitReached,
        => true,
        else => false,
    };
}

pub const JsonPresence = union(enum) {
    absent,
    value: JsonView,
};

pub const WorkflowRunStatus = enum {
    pending,
    running,
    completed,
    halted,
    paused,
    cancelled,
    @"error",
};

pub const WorkflowPauseInfo = union(enum) {
    user,
    checkpoint: []const u8,
};

pub const WorkflowFailureKind = enum {
    max_total_subagents,
    timeout_seconds,
    max_ai_credits,
};

pub const WorkflowDurableOperation = enum {
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

pub const WorkflowFailure = union(enum) {
    limit_reached: struct {
        kind: WorkflowFailureKind,
        value: f64,
        suggested_value: ?f64,
        run_id: []const u8,
    },
    resume_declined: struct { run_id: []const u8, reason: []const u8 },
    durable_failure: struct {
        code: []const u8,
        operation: WorkflowDurableOperation,
        run_id: []const u8,
    },
    accounting_incomplete: struct { run_id: []const u8, drained_nano_aiu: i64 },
    provider_disconnected: struct { run_id: []const u8 },
};

pub const WorkflowRunError = struct {
    message: ?[]const u8 = null,
    failure: ?WorkflowFailure = null,
};

pub const WorkflowHalt = struct {
    reason: ?[]const u8 = null,
    failure: ?WorkflowFailure = null,
};

pub const WorkflowOutcome = union(enum) {
    pending,
    running,
    completed: JsonPresence,
    halted: WorkflowHalt,
    paused: WorkflowPauseInfo,
    cancelled: ?[]const u8,
    @"error": WorkflowRunError,
};

pub const WorkflowRun = struct {
    arena: std.heap.ArenaAllocator,
    run_id: []const u8,
    attempt: ?u32,
    snapshot: ?JsonView,
    outcome: WorkflowOutcome,

    pub fn deinit(self: *WorkflowRun) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn isTerminal(self: WorkflowRun) bool {
        return switch (self.outcome) {
            .pending, .running => false,
            else => true,
        };
    }
};

pub const WorkflowRunOptions = struct {
    args: ?JsonView = null,
    limits: ?WorkflowLimitOverrides = null,
    notify_on_complete: ?bool = null,
    log_phase_names: ?bool = null,
};

pub const WorkflowResumeOptions = struct {
    limits: ?WorkflowLimitOverrides = null,
    notify_on_complete: ?bool = null,
    log_phase_names: ?bool = null,
};

pub const WorkflowListRunsOptions = struct {
    after_seq: ?i64 = null,
    before_seq: ?i64 = null,
    limit: ?u16 = null,
};

pub const WorkflowProgressOptions = struct {
    phase_id: ?[]const u8 = null,
    after_seq: ?i64 = null,
    before_seq: ?i64 = null,
    limit: ?u16 = null,
};

pub const WorkflowWaitOptions = struct {
    poll_interval_ns: u64 = 5 * std.time.ns_per_s,
    timeout_ns: ?u64 = null,
    cancellation: ?*session.Cancellation = null,
};

pub const WorkflowRunsPage = struct {
    value: Json,

    pub fn deinit(self: *WorkflowRunsPage) void {
        self.value.deinit();
        self.* = undefined;
    }
};

pub const WorkflowProgressPage = struct {
    value: Json,

    pub fn deinit(self: *WorkflowProgressPage) void {
        self.value.deinit();
        self.* = undefined;
    }
};

pub const WorkflowRunDetail = struct {
    value: Json,

    pub fn deinit(self: *WorkflowRunDetail) void {
        self.value.deinit();
        self.* = undefined;
    }
};

pub fn WorkflowApi(comptime SessionType: type) type {
    return struct {
        session: SessionType,

        const Self = @This();

        pub fn run(
            self: Self,
            allocator: std.mem.Allocator,
            name: []const u8,
            options: WorkflowRunOptions,
        ) !WorkflowRun {
            return self.session.workflowRun(allocator, name, options);
        }

        pub fn @"resume"(
            self: Self,
            allocator: std.mem.Allocator,
            run_id: []const u8,
            options: WorkflowResumeOptions,
        ) !WorkflowRun {
            return self.session.workflowResume(allocator, run_id, options);
        }

        pub fn getRun(self: Self, allocator: std.mem.Allocator, run_id: []const u8) !WorkflowRun {
            return self.session.workflowGetRun(allocator, run_id);
        }

        pub fn waitForRun(
            self: Self,
            allocator: std.mem.Allocator,
            run_id: []const u8,
            options: WorkflowWaitOptions,
        ) !WorkflowRun {
            return self.session.workflowWaitForRun(allocator, run_id, options);
        }

        pub fn listRuns(
            self: Self,
            allocator: std.mem.Allocator,
            options: WorkflowListRunsOptions,
        ) !WorkflowRunsPage {
            return self.session.workflowListRuns(allocator, options);
        }

        pub fn getRunDetail(
            self: Self,
            allocator: std.mem.Allocator,
            run_id: []const u8,
        ) !WorkflowRunDetail {
            return self.session.workflowGetRunDetail(allocator, run_id);
        }

        pub fn getRunProgress(
            self: Self,
            allocator: std.mem.Allocator,
            run_id: []const u8,
            options: WorkflowProgressOptions,
        ) !WorkflowProgressPage {
            return self.session.workflowGetRunProgress(allocator, run_id, options);
        }

        pub fn pause(self: Self, allocator: std.mem.Allocator, run_id: []const u8) !WorkflowRun {
            return self.session.workflowPause(allocator, run_id);
        }

        pub fn cancel(self: Self, allocator: std.mem.Allocator, run_id: []const u8) !WorkflowRun {
            return self.session.workflowCancel(allocator, run_id);
        }
    };
}

pub fn validateWorkflows(workflows: []const WorkflowDefinition) !void {
    for (workflows, 0..) |definition, index| {
        if (std.mem.trim(u8, definition.meta.name, " \t\r\n").len == 0)
            return error.InvalidWorkflowName;
        for (workflows[0..index]) |previous| {
            if (std.mem.eql(u8, previous.meta.name, definition.meta.name))
                return error.DuplicateWorkflowName;
        }
        for (definition.meta.phases, 0..) |phase, phase_index| {
            if (std.mem.trim(u8, phase.title, " \t\r\n").len == 0)
                return error.InvalidWorkflowPhase;
            for (definition.meta.phases[0..phase_index]) |previous| {
                if (std.mem.eql(u8, previous.title, phase.title))
                    return error.DuplicateWorkflowPhase;
            }
        }
        if (definition.meta.args_schema) |schema| {
            const parsed = std.json.parseFromSlice(
                std.json.Value,
                std.heap.page_allocator,
                schema.bytes,
                .{},
            ) catch return error.InvalidWorkflowArgsSchema;
            defer parsed.deinit();
            switch (parsed.value) {
                .object, .bool => {},
                else => return error.InvalidWorkflowArgsSchema,
            }
        }
        if (definition.meta.limits) |limits| try validateDeclaredLimits(limits);
    }
}

pub fn validateDeclaredLimits(limits: WorkflowDeclaredLimits) !void {
    if (limits.max_concurrent_subagents) |value|
        if (value == 0) return error.InvalidWorkflowLimit;
    if (limits.max_total_subagents) |value|
        if (value == 0) return error.InvalidWorkflowLimit;
    if (limits.timeout_seconds) |value|
        if (!std.math.isFinite(value) or value <= 0 or value > 2_147_483.647)
            return error.InvalidWorkflowLimit;
    if (limits.max_ai_credits) |value| {
        const nano = value * 1_000_000_000;
        if (!std.math.isFinite(value) or value <= 0 or
            nano < 1 or nano > @as(f64, @floatFromInt(std.math.maxInt(i64))))
            return error.InvalidWorkflowLimit;
    }
}

pub fn validateLimitOverrides(limits: WorkflowLimitOverrides) !void {
    switch (limits.max_concurrent_subagents) {
        .value => |value| if (value == 0) return error.InvalidWorkflowLimit,
        else => {},
    }
    switch (limits.max_total_subagents) {
        .value => |value| if (value == 0 or value > std.math.maxInt(i64))
            return error.InvalidWorkflowLimit,
        else => {},
    }
    switch (limits.timeout_seconds) {
        .value => |value| if (!std.math.isFinite(value) or
            value <= 0 or value > 2_147_483.647)
            return error.InvalidWorkflowLimit,
        else => {},
    }
    switch (limits.max_ai_credits) {
        .value => |value| {
            const nano = value * 1_000_000_000;
            if (!std.math.isFinite(value) or value <= 0 or
                nano < 1 or nano > @as(f64, @floatFromInt(std.math.maxInt(i64))))
                return error.InvalidWorkflowLimit;
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

test "workflow registration rejects duplicate names and phase titles" {
    const run = struct {
        fn callback(_: std.mem.Allocator, _: *WorkflowContext, _: ?*anyopaque) !?Json {
            return null;
        }
    }.callback;
    try std.testing.expectError(error.DuplicateWorkflowName, validateWorkflows(&.{
        .{ .meta = .{ .name = "same", .description = "one" }, .run = run },
        .{ .meta = .{ .name = "same", .description = "two" }, .run = run },
    }));
    try std.testing.expectError(error.DuplicateWorkflowPhase, validateWorkflows(&.{
        .{
            .meta = .{
                .name = "phases",
                .description = "duplicate",
                .phases = &.{ .{ .title = "Review" }, .{ .title = "Review" } },
            },
            .run = run,
        },
    }));

    try validateWorkflows(&.{
        .{
            .meta = .{
                .name = "boolean-schema",
                .description = "Accepts every JSON value.",
                .args_schema = try JsonView.init("true"),
            },
            .run = run,
        },
    });
    try std.testing.expectError(error.InvalidWorkflowArgsSchema, validateWorkflows(&.{
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
    const inherited = WorkflowLimitOverrides{};
    try std.testing.expect(inherited.max_ai_credits == .inherit);
    const unlimited = WorkflowLimitOverrides{ .max_ai_credits = .unlimited };
    try std.testing.expect(unlimited.max_ai_credits == .unlimited);
    const bounded = WorkflowLimitOverrides{ .max_ai_credits = .{ .value = 2.5 } };
    try std.testing.expectEqual(@as(f64, 2.5), bounded.max_ai_credits.value);
    try std.testing.expectError(
        error.InvalidWorkflowLimit,
        validateLimitOverrides(.{ .max_concurrent_subagents = .{ .value = 0 } }),
    );
    try std.testing.expectError(
        error.InvalidWorkflowLimit,
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
            _: WorkflowAgentOptions,
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
        fn progress(_: *anyopaque, _: WorkflowLogKind, _: []const u8) !void {}

        fn task(
            allocator: std.mem.Allocator,
            _: *WorkflowBranch,
            _: ?*anyopaque,
        ) !?Json {
            return try Json.init(allocator, "{\"task\":true}");
        }

        fn failTask(
            _: std.mem.Allocator,
            _: *WorkflowBranch,
            _: ?*anyopaque,
        ) !?Json {
            return error.WorkflowLimitReached;
        }

        fn stage(
            allocator: std.mem.Allocator,
            _: *WorkflowBranch,
            _: JsonView,
            _: JsonView,
            index: usize,
            _: ?*anyopaque,
        ) !?Json {
            if (index == 1) return error.WorkflowLimitReached;
            return try Json.initValue(allocator, .{ .index = index });
        }
    };

    var cancellation: std.Io.Event = .unset;
    var state: u8 = 0;
    var context = WorkflowContext{
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
        error.WorkflowLimitReached,
        context.parallel(std.testing.allocator, &.{
            .{ .run = callbacks.task },
            .{ .run = callbacks.failTask },
        }),
    );
    try std.testing.expectError(
        error.WorkflowLimitReached,
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
