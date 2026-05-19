const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zql_dep   = b.dependency("zql",   .{ .target = target, .optimize = optimize });
    const httpz_dep = b.dependency("httpz", .{ .target = target, .optimize = optimize });

    const web_mod = b.createModule(.{
        .root_source_file = b.path("src/web.zig"),
        .target           = target,
        .optimize         = optimize,
    });
    web_mod.addImport("zql",   zql_dep.module("zql"));
    web_mod.addImport("httpz", httpz_dep.module("httpz"));

    const exe = b.addExecutable(.{
        .name        = "zql-web-example",
        .root_module = web_mod,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run the example web server on :5882");
    run_step.dependOn(&run.step);
}
