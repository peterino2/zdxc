//! Time and allocations per compilation stage, for benchmarks. A caller
//! that wants them points `current` at a `Stats` for the thread's
//! compilation; zones anywhere in the compiler then add to it. With no
//! `Stats` (the default) a zone costs one thread-local load.

const std = @import("std");

pub const Stage = enum {
    /// Command-line options and setup.
    args,
    /// Preprocessing and lexing, up to a token array.
    preprocess,
    parse,
    sema,
    lower,
    ir_opt,
    /// DXIL emission, in all (the zones below are inside it).
    dxil,
    /// Lowering the entry's IR to DXIL instructions (inlining every call).
    dxil_lower,
    /// Renumbering a function's instructions into its body.
    dxil_finish,
    promote,
    sccp,
    unroll,
    cse,
    /// Block merging, bypassing and if-conversion (dxil/cfg.zig).
    cfg,
    bitcode,
    container,
    spirv,
    /// Diagnostics rendering and the rest of `compile`.
    other,
};

pub const count = @typeInfo(Stage).@"enum".field_names.len;

/// Sizes of the work, to explain the times.
pub const Counter = enum {
    /// DXIL instructions lowering produced (before any optimization).
    dxil_lowered,
    /// DXIL instructions left in the emitted functions.
    dxil_final,
    /// Times promotion ran.
    promote_runs,
};

pub const counter_count = @typeInfo(Counter).@"enum".field_names.len;

/// What the caller's allocator counters read at a point (the caller's
/// `sample` fills it in).
pub const Sample = struct { calls: u64 = 0, bytes: u64 = 0 };

pub const Stats = struct {
    io: std.Io,
    ns: [count]u64 = @splat(0),
    /// Allocation calls and bytes requested in each stage.
    calls: [count]u64 = @splat(0),
    bytes: [count]u64 = @splat(0),
    /// Times each zone was entered.
    entries: [count]u32 = @splat(0),
    counters: [counter_count]u64 = @splat(0),
    sample: ?*const fn (ctx: ?*anyopaque) Sample = null,
    sample_ctx: ?*anyopaque = null,

    fn read(s: *const Stats) Sample {
        return if (s.sample) |f| f(s.sample_ctx) else .{};
    }
};

pub threadlocal var current: ?*Stats = null;

pub const Zone = struct {
    stage: Stage,
    t0: i96 = 0,
    s0: Sample = .{},
    on: bool = false,

    /// Ends the zone, adding its time and allocations to its stage
    /// (inclusive of zones nested in it).
    pub fn end(z: Zone) void {
        if (!z.on) return;
        const s = current orelse return;
        const t1 = std.Io.Clock.awake.now(s.io).toNanoseconds();
        const s1 = s.read();
        const k = @backingInt(z.stage);
        s.ns[k] += @intCast(t1 - z.t0);
        s.calls[k] += s1.calls - z.s0.calls;
        s.bytes[k] += s1.bytes - z.s0.bytes;
        s.entries[k] += 1;
    }
};

/// Adds `n` to a counter.
pub fn add(c: Counter, n: u64) void {
    if (current) |s| s.counters[@backingInt(c)] += n;
}

pub fn begin(stage: Stage) Zone {
    const s = current orelse return .{ .stage = stage };
    return .{ .stage = stage, .t0 = std.Io.Clock.awake.now(s.io).toNanoseconds(), .s0 = s.read(), .on = true };
}
