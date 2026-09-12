const std = @import("std");
const copilot = @import("copilot_sdk");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1 and std.mem.eql(u8, args[1], "--help")) {
        return printHelp(init.io);
    }

    var client = try copilot.Client.init(init.gpa, init.io, .{}, null);
    defer client.deinit();
    const session = try client.createSession(.{
        .model = "gpt-5.6-luna",
    }, null);
    defer session.disconnect(null) catch {};

    const response = try session.sendAndWait(.{
        .prompt = "Explain Zig error unions in one sentence.",
    }, null) orelse return error.MissingAssistantResponse;
    defer response.deinit(init.gpa);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try stdout_writer.interface.print("{s}\n", .{response.content});
    try stdout_writer.interface.flush();
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
