const std = @import("std");
const Io = std.Io;
const zdxc = @import("zdxc");
const shader = zdxc.dxil.shader;
const container = zdxc.dxil.container;
const front = zdxc.front;

const usage =
    \\OVERVIEW: zdxc - HLSL 2021 to DXIL / SPIR-V compiler
    \\
    \\USAGE: zdxc [options] <input>
    \\
    \\OPTIONS:
    \\  -T <profile>          Target profile (cs_6_0 .. cs_6_9, vs_, ps_, gs_)
    \\  -E <name>             Entry point name (default: main)
    \\  -Fo <file>            Output object file
    \\  -spirv                Generate SPIR-V
    \\  -D <name>[=<value>]   Define a macro
    \\  -I <dir>              Add an include directory
    \\  -P                    Preprocess only (to -Fi <file>, or stdout)
    \\  -Fi <file>            Output file for -P
    \\  -HV 2021              HLSL version (only 2021 is supported)
    \\  -enable-16bit-types   Enable 16-bit types
    \\  --version             Print version
    \\
    \\DEVELOPMENT (temporary, until the frontend lands):
    \\  -zdxc-empty           Emit an empty shader for -T instead of compiling <input>
    \\  -zdxc-check-hash      Verify the container hash of <input>
    \\  -zdxc-lex             Print the tokens of <input>, one per line (no preprocessing;
    \\                        `#line` lines are skipped)
    \\
;

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

    run(cli, arena, try init.minimal.args.toSlice(arena), &stdout_writer.interface) catch |err| switch (err) {
        error.Fatal => return 1,
        else => return err,
    };
    try stdout_writer.interface.flush();
    return 0;
}

/// Splits `-Dfoo` / `-D foo` style options.
fn optionValue(cli: Cli, args: []const [:0]const u8, i: *usize, flag: []const u8) ![]const u8 {
    const a = args[i.*];
    if (a.len > flag.len) return a[flag.len..];
    i.* += 1;
    if (i.* >= args.len) return cli.fail("missing argument to '{s}'", .{flag});
    return args[i.*];
}

fn parseArgs(cli: Cli, arena: std.mem.Allocator, args: []const [:0]const u8, stdout: *Io.Writer) !?Options {
    var opts: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-T")) {
            opts.profile = try optionValue(cli, args, &i, "-T");
        } else if (std.mem.eql(u8, a, "-E")) {
            opts.entry = try optionValue(cli, args, &i, "-E");
        } else if (std.mem.eql(u8, a, "-Fo")) {
            opts.output = try optionValue(cli, args, &i, "-Fo");
        } else if (std.mem.eql(u8, a, "-Fi")) {
            opts.pp_output = try optionValue(cli, args, &i, "-Fi");
        } else if (std.mem.startsWith(u8, a, "-D")) {
            const v = try optionValue(cli, args, &i, "-D");
            if (std.mem.indexOfScalar(u8, v, '=')) |eq| {
                try opts.defines.append(arena, .{ .name = v[0..eq], .value = v[eq + 1 ..] });
            } else try opts.defines.append(arena, .{ .name = v });
        } else if (std.mem.startsWith(u8, a, "-I")) {
            try opts.include_dirs.append(arena, try optionValue(cli, args, &i, "-I"));
        } else if (std.mem.eql(u8, a, "-HV")) {
            const v = try optionValue(cli, args, &i, "-HV");
            if (!std.mem.eql(u8, v, "2021")) return cli.fail("HLSL version {s} is not supported; zdxc implements HLSL 2021 only", .{v});
        } else if (std.mem.eql(u8, a, "-P")) {
            opts.preprocess = true;
        } else if (std.mem.eql(u8, a, "-spirv")) {
            opts.spirv = true;
        } else if (std.mem.eql(u8, a, "-enable-16bit-types")) {
            opts.enable_16bit = true;
        } else if (std.mem.eql(u8, a, "-zdxc-empty")) {
            opts.empty = true;
        } else if (std.mem.eql(u8, a, "-zdxc-check-hash")) {
            opts.check_hash = true;
        } else if (std.mem.eql(u8, a, "-zdxc-lex")) {
            opts.lex = true;
        } else if (std.mem.eql(u8, a, "--version")) {
            try stdout.print("zdxc {s}\n", .{zdxc.version});
            return null;
        } else if (std.mem.eql(u8, a, "-help") or std.mem.eql(u8, a, "--help")) {
            try stdout.writeAll(usage);
            return null;
        } else if (a.len > 0 and a[0] == '-') {
            return cli.fail("unknown argument: '{s}'", .{a});
        } else {
            if (opts.input != null) return cli.fail("more than one input file", .{});
            opts.input = a;
        }
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

    if (opts.preprocess) {
        const input = opts.input orelse return cli.fail("no input file", .{});
        var disk: front.source.DiskFs = .{ .io = cli.io };
        var sm = front.source.SourceManager.init(arena, disk.fileSystem());
        var diags = zdxc.Diagnostics.init(arena);
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
        if (try pp.enterMainFile(input)) try front.pp_print.print(&pp, &out.writer);
        try diags.render(&sm, cli.stderr);
        try cli.stderr.flush();
        if (diags.hasErrors()) return error.Fatal;
        if (opts.pp_output) |path| {
            try Io.Dir.cwd().writeFile(cli.io, .{ .sub_path = path, .data = out.written() });
        } else try stdout.writeAll(out.written());
        return;
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
