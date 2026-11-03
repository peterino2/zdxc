//! Full unrolling of loops with a constant trip count, on a DXIL function
//! after promotion to SSA values (as dxc's loop unrolling runs after SROA):
//! by then a loop's bound often comes from struct fields and arguments
//! only inlining made constant. Unrolled, indices into local arrays become
//! constants (so promotion can take the arrays out of memory) and code
//! guarded by the counter folds away, as it does for dxc.
//!
//! A loop qualifies when it is innermost, has one block leaving it (a
//! conditional branch out of the loop, to one block), and that branch's
//! condition is decided by header phis that start constant and step by
//! values computed from themselves. Its blocks are copied once per
//! iteration, and once more up to the exit, after the function's last
//! block; the original blocks are left unreachable for promotion to drop.

const std = @import("std");
const Allocator = std.mem.Allocator;
const module = @import("module.zig");
const stats = @import("../stats.zig");
const promote = @import("promote.zig");

const Value = module.Value;
const Inst = module.Inst;
const Edge = @typeInfo(@FieldType(@FieldType(@FieldType(Inst, "op"), "phi"), "incoming")).pointer.child;

const none = std.math.maxInt(u32);

/// Most iterations unrolled, most instructions one loop may grow to
/// unrolled (small loops only, as dxc's full unrolling of loops without
/// [unroll]: larger ones cost compile time and code size for little), and
/// most one function may grow by.
const max_trips = 256;
const max_loop_growth = 300;
const max_growth = 65536;

/// Unrolls the qualifying loops of `func`, innermost first; true if any.
pub fn run(a: Allocator, m: *module.Module, func: u32) Allocator.Error!bool {
    const zone = stats.begin(.unroll);
    defer zone.end();
    var budget: usize = max_growth;
    var tried: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var any = false;
    while (try unrollOne(a, m, func, &budget, &tried)) any = true;
    return any;
}

const Cfg = struct {
    nb: u32,
    block_start: []u32,
    succs: [][]u32,
    preds: [][]u32,
    idom: []u32,
    /// Each reachable block's interval in a depth-first walk of the
    /// dominator tree (`none` for unreachable blocks): `d` dominates `b`
    /// when `b`'s interval is inside `d`'s.
    dom_pre: []u32,
    dom_post: []u32,

    fn dominates(c: *const Cfg, d: u32, b: u32) bool {
        if (d == b) return true;
        if (c.dom_pre[d] == none or c.dom_pre[b] == none) return false;
        return c.dom_pre[d] <= c.dom_pre[b] and c.dom_post[b] <= c.dom_post[d];
    }
};

/// Numbers the dominator tree's blocks in and out of a depth-first walk.
fn domIntervals(a: Allocator, idom: []const u32) Allocator.Error!struct { []u32, []u32 } {
    const nb = idom.len;
    // Children lists, packed: block b's are kids[first[b]..first[b + 1]].
    const first = try a.alloc(u32, nb + 1);
    @memset(first, 0);
    for (idom, 0..) |p, b| if (p != none and p != b) {
        first[p + 1] += 1;
    };
    for (1..nb + 1) |k| first[k] += first[k - 1];
    const fill = try a.dupe(u32, first[0..nb]);
    const kids = try a.alloc(u32, first[nb]);
    for (idom, 0..) |p, b| if (p != none and p != b) {
        kids[fill[p]] = @intCast(b);
        fill[p] += 1;
    };
    const pre = try a.alloc(u32, nb);
    const post = try a.alloc(u32, nb);
    @memset(pre, none);
    @memset(post, none);
    if (nb == 0) return .{ pre, post };
    var clock: u32 = 0;
    // `next` reuses fill: the next child to visit.
    @memcpy(fill, first[0..nb]);
    var stack: std.ArrayList(u32) = .empty;
    try stack.append(a, 0);
    pre[0] = clock;
    clock += 1;
    while (stack.items.len > 0) {
        const b = stack.items[stack.items.len - 1];
        if (fill[b] < first[b + 1]) {
            const k = kids[fill[b]];
            fill[b] += 1;
            pre[k] = clock;
            clock += 1;
            try stack.append(a, k);
        } else {
            post[b] = clock;
            clock += 1;
            _ = stack.pop();
        }
    }
    return .{ pre, post };
}

/// A loop's blocks: a bit per block of the function, and the list in
/// block order.
const Body = struct {
    bits: []u64,
    blocks: []const u32,

    fn has(b: Body, x: u32) bool {
        return b.bits[x >> 6] >> @intCast(x & 63) & 1 != 0;
    }

    fn add(b: *Body, x: u32) void {
        b.bits[x >> 6] |= @as(u64, 1) << @intCast(x & 63);
    }
};

fn isTerminator(inst: Inst) bool {
    return switch (inst.op) {
        .ret, .br, .@"switch", .@"unreachable" => true,
        else => false,
    };
}

fn buildCfg(a: Allocator, f: *const module.Function) Allocator.Error!?Cfg {
    const nb = f.num_blocks;
    const insts = f.insts.items;
    const block_start = try a.alloc(u32, nb + 1);
    var b: u32 = 0;
    block_start[0] = 0;
    for (insts, 0..) |inst, i| {
        if (b >= nb) return null;
        if (isTerminator(inst)) {
            b += 1;
            block_start[b] = @intCast(i + 1);
        }
    }
    if (b != nb) return null;
    // Successors (each once) and predecessors, packed: each block's are a
    // slice of one array.
    var succ_flat: std.ArrayList(u32) = .empty;
    try succ_flat.ensureTotalCapacity(a, 2 * nb);
    const succ_off = try a.alloc(u32, nb + 1);
    for (0..nb) |bi| {
        const start = succ_flat.items.len;
        succ_off[bi] = @intCast(start);
        switch (insts[block_start[bi + 1] - 1].op) {
            .br => |br| {
                try succ_flat.append(a, br.then);
                if (br.@"else") |e| if (e != br.then) try succ_flat.append(a, e);
            },
            .@"switch" => |sw| {
                try succ_flat.append(a, sw.default);
                for (sw.cases) |c| if (std.mem.indexOfScalar(u32, succ_flat.items[start..], c.block) == null) try succ_flat.append(a, c.block);
            },
            else => {},
        }
    }
    succ_off[nb] = @intCast(succ_flat.items.len);
    const succs = try a.alloc([]u32, nb);
    for (succs, 0..) |*sl, bi| sl.* = succ_flat.items[succ_off[bi]..succ_off[bi + 1]];
    const pred_off = try a.alloc(u32, nb + 1);
    @memset(pred_off, 0);
    for (succ_flat.items) |t| pred_off[t + 1] += 1;
    for (1..nb + 1) |k| pred_off[k] += pred_off[k - 1];
    const pred_flat = try a.alloc(u32, succ_flat.items.len);
    {
        const fill = try a.dupe(u32, pred_off[0..nb]);
        for (0..nb) |bi| for (succs[bi]) |t| {
            pred_flat[fill[t]] = @intCast(bi);
            fill[t] += 1;
        };
    }
    const preds = try a.alloc([]u32, nb);
    for (preds, 0..) |*pl, bi| pl.* = pred_flat[pred_off[bi]..pred_off[bi + 1]];

    // Reverse postorder, then Cooper, Harvey and Kennedy's dominators.
    const order = try a.alloc(u32, nb);
    @memset(order, none);
    var rpo: std.ArrayList(u32) = .empty;
    {
        var post: std.ArrayList(u32) = .empty;
        const seen = try a.alloc(bool, nb);
        @memset(seen, false);
        const Fr = struct { b: u32, next: u32 };
        var stack: std.ArrayList(Fr) = .empty;
        try stack.append(a, .{ .b = 0, .next = 0 });
        seen[0] = true;
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            if (top.next < succs[top.b].len) {
                const s = succs[top.b][top.next];
                top.next += 1;
                if (!seen[s]) {
                    seen[s] = true;
                    try stack.append(a, .{ .b = s, .next = 0 });
                }
            } else {
                try post.append(a, top.b);
                _ = stack.pop();
            }
        }
        var k = post.items.len;
        while (k > 0) {
            k -= 1;
            order[post.items[k]] = @intCast(rpo.items.len);
            try rpo.append(a, post.items[k]);
        }
    }
    const idom = try a.alloc(u32, nb);
    @memset(idom, none);
    idom[0] = 0;
    var changed = true;
    while (changed) {
        changed = false;
        for (rpo.items[1..]) |bb| {
            var new: u32 = none;
            for (preds[bb]) |p| {
                if (idom[p] == none) continue;
                if (new == none) {
                    new = p;
                    continue;
                }
                var x = p;
                var y = new;
                while (x != y) {
                    while (order[x] > order[y]) x = idom[x];
                    while (order[y] > order[x]) y = idom[y];
                }
                new = x;
            }
            if (new != none and idom[bb] != new) {
                idom[bb] = new;
                changed = true;
            }
        }
    }
    const pre, const post = try domIntervals(a, idom);
    return .{ .nb = nb, .block_start = block_start, .succs = succs, .preds = preds, .idom = idom, .dom_pre = pre, .dom_post = post };
}

fn constInt(m: *const module.Module, v: Value) ?i64 {
    if (v != .constant) return null;
    return switch (m.constants.items[v.constant].kind) {
        .int => |x| x,
        else => null,
    };
}

fn intWidth(m: *const module.Module, ty: module.TypeId) ?u32 {
    return switch (m.types.items[ty]) {
        .int => |w| w,
        else => null,
    };
}

fn bitsOf(v: i64, w: u32) u64 {
    const u: u64 = @bitCast(v);
    return if (w >= 64) u else u & ((@as(u64, 1) << @intCast(w)) - 1);
}

/// A `w`-bit pattern as constants hold it: 0 / 1 for i1, sign-extended
/// above.
fn stored(p: u64, w: u32) i64 {
    if (w == 1) return @intCast(p & 1);
    if (w >= 64) return @bitCast(p);
    const sh: u6 = @intCast(64 - w);
    return @as(i64, @bitCast(p << sh)) >> sh;
}

/// Integer value of `v` given the header phis' values in `state` (index:
/// instruction), or null.
fn eval(m: *const module.Module, f: *const module.Function, state: *const std.AutoHashMapUnmanaged(u32, i64), v: Value, depth: u32) ?i64 {
    if (depth > 64) return null;
    if (constInt(m, v)) |c| return c;
    if (v != .inst) return null;
    if (state.get(v.inst)) |s| return s;
    const inst = f.insts.items[v.inst];
    const w = intWidth(m, inst.ty) orelse return null;
    switch (inst.op) {
        .binop => |b| {
            const x = bitsOf(eval(m, f, state, b.lhs, depth + 1) orelse return null, w);
            const y = bitsOf(eval(m, f, state, b.rhs, depth + 1) orelse return null, w);
            const sx = stored(x, w);
            const sy = stored(y, w);
            const p: u64 = switch (b.op) {
                .add => x +% y,
                .sub => x -% y,
                .mul => x *% y,
                .@"and" => x & y,
                .@"or" => x | y,
                .xor => x ^ y,
                .shl => if (y < w) x << @intCast(y) else return null,
                .lshr => if (y < w) x >> @intCast(y) else return null,
                .ashr => if (y < w) @bitCast(sx >> @intCast(y)) else return null,
                .udiv => if (y != 0) x / y else return null,
                .urem => if (y != 0) x % y else return null,
                .sdiv => if (sy != 0 and !(sy == -1 and sx == std.math.minInt(i64))) @bitCast(@divTrunc(sx, sy)) else return null,
                .srem => if (sy != 0 and sy != -1) @bitCast(@rem(sx, sy)) else return null,
            };
            return stored(bitsOf(@bitCast(p), w), w);
        },
        .cast => |c| {
            const from = intWidth(m, typeOf(m, f, c.val) orelse return null) orelse return null;
            const x = bitsOf(eval(m, f, state, c.val, depth + 1) orelse return null, from);
            const out: u64 = switch (c.op) {
                .zext, .trunc => x,
                .sext => if (from == 1) (if (x & 1 != 0) ~@as(u64, 0) else 0) else @bitCast(stored(x, from)),
                else => return null,
            };
            return stored(bitsOf(@bitCast(out), w), w);
        },
        .cmp => |c| {
            if (c.pred < 32 or c.pred > 41) return null;
            const cw = intWidth(m, typeOf(m, f, c.lhs) orelse return null) orelse return null;
            const x = bitsOf(eval(m, f, state, c.lhs, depth + 1) orelse return null, cw);
            const y = bitsOf(eval(m, f, state, c.rhs, depth + 1) orelse return null, cw);
            const sx = stored(x, cw);
            const sy = stored(y, cw);
            const t = switch (c.pred) {
                32 => x == y,
                33 => x != y,
                34 => x > y,
                35 => x >= y,
                36 => x < y,
                37 => x <= y,
                38 => sx > sy,
                39 => sx >= sy,
                40 => sx < sy,
                else => sx <= sy,
            };
            return @intFromBool(t);
        },
        .select => |s| {
            const c = eval(m, f, state, s.cond, depth + 1) orelse return null;
            return eval(m, f, state, if (c & 1 != 0) s.t else s.f, depth + 1);
        },
        else => return null,
    }
}

fn typeOf(m: *const module.Module, f: *const module.Function, v: Value) ?module.TypeId {
    return switch (v) {
        .inst => |i| f.insts.items[i].ty,
        .constant => |c| m.constants.items[c].ty,
        .arg => |k| m.types.items[f.ty].function.params[k],
        else => null,
    };
}

fn unrollOne(a: Allocator, m: *module.Module, func: u32, budget: *usize, tried: *std.AutoHashMapUnmanaged(u32, void)) Allocator.Error!bool {
    const f = &m.functions.items[func];
    const cfg = (try buildCfg(a, f)) orelse return false;
    const nb = cfg.nb;
    const insts = f.insts.items;

    // Loops: headers with back edges (from blocks they dominate), and
    // their blocks.
    const Loop = struct { h: u32, body: Body, latches: []u32 };
    var loops: std.ArrayList(Loop) = .empty;
    for (0..nb) |hb| {
        const h: u32 = @intCast(hb);
        if (cfg.idom[h] == none) continue;
        var latches: std.ArrayList(u32) = .empty;
        for (cfg.preds[h]) |p| if (cfg.idom[p] != none and cfg.dominates(h, p)) try latches.append(a, p);
        if (latches.items.len == 0) continue;
        const bits = try a.alloc(u64, (nb + 63) / 64);
        @memset(bits, 0);
        var blocks: std.ArrayList(u32) = .empty;
        var body: Body = .{ .bits = bits, .blocks = &.{} };
        body.add(h);
        try blocks.append(a, h);
        var stack: std.ArrayList(u32) = .empty;
        try stack.appendSlice(a, latches.items);
        while (stack.pop()) |x| {
            if (body.has(x)) continue;
            body.add(x);
            try blocks.append(a, x);
            for (cfg.preds[x]) |p| if (cfg.idom[p] != none) try stack.append(a, p);
        }
        std.sort.pdq(u32, blocks.items, {}, std.sort.asc(u32));
        body.blocks = blocks.items;
        try loops.append(a, .{ .h = h, .body = body, .latches = latches.items });
    }

    // Loops that do nothing (as dxc's loop deletion removes them): no
    // instruction with an effect, one block they leave to, and nothing
    // after them reading their values. Their preheader goes straight to
    // that block; their blocks are left unreachable for promotion to drop.
    // (Nested ones too: an outer loop whose inner loops do nothing.)
    const loop_inst = try a.alloc(bool, insts.len);
    @memset(loop_inst, false);
    // (The loop whose instructions loop_inst marks, cleared for the next.)
    var marked: ?Body = null;
    dead: for (loops.items) |lp| {
        if (marked) |mk| for (mk.blocks) |bb| @memset(loop_inst[cfg.block_start[bb]..cfg.block_start[bb + 1]], false);
        marked = null;
        var exit: u32 = none;
        for (lp.body.blocks) |bb| {
            for (cfg.block_start[bb]..cfg.block_start[bb + 1]) |i| switch (insts[i].op) {
                .br, .@"switch" => {},
                .ret, .@"unreachable", .store, .atomicrmw, .cmpxchg => continue :dead,
                .call => |c| switch (m.functions.items[c.callee].attrs) {
                    .nounwind_readnone, .nounwind_readonly => {},
                    else => if (!promote.isWaveOp(m.functions.items[c.callee].name)) continue :dead,
                },
                else => {},
            };
            for (cfg.succs[bb]) |s| if (!lp.body.has(s)) {
                if (exit != none and exit != s) continue :dead;
                exit = s;
            };
        }
        if (exit == none) continue;
        var pre: u32 = none;
        for (cfg.preds[lp.h]) |p| if (!lp.body.has(p)) {
            if (pre != none) continue :dead;
            pre = p;
        };
        if (pre == none) continue;
        const pterm = &insts[cfg.block_start[pre + 1] - 1];
        if (pterm.op != .br) continue;
        if (pterm.op.br.then == exit or pterm.op.br.@"else" == exit) continue;

        for (lp.body.blocks) |bb| @memset(loop_inst[cfg.block_start[bb]..cfg.block_start[bb + 1]], true);
        marked = lp.body;
        // The exit's phis: one value from the loop, from before it.
        const phi_end = blk: {
            var i = cfg.block_start[exit];
            while (insts[i].op == .phi) i += 1;
            break :blk i;
        };
        const from_loop = try a.alloc(?Value, phi_end - cfg.block_start[exit]);
        for (cfg.block_start[exit]..phi_end, from_loop) |i, *fl| {
            fl.* = null;
            for (insts[i].op.phi.incoming) |in| if (lp.body.has(in.block)) {
                if (in.val == .inst and loop_inst[in.val.inst]) continue :dead;
                if (fl.* != null and !std.meta.eql(fl.*.?, in.val)) continue :dead;
                fl.* = in.val;
            };
        }
        // Nothing else outside reads the loop's values.
        const Check = struct {
            loop_inst: []const bool,
            used: bool = false,
            pub fn visit(c: *@This(), v: Value, _: anytype) Value {
                if (v == .inst and v.inst < c.loop_inst.len and c.loop_inst[v.inst]) c.used = true;
                return v;
            }
        };
        var check: Check = .{ .loop_inst = loop_inst };
        for (0..nb) |bb| {
            if (lp.body.has(@intCast(bb))) continue;
            for (cfg.block_start[bb]..cfg.block_start[bb + 1]) |i| {
                if (bb == exit and i < phi_end) continue;
                var copy = insts[i];
                try operandsMap(a, &copy, &check);
            }
        }
        if (check.used) continue;

        const ma = m.allocator();
        for (cfg.block_start[exit]..phi_end, from_loop) |i, fl| {
            var edges: std.ArrayList(Edge) = .empty;
            for (insts[i].op.phi.incoming) |in| if (!lp.body.has(in.block)) try edges.append(ma, in);
            if (fl) |v| try edges.append(ma, .{ .val = v, .block = pre });
            insts[i].op.phi.incoming = edges.items;
        }
        if (pterm.op.br.then == lp.h) pterm.op.br.then = exit;
        if (pterm.op.br.@"else") |*e| if (e.* == lp.h) {
            e.* = exit;
        };
        for (lp.body.blocks) |bb| insts[cfg.block_start[bb + 1] - 1].op = .@"unreachable";
        return true;
    }

    candidates: for (loops.items) |lp| {
        const h = lp.h;
        if (tried.contains(h)) continue;
        // Innermost: no other loop's header inside.
        for (loops.items) |other| if (other.h != h and lp.body.has(other.h)) continue :candidates;
        try tried.put(a, h, {});

        // One way out: a conditional branch from one block, to one block.
        var exiting: u32 = none;
        var exit: u32 = none;
        var size: usize = 0;
        var body_blocks: std.ArrayList(u32) = .empty;
        for (lp.body.blocks) |bb| {
            try body_blocks.append(a, bb);
            size += cfg.block_start[bb + 1] - cfg.block_start[bb];
            const term = insts[cfg.block_start[bb + 1] - 1].op;
            if (term == .@"switch") {
                for (cfg.succs[bb]) |s| if (!lp.body.has(s)) continue :candidates;
            }
            for (cfg.succs[bb]) |s| if (!lp.body.has(s)) {
                if (exiting != none) continue :candidates;
                exiting = bb;
                exit = s;
            };
        }
        if (exiting == none) continue;
        const xterm = insts[cfg.block_start[exiting + 1] - 1].op;
        if (xterm != .br or xterm.br.@"else" == null) continue;
        const stay = if (xterm.br.then == exit) xterm.br.@"else".? else xterm.br.then;
        if (!lp.body.has(stay) or stay == exit) continue;
        for (lp.latches) |l| if (!cfg.dominates(exiting, l)) continue :candidates;
        // One way in.
        var pre: u32 = none;
        for (cfg.preds[h]) |p| if (!lp.body.has(p)) {
            if (pre != none) continue :candidates;
            pre = p;
        };
        if (pre == none) continue;

        // The header's phis: the integer ones whose values can be followed.
        var phis: std.ArrayList(u32) = .empty;
        {
            var i = cfg.block_start[h];
            while (insts[i].op == .phi) : (i += 1) try phis.append(a, i);
        }
        var state: std.AutoHashMapUnmanaged(u32, i64) = .empty;
        for (phis.items) |pi| {
            if (intWidth(m, insts[pi].ty) == null) continue;
            for (insts[pi].op.phi.incoming) |in| if (in.block == pre) {
                if (constInt(m, in.val)) |c| try state.put(a, pi, c);
            };
        }
        const xcond = xterm.br.cond.?;
        const stay_on: i64 = if (xterm.br.then == stay) 1 else 0;
        var states: std.ArrayList(std.AutoHashMapUnmanaged(u32, i64)) = .empty;
        while (true) {
            const c = eval(m, f, &state, xcond, 0) orelse continue :candidates;
            if ((c & 1) != stay_on) break;
            if (states.items.len >= max_trips) continue :candidates;
            try states.append(a, try state.clone(a));
            // Next values: what every latch passes back (the same).
            var next: std.AutoHashMapUnmanaged(u32, i64) = .empty;
            for (phis.items) |pi| {
                if (!state.contains(pi)) continue;
                var val: ?i64 = null;
                var ok = true;
                for (insts[pi].op.phi.incoming) |in| {
                    if (in.block == pre) continue;
                    const v = eval(m, f, &state, in.val, 0) orelse {
                        ok = false;
                        break;
                    };
                    if (val != null and val.? != v) ok = false;
                    val = v;
                }
                if (ok) if (val) |v| try next.put(a, pi, v);
            }
            state = next;
        }
        const trips = states.items.len;
        const growth = (trips + 1) * size;
        if (growth > max_loop_growth or growth > budget.*) continue;
        budget.* -= growth;
        try states.append(a, state); // the last pass, up to the exit

        // Copies: block `body_blocks[j]` of copy `k` is block
        // `nb + k * nbody + j`.
        const nbody: u32 = @intCast(body_blocks.items.len);
        const index_in = try a.alloc(u32, nb);
        @memset(index_in, none);
        for (body_blocks.items, 0..) |bb, j| index_in[bb] = @intCast(j);
        const n0: u32 = @intCast(insts.len);
        const copies: u32 = @intCast(trips + 1);
        // Value maps per copy (original instruction -> value).
        const maps = try a.alloc(std.AutoHashMapUnmanaged(u32, Value), copies);
        for (maps) |*mp| mp.* = .empty;
        const S = struct {
            fn block(nb_: u32, nbody_: u32, idx: []const u32, k: u32, b: u32) u32 {
                return nb_ + k * nbody_ + idx[b];
            }
        };

        var out: std.ArrayList(Inst) = .empty;
        const ma = m.allocator();
        // New instruction indices come after the existing ones.
        var next_index: u32 = n0;
        // First pass: give every copied instruction its index (phis of
        // later copies refer back, latch values refer forward to the next
        // copy's header).
        const new_index = try a.alloc([]u32, copies);
        for (0..copies) |k| {
            new_index[k] = try a.alloc(u32, n0);
            @memset(new_index[k], none);
            for (body_blocks.items) |bb| {
                var i = cfg.block_start[bb];
                while (i < cfg.block_start[bb + 1]) : (i += 1) {
                    new_index[k][i] = next_index;
                    next_index += 1;
                }
            }
        }
        // Header phis: a constant where followed, else the value from the
        // copy before (or from the preheader).
        for (0..copies) |k| {
            for (phis.items) |pi| {
                if (states.items[k].get(pi)) |c| {
                    try maps[k].put(a, pi, try m.constant(.{ .ty = insts[pi].ty, .kind = .{ .int = c } }));
                    continue;
                }
                if (k == 0) {
                    for (insts[pi].op.phi.incoming) |in| if (in.block == pre) try maps[0].put(a, pi, in.val);
                }
            }
        }
        const Mapper = struct {
            maps: []std.AutoHashMapUnmanaged(u32, Value),
            new_index: [][]u32,
            k: u32,
            fn val(c: @This(), v: Value) Value {
                if (v != .inst) return v;
                if (c.maps[c.k].get(v.inst)) |x| return x;
                if (v.inst < c.new_index[c.k].len and c.new_index[c.k][v.inst] != none) return .{ .inst = c.new_index[c.k][v.inst] };
                return v;
            }
            fn visit(c: *@This(), v: Value, _: anytype) Value {
                return c.val(v);
            }
        };
        for (0..copies) |kk| {
            const k: u32 = @intCast(kk);
            for (body_blocks.items) |bb| {
                var i = cfg.block_start[bb];
                while (i < cfg.block_start[bb + 1]) : (i += 1) {
                    var inst = insts[i];
                    var mapper: Mapper = .{ .maps = maps, .new_index = new_index, .k = k };
                    if (bb == h and inst.op == .phi) {
                        if (maps[k].get(i)) |v| {
                            // Folded away: a phi of that value on every
                            // edge keeps the numbering (promotion drops it).
                            var edges: std.ArrayList(Edge) = .empty;
                            if (k == 0) {
                                try edges.append(ma, .{ .val = v, .block = pre });
                            } else for (lp.latches) |l| try edges.append(ma, .{ .val = v, .block = S.block(nb, nbody, index_in, k - 1, l) });
                            try out.append(ma, .{ .ty = inst.ty, .op = .{ .phi = .{ .incoming = edges.items } } });
                            continue;
                        }
                        // From the latches of the copy before.
                        var edges: std.ArrayList(Edge) = .empty;
                        for (inst.op.phi.incoming) |in| {
                            if (in.block == pre or k == 0) continue;
                            const prev: Mapper = .{ .maps = maps, .new_index = new_index, .k = k - 1 };
                            try edges.append(ma, .{ .val = prev.val(in.val), .block = S.block(nb, nbody, index_in, k - 1, in.block) });
                        }
                        if (k == 0) {
                            // (Not followed and no preheader value mapped:
                            // the preheader's incoming.)
                            for (inst.op.phi.incoming) |in| if (in.block == pre) try edges.append(ma, .{ .val = in.val, .block = pre });
                        }
                        try out.append(ma, .{ .ty = inst.ty, .op = .{ .phi = .{ .incoming = edges.items } } });
                        continue;
                    }
                    if (inst.op == .phi) {
                        const edges = try ma.alloc(Edge, inst.op.phi.incoming.len);
                        for (inst.op.phi.incoming, edges) |in, *e| e.* = .{ .val = mapper.val(in.val), .block = if (index_in[in.block] != none) S.block(nb, nbody, index_in, k, in.block) else in.block };
                        inst.op = .{ .phi = .{ .incoming = edges } };
                        try out.append(ma, inst);
                        continue;
                    }
                    try operandsMap(ma, &inst, &mapper);
                    // Branches: within the copy; back to the header: the
                    // next copy; out of the exiting block: per copy.
                    switch (inst.op) {
                        .br => |*br| {
                            if (bb == exiting) {
                                const target = if (k + 1 < copies) stay else exit;
                                const tb = if (target == exit) exit else S.block(nb, nbody, index_in, k, target);
                                br.* = .{ .then = tb };
                            } else {
                                br.then = mapBlock(br.then, h, k, copies, nb, nbody, index_in);
                                if (br.@"else") |*e| e.* = mapBlock(e.*, h, k, copies, nb, nbody, index_in);
                            }
                        },
                        .@"switch" => |*sw| {
                            sw.default = mapBlock(sw.default, h, k, copies, nb, nbody, index_in);
                            const cs = try ma.alloc(@typeInfo(@TypeOf(sw.cases)).pointer.child, sw.cases.len);
                            for (sw.cases, cs) |c, *o| o.* = .{ .val = c.val, .block = mapBlock(c.block, h, k, copies, nb, nbody, index_in) };
                            sw.cases = cs;
                        },
                        else => {},
                    }
                    // Integer values the counter decides: constants.
                    if (inst.op == .binop or inst.op == .cast or inst.op == .cmp or inst.op == .select) {
                        if (eval(m, f, &states.items[k], .{ .inst = i }, 0)) |c| {
                            if (intWidth(m, inst.ty) != null) try maps[k].put(a, i, try m.constant(.{ .ty = inst.ty, .kind = .{ .int = c } }));
                        }
                    }
                    try out.append(ma, inst);
                }
            }
        }

        // The preheader enters the first copy; the exit's phis and the
        // code after the loop see the last copy's values.
        const last: Mapper = .{ .maps = maps, .new_index = new_index, .k = copies - 1 };
        const in_body = try a.alloc(bool, n0);
        for (0..nb) |bb| for (cfg.block_start[bb]..cfg.block_start[bb + 1]) |i| {
            in_body[i] = lp.body.has(@intCast(bb));
        };
        const Outside = struct {
            last: Mapper,
            in_body: []const bool,
            fn visit(c: *@This(), v: Value, _: anytype) Value {
                if (v == .inst and v.inst < c.in_body.len and c.in_body[v.inst]) return c.last.val(v);
                return v;
            }
        };
        var outside: Outside = .{ .last = last, .in_body = in_body };
        for (0..nb) |bb| {
            if (lp.body.has(@intCast(bb))) {
                // The originals: unreachable now.
                insts[cfg.block_start[bb + 1] - 1].op = .@"unreachable";
                continue;
            }
            for (cfg.block_start[bb]..cfg.block_start[bb + 1]) |i| {
                var inst = &insts[i];
                if (inst.op == .phi) {
                    const edges = try ma.alloc(Edge, inst.op.phi.incoming.len);
                    for (inst.op.phi.incoming, edges) |in, *e| e.* = .{
                        .val = outside.visit(in.val, {}),
                        .block = if (in.block == exiting and bb == exit) S.block(nb, nbody, index_in, copies - 1, exiting) else in.block,
                    };
                    inst.op = .{ .phi = .{ .incoming = edges } };
                    continue;
                }
                try operandsMap(ma, inst, &outside);
                if (bb == pre) switch (inst.op) {
                    .br => |*br| {
                        if (br.then == h) br.then = S.block(nb, nbody, index_in, 0, h);
                        if (br.@"else") |*e| if (e.* == h) {
                            e.* = S.block(nb, nbody, index_in, 0, h);
                        };
                    },
                    .@"switch" => |*sw| {
                        if (sw.default == h) sw.default = S.block(nb, nbody, index_in, 0, h);
                        const cs = try ma.alloc(@typeInfo(@TypeOf(sw.cases)).pointer.child, sw.cases.len);
                        for (sw.cases, cs) |c, *o| o.* = .{ .val = c.val, .block = if (c.block == h) S.block(nb, nbody, index_in, 0, h) else c.block };
                        sw.cases = cs;
                    },
                    else => {},
                };
            }
        }
        try f.insts.appendSlice(ma, out.items);
        f.num_blocks = nb + copies * nbody;
        return true;
    }
    return false;
}

/// A branch target in copy `k`: the copy's own block, or (the header) the
/// next copy's.
fn mapBlock(t: u32, h: u32, k: u32, copies: u32, nb: u32, nbody: u32, idx: []const u32) u32 {
    if (idx[t] == none) return t;
    if (t == h) return nb + @min(k + 1, copies - 1) * nbody + idx[t];
    return nb + k * nbody + idx[t];
}

/// Rewrites `inst`'s value operands through `ctx.visit` (block operands
/// are the caller's).
pub fn operandsMap(a: Allocator, inst: *Inst, ctx: anytype) Allocator.Error!void {
    const S = struct {
        fn one(c: anytype, v: *Value) void {
            v.* = c.visit(v.*, {});
        }
        fn many(al: Allocator, c: anytype, vs: *[]const Value) Allocator.Error!void {
            const o = try al.alloc(Value, vs.len);
            for (vs.*, o) |v, *x| x.* = c.visit(v, {});
            vs.* = o;
        }
    };
    switch (inst.op) {
        .ret => |*v| if (v.*) |*x| S.one(ctx, x),
        .br => |*b| if (b.cond) |*c| S.one(ctx, c),
        .@"switch" => |*sw| S.one(ctx, &sw.cond),
        .call => |*c| try S.many(a, ctx, &c.args),
        .binop => |*b| {
            S.one(ctx, &b.lhs);
            S.one(ctx, &b.rhs);
        },
        .cast => |*c| S.one(ctx, &c.val),
        .cmp => |*c| {
            S.one(ctx, &c.lhs);
            S.one(ctx, &c.rhs);
        },
        .select => |*s| {
            S.one(ctx, &s.cond);
            S.one(ctx, &s.t);
            S.one(ctx, &s.f);
        },
        .extractvalue => |*x| S.one(ctx, &x.agg),
        .phi => |*p| {
            const out = try a.alloc(Edge, p.incoming.len);
            for (p.incoming, out) |in, *o| o.* = .{ .val = ctx.visit(in.val, {}), .block = in.block };
            p.incoming = out;
        },
        .alloca => |*x| S.one(ctx, &x.size),
        .load => |*x| S.one(ctx, &x.ptr),
        .store => |*x| {
            S.one(ctx, &x.ptr);
            S.one(ctx, &x.val);
        },
        .gep => |*x| {
            S.one(ctx, &x.ptr);
            try S.many(a, ctx, &x.indices);
        },
        .atomicrmw => |*x| {
            S.one(ctx, &x.ptr);
            S.one(ctx, &x.val);
        },
        .cmpxchg => |*x| {
            S.one(ctx, &x.ptr);
            S.one(ctx, &x.cmp);
            S.one(ctx, &x.new);
        },
        .@"unreachable" => {},
        .extractelement => |*x| {
            S.one(ctx, &x.vec);
            S.one(ctx, &x.index);
        },
        .insertelement => |*x| {
            S.one(ctx, &x.vec);
            S.one(ctx, &x.val);
            S.one(ctx, &x.index);
        },
    }
}
