//! One compilation, as a library call: a dxc command line in, the outputs
//! and diagnostics out, in memory. The command-line driver and the C API
//! are both built on `compile`; neither the compiler nor this file writes
//! files.

const std = @import("std");
const Io = std.Io;
const zdxc = @import("root.zig");
const shader = zdxc.dxil.shader;
const container = zdxc.dxil.container;
const front = zdxc.front;
const options = zdxc.options;
const FileSystem = front.source.FileSystem;
const stats = zdxc.stats;

pub const Request = struct {
    /// dxc command-line options, without the program name: "-T", "ps_6_0",
    /// "-E", "PS", "shader.hlsl", ...
    args: []const []const u8,
    /// The main file's text. When null, the input file named in `args` is
    /// read through `fs`.
    source: ?[]const u8 = null,
    /// The main file's name in diagnostics when `source` is given. Defaults
    /// to the input file named in `args`, else "hlsl.hlsl" (as in dxc).
    source_name: ?[]const u8 = null,
    /// Reads the input and included files. Null reads them from disk,
    /// relative to the current directory.
    fs: ?FileSystem = null,
    io: Io,
    /// Color diagnostics unless the options say otherwise.
    color: bool = false,
    /// Fail without -Fo, as the command line does (a library caller takes
    /// the object from the result instead).
    require_output: bool = false,
    /// Note options that are accepted but have no effect yet. (The DXC
    /// drop-in leaves them out: its clients read any diagnostic text as a
    /// warning.)
    compat_notes: bool = true,
    /// Diagnostics without a source location (code generation's) name the
    /// main file at 1:1. (The DXC drop-in: Unreal reads only diagnostics
    /// that start with `file:line:col:` as errors, and calls a failure
    /// with none an internal error.)
    place_unplaced: bool = false,
};

pub const Status = enum(u8) {
    ok = 0,
    /// Bad options, or an input that cannot be read (dxc's exit code 1).
    failed = 1,
    /// Errors in the source (dxc's exit code 5).
    compile_failed = 5,
};

pub const Result = struct {
    status: Status = .ok,
    /// The DXIL container or SPIR-V module, and its -Fo name.
    object: ?[]const u8 = null,
    object_name: ?[]const u8 = null,
    /// The root signature container (-Frs) and its name.
    root_signature: ?[]const u8 = null,
    root_signature_name: ?[]const u8 = null,
    /// DXIL: the shader's reflection (dxil/reflect.zig), for the DXC
    /// drop-in's DXC_OUT_REFLECTION.
    reflection: ?[]const u8 = null,
    /// Preprocessed source (-P) and its -Fi name.
    preprocessed: ?[]const u8 = null,
    preprocessed_name: ?[]const u8 = null,
    /// Errors, warnings and notes: what the command line prints on stderr.
    diagnostics: []const u8 = "",
    /// Other text the command line prints on stdout (-help, dumps).
    text: []const u8 = "",
};

/// Runs one compilation. Everything in the result is allocated in `arena`.
/// Only running out of memory fails the call; every other failure is in
/// the result's status and diagnostics.
pub fn compile(arena: std.mem.Allocator, req: Request) error{OutOfMemory}!Result {
    var result: Result = .{};
    var stdout: Io.Writer.Allocating = .init(arena);
    var stderr: Io.Writer.Allocating = .init(arena);
    var disk: front.source.DiskFs = .{ .io = req.io };
    var overlay: Overlay = .{ .base = req.fs orelse disk.fileSystem() };
    var r = req;
    if (req.source) |text| {
        // The main file is the given text, under its name.
        var failure: options.Failure = .{};
        const inputs = if (options.parse(arena, req.args, &failure)) |p| p.inputs else |_| &.{};
        const name = req.source_name orelse if (inputs.len > 0) inputs[inputs.len - 1] else "hlsl.hlsl";
        overlay.name = name;
        overlay.text = text;
        if (inputs.len == 0) {
            const args = try arena.alloc([]const u8, req.args.len + 1);
            @memcpy(args[0..req.args.len], req.args);
            args[req.args.len] = name;
            r.args = args;
        }
    }
    var ctx: Ctx = .{
        .io = req.io,
        .fs = overlay.fileSystem(),
        .req = &r,
        .result = &result,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    run(&ctx, arena) catch |err| switch (err) {
        error.Fatal => result.status = .failed,
        error.CompileFailed => result.status = .compile_failed,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            ctx.stderr.print("zdxc: error: {s}\n", .{@errorName(err)}) catch return error.OutOfMemory;
            result.status = .failed;
        },
    };
    if (result.status != .ok) {
        result.object = null;
        result.reflection = null;
        result.root_signature = null;
        result.preprocessed = null;
    }
    result.diagnostics = stderr.written();
    result.text = stdout.written();
    return result;
}

/// The file system, with the in-memory main file in front of it.
const Overlay = struct {
    base: FileSystem,
    name: ?[]const u8 = null,
    text: []const u8 = "",

    fn fileSystem(o: *Overlay) FileSystem {
        return .{ .ctx = o, .readFn = read };
    }

    fn read(ctx: *anyopaque, gpa: std.mem.Allocator, path: []const u8) ?[]const u8 {
        const o: *Overlay = @ptrCast(@alignCast(ctx));
        if (o.name) |n| if (std.mem.eql(u8, n, path)) return gpa.dupe(u8, o.text) catch null;
        return o.base.read(gpa, path);
    }
};

const Ctx = struct {
    io: Io,
    fs: FileSystem,
    req: *const Request,
    result: *Result,
    stdout: *Io.Writer,
    stderr: *Io.Writer,

    fn fail(ctx: *Ctx, comptime fmt: []const u8, args: anytype) error{Fatal} {
        ctx.stderr.print("zdxc: error: " ++ fmt ++ "\n", args) catch {};
        return error.Fatal;
    }

    fn read(ctx: *Ctx, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
        return ctx.fs.read(arena, path) orelse ctx.fail("cannot open file '{s}'", .{path});
    }

    /// -Fo is required on the command line.
    fn needOutput(ctx: *Ctx, opts: Options) !void {
        if (ctx.req.require_output and opts.output == null) return ctx.fail("missing -Fo <file>", .{});
    }
};

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
    /// -HV: 2021, or 2016-2018 (component-wise `&&`, `||` and `?:`).
    hlsl_version: u16 = 2021,
    row_major: bool = false,
    col_major: bool = false,
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
    /// -zdxc-no-opt: no SPIR-V IR optimizations.
    no_opt: bool = false,
    /// -O0..-O3 / -Od (default -O3, as in dxc).
    opt_level: enum { od, o0, o1, o2, o3 } = .o3,
    /// Accepted options with no effect yet, reported once each.
    ignored: std.ArrayList([]const u8) = .empty,
    /// `--job=<file>`: the command-line driver handles it before compiling.
    job: ?[]const u8 = null,
};

/// Parse a dxc-style command line. Returns null when the command is
/// complete (`-help`, `--version`).
fn parseArgs(ctx: *Ctx, arena: std.mem.Allocator, args: []const []const u8) !?Options {
    var failure: options.Failure = .{};
    const parsed = options.parse(arena, args, &failure) catch |e| switch (e) {
        error.UnknownArgument => return ctx.fail("unknown argument: '{s}'", .{failure.arg}),
        error.MissingArgument => return ctx.fail("argument to '{s}' is missing", .{failure.arg}),
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
                .zdxc_no_opt => opts.no_opt = true,
                .zdxc_exp => zdxc.dxil.exp.cur = zdxc.dxil.exp.Exp.parse(a.value()),
                .job => opts.job = a.value(),
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
                    .unsupported => |why| return ctx.fail("'{s}' is not supported: {s}", .{ a.spelling, why }),
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
                    .hlsl_version => {
                        const n = std.fmt.parseInt(u16, v, 10) catch 0;
                        if (n != 2021 and (n < 2016 or n > 2018)) {
                            return ctx.fail("HLSL version {s} is not supported; zdxc implements HLSL 2016-2018 and 2021", .{v});
                        }
                        opts.hlsl_version = n;
                    },
                    .P => opts.preprocess = true,
                    .spirv => opts.spirv = true,
                    .fspv_target_env_EQ => opts.target_env = v,
                    .enable_16bit_types => opts.enable_16bit = true,
                    .Zpr => opts.row_major = true,
                    .Zpc => opts.col_major = true,
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
                        const shift = std.fmt.parseInt(u32, a.values[0], 10) catch return ctx.fail("invalid {s} shift '{s}'", .{ a.spelling, a.values[0] });
                        const set: ?u32 = if (std.mem.eql(u8, a.values[1], "all")) null else std.fmt.parseInt(u32, a.values[1], 10) catch return ctx.fail("invalid {s} space '{s}'", .{ a.spelling, a.values[1] });
                        try opts.vk.shifts[k].append(arena, .{ .shift = shift, .set = set });
                    },
                    .fvk_bind_globals => opts.vk.bind_globals = .{
                        std.fmt.parseInt(u32, a.values[0], 10) catch return ctx.fail("invalid -fvk-bind-globals binding number: {s}", .{a.values[0]}),
                        std.fmt.parseInt(u32, a.values[1], 10) catch return ctx.fail("invalid -fvk-bind-globals set number: {s}", .{a.values[1]}),
                    },
                    .fvk_bind_register, .vkbr => {
                        const reg = a.values[0];
                        if (reg.len < 2 or std.mem.indexOfScalar(u8, "btsu", reg[0]) == null) return ctx.fail("invalid -fvk-bind-register register '{s}'", .{reg});
                        const num = struct {
                            fn f(c: *Ctx, t: []const u8) !u32 {
                                return std.fmt.parseInt(u32, t, 10) catch c.fail("invalid -fvk-bind-register number '{s}'", .{t});
                            }
                        }.f;
                        try opts.vk.bind_register.append(arena, .{ .class = reg[0], .index = try num(ctx, reg[1..]), .space = try num(ctx, a.values[1]), .binding = try num(ctx, a.values[2]), .set = try num(ctx, a.values[3]) });
                    },
                    .auto_binding_space => {
                        opts.vk.auto_binding_space = std.fmt.parseInt(u32, v, 10) catch return ctx.fail("invalid -auto-binding-space '{s}'", .{v});
                        opts.vk.auto_binding_given = true;
                    },
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
                        if (std.mem.eql(u8, v, "alpha")) opts.vk.alpha_io_order = true else if (!std.mem.eql(u8, v, "decl")) return ctx.fail("unknown -fvk-stage-io-order '{s}'", .{v});
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
                            return ctx.fail("unknown diagnostics format '{s}' (expected clang, msvc or vi)", .{v});
                    },
                    .ferror_limit_EQ => opts.error_limit = std.fmt.parseInt(u32, v, 10) catch
                        return ctx.fail("invalid -ferror-limit value '{s}'", .{v}),
                    .fdiagnostics_color => opts.color = true,
                    .fdiagnostics_color_EQ => opts.color = if (std.mem.eql(u8, v, "always"))
                        true
                    else if (std.mem.eql(u8, v, "never"))
                        false
                    else
                        null,
                    .help, ._help_question, ._help_hidden => {
                        try options.printHelp(ctx.stdout, id == ._help_hidden);
                        return null;
                    },
                    ._version => {
                        try ctx.stdout.print("zdxc {s} (dxc-compatible command line, HLSL 2021)\n", .{zdxc.version});
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
    if (opts.row_major and opts.col_major) return ctx.fail("Cannot specify /Zpr and /Zpc together, use /? to get usage information", .{});
    // Like dxc, the last input wins (dxc reads getLastArgValue(OPT_INPUT)).
    if (parsed.inputs.len > 0) opts.input = parsed.inputs[parsed.inputs.len - 1];

    if (opts.ignored.items.len > 0 and !opts.no_warnings and ctx.req.compat_notes) {
        try ctx.stderr.writeAll("zdxc: note: accepted for compatibility, no effect yet:");
        for (opts.ignored.items) |sp| try ctx.stderr.print(" {s}", .{sp});
        try ctx.stderr.writeByte('\n');
    }
    return opts;
}

fn run(ctx: *Ctx, arena: std.mem.Allocator) !void {
    const za = stats.begin(.args);
    const opts = try parseArgs(ctx, arena, ctx.req.args) orelse return;
    za.end();
    ctx.result.object_name = opts.output;
    ctx.result.root_signature_name = opts.rootsig_output;
    ctx.result.preprocessed_name = opts.pp_output;
    if (opts.job != null) return ctx.fail("--job is a command-line option; it cannot be used inside a job file or the library", .{});

    if (opts.check_hash) {
        const path = opts.input orelse return ctx.fail("no input file", .{});
        const bytes = try ctx.read(arena, path);
        const view = container.parse(arena, bytes) catch return ctx.fail("{s}: not a DXIL container", .{path});
        if (!container.hashMatches(view.bytes)) return ctx.fail("{s}: hash mismatch", .{path});
        try ctx.stdout.print("{s}: hash ok ({d} parts)\n", .{ path, view.parts.items.len });
        return;
    }

    if (opts.lex) {
        const path = opts.input orelse return ctx.fail("no input file", .{});
        const text = try ctx.read(arena, path);
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
            try ctx.stdout.print("{s}\n", .{t.text});
        }
        return;
    }

    // Root signature targets: the root signature in the macro -E names.
    if (opts.profile) |p| if (std.mem.eql(u8, p, "rootsig_1_0") or std.mem.eql(u8, p, "rootsig_1_1")) {
        const input = opts.input orelse return ctx.fail("no input file", .{});
        try ctx.needOutput(opts);
        const version: zdxc.dxil.rootsig.Version = if (std.mem.eql(u8, p, "rootsig_1_0")) .v1_0 else .v1_1;
        const blob = try compileRootSignatureMacro(ctx, arena, opts, input, opts.entry, version, .none) orelse return error.CompileFailed;
        ctx.result.object = try rootSignatureContainer(arena, blob);
        return;
    };

    const profile: ?shader.Profile = if (opts.profile) |p|
        shader.Profile.parse(p) orelse return ctx.fail("unknown profile '{s}'", .{p})
    else
        null;

    // The front end: everything except the development modes that work on
    // containers or raw tokens.
    if (!opts.empty) {
        const input = opts.input orelse return ctx.fail("no input file", .{});
        var sm = front.source.SourceManager.init(arena, ctx.fs);
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
            .hlsl_version = opts.hlsl_version,
        });
        var out: Io.Writer.Allocating = .init(arena);
        var module: ?zdxc.ir.ir.Module = null;
        const zp = stats.begin(.preprocess);
        const opened = try pp.enterMainFile(input);
        if (opened) {
            if (opts.preprocess) {
                try front.pp_print.print(&pp, &out.writer);
                zp.end();
            } else {
                var parser = try front.parser.Parser.fromPreprocessor(arena, &diags, &pp);
                zp.end();
                const zparse = stats.begin(.parse);
                const tu = try parser.parseTranslationUnit();
                zparse.end();
                if (opts.dump_ast) try front.ast_dump.dumpUnit(ctx.stdout, tu);
                if (!opts.parse) {
                    const is_lib = if (profile) |p| p.kind == .library else true;
                    var sema = try zdxc.sema.Sema.init(arena, &diags, .{
                        .entry = if (opts.sema or is_lib) null else opts.entry,
                        .spirv = opts.spirv,
                        .enable_16bit = opts.enable_16bit,
                        .hlsl_version = opts.hlsl_version,
                        .sm_minor = if (profile) |p| p.minor else 10,
                        .library = is_lib,
                        .root = opts.entry,
                        .row_major = opts.row_major,
                    });
                    // About one resolution per expression: reserve rather
                    // than grow, which leaves every old buffer in the arena.
                    const zs = stats.begin(.sema);
                    try sema.resolutions.ensureTotalCapacity(arena, parser.toks.len);
                    try sema.checkUnit(tu);
                    zs.end();
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
                        const zl = stats.begin(.lower);
                        module = zdxc.ir.lower.lowerUnit(arena, &sema, .{ .entry = opts.entry, .stage = stage }) catch |e| switch (e) {
                            error.Unsupported => null,
                            else => |x| return x,
                        };
                        zl.end();
                        if (module) |*mm| {
                            mm.native_16bit = opts.enable_16bit;
                            mm.row_major = opts.row_major;
                            mm.vk = opts.vk;
                            mm.strip_rootsig = opts.strip_rootsig;
                            if (opts.rootsig_ver) |rv| {
                                if (std.mem.eql(u8, rv, "rootsig_1_0")) mm.rootsig_version = .v1_0 else if (!std.mem.eql(u8, rv, "rootsig_1_1")) return ctx.fail("unknown root signature version '{s}'", .{rv});
                            }
                        }
                    }
                }
            }
        }
        const color = opts.color orelse ctx.req.color;
        try diags.render(&sm, ctx.stderr, .{ .format = opts.diag_format, .color = color, .unplaced = if (ctx.req.place_unplaced) opts.input else null });
        // An unreadable input is an I/O error, as in dxc.
        if (!opened) return error.Fatal;
        if (diags.hasErrors()) return error.CompileFailed;
        if (opts.preprocess) {
            ctx.result.preprocessed = out.written();
            return;
        }
        if (opts.parse or opts.sema) return;
        if (profile == null) return ctx.fail("missing -T <profile>", .{});
        if (module) |*m| {
            const zo = stats.begin(.ir_opt);
            try zdxc.ir.opt.run(arena, m);
            zo.end();
            const zv = stats.begin(.spirv);
            defer if (opts.spirv) zv.end();
            if (opts.spirv) {
                try zdxc.ir.inline_calls.runResourceReturns(m);
                zdxc.ir.split_resources.run(arena, m, &diags) catch |err| switch (err) {
                    error.Unsupported => {
                        try diags.render(&sm, ctx.stderr, .{ .format = opts.diag_format, .color = false, .unplaced = if (ctx.req.place_unplaced) opts.input else null });
                        return error.CompileFailed;
                    },
                    else => |x| return x,
                };
                // Legalization and cleanup dxc's SPIR-V gets from its
                // optimizer (skipped for -Od).
                if (!opts.no_opt and opts.opt_level != .od) {
                    try zdxc.ir.inline_calls.run(m);
                    try zdxc.ir.ssa.run(m);
                }
            }
            if (opts.dump_ir) {
                try zdxc.ir.ir.dump(m, ctx.stdout);
                return;
            }
            if (opts.spirv) {
                const bytes = zdxc.spirv.emit.emit(arena, m, &diags, zdxc.spirv.emit.TargetEnv.parse(opts.target_env) orelse return ctx.fail("unknown SPIR-V target environment '{s}'", .{opts.target_env})) catch |err| switch (err) {
                    error.Unsupported => {
                        try diags.render(&sm, ctx.stderr, .{ .format = opts.diag_format, .color = false, .unplaced = if (ctx.req.place_unplaced) opts.input else null });
                        return error.CompileFailed;
                    },
                    else => |x| return x,
                };
                try ctx.needOutput(opts);
                ctx.result.object = bytes;
                return;
            }
            // -rootsig-define: the macro's root signature for the entry.
            if (opts.rootsig_define) |macro| if (m.entries.items.len == 1) {
                // (Not defined, or #undef'd, at the end of the file: no
                // root signature from it, as dxc.)
                const text = try rootSignatureMacroText(ctx, arena, opts, input, macro, false) orelse return error.CompileFailed;
                if (text.len > 0) m.entries.items[0].root_signature = text;
            };
            if (zdxc.dxil.exp.cur.wave != 0 and profile.?.minor >= 6) for (m.entries.items) |*en| {
                if (en.stage == .compute and en.wave_size[0] == 0) en.wave_size = .{ zdxc.dxil.exp.cur.wave, 0, 0 };
            };
            const zd = stats.begin(.dxil);
            const dxil_out = zdxc.dxil.emit.emitWithReflectionAt(arena, m, profile.?, &diags, if (opts.no_opt) .none else if (opts.opt_level == .od) .debug else .full) catch |err| switch (err) {
                error.Unsupported => {
                    try diags.render(&sm, ctx.stderr, .{ .format = opts.diag_format, .color = false, .unplaced = if (ctx.req.place_unplaced) opts.input else null });
                    return error.CompileFailed;
                },
                else => |x| return x,
            };
            zd.end();
            try ctx.needOutput(opts);
            ctx.result.object = dxil_out.object;
            ctx.result.reflection = dxil_out.reflection;
            if (opts.rootsig_output != null) {
                const text = (if (m.entries.items.len == 1) m.entries.items[0].root_signature else null) orelse return ctx.fail("-Frs: the shader has no root signature", .{});
                var d: zdxc.dxil.rootsig.Diagnostic = .{};
                const blob = try zdxc.dxil.rootsig.compileWithOptions(arena, text, .{ .version = if (m.rootsig_version == .v1_0) .v1_0 else .v1_1, .flags = .global }, &d) orelse return ctx.fail("root signature error - {s}", .{d.message()});
                ctx.result.root_signature = try rootSignatureContainer(arena, blob);
            }
            return;
        }
        return ctx.fail("code generation is not implemented yet: the input was checked but no output was written (use -zdxc-empty for a placeholder shader)", .{});
    }

    const prof = profile orelse return ctx.fail("missing -T <profile>", .{});
    if (!opts.empty) return ctx.fail("compiling HLSL is not implemented yet (use -P or -zdxc-empty)", .{});
    if (prof.kind != .compute) return ctx.fail("-zdxc-empty supports compute profiles only", .{});

    const bytes = if (opts.spirv)
        try zdxc.spirv.builder.buildEmptyCompute(arena, .{ .entry = opts.entry, .num_threads = .{ 1, 1, 1 } })
    else
        try shader.buildEmptyCompute(arena, .{ .entry = opts.entry, .profile = prof, .num_threads = .{ 1, 1, 1 } });

    try ctx.needOutput(opts);
    ctx.result.object = bytes;
}

/// The text of the root signature macro `macro` defines in `input` (its
/// string literals concatenated), or null after reporting an error. A
/// macro not defined at the end of `input` is an error when `required`,
/// else empty text.
fn rootSignatureMacroText(ctx: *Ctx, arena: std.mem.Allocator, opts: Options, input: []const u8, macro: []const u8, required: bool) !?[]const u8 {
    const text = try ctx.read(arena, input);
    var sm = front.source.SourceManager.init(arena, ctx.fs);
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
        if (!any and !required and t.kind == .identifier and std.mem.eql(u8, t.text, macro)) return "";
        if (t.kind != .string) {
            _ = diags.report(.{ .severity = .@"error", .loc = t.loc }, "root signature macro '{s}' must expand to string literals", .{macro});
            break;
        }
        any = true;
        try parts.appendSlice(arena, try zdxc.ir.lower.stringContents(arena, t.text));
    }
    if (!any and !diags.hasErrors()) _ = diags.report(.{ .severity = .@"error", .loc = .none }, "root signature macro '{s}' is not defined", .{macro});
    if (diags.hasErrors()) {
        try diags.render(&sm, ctx.stderr, .{ .format = opts.diag_format, .color = false, .unplaced = if (ctx.req.place_unplaced) opts.input else null });
        return null;
    }
    return parts.items;
}

fn compileRootSignatureMacro(ctx: *Ctx, arena: std.mem.Allocator, opts: Options, input: []const u8, macro: []const u8, version: zdxc.dxil.rootsig.Version, flags: zdxc.dxil.rootsig.CompilationFlags) !?[]const u8 {
    const text = try rootSignatureMacroText(ctx, arena, opts, input, macro, true) orelse return null;
    var d: zdxc.dxil.rootsig.Diagnostic = .{};
    return try zdxc.dxil.rootsig.compileWithOptions(arena, text, .{ .version = version, .flags = flags }, &d) orelse {
        try ctx.stderr.print("{s}: error: root signature error - {s}\n", .{ input, d.message() });
        return null;
    };
}

/// A container holding only the root signature (RTS0) part.
fn rootSignatureContainer(arena: std.mem.Allocator, blob: []const u8) ![]u8 {
    return zdxc.dxil.container.assemble(arena, &.{.{ .fourcc = zdxc.dxil.container.fourcc("RTS0"), .data = blob }});
}
