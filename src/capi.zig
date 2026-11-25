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

const Output = enum(c_int) { object, diagnostics, preprocessed, root_signature, text, dependencies, _ };

const Dependency = struct { path: [:0]const u8, missing: bool };

const Result = struct {
    arena: BumpArena,
    status: compile.Status,
    /// Indexed by `Output`; each NUL-terminated.
    outputs: [6]?[:0]const u8,
    names: [6]?[:0]const u8,
    /// compile.Result.dependencies, with NUL-terminated paths.
    dependencies: []const Dependency,
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
    const deps = try a.alloc(Dependency, c.dependencies.len);
    for (deps, c.dependencies) |*d, s| d.* = .{ .path = try a.dupeSentinel(u8, s.path, 0), .missing = s.missing };
    const r = try a.create(Result);
    r.* = .{
        .arena = undefined,
        .status = c.status,
        .outputs = .{
            try output(a, c.object),
            try output(a, if (c.diagnostics.len > 0) c.diagnostics else null),
            try output(a, c.preprocessed),
            try output(a, c.root_signature),
            try output(a, if (c.text.len > 0) c.text else null),
            try output(a, c.dependency_rule),
        },
        .names = .{
            try dupeZ(a, c.object_name),
            null,
            try dupeZ(a, c.preprocessed_name),
            try dupeZ(a, c.root_signature_name),
            null,
            try dupeZ(a, c.dependency_rule_name),
        },
        .dependencies = deps,
    };
    return r;
}

fn dupeZ(a: std.mem.Allocator, s: ?[]const u8) !?[:0]const u8 {
    return if (s) |t| try a.dupeSentinel(u8, t, 0) else null;
}

/// A 4-byte aligned, NUL-terminated copy of `s`.
fn output(a: std.mem.Allocator, s: ?[]const u8) !?[:0]const u8 {
    const t = s orelse return null;
    const buf = try a.alignedAlloc(u8, .@"4", t.len + 1);
    @memcpy(buf[0..t.len], t);
    buf[t.len] = 0;
    return buf[0..t.len :0];
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

export fn zdxc_result_dependency_count(r: *const Result) usize {
    return r.dependencies.len;
}

export fn zdxc_result_dependency(r: *const Result, index: usize, missing: ?*c_int) ?[*:0]const u8 {
    const d = if (index < r.dependencies.len) r.dependencies[index] else {
        if (missing) |m| m.* = 0;
        return null;
    };
    if (missing) |m| m.* = @intFromBool(d.missing);
    return d.path.ptr;
}

export fn zdxc_result_free(r: ?*Result) void {
    const res = r orelse return;
    var arena = res.arena;
    arena.deinit();
}

export fn zdxc_version() [*:0]const u8 {
    return zdxc.version;
}

test "outputs are 4-byte aligned" {
    const args = [_]?[*:0]const u8{ "-T", "cs_6_0", "-zdxc-empty", "-spirv" };
    const src = "[numthreads(1, 1, 1)] void main() {}";
    for ([_]bool{ false, true }) |spirv| {
        const info: CompileInfo = .{
            .size = @sizeOf(CompileInfo),
            .args = &args,
            .arg_count = if (spirv) 4 else 3,
            .source = src,
            .source_size = src.len,
            .source_name = null,
            .read_file = null,
            .user = null,
        };
        const r = zdxc_compile(&info).?;
        defer zdxc_result_free(r);
        var size: usize = 0;
        const obj = zdxc_result_output(r, .object, &size).?;
        try std.testing.expect(size > 0 and size % 4 == 0);
        try std.testing.expect(@intFromPtr(obj) % 4 == 0);
    }
}
