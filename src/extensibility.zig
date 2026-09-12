const std = @import("std");

pub const CapabilityState = enum {
    unknown,
    unsupported,
    supported,
};

pub const Capability = enum {
    canvases,
    mcp_apps,
};

pub const CapabilitySet = struct {
    canvases: CapabilityState = .unknown,
    mcp_apps: CapabilityState = .unknown,

    pub fn state(self: CapabilitySet, capability: Capability) CapabilityState {
        return switch (capability) {
            .canvases => self.canvases,
            .mcp_apps => self.mcp_apps,
        };
    }

    pub fn supports(self: CapabilitySet, capability: Capability) bool {
        return self.state(capability) == .supported;
    }
};

pub const ExtensionInfo = struct {
    source: []const u8,
    name: []const u8,
};

pub const CanvasProviderIdentity = struct {
    id: []const u8,
    name: ?[]const u8 = null,
};

pub const SkillsConfig = struct {
    enabled: ?bool = null,
    directories: []const []const u8 = &.{},
    disabled: []const []const u8 = &.{},
    included_builtin: []const []const u8 = &.{},
};

pub const NameValue = struct {
    name: []const u8,
    value: []const u8,
};

pub const McpServer = struct {
    name: []const u8,
    config: McpServerConfig,
};

pub const McpServerConfig = union(enum) {
    stdio: Stdio,
    http: Http,

    pub const Stdio = struct {
        command: []const u8,
        args: []const []const u8 = &.{},
        env: []const NameValue = &.{},
        working_directory: ?[]const u8 = null,
        tools: ?[]const []const u8 = null,
        timeout_ms: ?u32 = null,
    };

    pub const Http = struct {
        transport: enum { http, sse } = .http,
        url: []const u8,
        headers: []const NameValue = &.{},
        tools: ?[]const []const u8 = null,
        timeout_ms: ?u32 = null,
    };
};

pub const McpOAuthTokenStorage = enum {
    persistent,
    in_memory,
};

pub const McpAuthReason = enum {
    initial,
    refresh,
    reauth,
    upscope,
};

pub const McpAuthRequest = struct {
    request_id: []const u8,
    server_name: []const u8,
    server_url: []const u8,
    reason: McpAuthReason,
    resource_metadata: ?[]const u8 = null,
    www_authenticate_json: ?[]const u8 = null,
    http_response_json: ?[]const u8 = null,
    static_client_config_json: ?[]const u8 = null,
};

pub const McpAuthResult = union(enum) {
    cancelled,
    token: Token,

    pub const Token = struct {
        access_token: []u8,
        token_type: ?[]u8 = null,
        expires_in_seconds: ?u64 = null,

        pub fn deinitSecure(self: *Token, allocator: std.mem.Allocator) void {
            @memset(self.access_token, 0);
            allocator.free(self.access_token);
            if (self.token_type) |value| {
                @memset(value, 0);
                allocator.free(value);
            }
            self.* = undefined;
        }
    };
};

pub const McpAuthHandler = *const fn (
    allocator: std.mem.Allocator,
    request: McpAuthRequest,
    context: ?*anyopaque,
) anyerror!McpAuthResult;

pub const McpConfig = struct {
    servers: []const McpServer = &.{},
    disabled_servers: []const []const u8 = &.{},
    oauth_token_storage: McpOAuthTokenStorage = .in_memory,
    auth_client_id_metadata_url: ?[]const u8 = null,
    on_auth_request: ?McpAuthHandler = null,
    auth_context: ?*anyopaque = null,
};

pub const HookInvocation = struct {
    session_id: []const u8,
};

pub const HookBaseInput = struct {
    runtime_session_id: []const u8,
    timestamp_ms: i64,
    working_directory: []const u8,
};

pub const PreToolUseInput = struct {
    base: HookBaseInput,
    tool_name: []const u8,
    tool_args_json: []const u8,
};

pub const PreToolUseOutput = struct {
    permission_decision: ?enum { allow, deny, ask } = null,
    permission_decision_reason: ?[]const u8 = null,
    modified_args_json: ?[]const u8 = null,
    additional_context: ?[]const u8 = null,
    suppress_output: ?bool = null,
};

pub const PreMcpToolCallInput = struct {
    base: HookBaseInput,
    tool_call_id: ?[]const u8 = null,
    server_name: []const u8,
    tool_name: []const u8,
    arguments_json: []const u8,
    meta_json: ?[]const u8 = null,
};

pub const PreMcpToolCallOutput = struct {
    meta_to_use_json: ?[]const u8 = null,
    omit_meta: bool = false,
};

pub const PostToolUseInput = struct {
    base: HookBaseInput,
    tool_name: []const u8,
    tool_args_json: []const u8,
    tool_result_json: []const u8,
};

pub const PostToolUseOutput = struct {
    modified_result_json: ?[]const u8 = null,
    additional_context: ?[]const u8 = null,
    suppress_output: ?bool = null,
};

pub const PostToolUseFailureInput = struct {
    base: HookBaseInput,
    tool_name: []const u8,
    tool_args_json: []const u8,
    message: []const u8,
};

pub const PostToolUseFailureOutput = struct {
    additional_context: ?[]const u8 = null,
};

pub const UserPromptSubmittedInput = struct {
    base: HookBaseInput,
    prompt: []const u8,
};

pub const UserPromptSubmittedOutput = struct {
    modified_prompt: ?[]const u8 = null,
    additional_context: ?[]const u8 = null,
    suppress_output: ?bool = null,
};

pub const UserPromptTransformedInput = struct {
    base: HookBaseInput,
    prompt: []const u8,
    transformed_prompt: []const u8,
};

pub const UserPromptTransformedOutput = struct {
    modified_transformed_prompt: ?[]const u8 = null,
};

pub const SessionStartInput = struct {
    base: HookBaseInput,
    source: enum { startup, resumed, created },
    initial_prompt: ?[]const u8 = null,
};

pub const SessionStartOutput = struct {
    additional_context: ?[]const u8 = null,
    modified_config_json: ?[]const u8 = null,
};

pub const SessionEndInput = struct {
    base: HookBaseInput,
    reason: enum { complete, @"error", abort, timeout, user_exit },
    final_message: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

pub const SessionEndOutput = struct {
    suppress_output: ?bool = null,
    cleanup_actions: ?[]const []const u8 = null,
    session_summary: ?[]const u8 = null,
};

pub const ErrorOccurredInput = struct {
    base: HookBaseInput,
    message: []const u8,
    context: enum { model_call, tool_execution, system, user_input },
    recoverable: bool,
};

pub const ErrorOccurredOutput = struct {
    suppress_output: ?bool = null,
    handling: ?enum { retry, skip, abort } = null,
    retry_count: ?u32 = null,
    user_notification: ?[]const u8 = null,
};

pub const AgentStopInput = struct {
    base: HookBaseInput,
    stop_reason: ?[]const u8 = null,
    transcript_path: ?[]const u8 = null,
    stop_hook_active: bool = false,
};

pub const AgentStopOutput = struct {
    block: bool = false,
    reason: ?[]const u8 = null,
};

pub const SessionHooks = struct {
    on_pre_tool_use: ?*const fn (std.mem.Allocator, PreToolUseInput, HookInvocation, ?*anyopaque) anyerror!PreToolUseOutput = null,
    on_pre_mcp_tool_call: ?*const fn (std.mem.Allocator, PreMcpToolCallInput, HookInvocation, ?*anyopaque) anyerror!PreMcpToolCallOutput = null,
    on_post_tool_use: ?*const fn (std.mem.Allocator, PostToolUseInput, HookInvocation, ?*anyopaque) anyerror!PostToolUseOutput = null,
    on_post_tool_use_failure: ?*const fn (std.mem.Allocator, PostToolUseFailureInput, HookInvocation, ?*anyopaque) anyerror!PostToolUseFailureOutput = null,
    on_user_prompt_submitted: ?*const fn (std.mem.Allocator, UserPromptSubmittedInput, HookInvocation, ?*anyopaque) anyerror!UserPromptSubmittedOutput = null,
    on_user_prompt_transformed: ?*const fn (std.mem.Allocator, UserPromptTransformedInput, HookInvocation, ?*anyopaque) anyerror!UserPromptTransformedOutput = null,
    on_session_start: ?*const fn (std.mem.Allocator, SessionStartInput, HookInvocation, ?*anyopaque) anyerror!SessionStartOutput = null,
    on_session_end: ?*const fn (std.mem.Allocator, SessionEndInput, HookInvocation, ?*anyopaque) anyerror!SessionEndOutput = null,
    on_error_occurred: ?*const fn (std.mem.Allocator, ErrorOccurredInput, HookInvocation, ?*anyopaque) anyerror!ErrorOccurredOutput = null,
    on_agent_stop: ?*const fn (std.mem.Allocator, AgentStopInput, HookInvocation, ?*anyopaque) anyerror!AgentStopOutput = null,
    context: ?*anyopaque = null,

    pub fn any(self: SessionHooks) bool {
        return self.on_pre_tool_use != null or self.on_pre_mcp_tool_call != null or
            self.on_post_tool_use != null or self.on_post_tool_use_failure != null or
            self.on_user_prompt_submitted != null or self.on_user_prompt_transformed != null or
            self.on_session_start != null or self.on_session_end != null or
            self.on_error_occurred != null or self.on_agent_stop != null;
    }
};

pub const CanvasDeclaration = struct {
    id: []const u8,
    display_name: []const u8,
    description: []const u8,
    input_schema_json: ?[]const u8 = null,
};

pub const CanvasOpenRequest = struct {
    extension_id: []const u8,
    canvas_id: []const u8,
    instance_id: []const u8,
    input_json: ?[]const u8 = null,
    host_json: ?[]const u8 = null,
    session_json: ?[]const u8 = null,
};

pub const CanvasOpenResult = struct {
    url: ?[]const u8 = null,
    title: ?[]const u8 = null,
    status: ?[]const u8 = null,
};

pub const CanvasCloseRequest = struct {
    extension_id: []const u8,
    canvas_id: []const u8,
    instance_id: []const u8,
    host_json: ?[]const u8 = null,
    session_json: ?[]const u8 = null,
};

pub const CanvasActionRequest = struct {
    extension_id: []const u8,
    canvas_id: []const u8,
    instance_id: []const u8,
    action_name: []const u8,
    input_json: ?[]const u8 = null,
    host_json: ?[]const u8 = null,
    session_json: ?[]const u8 = null,
};

pub const CanvasAction = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    input_schema_json: ?[]const u8 = null,
    handler: *const fn (std.mem.Allocator, CanvasActionRequest, ?*anyopaque) anyerror![]u8,
};

pub const Canvas = struct {
    declaration: CanvasDeclaration,
    on_open: *const fn (std.mem.Allocator, CanvasOpenRequest, ?*anyopaque) anyerror!CanvasOpenResult,
    on_close: ?*const fn (CanvasCloseRequest, ?*anyopaque) anyerror!void = null,
    actions: []const CanvasAction = &.{},
    context: ?*anyopaque = null,
};

pub const OpenCanvas = struct {
    instance_id: []const u8,
    extension_id: []const u8,
    extension_name: ?[]const u8 = null,
    canvas_id: []const u8,
    icon: ?[]const u8 = null,
    title: ?[]const u8 = null,
    status: ?[]const u8 = null,
    url: ?[]const u8 = null,
    input_json: ?[]const u8 = null,
};

pub const OpenCanvasSnapshot = struct {
    allocator: std.mem.Allocator,
    items: []OpenCanvas,

    pub fn deinit(self: *OpenCanvasSnapshot) void {
        for (self.items) |item| freeOpenCanvas(self.allocator, item);
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub const OpenCanvasResult = struct {
    allocator: std.mem.Allocator,
    value: OpenCanvas,

    pub fn deinit(self: *OpenCanvasResult) void {
        freeOpenCanvas(self.allocator, self.value);
        self.* = undefined;
    }
};

pub const OpenCanvasRequest = struct {
    extension_id: ?[]const u8 = null,
    canvas_id: []const u8,
    instance_id: []const u8,
    input_json: ?[]const u8 = null,
};

pub const InvokeCanvasActionRequest = struct {
    instance_id: []const u8,
    action_name: []const u8,
    input_json: ?[]const u8 = null,
};

pub const ExperimentalRequests = struct {
    mcp_apps: bool = false,
};

pub const ExperimentalFeature = enum {
    mcp_apps,
};

pub const OwnedJson = struct {
    allocator: std.mem.Allocator,
    json: []u8,

    pub fn deinit(self: *OwnedJson) void {
        self.allocator.free(self.json);
        self.* = undefined;
    }
};

pub const McpAppToolCall = struct {
    server_name: []const u8,
    tool_name: []const u8,
    arguments_json: []const u8 = "{}",
    origin_server_name: []const u8,
};

pub const EnvironmentGrant = struct {
    name: []const u8,
    value: []const u8,
};

fn wipeSecret(value: []const u8) void {
    @memset(@constCast(value), 0);
}

pub const EnvironmentGrants = struct {
    allocator: std.mem.Allocator,
    items: []EnvironmentGrant,

    pub fn deinit(self: *EnvironmentGrants) void {
        for (self.items) |item| {
            self.allocator.free(item.name);
            wipeSecret(item.value);
            self.allocator.free(item.value);
        }
        self.allocator.free(self.items);
        self.* = undefined;
    }

    pub fn get(self: EnvironmentGrants, name: []const u8) ?[]const u8 {
        for (self.items) |item| {
            if (std.mem.eql(u8, item.name, name)) return item.value;
        }
        return null;
    }
};

test "environment grant teardown wipes secret bytes" {
    var secret = [_]u8{ 's', 'e', 'c', 'r', 'e', 't' };
    wipeSecret(&secret);
    for (secret) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

pub const SessionFeatures = struct {
    plugin_directories: []const []const u8 = &.{},
    skills: SkillsConfig = .{},
    hooks: SessionHooks = .{},
    mcp: McpConfig = .{},
    canvases: []const Canvas = &.{},
    request_canvas_renderer: bool = false,
    request_extensions: bool = false,
    extension_info: ?ExtensionInfo = null,
    experimental: ExperimentalRequests = .{},
};

pub const CreateExtensions = struct {
    common: SessionFeatures = .{},
    extension_sdk_path: ?[]const u8 = null,
    canvas_provider: ?CanvasProviderIdentity = null,
};

pub const ResumeExtensions = struct {
    common: SessionFeatures = .{},
    extension_sdk_path: ?[]const u8 = null,
    canvas_provider: ?CanvasProviderIdentity = null,
    open_canvases: []const OpenCanvas = &.{},
};

pub const JoinExtensions = struct {
    common: SessionFeatures = .{},
    canvas_provider: ?CanvasProviderIdentity = null,
    open_canvases: []const OpenCanvas = &.{},
    requested_environment_variables: []const []const u8 = &.{},
};

pub fn validate(features: SessionFeatures) !void {
    try uniqueNonEmpty(features.plugin_directories, error.DuplicatePluginDirectory);
    try uniqueNonEmpty(features.skills.directories, error.DuplicateSkillDirectory);
    for (features.mcp.servers, 0..) |server, index| {
        if (server.name.len == 0) return error.InvalidMcpServer;
        for (features.mcp.servers[0..index]) |previous| {
            if (std.mem.eql(u8, previous.name, server.name)) return error.DuplicateMcpServerName;
        }
        switch (server.config) {
            .stdio => |value| {
                if (value.command.len == 0 or
                    (value.timeout_ms != null and value.timeout_ms.? == 0))
                    return error.InvalidMcpServer;
            },
            .http => |value| {
                if (value.url.len == 0 or
                    (value.timeout_ms != null and value.timeout_ms.? == 0))
                    return error.InvalidMcpServer;
                for (value.headers, 0..) |header, header_index| {
                    if (header.name.len == 0) return error.InvalidMcpServer;
                    for (value.headers[0..header_index]) |previous| {
                        if (std.ascii.eqlIgnoreCase(previous.name, header.name))
                            return error.DuplicateMcpHeaderName;
                    }
                }
            },
        }
    }
    for (features.canvases, 0..) |canvas, index| {
        if (canvas.declaration.id.len == 0) return error.InvalidCanvas;
        for (features.canvases[0..index]) |previous| {
            if (std.mem.eql(u8, previous.declaration.id, canvas.declaration.id))
                return error.DuplicateCanvasId;
        }
        if (canvas.declaration.input_schema_json) |json| try validateJsonSchema(json);
        for (canvas.actions, 0..) |action, action_index| {
            if (action.name.len == 0 or std.mem.startsWith(u8, action.name, "canvas."))
                return error.ReservedCanvasActionName;
            for (canvas.actions[0..action_index]) |previous| {
                if (std.mem.eql(u8, previous.name, action.name))
                    return error.DuplicateCanvasAction;
            }
            if (action.input_schema_json) |json| try validateJsonSchema(json);
        }
    }
}

fn uniqueNonEmpty(values: []const []const u8, duplicate_error: anyerror) !void {
    for (values, 0..) |value, index| {
        if (value.len == 0) return error.InvalidExtensionConfiguration;
        for (values[0..index]) |previous| {
            if (std.mem.eql(u8, previous, value)) return duplicate_error;
        }
    }
}

fn validateJsonSchema(json: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, json, .{}) catch
        return error.InvalidJsonSchema;
    defer parsed.deinit();
    switch (parsed.value) {
        .object, .bool => {},
        else => return error.InvalidJsonSchema,
    }
}

pub fn freeOpenCanvas(allocator: std.mem.Allocator, value: OpenCanvas) void {
    allocator.free(value.instance_id);
    allocator.free(value.extension_id);
    if (value.extension_name) |item| allocator.free(item);
    allocator.free(value.canvas_id);
    if (value.icon) |item| allocator.free(item);
    if (value.title) |item| allocator.free(item);
    if (value.status) |item| allocator.free(item);
    if (value.url) |item| allocator.free(item);
    if (value.input_json) |item| allocator.free(item);
}

test "capabilities fail closed" {
    const capabilities = CapabilitySet{};
    try std.testing.expect(!capabilities.supports(.canvases));
    try std.testing.expect(!capabilities.supports(.mcp_apps));
}

test "configuration rejects duplicate identities and invalid schemas" {
    try validateJsonSchema("true");
    try validateJsonSchema("false");
    try std.testing.expectError(error.DuplicatePluginDirectory, validate(.{
        .plugin_directories = &.{ "a", "a" },
    }));
    try std.testing.expectError(error.InvalidJsonSchema, validate(.{
        .canvases = &.{.{
            .declaration = .{
                .id = "review",
                .display_name = "Review",
                .description = "Review",
                .input_schema_json = "[]",
            },
            .on_open = struct {
                fn open(_: std.mem.Allocator, _: CanvasOpenRequest, _: ?*anyopaque) !CanvasOpenResult {
                    return .{};
                }
            }.open,
        }},
    }));
    try std.testing.expectError(error.InvalidMcpServer, validate(.{
        .mcp = .{ .servers = &.{.{
            .name = "stdio",
            .config = .{ .stdio = .{
                .command = "server",
                .timeout_ms = 0,
            } },
        }} },
    }));
    try std.testing.expectError(error.InvalidMcpServer, validate(.{
        .mcp = .{ .servers = &.{.{
            .name = "http",
            .config = .{ .http = .{
                .url = "https://example.test",
                .timeout_ms = 0,
            } },
        }} },
    }));
    try std.testing.expectError(error.DuplicateMcpHeaderName, validate(.{
        .mcp = .{ .servers = &.{.{
            .name = "http",
            .config = .{ .http = .{
                .url = "https://example.test",
                .headers = &.{
                    .{ .name = "Authorization", .value = "one" },
                    .{ .name = "authorization", .value = "two" },
                },
            } },
        }} },
    }));
}
