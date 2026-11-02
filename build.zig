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

    // The command line. Its step is "zdxc-cli" so that a dependent's
    // artifact("zdxc") names the library; it still installs as bin/zdxc.
    const exe = b.addExecutable(.{
        .name = "zdxc-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zdxc", .module = mod }},
        }),
    });
    const exe_name = if (target.result.os.tag == .windows) "zdxc.exe" else "zdxc";
    b.getInstallStep().dependOn(&b.addInstallArtifact(exe, .{ .dest_sub_path = exe_name }).step);

    // libzdxc: the C API (include/zdxc.h), static by default.
    const linkage = b.option(std.builtin.LinkMode, "linkage", "libzdxc: static (default) or dynamic") orelse .static;
    const lib = b.addLibrary(.{
        .name = "zdxc",
        .linkage = linkage,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/capi.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zdxc", .module = mod }},
        }),
    });
    // A static library carries its own compiler runtime, so C callers
    // need nothing else.
    lib.bundle_compiler_rt = true;
    lib.installHeader(b.path("include/zdxc.h"), "zdxc.h");
    b.installArtifact(lib);

    // The DXC drop-in: a `dxc` command line and a dxcompiler library with
    // DXC's COM entry points (src/dxcapi.zig), for programs that load
    // libdxcompiler / dxcompiler.dll themselves.
    const dropin_step = b.step("dropin", "Build the DXC drop-in: bin/dxc and the dxcompiler library");
    const dxc_name = if (target.result.os.tag == .windows) "dxc.exe" else "dxc";
    dropin_step.dependOn(&b.addInstallArtifact(exe, .{ .dest_sub_path = dxc_name }).step);
    const dxcompiler = b.addLibrary(.{
        .name = "dxcompiler",
        .linkage = .dynamic,
        .root_module = b.addModule("dxcapi", .{
            .root_source_file = b.path("src/dxcapi.zig"),
            .target = target,
            .optimize = optimize,
            // It is loaded into C programs, so it names the libc it uses
            // (for TLS, among others) instead of leaving it implied.
            .link_libc = target.result.os.tag != .windows,
            .imports = &.{.{ .name = "zdxc", .module = mod }},
        }),
    });
    dropin_step.dependOn(&b.addInstallArtifact(dxcompiler, .{}).step);
    // (Not installed by default, so a dependent finds it by this name
    // rather than with artifact().)
    b.addNamedLazyPath("dxcompiler", dxcompiler.getEmittedBin());

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
    const dxcapi_tests = b.addTest(.{ .root_module = dxcompiler.root_module });
    test_step.dependOn(&b.addRunArtifact(dxcapi_tests).step);
}
