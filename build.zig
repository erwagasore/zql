const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Library module (importable by dependents) ─────────────────────────────
    const lib_mod = b.addModule("zql", .{
        .root_source_file = b.path("src/zql.zig"),
        .target           = target,
        .optimize         = optimize,
    });

    // ── Tests ─────────────────────────────────────────────────────────────────
    const tests = b.addTest(.{
        .root_source_file = b.path("tests/zql_test.zig"),
        .target           = target,
        .optimize         = optimize,
    });
    tests.root_module.addImport("zql", lib_mod);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
