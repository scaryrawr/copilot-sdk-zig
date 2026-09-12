const std = @import("std");
const json_rpc = @import("json_rpc.zig");
const models = @import("models.zig");
const provider = @import("provider.zig");
const protocol = @import("protocol_version.zig");
const session_types = @import("session.zig");
const ext = @import("extensibility.zig");

const max_queued_events: usize = 1024;

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
    extension_runtimes: std.ArrayList(SessionExtensionRuntime) = .empty,
    pending_extension_runtime: ?SessionExtensionRuntime = null,
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
        try client.setBuiltinPluginDirectories(options.builtin_plugin_directories);
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
        if (self.pending_extension_runtime) |*runtime| {
            self.releaseMcpOAuthInterest(runtime) catch {};
        }
        for (self.extension_runtimes.items) |*runtime| {
            self.releaseMcpOAuthInterest(runtime) catch {};
        }
        for (self.events.items) |*event| event.deinit(self.allocator);
        self.events.deinit(self.allocator);
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

    fn wipeTransportBuffers(self: *Client) void {
        wipeSecret(self.reader_buffer);
        wipeSecret(self.writer_buffer);
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
        try ext.validate(config.extensions.common);
        var parsed_parameters: std.ArrayList(std.json.Parsed(std.json.Value)) = .empty;
        defer {
            for (parsed_parameters.items) |parsed| parsed.deinit();
            parsed_parameters.deinit(self.allocator);
        }
        var tools: std.ArrayList(WireTool) = .empty;
        defer tools.deinit(self.allocator);
        try appendWireTools(self.allocator, config.tools, &parsed_parameters, &tools);
        try self.beginExtensionRuntime(null, config, &.{});
        errdefer self.rollbackExtensionRuntime();

        var extension_values = ExtensionWireValues.init(self.allocator);
        defer extension_values.deinit();
        try extension_values.lower(config.extensions.common);
        const request = try buildCreateSessionRequest(config, tools.items, &extension_values);
        const parsed = try self.call(
            WireSessionLifecycleResponse,
            "session.create",
            request,
        );
        defer {
            wipeLifecycleResponseSecrets(parsed.value);
            parsed.deinit();
        }
        const returned_id = parsed.value.sessionId orelse return error.MissingSessionId;
        errdefer {
            self.rollbackExtensionRuntime();
            self.detachSessionBestEffort(returned_id);
        }

        const id = try self.allocator.dupe(u8, returned_id);
        self.session_ids.append(self.allocator, id) catch |err| {
            self.allocator.free(id);
            return err;
        };
        errdefer self.removeSessionId(id);
        try self.commitExtensionRuntime(returned_id, parsed.value, &.{});
        return .{ .client = self, .id = id };
    }

    pub fn resumeSession(
        self: *Client,
        session_id: []const u8,
        config: session_types.ResumeSessionConfig,
    ) !Session {
        return self.resumeSessionWithEnvironment(session_id, config, &.{});
    }

    /// Deprecated compatibility wrapper. Use `resumeSession`.
    pub fn joinSession(
        self: *Client,
        session_id: []const u8,
        config: session_types.SessionConfig,
    ) !Session {
        return self.resumeSession(session_id, resumeConfigFromCreate(config));
    }

    fn resumeSessionWithEnvironment(
        self: *Client,
        session_id: []const u8,
        config: session_types.ResumeSessionConfig,
        requested_environment_variables: []const []const u8,
    ) !Session {
        try ext.validate(config.extensions.common);
        const existing_session_id = self.findSessionId(session_id);
        var parsed_parameters: std.ArrayList(std.json.Parsed(std.json.Value)) = .empty;
        defer {
            for (parsed_parameters.items) |parsed| parsed.deinit();
            parsed_parameters.deinit(self.allocator);
        }
        var tools: std.ArrayList(WireTool) = .empty;
        defer tools.deinit(self.allocator);
        try appendWireTools(self.allocator, config.tools, &parsed_parameters, &tools);
        try self.beginExtensionRuntime(
            session_id,
            config,
            config.extensions.open_canvases,
        );
        errdefer self.rollbackExtensionRuntime();

        var extension_values = ExtensionWireValues.init(self.allocator);
        defer extension_values.deinit();
        try extension_values.lower(config.extensions.common);
        const request = try buildResumeSessionRequest(
            session_id,
            config,
            tools.items,
            &extension_values,
            requested_environment_variables,
        );
        const parsed = try self.call(WireSessionLifecycleResponse, "session.resume", request);
        defer {
            wipeLifecycleResponseSecrets(parsed.value);
            parsed.deinit();
        }
        errdefer if (existing_session_id == null) {
            self.rollbackExtensionRuntime();
            self.detachSessionBestEffort(session_id);
        };

        var added_session_id = false;
        const id = existing_session_id orelse id: {
            const copy = try self.allocator.dupe(u8, session_id);
            self.session_ids.append(self.allocator, copy) catch |err| {
                self.allocator.free(copy);
                return err;
            };
            added_session_id = true;
            break :id copy;
        };
        errdefer if (added_session_id) self.removeSessionId(id);
        try self.commitExtensionRuntime(
            session_id,
            parsed.value,
            requested_environment_variables,
        );
        return .{ .client = self, .id = id };
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
            self.releaseMcpOAuthInterest(runtime) catch {};
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
        const session = try self.resumeSessionWithEnvironment(
            session_id,
            resume_config,
            config.extensions.requested_environment_variables,
        );
        const grants = session.snapshotEnvironmentGrants(self.allocator) catch |err| {
            session.disconnect() catch |cleanup_err| {
                if (self.findExtensionRuntime(session.id)) |runtime| {
                    self.releaseMcpOAuthInterest(runtime) catch {};
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
        defer {
            wipeSecret(request);
            self.allocator.free(request);
        }
        try json_rpc.writeFrame(&self.writer.interface, request);
        wipeSecret(self.writer_buffer);

        while (true) {
            const body = try json_rpc.readFrame(self.allocator, &self.reader.interface);
            defer {
                wipeSecret(body);
                self.allocator.free(body);
            }
            const value = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
            defer {
                wipeJsonStrings(value.value);
                value.deinit();
            }
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
            defer {
                wipeSecret(result_json);
                self.allocator.free(result_json);
            }
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
        if (std.mem.eql(u8, method, "hooks.invoke")) {
            return self.dispatchHookRequest(writer, id, params);
        }
        if (std.mem.eql(u8, method, "canvas.open") or
            std.mem.eql(u8, method, "canvas.close") or
            std.mem.eql(u8, method, "canvas.action.invoke"))
        {
            return self.dispatchCanvasRequest(writer, id, method, params);
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
        const response = try json_rpc.encodeSuccessResponse(self.allocator, id, .null);
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
            const args = try stringifyJsonValue(self.allocator, input.get("toolArgs") orelse .null);
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
            const arguments = try stringifyJsonValue(self.allocator, input.get("arguments") orelse .null);
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
            const args = try stringifyJsonValue(self.allocator, input.get("toolArgs") orelse .null);
            defer self.allocator.free(args);
            const tool_result = try stringifyJsonValue(self.allocator, input.get("toolResult") orelse .null);
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
            const args = try stringifyJsonValue(self.allocator, input.get("toolArgs") orelse .null);
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
                .stop_hook_active = (jsonOptionalBool(input, "stopHookActive") catch
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
        const params_json = try stringifyRpcParams(self.allocator, params) orelse
            return self.writeServerRequestError(writer, id, -32602, "invalid user input request");
        defer self.allocator.free(params_json);

        const parsed = std.json.parseFromSlice(
            WireUserInputRequest,
            self.allocator,
            params_json,
            .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
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
        const event_value = params.get("event") orelse return error.InvalidSessionEvent;
        var queued = QueuedEvent{
            .session_id = try self.allocator.dupe(u8, session_id),
            .event = undefined,
        };
        errdefer self.allocator.free(queued.session_id);
        queued.event = try session_types.parseEvent(
            self.allocator,
            event_value,
        );
        errdefer queued.event.deinit(self.allocator);
        self.applyExtensionEvent(session_id, &queued.event);
        try self.events.append(self.allocator, queued);
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
    ) void {
        const runtime = self.findExtensionRuntime(session_id) orelse return;
        const data_json = switch (event.*) {
            .capabilities_changed => |value| value.data_json,
            .session_canvas_closed => |value| value.data_json,
            .session_canvas_opened => |value| value.data_json,
            else => return,
        };
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            data_json,
            .{},
        ) catch return;
        defer parsed.deinit();
        const data = switch (parsed.value) {
            .object => |value| value,
            else => return,
        };
        switch (event.*) {
            .capabilities_changed => {
                const ui = switch (data.get("ui") orelse return) {
                    .object => |value| value,
                    else => return,
                };
                if (ui.get("canvases")) |value| {
                    if (value == .bool) runtime.capabilities.canvases =
                        capabilityState(value.bool);
                }
                if (ui.get("mcpApps")) |value| {
                    if (value == .bool) runtime.capabilities.mcp_apps =
                        capabilityState(value.bool);
                }
            },
            .session_canvas_closed => {
                const instance_id = switch (data.get("instanceId") orelse return) {
                    .string => |value| value,
                    else => return,
                };
                removeOpenCanvas(runtime, self.allocator, instance_id);
            },
            .session_canvas_opened => {
                const canvas_data = std.json.parseFromSlice(
                    WireOpenCanvas,
                    self.allocator,
                    data_json,
                    .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
                ) catch return;
                defer canvas_data.deinit();
                const canvas = cloneWireOpenCanvas(
                    self.allocator,
                    canvas_data.value,
                ) catch return;
                upsertOpenCanvas(runtime, self.allocator, canvas) catch
                    ext.freeOpenCanvas(self.allocator, canvas);
            },
            else => unreachable,
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
            defer {
                wipeSecret(body);
                self.allocator.free(body);
            }
            const value = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
            defer {
                wipeJsonStrings(value.value);
                value.deinit();
            }
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
        if (event == .mcp_oauth_required) {
            try self.handleMcpAuthEvent(event.mcp_oauth_required.data_json);
        }
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
        for (0..2) |_| {
            const parsed = try self.client.call(struct {
                success: bool,
                @"error": ?[]const u8 = null,
            }, "session.detach", .{
                .sessionId = self.id,
            });
            defer parsed.deinit();
            if (parsed.value.success) {
                if (self.client.findExtensionRuntime(self.id)) |runtime| {
                    try self.client.releaseMcpOAuthInterest(runtime);
                }
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

const ExtensionWireValues = struct {
    allocator: std.mem.Allocator,
    json_values: std.ArrayList(std.json.Parsed(std.json.Value)) = .empty,
    canvas_actions: std.ArrayList(WireCanvasAction) = .empty,
    canvases: std.ArrayList(WireCanvas) = .empty,
    open_canvases: std.ArrayList(WireOpenCanvas) = .empty,
    mcp_object: std.json.ObjectMap = .empty,
    mcp_servers: ?std.json.Value = null,

    fn init(allocator: std.mem.Allocator) ExtensionWireValues {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *ExtensionWireValues) void {
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
        .model_capabilities = config.model_capabilities,
        .working_directory = config.working_directory,
        .streaming = config.streaming,
        .tools = config.tools,
        .available_tools = config.available_tools,
        .excluded_tools = config.excluded_tools,
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
        .model_capabilities = config.model_capabilities,
        .working_directory = config.working_directory,
        .streaming = config.streaming,
        .tools = config.tools,
        .available_tools = config.available_tools,
        .excluded_tools = config.excluded_tools,
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
    config: session_types.CreateSessionConfig,
    tools: []const WireTool,
    values: *ExtensionWireValues,
) !CreateSessionRequest {
    const features: ext.SessionFeatures = if (@hasField(@TypeOf(config), "extensions"))
        config.extensions.common
    else
        .{};
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
    const features = config.extensions.common;
    const configured_open_canvases = config.extensions.open_canvases;
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
        .openCanvases = if (values.open_canvases.items.len > 0)
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
    _ = &Client.init;
    _ = &Client.initParent;
    _ = &Client.createSession;
    _ = &Client.joinSession;
    _ = &Client.resumeSession;
    _ = &Client.joinParentSession;
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
    _ = &Session.capabilities;
    _ = &Session.experimental;
    _ = &Session.openCanvas;
    _ = &Session.closeCanvas;
    _ = &Session.invokeCanvasAction;
    _ = &Session.snapshotOpenCanvases;
    _ = &McpApps.listTools;
    _ = &McpApps.callTool;
    _ = &McpApps.readResource;
    _ = &Session.approvePermission;
    _ = &Session.rejectPermission;
    _ = &Session.respondToPermissionJson;
    _ = &Session.respondToTool;
    _ = &Session.respondToToolResultJson;
    _ = &Session.respondToToolError;
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
        \\{"sessionId":"session-1","question":"Continue?","choices":["Yes","No"],"allowFreeform":true}
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
    const params = try buildCreateSessionRequest(.{
        .provider = .{
            .base_url = "https://api.openai.com/v1",
            .protocol = .{ .openai = .{ .responses = .websockets } },
            .authentication = .{ .bearer_token = "token" },
        },
    }, &.{}, &extension_values);
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
    const params = try buildResumeSessionRequest("session-1", .{
        .provider = .{
            .base_url = "https://api.anthropic.com",
            .protocol = .anthropic,
            .authentication = .{ .api_key = "key" },
        },
    }, &.{}, &extension_values, &.{});
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
            .writer_buffer = &writer_buffer,
        };
        defer {
            for (client.session_ids.items) |id| allocator.free(id);
            client.session_ids.deinit(allocator);
            for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
            client.extension_runtimes.deinit(allocator);
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
            .{ model_and_provider, case.wire, defaults },
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
    client.applyExtensionEvent("s1", &session_event);
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
    };
    try client.beginExtensionRuntime(null, session_types.CreateSessionConfig{
        .extensions = .{ .common = .{ .hooks = .{
            .on_post_tool_use = handlers.postTool,
            .on_pre_mcp_tool_call = handlers.preMcp,
        } } },
    }, &.{});
    const params = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"sessionId":"s1","hookType":"postToolUse","input":{"sessionId":"s1","timestamp":42,"cwd":"/repo","toolArgs":{},"toolResult":{}}}
    ,
        .{},
    );
    defer params.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    try client.dispatchServerRequest(
        &output.writer,
        .{ .integer = 9 },
        "hooks.invoke",
        params.value,
    );

    const body = try framedBody(allocator, output.written());
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"code\":-32602") != null);

    const optional_params = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"sessionId":"s1","hookType":"preMcpToolCall","input":{"sessionId":"s1","timestamp":42,"cwd":"/repo","toolCallId":42,"serverName":"server","toolName":"tool","arguments":{}}}
    ,
        .{},
    );
    defer optional_params.deinit();
    var optional_output: std.Io.Writer.Allocating = .init(allocator);
    defer optional_output.deinit();
    try client.dispatchServerRequest(
        &optional_output.writer,
        .{ .integer = 10 },
        "hooks.invoke",
        optional_params.value,
    );
    const optional_body = try framedBody(allocator, optional_output.written());
    defer allocator.free(optional_body);
    try std.testing.expect(
        std.mem.indexOf(u8, optional_body, "\"code\":-32602") != null,
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

    try std.testing.expectError(error.EventQueueFull, client.queueSessionEvent(parsed.value));
}
