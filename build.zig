const std = @import("std");
const parity_evidence = @import("src/parity_evidence.zig");

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
    const census_runner = b.addExecutable(.{
        .name = "parity-census-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/parity_census_runner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_schema_tests.step);
    test_step.dependOn(&run_census_tests.step);
    for (parity_evidence.registry) |spec| {
        const evidence_module = b.createModule(.{
            .root_source_file = b.path(spec.source_file),
            .target = target,
            .optimize = optimize,
        });
        if (spec.package_root) |package_root| {
            evidence_module.addImport("copilot_sdk", b.createModule(.{
                .root_source_file = b.path(package_root),
                .target = target,
                .optimize = optimize,
            }));
        }
        const evidence_test = b.addTest(.{
            .name = b.fmt("census-{s}", .{@tagName(spec.id)}),
            .root_module = evidence_module,
            .filters = &.{spec.test_filter},
        });
        const run_evidence = b.addRunArtifact(census_runner);
        run_evidence.addArg(@tagName(spec.id));
        run_evidence.addArtifactArg(evidence_test);
        test_step.dependOn(&run_evidence.step);
    }
}
