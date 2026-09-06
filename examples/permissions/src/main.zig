const std = @import("std");
const copilot = @import("copilot_sdk");
const schema = @import("copilot_schema");

const StatusArguments = struct {
    environment: []const u8,
};

const status_tool = schema.defineTool(StatusArguments, .{
    .name = "read_deployment_status",
    .description = "Read the deployment status for an environment.",
    .handler = struct {
        fn handle(allocator: std.mem.Allocator, arguments: StatusArguments) ![]u8 {
            return std.fmt.allocPrint(
                allocator,
                "{s} is healthy",
                .{arguments.environment},
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
        .tools = &.{status_tool},
        .request_permission = true,
    });
    defer session.disconnect() catch {};

    const message_id = try session.send(.{
        .prompt = "Use read_deployment_status for production and report the result.",
    });
    defer init.gpa.free(message_id);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    while (true) {
        var event = try session.nextEvent();
        defer event.deinit(init.gpa);

        switch (event) {
            .permission_requested => |request| {
                const kind = try request.kind();
                try stdout.print("permission kind: {s}\n", .{@tagName(kind)});
                switch (kind) {
                    .custom_tool => try session.approvePermission(request.request_id),
                    else => try session.rejectPermission(
                        request.request_id,
                        "This example approves only custom tools.",
                    ),
                }
            },
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
            "Prints and approves a custom tool permission request.\n",
    );
    try writer.interface.flush();
}
