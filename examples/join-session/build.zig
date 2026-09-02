const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const copilot = b.dependency("copilot_sdk", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "join-session",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "copilot_sdk", .module = copilot.module("copilot_sdk") },
                .{ .name = "copilot_schema", .module = copilot.module("copilot_schema") },
            },
        }),
    });
    b.installArtifact(exe);
}
