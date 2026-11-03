//! The C API (include/zdxc.h): `compile`, behind C types. Every result
//! owns an arena; nothing is global.

const std = @import("std");
const BumpArena = @import("zdxc").BumpArena;
const zdxc = @import("zdxc");
const compile = zdxc.compile;
const FileSystem = zdxc.front.source.FileSystem;

const ReadFileFn = *const fn (user: ?*anyopaque, path: [*:0]const u8, data: *?[*]const u8, size: *usize) callconv(.c) c_int;

const CompileInfo = extern struct {
    size: u32,
    args: ?[*]const ?[*:0]const u8,
    arg_count: usize,
    source: ?[*]const u8,
    source_size: usize,
    source_name: ?[*:0]const u8,
    read_file: ?ReadFileFn,
    user: ?*anyopaque,
};

const Output = enum(c_int) { object, diagnostics, preprocessed, root_signature, text, _ };

const Result = struct {
    arena: BumpArena,
    status: compile.Status,
    /// Indexed by `Output`; each NUL-terminated.
    outputs: [5]?[:0]const u8,
    names: [5]?[:0]const u8,
};

export fn zdxc_compile(info: ?*const CompileInfo) ?*Result {
    const i = info orelse return null;
    if (i.size < @sizeOf(CompileInfo)) return null;
    var arena: BumpArena = .init(std.heap.smp_allocator);
    const r = compileInto(&arena, i) catch {
        arena.deinit();
        return null;
    };
    r.arena = arena;
    return r;
}

fn compileInto(arena: *BumpArena, i: *const CompileInfo) !*Result {
    const a = arena.allocator();
    const args = try a.alloc([]const u8, i.arg_count);
    for (args, 0..) |*d, k| d.* = std.mem.span(i.args.?[k] orelse return error.InvalidArgument);
    var callback: Callback = undefined;
    var threaded: std.Io.Threaded = .init_single_threaded;
    var req: compile.Request = .{ .args = args, .io = threaded.io() };
    if (i.source) |s| {
        // Callers often pass strlen + 1.
        req.source = std.mem.trimEnd(u8, s[0..i.source_size], "\x00");
    }
    if (i.source_name) |n| req.source_name = std.mem.span(n);
    if (i.read_file) |f| {
        callback = .{ .read_file = f, .user = i.user };
        req.fs = callback.fileSystem();
    }
    const c = try compile.compile(a, req);
    const r = try a.create(Result);
    r.* = .{
        .arena = undefined,
        .status = c.status,
        .outputs = .{
            try dupeZ(a, c.object),
            if (c.diagnostics.len > 0) try a.dupeSentinel(u8, c.diagnostics, 0) else null,
            try dupeZ(a, c.preprocessed),
            try dupeZ(a, c.root_signature),
            if (c.text.len > 0) try a.dupeSentinel(u8, c.text, 0) else null,
        },
        .names = .{
            try dupeZ(a, c.object_name),
            null,
            try dupeZ(a, c.preprocessed_name),
            try dupeZ(a, c.root_signature_name),
            null,
        },
    };
    return r;
}

fn dupeZ(a: std.mem.Allocator, s: ?[]const u8) !?[:0]const u8 {
    return if (s) |t| try a.dupeSentinel(u8, t, 0) else null;
}

/// `zdxc_read_file_fn` as a file system.
const Callback = struct {
    read_file: ReadFileFn,
    user: ?*anyopaque,

    fn fileSystem(c: *Callback) FileSystem {
        return .{ .ctx = c, .readFn = read };
    }

    fn read(ctx: *anyopaque, gpa: std.mem.Allocator, path: []const u8) ?[]const u8 {
        const c: *Callback = @ptrCast(@alignCast(ctx));
        const z = gpa.dupeSentinel(u8, path, 0) catch return null;
        defer gpa.free(z);
        var data: ?[*]const u8 = null;
        var size: usize = 0;
        if (c.read_file(c.user, z, &data, &size) != 0) return null;
        const d = data orelse return if (size == 0) gpa.dupe(u8, "") catch null else null;
        return gpa.dupe(u8, d[0..size]) catch null;
    }
};

export fn zdxc_result_status(r: *const Result) c_int {
    return @intFromEnum(r.status);
}

export fn zdxc_result_output(r: *const Result, which: Output, size: ?*usize) ?*const anyopaque {
    const o = if (@intFromEnum(which) >= 0 and @intFromEnum(which) < r.outputs.len) r.outputs[@intCast(@intFromEnum(which))] else null;
    if (size) |s| s.* = if (o) |b| b.len else 0;
    return if (o) |b| b.ptr else null;
}

export fn zdxc_result_output_name(r: *const Result, which: Output) ?[*:0]const u8 {
    const n = if (@intFromEnum(which) >= 0 and @intFromEnum(which) < r.names.len) r.names[@intCast(@intFromEnum(which))] else null;
    return if (n) |s| s.ptr else null;
}

export fn zdxc_result_free(r: ?*Result) void {
    const res = r orelse return;
    var arena = res.arena;
    arena.deinit();
}

export fn zdxc_version() [*:0]const u8 {
    return zdxc.version;
}
