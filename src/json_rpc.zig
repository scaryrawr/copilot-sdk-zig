const std = @import("std");
const errors = @import("errors.zig");

const max_frame_size = 16 * 1024 * 1024;

pub const ErrorObject = struct {
    code: i64,
    message: []const u8,
};

pub fn RequestFrame(comptime Params: type) type {
    return struct {
        jsonrpc: []const u8 = "2.0",
        id: u64,
        method: []const u8,
        params: Params,
    };
}

pub fn ResponseFrame(comptime Result: type) type {
    return struct {
        jsonrpc: []const u8,
        id: u64,
        result: ?Result = null,
        @"error": ?ErrorObject = null,
    };
}

pub fn NotificationFrame(comptime Params: type) type {
    return struct {
        jsonrpc: []const u8 = "2.0",
        method: []const u8,
        params: Params,
    };
}

pub const ErrorResponseFrame = struct {
    jsonrpc: []const u8 = "2.0",
    id: std.json.Value,
    @"error": ErrorObject,
};

pub const SuccessResponseFrame = struct {
    jsonrpc: []const u8 = "2.0",
    id: std.json.Value,
    result: std.json.Value,
};

pub fn encodeRequest(
    allocator: std.mem.Allocator,
    id: u64,
    method: []const u8,
    params: anytype,
) ![]u8 {
    return std.json.Stringify.valueAlloc(
        allocator,
        RequestFrame(@TypeOf(params)){
            .id = id,
            .method = method,
            .params = params,
        },
        .{ .emit_null_optional_fields = false },
    );
}

pub fn encodeErrorResponse(
    allocator: std.mem.Allocator,
    id: std.json.Value,
    code: i64,
    message: []const u8,
) ![]u8 {
    return std.json.Stringify.valueAlloc(
        allocator,
        ErrorResponseFrame{
            .id = id,
            .@"error" = .{
                .code = code,
                .message = message,
            },
        },
        .{},
    );
}

pub fn encodeSuccessResponse(
    allocator: std.mem.Allocator,
    id: std.json.Value,
    result: anytype,
) ![]u8 {
    const TypedSuccessResponseFrame = struct {
        jsonrpc: []const u8 = "2.0",
        id: std.json.Value,
        result: @TypeOf(result),
    };
    return std.json.Stringify.valueAlloc(
        allocator,
        TypedSuccessResponseFrame{
            .id = id,
            .result = result,
        },
        .{},
    );
}

pub fn writeFrame(writer: *std.Io.Writer, body: []const u8) !void {
    try writer.print("Content-Length: {d}\r\n\r\n", .{body.len});
    try writer.writeAll(body);
    try writer.flush();
}

const FailurePolicy = enum {
    legacy,
    detailed,
};

fn FrameResult(comptime policy: FailurePolicy) type {
    if (policy == .detailed) return errors.DetailedResult([]u8);
    return union(enum) {
        success: []u8,
        failure: anyerror,
    };
}

pub fn readFrame(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    return switch (try readFrameImpl(.legacy, allocator, reader)) {
        .success => |body| body,
        .failure => |native_error| native_error,
    };
}

pub fn readFrameDetailed(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
) errors.DetailedError!errors.DetailedResult([]u8) {
    return readFrameImpl(.detailed, allocator, reader);
}

fn readFrameImpl(
    comptime policy: FailurePolicy,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
) errors.DetailedError!FrameResult(policy) {
    var content_length: ?usize = null;
    var saw_line = false;

    while (reader.takeDelimiter('\n') catch |cause| {
        return .{ .failure = if (comptime policy == .legacy)
            cause
        else
            try ioFailure(allocator, cause) };
    }) |raw_line| {
        saw_line = true;
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(line, "Content-Length:")) {
            const value = std.mem.trim(u8, line["Content-Length:".len..], " \t");
            if (comptime policy == .legacy) {
                content_length = std.fmt.parseUnsigned(usize, value, 10) catch |cause|
                    return .{ .failure = cause };
            } else {
                const owned_value = try allocator.dupe(u8, value);
                content_length = std.fmt.parseUnsigned(usize, owned_value, 10) catch |cause| {
                    return .{ .failure = .{
                        .allocator = allocator,
                        .native_error = cause,
                        .detail = .{ .protocol = .{ .invalid_content_length = .{
                            .value = owned_value,
                        } } },
                    } };
                };
                allocator.free(owned_value);
            }
        }
    }

    if (!saw_line) return .{ .failure = if (comptime policy == .legacy)
        error.MissingContentLength
    else
        try ioFailure(allocator, error.EndOfStream) };
    const length = content_length orelse {
        if (comptime policy == .legacy)
            return .{ .failure = error.MissingContentLength };
        return .{ .failure = .{
            .allocator = allocator,
            .native_error = error.MissingContentLength,
            .detail = .{ .protocol = .missing_content_length },
        } };
    };
    if (length > max_frame_size) {
        if (comptime policy == .legacy)
            return .{ .failure = error.FrameTooLarge };
        return .{ .failure = .{
            .allocator = allocator,
            .native_error = error.FrameTooLarge,
            .detail = .{ .protocol = .{ .frame_too_large = .{
                .declared = length,
                .maximum = max_frame_size,
            } } },
        } };
    }

    const body = try allocator.alloc(u8, length);
    var received: usize = 0;
    while (received < length) {
        const count = reader.readSliceShort(body[received..]) catch |cause| {
            allocator.free(body);
            return .{ .failure = if (comptime policy == .legacy)
                cause
            else
                try ioFailure(allocator, cause) };
        };
        if (count == 0) break;
        received += count;
    }
    if (received != length) {
        allocator.free(body);
        if (comptime policy == .legacy)
            return .{ .failure = error.EndOfStream };
        return .{ .failure = .{
            .allocator = allocator,
            .native_error = error.EndOfStream,
            .detail = .{ .protocol = .{ .truncated_frame = .{
                .declared = length,
                .received = received,
            } } },
        } };
    }
    return .{ .success = body };
}

fn ioFailure(allocator: std.mem.Allocator, cause: anyerror) !errors.Failure {
    return .{
        .allocator = allocator,
        .native_error = cause,
        .detail = .{ .client = .{ .io = .{
            .operation = .read,
            .message = try allocator.dupe(u8, @errorName(cause)),
            .cause = .{ .code = cause },
        } } },
    };
}

test "request and response frames are typed" {
    const allocator = std.testing.allocator;
    const body = try encodeRequest(allocator, 7, "session.send", .{
        .sessionId = "s1",
        .prompt = "hello",
    });
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(
        RequestFrame(struct { sessionId: []const u8, prompt: []const u8 }),
        allocator,
        body,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u64, 7), parsed.value.id);
    try std.testing.expectEqualStrings("session.send", parsed.value.method);
    try std.testing.expectEqualStrings("hello", parsed.value.params.prompt);

    const response = try std.json.parseFromSlice(
        ResponseFrame(struct { messageId: []const u8 }),
        allocator,
        \\{"jsonrpc":"2.0","id":7,"result":{"messageId":"m1"}}
    ,
        .{},
    );
    defer response.deinit();
    try std.testing.expectEqualStrings("m1", response.value.result.?.messageId);
}

test "Content-Length framing round trips" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    try writeFrame(&output.writer, "{\"ok\":true}");
    var input = std.Io.Reader.fixed(output.written());
    const body = try readFrame(allocator, &input);
    defer allocator.free(body);

    try std.testing.expectEqualStrings("{\"ok\":true}", body);
}

test "fragmented Content-Length framing reads complete body" {
    std.debug.print("\nCENSUS_PROBE fragmented_frame_behavior\n", .{});
    const allocator = std.testing.allocator;
    var reader_buffer: [64]u8 = undefined;
    var reader: std.testing.Reader = .init(&reader_buffer, &.{
        .{ .buffer = "Content-" },
        .{ .buffer = "Length: 11\r" },
        .{ .buffer = "\n\r\nhello " },
        .{ .buffer = "world" },
    });
    reader.artificial_limit = .limited(1);

    const body = try readFrame(allocator, &reader.interface);
    defer allocator.free(body);
    try std.testing.expectEqualStrings("hello world", body);
}

test "fragmented framing reports actual EOF after partial body" {
    const allocator = std.testing.allocator;
    var reader_buffer: [64]u8 = undefined;
    var reader: std.testing.Reader = .init(&reader_buffer, &.{
        .{ .buffer = "Content-Len" },
        .{ .buffer = "gth: 5\r\n\r\n" },
        .{ .buffer = "ab" },
        .{ .buffer = "c" },
    });
    reader.artificial_limit = .limited(1);

    var failure = switch (try readFrameDetailed(allocator, &reader.interface)) {
        .success => |body| {
            allocator.free(body);
            return error.TestExpectedFailure;
        },
        .failure => |value| value,
    };
    defer failure.deinit();
    try std.testing.expectEqual(error.EndOfStream, failure.native_error);
    switch (failure.detail) {
        .protocol => |protocol_failure| switch (protocol_failure) {
            .truncated_frame => |truncated| {
                try std.testing.expectEqual(@as(usize, 5), truncated.declared);
                try std.testing.expectEqual(@as(usize, 3), truncated.received);
            },
            else => return error.TestExpectedTruncatedFrame,
        },
        else => return error.TestExpectedProtocolFailure,
    }
}

test "captured framing failures retain literal input and lengths" {
    std.debug.print("\nCENSUS_PROBE framing_failure_ownership\n", .{});
    const allocator = std.testing.allocator;

    var invalid_reader = std.Io.Reader.fixed("Content-Length: nope\r\n\r\n");
    var invalid_failure = switch (try readFrameDetailed(allocator, &invalid_reader)) {
        .success => |body| {
            allocator.free(body);
            return error.TestExpectedFailure;
        },
        .failure => |failure| failure,
    };
    defer invalid_failure.deinit();
    try std.testing.expectEqual(error.InvalidCharacter, invalid_failure.native_error);
    switch (invalid_failure.detail) {
        .protocol => |protocol_failure| switch (protocol_failure) {
            .invalid_content_length => |failure| {
                try std.testing.expectEqualStrings("nope", failure.value);
            },
            else => return error.TestExpectedInvalidContentLength,
        },
        else => return error.TestExpectedProtocolFailure,
    }

    var truncated_reader = std.Io.Reader.fixed("Content-Length: 5\r\n\r\nabc");
    var truncated_failure = switch (try readFrameDetailed(allocator, &truncated_reader)) {
        .success => |body| {
            allocator.free(body);
            return error.TestExpectedFailure;
        },
        .failure => |failure| failure,
    };
    defer truncated_failure.deinit();
    try std.testing.expectEqual(error.EndOfStream, truncated_failure.native_error);
    switch (truncated_failure.detail) {
        .protocol => |protocol_failure| switch (protocol_failure) {
            .truncated_frame => |failure| {
                try std.testing.expectEqual(@as(usize, 5), failure.declared);
                try std.testing.expectEqual(@as(usize, 3), failure.received);
            },
            else => return error.TestExpectedTruncatedFrame,
        },
        else => return error.TestExpectedProtocolFailure,
    }
}

test "truncated frames preserve legacy error and detailed diagnostics" {
    const allocator = std.testing.allocator;
    const frame = "Content-Length: 5\r\n\r\nabc";

    var plain_reader = std.Io.Reader.fixed(frame);
    try std.testing.expectError(
        error.EndOfStream,
        readFrame(allocator, &plain_reader),
    );

    var captured_reader = std.Io.Reader.fixed(frame);
    var failure_value = switch (try readFrameDetailed(allocator, &captured_reader)) {
        .success => |body| {
            allocator.free(body);
            return error.TestExpectedFailure;
        },
        .failure => |failure| failure,
    };
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

test "legacy framing preserves native error when diagnostics cannot allocate" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });
    var reader = std.Io.Reader.fixed("");

    try std.testing.expectError(
        error.MissingContentLength,
        readFrame(failing.allocator(), &reader),
    );
}

test "error responses preserve the request id" {
    const allocator = std.testing.allocator;
    const body = try encodeErrorResponse(
        allocator,
        .{ .string = "request-9" },
        -32601,
        "method not found",
    );
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(ErrorResponseFrame, allocator, body, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("request-9", parsed.value.id.string);
    try std.testing.expectEqual(@as(i64, -32601), parsed.value.@"error".code);
}

test "success responses encode typed results and preserve Value compatibility" {
    const allocator = std.testing.allocator;
    const typed_body = try encodeSuccessResponse(
        allocator,
        .{ .integer = 12 },
        .{ .accepted = true },
    );
    defer allocator.free(typed_body);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":12,\"result\":{\"accepted\":true}}",
        typed_body,
    );

    const value_body = try encodeSuccessResponse(
        allocator,
        .{ .string = "request-13" },
        std.json.Value{ .bool = true },
    );
    defer allocator.free(value_body);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":\"request-13\",\"result\":true}",
        value_body,
    );
}
