const std = @import("std");

fn countExactLines(output: []const u8, expected: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.eql(u8, line, expected)) count += 1;
    }
    return count;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) {
        std.debug.print("usage: {s} <evidence-id> <test-binary>\n", .{args[0]});
        return error.InvalidArguments;
    }

    const result = try std.process.run(allocator, init.io, .{
        .argv = &.{args[2]},
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(16 * 1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.stdout.len != 0) std.debug.print("{s}", .{result.stdout});
    if (result.stderr.len != 0) std.debug.print("{s}", .{result.stderr});

    var marker_buffer: [256]u8 = undefined;
    const marker = try std.fmt.bufPrint(&marker_buffer, "CENSUS_PROBE {s}", .{args[1]});
    const marker_count = countExactLines(result.stdout, marker) +
        countExactLines(result.stderr, marker);
    const passed_count = countExactLines(result.stdout, "All 1 tests passed.") +
        countExactLines(result.stderr, "All 1 tests passed.");
    const exited_successfully = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };

    if (!exited_successfully or marker_count != 1 or passed_count != 1) {
        std.debug.print(
            "CENSUS_TEST_FAILED {s} exit_success={} markers={d} one_test_summaries={d}\n",
            .{ args[1], exited_successfully, marker_count, passed_count },
        );
        return error.CensusEvidenceFailed;
    }
    std.debug.print("CENSUS_TEST_PASSED {s}\n", .{args[1]});
}
