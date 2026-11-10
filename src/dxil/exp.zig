//! EXPERIMENT (not for landing): knobs for measuring what the GPU driver's
//! pipeline compile time depends on, set by `-zdxc-exp=<knob>,<knob>,...`.
//!
//! VALIDATION BUILD: meld, meld_nohoist and opaque_trip are on by default.
//! Knobs only turn things on, so `-zdxc-exp=` cannot turn those off.
//!
//! Shader flags:
//!   noopt_flag       set the DisableOptimizations shader flag (bit 0)
//!   wave32, wave64   give compute shaders without [WaveSize] that size
//!
//! Passes:
//!   unroll_none      unroll no loops
//!   unroll_marked    unroll only [unroll] loops
//!   nocse            no common subexpression elimination
//!   ifconv=N         cfg if-converts arms costing up to N (default 2), math
//!                    dx.op calls too
//!
//! Melding (meld.zig):
//!   meld             merge mutually exclusive copies of regions
//!   meld_any         also merge copies inside arms (not only at their top)
//!   meld_nopack      no packing of the phis melding leaves
//!   meld_nohoist     no hoisting of copies out of ifs (only copies at the
//!                    top of arms)
//!   meld_hoistonly   hoist copies to the top of their arms, merge nothing
//!                    (its cost alone)
//!   meld_noholes     merge only copies identical in every block (no holes)
//!   meld_min=N       smallest region (and gain) melding merges (default 64)
//!   meld_log         print what melding merged
//!   meld_debug       print the regions melding considers, and why copies
//!                    differ
//!
//! Loop trip counts:
//!   opaque_trip      hide the trip counts of loops that write memory other
//!                    threads can see (measuring only: it changes what the
//!                    GPU runs); the unroller leaves those without [unroll]
//!                    rolled, unless they use local arrays
//!   opaque_trip_all  hide every loop's trip count
//!   unroll_writes    with opaque_trip, unroll the loops it hides as any
//!                    other
const std = @import("std");

pub const Unroll = enum { all, marked, none };

pub const Exp = struct {
    // Shader flags
    noopt_flag: bool = false,
    wave: u32 = 0, // 0: no override
    // Passes
    unroll: Unroll = .all,
    nocse: bool = false,
    ifconv: u32 = 0, // 0: cfg's own limit
    // Melding
    meld: bool = true,
    meld_any: bool = false,
    meld_nopack: bool = false,
    meld_nohoist: bool = true,
    meld_hoistonly: bool = false,
    meld_noholes: bool = false,
    meld_min: u32 = 64,
    meld_log: bool = false,
    meld_debug: bool = false,
    // Loop trip counts
    opaque_trip: bool = true,
    opaque_trip_all: bool = false,
    unroll_writes: bool = false,

    /// The knobs that take no value.
    const Knob = enum {
        noopt_flag,
        wave32,
        wave64,
        unroll_none,
        unroll_marked,
        nocse,
        meld,
        meld_any,
        meld_nopack,
        meld_nohoist,
        meld_hoistonly,
        meld_noholes,
        meld_log,
        meld_debug,
        opaque_trip,
        opaque_trip_all,
        unroll_writes,
    };

    /// Parses `-zdxc-exp=`'s comma-separated knobs; unknown ones are ignored.
    pub fn parse(s: []const u8) Exp {
        var x: Exp = .{};
        var it = std.mem.tokenizeScalar(u8, s, ',');
        while (it.next()) |k| {
            if (std.mem.startsWith(u8, k, "ifconv=")) {
                x.ifconv = std.fmt.parseInt(u32, k["ifconv=".len..], 10) catch 0;
                continue;
            }
            if (std.mem.startsWith(u8, k, "meld_min=")) {
                x.meld_min = std.fmt.parseInt(u32, k["meld_min=".len..], 10) catch 64;
                continue;
            }
            switch (std.meta.stringToEnum(Knob, k) orelse continue) {
                .noopt_flag => x.noopt_flag = true,
                .wave32 => x.wave = 32,
                .wave64 => x.wave = 64,
                .unroll_none => x.unroll = .none,
                .unroll_marked => x.unroll = .marked,
                .nocse => x.nocse = true,
                .meld => x.meld = true,
                .meld_any => x.meld_any = true,
                .meld_nopack => x.meld_nopack = true,
                .meld_nohoist => x.meld_nohoist = true,
                .meld_hoistonly => x.meld_hoistonly = true,
                .meld_noholes => x.meld_noholes = true,
                .meld_log => x.meld_log = true,
                .meld_debug => x.meld_debug = true,
                .opaque_trip => x.opaque_trip = true,
                .opaque_trip_all => x.opaque_trip_all = true,
                .unroll_writes => x.unroll_writes = true,
            }
        }
        return x;
    }
};

/// The knobs in effect, set from `-zdxc-exp=` (compile.zig).
pub var cur: Exp = .{};
