const std = @import("std");
const copilot = @import("copilot_sdk");
const schema = @import("copilot_schema");

const WeatherArguments = struct {
    city: []const u8,
};

const weather_tool = schema.defineTool(WeatherArguments, .{
    .name = "get_weather",
    .description = "Get the current weather for a city.",
    .skip_permission = true,
    .handler = struct {
        fn handle(allocator: std.mem.Allocator, arguments: WeatherArguments) ![]u8 {
            return std.fmt.allocPrint(
                allocator,
                "Weather in {s}: 18 C, partly cloudy.",
                .{arguments.city},
            );
        }
    }.handle,
});

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1 and std.mem.eql(u8, args[1], "--help")) {
        return printHelp(init.io);
    }

    var client = try copilot.Client.init(init.gpa, init.io, .{});
    defer client.deinit();
    const session = try client.createSession(.{
        .model = "gpt-5.6-luna",
        .tools = &.{weather_tool},
    });
    defer session.disconnect() catch |err| {
        std.log.err("session cleanup failed: {s}", .{@errorName(err)});
    };

    const message_id = try session.send(.{
        .prompt = "Use get_weather to check the weather in Seattle, then summarize it.",
    });
    defer init.gpa.free(message_id);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    while (true) {
        var event = try session.nextEvent();
        defer event.deinit(init.gpa);

        switch (event) {
            .external_tool_requested => |request| try stdout.print(
                "called tool: {s}\n",
                .{request.tool_name},
            ),
            .assistant_message => |message| try stdout.print("{s}\n", .{message.content}),
            .session_idle => break,
            .session_error => |err| {
                try stdout.print("Copilot session error: {s}\n", .{err.message});
                try stdout.flush();
                return error.CopilotSessionError;
            },
            else => {},
        }
    }
    try stdout.flush();
}

fn printHelp(io: std.Io) !void {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.writeAll(
        "Usage: zig build run -- [--help]\n\n" ++
            "Registers a custom get_weather tool and handles its invocation.\n",
    );
    try writer.interface.flush();
}
