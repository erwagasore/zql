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
    // Tests live alongside the code in src/zql.zig (Zig convention).
    const tests = b.addTest(.{ .root_module = lib_mod });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    // ── Check step (fast compilation check, no binary emitted) ────────────────
    // For libraries, check compilation by building the test artifact without running it.
    const check = b.addTest(.{ .root_module = lib_mod });
    const check_step = b.step("check", "Check compilation");
    check_step.dependOn(&check.step);
}
