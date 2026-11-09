//! Control-flow cleanup, as dxc's simplifycfg does it: a block that only
//! branches to a block with no other predecessor takes that block in, and
//! a block holding nothing but an unconditional branch is bypassed (its
//! predecessors branch straight to its successor). Lowering gives every
//! statement, scope and inlined call its own blocks, and the optimizer
//! empties many more; without this they stay as chains of branches.
//!
//! Run on a function in SSA form, after promotion (which drops the blocks
//! no path reaches).

const std = @import("std");
const Allocator = std.mem.Allocator;
const module = @import("module.zig");
const promote = @import("promote.zig");
const stats = @import("../stats.zig");

const Value = module.Value;
const Inst = module.Inst;

const none = std.math.maxInt(u32);

const Edge = @typeInfo(@FieldType(@FieldType(@FieldType(Inst, "op"), "phi"), "incoming")).pointer.child;
const Case = @typeInfo(@FieldType(@FieldType(@FieldType(Inst, "op"), "switch"), "cases")).pointer.child;

fn isTerminator(inst: Inst) bool {
    return switch (inst.op) {
        .ret, .br, .@"switch", .@"unreachable" => true,
        else => false,
    };
}

/// Most cost of the instructions one arm of an if may hoist above its
/// branch to become a select (LLVM's phi-node-folding-threshold, as in
/// dxc).
const max_arm_cost = 2;

const State = struct {
    a: Allocator,
    m: *const module.Module,
    insts: []Inst,
    /// Each block's instructions (old indices), its terminator last.
    body: []std.ArrayList(u32),
    /// Predecessor edges (a block twice if it branches here twice).
    preds: []std.ArrayList(u32),
    /// The block that now holds a merged block's terminator: phis naming
    /// the merged block mean it.
    owner: []u32,
    alive: []bool,
    /// Phis replaced by their one input.
    repl: []?Value,

    fn find(s: *State, b: u32) u32 {
        var x = b;
        while (s.owner[x] != x) x = s.owner[x];
        var y = b;
        while (s.owner[y] != x) {
            const next = s.owner[y];
            s.owner[y] = x;
            y = next;
        }
        return x;
    }

    fn term(s: *State, b: u32) *Inst {
        const items = s.body[b].items;
        return &s.insts[items[items.len - 1]];
    }

    fn hasPhis(s: *State, b: u32) bool {
        return s.insts[s.body[b].items[0]].op == .phi;
    }

    fn removePred(s: *State, b: u32, p: u32) void {
        const l = &s.preds[b];
        for (l.items, 0..) |x, k| if (x == p) {
            _ = l.swapRemove(k);
            return;
        };
    }

    fn renamePred(s: *State, x: u32, from: u32, to: u32) void {
        for (s.preds[x].items) |*p| {
            if (p.* == from) p.* = to;
        }
    }

    fn countPred(s: *State, b: u32, p: u32) u32 {
        var c: u32 = 0;
        for (s.preds[b].items) |x| c += @intFromBool(x == p);
        return c;
    }

    /// `b` (unconditional branch to `c`, `c`'s only predecessor) takes in
    /// `c`.
    fn merge(s: *State, b: u32, c: u32) Allocator.Error!void {
        const cb = s.body[c].items;
        var k: usize = 0;
        while (k < cb.len and s.insts[cb[k]].op == .phi) : (k += 1) {
            s.repl[cb[k]] = s.insts[cb[k]].op.phi.incoming[0].val;
        }
        const bb = &s.body[b];
        _ = bb.pop();
        try bb.appendSlice(s.a, cb[k..]);
        s.alive[c] = false;
        s.owner[c] = b;
        // (`c`'s successors now have `b` for a predecessor.)
        switch (s.term(b).op) {
            .br => |br| {
                s.renamePred(br.then, c, b);
                if (br.@"else") |e| s.renamePred(e, c, b);
            },
            .@"switch" => |sw| {
                s.renamePred(sw.default, c, b);
                for (sw.cases) |x| s.renamePred(x.block, c, b);
            },
            else => {},
        }
    }

    /// Retargets `p`'s edges to `b` at `c`.
    fn retarget(s: *State, p: u32, b: u32, c: u32) Allocator.Error!void {
        const t = s.term(p);
        switch (t.op) {
            .br => |*br| {
                if (br.then == b) br.then = c;
                if (br.@"else") |*e| if (e.* == b) {
                    e.* = c;
                };
            },
            .@"switch" => |*sw| {
                if (sw.default == b) sw.default = c;
                const cs = try s.a.dupe(Case, sw.cases);
                for (cs) |*x| if (x.block == b) {
                    x.block = c;
                };
                sw.cases = cs;
            },
            else => unreachable,
        }
    }

    /// True if `b` is cheap instructions safe to run on either path (see
    /// cost) and `br m`, and only `p` branches to it.
    fn armFrom(s: *State, b: u32, p: u32, m: u32) bool {
        if (s.preds[b].items.len != 1 or s.preds[b].items[0] != p) return false;
        const t = s.term(b).op;
        if (t != .br or t.br.@"else" != null or t.br.then != m) return false;
        const items = s.body[b].items;
        var total: u32 = 0;
        const limit: u32 = if (@import("exp.zig").cur.ifconv != 0) @import("exp.zig").cur.ifconv else max_arm_cost;
        for (items[0 .. items.len - 1]) |i| {
            total += s.cost(s.insts[i]) orelse return false;
            if (total > limit) return false;
        }
        return true;
    }

    /// What hoisting `inst` above a branch costs, or null if it cannot
    /// be: it has an effect, may trap (integer division), or reads memory.
    fn cost(s: *State, inst: Inst) ?u32 {
        return switch (inst.op) {
            .binop => |b| switch (b.op) {
                .udiv, .sdiv, .urem, .srem => if (s.m.types.items[inst.ty] == .int) null else 1,
                else => 1,
            },
            .cast => |c| if (c.op == .bitcast) 0 else 1,
            .cmp, .select, .extractvalue, .extractelement, .insertelement => 1,
            // (EXPERIMENT: with -zdxc-exp=ifconv=N, math dx.op calls too:
            // no effects, no memory.)
            .call => |c| if (@import("exp.zig").cur.ifconv != 0 and s.m.functions.items[c.callee].attrs == .nounwind_readnone) 2 else null,
            else => null,
        };
    }

    /// The instructions of `b` before its terminator, moved to the end of
    /// `p` (before its terminator).
    fn hoist(s: *State, b: u32, p: u32) Allocator.Error!void {
        const from = s.body[b].items;
        if (from.len < 2) return;
        const to = &s.body[p];
        const t = to.pop().?;
        try to.appendSlice(s.a, from[0 .. from.len - 1]);
        try to.append(s.a, t);
        from[0] = from[from.len - 1];
        s.body[b].shrinkRetainingCapacity(1);
    }

    /// A branch to one block every way goes there unconditionally; the
    /// phis there keep one input from it.
    fn collapse(s: *State, b: u32) Allocator.Error!bool {
        const t = s.term(b);
        const target: u32 = switch (t.op) {
            .br => |br| if (br.@"else") |e| (if (e == br.then) e else return false) else return false,
            .@"switch" => |sw| blk: {
                for (sw.cases) |c| if (c.block != sw.default) return false;
                break :blk sw.default;
            },
            else => return false,
        };
        t.op = .{ .br = .{ .then = target } };
        while (s.countPred(target, b) > 1) s.removePred(target, b);
        const cb = s.body[target].items;
        var k: usize = 0;
        while (k < cb.len and s.insts[cb[k]].op == .phi) : (k += 1) {
            const phi = &s.insts[cb[k]].op.phi;
            var out: std.ArrayList(Edge) = .empty;
            var seen = false;
            for (phi.incoming) |in| {
                if (s.find(in.block) == b) {
                    if (seen) continue;
                    seen = true;
                }
                try out.append(s.a, in);
            }
            phi.incoming = out.items;
        }
        return true;
    }

    /// `m`'s two predecessors: a conditional branch and a block it
    /// branches to (a triangle), or two blocks one conditional
    /// branch picks between (a diamond). `m`'s phis become selects on the
    /// branch's condition, and the branch goes straight to `m` (dxc's
    /// simplifycfg folds two-entry phis so). True if done.
    fn ifConvert(s: *State, m: u32) Allocator.Error!bool {
        const ps = s.preds[m].items;
        if (ps.len != 2 or ps[0] == ps[1]) return false;
        // The branching block, and the block each of its arms reaches `m`
        // from.
        var p: u32 = none;
        var via: [2]u32 = undefined;
        for (0..2) |k| {
            const q = ps[k];
            const other = ps[1 - k];
            const t = s.term(q).op;
            if (q == m or t != .br) continue;
            const e = t.br.@"else" orelse continue;
            if (t.br.then == m and e == other and s.armFrom(other, q, m)) {
                p = q;
                via = .{ q, other };
            } else if (e == m and t.br.then == other and s.armFrom(other, q, m)) {
                p = q;
                via = .{ other, q };
            }
        }
        if (p == none) {
            // A diamond: both predecessors empty, from one branch.
            if (s.preds[ps[0]].items.len != 1) return false;
            const q = s.preds[ps[0]].items[0];
            if (q == m or !s.armFrom(ps[0], q, m) or !s.armFrom(ps[1], q, m)) return false;
            const t = s.term(q).op;
            if (t != .br) return false;
            const e = t.br.@"else" orelse return false;
            if (t.br.then == ps[0] and e == ps[1]) {
                via = .{ ps[0], ps[1] };
            } else if (t.br.then == ps[1] and e == ps[0]) {
                via = .{ ps[1], ps[0] };
            } else return false;
            p = q;
        }
        const cond = s.term(p).op.br.cond.?;
        const mb = s.body[m].items;
        var k: usize = 0;
        while (k < mb.len and s.insts[mb[k]].op == .phi) : (k += 1) {
            const inst = &s.insts[mb[k]];
            var vals: [2]?Value = .{ null, null };
            for (inst.op.phi.incoming) |in| {
                const from = s.find(in.block);
                if (from == via[0]) vals[0] = in.val else if (from == via[1]) vals[1] = in.val;
            }
            if (vals[0] == null or vals[1] == null) return false;
        }
        k = 0;
        while (k < mb.len and s.insts[mb[k]].op == .phi) : (k += 1) {
            const inst = &s.insts[mb[k]];
            var vals: [2]Value = undefined;
            for (inst.op.phi.incoming) |in| {
                const from = s.find(in.block);
                if (from == via[0]) vals[0] = in.val else if (from == via[1]) vals[1] = in.val;
            }
            if (std.meta.eql(vals[0], vals[1])) {
                s.repl[mb[k]] = vals[0];
            } else inst.op = .{ .select = .{ .cond = cond, .t = vals[0], .f = vals[1] } };
        }
        // `p` goes to `m`, running what the arms did first; their blocks
        // go.
        for (via) |v| if (v != p) try s.hoist(v, p);
        s.term(p).op = .{ .br = .{ .then = m } };
        for (via) |v| if (v != p) {
            s.alive[v] = false;
            s.preds[v].clearRetainingCapacity();
        };
        s.preds[m].clearRetainingCapacity();
        try s.preds[m].append(s.a, p);
        return true;
    }

    /// Bypasses `b` (only `br c`): its predecessors branch to `c`.
    fn bypass(s: *State, b: u32, c: u32) Allocator.Error!void {
        const ps = try s.a.dupe(u32, s.preds[b].items);
        const phis = s.hasPhis(c);
        // `c`'s phis: the input from `b` comes from each of `b`'s
        // predecessors instead.
        const cb = s.body[c].items;
        var k: usize = 0;
        while (k < cb.len and s.insts[cb[k]].op == .phi) : (k += 1) {
            const phi = &s.insts[cb[k]].op.phi;
            var out: std.ArrayList(Edge) = .empty;
            try out.ensureTotalCapacity(s.a, phi.incoming.len + ps.len);
            for (phi.incoming) |in| {
                if (s.find(in.block) == b) {
                    for (ps) |p| out.appendAssumeCapacity(.{ .val = in.val, .block = p });
                } else out.appendAssumeCapacity(in);
            }
            phi.incoming = out.items;
        }
        // (Each distinct predecessor once: retarget moves all its edges.)
        for (ps, 0..) |p, i| {
            if (std.mem.indexOfScalar(u32, ps[0..i], p) != null) continue;
            try s.retarget(p, b, c);
        }
        s.removePred(c, b);
        try s.preds[c].appendSlice(s.a, ps);
        s.preds[b].clearRetainingCapacity();
        s.alive[b] = false;
        // A conditional branch now going to `c` both ways goes there
        // unconditionally (when `c` has no phis to give two inputs).
        if (!phis) for (ps) |p| {
            const t = s.term(p);
            if (t.op == .br) if (t.op.br.@"else") |e| if (e == t.op.br.then) {
                t.op.br = .{ .then = e };
                s.removePred(c, p);
            };
        };
    }
};

/// Simplifies `func`'s control flow; true if anything changed.
pub fn run(a: Allocator, m: *module.Module, func: u32) Allocator.Error!bool {
    const zone = stats.begin(.cfg);
    defer zone.end();
    const f = &m.functions.items[func];
    const nb = f.num_blocks;
    const n: u32 = @intCast(f.insts.items.len);
    if (nb < 2) return false;

    var s: State = .{
        .a = a,
        .m = m,
        .insts = try a.dupe(Inst, f.insts.items),
        .body = try a.alloc(std.ArrayList(u32), nb),
        .preds = try a.alloc(std.ArrayList(u32), nb),
        .owner = try a.alloc(u32, nb),
        .alive = try a.alloc(bool, nb),
        .repl = try a.alloc(?Value, n),
    };
    @memset(s.repl, null);
    @memset(s.alive, true);
    for (s.owner, 0..) |*o, b| o.* = @intCast(b);
    {
        var b: u32 = 0;
        var start: u32 = 0;
        for (s.insts, 0..) |inst, i| {
            if (!isTerminator(inst)) continue;
            if (b >= nb) return false; // not the block layout expected
            s.body[b] = .empty;
            try s.body[b].ensureTotalCapacity(a, i + 1 - start);
            for (start..i + 1) |k| s.body[b].appendAssumeCapacity(@intCast(k));
            start = @intCast(i + 1);
            b += 1;
        }
        if (b != nb or start != n) return false;
    }
    for (s.preds) |*p| p.* = .empty;
    for (0..nb) |b| {
        const t = s.term(@intCast(b)).*;
        switch (t.op) {
            .br => |br| {
                try s.preds[br.then].append(a, @intCast(b));
                if (br.@"else") |e| try s.preds[e].append(a, @intCast(b));
            },
            .@"switch" => |sw| {
                try s.preds[sw.default].append(a, @intCast(b));
                for (sw.cases) |c| try s.preds[c.block].append(a, @intCast(b));
            },
            else => {},
        }
    }

    var changed = false;
    var again = true;
    while (again) {
        again = false;
        for (0..nb) |bi| {
            const b: u32 = @intCast(bi);
            if (!s.alive[b]) continue;
            // Take in the chain of blocks only `b` leads to.
            while (true) {
                const t = s.term(b).*;
                if (t.op != .br or t.op.br.@"else" != null) break;
                const c = t.op.br.then;
                if (c == b or c == 0 or s.preds[c].items.len != 1) break;
                try s.merge(b, c);
                changed = true;
                again = true;
            }
        }
        for (1..nb) |bi| {
            const b: u32 = @intCast(bi);
            if (!s.alive[b] or s.body[b].items.len != 1) continue;
            const t = s.term(b).*;
            if (t.op != .br or t.op.br.@"else" != null) continue;
            const c = t.op.br.then;
            const ps = s.preds[b].items;
            if (c == b or ps.len == 0) continue;
            if (std.mem.indexOfScalar(u32, ps, b) != null) continue;
            // With phis in `c`, a predecessor already branching there could
            // need two values on one edge: left alone.
            if (s.hasPhis(c)) {
                const clash = for (ps) |p| {
                    if (s.countPred(c, p) != 0) break true;
                } else false;
                if (clash) continue;
            }
            try s.bypass(b, c);
            changed = true;
            again = true;
        }
        for (0..nb) |bi| {
            const b: u32 = @intCast(bi);
            if (!s.alive[b] or !try s.collapse(b)) continue;
            changed = true;
            again = true;
        }
        for (1..nb) |bi| {
            const b: u32 = @intCast(bi);
            if (!s.alive[b] or !try s.ifConvert(b)) continue;
            changed = true;
            again = true;
        }
    }
    if (!changed) return false;

    // Lay the blocks out again, in their old order, and renumber.
    const new_block = try a.alloc(u32, nb);
    var kept: u32 = 0;
    for (0..nb) |b| {
        new_block[b] = if (s.alive[b]) kept else none;
        if (s.alive[b]) kept += 1;
    }
    const index = try a.alloc(u32, n);
    @memset(index, none);
    var count: u32 = 0;
    for (0..nb) |b| if (s.alive[b]) for (s.body[b].items) |i| {
        if (s.repl[i] != null) continue;
        index[i] = count;
        count += 1;
    };
    const Map = struct {
        repl: []const ?Value,
        index: []const u32,
        pub fn visit(ctx: *@This(), v: Value, _: promote.Role) Value {
            var x = v;
            while (x == .inst) {
                const r = ctx.repl[x.inst] orelse break;
                x = r;
            }
            return if (x == .inst) .{ .inst = ctx.index[x.inst] } else x;
        }
    };
    var map: Map = .{ .repl = s.repl, .index = index };
    const ma = m.allocator();
    var out: std.ArrayList(Inst) = .empty;
    try out.ensureTotalCapacityPrecise(ma, count);
    for (0..nb) |b| if (s.alive[b]) for (s.body[b].items) |i| {
        if (s.repl[i] != null) continue;
        var inst = s.insts[i];
        try promote.operands(true, ma, &inst, &map);
        switch (inst.op) {
            .phi => |*p| {
                const es: []Edge = @constCast(p.incoming);
                for (es) |*e| e.block = new_block[s.find(e.block)];
            },
            .br => |*br| {
                br.then = new_block[br.then];
                if (br.@"else") |*e| e.* = new_block[e.*];
            },
            .@"switch" => |*sw| {
                sw.default = new_block[sw.default];
                const cs = try ma.alloc(Case, sw.cases.len);
                for (sw.cases, cs) |c, *o| o.* = .{ .val = c.val, .block = new_block[c.block] };
                sw.cases = cs;
            },
            else => {},
        }
        out.appendAssumeCapacity(inst);
    };
    f.insts = out;
    f.num_blocks = kept;
    return true;
}
