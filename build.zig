const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("copilot_sdk", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const schema_module = b.addModule("copilot_schema", .{
        .root_source_file = b.path("src/schema.zig"),
        .target = target,
        .optimize = optimize,
    });
    schema_module.addImport("copilot_sdk", module);

    const library = b.addLibrary(.{
        .name = "copilot_sdk",
        .root_module = module,
    });
    b.installArtifact(library);

    const tests = b.addTest(.{ .root_module = module });
    const run_tests = b.addRunArtifact(tests);
    const schema_tests = b.addTest(.{ .root_module = schema_module });
    const run_schema_tests = b.addRunArtifact(schema_tests);
    const census_module = b.createModule(.{
        .root_source_file = b.path("src/parity_census.zig"),
        .target = target,
        .optimize = optimize,
    });
    census_module.addImport("parity_requirements", b.createModule(.{
        .root_source_file = b.path("testdata/protocol_parity_requirements.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const census_tests = b.addTest(.{ .root_module = census_module });
    const run_census_tests = b.addRunArtifact(census_tests);
    const run_census = b.addSystemCommand(&.{ "bash", "./scripts/parity-census.sh" });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_schema_tests.step);
    test_step.dependOn(&run_census_tests.step);
    test_step.dependOn(&run_census.step);
}
