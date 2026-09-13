const std = @import("std");
const json_rpc = @import("json_rpc.zig");
const models = @import("models.zig");
const provider = @import("provider.zig");
const protocol = @import("protocol_version.zig");
const session_types = @import("session.zig");
const event_log = @import("event_log.zig");
const turn_tracker = @import("turn_tracker.zig");
const ext = @import("extensibility.zig");

const retained_event_limit: usize = 64;
const event_subscriber_limit: usize = 16;
const retained_log_limit: usize = 128;
const event_ingress_limit: usize = 256;
const detached_send_limit: usize = 64;

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

const PendingCall = struct {
    id: u64,
    completed: std.Io.Event = .unset,
    response: ?[]u8 = null,
    failure: ?anyerror = null,
};

const QueuedSessionEvent = struct {
    log: *event_log.EventLog,
    event: session_types.SessionEvent,
};

const EventLogLease = struct {
    client: *Client,
    log: *event_log.EventLog,
    active: bool = true,

    fn clone(self: EventLogLease) EventLogLease {
        std.debug.assert(self.active);
        self.log.retainOperation();
        return .{ .client = self.client, .log = self.log };
    }

    fn deinit(self: *EventLogLease) void {
        if (!self.active) return;
        self.active = false;
        self.log.releaseOperation();
        self.client.reclaimClosedEventLogs();
    }
};

const CallbackLease = struct {
    client: *Client,
    log: ?*event_log.EventLog,
    active: bool = true,

    fn deinit(self: *CallbackLease) void {
        if (!self.active) return;
        self.active = false;
        self.client.releaseCallback(self.log);
    }
};

const CallbackOrigin = struct {
    log: ?*event_log.EventLog,
    generation: u64,
    admitted: bool,
};

fn AcquiredCallback(comptime T: type) type {
    return struct {
        value: T,
        lease: CallbackLease,
    };
}

const SendOperationOwner = enum {
    waiter,
    reaper,
};

const SendOperation = struct {
    client: *Client,
    log_lease: EventLogLease,
    receipt: turn_tracker.ReceiptToken,
    request_id: u64,
    request: []u8,
    owner: SendOperationOwner = .waiter,
    completed: std.Io.Event = .unset,
    failure: ?anyerror = null,
    future: ?std.Io.Future(anyerror!void) = null,
};

const SessionRemoval = struct {
    client: *Client,
    session_id: []u8,
    log_lease: EventLogLease,
    owner: SendOperationOwner = .waiter,
    completed: std.Io.Event = .unset,
    future: ?std.Io.Future(anyerror!void) = null,
};

const RegisteredTool = struct {
    session_id: []const u8,
    generation: u64 = 0,
    name: []u8,
    handler: session_types.ToolHandler,
    context: ?*anyopaque,

    fn deinit(self: RegisteredTool, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

const RegisteredUserInputHandler = struct {
    session_id: []const u8,
    generation: u64 = 0,
    handler: session_types.UserInputHandler,
    context: ?*anyopaque,
};

const RegisteredPermissionHandler = struct {
    session_id: []const u8,
    generation: u64 = 0,
    handler: session_types.PermissionHandler,
    managed_settings_enabled: bool,
    context: ?*anyopaque,
};

const RegisteredMcpAuthHandler = struct {
    handler: ext.McpAuthHandler,
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
    generation: u64 = 0,
    accepting_callbacks: bool = true,
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
    generation: u64 = 0,
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
    source: ?[]const u8 = null,
    attachments: ?WireAttachments = null,
    mode: ?session_types.MessageDeliveryMode = null,
    agentMode: ?session_types.AgentMode = null,
    requestHeaders: ?WireRequestHeaders = null,
    displayPrompt: ?[]const u8 = null,
};

const WireAttachments = struct {
    values: []const session_types.MessageAttachment,

    pub fn jsonStringify(self: WireAttachments, writer: anytype) !void {
        try writer.beginArray();
        for (self.values) |value| {
            try writer.write(WireAttachment{ .value = value });
        }
        try writer.endArray();
    }
};

const WireAttachment = struct {
    value: session_types.MessageAttachment,

    pub fn jsonStringify(self: WireAttachment, writer: anytype) !void {
        switch (self.value) {
            .file => |value| try writer.write(.{
                .type = "file",
                .path = value.path,
                .displayName = value.display_name,
            }),
            .directory => |value| try writer.write(.{
                .type = "directory",
                .path = value.path,
                .displayName = value.display_name,
            }),
            .selection => |value| try writer.write(.{
                .type = "selection",
                .filePath = value.file_path,
                .displayName = value.display_name,
                .selection = value.selection,
                .text = value.text,
            }),
            .blob => |value| try writer.write(.{
                .type = "blob",
                .data = value.data,
                .mimeType = value.mime_type,
                .displayName = value.display_name,
            }),
        }
    }
};

const WireRequestHeaders = struct {
    values: []const session_types.RequestHeader,

    pub fn jsonStringify(self: WireRequestHeaders, writer: anytype) !void {
        try writer.beginObject();
        for (self.values) |header| {
            try writer.objectField(header.name);
            try writer.write(header.value);
        }
        try writer.endObject();
    }
};

fn lowerMessage(
    session_id: []const u8,
    options: session_types.MessageOptions,
    source: ?[]const u8,
) WireSendRequest {
    return .{
        .sessionId = session_id,
        .prompt = options.prompt,
        .source = source,
        .attachments = if (options.attachments) |values|
            .{ .values = values }
        else
            null,
        .mode = options.mode,
        .agentMode = options.agent_mode,
        .requestHeaders = if (options.request_headers) |values|
            .{ .values = values }
        else
            null,
        .displayPrompt = options.display_prompt,
    };
}

fn validateMessageOptions(options: session_types.MessageOptions) !void {
    if (options.source) |source| switch (source) {
        .agent => |name| if (name.len == 0) return error.InvalidMessageSource,
        else => {},
    };
    if (options.request_headers) |headers| {
        for (headers, 0..) |header, index| {
            if (!isValidHeaderName(header.name)) return error.InvalidRequestHeaderName;
            for (headers[0..index]) |previous| {
                if (std.ascii.eqlIgnoreCase(previous.name, header.name))
                    return error.DuplicateRequestHeader;
            }
        }
    }
}

fn isValidHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
            else => return false,
        }
    }
    return true;
}

fn generationsMatch(stored: u64, requested: u64) bool {
    return stored == requested or stored == 0 or requested == 0;
}

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
    event_logs: std.ArrayList(*event_log.EventLog) = .empty,
    next_event_log_generation: u64 = 1,
    pending_calls: std.ArrayList(*PendingCall) = .empty,
    pending_mutex: std.Io.Mutex = .init,
    writer_mutex: std.Io.Mutex = .init,
    event_logs_mutex: std.Io.Mutex = .init,
    registry_mutex: std.Io.Mutex = .init,
    registry_teardown_mutex: std.Io.Mutex = .init,
    accepting_callbacks: bool = true,
    active_callbacks: usize = 0,
    callbacks_drained: std.Io.Event = .is_set,
    event_queue_mutex: std.Io.Mutex = .init,
    event_queue_ready: std.Io.Event = .unset,
    event_queue: std.ArrayList(QueuedSessionEvent) = .empty,
    event_processor_future: ?std.Io.Future(anyerror!void) = null,
    event_processor_closing: bool = false,
    send_operations_mutex: std.Io.Mutex = .init,
    send_operations: std.ArrayList(*SendOperation) = .empty,
    send_reaper_ready: std.Io.Event = .unset,
    send_reaper_future: ?std.Io.Future(anyerror!void) = null,
    send_reaper_closing: bool = false,
    session_removals_mutex: std.Io.Mutex = .init,
    session_removals: std.ArrayList(*SessionRemoval) = .empty,
    session_removal_reaper_ready: std.Io.Event = .unset,
    session_removal_reaper_future: ?std.Io.Future(anyerror!void) = null,
    session_removal_reaper_closing: bool = false,
    pump_future: ?std.Io.Future(anyerror!void) = null,
    pump_failure: ?anyerror = null,
    ignore_eof: bool = false,
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
        self.event_logs_mutex.lockUncancelable(self.io);
        for (self.event_logs.items) |log| log.beginClose();
        self.event_logs_mutex.unlock(self.io);
        self.stopEventProcessor();
        self.stopSessionRemovalReaper();
        self.finishSessionRemovals();
        self.registry_mutex.lockUncancelable(self.io);
        self.accepting_callbacks = false;
        self.registry_mutex.unlock(self.io);
        self.waitCallbacksDrained();
        if (self.pending_extension_runtime) |*runtime| {
            self.releaseMcpOAuthInterest(runtime) catch {};
        }
        for (self.extension_runtimes.items) |*runtime| {
            self.releaseMcpOAuthInterest(runtime) catch {};
        }
        if (self.pump_future) |*pump| {
            _ = pump.cancel(self.io) catch {};
        }
        self.stopSendReaper();
        self.finishSendOperations();
        for (self.pending_calls.items) |pending| {
            if (pending.response) |response| {
                wipeSecret(response);
                self.allocator.free(response);
            }
        }
        self.pending_calls.deinit(self.allocator);
        self.event_queue.deinit(self.allocator);
        for (self.event_logs.items) |log| {
            log.deinit();
            self.allocator.destroy(log);
        }
        self.event_logs.deinit(self.allocator);
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

    fn wipeTransportBuffers(self: *Client) void {
        wipeSecret(self.reader_buffer);
        wipeSecret(self.writer_buffer);
    }

    fn connect(
        self: *Client,
        token: ?[]const u8,
        client_info: ?ClientInfo,
    ) !void {
        const parsed = try self.bootstrapCall(struct {
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
        const parsed = try self.bootstrapCall(std.json.Value, "plugins.builtin.set", .{
            .paths = directories,
        });
        parsed.deinit();
    }

    pub fn createSession(
        self: *Client,
        config: session_types.CreateSessionConfig,
    ) !Session {
        try validateCustomAgents(config.custom_agents, config.agent);
        try ext.validate(config.extensions.common);
        try validateCustomAgentMcpServers(config.custom_agents);
        try provider.validateCapabilities(config.model_capabilities);

        var prepared_providers = try provider.prepareSessionProviders(
            self.allocator,
            config.provider,
            config.providers,
            config.models,
        );
        defer prepared_providers.deinit(self.allocator);

        const owned_session_id = if (config.session_id) |requested|
            try self.allocator.dupe(u8, requested)
        else
            try generateSessionId(self.allocator, self.io);
        if (self.hasSession(owned_session_id)) {
            self.allocator.free(owned_session_id);
            return error.SessionAlreadyActive;
        }
        self.session_ids.append(self.allocator, owned_session_id) catch |err| {
            self.allocator.free(owned_session_id);
            return err;
        };
        errdefer self.removeSession(owned_session_id);
        const session_log = try self.ensureEventLog(owned_session_id);

        var extension_values = ExtensionWireValues.init(self.allocator);
        defer extension_values.deinit();
        try extension_values.lowerCustomAgents(config.custom_agents);
        var parsed_parameters: std.ArrayList(std.json.Parsed(std.json.Value)) = .empty;
        defer {
            for (parsed_parameters.items) |parsed| parsed.deinit();
            parsed_parameters.deinit(self.allocator);
        }
        var tools: std.ArrayList(WireTool) = .empty;
        defer tools.deinit(self.allocator);
        try appendWireTools(self.allocator, config.tools, &parsed_parameters, &tools);
        try extension_values.lower(config.extensions.common);
        try self.beginProviderTokens(owned_session_id, prepared_providers.token_bindings);
        errdefer self.rollbackProviderTokens();
        try self.beginExtensionRuntime(owned_session_id, config, &.{});
        errdefer self.rollbackExtensionRuntime();

        const request = try buildPreparedCreateSessionRequest(
            owned_session_id,
            config,
            tools.items,
            &extension_values,
            prepared_providers,
        );
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
        if (!std.mem.eql(u8, owned_session_id, returned_id)) {
            if (!self.hasSession(returned_id)) {
                self.detachSessionBestEffort(returned_id);
            }
            return error.SessionIdMismatch;
        }
        errdefer self.detachSessionBestEffort(returned_id);

        try self.commitExtensionRuntime(returned_id, parsed.value, &.{});
        self.commitProviderTokens();
        return .{
            .client = self,
            .id = owned_session_id,
            .generation = session_log.generation,
        };
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
        try validateCustomAgents(config.custom_agents, config.agent);
        try ext.validate(config.extensions.common);
        try validateCustomAgentMcpServers(config.custom_agents);
        try provider.validateCapabilities(config.model_capabilities);

        var prepared_providers = try provider.prepareSessionProviders(
            self.allocator,
            config.provider,
            config.providers,
            config.models,
        );
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
        errdefer if (existing_session_id == null) self.removeSession(runtime_session_id);
        const session_log = try self.ensureEventLog(runtime_session_id);

        var extension_values = ExtensionWireValues.init(self.allocator);
        defer extension_values.deinit();
        try extension_values.lowerCustomAgents(config.custom_agents);
        var parsed_parameters: std.ArrayList(std.json.Parsed(std.json.Value)) = .empty;
        defer {
            for (parsed_parameters.items) |parsed| parsed.deinit();
            parsed_parameters.deinit(self.allocator);
        }
        var tools: std.ArrayList(WireTool) = .empty;
        defer tools.deinit(self.allocator);
        try appendWireTools(self.allocator, config.tools, &parsed_parameters, &tools);
        try extension_values.lower(config.extensions.common);

        try self.beginProviderTokens(runtime_session_id, prepared_providers.token_bindings);
        errdefer self.rollbackProviderTokens();
        try self.beginExtensionRuntime(
            runtime_session_id,
            config,
            config.extensions.open_canvases orelse &.{},
        );
        errdefer self.rollbackExtensionRuntime();

        const request = try buildPreparedResumeSessionRequest(
            runtime_session_id,
            config,
            tools.items,
            &extension_values,
            requested_environment_variables,
            prepared_providers,
        );
        const parsed = try self.call(WireSessionLifecycleResponse, "session.resume", request);
        defer {
            wipeLifecycleResponseSecrets(parsed.value);
            parsed.deinit();
        }
        const returned_id = parsed.value.sessionId orelse return error.MissingSessionId;
        if (!std.mem.eql(u8, runtime_session_id, returned_id)) {
            if (!self.hasSession(returned_id)) {
                self.detachSessionBestEffort(returned_id);
            }
            return error.SessionIdMismatch;
        }
        errdefer if (existing_session_id == null) self.detachSessionBestEffort(returned_id);

        try self.commitExtensionRuntime(
            runtime_session_id,
            parsed.value,
            requested_environment_variables,
        );
        self.commitProviderTokens();
        return .{
            .client = self,
            .id = runtime_session_id,
            .generation = session_log.generation,
        };
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
        try self.registry_mutex.lock(self.io);
        defer self.registry_mutex.unlock(self.io);
        if (self.pending_extension_runtime != null)
            return error.SessionLifecycleAlreadyInProgress;
        self.pending_extension_runtime = try SessionExtensionRuntime.init(
            self.allocator,
            session_id,
            config,
            open_canvases,
        );
        if (session_id) |id| {
            self.pending_extension_runtime.?.generation = self.activeGeneration(id);
        }
    }

    fn rollbackExtensionRuntime(self: *Client) void {
        self.registry_teardown_mutex.lockUncancelable(self.io);
        defer self.registry_teardown_mutex.unlock(self.io);
        self.registry_mutex.lockUncancelable(self.io);
        self.accepting_callbacks = false;
        self.registry_mutex.unlock(self.io);
        self.waitCallbacksDrained();
        self.registry_mutex.lockUncancelable(self.io);
        var runtime = self.pending_extension_runtime;
        self.pending_extension_runtime = null;
        self.accepting_callbacks = true;
        self.registry_mutex.unlock(self.io);
        if (runtime) |*value| {
            self.releaseMcpOAuthInterest(value) catch {};
            value.deinit(self.allocator);
        }
    }

    fn commitExtensionRuntime(
        self: *Client,
        session_id: []const u8,
        response: WireSessionLifecycleResponse,
        requested_environment_variables: []const []const u8,
    ) !void {
        self.registry_teardown_mutex.lockUncancelable(self.io);
        defer self.registry_teardown_mutex.unlock(self.io);
        var register_session_id: ?[]u8 = null;
        defer if (register_session_id) |value| self.allocator.free(value);
        var release_session_id: ?[]u8 = null;
        defer if (release_session_id) |value| self.allocator.free(value);
        var release_handle: ?[]u8 = null;
        defer if (release_handle) |value| self.allocator.free(value);
        var replacing = false;

        {
            try self.registry_mutex.lock(self.io);
            defer self.registry_mutex.unlock(self.io);
            const runtime = if (self.pending_extension_runtime) |*value|
                value
            else
                return error.MissingExtensionRuntime;
            if (runtime.session_id) |id| {
                if (!std.mem.eql(u8, id, session_id)) return error.UnexpectedSessionId;
            } else {
                runtime.session_id = try self.allocator.dupe(u8, session_id);
            }
            runtime.capabilities = parseCapabilities(response.capabilities);
            if (response.openCanvases) |canvases| {
                for (runtime.open_canvases.items) |canvas| {
                    ext.freeOpenCanvas(self.allocator, canvas);
                }
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

            for (self.extension_runtimes.items) |*existing| {
                if (existing.session_id == null or
                    !std.mem.eql(u8, existing.session_id.?, session_id) or
                    !generationsMatch(existing.generation, runtime.generation))
                {
                    continue;
                }
                replacing = true;
                if (existing.mcp_oauth_interest_handle == null and
                    runtime.mcp_auth_handler != null)
                {
                    register_session_id = try self.allocator.dupe(u8, session_id);
                } else if (existing.mcp_oauth_interest_handle) |handle| {
                    if (runtime.mcp_auth_handler == null) {
                        release_session_id = try self.allocator.dupe(u8, session_id);
                        release_handle = try self.allocator.dupe(u8, handle);
                    }
                }
                break;
            }
            if (!replacing) {
                try self.extension_runtimes.ensureUnusedCapacity(self.allocator, 1);
                if (runtime.mcp_auth_handler != null) {
                    register_session_id = try self.allocator.dupe(u8, session_id);
                }
            }
        }

        var registered_handle: ?[]u8 = null;
        errdefer if (registered_handle) |value| {
            self.releaseMcpOAuthHandle(session_id, value) catch {};
            self.allocator.free(value);
        };
        if (register_session_id) |id| {
            registered_handle = try self.registerMcpOAuthHandle(id);
        }
        if (release_session_id) |id| {
            try self.releaseMcpOAuthHandle(id, release_handle.?);
        }

        if (replacing) {
            self.registry_mutex.lockUncancelable(self.io);
            if (self.pending_extension_runtime) |*runtime| {
                runtime.accepting_callbacks = false;
                for (self.extension_runtimes.items) |*existing| {
                    if (existing.session_id == null or
                        !std.mem.eql(u8, existing.session_id.?, session_id) or
                        !generationsMatch(existing.generation, runtime.generation))
                    {
                        continue;
                    }
                    existing.accepting_callbacks = false;
                    break;
                }
            }
            self.registry_mutex.unlock(self.io);
            const generation = self.activeGeneration(session_id);
            if (self.findEventLogGeneration(session_id, generation)) |log| {
                log.waitCallbacksDrainedUncancelable();
            }
        }
        self.registry_mutex.lockUncancelable(self.io);
        defer self.registry_mutex.unlock(self.io);
        const runtime = if (self.pending_extension_runtime) |*value|
            value
        else
            return error.MissingExtensionRuntime;
        runtime.accepting_callbacks = true;
        if (registered_handle) |handle| {
            runtime.mcp_oauth_interest_handle = handle;
            registered_handle = null;
        }
        for (self.extension_runtimes.items, 0..) |*existing, index| {
            if (existing.session_id == null or
                !std.mem.eql(u8, existing.session_id.?, session_id) or
                !generationsMatch(existing.generation, runtime.generation))
            {
                continue;
            }
            if (existing.mcp_oauth_interest_handle != null and
                runtime.mcp_auth_handler != null)
            {
                runtime.mcp_oauth_interest_handle =
                    existing.mcp_oauth_interest_handle;
                existing.mcp_oauth_interest_handle = null;
            }
            const replacement = self.pending_extension_runtime.?;
            self.pending_extension_runtime = null;
            existing.deinit(self.allocator);
            self.extension_runtimes.items[index] = replacement;
            return;
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
        runtime.mcp_oauth_interest_handle = try self.registerMcpOAuthHandle(session_id);
    }

    fn registerMcpOAuthHandle(
        self: *Client,
        session_id: []const u8,
    ) ![]u8 {
        const parsed = try self.call(struct {
            handle: []const u8,
        }, "session.eventLog.registerInterest", .{
            .sessionId = session_id,
            .eventType = "mcp.oauth_required",
        });
        defer parsed.deinit();
        return self.allocator.dupe(u8, parsed.value.handle) catch |err| {
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
        try self.releaseMcpOAuthHandle(session_id, handle);
        self.allocator.free(handle);
        runtime.mcp_oauth_interest_handle = null;
    }

    fn releaseMcpOAuthHandle(
        self: *Client,
        session_id: []const u8,
        handle: []const u8,
    ) !void {
        const parsed = try self.call(struct {
            success: bool,
        }, "session.eventLog.releaseInterest", .{
            .sessionId = session_id,
            .handle = handle,
        });
        defer parsed.deinit();
        if (!parsed.value.success) return error.EventInterestNotReleased;
    }

    fn releaseMcpOAuthInterestForSession(
        self: *Client,
        session_id: []const u8,
        generation: u64,
    ) !bool {
        self.registry_mutex.lockUncancelable(self.io);
        const runtime = self.findExtensionRuntimeGenerationLocked(
            session_id,
            generation,
        ) orelse {
            self.registry_mutex.unlock(self.io);
            return false;
        };
        const handle = runtime.mcp_oauth_interest_handle orelse {
            self.registry_mutex.unlock(self.io);
            return false;
        };
        runtime.mcp_oauth_interest_handle = null;
        const owned_session_id = self.allocator.dupe(u8, session_id) catch |err| {
            runtime.mcp_oauth_interest_handle = handle;
            self.registry_mutex.unlock(self.io);
            return err;
        };
        self.registry_mutex.unlock(self.io);
        defer self.allocator.free(owned_session_id);

        const parsed = self.call(struct {
            success: bool,
        }, "session.eventLog.releaseInterest", .{
            .sessionId = owned_session_id,
            .handle = handle,
        }) catch |err| {
            self.restoreMcpOAuthInterest(owned_session_id, generation, handle);
            return err;
        };
        defer parsed.deinit();
        if (!parsed.value.success) {
            self.restoreMcpOAuthInterest(owned_session_id, generation, handle);
            return error.EventInterestNotReleased;
        }
        self.allocator.free(handle);
        return true;
    }

    fn restoreMcpOAuthInterest(
        self: *Client,
        session_id: []const u8,
        generation: u64,
        handle: []u8,
    ) void {
        self.registry_mutex.lockUncancelable(self.io);
        defer self.registry_mutex.unlock(self.io);
        if (self.findExtensionRuntimeGenerationLocked(session_id, generation)) |runtime| {
            if (runtime.mcp_auth_handler != null and
                runtime.mcp_oauth_interest_handle == null)
            {
                runtime.mcp_oauth_interest_handle = handle;
                return;
            }
        }
        self.allocator.free(handle);
    }

    fn registerMcpOAuthInterestForSession(
        self: *Client,
        session_id: []const u8,
        generation: u64,
    ) !void {
        self.registry_mutex.lockUncancelable(self.io);
        const should_register = if (self.findExtensionRuntimeGenerationLocked(
            session_id,
            generation,
        )) |runtime|
            runtime.mcp_auth_handler != null and runtime.mcp_oauth_interest_handle == null
        else
            false;
        self.registry_mutex.unlock(self.io);
        if (!should_register) return;

        const parsed = try self.call(struct {
            handle: []const u8,
        }, "session.eventLog.registerInterest", .{
            .sessionId = session_id,
            .eventType = "mcp.oauth_required",
        });
        defer parsed.deinit();
        const handle = try self.allocator.dupe(u8, parsed.value.handle);
        self.registry_mutex.lockUncancelable(self.io);
        if (self.findExtensionRuntimeGenerationLocked(session_id, generation)) |runtime| {
            if (runtime.mcp_auth_handler != null and
                runtime.mcp_oauth_interest_handle == null)
            {
                runtime.mcp_oauth_interest_handle = handle;
                self.registry_mutex.unlock(self.io);
                return;
            }
        }
        self.registry_mutex.unlock(self.io);
        defer self.allocator.free(handle);
        const released = try self.call(struct {
            success: bool,
        }, "session.eventLog.releaseInterest", .{
            .sessionId = session_id,
            .handle = handle,
        });
        released.deinit();
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
        const session = try self.resumeSessionWithEnvironment(
            session_id,
            resume_config,
            config.extensions.requested_environment_variables,
        );
        const grants = session.snapshotEnvironmentGrants(self.allocator) catch |err| {
            session.disconnect() catch |cleanup_err| {
                _ = self.releaseMcpOAuthInterestForSession(
                    session.id,
                    session.generation,
                ) catch false;
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
        const id = try self.nextRequestId();
        const request = try json_rpc.encodeRequest(self.allocator, id, method, params);
        defer {
            wipeSecret(request);
            self.allocator.free(request);
        }
        return self.callEncoded(Result, id, request);
    }

    fn callEncoded(
        self: *Client,
        comptime Result: type,
        id: u64,
        request: []const u8,
    ) !std.json.Parsed(Result) {
        var pending = PendingCall{ .id = id };
        try self.pending_mutex.lock(self.io);
        if (self.pump_failure) |err| {
            self.pending_mutex.unlock(self.io);
            return err;
        }
        self.pending_calls.append(self.allocator, &pending) catch |err| {
            self.pending_mutex.unlock(self.io);
            return err;
        };
        self.pending_mutex.unlock(self.io);
        errdefer if (pending.response) |response| {
            wipeSecret(response);
            self.allocator.free(response);
            pending.response = null;
        };
        errdefer self.removePendingCall(&pending);

        try self.writer_mutex.lock(self.io);
        const write_result = writeFrameAndWipe(
            &self.writer.interface,
            self.writer_buffer,
            request,
        );
        self.writer_mutex.unlock(self.io);
        try write_result;
        self.pending_mutex.lockUncancelable(self.io);
        self.ensurePumpLocked();
        self.pending_mutex.unlock(self.io);

        try pending.completed.wait(self.io);
        self.pending_mutex.lockUncancelable(self.io);
        const failure = pending.failure;
        const response = pending.response;
        pending.response = null;
        self.pending_mutex.unlock(self.io);
        self.removePendingCall(&pending);
        if (failure) |err| return err;
        const owned_response = response orelse return error.MissingResponse;
        defer {
            wipeSecret(owned_response);
            self.allocator.free(owned_response);
        }
        return self.parseResponse(Result, id, owned_response);
    }

    fn nextRequestId(self: *Client) !u64 {
        try self.pending_mutex.lock(self.io);
        defer self.pending_mutex.unlock(self.io);
        const id = self.next_request_id;
        self.next_request_id += 1;
        return id;
    }

    fn startSendOperation(
        self: *Client,
        log_lease: EventLogLease,
        receipt: turn_tracker.ReceiptToken,
        options: session_types.MessageOptions,
        source: ?[]const u8,
    ) !*SendOperation {
        const request_id = try self.nextRequestId();
        const request = try json_rpc.encodeRequest(
            self.allocator,
            request_id,
            "session.send",
            lowerMessage(log_lease.log.session_id, options, source),
        );
        errdefer {
            wipeSecret(request);
            self.allocator.free(request);
        }
        const operation = try self.allocator.create(SendOperation);
        errdefer self.allocator.destroy(operation);
        operation.* = .{
            .client = self,
            .log_lease = log_lease.clone(),
            .receipt = receipt,
            .request_id = request_id,
            .request = request,
        };
        errdefer operation.log_lease.deinit();
        self.send_operations_mutex.lockUncancelable(self.io);
        if (self.send_operations.items.len >= detached_send_limit) {
            self.send_operations_mutex.unlock(self.io);
            return error.TooManyPendingSends;
        }
        self.send_operations.append(self.allocator, operation) catch |err| {
            self.send_operations_mutex.unlock(self.io);
            return err;
        };
        if (self.send_reaper_future == null) {
            self.send_reaper_future = self.io.async(sendReaperMain, .{self});
        }
        self.send_operations_mutex.unlock(self.io);
        operation.future = self.io.async(sendOperationMain, .{operation});
        return operation;
    }

    fn sendOperationMain(operation: *SendOperation) anyerror!void {
        defer {
            wipeSecret(operation.request);
            operation.client.allocator.free(operation.request);
            operation.request = &.{};
            operation.completed.set(operation.client.io);
            operation.client.send_reaper_ready.set(operation.client.io);
        }
        const parsed = operation.client.callEncoded(
            struct { messageId: []const u8 },
            operation.request_id,
            operation.request,
        ) catch |err| {
            operation.failure = err;
            operation.log_lease.log.failTurn(operation.receipt, err);
            return;
        };
        defer parsed.deinit();
        operation.log_lease.log.bindTurnMessage(
            operation.receipt,
            parsed.value.messageId,
        ) catch |err| {
            operation.failure = err;
            operation.log_lease.log.failTurn(operation.receipt, err);
        };
    }

    fn destroyClaimedSendOperation(self: *Client, operation: *SendOperation) !void {
        if (operation.future) |*future| try future.await(self.io);
        const failure = operation.failure;
        operation.log_lease.deinit();
        self.allocator.destroy(operation);
        if (failure) |err| return err;
    }

    fn claimCompletedSendOperation(
        self: *Client,
        operation: *SendOperation,
        owner: SendOperationOwner,
    ) ?*SendOperation {
        self.send_operations_mutex.lockUncancelable(self.io);
        defer self.send_operations_mutex.unlock(self.io);
        for (self.send_operations.items, 0..) |candidate, index| {
            if (candidate != operation or
                candidate.owner != owner or
                !candidate.completed.isSet())
            {
                continue;
            }
            return self.send_operations.orderedRemove(index);
        }
        return null;
    }

    fn finishOrDetachSendOperation(
        self: *Client,
        operation: *SendOperation,
    ) union(enum) {
        completed: *SendOperation,
        detached,
    } {
        self.send_operations_mutex.lockUncancelable(self.io);
        defer self.send_operations_mutex.unlock(self.io);
        for (self.send_operations.items, 0..) |candidate, index| {
            if (candidate != operation or candidate.owner != .waiter) continue;
            if (candidate.completed.isSet()) {
                return .{ .completed = self.send_operations.orderedRemove(index) };
            }
            candidate.owner = .reaper;
            self.send_reaper_ready.set(self.io);
            return .detached;
        }
        unreachable;
    }

    fn reapSendOperations(self: *Client) void {
        while (true) {
            self.send_operations_mutex.lockUncancelable(self.io);
            var completed: ?*SendOperation = null;
            for (self.send_operations.items, 0..) |operation, index| {
                if (operation.owner != .reaper or
                    !operation.completed.isSet() or
                    operation.future == null)
                {
                    continue;
                }
                completed = self.send_operations.orderedRemove(index);
                break;
            }
            self.send_operations_mutex.unlock(self.io);
            const operation = completed orelse return;
            self.destroyClaimedSendOperation(operation) catch {};
        }
    }

    fn sendReaperMain(self: *Client) anyerror!void {
        while (true) {
            self.send_operations_mutex.lockUncancelable(self.io);
            if (self.send_reaper_closing) {
                self.send_operations_mutex.unlock(self.io);
                return;
            }
            self.send_reaper_ready.reset();
            self.send_operations_mutex.unlock(self.io);
            self.reapSendOperations();
            try self.send_reaper_ready.wait(self.io);
        }
    }

    fn stopSendReaper(self: *Client) void {
        if (self.send_reaper_future == null) return;
        self.send_operations_mutex.lockUncancelable(self.io);
        self.send_reaper_closing = true;
        self.send_reaper_ready.set(self.io);
        self.send_operations_mutex.unlock(self.io);
        if (self.send_reaper_future) |*future| {
            _ = future.await(self.io) catch {};
            self.send_reaper_future = null;
        }
    }

    fn finishSendOperations(self: *Client) void {
        if (self.send_operations.items.len == 0) {
            self.send_operations.deinit(self.allocator);
            return;
        }
        while (true) {
            self.send_operations_mutex.lockUncancelable(self.io);
            const operation = if (self.send_operations.items.len == 0)
                null
            else
                self.send_operations.orderedRemove(0);
            self.send_operations_mutex.unlock(self.io);
            const value = operation orelse break;
            self.destroyClaimedSendOperation(value) catch {};
        }
        self.send_operations.deinit(self.allocator);
    }

    fn prepareSessionRemoval(
        self: *Client,
        session_id: []const u8,
        generation: u64,
    ) !*SessionRemoval {
        self.session_removals_mutex.lockUncancelable(self.io);
        defer self.session_removals_mutex.unlock(self.io);
        try self.session_removals.ensureUnusedCapacity(self.allocator, 1);
        const removal = try self.allocator.create(SessionRemoval);
        errdefer self.allocator.destroy(removal);
        const owned_session_id = try self.allocator.dupe(u8, session_id);
        errdefer self.allocator.free(owned_session_id);
        const log_lease = self.acquireEventLog(
            session_id,
            generation,
            true,
        ) catch |err| switch (err) {
            error.SessionDisconnected => if (generation == 0) blk: {
                _ = try self.ensureEventLog(session_id);
                break :blk try self.acquireEventLog(session_id, 0, true);
            } else return err,
        };
        removal.* = .{
            .client = self,
            .session_id = owned_session_id,
            .log_lease = log_lease,
        };
        self.session_removals.appendAssumeCapacity(removal);
        return removal;
    }

    fn cancelPreparedSessionRemoval(self: *Client, removal: *SessionRemoval) void {
        self.session_removals_mutex.lockUncancelable(self.io);
        for (self.session_removals.items, 0..) |candidate, index| {
            if (candidate != removal) continue;
            _ = self.session_removals.orderedRemove(index);
            break;
        } else unreachable;
        self.session_removals_mutex.unlock(self.io);
        removal.log_lease.deinit();
        self.allocator.free(removal.session_id);
        self.allocator.destroy(removal);
    }

    fn startSessionRemoval(
        self: *Client,
        removal: *SessionRemoval,
        owner: SendOperationOwner,
    ) void {
        removal.owner = owner;
        removal.log_lease.log.beginClose();
        if (self.retireSessionId(removal.session_id)) |owned_session_id| {
            self.allocator.free(removal.session_id);
            removal.session_id = owned_session_id;
        }
        self.session_removals_mutex.lockUncancelable(self.io);
        if (self.session_removal_reaper_future == null) {
            self.session_removal_reaper_future =
                self.io.async(sessionRemovalReaperMain, .{self});
        }
        self.session_removals_mutex.unlock(self.io);
        removal.future = self.io.async(sessionRemovalMain, .{removal});
    }

    fn finishSessionRemoval(self: *Client, removal: *SessionRemoval) void {
        self.session_removals_mutex.lockUncancelable(self.io);
        for (self.session_removals.items, 0..) |candidate, index| {
            if (candidate != removal or candidate.owner != .waiter) continue;
            _ = self.session_removals.orderedRemove(index);
            break;
        } else unreachable;
        self.session_removals_mutex.unlock(self.io);
        if (removal.future) |*future| _ = future.await(self.io) catch {};
        removal.log_lease.deinit();
        self.allocator.free(removal.session_id);
        self.allocator.destroy(removal);
    }

    fn sessionRemovalMain(removal: *SessionRemoval) anyerror!void {
        defer {
            removal.completed.set(removal.client.io);
            removal.client.session_removal_reaper_ready.set(removal.client.io);
        }
        removal.client.removeSessionWithLog(
            removal.session_id,
            removal.log_lease.log,
        );
        removal.log_lease.deinit();
    }

    fn reapSessionRemovals(self: *Client) void {
        while (true) {
            self.session_removals_mutex.lockUncancelable(self.io);
            var completed: ?*SessionRemoval = null;
            for (self.session_removals.items, 0..) |removal, index| {
                if (removal.owner != .reaper or
                    !removal.completed.isSet() or
                    removal.future == null)
                {
                    continue;
                }
                completed = self.session_removals.orderedRemove(index);
                break;
            }
            self.session_removals_mutex.unlock(self.io);
            const removal = completed orelse return;
            if (removal.future) |*future| _ = future.await(self.io) catch {};
            self.allocator.free(removal.session_id);
            self.allocator.destroy(removal);
        }
    }

    fn sessionRemovalReaperMain(self: *Client) anyerror!void {
        while (true) {
            self.session_removals_mutex.lockUncancelable(self.io);
            if (self.session_removal_reaper_closing) {
                self.session_removals_mutex.unlock(self.io);
                return;
            }
            self.session_removal_reaper_ready.reset();
            self.session_removals_mutex.unlock(self.io);
            self.reapSessionRemovals();
            try self.session_removal_reaper_ready.wait(self.io);
        }
    }

    fn stopSessionRemovalReaper(self: *Client) void {
        if (self.session_removal_reaper_future == null) return;
        self.session_removals_mutex.lockUncancelable(self.io);
        self.session_removal_reaper_closing = true;
        self.session_removal_reaper_ready.set(self.io);
        self.session_removals_mutex.unlock(self.io);
        if (self.session_removal_reaper_future) |*future| {
            _ = future.await(self.io) catch {};
            self.session_removal_reaper_future = null;
        }
    }

    fn finishSessionRemovals(self: *Client) void {
        while (true) {
            self.session_removals_mutex.lockUncancelable(self.io);
            const removal = if (self.session_removals.items.len == 0)
                null
            else
                self.session_removals.orderedRemove(0);
            self.session_removals_mutex.unlock(self.io);
            const value = removal orelse break;
            if (value.future) |*future| _ = future.await(self.io) catch {};
            value.log_lease.deinit();
            self.allocator.free(value.session_id);
            self.allocator.destroy(value);
        }
        self.session_removals.deinit(self.allocator);
    }

    fn ensurePumpLocked(self: *Client) void {
        if (self.pump_future == null) {
            self.pump_future = self.io.async(pumpMain, .{self});
        }
    }

    fn removePendingCall(self: *Client, pending: *PendingCall) void {
        self.pending_mutex.lockUncancelable(self.io);
        defer self.pending_mutex.unlock(self.io);
        for (self.pending_calls.items, 0..) |candidate, index| {
            if (candidate == pending) {
                _ = self.pending_calls.orderedRemove(index);
                return;
            }
        }
    }

    fn parseResponse(
        self: *Client,
        comptime Result: type,
        expected_id: u64,
        body: []const u8,
    ) !std.json.Parsed(Result) {
        const value = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
        defer {
            wipeJsonStrings(value.value);
            value.deinit();
        }
        const object = switch (value.value) {
            .object => |object| object,
            else => return error.InvalidJsonRpc,
        };
        const response_id = object.get("id") orelse return error.InvalidJsonRpc;
        const response_number = switch (response_id) {
            .integer => |number| std.math.cast(u64, number) orelse return error.InvalidJsonRpc,
            else => return error.InvalidJsonRpc,
        };
        if (response_number != expected_id) return error.UnexpectedResponse;
        if (object.get("error")) |rpc_error| {
            if (rpc_error != .null) return error.JsonRpcError;
        }
        const result = object.get("result") orelse return error.MissingResult;
        const result_json = try std.json.Stringify.valueAlloc(self.allocator, result, .{});
        defer {
            wipeSecret(result_json);
            self.allocator.free(result_json);
        }
        return std.json.parseFromSlice(Result, self.allocator, result_json, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
    }

    fn pumpMain(self: *Client) anyerror!void {
        while (true) {
            const body = json_rpc.readFrame(
                self.allocator,
                &self.reader.interface,
            ) catch |err| {
                if ((err == error.EndOfStream or err == error.MissingContentLength) and
                    self.ignore_eof)
                {
                    std.Io.sleep(
                        self.io,
                        std.Io.Duration.fromMilliseconds(1),
                        .awake,
                    ) catch |sleep_err| {
                        self.finishPump(sleep_err);
                        return sleep_err;
                    };
                    continue;
                }
                self.finishPump(err);
                return err;
            };
            defer {
                wipeSecret(body);
                self.allocator.free(body);
            }
            self.routeFrame(body) catch |err| {
                self.finishPump(err);
                return err;
            };
            if (self.ignore_eof) {
                std.Io.sleep(
                    self.io,
                    std.Io.Duration.fromMilliseconds(10),
                    .awake,
                ) catch |err| {
                    self.finishPump(err);
                    return err;
                };
            }
        }
    }

    fn routeFrame(self: *Client, body: []const u8) !void {
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
                try self.writer_mutex.lock(self.io);
                const dispatch_result = self.dispatchServerRequest(
                    &self.writer.interface,
                    request_id,
                    name,
                    object.get("params"),
                );
                self.writer_mutex.unlock(self.io);
                return dispatch_result;
            }
            if (std.mem.eql(u8, name, "session.event")) {
                self.queueSessionEvent(
                    object.get("params") orelse return error.InvalidJsonRpc,
                ) catch |err| switch (err) {
                    error.UnknownSessionEvent, error.SessionDisconnected => return,
                    else => return err,
                };
            }
            return;
        }

        const response_id = object.get("id") orelse return error.InvalidJsonRpc;
        const response_number = switch (response_id) {
            .integer => |number| std.math.cast(u64, number) orelse
                return error.InvalidJsonRpc,
            else => return error.InvalidJsonRpc,
        };
        const owned_response = try self.allocator.dupe(u8, body);
        try self.pending_mutex.lock(self.io);
        for (self.pending_calls.items) |pending| {
            if (pending.id != response_number) continue;
            if (pending.response != null or pending.failure != null) {
                self.pending_mutex.unlock(self.io);
                wipeSecret(owned_response);
                self.allocator.free(owned_response);
                return;
            }
            pending.response = owned_response;
            pending.completed.set(self.io);
            self.pending_mutex.unlock(self.io);
            return;
        }
        self.pending_mutex.unlock(self.io);
        wipeSecret(owned_response);
        self.allocator.free(owned_response);
    }

    fn finishPump(self: *Client, err: anyerror) void {
        self.pending_mutex.lockUncancelable(self.io);
        if (self.pump_failure == null) self.pump_failure = err;
        for (self.pending_calls.items) |pending| {
            if (pending.response == null) pending.failure = self.pump_failure;
            pending.completed.set(self.io);
        }
        self.pending_mutex.unlock(self.io);
        self.event_logs_mutex.lockUncancelable(self.io);
        defer self.event_logs_mutex.unlock(self.io);
        for (self.event_logs.items) |log| log.fail(err);
    }

    fn bootstrapCall(
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
        try writeFrameAndWipe(&self.writer.interface, self.writer_buffer, request);

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
        if (std.mem.eql(u8, method, "providerToken.getToken") and
            self.findProviderTokenFromParams(params) != null)
        {
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
        var acquired = self.acquireSessionHooks(session_id) orelse
            return self.writeServerRequestError(writer, id, -32000, "session not registered");
        defer acquired.lease.deinit();
        const hooks = acquired.value;
        const base = parseHookBase(input) catch
            return self.writeServerRequestError(writer, id, -32602, "invalid hook input");
        const invocation = ext.HookInvocation{ .session_id = session_id };
        self.dispatching_rpc_handler = true;
        defer self.dispatching_rpc_handler = false;

        if (std.mem.eql(u8, hook_type, "preToolUse")) {
            const handler = hooks.on_pre_tool_use orelse
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
            }, invocation, hooks.context) catch |err|
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
            const handler = hooks.on_pre_mcp_tool_call orelse
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
            }, invocation, hooks.context) catch |err|
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
            const handler = hooks.on_post_tool_use orelse
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
            }, invocation, hooks.context) catch |err|
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
            const handler = hooks.on_post_tool_use_failure orelse
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
            }, invocation, hooks.context) catch |err|
                return self.writeServerRequestError(writer, id, -32000, @errorName(err));
            return self.writeTypedSuccess(writer, id, .{ .output = .{
                .additionalContext = output.additional_context,
            } });
        }
        if (std.mem.eql(u8, hook_type, "userPromptSubmitted")) {
            const handler = hooks.on_user_prompt_submitted orelse
                return self.writeTypedSuccess(writer, id, .{});
            const output = handler(self.allocator, .{
                .base = base,
                .prompt = jsonRequiredString(input, "prompt") catch
                    return self.writeServerRequestError(writer, id, -32602, "invalid hook input"),
            }, invocation, hooks.context) catch |err|
                return self.writeServerRequestError(writer, id, -32000, @errorName(err));
            return self.writeTypedSuccess(writer, id, .{ .output = .{
                .modifiedPrompt = output.modified_prompt,
                .additionalContext = output.additional_context,
                .suppressOutput = output.suppress_output,
            } });
        }
        if (std.mem.eql(u8, hook_type, "userPromptTransformed")) {
            const handler = hooks.on_user_prompt_transformed orelse
                return self.writeTypedSuccess(writer, id, .{});
            const output = handler(self.allocator, .{
                .base = base,
                .prompt = jsonRequiredString(input, "prompt") catch
                    return self.writeServerRequestError(writer, id, -32602, "invalid hook input"),
                .transformed_prompt = jsonRequiredString(input, "transformedPrompt") catch
                    return self.writeServerRequestError(writer, id, -32602, "invalid hook input"),
            }, invocation, hooks.context) catch |err|
                return self.writeServerRequestError(writer, id, -32000, @errorName(err));
            return self.writeTypedSuccess(writer, id, .{ .output = .{
                .modifiedTransformedPrompt = output.modified_transformed_prompt,
            } });
        }
        if (std.mem.eql(u8, hook_type, "sessionStart")) {
            const handler = hooks.on_session_start orelse
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
            }, invocation, hooks.context) catch |err|
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
            const handler = hooks.on_session_end orelse
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
            }, invocation, hooks.context) catch |err|
                return self.writeServerRequestError(writer, id, -32000, @errorName(err));
            return self.writeTypedSuccess(writer, id, .{ .output = .{
                .suppressOutput = output.suppress_output,
                .cleanupActions = output.cleanup_actions,
                .sessionSummary = output.session_summary,
            } });
        }
        if (std.mem.eql(u8, hook_type, "errorOccurred")) {
            const handler = hooks.on_error_occurred orelse
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
            }, invocation, hooks.context) catch |err|
                return self.writeServerRequestError(writer, id, -32000, @errorName(err));
            return self.writeTypedSuccess(writer, id, .{ .output = .{
                .suppressOutput = output.suppress_output,
                .errorHandling = output.handling,
                .retryCount = output.retry_count,
                .userNotification = output.user_notification,
            } });
        }
        if (std.mem.eql(u8, hook_type, "agentStop")) {
            const handler = hooks.on_agent_stop orelse
                return self.writeTypedSuccess(writer, id, .{});
            const output = handler(self.allocator, .{
                .base = base,
                .stop_reason = jsonOptionalString(input, "stopReason") catch
                    return self.writeServerRequestError(writer, id, -32602, "invalid hook input"),
                .transcript_path = jsonOptionalString(input, "transcriptPath") catch
                    return self.writeServerRequestError(writer, id, -32602, "invalid hook input"),
                .stop_hook_active = (jsonOptionalBool(input, "stop_hook_active") catch
                    return self.writeServerRequestError(writer, id, -32602, "invalid hook input")) orelse false,
            }, invocation, hooks.context) catch |err|
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
        const canvas_id = jsonRequiredString(object, "canvasId") catch
            return self.writeServerRequestError(writer, id, -32602, "invalid canvas request");
        var acquired = self.acquireCanvas(session_id, canvas_id) orelse
            return self.writeServerRequestError(writer, id, -32000, "canvas not registered");
        defer acquired.lease.deinit();
        const registered = acquired.value;
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

        var acquired = self.acquireProviderToken(
            parsed.value.sessionId,
            parsed.value.providerName,
        ) orelse return self.writeServerRequestError(
            writer,
            id,
            -32000,
            "bearer token provider not registered",
        );
        defer acquired.lease.deinit();
        const token_provider = acquired.value;

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

        if (self.findEventLog(parsed.value.sessionId) == null)
            return self.writeServerRequestError(writer, id, -32000, "session is not active");
        var acquired = self.acquireUserInputHandler(parsed.value.sessionId) orelse
            return self.writeServerRequestError(writer, id, -32000, "user input handler not registered");
        defer acquired.lease.deinit();
        const registered = acquired.value;

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
        self.event_logs_mutex.lockUncancelable(self.io);
        const log = self.findEventLogLocked(session_id) orelse {
            self.event_logs_mutex.unlock(self.io);
            return error.UnknownSessionEvent;
        };
        log.beginIngress() catch |err| {
            self.event_logs_mutex.unlock(self.io);
            return err;
        };
        self.event_logs_mutex.unlock(self.io);
        errdefer log.finishIngress();
        var event = try session_types.parseEvent(
            self.allocator,
            event_value,
        );
        errdefer event.deinit(self.allocator);
        try self.event_queue_mutex.lock(self.io);
        defer self.event_queue_mutex.unlock(self.io);
        if (self.event_processor_closing) return error.SessionDisconnected;
        if (self.event_queue.items.len == event_ingress_limit)
            return error.EventIngressOverflow;
        try self.event_queue.append(self.allocator, .{
            .log = log,
            .event = event,
        });
        self.event_queue_ready.set(self.io);
        if (self.event_processor_future == null) {
            self.event_processor_future = self.io.async(eventProcessorMain, .{self});
        }
    }

    fn ensureEventLog(self: *Client, session_id: []const u8) !*event_log.EventLog {
        try self.event_logs_mutex.lock(self.io);
        defer self.event_logs_mutex.unlock(self.io);
        if (self.findEventLogLocked(session_id)) |log| return log;
        self.reclaimClosedEventLogsLocked();
        if (self.event_logs.items.len >= retained_log_limit) {
            self.discardOldestClosedEventLogLocked();
        }
        if (self.event_logs.items.len >= retained_log_limit)
            return error.TooManyRetainedSessionLogs;
        const log = try self.allocator.create(event_log.EventLog);
        errdefer self.allocator.destroy(log);
        log.* = try event_log.EventLog.init(
            self.allocator,
            self.io,
            session_id,
            self.next_event_log_generation,
            retained_event_limit,
            event_subscriber_limit,
        );
        self.next_event_log_generation +%= 1;
        if (self.next_event_log_generation == 0) self.next_event_log_generation = 1;
        errdefer log.deinit();
        try self.event_logs.append(self.allocator, log);
        self.pending_mutex.lockUncancelable(self.io);
        const pump_failure = self.pump_failure;
        self.pending_mutex.unlock(self.io);
        if (pump_failure) |err| log.fail(err);
        return log;
    }

    fn eventProcessorMain(self: *Client) anyerror!void {
        while (true) {
            try self.event_queue_mutex.lock(self.io);
            if (self.event_queue.items.len == 0) {
                if (self.event_processor_closing) {
                    self.event_queue_mutex.unlock(self.io);
                    return;
                }
                self.event_queue_ready.reset();
                self.event_queue_mutex.unlock(self.io);
                try self.event_queue_ready.wait(self.io);
                continue;
            }
            var work = self.event_queue.orderedRemove(0);
            self.event_queue_mutex.unlock(self.io);
            defer work.log.finishIngress();

            try work.log.processing_mutex.lock(self.io);
            defer work.log.processing_mutex.unlock(self.io);
            self.applyExtensionEvent(
                work.log.session_id,
                work.log.generation,
                &work.event,
            ) catch |err| {
                work.event.deinit(self.allocator);
                work.log.fail(err);
                continue;
            };
            (Session{
                .client = self,
                .id = work.log.session_id,
                .generation = work.log.generation,
            }).processEvent(work.log, &work.event) catch |err| {
                work.event.deinit(self.allocator);
                work.log.fail(err);
                continue;
            };
            work.log.observeTurnEvent(work.event) catch |err| {
                work.event.deinit(self.allocator);
                work.log.fail(err);
                continue;
            };
            work.log.append(work.event) catch |err| {
                work.event.deinit(self.allocator);
                work.log.fail(err);
                continue;
            };
        }
    }

    fn stopEventProcessor(self: *Client) void {
        if (self.event_processor_future == null) return;
        self.event_queue_mutex.lockUncancelable(self.io);
        self.event_processor_closing = true;
        self.event_queue_ready.set(self.io);
        self.event_queue_mutex.unlock(self.io);
        if (self.event_processor_future) |*future| {
            _ = future.await(self.io) catch {};
            self.event_processor_future = null;
        }
    }

    fn findEventLog(self: *Client, session_id: []const u8) ?*event_log.EventLog {
        self.event_logs_mutex.lockUncancelable(self.io);
        defer self.event_logs_mutex.unlock(self.io);
        return self.findEventLogLocked(session_id);
    }

    fn activeGeneration(self: *Client, session_id: []const u8) u64 {
        self.event_logs_mutex.lockUncancelable(self.io);
        defer self.event_logs_mutex.unlock(self.io);
        const log = self.findEventLogLocked(session_id) orelse return 0;
        return log.generation;
    }

    fn findEventLogLocked(self: *Client, session_id: []const u8) ?*event_log.EventLog {
        for (self.event_logs.items) |log| {
            if (std.mem.eql(u8, log.session_id, session_id) and
                log.isAcceptingIngress())
            {
                return log;
            }
        }
        return null;
    }

    fn findEventLogGeneration(
        self: *Client,
        session_id: []const u8,
        generation: u64,
    ) ?*event_log.EventLog {
        self.event_logs_mutex.lockUncancelable(self.io);
        defer self.event_logs_mutex.unlock(self.io);
        for (self.event_logs.items) |log| {
            if (log.generation == generation and
                std.mem.eql(u8, log.session_id, session_id))
            {
                return log;
            }
        }
        return null;
    }

    fn acquireEventLog(
        self: *Client,
        session_id: []const u8,
        generation: u64,
        require_open: bool,
    ) !EventLogLease {
        self.event_logs_mutex.lockUncancelable(self.io);
        defer self.event_logs_mutex.unlock(self.io);
        const log = if (generation == 0)
            self.findEventLogLocked(session_id) orelse
                return error.SessionDisconnected
        else blk: {
            for (self.event_logs.items) |candidate| {
                if (candidate.generation == generation and
                    std.mem.eql(u8, candidate.session_id, session_id))
                {
                    break :blk candidate;
                }
            }
            return error.SessionDisconnected;
        };
        if (require_open and !log.isAcceptingIngress())
            return error.SessionDisconnected;
        log.retainOperation();
        return .{ .client = self, .log = log };
    }

    fn reclaimClosedEventLogs(self: *Client) void {
        self.event_logs_mutex.lockUncancelable(self.io);
        defer self.event_logs_mutex.unlock(self.io);
        self.reclaimClosedEventLogsLocked();
    }

    fn reclaimClosedEventLogsLocked(self: *Client) void {
        var index: usize = 0;
        while (index < self.event_logs.items.len) {
            const log = self.event_logs.items[index];
            if (!log.isReclaimable()) {
                index += 1;
                continue;
            }
            _ = self.event_logs.orderedRemove(index);
            log.deinit();
            self.allocator.destroy(log);
        }
    }

    fn discardOldestClosedEventLogLocked(self: *Client) void {
        for (self.event_logs.items, 0..) |log, index| {
            if (!log.isDiscardableClosed()) continue;
            _ = self.event_logs.orderedRemove(index);
            log.deinit();
            self.allocator.destroy(log);
            return;
        }
    }

    fn findExtensionRuntime(self: *Client, session_id: []const u8) ?*SessionExtensionRuntime {
        self.registry_mutex.lockUncancelable(self.io);
        defer self.registry_mutex.unlock(self.io);
        return self.findExtensionRuntimeLocked(session_id);
    }

    fn findExtensionRuntimeLocked(
        self: *Client,
        session_id: []const u8,
    ) ?*SessionExtensionRuntime {
        return self.findExtensionRuntimeGenerationLocked(
            session_id,
            self.activeGeneration(session_id),
        );
    }

    fn findExtensionRuntimeGenerationLocked(
        self: *Client,
        session_id: []const u8,
        generation: u64,
    ) ?*SessionExtensionRuntime {
        if (self.pending_extension_runtime) |*runtime| {
            if (runtime.session_id) |id| {
                if (std.mem.eql(u8, id, session_id) and
                    generationsMatch(runtime.generation, generation)) return runtime;
            }
        }
        for (self.extension_runtimes.items) |*runtime| {
            if (runtime.session_id) |id| {
                if (std.mem.eql(u8, id, session_id) and
                    generationsMatch(runtime.generation, generation)) return runtime;
            }
        }
        return null;
    }

    fn acquireSessionHooks(
        self: *Client,
        session_id: []const u8,
    ) ?AcquiredCallback(ext.SessionHooks) {
        self.registry_mutex.lockUncancelable(self.io);
        defer self.registry_mutex.unlock(self.io);
        if (!self.accepting_callbacks) return null;
        const origin = self.resolveCallbackOriginLocked(session_id, null) orelse return null;
        const runtime = self.findExtensionRuntimeGenerationLocked(
            session_id,
            origin.generation,
        ) orelse return null;
        if (!runtime.accepting_callbacks) return null;
        const lease = self.beginCallbackLocked(origin) orelse return null;
        return .{ .value = runtime.hooks, .lease = lease };
    }

    fn acquireCanvas(
        self: *Client,
        session_id: []const u8,
        canvas_id: []const u8,
    ) ?AcquiredCallback(OwnedCanvas) {
        self.registry_mutex.lockUncancelable(self.io);
        defer self.registry_mutex.unlock(self.io);
        if (!self.accepting_callbacks) return null;
        const origin = self.resolveCallbackOriginLocked(session_id, null) orelse return null;
        const runtime = self.findExtensionRuntimeGenerationLocked(
            session_id,
            origin.generation,
        ) orelse return null;
        if (!runtime.accepting_callbacks) return null;
        for (runtime.canvases) |canvas| {
            if (!std.mem.eql(u8, canvas.id, canvas_id)) continue;
            const lease = self.beginCallbackLocked(origin) orelse return null;
            return .{ .value = canvas, .lease = lease };
        }
        return null;
    }

    fn applyExtensionEvent(
        self: *Client,
        session_id: []const u8,
        generation: u64,
        event: *const session_types.SessionEvent,
    ) !void {
        try self.registry_mutex.lock(self.io);
        defer self.registry_mutex.unlock(self.io);
        if (self.pending_extension_runtime) |*runtime| {
            if (runtime.session_id) |id| {
                if (std.mem.eql(u8, id, session_id) and
                    generationsMatch(runtime.generation, generation))
                {
                    try applyExtensionEventToRuntime(self.allocator, runtime, event);
                }
            }
        }
        for (self.extension_runtimes.items) |*runtime| {
            if (runtime.session_id) |id| {
                if (std.mem.eql(u8, id, session_id) and
                    generationsMatch(runtime.generation, generation))
                {
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
        var closing_log: ?*event_log.EventLog = null;
        self.event_logs_mutex.lockUncancelable(self.io);
        var index = self.event_logs.items.len;
        while (index > 0) {
            index -= 1;
            const log = self.event_logs.items[index];
            if (std.mem.eql(u8, log.session_id, session_id) and
                log.isAcceptingIngress())
            {
                closing_log = log;
                break;
            }
        }
        self.event_logs_mutex.unlock(self.io);
        if (closing_log) |log| log.beginClose();
        self.removeSessionWithLog(session_id, closing_log);
    }

    fn removeSessionWithLog(
        self: *Client,
        session_id: []const u8,
        closing_log: ?*event_log.EventLog,
    ) void {
        if (closing_log) |log| {
            log.waitIngressDrainedUncancelable();
            log.close();
        }
        self.registry_mutex.lockUncancelable(self.io);
        const generation = if (closing_log) |log| log.generation else 0;
        if (self.findExtensionRuntimeGenerationLocked(session_id, generation)) |runtime| {
            runtime.accepting_callbacks = false;
        }
        self.registry_mutex.unlock(self.io);
        if (closing_log) |log| log.waitCallbacksDrainedUncancelable();
        self.registry_teardown_mutex.lockUncancelable(self.io);
        defer self.registry_teardown_mutex.unlock(self.io);
        self.registry_mutex.lockUncancelable(self.io);
        defer self.registry_mutex.unlock(self.io);

        for (self.extension_runtimes.items, 0..) |runtime, runtime_index| {
            if (runtime.session_id != null and
                std.mem.eql(u8, runtime.session_id.?, session_id) and
                generationsMatch(runtime.generation, generation))
            {
                var removed = self.extension_runtimes.orderedRemove(runtime_index);
                removed.deinit(self.allocator);
                break;
            }
        }

        var tool_index: usize = 0;
        while (tool_index < self.tools.items.len) {
            if (std.mem.eql(u8, self.tools.items[tool_index].session_id, session_id) and
                generationsMatch(self.tools.items[tool_index].generation, generation))
            {
                const tool = self.tools.orderedRemove(tool_index);
                tool.deinit(self.allocator);
            } else {
                tool_index += 1;
            }
        }

        var user_input_handler_index: usize = 0;
        while (user_input_handler_index < self.user_input_handlers.items.len) {
            if (std.mem.eql(u8, self.user_input_handlers.items[user_input_handler_index].session_id, session_id) and
                generationsMatch(
                    self.user_input_handlers.items[user_input_handler_index].generation,
                    generation,
                ))
            {
                _ = self.user_input_handlers.orderedRemove(user_input_handler_index);
            } else {
                user_input_handler_index += 1;
            }
        }

        var permission_handler_index: usize = 0;
        while (permission_handler_index < self.permission_handlers.items.len) {
            if (std.mem.eql(u8, self.permission_handlers.items[permission_handler_index].session_id, session_id) and
                generationsMatch(
                    self.permission_handlers.items[permission_handler_index].generation,
                    generation,
                ))
            {
                _ = self.permission_handlers.orderedRemove(permission_handler_index);
            } else {
                permission_handler_index += 1;
            }
        }
        self.removeSessionId(session_id, generation);
    }

    fn findSessionId(self: *Client, session_id: []const u8) ?[]u8 {
        for (self.session_ids.items) |id| {
            if (std.mem.eql(u8, id, session_id)) return id;
        }
        return null;
    }

    fn retireSessionId(self: *Client, session_id: []const u8) ?[]u8 {
        self.registry_mutex.lockUncancelable(self.io);
        defer self.registry_mutex.unlock(self.io);
        for (self.session_ids.items, 0..) |id, session_index| {
            if (!std.mem.eql(u8, id, session_id)) continue;
            return self.session_ids.orderedRemove(session_index);
        }
        return null;
    }

    fn removeSessionId(
        self: *Client,
        session_id: []const u8,
        generation: u64,
    ) void {
        var provider_token_index: usize = 0;
        while (provider_token_index < self.provider_tokens.items.len) {
            if (std.mem.eql(
                u8,
                self.provider_tokens.items[provider_token_index].session_id,
                session_id,
            ) and generationsMatch(
                self.provider_tokens.items[provider_token_index].generation,
                generation,
            )) {
                const registered = self.provider_tokens.orderedRemove(provider_token_index);
                registered.deinit(self.allocator);
            } else {
                provider_token_index += 1;
            }
        }

        for (self.session_ids.items, 0..) |id, session_index| {
            if (std.mem.eql(u8, id, session_id)) {
                const active_generation = self.activeGeneration(session_id);
                if (generation != 0 and
                    active_generation != 0 and
                    active_generation != generation) return;
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
        _ = try self.ensureEventLog(owned_session_id);

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
        try self.registry_mutex.lock(self.io);
        defer self.registry_mutex.unlock(self.io);
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
            .generation = self.activeGeneration(session_id),
            .providers = registered,
        });
    }

    fn beginProviderTokens(
        self: *Client,
        session_id: []const u8,
        bindings: []const provider.TokenBinding,
    ) !void {
        try self.registry_mutex.lock(self.io);
        defer self.registry_mutex.unlock(self.io);
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
            .generation = self.activeGeneration(session_id),
            .providers = registered,
        };
    }

    fn rollbackProviderTokens(self: *Client) void {
        self.registry_mutex.lockUncancelable(self.io);
        defer self.registry_mutex.unlock(self.io);
        const registered = self.pending_provider_tokens orelse return;
        self.pending_provider_tokens = null;
        registered.deinit(self.allocator);
    }

    fn commitProviderTokens(self: *Client) void {
        self.registry_mutex.lockUncancelable(self.io);
        defer self.registry_mutex.unlock(self.io);
        const pending = self.pending_provider_tokens orelse return;
        self.pending_provider_tokens = null;

        for (self.provider_tokens.items, 0..) |registered, index| {
            if (!std.mem.eql(u8, registered.session_id, pending.session_id) or
                registered.generation != pending.generation) continue;
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
        self.registry_mutex.lockUncancelable(self.io);
        defer self.registry_mutex.unlock(self.io);
        return self.findProviderTokenLocked(
            session_id,
            self.activeGeneration(session_id),
            provider_name,
        );
    }

    fn findProviderTokenLocked(
        self: *Client,
        session_id: []const u8,
        generation: u64,
        provider_name: []const u8,
    ) ?provider.BearerTokenProvider {
        if (self.pending_provider_tokens) |pending| {
            if (std.mem.eql(u8, pending.session_id, session_id) and
                generationsMatch(pending.generation, generation))
            {
                for (pending.providers) |registered| {
                    if (std.mem.eql(u8, registered.provider_name, provider_name)) {
                        return registered.token_provider;
                    }
                }
                return null;
            }
        }
        for (self.provider_tokens.items) |session_providers| {
            if (!std.mem.eql(u8, session_providers.session_id, session_id) or
                !generationsMatch(session_providers.generation, generation)) continue;
            for (session_providers.providers) |registered| {
                if (std.mem.eql(u8, registered.provider_name, provider_name)) {
                    return registered.token_provider;
                }
            }
            return null;
        }
        return null;
    }

    fn acquireProviderToken(
        self: *Client,
        session_id: []const u8,
        provider_name: []const u8,
    ) ?AcquiredCallback(provider.BearerTokenProvider) {
        self.registry_mutex.lockUncancelable(self.io);
        defer self.registry_mutex.unlock(self.io);
        if (!self.accepting_callbacks) return null;
        const origin = self.resolveCallbackOriginLocked(session_id, null) orelse return null;
        const token_provider =
            self.findProviderTokenLocked(
                session_id,
                origin.generation,
                provider_name,
            ) orelse return null;
        const lease = self.beginCallbackLocked(origin) orelse return null;
        return .{ .value = token_provider, .lease = lease };
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
        try self.registry_mutex.lock(self.io);
        defer self.registry_mutex.unlock(self.io);
        for (definitions) |definition| {
            const handler = definition.handler orelse continue;
            const name = try self.allocator.dupe(u8, definition.name);
            errdefer self.allocator.free(name);
            try self.tools.append(self.allocator, .{
                .session_id = session_id,
                .generation = self.activeGeneration(session_id),
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
    ) ?AcquiredCallback(RegisteredTool) {
        self.registry_mutex.lockUncancelable(self.io);
        defer self.registry_mutex.unlock(self.io);
        return self.findToolHandlerLocked(
            session_id,
            self.activeGeneration(session_id),
            name,
        );
    }

    fn findToolHandlerLocked(
        self: *Client,
        session_id: []const u8,
        generation: u64,
        name: []const u8,
    ) ?RegisteredTool {
        if (self.findExtensionRuntimeGenerationLocked(session_id, generation)) |runtime| {
            for (runtime.tools) |tool| {
                if (std.mem.eql(u8, tool.name, name)) return .{
                    .session_id = session_id,
                    .generation = runtime.generation,
                    .name = tool.name,
                    .handler = tool.handler,
                    .context = tool.context,
                };
            }
        }
        for (self.tools.items) |tool| {
            if (std.mem.eql(u8, tool.session_id, session_id) and
                generationsMatch(tool.generation, generation) and
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
        try self.registry_mutex.lock(self.io);
        defer self.registry_mutex.unlock(self.io);
        try self.user_input_handlers.append(self.allocator, .{
            .session_id = session_id,
            .generation = self.activeGeneration(session_id),
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
        try self.registry_mutex.lock(self.io);
        defer self.registry_mutex.unlock(self.io);
        try self.permission_handlers.append(self.allocator, .{
            .session_id = session_id,
            .generation = self.activeGeneration(session_id),
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
        self.registry_mutex.lockUncancelable(self.io);
        defer self.registry_mutex.unlock(self.io);
        return self.findPermissionHandlerLocked(
            session_id,
            self.activeGeneration(session_id),
        );
    }

    fn findPermissionHandlerLocked(
        self: *Client,
        session_id: []const u8,
        generation: u64,
    ) ?RegisteredPermissionHandler {
        if (self.findExtensionRuntimeGenerationLocked(session_id, generation)) |runtime| {
            if (runtime.permission_handler) |handler| return .{
                .session_id = session_id,
                .generation = runtime.generation,
                .handler = handler,
                .managed_settings_enabled = runtime.managed_settings_enabled,
                .context = runtime.permission_context,
            };
        }
        for (self.permission_handlers.items) |registered| {
            if (std.mem.eql(u8, registered.session_id, session_id) and
                generationsMatch(registered.generation, generation)) return registered;
        }
        return null;
    }

    fn findUserInputHandler(
        self: *Client,
        session_id: []const u8,
    ) ?RegisteredUserInputHandler {
        self.registry_mutex.lockUncancelable(self.io);
        defer self.registry_mutex.unlock(self.io);
        return self.findUserInputHandlerLocked(
            session_id,
            self.activeGeneration(session_id),
        );
    }

    fn findUserInputHandlerLocked(
        self: *Client,
        session_id: []const u8,
        generation: u64,
    ) ?RegisteredUserInputHandler {
        if (self.findExtensionRuntimeGenerationLocked(session_id, generation)) |runtime| {
            if (runtime.user_input_handler) |handler| return .{
                .session_id = session_id,
                .generation = runtime.generation,
                .handler = handler,
                .context = runtime.user_input_context,
            };
        }
        for (self.user_input_handlers.items) |registered| {
            if (std.mem.eql(u8, registered.session_id, session_id) and
                generationsMatch(registered.generation, generation)) return registered;
        }
        return null;
    }

    fn acquireToolHandler(
        self: *Client,
        session_id: []const u8,
        origin_log: ?*event_log.EventLog,
        name: []const u8,
    ) ?AcquiredCallback(RegisteredTool) {
        self.registry_mutex.lockUncancelable(self.io);
        defer self.registry_mutex.unlock(self.io);
        if (!self.accepting_callbacks) return null;
        const origin = self.resolveCallbackOriginLocked(session_id, origin_log) orelse return null;
        if (self.findExtensionRuntimeGenerationLocked(
            session_id,
            origin.generation,
        )) |runtime| {
            if (!runtime.accepting_callbacks) return null;
        }
        const handler = self.findToolHandlerLocked(
            session_id,
            origin.generation,
            name,
        ) orelse return null;
        const lease = self.beginCallbackLocked(origin) orelse return null;
        return .{ .value = handler, .lease = lease };
    }

    fn acquirePermissionHandler(
        self: *Client,
        session_id: []const u8,
        origin_log: ?*event_log.EventLog,
    ) ?AcquiredCallback(RegisteredPermissionHandler) {
        self.registry_mutex.lockUncancelable(self.io);
        defer self.registry_mutex.unlock(self.io);
        if (!self.accepting_callbacks) return null;
        const origin = self.resolveCallbackOriginLocked(session_id, origin_log) orelse return null;
        if (self.findExtensionRuntimeGenerationLocked(
            session_id,
            origin.generation,
        )) |runtime| {
            if (!runtime.accepting_callbacks) return null;
        }
        const handler = self.findPermissionHandlerLocked(
            session_id,
            origin.generation,
        ) orelse return null;
        const lease = self.beginCallbackLocked(origin) orelse return null;
        return .{ .value = handler, .lease = lease };
    }

    fn acquireUserInputHandler(
        self: *Client,
        session_id: []const u8,
    ) ?AcquiredCallback(RegisteredUserInputHandler) {
        self.registry_mutex.lockUncancelable(self.io);
        defer self.registry_mutex.unlock(self.io);
        if (!self.accepting_callbacks) return null;
        const origin = self.resolveCallbackOriginLocked(session_id, null) orelse return null;
        if (self.findExtensionRuntimeGenerationLocked(
            session_id,
            origin.generation,
        )) |runtime| {
            if (!runtime.accepting_callbacks) return null;
        }
        const handler = self.findUserInputHandlerLocked(
            session_id,
            origin.generation,
        ) orelse return null;
        const lease = self.beginCallbackLocked(origin) orelse return null;
        return .{ .value = handler, .lease = lease };
    }

    fn acquireMcpAuthHandler(
        self: *Client,
        session_id: []const u8,
        origin_log: *event_log.EventLog,
    ) ?AcquiredCallback(RegisteredMcpAuthHandler) {
        self.registry_mutex.lockUncancelable(self.io);
        defer self.registry_mutex.unlock(self.io);
        if (!self.accepting_callbacks) return null;
        const origin = self.resolveCallbackOriginLocked(
            session_id,
            origin_log,
        ) orelse return null;
        const runtime = self.findExtensionRuntimeGenerationLocked(
            session_id,
            origin.generation,
        ) orelse return null;
        if (!runtime.accepting_callbacks) return null;
        const handler = runtime.mcp_auth_handler orelse return null;
        const lease = self.beginCallbackLocked(origin) orelse return null;
        return .{
            .value = .{ .handler = handler, .context = runtime.mcp_auth_context },
            .lease = lease,
        };
    }

    fn resolveCallbackOriginLocked(
        self: *Client,
        session_id: []const u8,
        origin_log: ?*event_log.EventLog,
    ) ?CallbackOrigin {
        if (origin_log) |log| {
            if (!std.mem.eql(u8, log.session_id, session_id)) return null;
            return .{
                .log = log,
                .generation = log.generation,
                .admitted = true,
            };
        }
        self.event_logs_mutex.lockUncancelable(self.io);
        defer self.event_logs_mutex.unlock(self.io);
        const log = self.findEventLogLocked(session_id);
        return .{
            .log = log,
            .generation = if (log) |value| value.generation else 0,
            .admitted = false,
        };
    }

    fn beginCallbackLocked(
        self: *Client,
        origin: CallbackOrigin,
    ) ?CallbackLease {
        if (origin.log) |log| {
            log.retainCallback(origin.admitted) catch return null;
        }
        self.active_callbacks += 1;
        self.callbacks_drained.reset();
        return .{ .client = self, .log = origin.log };
    }

    fn releaseCallback(self: *Client, log: ?*event_log.EventLog) void {
        self.registry_mutex.lockUncancelable(self.io);
        std.debug.assert(self.active_callbacks > 0);
        self.active_callbacks -= 1;
        if (self.active_callbacks == 0) self.callbacks_drained.set(self.io);
        self.registry_mutex.unlock(self.io);
        if (log) |value| {
            value.releaseCallback();
            self.reclaimClosedEventLogs();
        }
    }

    fn waitCallbacksDrained(self: *Client) void {
        self.callbacks_drained.waitUncancelable(self.io);
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

    fn nextSubscriberEvent(
        self: *Client,
        log: *event_log.EventLog,
        token: event_log.SubscriberToken,
        deadline: ?std.Io.Clock.Timestamp,
        cancellation: ?*session_types.Cancellation,
        local_end_out: ?*?anyerror,
    ) !session_types.SessionEvent {
        var local_end_storage: ?anyerror = null;
        const local_end = local_end_out orelse &local_end_storage;
        while (true) {
            switch (try log.inspect(token)) {
                .event => |event| return event,
                .overflow => return error.EventLogOverflow,
                .failure => |err| return err,
                .closed => {
                    self.reclaimClosedEventLogs();
                    return error.SessionDisconnected;
                },
                .wait => |ready| {
                    if (local_end.*) |err| return err;
                    if (deadline == null and cancellation == null) {
                        try ready.wait(self.io);
                        continue;
                    }
                    const WaitResult = union(enum) {
                        ready: anyerror!void,
                        canceled: anyerror!void,
                        timeout: anyerror!void,
                    };
                    var results: [3]WaitResult = undefined;
                    var select = std.Io.Select(WaitResult).init(self.io, &results);
                    select.async(.ready, waitForEvent, .{ ready, self.io });
                    if (cancellation) |value| {
                        select.async(.canceled, waitForEvent, .{ &value.event, self.io });
                    }
                    if (deadline) |value| {
                        select.async(.timeout, waitForDeadline, .{ value, self.io });
                    }
                    const result = try select.await();
                    select.cancelDiscard();
                    local_end.* = switch (result) {
                        .ready => |wait_result| blk: {
                            try wait_result;
                            break :blk null;
                        },
                        .canceled => |wait_result| blk: {
                            try wait_result;
                            break :blk error.Canceled;
                        },
                        .timeout => |wait_result| blk: {
                            try wait_result;
                            break :blk error.Timeout;
                        },
                    };
                },
            }
        }
    }
};

fn waitForEvent(event: *std.Io.Event, io: std.Io) anyerror!void {
    return event.wait(io);
}

fn waitForDeadline(deadline: std.Io.Clock.Timestamp, io: std.Io) anyerror!void {
    return deadline.wait(io);
}

pub const EventSubscriber = struct {
    lease: EventLogLease,
    token: event_log.SubscriberToken,
    active: bool = true,

    pub fn nextEvent(self: *EventSubscriber) !session_types.SessionEvent {
        if (!self.active) return error.InvalidEventSubscriber;
        return self.lease.client.nextSubscriberEvent(
            self.lease.log,
            self.token,
            null,
            null,
            null,
        );
    }

    pub fn deinit(self: *EventSubscriber) void {
        if (!self.active) return;
        self.lease.log.unsubscribe(self.token);
        self.active = false;
        self.lease.deinit();
    }
};

pub const Session = struct {
    client: *Client,
    id: []const u8,
    generation: u64 = 0,

    pub fn send(self: Session, options: session_types.MessageOptions) ![]u8 {
        try validateMessageOptions(options);
        var log_lease = try self.operationEventLog();
        defer log_lease.deinit();
        const session_log = log_lease.log;
        const receipt = try session_log.reserveTurn(.raw);
        errdefer session_log.failTurn(receipt, error.SendFailed);
        const owned_source = if (options.source) |source| switch (source) {
            .user, .system => null,
            .agent => |name| try std.fmt.allocPrint(
                self.client.allocator,
                "agent-{s}",
                .{name},
            ),
        } else null;
        defer if (owned_source) |source| self.client.allocator.free(source);
        const source: ?[]const u8 = if (options.source) |value| switch (value) {
            .user => "user",
            .system => "system",
            .agent => owned_source.?,
        } else null;
        const message_id = try self.sendLowered(options, source);
        session_log.bindTurnMessage(receipt, message_id) catch |err| {
            self.client.allocator.free(message_id);
            return err;
        };
        return message_id;
    }

    fn sendLowered(
        self: Session,
        options: session_types.MessageOptions,
        source: ?[]const u8,
    ) ![]u8 {
        const parsed = try self.client.call(
            struct { messageId: []const u8 },
            "session.send",
            lowerMessage(self.id, options, source),
        );
        defer parsed.deinit();
        return self.client.allocator.dupe(u8, parsed.value.messageId);
    }

    pub fn sendAndWait(
        self: Session,
        options: session_types.MessageOptions,
    ) !?session_types.AssistantMessage {
        return self.sendAndWaitWithOptions(options, .{});
    }

    pub fn sendAndWaitWithOptions(
        self: Session,
        options: session_types.MessageOptions,
        wait_options: session_types.WaitOptions,
    ) !?session_types.AssistantMessage {
        try validateMessageOptions(options);
        const deadline = if (wait_options.timeout_ns) |timeout_ns|
            std.Io.Clock.Timestamp.fromNow(self.client.io, .{
                .raw = std.Io.Duration.fromNanoseconds(@intCast(timeout_ns)),
                .clock = .awake,
            })
        else
            null;
        if (wait_options.cancellation) |cancellation| {
            if (cancellation.isCancelled()) return error.Canceled;
        }
        var log_lease = try self.operationEventLog();
        defer log_lease.deinit();
        const session_log = log_lease.log;
        const receipt = try session_log.reserveTurn(.waited);
        var operation_started = false;
        errdefer if (operation_started)
            session_log.detachTurnWaiter(receipt)
        else
            session_log.abandonTurn(receipt);
        const owned_source = if (options.source) |source| switch (source) {
            .user, .system => null,
            .agent => |name| try std.fmt.allocPrint(
                self.client.allocator,
                "agent-{s}",
                .{name},
            ),
        } else null;
        defer if (owned_source) |source| self.client.allocator.free(source);
        const source: ?[]const u8 = if (options.source) |value| switch (value) {
            .user => "user",
            .system => "system",
            .agent => owned_source.?,
        } else null;
        const operation = try self.client.startSendOperation(
            log_lease,
            receipt,
            options,
            source,
        );
        operation_started = true;
        try self.waitForSendOperation(operation, deadline, wait_options.cancellation);
        return self.waitForTurn(session_log, receipt, deadline, wait_options.cancellation);
    }

    fn waitForSendOperation(
        self: Session,
        operation: *SendOperation,
        deadline: ?std.Io.Clock.Timestamp,
        cancellation: ?*session_types.Cancellation,
    ) !void {
        while (true) {
            if (operation.completed.isSet()) {
                if (self.client.claimCompletedSendOperation(operation, .waiter)) |claimed| {
                    return self.client.destroyClaimedSendOperation(claimed);
                }
            }
            if (cancellation) |value| {
                if (value.isCancelled()) {
                    return self.finishOrDetachSendOperation(operation, error.Canceled);
                }
            }
            const WaitResult = union(enum) {
                completed: anyerror!void,
                canceled: anyerror!void,
                timeout: anyerror!void,
            };
            var results: [3]WaitResult = undefined;
            var select = std.Io.Select(WaitResult).init(self.client.io, &results);
            select.async(.completed, waitForEvent, .{ &operation.completed, self.client.io });
            if (cancellation) |value| {
                select.async(.canceled, waitForEvent, .{ &value.event, self.client.io });
            }
            if (deadline) |value| {
                select.async(.timeout, waitForDeadline, .{ value, self.client.io });
            }
            const result = try select.await();
            select.cancelDiscard();
            if (operation.completed.isSet()) {
                if (self.client.claimCompletedSendOperation(operation, .waiter)) |claimed| {
                    return self.client.destroyClaimedSendOperation(claimed);
                }
            }
            if (cancellation) |value| {
                if (value.isCancelled()) {
                    return self.finishOrDetachSendOperation(operation, error.Canceled);
                }
            }
            switch (result) {
                .completed => |wait_result| try wait_result,
                .canceled => |wait_result| {
                    try wait_result;
                    return self.finishOrDetachSendOperation(operation, error.Canceled);
                },
                .timeout => |wait_result| {
                    try wait_result;
                    return self.finishOrDetachSendOperation(operation, error.Timeout);
                },
            }
        }
    }

    fn finishOrDetachSendOperation(
        self: Session,
        operation: *SendOperation,
        local_error: anyerror,
    ) !void {
        switch (self.client.finishOrDetachSendOperation(operation)) {
            .completed => |claimed| return self.client.destroyClaimedSendOperation(claimed),
            .detached => return local_error,
        }
    }

    fn waitForTurn(
        self: Session,
        session_log: *event_log.EventLog,
        receipt: turn_tracker.ReceiptToken,
        deadline: ?std.Io.Clock.Timestamp,
        cancellation: ?*session_types.Cancellation,
    ) !?session_types.AssistantMessage {
        while (true) {
            switch (try session_log.inspectTurn(receipt)) {
                .completed => |response| return response,
                .failure => |err| return err,
                .pending => |ready| {
                    if (cancellation) |value| {
                        if (value.isCancelled()) return error.Canceled;
                    }
                    const WaitResult = union(enum) {
                        ready: anyerror!void,
                        canceled: anyerror!void,
                        timeout: anyerror!void,
                    };
                    var results: [3]WaitResult = undefined;
                    var select = std.Io.Select(WaitResult).init(self.client.io, &results);
                    select.async(.ready, waitForEvent, .{ ready, self.client.io });
                    if (cancellation) |value| {
                        select.async(.canceled, waitForEvent, .{ &value.event, self.client.io });
                    }
                    if (deadline) |value| {
                        select.async(.timeout, waitForDeadline, .{ value, self.client.io });
                    }
                    const result = try select.await();
                    select.cancelDiscard();
                    switch (try session_log.inspectTurn(receipt)) {
                        .completed => |response| return response,
                        .failure => |err| return err,
                        .pending => {},
                    }
                    if (cancellation) |value| {
                        if (value.isCancelled()) return error.Canceled;
                    }
                    switch (result) {
                        .ready => |wait_result| try wait_result,
                        .canceled => |wait_result| {
                            try wait_result;
                            return error.Canceled;
                        },
                        .timeout => |wait_result| {
                            try wait_result;
                            return error.Timeout;
                        },
                    }
                },
            }
        }
    }

    fn operationEventLog(self: Session) !EventLogLease {
        if (self.generation == 0) {
            const session_log = try self.client.ensureEventLog(self.id);
            return self.client.acquireEventLog(
                self.id,
                session_log.generation,
                true,
            );
        }
        return self.client.acquireEventLog(self.id, self.generation, true);
    }

    pub fn nextEvent(self: Session) !session_types.SessionEvent {
        const generation = if (self.generation == 0)
            (try self.client.ensureEventLog(self.id)).generation
        else
            self.generation;
        var lease = try self.client.acquireEventLog(self.id, generation, false);
        defer lease.deinit();
        const session_log = lease.log;
        return self.client.nextSubscriberEvent(
            session_log,
            session_log.compatibilityToken(),
            null,
            null,
            null,
        );
    }

    pub fn subscribe(self: Session) !EventSubscriber {
        const generation = if (self.generation == 0)
            (try self.client.ensureEventLog(self.id)).generation
        else
            self.generation;
        var lease = try self.client.acquireEventLog(self.id, generation, false);
        errdefer lease.deinit();
        return Session.subscribeTo(lease);
    }

    fn subscribeTo(lease: EventLogLease) !EventSubscriber {
        return .{
            .lease = lease,
            .token = try lease.log.subscribe(),
        };
    }

    fn processEvent(
        self: Session,
        origin_log: *event_log.EventLog,
        event: *session_types.SessionEvent,
    ) !void {
        if (event.* == .mcp_oauth_required) {
            try self.handleMcpAuthEvent(origin_log, event.mcp_oauth_required.data_json);
        }
        if (event.* == .external_tool_requested) {
            const request = event.external_tool_requested;
            if (self.client.acquireToolHandler(
                self.id,
                origin_log,
                request.tool_name,
            )) |initial| {
                var acquired = initial;
                defer acquired.lease.deinit();
                const tool = acquired.value;
                const result = tool.handler(
                    self.client.allocator,
                    request.arguments_json,
                    tool.context,
                ) catch |err| {
                    try self.respondToToolError(request.request_id, @errorName(err));
                    return;
                };
                defer self.client.allocator.free(result);
                try self.respondToTool(request.request_id, result);
            }
        }
        if (event.* == .permission_requested) {
            const request = event.permission_requested;
            if (self.client.acquirePermissionHandler(self.id, origin_log)) |initial| {
                var acquired = initial;
                defer acquired.lease.deinit();
                const handler = acquired.value;
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
                    return;
                };
                switch (decision) {
                    .approve_once => self.approvePermission(request.request_id) catch |err| {
                        event.permission_requested.automatic_handling =
                            .{ .delivery_failed = err };
                        return;
                    },
                    .reject => |feedback| self.rejectPermission(request.request_id, feedback) catch |err| {
                        event.permission_requested.automatic_handling =
                            .{ .delivery_failed = err };
                        return;
                    },
                    .json => |decision_json| self.respondToPermissionJson(
                        request.request_id,
                        decision_json,
                        null,
                    ) catch |err| {
                        event.permission_requested.automatic_handling =
                            .{ .delivery_failed = err };
                        return;
                    },
                    .no_result => {
                        event.permission_requested.automatic_handling = .no_result;
                        return;
                    },
                }
                event.permission_requested.automatic_handling = .handled;
            }
        }
    }

    pub fn capabilities(self: Session) ext.CapabilitySet {
        self.client.registry_mutex.lockUncancelable(self.client.io);
        defer self.client.registry_mutex.unlock(self.client.io);
        const runtime = self.client.findExtensionRuntimeGenerationLocked(
            self.id,
            self.generation,
        ) orelse return .{};
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
                self.client.registry_mutex.lockUncancelable(self.client.io);
                defer self.client.registry_mutex.unlock(self.client.io);
                const runtime = self.client.findExtensionRuntimeGenerationLocked(
                    self.id,
                    self.generation,
                ) orelse
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
        self.client.registry_mutex.lockUncancelable(self.client.io);
        const supports_canvases = if (self.client.findExtensionRuntimeGenerationLocked(
            self.id,
            self.generation,
        )) |runtime|
            runtime.capabilities.supports(.canvases)
        else
            false;
        self.client.registry_mutex.unlock(self.client.io);
        if (!supports_canvases) return error.UnsupportedCapability;
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
        self.client.registry_mutex.lockUncancelable(self.client.io);
        defer self.client.registry_mutex.unlock(self.client.io);
        const runtime = self.client.findExtensionRuntimeGenerationLocked(
            self.id,
            self.generation,
        ) orelse {
            ext.freeOpenCanvas(self.client.allocator, state_value);
            return error.SessionDisconnected;
        };
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
        self.client.registry_mutex.lockUncancelable(self.client.io);
        const supports_canvases = if (self.client.findExtensionRuntimeGenerationLocked(
            self.id,
            self.generation,
        )) |runtime|
            runtime.capabilities.supports(.canvases)
        else
            false;
        self.client.registry_mutex.unlock(self.client.io);
        if (!supports_canvases) return error.UnsupportedCapability;
        const parsed = try self.client.call(std.json.Value, "session.canvas.close", .{
            .sessionId = self.id,
            .instanceId = instance_id,
        });
        parsed.deinit();
        self.client.registry_mutex.lockUncancelable(self.client.io);
        defer self.client.registry_mutex.unlock(self.client.io);
        const runtime = self.client.findExtensionRuntimeGenerationLocked(
            self.id,
            self.generation,
        ) orelse
            return error.SessionDisconnected;
        removeOpenCanvas(runtime, self.client.allocator, instance_id);
    }

    pub fn invokeCanvasAction(
        self: Session,
        allocator: std.mem.Allocator,
        request: ext.InvokeCanvasActionRequest,
    ) !ext.OwnedJson {
        self.client.registry_mutex.lockUncancelable(self.client.io);
        const supports_canvases = if (self.client.findExtensionRuntimeGenerationLocked(
            self.id,
            self.generation,
        )) |runtime|
            runtime.capabilities.supports(.canvases)
        else
            false;
        self.client.registry_mutex.unlock(self.client.io);
        if (!supports_canvases) return error.UnsupportedCapability;
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
        self.client.registry_mutex.lockUncancelable(self.client.io);
        defer self.client.registry_mutex.unlock(self.client.io);
        const runtime = self.client.findExtensionRuntimeGenerationLocked(
            self.id,
            self.generation,
        ) orelse
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
        self.client.registry_mutex.lockUncancelable(self.client.io);
        defer self.client.registry_mutex.unlock(self.client.io);
        const runtime = self.client.findExtensionRuntimeGenerationLocked(
            self.id,
            self.generation,
        ) orelse return .{
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

    fn handleMcpAuthEvent(
        self: Session,
        origin_log: *event_log.EventLog,
        data_json: []const u8,
    ) !void {
        var acquired = self.client.acquireMcpAuthHandler(
            self.id,
            origin_log,
        ) orelse return;
        defer acquired.lease.deinit();
        const registered = acquired.value;
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
        var outcome = invokeMcpAuthHandler(registered.handler, self.client.allocator, .{
            .request_id = parsed.value.requestId,
            .server_name = parsed.value.serverName,
            .server_url = parsed.value.serverUrl,
            .reason = parsed.value.reason,
            .resource_metadata = parsed.value.resourceMetadata,
            .www_authenticate_json = www_json,
            .http_response_json = http_json,
            .static_client_config_json = static_json,
        }, registered.context);
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
        const removal = try self.client.prepareSessionRemoval(
            self.id,
            self.generation,
        );
        var removal_started = false;
        defer if (!removal_started) self.client.cancelPreparedSessionRemoval(removal);
        const released_oauth_interest =
            try self.client.releaseMcpOAuthInterestForSession(
                self.id,
                removal.log_lease.log.generation,
            );
        errdefer if (released_oauth_interest) {
            self.client.registerMcpOAuthInterestForSession(
                self.id,
                removal.log_lease.log.generation,
            ) catch {};
        };
        for (0..2) |_| {
            const parsed = try self.client.call(struct {
                success: bool,
                @"error": ?[]const u8 = null,
            }, "session.detach", .{
                .sessionId = self.id,
            });
            defer parsed.deinit();
            if (parsed.value.success) {
                removal_started = true;
                const owner: SendOperationOwner =
                    if (removal.log_lease.log.hasActiveCallbacks()) .reaper else .waiter;
                self.client.startSessionRemoval(removal, owner);
                if (owner == .waiter) {
                    self.client.finishSessionRemoval(removal);
                }
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
        self.session.client.registry_mutex.lockUncancelable(self.session.client.io);
        defer self.session.client.registry_mutex.unlock(self.session.client.io);
        const runtime = self.session.client.findExtensionRuntimeGenerationLocked(
            self.session.id,
            self.session.generation,
        ) orelse
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
        .ignore_eof = true,
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
    defer {
        deinitTestMessaging(&client);
        client.user_input_handlers.deinit(allocator);
    }

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
    _ = try client.ensureEventLog("session-1");

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
        deinitTestMessaging(&client);
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
    try appendTestEvent(
        &client,
        "session-1",
        try session_types.parseEvent(allocator, parsed_event.value),
    );

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
        deinitTestMessaging(&client);
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
    try appendTestEvent(
        &client,
        "session-1",
        try session_types.parseEvent(allocator, parsed_event.value),
    );

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
        deinitTestMessaging(&client);
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
    try appendTestEvent(
        &client,
        "session-1",
        try session_types.parseEvent(allocator, parsed_event.value),
    );

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
        deinitTestMessaging(&client);
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
    try appendTestEvent(
        &client,
        "managed-session",
        try session_types.parseEvent(allocator, managed_session_event.value),
    );

    const managed_request_event = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"permission.requested","data":{"requestId":"permission-2","permissionRequest":{"kind":"future-kind","managedApprovalRequired":true}}}
    ,
        .{},
    );
    defer managed_request_event.deinit();
    try appendTestEvent(
        &client,
        "managed-request",
        try session_types.parseEvent(allocator, managed_request_event.value),
    );

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
        .ignore_eof = true,
    };
    try client.session_ids.append(allocator, try allocator.dupe(u8, "session-1"));
    defer {
        client.removeSession("session-1");
        deinitTestMessaging(&client);
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
    try appendTestEvent(
        &client,
        "session-1",
        try session_types.parseEvent(allocator, parsed_event.value),
    );

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
        deinitTestMessaging(&client);
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
    try appendTestEvent(
        &client,
        "session-1",
        try session_types.parseEvent(allocator, parsed_event.value),
    );

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

fn deinitTestMessaging(client: *Client) void {
    client.stopEventProcessor();
    if (client.pump_future) |*pump| _ = pump.cancel(client.io) catch {};
    client.stopSessionRemovalReaper();
    client.finishSessionRemovals();
    client.stopSendReaper();
    client.finishSendOperations();
    for (client.pending_calls.items) |pending| {
        if (pending.response) |response| client.allocator.free(response);
    }
    client.pending_calls.deinit(client.allocator);
    client.event_queue.deinit(client.allocator);
    for (client.event_logs.items) |session_log| {
        session_log.deinit();
        client.allocator.destroy(session_log);
    }
    client.event_logs.deinit(client.allocator);
}

fn appendTestEvent(
    client: *Client,
    session_id: []const u8,
    initial_event: session_types.SessionEvent,
) !void {
    const session_log = try client.ensureEventLog(session_id);
    var event = initial_event;
    try client.applyExtensionEvent(session_id, session_log.generation, &event);
    try (Session{
        .client = client,
        .id = session_id,
        .generation = session_log.generation,
    }).processEvent(session_log, &event);
    try session_log.observeTurnEvent(event);
    try session_log.append(event);
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
        .ignore_eof = true,
    };
    defer {
        deinitTestMessaging(&client);
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

test "session.send serializes every stable attachment and message option" {
    const attachments = [_]session_types.MessageAttachment{
        .{ .file = .{
            .path = "/tmp/a.zig",
            .display_name = "a.zig",
        } },
        .{ .directory = .{
            .path = "/tmp/src",
            .display_name = "src",
        } },
        .{ .selection = .{
            .file_path = "/tmp/a.zig",
            .display_name = "a",
            .selection = .{
                .start = .{ .line = 1, .character = 2 },
                .end = .{ .line = 1, .character = 14 },
            },
            .text = "const a = 1;",
        } },
        .{ .blob = .{
            .data = "aGVsbG8=",
            .mime_type = "text/plain",
            .display_name = "hello.txt",
        } },
    };
    const headers = [_]session_types.RequestHeader{
        .{ .name = "x-request-id", .value = "42" },
    };

    const result = try runSendRpc(std.testing.allocator, .{
        .prompt = "inspect",
        .source = .{ .agent = "reviewer" },
        .attachments = &attachments,
        .mode = .immediate,
        .agent_mode = .interactive,
        .request_headers = &headers,
        .display_prompt = "Inspect the selected code.",
    });
    defer std.testing.allocator.free(result.message_id);
    defer std.testing.allocator.free(result.request_body);

    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"method":"session.send","params":{"sessionId":"session-1","prompt":"inspect","source":"agent-reviewer","attachments":[{"type":"file","path":"/tmp/a.zig","displayName":"a.zig"},{"type":"directory","path":"/tmp/src","displayName":"src"},{"type":"selection","filePath":"/tmp/a.zig","displayName":"a","selection":{"start":{"line":1,"character":2},"end":{"line":1,"character":14}},"text":"const a = 1;"},{"type":"blob","data":"aGVsbG8=","mimeType":"text/plain","displayName":"hello.txt"}],"mode":"immediate","agentMode":"interactive","requestHeaders":{"x-request-id":"42"},"displayPrompt":"Inspect the selected code."}}
    , result.request_body);
}

test "session.send preserves absent attachment display names" {
    const attachments = [_]session_types.MessageAttachment{
        .{ .file = .{ .path = "/tmp/a.zig" } },
        .{ .directory = .{ .path = "/tmp" } },
        .{ .selection = .{
            .file_path = "/tmp/a.zig",
            .display_name = "selection",
        } },
        .{ .blob = .{ .data = "YQ==", .mime_type = "text/plain" } },
    };

    const result = try runSendRpc(std.testing.allocator, .{
        .prompt = "inspect",
        .attachments = &attachments,
    });
    defer std.testing.allocator.free(result.message_id);
    defer std.testing.allocator.free(result.request_body);

    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"method":"session.send","params":{"sessionId":"session-1","prompt":"inspect","attachments":[{"type":"file","path":"/tmp/a.zig"},{"type":"directory","path":"/tmp"},{"type":"selection","filePath":"/tmp/a.zig","displayName":"selection"},{"type":"blob","data":"YQ==","mimeType":"text/plain"}]}}
    , result.request_body);
}

test "session.send preserves omitted and empty collections" {
    const omitted = try runSendRpc(std.testing.allocator, .{
        .prompt = "omitted",
        .attachments = null,
        .request_headers = null,
    });
    defer std.testing.allocator.free(omitted.message_id);
    defer std.testing.allocator.free(omitted.request_body);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"method":"session.send","params":{"sessionId":"session-1","prompt":"omitted"}}
    , omitted.request_body);

    const empty = try runSendRpc(std.testing.allocator, .{
        .prompt = "empty",
        .attachments = &.{},
        .request_headers = &.{},
    });
    defer std.testing.allocator.free(empty.message_id);
    defer std.testing.allocator.free(empty.request_body);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"method":"session.send","params":{"sessionId":"session-1","prompt":"empty","attachments":[],"requestHeaders":{}}}
    , empty.request_body);
}

test "session.send preserves all selection optionality combinations" {
    const attachments = [_]session_types.MessageAttachment{
        .{ .selection = .{ .file_path = "a", .display_name = "neither" } },
        .{ .selection = .{
            .file_path = "b",
            .display_name = "range",
            .selection = .{
                .start = .{ .line = 1, .character = 2 },
                .end = .{ .line = 3, .character = 4 },
            },
        } },
        .{ .selection = .{
            .file_path = "c",
            .display_name = "text",
            .text = "",
        } },
        .{ .selection = .{
            .file_path = "d",
            .display_name = "both",
            .selection = .{
                .start = .{ .line = 5, .character = 6 },
                .end = .{ .line = 7, .character = 8 },
            },
            .text = "selected",
        } },
    };
    const result = try runSendRpc(std.testing.allocator, .{
        .prompt = "selections",
        .source = .system,
        .attachments = &attachments,
        .mode = .enqueue,
        .agent_mode = .shell,
    });
    defer std.testing.allocator.free(result.message_id);
    defer std.testing.allocator.free(result.request_body);

    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"method":"session.send","params":{"sessionId":"session-1","prompt":"selections","source":"system","attachments":[{"type":"selection","filePath":"a","displayName":"neither"},{"type":"selection","filePath":"b","displayName":"range","selection":{"start":{"line":1,"character":2},"end":{"line":3,"character":4}}},{"type":"selection","filePath":"c","displayName":"text","text":""},{"type":"selection","filePath":"d","displayName":"both","selection":{"start":{"line":5,"character":6},"end":{"line":7,"character":8}},"text":"selected"}],"mode":"enqueue","agentMode":"shell"}}
    , result.request_body);
}

test "message source and agent mode values lower exactly" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        options: session_types.MessageOptions,
        source: ?[]const u8,
        expected: []const u8,
    }{
        .{
            .options = .{ .prompt = "p", .source = .user, .agent_mode = .plan },
            .source = "user",
            .expected = "{\"sessionId\":\"s\",\"prompt\":\"p\",\"source\":\"user\",\"agentMode\":\"plan\"}",
        },
        .{
            .options = .{ .prompt = "p", .source = .system, .agent_mode = .autopilot },
            .source = "system",
            .expected = "{\"sessionId\":\"s\",\"prompt\":\"p\",\"source\":\"system\",\"agentMode\":\"autopilot\"}",
        },
        .{
            .options = .{ .prompt = "p", .source = .{ .agent = "reviewer" } },
            .source = "agent-reviewer",
            .expected = "{\"sessionId\":\"s\",\"prompt\":\"p\",\"source\":\"agent-reviewer\"}",
        },
    };
    for (cases) |case| {
        const json = try std.json.Stringify.valueAlloc(
            allocator,
            lowerMessage("s", case.options, case.source),
            .{ .emit_null_optional_fields = false },
        );
        defer allocator.free(json);
        try std.testing.expectEqualStrings(case.expected, json);
    }
}

test "invalid outbound source and headers are rejected before writing" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const request_file = try tmp.dir.createFile(std.testing.io, "requests", .{});
    defer request_file.close(std.testing.io);
    var writer_buffer: [1024]u8 = undefined;
    var writer = request_file.writer(std.testing.io, &writer_buffer);
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = undefined,
        .writer = &writer,
        .reader_buffer = &.{},
        .writer_buffer = &writer_buffer,
    };
    defer deinitTestMessaging(&client);
    const active_session = Session{ .client = &client, .id = "s1" };

    try std.testing.expectError(
        error.InvalidMessageSource,
        active_session.send(.{ .prompt = "p", .source = .{ .agent = "" } }),
    );
    try std.testing.expectError(
        error.InvalidRequestHeaderName,
        active_session.send(.{
            .prompt = "p",
            .request_headers = &.{.{ .name = "bad:name", .value = "v" }},
        }),
    );
    try std.testing.expectError(
        error.DuplicateRequestHeader,
        active_session.send(.{
            .prompt = "p",
            .request_headers = &.{
                .{ .name = "X-Trace", .value = "one" },
                .{ .name = "x-trace", .value = "two" },
            },
        }),
    );

    try writer.interface.flush();
    const requests = try tmp.dir.readFileAlloc(
        std.testing.io,
        "requests",
        allocator,
        .limited(1024),
    );
    defer allocator.free(requests);
    try std.testing.expectEqualStrings("", requests);
}

test "sendAndWait default is sixty seconds" {
    const options: session_types.WaitOptions = .{};
    try std.testing.expectEqual(
        @as(?u64, 60 * std.time.ns_per_s),
        options.timeout_ns,
    );
}

test "session.sendAndWait cleans its message id and returns an owned assistant message" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const response_body =
        \\{"jsonrpc":"2.0","id":1,"result":{"messageId":"temporary-id"}}
    ;
    const user_event =
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"session-1","event":{"type":"user.message","data":{"content":"inspect","messageId":"temporary-id","turnId":"turn-1"}}}}
    ;
    const message_event =
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"session-1","event":{"type":"assistant.message","data":{"content":"answer","messageId":"assistant-id","turnId":"turn-1"}}}}
    ;
    const turn_end_event =
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"session-1","event":{"type":"assistant.turn_end","data":{"turnId":"turn-1"}}}}
    ;
    const response_frame = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}",
        .{
            response_body.len,
            response_body,
            user_event.len,
            user_event,
            message_event.len,
            message_event,
            turn_end_event.len,
            turn_end_event,
        },
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
        deinitTestMessaging(&client);
        client.session_ids.deinit(allocator);
    }

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
        \\{"jsonrpc":"2.0","id":1,"method":"session.send","params":{"sessionId":"session-1","prompt":"inspect","attachments":[{"type":"file","path":"/tmp/a.zig"}]}}
    , request_body);
}

test "sendAndWait preserves events for nextEvent and explicit subscribers" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const response_body =
        \\{"jsonrpc":"2.0","id":1,"result":{"messageId":"temporary-id"}}
    ;
    const user_event =
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"session-1","event":{"type":"user.message","data":{"content":"answer","messageId":"temporary-id","turnId":"turn-1"}}}}
    ;
    const message_event =
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"session-1","event":{"type":"assistant.message","data":{"content":"answer","messageId":"assistant-id","turnId":"turn-1"}}}}
    ;
    const turn_end_event =
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"session-1","event":{"type":"assistant.turn_end","data":{"turnId":"turn-1"}}}}
    ;
    const responses = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}",
        .{
            response_body.len,
            response_body,
            user_event.len,
            user_event,
            message_event.len,
            message_event,
            turn_end_event.len,
            turn_end_event,
        },
    );
    defer allocator.free(responses);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = responses });
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
        .writer_buffer = &writer_buffer,
    };
    defer deinitTestMessaging(&client);
    const active_session = Session{ .client = &client, .id = "session-1" };
    var observer = try active_session.subscribe();
    defer observer.deinit();

    const response = (try active_session.sendAndWait(.{ .prompt = "answer" })).?;
    defer response.deinit(allocator);

    var compatibility_user = try active_session.nextEvent();
    defer compatibility_user.deinit(allocator);
    var compatibility_message = try active_session.nextEvent();
    defer compatibility_message.deinit(allocator);
    var compatibility_turn_end = try active_session.nextEvent();
    defer compatibility_turn_end.deinit(allocator);
    var observer_user = try observer.nextEvent();
    defer observer_user.deinit(allocator);
    var observer_message = try observer.nextEvent();
    defer observer_message.deinit(allocator);
    var observer_turn_end = try observer.nextEvent();
    defer observer_turn_end.deinit(allocator);

    try std.testing.expectEqualStrings("answer", response.content);
    try std.testing.expect(compatibility_user == .user_message);
    try std.testing.expectEqualStrings(
        "answer",
        compatibility_message.assistant_message.content,
    );
    try std.testing.expect(compatibility_turn_end == .assistant_turn_end);
    try std.testing.expect(observer_user == .user_message);
    try std.testing.expectEqualStrings("answer", observer_message.assistant_message.content);
    try std.testing.expect(observer_turn_end == .assistant_turn_end);
}

test "sendAndWaitWithOptions times out locally without aborting the session" {
    const allocator = std.testing.allocator;
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
        .writer_buffer = &writer_buffer,
        .ignore_eof = true,
    };
    defer deinitTestMessaging(&client);

    try std.testing.expectError(
        error.Timeout,
        (Session{ .client = &client, .id = "session-1" }).sendAndWaitWithOptions(
            .{ .prompt = "wait" },
            .{ .timeout_ns = std.time.ns_per_ms },
        ),
    );
    const request_frame = try tmp.dir.readFileAlloc(
        std.testing.io,
        "request",
        allocator,
        .limited(4096),
    );
    defer allocator.free(request_frame);
    try std.testing.expect(std.mem.indexOf(u8, request_frame, "\"method\":\"session.send\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request_frame, "session.abort") == null);
}

test "cancellation before send emits no request" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const request_file = try tmp.dir.createFile(std.testing.io, "request", .{});
    defer request_file.close(std.testing.io);
    var writer_buffer: [1024]u8 = undefined;
    var writer = request_file.writer(std.testing.io, &writer_buffer);
    var cancellation: session_types.Cancellation = .{};
    cancellation.cancel(std.testing.io);
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = undefined,
        .writer = &writer,
        .reader_buffer = &.{},
        .writer_buffer = &writer_buffer,
    };
    defer deinitTestMessaging(&client);

    try std.testing.expectError(
        error.Canceled,
        (Session{ .client = &client, .id = "session-1" }).sendAndWaitWithOptions(
            .{ .prompt = "do not send" },
            .{ .cancellation = &cancellation },
        ),
    );
    try writer.interface.flush();
    const requests = try tmp.dir.readFileAlloc(
        std.testing.io,
        "request",
        allocator,
        .limited(4096),
    );
    defer allocator.free(requests);
    try std.testing.expectEqual(@as(usize, 0), requests.len);
}

test "cancellation after send stops only the local wait" {
    const allocator = std.testing.allocator;
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
        .writer_buffer = &writer_buffer,
        .ignore_eof = true,
    };
    defer deinitTestMessaging(&client);
    var cancellation: session_types.Cancellation = .{};
    var cancel_future = std.testing.io.async(struct {
        fn run(value: *session_types.Cancellation) anyerror!void {
            try std.Io.sleep(
                std.testing.io,
                std.Io.Duration.fromMilliseconds(5),
                .awake,
            );
            value.cancel(std.testing.io);
        }
    }.run, .{&cancellation});
    defer _ = cancel_future.cancel(std.testing.io) catch {};

    try std.testing.expectError(
        error.Canceled,
        (Session{ .client = &client, .id = "session-1" }).sendAndWaitWithOptions(
            .{ .prompt = "wait" },
            .{ .timeout_ns = null, .cancellation = &cancellation },
        ),
    );
    try cancel_future.await(std.testing.io);
    const request_frame = try tmp.dir.readFileAlloc(
        std.testing.io,
        "request",
        allocator,
        .limited(4096),
    );
    defer allocator.free(request_frame);
    try std.testing.expect(std.mem.indexOf(u8, request_frame, "\"method\":\"session.send\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request_frame, "session.abort") == null);
}

test "timeout covers the pending send RPC" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = "" });
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
        .ignore_eof = true,
    };
    defer deinitTestMessaging(&client);

    try std.testing.expectError(
        error.Timeout,
        (Session{ .client = &client, .id = "s1" }).sendAndWaitWithOptions(
            .{ .prompt = "wait" },
            .{ .timeout_ns = std.time.ns_per_ms },
        ),
    );

    const requests = try tmp.dir.readFileAlloc(
        std.testing.io,
        "requests",
        allocator,
        .limited(4096),
    );
    defer allocator.free(requests);
    try std.testing.expect(std.mem.indexOf(u8, requests, "\"method\":\"session.send\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, requests, "session.abort") == null);
}

test "cancellation covers the pending send RPC" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = "" });
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
        .ignore_eof = true,
    };
    defer deinitTestMessaging(&client);
    var cancellation: session_types.Cancellation = .{};
    var cancel_future = std.testing.io.async(struct {
        fn run(value: *session_types.Cancellation) anyerror!void {
            try std.Io.sleep(
                std.testing.io,
                std.Io.Duration.fromMilliseconds(5),
                .awake,
            );
            value.cancel(std.testing.io);
        }
    }.run, .{&cancellation});
    defer _ = cancel_future.cancel(std.testing.io) catch {};

    try std.testing.expectError(
        error.Canceled,
        (Session{ .client = &client, .id = "s1" }).sendAndWaitWithOptions(
            .{ .prompt = "wait" },
            .{ .timeout_ns = null, .cancellation = &cancellation },
        ),
    );
    try cancel_future.await(std.testing.io);

    const requests = try tmp.dir.readFileAlloc(
        std.testing.io,
        "requests",
        allocator,
        .limited(4096),
    );
    defer allocator.free(requests);
    try std.testing.expect(std.mem.indexOf(u8, requests, "\"method\":\"session.send\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, requests, "session.abort") == null);
}

test "immediate send writes while another turn waiter is active" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = "" });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{});
    defer response_file.close(std.testing.io);
    var reader_buffer: [1024]u8 = undefined;
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
        .writer_buffer = &writer_buffer,
        .ignore_eof = true,
    };
    defer deinitTestMessaging(&client);
    const active_session = Session{ .client = &client, .id = "s1" };

    var waiter = std.testing.io.async(struct {
        fn run(value: Session) anyerror!void {
            const response = try value.sendAndWaitWithOptions(
                .{ .prompt = "first" },
                .{ .timeout_ns = null },
            );
            if (response) |message| message.deinit(value.client.allocator);
        }
    }.run, .{active_session});
    defer _ = waiter.cancel(std.testing.io) catch {};
    try std.Io.sleep(
        std.testing.io,
        std.Io.Duration.fromMilliseconds(5),
        .awake,
    );

    var immediate = std.testing.io.async(struct {
        fn run(value: Session) anyerror!void {
            const id = try value.send(.{ .prompt = "second", .mode = .immediate });
            value.client.allocator.free(id);
        }
    }.run, .{active_session});
    defer _ = immediate.cancel(std.testing.io) catch {};

    var request_count: usize = 0;
    for (0..100) |_| {
        const requests = try tmp.dir.readFileAlloc(
            std.testing.io,
            "requests",
            allocator,
            .limited(8192),
        );
        request_count = std.mem.count(u8, requests, "\"method\":\"session.send\"");
        allocator.free(requests);
        if (request_count == 2) break;
        try std.Io.sleep(
            std.testing.io,
            std.Io.Duration.fromMilliseconds(1),
            .awake,
        );
    }
    try std.testing.expectEqual(@as(usize, 2), request_count);
    client.finishPump(error.TestTransportStopped);
    try std.testing.expectError(error.TestTransportStopped, waiter.await(std.testing.io));
    try std.testing.expectError(error.TestTransportStopped, immediate.await(std.testing.io));
}

test "completed send remains owned by its waiter while the reaper runs" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer deinitTestMessaging(&client);
    const log = try client.ensureEventLog("s1");
    const receipt = try log.reserveTurn(.waited);
    const operation = try allocator.create(SendOperation);
    operation.* = .{
        .client = &client,
        .log_lease = try client.acquireEventLog("s1", log.generation, false),
        .receipt = receipt,
        .request_id = 1,
        .request = &.{},
    };
    try client.send_operations.append(allocator, operation);
    operation.future = std.testing.io.async(struct {
        fn run() anyerror!void {}
    }.run, .{});
    operation.completed.set(std.testing.io);

    client.reapSendOperations();
    try std.testing.expectEqual(@as(usize, 1), client.send_operations.items.len);
    const claimed = client.claimCompletedSendOperation(operation, .waiter) orelse
        return error.TestExpectedWaiterClaim;
    try client.destroyClaimedSendOperation(claimed);
    try std.testing.expectEqual(@as(usize, 0), client.send_operations.items.len);
}

test "failed send admission abandons its waited turn receipt" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer deinitTestMessaging(&client);
    const log = try client.ensureEventLog("s1");
    for (0..detached_send_limit) |_| {
        const operation = try allocator.create(SendOperation);
        operation.* = .{
            .client = &client,
            .log_lease = try client.acquireEventLog("s1", log.generation, false),
            .receipt = .{ .slot = 0, .generation = 0 },
            .request_id = 0,
            .request = &.{},
        };
        try client.send_operations.append(allocator, operation);
    }
    const active_session = Session{
        .client = &client,
        .id = "s1",
        .generation = log.generation,
    };

    for (0..40) |_| {
        try std.testing.expectError(
            error.TooManyPendingSends,
            active_session.sendAndWaitWithOptions(
                .{ .prompt = "blocked" },
                .{ .timeout_ns = null },
            ),
        );
    }
}

test "detached send lease keeps a closed log alive through a late response" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = "" });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{});
    defer response_file.close(std.testing.io);
    const response_sink = try tmp.dir.openFile(
        std.testing.io,
        "responses",
        .{ .mode = .write_only },
    );
    defer response_sink.close(std.testing.io);
    var response_buffer: [1024]u8 = undefined;
    var response_writer = response_sink.writer(std.testing.io, &response_buffer);
    var reader_buffer: [1024]u8 = undefined;
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
        .writer_buffer = &writer_buffer,
        .ignore_eof = true,
    };
    defer deinitTestMessaging(&client);
    const log = try client.ensureEventLog("s1");
    const active_session = Session{
        .client = &client,
        .id = "s1",
        .generation = log.generation,
    };
    try std.testing.expectError(
        error.Timeout,
        active_session.sendAndWaitWithOptions(
            .{ .prompt = "wait" },
            .{ .timeout_ns = std.time.ns_per_ms },
        ),
    );
    var disconnect_future = std.testing.io.async(struct {
        fn run(value: Session) anyerror!void {
            try value.disconnect();
        }
    }.run, .{active_session});
    defer _ = disconnect_future.cancel(std.testing.io) catch {};
    var detach_written = false;
    for (0..100) |_| {
        const requests = try tmp.dir.readFileAlloc(
            std.testing.io,
            "requests",
            allocator,
            .limited(8192),
        );
        const has_detach =
            std.mem.indexOf(u8, requests, "\"method\":\"session.detach\"") != null;
        allocator.free(requests);
        if (has_detach) {
            detach_written = true;
            break;
        }
        try std.Io.sleep(
            std.testing.io,
            std.Io.Duration.fromMilliseconds(1),
            .awake,
        );
    }
    try std.testing.expect(detach_written);
    const detach_response =
        \\{"jsonrpc":"2.0","id":2,"result":{"success":true}}
    ;
    try json_rpc.writeFrame(&response_writer.interface, detach_response);
    try response_writer.interface.flush();
    try disconnect_future.await(std.testing.io);

    client.reclaimClosedEventLogs();
    try std.testing.expectEqual(@as(usize, 1), client.event_logs.items.len);

    const send_response =
        \\{"jsonrpc":"2.0","id":1,"result":{"messageId":"late-message"}}
    ;
    try json_rpc.writeFrame(&response_writer.interface, send_response);
    try response_writer.interface.flush();
    var reclaimed = false;
    for (0..100) |_| {
        client.send_operations_mutex.lockUncancelable(std.testing.io);
        const send_count = client.send_operations.items.len;
        client.send_operations_mutex.unlock(std.testing.io);
        client.event_logs_mutex.lockUncancelable(std.testing.io);
        const log_count = client.event_logs.items.len;
        client.event_logs_mutex.unlock(std.testing.io);
        if (send_count == 0 and log_count == 0) {
            reclaimed = true;
            break;
        }
        try std.Io.sleep(
            std.testing.io,
            std.Io.Duration.fromMilliseconds(1),
            .awake,
        );
    }
    try std.testing.expect(reclaimed);
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
            .ignore_eof = true,
        };
        defer {
            deinitTestMessaging(&client);
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
        deinitTestMessaging(&client);
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
    try client.applyExtensionEvent("s1", 0, &session_event);
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
        client.applyExtensionEvent("s1", 0, &opened_event),
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
    try client.beginExtensionRuntime("s1", session_types.CreateSessionConfig{
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
    try client.beginExtensionRuntime("s1", session_types.CreateSessionConfig{
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
    try client.beginExtensionRuntime("new-session", session_types.CreateSessionConfig{
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
    try client.beginExtensionRuntime("s1", session_types.CreateSessionConfig{
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
    try client.beginExtensionRuntime("s1", session_types.CreateSessionConfig{
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
        .ignore_eof = true,
    };
    defer {
        deinitTestMessaging(&client);
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
    _ = try client.ensureEventLog("s1");
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

test "OAuth registration does not hold the registry mutex while waiting" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const hook_request =
        \\{"jsonrpc":"2.0","id":900,"method":"hooks.invoke","params":{"sessionId":"s1","hookType":"preToolUse","input":{"sessionId":"s1","timestamp":42,"cwd":"/repo","toolName":"shell","toolArgs":{}}}}
    ;
    const register_response =
        \\{"jsonrpc":"2.0","id":1,"result":{"handle":"interest-1"}}
    ;
    const responses = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}",
        .{
            hook_request.len,
            hook_request,
            register_response.len,
            register_response,
        },
    );
    defer allocator.free(responses);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = responses });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{});
    defer response_file.close(std.testing.io);
    var reader_buffer: [2048]u8 = undefined;
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
        .ignore_eof = true,
    };
    defer {
        deinitTestMessaging(&client);
        for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
        client.extension_runtimes.deinit(allocator);
    }
    var hook_called = false;
    const hook = struct {
        fn handle(
            _: std.mem.Allocator,
            _: ext.PreToolUseInput,
            _: ext.HookInvocation,
            context: ?*anyopaque,
        ) !ext.PreToolUseOutput {
            const called: *bool = @ptrCast(@alignCast(context.?));
            called.* = true;
            return .{};
        }
    }.handle;
    const auth = struct {
        fn handle(
            _: std.mem.Allocator,
            _: ext.McpAuthRequest,
            _: ?*anyopaque,
        ) !ext.McpAuthResult {
            return .cancelled;
        }
    }.handle;
    try client.beginExtensionRuntime("s1", session_types.ResumeSessionConfig{
        .extensions = .{ .common = .{
            .hooks = .{
                .on_pre_tool_use = hook,
                .context = &hook_called,
            },
            .mcp = .{ .on_auth_request = auth },
        } },
    }, &.{});

    try client.commitExtensionRuntime("s1", .{}, &.{});

    try std.testing.expect(hook_called);
    try std.testing.expectEqualStrings(
        "interest-1",
        client.findExtensionRuntime("s1").?.mcp_oauth_interest_handle.?,
    );
    const requests = try tmp.dir.readFileAlloc(
        std.testing.io,
        "requests",
        allocator,
        .limited(8192),
    );
    defer allocator.free(requests);
    try std.testing.expect(std.mem.indexOf(u8, requests, "\"id\":900,\"result\"") != null);
}

test "OAuth rollback does not hold the registry mutex while waiting" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const hook_request =
        \\{"jsonrpc":"2.0","id":901,"method":"hooks.invoke","params":{"sessionId":"s1","hookType":"preToolUse","input":{"sessionId":"s1","timestamp":42,"cwd":"/repo","toolName":"shell","toolArgs":{}}}}
    ;
    const release_response =
        \\{"jsonrpc":"2.0","id":1,"result":{"success":true}}
    ;
    const responses = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}",
        .{
            hook_request.len,
            hook_request,
            release_response.len,
            release_response,
        },
    );
    defer allocator.free(responses);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = responses });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{});
    defer response_file.close(std.testing.io);
    var reader_buffer: [2048]u8 = undefined;
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
        .ignore_eof = true,
    };
    defer {
        deinitTestMessaging(&client);
        for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
        client.extension_runtimes.deinit(allocator);
    }
    var hook_called = false;
    const hook = struct {
        fn handle(
            _: std.mem.Allocator,
            _: ext.PreToolUseInput,
            _: ext.HookInvocation,
            context: ?*anyopaque,
        ) !ext.PreToolUseOutput {
            const called: *bool = @ptrCast(@alignCast(context.?));
            called.* = true;
            return .{};
        }
    }.handle;
    try client.beginExtensionRuntime("s1", session_types.ResumeSessionConfig{
        .extensions = .{ .common = .{ .hooks = .{
            .on_pre_tool_use = hook,
            .context = &hook_called,
        } } },
    }, &.{});
    try client.commitExtensionRuntime("s1", .{}, &.{});
    try client.beginExtensionRuntime("s1", session_types.ResumeSessionConfig{}, &.{});
    client.pending_extension_runtime.?.mcp_oauth_interest_handle =
        try allocator.dupe(u8, "interest-1");

    client.rollbackExtensionRuntime();

    try std.testing.expect(hook_called);
    try std.testing.expect(client.pending_extension_runtime == null);
    const requests = try tmp.dir.readFileAlloc(
        std.testing.io,
        "requests",
        allocator,
        .limited(8192),
    );
    defer allocator.free(requests);
    try std.testing.expect(std.mem.indexOf(u8, requests, "\"id\":901,\"result\"") != null);
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
        .ignore_eof = true,
    };
    defer {
        deinitTestMessaging(&client);
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

test "concurrent disconnect preparation claims removal storage" {
    const allocator = std.testing.allocator;
    const session_count = 16;
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer deinitTestMessaging(&client);
    var session_ids: [session_count][]u8 = undefined;
    defer for (session_ids) |id| allocator.free(id);
    var preparations: [session_count]std.Io.Future(anyerror!*SessionRemoval) = undefined;
    for (&session_ids, 0..) |*id, index| {
        id.* = try std.fmt.allocPrint(allocator, "session-{d}", .{index});
        const log = try client.ensureEventLog(id.*);
        preparations[index] = std.testing.io.async(struct {
            fn run(
                value: *Client,
                session_id: []const u8,
                generation: u64,
            ) anyerror!*SessionRemoval {
                return value.prepareSessionRemoval(session_id, generation);
            }
        }.run, .{ &client, id.*, log.generation });
    }
    var removals: [session_count]*SessionRemoval = undefined;
    for (&preparations, 0..) |*preparation, index| {
        removals[index] = try preparation.await(std.testing.io);
    }
    try std.testing.expectEqual(session_count, client.session_removals.items.len);
    try std.testing.expect(client.session_removals.capacity >= session_count);
    for (removals) |removal| client.cancelPreparedSessionRemoval(removal);
    try std.testing.expectEqual(@as(usize, 0), client.session_removals.items.len);
}

test "tool callback can disconnect without waiting on its own lease" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const detach_response =
        \\{"jsonrpc":"2.0","id":1,"result":{"success":true}}
    ;
    const tool_response =
        \\{"jsonrpc":"2.0","id":2,"result":{"success":true}}
    ;
    const responses = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}",
        .{
            detach_response.len,
            detach_response,
            tool_response.len,
            tool_response,
        },
    );
    defer allocator.free(responses);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = responses });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{});
    defer response_file.close(std.testing.io);
    var reader_buffer: [2048]u8 = undefined;
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
        .ignore_eof = true,
    };
    defer {
        deinitTestMessaging(&client);
        for (client.tools.items) |tool| tool.deinit(allocator);
        client.tools.deinit(allocator);
        for (client.session_ids.items) |id| allocator.free(id);
        client.session_ids.deinit(allocator);
    }
    const owned_session_id = try allocator.dupe(u8, "s1");
    try client.session_ids.append(allocator, owned_session_id);
    const log = try client.ensureEventLog("s1");
    const active_session = Session{
        .client = &client,
        .id = owned_session_id,
        .generation = log.generation,
    };
    const CallbackContext = struct {
        session: Session,
        returned: bool = false,
    };
    var context = CallbackContext{ .session = active_session };
    const handler = struct {
        fn handle(
            callback_allocator: std.mem.Allocator,
            _: []const u8,
            callback_context: ?*anyopaque,
        ) ![]u8 {
            const state: *CallbackContext = @ptrCast(@alignCast(callback_context.?));
            try state.session.disconnect();
            state.returned = true;
            return callback_allocator.dupe(
                u8,
                "{\"textResultForLlm\":\"disconnected\"}",
            );
        }
    }.handle;
    try client.registerToolHandlers("s1", &.{.{
        .name = "disconnect",
        .handler = handler,
        .context = &context,
    }});
    var subscriber = try active_session.subscribe();
    defer subscriber.deinit();
    const params = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"sessionId":"s1","event":{"type":"external_tool.requested","data":{"requestId":"request-1","sessionId":"s1","toolCallId":"tool-1","toolName":"disconnect","arguments":{}}}}
    ,
        .{},
    );
    defer params.deinit();

    try client.queueSessionEvent(params.value);
    var event = try subscriber.nextEvent();
    defer event.deinit(allocator);
    try std.testing.expect(context.returned);
    try std.testing.expectEqualStrings(
        "disconnect",
        event.external_tool_requested.tool_name,
    );
    var removed = false;
    for (0..100) |_| {
        client.registry_mutex.lockUncancelable(std.testing.io);
        const session_count = client.session_ids.items.len;
        client.registry_mutex.unlock(std.testing.io);
        if (session_count == 0) {
            removed = true;
            break;
        }
        try std.Io.sleep(
            std.testing.io,
            std.Io.Duration.fromMilliseconds(1),
            .awake,
        );
    }
    try std.testing.expect(removed);
    try client.registerOwnedSession(
        try allocator.dupe(u8, "s1"),
        .{},
        &.{},
    );
    try std.testing.expect(client.findSessionId("s1") != null);
}

test "an unrelated active callback does not defer disconnect or same-id reuse" {
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
        .writer_buffer = &writer_buffer,
    };
    defer {
        deinitTestMessaging(&client);
        for (client.tools.items) |tool| tool.deinit(allocator);
        client.tools.deinit(allocator);
        for (client.session_ids.items) |id| allocator.free(id);
        client.session_ids.deinit(allocator);
    }
    try client.registerOwnedSession(
        try allocator.dupe(u8, "callback-session"),
        .{},
        &.{},
    );
    try client.registerOwnedSession(
        try allocator.dupe(u8, "disconnect-session"),
        .{},
        &.{},
    );
    _ = try client.ensureEventLog("callback-session");
    const disconnect_log = try client.ensureEventLog("disconnect-session");
    const handler = struct {
        fn handle(
            callback_allocator: std.mem.Allocator,
            _: []const u8,
            _: ?*anyopaque,
        ) ![]u8 {
            return callback_allocator.dupe(u8, "{}");
        }
    }.handle;
    try client.registerToolHandlers("callback-session", &.{.{
        .name = "held",
        .handler = handler,
    }});
    var held_callback = client.acquireToolHandler(
        "callback-session",
        null,
        "held",
    ) orelse return error.TestExpectedCallbackLease;
    defer held_callback.lease.deinit();

    try (Session{
        .client = &client,
        .id = "disconnect-session",
        .generation = disconnect_log.generation,
    }).disconnect();
    try std.testing.expect(client.findSessionId("disconnect-session") == null);
    try client.registerOwnedSession(
        try allocator.dupe(u8, "disconnect-session"),
        .{},
        &.{},
    );
    try std.testing.expect(client.findSessionId("disconnect-session") != null);
}

test "old-generation admitted callbacks retain old state without blocking new disconnect" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = "" });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{});
    defer response_file.close(std.testing.io);
    const response_sink = try tmp.dir.openFile(
        std.testing.io,
        "responses",
        .{ .mode = .write_only },
    );
    defer response_sink.close(std.testing.io);
    var response_buffer: [2048]u8 = undefined;
    var response_writer = response_sink.writer(std.testing.io, &response_buffer);
    var reader_buffer: [2048]u8 = undefined;
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
        .ignore_eof = true,
    };
    defer deinitTestClientRegistries(&client);

    const CallbackState = struct {
        session: ?Session = null,
        call_count: usize = 0,
        second_started: std.Io.Event = .unset,
        release_second: std.Io.Event = .unset,
    };
    var old_state = CallbackState{};
    const old_handler = struct {
        fn handle(
            _: session_types.PermissionRequested,
            _: session_types.PermissionInvocation,
            context: ?*anyopaque,
        ) !session_types.PermissionDecision {
            const state: *CallbackState = @ptrCast(@alignCast(context.?));
            state.call_count += 1;
            if (state.call_count == 1) {
                try state.session.?.disconnect();
            } else {
                state.second_started.set(state.session.?.client.io);
                try state.release_second.wait(state.session.?.client.io);
            }
            return .no_result;
        }
    }.handle;
    try client.registerOwnedSession(
        try allocator.dupe(u8, "s1"),
        .{
            .on_permission_request = old_handler,
            .permission_context = &old_state,
        },
        &.{},
    );
    const old_log = client.findEventLog("s1").?;
    const old_generation = old_log.generation;
    const old_session = Session{
        .client = &client,
        .id = client.findSessionId("s1").?,
        .generation = old_log.generation,
    };
    old_state.session = old_session;
    try old_log.beginIngress();
    try old_log.beginIngress();
    const first_response =
        \\{"jsonrpc":"2.0","id":1,"result":{"success":true}}
    ;
    try json_rpc.writeFrame(&response_writer.interface, first_response);
    try response_writer.interface.flush();
    const first_json = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"permission.requested","data":{"requestId":"permission-1","permissionRequest":{"kind":"shell","fullCommandText":"pwd","intention":"test","commands":[],"possiblePaths":[],"possibleUrls":[],"hasWriteFileRedirection":false,"canOfferSessionApproval":false}}}
    ,
        .{},
    );
    defer first_json.deinit();
    var first = try session_types.parseEvent(allocator, first_json.value);
    defer first.deinit(allocator);
    try old_session.processEvent(old_log, &first);
    old_log.finishIngress();

    var new_called = false;
    const new_handler = struct {
        fn handle(
            _: session_types.PermissionRequested,
            _: session_types.PermissionInvocation,
            context: ?*anyopaque,
        ) !session_types.PermissionDecision {
            const called: *bool = @ptrCast(@alignCast(context.?));
            called.* = true;
            return .no_result;
        }
    }.handle;
    try client.registerOwnedSession(
        try allocator.dupe(u8, "s1"),
        .{
            .on_permission_request = new_handler,
            .permission_context = &new_called,
        },
        &.{},
    );
    const new_log = client.findEventLog("s1").?;
    const new_session = Session{
        .client = &client,
        .id = client.findSessionId("s1").?,
        .generation = new_log.generation,
    };

    const second_json = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"permission.requested","data":{"requestId":"permission-2","permissionRequest":{"kind":"shell","fullCommandText":"pwd","intention":"test","commands":[],"possiblePaths":[],"possibleUrls":[],"hasWriteFileRedirection":false,"canOfferSessionApproval":false}}}
    ,
        .{},
    );
    defer second_json.deinit();
    var second = try session_types.parseEvent(allocator, second_json.value);
    defer second.deinit(allocator);
    var old_callback = std.testing.io.async(struct {
        fn run(
            session: Session,
            log: *event_log.EventLog,
            event: *session_types.SessionEvent,
        ) anyerror!void {
            defer log.finishIngress();
            try session.processEvent(log, event);
        }
    }.run, .{ old_session, old_log, &second });
    defer _ = old_callback.cancel(std.testing.io) catch {};
    try old_state.second_started.wait(std.testing.io);
    try std.testing.expectEqual(@as(usize, 2), old_state.call_count);
    try std.testing.expect(!new_called);

    var new_disconnect = std.testing.io.async(struct {
        fn run(session: Session) anyerror!void {
            try session.disconnect();
        }
    }.run, .{new_session});
    defer _ = new_disconnect.cancel(std.testing.io) catch {};
    for (0..100) |_| {
        const requests = try tmp.dir.readFileAlloc(
            std.testing.io,
            "requests",
            allocator,
            .limited(8192),
        );
        const count = std.mem.count(u8, requests, "\"method\":\"session.detach\"");
        allocator.free(requests);
        if (count == 2) break;
        try std.Io.sleep(
            std.testing.io,
            std.Io.Duration.fromMilliseconds(1),
            .awake,
        );
    } else return error.TestDetachRequestsNotWritten;
    const second_response =
        \\{"jsonrpc":"2.0","id":2,"result":{"success":true}}
    ;
    try json_rpc.writeFrame(&response_writer.interface, second_response);
    try response_writer.interface.flush();
    try new_disconnect.await(std.testing.io);
    try std.testing.expect(client.findSessionId("s1") == null);

    try client.registerOwnedSession(
        try allocator.dupe(u8, "s1"),
        .{},
        &.{},
    );
    const newest_log = client.findEventLog("s1").?;
    old_state.release_second.set(std.testing.io);
    try old_callback.await(std.testing.io);
    for (0..100) |_| {
        if (client.findEventLogGeneration("s1", old_generation) == null) break;
        try std.Io.sleep(
            std.testing.io,
            std.Io.Duration.fromMilliseconds(1),
            .awake,
        );
    }
    try std.testing.expect(client.findEventLogGeneration("s1", old_generation) == null);
    try std.testing.expect(client.findSessionId("s1") != null);
    try std.testing.expect(client.findEventLog("s1") == newest_log);
}

test "failed detach preserves events received during the attempt" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const first_detach =
        \\{"jsonrpc":"2.0","id":1,"result":{"success":false,"error":"busy"}}
    ;
    const first_event =
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"s1","event":{"type":"assistant.message","data":{"content":"first","messageId":"a1","turnId":"t1"}}}}
    ;
    const second_event =
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"s1","event":{"type":"assistant.message","data":{"content":"second","messageId":"a2","turnId":"t2"}}}}
    ;
    const second_detach =
        \\{"jsonrpc":"2.0","id":2,"result":{"success":false,"error":"busy"}}
    ;
    const responses = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}",
        .{
            first_detach.len,
            first_detach,
            first_event.len,
            first_event,
            second_event.len,
            second_event,
            second_detach.len,
            second_detach,
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
    var writer_buffer: [2048]u8 = undefined;
    var writer = request_file.writer(std.testing.io, &writer_buffer);
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = &reader,
        .writer = &writer,
        .reader_buffer = &.{},
        .writer_buffer = &writer_buffer,
        .ignore_eof = true,
    };
    defer deinitTestMessaging(&client);
    const log = try client.ensureEventLog("s1");
    const active_session = Session{
        .client = &client,
        .id = "s1",
        .generation = log.generation,
    };
    var subscriber = try active_session.subscribe();
    defer subscriber.deinit();

    try std.testing.expectError(error.SessionDetachFailed, active_session.disconnect());
    var first = try subscriber.nextEvent();
    defer first.deinit(allocator);
    var second = try subscriber.nextEvent();
    defer second.deinit(allocator);
    try std.testing.expectEqualStrings("first", first.assistant_message.content);
    try std.testing.expectEqualStrings("second", second.assistant_message.content);
    try std.testing.expect(log.isAcceptingIngress());
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
        .ignore_eof = true,
    };
    defer {
        if (client.pending_extension_runtime) |*runtime| runtime.deinit(allocator);
        deinitTestMessaging(&client);
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
    _ = try client.ensureEventLog("s1");
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

test "session.event notifications retain owned data by session" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer {
        deinitTestMessaging(&client);
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
    _ = try client.ensureEventLog("s1");
    try client.queueSessionEvent(parsed.value);

    const session_log = client.findEventLog("s1").?;
    var event = try client.nextSubscriberEvent(
        session_log,
        session_log.compatibilityToken(),
        null,
        null,
        null,
    );
    defer event.deinit(allocator);
    try std.testing.expectEqualStrings("hello", event.assistant_message.content);
}

test "unknown session events are rejected without allocating a log" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer deinitTestMessaging(&client);
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"sessionId":"unknown","event":{"type":"session.idle","data":{}}}
    ,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectError(
        error.UnknownSessionEvent,
        client.queueSessionEvent(parsed.value),
    );
    try std.testing.expectEqual(@as(usize, 0), client.event_logs.items.len);
}

test "unprocessed session event ingress is bounded" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer deinitTestMessaging(&client);
    const session_log = try client.ensureEventLog("s1");
    try session_log.processing_mutex.lock(std.testing.io);
    defer session_log.processing_mutex.unlock(std.testing.io);
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"sessionId":"s1","event":{"type":"session.idle","data":{}}}
    ,
        .{},
    );
    defer parsed.deinit();

    var overflowed = false;
    for (0..event_ingress_limit + 2) |_| {
        client.queueSessionEvent(parsed.value) catch |err| switch (err) {
            error.EventIngressOverflow => {
                overflowed = true;
                break;
            },
            else => return err,
        };
    }
    try std.testing.expect(overflowed);
}

test "matching turn completion wins over an expired deadline" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer deinitTestMessaging(&client);
    const session_log = try client.ensureEventLog("s1");
    const receipt = try session_log.reserveTurn(.waited);
    try session_log.bindTurnMessage(receipt, "message-1");
    const events = [_][]const u8{
        \\{"type":"user.message","data":{"content":"p","messageId":"message-1","turnId":"turn-1"}}
        ,
        \\{"type":"assistant.message","data":{"content":"answer","messageId":"assistant-1","turnId":"turn-1"}}
        ,
        \\{"type":"assistant.turn_end","data":{"turnId":"turn-1"}}
        ,
    };
    for (events) |json| {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
        defer parsed.deinit();
        var event = try session_types.parseEvent(allocator, parsed.value);
        defer event.deinit(allocator);
        try session_log.observeTurnEvent(event);
    }

    const deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .raw = std.Io.Duration.fromNanoseconds(0),
        .clock = .awake,
    });
    const result = (try (Session{
        .client = &client,
        .id = "s1",
    }).waitForTurn(session_log, receipt, deadline, null)).?;
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("answer", result.content);
}

test "unmatched and duplicate responses are discarded" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer deinitTestMessaging(&client);
    var pending = PendingCall{ .id = 1 };
    try client.pending_calls.append(allocator, &pending);
    defer {
        client.pending_calls.clearRetainingCapacity();
        if (pending.response) |response| allocator.free(response);
    }

    try client.routeFrame(
        \\{"jsonrpc":"2.0","id":1,"result":{"value":"first"}}
    );
    try client.routeFrame(
        \\{"jsonrpc":"2.0","id":1,"result":{"value":"duplicate"}}
    );
    try client.routeFrame(
        \\{"jsonrpc":"2.0","id":999,"result":{"value":"late"}}
    );

    try std.testing.expect(std.mem.indexOf(u8, pending.response.?, "first") != null);
    try std.testing.expect(std.mem.indexOf(u8, pending.response.?, "duplicate") == null);
    try std.testing.expectEqual(@as(usize, 1), client.pending_calls.items.len);
}

test "disconnect closes the session event log" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer {
        deinitTestMessaging(&client);
        for (client.tools.items) |tool| tool.deinit(allocator);
        client.tools.deinit(allocator);
        for (client.session_ids.items) |id| allocator.free(id);
        client.session_ids.deinit(allocator);
    }

    const session_id = try allocator.dupe(u8, "s1");
    try client.session_ids.append(allocator, session_id);
    const session_log = try client.ensureEventLog("s1");
    const token = session_log.compatibilityToken();
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"session.idle","data":{}}
    ,
        .{},
    );
    defer parsed.deinit();
    try session_log.append(try session_types.parseEvent(allocator, parsed.value));

    client.removeSession("s1");

    try std.testing.expectEqual(@as(usize, 0), client.session_ids.items.len);
    var retained = try session_log.inspect(token);
    try std.testing.expect(retained == .event);
    retained.event.deinit(allocator);
    try std.testing.expect((try session_log.inspect(token)) == .closed);
}

test "closed session logs are reclaimed after explicit subscribers release" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer deinitTestMessaging(&client);
    const session_log = try client.ensureEventLog("s1");
    var lease = try client.acquireEventLog("s1", session_log.generation, false);
    errdefer lease.deinit();
    var subscriber = try Session.subscribeTo(lease);

    client.removeSession("s1");

    try std.testing.expectEqual(@as(usize, 1), client.event_logs.items.len);
    subscriber.deinit();
    try std.testing.expectEqual(@as(usize, 0), client.event_logs.items.len);
}

test "repeated disconnect closes the active event log generation" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer deinitTestMessaging(&client);

    const first = try client.ensureEventLog("s1");
    const first_generation = first.generation;
    client.removeSession("s1");
    const second = try client.ensureEventLog("s1");
    const second_token = second.compatibilityToken();
    client.removeSession("s1");

    try std.testing.expect(client.findEventLogGeneration("s1", first_generation) == null);
    try std.testing.expect((try second.inspect(second_token)) == .closed);
}

test "closed compatibility logs are bounded even when nextEvent is not drained" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer deinitTestMessaging(&client);
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"session.idle","data":{}}
    ,
        .{},
    );
    defer parsed.deinit();

    var first_generation: u64 = 0;
    for (0..retained_log_limit + 1) |_| {
        const log = try client.ensureEventLog("s1");
        if (first_generation == 0) first_generation = log.generation;
        try log.append(try session_types.parseEvent(allocator, parsed.value));
        client.removeSession("s1");
    }

    try std.testing.expectEqual(retained_log_limit, client.event_logs.items.len);
    try std.testing.expect(client.findEventLogGeneration("s1", first_generation) == null);
}

test "stale session generation cannot remove a newer same-id session" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer deinitTestMessaging(&client);

    const first = try client.ensureEventLog("s1");
    const stale = Session{
        .client = &client,
        .id = "s1",
        .generation = first.generation,
    };
    client.removeSession("s1");
    const current = try client.ensureEventLog("s1");

    try std.testing.expectError(error.SessionDisconnected, stale.disconnect());
    try std.testing.expect(current.isAcceptingIngress());
    try std.testing.expect(client.findEventLogGeneration("s1", current.generation) == current);
}

test "event logs created after pump failure inherit the terminal error" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = std.testing.io,
        .child = null,
        .reader = undefined,
        .writer = undefined,
        .reader_buffer = &.{},
        .writer_buffer = &.{},
    };
    defer deinitTestMessaging(&client);

    client.finishPump(error.EndOfStream);

    try std.testing.expectError(
        error.EndOfStream,
        (Session{ .client = &client, .id = "s1" }).nextEvent(),
    );
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
        .ignore_eof = true,
    };
    defer {
        deinitTestMessaging(&client);
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
            .ignore_eof = true,
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
    deinitTestMessaging(client);
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
