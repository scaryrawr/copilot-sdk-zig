const std = @import("std");
const copilot = @import("copilot_sdk");

pub fn schemaFor(comptime T: type) []const u8 {
    return schemaForType(T);
}

pub fn ToolDefinition(comptime Arguments: type) type {
    return struct {
        name: []const u8,
        description: []const u8,
        handler: *const fn (std.mem.Allocator, Arguments) anyerror![]u8,
        skip_permission: bool = false,
    };
}

pub fn defineTool(
    comptime Arguments: type,
    comptime definition: ToolDefinition(Arguments),
) copilot.Tool {
    return .{
        .name = definition.name,
        .description = definition.description,
        .parameters_json = schemaFor(Arguments),
        .skip_permission = definition.skip_permission,
        .handler = struct {
            fn invoke(
                allocator: std.mem.Allocator,
                arguments_json: []const u8,
                _: ?*anyopaque,
            ) ![]u8 {
                const arguments = try std.json.parseFromSlice(
                    Arguments,
                    allocator,
                    arguments_json,
                    .{
                        .allocate = .alloc_always,
                        .ignore_unknown_fields = true,
                    },
                );
                defer arguments.deinit();
                return definition.handler(allocator, arguments.value);
            }
        }.invoke,
    };
}

fn schemaForType(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .bool => "{\"type\":\"boolean\"}",
        .int, .comptime_int => "{\"type\":\"integer\"}",
        .float, .comptime_float => "{\"type\":\"number\"}",
        .optional => |optional| schemaForType(optional.child),
        .pointer => |pointer| switch (pointer.size) {
            .slice => if (pointer.child == u8)
                "{\"type\":\"string\"}"
            else
                "{\"type\":\"array\",\"items\":" ++ schemaForType(pointer.child) ++ "}",
            else => @compileError("copilot_schema supports only slices, not single-item pointers"),
        },
        .array => |array| if (array.child == u8)
            "{\"type\":\"string\"}"
        else
            "{\"type\":\"array\",\"items\":" ++ schemaForType(array.child) ++ "}",
        .@"enum" => |enum_info| enumSchema(enum_info.fields),
        .@"struct" => |struct_info| structSchema(struct_info.fields),
        else => @compileError("unsupported Copilot tool parameter type: " ++ @typeName(T)),
    };
}

fn enumSchema(comptime fields: []const std.builtin.Type.EnumField) []const u8 {
    comptime var result: []const u8 = "{\"type\":\"string\",\"enum\":[";
    inline for (fields, 0..) |field, index| {
        if (index != 0) result = result ++ ",";
        result = result ++ "\"" ++ field.name ++ "\"";
    }
    return result ++ "]}";
}

fn structSchema(comptime fields: []const std.builtin.Type.StructField) []const u8 {
    comptime var properties: []const u8 = "{\"type\":\"object\",\"properties\":{";
    inline for (fields, 0..) |field, index| {
        if (index != 0) properties = properties ++ ",";
        properties = properties ++ "\"" ++ field.name ++ "\":" ++
            comptime schemaForType(field.type);
    }
    properties = properties ++ "}";

    comptime var required: []const u8 = ",\"required\":[";
    comptime var required_count: usize = 0;
    inline for (fields) |field| {
        if (@typeInfo(field.type) != .optional) {
            if (required_count != 0) required = required ++ ",";
            required = required ++ "\"" ++ field.name ++ "\"";
            required_count += 1;
        }
    }
    return properties ++ required ++ "]}";
}

test "derives object schemas from Zig types" {
    const Arguments = struct {
        city: []const u8,
        unit: ?enum { celsius, fahrenheit },
        days: u8,
    };

    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"},\"unit\":{\"type\":\"string\",\"enum\":[\"celsius\",\"fahrenheit\"]},\"days\":{\"type\":\"integer\"}},\"required\":[\"city\",\"days\"]}",
        schemaFor(Arguments),
    );
}

test "defines tools with typed handlers" {
    const Arguments = struct { city: []const u8 };
    const tool = defineTool(Arguments, .{
        .name = "weather",
        .description = "Get weather.",
        .handler = struct {
            fn handle(allocator: std.mem.Allocator, arguments: Arguments) ![]u8 {
                return std.fmt.allocPrint(allocator, "Weather for {s}", .{arguments.city});
            }
        }.handle,
    });

    const result = try tool.handler.?(
        std.testing.allocator,
        "{\"city\":\"Seattle\"}",
        tool.context,
    );
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Weather for Seattle", result);
}
