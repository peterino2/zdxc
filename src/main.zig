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
    preprocess: bool = false,
    pp_output: ?[]const u8 = null,
    enable_16bit: bool = false,
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
                    .enable_16bit_types => opts.enable_16bit = true,
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
            .enable_16bit = opts.enable_16bit,
        });
        var out: Io.Writer.Allocating = .init(arena);
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
                    });
                    try sema.checkUnit(tu);
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
