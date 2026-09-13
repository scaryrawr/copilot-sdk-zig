const std = @import("std");
const json_rpc = @import("json_rpc.zig");
const models = @import("models.zig");
const provider = @import("provider.zig");
const protocol = @import("protocol_version.zig");
const session_types = @import("session.zig");
const ext = @import("extensibility.zig");

const max_queued_events: usize = 1024;
const event_queue_capacity_message = "SDK event queue capacity exceeded";

fn wipeSecret(value: []const u8) void {
    std.crypto.secureZero(u8, @constCast(@volatileCast(value)));
}

fn wipeAndFreeSecret(allocator: std.mem.Allocator, value: []u8) void {
    if (value.len == 0) return;
    wipeSecret(value);
    allocator.rawFree(value, .of(u8), @returnAddress());
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

const QueuedEvent = struct {
    id: u64 = 0,
    session_id: []u8,
    event: session_types.SessionEvent,
    automatic_handling_in_progress: bool = false,
    remove_after_automatic_handling: bool = false,

    fn deinit(self: *QueuedEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        self.event.deinit(allocator);
    }
};

const EventDeliveryClass = enum {
    observation,
    automatic,
    permission_request,
    external_tool_request,
};

const EventQueueFailure = enum {
    capacity_exceeded,
    allocation_failed,
    rejection_failed,
};

const BufferedResponse = struct {
    id: u64,
    body: []u8,

    fn deinit(self: *BufferedResponse, allocator: std.mem.Allocator) void {
        wipeSecret(self.body);
        allocator.free(self.body);
    }
};

const AutomaticEventTarget = union(enum) {
    queued: u64,
    transient: *session_types.SessionEvent,
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

const RuntimeCommand = struct {
    name: []u8,
    handler: session_types.CommandHandler,
    context: ?*anyopaque,
};

const WireMcpOAuthInterest = struct {
    handle: []const u8,
};

const OwnedMcpOAuthInterest = struct {
    response: std.json.Parsed(WireMcpOAuthInterest),

    fn handle(self: *const OwnedMcpOAuthInterest) []const u8 {
        return self.response.value.handle;
    }

    fn deinitSecure(self: *OwnedMcpOAuthInterest) void {
        wipeSecret(self.response.value.handle);
        self.response.deinit();
        self.* = undefined;
    }
};

const McpOAuthInterest = union(enum) {
    none,
    registering: enum {
        initial,
        restore,
    },
    registered: OwnedMcpOAuthInterest,
    releasing: OwnedMcpOAuthInterest,
    restore_required,
};

const McpOAuthRuntimeLocation = union(enum) {
    pending,
    committed,
    external: *SessionExtensionRuntime,
};

fn testMcpOAuthInterest(
    allocator: std.mem.Allocator,
    handle: []const u8,
) !McpOAuthInterest {
    const json = try std.fmt.allocPrint(allocator, "{{\"handle\":\"{s}\"}}", .{handle});
    defer allocator.free(json);
    return .{ .registered = .{
        .response = try std.json.parseFromSlice(
            WireMcpOAuthInterest,
            allocator,
            json,
            .{ .allocate = .alloc_always },
        ),
    } };
}

const SessionExtensionRuntime = struct {
    session_id: ?[]u8 = null,
    hooks: ext.SessionHooks,
    mcp_auth_handler: ?ext.McpAuthHandler,
    mcp_auth_context: ?*anyopaque,
    canvases: []OwnedCanvas,
    open_canvases: std.ArrayList(ext.OpenCanvas) = .empty,
    capabilities: ext.CapabilitySet = .{},
    mcp_apps_requested: bool,
    event_queue_failure: ?EventQueueFailure = null,
    tools: []RuntimeTool,
    commands: []RuntimeCommand,
    permission_handler: ?session_types.PermissionHandler,
    permission_context: ?*anyopaque,
    managed_settings_enabled: bool,
    user_input_handler: ?session_types.UserInputHandler,
    user_input_context: ?*anyopaque,
    elicitation_handler: ?session_types.ElicitationHandler,
    elicitation_context: ?*anyopaque,
    exit_plan_mode_handler: ?session_types.ExitPlanModeHandler,
    exit_plan_mode_context: ?*anyopaque,
    auto_mode_switch_handler: ?session_types.AutoModeSwitchHandler,
    auto_mode_switch_context: ?*anyopaque,
    git_hub_token_provider: ?session_types.GitHubTokenProvider,
    git_hub_token_registration_id: ?[]u8 = null,
    provider_tokens: ?[]RegisteredProviderToken = null,
    credentials_quarantined: bool = false,
    granted_environment_variables: std.ArrayList(ext.EnvironmentGrant) = .empty,
    mcp_oauth_interest: McpOAuthInterest = .none,

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
        const commands = allocator.alloc(RuntimeCommand, config.commands.len) catch |err| {
            allocator.free(tools);
            return err;
        };
        const canvases = allocator.alloc(OwnedCanvas, features.canvases.len) catch |err| {
            allocator.free(commands);
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
            .commands = commands,
            .permission_handler = config.on_permission_request,
            .permission_context = config.permission_context,
            .managed_settings_enabled = managedSettingsEnabled(config),
            .user_input_handler = config.on_user_input_request,
            .user_input_context = config.user_input_context,
            .elicitation_handler = config.on_elicitation_request,
            .elicitation_context = config.elicitation_context,
            .exit_plan_mode_handler = config.on_exit_plan_mode_request,
            .exit_plan_mode_context = config.exit_plan_mode_context,
            .auto_mode_switch_handler = config.on_auto_mode_switch_request,
            .auto_mode_switch_context = config.auto_mode_switch_context,
            .git_hub_token_provider = config.git_hub_token_provider,
        };
        var initialized_tools: usize = 0;
        var initialized_commands: usize = 0;
        var initialized_canvases: usize = 0;
        errdefer {
            for (result.canvases[0..initialized_canvases]) |*canvas| canvas.deinit(allocator);
            allocator.free(result.canvases);
            for (result.tools[0..initialized_tools]) |tool| allocator.free(tool.name);
            allocator.free(result.tools);
            for (result.commands[0..initialized_commands]) |command| allocator.free(command.name);
            allocator.free(result.commands);
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
        for (config.commands, 0..) |command, index| {
            result.commands[index] = .{
                .name = try allocator.dupe(u8, command.name),
                .handler = command.handler,
                .context = command.context,
            };
            initialized_commands += 1;
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
        for (self.commands) |command| allocator.free(command.name);
        allocator.free(self.commands);
        if (self.provider_tokens) |provider_tokens| {
            for (provider_tokens) |registered| registered.deinit(allocator);
            allocator.free(provider_tokens);
        }
        if (self.git_hub_token_registration_id) |registration_id| allocator.free(registration_id);
        for (self.open_canvases.items) |canvas| ext.freeOpenCanvas(allocator, canvas);
        self.open_canvases.deinit(allocator);
        for (self.granted_environment_variables.items) |grant| {
            allocator.free(grant.name);
            wipeSecret(grant.value);
            allocator.free(grant.value);
        }
        self.granted_environment_variables.deinit(allocator);
        switch (self.mcp_oauth_interest) {
            .registered, .releasing => |*interest| interest.deinitSecure(),
            .none, .registering, .restore_required => {},
        }
    }

    fn quarantineCredentials(self: *SessionExtensionRuntime, allocator: std.mem.Allocator) void {
        if (self.provider_tokens) |provider_tokens| {
            for (provider_tokens) |registered| registered.deinit(allocator);
            allocator.free(provider_tokens);
            self.provider_tokens = null;
        }
        if (self.git_hub_token_registration_id) |registration_id| {
            allocator.free(registration_id);
            self.git_hub_token_registration_id = null;
        }
        self.git_hub_token_provider = null;
        self.mcp_auth_handler = null;
        self.mcp_auth_context = null;
        self.credentials_quarantined = true;
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
    next_queued_event_id: u64 = 1,
    tools: std.ArrayList(RegisteredTool) = .empty,
    user_input_handlers: std.ArrayList(RegisteredUserInputHandler) = .empty,
    permission_handlers: std.ArrayList(RegisteredPermissionHandler) = .empty,
    extension_runtimes: std.ArrayList(SessionExtensionRuntime) = .empty,
    pending_extension_runtime: ?SessionExtensionRuntime = null,
    provider_tokens: std.ArrayList(RegisteredProviderTokens) = .empty,
    pending_provider_tokens: ?RegisteredProviderTokens = null,
    rpc_handlers: std.ArrayList(RegisteredRpcHandler) = .empty,
    dispatching_rpc_handler: bool = false,
    active_request_ids: [8]u64 = undefined,
    active_request_count: usize = 0,
    buffered_responses: std.ArrayList(BufferedResponse) = .empty,

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
        var remaining_runtimes = self.extension_runtimes.items.len;
        while (remaining_runtimes > 0) {
            remaining_runtimes -= 1;
            if (remaining_runtimes >= self.extension_runtimes.items.len) continue;
            self.releaseMcpOAuthInterest(
                &self.extension_runtimes.items[remaining_runtimes],
            ) catch {};
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
        if (self.pending_provider_tokens) |registered| {
            registered.deinit(self.allocator);
        }
        for (self.provider_tokens.items) |registered| registered.deinit(self.allocator);
        self.provider_tokens.deinit(self.allocator);
        for (self.rpc_handlers.items) |handler| handler.deinit(self.allocator);
        self.rpc_handlers.deinit(self.allocator);
        for (self.buffered_responses.items) |*response| response.deinit(self.allocator);
        self.buffered_responses.deinit(self.allocator);
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
        try validateLifecycleConfig(config);
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

        const server_assigned = config.cloud != null and config.session_id == null;
        const owned_session_id = if (config.session_id) |requested|
            try self.allocator.dupe(u8, requested)
        else if (server_assigned)
            null
        else
            try generateSessionId(self.allocator, self.io);
        if (owned_session_id) |session_id| {
            if (self.hasSession(session_id)) {
                self.allocator.free(session_id);
                return error.SessionAlreadyActive;
            }
            self.session_ids.append(self.allocator, session_id) catch |err| {
                self.allocator.free(session_id);
                return err;
            };
        }
        errdefer if (owned_session_id) |session_id| self.removeSession(session_id);

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
        try extension_values.lowerHostInjection(
            config.feature_flags,
            config.exp_assignments,
        );
        try self.beginExtensionRuntime(owned_session_id, config, &.{});
        errdefer self.rollbackExtensionRuntime();
        try self.installRuntimeProviderTokens(prepared_providers.token_bindings);
        try self.installGitHubTokenProvider(&extension_values);

        const request = try buildPreparedCreateSessionRequest(
            owned_session_id,
            config,
            tools.items,
            &extension_values,
            prepared_providers,
        );
        var detach_on_error: ?[]const u8 = owned_session_id;
        var lifecycle_rpc_dispatched = false;
        errdefer {
            self.quarantinePendingCredentials();
            if (lifecycle_rpc_dispatched) {
                if (detach_on_error) |session_id| self.detachSessionBestEffort(session_id);
            }
        }
        lifecycle_rpc_dispatched = true;
        var rpc_rejected = false;
        const parsed = self.callTrackingRpcRejection(
            WireSessionLifecycleResponse,
            "session.create",
            request,
            &rpc_rejected,
        ) catch |err| {
            if (rpc_rejected) lifecycle_rpc_dispatched = false;
            return err;
        };
        defer {
            wipeLifecycleResponseSecrets(parsed.value);
            parsed.deinit();
        }
        var response_detach_on_error: ?[]const u8 = null;
        errdefer {
            self.quarantinePendingCredentials();
            if (response_detach_on_error) |session_id|
                self.detachSessionBestEffort(session_id);
        }
        const returned_id = parsed.value.sessionId orelse return error.MissingSessionId;
        if (owned_session_id) |session_id| if (!std.mem.eql(u8, session_id, returned_id)) {
            if (!self.hasSession(returned_id)) {
                detach_on_error = null;
                response_detach_on_error = returned_id;
            }
            return error.SessionIdMismatch;
        };

        var adopted_session_id: ?[]u8 = null;
        if (server_assigned) {
            if (returned_id.len == 0 or self.hasSession(returned_id))
                return error.InvalidServerAssignedSessionId;
            response_detach_on_error = returned_id;
            const copy = try self.allocator.dupe(u8, returned_id);
            self.session_ids.append(self.allocator, copy) catch |err| {
                self.allocator.free(copy);
                return err;
            };
            adopted_session_id = copy;
            detach_on_error = null;
            try self.bindPendingRuntimeSessionId(copy);
        }
        errdefer if (adopted_session_id) |session_id| self.removeSession(session_id);
        try self.applyExtensionRuntimeResponse(parsed.value, &.{});
        try self.updateStableSessionOptions(returned_id, config);
        try self.finishExtensionRuntimeCommit(returned_id);
        return .{
            .client = self,
            .id = adopted_session_id orelse owned_session_id.?,
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
        try validateLifecycleConfig(config);
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
        try extension_values.lowerHostInjection(
            config.feature_flags,
            config.exp_assignments,
        );

        try self.beginExtensionRuntime(
            runtime_session_id,
            config,
            config.extensions.open_canvases orelse &.{},
        );
        errdefer self.rollbackExtensionRuntime();
        try self.installRuntimeProviderTokens(prepared_providers.token_bindings);
        try self.installGitHubTokenProvider(&extension_values);

        const request = try buildPreparedResumeSessionRequest(
            runtime_session_id,
            config,
            tools.items,
            &extension_values,
            requested_environment_variables,
            prepared_providers,
        );
        var detach_on_error: ?[]const u8 =
            if (existing_session_id == null) runtime_session_id else null;
        var quarantine_on_error = true;
        var lifecycle_rpc_dispatched = false;
        errdefer {
            if (quarantine_on_error)
                self.quarantineSessionCredentials(runtime_session_id);
            if (lifecycle_rpc_dispatched) {
                if (detach_on_error) |detached_session_id|
                    self.detachSessionBestEffort(detached_session_id);
            }
        }
        lifecycle_rpc_dispatched = true;
        var rpc_rejected = false;
        const parsed = self.callTrackingRpcRejection(
            WireSessionLifecycleResponse,
            "session.resume",
            request,
            &rpc_rejected,
        ) catch |err| {
            if (rpc_rejected) lifecycle_rpc_dispatched = false;
            return err;
        };
        defer {
            wipeLifecycleResponseSecrets(parsed.value);
            parsed.deinit();
        }
        var response_detach_on_error: ?[]const u8 = null;
        errdefer {
            if (quarantine_on_error)
                self.quarantineSessionCredentials(runtime_session_id);
            if (response_detach_on_error) |detached_session_id|
                self.detachSessionBestEffort(detached_session_id);
        }
        const returned_id = parsed.value.sessionId orelse return error.MissingSessionId;
        if (!std.mem.eql(u8, runtime_session_id, returned_id)) {
            if (!self.hasSession(returned_id)) {
                detach_on_error = null;
                response_detach_on_error = returned_id;
            }
            return error.SessionIdMismatch;
        }

        try self.applyExtensionRuntimeResponse(parsed.value, requested_environment_variables);
        try self.updateStableSessionOptions(returned_id, config);
        self.finishExtensionRuntimeCommit(runtime_session_id) catch |err| {
            if (err == error.EventInterestNotReleased)
                quarantine_on_error = false;
            return err;
        };
        return .{ .client = self, .id = runtime_session_id };
    }

    fn installRuntimeProviderTokens(
        self: *Client,
        bindings: []const provider.TokenBinding,
    ) !void {
        const runtime = if (self.pending_extension_runtime) |*value|
            value
        else
            return error.MissingExtensionRuntime;
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
        runtime.provider_tokens = registered;
    }

    fn installGitHubTokenProvider(
        self: *Client,
        values: *ExtensionWireValues,
    ) !void {
        const runtime = if (self.pending_extension_runtime) |*value|
            value
        else
            return error.MissingExtensionRuntime;
        if (runtime.git_hub_token_provider == null) return;
        const registration_id = try generateSessionId(self.allocator, self.io);
        runtime.git_hub_token_registration_id = registration_id;
        values.git_hub_token_registration_id = registration_id;
    }

    fn updateStableSessionOptions(
        self: *Client,
        session_id: []const u8,
        config: anytype,
    ) !void {
        if (config.coauthor_enabled == null and config.manage_schedule_enabled == null)
            return;
        const parsed = try self.call(RpcSuccess, "session.options.update", .{
            .sessionId = session_id,
            .coauthorEnabled = config.coauthor_enabled,
            .manageScheduleEnabled = config.manage_schedule_enabled,
        });
        defer parsed.deinit();
        if (!parsed.value.success) return error.SessionOptionsNotAccepted;
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
        self.quarantinePendingCredentials();
        if (self.pending_extension_runtime) |*runtime| {
            std.debug.assert(runtime.mcp_oauth_interest == .none);
            runtime.deinit(self.allocator);
        }
        self.pending_extension_runtime = null;
    }

    fn quarantinePendingCredentials(self: *Client) void {
        if (self.pending_extension_runtime) |*runtime| {
            runtime.quarantineCredentials(self.allocator);
        }
        if (self.pending_provider_tokens) |pending| {
            self.pending_provider_tokens = null;
            pending.deinit(self.allocator);
        }
    }

    fn quarantineSessionCredentials(self: *Client, session_id: []const u8) void {
        for (self.extension_runtimes.items) |*runtime| {
            if (runtime.session_id != null and
                std.mem.eql(u8, runtime.session_id.?, session_id))
            {
                runtime.quarantineCredentials(self.allocator);
                break;
            }
        }
        var index: usize = 0;
        while (index < self.provider_tokens.items.len) {
            if (std.mem.eql(u8, self.provider_tokens.items[index].session_id, session_id)) {
                const registered = self.provider_tokens.orderedRemove(index);
                registered.deinit(self.allocator);
            } else {
                index += 1;
            }
        }
        self.quarantinePendingCredentials();
    }

    fn bindPendingRuntimeSessionId(self: *Client, session_id: []const u8) !void {
        const runtime = if (self.pending_extension_runtime) |*value|
            value
        else
            return error.MissingExtensionRuntime;
        if (runtime.session_id) |registered_id| {
            if (!std.mem.eql(u8, registered_id, session_id))
                return error.UnexpectedSessionId;
            return;
        }
        runtime.session_id = try self.allocator.dupe(u8, session_id);
    }

    fn commitExtensionRuntime(
        self: *Client,
        session_id: []const u8,
        response: WireSessionLifecycleResponse,
        requested_environment_variables: []const []const u8,
    ) !void {
        try self.bindPendingRuntimeSessionId(session_id);
        try self.applyExtensionRuntimeResponse(response, requested_environment_variables);
        try self.finishExtensionRuntimeCommit(session_id);
    }

    fn applyExtensionRuntimeResponse(
        self: *Client,
        response: WireSessionLifecycleResponse,
        requested_environment_variables: []const []const u8,
    ) !void {
        const runtime = if (self.pending_extension_runtime) |*value| value else return error.MissingExtensionRuntime;
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
    }

    fn finishExtensionRuntimeCommit(
        self: *Client,
        session_id: []const u8,
    ) !void {
        const runtime = if (self.pending_extension_runtime) |*value| value else return error.MissingExtensionRuntime;
        const runtime_session_id = runtime.session_id orelse return error.MissingSessionId;
        if (!std.mem.eql(u8, runtime_session_id, session_id))
            return error.UnexpectedSessionId;
        for (self.extension_runtimes.items) |*existing| {
            if (existing.session_id != null and
                std.mem.eql(u8, existing.session_id.?, session_id))
            {
                if (runtime.mcp_auth_handler != null and
                    existing.mcp_oauth_interest == .none)
                {
                    try self.registerMcpOAuthInterest(runtime);
                }
                try self.commitPreparedExtensionRuntime(session_id);
                return;
            }
        }
        try self.extension_runtimes.ensureUnusedCapacity(self.allocator, 1);
        if (runtime.mcp_auth_handler != null) {
            try self.registerMcpOAuthInterest(runtime);
        }
        try self.commitPreparedExtensionRuntime(session_id);
    }

    fn commitPreparedExtensionRuntime(self: *Client, session_id: []const u8) !void {
        const runtime = &self.pending_extension_runtime.?;
        for (self.extension_runtimes.items, 0..) |*existing, index| {
            if (existing.session_id != null and
                std.mem.eql(u8, existing.session_id.?, session_id))
            {
                if (runtime.mcp_auth_handler == null) {
                    self.releaseMcpOAuthInterest(existing) catch
                        return error.EventInterestNotReleased;
                } else if (runtime.mcp_oauth_interest == .none) {
                    switch (existing.mcp_oauth_interest) {
                        .registered => |interest| {
                            runtime.mcp_oauth_interest = .{ .registered = interest };
                            existing.mcp_oauth_interest = .none;
                        },
                        .restore_required => return error.EventInterestRestoreRequired,
                        .registering, .releasing => return error.EventInterestOperationInProgress,
                        .none => {},
                    }
                }
                runtime.event_queue_failure = existing.event_queue_failure;
                const replacement = self.pending_extension_runtime.?;
                self.pending_extension_runtime = null;
                existing.deinit(self.allocator);
                self.extension_runtimes.items[index] = replacement;
                return;
            }
        }
        const committed = self.pending_extension_runtime.?;
        self.pending_extension_runtime = null;
        self.extension_runtimes.appendAssumeCapacity(committed);
    }

    fn registerMcpOAuthInterest(
        self: *Client,
        runtime: *SessionExtensionRuntime,
    ) !void {
        if (runtime.mcp_oauth_interest == .registered) return;
        const prior_state: @TypeOf(@as(McpOAuthInterest, undefined).registering) =
            switch (runtime.mcp_oauth_interest) {
                .none => .initial,
                .restore_required => .restore,
                .registering, .releasing => return error.EventInterestOperationInProgress,
                .registered => unreachable,
            };
        const session_id = runtime.session_id orelse return error.MissingSessionId;
        const runtime_location = self.mcpOAuthRuntimeLocation(runtime);
        const owned_session_id = try self.allocator.dupe(u8, session_id);
        defer self.allocator.free(owned_session_id);
        runtime.mcp_oauth_interest = .{ .registering = prior_state };
        errdefer if (self.resolveMcpOAuthRuntime(owned_session_id, runtime_location)) |current| {
            if (current.mcp_oauth_interest == .registering) {
                current.mcp_oauth_interest = switch (prior_state) {
                    .initial => .none,
                    .restore => .restore_required,
                };
            }
        };
        const parsed = try self.call(WireMcpOAuthInterest, "session.eventLog.registerInterest", .{
            .sessionId = owned_session_id,
            .eventType = "mcp.oauth_required",
        });
        self.adoptMcpOAuthInterest(
            owned_session_id,
            runtime_location,
            parsed,
        );
    }

    fn adoptMcpOAuthInterest(
        self: *Client,
        session_id: []const u8,
        runtime_location: McpOAuthRuntimeLocation,
        parsed: std.json.Parsed(WireMcpOAuthInterest),
    ) void {
        const current = self.resolveMcpOAuthRuntime(
            session_id,
            runtime_location,
        ) orelse unreachable;
        std.debug.assert(current.mcp_oauth_interest == .registering);
        current.mcp_oauth_interest = .{ .registered = .{ .response = parsed } };
    }

    fn releaseMcpOAuthInterest(
        self: *Client,
        runtime: *SessionExtensionRuntime,
    ) !void {
        const interest = switch (runtime.mcp_oauth_interest) {
            .none => return,
            .restore_required => return error.EventInterestRestoreRequired,
            .registering, .releasing => return error.EventInterestOperationInProgress,
            .registered => |owned| owned,
        };
        const session_id = runtime.session_id orelse
            return error.MissingSessionId;
        const runtime_location = self.mcpOAuthRuntimeLocation(runtime);
        const owned_session_id = try self.allocator.dupe(u8, session_id);
        defer self.allocator.free(owned_session_id);
        runtime.mcp_oauth_interest = .{ .releasing = interest };
        errdefer if (self.resolveMcpOAuthRuntime(owned_session_id, runtime_location)) |current| {
            if (current.mcp_oauth_interest == .releasing) {
                const retained = current.mcp_oauth_interest.releasing;
                current.mcp_oauth_interest = .{ .registered = retained };
            }
        };
        try self.releaseMcpOAuthInterestOwner(
            owned_session_id,
            &interest,
        );
        const current = self.resolveMcpOAuthRuntime(
            owned_session_id,
            runtime_location,
        ) orelse unreachable;
        std.debug.assert(current.mcp_oauth_interest == .releasing);
        var released = current.mcp_oauth_interest.releasing;
        current.mcp_oauth_interest = .none;
        released.deinitSecure();
    }

    fn releaseMcpOAuthInterestOwner(
        self: *Client,
        session_id: []const u8,
        interest: *const OwnedMcpOAuthInterest,
    ) !void {
        const parsed = try self.call(struct {
            success: bool,
        }, "session.eventLog.releaseInterest", .{
            .sessionId = session_id,
            .handle = interest.handle(),
        });
        defer parsed.deinit();
        if (!parsed.value.success) return error.EventInterestNotReleased;
    }

    fn resolveMcpOAuthRuntime(
        self: *Client,
        session_id: []const u8,
        location: McpOAuthRuntimeLocation,
    ) ?*SessionExtensionRuntime {
        switch (location) {
            .pending => {
                const pending = if (self.pending_extension_runtime) |*runtime|
                    runtime
                else
                    return null;
                const pending_session_id = pending.session_id orelse return null;
                if (!std.mem.eql(u8, pending_session_id, session_id)) return null;
                return pending;
            },
            .committed => {
                for (self.extension_runtimes.items) |*runtime| {
                    const runtime_session_id = runtime.session_id orelse continue;
                    if (std.mem.eql(u8, runtime_session_id, session_id)) return runtime;
                }
                return null;
            },
            .external => |runtime| return runtime,
        }
    }

    fn mcpOAuthRuntimeLocation(
        self: *Client,
        runtime: *SessionExtensionRuntime,
    ) McpOAuthRuntimeLocation {
        if (self.pending_extension_runtime) |*pending| {
            if (pending == runtime) return .pending;
        }
        for (self.extension_runtimes.items) |*committed| {
            if (committed == runtime) return .committed;
        }
        return .{ .external = runtime };
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
        var ignored_rpc_rejection = false;
        return self.callTrackingRpcRejection(
            Result,
            method,
            params,
            &ignored_rpc_rejection,
        );
    }

    fn callTrackingRpcRejection(
        self: *Client,
        comptime Result: type,
        method: []const u8,
        params: anytype,
        rpc_rejected: *bool,
    ) !std.json.Parsed(Result) {
        rpc_rejected.* = false;
        if (self.dispatching_rpc_handler) return error.ReentrantRpcCall;
        if (self.active_request_count == self.active_request_ids.len)
            return error.RpcNestingLimitExceeded;
        const id = self.next_request_id;
        self.next_request_id += 1;
        self.active_request_ids[self.active_request_count] = id;
        self.active_request_count += 1;
        defer {
            self.active_request_count -= 1;
            std.debug.assert(self.active_request_ids[self.active_request_count] == id);
            if (self.takeBufferedResponse(id)) |body| {
                var response = BufferedResponse{ .id = id, .body = body };
                response.deinit(self.allocator);
            }
        }

        const request = try json_rpc.encodeRequest(self.allocator, id, method, params);
        defer {
            wipeSecret(request);
            self.allocator.free(request);
        }
        try writeFrameAndWipe(&self.writer.interface, self.writer_buffer, request);

        while (true) {
            const body = self.takeBufferedResponse(id) orelse
                try json_rpc.readFrame(self.allocator, &self.reader.interface);
            var owns_body = true;
            defer {
                if (owns_body) {
                    wipeSecret(body);
                    self.allocator.free(body);
                }
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
                    try self.queueSessionEvent(
                        object.get("params") orelse return error.InvalidJsonRpc,
                    );
                }
                continue;
            }

            const response_id = object.get("id") orelse return error.InvalidJsonRpc;
            const response_number = switch (response_id) {
                .integer => |number| std.math.cast(u64, number) orelse return error.InvalidJsonRpc,
                else => return error.InvalidJsonRpc,
            };
            if (response_number != id) {
                if (!self.isActiveRequest(response_number) or
                    self.hasBufferedResponse(response_number))
                {
                    return error.UnexpectedResponse;
                }
                try self.buffered_responses.append(self.allocator, .{
                    .id = response_number,
                    .body = body,
                });
                owns_body = false;
                continue;
            }
            if (object.get("error")) |rpc_error| {
                if (rpc_error != .null) {
                    rpc_rejected.* = true;
                    return error.JsonRpcError;
                }
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

    fn isActiveRequest(self: *const Client, id: u64) bool {
        for (self.active_request_ids[0..self.active_request_count]) |active_id| {
            if (active_id == id) return true;
        }
        return false;
    }

    fn hasBufferedResponse(self: *const Client, id: u64) bool {
        for (self.buffered_responses.items) |response| {
            if (response.id == id) return true;
        }
        return false;
    }

    fn takeBufferedResponse(self: *Client, id: u64) ?[]u8 {
        for (self.buffered_responses.items, 0..) |response, index| {
            if (response.id == id) return self.buffered_responses.orderedRemove(index).body;
        }
        return null;
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
        if (std.mem.eql(u8, method, "providerToken.getToken")) {
            return self.dispatchProviderTokenRequest(writer, id, params);
        }
        if (std.mem.eql(u8, method, "gitHubToken.getToken")) {
            return self.dispatchGitHubTokenRequest(writer, id, params);
        }
        if (std.mem.eql(u8, method, "userInput.request")) {
            return self.dispatchUserInputRequest(writer, id, params);
        }
        if (std.mem.eql(u8, method, "exitPlanMode.request")) {
            return self.dispatchExitPlanModeRequest(writer, id, params);
        }
        if (std.mem.eql(u8, method, "autoModeSwitch.request")) {
            return self.dispatchAutoModeSwitchRequest(writer, id, params);
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
        defer {
            wipeSecret(result_json);
            self.allocator.free(result_json);
        }
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, result_json, .{});
        defer {
            wipeJsonStrings(parsed.value);
            parsed.deinit();
        }
        const response = try json_rpc.encodeSuccessResponse(self.allocator, id, parsed.value);
        defer {
            wipeSecret(response);
            self.allocator.free(response);
        }
        try self.writeServerFrame(writer, response);
    }

    fn writeNullSuccess(
        self: *Client,
        writer: *std.Io.Writer,
        id: std.json.Value,
    ) !void {
        const result: std.json.Value = .null;
        const response = try json_rpc.encodeSuccessResponse(self.allocator, id, result);
        defer self.allocator.free(response);
        try self.writeServerFrame(writer, response);
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
        if (!std.mem.eql(u8, session_id, base.runtime_session_id))
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
                std.meta.stringToEnum(
                    @TypeOf(@as(ext.SessionEndInput, undefined).reason),
                    reason_string,
                ) orelse
                return self.writeServerRequestError(writer, id, -32602, "invalid hook input");
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
                std.meta.stringToEnum(
                    @TypeOf(@as(ext.ErrorOccurredInput, undefined).context),
                    context_string,
                ) orelse
                return self.writeServerRequestError(writer, id, -32602, "invalid hook input");
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
        defer wipeAndFreeSecret(self.allocator, token);

        const response = try json_rpc.encodeSuccessResponse(self.allocator, id, .{ .token = token });
        defer wipeAndFreeSecret(self.allocator, response);
        try self.writeServerFrame(writer, response);
    }

    fn writeServerFrame(
        self: *Client,
        writer: *std.Io.Writer,
        response: []const u8,
    ) !void {
        if (self.writer_buffer.len != 0 and writer == &self.writer.interface) {
            return writeFrameAndWipe(writer, self.writer_buffer, response);
        }
        return json_rpc.writeFrame(writer, response);
    }

    fn findGitHubTokenRuntime(
        self: *Client,
        registration_id: []const u8,
    ) ?*SessionExtensionRuntime {
        if (self.pending_extension_runtime) |*runtime| {
            if (runtime.git_hub_token_registration_id) |candidate| {
                if (std.mem.eql(u8, candidate, registration_id)) return runtime;
            }
        }
        for (self.extension_runtimes.items) |*runtime| {
            if (runtime.git_hub_token_registration_id) |candidate| {
                if (std.mem.eql(u8, candidate, registration_id)) return runtime;
            }
        }
        return null;
    }

    fn dispatchGitHubTokenRequest(
        self: *Client,
        writer: *std.Io.Writer,
        id: std.json.Value,
        params: ?std.json.Value,
    ) !void {
        const value = params orelse
            return self.writeServerRequestError(writer, id, -32602, "invalid GitHub token request");
        const parsed = std.json.parseFromValue(
            WireGitHubTokenRequest,
            self.allocator,
            value,
            .{ .ignore_unknown_fields = false },
        ) catch
            return self.writeServerRequestError(writer, id, -32602, "invalid GitHub token request");
        defer parsed.deinit();
        if (value.object.get("sessionId")) |session_id| {
            if (session_id != .string)
                return self.writeServerRequestError(writer, id, -32602, "invalid GitHub token request");
        }

        const runtime = self.findGitHubTokenRuntime(parsed.value.registrationId) orelse
            return self.writeServerRequestError(writer, id, -32602, "unknown GitHub token registration");
        if (runtime.session_id) |registered_session_id| {
            const requested_session_id = parsed.value.sessionId orelse
                return self.writeServerRequestError(writer, id, -32602, "GitHub token registration mismatch");
            if (!std.mem.eql(u8, registered_session_id, requested_session_id))
                return self.writeServerRequestError(writer, id, -32602, "GitHub token registration mismatch");
        } else if (parsed.value.sessionId != null) {
            return self.writeServerRequestError(writer, id, -32602, "GitHub token registration mismatch");
        }
        const provider_config = runtime.git_hub_token_provider orelse
            return self.writeServerRequestError(writer, id, -32602, "unknown GitHub token registration");

        self.dispatching_rpc_handler = true;
        defer self.dispatching_rpc_handler = false;
        var result = provider_config.callback(self.allocator, .{
            .host = parsed.value.host,
            .session_id = parsed.value.sessionId orelse runtime.session_id,
            .reason = parsed.value.reason,
        }, provider_config.context) catch |err|
            return self.writeServerRequestError(writer, id, -32000, @errorName(err));
        defer switch (result) {
            .token => |*token| token.deinitSecure(self.allocator),
            .cancelled => {},
        };

        switch (result) {
            .cancelled => return self.writeTypedSuccess(writer, id, .{ .kind = "cancelled" }),
            .token => |token| {
                if (token.expires_in_seconds < 3601)
                    return self.writeServerRequestError(writer, id, -32603, "invalid GitHub token result");
                return self.writeTypedSuccess(writer, id, .{
                    .kind = "token",
                    .accessToken = token.access_token,
                    .tokenType = token.token_type,
                    .expiresIn = token.expires_in_seconds,
                });
            },
        }
    }

    fn dispatchExitPlanModeRequest(
        self: *Client,
        writer: *std.Io.Writer,
        id: std.json.Value,
        params: ?std.json.Value,
    ) !void {
        const value = params orelse
            return self.writeServerRequestError(writer, id, -32602, "invalid exit plan mode request");
        const parsed = std.json.parseFromValue(
            WireExitPlanModeRequest,
            self.allocator,
            value,
            .{},
        ) catch return self.writeServerRequestError(
            writer,
            id,
            -32602,
            "invalid exit plan mode request",
        );
        defer parsed.deinit();
        const runtime = self.findExtensionRuntime(parsed.value.sessionId) orelse
            return self.writeServerRequestError(writer, id, -32602, "unknown exit plan mode session");
        const handler = runtime.exit_plan_mode_handler orelse
            return self.writeTypedSuccess(writer, id, .{ .approved = true });
        self.dispatching_rpc_handler = true;
        defer self.dispatching_rpc_handler = false;
        const result = handler(.{
            .session_id = parsed.value.sessionId,
            .summary = parsed.value.summary,
            .plan_content = parsed.value.planContent,
            .actions = parsed.value.actions,
            .recommended_action = parsed.value.recommendedAction,
        }, runtime.exit_plan_mode_context) catch |err|
            return self.writeServerRequestError(writer, id, -32000, @errorName(err));
        if (result.selected_action) |selected| {
            var found = false;
            for (parsed.value.actions) |action| {
                if (action == selected) {
                    found = true;
                    break;
                }
            }
            if (!found)
                return self.writeServerRequestError(writer, id, -32603, "invalid exit plan mode result");
        }
        return self.writeTypedSuccess(writer, id, .{
            .approved = result.approved,
            .selectedAction = result.selected_action,
            .feedback = result.feedback,
        });
    }

    fn dispatchAutoModeSwitchRequest(
        self: *Client,
        writer: *std.Io.Writer,
        id: std.json.Value,
        params: ?std.json.Value,
    ) !void {
        const value = params orelse
            return self.writeServerRequestError(writer, id, -32602, "invalid auto mode switch request");
        const parsed = std.json.parseFromValue(
            WireAutoModeSwitchRequest,
            self.allocator,
            value,
            .{},
        ) catch return self.writeServerRequestError(
            writer,
            id,
            -32602,
            "invalid auto mode switch request",
        );
        defer parsed.deinit();
        const runtime = self.findExtensionRuntime(parsed.value.sessionId) orelse
            return self.writeServerRequestError(writer, id, -32602, "unknown auto mode switch session");
        const handler = runtime.auto_mode_switch_handler orelse
            return self.writeTypedSuccess(writer, id, .{ .response = session_types.AutoModeSwitchResponse.no });

        self.dispatching_rpc_handler = true;
        defer self.dispatching_rpc_handler = false;
        const response = handler(.{
            .session_id = parsed.value.sessionId,
            .error_code = parsed.value.errorCode,
            .retry_after_seconds = parsed.value.retryAfterSeconds,
        }, runtime.auto_mode_switch_context) catch |err|
            return self.writeServerRequestError(writer, id, -32000, @errorName(err));
        return self.writeTypedSuccess(writer, id, .{ .response = response });
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
        const params = switch (params_value) {
            .object => |object| object,
            else => return error.InvalidSessionEvent,
        };
        const session_id_value = params.get("sessionId") orelse return error.InvalidSessionEvent;
        const session_id = switch (session_id_value) {
            .string => |id| id,
            else => return error.InvalidSessionEvent,
        };
        if (self.findExtensionRuntime(session_id) == null) return;
        const event_value = params.get("event") orelse return error.InvalidSessionEvent;
        const owned_session_id = try self.allocator.dupe(u8, session_id);
        var session_id_owned = true;
        errdefer if (session_id_owned) self.allocator.free(owned_session_id);
        const event = try session_types.parseEvent(
            self.allocator,
            event_value,
        );
        session_id_owned = false;
        var queued = QueuedEvent{
            .id = self.next_queued_event_id,
            .session_id = owned_session_id,
            .event = event,
        };
        self.next_queued_event_id +%= 1;
        if (self.next_queued_event_id == 0) self.next_queued_event_id = 1;
        var queued_owned = true;
        defer if (queued_owned) queued.deinit(self.allocator);
        try self.applyExtensionEvent(session_id, &queued.event);
        const delivery_class: EventDeliveryClass = switch (queued.event) {
            .command_execute, .elicitation_requested => .automatic,
            .mcp_oauth_required => if (self.findExtensionRuntime(session_id)) |runtime|
                if (!runtime.credentials_quarantined and runtime.mcp_auth_handler != null)
                    .automatic
                else
                    .observation
            else
                .observation,
            .permission_requested => .permission_request,
            .external_tool_requested => .external_tool_request,
            else => .observation,
        };
        const failed = self.sessionEventQueueFailure(session_id) != null;
        if (failed or self.queuedEventCount(session_id) >= max_queued_events) {
            self.handleUnretainedEvent(
                session_id,
                &queued.event,
                delivery_class,
                .capacity_exceeded,
            );
            return;
        }
        queued.automatic_handling_in_progress = delivery_class == .automatic;
        self.events.append(self.allocator, queued) catch {
            self.handleUnretainedEvent(
                session_id,
                &queued.event,
                delivery_class,
                .allocation_failed,
            );
            return;
        };
        queued_owned = false;
        if (delivery_class == .automatic) {
            const event_id = queued.id;
            const target = AutomaticEventTarget{ .queued = event_id };
            defer self.finishAutomaticEvent(target);
            self.handleAutomaticSessionEvent(session_id, target);
        }
    }

    fn queuedEventCount(self: *const Client, session_id: []const u8) usize {
        var count: usize = 0;
        for (self.events.items) |queued| {
            if (std.mem.eql(u8, queued.session_id, session_id)) count += 1;
        }
        return count;
    }

    fn sessionEventQueueFailure(
        self: *Client,
        session_id: []const u8,
    ) ?EventQueueFailure {
        var failure: ?EventQueueFailure = null;
        if (self.pending_extension_runtime) |*runtime| {
            if (runtime.session_id) |runtime_session_id| {
                if (std.mem.eql(u8, runtime_session_id, session_id)) {
                    failure = runtime.event_queue_failure;
                }
            }
        }
        for (self.extension_runtimes.items) |*runtime| {
            const runtime_session_id = runtime.session_id orelse continue;
            if (!std.mem.eql(u8, runtime_session_id, session_id)) continue;
            if (runtime.event_queue_failure == .rejection_failed)
                return .rejection_failed;
            if (failure == null) failure = runtime.event_queue_failure;
        }
        return failure;
    }

    fn recordEventQueueFailure(
        self: *Client,
        session_id: []const u8,
        failure: EventQueueFailure,
    ) void {
        if (self.pending_extension_runtime) |*runtime| {
            if (runtime.session_id) |runtime_session_id| {
                if (std.mem.eql(u8, runtime_session_id, session_id) and
                    (runtime.event_queue_failure == null or failure == .rejection_failed))
                {
                    runtime.event_queue_failure = failure;
                }
            }
        }
        for (self.extension_runtimes.items) |*runtime| {
            const runtime_session_id = runtime.session_id orelse continue;
            if (std.mem.eql(u8, runtime_session_id, session_id) and
                (runtime.event_queue_failure == null or failure == .rejection_failed))
            {
                runtime.event_queue_failure = failure;
            }
        }
    }

    fn handleUnretainedEvent(
        self: *Client,
        session_id: []const u8,
        event: *session_types.SessionEvent,
        delivery_class: EventDeliveryClass,
        failure: EventQueueFailure,
    ) void {
        self.recordEventQueueFailure(session_id, failure);
        switch (delivery_class) {
            .observation => {},
            .automatic => self.handleAutomaticSessionEvent(
                session_id,
                .{ .transient = event },
            ),
            .permission_request => {
                const request_id = event.permission_requested.request_id;
                (Session{ .client = self, .id = session_id }).rejectPermission(
                    request_id,
                    event_queue_capacity_message,
                ) catch self.recordEventQueueFailure(
                    session_id,
                    .rejection_failed,
                );
            },
            .external_tool_request => {
                const request_id = event.external_tool_requested.request_id;
                (Session{ .client = self, .id = session_id }).respondToToolError(
                    request_id,
                    event_queue_capacity_message,
                ) catch self.recordEventQueueFailure(
                    session_id,
                    .rejection_failed,
                );
            },
        }
    }

    fn handleAutomaticSessionEvent(
        self: *Client,
        session_id: []const u8,
        target: AutomaticEventTarget,
    ) void {
        const event = self.automaticEvent(target) orelse return;
        switch (event.*) {
            .command_execute => self.handleCommandEvent(
                session_id,
                target,
            ),
            .elicitation_requested => self.handleElicitationEvent(
                session_id,
                target,
            ),
            .mcp_oauth_required => self.handleMcpAuthEvent(
                session_id,
                target,
            ),
            else => {},
        }
    }

    fn automaticEvent(
        self: *Client,
        target: AutomaticEventTarget,
    ) ?*session_types.SessionEvent {
        return switch (target) {
            .queued => |id| blk: {
                const queued = self.queuedEvent(id) orelse break :blk null;
                break :blk &queued.event;
            },
            .transient => |event| event,
        };
    }

    fn queuedEvent(self: *Client, id: u64) ?*QueuedEvent {
        for (self.events.items) |*queued| {
            if (queued.id == id) return queued;
        }
        return null;
    }

    fn finishAutomaticEvent(self: *Client, target: AutomaticEventTarget) void {
        const id = switch (target) {
            .queued => |id| id,
            .transient => return,
        };
        for (self.events.items, 0..) |*queued, index| {
            if (queued.id != id) continue;
            if (queued.remove_after_automatic_handling) {
                var removed = self.events.orderedRemove(index);
                removed.deinit(self.allocator);
            } else {
                queued.automatic_handling_in_progress = false;
            }
            return;
        }
    }

    fn setCommandAutomaticHandling(
        self: *Client,
        target: AutomaticEventTarget,
        handling: session_types.AutomaticInteractionHandling,
    ) void {
        const event = self.automaticEvent(target) orelse return;
        event.command_execute.automatic_handling = handling;
    }

    fn setElicitationAutomaticHandling(
        self: *Client,
        target: AutomaticEventTarget,
        handling: session_types.AutomaticInteractionHandling,
    ) void {
        const event = self.automaticEvent(target) orelse return;
        event.elicitation_requested.automatic_handling = handling;
    }

    fn setMcpAuthAutomaticHandling(
        self: *Client,
        target: AutomaticEventTarget,
        handling: session_types.AutomaticInteractionHandling,
    ) void {
        const event = self.automaticEvent(target) orelse return;
        event.mcp_oauth_required.automatic_handling = handling;
    }

    fn handleCommandEvent(
        self: *Client,
        session_id: []const u8,
        target: AutomaticEventTarget,
    ) void {
        const runtime = self.findExtensionRuntime(session_id) orelse return;
        const request = (self.automaticEvent(target) orelse return).command_execute;
        var matched = false;
        for (runtime.commands) |command| {
            if (!std.mem.eql(u8, command.name, request.command_name)) continue;
            matched = true;
            command.handler(.{
                .session_id = session_id,
                .command = request.command,
                .command_name = request.command_name,
                .args = request.args,
            }, command.context) catch |handler_error| {
                self.completeCommand(
                    session_id,
                    request.request_id,
                    @errorName(handler_error),
                ) catch |delivery_error| {
                    self.setCommandAutomaticHandling(
                        target,
                        .{ .delivery_failed = delivery_error },
                    );
                    return;
                };
                self.setCommandAutomaticHandling(
                    target,
                    .{ .handler_failed = handler_error },
                );
                return;
            };
            self.completeCommand(session_id, request.request_id, null) catch |err| {
                self.setCommandAutomaticHandling(target, .{ .delivery_failed = err });
                return;
            };
            self.setCommandAutomaticHandling(target, .handled);
            return;
        }
        if (!matched) {
            const message = std.fmt.allocPrint(
                self.allocator,
                "Unknown command: {s}",
                .{request.command_name},
            ) catch |err| {
                self.setCommandAutomaticHandling(target, .{ .delivery_failed = err });
                return;
            };
            defer self.allocator.free(message);
            self.completeCommand(session_id, request.request_id, message) catch |err| {
                self.setCommandAutomaticHandling(target, .{ .delivery_failed = err });
                return;
            };
            self.setCommandAutomaticHandling(target, .handled);
        }
    }

    fn completeCommand(
        self: *Client,
        session_id: []const u8,
        request_id: []const u8,
        command_error: ?[]const u8,
    ) !void {
        const parsed = if (command_error) |message|
            try self.call(
                RpcSuccess,
                "session.commands.handlePendingCommand",
                .{
                    .sessionId = session_id,
                    .requestId = request_id,
                    .@"error" = message,
                },
            )
        else
            try self.call(
                RpcSuccess,
                "session.commands.handlePendingCommand",
                .{
                    .sessionId = session_id,
                    .requestId = request_id,
                },
            );
        defer parsed.deinit();
        if (!parsed.value.success) return error.CommandResultNotAccepted;
    }

    fn handleElicitationEvent(
        self: *Client,
        session_id: []const u8,
        target: AutomaticEventTarget,
    ) void {
        const runtime = self.findExtensionRuntime(session_id) orelse return;
        const payload = (self.automaticEvent(target) orelse return).elicitation_requested;
        const handler = runtime.elicitation_handler orelse return;
        var requested_schema_json: ?[]u8 = null;
        defer if (requested_schema_json) |json| self.allocator.free(json);
        if (payload.requested_schema != null) {
            const parsed_data = std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                payload.raw.data_json,
                .{},
            ) catch |err| {
                self.setElicitationAutomaticHandling(target, .{ .delivery_failed = err });
                return;
            };
            defer parsed_data.deinit();
            const data_object = switch (parsed_data.value) {
                .object => |object| object,
                else => {
                    self.setElicitationAutomaticHandling(target, .invalid_result);
                    return;
                },
            };
            requested_schema_json = stringifyJsonValue(
                self.allocator,
                data_object.get("requestedSchema") orelse {
                    self.setElicitationAutomaticHandling(target, .invalid_result);
                    return;
                },
            ) catch |err| {
                self.setElicitationAutomaticHandling(target, .{ .delivery_failed = err });
                return;
            };
        }
        var result = handler(self.allocator, .{
            .session_id = session_id,
            .message = payload.message,
            .requested_schema_json = requested_schema_json,
            .mode = payload.mode,
            .elicitation_source = payload.elicitation_source,
            .url = payload.url,
        }, runtime.elicitation_context) catch |err| {
            self.setElicitationAutomaticHandling(target, .{ .handler_failed = err });
            return;
        };
        defer result.deinit(self.allocator);
        const content = if (result.content_json) |json|
            std.json.parseFromSlice(std.json.Value, self.allocator, json, .{}) catch {
                self.setElicitationAutomaticHandling(target, .invalid_result);
                return;
            }
        else
            null;
        defer if (content) |value| value.deinit();
        if (content) |value| {
            if (value.value != .object) {
                self.setElicitationAutomaticHandling(target, .invalid_result);
                return;
            }
        }
        self.completeElicitation(session_id, payload.request_id, .{ .result = .{
            .action = result.action,
            .content = if (content) |value| value.value else null,
        } }) catch |err| {
            self.setElicitationAutomaticHandling(target, .{ .delivery_failed = err });
            return;
        };
        self.setElicitationAutomaticHandling(target, .handled);
    }

    fn completeElicitation(
        self: *Client,
        session_id: []const u8,
        response_id: []const u8,
        result: ElicitationResponse,
    ) !void {
        const parsed = switch (result) {
            .cancelled => try self.call(
                RpcSuccess,
                "session.ui.handlePendingElicitation",
                .{
                    .sessionId = session_id,
                    .requestId = response_id,
                    .result = .{ .action = session_types.ElicitationAction.cancel },
                },
            ),
            .result => |value| try self.call(
                RpcSuccess,
                "session.ui.handlePendingElicitation",
                .{
                    .sessionId = session_id,
                    .requestId = response_id,
                    .result = value,
                },
            ),
        };
        defer parsed.deinit();
        if (!parsed.value.success) return error.ElicitationResultNotAccepted;
    }

    fn handleMcpAuthEvent(
        self: *Client,
        session_id: []const u8,
        target: AutomaticEventTarget,
    ) void {
        const runtime = self.findExtensionRuntime(session_id) orelse return;
        if (runtime.credentials_quarantined) return;
        const handler = runtime.mcp_auth_handler orelse return;
        const payload = (self.automaticEvent(target) orelse return).mcp_oauth_required;
        const parsed = std.json.parseFromSlice(
            WireMcpAuthRequest,
            self.allocator,
            payload.raw.data_json,
            .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
        ) catch {
            self.setMcpAuthAutomaticHandling(target, .invalid_result);
            return;
        };
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
            std.json.Stringify.valueAlloc(self.allocator, value, .{}) catch |err| {
                self.setMcpAuthAutomaticHandling(target, .{ .delivery_failed = err });
                return;
            }
        else
            null;
        defer if (www_json) |value| {
            wipeSecret(value);
            self.allocator.free(value);
        };
        const http_json = if (parsed.value.httpResponse) |value|
            std.json.Stringify.valueAlloc(self.allocator, value, .{}) catch |err| {
                self.setMcpAuthAutomaticHandling(target, .{ .delivery_failed = err });
                return;
            }
        else
            null;
        defer if (http_json) |value| {
            wipeSecret(value);
            self.allocator.free(value);
        };
        const static_json = if (parsed.value.staticClientConfig) |value|
            std.json.Stringify.valueAlloc(self.allocator, value, .{}) catch |err| {
                self.setMcpAuthAutomaticHandling(target, .{ .delivery_failed = err });
                return;
            }
        else
            null;
        defer if (static_json) |value| {
            wipeSecret(value);
            self.allocator.free(value);
        };
        var result = handler(self.allocator, .{
            .request_id = parsed.value.requestId,
            .server_name = parsed.value.serverName,
            .server_url = parsed.value.serverUrl,
            .reason = parsed.value.reason,
            .resource_metadata = parsed.value.resourceMetadata,
            .www_authenticate_json = www_json,
            .http_response_json = http_json,
            .static_client_config_json = static_json,
        }, runtime.mcp_auth_context) catch |err| {
            self.setMcpAuthAutomaticHandling(target, .{ .handler_failed = err });
            return;
        };
        defer switch (result) {
            .token => |*token| token.deinitSecure(self.allocator),
            .cancelled => {},
        };
        const response = switch (result) {
            .cancelled => self.call(
                RpcSuccess,
                "session.mcp.oauth.handlePendingRequest",
                .{
                    .sessionId = session_id,
                    .requestId = parsed.value.requestId,
                    .result = .{ .kind = "cancelled" },
                },
            ),
            .token => |token| blk: {
                if (token.expires_in_seconds) |expires_in_seconds| {
                    if (expires_in_seconds == 0) {
                        self.setMcpAuthAutomaticHandling(target, .invalid_result);
                        return;
                    }
                }
                break :blk self.call(
                    RpcSuccess,
                    "session.mcp.oauth.handlePendingRequest",
                    .{
                        .sessionId = session_id,
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
        const accepted = response catch |err| {
            self.setMcpAuthAutomaticHandling(target, .{ .delivery_failed = err });
            return;
        };
        defer accepted.deinit();
        if (!accepted.value.success) {
            self.setMcpAuthAutomaticHandling(
                target,
                .{ .delivery_failed = error.McpAuthNotAccepted },
            );
            return;
        }
        self.setMcpAuthAutomaticHandling(target, .handled);
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
        return null;
    }

    fn applyExtensionEvent(
        self: *Client,
        session_id: []const u8,
        event: *const session_types.SessionEvent,
    ) !void {
        const runtime = self.findExtensionRuntime(session_id) orelse return;
        try applyExtensionEventToRuntime(self.allocator, runtime, event);
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
                    if (ui.elicitation) |elicitation| {
                        runtime.capabilities.elicitation = capabilityState(elicitation);
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
                if (self.events.items[index].automatic_handling_in_progress) {
                    self.events.items[index].remove_after_automatic_handling = true;
                    index += 1;
                    continue;
                }
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
        if (self.findExtensionRuntime(session_id)) |runtime| {
            if (runtime.credentials_quarantined) return null;
            for (runtime.provider_tokens orelse &.{}) |registered| {
                if (std.mem.eql(u8, registered.provider_name, provider_name)) {
                    return registered.token_provider;
                }
            }
        }
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

    fn nextEvent(self: *Client, session_id: []const u8) !session_types.SessionEvent {
        while (true) {
            for (self.events.items, 0..) |queued, index| {
                if (!queued.automatic_handling_in_progress and
                    std.mem.eql(u8, queued.session_id, session_id))
                {
                    const result = self.events.orderedRemove(index);
                    self.allocator.free(result.session_id);
                    return result.event;
                }
            }
            if (self.sessionEventQueueFailure(session_id)) |failure| {
                return switch (failure) {
                    .capacity_exceeded => error.EventQueueFull,
                    .allocation_failed => error.EventQueueAllocationFailed,
                    .rejection_failed => error.EventQueueRejectionFailed,
                };
            }

            const body = try json_rpc.readFrame(self.allocator, &self.reader.interface);
            var owns_body = true;
            defer {
                if (owns_body) {
                    wipeSecret(body);
                    self.allocator.free(body);
                }
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
            const method_value = object.get("method") orelse {
                const response_id = object.get("id") orelse return error.InvalidJsonRpc;
                const response_number = switch (response_id) {
                    .integer => |number| std.math.cast(u64, number) orelse
                        return error.InvalidJsonRpc,
                    else => return error.InvalidJsonRpc,
                };
                if (!self.isActiveRequest(response_number) or
                    self.hasBufferedResponse(response_number))
                {
                    return error.UnexpectedResponse;
                }
                try self.buffered_responses.append(self.allocator, .{
                    .id = response_number,
                    .body = body,
                });
                owns_body = false;
                continue;
            };
            const method = switch (method_value) {
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

const ElicitationResponse = union(enum) {
    cancelled,
    result: struct {
        action: session_types.ElicitationAction,
        content: ?std.json.Value,
    },
};

pub const Session = struct {
    client: *Client,
    id: []const u8,

    pub fn send(self: Session, options: session_types.MessageOptions) ![]u8 {
        const parsed = try self.client.call(
            struct { messageId: []const u8 },
            "session.send",
            lowerMessage(self.id, options),
        );
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

    pub fn capabilities(self: Session) ext.CapabilitySet {
        const runtime = self.client.findExtensionRuntime(self.id) orelse return .{};
        return runtime.capabilities;
    }

    pub fn ui(self: Session) SessionUi {
        return .{ .session = self };
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

    pub fn disconnect(self: Session) !void {
        var released_oauth_interest = false;
        if (self.client.findExtensionRuntime(self.id)) |runtime| {
            if (runtime.mcp_oauth_interest == .restore_required) {
                self.client.registerMcpOAuthInterest(runtime) catch
                    return error.McpOAuthInterestRestoreFailed;
            }
            const current = self.client.findExtensionRuntime(self.id) orelse
                return error.MissingExtensionRuntime;
            released_oauth_interest = current.mcp_oauth_interest == .registered;
            try self.client.releaseMcpOAuthInterest(current);
        }
        for (0..2) |_| {
            const parsed = self.client.call(struct {
                success: bool,
                @"error": ?[]const u8 = null,
            }, "session.detach", .{
                .sessionId = self.id,
            }) catch |detach_error| {
                try self.restoreMcpOAuthInterestAfterDetachFailure(released_oauth_interest);
                return detach_error;
            };
            defer parsed.deinit();
            if (parsed.value.success) {
                self.client.removeSession(self.id);
                return;
            }
        }
        try self.restoreMcpOAuthInterestAfterDetachFailure(released_oauth_interest);
        return error.SessionDetachFailed;
    }

    fn restoreMcpOAuthInterestAfterDetachFailure(
        self: Session,
        released_oauth_interest: bool,
    ) !void {
        if (!released_oauth_interest) return;
        const runtime = self.client.findExtensionRuntime(self.id) orelse
            return error.MissingExtensionRuntime;
        if (runtime.mcp_auth_handler == null) return;
        switch (runtime.mcp_oauth_interest) {
            .none => runtime.mcp_oauth_interest = .restore_required,
            .restore_required => {},
            .registered => return,
            .registering, .releasing => return error.EventInterestOperationInProgress,
        }
        const current = self.client.findExtensionRuntime(self.id) orelse
            return error.MissingExtensionRuntime;
        self.client.registerMcpOAuthInterest(current) catch
            return error.McpOAuthInterestRestoreFailed;
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

pub const SessionUi = struct {
    session: Session,

    pub fn elicitation(
        self: SessionUi,
        params: session_types.UiElicitationParams,
    ) !session_types.UiElicitationResult {
        const schema = try std.json.parseFromSlice(
            std.json.Value,
            self.session.client.allocator,
            params.requested_schema_json,
            .{},
        );
        defer schema.deinit();
        if (schema.value != .object) return error.InvalidElicitationSchema;
        var result = try self.elicitationValue(params.message, schema.value);
        defer result.deinit();
        return .{
            .allocator = self.session.client.allocator,
            .action = result.action,
            .content_json = if (result.content) |content|
                try stringifyJsonValue(self.session.client.allocator, content)
            else
                null,
        };
    }

    pub fn confirm(self: SessionUi, message: []const u8) !bool {
        var schema: std.json.ObjectMap = .empty;
        defer schema.deinit(self.session.client.allocator);
        var properties: std.json.ObjectMap = .empty;
        defer properties.deinit(self.session.client.allocator);
        var confirmed: std.json.ObjectMap = .empty;
        defer confirmed.deinit(self.session.client.allocator);
        try confirmed.put(self.session.client.allocator, "type", .{ .string = "boolean" });
        try confirmed.put(self.session.client.allocator, "default", .{ .bool = true });
        try properties.put(self.session.client.allocator, "confirmed", .{ .object = confirmed });
        try schema.put(self.session.client.allocator, "type", .{ .string = "object" });
        try schema.put(self.session.client.allocator, "properties", .{ .object = properties });
        var required = std.json.Array.init(self.session.client.allocator);
        defer required.deinit();
        try required.append(.{ .string = "confirmed" });
        try schema.put(self.session.client.allocator, "required", .{ .array = required });
        var result = try self.elicitationValue(message, .{ .object = schema });
        defer result.deinit();
        if (result.action != .accept) return false;
        const content = result.content orelse return error.InvalidElicitationResult;
        const object = switch (content) {
            .object => |object| object,
            else => return error.InvalidElicitationResult,
        };
        return switch (object.get("confirmed") orelse return error.InvalidElicitationResult) {
            .bool => |value| value,
            else => error.InvalidElicitationResult,
        };
    }

    pub fn select(
        self: SessionUi,
        message: []const u8,
        options: []const []const u8,
    ) !?[]u8 {
        var schema: std.json.ObjectMap = .empty;
        defer schema.deinit(self.session.client.allocator);
        var properties: std.json.ObjectMap = .empty;
        defer properties.deinit(self.session.client.allocator);
        var selection: std.json.ObjectMap = .empty;
        defer selection.deinit(self.session.client.allocator);
        try selection.put(self.session.client.allocator, "type", .{ .string = "string" });
        var choices = std.json.Array.init(self.session.client.allocator);
        defer choices.deinit();
        for (options) |option| try choices.append(.{ .string = option });
        try selection.put(self.session.client.allocator, "enum", .{ .array = choices });
        try properties.put(self.session.client.allocator, "selection", .{ .object = selection });
        try schema.put(self.session.client.allocator, "type", .{ .string = "object" });
        try schema.put(self.session.client.allocator, "properties", .{ .object = properties });
        var required = std.json.Array.init(self.session.client.allocator);
        defer required.deinit();
        try required.append(.{ .string = "selection" });
        try schema.put(self.session.client.allocator, "required", .{ .array = required });

        var result = try self.elicitationValue(message, .{ .object = schema });
        defer result.deinit();
        if (result.action != .accept) return null;
        const selected = try elicitationStringField(
            self.session.client.allocator,
            result.content,
            "selection",
        );
        errdefer {
            wipeSecret(selected);
            self.session.client.allocator.free(selected);
        }
        for (options) |option| {
            if (std.mem.eql(u8, selected, option)) return selected;
        }
        return error.InvalidElicitationResult;
    }

    pub fn input(
        self: SessionUi,
        message: []const u8,
        options: session_types.UiInputOptions,
    ) !?[]u8 {
        if (options.min_length != null and options.max_length != null and
            options.min_length.? > options.max_length.?)
        {
            return error.InvalidElicitationSchema;
        }
        if (options.default) |value| {
            if (!uiInputValueIsValid(value, options))
                return error.InvalidElicitationSchema;
        }
        var schema: std.json.ObjectMap = .empty;
        defer schema.deinit(self.session.client.allocator);
        var properties: std.json.ObjectMap = .empty;
        defer properties.deinit(self.session.client.allocator);
        var field: std.json.ObjectMap = .empty;
        defer field.deinit(self.session.client.allocator);
        try field.put(self.session.client.allocator, "type", .{ .string = "string" });
        if (options.title) |value| try field.put(self.session.client.allocator, "title", .{ .string = value });
        if (options.description) |value| try field.put(self.session.client.allocator, "description", .{ .string = value });
        if (options.min_length) |value| try field.put(
            self.session.client.allocator,
            "minLength",
            .{ .integer = std.math.cast(i64, value) orelse return error.InvalidElicitationSchema },
        );
        if (options.max_length) |value| try field.put(
            self.session.client.allocator,
            "maxLength",
            .{ .integer = std.math.cast(i64, value) orelse return error.InvalidElicitationSchema },
        );
        if (options.format) |value| try field.put(self.session.client.allocator, "format", .{ .string = @tagName(value) });
        if (options.default) |value| try field.put(self.session.client.allocator, "default", .{ .string = value });
        try properties.put(self.session.client.allocator, "value", .{ .object = field });
        try schema.put(self.session.client.allocator, "type", .{ .string = "object" });
        try schema.put(self.session.client.allocator, "properties", .{ .object = properties });
        var required = std.json.Array.init(self.session.client.allocator);
        defer required.deinit();
        try required.append(.{ .string = "value" });
        try schema.put(self.session.client.allocator, "required", .{ .array = required });

        var result = try self.elicitationValue(message, .{ .object = schema });
        defer result.deinit();
        if (result.action != .accept) return null;
        const value = try elicitationStringField(
            self.session.client.allocator,
            result.content,
            "value",
        );
        errdefer {
            wipeSecret(value);
            self.session.client.allocator.free(value);
        }
        if (!uiInputValueIsValid(value, options))
            return error.InvalidElicitationResult;
        return value;
    }

    fn elicitationValue(
        self: SessionUi,
        message: []const u8,
        requested_schema: std.json.Value,
    ) !OwnedUiElicitationResult {
        const runtime = self.session.client.findExtensionRuntime(self.session.id) orelse
            return error.UnsupportedCapability;
        if (!runtime.capabilities.supports(.elicitation))
            return error.UnsupportedCapability;
        var parsed = try self.session.client.call(
            std.json.Value,
            "session.ui.elicitation",
            .{
                .sessionId = self.session.id,
                .message = message,
                .requestedSchema = requested_schema,
            },
        );
        errdefer {
            wipeJsonStrings(parsed.value);
            parsed.deinit();
        }
        const object = switch (parsed.value) {
            .object => |value| value,
            else => return error.InvalidElicitationResult,
        };
        const action_string = jsonRequiredString(object, "action") catch
            return error.InvalidElicitationResult;
        const action = std.meta.stringToEnum(
            session_types.ElicitationAction,
            action_string,
        ) orelse return error.InvalidElicitationResult;
        const content = if (object.get("content")) |content| blk: {
            if (content != .object) return error.InvalidElicitationResult;
            break :blk content;
        } else null;
        return .{
            .response = parsed,
            .action = action,
            .content = content,
        };
    }
};

const OwnedUiElicitationResult = struct {
    response: std.json.Parsed(std.json.Value),
    action: session_types.ElicitationAction,
    content: ?std.json.Value,

    fn deinit(self: *OwnedUiElicitationResult) void {
        wipeJsonStrings(self.response.value);
        self.response.deinit();
        self.* = undefined;
    }
};

fn elicitationStringField(
    allocator: std.mem.Allocator,
    content: ?std.json.Value,
    name: []const u8,
) ![]u8 {
    const content_value = content orelse return error.InvalidElicitationResult;
    const object = switch (content_value) {
        .object => |value| value,
        else => return error.InvalidElicitationResult,
    };
    const value = jsonRequiredString(object, name) catch return error.InvalidElicitationResult;
    return allocator.dupe(u8, value);
}

fn uiInputValueIsValid(
    value: []const u8,
    options: session_types.UiInputOptions,
) bool {
    const length = std.unicode.utf8CountCodepoints(value) catch return false;
    if (options.min_length) |minimum| {
        if (length < minimum) return false;
    }
    if (options.max_length) |maximum| {
        if (length > maximum) return false;
    }
    const format = options.format orelse return true;
    return switch (format) {
        .email => isValidEmail(value),
        .uri => isValidUri(value),
        .date => isValidDate(value),
        .@"date-time" => isValidDateTime(value),
    };
}

fn isValidEmail(value: []const u8) bool {
    if (value.len > 254) return false;
    const separator = std.mem.indexOfScalar(u8, value, '@') orelse return false;
    if (separator == 0 or separator + 1 == value.len) return false;
    if (std.mem.indexOfScalarPos(u8, value, separator + 1, '@') != null) return false;
    const local = value[0..separator];
    const domain = value[separator + 1 ..];
    if (local.len > 64 or domain.len > 253) return false;
    if (local[0] == '.' or local[local.len - 1] == '.' or
        domain[0] == '.' or domain[domain.len - 1] == '.' or
        std.mem.indexOf(u8, local, "..") != null or
        std.mem.indexOf(u8, domain, "..") != null)
    {
        return false;
    }
    for (local) |byte| {
        if (!isEmailAtomByte(byte) and byte != '.') return false;
    }
    var labels = std.mem.splitScalar(u8, domain, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or
            !std.ascii.isAlphanumeric(label[0]) or
            !std.ascii.isAlphanumeric(label[label.len - 1]))
        {
            return false;
        }
        if (label.len > 2) {
            for (label[1 .. label.len - 1]) |byte| {
                if (!std.ascii.isAlphanumeric(byte) and byte != '-') return false;
            }
        }
    }
    return true;
}

fn isEmailAtomByte(byte: u8) bool {
    if (std.ascii.isAlphanumeric(byte)) return true;
    return switch (byte) {
        '!',
        '#',
        '$',
        '%',
        '&',
        '\'',
        '*',
        '+',
        '-',
        '/',
        '=',
        '?',
        '^',
        '_',
        '`',
        '{',
        '|',
        '}',
        '~',
        => true,
        else => false,
    };
}

fn isValidUri(value: []const u8) bool {
    const uri = std.Uri.parse(value) catch return false;
    return uri.scheme.len != 0;
}

fn isValidDate(value: []const u8) bool {
    if (value.len != 10 or value[4] != '-' or value[7] != '-') return false;
    const year = parseFixedDecimal(value[0..4]) orelse return false;
    const month = parseFixedDecimal(value[5..7]) orelse return false;
    const day = parseFixedDecimal(value[8..10]) orelse return false;
    if (month < 1 or month > 12 or day < 1) return false;
    return day <= daysInMonth(year, month);
}

fn isValidDateTime(value: []const u8) bool {
    if (value.len < 20 or !isValidDate(value[0..10])) return false;
    if (value[10] != 'T' and value[10] != 't') return false;
    if (value[13] != ':' or value[16] != ':') return false;
    const hour = parseFixedDecimal(value[11..13]) orelse return false;
    const minute = parseFixedDecimal(value[14..16]) orelse return false;
    const second = parseFixedDecimal(value[17..19]) orelse return false;
    if (hour > 23 or minute > 59 or second > 60) return false;
    var index: usize = 19;
    if (index < value.len and value[index] == '.') {
        index += 1;
        const fraction_start = index;
        while (index < value.len and std.ascii.isDigit(value[index])) : (index += 1) {}
        if (index == fraction_start) return false;
    }
    var offset_minutes: i32 = 0;
    if (index == value.len - 1 and (value[index] == 'Z' or value[index] == 'z')) {
        return second != 60 or isValidLeapSecond(value, hour, minute, offset_minutes);
    }
    if (index + 6 != value.len or
        (value[index] != '+' and value[index] != '-') or
        value[index + 3] != ':')
    {
        return false;
    }
    const offset_hour = parseFixedDecimal(value[index + 1 .. index + 3]) orelse return false;
    const offset_minute = parseFixedDecimal(value[index + 4 .. index + 6]) orelse return false;
    if (offset_hour > 23 or offset_minute > 59) return false;
    offset_minutes = @as(i32, offset_hour) * 60 + offset_minute;
    if (value[index] == '-') offset_minutes = -offset_minutes;
    return second != 60 or isValidLeapSecond(value, hour, minute, offset_minutes);
}

fn parseFixedDecimal(value: []const u8) ?u16 {
    var result: u16 = 0;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
        result = result * 10 + (byte - '0');
    }
    return result;
}

fn daysInMonth(year: u16, month: u16) u16 {
    const leap = @mod(year, 4) == 0 and
        (@mod(year, 100) != 0 or @mod(year, 400) == 0);
    const month_lengths = [_]u8{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return month_lengths[month - 1];
}

fn isValidLeapSecond(
    value: []const u8,
    hour: u16,
    minute: u16,
    offset_minutes: i32,
) bool {
    var year = parseFixedDecimal(value[0..4]) orelse return false;
    var month = parseFixedDecimal(value[5..7]) orelse return false;
    var day = parseFixedDecimal(value[8..10]) orelse return false;
    var utc_minute = @as(i32, hour) * 60 + minute - offset_minutes;
    if (utc_minute < 0) {
        utc_minute += 24 * 60;
        if (day > 1) {
            day -= 1;
        } else if (month > 1) {
            month -= 1;
            day = daysInMonth(year, month);
        } else {
            if (year == 0) return false;
            year -= 1;
            month = 12;
            day = 31;
        }
    } else if (utc_minute >= 24 * 60) {
        utc_minute -= 24 * 60;
        if (day < daysInMonth(year, month)) {
            day += 1;
        } else if (month < 12) {
            month += 1;
            day = 1;
        } else {
            if (year == 9999) return false;
            year += 1;
            month = 1;
            day = 1;
        }
    }
    return utc_minute == 23 * 60 + 59 and
        ((month == 6 and day == 30) or (month == 12 and day == 31));
}

test "UI input validation enforces lengths and every supported format" {
    try std.testing.expect(uiInputValueIsValid("42", .{}));
    try std.testing.expect(uiInputValueIsValid("é", .{
        .min_length = 1,
        .max_length = 1,
    }));
    try std.testing.expect(!uiInputValueIsValid("é", .{ .max_length = 0 }));
    try std.testing.expect(uiInputValueIsValid("user@example.com", .{ .format = .email }));
    try std.testing.expect(!uiInputValueIsValid("not-an-email", .{ .format = .email }));
    try std.testing.expect(!uiInputValueIsValid("a..b@example.com", .{ .format = .email }));
    try std.testing.expect(!uiInputValueIsValid("a@-", .{ .format = .email }));
    try std.testing.expect(!uiInputValueIsValid("a@foo-.com", .{ .format = .email }));
    try std.testing.expect(!uiInputValueIsValid("a(b)@example.com", .{ .format = .email }));
    try std.testing.expect(!uiInputValueIsValid("a,b@example.com", .{ .format = .email }));
    try std.testing.expect(!uiInputValueIsValid("\"a\"@example.com", .{ .format = .email }));
    try std.testing.expect(!uiInputValueIsValid("ü@example.com", .{ .format = .email }));
    try std.testing.expect(!uiInputValueIsValid("a@exämple.com", .{ .format = .email }));
    const max_local = ([_]u8{'a'} ** 64) ++ "@example.com";
    const oversized_local = ([_]u8{'a'} ** 65) ++ "@example.com";
    try std.testing.expect(uiInputValueIsValid(max_local[0..], .{ .format = .email }));
    try std.testing.expect(!uiInputValueIsValid(oversized_local[0..], .{ .format = .email }));
    const max_label = "a@" ++ ([_]u8{'b'} ** 63) ++ ".com";
    const oversized_label = "a@" ++ ([_]u8{'b'} ** 64) ++ ".com";
    try std.testing.expect(uiInputValueIsValid(max_label[0..], .{ .format = .email }));
    try std.testing.expect(!uiInputValueIsValid(oversized_label[0..], .{ .format = .email }));
    const max_address =
        ([_]u8{'a'} ** 64) ++ "@" ++
        ([_]u8{'b'} ** 63) ++ "." ++
        ([_]u8{'c'} ** 63) ++ "." ++
        ([_]u8{'d'} ** 61);
    const oversized_address = max_address ++ "d";
    try std.testing.expectEqual(@as(usize, 254), max_address.len);
    try std.testing.expect(uiInputValueIsValid(max_address[0..], .{ .format = .email }));
    try std.testing.expect(!uiInputValueIsValid(oversized_address[0..], .{ .format = .email }));
    try std.testing.expect(uiInputValueIsValid("https://127.0.0.1:8080/path", .{ .format = .uri }));
    try std.testing.expect(!uiInputValueIsValid("example.com/path", .{ .format = .uri }));
    try std.testing.expect(uiInputValueIsValid("2024-02-29", .{ .format = .date }));
    try std.testing.expect(!uiInputValueIsValid("2023-02-29", .{ .format = .date }));
    try std.testing.expect(uiInputValueIsValid(
        "2024-07-01T01:59:60.5+02:00",
        .{ .format = .@"date-time" },
    ));
    try std.testing.expect(!uiInputValueIsValid(
        "2024-02-29 23:59:59",
        .{ .format = .@"date-time" },
    ));
    try std.testing.expect(!uiInputValueIsValid(
        "2024-01-15T12:34:60Z",
        .{ .format = .@"date-time" },
    ));
}

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

fn validateExpAssignments(value: session_types.CopilotExpAssignmentResponse) !void {
    for (value.flights, 0..) |flight, index| {
        for (value.flights[index + 1 ..]) |candidate| {
            if (std.mem.eql(u8, flight.name, candidate.name))
                return error.InvalidExpAssignments;
        }
    }
    for (value.configs) |config| {
        for (config.parameters, 0..) |parameter, index| {
            switch (parameter.value) {
                .number => |number| if (!std.math.isFinite(number))
                    return error.InvalidExpAssignments,
                else => {},
            }
            for (config.parameters[index + 1 ..]) |candidate| {
                if (std.mem.eql(u8, parameter.name, candidate.name))
                    return error.InvalidExpAssignments;
            }
        }
    }
    if (value.flighting_version) |version| {
        if (!std.math.isFinite(version)) return error.InvalidExpAssignments;
    }
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

const WireCommand = struct {
    name: []const u8,
    description: []const u8,
};

const WireCommands = struct {
    values: []const session_types.CommandDefinition,

    pub fn jsonStringify(self: WireCommands, writer: anytype) !void {
        try writer.beginArray();
        for (self.values) |command| {
            try writer.write(WireCommand{
                .name = command.name,
                .description = command.description orelse "",
            });
        }
        try writer.endArray();
    }
};

const WireExpAssignments = struct {
    value: session_types.CopilotExpAssignmentResponse,

    pub fn jsonStringify(self: WireExpAssignments, writer: anytype) !void {
        try writer.beginObject();
        try writer.objectField("Features");
        try writer.write(self.value.features);
        try writer.objectField("Flights");
        try writer.beginObject();
        for (self.value.flights) |flight| {
            try writer.objectField(flight.name);
            try writer.write(flight.value);
        }
        try writer.endObject();
        try writer.objectField("Configs");
        try writer.beginArray();
        for (self.value.configs) |config| {
            try writer.beginObject();
            try writer.objectField("Id");
            try writer.write(config.id);
            try writer.objectField("Parameters");
            try writer.beginObject();
            for (config.parameters) |parameter| {
                try writer.objectField(parameter.name);
                switch (parameter.value) {
                    .string => |value| try writer.write(value),
                    .number => |value| try writer.write(value),
                    .boolean => |value| try writer.write(value),
                    .null => try writer.write(null),
                }
            }
            try writer.endObject();
            try writer.endObject();
        }
        try writer.endArray();
        if (self.value.parameter_groups) |value| {
            try writer.objectField("ParameterGroups");
            try writer.write(value);
        }
        if (self.value.flighting_version) |value| {
            try writer.objectField("FlightingVersion");
            try writer.write(value);
        }
        if (self.value.impression_id) |value| {
            try writer.objectField("ImpressionId");
            try writer.write(value);
        }
        try writer.objectField("AssignmentContext");
        try writer.write(self.value.assignment_context);
        try writer.endObject();
    }
};

const WireToolSearch = struct {
    enabled: ?bool = null,
    deferThreshold: ?u64 = null,
};

const WireGitHubMcpToolConfig = struct {
    enableAllTools: ?bool = null,
    additionalToolsets: ?[]const []const u8 = null,
    additionalTools: ?[]const []const u8 = null,
    enableInsidersMode: ?bool = null,
    disableFormDeferral: ?bool = null,
};

const WireCloudSessionRepository = struct {
    owner: []const u8,
    name: []const u8,
    branch: ?[]const u8 = null,
};

const WireCloudSessionOptions = struct {
    repository: ?WireCloudSessionRepository = null,
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

const WireGitHubTokenRequest = struct {
    registrationId: []const u8,
    host: []const u8,
    sessionId: ?[]const u8 = null,
    reason: session_types.GitHubTokenReason,
};

const WireExitPlanModeRequest = struct {
    sessionId: []const u8,
    summary: []const u8,
    planContent: ?[]const u8 = null,
    actions: []const session_types.ExitPlanModeAction,
    recommendedAction: session_types.ExitPlanModeAction,
};

const WireAutoModeSwitchRequest = struct {
    sessionId: []const u8,
    errorCode: ?[]const u8 = null,
    retryAfterSeconds: ?u64 = null,
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
    elicitation: ?bool = null,
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
        .elicitation = capabilityState(ui.elicitation),
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
    feature_flags_object: std.json.ObjectMap = .empty,
    feature_flags: ?std.json.Value = null,
    exp_assignments: ?WireExpAssignments = null,
    git_hub_token_registration_id: ?[]const u8 = null,

    fn init(allocator: std.mem.Allocator) ExtensionWireValues {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *ExtensionWireValues) void {
        for (self.custom_agent_mcp_objects.items) |*object| object.deinit(self.allocator);
        self.custom_agent_mcp_objects.deinit(self.allocator);
        self.custom_agents.deinit(self.allocator);
        self.feature_flags_object.deinit(self.allocator);
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

    fn lowerHostInjection(
        self: *ExtensionWireValues,
        feature_flags: ?[]const session_types.FeatureFlag,
        exp_assignments: ?session_types.CopilotExpAssignmentResponse,
    ) !void {
        if (feature_flags) |flags| {
            for (flags) |flag| {
                if (flag.name.len == 0 or self.feature_flags_object.contains(flag.name))
                    return error.InvalidFeatureFlags;
                try self.feature_flags_object.put(
                    self.allocator,
                    flag.name,
                    .{ .bool = flag.enabled },
                );
            }
            self.feature_flags = .{ .object = self.feature_flags_object };
        }
        if (exp_assignments) |value| {
            try validateExpAssignments(value);
            self.exp_assignments = .{ .value = value };
        }
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
    includeSubAgentStreamingEvents: bool,
    tools: []const WireTool,
    commands: ?WireCommands,
    toolSearch: ?WireToolSearch,
    availableTools: ?[]const []const u8,
    excludedTools: ?[]const []const u8,
    customAgents: ?[]const WireCustomAgent,
    defaultAgent: ?WireDefaultAgent,
    agent: ?[]const u8,
    customAgentsLocalOnly: ?bool,
    excludedBuiltinAgents: ?[]const []const u8,
    toolFilterPrecedence: ToolFilterPrecedence = .excluded,
    systemMessage: ?session_types.SystemMessageConfig,
    enableSessionTelemetry: ?bool,
    enableFileChangeTracking: ?bool,
    requestPermission: bool,
    requestUserInput: bool,
    requestElicitation: bool,
    askUserVariant: ?session_types.AskUserVariant,
    githubMcpToolConfig: ?WireGitHubMcpToolConfig,
    requestExitPlanMode: bool,
    requestAutoModeSwitch: bool,
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
    gitHubToken: ?[]const u8,
    gitHubTokenProviderRegistrationId: ?[]const u8,
    remoteSession: ?session_types.RemoteSessionMode,
    cloud: ?WireCloudSessionOptions,
    featureFlags: ?std.json.Value,
    expAssignments: ?WireExpAssignments,
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
    includeSubAgentStreamingEvents: bool,
    tools: []const WireTool,
    commands: ?WireCommands,
    toolSearch: ?WireToolSearch,
    availableTools: ?[]const []const u8,
    excludedTools: ?[]const []const u8,
    customAgents: ?[]const WireCustomAgent,
    defaultAgent: ?WireDefaultAgent,
    agent: ?[]const u8,
    customAgentsLocalOnly: ?bool,
    excludedBuiltinAgents: ?[]const []const u8,
    toolFilterPrecedence: ToolFilterPrecedence = .excluded,
    systemMessage: ?session_types.SystemMessageConfig,
    enableSessionTelemetry: ?bool,
    enableFileChangeTracking: ?bool,
    requestPermission: bool,
    requestUserInput: bool,
    requestElicitation: bool,
    askUserVariant: ?session_types.AskUserVariant,
    githubMcpToolConfig: ?WireGitHubMcpToolConfig,
    requestExitPlanMode: bool,
    requestAutoModeSwitch: bool,
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
    gitHubToken: ?[]const u8,
    gitHubTokenProviderRegistrationId: ?[]const u8,
    remoteSession: ?session_types.RemoteSessionMode,
    featureFlags: ?std.json.Value,
    expAssignments: ?WireExpAssignments,
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

fn validateLifecycleConfig(config: anytype) !void {
    if (config.git_hub_token != null and config.git_hub_token_provider != null)
        return error.ConflictingGitHubAuthentication;
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
        .include_subagent_streaming_events = config.include_subagent_streaming_events,
        .tools = config.tools,
        .commands = config.commands,
        .tool_search = config.tool_search,
        .available_tools = config.available_tools,
        .excluded_tools = config.excluded_tools,
        .custom_agents = config.custom_agents,
        .default_agent = config.default_agent,
        .agent = config.agent,
        .custom_agents_local_only = config.custom_agents_local_only,
        .excluded_builtin_agents = config.excluded_builtin_agents,
        .system_message = config.system_message,
        .enable_session_telemetry = config.enable_session_telemetry,
        .enable_file_change_tracking = config.enable_file_change_tracking,
        .coauthor_enabled = config.coauthor_enabled,
        .manage_schedule_enabled = config.manage_schedule_enabled,
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
        .ask_user_variant = config.ask_user_variant,
        .on_elicitation_request = config.on_elicitation_request,
        .elicitation_context = config.elicitation_context,
        .github_mcp_tool_config = config.github_mcp_tool_config,
        .on_exit_plan_mode_request = config.on_exit_plan_mode_request,
        .exit_plan_mode_context = config.exit_plan_mode_context,
        .on_auto_mode_switch_request = config.on_auto_mode_switch_request,
        .auto_mode_switch_context = config.auto_mode_switch_context,
        .git_hub_token = config.git_hub_token,
        .git_hub_token_provider = config.git_hub_token_provider,
        .remote_session = config.remote_session,
        .feature_flags = config.feature_flags,
        .exp_assignments = config.exp_assignments,
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
        .include_subagent_streaming_events = config.include_subagent_streaming_events,
        .tools = config.tools,
        .commands = config.commands,
        .tool_search = config.tool_search,
        .available_tools = config.available_tools,
        .excluded_tools = config.excluded_tools,
        .custom_agents = config.custom_agents,
        .default_agent = config.default_agent,
        .agent = config.agent,
        .custom_agents_local_only = config.custom_agents_local_only,
        .excluded_builtin_agents = config.excluded_builtin_agents,
        .system_message = config.system_message,
        .enable_session_telemetry = config.enable_session_telemetry,
        .enable_file_change_tracking = config.enable_file_change_tracking,
        .coauthor_enabled = config.coauthor_enabled,
        .manage_schedule_enabled = config.manage_schedule_enabled,
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
        .ask_user_variant = config.ask_user_variant,
        .on_elicitation_request = config.on_elicitation_request,
        .elicitation_context = config.elicitation_context,
        .github_mcp_tool_config = config.github_mcp_tool_config,
        .on_exit_plan_mode_request = config.on_exit_plan_mode_request,
        .exit_plan_mode_context = config.exit_plan_mode_context,
        .on_auto_mode_switch_request = config.on_auto_mode_switch_request,
        .auto_mode_switch_context = config.auto_mode_switch_context,
        .git_hub_token = config.git_hub_token,
        .git_hub_token_provider = config.git_hub_token_provider,
        .remote_session = config.remote_session,
        .feature_flags = config.feature_flags,
        .exp_assignments = config.exp_assignments,
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

fn lowerToolSearch(
    config: ?session_types.ToolSearchConfig,
) ?WireToolSearch {
    const value = config orelse return null;
    return .{
        .enabled = value.enabled,
        .deferThreshold = value.defer_threshold,
    };
}

fn lowerGitHubMcpToolConfig(
    config: ?session_types.GitHubMcpToolConfig,
) ?WireGitHubMcpToolConfig {
    const value = config orelse return null;
    return .{
        .enableAllTools = value.enable_all_tools,
        .additionalToolsets = value.additional_toolsets,
        .additionalTools = value.additional_tools,
        .enableInsidersMode = value.enable_insiders_mode,
        .disableFormDeferral = value.disable_form_deferral,
    };
}

fn lowerCloud(
    config: ?session_types.CloudSessionOptions,
) ?WireCloudSessionOptions {
    const value = config orelse return null;
    return .{
        .repository = if (value.repository) |repository| .{
            .owner = repository.owner,
            .name = repository.name,
            .branch = repository.branch,
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
        .includeSubAgentStreamingEvents = config.include_subagent_streaming_events,
        .tools = tools,
        .commands = if (config.commands.len == 0) null else .{ .values = config.commands },
        .toolSearch = lowerToolSearch(config.tool_search),
        .availableTools = config.available_tools,
        .excludedTools = config.excluded_tools,
        .customAgents = values.wireCustomAgents(),
        .defaultAgent = lowerDefaultAgent(config.default_agent),
        .agent = lowerInitialAgent(config.agent),
        .customAgentsLocalOnly = config.custom_agents_local_only,
        .excludedBuiltinAgents = config.excluded_builtin_agents,
        .systemMessage = config.system_message,
        .enableSessionTelemetry = config.enable_session_telemetry,
        .enableFileChangeTracking = config.enable_file_change_tracking,
        .requestPermission = config.request_permission or config.on_permission_request != null,
        .requestUserInput = config.on_user_input_request != null,
        .requestElicitation = config.on_elicitation_request != null,
        .askUserVariant = config.ask_user_variant,
        .githubMcpToolConfig = lowerGitHubMcpToolConfig(config.github_mcp_tool_config),
        .requestExitPlanMode = config.on_exit_plan_mode_request != null,
        .requestAutoModeSwitch = config.on_auto_mode_switch_request != null,
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
        .gitHubToken = config.git_hub_token,
        .gitHubTokenProviderRegistrationId = values.git_hub_token_registration_id,
        .remoteSession = config.remote_session,
        .cloud = lowerCloud(config.cloud),
        .featureFlags = values.feature_flags,
        .expAssignments = values.exp_assignments,
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
        .includeSubAgentStreamingEvents = config.include_subagent_streaming_events,
        .tools = tools,
        .commands = if (config.commands.len == 0) null else .{ .values = config.commands },
        .toolSearch = lowerToolSearch(config.tool_search),
        .availableTools = config.available_tools,
        .excludedTools = config.excluded_tools,
        .customAgents = values.wireCustomAgents(),
        .defaultAgent = lowerDefaultAgent(config.default_agent),
        .agent = lowerInitialAgent(config.agent),
        .customAgentsLocalOnly = config.custom_agents_local_only,
        .excludedBuiltinAgents = config.excluded_builtin_agents,
        .systemMessage = config.system_message,
        .enableSessionTelemetry = config.enable_session_telemetry,
        .enableFileChangeTracking = config.enable_file_change_tracking,
        .requestPermission = config.request_permission or config.on_permission_request != null,
        .requestUserInput = config.on_user_input_request != null,
        .requestElicitation = config.on_elicitation_request != null,
        .askUserVariant = config.ask_user_variant,
        .githubMcpToolConfig = lowerGitHubMcpToolConfig(config.github_mcp_tool_config),
        .requestExitPlanMode = config.on_exit_plan_mode_request != null,
        .requestAutoModeSwitch = config.on_auto_mode_switch_request != null,
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
        .gitHubToken = config.git_hub_token,
        .gitHubTokenProviderRegistrationId = values.git_hub_token_registration_id,
        .remoteSession = config.remote_session,
        .featureFlags = values.feature_flags,
        .expAssignments = values.exp_assignments,
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
    _ = &Session.ui;
    _ = &SessionUi.elicitation;
    _ = &SessionUi.confirm;
    _ = &SessionUi.select;
    _ = &SessionUi.input;
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

const TestGitHubTokenState = struct {
    expires_in_seconds: u64 = 3601,
    cancelled: bool = false,
    fail: bool = false,
    calls: usize = 0,
    last_reason: ?session_types.GitHubTokenReason = null,
    last_session_id: ?[]const u8 = null,
};

fn testGitHubTokenProvider(
    allocator: std.mem.Allocator,
    request: session_types.GitHubTokenRequest,
    context: ?*anyopaque,
) !session_types.GitHubTokenResult {
    const state: *TestGitHubTokenState = @ptrCast(@alignCast(context.?));
    state.calls += 1;
    state.last_reason = request.reason;
    state.last_session_id = request.session_id;
    if (state.fail) return error.TokenProviderFailed;
    if (state.cancelled) return .cancelled;
    return .{ .token = .{
        .access_token = try allocator.dupe(u8, "secret-token"),
        .token_type = try allocator.dupe(u8, "bearer"),
        .expires_in_seconds = state.expires_in_seconds,
    } };
}

fn responseErrorCode(allocator: std.mem.Allocator, framed: []const u8) !i64 {
    const body = try framedBody(allocator, framed);
    defer allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    return parsed.value.object.get("error").?.object.get("code").?.integer;
}

test "GitHub token callbacks route by registration and session and validate lifetime" {
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

    var committed_state = TestGitHubTokenState{};
    var committed = try SessionExtensionRuntime.init(allocator, "committed", session_types.CreateSessionConfig{
        .git_hub_token_provider = .{
            .callback = testGitHubTokenProvider,
            .context = &committed_state,
        },
    }, &.{});
    committed.git_hub_token_registration_id = try allocator.dupe(u8, "committed-registration");
    try client.extension_runtimes.append(allocator, committed);

    var pending_state = TestGitHubTokenState{ .expires_in_seconds = 3600 };
    try client.beginExtensionRuntime("pending", session_types.CreateSessionConfig{
        .git_hub_token_provider = .{
            .callback = testGitHubTokenProvider,
            .context = &pending_state,
        },
    }, &.{});
    client.pending_extension_runtime.?.git_hub_token_registration_id =
        try allocator.dupe(u8, "pending-registration");

    const invalid_lifetime_params = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"registrationId":"pending-registration","host":"github.com","sessionId":"pending","reason":"initial"}
    ,
        .{},
    );
    defer invalid_lifetime_params.deinit();
    var invalid_lifetime_output: std.Io.Writer.Allocating = .init(allocator);
    defer invalid_lifetime_output.deinit();
    try client.dispatchServerRequest(
        &invalid_lifetime_output.writer,
        .{ .integer = 1 },
        "gitHubToken.getToken",
        invalid_lifetime_params.value,
    );
    try std.testing.expectEqual(
        @as(i64, -32603),
        try responseErrorCode(allocator, invalid_lifetime_output.written()),
    );
    try std.testing.expectEqual(@as(usize, 1), pending_state.calls);
    try std.testing.expectEqual(session_types.GitHubTokenReason.initial, pending_state.last_reason.?);

    const missing_pending_session_params = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"registrationId":"pending-registration","host":"github.com","reason":"initial"}
    ,
        .{},
    );
    defer missing_pending_session_params.deinit();
    var missing_pending_session_output: std.Io.Writer.Allocating = .init(allocator);
    defer missing_pending_session_output.deinit();
    try client.dispatchServerRequest(
        &missing_pending_session_output.writer,
        .{ .integer = 2 },
        "gitHubToken.getToken",
        missing_pending_session_params.value,
    );
    try std.testing.expectEqual(
        @as(i64, -32602),
        try responseErrorCode(allocator, missing_pending_session_output.written()),
    );

    pending_state.expires_in_seconds = 3601;
    var valid_output: std.Io.Writer.Allocating = .init(allocator);
    defer valid_output.deinit();
    try client.dispatchServerRequest(
        &valid_output.writer,
        .{ .integer = 3 },
        "gitHubToken.getToken",
        invalid_lifetime_params.value,
    );
    const valid_body = try framedBody(allocator, valid_output.written());
    defer allocator.free(valid_body);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":3,"result":{"kind":"token","accessToken":"secret-token","tokenType":"bearer","expiresIn":3601}}
    , valid_body);

    const committed_params = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"registrationId":"committed-registration","host":"github.example","sessionId":"committed","reason":"refresh"}
    ,
        .{},
    );
    defer committed_params.deinit();
    committed_state.cancelled = true;
    var cancelled_output: std.Io.Writer.Allocating = .init(allocator);
    defer cancelled_output.deinit();
    try client.dispatchServerRequest(
        &cancelled_output.writer,
        .{ .integer = 4 },
        "gitHubToken.getToken",
        committed_params.value,
    );
    const cancelled_body = try framedBody(allocator, cancelled_output.written());
    defer allocator.free(cancelled_body);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":4,"result":{"kind":"cancelled"}}
    , cancelled_body);
    try std.testing.expectEqualStrings("committed", committed_state.last_session_id.?);
    try std.testing.expectEqual(session_types.GitHubTokenReason.refresh, committed_state.last_reason.?);

    const missing_committed_session_params = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"registrationId":"committed-registration","host":"github.example","reason":"refresh"}
    ,
        .{},
    );
    defer missing_committed_session_params.deinit();
    var missing_committed_session_output: std.Io.Writer.Allocating = .init(allocator);
    defer missing_committed_session_output.deinit();
    try client.dispatchServerRequest(
        &missing_committed_session_output.writer,
        .{ .integer = 5 },
        "gitHubToken.getToken",
        missing_committed_session_params.value,
    );
    try std.testing.expectEqual(
        @as(i64, -32602),
        try responseErrorCode(allocator, missing_committed_session_output.written()),
    );

    const mismatched_params = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"registrationId":"pending-registration","host":"github.com","sessionId":"committed","reason":"refresh"}
    ,
        .{},
    );
    defer mismatched_params.deinit();
    var mismatched_output: std.Io.Writer.Allocating = .init(allocator);
    defer mismatched_output.deinit();
    try client.dispatchServerRequest(
        &mismatched_output.writer,
        .{ .integer = 6 },
        "gitHubToken.getToken",
        mismatched_params.value,
    );
    try std.testing.expectEqual(
        @as(i64, -32602),
        try responseErrorCode(allocator, mismatched_output.written()),
    );
    const reverse_mismatched_params = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"registrationId":"committed-registration","host":"github.com","sessionId":"pending","reason":"refresh"}
    ,
        .{},
    );
    defer reverse_mismatched_params.deinit();
    var reverse_mismatched_output: std.Io.Writer.Allocating = .init(allocator);
    defer reverse_mismatched_output.deinit();
    try client.dispatchServerRequest(
        &reverse_mismatched_output.writer,
        .{ .integer = 7 },
        "gitHubToken.getToken",
        reverse_mismatched_params.value,
    );
    try std.testing.expectEqual(
        @as(i64, -32602),
        try responseErrorCode(allocator, reverse_mismatched_output.written()),
    );

    const unknown_params = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"registrationId":"unknown","host":"github.com","reason":"initial"}
    ,
        .{},
    );
    defer unknown_params.deinit();
    var unknown_output: std.Io.Writer.Allocating = .init(allocator);
    defer unknown_output.deinit();
    try client.dispatchServerRequest(
        &unknown_output.writer,
        .{ .integer = 8 },
        "gitHubToken.getToken",
        unknown_params.value,
    );
    try std.testing.expectEqual(
        @as(i64, -32602),
        try responseErrorCode(allocator, unknown_output.written()),
    );

    const invalid_reason_params = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"registrationId":"pending-registration","host":"github.com","reason":"future"}
    ,
        .{},
    );
    defer invalid_reason_params.deinit();
    var invalid_reason_output: std.Io.Writer.Allocating = .init(allocator);
    defer invalid_reason_output.deinit();
    try client.dispatchServerRequest(
        &invalid_reason_output.writer,
        .{ .integer = 6 },
        "gitHubToken.getToken",
        invalid_reason_params.value,
    );
    try std.testing.expectEqual(
        @as(i64, -32602),
        try responseErrorCode(allocator, invalid_reason_output.written()),
    );

    const unknown_field_params = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"registrationId":"pending-registration","host":"github.com","reason":"initial","extra":true}
    ,
        .{},
    );
    defer unknown_field_params.deinit();
    var unknown_field_output: std.Io.Writer.Allocating = .init(allocator);
    defer unknown_field_output.deinit();
    try client.dispatchServerRequest(
        &unknown_field_output.writer,
        .{ .integer = 7 },
        "gitHubToken.getToken",
        unknown_field_params.value,
    );
    try std.testing.expectEqual(
        @as(i64, -32602),
        try responseErrorCode(allocator, unknown_field_output.written()),
    );

    const null_session_params = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"registrationId":"pending-registration","host":"github.com","sessionId":null,"reason":"initial"}
    ,
        .{},
    );
    defer null_session_params.deinit();
    var null_session_output: std.Io.Writer.Allocating = .init(allocator);
    defer null_session_output.deinit();
    try client.dispatchServerRequest(
        &null_session_output.writer,
        .{ .integer = 8 },
        "gitHubToken.getToken",
        null_session_params.value,
    );
    try std.testing.expectEqual(
        @as(i64, -32602),
        try responseErrorCode(allocator, null_session_output.written()),
    );

    pending_state.fail = true;
    var failed_output: std.Io.Writer.Allocating = .init(allocator);
    defer failed_output.deinit();
    try client.dispatchServerRequest(
        &failed_output.writer,
        .{ .integer = 9 },
        "gitHubToken.getToken",
        invalid_lifetime_params.value,
    );
    try std.testing.expectEqual(
        @as(i64, -32000),
        try responseErrorCode(allocator, failed_output.written()),
    );
}

test "pending cloud credentials reject forged sessions and preserve committed isolation" {
    const allocator = std.testing.allocator;
    var pending_model_state = ProviderTokenTestContext{
        .token = "pending-token",
        .expected_session_id = "forged",
        .expected_provider_name = "model-provider",
    };
    var committed_model_state = ProviderTokenTestContext{
        .token = "committed-token",
        .expected_session_id = "committed",
        .expected_provider_name = "model-provider",
    };
    var github_state = TestGitHubTokenState{};
    var command_calls: usize = 0;
    var elicitation_calls: usize = 0;
    const command_handler = struct {
        fn handle(_: session_types.CommandContext, context: ?*anyopaque) !void {
            const calls: *usize = @ptrCast(@alignCast(context.?));
            calls.* += 1;
        }
    }.handle;
    const elicitation_handler = struct {
        fn handle(
            callback_allocator: std.mem.Allocator,
            _: session_types.ElicitationRequest,
            context: ?*anyopaque,
        ) !session_types.ElicitationResult {
            const calls: *usize = @ptrCast(@alignCast(context.?));
            calls.* += 1;
            return .{
                .action = .accept,
                .content_json = try callback_allocator.dupe(u8, "{}"),
            };
        }
    }.handle;
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
        client.provider_tokens.deinit(allocator);
        client.session_ids.deinit(allocator);
    }
    var committed = try SessionExtensionRuntime.init(
        allocator,
        "committed",
        session_types.CreateSessionConfig{},
        &.{},
    );
    committed.provider_tokens = try allocator.alloc(RegisteredProviderToken, 1);
    committed.provider_tokens.?[0] = .{
        .provider_name = try allocator.dupe(u8, "model-provider"),
        .token_provider = .{
            .callback = providerTokenTestCallback,
            .context = &committed_model_state,
        },
    };
    try client.extension_runtimes.append(allocator, committed);
    try client.beginExtensionRuntime(null, session_types.CreateSessionConfig{
        .commands = &.{.{
            .name = "ship",
            .handler = command_handler,
            .context = &command_calls,
        }},
        .on_elicitation_request = elicitation_handler,
        .elicitation_context = &elicitation_calls,
        .git_hub_token_provider = .{
            .callback = testGitHubTokenProvider,
            .context = &github_state,
        },
    }, &.{});
    try client.installRuntimeProviderTokens(&.{.{
        .provider_name = "model-provider",
        .token_provider = .{
            .callback = providerTokenTestCallback,
            .context = &pending_model_state,
        },
    }});
    client.pending_extension_runtime.?.git_hub_token_registration_id =
        try allocator.dupe(u8, "cloud-registration");

    const provider_params = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"sessionId":"forged","providerName":"model-provider"}
    ,
        .{},
    );
    defer provider_params.deinit();
    var provider_output: std.Io.Writer.Allocating = .init(allocator);
    defer provider_output.deinit();
    try client.dispatchServerRequest(
        &provider_output.writer,
        .{ .integer = 1 },
        "providerToken.getToken",
        provider_params.value,
    );
    try std.testing.expectEqual(
        @as(i64, -32000),
        try responseErrorCode(allocator, provider_output.written()),
    );
    try std.testing.expectEqual(@as(usize, 0), pending_model_state.calls);

    const forged_events = [_][]const u8{
        \\{"sessionId":"forged","event":{"type":"command.execute","data":{"requestId":"command-1","command":"/ship","commandName":"ship","args":""}}}
        ,
        \\{"sessionId":"forged","event":{"type":"elicitation.requested","data":{"requestId":"elicit-1","message":"Pick"}}}
        ,
    };
    for (forged_events) |event_json| {
        const parsed_event = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            event_json,
            .{},
        );
        defer parsed_event.deinit();
        try client.queueSessionEvent(parsed_event.value);
    }
    try std.testing.expectEqual(@as(usize, 0), client.events.items.len);
    try std.testing.expectEqual(@as(usize, 0), command_calls);
    try std.testing.expectEqual(@as(usize, 0), elicitation_calls);

    const committed_provider_params = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"sessionId":"committed","providerName":"model-provider"}
    ,
        .{},
    );
    defer committed_provider_params.deinit();
    var committed_provider_output: std.Io.Writer.Allocating = .init(allocator);
    defer committed_provider_output.deinit();
    try client.dispatchServerRequest(
        &committed_provider_output.writer,
        .{ .integer = 10 },
        "providerToken.getToken",
        committed_provider_params.value,
    );
    const committed_provider_body = try framedBody(
        allocator,
        committed_provider_output.written(),
    );
    defer allocator.free(committed_provider_body);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":10,"result":{"token":"committed-token"}}
    ,
        committed_provider_body,
    );
    try std.testing.expectEqual(@as(usize, 1), committed_model_state.calls);

    const forged_github_params = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"registrationId":"cloud-registration","host":"github.com","sessionId":"forged","reason":"initial"}
    ,
        .{},
    );
    defer forged_github_params.deinit();
    var forged_github_output: std.Io.Writer.Allocating = .init(allocator);
    defer forged_github_output.deinit();
    try client.dispatchServerRequest(
        &forged_github_output.writer,
        .{ .integer = 2 },
        "gitHubToken.getToken",
        forged_github_params.value,
    );
    const forged_github_body = try framedBody(allocator, forged_github_output.written());
    defer allocator.free(forged_github_body);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"GitHub token registration mismatch"}}
    ,
        forged_github_body,
    );
    try std.testing.expectEqual(@as(usize, 0), github_state.calls);

    const initial_github_params = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"registrationId":"cloud-registration","host":"github.com","reason":"initial"}
    ,
        .{},
    );
    defer initial_github_params.deinit();
    var initial_github_output: std.Io.Writer.Allocating = .init(allocator);
    defer initial_github_output.deinit();
    try client.dispatchServerRequest(
        &initial_github_output.writer,
        .{ .integer = 3 },
        "gitHubToken.getToken",
        initial_github_params.value,
    );
    const initial_github_body = try framedBody(allocator, initial_github_output.written());
    defer allocator.free(initial_github_body);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":3,"result":{"kind":"token","accessToken":"secret-token","tokenType":"bearer","expiresIn":3601}}
    , initial_github_body);
    try std.testing.expectEqual(@as(usize, 1), github_state.calls);
    try std.testing.expect(github_state.last_session_id == null);
}

test "session UI lowers confirm select and input exactly" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const response_bodies = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"result":{"action":"accept","content":{"confirmed":true}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"result":{"action":"accept","content":{"selection":"two"}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"result":{"action":"accept","content":{"value":"hello@example.com"}}}
        ,
    };
    var response_bytes: std.Io.Writer.Allocating = .init(allocator);
    defer response_bytes.deinit();
    for (response_bodies) |body| {
        try response_bytes.writer.print("Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    }
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "responses",
        .data = response_bytes.written(),
    });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{ .mode = .read_only });
    defer response_file.close(std.testing.io);
    var reader_buffer: [4096]u8 = undefined;
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
    defer {
        for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
        client.extension_runtimes.deinit(allocator);
        client.events.deinit(allocator);
        client.session_ids.deinit(allocator);
    }
    var runtime = try SessionExtensionRuntime.init(
        allocator,
        "ui-session",
        session_types.CreateSessionConfig{},
        &.{},
    );
    runtime.capabilities.elicitation = .supported;
    try client.extension_runtimes.append(allocator, runtime);

    const ui = (Session{ .client = &client, .id = "ui-session" }).ui();
    try std.testing.expect(try ui.confirm("Proceed?"));
    const selected = (try ui.select("Choose", &.{ "one", "two" })).?;
    defer allocator.free(selected);
    try std.testing.expectEqualStrings("two", selected);
    const input = (try ui.input("Value", .{
        .title = "Name",
        .description = "Enter a name",
        .min_length = 1,
        .max_length = 20,
        .format = .email,
        .default = "a@example.com",
    })).?;
    defer allocator.free(input);
    try std.testing.expectEqualStrings("hello@example.com", input);

    try writer.interface.flush();
    const requests = try tmp.dir.readFileAlloc(
        std.testing.io,
        "requests",
        allocator,
        .limited(64 * 1024),
    );
    defer allocator.free(requests);
    var request_reader = std.Io.Reader.fixed(requests);
    const confirm_body = try json_rpc.readFrame(allocator, &request_reader);
    defer allocator.free(confirm_body);
    const select_body = try json_rpc.readFrame(allocator, &request_reader);
    defer allocator.free(select_body);
    const input_body = try json_rpc.readFrame(allocator, &request_reader);
    defer allocator.free(input_body);

    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"method":"session.ui.elicitation","params":{"sessionId":"ui-session","message":"Proceed?","requestedSchema":{"type":"object","properties":{"confirmed":{"type":"boolean","default":true}},"required":["confirmed"]}}}
    , confirm_body);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":2,"method":"session.ui.elicitation","params":{"sessionId":"ui-session","message":"Choose","requestedSchema":{"type":"object","properties":{"selection":{"type":"string","enum":["one","two"]}},"required":["selection"]}}}
    , select_body);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":3,"method":"session.ui.elicitation","params":{"sessionId":"ui-session","message":"Value","requestedSchema":{"type":"object","properties":{"value":{"type":"string","title":"Name","description":"Enter a name","minLength":1,"maxLength":20,"format":"email","default":"a@example.com"}},"required":["value"]}}}
    , input_body);
}

test "session UI rejects invalid defaults before RPC and invalid returned values" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":{"action":"accept","content":{"value":"not-an-email"}}}
    ;
    const responses = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}",
        .{ response.len, response },
    );
    defer allocator.free(responses);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = responses });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{ .mode = .read_only });
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
        .writer_buffer = &.{},
    };
    defer {
        for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
        client.extension_runtimes.deinit(allocator);
    }
    var runtime = try SessionExtensionRuntime.init(
        allocator,
        "ui-session",
        session_types.CreateSessionConfig{},
        &.{},
    );
    runtime.capabilities.elicitation = .supported;
    try client.extension_runtimes.append(allocator, runtime);
    const ui = (Session{ .client = &client, .id = "ui-session" }).ui();

    try std.testing.expectError(
        error.InvalidElicitationSchema,
        ui.input("Email", .{
            .format = .email,
            .default = "not-an-email",
        }),
    );
    try std.testing.expectError(
        error.InvalidElicitationResult,
        ui.input("Email", .{ .format = .email }),
    );

    try writer.interface.flush();
    const requests = try tmp.dir.readFileAlloc(
        std.testing.io,
        "requests",
        allocator,
        .limited(4096),
    );
    defer allocator.free(requests);
    var request_reader = std.Io.Reader.fixed(requests);
    const body = try json_rpc.readFrame(allocator, &request_reader);
    defer allocator.free(body);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"method":"session.ui.elicitation","params":{"sessionId":"ui-session","message":"Email","requestedSchema":{"type":"object","properties":{"value":{"type":"string","format":"email"}},"required":["value"]}}}
    , body);
}

test "command and elicitation events resolve on receipt without nextEvent" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const response_body =
        "Content-Length: 50\r\n\r\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"success\":true}}" ++
        "Content-Length: 50\r\n\r\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"success\":true}}";
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "responses",
        .data = response_body,
    });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{ .mode = .read_only });
    defer response_file.close(std.testing.io);
    var reader_buffer: [2048]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
    const request_file = try tmp.dir.createFile(std.testing.io, "requests", .{});
    defer request_file.close(std.testing.io);
    var writer_buffer: [4096]u8 = undefined;
    var writer = request_file.writer(std.testing.io, &writer_buffer);

    const HandlerState = struct {
        command_called: bool = false,
        elicitation_called: bool = false,
    };
    var state = HandlerState{};
    const command_handler = struct {
        fn handle(
            request: session_types.CommandContext,
            context: ?*anyopaque,
        ) !void {
            const handler_state: *HandlerState = @ptrCast(@alignCast(context.?));
            try std.testing.expectEqualStrings("events", request.session_id);
            try std.testing.expectEqualStrings("/ship now", request.command);
            try std.testing.expectEqualStrings("ship", request.command_name);
            try std.testing.expectEqualStrings("now", request.args);
            handler_state.command_called = true;
        }
    }.handle;
    const elicitation_handler = struct {
        fn handle(
            inner_allocator: std.mem.Allocator,
            request: session_types.ElicitationRequest,
            context: ?*anyopaque,
        ) !session_types.ElicitationResult {
            const handler_state: *HandlerState = @ptrCast(@alignCast(context.?));
            try std.testing.expectEqualStrings("events", request.session_id);
            try std.testing.expectEqualStrings("Pick", request.message);
            try std.testing.expectEqualStrings(
                "{\"type\":\"object\",\"properties\":{\"answer\":{\"type\":\"string\"}}}",
                request.requested_schema_json.?,
            );
            handler_state.elicitation_called = true;
            return .{
                .action = .accept,
                .content_json = try inner_allocator.dupe(u8, "{\"answer\":\"ok\"}"),
            };
        }
    }.handle;

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
        for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
        client.extension_runtimes.deinit(allocator);
        client.session_ids.deinit(allocator);
    }
    const commands = [_]session_types.CommandDefinition{.{
        .name = "ship",
        .handler = command_handler,
        .context = &state,
    }};
    const runtime = try SessionExtensionRuntime.init(allocator, "events", session_types.CreateSessionConfig{
        .commands = &commands,
        .on_elicitation_request = elicitation_handler,
        .elicitation_context = &state,
    }, &.{});
    try client.extension_runtimes.append(allocator, runtime);

    const command_json = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"sessionId":"events","event":{"type":"command.execute","data":{"requestId":"command-1","command":"/ship now","commandName":"ship","args":"now"}}}
    ,
        .{},
    );
    defer command_json.deinit();
    try client.queueSessionEvent(command_json.value);
    const elicitation_json = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"sessionId":"events","event":{"type":"elicitation.requested","data":{"requestId":"elicit-1","message":"Pick","mode":"form","requestedSchema":{"type":"object","properties":{"answer":{"type":"string"}}}}}}
    ,
        .{},
    );
    defer elicitation_json.deinit();
    try client.queueSessionEvent(elicitation_json.value);
    try std.testing.expect(state.command_called);
    try std.testing.expect(state.elicitation_called);
    try std.testing.expectEqual(@as(usize, 2), client.events.items.len);
    try std.testing.expect(
        client.events.items[0].event.command_execute.automatic_handling == .handled,
    );
    try std.testing.expect(
        client.events.items[1].event.elicitation_requested.automatic_handling == .handled,
    );

    const session = Session{ .client = &client, .id = "events" };
    var command_event = try session.nextEvent();
    defer command_event.deinit(allocator);
    var elicitation_event = try session.nextEvent();
    defer elicitation_event.deinit(allocator);
    try std.testing.expect(command_event.command_execute.automatic_handling == .handled);
    try std.testing.expect(elicitation_event.elicitation_requested.automatic_handling == .handled);

    try writer.interface.flush();
    const requests = try tmp.dir.readFileAlloc(
        std.testing.io,
        "requests",
        allocator,
        .limited(16 * 1024),
    );
    defer allocator.free(requests);
    var request_reader = std.Io.Reader.fixed(requests);
    const command_body = try json_rpc.readFrame(allocator, &request_reader);
    defer allocator.free(command_body);
    const elicitation_body = try json_rpc.readFrame(allocator, &request_reader);
    defer allocator.free(elicitation_body);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"method":"session.commands.handlePendingCommand","params":{"sessionId":"events","requestId":"command-1"}}
    , command_body);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":2,"method":"session.ui.handlePendingElicitation","params":{"sessionId":"events","requestId":"elicit-1","result":{"action":"accept","content":{"answer":"ok"}}}}
    , elicitation_body);
}

test "immediate command delivery buffers an interleaved outer response" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const event_frame =
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"events","event":{"type":"command.execute","data":{"requestId":"command-1","command":"/ship","commandName":"ship","args":""}}}}
    ;
    const nested_event =
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"events","event":{"type":"assistant.message","data":{"content":"nested","messageId":"m1"}}}}
    ;
    const outer_response =
        \\{"jsonrpc":"2.0","id":1,"result":{"value":"outer"}}
    ;
    const command_response =
        \\{"jsonrpc":"2.0","id":2,"result":{"success":true}}
    ;
    const responses = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}",
        .{
            event_frame.len,
            event_frame,
            nested_event.len,
            nested_event,
            outer_response.len,
            outer_response,
            command_response.len,
            command_response,
        },
    );
    defer allocator.free(responses);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = responses });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{ .mode = .read_only });
    defer response_file.close(std.testing.io);
    var reader_buffer: [4096]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
    const request_file = try tmp.dir.createFile(std.testing.io, "requests", .{});
    defer request_file.close(std.testing.io);
    var writer_buffer: [4096]u8 = undefined;
    var writer = request_file.writer(std.testing.io, &writer_buffer);

    var called = false;
    const handler = struct {
        fn handle(_: session_types.CommandContext, context: ?*anyopaque) !void {
            const did_call: *bool = @ptrCast(@alignCast(context.?));
            did_call.* = true;
        }
    }.handle;
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
        for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
        client.extension_runtimes.deinit(allocator);
        for (client.buffered_responses.items) |*response| response.deinit(allocator);
        client.buffered_responses.deinit(allocator);
    }
    try client.extension_runtimes.append(
        allocator,
        try SessionExtensionRuntime.init(allocator, "events", session_types.CreateSessionConfig{
            .commands = &.{.{
                .name = "ship",
                .handler = handler,
                .context = &called,
            }},
        }, &.{}),
    );

    const parsed = try client.callRpc(
        struct { value: []const u8 },
        "test.outer",
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings("outer", parsed.value.value);
    try std.testing.expect(called);
    try std.testing.expectEqual(@as(usize, 2), client.events.items.len);
    try std.testing.expect(
        client.events.items[0].event.command_execute.automatic_handling == .handled,
    );
    try std.testing.expectEqualStrings(
        "nested",
        client.events.items[1].event.assistant_message.content,
    );
    try std.testing.expectEqual(@as(usize, 0), client.buffered_responses.items.len);

    try writer.interface.flush();
    const requests = try tmp.dir.readFileAlloc(
        std.testing.io,
        "requests",
        allocator,
        .limited(16 * 1024),
    );
    defer allocator.free(requests);
    var request_reader = std.Io.Reader.fixed(requests);
    const outer_body = try json_rpc.readFrame(allocator, &request_reader);
    defer allocator.free(outer_body);
    const command_body = try json_rpc.readFrame(allocator, &request_reader);
    defer allocator.free(command_body);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"method":"test.outer","params":[]}
    , outer_body);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":2,"method":"session.commands.handlePendingCommand","params":{"sessionId":"events","requestId":"command-1"}}
    , command_body);
}

test "an immediate handler cannot consume or invalidate its own event" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const command_event =
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"events","event":{"type":"command.execute","data":{"requestId":"command-1","command":"/ship","commandName":"ship","args":""}}}}
    ;
    const outer_response =
        \\{"jsonrpc":"2.0","id":1,"result":{"value":"outer"}}
    ;
    const nested_event =
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"events","event":{"type":"assistant.message","data":{"content":"nested","messageId":"m1"}}}}
    ;
    const command_response =
        \\{"jsonrpc":"2.0","id":2,"result":{"success":true}}
    ;
    const responses = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}",
        .{
            command_event.len,
            command_event,
            outer_response.len,
            outer_response,
            nested_event.len,
            nested_event,
            command_response.len,
            command_response,
        },
    );
    defer allocator.free(responses);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = responses });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{ .mode = .read_only });
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
        for (client.events.items) |*queued| queued.deinit(allocator);
        client.events.deinit(allocator);
        for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
        client.extension_runtimes.deinit(allocator);
        for (client.buffered_responses.items) |*response| response.deinit(allocator);
        client.buffered_responses.deinit(allocator);
    }
    const HandlerState = struct {
        session: Session,
        allocator: std.mem.Allocator,
        observed_nested_event: bool = false,
    };
    var state = HandlerState{
        .session = .{ .client = &client, .id = "events" },
        .allocator = allocator,
    };
    const handler = struct {
        fn handle(_: session_types.CommandContext, context: ?*anyopaque) !void {
            const handler_state: *HandlerState = @ptrCast(@alignCast(context.?));
            var event = try handler_state.session.nextEvent();
            defer event.deinit(handler_state.allocator);
            try std.testing.expectEqualStrings(
                "nested",
                event.assistant_message.content,
            );
            handler_state.observed_nested_event = true;
        }
    }.handle;
    try client.extension_runtimes.append(
        allocator,
        try SessionExtensionRuntime.init(
            allocator,
            "events",
            session_types.CreateSessionConfig{
                .commands = &.{.{
                    .name = "ship",
                    .handler = handler,
                    .context = &state,
                }},
            },
            &.{},
        ),
    );

    const outer = try client.callRpc(
        struct { value: []const u8 },
        "test.outer",
        .{},
    );
    defer outer.deinit();

    try std.testing.expectEqualStrings("outer", outer.value.value);
    try std.testing.expect(state.observed_nested_event);
    try std.testing.expectEqual(@as(usize, 1), client.events.items.len);
    try std.testing.expect(
        client.events.items[0].event.command_execute.automatic_handling == .handled,
    );
    try std.testing.expectEqual(@as(usize, 0), client.buffered_responses.items.len);
}

test "elicitation handler failures remain typed and never become cancellation" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = "" });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{ .mode = .read_only });
    defer response_file.close(std.testing.io);
    var reader_buffer: [128]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
    const request_file = try tmp.dir.createFile(std.testing.io, "requests", .{});
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
    defer {
        for (client.events.items) |*queued| queued.deinit(allocator);
        client.events.deinit(allocator);
        for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
        client.extension_runtimes.deinit(allocator);
    }
    const handler = struct {
        fn handle(
            _: std.mem.Allocator,
            request: session_types.ElicitationRequest,
            _: ?*anyopaque,
        ) !session_types.ElicitationResult {
            if (std.mem.eql(u8, request.message, "fail")) return error.HandlerFailed;
            return .{
                .action = .accept,
                .content_json = try std.testing.allocator.dupe(u8, "[]"),
            };
        }
    }.handle;
    try client.extension_runtimes.append(
        allocator,
        try SessionExtensionRuntime.init(allocator, "events", session_types.CreateSessionConfig{
            .on_elicitation_request = handler,
        }, &.{}),
    );

    const failed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"sessionId":"events","event":{"type":"elicitation.requested","data":{"requestId":"failure","message":"fail"}}}
    ,
        .{},
    );
    defer failed.deinit();
    try client.queueSessionEvent(failed.value);
    switch (client.events.items[0].event.elicitation_requested.automatic_handling) {
        .handler_failed => |err| try std.testing.expectEqual(error.HandlerFailed, err),
        else => return error.TestUnexpectedResult,
    }

    const malformed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"sessionId":"events","event":{"type":"elicitation.requested","data":{"requestId":"malformed","message":"malformed"}}}
    ,
        .{},
    );
    defer malformed.deinit();
    try client.queueSessionEvent(malformed.value);
    try std.testing.expect(
        client.events.items[1].event.elicitation_requested.automatic_handling ==
            .invalid_result,
    );
    try writer.interface.flush();
    const requests = try tmp.dir.readFileAlloc(
        std.testing.io,
        "requests",
        allocator,
        .limited(1024),
    );
    defer allocator.free(requests);
    try std.testing.expectEqual(@as(usize, 0), requests.len);
}

test "exit plan and auto mode callbacks validate and lower exact responses" {
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
    var exit_called = false;
    var auto_called = false;
    const exit_handler = struct {
        fn handle(
            request: session_types.ExitPlanModeRequest,
            context: ?*anyopaque,
        ) !session_types.ExitPlanModeResult {
            const called: *bool = @ptrCast(@alignCast(context.?));
            try std.testing.expectEqualStrings("callbacks", request.session_id);
            try std.testing.expectEqualStrings("Plan", request.summary);
            try std.testing.expectEqualStrings("Do it", request.plan_content.?);
            try std.testing.expectEqual(@as(usize, 2), request.actions.len);
            try std.testing.expectEqual(session_types.ExitPlanModeAction.autopilot, request.recommended_action);
            called.* = true;
            return .{
                .approved = true,
                .selected_action = .interactive,
                .feedback = "Looks good",
            };
        }
    }.handle;
    const auto_handler = struct {
        fn handle(
            request: session_types.AutoModeSwitchRequest,
            context: ?*anyopaque,
        ) !session_types.AutoModeSwitchResponse {
            const called: *bool = @ptrCast(@alignCast(context.?));
            try std.testing.expectEqualStrings("callbacks", request.session_id);
            try std.testing.expectEqualStrings("rate_limit", request.error_code.?);
            try std.testing.expectEqual(@as(u64, 12), request.retry_after_seconds.?);
            called.* = true;
            return .yes_always;
        }
    }.handle;
    const runtime = try SessionExtensionRuntime.init(allocator, "callbacks", session_types.CreateSessionConfig{
        .on_exit_plan_mode_request = exit_handler,
        .exit_plan_mode_context = &exit_called,
        .on_auto_mode_switch_request = auto_handler,
        .auto_mode_switch_context = &auto_called,
    }, &.{});
    try client.extension_runtimes.append(allocator, runtime);

    const exit_params = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"sessionId":"callbacks","summary":"Plan","planContent":"Do it","actions":["interactive","autopilot"],"recommendedAction":"autopilot"}
    ,
        .{},
    );
    defer exit_params.deinit();
    var exit_output: std.Io.Writer.Allocating = .init(allocator);
    defer exit_output.deinit();
    try client.dispatchServerRequest(
        &exit_output.writer,
        .{ .integer = 1 },
        "exitPlanMode.request",
        exit_params.value,
    );
    const exit_body = try framedBody(allocator, exit_output.written());
    defer allocator.free(exit_body);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"result":{"approved":true,"selectedAction":"interactive","feedback":"Looks good"}}
    , exit_body);
    try std.testing.expect(exit_called);

    const auto_params = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"sessionId":"callbacks","errorCode":"rate_limit","retryAfterSeconds":12}
    ,
        .{},
    );
    defer auto_params.deinit();
    var auto_output: std.Io.Writer.Allocating = .init(allocator);
    defer auto_output.deinit();
    try client.dispatchServerRequest(
        &auto_output.writer,
        .{ .integer = 2 },
        "autoModeSwitch.request",
        auto_params.value,
    );
    const auto_body = try framedBody(allocator, auto_output.written());
    defer allocator.free(auto_body);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":2,"result":{"response":"yes_always"}}
    , auto_body);
    try std.testing.expect(auto_called);

    const invalid_exit_params = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"sessionId":"callbacks","summary":"Plan","actions":["future"],"recommendedAction":"future"}
    ,
        .{},
    );
    defer invalid_exit_params.deinit();
    var invalid_output: std.Io.Writer.Allocating = .init(allocator);
    defer invalid_output.deinit();
    try client.dispatchServerRequest(
        &invalid_output.writer,
        .{ .integer = 3 },
        "exitPlanMode.request",
        invalid_exit_params.value,
    );
    try std.testing.expectEqual(
        @as(i64, -32602),
        try responseErrorCode(allocator, invalid_output.written()),
    );
}

test "cloud create lowers stable session fields and adopts the server id" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const create_response =
        \\{"jsonrpc":"2.0","id":1,"result":{"sessionId":"cloud-id","capabilities":{"ui":{"elicitation":true}}}}
    ;
    const update_response =
        \\{"jsonrpc":"2.0","id":2,"result":{"success":true}}
    ;
    const responses = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}",
        .{ create_response.len, create_response, update_response.len, update_response },
    );
    defer allocator.free(responses);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = responses });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{ .mode = .read_only });
    defer response_file.close(std.testing.io);
    var reader_buffer: [4096]u8 = undefined;
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
    defer {
        for (client.session_ids.items) |id| allocator.free(id);
        client.session_ids.deinit(allocator);
        for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
        client.extension_runtimes.deinit(allocator);
    }

    const command_handler = struct {
        fn handle(_: session_types.CommandContext, _: ?*anyopaque) !void {}
    }.handle;
    const elicitation_handler = struct {
        fn handle(
            inner_allocator: std.mem.Allocator,
            _: session_types.ElicitationRequest,
            _: ?*anyopaque,
        ) !session_types.ElicitationResult {
            return .{
                .action = .cancel,
                .content_json = try inner_allocator.dupe(u8, "{}"),
            };
        }
    }.handle;
    const exit_handler = struct {
        fn handle(
            _: session_types.ExitPlanModeRequest,
            _: ?*anyopaque,
        ) !session_types.ExitPlanModeResult {
            return .{ .approved = true };
        }
    }.handle;
    const auto_handler = struct {
        fn handle(
            _: session_types.AutoModeSwitchRequest,
            _: ?*anyopaque,
        ) !session_types.AutoModeSwitchResponse {
            return .no;
        }
    }.handle;
    const exp_parameters = [_]session_types.ExpParameter{
        .{ .name = "enabled", .value = .{ .boolean = true } },
        .{ .name = "count", .value = .{ .number = 2 } },
        .{ .name = "ratio", .value = .{ .number = 1.5 } },
        .{ .name = "label", .value = .{ .string = "x" } },
        .{ .name = "empty", .value = .null },
    };
    const exp_configs = [_]session_types.ExpConfigEntry{.{
        .id = "config",
        .parameters = &exp_parameters,
    }};
    const exp_assignments = session_types.CopilotExpAssignmentResponse{
        .features = &.{"flight"},
        .flights = &.{.{ .name = "flight", .value = "treatment" }},
        .configs = &exp_configs,
        .flighting_version = 2.5,
        .impression_id = "impression",
        .assignment_context = "context",
    };

    const created = try client.createSession(.{
        .cloud = .{ .repository = .{
            .owner = "github",
            .name = "copilot-sdk",
            .branch = "main",
        } },
        .include_subagent_streaming_events = false,
        .commands = &.{.{
            .name = "ship",
            .description = "Ship it",
            .handler = command_handler,
        }},
        .tool_search = .{ .enabled = true, .defer_threshold = 7 },
        .enable_session_telemetry = true,
        .enable_file_change_tracking = true,
        .coauthor_enabled = false,
        .manage_schedule_enabled = true,
        .ask_user_variant = .elicitation,
        .on_elicitation_request = elicitation_handler,
        .github_mcp_tool_config = .{
            .enable_all_tools = false,
            .additional_toolsets = &.{"repos"},
            .additional_tools = &.{"get_file"},
            .enable_insiders_mode = true,
            .disable_form_deferral = true,
        },
        .on_exit_plan_mode_request = exit_handler,
        .on_auto_mode_switch_request = auto_handler,
        .git_hub_token = "static-secret",
        .remote_session = .@"export",
        .feature_flags = &.{
            .{ .name = "alpha", .enabled = true },
            .{ .name = "beta", .enabled = false },
        },
        .exp_assignments = exp_assignments,
    });
    try std.testing.expectEqualStrings("cloud-id", created.id);
    try std.testing.expect(created.capabilities().supports(.elicitation));

    try writer.interface.flush();
    const requests = try tmp.dir.readFileAlloc(
        std.testing.io,
        "requests",
        allocator,
        .limited(32 * 1024),
    );
    defer allocator.free(requests);
    var frames = std.Io.Reader.fixed(requests);
    const create_body = try json_rpc.readFrame(allocator, &frames);
    defer {
        wipeSecret(create_body);
        allocator.free(create_body);
    }
    const update_body = try json_rpc.readFrame(allocator, &frames);
    defer allocator.free(update_body);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"method":"session.create","params":{"streaming":false,"includeSubAgentStreamingEvents":false,"tools":[],"commands":[{"name":"ship","description":"Ship it"}],"toolSearch":{"enabled":true,"deferThreshold":7},"toolFilterPrecedence":"excluded","enableSessionTelemetry":true,"enableFileChangeTracking":true,"requestPermission":false,"requestUserInput":false,"requestElicitation":true,"askUserVariant":"elicitation","githubMcpToolConfig":{"enableAllTools":false,"additionalToolsets":["repos"],"additionalTools":["get_file"],"enableInsidersMode":true,"disableFormDeferral":true},"requestExitPlanMode":true,"requestAutoModeSwitch":true,"enableManagedSettings":false,"gitHubToken":"static-secret","remoteSession":"export","cloud":{"repository":{"owner":"github","name":"copilot-sdk","branch":"main"}},"featureFlags":{"alpha":true,"beta":false},"expAssignments":{"Features":["flight"],"Flights":{"flight":"treatment"},"Configs":[{"Id":"config","Parameters":{"enabled":true,"count":2,"ratio":1.5,"label":"x","empty":null}}],"FlightingVersion":2.5,"ImpressionId":"impression","AssignmentContext":"context"}}}
    , create_body);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":2,"method":"session.options.update","params":{"sessionId":"cloud-id","coauthorEnabled":false,"manageScheduleEnabled":true}}
    , update_body);
    try validateLifecycleConfig(session_types.CreateSessionConfig{
        .session_id = "caller",
        .cloud = .{},
    });
    try std.testing.expectError(
        error.ConflictingGitHubAuthentication,
        validateLifecycleConfig(session_types.CreateSessionConfig{
            .git_hub_token = "static",
            .git_hub_token_provider = .{
                .callback = testGitHubTokenProvider,
            },
        }),
    );
}

test "cloud create preserves a caller session id and rolls back mismatches" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const matching_response =
        \\{"jsonrpc":"2.0","id":1,"result":{"sessionId":"caller-cloud"}}
    ;
    const mismatch_response =
        \\{"jsonrpc":"2.0","id":2,"result":{"sessionId":"unexpected-cloud"}}
    ;
    const detach_response =
        \\{"jsonrpc":"2.0","id":3,"result":{"success":true}}
    ;
    const responses = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}",
        .{
            matching_response.len,
            matching_response,
            mismatch_response.len,
            mismatch_response,
            detach_response.len,
            detach_response,
        },
    );
    defer allocator.free(responses);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = responses });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{ .mode = .read_only });
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
    defer {
        client.rollbackExtensionRuntime();
        for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
        client.extension_runtimes.deinit(allocator);
        for (client.session_ids.items) |id| allocator.free(id);
        client.session_ids.deinit(allocator);
    }

    const created = try client.createSession(.{
        .session_id = "caller-cloud",
        .cloud = .{},
    });
    try std.testing.expectEqualStrings("caller-cloud", created.id);
    try std.testing.expectError(
        error.SessionIdMismatch,
        client.createSession(.{
            .session_id = "second-cloud",
            .cloud = .{},
        }),
    );
    try std.testing.expect(client.findSessionId("caller-cloud") != null);
    try std.testing.expect(client.findSessionId("second-cloud") == null);
    try std.testing.expect(client.findExtensionRuntime("second-cloud") == null);

    try writer.interface.flush();
    const requests = try tmp.dir.readFileAlloc(
        std.testing.io,
        "requests",
        allocator,
        .limited(16 * 1024),
    );
    defer allocator.free(requests);
    var request_reader = std.Io.Reader.fixed(requests);
    const matching_body = try json_rpc.readFrame(allocator, &request_reader);
    defer allocator.free(matching_body);
    const mismatch_body = try json_rpc.readFrame(allocator, &request_reader);
    defer allocator.free(mismatch_body);
    const detach_body = try json_rpc.readFrame(allocator, &request_reader);
    defer allocator.free(detach_body);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"method":"session.create","params":{"sessionId":"caller-cloud","streaming":false,"includeSubAgentStreamingEvents":true,"tools":[],"toolFilterPrecedence":"excluded","requestPermission":false,"requestUserInput":false,"requestElicitation":false,"requestExitPlanMode":false,"requestAutoModeSwitch":false,"enableManagedSettings":false,"cloud":{}}}
    , matching_body);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":2,"method":"session.create","params":{"sessionId":"second-cloud","streaming":false,"includeSubAgentStreamingEvents":true,"tools":[],"toolFilterPrecedence":"excluded","requestPermission":false,"requestUserInput":false,"requestElicitation":false,"requestExitPlanMode":false,"requestAutoModeSwitch":false,"enableManagedSettings":false,"cloud":{}}}
    , mismatch_body);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":3,"method":"session.detach","params":{"sessionId":"unexpected-cloud"}}
    , detach_body);
}

test "known-id create detaches after a malformed lifecycle result" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const malformed_response =
        \\{"jsonrpc":"2.0","id":1,"result":[]}
    ;
    const detach_response =
        \\{"jsonrpc":"2.0","id":2,"result":{"success":true}}
    ;
    const responses = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}",
        .{
            malformed_response.len,
            malformed_response,
            detach_response.len,
            detach_response,
        },
    );
    defer allocator.free(responses);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = responses });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{ .mode = .read_only });
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
        .writer_buffer = &.{},
    };
    defer {
        for (client.session_ids.items) |id| allocator.free(id);
        client.session_ids.deinit(allocator);
        for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
        client.extension_runtimes.deinit(allocator);
    }

    var failed = false;
    _ = client.createSession(.{
        .cloud = .{},
        .session_id = "known",
    }) catch {
        failed = true;
    };
    try std.testing.expect(failed);
    try std.testing.expectEqual(@as(usize, 0), client.session_ids.items.len);
    try writer.interface.flush();
    const requests = try tmp.dir.readFileAlloc(
        std.testing.io,
        "requests",
        allocator,
        .limited(4096),
    );
    defer allocator.free(requests);
    var frames = std.Io.Reader.fixed(requests);
    const create_body = try json_rpc.readFrame(allocator, &frames);
    defer allocator.free(create_body);
    const detach_body = try json_rpc.readFrame(allocator, &frames);
    defer allocator.free(detach_body);
    try std.testing.expect(std.mem.indexOf(
        u8,
        detach_body,
        "\"method\":\"session.detach\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        detach_body,
        "\"sessionId\":\"known\"",
    ) != null);
}

test "ExP assignment lowering rejects duplicate record keys" {
    const allocator = std.testing.allocator;
    var values = ExtensionWireValues.init(allocator);
    defer values.deinit();
    try std.testing.expectError(
        error.InvalidExpAssignments,
        values.lowerHostInjection(null, .{
            .features = &.{},
            .flights = &.{
                .{ .name = "duplicate", .value = "first" },
                .{ .name = "duplicate", .value = "second" },
            },
            .configs = &.{},
            .assignment_context = "context",
        }),
    );

    var parameter_values = ExtensionWireValues.init(allocator);
    defer parameter_values.deinit();
    try std.testing.expectError(
        error.InvalidExpAssignments,
        parameter_values.lowerHostInjection(null, .{
            .features = &.{},
            .flights = &.{},
            .configs = &.{.{
                .id = "config",
                .parameters = &.{
                    .{ .name = "duplicate", .value = .{ .boolean = true } },
                    .{ .name = "duplicate", .value = .{ .boolean = false } },
                },
            }},
            .assignment_context = "context",
        }),
    );

    var non_finite_values = ExtensionWireValues.init(allocator);
    defer non_finite_values.deinit();
    try std.testing.expectError(
        error.InvalidExpAssignments,
        non_finite_values.lowerHostInjection(null, .{
            .features = &.{},
            .flights = &.{},
            .configs = &.{.{
                .id = "config",
                .parameters = &.{.{
                    .name = "invalid",
                    .value = .{ .number = std.math.nan(f64) },
                }},
            }},
            .assignment_context = "context",
        }),
    );
}

test "post-response lifecycle failure detaches creates and quarantines resumed credentials" {
    const allocator = std.testing.allocator;
    const command_handler = struct {
        fn handle(_: session_types.CommandContext, _: ?*anyopaque) !void {}
    }.handle;

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const create_response =
            \\{"jsonrpc":"2.0","id":1,"result":{"sessionId":"new-session"}}
        ;
        const update_response =
            \\{"jsonrpc":"2.0","id":2,"result":{"success":false}}
        ;
        const detach_response =
            \\{"jsonrpc":"2.0","id":3,"result":{"success":true}}
        ;
        const token_request =
            \\{"jsonrpc":"2.0","id":77,"method":"providerToken.getToken","params":{"sessionId":"new-session","providerName":"model-provider"}}
        ;
        const oauth_event =
            \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"new-session","event":{"type":"mcp.oauth_required","data":{"requestId":"oauth-1","serverName":"server","serverUrl":"https://example.test","reason":"initial"}}}}
        ;
        const responses = try std.fmt.allocPrint(
            allocator,
            "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}",
            .{
                create_response.len,
                create_response,
                update_response.len,
                update_response,
                token_request.len,
                token_request,
                oauth_event.len,
                oauth_event,
                detach_response.len,
                detach_response,
            },
        );
        defer allocator.free(responses);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = responses });
        const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{ .mode = .read_only });
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
            .writer_buffer = &.{},
        };
        defer {
            for (client.session_ids.items) |id| allocator.free(id);
            client.session_ids.deinit(allocator);
            for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
            client.extension_runtimes.deinit(allocator);
            for (client.events.items) |*event| event.deinit(allocator);
            client.events.deinit(allocator);
        }
        var model_state = ProviderTokenTestContext{
            .token = "model-token",
            .expected_session_id = "new-session",
            .expected_provider_name = "model-provider",
        };
        const McpState = struct {
            calls: usize = 0,
        };
        var mcp_state = McpState{};
        const mcp_handler = struct {
            fn handle(
                _: std.mem.Allocator,
                _: ext.McpAuthRequest,
                context: ?*anyopaque,
            ) !ext.McpAuthResult {
                const state: *McpState = @ptrCast(@alignCast(context.?));
                state.calls += 1;
                return error.UnexpectedMcpAuthCallback;
            }
        }.handle;

        try std.testing.expectError(
            error.SessionOptionsNotAccepted,
            client.createSession(.{
                .cloud = .{},
                .coauthor_enabled = true,
                .extensions = .{ .common = .{ .mcp = .{
                    .on_auth_request = mcp_handler,
                    .auth_context = &mcp_state,
                } } },
                .provider = .{
                    .base_url = "https://example.test",
                    .provider_name = "model-provider",
                    .bearer_token_provider = .{
                        .callback = providerTokenTestCallback,
                        .context = &model_state,
                    },
                },
            }),
        );
        try std.testing.expectEqual(@as(usize, 0), client.session_ids.items.len);
        try std.testing.expectEqual(@as(usize, 0), client.extension_runtimes.items.len);
        try std.testing.expectEqual(@as(usize, 0), model_state.calls);
        try std.testing.expectEqual(@as(usize, 0), mcp_state.calls);
        try std.testing.expectEqual(@as(usize, 1), client.events.items.len);
        try std.testing.expect(
            client.events.items[0].event.mcp_oauth_required.automatic_handling ==
                .not_configured,
        );
        try writer.interface.flush();
        const requests = try tmp.dir.readFileAlloc(
            std.testing.io,
            "requests",
            allocator,
            .limited(16 * 1024),
        );
        defer allocator.free(requests);
        var frames = std.Io.Reader.fixed(requests);
        const create_body = try json_rpc.readFrame(allocator, &frames);
        defer allocator.free(create_body);
        const update_body = try json_rpc.readFrame(allocator, &frames);
        defer allocator.free(update_body);
        const detach_body = try json_rpc.readFrame(allocator, &frames);
        defer allocator.free(detach_body);
        const token_body = try json_rpc.readFrame(allocator, &frames);
        defer allocator.free(token_body);
        try std.testing.expect(
            std.mem.indexOf(u8, detach_body, "\"method\":\"session.detach\"") != null,
        );
        try std.testing.expect(
            std.mem.indexOf(u8, detach_body, "\"sessionId\":\"new-session\"") != null,
        );
        try std.testing.expectEqualStrings(
            \\{"jsonrpc":"2.0","id":77,"error":{"code":-32000,"message":"bearer token provider not registered"}}
        , token_body);
    }

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const resume_response =
            \\{"jsonrpc":"2.0","id":1,"result":{"sessionId":"resident"}}
        ;
        const update_response =
            \\{"jsonrpc":"2.0","id":2,"result":{"success":false}}
        ;
        const responses = try std.fmt.allocPrint(
            allocator,
            "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}",
            .{ resume_response.len, resume_response, update_response.len, update_response },
        );
        defer allocator.free(responses);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = responses });
        const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{ .mode = .read_only });
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
            .writer_buffer = &.{},
        };
        defer {
            for (client.session_ids.items) |id| allocator.free(id);
            client.session_ids.deinit(allocator);
            for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
            client.extension_runtimes.deinit(allocator);
        }
        try client.session_ids.append(allocator, try allocator.dupe(u8, "resident"));
        var old_github_state = TestGitHubTokenState{};
        var new_github_state = TestGitHubTokenState{};
        var old_model_state = ProviderTokenTestContext{
            .token = "old-model-token",
            .expected_session_id = "resident",
            .expected_provider_name = "model-provider",
        };
        var new_model_state = ProviderTokenTestContext{
            .token = "new-model-token",
            .expected_session_id = "resident",
            .expected_provider_name = "model-provider",
        };
        const old_commands = [_]session_types.CommandDefinition{.{
            .name = "old",
            .handler = command_handler,
        }};
        try client.beginExtensionRuntime(
            "resident",
            session_types.ResumeSessionConfig{
                .commands = &old_commands,
                .git_hub_token_provider = .{
                    .callback = testGitHubTokenProvider,
                    .context = &old_github_state,
                },
            },
            &.{},
        );
        try client.installRuntimeProviderTokens(&.{.{
            .provider_name = "model-provider",
            .token_provider = .{
                .callback = providerTokenTestCallback,
                .context = &old_model_state,
            },
        }});
        client.pending_extension_runtime.?.git_hub_token_registration_id =
            try allocator.dupe(u8, "old-registration");
        try client.commitExtensionRuntime("resident", .{}, &.{});
        const new_commands = [_]session_types.CommandDefinition{.{
            .name = "new",
            .handler = command_handler,
        }};
        try std.testing.expectError(
            error.SessionOptionsNotAccepted,
            client.resumeSession("resident", .{
                .commands = &new_commands,
                .manage_schedule_enabled = true,
                .git_hub_token_provider = .{
                    .callback = testGitHubTokenProvider,
                    .context = &new_github_state,
                },
                .provider = .{
                    .base_url = "https://example.test",
                    .provider_name = "model-provider",
                    .bearer_token_provider = .{
                        .callback = providerTokenTestCallback,
                        .context = &new_model_state,
                    },
                },
            }),
        );
        try writer.interface.flush();
        const requests = try tmp.dir.readFileAlloc(
            std.testing.io,
            "requests",
            allocator,
            .limited(16 * 1024),
        );
        defer allocator.free(requests);
        var frames = std.Io.Reader.fixed(requests);
        const resume_body = try json_rpc.readFrame(allocator, &frames);
        defer allocator.free(resume_body);
        const resume_request = try std.json.parseFromSlice(std.json.Value, allocator, resume_body, .{});
        defer resume_request.deinit();
        const replacement_registration = resume_request.value.object
            .get("params").?.object
            .get("gitHubTokenProviderRegistrationId").?.string;
        const update_body = try json_rpc.readFrame(allocator, &frames);
        defer allocator.free(update_body);
        try std.testing.expectEqualStrings("", frames.buffered());

        const token_params_json = try std.fmt.allocPrint(
            allocator,
            "{{\"registrationId\":\"{s}\",\"host\":\"github.com\",\"sessionId\":\"resident\",\"reason\":\"refresh\"}}",
            .{replacement_registration},
        );
        defer allocator.free(token_params_json);
        const token_params = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            token_params_json,
            .{},
        );
        defer token_params.deinit();
        var token_output: std.Io.Writer.Allocating = .init(allocator);
        defer token_output.deinit();
        try client.dispatchServerRequest(
            &token_output.writer,
            .{ .integer = 3 },
            "gitHubToken.getToken",
            token_params.value,
        );
        try std.testing.expectEqual(@as(i64, -32602), try responseErrorCode(allocator, token_output.written()));
        try std.testing.expectEqual(@as(usize, 0), old_github_state.calls);
        try std.testing.expectEqual(@as(usize, 0), new_github_state.calls);

        const old_token_params = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            \\{"registrationId":"old-registration","host":"github.com","sessionId":"resident","reason":"refresh"}
        ,
            .{},
        );
        defer old_token_params.deinit();
        var old_token_output: std.Io.Writer.Allocating = .init(allocator);
        defer old_token_output.deinit();
        try client.dispatchServerRequest(
            &old_token_output.writer,
            .{ .integer = 4 },
            "gitHubToken.getToken",
            old_token_params.value,
        );
        try std.testing.expectEqual(@as(i64, -32602), try responseErrorCode(allocator, old_token_output.written()));
        try std.testing.expectEqual(@as(usize, 0), old_github_state.calls);

        const provider_params = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            \\{"sessionId":"resident","providerName":"model-provider"}
        ,
            .{},
        );
        defer provider_params.deinit();
        var provider_output: std.Io.Writer.Allocating = .init(allocator);
        defer provider_output.deinit();
        try client.dispatchServerRequest(
            &provider_output.writer,
            .{ .integer = 5 },
            "providerToken.getToken",
            provider_params.value,
        );
        try std.testing.expectEqual(@as(i64, -32000), try responseErrorCode(allocator, provider_output.written()));
        try std.testing.expectEqual(@as(usize, 0), old_model_state.calls);
        try std.testing.expectEqual(@as(usize, 0), new_model_state.calls);

        const resident = client.findExtensionRuntime("resident").?;
        try std.testing.expectEqual(@as(usize, 1), resident.commands.len);
        try std.testing.expectEqualStrings("old", resident.commands[0].name);
        try std.testing.expect(resident.credentials_quarantined);
        try std.testing.expect(client.findGitHubTokenRuntime("old-registration") == null);
        try std.testing.expect(client.findGitHubTokenRuntime(replacement_registration) == null);
    }
}

test "resident resume response failure quarantines old and replacement credentials" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const resume_response =
        \\{"jsonrpc":"2.0","id":1,"result":{"sessionId":"resident","grantedEnvironmentVariables":{"TOKEN":1}}}
    ;
    const responses = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}",
        .{ resume_response.len, resume_response },
    );
    defer allocator.free(responses);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = responses });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{ .mode = .read_only });
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
        .writer_buffer = &.{},
    };
    defer {
        for (client.session_ids.items) |id| allocator.free(id);
        client.session_ids.deinit(allocator);
        for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
        client.extension_runtimes.deinit(allocator);
    }

    try client.session_ids.append(allocator, try allocator.dupe(u8, "resident"));
    var old_github_state = TestGitHubTokenState{};
    var old_model_state = ProviderTokenTestContext{
        .token = "old-model-token",
        .expected_session_id = "resident",
        .expected_provider_name = "model-provider",
    };
    try client.beginExtensionRuntime(
        "resident",
        session_types.ResumeSessionConfig{
            .git_hub_token_provider = .{
                .callback = testGitHubTokenProvider,
                .context = &old_github_state,
            },
        },
        &.{},
    );
    try client.installRuntimeProviderTokens(&.{.{
        .provider_name = "model-provider",
        .token_provider = .{
            .callback = providerTokenTestCallback,
            .context = &old_model_state,
        },
    }});
    client.pending_extension_runtime.?.git_hub_token_registration_id =
        try allocator.dupe(u8, "old-registration");
    try client.commitExtensionRuntime("resident", .{}, &.{});

    var new_github_state = TestGitHubTokenState{};
    var new_model_state = ProviderTokenTestContext{
        .token = "new-model-token",
        .expected_session_id = "resident",
        .expected_provider_name = "model-provider",
    };
    try std.testing.expectError(
        error.InvalidGrantedEnvironmentVariables,
        client.resumeSessionWithEnvironment(
            "resident",
            .{
                .git_hub_token_provider = .{
                    .callback = testGitHubTokenProvider,
                    .context = &new_github_state,
                },
                .provider = .{
                    .base_url = "https://example.test",
                    .provider_name = "model-provider",
                    .bearer_token_provider = .{
                        .callback = providerTokenTestCallback,
                        .context = &new_model_state,
                    },
                },
            },
            &.{"TOKEN"},
        ),
    );

    try writer.interface.flush();
    const requests = try tmp.dir.readFileAlloc(
        std.testing.io,
        "requests",
        allocator,
        .limited(16 * 1024),
    );
    defer allocator.free(requests);
    var frames = std.Io.Reader.fixed(requests);
    const resume_body = try json_rpc.readFrame(allocator, &frames);
    defer allocator.free(resume_body);
    const resume_request = try std.json.parseFromSlice(std.json.Value, allocator, resume_body, .{});
    defer resume_request.deinit();
    const replacement_registration = resume_request.value.object
        .get("params").?.object
        .get("gitHubTokenProviderRegistrationId").?.string;

    const token_params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"registrationId\":\"{s}\",\"host\":\"github.com\",\"sessionId\":\"resident\",\"reason\":\"refresh\"}}",
        .{replacement_registration},
    );
    defer allocator.free(token_params_json);
    const token_params = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        token_params_json,
        .{},
    );
    defer token_params.deinit();
    var token_output: std.Io.Writer.Allocating = .init(allocator);
    defer token_output.deinit();
    try client.dispatchServerRequest(
        &token_output.writer,
        .{ .integer = 2 },
        "gitHubToken.getToken",
        token_params.value,
    );
    try std.testing.expectEqual(@as(i64, -32602), try responseErrorCode(allocator, token_output.written()));
    try std.testing.expectEqual(@as(usize, 0), old_github_state.calls);
    try std.testing.expectEqual(@as(usize, 0), new_github_state.calls);

    const old_token_params = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"registrationId":"old-registration","host":"github.com","sessionId":"resident","reason":"refresh"}
    ,
        .{},
    );
    defer old_token_params.deinit();
    var old_token_output: std.Io.Writer.Allocating = .init(allocator);
    defer old_token_output.deinit();
    try client.dispatchServerRequest(
        &old_token_output.writer,
        .{ .integer = 3 },
        "gitHubToken.getToken",
        old_token_params.value,
    );
    try std.testing.expectEqual(@as(i64, -32602), try responseErrorCode(allocator, old_token_output.written()));

    const provider_params = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"sessionId":"resident","providerName":"model-provider"}
    ,
        .{},
    );
    defer provider_params.deinit();
    var provider_output: std.Io.Writer.Allocating = .init(allocator);
    defer provider_output.deinit();
    try client.dispatchServerRequest(
        &provider_output.writer,
        .{ .integer = 4 },
        "providerToken.getToken",
        provider_params.value,
    );
    try std.testing.expectEqual(@as(i64, -32000), try responseErrorCode(allocator, provider_output.written()));
    try std.testing.expectEqual(@as(usize, 0), old_model_state.calls);
    try std.testing.expectEqual(@as(usize, 0), new_model_state.calls);

    const resident = client.findExtensionRuntime("resident").?;
    try std.testing.expect(resident.credentials_quarantined);
    try std.testing.expect(client.findGitHubTokenRuntime("old-registration") == null);
    try std.testing.expect(client.findGitHubTokenRuntime(replacement_registration) == null);
}

test "invalid resident resume ids preserve non-secret callbacks and quarantine credentials" {
    const allocator = std.testing.allocator;
    const command_handler = struct {
        fn handle(_: session_types.CommandContext, _: ?*anyopaque) !void {}
    }.handle;
    const cases = [_]struct {
        response: []const u8,
        expected_error: anyerror,
        detached_session_id: ?[]const u8,
    }{
        .{
            .response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}",
            .expected_error = error.MissingSessionId,
            .detached_session_id = null,
        },
        .{
            .response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"sessionId\":\"unexpected\"}}",
            .expected_error = error.SessionIdMismatch,
            .detached_session_id = "unexpected",
        },
    };

    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const detach_response =
            \\{"jsonrpc":"2.0","id":2,"result":{"success":true}}
        ;
        const token_request =
            \\{"jsonrpc":"2.0","id":77,"method":"gitHubToken.getToken","params":{"registrationId":"old-registration","host":"github.com","sessionId":"resident","reason":"refresh"}}
        ;
        const responses = if (case.detached_session_id != null)
            try std.fmt.allocPrint(
                allocator,
                "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}",
                .{
                    case.response.len,
                    case.response,
                    token_request.len,
                    token_request,
                    detach_response.len,
                    detach_response,
                },
            )
        else
            try std.fmt.allocPrint(
                allocator,
                "Content-Length: {d}\r\n\r\n{s}",
                .{ case.response.len, case.response },
            );
        defer allocator.free(responses);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = responses });
        const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{ .mode = .read_only });
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
            .writer_buffer = &.{},
        };
        defer {
            for (client.session_ids.items) |id| allocator.free(id);
            client.session_ids.deinit(allocator);
            for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
            client.extension_runtimes.deinit(allocator);
        }

        try client.session_ids.append(allocator, try allocator.dupe(u8, "resident"));
        var old_github_state = TestGitHubTokenState{};
        const old_commands = [_]session_types.CommandDefinition{.{
            .name = "old",
            .handler = command_handler,
        }};
        var old_runtime = try SessionExtensionRuntime.init(
            allocator,
            "resident",
            session_types.ResumeSessionConfig{
                .commands = &old_commands,
                .git_hub_token_provider = .{
                    .callback = testGitHubTokenProvider,
                    .context = &old_github_state,
                },
            },
            &.{},
        );
        old_runtime.git_hub_token_registration_id =
            try allocator.dupe(u8, "old-registration");
        try client.extension_runtimes.append(allocator, old_runtime);

        var new_github_state = TestGitHubTokenState{};
        try std.testing.expectError(
            case.expected_error,
            client.resumeSession("resident", .{
                .git_hub_token_provider = .{
                    .callback = testGitHubTokenProvider,
                    .context = &new_github_state,
                },
            }),
        );

        try writer.interface.flush();
        const requests = try tmp.dir.readFileAlloc(
            std.testing.io,
            "requests",
            allocator,
            .limited(16 * 1024),
        );
        defer allocator.free(requests);
        var frames = std.Io.Reader.fixed(requests);
        const resume_body = try json_rpc.readFrame(allocator, &frames);
        defer allocator.free(resume_body);
        const resume_request = try std.json.parseFromSlice(std.json.Value, allocator, resume_body, .{});
        defer resume_request.deinit();
        const replacement_registration = resume_request.value.object
            .get("params").?.object
            .get("gitHubTokenProviderRegistrationId").?.string;

        const resident = client.findExtensionRuntime("resident").?;
        try std.testing.expectEqual(@as(usize, 1), resident.commands.len);
        try std.testing.expectEqualStrings("old", resident.commands[0].name);
        try std.testing.expect(resident.credentials_quarantined);
        try std.testing.expect(client.findGitHubTokenRuntime("old-registration") == null);
        try std.testing.expect(client.findGitHubTokenRuntime(replacement_registration) == null);

        const old_token_params = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            \\{"registrationId":"old-registration","host":"github.com","sessionId":"resident","reason":"refresh"}
        ,
            .{},
        );
        defer old_token_params.deinit();
        var token_output: std.Io.Writer.Allocating = .init(allocator);
        defer token_output.deinit();
        try client.dispatchServerRequest(
            &token_output.writer,
            .{ .integer = 3 },
            "gitHubToken.getToken",
            old_token_params.value,
        );
        try std.testing.expectEqual(
            @as(i64, -32602),
            try responseErrorCode(allocator, token_output.written()),
        );
        try std.testing.expectEqual(@as(usize, 0), old_github_state.calls);
        try std.testing.expectEqual(@as(usize, 0), new_github_state.calls);

        if (case.detached_session_id) |detached_session_id| {
            const detach_body = try json_rpc.readFrame(allocator, &frames);
            defer allocator.free(detach_body);
            const cleanup_token_body = try json_rpc.readFrame(allocator, &frames);
            defer allocator.free(cleanup_token_body);
            const expected_detach = try std.fmt.allocPrint(
                allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session.detach\",\"params\":{{\"sessionId\":\"{s}\"}}}}",
                .{detached_session_id},
            );
            defer allocator.free(expected_detach);
            try std.testing.expectEqualStrings(expected_detach, detach_body);
            try std.testing.expectEqualStrings(
                \\{"jsonrpc":"2.0","id":77,"error":{"code":-32602,"message":"unknown GitHub token registration"}}
            , cleanup_token_body);
        }
        try std.testing.expectEqualStrings("", frames.buffered());
    }
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
        \\{"type":"permission.requested","data":{"requestId":"permission-1","permissionRequest":{"kind":"shell","fullCommandText":"pwd","intention":"show directory","commands":[],"possiblePaths":[],"possibleUrls":[],"hasWriteFileRedirection":false,"canOfferSessionApproval":false}}}
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
        \\{"type":"permission.requested","data":{"requestId":"permission-1","permissionRequest":{"kind":"read","intention":"inspect file","path":"README.md"}}}
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
        \\{"type":"permission.requested","data":{"requestId":"permission-1","permissionRequest":{"kind":"shell","fullCommandText":"pwd","intention":"show directory","commands":[],"possiblePaths":[],"possibleUrls":[],"hasWriteFileRedirection":false,"canOfferSessionApproval":false}}}
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
        \\{"type":"permission.requested","data":{"requestId":"permission-1","permissionRequest":{"kind":"shell","fullCommandText":"pwd","intention":"show directory","commands":[],"possiblePaths":[],"possibleUrls":[],"hasWriteFileRedirection":false,"canOfferSessionApproval":false}}}
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
        for (client.events.items) |*queued_event| queued_event.deinit(allocator);
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
        const defaults = ",\"streaming\":false,\"includeSubAgentStreamingEvents\":true,\"tools\":[],\"toolFilterPrecedence\":\"excluded\",\"requestPermission\":false,\"requestUserInput\":false,\"requestElicitation\":false,\"requestExitPlanMode\":false,\"requestAutoModeSwitch\":false,\"enableManagedSettings\":false";
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
        "{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"session.create\",\"params\":{\"streaming\":false,\"includeSubAgentStreamingEvents\":true,\"tools\":[],\"toolFilterPrecedence\":\"excluded\",\"requestPermission\":true,\"requestUserInput\":false,\"requestElicitation\":false,\"requestExitPlanMode\":false,\"requestAutoModeSwitch\":false,\"enableManagedSettings\":false,\"managedSettings\":{\"permissions\":{\"disableBypassPermissionsMode\":\"allow-auto-only\",\"deny\":[\"Shell(git push *)\"],\"ask\":[\"Read(**)\"],\"allow\":[\"Read(src/**)\"]}}}}",
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
        "{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"session.resume\",\"params\":{\"sessionId\":\"session-1\",\"streaming\":false,\"includeSubAgentStreamingEvents\":true,\"tools\":[],\"toolFilterPrecedence\":\"excluded\",\"requestPermission\":true,\"requestUserInput\":false,\"requestElicitation\":false,\"requestExitPlanMode\":false,\"requestAutoModeSwitch\":false,\"enableManagedSettings\":false,\"managedSettings\":{\"permissions\":{\"disableBypassPermissionsMode\":\"allow-auto-only\",\"deny\":[\"Shell(git push *)\"],\"ask\":[\"Read(**)\"],\"allow\":[\"Read(src/**)\"]}}}}",
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
        "{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"session.create\",\"params\":{\"streaming\":false,\"includeSubAgentStreamingEvents\":true,\"tools\":[],\"toolFilterPrecedence\":\"excluded\",\"requestPermission\":true,\"requestUserInput\":false,\"requestElicitation\":false,\"requestExitPlanMode\":false,\"requestAutoModeSwitch\":false,\"enableManagedSettings\":true}}",
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
        "{\"jsonrpc\":\"2.0\",\"id\":16,\"method\":\"session.resume\",\"params\":{\"sessionId\":\"session-1\",\"streaming\":false,\"includeSubAgentStreamingEvents\":true,\"tools\":[],\"toolFilterPrecedence\":\"excluded\",\"requestPermission\":true,\"requestUserInput\":false,\"requestElicitation\":false,\"requestExitPlanMode\":false,\"requestAutoModeSwitch\":false,\"enableManagedSettings\":true}}",
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

test "provisional create runtime is unreachable without an exact session id" {
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
    try std.testing.expect(client.findExtensionRuntime("new-session") == null);
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

test "all hook paths reject a forged nested session identity" {
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
    try client.extension_runtimes.append(
        allocator,
        try SessionExtensionRuntime.init(
            allocator,
            "registered",
            session_types.ResumeSessionConfig{},
            &.{},
        ),
    );

    const hook_types = [_][]const u8{
        "preToolUse",
        "preMcpToolCall",
        "postToolUse",
        "postToolUseFailure",
        "userPromptSubmitted",
        "userPromptTransformed",
        "sessionStart",
        "sessionEnd",
        "errorOccurred",
        "agentStop",
    };
    for (hook_types, 0..) |hook_type, index| {
        const json = try std.fmt.allocPrint(
            allocator,
            "{{\"sessionId\":\"registered\",\"hookType\":\"{s}\",\"input\":{{\"sessionId\":\"forged\",\"timestamp\":1,\"cwd\":\"/repo\"}}}}",
            .{hook_type},
        );
        defer allocator.free(json);
        const params = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
        defer params.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        try client.dispatchServerRequest(
            &output.writer,
            .{ .integer = @intCast(index + 1) },
            "hooks.invoke",
            params.value,
        );
        try std.testing.expectEqual(
            @as(i64, -32602),
            try responseErrorCode(allocator, output.written()),
        );
    }
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
    client.pending_extension_runtime.?.git_hub_token_registration_id =
        try allocator.dupe(u8, "old-registration");
    try client.commitExtensionRuntime("s1", .{}, &.{});
    try client.beginExtensionRuntime("s1", session_types.ResumeSessionConfig{
        .extensions = .{ .common = .{ .hooks = .{
            .context = &new_context,
        } } },
    }, &.{});
    client.pending_extension_runtime.?.git_hub_token_registration_id =
        try allocator.dupe(u8, "new-registration");
    try std.testing.expectEqual(
        @as(?*anyopaque, &new_context),
        client.findExtensionRuntime("s1").?.hooks.context,
    );
    try std.testing.expect(client.findGitHubTokenRuntime("new-registration") != null);
    try std.testing.expect(client.findGitHubTokenRuntime("old-registration") != null);
    try client.commitExtensionRuntime("s1", .{}, &.{});
    try std.testing.expectEqual(@as(usize, 1), client.extension_runtimes.items.len);
    try std.testing.expectEqual(
        @as(?*anyopaque, &new_context),
        client.findExtensionRuntime("s1").?.hooks.context,
    );
    try std.testing.expect(client.findGitHubTokenRuntime("new-registration") != null);
    try std.testing.expect(client.findGitHubTokenRuntime("old-registration") == null);
}

test "credential quarantine is idempotent and cleared by replacement and removal" {
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
        for (client.session_ids.items) |id| allocator.free(id);
        client.session_ids.deinit(allocator);
    }
    try client.session_ids.append(allocator, try allocator.dupe(u8, "s1"));

    var old_github_state = TestGitHubTokenState{};
    try client.beginExtensionRuntime("s1", session_types.ResumeSessionConfig{
        .git_hub_token_provider = .{
            .callback = testGitHubTokenProvider,
            .context = &old_github_state,
        },
    }, &.{});
    client.pending_extension_runtime.?.git_hub_token_registration_id =
        try allocator.dupe(u8, "old-registration");
    try client.commitExtensionRuntime("s1", .{}, &.{});

    client.quarantineSessionCredentials("s1");
    client.quarantineSessionCredentials("s1");
    try std.testing.expect(client.findExtensionRuntime("s1").?.credentials_quarantined);
    try std.testing.expect(client.findGitHubTokenRuntime("old-registration") == null);

    var new_github_state = TestGitHubTokenState{};
    try client.beginExtensionRuntime("s1", session_types.ResumeSessionConfig{
        .git_hub_token_provider = .{
            .callback = testGitHubTokenProvider,
            .context = &new_github_state,
        },
    }, &.{});
    client.pending_extension_runtime.?.git_hub_token_registration_id =
        try allocator.dupe(u8, "new-registration");
    try client.commitExtensionRuntime("s1", .{}, &.{});
    try std.testing.expect(!client.findExtensionRuntime("s1").?.credentials_quarantined);
    try std.testing.expect(client.findGitHubTokenRuntime("new-registration") != null);

    client.removeSession("s1");
    client.removeSession("s1");
    try std.testing.expect(client.findExtensionRuntime("s1") == null);
    try std.testing.expect(client.findGitHubTokenRuntime("new-registration") == null);
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
        runtime.mcp_oauth_interest.registered.handle(),
    );
    try client.releaseMcpOAuthInterest(runtime);
    try std.testing.expect(runtime.mcp_oauth_interest == .none);
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

test "OAuth interest adoption cannot fail after the typed response is owned" {
    const allocator = std.testing.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(
        allocator,
        .{ .fail_index = 0 },
    );
    var client: Client = undefined;
    client.allocator = failing_allocator.allocator();
    client.pending_extension_runtime = null;
    client.extension_runtimes = .empty;
    defer {
        for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
        client.extension_runtimes.deinit(allocator);
    }
    var runtime = try SessionExtensionRuntime.init(
        allocator,
        "s1",
        session_types.ResumeSessionConfig{},
        &.{},
    );
    runtime.mcp_oauth_interest = .{ .registering = .initial };
    try client.extension_runtimes.append(allocator, runtime);
    const parsed = try std.json.parseFromSlice(
        WireMcpOAuthInterest,
        allocator,
        \\{"handle":"interest-1"}
    ,
        .{ .allocate = .alloc_always },
    );

    client.adoptMcpOAuthInterest(
        "s1",
        .committed,
        parsed,
    );
    try std.testing.expect(!failing_allocator.has_induced_failure);
    try std.testing.expectEqualStrings(
        "interest-1",
        client.extension_runtimes.items[0].mcp_oauth_interest.registered.handle(),
    );
}

test "failed OAuth release preserves the committed runtime for retry" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const failed_release =
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"release failed"}}
    ;
    const successful_release =
        \\{"jsonrpc":"2.0","id":2,"result":{"success":true}}
    ;
    const responses = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}",
        .{
            failed_release.len,
            failed_release,
            successful_release.len,
            successful_release,
        },
    );
    defer allocator.free(responses);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = responses });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{ .mode = .read_only });
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
    defer {
        client.rollbackExtensionRuntime();
        for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
        client.extension_runtimes.deinit(allocator);
    }
    var old_context: u8 = 1;
    var new_context: u8 = 2;
    var original = try SessionExtensionRuntime.init(
        allocator,
        "s1",
        session_types.ResumeSessionConfig{
            .extensions = .{ .common = .{ .hooks = .{ .context = &old_context } } },
        },
        &.{},
    );
    original.mcp_oauth_interest = try testMcpOAuthInterest(allocator, "interest-1");
    try client.extension_runtimes.append(allocator, original);
    try client.beginExtensionRuntime(
        "s1",
        session_types.ResumeSessionConfig{
            .extensions = .{ .common = .{ .hooks = .{ .context = &new_context } } },
        },
        &.{},
    );

    try std.testing.expectError(
        error.EventInterestNotReleased,
        client.commitPreparedExtensionRuntime("s1"),
    );
    try std.testing.expect(client.pending_extension_runtime != null);
    try std.testing.expectEqualStrings(
        "interest-1",
        client.extension_runtimes.items[0].mcp_oauth_interest.registered.handle(),
    );
    try std.testing.expectEqual(
        @as(?*anyopaque, &old_context),
        client.extension_runtimes.items[0].hooks.context,
    );

    try client.commitPreparedExtensionRuntime("s1");
    try std.testing.expect(client.pending_extension_runtime == null);
    try std.testing.expect(
        client.findExtensionRuntime("s1").?.mcp_oauth_interest == .none,
    );
    try std.testing.expectEqual(
        @as(?*anyopaque, &new_context),
        client.findExtensionRuntime("s1").?.hooks.context,
    );

    try writer.interface.flush();
    const requests = try tmp.dir.readFileAlloc(
        std.testing.io,
        "requests",
        allocator,
        .limited(4096),
    );
    defer allocator.free(requests);
    var request_reader = std.Io.Reader.fixed(requests);
    for (0..2) |index| {
        const body = try json_rpc.readFrame(allocator, &request_reader);
        defer allocator.free(body);
        const expected = try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"session.eventLog.releaseInterest\",\"params\":{{\"sessionId\":\"s1\",\"handle\":\"interest-1\"}}}}",
            .{index + 1},
        );
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, body);
    }
}

test "every OAuth release failure keeps the owned handle retryable" {
    const allocator = std.testing.allocator;
    const response_bodies = [_][]const u8{
        "",
        "Content-Length: 75\r\n\r\n{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32000,\"message\":\"release failed\"}}",
        "Content-Length: 1\r\n\r\n{",
        "Content-Length: 51\r\n\r\n{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"success\":false}}",
    };
    for (response_bodies) |response_body| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{
            .sub_path = "responses",
            .data = response_body,
        });
        const response_file = try tmp.dir.openFile(
            std.testing.io,
            "responses",
            .{ .mode = .read_only },
        );
        defer response_file.close(std.testing.io);
        var reader_buffer: [512]u8 = undefined;
        var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
        const request_file = try tmp.dir.createFile(std.testing.io, "requests", .{});
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
        defer {
            for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
            client.extension_runtimes.deinit(allocator);
        }
        var runtime = try SessionExtensionRuntime.init(
            allocator,
            "s1",
            session_types.ResumeSessionConfig{},
            &.{},
        );
        runtime.mcp_oauth_interest = try testMcpOAuthInterest(allocator, "interest-1");
        try client.extension_runtimes.append(allocator, runtime);

        var failed = false;
        client.releaseMcpOAuthInterest(&client.extension_runtimes.items[0]) catch {
            failed = true;
        };
        try std.testing.expect(failed);
        try std.testing.expectEqualStrings(
            "interest-1",
            client.extension_runtimes.items[0].mcp_oauth_interest.registered.handle(),
        );
    }
}

test "reentrant disconnect cannot invalidate an OAuth release" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const event =
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"s1","event":{"type":"mcp.oauth_required","data":{"requestId":"oauth-1","serverName":"server","serverUrl":"https://example.test","reason":"initial"}}}}
    ;
    const auth_response =
        \\{"jsonrpc":"2.0","id":2,"result":{"success":true}}
    ;
    const release_response =
        \\{"jsonrpc":"2.0","id":1,"result":{"success":true}}
    ;
    const responses = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}",
        .{
            event.len,
            event,
            auth_response.len,
            auth_response,
            release_response.len,
            release_response,
        },
    );
    defer allocator.free(responses);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = responses });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{ .mode = .read_only });
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
        for (client.events.items) |*queued| queued.deinit(allocator);
        client.events.deinit(allocator);
        for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
        client.extension_runtimes.deinit(allocator);
    }
    const HandlerState = struct {
        session: Session,
        called: bool = false,
    };
    var state = HandlerState{ .session = .{ .client = &client, .id = "s1" } };
    const handler = struct {
        fn handle(
            _: std.mem.Allocator,
            _: ext.McpAuthRequest,
            context: ?*anyopaque,
        ) !ext.McpAuthResult {
            const handler_state: *HandlerState = @ptrCast(@alignCast(context.?));
            try std.testing.expectError(
                error.EventInterestOperationInProgress,
                handler_state.session.disconnect(),
            );
            handler_state.called = true;
            return .cancelled;
        }
    }.handle;
    var runtime = try SessionExtensionRuntime.init(
        allocator,
        "s1",
        session_types.ResumeSessionConfig{
            .extensions = .{ .common = .{ .mcp = .{
                .on_auth_request = handler,
                .auth_context = &state,
            } } },
        },
        &.{},
    );
    runtime.mcp_oauth_interest = try testMcpOAuthInterest(allocator, "interest-1");
    try client.extension_runtimes.append(allocator, runtime);

    try client.releaseMcpOAuthInterest(&client.extension_runtimes.items[0]);
    try std.testing.expect(state.called);
    try std.testing.expect(
        client.extension_runtimes.items[0].mcp_oauth_interest == .none,
    );
    try std.testing.expect(
        client.events.items[0].event.mcp_oauth_required.automatic_handling == .handled,
    );
}

test "disconnecting another session cannot invalidate an OAuth release" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const event =
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"s1","event":{"type":"mcp.oauth_required","data":{"requestId":"oauth-1","serverName":"server","serverUrl":"https://example.test","reason":"initial"}}}}
    ;
    const detach_response =
        \\{"jsonrpc":"2.0","id":2,"result":{"success":true}}
    ;
    const auth_response =
        \\{"jsonrpc":"2.0","id":3,"result":{"success":true}}
    ;
    const release_response =
        \\{"jsonrpc":"2.0","id":1,"result":{"success":true}}
    ;
    const responses = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}",
        .{
            event.len,
            event,
            detach_response.len,
            detach_response,
            auth_response.len,
            auth_response,
            release_response.len,
            release_response,
        },
    );
    defer allocator.free(responses);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = responses });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{ .mode = .read_only });
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
        for (client.events.items) |*queued| queued.deinit(allocator);
        client.events.deinit(allocator);
        for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
        client.extension_runtimes.deinit(allocator);
        for (client.session_ids.items) |id| allocator.free(id);
        client.session_ids.deinit(allocator);
    }
    const HandlerState = struct {
        other: Session,
        called: bool = false,
    };
    var state = HandlerState{ .other = .{ .client = &client, .id = "s2" } };
    const handler = struct {
        fn handle(
            _: std.mem.Allocator,
            _: ext.McpAuthRequest,
            context: ?*anyopaque,
        ) !ext.McpAuthResult {
            const handler_state: *HandlerState = @ptrCast(@alignCast(context.?));
            try handler_state.other.disconnect();
            handler_state.called = true;
            return .cancelled;
        }
    }.handle;
    const s2_id = try allocator.dupe(u8, "s2");
    try client.session_ids.append(allocator, s2_id);
    var s2 = try SessionExtensionRuntime.init(
        allocator,
        "s2",
        session_types.ResumeSessionConfig{},
        &.{},
    );
    try client.extension_runtimes.append(allocator, s2);
    s2 = undefined;
    var s1 = try SessionExtensionRuntime.init(
        allocator,
        "s1",
        session_types.ResumeSessionConfig{
            .extensions = .{ .common = .{ .mcp = .{
                .on_auth_request = handler,
                .auth_context = &state,
            } } },
        },
        &.{},
    );
    s1.mcp_oauth_interest = try testMcpOAuthInterest(allocator, "interest-1");
    try client.extension_runtimes.append(allocator, s1);
    s1 = undefined;

    try client.releaseMcpOAuthInterest(client.findExtensionRuntime("s1").?);
    try std.testing.expect(state.called);
    try std.testing.expect(client.findExtensionRuntime("s2") == null);
    try std.testing.expect(
        client.findExtensionRuntime("s1").?.mcp_oauth_interest == .none,
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

test "detach restoration failures remain observable and retryable" {
    const allocator = std.testing.allocator;
    const release_response =
        \\{"jsonrpc":"2.0","id":1,"result":{"success":true}}
    ;
    const first_detach_response =
        \\{"jsonrpc":"2.0","id":2,"result":{"success":false}}
    ;
    const second_detach_response =
        \\{"jsonrpc":"2.0","id":3,"result":{"success":false}}
    ;
    const restore_responses = [_]?[]const u8{
        null,
        \\{"jsonrpc":"2.0","id":4,"error":{"code":-32000,"message":"restore failed"}}
        ,
        "{",
        \\{"jsonrpc":"2.0","id":4,"result":{"success":false}}
        ,
    };
    for (restore_responses) |restore_response| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var responses: std.ArrayList(u8) = .empty;
        defer responses.deinit(allocator);
        const fixed_responses = [_][]const u8{
            release_response,
            first_detach_response,
            second_detach_response,
        };
        for (fixed_responses) |response| {
            try responses.print(
                allocator,
                "Content-Length: {d}\r\n\r\n{s}",
                .{ response.len, response },
            );
        }
        if (restore_response) |response| {
            try responses.print(
                allocator,
                "Content-Length: {d}\r\n\r\n{s}",
                .{ response.len, response },
            );
        }
        try tmp.dir.writeFile(std.testing.io, .{
            .sub_path = "responses",
            .data = responses.items,
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
            .writer_buffer = &.{},
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
        var runtime = try SessionExtensionRuntime.init(
            allocator,
            "s1",
            session_types.ResumeSessionConfig{
                .extensions = .{ .common = .{ .mcp = .{
                    .on_auth_request = handler,
                } } },
            },
            &.{},
        );
        runtime.mcp_oauth_interest = try testMcpOAuthInterest(allocator, "interest-1");
        try client.extension_runtimes.append(allocator, runtime);

        try std.testing.expectError(
            error.McpOAuthInterestRestoreFailed,
            (Session{ .client = &client, .id = "s1" }).disconnect(),
        );
        try std.testing.expect(client.findExtensionRuntime("s1") != null);
        try std.testing.expect(
            client.findExtensionRuntime("s1").?.mcp_oauth_interest == .restore_required,
        );
    }
}

test "disconnect retries pending OAuth restoration before detach" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const register_response =
        \\{"jsonrpc":"2.0","id":1,"result":{"handle":"interest-2"}}
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
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = responses });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{ .mode = .read_only });
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
    var runtime = try SessionExtensionRuntime.init(
        allocator,
        "s1",
        session_types.ResumeSessionConfig{
            .extensions = .{ .common = .{ .mcp = .{
                .on_auth_request = handler,
            } } },
        },
        &.{},
    );
    runtime.mcp_oauth_interest = .restore_required;
    try client.extension_runtimes.append(allocator, runtime);

    try (Session{ .client = &client, .id = "s1" }).disconnect();
    try std.testing.expect(client.findExtensionRuntime("s1") == null);
    try writer.interface.flush();
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
    const release_body = try json_rpc.readFrame(allocator, &frames);
    defer allocator.free(release_body);
    const detach_body = try json_rpc.readFrame(allocator, &frames);
    defer allocator.free(detach_body);
    try std.testing.expect(std.mem.indexOf(
        u8,
        register_body,
        "\"method\":\"session.eventLog.registerInterest\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        release_body,
        "\"method\":\"session.eventLog.releaseInterest\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        detach_body,
        "\"method\":\"session.detach\"",
    ) != null);
}

test "detach recovery preserves an interest restored during nested dispatch" {
    const allocator = std.testing.allocator;
    var client: Client = undefined;
    client.allocator = allocator;
    client.pending_extension_runtime = null;
    client.extension_runtimes = .empty;
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
    var runtime = try SessionExtensionRuntime.init(
        allocator,
        "s1",
        session_types.ResumeSessionConfig{
            .extensions = .{ .common = .{ .mcp = .{
                .on_auth_request = handler,
            } } },
        },
        &.{},
    );
    runtime.mcp_oauth_interest = try testMcpOAuthInterest(allocator, "interest-2");
    try client.extension_runtimes.append(allocator, runtime);

    try (Session{ .client = &client, .id = "s1" })
        .restoreMcpOAuthInterestAfterDetachFailure(true);
    try std.testing.expectEqualStrings(
        "interest-2",
        client.extension_runtimes.items[0].mcp_oauth_interest.registered.handle(),
    );
}

test "client teardown releases OAuth interests before event storage" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const event_frame =
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"s1","event":{"type":"mcp.oauth_required","data":{"staticClientConfig":{"clientSecret":"secret"}}}}}
    ;
    const release_response =
        \\{"jsonrpc":"2.0","id":1,"result":{"success":true}}
    ;
    const responses = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}",
        .{ event_frame.len, event_frame, release_response.len, release_response },
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
    client.findExtensionRuntime("s1").?.mcp_oauth_interest =
        try testMcpOAuthInterest(allocator, "interest-1");

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

test "invalid MCP OAuth token remains observable without cancellation" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const register_response =
        \\{"jsonrpc":"2.0","id":1,"result":{"handle":"interest-1"}}
    ;
    const event =
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"s1","event":{"type":"mcp.oauth_required","data":{"requestId":"oauth-1","serverName":"server","serverUrl":"https://example.test","reason":"initial"}}}}
    ;
    const responses = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}",
        .{
            register_response.len,
            register_response,
            event.len,
            event,
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
    var oauth_event = try session.nextEvent();
    defer oauth_event.deinit(allocator);
    try std.testing.expect(
        oauth_event.mcp_oauth_required.automatic_handling == .invalid_result,
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
        std.mem.indexOf(u8, requests, "session.mcp.oauth.handlePendingRequest") == null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, requests, "\"accessToken\"") == null,
    );
}

test "MCP OAuth handler failure remains observable without cancellation" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const event =
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"s1","event":{"type":"mcp.oauth_required","data":{"requestId":"oauth-1","serverName":"server","serverUrl":"https://example.test","reason":"initial"}}}}
    ;
    const outer_response =
        \\{"jsonrpc":"2.0","id":1,"result":{"value":"done"}}
    ;
    const responses = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}",
        .{ event.len, event, outer_response.len, outer_response },
    );
    defer allocator.free(responses);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "responses",
        .data = responses,
    });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{ .mode = .read_only });
    defer response_file.close(std.testing.io);
    var reader_buffer: [128]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
    const request_file = try tmp.dir.createFile(std.testing.io, "requests", .{});
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
    defer {
        for (client.events.items) |*queued| queued.deinit(allocator);
        client.events.deinit(allocator);
        for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
        client.extension_runtimes.deinit(allocator);
    }
    const handler = struct {
        fn handle(
            _: std.mem.Allocator,
            _: ext.McpAuthRequest,
            _: ?*anyopaque,
        ) !ext.McpAuthResult {
            return error.LoginFailed;
        }
    }.handle;
    try client.extension_runtimes.append(
        allocator,
        try SessionExtensionRuntime.init(
            allocator,
            "s1",
            session_types.ResumeSessionConfig{
                .extensions = .{ .common = .{ .mcp = .{
                    .on_auth_request = handler,
                } } },
            },
            &.{},
        ),
    );
    const outer = try client.callRpc(struct { value: []const u8 }, "test.outer", .{});
    defer outer.deinit();

    try std.testing.expectEqualStrings("done", outer.value.value);
    try std.testing.expectEqual(@as(usize, 1), client.events.items.len);
    const handling = client.events.items[0].event.mcp_oauth_required.automatic_handling;
    try std.testing.expect(handling == .handler_failed);
    try std.testing.expect(handling.handler_failed == error.LoginFailed);
    try writer.interface.flush();
    const requests = try tmp.dir.readFileAlloc(
        std.testing.io,
        "requests",
        allocator,
        .limited(256),
    );
    defer allocator.free(requests);
    try std.testing.expect(
        std.mem.indexOf(u8, requests, "session.mcp.oauth.handlePendingRequest") == null,
    );
}

test "explicit MCP OAuth cancellation sends the cancellation response" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":{"success":true}}
    ;
    const framed = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}",
        .{ response.len, response },
    );
    defer allocator.free(framed);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = framed });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{ .mode = .read_only });
    defer response_file.close(std.testing.io);
    var reader_buffer: [256]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
    const request_file = try tmp.dir.createFile(std.testing.io, "requests", .{});
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
    defer {
        for (client.events.items) |*queued| queued.deinit(allocator);
        client.events.deinit(allocator);
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
    try client.extension_runtimes.append(
        allocator,
        try SessionExtensionRuntime.init(
            allocator,
            "s1",
            session_types.ResumeSessionConfig{
                .extensions = .{ .common = .{ .mcp = .{
                    .on_auth_request = handler,
                } } },
            },
            &.{},
        ),
    );
    const params = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"sessionId":"s1","event":{"type":"mcp.oauth_required","data":{"requestId":"oauth-1","serverName":"server","serverUrl":"https://example.test","reason":"initial"}}}
    ,
        .{},
    );
    defer params.deinit();
    try client.queueSessionEvent(params.value);

    try std.testing.expect(
        client.events.items[0].event.mcp_oauth_required.automatic_handling == .handled,
    );
    try writer.interface.flush();
    const requests = try tmp.dir.readFileAlloc(
        std.testing.io,
        "requests",
        allocator,
        .limited(1024),
    );
    defer allocator.free(requests);
    try std.testing.expect(
        std.mem.indexOf(u8, requests, "\"kind\":\"cancelled\"") != null,
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

test "canvas identity is instance-only" {
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
        for (client.events.items) |*queued_event| queued_event.deinit(allocator);
        client.events.deinit(allocator);
        for (client.tools.items) |tool| tool.deinit(allocator);
        client.tools.deinit(allocator);
        for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
        client.extension_runtimes.deinit(allocator);
    }
    try client.extension_runtimes.append(
        allocator,
        try SessionExtensionRuntime.init(
            allocator,
            "s1",
            session_types.CreateSessionConfig{},
            &.{},
        ),
    );

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

fn fillRequiredEventQueue(
    client: *Client,
    allocator: std.mem.Allocator,
    session_id: []const u8,
) !void {
    const permission_json = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"permission.requested","data":{"requestId":"permission-queued","permissionRequest":{"kind":"shell","fullCommandText":"pwd","intention":"show directory","commands":[],"possiblePaths":[],"possibleUrls":[],"hasWriteFileRedirection":false,"canOfferSessionApproval":false}}}
    ,
        .{},
    );
    defer permission_json.deinit();
    const tool_json = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"type":"external_tool.requested","data":{"requestId":"tool-queued","sessionId":"s1","toolCallId":"call-1","toolName":"lookup"}}
    ,
        .{},
    );
    defer tool_json.deinit();
    for (0..max_queued_events) |index| {
        try client.events.append(allocator, .{
            .session_id = try allocator.dupe(u8, session_id),
            .event = try session_types.parseEvent(
                allocator,
                if (index % 2 == 0) permission_json.value else tool_json.value,
            ),
        });
    }
}

test "a full interaction queue does not evict another session" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const event =
        \\{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"s1","event":{"type":"command.execute","data":{"requestId":"command-1","command":"/ship","commandName":"ship","args":""}}}}
    ;
    const command_response =
        \\{"jsonrpc":"2.0","id":2,"result":{"success":true}}
    ;
    const outer_response =
        \\{"jsonrpc":"2.0","id":1,"result":{"value":"done"}}
    ;
    const responses = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}",
        .{
            event.len,
            event,
            command_response.len,
            command_response,
            outer_response.len,
            outer_response,
        },
    );
    defer allocator.free(responses);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = responses });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{ .mode = .read_only });
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
        for (client.events.items) |*queued_event| queued_event.deinit(allocator);
        client.events.deinit(allocator);
        for (client.tools.items) |tool| tool.deinit(allocator);
        client.tools.deinit(allocator);
        for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
        client.extension_runtimes.deinit(allocator);
    }
    var command_called = false;
    const handler = struct {
        fn handle(_: session_types.CommandContext, context: ?*anyopaque) !void {
            const called: *bool = @ptrCast(@alignCast(context.?));
            called.* = true;
        }
    }.handle;
    try client.extension_runtimes.append(
        allocator,
        try SessionExtensionRuntime.init(
            allocator,
            "s1",
            session_types.CreateSessionConfig{
                .commands = &.{.{
                    .name = "ship",
                    .handler = handler,
                    .context = &command_called,
                }},
            },
            &.{},
        ),
    );
    try client.extension_runtimes.append(
        allocator,
        try SessionExtensionRuntime.init(
            allocator,
            "s2",
            session_types.CreateSessionConfig{},
            &.{},
        ),
    );

    try client.events.ensureTotalCapacity(allocator, max_queued_events);
    try client.events.append(allocator, .{
        .session_id = try allocator.dupe(u8, "s2"),
        .event = .{ .session_idle = .{} },
    });
    try fillRequiredEventQueue(&client, allocator, "s1");

    const outer = try client.callRpc(struct { value: []const u8 }, "test.outer", .{});
    defer outer.deinit();
    try std.testing.expectEqualStrings("done", outer.value.value);
    try std.testing.expect(command_called);
    try std.testing.expectEqual(@as(usize, max_queued_events + 1), client.events.items.len);
    var preserved = try (Session{ .client = &client, .id = "s2" }).nextEvent();
    defer preserved.deinit(allocator);
    try std.testing.expect(preserved == .session_idle);
    for (0..max_queued_events) |_| {
        var retained = try (Session{ .client = &client, .id = "s1" }).nextEvent();
        retained.deinit(allocator);
    }
    try std.testing.expectError(
        error.EventQueueFull,
        (Session{ .client = &client, .id = "s1" }).nextEvent(),
    );
    try writer.interface.flush();
    const requests = try tmp.dir.readFileAlloc(
        std.testing.io,
        "requests",
        allocator,
        .limited(2048),
    );
    defer allocator.free(requests);
    var request_reader = std.Io.Reader.fixed(requests);
    const outer_body = try json_rpc.readFrame(allocator, &request_reader);
    defer allocator.free(outer_body);
    const command_body = try json_rpc.readFrame(allocator, &request_reader);
    defer allocator.free(command_body);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"method":"test.outer","params":[]}
    , outer_body);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":2,"method":"session.commands.handlePendingCommand","params":{"sessionId":"s1","requestId":"command-1"}}
    , command_body);
}

test "a full session queue rejects unretained permission and tool requests" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        event_json: []const u8,
        expected_request: []const u8,
    }{
        .{
            .event_json =
            \\{"sessionId":"s1","event":{"type":"permission.requested","data":{"requestId":"overflow","permissionRequest":{"kind":"shell","fullCommandText":"pwd","intention":"show directory","commands":[],"possiblePaths":[],"possibleUrls":[],"hasWriteFileRedirection":false,"canOfferSessionApproval":false}}}}
            ,
            .expected_request =
            \\{"jsonrpc":"2.0","id":1,"method":"session.permissions.handlePendingPermissionRequest","params":{"sessionId":"s1","requestId":"overflow","result":{"kind":"reject","feedback":"SDK event queue capacity exceeded"}}}
            ,
        },
        .{
            .event_json =
            \\{"sessionId":"s1","event":{"type":"external_tool.requested","data":{"requestId":"overflow","sessionId":"s1","toolCallId":"call-overflow","toolName":"lookup"}}}
            ,
            .expected_request =
            \\{"jsonrpc":"2.0","id":1,"method":"session.tools.handlePendingToolCall","params":{"sessionId":"s1","requestId":"overflow","error":"SDK event queue capacity exceeded"}}
            ,
        },
    };

    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const response =
            \\{"jsonrpc":"2.0","id":1,"result":{"success":true}}
        ;
        const framed = try std.fmt.allocPrint(
            allocator,
            "Content-Length: {d}\r\n\r\n{s}",
            .{ response.len, response },
        );
        defer allocator.free(framed);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = framed });
        const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{ .mode = .read_only });
        defer response_file.close(std.testing.io);
        var reader_buffer: [512]u8 = undefined;
        var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
        const request_file = try tmp.dir.createFile(std.testing.io, "requests", .{});
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
        defer {
            for (client.events.items) |*event| event.deinit(allocator);
            client.events.deinit(allocator);
            for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
            client.extension_runtimes.deinit(allocator);
        }
        try client.extension_runtimes.append(
            allocator,
            try SessionExtensionRuntime.init(
                allocator,
                "s1",
                session_types.CreateSessionConfig{},
                &.{},
            ),
        );
        try fillRequiredEventQueue(&client, allocator, "s1");
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            case.event_json,
            .{},
        );
        defer parsed.deinit();

        try client.queueSessionEvent(parsed.value);
        try std.testing.expectEqual(@as(usize, max_queued_events), client.events.items.len);
        try writer.interface.flush();
        const requests = try tmp.dir.readFileAlloc(
            std.testing.io,
            "requests",
            allocator,
            .limited(4096),
        );
        defer allocator.free(requests);
        var request_reader = std.Io.Reader.fixed(requests);
        const request = try json_rpc.readFrame(allocator, &request_reader);
        defer allocator.free(request);
        try std.testing.expectEqualStrings(case.expected_request, request);
        for (0..max_queued_events) |_| {
            var retained = try (Session{ .client = &client, .id = "s1" }).nextEvent();
            retained.deinit(allocator);
        }
        try std.testing.expectError(
            error.EventQueueFull,
            (Session{ .client = &client, .id = "s1" }).nextEvent(),
        );
    }
}

test "failed overflow rejection is observable after retained work drains" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":{"success":false}}
    ;
    const framed = try std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\n\r\n{s}",
        .{ response.len, response },
    );
    defer allocator.free(framed);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "responses", .data = framed });
    const response_file = try tmp.dir.openFile(std.testing.io, "responses", .{ .mode = .read_only });
    defer response_file.close(std.testing.io);
    var reader_buffer: [512]u8 = undefined;
    var reader = response_file.readerStreaming(std.testing.io, &reader_buffer);
    const request_file = try tmp.dir.createFile(std.testing.io, "requests", .{});
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
    defer {
        for (client.events.items) |*event| event.deinit(allocator);
        client.events.deinit(allocator);
        for (client.extension_runtimes.items) |*runtime| runtime.deinit(allocator);
        client.extension_runtimes.deinit(allocator);
    }
    try client.extension_runtimes.append(
        allocator,
        try SessionExtensionRuntime.init(
            allocator,
            "s1",
            session_types.CreateSessionConfig{},
            &.{},
        ),
    );
    try fillRequiredEventQueue(&client, allocator, "s1");
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"sessionId":"s1","event":{"type":"permission.requested","data":{"requestId":"overflow","permissionRequest":{"kind":"shell","fullCommandText":"pwd","intention":"show directory","commands":[],"possiblePaths":[],"possibleUrls":[],"hasWriteFileRedirection":false,"canOfferSessionApproval":false}}}}
    ,
        .{},
    );
    defer parsed.deinit();

    try client.queueSessionEvent(parsed.value);
    for (0..max_queued_events) |_| {
        var retained = try (Session{ .client = &client, .id = "s1" }).nextEvent();
        retained.deinit(allocator);
    }
    try std.testing.expectError(
        error.EventQueueRejectionFailed,
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
        \\{"jsonrpc":"2.0","id":1,"method":"session.create","params":{"sessionId":"created","streaming":false,"includeSubAgentStreamingEvents":true,"tools":[],"customAgents":[{"name":"reviewer","displayName":"Code reviewer","description":"Reviews code.","tools":["read"],"prompt":"Review.","mcpServers":{"docs":{"type":"stdio","command":"docs-mcp","args":["--stdio"],"env":{"TOKEN":"secret"},"cwd":"/repo","tools":["lookup"],"timeout":25}},"infer":false,"skills":["review"],"model":"gpt-5.4","reasoningEffort":"xhigh"}],"defaultAgent":{"excludedTools":["deploy"]},"agent":"reviewer","customAgentsLocalOnly":true,"excludedBuiltinAgents":["explore"],"toolFilterPrecedence":"excluded","requestPermission":false,"requestUserInput":false,"requestElicitation":false,"requestExitPlanMode":false,"requestAutoModeSwitch":false,"enableManagedSettings":false}}
    , create_body);
    const resume_body = try json_rpc.readFrame(allocator, &frames);
    defer allocator.free(resume_body);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":2,"method":"session.resume","params":{"sessionId":"session-1","streaming":false,"includeSubAgentStreamingEvents":true,"tools":[],"customAgents":[{"name":"docs","prompt":"Answer from docs.","mcpServers":{"search":{"type":"sse","url":"https://example.test/mcp","headers":{"Authorization":"secret"},"tools":["search"],"timeout":50}}}],"agent":"docs","toolFilterPrecedence":"excluded","requestPermission":false,"requestUserInput":false,"requestElicitation":false,"requestExitPlanMode":false,"requestAutoModeSwitch":false,"enableManagedSettings":false}}
    , resume_body);
    const join_body = try json_rpc.readFrame(allocator, &frames);
    defer allocator.free(join_body);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":3,"method":"session.resume","params":{"sessionId":"parent-session","streaming":false,"includeSubAgentStreamingEvents":true,"tools":[],"customAgents":[{"name":"parent-reviewer","displayName":"Parent reviewer","description":"Reviews the parent session.","tools":["read"],"prompt":"Review the parent.","mcpServers":{"parent-docs":{"type":"stdio","command":"parent-mcp","args":["--stdio"],"env":{"TOKEN":"secret"},"cwd":"/parent","tools":["lookup"],"timeout":75}},"infer":true,"skills":["review"],"model":"gpt-5.4","reasoningEffort":"max"}],"defaultAgent":{"excludedTools":["write"]},"agent":"parent-reviewer","customAgentsLocalOnly":false,"excludedBuiltinAgents":["task"],"toolFilterPrecedence":"excluded","requestPermission":true,"requestUserInput":false,"requestElicitation":false,"requestExitPlanMode":false,"requestAutoModeSwitch":false,"enableManagedSettings":false,"disableResume":true}}
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
        "{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"session.create\",\"params\":{\"sessionId\":\"session-provider-graph\",\"providers\":[{\"name\":\"openai\",\"type\":\"openai\",\"wireApi\":\"responses\",\"transport\":\"websockets\",\"baseUrl\":\"https://api.openai.com/v1\",\"apiKey\":\"key\",\"bearerToken\":\"static\",\"headers\":{\"X-Tenant\":\"acme\"},\"hasBearerTokenProvider\":true}],\"models\":[{\"id\":\"reasoner\",\"provider\":\"openai\",\"wireModel\":\"deployment\",\"modelId\":\"gpt-4.1\",\"name\":\"Reasoner\",\"maxPromptTokens\":100,\"maxContextWindowTokens\":200,\"maxOutputTokens\":50,\"capabilities\":{\"supports\":{\"reasoningEffort\":true}}}],\"streaming\":false,\"includeSubAgentStreamingEvents\":true,\"tools\":[],\"toolFilterPrecedence\":\"excluded\",\"requestPermission\":false,\"requestUserInput\":false,\"requestElicitation\":false,\"requestExitPlanMode\":false,\"requestAutoModeSwitch\":false,\"enableManagedSettings\":false}}",
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
        "{\"jsonrpc\":\"2.0\",\"id\":22,\"method\":\"session.resume\",\"params\":{\"sessionId\":\"session-provider-graph\",\"providers\":[{\"name\":\"openai\",\"type\":\"openai\",\"wireApi\":\"responses\",\"transport\":\"websockets\",\"baseUrl\":\"https://api.openai.com/v1\",\"apiKey\":\"key\",\"bearerToken\":\"static\",\"headers\":{\"X-Tenant\":\"acme\"},\"hasBearerTokenProvider\":true}],\"models\":[{\"id\":\"reasoner\",\"provider\":\"openai\",\"wireModel\":\"deployment\",\"modelId\":\"gpt-4.1\",\"name\":\"Reasoner\",\"maxPromptTokens\":100,\"maxContextWindowTokens\":200,\"maxOutputTokens\":50,\"capabilities\":{\"supports\":{\"reasoningEffort\":true}}}],\"streaming\":false,\"includeSubAgentStreamingEvents\":true,\"tools\":[],\"toolFilterPrecedence\":\"excluded\",\"requestPermission\":false,\"requestUserInput\":false,\"requestElicitation\":false,\"requestExitPlanMode\":false,\"requestAutoModeSwitch\":false,\"enableManagedSettings\":false,\"disableResume\":true}}",
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
        "{\"jsonrpc\":\"2.0\",\"id\":23,\"method\":\"session.create\",\"params\":{\"sessionId\":\"singular\",\"provider\":{\"type\":\"openai\",\"wireApi\":\"responses\",\"transport\":\"websockets\",\"baseUrl\":\"https://api.example.test\",\"apiKey\":\"key\",\"bearerToken\":\"static\",\"headers\":{\"X-Region\":\"west\"},\"modelId\":\"gpt-4.1\",\"modelCapabilities\":{\"supports\":{\"vision\":true}},\"providerName\":\"telemetry\",\"wireModel\":\"deployment\",\"maxPromptTokens\":100,\"maxContextWindowTokens\":200,\"maxOutputTokens\":50,\"hasBearerTokenProvider\":true},\"streaming\":false,\"includeSubAgentStreamingEvents\":true,\"tools\":[],\"toolFilterPrecedence\":\"excluded\",\"requestPermission\":false,\"requestUserInput\":false,\"requestElicitation\":false,\"requestExitPlanMode\":false,\"requestAutoModeSwitch\":false,\"enableManagedSettings\":false}}",
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
        "{\"jsonrpc\":\"2.0\",\"id\":24,\"method\":\"session.resume\",\"params\":{\"sessionId\":\"singular\",\"provider\":{\"type\":\"openai\",\"wireApi\":\"responses\",\"transport\":\"websockets\",\"baseUrl\":\"https://api.example.test\",\"apiKey\":\"key\",\"bearerToken\":\"static\",\"headers\":{\"X-Region\":\"west\"},\"modelId\":\"gpt-4.1\",\"modelCapabilities\":{\"supports\":{\"vision\":true}},\"providerName\":\"telemetry\",\"wireModel\":\"deployment\",\"maxPromptTokens\":100,\"maxContextWindowTokens\":200,\"maxOutputTokens\":50,\"hasBearerTokenProvider\":true},\"streaming\":false,\"includeSubAgentStreamingEvents\":true,\"tools\":[],\"toolFilterPrecedence\":\"excluded\",\"requestPermission\":false,\"requestUserInput\":false,\"requestElicitation\":false,\"requestExitPlanMode\":false,\"requestAutoModeSwitch\":false,\"enableManagedSettings\":false,\"disableResume\":true}}",
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
        const defaults = ",\"streaming\":false,\"includeSubAgentStreamingEvents\":true,\"tools\":[],\"toolFilterPrecedence\":\"excluded\",\"requestPermission\":false,\"requestUserInput\":false,\"requestElicitation\":false,\"requestExitPlanMode\":false,\"requestAutoModeSwitch\":false,\"enableManagedSettings\":false";
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
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.create\",\"params\":{\"sessionId\":\"early-create\",\"provider\":{\"type\":\"openai\",\"wireApi\":\"completions\",\"baseUrl\":\"https://example.test\",\"providerName\":\"attribution-only\",\"hasBearerTokenProvider\":true},\"streaming\":false,\"includeSubAgentStreamingEvents\":true,\"tools\":[],\"toolFilterPrecedence\":\"excluded\",\"requestPermission\":false,\"requestUserInput\":false,\"requestElicitation\":false,\"requestExitPlanMode\":false,\"requestAutoModeSwitch\":false,\"enableManagedSettings\":false}}",
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
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.resume\",\"params\":{\"sessionId\":\"early-resume\",\"providers\":[{\"name\":\"first\",\"type\":\"openai\",\"wireApi\":\"completions\",\"baseUrl\":\"https://first.test\",\"hasBearerTokenProvider\":true},{\"name\":\"second\",\"type\":\"openai\",\"wireApi\":\"completions\",\"baseUrl\":\"https://second.test\",\"hasBearerTokenProvider\":true}],\"models\":[{\"id\":\"one\",\"provider\":\"first\"},{\"id\":\"two\",\"provider\":\"second\"}],\"streaming\":false,\"includeSubAgentStreamingEvents\":true,\"tools\":[],\"toolFilterPrecedence\":\"excluded\",\"requestPermission\":false,\"requestUserInput\":false,\"requestElicitation\":false,\"requestExitPlanMode\":false,\"requestAutoModeSwitch\":false,\"enableManagedSettings\":false,\"disableResume\":true}}",
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

test "provider token dispatch wipes callback and response allocations" {
    const secret = "provider-secret-token";
    const TrackingAllocator = struct {
        backing: std.mem.Allocator,
        token_ptr: ?[*]u8 = null,
        response_len: usize,
        token_wiped: bool = false,
        response_wiped: bool = false,

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            } };
        }

        fn alloc(
            context: *anyopaque,
            len: usize,
            alignment: std.mem.Alignment,
            return_address: usize,
        ) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.backing.rawAlloc(len, alignment, return_address);
        }

        fn resize(
            context: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            new_len: usize,
            return_address: usize,
        ) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.backing.rawResize(memory, alignment, new_len, return_address);
        }

        fn remap(
            context: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            new_len: usize,
            return_address: usize,
        ) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.backing.rawRemap(memory, alignment, new_len, return_address);
        }

        fn free(
            context: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            return_address: usize,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            const wiped = for (memory) |byte| {
                if (byte != 0) break false;
            } else true;
            if (self.token_ptr) |token_ptr| {
                if (memory.ptr == token_ptr) self.token_wiped = wiped;
            }
            if (memory.len == self.response_len and
                (self.token_ptr == null or memory.ptr != self.token_ptr.?))
            {
                self.response_wiped = self.response_wiped or wiped;
            }
            self.backing.rawFree(memory, alignment, return_address);
        }
    };
    const CallbackContext = struct {
        tracker: *TrackingAllocator,
    };
    const callback = struct {
        fn getToken(
            allocator: std.mem.Allocator,
            _: provider.ProviderTokenRequest,
            context: ?*anyopaque,
        ) ![]u8 {
            const state: *CallbackContext = @ptrCast(@alignCast(context.?));
            const token = try allocator.dupe(u8, secret);
            state.tracker.token_ptr = token.ptr;
            return token;
        }
    }.getToken;
    const expected_response =
        \\{"jsonrpc":"2.0","id":1,"result":{"token":"provider-secret-token"}}
    ;

    for ([_]bool{ false, true }) |fail_write| {
        var tracker = TrackingAllocator{
            .backing = std.testing.allocator,
            .response_len = expected_response.len,
        };
        const allocator = tracker.allocator();
        var callback_context = CallbackContext{ .tracker = &tracker };
        var client: Client = undefined;
        client.allocator = allocator;
        client.writer_buffer = &.{};
        client.pending_extension_runtime = null;
        client.extension_runtimes = .empty;
        client.provider_tokens = .empty;
        defer {
            for (client.provider_tokens.items) |registered| registered.deinit(allocator);
            client.provider_tokens.deinit(allocator);
        }
        try client.registerProviderTokens("s1", &.{.{
            .provider_name = "provider",
            .token_provider = .{
                .callback = callback,
                .context = &callback_context,
            },
        }});
        const params = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            \\{"sessionId":"s1","providerName":"provider"}
        ,
            .{},
        );
        defer params.deinit();
        var output_bytes: [512]u8 = undefined;
        var output = if (fail_write)
            std.Io.Writer{
                .vtable = &.{ .drain = std.Io.Writer.failingDrain },
                .buffer = output_bytes[0..1],
            }
        else
            std.Io.Writer.fixed(&output_bytes);

        if (fail_write) {
            try std.testing.expectError(
                error.WriteFailed,
                client.dispatchProviderTokenRequest(
                    &output,
                    .{ .integer = 1 },
                    params.value,
                ),
            );
        } else {
            try client.dispatchProviderTokenRequest(
                &output,
                .{ .integer = 1 },
                params.value,
            );
            try std.testing.expect(
                std.mem.indexOf(u8, output.buffered(), secret) != null,
            );
        }
        try std.testing.expect(tracker.token_wiped);
        try std.testing.expect(tracker.response_wiped);
    }
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
        try writer.interface.flush();
        const requests = try tmp.dir.readFileAlloc(
            std.testing.io,
            "request",
            allocator,
            .limited(4096),
        );
        defer allocator.free(requests);
        try std.testing.expect(
            std.mem.indexOf(u8, requests, "\"method\":\"session.detach\"") == null,
        );
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
