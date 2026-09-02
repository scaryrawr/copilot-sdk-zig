const std = @import("std");
const json_rpc = @import("json_rpc.zig");
const protocol = @import("protocol_version.zig");
const session_types = @import("session.zig");

const max_queued_events: usize = 1024;

pub const ClientOptions = struct {
    cli_path: []const u8 = "copilot",
    working_directory: ?[]const u8 = null,
    cli_args: []const []const u8 = &.{},
    connection_token: ?[]const u8 = null,
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

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    child: ?std.process.Child,
    reader: *std.Io.File.Reader,
    writer: *std.Io.File.Writer,
    reader_buffer: []u8,
    writer_buffer: []u8,
    next_request_id: u64 = 1,
    session_ids: std.ArrayList([]u8) = .empty,
    events: std.ArrayList(QueuedEvent) = .empty,
    tools: std.ArrayList(RegisteredTool) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: ClientOptions,
    ) !Client {
        var client = try spawn(allocator, io, options);
        errdefer client.deinit();
        try client.connect(options.connection_token);
        return client;
    }

    pub fn initParent(allocator: std.mem.Allocator, io: std.Io) !Client {
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
        try client.connect(null);
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
        for (self.session_ids.items) |id| self.allocator.free(id);
        self.session_ids.deinit(self.allocator);
        if (self.child) |*child| child.kill(self.io);
        self.allocator.destroy(self.reader);
        self.allocator.destroy(self.writer);
        self.allocator.free(self.reader_buffer);
        self.allocator.free(self.writer_buffer);
        self.* = undefined;
    }

    fn connect(self: *Client, token: ?[]const u8) !void {
        const parsed = try self.call(struct {
            ok: bool,
            protocolVersion: u64,
            version: []const u8,
        }, "connect", .{ .token = token });
        defer parsed.deinit();
        try validateConnectResult(parsed.value.ok, parsed.value.protocolVersion);
    }

    pub fn createSession(
        self: *Client,
        config: session_types.SessionConfig,
    ) !Session {
        var parsed_parameters: std.ArrayList(std.json.Parsed(std.json.Value)) = .empty;
        defer {
            for (parsed_parameters.items) |parsed| parsed.deinit();
            parsed_parameters.deinit(self.allocator);
        }
        var tools: std.ArrayList(WireTool) = .empty;
        defer tools.deinit(self.allocator);
        try appendWireTools(self.allocator, config.tools, &parsed_parameters, &tools);

        const parsed = try self.call(struct { sessionId: []const u8 }, "session.create", .{
            .sessionId = config.session_id,
            .model = config.model,
            .workingDirectory = config.working_directory,
            .streaming = config.streaming,
            .tools = tools.items,
            .systemMessage = config.system_message,
            .requestPermission = config.request_permission,
        });
        defer parsed.deinit();

        const id = try self.allocator.dupe(u8, parsed.value.sessionId);
        self.session_ids.append(self.allocator, id) catch |err| {
            self.allocator.free(id);
            return err;
        };
        errdefer self.removeSession(id);
        try self.registerToolHandlers(id, config.tools);
        return .{ .client = self, .id = id };
    }

    pub fn joinSession(
        self: *Client,
        session_id: []const u8,
        config: session_types.SessionConfig,
    ) !Session {
        var parsed_parameters: std.ArrayList(std.json.Parsed(std.json.Value)) = .empty;
        defer {
            for (parsed_parameters.items) |parsed| parsed.deinit();
            parsed_parameters.deinit(self.allocator);
        }
        var tools: std.ArrayList(WireTool) = .empty;
        defer tools.deinit(self.allocator);
        try appendWireTools(self.allocator, config.tools, &parsed_parameters, &tools);

        const parsed = try self.call(std.json.Value, "session.resume", .{
            .sessionId = session_id,
            .model = config.model,
            .workingDirectory = config.working_directory,
            .streaming = config.streaming,
            .tools = tools.items,
            .systemMessage = config.system_message,
            .requestPermission = config.request_permission,
            .disableResume = true,
        });
        parsed.deinit();

        const id = try self.allocator.dupe(u8, session_id);
        self.session_ids.append(self.allocator, id) catch |err| {
            self.allocator.free(id);
            return err;
        };
        errdefer self.removeSession(id);
        try self.registerToolHandlers(id, config.tools);
        return .{ .client = self, .id = id };
    }

    fn call(
        self: *Client,
        comptime Result: type,
        method: []const u8,
        params: anytype,
    ) !std.json.Parsed(Result) {
        const id = self.next_request_id;
        self.next_request_id += 1;

        const request = try json_rpc.encodeRequest(self.allocator, id, method, params);
        defer self.allocator.free(request);
        try json_rpc.writeFrame(&self.writer.interface, request);

        while (true) {
            const body = try json_rpc.readFrame(self.allocator, &self.reader.interface);
            defer self.allocator.free(body);
            const value = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
            defer value.deinit();
            const object = switch (value.value) {
                .object => |object| object,
                else => return error.InvalidJsonRpc,
            };

            if (object.get("method")) |notification_method| {
                const name = switch (notification_method) {
                    .string => |name| name,
                    else => return error.InvalidJsonRpc,
                };
                if (object.get("id")) |request_id| {
                    try self.rejectServerRequest(request_id);
                    continue;
                }
                if (std.mem.eql(u8, name, "session.event")) {
                    try self.queueSessionEvent(object.get("params") orelse return error.InvalidJsonRpc);
                }
                continue;
            }

            const response_id = object.get("id") orelse return error.InvalidJsonRpc;
            const response_number = switch (response_id) {
                .integer => |number| std.math.cast(u64, number) orelse return error.InvalidJsonRpc,
                else => return error.InvalidJsonRpc,
            };
            if (response_number != id) return error.UnexpectedResponse;
            if (object.get("error")) |rpc_error| {
                if (rpc_error != .null) return error.JsonRpcError;
            }
            const result = object.get("result") orelse return error.MissingResult;
            const result_json = try std.json.Stringify.valueAlloc(self.allocator, result, .{});
            defer self.allocator.free(result_json);
            // The CLI may add response metadata as the protocol evolves. Parse the
            // fields this SDK needs without rejecting compatible extra fields. The
            // parsed result must own strings because result_json is freed below.
            return std.json.parseFromSlice(Result, self.allocator, result_json, .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            });
        }
    }

    fn rejectServerRequest(self: *Client, id: std.json.Value) !void {
        const response = try json_rpc.encodeErrorResponse(
            self.allocator,
            id,
            -32601,
            "method not found",
        );
        defer self.allocator.free(response);
        try json_rpc.writeFrame(&self.writer.interface, response);
    }

    fn queueSessionEvent(self: *Client, params_value: std.json.Value) !void {
        if (self.events.items.len >= max_queued_events) return error.EventQueueFull;
        const params = switch (params_value) {
            .object => |object| object,
            else => return error.InvalidSessionEvent,
        };
        const session_id_value = params.get("sessionId") orelse return error.InvalidSessionEvent;
        const session_id = switch (session_id_value) {
            .string => |id| id,
            else => return error.InvalidSessionEvent,
        };
        var queued = QueuedEvent{
            .session_id = try self.allocator.dupe(u8, session_id),
            .event = undefined,
        };
        errdefer self.allocator.free(queued.session_id);
        queued.event = try session_types.parseEvent(
            self.allocator,
            params.get("event") orelse return error.InvalidSessionEvent,
        );
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

    fn nextEvent(self: *Client, session_id: []const u8) !session_types.SessionEvent {
        while (true) {
            for (self.events.items, 0..) |queued, index| {
                if (std.mem.eql(u8, queued.session_id, session_id)) {
                    const result = self.events.orderedRemove(index);
                    self.allocator.free(result.session_id);
                    return result.event;
                }
            }

            const body = try json_rpc.readFrame(self.allocator, &self.reader.interface);
            defer self.allocator.free(body);
            const value = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
            defer value.deinit();
            const object = switch (value.value) {
                .object => |object| object,
                else => return error.InvalidJsonRpc,
            };
            const method = switch (object.get("method") orelse return error.UnexpectedResponse) {
                .string => |method| method,
                else => return error.InvalidJsonRpc,
            };
            if (object.get("id")) |request_id| {
                try self.rejectServerRequest(request_id);
                continue;
            }
            if (std.mem.eql(u8, method, "session.event")) {
                try self.queueSessionEvent(object.get("params") orelse return error.InvalidJsonRpc);
            }
        }
    }
};

pub const Session = struct {
    client: *Client,
    id: []const u8,

    pub fn send(self: Session, options: session_types.MessageOptions) ![]u8 {
        const parsed = try self.client.call(struct { messageId: []const u8 }, "session.send", .{
            .sessionId = self.id,
            .prompt = options.prompt,
        });
        defer parsed.deinit();
        return self.client.allocator.dupe(u8, parsed.value.messageId);
    }

    pub fn sendAndWait(
        self: Session,
        options: session_types.MessageOptions,
    ) !?session_types.AssistantMessage {
        const message_id = try self.send(options);
        defer self.client.allocator.free(message_id);

        var response: ?session_types.AssistantMessage = null;
        errdefer if (response) |message| message.deinit(self.client.allocator);

        while (true) {
            var event = try self.nextEvent();
            defer event.deinit(self.client.allocator);

            switch (event) {
                .assistant_message => |message| {
                    if (response) |previous| previous.deinit(self.client.allocator);
                    response = message;
                    event = .session_idle;
                },
                .session_idle => return response,
                .session_error => return error.CopilotSessionError,
                else => {},
            }
        }
    }

    pub fn nextEvent(self: Session) !session_types.SessionEvent {
        var event = try self.client.nextEvent(self.id);
        errdefer event.deinit(self.client.allocator);
        if (event == .external_tool_requested) {
            const request = event.external_tool_requested;
            if (self.client.findToolHandler(self.id, request.tool_name)) |tool| {
                const result = tool.handler(
                    self.client.allocator,
                    request.arguments_json,
                    tool.context,
                ) catch |err| {
                    try self.respondToToolError(request.request_id, @errorName(err));
                    return event;
                };
                defer self.client.allocator.free(result);
                try self.respondToTool(request.request_id, result);
            }
        }
        return event;
    }

    pub fn destroy(self: Session) !void {
        const parsed = try self.client.call(std.json.Value, "session.destroy", .{
            .sessionId = self.id,
        });
        parsed.deinit();
        self.client.removeSession(self.id);
    }

    pub fn approvePermission(self: Session, request_id: []const u8) !void {
        const parsed = try self.client.call(std.json.Value, "session.permissions.handlePendingPermissionRequest", .{
            .sessionId = self.id,
            .requestId = request_id,
            .result = .{ .kind = "approve-once" },
        });
        parsed.deinit();
    }

    pub fn rejectPermission(
        self: Session,
        request_id: []const u8,
        feedback: ?[]const u8,
    ) !void {
        const parsed = try self.client.call(std.json.Value, "session.permissions.handlePendingPermissionRequest", .{
            .sessionId = self.id,
            .requestId = request_id,
            .result = .{ .kind = "reject", .feedback = feedback },
        });
        parsed.deinit();
    }

    pub fn respondToTool(
        self: Session,
        request_id: []const u8,
        result: []const u8,
    ) !void {
        const parsed = try self.client.call(struct { success: bool }, "session.tools.handlePendingToolCall", .{
            .sessionId = self.id,
            .requestId = request_id,
            .result = result,
        });
        defer parsed.deinit();
        if (!parsed.value.success) return error.ToolResultNotAccepted;
    }

    pub fn respondToToolError(
        self: Session,
        request_id: []const u8,
        message: []const u8,
    ) !void {
        const parsed = try self.client.call(struct { success: bool }, "session.tools.handlePendingToolCall", .{
            .sessionId = self.id,
            .requestId = request_id,
            .@"error" = message,
        });
        defer parsed.deinit();
        if (!parsed.value.success) return error.ToolResultNotAccepted;
    }
};

const WireTool = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.json.Value,
    skipPermission: bool,
};

fn appendWireTools(
    allocator: std.mem.Allocator,
    definitions: []const session_types.Tool,
    parsed_parameters: *std.ArrayList(std.json.Parsed(std.json.Value)),
    tools: *std.ArrayList(WireTool),
) !void {
    for (definitions) |definition| {
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            definition.parameters_json,
            .{},
        );
        errdefer parsed.deinit();
        if (parsed.value != .object) return error.InvalidToolParameters;
        try tools.append(allocator, .{
            .name = definition.name,
            .description = definition.description,
            .parameters = parsed.value,
            .skipPermission = definition.skip_permission,
        });
        try parsed_parameters.append(allocator, parsed);
    }
}

test "public client API type checks" {
    _ = &Client.init;
    _ = &Client.initParent;
    _ = &Client.createSession;
    _ = &Client.joinSession;
    _ = &Session.send;
    _ = &Session.sendAndWait;
    _ = &Session.nextEvent;
    _ = &Session.destroy;
    _ = &Session.approvePermission;
    _ = &Session.rejectPermission;
    _ = &Session.respondToTool;
    _ = &Session.respondToToolError;
}

fn validateConnectResult(ok: bool, protocol_version: u64) !void {
    if (!ok) return error.ConnectRejected;
    if (protocol_version != protocol.sdk_protocol_version) return error.ProtocolVersionMismatch;
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
    try client.queueSessionEvent(parsed.value);

    try std.testing.expectEqual(@as(usize, 1), client.events.items.len);
    try std.testing.expectEqualStrings("s1", client.events.items[0].session_id);
    try std.testing.expectEqualStrings(
        "hello",
        client.events.items[0].event.assistant_message.content,
    );
}

test "destroy removes session-owned allocations" {
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
        .event = .{ .session_idle = {} },
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
            .event = .{ .session_idle = {} },
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

    try std.testing.expectError(error.EventQueueFull, client.queueSessionEvent(parsed.value));
}
