const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const hlsl_headers = b.createModule(.{
        .root_source_file = b.path("vendor/hlsl_headers.zig"),
        .target = target,
        .optimize = optimize,
    });
    const mod = b.addModule("zdxc", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "hlsl_headers", .module = hlsl_headers }},
    });

    const exe = b.addExecutable(.{
        .name = "zdxc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zdxc", .module = mod }},
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run zdxc");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const test_step = b.step("test", "Run unit tests");
    const mod_tests = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    // Oracle checks: compare zdxc output against the DXC build in ../build.
    const oracle_step = b.step("oracle", "Validate zdxc output with dxv and spirv-val");
    const oracle = b.addSystemCommand(&.{ "sh", "test/oracle/m0.sh" });
    oracle.addArtifactArg(exe);
    oracle.setCwd(b.path("."));
    oracle.has_side_effects = true;
    oracle_step.dependOn(&oracle.step);

    const oracle_parse_step = b.step("oracle-parse", "Parse every dxc-valid corpus file with zdxc");
    const oracle_parse = b.addSystemCommand(&.{ "sh", "test/oracle/parse.sh" });
    oracle_parse.addArtifactArg(exe);
    oracle_parse.setCwd(b.path("."));
    oracle_parse.has_side_effects = true;
    oracle_parse_step.dependOn(&oracle_parse.step);

    // Benchmarks always build optimized so numbers are comparable.
    const bench = b.addExecutable(.{
        .name = "pp_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/pp_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "zdxc", .module = mod }},
        }),
    });
    const bench_step = b.step("bench", "Build the preprocessor benchmark (zig-out/bin/pp_bench)");
    bench_step.dependOn(&b.addInstallArtifact(bench, .{}).step);

    const oracle_pp_step = b.step("oracle-pp", "Compare zdxc -P with dxc -P over the DXC test corpus");
    const oracle_pp = b.addSystemCommand(&.{ "sh", "test/oracle/pp.sh" });
    oracle_pp.addArtifactArg(exe);
    oracle_pp.setCwd(b.path("."));
    oracle_pp.has_side_effects = true;
    oracle_pp_step.dependOn(&oracle_pp.step);
}
