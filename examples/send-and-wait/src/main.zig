const std = @import("std");
const copilot = @import("copilot_sdk");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1 and std.mem.eql(u8, args[1], "--help")) {
        return printHelp(init.io);
    }

    var client = try copilot.Client.init(init.gpa, init.io, .{});
    defer client.deinit();
    const session = try client.createSession(.{
        .model = "gpt-5.6-luna",
    });
    var session_connected = true;
    defer if (session_connected) {
        session.disconnect() catch |err| {
            std.log.err("failed to disconnect Copilot session: {s}", .{@errorName(err)});
        };
    };

    const response = try session.sendAndWaitWithOptions(
        .{ .prompt = "Explain Zig error unions in one sentence." },
        .{ .timeout_ns = 30 * std.time.ns_per_s },
    ) orelse return error.MissingAssistantResponse;
    defer response.deinit(init.gpa);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try stdout_writer.interface.print("{s}\n", .{response.content});
    try stdout_writer.interface.flush();
    try session.disconnect();
    session_connected = false;
    try client.shutdown();
}

fn printHelp(io: std.Io) !void {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.writeAll(
        "Usage: zig build run -- [--help]\n\n" ++
            "Sends a non-streaming prompt and waits for the final response.\n",
    );
    try writer.interface.flush();
}
