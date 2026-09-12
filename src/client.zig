const std = @import("std");
const json_rpc = @import("json_rpc.zig");
const models = @import("models.zig");
const provider = @import("provider.zig");
const protocol = @import("protocol_version.zig");
const session_types = @import("session.zig");

const max_queued_events: usize = 1024;

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
    provider_tokens: std.ArrayList(RegisteredProviderTokens) = .empty,
    rpc_handlers: std.ArrayList(RegisteredRpcHandler) = .empty,
    dispatching_rpc_handler: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: ClientOptions,
    ) !Client {
        var client = try spawn(allocator, io, options);
        errdefer client.deinit();
        try client.connect(options.connection_token, options.client_info);
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
        try client.connect(null, null);
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
        for (self.provider_tokens.items) |registered| registered.deinit(self.allocator);
        self.provider_tokens.deinit(self.allocator);
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

    fn connect(
        self: *Client,
        token: ?[]const u8,
        client_info: ?ClientInfo,
    ) !void {
        const parsed = try self.call(struct {
            ok: bool,
            protocolVersion: u64,
            version: []const u8,
        }, "connect", .{
            .token = token,
            .clientInfo = toWireClientInfo(client_info),
        });
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

        var prepared_providers = try provider.prepareSessionProviders(
            self.allocator,
            config.provider,
            config.providers,
            config.models,
        );
        defer prepared_providers.deinit(self.allocator);

        const setup = blk: {
            const owned_id = if (config.session_id) |requested|
                try self.allocator.dupe(u8, requested)
            else
                try generateSessionId(self.allocator, self.io);
            const request = buildPreparedCreateSessionRequest(
                owned_id,
                config,
                tools.items,
                prepared_providers,
            ) catch |err| {
                self.allocator.free(owned_id);
                return err;
            };
            try self.registerOwnedSession(owned_id, config, prepared_providers.token_bindings);
            break :blk .{ .id = owned_id, .request = request };
        };
        errdefer self.removeSession(setup.id);
        const parsed = try self.call(
            struct { sessionId: []const u8 },
            "session.create",
            setup.request,
        );
        defer parsed.deinit();
        if (!std.mem.eql(u8, setup.id, parsed.value.sessionId)) {
            return error.SessionIdMismatch;
        }
        return .{ .client = self, .id = setup.id };
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

        var prepared_providers = try provider.prepareSessionProviders(
            self.allocator,
            config.provider,
            config.providers,
            config.models,
        );
        defer prepared_providers.deinit(self.allocator);

        const setup = blk: {
            const owned_id = try self.allocator.dupe(u8, session_id);
            const request = buildPreparedResumeSessionRequest(
                owned_id,
                config,
                tools.items,
                prepared_providers,
            ) catch |err| {
                self.allocator.free(owned_id);
                return err;
            };
            try self.registerOwnedSession(owned_id, config, prepared_providers.token_bindings);
            break :blk .{ .id = owned_id, .request = request };
        };
        errdefer self.removeSession(setup.id);
        const parsed = try self.call(std.json.Value, "session.resume", setup.request);
        parsed.deinit();
        return .{ .client = self, .id = setup.id };
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
        return self.call(Result, method, params);
    }

    /// Lists models available to the authenticated or explicitly selected user.
    pub fn listModels(
        self: *Client,
        options: models.ListOptions,
    ) !std.json.Parsed(models.ModelList) {
        return self.call(models.ModelList, "models.list", WireModelsListRequest{
            .selectionId = options.selection_id,
            .gitHubToken = options.github_token,
        });
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
        if (self.dispatching_rpc_handler) return error.ReentrantRpcCall;
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
                    try self.dispatchServerRequest(
                        &self.writer.interface,
                        request_id,
                        name,
                        object.get("params"),
                    );
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
        if (std.mem.eql(u8, method, "providerToken.getToken")) {
            return self.dispatchProviderTokenRequest(writer, id, params);
        }
        if (std.mem.eql(u8, method, "userInput.request") and
            self.findUserInputHandlerFromParams(params) != null)
        {
            return self.dispatchUserInputRequest(writer, id, params);
        }
        const registered = self.findRpcHandler(method) orelse {
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
            try json_rpc.writeFrame(writer, response);
            return;
        };
        defer result.deinit();
        const response = try json_rpc.encodeSuccessResponse(self.allocator, id, result.value);
        defer self.allocator.free(response);
        try json_rpc.writeFrame(writer, response);
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
    ) !void {
        const value = params orelse
            return self.writeServerRequestError(writer, id, -32602, "invalid user input request");
        const parsed = std.json.parseFromValue(
            WireUserInputRequest,
            self.allocator,
            value,
            .{ .ignore_unknown_fields = true },
        ) catch {
            return self.writeServerRequestError(writer, id, -32602, "invalid user input request");
        };
        defer parsed.deinit();

        const registered = self.findUserInputHandler(parsed.value.sessionId) orelse
            return self.writeServerRequestError(writer, id, -32000, "user input handler not registered");

        self.dispatching_rpc_handler = true;
        defer self.dispatching_rpc_handler = false;
        const response = registered.handler(self.allocator, .{
            .session_id = parsed.value.sessionId,
            .question = parsed.value.question,
            .choices = parsed.value.choices,
            .allow_freeform = parsed.value.allowFreeform,
        }, registered.context) catch |err| {
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

    fn findProviderToken(
        self: *Client,
        session_id: []const u8,
        provider_name: []const u8,
    ) ?provider.BearerTokenProvider {
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
                try self.dispatchServerRequest(
                    &self.writer.interface,
                    request_id,
                    method,
                    object.get("params"),
                );
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
                    event = .{ .session_idle = .{} };
                },
                .session_idle => |idle| {
                    if (completesSendAndWait(idle)) return response;
                },
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
                        .{ .handler_failed = err };
                    return event;
                };
                switch (decision) {
                    .approve_once => self.approvePermission(request.request_id) catch |err| {
                        event.permission_requested.automatic_handling =
                            .{ .delivery_failed = err };
                        return event;
                    },
                    .reject => |feedback| self.rejectPermission(request.request_id, feedback) catch |err| {
                        event.permission_requested.automatic_handling =
                            .{ .delivery_failed = err };
                        return event;
                    },
                    .json => |decision_json| self.respondToPermissionJson(
                        request.request_id,
                        decision_json,
                        null,
                    ) catch |err| {
                        event.permission_requested.automatic_handling =
                            .{ .delivery_failed = err };
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

    pub fn disconnect(self: Session) !void {
        for (0..2) |_| {
            const parsed = try self.client.call(struct {
                success: bool,
                @"error": ?[]const u8 = null,
            }, "session.detach", .{
                .sessionId = self.id,
            });
            defer parsed.deinit();
            if (parsed.value.success) {
                self.client.removeSession(self.id);
                return;
            }
        }
        return error.SessionDetachFailed;
    }

    pub fn setAutoTier(
        self: Session,
        auto_tier: ?session_types.AutoTier,
    ) !session_types.AutoTierSwitchResult {
        const parsed = try self.client.call(
            session_types.AutoTierSwitchResult,
            "session.model.switchAutoTier",
            .{
                .sessionId = self.id,
                .autoTier = if (auto_tier) |tier|
                    std.json.Value{ .string = @tagName(tier) }
                else
                    std.json.Value.null,
            },
        );
        defer parsed.deinit();
        return parsed.value;
    }

    /// Aborts the current agent turn. The caller owns the returned result.
    pub fn abort(self: Session) !std.json.Parsed(session_types.AbortResult) {
        return self.client.call(session_types.AbortResult, "session.abort", .{
            .sessionId = self.id,
        });
    }

    /// Changes the selected model for subsequent turns. The caller owns the
    /// returned result.
    pub fn setModel(
        self: Session,
        model_id: []const u8,
        options: session_types.ModelSwitchOptions,
    ) !std.json.Parsed(session_types.ModelSwitchResult) {
        return self.client.call(
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
        );
    }

    /// Emits a user-visible timeline entry and returns its event ID.
    pub fn log(
        self: Session,
        message: []const u8,
        options: session_types.LogOptions,
    ) ![]u8 {
        const parsed = try self.client.call(struct { eventId: []const u8 }, "session.log", WireLogRequest{
            .sessionId = self.id,
            .message = message,
            .level = options.level,
            .type = options.log_type,
            .ephemeral = options.ephemeral,
            .url = options.url,
            .tip = options.tip,
        });
        defer parsed.deinit();
        return self.client.allocator.dupe(u8, parsed.value.eventId);
    }

    pub fn approvePermission(self: Session, request_id: []const u8) !void {
        const parsed = try self.client.call(RpcSuccess, "session.permissions.handlePendingPermissionRequest", .{
            .sessionId = self.id,
            .requestId = request_id,
            .result = .{ .kind = "approve-once" },
        });
        defer parsed.deinit();
        if (!parsed.value.success) return error.PermissionDecisionNotAccepted;
    }

    pub fn rejectPermission(
        self: Session,
        request_id: []const u8,
        feedback: ?[]const u8,
    ) !void {
        const parsed = try self.client.call(RpcSuccess, "session.permissions.handlePendingPermissionRequest", .{
            .sessionId = self.id,
            .requestId = request_id,
            .result = .{ .kind = "reject", .feedback = feedback },
        });
        defer parsed.deinit();
        if (!parsed.value.success) return error.PermissionDecisionNotAccepted;
    }

    pub fn respondToPermissionJson(
        self: Session,
        request_id: []const u8,
        decision_json: []const u8,
        decision_context_json: ?[]const u8,
    ) !void {
        const decision = try std.json.parseFromSlice(
            std.json.Value,
            self.client.allocator,
            decision_json,
            .{},
        );
        defer decision.deinit();
        if (decision.value != .object) return error.InvalidPermissionDecision;

        const decision_context = if (decision_context_json) |context_json|
            try std.json.parseFromSlice(
                std.json.Value,
                self.client.allocator,
                context_json,
                .{},
            )
        else
            null;
        defer if (decision_context) |context| context.deinit();
        if (decision_context) |context| {
            if (context.value != .object) return error.InvalidPermissionDecisionContext;
        }

        const parsed = if (decision_context) |context|
            try self.client.call(
                RpcSuccess,
                "session.permissions.handlePendingPermissionRequest",
                .{
                    .sessionId = self.id,
                    .requestId = request_id,
                    .result = decision.value,
                    .decisionContext = context.value,
                },
            )
        else
            try self.client.call(
                RpcSuccess,
                "session.permissions.handlePendingPermissionRequest",
                .{
                    .sessionId = self.id,
                    .requestId = request_id,
                    .result = decision.value,
                },
            );
        defer parsed.deinit();
        if (!parsed.value.success) return error.PermissionDecisionNotAccepted;
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

    pub fn respondToToolResultJson(
        self: Session,
        request_id: []const u8,
        result_json: []const u8,
    ) !void {
        const result = try std.json.parseFromSlice(
            std.json.Value,
            self.client.allocator,
            result_json,
            .{},
        );
        defer result.deinit();
        const object = switch (result.value) {
            .object => |object| object,
            else => return error.InvalidToolResult,
        };
        const text = object.get("textResultForLlm") orelse return error.InvalidToolResult;
        if (text != .string) return error.InvalidToolResult;

        const parsed = try self.client.call(
            struct { success: bool },
            "session.tools.handlePendingToolCall",
            .{
                .sessionId = self.id,
                .requestId = request_id,
                .result = result.value,
            },
        );
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
    providers: ?[]const provider.WireNamedProvider,
    models: ?[]const provider.WireProviderModel,
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

fn buildPreparedCreateSessionRequest(
    session_id: ?[]const u8,
    config: session_types.SessionConfig,
    tools: []const WireTool,
    prepared_providers: provider.PreparedProviders,
) !CreateSessionRequest {
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

fn buildPreparedResumeSessionRequest(
    session_id: []const u8,
    config: session_types.SessionConfig,
    tools: []const WireTool,
    prepared_providers: provider.PreparedProviders,
) !ResumeSessionRequest {
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
    try client.dispatchServerRequest(
        &success_output.writer,
        .{ .integer = 1 },
        "test.success",
        .{ .object = success_params },
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
        \\{"sessionId":"session-1","question":"Continue?","choices":["Yes","No"],"allowFreeform":true,"futureField":"accepted"}
    ,
        .{},
    );
    defer parsed_params.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try client.dispatchServerRequest(
        &output.writer,
        .{ .integer = 3 },
        "userInput.request",
        parsed_params.value,
    );

    try std.testing.expect(called);
    const body = try framedBody(allocator, output.written());
    defer allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"answer\":\"Yes\",\"wasFreeform\":false}}",
        body,
    );
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
        .event = try session_types.parseEvent(allocator, parsed_event.value),
    });

    const session = Session{ .client = &client, .id = "session-1" };
    var event = try session.nextEvent();
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
    var event = try session.nextEvent();
    defer event.deinit(allocator);
    try std.testing.expectEqualStrings("permission-1", event.permission_requested.request_id);
    switch (event.permission_requested.automatic_handling) {
        .handler_failed => |err| try std.testing.expectEqual(
            error.PermissionHandlerFailed,
            err,
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
    var first = try managed_session.nextEvent();
    defer first.deinit(allocator);
    try std.testing.expectEqualStrings("permission-1", first.permission_requested.request_id);
    switch (first.permission_requested.automatic_handling) {
        .handler_failed => |err| try std.testing.expectEqual(
            error.ApproveAllWithManagedSettings,
            err,
        ),
        else => return error.TestExpectedHandlerFailure,
    }

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
    var event = try session.nextEvent();
    defer event.deinit(allocator);

    const request_frame = try tmp.dir.readFileAlloc(
        std.testing.io,
        "request",
        allocator,
        .limited(4096),
    );
    return .{
        .handling = event.permission_requested.automatic_handling,
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
        .delivery_failed => |err| try std.testing.expectEqual(
            error.PermissionDecisionNotAccepted,
            err,
        ),
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
    var event = try session.nextEvent();
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
    const config = session_types.SessionConfig{
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

test "resume request places provider in params and disables nested resume" {
    const allocator = std.testing.allocator;
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
        config,
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
                .protocol = .{ .openai = .responses },
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
            prepared,
        ),
    );
    defer allocator.free(create);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"session.create\",\"params\":{\"sessionId\":\"session-provider-graph\",\"providers\":[{\"name\":\"openai\",\"type\":\"openai\",\"wireApi\":\"responses\",\"baseUrl\":\"https://api.openai.com/v1\",\"apiKey\":\"key\",\"bearerToken\":\"static\",\"headers\":{\"X-Tenant\":\"acme\"},\"hasBearerTokenProvider\":true}],\"models\":[{\"id\":\"reasoner\",\"provider\":\"openai\",\"wireModel\":\"deployment\",\"modelId\":\"gpt-4.1\",\"name\":\"Reasoner\",\"maxPromptTokens\":100,\"maxContextWindowTokens\":200,\"maxOutputTokens\":50,\"capabilities\":{\"supports\":{\"reasoningEffort\":true}}}],\"streaming\":false,\"tools\":[],\"toolFilterPrecedence\":\"excluded\",\"requestPermission\":false,\"requestUserInput\":false,\"enableManagedSettings\":false}}",
        create,
    );

    const resume_encoded = try json_rpc.encodeRequest(
        allocator,
        22,
        "session.resume",
        try buildPreparedResumeSessionRequest(
            "session-provider-graph",
            config,
            &.{},
            prepared,
        ),
    );
    defer allocator.free(resume_encoded);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":22,\"method\":\"session.resume\",\"params\":{\"sessionId\":\"session-provider-graph\",\"providers\":[{\"name\":\"openai\",\"type\":\"openai\",\"wireApi\":\"responses\",\"baseUrl\":\"https://api.openai.com/v1\",\"apiKey\":\"key\",\"bearerToken\":\"static\",\"headers\":{\"X-Tenant\":\"acme\"},\"hasBearerTokenProvider\":true}],\"models\":[{\"id\":\"reasoner\",\"provider\":\"openai\",\"wireModel\":\"deployment\",\"modelId\":\"gpt-4.1\",\"name\":\"Reasoner\",\"maxPromptTokens\":100,\"maxContextWindowTokens\":200,\"maxOutputTokens\":50,\"capabilities\":{\"supports\":{\"reasoningEffort\":true}}}],\"streaming\":false,\"tools\":[],\"toolFilterPrecedence\":\"excluded\",\"requestPermission\":false,\"requestUserInput\":false,\"enableManagedSettings\":false,\"disableResume\":true}}",
        resume_encoded,
    );
}

test "singular create request encodes every provider field and default callback routing" {
    const allocator = std.testing.allocator;
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
        try buildPreparedCreateSessionRequest("singular", config, &.{}, prepared),
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
        try buildPreparedResumeSessionRequest("singular", config, &.{}, prepared),
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

    const create_config = session_types.SessionConfig{
        .on_permission_request = permission_handler,
        .on_user_input_request = user_input_handler,
    };
    const create_params = try buildPreparedCreateSessionRequest(
        create_config.session_id,
        create_config,
        &.{},
        .{},
    );
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

    const resume_config = session_types.SessionConfig{
        .on_permission_request = permission_handler,
        .on_user_input_request = user_input_handler,
    };
    const resume_params = try buildPreparedResumeSessionRequest(
        "session-1",
        resume_config,
        &.{},
        .{},
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
            try buildPreparedCreateSessionRequest(
                null,
                .{
                    .enable_config_discovery = case.value,
                    .enable_skills = case.value,
                    .skip_custom_instructions = case.value,
                    .enable_on_demand_instruction_discovery = case.value,
                },
                &.{},
                .{},
            ),
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
            try buildPreparedResumeSessionRequest(
                "session-1",
                .{
                    .enable_config_discovery = case.value,
                    .enable_skills = case.value,
                    .skip_custom_instructions = case.value,
                    .enable_on_demand_instruction_discovery = case.value,
                },
                &.{},
                .{},
            ),
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
        try buildPreparedCreateSessionRequest(
            null,
            .{
                .available_tools = available_tools,
                .excluded_tools = excluded_tools,
            },
            &.{},
            .{},
        ),
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
        try buildPreparedResumeSessionRequest(
            "session-1",
            .{
                .available_tools = available_tools,
                .excluded_tools = excluded_tools,
            },
            &.{},
            .{},
        ),
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
        try buildPreparedCreateSessionRequest(
            null,
            .{
                .skill_directories = skill_directories,
                .instruction_directories = instruction_directories,
            },
            &.{},
            .{},
        ),
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
        try buildPreparedResumeSessionRequest(
            "session-1",
            .{
                .skill_directories = skill_directories,
                .instruction_directories = instruction_directories,
            },
            &.{},
            .{},
        ),
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
        try buildPreparedCreateSessionRequest(null, .{}, &.{}, .{}),
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
        try buildPreparedResumeSessionRequest("session-1", .{}, &.{}, .{}),
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
        try buildPreparedCreateSessionRequest(config.session_id, config, &.{}, .{}),
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
        try buildPreparedResumeSessionRequest("session-1", config, &.{}, .{}),
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
        try buildPreparedCreateSessionRequest(
            fetched_config.session_id,
            fetched_config,
            &.{},
            .{},
        ),
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
        try buildPreparedResumeSessionRequest("session-1", fetched_config, &.{}, .{}),
    );
    defer allocator.free(fetched_resume_encoded);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":16,\"method\":\"session.resume\",\"params\":{\"sessionId\":\"session-1\",\"streaming\":false,\"tools\":[],\"toolFilterPrecedence\":\"excluded\",\"requestPermission\":true,\"requestUserInput\":false,\"enableManagedSettings\":true,\"disableResume\":true}}",
        fetched_resume_encoded,
    );
}

test "session requests omit a null provider" {
    const allocator = std.testing.allocator;
    const create_params = try buildPreparedCreateSessionRequest(null, .{}, &.{}, .{});
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
    try std.testing.expect(
        !create_parsed.value.object.get("params").?.object.contains("providers"),
    );
    try std.testing.expect(
        !create_parsed.value.object.get("params").?.object.contains("models"),
    );

    const resume_params = try buildPreparedResumeSessionRequest("session-1", .{}, &.{}, .{});
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
    try std.testing.expect(
        !resume_parsed.value.object.get("params").?.object.contains("providers"),
    );
    try std.testing.expect(
        !resume_parsed.value.object.get("params").?.object.contains("models"),
    );
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
        client.user_input_handlers.deinit(allocator);
        client.permission_handlers.deinit(allocator);
        for (client.provider_tokens.items) |registered| registered.deinit(allocator);
        client.provider_tokens.deinit(allocator);
        for (client.session_ids.items) |id| allocator.free(id);
        client.session_ids.deinit(allocator);
    }

    try client.registerOwnedSession(
        try allocator.dupe(u8, "s1"),
        .{},
        &.{.{
            .provider_name = "provider",
            .token_provider = .{ .callback = failingProviderTokenCallback },
        }},
    );
    try client.events.append(allocator, .{
        .session_id = try allocator.dupe(u8, "s1"),
        .event = .{ .session_idle = .{} },
    });

    client.removeSession("s1");
    client.removeSession("s1");

    try std.testing.expectEqual(@as(usize, 0), client.session_ids.items.len);
    try std.testing.expectEqual(@as(usize, 0), client.events.items.len);
    try std.testing.expectEqual(@as(usize, 0), client.provider_tokens.items.len);
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
    for (client.events.items) |*event| event.deinit(client.allocator);
    client.events.deinit(client.allocator);
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
    const resume_response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}";
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
            .expected = "{\"jsonrpc\":\"2.0\",\"id\":64,\"error\":{\"code\":-32000,\"message\":\"bearer token provider not registered\"}}",
        },
        .{
            .id = 65,
            .params_json = "{\"sessionId\":\"session-two\"}",
            .expected = "{\"jsonrpc\":\"2.0\",\"id\":65,\"error\":{\"code\":-32602,\"message\":\"invalid provider token request\"}}",
        },
        .{
            .id = 66,
            .params_json = "{\"sessionId\":\"session-two\",\"providerName\":\"shared\",\"extra\":true}",
            .expected = "{\"jsonrpc\":\"2.0\",\"id\":66,\"error\":{\"code\":-32602,\"message\":\"invalid provider token request\"}}",
        },
        .{
            .id = 67,
            .params_json = null,
            .expected = "{\"jsonrpc\":\"2.0\",\"id\":67,\"error\":{\"code\":-32602,\"message\":\"invalid provider token request\"}}",
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

    try std.testing.expectError(error.EventQueueFull, client.queueSessionEvent(parsed.value));
}
