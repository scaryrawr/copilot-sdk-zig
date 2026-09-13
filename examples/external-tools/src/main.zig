const std = @import("std");
const copilot = @import("copilot_sdk");
const schema = @import("copilot_schema");

const StatusArguments = struct {
    environment: []const u8,
};

const status_tool = copilot.Tool{
    .name = "external_deployment_status",
    .description = "Read a deployment status supplied by the SDK consumer.",
    .parameters_json = schema.schemaFor(StatusArguments),
    // No handler: the request is surfaced as an event for manual resolution.
};

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
    defer session.disconnect() catch |err| {
        std.log.err("session cleanup failed: {s}", .{@errorName(err)});
    };

    const message_id = try session.send(.{
        .prompt = "Use external_deployment_status for staging and report the result.",
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
                try session.approvePermission(request.request_id);
            },
            .external_tool_requested => |request| {
                const arguments = try request.parseArguments(StatusArguments, init.gpa);
                defer arguments.deinit();
                const result = try std.fmt.allocPrint(
                    init.gpa,
                    "{s} is awaiting approval",
                    .{arguments.value.environment},
                );
                defer init.gpa.free(result);
                try session.respondToTool(request.request_id, result);
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
            "Manually resolves a declaration-only external tool request.\n",
    );
    try writer.interface.flush();
}
