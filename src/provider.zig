const std = @import("std");

pub const ProviderConfig = struct {
    base_url: []const u8,
    protocol: Protocol = .{ .openai = .completions },
    authentication: Authentication = .none,
    headers: []const Header = &.{},
    model_id: ?[]const u8 = null,
    wire_model: ?[]const u8 = null,
    max_prompt_tokens: ?u64 = null,
    max_output_tokens: ?u64 = null,

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

    pub const Authentication = union(enum) {
        none,
        api_key: []const u8,
        bearer_token: []const u8,
    };

    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };
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
    values: []const ProviderConfig.Header,

    pub fn jsonStringify(self: WireHeaders, writer: anytype) !void {
        try writer.beginObject();
        for (self.values) |header| {
            try writer.objectField(header.name);
            try writer.write(header.value);
        }
        try writer.endObject();
    }
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
    wireModel: ?[]const u8 = null,
    maxPromptTokens: ?u64 = null,
    maxOutputTokens: ?u64 = null,
};

pub fn lower(config: ProviderConfig) !WireProvider {
    try validateHeaders(config.headers);

    var wire = WireProvider{
        .type = undefined,
        .baseUrl = config.base_url,
        .headers = if (config.headers.len == 0) null else .{ .values = config.headers },
        .modelId = config.model_id,
        .wireModel = config.wire_model,
        .maxPromptTokens = config.max_prompt_tokens,
        .maxOutputTokens = config.max_output_tokens,
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
        .anthropic => {
            wire.type = .anthropic;
        },
    }

    switch (config.authentication) {
        .none => {},
        .api_key => |api_key| wire.apiKey = api_key,
        .bearer_token => |bearer_token| wire.bearerToken = bearer_token,
    }

    return wire;
}

fn lowerOpenAI(api: ProviderConfig.OpenAI, wire: *WireProvider) void {
    switch (api) {
        .completions => wire.wireApi = .completions,
        .responses => |transport| {
            wire.wireApi = .responses;
            wire.transport = switch (transport) {
                .http => .http,
                .websockets => .websockets,
            };
        },
    }
}

fn validateHeaders(headers: []const ProviderConfig.Header) !void {
    for (headers, 0..) |header, index| {
        if (header.name.len == 0) return error.EmptyHeaderName;
        for (headers[0..index]) |previous| {
            if (std.ascii.eqlIgnoreCase(header.name, previous.name)) {
                return error.DuplicateHeaderName;
            }
        }
    }
}

fn encodeProvider(config: ProviderConfig) ![]u8 {
    const wire = try lower(config);
    return std.json.Stringify.valueAlloc(
        std.testing.allocator,
        wire,
        .{ .emit_null_optional_fields = false },
    );
}

fn expectJson(expected: []const u8, actual: []const u8) !void {
    try std.testing.expectEqualStrings(expected, actual);
}

test "OpenAI Completions omits transport and absent fields" {
    const encoded = try encodeProvider(.{
        .base_url = "http://localhost:11434/v1",
    });
    defer std.testing.allocator.free(encoded);

    try expectJson(
        \\{"type":"openai","wireApi":"completions","baseUrl":"http://localhost:11434/v1"}
    , encoded);
}

test "OpenAI Responses supports HTTP and WebSocket transports" {
    const http = try encodeProvider(.{
        .base_url = "https://api.openai.com/v1",
        .protocol = .{ .openai = .{ .responses = .http } },
    });
    defer std.testing.allocator.free(http);
    try expectJson(
        \\{"type":"openai","wireApi":"responses","transport":"http","baseUrl":"https://api.openai.com/v1"}
    , http);

    const websockets = try encodeProvider(.{
        .base_url = "https://api.openai.com/v1",
        .protocol = .{ .openai = .{ .responses = .websockets } },
    });
    defer std.testing.allocator.free(websockets);
    try expectJson(
        \\{"type":"openai","wireApi":"responses","transport":"websockets","baseUrl":"https://api.openai.com/v1"}
    , websockets);
}

test "Azure lowers API version and API selection" {
    const encoded = try encodeProvider(.{
        .base_url = "https://example.openai.azure.com",
        .protocol = .{ .azure = .{
            .api = .{ .responses = .http },
            .api_version = "2025-04-01-preview",
        } },
    });
    defer std.testing.allocator.free(encoded);

    try expectJson(
        \\{"type":"azure","wireApi":"responses","transport":"http","baseUrl":"https://example.openai.azure.com","azure":{"apiVersion":"2025-04-01-preview"}}
    , encoded);
}

test "Anthropic omits OpenAI and Azure options" {
    const encoded = try encodeProvider(.{
        .base_url = "https://api.anthropic.com",
        .protocol = .anthropic,
    });
    defer std.testing.allocator.free(encoded);

    try expectJson(
        \\{"type":"anthropic","baseUrl":"https://api.anthropic.com"}
    , encoded);
}

test "authentication variants are exclusive" {
    const api_key = try encodeProvider(.{
        .base_url = "https://api.openai.com/v1",
        .authentication = .{ .api_key = "key" },
    });
    defer std.testing.allocator.free(api_key);
    try expectJson(
        \\{"type":"openai","wireApi":"completions","baseUrl":"https://api.openai.com/v1","apiKey":"key"}
    , api_key);

    const bearer = try encodeProvider(.{
        .base_url = "https://example.test",
        .authentication = .{ .bearer_token = "token" },
    });
    defer std.testing.allocator.free(bearer);
    try expectJson(
        \\{"type":"openai","wireApi":"completions","baseUrl":"https://example.test","bearerToken":"token"}
    , bearer);
}

test "headers and model fields lower to the provider wire contract" {
    const encoded = try encodeProvider(.{
        .base_url = "not-required-to-be-a-url",
        .headers = &.{
            .{ .name = "X-Tenant", .value = "acme" },
            .{ .name = "X-Region", .value = "west" },
        },
        .model_id = "gpt-4.1",
        .wire_model = "deployment-name",
        .max_prompt_tokens = 100_000,
        .max_output_tokens = 16_384,
    });
    defer std.testing.allocator.free(encoded);

    try expectJson(
        \\{"type":"openai","wireApi":"completions","baseUrl":"not-required-to-be-a-url","headers":{"X-Tenant":"acme","X-Region":"west"},"modelId":"gpt-4.1","wireModel":"deployment-name","maxPromptTokens":100000,"maxOutputTokens":16384}
    , encoded);
}

test "header validation rejects empty and case-insensitive duplicate names" {
    try std.testing.expectError(error.EmptyHeaderName, lower(.{
        .base_url = "http://localhost",
        .headers = &.{.{ .name = "", .value = "value" }},
    }));
    try std.testing.expectError(error.DuplicateHeaderName, lower(.{
        .base_url = "http://localhost",
        .headers = &.{
            .{ .name = "Authorization", .value = "first" },
            .{ .name = "authorization", .value = "second" },
        },
    }));
}
