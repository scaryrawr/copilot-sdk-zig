const std = @import("std");
const builtin = @import("builtin");
const json_rpc = @import("json_rpc.zig");
const models = @import("models.zig");
const provider = @import("provider.zig");
const protocol = @import("protocol_version.zig");
const runtime_types = @import("runtime.zig");
const session_types = @import("session.zig");
const ext = @import("extensibility.zig");

const max_queued_events: usize = 1024;
const teardown_oauth_release_timeout = std.Io.Duration.fromMilliseconds(250);

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
    connection: ?runtime_types.RuntimeConnection = null,
    on_list_models: ?runtime_types.ModelListCallback = null,
    on_get_trace_context: ?runtime_types.TraceContextCallback = null,
    session_filesystem: ?runtime_types.SessionFilesystemConfig = null,
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
    traceparent: ?[]const u8 = null,
    tracestate: ?[]const u8 = null,
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
    trace_context: runtime_types.TraceContext,
) WireSendRequest {
    return .{
        .sessionId = session_id,
        .prompt = options.prompt,
        .attachments = if (options.attachments) |values|
            .{ .values = values }
        else
            null,
        .traceparent = trace_context.traceparent,
        .tracestate = trace_context.tracestate,
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

const FileTransport = struct {
    reader: std.Io.File.Reader,
    writer: std.Io.File.Writer,
    reader_buffer: []u8,
    writer_buffer: []u8,
};

const SocketTransport = struct {
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    reader_buffer: []u8,
    writer_buffer: []u8,
};

const Transport = union(enum) {
    none,
    stdio_child: struct {
        child: std.process.Child,
        io: FileTransport,
    },
    tcp_child: struct {
        child: std.process.Child,
        io: SocketTransport,
        port: u16,
    },
    uri: struct {
        io: SocketTransport,
        port: u16,
    },
    parent_stdio: FileTransport,
    fixture: struct {
        reader: ?*std.Io.File.Reader,
        writer: ?*std.Io.File.Writer,
        reader_buffer: []u8,
        writer_buffer: []u8,
        owns_allocations: bool = false,
    },

    fn reader(self: *Transport) *std.Io.Reader {
        return switch (self.*) {
            .none => unreachable,
            .stdio_child => |*value| &value.io.reader.interface,
            .tcp_child => |*value| &value.io.reader.interface,
            .uri => |*value| &value.io.reader.interface,
            .parent_stdio => |*value| &value.reader.interface,
            .fixture => |value| &value.reader.?.interface,
        };
    }

    fn writer(self: *Transport) *std.Io.Writer {
        return switch (self.*) {
            .none => unreachable,
            .stdio_child => |*value| &value.io.writer.interface,
            .tcp_child => |*value| &value.io.writer.interface,
            .uri => |*value| &value.io.writer.interface,
            .parent_stdio => |*value| &value.writer.interface,
            .fixture => |value| &value.writer.?.interface,
        };
    }

    fn writerBuffer(self: *Transport) []u8 {
        return switch (self.*) {
            .none => &.{},
            .stdio_child => |*value| value.io.writer_buffer,
            .tcp_child => |*value| value.io.writer_buffer,
            .uri => |*value| value.io.writer_buffer,
            .parent_stdio => |*value| value.writer_buffer,
            .fixture => |value| value.writer_buffer,
        };
    }

    fn port(self: *const Transport) ?u16 {
        return switch (self.*) {
            .tcp_child => |value| value.port,
            .uri => |value| value.port,
            .none, .stdio_child, .parent_stdio, .fixture => null,
        };
    }

    fn deinit(self: *Transport, allocator: std.mem.Allocator, io: std.Io) void {
        switch (self.*) {
            .none => {},
            .stdio_child => |*value| {
                value.child.kill(io);
                wipeSecret(value.io.reader_buffer);
                wipeSecret(value.io.writer_buffer);
                allocator.free(value.io.reader_buffer);
                allocator.free(value.io.writer_buffer);
            },
            .tcp_child => |*value| {
                value.io.stream.close(io);
                value.child.kill(io);
                wipeSecret(value.io.reader_buffer);
                wipeSecret(value.io.writer_buffer);
                allocator.free(value.io.reader_buffer);
                allocator.free(value.io.writer_buffer);
            },
            .uri => |*value| {
                value.io.stream.close(io);
                wipeSecret(value.io.reader_buffer);
                wipeSecret(value.io.writer_buffer);
                allocator.free(value.io.reader_buffer);
                allocator.free(value.io.writer_buffer);
            },
            .parent_stdio => |*value| {
                wipeSecret(value.reader_buffer);
                wipeSecret(value.writer_buffer);
                allocator.free(value.reader_buffer);
                allocator.free(value.writer_buffer);
            },
            .fixture => |value| {
                wipeSecret(value.reader_buffer);
                wipeSecret(value.writer_buffer);
                if (value.owns_allocations) {
                    if (value.reader) |fixture_reader| allocator.destroy(fixture_reader);
                    if (value.writer) |fixture_writer| allocator.destroy(fixture_writer);
                    if (value.reader_buffer.len != 0) allocator.free(value.reader_buffer);
                    if (value.writer_buffer.len != 0) allocator.free(value.writer_buffer);
                }
            },
        }
        self.* = undefined;
    }
};

const ResolvedConnection = union(enum) {
    stdio: struct {
        child: runtime_types.ChildRuntime,
        token: ?[]const u8,
    },
    tcp: struct {
        child: runtime_types.ChildRuntime,
        port: u16,
        token: ?[]const u8,
    },
    uri: struct {
        host: []const u8,
        port: u16,
        token: ?[]const u8,
        mode: runtime_types.RuntimeMode,
    },
};

const DefaultConnection = enum {
    stdio,
    inprocess,
};

const ParsedUri = struct {
    host: []const u8,
    port: u16,
};

const managed_environment_keys = [_][]const u8{
    "COPILOT_SDK_AUTH_TOKEN",
    "COPILOT_CONNECTION_TOKEN",
    "COPILOT_HOME",
    "COPILOT_DISABLE_KEYTAR",
    "COPILOT_OTEL_ENABLED",
    "OTEL_EXPORTER_OTLP_ENDPOINT",
    "OTEL_EXPORTER_OTLP_PROTOCOL",
    "COPILOT_OTEL_FILE_EXPORTER_PATH",
    "COPILOT_OTEL_EXPORTER_TYPE",
    "COPILOT_OTEL_SOURCE_NAME",
    "OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT",
};

const RegisteredSessionFilesystem = struct {
    session_id: []u8,
    provider: runtime_types.SessionFilesystemProvider,

    fn deinit(self: *RegisteredSessionFilesystem, allocator: std.mem.Allocator) void {
        if (self.provider.deinit) |deinit_provider| {
            deinit_provider(self.provider.context);
        }
        allocator.free(self.session_id);
    }
};

fn parseDefaultConnection(value: ?[]const u8) !DefaultConnection {
    const configured = value orelse return .stdio;
    if (std.ascii.eqlIgnoreCase(configured, "stdio")) return .stdio;
    if (std.ascii.eqlIgnoreCase(configured, "inprocess")) return .inprocess;
    return error.InvalidDefaultConnection;
}

fn resolveConnection(
    options: ClientOptions,
    default_connection: DefaultConnection,
) !ResolvedConnection {
    if (options.connection) |connection| {
        return switch (connection) {
            .stdio => |value| .{ .stdio = .{
                .child = value.runtime,
                .token = null,
            } },
            .tcp => |value| .{ .tcp = .{
                .child = value.runtime,
                .port = value.port,
                .token = value.connection_token,
            } },
            .uri => |value| blk: {
                const parsed = try parseRuntimeUri(value.uri);
                break :blk .{ .uri = .{
                    .host = parsed.host,
                    .port = parsed.port,
                    .token = value.connection_token,
                    .mode = value.mode,
                } };
            },
        };
    }
    if (default_connection == .inprocess)
        return error.UnsupportedInProcessConnection;
    return .{ .stdio = .{
        .child = .{
            .executable = options.cli_path,
            .args = options.cli_args,
            .working_directory = options.working_directory,
        },
        .token = options.connection_token,
    } };
}

fn connectionMode(connection: ResolvedConnection) runtime_types.RuntimeMode {
    return switch (connection) {
        .stdio => |value| value.child.mode,
        .tcp => |value| value.child.mode,
        .uri => |value| value.mode,
    };
}

fn connectionToken(connection: ResolvedConnection) ?[]const u8 {
    return switch (connection) {
        .stdio => |value| value.token,
        .tcp => |value| value.token,
        .uri => |value| value.token,
    };
}

fn needsGeneratedConnectionToken(connection: ResolvedConnection) bool {
    return switch (connection) {
        .tcp => |value| value.token == null,
        .stdio, .uri => false,
    };
}

fn validateClientOptions(options: ClientOptions, connection: ResolvedConnection) !void {
    if (options.connection != null and
        (!std.mem.eql(u8, options.cli_path, "copilot") or
            options.working_directory != null or
            options.cli_args.len != 0 or
            options.connection_token != null))
    {
        return error.ConflictingConnectionOptions;
    }

    if (options.builtin_plugin_directories.len > 64)
        return error.TooManyBuiltinPluginDirectories;
    for (options.builtin_plugin_directories, 0..) |directory, index| {
        if (!std.fs.path.isAbsolute(directory) or directory.len > 4096)
            return error.InvalidBuiltinPluginDirectory;
        for (options.builtin_plugin_directories[0..index]) |previous| {
            if (std.mem.eql(u8, previous, directory))
                return error.DuplicateBuiltinPluginDirectory;
        }
    }

    if (options.session_filesystem) |filesystem| {
        if (filesystem.initial_working_directory.len == 0)
            return error.InvalidSessionFilesystemInitialWorkingDirectory;
        if (filesystem.session_state_path.len == 0)
            return error.InvalidSessionFilesystemStatePath;
    }

    switch (connection) {
        .uri => |value| {
            if (value.token) |token| {
                if (token.len == 0) return error.InvalidConnectionToken;
            }
        },
        .stdio => |value| {
            try validateChildRuntime(value.child, options.session_filesystem != null);
        },
        .tcp => |value| {
            try validateChildRuntime(value.child, options.session_filesystem != null);
            if (value.token) |token| {
                if (token.len == 0) return error.InvalidConnectionToken;
            }
        },
    }
}

fn validateChildRuntime(
    child_runtime: runtime_types.ChildRuntime,
    has_session_filesystem: bool,
) !void {
    if (child_runtime.executable.len == 0) return error.InvalidRuntimeExecutable;
    if (child_runtime.base_directory) |directory| {
        if (directory.len == 0) return error.InvalidBaseDirectory;
    }
    switch (child_runtime.authentication) {
        .token, .token_and_logged_in_user => |token| {
            if (token.len == 0) return error.InvalidGitHubToken;
        },
        .default, .logged_in_user, .disabled => {},
    }
    if (child_runtime.mode == .empty and
        child_runtime.base_directory == null and
        !has_session_filesystem)
    {
        return error.EmptyModeRequiresPersistence;
    }
    const environment = child_runtime.environment orelse return;
    for (environment, 0..) |entry, index| {
        if (!std.process.Environ.Map.validateKeyForPut(entry.name) or
            std.mem.indexOfScalar(u8, entry.value, 0) != null)
        {
            return error.InvalidEnvironmentVariable;
        }
        for (managed_environment_keys) |managed| {
            if (environmentKeyEql(entry.name, managed))
                return error.ManagedEnvironmentVariable;
        }
        for (environment[0..index]) |previous| {
            if (environmentKeyEql(entry.name, previous.name))
                return error.DuplicateEnvironmentVariable;
        }
    }
}

fn environmentKeyEql(a: []const u8, b: []const u8) bool {
    return if (builtin.os.tag == .windows)
        std.ascii.eqlIgnoreCase(a, b)
    else
        std.mem.eql(u8, a, b);
}

fn parseRuntimeUri(uri: []const u8) !ParsedUri {
    var value = uri;
    if (std.mem.startsWith(u8, value, "http://")) {
        value = value["http://".len..];
    } else if (std.mem.startsWith(u8, value, "https://")) {
        value = value["https://".len..];
    }
    if (value.len == 0 or std.mem.indexOfScalar(u8, value, '/') != null)
        return error.InvalidRuntimeUri;

    if (value[0] == '[') {
        const close = std.mem.indexOfScalar(u8, value, ']') orelse
            return error.InvalidRuntimeUri;
        if (close + 2 > value.len or value[close + 1] != ':')
            return error.InvalidRuntimeUri;
        return .{
            .host = value[1..close],
            .port = try parsePort(value[close + 2 ..]),
        };
    }
    if (std.mem.indexOfScalar(u8, value, ':')) |colon| {
        if (std.mem.indexOfScalarPos(u8, value, colon + 1, ':') != null)
            return error.InvalidRuntimeUri;
        return .{
            .host = if (colon == 0) "localhost" else value[0..colon],
            .port = try parsePort(value[colon + 1 ..]),
        };
    }
    return .{
        .host = "localhost",
        .port = try parsePort(value),
    };
}

fn parsePort(value: []const u8) !u16 {
    if (value.len == 0) return error.InvalidRuntimeUri;
    const port = std.fmt.parseUnsigned(u16, value, 10) catch
        return error.InvalidRuntimeUri;
    if (port == 0) return error.InvalidRuntimeUri;
    return port;
}

fn openTransport(
    allocator: std.mem.Allocator,
    io: std.Io,
    connection: ResolvedConnection,
    effective_token: ?[]const u8,
) !Transport {
    return switch (connection) {
        .stdio => |value| try spawnStdio(
            allocator,
            io,
            value.child,
            effective_token,
        ),
        .tcp => |value| try spawnTcp(
            allocator,
            io,
            value.child,
            value.port,
            effective_token,
        ),
        .uri => |value| blk: {
            const stream = try connectToHostBounded(io, value.host, value.port);
            errdefer stream.close(io);
            break :blk try externalUriTransport(allocator, io, stream, value.port);
        },
    };
}

fn spawnStdio(
    allocator: std.mem.Allocator,
    io: std.Io,
    child_runtime: runtime_types.ChildRuntime,
    connection_token: ?[]const u8,
) !Transport {
    var port_buffer: [5]u8 = undefined;
    var timeout_buffer: [10]u8 = undefined;
    var argv = try buildRuntimeArgv(
        allocator,
        child_runtime,
        .stdio,
        0,
        &port_buffer,
        &timeout_buffer,
    );
    defer argv.deinit(allocator);
    var environment = try buildRuntimeEnvironment(
        allocator,
        child_runtime,
        connection_token,
    );
    defer deinitEnvironment(&environment);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = if (child_runtime.working_directory) |cwd| .{ .path = cwd } else .inherit,
        .environ_map = &environment,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    errdefer child.kill(io);

    const reader_buffer = try allocator.alloc(u8, 8192);
    errdefer allocator.free(reader_buffer);
    const writer_buffer = try allocator.alloc(u8, 8192);
    errdefer allocator.free(writer_buffer);
    return .{ .stdio_child = .{
        .child = child,
        .io = .{
            .reader = child.stdout.?.readerStreaming(io, reader_buffer),
            .writer = child.stdin.?.writerStreaming(io, writer_buffer),
            .reader_buffer = reader_buffer,
            .writer_buffer = writer_buffer,
        },
    } };
}

fn spawnTcp(
    allocator: std.mem.Allocator,
    io: std.Io,
    child_runtime: runtime_types.ChildRuntime,
    requested_port: u16,
    connection_token: ?[]const u8,
) !Transport {
    var port_buffer: [5]u8 = undefined;
    var timeout_buffer: [10]u8 = undefined;
    var argv = try buildRuntimeArgv(
        allocator,
        child_runtime,
        .tcp,
        requested_port,
        &port_buffer,
        &timeout_buffer,
    );
    defer argv.deinit(allocator);
    var environment = try buildRuntimeEnvironment(
        allocator,
        child_runtime,
        connection_token,
    );
    defer deinitEnvironment(&environment);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = if (child_runtime.working_directory) |cwd| .{ .path = cwd } else .inherit,
        .environ_map = &environment,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    errdefer child.kill(io);

    const announced_port = try readAnnouncedPortBounded(allocator, io, &child);
    child.stdout.?.close(io);
    child.stdout = null;
    if (requested_port != 0 and announced_port != requested_port)
        return error.RuntimePortMismatch;
    const port = announced_port;
    const stream = try connectToHostWithRetry(io, "localhost", port);
    errdefer stream.close(io);
    return ownedTcpTransport(allocator, io, stream, port, child);
}

fn allocateSocketTransport(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
) !SocketTransport {
    const reader_buffer = try allocator.alloc(u8, 8192);
    errdefer allocator.free(reader_buffer);
    const writer_buffer = try allocator.alloc(u8, 8192);
    errdefer allocator.free(writer_buffer);
    return .{
        .stream = stream,
        .reader = stream.reader(io, reader_buffer),
        .writer = stream.writer(io, writer_buffer),
        .reader_buffer = reader_buffer,
        .writer_buffer = writer_buffer,
    };
}

fn ownedTcpTransport(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    port: u16,
    child: std.process.Child,
) !Transport {
    return .{ .tcp_child = .{
        .child = child,
        .io = try allocateSocketTransport(allocator, io, stream),
        .port = port,
    } };
}

fn externalUriTransport(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    port: u16,
) !Transport {
    return .{ .uri = .{
        .io = try allocateSocketTransport(allocator, io, stream),
        .port = port,
    } };
}

const RuntimeTransportKind = enum { stdio, tcp };

fn buildRuntimeArgv(
    allocator: std.mem.Allocator,
    child_runtime: runtime_types.ChildRuntime,
    transport_kind: RuntimeTransportKind,
    port: u16,
    port_buffer: *[5]u8,
    timeout_buffer: *[10]u8,
) !std.ArrayList([]const u8) {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(allocator);
    try argv.append(allocator, child_runtime.executable);
    try argv.appendSlice(allocator, child_runtime.args);
    try argv.appendSlice(allocator, &.{ "--headless", "--no-auto-update" });
    if (child_runtime.log_level) |level| {
        try argv.appendSlice(allocator, &.{ "--log-level", level.wireValue() });
    }
    switch (transport_kind) {
        .stdio => try argv.append(allocator, "--stdio"),
        .tcp => if (port != 0) {
            const port_text = try std.fmt.bufPrint(port_buffer, "{d}", .{port});
            try argv.appendSlice(allocator, &.{ "--port", port_text });
        },
    }
    switch (child_runtime.authentication) {
        .token, .token_and_logged_in_user => {
            try argv.appendSlice(allocator, &.{
                "--auth-token-env",
                "COPILOT_SDK_AUTH_TOKEN",
            });
        },
        .default, .logged_in_user, .disabled => {},
    }
    switch (child_runtime.authentication) {
        .token, .disabled => try argv.append(allocator, "--no-auto-login"),
        .default, .logged_in_user, .token_and_logged_in_user => {},
    }
    if (child_runtime.session_idle_timeout_seconds != 0) {
        const timeout = try std.fmt.bufPrint(
            timeout_buffer,
            "{d}",
            .{child_runtime.session_idle_timeout_seconds},
        );
        try argv.appendSlice(allocator, &.{ "--session-idle-timeout", timeout });
    }
    if (child_runtime.enable_remote_sessions) {
        try argv.append(allocator, "--remote");
    }
    return argv;
}

fn buildRuntimeEnvironment(
    allocator: std.mem.Allocator,
    child_runtime: runtime_types.ChildRuntime,
    connection_token: ?[]const u8,
) !std.process.Environ.Map {
    var result = if (child_runtime.environment) |_|
        std.process.Environ.Map.init(allocator)
    else
        try inheritedEnvironmentMap(allocator);
    errdefer deinitEnvironment(&result);
    if (child_runtime.environment) |environment| {
        for (environment) |entry| {
            try result.put(entry.name, entry.value);
        }
    }
    _ = result.swapRemove("NODE_DEBUG");
    switch (child_runtime.authentication) {
        .token, .token_and_logged_in_user => |token| {
            try result.put("COPILOT_SDK_AUTH_TOKEN", token);
        },
        .default, .logged_in_user, .disabled => {},
    }
    if (connection_token) |token| {
        try result.put("COPILOT_CONNECTION_TOKEN", token);
    }
    if (child_runtime.base_directory) |directory| {
        try result.put("COPILOT_HOME", directory);
    }
    if (child_runtime.mode == .empty) {
        try result.put("COPILOT_DISABLE_KEYTAR", "1");
    }
    if (child_runtime.telemetry) |telemetry| {
        try result.put("COPILOT_OTEL_ENABLED", "true");
        if (telemetry.otlp_endpoint) |value|
            try result.put("OTEL_EXPORTER_OTLP_ENDPOINT", value);
        if (telemetry.otlp_protocol) |value|
            try result.put(
                "OTEL_EXPORTER_OTLP_PROTOCOL",
                switch (value) {
                    .http_json => "http/json",
                    .http_protobuf => "http/protobuf",
                },
            );
        if (telemetry.file_path) |value|
            try result.put("COPILOT_OTEL_FILE_EXPORTER_PATH", value);
        if (telemetry.exporter_type) |value|
            try result.put("COPILOT_OTEL_EXPORTER_TYPE", value);
        if (telemetry.source_name) |value|
            try result.put("COPILOT_OTEL_SOURCE_NAME", value);
        if (telemetry.capture_content) |value|
            try result.put(
                "OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT",
                if (value) "true" else "false",
            );
    }
    return result;
}

fn inheritedEnvironmentMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    return switch (builtin.os.tag) {
        .windows, .wasi, .emscripten => std.process.Environ.createMap(
            .{ .block = .global },
            allocator,
        ),
        else => blk: {
            const entries = std.mem.span(std.c.environ);
            break :blk std.process.Environ.createMap(.{
                .block = .{ .slice = @ptrCast(entries[0..entries.len :null]) },
            }, allocator);
        },
    };
}

fn deinitEnvironment(environment: *std.process.Environ.Map) void {
    for (environment.values()) |value| wipeSecret(value);
    environment.deinit();
}

fn readAnnouncedPort(
    allocator: std.mem.Allocator,
    io: std.Io,
    child: *std.process.Child,
) !u16 {
    const buffer = try allocator.alloc(u8, 4096);
    defer allocator.free(buffer);
    var reader = child.stdout.?.readerStreaming(io, buffer);
    while (try reader.interface.takeDelimiter('\n')) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        const marker = "listening on port ";
        const marker_index = std.ascii.indexOfIgnoreCase(line, marker) orelse continue;
        const port_text = std.mem.trim(
            u8,
            line[marker_index + marker.len ..],
            " \t\r\n",
        );
        return std.fmt.parseUnsigned(u16, port_text, 10) catch
            return error.InvalidRuntimePortAnnouncement;
    }
    return error.MissingRuntimePortAnnouncement;
}

fn readAnnouncedPortBounded(
    allocator: std.mem.Allocator,
    io: std.Io,
    child: *std.process.Child,
) !u16 {
    const Result = union(enum) {
        port: anyerror!u16,
        timeout: anyerror!void,
    };
    var result_buffer: [2]Result = undefined;
    var select = std.Io.Select(Result).init(io, &result_buffer);
    defer select.cancelDiscard();
    select.async(.port, readAnnouncedPort, .{ allocator, io, child });
    select.async(.timeout, std.Io.sleep, .{
        io,
        std.Io.Duration.fromSeconds(10),
        std.Io.Clock.awake,
    });
    return switch (try select.await()) {
        .port => |result| try result,
        .timeout => |result| {
            try result;
            return error.RuntimeStartupTimeout;
        },
    };
}

fn connectToHostWithRetry(io: std.Io, host: []const u8, port: u16) !std.Io.net.Stream {
    var last_error: anyerror = error.ConnectionRefused;
    for (0..100) |_| {
        return connectToHost(io, host, port) catch |err| {
            last_error = err;
            try std.Io.sleep(io, .fromMilliseconds(10), .awake);
            continue;
        };
    }
    return last_error;
}

fn connectToHostBounded(io: std.Io, host: []const u8, port: u16) !std.Io.net.Stream {
    const Result = union(enum) {
        stream: anyerror!std.Io.net.Stream,
        timeout: anyerror!void,
    };
    var result_buffer: [2]Result = undefined;
    var select = std.Io.Select(Result).init(io, &result_buffer);
    defer select.cancelDiscard();
    select.async(.stream, connectToHost, .{ io, host, port });
    select.async(.timeout, std.Io.sleep, .{
        io,
        std.Io.Duration.fromSeconds(10),
        std.Io.Clock.awake,
    });
    return switch (try select.await()) {
        .stream => |result| try result,
        .timeout => |result| {
            try result;
            return error.RuntimeConnectionTimeout;
        },
    };
}

fn connectToHost(io: std.Io, host: []const u8, port: u16) !std.Io.net.Stream {
    if (std.mem.eql(u8, host, "localhost")) {
        const address = std.Io.net.IpAddress{ .ip4 = .loopback(port) };
        return address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    }
    if (std.Io.net.IpAddress.parse(host, port)) |address| {
        return address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    } else |_| {}

    const hostname = try std.Io.net.HostName.init(host);
    var lookup_buffer: [32]std.Io.net.HostName.LookupResult = undefined;
    var lookup_queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&lookup_buffer);
    try hostname.lookup(io, &lookup_queue, .{ .port = port });
    var last_error: anyerror = error.NoAddressReturned;
    while (lookup_queue.getOne(io)) |result| {
        switch (result) {
            .canonical_name => {},
            .address => |address| {
                return address.connect(io, .{
                    .mode = .stream,
                    .protocol = .tcp,
                }) catch |err| {
                    last_error = err;
                    continue;
                };
            },
        }
    } else |_| {}
    return last_error;
}

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    transport: Transport = .none,
    on_list_models: ?runtime_types.ModelListCallback = null,
    on_get_trace_context: ?runtime_types.TraceContextCallback = null,
    session_filesystem: ?runtime_types.SessionFilesystemConfig = null,
    mode: runtime_types.RuntimeMode = .copilot_cli,
    session_filesystem_providers: std.ArrayList(RegisteredSessionFilesystem) = .empty,
    pending_session_filesystem_provider: ?RegisteredSessionFilesystem = null,
    next_request_id: u64 = 1,
    session_ids: std.ArrayList([]u8) = .empty,
    events: std.ArrayList(QueuedEvent) = .empty,
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
        var ambient_environment = if (options.connection == null)
            try inheritedEnvironmentMap(allocator)
        else
            null;
        defer if (ambient_environment) |*value| deinitEnvironment(value);
        const default_connection = try parseDefaultConnection(
            if (ambient_environment) |*value|
                value.get("COPILOT_SDK_DEFAULT_CONNECTION")
            else
                null,
        );
        const connection = try resolveConnection(options, default_connection);
        try validateClientOptions(options, connection);
        var generated_token: ?[]u8 = null;
        defer if (generated_token) |token| {
            wipeSecret(token);
            allocator.free(token);
        };
        if (needsGeneratedConnectionToken(connection)) {
            generated_token = try generateSessionId(allocator, io);
        }
        const token = connectionToken(connection) orelse generated_token;
        var client = Client{
            .allocator = allocator,
            .io = io,
            .transport = try openTransport(allocator, io, connection, token),
            .on_list_models = options.on_list_models,
            .on_get_trace_context = options.on_get_trace_context,
            .session_filesystem = options.session_filesystem,
            .mode = connectionMode(connection),
        };
        errdefer client.deinit();
        try client.connect(token, options.client_info);
        try client.setBuiltinPluginDirectories(options.builtin_plugin_directories);
        try client.setSessionFilesystemProvider();
        return client;
    }

    pub fn initParent(allocator: std.mem.Allocator, io: std.Io) !Client {
        const reader_buffer = try allocator.alloc(u8, 8192);
        errdefer allocator.free(reader_buffer);
        const writer_buffer = try allocator.alloc(u8, 8192);
        errdefer allocator.free(writer_buffer);

        var client = Client{
            .allocator = allocator,
            .io = io,
            .transport = .{ .parent_stdio = .{
                .reader = std.Io.File.stdin().readerStreaming(io, reader_buffer),
                .writer = std.Io.File.stdout().writerStreaming(io, writer_buffer),
                .reader_buffer = reader_buffer,
                .writer_buffer = writer_buffer,
            } },
        };
        errdefer client.deinit();
        try client.connect(null, null);
        return client;
    }

    pub fn deinit(self: *Client) void {
        self.releaseInterestsAndDetachSessionsBounded();
        if (self.pending_session_filesystem_provider) |*registered| {
            registered.deinit(self.allocator);
        }
        for (self.session_filesystem_providers.items) |*registered| {
            registered.deinit(self.allocator);
        }
        self.session_filesystem_providers.deinit(self.allocator);
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
        for (self.session_ids.items) |id| self.allocator.free(id);
        self.session_ids.deinit(self.allocator);
        self.transport.deinit(self.allocator, self.io);
        self.* = undefined;
    }

    fn releaseInterestsAndDetachSessionsBounded(self: *Client) void {
        if (!self.hasMcpOAuthInterests() and self.session_ids.items.len == 0) return;
        const Result = union(enum) {
            released: void,
            timeout: anyerror!void,
        };
        var result_buffer: [2]Result = undefined;
        var select = std.Io.Select(Result).init(self.io, &result_buffer);
        defer select.cancelDiscard();
        select.async(.released, Client.releaseInterestsAndDetachSessions, .{self});
        select.async(.timeout, std.Io.sleep, .{
            self.io,
            teardown_oauth_release_timeout,
            std.Io.Clock.awake,
        });
        switch (select.await() catch return) {
            .released => {},
            .timeout => |result| result catch {},
        }
    }

    fn hasMcpOAuthInterests(self: *const Client) bool {
        if (self.pending_extension_runtime) |runtime| {
            if (runtime.mcp_oauth_interest_handle != null) return true;
        }
        for (self.extension_runtimes.items) |runtime| {
            if (runtime.mcp_oauth_interest_handle != null) return true;
        }
        return false;
    }

    fn releaseInterestsAndDetachSessions(self: *Client) void {
        if (self.pending_extension_runtime) |*runtime| {
            self.releaseMcpOAuthInterest(runtime) catch {};
        }
        for (self.extension_runtimes.items) |*runtime| {
            self.releaseMcpOAuthInterest(runtime) catch {};
        }
        for (self.session_ids.items) |session_id| {
            self.detachSessionBestEffort(session_id);
        }
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
        const parsed = try self.call(std.json.Value, "plugins.builtin.set", .{
            .paths = directories,
        });
        parsed.deinit();
    }

    fn setSessionFilesystemProvider(self: *Client) !void {
        const config = self.session_filesystem orelse return;
        const parsed = try self.call(struct {
            success: bool,
        }, "sessionFs.setProvider", .{
            .initialCwd = config.initial_working_directory,
            .sessionStatePath = config.session_state_path,
            .conventions = @tagName(config.conventions),
            .capabilities = .{
                .sqlite = config.sqlite,
            },
        });
        defer parsed.deinit();
        if (!parsed.value.success) return error.SessionFilesystemProviderRejected;
    }

    pub fn runtimePort(self: *const Client) ?u16 {
        return self.transport.port();
    }

    fn traceContext(self: *Client) runtime_types.TraceContext {
        const callback = self.on_get_trace_context orelse return .{};
        return callback.handler(callback.context) catch .{};
    }

    fn transportReader(self: *Client) *std.Io.Reader {
        return self.transport.reader();
    }

    fn transportWriter(self: *Client) *std.Io.Writer {
        return self.transport.writer();
    }

    fn transportWriterBuffer(self: *Client) []u8 {
        return self.transport.writerBuffer();
    }

    fn wipeTransportBuffers(self: *Client) void {
        switch (self.transport) {
            .none => {},
            .stdio_child => |*value| {
                wipeSecret(value.io.reader_buffer);
                wipeSecret(value.io.writer_buffer);
            },
            .tcp_child => |*value| {
                wipeSecret(value.io.reader_buffer);
                wipeSecret(value.io.writer_buffer);
            },
            .uri => |*value| {
                wipeSecret(value.io.reader_buffer);
                wipeSecret(value.io.writer_buffer);
            },
            .parent_stdio => |*value| {
                wipeSecret(value.reader_buffer);
                wipeSecret(value.writer_buffer);
            },
            .fixture => |value| {
                wipeSecret(value.reader_buffer);
                wipeSecret(value.writer_buffer);
            },
        }
    }

    pub fn createSession(
        self: *Client,
        config: session_types.CreateSessionConfig,
    ) !Session {
        try validateSessionMode(self.mode, config.available_tools);
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
        try self.beginSessionFilesystem(owned_session_id);
        errdefer self.rollbackSessionFilesystem();

        var request = try buildPreparedCreateSessionRequest(
            owned_session_id,
            config,
            tools.items,
            &extension_values,
            prepared_providers,
            self.mode,
        );
        const trace_context = self.traceContext();
        request.traceparent = trace_context.traceparent;
        request.tracestate = trace_context.tracestate;
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

        try self.updateSessionOptionsForMode(returned_id, config);
        try self.commitExtensionRuntime(returned_id, parsed.value, &.{});
        self.commitSessionFilesystem(returned_id);
        self.commitProviderTokens();
        return .{ .client = self, .id = owned_session_id };
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
        try validateSessionMode(self.mode, config.available_tools);
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

        try self.beginProviderTokens(runtime_session_id, prepared_providers.token_bindings);
        errdefer self.rollbackProviderTokens();
        try self.beginExtensionRuntime(
            runtime_session_id,
            config,
            config.extensions.open_canvases orelse &.{},
        );
        errdefer self.rollbackExtensionRuntime();
        try self.beginSessionFilesystem(runtime_session_id);
        errdefer self.rollbackSessionFilesystem();

        var request = try buildPreparedResumeSessionRequest(
            runtime_session_id,
            config,
            tools.items,
            &extension_values,
            requested_environment_variables,
            prepared_providers,
            self.mode,
        );
        const trace_context = self.traceContext();
        request.traceparent = trace_context.traceparent;
        request.tracestate = trace_context.tracestate;
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

        try self.updateSessionOptionsForMode(runtime_session_id, config);
        try self.commitExtensionRuntime(
            runtime_session_id,
            parsed.value,
            requested_environment_variables,
        );
        self.commitSessionFilesystem(runtime_session_id);
        self.commitProviderTokens();
        return .{ .client = self, .id = runtime_session_id };
    }

    fn updateSessionOptionsForMode(
        self: *Client,
        session_id: []const u8,
        config: anytype,
    ) !void {
        if (self.mode != .empty) return;
        const parsed = try self.call(struct {
            success: bool,
        }, "session.options.update", SessionOptionsUpdateRequest{
            .sessionId = session_id,
            .skipCustomInstructions = config.skip_custom_instructions orelse true,
            .customAgentsLocalOnly = config.custom_agents_local_only orelse true,
            .coauthorEnabled = false,
            .manageScheduleEnabled = false,
            .includedBuiltinSkills = config.extensions.common.skills.included_builtin orelse &.{},
        });
        defer parsed.deinit();
        if (!parsed.value.success) return error.SessionOptionsUpdateRejected;
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

    fn beginSessionFilesystem(self: *Client, session_id: []const u8) !void {
        const config = self.session_filesystem orelse return;
        if (self.pending_session_filesystem_provider != null)
            return error.SessionLifecycleAlreadyInProgress;
        try self.session_filesystem_providers.ensureUnusedCapacity(self.allocator, 1);
        const owned_session_id = try self.allocator.dupe(u8, session_id);
        errdefer self.allocator.free(owned_session_id);
        const filesystem_provider = try config.create_provider(
            self.allocator,
            session_id,
            config.context,
        );
        if (config.sqlite and filesystem_provider.sqlite == null) {
            if (filesystem_provider.deinit) |deinit_provider| {
                deinit_provider(filesystem_provider.context);
            }
            return error.MissingSessionFilesystemSqliteProvider;
        }
        self.pending_session_filesystem_provider = .{
            .session_id = owned_session_id,
            .provider = filesystem_provider,
        };
    }

    fn rollbackSessionFilesystem(self: *Client) void {
        if (self.pending_session_filesystem_provider) |*registered| {
            registered.deinit(self.allocator);
        }
        self.pending_session_filesystem_provider = null;
    }

    fn commitSessionFilesystem(self: *Client, session_id: []const u8) void {
        const pending = self.pending_session_filesystem_provider orelse return;
        std.debug.assert(std.mem.eql(u8, pending.session_id, session_id));
        for (self.session_filesystem_providers.items, 0..) |*existing, index| {
            if (std.mem.eql(u8, existing.session_id, session_id)) {
                existing.deinit(self.allocator);
                self.session_filesystem_providers.items[index] = pending;
                self.pending_session_filesystem_provider = null;
                return;
            }
        }
        self.session_filesystem_providers.appendAssumeCapacity(pending);
        self.pending_session_filesystem_provider = null;
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
        if (self.on_list_models) |callback| {
            return callback.handler(self.allocator, callback.context);
        }
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
        try writeFrameAndWipe(
            self.transportWriter(),
            self.transportWriterBuffer(),
            request,
        );

        while (true) {
            const body = try json_rpc.readFrame(self.allocator, self.transportReader());
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
                    try self.dispatchTransportServerRequest(
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
        defer {
            wipeSecret(response);
            self.allocator.free(response);
        }
        try json_rpc.writeFrame(writer, response);
    }

    fn dispatchTransportServerRequest(
        self: *Client,
        id: std.json.Value,
        method: []const u8,
        params: ?std.json.Value,
    ) !void {
        const writer = self.transportWriter();
        defer {
            wipeSecret(self.transportWriterBuffer());
            writer.end = 0;
        }
        try self.dispatchServerRequest(writer, id, method, params);
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
        if (std.mem.startsWith(u8, method, "sessionFs.")) {
            return self.dispatchSessionFilesystemRequest(writer, id, method, params);
        }
        const registered = self.findRpcHandler(method) orelse {
            try self.rejectServerRequest(writer, id);
            return;
        };
        const params_json = try stringifyRpcParams(self.allocator, params);
        defer if (params_json) |json| {
            wipeSecret(json);
            self.allocator.free(json);
        };

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
            defer {
                wipeSecret(response);
                self.allocator.free(response);
            }
            try json_rpc.writeFrame(writer, response);
            return;
        };
        defer {
            wipeSecret(result_json);
            self.allocator.free(result_json);
        }

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
            defer {
                wipeSecret(response);
                self.allocator.free(response);
            }
            try json_rpc.writeFrame(writer, response);
            return;
        };
        defer {
            wipeJsonStrings(result.value);
            result.deinit();
        }
        const response = try json_rpc.encodeSuccessResponse(self.allocator, id, result.value);
        defer {
            wipeSecret(response);
            self.allocator.free(response);
        }
        try json_rpc.writeFrame(writer, response);
    }

    fn findSessionFilesystem(
        self: *Client,
        session_id: []const u8,
    ) ?runtime_types.SessionFilesystemProvider {
        if (self.pending_session_filesystem_provider) |registered| {
            if (std.mem.eql(u8, registered.session_id, session_id))
                return registered.provider;
        }
        for (self.session_filesystem_providers.items) |registered| {
            if (std.mem.eql(u8, registered.session_id, session_id))
                return registered.provider;
        }
        return null;
    }

    fn dispatchSessionFilesystemRequest(
        self: *Client,
        writer: *std.Io.Writer,
        id: std.json.Value,
        method: []const u8,
        params: ?std.json.Value,
    ) !void {
        const params_value = params orelse {
            try self.writeServerRequestError(writer, id, -32602, "invalid session filesystem request");
            return;
        };
        const object = switch (params_value) {
            .object => |value| value,
            else => {
                try self.writeServerRequestError(writer, id, -32602, "invalid session filesystem request");
                return;
            },
        };
        const session_id = jsonRequiredString(object, "sessionId") catch {
            try self.writeServerRequestError(writer, id, -32602, "invalid session filesystem request");
            return;
        };
        const filesystem_provider = self.findSessionFilesystem(session_id) orelse {
            try self.writeServerRequestError(writer, id, -32602, "unknown session filesystem");
            return;
        };

        self.dispatching_rpc_handler = true;
        defer self.dispatching_rpc_handler = false;

        if (std.mem.eql(u8, method, "sessionFs.readFile")) {
            const path = jsonRequiredString(object, "path") catch {
                try self.writeServerRequestError(writer, id, -32602, "invalid session filesystem request");
                return;
            };
            const content = filesystem_provider.read_file(
                self.allocator,
                path,
                filesystem_provider.context,
            ) catch |err| {
                try self.writeTypedSuccess(writer, id, WireReadFileResult{
                    .content = "",
                    .@"error" = filesystemError(err),
                });
                return;
            };
            defer {
                wipeSecret(content);
                self.allocator.free(content);
            }
            if (!std.unicode.utf8ValidateSlice(content)) {
                try self.writeServerRequestError(writer, id, -32603, "invalid session filesystem callback result");
                return;
            }
            try self.writeTypedSuccess(writer, id, WireReadFileResult{
                .content = content,
            });
            return;
        }
        if (std.mem.eql(u8, method, "sessionFs.writeFile") or
            std.mem.eql(u8, method, "sessionFs.appendFile"))
        {
            const path = jsonRequiredString(object, "path") catch {
                try self.writeServerRequestError(writer, id, -32602, "invalid session filesystem request");
                return;
            };
            const content = jsonRequiredString(object, "content") catch {
                try self.writeServerRequestError(writer, id, -32602, "invalid session filesystem request");
                return;
            };
            const mode = jsonOptionalU32(object, "mode") catch {
                try self.writeServerRequestError(writer, id, -32602, "invalid session filesystem request");
                return;
            };
            const operation = if (std.mem.eql(u8, method, "sessionFs.writeFile"))
                filesystem_provider.write_file(path, content, mode, filesystem_provider.context)
            else
                filesystem_provider.append_file(path, content, mode, filesystem_provider.context);
            operation catch |err| {
                try self.writeRpcSuccess(writer, id, filesystemError(err));
                return;
            };
            try self.writeRpcSuccess(writer, id, @as(?FilesystemError, null));
            return;
        }
        if (std.mem.eql(u8, method, "sessionFs.exists")) {
            const path = jsonRequiredString(object, "path") catch {
                try self.writeServerRequestError(writer, id, -32602, "invalid session filesystem request");
                return;
            };
            const exists = filesystem_provider.exists(
                path,
                filesystem_provider.context,
            ) catch false;
            try self.writeRpcSuccess(writer, id, .{ .exists = exists });
            return;
        }
        if (std.mem.eql(u8, method, "sessionFs.stat")) {
            const path = jsonRequiredString(object, "path") catch {
                try self.writeServerRequestError(writer, id, -32602, "invalid session filesystem request");
                return;
            };
            const info = filesystem_provider.stat(path, filesystem_provider.context) catch |err| {
                try self.writeTypedSuccess(writer, id, WireStatResult{
                    .isFile = false,
                    .isDirectory = false,
                    .size = 0,
                    .mtime = "1970-01-01T00:00:00.000Z",
                    .birthtime = "1970-01-01T00:00:00.000Z",
                    .@"error" = filesystemError(err),
                });
                return;
            };
            if (!validDateTime(info.mtime) or !validDateTime(info.birthtime)) {
                try self.writeServerRequestError(writer, id, -32603, "invalid session filesystem callback result");
                return;
            }
            try self.writeTypedSuccess(writer, id, WireStatResult{
                .isFile = info.is_file,
                .isDirectory = info.is_directory,
                .size = info.size,
                .mtime = info.mtime,
                .birthtime = info.birthtime,
            });
            return;
        }
        if (std.mem.eql(u8, method, "sessionFs.mkdir")) {
            const path = jsonRequiredString(object, "path") catch {
                try self.writeServerRequestError(writer, id, -32602, "invalid session filesystem request");
                return;
            };
            const recursive = (jsonOptionalBool(object, "recursive") catch {
                try self.writeServerRequestError(writer, id, -32602, "invalid session filesystem request");
                return;
            }) orelse false;
            const mode = jsonOptionalU32(object, "mode") catch {
                try self.writeServerRequestError(writer, id, -32602, "invalid session filesystem request");
                return;
            };
            filesystem_provider.make_directory(
                path,
                recursive,
                mode,
                filesystem_provider.context,
            ) catch |err| {
                try self.writeRpcSuccess(writer, id, filesystemError(err));
                return;
            };
            try self.writeRpcSuccess(writer, id, @as(?FilesystemError, null));
            return;
        }
        if (std.mem.eql(u8, method, "sessionFs.readdir")) {
            const path = jsonRequiredString(object, "path") catch {
                try self.writeServerRequestError(writer, id, -32602, "invalid session filesystem request");
                return;
            };
            const result = filesystem_provider.read_directory(
                self.allocator,
                path,
                filesystem_provider.context,
            ) catch |err| {
                try self.writeTypedSuccess(writer, id, WireReadDirectoryResult{
                    .entries = &.{},
                    .@"error" = filesystemError(err),
                });
                return;
            };
            defer result.deinit();
            if (!validStrings(result.value.entries)) {
                try self.writeServerRequestError(writer, id, -32603, "invalid session filesystem callback result");
                return;
            }
            try self.writeTypedSuccess(writer, id, WireReadDirectoryResult{
                .entries = result.value.entries,
            });
            return;
        }
        if (std.mem.eql(u8, method, "sessionFs.readdirWithTypes")) {
            const path = jsonRequiredString(object, "path") catch {
                try self.writeServerRequestError(writer, id, -32602, "invalid session filesystem request");
                return;
            };
            const result = filesystem_provider.read_directory_with_types(
                self.allocator,
                path,
                filesystem_provider.context,
            ) catch |err| {
                try self.writeRpcSuccess(writer, id, .{
                    .entries = &.{},
                    .@"error" = filesystemError(err),
                });
                return;
            };
            defer result.deinit();
            if (!validFilesystemEntries(result.value.entries)) {
                try self.writeServerRequestError(writer, id, -32603, "invalid session filesystem callback result");
                return;
            }
            try self.writeRpcSuccess(writer, id, WireFilesystemEntries{
                .entries = result.value.entries,
            });
            return;
        }
        if (std.mem.eql(u8, method, "sessionFs.rm")) {
            const path = jsonRequiredString(object, "path") catch {
                try self.writeServerRequestError(writer, id, -32602, "invalid session filesystem request");
                return;
            };
            const recursive = (jsonOptionalBool(object, "recursive") catch {
                try self.writeServerRequestError(writer, id, -32602, "invalid session filesystem request");
                return;
            }) orelse false;
            const force = (jsonOptionalBool(object, "force") catch {
                try self.writeServerRequestError(writer, id, -32602, "invalid session filesystem request");
                return;
            }) orelse false;
            filesystem_provider.remove(
                path,
                recursive,
                force,
                filesystem_provider.context,
            ) catch |err| {
                try self.writeRpcSuccess(writer, id, filesystemError(err));
                return;
            };
            try self.writeRpcSuccess(writer, id, @as(?FilesystemError, null));
            return;
        }
        if (std.mem.eql(u8, method, "sessionFs.rename")) {
            const source = jsonRequiredString(object, "src") catch {
                try self.writeServerRequestError(writer, id, -32602, "invalid session filesystem request");
                return;
            };
            const destination = jsonRequiredString(object, "dest") catch {
                try self.writeServerRequestError(writer, id, -32602, "invalid session filesystem request");
                return;
            };
            filesystem_provider.rename(
                source,
                destination,
                filesystem_provider.context,
            ) catch |err| {
                try self.writeRpcSuccess(writer, id, filesystemError(err));
                return;
            };
            try self.writeRpcSuccess(writer, id, @as(?FilesystemError, null));
            return;
        }
        if (std.mem.eql(u8, method, "sessionFs.sqliteExists")) {
            const sqlite = filesystem_provider.sqlite orelse {
                try self.writeRpcSuccess(writer, id, .{ .exists = false });
                return;
            };
            const exists = sqlite.exists(filesystem_provider.context) catch |err| {
                try self.writeServerRequestError(writer, id, -32000, @errorName(err));
                return;
            };
            try self.writeRpcSuccess(writer, id, .{ .exists = exists });
            return;
        }
        if (std.mem.eql(u8, method, "sessionFs.sqliteQuery")) {
            const sqlite = filesystem_provider.sqlite orelse {
                try self.writeServerRequestError(writer, id, -32601, "SQLite is not supported by this provider");
                return;
            };
            const query_type = parseSqliteQueryType(object.get("queryType")) catch {
                try self.writeServerRequestError(writer, id, -32602, "invalid session filesystem request");
                return;
            };
            const query = jsonRequiredString(object, "query") catch {
                try self.writeServerRequestError(writer, id, -32602, "invalid session filesystem request");
                return;
            };
            const sqlite_params = jsonOptionalObjectValue(object, "params") catch {
                try self.writeServerRequestError(writer, id, -32602, "invalid session filesystem request");
                return;
            };
            const result = sqlite.query(
                self.allocator,
                query_type,
                query,
                sqlite_params,
                filesystem_provider.context,
            ) catch |err| {
                try self.writeServerRequestError(writer, id, -32000, @errorName(err));
                return;
            };
            defer result.deinit();
            if (!validSqliteQueryResult(result.value)) {
                try self.writeServerRequestError(writer, id, -32603, "invalid session filesystem callback result");
                return;
            }
            try self.writeRpcSuccess(writer, id, WireSqliteQueryResult{
                .value = result.value,
            });
            return;
        }
        if (std.mem.eql(u8, method, "sessionFs.sqliteTransaction")) {
            const sqlite = filesystem_provider.sqlite orelse {
                try self.writeServerRequestError(writer, id, -32601, "SQLite is not supported by this provider");
                return;
            };
            const transaction = sqlite.transaction orelse {
                try self.writeRpcSuccess(writer, id, .{
                    .results = &.{},
                    .@"error" = .{
                        .errorClass = "fatal",
                        .message = "SQLite transactions are not supported by this provider",
                    },
                });
                return;
            };
            var statements = parseSqliteStatements(self.allocator, object.get("statements")) catch {
                try self.writeServerRequestError(writer, id, -32602, "invalid session filesystem request");
                return;
            };
            defer statements.deinit(self.allocator);
            const result = transaction(
                self.allocator,
                statements.items,
                filesystem_provider.context,
            ) catch |err| {
                try self.writeRpcSuccess(writer, id, .{
                    .results = &.{},
                    .@"error" = .{
                        .errorClass = "fatal",
                        .message = @errorName(err),
                    },
                });
                return;
            };
            defer result.deinit();
            if (!validSqliteTransactionResult(result.value, statements.items.len)) {
                try self.writeServerRequestError(writer, id, -32603, "invalid session filesystem callback result");
                return;
            }
            try self.writeRpcSuccess(writer, id, WireSqliteTransactionResult{
                .value = result.value,
            });
            return;
        }

        try self.rejectServerRequest(writer, id);
    }

    fn writeRpcSuccess(
        self: *Client,
        writer: *std.Io.Writer,
        id: std.json.Value,
        result: anytype,
    ) !void {
        const response = try json_rpc.encodeSuccessResponse(
            self.allocator,
            id,
            result,
        );
        defer {
            wipeSecret(response);
            self.allocator.free(response);
        }
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
        try json_rpc.writeFrame(writer, response);
    }

    fn writeNullSuccess(
        self: *Client,
        writer: *std.Io.Writer,
        id: std.json.Value,
    ) !void {
        const result: std.json.Value = .null;
        const response = try json_rpc.encodeSuccessResponse(self.allocator, id, result);
        defer {
            wipeSecret(response);
            self.allocator.free(response);
        }
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
            defer if (input_json) |value| {
                wipeSecret(value);
                self.allocator.free(value);
            };
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
            defer {
                wipeSecret(output_json);
                self.allocator.free(output_json);
            }
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
            defer {
                wipeJsonStrings(output.value);
                output.deinit();
            }
            const response = try json_rpc.encodeSuccessResponse(self.allocator, id, output.value);
            defer {
                wipeSecret(response);
                self.allocator.free(response);
            }
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
        defer {
            wipeSecret(token);
            self.allocator.free(token);
        }

        const response = try json_rpc.encodeSuccessResponse(self.allocator, id, .{ .token = token });
        defer {
            wipeSecret(response);
            self.allocator.free(response);
        }
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
        defer {
            wipeSecret(response.answer);
            self.allocator.free(response.answer);
        }

        const frame = try json_rpc.encodeSuccessResponse(
            self.allocator,
            id,
            .{
                .answer = response.answer,
                .wasFreeform = response.was_freeform,
            },
        );
        defer {
            wipeSecret(frame);
            self.allocator.free(frame);
        }
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
        defer {
            wipeSecret(response);
            self.allocator.free(response);
        }
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
        try self.applyExtensionEvent(session_id, &queued.event);
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

        for (self.session_filesystem_providers.items, 0..) |*registered, filesystem_index| {
            if (std.mem.eql(u8, registered.session_id, session_id)) {
                var removed = self.session_filesystem_providers.orderedRemove(filesystem_index);
                removed.deinit(self.allocator);
                break;
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
                if (std.mem.eql(u8, queued.session_id, session_id)) {
                    const result = self.events.orderedRemove(index);
                    self.allocator.free(result.session_id);
                    return result.event;
                }
            }

            const body = try json_rpc.readFrame(self.allocator, self.transportReader());
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
                try self.dispatchTransportServerRequest(
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
        const trace_context = self.client.traceContext();
        const parsed = try self.client.call(
            struct { messageId: []const u8 },
            "session.send",
            lowerMessage(self.id, options, trace_context),
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
        var released_oauth_interest = false;
        if (self.client.findExtensionRuntime(self.id)) |runtime| {
            released_oauth_interest = runtime.mcp_oauth_interest_handle != null;
            try self.client.releaseMcpOAuthInterest(runtime);
        }
        errdefer if (released_oauth_interest) {
            if (self.client.findExtensionRuntime(self.id)) |runtime| {
                if (runtime.mcp_auth_handler != null) {
                    self.client.registerMcpOAuthInterest(runtime) catch {};
                }
            }
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

const FilesystemError = struct {
    code: []const u8,
    message: []const u8,
};

const WireReadFileResult = struct {
    content: []const u8,
    @"error": ?FilesystemError = null,
};

const WireStatResult = struct {
    isFile: bool,
    isDirectory: bool,
    size: u64,
    mtime: []const u8,
    birthtime: []const u8,
    @"error": ?FilesystemError = null,
};

const WireReadDirectoryResult = struct {
    entries: []const []const u8,
    @"error": ?FilesystemError = null,
};

const WireFilesystemEntries = struct {
    entries: []const runtime_types.SessionFilesystemEntry,

    pub fn jsonStringify(self: WireFilesystemEntries, writer: anytype) !void {
        try writer.beginObject();
        try writer.objectField("entries");
        try writer.beginArray();
        for (self.entries) |entry| {
            try writer.write(.{
                .name = entry.name,
                .type = @tagName(entry.entry_type),
            });
        }
        try writer.endArray();
        try writer.endObject();
    }
};

const WireSqliteQueryResult = struct {
    value: runtime_types.SessionFilesystemSqliteQueryResult,

    pub fn jsonStringify(self: WireSqliteQueryResult, writer: anytype) !void {
        try writer.beginObject();
        try writer.objectField("columns");
        try writer.write(self.value.columns);
        try writer.objectField("rows");
        try writer.write(self.value.rows);
        try writer.objectField("rowsAffected");
        try writer.write(self.value.rows_affected);
        if (self.value.last_insert_rowid) |row_id| {
            try writer.objectField("lastInsertRowid");
            try writer.write(row_id);
        }
        try writer.endObject();
    }
};

const WireSqliteTransactionResult = struct {
    value: runtime_types.SessionFilesystemSqliteTransactionResult,

    pub fn jsonStringify(self: WireSqliteTransactionResult, writer: anytype) !void {
        try writer.beginObject();
        try writer.objectField("results");
        try writer.beginArray();
        for (self.value.results) |result| {
            try writer.write(WireSqliteQueryResult{ .value = result });
        }
        try writer.endArray();
        if (self.value.@"error") |failure| {
            try writer.objectField("error");
            try writer.write(.{
                .errorClass = switch (failure.error_class) {
                    .busy_or_locked => "busyOrLocked",
                    .fatal => "fatal",
                    .post_commit_ambiguous => "postCommitAmbiguous",
                },
                .message = failure.message,
            });
        }
        try writer.endObject();
    }
};

fn filesystemError(err: anyerror) FilesystemError {
    return .{
        .code = if (err == error.FileNotFound) "ENOENT" else "UNKNOWN",
        .message = @errorName(err),
    };
}

fn jsonOptionalU32(object: std.json.ObjectMap, name: []const u8) !?u32 {
    return switch (object.get(name) orelse return null) {
        .integer => |value| std.math.cast(u32, value) orelse error.InvalidField,
        .null => null,
        else => error.InvalidField,
    };
}

fn parseSqliteQueryType(value: ?std.json.Value) !runtime_types.SessionFilesystemSqliteQueryType {
    const string = switch (value orelse return error.MissingField) {
        .string => |item| item,
        else => return error.InvalidField,
    };
    if (std.mem.eql(u8, string, "exec")) return .exec;
    if (std.mem.eql(u8, string, "query")) return .query;
    if (std.mem.eql(u8, string, "run")) return .run;
    return error.InvalidField;
}

fn parseSqliteStatements(
    allocator: std.mem.Allocator,
    value: ?std.json.Value,
) !std.ArrayList(runtime_types.SessionFilesystemSqliteStatement) {
    const array = switch (value orelse return error.MissingField) {
        .array => |item| item,
        else => return error.InvalidField,
    };
    var result: std.ArrayList(runtime_types.SessionFilesystemSqliteStatement) = .empty;
    errdefer result.deinit(allocator);
    try result.ensureTotalCapacity(allocator, array.items.len);
    for (array.items) |item| {
        const object = switch (item) {
            .object => |entry| entry,
            else => return error.InvalidField,
        };
        result.appendAssumeCapacity(.{
            .query_type = try parseSqliteQueryType(object.get("queryType")),
            .query = try jsonRequiredString(object, "query"),
            .params = try jsonOptionalObjectValue(object, "params"),
        });
    }
    return result;
}

fn jsonOptionalObjectValue(
    object: std.json.ObjectMap,
    name: []const u8,
) !?std.json.Value {
    return switch (object.get(name) orelse return null) {
        .object => |value| .{ .object = value },
        .null => null,
        else => error.InvalidField,
    };
}

fn validStrings(values: []const []const u8) bool {
    for (values) |value| {
        if (!std.unicode.utf8ValidateSlice(value)) return false;
    }
    return true;
}

fn validFilesystemEntries(
    entries: []const runtime_types.SessionFilesystemEntry,
) bool {
    for (entries) |entry| {
        if (!std.unicode.utf8ValidateSlice(entry.name)) return false;
    }
    return true;
}

fn validDateTime(value: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(value) or value.len < 20) return false;
    if (value[4] != '-' or value[7] != '-' or
        (value[10] != 'T' and value[10] != 't') or
        value[13] != ':' or value[16] != ':')
    {
        return false;
    }
    for ([_]usize{ 0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18 }) |index| {
        if (!std.ascii.isDigit(value[index])) return false;
    }
    return value[value.len - 1] == 'Z' or
        value[value.len - 1] == 'z' or
        (value.len >= 25 and
            (value[value.len - 6] == '+' or value[value.len - 6] == '-') and
            value[value.len - 3] == ':');
}

fn validSqliteRows(rows: []const std.json.Value) bool {
    for (rows) |row| {
        if (row != .object) return false;
    }
    return true;
}

fn validSqliteQueryResult(
    result: runtime_types.SessionFilesystemSqliteQueryResult,
) bool {
    return validStrings(result.columns) and validSqliteRows(result.rows);
}

fn validSqliteTransactionResult(
    result: runtime_types.SessionFilesystemSqliteTransactionResult,
    statement_count: usize,
) bool {
    if (result.@"error") |failure| {
        return result.results.len == 0 and
            std.unicode.utf8ValidateSlice(failure.message);
    }
    if (result.results.len != statement_count) return false;
    for (result.results) |item| {
        if (!validSqliteQueryResult(item)) return false;
    }
    return true;
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
    systemMessage: ?WireSystemMessage,
    isExperimentalMode: ?bool,
    enableSessionTelemetry: ?bool,
    skipEmbeddingRetrieval: ?bool,
    embeddingCacheStorage: ?[]const u8,
    enableFileHooks: ?bool,
    enableHostGitOperations: ?bool,
    enableSessionStore: ?bool,
    memory: ?WireMemoryConfiguration,
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
    traceparent: ?[]const u8 = null,
    tracestate: ?[]const u8 = null,
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
    systemMessage: ?WireSystemMessage,
    isExperimentalMode: ?bool,
    enableSessionTelemetry: ?bool,
    skipEmbeddingRetrieval: ?bool,
    embeddingCacheStorage: ?[]const u8,
    enableFileHooks: ?bool,
    enableHostGitOperations: ?bool,
    enableSessionStore: ?bool,
    memory: ?WireMemoryConfiguration,
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
    traceparent: ?[]const u8 = null,
    tracestate: ?[]const u8 = null,
};

const ToolFilterPrecedence = enum {
    available,
    excluded,
};

const WireMemoryConfiguration = struct {
    enabled: bool,
};

const WireSystemMessageSection = struct {
    action: []const u8,
};

const WireSystemMessageSections = struct {
    environment_context: WireSystemMessageSection,
};

const WireSystemMessage = struct {
    mode: []const u8,
    content: ?[]const u8 = null,
    sections: ?WireSystemMessageSections = null,
};

const SessionOptionsUpdateRequest = struct {
    sessionId: []const u8,
    skipCustomInstructions: bool,
    customAgentsLocalOnly: bool,
    coauthorEnabled: bool,
    manageScheduleEnabled: bool,
    installedPlugins: []const std.json.Value = &.{},
    includedBuiltinSkills: []const []const u8,
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

fn validateSessionMode(
    mode: runtime_types.RuntimeMode,
    available_tools: ?[]const []const u8,
) !void {
    if (mode == .empty and available_tools == null)
        return error.EmptyModeRequiresAvailableTools;
}

fn lowerSystemMessage(
    mode: runtime_types.RuntimeMode,
    supplied: ?session_types.SystemMessageConfig,
) ?WireSystemMessage {
    if (mode != .empty) {
        const value = supplied orelse return null;
        return .{
            .mode = @tagName(value.mode),
            .content = value.content,
        };
    }
    if (supplied) |value| {
        if (value.mode == .replace) {
            return .{
                .mode = "replace",
                .content = value.content,
            };
        }
        return .{
            .mode = "customize",
            .content = value.content,
            .sections = .{
                .environment_context = .{ .action = "remove" },
            },
        };
    }
    return .{
        .mode = "customize",
        .sections = .{
            .environment_context = .{ .action = "remove" },
        },
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
        .copilot_cli,
    );
}

fn buildPreparedCreateSessionRequest(
    session_id: ?[]const u8,
    config: session_types.CreateSessionConfig,
    tools: []const WireTool,
    values: *ExtensionWireValues,
    prepared_providers: provider.PreparedProviders,
    mode: runtime_types.RuntimeMode,
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
        .customAgentsLocalOnly = config.custom_agents_local_only orelse
            if (mode == .empty) true else null,
        .excludedBuiltinAgents = config.excluded_builtin_agents,
        .systemMessage = lowerSystemMessage(mode, config.system_message),
        .isExperimentalMode = if (mode == .empty) false else null,
        .enableSessionTelemetry = if (mode == .empty) false else null,
        .skipEmbeddingRetrieval = if (mode == .empty) true else null,
        .embeddingCacheStorage = if (mode == .empty) "in-memory" else null,
        .enableFileHooks = if (mode == .empty) false else null,
        .enableHostGitOperations = if (mode == .empty) false else null,
        .enableSessionStore = if (mode == .empty) false else null,
        .memory = if (mode == .empty) .{ .enabled = false } else null,
        .requestPermission = config.request_permission or config.on_permission_request != null,
        .requestUserInput = config.on_user_input_request != null,
        .enableConfigDiscovery = config.enable_config_discovery,
        .skillDirectories = config.skill_directories orelse
            optionalSlice(features.skills.directories),
        .enableSkills = config.enable_skills orelse features.skills.enabled orelse
            if (mode == .empty) false else null,
        .instructionDirectories = config.instruction_directories,
        .skipCustomInstructions = config.skip_custom_instructions,
        .enableOnDemandInstructionDiscovery = config.enable_on_demand_instruction_discovery orelse
            if (mode == .empty) false else null,
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
        else if (mode == .empty)
            "in-memory"
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
        .copilot_cli,
    );
}

fn buildPreparedResumeSessionRequest(
    session_id: []const u8,
    config: session_types.ResumeSessionConfig,
    tools: []const WireTool,
    values: *ExtensionWireValues,
    requested_environment_variables: []const []const u8,
    prepared_providers: provider.PreparedProviders,
    mode: runtime_types.RuntimeMode,
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
        .customAgentsLocalOnly = config.custom_agents_local_only orelse
            if (mode == .empty) true else null,
        .excludedBuiltinAgents = config.excluded_builtin_agents,
        .systemMessage = lowerSystemMessage(mode, config.system_message),
        .isExperimentalMode = if (mode == .empty) false else null,
        .enableSessionTelemetry = if (mode == .empty) false else null,
        .skipEmbeddingRetrieval = if (mode == .empty) true else null,
        .embeddingCacheStorage = if (mode == .empty) "in-memory" else null,
        .enableFileHooks = if (mode == .empty) false else null,
        .enableHostGitOperations = if (mode == .empty) false else null,
        .enableSessionStore = if (mode == .empty) false else null,
        .memory = if (mode == .empty) .{ .enabled = false } else null,
        .requestPermission = config.request_permission or config.on_permission_request != null,
        .requestUserInput = config.on_user_input_request != null,
        .enableConfigDiscovery = config.enable_config_discovery,
        .skillDirectories = config.skill_directories orelse
            optionalSlice(features.skills.directories),
        .enableSkills = config.enable_skills orelse features.skills.enabled orelse
            if (mode == .empty) false else null,
        .instructionDirectories = config.instruction_directories,
        .skipCustomInstructions = config.skip_custom_instructions,
        .enableOnDemandInstructionDiscovery = config.enable_on_demand_instruction_discovery orelse
            if (mode == .empty) false else null,
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
        else if (mode == .empty)
            "in-memory"
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
}

test "stdio runtime lowers stable argv and environment options" {
    const allocator = std.testing.allocator;
    const fake_runtime = try fakeRuntimePath(allocator);
    defer allocator.free(fake_runtime);

    var client = try Client.init(allocator, std.testing.io, .{
        .connection = .{ .stdio = .{ .runtime = .{
            .executable = "node",
            .args = &.{ fake_runtime, "--user-flag" },
            .mode = .empty,
            .base_directory = "/tmp/copilot-sdk-zig-home",
            .log_level = .debug,
            .environment = &.{.{
                .name = "TEST_RUNTIME_VALUE",
                .value = "kept",
            }},
            .authentication = .{ .token_and_logged_in_user = "github-secret" },
            .telemetry = .{
                .otlp_endpoint = "http://127.0.0.1:4318",
                .otlp_protocol = .http_json,
                .file_path = "/tmp/copilot-traces.jsonl",
                .exporter_type = "file",
                .source_name = "zig-tests",
                .capture_content = false,
            },
            .session_idle_timeout_seconds = 90,
            .enable_remote_sessions = true,
        } } },
    });
    defer client.deinit();

    const inspected = try client.callRpc(std.json.Value, "test.inspect", .{});
    defer inspected.deinit();
    const object = inspected.value.object;
    const args = object.get("args").?.array.items;
    const expected = [_][]const u8{
        "--user-flag",
        "--headless",
        "--no-auto-update",
        "--log-level",
        "debug",
        "--stdio",
        "--auth-token-env",
        "COPILOT_SDK_AUTH_TOKEN",
        "--session-idle-timeout",
        "90",
        "--remote",
    };
    try std.testing.expectEqual(expected.len, args.len);
    for (expected, args) |expected_arg, actual_arg| {
        try std.testing.expectEqualStrings(expected_arg, actual_arg.string);
    }
    const environment = object.get("env").?.object;
    try std.testing.expectEqualStrings(
        "kept",
        environment.get("TEST_RUNTIME_VALUE").?.string,
    );
    try std.testing.expectEqualStrings(
        "github-secret",
        environment.get("COPILOT_SDK_AUTH_TOKEN").?.string,
    );
    try std.testing.expectEqualStrings(
        "/tmp/copilot-sdk-zig-home",
        environment.get("COPILOT_HOME").?.string,
    );
    try std.testing.expectEqualStrings(
        "1",
        environment.get("COPILOT_DISABLE_KEYTAR").?.string,
    );
    try std.testing.expectEqualStrings(
        "http/json",
        environment.get("OTEL_EXPORTER_OTLP_PROTOCOL").?.string,
    );
    try std.testing.expectEqualStrings(
        "false",
        environment.get("OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT").?.string,
    );
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

test "runtime authentication preserves every stable upstream state" {
    const allocator = std.testing.allocator;
    const fake_runtime = try fakeRuntimePath(allocator);
    defer allocator.free(fake_runtime);

    const cases = [_]struct {
        authentication: runtime_types.RuntimeAuthentication,
        expects_no_auto_login: bool,
        expects_auth_token: bool,
    }{
        .{ .authentication = .default, .expects_no_auto_login = false, .expects_auth_token = false },
        .{ .authentication = .logged_in_user, .expects_no_auto_login = false, .expects_auth_token = false },
        .{ .authentication = .{ .token = "token-only" }, .expects_no_auto_login = true, .expects_auth_token = true },
        .{ .authentication = .{ .token_and_logged_in_user = "token-and-user" }, .expects_no_auto_login = false, .expects_auth_token = true },
        .{ .authentication = .disabled, .expects_no_auto_login = true, .expects_auth_token = false },
    };

    for (cases) |case| {
        var client = try Client.init(allocator, std.testing.io, .{
            .connection = .{ .stdio = .{ .runtime = .{
                .executable = "node",
                .args = &.{fake_runtime},
                .authentication = case.authentication,
            } } },
        });
        defer client.deinit();

        const inspected = try client.callRpc(std.json.Value, "test.inspect", .{});
        defer inspected.deinit();
        const args = inspected.value.object.get("args").?.array.items;
        var has_no_auto_login = false;
        var has_auth_token = false;
        for (args) |argument| {
            has_no_auto_login = has_no_auto_login or
                std.mem.eql(u8, argument.string, "--no-auto-login");
            has_auth_token = has_auth_token or
                std.mem.eql(u8, argument.string, "--auth-token-env");
        }
        try std.testing.expectEqual(case.expects_no_auto_login, has_no_auto_login);
        try std.testing.expectEqual(case.expects_auth_token, has_auth_token);

        const environment = inspected.value.object.get("env").?.object;
        if (case.expects_auth_token) {
            const expected = switch (case.authentication) {
                .token => |token| token,
                .token_and_logged_in_user => |token| token,
                else => unreachable,
            };
            try std.testing.expectEqualStrings(
                expected,
                environment.get("COPILOT_SDK_AUTH_TOKEN").?.string,
            );
        } else {
            try std.testing.expect(environment.get("COPILOT_SDK_AUTH_TOKEN") == null);
        }
    }
}

test "runtime configuration rejects invalid state before spawning" {
    const invalid_executable = "/definitely/not/a/copilot/runtime";

    try std.testing.expectError(
        error.ConflictingConnectionOptions,
        Client.init(std.testing.allocator, std.testing.io, .{
            .cli_path = invalid_executable,
            .connection = .{ .stdio = .{ .runtime = .{
                .executable = invalid_executable,
            } } },
        }),
    );
    try std.testing.expectError(
        error.ManagedEnvironmentVariable,
        Client.init(std.testing.allocator, std.testing.io, .{
            .connection = .{ .stdio = .{ .runtime = .{
                .executable = invalid_executable,
                .environment = &.{.{
                    .name = "COPILOT_SDK_AUTH_TOKEN",
                    .value = "raw-secret",
                }},
            } } },
        }),
    );
    try std.testing.expectError(
        error.EmptyModeRequiresPersistence,
        Client.init(std.testing.allocator, std.testing.io, .{
            .connection = .{ .stdio = .{ .runtime = .{
                .executable = invalid_executable,
                .mode = .empty,
            } } },
        }),
    );
    try std.testing.expectError(
        error.InvalidBaseDirectory,
        Client.init(std.testing.allocator, std.testing.io, .{
            .connection = .{ .stdio = .{ .runtime = .{
                .executable = invalid_executable,
                .base_directory = "",
            } } },
        }),
    );
    try std.testing.expectError(
        error.InvalidGitHubToken,
        Client.init(std.testing.allocator, std.testing.io, .{
            .connection = .{ .stdio = .{ .runtime = .{
                .executable = invalid_executable,
                .authentication = .{ .token = "" },
            } } },
        }),
    );
    try std.testing.expectError(
        error.InvalidRuntimeUri,
        Client.init(std.testing.allocator, std.testing.io, .{
            .connection = .{ .uri = .{ .uri = "not-a-host-and-port" } },
        }),
    );
}

test "runtime environment distinguishes inheritance from explicit empty" {
    const allocator = std.testing.allocator;

    var inherited = try buildRuntimeEnvironment(allocator, .{}, null);
    defer deinitEnvironment(&inherited);
    try std.testing.expect(inherited.get("NODE_DEBUG") == null);

    var empty = try buildRuntimeEnvironment(allocator, .{
        .environment = &.{},
    }, null);
    defer deinitEnvironment(&empty);
    try std.testing.expectEqual(@as(usize, 0), empty.count());

    var filtered = try buildRuntimeEnvironment(allocator, .{
        .environment = &.{
            .{ .name = "NODE_DEBUG", .value = "rpc" },
            .{ .name = "TEST_RUNTIME_VALUE", .value = "present" },
        },
    }, null);
    defer deinitEnvironment(&filtered);
    try std.testing.expect(filtered.get("NODE_DEBUG") == null);
    try std.testing.expectEqualStrings("present", filtered.get("TEST_RUNTIME_VALUE").?);
}

test "default connection environment selection matches upstream" {
    try std.testing.expectEqual(
        DefaultConnection.stdio,
        try parseDefaultConnection(null),
    );
    try std.testing.expectEqual(
        DefaultConnection.stdio,
        try parseDefaultConnection("StDiO"),
    );
    try std.testing.expectEqual(
        DefaultConnection.inprocess,
        try parseDefaultConnection("INPROCESS"),
    );
    try std.testing.expectError(
        error.InvalidDefaultConnection,
        parseDefaultConnection("socket"),
    );
    try std.testing.expectError(
        error.UnsupportedInProcessConnection,
        resolveConnection(.{}, .inprocess),
    );
    const explicit = try resolveConnection(.{
        .connection = .{ .uri = .{ .uri = "localhost:4321" } },
    }, .inprocess);
    try std.testing.expectEqual(@as(u16, 4321), explicit.uri.port);
}

test "legacy ClientOptions remain an implicit stdio connection" {
    const allocator = std.testing.allocator;
    const fake_runtime = try fakeRuntimePath(allocator);
    defer allocator.free(fake_runtime);

    var client = try Client.init(allocator, std.testing.io, .{
        .cli_path = "node",
        .cli_args = &.{fake_runtime},
        .connection_token = "legacy-token",
    });
    defer client.deinit();
    const inspected = try client.callRpc(std.json.Value, "test.inspect", .{});
    defer inspected.deinit();
    const args = inspected.value.object.get("args").?.array.items;
    try std.testing.expectEqualStrings("--headless", args[0].string);
    try std.testing.expectEqualStrings("--no-auto-update", args[1].string);
    try std.testing.expectEqualStrings("--stdio", args[2].string);
    try std.testing.expectEqualStrings(
        "legacy-token",
        inspected.value.object.get("env").?.object.get("COPILOT_CONNECTION_TOKEN").?.string,
    );
}

test "failed child handshake kills and reaps the runtime" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const fake_runtime = try fakeRuntimePath(allocator);
    defer allocator.free(fake_runtime);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const pid_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/runtime.pid",
        .{tmp.sub_path},
    );
    defer allocator.free(pid_path);

    try std.testing.expectError(
        error.JsonRpcError,
        Client.init(allocator, std.testing.io, .{
            .connection = .{ .stdio = .{ .runtime = .{
                .executable = "node",
                .args = &.{ fake_runtime, "--pid-path", pid_path, "--fail-connect" },
            } } },
        }),
    );

    const pid_text = try tmp.dir.readFileAlloc(
        std.testing.io,
        "runtime.pid",
        allocator,
        .limited(64),
    );
    defer allocator.free(pid_text);
    const pid = try std.fmt.parseInt(std.posix.pid_t, pid_text, 10);
    try std.testing.expectError(error.ProcessNotFound, std.posix.kill(pid, .CONT));
}

test "client deinit does not wait for an unresponsive owned runtime" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const fake_runtime = try fakeRuntimePath(allocator);
    defer allocator.free(fake_runtime);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const pid_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/runtime.pid",
        .{tmp.sub_path},
    );
    defer allocator.free(pid_path);

    var client = try Client.init(allocator, std.testing.io, .{
        .connection = .{ .stdio = .{ .runtime = .{
            .executable = "node",
            .args = &.{ fake_runtime, "--pid-path", pid_path, "--hang-after-connect" },
        } } },
    });
    const start = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    client.deinit();
    const elapsed = start.durationTo(std.Io.Clock.Timestamp.now(std.testing.io, .awake));
    try std.testing.expect(elapsed.raw.toMilliseconds() < 1000);

    const pid_text = try tmp.dir.readFileAlloc(
        std.testing.io,
        "runtime.pid",
        allocator,
        .limited(64),
    );
    defer allocator.free(pid_text);
    const pid = try std.fmt.parseInt(std.posix.pid_t, pid_text, 10);
    try std.testing.expectError(error.ProcessNotFound, std.posix.kill(pid, .CONT));
}

fn unusedTcpPort(io: std.Io) !u16 {
    const address = std.Io.net.IpAddress{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    return server.socket.address.getPort();
}

test "TCP startup consumes delayed announcements and validates fixed ports" {
    const allocator = std.testing.allocator;
    const fake_runtime = try fakeRuntimePath(allocator);
    defer allocator.free(fake_runtime);
    const port = try unusedTcpPort(std.testing.io);
    const port_text = try std.fmt.allocPrint(allocator, "{d}", .{port});
    defer allocator.free(port_text);

    const start = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    var client = try Client.init(allocator, std.testing.io, .{
        .connection = .{ .tcp = .{
            .port = port,
            .runtime = .{
                .executable = "node",
                .args = &.{ fake_runtime, "--announce-delay-ms", "100" },
            },
        } },
    });
    defer client.deinit();
    const elapsed = start.durationTo(std.Io.Clock.Timestamp.now(std.testing.io, .awake));
    try std.testing.expect(elapsed.raw.toMilliseconds() >= 75);
    try std.testing.expectEqual(port, client.runtimePort().?);
    const inspected = try client.callRpc(std.json.Value, "test.inspect", .{});
    defer inspected.deinit();
    const args = inspected.value.object.get("args").?.array.items;
    try std.testing.expectEqualStrings("--port", args[4].string);
    try std.testing.expectEqualStrings(port_text, args[5].string);
}

test "TCP startup rejects a mismatched fixed-port announcement" {
    const allocator = std.testing.allocator;
    const fake_runtime = try fakeRuntimePath(allocator);
    defer allocator.free(fake_runtime);
    const port = try unusedTcpPort(std.testing.io);

    try std.testing.expectError(
        error.RuntimePortMismatch,
        Client.init(allocator, std.testing.io, .{
            .connection = .{ .tcp = .{
                .port = port,
                .runtime = .{
                    .executable = "node",
                    .args = &.{ fake_runtime, "--announce-port-offset", "1" },
                },
            } },
        }),
    );
}

test "TCP startup times out when the runtime never announces a port" {
    const allocator = std.testing.allocator;
    const fake_runtime = try fakeRuntimePath(allocator);
    defer allocator.free(fake_runtime);
    const start = std.Io.Clock.Timestamp.now(std.testing.io, .awake);

    try std.testing.expectError(
        error.RuntimeStartupTimeout,
        Client.init(allocator, std.testing.io, .{
            .connection = .{ .tcp = .{ .runtime = .{
                .executable = "node",
                .args = &.{ fake_runtime, "--never-announce" },
            } } },
        }),
    );
    const elapsed = start.durationTo(std.Io.Clock.Timestamp.now(std.testing.io, .awake));
    try std.testing.expect(elapsed.raw.toMilliseconds() >= 9_500);
    try std.testing.expect(elapsed.raw.toMilliseconds() < 12_000);
}

test "failed URI handshake closes its socket without stopping the server" {
    const allocator = std.testing.allocator;
    const fake_runtime = try fakeRuntimePath(allocator);
    defer allocator.free(fake_runtime);

    var external = try std.process.spawn(std.testing.io, .{
        .argv = &.{ "node", fake_runtime },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    defer external.kill(std.testing.io);
    const port = try readAnnouncedPort(allocator, std.testing.io, &external);
    external.stdout.?.close(std.testing.io);
    external.stdout = null;
    const uri = try std.fmt.allocPrint(allocator, "127.0.0.1:{d}", .{port});
    defer allocator.free(uri);

    try std.testing.expectError(
        error.JsonRpcError,
        Client.init(allocator, std.testing.io, .{
            .connection = .{ .uri = .{
                .uri = uri,
                .connection_token = "reject",
            } },
        }),
    );

    var client = try Client.init(allocator, std.testing.io, .{
        .connection = .{ .uri = .{ .uri = uri } },
    });
    defer client.deinit();
    const inspected = try client.callRpc(std.json.Value, "test.inspect", .{});
    defer inspected.deinit();
    try std.testing.expectEqual(
        @as(i64, 1),
        inspected.value.object.get("activeConnections").?.integer,
    );
}

test "failed TCP startup reaps the child before returning" {
    const allocator = std.testing.allocator;
    const fake_runtime = try fakeRuntimePath(allocator);
    defer allocator.free(fake_runtime);

    try std.testing.expectError(
        error.MissingRuntimePortAnnouncement,
        Client.init(allocator, std.testing.io, .{
            .connection = .{ .tcp = .{ .runtime = .{
                .executable = "node",
                .args = &.{ fake_runtime, "--no-listen" },
            } } },
        }),
    );
}

test "RPC handler registration rejects duplicates and unregisters" {
    const allocator = std.testing.allocator;
    var extension_values = ExtensionWireValues.init(allocator);
    defer extension_values.deinit();
    var client = Client{
        .allocator = allocator,
        .io = undefined,
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

test "TCP child connects and URI teardown leaves the external runtime alive" {
    const allocator = std.testing.allocator;
    const fake_runtime = try fakeRuntimePath(allocator);
    defer allocator.free(fake_runtime);

    var tcp_client = try Client.init(allocator, std.testing.io, .{
        .connection = .{ .tcp = .{ .runtime = .{
            .executable = "node",
            .args = &.{fake_runtime},
        } } },
    });
    const tcp_port = tcp_client.runtimePort().?;
    try std.testing.expect(tcp_port != 0);
    const tcp_inspection = try tcp_client.callRpc(std.json.Value, "test.inspect", .{});
    defer tcp_inspection.deinit();
    const tcp_args = tcp_inspection.value.object.get("args").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), tcp_args.len);
    try std.testing.expectEqualStrings("--headless", tcp_args[0].string);
    try std.testing.expectEqualStrings("--no-auto-update", tcp_args[1].string);
    const generated_token =
        tcp_inspection.value.object.get("env").?.object.get("COPILOT_CONNECTION_TOKEN").?.string;
    try std.testing.expect(generated_token.len != 0);
    try std.testing.expectEqualStrings(
        generated_token,
        tcp_inspection.value.object.get("lastRequest").?.object.get("params").?.object.get("token").?.string,
    );
    tcp_client.deinit();

    var external = try std.process.spawn(std.testing.io, .{
        .argv = &.{ "node", fake_runtime },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    defer external.kill(std.testing.io);
    const external_port = try readAnnouncedPort(allocator, std.testing.io, &external);
    external.stdout.?.close(std.testing.io);
    external.stdout = null;
    const uri = try std.fmt.allocPrint(allocator, "localhost:{d}", .{external_port});
    defer allocator.free(uri);

    var first = try Client.init(allocator, std.testing.io, .{
        .connection = .{ .uri = .{ .uri = uri } },
    });
    _ = try first.createSession(.{ .session_id = "external-session" });
    first.deinit();

    var second = try Client.init(allocator, std.testing.io, .{
        .connection = .{ .uri = .{ .uri = uri } },
    });
    defer second.deinit();
    const inspection = try second.callRpc(std.json.Value, "test.inspect", .{});
    defer inspection.deinit();
    try std.testing.expectEqual(@as(usize, 0), inspection.value.object.get("args").?.array.items.len);
    var saw_detach = false;
    for (inspection.value.object.get("requests").?.array.items) |request| {
        if (std.mem.eql(
            u8,
            "session.detach",
            request.object.get("method").?.string,
        )) {
            saw_detach = true;
            break;
        }
    }
    try std.testing.expect(saw_detach);
}

test "model and trace callbacks stay isolated per client" {
    const ModelContext = struct {
        model_id: []const u8,
        traceparent: []const u8,
    };
    const callbacks = struct {
        fn listModels(
            allocator: std.mem.Allocator,
            context_pointer: ?*anyopaque,
        ) !std.json.Parsed(models.ModelList) {
            const context: *ModelContext = @ptrCast(@alignCast(context_pointer.?));
            const json = try std.fmt.allocPrint(
                allocator,
                "{{\"models\":[{{\"id\":\"{s}\",\"name\":\"callback\",\"capabilities\":{{}}}}]}}",
                .{context.model_id},
            );
            defer allocator.free(json);
            return std.json.parseFromSlice(models.ModelList, allocator, json, .{
                .allocate = .alloc_always,
            });
        }

        fn traceContext(context_pointer: ?*anyopaque) !runtime_types.TraceContext {
            const context: *ModelContext = @ptrCast(@alignCast(context_pointer.?));
            return .{
                .traceparent = context.traceparent,
                .tracestate = "vendor=value",
            };
        }
    };

    const allocator = std.testing.allocator;
    const fake_runtime = try fakeRuntimePath(allocator);
    defer allocator.free(fake_runtime);
    var first_context = ModelContext{
        .model_id = "first-model",
        .traceparent = "00-11111111111111111111111111111111-1111111111111111-01",
    };
    var second_context = ModelContext{
        .model_id = "second-model",
        .traceparent = "00-22222222222222222222222222222222-2222222222222222-01",
    };
    var first = try Client.init(allocator, std.testing.io, .{
        .connection = .{ .stdio = .{ .runtime = .{
            .executable = "node",
            .args = &.{fake_runtime},
        } } },
        .on_list_models = .{
            .handler = callbacks.listModels,
            .context = &first_context,
        },
        .on_get_trace_context = .{
            .handler = callbacks.traceContext,
            .context = &first_context,
        },
    });
    defer first.deinit();
    var second = try Client.init(allocator, std.testing.io, .{
        .connection = .{ .stdio = .{ .runtime = .{
            .executable = "node",
            .args = &.{fake_runtime},
        } } },
        .on_list_models = .{
            .handler = callbacks.listModels,
            .context = &second_context,
        },
        .on_get_trace_context = .{
            .handler = callbacks.traceContext,
            .context = &second_context,
        },
    });
    defer second.deinit();

    const first_models = try first.listModels(.{});
    defer first_models.deinit();
    const second_models = try second.listModels(.{});
    defer second_models.deinit();
    try std.testing.expectEqualStrings("first-model", first_models.value.models[0].id);
    try std.testing.expectEqualStrings("second-model", second_models.value.models[0].id);

    const session = try first.createSession(.{ .session_id = "trace-session" });
    const create_inspection = try first.callRpc(std.json.Value, "test.inspect", .{});
    defer create_inspection.deinit();
    try expectTraceContext(
        create_inspection.value.object.get("lastRequest").?,
        first_context.traceparent,
    );

    const message_id = try session.send(.{ .prompt = "trace me" });
    defer allocator.free(message_id);
    const send_inspection = try first.callRpc(std.json.Value, "test.inspect", .{});
    defer send_inspection.deinit();
    try expectTraceContext(
        send_inspection.value.object.get("lastRequest").?,
        first_context.traceparent,
    );
    try session.disconnect();

    const resumed = try second.resumeSession("trace-resume", .{});
    const resume_inspection = try second.callRpc(std.json.Value, "test.inspect", .{});
    defer resume_inspection.deinit();
    try expectTraceContext(
        resume_inspection.value.object.get("lastRequest").?,
        second_context.traceparent,
    );
    try resumed.disconnect();
}

fn expectTraceContext(request: std.json.Value, traceparent: []const u8) !void {
    const params = request.object.get("params").?.object;
    try std.testing.expectEqualStrings(traceparent, params.get("traceparent").?.string);
    try std.testing.expectEqualStrings("vendor=value", params.get("tracestate").?.string);
}

fn findObservedRequest(
    requests: []const std.json.Value,
    method: []const u8,
) ?std.json.Value {
    return findObservedRequestAt(requests, method, 0);
}

fn findObservedRequestAt(
    requests: []const std.json.Value,
    method: []const u8,
    target_index: usize,
) ?std.json.Value {
    var match_index: usize = 0;
    for (requests) |request| {
        const object = switch (request) {
            .object => |value| value,
            else => continue,
        };
        const request_method = switch (object.get("method") orelse continue) {
            .string => |value| value,
            else => continue,
        };
        if (std.mem.eql(u8, request_method, method)) {
            if (match_index == target_index) return request;
            match_index += 1;
        }
    }
    return null;
}

test "empty mode lowers restrictive create and resume requests" {
    const allocator = std.testing.allocator;
    const fake_runtime = try fakeRuntimePath(allocator);
    defer allocator.free(fake_runtime);
    var client = try Client.init(allocator, std.testing.io, .{
        .connection = .{ .stdio = .{ .runtime = .{
            .executable = "node",
            .args = &.{fake_runtime},
            .mode = .empty,
            .base_directory = "/tmp/copilot-sdk-zig-empty",
        } } },
    });
    defer client.deinit();

    const created = try client.createSession(.{
        .session_id = "empty-create",
        .available_tools = &.{},
    });
    defer created.disconnect() catch {};
    const resumed = try client.resumeSession("empty-resume", .{
        .available_tools = &.{"builtin:ask_user"},
        .custom_agents_local_only = false,
        .skip_custom_instructions = false,
        .extensions = .{ .common = .{
            .skills = .{ .included_builtin = &.{"review"} },
        } },
    });
    defer resumed.disconnect() catch {};

    const inspected = try client.callRpc(std.json.Value, "test.inspect", .{});
    defer inspected.deinit();
    const requests = inspected.value.object.get("requests").?.array.items;
    const create_request = findObservedRequest(requests, "session.create").?;
    const create_json = try std.json.Stringify.valueAlloc(
        allocator,
        create_request.object.get("params").?,
        .{},
    );
    defer allocator.free(create_json);
    try std.testing.expectEqualStrings(
        "{\"sessionId\":\"empty-create\",\"streaming\":false,\"tools\":[],\"availableTools\":[],\"customAgentsLocalOnly\":true,\"toolFilterPrecedence\":\"excluded\",\"systemMessage\":{\"mode\":\"customize\",\"sections\":{\"environment_context\":{\"action\":\"remove\"}}},\"isExperimentalMode\":false,\"enableSessionTelemetry\":false,\"skipEmbeddingRetrieval\":true,\"embeddingCacheStorage\":\"in-memory\",\"enableFileHooks\":false,\"enableHostGitOperations\":false,\"enableSessionStore\":false,\"memory\":{\"enabled\":false},\"requestPermission\":false,\"requestUserInput\":false,\"enableSkills\":false,\"enableOnDemandInstructionDiscovery\":false,\"enableManagedSettings\":false,\"mcpOAuthTokenStorage\":\"in-memory\"}",
        create_json,
    );

    const resume_request = findObservedRequest(requests, "session.resume").?;
    const resume_json = try std.json.Stringify.valueAlloc(
        allocator,
        resume_request.object.get("params").?,
        .{},
    );
    defer allocator.free(resume_json);
    try std.testing.expectEqualStrings(
        "{\"sessionId\":\"empty-resume\",\"streaming\":false,\"tools\":[],\"availableTools\":[\"builtin:ask_user\"],\"customAgentsLocalOnly\":false,\"toolFilterPrecedence\":\"excluded\",\"systemMessage\":{\"mode\":\"customize\",\"sections\":{\"environment_context\":{\"action\":\"remove\"}}},\"isExperimentalMode\":false,\"enableSessionTelemetry\":false,\"skipEmbeddingRetrieval\":true,\"embeddingCacheStorage\":\"in-memory\",\"enableFileHooks\":false,\"enableHostGitOperations\":false,\"enableSessionStore\":false,\"memory\":{\"enabled\":false},\"requestPermission\":false,\"requestUserInput\":false,\"enableSkills\":false,\"skipCustomInstructions\":false,\"enableOnDemandInstructionDiscovery\":false,\"enableManagedSettings\":false,\"mcpOAuthTokenStorage\":\"in-memory\",\"includedBuiltinSkills\":[\"review\"]}",
        resume_json,
    );

    const update_request = findObservedRequest(requests, "session.options.update").?;
    const update_json = try std.json.Stringify.valueAlloc(
        allocator,
        update_request.object.get("params").?,
        .{},
    );
    defer allocator.free(update_json);
    try std.testing.expectEqualStrings(
        "{\"sessionId\":\"empty-create\",\"skipCustomInstructions\":true,\"customAgentsLocalOnly\":true,\"coauthorEnabled\":false,\"manageScheduleEnabled\":false,\"installedPlugins\":[],\"includedBuiltinSkills\":[]}",
        update_json,
    );
    const resume_update_request =
        findObservedRequestAt(requests, "session.options.update", 1).?;
    const resume_update_json = try std.json.Stringify.valueAlloc(
        allocator,
        resume_update_request.object.get("params").?,
        .{},
    );
    defer allocator.free(resume_update_json);
    try std.testing.expectEqualStrings(
        "{\"sessionId\":\"empty-resume\",\"skipCustomInstructions\":false,\"customAgentsLocalOnly\":false,\"coauthorEnabled\":false,\"manageScheduleEnabled\":false,\"installedPlugins\":[],\"includedBuiltinSkills\":[\"review\"]}",
        resume_update_json,
    );
}

test "empty mode rejects sessions without explicit available tools" {
    const allocator = std.testing.allocator;
    const fake_runtime = try fakeRuntimePath(allocator);
    defer allocator.free(fake_runtime);
    var client = try Client.init(allocator, std.testing.io, .{
        .connection = .{ .stdio = .{ .runtime = .{
            .executable = "node",
            .args = &.{fake_runtime},
            .mode = .empty,
            .base_directory = "/tmp/copilot-sdk-zig-empty",
        } } },
    });
    defer client.deinit();

    try std.testing.expectError(
        error.EmptyModeRequiresAvailableTools,
        client.createSession(.{ .session_id = "invalid-empty-create" }),
    );
    try std.testing.expectError(
        error.EmptyModeRequiresAvailableTools,
        client.resumeSession("invalid-empty-resume", .{}),
    );
    const inspected = try client.callRpc(std.json.Value, "test.inspect", .{});
    defer inspected.deinit();
    const requests = inspected.value.object.get("requests").?.array.items;
    try std.testing.expect(findObservedRequest(requests, "session.create") == null);
    try std.testing.expect(findObservedRequest(requests, "session.resume") == null);
}

test "URI empty mode requires available tools and lowers session defaults" {
    const allocator = std.testing.allocator;
    const fake_runtime = try fakeRuntimePath(allocator);
    defer allocator.free(fake_runtime);
    var external = try std.process.spawn(std.testing.io, .{
        .argv = &.{ "node", fake_runtime },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    defer external.kill(std.testing.io);
    const port = try readAnnouncedPort(allocator, std.testing.io, &external);
    external.stdout.?.close(std.testing.io);
    external.stdout = null;
    const uri = try std.fmt.allocPrint(allocator, "127.0.0.1:{d}", .{port});
    defer allocator.free(uri);

    var client = try Client.init(allocator, std.testing.io, .{
        .connection = .{ .uri = .{
            .uri = uri,
            .mode = .empty,
        } },
    });
    defer client.deinit();

    try std.testing.expectError(
        error.EmptyModeRequiresAvailableTools,
        client.createSession(.{ .session_id = "invalid-uri-empty" }),
    );
    const session = try client.createSession(.{
        .session_id = "uri-empty",
        .available_tools = &.{},
    });
    defer session.disconnect() catch {};

    const inspected = try client.callRpc(std.json.Value, "test.inspect", .{});
    defer inspected.deinit();
    const requests = inspected.value.object.get("requests").?.array.items;
    const create_request = findObservedRequest(requests, "session.create").?;
    const create_json = try std.json.Stringify.valueAlloc(
        allocator,
        create_request.object.get("params").?,
        .{},
    );
    defer allocator.free(create_json);
    try std.testing.expectEqualStrings(
        "{\"sessionId\":\"uri-empty\",\"streaming\":false,\"tools\":[],\"availableTools\":[],\"customAgentsLocalOnly\":true,\"toolFilterPrecedence\":\"excluded\",\"systemMessage\":{\"mode\":\"customize\",\"sections\":{\"environment_context\":{\"action\":\"remove\"}}},\"isExperimentalMode\":false,\"enableSessionTelemetry\":false,\"skipEmbeddingRetrieval\":true,\"embeddingCacheStorage\":\"in-memory\",\"enableFileHooks\":false,\"enableHostGitOperations\":false,\"enableSessionStore\":false,\"memory\":{\"enabled\":false},\"requestPermission\":false,\"requestUserInput\":false,\"enableSkills\":false,\"enableOnDemandInstructionDiscovery\":false,\"enableManagedSettings\":false,\"mcpOAuthTokenStorage\":\"in-memory\"}",
        create_json,
    );
    const update_request = findObservedRequest(requests, "session.options.update").?;
    const update_json = try std.json.Stringify.valueAlloc(
        allocator,
        update_request.object.get("params").?,
        .{},
    );
    defer allocator.free(update_json);
    try std.testing.expectEqualStrings(
        "{\"sessionId\":\"uri-empty\",\"skipCustomInstructions\":true,\"customAgentsLocalOnly\":true,\"coauthorEnabled\":false,\"manageScheduleEnabled\":false,\"installedPlugins\":[],\"includedBuiltinSkills\":[]}",
        update_json,
    );
}

test "empty mode rolls back when its options update fails" {
    const allocator = std.testing.allocator;
    const fake_runtime = try fakeRuntimePath(allocator);
    defer allocator.free(fake_runtime);
    var deinit_count: usize = 0;
    var client = try Client.init(allocator, std.testing.io, .{
        .connection = .{ .stdio = .{ .runtime = .{
            .executable = "node",
            .args = &.{ fake_runtime, "--fail-options-update" },
            .mode = .empty,
            .base_directory = "/tmp/copilot-sdk-zig-empty",
        } } },
        .session_filesystem = .{
            .initial_working_directory = "/workspace",
            .session_state_path = "/state",
            .conventions = .posix,
            .sqlite = true,
            .create_provider = createTestFilesystem,
            .context = &deinit_count,
        },
    });
    defer client.deinit();

    try std.testing.expectError(
        error.JsonRpcError,
        client.createSession(.{
            .session_id = "empty-update-failure",
            .available_tools = &.{},
        }),
    );
    try std.testing.expectEqual(@as(usize, 1), deinit_count);
    const inspected = try client.callRpc(std.json.Value, "test.inspect", .{});
    defer inspected.deinit();
    const requests = inspected.value.object.get("requests").?.array.items;
    try std.testing.expect(findObservedRequest(requests, "session.detach") != null);
}

test "trace callback failures are isolated from session requests" {
    const callbacks = struct {
        fn fail(_: ?*anyopaque) !runtime_types.TraceContext {
            return error.TraceUnavailable;
        }
    };
    const allocator = std.testing.allocator;
    const fake_runtime = try fakeRuntimePath(allocator);
    defer allocator.free(fake_runtime);
    var client = try Client.init(allocator, std.testing.io, .{
        .connection = .{ .stdio = .{ .runtime = .{
            .executable = "node",
            .args = &.{fake_runtime},
        } } },
        .on_get_trace_context = .{ .handler = callbacks.fail },
    });
    defer client.deinit();

    const session = try client.createSession(.{ .session_id = "no-trace" });
    defer session.disconnect() catch {};
    const inspected = try client.callRpc(std.json.Value, "test.inspect", .{});
    defer inspected.deinit();
    const params = inspected.value.object.get("lastRequest").?.object.get("params").?.object;
    try std.testing.expect(params.get("traceparent") == null);
    try std.testing.expect(params.get("tracestate") == null);
}

const TestFilesystemContext = struct {
    allocator: std.mem.Allocator,
    session_id: []u8,
    deinit_count: *usize,
};

fn createTestFilesystem(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    context_pointer: ?*anyopaque,
) !runtime_types.SessionFilesystemProvider {
    const deinit_count: *usize = @ptrCast(@alignCast(context_pointer.?));
    const context = try allocator.create(TestFilesystemContext);
    errdefer allocator.destroy(context);
    context.* = .{
        .allocator = allocator,
        .session_id = try allocator.dupe(u8, session_id),
        .deinit_count = deinit_count,
    };
    return .{
        .context = context,
        .read_file = testFilesystemReadFile,
        .write_file = testFilesystemWriteFile,
        .append_file = testFilesystemWriteFile,
        .exists = testFilesystemExists,
        .stat = testFilesystemStat,
        .make_directory = testFilesystemMakeDirectory,
        .read_directory = testFilesystemReadDirectory,
        .read_directory_with_types = testFilesystemReadDirectoryWithTypes,
        .remove = testFilesystemRemove,
        .rename = testFilesystemRename,
        .sqlite = .{
            .query = testFilesystemSqliteQuery,
            .transaction = testFilesystemSqliteTransaction,
            .exists = testFilesystemSqliteExists,
        },
        .deinit = deinitTestFilesystem,
    };
}

fn testFilesystemReadFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    context_pointer: ?*anyopaque,
) ![]u8 {
    const context: *TestFilesystemContext = @ptrCast(@alignCast(context_pointer.?));
    if (std.mem.eql(u8, path, "/missing")) return error.FileNotFound;
    return std.fmt.allocPrint(allocator, "{s}:{s}", .{ context.session_id, path });
}

fn testFilesystemWriteFile(
    _: []const u8,
    _: []const u8,
    _: ?u32,
    _: ?*anyopaque,
) !void {}

fn testFilesystemExists(_: []const u8, _: ?*anyopaque) !bool {
    return true;
}

fn testFilesystemStat(
    _: []const u8,
    _: ?*anyopaque,
) !runtime_types.SessionFilesystemFileInfo {
    return .{
        .is_file = true,
        .is_directory = false,
        .size = 4,
        .mtime = "2026-09-13T00:00:00.000Z",
        .birthtime = "2026-09-12T00:00:00.000Z",
    };
}

fn testFilesystemMakeDirectory(
    _: []const u8,
    _: bool,
    _: ?u32,
    _: ?*anyopaque,
) !void {}

fn testFilesystemReadDirectory(
    allocator: std.mem.Allocator,
    _: []const u8,
    _: ?*anyopaque,
) !std.json.Parsed(runtime_types.SessionFilesystemReadDirectoryResult) {
    return std.json.parseFromSlice(
        runtime_types.SessionFilesystemReadDirectoryResult,
        allocator,
        "{\"entries\":[\"a\",\"b\"]}",
        .{ .allocate = .alloc_always },
    );
}

fn testFilesystemReadDirectoryWithTypes(
    allocator: std.mem.Allocator,
    _: []const u8,
    _: ?*anyopaque,
) !std.json.Parsed(runtime_types.SessionFilesystemReadDirectoryWithTypesResult) {
    return std.json.parseFromSlice(
        runtime_types.SessionFilesystemReadDirectoryWithTypesResult,
        allocator,
        "{\"entries\":[{\"name\":\"a\",\"entry_type\":\"file\"}]}",
        .{ .allocate = .alloc_always },
    );
}

fn testFilesystemRemove(
    _: []const u8,
    _: bool,
    _: bool,
    _: ?*anyopaque,
) !void {}

fn testFilesystemRename(_: []const u8, _: []const u8, _: ?*anyopaque) !void {}

fn testFilesystemSqliteQuery(
    allocator: std.mem.Allocator,
    _: runtime_types.SessionFilesystemSqliteQueryType,
    query: []const u8,
    _: ?std.json.Value,
    _: ?*anyopaque,
) !std.json.Parsed(runtime_types.SessionFilesystemSqliteQueryResult) {
    if (std.mem.eql(u8, query, "callback-error"))
        return error.DatabaseUnavailable;
    return std.json.parseFromSlice(
        runtime_types.SessionFilesystemSqliteQueryResult,
        allocator,
        if (std.mem.eql(u8, query, "invalid"))
            "{\"columns\":[],\"rows\":[1],\"rows_affected\":0}"
        else
            "{\"columns\":[\"value\"],\"rows\":[{\"value\":7}],\"rows_affected\":0}",
        .{ .allocate = .alloc_always },
    );
}

fn testFilesystemSqliteTransaction(
    allocator: std.mem.Allocator,
    statements: []const runtime_types.SessionFilesystemSqliteStatement,
    _: ?*anyopaque,
) !std.json.Parsed(runtime_types.SessionFilesystemSqliteTransactionResult) {
    return std.json.parseFromSlice(
        runtime_types.SessionFilesystemSqliteTransactionResult,
        allocator,
        if (statements.len == 1)
            "{\"results\":[{\"columns\":[],\"rows\":[],\"rows_affected\":1,\"last_insert_rowid\":9}]}"
        else
            "{\"results\":[]}",
        .{ .allocate = .alloc_always },
    );
}

fn testFilesystemSqliteExists(context_pointer: ?*anyopaque) !bool {
    const context: *TestFilesystemContext = @ptrCast(@alignCast(context_pointer.?));
    if (std.mem.eql(u8, context.session_id, "fs-sqlite-error"))
        return error.DatabaseUnavailable;
    return true;
}

fn deinitTestFilesystem(context_pointer: ?*anyopaque) void {
    const context: *TestFilesystemContext = @ptrCast(@alignCast(context_pointer.?));
    context.deinit_count.* += 1;
    context.allocator.free(context.session_id);
    context.allocator.destroy(context);
}

test "session filesystem routes by session and reports protocol errors" {
    const allocator = std.testing.allocator;
    const fake_runtime = try fakeRuntimePath(allocator);
    defer allocator.free(fake_runtime);
    var deinit_count: usize = 0;
    var client = try Client.init(allocator, std.testing.io, .{
        .connection = .{ .stdio = .{ .runtime = .{
            .executable = "node",
            .args = &.{fake_runtime},
        } } },
        .session_filesystem = .{
            .initial_working_directory = "/workspace",
            .session_state_path = "/state",
            .conventions = .posix,
            .sqlite = true,
            .create_provider = createTestFilesystem,
            .context = &deinit_count,
        },
    });
    defer client.deinit();
    const first_session = try client.createSession(.{ .session_id = "fs-one" });
    const second_session = try client.createSession(.{ .session_id = "fs-two" });

    const read_result = try client.callRpc(std.json.Value, "test.fs", .{
        .method = "sessionFs.readFile",
        .params = .{ .sessionId = "fs-one", .path = "/note.txt" },
    });
    defer read_result.deinit();
    try std.testing.expectEqualStrings(
        "fs-one:/note.txt",
        read_result.value.object.get("result").?.object.get("content").?.string,
    );
    try std.testing.expect(
        read_result.value.object.get("result").?.object.get("error") == null,
    );
    const second_read_result = try client.callRpc(std.json.Value, "test.fs", .{
        .method = "sessionFs.readFile",
        .params = .{ .sessionId = "fs-two", .path = "/note.txt" },
    });
    defer second_read_result.deinit();
    try std.testing.expectEqualStrings(
        "fs-two:/note.txt",
        second_read_result.value.object.get("result").?.object.get("content").?.string,
    );

    const missing_result = try client.callRpc(std.json.Value, "test.fs", .{
        .method = "sessionFs.readFile",
        .params = .{ .sessionId = "fs-one", .path = "/missing" },
    });
    defer missing_result.deinit();
    try std.testing.expectEqualStrings(
        "ENOENT",
        missing_result.value.object.get("result").?.object.get("error").?.object.get("code").?.string,
    );

    const entries_result = try client.callRpc(std.json.Value, "test.fs", .{
        .method = "sessionFs.readdirWithTypes",
        .params = .{ .sessionId = "fs-one", .path = "/" },
    });
    defer entries_result.deinit();
    const first_entry =
        entries_result.value.object.get("result").?.object.get("entries").?.array.items[0].object;
    try std.testing.expectEqualStrings("a", first_entry.get("name").?.string);
    try std.testing.expectEqualStrings("file", first_entry.get("type").?.string);

    const query_result = try client.callRpc(std.json.Value, "test.fs", .{
        .method = "sessionFs.sqliteQuery",
        .params = .{
            .sessionId = "fs-one",
            .queryType = "query",
            .query = "select 7",
        },
    });
    defer query_result.deinit();
    const query_wire = query_result.value.object.get("result").?.object;
    try std.testing.expectEqual(@as(i64, 0), query_wire.get("rowsAffected").?.integer);
    try std.testing.expect(query_wire.get("lastInsertRowid") == null);
    try std.testing.expectEqual(
        @as(i64, 7),
        query_wire.get("rows").?.array.items[0].object.get("value").?.integer,
    );

    const transaction_result = try client.callRpc(std.json.Value, "test.fs", .{
        .method = "sessionFs.sqliteTransaction",
        .params = .{
            .sessionId = "fs-one",
            .statements = &.{.{
                .queryType = "run",
                .query = "insert into values_table values (7)",
            }},
        },
    });
    defer transaction_result.deinit();
    const transaction_wire =
        transaction_result.value.object.get("result").?.object.get("results").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 1), transaction_wire.get("rowsAffected").?.integer);
    try std.testing.expectEqual(@as(i64, 9), transaction_wire.get("lastInsertRowid").?.integer);

    const malformed_result = try client.callRpc(std.json.Value, "test.fs", .{
        .method = "sessionFs.readFile",
        .params = .{ .sessionId = "fs-one" },
    });
    defer malformed_result.deinit();
    try std.testing.expectEqual(
        @as(i64, -32602),
        malformed_result.value.object.get("error").?.object.get("code").?.integer,
    );

    const invalid_result = try client.callRpc(std.json.Value, "test.fs", .{
        .method = "sessionFs.sqliteQuery",
        .params = .{
            .sessionId = "fs-one",
            .queryType = "query",
            .query = "invalid",
        },
    });
    defer invalid_result.deinit();
    try std.testing.expectEqual(
        @as(i64, -32603),
        invalid_result.value.object.get("error").?.object.get("code").?.integer,
    );

    const invalid_params = try client.callRpc(std.json.Value, "test.fs", .{
        .method = "sessionFs.sqliteQuery",
        .params = .{
            .sessionId = "fs-one",
            .queryType = "query",
            .query = "select 7",
            .params = &.{"not-an-object"},
        },
    });
    defer invalid_params.deinit();
    try std.testing.expectEqual(
        @as(i64, -32602),
        invalid_params.value.object.get("error").?.object.get("code").?.integer,
    );

    const callback_error = try client.callRpc(std.json.Value, "test.fs", .{
        .method = "sessionFs.sqliteQuery",
        .params = .{
            .sessionId = "fs-one",
            .queryType = "query",
            .query = "callback-error",
        },
    });
    defer callback_error.deinit();
    try std.testing.expectEqual(
        @as(i64, -32000),
        callback_error.value.object.get("error").?.object.get("code").?.integer,
    );

    try first_session.disconnect();
    try second_session.disconnect();
    try std.testing.expectEqual(@as(usize, 2), deinit_count);
}

test "session filesystem provider rolls back when session creation fails" {
    const allocator = std.testing.allocator;
    const fake_runtime = try fakeRuntimePath(allocator);
    defer allocator.free(fake_runtime);
    var deinit_count: usize = 0;
    var client = try Client.init(allocator, std.testing.io, .{
        .connection = .{ .stdio = .{ .runtime = .{
            .executable = "node",
            .args = &.{ fake_runtime, "--fail-session" },
        } } },
        .session_filesystem = .{
            .initial_working_directory = "/workspace",
            .session_state_path = "/state",
            .conventions = .posix,
            .sqlite = true,
            .create_provider = createTestFilesystem,
            .context = &deinit_count,
        },
    });
    defer client.deinit();

    try std.testing.expectError(
        error.JsonRpcError,
        client.createSession(.{ .session_id = "rollback" }),
    );
    try std.testing.expectEqual(@as(usize, 1), deinit_count);
}

test "sqliteExists provider errors remain correlated JSON-RPC errors" {
    const allocator = std.testing.allocator;
    const fake_runtime = try fakeRuntimePath(allocator);
    defer allocator.free(fake_runtime);
    var deinit_count: usize = 0;
    var client = try Client.init(allocator, std.testing.io, .{
        .connection = .{ .stdio = .{ .runtime = .{
            .executable = "node",
            .args = &.{fake_runtime},
        } } },
        .session_filesystem = .{
            .initial_working_directory = "/workspace",
            .session_state_path = "/state",
            .conventions = .posix,
            .sqlite = true,
            .create_provider = createTestFilesystem,
            .context = &deinit_count,
        },
    });
    defer client.deinit();
    const session = try client.createSession(.{ .session_id = "fs-sqlite-error" });
    defer session.disconnect() catch {};

    const response = try client.callRpc(std.json.Value, "test.fs", .{
        .method = "sessionFs.sqliteExists",
        .params = .{ .sessionId = "fs-sqlite-error" },
    });
    defer response.deinit();
    const rpc_error = response.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32000), rpc_error.get("code").?.integer);
    try std.testing.expectEqualStrings(
        "DatabaseUnavailable",
        rpc_error.get("message").?.string,
    );
}

fn fakeRuntimePath(allocator: std.mem.Allocator) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, "tests/fake_runtime.mjs" });
}

test "user input handler receives requests and returns responses" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = undefined,
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
        .transport = .{ .fixture = .{
            .reader = &reader,
            .writer = &writer,
            .reader_buffer = &.{},
            .writer_buffer = &writer_buffer,
        } },
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
        .transport = .{ .fixture = .{
            .reader = null,
            .writer = &writer,
            .reader_buffer = &.{},
            .writer_buffer = &.{},
        } },
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
        .transport = .{ .fixture = .{
            .reader = &reader,
            .writer = &writer,
            .reader_buffer = &.{},
            .writer_buffer = &.{},
        } },
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
        .transport = .{ .fixture = .{
            .reader = &reader,
            .writer = &writer,
            .reader_buffer = &.{},
            .writer_buffer = &.{},
        } },
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
        .copilot_cli,
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
        .copilot_cli,
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
            .transport = .{ .fixture = .{
                .reader = &reader,
                .writer = &writer,
                .reader_buffer = &.{},
                .writer_buffer = &writer_buffer,
            } },
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
        .transport = .{ .fixture = .{
            .reader = &reader,
            .writer = &writer,
            .reader_buffer = &.{},
            .writer_buffer = &writer_buffer,
        } },
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
        .transport = .{ .fixture = .{
            .reader = &reader,
            .writer = &writer,
            .reader_buffer = &.{},
            .writer_buffer = &writer_buffer,
        } },
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
        .transport = .{ .fixture = .{
            .reader = reader,
            .writer = writer,
            .reader_buffer = reader_buffer,
            .writer_buffer = writer_buffer,
            .owns_allocations = true,
        } },
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

test "client teardown bounds OAuth interest release and reaps the child" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const fake_runtime = try fakeRuntimePath(allocator);
    defer allocator.free(fake_runtime);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const pid_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/runtime.pid",
        .{tmp.sub_path},
    );
    defer allocator.free(pid_path);
    const handler = struct {
        fn handle(
            _: std.mem.Allocator,
            _: ext.McpAuthRequest,
            _: ?*anyopaque,
        ) !ext.McpAuthResult {
            return .cancelled;
        }
    }.handle;

    var client = try Client.init(allocator, std.testing.io, .{
        .connection = .{ .stdio = .{ .runtime = .{
            .executable = "node",
            .args = &.{
                fake_runtime,
                "--pid-path",
                pid_path,
                "--hang-release-interest",
            },
        } } },
    });
    _ = try client.createSession(.{
        .session_id = "hung-release",
        .extensions = .{ .common = .{ .mcp = .{
            .on_auth_request = handler,
        } } },
    });
    try std.testing.expectEqualStrings(
        "interest-1",
        client.findExtensionRuntime("hung-release").?.mcp_oauth_interest_handle.?,
    );

    const start = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    client.deinit();
    const elapsed = start.durationTo(std.Io.Clock.Timestamp.now(std.testing.io, .awake));
    try std.testing.expect(elapsed.raw.toMilliseconds() < 1000);

    const pid_text = try tmp.dir.readFileAlloc(
        std.testing.io,
        "runtime.pid",
        allocator,
        .limited(64),
    );
    defer allocator.free(pid_text);
    const pid = try std.fmt.parseInt(std.posix.pid_t, pid_text, 10);
    try std.testing.expectError(error.ProcessNotFound, std.posix.kill(pid, .CONT));
}

test "transport buffer teardown wipes reader and writer storage" {
    var reader_buffer = [_]u8{0x5a} ** 16;
    var writer_buffer = [_]u8{0xa5} ** 16;
    var client = Client{
        .allocator = std.testing.allocator,
        .io = undefined,
        .transport = .{ .fixture = .{
            .reader = null,
            .writer = null,
            .reader_buffer = &reader_buffer,
            .writer_buffer = &writer_buffer,
        } },
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
        .transport = .{ .fixture = .{
            .reader = &reader,
            .writer = &writer,
            .reader_buffer = &.{},
            .writer_buffer = &writer_buffer,
        } },
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
        .transport = .{ .fixture = .{
            .reader = &reader,
            .writer = &writer,
            .reader_buffer = &.{},
            .writer_buffer = &writer_buffer,
        } },
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
        .copilot_cli,
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
            .copilot_cli,
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
            .copilot_cli,
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
            .copilot_cli,
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
            .copilot_cli,
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
            .transport = .{ .fixture = .{
                .reader = &reader,
                .writer = &writer,
                .reader_buffer = &.{},
                .writer_buffer = &.{},
            } },
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
        .transport = .{ .fixture = .{
            .reader = &reader,
            .writer = &writer,
            .reader_buffer = &.{},
            .writer_buffer = &.{},
        } },
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
        .transport = .{ .fixture = .{
            .reader = &reader,
            .writer = &writer,
            .reader_buffer = &.{},
            .writer_buffer = &.{},
        } },
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
            .transport = .{ .fixture = .{
                .reader = &reader,
                .writer = &writer,
                .reader_buffer = &.{},
                .writer_buffer = &.{},
            } },
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
        .transport = .{ .fixture = .{
            .reader = &reader,
            .writer = &writer,
            .reader_buffer = &.{},
            .writer_buffer = &.{},
        } },
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
        .transport = .{ .fixture = .{
            .reader = &reader,
            .writer = &writer,
            .reader_buffer = &.{},
            .writer_buffer = &.{},
        } },
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
        .transport = .{ .fixture = .{
            .reader = reader,
            .writer = writer,
            .reader_buffer = reader_buffer,
            .writer_buffer = writer_buffer,
            .owns_allocations = true,
        } },
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
