const std = @import("std");
const builtin = @import("builtin");

pub const SdkError = error{
    ClientFailure,
    ProcessExited,
    ProtocolFailure,
    ProtocolMismatch,
    RpcRejected,
    SessionNotFound,
    SessionFailure,
    QueueFailure,
    PermissionFailure,
    ToolFailure,
};

pub const DetailedError = std.mem.Allocator.Error;

pub fn DetailedResult(comptime T: type) type {
    return union(enum) {
        success: T,
        failure: Failure,
    };
}

pub const Failure = struct {
    allocator: std.mem.Allocator,
    native_error: anyerror = error.UnknownFailure,
    detail: FailureDetail,

    pub fn clone(self: *const Failure, allocator: std.mem.Allocator) DetailedError!Failure {
        return .{
            .allocator = allocator,
            .native_error = self.native_error,
            .detail = try cloneDetail(allocator, self.detail),
        };
    }

    pub fn deinit(self: *Failure) void {
        deinitDetail(self.allocator, &self.detail);
        self.* = undefined;
    }

    pub fn errorTag(self: *const Failure) SdkError {
        return switch (self.detail) {
            .process => |process| switch (process) {
                .exited => error.ProcessExited,
                else => error.ClientFailure,
            },
            .client => error.ClientFailure,
            .protocol => |protocol| switch (protocol) {
                .mismatch => error.ProtocolMismatch,
                else => error.ProtocolFailure,
            },
            .rpc => error.RpcRejected,
            .session => |session| switch (session) {
                .not_found => error.SessionNotFound,
                else => error.SessionFailure,
            },
            .queue => error.QueueFailure,
            .permission => error.PermissionFailure,
            .tool => error.ToolFailure,
            .shutdown => error.ClientFailure,
        };
    }

    pub fn message(self: *const Failure) ?[]const u8 {
        return switch (self.detail) {
            .process => |value| switch (value) {
                .spawn => |detail| detail.message,
                .exited => |detail| detail.message,
                .terminate => |detail| detail.message,
            },
            .client => |value| switch (value) {
                .io => |detail| detail.message,
                .json => |detail| detail.message,
                .invalid_config => |detail| detail.message,
                .reentrant_call => |detail| detail.message,
                .request_cancelled => |detail| detail.message,
                .operation_rejected => |detail| detail.message,
                .stop => null,
            },
            .protocol => |value| switch (value) {
                .invalid_json => |detail| detail.message,
                .invalid_envelope => |detail| detail.message_json,
                else => null,
            },
            .rpc => |value| value.message,
            .session => |value| switch (value) {
                .not_found => |detail| detail.rpc.message,
                .agent => |detail| detail.message,
                .detach_failed => |detail| detail.message,
                else => null,
            },
            .queue => |value| switch (value) {
                .rejected => |detail| detail.message,
                else => null,
            },
            .permission => |value| switch (value) {
                .invalid_decision => |detail| detail.message,
                .delivery_failed => |detail| detail.message,
                .not_accepted => |detail| detail.message,
                else => null,
            },
            .tool => |value| switch (value) {
                .invalid_result => |detail| detail.message,
                .delivery_failed => |detail| detail.message,
                .not_accepted => |detail| detail.message,
                else => null,
            },
            .shutdown => null,
        };
    }

    pub fn machineCode(self: *const Failure) ?[]const u8 {
        return switch (self.detail) {
            .rpc => |value| value.machine_code,
            .session => |value| switch (value) {
                .not_found => |detail| detail.rpc.machine_code,
                .agent => |detail| detail.error_code,
                .detach_failed => |detail| if (detail.rpc) |rpc| rpc.machine_code else null,
                else => null,
            },
            .queue => |value| switch (value) {
                .rejected => |detail| detail.machine_code,
                else => null,
            },
            .permission => |value| switch (value) {
                .delivery_failed => |detail| detail.machine_code,
                else => null,
            },
            .tool => |value| switch (value) {
                .delivery_failed => |detail| detail.machine_code,
                else => null,
            },
            .shutdown => null,
            else => null,
        };
    }

    pub fn cause(self: *const Failure) ?Cause {
        return switch (self.detail) {
            .process => |value| switch (value) {
                .spawn => |detail| detail.cause,
                .terminate => |detail| detail.cause,
                else => null,
            },
            .client => |value| switch (value) {
                .io => |detail| detail.cause,
                .json => |detail| detail.cause,
                else => null,
            },
            .protocol => |value| switch (value) {
                .invalid_json => |detail| detail.cause,
                else => null,
            },
            .session => |value| switch (value) {
                .event_loop_closed => |detail| detail.cause,
                else => null,
            },
            .permission => |value| switch (value) {
                .invalid_decision => |detail| detail.cause,
                .handler_failed => |detail| detail.cause,
                else => null,
            },
            .tool => |value| switch (value) {
                .invalid_result => |detail| detail.cause,
                .handler_failed => |detail| detail.cause,
                else => null,
            },
            .shutdown => null,
            else => null,
        };
    }

    pub fn isTransportFailure(self: *const Failure) bool {
        return switch (self.detail) {
            .process => true,
            .client => |value| switch (value) {
                .io, .request_cancelled => true,
                else => false,
            },
            else => false,
        };
    }
};

pub const Cause = struct {
    code: anyerror,
    message: ?[]u8 = null,
};

pub const FailureDetail = union(enum) {
    process: ProcessFailure,
    client: ClientFailure,
    protocol: ProtocolFailure,
    rpc: RpcFailure,
    session: SessionFailure,
    queue: QueueFailure,
    permission: PermissionFailure,
    tool: ToolFailure,
    shutdown: ShutdownFailure,
};

pub const ShutdownFailure = struct {
    sessions_attempted: usize,
    child_termination_attempted: bool,
    failure_storage: []Failure,
    failure_count: usize,
    diagnostics_dropped: usize,

    pub fn failures(self: *const ShutdownFailure) []const Failure {
        return self.failure_storage[0..self.failure_count];
    }
};

pub const ProcessFailure = union(enum) {
    spawn: struct { executable: []u8, message: []u8, cause: Cause },
    exited: struct { exit: ProcessExit, message: []u8 },
    terminate: struct { exit: ?ProcessExit, message: []u8, cause: Cause },
};

pub const ProcessExit = union(enum) {
    exited: u8,
    signal: u32,
    stopped: u32,
    unknown: u32,
};

pub const ClientFailure = union(enum) {
    io: struct { operation: ClientOperation, message: []u8, cause: Cause },
    json: struct { operation: ClientOperation, message: []u8, cause: Cause },
    invalid_config: struct { field: ?[]u8, message: []u8 },
    reentrant_call: struct { method: []u8, message: []u8 },
    request_cancelled: struct { method: []u8, request_id: u64, message: []u8 },
    operation_rejected: struct {
        operation: SessionOperation,
        session_id: []u8,
        message: ?[]u8,
    },
    stop: struct { failures: []Failure },
};

pub const SessionOperation = enum {
    delete,
    set_foreground,

    pub fn wireMethod(self: SessionOperation) []const u8 {
        return switch (self) {
            .delete => "session.delete",
            .set_foreground => "session.setForeground",
        };
    }
};

pub const ClientOperation = enum {
    spawn,
    connect,
    read,
    write,
    stop,
    callback,
};

pub const ProtocolFailure = union(enum) {
    missing_content_length,
    invalid_content_length: struct { value: []u8 },
    frame_too_large: struct { declared: usize, maximum: usize },
    truncated_frame: struct { declared: usize, received: usize },
    invalid_json: struct { message: []u8, cause: Cause },
    invalid_envelope: struct { reason: EnvelopeViolation, message_json: ?[]u8 },
    unexpected_response: struct { expected_id: u64, actual_id_json: ?[]u8 },
    mismatch: ProtocolMismatch,
};

pub const EnvelopeViolation = enum {
    non_object,
    invalid_jsonrpc_version,
    missing_id,
    invalid_id,
    missing_result_and_error,
    result_and_error,
    invalid_error_object,
    invalid_error_code,
    invalid_error_message,
    invalid_method,
    missing_params,
    malformed_field_type,
    invalid_session_status,
};

pub const ProtocolMismatch = union(enum) {
    unsupported: struct { server: u64, minimum: u64, maximum: u64 },
    invalid_server_version: struct { server_json: []u8 },
    changed: struct { previous: u64, current: u64 },
};

pub const RpcFailure = struct {
    method: []u8,
    request_id: u64,
    code: i64,
    machine_code: ?[]u8,
    message: []u8,
    data_json: ?[]u8,
    context: RpcOperationContext,
};

pub const RpcOperationContext = union(enum) {
    generic,
    session: struct { session_id: []u8 },
    queue: struct { session_id: []u8 },
    permission: struct {
        session_id: []u8,
        request_id: []u8,
    },
    tool: struct {
        session_id: []u8,
        request_id: []u8,
        tool_call_id: ?[]u8,
        tool_name: ?[]u8,
    },
};

pub const SessionFailure = union(enum) {
    not_found: struct { session_id: []u8, rpc: RpcFailure },
    agent: SessionAgentFailure,
    timeout: struct { session_id: []u8, timeout_ns: u64 },
    send_while_waiting: struct { session_id: []u8 },
    event_loop_closed: struct { session_id: []u8, cause: ?Cause },
    id_mismatch: struct { requested: []u8, returned: []u8 },
    detach_failed: struct {
        session_id: []u8,
        attempts: usize,
        rpc: ?RpcFailure,
        message: ?[]u8,
    },
};

pub const SessionAgentFailure = struct {
    session_id: []u8,
    error_type: []u8,
    error_code: ?[]u8,
    message: []u8,
    status_code: ?u16,
    provider_call_id: ?[]u8,
    service_request_id: ?[]u8,
    remediation_json: ?[]u8,
    url: ?[]u8,
    stack: ?[]u8,
    eligible_for_auto_switch: ?bool,
};

pub const QueueFailure = union(enum) {
    full: struct {
        session_id: ?[]u8,
        event_type: ?[]u8,
        length: usize,
        capacity: usize,
    },
    rejected: RpcFailure,
};

pub const PermissionFailure = union(enum) {
    invalid_decision: struct {
        session_id: []u8,
        request_id: []u8,
        message: []u8,
        cause: ?Cause,
    },
    handler_failed: struct { session_id: []u8, request_id: []u8, cause: Cause },
    delivery_failed: RpcFailure,
    not_accepted: struct { session_id: []u8, request_id: []u8, message: []u8 },
};

pub const ToolFailure = union(enum) {
    invalid_result: struct {
        session_id: []u8,
        request_id: []u8,
        tool_call_id: ?[]u8,
        tool_name: ?[]u8,
        message: []u8,
        cause: ?Cause,
    },
    handler_failed: struct {
        session_id: []u8,
        request_id: []u8,
        tool_call_id: []u8,
        tool_name: []u8,
        cause: Cause,
    },
    delivery_failed: RpcFailure,
    not_accepted: struct {
        session_id: []u8,
        request_id: []u8,
        tool_call_id: ?[]u8,
        message: []u8,
    },
};

fn freeOptional(allocator: std.mem.Allocator, value: ?[]u8) void {
    if (value) |slice| allocator.free(slice);
}

fn deinitCause(allocator: std.mem.Allocator, cause: Cause) void {
    freeOptional(allocator, cause.message);
}

var rpc_data_wipe_observer: ?*const fn ([]const u8) void = null;

pub fn setRpcDataWipeObserverForTest(observer: ?*const fn ([]const u8) void) void {
    if (!builtin.is_test) @compileError("RPC wipe observers are test-only");
    rpc_data_wipe_observer = observer;
}

pub fn freeRpcData(allocator: std.mem.Allocator, value: []u8) void {
    std.crypto.secureZero(u8, value);
    if (builtin.is_test) {
        if (rpc_data_wipe_observer) |observer| observer(value);
    }
    allocator.free(value);
}

fn deinitRpc(allocator: std.mem.Allocator, rpc: RpcFailure) void {
    allocator.free(rpc.method);
    freeOptional(allocator, rpc.machine_code);
    allocator.free(rpc.message);
    if (rpc.data_json) |data_json| {
        freeRpcData(allocator, data_json);
    }
    switch (rpc.context) {
        .generic => {},
        .session => |context| allocator.free(context.session_id),
        .queue => |context| allocator.free(context.session_id),
        .permission => |context| {
            allocator.free(context.session_id);
            allocator.free(context.request_id);
        },
        .tool => |context| {
            allocator.free(context.session_id);
            allocator.free(context.request_id);
            freeOptional(allocator, context.tool_call_id);
            freeOptional(allocator, context.tool_name);
        },
    }
}

fn deinitAgent(allocator: std.mem.Allocator, agent: SessionAgentFailure) void {
    allocator.free(agent.session_id);
    allocator.free(agent.error_type);
    freeOptional(allocator, agent.error_code);
    allocator.free(agent.message);
    freeOptional(allocator, agent.provider_call_id);
    freeOptional(allocator, agent.service_request_id);
    freeOptional(allocator, agent.remediation_json);
    freeOptional(allocator, agent.url);
    freeOptional(allocator, agent.stack);
}

fn cloneSlice(allocator: std.mem.Allocator, value: []const u8) DetailedError![]u8 {
    return try allocator.dupe(u8, value);
}

fn cloneOptionalSlice(
    allocator: std.mem.Allocator,
    value: ?[]const u8,
) DetailedError!?[]u8 {
    return if (value) |slice| try cloneSlice(allocator, slice) else null;
}

fn cloneCause(allocator: std.mem.Allocator, cause: Cause) DetailedError!Cause {
    return .{
        .code = cause.code,
        .message = try cloneOptionalSlice(allocator, cause.message),
    };
}

fn cloneFailures(
    allocator: std.mem.Allocator,
    failures: []const Failure,
) DetailedError![]Failure {
    const cloned = try allocator.alloc(Failure, failures.len);
    errdefer allocator.free(cloned);

    var initialized: usize = 0;
    errdefer for (cloned[0..initialized]) |*failure| failure.deinit();

    for (failures, cloned) |*failure, *destination| {
        destination.* = try failure.clone(allocator);
        initialized += 1;
    }
    return cloned;
}

fn cloneRpcContext(
    allocator: std.mem.Allocator,
    context: RpcOperationContext,
) DetailedError!RpcOperationContext {
    return switch (context) {
        .generic => .generic,
        .session => |value| .{ .session = .{
            .session_id = try cloneSlice(allocator, value.session_id),
        } },
        .queue => |value| .{ .queue = .{
            .session_id = try cloneSlice(allocator, value.session_id),
        } },
        .permission => |value| permission: {
            const session_id = try cloneSlice(allocator, value.session_id);
            errdefer allocator.free(session_id);
            break :permission .{ .permission = .{
                .session_id = session_id,
                .request_id = try cloneSlice(allocator, value.request_id),
            } };
        },
        .tool => |value| tool: {
            const session_id = try cloneSlice(allocator, value.session_id);
            errdefer allocator.free(session_id);
            const request_id = try cloneSlice(allocator, value.request_id);
            errdefer allocator.free(request_id);
            const tool_call_id = try cloneOptionalSlice(allocator, value.tool_call_id);
            errdefer freeOptional(allocator, tool_call_id);
            break :tool .{ .tool = .{
                .session_id = session_id,
                .request_id = request_id,
                .tool_call_id = tool_call_id,
                .tool_name = try cloneOptionalSlice(allocator, value.tool_name),
            } };
        },
    };
}

fn cloneRpc(allocator: std.mem.Allocator, rpc: RpcFailure) DetailedError!RpcFailure {
    const method = try cloneSlice(allocator, rpc.method);
    errdefer allocator.free(method);
    const machine_code = try cloneOptionalSlice(allocator, rpc.machine_code);
    errdefer freeOptional(allocator, machine_code);
    const message = try cloneSlice(allocator, rpc.message);
    errdefer allocator.free(message);
    const data_json = try cloneOptionalSlice(allocator, rpc.data_json);
    errdefer if (data_json) |value| freeRpcData(allocator, value);

    return .{
        .method = method,
        .request_id = rpc.request_id,
        .code = rpc.code,
        .machine_code = machine_code,
        .message = message,
        .data_json = data_json,
        .context = try cloneRpcContext(allocator, rpc.context),
    };
}

fn cloneAgent(
    allocator: std.mem.Allocator,
    agent: SessionAgentFailure,
) DetailedError!SessionAgentFailure {
    const session_id = try cloneSlice(allocator, agent.session_id);
    errdefer allocator.free(session_id);
    const error_type = try cloneSlice(allocator, agent.error_type);
    errdefer allocator.free(error_type);
    const error_code = try cloneOptionalSlice(allocator, agent.error_code);
    errdefer freeOptional(allocator, error_code);
    const message = try cloneSlice(allocator, agent.message);
    errdefer allocator.free(message);
    const provider_call_id = try cloneOptionalSlice(allocator, agent.provider_call_id);
    errdefer freeOptional(allocator, provider_call_id);
    const service_request_id = try cloneOptionalSlice(allocator, agent.service_request_id);
    errdefer freeOptional(allocator, service_request_id);
    const remediation_json = try cloneOptionalSlice(allocator, agent.remediation_json);
    errdefer freeOptional(allocator, remediation_json);
    const url = try cloneOptionalSlice(allocator, agent.url);
    errdefer freeOptional(allocator, url);

    return .{
        .session_id = session_id,
        .error_type = error_type,
        .error_code = error_code,
        .message = message,
        .status_code = agent.status_code,
        .provider_call_id = provider_call_id,
        .service_request_id = service_request_id,
        .remediation_json = remediation_json,
        .url = url,
        .stack = try cloneOptionalSlice(allocator, agent.stack),
        .eligible_for_auto_switch = agent.eligible_for_auto_switch,
    };
}

fn cloneDetail(
    allocator: std.mem.Allocator,
    detail: FailureDetail,
) DetailedError!FailureDetail {
    return switch (detail) {
        .process => |value| .{ .process = switch (value) {
            .spawn => |item| spawn: {
                const executable = try cloneSlice(allocator, item.executable);
                errdefer allocator.free(executable);
                const message = try cloneSlice(allocator, item.message);
                errdefer allocator.free(message);
                break :spawn .{ .spawn = .{
                    .executable = executable,
                    .message = message,
                    .cause = try cloneCause(allocator, item.cause),
                } };
            },
            .exited => |item| .{ .exited = .{
                .exit = item.exit,
                .message = try cloneSlice(allocator, item.message),
            } },
            .terminate => |item| terminate: {
                const message = try cloneSlice(allocator, item.message);
                errdefer allocator.free(message);
                break :terminate .{ .terminate = .{
                    .exit = item.exit,
                    .message = message,
                    .cause = try cloneCause(allocator, item.cause),
                } };
            },
        } },
        .client => |value| .{ .client = switch (value) {
            .io => |item| io: {
                const message = try cloneSlice(allocator, item.message);
                errdefer allocator.free(message);
                break :io .{ .io = .{
                    .operation = item.operation,
                    .message = message,
                    .cause = try cloneCause(allocator, item.cause),
                } };
            },
            .json => |item| json: {
                const message = try cloneSlice(allocator, item.message);
                errdefer allocator.free(message);
                break :json .{ .json = .{
                    .operation = item.operation,
                    .message = message,
                    .cause = try cloneCause(allocator, item.cause),
                } };
            },
            .invalid_config => |item| invalid_config: {
                const field = try cloneOptionalSlice(allocator, item.field);
                errdefer freeOptional(allocator, field);
                break :invalid_config .{ .invalid_config = .{
                    .field = field,
                    .message = try cloneSlice(allocator, item.message),
                } };
            },
            .reentrant_call => |item| reentrant_call: {
                const method = try cloneSlice(allocator, item.method);
                errdefer allocator.free(method);
                break :reentrant_call .{ .reentrant_call = .{
                    .method = method,
                    .message = try cloneSlice(allocator, item.message),
                } };
            },
            .request_cancelled => |item| request_cancelled: {
                const method = try cloneSlice(allocator, item.method);
                errdefer allocator.free(method);
                break :request_cancelled .{ .request_cancelled = .{
                    .method = method,
                    .request_id = item.request_id,
                    .message = try cloneSlice(allocator, item.message),
                } };
            },
            .operation_rejected => |item| operation_rejected: {
                const session_id = try cloneSlice(allocator, item.session_id);
                errdefer allocator.free(session_id);
                break :operation_rejected .{ .operation_rejected = .{
                    .operation = item.operation,
                    .session_id = session_id,
                    .message = try cloneOptionalSlice(allocator, item.message),
                } };
            },
            .stop => |item| .{ .stop = .{
                .failures = try cloneFailures(allocator, item.failures),
            } },
        } },
        .protocol => |value| .{ .protocol = switch (value) {
            .missing_content_length => .missing_content_length,
            .invalid_content_length => |item| .{ .invalid_content_length = .{
                .value = try cloneSlice(allocator, item.value),
            } },
            .frame_too_large => |item| .{ .frame_too_large = item },
            .truncated_frame => |item| .{ .truncated_frame = item },
            .invalid_json => |item| invalid_json: {
                const message = try cloneSlice(allocator, item.message);
                errdefer allocator.free(message);
                break :invalid_json .{ .invalid_json = .{
                    .message = message,
                    .cause = try cloneCause(allocator, item.cause),
                } };
            },
            .invalid_envelope => |item| .{ .invalid_envelope = .{
                .reason = item.reason,
                .message_json = try cloneOptionalSlice(allocator, item.message_json),
            } },
            .unexpected_response => |item| .{ .unexpected_response = .{
                .expected_id = item.expected_id,
                .actual_id_json = try cloneOptionalSlice(allocator, item.actual_id_json),
            } },
            .mismatch => |item| .{ .mismatch = switch (item) {
                .unsupported => |version| .{ .unsupported = version },
                .invalid_server_version => |version| .{ .invalid_server_version = .{
                    .server_json = try cloneSlice(allocator, version.server_json),
                } },
                .changed => |version| .{ .changed = version },
            } },
        } },
        .rpc => |value| .{ .rpc = try cloneRpc(allocator, value) },
        .session => |value| .{ .session = switch (value) {
            .not_found => |item| not_found: {
                const session_id = try cloneSlice(allocator, item.session_id);
                errdefer allocator.free(session_id);
                break :not_found .{ .not_found = .{
                    .session_id = session_id,
                    .rpc = try cloneRpc(allocator, item.rpc),
                } };
            },
            .agent => |item| .{ .agent = try cloneAgent(allocator, item) },
            .timeout => |item| .{ .timeout = .{
                .session_id = try cloneSlice(allocator, item.session_id),
                .timeout_ns = item.timeout_ns,
            } },
            .send_while_waiting => |item| .{ .send_while_waiting = .{
                .session_id = try cloneSlice(allocator, item.session_id),
            } },
            .event_loop_closed => |item| event_loop_closed: {
                const session_id = try cloneSlice(allocator, item.session_id);
                errdefer allocator.free(session_id);
                break :event_loop_closed .{ .event_loop_closed = .{
                    .session_id = session_id,
                    .cause = if (item.cause) |cause| try cloneCause(allocator, cause) else null,
                } };
            },
            .id_mismatch => |item| id_mismatch: {
                const requested = try cloneSlice(allocator, item.requested);
                errdefer allocator.free(requested);
                break :id_mismatch .{ .id_mismatch = .{
                    .requested = requested,
                    .returned = try cloneSlice(allocator, item.returned),
                } };
            },
            .detach_failed => |item| detach_failed: {
                const session_id = try cloneSlice(allocator, item.session_id);
                errdefer allocator.free(session_id);
                const rpc = if (item.rpc) |rpc| try cloneRpc(allocator, rpc) else null;
                errdefer if (rpc) |failure| deinitRpc(allocator, failure);
                break :detach_failed .{ .detach_failed = .{
                    .session_id = session_id,
                    .attempts = item.attempts,
                    .rpc = rpc,
                    .message = try cloneOptionalSlice(allocator, item.message),
                } };
            },
        } },
        .queue => |value| .{ .queue = switch (value) {
            .full => |item| full: {
                const session_id = try cloneOptionalSlice(allocator, item.session_id);
                errdefer freeOptional(allocator, session_id);
                break :full .{ .full = .{
                    .session_id = session_id,
                    .event_type = try cloneOptionalSlice(allocator, item.event_type),
                    .length = item.length,
                    .capacity = item.capacity,
                } };
            },
            .rejected => |item| .{ .rejected = try cloneRpc(allocator, item) },
        } },
        .permission => |value| .{ .permission = switch (value) {
            .invalid_decision => |item| invalid_decision: {
                const session_id = try cloneSlice(allocator, item.session_id);
                errdefer allocator.free(session_id);
                const request_id = try cloneSlice(allocator, item.request_id);
                errdefer allocator.free(request_id);
                const message = try cloneSlice(allocator, item.message);
                errdefer allocator.free(message);
                break :invalid_decision .{ .invalid_decision = .{
                    .session_id = session_id,
                    .request_id = request_id,
                    .message = message,
                    .cause = if (item.cause) |cause| try cloneCause(allocator, cause) else null,
                } };
            },
            .handler_failed => |item| handler_failed: {
                const session_id = try cloneSlice(allocator, item.session_id);
                errdefer allocator.free(session_id);
                const request_id = try cloneSlice(allocator, item.request_id);
                errdefer allocator.free(request_id);
                break :handler_failed .{ .handler_failed = .{
                    .session_id = session_id,
                    .request_id = request_id,
                    .cause = try cloneCause(allocator, item.cause),
                } };
            },
            .delivery_failed => |item| .{ .delivery_failed = try cloneRpc(allocator, item) },
            .not_accepted => |item| not_accepted: {
                const session_id = try cloneSlice(allocator, item.session_id);
                errdefer allocator.free(session_id);
                const request_id = try cloneSlice(allocator, item.request_id);
                errdefer allocator.free(request_id);
                break :not_accepted .{ .not_accepted = .{
                    .session_id = session_id,
                    .request_id = request_id,
                    .message = try cloneSlice(allocator, item.message),
                } };
            },
        } },
        .tool => |value| .{ .tool = switch (value) {
            .invalid_result => |item| invalid_result: {
                const session_id = try cloneSlice(allocator, item.session_id);
                errdefer allocator.free(session_id);
                const request_id = try cloneSlice(allocator, item.request_id);
                errdefer allocator.free(request_id);
                const tool_call_id = try cloneOptionalSlice(allocator, item.tool_call_id);
                errdefer freeOptional(allocator, tool_call_id);
                const tool_name = try cloneOptionalSlice(allocator, item.tool_name);
                errdefer freeOptional(allocator, tool_name);
                const message = try cloneSlice(allocator, item.message);
                errdefer allocator.free(message);
                break :invalid_result .{ .invalid_result = .{
                    .session_id = session_id,
                    .request_id = request_id,
                    .tool_call_id = tool_call_id,
                    .tool_name = tool_name,
                    .message = message,
                    .cause = if (item.cause) |cause| try cloneCause(allocator, cause) else null,
                } };
            },
            .handler_failed => |item| handler_failed: {
                const session_id = try cloneSlice(allocator, item.session_id);
                errdefer allocator.free(session_id);
                const request_id = try cloneSlice(allocator, item.request_id);
                errdefer allocator.free(request_id);
                const tool_call_id = try cloneSlice(allocator, item.tool_call_id);
                errdefer allocator.free(tool_call_id);
                const tool_name = try cloneSlice(allocator, item.tool_name);
                errdefer allocator.free(tool_name);
                break :handler_failed .{ .handler_failed = .{
                    .session_id = session_id,
                    .request_id = request_id,
                    .tool_call_id = tool_call_id,
                    .tool_name = tool_name,
                    .cause = try cloneCause(allocator, item.cause),
                } };
            },
            .delivery_failed => |item| .{ .delivery_failed = try cloneRpc(allocator, item) },
            .not_accepted => |item| not_accepted: {
                const session_id = try cloneSlice(allocator, item.session_id);
                errdefer allocator.free(session_id);
                const request_id = try cloneSlice(allocator, item.request_id);
                errdefer allocator.free(request_id);
                const tool_call_id = try cloneOptionalSlice(allocator, item.tool_call_id);
                errdefer freeOptional(allocator, tool_call_id);
                break :not_accepted .{ .not_accepted = .{
                    .session_id = session_id,
                    .request_id = request_id,
                    .tool_call_id = tool_call_id,
                    .message = try cloneSlice(allocator, item.message),
                } };
            },
        } },
        .shutdown => |item| shutdown: {
            const failure_storage = try allocator.alloc(Failure, item.failure_storage.len);
            errdefer allocator.free(failure_storage);

            var initialized: usize = 0;
            errdefer for (failure_storage[0..initialized]) |*failure| failure.deinit();

            for (
                item.failure_storage[0..item.failure_count],
                failure_storage[0..item.failure_count],
            ) |*failure, *destination| {
                destination.* = try failure.clone(allocator);
                initialized += 1;
            }

            break :shutdown .{ .shutdown = .{
                .sessions_attempted = item.sessions_attempted,
                .child_termination_attempted = item.child_termination_attempted,
                .failure_storage = failure_storage,
                .failure_count = item.failure_count,
                .diagnostics_dropped = item.diagnostics_dropped,
            } };
        },
    };
}

fn deinitDetail(allocator: std.mem.Allocator, detail: *FailureDetail) void {
    switch (detail.*) {
        .process => |value| switch (value) {
            .spawn => |item| {
                allocator.free(item.executable);
                allocator.free(item.message);
                deinitCause(allocator, item.cause);
            },
            .exited => |item| allocator.free(item.message),
            .terminate => |item| {
                allocator.free(item.message);
                deinitCause(allocator, item.cause);
            },
        },
        .client => |value| switch (value) {
            .io => |item| {
                allocator.free(item.message);
                deinitCause(allocator, item.cause);
            },
            .json => |item| {
                allocator.free(item.message);
                deinitCause(allocator, item.cause);
            },
            .invalid_config => |item| {
                freeOptional(allocator, item.field);
                allocator.free(item.message);
            },
            .reentrant_call => |item| {
                allocator.free(item.method);
                allocator.free(item.message);
            },
            .request_cancelled => |item| {
                allocator.free(item.method);
                allocator.free(item.message);
            },
            .operation_rejected => |item| {
                allocator.free(item.session_id);
                freeOptional(allocator, item.message);
            },
            .stop => |item| {
                for (item.failures) |*failure| failure.deinit();
                allocator.free(item.failures);
            },
        },
        .protocol => |value| switch (value) {
            .invalid_content_length => |item| allocator.free(item.value),
            .invalid_json => |item| {
                allocator.free(item.message);
                deinitCause(allocator, item.cause);
            },
            .invalid_envelope => |item| {
                if (item.message_json) |message_json| {
                    freeRpcData(allocator, message_json);
                }
            },
            .unexpected_response => |item| freeOptional(allocator, item.actual_id_json),
            .mismatch => |item| switch (item) {
                .invalid_server_version => |version| allocator.free(version.server_json),
                else => {},
            },
            else => {},
        },
        .rpc => |value| deinitRpc(allocator, value),
        .session => |value| switch (value) {
            .not_found => |item| {
                allocator.free(item.session_id);
                deinitRpc(allocator, item.rpc);
            },
            .agent => |item| deinitAgent(allocator, item),
            .timeout => |item| allocator.free(item.session_id),
            .send_while_waiting => |item| allocator.free(item.session_id),
            .event_loop_closed => |item| {
                allocator.free(item.session_id);
                if (item.cause) |cause| deinitCause(allocator, cause);
            },
            .id_mismatch => |item| {
                allocator.free(item.requested);
                allocator.free(item.returned);
            },
            .detach_failed => |item| {
                allocator.free(item.session_id);
                if (item.rpc) |rpc| deinitRpc(allocator, rpc);
                freeOptional(allocator, item.message);
            },
        },
        .queue => |value| switch (value) {
            .full => |item| {
                freeOptional(allocator, item.session_id);
                freeOptional(allocator, item.event_type);
            },
            .rejected => |item| deinitRpc(allocator, item),
        },
        .permission => |value| switch (value) {
            .invalid_decision => |item| {
                allocator.free(item.session_id);
                allocator.free(item.request_id);
                allocator.free(item.message);
                if (item.cause) |cause| deinitCause(allocator, cause);
            },
            .handler_failed => |item| {
                allocator.free(item.session_id);
                allocator.free(item.request_id);
                deinitCause(allocator, item.cause);
            },
            .delivery_failed => |item| deinitRpc(allocator, item),
            .not_accepted => |item| {
                allocator.free(item.session_id);
                allocator.free(item.request_id);
                allocator.free(item.message);
            },
        },
        .tool => |value| switch (value) {
            .invalid_result => |item| {
                allocator.free(item.session_id);
                allocator.free(item.request_id);
                freeOptional(allocator, item.tool_call_id);
                freeOptional(allocator, item.tool_name);
                allocator.free(item.message);
                if (item.cause) |cause| deinitCause(allocator, cause);
            },
            .handler_failed => |item| {
                allocator.free(item.session_id);
                allocator.free(item.request_id);
                allocator.free(item.tool_call_id);
                allocator.free(item.tool_name);
                deinitCause(allocator, item.cause);
            },
            .delivery_failed => |item| deinitRpc(allocator, item),
            .not_accepted => |item| {
                allocator.free(item.session_id);
                allocator.free(item.request_id);
                freeOptional(allocator, item.tool_call_id);
                allocator.free(item.message);
            },
        },
        .shutdown => |item| {
            for (item.failure_storage[0..item.failure_count]) |*failure| failure.deinit();
            if (item.failure_storage.len != 0) allocator.free(item.failure_storage);
        },
    }
}

const CloneTestData = struct {
    var rpc_method = "rpc.method".*;
    var rpc_message = "rpc message".*;
    var rpc_secret = "{\"token\":\"rpc-secret\"}".*;
    var envelope_secret = "{\"token\":\"envelope-secret\"}".*;
    var tail = "tail".*;
    var tail_message = "force trailing allocation".*;
};

fn testRpc(data_json: ?[]u8) RpcFailure {
    return .{
        .method = &CloneTestData.rpc_method,
        .request_id = 91,
        .code = -32091,
        .machine_code = null,
        .message = &CloneTestData.rpc_message,
        .data_json = data_json,
        .context = .generic,
    };
}

test "failure clone returns independent pump diagnostics" {
    var value = "nope".*;
    const source = Failure{
        .allocator = std.heap.page_allocator,
        .native_error = error.InvalidCharacter,
        .detail = .{ .protocol = .{ .invalid_content_length = .{
            .value = &value,
        } } },
    };
    var cloned = try source.clone(std.testing.allocator);
    defer cloned.deinit();

    try std.testing.expectEqual(source.native_error, cloned.native_error);
    try std.testing.expectEqualStrings(
        source.detail.protocol.invalid_content_length.value,
        cloned.detail.protocol.invalid_content_length.value,
    );
    try std.testing.expect(
        source.detail.protocol.invalid_content_length.value.ptr !=
            cloned.detail.protocol.invalid_content_length.value.ptr,
    );
}

const TestWipeProbe = struct {
    var calls: usize = 0;
    var saw_nonzero: bool = false;

    fn reset() void {
        calls = 0;
        saw_nonzero = false;
    }

    fn observe(value: []const u8) void {
        calls += 1;
        for (value) |byte| {
            if (byte != 0) saw_nonzero = true;
        }
    }
};

fn testSecretFailure() Failure {
    return .{
        .allocator = std.heap.page_allocator,
        .native_error = error.SecretFailure,
        .detail = .{ .client = .{ .stop = .{ .failures = testBorrowedFailures: {
            const failures = struct {
                var values = [_]Failure{
                    .{
                        .allocator = std.heap.page_allocator,
                        .native_error = error.SecretRpcFailure,
                        .detail = .{ .rpc = testRpc(
                            &CloneTestData.rpc_secret,
                        ) },
                    },
                    .{
                        .allocator = std.heap.page_allocator,
                        .native_error = error.SecretEnvelopeFailure,
                        .detail = .{ .protocol = .{ .invalid_envelope = .{
                            .reason = .invalid_error_object,
                            .message_json = &CloneTestData.envelope_secret,
                        } } },
                    },
                    .{
                        .allocator = std.heap.page_allocator,
                        .native_error = error.RollbackTailFailure,
                        .detail = .{ .client = .{ .reentrant_call = .{
                            .method = &CloneTestData.tail,
                            .message = &CloneTestData.tail_message,
                        } } },
                    },
                };
            };
            break :testBorrowedFailures failures.values[0..];
        } } } },
    };
}

fn cloneSecretFailureForAllocationTest(allocator: std.mem.Allocator) !void {
    const source = testSecretFailure();
    var cloned = try source.clone(allocator);
    cloned.deinit();
}

test "failure clone rolls back every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        cloneSecretFailureForAllocationTest,
        .{},
    );
}

test "failure clone normal deinit securely wipes cloned secret JSON" {
    const source = testSecretFailure();
    var cloned = try source.clone(std.testing.allocator);

    TestWipeProbe.reset();
    setRpcDataWipeObserverForTest(TestWipeProbe.observe);
    defer setRpcDataWipeObserverForTest(null);
    cloned.deinit();

    try std.testing.expectEqual(@as(usize, 2), TestWipeProbe.calls);
    try std.testing.expect(!TestWipeProbe.saw_nonzero);
}

test "failure clone rollback securely wipes cloned secret JSON" {
    const source = testSecretFailure();

    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var counted = try source.clone(counting.allocator());
    counted.deinit();

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = counting.alloc_index - 1,
    });
    TestWipeProbe.reset();
    setRpcDataWipeObserverForTest(TestWipeProbe.observe);
    defer setRpcDataWipeObserverForTest(null);

    try std.testing.expectError(error.OutOfMemory, source.clone(failing.allocator()));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 2), TestWipeProbe.calls);
    try std.testing.expect(!TestWipeProbe.saw_nonzero);
}

test "session operation wire methods" {
    const cases = [_]struct {
        operation: SessionOperation,
        expected: []const u8,
    }{
        .{ .operation = .delete, .expected = "session.delete" },
        .{ .operation = .set_foreground, .expected = "session.setForeground" },
    };

    try std.testing.expectEqual(std.meta.fields(SessionOperation).len, cases.len);
    for (cases) |case| {
        try std.testing.expectEqualStrings(case.expected, case.operation.wireMethod());
    }
}
