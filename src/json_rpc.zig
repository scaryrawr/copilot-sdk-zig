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
    result: std.json.Value,
) ![]u8 {
    return std.json.Stringify.valueAlloc(
        allocator,
        SuccessResponseFrame{
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

pub fn readFrame(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    return readFrameCaptured(allocator, reader, null);
}

pub fn readFrameCaptured(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    capture: ?*errors.ErrorCapture,
) ![]u8 {
    if (capture) |target| try target.ensureEmpty();

    var content_length: ?usize = null;
    var saw_line = false;

    while (try reader.takeDelimiter('\n')) |raw_line| {
        saw_line = true;
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(line, "Content-Length:")) {
            const value = std.mem.trim(u8, line["Content-Length:".len..], " \t");
            content_length = std.fmt.parseUnsigned(usize, value, 10) catch |cause| {
                const target = capture orelse return cause;
                return target.recordOwned(.{
                    .allocator = target.allocator,
                    .detail = .{ .protocol = .{ .invalid_content_length = .{
                        .value = try target.allocator.dupe(u8, value),
                    } } },
                });
            };
        }
    }

    if (!saw_line) return error.EndOfStream;
    const length = content_length orelse {
        const target = capture orelse return error.MissingContentLength;
        return target.recordOwned(.{
            .allocator = target.allocator,
            .detail = .{ .protocol = .missing_content_length },
        });
    };
    if (length > max_frame_size) {
        const target = capture orelse return error.FrameTooLarge;
        return target.recordOwned(.{
            .allocator = target.allocator,
            .detail = .{ .protocol = .{ .frame_too_large = .{
                .declared = length,
                .maximum = max_frame_size,
            } } },
        });
    }

    const body = try allocator.alloc(u8, length);
    errdefer allocator.free(body);
    const received = try reader.readSliceShort(body);
    if (received != length) {
        if (capture) |target| {
            const recorded = target.recordOwned(.{
                .allocator = target.allocator,
                .detail = .{ .protocol = .{ .truncated_frame = .{
                    .declared = length,
                    .received = received,
                } } },
            });
            if (recorded == error.ErrorCaptureNotEmpty) return recorded;
        }
        return error.TruncatedFrame;
    }
    return body;
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

test "captured framing failures retain literal input and lengths" {
    const allocator = std.testing.allocator;

    var invalid_reader = std.Io.Reader.fixed("Content-Length: nope\r\n\r\n");
    var invalid_capture = errors.ErrorCapture.init(allocator);
    defer invalid_capture.deinit();
    try std.testing.expectError(
        error.ProtocolFailure,
        readFrameCaptured(allocator, &invalid_reader, &invalid_capture),
    );
    switch (invalid_capture.get().?.detail) {
        .protocol => |protocol_failure| switch (protocol_failure) {
            .invalid_content_length => |failure| {
                try std.testing.expectEqualStrings("nope", failure.value);
            },
            else => return error.TestExpectedInvalidContentLength,
        },
        else => return error.TestExpectedProtocolFailure,
    }

    var truncated_reader = std.Io.Reader.fixed("Content-Length: 5\r\n\r\nabc");
    var truncated_capture = errors.ErrorCapture.init(allocator);
    defer truncated_capture.deinit();
    try std.testing.expectError(
        error.TruncatedFrame,
        readFrameCaptured(allocator, &truncated_reader, &truncated_capture),
    );
    switch (truncated_capture.get().?.detail) {
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

test "stale capture rejects frames without consuming input" {
    const allocator = std.testing.allocator;
    var capture = errors.ErrorCapture.init(allocator);
    defer capture.deinit();
    try std.testing.expectEqual(
        error.ProtocolFailure,
        capture.recordOwned(.{
            .allocator = allocator,
            .detail = .{ .protocol = .missing_content_length },
        }),
    );

    inline for ([_][]const u8{
        "Content-Length: 2\r\n\r\n{}",
        "Content-Length: nope\r\n\r\n",
    }) |frame| {
        var reader = std.Io.Reader.fixed(frame);
        try std.testing.expectError(
            error.ErrorCaptureNotEmpty,
            readFrameCaptured(allocator, &reader, &capture),
        );
        try std.testing.expectEqual(@as(usize, 0), reader.seek);
        try std.testing.expectEqual(
            error.ProtocolFailure,
            capture.get().?.errorTag(),
        );
    }
}

test "truncated frames use one low-level error with and without capture" {
    const allocator = std.testing.allocator;
    const frame = "Content-Length: 5\r\n\r\nabc";

    var plain_reader = std.Io.Reader.fixed(frame);
    try std.testing.expectError(
        error.TruncatedFrame,
        readFrameCaptured(allocator, &plain_reader, null),
    );

    var capture = errors.ErrorCapture.init(allocator);
    defer capture.deinit();
    var captured_reader = std.Io.Reader.fixed(frame);
    try std.testing.expectError(
        error.TruncatedFrame,
        readFrameCaptured(allocator, &captured_reader, &capture),
    );
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

test "success responses preserve the request id and result" {
    const allocator = std.testing.allocator;
    const body = try encodeSuccessResponse(
        allocator,
        .{ .integer = 12 },
        .{ .bool = true },
    );
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(SuccessResponseFrame, allocator, body, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 12), parsed.value.id.integer);
    try std.testing.expect(parsed.value.result.bool);
}
