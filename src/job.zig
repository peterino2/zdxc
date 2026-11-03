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
//!
//! Two more threads read the jobs' input files ahead of the compiles and
//! write their outputs after them, so the compile threads do not wait on
//! opening files (which Windows, with its on-access scanner, serializes).
//! An output that cannot be written is reported after every job's output,
//! and fails its job.

const std = @import("std");
const BumpArena = @import("zdxc").BumpArena;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const FileSystem = @import("zdxc").front.source.FileSystem;

/// Compiles one job: `args` is a full command line (argv[0] first). It
/// writes to `stdout` / `stderr` and returns the exit code.
pub const CompileFn = *const fn (io: Io, arena: Allocator, args: []const [:0]const u8, ctx: Context, stdout: *Io.Writer, stderr: *Io.Writer) u8;

/// What a run gives a compile besides its command line.
pub const Context = struct {
    /// The input file's text, already read.
    source: ?[]const u8 = null,
    /// Reads the other files (null: from disk).
    fs: ?FileSystem = null,
    /// Where to add the files to write (allocated in the compile's arena),
    /// instead of writing them.
    outputs: ?*Outputs = null,
};

/// A file a job writes.
pub const Output = struct { path: []const u8, bytes: []const u8 };
pub const Outputs = std.ArrayList(Output);

/// The input file a job's command line names, if any.
pub const InputFn = *const fn (arena: Allocator, args: []const [:0]const u8) ?[]const u8;

/// How many jobs the reading thread may get ahead of the compiles.
const read_ahead = 256;
/// The compiles wake the reading thread every this many jobs.
const wake_every = 32;

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
pub fn run(io: Io, arena: Allocator, argv: []const [:0]const u8, at: usize, compile: CompileFn, input: InputFn, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
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

    var b: Batch = .{
        .io = io,
        .jobs = jobs,
        .results = try arena.alloc(Result, jobs.len),
        .sources = try arena.alloc(Source, jobs.len),
        .files = .{ .io = io },
        .compile = compile,
        .input = input,
        .stdout = stdout,
        .stderr = stderr,
    };
    @memset(b.results, .{});
    @memset(b.sources, .{});
    const reader: ?std.Thread = std.Thread.spawn(.{}, Batch.read, .{&b}) catch null;
    b.reading = reader != null;
    const writer: ?std.Thread = std.Thread.spawn(.{}, Batch.write, .{&b}) catch null;
    b.writing = writer != null;
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
    if (reader) |t| t.join();
    if (writer) |t| t.join();
    try stderr.writeAll(b.write_errors.items);

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
    /// Files for the writing thread; owned by smp_allocator.
    writes: []Output = &.{},
};

/// Files the jobs read (headers, mostly), shared by the whole run: each is
/// opened once, rather than once per job and include directory searched.
/// Files that do not exist are remembered too. The text lives until the
/// process exits.
const FileCache = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    files: std.StringHashMapUnmanaged(?[]const u8) = .empty,

    fn fileSystem(c: *FileCache) FileSystem {
        return .{ .ctx = c, .readFn = read };
    }

    fn read(ctx: *anyopaque, _: Allocator, path: []const u8) ?[]const u8 {
        const c: *FileCache = @ptrCast(@alignCast(ctx));
        const gpa = std.heap.smp_allocator;
        {
            c.mutex.lockUncancelable(c.io);
            defer c.mutex.unlock(c.io);
            if (c.files.get(path)) |cached| return cached;
        }
        // Read outside the lock: other jobs keep using the cache meanwhile.
        const text: ?[]const u8 = Io.Dir.cwd().readFileAlloc(c.io, path, gpa, .limited(256 << 20)) catch null;
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        const key = gpa.dupe(u8, path) catch return text;
        const gop = c.files.getOrPut(gpa, key) catch {
            gpa.free(key);
            return text;
        };
        if (gop.found_existing) {
            gpa.free(key);
            if (text) |t| gpa.free(t);
            return gop.value_ptr.*;
        }
        gop.value_ptr.* = text;
        return text;
    }
};

/// A job's input file, as read by the reading thread.
const Source = struct {
    state: std.atomic.Value(State) = .init(.pending),
    /// Valid once `state` is `.read`; owned by smp_allocator.
    text: []u8 = &.{},

    const State = enum(u32) {
        pending,
        read,
        /// No input named, or it could not be read: the compile reads (and
        /// reports) it itself.
        none,
    };
};

const Batch = struct {
    io: Io,
    jobs: []const []const [:0]const u8,
    results: []Result,
    sources: []Source,
    files: FileCache,
    compile: CompileFn,
    input: InputFn,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    /// Whether the reading thread is running (else every source is read by
    /// its compile).
    reading: bool = false,
    /// Whether the writing thread is running (else every compile writes its
    /// own outputs).
    writing: bool = false,
    /// Messages for the outputs the writing thread could not write.
    write_errors: std.ArrayList(u8) = .empty,
    /// `printed`, for the writing thread to wait on: it writes a job's
    /// outputs once the job is printed.
    printed_count: std.atomic.Value(u32) = .init(0),
    next: std.atomic.Value(usize) = .init(0),
    /// Jobs taken by the compiles, for the reading thread to wait on.
    started: std.atomic.Value(u32) = .init(0),
    /// Guards `results` and the writers; jobs are printed in order.
    mutex: Io.Mutex = .init,
    printed: usize = 0,

    /// Reads every job's input file in job order, at most `read_ahead`
    /// jobs ahead of the compiles.
    fn read(b: *Batch) void {
        const gpa = std.heap.smp_allocator;
        var arena: BumpArena = .init(gpa);
        defer arena.deinit();
        for (b.jobs, b.sources, 0..) |args, *s, i| {
            while (true) {
                const started = b.started.load(.acquire);
                if (i < @as(usize, started) + read_ahead) break;
                b.io.futexWaitUncancelable(u32, &b.started.raw, started);
            }
            _ = arena.reset(.retain_capacity);
            const text: ?[]u8 = if (b.input(arena.allocator(), args)) |path|
                Io.Dir.cwd().readFileAlloc(b.io, path, gpa, .limited(256 << 20)) catch null
            else
                null;
            if (text) |t| s.text = t;
            s.state.store(if (text != null) .read else .none, .release);
            b.io.futexWake(Source.State, &s.state.raw, std.math.maxInt(u32));
        }
    }

    /// Writes every job's outputs, in job order, as the jobs are printed.
    fn write(b: *Batch) void {
        const gpa = std.heap.smp_allocator;
        for (b.results, 0..) |*r, i| {
            while (true) {
                const printed = b.printed_count.load(.acquire);
                if (i < printed) break;
                b.io.futexWaitUncancelable(u32, &b.printed_count.raw, printed);
            }
            for (r.writes) |o| {
                Io.Dir.cwd().writeFile(b.io, .{ .sub_path = o.path, .data = o.bytes }) catch |e| {
                    b.write_errors.print(gpa, "zdxc: error: cannot write '{s}': {s}\n", .{ o.path, @errorName(e) }) catch {};
                    r.code = 1;
                };
                gpa.free(o.path);
                gpa.free(o.bytes);
            }
            gpa.free(r.writes);
            r.writes = &.{};
        }
    }

    /// The outputs of a job, copied out of its arena (null if out of
    /// memory: then the job fails).
    fn keep(outputs: []const Output) ?[]Output {
        const gpa = std.heap.smp_allocator;
        const kept = gpa.alloc(Output, outputs.len) catch return null;
        for (kept, outputs, 0..) |*k, o, n| {
            const path = gpa.dupe(u8, o.path) catch null;
            const bytes = if (path != null) gpa.dupe(u8, o.bytes) catch null else null;
            if (bytes == null) {
                if (path) |p| gpa.free(p);
                for (kept[0..n]) |d| {
                    gpa.free(d.path);
                    gpa.free(d.bytes);
                }
                gpa.free(kept);
                return null;
            }
            k.* = .{ .path = path.?, .bytes = bytes.? };
        }
        return kept;
    }

    fn work(b: *Batch) void {
        const gpa = std.heap.smp_allocator;
        var arena: BumpArena = .init(gpa);
        defer arena.deinit();
        while (true) {
            const i = b.next.fetchAdd(1, .monotonic);
            if (i >= b.jobs.len) return;
            if (b.started.fetchAdd(1, .release) % wake_every == wake_every - 1) b.io.futexWake(u32, &b.started.raw, 1);
            _ = arena.reset(.retain_capacity);
            const a = arena.allocator();
            var out: Io.Writer.Allocating = .init(a);
            var err: Io.Writer.Allocating = .init(a);
            const s = &b.sources[i];
            var source: ?[]const u8 = null;
            if (b.reading) {
                while (true) switch (s.state.load(.acquire)) {
                    .pending => b.io.futexWaitUncancelable(Source.State, &s.state.raw, .pending),
                    .read => {
                        source = s.text;
                        break;
                    },
                    .none => break,
                };
            }
            var outputs: Outputs = .empty;
            var code = b.compile(b.io, a, b.jobs[i], .{
                .source = source,
                .fs = b.files.fileSystem(),
                .outputs = if (b.writing) &outputs else null,
            }, &out.writer, &err.writer);
            gpa.free(s.text);
            s.text = &.{};
            // The arena is reused for the next job: keep the output.
            const writes: []Output = keep(outputs.items) orelse writes: {
                err.writer.writeAll("zdxc: error: OutOfMemory\n") catch {};
                code = 1;
                break :writes &.{};
            };
            b.finish(i, .{
                .done = true,
                .code = code,
                .out = gpa.dupe(u8, out.written()) catch &.{},
                .err = gpa.dupe(u8, err.written()) catch &.{},
                .writes = writes,
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
        b.printed_count.store(@intCast(b.printed), .release);
        b.io.futexWake(u32, &b.printed_count.raw, 1);
    }
};
