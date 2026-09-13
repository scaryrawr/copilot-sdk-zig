const std = @import("std");
const copilot = @import("copilot_sdk");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len > 1 and std.mem.eql(u8, args[1], "--help")) {
        try printHelp(init.io);
        return;
    }

    var cli_path: []const u8 = "copilot";
    if (args.len > 1) {
        if (args.len != 3 or !std.mem.eql(u8, args[1], "--cli-path")) {
            try printHelp(init.io);
            return error.InvalidArgument;
        }
        cli_path = args[2];
    }

    var client = try copilot.Client.init(allocator, init.io, .{ .cli_path = cli_path });
    defer client.deinit();

    var session = try client.createSession(.{
        .model = "gpt-5.6-luna",
        .streaming = true,
        .on_permission_request = copilot.approveAll,
    });
    defer session.disconnect() catch |err| {
        std.log.err("session cleanup failed: {s}", .{@errorName(err)});
    };

    const message_id = try session.send(.{ .prompt = "Explain this repository in one paragraph." });
    defer allocator.free(message_id);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("message id: {s}\n", .{message_id});

    var received_delta = false;
    while (true) {
        var event = try session.nextEvent();
        defer event.deinit(allocator);

        switch (event) {
            .assistant_message => |message| {
                if (received_delta) {
                    try stdout.writeByte('\n');
                } else {
                    try stdout.print("{s}\n", .{message.content});
                }
            },
            .assistant_message_delta => |delta| {
                received_delta = true;
                try stdout.print("{s}", .{delta.delta_content});
            },
            .assistant_reasoning, .assistant_reasoning_delta => {},
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
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    try stdout_writer.interface.writeAll(
        "Usage: zig build run -- [--cli-path PATH]\n\n" ++
            "Starts Copilot CLI, sends a prompt, and prints the response.\n",
    );
    try stdout_writer.interface.flush();
}
