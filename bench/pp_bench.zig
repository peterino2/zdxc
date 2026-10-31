//! Preprocessor benchmark: lexes / preprocesses a set of files in-process
//! and reports the best-of-N wall time and throughput.
//!
//! Usage: pp_bench [-mode lex|pp|print] [-iters N] <file-list.txt>
//! The file list has one path per line. File contents are read once and
//! served from memory, so disk I/O is excluded from the timings.

const std = @import("std");
const Io = std.Io;
const zdxc = @import("zdxc");
const front = zdxc.front;

const Mode = enum { lex, load, pp, print };

/// Serves each path from memory after the first read.
const CachedFs = struct {
    io: Io,
    gpa: std.mem.Allocator,
    files: std.StringHashMapUnmanaged(?[]const u8) = .empty,

    fn fileSystem(c: *CachedFs) front.source.FileSystem {
        return .{ .ctx = c, .readFn = readImpl };
    }

    fn readImpl(ctx: *anyopaque, _: std.mem.Allocator, path: []const u8) ?[]const u8 {
        const c: *CachedFs = @ptrCast(@alignCast(ctx));
        const gop = c.files.getOrPut(c.gpa, path) catch return null;
        if (!gop.found_existing) {
            gop.key_ptr.* = c.gpa.dupe(u8, path) catch return null;
            gop.value_ptr.* = Io.Dir.cwd().readFileAlloc(c.io, path, c.gpa, .limited(256 << 20)) catch null;
        }
        return gop.value_ptr.*;
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var mode: Mode = .pp;
    var iters: usize = 5;
    var list_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-mode")) {
            i += 1;
            mode = std.meta.stringToEnum(Mode, args[i]) orelse return error.BadMode;
        } else if (std.mem.eql(u8, args[i], "-iters")) {
            i += 1;
            iters = try std.fmt.parseInt(usize, args[i], 10);
        } else list_path = args[i];
    }

    const list = try Io.Dir.cwd().readFileAlloc(io, list_path orelse return error.MissingFileList, arena, .limited(64 << 20));
    var paths: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, list, '\n');
    while (it.next()) |p| try paths.append(arena, p);

    var cfs: CachedFs = .{ .io = io, .gpa = gpa };
    var total_bytes: usize = 0;
    for (paths.items) |p| {
        if (CachedFs.readImpl(&cfs, gpa, p)) |text| total_bytes += text.len;
    }

    var best: u64 = std.math.maxInt(u64);
    var checksum: u64 = 0;
    for (0..iters) |_| {
        const start = Io.Timestamp.now(io, .awake);
        checksum = 0;
        for (paths.items) |p| checksum +%= try runOne(gpa, &cfs, p, mode);
        const ns: u64 = @intCast(start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds);
        best = @min(best, ns);
    }

    var buf: [256]u8 = undefined;
    var w = Io.File.Writer.init(.stdout(), io, &buf);
    const mb = @as(f64, @floatFromInt(total_bytes)) / (1024.0 * 1024.0);
    const secs = @as(f64, @floatFromInt(best)) / 1e9;
    try w.interface.print("{s}: {d} files, {d:.1} MB, best {d:.2} ms, {d:.0} MB/s (checksum {d})\n", .{
        @tagName(mode), paths.items.len, mb, secs * 1000.0, mb / secs, checksum,
    });
    try w.interface.flush();
}

fn runOne(gpa: std.mem.Allocator, cfs: *CachedFs, path: []const u8, mode: Mode) !u64 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (mode == .lex) {
        const text = CachedFs.readImpl(cfs, gpa, path) orelse return 0;
        var lx = front.lexer.Lexer.init(text, 0);
        var n: u64 = 0;
        while (lx.next().kind != .eof) n += 1;
        return n;
    }

    var sm = front.source.SourceManager.init(arena, cfs.fileSystem());
    if (mode == .load) {
        const id = try sm.load(path) orelse return 0;
        return sm.file(id).line_starts.len;
    }
    var diags = zdxc.Diagnostics.init(arena);
    var pp = front.preproc.Preprocessor.init(arena, &sm, &diags, .{});
    if (!try pp.enterMainFile(path)) return 0;
    if (mode == .print) {
        var out: Io.Writer.Allocating = .init(arena);
        try front.pp_print.print(&pp, &out.writer);
        return out.written().len;
    }
    var n: u64 = 0;
    while ((try pp.next()).kind != .eof) n += 1;
    return n;
}
