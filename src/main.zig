const std = @import("std");
const Io = std.Io;
const zdxc = @import("zdxc");
const shader = zdxc.dxil.shader;
const container = zdxc.dxil.container;

const usage =
    \\OVERVIEW: zdxc - HLSL 2021 to DXIL / SPIR-V compiler
    \\
    \\USAGE: zdxc [options] <input>
    \\
    \\OPTIONS:
    \\  -T <profile>        Target profile (cs_6_0 .. cs_6_9, vs_, ps_, gs_)
    \\  -E <name>           Entry point name (default: main)
    \\  -Fo <file>          Output object file
    \\  -spirv              Generate SPIR-V
    \\  --version           Print version
    \\
    \\DEVELOPMENT (temporary, until the frontend lands):
    \\  -zdxc-empty         Emit an empty shader for -T instead of compiling <input>
    \\  -zdxc-check-hash    Verify the container hash of <input>
    \\
;

const Options = struct {
    profile: ?[]const u8 = null,
    entry: []const u8 = "main",
    output: ?[]const u8 = null,
    input: ?[]const u8 = null,
    spirv: bool = false,
    empty: bool = false,
    check_hash: bool = false,
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
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const cli: Cli = .{ .io = io, .stderr = &stderr_writer.interface };

    run(cli, arena, try init.minimal.args.toSlice(arena), &stdout_writer.interface) catch |err| switch (err) {
        error.Fatal => return 1,
        else => return err,
    };
    try stdout_writer.interface.flush();
    return 0;
}

fn run(cli: Cli, arena: std.mem.Allocator, args: []const [:0]const u8, stdout: *Io.Writer) !void {
    var opts: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const next = struct {
            fn get(c: Cli, as: []const [:0]const u8, idx: *usize, name: []const u8) ![]const u8 {
                idx.* += 1;
                if (idx.* >= as.len) return c.fail("missing argument to '{s}'", .{name});
                return as[idx.*];
            }
        }.get;
        if (std.mem.eql(u8, a, "-T")) {
            opts.profile = try next(cli, args, &i, a);
        } else if (std.mem.eql(u8, a, "-E")) {
            opts.entry = try next(cli, args, &i, a);
        } else if (std.mem.eql(u8, a, "-Fo")) {
            opts.output = try next(cli, args, &i, a);
        } else if (std.mem.eql(u8, a, "-spirv")) {
            opts.spirv = true;
        } else if (std.mem.eql(u8, a, "-zdxc-empty")) {
            opts.empty = true;
        } else if (std.mem.eql(u8, a, "-zdxc-check-hash")) {
            opts.check_hash = true;
        } else if (std.mem.eql(u8, a, "--version")) {
            try stdout.print("zdxc {s}\n", .{zdxc.version});
            return;
        } else if (std.mem.eql(u8, a, "-help") or std.mem.eql(u8, a, "--help")) {
            try stdout.writeAll(usage);
            return;
        } else if (a.len > 0 and a[0] == '-') {
            return cli.fail("unknown argument: '{s}'", .{a});
        } else {
            if (opts.input != null) return cli.fail("more than one input file", .{});
            opts.input = a;
        }
    }

    if (opts.check_hash) {
        const path = opts.input orelse return cli.fail("no input file", .{});
        const bytes = try Io.Dir.cwd().readFileAlloc(cli.io, path, arena, .limited(1 << 30));
        var view = container.parse(arena, bytes) catch return cli.fail("{s}: not a DXIL container", .{path});
        _ = &view;
        if (!container.hashMatches(view.bytes)) return cli.fail("{s}: hash mismatch", .{path});
        try stdout.print("{s}: hash ok ({d} parts)\n", .{ path, view.parts.items.len });
        return;
    }

    const profile_str = opts.profile orelse return cli.fail("missing -T <profile>", .{});
    const profile = shader.Profile.parse(profile_str) orelse return cli.fail("unknown profile '{s}'", .{profile_str});

    if (!opts.empty) return cli.fail("compiling HLSL is not implemented yet (use -zdxc-empty)", .{});
    if (profile.kind != .compute) return cli.fail("-zdxc-empty supports compute profiles only", .{});

    const bytes = if (opts.spirv)
        try zdxc.spirv.builder.buildEmptyCompute(arena, .{ .entry = opts.entry, .num_threads = .{ 1, 1, 1 } })
    else
        try shader.buildEmptyCompute(arena, .{ .entry = opts.entry, .profile = profile, .num_threads = .{ 1, 1, 1 } });

    const out = opts.output orelse return cli.fail("missing -Fo <file>", .{});
    try Io.Dir.cwd().writeFile(cli.io, .{ .sub_path = out, .data = bytes });
}
