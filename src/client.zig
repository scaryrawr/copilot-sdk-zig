const std = @import("std");
const errors = @import("errors.zig");
const json_rpc = @import("json_rpc.zig");
const models = @import("models.zig");
const provider = @import("provider.zig");
const protocol = @import("protocol_version.zig");
const session_types = @import("session.zig");

const max_queued_events: usize = 1024;

const FailurePolicy = enum {
    legacy,
    detailed,
};

const LegacyFailure = struct {
    native_error: anyerror,
};

fn PolicyFailure(comptime policy: FailurePolicy) type {
    return if (policy == .legacy) LegacyFailure else errors.Failure;
}

fn PolicyResult(comptime policy: FailurePolicy, comptime T: type) type {
    if (policy == .detailed) return errors.DetailedResult(T);
    return union(enum) {
        success: T,
        failure: LegacyFailure,
    };
}

const InboundMessage = union(enum) {
    response: struct {
        id: u64,
        id_value: std.json.Value,
        result: ?std.json.Value,
        rpc_error: ?std.json.Value,
    },
    request: struct {
        id: std.json.Value,
        method: []const u8,
        params: ?std.json.Value,
    },
    notification: struct {
        method: []const u8,
        params: ?std.json.Value,
    },
};

fn legacyResult(
    comptime T: type,
    result: errors.DetailedError!PolicyResult(.legacy, T),
) !T {
    return switch (try result) {
        .success => |value| value,
        .failure => |failure| failure.native_error,
    };
}

fn policyFailure(
    comptime policy: FailurePolicy,
    native_error: anyerror,
    comptime constructor: anytype,
    args: anytype,
) errors.DetailedError!PolicyFailure(policy) {
    if (comptime policy == .legacy) return .{ .native_error = native_error };
    return @call(.auto, constructor, args);
}

fn ownedCause(code: anyerror) errors.Cause {
    return .{ .code = code };
}

fn recordFailure(
    allocator: std.mem.Allocator,
    tag: anyerror,
    detail: errors.FailureDetail,
) errors.Failure {
    return .{
        .allocator = allocator,
        .native_error = tag,
        .detail = detail,
    };
}

fn recordClientIo(
    allocator: std.mem.Allocator,
    operation: errors.ClientOperation,
    cause: anyerror,
) !errors.Failure {
    const message = try allocator.dupe(u8, @errorName(cause));
    return recordFailure(allocator, cause, .{ .client = .{ .io = .{
        .operation = operation,
        .message = message,
        .cause = ownedCause(cause),
    } } });
}

fn recordClientJson(
    allocator: std.mem.Allocator,
    operation: errors.ClientOperation,
    cause: anyerror,
) !errors.Failure {
    const message = try allocator.dupe(u8, @errorName(cause));
    return recordFailure(allocator, cause, .{ .client = .{ .json = .{
        .operation = operation,
        .message = message,
        .cause = ownedCause(cause),
    } } });
}

fn recordProcessSpawn(
    allocator: std.mem.Allocator,
    executable: []const u8,
    cause: anyerror,
) !errors.Failure {
    const owned_executable = try allocator.dupe(u8, executable);
    var executable_transferred = false;
    defer if (!executable_transferred) allocator.free(owned_executable);
    const message = try allocator.dupe(u8, @errorName(cause));
    var message_transferred = false;
    defer if (!message_transferred) allocator.free(message);
    executable_transferred = true;
    message_transferred = true;
    return recordFailure(allocator, cause, .{ .process = .{ .spawn = .{
        .executable = owned_executable,
        .message = message,
        .cause = ownedCause(cause),
    } } });
}

fn processExit(term: std.process.Child.Term) errors.ProcessExit {
    return switch (term) {
        .exited => |code| .{ .exited = code },
        .signal => |signal| .{ .signal = @intFromEnum(signal) },
        .stopped => |signal| .{ .stopped = @intFromEnum(signal) },
        .unknown => |code| .{ .unknown = code },
    };
}

fn recordProcessExit(
    allocator: std.mem.Allocator,
    exit: errors.ProcessExit,
) !errors.Failure {
    const message = try std.fmt.allocPrint(
        allocator,
        "Copilot CLI process terminated ({s})",
        .{@tagName(exit)},
    );
    return recordFailure(allocator, error.EndOfStream, .{ .process = .{ .exited = .{
        .exit = exit,
        .message = message,
    } } });
}

fn recordProcessTerminate(
    allocator: std.mem.Allocator,
    exit: ?errors.ProcessExit,
    cause: anyerror,
) !errors.Failure {
    const message = try allocator.dupe(u8, @errorName(cause));
    return recordFailure(allocator, cause, .{ .process = .{ .terminate = .{
        .exit = exit,
        .message = message,
        .cause = ownedCause(cause),
    } } });
}

fn recordReentrant(
    allocator: std.mem.Allocator,
    method: []const u8,
) !errors.Failure {
    const owned_method = try allocator.dupe(u8, method);
    var method_transferred = false;
    defer if (!method_transferred) allocator.free(owned_method);
    const message = try allocator.dupe(u8, "RPC calls cannot be nested from an RPC handler");
    var message_transferred = false;
    defer if (!message_transferred) allocator.free(message);
    method_transferred = true;
    message_transferred = true;
    return recordFailure(allocator, error.ReentrantRpcCall, .{ .client = .{ .reentrant_call = .{
        .method = owned_method,
        .message = message,
    } } });
}

fn recordConnectRejected(allocator: std.mem.Allocator) !errors.Failure {
    const message = try allocator.dupe(u8, "Copilot CLI rejected the connection");
    return recordFailure(allocator, error.ConnectRejected, .{ .client = .{
        .invalid_config = .{
            .field = null,
            .message = message,
        },
    } });
}

fn recordInvalidConfig(
    allocator: std.mem.Allocator,
    field: []const u8,
    cause: anyerror,
) !errors.Failure {
    const owned_field = try allocator.dupe(u8, field);
    const message = allocator.dupe(u8, @errorName(cause)) catch |err| {
        allocator.free(owned_field);
        return err;
    };
    return recordFailure(allocator, cause, .{ .client = .{
        .invalid_config = .{
            .field = owned_field,
            .message = message,
        },
    } });
}

fn recordInvalidJson(
    allocator: std.mem.Allocator,
    cause: anyerror,
) !errors.Failure {
    const message = try allocator.dupe(u8, @errorName(cause));
    return recordFailure(allocator, cause, .{ .protocol = .{ .invalid_json = .{
        .message = message,
        .cause = ownedCause(cause),
    } } });
}

fn recordInvalidEnvelope(
    allocator: std.mem.Allocator,
    native_error: anyerror,
    reason: errors.EnvelopeViolation,
    offending_value: std.json.Value,
) !errors.Failure {
    const json = try std.json.Stringify.valueAlloc(allocator, offending_value, .{});
    return recordFailure(allocator, native_error, .{ .protocol = .{
        .invalid_envelope = .{
            .reason = reason,
            .message_json = json,
        },
    } });
}

fn recordEnvelope(
    allocator: std.mem.Allocator,
    reason: errors.EnvelopeViolation,
    offending_value: std.json.Value,
) !errors.Failure {
    return recordInvalidEnvelope(
        allocator,
        envelopeError(reason),
        reason,
        offending_value,
    );
}

fn envelopeError(reason: errors.EnvelopeViolation) anyerror {
    return switch (reason) {
        .missing_result_and_error => error.MissingResult,
        else => error.InvalidJsonRpc,
    };
}

fn recordUnexpectedResponse(
    allocator: std.mem.Allocator,
    expected_id: u64,
    actual_id: std.json.Value,
) !errors.Failure {
    const json = try std.json.Stringify.valueAlloc(allocator, actual_id, .{});
    return recordFailure(allocator, error.UnexpectedResponse, .{ .protocol = .{
        .unexpected_response = .{
            .expected_id = expected_id,
            .actual_id_json = json,
        },
    } });
}

fn recordInvalidEvent(
    allocator: std.mem.Allocator,
    reason: errors.EnvelopeViolation,
    value: std.json.Value,
) !errors.Failure {
    return recordInvalidEnvelope(
        allocator,
        error.InvalidSessionEvent,
        reason,
        value,
    );
}

fn parseInboundMessage(
    comptime failure_policy: FailurePolicy,
    allocator: std.mem.Allocator,
    value: std.json.Value,
) errors.DetailedError!PolicyResult(failure_policy, InboundMessage) {
    const object = switch (value) {
        .object => |object| object,
        else => return .{ .failure = try policyFailure(
            failure_policy,
            envelopeError(.non_object),
            recordEnvelope,
            .{ allocator, .non_object, value },
        ) },
    };
    const version = object.get("jsonrpc") orelse
        return .{ .failure = try policyFailure(
            failure_policy,
            envelopeError(.invalid_jsonrpc_version),
            recordEnvelope,
            .{ allocator, .invalid_jsonrpc_version, value },
        ) };
    if (version != .string or !std.mem.eql(u8, version.string, "2.0"))
        return .{ .failure = try policyFailure(
            failure_policy,
            envelopeError(.invalid_jsonrpc_version),
            recordEnvelope,
            .{ allocator, .invalid_jsonrpc_version, value },
        ) };

    if (object.get("method")) |method_value| {
        const method = switch (method_value) {
            .string => |name| name,
            else => return .{ .failure = try policyFailure(
                failure_policy,
                envelopeError(.invalid_method),
                recordEnvelope,
                .{ allocator, .invalid_method, value },
            ) },
        };
        const params = object.get("params");
        if (object.get("id")) |id| {
            return .{ .success = .{ .request = .{
                .id = id,
                .method = method,
                .params = params,
            } } };
        }
        return .{ .success = .{ .notification = .{
            .method = method,
            .params = params,
        } } };
    }

    const id_value = object.get("id") orelse
        return .{ .failure = try policyFailure(
            failure_policy,
            envelopeError(.missing_id),
            recordEnvelope,
            .{ allocator, .missing_id, value },
        ) };
    const id = switch (id_value) {
        .integer => |number| std.math.cast(u64, number) orelse
            return .{ .failure = try policyFailure(
                failure_policy,
                envelopeError(.invalid_id),
                recordEnvelope,
                .{ allocator, .invalid_id, value },
            ) },
        else => return .{ .failure = try policyFailure(
            failure_policy,
            envelopeError(.invalid_id),
            recordEnvelope,
            .{ allocator, .invalid_id, value },
        ) },
    };
    const result = object.get("result");
    const rpc_error = object.get("error");
    if (result != null and rpc_error != null)
        return .{ .failure = try policyFailure(
            failure_policy,
            envelopeError(.result_and_error),
            recordEnvelope,
            .{ allocator, .result_and_error, value },
        ) };
    if (result == null and rpc_error == null)
        return .{ .failure = try policyFailure(
            failure_policy,
            envelopeError(.missing_result_and_error),
            recordEnvelope,
            .{ allocator, .missing_result_and_error, value },
        ) };
    return .{ .success = .{ .response = .{
        .id = id,
        .id_value = id_value,
        .result = result,
        .rpc_error = rpc_error,
    } } };
}

fn recordProtocolMismatch(
    allocator: std.mem.Allocator,
    server: u64,
) !errors.Failure {
    return recordFailure(allocator, error.ProtocolVersionMismatch, .{ .protocol = .{ .mismatch = .{
        .unsupported = .{
            .server = server,
            .minimum = protocol.sdk_protocol_version,
            .maximum = protocol.sdk_protocol_version,
        },
    } } });
}

fn recordInvalidProtocolVersion(
    allocator: std.mem.Allocator,
    server: std.json.Value,
) !errors.Failure {
    const server_json = try std.json.Stringify.valueAlloc(allocator, server, .{});
    return recordFailure(allocator, error.ProtocolVersionMismatch, .{ .protocol = .{
        .mismatch = .{ .invalid_server_version = .{
            .server_json = server_json,
        } },
    } });
}

fn recordQueueFull(
    allocator: std.mem.Allocator,
    session_id: ?[]const u8,
    event_type: ?[]const u8,
    length: usize,
) !errors.Failure {
    var transferred = false;
    const owned_session_id = if (session_id) |value|
        try allocator.dupe(u8, value)
    else
        null;
    defer if (!transferred) {
        if (owned_session_id) |value| allocator.free(value);
    };
    const owned_event_type = if (event_type) |value|
        try allocator.dupe(u8, value)
    else
        null;
    defer if (!transferred) {
        if (owned_event_type) |value| allocator.free(value);
    };
    transferred = true;
    return recordFailure(allocator, error.EventQueueFull, .{ .queue = .{ .full = .{
        .session_id = owned_session_id,
        .event_type = owned_event_type,
        .length = length,
        .capacity = max_queued_events,
    } } });
}

fn recordSessionAgentFailure(
    allocator: std.mem.Allocator,
    agent: errors.SessionAgentFailure,
) errors.Failure {
    return recordFailure(allocator, error.CopilotSessionError, .{
        .session = .{ .agent = agent },
    });
}

const SessionAgentWireView = struct {
    error_type: []const u8,
    error_code: ?[]const u8,
    message: []const u8,
    status_code: ?u16,
    provider_call_id: ?[]const u8,
    service_request_id: ?[]const u8,
    remediation: ?std.json.Value,
    url: ?[]const u8,
    stack: ?[]const u8,
    eligible_for_auto_switch: ?bool,
};

fn ownSessionAgentFailure(
    allocator: std.mem.Allocator,
    session_id: []u8,
    view: SessionAgentWireView,
) !errors.SessionAgentFailure {
    var transferred = false;
    const error_type = try allocator.dupe(u8, view.error_type);
    defer if (!transferred) allocator.free(error_type);
    const error_code = try dupeOptional(allocator, view.error_code);
    defer if (!transferred) {
        if (error_code) |value| allocator.free(value);
    };
    const message = try allocator.dupe(u8, view.message);
    defer if (!transferred) allocator.free(message);
    const provider_call_id = try dupeOptional(allocator, view.provider_call_id);
    defer if (!transferred) {
        if (provider_call_id) |value| allocator.free(value);
    };
    const service_request_id = try dupeOptional(allocator, view.service_request_id);
    defer if (!transferred) {
        if (service_request_id) |value| allocator.free(value);
    };
    const remediation_json = if (view.remediation) |value|
        try std.json.Stringify.valueAlloc(allocator, value, .{})
    else
        null;
    defer if (!transferred) {
        if (remediation_json) |value| allocator.free(value);
    };
    const url = try dupeOptional(allocator, view.url);
    defer if (!transferred) {
        if (url) |value| allocator.free(value);
    };
    const stack = try dupeOptional(allocator, view.stack);
    defer if (!transferred) {
        if (stack) |value| allocator.free(value);
    };
    transferred = true;
    return .{
        .session_id = session_id,
        .error_type = error_type,
        .error_code = error_code,
        .message = message,
        .status_code = view.status_code,
        .provider_call_id = provider_call_id,
        .service_request_id = service_request_id,
        .remediation_json = remediation_json,
        .url = url,
        .stack = stack,
        .eligible_for_auto_switch = view.eligible_for_auto_switch,
    };
}

fn sessionFailureFromFrame(
    allocator: std.mem.Allocator,
    session_id: []u8,
    frame: []const u8,
) errors.DetailedError!errors.Failure {
    var session_id_owned = true;
    defer if (session_id_owned) allocator.free(session_id);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, frame, .{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return recordInvalidJson(allocator, err);
    };
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return recordEnvelope(allocator, .non_object, parsed.value),
    };
    const params = switch (object.get("params") orelse
        return recordEnvelope(allocator, .missing_params, parsed.value)) {
        .object => |value| value,
        else => return recordEnvelope(allocator, .missing_params, parsed.value),
    };
    const event = params.get("event") orelse
        return recordEnvelope(allocator, .missing_params, parsed.value);
    const view = Client.sessionAgentWireView(event) catch |err|
        return recordInvalidEvent(allocator, sessionEventViolation(err), event);
    const agent = try ownSessionAgentFailure(allocator, session_id, view orelse
        return recordInvalidEvent(allocator, .malformed_field_type, event));
    session_id_owned = false;
    return recordSessionAgentFailure(allocator, agent);
}

fn recordDetachFailure(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    attempts: usize,
) !errors.Failure {
    var transferred = false;
    const owned_session_id = try allocator.dupe(u8, session_id);
    defer if (!transferred) allocator.free(owned_session_id);
    const message = try allocator.dupe(u8, "session detach was not accepted");
    defer if (!transferred) allocator.free(message);
    transferred = true;
    return recordFailure(allocator, error.SessionDetachFailed, .{ .session = .{ .detach_failed = .{
        .session_id = owned_session_id,
        .attempts = attempts,
        .rpc = null,
        .message = message,
    } } });
}

fn recordPermissionNotAccepted(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    request_id: []const u8,
) !errors.Failure {
    var transferred = false;
    const owned_session_id = try allocator.dupe(u8, session_id);
    defer if (!transferred) allocator.free(owned_session_id);
    const owned_request_id = try allocator.dupe(u8, request_id);
    defer if (!transferred) allocator.free(owned_request_id);
    const message = try allocator.dupe(u8, "permission decision was not accepted");
    defer if (!transferred) allocator.free(message);
    transferred = true;
    return recordFailure(allocator, error.PermissionDecisionNotAccepted, .{ .permission = .{
        .not_accepted = .{
            .session_id = owned_session_id,
            .request_id = owned_request_id,
            .message = message,
        },
    } });
}

fn recordInvalidPermission(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    request_id: []const u8,
    cause: anyerror,
) !errors.Failure {
    var transferred = false;
    const owned_session_id = try allocator.dupe(u8, session_id);
    defer if (!transferred) allocator.free(owned_session_id);
    const owned_request_id = try allocator.dupe(u8, request_id);
    defer if (!transferred) allocator.free(owned_request_id);
    const message = try allocator.dupe(u8, @errorName(cause));
    defer if (!transferred) allocator.free(message);
    transferred = true;
    return recordFailure(allocator, cause, .{ .permission = .{
        .invalid_decision = .{
            .session_id = owned_session_id,
            .request_id = owned_request_id,
            .message = message,
            .cause = .{ .code = cause },
        },
    } });
}

fn recordToolNotAccepted(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    request_id: []const u8,
) !errors.Failure {
    var transferred = false;
    const owned_session_id = try allocator.dupe(u8, session_id);
    defer if (!transferred) allocator.free(owned_session_id);
    const owned_request_id = try allocator.dupe(u8, request_id);
    defer if (!transferred) allocator.free(owned_request_id);
    const message = try allocator.dupe(u8, "tool result was not accepted");
    defer if (!transferred) allocator.free(message);
    transferred = true;
    return recordFailure(allocator, error.ToolResultNotAccepted, .{ .tool = .{ .not_accepted = .{
        .session_id = owned_session_id,
        .request_id = owned_request_id,
        .tool_call_id = null,
        .message = message,
    } } });
}

fn recordInvalidToolResult(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    request_id: []const u8,
    cause: anyerror,
) !errors.Failure {
    var transferred = false;
    const owned_session_id = try allocator.dupe(u8, session_id);
    defer if (!transferred) allocator.free(owned_session_id);
    const owned_request_id = try allocator.dupe(u8, request_id);
    defer if (!transferred) allocator.free(owned_request_id);
    const message = try allocator.dupe(u8, @errorName(cause));
    defer if (!transferred) allocator.free(message);
    transferred = true;
    return recordFailure(allocator, cause, .{ .tool = .{ .invalid_result = .{
        .session_id = owned_session_id,
        .request_id = owned_request_id,
        .tool_call_id = null,
        .tool_name = null,
        .message = message,
        .cause = .{ .code = cause },
    } } });
}

fn recordPermissionHandlerFailure(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    request_id: []const u8,
    cause: anyerror,
) !errors.Failure {
    const owned_session_id = try allocator.dupe(u8, session_id);
    errdefer allocator.free(owned_session_id);
    const owned_request_id = try allocator.dupe(u8, request_id);
    return recordFailure(allocator, cause, .{ .permission = .{ .handler_failed = .{
        .session_id = owned_session_id,
        .request_id = owned_request_id,
        .cause = ownedCause(cause),
    } } });
}

fn recordToolHandlerFailure(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    request_id: []const u8,
    tool_call_id: []const u8,
    tool_name: []const u8,
    cause: anyerror,
) !errors.Failure {
    const owned_session_id = try allocator.dupe(u8, session_id);
    errdefer allocator.free(owned_session_id);
    const owned_request_id = try allocator.dupe(u8, request_id);
    errdefer allocator.free(owned_request_id);
    const owned_tool_call_id = try allocator.dupe(u8, tool_call_id);
    errdefer allocator.free(owned_tool_call_id);
    const owned_tool_name = try allocator.dupe(u8, tool_name);
    return recordFailure(allocator, cause, .{ .tool = .{ .handler_failed = .{
        .session_id = owned_session_id,
        .request_id = owned_request_id,
        .tool_call_id = owned_tool_call_id,
        .tool_name = owned_tool_name,
        .cause = ownedCause(cause),
    } } });
}

fn dupeOptional(
    allocator: std.mem.Allocator,
    value: ?[]const u8,
) !?[]u8 {
    return if (value) |slice| try allocator.dupe(u8, slice) else null;
}

const SessionEventWireError = error{
    MissingField,
    MalformedFieldType,
    InvalidStatus,
};

fn sessionEventViolation(err: SessionEventWireError) errors.EnvelopeViolation {
    return switch (err) {
        error.MissingField => .missing_params,
        error.MalformedFieldType => .malformed_field_type,
        error.InvalidStatus => .invalid_session_status,
    };
}

fn requiredWireString(object: std.json.ObjectMap, name: []const u8) SessionEventWireError![]const u8 {
    return switch (object.get(name) orelse return error.MissingField) {
        .string => |value| value,
        else => error.MalformedFieldType,
    };
}

fn optionalWireString(object: std.json.ObjectMap, name: []const u8) SessionEventWireError!?[]const u8 {
    return switch (object.get(name) orelse return null) {
        .string => |value| value,
        .null => null,
        else => error.MalformedFieldType,
    };
}

fn optionalWireBool(object: std.json.ObjectMap, name: []const u8) SessionEventWireError!?bool {
    return switch (object.get(name) orelse return null) {
        .bool => |value| value,
        .null => null,
        else => error.MalformedFieldType,
    };
}

fn optionalWireStatusCode(object: std.json.ObjectMap, name: []const u8) SessionEventWireError!?u16 {
    return switch (object.get(name) orelse return null) {
        .integer => |value| if (value >= 0 and value <= 999)
            @intCast(value)
        else
            error.InvalidStatus,
        .null => null,
        else => error.MalformedFieldType,
    };
}

fn rpcMachineCode(data: ?std.json.Value) ?[]const u8 {
    const object = switch (data orelse return null) {
        .object => |value| value,
        else => return null,
    };
    for ([_][]const u8{ "code", "errorCode" }) |key| {
        const value = object.get(key) orelse continue;
        if (value == .string) return value.string;
    }
    return null;
}

fn isMissingSession(machine_code: ?[]const u8, message: []const u8) bool {
    if (machine_code) |code| {
        if (std.mem.eql(u8, code, "session_not_found") or
            std.mem.eql(u8, code, "missing_session"))
        {
            return true;
        }
    }
    return std.mem.indexOf(u8, message, "Session not found") != null;
}

const RpcFailureView = struct {
    method: []const u8,
    request_id: u64,
    code: i64,
    machine_code: ?[]const u8,
    message: []const u8,
    data: ?std.json.Value,
    context: OperationContext,
};

const RpcFailureValidation = union(enum) {
    valid: RpcFailureView,
    invalid: errors.EnvelopeViolation,
};

fn validateRpcFailure(
    method: []const u8,
    request_id: u64,
    context: OperationContext,
    value: std.json.Value,
) RpcFailureValidation {
    const object = switch (value) {
        .object => |object| object,
        else => return .{ .invalid = .invalid_error_object },
    };
    const code = switch (object.get("code") orelse
        return .{ .invalid = .invalid_error_code }) {
        .integer => |number| number,
        else => return .{ .invalid = .invalid_error_code },
    };
    const message = switch (object.get("message") orelse
        return .{ .invalid = .invalid_error_message }) {
        .string => |string| string,
        else => return .{ .invalid = .invalid_error_message },
    };
    const data = object.get("data");
    return .{ .valid = .{
        .method = method,
        .request_id = request_id,
        .code = code,
        .machine_code = rpcMachineCode(data),
        .message = message,
        .data = data,
        .context = context,
    } };
}

fn ownRpcOperationContext(
    allocator: std.mem.Allocator,
    context: OperationContext,
) !errors.RpcOperationContext {
    return switch (context) {
        .generic => .generic,
        .session => |item| .{ .session = .{
            .session_id = try allocator.dupe(u8, item.session_id),
        } },
        .queue => |item| .{ .queue = .{
            .session_id = try allocator.dupe(u8, item.session_id),
        } },
        .permission => |item| permission: {
            const session_id = try allocator.dupe(u8, item.session_id);
            errdefer allocator.free(session_id);
            const request_id = try allocator.dupe(u8, item.request_id);
            break :permission .{ .permission = .{
                .session_id = session_id,
                .request_id = request_id,
            } };
        },
        .tool => |item| tool: {
            const session_id = try allocator.dupe(u8, item.session_id);
            errdefer allocator.free(session_id);
            const request_id = try allocator.dupe(u8, item.request_id);
            errdefer allocator.free(request_id);
            const tool_call_id = try dupeOptional(allocator, item.tool_call_id);
            errdefer if (tool_call_id) |value| allocator.free(value);
            const tool_name = try dupeOptional(allocator, item.tool_name);
            break :tool .{ .tool = .{
                .session_id = session_id,
                .request_id = request_id,
                .tool_call_id = tool_call_id,
                .tool_name = tool_name,
            } };
        },
    };
}

fn ownRpcFailure(
    allocator: std.mem.Allocator,
    view: RpcFailureView,
) !errors.RpcFailure {
    const owned_method = try allocator.dupe(u8, view.method);
    errdefer allocator.free(owned_method);
    const owned_machine_code = if (view.machine_code) |value|
        try allocator.dupe(u8, value)
    else
        null;
    errdefer if (owned_machine_code) |value| allocator.free(value);
    const owned_message = try allocator.dupe(u8, view.message);
    errdefer allocator.free(owned_message);
    const data_json = if (view.data) |value|
        try std.json.Stringify.valueAlloc(allocator, value, .{})
    else
        null;
    errdefer if (data_json) |value| allocator.free(value);
    const context = try ownRpcOperationContext(allocator, view.context);
    return .{
        .method = owned_method,
        .request_id = view.request_id,
        .code = view.code,
        .machine_code = owned_machine_code,
        .message = owned_message,
        .data_json = data_json,
        .context = context,
    };
}

const OperationContext = union(enum) {
    generic,
    session: struct { session_id: []const u8 },
    queue: struct { session_id: []const u8 },
    permission: struct {
        session_id: []const u8,
        request_id: []const u8,
    },
    tool: struct {
        session_id: []const u8,
        request_id: []const u8,
        tool_call_id: ?[]const u8 = null,
        tool_name: ?[]const u8 = null,
    },
};

fn recordRpcFailure(
    allocator: std.mem.Allocator,
    view: RpcFailureView,
) !errors.Failure {
    const rpc = try ownRpcFailure(allocator, view);
    var rpc_transferred = false;
    defer if (!rpc_transferred) {
        var failure = errors.Failure{
            .allocator = allocator,
            .native_error = error.JsonRpcError,
            .detail = .{ .rpc = rpc },
        };
        failure.deinit();
    };

    switch (view.context) {
        .session => |session_context| {
            if (!isMissingSession(view.machine_code, view.message)) {
                rpc_transferred = true;
                return recordFailure(allocator, error.JsonRpcError, .{ .rpc = rpc });
            }
            const owned_session_id = try allocator.dupe(u8, session_context.session_id);
            rpc_transferred = true;
            return recordFailure(allocator, error.JsonRpcError, .{ .session = .{ .not_found = .{
                .session_id = owned_session_id,
                .rpc = rpc,
            } } });
        },
        .queue => |queue_context| {
            _ = queue_context;
            rpc_transferred = true;
            return recordFailure(allocator, error.JsonRpcError, .{ .queue = .{ .rejected = rpc } });
        },
        .permission => |permission_context| {
            _ = permission_context;
            rpc_transferred = true;
            return recordFailure(allocator, error.JsonRpcError, .{
                .permission = .{ .delivery_failed = rpc },
            });
        },
        .tool => |tool_context| {
            _ = tool_context;
            rpc_transferred = true;
            return recordFailure(allocator, error.JsonRpcError, .{
                .tool = .{ .delivery_failed = rpc },
            });
        },
        .generic => {},
    }
    rpc_transferred = true;
    return recordFailure(allocator, error.JsonRpcError, .{ .rpc = rpc });
}

pub const ClientOptions = struct {
    cli_path: []const u8 = "copilot",
    working_directory: ?[]const u8 = null,
    cli_args: []const []const u8 = &.{},
    connection_token: ?[]const u8 = null,
    client_info: ?ClientInfo = null,
};

pub const ClientInfo = struct {
    application_name: ?[]const u8 = null,
    application_version: ?[]const u8 = null,
    integration_name: ?[]const u8 = null,
    integration_version: ?[]const u8 = null,
};

const EventDelivery = struct {
    session_id: []u8,
    payload: Payload,

    const SessionErrorDelivery = struct {
        event: session_types.SessionError,
        diagnostic_frame: []u8,

        fn intoFailure(
            self: *SessionErrorDelivery,
            allocator: std.mem.Allocator,
            owned_session_id: []u8,
        ) errors.DetailedError!errors.Failure {
            const event = self.event;
            const frame = self.diagnostic_frame;
            self.* = undefined;
            defer allocator.free(event.message);
            defer allocator.free(frame);
            return sessionFailureFromFrame(allocator, owned_session_id, frame);
        }
    };

    const Payload = union(enum) {
        assistant_message: session_types.AssistantMessage,
        assistant_message_delta: session_types.AssistantMessageDelta,
        assistant_reasoning: session_types.AssistantReasoning,
        assistant_reasoning_delta: session_types.AssistantReasoningDelta,
        session_idle: session_types.SessionIdle,
        session_error: SessionErrorDelivery,
        permission_requested: session_types.PermissionRequested,
        external_tool_requested: session_types.ExternalToolRequested,
        unknown: session_types.UnknownEvent,

        fn takeEvent(
            self: *Payload,
            allocator: std.mem.Allocator,
        ) session_types.SessionEvent {
            const event: session_types.SessionEvent = switch (self.*) {
                .assistant_message => |value| .{ .assistant_message = value },
                .assistant_message_delta => |value| .{ .assistant_message_delta = value },
                .assistant_reasoning => |value| .{ .assistant_reasoning = value },
                .assistant_reasoning_delta => |value| .{ .assistant_reasoning_delta = value },
                .session_idle => |value| .{ .session_idle = value },
                .session_error => |value| block: {
                    allocator.free(value.diagnostic_frame);
                    break :block .{ .session_error = value.event };
                },
                .permission_requested => |value| .{ .permission_requested = value },
                .external_tool_requested => |value| .{ .external_tool_requested = value },
                .unknown => |value| .{ .unknown = value },
            };
            self.* = undefined;
            return event;
        }

        fn deinit(self: *Payload, allocator: std.mem.Allocator) void {
            var event = self.takeEvent(allocator);
            event.deinit(allocator);
        }
    };

    fn intoEvent(
        self: *EventDelivery,
        allocator: std.mem.Allocator,
    ) session_types.SessionEvent {
        allocator.free(self.session_id);
        const event = self.payload.takeEvent(allocator);
        self.* = undefined;
        return event;
    }

    fn deinit(self: *EventDelivery, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        self.payload.deinit(allocator);
        self.* = undefined;
    }
};

const RegisteredTool = struct {
    session_id: []const u8,
    name: []u8,
    handler: session_types.ToolHandler,
    context: ?*anyopaque,

    fn deinit(self: RegisteredTool, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

const RegisteredUserInputHandler = struct {
    session_id: []const u8,
    handler: session_types.UserInputHandler,
    context: ?*anyopaque,
};

const RegisteredPermissionHandler = struct {
    session_id: []const u8,
    handler: session_types.PermissionHandler,
    managed_settings_enabled: bool,
    context: ?*anyopaque,
};

pub const RpcHandler = *const fn (
    allocator: std.mem.Allocator,
    params_json: ?[]const u8,
    context: ?*anyopaque,
) anyerror![]u8;

const WireModelsListRequest = struct {
    selectionId: ?[]const u8 = null,
    gitHubToken: ?[]const u8 = null,
};

const RegisteredRpcHandler = struct {
    method: []u8,
    handler: RpcHandler,
    context: ?*anyopaque,

    fn deinit(self: RegisteredRpcHandler, allocator: std.mem.Allocator) void {
        allocator.free(self.method);
    }
};

const ShutdownOps = struct {
    context: ?*anyopaque,
    disconnect_session_once: *const fn (?*anyopaque, *Client, []const u8) anyerror!void,
    terminate_child_once: *const fn (?*anyopaque, *Client) anyerror!void,
};

const ShutdownObserver = struct {
    context: *anyopaque,
    record: *const fn (*anyopaque, ?[]const u8, anyerror) void,
};

fn runShutdown(
    client: *Client,
    ops: ShutdownOps,
    observer: ?ShutdownObserver,
) ?anyerror {
    var first_error: ?anyerror = null;
    var index = client.session_ids.items.len;
    while (index > 0) {
        index -= 1;
        const session_id = client.session_ids.items[index];
        ops.disconnect_session_once(ops.context, client, session_id) catch |err| {
            if (first_error == null) first_error = err;
            if (observer) |sink| sink.record(sink.context, session_id, err);
        };
    }
    ops.terminate_child_once(ops.context, client) catch |err| {
        if (first_error == null) first_error = err;
        if (observer) |sink| sink.record(sink.context, null, err);
    };
    return first_error;
}

fn disconnectForShutdown(_: ?*anyopaque, client: *Client, session_id: []const u8) !void {
    return legacyResult(
        void,
        (Session{ .client = client, .id = session_id }).disconnectImpl(.legacy),
    );
}

fn terminateForShutdown(_: ?*anyopaque, client: *Client) !void {
    if (client.child) |*child| child.kill(client.io);
}

const real_shutdown_ops = ShutdownOps{
    .context = null,
    .disconnect_session_once = disconnectForShutdown,
    .terminate_child_once = terminateForShutdown,
};

const ShutdownCollector = struct {
    allocator: std.mem.Allocator,
    storage: []errors.Failure,
    count: usize = 0,
    dropped: usize = 0,

    fn record(context: *anyopaque, session_id: ?[]const u8, native_error: anyerror) void {
        const self: *ShutdownCollector = @ptrCast(@alignCast(context));
        if (self.count == self.storage.len) {
            self.dropped += 1;
            return;
        }
        const detail: errors.FailureDetail = if (session_id) |id| blk: {
            const owned_id = self.allocator.dupe(u8, id) catch |err| switch (err) {
                error.OutOfMemory => {
                    self.dropped += 1;
                    return;
                },
            };
            break :blk .{ .session = .{ .detach_failed = .{
                .session_id = owned_id,
                .attempts = 1,
                .rpc = null,
                .message = null,
            } } };
        } else {
            self.storage[self.count] = recordProcessTerminate(
                self.allocator,
                null,
                native_error,
            ) catch |err| switch (err) {
                error.OutOfMemory => {
                    self.dropped += 1;
                    return;
                },
            };
            self.count += 1;
            return;
        };
        self.storage[self.count] = recordFailure(self.allocator, native_error, detail);
        self.count += 1;
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    child: ?std.process.Child,
    last_exit: ?errors.ProcessExit = null,
    reader: *std.Io.File.Reader,
    writer: *std.Io.File.Writer,
    reader_buffer: []u8,
    writer_buffer: []u8,
    next_request_id: u64 = 1,
    session_ids: std.ArrayList([]u8) = .empty,
    events: std.ArrayList(EventDelivery) = .empty,
    tools: std.ArrayList(RegisteredTool) = .empty,
    user_input_handlers: std.ArrayList(RegisteredUserInputHandler) = .empty,
    permission_handlers: std.ArrayList(RegisteredPermissionHandler) = .empty,
    rpc_handlers: std.ArrayList(RegisteredRpcHandler) = .empty,
    dispatching_rpc_handler: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: ClientOptions,
    ) !Client {
        return legacyResult(Client, initEngine(.legacy, allocator, io, options));
    }

    pub fn initDetailed(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: ClientOptions,
    ) errors.DetailedError!errors.DetailedResult(Client) {
        return initEngine(.detailed, allocator, io, options);
    }

    fn initEngine(
        comptime failure_policy: FailurePolicy,
        allocator: std.mem.Allocator,
        io: std.Io,
        options: ClientOptions,
    ) errors.DetailedError!PolicyResult(failure_policy, Client) {
        var client = spawn(allocator, io, options) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .failure = try policyFailure(
                failure_policy,
                err,
                recordProcessSpawn,
                .{ allocator, options.cli_path, err },
            ) };
        };
        errdefer client.deinit();
        switch (try client.connect(failure_policy, options.connection_token, options.client_info)) {
            .success => return .{ .success = client },
            .failure => |failure| {
                client.deinit();
                return .{ .failure = failure };
            },
        }
    }

    pub fn initParent(allocator: std.mem.Allocator, io: std.Io) !Client {
        return legacyResult(Client, initParentEngine(.legacy, allocator, io));
    }

    pub fn initParentDetailed(
        allocator: std.mem.Allocator,
        io: std.Io,
    ) errors.DetailedError!errors.DetailedResult(Client) {
        return initParentEngine(.detailed, allocator, io);
    }

    fn initParentEngine(
        comptime failure_policy: FailurePolicy,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) errors.DetailedError!PolicyResult(failure_policy, Client) {
        const reader_buffer = try allocator.alloc(u8, 8192);
        errdefer allocator.free(reader_buffer);
        const writer_buffer = try allocator.alloc(u8, 8192);
        errdefer allocator.free(writer_buffer);
        const reader = try allocator.create(std.Io.File.Reader);
        errdefer allocator.destroy(reader);
        const writer = try allocator.create(std.Io.File.Writer);
        errdefer allocator.destroy(writer);

        reader.* = std.Io.File.stdin().readerStreaming(io, reader_buffer);
        writer.* = std.Io.File.stdout().writerStreaming(io, writer_buffer);

        var client = Client{
            .allocator = allocator,
            .io = io,
            .child = null,
            .reader = reader,
            .writer = writer,
            .reader_buffer = reader_buffer,
            .writer_buffer = writer_buffer,
        };
        errdefer client.deinit();
        switch (try client.connect(failure_policy, null, null)) {
            .success => return .{ .success = client },
            .failure => |failure| {
                client.deinit();
                return .{ .failure = failure };
            },
        }
    }

    fn spawn(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: ClientOptions,
    ) !Client {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.appendSlice(allocator, &.{
            options.cli_path,
            "--headless",
            "--stdio",
            "--no-auto-update",
        });
        try argv.appendSlice(allocator, options.cli_args);

        var child = try std.process.spawn(io, .{
            .argv = argv.items,
            .cwd = if (options.working_directory) |cwd| .{ .path = cwd } else .inherit,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        errdefer child.kill(io);

        const reader_buffer = try allocator.alloc(u8, 8192);
        errdefer allocator.free(reader_buffer);
        const writer_buffer = try allocator.alloc(u8, 8192);
        errdefer allocator.free(writer_buffer);
        const reader = try allocator.create(std.Io.File.Reader);
        errdefer allocator.destroy(reader);
        const writer = try allocator.create(std.Io.File.Writer);
        errdefer allocator.destroy(writer);

        reader.* = child.stdout.?.readerStreaming(io, reader_buffer);
        writer.* = child.stdin.?.writerStreaming(io, writer_buffer);

        return .{
            .allocator = allocator,
            .io = io,
            .child = child,
            .reader = reader,
            .writer = writer,
            .reader_buffer = reader_buffer,
            .writer_buffer = writer_buffer,
        };
    }

    pub fn deinit(self: *Client) void {
        for (self.events.items) |*event| event.deinit(self.allocator);
        self.events.deinit(self.allocator);
        for (self.tools.items) |tool| tool.deinit(self.allocator);
        self.tools.deinit(self.allocator);
        self.user_input_handlers.deinit(self.allocator);
        self.permission_handlers.deinit(self.allocator);
        for (self.rpc_handlers.items) |handler| handler.deinit(self.allocator);
        self.rpc_handlers.deinit(self.allocator);
        for (self.session_ids.items) |id| self.allocator.free(id);
        self.session_ids.deinit(self.allocator);
        if (self.child) |*child| child.kill(self.io);
        self.allocator.destroy(self.reader);
        self.allocator.destroy(self.writer);
        self.allocator.free(self.reader_buffer);
        self.allocator.free(self.writer_buffer);
        self.* = undefined;
    }

    pub fn stop(self: *Client) !void {
        if (runShutdown(self, real_shutdown_ops, null)) |err| return err;
    }

    pub fn stopDetailed(self: *Client) errors.DetailedResult(void) {
        return stopDetailedWithOps(self, real_shutdown_ops, self.child != null);
    }

    fn stopDetailedWithOps(
        self: *Client,
        ops: ShutdownOps,
        child_attempted: bool,
    ) errors.DetailedResult(void) {
        const session_count = self.session_ids.items.len;
        const storage: []errors.Failure = self.allocator.alloc(
            errors.Failure,
            session_count + @intFromBool(child_attempted),
        ) catch &.{};
        var collector = ShutdownCollector{
            .allocator = self.allocator,
            .storage = storage,
        };
        const native_error = runShutdown(self, ops, .{
            .context = &collector,
            .record = ShutdownCollector.record,
        }) orelse {
            if (collector.storage.len != 0) self.allocator.free(collector.storage);
            return .{ .success = {} };
        };
        return .{ .failure = .{
            .allocator = self.allocator,
            .native_error = native_error,
            .detail = .{ .shutdown = .{
                .sessions_attempted = session_count,
                .child_termination_attempted = child_attempted,
                .failure_storage = collector.storage,
                .failure_count = collector.count,
                .diagnostics_dropped = collector.dropped,
            } },
        } };
    }

    fn recordReadFailure(
        self: *Client,
        cause: anyerror,
    ) errors.DetailedError!errors.Failure {
        if (cause == error.OutOfMemory) return error.OutOfMemory;
        if (cause == error.EndOfStream) {
            if (self.last_exit) |exit| return recordProcessExit(self.allocator, exit);
            if (self.child) |*child| {
                if (child.id != null) {
                    const term = child.wait(self.io) catch |wait_error|
                        return recordClientIo(self.allocator, .read, wait_error);
                    const exit = processExit(term);
                    self.last_exit = exit;
                    return recordProcessExit(self.allocator, exit);
                }
            }
        }
        return recordClientIo(self.allocator, .read, cause);
    }

    fn connect(
        self: *Client,
        comptime failure_policy: FailurePolicy,
        token: ?[]const u8,
        client_info: ?ClientInfo,
    ) errors.DetailedError!PolicyResult(failure_policy, void) {
        const parsed = switch (try self.callImpl(failure_policy, struct {
            ok: bool,
            protocolVersion: std.json.Value,
            version: []const u8,
        }, "connect", .{
            .token = token,
            .clientInfo = toWireClientInfo(client_info),
        }, .generic)) {
            .success => |value| value,
            .failure => |failure| return .{ .failure = failure },
        };
        defer parsed.deinit();
        if (!parsed.value.ok) return .{ .failure = try policyFailure(
            failure_policy,
            error.ConnectRejected,
            recordConnectRejected,
            .{self.allocator},
        ) };
        const server_version = switch (parsed.value.protocolVersion) {
            .integer => |value| std.math.cast(u64, value) orelse
                return .{ .failure = try policyFailure(
                    failure_policy,
                    error.ProtocolVersionMismatch,
                    recordInvalidProtocolVersion,
                    .{ self.allocator, parsed.value.protocolVersion },
                ) },
            else => return .{ .failure = try policyFailure(
                failure_policy,
                error.ProtocolVersionMismatch,
                recordInvalidProtocolVersion,
                .{ self.allocator, parsed.value.protocolVersion },
            ) },
        };
        if (server_version != protocol.sdk_protocol_version)
            return .{ .failure = try policyFailure(
                failure_policy,
                error.ProtocolVersionMismatch,
                recordProtocolMismatch,
                .{ self.allocator, server_version },
            ) };
        return .{ .success = {} };
    }

    pub fn createSession(
        self: *Client,
        config: session_types.SessionConfig,
    ) !Session {
        return legacyResult(Session, self.createSessionEngine(.legacy, config));
    }

    pub fn createSessionDetailed(
        self: *Client,
        config: session_types.SessionConfig,
    ) errors.DetailedError!errors.DetailedResult(Session) {
        return self.createSessionEngine(.detailed, config);
    }

    fn createSessionEngine(
        self: *Client,
        comptime failure_policy: FailurePolicy,
        config: session_types.SessionConfig,
    ) errors.DetailedError!PolicyResult(failure_policy, Session) {
        var parsed_parameters: std.ArrayList(std.json.Parsed(std.json.Value)) = .empty;
        defer {
            for (parsed_parameters.items) |parsed| parsed.deinit();
            parsed_parameters.deinit(self.allocator);
        }
        var tools: std.ArrayList(WireTool) = .empty;
        defer tools.deinit(self.allocator);
        appendWireTools(self.allocator, config.tools, &parsed_parameters, &tools) catch |err|
            return .{ .failure = try policyFailure(
                failure_policy,
                err,
                recordInvalidConfig,
                .{ self.allocator, "tools", err },
            ) };

        const request = buildCreateSessionRequest(config, tools.items) catch |err|
            return .{ .failure = try policyFailure(
                failure_policy,
                err,
                recordInvalidConfig,
                .{ self.allocator, "session", err },
            ) };
        const context: OperationContext = if (config.session_id) |session_id|
            .{ .session = .{ .session_id = session_id } }
        else
            .generic;
        const parsed = switch (try self.callImpl(
            failure_policy,
            struct { sessionId: []const u8 },
            "session.create",
            request,
            context,
        )) {
            .success => |value| value,
            .failure => |failure| return .{ .failure = failure },
        };
        defer parsed.deinit();

        const id = try self.allocator.dupe(u8, parsed.value.sessionId);
        self.session_ids.append(self.allocator, id) catch |err| {
            self.allocator.free(id);
            return err;
        };
        errdefer self.removeSession(id);
        try self.registerToolHandlers(id, config.tools);
        try self.registerPermissionHandler(id, config);
        try self.registerUserInputHandler(id, config.on_user_input_request, config.user_input_context);
        return .{ .success = .{ .client = self, .id = id } };
    }

    pub fn joinSession(
        self: *Client,
        session_id: []const u8,
        config: session_types.SessionConfig,
    ) !Session {
        return legacyResult(Session, self.joinSessionEngine(.legacy, session_id, config));
    }

    pub fn joinSessionDetailed(
        self: *Client,
        session_id: []const u8,
        config: session_types.SessionConfig,
    ) errors.DetailedError!errors.DetailedResult(Session) {
        return self.joinSessionEngine(.detailed, session_id, config);
    }

    fn joinSessionEngine(
        self: *Client,
        comptime failure_policy: FailurePolicy,
        session_id: []const u8,
        config: session_types.SessionConfig,
    ) errors.DetailedError!PolicyResult(failure_policy, Session) {
        var parsed_parameters: std.ArrayList(std.json.Parsed(std.json.Value)) = .empty;
        defer {
            for (parsed_parameters.items) |parsed| parsed.deinit();
            parsed_parameters.deinit(self.allocator);
        }
        var tools: std.ArrayList(WireTool) = .empty;
        defer tools.deinit(self.allocator);
        appendWireTools(self.allocator, config.tools, &parsed_parameters, &tools) catch |err|
            return .{ .failure = try policyFailure(
                failure_policy,
                err,
                recordInvalidConfig,
                .{ self.allocator, "tools", err },
            ) };

        const request = buildResumeSessionRequest(session_id, config, tools.items) catch |err|
            return .{ .failure = try policyFailure(
                failure_policy,
                err,
                recordInvalidConfig,
                .{ self.allocator, "session", err },
            ) };
        const parsed = switch (try self.callImpl(
            failure_policy,
            std.json.Value,
            "session.resume",
            request,
            .{ .session = .{ .session_id = session_id } },
        )) {
            .success => |value| value,
            .failure => |failure| return .{ .failure = failure },
        };
        parsed.deinit();

        const id = try self.allocator.dupe(u8, session_id);
        self.session_ids.append(self.allocator, id) catch |err| {
            self.allocator.free(id);
            return err;
        };
        errdefer self.removeSession(id);
        try self.registerToolHandlers(id, config.tools);
        try self.registerPermissionHandler(id, config);
        try self.registerUserInputHandler(id, config.on_user_input_request, config.user_input_context);
        return .{ .success = .{ .client = self, .id = id } };
    }

    /// Calls any outbound RPC method from the pinned upstream schema.
    ///
    /// Prefer typed high-level methods when available. The caller owns the
    /// returned parsed result and must call `deinit`.
    pub fn callRpc(
        self: *Client,
        comptime Result: type,
        method: []const u8,
        params: anytype,
    ) !std.json.Parsed(Result) {
        return legacyResult(
            std.json.Parsed(Result),
            self.callImpl(.legacy, Result, method, params, .generic),
        );
    }

    pub fn callRpcDetailed(
        self: *Client,
        comptime Result: type,
        method: []const u8,
        params: anytype,
    ) errors.DetailedError!errors.DetailedResult(std.json.Parsed(Result)) {
        return self.callImpl(.detailed, Result, method, params, .generic);
    }

    /// Lists models available to the authenticated or explicitly selected user.
    pub fn listModels(
        self: *Client,
        options: models.ListOptions,
    ) !std.json.Parsed(models.ModelList) {
        return legacyResult(std.json.Parsed(models.ModelList), self.callImpl(
            .legacy,
            models.ModelList,
            "models.list",
            WireModelsListRequest{
                .selectionId = options.selection_id,
                .gitHubToken = options.github_token,
            },
            .generic,
        ));
    }

    pub fn listModelsDetailed(
        self: *Client,
        options: models.ListOptions,
    ) errors.DetailedError!errors.DetailedResult(std.json.Parsed(models.ModelList)) {
        return self.callImpl(.detailed, models.ModelList, "models.list", WireModelsListRequest{
            .selectionId = options.selection_id,
            .gitHubToken = options.github_token,
        }, .generic);
    }

    /// Registers a synchronous handler for an inbound RPC method.
    pub fn registerRpcHandler(
        self: *Client,
        method: []const u8,
        handler: RpcHandler,
        context: ?*anyopaque,
    ) !void {
        if (method.len == 0) return error.InvalidRpcMethod;
        if (self.findRpcHandler(method) != null) return error.RpcHandlerAlreadyRegistered;
        const owned_method = try self.allocator.dupe(u8, method);
        errdefer self.allocator.free(owned_method);
        try self.rpc_handlers.append(self.allocator, .{
            .method = owned_method,
            .handler = handler,
            .context = context,
        });
    }

    pub fn unregisterRpcHandler(self: *Client, method: []const u8) bool {
        for (self.rpc_handlers.items, 0..) |registered, index| {
            if (std.mem.eql(u8, registered.method, method)) {
                const removed = self.rpc_handlers.orderedRemove(index);
                removed.deinit(self.allocator);
                return true;
            }
        }
        return false;
    }

    fn callImpl(
        self: *Client,
        comptime failure_policy: FailurePolicy,
        comptime Result: type,
        method: []const u8,
        params: anytype,
        context: OperationContext,
    ) errors.DetailedError!PolicyResult(failure_policy, std.json.Parsed(Result)) {
        if (self.dispatching_rpc_handler)
            return .{ .failure = try policyFailure(
                failure_policy,
                error.ReentrantRpcCall,
                recordReentrant,
                .{ self.allocator, method },
            ) };
        const id = self.next_request_id;
        self.next_request_id += 1;

        const request = json_rpc.encodeRequest(self.allocator, id, method, params) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .failure = try policyFailure(
                failure_policy,
                err,
                recordClientJson,
                .{ self.allocator, .write, err },
            ) };
        };
        defer self.allocator.free(request);
        json_rpc.writeFrame(&self.writer.interface, request) catch |err|
            return .{ .failure = try policyFailure(
                failure_policy,
                err,
                recordClientIo,
                .{ self.allocator, .write, err },
            ) };

        while (true) {
            const body = if (comptime failure_policy == .legacy)
                json_rpc.readFrame(self.allocator, &self.reader.interface) catch |err|
                    return .{ .failure = .{ .native_error = err } }
            else switch (try json_rpc.readFrameDetailed(
                self.allocator,
                &self.reader.interface,
            )) {
                .success => |value| value,
                .failure => |failure_value| {
                    var frame_failure = failure_value;
                    if (frame_failure.native_error == error.EndOfStream) {
                        frame_failure.deinit();
                        return .{ .failure = try self.recordReadFailure(error.EndOfStream) };
                    }
                    return .{ .failure = frame_failure };
                },
            };
            var body_owned = true;
            defer if (body_owned) self.allocator.free(body);
            const value = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return .{ .failure = try policyFailure(
                    failure_policy,
                    err,
                    recordInvalidJson,
                    .{ self.allocator, err },
                ) };
            };
            defer value.deinit();
            const inbound = switch (try parseInboundMessage(
                failure_policy,
                self.allocator,
                value.value,
            )) {
                .success => |message| message,
                .failure => |failure| return .{ .failure = failure },
            };
            switch (inbound) {
                .request => |inbound_request| {
                    var operation: errors.ClientOperation = .callback;
                    self.dispatchServerRequest(
                        &self.writer.interface,
                        inbound_request.id,
                        inbound_request.method,
                        inbound_request.params,
                        &operation,
                    ) catch |err| {
                        if (err == error.OutOfMemory) return error.OutOfMemory;
                        return .{ .failure = try policyFailure(
                            failure_policy,
                            err,
                            recordClientIo,
                            .{ self.allocator, operation, err },
                        ) };
                    };
                    continue;
                },
                .notification => |notification| {
                    if (std.mem.eql(u8, notification.method, "session.event")) {
                        switch (try self.queueSessionEvent(
                            failure_policy,
                            body,
                            notification.params orelse
                                return .{ .failure = try policyFailure(
                                    failure_policy,
                                    error.InvalidJsonRpc,
                                    recordInvalidEnvelope,
                                    .{
                                        self.allocator,
                                        error.InvalidJsonRpc,
                                        .missing_params,
                                        value.value,
                                    },
                                ) },
                        )) {
                            .success => |retained| body_owned = !retained,
                            .failure => |failure| return .{ .failure = failure },
                        }
                    }
                    continue;
                },
                .response => |response| {
                    if (response.id != id)
                        return .{ .failure = try policyFailure(
                            failure_policy,
                            error.UnexpectedResponse,
                            recordUnexpectedResponse,
                            .{ self.allocator, id, response.id_value },
                        ) };
                    if (response.rpc_error) |rpc_error| {
                        const rpc_failure = switch (validateRpcFailure(
                            method,
                            id,
                            context,
                            rpc_error,
                        )) {
                            .valid => |failure| failure,
                            .invalid => |reason| return .{ .failure = try policyFailure(
                                failure_policy,
                                envelopeError(reason),
                                recordEnvelope,
                                .{ self.allocator, reason, value.value },
                            ) },
                        };
                        return .{ .failure = try policyFailure(
                            failure_policy,
                            error.JsonRpcError,
                            recordRpcFailure,
                            .{ self.allocator, rpc_failure },
                        ) };
                    }
                    const result = response.result orelse
                        return .{ .failure = try policyFailure(
                            failure_policy,
                            envelopeError(.missing_result_and_error),
                            recordEnvelope,
                            .{ self.allocator, .missing_result_and_error, value.value },
                        ) };
                    const result_json = try std.json.Stringify.valueAlloc(
                        self.allocator,
                        result,
                        .{},
                    );
                    defer self.allocator.free(result_json);
                    const parsed = std.json.parseFromSlice(Result, self.allocator, result_json, .{
                        .allocate = .alloc_always,
                        .ignore_unknown_fields = true,
                    }) catch |err| {
                        if (err == error.OutOfMemory) return error.OutOfMemory;
                        return .{ .failure = try policyFailure(
                            failure_policy,
                            err,
                            recordClientJson,
                            .{ self.allocator, .read, err },
                        ) };
                    };
                    return .{ .success = parsed };
                },
            }
        }
    }

    fn rejectServerRequest(
        self: *Client,
        writer: *std.Io.Writer,
        id: std.json.Value,
    ) !void {
        const response = try json_rpc.encodeErrorResponse(
            self.allocator,
            id,
            -32601,
            "method not found",
        );
        defer self.allocator.free(response);
        try json_rpc.writeFrame(writer, response);
    }

    fn dispatchServerRequest(
        self: *Client,
        writer: *std.Io.Writer,
        id: std.json.Value,
        method: []const u8,
        params: ?std.json.Value,
        failure_operation: *errors.ClientOperation,
    ) !void {
        if (std.mem.eql(u8, method, "userInput.request") and
            self.findUserInputHandlerFromParams(params) != null)
        {
            return self.dispatchUserInputRequest(
                writer,
                id,
                params,
                failure_operation,
            );
        }
        const registered = self.findRpcHandler(method) orelse {
            failure_operation.* = .write;
            try self.rejectServerRequest(writer, id);
            return;
        };
        const params_json = try stringifyRpcParams(self.allocator, params);
        defer if (params_json) |json| self.allocator.free(json);

        self.dispatching_rpc_handler = true;
        defer self.dispatching_rpc_handler = false;
        const result_json = registered.handler(
            self.allocator,
            params_json,
            registered.context,
        ) catch |err| {
            const response = try json_rpc.encodeErrorResponse(
                self.allocator,
                id,
                -32000,
                @errorName(err),
            );
            defer self.allocator.free(response);
            failure_operation.* = .write;
            try json_rpc.writeFrame(writer, response);
            return;
        };
        defer self.allocator.free(result_json);

        const result = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            result_json,
            .{},
        ) catch {
            const response = try json_rpc.encodeErrorResponse(
                self.allocator,
                id,
                -32603,
                "invalid handler result",
            );
            defer self.allocator.free(response);
            failure_operation.* = .write;
            try json_rpc.writeFrame(writer, response);
            return;
        };
        defer result.deinit();
        const response = try json_rpc.encodeSuccessResponse(self.allocator, id, result.value);
        defer self.allocator.free(response);
        failure_operation.* = .write;
        try json_rpc.writeFrame(writer, response);
    }

    fn findRpcHandler(self: *Client, method: []const u8) ?RegisteredRpcHandler {
        for (self.rpc_handlers.items) |registered| {
            if (std.mem.eql(u8, registered.method, method)) return registered;
        }
        return null;
    }

    fn dispatchUserInputRequest(
        self: *Client,
        writer: *std.Io.Writer,
        id: std.json.Value,
        params: ?std.json.Value,
        failure_operation: *errors.ClientOperation,
    ) !void {
        const params_json = try stringifyRpcParams(self.allocator, params) orelse
            {
                failure_operation.* = .write;
                return self.writeServerRequestError(
                    writer,
                    id,
                    -32602,
                    "invalid user input request",
                );
            };
        defer self.allocator.free(params_json);

        const parsed = std.json.parseFromSlice(
            WireUserInputRequest,
            self.allocator,
            params_json,
            .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
        ) catch {
            failure_operation.* = .write;
            return self.writeServerRequestError(writer, id, -32602, "invalid user input request");
        };
        defer parsed.deinit();

        const registered = self.findUserInputHandler(parsed.value.sessionId) orelse
            {
                failure_operation.* = .write;
                return self.writeServerRequestError(
                    writer,
                    id,
                    -32000,
                    "user input handler not registered",
                );
            };

        self.dispatching_rpc_handler = true;
        defer self.dispatching_rpc_handler = false;
        const response = registered.handler(self.allocator, .{
            .session_id = parsed.value.sessionId,
            .question = parsed.value.question,
            .choices = parsed.value.choices,
            .allow_freeform = parsed.value.allowFreeform,
        }, registered.context) catch |err| {
            failure_operation.* = .write;
            return self.writeServerRequestError(writer, id, -32000, @errorName(err));
        };
        defer self.allocator.free(response.answer);

        const result_json = try std.json.Stringify.valueAlloc(self.allocator, .{
            .answer = response.answer,
            .wasFreeform = response.was_freeform,
        }, .{});
        defer self.allocator.free(result_json);
        const result = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            result_json,
            .{},
        );
        defer result.deinit();
        const frame = try json_rpc.encodeSuccessResponse(self.allocator, id, result.value);
        defer self.allocator.free(frame);
        failure_operation.* = .write;
        try json_rpc.writeFrame(writer, frame);
    }

    fn writeServerRequestError(
        self: *Client,
        writer: *std.Io.Writer,
        id: std.json.Value,
        code: i64,
        message: []const u8,
    ) !void {
        const response = try json_rpc.encodeErrorResponse(
            self.allocator,
            id,
            code,
            message,
        );
        defer self.allocator.free(response);
        try json_rpc.writeFrame(writer, response);
    }

    fn sessionAgentWireView(event_value: std.json.Value) SessionEventWireError!?SessionAgentWireView {
        const event_object = switch (event_value) {
            .object => |object| object,
            else => return error.MalformedFieldType,
        };
        const event_type = switch (event_object.get("type") orelse
            return error.MissingField) {
            .string => |value| value,
            else => return error.MalformedFieldType,
        };
        if (!std.mem.eql(u8, event_type, "session.error")) return null;
        const data = switch (event_object.get("data") orelse
            return error.MissingField) {
            .object => |object| object,
            else => return error.MalformedFieldType,
        };
        return .{
            .error_type = try requiredWireString(data, "errorType"),
            .error_code = try optionalWireString(data, "errorCode"),
            .message = try requiredWireString(data, "message"),
            .status_code = try optionalWireStatusCode(data, "statusCode"),
            .provider_call_id = try optionalWireString(data, "providerCallId"),
            .service_request_id = try optionalWireString(data, "serviceRequestId"),
            .remediation = data.get("remediation"),
            .url = try optionalWireString(data, "url"),
            .stack = try optionalWireString(data, "stack"),
            .eligible_for_auto_switch = try optionalWireBool(data, "eligibleForAutoSwitch"),
        };
    }

    fn queueSessionEvent(
        self: *Client,
        comptime failure_policy: FailurePolicy,
        frame: []u8,
        params_value: std.json.Value,
    ) errors.DetailedError!PolicyResult(failure_policy, bool) {
        const params = switch (params_value) {
            .object => |object| object,
            else => return .{ .failure = try policyFailure(
                failure_policy,
                error.InvalidJsonRpc,
                recordInvalidEnvelope,
                .{
                    self.allocator,
                    error.InvalidJsonRpc,
                    .malformed_field_type,
                    params_value,
                },
            ) },
        };
        const session_id_value = params.get("sessionId") orelse
            return .{ .failure = try policyFailure(
                failure_policy,
                error.InvalidJsonRpc,
                recordInvalidEnvelope,
                .{ self.allocator, error.InvalidJsonRpc, .missing_params, params_value },
            ) };
        const session_id = switch (session_id_value) {
            .string => |id| id,
            else => return .{ .failure = try policyFailure(
                failure_policy,
                error.InvalidJsonRpc,
                recordInvalidEnvelope,
                .{
                    self.allocator,
                    error.InvalidJsonRpc,
                    .malformed_field_type,
                    params_value,
                },
            ) },
        };
        if (self.events.items.len >= max_queued_events) {
            const event_type = if (params.get("event")) |event_value| switch (event_value) {
                .object => |event_object| if (event_object.get("type")) |type_value| switch (type_value) {
                    .string => |string| string,
                    else => null,
                } else null,
                else => null,
            } else null;
            return .{ .failure = try policyFailure(
                failure_policy,
                error.EventQueueFull,
                recordQueueFull,
                .{ self.allocator, session_id, event_type, self.events.items.len },
            ) };
        }
        var transferred = false;
        const event_value = params.get("event") orelse
            return .{ .failure = try policyFailure(
                failure_policy,
                error.InvalidJsonRpc,
                recordInvalidEnvelope,
                .{ self.allocator, error.InvalidJsonRpc, .missing_params, params_value },
            ) };
        const agent_view = sessionAgentWireView(event_value) catch |err|
            return .{ .failure = try policyFailure(
                failure_policy,
                error.InvalidSessionEvent,
                recordInvalidEvent,
                .{ self.allocator, sessionEventViolation(err), event_value },
            ) };
        var event = session_types.parseEventClassified(self.allocator, event_value) catch |err| {
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.MissingField, error.MalformedFieldType => return .{
                    .failure = try policyFailure(
                        failure_policy,
                        error.InvalidSessionEvent,
                        recordInvalidEvent,
                        .{
                            self.allocator,
                            if (err == error.MissingField)
                                errors.EnvelopeViolation.missing_params
                            else
                                errors.EnvelopeViolation.malformed_field_type,
                            event_value,
                        },
                    ),
                },
            }
        };
        defer if (!transferred) event.deinit(self.allocator);
        const owned_session_id = try self.allocator.dupe(u8, session_id);
        defer if (!transferred) self.allocator.free(owned_session_id);
        const payload: EventDelivery.Payload = switch (event) {
            .assistant_message => |value| .{ .assistant_message = value },
            .assistant_message_delta => |value| .{ .assistant_message_delta = value },
            .assistant_reasoning => |value| .{ .assistant_reasoning = value },
            .assistant_reasoning_delta => |value| .{ .assistant_reasoning_delta = value },
            .session_idle => |value| .{ .session_idle = value },
            .session_error => |value| .{ .session_error = .{
                .event = value,
                .diagnostic_frame = frame,
            } },
            .permission_requested => |value| .{ .permission_requested = value },
            .external_tool_requested => |value| .{ .external_tool_requested = value },
            .unknown => |value| .{ .unknown = value },
        };
        try self.events.append(self.allocator, .{
            .session_id = owned_session_id,
            .payload = payload,
        });
        transferred = true;
        return .{ .success = agent_view != null };
    }

    fn removeSession(self: *Client, session_id: []const u8) void {
        var index: usize = 0;
        while (index < self.events.items.len) {
            if (std.mem.eql(u8, self.events.items[index].session_id, session_id)) {
                var event = self.events.orderedRemove(index);
                event.deinit(self.allocator);
            } else {
                index += 1;
            }
        }

        var tool_index: usize = 0;
        while (tool_index < self.tools.items.len) {
            if (std.mem.eql(u8, self.tools.items[tool_index].session_id, session_id)) {
                const tool = self.tools.orderedRemove(tool_index);
                tool.deinit(self.allocator);
            } else {
                tool_index += 1;
            }
        }

        var user_input_handler_index: usize = 0;
        while (user_input_handler_index < self.user_input_handlers.items.len) {
            if (std.mem.eql(u8, self.user_input_handlers.items[user_input_handler_index].session_id, session_id)) {
                _ = self.user_input_handlers.orderedRemove(user_input_handler_index);
            } else {
                user_input_handler_index += 1;
            }
        }

        var permission_handler_index: usize = 0;
        while (permission_handler_index < self.permission_handlers.items.len) {
            if (std.mem.eql(u8, self.permission_handlers.items[permission_handler_index].session_id, session_id)) {
                _ = self.permission_handlers.orderedRemove(permission_handler_index);
            } else {
                permission_handler_index += 1;
            }
        }

        for (self.session_ids.items, 0..) |id, session_index| {
            if (std.mem.eql(u8, id, session_id)) {
                self.allocator.free(id);
                _ = self.session_ids.orderedRemove(session_index);
                return;
            }
        }
    }

    fn registerToolHandlers(
        self: *Client,
        session_id: []const u8,
        definitions: []const session_types.Tool,
    ) !void {
        for (definitions) |definition| {
            const handler = definition.handler orelse continue;
            const name = try self.allocator.dupe(u8, definition.name);
            errdefer self.allocator.free(name);
            try self.tools.append(self.allocator, .{
                .session_id = session_id,
                .name = name,
                .handler = handler,
                .context = definition.context,
            });
        }
    }

    fn findToolHandler(
        self: *Client,
        session_id: []const u8,
        name: []const u8,
    ) ?RegisteredTool {
        for (self.tools.items) |tool| {
            if (std.mem.eql(u8, tool.session_id, session_id) and
                std.mem.eql(u8, tool.name, name))
            {
                return tool;
            }
        }
        return null;
    }

    fn registerUserInputHandler(
        self: *Client,
        session_id: []const u8,
        handler: ?session_types.UserInputHandler,
        context: ?*anyopaque,
    ) !void {
        const callback = handler orelse return;
        try self.user_input_handlers.append(self.allocator, .{
            .session_id = session_id,
            .handler = callback,
            .context = context,
        });
    }

    fn registerPermissionHandler(
        self: *Client,
        session_id: []const u8,
        config: session_types.SessionConfig,
    ) !void {
        const callback = config.on_permission_request orelse return;
        try self.permission_handlers.append(self.allocator, .{
            .session_id = session_id,
            .handler = callback,
            .managed_settings_enabled = managedSettingsEnabled(config),
            .context = config.permission_context,
        });
    }

    fn findPermissionHandler(
        self: *Client,
        session_id: []const u8,
    ) ?RegisteredPermissionHandler {
        for (self.permission_handlers.items) |registered| {
            if (std.mem.eql(u8, registered.session_id, session_id)) return registered;
        }
        return null;
    }

    fn findUserInputHandler(
        self: *Client,
        session_id: []const u8,
    ) ?RegisteredUserInputHandler {
        for (self.user_input_handlers.items) |registered| {
            if (std.mem.eql(u8, registered.session_id, session_id)) return registered;
        }
        return null;
    }

    fn findUserInputHandlerFromParams(
        self: *Client,
        params: ?std.json.Value,
    ) ?RegisteredUserInputHandler {
        const object = switch (params orelse return null) {
            .object => |object| object,
            else => return null,
        };
        const session_id = switch (object.get("sessionId") orelse return null) {
            .string => |value| value,
            else => return null,
        };
        return self.findUserInputHandler(session_id);
    }

    fn nextEventImpl(
        self: *Client,
        comptime failure_policy: FailurePolicy,
        session_id: []const u8,
    ) errors.DetailedError!PolicyResult(failure_policy, EventDelivery) {
        while (true) {
            for (self.events.items, 0..) |queued, index| {
                if (std.mem.eql(u8, queued.session_id, session_id)) {
                    return .{ .success = self.events.orderedRemove(index) };
                }
            }

            const body = if (comptime failure_policy == .legacy)
                json_rpc.readFrame(self.allocator, &self.reader.interface) catch |err|
                    return .{ .failure = .{ .native_error = err } }
            else switch (try json_rpc.readFrameDetailed(
                self.allocator,
                &self.reader.interface,
            )) {
                .success => |value| value,
                .failure => |failure_value| {
                    var frame_failure = failure_value;
                    if (frame_failure.native_error == error.EndOfStream) {
                        frame_failure.deinit();
                        return .{ .failure = try self.recordReadFailure(error.EndOfStream) };
                    }
                    return .{ .failure = frame_failure };
                },
            };
            var body_owned = true;
            defer if (body_owned) self.allocator.free(body);
            const value = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return .{ .failure = try policyFailure(
                    failure_policy,
                    err,
                    recordInvalidJson,
                    .{ self.allocator, err },
                ) };
            };
            defer value.deinit();
            const inbound = switch (try parseInboundMessage(
                failure_policy,
                self.allocator,
                value.value,
            )) {
                .success => |message| message,
                .failure => |failure| return .{ .failure = failure },
            };
            switch (inbound) {
                .request => |request| {
                    var operation: errors.ClientOperation = .callback;
                    self.dispatchServerRequest(
                        &self.writer.interface,
                        request.id,
                        request.method,
                        request.params,
                        &operation,
                    ) catch |err| {
                        if (err == error.OutOfMemory) return error.OutOfMemory;
                        return .{ .failure = try policyFailure(
                            failure_policy,
                            err,
                            recordClientIo,
                            .{ self.allocator, operation, err },
                        ) };
                    };
                },
                .notification => |notification| {
                    if (std.mem.eql(u8, notification.method, "session.event")) {
                        switch (try self.queueSessionEvent(
                            failure_policy,
                            body,
                            notification.params orelse
                                return .{ .failure = try policyFailure(
                                    failure_policy,
                                    error.InvalidJsonRpc,
                                    recordInvalidEnvelope,
                                    .{
                                        self.allocator,
                                        error.InvalidJsonRpc,
                                        .missing_params,
                                        value.value,
                                    },
                                ) },
                        )) {
                            .success => |retained| body_owned = !retained,
                            .failure => |failure| return .{ .failure = failure },
                        }
                    }
                },
                .response => |response| return .{ .failure = try policyFailure(
                    failure_policy,
                    error.UnexpectedResponse,
                    recordUnexpectedResponse,
                    .{ self.allocator, 0, response.id_value },
                ) },
            }
        }
    }
};

pub const Session = struct {
    client: *Client,
    id: []const u8,

    pub fn send(
        self: Session,
        options: session_types.MessageOptions,
    ) ![]u8 {
        return legacyResult([]u8, self.sendImpl(.legacy, options));
    }

    pub fn sendDetailed(
        self: Session,
        options: session_types.MessageOptions,
    ) errors.DetailedError!errors.DetailedResult([]u8) {
        return self.sendImpl(.detailed, options);
    }

    fn sendImpl(
        self: Session,
        comptime failure_policy: FailurePolicy,
        options: session_types.MessageOptions,
    ) errors.DetailedError!PolicyResult(failure_policy, []u8) {
        const parsed = switch (try self.client.callImpl(failure_policy, struct { messageId: []const u8 }, "session.send", .{
            .sessionId = self.id,
            .prompt = options.prompt,
        }, .{ .session = .{ .session_id = self.id } })) {
            .success => |value| value,
            .failure => |failure| return .{ .failure = failure },
        };
        defer parsed.deinit();
        return .{ .success = try self.client.allocator.dupe(u8, parsed.value.messageId) };
    }

    pub fn sendAndWait(
        self: Session,
        options: session_types.MessageOptions,
    ) !?session_types.AssistantMessage {
        return legacyResult(
            ?session_types.AssistantMessage,
            self.sendAndWaitImpl(.legacy, options),
        );
    }

    pub fn sendAndWaitDetailed(
        self: Session,
        options: session_types.MessageOptions,
    ) errors.DetailedError!errors.DetailedResult(?session_types.AssistantMessage) {
        return self.sendAndWaitImpl(.detailed, options);
    }

    fn sendAndWaitImpl(
        self: Session,
        comptime failure_policy: FailurePolicy,
        options: session_types.MessageOptions,
    ) errors.DetailedError!PolicyResult(failure_policy, ?session_types.AssistantMessage) {
        const message_id = switch (try self.sendImpl(failure_policy, options)) {
            .success => |value| value,
            .failure => |failure| return .{ .failure = failure },
        };
        defer self.client.allocator.free(message_id);

        var response: ?session_types.AssistantMessage = null;
        var response_owned = true;
        defer if (response_owned) {
            if (response) |message| message.deinit(self.client.allocator);
        };

        while (true) {
            var delivery = switch (try self.nextEventDeliveryImpl(failure_policy)) {
                .success => |value| value,
                .failure => |failure| return .{ .failure = failure },
            };
            var delivery_owned = true;
            defer if (delivery_owned) delivery.deinit(self.client.allocator);
            switch (delivery.payload) {
                .assistant_message => |*message| {
                    if (response) |previous| previous.deinit(self.client.allocator);
                    response = message.*;
                    delivery.payload = .{ .session_idle = .{} };
                },
                .session_idle => |idle| {
                    if (completesSendAndWait(idle)) {
                        response_owned = false;
                        return .{ .success = response };
                    }
                },
                .session_error => |*session_error| {
                    if (comptime failure_policy == .detailed) {
                        delivery_owned = false;
                        return .{ .failure = try session_error.intoFailure(
                            self.client.allocator,
                            delivery.session_id,
                        ) };
                    }
                    return .{ .failure = .{ .native_error = error.CopilotSessionError } };
                },
                else => {},
            }
        }
    }

    pub fn nextEvent(self: Session) !session_types.SessionEvent {
        return switch (try self.nextEventDeliveryImpl(.legacy)) {
            .success => |delivery_value| {
                var delivery = delivery_value;
                return delivery.intoEvent(self.client.allocator);
            },
            .failure => |failure| failure.native_error,
        };
    }

    pub fn nextEventDetailed(
        self: Session,
    ) errors.DetailedError!errors.DetailedResult(session_types.SessionEvent) {
        return switch (try self.nextEventDeliveryImpl(.detailed)) {
            .success => |delivery_value| {
                var delivery = delivery_value;
                switch (delivery.payload) {
                    .session_error => |*session_error| return .{ .failure = try session_error.intoFailure(
                        self.client.allocator,
                        delivery.session_id,
                    ) },
                    else => return .{ .success = delivery.intoEvent(self.client.allocator) },
                }
            },
            .failure => |failure| .{ .failure = failure },
        };
    }

    fn nextEventDeliveryImpl(
        self: Session,
        comptime failure_policy: FailurePolicy,
    ) errors.DetailedError!PolicyResult(failure_policy, EventDelivery) {
        var delivery = switch (try self.client.nextEventImpl(failure_policy, self.id)) {
            .success => |value| value,
            .failure => |failure| return .{ .failure = failure },
        };
        var delivery_owned = true;
        defer if (delivery_owned) delivery.deinit(self.client.allocator);
        if (delivery.payload == .external_tool_requested) {
            const request = delivery.payload.external_tool_requested;
            if (self.client.findToolHandler(self.id, request.tool_name)) |tool| {
                const result = tool.handler(
                    self.client.allocator,
                    request.arguments_json,
                    tool.context,
                ) catch |err| {
                    const delivered = try self.respondToToolErrorImpl(
                        failure_policy,
                        request.request_id,
                        @errorName(err),
                        request.tool_call_id,
                        request.tool_name,
                    );
                    switch (delivered) {
                        .failure => |failure| return .{ .failure = failure },
                        .success => {
                            if (comptime failure_policy == .detailed) {
                                return .{ .failure = try recordToolHandlerFailure(
                                    self.client.allocator,
                                    self.id,
                                    request.request_id,
                                    request.tool_call_id,
                                    request.tool_name,
                                    err,
                                ) };
                            }
                            delivery_owned = false;
                            return .{ .success = delivery };
                        },
                    }
                };
                defer self.client.allocator.free(result);
                switch (try self.respondToToolImpl(
                    failure_policy,
                    request.request_id,
                    result,
                    request.tool_call_id,
                    request.tool_name,
                )) {
                    .success => {},
                    .failure => |failure| return .{ .failure = failure },
                }
            }
        }
        if (delivery.payload == .permission_requested) {
            const request = delivery.payload.permission_requested;
            if (self.client.findPermissionHandler(self.id)) |handler| {
                const decision = handler.handler(
                    request,
                    .{
                        .session_id = self.id,
                        .managed_settings_enabled = handler.managed_settings_enabled,
                    },
                    handler.context,
                ) catch |err| {
                    if (comptime failure_policy == .legacy) {
                        delivery.payload.permission_requested.automatic_handling =
                            .{ .handler_failed = err };
                        delivery_owned = false;
                        return .{ .success = delivery };
                    }
                    return .{ .failure = try recordPermissionHandlerFailure(
                        self.client.allocator,
                        self.id,
                        request.request_id,
                        err,
                    ) };
                };
                switch (decision) {
                    .approve_once => switch (try self.approvePermissionImpl(
                        failure_policy,
                        request.request_id,
                    )) {
                        .success => {},
                        .failure => |failure_value| {
                            if (comptime failure_policy == .legacy) {
                                delivery.payload.permission_requested.automatic_handling =
                                    .{ .delivery_failed = failure_value.native_error };
                                delivery_owned = false;
                                return .{ .success = delivery };
                            }
                            return .{ .failure = failure_value };
                        },
                    },
                    .reject => |feedback| switch (try self.rejectPermissionImpl(
                        failure_policy,
                        request.request_id,
                        feedback,
                    )) {
                        .success => {},
                        .failure => |failure_value| {
                            if (comptime failure_policy == .legacy) {
                                delivery.payload.permission_requested.automatic_handling =
                                    .{ .delivery_failed = failure_value.native_error };
                                delivery_owned = false;
                                return .{ .success = delivery };
                            }
                            return .{ .failure = failure_value };
                        },
                    },
                    .json => |decision_json| switch (try self.respondToPermissionJsonImpl(
                        failure_policy,
                        request.request_id,
                        decision_json,
                        null,
                    )) {
                        .success => {},
                        .failure => |failure_value| {
                            if (comptime failure_policy == .legacy) {
                                delivery.payload.permission_requested.automatic_handling =
                                    .{ .delivery_failed = failure_value.native_error };
                                delivery_owned = false;
                                return .{ .success = delivery };
                            }
                            return .{ .failure = failure_value };
                        },
                    },
                    .no_result => {
                        delivery.payload.permission_requested.automatic_handling = .no_result;
                        delivery_owned = false;
                        return .{ .success = delivery };
                    },
                }
                delivery.payload.permission_requested.automatic_handling = .handled;
            }
        }
        delivery_owned = false;
        return .{ .success = delivery };
    }

    pub fn disconnect(self: Session) !void {
        return legacyResult(void, self.disconnectImpl(.legacy));
    }

    pub fn disconnectDetailed(
        self: Session,
    ) errors.DetailedError!errors.DetailedResult(void) {
        return self.disconnectImpl(.detailed);
    }

    fn disconnectImpl(
        self: Session,
        comptime failure_policy: FailurePolicy,
    ) errors.DetailedError!PolicyResult(failure_policy, void) {
        for (0..2) |_| {
            const parsed = switch (try self.client.callImpl(failure_policy, struct {
                success: bool,
                @"error": ?[]const u8 = null,
            }, "session.detach", .{
                .sessionId = self.id,
            }, .{ .session = .{ .session_id = self.id } })) {
                .success => |value| value,
                .failure => |failure| return .{ .failure = failure },
            };
            defer parsed.deinit();
            if (parsed.value.success) {
                self.client.removeSession(self.id);
                return .{ .success = {} };
            }
        }
        return .{ .failure = try policyFailure(
            failure_policy,
            error.SessionDetachFailed,
            recordDetachFailure,
            .{ self.client.allocator, self.id, 2 },
        ) };
    }

    pub fn setAutoTier(
        self: Session,
        auto_tier: ?session_types.AutoTier,
    ) !session_types.AutoTierSwitchResult {
        return legacyResult(
            session_types.AutoTierSwitchResult,
            self.setAutoTierImpl(.legacy, auto_tier),
        );
    }

    pub fn setAutoTierDetailed(
        self: Session,
        auto_tier: ?session_types.AutoTier,
    ) errors.DetailedError!errors.DetailedResult(session_types.AutoTierSwitchResult) {
        return self.setAutoTierImpl(.detailed, auto_tier);
    }

    fn setAutoTierImpl(
        self: Session,
        comptime failure_policy: FailurePolicy,
        auto_tier: ?session_types.AutoTier,
    ) errors.DetailedError!PolicyResult(failure_policy, session_types.AutoTierSwitchResult) {
        const parsed = switch (try self.client.callImpl(
            failure_policy,
            session_types.AutoTierSwitchResult,
            "session.model.switchAutoTier",
            .{
                .sessionId = self.id,
                .autoTier = if (auto_tier) |tier|
                    std.json.Value{ .string = @tagName(tier) }
                else
                    std.json.Value.null,
            },
            .{ .session = .{ .session_id = self.id } },
        )) {
            .success => |value| value,
            .failure => |failure| return .{ .failure = failure },
        };
        defer parsed.deinit();
        return .{ .success = parsed.value };
    }

    /// Aborts the current agent turn. The caller owns the returned result.
    pub fn abort(self: Session) !std.json.Parsed(session_types.AbortResult) {
        return legacyResult(
            std.json.Parsed(session_types.AbortResult),
            self.client.callImpl(.legacy, session_types.AbortResult, "session.abort", .{
                .sessionId = self.id,
            }, .{ .session = .{ .session_id = self.id } }),
        );
    }

    pub fn abortDetailed(
        self: Session,
    ) errors.DetailedError!errors.DetailedResult(std.json.Parsed(session_types.AbortResult)) {
        return self.client.callImpl(.detailed, session_types.AbortResult, "session.abort", .{
            .sessionId = self.id,
        }, .{ .session = .{ .session_id = self.id } });
    }

    /// Changes the selected model for subsequent turns. The caller owns the
    /// returned result.
    pub fn setModel(
        self: Session,
        model_id: []const u8,
        options: session_types.ModelSwitchOptions,
    ) !std.json.Parsed(session_types.ModelSwitchResult) {
        return legacyResult(std.json.Parsed(session_types.ModelSwitchResult), self.setModelImpl(
            .legacy,
            model_id,
            options,
        ));
    }

    pub fn setModelDetailed(
        self: Session,
        model_id: []const u8,
        options: session_types.ModelSwitchOptions,
    ) errors.DetailedError!errors.DetailedResult(std.json.Parsed(session_types.ModelSwitchResult)) {
        return self.setModelImpl(.detailed, model_id, options);
    }

    fn setModelImpl(
        self: Session,
        comptime failure_policy: FailurePolicy,
        model_id: []const u8,
        options: session_types.ModelSwitchOptions,
    ) errors.DetailedError!PolicyResult(
        failure_policy,
        std.json.Parsed(session_types.ModelSwitchResult),
    ) {
        return self.client.callImpl(
            failure_policy,
            session_types.ModelSwitchResult,
            "session.model.switchTo",
            WireModelSwitchRequest{
                .sessionId = self.id,
                .modelId = model_id,
                .autoTier = options.auto_tier,
                .reasoningEffort = options.reasoning_effort,
                .reasoningSummary = options.reasoning_summary,
                .contextTier = options.context_tier,
                .compactionDecision = options.compaction_decision,
                .runCompactionPreflight = options.run_compaction_preflight,
            },
            .{ .session = .{ .session_id = self.id } },
        );
    }

    /// Emits a user-visible timeline entry and returns its event ID.
    pub fn log(
        self: Session,
        message: []const u8,
        options: session_types.LogOptions,
    ) ![]u8 {
        return legacyResult([]u8, self.logImpl(.legacy, message, options));
    }

    pub fn logDetailed(
        self: Session,
        message: []const u8,
        options: session_types.LogOptions,
    ) errors.DetailedError!errors.DetailedResult([]u8) {
        return self.logImpl(.detailed, message, options);
    }

    fn logImpl(
        self: Session,
        comptime failure_policy: FailurePolicy,
        message: []const u8,
        options: session_types.LogOptions,
    ) errors.DetailedError!PolicyResult(failure_policy, []u8) {
        const parsed = switch (try self.client.callImpl(failure_policy, struct { eventId: []const u8 }, "session.log", WireLogRequest{
            .sessionId = self.id,
            .message = message,
            .level = options.level,
            .type = options.log_type,
            .ephemeral = options.ephemeral,
            .url = options.url,
            .tip = options.tip,
        }, .{ .session = .{ .session_id = self.id } })) {
            .success => |value| value,
            .failure => |failure| return .{ .failure = failure },
        };
        defer parsed.deinit();
        return .{ .success = try self.client.allocator.dupe(u8, parsed.value.eventId) };
    }

    pub fn approvePermission(
        self: Session,
        request_id: []const u8,
    ) !void {
        return legacyResult(void, self.approvePermissionImpl(.legacy, request_id));
    }

    pub fn approvePermissionDetailed(
        self: Session,
        request_id: []const u8,
    ) errors.DetailedError!errors.DetailedResult(void) {
        return self.approvePermissionImpl(.detailed, request_id);
    }

    fn approvePermissionImpl(
        self: Session,
        comptime failure_policy: FailurePolicy,
        request_id: []const u8,
    ) errors.DetailedError!PolicyResult(failure_policy, void) {
        const parsed = switch (try self.client.callImpl(failure_policy, RpcSuccess, "session.permissions.handlePendingPermissionRequest", .{
            .sessionId = self.id,
            .requestId = request_id,
            .result = .{ .kind = "approve-once" },
        }, .{ .permission = .{
            .session_id = self.id,
            .request_id = request_id,
        } })) {
            .success => |value| value,
            .failure => |failure| return .{ .failure = failure },
        };
        defer parsed.deinit();
        if (!parsed.value.success)
            return .{ .failure = try policyFailure(
                failure_policy,
                error.PermissionDecisionNotAccepted,
                recordPermissionNotAccepted,
                .{ self.client.allocator, self.id, request_id },
            ) };
        return .{ .success = {} };
    }

    pub fn rejectPermission(
        self: Session,
        request_id: []const u8,
        feedback: ?[]const u8,
    ) !void {
        return legacyResult(void, self.rejectPermissionImpl(.legacy, request_id, feedback));
    }

    pub fn rejectPermissionDetailed(
        self: Session,
        request_id: []const u8,
        feedback: ?[]const u8,
    ) errors.DetailedError!errors.DetailedResult(void) {
        return self.rejectPermissionImpl(.detailed, request_id, feedback);
    }

    fn rejectPermissionImpl(
        self: Session,
        comptime failure_policy: FailurePolicy,
        request_id: []const u8,
        feedback: ?[]const u8,
    ) errors.DetailedError!PolicyResult(failure_policy, void) {
        const parsed = switch (try self.client.callImpl(failure_policy, RpcSuccess, "session.permissions.handlePendingPermissionRequest", .{
            .sessionId = self.id,
            .requestId = request_id,
            .result = .{ .kind = "reject", .feedback = feedback },
        }, .{ .permission = .{
            .session_id = self.id,
            .request_id = request_id,
        } })) {
            .success => |value| value,
            .failure => |failure| return .{ .failure = failure },
        };
        defer parsed.deinit();
        if (!parsed.value.success)
            return .{ .failure = try policyFailure(
                failure_policy,
                error.PermissionDecisionNotAccepted,
                recordPermissionNotAccepted,
                .{ self.client.allocator, self.id, request_id },
            ) };
        return .{ .success = {} };
    }

    pub fn respondToPermissionJson(
        self: Session,
        request_id: []const u8,
        decision_json: []const u8,
        decision_context_json: ?[]const u8,
    ) !void {
        return legacyResult(void, self.respondToPermissionJsonImpl(
            .legacy,
            request_id,
            decision_json,
            decision_context_json,
        ));
    }

    pub fn respondToPermissionJsonDetailed(
        self: Session,
        request_id: []const u8,
        decision_json: []const u8,
        decision_context_json: ?[]const u8,
    ) errors.DetailedError!errors.DetailedResult(void) {
        return self.respondToPermissionJsonImpl(
            .detailed,
            request_id,
            decision_json,
            decision_context_json,
        );
    }

    fn respondToPermissionJsonImpl(
        self: Session,
        comptime failure_policy: FailurePolicy,
        request_id: []const u8,
        decision_json: []const u8,
        decision_context_json: ?[]const u8,
    ) errors.DetailedError!PolicyResult(failure_policy, void) {
        const decision = std.json.parseFromSlice(
            std.json.Value,
            self.client.allocator,
            decision_json,
            .{},
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .failure = try policyFailure(
                failure_policy,
                err,
                recordInvalidPermission,
                .{ self.client.allocator, self.id, request_id, err },
            ) };
        };
        defer decision.deinit();
        if (decision.value != .object)
            return .{ .failure = try policyFailure(
                failure_policy,
                error.InvalidPermissionDecision,
                recordInvalidPermission,
                .{ self.client.allocator, self.id, request_id, error.InvalidPermissionDecision },
            ) };

        const decision_context = if (decision_context_json) |context_json|
            std.json.parseFromSlice(
                std.json.Value,
                self.client.allocator,
                context_json,
                .{},
            ) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return .{ .failure = try policyFailure(
                    failure_policy,
                    err,
                    recordInvalidPermission,
                    .{ self.client.allocator, self.id, request_id, err },
                ) };
            }
        else
            null;
        defer if (decision_context) |context| context.deinit();
        if (decision_context) |context| {
            if (context.value != .object)
                return .{ .failure = try policyFailure(
                    failure_policy,
                    error.InvalidPermissionDecisionContext,
                    recordInvalidPermission,
                    .{ self.client.allocator, self.id, request_id, error.InvalidPermissionDecisionContext },
                ) };
        }

        const parsed_result = if (decision_context) |context|
            try self.client.callImpl(
                failure_policy,
                RpcSuccess,
                "session.permissions.handlePendingPermissionRequest",
                .{
                    .sessionId = self.id,
                    .requestId = request_id,
                    .result = decision.value,
                    .decisionContext = context.value,
                },
                .{ .permission = .{
                    .session_id = self.id,
                    .request_id = request_id,
                } },
            )
        else
            try self.client.callImpl(
                failure_policy,
                RpcSuccess,
                "session.permissions.handlePendingPermissionRequest",
                .{
                    .sessionId = self.id,
                    .requestId = request_id,
                    .result = decision.value,
                },
                .{ .permission = .{
                    .session_id = self.id,
                    .request_id = request_id,
                } },
            );
        const parsed = switch (parsed_result) {
            .success => |value| value,
            .failure => |failure| return .{ .failure = failure },
        };
        defer parsed.deinit();
        if (!parsed.value.success)
            return .{ .failure = try policyFailure(
                failure_policy,
                error.PermissionDecisionNotAccepted,
                recordPermissionNotAccepted,
                .{ self.client.allocator, self.id, request_id },
            ) };
        return .{ .success = {} };
    }

    pub fn respondToTool(
        self: Session,
        request_id: []const u8,
        result: []const u8,
    ) !void {
        return legacyResult(void, self.respondToToolImpl(
            .legacy,
            request_id,
            result,
            null,
            null,
        ));
    }

    pub fn respondToToolDetailed(
        self: Session,
        request_id: []const u8,
        result: []const u8,
    ) errors.DetailedError!errors.DetailedResult(void) {
        return self.respondToToolImpl(.detailed, request_id, result, null, null);
    }

    fn respondToToolImpl(
        self: Session,
        comptime failure_policy: FailurePolicy,
        request_id: []const u8,
        result: []const u8,
        tool_call_id: ?[]const u8,
        tool_name: ?[]const u8,
    ) errors.DetailedError!PolicyResult(failure_policy, void) {
        const parsed = switch (try self.client.callImpl(failure_policy, struct { success: bool }, "session.tools.handlePendingToolCall", .{
            .sessionId = self.id,
            .requestId = request_id,
            .result = result,
        }, .{ .tool = .{
            .session_id = self.id,
            .request_id = request_id,
            .tool_call_id = tool_call_id,
            .tool_name = tool_name,
        } })) {
            .success => |value| value,
            .failure => |failure| return .{ .failure = failure },
        };
        defer parsed.deinit();
        if (!parsed.value.success)
            return .{ .failure = try policyFailure(
                failure_policy,
                error.ToolResultNotAccepted,
                recordToolNotAccepted,
                .{ self.client.allocator, self.id, request_id },
            ) };
        return .{ .success = {} };
    }

    pub fn respondToToolResultJson(
        self: Session,
        request_id: []const u8,
        result_json: []const u8,
    ) !void {
        return legacyResult(void, self.respondToToolResultJsonImpl(
            .legacy,
            request_id,
            result_json,
        ));
    }

    pub fn respondToToolResultJsonDetailed(
        self: Session,
        request_id: []const u8,
        result_json: []const u8,
    ) errors.DetailedError!errors.DetailedResult(void) {
        return self.respondToToolResultJsonImpl(.detailed, request_id, result_json);
    }

    fn respondToToolResultJsonImpl(
        self: Session,
        comptime failure_policy: FailurePolicy,
        request_id: []const u8,
        result_json: []const u8,
    ) errors.DetailedError!PolicyResult(failure_policy, void) {
        const result = std.json.parseFromSlice(
            std.json.Value,
            self.client.allocator,
            result_json,
            .{},
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .failure = try policyFailure(
                failure_policy,
                err,
                recordInvalidToolResult,
                .{ self.client.allocator, self.id, request_id, err },
            ) };
        };
        defer result.deinit();
        const object = switch (result.value) {
            .object => |object| object,
            else => return .{ .failure = try policyFailure(
                failure_policy,
                error.InvalidToolResult,
                recordInvalidToolResult,
                .{ self.client.allocator, self.id, request_id, error.InvalidToolResult },
            ) },
        };
        const text = object.get("textResultForLlm") orelse
            return .{ .failure = try policyFailure(
                failure_policy,
                error.InvalidToolResult,
                recordInvalidToolResult,
                .{ self.client.allocator, self.id, request_id, error.InvalidToolResult },
            ) };
        if (text != .string)
            return .{ .failure = try policyFailure(
                failure_policy,
                error.InvalidToolResult,
                recordInvalidToolResult,
                .{ self.client.allocator, self.id, request_id, error.InvalidToolResult },
            ) };

        const parsed = switch (try self.client.callImpl(
            failure_policy,
            struct { success: bool },
            "session.tools.handlePendingToolCall",
            .{
                .sessionId = self.id,
                .requestId = request_id,
                .result = result.value,
            },
            .{ .tool = .{
                .session_id = self.id,
                .request_id = request_id,
            } },
        )) {
            .success => |value| value,
            .failure => |failure| return .{ .failure = failure },
        };
        defer parsed.deinit();
        if (!parsed.value.success)
            return .{ .failure = try policyFailure(
                failure_policy,
                error.ToolResultNotAccepted,
                recordToolNotAccepted,
                .{ self.client.allocator, self.id, request_id },
            ) };
        return .{ .success = {} };
    }

    pub fn respondToToolError(
        self: Session,
        request_id: []const u8,
        message: []const u8,
    ) !void {
        return legacyResult(void, self.respondToToolErrorImpl(
            .legacy,
            request_id,
            message,
            null,
            null,
        ));
    }

    pub fn respondToToolErrorDetailed(
        self: Session,
        request_id: []const u8,
        message: []const u8,
    ) errors.DetailedError!errors.DetailedResult(void) {
        return self.respondToToolErrorImpl(.detailed, request_id, message, null, null);
    }

    fn respondToToolErrorImpl(
        self: Session,
        comptime failure_policy: FailurePolicy,
        request_id: []const u8,
        message: []const u8,
        tool_call_id: ?[]const u8,
        tool_name: ?[]const u8,
    ) errors.DetailedError!PolicyResult(failure_policy, void) {
        const parsed = switch (try self.client.callImpl(failure_policy, struct { success: bool }, "session.tools.handlePendingToolCall", .{
            .sessionId = self.id,
            .requestId = request_id,
            .@"error" = message,
        }, .{ .tool = .{
            .session_id = self.id,
            .request_id = request_id,
            .tool_call_id = tool_call_id,
            .tool_name = tool_name,
        } })) {
            .success => |value| value,
            .failure => |failure| return .{ .failure = failure },
        };
        defer parsed.deinit();
        if (!parsed.value.success)
            return .{ .failure = try policyFailure(
                failure_policy,
                error.ToolResultNotAccepted,
                recordToolNotAccepted,
                .{ self.client.allocator, self.id, request_id },
            ) };
        return .{ .success = {} };
    }
};

fn stringifyRpcParams(
    allocator: std.mem.Allocator,
    params: ?std.json.Value,
) !?[]u8 {
    const value = params orelse return null;
    return @as(?[]u8, try std.json.Stringify.valueAlloc(allocator, value, .{}));
}

fn completesSendAndWait(idle: session_types.SessionIdle) bool {
    return idle.mode == null or !std.mem.eql(u8, idle.mode.?, "autopilot");
}

const WireTool = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.json.Value,
    overridesBuiltInTool: bool,
    skipPermission: bool,
    @"defer": session_types.ToolLoading,
    metadata: ?std.json.Value,
    isTerminal: bool,
};

const WireModelSwitchRequest = struct {
    sessionId: []const u8,
    modelId: []const u8,
    autoTier: ?session_types.AutoTier = null,
    reasoningEffort: ?[]const u8 = null,
    reasoningSummary: ?session_types.ReasoningSummary = null,
    contextTier: ?session_types.ContextTier = null,
    compactionDecision: ?[]const u8 = null,
    runCompactionPreflight: ?bool = null,
};

const WireLogRequest = struct {
    sessionId: []const u8,
    message: []const u8,
    level: session_types.LogLevel,
    type: ?[]const u8,
    ephemeral: bool,
    url: ?[]const u8,
    tip: ?[]const u8,
};

const WireUserInputRequest = struct {
    sessionId: []const u8,
    question: []const u8,
    choices: ?[]const []const u8 = null,
    allowFreeform: ?bool = null,
};

const WireManagedSettingsPermissions = struct {
    disableBypassPermissionsMode: ?[]const u8 = null,
    deny: ?[]const []const u8 = null,
    ask: ?[]const []const u8 = null,
    allow: ?[]const []const u8 = null,
};

const WireManagedSettings = struct {
    permissions: ?WireManagedSettingsPermissions = null,
};

const CreateSessionRequest = struct {
    sessionId: ?[]const u8,
    model: ?[]const u8,
    provider: ?provider.WireProvider,
    modelCapabilities: ?models.CapabilitiesOverride,
    workingDirectory: ?[]const u8,
    streaming: bool,
    tools: []const WireTool,
    availableTools: ?[]const []const u8,
    excludedTools: ?[]const []const u8,
    toolFilterPrecedence: ToolFilterPrecedence = .excluded,
    systemMessage: ?session_types.SystemMessageConfig,
    requestPermission: bool,
    requestUserInput: bool,
    enableConfigDiscovery: ?bool,
    skillDirectories: ?[]const []const u8,
    enableSkills: ?bool,
    instructionDirectories: ?[]const []const u8,
    skipCustomInstructions: ?bool,
    enableOnDemandInstructionDiscovery: ?bool,
    enableManagedSettings: bool,
    managedSettings: ?WireManagedSettings,
};

const ResumeSessionRequest = struct {
    sessionId: []const u8,
    model: ?[]const u8,
    provider: ?provider.WireProvider,
    modelCapabilities: ?models.CapabilitiesOverride,
    workingDirectory: ?[]const u8,
    streaming: bool,
    tools: []const WireTool,
    availableTools: ?[]const []const u8,
    excludedTools: ?[]const []const u8,
    toolFilterPrecedence: ToolFilterPrecedence = .excluded,
    systemMessage: ?session_types.SystemMessageConfig,
    requestPermission: bool,
    requestUserInput: bool,
    enableConfigDiscovery: ?bool,
    skillDirectories: ?[]const []const u8,
    enableSkills: ?bool,
    instructionDirectories: ?[]const []const u8,
    skipCustomInstructions: ?bool,
    enableOnDemandInstructionDiscovery: ?bool,
    enableManagedSettings: bool,
    managedSettings: ?WireManagedSettings,
    disableResume: bool = true,
};

const ToolFilterPrecedence = enum {
    available,
    excluded,
};

fn managedSettingsEnabled(config: session_types.SessionConfig) bool {
    return config.enable_managed_settings or config.managed_settings != null;
}

fn lowerManagedSettings(
    settings: ?session_types.ManagedSettings,
) ?WireManagedSettings {
    const value = settings orelse return null;
    return .{
        .permissions = if (value.permissions) |permissions| .{
            .disableBypassPermissionsMode = permissions.disable_bypass_permissions_mode,
            .deny = permissions.deny,
            .ask = permissions.ask,
            .allow = permissions.allow,
        } else null,
    };
}

fn lowerModelCapabilities(
    capabilities: ?models.CapabilitiesOverride,
) !?models.CapabilitiesOverride {
    const value = capabilities orelse return null;
    const limits = value.limits orelse return value;
    const vision = limits.vision orelse return value;
    if (vision.max_prompt_images == 0) return error.InvalidMaxPromptImages;
    return value;
}

fn buildCreateSessionRequest(
    config: session_types.SessionConfig,
    tools: []const WireTool,
) !CreateSessionRequest {
    return .{
        .sessionId = config.session_id,
        .model = config.model,
        .provider = if (config.provider) |value| try provider.lower(value) else null,
        .modelCapabilities = try lowerModelCapabilities(config.model_capabilities),
        .workingDirectory = config.working_directory,
        .streaming = config.streaming,
        .tools = tools,
        .availableTools = config.available_tools,
        .excludedTools = config.excluded_tools,
        .systemMessage = config.system_message,
        .requestPermission = config.request_permission or config.on_permission_request != null,
        .requestUserInput = config.on_user_input_request != null,
        .enableConfigDiscovery = config.enable_config_discovery,
        .skillDirectories = config.skill_directories,
        .enableSkills = config.enable_skills,
        .instructionDirectories = config.instruction_directories,
        .skipCustomInstructions = config.skip_custom_instructions,
        .enableOnDemandInstructionDiscovery = config.enable_on_demand_instruction_discovery,
        .enableManagedSettings = config.enable_managed_settings,
        .managedSettings = lowerManagedSettings(config.managed_settings),
    };
}

fn buildResumeSessionRequest(
    session_id: []const u8,
    config: session_types.SessionConfig,
    tools: []const WireTool,
) !ResumeSessionRequest {
    return .{
        .sessionId = session_id,
        .model = config.model,
        .provider = if (config.provider) |value| try provider.lower(value) else null,
        .modelCapabilities = try lowerModelCapabilities(config.model_capabilities),
        .workingDirectory = config.working_directory,
        .streaming = config.streaming,
        .tools = tools,
        .availableTools = config.available_tools,
        .excludedTools = config.excluded_tools,
        .systemMessage = config.system_message,
        .requestPermission = config.request_permission or config.on_permission_request != null,
        .requestUserInput = config.on_user_input_request != null,
        .enableConfigDiscovery = config.enable_config_discovery,
        .skillDirectories = config.skill_directories,
        .enableSkills = config.enable_skills,
        .instructionDirectories = config.instruction_directories,
        .skipCustomInstructions = config.skip_custom_instructions,
        .enableOnDemandInstructionDiscovery = config.enable_on_demand_instruction_discovery,
        .enableManagedSettings = config.enable_managed_settings,
        .managedSettings = lowerManagedSettings(config.managed_settings),
    };
}

const RpcSuccess = struct {
    success: bool,
};

const WireClientInfo = struct {
    editorName: ?[]const u8 = null,
    editorVersion: ?[]const u8 = null,
    extensionName: ?[]const u8 = null,
    extensionVersion: ?[]const u8 = null,
};

fn toWireClientInfo(info: ?ClientInfo) ?WireClientInfo {
    const value = info orelse return null;
    if (value.application_name == null and
        value.application_version == null and
        value.integration_name == null and
        value.integration_version == null)
    {
        return null;
    }
    return .{
        .editorName = value.application_name,
        .editorVersion = value.application_version,
        .extensionName = value.integration_name,
        .extensionVersion = value.integration_version,
    };
}

fn appendWireTools(
    allocator: std.mem.Allocator,
    definitions: []const session_types.Tool,
    parsed_parameters: *std.ArrayList(std.json.Parsed(std.json.Value)),
    tools: *std.ArrayList(WireTool),
) !void {
    for (definitions) |definition| {
        const parsed_parameters_value = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            definition.parameters_json,
            .{},
        );
        errdefer parsed_parameters_value.deinit();
        if (parsed_parameters_value.value != .object) return error.InvalidToolParameters;

        var parsed_metadata: ?std.json.Parsed(std.json.Value) = null;
        errdefer if (parsed_metadata) |parsed| parsed.deinit();
        if (definition.metadata_json) |metadata_json| {
            const parsed = try std.json.parseFromSlice(
                std.json.Value,
                allocator,
                metadata_json,
                .{},
            );
            if (parsed.value != .object) {
                parsed.deinit();
                return error.InvalidToolMetadata;
            }
            parsed_metadata = parsed;
        }

        try tools.append(allocator, .{
            .name = definition.name,
            .description = definition.description,
            .parameters = parsed_parameters_value.value,
            .overridesBuiltInTool = definition.overrides_built_in_tool,
            .skipPermission = definition.skip_permission,
            .@"defer" = definition.defer_loading,
            .metadata = if (parsed_metadata) |parsed| parsed.value else null,
            .isTerminal = definition.is_terminal,
        });
        try parsed_parameters.append(allocator, parsed_parameters_value);
        if (parsed_metadata) |parsed| try parsed_parameters.append(allocator, parsed);
    }
}

test "public client API type checks" {
    const init_fn: *const fn (std.mem.Allocator, std.Io, ClientOptions) anyerror!Client = &Client.init;
    const init_parent_fn: *const fn (std.mem.Allocator, std.Io) anyerror!Client = &Client.initParent;
    const deinit_fn: *const fn (*Client) void = &Client.deinit;
    const stop_fn: *const fn (*Client) anyerror!void = &Client.stop;
    const create_fn: *const fn (*Client, session_types.SessionConfig) anyerror!Session = &Client.createSession;
    const join_fn: *const fn (*Client, []const u8, session_types.SessionConfig) anyerror!Session = &Client.joinSession;
    const list_fn: *const fn (*Client, models.ListOptions) anyerror!std.json.Parsed(models.ModelList) = &Client.listModels;
    const register_fn: *const fn (*Client, []const u8, RpcHandler, ?*anyopaque) anyerror!void = &Client.registerRpcHandler;
    const unregister_fn: *const fn (*Client, []const u8) bool = &Client.unregisterRpcHandler;
    const send_fn: *const fn (Session, session_types.MessageOptions) anyerror![]u8 = &Session.send;
    const send_wait_fn: *const fn (Session, session_types.MessageOptions) anyerror!?session_types.AssistantMessage = &Session.sendAndWait;
    const event_fn: *const fn (Session) anyerror!session_types.SessionEvent = &Session.nextEvent;
    const disconnect_fn: *const fn (Session) anyerror!void = &Session.disconnect;
    const auto_tier_fn: *const fn (Session, ?session_types.AutoTier) anyerror!session_types.AutoTierSwitchResult = &Session.setAutoTier;
    const abort_fn: *const fn (Session) anyerror!std.json.Parsed(session_types.AbortResult) = &Session.abort;
    const model_fn: *const fn (Session, []const u8, session_types.ModelSwitchOptions) anyerror!std.json.Parsed(session_types.ModelSwitchResult) = &Session.setModel;
    const log_fn: *const fn (Session, []const u8, session_types.LogOptions) anyerror![]u8 = &Session.log;
    const approve_fn: *const fn (Session, []const u8) anyerror!void = &Session.approvePermission;
    const reject_fn: *const fn (Session, []const u8, ?[]const u8) anyerror!void = &Session.rejectPermission;
    const permission_json_fn: *const fn (Session, []const u8, []const u8, ?[]const u8) anyerror!void = &Session.respondToPermissionJson;
    const tool_fn: *const fn (Session, []const u8, []const u8) anyerror!void = &Session.respondToTool;
    const tool_json_fn: *const fn (Session, []const u8, []const u8) anyerror!void = &Session.respondToToolResultJson;
    const tool_error_fn: *const fn (Session, []const u8, []const u8) anyerror!void = &Session.respondToToolError;
    _ = .{
        init_fn,       init_parent_fn,     deinit_fn,     stop_fn,      create_fn,     join_fn,
        list_fn,       register_fn,        unregister_fn, send_fn,      send_wait_fn,  event_fn,
        disconnect_fn, auto_tier_fn,       abort_fn,      model_fn,     log_fn,        approve_fn,
        reject_fn,     permission_json_fn, tool_fn,       tool_json_fn, tool_error_fn,
    };

    if (false) {
        var client: *Client = undefined;
        const session: Session = undefined;
        _ = client.callRpc(std.json.Value, "method", .{});
        _ = client.callRpcDetailed(std.json.Value, "method", .{});
        _ = session.send(.{ .prompt = "hello" });
        _ = session.disconnect();
    }
}

const ShutdownProbe = struct {
    attempted: [3][]const u8 = undefined,
    attempt_count: usize = 0,
    terminate_count: usize = 0,
    disconnect_errors: [3]?anyerror,
    terminate_error: ?anyerror,

    fn disconnect(context: ?*anyopaque, _: *Client, session_id: []const u8) !void {
        const self: *ShutdownProbe = @ptrCast(@alignCast(context.?));
        const attempt = self.attempt_count;
        self.attempted[attempt] = session_id;
        self.attempt_count += 1;
        if (self.disconnect_errors[attempt]) |err| return err;
    }

    fn terminate(context: ?*anyopaque, _: *Client) !void {
        const self: *ShutdownProbe = @ptrCast(@alignCast(context.?));
        self.terminate_count += 1;
        if (self.terminate_error) |err| return err;
    }
};

const ShutdownRecordProbe = struct {
    calls: usize = 0,
    drop_all: bool,

    fn record(context: *anyopaque, _: ?[]const u8, _: anyerror) void {
        const self: *ShutdownRecordProbe = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (self.drop_all) return;
    }
};

test "shutdown attempts every initial session and child after all injected failures" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = undefined,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer {
        for (client.session_ids.items) |id| allocator.free(id);
        client.session_ids.deinit(allocator);
    }
    for ([_][]const u8{ "s1", "s2", "s3" }) |id| {
        try client.session_ids.append(allocator, try allocator.dupe(u8, id));
    }

    const cases = [_]struct {
        disconnect_errors: [3]?anyerror,
        terminate_error: ?anyerror,
        drop_all_diagnostics: bool,
        expected_first: anyerror,
    }{
        .{
            .disconnect_errors = .{ error.BrokenPipe, error.OutOfMemory, error.EndOfStream },
            .terminate_error = error.AccessDenied,
            .drop_all_diagnostics = false,
            .expected_first = error.BrokenPipe,
        },
        .{
            .disconnect_errors = .{ error.BrokenPipe, error.OutOfMemory, error.EndOfStream },
            .terminate_error = error.AccessDenied,
            .drop_all_diagnostics = true,
            .expected_first = error.BrokenPipe,
        },
    };

    for (cases) |case| {
        var operations = ShutdownProbe{
            .disconnect_errors = case.disconnect_errors,
            .terminate_error = case.terminate_error,
        };
        var records = ShutdownRecordProbe{ .drop_all = case.drop_all_diagnostics };
        const result = runShutdown(&client, .{
            .context = &operations,
            .disconnect_session_once = ShutdownProbe.disconnect,
            .terminate_child_once = ShutdownProbe.terminate,
        }, .{
            .context = &records,
            .record = ShutdownRecordProbe.record,
        });
        try std.testing.expectEqual(case.expected_first, result.?);
        try std.testing.expectEqual(@as(usize, 3), operations.attempt_count);
        try std.testing.expectEqualStrings("s3", operations.attempted[0]);
        try std.testing.expectEqualStrings("s2", operations.attempted[1]);
        try std.testing.expectEqualStrings("s1", operations.attempted[2]);
        try std.testing.expectEqual(@as(usize, 1), operations.terminate_count);
        try std.testing.expectEqual(@as(usize, 4), records.calls);
    }
}

test "stopDetailed aggregates owned failures and attempt counts" {
    std.debug.print("\nCENSUS_PROBE shutdown_behavior\n", .{});
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = undefined,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer {
        for (client.session_ids.items) |id| allocator.free(id);
        client.session_ids.deinit(allocator);
    }
    for ([_][]const u8{ "s1", "s2", "s3" }) |id| {
        try client.session_ids.append(allocator, try allocator.dupe(u8, id));
    }

    var operations = ShutdownProbe{
        .disconnect_errors = .{ error.BrokenPipe, error.OutOfMemory, error.EndOfStream },
        .terminate_error = error.AccessDenied,
    };
    var failure = switch (client.stopDetailedWithOps(.{
        .context = &operations,
        .disconnect_session_once = ShutdownProbe.disconnect,
        .terminate_child_once = ShutdownProbe.terminate,
    }, true)) {
        .success => return error.TestExpectedShutdownFailure,
        .failure => |failure| failure,
    };
    defer failure.deinit();

    try std.testing.expectEqual(error.BrokenPipe, failure.native_error);
    const shutdown = switch (failure.detail) {
        .shutdown => |shutdown| shutdown,
        else => return error.TestExpectedShutdownFailure,
    };
    try std.testing.expectEqual(@as(usize, 3), shutdown.sessions_attempted);
    try std.testing.expect(shutdown.child_termination_attempted);
    try std.testing.expectEqual(@as(usize, 4), shutdown.failure_count);
    try std.testing.expectEqual(@as(usize, 0), shutdown.diagnostics_dropped);
    try std.testing.expectEqual(@as(usize, 3), operations.attempt_count);
    try std.testing.expectEqual(@as(usize, 1), operations.terminate_count);

    switch (shutdown.failures()[0].detail) {
        .session => |session_failure| switch (session_failure) {
            .detach_failed => |detail| try std.testing.expectEqualStrings("s3", detail.session_id),
            else => return error.TestExpectedDetachFailure,
        },
        else => return error.TestExpectedDetachFailure,
    }
    switch (shutdown.failures()[3].detail) {
        .process => |process_failure| switch (process_failure) {
            .terminate => |detail| {
                try std.testing.expect(detail.exit == null);
                try std.testing.expectEqualStrings("AccessDenied", detail.message);
                try std.testing.expectEqual(error.AccessDenied, detail.cause.code);
            },
            else => return error.TestExpectedTerminateFailure,
        },
        else => return error.TestExpectedTerminateFailure,
    }
}

test "stopDetailed reports allocation-free dropped diagnostics" {
    std.debug.print("\nCENSUS_PROBE shutdown_dropped_behavior\n", .{});
    const allocator = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var client = Client{
        .allocator = failing.allocator(),
        .io = undefined,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer {
        for (client.session_ids.items) |id| allocator.free(id);
        client.session_ids.deinit(allocator);
    }
    for ([_][]const u8{ "s1", "s2", "s3" }) |id| {
        try client.session_ids.append(allocator, try allocator.dupe(u8, id));
    }

    var operations = ShutdownProbe{
        .disconnect_errors = .{ error.BrokenPipe, error.EndOfStream, error.ConnectionResetByPeer },
        .terminate_error = error.AccessDenied,
    };
    var failure = switch (client.stopDetailedWithOps(.{
        .context = &operations,
        .disconnect_session_once = ShutdownProbe.disconnect,
        .terminate_child_once = ShutdownProbe.terminate,
    }, true)) {
        .success => return error.TestExpectedShutdownFailure,
        .failure => |failure| failure,
    };
    defer failure.deinit();

    const shutdown = switch (failure.detail) {
        .shutdown => |shutdown| shutdown,
        else => return error.TestExpectedShutdownFailure,
    };
    try std.testing.expectEqual(@as(usize, 3), shutdown.sessions_attempted);
    try std.testing.expect(shutdown.child_termination_attempted);
    try std.testing.expectEqual(@as(usize, 0), shutdown.failure_storage.len);
    try std.testing.expectEqual(@as(usize, 0), shutdown.failure_count);
    try std.testing.expectEqual(@as(usize, 4), shutdown.diagnostics_dropped);
    try std.testing.expectEqual(@as(usize, 3), operations.attempt_count);
    try std.testing.expectEqual(@as(usize, 1), operations.terminate_count);
}

test "RPC handler registration rejects duplicates and unregisters" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = undefined,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer {
        for (client.rpc_handlers.items) |handler| handler.deinit(allocator);
        client.rpc_handlers.deinit(allocator);
    }

    const handler = struct {
        fn handle(
            inner_allocator: std.mem.Allocator,
            _: ?[]const u8,
            _: ?*anyopaque,
        ) ![]u8 {
            return inner_allocator.dupe(u8, "{}");
        }
    }.handle;

    try client.registerRpcHandler("gitHubToken.getToken", handler, null);
    try std.testing.expectError(
        error.RpcHandlerAlreadyRegistered,
        client.registerRpcHandler("gitHubToken.getToken", handler, null),
    );
    try std.testing.expect(client.unregisterRpcHandler("gitHubToken.getToken"));
    try std.testing.expect(!client.unregisterRpcHandler("gitHubToken.getToken"));
}

test "model list options map to wire fields" {
    const request = WireModelsListRequest{
        .selectionId = "account-1",
        .gitHubToken = "token",
    };
    const body = try json_rpc.encodeRequest(
        std.testing.allocator,
        4,
        "models.list",
        request,
    );
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const params = parsed.value.object.get("params").?.object;
    try std.testing.expectEqualStrings("account-1", params.get("selectionId").?.string);
    try std.testing.expectEqualStrings("token", params.get("gitHubToken").?.string);
}

test "inbound RPC params preserve omission and non-object values" {
    try std.testing.expect(try stringifyRpcParams(std.testing.allocator, null) == null);

    const scalar = (try stringifyRpcParams(
        std.testing.allocator,
        .{ .string = "value" },
    )).?;
    defer std.testing.allocator.free(scalar);
    try std.testing.expectEqualStrings("\"value\"", scalar);
}

test "inbound request without params is dispatched while waiting for a response" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const inbound_notification =
        \\{"jsonrpc":"2.0","method":"test.notice"}
    ;
    const inbound_request =
        \\{"jsonrpc":"2.0","id":44,"method":"test.noParams"}
    ;
    const call_response =
        \\{"jsonrpc":"2.0","id":1,"result":{"done":true}}
    ;
    const frames = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}",
        .{
            inbound_notification.len,
            inbound_notification,
            inbound_request.len,
            inbound_request,
            call_response.len,
            call_response,
        },
    );
    defer allocator.free(frames);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "response", .data = frames });
    const response_file = try tmp.dir.openFile(std.testing.io, "response", .{});
    defer response_file.close(std.testing.io);
    var reader_buffer: [1024]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
    const request_file = try tmp.dir.createFile(std.testing.io, "request", .{ .read = true });
    var writer_buffer: [2048]u8 = undefined;
    var writer = request_file.writer(std.testing.io, &writer_buffer);
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = &reader,
        .writer = &writer,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer {
        for (client.rpc_handlers.items) |registered| registered.deinit(allocator);
        client.rpc_handlers.deinit(allocator);
    }
    try client.registerRpcHandler("test.noParams", struct {
        fn handle(
            inner_allocator: std.mem.Allocator,
            params_json: ?[]const u8,
            _: ?*anyopaque,
        ) ![]u8 {
            try std.testing.expect(params_json == null);
            return inner_allocator.dupe(u8, "{\"accepted\":true}");
        }
    }.handle, null);

    const result = try client.callRpc(
        struct { done: bool },
        "test.outer",
        .{},
    );
    defer result.deinit();
    try std.testing.expect(result.value.done);
    try writer.interface.flush();
    request_file.close(std.testing.io);

    const written = try tmp.dir.readFileAlloc(
        std.testing.io,
        "request",
        allocator,
        .unlimited,
    );
    defer allocator.free(written);
    try std.testing.expect(std.mem.indexOf(
        u8,
        written,
        "{\"jsonrpc\":\"2.0\",\"id\":44,\"result\":{\"accepted\":true}}",
    ) != null);
}

test "inbound RPC dispatch writes success and error frames" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = undefined,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer {
        for (client.rpc_handlers.items) |handler| handler.deinit(allocator);
        client.rpc_handlers.deinit(allocator);
    }

    try client.registerRpcHandler("test.success", struct {
        fn handle(
            inner_allocator: std.mem.Allocator,
            params_json: ?[]const u8,
            _: ?*anyopaque,
        ) ![]u8 {
            if (params_json == null or
                !std.mem.eql(u8, params_json.?, "{\"value\":7}"))
            {
                return error.UnexpectedParams;
            }
            return inner_allocator.dupe(u8, "{\"accepted\":true}");
        }
    }.handle, null);
    try client.registerRpcHandler("test.failure", struct {
        fn handle(
            _: std.mem.Allocator,
            _: ?[]const u8,
            _: ?*anyopaque,
        ) ![]u8 {
            return error.HandlerFailed;
        }
    }.handle, null);
    try client.registerRpcHandler("test.invalid", struct {
        fn handle(
            inner_allocator: std.mem.Allocator,
            _: ?[]const u8,
            _: ?*anyopaque,
        ) ![]u8 {
            return inner_allocator.dupe(u8, "not json");
        }
    }.handle, null);

    var success_output: std.Io.Writer.Allocating = .init(allocator);
    defer success_output.deinit();
    var success_params: std.json.ObjectMap = .empty;
    defer success_params.deinit(allocator);
    try success_params.put(allocator, "value", .{ .integer = 7 });
    var failure_operation: errors.ClientOperation = .callback;
    try client.dispatchServerRequest(
        &success_output.writer,
        .{ .integer = 1 },
        "test.success",
        .{ .object = success_params },
        &failure_operation,
    );
    const success_body = try framedBody(allocator, success_output.written());
    defer allocator.free(success_body);
    const success = try std.json.parseFromSlice(std.json.Value, allocator, success_body, .{});
    defer success.deinit();
    try std.testing.expect(success.value.object.get("result").?.object.get("accepted").?.bool);

    var failure_output: std.Io.Writer.Allocating = .init(allocator);
    defer failure_output.deinit();
    try client.dispatchServerRequest(
        &failure_output.writer,
        .{ .integer = 2 },
        "test.failure",
        null,
        &failure_operation,
    );
    const failure_body = try framedBody(allocator, failure_output.written());
    defer allocator.free(failure_body);
    const failure = try std.json.parseFromSlice(std.json.Value, allocator, failure_body, .{});
    defer failure.deinit();
    try std.testing.expectEqualStrings(
        "HandlerFailed",
        failure.value.object.get("error").?.object.get("message").?.string,
    );

    var invalid_output: std.Io.Writer.Allocating = .init(allocator);
    defer invalid_output.deinit();
    try client.dispatchServerRequest(
        &invalid_output.writer,
        .{ .integer = 3 },
        "test.invalid",
        null,
        &failure_operation,
    );
    const invalid_body = try framedBody(allocator, invalid_output.written());
    defer allocator.free(invalid_body);
    const invalid = try std.json.parseFromSlice(std.json.Value, allocator, invalid_body, .{});
    defer invalid.deinit();
    try std.testing.expectEqual(
        @as(i64, -32603),
        invalid.value.object.get("error").?.object.get("code").?.integer,
    );
}

fn expectServerRequestResponse(
    client: *Client,
    id: i64,
    method: []const u8,
    params: ?std.json.Value,
    expected_code: ?i64,
    expected_message: ?[]const u8,
) !void {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var failure_operation: errors.ClientOperation = .callback;
    try client.dispatchServerRequest(
        &output.writer,
        .{ .integer = id },
        method,
        params,
        &failure_operation,
    );
    const body = try framedBody(allocator, output.written());
    defer allocator.free(body);
    const response = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer response.deinit();
    try std.testing.expectEqual(id, response.value.object.get("id").?.integer);
    if (expected_code) |code| {
        const rpc_error = response.value.object.get("error").?.object;
        try std.testing.expectEqual(code, rpc_error.get("code").?.integer);
        try std.testing.expectEqualStrings(expected_message.?, rpc_error.get("message").?.string);
    } else {
        try std.testing.expect(response.value.object.get("result").?.object.get("accepted").?.bool);
    }
}

test "server request response matrix preserves generic userInput.request fallback" {
    std.debug.print("\nCENSUS_PROBE server_request_response_matrix\n", .{});
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = undefined,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer {
        for (client.rpc_handlers.items) |handler| handler.deinit(allocator);
        client.rpc_handlers.deinit(allocator);
        client.user_input_handlers.deinit(allocator);
    }
    try client.registerRpcHandler("test.success", struct {
        fn handle(inner_allocator: std.mem.Allocator, _: ?[]const u8, _: ?*anyopaque) ![]u8 {
            return inner_allocator.dupe(u8, "{\"accepted\":true}");
        }
    }.handle, null);
    try client.registerRpcHandler("test.failure", struct {
        fn handle(_: std.mem.Allocator, _: ?[]const u8, _: ?*anyopaque) ![]u8 {
            return error.HandlerFailed;
        }
    }.handle, null);
    try client.registerRpcHandler("test.invalid", struct {
        fn handle(inner_allocator: std.mem.Allocator, _: ?[]const u8, _: ?*anyopaque) ![]u8 {
            return inner_allocator.dupe(u8, "not json");
        }
    }.handle, null);
    var generic_user_input_called = false;
    try client.registerRpcHandler("userInput.request", struct {
        fn handle(
            inner_allocator: std.mem.Allocator,
            params_json: ?[]const u8,
            context: ?*anyopaque,
        ) ![]u8 {
            const called: *bool = @ptrCast(@alignCast(context.?));
            try std.testing.expect(params_json != null);
            called.* = true;
            return inner_allocator.dupe(u8, "{\"accepted\":true}");
        }
    }.handle, &generic_user_input_called);

    try expectServerRequestResponse(&client, 1, "test.unknown", null, -32601, "method not found");
    try expectServerRequestResponse(&client, 2, "test.success", null, null, null);
    try expectServerRequestResponse(&client, 3, "test.failure", null, -32000, "HandlerFailed");
    try expectServerRequestResponse(&client, 4, "test.invalid", null, -32603, "invalid handler result");

    var user_input_params: std.json.ObjectMap = .empty;
    defer user_input_params.deinit(allocator);
    try user_input_params.put(allocator, "sessionId", .{ .string = "generic-session" });
    try user_input_params.put(allocator, "question", .{ .string = "Continue?" });
    try expectServerRequestResponse(
        &client,
        5,
        "userInput.request",
        .{ .object = user_input_params },
        null,
        null,
    );
    try std.testing.expect(generic_user_input_called);

    var specialized_params: std.json.ObjectMap = .empty;
    defer specialized_params.deinit(allocator);
    try specialized_params.put(allocator, "sessionId", .{ .string = "specialized-session" });
    try specialized_params.put(allocator, "question", .{ .string = "Continue?" });
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var failure_operation: errors.ClientOperation = .callback;
    try client.dispatchUserInputRequest(
        &output.writer,
        .{ .integer = 6 },
        .{ .object = specialized_params },
        &failure_operation,
    );
    const body = try framedBody(allocator, output.written());
    defer allocator.free(body);
    const response = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer response.deinit();
    const rpc_error = response.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32000), rpc_error.get("code").?.integer);
    try std.testing.expectEqualStrings(
        "user input handler not registered",
        rpc_error.get("message").?.string,
    );

    try client.registerUserInputHandler("specialized-session", struct {
        fn handle(
            inner_allocator: std.mem.Allocator,
            _: session_types.UserInputRequest,
            _: ?*anyopaque,
        ) !session_types.UserInputResponse {
            return .{
                .answer = try inner_allocator.dupe(u8, "unused"),
                .was_freeform = false,
            };
        }
    }.handle, null);
    var invalid_specialized_params: std.json.ObjectMap = .empty;
    defer invalid_specialized_params.deinit(allocator);
    try invalid_specialized_params.put(
        allocator,
        "sessionId",
        .{ .string = "specialized-session" },
    );
    try expectServerRequestResponse(
        &client,
        7,
        "userInput.request",
        .{ .object = invalid_specialized_params },
        -32602,
        "invalid user input request",
    );
}

test "userInput.request without either handler is method not found" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = undefined,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer client.user_input_handlers.deinit(allocator);

    var params: std.json.ObjectMap = .empty;
    defer params.deinit(allocator);
    try params.put(allocator, "sessionId", .{ .string = "missing-session" });
    try params.put(allocator, "question", .{ .string = "Continue?" });
    try expectServerRequestResponse(
        &client,
        8,
        "userInput.request",
        .{ .object = params },
        -32601,
        "method not found",
    );
}

test "user input handler receives requests and returns responses" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = undefined,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer client.user_input_handlers.deinit(allocator);

    var called = false;
    const handler = struct {
        fn handle(
            inner_allocator: std.mem.Allocator,
            request: session_types.UserInputRequest,
            context: ?*anyopaque,
        ) !session_types.UserInputResponse {
            const did_call: *bool = @ptrCast(@alignCast(context.?));
            try std.testing.expectEqualStrings("session-1", request.session_id);
            try std.testing.expectEqualStrings("Continue?", request.question);
            try std.testing.expectEqual(@as(usize, 2), request.choices.?.len);
            try std.testing.expectEqualStrings("Yes", request.choices.?[0]);
            try std.testing.expectEqualStrings("No", request.choices.?[1]);
            try std.testing.expect(request.allow_freeform.?);
            did_call.* = true;
            return .{
                .answer = try inner_allocator.dupe(u8, "Yes"),
                .was_freeform = false,
            };
        }
    }.handle;
    try client.registerUserInputHandler("session-1", handler, &called);

    const parsed_params = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"sessionId":"session-1","question":"Continue?","choices":["Yes","No"],"allowFreeform":true}
    ,
        .{},
    );
    defer parsed_params.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var failure_operation: errors.ClientOperation = .callback;
    try client.dispatchServerRequest(
        &output.writer,
        .{ .integer = 3 },
        "userInput.request",
        parsed_params.value,
        &failure_operation,
    );

    try std.testing.expect(called);
    const body = try framedBody(allocator, output.written());
    defer allocator.free(body);
    const response = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer response.deinit();
    const result = response.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("Yes", result.get("answer").?.string);
    try std.testing.expect(!result.get("wasFreeform").?.bool);
}

test "permission handler receives events and can leave requests pending" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = undefined,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    try client.session_ids.append(allocator, try allocator.dupe(u8, "session-1"));
    defer {
        client.removeSession("session-1");
        client.events.deinit(allocator);
        client.permission_handlers.deinit(allocator);
        client.session_ids.deinit(allocator);
    }

    var called = false;
    const handler = struct {
        fn handle(
            request: session_types.PermissionRequested,
            invocation: session_types.PermissionInvocation,
            context: ?*anyopaque,
        ) !session_types.PermissionDecision {
            const did_call: *bool = @ptrCast(@alignCast(context.?));
            try std.testing.expectEqualStrings("permission-1", request.request_id);
            try std.testing.expectEqualStrings("session-1", invocation.session_id);
            try std.testing.expect(!invocation.managed_settings_enabled);
            try std.testing.expectEqualStrings(
                "{\"kind\":\"shell\",\"fullCommandText\":\"pwd\"}",
                request.permission_request_json,
            );
            did_call.* = true;
            return .no_result;
        }
    }.handle;
    try client.registerPermissionHandler("session-1", .{
        .on_permission_request = handler,
        .permission_context = &called,
    });

    const parsed_event = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"permission.requested","data":{"requestId":"permission-1","permissionRequest":{"kind":"shell","fullCommandText":"pwd"}}}
    ,
        .{},
    );
    defer parsed_event.deinit();
    try client.events.append(allocator, .{
        .session_id = try allocator.dupe(u8, "session-1"),
        .payload = try deliveryPayloadForTest(
            allocator,
            try session_types.parseEvent(allocator, parsed_event.value),
        ),
    });

    const session = Session{ .client = &client, .id = "session-1" };
    var event = try session.nextEvent();
    defer event.deinit(allocator);
    try std.testing.expect(called);
    try std.testing.expect(event == .permission_requested);
    try std.testing.expect(event.permission_requested.automatic_handling == .no_result);

    try client.registerPermissionHandler("session-2", .{
        .enable_managed_settings = true,
        .on_permission_request = handler,
        .permission_context = &called,
    });
    try std.testing.expect(
        client.findPermissionHandler("session-2").?.managed_settings_enabled,
    );
}

test "permission handler receives injected managed settings metadata" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = undefined,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    try client.session_ids.append(allocator, try allocator.dupe(u8, "session-1"));
    defer {
        client.removeSession("session-1");
        client.events.deinit(allocator);
        client.permission_handlers.deinit(allocator);
        client.session_ids.deinit(allocator);
    }

    var called = false;
    const handler = struct {
        fn handle(
            _: session_types.PermissionRequested,
            invocation: session_types.PermissionInvocation,
            context: ?*anyopaque,
        ) !session_types.PermissionDecision {
            const did_call: *bool = @ptrCast(@alignCast(context.?));
            try std.testing.expectEqualStrings("session-1", invocation.session_id);
            try std.testing.expect(invocation.managed_settings_enabled);
            did_call.* = true;
            return .no_result;
        }
    }.handle;
    try client.registerPermissionHandler("session-1", .{
        .managed_settings = .{},
        .on_permission_request = handler,
        .permission_context = &called,
    });

    const parsed_event = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"permission.requested","data":{"requestId":"permission-1","permissionRequest":{"kind":"future-kind"}}}
    ,
        .{},
    );
    defer parsed_event.deinit();
    try client.events.append(allocator, .{
        .session_id = try allocator.dupe(u8, "session-1"),
        .payload = try deliveryPayloadForTest(
            allocator,
            try session_types.parseEvent(allocator, parsed_event.value),
        ),
    });

    const session = Session{ .client = &client, .id = "session-1" };
    var event = try session.nextEvent();
    defer event.deinit(allocator);
    try std.testing.expect(called);
    try std.testing.expect(event == .permission_requested);
    try std.testing.expect(event.permission_requested.automatic_handling == .no_result);
}

test "permission handler failures leave requests available for manual handling" {
    std.debug.print("\nCENSUS_PROBE permission_handler_behavior\n", .{});
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = undefined,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    try client.session_ids.append(allocator, try allocator.dupe(u8, "session-1"));
    defer {
        client.removeSession("session-1");
        client.events.deinit(allocator);
        client.permission_handlers.deinit(allocator);
        client.session_ids.deinit(allocator);
    }

    const handler = struct {
        fn handle(
            _: session_types.PermissionRequested,
            _: session_types.PermissionInvocation,
            _: ?*anyopaque,
        ) !session_types.PermissionDecision {
            return error.PermissionHandlerFailed;
        }
    }.handle;
    try client.registerPermissionHandler("session-1", .{
        .on_permission_request = handler,
    });

    const parsed_event = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"permission.requested","data":{"requestId":"permission-1","permissionRequest":{"kind":"shell","fullCommandText":"pwd"}}}
    ,
        .{},
    );
    defer parsed_event.deinit();
    try client.events.append(allocator, .{
        .session_id = try allocator.dupe(u8, "session-1"),
        .payload = try deliveryPayloadForTest(
            allocator,
            try session_types.parseEvent(allocator, parsed_event.value),
        ),
    });

    const session = Session{ .client = &client, .id = "session-1" };
    var event = try session.nextEvent();
    defer event.deinit(allocator);
    try std.testing.expect(event == .permission_requested);
    try std.testing.expectEqual(
        error.PermissionHandlerFailed,
        event.permission_requested.automatic_handling.handler_failed,
    );
}

test "approveAll leaves managed permission events observable" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = undefined,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    try client.session_ids.append(allocator, try allocator.dupe(u8, "managed-session"));
    try client.session_ids.append(allocator, try allocator.dupe(u8, "managed-request"));
    defer {
        client.removeSession("managed-session");
        client.removeSession("managed-request");
        client.events.deinit(allocator);
        client.permission_handlers.deinit(allocator);
        client.session_ids.deinit(allocator);
    }
    try client.registerPermissionHandler("managed-session", .{
        .enable_managed_settings = true,
        .on_permission_request = session_types.approveAll,
    });
    try client.registerPermissionHandler("managed-request", .{
        .on_permission_request = session_types.approveAll,
    });

    const managed_session_event = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"permission.requested","data":{"requestId":"permission-1","permissionRequest":{"kind":"read"}}}
    ,
        .{},
    );
    defer managed_session_event.deinit();
    try client.events.append(allocator, .{
        .session_id = try allocator.dupe(u8, "managed-session"),
        .payload = try deliveryPayloadForTest(
            allocator,
            try session_types.parseEvent(allocator, managed_session_event.value),
        ),
    });

    const managed_request_event = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"permission.requested","data":{"requestId":"permission-2","permissionRequest":{"kind":"future-kind","managedApprovalRequired":true}}}
    ,
        .{},
    );
    defer managed_request_event.deinit();
    try client.events.append(allocator, .{
        .session_id = try allocator.dupe(u8, "managed-request"),
        .payload = try deliveryPayloadForTest(
            allocator,
            try session_types.parseEvent(allocator, managed_request_event.value),
        ),
    });

    const managed_session = Session{ .client = &client, .id = "managed-session" };
    var first = try managed_session.nextEvent();
    defer first.deinit(allocator);
    try std.testing.expectEqual(
        error.ApproveAllWithManagedSettings,
        first.permission_requested.automatic_handling.handler_failed,
    );

    const managed_request = Session{ .client = &client, .id = "managed-request" };
    var second = try managed_request.nextEvent();
    defer second.deinit(allocator);
    try std.testing.expectEqualStrings("permission-2", second.permission_requested.request_id);
    try std.testing.expect(second.permission_requested.automatic_handling == .no_result);
}

fn runAutomaticPermissionRpc(
    allocator: std.mem.Allocator,
    response_body: []const u8,
) !struct {
    handling: ?session_types.AutomaticPermissionHandling,
    failure: ?anyerror,
    request_frame: []u8,
} {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const response_frame = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}",
        .{ response_body.len, response_body },
    );
    defer allocator.free(response_frame);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "response",
        .data = response_frame,
    });

    const response_file = try tmp.dir.openFile(
        std.testing.io,
        "response",
        .{ .mode = .read_only },
    );
    defer response_file.close(std.testing.io);
    var reader_buffer: [1024]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);

    const request_file = try tmp.dir.createFile(
        std.testing.io,
        "request",
        .{},
    );
    defer request_file.close(std.testing.io);
    var writer_buffer: [1024]u8 = undefined;
    var writer = request_file.writer(std.testing.io, &writer_buffer);

    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = &reader,
        .writer = &writer,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    try client.session_ids.append(allocator, try allocator.dupe(u8, "session-1"));
    defer {
        client.removeSession("session-1");
        client.events.deinit(allocator);
        client.permission_handlers.deinit(allocator);
        client.session_ids.deinit(allocator);
    }

    const handler = struct {
        fn handle(
            _: session_types.PermissionRequested,
            _: session_types.PermissionInvocation,
            _: ?*anyopaque,
        ) !session_types.PermissionDecision {
            return .approve_once;
        }
    }.handle;
    try client.registerPermissionHandler("session-1", .{
        .on_permission_request = handler,
    });

    const parsed_event = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"permission.requested","data":{"requestId":"permission-1","permissionRequest":{"kind":"shell","fullCommandText":"pwd"}}}
    ,
        .{},
    );
    defer parsed_event.deinit();
    try client.events.append(allocator, .{
        .session_id = try allocator.dupe(u8, "session-1"),
        .payload = try deliveryPayloadForTest(
            allocator,
            try session_types.parseEvent(allocator, parsed_event.value),
        ),
    });

    const session = Session{ .client = &client, .id = "session-1" };
    var handling: ?session_types.AutomaticPermissionHandling = null;
    var native_failure: ?anyerror = null;
    switch (try session.nextEventDetailed()) {
        .success => |event_value| {
            var event = event_value;
            defer event.deinit(allocator);
            handling = event.permission_requested.automatic_handling;
        },
        .failure => |failure_value| {
            var failure = failure_value;
            defer failure.deinit();
            native_failure = failure.native_error;
        },
    }

    const request_frame = try tmp.dir.readFileAlloc(
        std.testing.io,
        "request",
        allocator,
        .limited(4096),
    );
    return .{
        .handling = handling,
        .failure = native_failure,
        .request_frame = request_frame,
    };
}

test "successful automatic permission handling writes one exact RPC and marks the event handled" {
    const allocator = std.testing.allocator;
    const result = try runAutomaticPermissionRpc(allocator,
        \\{"jsonrpc":"2.0","id":1,"result":{"success":true}}
    );
    defer allocator.free(result.request_frame);

    try std.testing.expect(result.failure == null);
    try std.testing.expect(result.handling.? == .handled);
    const expected_body =
        \\{"jsonrpc":"2.0","id":1,"method":"session.permissions.handlePendingPermissionRequest","params":{"sessionId":"session-1","requestId":"permission-1","result":{"kind":"approve-once"}}}
    ;
    const expected_frame = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}",
        .{ expected_body.len, expected_body },
    );
    defer allocator.free(expected_frame);
    try std.testing.expectEqualStrings(expected_frame, result.request_frame);
}

test "rejected automatic permission RPC returns an explicit delivery failure" {
    const allocator = std.testing.allocator;
    const result = try runAutomaticPermissionRpc(allocator,
        \\{"jsonrpc":"2.0","id":1,"result":{"success":false}}
    );
    defer allocator.free(result.request_frame);

    try std.testing.expectEqual(error.PermissionDecisionNotAccepted, result.failure.?);
    try std.testing.expect(result.handling == null);
    const expected_body =
        \\{"jsonrpc":"2.0","id":1,"method":"session.permissions.handlePendingPermissionRequest","params":{"sessionId":"session-1","requestId":"permission-1","result":{"kind":"approve-once"}}}
    ;
    const expected_frame = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}",
        .{ expected_body.len, expected_body },
    );
    defer allocator.free(expected_frame);
    try std.testing.expectEqualStrings(expected_frame, result.request_frame);
}

test "permission response delivery failures are explicit" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "read-only", .data = "" });
    const transport = try tmp.dir.openFile(
        std.testing.io,
        "read-only",
        .{ .mode = .read_only },
    );
    defer transport.close(std.testing.io);
    var writer_buffer: [1024]u8 = undefined;
    var writer = transport.writer(std.testing.io, &writer_buffer);

    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = undefined,
        .writer = &writer,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    try client.session_ids.append(allocator, try allocator.dupe(u8, "session-1"));
    defer {
        client.removeSession("session-1");
        client.events.deinit(allocator);
        client.permission_handlers.deinit(allocator);
        client.session_ids.deinit(allocator);
    }

    const handler = struct {
        fn handle(
            _: session_types.PermissionRequested,
            _: session_types.PermissionInvocation,
            _: ?*anyopaque,
        ) !session_types.PermissionDecision {
            return .approve_once;
        }
    }.handle;
    try client.registerPermissionHandler("session-1", .{
        .on_permission_request = handler,
    });

    const parsed_event = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"permission.requested","data":{"requestId":"permission-1","permissionRequest":{"kind":"shell","fullCommandText":"pwd"}}}
    ,
        .{},
    );
    defer parsed_event.deinit();
    try client.events.append(allocator, .{
        .session_id = try allocator.dupe(u8, "session-1"),
        .payload = try deliveryPayloadForTest(
            allocator,
            try session_types.parseEvent(allocator, parsed_event.value),
        ),
    });

    const session = Session{ .client = &client, .id = "session-1" };
    var event = try session.nextEvent();
    defer event.deinit(allocator);
    try std.testing.expect(event == .permission_requested);
    try std.testing.expectEqual(
        error.WriteFailed,
        event.permission_requested.automatic_handling.delivery_failed,
    );
}

fn framedBody(allocator: std.mem.Allocator, framed: []const u8) ![]u8 {
    var reader = std.Io.Reader.fixed(framed);
    return json_rpc.readFrame(allocator, &reader);
}

test "client info maps to connect wire fields" {
    const info = toWireClientInfo(.{
        .application_name = "acme",
        .application_version = "2.4.0",
        .integration_name = "zig",
        .integration_version = "1.0.0",
    }).?;

    try std.testing.expectEqualStrings("acme", info.editorName.?);
    try std.testing.expectEqualStrings("2.4.0", info.editorVersion.?);
    try std.testing.expectEqualStrings("zig", info.extensionName.?);
    try std.testing.expectEqualStrings("1.0.0", info.extensionVersion.?);
    try std.testing.expect(toWireClientInfo(.{}) == null);
}

test "sendAndWait ignores autopilot idle events" {
    var autopilot = "autopilot".*;
    try std.testing.expect(!completesSendAndWait(.{ .mode = &autopilot }));
    try std.testing.expect(completesSendAndWait(.{}));
    var interactive = "interactive".*;
    try std.testing.expect(completesSendAndWait(.{ .mode = &interactive }));
}

test "tool definitions map current wire fields" {
    const allocator = std.testing.allocator;
    var parsed_values: std.ArrayList(std.json.Parsed(std.json.Value)) = .empty;
    defer {
        for (parsed_values.items) |parsed| parsed.deinit();
        parsed_values.deinit(allocator);
    }
    var tools: std.ArrayList(WireTool) = .empty;
    defer tools.deinit(allocator);

    try appendWireTools(
        allocator,
        &.{.{
            .name = "finish",
            .overrides_built_in_tool = true,
            .defer_loading = .never,
            .metadata_json = "{\"acme:priority\":1}",
            .is_terminal = true,
        }},
        &parsed_values,
        &tools,
    );

    try std.testing.expectEqual(@as(usize, 1), tools.items.len);
    try std.testing.expect(tools.items[0].overridesBuiltInTool);
    try std.testing.expectEqual(session_types.ToolLoading.never, tools.items[0].@"defer");
    try std.testing.expect(tools.items[0].metadata.? == .object);
    try std.testing.expect(tools.items[0].isTerminal);
}

test "session lifecycle requests map upstream wire fields" {
    const allocator = std.testing.allocator;
    const abort_encoded = try json_rpc.encodeRequest(
        allocator,
        6,
        "session.abort",
        .{ .sessionId = "session-1" },
    );
    defer allocator.free(abort_encoded);
    const abort_parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        abort_encoded,
        .{},
    );
    defer abort_parsed.deinit();
    try std.testing.expectEqualStrings(
        "session-1",
        abort_parsed.value.object.get("params").?.object.get("sessionId").?.string,
    );

    const model_encoded = try json_rpc.encodeRequest(
        allocator,
        7,
        "session.model.switchTo",
        WireModelSwitchRequest{
            .sessionId = "session-1",
            .modelId = "auto",
            .autoTier = .intelligence,
            .reasoningEffort = "high",
            .reasoningSummary = .detailed,
            .contextTier = .long_context,
            .compactionDecision = "proceed",
            .runCompactionPreflight = true,
        },
    );
    defer allocator.free(model_encoded);
    const model_parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        model_encoded,
        .{},
    );
    defer model_parsed.deinit();
    const model_params = model_parsed.value.object.get("params").?.object;
    try std.testing.expectEqualStrings("session-1", model_params.get("sessionId").?.string);
    try std.testing.expectEqualStrings("auto", model_params.get("modelId").?.string);
    try std.testing.expectEqualStrings("intelligence", model_params.get("autoTier").?.string);
    try std.testing.expectEqualStrings("high", model_params.get("reasoningEffort").?.string);
    try std.testing.expectEqualStrings("detailed", model_params.get("reasoningSummary").?.string);
    try std.testing.expectEqualStrings("long_context", model_params.get("contextTier").?.string);
    try std.testing.expectEqualStrings("proceed", model_params.get("compactionDecision").?.string);
    try std.testing.expect(model_params.get("runCompactionPreflight").?.bool);

    const model_result = try std.json.parseFromSlice(
        session_types.ModelSwitchResult,
        allocator,
        \\{"modelId":"gpt-5.6","status":"confirmation_required","confirmation":{"targetModelDisplayName":"GPT 5.6","currentTokens":16000,"targetLimit":8192},"modelState":{"modelId":"gpt-5.4","reasoningEffort":"high","contextTier":"long_context","autoTier":"balance","pendingAutoTier":null,"activatingAutoTier":"intelligence"}}
    ,
        .{},
    );
    defer model_result.deinit();
    try std.testing.expectEqualStrings(
        "GPT 5.6",
        model_result.value.confirmation.?.targetModelDisplayName,
    );
    try std.testing.expectEqual(@as(f64, 16_000), model_result.value.confirmation.?.currentTokens);
    try std.testing.expectEqual(@as(f64, 8_192), model_result.value.confirmation.?.targetLimit);
    try std.testing.expectEqualStrings("gpt-5.4", model_result.value.modelState.?.modelId.?);
    try std.testing.expectEqual(
        session_types.ContextTier.long_context,
        model_result.value.modelState.?.contextTier.?,
    );
    try std.testing.expectEqual(
        session_types.AutoTier.balance,
        model_result.value.modelState.?.autoTier.?,
    );
    try std.testing.expectEqual(
        session_types.AutoTier.intelligence,
        model_result.value.modelState.?.activatingAutoTier.?,
    );

    const log_encoded = try json_rpc.encodeRequest(
        allocator,
        8,
        "session.log",
        WireLogRequest{
            .sessionId = "session-1",
            .message = "Disk usage is high",
            .level = .warning,
            .type = "system",
            .ephemeral = true,
            .url = "https://example.com/status",
            .tip = "Free some space.",
        },
    );
    defer allocator.free(log_encoded);
    const log_parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        log_encoded,
        .{},
    );
    defer log_parsed.deinit();
    const log_params = log_parsed.value.object.get("params").?.object;
    try std.testing.expectEqualStrings("warning", log_params.get("level").?.string);
    try std.testing.expectEqualStrings("system", log_params.get("type").?.string);
    try std.testing.expect(log_params.get("ephemeral").?.bool);
    try std.testing.expectEqualStrings(
        "https://example.com/status",
        log_params.get("url").?.string,
    );
    try std.testing.expectEqualStrings("Free some space.", log_params.get("tip").?.string);
}

test "create request places the lowered provider in params" {
    const allocator = std.testing.allocator;
    const params = try buildCreateSessionRequest(.{
        .provider = .{
            .base_url = "https://api.openai.com/v1",
            .protocol = .{ .openai = .{ .responses = .websockets } },
            .authentication = .{ .bearer_token = "token" },
        },
    }, &.{});
    const encoded = try json_rpc.encodeRequest(allocator, 9, "session.create", params);
    defer allocator.free(encoded);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("session.create", root.get("method").?.string);
    const provider_value = root.get("params").?.object.get("provider").?.object;
    try std.testing.expectEqualStrings("openai", provider_value.get("type").?.string);
    try std.testing.expectEqualStrings("responses", provider_value.get("wireApi").?.string);
    try std.testing.expectEqualStrings("websockets", provider_value.get("transport").?.string);
    try std.testing.expectEqualStrings("token", provider_value.get("bearerToken").?.string);
}

test "resume request places provider in params and disables nested resume" {
    const allocator = std.testing.allocator;
    const params = try buildResumeSessionRequest("session-1", .{
        .provider = .{
            .base_url = "https://api.anthropic.com",
            .protocol = .anthropic,
            .authentication = .{ .api_key = "key" },
        },
    }, &.{});
    const encoded = try json_rpc.encodeRequest(allocator, 10, "session.resume", params);
    defer allocator.free(encoded);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("session.resume", root.get("method").?.string);
    const request_params = root.get("params").?.object;
    try std.testing.expect(request_params.get("disableResume").?.bool);
    const provider_value = request_params.get("provider").?.object;
    try std.testing.expectEqualStrings("anthropic", provider_value.get("type").?.string);
    try std.testing.expectEqualStrings("key", provider_value.get("apiKey").?.string);
}

test "createSession and joinSession preserve deep partial model capability overrides" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        capabilities: ?models.CapabilitiesOverride,
        wire: []const u8,
    }{
        .{ .capabilities = null, .wire = "" },
        .{ .capabilities = .{}, .wire = ",\"modelCapabilities\":{}" },
        .{
            .capabilities = .{ .supports = .{} },
            .wire = ",\"modelCapabilities\":{\"supports\":{}}",
        },
        .{
            .capabilities = .{ .supports = .{ .vision = true } },
            .wire = ",\"modelCapabilities\":{\"supports\":{\"vision\":true}}",
        },
        .{
            .capabilities = .{ .supports = .{ .vision = false } },
            .wire = ",\"modelCapabilities\":{\"supports\":{\"vision\":false}}",
        },
        .{
            .capabilities = .{ .supports = .{ .reasoningEffort = false, .adaptive_thinking = .optional } },
            .wire = ",\"modelCapabilities\":{\"supports\":{\"reasoningEffort\":false,\"adaptive_thinking\":\"optional\"}}",
        },
        .{
            .capabilities = .{ .limits = .{ .vision = .{ .max_prompt_images = 1 } } },
            .wire = ",\"modelCapabilities\":{\"limits\":{\"vision\":{\"max_prompt_images\":1}}}",
        },
        .{
            .capabilities = .{ .limits = .{ .vision = .{ .supported_media_types = &.{} } } },
            .wire = ",\"modelCapabilities\":{\"limits\":{\"vision\":{\"supported_media_types\":[]}}}",
        },
        .{
            .capabilities = .{
                .supports = .{ .vision = true, .reasoningEffort = true, .adaptive_thinking = .required },
                .limits = .{
                    .max_prompt_tokens = 0,
                    .max_output_tokens = 4096,
                    .max_context_window_tokens = 32768,
                    .vision = .{
                        .supported_media_types = &.{ "image/png", "image/jpeg" },
                        .max_prompt_images = 8,
                        .max_prompt_image_size = 10485760,
                    },
                },
            },
            .wire = ",\"modelCapabilities\":{\"supports\":{\"vision\":true,\"reasoningEffort\":true,\"adaptive_thinking\":\"required\"},\"limits\":{\"max_prompt_tokens\":0,\"max_output_tokens\":4096,\"max_context_window_tokens\":32768,\"vision\":{\"supported_media_types\":[\"image/png\",\"image/jpeg\"],\"max_prompt_images\":8,\"max_prompt_image_size\":10485760}}}",
        },
    };

    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const create_response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"sessionId\":\"created-session\"}}";
        const resume_response = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}";
        const responses = try std.fmt.allocPrint(
            allocator,
            "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}",
            .{ create_response.len, create_response, resume_response.len, resume_response },
        );
        defer allocator.free(responses);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = responses });
        const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{});
        defer response_file.close(std.testing.io);
        var reader_buffer: [1024]u8 = undefined;
        var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
        const request_file = try tmp.dir.createFile(std.testing.io, "requests", .{});
        defer request_file.close(std.testing.io);
        var writer_buffer: [1024]u8 = undefined;
        var writer = request_file.writer(std.testing.io, &writer_buffer);
        var client = Client{
            .allocator = allocator,
            .io = std.testing.io,
            .child = null,
            .reader = &reader,
            .writer = &writer,
            .reader_buffer = &.{},
            .writer_buffer = &.{},
        };
        defer {
            for (client.session_ids.items) |id| allocator.free(id);
            client.session_ids.deinit(allocator);
        }
        const config = session_types.SessionConfig{
            .model = "local-vision-model",
            .provider = .{
                .base_url = "http://localhost:8000/v1",
                .model_id = "local-vision-model",
                .wire_model = "local-vision-model",
            },
            .model_capabilities = case.capabilities,
        };
        const created = try client.createSession(config);
        try std.testing.expectEqualStrings("created-session", created.id);
        const joined = try client.joinSession("existing-session", config);
        try std.testing.expectEqualStrings("existing-session", joined.id);

        var invalid_config = config;
        invalid_config.model_capabilities = .{ .limits = .{ .vision = .{ .max_prompt_images = 0 } } };
        try std.testing.expectError(error.InvalidMaxPromptImages, client.createSession(invalid_config));
        try std.testing.expectError(
            error.InvalidMaxPromptImages,
            client.joinSession("existing-session", invalid_config),
        );

        const requests = try tmp.dir.readFileAlloc(std.testing.io, "requests", allocator, .limited(8192));
        defer allocator.free(requests);
        var frames = std.Io.Reader.fixed(requests);
        const model_and_provider = "\"model\":\"local-vision-model\",\"provider\":{\"type\":\"openai\",\"wireApi\":\"completions\",\"baseUrl\":\"http://localhost:8000/v1\",\"modelId\":\"local-vision-model\",\"wireModel\":\"local-vision-model\"}";
        const defaults = ",\"streaming\":false,\"tools\":[],\"toolFilterPrecedence\":\"excluded\",\"requestPermission\":false,\"requestUserInput\":false,\"enableManagedSettings\":false";
        const expected_create = try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.create\",\"params\":{{{s}{s}{s}}}}}",
            .{ model_and_provider, case.wire, defaults },
        );
        defer allocator.free(expected_create);
        const create_body = try json_rpc.readFrame(allocator, &frames);
        defer allocator.free(create_body);
        try std.testing.expectEqualStrings(expected_create, create_body);
        const expected_resume = try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session.resume\",\"params\":{{\"sessionId\":\"existing-session\",{s}{s}{s},\"disableResume\":true}}}}",
            .{ model_and_provider, case.wire, defaults },
        );
        defer allocator.free(expected_resume);
        const resume_body = try json_rpc.readFrame(allocator, &frames);
        defer allocator.free(resume_body);
        try std.testing.expectEqualStrings(expected_resume, resume_body);
        try std.testing.expectEqualStrings("", frames.buffered());
    }
}

test "session requests enable configured callbacks" {
    const allocator = std.testing.allocator;
    const user_input_handler = struct {
        fn handle(
            inner_allocator: std.mem.Allocator,
            _: session_types.UserInputRequest,
            _: ?*anyopaque,
        ) !session_types.UserInputResponse {
            return .{
                .answer = try inner_allocator.dupe(u8, "Continue"),
                .was_freeform = false,
            };
        }
    }.handle;
    const permission_handler = struct {
        fn handle(
            _: session_types.PermissionRequested,
            _: session_types.PermissionInvocation,
            _: ?*anyopaque,
        ) !session_types.PermissionDecision {
            return .no_result;
        }
    }.handle;

    const create_params = try buildCreateSessionRequest(.{
        .on_permission_request = permission_handler,
        .on_user_input_request = user_input_handler,
    }, &.{});
    const create_encoded = try json_rpc.encodeRequest(
        allocator,
        11,
        "session.create",
        create_params,
    );
    defer allocator.free(create_encoded);
    const create_parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        create_encoded,
        .{},
    );
    defer create_parsed.deinit();
    try std.testing.expect(
        create_parsed.value.object.get("params").?.object.get("requestUserInput").?.bool,
    );
    try std.testing.expect(
        create_parsed.value.object.get("params").?.object.get("requestPermission").?.bool,
    );

    const resume_params = try buildResumeSessionRequest("session-1", .{
        .on_permission_request = permission_handler,
        .on_user_input_request = user_input_handler,
    }, &.{});
    const resume_encoded = try json_rpc.encodeRequest(
        allocator,
        12,
        "session.resume",
        resume_params,
    );
    defer allocator.free(resume_encoded);
    const resume_parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        resume_encoded,
        .{},
    );
    defer resume_parsed.deinit();
    try std.testing.expect(
        resume_parsed.value.object.get("params").?.object.get("requestUserInput").?.bool,
    );
    try std.testing.expect(
        resume_parsed.value.object.get("params").?.object.get("requestPermission").?.bool,
    );
}

test "session requests preserve discovery semantics" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        value: ?bool,
        wire: ?bool,
    }{
        .{ .value = null, .wire = null },
        .{ .value = false, .wire = false },
        .{ .value = true, .wire = true },
    };

    for (cases) |case| {
        const create_encoded = try json_rpc.encodeRequest(
            allocator,
            13,
            "session.create",
            try buildCreateSessionRequest(.{
                .enable_config_discovery = case.value,
                .enable_skills = case.value,
                .skip_custom_instructions = case.value,
                .enable_on_demand_instruction_discovery = case.value,
            }, &.{}),
        );
        defer allocator.free(create_encoded);
        const create_parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            create_encoded,
            .{},
        );
        defer create_parsed.deinit();
        const create_params = create_parsed.value.object.get("params").?.object;

        const resume_encoded = try json_rpc.encodeRequest(
            allocator,
            14,
            "session.resume",
            try buildResumeSessionRequest("session-1", .{
                .enable_config_discovery = case.value,
                .enable_skills = case.value,
                .skip_custom_instructions = case.value,
                .enable_on_demand_instruction_discovery = case.value,
            }, &.{}),
        );
        defer allocator.free(resume_encoded);
        const resume_parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            resume_encoded,
            .{},
        );
        defer resume_parsed.deinit();
        const resume_params = resume_parsed.value.object.get("params").?.object;

        if (case.wire) |expected| {
            try std.testing.expectEqual(
                expected,
                create_params.get("enableConfigDiscovery").?.bool,
            );
            try std.testing.expectEqual(
                expected,
                resume_params.get("enableConfigDiscovery").?.bool,
            );
            try std.testing.expectEqual(
                expected,
                create_params.get("enableSkills").?.bool,
            );
            try std.testing.expectEqual(
                expected,
                resume_params.get("enableSkills").?.bool,
            );
            try std.testing.expectEqual(
                expected,
                create_params.get("skipCustomInstructions").?.bool,
            );
            try std.testing.expectEqual(
                expected,
                resume_params.get("skipCustomInstructions").?.bool,
            );
            try std.testing.expectEqual(
                expected,
                create_params.get("enableOnDemandInstructionDiscovery").?.bool,
            );
            try std.testing.expectEqual(
                expected,
                resume_params.get("enableOnDemandInstructionDiscovery").?.bool,
            );
        } else {
            try std.testing.expect(!create_params.contains("enableConfigDiscovery"));
            try std.testing.expect(!resume_params.contains("enableConfigDiscovery"));
            try std.testing.expect(!create_params.contains("enableSkills"));
            try std.testing.expect(!resume_params.contains("enableSkills"));
            try std.testing.expect(!create_params.contains("skipCustomInstructions"));
            try std.testing.expect(!resume_params.contains("skipCustomInstructions"));
            try std.testing.expect(!create_params.contains("enableOnDemandInstructionDiscovery"));
            try std.testing.expect(!resume_params.contains("enableOnDemandInstructionDiscovery"));
        }
    }
}

test "session requests preserve tool filters with excluded precedence" {
    const allocator = std.testing.allocator;
    const available_tools = &.{ "custom:*", "builtin:ask_user" };
    const excluded_tools = &.{"builtin:web_fetch"};

    const create_encoded = try json_rpc.encodeRequest(
        allocator,
        15,
        "session.create",
        try buildCreateSessionRequest(.{
            .available_tools = available_tools,
            .excluded_tools = excluded_tools,
        }, &.{}),
    );
    defer allocator.free(create_encoded);
    const create_parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        create_encoded,
        .{},
    );
    defer create_parsed.deinit();

    const resume_encoded = try json_rpc.encodeRequest(
        allocator,
        16,
        "session.resume",
        try buildResumeSessionRequest("session-1", .{
            .available_tools = available_tools,
            .excluded_tools = excluded_tools,
        }, &.{}),
    );
    defer allocator.free(resume_encoded);
    const resume_parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        resume_encoded,
        .{},
    );
    defer resume_parsed.deinit();

    for ([_]std.json.ObjectMap{
        create_parsed.value.object.get("params").?.object,
        resume_parsed.value.object.get("params").?.object,
    }) |params| {
        const available = params.get("availableTools").?.array.items;
        try std.testing.expectEqual(@as(usize, 2), available.len);
        try std.testing.expectEqualStrings("custom:*", available[0].string);
        try std.testing.expectEqualStrings("builtin:ask_user", available[1].string);

        const excluded = params.get("excludedTools").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), excluded.len);
        try std.testing.expectEqualStrings("builtin:web_fetch", excluded[0].string);
        try std.testing.expectEqualStrings(
            "excluded",
            params.get("toolFilterPrecedence").?.string,
        );
    }
}

test "session requests preserve explicit discovery directories" {
    const allocator = std.testing.allocator;
    const skill_directories = &.{ ".agents/skills", ".github/skills" };
    const instruction_directories = &.{ ".", ".github/instructions" };

    const create_encoded = try json_rpc.encodeRequest(
        allocator,
        15,
        "session.create",
        try buildCreateSessionRequest(.{
            .skill_directories = skill_directories,
            .instruction_directories = instruction_directories,
        }, &.{}),
    );
    defer allocator.free(create_encoded);
    const create_parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        create_encoded,
        .{},
    );
    defer create_parsed.deinit();
    const create_params = create_parsed.value.object.get("params").?.object;

    const resume_encoded = try json_rpc.encodeRequest(
        allocator,
        16,
        "session.resume",
        try buildResumeSessionRequest("session-1", .{
            .skill_directories = skill_directories,
            .instruction_directories = instruction_directories,
        }, &.{}),
    );
    defer allocator.free(resume_encoded);
    const resume_parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        resume_encoded,
        .{},
    );
    defer resume_parsed.deinit();
    const resume_params = resume_parsed.value.object.get("params").?.object;

    for ([_]std.json.ObjectMap{ create_params, resume_params }) |params| {
        const skills = params.get("skillDirectories").?.array.items;
        try std.testing.expectEqual(@as(usize, 2), skills.len);
        try std.testing.expectEqualStrings(".agents/skills", skills[0].string);
        try std.testing.expectEqualStrings(".github/skills", skills[1].string);

        const instructions = params.get("instructionDirectories").?.array.items;
        try std.testing.expectEqual(@as(usize, 2), instructions.len);
        try std.testing.expectEqualStrings(".", instructions[0].string);
        try std.testing.expectEqualStrings(".github/instructions", instructions[1].string);
    }

    const omitted_create = try json_rpc.encodeRequest(
        allocator,
        17,
        "session.create",
        try buildCreateSessionRequest(.{}, &.{}),
    );
    defer allocator.free(omitted_create);
    const omitted_create_parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        omitted_create,
        .{},
    );
    defer omitted_create_parsed.deinit();
    const omitted_create_params = omitted_create_parsed.value.object.get("params").?.object;

    const omitted_resume = try json_rpc.encodeRequest(
        allocator,
        18,
        "session.resume",
        try buildResumeSessionRequest("session-1", .{}, &.{}),
    );
    defer allocator.free(omitted_resume);
    const omitted_resume_parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        omitted_resume,
        .{},
    );
    defer omitted_resume_parsed.deinit();
    const omitted_resume_params = omitted_resume_parsed.value.object.get("params").?.object;

    for ([_]std.json.ObjectMap{ omitted_create_params, omitted_resume_params }) |params| {
        try std.testing.expect(!params.contains("skillDirectories"));
        try std.testing.expect(!params.contains("instructionDirectories"));
    }
}

test "session requests lower both managed settings sources" {
    const allocator = std.testing.allocator;
    const permission_handler = struct {
        fn handle(
            _: session_types.PermissionRequested,
            _: session_types.PermissionInvocation,
            _: ?*anyopaque,
        ) !session_types.PermissionDecision {
            return .no_result;
        }
    }.handle;
    const config = session_types.SessionConfig{
        .enable_managed_settings = false,
        .managed_settings = .{
            .permissions = .{
                .disable_bypass_permissions_mode = "allow-auto-only",
                .deny = &.{"Shell(git push *)"},
                .ask = &.{"Read(**)"},
                .allow = &.{"Read(src/**)"},
            },
        },
        .on_permission_request = permission_handler,
    };

    try std.testing.expect(managedSettingsEnabled(config));

    const create_encoded = try json_rpc.encodeRequest(
        allocator,
        13,
        "session.create",
        try buildCreateSessionRequest(config, &.{}),
    );
    defer allocator.free(create_encoded);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"session.create\",\"params\":{\"streaming\":false,\"tools\":[],\"toolFilterPrecedence\":\"excluded\",\"requestPermission\":true,\"requestUserInput\":false,\"enableManagedSettings\":false,\"managedSettings\":{\"permissions\":{\"disableBypassPermissionsMode\":\"allow-auto-only\",\"deny\":[\"Shell(git push *)\"],\"ask\":[\"Read(**)\"],\"allow\":[\"Read(src/**)\"]}}}}",
        create_encoded,
    );

    const resume_encoded = try json_rpc.encodeRequest(
        allocator,
        14,
        "session.resume",
        try buildResumeSessionRequest("session-1", config, &.{}),
    );
    defer allocator.free(resume_encoded);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"session.resume\",\"params\":{\"sessionId\":\"session-1\",\"streaming\":false,\"tools\":[],\"toolFilterPrecedence\":\"excluded\",\"requestPermission\":true,\"requestUserInput\":false,\"enableManagedSettings\":false,\"managedSettings\":{\"permissions\":{\"disableBypassPermissionsMode\":\"allow-auto-only\",\"deny\":[\"Shell(git push *)\"],\"ask\":[\"Read(**)\"],\"allow\":[\"Read(src/**)\"]}},\"disableResume\":true}}",
        resume_encoded,
    );

    const fetched_config = session_types.SessionConfig{
        .enable_managed_settings = true,
        .on_permission_request = permission_handler,
    };
    try std.testing.expect(managedSettingsEnabled(fetched_config));

    const fetched_create_encoded = try json_rpc.encodeRequest(
        allocator,
        15,
        "session.create",
        try buildCreateSessionRequest(fetched_config, &.{}),
    );
    defer allocator.free(fetched_create_encoded);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"session.create\",\"params\":{\"streaming\":false,\"tools\":[],\"toolFilterPrecedence\":\"excluded\",\"requestPermission\":true,\"requestUserInput\":false,\"enableManagedSettings\":true}}",
        fetched_create_encoded,
    );

    const fetched_resume_encoded = try json_rpc.encodeRequest(
        allocator,
        16,
        "session.resume",
        try buildResumeSessionRequest("session-1", fetched_config, &.{}),
    );
    defer allocator.free(fetched_resume_encoded);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":16,\"method\":\"session.resume\",\"params\":{\"sessionId\":\"session-1\",\"streaming\":false,\"tools\":[],\"toolFilterPrecedence\":\"excluded\",\"requestPermission\":true,\"requestUserInput\":false,\"enableManagedSettings\":true,\"disableResume\":true}}",
        fetched_resume_encoded,
    );
}

test "session requests omit a null provider" {
    const allocator = std.testing.allocator;
    const create_params = try buildCreateSessionRequest(.{}, &.{});
    const create_encoded = try json_rpc.encodeRequest(
        allocator,
        11,
        "session.create",
        create_params,
    );
    defer allocator.free(create_encoded);

    const create_parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        create_encoded,
        .{},
    );
    defer create_parsed.deinit();
    try std.testing.expect(
        !create_parsed.value.object.get("params").?.object.contains("provider"),
    );

    const resume_params = try buildResumeSessionRequest("session-1", .{}, &.{});
    const resume_encoded = try json_rpc.encodeRequest(
        allocator,
        12,
        "session.resume",
        resume_params,
    );
    defer allocator.free(resume_encoded);

    const resume_parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        resume_encoded,
        .{},
    );
    defer resume_parsed.deinit();
    try std.testing.expect(
        !resume_parsed.value.object.get("params").?.object.contains("provider"),
    );
}

fn validateConnectResult(ok: bool, protocol_version: u64) !void {
    if (!ok) return error.ConnectRejected;
    if (protocol_version != protocol.sdk_protocol_version) return error.ProtocolVersionMismatch;
}

fn exerciseFailureConstructors(allocator: std.mem.Allocator) !void {
    var process = try recordProcessSpawn(allocator, "copilot", error.FileNotFound);
    process.deinit();
    var reentrant = try recordReentrant(allocator, "session.send");
    reentrant.deinit();
    var config = try recordInvalidConfig(allocator, "cli_path", error.InvalidArgument);
    config.deinit();
    var queue = try recordQueueFull(allocator, "session-1", "session.idle", max_queued_events);
    queue.deinit();
    var detach = try recordDetachFailure(allocator, "session-1", 2);
    detach.deinit();
    var permission = try recordPermissionNotAccepted(allocator, "session-1", "request-1");
    permission.deinit();
    var invalid_permission = try recordInvalidPermission(
        allocator,
        "session-1",
        "request-1",
        error.InvalidPermissionDecision,
    );
    invalid_permission.deinit();
    var tool = try recordToolNotAccepted(allocator, "session-1", "request-1");
    tool.deinit();
    var invalid_tool = try recordInvalidToolResult(
        allocator,
        "session-1",
        "request-1",
        error.InvalidToolResult,
    );
    invalid_tool.deinit();

    const response_json =
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"different wording","data":{"errorCode":"session_not_found"}}}
    ;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        response_json,
        .{},
    );
    defer parsed.deinit();
    const rpc_view = switch (validateRpcFailure(
        "session.resume",
        1,
        .{ .session = .{ .session_id = "missing-session" } },
        parsed.value.object.get("error").?,
    )) {
        .valid => |value| value,
        .invalid => return error.TestExpectedRpcFailure,
    };
    var rpc = try recordRpcFailure(allocator, rpc_view);
    rpc.deinit();
    inline for ([_]OperationContext{
        .{ .queue = .{ .session_id = "session-1" } },
        .{ .permission = .{
            .session_id = "session-1",
            .request_id = "permission-1",
        } },
        .{ .tool = .{
            .session_id = "session-1",
            .request_id = "tool-1",
            .tool_call_id = "call-1",
            .tool_name = "lookup",
        } },
    }) |context| {
        const contextual_view = switch (validateRpcFailure(
            "session.operation",
            2,
            context,
            parsed.value.object.get("error").?,
        )) {
            .valid => |value| value,
            .invalid => return error.TestExpectedRpcFailure,
        };
        var contextual = try recordRpcFailure(allocator, contextual_view);
        contextual.deinit();
    }
}

const CensusConstructorCase = enum {
    process_spawn,
    process_exit,
    process_terminate,
    client_io_read,
    client_io_write,
    client_json,
    invalid_config,
    connect_rejected,
    reentrant,
    invalid_envelope,
    invalid_event,
    unexpected_response,
    protocol_mismatch,
    invalid_protocol_version,
    queue_full,
    session_agent,
    session_detach,
    permission_invalid,
    permission_handler,
    permission_not_accepted,
    tool_invalid,
    tool_handler,
    tool_not_accepted,
    rpc_generic,
    rpc_session_missing,
    rpc_session,
    rpc_queue,
    rpc_permission,
    rpc_tool,
};

fn recordRpcConstructorCase(
    allocator: std.mem.Allocator,
    context: OperationContext,
    missing_session: bool,
) !errors.Failure {
    const body = if (missing_session)
        \\{"code":-32001,"message":"missing","data":{"errorCode":"session_not_found"}}
    else
        \\{"code":-32077,"message":"rejected","data":{"errorCode":"rejected"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const view = switch (validateRpcFailure("test.method", 17, context, parsed.value)) {
        .valid => |value| value,
        .invalid => return error.TestExpectedRpcFailure,
    };
    return recordRpcFailure(allocator, view);
}

fn makeCensusFailure(
    allocator: std.mem.Allocator,
    case: CensusConstructorCase,
) !errors.Failure {
    return switch (case) {
        .process_spawn => recordProcessSpawn(allocator, "copilot", error.FileNotFound),
        .process_exit => recordProcessExit(allocator, .{ .exited = 7 }),
        .process_terminate => recordProcessTerminate(
            allocator,
            .{ .signal = 15 },
            error.AccessDenied,
        ),
        .client_io_read => recordClientIo(allocator, .read, error.ReadFailed),
        .client_io_write => recordClientIo(allocator, .write, error.BrokenPipe),
        .client_json => recordClientJson(allocator, .write, error.InvalidJson),
        .invalid_config => recordInvalidConfig(allocator, "cli_path", error.InvalidArgument),
        .connect_rejected => recordConnectRejected(allocator),
        .reentrant => recordReentrant(allocator, "session.send"),
        .invalid_envelope => blk: {
            const parsed = try std.json.parseFromSlice(
                std.json.Value,
                allocator,
                \\{"jsonrpc":"2.0","result":{}}
            ,
                .{},
            );
            defer parsed.deinit();
            break :blk recordEnvelope(allocator, .missing_id, parsed.value);
        },
        .invalid_event => blk: {
            const parsed = try std.json.parseFromSlice(
                std.json.Value,
                allocator,
                \\{"jsonrpc":"2.0","method":"session.event"}
            ,
                .{},
            );
            defer parsed.deinit();
            break :blk recordInvalidEnvelope(
                allocator,
                error.InvalidJsonRpc,
                .missing_params,
                parsed.value,
            );
        },
        .unexpected_response => recordUnexpectedResponse(allocator, 17, .{ .integer = 18 }),
        .protocol_mismatch => recordProtocolMismatch(allocator, 99),
        .invalid_protocol_version => recordInvalidProtocolVersion(allocator, .{ .string = "bad" }),
        .queue_full => recordQueueFull(allocator, "session-1", "session.idle", max_queued_events),
        .session_agent => sessionFailureFromFrame(allocator, try allocator.dupe(u8, "session-1"),
            \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"session-1","event":{"type":"session.error","data":{"errorType":"provider","message":"Try later","statusCode":429}}}}
        ),
        .session_detach => recordDetachFailure(allocator, "session-1", 2),
        .permission_invalid => recordInvalidPermission(
            allocator,
            "session-1",
            "request-1",
            error.InvalidPermissionDecision,
        ),
        .permission_handler => recordPermissionHandlerFailure(
            allocator,
            "session-1",
            "request-1",
            error.HandlerFailed,
        ),
        .permission_not_accepted => recordPermissionNotAccepted(
            allocator,
            "session-1",
            "request-1",
        ),
        .tool_invalid => recordInvalidToolResult(
            allocator,
            "session-1",
            "request-1",
            error.InvalidToolResult,
        ),
        .tool_handler => recordToolHandlerFailure(
            allocator,
            "session-1",
            "request-1",
            "call-1",
            "lookup",
            error.HandlerFailed,
        ),
        .tool_not_accepted => recordToolNotAccepted(allocator, "session-1", "request-1"),
        .rpc_generic => recordRpcConstructorCase(allocator, .generic, false),
        .rpc_session_missing => recordRpcConstructorCase(
            allocator,
            .{ .session = .{ .session_id = "session-1" } },
            true,
        ),
        .rpc_session => recordRpcConstructorCase(
            allocator,
            .{ .session = .{ .session_id = "session-1" } },
            false,
        ),
        .rpc_queue => recordRpcConstructorCase(
            allocator,
            .{ .queue = .{ .session_id = "session-1" } },
            false,
        ),
        .rpc_permission => recordRpcConstructorCase(
            allocator,
            .{ .permission = .{
                .session_id = "session-1",
                .request_id = "request-1",
            } },
            false,
        ),
        .rpc_tool => recordRpcConstructorCase(
            allocator,
            .{ .tool = .{
                .session_id = "session-1",
                .request_id = "request-1",
                .tool_call_id = "call-1",
                .tool_name = "lookup",
            } },
            false,
        ),
    };
}

test "failure constructors classify owned literal fields and deinit" {
    std.debug.print("\nCENSUS_PROBE failure_constructor_ownership\n", .{});
    const cases = [_]struct {
        case: CensusConstructorCase,
        expected: errors.SdkError,
    }{
        .{ .case = .process_spawn, .expected = error.ClientFailure },
        .{ .case = .process_exit, .expected = error.ProcessExited },
        .{ .case = .process_terminate, .expected = error.ClientFailure },
        .{ .case = .client_io_read, .expected = error.ClientFailure },
        .{ .case = .client_io_write, .expected = error.ClientFailure },
        .{ .case = .client_json, .expected = error.ClientFailure },
        .{ .case = .invalid_config, .expected = error.ClientFailure },
        .{ .case = .connect_rejected, .expected = error.ClientFailure },
        .{ .case = .reentrant, .expected = error.ClientFailure },
        .{ .case = .invalid_envelope, .expected = error.ProtocolFailure },
        .{ .case = .invalid_event, .expected = error.ProtocolFailure },
        .{ .case = .unexpected_response, .expected = error.ProtocolFailure },
        .{ .case = .protocol_mismatch, .expected = error.ProtocolMismatch },
        .{ .case = .invalid_protocol_version, .expected = error.ProtocolMismatch },
        .{ .case = .queue_full, .expected = error.QueueFailure },
        .{ .case = .session_agent, .expected = error.SessionFailure },
        .{ .case = .session_detach, .expected = error.SessionFailure },
        .{ .case = .permission_invalid, .expected = error.PermissionFailure },
        .{ .case = .permission_handler, .expected = error.PermissionFailure },
        .{ .case = .permission_not_accepted, .expected = error.PermissionFailure },
        .{ .case = .tool_invalid, .expected = error.ToolFailure },
        .{ .case = .tool_handler, .expected = error.ToolFailure },
        .{ .case = .tool_not_accepted, .expected = error.ToolFailure },
        .{ .case = .rpc_generic, .expected = error.RpcRejected },
        .{ .case = .rpc_session_missing, .expected = error.SessionNotFound },
        .{ .case = .rpc_session, .expected = error.RpcRejected },
        .{ .case = .rpc_queue, .expected = error.QueueFailure },
        .{ .case = .rpc_permission, .expected = error.PermissionFailure },
        .{ .case = .rpc_tool, .expected = error.ToolFailure },
    };
    for (cases) |case| {
        var failure = try makeCensusFailure(std.testing.allocator, case.case);
        defer failure.deinit();
        try std.testing.expectEqual(case.expected, failure.errorTag());
    }
}

test "process terminate and client write constructors own fields and deinit" {
    std.debug.print("\nCENSUS_PROBE process_write_ownership\n", .{});
    var terminate = try recordProcessTerminate(
        std.testing.allocator,
        .{ .signal = 15 },
        error.AccessDenied,
    );
    defer terminate.deinit();
    switch (terminate.detail) {
        .process => |process_failure| switch (process_failure) {
            .terminate => |detail| {
                try std.testing.expectEqualStrings("AccessDenied", detail.message);
                try std.testing.expectEqual(error.AccessDenied, detail.cause.code);
                switch (detail.exit.?) {
                    .signal => |signal| try std.testing.expectEqual(@as(u32, 15), signal),
                    else => return error.TestExpectedSignalExit,
                }
            },
            else => return error.TestExpectedTerminateFailure,
        },
        else => return error.TestExpectedProcessFailure,
    }

    var write = try recordClientIo(std.testing.allocator, .write, error.BrokenPipe);
    defer write.deinit();
    switch (write.detail) {
        .client => |client_failure| switch (client_failure) {
            .io => |detail| {
                try std.testing.expectEqual(errors.ClientOperation.write, detail.operation);
                try std.testing.expectEqualStrings("BrokenPipe", detail.message);
                try std.testing.expectEqual(error.BrokenPipe, detail.cause.code);
            },
            else => return error.TestExpectedIoFailure,
        },
        else => return error.TestExpectedClientFailure,
    }
}

test "failure constructors roll back every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseFailureConstructors,
        .{},
    );
}

fn exerciseSessionFailureFromFrame(allocator: std.mem.Allocator) !void {
    const session_id = try allocator.dupe(u8, "session-1");
    const frame =
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"session-1","event":{"type":"session.error","data":{"errorType":"provider","errorCode":"rate_limited","message":"Try later","statusCode":429,"providerCallId":"provider-1","serviceRequestId":"service-1","remediation":{"retryAfter":30},"url":"https://example.test/help","stack":"trace","eligibleForAutoSwitch":true}}}}
    ;

    var failure = try sessionFailureFromFrame(allocator, session_id, frame);
    defer failure.deinit();

    const agent = switch (failure.detail) {
        .session => |session_failure| switch (session_failure) {
            .agent => |value| value,
            else => return error.TestExpectedSessionAgentFailure,
        },
        else => return error.TestExpectedSessionAgentFailure,
    };
    try std.testing.expectEqual(error.CopilotSessionError, failure.native_error);
    try std.testing.expectEqualStrings("session-1", agent.session_id);
    try std.testing.expectEqualStrings("provider", agent.error_type);
    try std.testing.expectEqualStrings("rate_limited", agent.error_code.?);
    try std.testing.expectEqualStrings("Try later", agent.message);
    try std.testing.expectEqual(@as(?u16, 429), agent.status_code);
    try std.testing.expectEqualStrings("provider-1", agent.provider_call_id.?);
    try std.testing.expectEqualStrings("service-1", agent.service_request_id.?);
    try std.testing.expectEqualStrings("{\"retryAfter\":30}", agent.remediation_json.?);
    try std.testing.expectEqualStrings("https://example.test/help", agent.url.?);
    try std.testing.expectEqualStrings("trace", agent.stack.?);
    try std.testing.expectEqual(@as(?bool, true), agent.eligible_for_auto_switch);
}

fn deliveryPayloadForTest(
    allocator: std.mem.Allocator,
    event: session_types.SessionEvent,
) !EventDelivery.Payload {
    return switch (event) {
        .assistant_message => |value| .{ .assistant_message = value },
        .assistant_message_delta => |value| .{ .assistant_message_delta = value },
        .assistant_reasoning => |value| .{ .assistant_reasoning = value },
        .assistant_reasoning_delta => |value| .{ .assistant_reasoning_delta = value },
        .session_idle => |value| .{ .session_idle = value },
        .session_error => {
            var owned = event;
            owned.deinit(allocator);
            return error.TestExpectedNonErrorDelivery;
        },
        .permission_requested => |value| .{ .permission_requested = value },
        .external_tool_requested => |value| .{ .external_tool_requested = value },
        .unknown => |value| .{ .unknown = value },
    };
}

test "session failure conversion rolls back every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseSessionFailureFromFrame,
        .{},
    );
}

test "legacy delivery preserves the public session error" {
    const allocator = std.testing.allocator;
    var delivery = EventDelivery{
        .session_id = try allocator.dupe(u8, "session-1"),
        .payload = .{ .session_error = .{
            .event = .{ .message = try allocator.dupe(u8, "Try later") },
            .diagnostic_frame = try allocator.dupe(u8,
                \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"session-1","event":{"type":"session.error","data":{"errorType":"provider","message":"Try later"}}}}
            ),
        } },
    };
    var event = delivery.intoEvent(allocator);
    defer event.deinit(allocator);

    try std.testing.expect(event == .session_error);
    try std.testing.expectEqualStrings("Try later", event.session_error.message);
}

test "connect validates the protocol version" {
    std.debug.print("\nCENSUS_PROBE protocol_version_dispatch\n", .{});
    try validateConnectResult(true, protocol.sdk_protocol_version);
    try std.testing.expectError(
        error.ConnectRejected,
        validateConnectResult(false, protocol.sdk_protocol_version),
    );
    try std.testing.expectError(
        error.ProtocolVersionMismatch,
        validateConnectResult(true, protocol.sdk_protocol_version + 1),
    );
}

test "connect rejection preserves legacy and detailed classification" {
    std.debug.print("\nCENSUS_PROBE connect_rejection_dispatch\n", .{});
    const allocator = std.testing.allocator;
    const body =
        \\{"jsonrpc":"2.0","id":1,"result":{"ok":false,"protocolVersion":1,"version":"test"}}
    ;
    const frame = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );
    defer allocator.free(frame);

    inline for (.{ FailurePolicy.legacy, FailurePolicy.detailed }) |policy| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "response", .data = frame });
        const response_file = try tmp.dir.openFile(std.testing.io, "response", .{});
        defer response_file.close(std.testing.io);
        var reader_buffer: [512]u8 = undefined;
        var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
        const request_file = try tmp.dir.createFile(std.testing.io, "request", .{});
        defer request_file.close(std.testing.io);
        var writer_buffer: [512]u8 = undefined;
        var writer = request_file.writer(std.testing.io, &writer_buffer);
        var client = Client{
            .allocator = allocator,
            .io = std.testing.io,
            .child = null,
            .reader = &reader,
            .writer = &writer,
            .reader_buffer = &.{},
            .writer_buffer = &.{},
        };

        if (policy == .legacy) {
            switch (try client.connect(.legacy, null, null)) {
                .success => return error.TestExpectedClientFailure,
                .failure => |failure| try std.testing.expectEqual(
                    error.ConnectRejected,
                    failure.native_error,
                ),
            }
        } else {
            var failure = switch (try client.connect(.detailed, null, null)) {
                .success => return error.TestExpectedClientFailure,
                .failure => |value| value,
            };
            defer failure.deinit();
            try std.testing.expectEqual(error.ConnectRejected, failure.native_error);
            try std.testing.expectEqual(error.ClientFailure, failure.errorTag());
            const invalid = switch (failure.detail) {
                .client => |client_failure| switch (client_failure) {
                    .invalid_config => |value| value,
                    else => return error.TestExpectedInvalidConfig,
                },
                else => return error.TestExpectedClientFailure,
            };
            try std.testing.expect(invalid.field == null);
            try std.testing.expectEqualStrings("Copilot CLI rejected the connection", invalid.message);
        }
    }
}

test "typed RPC results allow additional fields" {
    const allocator = std.testing.allocator;
    const result_json = try allocator.dupe(u8,
        \\{"sessionId":"s1","workspacePath":"/tmp/workspace"}
    );
    const parsed = try std.json.parseFromSlice(
        struct { sessionId: []const u8 },
        allocator,
        result_json,
        .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        },
    );
    defer parsed.deinit();
    allocator.free(result_json);
    try std.testing.expectEqualStrings("s1", parsed.value.sessionId);
}

test "session.event notifications queue by session" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = undefined,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer {
        for (client.events.items) |*event| event.deinit(allocator);
        client.events.deinit(allocator);
        for (client.tools.items) |tool| tool.deinit(allocator);
        client.tools.deinit(allocator);
    }

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"sessionId":"s1","event":{"type":"assistant.message","data":{"content":"hello","messageId":"m1"}}}
    ,
        .{},
    );
    defer parsed.deinit();
    const frame = try allocator.dupe(u8, "{}");
    switch (try client.queueSessionEvent(.detailed, frame, parsed.value)) {
        .success => |retained| if (!retained) allocator.free(frame),
        .failure => |failure_value| {
            allocator.free(frame);
            var failure = failure_value;
            defer failure.deinit();
            return error.TestUnexpectedFailure;
        },
    }

    try std.testing.expectEqual(@as(usize, 1), client.events.items.len);
    try std.testing.expectEqualStrings("s1", client.events.items[0].session_id);
    try std.testing.expectEqualStrings(
        "hello",
        client.events.items[0].payload.assistant_message.content,
    );
}

test "disconnect removes session-owned allocations" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = undefined,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer {
        for (client.events.items) |*event| event.deinit(allocator);
        client.events.deinit(allocator);
        for (client.tools.items) |tool| tool.deinit(allocator);
        client.tools.deinit(allocator);
        for (client.session_ids.items) |id| allocator.free(id);
        client.session_ids.deinit(allocator);
    }

    const session_id = try allocator.dupe(u8, "s1");
    try client.session_ids.append(allocator, session_id);
    try client.events.append(allocator, .{
        .session_id = try allocator.dupe(u8, "s1"),
        .payload = .{ .session_idle = .{} },
    });

    client.removeSession("s1");

    try std.testing.expectEqual(@as(usize, 0), client.session_ids.items.len);
    try std.testing.expectEqual(@as(usize, 0), client.events.items.len);
}

test "session event queue has a fixed bound" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = undefined,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer {
        for (client.events.items) |*event| event.deinit(allocator);
        client.events.deinit(allocator);
        for (client.tools.items) |tool| tool.deinit(allocator);
        client.tools.deinit(allocator);
    }

    try client.events.ensureTotalCapacity(allocator, max_queued_events);
    for (0..max_queued_events) |_| {
        try client.events.append(allocator, .{
            .session_id = try allocator.dupe(u8, "s1"),
            .payload = .{ .session_idle = .{} },
        });
    }

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"sessionId":"s1","event":{"type":"session.idle","data":{}}}
    ,
        .{},
    );
    defer parsed.deinit();

    const frame = try allocator.dupe(u8, "{}");
    defer allocator.free(frame);
    var failure = switch (try client.queueSessionEvent(.detailed, frame, parsed.value)) {
        .success => return error.TestExpectedQueueFailure,
        .failure => |value| value,
    };
    defer failure.deinit();
    try std.testing.expectEqual(error.EventQueueFull, failure.native_error);
    switch (failure.detail) {
        .queue => |queue_failure| switch (queue_failure) {
            .full => |full| {
                try std.testing.expectEqualStrings("s1", full.session_id.?);
                try std.testing.expectEqualStrings("session.idle", full.event_type.?);
                try std.testing.expectEqual(max_queued_events, full.length);
                try std.testing.expectEqual(max_queued_events, full.capacity);
            },
            else => return error.TestExpectedQueueFull,
        },
        else => return error.TestExpectedQueueFailure,
    }
}

test "legacy nextEvent preserves EventQueueFull" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const session_event =
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"session-1","event":{"type":"session.idle","data":{}}}}
    ;
    const response_frame = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}",
        .{ session_event.len, session_event },
    );
    defer allocator.free(response_frame);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "response", .data = response_frame });
    const response_file = try tmp.dir.openFile(std.testing.io, "response", .{});
    defer response_file.close(std.testing.io);
    var reader_buffer: [1024]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
    const request_file = try tmp.dir.createFile(std.testing.io, "request", .{});
    defer request_file.close(std.testing.io);
    var writer_buffer: [1024]u8 = undefined;
    var writer = request_file.writer(std.testing.io, &writer_buffer);
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = &reader,
        .writer = &writer,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer {
        for (client.events.items) |*event| event.deinit(allocator);
        client.events.deinit(allocator);
    }

    try client.events.ensureTotalCapacity(allocator, max_queued_events);
    for (0..max_queued_events) |_| {
        try client.events.append(allocator, .{
            .session_id = try allocator.dupe(u8, "session-2"),
            .payload = .{ .session_idle = .{} },
        });
    }

    try std.testing.expectError(
        error.EventQueueFull,
        (Session{ .client = &client, .id = "session-1" }).nextEvent(),
    );
}

test "public RPC capture owns a specialized queue rejection" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const response_body =
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32042,"message":"queue already paused","data":{"code":"queue_already_paused","retryable":false}}}
    ;
    const response_frame = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}",
        .{ response_body.len, response_body },
    );
    defer allocator.free(response_frame);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "response", .data = response_frame });
    const response_file = try tmp.dir.openFile(std.testing.io, "response", .{});
    var reader_buffer: [1024]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
    const request_file = try tmp.dir.createFile(std.testing.io, "request", .{});
    var writer_buffer: [1024]u8 = undefined;
    var writer = request_file.writer(std.testing.io, &writer_buffer);
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = &reader,
        .writer = &writer,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    var failure = switch (try client.callImpl(
        .detailed,
        std.json.Value,
        "session.queue.setDrainPaused",
        .{ .sessionId = "session-owned", .paused = true },
        .{ .queue = .{ .session_id = "session-owned" } },
    )) {
        .success => |value| {
            value.deinit();
            return error.TestExpectedQueueFailure;
        },
        .failure => |value| value,
    };
    response_file.close(std.testing.io);
    request_file.close(std.testing.io);

    defer failure.deinit();
    try std.testing.expectEqual(error.QueueFailure, failure.errorTag());
    try std.testing.expectEqualStrings("queue_already_paused", failure.machineCode().?);
    switch (failure.detail) {
        .queue => |queue_failure| switch (queue_failure) {
            .rejected => |rejected| {
                try std.testing.expectEqual(@as(i64, -32042), rejected.code);
                try std.testing.expectEqual(@as(u64, 1), rejected.request_id);
                try std.testing.expectEqualStrings(
                    "{\"code\":\"queue_already_paused\",\"retryable\":false}",
                    rejected.data_json.?,
                );
                switch (rejected.context) {
                    .queue => |context| try std.testing.expectEqualStrings(
                        "session-owned",
                        context.session_id,
                    ),
                    else => return error.TestExpectedQueueContext,
                }
            },
            else => return error.TestExpectedQueueRejection,
        },
        else => return error.TestExpectedQueueFailure,
    }
}

test "public RPC without a capture returns the typed error tag" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const response_body =
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"method not found","data":{"code":"missing_method"}}}
    ;
    const response_frame = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}",
        .{ response_body.len, response_body },
    );
    defer allocator.free(response_frame);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "response", .data = response_frame });
    const response_file = try tmp.dir.openFile(std.testing.io, "response", .{});
    defer response_file.close(std.testing.io);
    var reader_buffer: [1024]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
    const request_file = try tmp.dir.createFile(std.testing.io, "request", .{});
    defer request_file.close(std.testing.io);
    var writer_buffer: [1024]u8 = undefined;
    var writer = request_file.writer(std.testing.io, &writer_buffer);
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = &reader,
        .writer = &writer,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };

    try std.testing.expectError(
        error.JsonRpcError,
        client.callRpc(std.json.Value, "unknown.method", .{}),
    );
}

fn callLegacyRpcFromBody(
    allocator: std.mem.Allocator,
    response_body: []const u8,
) !std.json.Parsed(std.json.Value) {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const response_frame = try std.fmt.allocPrint(
        std.testing.allocator,
        "Content-Length: {d}\r\n\r\n{s}",
        .{ response_body.len, response_body },
    );
    defer std.testing.allocator.free(response_frame);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "response", .data = response_frame });
    const response_file = try tmp.dir.openFile(std.testing.io, "response", .{});
    defer response_file.close(std.testing.io);
    var reader_buffer: [1024]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
    const request_file = try tmp.dir.createFile(std.testing.io, "request", .{});
    defer request_file.close(std.testing.io);
    var writer_buffer: [1024]u8 = undefined;
    var writer = request_file.writer(std.testing.io, &writer_buffer);
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = &reader,
        .writer = &writer,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };

    return client.callRpc(std.json.Value, "test.invalidRpcError", .{});
}

test "public RPC preserves malformed error envelope errors" {
    const response_body =
        \\{"jsonrpc":"2.0","id":1,"error":{"message":"missing code"}}
    ;
    try std.testing.expectError(
        error.InvalidJsonRpc,
        callLegacyRpcFromBody(std.testing.allocator, response_body),
    );

    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    try std.testing.expectError(
        error.InvalidJsonRpc,
        callLegacyRpcFromBody(counting.allocator(), response_body),
    );
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = counting.alloc_index,
    });
    try std.testing.expectError(
        error.InvalidJsonRpc,
        callLegacyRpcFromBody(failing.allocator(), response_body),
    );
    try std.testing.expect(!failing.has_induced_failure);
}

fn detailedRpcFailureFromFrame(
    allocator: std.mem.Allocator,
    frame: []const u8,
) !errors.Failure {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "response", .data = frame });
    const response_file = try tmp.dir.openFile(std.testing.io, "response", .{});
    defer response_file.close(std.testing.io);
    var reader_buffer: [2048]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
    const request_file = try tmp.dir.createFile(std.testing.io, "request", .{});
    defer request_file.close(std.testing.io);
    var writer_buffer: [1024]u8 = undefined;
    var writer = request_file.writer(std.testing.io, &writer_buffer);
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = &reader,
        .writer = &writer,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    return switch (try client.callRpcDetailed(std.json.Value, "test.method", .{})) {
        .success => |value| {
            value.deinit();
            return error.TestExpectedFailure;
        },
        .failure => |failure| failure,
    };
}

test "detailed RPC and malformed frame failures own literal payloads" {
    std.debug.print("\nCENSUS_PROBE unexpected_response_dispatch\n", .{});
    const allocator = std.testing.allocator;
    const response_body =
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32042,"message":"rejected","data":{"code":"denied"}}}
    ;
    const response_frame = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}",
        .{ response_body.len, response_body },
    );
    defer allocator.free(response_frame);

    var rpc_failure = try detailedRpcFailureFromFrame(allocator, response_frame);
    defer rpc_failure.deinit();
    try std.testing.expectEqual(error.JsonRpcError, rpc_failure.native_error);
    switch (rpc_failure.detail) {
        .rpc => |rpc| {
            try std.testing.expectEqualStrings("test.method", rpc.method);
            try std.testing.expectEqual(@as(i64, -32042), rpc.code);
            try std.testing.expectEqualStrings("denied", rpc.machine_code.?);
            try std.testing.expectEqualStrings("{\"code\":\"denied\"}", rpc.data_json.?);
        },
        else => return error.TestExpectedRpcFailure,
    }

    var frame_failure = try detailedRpcFailureFromFrame(
        allocator,
        "Content-Length: nope\r\n\r\n",
    );
    defer frame_failure.deinit();
    try std.testing.expectEqual(error.InvalidCharacter, frame_failure.native_error);
    switch (frame_failure.detail) {
        .protocol => |protocol_failure| switch (protocol_failure) {
            .invalid_content_length => |invalid| {
                try std.testing.expectEqualStrings("nope", invalid.value);
            },
            else => return error.TestExpectedInvalidContentLength,
        },
        else => return error.TestExpectedProtocolFailure,
    }
}

test "joinSessionDetailed retains the missing session id" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const response_body =
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"missing","data":{"errorCode":"session_not_found"}}}
    ;
    const response_frame = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}",
        .{ response_body.len, response_body },
    );
    defer allocator.free(response_frame);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "response", .data = response_frame });
    const response_file = try tmp.dir.openFile(std.testing.io, "response", .{});
    defer response_file.close(std.testing.io);
    var reader_buffer: [2048]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
    const request_file = try tmp.dir.createFile(std.testing.io, "request", .{});
    defer request_file.close(std.testing.io);
    var writer_buffer: [1024]u8 = undefined;
    var writer = request_file.writer(std.testing.io, &writer_buffer);
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = &reader,
        .writer = &writer,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };

    var failure = switch (try client.joinSessionDetailed("missing-session", .{})) {
        .success => return error.TestExpectedFailure,
        .failure => |failure| failure,
    };
    defer failure.deinit();
    try std.testing.expectEqual(error.JsonRpcError, failure.native_error);
    switch (failure.detail) {
        .session => |detail| switch (detail) {
            .not_found => |not_found| {
                try std.testing.expectEqualStrings("missing-session", not_found.session_id);
                try std.testing.expectEqualStrings(
                    "session_not_found",
                    not_found.rpc.machine_code.?,
                );
            },
            else => return error.TestExpectedSessionNotFound,
        },
        else => return error.TestExpectedSessionFailure,
    }
}

fn invalidPermissionDetailedFailure(allocator: std.mem.Allocator) !errors.Failure {
    var client = Client{
        .allocator = allocator,
        .io = undefined,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    const session = Session{ .client = &client, .id = "owned-session" };
    return switch (try session.respondToPermissionJsonDetailed(
        "owned-request",
        "[]",
        null,
    )) {
        .success => return error.TestExpectedFailure,
        .failure => |failure| failure,
    };
}

const DetailedDeliveryKind = enum { permission, tool };

fn detailedDeliveryFailure(
    allocator: std.mem.Allocator,
    kind: DetailedDeliveryKind,
    response_body: []const u8,
) !errors.Failure {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const response_frame = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}",
        .{ response_body.len, response_body },
    );
    defer allocator.free(response_frame);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "response", .data = response_frame });
    const response_file = try tmp.dir.openFile(std.testing.io, "response", .{});
    defer response_file.close(std.testing.io);
    var reader_buffer: [2048]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
    const request_file = try tmp.dir.createFile(std.testing.io, "request", .{});
    defer request_file.close(std.testing.io);
    var writer_buffer: [1024]u8 = undefined;
    var writer = request_file.writer(std.testing.io, &writer_buffer);
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = &reader,
        .writer = &writer,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    const session = Session{ .client = &client, .id = "session-owned" };
    const result = switch (kind) {
        .permission => try session.respondToPermissionJsonDetailed(
            "request-owned",
            "{\"kind\":\"approve-once\"}",
            null,
        ),
        .tool => try session.respondToToolResultJsonDetailed(
            "request-owned",
            "{\"textResultForLlm\":\"done\",\"resultType\":\"success\"}",
        ),
    };
    return switch (result) {
        .success => return error.TestExpectedFailure,
        .failure => |failure| failure,
    };
}

test "detailed failure ownership survives its source client" {
    var failure = try invalidPermissionDetailedFailure(std.testing.allocator);
    defer failure.deinit();
    try std.testing.expectEqual(error.InvalidPermissionDecision, failure.native_error);
    switch (failure.detail) {
        .permission => |permission_detail| switch (permission_detail) {
            .invalid_decision => |invalid| {
                try std.testing.expectEqualStrings("owned-session", invalid.session_id);
                try std.testing.expectEqualStrings("owned-request", invalid.request_id);
            },
            else => return error.TestExpectedInvalidPermission,
        },
        else => return error.TestExpectedPermissionFailure,
    }
}

test "detailed permission and tool delivery failures retain operation context" {
    std.debug.print("\nCENSUS_PROBE permission_tool_delivery_behavior\n", .{});
    const rpc_error =
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32042,"message":"delivery rejected","data":{"code":"delivery_denied"}}}
    ;
    inline for ([_]DetailedDeliveryKind{ .permission, .tool }) |kind| {
        var failure = try detailedDeliveryFailure(std.testing.allocator, kind, rpc_error);
        defer failure.deinit();
        try std.testing.expectEqual(error.JsonRpcError, failure.native_error);
        switch (kind) {
            .permission => switch (failure.detail) {
                .permission => |detail| switch (detail) {
                    .delivery_failed => |delivery| {
                        try std.testing.expectEqualStrings(
                            "delivery_denied",
                            delivery.machine_code.?,
                        );
                        switch (delivery.context) {
                            .permission => |context| {
                                try std.testing.expectEqualStrings("session-owned", context.session_id);
                                try std.testing.expectEqualStrings("request-owned", context.request_id);
                            },
                            else => return error.TestExpectedPermissionContext,
                        }
                    },
                    else => return error.TestExpectedPermissionDeliveryFailure,
                },
                else => return error.TestExpectedPermissionFailure,
            },
            .tool => switch (failure.detail) {
                .tool => |detail| switch (detail) {
                    .delivery_failed => |delivery| {
                        try std.testing.expectEqualStrings(
                            "delivery_denied",
                            delivery.machine_code.?,
                        );
                        switch (delivery.context) {
                            .tool => |context| {
                                try std.testing.expectEqualStrings("session-owned", context.session_id);
                                try std.testing.expectEqualStrings("request-owned", context.request_id);
                            },
                            else => return error.TestExpectedToolContext,
                        }
                    },
                    else => return error.TestExpectedToolDeliveryFailure,
                },
                else => return error.TestExpectedToolFailure,
            },
        }
    }
}

test "direct permission and tool validation failures retain request context" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = undefined,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    const session = Session{ .client = &client, .id = "session-1" };

    var permission_failure = switch (try session.respondToPermissionJsonDetailed(
        "permission-1",
        "[]",
        null,
    )) {
        .success => return error.TestExpectedPermissionFailure,
        .failure => |failure| failure,
    };
    defer permission_failure.deinit();
    try std.testing.expectEqual(
        error.InvalidPermissionDecision,
        permission_failure.native_error,
    );
    switch (permission_failure.detail) {
        .permission => |permission_detail| switch (permission_detail) {
            .invalid_decision => |invalid| {
                try std.testing.expectEqualStrings("session-1", invalid.session_id);
                try std.testing.expectEqualStrings("permission-1", invalid.request_id);
                try std.testing.expectEqual(
                    error.InvalidPermissionDecision,
                    invalid.cause.?.code,
                );
            },
            else => return error.TestExpectedInvalidPermission,
        },
        else => return error.TestExpectedPermissionFailure,
    }

    var tool_failure = switch (try session.respondToToolResultJsonDetailed(
        "tool-request-1",
        "{}",
    )) {
        .success => return error.TestExpectedToolFailure,
        .failure => |failure| failure,
    };
    defer tool_failure.deinit();
    try std.testing.expectEqual(error.InvalidToolResult, tool_failure.native_error);
    switch (tool_failure.detail) {
        .tool => |tool_detail| switch (tool_detail) {
            .invalid_result => |invalid| {
                try std.testing.expectEqualStrings("session-1", invalid.session_id);
                try std.testing.expectEqualStrings("tool-request-1", invalid.request_id);
                try std.testing.expectEqual(error.InvalidToolResult, invalid.cause.?.code);
            },
            else => return error.TestExpectedInvalidToolResult,
        },
        else => return error.TestExpectedToolFailure,
    }
}

fn expectDetailedCallFailure(
    allocator: std.mem.Allocator,
    response_body: []const u8,
    method: []const u8,
) !errors.Failure {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const response_frame = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}",
        .{ response_body.len, response_body },
    );
    defer allocator.free(response_frame);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "response", .data = response_frame });
    const response_file = try tmp.dir.openFile(std.testing.io, "response", .{});
    defer response_file.close(std.testing.io);
    var reader_buffer: [2048]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
    const request_file = try tmp.dir.createFile(std.testing.io, "request", .{});
    defer request_file.close(std.testing.io);
    var writer_buffer: [1024]u8 = undefined;
    var writer = request_file.writer(std.testing.io, &writer_buffer);
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = &reader,
        .writer = &writer,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    return switch (try client.callImpl(
        .detailed,
        std.json.Value,
        method,
        .{ .sessionId = "missing-session", .requestId = "request-1" },
        if (std.mem.eql(u8, method, "session.resume"))
            .{ .session = .{ .session_id = "missing-session" } }
        else
            .generic,
    )) {
        .success => |value| {
            value.deinit();
            return error.TestExpectedFailure;
        },
        .failure => |failure| failure,
    };
}

test "public RPC captures malformed JSON and envelopes" {
    std.debug.print("\nCENSUS_PROBE invalid_json_dispatch\n", .{});
    const allocator = std.testing.allocator;
    var invalid_json = try expectDetailedCallFailure(
        allocator,
        "{",
        "test.invalidJson",
    );
    defer invalid_json.deinit();
    try std.testing.expectEqual(error.UnexpectedEndOfInput, invalid_json.native_error);
    switch (invalid_json.detail) {
        .protocol => |protocol_failure| switch (protocol_failure) {
            .invalid_json => |failure| {
                try std.testing.expectEqual(error.UnexpectedEndOfInput, failure.cause.code);
            },
            else => return error.TestExpectedInvalidJson,
        },
        else => return error.TestExpectedProtocolFailure,
    }

    var invalid_envelope = try expectDetailedCallFailure(
        allocator,
        \\ { "jsonrpc": "2.0", "id": 1, "result": {}, "error": { "code": -1, "message": "bad" } }
    ,
        "test.invalidEnvelope",
    );
    defer invalid_envelope.deinit();
    try std.testing.expectEqual(error.InvalidJsonRpc, invalid_envelope.native_error);
    switch (invalid_envelope.detail) {
        .protocol => |protocol_failure| switch (protocol_failure) {
            .invalid_envelope => |failure| {
                try std.testing.expectEqual(
                    errors.EnvelopeViolation.result_and_error,
                    failure.reason,
                );
                try std.testing.expectEqualStrings(
                    "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{},\"error\":{\"code\":-1,\"message\":\"bad\"}}",
                    failure.message_json.?,
                );
                const reparsed = try std.json.parseFromSlice(
                    std.json.Value,
                    allocator,
                    failure.message_json.?,
                    .{},
                );
                reparsed.deinit();
            },
            else => return error.TestExpectedInvalidEnvelope,
        },
        else => return error.TestExpectedProtocolFailure,
    }
}

test "invalid envelope dispatch retains canonical parseable JSON" {
    std.debug.print("\nCENSUS_PROBE invalid_envelope_dispatch\n", .{});
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        body: []const u8,
        canonical: []const u8,
        reason: errors.EnvelopeViolation,
        native_error: anyerror = error.InvalidJsonRpc,
    }{
        .{ .body = " [] ", .canonical = "[]", .reason = .non_object },
        .{
            .body =
            \\{"id":1,"result":{}}
            ,
            .canonical = "{\"id\":1,\"result\":{}}",
            .reason = .invalid_jsonrpc_version,
        },
        .{
            .body =
            \\{"jsonrpc":"2.0","result":{}}
            ,
            .canonical = "{\"jsonrpc\":\"2.0\",\"result\":{}}",
            .reason = .missing_id,
        },
        .{
            .body =
            \\{"jsonrpc":"2.0","id":-1,"result":{}}
            ,
            .canonical = "{\"jsonrpc\":\"2.0\",\"id\":-1,\"result\":{}}",
            .reason = .invalid_id,
        },
        .{
            .body =
            \\{"jsonrpc":"2.0","id":1}
            ,
            .canonical = "{\"jsonrpc\":\"2.0\",\"id\":1}",
            .reason = .missing_result_and_error,
            .native_error = error.MissingResult,
        },
        .{
            .body =
            \\{"jsonrpc":"2.0","id":1,"result":{},"error":{"code":-1,"message":"bad"}}
            ,
            .canonical = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{},\"error\":{\"code\":-1,\"message\":\"bad\"}}",
            .reason = .result_and_error,
        },
        .{
            .body =
            \\{"jsonrpc":"2.0","id":1,"error":null}
            ,
            .canonical = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":null}",
            .reason = .invalid_error_object,
        },
        .{
            .body =
            \\{"jsonrpc":"2.0","id":1,"error":{"message":"bad"}}
            ,
            .canonical = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"message\":\"bad\"}}",
            .reason = .invalid_error_code,
        },
        .{
            .body =
            \\{"jsonrpc":"2.0","id":1,"error":{"code":-1}}
            ,
            .canonical = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-1}}",
            .reason = .invalid_error_message,
        },
        .{
            .body =
            \\{"jsonrpc":"2.0","id":7,"method":4}
            ,
            .canonical = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":4}",
            .reason = .invalid_method,
        },
    };
    for (cases) |case| {
        var failure = try expectDetailedCallFailure(allocator, case.body, "test.envelope");
        defer failure.deinit();
        try std.testing.expectEqual(case.native_error, failure.native_error);
        const invalid = switch (failure.detail) {
            .protocol => |protocol_failure| switch (protocol_failure) {
                .invalid_envelope => |value| value,
                else => return error.TestExpectedInvalidEnvelope,
            },
            else => return error.TestExpectedProtocolFailure,
        };
        try std.testing.expectEqual(case.reason, invalid.reason);
        try std.testing.expectEqualStrings(case.canonical, invalid.message_json.?);
        const reparsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            invalid.message_json.?,
            .{},
        );
        reparsed.deinit();
    }
}

test "malformed RPC error objects retain the inbound response" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        body: []const u8,
        reason: errors.EnvelopeViolation,
    }{
        .{
            .body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":null}",
            .reason = .invalid_error_object,
        },
        .{
            .body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"message\":\"bad\"}}",
            .reason = .invalid_error_code,
        },
        .{
            .body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":\"bad\",\"message\":\"bad\"}}",
            .reason = .invalid_error_code,
        },
        .{
            .body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-1}}",
            .reason = .invalid_error_message,
        },
        .{
            .body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-1,\"message\":7}}",
            .reason = .invalid_error_message,
        },
    };

    for (cases) |case| {
        var failure_value = try expectDetailedCallFailure(
            allocator,
            case.body,
            "test.invalidRpcError",
        );
        defer failure_value.deinit();
        try std.testing.expectEqual(error.InvalidJsonRpc, failure_value.native_error);
        switch (failure_value.detail) {
            .protocol => |protocol_failure| switch (protocol_failure) {
                .invalid_envelope => |failure| {
                    try std.testing.expectEqual(case.reason, failure.reason);
                    try std.testing.expectEqualStrings(case.body, failure.message_json.?);
                    const reparsed = try std.json.parseFromSlice(
                        std.json.Value,
                        allocator,
                        failure.message_json.?,
                        .{},
                    );
                    reparsed.deinit();
                },
                else => return error.TestExpectedInvalidEnvelope,
            },
            else => return error.TestExpectedProtocolFailure,
        }
    }
}

fn expectTruncatedCallFailure(
    allocator: std.mem.Allocator,
) !errors.Failure {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "response",
        .data = "Content-Length: 5\r\n\r\nabc",
    });
    const response_file = try tmp.dir.openFile(std.testing.io, "response", .{});
    defer response_file.close(std.testing.io);
    var reader_buffer: [128]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
    const request_file = try tmp.dir.createFile(std.testing.io, "request", .{});
    defer request_file.close(std.testing.io);
    var writer_buffer: [128]u8 = undefined;
    var writer = request_file.writer(std.testing.io, &writer_buffer);
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = &reader,
        .writer = &writer,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    return switch (try client.callRpcDetailed(std.json.Value, "test.truncated", .{})) {
        .success => |value| {
            value.deinit();
            return error.TestExpectedFailure;
        },
        .failure => |failure| failure,
    };
}

test "truncated RPC frames consistently map to protocol failure" {
    const allocator = std.testing.allocator;
    var failure_value = try expectTruncatedCallFailure(allocator);
    defer failure_value.deinit();
    try std.testing.expectEqual(error.TruncatedFrame, failure_value.native_error);
    switch (failure_value.detail) {
        .protocol => |failure| switch (failure) {
            .truncated_frame => |truncated| {
                try std.testing.expectEqual(@as(usize, 5), truncated.declared);
                try std.testing.expectEqual(@as(usize, 3), truncated.received);
            },
            else => return error.TestExpectedTruncatedFrame,
        },
        else => return error.TestExpectedProtocolFailure,
    }
}

test "missing session specialization retains the original RPC failure" {
    const allocator = std.testing.allocator;
    var failure = try expectDetailedCallFailure(
        allocator,
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"The requested conversation is unavailable","data":{"errorCode":"session_not_found"}}}
    ,
        "session.resume",
    );
    defer failure.deinit();
    try std.testing.expectEqual(error.JsonRpcError, failure.native_error);
    switch (failure.detail) {
        .session => |session_failure| switch (session_failure) {
            .not_found => |not_found| {
                try std.testing.expectEqualStrings("missing-session", not_found.session_id);
                try std.testing.expectEqual(@as(i64, -32001), not_found.rpc.code);
                try std.testing.expectEqualStrings(
                    "session_not_found",
                    not_found.rpc.machine_code.?,
                );
                try std.testing.expectEqualStrings(
                    "{\"errorCode\":\"session_not_found\"}",
                    not_found.rpc.data_json.?,
                );
            },
            else => return error.TestExpectedSessionNotFound,
        },
        else => return error.TestExpectedSessionFailure,
    }
}

test "ordinary session RPC rejection retains owned session context" {
    const allocator = std.testing.allocator;
    var failure = try expectDetailedCallFailure(
        allocator,
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32077,"message":"Session is busy","data":{"errorCode":"session_busy"}}}
    ,
        "session.resume",
    );
    defer failure.deinit();

    try std.testing.expectEqual(error.JsonRpcError, failure.native_error);
    switch (failure.detail) {
        .rpc => |rpc| {
            try std.testing.expectEqual(@as(i64, -32077), rpc.code);
            try std.testing.expectEqualStrings("Session is busy", rpc.message);
            try std.testing.expectEqualStrings("session_busy", rpc.machine_code.?);
            switch (rpc.context) {
                .session => |context| try std.testing.expectEqualStrings(
                    "missing-session",
                    context.session_id,
                ),
                else => return error.TestExpectedSessionContext,
            }
        },
        else => return error.TestExpectedRpcFailure,
    }
}

test "interleaved request response write failure is captured" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const inbound_request =
        \\{"jsonrpc":"2.0","id":91,"method":"test.callback"}
    ;
    const frame = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}",
        .{ inbound_request.len, inbound_request },
    );
    defer allocator.free(frame);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "response", .data = frame });
    const response_file = try tmp.dir.openFile(std.testing.io, "response", .{});
    defer response_file.close(std.testing.io);
    var reader_buffer: [1024]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "read-only", .data = "" });
    const read_only_file = try tmp.dir.openFile(std.testing.io, "read-only", .{});
    defer read_only_file.close(std.testing.io);
    var writer_buffer: [64]u8 = undefined;
    var writer = read_only_file.writer(std.testing.io, &writer_buffer);
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = &reader,
        .writer = &writer,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer {
        for (client.rpc_handlers.items) |registered| registered.deinit(allocator);
        client.rpc_handlers.deinit(allocator);
    }
    try client.registerRpcHandler("test.callback", struct {
        fn handle(
            inner_allocator: std.mem.Allocator,
            params_json: ?[]const u8,
            _: ?*anyopaque,
        ) ![]u8 {
            try std.testing.expect(params_json == null);
            return inner_allocator.dupe(u8, "{}");
        }
    }.handle, null);

    var failure = switch (try client.nextEventImpl(.detailed, "session-1")) {
        .success => |delivery| {
            var owned = delivery;
            owned.deinit(allocator);
            return error.TestExpectedWriteFailure;
        },
        .failure => |value| value,
    };
    defer failure.deinit();
    try std.testing.expectEqual(error.WriteFailed, failure.native_error);
    switch (failure.detail) {
        .client => |client_failure| switch (client_failure) {
            .io => |io_failure| {
                try std.testing.expectEqual(errors.ClientOperation.write, io_failure.operation);
            },
            else => return error.TestExpectedIoFailure,
        },
        else => return error.TestExpectedClientFailure,
    }
}

test "nextEventDetailed owns complete session diagnostics after frame teardown" {
    std.debug.print("\nCENSUS_PROBE session_agent_delivery\n", .{});
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const session_event =
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"session-1","event":{"type":"session.error","data":{"errorType":"provider","errorCode":"rate_limited","message":"Try later","statusCode":429,"providerCallId":"provider-1","serviceRequestId":"service-1","remediation":{"retryAfter":30},"url":"https://example.test/help","stack":"trace","eligibleForAutoSwitch":true}}}}
    ;
    const responses = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}",
        .{ session_event.len, session_event },
    );
    defer allocator.free(responses);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "response", .data = responses });
    const response_file = try tmp.dir.openFile(std.testing.io, "response", .{});
    var reader_buffer: [2048]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
    const request_file = try tmp.dir.createFile(std.testing.io, "request", .{});
    var writer_buffer: [1024]u8 = undefined;
    var writer = request_file.writer(std.testing.io, &writer_buffer);
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = &reader,
        .writer = &writer,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer client.events.deinit(allocator);
    const session = Session{ .client = &client, .id = "session-1" };
    var failure = switch (try session.nextEventDetailed()) {
        .success => |event_value| {
            var event = event_value;
            event.deinit(allocator);
            return error.TestExpectedSessionFailure;
        },
        .failure => |value| value,
    };
    response_file.close(std.testing.io);
    request_file.close(std.testing.io);

    defer failure.deinit();
    try std.testing.expectEqual(error.CopilotSessionError, failure.native_error);
    switch (failure.detail) {
        .session => |session_failure| switch (session_failure) {
            .agent => |agent| {
                try std.testing.expectEqualStrings("session-1", agent.session_id);
                try std.testing.expectEqualStrings("provider", agent.error_type);
                try std.testing.expectEqualStrings("rate_limited", agent.error_code.?);
                try std.testing.expectEqualStrings("Try later", agent.message);
                try std.testing.expectEqual(@as(?u16, 429), agent.status_code);
                try std.testing.expectEqualStrings("provider-1", agent.provider_call_id.?);
                try std.testing.expectEqualStrings("service-1", agent.service_request_id.?);
                try std.testing.expectEqualStrings("{\"retryAfter\":30}", agent.remediation_json.?);
                try std.testing.expectEqualStrings("https://example.test/help", agent.url.?);
                try std.testing.expectEqualStrings("trace", agent.stack.?);
                try std.testing.expectEqual(@as(?bool, true), agent.eligible_for_auto_switch);
            },
            else => return error.TestExpectedAgentFailure,
        },
        else => return error.TestExpectedSessionFailure,
    }
}

test "cross-session errors retain diagnostics without eager failure construction" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const error_event =
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"session-2","event":{"type":"session.error","data":{"errorType":"provider","errorCode":"rate_limited","message":"Try later","statusCode":429,"providerCallId":"provider-1","serviceRequestId":"service-1","remediation":{"retryAfter":30},"url":"https://example.test/help","stack":"trace","eligibleForAutoSwitch":true}}}}
    ;
    const idle_event =
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"session-1","event":{"type":"session.idle","data":{}}}}
    ;
    const responses = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}",
        .{ error_event.len, error_event, idle_event.len, idle_event },
    );
    defer allocator.free(responses);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "response", .data = responses });
    const response_file = try tmp.dir.openFile(std.testing.io, "response", .{});
    defer response_file.close(std.testing.io);
    var reader_buffer: [2048]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
    const request_file = try tmp.dir.createFile(std.testing.io, "request", .{});
    defer request_file.close(std.testing.io);
    var writer_buffer: [1024]u8 = undefined;
    var writer = request_file.writer(std.testing.io, &writer_buffer);
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = &reader,
        .writer = &writer,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer {
        for (client.events.items) |*queued| queued.deinit(allocator);
        client.events.deinit(allocator);
    }

    var idle = try (Session{ .client = &client, .id = "session-1" }).nextEvent();
    defer idle.deinit(allocator);
    try std.testing.expect(idle == .session_idle);

    var failure = switch (try (Session{
        .client = &client,
        .id = "session-2",
    }).nextEventDetailed()) {
        .success => |event_value| {
            var event = event_value;
            event.deinit(allocator);
            return error.TestExpectedSessionFailure;
        },
        .failure => |value| value,
    };
    defer failure.deinit();
    try std.testing.expectEqual(error.CopilotSessionError, failure.native_error);
    const agent = switch (failure.detail) {
        .session => |session_failure| switch (session_failure) {
            .agent => |value| value,
            else => return error.TestExpectedAgentFailure,
        },
        else => return error.TestExpectedSessionFailure,
    };
    try std.testing.expectEqualStrings("session-2", agent.session_id);
    try std.testing.expectEqualStrings("rate_limited", agent.error_code.?);
    try std.testing.expectEqualStrings("{\"retryAfter\":30}", agent.remediation_json.?);
}

test "nextEventDetailed retains framing diagnostics" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "response",
        .data = "Content-Length: nope\r\n\r\n",
    });
    const response_file = try tmp.dir.openFile(std.testing.io, "response", .{});
    defer response_file.close(std.testing.io);
    var reader_buffer: [256]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
    const request_file = try tmp.dir.createFile(std.testing.io, "request", .{});
    defer request_file.close(std.testing.io);
    var writer_buffer: [256]u8 = undefined;
    var writer = request_file.writer(std.testing.io, &writer_buffer);
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = &reader,
        .writer = &writer,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer client.events.deinit(allocator);
    const session = Session{ .client = &client, .id = "session-1" };
    var failure = switch (try session.nextEventDetailed()) {
        .success => return error.TestExpectedProtocolFailure,
        .failure => |failure| failure,
    };
    defer failure.deinit();
    try std.testing.expectEqual(error.InvalidCharacter, failure.native_error);
    switch (failure.detail) {
        .protocol => |protocol_failure| switch (protocol_failure) {
            .invalid_content_length => |invalid| {
                try std.testing.expectEqualStrings("nope", invalid.value);
            },
            else => return error.TestExpectedInvalidContentLength,
        },
        else => return error.TestExpectedProtocolFailure,
    }
}

test "nextEvent preserves native framing error when diagnostics cannot allocate" {
    const allocator = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const response_file = try tmp.dir.createFile(std.testing.io, "response", .{});
    defer response_file.close(std.testing.io);
    var reader_buffer: [1]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
    const request_file = try tmp.dir.createFile(std.testing.io, "request", .{});
    defer request_file.close(std.testing.io);
    var writer_buffer: [1]u8 = undefined;
    var writer = request_file.writer(std.testing.io, &writer_buffer);
    var client = Client{
        .allocator = failing.allocator(),
        .io = std.testing.io,
        .child = null,
        .reader = &reader,
        .writer = &writer,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer client.events.deinit(failing.allocator());

    try std.testing.expectError(
        error.ReadFailed,
        (Session{ .client = &client, .id = "session-1" }).nextEvent(),
    );
}

test "nextEventDetailed owns the child process exit status" {
    const allocator = std.testing.allocator;
    var child = try std.process.spawn(std.testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "exit 7" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    const reader_buffer = try allocator.alloc(u8, 256);
    const writer_buffer = try allocator.alloc(u8, 256);
    const reader = try allocator.create(std.Io.File.Reader);
    const writer = try allocator.create(std.Io.File.Writer);
    reader.* = child.stdout.?.readerStreaming(std.testing.io, reader_buffer);
    writer.* = child.stdin.?.writerStreaming(std.testing.io, writer_buffer);
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = child,
        .reader = reader,
        .writer = writer,
        .reader_buffer = reader_buffer,
        .writer_buffer = writer_buffer,
    };
    defer client.deinit();
    const session = Session{ .client = &client, .id = "session-1" };
    var failure = switch (try session.nextEventDetailed()) {
        .success => return error.TestExpectedProcessFailure,
        .failure => |failure| failure,
    };
    defer failure.deinit();
    try std.testing.expectEqual(error.EndOfStream, failure.native_error);
    try std.testing.expect(failure.isTransportFailure());
    switch (failure.detail) {
        .process => |process_failure| switch (process_failure) {
            .exited => |exited| switch (exited.exit) {
                .exited => |code| try std.testing.expectEqual(@as(u8, 7), code),
                else => return error.TestExpectedExitCode,
            },
            else => return error.TestExpectedProcessExit,
        },
        else => return error.TestExpectedProcessFailure,
    }
}

fn runAutomaticToolFailure(
    allocator: std.mem.Allocator,
    response_body: []const u8,
) !errors.DetailedResult(session_types.SessionEvent) {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const response_frame = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}",
        .{ response_body.len, response_body },
    );
    defer allocator.free(response_frame);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "response", .data = response_frame });
    const response_file = try tmp.dir.openFile(std.testing.io, "response", .{});
    defer response_file.close(std.testing.io);
    var reader_buffer: [1024]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
    const request_file = try tmp.dir.createFile(std.testing.io, "request", .{});
    defer request_file.close(std.testing.io);
    var writer_buffer: [1024]u8 = undefined;
    var writer = request_file.writer(std.testing.io, &writer_buffer);
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = &reader,
        .writer = &writer,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer {
        for (client.events.items) |*queued| queued.deinit(allocator);
        client.events.deinit(allocator);
        for (client.tools.items) |tool| tool.deinit(allocator);
        client.tools.deinit(allocator);
    }
    try client.tools.append(allocator, .{
        .session_id = "session-1",
        .name = try allocator.dupe(u8, "explode"),
        .handler = struct {
            fn handle(
                _: std.mem.Allocator,
                _: []const u8,
                _: ?*anyopaque,
            ) ![]u8 {
                return error.ToolHandlerExploded;
            }
        }.handle,
        .context = null,
    });
    const event_json = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"external_tool.requested","data":{"requestId":"request-1","toolCallId":"call-1","toolName":"explode","arguments":{}}}
    ,
        .{},
    );
    defer event_json.deinit();
    try client.events.append(allocator, .{
        .session_id = try allocator.dupe(u8, "session-1"),
        .payload = try deliveryPayloadForTest(
            allocator,
            try session_types.parseEvent(allocator, event_json.value),
        ),
    });
    return (Session{ .client = &client, .id = "session-1" }).nextEventDetailed();
}

test "nextEventDetailed reports automatic tool handler failure" {
    std.debug.print("\nCENSUS_PROBE tool_handler_behavior\n", .{});
    const allocator = std.testing.allocator;
    var failure = switch (try runAutomaticToolFailure(allocator,
        \\{"jsonrpc":"2.0","id":1,"result":{"success":true}}
    )) {
        .success => |event| {
            var owned = event;
            owned.deinit(allocator);
            return error.TestExpectedToolHandlerFailure;
        },
        .failure => |value| value,
    };
    defer failure.deinit();

    try std.testing.expectEqual(error.ToolHandlerExploded, failure.native_error);
    switch (failure.detail) {
        .tool => |detail| switch (detail) {
            .handler_failed => |handler| {
                try std.testing.expectEqualStrings("session-1", handler.session_id);
                try std.testing.expectEqualStrings("request-1", handler.request_id);
                try std.testing.expectEqualStrings("call-1", handler.tool_call_id);
                try std.testing.expectEqualStrings("explode", handler.tool_name);
                try std.testing.expectEqual(error.ToolHandlerExploded, handler.cause.code);
            },
            else => return error.TestExpectedToolHandlerFailure,
        },
        else => return error.TestExpectedToolFailure,
    }
}

test "nextEventDetailed reports automatic tool delivery failure" {
    const allocator = std.testing.allocator;
    var failure = switch (try runAutomaticToolFailure(allocator,
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32070,"message":"Tool delivery denied","data":{"errorCode":"tool_delivery_denied"}}}
    )) {
        .success => |event| {
            var owned = event;
            owned.deinit(allocator);
            return error.TestExpectedToolDeliveryFailure;
        },
        .failure => |value| value,
    };
    defer failure.deinit();

    try std.testing.expectEqual(error.JsonRpcError, failure.native_error);
    switch (failure.detail) {
        .tool => |detail| switch (detail) {
            .delivery_failed => |rpc| {
                try std.testing.expectEqual(@as(i64, -32070), rpc.code);
                try std.testing.expectEqualStrings("Tool delivery denied", rpc.message);
                try std.testing.expectEqualStrings("tool_delivery_denied", rpc.machine_code.?);
                switch (rpc.context) {
                    .tool => |context| {
                        try std.testing.expectEqualStrings("session-1", context.session_id);
                        try std.testing.expectEqualStrings("request-1", context.request_id);
                        try std.testing.expectEqualStrings("call-1", context.tool_call_id.?);
                        try std.testing.expectEqualStrings("explode", context.tool_name.?);
                    },
                    else => return error.TestExpectedToolContext,
                }
            },
            else => return error.TestExpectedToolDeliveryFailure,
        },
        else => return error.TestExpectedToolFailure,
    }
}

fn expectInvalidSessionEventMapping(
    allocator: std.mem.Allocator,
    params_json: []const u8,
    expected_native_error: anyerror,
    expected_reason: errors.EnvelopeViolation,
    expected_message_json: []const u8,
) !void {
    var client = Client{
        .allocator = allocator,
        .io = undefined,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer {
        for (client.events.items) |*event| event.deinit(allocator);
        client.events.deinit(allocator);
        for (client.tools.items) |tool| tool.deinit(allocator);
        client.tools.deinit(allocator);
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, params_json, .{});
    defer parsed.deinit();

    const detailed_frame = try allocator.dupe(u8, "{}");
    defer allocator.free(detailed_frame);
    var failure = switch (try client.queueSessionEvent(.detailed, detailed_frame, parsed.value)) {
        .success => return error.TestExpectedProtocolFailure,
        .failure => |value| value,
    };
    defer failure.deinit();
    try std.testing.expectEqual(expected_native_error, failure.native_error);
    switch (failure.detail) {
        .protocol => |protocol_failure| switch (protocol_failure) {
            .invalid_envelope => |invalid| {
                try std.testing.expectEqual(expected_reason, invalid.reason);
                try std.testing.expectEqualStrings(expected_message_json, invalid.message_json.?);
                const reparsed = try std.json.parseFromSlice(
                    std.json.Value,
                    allocator,
                    invalid.message_json.?,
                    .{},
                );
                reparsed.deinit();
            },
            else => return error.TestExpectedInvalidEnvelope,
        },
        else => return error.TestExpectedProtocolFailure,
    }

    const legacy_frame = try allocator.dupe(u8, "{}");
    defer allocator.free(legacy_frame);
    switch (try client.queueSessionEvent(.legacy, legacy_frame, parsed.value)) {
        .success => return error.TestExpectedProtocolFailure,
        .failure => |legacy| try std.testing.expectEqual(
            expected_native_error,
            legacy.native_error,
        ),
    }
}

fn expectInvalidSessionEventEnvelope(
    allocator: std.mem.Allocator,
    body: []const u8,
    expected_native_error: anyerror,
    expected_reason: errors.EnvelopeViolation,
    expected_message_json: []const u8,
) !void {
    const frame = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );
    defer allocator.free(frame);

    inline for (.{ FailurePolicy.legacy, FailurePolicy.detailed }) |policy| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "response", .data = frame });
        const response_file = try tmp.dir.openFile(std.testing.io, "response", .{});
        defer response_file.close(std.testing.io);
        var reader_buffer: [512]u8 = undefined;
        var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
        const request_file = try tmp.dir.createFile(std.testing.io, "request", .{});
        defer request_file.close(std.testing.io);
        var writer_buffer: [128]u8 = undefined;
        var writer = request_file.writer(std.testing.io, &writer_buffer);
        var client = Client{
            .allocator = allocator,
            .io = std.testing.io,
            .child = null,
            .reader = &reader,
            .writer = &writer,
            .reader_buffer = &.{},
            .writer_buffer = &.{},
        };
        defer client.events.deinit(allocator);

        if (policy == .legacy) {
            const result = client.callRpc(std.json.Value, "test.method", .{});
            try std.testing.expectError(expected_native_error, result);
        } else {
            var failure = switch (try client.callRpcDetailed(
                std.json.Value,
                "test.method",
                .{},
            )) {
                .success => |parsed| {
                    parsed.deinit();
                    return error.TestExpectedProtocolFailure;
                },
                .failure => |value| value,
            };
            defer failure.deinit();
            try std.testing.expectEqual(expected_native_error, failure.native_error);
            const invalid = switch (failure.detail) {
                .protocol => |protocol_failure| switch (protocol_failure) {
                    .invalid_envelope => |value| value,
                    else => return error.TestExpectedInvalidEnvelope,
                },
                else => return error.TestExpectedProtocolFailure,
            };
            try std.testing.expectEqual(expected_reason, invalid.reason);
            try std.testing.expectEqualStrings(expected_message_json, invalid.message_json.?);
            const parsed = try std.json.parseFromSlice(
                std.json.Value,
                allocator,
                invalid.message_json.?,
                .{},
            );
            parsed.deinit();
        }
    }
}

test "session.event invalid envelope violation matrix" {
    std.debug.print("\nCENSUS_PROBE session_event_violation_matrix\n", .{});
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(
        errors.EnvelopeViolation.missing_params,
        sessionEventViolation(error.MissingField),
    );
    try std.testing.expectEqual(
        errors.EnvelopeViolation.malformed_field_type,
        sessionEventViolation(error.MalformedFieldType),
    );
    try expectInvalidSessionEventEnvelope(
        allocator,
        \\ { "jsonrpc": "2.0", "method": "session.event" }
    ,
        error.InvalidJsonRpc,
        .missing_params,
        "{\"jsonrpc\":\"2.0\",\"method\":\"session.event\"}",
    );
    try expectInvalidSessionEventEnvelope(
        allocator,
        \\{"jsonrpc":"2.0","method":"session.event","params":[]}
    ,
        error.InvalidJsonRpc,
        .malformed_field_type,
        "[]",
    );
    try expectInvalidSessionEventEnvelope(
        allocator,
        \\{"jsonrpc":"2.0","method":"session.event","params":{"event":{}}}
    ,
        error.InvalidJsonRpc,
        .missing_params,
        "{\"event\":{}}",
    );
    try expectInvalidSessionEventEnvelope(
        allocator,
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":7,"event":{}}}
    ,
        error.InvalidJsonRpc,
        .malformed_field_type,
        "{\"sessionId\":7,\"event\":{}}",
    );
    try expectInvalidSessionEventEnvelope(
        allocator,
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"s1"}}
    ,
        error.InvalidJsonRpc,
        .missing_params,
        "{\"sessionId\":\"s1\"}",
    );
    try expectInvalidSessionEventEnvelope(
        allocator,
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"s1","event":{"type":"session.error","data":{"errorType":"provider"}}}}
    ,
        error.InvalidSessionEvent,
        .missing_params,
        "{\"type\":\"session.error\",\"data\":{\"errorType\":\"provider\"}}",
    );
    try expectInvalidSessionEventEnvelope(
        allocator,
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"s1","event":{"type":"session.error","data":{"errorType":"provider","message":7}}}}
    ,
        error.InvalidSessionEvent,
        .malformed_field_type,
        "{\"type\":\"session.error\",\"data\":{\"errorType\":\"provider\",\"message\":7}}",
    );
    try expectInvalidSessionEventEnvelope(
        allocator,
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"s1","event":{"type":"assistant.message","data":{}}}}
    ,
        error.InvalidSessionEvent,
        .missing_params,
        "{\"type\":\"assistant.message\",\"data\":{}}",
    );
    try expectInvalidSessionEventEnvelope(
        allocator,
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"s1","event":{"type":"assistant.message","data":{"content":7}}}}
    ,
        error.InvalidSessionEvent,
        .malformed_field_type,
        "{\"type\":\"assistant.message\",\"data\":{\"content\":7}}",
    );
    try expectInvalidSessionEventEnvelope(
        allocator,
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"s1","event":{"type":"permission.requested","data":{"permissionRequest":{}}}}}
    ,
        error.InvalidSessionEvent,
        .missing_params,
        "{\"type\":\"permission.requested\",\"data\":{\"permissionRequest\":{}}}",
    );
    try expectInvalidSessionEventEnvelope(
        allocator,
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"s1","event":{"type":"permission.requested","data":{"requestId":7,"permissionRequest":{}}}}}
    ,
        error.InvalidSessionEvent,
        .malformed_field_type,
        "{\"type\":\"permission.requested\",\"data\":{\"requestId\":7,\"permissionRequest\":{}}}",
    );
    try expectInvalidSessionEventEnvelope(
        allocator,
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"s1","event":{"type":"session.error","data":{"errorType":"provider","message":"bad","statusCode":1000}}}}
    ,
        error.InvalidSessionEvent,
        .invalid_session_status,
        "{\"type\":\"session.error\",\"data\":{\"errorType\":\"provider\",\"message\":\"bad\",\"statusCode\":1000}}",
    );
    try expectInvalidSessionEventEnvelope(
        allocator,
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"s1","event":{"type":"session.error","data":{"errorType":"provider","message":"bad","statusCode":-1}}}}
    ,
        error.InvalidSessionEvent,
        .invalid_session_status,
        "{\"type\":\"session.error\",\"data\":{\"errorType\":\"provider\",\"message\":\"bad\",\"statusCode\":-1}}",
    );
    const accepted_body =
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"s1","event":{"type":"session.error","data":{"errorType":"provider","message":"ok","statusCode":999}}}}
    ;
    var accepted_status = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"session.error","data":{"errorType":"provider","message":"ok","statusCode":999}}
    ,
        .{},
    );
    defer accepted_status.deinit();
    const accepted_view = (try Client.sessionAgentWireView(accepted_status.value)).?;
    try std.testing.expectEqual(@as(?u16, 999), accepted_view.status_code);
    const accepted_frame = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}",
        .{ accepted_body.len, accepted_body },
    );
    defer allocator.free(accepted_frame);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "response", .data = accepted_frame });
    const response_file = try tmp.dir.openFile(std.testing.io, "response", .{});
    defer response_file.close(std.testing.io);
    var reader_buffer: [512]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
    const request_file = try tmp.dir.createFile(std.testing.io, "request", .{});
    defer request_file.close(std.testing.io);
    var writer_buffer: [128]u8 = undefined;
    var writer = request_file.writer(std.testing.io, &writer_buffer);
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = &reader,
        .writer = &writer,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer client.events.deinit(allocator);
    var delivery = switch (try client.nextEventImpl(.detailed, "s1")) {
        .success => |value| value,
        .failure => |failure| {
            var owned = failure;
            defer owned.deinit();
            return error.TestExpectedSessionEvent;
        },
    };
    defer delivery.deinit(allocator);
    switch (delivery.payload) {
        .session_error => {},
        else => return error.TestExpectedSessionError,
    }
}

test "parity production fixes preserve boundary behavior" {
    const allocator = std.testing.allocator;

    var reader_buffer: [64]u8 = undefined;
    var fragmented: std.testing.Reader = .init(&reader_buffer, &.{
        .{ .buffer = "Content-" },
        .{ .buffer = "Length: 2\r" },
        .{ .buffer = "\n\r\n{" },
        .{ .buffer = "}" },
    });
    fragmented.artificial_limit = .limited(1);
    const body = try json_rpc.readFrame(allocator, &fragmented.interface);
    defer allocator.free(body);
    try std.testing.expectEqualStrings("{}", body);

    try expectInvalidSessionEventMapping(
        allocator,
        "{}",
        error.InvalidJsonRpc,
        .missing_params,
        "{}",
    );
    try expectInvalidSessionEventMapping(
        allocator,
        "{\"sessionId\":7,\"event\":{}}",
        error.InvalidJsonRpc,
        .malformed_field_type,
        "{\"sessionId\":7,\"event\":{}}",
    );
    try expectInvalidSessionEventMapping(
        allocator,
        "{\"sessionId\":\"s1\",\"event\":{\"type\":\"session.error\",\"data\":{\"errorType\":\"provider\",\"message\":\"bad\",\"statusCode\":1000}}}",
        error.InvalidSessionEvent,
        .invalid_session_status,
        "{\"type\":\"session.error\",\"data\":{\"errorType\":\"provider\",\"message\":\"bad\",\"statusCode\":1000}}",
    );
    try expectInvalidSessionEventMapping(
        allocator,
        "{\"sessionId\":\"s1\",\"event\":{\"type\":\"session.error\",\"data\":{\"errorType\":\"provider\",\"message\":\"bad\",\"statusCode\":-1}}}",
        error.InvalidSessionEvent,
        .invalid_session_status,
        "{\"type\":\"session.error\",\"data\":{\"errorType\":\"provider\",\"message\":\"bad\",\"statusCode\":-1}}",
    );

    const canonical_source = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        " { \"params\" : null } ",
        .{},
    );
    defer canonical_source.deinit();
    var canonical_envelope = try recordEnvelope(
        allocator,
        .missing_params,
        canonical_source.value,
    );
    defer canonical_envelope.deinit();
    const message_json = switch (canonical_envelope.detail) {
        .protocol => |protocol_failure| switch (protocol_failure) {
            .invalid_envelope => |envelope| envelope.message_json,
            else => unreachable,
        },
        else => unreachable,
    };
    try std.testing.expectEqualStrings("{\"params\":null}", message_json.?);
    const parsed_message = try std.json.parseFromSlice(std.json.Value, allocator, message_json.?, .{});
    parsed_message.deinit();
}
