const std = @import("std");
const models = @import("models.zig");

pub const ProviderTokenRequest = struct {
    session_id: []const u8,
    provider_name: []const u8,
};

pub const BearerTokenCallback = *const fn (
    allocator: std.mem.Allocator,
    request: ProviderTokenRequest,
    context: ?*anyopaque,
) anyerror![]u8;

pub const BearerTokenProvider = struct {
    callback: BearerTokenCallback,
    context: ?*anyopaque = null,
};

const ProviderAuthentication = union(enum) {
    none,
    api_key: []const u8,
    bearer_token: []const u8,
    api_key_and_bearer_token: struct {
        api_key: []const u8,
        bearer_token: []const u8,
    },
};

const ProviderHeader = struct {
    name: []const u8,
    value: []const u8,
};

pub const Authentication = ProviderAuthentication;
pub const Header = ProviderHeader;

pub const ProviderConfig = struct {
    base_url: []const u8,
    protocol: Protocol = .{ .openai = .completions },
    authentication: ProviderAuthentication = .none,
    bearer_token_provider: ?BearerTokenProvider = null,
    headers: []const ProviderHeader = &.{},
    model_id: ?[]const u8 = null,
    model_capabilities: ?models.CapabilitiesOverride = null,
    provider_name: ?[]const u8 = null,
    wire_model: ?[]const u8 = null,
    max_prompt_tokens: ?u64 = null,
    max_context_window_tokens: ?u64 = null,
    max_output_tokens: ?u64 = null,

    pub const Authentication = ProviderAuthentication;
    pub const Header = ProviderHeader;

    pub const Protocol = union(enum) {
        openai: OpenAI,
        azure: Azure,
        anthropic,
    };

    pub const OpenAI = union(enum) {
        completions,
        responses: Transport,
    };

    pub const Azure = struct {
        api: OpenAI = .completions,
        api_version: ?[]const u8 = null,
    };

    pub const Transport = enum {
        http,
        websockets,
    };
};

pub const NamedProviderConfig = struct {
    name: []const u8,
    base_url: []const u8,
    protocol: Protocol = .{ .openai = .completions },
    authentication: ProviderAuthentication = .none,
    bearer_token_provider: ?BearerTokenProvider = null,
    headers: []const ProviderHeader = &.{},

    pub const Protocol = union(enum) {
        openai: Api,
        azure: Azure,
        anthropic,
    };

    pub const Api = enum {
        completions,
        responses,
    };

    pub const Azure = struct {
        api: Api = .completions,
        api_version: ?[]const u8 = null,
    };
};

pub const ProviderModelConfig = struct {
    id: []const u8,
    provider: []const u8,
    wire_model: ?[]const u8 = null,
    model_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    max_prompt_tokens: ?u64 = null,
    max_context_window_tokens: ?u64 = null,
    max_output_tokens: ?u64 = null,
    capabilities: ?models.CapabilitiesOverride = null,
};

const WireProviderType = enum {
    openai,
    azure,
    anthropic,
};

const WireApi = enum {
    completions,
    responses,
};

const WireTransport = enum {
    http,
    websockets,
};

const WireAzure = struct {
    apiVersion: ?[]const u8 = null,
};

const WireHeaders = struct {
    values: []const Header,

    pub fn jsonStringify(self: WireHeaders, writer: anytype) !void {
        try writer.beginObject();
        for (self.values) |header| {
            try writer.objectField(header.name);
            try writer.write(header.value);
        }
        try writer.endObject();
    }
};

const LoweredAuthentication = struct {
    api_key: ?[]const u8 = null,
    bearer_token: ?[]const u8 = null,
};

pub const WireProvider = struct {
    type: WireProviderType,
    wireApi: ?WireApi = null,
    transport: ?WireTransport = null,
    baseUrl: []const u8,
    apiKey: ?[]const u8 = null,
    bearerToken: ?[]const u8 = null,
    azure: ?WireAzure = null,
    headers: ?WireHeaders = null,
    modelId: ?[]const u8 = null,
    modelCapabilities: ?models.CapabilitiesOverride = null,
    providerName: ?[]const u8 = null,
    wireModel: ?[]const u8 = null,
    maxPromptTokens: ?u64 = null,
    maxContextWindowTokens: ?u64 = null,
    maxOutputTokens: ?u64 = null,
    hasBearerTokenProvider: ?bool = null,
};

pub const WireNamedProvider = struct {
    name: []const u8,
    type: WireProviderType,
    wireApi: ?WireApi = null,
    baseUrl: []const u8,
    apiKey: ?[]const u8 = null,
    bearerToken: ?[]const u8 = null,
    azure: ?WireAzure = null,
    headers: ?WireHeaders = null,
    hasBearerTokenProvider: ?bool = null,
};

pub const WireProviderModel = struct {
    id: []const u8,
    provider: []const u8,
    wireModel: ?[]const u8 = null,
    modelId: ?[]const u8 = null,
    name: ?[]const u8 = null,
    maxPromptTokens: ?u64 = null,
    maxContextWindowTokens: ?u64 = null,
    maxOutputTokens: ?u64 = null,
    capabilities: ?models.CapabilitiesOverride = null,
};

pub const TokenBinding = struct {
    provider_name: []const u8,
    token_provider: BearerTokenProvider,
};

pub const PreparedProviders = struct {
    provider: ?WireProvider = null,
    providers: ?[]WireNamedProvider = null,
    models: ?[]WireProviderModel = null,
    token_bindings: []TokenBinding = &.{},

    pub fn deinit(self: *PreparedProviders, allocator: std.mem.Allocator) void {
        if (self.providers) |values| allocator.free(values);
        if (self.models) |values| allocator.free(values);
        if (self.token_bindings.len != 0) allocator.free(self.token_bindings);
        self.* = .{};
    }
};

pub fn prepareSessionProviders(
    allocator: std.mem.Allocator,
    singular: ?ProviderConfig,
    named: []const NamedProviderConfig,
    configured_models: []const ProviderModelConfig,
) !PreparedProviders {
    if (singular != null and (named.len != 0 or configured_models.len != 0)) {
        return error.MixedProviderModes;
    }

    var prepared: PreparedProviders = .{};
    errdefer prepared.deinit(allocator);

    if (singular) |config| {
        prepared.provider = try lowerProvider(config);
        if (config.bearer_token_provider) |token_provider| {
            prepared.token_bindings = try allocator.alloc(TokenBinding, 1);
            prepared.token_bindings[0] = .{
                .provider_name = "default",
                .token_provider = token_provider,
            };
        }
        return prepared;
    }

    try validateNamedGraph(named, configured_models);

    if (named.len != 0) {
        const wire = try allocator.alloc(WireNamedProvider, named.len);
        prepared.providers = wire;
        var callback_count: usize = 0;
        for (named, 0..) |config, index| {
            wire[index] = try lowerNamedProvider(config);
            if (config.bearer_token_provider != null) callback_count += 1;
        }
        if (callback_count != 0) {
            prepared.token_bindings = try allocator.alloc(TokenBinding, callback_count);
            var binding_index: usize = 0;
            for (named) |config| {
                if (config.bearer_token_provider) |token_provider| {
                    prepared.token_bindings[binding_index] = .{
                        .provider_name = config.name,
                        .token_provider = token_provider,
                    };
                    binding_index += 1;
                }
            }
        }
    }

    if (configured_models.len != 0) {
        const wire = try allocator.alloc(WireProviderModel, configured_models.len);
        prepared.models = wire;
        for (configured_models, 0..) |config, index| {
            try validateCapabilities(config.capabilities);
            wire[index] = .{
                .id = config.id,
                .provider = config.provider,
                .wireModel = config.wire_model,
                .modelId = config.model_id,
                .name = config.name,
                .maxPromptTokens = config.max_prompt_tokens,
                .maxContextWindowTokens = config.max_context_window_tokens,
                .maxOutputTokens = config.max_output_tokens,
                .capabilities = config.capabilities,
            };
        }
    }

    return prepared;
}

fn lowerProvider(config: ProviderConfig) !WireProvider {
    try validateHeaders(config.headers);
    try validateCapabilities(config.model_capabilities);
    const authentication = lowerAuthentication(config.authentication);

    var wire = WireProvider{
        .type = undefined,
        .baseUrl = config.base_url,
        .apiKey = authentication.api_key,
        .bearerToken = authentication.bearer_token,
        .headers = if (config.headers.len == 0) null else .{ .values = config.headers },
        .modelId = config.model_id,
        .modelCapabilities = config.model_capabilities,
        .providerName = config.provider_name,
        .wireModel = config.wire_model,
        .maxPromptTokens = config.max_prompt_tokens,
        .maxContextWindowTokens = config.max_context_window_tokens,
        .maxOutputTokens = config.max_output_tokens,
        .hasBearerTokenProvider = if (config.bearer_token_provider != null) true else null,
    };

    switch (config.protocol) {
        .openai => |api| {
            wire.type = .openai;
            lowerOpenAI(api, &wire);
        },
        .azure => |azure| {
            wire.type = .azure;
            lowerOpenAI(azure.api, &wire);
            if (azure.api_version) |api_version| {
                wire.azure = .{ .apiVersion = api_version };
            }
        },
        .anthropic => wire.type = .anthropic,
    }

    return wire;
}

pub fn lower(config: ProviderConfig) !WireProvider {
    return lowerProvider(config);
}

fn lowerNamedProvider(config: NamedProviderConfig) !WireNamedProvider {
    try validateHeaders(config.headers);
    const authentication = lowerAuthentication(config.authentication);

    var wire = WireNamedProvider{
        .name = config.name,
        .type = undefined,
        .baseUrl = config.base_url,
        .apiKey = authentication.api_key,
        .bearerToken = authentication.bearer_token,
        .headers = if (config.headers.len == 0) null else .{ .values = config.headers },
        .hasBearerTokenProvider = if (config.bearer_token_provider != null) true else null,
    };

    switch (config.protocol) {
        .openai => |api| {
            wire.type = .openai;
            wire.wireApi = @enumFromInt(@intFromEnum(api));
        },
        .azure => |azure| {
            wire.type = .azure;
            wire.wireApi = @enumFromInt(@intFromEnum(azure.api));
            if (azure.api_version) |api_version| {
                wire.azure = .{ .apiVersion = api_version };
            }
        },
        .anthropic => wire.type = .anthropic,
    }

    return wire;
}

fn lowerAuthentication(authentication: ProviderAuthentication) LoweredAuthentication {
    return switch (authentication) {
        .none => .{},
        .api_key => |api_key| .{ .api_key = api_key },
        .bearer_token => |bearer_token| .{ .bearer_token = bearer_token },
        .api_key_and_bearer_token => |credentials| .{
            .api_key = credentials.api_key,
            .bearer_token = credentials.bearer_token,
        },
    };
}

fn lowerOpenAI(api: ProviderConfig.OpenAI, wire: *WireProvider) void {
    switch (api) {
        .completions => wire.wireApi = .completions,
        .responses => |transport| {
            wire.wireApi = .responses;
            wire.transport = @enumFromInt(@intFromEnum(transport));
        },
    }
}

fn validateNamedGraph(
    providers: []const NamedProviderConfig,
    configured_models: []const ProviderModelConfig,
) !void {
    for (providers, 0..) |config, index| {
        if (std.mem.indexOfScalar(u8, config.name, '/') != null) {
            return error.InvalidProviderName;
        }
        for (providers[0..index]) |previous| {
            if (std.mem.eql(u8, config.name, previous.name)) return error.DuplicateProviderName;
        }
    }
    for (configured_models, 0..) |config, index| {
        var provider_exists = false;
        for (providers) |candidate| {
            if (std.mem.eql(u8, config.provider, candidate.name)) {
                provider_exists = true;
                break;
            }
        }
        if (!provider_exists) return error.UnknownModelProvider;
        for (configured_models[0..index]) |previous| {
            if (std.mem.eql(u8, config.provider, previous.provider) and
                std.mem.eql(u8, config.id, previous.id))
            {
                return error.DuplicateQualifiedModelId;
            }
        }
    }
}

fn validateHeaders(headers: []const Header) !void {
    for (headers, 0..) |header, index| {
        if (header.name.len == 0) return error.EmptyHeaderName;
        for (headers[0..index]) |previous| {
            if (std.ascii.eqlIgnoreCase(header.name, previous.name)) {
                return error.DuplicateHeaderName;
            }
        }
    }
}

pub fn validateCapabilities(capabilities: ?models.CapabilitiesOverride) !void {
    const value = capabilities orelse return;
    const limits = value.limits orelse return;
    const vision = limits.vision orelse return;
    if (vision.max_prompt_images == 0) return error.InvalidMaxPromptImages;
}

fn encodePrepared(config: ProviderConfig) ![]u8 {
    var prepared = try prepareSessionProviders(std.testing.allocator, config, &.{}, &.{});
    defer prepared.deinit(std.testing.allocator);
    return std.json.Stringify.valueAlloc(
        std.testing.allocator,
        prepared.provider.?,
        .{ .emit_null_optional_fields = false },
    );
}

test "singular provider preserves static credentials and derives callback flag" {
    const callback = struct {
        fn get(
            allocator: std.mem.Allocator,
            _: ProviderTokenRequest,
            _: ?*anyopaque,
        ) ![]u8 {
            return allocator.dupe(u8, "dynamic");
        }
    }.get;
    const encoded = try encodePrepared(.{
        .base_url = "https://api.example.test",
        .authentication = .{ .api_key_and_bearer_token = .{
            .api_key = "key",
            .bearer_token = "static",
        } },
        .bearer_token_provider = .{ .callback = callback },
        .model_id = "gpt-4.1",
        .model_capabilities = .{ .supports = .{ .vision = true } },
        .provider_name = "telemetry-name",
        .wire_model = "deployment",
        .max_prompt_tokens = 100,
        .max_context_window_tokens = 200,
        .max_output_tokens = 50,
    });
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualStrings(
        "{\"type\":\"openai\",\"wireApi\":\"completions\",\"baseUrl\":\"https://api.example.test\",\"apiKey\":\"key\",\"bearerToken\":\"static\",\"modelId\":\"gpt-4.1\",\"modelCapabilities\":{\"supports\":{\"vision\":true}},\"providerName\":\"telemetry-name\",\"wireModel\":\"deployment\",\"maxPromptTokens\":100,\"maxContextWindowTokens\":200,\"maxOutputTokens\":50,\"hasBearerTokenProvider\":true}",
        encoded,
    );
}

test "legacy authentication variants remain source compatible" {
    const cases = [_]struct {
        authentication: Authentication,
        expected: []const u8,
    }{
        .{
            .authentication = .none,
            .expected = "{\"type\":\"openai\",\"wireApi\":\"completions\",\"baseUrl\":\"http://localhost\"}",
        },
        .{
            .authentication = .{ .api_key = "key" },
            .expected = "{\"type\":\"openai\",\"wireApi\":\"completions\",\"baseUrl\":\"http://localhost\",\"apiKey\":\"key\"}",
        },
        .{
            .authentication = .{ .bearer_token = "token" },
            .expected = "{\"type\":\"openai\",\"wireApi\":\"completions\",\"baseUrl\":\"http://localhost\",\"bearerToken\":\"token\"}",
        },
    };

    for (cases) |case| {
        const encoded = try encodePrepared(.{
            .base_url = "http://localhost",
            .authentication = case.authentication,
        });
        defer std.testing.allocator.free(encoded);
        try std.testing.expectEqualStrings(case.expected, encoded);
    }
}

test "named providers and models lower to exact wire JSON" {
    var prepared = try prepareSessionProviders(
        std.testing.allocator,
        null,
        &.{
            .{
                .name = "azure",
                .base_url = "https://example.openai.azure.com",
                .protocol = .{ .azure = .{
                    .api = .responses,
                    .api_version = "2025-04-01-preview",
                } },
                .authentication = .{ .api_key_and_bearer_token = .{
                    .api_key = "key",
                    .bearer_token = "token",
                } },
                .headers = &.{.{ .name = "X-Tenant", .value = "acme" }},
            },
        },
        &.{
            .{
                .id = "reasoner",
                .provider = "azure",
                .wire_model = "deployment",
                .model_id = "gpt-4.1",
                .name = "Reasoner",
                .max_prompt_tokens = 100,
                .max_context_window_tokens = 200,
                .max_output_tokens = 50,
                .capabilities = .{ .supports = .{ .reasoningEffort = true } },
            },
        },
    );
    defer prepared.deinit(std.testing.allocator);

    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, .{
        .providers = prepared.providers,
        .models = prepared.models,
    }, .{ .emit_null_optional_fields = false });
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings(
        "{\"providers\":[{\"name\":\"azure\",\"type\":\"azure\",\"wireApi\":\"responses\",\"baseUrl\":\"https://example.openai.azure.com\",\"apiKey\":\"key\",\"bearerToken\":\"token\",\"azure\":{\"apiVersion\":\"2025-04-01-preview\"},\"headers\":{\"X-Tenant\":\"acme\"}}],\"models\":[{\"id\":\"reasoner\",\"provider\":\"azure\",\"wireModel\":\"deployment\",\"modelId\":\"gpt-4.1\",\"name\":\"Reasoner\",\"maxPromptTokens\":100,\"maxContextWindowTokens\":200,\"maxOutputTokens\":50,\"capabilities\":{\"supports\":{\"reasoningEffort\":true}}}]}",
        encoded,
    );
}

test "provider graph validation rejects only documented invalid shapes" {
    try std.testing.expectError(error.MixedProviderModes, prepareSessionProviders(
        std.testing.allocator,
        .{ .base_url = "http://localhost" },
        &.{.{ .name = "named", .base_url = "http://localhost" }},
        &.{},
    ));
    try std.testing.expectError(error.InvalidProviderName, prepareSessionProviders(
        std.testing.allocator,
        null,
        &.{.{ .name = "bad/name", .base_url = "http://localhost" }},
        &.{},
    ));
    try std.testing.expectError(error.DuplicateProviderName, prepareSessionProviders(
        std.testing.allocator,
        null,
        &.{
            .{ .name = "same", .base_url = "http://one" },
            .{ .name = "same", .base_url = "http://two" },
        },
        &.{},
    ));
    try std.testing.expectError(error.UnknownModelProvider, prepareSessionProviders(
        std.testing.allocator,
        null,
        &.{.{ .name = "known", .base_url = "http://localhost" }},
        &.{.{ .id = "model", .provider = "missing" }},
    ));
    try std.testing.expectError(error.DuplicateQualifiedModelId, prepareSessionProviders(
        std.testing.allocator,
        null,
        &.{.{ .name = "known", .base_url = "http://localhost" }},
        &.{
            .{ .id = "model", .provider = "known" },
            .{ .id = "model", .provider = "known" },
        },
    ));
    try std.testing.expectError(error.EmptyHeaderName, prepareSessionProviders(
        std.testing.allocator,
        .{
            .base_url = "http://localhost",
            .headers = &.{.{ .name = "", .value = "value" }},
        },
        &.{},
        &.{},
    ));
    try std.testing.expectError(error.DuplicateHeaderName, prepareSessionProviders(
        std.testing.allocator,
        null,
        &.{.{
            .name = "known",
            .base_url = "http://localhost",
            .headers = &.{
                .{ .name = "Authorization", .value = "first" },
                .{ .name = "authorization", .value = "second" },
            },
        }},
        &.{},
    ));
    try std.testing.expectError(error.InvalidMaxPromptImages, prepareSessionProviders(
        std.testing.allocator,
        null,
        &.{.{ .name = "known", .base_url = "http://localhost" }},
        &.{.{
            .id = "model",
            .provider = "known",
            .capabilities = .{ .limits = .{ .vision = .{ .max_prompt_images = 0 } } },
        }},
    ));
}
