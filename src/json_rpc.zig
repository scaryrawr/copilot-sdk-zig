const std = @import("std");

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
    var content_length: ?usize = null;

    while (try reader.takeDelimiter('\n')) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(line, "Content-Length:")) {
            const value = std.mem.trim(u8, line["Content-Length:".len..], " \t");
            content_length = try std.fmt.parseUnsigned(usize, value, 10);
        }
    }

    const length = content_length orelse return error.MissingContentLength;
    if (length > 16 * 1024 * 1024) return error.FrameTooLarge;
    return reader.readAlloc(allocator, length);
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
