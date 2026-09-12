const std = @import("std");

pub const ListOptions = struct {
    selection_id: ?[]const u8 = null,
    github_token: ?[]const u8 = null,
};

pub const ModelList = struct {
    models: []const Model,
};

pub const Model = struct {
    id: []const u8,
    name: []const u8,
    capabilities: Capabilities,
    metadata: ?std.json.Value = null,
    policy: ?Policy = null,
    billing: ?Billing = null,
    supportedReasoningEfforts: ?[]const []const u8 = null,
    defaultReasoningEffort: ?[]const u8 = null,
    supportedContextTiers: ?[]const []const u8 = null,
    modelPickerCategory: ?PickerCategory = null,
    modelPickerPriceCategory: ?PickerPriceCategory = null,
    warningText: ?WarningText = null,
    infoMessages: ?[]const Message = null,
    warningMessages: ?[]const Message = null,
};

pub const Capabilities = struct {
    supports: ?Supports = null,
    limits: ?Limits = null,
};

pub const Supports = struct {
    vision: ?bool = null,
    reasoningEffort: ?bool = null,
    adaptive_thinking: ?AdaptiveThinking = null,
};

pub const AdaptiveThinking = enum {
    unsupported,
    optional,
    required,
};

pub const Limits = struct {
    max_prompt_tokens: ?u64 = null,
    max_output_tokens: ?u64 = null,
    max_context_window_tokens: ?u64 = null,
    vision: ?VisionLimits = null,
};

pub const VisionLimits = struct {
    supported_media_types: []const []const u8,
    max_prompt_images: u64,
    max_prompt_image_size: u64,
};

/// Per-property overrides deep-merged over runtime defaults.
/// Null fields are omitted from session requests, not set to false or zero.
pub const CapabilitiesOverride = struct {
    supports: ?Supports = null,
    limits: ?LimitsOverride = null,
};

pub const LimitsOverride = struct {
    max_prompt_tokens: ?u64 = null,
    max_output_tokens: ?u64 = null,
    max_context_window_tokens: ?u64 = null,
    vision: ?VisionLimitsOverride = null,
};

pub const VisionLimitsOverride = struct {
    supported_media_types: ?[]const []const u8 = null,
    max_prompt_images: ?u64 = null,
    max_prompt_image_size: ?u64 = null,
};

pub const Policy = struct {
    state: PolicyState,
    terms: ?[]const u8 = null,
};

pub const PolicyState = enum {
    enabled,
    disabled,
    unconfigured,
};

pub const Billing = struct {
    multiplier: ?f64 = null,
    tokenPrices: ?TokenPrices = null,
    discountPercent: ?u8 = null,
    promo: ?Promotion = null,
};

pub const TokenPrices = struct {
    inputPrice: ?f64 = null,
    outputPrice: ?f64 = null,
    cachePrice: ?f64 = null,
    cacheReadPrice: ?f64 = null,
    cacheWritePrice: ?f64 = null,
    cacheWrite1hPrice: ?f64 = null,
    batchSize: ?u64 = null,
    contextMax: ?u64 = null,
    maxPromptTokens: ?u64 = null,
    longContext: ?LongContextTokenPrices = null,
};

pub const LongContextTokenPrices = struct {
    inputPrice: ?f64 = null,
    outputPrice: ?f64 = null,
    cachePrice: ?f64 = null,
    cacheReadPrice: ?f64 = null,
    cacheWritePrice: ?f64 = null,
    cacheWrite1hPrice: ?f64 = null,
    contextMax: ?u64 = null,
    maxPromptTokens: ?u64 = null,
};

pub const Promotion = struct {
    id: ?[]const u8 = null,
    discountPercent: ?f64 = null,
    endsAt: ?[]const u8 = null,
    message: ?[]const u8 = null,
    showBanner: ?bool = null,
};

pub const PickerCategory = enum {
    lightweight,
    versatile,
    powerful,
};

pub const PickerPriceCategory = enum {
    low,
    medium,
    high,
    very_high,
};

pub const WarningText = struct {
    dataRetention: ?[]const u8 = null,
};

pub const Message = struct {
    code: []const u8,
    message: []const u8,
};

test "model list preserves published metadata" {
    const parsed = try std.json.parseFromSlice(
        ModelList,
        std.testing.allocator,
        \\{"models":[{
        \\  "id":"claude-opus-5",
        \\  "name":"Claude Opus 5",
        \\  "capabilities":{
        \\    "supports":{"vision":true,"reasoningEffort":true,"adaptive_thinking":"required"},
        \\    "limits":{"max_prompt_tokens":200000,"max_output_tokens":32000,"max_context_window_tokens":232000,
        \\      "vision":{"supported_media_types":["image/png","image/jpeg"],"max_prompt_images":8,"max_prompt_image_size":10485760}}
        \\  },
        \\  "metadata":{"provider":"anthropic","region":"us-east"},
        \\  "policy":{"state":"enabled","terms":"Enterprise terms"},
        \\  "billing":{"multiplier":2.0,"discountPercent":10,"tokenPrices":{
        \\    "inputPrice":1.25,"outputPrice":5.0,"cachePrice":0.5,"cacheReadPrice":0.25,
        \\    "cacheWritePrice":0.75,"cacheWrite1hPrice":1.0,"batchSize":1000000,
        \\    "contextMax":200000,"maxPromptTokens":200000,
        \\    "longContext":{"inputPrice":2.5,"outputPrice":10.0,"cachePrice":1.0,
        \\      "cacheReadPrice":0.5,"cacheWritePrice":1.5,"cacheWrite1hPrice":2.0,
        \\      "contextMax":1000000,"maxPromptTokens":1000000}},
        \\    "promo":{"id":"fall","discountPercent":12.5,"endsAt":"2026-10-01T00:00:00Z",
        \\      "message":"Limited promotion","showBanner":true}},
        \\  "supportedReasoningEfforts":["low","medium","high"],
        \\  "defaultReasoningEffort":"medium",
        \\  "supportedContextTiers":["default","long_context"],
        \\  "modelPickerCategory":"powerful",
        \\  "modelPickerPriceCategory":"very_high",
        \\  "warningText":{"dataRetention":"Review retention terms."},
        \\  "infoMessages":[{"code":"new_model","message":"Recently added."}],
        \\  "warningMessages":[{"code":"client_version_deprecated","message":"Update the client."}]
        \\}]}
    ,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const model = parsed.value.models[0];
    try std.testing.expectEqualStrings("claude-opus-5", model.id);
    try std.testing.expectEqual(AdaptiveThinking.required, model.capabilities.supports.?.adaptive_thinking.?);
    try std.testing.expectEqual(@as(u64, 232000), model.capabilities.limits.?.max_context_window_tokens.?);
    try std.testing.expectEqualStrings("anthropic", model.metadata.?.object.get("provider").?.string);
    try std.testing.expectEqual(PolicyState.enabled, model.policy.?.state);
    try std.testing.expectEqual(@as(f64, 2.0), model.billing.?.multiplier.?);
    try std.testing.expectEqual(@as(f64, 2.5), model.billing.?.tokenPrices.?.longContext.?.inputPrice.?);
    try std.testing.expectEqual(PickerCategory.powerful, model.modelPickerCategory.?);
    try std.testing.expectEqual(PickerPriceCategory.very_high, model.modelPickerPriceCategory.?);
    try std.testing.expectEqualStrings("Review retention terms.", model.warningText.?.dataRetention.?);
    try std.testing.expectEqualStrings("new_model", model.infoMessages.?[0].code);
    try std.testing.expectEqualStrings("Update the client.", model.warningMessages.?[0].message);
}

test "model capabilities preserve absent optional sections" {
    const parsed = try std.json.parseFromSlice(
        ModelList,
        std.testing.allocator,
        \\{"models":[{"id":"embedding","name":"Embedding","capabilities":{}}]}
    ,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try std.testing.expect(parsed.value.models[0].capabilities.supports == null);
    try std.testing.expect(parsed.value.models[0].capabilities.limits == null);
}
