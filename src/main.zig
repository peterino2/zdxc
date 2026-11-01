const std = @import("std");
const Io = std.Io;
const zdxc = @import("zdxc");
const shader = zdxc.dxil.shader;
const container = zdxc.dxil.container;
const front = zdxc.front;

const options = zdxc.options;

const Options = struct {
    profile: ?[]const u8 = null,
    entry: []const u8 = "main",
    output: ?[]const u8 = null,
    input: ?[]const u8 = null,
    spirv: bool = false,
    /// -fspv-target-env (vulkan1.0 by default).
    target_env: []const u8 = "vulkan1.0",
    preprocess: bool = false,
    pp_output: ?[]const u8 = null,
    enable_16bit: bool = false,
    /// -force-rootsig-ver, -Qstrip_rootsignature, -rootsig-define, -Frs.
    rootsig_ver: ?[]const u8 = null,
    strip_rootsig: bool = false,
    rootsig_define: ?[]const u8 = null,
    rootsig_output: ?[]const u8 = null,
    vk: zdxc.ir.ir.VkOptions = .{},
    defines: std.ArrayList(front.preproc.Define) = .empty,
    include_dirs: std.ArrayList([]const u8) = .empty,
    empty: bool = false,
    check_hash: bool = false,
    lex: bool = false,
    warnings_as_errors: bool = false,
    no_warnings: bool = false,
    disabled_warnings: std.ArrayList([]const u8) = .empty,
    diag_format: zdxc.diag.Format = .clang,
    color: ?bool = null,
    error_limit: u32 = 20,
    parse: bool = false,
    dump_ast: bool = false,
    sema: bool = false,
    dump_ir: bool = false,
    /// -O0..-O3 / -Od (default -O3, as in dxc).
    opt_level: enum { od, o0, o1, o2, o3 } = .o3,
    /// Accepted options with no effect yet, reported once each.
    ignored: std.ArrayList([]const u8) = .empty,
};

const Cli = struct {
    io: Io,
    stderr: *Io.Writer,

    fn fail(cli: Cli, comptime fmt: []const u8, args: anytype) error{Fatal} {
        cli.stderr.print("zdxc: error: " ++ fmt ++ "\n", args) catch {};
        cli.stderr.flush() catch {};
        return error.Fatal;
    }
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const cli: Cli = .{ .io = io, .stderr = &stderr_writer.interface };
    defer stderr_writer.interface.flush() catch {};

    // Exit codes follow dxc: 1 for command-line and I/O errors, 5 when the
    // compilation reports errors.
    run(cli, arena, try init.minimal.args.toSlice(arena), &stdout_writer.interface) catch |err| switch (err) {
        error.Fatal => return 1,
        error.CompileFailed => return 5,
        else => return err,
    };
    try stdout_writer.interface.flush();
    return 0;
}

/// Parse a dxc-style command line. Returns null when the command is
/// complete (`-help`, `--version`).
fn parseArgs(cli: Cli, arena: std.mem.Allocator, argv: []const [:0]const u8, stdout: *Io.Writer) !?Options {
    var failure: options.Failure = .{};
    const plain = try arena.alloc([]const u8, argv.len -| 1);
    for (plain, 0..) |*a, i| a.* = argv[i + 1];
    const parsed = options.parse(arena, plain, &failure) catch |e| switch (e) {
        error.UnknownArgument => return cli.fail("unknown argument: '{s}'", .{failure.arg}),
        error.MissingArgument => return cli.fail("argument to '{s}' is missing", .{failure.arg}),
        error.OutOfMemory => return error.OutOfMemory,
    };

    var opts: Options = .{};
    for (parsed.args) |a| {
        switch (a.which) {
            .extra => |x| switch (x) {
                .zdxc_empty => opts.empty = true,
                .zdxc_check_hash => opts.check_hash = true,
                .zdxc_lex => opts.lex = true,
                .zdxc_parse => opts.parse = true,
                .zdxc_ast => {
                    opts.parse = true;
                    opts.dump_ast = true;
                },
                .zdxc_sema => opts.sema = true,
                .zdxc_ir => opts.dump_ir = true,
                .fcolor_diagnostics => opts.color = true,
                .fno_color_diagnostics => opts.color = false,
            },
            .dxc => |id| {
                switch (options.support(id)) {
                    .implemented => {},
                    .ignored => {
                        try opts.ignored.append(arena, a.spelling);
                        continue;
                    },
                    .unsupported => |why| return cli.fail("'{s}' is not supported: {s}", .{ a.spelling, why }),
                }
                const v = a.value();
                switch (id) {
                    .target_profile => opts.profile = v,
                    .entrypoint => opts.entry = v,
                    .Fo => opts.output = v,
                    .Fi => opts.pp_output = v,
                    .D => if (std.mem.indexOfScalar(u8, v, '=')) |eq| {
                        try opts.defines.append(arena, .{ .name = v[0..eq], .value = v[eq + 1 ..] });
                    } else try opts.defines.append(arena, .{ .name = v }),
                    .I => try opts.include_dirs.append(arena, v),
                    .hlsl_version => if (!std.mem.eql(u8, v, "2021")) {
                        return cli.fail("HLSL version {s} is not supported; zdxc implements HLSL 2021 only", .{v});
                    },
                    .P => opts.preprocess = true,
                    .spirv => opts.spirv = true,
                    .fspv_target_env_EQ => opts.target_env = v,
                    .enable_16bit_types => opts.enable_16bit = true,
                    .force_rootsig_ver, .force_rootsig_ver_ => opts.rootsig_ver = v,
                    .Qstrip_rootsignature => opts.strip_rootsig = true,
                    .rootsig_define => opts.rootsig_define = v,
                    .Frs => opts.rootsig_output = v,
                    .fvk_b_shift, .fvk_t_shift, .fvk_s_shift, .fvk_u_shift => {
                        const k: usize = switch (id) {
                            .fvk_b_shift => 0,
                            .fvk_t_shift => 1,
                            .fvk_s_shift => 2,
                            else => 3,
                        };
                        const shift = std.fmt.parseInt(u32, a.values[0], 10) catch return cli.fail("invalid {s} shift '{s}'", .{ a.spelling, a.values[0] });
                        const set: ?u32 = if (std.mem.eql(u8, a.values[1], "all")) null else std.fmt.parseInt(u32, a.values[1], 10) catch return cli.fail("invalid {s} space '{s}'", .{ a.spelling, a.values[1] });
                        try opts.vk.shifts[k].append(arena, .{ .shift = shift, .set = set });
                    },
                    .fvk_bind_globals => opts.vk.bind_globals = .{
                        std.fmt.parseInt(u32, a.values[0], 10) catch return cli.fail("invalid -fvk-bind-globals binding number: {s}", .{a.values[0]}),
                        std.fmt.parseInt(u32, a.values[1], 10) catch return cli.fail("invalid -fvk-bind-globals set number: {s}", .{a.values[1]}),
                    },
                    .fvk_bind_register, .vkbr => {
                        const reg = a.values[0];
                        if (reg.len < 2 or std.mem.indexOfScalar(u8, "btsu", reg[0]) == null) return cli.fail("invalid -fvk-bind-register register '{s}'", .{reg});
                        const num = struct {
                            fn f(c: Cli, t: []const u8) !u32 {
                                return std.fmt.parseInt(u32, t, 10) catch c.fail("invalid -fvk-bind-register number '{s}'", .{t});
                            }
                        }.f;
                        try opts.vk.bind_register.append(arena, .{ .class = reg[0], .index = try num(cli, reg[1..]), .space = try num(cli, a.values[1]), .binding = try num(cli, a.values[2]), .set = try num(cli, a.values[3]) });
                    },
                    .auto_binding_space => opts.vk.auto_binding_space = std.fmt.parseInt(u32, v, 10) catch return cli.fail("invalid -auto-binding-space '{s}'", .{v}),
                    .fvk_auto_shift_bindings => opts.vk.auto_shift = true,
                    .fspv_flatten_resource_arrays => opts.vk.flatten_arrays = true,
                    .fspv_use_legacy_buffer_matrix_order => opts.vk.legacy_matrix_order = true,
                    .fspv_use_vulkan_memory_model => opts.vk.vulkan_memory_model = true,
                    // (zdxc never removes interface variables.)
                    .fspv_preserve_interface => {},
                    .fvk_invert_y => opts.vk.invert_y = true,
                    .fvk_use_gl_layout => opts.vk.layout = .gl,
                    .fvk_use_dx_layout => opts.vk.layout = .dx,
                    .fvk_use_scalar_layout => opts.vk.layout = .scalar,
                    .fspv_entrypoint_name_EQ => opts.vk.entry_name = v,
                    .fspv_extension_EQ => try opts.vk.extensions.append(arena, v),
                    .fspv_reflect => opts.vk.reflect = true,
                    .fspv_enable_maximal_reconvergence => opts.vk.maximal_reconvergence = true,
                    .fvk_support_nonzero_base_instance => opts.vk.nonzero_base_instance = true,
                    .fvk_support_nonzero_base_vertex => opts.vk.nonzero_base_vertex = true,
                    .fspv_use_unknown_image_format => opts.vk.unknown_image_format = true,
                    .fvk_use_dx_position_w => opts.vk.dx_position_w = true,
                    .fvk_stage_io_order_EQ => {
                        if (std.mem.eql(u8, v, "alpha")) opts.vk.alpha_io_order = true else if (!std.mem.eql(u8, v, "decl")) return cli.fail("unknown -fvk-stage-io-order '{s}'", .{v});
                    },
                    ._SLASH_WX => opts.warnings_as_errors = true,
                    .no_warnings => opts.no_warnings = true,
                    .W_Joined => {
                        // -Wno-<group>, -Werror; enabling groups is a no-op.
                        if (std.mem.startsWith(u8, v, "no-")) {
                            try opts.disabled_warnings.append(arena, v[3..]);
                        } else if (std.mem.eql(u8, v, "error")) opts.warnings_as_errors = true;
                    },
                    .Wno_vk_ignored_features => try opts.disabled_warnings.append(arena, "vk-ignored-features"),
                    .Wno_vk_emulated_features => try opts.disabled_warnings.append(arena, "vk-emulated-features"),
                    .fdiagnostics_format_EQ => {
                        // dxc also accepts msvc-fallback.
                        const name = if (std.mem.eql(u8, v, "msvc-fallback")) "msvc" else v;
                        opts.diag_format = std.meta.stringToEnum(zdxc.diag.Format, name) orelse
                            return cli.fail("unknown diagnostics format '{s}' (expected clang, msvc or vi)", .{v});
                    },
                    .ferror_limit_EQ => opts.error_limit = std.fmt.parseInt(u32, v, 10) catch
                        return cli.fail("invalid -ferror-limit value '{s}'", .{v}),
                    .fdiagnostics_color => opts.color = true,
                    .fdiagnostics_color_EQ => opts.color = if (std.mem.eql(u8, v, "always"))
                        true
                    else if (std.mem.eql(u8, v, "never"))
                        false
                    else
                        null,
                    .help, ._help_question, ._help_hidden => {
                        try options.printHelp(stdout, id == ._help_hidden);
                        return null;
                    },
                    ._version => {
                        try stdout.print("zdxc {s} (dxc-compatible command line, HLSL 2021)\n", .{zdxc.version});
                        return null;
                    },
                    .O0 => opts.opt_level = .o0,
                    .O1 => opts.opt_level = .o1,
                    .O2 => opts.opt_level = .o2,
                    .O3 => opts.opt_level = .o3,
                    .Od => opts.opt_level = .od,
                    else => {}, // implemented as a no-op (e.g. -Vd, -nologo)
                }
            },
        }
    }
    // Like dxc, the last input wins (dxc reads getLastArgValue(OPT_INPUT)).
    if (parsed.inputs.len > 0) opts.input = parsed.inputs[parsed.inputs.len - 1];

    if (opts.ignored.items.len > 0 and !opts.no_warnings) {
        try cli.stderr.writeAll("zdxc: note: accepted for compatibility, no effect yet:");
        for (opts.ignored.items) |sp| try cli.stderr.print(" {s}", .{sp});
        try cli.stderr.writeByte('\n');
    }
    return opts;
}

fn run(cli: Cli, arena: std.mem.Allocator, args: []const [:0]const u8, stdout: *Io.Writer) !void {
    const opts = try parseArgs(cli, arena, args, stdout) orelse return;

    if (opts.check_hash) {
        const path = opts.input orelse return cli.fail("no input file", .{});
        const bytes = try Io.Dir.cwd().readFileAlloc(cli.io, path, arena, .limited(1 << 30));
        const view = container.parse(arena, bytes) catch return cli.fail("{s}: not a DXIL container", .{path});
        if (!container.hashMatches(view.bytes)) return cli.fail("{s}: hash mismatch", .{path});
        try stdout.print("{s}: hash ok ({d} parts)\n", .{ path, view.parts.items.len });
        return;
    }

    if (opts.lex) {
        const path = opts.input orelse return cli.fail("no input file", .{});
        const text = try Io.Dir.cwd().readFileAlloc(cli.io, path, arena, .limited(256 << 20));
        var lx = front.lexer.Lexer.init(text, 0);
        while (true) {
            const t = lx.next();
            if (t.kind == .eof) break;
            if (t.kind == .hash and t.flags.bol) {
                const save = lx;
                const d = lx.next();
                if (d.isIdent("line")) {
                    lx.skipLine();
                    continue;
                }
                lx = save;
            }
            try stdout.print("{s}\n", .{t.text});
        }
        return;
    }

    // Root signature targets: the root signature in the macro -E names.
    if (opts.profile) |p| if (std.mem.eql(u8, p, "rootsig_1_0") or std.mem.eql(u8, p, "rootsig_1_1")) {
        const input = opts.input orelse return cli.fail("no input file", .{});
        const out = opts.output orelse return cli.fail("missing -Fo <file>", .{});
        const version: zdxc.dxil.rootsig.Version = if (std.mem.eql(u8, p, "rootsig_1_0")) .v1_0 else .v1_1;
        const blob = try compileRootSignatureMacro(cli, arena, opts, input, opts.entry, version, .none) orelse return error.CompileFailed;
        try Io.Dir.cwd().writeFile(cli.io, .{ .sub_path = out, .data = try rootSignatureContainer(arena, blob) });
        return;
    };

    const profile: ?shader.Profile = if (opts.profile) |p|
        shader.Profile.parse(p) orelse return cli.fail("unknown profile '{s}'", .{p})
    else
        null;

    // The front end: everything except the development modes that work on
    // containers or raw tokens.
    if (!opts.empty) {
        const input = opts.input orelse return cli.fail("no input file", .{});
        var disk: front.source.DiskFs = .{ .io = cli.io };
        var sm = front.source.SourceManager.init(arena, disk.fileSystem());
        var diags = zdxc.Diagnostics.init(arena);
        diags.warnings_as_errors = opts.warnings_as_errors;
        diags.suppress_warnings = opts.no_warnings;
        diags.error_limit = opts.error_limit;
        for (opts.disabled_warnings.items) |g| try diags.disableGroup(g);
        var pp = front.preproc.Preprocessor.init(arena, &sm, &diags, .{
            .defines = opts.defines.items,
            .include_dirs = opts.include_dirs.items,
            .stage = if (profile) |p| @backingInt(p.kind) else 5,
            .major = if (profile) |p| p.major else 6,
            .minor = if (profile) |p| p.minor else 0,
            .spirv = opts.spirv,
            .spirv_minor = if (zdxc.spirv.emit.TargetEnv.parse(opts.target_env)) |t| t.minor else 0,
            .enable_16bit = opts.enable_16bit,
        });
        var out: Io.Writer.Allocating = .init(arena);
        var module: ?zdxc.ir.ir.Module = null;
        if (try pp.enterMainFile(input)) {
            if (opts.preprocess) {
                try front.pp_print.print(&pp, &out.writer);
            } else {
                var parser = try front.parser.Parser.fromPreprocessor(arena, &diags, &pp);
                const tu = try parser.parseTranslationUnit();
                if (opts.dump_ast) try front.ast_dump.dumpUnit(stdout, tu);
                if (!opts.parse) {
                    const is_lib = if (profile) |p| p.kind == .library else true;
                    var sema = try zdxc.sema.Sema.init(arena, &diags, .{
                        .entry = if (opts.sema or is_lib) null else opts.entry,
                        .spirv = opts.spirv,
                        .enable_16bit = opts.enable_16bit,
                        .sm_minor = if (profile) |p| p.minor else 10,
                        .library = is_lib,
                        .root = opts.entry,
                    });
                    try sema.checkUnit(tu);
                    if (!opts.sema and !diags.hasErrors() and profile != null) {
                        const stage: zdxc.ir.ir.Stage = switch (profile.?.kind) {
                            .vertex => .vertex,
                            .pixel => .pixel,
                            .geometry => .geometry,
                            .hull => .hull,
                            .domain => .domain,
                            .compute => .compute,
                            .mesh => .mesh,
                            .amplification => .amplification,
                            else => .library,
                        };
                        module = zdxc.ir.lower.lowerUnit(arena, &sema, .{ .entry = opts.entry, .stage = stage }) catch |e| switch (e) {
                            error.Unsupported => null,
                            else => |x| return x,
                        };
                        if (module) |*mm| {
                            mm.native_16bit = opts.enable_16bit;
                            mm.vk = opts.vk;
                            mm.strip_rootsig = opts.strip_rootsig;
                            if (opts.rootsig_ver) |rv| {
                                if (std.mem.eql(u8, rv, "rootsig_1_0")) mm.rootsig_version = .v1_0 else if (!std.mem.eql(u8, rv, "rootsig_1_1")) return cli.fail("unknown root signature version '{s}'", .{rv});
                            }
                        }
                    }
                }
            }
        }
        const color = opts.color orelse (Io.File.stderr().supportsAnsiEscapeCodes(cli.io) catch false);
        try diags.render(&sm, cli.stderr, .{ .format = opts.diag_format, .color = color });
        try cli.stderr.flush();
        if (diags.hasErrors()) return error.CompileFailed;
        if (opts.preprocess) {
            if (opts.pp_output) |path| {
                try Io.Dir.cwd().writeFile(cli.io, .{ .sub_path = path, .data = out.written() });
            } else try stdout.writeAll(out.written());
            return;
        }
        if (opts.parse or opts.sema) return;
        if (profile == null) return cli.fail("missing -T <profile>", .{});
        if (module) |*m| {
            try zdxc.ir.opt.run(arena, m);
            if (opts.dump_ir) {
                try zdxc.ir.ir.dump(m, stdout);
                return;
            }
            if (opts.spirv) {
                zdxc.ir.split_resources.run(arena, m, &diags) catch |err| switch (err) {
                    error.Unsupported => {
                        try diags.render(&sm, cli.stderr, .{ .format = opts.diag_format, .color = false });
                        try cli.stderr.flush();
                        return error.CompileFailed;
                    },
                    else => |x| return x,
                };
                const bytes = zdxc.spirv.emit.emit(arena, m, &diags, zdxc.spirv.emit.TargetEnv.parse(opts.target_env) orelse return cli.fail("unknown SPIR-V target environment '{s}'", .{opts.target_env})) catch |err| switch (err) {
                    error.Unsupported => {
                        try diags.render(&sm, cli.stderr, .{ .format = opts.diag_format, .color = false });
                        try cli.stderr.flush();
                        return error.CompileFailed;
                    },
                    else => |x| return x,
                };
                const path = opts.output orelse return cli.fail("missing -Fo <file>", .{});
                try Io.Dir.cwd().writeFile(cli.io, .{ .sub_path = path, .data = bytes });
                return;
            }
            // -rootsig-define: the macro's root signature for the entry.
            if (opts.rootsig_define) |macro| if (m.entries.items.len == 1) {
                m.entries.items[0].root_signature = try rootSignatureMacroText(cli, arena, opts, input, macro) orelse return error.CompileFailed;
            };
            const bytes = zdxc.dxil.emit.emit(arena, m, profile.?, &diags) catch |err| switch (err) {
                error.Unsupported => {
                    try diags.render(&sm, cli.stderr, .{ .format = opts.diag_format, .color = false });
                    try cli.stderr.flush();
                    return error.CompileFailed;
                },
                else => |x| return x,
            };
            const path = opts.output orelse return cli.fail("missing -Fo <file>", .{});
            try Io.Dir.cwd().writeFile(cli.io, .{ .sub_path = path, .data = bytes });
            if (opts.rootsig_output) |rs_path| {
                const text = (if (m.entries.items.len == 1) m.entries.items[0].root_signature else null) orelse return cli.fail("-Frs: the shader has no root signature", .{});
                var d: zdxc.dxil.rootsig.Diagnostic = .{};
                const blob = try zdxc.dxil.rootsig.compileWithOptions(arena, text, .{ .version = if (m.rootsig_version == .v1_0) .v1_0 else .v1_1, .flags = .global }, &d) orelse return cli.fail("root signature error - {s}", .{d.message()});
                try Io.Dir.cwd().writeFile(cli.io, .{ .sub_path = rs_path, .data = try rootSignatureContainer(arena, blob) });
            }
            return;
        }
        return cli.fail("code generation is not implemented yet: the input was checked but no output was written (use -zdxc-empty for a placeholder shader)", .{});
    }

    const prof = profile orelse return cli.fail("missing -T <profile>", .{});
    if (!opts.empty) return cli.fail("compiling HLSL is not implemented yet (use -P or -zdxc-empty)", .{});
    if (prof.kind != .compute) return cli.fail("-zdxc-empty supports compute profiles only", .{});

    const bytes = if (opts.spirv)
        try zdxc.spirv.builder.buildEmptyCompute(arena, .{ .entry = opts.entry, .num_threads = .{ 1, 1, 1 } })
    else
        try shader.buildEmptyCompute(arena, .{ .entry = opts.entry, .profile = prof, .num_threads = .{ 1, 1, 1 } });

    const out = opts.output orelse return cli.fail("missing -Fo <file>", .{});
    try Io.Dir.cwd().writeFile(cli.io, .{ .sub_path = out, .data = bytes });
}

/// The text of the root signature macro `macro` defines in `input` (its
/// string literals concatenated), or null after reporting an error.
fn rootSignatureMacroText(cli: Cli, arena: std.mem.Allocator, opts: Options, input: []const u8, macro: []const u8) !?[]const u8 {
    const text = try Io.Dir.cwd().readFileAlloc(cli.io, input, arena, .limited(256 << 20));
    var disk: front.source.DiskFs = .{ .io = cli.io };
    var sm = front.source.SourceManager.init(arena, disk.fileSystem());
    var diags = zdxc.Diagnostics.init(arena);
    var pp = front.preproc.Preprocessor.init(arena, &sm, &diags, .{
        .defines = opts.defines.items,
        .include_dirs = opts.include_dirs.items,
        .stage = 6,
    });
    // Expand the macro after a marker at the end of the file.
    const marker = "__zdxc_root_signature__";
    try pp.enterMainText(input, try std.mem.concat(arena, u8, &.{ text, "\n" ++ marker ++ " ", macro, "\n" }));
    var parts: std.ArrayList(u8) = .empty;
    var seen = false;
    var any = false;
    while (true) {
        const t = try pp.next();
        if (t.kind == .eof) break;
        if (!seen) {
            seen = t.kind == .identifier and std.mem.eql(u8, t.text, marker);
            continue;
        }
        if (t.kind != .string) {
            _ = diags.report(.{ .severity = .@"error", .loc = t.loc }, "root signature macro '{s}' must expand to string literals", .{macro});
            break;
        }
        any = true;
        try parts.appendSlice(arena, try zdxc.ir.lower.stringContents(arena, t.text));
    }
    if (!any and !diags.hasErrors()) _ = diags.report(.{ .severity = .@"error", .loc = .none }, "root signature macro '{s}' is not defined", .{macro});
    if (diags.hasErrors()) {
        try diags.render(&sm, cli.stderr, .{ .format = opts.diag_format, .color = false });
        try cli.stderr.flush();
        return null;
    }
    return parts.items;
}

fn compileRootSignatureMacro(cli: Cli, arena: std.mem.Allocator, opts: Options, input: []const u8, macro: []const u8, version: zdxc.dxil.rootsig.Version, flags: zdxc.dxil.rootsig.CompilationFlags) !?[]const u8 {
    const text = try rootSignatureMacroText(cli, arena, opts, input, macro) orelse return null;
    var d: zdxc.dxil.rootsig.Diagnostic = .{};
    return try zdxc.dxil.rootsig.compileWithOptions(arena, text, .{ .version = version, .flags = flags }, &d) orelse {
        try cli.stderr.print("{s}: error: root signature error - {s}\n", .{ input, d.message() });
        try cli.stderr.flush();
        return null;
    };
}

/// A container holding only the root signature (RTS0) part.
fn rootSignatureContainer(arena: std.mem.Allocator, blob: []const u8) ![]u8 {
    return zdxc.dxil.container.assemble(arena, &.{.{ .fourcc = zdxc.dxil.container.fourcc("RTS0"), .data = blob }});
}
