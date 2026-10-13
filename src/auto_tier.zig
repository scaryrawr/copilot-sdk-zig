const std = @import("std");

pub fn validIdentifier(value: []const u8) bool {
    if (value.len == 0) return false;
    const view = std.unicode.Utf8View.init(value) catch return false;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        switch (codepoint) {
            0...0x20, 0x7f...0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff => return false,
            else => {},
        }
    }
    return true;
}

pub const AutoTier = union(enum) {
    efficiency,
    balance,
    intelligence,
    fast,
    custom: []const u8,

    pub fn init(value: []const u8) !AutoTier {
        if (!validIdentifier(value)) return error.InvalidAutoTier;
        inline for (.{ "efficiency", "balance", "intelligence", "fast" }) |name| {
            if (std.mem.eql(u8, value, name)) return @unionInit(AutoTier, name, {});
        }
        return .{ .custom = value };
    }

    pub fn wireName(self: AutoTier) []const u8 {
        return switch (self) {
            .custom => |value| value,
            else => @tagName(self),
        };
    }

    pub fn jsonStringify(self: AutoTier, writer: anytype) !void {
        if (!validIdentifier(self.wireName())) return error.WriteFailed;
        try writer.write(self.wireName());
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !AutoTier {
        const value = try std.json.innerParse([]const u8, allocator, source, options);
        return init(value) catch return error.InvalidEnumTag;
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !AutoTier {
        const value = try std.json.innerParseFromValue([]const u8, allocator, source, options);
        return init(value) catch return error.InvalidEnumTag;
    }
};

test "auto tiers preserve known presets and provider identifiers" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "balance", "provider-tier", "低延迟" }) |value| {
        const encoded = try std.json.Stringify.valueAlloc(allocator, try AutoTier.init(value), .{});
        defer allocator.free(encoded);
        const parsed = try std.json.parseFromSlice(AutoTier, allocator, encoded, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        try std.testing.expectEqualStrings(value, parsed.value.wireName());
        const dynamic = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
        defer dynamic.deinit();
        const from_value = try std.json.parseFromValue(AutoTier, allocator, dynamic.value, .{ .allocate = .alloc_always });
        defer from_value.deinit();
        try std.testing.expectEqualStrings(value, from_value.value.wireName());
    }
    for ([_][]const u8{ "", "white space", "tier\t", "\x00", "\x7f", "\xc2\x85", "\xc2\xa0", "\xe2\x80\xa8", "\xef\xbb\xbf", "\xff" }) |value| {
        try std.testing.expectError(error.InvalidAutoTier, AutoTier.init(value));
        var writer: std.Io.Writer.Allocating = .init(allocator);
        defer writer.deinit();
        try std.testing.expectError(
            error.WriteFailed,
            std.json.Stringify.value(.{
                .autoTier = @as(?AutoTier, .{ .custom = value }),
            }, .{ .emit_null_optional_fields = false }, &writer.writer),
        );
    }
}
