const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zdxc", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
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
}
