const std = @import("std");
const admin = @import("client_admin.zig");
const errors = @import("errors.zig");
const json_rpc = @import("json_rpc.zig");
const models = @import("models.zig");
const provider = @import("provider.zig");
const protocol = @import("protocol_version.zig");
const session_types = @import("session.zig");
const ext = @import("extensibility.zig");

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

fn isTransportEndOfStream(failure: *const errors.Failure) bool {
    if (failure.native_error != error.EndOfStream) return false;
    return switch (failure.detail) {
        .client => |client_failure| switch (client_failure) {
            .io => |io_failure| io_failure.operation == .read,
            else => false,
        },
        else => false,
    };
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

fn ownFallbackSessionErrorEvent(
    allocator: std.mem.Allocator,
    view: SessionAgentWireView,
    data: std.json.Value,
) !session_types.SessionEvent {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();
    const raw_json = try std.json.Stringify.valueAlloc(allocator, data, .{});
    errdefer allocator.free(raw_json);
    return .{ .session_error = .{
        .error_type = try arena_allocator.dupe(u8, view.error_type),
        .error_code = try dupeOptional(arena_allocator, view.error_code),
        .eligible_for_auto_switch = view.eligible_for_auto_switch,
        .message = try arena_allocator.dupe(u8, view.message),
        .remediation = null,
        .stack = try dupeOptional(arena_allocator, view.stack),
        .status_code = if (view.status_code) |status| @as(u64, status) else null,
        .provider_call_id = try dupeOptional(arena_allocator, view.provider_call_id),
        .service_request_id = try dupeOptional(arena_allocator, view.service_request_id),
        .url = try dupeOptional(arena_allocator, view.url),
        .raw = .{ .data_json = raw_json, .owns_data = true },
        .arena = arena,
    } };
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

fn recordSessionOperationRejected(
    allocator: std.mem.Allocator,
    operation: errors.SessionOperation,
    session_id: []const u8,
    message: ?[]const u8,
) !errors.Failure {
    const owned_session_id = try allocator.dupe(u8, session_id);
    errdefer allocator.free(owned_session_id);
    const owned_message = try dupeOptional(allocator, message);
    return recordFailure(allocator, error.CopilotClientError, .{ .client = .{
        .operation_rejected = .{
            .operation = operation,
            .session_id = owned_session_id,
            .message = owned_message,
        },
    } });
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

fn wipeSecret(value: []const u8) void {
    @memset(@constCast(value), 0);
}

fn wipeJsonStrings(value: std.json.Value) void {
    switch (value) {
        .string, .number_string => |string| wipeSecret(string),
        .array => |array| for (array.items) |item| wipeJsonStrings(item),
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| wipeJsonStrings(entry.value_ptr.*);
        },
        else => {},
    }
}

fn writeFrameAndWipe(
    writer: *std.Io.Writer,
    writer_buffer: []u8,
    body: []const u8,
) !void {
    defer {
        wipeSecret(writer_buffer);
        writer.end = 0;
    }
    try json_rpc.writeFrame(writer, body);
}

pub const ClientOptions = struct {
    cli_path: []const u8 = "copilot",
    working_directory: ?[]const u8 = null,
    cli_args: []const []const u8 = &.{},
    connection_token: ?[]const u8 = null,
    client_info: ?ClientInfo = null,
    /// Absolute trusted plugin directories installed before `init` returns.
    builtin_plugin_directories: []const []const u8 = &.{},
};

pub const ClientInfo = struct {
    application_name: ?[]const u8 = null,
    application_version: ?[]const u8 = null,
    integration_name: ?[]const u8 = null,
    integration_version: ?[]const u8 = null,
};

const EventDelivery = struct {
    session_id: []u8,
    event: session_types.SessionEvent,
    diagnostic_frame: ?[]u8 = null,

    fn intoEvent(
        self: *EventDelivery,
        allocator: std.mem.Allocator,
    ) session_types.SessionEvent {
        allocator.free(self.session_id);
        if (self.diagnostic_frame) |frame| allocator.free(frame);
        const event = self.event;
        self.* = undefined;
        return event;
    }

    fn intoFailure(
        self: *EventDelivery,
        allocator: std.mem.Allocator,
    ) errors.DetailedError!errors.Failure {
        const frame = self.diagnostic_frame.?;
        self.diagnostic_frame = null;
        var event = self.event;
        self.event = undefined;
        defer event.deinit(allocator);
        const session_id = self.session_id;
        self.* = undefined;
        defer allocator.free(frame);
        return sessionFailureFromFrame(allocator, session_id, frame);
    }

    fn deinit(self: *EventDelivery, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        if (self.diagnostic_frame) |frame| allocator.free(frame);
        self.event.deinit(allocator);
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

const OwnedCanvasAction = struct {
    name: []u8,
    handler: *const fn (std.mem.Allocator, ext.CanvasActionRequest, ?*anyopaque) anyerror![]u8,
};

const OwnedCanvas = struct {
    id: []u8,
    on_open: *const fn (std.mem.Allocator, ext.CanvasOpenRequest, ?*anyopaque) anyerror!ext.CanvasOpenResult,
    on_close: ?*const fn (ext.CanvasCloseRequest, ?*anyopaque) anyerror!void,
    actions: []OwnedCanvasAction,
    context: ?*anyopaque,

    fn deinit(self: *OwnedCanvas, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        for (self.actions) |action| allocator.free(action.name);
        allocator.free(self.actions);
    }
};

const RuntimeTool = struct {
    name: []u8,
    handler: session_types.ToolHandler,
    context: ?*anyopaque,
};

const SessionExtensionRuntime = struct {
    session_id: ?[]u8 = null,
    hooks: ext.SessionHooks,
    mcp_auth_handler: ?ext.McpAuthHandler,
    mcp_auth_context: ?*anyopaque,
    canvases: []OwnedCanvas,
    open_canvases: std.ArrayList(ext.OpenCanvas) = .empty,
    capabilities: ext.CapabilitySet = .{},
    mcp_apps_requested: bool,
    tools: []RuntimeTool,
    permission_handler: ?session_types.PermissionHandler,
    permission_context: ?*anyopaque,
    managed_settings_enabled: bool,
    user_input_handler: ?session_types.UserInputHandler,
    user_input_context: ?*anyopaque,
    granted_environment_variables: std.ArrayList(ext.EnvironmentGrant) = .empty,
    mcp_oauth_interest_handle: ?[]u8 = null,

    fn init(
        allocator: std.mem.Allocator,
        session_id: ?[]const u8,
        config: anytype,
        initial_open_canvases: []const ext.OpenCanvas,
    ) !SessionExtensionRuntime {
        const features = config.extensions.common;
        var tool_count: usize = 0;
        for (config.tools) |tool| if (tool.handler != null) {
            tool_count += 1;
        };
        const tools = try allocator.alloc(RuntimeTool, tool_count);
        const canvases = allocator.alloc(OwnedCanvas, features.canvases.len) catch |err| {
            allocator.free(tools);
            return err;
        };
        var result = SessionExtensionRuntime{
            .hooks = features.hooks,
            .mcp_auth_handler = features.mcp.on_auth_request,
            .mcp_auth_context = features.mcp.auth_context,
            .canvases = canvases,
            .mcp_apps_requested = features.experimental.mcp_apps,
            .tools = tools,
            .permission_handler = config.on_permission_request,
            .permission_context = config.permission_context,
            .managed_settings_enabled = managedSettingsEnabled(config),
            .user_input_handler = config.on_user_input_request,
            .user_input_context = config.user_input_context,
        };
        var initialized_tools: usize = 0;
        var initialized_canvases: usize = 0;
        errdefer {
            for (result.canvases[0..initialized_canvases]) |*canvas| canvas.deinit(allocator);
            allocator.free(result.canvases);
            for (result.tools[0..initialized_tools]) |tool| allocator.free(tool.name);
            allocator.free(result.tools);
            if (result.session_id) |id| allocator.free(id);
            for (result.open_canvases.items) |canvas| ext.freeOpenCanvas(allocator, canvas);
            result.open_canvases.deinit(allocator);
        }
        if (session_id) |id| result.session_id = try allocator.dupe(u8, id);
        for (config.tools) |tool| {
            const handler = tool.handler orelse continue;
            result.tools[initialized_tools] = .{
                .name = try allocator.dupe(u8, tool.name),
                .handler = handler,
                .context = tool.context,
            };
            initialized_tools += 1;
        }
        for (features.canvases, 0..) |canvas, index| {
            const actions = try allocator.alloc(OwnedCanvasAction, canvas.actions.len);
            var initialized_actions: usize = 0;
            errdefer {
                for (actions[0..initialized_actions]) |action| allocator.free(action.name);
                allocator.free(actions);
            }
            for (canvas.actions, 0..) |action, action_index| {
                actions[action_index] = .{
                    .name = try allocator.dupe(u8, action.name),
                    .handler = action.handler,
                };
                initialized_actions += 1;
            }
            result.canvases[index] = .{
                .id = try allocator.dupe(u8, canvas.declaration.id),
                .on_open = canvas.on_open,
                .on_close = canvas.on_close,
                .actions = actions,
                .context = canvas.context,
            };
            initialized_canvases += 1;
        }
        for (initial_open_canvases) |canvas| {
            const clone = try cloneOpenCanvas(allocator, canvas);
            errdefer ext.freeOpenCanvas(allocator, clone);
            try result.open_canvases.append(allocator, clone);
        }
        return result;
    }

    fn deinit(self: *SessionExtensionRuntime, allocator: std.mem.Allocator) void {
        if (self.session_id) |id| allocator.free(id);
        for (self.canvases) |*canvas| canvas.deinit(allocator);
        allocator.free(self.canvases);
        for (self.tools) |tool| allocator.free(tool.name);
        allocator.free(self.tools);
        for (self.open_canvases.items) |canvas| ext.freeOpenCanvas(allocator, canvas);
        self.open_canvases.deinit(allocator);
        for (self.granted_environment_variables.items) |grant| {
            allocator.free(grant.name);
            wipeSecret(grant.value);
            allocator.free(grant.value);
        }
        self.granted_environment_variables.deinit(allocator);
        if (self.mcp_oauth_interest_handle) |handle| allocator.free(handle);
    }
};

const RegisteredProviderToken = struct {
    provider_name: []u8,
    token_provider: provider.BearerTokenProvider,

    fn deinit(self: RegisteredProviderToken, allocator: std.mem.Allocator) void {
        allocator.free(self.provider_name);
    }
};

const RegisteredProviderTokens = struct {
    session_id: []const u8,
    providers: []RegisteredProviderToken,

    fn deinit(self: RegisteredProviderTokens, allocator: std.mem.Allocator) void {
        for (self.providers) |registered| registered.deinit(allocator);
        allocator.free(self.providers);
    }
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

const WireSendRequest = struct {
    sessionId: []const u8,
    prompt: []const u8,
    attachments: ?WireAttachments = null,
};

const WireAttachments = struct {
    values: []const session_types.Attachment,

    pub fn jsonStringify(self: WireAttachments, writer: anytype) !void {
        try writer.beginArray();
        for (self.values) |value| {
            try writer.write(WireAttachment{ .value = value });
        }
        try writer.endArray();
    }
};

const WireAttachment = struct {
    value: session_types.Attachment,

    pub fn jsonStringify(self: WireAttachment, writer: anytype) !void {
        switch (self.value) {
            .file => |value| try writer.write(.{
                .type = "file",
                .path = value.path,
                .displayName = attachmentDisplayName(value.display_name, value.path),
                .lineRange = value.line_range,
            }),
            .directory => |value| try writer.write(.{
                .type = "directory",
                .path = value.path,
                .displayName = attachmentDisplayName(value.display_name, value.path),
            }),
            .selection => |value| try writer.write(.{
                .type = "selection",
                .filePath = value.file_path,
                .text = value.text,
                .displayName = attachmentDisplayName(value.display_name, value.file_path),
                .selection = value.selection,
            }),
            .blob => |value| try writer.write(.{
                .type = "blob",
                .data = value.data,
                .mimeType = value.mime_type,
                .displayName = nonEmptyDisplayName(value.display_name) orelse "attachment",
            }),
            .github_reference => |value| try writer.write(.{
                .type = "github_reference",
                .number = value.number,
                .title = value.title,
                .referenceType = value.reference_type,
                .state = value.state,
                .url = value.url,
            }),
            .github_commit => |value| try writer.write(.{
                .type = "github_commit",
                .message = value.message,
                .oid = value.oid,
                .repo = wireRepo(value.repo),
                .url = value.url,
            }),
            .github_release => |value| try writer.write(.{
                .type = "github_release",
                .name = value.name,
                .repo = wireRepo(value.repo),
                .tagName = value.tag_name,
                .url = value.url,
            }),
            .github_actions_job => |value| try writer.write(.{
                .type = "github_actions_job",
                .conclusion = value.conclusion,
                .jobId = value.job_id,
                .jobName = value.job_name,
                .repo = wireRepo(value.repo),
                .url = value.url,
                .workflowName = value.workflow_name,
            }),
            .github_repository => |value| try writer.write(.{
                .type = "github_repository",
                .description = value.description,
                .ref = value.git_ref,
                .repo = wireRepo(value.repo),
                .url = value.url,
            }),
            .github_file_diff => |value| switch (value.sides) {
                .added => |head| try writer.write(.{
                    .type = "github_file_diff",
                    .head = wireFileDiffSide(head),
                    .url = value.url,
                }),
                .deleted => |base| try writer.write(.{
                    .type = "github_file_diff",
                    .base = wireFileDiffSide(base),
                    .url = value.url,
                }),
                .modified => |sides| try writer.write(.{
                    .type = "github_file_diff",
                    .base = wireFileDiffSide(sides.base),
                    .head = wireFileDiffSide(sides.head),
                    .url = value.url,
                }),
            },
            .github_tree_comparison => |value| try writer.write(.{
                .type = "github_tree_comparison",
                .base = wireTreeComparisonSide(value.base),
                .head = wireTreeComparisonSide(value.head),
                .url = value.url,
            }),
            .github_url => |value| try writer.write(.{
                .type = "github_url",
                .url = value.url,
            }),
            .github_file => |value| try writer.write(.{
                .type = "github_file",
                .path = value.path,
                .ref = value.git_ref,
                .repo = wireRepo(value.repo),
                .url = value.url,
            }),
            .github_snippet => |value| try writer.write(.{
                .type = "github_snippet",
                .lineRange = value.line_range,
                .path = value.path,
                .ref = value.git_ref,
                .repo = wireRepo(value.repo),
                .url = value.url,
            }),
        }
    }
};

fn nonEmptyDisplayName(display_name: ?[]const u8) ?[]const u8 {
    const value = display_name orelse return null;
    return if (std.mem.trim(u8, value, " \t\r\n").len == 0) null else value;
}

fn attachmentDisplayName(display_name: ?[]const u8, path: []const u8) []const u8 {
    if (nonEmptyDisplayName(display_name)) |value| return value;
    const base_name = std.fs.path.basename(path);
    if (base_name.len != 0) return base_name;
    return if (path.len != 0) path else "attachment";
}

const WireGitHubRepoPointer = struct {
    id: ?i64 = null,
    name: []const u8,
    owner: []const u8,
};

const WireGitHubFileDiffSide = struct {
    path: []const u8,
    ref: []const u8,
    repo: WireGitHubRepoPointer,
};

const WireGitHubTreeComparisonSide = struct {
    repo: WireGitHubRepoPointer,
    revision: []const u8,
};

fn wireRepo(value: session_types.Attachment.GitHubRepoPointer) WireGitHubRepoPointer {
    return .{
        .id = value.id,
        .name = value.name,
        .owner = value.owner,
    };
}

fn wireFileDiffSide(
    value: session_types.Attachment.GitHubFileDiffSide,
) WireGitHubFileDiffSide {
    return .{
        .path = value.path,
        .ref = value.git_ref,
        .repo = wireRepo(value.repo),
    };
}

fn wireTreeComparisonSide(
    value: session_types.Attachment.GitHubTreeComparisonSide,
) WireGitHubTreeComparisonSide {
    return .{
        .repo = wireRepo(value.repo),
        .revision = value.revision,
    };
}

fn lowerMessage(
    session_id: []const u8,
    options: session_types.MessageOptions,
) WireSendRequest {
    return .{
        .sessionId = session_id,
        .prompt = options.prompt,
        .attachments = if (options.attachments) |values|
            .{ .values = values }
        else
            null,
    };
}

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
    lifecycle_events: admin.LifecycleQueue = .{},
    tools: std.ArrayList(RegisteredTool) = .empty,
    user_input_handlers: std.ArrayList(RegisteredUserInputHandler) = .empty,
    permission_handlers: std.ArrayList(RegisteredPermissionHandler) = .empty,
    extension_runtimes: std.ArrayList(SessionExtensionRuntime) = .empty,
    pending_extension_runtime: ?SessionExtensionRuntime = null,
    provider_tokens: std.ArrayList(RegisteredProviderTokens) = .empty,
    pending_provider_tokens: ?RegisteredProviderTokens = null,
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
            .success => {},
            .failure => |failure| {
                client.deinit();
                return .{ .failure = failure };
            },
        }
        client.setBuiltinPluginDirectories(options.builtin_plugin_directories) catch |err| {
            client.deinit();
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .failure = try policyFailure(
                failure_policy,
                err,
                recordInvalidConfig,
                .{ allocator, "builtin_plugin_directories", err },
            ) };
        };
        return .{ .success = client };
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
        if (self.pending_extension_runtime) |*runtime| {
            self.releaseMcpOAuthInterest(runtime) catch |err|
                std.log.warn("failed to release pending MCP OAuth interest: {s}", .{@errorName(err)});
        }
        for (self.extension_runtimes.items) |*runtime| {
            self.releaseMcpOAuthInterest(runtime) catch |err|
                std.log.warn("failed to release MCP OAuth interest: {s}", .{@errorName(err)});
        }
        for (self.events.items) |*event| event.deinit(self.allocator);
        self.events.deinit(self.allocator);
        self.lifecycle_events.deinit();
        for (self.tools.items) |tool| tool.deinit(self.allocator);
        self.tools.deinit(self.allocator);
        self.user_input_handlers.deinit(self.allocator);
        self.permission_handlers.deinit(self.allocator);
        if (self.pending_extension_runtime) |*runtime| {
            runtime.deinit(self.allocator);
        }
        for (self.extension_runtimes.items) |*runtime| {
            runtime.deinit(self.allocator);
        }
        self.extension_runtimes.deinit(self.allocator);
        if (self.pending_provider_tokens) |registered| {
            registered.deinit(self.allocator);
        }
        for (self.provider_tokens.items) |registered| registered.deinit(self.allocator);
        self.provider_tokens.deinit(self.allocator);
        for (self.rpc_handlers.items) |handler| handler.deinit(self.allocator);
        self.rpc_handlers.deinit(self.allocator);
        for (self.session_ids.items) |id| self.allocator.free(id);
        self.session_ids.deinit(self.allocator);
        if (self.child) |*child| child.kill(self.io);
        self.allocator.destroy(self.reader);
        self.allocator.destroy(self.writer);
        self.wipeTransportBuffers();
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

    fn wipeTransportBuffers(self: *Client) void {
        wipeSecret(self.reader_buffer);
        wipeSecret(self.writer_buffer);
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

    fn setBuiltinPluginDirectories(self: *Client, directories: []const []const u8) !void {
        if (directories.len == 0) return;
        if (directories.len > 64) return error.TooManyBuiltinPluginDirectories;
        for (directories, 0..) |directory, index| {
            if (!std.fs.path.isAbsolute(directory) or directory.len > 4096)
                return error.InvalidBuiltinPluginDirectory;
            for (directories[0..index]) |previous| {
                if (std.mem.eql(u8, previous, directory))
                    return error.DuplicateBuiltinPluginDirectory;
            }
        }
        const parsed = try self.call(std.json.Value, "plugins.builtin.set", .{
            .paths = directories,
        });
        parsed.deinit();
    }

    pub fn createSession(
        self: *Client,
        config: session_types.CreateSessionConfig,
    ) !Session {
        return legacyResult(Session, self.createSessionEngine(.legacy, config));
    }

    pub fn createSessionDetailed(
        self: *Client,
        config: session_types.CreateSessionConfig,
    ) errors.DetailedError!errors.DetailedResult(Session) {
        return self.createSessionEngine(.detailed, config);
    }

    fn createSessionEngine(
        self: *Client,
        comptime failure_policy: FailurePolicy,
        config: session_types.CreateSessionConfig,
    ) errors.DetailedError!PolicyResult(failure_policy, Session) {
        validateCustomAgents(config.custom_agents, config.agent) catch |err|
            return .{ .failure = try policyFailure(
                failure_policy,
                err,
                recordInvalidConfig,
                .{ self.allocator, "custom_agents", err },
            ) };
        ext.validate(config.extensions.common) catch |err|
            return .{ .failure = try policyFailure(
                failure_policy,
                err,
                recordInvalidConfig,
                .{ self.allocator, "extensions", err },
            ) };
        validateCustomAgentMcpServers(config.custom_agents) catch |err|
            return .{ .failure = try policyFailure(
                failure_policy,
                err,
                recordInvalidConfig,
                .{ self.allocator, "custom_agents", err },
            ) };
        provider.validateCapabilities(config.model_capabilities) catch |err|
            return .{ .failure = try policyFailure(
                failure_policy,
                err,
                recordInvalidConfig,
                .{ self.allocator, "model_capabilities", err },
            ) };

        var prepared_providers = provider.prepareSessionProviders(
            self.allocator,
            config.provider,
            config.providers,
            config.models,
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .failure = try policyFailure(
                failure_policy,
                err,
                recordInvalidConfig,
                .{ self.allocator, "providers", err },
            ) };
        };
        defer prepared_providers.deinit(self.allocator);

        const owned_session_id = if (config.session_id) |requested|
            try self.allocator.dupe(u8, requested)
        else
            generateSessionId(self.allocator, self.io) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return .{ .failure = try policyFailure(
                    failure_policy,
                    err,
                    recordClientIo,
                    .{ self.allocator, .write, err },
                ) };
            };
        if (self.hasSession(owned_session_id)) {
            self.allocator.free(owned_session_id);
            return .{ .failure = try policyFailure(
                failure_policy,
                error.SessionAlreadyActive,
                recordInvalidConfig,
                .{ self.allocator, "session_id", error.SessionAlreadyActive },
            ) };
        }
        self.session_ids.append(self.allocator, owned_session_id) catch |err| {
            self.allocator.free(owned_session_id);
            return err;
        };
        var lifecycle_committed = false;
        defer if (!lifecycle_committed) {
            self.rollbackProviderTokens();
            self.rollbackExtensionRuntime();
            self.removeSession(owned_session_id);
        };

        var extension_values = ExtensionWireValues.init(self.allocator);
        defer extension_values.deinit();
        extension_values.lowerCustomAgents(config.custom_agents) catch |err|
            return .{ .failure = try policyFailure(
                failure_policy,
                err,
                recordInvalidConfig,
                .{ self.allocator, "custom_agents", err },
            ) };
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

        extension_values.lower(config.extensions.common) catch |err|
            return .{ .failure = try policyFailure(
                failure_policy,
                err,
                recordInvalidConfig,
                .{ self.allocator, "extensions", err },
            ) };
        self.beginProviderTokens(owned_session_id, prepared_providers.token_bindings) catch |err|
            return .{ .failure = try policyFailure(
                failure_policy,
                err,
                recordInvalidConfig,
                .{ self.allocator, "providers", err },
            ) };
        self.beginExtensionRuntime(owned_session_id, config, &.{}) catch |err|
            return .{ .failure = try policyFailure(
                failure_policy,
                err,
                recordInvalidConfig,
                .{ self.allocator, "extensions", err },
            ) };

        const request = buildPreparedCreateSessionRequest(
            owned_session_id,
            config,
            tools.items,
            &extension_values,
            prepared_providers,
        ) catch |err| return .{ .failure = try policyFailure(
            failure_policy,
            err,
            recordInvalidConfig,
            .{ self.allocator, "session", err },
        ) };
        const parsed = switch (try self.callImpl(
            failure_policy,
            WireSessionLifecycleResponse,
            "session.create",
            request,
            .{ .session = .{ .session_id = owned_session_id } },
        )) {
            .success => |value| value,
            .failure => |failure| return .{ .failure = failure },
        };
        defer {
            wipeLifecycleResponseSecrets(parsed.value);
            parsed.deinit();
        }
        const returned_id = parsed.value.sessionId orelse
            return .{ .failure = try policyFailure(
                failure_policy,
                error.MissingSessionId,
                recordInvalidConfig,
                .{ self.allocator, "sessionId", error.MissingSessionId },
            ) };
        if (!std.mem.eql(u8, owned_session_id, returned_id)) {
            if (!self.hasSession(returned_id)) {
                self.detachSessionBestEffort(returned_id);
            }
            return .{ .failure = try policyFailure(
                failure_policy,
                error.SessionIdMismatch,
                recordInvalidConfig,
                .{ self.allocator, "sessionId", error.SessionIdMismatch },
            ) };
        }
        defer if (!lifecycle_committed) self.detachSessionBestEffort(returned_id);
        self.commitExtensionRuntime(returned_id, parsed.value, &.{}) catch |err|
            return .{ .failure = try policyFailure(
                failure_policy,
                err,
                recordInvalidConfig,
                .{ self.allocator, "extensions", err },
            ) };
        self.commitProviderTokens();
        lifecycle_committed = true;
        return .{ .success = .{ .client = self, .id = owned_session_id } };
    }

    pub fn resumeSession(
        self: *Client,
        session_id: []const u8,
        config: session_types.ResumeSessionConfig,
    ) !Session {
        return legacyResult(
            Session,
            self.resumeSessionWithEnvironment(.legacy, session_id, config, &.{}),
        );
    }

    pub fn resumeSessionDetailed(
        self: *Client,
        session_id: []const u8,
        config: session_types.ResumeSessionConfig,
    ) errors.DetailedError!errors.DetailedResult(Session) {
        return self.resumeSessionWithEnvironment(.detailed, session_id, config, &.{});
    }

    /// Deprecated compatibility wrapper. Use `resumeSession`.
    pub fn joinSession(
        self: *Client,
        session_id: []const u8,
        config: session_types.SessionConfig,
    ) !Session {
        return self.resumeSession(session_id, resumeConfigFromCreate(config));
    }

    pub fn joinSessionDetailed(
        self: *Client,
        session_id: []const u8,
        config: session_types.SessionConfig,
    ) errors.DetailedError!errors.DetailedResult(Session) {
        return self.resumeSessionWithEnvironment(
            .detailed,
            session_id,
            resumeConfigFromCreate(config),
            &.{},
        );
    }

    fn resumeSessionWithEnvironment(
        self: *Client,
        comptime failure_policy: FailurePolicy,
        session_id: []const u8,
        config: session_types.ResumeSessionConfig,
        requested_environment_variables: []const []const u8,
    ) errors.DetailedError!PolicyResult(failure_policy, Session) {
        validateCustomAgents(config.custom_agents, config.agent) catch |err|
            return .{ .failure = try policyFailure(
                failure_policy,
                err,
                recordInvalidConfig,
                .{ self.allocator, "custom_agents", err },
            ) };
        ext.validate(config.extensions.common) catch |err|
            return .{ .failure = try policyFailure(
                failure_policy,
                err,
                recordInvalidConfig,
                .{ self.allocator, "extensions", err },
            ) };
        validateCustomAgentMcpServers(config.custom_agents) catch |err|
            return .{ .failure = try policyFailure(
                failure_policy,
                err,
                recordInvalidConfig,
                .{ self.allocator, "custom_agents", err },
            ) };
        provider.validateCapabilities(config.model_capabilities) catch |err|
            return .{ .failure = try policyFailure(
                failure_policy,
                err,
                recordInvalidConfig,
                .{ self.allocator, "model_capabilities", err },
            ) };

        var prepared_providers = provider.prepareSessionProviders(
            self.allocator,
            config.provider,
            config.providers,
            config.models,
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .failure = try policyFailure(
                failure_policy,
                err,
                recordInvalidConfig,
                .{ self.allocator, "providers", err },
            ) };
        };
        defer prepared_providers.deinit(self.allocator);

        const existing_session_id = self.findSessionId(session_id);
        const runtime_session_id = existing_session_id orelse id: {
            const copy = try self.allocator.dupe(u8, session_id);
            self.session_ids.append(self.allocator, copy) catch |err| {
                self.allocator.free(copy);
                return err;
            };
            break :id copy;
        };
        var lifecycle_committed = false;
        defer if (!lifecycle_committed) {
            self.rollbackProviderTokens();
            self.rollbackExtensionRuntime();
            if (existing_session_id == null) self.removeSession(runtime_session_id);
        };

        var extension_values = ExtensionWireValues.init(self.allocator);
        defer extension_values.deinit();
        extension_values.lowerCustomAgents(config.custom_agents) catch |err|
            return .{ .failure = try policyFailure(
                failure_policy,
                err,
                recordInvalidConfig,
                .{ self.allocator, "custom_agents", err },
            ) };
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

        extension_values.lower(config.extensions.common) catch |err|
            return .{ .failure = try policyFailure(
                failure_policy,
                err,
                recordInvalidConfig,
                .{ self.allocator, "extensions", err },
            ) };

        self.beginProviderTokens(runtime_session_id, prepared_providers.token_bindings) catch |err|
            return .{ .failure = try policyFailure(
                failure_policy,
                err,
                recordInvalidConfig,
                .{ self.allocator, "providers", err },
            ) };
        self.beginExtensionRuntime(
            runtime_session_id,
            config,
            config.extensions.open_canvases orelse &.{},
        ) catch |err| return .{ .failure = try policyFailure(
            failure_policy,
            err,
            recordInvalidConfig,
            .{ self.allocator, "extensions", err },
        ) };

        const request = buildPreparedResumeSessionRequest(
            runtime_session_id,
            config,
            tools.items,
            &extension_values,
            requested_environment_variables,
            prepared_providers,
        ) catch |err| return .{ .failure = try policyFailure(
            failure_policy,
            err,
            recordInvalidConfig,
            .{ self.allocator, "session", err },
        ) };
        const parsed = switch (try self.callImpl(
            failure_policy,
            WireSessionLifecycleResponse,
            "session.resume",
            request,
            .{ .session = .{ .session_id = session_id } },
        )) {
            .success => |value| value,
            .failure => |failure| return .{ .failure = failure },
        };
        defer {
            wipeLifecycleResponseSecrets(parsed.value);
            parsed.deinit();
        }
        const returned_id = parsed.value.sessionId orelse
            return .{ .failure = try policyFailure(
                failure_policy,
                error.MissingSessionId,
                recordInvalidConfig,
                .{ self.allocator, "sessionId", error.MissingSessionId },
            ) };
        if (!std.mem.eql(u8, runtime_session_id, returned_id)) {
            if (!self.hasSession(returned_id)) {
                self.detachSessionBestEffort(returned_id);
            }
            return .{ .failure = try policyFailure(
                failure_policy,
                error.SessionIdMismatch,
                recordInvalidConfig,
                .{ self.allocator, "sessionId", error.SessionIdMismatch },
            ) };
        }
        defer if (!lifecycle_committed and existing_session_id == null)
            self.detachSessionBestEffort(returned_id);
        self.commitExtensionRuntime(
            runtime_session_id,
            parsed.value,
            requested_environment_variables,
        ) catch |err| return .{ .failure = try policyFailure(
            failure_policy,
            err,
            recordInvalidConfig,
            .{ self.allocator, "extensions", err },
        ) };
        self.commitProviderTokens();
        lifecycle_committed = true;
        return .{ .success = .{ .client = self, .id = runtime_session_id } };
    }

    fn detachSessionBestEffort(self: *Client, session_id: []const u8) void {
        const parsed = self.call(struct {
            success: bool,
            @"error": ?[]const u8 = null,
        }, "session.detach", .{
            .sessionId = session_id,
        }) catch return;
        parsed.deinit();
    }

    fn beginExtensionRuntime(
        self: *Client,
        session_id: ?[]const u8,
        config: anytype,
        open_canvases: []const ext.OpenCanvas,
    ) !void {
        if (self.pending_extension_runtime != null)
            return error.SessionLifecycleAlreadyInProgress;
        self.pending_extension_runtime = try SessionExtensionRuntime.init(
            self.allocator,
            session_id,
            config,
            open_canvases,
        );
    }

    fn rollbackExtensionRuntime(self: *Client) void {
        if (self.pending_extension_runtime) |*runtime| {
            self.releaseMcpOAuthInterest(runtime) catch |err|
                std.log.warn("failed to release MCP OAuth interest during rollback: {s}", .{@errorName(err)});
            runtime.deinit(self.allocator);
        }
        self.pending_extension_runtime = null;
    }

    fn commitExtensionRuntime(
        self: *Client,
        session_id: []const u8,
        response: WireSessionLifecycleResponse,
        requested_environment_variables: []const []const u8,
    ) !void {
        const runtime = if (self.pending_extension_runtime) |*value| value else return error.MissingExtensionRuntime;
        if (runtime.session_id) |id| {
            if (!std.mem.eql(u8, id, session_id)) return error.UnexpectedSessionId;
        } else {
            runtime.session_id = try self.allocator.dupe(u8, session_id);
        }
        runtime.capabilities = parseCapabilities(response.capabilities);
        if (response.openCanvases) |canvases| {
            for (runtime.open_canvases.items) |canvas| ext.freeOpenCanvas(self.allocator, canvas);
            runtime.open_canvases.clearRetainingCapacity();
            for (canvases) |canvas| {
                const clone = try cloneWireOpenCanvas(self.allocator, canvas);
                errdefer ext.freeOpenCanvas(self.allocator, clone);
                try runtime.open_canvases.append(self.allocator, clone);
            }
        }
        if (response.grantedEnvironmentVariables) |grants_value| {
            const grants = switch (grants_value) {
                .object => |value| value,
                else => return error.InvalidGrantedEnvironmentVariables,
            };
            var iterator = grants.iterator();
            while (iterator.next()) |entry| {
                var requested = false;
                for (requested_environment_variables) |name| {
                    if (std.mem.eql(u8, name, entry.key_ptr.*)) {
                        requested = true;
                        break;
                    }
                }
                if (!requested) continue;
                const value = switch (entry.value_ptr.*) {
                    .string => |item| item,
                    else => return error.InvalidGrantedEnvironmentVariables,
                };
                const name_copy = try self.allocator.dupe(u8, entry.key_ptr.*);
                errdefer self.allocator.free(name_copy);
                const value_copy = try self.allocator.dupe(u8, value);
                errdefer {
                    wipeSecret(value_copy);
                    self.allocator.free(value_copy);
                }
                try runtime.granted_environment_variables.append(self.allocator, .{
                    .name = name_copy,
                    .value = value_copy,
                });
            }
        }
        for (self.extension_runtimes.items, 0..) |*existing, index| {
            if (existing.session_id != null and
                std.mem.eql(u8, existing.session_id.?, session_id))
            {
                if (existing.mcp_oauth_interest_handle != null and
                    runtime.mcp_auth_handler != null)
                {
                    runtime.mcp_oauth_interest_handle =
                        existing.mcp_oauth_interest_handle;
                    existing.mcp_oauth_interest_handle = null;
                } else if (runtime.mcp_auth_handler != null) {
                    try self.registerMcpOAuthInterest(runtime);
                } else {
                    try self.releaseMcpOAuthInterest(existing);
                }
                const replacement = self.pending_extension_runtime.?;
                self.pending_extension_runtime = null;
                existing.deinit(self.allocator);
                self.extension_runtimes.items[index] = replacement;
                return;
            }
        }
        try self.extension_runtimes.ensureUnusedCapacity(self.allocator, 1);
        if (runtime.mcp_auth_handler != null) {
            try self.registerMcpOAuthInterest(runtime);
        }
        const committed = self.pending_extension_runtime.?;
        self.pending_extension_runtime = null;
        self.extension_runtimes.appendAssumeCapacity(committed);
    }

    fn registerMcpOAuthInterest(
        self: *Client,
        runtime: *SessionExtensionRuntime,
    ) !void {
        if (runtime.mcp_oauth_interest_handle != null) return;
        const session_id = runtime.session_id orelse return error.MissingSessionId;
        const parsed = try self.call(struct {
            handle: []const u8,
        }, "session.eventLog.registerInterest", .{
            .sessionId = session_id,
            .eventType = "mcp.oauth_required",
        });
        defer parsed.deinit();
        runtime.mcp_oauth_interest_handle =
            self.allocator.dupe(u8, parsed.value.handle) catch |err| {
                const released = self.call(struct {
                    success: bool,
                }, "session.eventLog.releaseInterest", .{
                    .sessionId = session_id,
                    .handle = parsed.value.handle,
                }) catch return err;
                released.deinit();
                return err;
            };
    }

    fn releaseMcpOAuthInterest(
        self: *Client,
        runtime: *SessionExtensionRuntime,
    ) !void {
        const handle = runtime.mcp_oauth_interest_handle orelse return;
        const session_id = runtime.session_id orelse
            return error.MissingSessionId;
        const parsed = try self.call(struct {
            success: bool,
        }, "session.eventLog.releaseInterest", .{
            .sessionId = session_id,
            .handle = handle,
        });
        defer parsed.deinit();
        if (!parsed.value.success) return error.EventInterestNotReleased;
        self.allocator.free(handle);
        runtime.mcp_oauth_interest_handle = null;
    }

    /// Joins a parent-selected extension session. The session id is injected by
    /// the parent runtime and is intentionally explicit in Zig's `initParent`
    /// API because `Client` does not own process-environment state.
    pub fn joinParentSession(
        self: *Client,
        session_id: []const u8,
        config: session_types.JoinSessionConfig,
    ) !JoinedSession {
        const resume_config = resumeConfigFromJoin(config);
        // Extension SDK overrides are structurally impossible here.
        const session = try legacyResult(
            Session,
            self.resumeSessionWithEnvironment(
                .legacy,
                session_id,
                resume_config,
                config.extensions.requested_environment_variables,
            ),
        );
        const grants = session.snapshotEnvironmentGrants(self.allocator) catch |err| {
            session.disconnect() catch |cleanup_err| {
                if (self.findExtensionRuntime(session.id)) |runtime| {
                    self.releaseMcpOAuthInterest(runtime) catch |release_err|
                        std.log.warn("failed to release MCP OAuth interest after join cleanup: {s}", .{@errorName(release_err)});
                }
                self.removeSession(session.id);
                return cleanup_err;
            };
            return err;
        };
        return .{
            .session = session,
            .grants = grants,
        };
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

    fn callOwned(
        self: *Client,
        comptime failure_policy: FailurePolicy,
        comptime Wire: type,
        comptime Owned: type,
        method: []const u8,
        params: anytype,
        context: OperationContext,
        comptime convert: anytype,
    ) errors.DetailedError!PolicyResult(failure_policy, Owned) {
        const parsed = switch (try self.callImpl(
            failure_policy,
            Wire,
            method,
            params,
            context,
        )) {
            .success => |value| value,
            .failure => |failure| return .{ .failure = failure },
        };
        defer parsed.deinit();
        return .{ .success = try convert(self.allocator, parsed.value) };
    }

    pub fn ping(self: *Client, message: ?[]const u8) !admin.PingResponse {
        return legacyResult(admin.PingResponse, self.pingImpl(.legacy, message));
    }

    pub fn pingDetailed(
        self: *Client,
        message: ?[]const u8,
    ) errors.DetailedError!errors.DetailedResult(admin.PingResponse) {
        return self.pingImpl(.detailed, message);
    }

    fn pingImpl(
        self: *Client,
        comptime failure_policy: FailurePolicy,
        message: ?[]const u8,
    ) errors.DetailedError!PolicyResult(failure_policy, admin.PingResponse) {
        return self.callOwned(
            failure_policy,
            admin.PingResult,
            admin.PingResponse,
            "ping",
            admin.PingParams{ .message = message },
            .generic,
            admin.ownPing,
        );
    }

    pub fn getStatus(self: *Client) !admin.ClientStatus {
        return legacyResult(admin.ClientStatus, self.getStatusImpl(.legacy));
    }

    pub fn getStatusDetailed(
        self: *Client,
    ) errors.DetailedError!errors.DetailedResult(admin.ClientStatus) {
        return self.getStatusImpl(.detailed);
    }

    fn getStatusImpl(
        self: *Client,
        comptime failure_policy: FailurePolicy,
    ) errors.DetailedError!PolicyResult(failure_policy, admin.ClientStatus) {
        return self.callOwned(
            failure_policy,
            admin.StatusGetResult,
            admin.ClientStatus,
            "status.get",
            admin.EmptyParams{},
            .generic,
            admin.ownStatus,
        );
    }

    pub fn getAuthStatus(self: *Client) !admin.AuthStatus {
        return legacyResult(admin.AuthStatus, self.getAuthStatusImpl(.legacy));
    }

    pub fn getAuthStatusDetailed(
        self: *Client,
    ) errors.DetailedError!errors.DetailedResult(admin.AuthStatus) {
        return self.getAuthStatusImpl(.detailed);
    }

    fn getAuthStatusImpl(
        self: *Client,
        comptime failure_policy: FailurePolicy,
    ) errors.DetailedError!PolicyResult(failure_policy, admin.AuthStatus) {
        return self.callOwned(
            failure_policy,
            admin.AuthGetStatusResult,
            admin.AuthStatus,
            "auth.getStatus",
            admin.EmptyParams{},
            .generic,
            admin.ownAuthStatus,
        );
    }

    pub fn getLastSessionId(self: *Client) !?admin.SessionId {
        return legacyResult(?admin.SessionId, self.getLastSessionIdImpl(.legacy));
    }

    pub fn getLastSessionIdDetailed(
        self: *Client,
    ) errors.DetailedError!errors.DetailedResult(?admin.SessionId) {
        return self.getLastSessionIdImpl(.detailed);
    }

    fn getLastSessionIdImpl(
        self: *Client,
        comptime failure_policy: FailurePolicy,
    ) errors.DetailedError!PolicyResult(failure_policy, ?admin.SessionId) {
        return self.callOwned(
            failure_policy,
            admin.OptionalSessionIdResult,
            ?admin.SessionId,
            "session.getLastId",
            admin.EmptyParams{},
            .generic,
            admin.ownSessionId,
        );
    }

    pub fn deleteSession(self: *Client, session_id: []const u8) !void {
        return legacyResult(void, self.deleteSessionImpl(.legacy, session_id));
    }

    pub fn deleteSessionDetailed(
        self: *Client,
        session_id: []const u8,
    ) errors.DetailedError!errors.DetailedResult(void) {
        return self.deleteSessionImpl(.detailed, session_id);
    }

    pub fn listSessions(
        self: *Client,
        filter: ?admin.SessionListFilter,
    ) !admin.SessionCatalog {
        return legacyResult(admin.SessionCatalog, self.listSessionsImpl(.legacy, filter));
    }

    pub fn listSessionsDetailed(
        self: *Client,
        filter: ?admin.SessionListFilter,
    ) errors.DetailedError!errors.DetailedResult(admin.SessionCatalog) {
        return self.listSessionsImpl(.detailed, filter);
    }

    fn listSessionsImpl(
        self: *Client,
        comptime failure_policy: FailurePolicy,
        filter: ?admin.SessionListFilter,
    ) errors.DetailedError!PolicyResult(failure_policy, admin.SessionCatalog) {
        return self.callOwned(
            failure_policy,
            admin.SessionListResult,
            admin.SessionCatalog,
            "session.list",
            admin.lowerFilter(filter),
            .generic,
            admin.ownCatalog,
        );
    }

    pub fn getSessionMetadata(
        self: *Client,
        session_id: []const u8,
    ) !?admin.SessionMetadata {
        return legacyResult(
            ?admin.SessionMetadata,
            self.getSessionMetadataImpl(.legacy, session_id),
        );
    }

    pub fn getSessionMetadataDetailed(
        self: *Client,
        session_id: []const u8,
    ) errors.DetailedError!errors.DetailedResult(?admin.SessionMetadata) {
        return self.getSessionMetadataImpl(.detailed, session_id);
    }

    fn getSessionMetadataImpl(
        self: *Client,
        comptime failure_policy: FailurePolicy,
        session_id: []const u8,
    ) errors.DetailedError!PolicyResult(failure_policy, ?admin.SessionMetadata) {
        return self.callOwned(
            failure_policy,
            admin.SessionGetMetadataResult,
            ?admin.SessionMetadata,
            "session.getMetadata",
            admin.SessionIdParams{ .sessionId = session_id },
            .{ .session = .{ .session_id = session_id } },
            admin.ownOptionalMetadata,
        );
    }

    pub fn getForegroundSessionId(self: *Client) !?admin.SessionId {
        return legacyResult(?admin.SessionId, self.getForegroundSessionIdImpl(.legacy));
    }

    pub fn getForegroundSessionIdDetailed(
        self: *Client,
    ) errors.DetailedError!errors.DetailedResult(?admin.SessionId) {
        return self.getForegroundSessionIdImpl(.detailed);
    }

    fn getForegroundSessionIdImpl(
        self: *Client,
        comptime failure_policy: FailurePolicy,
    ) errors.DetailedError!PolicyResult(failure_policy, ?admin.SessionId) {
        return self.callOwned(
            failure_policy,
            admin.OptionalSessionIdResult,
            ?admin.SessionId,
            "session.getForeground",
            admin.EmptyParams{},
            .generic,
            admin.ownSessionId,
        );
    }

    pub fn setForegroundSessionId(
        self: *Client,
        session_id: []const u8,
    ) !void {
        return legacyResult(void, self.sessionOperationImpl(
            .legacy,
            "session.setForeground",
            .set_foreground,
            session_id,
        ));
    }

    pub fn setForegroundSessionIdDetailed(
        self: *Client,
        session_id: []const u8,
    ) errors.DetailedError!errors.DetailedResult(void) {
        return self.sessionOperationImpl(
            .detailed,
            "session.setForeground",
            .set_foreground,
            session_id,
        );
    }

    fn sessionOperationImpl(
        self: *Client,
        comptime failure_policy: FailurePolicy,
        method: []const u8,
        operation: errors.SessionOperation,
        session_id: []const u8,
    ) errors.DetailedError!PolicyResult(failure_policy, void) {
        const parsed = switch (try self.callImpl(
            failure_policy,
            admin.SuccessResult,
            method,
            admin.SessionIdParams{ .sessionId = session_id },
            .{ .session = .{ .session_id = session_id } },
        )) {
            .success => |value| value,
            .failure => |failure| return .{ .failure = failure },
        };
        defer parsed.deinit();
        if (!parsed.value.success) return .{ .failure = try policyFailure(
            failure_policy,
            error.CopilotClientError,
            recordSessionOperationRejected,
            .{ self.allocator, operation, session_id, parsed.value.@"error" },
        ) };
        return .{ .success = {} };
    }

    const McpOAuthInterestReleaseState = enum {
        no_interest,
        released,
    };

    fn findAttachedExtensionRuntimeIndex(
        self: *Client,
        session_id: []const u8,
    ) ?usize {
        for (self.extension_runtimes.items, 0..) |runtime, index| {
            const runtime_session_id = runtime.session_id orelse continue;
            if (std.mem.eql(u8, runtime_session_id, session_id)) return index;
        }
        return null;
    }

    fn releaseAttachedMcpOAuthInterest(
        self: *Client,
        comptime failure_policy: FailurePolicy,
        session_id: []const u8,
    ) errors.DetailedError!PolicyResult(
        failure_policy,
        McpOAuthInterestReleaseState,
    ) {
        const runtime_index = self.findAttachedExtensionRuntimeIndex(session_id) orelse
            return .{ .success = .no_interest };
        const handle = self.extension_runtimes.items[runtime_index].mcp_oauth_interest_handle orelse
            return .{ .success = .no_interest };
        const owned_handle = try self.allocator.dupe(u8, handle);
        defer self.allocator.free(owned_handle);
        const parsed = switch (try self.callImpl(
            failure_policy,
            struct { success: bool },
            "session.eventLog.releaseInterest",
            .{
                .sessionId = session_id,
                .handle = owned_handle,
            },
            .{ .session = .{ .session_id = session_id } },
        )) {
            .success => |value| value,
            .failure => |failure| return .{ .failure = failure },
        };
        defer parsed.deinit();
        if (!parsed.value.success) return .{ .failure = try policyFailure(
            failure_policy,
            error.EventInterestNotReleased,
            recordClientIo,
            .{ self.allocator, .callback, error.EventInterestNotReleased },
        ) };

        const current_index = self.findAttachedExtensionRuntimeIndex(session_id) orelse
            return .{ .success = .released };
        const current_handle =
            self.extension_runtimes.items[current_index].mcp_oauth_interest_handle orelse
            return .{ .success = .released };
        if (!std.mem.eql(u8, current_handle, owned_handle))
            return .{ .success = .released };
        self.allocator.free(current_handle);
        self.extension_runtimes.items[current_index].mcp_oauth_interest_handle = null;
        return .{ .success = .released };
    }

    fn restoreAttachedMcpOAuthInterestDetailed(
        self: *Client,
        session_id: []const u8,
    ) errors.DetailedError!errors.DetailedResult(void) {
        const runtime_index = self.findAttachedExtensionRuntimeIndex(session_id) orelse
            return .{ .success = {} };
        if (self.extension_runtimes.items[runtime_index].mcp_oauth_interest_handle != null)
            return .{ .success = {} };

        const parsed = switch (try self.callImpl(
            .detailed,
            struct { handle: []const u8 },
            "session.eventLog.registerInterest",
            .{
                .sessionId = session_id,
                .eventType = "mcp.oauth_required",
            },
            .{ .session = .{ .session_id = session_id } },
        )) {
            .success => |value| value,
            .failure => |failure| return .{ .failure = failure },
        };
        defer parsed.deinit();
        const owned_handle = try self.allocator.dupe(u8, parsed.value.handle);
        const current_index = self.findAttachedExtensionRuntimeIndex(session_id) orelse {
            self.allocator.free(owned_handle);
            return .{ .success = {} };
        };
        if (self.extension_runtimes.items[current_index].mcp_oauth_interest_handle) |_| {
            self.allocator.free(owned_handle);
        } else {
            self.extension_runtimes.items[current_index].mcp_oauth_interest_handle =
                owned_handle;
        }
        return .{ .success = {} };
    }

    fn restoreReleasedMcpOAuthInterest(
        self: *Client,
        release_state: McpOAuthInterestReleaseState,
        session_id: []const u8,
    ) void {
        if (release_state != .released) return;
        const result = self.restoreAttachedMcpOAuthInterestDetailed(session_id) catch |err| {
            std.log.warn(
                "failed to restore MCP OAuth interest after session.delete failure for {s}: {s}",
                .{ session_id, @errorName(err) },
            );
            self.removeSession(session_id);
            return;
        };
        switch (result) {
            .success => {},
            .failure => |failure_value| {
                var failure = failure_value;
                defer failure.deinit();
                std.log.warn(
                    "failed to restore MCP OAuth interest after session.delete failure for {s}: {s}",
                    .{ session_id, @errorName(failure.native_error) },
                );
                self.removeSession(session_id);
            },
        }
    }

    fn deleteSessionImpl(
        self: *Client,
        comptime failure_policy: FailurePolicy,
        session_id: []const u8,
    ) errors.DetailedError!PolicyResult(failure_policy, void) {
        const release_state = switch (try self.releaseAttachedMcpOAuthInterest(
            failure_policy,
            session_id,
        )) {
            .success => |state| state,
            .failure => |failure| return .{ .failure = failure },
        };
        const deletion = self.sessionOperationImpl(
            failure_policy,
            "session.delete",
            .delete,
            session_id,
        ) catch |err| {
            self.restoreReleasedMcpOAuthInterest(release_state, session_id);
            return err;
        };
        return switch (deletion) {
            .success => {
                self.removeSession(session_id);
                return .{ .success = {} };
            },
            .failure => |failure| {
                self.restoreReleasedMcpOAuthInterest(release_state, session_id);
                return .{ .failure = failure };
            },
        };
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

    fn call(
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
        defer {
            wipeSecret(request);
            self.allocator.free(request);
        }
        writeFrameAndWipe(&self.writer.interface, self.writer_buffer, request) catch |err|
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
                    if (isTransportEndOfStream(&frame_failure)) {
                        frame_failure.deinit();
                        return .{ .failure = try self.recordReadFailure(error.EndOfStream) };
                    }
                    return .{ .failure = frame_failure };
                },
            };
            var body_owned = true;
            defer if (body_owned) {
                wipeSecret(body);
                self.allocator.free(body);
            };
            const value = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return .{ .failure = try policyFailure(
                    failure_policy,
                    err,
                    recordInvalidJson,
                    .{ self.allocator, err },
                ) };
            };
            defer {
                wipeJsonStrings(value.value);
                value.deinit();
            }
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
                    self.dispatchServerRequestTracked(
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
                    switch (try self.routeNotification(
                        failure_policy,
                        body,
                        notification.method,
                        notification.params,
                        value.value,
                    )) {
                        .success => |disposition| body_owned = switch (disposition) {
                            .reader_releases_frame => true,
                            .router_retains_frame => false,
                        },
                        .failure => |failure| return .{ .failure = failure },
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
                    defer {
                        wipeSecret(result_json);
                        self.allocator.free(result_json);
                    }
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
    ) !void {
        var operation: errors.ClientOperation = .callback;
        return self.dispatchServerRequestTracked(writer, id, method, params, &operation);
    }

    fn dispatchServerRequestTracked(
        self: *Client,
        writer: *std.Io.Writer,
        id: std.json.Value,
        method: []const u8,
        params: ?std.json.Value,
        failure_operation: *errors.ClientOperation,
    ) !void {
        if (std.mem.eql(u8, method, "hooks.invoke")) {
            return self.dispatchHookRequest(writer, id, params);
        }
        if (std.mem.eql(u8, method, "canvas.open") or
            std.mem.eql(u8, method, "canvas.close") or
            std.mem.eql(u8, method, "canvas.action.invoke"))
        {
            return self.dispatchCanvasRequest(writer, id, method, params);
        }
        if (std.mem.eql(u8, method, "providerToken.getToken") and
            self.findProviderTokenFromParams(params) != null)
        {
            return self.dispatchProviderTokenRequest(writer, id, params);
        }
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

    fn writeTypedSuccess(
        self: *Client,
        writer: *std.Io.Writer,
        id: std.json.Value,
        result: anytype,
    ) !void {
        const result_json = try std.json.Stringify.valueAlloc(self.allocator, result, .{
            .emit_null_optional_fields = false,
        });
        defer self.allocator.free(result_json);
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, result_json, .{});
        defer parsed.deinit();
        const response = try json_rpc.encodeSuccessResponse(self.allocator, id, parsed.value);
        defer self.allocator.free(response);
        try json_rpc.writeFrame(writer, response);
    }

    fn writeNullSuccess(
        self: *Client,
        writer: *std.Io.Writer,
        id: std.json.Value,
    ) !void {
        const result: std.json.Value = .null;
        const response = try json_rpc.encodeSuccessResponse(self.allocator, id, result);
        defer self.allocator.free(response);
        try json_rpc.writeFrame(writer, response);
    }

    fn dispatchHookRequest(
        self: *Client,
        writer: *std.Io.Writer,
        id: std.json.Value,
        params: ?std.json.Value,
    ) !void {
        const object = switch (params orelse
            return self.writeServerRequestError(writer, id, -32602, "invalid hook request")) {
            .object => |value| value,
            else => return self.writeServerRequestError(writer, id, -32602, "invalid hook request"),
        };
        const session_id = jsonRequiredString(object, "sessionId") catch
            return self.writeServerRequestError(writer, id, -32602, "invalid hook request");
        const hook_type = jsonRequiredString(object, "hookType") catch
            return self.writeServerRequestError(writer, id, -32602, "invalid hook request");
        const input = switch (object.get("input") orelse
            return self.writeServerRequestError(writer, id, -32602, "invalid hook request")) {
            .object => |value| value,
            else => return self.writeServerRequestError(writer, id, -32602, "invalid hook request"),
        };
        const runtime = self.findExtensionRuntime(session_id) orelse
            return self.writeServerRequestError(writer, id, -32000, "session not registered");
        const base = parseHookBase(input) catch
            return self.writeServerRequestError(writer, id, -32602, "invalid hook input");
        const invocation = ext.HookInvocation{ .session_id = session_id };
        self.dispatching_rpc_handler = true;
        defer self.dispatching_rpc_handler = false;

        if (std.mem.eql(u8, hook_type, "preToolUse")) {
            const handler = runtime.hooks.on_pre_tool_use orelse
                return self.writeTypedSuccess(writer, id, .{});
            const args = try stringifyJsonValue(
                self.allocator,
                jsonRequiredValue(input, "toolArgs") catch
                    return self.writeServerRequestError(writer, id, -32602, "invalid hook input"),
            );
            defer self.allocator.free(args);
            const output = handler(self.allocator, .{
                .base = base,
                .tool_name = jsonRequiredString(input, "toolName") catch
                    return self.writeServerRequestError(writer, id, -32602, "invalid hook input"),
                .tool_args_json = args,
            }, invocation, runtime.hooks.context) catch |err|
                return self.writeServerRequestError(writer, id, -32000, @errorName(err));
            const modified = parseOptionalJson(
                self.allocator,
                output.modified_args_json,
            ) catch return self.writeServerRequestError(
                writer,
                id,
                -32603,
                "invalid hook output",
            );
            defer if (modified) |value| value.deinit();
            return self.writeTypedSuccess(writer, id, .{ .output = .{
                .permissionDecision = output.permission_decision,
                .permissionDecisionReason = output.permission_decision_reason,
                .modifiedArgs = if (modified) |value| value.value else null,
                .additionalContext = output.additional_context,
                .suppressOutput = output.suppress_output,
            } });
        }
        if (std.mem.eql(u8, hook_type, "preMcpToolCall")) {
            const handler = runtime.hooks.on_pre_mcp_tool_call orelse
                return self.writeTypedSuccess(writer, id, .{});
            const arguments = try stringifyJsonValue(
                self.allocator,
                jsonRequiredValue(input, "arguments") catch
                    return self.writeServerRequestError(writer, id, -32602, "invalid hook input"),
            );
            defer self.allocator.free(arguments);
            const meta = if (input.get("_meta")) |value|
                try stringifyJsonValue(self.allocator, value)
            else
                null;
            defer if (meta) |value| self.allocator.free(value);
            const output = handler(self.allocator, .{
                .base = base,
                .tool_call_id = jsonOptionalString(input, "toolCallId") catch
                    return self.writeServerRequestError(writer, id, -32602, "invalid hook input"),
                .server_name = jsonRequiredString(input, "serverName") catch
                    return self.writeServerRequestError(writer, id, -32602, "invalid hook input"),
                .tool_name = jsonRequiredString(input, "toolName") catch
                    return self.writeServerRequestError(writer, id, -32602, "invalid hook input"),
                .arguments_json = arguments,
                .meta_json = meta,
            }, invocation, runtime.hooks.context) catch |err|
                return self.writeServerRequestError(writer, id, -32000, @errorName(err));
            const meta_value = parseOptionalJson(
                self.allocator,
                output.meta_to_use_json,
            ) catch return self.writeServerRequestError(
                writer,
                id,
                -32603,
                "invalid hook output",
            );
            defer if (meta_value) |value| value.deinit();
            return self.writeTypedSuccess(writer, id, .{ .output = .{
                .metaToUse = if (output.omit_meta)
                    std.json.Value.null
                else if (meta_value) |value|
                    value.value
                else
                    null,
            } });
        }
        if (std.mem.eql(u8, hook_type, "postToolUse")) {
            const handler = runtime.hooks.on_post_tool_use orelse
                return self.writeTypedSuccess(writer, id, .{});
            const args = try stringifyJsonValue(
                self.allocator,
                jsonRequiredValue(input, "toolArgs") catch
                    return self.writeServerRequestError(writer, id, -32602, "invalid hook input"),
            );
            defer self.allocator.free(args);
            const tool_result = try stringifyJsonValue(
                self.allocator,
                jsonRequiredValue(input, "toolResult") catch
                    return self.writeServerRequestError(writer, id, -32602, "invalid hook input"),
            );
            defer self.allocator.free(tool_result);
            const output = handler(self.allocator, .{
                .base = base,
                .tool_name = jsonRequiredString(input, "toolName") catch
                    return self.writeServerRequestError(writer, id, -32602, "invalid hook input"),
                .tool_args_json = args,
                .tool_result_json = tool_result,
            }, invocation, runtime.hooks.context) catch |err|
                return self.writeServerRequestError(writer, id, -32000, @errorName(err));
            const modified = parseOptionalJson(
                self.allocator,
                output.modified_result_json,
            ) catch return self.writeServerRequestError(
                writer,
                id,
                -32603,
                "invalid hook output",
            );
            defer if (modified) |value| value.deinit();
            return self.writeTypedSuccess(writer, id, .{ .output = .{
                .modifiedResult = if (modified) |value| value.value else null,
                .additionalContext = output.additional_context,
                .suppressOutput = output.suppress_output,
            } });
        }
        if (std.mem.eql(u8, hook_type, "postToolUseFailure")) {
            const handler = runtime.hooks.on_post_tool_use_failure orelse
                return self.writeTypedSuccess(writer, id, .{});
            const args = try stringifyJsonValue(
                self.allocator,
                jsonRequiredValue(input, "toolArgs") catch
                    return self.writeServerRequestError(writer, id, -32602, "invalid hook input"),
            );
            defer self.allocator.free(args);
            const output = handler(self.allocator, .{
                .base = base,
                .tool_name = jsonRequiredString(input, "toolName") catch
                    return self.writeServerRequestError(writer, id, -32602, "invalid hook input"),
                .tool_args_json = args,
                .message = jsonRequiredString(input, "error") catch
                    return self.writeServerRequestError(writer, id, -32602, "invalid hook input"),
            }, invocation, runtime.hooks.context) catch |err|
                return self.writeServerRequestError(writer, id, -32000, @errorName(err));
            return self.writeTypedSuccess(writer, id, .{ .output = .{
                .additionalContext = output.additional_context,
            } });
        }
        if (std.mem.eql(u8, hook_type, "userPromptSubmitted")) {
            const handler = runtime.hooks.on_user_prompt_submitted orelse
                return self.writeTypedSuccess(writer, id, .{});
            const output = handler(self.allocator, .{
                .base = base,
                .prompt = jsonRequiredString(input, "prompt") catch
                    return self.writeServerRequestError(writer, id, -32602, "invalid hook input"),
            }, invocation, runtime.hooks.context) catch |err|
                return self.writeServerRequestError(writer, id, -32000, @errorName(err));
            return self.writeTypedSuccess(writer, id, .{ .output = .{
                .modifiedPrompt = output.modified_prompt,
                .additionalContext = output.additional_context,
                .suppressOutput = output.suppress_output,
            } });
        }
        if (std.mem.eql(u8, hook_type, "userPromptTransformed")) {
            const handler = runtime.hooks.on_user_prompt_transformed orelse
                return self.writeTypedSuccess(writer, id, .{});
            const output = handler(self.allocator, .{
                .base = base,
                .prompt = jsonRequiredString(input, "prompt") catch
                    return self.writeServerRequestError(writer, id, -32602, "invalid hook input"),
                .transformed_prompt = jsonRequiredString(input, "transformedPrompt") catch
                    return self.writeServerRequestError(writer, id, -32602, "invalid hook input"),
            }, invocation, runtime.hooks.context) catch |err|
                return self.writeServerRequestError(writer, id, -32000, @errorName(err));
            return self.writeTypedSuccess(writer, id, .{ .output = .{
                .modifiedTransformedPrompt = output.modified_transformed_prompt,
            } });
        }
        if (std.mem.eql(u8, hook_type, "sessionStart")) {
            const handler = runtime.hooks.on_session_start orelse
                return self.writeTypedSuccess(writer, id, .{});
            const source_string = jsonRequiredString(input, "source") catch
                return self.writeServerRequestError(writer, id, -32602, "invalid hook input");
            const source: @TypeOf(@as(ext.SessionStartInput, undefined).source) =
                if (std.mem.eql(u8, source_string, "startup"))
                    .startup
                else if (std.mem.eql(u8, source_string, "resume"))
                    .resumed
                else if (std.mem.eql(u8, source_string, "new"))
                    .created
                else
                    return self.writeServerRequestError(writer, id, -32602, "invalid hook input");
            const output = handler(self.allocator, .{
                .base = base,
                .source = source,
                .initial_prompt = jsonOptionalString(input, "initialPrompt") catch
                    return self.writeServerRequestError(writer, id, -32602, "invalid hook input"),
            }, invocation, runtime.hooks.context) catch |err|
                return self.writeServerRequestError(writer, id, -32000, @errorName(err));
            const modified = parseOptionalJson(
                self.allocator,
                output.modified_config_json,
            ) catch return self.writeServerRequestError(
                writer,
                id,
                -32603,
                "invalid hook output",
            );
            defer if (modified) |value| value.deinit();
            return self.writeTypedSuccess(writer, id, .{ .output = .{
                .additionalContext = output.additional_context,
                .modifiedConfig = if (modified) |value| value.value else null,
            } });
        }
        if (std.mem.eql(u8, hook_type, "sessionEnd")) {
            const handler = runtime.hooks.on_session_end orelse
                return self.writeTypedSuccess(writer, id, .{});
            const reason_string = jsonRequiredString(input, "reason") catch
                return self.writeServerRequestError(writer, id, -32602, "invalid hook input");
            const reason: @TypeOf(@as(ext.SessionEndInput, undefined).reason) =
                if (std.mem.eql(u8, reason_string, "complete")) .complete else if (std.mem.eql(
                    u8,
                    reason_string,
                    "error",
                )) .@"error" else if (std.mem.eql(u8, reason_string, "abort")) .abort else if (std.mem.eql(
                    u8,
                    reason_string,
                    "timeout",
                )) .timeout else if (std.mem.eql(u8, reason_string, "user_exit")) .user_exit else return self.writeServerRequestError(writer, id, -32602, "invalid hook input");
            const output = handler(self.allocator, .{
                .base = base,
                .reason = reason,
                .final_message = jsonOptionalString(input, "finalMessage") catch
                    return self.writeServerRequestError(writer, id, -32602, "invalid hook input"),
                .message = jsonOptionalString(input, "error") catch
                    return self.writeServerRequestError(writer, id, -32602, "invalid hook input"),
            }, invocation, runtime.hooks.context) catch |err|
                return self.writeServerRequestError(writer, id, -32000, @errorName(err));
            return self.writeTypedSuccess(writer, id, .{ .output = .{
                .suppressOutput = output.suppress_output,
                .cleanupActions = output.cleanup_actions,
                .sessionSummary = output.session_summary,
            } });
        }
        if (std.mem.eql(u8, hook_type, "errorOccurred")) {
            const handler = runtime.hooks.on_error_occurred orelse
                return self.writeTypedSuccess(writer, id, .{});
            const context_string = jsonRequiredString(input, "errorContext") catch
                return self.writeServerRequestError(writer, id, -32602, "invalid hook input");
            const context: @TypeOf(@as(ext.ErrorOccurredInput, undefined).context) =
                if (std.mem.eql(u8, context_string, "model_call")) .model_call else if (std.mem.eql(
                    u8,
                    context_string,
                    "tool_execution",
                )) .tool_execution else if (std.mem.eql(u8, context_string, "system")) .system else if (std.mem.eql(
                    u8,
                    context_string,
                    "user_input",
                )) .user_input else return self.writeServerRequestError(writer, id, -32602, "invalid hook input");
            const output = handler(self.allocator, .{
                .base = base,
                .message = jsonRequiredString(input, "error") catch
                    return self.writeServerRequestError(writer, id, -32602, "invalid hook input"),
                .context = context,
                .recoverable = jsonRequiredBool(input, "recoverable") catch
                    return self.writeServerRequestError(writer, id, -32602, "invalid hook input"),
            }, invocation, runtime.hooks.context) catch |err|
                return self.writeServerRequestError(writer, id, -32000, @errorName(err));
            return self.writeTypedSuccess(writer, id, .{ .output = .{
                .suppressOutput = output.suppress_output,
                .errorHandling = output.handling,
                .retryCount = output.retry_count,
                .userNotification = output.user_notification,
            } });
        }
        if (std.mem.eql(u8, hook_type, "agentStop")) {
            const handler = runtime.hooks.on_agent_stop orelse
                return self.writeTypedSuccess(writer, id, .{});
            const output = handler(self.allocator, .{
                .base = base,
                .stop_reason = jsonOptionalString(input, "stopReason") catch
                    return self.writeServerRequestError(writer, id, -32602, "invalid hook input"),
                .transcript_path = jsonOptionalString(input, "transcriptPath") catch
                    return self.writeServerRequestError(writer, id, -32602, "invalid hook input"),
                .stop_hook_active = (jsonOptionalBool(input, "stop_hook_active") catch
                    return self.writeServerRequestError(writer, id, -32602, "invalid hook input")) orelse false,
            }, invocation, runtime.hooks.context) catch |err|
                return self.writeServerRequestError(writer, id, -32000, @errorName(err));
            return self.writeTypedSuccess(writer, id, .{ .output = .{
                .decision = if (output.block) "block" else null,
                .reason = output.reason,
            } });
        }
        return self.writeServerRequestError(writer, id, -32602, "unknown hook type");
    }

    fn dispatchCanvasRequest(
        self: *Client,
        writer: *std.Io.Writer,
        id: std.json.Value,
        method: []const u8,
        params: ?std.json.Value,
    ) !void {
        const object = switch (params orelse
            return self.writeServerRequestError(writer, id, -32602, "invalid canvas request")) {
            .object => |value| value,
            else => return self.writeServerRequestError(writer, id, -32602, "invalid canvas request"),
        };
        const session_id = jsonRequiredString(object, "sessionId") catch
            return self.writeServerRequestError(writer, id, -32602, "invalid canvas request");
        const runtime = self.findExtensionRuntime(session_id) orelse
            return self.writeServerRequestError(writer, id, -32000, "session not registered");
        const canvas_id = jsonRequiredString(object, "canvasId") catch
            return self.writeServerRequestError(writer, id, -32602, "invalid canvas request");
        var canvas: ?*OwnedCanvas = null;
        for (runtime.canvases) |*candidate| {
            if (std.mem.eql(u8, candidate.id, canvas_id)) {
                canvas = candidate;
                break;
            }
        }
        const registered = canvas orelse
            return self.writeServerRequestError(writer, id, -32000, "canvas not registered");
        const extension_id = jsonRequiredString(object, "extensionId") catch
            return self.writeServerRequestError(writer, id, -32602, "invalid canvas request");
        const instance_id = jsonRequiredString(object, "instanceId") catch
            return self.writeServerRequestError(writer, id, -32602, "invalid canvas request");
        const host_json = if (object.get("host")) |value|
            try stringifyJsonValue(self.allocator, value)
        else
            null;
        defer if (host_json) |value| self.allocator.free(value);
        const session_json = if (object.get("session")) |value|
            try stringifyJsonValue(self.allocator, value)
        else
            null;
        defer if (session_json) |value| self.allocator.free(value);
        self.dispatching_rpc_handler = true;
        defer self.dispatching_rpc_handler = false;

        if (std.mem.eql(u8, method, "canvas.open")) {
            const input_json = if (object.get("input")) |value|
                try stringifyJsonValue(self.allocator, value)
            else
                null;
            defer if (input_json) |value| self.allocator.free(value);
            const output = registered.on_open(self.allocator, .{
                .extension_id = extension_id,
                .canvas_id = canvas_id,
                .instance_id = instance_id,
                .input_json = input_json,
                .host_json = host_json,
                .session_json = session_json,
            }, registered.context) catch |err|
                return self.writeServerRequestError(writer, id, -32000, @errorName(err));
            return self.writeTypedSuccess(writer, id, output);
        }
        if (std.mem.eql(u8, method, "canvas.close")) {
            if (registered.on_close) |handler| {
                handler(.{
                    .extension_id = extension_id,
                    .canvas_id = canvas_id,
                    .instance_id = instance_id,
                    .host_json = host_json,
                    .session_json = session_json,
                }, registered.context) catch |err|
                    return self.writeServerRequestError(writer, id, -32000, @errorName(err));
            }
            return self.writeNullSuccess(writer, id);
        }
        const action_name = jsonRequiredString(object, "actionName") catch
            return self.writeServerRequestError(writer, id, -32602, "invalid canvas request");
        for (registered.actions) |action| {
            if (!std.mem.eql(u8, action.name, action_name)) continue;
            const input_json = if (object.get("input")) |value|
                try stringifyJsonValue(self.allocator, value)
            else
                null;
            defer if (input_json) |value| self.allocator.free(value);
            const output_json = action.handler(self.allocator, .{
                .extension_id = extension_id,
                .canvas_id = canvas_id,
                .instance_id = instance_id,
                .action_name = action_name,
                .input_json = input_json,
                .host_json = host_json,
                .session_json = session_json,
            }, registered.context) catch |err|
                return self.writeServerRequestError(writer, id, -32000, @errorName(err));
            defer self.allocator.free(output_json);
            const output = std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                output_json,
                .{},
            ) catch return self.writeServerRequestError(
                writer,
                id,
                -32603,
                "invalid canvas action result",
            );
            defer output.deinit();
            const response = try json_rpc.encodeSuccessResponse(self.allocator, id, output.value);
            defer self.allocator.free(response);
            return json_rpc.writeFrame(writer, response);
        }
        return self.writeServerRequestError(writer, id, -32000, "canvas action not registered");
    }

    fn dispatchProviderTokenRequest(
        self: *Client,
        writer: *std.Io.Writer,
        id: std.json.Value,
        params: ?std.json.Value,
    ) !void {
        const value = params orelse
            return self.writeServerRequestError(writer, id, -32602, "invalid provider token request");
        const parsed = std.json.parseFromValue(
            WireProviderTokenRequest,
            self.allocator,
            value,
            .{},
        ) catch {
            return self.writeServerRequestError(writer, id, -32602, "invalid provider token request");
        };
        defer parsed.deinit();

        const token_provider = self.findProviderToken(
            parsed.value.sessionId,
            parsed.value.providerName,
        ) orelse return self.writeServerRequestError(
            writer,
            id,
            -32000,
            "bearer token provider not registered",
        );

        self.dispatching_rpc_handler = true;
        defer self.dispatching_rpc_handler = false;
        const token = token_provider.callback(self.allocator, .{
            .session_id = parsed.value.sessionId,
            .provider_name = parsed.value.providerName,
        }, token_provider.context) catch |err| {
            return self.writeServerRequestError(writer, id, -32000, @errorName(err));
        };
        defer self.allocator.free(token);

        const response = try json_rpc.encodeSuccessResponse(self.allocator, id, .{ .token = token });
        defer self.allocator.free(response);
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
        const value = params orelse
            return self.writeServerRequestError(writer, id, -32602, "invalid user input request");
        const parsed = std.json.parseFromValue(
            WireUserInputRequest,
            self.allocator,
            value,
            .{ .ignore_unknown_fields = true },
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

        const frame = try json_rpc.encodeSuccessResponse(
            self.allocator,
            id,
            .{
                .answer = response.answer,
                .wasFreeform = response.was_freeform,
            },
        );
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
        var event = event: {
            const parsed_event = session_types.parseEventClassified(
                self.allocator,
                event_value,
            ) catch |err| {
                if (agent_view) |view| {
                    const data_value = event_value.object.get("data").?;
                    break :event ownFallbackSessionErrorEvent(
                        self.allocator,
                        view,
                        data_value,
                    ) catch |fallback_err| {
                        if (fallback_err == error.OutOfMemory) return error.OutOfMemory;
                        return .{ .failure = try policyFailure(
                            failure_policy,
                            error.InvalidSessionEvent,
                            recordInvalidEvent,
                            .{ self.allocator, .malformed_field_type, event_value },
                        ) };
                    };
                }
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
            break :event parsed_event;
        };
        defer if (!transferred) event.deinit(self.allocator);
        try self.applyExtensionEvent(session_id, &event);
        const owned_session_id = try self.allocator.dupe(u8, session_id);
        defer if (!transferred) self.allocator.free(owned_session_id);
        const diagnostic_frame = if (agent_view != null) frame else null;
        try self.events.append(self.allocator, .{
            .session_id = owned_session_id,
            .event = event,
            .diagnostic_frame = diagnostic_frame,
        });
        transferred = true;
        return .{ .success = agent_view != null };
    }

    fn queueLifecycleEvent(
        self: *Client,
        comptime failure_policy: FailurePolicy,
        params_value: std.json.Value,
    ) errors.DetailedError!PolicyResult(failure_policy, void) {
        const event = admin.parseLifecycleEvent(self.allocator, params_value) catch |err| switch (err) {
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
                        params_value,
                    },
                ),
            },
        };
        self.lifecycle_events.push(event);
        return .{ .success = {} };
    }

    const NotificationFrameDisposition = enum {
        reader_releases_frame,
        router_retains_frame,
    };

    fn routeNotification(
        self: *Client,
        comptime failure_policy: FailurePolicy,
        frame: []u8,
        method: []const u8,
        params: ?std.json.Value,
        envelope: std.json.Value,
    ) errors.DetailedError!PolicyResult(
        failure_policy,
        NotificationFrameDisposition,
    ) {
        if (!std.mem.eql(u8, method, "session.event") and
            !std.mem.eql(u8, method, "session.lifecycle"))
        {
            return .{ .success = .reader_releases_frame };
        }
        const params_value = params orelse
            return .{ .failure = try policyFailure(
                failure_policy,
                error.InvalidJsonRpc,
                recordInvalidEnvelope,
                .{
                    self.allocator,
                    error.InvalidJsonRpc,
                    .missing_params,
                    envelope,
                },
            ) };
        if (std.mem.eql(u8, method, "session.event")) {
            return switch (try self.queueSessionEvent(failure_policy, frame, params_value)) {
                .success => |retained| .{ .success = if (retained)
                    .router_retains_frame
                else
                    .reader_releases_frame },
                .failure => |failure| .{ .failure = failure },
            };
        }
        return switch (try self.queueLifecycleEvent(failure_policy, params_value)) {
            .success => .{ .success = .reader_releases_frame },
            .failure => |failure| .{ .failure = failure },
        };
    }

    fn findExtensionRuntime(self: *Client, session_id: []const u8) ?*SessionExtensionRuntime {
        if (self.pending_extension_runtime) |*runtime| {
            if (runtime.session_id) |id| {
                if (std.mem.eql(u8, id, session_id)) return runtime;
            }
        }
        for (self.extension_runtimes.items) |*runtime| {
            if (runtime.session_id) |id| {
                if (std.mem.eql(u8, id, session_id)) return runtime;
            }
        }
        if (self.pending_extension_runtime) |*runtime| {
            if (runtime.session_id == null) return runtime;
        }
        return null;
    }

    fn applyExtensionEvent(
        self: *Client,
        session_id: []const u8,
        event: *const session_types.SessionEvent,
    ) !void {
        if (self.pending_extension_runtime) |*runtime| {
            if (runtime.session_id) |id| {
                if (std.mem.eql(u8, id, session_id)) {
                    try applyExtensionEventToRuntime(self.allocator, runtime, event);
                }
            } else {
                try applyExtensionEventToRuntime(self.allocator, runtime, event);
            }
        }
        for (self.extension_runtimes.items) |*runtime| {
            if (runtime.session_id) |id| {
                if (std.mem.eql(u8, id, session_id)) {
                    try applyExtensionEventToRuntime(self.allocator, runtime, event);
                    return;
                }
            }
        }
    }

    fn applyExtensionEventToRuntime(
        allocator: std.mem.Allocator,
        runtime: *SessionExtensionRuntime,
        event: *const session_types.SessionEvent,
    ) !void {
        switch (event.*) {
            .capabilities_changed => |payload| {
                if (payload.data.ui) |ui| {
                    if (ui.canvases) |canvases| {
                        runtime.capabilities.canvases = capabilityState(canvases);
                    }
                    if (ui.mcp_apps) |mcp_apps| {
                        runtime.capabilities.mcp_apps = capabilityState(mcp_apps);
                    }
                }
            },
            .session_canvas_closed => |payload| {
                removeOpenCanvas(runtime, allocator, payload.data.instance_id);
            },
            .session_canvas_opened => |payload| {
                const canvas = try cloneTypedOpenCanvas(
                    allocator,
                    payload.data,
                );
                errdefer ext.freeOpenCanvas(allocator, canvas);
                try upsertOpenCanvas(runtime, allocator, canvas);
            },
            else => {},
        }
    }

    fn removeSession(self: *Client, session_id: []const u8) void {
        for (self.extension_runtimes.items, 0..) |runtime, runtime_index| {
            if (runtime.session_id != null and
                std.mem.eql(u8, runtime.session_id.?, session_id))
            {
                var removed = self.extension_runtimes.orderedRemove(runtime_index);
                removed.deinit(self.allocator);
                break;
            }
        }
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

        self.removeSessionId(session_id);
    }

    fn findSessionId(self: *Client, session_id: []const u8) ?[]u8 {
        for (self.session_ids.items) |id| {
            if (std.mem.eql(u8, id, session_id)) return id;
        }
        return null;
    }

    fn removeSessionId(self: *Client, session_id: []const u8) void {
        var provider_token_index: usize = 0;
        while (provider_token_index < self.provider_tokens.items.len) {
            if (std.mem.eql(
                u8,
                self.provider_tokens.items[provider_token_index].session_id,
                session_id,
            )) {
                const registered = self.provider_tokens.orderedRemove(provider_token_index);
                registered.deinit(self.allocator);
            } else {
                provider_token_index += 1;
            }
        }

        for (self.session_ids.items, 0..) |id, session_index| {
            if (std.mem.eql(u8, id, session_id)) {
                self.allocator.free(id);
                _ = self.session_ids.orderedRemove(session_index);
                if (self.session_ids.items.len == 0) {
                    self.session_ids.deinit(self.allocator);
                    self.session_ids = .empty;
                }
                return;
            }
        }
    }

    fn registerOwnedSession(
        self: *Client,
        owned_session_id: []u8,
        config: session_types.SessionConfig,
        token_bindings: []const provider.TokenBinding,
    ) !void {
        if (self.hasSession(owned_session_id)) {
            self.allocator.free(owned_session_id);
            return error.SessionAlreadyActive;
        }

        self.session_ids.append(self.allocator, owned_session_id) catch |err| {
            self.allocator.free(owned_session_id);
            return err;
        };
        errdefer self.removeSession(owned_session_id);

        try self.registerToolHandlers(owned_session_id, config.tools);
        try self.registerPermissionHandler(owned_session_id, config);
        try self.registerUserInputHandler(
            owned_session_id,
            config.on_user_input_request,
            config.user_input_context,
        );
        try self.registerProviderTokens(owned_session_id, token_bindings);
    }

    fn hasSession(self: *Client, session_id: []const u8) bool {
        for (self.session_ids.items) |registered| {
            if (std.mem.eql(u8, registered, session_id)) return true;
        }
        return false;
    }

    fn registerProviderTokens(
        self: *Client,
        session_id: []const u8,
        bindings: []const provider.TokenBinding,
    ) !void {
        if (bindings.len == 0) return;
        const registered = try self.allocator.alloc(RegisteredProviderToken, bindings.len);
        var initialized: usize = 0;
        errdefer {
            for (registered[0..initialized]) |value| value.deinit(self.allocator);
            self.allocator.free(registered);
        }
        for (bindings, 0..) |binding, index| {
            registered[index] = .{
                .provider_name = try self.allocator.dupe(u8, binding.provider_name),
                .token_provider = binding.token_provider,
            };
            initialized += 1;
        }
        try self.provider_tokens.append(self.allocator, .{
            .session_id = session_id,
            .providers = registered,
        });
    }

    fn beginProviderTokens(
        self: *Client,
        session_id: []const u8,
        bindings: []const provider.TokenBinding,
    ) !void {
        if (self.pending_provider_tokens != null) return error.ProviderTokensPending;
        if (bindings.len != 0) {
            try self.provider_tokens.ensureUnusedCapacity(self.allocator, 1);
        }

        const registered = try self.allocator.alloc(RegisteredProviderToken, bindings.len);
        var initialized: usize = 0;
        errdefer {
            for (registered[0..initialized]) |value| value.deinit(self.allocator);
            self.allocator.free(registered);
        }
        for (bindings, 0..) |binding, index| {
            registered[index] = .{
                .provider_name = try self.allocator.dupe(u8, binding.provider_name),
                .token_provider = binding.token_provider,
            };
            initialized += 1;
        }
        self.pending_provider_tokens = .{
            .session_id = session_id,
            .providers = registered,
        };
    }

    fn rollbackProviderTokens(self: *Client) void {
        const registered = self.pending_provider_tokens orelse return;
        self.pending_provider_tokens = null;
        registered.deinit(self.allocator);
    }

    fn commitProviderTokens(self: *Client) void {
        const pending = self.pending_provider_tokens orelse return;
        self.pending_provider_tokens = null;

        for (self.provider_tokens.items, 0..) |registered, index| {
            if (!std.mem.eql(u8, registered.session_id, pending.session_id)) continue;
            registered.deinit(self.allocator);
            if (pending.providers.len == 0) {
                pending.deinit(self.allocator);
                _ = self.provider_tokens.orderedRemove(index);
                return;
            }
            self.provider_tokens.items[index] = pending;
            return;
        }
        if (pending.providers.len == 0) {
            pending.deinit(self.allocator);
            return;
        }
        self.provider_tokens.appendAssumeCapacity(pending);
    }

    fn findProviderToken(
        self: *Client,
        session_id: []const u8,
        provider_name: []const u8,
    ) ?provider.BearerTokenProvider {
        if (self.pending_provider_tokens) |pending| {
            if (std.mem.eql(u8, pending.session_id, session_id)) {
                for (pending.providers) |registered| {
                    if (std.mem.eql(u8, registered.provider_name, provider_name)) {
                        return registered.token_provider;
                    }
                }
                return null;
            }
        }
        for (self.provider_tokens.items) |session_providers| {
            if (!std.mem.eql(u8, session_providers.session_id, session_id)) continue;
            for (session_providers.providers) |registered| {
                if (std.mem.eql(u8, registered.provider_name, provider_name)) {
                    return registered.token_provider;
                }
            }
            return null;
        }
        return null;
    }

    fn findProviderTokenFromParams(
        self: *Client,
        params: ?std.json.Value,
    ) ?provider.BearerTokenProvider {
        const object = switch (params orelse return null) {
            .object => |object| object,
            else => return null,
        };
        const session_id = switch (object.get("sessionId") orelse return null) {
            .string => |value| value,
            else => return null,
        };
        const provider_name = switch (object.get("providerName") orelse return null) {
            .string => |value| value,
            else => return null,
        };
        return self.findProviderToken(session_id, provider_name);
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
        if (self.findExtensionRuntime(session_id)) |runtime| {
            for (runtime.tools) |tool| {
                if (std.mem.eql(u8, tool.name, name)) return .{
                    .session_id = session_id,
                    .name = tool.name,
                    .handler = tool.handler,
                    .context = tool.context,
                };
            }
        }
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
        config: anytype,
    ) !void {
        const optional_callback: ?session_types.PermissionHandler = config.on_permission_request;
        const callback = optional_callback orelse return;
        try self.permission_handlers.append(self.allocator, .{
            .session_id = session_id,
            .handler = callback,
            .managed_settings_enabled = managedSettingsEnabled(config),
            .context = if (@hasField(@TypeOf(config), "permission_context"))
                config.permission_context
            else
                null,
        });
    }

    fn findPermissionHandler(
        self: *Client,
        session_id: []const u8,
    ) ?RegisteredPermissionHandler {
        if (self.findExtensionRuntime(session_id)) |runtime| {
            if (runtime.permission_handler) |handler| return .{
                .session_id = session_id,
                .handler = handler,
                .managed_settings_enabled = runtime.managed_settings_enabled,
                .context = runtime.permission_context,
            };
        }
        for (self.permission_handlers.items) |registered| {
            if (std.mem.eql(u8, registered.session_id, session_id)) return registered;
        }
        return null;
    }

    fn findUserInputHandler(
        self: *Client,
        session_id: []const u8,
    ) ?RegisteredUserInputHandler {
        if (self.findExtensionRuntime(session_id)) |runtime| {
            if (runtime.user_input_handler) |handler| return .{
                .session_id = session_id,
                .handler = handler,
                .context = runtime.user_input_context,
            };
        }
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

    pub fn nextLifecycleEvent(self: *Client) !admin.SessionLifecycleDelivery {
        return legacyResult(
            admin.SessionLifecycleDelivery,
            self.nextLifecycleEventImpl(.legacy),
        );
    }

    pub fn nextLifecycleEventDetailed(
        self: *Client,
    ) errors.DetailedError!errors.DetailedResult(admin.SessionLifecycleDelivery) {
        return self.nextLifecycleEventImpl(.detailed);
    }

    fn nextLifecycleEventImpl(
        self: *Client,
        comptime failure_policy: FailurePolicy,
    ) errors.DetailedError!PolicyResult(failure_policy, admin.SessionLifecycleDelivery) {
        while (true) {
            if (self.lifecycle_events.popDelivery()) |delivery| {
                return .{ .success = delivery };
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
                    if (isTransportEndOfStream(&frame_failure)) {
                        frame_failure.deinit();
                        return .{ .failure = try self.recordReadFailure(error.EndOfStream) };
                    }
                    return .{ .failure = frame_failure };
                },
            };
            var body_owned = true;
            defer if (body_owned) {
                wipeSecret(body);
                self.allocator.free(body);
            };
            const value = std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                body,
                .{},
            ) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return .{ .failure = try policyFailure(
                    failure_policy,
                    err,
                    recordInvalidJson,
                    .{ self.allocator, err },
                ) };
            };
            defer {
                wipeJsonStrings(value.value);
                value.deinit();
            }
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
                    self.dispatchServerRequestTracked(
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
                    switch (try self.routeNotification(
                        failure_policy,
                        body,
                        notification.method,
                        notification.params,
                        value.value,
                    )) {
                        .success => |disposition| body_owned = switch (disposition) {
                            .reader_releases_frame => true,
                            .router_retains_frame => false,
                        },
                        .failure => |failure| return .{ .failure = failure },
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
                    if (isTransportEndOfStream(&frame_failure)) {
                        frame_failure.deinit();
                        return .{ .failure = try self.recordReadFailure(error.EndOfStream) };
                    }
                    return .{ .failure = frame_failure };
                },
            };
            var body_owned = true;
            defer if (body_owned) {
                wipeSecret(body);
                self.allocator.free(body);
            };
            const value = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return .{ .failure = try policyFailure(
                    failure_policy,
                    err,
                    recordInvalidJson,
                    .{ self.allocator, err },
                ) };
            };
            defer {
                wipeJsonStrings(value.value);
                value.deinit();
            }
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
                    self.dispatchServerRequestTracked(
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
                    switch (try self.routeNotification(
                        failure_policy,
                        body,
                        notification.method,
                        notification.params,
                        value.value,
                    )) {
                        .success => |disposition| body_owned = switch (disposition) {
                            .reader_releases_frame => true,
                            .router_retains_frame => false,
                        },
                        .failure => |failure| return .{ .failure = failure },
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
        const parsed = switch (try self.client.callImpl(
            failure_policy,
            struct { messageId: []const u8 },
            "session.send",
            lowerMessage(self.id, options),
            .{ .session = .{ .session_id = self.id } },
        )) {
            .success => |value| value,
            .failure => |failure| return .{ .failure = failure },
        };
        defer parsed.deinit();
        return .{ .success = try self.client.allocator.dupe(u8, parsed.value.messageId) };
    }

    pub fn getEvents(self: Session) !session_types.SessionEventHistory {
        return legacyResult(
            session_types.SessionEventHistory,
            self.getEventsImpl(.legacy),
        );
    }

    pub fn getEventsDetailed(
        self: Session,
    ) errors.DetailedError!errors.DetailedResult(session_types.SessionEventHistory) {
        return self.getEventsImpl(.detailed);
    }

    fn getEventsImpl(
        self: Session,
        comptime failure_policy: FailurePolicy,
    ) errors.DetailedError!PolicyResult(failure_policy, session_types.SessionEventHistory) {
        const parsed = switch (try self.client.callImpl(
            failure_policy,
            admin.SessionGetMessagesResult,
            "session.getMessages",
            admin.SessionIdParams{ .sessionId = self.id },
            .{ .session = .{ .session_id = self.id } },
        )) {
            .success => |value| value,
            .failure => |failure| return .{ .failure = failure },
        };
        defer parsed.deinit();

        const events = try self.client.allocator.alloc(
            session_types.SessionEvent,
            parsed.value.events.len,
        );
        var initialized: usize = 0;
        for (parsed.value.events, events) |value, *event| {
            event.* = session_types.parseEventClassified(
                self.client.allocator,
                value,
            ) catch |err| switch (err) {
                error.OutOfMemory => {
                    for (events[0..initialized]) |*owned_event|
                        owned_event.deinit(self.client.allocator);
                    self.client.allocator.free(events);
                    return error.OutOfMemory;
                },
                error.MissingField, error.MalformedFieldType => {
                    for (events[0..initialized]) |*owned_event|
                        owned_event.deinit(self.client.allocator);
                    self.client.allocator.free(events);
                    return .{ .failure = try policyFailure(
                        failure_policy,
                        error.InvalidSessionEvent,
                        recordInvalidEvent,
                        .{
                            self.client.allocator,
                            if (err == error.MissingField)
                                errors.EnvelopeViolation.missing_params
                            else
                                errors.EnvelopeViolation.malformed_field_type,
                            value,
                        },
                    ) };
                },
            };
            initialized += 1;
        }
        return .{ .success = .{
            .allocator = self.client.allocator,
            .events = events,
        } };
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
            switch (delivery.event) {
                .assistant_message => |*message| {
                    if (response) |previous| previous.deinit(self.client.allocator);
                    response = message.*;
                    delivery.event = .{ .session_idle = .{} };
                },
                .session_idle => |idle| {
                    if (completesSendAndWait(idle)) {
                        response_owned = false;
                        return .{ .success = response };
                    }
                },
                .session_error => {
                    if (comptime failure_policy == .detailed) {
                        delivery_owned = false;
                        return .{ .failure = try delivery.intoFailure(self.client.allocator) };
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
                switch (delivery.event) {
                    .session_error => return .{ .failure = try delivery.intoFailure(
                        self.client.allocator,
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
        if (delivery.event == .mcp_oauth_required) {
            self.handleMcpAuthEvent(delivery.event.mcp_oauth_required.data_json) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return .{ .failure = try policyFailure(
                    failure_policy,
                    err,
                    recordClientIo,
                    .{ self.client.allocator, .callback, err },
                ) };
            };
        }
        if (delivery.event == .external_tool_requested) {
            const request = delivery.event.external_tool_requested;
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
        if (delivery.event == .permission_requested) {
            const request = delivery.event.permission_requested;
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
                        delivery.event.permission_requested.automatic_handling =
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
                                delivery.event.permission_requested.automatic_handling =
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
                                delivery.event.permission_requested.automatic_handling =
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
                                delivery.event.permission_requested.automatic_handling =
                                    .{ .delivery_failed = failure_value.native_error };
                                delivery_owned = false;
                                return .{ .success = delivery };
                            }
                            return .{ .failure = failure_value };
                        },
                    },
                    .no_result => {
                        delivery.event.permission_requested.automatic_handling = .no_result;
                        delivery_owned = false;
                        return .{ .success = delivery };
                    },
                }
                delivery.event.permission_requested.automatic_handling = .handled;
            }
        }
        delivery_owned = false;
        return .{ .success = delivery };
    }

    pub fn capabilities(self: Session) ext.CapabilitySet {
        const runtime = self.client.findExtensionRuntime(self.id) orelse return .{};
        return runtime.capabilities;
    }

    pub fn experimental(
        self: Session,
        comptime feature: ext.ExperimentalFeature,
    ) !switch (feature) {
        .mcp_apps => McpApps,
    } {
        return switch (feature) {
            .mcp_apps => blk: {
                const runtime = self.client.findExtensionRuntime(self.id) orelse
                    return error.UnsupportedCapability;
                if (!runtime.mcp_apps_requested)
                    return error.ExperimentalFeatureNotRequested;
                if (!runtime.capabilities.supports(.mcp_apps))
                    return error.UnsupportedCapability;
                break :blk .{ .session = self };
            },
        };
    }

    pub fn openCanvas(
        self: Session,
        allocator: std.mem.Allocator,
        request: ext.OpenCanvasRequest,
    ) !ext.OpenCanvasResult {
        const runtime = self.client.findExtensionRuntime(self.id) orelse
            return error.UnsupportedCapability;
        if (!runtime.capabilities.supports(.canvases))
            return error.UnsupportedCapability;
        const input = if (request.input_json) |json|
            try std.json.parseFromSlice(std.json.Value, self.client.allocator, json, .{})
        else
            null;
        defer if (input) |value| value.deinit();
        const parsed = try self.client.call(WireOpenCanvas, "session.canvas.open", .{
            .sessionId = self.id,
            .extensionId = request.extension_id,
            .canvasId = request.canvas_id,
            .instanceId = request.instance_id,
            .input = if (input) |value| value.value else null,
        });
        defer parsed.deinit();
        const state_value = try cloneWireOpenCanvas(self.client.allocator, parsed.value);
        upsertOpenCanvas(runtime, self.client.allocator, state_value) catch |err| {
            ext.freeOpenCanvas(self.client.allocator, state_value);
            return err;
        };
        return .{
            .allocator = allocator,
            .value = try cloneWireOpenCanvas(allocator, parsed.value),
        };
    }

    pub fn closeCanvas(self: Session, instance_id: []const u8) !void {
        const runtime = self.client.findExtensionRuntime(self.id) orelse
            return error.UnsupportedCapability;
        if (!runtime.capabilities.supports(.canvases))
            return error.UnsupportedCapability;
        const parsed = try self.client.call(std.json.Value, "session.canvas.close", .{
            .sessionId = self.id,
            .instanceId = instance_id,
        });
        parsed.deinit();
        removeOpenCanvas(runtime, self.client.allocator, instance_id);
    }

    pub fn invokeCanvasAction(
        self: Session,
        allocator: std.mem.Allocator,
        request: ext.InvokeCanvasActionRequest,
    ) !ext.OwnedJson {
        const runtime = self.client.findExtensionRuntime(self.id) orelse
            return error.UnsupportedCapability;
        if (!runtime.capabilities.supports(.canvases))
            return error.UnsupportedCapability;
        const input = if (request.input_json) |json|
            try std.json.parseFromSlice(std.json.Value, self.client.allocator, json, .{})
        else
            null;
        defer if (input) |value| value.deinit();
        const parsed = try self.client.call(std.json.Value, "session.canvas.action.invoke", .{
            .sessionId = self.id,
            .instanceId = request.instance_id,
            .actionName = request.action_name,
            .input = if (input) |value| value.value else null,
        });
        defer parsed.deinit();
        return .{
            .allocator = allocator,
            .json = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{}),
        };
    }

    pub fn snapshotOpenCanvases(
        self: Session,
        allocator: std.mem.Allocator,
    ) !ext.OpenCanvasSnapshot {
        const runtime = self.client.findExtensionRuntime(self.id) orelse
            return .{ .allocator = allocator, .items = try allocator.alloc(ext.OpenCanvas, 0) };
        const items = try allocator.alloc(ext.OpenCanvas, runtime.open_canvases.items.len);
        var initialized: usize = 0;
        errdefer {
            for (items[0..initialized]) |item| ext.freeOpenCanvas(allocator, item);
            allocator.free(items);
        }
        for (runtime.open_canvases.items, 0..) |item, index| {
            items[index] = try cloneOpenCanvas(allocator, item);
            initialized += 1;
        }
        return .{ .allocator = allocator, .items = items };
    }

    pub fn snapshotEnvironmentGrants(
        self: Session,
        allocator: std.mem.Allocator,
    ) !ext.EnvironmentGrants {
        const runtime = self.client.findExtensionRuntime(self.id) orelse return .{
            .allocator = allocator,
            .items = try allocator.alloc(ext.EnvironmentGrant, 0),
        };
        const items = try allocator.alloc(
            ext.EnvironmentGrant,
            runtime.granted_environment_variables.items.len,
        );
        var initialized: usize = 0;
        errdefer {
            for (items[0..initialized]) |item| {
                allocator.free(item.name);
                wipeSecret(item.value);
                allocator.free(item.value);
            }
            allocator.free(items);
        }
        for (runtime.granted_environment_variables.items, 0..) |grant, index| {
            const name = try allocator.dupe(u8, grant.name);
            errdefer allocator.free(name);
            items[index] = .{
                .name = name,
                .value = try allocator.dupe(u8, grant.value),
            };
            initialized += 1;
        }
        return .{ .allocator = allocator, .items = items };
    }

    fn handleMcpAuthEvent(self: Session, data_json: []const u8) !void {
        const runtime = self.client.findExtensionRuntime(self.id) orelse return;
        const handler = runtime.mcp_auth_handler orelse return;
        const parsed = try std.json.parseFromSlice(
            WireMcpAuthRequest,
            self.client.allocator,
            data_json,
            .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
        );
        defer {
            wipeSecret(parsed.value.requestId);
            wipeSecret(parsed.value.serverName);
            wipeSecret(parsed.value.serverUrl);
            if (parsed.value.resourceMetadata) |value| wipeSecret(value);
            if (parsed.value.wwwAuthenticateParams) |value| wipeJsonStrings(value);
            if (parsed.value.httpResponse) |value| wipeJsonStrings(value);
            if (parsed.value.staticClientConfig) |value| wipeJsonStrings(value);
            parsed.deinit();
        }
        const www_json = if (parsed.value.wwwAuthenticateParams) |value|
            try std.json.Stringify.valueAlloc(self.client.allocator, value, .{})
        else
            null;
        defer if (www_json) |value| {
            wipeSecret(value);
            self.client.allocator.free(value);
        };
        const http_json = if (parsed.value.httpResponse) |value|
            try std.json.Stringify.valueAlloc(self.client.allocator, value, .{})
        else
            null;
        defer if (http_json) |value| {
            wipeSecret(value);
            self.client.allocator.free(value);
        };
        const static_json = if (parsed.value.staticClientConfig) |value|
            try std.json.Stringify.valueAlloc(self.client.allocator, value, .{})
        else
            null;
        defer if (static_json) |value| {
            wipeSecret(value);
            self.client.allocator.free(value);
        };
        var outcome = invokeMcpAuthHandler(handler, self.client.allocator, .{
            .request_id = parsed.value.requestId,
            .server_name = parsed.value.serverName,
            .server_url = parsed.value.serverUrl,
            .reason = parsed.value.reason,
            .resource_metadata = parsed.value.resourceMetadata,
            .www_authenticate_json = www_json,
            .http_response_json = http_json,
            .static_client_config_json = static_json,
        }, runtime.mcp_auth_context);
        const response = switch (outcome.result) {
            .cancelled => self.client.call(
                RpcSuccess,
                "session.mcp.oauth.handlePendingRequest",
                .{
                    .sessionId = self.id,
                    .requestId = parsed.value.requestId,
                    .result = .{ .kind = "cancelled" },
                },
            ),
            .token => |*token| blk: {
                defer token.deinitSecure(self.client.allocator);
                if (token.expires_in_seconds) |expires_in_seconds| {
                    if (expires_in_seconds == 0) {
                        outcome.handler_error = error.InvalidMcpAuthTokenExpiration;
                        break :blk self.client.call(
                            RpcSuccess,
                            "session.mcp.oauth.handlePendingRequest",
                            .{
                                .sessionId = self.id,
                                .requestId = parsed.value.requestId,
                                .result = .{ .kind = "cancelled" },
                            },
                        );
                    }
                }
                break :blk self.client.call(
                    RpcSuccess,
                    "session.mcp.oauth.handlePendingRequest",
                    .{
                        .sessionId = self.id,
                        .requestId = parsed.value.requestId,
                        .result = .{
                            .kind = "token",
                            .accessToken = token.access_token,
                            .tokenType = token.token_type,
                            .expiresIn = token.expires_in_seconds,
                        },
                    },
                );
            },
        };
        const accepted = try response;
        defer accepted.deinit();
        if (!accepted.value.success) return error.McpAuthNotAccepted;
        if (outcome.handler_error) |handler_error| return handler_error;
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
        var released_oauth_interest = false;
        if (self.client.findExtensionRuntime(self.id)) |runtime| {
            released_oauth_interest = runtime.mcp_oauth_interest_handle != null;
            self.client.releaseMcpOAuthInterest(runtime) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return .{ .failure = try policyFailure(
                    failure_policy,
                    err,
                    recordClientIo,
                    .{ self.client.allocator, .callback, err },
                ) };
            };
        }
        errdefer if (released_oauth_interest) {
            if (self.client.findExtensionRuntime(self.id)) |runtime| {
                if (runtime.mcp_auth_handler != null) {
                    self.client.registerMcpOAuthInterest(runtime) catch |err|
                        std.log.warn("failed to restore MCP OAuth interest after disconnect failure: {s}", .{@errorName(err)});
                }
            }
        };
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

pub const JoinedSession = struct {
    session: Session,
    grants: ext.EnvironmentGrants,

    pub fn deinit(self: *JoinedSession) void {
        self.grants.deinit();
        self.* = undefined;
    }
};

pub const McpApps = struct {
    session: Session,

    fn ensureSupported(self: McpApps) !void {
        const runtime = self.session.client.findExtensionRuntime(self.session.id) orelse
            return error.UnsupportedCapability;
        if (!runtime.mcp_apps_requested)
            return error.ExperimentalFeatureNotRequested;
        if (!runtime.capabilities.supports(.mcp_apps))
            return error.UnsupportedCapability;
    }

    pub fn listTools(
        self: McpApps,
        allocator: std.mem.Allocator,
        server_name: []const u8,
        origin_server_name: []const u8,
    ) !ext.OwnedJson {
        try self.ensureSupported();
        const parsed = try self.session.client.call(
            std.json.Value,
            "session.mcp.apps.listTools",
            .{
                .sessionId = self.session.id,
                .serverName = server_name,
                .originServerName = origin_server_name,
            },
        );
        defer parsed.deinit();
        return .{
            .allocator = allocator,
            .json = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{}),
        };
    }

    pub fn callTool(
        self: McpApps,
        allocator: std.mem.Allocator,
        request: ext.McpAppToolCall,
    ) !ext.OwnedJson {
        try self.ensureSupported();
        const arguments = try std.json.parseFromSlice(
            std.json.Value,
            self.session.client.allocator,
            request.arguments_json,
            .{},
        );
        defer arguments.deinit();
        if (arguments.value != .object) return error.InvalidMcpAppToolArguments;
        const parsed = try self.session.client.call(
            std.json.Value,
            "session.mcp.apps.callTool",
            .{
                .sessionId = self.session.id,
                .serverName = request.server_name,
                .toolName = request.tool_name,
                .arguments = arguments.value,
                .originServerName = request.origin_server_name,
            },
        );
        defer parsed.deinit();
        return .{
            .allocator = allocator,
            .json = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{}),
        };
    }

    pub fn readResource(
        self: McpApps,
        allocator: std.mem.Allocator,
        server_name: []const u8,
        uri: []const u8,
    ) !ext.OwnedJson {
        try self.ensureSupported();
        const parsed = try self.session.client.call(
            std.json.Value,
            "session.mcp.apps.readResource",
            .{
                .sessionId = self.session.id,
                .serverName = server_name,
                .uri = uri,
            },
        );
        defer parsed.deinit();
        return .{
            .allocator = allocator,
            .json = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{}),
        };
    }
};

fn stringifyRpcParams(
    allocator: std.mem.Allocator,
    params: ?std.json.Value,
) !?[]u8 {
    const value = params orelse return null;
    return @as(?[]u8, try std.json.Stringify.valueAlloc(allocator, value, .{}));
}

fn jsonRequiredString(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    return switch (object.get(name) orelse return error.MissingField) {
        .string => |value| value,
        else => error.InvalidField,
    };
}

fn jsonRequiredValue(object: std.json.ObjectMap, name: []const u8) !std.json.Value {
    return object.get(name) orelse error.MissingField;
}

fn jsonOptionalString(object: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    return switch (object.get(name) orelse return null) {
        .string => |value| value,
        .null => null,
        else => error.InvalidField,
    };
}

fn jsonRequiredBool(object: std.json.ObjectMap, name: []const u8) !bool {
    return switch (object.get(name) orelse return error.MissingField) {
        .bool => |value| value,
        else => error.InvalidField,
    };
}

fn jsonOptionalBool(object: std.json.ObjectMap, name: []const u8) !?bool {
    return switch (object.get(name) orelse return null) {
        .bool => |value| value,
        .null => null,
        else => error.InvalidField,
    };
}

fn parseHookBase(input: std.json.ObjectMap) !ext.HookBaseInput {
    const timestamp = switch (input.get("timestamp") orelse return error.MissingField) {
        .integer => |value| value,
        else => return error.InvalidField,
    };
    return .{
        .runtime_session_id = try jsonRequiredString(input, "sessionId"),
        .timestamp_ms = timestamp,
        .working_directory = try jsonRequiredString(input, "cwd"),
    };
}

fn wipeLifecycleResponseSecrets(response: WireSessionLifecycleResponse) void {
    const grants = response.grantedEnvironmentVariables orelse return;
    wipeJsonStrings(grants);
}

fn stringifyJsonValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

fn parseOptionalJson(
    allocator: std.mem.Allocator,
    source: ?[]const u8,
) !?std.json.Parsed(std.json.Value) {
    const json = source orelse return null;
    return try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
}

const McpAuthOutcome = struct {
    result: ext.McpAuthResult,
    handler_error: ?anyerror = null,
};

fn invokeMcpAuthHandler(
    handler: ext.McpAuthHandler,
    allocator: std.mem.Allocator,
    request: ext.McpAuthRequest,
    context: ?*anyopaque,
) McpAuthOutcome {
    return .{
        .result = handler(allocator, request, context) catch |err|
            return .{ .result = .cancelled, .handler_error = err },
    };
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

const WireProviderTokenRequest = struct {
    sessionId: []const u8,
    providerName: []const u8,
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

const WireExtensionInfo = struct {
    source: []const u8,
    name: []const u8,
};

const WireCanvasProvider = struct {
    id: []const u8,
    name: ?[]const u8 = null,
};

const WireCanvasAction = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    inputSchema: ?std.json.Value = null,
};

const WireCanvas = struct {
    id: []const u8,
    displayName: []const u8,
    description: []const u8,
    inputSchema: ?std.json.Value = null,
    actions: []const WireCanvasAction,
};

const WireOpenCanvas = struct {
    instanceId: []const u8,
    extensionId: []const u8,
    extensionName: ?[]const u8 = null,
    canvasId: []const u8,
    icon: ?[]const u8 = null,
    title: ?[]const u8 = null,
    status: ?[]const u8 = null,
    url: ?[]const u8 = null,
    input: ?std.json.Value = null,
};

const WireCapabilitiesUi = struct {
    canvases: ?bool = null,
    mcpApps: ?bool = null,
};

const WireCapabilities = struct {
    ui: ?WireCapabilitiesUi = null,
};

const WireSessionLifecycleResponse = struct {
    sessionId: ?[]const u8 = null,
    capabilities: ?WireCapabilities = null,
    openCanvases: ?[]const WireOpenCanvas = null,
    grantedEnvironmentVariables: ?std.json.Value = null,
};

const WireMcpAuthRequest = struct {
    requestId: []const u8,
    serverName: []const u8,
    serverUrl: []const u8,
    reason: ext.McpAuthReason,
    resourceMetadata: ?[]const u8 = null,
    wwwAuthenticateParams: ?std.json.Value = null,
    httpResponse: ?std.json.Value = null,
    staticClientConfig: ?std.json.Value = null,
};

fn capabilityState(value: ?bool) ext.CapabilityState {
    return if (value) |supported|
        if (supported) .supported else .unsupported
    else
        .unknown;
}

fn parseCapabilities(value: ?WireCapabilities) ext.CapabilitySet {
    const capabilities = value orelse return .{};
    const ui = capabilities.ui orelse return .{};
    return .{
        .canvases = capabilityState(ui.canvases),
        .mcp_apps = capabilityState(ui.mcpApps),
    };
}

fn cloneOptional(
    allocator: std.mem.Allocator,
    value: ?[]const u8,
) !?[]const u8 {
    return if (value) |item| try allocator.dupe(u8, item) else null;
}

fn cloneOpenCanvas(
    allocator: std.mem.Allocator,
    value: ext.OpenCanvas,
) !ext.OpenCanvas {
    const instance_id = try allocator.dupe(u8, value.instance_id);
    errdefer allocator.free(instance_id);
    const extension_id = try allocator.dupe(u8, value.extension_id);
    errdefer allocator.free(extension_id);
    const canvas_id = try allocator.dupe(u8, value.canvas_id);
    errdefer allocator.free(canvas_id);
    const extension_name = try cloneOptional(allocator, value.extension_name);
    errdefer if (extension_name) |item| allocator.free(item);
    const icon = try cloneOptional(allocator, value.icon);
    errdefer if (icon) |item| allocator.free(item);
    const title = try cloneOptional(allocator, value.title);
    errdefer if (title) |item| allocator.free(item);
    const status = try cloneOptional(allocator, value.status);
    errdefer if (status) |item| allocator.free(item);
    const url = try cloneOptional(allocator, value.url);
    errdefer if (url) |item| allocator.free(item);
    return .{
        .instance_id = instance_id,
        .extension_id = extension_id,
        .extension_name = extension_name,
        .canvas_id = canvas_id,
        .icon = icon,
        .title = title,
        .status = status,
        .url = url,
        .input_json = try cloneOptional(allocator, value.input_json),
    };
}

fn cloneWireOpenCanvas(
    allocator: std.mem.Allocator,
    value: WireOpenCanvas,
) !ext.OpenCanvas {
    const input_json = if (value.input) |input|
        try std.json.Stringify.valueAlloc(allocator, input, .{})
    else
        null;
    errdefer if (input_json) |item| allocator.free(item);
    const result = try cloneOpenCanvas(allocator, .{
        .instance_id = value.instanceId,
        .extension_id = value.extensionId,
        .extension_name = value.extensionName,
        .canvas_id = value.canvasId,
        .icon = value.icon,
        .title = value.title,
        .status = value.status,
        .url = value.url,
        .input_json = input_json,
    });
    if (input_json) |item| allocator.free(item);
    return result;
}

fn cloneTypedOpenCanvas(
    allocator: std.mem.Allocator,
    value: session_types.SessionEventTypes.CanvasOpenedData,
) !ext.OpenCanvas {
    const input_json = if (value.input) |input|
        try std.json.Stringify.valueAlloc(allocator, input, .{})
    else
        null;
    errdefer if (input_json) |item| allocator.free(item);
    const result = try cloneOpenCanvas(allocator, .{
        .instance_id = value.instance_id,
        .extension_id = value.extension_id,
        .extension_name = value.extension_name,
        .canvas_id = value.canvas_id,
        .icon = value.icon,
        .title = value.title,
        .status = value.status,
        .url = value.url,
        .input_json = input_json,
    });
    if (input_json) |item| allocator.free(item);
    return result;
}

fn removeOpenCanvas(
    runtime: *SessionExtensionRuntime,
    allocator: std.mem.Allocator,
    instance_id: []const u8,
) void {
    var index: usize = 0;
    while (index < runtime.open_canvases.items.len) {
        if (std.mem.eql(u8, runtime.open_canvases.items[index].instance_id, instance_id)) {
            const removed = runtime.open_canvases.orderedRemove(index);
            ext.freeOpenCanvas(allocator, removed);
        } else {
            index += 1;
        }
    }
}

fn upsertOpenCanvas(
    runtime: *SessionExtensionRuntime,
    allocator: std.mem.Allocator,
    canvas: ext.OpenCanvas,
) !void {
    for (runtime.open_canvases.items, 0..) |existing, index| {
        if (std.mem.eql(u8, existing.instance_id, canvas.instance_id)) {
            ext.freeOpenCanvas(allocator, runtime.open_canvases.items[index]);
            runtime.open_canvases.items[index] = canvas;
            return;
        }
    }
    try runtime.open_canvases.append(allocator, canvas);
}

fn validateCustomAgents(
    custom_agents: ?[]const session_types.CustomAgentConfig,
    initial_agent: session_types.InitialAgent,
) !void {
    const agents = custom_agents orelse &.{};
    for (agents, 0..) |agent, index| {
        for (agents[0..index]) |previous| {
            if (std.mem.eql(u8, previous.name, agent.name))
                return error.DuplicateCustomAgentName;
        }
    }
    const selected_name = switch (initial_agent) {
        .default_agent => return,
        .custom_agent => |name| name,
    };
    for (agents) |agent| {
        if (std.mem.eql(u8, agent.name, selected_name)) return;
    }
    return error.UnknownCustomAgent;
}

fn validateCustomAgentMcpServers(
    custom_agents: ?[]const session_types.CustomAgentConfig,
) !void {
    for (custom_agents orelse &.{}) |agent| {
        if (agent.mcp_servers) |servers| try ext.validateMcpServers(servers);
    }
}

const WireCustomAgent = struct {
    name: []const u8,
    displayName: ?[]const u8,
    description: ?[]const u8,
    tools: ?[]const []const u8,
    prompt: []const u8,
    mcpServers: ?std.json.Value,
    infer: ?bool,
    skills: ?[]const []const u8,
    model: ?[]const u8,
    reasoningEffort: ?session_types.ReasoningEffort,
};

const WireDefaultAgent = struct {
    excludedTools: ?[]const []const u8,
};

const ExtensionWireValues = struct {
    allocator: std.mem.Allocator,
    json_values: std.ArrayList(std.json.Parsed(std.json.Value)) = .empty,
    canvas_actions: std.ArrayList(WireCanvasAction) = .empty,
    canvases: std.ArrayList(WireCanvas) = .empty,
    open_canvases: std.ArrayList(WireOpenCanvas) = .empty,
    mcp_object: std.json.ObjectMap = .empty,
    mcp_servers: ?std.json.Value = null,
    custom_agents_present: bool = false,
    custom_agents: std.ArrayList(WireCustomAgent) = .empty,
    custom_agent_mcp_objects: std.ArrayList(std.json.ObjectMap) = .empty,

    fn init(allocator: std.mem.Allocator) ExtensionWireValues {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *ExtensionWireValues) void {
        for (self.custom_agent_mcp_objects.items) |*object| object.deinit(self.allocator);
        self.custom_agent_mcp_objects.deinit(self.allocator);
        self.custom_agents.deinit(self.allocator);
        self.mcp_object.deinit(self.allocator);
        for (self.json_values.items) |value| {
            wipeJsonStrings(value.value);
            value.deinit();
        }
        self.json_values.deinit(self.allocator);
        self.canvas_actions.deinit(self.allocator);
        self.canvases.deinit(self.allocator);
        self.open_canvases.deinit(self.allocator);
    }

    fn parseJson(self: *ExtensionWireValues, source: []const u8) !std.json.Value {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, source, .{
            .allocate = .alloc_always,
        });
        errdefer {
            wipeJsonStrings(parsed.value);
            parsed.deinit();
        }
        const value = parsed.value;
        try self.json_values.append(self.allocator, parsed);
        return value;
    }

    fn lowerCustomAgentMcpServers(
        self: *ExtensionWireValues,
        servers: []const ext.McpServer,
    ) !std.json.Value {
        var object: std.json.ObjectMap = .empty;
        errdefer object.deinit(self.allocator);
        for (servers) |server| {
            const json = switch (server.config) {
                .stdio => |config| try lowerStdioMcp(self.allocator, config),
                .http => |config| try lowerHttpMcp(self.allocator, config),
            };
            defer {
                wipeSecret(json);
                self.allocator.free(json);
            }
            try object.put(self.allocator, server.name, try self.parseJson(json));
        }
        try self.custom_agent_mcp_objects.append(self.allocator, object);
        return .{ .object = object };
    }

    fn lowerCustomAgents(
        self: *ExtensionWireValues,
        custom_agents: ?[]const session_types.CustomAgentConfig,
    ) !void {
        const agents = custom_agents orelse return;
        self.custom_agents_present = true;
        try self.custom_agents.ensureTotalCapacity(self.allocator, agents.len);
        for (agents) |agent| {
            try self.custom_agents.append(self.allocator, .{
                .name = agent.name,
                .displayName = agent.display_name,
                .description = agent.description,
                .tools = agent.tools,
                .prompt = agent.prompt,
                .mcpServers = if (agent.mcp_servers) |servers|
                    try self.lowerCustomAgentMcpServers(servers)
                else
                    null,
                .infer = agent.infer,
                .skills = agent.skills,
                .model = agent.model,
                .reasoningEffort = agent.reasoning_effort,
            });
        }
    }

    fn wireCustomAgents(self: *const ExtensionWireValues) ?[]const WireCustomAgent {
        return if (self.custom_agents_present) self.custom_agents.items else null;
    }

    fn lower(self: *ExtensionWireValues, features: ext.SessionFeatures) !void {
        var action_count: usize = 0;
        for (features.canvases) |canvas| action_count += canvas.actions.len;
        try self.canvas_actions.ensureTotalCapacity(self.allocator, action_count);
        try self.canvases.ensureTotalCapacity(self.allocator, features.canvases.len);
        for (features.canvases) |canvas| {
            const action_start = self.canvas_actions.items.len;
            for (canvas.actions) |action| {
                try self.canvas_actions.append(self.allocator, .{
                    .name = action.name,
                    .description = action.description,
                    .inputSchema = if (action.input_schema_json) |json|
                        try self.parseJson(json)
                    else
                        null,
                });
            }
            try self.canvases.append(self.allocator, .{
                .id = canvas.declaration.id,
                .displayName = canvas.declaration.display_name,
                .description = canvas.declaration.description,
                .inputSchema = if (canvas.declaration.input_schema_json) |json|
                    try self.parseJson(json)
                else
                    null,
                .actions = self.canvas_actions.items[action_start..],
            });
        }
        if (features.mcp.servers.len == 0) return;
        for (features.mcp.servers) |server| {
            const json = switch (server.config) {
                .stdio => |config| try lowerStdioMcp(self.allocator, config),
                .http => |config| try lowerHttpMcp(self.allocator, config),
            };
            defer {
                wipeSecret(json);
                self.allocator.free(json);
            }
            try self.mcp_object.put(self.allocator, server.name, try self.parseJson(json));
        }
        self.mcp_servers = .{ .object = self.mcp_object };
    }
};

fn nameValueObject(
    allocator: std.mem.Allocator,
    entries: []const ext.NameValue,
) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    errdefer object.deinit(allocator);
    for (entries) |entry| {
        if (entry.name.len == 0 or object.contains(entry.name))
            return error.InvalidMcpServer;
        try object.put(allocator, entry.name, .{ .string = entry.value });
    }
    return .{ .object = object };
}

fn lowerStdioMcp(allocator: std.mem.Allocator, config: ext.McpServerConfig.Stdio) ![]u8 {
    var env = try nameValueObject(allocator, config.env);
    defer env.object.deinit(allocator);
    return std.json.Stringify.valueAlloc(allocator, .{
        .type = "stdio",
        .command = config.command,
        .args = config.args,
        .env = env,
        .cwd = config.working_directory,
        .tools = config.tools,
        .timeout = config.timeout_ms,
    }, .{ .emit_null_optional_fields = false });
}

fn lowerHttpMcp(allocator: std.mem.Allocator, config: ext.McpServerConfig.Http) ![]u8 {
    var headers = try nameValueObject(allocator, config.headers);
    defer headers.object.deinit(allocator);
    return std.json.Stringify.valueAlloc(allocator, .{
        .type = @tagName(config.transport),
        .url = config.url,
        .headers = headers,
        .tools = config.tools,
        .timeout = config.timeout_ms,
    }, .{ .emit_null_optional_fields = false });
}

const CreateSessionRequest = struct {
    sessionId: ?[]const u8,
    model: ?[]const u8,
    provider: ?provider.WireProvider,
    providers: ?[]const provider.WireNamedProvider,
    models: ?[]const provider.WireProviderModel,
    modelCapabilities: ?models.CapabilitiesOverride,
    workingDirectory: ?[]const u8,
    streaming: bool,
    tools: []const WireTool,
    availableTools: ?[]const []const u8,
    excludedTools: ?[]const []const u8,
    customAgents: ?[]const WireCustomAgent,
    defaultAgent: ?WireDefaultAgent,
    agent: ?[]const u8,
    customAgentsLocalOnly: ?bool,
    excludedBuiltinAgents: ?[]const []const u8,
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
    canvases: ?[]const WireCanvas,
    requestCanvasRenderer: ?bool,
    requestExtensions: ?bool,
    extensionSdkPath: ?[]const u8,
    extensionInfo: ?WireExtensionInfo,
    canvasProvider: ?WireCanvasProvider,
    hooks: ?bool,
    requestMcpApps: ?bool,
    mcpServers: ?std.json.Value,
    mcpOAuthTokenStorage: ?[]const u8,
    authClientIdMetadataUrl: ?[]const u8,
    includedBuiltinSkills: ?[]const []const u8,
    pluginDirectories: ?[]const []const u8,
    disabledSkills: ?[]const []const u8,
    disabledMcpServers: ?[]const []const u8,
};

const ResumeSessionRequest = struct {
    sessionId: []const u8,
    model: ?[]const u8,
    provider: ?provider.WireProvider,
    providers: ?[]const provider.WireNamedProvider,
    models: ?[]const provider.WireProviderModel,
    modelCapabilities: ?models.CapabilitiesOverride,
    workingDirectory: ?[]const u8,
    streaming: bool,
    tools: []const WireTool,
    availableTools: ?[]const []const u8,
    excludedTools: ?[]const []const u8,
    customAgents: ?[]const WireCustomAgent,
    defaultAgent: ?WireDefaultAgent,
    agent: ?[]const u8,
    customAgentsLocalOnly: ?bool,
    excludedBuiltinAgents: ?[]const []const u8,
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
    disableResume: ?bool,
    continuePendingWork: ?bool,
    canvases: ?[]const WireCanvas,
    requestCanvasRenderer: ?bool,
    requestExtensions: ?bool,
    extensionSdkPath: ?[]const u8,
    extensionInfo: ?WireExtensionInfo,
    canvasProvider: ?WireCanvasProvider,
    hooks: ?bool,
    requestMcpApps: ?bool,
    mcpServers: ?std.json.Value,
    mcpOAuthTokenStorage: ?[]const u8,
    authClientIdMetadataUrl: ?[]const u8,
    includedBuiltinSkills: ?[]const []const u8,
    pluginDirectories: ?[]const []const u8,
    disabledSkills: ?[]const []const u8,
    disabledMcpServers: ?[]const []const u8,
    openCanvases: ?[]const WireOpenCanvas,
    requestedEnvironmentVariables: ?[]const []const u8,
};

const ToolFilterPrecedence = enum {
    available,
    excluded,
};

fn managedSettingsEnabled(config: anytype) bool {
    const enabled = if (@hasField(@TypeOf(config), "enable_managed_settings"))
        config.enable_managed_settings
    else
        false;
    const injected = if (@hasField(@TypeOf(config), "managed_settings")) switch (@typeInfo(
        @TypeOf(config.managed_settings),
    )) {
        .optional => config.managed_settings != null,
        else => true,
    } else false;
    return enabled or injected;
}

fn resumeConfigFromCreate(config: session_types.CreateSessionConfig) session_types.ResumeSessionConfig {
    return .{
        .model = config.model,
        .provider = config.provider,
        .providers = config.providers,
        .models = config.models,
        .model_capabilities = config.model_capabilities,
        .working_directory = config.working_directory,
        .streaming = config.streaming,
        .tools = config.tools,
        .available_tools = config.available_tools,
        .excluded_tools = config.excluded_tools,
        .custom_agents = config.custom_agents,
        .default_agent = config.default_agent,
        .agent = config.agent,
        .custom_agents_local_only = config.custom_agents_local_only,
        .excluded_builtin_agents = config.excluded_builtin_agents,
        .system_message = config.system_message,
        .request_permission = config.request_permission,
        .enable_config_discovery = config.enable_config_discovery,
        .skill_directories = config.skill_directories,
        .enable_skills = config.enable_skills,
        .instruction_directories = config.instruction_directories,
        .skip_custom_instructions = config.skip_custom_instructions,
        .enable_on_demand_instruction_discovery = config.enable_on_demand_instruction_discovery,
        .enable_managed_settings = config.enable_managed_settings,
        .managed_settings = config.managed_settings,
        .on_permission_request = config.on_permission_request,
        .permission_context = config.permission_context,
        .on_user_input_request = config.on_user_input_request,
        .user_input_context = config.user_input_context,
        .suppress_resume_event = true,
        .extensions = .{
            .common = config.extensions.common,
            .extension_sdk_path = config.extensions.extension_sdk_path,
            .canvas_provider = config.extensions.canvas_provider,
        },
    };
}

fn resumeConfigFromJoin(config: session_types.JoinSessionConfig) session_types.ResumeSessionConfig {
    return .{
        .model = config.model,
        .provider = config.provider,
        .providers = config.providers,
        .models = config.models,
        .model_capabilities = config.model_capabilities,
        .working_directory = config.working_directory,
        .streaming = config.streaming,
        .tools = config.tools,
        .available_tools = config.available_tools,
        .excluded_tools = config.excluded_tools,
        .custom_agents = config.custom_agents,
        .default_agent = config.default_agent,
        .agent = config.agent,
        .custom_agents_local_only = config.custom_agents_local_only,
        .excluded_builtin_agents = config.excluded_builtin_agents,
        .system_message = config.system_message,
        .request_permission = config.request_permission,
        .enable_config_discovery = config.enable_config_discovery,
        .skill_directories = config.skill_directories,
        .enable_skills = config.enable_skills,
        .instruction_directories = config.instruction_directories,
        .skip_custom_instructions = config.skip_custom_instructions,
        .enable_on_demand_instruction_discovery = config.enable_on_demand_instruction_discovery,
        .enable_managed_settings = config.enable_managed_settings,
        .managed_settings = config.managed_settings,
        .on_permission_request = config.on_permission_request orelse
            session_types.defaultJoinSessionPermissionHandler,
        .permission_context = config.permission_context,
        .on_user_input_request = config.on_user_input_request,
        .user_input_context = config.user_input_context,
        .suppress_resume_event = config.suppress_resume_event,
        .continue_pending_work = config.continue_pending_work,
        .extensions = .{
            .common = config.extensions.common,
            .canvas_provider = config.extensions.canvas_provider,
            .open_canvases = config.extensions.open_canvases,
        },
    };
}

fn generateSessionId(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var bytes: [16]u8 = undefined;
    try std.Io.randomSecure(io, &bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    const id = try allocator.alloc(u8, 36);
    const hex = "0123456789abcdef";
    var output_index: usize = 0;
    for (bytes, 0..) |byte, byte_index| {
        if (byte_index == 4 or byte_index == 6 or byte_index == 8 or byte_index == 10) {
            id[output_index] = '-';
            output_index += 1;
        }
        id[output_index] = hex[byte >> 4];
        id[output_index + 1] = hex[byte & 0x0f];
        output_index += 2;
    }
    return id;
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

fn lowerInitialAgent(initial_agent: session_types.InitialAgent) ?[]const u8 {
    return switch (initial_agent) {
        .default_agent => null,
        .custom_agent => |name| name,
    };
}

fn lowerDefaultAgent(config: ?session_types.DefaultAgentConfig) ?WireDefaultAgent {
    const value = config orelse return null;
    return .{ .excludedTools = value.excluded_tools };
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
    config: session_types.CreateSessionConfig,
    tools: []const WireTool,
    values: *ExtensionWireValues,
) !CreateSessionRequest {
    return buildPreparedCreateSessionRequest(
        config.session_id,
        config,
        tools,
        values,
        .{},
    );
}

fn buildPreparedCreateSessionRequest(
    session_id: ?[]const u8,
    config: session_types.CreateSessionConfig,
    tools: []const WireTool,
    values: *ExtensionWireValues,
    prepared_providers: provider.PreparedProviders,
) !CreateSessionRequest {
    const features = config.extensions.common;
    try provider.validateCapabilities(config.model_capabilities);
    return .{
        .sessionId = session_id,
        .model = config.model,
        .provider = prepared_providers.provider,
        .providers = prepared_providers.providers,
        .models = prepared_providers.models,
        .modelCapabilities = config.model_capabilities,
        .workingDirectory = config.working_directory,
        .streaming = config.streaming,
        .tools = tools,
        .availableTools = config.available_tools,
        .excludedTools = config.excluded_tools,
        .customAgents = values.wireCustomAgents(),
        .defaultAgent = lowerDefaultAgent(config.default_agent),
        .agent = lowerInitialAgent(config.agent),
        .customAgentsLocalOnly = config.custom_agents_local_only,
        .excludedBuiltinAgents = config.excluded_builtin_agents,
        .systemMessage = config.system_message,
        .requestPermission = config.request_permission or config.on_permission_request != null,
        .requestUserInput = config.on_user_input_request != null,
        .enableConfigDiscovery = config.enable_config_discovery,
        .skillDirectories = config.skill_directories orelse
            optionalSlice(features.skills.directories),
        .enableSkills = config.enable_skills orelse features.skills.enabled,
        .instructionDirectories = config.instruction_directories,
        .skipCustomInstructions = config.skip_custom_instructions,
        .enableOnDemandInstructionDiscovery = config.enable_on_demand_instruction_discovery,
        .enableManagedSettings = config.enable_managed_settings,
        .managedSettings = lowerManagedSettings(config.managed_settings),
        .canvases = if (values.canvases.items.len > 0) values.canvases.items else null,
        .requestCanvasRenderer = if (features.request_canvas_renderer) true else null,
        .requestExtensions = if (features.request_extensions) true else null,
        .extensionSdkPath = config.extensions.extension_sdk_path,
        .extensionInfo = if (features.extension_info) |value| .{
            .source = value.source,
            .name = value.name,
        } else null,
        .canvasProvider = if (config.extensions.canvas_provider) |value| .{
            .id = value.id,
            .name = value.name,
        } else null,
        .hooks = if (features.hooks.any()) true else null,
        .requestMcpApps = if (features.experimental.mcp_apps) true else null,
        .mcpServers = values.mcp_servers,
        .mcpOAuthTokenStorage = if (features.mcp.oauth_token_storage == .persistent)
            "persistent"
        else
            null,
        .authClientIdMetadataUrl = features.mcp.auth_client_id_metadata_url,
        .includedBuiltinSkills = features.skills.included_builtin,
        .pluginDirectories = optionalSlice(features.plugin_directories),
        .disabledSkills = optionalSlice(features.skills.disabled),
        .disabledMcpServers = optionalSlice(features.mcp.disabled_servers),
    };
}

fn buildResumeSessionRequest(
    session_id: []const u8,
    config: session_types.ResumeSessionConfig,
    tools: []const WireTool,
    values: *ExtensionWireValues,
    requested_environment_variables: []const []const u8,
) !ResumeSessionRequest {
    return buildPreparedResumeSessionRequest(
        session_id,
        config,
        tools,
        values,
        requested_environment_variables,
        .{},
    );
}

fn buildPreparedResumeSessionRequest(
    session_id: []const u8,
    config: session_types.ResumeSessionConfig,
    tools: []const WireTool,
    values: *ExtensionWireValues,
    requested_environment_variables: []const []const u8,
    prepared_providers: provider.PreparedProviders,
) !ResumeSessionRequest {
    const features = config.extensions.common;
    if (config.extensions.open_canvases) |configured_open_canvases| {
        try values.open_canvases.ensureTotalCapacity(
            values.allocator,
            configured_open_canvases.len,
        );
        for (configured_open_canvases) |canvas| {
            try values.open_canvases.append(values.allocator, .{
                .instanceId = canvas.instance_id,
                .extensionId = canvas.extension_id,
                .extensionName = canvas.extension_name,
                .canvasId = canvas.canvas_id,
                .icon = canvas.icon,
                .title = canvas.title,
                .status = canvas.status,
                .url = canvas.url,
                .input = if (canvas.input_json) |json|
                    try values.parseJson(json)
                else
                    null,
            });
        }
    }
    try provider.validateCapabilities(config.model_capabilities);
    return .{
        .sessionId = session_id,
        .model = config.model,
        .provider = prepared_providers.provider,
        .providers = prepared_providers.providers,
        .models = prepared_providers.models,
        .modelCapabilities = config.model_capabilities,
        .workingDirectory = config.working_directory,
        .streaming = config.streaming,
        .tools = tools,
        .availableTools = config.available_tools,
        .excludedTools = config.excluded_tools,
        .customAgents = values.wireCustomAgents(),
        .defaultAgent = lowerDefaultAgent(config.default_agent),
        .agent = lowerInitialAgent(config.agent),
        .customAgentsLocalOnly = config.custom_agents_local_only,
        .excludedBuiltinAgents = config.excluded_builtin_agents,
        .systemMessage = config.system_message,
        .requestPermission = config.request_permission or config.on_permission_request != null,
        .requestUserInput = config.on_user_input_request != null,
        .enableConfigDiscovery = config.enable_config_discovery,
        .skillDirectories = config.skill_directories orelse
            optionalSlice(features.skills.directories),
        .enableSkills = config.enable_skills orelse features.skills.enabled,
        .instructionDirectories = config.instruction_directories,
        .skipCustomInstructions = config.skip_custom_instructions,
        .enableOnDemandInstructionDiscovery = config.enable_on_demand_instruction_discovery,
        .enableManagedSettings = config.enable_managed_settings,
        .managedSettings = lowerManagedSettings(config.managed_settings),
        .disableResume = if (config.suppress_resume_event) true else null,
        .continuePendingWork = if (config.continue_pending_work) true else null,
        .canvases = if (values.canvases.items.len > 0) values.canvases.items else null,
        .requestCanvasRenderer = if (features.request_canvas_renderer) true else null,
        .requestExtensions = if (features.request_extensions) true else null,
        .extensionSdkPath = config.extensions.extension_sdk_path,
        .extensionInfo = if (features.extension_info) |value| .{
            .source = value.source,
            .name = value.name,
        } else null,
        .canvasProvider = if (config.extensions.canvas_provider) |value| .{
            .id = value.id,
            .name = value.name,
        } else null,
        .hooks = if (features.hooks.any()) true else null,
        .requestMcpApps = if (features.experimental.mcp_apps) true else null,
        .mcpServers = values.mcp_servers,
        .mcpOAuthTokenStorage = if (features.mcp.oauth_token_storage == .persistent)
            "persistent"
        else
            null,
        .authClientIdMetadataUrl = features.mcp.auth_client_id_metadata_url,
        .includedBuiltinSkills = features.skills.included_builtin,
        .pluginDirectories = optionalSlice(features.plugin_directories),
        .disabledSkills = optionalSlice(features.skills.disabled),
        .disabledMcpServers = optionalSlice(features.mcp.disabled_servers),
        .openCanvases = if (config.extensions.open_canvases != null)
            values.open_canvases.items
        else
            null,
        .requestedEnvironmentVariables = optionalSlice(requested_environment_variables),
    };
}

fn optionalSlice(value: anytype) ?@TypeOf(value) {
    return if (value.len == 0) null else value;
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
        _ = &Client.resumeSession;
        _ = &Client.resumeSessionDetailed;
        _ = &Client.joinParentSession;
        _ = &Session.capabilities;
        _ = &Session.experimental;
        _ = &Session.openCanvas;
        _ = &Session.closeCanvas;
        _ = &Session.invokeCanvasAction;
        _ = &Session.snapshotOpenCanvases;
        _ = &McpApps.listTools;
        _ = &McpApps.callTool;
        _ = &McpApps.readResource;
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
    var extension_values = ExtensionWireValues.init(allocator);
    defer extension_values.deinit();
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
    try client.dispatchServerRequestTracked(
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
    try client.dispatchServerRequestTracked(
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
    try client.dispatchServerRequestTracked(
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
    try client.dispatchServerRequestTracked(
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
    try client.dispatchServerRequestTracked(
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
                "{\"kind\":\"shell\",\"fullCommandText\":\"pwd\",\"intention\":\"show directory\",\"commands\":[],\"possiblePaths\":[],\"possibleUrls\":[],\"hasWriteFileRedirection\":false,\"canOfferSessionApproval\":false}",
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
        \\{"type":"permission.requested","data":{"requestId":"permission-1","permissionRequest":{"kind":"shell","fullCommandText":"pwd","intention":"show directory","commands":[],"possiblePaths":[],"possibleUrls":[],"hasWriteFileRedirection":false,"canOfferSessionApproval":false}}}
    ,
        .{},
    );
    defer parsed_event.deinit();
    try client.events.append(allocator, .{
        .session_id = try allocator.dupe(u8, "session-1"),
        .event = try deliveryEventForTest(
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
        .event = try deliveryEventForTest(
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
        \\{"type":"permission.requested","data":{"requestId":"permission-1","permissionRequest":{"kind":"shell","fullCommandText":"pwd","intention":"show directory","commands":[],"possiblePaths":[],"possibleUrls":[],"hasWriteFileRedirection":false,"canOfferSessionApproval":false}}}
    ,
        .{},
    );
    defer parsed_event.deinit();
    try client.events.append(allocator, .{
        .session_id = try allocator.dupe(u8, "session-1"),
        .event = try deliveryEventForTest(
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
        \\{"type":"permission.requested","data":{"requestId":"permission-1","permissionRequest":{"kind":"read","intention":"inspect file","path":"README.md"}}}
    ,
        .{},
    );
    defer managed_session_event.deinit();
    try client.events.append(allocator, .{
        .session_id = try allocator.dupe(u8, "managed-session"),
        .event = try deliveryEventForTest(
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
        .event = try deliveryEventForTest(
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
        .writer_buffer = &writer_buffer,
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
        \\{"type":"permission.requested","data":{"requestId":"permission-1","permissionRequest":{"kind":"shell","fullCommandText":"pwd","intention":"show directory","commands":[],"possiblePaths":[],"possibleUrls":[],"hasWriteFileRedirection":false,"canOfferSessionApproval":false}}}
    ,
        .{},
    );
    defer parsed_event.deinit();
    try client.events.append(allocator, .{
        .session_id = try allocator.dupe(u8, "session-1"),
        .event = try deliveryEventForTest(
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
        \\{"type":"permission.requested","data":{"requestId":"permission-1","permissionRequest":{"kind":"shell","fullCommandText":"pwd","intention":"show directory","commands":[],"possiblePaths":[],"possibleUrls":[],"hasWriteFileRedirection":false,"canOfferSessionApproval":false}}}
    ,
        .{},
    );
    defer parsed_event.deinit();
    try client.events.append(allocator, .{
        .session_id = try allocator.dupe(u8, "session-1"),
        .event = try deliveryEventForTest(
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

fn runSendRpc(
    allocator: std.mem.Allocator,
    options: session_types.MessageOptions,
) !struct {
    message_id: []u8,
    request_body: []u8,
} {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const response_body =
        \\{"jsonrpc":"2.0","id":1,"result":{"messageId":"message-1"}}
    ;
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

    const request_file = try tmp.dir.createFile(std.testing.io, "request", .{});
    defer request_file.close(std.testing.io);
    var writer_buffer: [8192]u8 = undefined;
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
        client.events.deinit(allocator);
        client.session_ids.deinit(allocator);
    }

    const message_id = try (Session{ .client = &client, .id = "session-1" }).send(options);
    errdefer allocator.free(message_id);
    const request_frame = try tmp.dir.readFileAlloc(
        std.testing.io,
        "request",
        allocator,
        .limited(64 * 1024),
    );
    defer allocator.free(request_frame);

    return .{
        .message_id = message_id,
        .request_body = try framedBody(allocator, request_frame),
    };
}

test "session.send keeps prompt-only wire output unchanged" {
    const result = try runSendRpc(std.testing.allocator, .{ .prompt = "hello" });
    defer std.testing.allocator.free(result.message_id);
    defer std.testing.allocator.free(result.request_body);

    try std.testing.expectEqualStrings("message-1", result.message_id);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"method":"session.send","params":{"sessionId":"session-1","prompt":"hello"}}
    , result.request_body);
}

test "session.send serializes every attachment variant" {
    const repo = session_types.Attachment.GitHubRepoPointer{
        .id = 7,
        .name = "repo",
        .owner = "owner",
    };
    const diff_side = session_types.Attachment.GitHubFileDiffSide{
        .path = "src/a.zig",
        .git_ref = "main",
        .repo = repo,
    };
    const attachments = [_]session_types.Attachment{
        .{ .file = .{
            .path = "/tmp/a.zig",
            .display_name = "a.zig",
            .line_range = .{ .start = 2, .end = 4 },
        } },
        .{ .directory = .{
            .path = "/tmp/src",
            .display_name = "src",
        } },
        .{ .selection = .{
            .file_path = "/tmp/a.zig",
            .text = "const a = 1;",
            .display_name = "a",
            .selection = .{
                .start = .{ .line = 1, .character = 2 },
                .end = .{ .line = 1, .character = 14 },
            },
        } },
        .{ .blob = .{
            .data = "aGVsbG8=",
            .mime_type = "text/plain",
            .display_name = "hello.txt",
        } },
        .{ .github_reference = .{
            .number = 42,
            .title = "Issue",
            .reference_type = .issue,
            .state = "open",
            .url = "https://github.com/owner/repo/issues/42",
        } },
        .{ .github_commit = .{
            .message = "Commit",
            .oid = "abc123",
            .repo = repo,
            .url = "https://github.com/owner/repo/commit/abc123",
        } },
        .{ .github_release = .{
            .name = "Release",
            .repo = repo,
            .tag_name = "v1.0.0",
            .url = "https://github.com/owner/repo/releases/tag/v1.0.0",
        } },
        .{ .github_actions_job = .{
            .conclusion = "success",
            .job_id = 99,
            .job_name = "test",
            .repo = repo,
            .url = "https://github.com/owner/repo/actions/runs/1/job/99",
            .workflow_name = "CI",
        } },
        .{ .github_repository = .{
            .description = "A repo",
            .git_ref = "main",
            .repo = repo,
            .url = "https://github.com/owner/repo",
        } },
        .{ .github_file_diff = .{
            .sides = .{ .modified = .{
                .base = diff_side,
                .head = .{
                    .path = "src/a.zig",
                    .git_ref = "feature",
                    .repo = repo,
                },
            } },
            .url = "https://github.com/owner/repo/compare/main...feature",
        } },
        .{ .github_tree_comparison = .{
            .base = .{ .repo = repo, .revision = "main" },
            .head = .{ .repo = repo, .revision = "feature" },
            .url = "https://github.com/owner/repo/compare/main...feature",
        } },
        .{ .github_url = .{
            .url = "https://github.com/owner/repo",
        } },
        .{ .github_file = .{
            .path = "src/a.zig",
            .git_ref = "main",
            .repo = repo,
            .url = "https://github.com/owner/repo/blob/main/src/a.zig",
        } },
        .{ .github_snippet = .{
            .line_range = .{ .start = 10, .end = 12 },
            .path = "src/a.zig",
            .git_ref = "main",
            .repo = repo,
            .url = "https://github.com/owner/repo/blob/main/src/a.zig#L10-L12",
        } },
    };

    const result = try runSendRpc(std.testing.allocator, .{
        .prompt = "inspect",
        .attachments = &attachments,
    });
    defer std.testing.allocator.free(result.message_id);
    defer std.testing.allocator.free(result.request_body);

    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"method":"session.send","params":{"sessionId":"session-1","prompt":"inspect","attachments":[{"type":"file","path":"/tmp/a.zig","displayName":"a.zig","lineRange":{"start":2,"end":4}},{"type":"directory","path":"/tmp/src","displayName":"src"},{"type":"selection","filePath":"/tmp/a.zig","text":"const a = 1;","displayName":"a","selection":{"start":{"line":1,"character":2},"end":{"line":1,"character":14}}},{"type":"blob","data":"aGVsbG8=","mimeType":"text/plain","displayName":"hello.txt"},{"type":"github_reference","number":42,"title":"Issue","referenceType":"issue","state":"open","url":"https://github.com/owner/repo/issues/42"},{"type":"github_commit","message":"Commit","oid":"abc123","repo":{"id":7,"name":"repo","owner":"owner"},"url":"https://github.com/owner/repo/commit/abc123"},{"type":"github_release","name":"Release","repo":{"id":7,"name":"repo","owner":"owner"},"tagName":"v1.0.0","url":"https://github.com/owner/repo/releases/tag/v1.0.0"},{"type":"github_actions_job","conclusion":"success","jobId":99,"jobName":"test","repo":{"id":7,"name":"repo","owner":"owner"},"url":"https://github.com/owner/repo/actions/runs/1/job/99","workflowName":"CI"},{"type":"github_repository","description":"A repo","ref":"main","repo":{"id":7,"name":"repo","owner":"owner"},"url":"https://github.com/owner/repo"},{"type":"github_file_diff","base":{"path":"src/a.zig","ref":"main","repo":{"id":7,"name":"repo","owner":"owner"}},"head":{"path":"src/a.zig","ref":"feature","repo":{"id":7,"name":"repo","owner":"owner"}},"url":"https://github.com/owner/repo/compare/main...feature"},{"type":"github_tree_comparison","base":{"repo":{"id":7,"name":"repo","owner":"owner"},"revision":"main"},"head":{"repo":{"id":7,"name":"repo","owner":"owner"},"revision":"feature"},"url":"https://github.com/owner/repo/compare/main...feature"},{"type":"github_url","url":"https://github.com/owner/repo"},{"type":"github_file","path":"src/a.zig","ref":"main","repo":{"id":7,"name":"repo","owner":"owner"},"url":"https://github.com/owner/repo/blob/main/src/a.zig"},{"type":"github_snippet","lineRange":{"start":10,"end":12},"path":"src/a.zig","ref":"main","repo":{"id":7,"name":"repo","owner":"owner"},"url":"https://github.com/owner/repo/blob/main/src/a.zig#L10-L12"}]}}
    , result.request_body);
}

test "session.send normalizes display names and omits absent optional fields" {
    const repo = session_types.Attachment.GitHubRepoPointer{
        .name = "repo",
        .owner = "owner",
    };
    const attachments = [_]session_types.Attachment{
        .{ .file = .{ .path = "/tmp/a.zig" } },
        .{ .directory = .{ .path = "/tmp", .display_name = "" } },
        .{ .selection = .{
            .file_path = "/tmp/a.zig",
            .text = "a",
            .display_name = " \t",
            .selection = .{
                .start = .{ .line = 0, .character = 0 },
                .end = .{ .line = 0, .character = 1 },
            },
        } },
        .{ .blob = .{ .data = "YQ==", .mime_type = "text/plain" } },
        .{ .github_actions_job = .{
            .job_id = 1,
            .job_name = "test",
            .repo = repo,
            .url = "https://github.com/owner/repo/actions",
            .workflow_name = "CI",
        } },
        .{ .github_repository = .{
            .repo = repo,
            .url = "https://github.com/owner/repo",
        } },
    };

    const result = try runSendRpc(std.testing.allocator, .{
        .prompt = "inspect",
        .attachments = &attachments,
    });
    defer std.testing.allocator.free(result.message_id);
    defer std.testing.allocator.free(result.request_body);

    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"method":"session.send","params":{"sessionId":"session-1","prompt":"inspect","attachments":[{"type":"file","path":"/tmp/a.zig","displayName":"a.zig"},{"type":"directory","path":"/tmp","displayName":"tmp"},{"type":"selection","filePath":"/tmp/a.zig","text":"a","displayName":"a.zig","selection":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}},{"type":"blob","data":"YQ==","mimeType":"text/plain","displayName":"attachment"},{"type":"github_actions_job","jobId":1,"jobName":"test","repo":{"name":"repo","owner":"owner"},"url":"https://github.com/owner/repo/actions","workflowName":"CI"},{"type":"github_repository","repo":{"name":"repo","owner":"owner"},"url":"https://github.com/owner/repo"}]}}
    , result.request_body);
}

test "session.send distinguishes omitted and empty attachments" {
    const omitted = try runSendRpc(std.testing.allocator, .{
        .prompt = "omitted",
        .attachments = null,
    });
    defer std.testing.allocator.free(omitted.message_id);
    defer std.testing.allocator.free(omitted.request_body);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"method":"session.send","params":{"sessionId":"session-1","prompt":"omitted"}}
    , omitted.request_body);

    const empty = try runSendRpc(std.testing.allocator, .{
        .prompt = "empty",
        .attachments = &.{},
    });
    defer std.testing.allocator.free(empty.message_id);
    defer std.testing.allocator.free(empty.request_body);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"method":"session.send","params":{"sessionId":"session-1","prompt":"empty","attachments":[]}}
    , empty.request_body);
}

test "session.send serializes every GitHub reference type" {
    const attachments = [_]session_types.Attachment{
        .{ .github_reference = .{
            .number = 1,
            .title = "Issue",
            .reference_type = .issue,
            .state = "open",
            .url = "issue",
        } },
        .{ .github_reference = .{
            .number = 2,
            .title = "PR",
            .reference_type = .pr,
            .state = "merged",
            .url = "pr",
        } },
        .{ .github_reference = .{
            .number = 3,
            .title = "Discussion",
            .reference_type = .discussion,
            .state = "open",
            .url = "discussion",
        } },
    };
    const result = try runSendRpc(std.testing.allocator, .{
        .prompt = "references",
        .attachments = &attachments,
    });
    defer std.testing.allocator.free(result.message_id);
    defer std.testing.allocator.free(result.request_body);

    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"method":"session.send","params":{"sessionId":"session-1","prompt":"references","attachments":[{"type":"github_reference","number":1,"title":"Issue","referenceType":"issue","state":"open","url":"issue"},{"type":"github_reference","number":2,"title":"PR","referenceType":"pr","state":"merged","url":"pr"},{"type":"github_reference","number":3,"title":"Discussion","referenceType":"discussion","state":"open","url":"discussion"}]}}
    , result.request_body);
}

test "session.send serializes every GitHub file diff shape" {
    const repo = session_types.Attachment.GitHubRepoPointer{
        .name = "repo",
        .owner = "owner",
    };
    const base = session_types.Attachment.GitHubFileDiffSide{
        .path = "old.zig",
        .git_ref = "main",
        .repo = repo,
    };
    const head = session_types.Attachment.GitHubFileDiffSide{
        .path = "new.zig",
        .git_ref = "feature",
        .repo = repo,
    };
    const attachments = [_]session_types.Attachment{
        .{ .github_file_diff = .{
            .sides = .{ .added = head },
            .url = "added",
        } },
        .{ .github_file_diff = .{
            .sides = .{ .deleted = base },
            .url = "deleted",
        } },
        .{ .github_file_diff = .{
            .sides = .{ .modified = .{ .base = base, .head = head } },
            .url = "modified",
        } },
    };
    const result = try runSendRpc(std.testing.allocator, .{
        .prompt = "diffs",
        .attachments = &attachments,
    });
    defer std.testing.allocator.free(result.message_id);
    defer std.testing.allocator.free(result.request_body);

    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"method":"session.send","params":{"sessionId":"session-1","prompt":"diffs","attachments":[{"type":"github_file_diff","head":{"path":"new.zig","ref":"feature","repo":{"name":"repo","owner":"owner"}},"url":"added"},{"type":"github_file_diff","base":{"path":"old.zig","ref":"main","repo":{"name":"repo","owner":"owner"}},"url":"deleted"},{"type":"github_file_diff","base":{"path":"old.zig","ref":"main","repo":{"name":"repo","owner":"owner"}},"head":{"path":"new.zig","ref":"feature","repo":{"name":"repo","owner":"owner"}},"url":"modified"}]}}
    , result.request_body);
}

test "session.send preserves attachment order" {
    const attachments = [_]session_types.Attachment{
        .{ .github_url = .{ .url = "first" } },
        .{ .directory = .{ .path = "second" } },
        .{ .blob = .{ .data = "dGhpcmQ=", .mime_type = "text/plain" } },
    };
    const result = try runSendRpc(std.testing.allocator, .{
        .prompt = "order",
        .attachments = &attachments,
    });
    defer std.testing.allocator.free(result.message_id);
    defer std.testing.allocator.free(result.request_body);

    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"method":"session.send","params":{"sessionId":"session-1","prompt":"order","attachments":[{"type":"github_url","url":"first"},{"type":"directory","path":"second","displayName":"second"},{"type":"blob","data":"dGhpcmQ=","mimeType":"text/plain","displayName":"attachment"}]}}
    , result.request_body);
}

test "session.sendAndWait cleans its message id and returns an owned assistant message" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const response_body =
        \\{"jsonrpc":"2.0","id":1,"result":{"messageId":"temporary-id"}}
    ;
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
        client.session_ids.deinit(allocator);
    }
    try client.events.append(allocator, .{
        .session_id = try allocator.dupe(u8, "session-1"),
        .event = .{ .assistant_message = .{
            .content = try allocator.dupe(u8, "answer"),
            .message_id = try allocator.dupe(u8, "assistant-id"),
        } },
    });
    try client.events.append(allocator, .{
        .session_id = try allocator.dupe(u8, "session-1"),
        .event = .{ .session_idle = .{} },
    });

    const attachments = [_]session_types.Attachment{
        .{ .file = .{ .path = "/tmp/a.zig" } },
    };
    const message = (try (Session{
        .client = &client,
        .id = "session-1",
    }).sendAndWait(.{
        .prompt = "inspect",
        .attachments = &attachments,
    })).?;
    defer message.deinit(allocator);

    try std.testing.expectEqualStrings("answer", message.content);
    try std.testing.expectEqualStrings("assistant-id", message.message_id.?);
    const request_frame = try tmp.dir.readFileAlloc(
        std.testing.io,
        "request",
        allocator,
        .limited(4096),
    );
    defer allocator.free(request_frame);
    const request_body = try framedBody(allocator, request_frame);
    defer allocator.free(request_body);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"method":"session.send","params":{"sessionId":"session-1","prompt":"inspect","attachments":[{"type":"file","path":"/tmp/a.zig","displayName":"a.zig"}]}}
    , request_body);
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
            .autoTier = .fast,
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
    try std.testing.expectEqualStrings("fast", model_params.get("autoTier").?.string);
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
    var extension_values = ExtensionWireValues.init(allocator);
    defer extension_values.deinit();
    const config = session_types.CreateSessionConfig{
        .provider = .{
            .base_url = "https://api.openai.com/v1",
            .protocol = .{ .openai = .{ .responses = .websockets } },
            .authentication = .{ .bearer_token = "token" },
        },
    };
    var prepared = try provider.prepareSessionProviders(
        allocator,
        config.provider,
        config.providers,
        config.models,
    );
    defer prepared.deinit(allocator);
    const params = try buildPreparedCreateSessionRequest(
        config.session_id,
        config,
        &.{},
        &extension_values,
        prepared,
    );
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

test "resume request places provider without suppressing resume by default" {
    const allocator = std.testing.allocator;
    var extension_values = ExtensionWireValues.init(allocator);
    defer extension_values.deinit();
    const config = session_types.ResumeSessionConfig{
        .provider = .{
            .base_url = "https://api.anthropic.com",
            .protocol = .anthropic,
            .authentication = .{ .api_key = "key" },
        },
    };
    var prepared = try provider.prepareSessionProviders(
        allocator,
        config.provider,
        config.providers,
        config.models,
    );
    defer prepared.deinit(allocator);
    const params = try buildPreparedResumeSessionRequest(
        "session-1",
        config,
        &.{},
        &extension_values,
        &.{},
        prepared,
    );
    const encoded = try json_rpc.encodeRequest(allocator, 10, "session.resume", params);
    defer allocator.free(encoded);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("session.resume", root.get("method").?.string);
    const request_params = root.get("params").?.object;
    try std.testing.expect(!request_params.contains("disableResume"));
    const provider_value = request_params.get("provider").?.object;
    try std.testing.expectEqualStrings("anthropic", provider_value.get("type").?.string);
    try std.testing.expectEqualStrings("key", provider_value.get("apiKey").?.string);
}

test "resume request preserves omitted and explicitly empty open canvases" {
    const allocator = std.testing.allocator;

    var omitted_values = ExtensionWireValues.init(allocator);
    defer omitted_values.deinit();
    const omitted_request = try buildResumeSessionRequest(
        "session-1",
        .{},
        &.{},
        &omitted_values,
        &.{},
    );
    const omitted_encoded = try json_rpc.encodeRequest(
        allocator,
        11,
        "session.resume",
        omitted_request,
    );
    defer allocator.free(omitted_encoded);
    const omitted = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        omitted_encoded,
        .{},
    );
    defer omitted.deinit();
    try std.testing.expect(
        !omitted.value.object.get("params").?.object.contains("openCanvases"),
    );

    var empty_values = ExtensionWireValues.init(allocator);
    defer empty_values.deinit();
    const empty_request = try buildResumeSessionRequest(
        "session-1",
        .{ .extensions = .{ .open_canvases = &.{} } },
        &.{},
        &empty_values,
        &.{},
    );
    const empty_encoded = try json_rpc.encodeRequest(
        allocator,
        12,
        "session.resume",
        empty_request,
    );
    defer allocator.free(empty_encoded);
    const empty = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        empty_encoded,
        .{},
    );
    defer empty.deinit();
    try std.testing.expectEqual(
        @as(usize, 0),
        empty.value.object.get("params").?.object.get("openCanvases").?.array.items.len,
    );
}

test "createSession and resumeSession preserve deep partial model capability overrides" {
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
        const resume_response = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"sessionId\":\"existing-session\"}}";
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
            .writer_buffer = &writer_buffer,
        };
        defer {
            for (client.session_ids.items) |id| allocator.free(id);
            client.session_ids.deinit(allocator);
            for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
            client.extension_runtimes.deinit(allocator);
        }
        const config = session_types.SessionConfig{
            .session_id = "created-session",
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
        const resume_config = session_types.ResumeSessionConfig{
            .model = config.model,
            .provider = config.provider,
            .model_capabilities = config.model_capabilities,
        };
        const joined = try client.resumeSession("existing-session", resume_config);
        try std.testing.expectEqualStrings("existing-session", joined.id);

        var invalid_config = config;
        invalid_config.model_capabilities = .{ .limits = .{ .vision = .{ .max_prompt_images = 0 } } };
        try std.testing.expectError(error.InvalidMaxPromptImages, client.createSession(invalid_config));
        var invalid_resume_config = resume_config;
        invalid_resume_config.model_capabilities = invalid_config.model_capabilities;
        try std.testing.expectError(
            error.InvalidMaxPromptImages,
            client.resumeSession("existing-session", invalid_resume_config),
        );

        const requests = try tmp.dir.readFileAlloc(std.testing.io, "requests", allocator, .limited(8192));
        defer allocator.free(requests);
        var frames = std.Io.Reader.fixed(requests);
        const model_and_provider = "\"model\":\"local-vision-model\",\"provider\":{\"type\":\"openai\",\"wireApi\":\"completions\",\"baseUrl\":\"http://localhost:8000/v1\",\"modelId\":\"local-vision-model\",\"wireModel\":\"local-vision-model\"}";
        const defaults = ",\"streaming\":false,\"tools\":[],\"toolFilterPrecedence\":\"excluded\",\"requestPermission\":false,\"requestUserInput\":false,\"enableManagedSettings\":false";
        const expected_create = try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.create\",\"params\":{{{s}{s}{s}}}}}",
            .{ "\"sessionId\":\"created-session\"," ++ model_and_provider, case.wire, defaults },
        );
        defer allocator.free(expected_create);
        const create_body = try json_rpc.readFrame(allocator, &frames);
        defer allocator.free(create_body);
        try std.testing.expectEqualStrings(expected_create, create_body);
        const expected_resume = try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session.resume\",\"params\":{{\"sessionId\":\"existing-session\",{s}{s}{s}}}}}",
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
    var extension_values = ExtensionWireValues.init(allocator);
    defer extension_values.deinit();
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
    }, &.{}, &extension_values);
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
    }, &.{}, &extension_values, &.{});
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
    var extension_values = ExtensionWireValues.init(allocator);
    defer extension_values.deinit();
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
            }, &.{}, &extension_values),
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
            }, &.{}, &extension_values, &.{}),
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
    var extension_values = ExtensionWireValues.init(allocator);
    defer extension_values.deinit();
    const available_tools = &.{ "custom:*", "builtin:ask_user" };
    const excluded_tools = &.{"builtin:web_fetch"};

    const create_encoded = try json_rpc.encodeRequest(
        allocator,
        15,
        "session.create",
        try buildCreateSessionRequest(.{
            .available_tools = available_tools,
            .excluded_tools = excluded_tools,
        }, &.{}, &extension_values),
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
        }, &.{}, &extension_values, &.{}),
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
    var extension_values = ExtensionWireValues.init(allocator);
    defer extension_values.deinit();
    const skill_directories = &.{ ".agents/skills", ".github/skills" };
    const instruction_directories = &.{ ".", ".github/instructions" };

    const create_encoded = try json_rpc.encodeRequest(
        allocator,
        15,
        "session.create",
        try buildCreateSessionRequest(.{
            .skill_directories = skill_directories,
            .instruction_directories = instruction_directories,
        }, &.{}, &extension_values),
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
        }, &.{}, &extension_values, &.{}),
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
        try buildCreateSessionRequest(.{}, &.{}, &extension_values),
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
        try buildResumeSessionRequest("session-1", .{}, &.{}, &extension_values, &.{}),
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
    var extension_values = ExtensionWireValues.init(allocator);
    defer extension_values.deinit();
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
    const resume_config = session_types.ResumeSessionConfig{
        .enable_managed_settings = config.enable_managed_settings,
        .managed_settings = config.managed_settings,
        .on_permission_request = config.on_permission_request,
    };

    const create_encoded = try json_rpc.encodeRequest(
        allocator,
        13,
        "session.create",
        try buildCreateSessionRequest(config, &.{}, &extension_values),
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
        try buildResumeSessionRequest(
            "session-1",
            resume_config,
            &.{},
            &extension_values,
            &.{},
        ),
    );
    defer allocator.free(resume_encoded);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"session.resume\",\"params\":{\"sessionId\":\"session-1\",\"streaming\":false,\"tools\":[],\"toolFilterPrecedence\":\"excluded\",\"requestPermission\":true,\"requestUserInput\":false,\"enableManagedSettings\":false,\"managedSettings\":{\"permissions\":{\"disableBypassPermissionsMode\":\"allow-auto-only\",\"deny\":[\"Shell(git push *)\"],\"ask\":[\"Read(**)\"],\"allow\":[\"Read(src/**)\"]}}}}",
        resume_encoded,
    );

    const fetched_config = session_types.SessionConfig{
        .enable_managed_settings = true,
        .on_permission_request = permission_handler,
    };
    const fetched_resume_config = session_types.ResumeSessionConfig{
        .enable_managed_settings = fetched_config.enable_managed_settings,
        .on_permission_request = fetched_config.on_permission_request,
    };
    try std.testing.expect(managedSettingsEnabled(fetched_config));

    const fetched_create_encoded = try json_rpc.encodeRequest(
        allocator,
        15,
        "session.create",
        try buildCreateSessionRequest(fetched_config, &.{}, &extension_values),
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
        try buildResumeSessionRequest(
            "session-1",
            fetched_resume_config,
            &.{},
            &extension_values,
            &.{},
        ),
    );
    defer allocator.free(fetched_resume_encoded);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":16,\"method\":\"session.resume\",\"params\":{\"sessionId\":\"session-1\",\"streaming\":false,\"tools\":[],\"toolFilterPrecedence\":\"excluded\",\"requestPermission\":true,\"requestUserInput\":false,\"enableManagedSettings\":true}}",
        fetched_resume_encoded,
    );
}

test "session requests omit a null provider" {
    const allocator = std.testing.allocator;
    var extension_values = ExtensionWireValues.init(allocator);
    defer extension_values.deinit();
    const create_params = try buildCreateSessionRequest(.{}, &.{}, &extension_values);
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

    const resume_params = try buildResumeSessionRequest(
        "session-1",
        session_types.ResumeSessionConfig{},
        &.{},
        &extension_values,
        &.{},
    );
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

test "extension fields lower to exact lifecycle wire names" {
    const allocator = std.testing.allocator;
    const open_handler = struct {
        fn handle(
            _: std.mem.Allocator,
            _: ext.CanvasOpenRequest,
            _: ?*anyopaque,
        ) !ext.CanvasOpenResult {
            return .{};
        }
    }.handle;
    const action_handler = struct {
        fn handle(
            inner_allocator: std.mem.Allocator,
            _: ext.CanvasActionRequest,
            _: ?*anyopaque,
        ) ![]u8 {
            return inner_allocator.dupe(u8, "{}");
        }
    }.handle;
    const features = ext.SessionFeatures{
        .plugin_directories = &.{"plugins"},
        .skills = .{
            .enabled = true,
            .directories = &.{"skills"},
            .disabled = &.{"unsafe"},
            .included_builtin = &.{"review"},
        },
        .mcp = .{
            .servers = &.{.{
                .name = "docs",
                .config = .{ .stdio = .{ .command = "docs-mcp" } },
            }},
            .disabled_servers = &.{"legacy"},
            .oauth_token_storage = .persistent,
            .auth_client_id_metadata_url = "https://example.test/client.json",
        },
        .canvases = &.{.{
            .declaration = .{
                .id = "review",
                .display_name = "Review",
                .description = "Review findings",
            },
            .on_open = open_handler,
            .actions = &.{.{
                .name = "dismiss",
                .handler = action_handler,
            }},
        }},
        .request_canvas_renderer = true,
        .request_extensions = true,
        .extension_info = .{ .source = "plugin", .name = "review" },
        .experimental = .{ .mcp_apps = true },
    };
    var values = ExtensionWireValues.init(allocator);
    defer values.deinit();
    try values.lower(features);
    const request = try buildCreateSessionRequest(.{
        .extensions = .{
            .common = features,
            .extension_sdk_path = "/sdk",
            .canvas_provider = .{ .id = "host:window" },
        },
    }, &.{}, &values);
    const encoded = try json_rpc.encodeRequest(allocator, 1, "session.create", request);
    defer allocator.free(encoded);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
    defer parsed.deinit();
    const params = parsed.value.object.get("params").?.object;
    try std.testing.expectEqualStrings("plugins", params.get("pluginDirectories").?.array.items[0].string);
    try std.testing.expectEqualStrings("skills", params.get("skillDirectories").?.array.items[0].string);
    try std.testing.expectEqualStrings("review", params.get("includedBuiltinSkills").?.array.items[0].string);
    try std.testing.expectEqualStrings("docs-mcp", params.get("mcpServers").?.object.get("docs").?.object.get("command").?.string);
    try std.testing.expectEqualStrings("review", params.get("canvases").?.array.items[0].object.get("id").?.string);
    try std.testing.expect(params.get("requestCanvasRenderer").?.bool);
    try std.testing.expect(params.get("requestMcpApps").?.bool);
    try std.testing.expectEqualStrings("/sdk", params.get("extensionSdkPath").?.string);
}

test "built-in skill allowlists distinguish omitted from empty" {
    const allocator = std.testing.allocator;
    var values = ExtensionWireValues.init(allocator);
    defer values.deinit();

    const omitted_request = try buildCreateSessionRequest(.{}, &.{}, &values);
    const omitted_encoded = try json_rpc.encodeRequest(
        allocator,
        1,
        "session.create",
        omitted_request,
    );
    defer allocator.free(omitted_encoded);
    const omitted = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        omitted_encoded,
        .{},
    );
    defer omitted.deinit();
    try std.testing.expect(
        !omitted.value.object.get("params").?.object.contains("includedBuiltinSkills"),
    );

    const empty_request = try buildCreateSessionRequest(.{
        .extensions = .{ .common = .{
            .skills = .{ .included_builtin = &.{} },
        } },
    }, &.{}, &values);
    const empty_encoded = try json_rpc.encodeRequest(
        allocator,
        2,
        "session.create",
        empty_request,
    );
    defer allocator.free(empty_encoded);
    const empty = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        empty_encoded,
        .{},
    );
    defer empty.deinit();
    try std.testing.expectEqual(
        @as(usize, 0),
        empty.value.object.get("params").?.object
            .get("includedBuiltinSkills").?.array.items.len,
    );

    const resume_request = try buildResumeSessionRequest("session-1", .{
        .extensions = .{ .common = .{
            .skills = .{ .included_builtin = &.{} },
        } },
    }, &.{}, &values, &.{});
    const resume_encoded = try json_rpc.encodeRequest(
        allocator,
        3,
        "session.resume",
        resume_request,
    );
    defer allocator.free(resume_encoded);
    const resumed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        resume_encoded,
        .{},
    );
    defer resumed.deinit();
    try std.testing.expectEqual(
        @as(usize, 0),
        resumed.value.object.get("params").?.object
            .get("includedBuiltinSkills").?.array.items.len,
    );
}

test "capability updates are tri-state and canvas state is defensive" {
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
        for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
        client.extension_runtimes.deinit(allocator);
    }

    try client.beginExtensionRuntime("s1", session_types.ResumeSessionConfig{
        .extensions = .{ .common = .{
            .experimental = .{ .mcp_apps = true },
        } },
    }, &.{});
    try client.commitExtensionRuntime("s1", .{
        .sessionId = "s1",
        .capabilities = .{ .ui = .{ .canvases = true } },
        .openCanvases = &.{.{
            .instanceId = "i1",
            .extensionId = "e1",
            .canvasId = "c1",
        }},
    }, &.{});
    const session = Session{ .client = &client, .id = "s1" };
    try std.testing.expect(session.capabilities().supports(.canvases));
    try std.testing.expectEqual(ext.CapabilityState.unknown, session.capabilities().mcp_apps);
    try std.testing.expectError(error.UnsupportedCapability, session.experimental(.mcp_apps));

    const event = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"capabilities.changed","data":{"ui":{"canvases":false,"mcpApps":true}}}
    ,
        .{},
    );
    defer event.deinit();
    var session_event = try session_types.parseEvent(allocator, event.value);
    defer session_event.deinit(allocator);
    try client.applyExtensionEvent("s1", &session_event);
    try std.testing.expectEqual(ext.CapabilityState.unsupported, session.capabilities().canvases);
    _ = try session.experimental(.mcp_apps);

    var snapshot = try session.snapshotOpenCanvases(allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 1), snapshot.items.len);
    try std.testing.expect(
        snapshot.items[0].instance_id.ptr !=
            client.findExtensionRuntime("s1").?.open_canvases.items[0].instance_id.ptr,
    );
    try std.testing.expectEqualStrings(
        "i1",
        client.findExtensionRuntime("s1").?.open_canvases.items[0].instance_id,
    );

    const opened = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"session.canvas.opened","data":{"instanceId":"i2","extensionId":"e1","canvasId":"c1"}}
    ,
        .{},
    );
    defer opened.deinit();
    var opened_event = try session_types.parseEvent(allocator, opened.value);
    defer opened_event.deinit(allocator);
    var empty_buffer: [0]u8 = .{};
    var failing_allocator = std.heap.FixedBufferAllocator.init(&empty_buffer);
    client.allocator = failing_allocator.allocator();
    try std.testing.expectError(
        error.OutOfMemory,
        client.applyExtensionEvent("s1", &opened_event),
    );
    client.allocator = allocator;
    try std.testing.expectEqual(
        @as(usize, 1),
        client.findExtensionRuntime("s1").?.open_canvases.items.len,
    );
}

test "typed hooks dispatch through a provisional session runtime" {
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
    defer client.rollbackExtensionRuntime();
    var called = false;
    const handler = struct {
        fn handle(
            _: std.mem.Allocator,
            input: ext.PreToolUseInput,
            invocation: ext.HookInvocation,
            context: ?*anyopaque,
        ) !ext.PreToolUseOutput {
            const did_call: *bool = @ptrCast(@alignCast(context.?));
            try std.testing.expectEqualStrings("s1", invocation.session_id);
            try std.testing.expectEqualStrings("shell", input.tool_name);
            try std.testing.expectEqualStrings("{\"command\":\"pwd\"}", input.tool_args_json);
            did_call.* = true;
            return .{ .permission_decision = .deny, .permission_decision_reason = "blocked" };
        }
    }.handle;
    try client.beginExtensionRuntime(null, session_types.CreateSessionConfig{
        .extensions = .{ .common = .{ .hooks = .{
            .on_pre_tool_use = handler,
            .context = &called,
        } } },
    }, &.{});
    const params = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"sessionId":"s1","hookType":"preToolUse","input":{"sessionId":"s1","timestamp":42,"cwd":"/repo","toolName":"shell","toolArgs":{"command":"pwd"}}}
    ,
        .{},
    );
    defer params.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try client.dispatchServerRequest(
        &output.writer,
        .{ .integer = 7 },
        "hooks.invoke",
        params.value,
    );
    try std.testing.expect(called);
    const body = try framedBody(allocator, output.written());
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"permissionDecision\":\"deny\"") != null);
}

test "agent stop hook reads the snake-case wire activity flag" {
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
    defer client.rollbackExtensionRuntime();
    var called = false;
    const handler = struct {
        fn handle(
            _: std.mem.Allocator,
            input: ext.AgentStopInput,
            _: ext.HookInvocation,
            context: ?*anyopaque,
        ) !ext.AgentStopOutput {
            const did_call: *bool = @ptrCast(@alignCast(context.?));
            try std.testing.expect(input.stop_hook_active);
            did_call.* = true;
            return .{};
        }
    }.handle;
    try client.beginExtensionRuntime(null, session_types.CreateSessionConfig{
        .extensions = .{ .common = .{ .hooks = .{
            .on_agent_stop = handler,
            .context = &called,
        } } },
    }, &.{});
    const params = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"sessionId":"s1","hookType":"agentStop","input":{"sessionId":"s1","timestamp":42,"cwd":"/repo","stop_hook_active":true}}
    ,
        .{},
    );
    defer params.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try client.dispatchServerRequest(
        &output.writer,
        .{ .integer = 8 },
        "hooks.invoke",
        params.value,
    );
    try std.testing.expect(called);
}

test "provisional create runtime does not shadow existing sessions" {
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
        client.rollbackExtensionRuntime();
        for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
        client.extension_runtimes.deinit(allocator);
    }
    var existing_context: u8 = 1;
    var create_context: u8 = 2;
    try client.beginExtensionRuntime("existing", session_types.ResumeSessionConfig{
        .extensions = .{ .common = .{ .hooks = .{
            .context = &existing_context,
        } } },
    }, &.{});
    try client.commitExtensionRuntime("existing", .{}, &.{});
    try client.beginExtensionRuntime(null, session_types.CreateSessionConfig{
        .extensions = .{ .common = .{ .hooks = .{
            .context = &create_context,
        } } },
    }, &.{});

    try std.testing.expectEqual(
        @as(?*anyopaque, &existing_context),
        client.findExtensionRuntime("existing").?.hooks.context,
    );
    try std.testing.expectEqual(
        @as(?*anyopaque, &create_context),
        client.findExtensionRuntime("new-session").?.hooks.context,
    );
}

test "invalid hook output receives an internal-error response" {
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
    defer client.rollbackExtensionRuntime();
    const handler = struct {
        fn handle(
            _: std.mem.Allocator,
            _: ext.PreToolUseInput,
            _: ext.HookInvocation,
            _: ?*anyopaque,
        ) !ext.PreToolUseOutput {
            return .{ .modified_args_json = "{" };
        }
    }.handle;
    try client.beginExtensionRuntime(null, session_types.CreateSessionConfig{
        .extensions = .{ .common = .{ .hooks = .{
            .on_pre_tool_use = handler,
        } } },
    }, &.{});
    const params = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"sessionId":"s1","hookType":"preToolUse","input":{"sessionId":"s1","timestamp":42,"cwd":"/repo","toolName":"shell","toolArgs":{}}}
    ,
        .{},
    );
    defer params.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try client.dispatchServerRequest(
        &output.writer,
        .{ .integer = 8 },
        "hooks.invoke",
        params.value,
    );
    const body = try framedBody(allocator, output.written());
    defer allocator.free(body);
    try std.testing.expect(
        std.mem.indexOf(u8, body, "\"code\":-32603") != null,
    );
}

test "invalid required hook fields receive an invalid-params response" {
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
    defer client.rollbackExtensionRuntime();
    const handlers = struct {
        fn preTool(
            _: std.mem.Allocator,
            input: ext.PreToolUseInput,
            _: ext.HookInvocation,
            _: ?*anyopaque,
        ) !ext.PreToolUseOutput {
            try std.testing.expectEqualStrings("null", input.tool_args_json);
            return .{};
        }
        fn postTool(
            _: std.mem.Allocator,
            _: ext.PostToolUseInput,
            _: ext.HookInvocation,
            _: ?*anyopaque,
        ) !ext.PostToolUseOutput {
            return error.TestUnexpectedHookInvocation;
        }
        fn preMcp(
            _: std.mem.Allocator,
            _: ext.PreMcpToolCallInput,
            _: ext.HookInvocation,
            _: ?*anyopaque,
        ) !ext.PreMcpToolCallOutput {
            return error.TestUnexpectedHookInvocation;
        }
        fn postToolFailure(
            _: std.mem.Allocator,
            _: ext.PostToolUseFailureInput,
            _: ext.HookInvocation,
            _: ?*anyopaque,
        ) !ext.PostToolUseFailureOutput {
            return error.TestUnexpectedHookInvocation;
        }
    };
    try client.beginExtensionRuntime(null, session_types.CreateSessionConfig{
        .extensions = .{ .common = .{ .hooks = .{
            .on_pre_tool_use = handlers.preTool,
            .on_post_tool_use = handlers.postTool,
            .on_post_tool_use_failure = handlers.postToolFailure,
            .on_pre_mcp_tool_call = handlers.preMcp,
        } } },
    }, &.{});
    const invalid_requests = [_][]const u8{
        \\{"sessionId":"s1","hookType":"preToolUse","input":{"sessionId":"s1","timestamp":42,"cwd":"/repo","toolName":"tool"}}
        ,
        \\{"sessionId":"s1","hookType":"preMcpToolCall","input":{"sessionId":"s1","timestamp":42,"cwd":"/repo","serverName":"server","toolName":"tool"}}
        ,
        \\{"sessionId":"s1","hookType":"postToolUse","input":{"sessionId":"s1","timestamp":42,"cwd":"/repo","toolName":"tool","toolResult":{}}}
        ,
        \\{"sessionId":"s1","hookType":"postToolUse","input":{"sessionId":"s1","timestamp":42,"cwd":"/repo","toolName":"tool","toolArgs":{}}}
        ,
        \\{"sessionId":"s1","hookType":"postToolUseFailure","input":{"sessionId":"s1","timestamp":42,"cwd":"/repo","toolName":"tool","error":"failed"}}
        ,
        \\{"sessionId":"s1","hookType":"preMcpToolCall","input":{"sessionId":"s1","timestamp":42,"cwd":"/repo","toolCallId":42,"serverName":"server","toolName":"tool","arguments":{}}}
        ,
    };
    for (invalid_requests, 0..) |request, index| {
        const params = try std.json.parseFromSlice(std.json.Value, allocator, request, .{});
        defer params.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        try client.dispatchServerRequest(
            &output.writer,
            .{ .integer = @intCast(9 + index) },
            "hooks.invoke",
            params.value,
        );
        const body = try framedBody(allocator, output.written());
        defer allocator.free(body);
        try std.testing.expect(
            std.mem.indexOf(u8, body, "\"code\":-32602") != null,
        );
    }

    const null_params = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"sessionId":"s1","hookType":"preToolUse","input":{"sessionId":"s1","timestamp":42,"cwd":"/repo","toolName":"tool","toolArgs":null}}
    ,
        .{},
    );
    defer null_params.deinit();
    var null_output: std.Io.Writer.Allocating = .init(allocator);
    defer null_output.deinit();
    try client.dispatchServerRequest(
        &null_output.writer,
        .{ .integer = 15 },
        "hooks.invoke",
        null_params.value,
    );
    const null_body = try framedBody(allocator, null_output.written());
    defer allocator.free(null_body);
    try std.testing.expect(
        std.mem.indexOf(u8, null_body, "\"result\":") != null,
    );
}

test "resident resume prefers and commits replacement runtime" {
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
        if (client.pending_extension_runtime) |*runtime| runtime.deinit(allocator);
        for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
        client.extension_runtimes.deinit(allocator);
    }
    var old_context: u8 = 1;
    var new_context: u8 = 2;
    try client.beginExtensionRuntime("s1", session_types.ResumeSessionConfig{
        .extensions = .{ .common = .{ .hooks = .{
            .context = &old_context,
        } } },
    }, &.{});
    try client.commitExtensionRuntime("s1", .{}, &.{});
    try client.beginExtensionRuntime("s1", session_types.ResumeSessionConfig{
        .extensions = .{ .common = .{ .hooks = .{
            .context = &new_context,
        } } },
    }, &.{});
    try std.testing.expectEqual(
        @as(?*anyopaque, &new_context),
        client.findExtensionRuntime("s1").?.hooks.context,
    );
    try client.commitExtensionRuntime("s1", .{}, &.{});
    try std.testing.expectEqual(@as(usize, 1), client.extension_runtimes.items.len);
    try std.testing.expectEqual(
        @as(?*anyopaque, &new_context),
        client.findExtensionRuntime("s1").?.hooks.context,
    );
}

test "failed resident resume preserves committed runtime and session id" {
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
        if (client.pending_extension_runtime) |*runtime| runtime.deinit(allocator);
        for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
        client.extension_runtimes.deinit(allocator);
        for (client.session_ids.items) |id| allocator.free(id);
        client.session_ids.deinit(allocator);
    }
    var old_context: u8 = 1;
    var new_context: u8 = 2;
    const session_id = try allocator.dupe(u8, "s1");
    try client.session_ids.append(allocator, session_id);
    try client.beginExtensionRuntime("s1", session_types.ResumeSessionConfig{
        .extensions = .{ .common = .{ .hooks = .{
            .context = &old_context,
        } } },
    }, &.{});
    try client.commitExtensionRuntime("s1", .{}, &.{});
    try client.beginExtensionRuntime("s1", session_types.ResumeSessionConfig{
        .extensions = .{ .common = .{ .hooks = .{
            .context = &new_context,
        } } },
    }, &.{});
    const response = try std.json.parseFromSlice(
        WireSessionLifecycleResponse,
        allocator,
        \\{"grantedEnvironmentVariables":{"TOKEN":1}}
    ,
        .{ .allocate = .alloc_always },
    );
    defer response.deinit();
    try std.testing.expectError(
        error.InvalidGrantedEnvironmentVariables,
        client.commitExtensionRuntime("s1", response.value, &.{"TOKEN"}),
    );
    client.rollbackExtensionRuntime();
    try std.testing.expectEqual(@as(usize, 1), client.extension_runtimes.items.len);
    try std.testing.expectEqual(@as(usize, 1), client.session_ids.items.len);
    try std.testing.expectEqual(
        @as(?*anyopaque, &old_context),
        client.findExtensionRuntime("s1").?.hooks.context,
    );
    try std.testing.expect(client.findSessionId("s1").?.ptr == session_id.ptr);
}

test "failed frame writes wipe the transport buffer" {
    const secret = "transport-secret";
    var writer_buffer: [256]u8 = undefined;
    var writer = std.Io.Writer{
        .vtable = &.{ .drain = std.Io.Writer.failingDrain },
        .buffer = &writer_buffer,
    };

    try std.testing.expectError(
        error.WriteFailed,
        writeFrameAndWipe(&writer, &writer_buffer, secret),
    );
    try std.testing.expectEqual(@as(usize, 0), writer.end);
    try std.testing.expect(std.mem.indexOf(u8, &writer_buffer, secret) == null);
    for (writer_buffer) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "MCP OAuth event interest is retained and released" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const register_response =
        \\{"jsonrpc":"2.0","id":1,"result":{"handle":"interest-1"}}
    ;
    const release_response =
        \\{"jsonrpc":"2.0","id":2,"result":{"success":true}}
    ;
    const responses = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}",
        .{
            register_response.len,
            register_response,
            release_response.len,
            release_response,
        },
    );
    defer allocator.free(responses);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "responses",
        .data = responses,
    });
    const response_file = try tmp.dir.openFile(
        std.testing.io,
        "responses",
        .{ .mode = .read_only },
    );
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
        .writer_buffer = &writer_buffer,
    };
    defer {
        for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
        client.extension_runtimes.deinit(allocator);
    }
    const handler = struct {
        fn handle(
            _: std.mem.Allocator,
            _: ext.McpAuthRequest,
            _: ?*anyopaque,
        ) !ext.McpAuthResult {
            return .cancelled;
        }
    }.handle;
    try client.beginExtensionRuntime("s1", session_types.ResumeSessionConfig{
        .extensions = .{ .common = .{ .mcp = .{
            .on_auth_request = handler,
        } } },
    }, &.{});
    try client.commitExtensionRuntime("s1", .{}, &.{});
    const runtime = client.findExtensionRuntime("s1").?;
    try client.registerMcpOAuthInterest(runtime);
    try std.testing.expectEqualStrings(
        "interest-1",
        runtime.mcp_oauth_interest_handle.?,
    );
    try client.releaseMcpOAuthInterest(runtime);
    try std.testing.expect(runtime.mcp_oauth_interest_handle == null);
    for (writer_buffer) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }

    const requests = try tmp.dir.readFileAlloc(
        std.testing.io,
        "requests",
        allocator,
        .limited(4096),
    );
    defer allocator.free(requests);
    var frames = std.Io.Reader.fixed(requests);
    const register_body = try json_rpc.readFrame(allocator, &frames);
    defer allocator.free(register_body);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            register_body,
            "\"method\":\"session.eventLog.registerInterest\"",
        ) != null,
    );
    const release_body = try json_rpc.readFrame(allocator, &frames);
    defer allocator.free(release_body);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            release_body,
            "\"method\":\"session.eventLog.releaseInterest\"",
        ) != null,
    );
}

test "disconnect releases OAuth interest before detaching" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const register_response =
        \\{"jsonrpc":"2.0","id":1,"result":{"handle":"interest-1"}}
    ;
    const release_response =
        \\{"jsonrpc":"2.0","id":2,"result":{"success":true}}
    ;
    const detach_response =
        \\{"jsonrpc":"2.0","id":3,"result":{"success":true}}
    ;
    const responses = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}",
        .{
            register_response.len,
            register_response,
            release_response.len,
            release_response,
            detach_response.len,
            detach_response,
        },
    );
    defer allocator.free(responses);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "responses",
        .data = responses,
    });
    const response_file = try tmp.dir.openFile(
        std.testing.io,
        "responses",
        .{ .mode = .read_only },
    );
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
        .writer_buffer = &writer_buffer,
    };
    defer {
        for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
        client.extension_runtimes.deinit(allocator);
        for (client.session_ids.items) |id| allocator.free(id);
        client.session_ids.deinit(allocator);
    }
    const handler = struct {
        fn handle(
            _: std.mem.Allocator,
            _: ext.McpAuthRequest,
            _: ?*anyopaque,
        ) !ext.McpAuthResult {
            return .cancelled;
        }
    }.handle;
    try client.beginExtensionRuntime("s1", session_types.ResumeSessionConfig{
        .extensions = .{ .common = .{ .mcp = .{
            .on_auth_request = handler,
        } } },
    }, &.{});
    try client.commitExtensionRuntime("s1", .{}, &.{});
    const session_id = try allocator.dupe(u8, "s1");
    try client.session_ids.append(allocator, session_id);

    try (Session{ .client = &client, .id = session_id }).disconnect();
    try std.testing.expect(client.findExtensionRuntime("s1") == null);
    try std.testing.expect(client.findSessionId("s1") == null);

    const requests = try tmp.dir.readFileAlloc(
        std.testing.io,
        "requests",
        allocator,
        .limited(4096),
    );
    defer allocator.free(requests);
    var frames = std.Io.Reader.fixed(requests);
    const register_body = try json_rpc.readFrame(allocator, &frames);
    defer allocator.free(register_body);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            register_body,
            "\"method\":\"session.eventLog.registerInterest\"",
        ) != null,
    );
    const release_body = try json_rpc.readFrame(allocator, &frames);
    defer allocator.free(release_body);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            release_body,
            "\"method\":\"session.eventLog.releaseInterest\"",
        ) != null,
    );
    const detach_body = try json_rpc.readFrame(allocator, &frames);
    defer allocator.free(detach_body);
    try std.testing.expect(
        std.mem.indexOf(u8, detach_body, "\"method\":\"session.detach\"") != null,
    );
}

test "client teardown releases OAuth interests before event storage" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const event =
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"s1","event":{"type":"mcp.oauth_required","data":{"staticClientConfig":{"clientSecret":"secret"}}}}}
    ;
    const release_response =
        \\{"jsonrpc":"2.0","id":1,"result":{"success":true}}
    ;
    const responses = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}",
        .{ event.len, event, release_response.len, release_response },
    );
    defer allocator.free(responses);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "responses",
        .data = responses,
    });
    const response_file = try tmp.dir.openFile(
        std.testing.io,
        "responses",
        .{ .mode = .read_only },
    );
    defer response_file.close(std.testing.io);
    const request_file = try tmp.dir.createFile(std.testing.io, "requests", .{});
    defer request_file.close(std.testing.io);

    const reader_buffer = try allocator.alloc(u8, 1024);
    const writer_buffer = try allocator.alloc(u8, 1024);
    const reader = try allocator.create(std.Io.File.Reader);
    const writer = try allocator.create(std.Io.File.Writer);
    reader.* = response_file.readerStreaming(std.testing.io, reader_buffer);
    writer.* = request_file.writer(std.testing.io, writer_buffer);
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = reader,
        .writer = writer,
        .reader_buffer = reader_buffer,
        .writer_buffer = writer_buffer,
    };
    try client.beginExtensionRuntime(
        "s1",
        session_types.ResumeSessionConfig{},
        &.{},
    );
    try client.commitExtensionRuntime("s1", .{}, &.{});
    client.findExtensionRuntime("s1").?.mcp_oauth_interest_handle =
        try allocator.dupe(u8, "interest-1");

    client.deinit();
}

test "transport buffer teardown wipes reader and writer storage" {
    var reader_buffer = [_]u8{0x5a} ** 16;
    var writer_buffer = [_]u8{0xa5} ** 16;
    var client = Client{
        .allocator = std.testing.allocator,
        .io = undefined,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &reader_buffer,
        .writer_buffer = &writer_buffer,
    };

    client.wipeTransportBuffers();

    for (reader_buffer ++ writer_buffer) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "zero OAuth token lifetime cancels the pending request" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const register_response =
        \\{"jsonrpc":"2.0","id":1,"result":{"handle":"interest-1"}}
    ;
    const event =
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"s1","event":{"type":"mcp.oauth_required","data":{"requestId":"oauth-1","serverName":"server","serverUrl":"https://example.test","reason":"initial"}}}}
    ;
    const cancel_response =
        \\{"jsonrpc":"2.0","id":2,"result":{"success":true}}
    ;
    const responses = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}",
        .{
            register_response.len,
            register_response,
            event.len,
            event,
            cancel_response.len,
            cancel_response,
        },
    );
    defer allocator.free(responses);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "responses",
        .data = responses,
    });
    const response_file = try tmp.dir.openFile(
        std.testing.io,
        "responses",
        .{ .mode = .read_only },
    );
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
        .writer_buffer = &writer_buffer,
    };
    defer {
        if (client.pending_extension_runtime) |*runtime| runtime.deinit(allocator);
        for (client.events.items) |*queued| queued.deinit(allocator);
        client.events.deinit(allocator);
        for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
        client.extension_runtimes.deinit(allocator);
    }
    const handler = struct {
        fn handle(
            callback_allocator: std.mem.Allocator,
            _: ext.McpAuthRequest,
            _: ?*anyopaque,
        ) !ext.McpAuthResult {
            return .{ .token = .{
                .access_token = try callback_allocator.dupe(u8, "secret"),
                .expires_in_seconds = 0,
            } };
        }
    }.handle;
    try client.beginExtensionRuntime("s1", session_types.ResumeSessionConfig{
        .extensions = .{ .common = .{ .mcp = .{
            .on_auth_request = handler,
        } } },
    }, &.{});
    try client.commitExtensionRuntime("s1", .{}, &.{});

    const session = Session{ .client = &client, .id = "s1" };
    try std.testing.expectError(
        error.InvalidMcpAuthTokenExpiration,
        session.nextEvent(),
    );
    try writer.interface.flush();
    const requests = try tmp.dir.readFileAlloc(
        std.testing.io,
        "requests",
        allocator,
        .limited(4096),
    );
    defer allocator.free(requests);
    try std.testing.expect(
        std.mem.indexOf(u8, requests, "\"kind\":\"cancelled\"") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, requests, "\"accessToken\"") == null,
    );
}

test "review regressions preserve protocol semantics" {
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
        for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
        client.extension_runtimes.deinit(allocator);
    }
    try client.beginExtensionRuntime("s1", session_types.ResumeSessionConfig{
        .extensions = .{ .common = .{ .experimental = .{ .mcp_apps = true } } },
    }, &.{});
    const response = try std.json.parseFromSlice(
        WireSessionLifecycleResponse,
        allocator,
        \\{"sessionId":"s1","capabilities":{"ui":{"mcpApps":true}},"grantedEnvironmentVariables":{"TOKEN":"secret","EXTRA":"no"}}
    ,
        .{ .allocate = .alloc_always },
    );
    defer response.deinit();
    try client.commitExtensionRuntime("s1", response.value, &.{"TOKEN"});
    const session = Session{ .client = &client, .id = "s1" };
    var grants = try session.snapshotEnvironmentGrants(allocator);
    defer grants.deinit();
    try std.testing.expectEqualStrings("secret", grants.get("TOKEN").?);
    try std.testing.expect(grants.get("EXTRA") == null);
    try std.testing.expect(
        grants.items[0].value.ptr !=
            client.findExtensionRuntime("s1").?.granted_environment_variables.items[0].value.ptr,
    );

    const apps = try session.experimental(.mcp_apps);
    try std.testing.expectError(error.InvalidMcpAppToolArguments, apps.callTool(
        allocator,
        .{
            .server_name = "server",
            .tool_name = "tool",
            .arguments_json = "[]",
            .origin_server_name = "origin",
        },
    ));

    const mapped = resumeConfigFromCreate(.{
        .model = "model",
        .streaming = true,
        .extensions = .{ .extension_sdk_path = "/sdk" },
    });
    try std.testing.expectEqualStrings("model", mapped.model.?);
    try std.testing.expect(mapped.streaming);
    try std.testing.expect(mapped.suppress_resume_event);
    try std.testing.expectEqualStrings("/sdk", mapped.extensions.extension_sdk_path.?);

    const joined = resumeConfigFromJoin(.{});
    try std.testing.expect(
        joined.on_permission_request.? ==
            session_types.defaultJoinSessionPermissionHandler,
    );
    const overridden_join = resumeConfigFromJoin(.{
        .on_permission_request = session_types.approveAll,
    });
    try std.testing.expect(
        overridden_join.on_permission_request.? == session_types.approveAll,
    );

    const stdio_json = try lowerStdioMcp(allocator, .{
        .command = "server",
        .working_directory = "/repo",
    });
    defer allocator.free(stdio_json);
    const stdio = try std.json.parseFromSlice(std.json.Value, allocator, stdio_json, .{});
    defer stdio.deinit();
    try std.testing.expectEqualStrings(
        "/repo",
        stdio.value.object.get("cwd").?.string,
    );
    try std.testing.expect(!stdio.value.object.contains("workingDirectory"));
}

test "OAuth errors cancel and canvas identity is instance-only" {
    const outcome = invokeMcpAuthHandler(struct {
        fn handle(
            _: std.mem.Allocator,
            _: ext.McpAuthRequest,
            _: ?*anyopaque,
        ) !ext.McpAuthResult {
            return error.LoginFailed;
        }
    }.handle, std.testing.allocator, .{
        .request_id = "request-1",
        .server_name = "tickets",
        .server_url = "https://example.test",
        .reason = .initial,
    }, null);
    try std.testing.expect(outcome.result == .cancelled);
    try std.testing.expect(outcome.handler_error.? == error.LoginFailed);

    const allocator = std.testing.allocator;
    var runtime = try SessionExtensionRuntime.init(
        allocator,
        "s1",
        session_types.ResumeSessionConfig{},
        &.{},
    );
    defer runtime.deinit(allocator);
    try upsertOpenCanvas(&runtime, allocator, try cloneOpenCanvas(allocator, .{
        .instance_id = "same",
        .extension_id = "old",
        .canvas_id = "first",
    }));
    try upsertOpenCanvas(&runtime, allocator, try cloneOpenCanvas(allocator, .{
        .instance_id = "same",
        .extension_id = "new",
        .canvas_id = "second",
    }));
    try std.testing.expectEqual(@as(usize, 1), runtime.open_canvases.items.len);
    try std.testing.expectEqualStrings("new", runtime.open_canvases.items[0].extension_id);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var null_client = Client{
        .allocator = allocator,
        .io = undefined,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    try null_client.writeNullSuccess(&output.writer, .{ .integer = 1 });
    const body = try framedBody(allocator, output.written());
    defer allocator.free(body);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null}", body);
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

fn deliveryEventForTest(
    _: std.mem.Allocator,
    event: session_types.SessionEvent,
) !session_types.SessionEvent {
    return event;
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
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"session.error","data":{"errorType":"provider","message":"Try later"}}
    ,
        .{},
    );
    defer parsed.deinit();
    var delivery = EventDelivery{
        .session_id = try allocator.dupe(u8, "session-1"),
        .event = try session_types.parseEvent(allocator, parsed.value),
        .diagnostic_frame = try allocator.dupe(u8,
            \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"session-1","event":{"type":"session.error","data":{"errorType":"provider","message":"Try later"}}}}
        ),
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
        client.events.items[0].event.assistant_message.content,
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
        .event = .{ .session_idle = .{} },
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
            .event = .{ .session_idle = .{} },
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
            .event = .{ .session_idle = .{} },
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
    try std.testing.expectEqual(error.EndOfStream, failure_value.native_error);
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
        \\{"type":"external_tool.requested","data":{"requestId":"request-1","sessionId":"session-1","toolCallId":"call-1","toolName":"explode","arguments":{}}}
    ,
        .{},
    );
    defer event_json.deinit();
    try client.events.append(allocator, .{
        .session_id = try allocator.dupe(u8, "session-1"),
        .event = try deliveryEventForTest(
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
    switch (delivery.event) {
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

test "create resume and parent join lower custom agents to literal lifecycle JSON" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const create_response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"sessionId\":\"created\"}}";
    const resume_response = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"sessionId\":\"session-1\"}}";
    const join_response = "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"sessionId\":\"parent-session\"}}";
    const responses = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}",
        .{
            create_response.len,
            create_response,
            resume_response.len,
            resume_response,
            join_response.len,
            join_response,
        },
    );
    defer allocator.free(responses);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = responses });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{});
    defer response_file.close(std.testing.io);
    var reader_buffer: [4096]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
    const request_file = try tmp.dir.createFile(std.testing.io, "requests", .{});
    defer request_file.close(std.testing.io);
    var writer_buffer: [4096]u8 = undefined;
    var writer = request_file.writer(std.testing.io, &writer_buffer);
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = &reader,
        .writer = &writer,
        .reader_buffer = &.{},
        .writer_buffer = &writer_buffer,
    };
    defer {
        for (client.session_ids.items) |id| allocator.free(id);
        client.session_ids.deinit(allocator);
        for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
        client.extension_runtimes.deinit(allocator);
    }

    const created = try client.createSession(.{
        .session_id = "created",
        .custom_agents = &.{.{
            .name = "reviewer",
            .display_name = "Code reviewer",
            .description = "Reviews code.",
            .tools = &.{"read"},
            .prompt = "Review.",
            .mcp_servers = &.{.{
                .name = "docs",
                .config = .{ .stdio = .{
                    .command = "docs-mcp",
                    .args = &.{"--stdio"},
                    .env = &.{.{ .name = "TOKEN", .value = "secret" }},
                    .working_directory = "/repo",
                    .tools = &.{"lookup"},
                    .timeout_ms = 25,
                } },
            }},
            .infer = false,
            .skills = &.{"review"},
            .model = "gpt-5.4",
            .reasoning_effort = .xhigh,
        }},
        .default_agent = .{ .excluded_tools = &.{"deploy"} },
        .agent = .{ .custom_agent = "reviewer" },
        .custom_agents_local_only = true,
        .excluded_builtin_agents = &.{"explore"},
    });
    try std.testing.expectEqualStrings("created", created.id);
    const resumed = try client.resumeSession("session-1", .{
        .custom_agents = &.{.{
            .name = "docs",
            .prompt = "Answer from docs.",
            .mcp_servers = &.{.{
                .name = "search",
                .config = .{ .http = .{
                    .transport = .sse,
                    .url = "https://example.test/mcp",
                    .headers = &.{.{ .name = "Authorization", .value = "secret" }},
                    .tools = &.{"search"},
                    .timeout_ms = 50,
                } },
            }},
        }},
        .agent = .{ .custom_agent = "docs" },
    });
    try std.testing.expectEqualStrings("session-1", resumed.id);
    var joined = try client.joinParentSession("parent-session", .{
        .custom_agents = &.{.{
            .name = "parent-reviewer",
            .display_name = "Parent reviewer",
            .description = "Reviews the parent session.",
            .tools = &.{"read"},
            .prompt = "Review the parent.",
            .mcp_servers = &.{.{
                .name = "parent-docs",
                .config = .{ .stdio = .{
                    .command = "parent-mcp",
                    .args = &.{"--stdio"},
                    .env = &.{.{ .name = "TOKEN", .value = "secret" }},
                    .working_directory = "/parent",
                    .tools = &.{"lookup"},
                    .timeout_ms = 75,
                } },
            }},
            .infer = true,
            .skills = &.{"review"},
            .model = "gpt-5.4",
            .reasoning_effort = .max,
        }},
        .default_agent = .{ .excluded_tools = &.{"write"} },
        .agent = .{ .custom_agent = "parent-reviewer" },
        .custom_agents_local_only = false,
        .excluded_builtin_agents = &.{"task"},
    });
    defer joined.deinit();
    try std.testing.expectEqualStrings("parent-session", joined.session.id);

    const requests = try tmp.dir.readFileAlloc(std.testing.io, "requests", allocator, .limited(8192));
    defer allocator.free(requests);
    var frames = std.Io.Reader.fixed(requests);
    const create_body = try json_rpc.readFrame(allocator, &frames);
    defer allocator.free(create_body);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"method":"session.create","params":{"sessionId":"created","streaming":false,"tools":[],"customAgents":[{"name":"reviewer","displayName":"Code reviewer","description":"Reviews code.","tools":["read"],"prompt":"Review.","mcpServers":{"docs":{"type":"stdio","command":"docs-mcp","args":["--stdio"],"env":{"TOKEN":"secret"},"cwd":"/repo","tools":["lookup"],"timeout":25}},"infer":false,"skills":["review"],"model":"gpt-5.4","reasoningEffort":"xhigh"}],"defaultAgent":{"excludedTools":["deploy"]},"agent":"reviewer","customAgentsLocalOnly":true,"excludedBuiltinAgents":["explore"],"toolFilterPrecedence":"excluded","requestPermission":false,"requestUserInput":false,"enableManagedSettings":false}}
    , create_body);
    const resume_body = try json_rpc.readFrame(allocator, &frames);
    defer allocator.free(resume_body);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":2,"method":"session.resume","params":{"sessionId":"session-1","streaming":false,"tools":[],"customAgents":[{"name":"docs","prompt":"Answer from docs.","mcpServers":{"search":{"type":"sse","url":"https://example.test/mcp","headers":{"Authorization":"secret"},"tools":["search"],"timeout":50}}}],"agent":"docs","toolFilterPrecedence":"excluded","requestPermission":false,"requestUserInput":false,"enableManagedSettings":false}}
    , resume_body);
    const join_body = try json_rpc.readFrame(allocator, &frames);
    defer allocator.free(join_body);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":3,"method":"session.resume","params":{"sessionId":"parent-session","streaming":false,"tools":[],"customAgents":[{"name":"parent-reviewer","displayName":"Parent reviewer","description":"Reviews the parent session.","tools":["read"],"prompt":"Review the parent.","mcpServers":{"parent-docs":{"type":"stdio","command":"parent-mcp","args":["--stdio"],"env":{"TOKEN":"secret"},"cwd":"/parent","tools":["lookup"],"timeout":75}},"infer":true,"skills":["review"],"model":"gpt-5.4","reasoningEffort":"max"}],"defaultAgent":{"excludedTools":["write"]},"agent":"parent-reviewer","customAgentsLocalOnly":false,"excludedBuiltinAgents":["task"],"toolFilterPrecedence":"excluded","requestPermission":true,"requestUserInput":false,"enableManagedSettings":false,"disableResume":true}}
    , join_body);
    try std.testing.expectEqualStrings("", frames.buffered());
}

test "custom agent optional slices preserve omitted and empty values" {
    const allocator = std.testing.allocator;

    var omitted_values = ExtensionWireValues.init(allocator);
    defer omitted_values.deinit();
    const omitted_request = try buildCreateSessionRequest(.{}, &.{}, &omitted_values);
    const omitted_encoded = try json_rpc.encodeRequest(
        allocator,
        33,
        "session.create",
        omitted_request,
    );
    defer allocator.free(omitted_encoded);
    const omitted = try std.json.parseFromSlice(std.json.Value, allocator, omitted_encoded, .{});
    defer omitted.deinit();
    const omitted_params = omitted.value.object.get("params").?.object;
    try std.testing.expect(!omitted_params.contains("customAgents"));
    try std.testing.expect(!omitted_params.contains("defaultAgent"));
    try std.testing.expect(!omitted_params.contains("agent"));
    try std.testing.expect(!omitted_params.contains("customAgentsLocalOnly"));
    try std.testing.expect(!omitted_params.contains("excludedBuiltinAgents"));

    var empty_agents_values = ExtensionWireValues.init(allocator);
    defer empty_agents_values.deinit();
    try empty_agents_values.lowerCustomAgents(&.{});
    const empty_agents_request = try buildCreateSessionRequest(
        .{
            .custom_agents = &.{},
            .default_agent = .{},
        },
        &.{},
        &empty_agents_values,
    );
    const empty_agents_encoded = try json_rpc.encodeRequest(
        allocator,
        34,
        "session.create",
        empty_agents_request,
    );
    defer allocator.free(empty_agents_encoded);
    const empty_agents = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        empty_agents_encoded,
        .{},
    );
    defer empty_agents.deinit();
    const empty_agents_params = empty_agents.value.object.get("params").?.object;
    try std.testing.expectEqual(
        @as(usize, 0),
        empty_agents_params.get("customAgents").?.array.items.len,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        empty_agents_params.get("defaultAgent").?.object.count(),
    );

    const config = session_types.CreateSessionConfig{
        .custom_agents = &.{
            .{ .name = "inherit", .prompt = "Inherit." },
            .{
                .name = "empty",
                .prompt = "Empty.",
                .tools = &.{},
                .mcp_servers = &.{},
                .skills = &.{},
            },
        },
        .default_agent = .{ .excluded_tools = &.{} },
        .excluded_builtin_agents = &.{},
    };
    var empty_values = ExtensionWireValues.init(allocator);
    defer empty_values.deinit();
    try empty_values.lowerCustomAgents(config.custom_agents);
    const empty_request = try buildCreateSessionRequest(config, &.{}, &empty_values);
    const empty_encoded = try json_rpc.encodeRequest(allocator, 35, "session.create", empty_request);
    defer allocator.free(empty_encoded);
    const empty = try std.json.parseFromSlice(std.json.Value, allocator, empty_encoded, .{});
    defer empty.deinit();
    const params = empty.value.object.get("params").?.object;
    const agents = params.get("customAgents").?.array.items;
    try std.testing.expect(!agents[0].object.contains("tools"));
    try std.testing.expect(!agents[0].object.contains("mcpServers"));
    try std.testing.expect(!agents[0].object.contains("skills"));
    try std.testing.expectEqual(@as(usize, 0), agents[1].object.get("tools").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), agents[1].object.get("mcpServers").?.object.count());
    try std.testing.expectEqual(@as(usize, 0), agents[1].object.get("skills").?.array.items.len);
    try std.testing.expectEqual(
        @as(usize, 0),
        params.get("defaultAgent").?.object.get("excludedTools").?.array.items.len,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        params.get("excludedBuiltinAgents").?.array.items.len,
    );
}

test "custom agent validation precedes lifecycle state and RPC writes" {
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
    const duplicate = &.{
        session_types.CustomAgentConfig{ .name = "same", .prompt = "One." },
        session_types.CustomAgentConfig{ .name = "same", .prompt = "Two." },
    };
    const unknown = &.{
        session_types.CustomAgentConfig{ .name = "known", .prompt = "Known." },
    };

    try std.testing.expectError(
        error.DuplicateCustomAgentName,
        client.createSession(.{ .custom_agents = duplicate }),
    );
    try std.testing.expectError(
        error.DuplicateCustomAgentName,
        client.resumeSession("s1", .{ .custom_agents = duplicate }),
    );
    try std.testing.expectError(
        error.UnknownCustomAgent,
        client.createSession(.{
            .custom_agents = unknown,
            .agent = .{ .custom_agent = "missing" },
        }),
    );
    try std.testing.expectError(
        error.UnknownCustomAgent,
        client.resumeSession("s1", .{
            .custom_agents = unknown,
            .agent = .{ .custom_agent = "missing" },
        }),
    );
    try std.testing.expectError(
        error.UnknownCustomAgent,
        client.joinSession("s1", .{
            .custom_agents = unknown,
            .agent = .{ .custom_agent = "missing" },
        }),
    );
    try std.testing.expectError(
        error.UnknownCustomAgent,
        client.joinParentSession("s1", .{
            .custom_agents = unknown,
            .agent = .{ .custom_agent = "missing" },
        }),
    );
    try std.testing.expectError(
        error.InvalidMcpServer,
        client.createSession(.{
            .custom_agents = &.{.{
                .name = "broken",
                .prompt = "Broken.",
                .mcp_servers = &.{.{
                    .name = "server",
                    .config = .{ .stdio = .{ .command = "" } },
                }},
            }},
        }),
    );
    try std.testing.expectEqual(@as(u64, 1), client.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.session_ids.items.len);
    try std.testing.expectEqual(@as(usize, 0), client.extension_runtimes.items.len);
    try std.testing.expect(client.pending_extension_runtime == null);
}

test "create and join mappings preserve custom agent configuration" {
    const agents = &.{
        session_types.CustomAgentConfig{ .name = "reviewer", .prompt = "Review." },
    };
    const create = resumeConfigFromCreate(.{
        .custom_agents = agents,
        .default_agent = .{ .excluded_tools = &.{"deploy"} },
        .agent = .{ .custom_agent = "reviewer" },
        .custom_agents_local_only = false,
        .excluded_builtin_agents = &.{"explore"},
    });
    const joined = resumeConfigFromJoin(.{
        .custom_agents = agents,
        .default_agent = .{ .excluded_tools = &.{"deploy"} },
        .agent = .{ .custom_agent = "reviewer" },
        .custom_agents_local_only = false,
        .excluded_builtin_agents = &.{"explore"},
    });

    for ([_]session_types.ResumeSessionConfig{ create, joined }) |mapped| {
        try std.testing.expectEqualStrings("reviewer", mapped.custom_agents.?[0].name);
        try std.testing.expectEqualStrings(
            "deploy",
            mapped.default_agent.?.excluded_tools.?[0],
        );
        switch (mapped.agent) {
            .custom_agent => |name| try std.testing.expectEqualStrings("reviewer", name),
            .default_agent => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqual(false, mapped.custom_agents_local_only.?);
        try std.testing.expectEqualStrings("explore", mapped.excluded_builtin_agents.?[0]);
    }
}

test "resume request places provider in params and disables nested resume" {
    const allocator = std.testing.allocator;
    var extension_values = ExtensionWireValues.init(allocator);
    defer extension_values.deinit();
    const config = session_types.SessionConfig{
        .provider = .{
            .base_url = "https://api.anthropic.com",
            .protocol = .anthropic,
            .authentication = .{ .api_key = "key" },
        },
    };
    var prepared = try provider.prepareSessionProviders(
        allocator,
        config.provider,
        config.providers,
        config.models,
    );
    defer prepared.deinit(allocator);
    const params = try buildPreparedResumeSessionRequest(
        "session-1",
        resumeConfigFromCreate(config),
        &.{},
        &extension_values,
        &.{},
        prepared,
    );
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

test "create and resume requests encode complete provider graphs exactly" {
    const allocator = std.testing.allocator;
    var create_extension_values = ExtensionWireValues.init(allocator);
    defer create_extension_values.deinit();
    var resume_extension_values = ExtensionWireValues.init(allocator);
    defer resume_extension_values.deinit();
    const token_callback = struct {
        fn get(
            inner_allocator: std.mem.Allocator,
            _: provider.ProviderTokenRequest,
            _: ?*anyopaque,
        ) ![]u8 {
            return inner_allocator.dupe(u8, "dynamic");
        }
    }.get;
    const config = session_types.SessionConfig{
        .session_id = "session-provider-graph",
        .providers = &.{
            .{
                .name = "openai",
                .base_url = "https://api.openai.com/v1",
                .protocol = .{ .openai = .{ .responses = .websockets } },
                .authentication = .{ .api_key_and_bearer_token = .{
                    .api_key = "key",
                    .bearer_token = "static",
                } },
                .bearer_token_provider = .{ .callback = token_callback },
                .headers = &.{.{ .name = "X-Tenant", .value = "acme" }},
            },
        },
        .models = &.{
            .{
                .id = "reasoner",
                .provider = "openai",
                .wire_model = "deployment",
                .model_id = "gpt-4.1",
                .name = "Reasoner",
                .max_prompt_tokens = 100,
                .max_context_window_tokens = 200,
                .max_output_tokens = 50,
                .capabilities = .{ .supports = .{ .reasoningEffort = true } },
            },
        },
    };
    var prepared = try provider.prepareSessionProviders(
        allocator,
        config.provider,
        config.providers,
        config.models,
    );
    defer prepared.deinit(allocator);

    const create = try json_rpc.encodeRequest(
        allocator,
        21,
        "session.create",
        try buildPreparedCreateSessionRequest(
            config.session_id,
            config,
            &.{},
            &create_extension_values,
            prepared,
        ),
    );
    defer allocator.free(create);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"session.create\",\"params\":{\"sessionId\":\"session-provider-graph\",\"providers\":[{\"name\":\"openai\",\"type\":\"openai\",\"wireApi\":\"responses\",\"transport\":\"websockets\",\"baseUrl\":\"https://api.openai.com/v1\",\"apiKey\":\"key\",\"bearerToken\":\"static\",\"headers\":{\"X-Tenant\":\"acme\"},\"hasBearerTokenProvider\":true}],\"models\":[{\"id\":\"reasoner\",\"provider\":\"openai\",\"wireModel\":\"deployment\",\"modelId\":\"gpt-4.1\",\"name\":\"Reasoner\",\"maxPromptTokens\":100,\"maxContextWindowTokens\":200,\"maxOutputTokens\":50,\"capabilities\":{\"supports\":{\"reasoningEffort\":true}}}],\"streaming\":false,\"tools\":[],\"toolFilterPrecedence\":\"excluded\",\"requestPermission\":false,\"requestUserInput\":false,\"enableManagedSettings\":false}}",
        create,
    );

    const resume_encoded = try json_rpc.encodeRequest(
        allocator,
        22,
        "session.resume",
        try buildPreparedResumeSessionRequest(
            "session-provider-graph",
            resumeConfigFromCreate(config),
            &.{},
            &resume_extension_values,
            &.{},
            prepared,
        ),
    );
    defer allocator.free(resume_encoded);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":22,\"method\":\"session.resume\",\"params\":{\"sessionId\":\"session-provider-graph\",\"providers\":[{\"name\":\"openai\",\"type\":\"openai\",\"wireApi\":\"responses\",\"transport\":\"websockets\",\"baseUrl\":\"https://api.openai.com/v1\",\"apiKey\":\"key\",\"bearerToken\":\"static\",\"headers\":{\"X-Tenant\":\"acme\"},\"hasBearerTokenProvider\":true}],\"models\":[{\"id\":\"reasoner\",\"provider\":\"openai\",\"wireModel\":\"deployment\",\"modelId\":\"gpt-4.1\",\"name\":\"Reasoner\",\"maxPromptTokens\":100,\"maxContextWindowTokens\":200,\"maxOutputTokens\":50,\"capabilities\":{\"supports\":{\"reasoningEffort\":true}}}],\"streaming\":false,\"tools\":[],\"toolFilterPrecedence\":\"excluded\",\"requestPermission\":false,\"requestUserInput\":false,\"enableManagedSettings\":false,\"disableResume\":true}}",
        resume_encoded,
    );
}

test "singular create request encodes every provider field and default callback routing" {
    const allocator = std.testing.allocator;
    var create_extension_values = ExtensionWireValues.init(allocator);
    defer create_extension_values.deinit();
    var resume_extension_values = ExtensionWireValues.init(allocator);
    defer resume_extension_values.deinit();
    const callback = struct {
        fn get(
            inner_allocator: std.mem.Allocator,
            _: provider.ProviderTokenRequest,
            _: ?*anyopaque,
        ) ![]u8 {
            return inner_allocator.dupe(u8, "dynamic");
        }
    }.get;
    const config = session_types.SessionConfig{
        .session_id = "singular",
        .provider = .{
            .base_url = "https://api.example.test",
            .protocol = .{ .openai = .{ .responses = .websockets } },
            .authentication = .{ .api_key_and_bearer_token = .{
                .api_key = "key",
                .bearer_token = "static",
            } },
            .bearer_token_provider = .{ .callback = callback },
            .headers = &.{.{ .name = "X-Region", .value = "west" }},
            .model_id = "gpt-4.1",
            .model_capabilities = .{ .supports = .{ .vision = true } },
            .provider_name = "telemetry",
            .wire_model = "deployment",
            .max_prompt_tokens = 100,
            .max_context_window_tokens = 200,
            .max_output_tokens = 50,
        },
    };
    var prepared = try provider.prepareSessionProviders(
        allocator,
        config.provider,
        config.providers,
        config.models,
    );
    defer prepared.deinit(allocator);
    try std.testing.expectEqualStrings("default", prepared.token_bindings[0].provider_name);

    const encoded = try json_rpc.encodeRequest(
        allocator,
        23,
        "session.create",
        try buildPreparedCreateSessionRequest(
            "singular",
            config,
            &.{},
            &create_extension_values,
            prepared,
        ),
    );
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":23,\"method\":\"session.create\",\"params\":{\"sessionId\":\"singular\",\"provider\":{\"type\":\"openai\",\"wireApi\":\"responses\",\"transport\":\"websockets\",\"baseUrl\":\"https://api.example.test\",\"apiKey\":\"key\",\"bearerToken\":\"static\",\"headers\":{\"X-Region\":\"west\"},\"modelId\":\"gpt-4.1\",\"modelCapabilities\":{\"supports\":{\"vision\":true}},\"providerName\":\"telemetry\",\"wireModel\":\"deployment\",\"maxPromptTokens\":100,\"maxContextWindowTokens\":200,\"maxOutputTokens\":50,\"hasBearerTokenProvider\":true},\"streaming\":false,\"tools\":[],\"toolFilterPrecedence\":\"excluded\",\"requestPermission\":false,\"requestUserInput\":false,\"enableManagedSettings\":false}}",
        encoded,
    );

    const resume_encoded = try json_rpc.encodeRequest(
        allocator,
        24,
        "session.resume",
        try buildPreparedResumeSessionRequest(
            "singular",
            resumeConfigFromCreate(config),
            &.{},
            &resume_extension_values,
            &.{},
            prepared,
        ),
    );
    defer allocator.free(resume_encoded);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":24,\"method\":\"session.resume\",\"params\":{\"sessionId\":\"singular\",\"provider\":{\"type\":\"openai\",\"wireApi\":\"responses\",\"transport\":\"websockets\",\"baseUrl\":\"https://api.example.test\",\"apiKey\":\"key\",\"bearerToken\":\"static\",\"headers\":{\"X-Region\":\"west\"},\"modelId\":\"gpt-4.1\",\"modelCapabilities\":{\"supports\":{\"vision\":true}},\"providerName\":\"telemetry\",\"wireModel\":\"deployment\",\"maxPromptTokens\":100,\"maxContextWindowTokens\":200,\"maxOutputTokens\":50,\"hasBearerTokenProvider\":true},\"streaming\":false,\"tools\":[],\"toolFilterPrecedence\":\"excluded\",\"requestPermission\":false,\"requestUserInput\":false,\"enableManagedSettings\":false,\"disableResume\":true}}",
        resume_encoded,
    );
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
        const resume_response = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"sessionId\":\"existing-session\"}}";
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
        defer deinitTestClientRegistries(&client);
        const config = session_types.SessionConfig{
            .session_id = "created-session",
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
        try std.testing.expectError(error.InvalidMaxPromptImages, client.joinSession("existing-session", invalid_config));

        const requests = try tmp.dir.readFileAlloc(std.testing.io, "requests", allocator, .limited(8192));
        defer allocator.free(requests);
        var frames = std.Io.Reader.fixed(requests);
        const model_and_provider = "\"model\":\"local-vision-model\",\"provider\":{\"type\":\"openai\",\"wireApi\":\"completions\",\"baseUrl\":\"http://localhost:8000/v1\",\"modelId\":\"local-vision-model\",\"wireModel\":\"local-vision-model\"}";
        const defaults = ",\"streaming\":false,\"tools\":[],\"toolFilterPrecedence\":\"excluded\",\"requestPermission\":false,\"requestUserInput\":false,\"enableManagedSettings\":false";
        const expected_create = try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.create\",\"params\":{{{s}{s}{s}}}}}",
            .{ "\"sessionId\":\"created-session\"," ++ model_and_provider, case.wire, defaults },
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

const ProviderTokenTestContext = struct {
    token: []const u8,
    calls: usize = 0,
    expected_session_id: []const u8,
    expected_provider_name: []const u8,
    matched: bool = false,
};

fn providerTokenTestCallback(
    allocator: std.mem.Allocator,
    request: provider.ProviderTokenRequest,
    context_ptr: ?*anyopaque,
) ![]u8 {
    const context: *ProviderTokenTestContext = @ptrCast(@alignCast(context_ptr.?));
    context.calls += 1;
    context.matched =
        std.mem.eql(u8, request.session_id, context.expected_session_id) and
        std.mem.eql(u8, request.provider_name, context.expected_provider_name);
    return allocator.dupe(u8, context.token);
}

fn failingProviderTokenCallback(
    _: std.mem.Allocator,
    _: provider.ProviderTokenRequest,
    _: ?*anyopaque,
) ![]u8 {
    return error.TokenUnavailable;
}

fn deinitTestClientRegistries(client: *Client) void {
    if (client.pending_extension_runtime) |*runtime| runtime.deinit(client.allocator);
    for (client.extension_runtimes.items) |*runtime| runtime.deinit(client.allocator);
    client.extension_runtimes.deinit(client.allocator);
    if (client.pending_provider_tokens) |registered| registered.deinit(client.allocator);
    for (client.events.items) |*event| event.deinit(client.allocator);
    client.events.deinit(client.allocator);
    client.lifecycle_events.deinit();
    for (client.tools.items) |tool| tool.deinit(client.allocator);
    client.tools.deinit(client.allocator);
    client.user_input_handlers.deinit(client.allocator);
    client.permission_handlers.deinit(client.allocator);
    for (client.provider_tokens.items) |registered| registered.deinit(client.allocator);
    client.provider_tokens.deinit(client.allocator);
    for (client.rpc_handlers.items) |handler| handler.deinit(client.allocator);
    client.rpc_handlers.deinit(client.allocator);
    for (client.session_ids.items) |id| client.allocator.free(id);
    client.session_ids.deinit(client.allocator);
}

test "provider token callback is routable before create response" {
    const allocator = std.testing.allocator;
    var context = ProviderTokenTestContext{
        .token = "create-token",
        .expected_session_id = "early-create",
        .expected_provider_name = "default",
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const callback_request =
        \\{"jsonrpc":"2.0","id":41,"method":"providerToken.getToken","params":{"sessionId":"early-create","providerName":"default"}}
    ;
    const create_response =
        \\{"jsonrpc":"2.0","id":1,"result":{"sessionId":"early-create"}}
    ;
    const responses = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}",
        .{ callback_request.len, callback_request, create_response.len, create_response },
    );
    defer allocator.free(responses);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = responses });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{});
    defer response_file.close(std.testing.io);
    var reader_buffer: [2048]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
    const request_file = try tmp.dir.createFile(std.testing.io, "requests", .{});
    defer request_file.close(std.testing.io);
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
    defer deinitTestClientRegistries(&client);

    const created = try client.createSession(.{
        .session_id = "early-create",
        .provider = .{
            .base_url = "https://example.test",
            .provider_name = "attribution-only",
            .bearer_token_provider = .{
                .callback = providerTokenTestCallback,
                .context = &context,
            },
        },
    });
    try std.testing.expectEqualStrings("early-create", created.id);
    try std.testing.expectEqual(@as(usize, 1), context.calls);
    try std.testing.expect(context.matched);

    const requests = try tmp.dir.readFileAlloc(std.testing.io, "requests", allocator, .limited(8192));
    defer allocator.free(requests);
    var frames = std.Io.Reader.fixed(requests);
    const create_frame = try json_rpc.readFrame(allocator, &frames);
    defer allocator.free(create_frame);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.create\",\"params\":{\"sessionId\":\"early-create\",\"provider\":{\"type\":\"openai\",\"wireApi\":\"completions\",\"baseUrl\":\"https://example.test\",\"providerName\":\"attribution-only\",\"hasBearerTokenProvider\":true},\"streaming\":false,\"tools\":[],\"toolFilterPrecedence\":\"excluded\",\"requestPermission\":false,\"requestUserInput\":false,\"enableManagedSettings\":false}}",
        create_frame,
    );
    const token_frame = try json_rpc.readFrame(allocator, &frames);
    defer allocator.free(token_frame);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":41,\"result\":{\"token\":\"create-token\"}}",
        token_frame,
    );
}

test "two named provider callbacks are routable before resume response" {
    const allocator = std.testing.allocator;
    var first_context = ProviderTokenTestContext{
        .token = "first-token",
        .expected_session_id = "early-resume",
        .expected_provider_name = "first",
    };
    var second_context = ProviderTokenTestContext{
        .token = "second-token",
        .expected_session_id = "early-resume",
        .expected_provider_name = "second",
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const first_request =
        \\{"jsonrpc":"2.0","id":51,"method":"providerToken.getToken","params":{"sessionId":"early-resume","providerName":"first"}}
    ;
    const second_request =
        \\{"jsonrpc":"2.0","id":52,"method":"providerToken.getToken","params":{"sessionId":"early-resume","providerName":"second"}}
    ;
    const resume_response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"sessionId\":\"early-resume\"}}";
    const responses = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}",
        .{
            first_request.len,
            first_request,
            second_request.len,
            second_request,
            resume_response.len,
            resume_response,
        },
    );
    defer allocator.free(responses);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = responses });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{});
    defer response_file.close(std.testing.io);
    var reader_buffer: [4096]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
    const request_file = try tmp.dir.createFile(std.testing.io, "requests", .{});
    defer request_file.close(std.testing.io);
    var writer_buffer: [4096]u8 = undefined;
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
    defer deinitTestClientRegistries(&client);

    const resumed = try client.joinSession("early-resume", .{
        .providers = &.{
            .{
                .name = "first",
                .base_url = "https://first.test",
                .bearer_token_provider = .{
                    .callback = providerTokenTestCallback,
                    .context = &first_context,
                },
            },
            .{
                .name = "second",
                .base_url = "https://second.test",
                .bearer_token_provider = .{
                    .callback = providerTokenTestCallback,
                    .context = &second_context,
                },
            },
        },
        .models = &.{
            .{ .id = "one", .provider = "first" },
            .{ .id = "two", .provider = "second" },
        },
    });
    try std.testing.expectEqualStrings("early-resume", resumed.id);
    try std.testing.expectEqual(@as(usize, 1), first_context.calls);
    try std.testing.expectEqual(@as(usize, 1), second_context.calls);
    try std.testing.expect(first_context.matched);
    try std.testing.expect(second_context.matched);

    const requests = try tmp.dir.readFileAlloc(std.testing.io, "requests", allocator, .limited(16384));
    defer allocator.free(requests);
    var frames = std.Io.Reader.fixed(requests);
    const resume_frame = try json_rpc.readFrame(allocator, &frames);
    defer allocator.free(resume_frame);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.resume\",\"params\":{\"sessionId\":\"early-resume\",\"providers\":[{\"name\":\"first\",\"type\":\"openai\",\"wireApi\":\"completions\",\"baseUrl\":\"https://first.test\",\"hasBearerTokenProvider\":true},{\"name\":\"second\",\"type\":\"openai\",\"wireApi\":\"completions\",\"baseUrl\":\"https://second.test\",\"hasBearerTokenProvider\":true}],\"models\":[{\"id\":\"one\",\"provider\":\"first\"},{\"id\":\"two\",\"provider\":\"second\"}],\"streaming\":false,\"tools\":[],\"toolFilterPrecedence\":\"excluded\",\"requestPermission\":false,\"requestUserInput\":false,\"enableManagedSettings\":false,\"disableResume\":true}}",
        resume_frame,
    );
    const first_frame = try json_rpc.readFrame(allocator, &frames);
    defer allocator.free(first_frame);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":51,\"result\":{\"token\":\"first-token\"}}",
        first_frame,
    );
    const second_frame = try json_rpc.readFrame(allocator, &frames);
    defer allocator.free(second_frame);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":52,\"result\":{\"token\":\"second-token\"}}",
        second_frame,
    );
}

test "provider token dispatch routes by session and provider and rejects invalid requests" {
    const allocator = std.testing.allocator;
    var first_context = ProviderTokenTestContext{
        .token = "session-one-token",
        .expected_session_id = "session-one",
        .expected_provider_name = "shared",
    };
    var second_context = ProviderTokenTestContext{
        .token = "session-two-token",
        .expected_session_id = "session-two",
        .expected_provider_name = "shared",
    };
    var client = Client{
        .allocator = allocator,
        .io = undefined,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer deinitTestClientRegistries(&client);
    try client.registerOwnedSession(
        try allocator.dupe(u8, "session-one"),
        .{},
        &.{.{
            .provider_name = "shared",
            .token_provider = .{
                .callback = providerTokenTestCallback,
                .context = &first_context,
            },
        }},
    );
    try client.registerOwnedSession(
        try allocator.dupe(u8, "session-two"),
        .{},
        &.{
            .{
                .provider_name = "shared",
                .token_provider = .{
                    .callback = providerTokenTestCallback,
                    .context = &second_context,
                },
            },
            .{
                .provider_name = "failing",
                .token_provider = .{ .callback = failingProviderTokenCallback },
            },
        },
    );

    const cases = [_]struct {
        id: i64,
        params_json: ?[]const u8,
        expected: []const u8,
    }{
        .{
            .id = 61,
            .params_json = "{\"sessionId\":\"session-one\",\"providerName\":\"shared\"}",
            .expected = "{\"jsonrpc\":\"2.0\",\"id\":61,\"result\":{\"token\":\"session-one-token\"}}",
        },
        .{
            .id = 62,
            .params_json = "{\"sessionId\":\"session-two\",\"providerName\":\"shared\"}",
            .expected = "{\"jsonrpc\":\"2.0\",\"id\":62,\"result\":{\"token\":\"session-two-token\"}}",
        },
        .{
            .id = 63,
            .params_json = "{\"sessionId\":\"session-two\",\"providerName\":\"failing\"}",
            .expected = "{\"jsonrpc\":\"2.0\",\"id\":63,\"error\":{\"code\":-32000,\"message\":\"TokenUnavailable\"}}",
        },
        .{
            .id = 64,
            .params_json = "{\"sessionId\":\"session-two\",\"providerName\":\"missing\"}",
            .expected = "{\"jsonrpc\":\"2.0\",\"id\":64,\"error\":{\"code\":-32601,\"message\":\"method not found\"}}",
        },
        .{
            .id = 65,
            .params_json = "{\"sessionId\":\"session-two\"}",
            .expected = "{\"jsonrpc\":\"2.0\",\"id\":65,\"error\":{\"code\":-32601,\"message\":\"method not found\"}}",
        },
        .{
            .id = 66,
            .params_json = "{\"sessionId\":\"session-two\",\"providerName\":\"shared\",\"extra\":true}",
            .expected = "{\"jsonrpc\":\"2.0\",\"id\":66,\"error\":{\"code\":-32602,\"message\":\"invalid provider token request\"}}",
        },
        .{
            .id = 67,
            .params_json = null,
            .expected = "{\"jsonrpc\":\"2.0\",\"id\":67,\"error\":{\"code\":-32601,\"message\":\"method not found\"}}",
        },
    };

    for (cases) |case| {
        var parsed_params: ?std.json.Parsed(std.json.Value) = if (case.params_json) |json|
            try std.json.parseFromSlice(std.json.Value, allocator, json, .{})
        else
            null;
        defer if (parsed_params) |*parsed| parsed.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        try client.dispatchServerRequest(
            &output.writer,
            .{ .integer = case.id },
            "providerToken.getToken",
            if (parsed_params) |parsed| parsed.value else null,
        );
        const body = try framedBody(allocator, output.written());
        defer allocator.free(body);
        try std.testing.expectEqualStrings(case.expected, body);
    }

    try std.testing.expectEqual(@as(usize, 1), first_context.calls);
    try std.testing.expectEqual(@as(usize, 1), second_context.calls);
    try std.testing.expect(first_context.matched);
    try std.testing.expect(second_context.matched);

    try client.registerRpcHandler("providerToken.getToken", struct {
        fn handle(
            inner_allocator: std.mem.Allocator,
            params_json: ?[]const u8,
            _: ?*anyopaque,
        ) ![]u8 {
            if (params_json == null or
                !std.mem.eql(
                    u8,
                    params_json.?,
                    "{\"sessionId\":\"session-two\",\"providerName\":\"untyped\"}",
                ))
            {
                return error.UnexpectedParams;
            }
            return inner_allocator.dupe(u8, "{\"token\":\"generic-token\"}");
        }
    }.handle, null);
    const fallback_params = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"sessionId\":\"session-two\",\"providerName\":\"untyped\"}",
        .{},
    );
    defer fallback_params.deinit();
    var fallback_output: std.Io.Writer.Allocating = .init(allocator);
    defer fallback_output.deinit();
    try client.dispatchServerRequest(
        &fallback_output.writer,
        .{ .integer = 68 },
        "providerToken.getToken",
        fallback_params.value,
    );
    const fallback_body = try framedBody(allocator, fallback_output.written());
    defer allocator.free(fallback_body);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":68,\"result\":{\"token\":\"generic-token\"}}",
        fallback_body,
    );

    try std.testing.expectError(
        error.SessionAlreadyActive,
        client.registerOwnedSession(
            try allocator.dupe(u8, "session-one"),
            .{},
            &.{},
        ),
    );
    try std.testing.expectEqual(@as(usize, 2), client.session_ids.items.len);
}

test "failed create and resume roll back provider token routes" {
    const allocator = std.testing.allocator;
    const callback = provider.BearerTokenProvider{ .callback = providerTokenTestCallback };
    const operations = [_]bool{ false, true };

    for (operations) |is_resume| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const rpc_error = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32000,\"message\":\"failed\"}}";
        const response = try std.fmt.allocPrint(
            allocator,
            "Content-Length: {d}\r\n\r\n{s}",
            .{ rpc_error.len, rpc_error },
        );
        defer allocator.free(response);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "response", .data = response });
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
        defer deinitTestClientRegistries(&client);
        const config = session_types.SessionConfig{
            .session_id = "rollback",
            .provider = .{
                .base_url = "https://example.test",
                .bearer_token_provider = callback,
            },
        };

        if (is_resume) {
            try std.testing.expectError(
                error.JsonRpcError,
                client.joinSession("rollback", config),
            );
        } else {
            try std.testing.expectError(error.JsonRpcError, client.createSession(config));
        }
        try std.testing.expectEqual(@as(usize, 0), client.session_ids.items.len);
        try std.testing.expectEqual(@as(usize, 0), client.provider_tokens.items.len);
    }
}

test "create rejects a mismatched runtime session id and rolls back" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const body =
        \\{"jsonrpc":"2.0","id":1,"result":{"sessionId":"different"}}
    ;
    const response = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );
    defer allocator.free(response);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "response", .data = response });
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
    defer deinitTestClientRegistries(&client);

    try std.testing.expectError(error.SessionIdMismatch, client.createSession(.{
        .session_id = "requested",
        .provider = .{
            .base_url = "https://example.test",
            .bearer_token_provider = .{ .callback = failingProviderTokenCallback },
        },
    }));
    try std.testing.expectEqual(@as(usize, 0), client.session_ids.items.len);
    try std.testing.expectEqual(@as(usize, 0), client.provider_tokens.items.len);
}

test "disconnect removes provider token registrations" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const body =
        \\{"jsonrpc":"2.0","id":1,"result":{"success":true}}
    ;
    const response = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );
    defer allocator.free(response);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "response", .data = response });
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
    defer deinitTestClientRegistries(&client);
    try client.registerOwnedSession(
        try allocator.dupe(u8, "disconnect-session"),
        .{},
        &.{.{
            .provider_name = "provider",
            .token_provider = .{ .callback = failingProviderTokenCallback },
        }},
    );

    try (Session{ .client = &client, .id = "disconnect-session" }).disconnect();
    try std.testing.expectEqual(@as(usize, 0), client.session_ids.items.len);
    try std.testing.expectEqual(@as(usize, 0), client.provider_tokens.items.len);

    const request = try tmp.dir.readFileAlloc(std.testing.io, "request", allocator, .limited(1024));
    defer allocator.free(request);
    const request_body = try framedBody(allocator, request);
    defer allocator.free(request_body);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.detach\",\"params\":{\"sessionId\":\"disconnect-session\"}}",
        request_body,
    );
}

test "client deinit frees provider token registrations" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const input_file = try tmp.dir.createFile(std.testing.io, "input", .{ .read = true });
    defer input_file.close(std.testing.io);
    const output_file = try tmp.dir.createFile(std.testing.io, "output", .{});
    defer output_file.close(std.testing.io);
    const reader_buffer = try allocator.alloc(u8, 64);
    const writer_buffer = try allocator.alloc(u8, 64);
    const reader = try allocator.create(std.Io.File.Reader);
    const writer = try allocator.create(std.Io.File.Writer);
    reader.* = input_file.readerStreaming(std.testing.io, reader_buffer);
    writer.* = output_file.writer(std.testing.io, writer_buffer);
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = reader,
        .writer = writer,
        .reader_buffer = reader_buffer,
        .writer_buffer = writer_buffer,
    };
    try client.registerOwnedSession(
        try allocator.dupe(u8, "deinit-session"),
        .{},
        &.{.{
            .provider_name = "provider",
            .token_provider = .{ .callback = failingProviderTokenCallback },
        }},
    );
    client.deinit();
}

fn appendTestFrame(
    allocator: std.mem.Allocator,
    frames: *std.ArrayList(u8),
    body: []const u8,
) !void {
    const frame = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );
    defer allocator.free(frame);
    try frames.appendSlice(allocator, frame);
}

fn deleteTestMcpAuthHandler(
    _: std.mem.Allocator,
    _: ext.McpAuthRequest,
    _: ?*anyopaque,
) !ext.McpAuthResult {
    return .cancelled;
}

fn deleteTestToolHandler(
    allocator: std.mem.Allocator,
    _: []const u8,
    _: ?*anyopaque,
) ![]u8 {
    return allocator.dupe(u8, "{}");
}

fn deleteTestUserInputHandler(
    allocator: std.mem.Allocator,
    _: session_types.UserInputRequest,
    _: ?*anyopaque,
) !session_types.UserInputResponse {
    return .{
        .answer = try allocator.dupe(u8, "answer"),
        .was_freeform = false,
    };
}

fn attachDeleteTestState(client: *Client, session_id: []const u8) !void {
    try client.registerOwnedSession(
        try client.allocator.dupe(u8, session_id),
        .{
            .tools = &.{.{
                .name = "delete-test-tool",
                .handler = deleteTestToolHandler,
            }},
            .on_permission_request = session_types.approveAll,
            .on_user_input_request = deleteTestUserInputHandler,
        },
        &.{.{
            .provider_name = "provider",
            .token_provider = .{ .callback = failingProviderTokenCallback },
        }},
    );
    try client.beginExtensionRuntime(
        session_id,
        session_types.ResumeSessionConfig{},
        &.{},
    );
    try client.commitExtensionRuntime(session_id, .{}, &.{});
    const runtime = client.findExtensionRuntime(session_id).?;
    runtime.mcp_auth_handler = deleteTestMcpAuthHandler;
    runtime.mcp_oauth_interest_handle =
        try client.allocator.dupe(u8, "interest-1");
    try client.events.append(client.allocator, .{
        .session_id = try client.allocator.dupe(u8, session_id),
        .event = .{ .session_idle = .{} },
    });
}

fn expectDeleteTestState(client: *Client, session_id: []const u8, present: bool) !void {
    const expected: usize = @intFromBool(present);
    try std.testing.expectEqual(expected, client.session_ids.items.len);
    try std.testing.expectEqual(expected, client.extension_runtimes.items.len);
    try std.testing.expectEqual(expected, client.events.items.len);
    try std.testing.expectEqual(expected, client.tools.items.len);
    try std.testing.expectEqual(expected, client.user_input_handlers.items.len);
    try std.testing.expectEqual(expected, client.permission_handlers.items.len);
    try std.testing.expectEqual(expected, client.provider_tokens.items.len);
    try std.testing.expectEqual(present, client.findExtensionRuntime(session_id) != null);
}

fn expectRequestBodies(
    allocator: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
    expected: []const []const u8,
) !void {
    const written = try tmp.dir.readFileAlloc(
        std.testing.io,
        "requests",
        allocator,
        .limited(8192),
    );
    defer allocator.free(written);
    var request_reader = std.Io.Reader.fixed(written);
    for (expected) |expected_body| {
        const actual = try json_rpc.readFrame(allocator, &request_reader);
        defer allocator.free(actual);
        try std.testing.expectEqualStrings(expected_body, actual);
    }
    try std.testing.expectEqualStrings("", request_reader.buffered());
}

test "delete session releases interest before remote success and removes registries" {
    const allocator = std.testing.allocator;
    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(allocator);
    try appendTestFrame(
        allocator,
        &frames,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"success\":true}}",
    );
    try appendTestFrame(
        allocator,
        &frames,
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"success\":true}}",
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = frames.items });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{});
    defer response_file.close(std.testing.io);
    var reader_buffer: [2048]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
    const request_file = try tmp.dir.createFile(std.testing.io, "requests", .{});
    defer request_file.close(std.testing.io);
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
    defer deinitTestClientRegistries(&client);
    try attachDeleteTestState(&client, "delete-session");

    try client.deleteSession("delete-session");
    try expectDeleteTestState(&client, "delete-session", false);

    try writer.interface.flush();
    try expectRequestBodies(allocator, &tmp, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.eventLog.releaseInterest\",\"params\":{\"sessionId\":\"delete-session\",\"handle\":\"interest-1\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session.delete\",\"params\":{\"sessionId\":\"delete-session\"}}",
    });
}

test "delete session release failure retains state and prevents delete" {
    const allocator = std.testing.allocator;
    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(allocator);
    try appendTestFrame(
        allocator,
        &frames,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"success\":false}}",
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = frames.items });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{});
    defer response_file.close(std.testing.io);
    var reader_buffer: [2048]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
    const request_file = try tmp.dir.createFile(std.testing.io, "requests", .{});
    defer request_file.close(std.testing.io);
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
    defer deinitTestClientRegistries(&client);
    try attachDeleteTestState(&client, "delete-session");

    var failure = switch (try client.deleteSessionDetailed("delete-session")) {
        .success => return error.TestExpectedClientFailure,
        .failure => |failure_value| failure_value,
    };
    defer failure.deinit();
    try std.testing.expectEqual(error.EventInterestNotReleased, failure.native_error);
    switch (failure.detail.client) {
        .io => |io_failure| try std.testing.expectEqual(
            errors.ClientOperation.callback,
            io_failure.operation,
        ),
        else => return error.TestExpectedClientFailure,
    }
    try expectDeleteTestState(&client, "delete-session", true);
    try std.testing.expectEqualStrings(
        "interest-1",
        client.findExtensionRuntime("delete-session").?.mcp_oauth_interest_handle.?,
    );

    try writer.interface.flush();
    try expectRequestBodies(allocator, &tmp, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.eventLog.releaseInterest\",\"params\":{\"sessionId\":\"delete-session\",\"handle\":\"interest-1\"}}",
    });
}

test "delete session rejection restores interest and retains state" {
    const allocator = std.testing.allocator;
    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(allocator);
    const responses = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"success\":true}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"success\":false,\"error\":\"delete refused\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"handle\":\"interest-2\"}}",
    };
    for (responses) |body| try appendTestFrame(allocator, &frames, body);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = frames.items });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{});
    defer response_file.close(std.testing.io);
    var reader_buffer: [2048]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
    const request_file = try tmp.dir.createFile(std.testing.io, "requests", .{});
    defer request_file.close(std.testing.io);
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
    defer deinitTestClientRegistries(&client);
    try attachDeleteTestState(&client, "delete-session");

    var failure = switch (try client.deleteSessionDetailed("delete-session")) {
        .success => return error.TestExpectedClientFailure,
        .failure => |failure_value| failure_value,
    };
    defer failure.deinit();
    try std.testing.expectEqual(error.CopilotClientError, failure.native_error);
    switch (failure.detail.client) {
        .operation_rejected => |rejected| {
            try std.testing.expectEqual(errors.SessionOperation.delete, rejected.operation);
            try std.testing.expectEqualStrings("delete refused", rejected.message.?);
        },
        else => return error.TestExpectedClientFailure,
    }
    try expectDeleteTestState(&client, "delete-session", true);
    try std.testing.expectEqualStrings(
        "interest-2",
        client.findExtensionRuntime("delete-session").?.mcp_oauth_interest_handle.?,
    );

    try writer.interface.flush();
    try expectRequestBodies(allocator, &tmp, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.eventLog.releaseInterest\",\"params\":{\"sessionId\":\"delete-session\",\"handle\":\"interest-1\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session.delete\",\"params\":{\"sessionId\":\"delete-session\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"session.eventLog.registerInterest\",\"params\":{\"sessionId\":\"delete-session\",\"eventType\":\"mcp.oauth_required\"}}",
    });
}

test "delete session transport failure removes state when restore also fails" {
    const allocator = std.testing.allocator;
    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(allocator);
    try appendTestFrame(
        allocator,
        &frames,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"success\":true}}",
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = frames.items });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{});
    defer response_file.close(std.testing.io);
    var reader_buffer: [2048]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
    const request_file = try tmp.dir.createFile(std.testing.io, "requests", .{});
    defer request_file.close(std.testing.io);
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
    defer deinitTestClientRegistries(&client);
    try attachDeleteTestState(&client, "delete-session");

    var failure = switch (try client.deleteSessionDetailed("delete-session")) {
        .success => return error.TestExpectedClientFailure,
        .failure => |failure_value| failure_value,
    };
    defer failure.deinit();
    try std.testing.expectEqual(error.EndOfStream, failure.native_error);
    switch (failure.detail.client) {
        .io => |io_failure| try std.testing.expectEqual(
            errors.ClientOperation.read,
            io_failure.operation,
        ),
        else => return error.TestExpectedClientFailure,
    }
    try expectDeleteTestState(&client, "delete-session", false);

    try writer.interface.flush();
    try expectRequestBodies(allocator, &tmp, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.eventLog.releaseInterest\",\"params\":{\"sessionId\":\"delete-session\",\"handle\":\"interest-1\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session.delete\",\"params\":{\"sessionId\":\"delete-session\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"session.eventLog.registerInterest\",\"params\":{\"sessionId\":\"delete-session\",\"eventType\":\"mcp.oauth_required\"}}",
    });
}

test "client administration and history use exact wire requests and owned results" {
    const allocator = std.testing.allocator;
    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(allocator);
    const responses = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"message\":\"pong-one\",\"timestamp\":\"2026-01-01T00:00:00Z\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"message\":\"pong-two\",\"timestamp\":\"2026-01-02T00:00:00Z\",\"protocolVersion\":9223372036854775808}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"version\":\"1.2.3\",\"protocolVersion\":3}}",
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{\"isAuthenticated\":true,\"authType\":\"future-auth\",\"host\":\"github.com\",\"login\":\"octocat\",\"statusMessage\":\"ready\",\"future\":true}}",
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{\"sessionId\":\"last-session\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"result\":{\"success\":true}}",
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"sessions\":[]}}",
        "{\"jsonrpc\":\"2.0\",\"id\":8,\"result\":{\"sessions\":[{\"sessionId\":\"catalog-session\",\"startTime\":\"start\",\"modifiedTime\":\"modified\",\"summary\":\"summary\",\"isRemote\":false,\"context\":{\"cwd\":\"/work\",\"gitRoot\":\"/work\",\"repository\":\"owner/repo\",\"branch\":\"main\"}}]}}",
        "{\"jsonrpc\":\"2.0\",\"id\":9,\"result\":{\"session\":{\"sessionId\":\"metadata-session\",\"startTime\":\"start-2\",\"modifiedTime\":\"modified-2\",\"isRemote\":true}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":10,\"result\":{\"sessionId\":\"foreground-session\",\"workspacePath\":\"/ignored\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":11,\"result\":{\"success\":true}}",
        "{\"jsonrpc\":\"2.0\",\"id\":12,\"result\":{\"events\":[{\"type\":\"assistant.message\",\"data\":{\"content\":\"history\",\"messageId\":\"m1\"}},{\"type\":\"future.event\",\"data\":{\"newField\":true}}]}}",
        "{\"jsonrpc\":\"2.0\",\"id\":13,\"result\":{\"version\":\"2.0.0\",\"protocolVersion\":4}}",
        "{\"jsonrpc\":\"2.0\",\"id\":14,\"result\":{\"isAuthenticated\":false}}",
        "{\"jsonrpc\":\"2.0\",\"id\":15,\"result\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":16,\"result\":{\"success\":true}}",
        "{\"jsonrpc\":\"2.0\",\"id\":17,\"result\":{\"sessions\":[]}}",
        "{\"jsonrpc\":\"2.0\",\"id\":18,\"result\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":19,\"result\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":20,\"result\":{\"success\":true}}",
        "{\"jsonrpc\":\"2.0\",\"id\":21,\"result\":{\"events\":[]}}",
    };
    for (responses) |body| try appendTestFrame(allocator, &frames, body);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = frames.items });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{});
    defer response_file.close(std.testing.io);
    var reader_buffer: [8192]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
    const request_file = try tmp.dir.createFile(std.testing.io, "requests", .{});
    defer request_file.close(std.testing.io);
    var writer_buffer: [8192]u8 = undefined;
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
    defer deinitTestClientRegistries(&client);

    var first_ping = try client.ping(null);
    defer first_ping.deinit();
    try std.testing.expectEqualStrings("pong-one", first_ping.message);
    try std.testing.expect(first_ping.protocol_version == null);

    var second_ping = switch (try client.pingDetailed("hello")) {
        .success => |value| value,
        .failure => |failure_value| {
            var failure = failure_value;
            defer failure.deinit();
            return error.TestUnexpectedFailure;
        },
    };
    defer second_ping.deinit();
    try std.testing.expectEqual(@as(?u64, 9_223_372_036_854_775_808), second_ping.protocol_version);

    var status = try client.getStatus();
    defer status.deinit();
    try std.testing.expectEqualStrings("1.2.3", status.version);

    var auth = try client.getAuthStatus();
    defer auth.deinit();
    try std.testing.expectEqualStrings("future-auth", auth.auth_type.?);
    try std.testing.expectEqualStrings("octocat", auth.login.?);

    var last_id = (try client.getLastSessionId()).?;
    defer last_id.deinit();
    try std.testing.expectEqualStrings("last-session", last_id.value);

    try client.deleteSession("delete-session");

    var empty_catalog = try client.listSessions(null);
    defer empty_catalog.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty_catalog.sessions.len);

    var catalog = try client.listSessions(.{
        .cwd = "/work",
        .git_root = "/work",
        .repository = "owner/repo",
        .branch = "main",
    });
    defer catalog.deinit();
    try std.testing.expectEqualStrings("catalog-session", catalog.sessions[0].session_id);
    try std.testing.expectEqualStrings("owner/repo", catalog.sessions[0].context.?.repository.?);

    var metadata = (try client.getSessionMetadata("metadata-session")).?;
    defer metadata.deinit();
    try std.testing.expectEqualStrings("modified-2", metadata.modified_time);
    try std.testing.expect(metadata.context == null);

    var foreground = (try client.getForegroundSessionId()).?;
    defer foreground.deinit();
    try std.testing.expectEqualStrings("foreground-session", foreground.value);

    try client.setForegroundSessionId("new-foreground");

    var history = try (Session{ .client = &client, .id = "history-session" }).getEvents();
    defer history.deinit();
    try std.testing.expectEqual(@as(usize, 2), history.events.len);
    try std.testing.expectEqualStrings("history", history.events[0].assistant_message.content);
    try std.testing.expectEqualStrings("future.event", history.events[1].unknown.event_type);

    var detailed_status = switch (try client.getStatusDetailed()) {
        .success => |value| value,
        .failure => |failure_value| {
            var failure = failure_value;
            defer failure.deinit();
            return error.TestUnexpectedFailure;
        },
    };
    defer detailed_status.deinit();
    var detailed_auth = switch (try client.getAuthStatusDetailed()) {
        .success => |value| value,
        .failure => |failure_value| {
            var failure = failure_value;
            defer failure.deinit();
            return error.TestUnexpectedFailure;
        },
    };
    defer detailed_auth.deinit();
    try std.testing.expect(!detailed_auth.is_authenticated);
    try std.testing.expect(detailed_auth.auth_type == null);
    const detailed_last = switch (try client.getLastSessionIdDetailed()) {
        .success => |value| value,
        .failure => |failure_value| {
            var failure = failure_value;
            defer failure.deinit();
            return error.TestUnexpectedFailure;
        },
    };
    try std.testing.expect(detailed_last == null);
    switch (try client.deleteSessionDetailed("delete-detailed")) {
        .success => {},
        .failure => |failure_value| {
            var failure = failure_value;
            defer failure.deinit();
            return error.TestUnexpectedFailure;
        },
    }
    var detailed_catalog = switch (try client.listSessionsDetailed(.{
        .repository = "owner/repo",
    })) {
        .success => |value| value,
        .failure => |failure_value| {
            var failure = failure_value;
            defer failure.deinit();
            return error.TestUnexpectedFailure;
        },
    };
    defer detailed_catalog.deinit();
    const detailed_metadata = switch (try client.getSessionMetadataDetailed("missing")) {
        .success => |value| value,
        .failure => |failure_value| {
            var failure = failure_value;
            defer failure.deinit();
            return error.TestUnexpectedFailure;
        },
    };
    try std.testing.expect(detailed_metadata == null);
    const detailed_foreground = switch (try client.getForegroundSessionIdDetailed()) {
        .success => |value| value,
        .failure => |failure_value| {
            var failure = failure_value;
            defer failure.deinit();
            return error.TestUnexpectedFailure;
        },
    };
    try std.testing.expect(detailed_foreground == null);
    switch (try client.setForegroundSessionIdDetailed("foreground-detailed")) {
        .success => {},
        .failure => |failure_value| {
            var failure = failure_value;
            defer failure.deinit();
            return error.TestUnexpectedFailure;
        },
    }
    var detailed_history = switch (try (Session{
        .client = &client,
        .id = "history-detailed",
    }).getEventsDetailed()) {
        .success => |value| value,
        .failure => |failure_value| {
            var failure = failure_value;
            defer failure.deinit();
            return error.TestUnexpectedFailure;
        },
    };
    defer detailed_history.deinit();

    try writer.interface.flush();
    const written = try tmp.dir.readFileAlloc(
        std.testing.io,
        "requests",
        allocator,
        .limited(32 * 1024),
    );
    defer allocator.free(written);
    var request_reader = std.Io.Reader.fixed(written);
    const expected = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\",\"params\":{\"message\":\"hello\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"status.get\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"auth.getStatus\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"session.getLastId\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"session.delete\",\"params\":{\"sessionId\":\"delete-session\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"session.list\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"session.list\",\"params\":{\"filter\":{\"cwd\":\"/work\",\"gitRoot\":\"/work\",\"repository\":\"owner/repo\",\"branch\":\"main\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"session.getMetadata\",\"params\":{\"sessionId\":\"metadata-session\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"session.getForeground\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"session.setForeground\",\"params\":{\"sessionId\":\"new-foreground\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"session.getMessages\",\"params\":{\"sessionId\":\"history-session\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"status.get\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"auth.getStatus\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"session.getLastId\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":16,\"method\":\"session.delete\",\"params\":{\"sessionId\":\"delete-detailed\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":17,\"method\":\"session.list\",\"params\":{\"filter\":{\"repository\":\"owner/repo\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":18,\"method\":\"session.getMetadata\",\"params\":{\"sessionId\":\"missing\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":19,\"method\":\"session.getForeground\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":20,\"method\":\"session.setForeground\",\"params\":{\"sessionId\":\"foreground-detailed\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"session.getMessages\",\"params\":{\"sessionId\":\"history-detailed\"}}",
    };
    for (expected) |expected_body| {
        const actual = try json_rpc.readFrame(allocator, &request_reader);
        defer allocator.free(actual);
        try std.testing.expectEqualStrings(expected_body, actual);
    }
    try std.testing.expectEqualStrings("", request_reader.buffered());
}

test "session operation rejection is owned and legacy methods collapse it" {
    std.debug.print("\nCENSUS_PROBE client_operation_rejection\n", .{});
    const allocator = std.testing.allocator;
    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(allocator);
    try appendTestFrame(
        allocator,
        &frames,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"success\":false,\"error\":\"delete refused\"}}",
    );
    try appendTestFrame(
        allocator,
        &frames,
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"success\":false,\"error\":\"foreground refused\"}}",
    );
    try appendTestFrame(
        allocator,
        &frames,
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"success\":false}}",
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = frames.items });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{});
    defer response_file.close(std.testing.io);
    var reader_buffer: [2048]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
    const request_file = try tmp.dir.createFile(std.testing.io, "requests", .{});
    defer request_file.close(std.testing.io);
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

    var delete_failure = switch (try client.deleteSessionDetailed("delete-me")) {
        .success => return error.TestExpectedClientFailure,
        .failure => |failure| failure,
    };
    defer delete_failure.deinit();
    try std.testing.expectEqual(error.CopilotClientError, delete_failure.native_error);
    try std.testing.expectEqual(error.ClientFailure, delete_failure.errorTag());
    switch (delete_failure.detail.client) {
        .operation_rejected => |rejected| {
            try std.testing.expectEqual(errors.SessionOperation.delete, rejected.operation);
            try std.testing.expectEqualStrings("delete-me", rejected.session_id);
            try std.testing.expectEqualStrings("delete refused", rejected.message.?);
        },
        else => return error.TestExpectedClientFailure,
    }

    var foreground_failure = switch (try client.setForegroundSessionIdDetailed("foreground-me")) {
        .success => return error.TestExpectedClientFailure,
        .failure => |failure| failure,
    };
    defer foreground_failure.deinit();
    switch (foreground_failure.detail.client) {
        .operation_rejected => |rejected| {
            try std.testing.expectEqual(errors.SessionOperation.set_foreground, rejected.operation);
            try std.testing.expectEqualStrings("foreground-me", rejected.session_id);
            try std.testing.expectEqualStrings("foreground refused", rejected.message.?);
        },
        else => return error.TestExpectedClientFailure,
    }

    try std.testing.expectError(error.CopilotClientError, client.deleteSession("legacy"));
}

test "all three read loops share lifecycle and session event routing" {
    const allocator = std.testing.allocator;
    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(allocator);
    const messages = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"method\":\"session.lifecycle\",\"params\":{\"type\":\"session.created\",\"sessionId\":\"created-session\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"message\":\"ok\",\"timestamp\":\"now\"}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"session.lifecycle\",\"params\":{\"type\":\"session.updated\",\"sessionId\":\"updated-session\",\"metadata\":null}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"session.event\",\"params\":{\"sessionId\":\"event-session\",\"event\":{\"type\":\"session.idle\",\"data\":{}}}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"session.event\",\"params\":{\"sessionId\":\"event-session\",\"event\":{\"type\":\"assistant.message\",\"data\":{\"content\":\"queued\",\"messageId\":\"m2\"}}}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"session.lifecycle\",\"params\":{\"type\":\"future.lifecycle\",\"sessionId\":\"future-session\",\"metadata\":{\"startTime\":\"start\",\"modifiedTime\":\"modified\",\"summary\":\"future\"},\"additive\":true}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"session.lifecycle\",\"params\":{\"type\":\"session.deleted\",\"sessionId\":\"deleted-session\"}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"session.lifecycle\",\"params\":{\"type\":\"session.foreground\",\"sessionId\":\"foreground-session\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"events\":[{\"type\":\"assistant.message\",\"data\":{\"content\":\"queued\",\"messageId\":\"m2\"}}]}}",
    };
    for (messages) |body| try appendTestFrame(allocator, &frames, body);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = frames.items });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{});
    defer response_file.close(std.testing.io);
    var reader_buffer: [4096]u8 = undefined;
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
    defer deinitTestClientRegistries(&client);

    var ping_result = try client.ping(null);
    defer ping_result.deinit();
    var from_call = try client.nextLifecycleEvent();
    defer from_call.deinit();
    try std.testing.expect(from_call.event.event_type == .created);
    try std.testing.expectEqualStrings("created-session", from_call.event.session_id);

    const session = Session{ .client = &client, .id = "event-session" };
    var idle = try session.nextEvent();
    defer idle.deinit(allocator);
    try std.testing.expect(idle == .session_idle);
    var from_session = try client.nextLifecycleEvent();
    defer from_session.deinit();
    try std.testing.expect(from_session.event.event_type == .updated);

    var from_lifecycle = try client.nextLifecycleEvent();
    defer from_lifecycle.deinit();
    try std.testing.expect(from_lifecycle.event.event_type == .unknown);
    try std.testing.expectEqualStrings(
        "future.lifecycle",
        from_lifecycle.event.event_type.unknown,
    );
    try std.testing.expectEqualStrings(
        "modified",
        from_lifecycle.event.metadata.?.modified_time,
    );

    var deleted = try client.nextLifecycleEvent();
    defer deleted.deinit();
    try std.testing.expect(deleted.event.event_type == .deleted);
    var foreground = try client.nextLifecycleEvent();
    defer foreground.deinit();
    try std.testing.expect(foreground.event.event_type == .foreground);

    var queued = try session.nextEvent();
    defer queued.deinit(allocator);
    try std.testing.expectEqualStrings("queued", queued.assistant_message.content);

    var history = try session.getEvents();
    defer history.deinit();
    try std.testing.expectEqual(std.meta.activeTag(queued), std.meta.activeTag(history.events[0]));
    try std.testing.expectEqualStrings(
        queued.assistant_message.content,
        history.events[0].assistant_message.content,
    );
}

test "lifecycle overflow through an RPC preserves prefix marker and next epoch" {
    const allocator = std.testing.allocator;
    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(allocator);
    for (0..admin.lifecycle_queue_capacity + 2) |index| {
        const body = try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"session.lifecycle\",\"params\":{{\"type\":\"session.created\",\"sessionId\":\"s-{d}\"}}}}",
            .{index},
        );
        defer allocator.free(body);
        try appendTestFrame(allocator, &frames, body);
    }
    try appendTestFrame(
        allocator,
        &frames,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"message\":\"ok\",\"timestamp\":\"now\"}}",
    );
    try appendTestFrame(
        allocator,
        &frames,
        "{\"jsonrpc\":\"2.0\",\"method\":\"session.lifecycle\",\"params\":{\"type\":\"session.background\",\"sessionId\":\"next-epoch\"}}",
    );
    try appendTestFrame(
        allocator,
        &frames,
        "{\"jsonrpc\":\"2.0\",\"method\":\"session.lifecycle\",\"params\":{\"type\":\"session.created\",\"sessionId\":\"saturated-drop\"}}",
    );
    try appendTestFrame(
        allocator,
        &frames,
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"message\":\"again\",\"timestamp\":\"later\"}}",
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = frames.items });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{});
    defer response_file.close(std.testing.io);
    var reader_buffer: [8192]u8 = undefined;
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
    defer deinitTestClientRegistries(&client);

    var pong = try client.ping(null);
    defer pong.deinit();
    for (0..admin.lifecycle_queue_capacity) |index| {
        var delivery = try client.nextLifecycleEvent();
        defer delivery.deinit();
        const expected = try std.fmt.allocPrint(allocator, "s-{d}", .{index});
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, delivery.event.session_id);
    }
    const overflow = try client.nextLifecycleEvent();
    try std.testing.expectEqual(@as(usize, 2), overflow.overflow.dropped_count);
    var next = try client.nextLifecycleEvent();
    defer next.deinit();
    try std.testing.expectEqualStrings("next-epoch", next.event.session_id);

    client.lifecycle_events.dropped_count = std.math.maxInt(usize);
    var second_pong = try client.ping(null);
    defer second_pong.deinit();
    const saturated = try client.nextLifecycleEvent();
    try std.testing.expectEqual(
        std.math.maxInt(usize),
        saturated.overflow.dropped_count,
    );
}

test "lifecycle malformed payload and saturated loss retain detailed classification" {
    const allocator = std.testing.allocator;
    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(allocator);
    try appendTestFrame(
        allocator,
        &frames,
        "{\"jsonrpc\":\"2.0\",\"method\":\"session.lifecycle\",\"params\":{\"type\":\"session.created\",\"sessionId\":7}}",
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = frames.items });
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
    defer deinitTestClientRegistries(&client);

    var failure = switch (try client.nextLifecycleEventDetailed()) {
        .success => |delivery_value| {
            var delivery = delivery_value;
            delivery.deinit();
            return error.TestExpectedProtocolFailure;
        },
        .failure => |failure_value| failure_value,
    };
    defer failure.deinit();
    try std.testing.expectEqual(error.InvalidSessionEvent, failure.native_error);
    switch (failure.detail) {
        .protocol => |protocol_failure| switch (protocol_failure) {
            .invalid_envelope => |invalid| try std.testing.expectEqual(
                errors.EnvelopeViolation.malformed_field_type,
                invalid.reason,
            ),
            else => return error.TestExpectedProtocolFailure,
        },
        else => return error.TestExpectedProtocolFailure,
    }
}

test "getEvents cleans a parsed prefix and classifies malformed history" {
    const allocator = std.testing.allocator;
    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(allocator);
    try appendTestFrame(
        allocator,
        &frames,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"events\":[{\"type\":\"assistant.message\",\"data\":{\"content\":\"valid\",\"messageId\":\"m1\"}},{\"type\":\"assistant.message\",\"data\":{\"content\":7}}]}}",
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = frames.items });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{});
    defer response_file.close(std.testing.io);
    var reader_buffer: [2048]u8 = undefined;
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
    defer deinitTestClientRegistries(&client);

    var failure = switch (try (Session{
        .client = &client,
        .id = "history-session",
    }).getEventsDetailed()) {
        .success => |history_value| {
            var history = history_value;
            history.deinit();
            return error.TestExpectedProtocolFailure;
        },
        .failure => |failure_value| failure_value,
    };
    defer failure.deinit();
    try std.testing.expectEqual(error.InvalidSessionEvent, failure.native_error);
    switch (failure.detail) {
        .protocol => |protocol_failure| switch (protocol_failure) {
            .invalid_envelope => |invalid| try std.testing.expectEqual(
                errors.EnvelopeViolation.malformed_field_type,
                invalid.reason,
            ),
            else => return error.TestExpectedProtocolFailure,
        },
        else => return error.TestExpectedProtocolFailure,
    }
}

test "Client.deinit releases queued lifecycle ownership" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const input_file = try tmp.dir.createFile(std.testing.io, "input", .{ .read = true });
    defer input_file.close(std.testing.io);
    const output_file = try tmp.dir.createFile(std.testing.io, "output", .{});
    defer output_file.close(std.testing.io);
    const reader_buffer = try allocator.alloc(u8, 64);
    const writer_buffer = try allocator.alloc(u8, 64);
    const reader = try allocator.create(std.Io.File.Reader);
    const writer = try allocator.create(std.Io.File.Writer);
    reader.* = input_file.readerStreaming(std.testing.io, reader_buffer);
    writer.* = output_file.writer(std.testing.io, writer_buffer);
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = reader,
        .writer = writer,
        .reader_buffer = reader_buffer,
        .writer_buffer = writer_buffer,
    };
    client.lifecycle_events.push(.{
        .allocator = allocator,
        .event_type = .{ .unknown = try allocator.dupe(u8, "future") },
        .session_id = try allocator.dupe(u8, "session"),
        .metadata = .{
            .allocator = allocator,
            .start_time = try allocator.dupe(u8, "start"),
            .modified_time = try allocator.dupe(u8, "modified"),
            .summary = try allocator.dupe(u8, "summary"),
        },
    });
    client.deinit();
}
