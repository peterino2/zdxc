//! Common subexpression elimination over the dominator tree, as the value
//! numbering of SPIRV-Tools' redundancy-elimination leaves dxc's SPIR-V:
//! a pure instruction equal to one in a block that dominates it (or
//! earlier in its own block) is that one. Equal: the same operation on the
//! same operands (commutative operations' in either order), of the same
//! type. Constants of one type and value are one constant.
//!
//! Unreal's inlined helpers each read the view uniforms, index the same
//! arrays and recompute the same products; left apart, they are a large
//! share of what its spirv-opt then spends its time on.
//!
//! Loads count only from constant buffers (nothing writes them). Wave,
//! quad and derivative operations, whose results depend on which lanes
//! run them, are never merged.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("ir.zig");
const opt = @import("opt.zig");

const Ref = ir.Ref;
const BlockId = ir.BlockId;
const none = std.math.maxInt(u32);

fn successors(a: Allocator, term: ir.Terminator) Allocator.Error![]const BlockId {
    return switch (term) {
        .br => |b| try a.dupe(BlockId, &.{b}),
        .cond_br => |c| try a.dupe(BlockId, &.{ c.then, c.@"else" }),
        .@"switch" => |sw| blk: {
            const out = try a.alloc(BlockId, sw.cases.len + 1);
            out[0] = sw.default;
            for (sw.cases, out[1..]) |c, *o| o.* = c.block;
            break :blk out;
        },
        else => &.{},
    };
}

/// Intrinsics whose value depends on the lanes running them (or on when).
fn lanesDependent(name: []const u8) bool {
    const prefixes = [_][]const u8{ "Wave", "Quad", "ddx", "ddy", "fwidth", "Evaluate", "GetAttributeAtVertex", "Clock", "clock" };
    for (prefixes) |p| if (std.mem.startsWith(u8, name, p)) return true;
    return false;
}

const Key = struct {
    words: std.ArrayList(u32) = .empty,
    a: Allocator,

    fn put(k: *Key, x: u32) !void {
        try k.words.append(k.a, x);
    }
    fn ref(k: *Key, r: Ref) !void {
        try k.put(r.index());
    }
    fn bytes(k: *Key, s: []const u8) !void {
        try k.put(@intCast(s.len));
        for (s) |c| try k.put(c);
    }
};

fn commutative(op: ir.BinaryOp) bool {
    return switch (op) {
        .add, .mul, .bit_and, .bit_or, .bit_xor, .log_and, .log_or => true,
        else => false,
    };
}

/// The key of a pure instruction to merge, or null. Operands are mapped
/// already.
fn keyOf(a: Allocator, f: *const ir.Function, inst: ir.Inst) Allocator.Error!?[]const u8 {
    var k: Key = .{ .a = a };
    try k.put(@intFromEnum(std.meta.activeTag(inst.op)));
    try k.put(inst.ty);
    try k.put(@intFromEnum(inst.ptr));
    switch (inst.op) {
        // (The emitter gives a global's pointer what it needs where it
        // meets it: one in a dominating block.)
        .global => |g| try k.put(g),
        .load => |p| {
            if (f.inst(p).ptr != .cbuffer) return null;
            try k.ref(p);
        },
        .access => |x| {
            try k.ref(x.base);
            for (x.indices) |r| try k.ref(r);
        },
        .binary => |x| {
            try k.put(@intFromEnum(x.op));
            var l = x.lhs;
            var r = x.rhs;
            if (commutative(x.op) and l.index() > r.index()) std.mem.swap(Ref, &l, &r);
            try k.ref(l);
            try k.ref(r);
        },
        .unary => |x| {
            try k.put(@intFromEnum(x.op));
            try k.ref(x.operand);
        },
        .cmp => |x| {
            try k.put(@intFromEnum(x.op));
            var l = x.lhs;
            var r = x.rhs;
            if ((x.op == .eq or x.op == .ne) and l.index() > r.index()) std.mem.swap(Ref, &l, &r);
            try k.ref(l);
            try k.ref(r);
        },
        .convert, .bitcast, .splat => |x| try k.ref(x),
        .extract => |x| {
            try k.ref(x.agg);
            try k.put(x.index);
        },
        .insert => |x| {
            try k.ref(x.agg);
            try k.ref(x.value);
            try k.put(x.index);
        },
        .construct => |xs| for (xs) |r| try k.ref(r),
        .shuffle => |x| {
            try k.ref(x.vec);
            try k.bytes(x.components);
        },
        .select => |x| {
            try k.ref(x.cond);
            try k.ref(x.t);
            try k.ref(x.f);
        },
        .intrinsic => |x| {
            if (lanesDependent(x.name) or !opt.isPureIntrinsic(f, x.name, x.args)) return null;
            try k.bytes(x.name);
            for (x.args) |r| try k.ref(r);
        },
        else => return null,
    }
    return std.mem.sliceAsBytes(k.words.items);
}

pub fn run(a: Allocator, f: *ir.Function) Allocator.Error!bool {
    const nb = f.blocks.items.len;
    const ni = f.insts.items.len;
    if (nb == 0) return false;

    // Reverse postorder of the reachable blocks.
    const order = try a.alloc(u32, nb);
    @memset(order, none);
    var rpo: std.ArrayList(u32) = .empty;
    {
        const visited = try a.alloc(bool, nb);
        @memset(visited, false);
        var post: std.ArrayList(u32) = .empty;
        var stack: std.ArrayList(struct { b: u32, next: usize }) = .empty;
        try stack.append(a, .{ .b = 0, .next = 0 });
        visited[0] = true;
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const succ = try successors(a, f.blocks.items[top.b].term);
            if (top.next < succ.len) {
                const s = succ[top.next];
                top.next += 1;
                if (s != .none and !visited[s.index()]) {
                    visited[s.index()] = true;
                    try stack.append(a, .{ .b = s.index(), .next = 0 });
                }
                continue;
            }
            try post.append(a, top.b);
            _ = stack.pop();
        }
        var i = post.items.len;
        while (i > 0) {
            i -= 1;
            order[post.items[i]] = @intCast(rpo.items.len);
            try rpo.append(a, post.items[i]);
        }
    }
    // Immediate dominators (Cooper, Harvey and Kennedy).
    const preds = try a.alloc(std.ArrayList(u32), nb);
    for (preds) |*p| p.* = .empty;
    for (rpo.items) |b| for (try successors(a, f.blocks.items[b].term)) |s| {
        if (s != .none) try preds[s.index()].append(a, b);
    };
    const idom = try a.alloc(u32, nb);
    @memset(idom, none);
    idom[0] = 0;
    var changed = true;
    while (changed) {
        changed = false;
        for (rpo.items[1..]) |b| {
            var nd: u32 = none;
            for (preds[b].items) |p| {
                if (idom[p] == none) continue;
                if (nd == none) {
                    nd = p;
                    continue;
                }
                var x = p;
                var y = nd;
                while (x != y) {
                    while (order[x] > order[y]) x = idom[x];
                    while (order[y] > order[x]) y = idom[y];
                }
                nd = x;
            }
            if (nd != none and idom[b] != nd) {
                idom[b] = nd;
                changed = true;
            }
        }
    }
    // Dominator tree intervals: a dominates b iff pre[a] <= pre[b] and
    // post[b] <= post[a].
    const pre = try a.alloc(u32, nb);
    const post = try a.alloc(u32, nb);
    {
        const kids = try a.alloc(std.ArrayList(u32), nb);
        for (kids) |*k| k.* = .empty;
        for (rpo.items[1..]) |b| if (idom[b] != none) try kids[idom[b]].append(a, b);
        var stack: std.ArrayList(struct { b: u32, next: usize }) = .empty;
        try stack.append(a, .{ .b = 0, .next = 0 });
        var t: u32 = 0;
        pre[0] = 0;
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            if (top.next < kids[top.b].items.len) {
                const c = kids[top.b].items[top.next];
                top.next += 1;
                t += 1;
                pre[c] = t;
                try stack.append(a, .{ .b = c, .next = 0 });
                continue;
            }
            t += 1;
            post[top.b] = t;
            _ = stack.pop();
        }
    }

    const def_block = try a.alloc(u32, ni);
    @memset(def_block, none);
    for (rpo.items) |b| for (f.blocks.items[b].insts.items) |r| {
        def_block[r.index()] = b;
    };

    const repl = try a.alloc(Ref, ni);
    @memset(repl, .none);
    const Map = struct {
        repl: []const Ref,
        pub fn map(c: @This(), x: Ref) Ref {
            var y = x;
            while (y != .none and y.index() < c.repl.len and c.repl[y.index()] != .none) y = c.repl[y.index()];
            return y;
        }
    };
    const mp = Map{ .repl = repl };

    var any = false;
    // Constants: one per type and value, wherever they are (the emitter
    // makes them before any block).
    {
        // (The first of each in a reachable block, in an order dominators
        // come first in: the emitter gives values to what it emits.)
        var consts: std.AutoHashMapUnmanaged([3]u64, Ref) = .empty;
        for (rpo.items) |b| for (f.blocks.items[b].insts.items) |r| {
            const i = r.index();
            const inst = f.insts.items[i];
            const k: [3]u64 = switch (inst.op) {
                .constant => |c| .{ @as(u64, inst.ty) | (@as(u64, @intFromEnum(inst.ptr)) << 32), @intFromEnum(std.meta.activeTag(c)), switch (c) {
                    .int => |v| @bitCast(v),
                    .float => |v| @bitCast(v),
                } },
                else => continue,
            };
            const gop = try consts.getOrPut(a, k);
            if (gop.found_existing) {
                repl[i] = gop.value_ptr.*;
                any = true;
            } else gop.value_ptr.* = r;
        };
    }

    var table: std.StringHashMapUnmanaged(std.ArrayList(Ref)) = .empty;
    for (rpo.items) |b| {
        for (f.blocks.items[b].insts.items) |r| {
            const ii = &f.insts.items[r.index()];
            if (ii.op == .constant) continue;
            ii.op = try opt.mapOp(a, ii.op, mp);
            const key = try keyOf(a, f, ii.*) orelse continue;
            const gop = try table.getOrPut(a, key);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            const hit = for (gop.value_ptr.items) |e| {
                const db = def_block[e.index()];
                if (db == b or (pre[db] <= pre[b] and post[b] <= post[db])) break e;
            } else Ref.none;
            if (hit != .none) {
                repl[r.index()] = hit;
                any = true;
            } else try gop.value_ptr.append(a, r);
        }
    }
    if (!any) return false;
    // Phis (whose operands may come from later blocks) and terminators,
    // of reachable blocks only.
    for (rpo.items) |b| {
        const blk = &f.blocks.items[b];
        for (blk.insts.items) |r| {
            const ii = &f.insts.items[r.index()];
            if (ii.op == .phi) ii.op = try opt.mapOp(a, ii.op, mp);
        }
        blk.term = switch (blk.term) {
            .ret => |v| .{ .ret = mp.map(v) },
            .cond_br => |c| .{ .cond_br = .{ .cond = mp.map(c.cond), .then = c.then, .@"else" = c.@"else" } },
            .@"switch" => |sw| .{ .@"switch" = .{ .value = mp.map(sw.value), .default = sw.default, .cases = sw.cases } },
            else => blk.term,
        };
    }
    return true;
}
