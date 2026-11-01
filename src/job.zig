//! `--job=<job.json>`: compile every shader a job file lists in one
//! process, on several threads. Starting a process costs more than
//! compiling most shaders, so a build with many shaders is much faster
//! this way than with one zdxc run per shader.
//!
//! The job file:
//!
//!     {
//!       "threads": 8,
//!       "args": ["-HV", "2021"],
//!       "jobs": [
//!         { "args": ["-T", "cs_6_0", "a.hlsl", "-Fo", "a.dxo"] },
//!         { "args": ["-T", "ps_6_0", "-E", "PS", "b.hlsl", "-Fo", "b.dxo"] }
//!       ]
//!     }
//!
//! Each job is a dxc command line. The top-level `args`, then any other
//! options given next to `--job`, come before every job's own. `threads`
//! defaults to the number of CPUs. Paths are relative to the current
//! directory, as on the command line. Each job's output and diagnostics
//! are printed in job order; the exit code is 0 when every job succeeds,
//! else 1 if any job failed on its command line or I/O, else 5.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Compiles one job: `args` is a full command line (argv[0] first). It
/// writes to `stdout` / `stderr` and returns the exit code.
pub const CompileFn = *const fn (io: Io, arena: Allocator, args: []const [:0]const u8, stdout: *Io.Writer, stderr: *Io.Writer) u8;

const JobFile = struct {
    threads: ?u32 = null,
    args: []const []const u8 = &.{},
    jobs: []const struct { args: []const []const u8 },
};

/// The index of `--job=<file>` in `argv`, if any.
pub fn find(argv: []const [:0]const u8) ?usize {
    for (argv[1..], 1..) |a, i| if (std.mem.startsWith(u8, a, "--job=")) return i;
    return null;
}

/// Runs the job file `argv[at]` names; the other arguments apply to every
/// job. Returns the process exit code.
pub fn run(io: Io, arena: Allocator, argv: []const [:0]const u8, at: usize, compile: CompileFn, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    const path = argv[at]["--job=".len..];
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 30)) catch |e| {
        try stderr.print("zdxc: error: cannot read job file '{s}': {s}\n", .{ path, @errorName(e) });
        return 1;
    };
    var scanner = std.json.Scanner.initCompleteInput(arena, text);
    var diag: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diag);
    const file = std.json.parseFromTokenSourceLeaky(JobFile, arena, &scanner, .{}) catch |e| {
        try stderr.print("zdxc: error: {s}:{d}:{d}: invalid job file: {s}\n", .{ path, diag.getLine(), diag.getColumn(), @errorName(e) });
        return 1;
    };

    // argv[0], the file's common args, the command line's, then the job's.
    var common: std.ArrayList([:0]const u8) = .empty;
    try common.append(arena, argv[0]);
    for (file.args) |a| try common.append(arena, try arena.dupeSentinel(u8, a, 0));
    for (argv[1..], 1..) |a, i| if (i != at) try common.append(arena, a);
    const jobs = try arena.alloc([]const [:0]const u8, file.jobs.len);
    for (jobs, file.jobs) |*j, fj| {
        const full = try arena.alloc([:0]const u8, common.items.len + fj.args.len);
        @memcpy(full[0..common.items.len], common.items);
        for (full[common.items.len..], fj.args) |*d, a| d.* = try arena.dupeSentinel(u8, a, 0);
        j.* = full;
    }

    var b: Batch = .{ .io = io, .jobs = jobs, .results = try arena.alloc(Result, jobs.len), .compile = compile, .stdout = stdout, .stderr = stderr };
    @memset(b.results, .{});
    const cpus: u32 = @intCast(std.Thread.getCpuCount() catch 1);
    const nthreads = @max(1, @min(file.threads orelse cpus, jobs.len));
    // The calling thread is one of the workers.
    const threads = try arena.alloc(std.Thread, nthreads - 1);
    var spawned: usize = 0;
    for (threads) |*t| {
        t.* = std.Thread.spawn(.{}, Batch.work, .{&b}) catch break;
        spawned += 1;
    }
    b.work();
    for (threads[0..spawned]) |t| t.join();

    var failed: usize = 0;
    var code: u8 = 0;
    for (b.results) |r| if (r.code != 0) {
        failed += 1;
        if (code != 1) code = r.code;
    };
    if (failed > 0) try stderr.print("zdxc: {d} of {d} jobs failed\n", .{ failed, jobs.len });
    return code;
}

const Result = struct {
    done: bool = false,
    code: u8 = 0,
    out: []u8 = &.{},
    err: []u8 = &.{},
};

const Batch = struct {
    io: Io,
    jobs: []const []const [:0]const u8,
    results: []Result,
    compile: CompileFn,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    next: std.atomic.Value(usize) = .init(0),
    /// Guards `results` and the writers; jobs are printed in order.
    mutex: Io.Mutex = .init,
    printed: usize = 0,

    fn work(b: *Batch) void {
        const gpa = std.heap.smp_allocator;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        while (true) {
            const i = b.next.fetchAdd(1, .monotonic);
            if (i >= b.jobs.len) return;
            _ = arena.reset(.retain_capacity);
            const a = arena.allocator();
            var out: Io.Writer.Allocating = .init(a);
            var err: Io.Writer.Allocating = .init(a);
            const code = b.compile(b.io, a, b.jobs[i], &out.writer, &err.writer);
            // The arena is reused for the next job: keep the output.
            b.finish(i, .{
                .done = true,
                .code = code,
                .out = gpa.dupe(u8, out.written()) catch &.{},
                .err = gpa.dupe(u8, err.written()) catch &.{},
            });
        }
    }

    /// Records job `i` and prints every finished job not yet printed, in
    /// order.
    fn finish(b: *Batch, i: usize, r: Result) void {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        b.results[i] = r;
        while (b.printed < b.results.len and b.results[b.printed].done) : (b.printed += 1) {
            const p = &b.results[b.printed];
            b.stdout.writeAll(p.out) catch {};
            b.stderr.writeAll(p.err) catch {};
            std.heap.smp_allocator.free(p.out);
            std.heap.smp_allocator.free(p.err);
            p.out = &.{};
            p.err = &.{};
        }
        b.stdout.flush() catch {};
        b.stderr.flush() catch {};
    }
};
