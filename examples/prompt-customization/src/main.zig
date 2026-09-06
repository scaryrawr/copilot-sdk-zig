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
        .system_message = .{
            .mode = .append,
            .content = "Answer as a concise Zig mentor and include one practical tip.",
        },
    });
    defer session.disconnect() catch {};

    const message_id = try session.send(.{
        .prompt = "What is an error union?",
    });
    defer init.gpa.free(message_id);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    while (true) {
        var event = try session.nextEvent();
        defer event.deinit(init.gpa);

        switch (event) {
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
            "Appends custom instructions to the session system message.\n",
    );
    try writer.interface.flush();
}
