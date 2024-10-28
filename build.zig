const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const huge_alloc_mod = b.addModule("huge_alloc", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const bench = b.addExecutable(.{
        .name = "bench",
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zstd_dependency = b.dependency("zstd", .{
        .target = target,
        .optimize = optimize,
    });
    bench.linkLibrary(zstd_dependency.artifact("zstd"));
    bench.root_module.addImport("huge_alloc", huge_alloc_mod);

    const run_bench = b.addRunArtifact(bench);

    const run_bench_step = b.step("runbench", "Run the benchmark application");
    run_bench_step.dependOn(&run_bench.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // This exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
