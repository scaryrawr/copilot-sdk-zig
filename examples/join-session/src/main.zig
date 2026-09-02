const std = @import("std");
const copilot = @import("copilot_sdk");
const schema = @import("copilot_schema");

const ExtensionStatusArguments = struct {};

const extension_tool = schema.defineTool(ExtensionStatusArguments, .{
    .name = "zig_extension_status",
    .description = "Report whether the Zig extension is connected.",
    .skip_permission = true,
    .handler = struct {
        fn handle(
            allocator: std.mem.Allocator,
            _: ExtensionStatusArguments,
        ) ![]u8 {
            return allocator.dupe(u8, "The Zig extension is connected.");
        }
    }.handle,
});

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3 or !std.mem.eql(u8, args[1], "--session-id")) {
        return error.InvalidArguments;
    }

    var client = try copilot.Client.initParent(init.gpa, init.io);
    defer client.deinit();
    const session = try client.joinSession(args[2], .{
        .model = "gpt-5.6-luna",
        .tools = &.{extension_tool},
    });

    while (true) {
        var event = session.nextEvent() catch break;
        defer event.deinit(init.gpa);
    }
}
