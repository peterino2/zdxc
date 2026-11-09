//! EXPERIMENT (not for landing): knobs for measuring what the GPU driver's
//! pipeline compile time depends on, set by `-zdxc-exp=<knob>,<knob>,...`.
//!   noopt_flag      set the DisableOptimizations shader flag (bit 0)
//!   wave32, wave64  give compute shaders without [WaveSize] that size
//!   unroll_none     unroll no loops
//!   unroll_marked   unroll only [unroll] loops
//!   nocse           no common subexpression elimination
//!   meld            merge mutually exclusive copies of regions (meld.zig)
//!   meld_log        print what melding merged
//!   meld_any        melding also merges copies inside arms (not only at their top)
//!   meld_nopack     no packing of the phis melding leaves
//!   meld_nohoist    no hoisting of copies out of ifs (only copies at the top of arms)
//!   meld_hoistonly  hoist copies to the top of their arms, merge nothing (its cost alone)
//!   ifconv=N        cfg if-converts arms costing up to N (default 2), math dx.op calls too
//!   meld_noholes    melding merges only copies identical in every block (no holes)
//!   meld_min=N      smallest region (and gain) melding merges (default 64)
//!   meld_debug      print the regions melding considers, and why copies differ
//!   opaque_trip     hide the trip counts of loops that write memory other
//!                   threads can see (measuring only: it changes what the GPU runs)
//!   opaque_trip_all hide every loop's trip count
const std = @import("std");

pub const Unroll = enum { all, marked, none };

pub const Exp = struct {
    noopt_flag: bool = false,
    wave: u32 = 0,
    unroll: Unroll = .all,
    nocse: bool = false,
    meld: bool = false,
    meld_log: bool = false,
    meld_any: bool = false,
    meld_nopack: bool = false,
    meld_nohoist: bool = false,
    meld_hoistonly: bool = false,
    ifconv: u32 = 0,
    meld_noholes: bool = false,
    meld_debug: bool = false,
    opaque_trip: bool = false,
    opaque_trip_all: bool = false,
    meld_min: u32 = 64,

    pub fn parse(s: []const u8) Exp {
        var x: Exp = .{};
        var it = std.mem.tokenizeScalar(u8, s, ',');
        while (it.next()) |k| {
            if (std.mem.eql(u8, k, "noopt_flag")) x.noopt_flag = true else if (std.mem.eql(u8, k, "wave32")) x.wave = 32 else if (std.mem.eql(u8, k, "wave64")) x.wave = 64 else if (std.mem.eql(u8, k, "unroll_none")) x.unroll = .none else if (std.mem.eql(u8, k, "unroll_marked")) x.unroll = .marked else if (std.mem.eql(u8, k, "nocse")) x.nocse = true else if (std.mem.eql(u8, k, "meld")) x.meld = true else if (std.mem.eql(u8, k, "meld_log")) x.meld_log = true else if (std.mem.eql(u8, k, "meld_any")) x.meld_any = true else if (std.mem.eql(u8, k, "meld_nopack")) x.meld_nopack = true else if (std.mem.eql(u8, k, "meld_nohoist")) x.meld_nohoist = true else if (std.mem.eql(u8, k, "meld_hoistonly")) x.meld_hoistonly = true else if (std.mem.startsWith(u8, k, "ifconv=")) x.ifconv = std.fmt.parseInt(u32, k[7..], 10) catch 0 else if (std.mem.eql(u8, k, "meld_noholes")) x.meld_noholes = true else if (std.mem.eql(u8, k, "meld_debug")) x.meld_debug = true else if (std.mem.eql(u8, k, "opaque_trip")) x.opaque_trip = true else if (std.mem.eql(u8, k, "opaque_trip_all")) x.opaque_trip_all = true else if (std.mem.startsWith(u8, k, "meld_min=")) x.meld_min = std.fmt.parseInt(u32, k[9..], 10) catch 64;
        }
        return x;
    }
};

pub var cur: Exp = .{};
