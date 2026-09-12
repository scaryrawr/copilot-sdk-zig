const std = @import("std");

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

pub const Error = SdkError || std.mem.Allocator.Error || error{ErrorCaptureNotEmpty};

pub const ErrorCapture = struct {
    allocator: std.mem.Allocator,
    captured: ?Failure = null,

    pub fn init(allocator: std.mem.Allocator) ErrorCapture {
        return .{ .allocator = allocator };
    }

    pub fn get(self: *const ErrorCapture) ?*const Failure {
        return if (self.captured) |*failure| failure else null;
    }

    pub fn take(self: *ErrorCapture) ?Failure {
        const failure = self.captured;
        self.captured = null;
        return failure;
    }

    pub fn reset(self: *ErrorCapture) void {
        if (self.captured) |*failure| failure.deinit();
        self.captured = null;
    }

    pub fn deinit(self: *ErrorCapture) void {
        self.reset();
        self.* = undefined;
    }

    pub fn ensureEmpty(self: *const ErrorCapture) error{ErrorCaptureNotEmpty}!void {
        if (self.captured != null) return error.ErrorCaptureNotEmpty;
    }

    pub fn recordOwned(self: *ErrorCapture, failure: Failure) Error {
        if (self.captured != null) {
            var rejected = failure;
            rejected.deinit();
            return error.ErrorCaptureNotEmpty;
        }
        self.captured = failure;
        return failure.errorTag();
    }
};

pub const Failure = struct {
    allocator: std.mem.Allocator,
    detail: FailureDetail,

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
                .rejected => |detail| detail.rpc.message,
                else => null,
            },
            .permission => |value| switch (value) {
                .invalid_decision => |detail| detail.message,
                .delivery_failed => |detail| if (detail.rpc) |rpc| rpc.message else null,
                .not_accepted => |detail| detail.message,
                else => null,
            },
            .tool => |value| switch (value) {
                .invalid_result => |detail| detail.message,
                .delivery_failed => |detail| if (detail.rpc) |rpc| rpc.message else null,
                .not_accepted => |detail| detail.message,
                else => null,
            },
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
                .rejected => |detail| detail.rpc.machine_code,
                else => null,
            },
            .permission => |value| switch (value) {
                .delivery_failed => |detail| if (detail.rpc) |rpc| rpc.machine_code else null,
                else => null,
            },
            .tool => |value| switch (value) {
                .delivery_failed => |detail| if (detail.rpc) |rpc| rpc.machine_code else null,
                else => null,
            },
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
                .delivery_failed => |detail| detail.cause,
                else => null,
            },
            .tool => |value| switch (value) {
                .invalid_result => |detail| detail.cause,
                .handler_failed => |detail| detail.cause,
                .delivery_failed => |detail| detail.cause,
                else => null,
            },
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
    stop: struct { failures: []Failure },
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
    rejected: struct {
        session_id: []u8,
        operation: []u8,
        rpc: RpcFailure,
    },
};

pub const PermissionFailure = union(enum) {
    invalid_decision: struct {
        session_id: []u8,
        request_id: []u8,
        message: []u8,
        cause: ?Cause,
    },
    handler_failed: struct { session_id: []u8, request_id: []u8, cause: Cause },
    delivery_failed: struct {
        session_id: []u8,
        request_id: []u8,
        rpc: ?RpcFailure,
        cause: ?Cause,
    },
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
    delivery_failed: struct {
        session_id: []u8,
        request_id: []u8,
        tool_call_id: ?[]u8,
        tool_name: ?[]u8,
        handler_cause: ?Cause,
        rpc: ?RpcFailure,
        cause: ?Cause,
    },
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

fn deinitRpc(allocator: std.mem.Allocator, rpc: RpcFailure) void {
    allocator.free(rpc.method);
    freeOptional(allocator, rpc.machine_code);
    allocator.free(rpc.message);
    freeOptional(allocator, rpc.data_json);
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
            .invalid_envelope => |item| freeOptional(allocator, item.message_json),
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
            .rejected => |item| {
                allocator.free(item.session_id);
                allocator.free(item.operation);
                deinitRpc(allocator, item.rpc);
            },
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
            .delivery_failed => |item| {
                allocator.free(item.session_id);
                allocator.free(item.request_id);
                if (item.rpc) |rpc| deinitRpc(allocator, rpc);
                if (item.cause) |cause| deinitCause(allocator, cause);
            },
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
            .delivery_failed => |item| {
                allocator.free(item.session_id);
                allocator.free(item.request_id);
                freeOptional(allocator, item.tool_call_id);
                freeOptional(allocator, item.tool_name);
                if (item.handler_cause) |cause| deinitCause(allocator, cause);
                if (item.rpc) |rpc| deinitRpc(allocator, rpc);
                if (item.cause) |cause| deinitCause(allocator, cause);
            },
            .not_accepted => |item| {
                allocator.free(item.session_id);
                allocator.free(item.request_id);
                freeOptional(allocator, item.tool_call_id);
                allocator.free(item.message);
            },
        },
    }
}

test "capture rejects stale state and take is self-contained" {
    const allocator = std.testing.allocator;
    var capture = ErrorCapture.init(allocator);
    defer capture.deinit();

    const failure = Failure{
        .allocator = allocator,
        .detail = .{ .rpc = .{
            .method = try allocator.dupe(u8, "session.resume"),
            .request_id = 7,
            .code = -32000,
            .machine_code = try allocator.dupe(u8, "missing_session"),
            .message = try allocator.dupe(u8, "Session not found"),
            .data_json = try allocator.dupe(u8, "{\"code\":\"missing_session\"}"),
        } },
    };
    try std.testing.expectEqual(error.RpcRejected, capture.recordOwned(failure));
    try std.testing.expectError(error.ErrorCaptureNotEmpty, capture.ensureEmpty());
    try std.testing.expectEqual(
        error.ErrorCaptureNotEmpty,
        capture.recordOwned(.{
            .allocator = allocator,
            .detail = .{ .protocol = .{ .invalid_content_length = .{
                .value = try allocator.dupe(u8, "rejected"),
            } } },
        }),
    );
    try std.testing.expectEqual(error.RpcRejected, capture.get().?.errorTag());

    var taken = capture.take().?;
    defer taken.deinit();
    try capture.ensureEmpty();
    try std.testing.expectEqualStrings("Session not found", taken.message().?);
    try std.testing.expectEqualStrings("missing_session", taken.machineCode().?);
}
