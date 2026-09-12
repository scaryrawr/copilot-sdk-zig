const std = @import("std");
const errors = @import("errors.zig");
const json_rpc = @import("json_rpc.zig");
const models = @import("models.zig");
const provider = @import("provider.zig");
const protocol = @import("protocol_version.zig");
const session_types = @import("session.zig");

const max_queued_events: usize = 1024;

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

fn beginCapture(capture: ?*errors.ErrorCapture) !void {
    if (capture) |value| try value.ensureEmpty();
}

fn ownedCause(code: anyerror) errors.Cause {
    return .{ .code = code };
}

fn recordFailure(
    capture: ?*errors.ErrorCapture,
    tag: errors.SdkError,
    detail: errors.FailureDetail,
) !noreturn {
    const target = capture orelse return tag;
    return target.recordOwned(.{
        .allocator = target.allocator,
        .detail = detail,
    });
}

fn recordClientIo(
    capture: ?*errors.ErrorCapture,
    operation: errors.ClientOperation,
    cause: anyerror,
) !noreturn {
    const target = capture orelse return error.ClientFailure;
    const message = try target.allocator.dupe(u8, @errorName(cause));
    return try recordFailure(capture, error.ClientFailure, .{ .client = .{ .io = .{
        .operation = operation,
        .message = message,
        .cause = ownedCause(cause),
    } } });
}

fn recordClientJson(
    capture: ?*errors.ErrorCapture,
    operation: errors.ClientOperation,
    cause: anyerror,
) !noreturn {
    const target = capture orelse return error.ClientFailure;
    const message = try target.allocator.dupe(u8, @errorName(cause));
    return try recordFailure(capture, error.ClientFailure, .{ .client = .{ .json = .{
        .operation = operation,
        .message = message,
        .cause = ownedCause(cause),
    } } });
}

fn recordProcessSpawn(
    capture: ?*errors.ErrorCapture,
    executable: []const u8,
    cause: anyerror,
) !noreturn {
    const target = capture orelse return error.ClientFailure;
    const owned_executable = try target.allocator.dupe(u8, executable);
    var executable_transferred = false;
    defer if (!executable_transferred) target.allocator.free(owned_executable);
    const message = try target.allocator.dupe(u8, @errorName(cause));
    var message_transferred = false;
    defer if (!message_transferred) target.allocator.free(message);
    executable_transferred = true;
    message_transferred = true;
    return try recordFailure(capture, error.ClientFailure, .{ .process = .{ .spawn = .{
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
    capture: ?*errors.ErrorCapture,
    exit: errors.ProcessExit,
) !noreturn {
    const target = capture orelse return error.ProcessExited;
    const message = try std.fmt.allocPrint(
        target.allocator,
        "Copilot CLI process terminated ({s})",
        .{@tagName(exit)},
    );
    return try recordFailure(capture, error.ProcessExited, .{ .process = .{ .exited = .{
        .exit = exit,
        .message = message,
    } } });
}

fn recordReentrant(
    capture: ?*errors.ErrorCapture,
    method: []const u8,
) !noreturn {
    const target = capture orelse return error.ClientFailure;
    const owned_method = try target.allocator.dupe(u8, method);
    var method_transferred = false;
    defer if (!method_transferred) target.allocator.free(owned_method);
    const message = try target.allocator.dupe(u8, "RPC calls cannot be nested from an RPC handler");
    var message_transferred = false;
    defer if (!message_transferred) target.allocator.free(message);
    method_transferred = true;
    message_transferred = true;
    return try recordFailure(capture, error.ClientFailure, .{ .client = .{ .reentrant_call = .{
        .method = owned_method,
        .message = message,
    } } });
}

fn recordConnectRejected(capture: ?*errors.ErrorCapture) !noreturn {
    const target = capture orelse return error.ClientFailure;
    const message = try target.allocator.dupe(u8, "Copilot CLI rejected the connection");
    return try recordFailure(capture, error.ClientFailure, .{ .client = .{
        .invalid_config = .{
            .field = null,
            .message = message,
        },
    } });
}

fn recordInvalidConfig(
    capture: ?*errors.ErrorCapture,
    field: []const u8,
    cause: anyerror,
) !noreturn {
    if (cause == error.OutOfMemory) return cause;
    const target = capture orelse return error.ClientFailure;
    const owned_field = try target.allocator.dupe(u8, field);
    const message = target.allocator.dupe(u8, @errorName(cause)) catch |err| {
        target.allocator.free(owned_field);
        return err;
    };
    return try recordFailure(capture, error.ClientFailure, .{ .client = .{
        .invalid_config = .{
            .field = owned_field,
            .message = message,
        },
    } });
}

fn recordFrameFailure(
    capture: ?*errors.ErrorCapture,
    cause: anyerror,
) !noreturn {
    const detail: errors.ProtocolFailure = switch (cause) {
        error.MissingContentLength => .missing_content_length,
        error.FrameTooLarge => .{ .frame_too_large = .{
            .declared = 16 * 1024 * 1024 + 1,
            .maximum = 16 * 1024 * 1024,
        } },
        error.TruncatedFrame => .{ .truncated_frame = .{
            .declared = 0,
            .received = 0,
        } },
        error.InvalidCharacter, error.Overflow => blk: {
            const target = capture orelse return error.ProtocolFailure;
            break :blk .{ .invalid_content_length = .{
                .value = try target.allocator.dupe(u8, ""),
            } };
        },
        else => return try recordClientIo(capture, .read, cause),
    };
    return try recordFailure(capture, error.ProtocolFailure, .{ .protocol = detail });
}

fn recordInvalidJson(
    capture: ?*errors.ErrorCapture,
    cause: anyerror,
) !noreturn {
    const target = capture orelse return error.ProtocolFailure;
    const message = try target.allocator.dupe(u8, @errorName(cause));
    return try recordFailure(capture, error.ProtocolFailure, .{ .protocol = .{ .invalid_json = .{
        .message = message,
        .cause = ownedCause(cause),
    } } });
}

fn recordEnvelope(
    capture: ?*errors.ErrorCapture,
    reason: errors.EnvelopeViolation,
    body: []const u8,
) !noreturn {
    const target = capture orelse return error.ProtocolFailure;
    const json = try target.allocator.dupe(u8, body);
    return try recordFailure(capture, error.ProtocolFailure, .{ .protocol = .{
        .invalid_envelope = .{
            .reason = reason,
            .message_json = json,
        },
    } });
}

fn recordUnexpectedResponse(
    capture: ?*errors.ErrorCapture,
    expected_id: u64,
    actual_id: std.json.Value,
) !noreturn {
    const target = capture orelse return error.ProtocolFailure;
    const json = try std.json.Stringify.valueAlloc(target.allocator, actual_id, .{});
    return try recordFailure(capture, error.ProtocolFailure, .{ .protocol = .{
        .unexpected_response = .{
            .expected_id = expected_id,
            .actual_id_json = json,
        },
    } });
}

fn recordInvalidEvent(
    capture: ?*errors.ErrorCapture,
    value: std.json.Value,
) !noreturn {
    const target = capture orelse return error.ProtocolFailure;
    const json = try std.json.Stringify.valueAlloc(target.allocator, value, .{});
    return try recordFailure(capture, error.ProtocolFailure, .{ .protocol = .{
        .invalid_envelope = .{
            .reason = .missing_params,
            .message_json = json,
        },
    } });
}

fn parseInboundMessage(
    capture: ?*errors.ErrorCapture,
    body: []const u8,
    value: std.json.Value,
) !InboundMessage {
    const object = switch (value) {
        .object => |object| object,
        else => return try recordEnvelope(capture, .non_object, body),
    };
    const version = object.get("jsonrpc") orelse
        return try recordEnvelope(capture, .invalid_jsonrpc_version, body);
    if (version != .string or !std.mem.eql(u8, version.string, "2.0"))
        return try recordEnvelope(capture, .invalid_jsonrpc_version, body);

    if (object.get("method")) |method_value| {
        const method = switch (method_value) {
            .string => |name| name,
            else => return try recordEnvelope(capture, .invalid_method, body),
        };
        const params = object.get("params");
        if (object.get("id")) |id| {
            return .{ .request = .{
                .id = id,
                .method = method,
                .params = params,
            } };
        }
        return .{ .notification = .{
            .method = method,
            .params = params,
        } };
    }

    const id_value = object.get("id") orelse
        return try recordEnvelope(capture, .missing_id, body);
    const id = switch (id_value) {
        .integer => |number| std.math.cast(u64, number) orelse
            return try recordEnvelope(capture, .invalid_id, body),
        else => return try recordEnvelope(capture, .invalid_id, body),
    };
    const result = object.get("result");
    const rpc_error = object.get("error");
    if (result != null and rpc_error != null)
        return try recordEnvelope(capture, .result_and_error, body);
    if (result == null and rpc_error == null)
        return try recordEnvelope(capture, .missing_result_and_error, body);
    return .{ .response = .{
        .id = id,
        .id_value = id_value,
        .result = result,
        .rpc_error = rpc_error,
    } };
}

fn recordProtocolMismatch(
    capture: ?*errors.ErrorCapture,
    server: u64,
) !noreturn {
    return try recordFailure(capture, error.ProtocolMismatch, .{ .protocol = .{ .mismatch = .{
        .unsupported = .{
            .server = server,
            .minimum = protocol.sdk_protocol_version,
            .maximum = protocol.sdk_protocol_version,
        },
    } } });
}

fn recordInvalidProtocolVersion(
    capture: ?*errors.ErrorCapture,
    server: std.json.Value,
) !noreturn {
    const target = capture orelse return error.ProtocolMismatch;
    const server_json = try std.json.Stringify.valueAlloc(target.allocator, server, .{});
    return try recordFailure(capture, error.ProtocolMismatch, .{ .protocol = .{
        .mismatch = .{ .invalid_server_version = .{
            .server_json = server_json,
        } },
    } });
}

fn recordQueueFull(
    capture: ?*errors.ErrorCapture,
    session_id: ?[]const u8,
    event_type: ?[]const u8,
    length: usize,
) !noreturn {
    const target = capture orelse return error.QueueFailure;
    var transferred = false;
    const owned_session_id = if (session_id) |value|
        try target.allocator.dupe(u8, value)
    else
        null;
    defer if (!transferred) {
        if (owned_session_id) |value| target.allocator.free(value);
    };
    const owned_event_type = if (event_type) |value|
        try target.allocator.dupe(u8, value)
    else
        null;
    defer if (!transferred) {
        if (owned_event_type) |value| target.allocator.free(value);
    };
    transferred = true;
    return try recordFailure(capture, error.QueueFailure, .{ .queue = .{ .full = .{
        .session_id = owned_session_id,
        .event_type = owned_event_type,
        .length = length,
        .capacity = max_queued_events,
    } } });
}

fn recordSessionAgentFailure(
    capture: ?*errors.ErrorCapture,
    session_id: []const u8,
    event: session_types.SessionError,
) !noreturn {
    const target = capture orelse return error.SessionFailure;
    var transferred = false;
    const owned_session_id = try target.allocator.dupe(u8, session_id);
    defer if (!transferred) target.allocator.free(owned_session_id);
    const error_type = try target.allocator.dupe(u8, event.error_type);
    defer if (!transferred) target.allocator.free(error_type);
    const error_code = try dupeOptional(target.allocator, event.error_code);
    defer if (!transferred) {
        if (error_code) |value| target.allocator.free(value);
    };
    const message = try target.allocator.dupe(u8, event.message);
    defer if (!transferred) target.allocator.free(message);
    const provider_call_id = try dupeOptional(target.allocator, event.provider_call_id);
    defer if (!transferred) {
        if (provider_call_id) |value| target.allocator.free(value);
    };
    const service_request_id = try dupeOptional(target.allocator, event.service_request_id);
    defer if (!transferred) {
        if (service_request_id) |value| target.allocator.free(value);
    };
    const remediation_json = try dupeOptional(target.allocator, event.remediation_json);
    defer if (!transferred) {
        if (remediation_json) |value| target.allocator.free(value);
    };
    const url = try dupeOptional(target.allocator, event.url);
    defer if (!transferred) {
        if (url) |value| target.allocator.free(value);
    };
    const stack = try dupeOptional(target.allocator, event.stack);
    defer if (!transferred) {
        if (stack) |value| target.allocator.free(value);
    };
    transferred = true;
    return try recordFailure(capture, error.SessionFailure, .{ .session = .{ .agent = .{
        .session_id = owned_session_id,
        .error_type = error_type,
        .error_code = error_code,
        .message = message,
        .status_code = event.status_code,
        .provider_call_id = provider_call_id,
        .service_request_id = service_request_id,
        .remediation_json = remediation_json,
        .url = url,
        .stack = stack,
        .eligible_for_auto_switch = event.eligible_for_auto_switch,
    } } });
}

fn recordDetachFailure(
    capture: ?*errors.ErrorCapture,
    session_id: []const u8,
    attempts: usize,
) !noreturn {
    const target = capture orelse return error.SessionFailure;
    var transferred = false;
    const owned_session_id = try target.allocator.dupe(u8, session_id);
    defer if (!transferred) target.allocator.free(owned_session_id);
    const message = try target.allocator.dupe(u8, "session detach was not accepted");
    defer if (!transferred) target.allocator.free(message);
    transferred = true;
    return try recordFailure(capture, error.SessionFailure, .{ .session = .{ .detach_failed = .{
        .session_id = owned_session_id,
        .attempts = attempts,
        .rpc = null,
        .message = message,
    } } });
}

fn recordPermissionNotAccepted(
    capture: ?*errors.ErrorCapture,
    session_id: []const u8,
    request_id: []const u8,
) !noreturn {
    const target = capture orelse return error.PermissionFailure;
    var transferred = false;
    const owned_session_id = try target.allocator.dupe(u8, session_id);
    defer if (!transferred) target.allocator.free(owned_session_id);
    const owned_request_id = try target.allocator.dupe(u8, request_id);
    defer if (!transferred) target.allocator.free(owned_request_id);
    const message = try target.allocator.dupe(u8, "permission decision was not accepted");
    defer if (!transferred) target.allocator.free(message);
    transferred = true;
    return try recordFailure(capture, error.PermissionFailure, .{ .permission = .{
        .not_accepted = .{
            .session_id = owned_session_id,
            .request_id = owned_request_id,
            .message = message,
        },
    } });
}

fn recordInvalidPermission(
    capture: ?*errors.ErrorCapture,
    session_id: []const u8,
    request_id: []const u8,
    cause: anyerror,
) !noreturn {
    const target = capture orelse return error.PermissionFailure;
    var transferred = false;
    const owned_session_id = try target.allocator.dupe(u8, session_id);
    defer if (!transferred) target.allocator.free(owned_session_id);
    const owned_request_id = try target.allocator.dupe(u8, request_id);
    defer if (!transferred) target.allocator.free(owned_request_id);
    const message = try target.allocator.dupe(u8, @errorName(cause));
    defer if (!transferred) target.allocator.free(message);
    transferred = true;
    return try recordFailure(capture, error.PermissionFailure, .{ .permission = .{
        .invalid_decision = .{
            .session_id = owned_session_id,
            .request_id = owned_request_id,
            .message = message,
            .cause = .{ .code = cause },
        },
    } });
}

fn recordToolNotAccepted(
    capture: ?*errors.ErrorCapture,
    session_id: []const u8,
    request_id: []const u8,
) !noreturn {
    const target = capture orelse return error.ToolFailure;
    var transferred = false;
    const owned_session_id = try target.allocator.dupe(u8, session_id);
    defer if (!transferred) target.allocator.free(owned_session_id);
    const owned_request_id = try target.allocator.dupe(u8, request_id);
    defer if (!transferred) target.allocator.free(owned_request_id);
    const message = try target.allocator.dupe(u8, "tool result was not accepted");
    defer if (!transferred) target.allocator.free(message);
    transferred = true;
    return try recordFailure(capture, error.ToolFailure, .{ .tool = .{ .not_accepted = .{
        .session_id = owned_session_id,
        .request_id = owned_request_id,
        .tool_call_id = null,
        .message = message,
    } } });
}

fn recordInvalidToolResult(
    capture: ?*errors.ErrorCapture,
    session_id: []const u8,
    request_id: []const u8,
    cause: anyerror,
) !noreturn {
    const target = capture orelse return error.ToolFailure;
    var transferred = false;
    const owned_session_id = try target.allocator.dupe(u8, session_id);
    defer if (!transferred) target.allocator.free(owned_session_id);
    const owned_request_id = try target.allocator.dupe(u8, request_id);
    defer if (!transferred) target.allocator.free(owned_request_id);
    const message = try target.allocator.dupe(u8, @errorName(cause));
    defer if (!transferred) target.allocator.free(message);
    transferred = true;
    return try recordFailure(capture, error.ToolFailure, .{ .tool = .{ .invalid_result = .{
        .session_id = owned_session_id,
        .request_id = owned_request_id,
        .tool_call_id = null,
        .tool_name = null,
        .message = message,
        .cause = .{ .code = cause },
    } } });
}

fn dupeOptional(
    allocator: std.mem.Allocator,
    value: ?[]const u8,
) !?[]u8 {
    return if (value) |slice| try allocator.dupe(u8, slice) else null;
}

fn attachToolContext(
    failure: *errors.Failure,
    tool_call_id: []const u8,
    tool_name: []const u8,
) !void {
    switch (failure.detail) {
        .tool => |*tool_failure| switch (tool_failure.*) {
            .delivery_failed => |*delivery| {
                if (delivery.tool_call_id == null) {
                    delivery.tool_call_id = try failure.allocator.dupe(u8, tool_call_id);
                }
                if (delivery.tool_name == null) {
                    delivery.tool_name = failure.allocator.dupe(u8, tool_name) catch |err| {
                        if (delivery.tool_call_id) |value| failure.allocator.free(value);
                        delivery.tool_call_id = null;
                        return err;
                    };
                }
            },
            else => {},
        },
        else => {},
    }
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

fn ownRpcFailure(
    allocator: std.mem.Allocator,
    method: []const u8,
    request_id: u64,
    code: i64,
    machine_code: ?[]const u8,
    message: []const u8,
    data: ?std.json.Value,
) !errors.RpcFailure {
    const owned_method = try allocator.dupe(u8, method);
    errdefer allocator.free(owned_method);
    const owned_machine_code = if (machine_code) |value|
        try allocator.dupe(u8, value)
    else
        null;
    errdefer if (owned_machine_code) |value| allocator.free(value);
    const owned_message = try allocator.dupe(u8, message);
    errdefer allocator.free(owned_message);
    const data_json = if (data) |value|
        try std.json.Stringify.valueAlloc(allocator, value, .{})
    else
        null;
    return .{
        .method = owned_method,
        .request_id = request_id,
        .code = code,
        .machine_code = owned_machine_code,
        .message = owned_message,
        .data_json = data_json,
    };
}

const RpcContext = struct {
    parsed: std.json.Parsed(std.json.Value),
    session_id: ?[]const u8,
    request_id: ?[]const u8,
    tool_call_id: ?[]const u8,
    tool_name: ?[]const u8,

    fn deinit(self: RpcContext) void {
        self.parsed.deinit();
    }
};

fn parseRpcContext(
    allocator: std.mem.Allocator,
    request_json: []const u8,
) !RpcContext {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request_json, .{});
    errdefer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidJsonRpc,
    };
    const params = switch (root.get("params") orelse .null) {
        .object => |object| object,
        else => std.json.ObjectMap.empty,
    };
    return .{
        .parsed = parsed,
        .session_id = jsonString(params, "sessionId"),
        .request_id = jsonString(params, "requestId"),
        .tool_call_id = jsonString(params, "toolCallId"),
        .tool_name = jsonString(params, "toolName"),
    };
}

fn jsonString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn recordRpcFailure(
    capture: ?*errors.ErrorCapture,
    method: []const u8,
    request_id: u64,
    request_json: []const u8,
    response_json: []const u8,
    value: std.json.Value,
) !noreturn {
    const object = switch (value) {
        .object => |object| object,
        else => return try recordEnvelope(capture, .invalid_error_object, response_json),
    };
    const code = switch (object.get("code") orelse
        return try recordEnvelope(capture, .invalid_error_code, response_json)) {
        .integer => |number| number,
        else => return try recordEnvelope(capture, .invalid_error_code, response_json),
    };
    const message = switch (object.get("message") orelse
        return try recordEnvelope(capture, .invalid_error_message, response_json)) {
        .string => |string| string,
        else => return try recordEnvelope(capture, .invalid_error_message, response_json),
    };
    const data = object.get("data");
    const machine_code = rpcMachineCode(data);
    const target = capture orelse {
        if (isMissingSession(machine_code, message))
            return error.SessionNotFound;
        if (std.mem.indexOf(u8, method, "queue") != null) return error.QueueFailure;
        if (std.mem.indexOf(u8, method, "permissions.") != null) return error.PermissionFailure;
        if (std.mem.indexOf(u8, method, "tools.") != null) return error.ToolFailure;
        return error.RpcRejected;
    };
    const context = try parseRpcContext(target.allocator, request_json);
    defer context.deinit();
    const rpc = try ownRpcFailure(
        target.allocator,
        method,
        request_id,
        code,
        machine_code,
        message,
        data,
    );
    var rpc_transferred = false;
    defer if (!rpc_transferred) {
        var failure = errors.Failure{
            .allocator = target.allocator,
            .detail = .{ .rpc = rpc },
        };
        failure.deinit();
    };

    if (context.session_id) |id| {
        if (isMissingSession(machine_code, message)) {
            const owned_session_id = try target.allocator.dupe(u8, id);
            rpc_transferred = true;
            return try recordFailure(capture, error.SessionNotFound, .{ .session = .{ .not_found = .{
                .session_id = owned_session_id,
                .rpc = rpc,
            } } });
        }
        if (std.mem.indexOf(u8, method, "queue") != null) {
            const owned_session_id = try target.allocator.dupe(u8, id);
            const operation = target.allocator.dupe(u8, method) catch |err| {
                target.allocator.free(owned_session_id);
                return err;
            };
            rpc_transferred = true;
            return try recordFailure(capture, error.QueueFailure, .{ .queue = .{ .rejected = .{
                .session_id = owned_session_id,
                .operation = operation,
                .rpc = rpc,
            } } });
        }
        if (std.mem.indexOf(u8, method, "permissions.") != null) {
            const owned_session_id = try target.allocator.dupe(u8, id);
            const owned_request_id = target.allocator.dupe(
                u8,
                context.request_id orelse "",
            ) catch |err| {
                target.allocator.free(owned_session_id);
                return err;
            };
            rpc_transferred = true;
            return try recordFailure(capture, error.PermissionFailure, .{ .permission = .{
                .delivery_failed = .{
                    .session_id = owned_session_id,
                    .request_id = owned_request_id,
                    .rpc = rpc,
                    .cause = null,
                },
            } });
        }
        if (std.mem.indexOf(u8, method, "tools.") != null) {
            const owned_session_id = try target.allocator.dupe(u8, id);
            const owned_request_id = target.allocator.dupe(
                u8,
                context.request_id orelse "",
            ) catch |err| {
                target.allocator.free(owned_session_id);
                return err;
            };
            const tool_call_id = dupeOptional(
                target.allocator,
                context.tool_call_id,
            ) catch |err| {
                target.allocator.free(owned_session_id);
                target.allocator.free(owned_request_id);
                return err;
            };
            const tool_name = dupeOptional(
                target.allocator,
                context.tool_name,
            ) catch |err| {
                target.allocator.free(owned_session_id);
                target.allocator.free(owned_request_id);
                if (tool_call_id) |owned| target.allocator.free(owned);
                return err;
            };
            rpc_transferred = true;
            return try recordFailure(capture, error.ToolFailure, .{ .tool = .{ .delivery_failed = .{
                .session_id = owned_session_id,
                .request_id = owned_request_id,
                .tool_call_id = tool_call_id,
                .tool_name = tool_name,
                .handler_cause = null,
                .rpc = rpc,
                .cause = null,
            } } });
        }
    }
    rpc_transferred = true;
    return try recordFailure(capture, error.RpcRejected, .{ .rpc = rpc });
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

const QueuedEvent = struct {
    session_id: []u8,
    event: session_types.SessionEvent,

    fn deinit(self: *QueuedEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        self.event.deinit(allocator);
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
    events: std.ArrayList(QueuedEvent) = .empty,
    tools: std.ArrayList(RegisteredTool) = .empty,
    user_input_handlers: std.ArrayList(RegisteredUserInputHandler) = .empty,
    permission_handlers: std.ArrayList(RegisteredPermissionHandler) = .empty,
    rpc_handlers: std.ArrayList(RegisteredRpcHandler) = .empty,
    dispatching_rpc_handler: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: ClientOptions,
        capture: ?*errors.ErrorCapture,
    ) !Client {
        try beginCapture(capture);
        var client = spawn(allocator, io, options) catch |err| {
            if (err == error.OutOfMemory) return err;
            return try recordProcessSpawn(capture, options.cli_path, err);
        };
        errdefer client.deinit();
        try client.connect(options.connection_token, options.client_info, capture);
        return client;
    }

    pub fn initParent(
        allocator: std.mem.Allocator,
        io: std.Io,
        capture: ?*errors.ErrorCapture,
    ) !Client {
        try beginCapture(capture);
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
        try client.connect(null, null, capture);
        return client;
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

    pub fn stop(self: *Client, capture: ?*errors.ErrorCapture) !void {
        try beginCapture(capture);
        var failures: std.ArrayList(errors.Failure) = .empty;
        defer {
            for (failures.items) |*failure| failure.deinit();
            failures.deinit(if (capture) |value| value.allocator else self.allocator);
        }
        var failed = false;
        var index = self.session_ids.items.len;
        while (index > 0) {
            index -= 1;
            const session = Session{
                .client = self,
                .id = self.session_ids.items[index],
            };
            if (capture) |target| {
                var nested = errors.ErrorCapture.init(target.allocator);
                defer nested.deinit();
                session.disconnectImpl(&nested) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    failed = true;
                    var failure = nested.take() orelse return err;
                    failures.append(target.allocator, failure) catch |append_error| {
                        failure.deinit();
                        return append_error;
                    };
                };
            } else {
                session.disconnectImpl(null) catch {
                    failed = true;
                };
            }
        }
        if (self.child) |*child| {
            child.kill(self.io);
        }
        if (!failed) return;
        const target = capture orelse return error.ClientFailure;
        const owned_failures = try failures.toOwnedSlice(target.allocator);
        return target.recordOwned(.{
            .allocator = target.allocator,
            .detail = .{ .client = .{ .stop = .{
                .failures = owned_failures,
            } } },
        });
    }

    fn recordReadFailure(
        self: *Client,
        capture: ?*errors.ErrorCapture,
        cause: anyerror,
    ) !noreturn {
        if (cause == error.OutOfMemory) return cause;
        if (capture) |value| {
            if (value.get()) |failure| return failure.errorTag();
        }
        if (cause == error.EndOfStream) {
            if (self.last_exit) |exit| return try recordProcessExit(capture, exit);
            if (self.child) |*child| {
                if (child.id != null) {
                    const term = child.wait(self.io) catch |wait_error|
                        return try recordClientIo(capture, .read, wait_error);
                    const exit = processExit(term);
                    self.last_exit = exit;
                    return try recordProcessExit(capture, exit);
                }
            }
        }
        return try recordFrameFailure(capture, cause);
    }

    fn connect(
        self: *Client,
        token: ?[]const u8,
        client_info: ?ClientInfo,
        capture: ?*errors.ErrorCapture,
    ) !void {
        const parsed = try self.callImpl(struct {
            ok: bool,
            protocolVersion: std.json.Value,
            version: []const u8,
        }, "connect", .{
            .token = token,
            .clientInfo = toWireClientInfo(client_info),
        }, capture, null);
        defer parsed.deinit();
        if (!parsed.value.ok) return try recordConnectRejected(capture);
        const server_version = switch (parsed.value.protocolVersion) {
            .integer => |value| std.math.cast(u64, value) orelse
                return try recordInvalidProtocolVersion(capture, parsed.value.protocolVersion),
            else => return try recordInvalidProtocolVersion(
                capture,
                parsed.value.protocolVersion,
            ),
        };
        if (server_version != protocol.sdk_protocol_version)
            return try recordProtocolMismatch(capture, server_version);
    }

    pub fn createSession(
        self: *Client,
        config: session_types.SessionConfig,
        capture: ?*errors.ErrorCapture,
    ) !Session {
        try beginCapture(capture);
        var parsed_parameters: std.ArrayList(std.json.Parsed(std.json.Value)) = .empty;
        defer {
            for (parsed_parameters.items) |parsed| parsed.deinit();
            parsed_parameters.deinit(self.allocator);
        }
        var tools: std.ArrayList(WireTool) = .empty;
        defer tools.deinit(self.allocator);
        appendWireTools(self.allocator, config.tools, &parsed_parameters, &tools) catch |err|
            return try recordInvalidConfig(capture, "tools", err);

        const request = buildCreateSessionRequest(config, tools.items) catch |err|
            return try recordInvalidConfig(capture, "session", err);
        const parsed = try self.callImpl(
            struct { sessionId: []const u8 },
            "session.create",
            request,
            capture,
            config.session_id,
        );
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
        return .{ .client = self, .id = id };
    }

    pub fn joinSession(
        self: *Client,
        session_id: []const u8,
        config: session_types.SessionConfig,
        capture: ?*errors.ErrorCapture,
    ) !Session {
        try beginCapture(capture);
        var parsed_parameters: std.ArrayList(std.json.Parsed(std.json.Value)) = .empty;
        defer {
            for (parsed_parameters.items) |parsed| parsed.deinit();
            parsed_parameters.deinit(self.allocator);
        }
        var tools: std.ArrayList(WireTool) = .empty;
        defer tools.deinit(self.allocator);
        appendWireTools(self.allocator, config.tools, &parsed_parameters, &tools) catch |err|
            return try recordInvalidConfig(capture, "tools", err);

        const request = buildResumeSessionRequest(session_id, config, tools.items) catch |err|
            return try recordInvalidConfig(capture, "session", err);
        const parsed = try self.callImpl(
            std.json.Value,
            "session.resume",
            request,
            capture,
            session_id,
        );
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
        return .{ .client = self, .id = id };
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
        capture: ?*errors.ErrorCapture,
    ) !std.json.Parsed(Result) {
        try beginCapture(capture);
        return self.callImpl(Result, method, params, capture, null);
    }

    /// Lists models available to the authenticated or explicitly selected user.
    pub fn listModels(
        self: *Client,
        options: models.ListOptions,
        capture: ?*errors.ErrorCapture,
    ) !std.json.Parsed(models.ModelList) {
        try beginCapture(capture);
        return self.callImpl(models.ModelList, "models.list", WireModelsListRequest{
            .selectionId = options.selection_id,
            .gitHubToken = options.github_token,
        }, capture, null);
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
        comptime Result: type,
        method: []const u8,
        params: anytype,
        capture: ?*errors.ErrorCapture,
        session_id: ?[]const u8,
    ) !std.json.Parsed(Result) {
        _ = session_id;
        if (self.dispatching_rpc_handler)
            return try recordReentrant(capture, method);
        const id = self.next_request_id;
        self.next_request_id += 1;

        const request = json_rpc.encodeRequest(self.allocator, id, method, params) catch |err| {
            if (err == error.OutOfMemory) return err;
            return try recordClientJson(capture, .write, err);
        };
        defer self.allocator.free(request);
        json_rpc.writeFrame(&self.writer.interface, request) catch |err|
            return try recordClientIo(capture, .write, err);

        while (true) {
            const body = json_rpc.readFrameCaptured(
                self.allocator,
                &self.reader.interface,
                capture,
            ) catch |err|
                return try self.recordReadFailure(capture, err);
            defer self.allocator.free(body);
            const value = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch |err| {
                if (err == error.OutOfMemory) return err;
                return try recordInvalidJson(capture, err);
            };
            defer value.deinit();
            const inbound = try parseInboundMessage(capture, body, value.value);
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
                        if (err == error.OutOfMemory) return err;
                        return try recordClientIo(capture, operation, err);
                    };
                    continue;
                },
                .notification => |notification| {
                    if (std.mem.eql(u8, notification.method, "session.event")) {
                        try self.queueSessionEvent(
                            notification.params orelse
                                return try recordEnvelope(capture, .missing_params, body),
                            capture,
                        );
                    }
                    continue;
                },
                .response => |response| {
                    if (response.id != id)
                        return try recordUnexpectedResponse(capture, id, response.id_value);
                    if (response.rpc_error) |rpc_error| {
                        return try recordRpcFailure(
                            capture,
                            method,
                            id,
                            request,
                            body,
                            rpc_error,
                        );
                    }
                    const result = response.result orelse
                        return try recordEnvelope(
                            capture,
                            .missing_result_and_error,
                            body,
                        );
                    const result_json = try std.json.Stringify.valueAlloc(
                        self.allocator,
                        result,
                        .{},
                    );
                    defer self.allocator.free(result_json);
                    return std.json.parseFromSlice(Result, self.allocator, result_json, .{
                        .allocate = .alloc_always,
                        .ignore_unknown_fields = true,
                    }) catch |err| {
                        if (err == error.OutOfMemory) return err;
                        return try recordClientJson(capture, .read, err);
                    };
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

    fn queueSessionEvent(
        self: *Client,
        params_value: std.json.Value,
        capture: ?*errors.ErrorCapture,
    ) !void {
        const params = switch (params_value) {
            .object => |object| object,
            else => return try recordEnvelope(capture, .missing_params, "invalid session event params"),
        };
        const session_id_value = params.get("sessionId") orelse
            return try recordEnvelope(capture, .missing_params, "session event missing sessionId");
        const session_id = switch (session_id_value) {
            .string => |id| id,
            else => return try recordEnvelope(capture, .missing_params, "invalid sessionId"),
        };
        if (self.events.items.len >= max_queued_events) {
            const event_type = if (params.get("event")) |event_value| switch (event_value) {
                .object => |event_object| if (event_object.get("type")) |type_value| switch (type_value) {
                    .string => |string| string,
                    else => null,
                } else null,
                else => null,
            } else null;
            return try recordQueueFull(
                capture,
                session_id,
                event_type,
                self.events.items.len,
            );
        }
        var queued = QueuedEvent{
            .session_id = try self.allocator.dupe(u8, session_id),
            .event = undefined,
        };
        errdefer self.allocator.free(queued.session_id);
        const event_value = params.get("event") orelse
            return try recordEnvelope(capture, .missing_params, "session event missing event");
        queued.event = session_types.parseEvent(self.allocator, event_value) catch |err| {
            if (err == error.OutOfMemory) return err;
            return try recordInvalidEvent(capture, event_value);
        };
        errdefer queued.event.deinit(self.allocator);
        try self.events.append(self.allocator, queued);
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
        session_id: []const u8,
        capture: ?*errors.ErrorCapture,
    ) !session_types.SessionEvent {
        while (true) {
            for (self.events.items, 0..) |queued, index| {
                if (std.mem.eql(u8, queued.session_id, session_id)) {
                    const result = self.events.orderedRemove(index);
                    self.allocator.free(result.session_id);
                    return result.event;
                }
            }

            const body = json_rpc.readFrameCaptured(
                self.allocator,
                &self.reader.interface,
                capture,
            ) catch |err|
                return try self.recordReadFailure(capture, err);
            defer self.allocator.free(body);
            const value = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch |err| {
                if (err == error.OutOfMemory) return err;
                return try recordInvalidJson(capture, err);
            };
            defer value.deinit();
            const inbound = try parseInboundMessage(capture, body, value.value);
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
                        if (err == error.OutOfMemory) return err;
                        return try recordClientIo(capture, operation, err);
                    };
                },
                .notification => |notification| {
                    if (std.mem.eql(u8, notification.method, "session.event")) {
                        try self.queueSessionEvent(
                            notification.params orelse
                                return try recordEnvelope(capture, .missing_params, body),
                            capture,
                        );
                    }
                },
                .response => |response| return try recordUnexpectedResponse(
                    capture,
                    0,
                    response.id_value,
                ),
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
        capture: ?*errors.ErrorCapture,
    ) ![]u8 {
        try beginCapture(capture);
        return self.sendImpl(options, capture);
    }

    fn sendImpl(
        self: Session,
        options: session_types.MessageOptions,
        capture: ?*errors.ErrorCapture,
    ) ![]u8 {
        const parsed = try self.client.callImpl(struct { messageId: []const u8 }, "session.send", .{
            .sessionId = self.id,
            .prompt = options.prompt,
        }, capture, self.id);
        defer parsed.deinit();
        return self.client.allocator.dupe(u8, parsed.value.messageId);
    }

    pub fn sendAndWait(
        self: Session,
        options: session_types.MessageOptions,
        capture: ?*errors.ErrorCapture,
    ) !?session_types.AssistantMessage {
        try beginCapture(capture);
        const message_id = try self.sendImpl(options, capture);
        defer self.client.allocator.free(message_id);

        var response: ?session_types.AssistantMessage = null;
        errdefer if (response) |message| message.deinit(self.client.allocator);

        while (true) {
            var event = try self.nextEventImpl(capture);
            defer event.deinit(self.client.allocator);

            switch (event) {
                .assistant_message => |message| {
                    if (response) |previous| previous.deinit(self.client.allocator);
                    response = message;
                    event = .{ .session_idle = .{} };
                },
                .session_idle => |idle| {
                    if (completesSendAndWait(idle)) return response;
                },
                .session_error => |session_error| {
                    return try recordSessionAgentFailure(capture, self.id, session_error);
                },
                else => {},
            }
        }
    }

    pub fn nextEvent(
        self: Session,
        capture: ?*errors.ErrorCapture,
    ) !session_types.SessionEvent {
        try beginCapture(capture);
        return self.nextEventImpl(capture);
    }

    fn nextEventImpl(
        self: Session,
        capture: ?*errors.ErrorCapture,
    ) !session_types.SessionEvent {
        var event = try self.client.nextEventImpl(self.id, capture);
        errdefer event.deinit(self.client.allocator);
        if (event == .external_tool_requested) {
            const request = event.external_tool_requested;
            if (self.client.findToolHandler(self.id, request.tool_name)) |tool| {
                const result = tool.handler(
                    self.client.allocator,
                    request.arguments_json,
                    tool.context,
                ) catch |err| {
                    var delivery = errors.ErrorCapture.init(self.client.allocator);
                    defer delivery.deinit();
                    self.respondToToolErrorImpl(
                        request.request_id,
                        @errorName(err),
                        &delivery,
                    ) catch |delivery_error| {
                        if (delivery_error == error.OutOfMemory) return delivery_error;
                        var failure = delivery.take() orelse return delivery_error;
                        attachToolContext(
                            &failure,
                            request.tool_call_id,
                            request.tool_name,
                        ) catch |attach_error| {
                            failure.deinit();
                            return attach_error;
                        };
                        event.external_tool_requested.automatic_handling = .{
                            .delivery_failed = .{
                                .handler_cause = .{ .code = err },
                                .failure = failure,
                            },
                        };
                        return event;
                    };
                    event.external_tool_requested.automatic_handling =
                        .{ .handler_failed_delivered = .{ .code = err } };
                    return event;
                };
                defer self.client.allocator.free(result);
                var delivery = errors.ErrorCapture.init(self.client.allocator);
                defer delivery.deinit();
                self.respondToToolImpl(request.request_id, result, &delivery) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    var failure = delivery.take() orelse return err;
                    attachToolContext(
                        &failure,
                        request.tool_call_id,
                        request.tool_name,
                    ) catch |attach_error| {
                        failure.deinit();
                        return attach_error;
                    };
                    event.external_tool_requested.automatic_handling = .{
                        .delivery_failed = .{
                            .handler_cause = null,
                            .failure = failure,
                        },
                    };
                    return event;
                };
                event.external_tool_requested.automatic_handling = .delivered;
            }
        }
        if (event == .permission_requested) {
            const request = event.permission_requested;
            if (self.client.findPermissionHandler(self.id)) |handler| {
                const decision = handler.handler(
                    request,
                    .{
                        .session_id = self.id,
                        .managed_settings_enabled = handler.managed_settings_enabled,
                    },
                    handler.context,
                ) catch |err| {
                    event.permission_requested.automatic_handling =
                        .{ .handler_failed = .{ .code = err } };
                    return event;
                };
                var delivery = errors.ErrorCapture.init(self.client.allocator);
                defer delivery.deinit();
                switch (decision) {
                    .approve_once => self.approvePermissionImpl(
                        request.request_id,
                        &delivery,
                    ) catch |err| {
                        if (err == error.OutOfMemory) return err;
                        const failure = delivery.take() orelse return err;
                        event.permission_requested.automatic_handling =
                            .{ .delivery_failed = .{ .failure = failure } };
                        return event;
                    },
                    .reject => |feedback| self.rejectPermissionImpl(
                        request.request_id,
                        feedback,
                        &delivery,
                    ) catch |err| {
                        if (err == error.OutOfMemory) return err;
                        const failure = delivery.take() orelse return err;
                        event.permission_requested.automatic_handling =
                            .{ .delivery_failed = .{ .failure = failure } };
                        return event;
                    },
                    .json => |decision_json| self.respondToPermissionJsonImpl(
                        request.request_id,
                        decision_json,
                        null,
                        &delivery,
                    ) catch |err| {
                        if (err == error.OutOfMemory) return err;
                        const failure = delivery.take() orelse return err;
                        event.permission_requested.automatic_handling =
                            .{ .delivery_failed = .{ .failure = failure } };
                        return event;
                    },
                    .no_result => {
                        event.permission_requested.automatic_handling = .no_result;
                        return event;
                    },
                }
                event.permission_requested.automatic_handling = .handled;
            }
        }
        return event;
    }

    pub fn disconnect(
        self: Session,
        capture: ?*errors.ErrorCapture,
    ) !void {
        try beginCapture(capture);
        return self.disconnectImpl(capture);
    }

    fn disconnectImpl(
        self: Session,
        capture: ?*errors.ErrorCapture,
    ) !void {
        for (0..2) |_| {
            const parsed = try self.client.callImpl(struct {
                success: bool,
                @"error": ?[]const u8 = null,
            }, "session.detach", .{
                .sessionId = self.id,
            }, capture, self.id);
            defer parsed.deinit();
            if (parsed.value.success) {
                self.client.removeSession(self.id);
                return;
            }
        }
        return try recordDetachFailure(capture, self.id, 2);
    }

    pub fn setAutoTier(
        self: Session,
        auto_tier: ?session_types.AutoTier,
        capture: ?*errors.ErrorCapture,
    ) !session_types.AutoTierSwitchResult {
        try beginCapture(capture);
        const parsed = try self.client.callImpl(
            session_types.AutoTierSwitchResult,
            "session.model.switchAutoTier",
            .{
                .sessionId = self.id,
                .autoTier = if (auto_tier) |tier|
                    std.json.Value{ .string = @tagName(tier) }
                else
                    std.json.Value.null,
            },
            capture,
            self.id,
        );
        defer parsed.deinit();
        return parsed.value;
    }

    /// Aborts the current agent turn. The caller owns the returned result.
    pub fn abort(
        self: Session,
        capture: ?*errors.ErrorCapture,
    ) !std.json.Parsed(session_types.AbortResult) {
        try beginCapture(capture);
        return self.client.callImpl(session_types.AbortResult, "session.abort", .{
            .sessionId = self.id,
        }, capture, self.id);
    }

    /// Changes the selected model for subsequent turns. The caller owns the
    /// returned result.
    pub fn setModel(
        self: Session,
        model_id: []const u8,
        options: session_types.ModelSwitchOptions,
        capture: ?*errors.ErrorCapture,
    ) !std.json.Parsed(session_types.ModelSwitchResult) {
        try beginCapture(capture);
        return self.client.callImpl(
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
            capture,
            self.id,
        );
    }

    /// Emits a user-visible timeline entry and returns its event ID.
    pub fn log(
        self: Session,
        message: []const u8,
        options: session_types.LogOptions,
        capture: ?*errors.ErrorCapture,
    ) ![]u8 {
        try beginCapture(capture);
        const parsed = try self.client.callImpl(struct { eventId: []const u8 }, "session.log", WireLogRequest{
            .sessionId = self.id,
            .message = message,
            .level = options.level,
            .type = options.log_type,
            .ephemeral = options.ephemeral,
            .url = options.url,
            .tip = options.tip,
        }, capture, self.id);
        defer parsed.deinit();
        return self.client.allocator.dupe(u8, parsed.value.eventId);
    }

    pub fn approvePermission(
        self: Session,
        request_id: []const u8,
        capture: ?*errors.ErrorCapture,
    ) !void {
        try beginCapture(capture);
        return self.approvePermissionImpl(request_id, capture);
    }

    fn approvePermissionImpl(
        self: Session,
        request_id: []const u8,
        capture: ?*errors.ErrorCapture,
    ) !void {
        const parsed = try self.client.callImpl(RpcSuccess, "session.permissions.handlePendingPermissionRequest", .{
            .sessionId = self.id,
            .requestId = request_id,
            .result = .{ .kind = "approve-once" },
        }, capture, self.id);
        defer parsed.deinit();
        if (!parsed.value.success)
            return try recordPermissionNotAccepted(capture, self.id, request_id);
    }

    pub fn rejectPermission(
        self: Session,
        request_id: []const u8,
        feedback: ?[]const u8,
        capture: ?*errors.ErrorCapture,
    ) !void {
        try beginCapture(capture);
        return self.rejectPermissionImpl(request_id, feedback, capture);
    }

    fn rejectPermissionImpl(
        self: Session,
        request_id: []const u8,
        feedback: ?[]const u8,
        capture: ?*errors.ErrorCapture,
    ) !void {
        const parsed = try self.client.callImpl(RpcSuccess, "session.permissions.handlePendingPermissionRequest", .{
            .sessionId = self.id,
            .requestId = request_id,
            .result = .{ .kind = "reject", .feedback = feedback },
        }, capture, self.id);
        defer parsed.deinit();
        if (!parsed.value.success)
            return try recordPermissionNotAccepted(capture, self.id, request_id);
    }

    pub fn respondToPermissionJson(
        self: Session,
        request_id: []const u8,
        decision_json: []const u8,
        decision_context_json: ?[]const u8,
        capture: ?*errors.ErrorCapture,
    ) !void {
        try beginCapture(capture);
        return self.respondToPermissionJsonImpl(
            request_id,
            decision_json,
            decision_context_json,
            capture,
        );
    }

    fn respondToPermissionJsonImpl(
        self: Session,
        request_id: []const u8,
        decision_json: []const u8,
        decision_context_json: ?[]const u8,
        capture: ?*errors.ErrorCapture,
    ) !void {
        const decision = std.json.parseFromSlice(
            std.json.Value,
            self.client.allocator,
            decision_json,
            .{},
        ) catch |err| {
            if (err == error.OutOfMemory) return err;
            return try recordInvalidPermission(capture, self.id, request_id, err);
        };
        defer decision.deinit();
        if (decision.value != .object)
            return try recordInvalidPermission(capture, self.id, request_id, error.InvalidPermissionDecision);

        const decision_context = if (decision_context_json) |context_json|
            std.json.parseFromSlice(
                std.json.Value,
                self.client.allocator,
                context_json,
                .{},
            ) catch |err| {
                if (err == error.OutOfMemory) return err;
                return try recordInvalidPermission(capture, self.id, request_id, err);
            }
        else
            null;
        defer if (decision_context) |context| context.deinit();
        if (decision_context) |context| {
            if (context.value != .object)
                return try recordInvalidPermission(
                    capture,
                    self.id,
                    request_id,
                    error.InvalidPermissionDecisionContext,
                );
        }

        const parsed = if (decision_context) |context|
            try self.client.callImpl(
                RpcSuccess,
                "session.permissions.handlePendingPermissionRequest",
                .{
                    .sessionId = self.id,
                    .requestId = request_id,
                    .result = decision.value,
                    .decisionContext = context.value,
                },
                capture,
                self.id,
            )
        else
            try self.client.callImpl(
                RpcSuccess,
                "session.permissions.handlePendingPermissionRequest",
                .{
                    .sessionId = self.id,
                    .requestId = request_id,
                    .result = decision.value,
                },
                capture,
                self.id,
            );
        defer parsed.deinit();
        if (!parsed.value.success)
            return try recordPermissionNotAccepted(capture, self.id, request_id);
    }

    pub fn respondToTool(
        self: Session,
        request_id: []const u8,
        result: []const u8,
        capture: ?*errors.ErrorCapture,
    ) !void {
        try beginCapture(capture);
        return self.respondToToolImpl(request_id, result, capture);
    }

    fn respondToToolImpl(
        self: Session,
        request_id: []const u8,
        result: []const u8,
        capture: ?*errors.ErrorCapture,
    ) !void {
        const parsed = try self.client.callImpl(struct { success: bool }, "session.tools.handlePendingToolCall", .{
            .sessionId = self.id,
            .requestId = request_id,
            .result = result,
        }, capture, self.id);
        defer parsed.deinit();
        if (!parsed.value.success)
            return try recordToolNotAccepted(capture, self.id, request_id);
    }

    pub fn respondToToolResultJson(
        self: Session,
        request_id: []const u8,
        result_json: []const u8,
        capture: ?*errors.ErrorCapture,
    ) !void {
        try beginCapture(capture);
        const result = std.json.parseFromSlice(
            std.json.Value,
            self.client.allocator,
            result_json,
            .{},
        ) catch |err| {
            if (err == error.OutOfMemory) return err;
            return try recordInvalidToolResult(capture, self.id, request_id, err);
        };
        defer result.deinit();
        const object = switch (result.value) {
            .object => |object| object,
            else => return try recordInvalidToolResult(
                capture,
                self.id,
                request_id,
                error.InvalidToolResult,
            ),
        };
        const text = object.get("textResultForLlm") orelse
            return try recordInvalidToolResult(capture, self.id, request_id, error.InvalidToolResult);
        if (text != .string)
            return try recordInvalidToolResult(capture, self.id, request_id, error.InvalidToolResult);

        const parsed = try self.client.callImpl(
            struct { success: bool },
            "session.tools.handlePendingToolCall",
            .{
                .sessionId = self.id,
                .requestId = request_id,
                .result = result.value,
            },
            capture,
            self.id,
        );
        defer parsed.deinit();
        if (!parsed.value.success)
            return try recordToolNotAccepted(capture, self.id, request_id);
    }

    pub fn respondToToolError(
        self: Session,
        request_id: []const u8,
        message: []const u8,
        capture: ?*errors.ErrorCapture,
    ) !void {
        try beginCapture(capture);
        return self.respondToToolErrorImpl(request_id, message, capture);
    }

    fn respondToToolErrorImpl(
        self: Session,
        request_id: []const u8,
        message: []const u8,
        capture: ?*errors.ErrorCapture,
    ) !void {
        const parsed = try self.client.callImpl(struct { success: bool }, "session.tools.handlePendingToolCall", .{
            .sessionId = self.id,
            .requestId = request_id,
            .@"error" = message,
        }, capture, self.id);
        defer parsed.deinit();
        if (!parsed.value.success)
            return try recordToolNotAccepted(capture, self.id, request_id);
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
    _ = &Client.init;
    _ = &Client.initParent;
    _ = &Client.stop;
    _ = &Client.createSession;
    _ = &Client.joinSession;
    _ = &Client.callRpc;
    _ = &Client.listModels;
    _ = &Client.registerRpcHandler;
    _ = &Client.unregisterRpcHandler;
    _ = &Session.send;
    _ = &Session.sendAndWait;
    _ = &Session.nextEvent;
    _ = &Session.disconnect;
    _ = &Session.abort;
    _ = &Session.setModel;
    _ = &Session.setAutoTier;
    _ = &Session.log;
    _ = &Session.approvePermission;
    _ = &Session.rejectPermission;
    _ = &Session.respondToPermissionJson;
    _ = &Session.respondToTool;
    _ = &Session.respondToToolResultJson;
    _ = &Session.respondToToolError;
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
        null,
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
        .event = try session_types.parseEvent(allocator, parsed_event.value),
    });

    const session = Session{ .client = &client, .id = "session-1" };
    var event = try session.nextEvent(null);
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
        .event = try session_types.parseEvent(allocator, parsed_event.value),
    });

    const session = Session{ .client = &client, .id = "session-1" };
    var event = try session.nextEvent(null);
    defer event.deinit(allocator);
    try std.testing.expect(called);
    try std.testing.expect(event == .permission_requested);
    try std.testing.expect(event.permission_requested.automatic_handling == .no_result);
}

test "permission handler failures leave requests available for manual handling" {
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
        .event = try session_types.parseEvent(allocator, parsed_event.value),
    });

    const session = Session{ .client = &client, .id = "session-1" };
    var event = try session.nextEvent(null);
    defer event.deinit(allocator);
    try std.testing.expectEqualStrings("permission-1", event.permission_requested.request_id);
    switch (event.permission_requested.automatic_handling) {
        .handler_failed => |cause| try std.testing.expectEqual(
            error.PermissionHandlerFailed,
            cause.code,
        ),
        else => return error.TestExpectedHandlerFailure,
    }
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
        .event = try session_types.parseEvent(allocator, managed_session_event.value),
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
        .event = try session_types.parseEvent(allocator, managed_request_event.value),
    });

    const managed_session = Session{ .client = &client, .id = "managed-session" };
    var first = try managed_session.nextEvent(null);
    defer first.deinit(allocator);
    try std.testing.expectEqualStrings("permission-1", first.permission_requested.request_id);
    switch (first.permission_requested.automatic_handling) {
        .handler_failed => |cause| try std.testing.expectEqual(
            error.ApproveAllWithManagedSettings,
            cause.code,
        ),
        else => return error.TestExpectedHandlerFailure,
    }

    const managed_request = Session{ .client = &client, .id = "managed-request" };
    var second = try managed_request.nextEvent(null);
    defer second.deinit(allocator);
    try std.testing.expectEqualStrings("permission-2", second.permission_requested.request_id);
    try std.testing.expect(second.permission_requested.automatic_handling == .no_result);
}

fn runAutomaticPermissionRpc(
    allocator: std.mem.Allocator,
    response_body: []const u8,
) !struct {
    handling: session_types.AutomaticPermissionHandling,
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
        .event = try session_types.parseEvent(allocator, parsed_event.value),
    });

    const session = Session{ .client = &client, .id = "session-1" };
    var event = try session.nextEvent(null);
    defer event.deinit(allocator);
    const handling = event.permission_requested.automatic_handling;
    event.permission_requested.automatic_handling = .not_configured;

    const request_frame = try tmp.dir.readFileAlloc(
        std.testing.io,
        "request",
        allocator,
        .limited(4096),
    );
    return .{
        .handling = handling,
        .request_frame = request_frame,
    };
}

test "successful automatic permission handling writes one exact RPC and marks the event handled" {
    const allocator = std.testing.allocator;
    const result = try runAutomaticPermissionRpc(allocator,
        \\{"jsonrpc":"2.0","id":1,"result":{"success":true}}
    );
    defer allocator.free(result.request_frame);

    try std.testing.expect(result.handling == .handled);
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

    switch (result.handling) {
        .delivery_failed => |delivery| {
            var failure = delivery.failure;
            defer failure.deinit();
            try std.testing.expectEqual(error.PermissionFailure, failure.errorTag());
            try std.testing.expectEqualStrings(
                "permission decision was not accepted",
                failure.message().?,
            );
        },
        else => return error.TestExpectedDeliveryFailure,
    }
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
        .event = try session_types.parseEvent(allocator, parsed_event.value),
    });

    const session = Session{ .client = &client, .id = "session-1" };
    var event = try session.nextEvent(null);
    defer event.deinit(allocator);
    try std.testing.expectEqualStrings("permission-1", event.permission_requested.request_id);
    switch (event.permission_requested.automatic_handling) {
        .delivery_failed => {},
        else => return error.TestExpectedDeliveryFailure,
    }
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
    try std.testing.expect(!completesSendAndWait(.{ .mode = @constCast("autopilot") }));
    try std.testing.expect(completesSendAndWait(.{}));
    try std.testing.expect(completesSendAndWait(.{ .mode = @constCast("interactive") }));
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
        const created = try client.createSession(config, null);
        try std.testing.expectEqualStrings("created-session", created.id);
        const joined = try client.joinSession("existing-session", config, null);
        try std.testing.expectEqualStrings("existing-session", joined.id);

        var invalid_config = config;
        invalid_config.model_capabilities = .{ .limits = .{ .vision = .{ .max_prompt_images = 0 } } };
        try std.testing.expectError(error.ClientFailure, client.createSession(invalid_config, null));
        try std.testing.expectError(error.ClientFailure, client.joinSession("existing-session", invalid_config, null));

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

fn expectRecordedFailure(
    capture: *errors.ErrorCapture,
    expected: anyerror,
    result: anytype,
) !void {
    _ = result catch |err| {
        if (err == error.OutOfMemory) return err;
        try std.testing.expectEqual(expected, err);
        capture.reset();
        return;
    };
    return error.TestExpectedFailure;
}

fn exerciseFailureConstructors(allocator: std.mem.Allocator) !void {
    var capture = errors.ErrorCapture.init(allocator);
    defer capture.deinit();

    try expectRecordedFailure(
        &capture,
        error.ClientFailure,
        recordProcessSpawn(&capture, "copilot", error.FileNotFound),
    );
    try expectRecordedFailure(
        &capture,
        error.ClientFailure,
        recordReentrant(&capture, "session.send"),
    );
    try expectRecordedFailure(
        &capture,
        error.ClientFailure,
        recordInvalidConfig(&capture, "cli_path", error.InvalidArgument),
    );
    try expectRecordedFailure(
        &capture,
        error.QueueFailure,
        recordQueueFull(&capture, "session-1", "session.idle", max_queued_events),
    );
    try expectRecordedFailure(
        &capture,
        error.SessionFailure,
        recordSessionAgentFailure(&capture, "session-1", .{
            .error_type = @constCast("provider"),
            .error_code = @constCast("rate_limited"),
            .message = @constCast("retry later"),
            .provider_call_id = @constCast("provider-1"),
            .service_request_id = @constCast("service-1"),
            .remediation_json = @constCast("{\"retry\":true}"),
            .url = @constCast("https://example.test"),
            .stack = @constCast("trace"),
        }),
    );
    try expectRecordedFailure(
        &capture,
        error.SessionFailure,
        recordDetachFailure(&capture, "session-1", 2),
    );
    try expectRecordedFailure(
        &capture,
        error.PermissionFailure,
        recordPermissionNotAccepted(&capture, "session-1", "request-1"),
    );
    try expectRecordedFailure(
        &capture,
        error.PermissionFailure,
        recordInvalidPermission(
            &capture,
            "session-1",
            "request-1",
            error.InvalidPermissionDecision,
        ),
    );
    try expectRecordedFailure(
        &capture,
        error.ToolFailure,
        recordToolNotAccepted(&capture, "session-1", "request-1"),
    );
    try expectRecordedFailure(
        &capture,
        error.ToolFailure,
        recordInvalidToolResult(
            &capture,
            "session-1",
            "request-1",
            error.InvalidToolResult,
        ),
    );

    const request_json =
        \\{"jsonrpc":"2.0","id":1,"method":"session.resume","params":{"sessionId":"session-1"}}
    ;
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
    try expectRecordedFailure(
        &capture,
        error.SessionNotFound,
        recordRpcFailure(
            &capture,
            "session.resume",
            1,
            request_json,
            response_json,
            parsed.value.object.get("error").?,
        ),
    );
}

test "failure constructors roll back every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseFailureConstructors,
        .{},
    );
}

test "connect validates the protocol version" {
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
    try client.queueSessionEvent(parsed.value, null);

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

    var capture = errors.ErrorCapture.init(allocator);
    defer capture.deinit();
    try std.testing.expectError(
        error.QueueFailure,
        client.queueSessionEvent(parsed.value, &capture),
    );
    switch (capture.get().?.detail) {
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
    var capture = errors.ErrorCapture.init(allocator);
    defer capture.deinit();

    try std.testing.expectError(
        error.QueueFailure,
        client.callRpc(
            std.json.Value,
            "session.queue.setDrainPaused",
            .{ .sessionId = "session-owned", .paused = true },
            &capture,
        ),
    );
    response_file.close(std.testing.io);
    request_file.close(std.testing.io);

    var failure = capture.take().?;
    defer failure.deinit();
    try std.testing.expectEqual(error.QueueFailure, failure.errorTag());
    try std.testing.expectEqualStrings("queue_already_paused", failure.machineCode().?);
    switch (failure.detail) {
        .queue => |queue_failure| switch (queue_failure) {
            .rejected => |rejected| {
                try std.testing.expectEqualStrings("session-owned", rejected.session_id);
                try std.testing.expectEqualStrings(
                    "session.queue.setDrainPaused",
                    rejected.operation,
                );
                try std.testing.expectEqual(@as(i64, -32042), rejected.rpc.code);
                try std.testing.expectEqual(@as(u64, 1), rejected.rpc.request_id);
                try std.testing.expectEqualStrings(
                    "{\"code\":\"queue_already_paused\",\"retryable\":false}",
                    rejected.rpc.data_json.?,
                );
            },
            else => return error.TestExpectedQueueRejection,
        },
        else => return error.TestExpectedQueueFailure,
    }
}

test "stale capture is rejected before an RPC write" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const request_file = try tmp.dir.createFile(std.testing.io, "request", .{});
    var writer_buffer: [1024]u8 = undefined;
    var writer = request_file.writer(std.testing.io, &writer_buffer);
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = undefined,
        .writer = &writer,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    var capture = errors.ErrorCapture.init(allocator);
    defer capture.deinit();
    try std.testing.expectEqual(
        error.ProtocolFailure,
        capture.recordOwned(.{
            .allocator = allocator,
            .detail = .{ .protocol = .missing_content_length },
        }),
    );

    try std.testing.expectError(
        error.ErrorCaptureNotEmpty,
        client.callRpc(std.json.Value, "test.method", .{}, &capture),
    );
    request_file.close(std.testing.io);
    const request = try tmp.dir.readFileAlloc(
        std.testing.io,
        "request",
        allocator,
        .limited(16),
    );
    defer allocator.free(request);
    try std.testing.expectEqualStrings("", request);
    try std.testing.expectEqual(error.ProtocolFailure, capture.get().?.errorTag());
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
        error.RpcRejected,
        client.callRpc(std.json.Value, "unknown.method", .{}, null),
    );
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

    var permission_capture = errors.ErrorCapture.init(allocator);
    defer permission_capture.deinit();
    try std.testing.expectError(
        error.PermissionFailure,
        session.respondToPermissionJson("permission-1", "[]", null, &permission_capture),
    );
    switch (permission_capture.get().?.detail) {
        .permission => |permission_failure| switch (permission_failure) {
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

    var tool_capture = errors.ErrorCapture.init(allocator);
    defer tool_capture.deinit();
    try std.testing.expectError(
        error.ToolFailure,
        session.respondToToolResultJson("tool-request-1", "{}", &tool_capture),
    );
    switch (tool_capture.get().?.detail) {
        .tool => |tool_failure| switch (tool_failure) {
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

fn expectCapturedCallError(
    allocator: std.mem.Allocator,
    response_body: []const u8,
    method: []const u8,
    expected: anyerror,
    capture: *errors.ErrorCapture,
) !void {
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
    try std.testing.expectError(
        expected,
        client.callRpc(
            std.json.Value,
            method,
            .{ .sessionId = "missing-session", .requestId = "request-1" },
            capture,
        ),
    );
}

test "public RPC captures malformed JSON and envelopes" {
    const allocator = std.testing.allocator;
    var invalid_json = errors.ErrorCapture.init(allocator);
    defer invalid_json.deinit();
    try expectCapturedCallError(
        allocator,
        "{",
        "test.invalidJson",
        error.ProtocolFailure,
        &invalid_json,
    );
    switch (invalid_json.get().?.detail) {
        .protocol => |protocol_failure| switch (protocol_failure) {
            .invalid_json => |failure| {
                try std.testing.expectEqual(error.UnexpectedEndOfInput, failure.cause.code);
            },
            else => return error.TestExpectedInvalidJson,
        },
        else => return error.TestExpectedProtocolFailure,
    }

    var invalid_envelope = errors.ErrorCapture.init(allocator);
    defer invalid_envelope.deinit();
    try expectCapturedCallError(
        allocator,
        \\{"jsonrpc":"2.0","id":1,"result":{},"error":{"code":-1,"message":"bad"}}
    ,
        "test.invalidEnvelope",
        error.ProtocolFailure,
        &invalid_envelope,
    );
    switch (invalid_envelope.get().?.detail) {
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
            },
            else => return error.TestExpectedInvalidEnvelope,
        },
        else => return error.TestExpectedProtocolFailure,
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
        var capture = errors.ErrorCapture.init(allocator);
        defer capture.deinit();
        try expectCapturedCallError(
            allocator,
            case.body,
            "test.invalidRpcError",
            error.ProtocolFailure,
            &capture,
        );
        switch (capture.get().?.detail) {
            .protocol => |protocol_failure| switch (protocol_failure) {
                .invalid_envelope => |failure| {
                    try std.testing.expectEqual(case.reason, failure.reason);
                    try std.testing.expectEqualStrings(case.body, failure.message_json.?);
                },
                else => return error.TestExpectedInvalidEnvelope,
            },
            else => return error.TestExpectedProtocolFailure,
        }
    }
}

fn expectTruncatedCallFailure(
    allocator: std.mem.Allocator,
    capture: ?*errors.ErrorCapture,
) !void {
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
    try std.testing.expectError(
        error.ProtocolFailure,
        client.callRpc(std.json.Value, "test.truncated", .{}, capture),
    );
}

test "truncated RPC frames consistently map to protocol failure" {
    const allocator = std.testing.allocator;
    try expectTruncatedCallFailure(allocator, null);

    var capture = errors.ErrorCapture.init(allocator);
    defer capture.deinit();
    try expectTruncatedCallFailure(allocator, &capture);
    switch (capture.get().?.detail) {
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
    var capture = errors.ErrorCapture.init(allocator);
    defer capture.deinit();
    try expectCapturedCallError(
        allocator,
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"The requested conversation is unavailable","data":{"errorCode":"session_not_found"}}}
    ,
        "session.resume",
        error.SessionNotFound,
        &capture,
    );

    var failure = capture.take().?;
    defer failure.deinit();
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

    var capture = errors.ErrorCapture.init(allocator);
    defer capture.deinit();
    try std.testing.expectError(
        error.ClientFailure,
        client.nextEventImpl("session-1", &capture),
    );
    switch (capture.get().?.detail) {
        .client => |failure| switch (failure) {
            .io => |io_failure| {
                try std.testing.expectEqual(errors.ClientOperation.write, io_failure.operation);
            },
            else => return error.TestExpectedIoFailure,
        },
        else => return error.TestExpectedClientFailure,
    }
}

test "sendAndWait captures complete session diagnostics" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const send_response =
        \\{"jsonrpc":"2.0","id":1,"result":{"messageId":"message-1"}}
    ;
    const session_event =
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"session-1","event":{"type":"session.error","data":{"errorType":"provider","errorCode":"rate_limited","message":"Try later","statusCode":429,"providerCallId":"provider-1","serviceRequestId":"service-1","remediation":{"retryAfter":30},"url":"https://example.test/help","stack":"trace","eligibleForAutoSwitch":true}}}}
    ;
    const responses = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}",
        .{ send_response.len, send_response, session_event.len, session_event },
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
    var capture = errors.ErrorCapture.init(allocator);
    defer capture.deinit();

    try std.testing.expectError(
        error.SessionFailure,
        session.sendAndWait(.{ .prompt = "hello" }, &capture),
    );
    response_file.close(std.testing.io);
    request_file.close(std.testing.io);

    var failure = capture.take().?;
    defer failure.deinit();
    switch (failure.detail) {
        .session => |session_failure| switch (session_failure) {
            .agent => |agent| {
                try std.testing.expectEqualStrings("session-1", agent.session_id);
                try std.testing.expectEqualStrings("provider", agent.error_type);
                try std.testing.expectEqualStrings("rate_limited", agent.error_code.?);
                try std.testing.expectEqualStrings("Try later", agent.message);
                try std.testing.expectEqual(@as(u16, 429), agent.status_code.?);
                try std.testing.expectEqualStrings("provider-1", agent.provider_call_id.?);
                try std.testing.expectEqualStrings("service-1", agent.service_request_id.?);
                try std.testing.expectEqualStrings(
                    "{\"retryAfter\":30}",
                    agent.remediation_json.?,
                );
                try std.testing.expectEqualStrings("trace", agent.stack.?);
                try std.testing.expect(agent.eligible_for_auto_switch.?);
            },
            else => return error.TestExpectedAgentFailure,
        },
        else => return error.TestExpectedSessionFailure,
    }
}

test "nextEvent captures the child process exit status" {
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
    var capture = errors.ErrorCapture.init(allocator);
    defer capture.deinit();

    try std.testing.expectError(error.ProcessExited, session.nextEvent(&capture));
    try std.testing.expect(capture.get().?.isTransportFailure());
    switch (capture.get().?.detail) {
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
) !session_types.SessionEvent {
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
        .event = try session_types.parseEvent(allocator, event_json.value),
    });
    return (Session{ .client = &client, .id = "session-1" }).nextEvent(null);
}

test "automatic tool handler outcome retains handler and delivery details" {
    const allocator = std.testing.allocator;
    var delivered = try runAutomaticToolFailure(allocator,
        \\{"jsonrpc":"2.0","id":1,"result":{"success":true}}
    );
    defer delivered.deinit(allocator);
    switch (delivered.external_tool_requested.automatic_handling) {
        .handler_failed_delivered => |cause| {
            try std.testing.expectEqual(error.ToolHandlerExploded, cause.code);
        },
        else => return error.TestExpectedDeliveredHandlerFailure,
    }

    var rejected = try runAutomaticToolFailure(allocator,
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32010,"message":"tool delivery rejected","data":{"code":"tool_rejected"}}}
    );
    defer rejected.deinit(allocator);
    switch (rejected.external_tool_requested.automatic_handling) {
        .delivery_failed => |delivery| {
            try std.testing.expectEqual(error.ToolHandlerExploded, delivery.handler_cause.?.code);
            try std.testing.expectEqual(error.ToolFailure, delivery.failure.errorTag());
            try std.testing.expectEqualStrings("tool_rejected", delivery.failure.machineCode().?);
            switch (delivery.failure.detail) {
                .tool => |tool_failure| switch (tool_failure) {
                    .delivery_failed => |failure| {
                        try std.testing.expectEqualStrings("session-1", failure.session_id);
                        try std.testing.expectEqualStrings("request-1", failure.request_id);
                        try std.testing.expectEqualStrings("call-1", failure.tool_call_id.?);
                        try std.testing.expectEqualStrings("explode", failure.tool_name.?);
                    },
                    else => return error.TestExpectedToolDeliveryFailure,
                },
                else => return error.TestExpectedToolFailure,
            }
        },
        else => return error.TestExpectedToolDeliveryFailure,
    }
}
