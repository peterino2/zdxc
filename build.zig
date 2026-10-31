const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const hlsl_headers = b.createModule(.{
        .root_source_file = b.path("vendor/hlsl_headers.zig"),
        .target = target,
        .optimize = optimize,
    });
    // dxc's option table, generated from the vendored tablegen file by a
    // host tool (no tablegen or Python needed).
    const gen_options = b.addExecutable(.{
        .name = "gen_options",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_options.zig"),
            .target = b.graph.host,
        }),
    });
    const gen_options_run = b.addRunArtifact(gen_options);
    gen_options_run.addFileArg(b.path("vendor/dxc/HLSLOptions.td"));
    const options_table = gen_options_run.addOutputFileArg("options_table.zig");

    // dxc's intrinsic declarations, likewise generated at build time.
    const gen_intrinsics = b.addExecutable(.{
        .name = "gen_intrinsics",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_intrinsics.zig"),
            .target = b.graph.host,
        }),
    });
    const gen_intrinsics_run = b.addRunArtifact(gen_intrinsics);
    gen_intrinsics_run.addFileArg(b.path("vendor/dxc/gen_intrin_main.txt"));
    const intrinsics_table = gen_intrinsics_run.addOutputFileArg("intrinsics_table.zig");

    const mod = b.addModule("zdxc", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "hlsl_headers", .module = hlsl_headers }},
    });
    mod.addAnonymousImport("options_table", .{ .root_source_file = options_table });
    mod.addAnonymousImport("intrinsics_table", .{ .root_source_file = intrinsics_table });

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
    const dxil_checks = b.addSystemCommand(&.{ "sh", "test/dxil/check.sh" });
    dxil_checks.addArtifactArg(exe);
    dxil_checks.setCwd(b.path("."));
    dxil_checks.has_side_effects = true;
    oracle_step.dependOn(&dxil_checks.step);
    const spirv_checks = b.addSystemCommand(&.{ "sh", "test/spirv/check.sh" });
    spirv_checks.addArtifactArg(exe);
    spirv_checks.setCwd(b.path("."));
    spirv_checks.has_side_effects = true;
    oracle_step.dependOn(&spirv_checks.step);

    const oracle_parse_step = b.step("oracle-parse", "Parse every dxc-valid corpus file with zdxc");
    const oracle_parse = b.addSystemCommand(&.{ "sh", "test/oracle/parse.sh" });
    oracle_parse.addArtifactArg(exe);
    oracle_parse.setCwd(b.path("."));
    oracle_parse.has_side_effects = true;
    oracle_parse_step.dependOn(&oracle_parse.step);

    const oracle_sema_step = b.step("oracle-sema", "Check that Sema accepts every dxc-valid corpus file");
    const oracle_sema = b.addSystemCommand(&.{ "sh", "test/oracle/sema.sh" });
    oracle_sema.addArtifactArg(exe);
    oracle_sema.setCwd(b.path("."));
    oracle_sema.has_side_effects = true;
    oracle_sema.step.dependOn(&oracle_parse.step); // builds the corpus list
    oracle_sema_step.dependOn(&oracle_sema.step);

    const oracle_codegen_step = b.step("oracle-codegen", "Compile the dxc-valid corpus to SPIR-V and DXIL and validate the output");
    for ([_][]const u8{ "spirv", "dxil" }) |backend| {
        const run = b.addSystemCommand(&.{ "sh", "test/oracle/codegen.sh" });
        run.addArtifactArg(exe);
        run.addArg(backend);
        run.setCwd(b.path("."));
        run.has_side_effects = true;
        run.step.dependOn(&oracle_parse.step); // builds the corpus list
        oracle_codegen_step.dependOn(&run.step);
    }

    const oracle_verify_step = b.step("oracle-verify", "Compare Sema errors with dxc's SemaHLSL -verify expectations");
    const oracle_verify = b.addSystemCommand(&.{ "sh", "test/oracle/verify.sh" });
    oracle_verify.addArtifactArg(exe);
    oracle_verify.setCwd(b.path("."));
    oracle_verify.has_side_effects = true;
    oracle_verify_step.dependOn(&oracle_verify.step);

    const oracle_cli_step = b.step("oracle-cli", "Parse every dxc command line in the DXC test corpus");
    const oracle_cli = b.addSystemCommand(&.{ "sh", "test/oracle/cli.sh" });
    oracle_cli.addArtifactArg(exe);
    oracle_cli.setCwd(b.path("."));
    oracle_cli.has_side_effects = true;
    oracle_cli_step.dependOn(&oracle_cli.step);

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
