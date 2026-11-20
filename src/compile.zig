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
    /// Set by `compile`: the input when `source` is given and the arguments
    /// name none (not parsed as an argument).
    main_input: ?[]const u8 = null,
};

pub const Status = enum(u8) {
    ok = 0,
    /// Bad options, or an input that cannot be read (dxc's exit code 1).
    failed = 1,
    /// Errors in the source (dxc's exit code 5).
    compile_failed = 5,
};

/// A file the input depends on: `path` as read, or for an include that
/// was not found (`missing`), as spelled.
pub const Dependency = front.preproc.Dependency;

pub const Result = struct {
    status: Status = .ok,
    /// The DXIL container or SPIR-V module, and its -Fo name.
    object: ?[]const u8 = null,
    object_name: ?[]const u8 = null,
    /// The root signature container (-Frs) and its name.
    root_signature: ?[]const u8 = null,
    root_signature_name: ?[]const u8 = null,
    /// DXIL with -Zi -Fd: the PDB and its name.
    pdb: ?[]const u8 = null,
    pdb_name: ?[]const u8 = null,
    /// DXIL: the shader's reflection (dxil/reflect.zig), for the DXC
    /// drop-in's DXC_OUT_REFLECTION.
    reflection: ?[]const u8 = null,
    /// Preprocessed source (-P) and its -Fi name.
    preprocessed: ?[]const u8 = null,
    preprocessed_name: ?[]const u8 = null,
    /// The files the compilation depends on: the main file first, then
    /// each #include once, in the order first included (with any leading
    /// "./" removed); the same list as -M's rule. An include that was not
    /// found is listed as spelled, with `missing` set, so a watcher can
    /// rebuild when it appears. Compiled-in headers are not files and are
    /// left out. Filled whenever the input was preprocessed, also after
    /// errors, so a build that failed still knows which files to watch.
    dependencies: []const Dependency = &.{},
    /// -M, -MD, -MF: the dependencies as a make rule (as dxc writes it),
    /// and its -MF / -MD name; with -M alone, no name (the command line
    /// prints it). These options preprocess only: there is no object. As in
    /// dxc, includes that were not found are listed as spelled, and the
    /// rule is given after preprocessing errors too (status compile_failed).
    dependency_rule: ?[]const u8 = null,
    dependency_rule_name: ?[]const u8 = null,
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
        // (An empty name counts as none.)
        const given = if (req.source_name) |n| (if (n.len > 0) n else null) else null;
        const name = given orelse if (inputs.len > 0) inputs[inputs.len - 1] else "hlsl.hlsl";
        overlay.name = name;
        overlay.text = text;
        // With no input among the arguments, the name is the input. It is
        // not parsed as an argument: Unreal names its sources by virtual
        // path, and "/Engine/Private/X.usf" would be /E (the entry point)
        // with the value "ngine/Private/X.usf".
        if (inputs.len == 0) r.main_input = name;
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
    /// -M (or -MD / -MF, which imply it): list the dependencies instead of
    /// compiling. -MD names the list after the input, -MF names it.
    dump_deps: bool = false,
    write_deps: bool = false,
    deps_output: ?[]const u8 = null,
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
    /// -zdxc-debug: positions and variables in the IR.
    debug: zdxc.ir.ir.DebugLevel = .none,
    /// -Zi, and -fspv-debug (which replaces what -Zi turns on).
    zi: bool = false,
    /// -Fd and -Qembed_debug (DXIL).
    pdb_output: ?[]const u8 = null,
    embed_debug: bool = false,
    spv_debug: ?struct { file: bool = false, source: bool = false, line: bool = false, tool: bool = false, rich: bool = false } = null,
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
                .zdxc_debug => opts.debug = .full,
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
                    .dump_dependencies => opts.dump_deps = true,
                    .write_dependencies => {
                        opts.dump_deps = true;
                        opts.write_deps = true;
                    },
                    .write_dependencies_to => {
                        opts.dump_deps = true;
                        opts.deps_output = v;
                    },
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
                    // Epic's DXC fork, which Unreal's ShaderConductor uses.
                    .fvk_ue5_layout => opts.vk.ue5_layout = true,
                    .fspv_support_precise_outputs => opts.vk.precise_outputs = true,
                    .fspv_fusemuladd => opts.vk.fuse_mul_add = true,
                    .fspv_force_subpass_image_depth_false => opts.vk.subpass_depth_false = true,
                    .fspv_no_scalar_block_layout => opts.vk.no_scalar_block_layout = true,
                    // Epic's DXC passes this to spirv-opt, whose dead code
                    // passes would otherwise drop unused fragment inputs;
                    // zdxc never removes interface variables.
                    .fspv_preserve_storage_input => {},
                    .fspv_svposition_implicit_invariant => opts.vk.position_invariant = true,
                    // zdxc compiles arrays of RW / append / consume
                    // structured buffers with or without it.
                    .fvk_allow_rwstructuredbuffer_arrays => {},
                    .fspv_entrypoint_name_EQ => opts.vk.entry_name = v,
                    .fspv_extension_EQ => try opts.vk.extensions.append(arena, v),
                    .fspv_reflect => opts.vk.reflect = true,
                    ._SLASH_Zi => opts.zi = true,
                    .Fd => opts.pdb_output = v,
                    .Qembed_debug => opts.embed_debug = true,
                    .fspv_debug_EQ => {
                        if (opts.spv_debug == null) opts.spv_debug = .{};
                        const d = &opts.spv_debug.?;
                        if (std.mem.eql(u8, v, "file")) {
                            d.file = true;
                        } else if (std.mem.eql(u8, v, "source")) {
                            d.file = true;
                            d.source = true;
                        } else if (std.mem.eql(u8, v, "line")) {
                            d.file = true;
                            d.source = true;
                            d.line = true;
                        } else if (std.mem.eql(u8, v, "tool")) {
                            d.tool = true;
                        } else if (std.mem.eql(u8, v, "vulkan") or std.mem.eql(u8, v, "vulkan-with-source")) {
                            // NonSemantic.Shader.DebugInfo.100.
                            d.file = true;
                            d.source = v.len > 6;
                            d.line = true;
                            d.rich = true;
                        } else if (std.mem.eql(u8, v, "rich") or std.mem.eql(u8, v, "rich-with-source")) {
                            return ctx.fail("'-fspv-debug={s}' (OpenCL.DebugInfo.100) is not supported by zdxc; use -fspv-debug=vulkan-with-source", .{v});
                        } else return ctx.fail("unknown SPIR-V debug info control parameter: {s}", .{v});
                    },
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
    // (Epic's DXC runs its fused multiply-add pass only when optimizing.)
    if (opts.opt_level == .od or opts.opt_level == .o0) opts.vk.fuse_mul_add = false;
    if (opts.spv_debug != null and !opts.spirv) return ctx.fail("-fspv-debug needs -spirv", .{});
    if ((opts.pdb_output != null or opts.embed_debug) and (!opts.zi or opts.spirv)) return ctx.fail("-Fd and -Qembed_debug need -Zi and a DXIL target", .{});
    if (opts.zi) {
        if (opts.spirv) {
            // (As dxc: every category, unless -fspv-debug picks.)
            if (opts.spv_debug == null) opts.spv_debug = .{ .file = true, .source = true, .line = true, .tool = true };
        } else opts.debug = .full;
    }
    if (opts.spv_debug) |d| if (d.line) {
        opts.debug = .full;
    };
    if (opts.row_major and opts.col_major) return ctx.fail("Cannot specify /Zpr and /Zpc together, use /? to get usage information", .{});
    // Like dxc, the last input wins (dxc reads getLastArgValue(OPT_INPUT)).
    if (parsed.inputs.len > 0) opts.input = parsed.inputs[parsed.inputs.len - 1] else if (ctx.req.main_input) |m| opts.input = m;

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

    const target = try Target.parse(ctx, opts.profile);

    // -P, -M / -MD / -MF: preprocess only, for any target (as dxc).
    if (opts.preprocess or opts.dump_deps) return preprocessOnly(ctx, arena, opts, target);

    const profile: ?shader.Profile = switch (target) {
        .none => null,
        .shader => |p| p,
        .root_signature => |v| return compileRootSignatureTarget(ctx, arena, opts, v),
    };

    // The front end: everything except the development modes that work on
    // containers or raw tokens.
    if (!opts.empty) {
        const input = opts.input orelse return ctx.fail("no input file", .{});
        const fe = try FrontEnd.create(ctx, arena, opts, target, .{});
        const sm = &fe.sm;
        const diags = &fe.diags;
        const pp = &fe.pp;
        var module: ?zdxc.ir.ir.Module = null;
        // -rootsig-define: the macro's root signature text, if any.
        var define_rootsig: ?[]const u8 = null;
        const zp = stats.begin(.preprocess);
        const opened = try pp.enterMainFile(input);
        if (opened) {
            var parser = try front.parser.Parser.fromPreprocessor(arena, diags, pp);
            zp.end();
            // The parser has read the whole input.
            ctx.result.dependencies = try dependencyList(arena, pp.deps.items);
            // -rootsig-define: the macro as defined at the end of the input
            // (not defined, or #undef'd: no root signature from it, as dxc).
            // SPIR-V has no root signature: dxc ignores the option there.
            if (opts.rootsig_define) |macro| if (!opts.spirv) {
                define_rootsig = try rootSignatureMacroText(arena, pp, macro, false);
            };
            const zparse = stats.begin(.parse);
            const tu = try parser.parseTranslationUnit();
            zparse.end();
            if (opts.dump_ast) try front.ast_dump.dumpUnit(ctx.stdout, tu);
            if (!opts.parse) {
                const is_lib = if (profile) |p| p.kind == .library else true;
                var sema = try zdxc.sema.Sema.init(arena, diags, .{
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
                    module = zdxc.ir.lower.lowerUnit(arena, &sema, .{ .entry = opts.entry, .stage = stage, .debug = opts.debug }) catch |e| switch (e) {
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
                            const v = rootSignatureVersion(rv) orelse return ctx.fail("unknown root signature version '{s}'", .{rv});
                            if (v == .v1_0) mm.rootsig_version = .v1_0;
                        }
                    }
                }
            }
        }
        try fe.render(ctx, opts);
        // An unreadable input is an I/O error, as in dxc.
        if (!opened) return error.Fatal;
        if (diags.hasErrors()) return error.CompileFailed;
        if (opts.parse or opts.sema) return;
        if (profile == null) return ctx.fail("missing -T <profile>", .{});
        if (module) |*m| {
            const zo = stats.begin(.ir_opt);
            zdxc.ir.ir.verify(m);
            try zdxc.ir.opt.run(arena, m);
            zdxc.ir.ir.verify(m);
            zo.end();
            const zv = stats.begin(.spirv);
            defer if (opts.spirv) zv.end();
            if (opts.spirv) {
                try zdxc.ir.inline_calls.runResourceReturns(m);
                zdxc.ir.split_resources.run(arena, m, diags) catch |err| switch (err) {
                    error.Unsupported => {
                        try diags.render(sm, ctx.stderr, .{ .format = opts.diag_format, .color = false, .unplaced = if (ctx.req.place_unplaced) opts.input else null });
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
                zdxc.ir.ir.verify(m);
            }
            if (opts.dump_ir) {
                try zdxc.ir.ir.dumpWith(m, ctx.stdout, if (m.debug != .none) sm else null);
                return;
            }
            if (opts.spirv) {
                const dbg: ?zdxc.spirv.emit.Debug = if (opts.spv_debug) |d| .{
                    .sm = sm,
                    .main_file = pp.main_file.?,
                    .file = d.file,
                    .text = d.source,
                    .line = d.line,
                    .processed = if (d.tool) &.{"zdxc-version: " ++ zdxc.version} else &.{},
                    .rich = d.rich,
                    .signature = "zdxc " ++ zdxc.version,
                    .args = if (d.rich) try std.mem.join(arena, " ", ctx.req.args) else "",
                } else null;
                const bytes = zdxc.spirv.emit.emitDebug(arena, m, diags, zdxc.spirv.emit.TargetEnv.parse(opts.target_env) orelse return ctx.fail("unknown SPIR-V target environment '{s}'", .{opts.target_env}), dbg) catch |err| switch (err) {
                    error.Unsupported => {
                        try diags.render(sm, ctx.stderr, .{ .format = opts.diag_format, .color = false, .unplaced = if (ctx.req.place_unplaced) opts.input else null });
                        return error.CompileFailed;
                    },
                    else => |x| return x,
                };
                try ctx.needOutput(opts);
                ctx.result.object = bytes;
                return;
            }
            // -rootsig-define: the macro's root signature for the entry.
            if (define_rootsig) |text| if (m.entries.items.len == 1 and text.len > 0) {
                m.entries.items[0].root_signature = text;
            };
            if (zdxc.dxil.exp.cur.wave != 0 and profile.?.minor >= 6) for (m.entries.items) |*en| {
                if (en.stage == .compute and en.wave_size[0] == 0) en.wave_size = .{ zdxc.dxil.exp.cur.wave, 0, 0 };
            };
            const zd = stats.begin(.dxil);
            // -Zi: the debug module goes into the PDB (-Fd) or, with
            // -Qembed_debug or no -Fd, into the container (as dxc).
            const dxil_dbg: ?zdxc.dxil.emit.Debug = if (opts.zi) .{
                .sm = sm,
                .main_file = pp.main_file.?,
                .args = ctx.req.args,
                .producer = "zdxc " ++ zdxc.version,
                .embed = opts.embed_debug or opts.pdb_output == null,
                .pdb = opts.pdb_output != null,
                .pdb_name = opts.pdb_output,
            } else null;
            const dxil_out = zdxc.dxil.emit.emitDebug(arena, m, profile.?, diags, if (opts.no_opt) .none else if (opts.opt_level == .od) .debug else .full, dxil_dbg) catch |err| switch (err) {
                error.Unsupported => {
                    try diags.render(sm, ctx.stderr, .{ .format = opts.diag_format, .color = false, .unplaced = if (ctx.req.place_unplaced) opts.input else null });
                    return error.CompileFailed;
                },
                else => |x| return x,
            };
            zd.end();
            try ctx.needOutput(opts);
            ctx.result.object = dxil_out.object;
            ctx.result.reflection = dxil_out.reflection;
            ctx.result.pdb = dxil_out.pdb;
            ctx.result.pdb_name = dxil_out.pdb_name;
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

/// What -T names.
const Target = union(enum) {
    /// No -T (allowed for -P and the development modes).
    none,
    shader: shader.Profile,
    /// rootsig_1_0, rootsig_1_1: the root signature in the macro -E names.
    root_signature: zdxc.dxil.rootsig.Version,

    fn parse(ctx: *Ctx, profile: ?[]const u8) !Target {
        const p = profile orelse return .none;
        if (rootSignatureVersion(p)) |v| return .{ .root_signature = v };
        return .{ .shader = shader.Profile.parse(p) orelse return ctx.fail("unknown profile '{s}'", .{p}) };
    }
};

/// rootsig_1_0 or rootsig_1_1 (-T, -force-rootsig-ver).
fn rootSignatureVersion(name: []const u8) ?zdxc.dxil.rootsig.Version {
    if (std.mem.eql(u8, name, "rootsig_1_0")) return .v1_0;
    if (std.mem.eql(u8, name, "rootsig_1_1")) return .v1_1;
    return null;
}

/// The preprocessor, with its source manager and diagnostics, set up from
/// the options: the one front end of compiling, -P / -M, and root
/// signature targets.
const FrontEnd = struct {
    sm: front.source.SourceManager,
    diags: zdxc.Diagnostics,
    pp: front.preproc.Preprocessor,

    const Mode = struct {
        /// -P, -M: see front.preproc.Options.
        preprocess_only: bool = false,
        keep_going: bool = false,
    };

    /// In `arena`: the preprocessor points at the others.
    fn create(ctx: *Ctx, arena: std.mem.Allocator, opts: Options, target: Target, mode: Mode) !*FrontEnd {
        const fe = try arena.create(FrontEnd);
        fe.sm = .init(arena, ctx.fs);
        fe.diags = .init(arena);
        fe.diags.warnings_as_errors = opts.warnings_as_errors;
        fe.diags.suppress_warnings = opts.no_warnings;
        fe.diags.error_limit = opts.error_limit;
        for (opts.disabled_warnings.items) |g| try fe.diags.disableGroup(g);
        // dxc's __SHADER_TARGET_STAGE / _MAJOR / _MINOR: a root signature
        // target is no shader kind (DXIL::ShaderKind::Invalid) and 0.0;
        // without -T, cs_6_0.
        const st: struct { u32, u32, u32 } = switch (target) {
            .none => .{ 5, 6, 0 },
            .shader => |p| .{ @backingInt(p.kind), p.major, p.minor },
            .root_signature => .{ 16, 0, 0 },
        };
        fe.pp = .init(arena, &fe.sm, &fe.diags, .{
            .defines = opts.defines.items,
            .include_dirs = opts.include_dirs.items,
            .stage = st[0],
            .major = st[1],
            .minor = st[2],
            .spirv = opts.spirv,
            .spirv_minor = if (zdxc.spirv.emit.TargetEnv.parse(opts.target_env)) |t| t.minor else 0,
            .enable_16bit = opts.enable_16bit,
            .hlsl_version = opts.hlsl_version,
            .preprocess_only = mode.preprocess_only,
            .keep_going = mode.keep_going,
        });
        return fe;
    }

    /// Prints the diagnostics so far.
    fn render(fe: *FrontEnd, ctx: *Ctx, opts: Options) !void {
        try fe.diags.render(&fe.sm, ctx.stderr, .{ .format = opts.diag_format, .color = opts.color orelse ctx.req.color, .unplaced = if (ctx.req.place_unplaced) opts.input else null });
    }
};

/// -P, -M / -MD / -MF: preprocess only (-P wins). -P gives the
/// preprocessed source; -M the files the input reads, as dxc's make rule:
///
///     <-Fo name, else the input>: main.hlsl \
///      inc/a.hlsli \
///      inc/b.hlsli
///
/// As in dxc, -M preprocesses on after an error (a missing include is
/// listed as spelled), and the rule is given even when it fails.
fn preprocessOnly(ctx: *Ctx, arena: std.mem.Allocator, opts: Options, target: Target) !void {
    const input = opts.input orelse return ctx.fail("no input file", .{});
    const dump_deps = !opts.preprocess;
    // -M needs a target, as in dxc.
    if (dump_deps and target == .none) return ctx.fail("missing -T <profile>", .{});
    const fe = try FrontEnd.create(ctx, arena, opts, target, .{ .preprocess_only = true, .keep_going = dump_deps });
    var out: Io.Writer.Allocating = .init(arena);
    const zp = stats.begin(.preprocess);
    const opened = try fe.pp.enterMainFile(input);
    if (opened) {
        if (dump_deps) {
            while ((try fe.pp.next()).kind != .eof) {}
        } else try front.pp_print.print(&fe.pp, &out.writer);
    }
    zp.end();
    ctx.result.dependencies = try dependencyList(arena, fe.pp.deps.items);
    try fe.render(ctx, opts);
    // An unreadable input is an I/O error, as in dxc.
    if (!opened) return error.Fatal;
    if (dump_deps) {
        var rule: Io.Writer.Allocating = .init(arena);
        try rule.writer.writeAll(opts.output orelse input);
        for (ctx.result.dependencies, 0..) |d, i| try rule.writer.print("{s}{s}", .{ if (i == 0) ": " else " \\\n ", d.path });
        try rule.writer.writeByte('\n');
        ctx.result.dependency_rule = rule.written();
        ctx.result.dependency_rule_name = opts.deps_output orelse if (opts.write_deps) try depFileName(arena, input) else null;
    } else if (!fe.diags.hasErrors()) ctx.result.preprocessed = out.written();
    if (fe.diags.hasErrors()) return error.CompileFailed;
}

/// -T rootsig_1_x: the root signature the macro -E names, alone in a
/// container.
fn compileRootSignatureTarget(ctx: *Ctx, arena: std.mem.Allocator, opts: Options, version: zdxc.dxil.rootsig.Version) !void {
    const input = opts.input orelse return ctx.fail("no input file", .{});
    try ctx.needOutput(opts);
    const fe = try FrontEnd.create(ctx, arena, opts, .{ .root_signature = version }, .{});
    const opened = try fe.pp.enterMainFile(input);
    const text = if (opened) try rootSignatureMacroText(arena, &fe.pp, opts.entry, true) else null;
    ctx.result.dependencies = try dependencyList(arena, fe.pp.deps.items);
    try fe.render(ctx, opts);
    if (!opened) return error.Fatal;
    var d: zdxc.dxil.rootsig.Diagnostic = .{};
    const blob = try zdxc.dxil.rootsig.compileWithOptions(arena, text orelse return error.CompileFailed, .{ .version = version, .flags = .none }, &d) orelse {
        try ctx.stderr.print("{s}: error: root signature error - {s}\n", .{ input, d.message() });
        return error.CompileFailed;
    };
    ctx.result.object = try rootSignatureContainer(arena, blob);
}

/// The text of the root signature macro `macro` as defined at the end of
/// the input (its string literals concatenated), reading the rest of the
/// input first; or null after reporting an error, or when the input has
/// errors. A macro not defined there is an error when `required`, else
/// empty text.
fn rootSignatureMacroText(arena: std.mem.Allocator, pp: *front.preproc.Preprocessor, macro: []const u8, required: bool) !?[]const u8 {
    while ((try pp.next()).kind != .eof) {}
    if (pp.diags.hasErrors()) return null;
    const toks = try pp.expandAtEnd(macro);
    if (toks.len == 0) {
        _ = pp.diags.report(.{ .severity = .@"error", .loc = .none }, "root signature macro '{s}' is not defined", .{macro});
        return null;
    }
    if (!required and toks[0].isIdent(macro)) return "";
    var parts: std.ArrayList(u8) = .empty;
    for (toks) |t| {
        if (t.kind != .string) {
            // At the macro's #define, as dxc reports root signature errors.
            _ = pp.diags.report(.{ .severity = .@"error", .loc = pp.macroLoc(macro), .len = @intCast(macro.len) }, "root signature macro '{s}' must expand to string literals", .{macro});
            return null;
        }
        try parts.appendSlice(arena, try zdxc.ir.lower.stringContents(arena, t.text));
    }
    return parts.items;
}

/// -MD's file, named as dxc names it: everything before the last '.' in
/// the input path (even one in a directory name), then ".d".
fn depFileName(arena: std.mem.Allocator, input: []const u8) ![]const u8 {
    const stem = if (std.mem.lastIndexOfScalar(u8, input, '.')) |dot| input[0..dot] else input;
    return std.mem.concat(arena, u8, &.{ stem, ".d" });
}

/// `deps` each once, without a leading "./" (as clang's dependency
/// collector, which dxc uses).
fn dependencyList(arena: std.mem.Allocator, deps: []const Dependency) ![]const Dependency {
    var list: std.ArrayList(Dependency) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (deps) |d| {
        const p = stripDotSlash(d.path);
        // (The paths live in the source manager or the preprocessor's
        // arena, as long as the result.)
        if ((try seen.getOrPut(arena, p)).found_existing) continue;
        try list.append(arena, .{ .path = p, .missing = d.missing });
    }
    return list.items;
}

fn stripDotSlash(path: []const u8) []const u8 {
    var p = path;
    while (p.len >= 2 and p[0] == '.' and std.fs.path.isSep(p[1])) {
        p = p[2..];
        while (p.len > 0 and std.fs.path.isSep(p[0])) p = p[1..];
    }
    return p;
}

/// A container holding only the root signature (RTS0) part.
fn rootSignatureContainer(arena: std.mem.Allocator, blob: []const u8) ![]u8 {
    return zdxc.dxil.container.assemble(arena, &.{.{ .fourcc = zdxc.dxil.container.fourcc("RTS0"), .data = blob }});
}

const DepTest = struct {
    arena: std.heap.ArenaAllocator = .init(std.testing.allocator),
    mfs: front.source.MemoryFs = .{},
    threaded: Io.Threaded = .init_single_threaded,

    fn deinit(t: *DepTest) void {
        t.arena.deinit();
    }

    fn compile_(t: *DepTest, args: []const []const u8, source: ?[]const u8) !Result {
        const a = t.arena.allocator();
        // (MemoryFs holds the quoted-include spelling: "./" + name.)
        try t.mfs.put(a, "./local.h", "#define LA 1\n");
        try t.mfs.put(a, "inc/common.hlsli", "#ifndef COMMON\n#define COMMON\n#include \"sub/deep.h\"\n#endif\n");
        try t.mfs.put(a, "inc/sub/deep.h", "#define LB 2\n");
        try t.mfs.put(a, "main.hlsl",
            \\#include "local.h"
            \\#include "common.hlsli"
            \\#include "common.hlsli"
            \\#include <dx/linalg.h>
            \\float4 main() : SV_Target { return LA + LB; }
            \\
        );
        return compile(a, .{ .args = args, .source = source, .fs = t.mfs.fileSystem(), .io = t.threaded.io(), .compat_notes = false });
    }

    /// The paths, a missing one as "missing:<spelling>".
    fn paths(t: *DepTest, deps: []const Dependency) ![]const []const u8 {
        const a = t.arena.allocator();
        const out = try a.alloc([]const u8, deps.len);
        for (out, deps) |*o, d| o.* = if (d.missing) try std.mem.concat(a, u8, &.{ "missing:", d.path }) else d.path;
        return out;
    }
};

const expected_deps: []const []const u8 = &.{ "main.hlsl", "local.h", "inc/common.hlsli", "inc/sub/deep.h" };

test "a compilation lists the files it read" {
    var t: DepTest = .{};
    defer t.deinit();
    const r = try t.compile_(&.{ "-T", "ps_6_0", "-I", "inc", "main.hlsl" }, null);
    try std.testing.expectEqual(Status.ok, r.status);
    try std.testing.expect(r.object != null);
    try std.testing.expect(r.dependency_rule == null);
    try std.testing.expectEqualDeep(expected_deps, try t.paths(r.dependencies));
}

test "dependencies with in-memory source and after a compile error" {
    var t: DepTest = .{};
    defer t.deinit();
    const r = try t.compile_(&.{ "-T", "ps_6_0", "-I", "inc" }, "#include \"common.hlsli\"\nfloat4 main() : SV_Target { return nope; }\n");
    try std.testing.expectEqual(Status.compile_failed, r.status);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "hlsl.hlsl", "inc/common.hlsli", "inc/sub/deep.h" }), try t.paths(r.dependencies));
    // A missing include is listed too, so a watcher can rebuild when it
    // appears (preprocessing stops at it: what follows is not listed).
    const m = try t.compile_(&.{ "-T", "ps_6_0", "-I", "inc" }, "#include \"local.h\"\n#include \"gen/missing.h\"\n#include \"common.hlsli\"\n");
    try std.testing.expectEqual(Status.compile_failed, m.status);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "hlsl.hlsl", "local.h", "missing:gen/missing.h" }), try t.paths(m.dependencies));
}

test "a root signature target lists the files it read" {
    var t: DepTest = .{};
    defer t.deinit();
    const src = "#include \"local.h\"\n#include \"common.hlsli\"\n#define RS \"RootFlags(0)\"\n";
    const r = try t.compile_(&.{ "-T", "rootsig_1_1", "-E", "RS", "-I", "inc" }, src);
    try std.testing.expectEqual(Status.ok, r.status);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "hlsl.hlsl", "local.h", "inc/common.hlsli", "inc/sub/deep.h" }), try t.paths(r.dependencies));
    // Also when the macro is not a root signature.
    const bad = try t.compile_(&.{ "-T", "rootsig_1_1", "-E", "RS", "-I", "inc" }, "#include \"local.h\"\n#define RS 1\n");
    try std.testing.expectEqual(Status.compile_failed, bad.status);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "hlsl.hlsl", "local.h" }), try t.paths(bad.dependencies));
}

test "root signature macros are read with the target's predefined macros" {
    var t: DepTest = .{};
    defer t.deinit();
    // A root signature target, as dxc: no shader kind (16), version 0.0;
    // -P preprocesses it rather than compiling.
    const p = try t.compile_(&.{ "-T", "rootsig_1_1", "-E", "RS", "-P" }, "__SHADER_TARGET_STAGE __SHADER_TARGET_MAJOR __SHADER_TARGET_MINOR\n");
    try std.testing.expectEqual(Status.ok, p.status);
    try std.testing.expect(std.mem.indexOf(u8, p.preprocessed.?, "16 0 0") != null);
    const r = try t.compile_(&.{ "-T", "rootsig_1_1", "-E", "RS" }, "#if __SHADER_TARGET_STAGE == 16 && __SHADER_TARGET_MAJOR == 0\n#define RS \"RootFlags(0)\"\n#endif\n");
    try std.testing.expectEqual(Status.ok, r.status);
    // -rootsig-define: the compilation's own preprocessing (ps_6_0).
    const d = try t.compile_(&.{ "-T", "ps_6_0", "-rootsig-define", "RS" },
        \\#if __SHADER_TARGET_STAGE == 0 && __SHADER_TARGET_MAJOR == 6
        \\#define RS "RootFlags(0)"
        \\#else
        \\#define RS 1
        \\#endif
        \\float4 main() : SV_Target { return 0; }
        \\
    );
    try std.testing.expectEqual(Status.ok, d.status);
    const bad = try t.compile_(&.{ "-T", "ps_6_0", "-rootsig-define", "RS" }, "#define RS 1\nfloat4 main() : SV_Target { return 0; }\n");
    try std.testing.expectEqual(Status.compile_failed, bad.status);
    try std.testing.expect(std.mem.indexOf(u8, bad.diagnostics, "must expand to string literals") != null);
    // Reported at the macro's #define, as dxc (not where it is expanded),
    // also through another macro.
    const ind = try t.compile_(&.{ "-T", "rootsig_1_1", "-E", "RS" }, "#define A 1\n#define RS A\n");
    try std.testing.expectEqual(Status.compile_failed, ind.status);
    try std.testing.expect(std.mem.startsWith(u8, ind.diagnostics, "hlsl.hlsl:2:9: error: root signature macro 'RS'"));
    try std.testing.expect(std.mem.indexOf(u8, ind.diagnostics, "expanded from") == null);
    // SPIR-V has no root signature: dxc ignores -rootsig-define there.
    const spv = try t.compile_(&.{ "-T", "ps_6_0", "-spirv", "-rootsig-define", "RS" }, "#define RS 1\nfloat4 main() : SV_Target { return 0; }\n");
    try std.testing.expectEqual(Status.ok, spv.status);
}

test "-M, -MD and -MF give dxc's make rule" {
    var t: DepTest = .{};
    defer t.deinit();
    const rule = "out.dxil: main.hlsl \\\n local.h \\\n inc/common.hlsli \\\n inc/sub/deep.h\n";
    const m = try t.compile_(&.{ "-T", "ps_6_0", "-I", "inc", "-M", "main.hlsl", "-Fo", "out.dxil" }, null);
    try std.testing.expectEqual(Status.ok, m.status);
    try std.testing.expect(m.object == null);
    try std.testing.expectEqualStrings(rule, m.dependency_rule.?);
    try std.testing.expect(m.dependency_rule_name == null);
    try std.testing.expectEqualDeep(expected_deps, try t.paths(m.dependencies));

    const md = try t.compile_(&.{ "-T", "ps_6_0", "-I", "inc", "-MD", "main.hlsl" }, null);
    try std.testing.expectEqualStrings("main.d", md.dependency_rule_name.?);
    try std.testing.expect(std.mem.startsWith(u8, md.dependency_rule.?, "main.hlsl: main.hlsl \\\n"));

    const mf = try t.compile_(&.{ "-T", "ps_6_0", "-I", "inc", "-MF", "deps/main.dep", "main.hlsl" }, null);
    try std.testing.expectEqualStrings("deps/main.dep", mf.dependency_rule_name.?);

    // As dxc: a missing include fails, but preprocessing goes on, and the
    // rule lists it as spelled, as do the dependencies (marked missing).
    const bad = try t.compile_(&.{ "-T", "ps_6_0", "-I", "inc", "-M" }, "#include \"local.h\"\n#include \"missing.h\"\n#error stop\n#include \"missing.h\"\n#include \"common.hlsli\"\n");
    try std.testing.expectEqual(Status.compile_failed, bad.status);
    try std.testing.expectEqualStrings("hlsl.hlsl: hlsl.hlsl \\\n local.h \\\n missing.h \\\n inc/common.hlsli \\\n inc/sub/deep.h\n", bad.dependency_rule.?);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "hlsl.hlsl", "local.h", "missing:missing.h", "inc/common.hlsli", "inc/sub/deep.h" }), try t.paths(bad.dependencies));
    // Only the first error is reported (the rest come after a fatal one).
    try std.testing.expect(std.mem.indexOf(u8, bad.diagnostics, "stop") == null);

    // -M needs a target, as in dxc.
    const no_t = try t.compile_(&.{ "-M", "main.hlsl" }, null);
    try std.testing.expectEqual(Status.failed, no_t.status);
}

test "depFileName and stripDotSlash" {
    const a = std.testing.allocator;
    const d = try depFileName(a, "dir.v2/shader.hlsl");
    defer a.free(d);
    try std.testing.expectEqualStrings("dir.v2/shader.d", d);
    // As dxc: up to the last '.', wherever it is.
    const e = try depFileName(a, "dir.v2/shader");
    defer a.free(e);
    try std.testing.expectEqualStrings("dir.d", e);
    const f = try depFileName(a, "shader");
    defer a.free(f);
    try std.testing.expectEqualStrings("shader.d", f);
    try std.testing.expectEqualStrings("a/b.h", stripDotSlash("././/a/b.h"));
    try std.testing.expectEqualStrings("../a.h", stripDotSlash("../a.h"));
}
