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
}
