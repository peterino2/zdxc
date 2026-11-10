//! EXPERIMENT (not for landing yet): region melding. Mutually exclusive
//! copies of one single-entry, single-exit region (the arms of a switch
//! that inline the same helpers) become one copy that every arm runs.
//!
//! A region (s, t) is the blocks reachable from `s` without passing `t`,
//! where `t` post-dominates `s`, every block but `s` is entered only from
//! the region, and `s` has no phis. Copies are isomorphic block by block
//! and instruction by instruction, up to scalar values they read from
//! outside (constant call arguments must agree); mutually exclusive
//! (neither entry reaches the other without a back edge); in the same
//! loop; and leave to different blocks. Merging them then keeps the
//! control flow reducible.
//!
//! The first copy stays. Each copy's entry edges go through a new block
//! that stores the copy's differing inputs and its number in new locals;
//! the kept copy reads its inputs from them; its exits go to a new block
//! that switches on the number to each copy's exit. The exits' phis become
//! locals, stored at the end of each predecessor. Values whose definitions
//! no longer dominate their uses go through locals too; promote.run then
//! turns the locals back into SSA values.

const std = @import("std");
const Allocator = std.mem.Allocator;
const module = @import("module.zig");
const promote = @import("promote.zig");
const exp = @import("exp.zig");

const Value = module.Value;
const Inst = module.Inst;
const TypeId = module.TypeId;

const Edge = @typeInfo(@FieldType(@FieldType(@FieldType(Inst, "op"), "phi"), "incoming")).pointer.child;
const Case = @typeInfo(@FieldType(@FieldType(@FieldType(Inst, "op"), "switch"), "cases")).pointer.child;
const none = std.math.maxInt(u32);

/// Regions grow up the post-dominator tree this many steps at most, and
/// to this many instructions.
const max_steps = 10;
const max_size = 6000;

fn isTerminator(inst: Inst) bool {
    return switch (inst.op) {
        .ret, .br, .@"switch", .@"unreachable" => true,
        else => false,
    };
}

// ---------------------------------------------------------------------
// Operands by slot

fn opCount(inst: Inst) usize {
    return switch (inst.op) {
        .ret => |v| @intFromBool(v != null),
        .br => |b| @intFromBool(b.cond != null),
        .@"switch" => 1,
        .call => |c| c.args.len,
        .binop, .cmp, .store, .atomicrmw, .extractelement => 2,
        .cast, .extractvalue, .alloca, .load => 1,
        .select, .cmpxchg, .insertelement => 3,
        .phi => |p| p.incoming.len,
        .gep => |g| 1 + g.indices.len,
        .@"unreachable" => 0,
    };
}

fn getOp(inst: Inst, k: usize) Value {
    return switch (inst.op) {
        .ret => |v| v.?,
        .br => |b| b.cond.?,
        .@"switch" => |sw| sw.cond,
        .call => |c| c.args[k],
        .binop => |b| if (k == 0) b.lhs else b.rhs,
        .cmp => |c| if (k == 0) c.lhs else c.rhs,
        .cast => |c| c.val,
        .extractvalue => |x| x.agg,
        .alloca => |x| x.size,
        .load => |x| x.ptr,
        .select => |s| switch (k) {
            0 => s.cond,
            1 => s.t,
            else => s.f,
        },
        .phi => |p| p.incoming[k].val,
        .store => |s| if (k == 0) s.ptr else s.val,
        .gep => |g| if (k == 0) g.ptr else g.indices[k - 1],
        .atomicrmw => |x| if (k == 0) x.ptr else x.val,
        .cmpxchg => |x| switch (k) {
            0 => x.ptr,
            1 => x.cmp,
            else => x.new,
        },
        .@"unreachable" => unreachable,
        .extractelement => |x| if (k == 0) x.vec else x.index,
        .insertelement => |x| switch (k) {
            0 => x.vec,
            1 => x.val,
            else => x.index,
        },
    };
}

fn setOp(ma: Allocator, inst: *Inst, k: usize, v: Value) Allocator.Error!void {
    switch (inst.op) {
        .ret => |*x| x.* = v,
        .br => |*b| b.cond = v,
        .@"switch" => |*sw| sw.cond = v,
        .call => |*c| {
            const args = try ma.dupe(Value, c.args);
            args[k] = v;
            c.args = args;
        },
        .binop => |*b| if (k == 0) {
            b.lhs = v;
        } else {
            b.rhs = v;
        },
        .cmp => |*c| if (k == 0) {
            c.lhs = v;
        } else {
            c.rhs = v;
        },
        .cast => |*c| c.val = v,
        .extractvalue => |*x| x.agg = v,
        .alloca => |*x| x.size = v,
        .load => |*x| x.ptr = v,
        .select => |*s| switch (k) {
            0 => s.cond = v,
            1 => s.t = v,
            else => s.f = v,
        },
        .phi => |*p| {
            const ins = try ma.dupe(Edge, p.incoming);
            ins[k].val = v;
            p.incoming = ins;
        },
        .store => |*s| if (k == 0) {
            s.ptr = v;
        } else {
            s.val = v;
        },
        .gep => |*g| if (k == 0) {
            g.ptr = v;
        } else {
            const ix = try ma.dupe(Value, g.indices);
            ix[k - 1] = v;
            g.indices = ix;
        },
        .atomicrmw => |*x| if (k == 0) {
            x.ptr = v;
        } else {
            x.val = v;
        },
        .cmpxchg => |*x| switch (k) {
            0 => x.ptr = v,
            1 => x.cmp = v,
            else => x.new = v,
        },
        .@"unreachable" => unreachable,
        .extractelement => |*x| if (k == 0) {
            x.vec = v;
        } else {
            x.index = v;
        },
        .insertelement => |*x| switch (k) {
            0 => x.vec = v,
            1 => x.val = v,
            else => x.index = v,
        },
    }
}

/// Whether operand `k` of `inst` may read a different value in each copy:
/// an arithmetic, comparison, selection or phi input, a stored value, a
/// branch condition, or a call argument that is no constant in either.
fn mayDiffer(inst: Inst, k: usize) enum { no, value, nonconst } {
    return switch (inst.op) {
        .call => .nonconst,
        .binop, .cmp, .cast, .select, .phi, .br, .@"switch" => .value,
        .store => if (k == 1) .value else .no,
        .extractelement => if (k == 0) .value else .no,
        .insertelement => if (k < 2) .value else .no,
        else => .no,
    };
}

/// The same instruction but for its operands (and phi blocks, branch
/// targets: compared by the caller).
fn sameShape(x: Inst, y: Inst) bool {
    if (x.ty != y.ty or x.md != y.md) return false;
    if (std.meta.activeTag(x.op) != std.meta.activeTag(y.op)) return false;
    return switch (x.op) {
        .ret => |v| (v == null) == (y.op.ret == null),
        .br => |b| (b.cond == null) == (y.op.br.cond == null) and (b.@"else" == null) == (y.op.br.@"else" == null),
        .@"switch" => |sw| blk: {
            const o = y.op.@"switch";
            if (sw.cases.len != o.cases.len) break :blk false;
            for (sw.cases, o.cases) |p, q| if (!std.meta.eql(p.val, q.val)) break :blk false;
            break :blk true;
        },
        .call => |c| c.callee == y.op.call.callee and c.args.len == y.op.call.args.len,
        .binop => |b| b.op == y.op.binop.op and b.flags == y.op.binop.flags,
        .cast => |c| c.op == y.op.cast.op,
        .cmp => |c| c.pred == y.op.cmp.pred,
        .extractvalue => |e| e.index == y.op.extractvalue.index,
        .phi => |p| p.incoming.len == y.op.phi.incoming.len,
        .alloca => |al| al.elem == y.op.alloca.elem,
        .load => |l| l.@"align" == y.op.load.@"align",
        .store => |s| s.@"align" == y.op.store.@"align",
        .gep => |g| g.elem == y.op.gep.elem and g.indices.len == y.op.gep.indices.len,
        .atomicrmw => |r| r.op == y.op.atomicrmw.op,
        .select, .cmpxchg, .@"unreachable", .extractelement, .insertelement => true,
    };
}

fn mix(x: u64) u64 {
    var z = x;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

fn shapeKey(inst: Inst) u64 {
    var h: u64 = mix(@as(u64, @backingInt(std.meta.activeTag(inst.op))) << 40 | inst.ty);
    h = mix(h ^ @backingInt(inst.md));
    switch (inst.op) {
        .call => |c| h = mix(h ^ (@as(u64, c.callee) << 8) ^ c.args.len),
        .binop => |b| h = mix(h ^ (@as(u64, @backingInt(b.op)) << 32) ^ b.flags),
        .cast => |c| h = mix(h ^ @backingInt(c.op)),
        .cmp => |c| h = mix(h ^ c.pred),
        .extractvalue => |e| h = mix(h ^ e.index),
        .phi => |p| h = mix(h ^ p.incoming.len),
        .gep => |g| h = mix(h ^ (@as(u64, g.elem) << 16) ^ g.indices.len),
        .@"switch" => |sw| {
            h = mix(h ^ sw.cases.len);
            for (sw.cases) |c| h = mix(h ^ std.hash.Wyhash.hash(0, std.mem.asBytes(&c.val)));
        },
        else => {},
    }
    return h;
}

// ---------------------------------------------------------------------
// The control-flow graph

const Graph = struct {
    nb: u32,
    block_start: []u32,
    block_of: []u32,
    succ_off: []u32,
    succs: []u32,
    pred_off: []u32,
    preds: []u32,
    rpo: []u32,
    nr: u32,
    rpo_index: []u32,
    idom: []u32,
    /// Dominator tree intervals.
    pre: []u32,
    post: []u32,
    /// Immediate post-dominator: a block, `nb` (the exit) or `none`.
    ipdom: []u32,
    /// Innermost loop (its header) holding each block; a header's parent
    /// loop.
    inner: []u32,
    loop_parent: []u32,
    words: usize,
    /// Forward reachability (back edges removed), `words` per block.
    fwd: []u64,

    fn succOf(g: *const Graph, b: u32) []const u32 {
        return g.succs[g.succ_off[b]..g.succ_off[b + 1]];
    }

    fn predOf(g: *const Graph, b: u32) []const u32 {
        return g.preds[g.pred_off[b]..g.pred_off[b + 1]];
    }

    fn reachable(g: *const Graph, b: u32) bool {
        return g.rpo_index[b] != none;
    }

    fn dominates(g: *const Graph, x: u32, y: u32) bool {
        return g.pre[x] <= g.pre[y] and g.post[y] <= g.post[x];
    }

    fn reaches(g: *const Graph, x: u32, y: u32) bool {
        return (g.fwd[x * g.words + y / 64] >> @intCast(y % 64)) & 1 != 0;
    }

    /// Nearest common dominator.
    fn ncd(g: *const Graph, x: u32, y: u32) u32 {
        var p = x;
        var q = y;
        while (p != q) {
            while (g.rpo_index[p] > g.rpo_index[q]) p = g.idom[p];
            while (g.rpo_index[q] > g.rpo_index[p]) q = g.idom[q];
        }
        return p;
    }
};

fn idoms(a: Allocator, nodes: u32, rpo: []const u32, rpo_index: []const u32, pred_off: []const u32, preds: []const u32) Allocator.Error![]u32 {
    const idom = try a.alloc(u32, nodes);
    @memset(idom, none);
    if (rpo.len == 0) return idom;
    idom[rpo[0]] = rpo[0];
    var changed = true;
    while (changed) {
        changed = false;
        for (rpo[1..]) |b| {
            var new: u32 = none;
            for (preds[pred_off[b]..pred_off[b + 1]]) |p| {
                if (idom[p] == none) continue;
                if (new == none) {
                    new = p;
                    continue;
                }
                var x = p;
                var y = new;
                while (x != y) {
                    while (rpo_index[x] > rpo_index[y]) x = idom[x];
                    while (rpo_index[y] > rpo_index[x]) y = idom[y];
                }
                new = x;
            }
            if (new != idom[b]) {
                idom[b] = new;
                changed = true;
            }
        }
    }
    return idom;
}

/// Reverse postorder from `root` over successor lists.
fn order(a: Allocator, nodes: u32, root: u32, succ_off: []const u32, succs: []const u32) Allocator.Error!struct { rpo: []u32, index: []u32 } {
    const index = try a.alloc(u32, nodes);
    @memset(index, none);
    const post = try a.alloc(u32, nodes);
    var np: u32 = 0;
    const seen = try a.alloc(bool, nodes);
    @memset(seen, false);
    const Frame = struct { b: u32, next: u32 };
    var stack: std.ArrayList(Frame) = .empty;
    try stack.append(a, .{ .b = root, .next = succ_off[root] });
    seen[root] = true;
    while (stack.items.len > 0) {
        const top = &stack.items[stack.items.len - 1];
        if (top.next < succ_off[top.b + 1]) {
            const s = succs[top.next];
            top.next += 1;
            if (!seen[s]) {
                seen[s] = true;
                try stack.append(a, .{ .b = s, .next = succ_off[s] });
            }
        } else {
            post[np] = top.b;
            np += 1;
            _ = stack.pop();
        }
    }
    const rpo = try a.alloc(u32, np);
    for (0..np) |k| {
        rpo[k] = post[np - 1 - k];
        index[rpo[k]] = @intCast(k);
    }
    return .{ .rpo = rpo, .index = index };
}

fn build(a: Allocator, insts: []const Inst, nb: u32, full: bool) Allocator.Error!?Graph {
    const n: u32 = @intCast(insts.len);
    var g: Graph = undefined;
    g.nb = nb;
    g.block_start = try a.alloc(u32, nb + 1);
    g.block_of = try a.alloc(u32, n);
    {
        var b: u32 = 0;
        g.block_start[0] = 0;
        for (insts, 0..) |inst, i| {
            if (b >= nb) return null;
            g.block_of[i] = b;
            if (isTerminator(inst)) {
                b += 1;
                g.block_start[b] = @intCast(i + 1);
            }
        }
        if (b != nb) return null;
    }
    var succs: std.ArrayList(u32) = .empty;
    g.succ_off = try a.alloc(u32, nb + 2);
    for (0..nb) |b| {
        g.succ_off[b] = @intCast(succs.items.len);
        switch (insts[g.block_start[b + 1] - 1].op) {
            .br => |br| {
                try succs.append(a, br.then);
                if (br.@"else") |e| try succs.append(a, e);
            },
            .@"switch" => |sw| {
                try succs.append(a, sw.default);
                for (sw.cases) |c| try succs.append(a, c.block);
            },
            else => {},
        }
    }
    g.succ_off[nb] = @intCast(succs.items.len);
    g.succ_off[nb + 1] = g.succ_off[nb];
    g.succs = succs.items;
    g.pred_off = try a.alloc(u32, nb + 1);
    @memset(g.pred_off, 0);
    for (g.succs) |s| g.pred_off[s + 1] += 1;
    for (1..nb + 1) |b| g.pred_off[b] += g.pred_off[b - 1];
    g.preds = try a.alloc(u32, g.succs.len);
    {
        const fill = try a.dupe(u32, g.pred_off[0..nb]);
        for (0..nb) |b| for (g.succOf(@intCast(b))) |s| {
            g.preds[fill[s]] = @intCast(b);
            fill[s] += 1;
        };
    }
    const o = try order(a, nb, 0, g.succ_off, g.succs);
    g.rpo = o.rpo;
    g.nr = @intCast(o.rpo.len);
    g.rpo_index = o.index;
    // Dominators of reachable blocks (unreachable predecessors skipped).
    {
        const rp_off = try a.alloc(u32, nb + 1);
        var rps: std.ArrayList(u32) = .empty;
        for (0..nb) |b| {
            rp_off[b] = @intCast(rps.items.len);
            for (g.predOf(@intCast(b))) |p| if (g.rpo_index[p] != none) try rps.append(a, p);
        }
        rp_off[nb] = @intCast(rps.items.len);
        g.idom = try idoms(a, nb, g.rpo, g.rpo_index, rp_off, rps.items);
    }
    // Dominator tree intervals.
    g.pre = try a.alloc(u32, nb);
    g.post = try a.alloc(u32, nb);
    @memset(g.pre, none);
    @memset(g.post, 0);
    {
        const child_off = try a.alloc(u32, nb + 1);
        @memset(child_off, 0);
        for (g.rpo[1..]) |b| child_off[g.idom[b] + 1] += 1;
        for (1..nb + 1) |b| child_off[b] += child_off[b - 1];
        const children = try a.alloc(u32, if (g.nr > 0) g.nr - 1 else 0);
        const fill = try a.dupe(u32, child_off[0..nb]);
        for (g.rpo[1..]) |b| {
            children[fill[g.idom[b]]] = b;
            fill[g.idom[b]] += 1;
        }
        var clock: u32 = 0;
        const Frame = struct { b: u32, next: u32 };
        var stack: std.ArrayList(Frame) = .empty;
        try stack.append(a, .{ .b = 0, .next = child_off[0] });
        g.pre[0] = clock;
        clock += 1;
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            if (top.next < child_off[top.b + 1]) {
                const c = children[top.next];
                top.next += 1;
                g.pre[c] = clock;
                clock += 1;
                try stack.append(a, .{ .b = c, .next = child_off[c] });
            } else {
                g.post[top.b] = clock;
                clock += 1;
                _ = stack.pop();
            }
        }
    }
    if (!full) return g;

    // Post-dominators: the reverse graph from an exit node (`nb`) that
    // every block without successors leads to.
    {
        const nodes = nb + 1;
        // Reverse successors: a block's (reachable) predecessors; the
        // exit's: the blocks without successors.
        const rs_off = try a.alloc(u32, nodes + 1);
        var rs: std.ArrayList(u32) = .empty;
        for (0..nb) |b| {
            rs_off[b] = @intCast(rs.items.len);
            for (g.predOf(@intCast(b))) |p| if (g.rpo_index[p] != none) try rs.append(a, p);
        }
        rs_off[nb] = @intCast(rs.items.len);
        for (g.rpo) |b| if (g.succOf(b).len == 0) try rs.append(a, b);
        rs_off[nodes] = @intCast(rs.items.len);
        // Reverse predecessors: successors, and the exit for blocks
        // without them.
        const rp_off = try a.alloc(u32, nodes + 1);
        var rp: std.ArrayList(u32) = .empty;
        for (0..nb) |b| {
            rp_off[b] = @intCast(rp.items.len);
            if (g.rpo_index[b] == none) continue;
            const ss = g.succOf(@intCast(b));
            if (ss.len == 0) try rp.append(a, nb) else try rp.appendSlice(a, ss);
        }
        rp_off[nb] = @intCast(rp.items.len);
        rp_off[nodes] = @intCast(rp.items.len);
        const ro = try order(a, nodes, nb, rs_off, rs.items);
        g.ipdom = try idoms(a, nodes, ro.rpo, ro.index, rp_off, rp.items);
    }

    // Loops: back edges (to a block dominating the source); natural loop
    // bodies, inner ones (later in reverse postorder) last.
    g.inner = try a.alloc(u32, nb);
    @memset(g.inner, none);
    g.loop_parent = try a.alloc(u32, nb);
    @memset(g.loop_parent, none);
    {
        const in_loop = try a.alloc(u32, nb);
        @memset(in_loop, none);
        var work: std.ArrayList(u32) = .empty;
        for (g.rpo) |h| {
            var header = false;
            for (g.predOf(h)) |p| {
                if (g.rpo_index[p] == none or !g.dominates(h, p)) continue;
                if (!header) {
                    header = true;
                    g.loop_parent[h] = g.inner[h];
                    g.inner[h] = h;
                    in_loop[h] = h;
                }
                if (in_loop[p] != h) {
                    in_loop[p] = h;
                    try work.append(a, p);
                }
            }
            while (work.pop()) |x| {
                g.inner[x] = h;
                for (g.predOf(x)) |p| {
                    if (g.rpo_index[p] == none or in_loop[p] == h) continue;
                    in_loop[p] = h;
                    try work.append(a, p);
                }
            }
        }
    }

    // Forward reachability, in reverse topological order of the edges that
    // are not back edges.
    g.words = (nb + 63) / 64;
    g.fwd = try a.alloc(u64, @as(usize, nb) * g.words);
    @memset(g.fwd, 0);
    {
        var k = g.nr;
        while (k > 0) {
            k -= 1;
            const b = g.rpo[k];
            const row = g.fwd[b * g.words ..][0..g.words];
            row[b / 64] |= @as(u64, 1) << @intCast(b % 64);
            for (g.succOf(b)) |s| {
                if (g.dominates(s, b)) continue; // back edge
                const srow = g.fwd[s * g.words ..][0..g.words];
                for (row, srow) |*x, y| x.* |= y;
            }
        }
    }
    return g;
}

// ---------------------------------------------------------------------
// Regions

const Region = struct {
    s: u32,
    t: u32,
    /// Depth-first preorder from `s`, successors in order.
    blocks: []const u32,
    size: u32,
    hash: u64,
    /// The hash without the blocks that may differ between copies (holes:
    /// see Ctx.holeOk); `hash` when those are most of the region.
    skel: u64,
    /// The innermost loop around the region (its header), `none` at top.
    ctx: u32,
};

/// Positions of a region's blocks and instructions (valid while `stamp`
/// marks them).
const Maps = struct {
    stamp: u32 = 0,
    bst: []u32,
    bpos: []u32,
    ist: []u32,
    ipos: []u32,

    fn init(a: Allocator, nb: usize, n: usize) Allocator.Error!Maps {
        const mp: Maps = .{ .bst = try a.alloc(u32, nb), .bpos = try a.alloc(u32, nb), .ist = try a.alloc(u32, n), .ipos = try a.alloc(u32, n) };
        @memset(mp.bst, 0);
        @memset(mp.ist, 0);
        return mp;
    }

    fn fill(mp: *Maps, g: *const Graph, blocks: []const u32) void {
        mp.stamp += 1;
        var k: u32 = 0;
        for (blocks, 0..) |b, bi| {
            mp.bst[b] = mp.stamp;
            mp.bpos[b] = @intCast(bi);
            for (g.block_start[b]..g.block_start[b + 1]) |i| {
                mp.ist[i] = mp.stamp;
                mp.ipos[i] = k;
                k += 1;
            }
        }
    }

    fn hasBlock(mp: *const Maps, b: u32) bool {
        return mp.bst[b] == mp.stamp;
    }

    fn hasInst(mp: *const Maps, v: Value) bool {
        return v == .inst and mp.ist[v.inst] == mp.stamp;
    }
};

const Ctx = struct {
    a: Allocator,
    m: *module.Module,
    func: u32,
    insts: []const Inst,
    g: Graph,
    ma: Maps,
    mb: Maps,
    user_off: []u32 = &.{},
    user_list: []u32 = &.{},

    fn typeOf(c: *const Ctx, v: Value) TypeId {
        return switch (v) {
            .constant => |k| c.m.constants.items[k].ty,
            .inst => |i| c.insts[i].ty,
            .arg => |x| c.m.types.items[c.m.functions.items[c.func].ty].function.params[x],
            .global => |x| c.m.globals.items[x].ptr_ty,
            .function => none,
        };
    }

    fn isScalar(c: *const Ctx, ty: TypeId) bool {
        if (ty == none) return false;
        return switch (c.m.types.items[ty]) {
            .half, .float, .double, .int => true,
            else => false,
        };
    }

    /// Instructions a merged region must not hold: ones whose result
    /// depends on which lanes run them together.
    fn forbidden(c: *const Ctx, inst: Inst) bool {
        return switch (inst.op) {
            .alloca, .ret => true,
            .call => |cl| blk: {
                const name = c.m.functions.items[cl.callee].name;
                if (!std.mem.startsWith(u8, name, "dx.op.")) break :blk true;
                break :blk promote.isWaveOp(name) or std.mem.startsWith(u8, name, "dx.op.barrier");
            },
            else => false,
        };
    }

    /// Region (s, t) into `out` (depth-first preorder), or null when it is
    /// too big; `valid` false when it has another entry.
    fn collect(c: *Ctx, s: u32, t: u32, out: *std.ArrayList(u32), stack: *std.ArrayList([2]u32)) Allocator.Error!?bool {
        const g = &c.g;
        const mp = &c.ma;
        mp.stamp += 1;
        out.clearRetainingCapacity();
        stack.clearRetainingCapacity();
        var size: u32 = 0;
        mp.bst[s] = mp.stamp;
        try out.append(c.a, s);
        size += g.block_start[s + 1] - g.block_start[s];
        try stack.append(c.a, .{ s, 0 });
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const ss = g.succOf(top[0]);
            if (top[1] >= ss.len) {
                _ = stack.pop();
                continue;
            }
            const x = ss[top[1]];
            top[1] += 1;
            if (x == t or mp.bst[x] == mp.stamp) continue;
            if (x == 0) return false;
            mp.bst[x] = mp.stamp;
            try out.append(c.a, x);
            size += g.block_start[x + 1] - g.block_start[x];
            if (size > max_size) return null;
            try stack.append(c.a, .{ x, 0 });
        }
        for (out.items[1..]) |b| for (g.predOf(b)) |p| {
            if (g.reachable(p) and mp.bst[p] != mp.stamp) return false;
        };
        return true;
    }

    /// Hash of the region in `blocks` (exit `t`), or null if it holds an
    /// instruction no merged region may.
    fn hashRegion(c: *Ctx, blocks: []const u32, t: u32) ?[2]u64 {
        const g = &c.g;
        c.ma.fill(g, blocks);
        var h: u64 = mix(blocks.len);
        for (blocks) |b| {
            h = mix(h ^ (g.block_start[b + 1] - g.block_start[b]));
            for (g.block_start[b]..g.block_start[b + 1]) |i| {
                const inst = c.insts[i];
                if (c.forbidden(inst)) return null;
                h = mix(h ^ shapeKey(inst));
                const call = inst.op == .call;
                for (0..opCount(inst)) |k| {
                    const v = getOp(inst, k);
                    if (c.ma.hasInst(v)) {
                        h = mix(h ^ (1 << 62 | @as(u64, c.ma.ipos[v.inst])));
                    } else if (call and v == .constant) {
                        h = mix(h ^ (2 << 62 | @as(u64, v.constant)));
                    } else h = mix(h ^ (3 << 62));
                }
                if (inst.op == .phi) for (inst.op.phi.incoming) |in| {
                    h = mix(h ^ (if (c.ma.hasBlock(in.block)) c.ma.bpos[in.block] else none));
                };
            }
            for (g.succOf(b)) |s| {
                const tok: u64 = if (s == t) 1 << 40 else if (c.ma.hasBlock(s)) c.ma.bpos[s] else 2 << 40;
                h = mix(h ^ tok);
            }
        }
        if (exp.cur.meld_noholes) return .{ h, h };
        // The skeleton, for copies that may differ in their straight
        // blocks (holes): the blocks' successors and phis, and the
        // contents of the largest block (holes are each copy's own,
        // smaller code around shared code).
        var big: usize = 0;
        var big_len: u32 = 0;
        var sk: u64 = mix(blocks.len ^ 0x5eed);
        for (blocks, 0..) |b, bi| {
            const len = g.block_start[b + 1] - g.block_start[b];
            if (len > big_len) {
                big_len = len;
                big = bi;
            }
            var phis: u32 = 0;
            while (phis < len and c.insts[g.block_start[b] + phis].op == .phi) phis += 1;
            sk = mix(sk ^ phis ^ (@as(u64, @backingInt(std.meta.activeTag(c.insts[g.block_start[b + 1] - 1].op))) << 16));
            if (!c.holeOk(blocks[0], t, b)) sk = mix(sk ^ len);
            for (g.succOf(b)) |s| {
                const tok: u64 = if (s == t) 1 << 40 else if (c.ma.hasBlock(s)) c.ma.bpos[s] else 2 << 40;
                sk = mix(sk ^ tok);
            }
        }
        const bb = blocks[big];
        sk = mix(sk ^ big ^ (@as(u64, big_len) << 32));
        for (g.block_start[bb]..g.block_start[bb + 1]) |i| {
            const inst = c.insts[i];
            sk = mix(sk ^ shapeKey(inst));
            for (0..opCount(inst)) |k| {
                const v = getOp(inst, k);
                if (v == .inst and g.block_of[v.inst] == bb) {
                    sk = mix(sk ^ (1 << 62 | @as(u64, v.inst - g.block_start[bb])));
                } else if (inst.op == .call and v == .constant) {
                    sk = mix(sk ^ (2 << 62 | @as(u64, v.constant)));
                } else sk = mix(sk ^ (3 << 62));
            }
        }
        return .{ h, sk };
    }

    /// Whether block `b` of the region (s, t) may be a hole: a block whose
    /// instructions may differ between copies, each copy's own run in the
    /// merged copy by a switch on the copy's number. A straight block
    /// inside the region: one successor (not the exit), no phis, not the
    /// entry.
    fn holeOk(c: *const Ctx, s: u32, t: u32, b: u32) bool {
        const g = &c.g;
        if (b == s) return false;
        if (c.insts[g.block_start[b]].op == .phi) return false;
        const term = c.insts[g.block_start[b + 1] - 1];
        if (term.op != .br or term.op.br.@"else" != null) return false;
        return term.op.br.then != t and term.op.br.then != s;
    }

    fn sameBlock(c: *const Ctx, ba: u32, bb: u32) bool {
        const g = &c.g;
        const la = g.block_start[ba + 1] - g.block_start[ba];
        if (la != g.block_start[bb + 1] - g.block_start[bb]) return false;
        for (0..la) |o| if (!sameShape(c.insts[g.block_start[ba] + o], c.insts[g.block_start[bb] + o])) return false;
        return true;
    }

    /// Each instruction's users (instructions reading it), built on first
    /// use.
    fn users(c: *Ctx, v: u32) Allocator.Error![]const u32 {
        if (c.user_off.len == 0) {
            const n = c.insts.len;
            c.user_off = try c.a.alloc(u32, n + 1);
            @memset(c.user_off, 0);
            for (c.insts) |inst| for (0..opCount(inst)) |k| {
                const x = getOp(inst, k);
                if (x == .inst) c.user_off[x.inst + 1] += 1;
            };
            for (1..n + 1) |i| c.user_off[i] += c.user_off[i - 1];
            c.user_list = try c.a.alloc(u32, c.user_off[n]);
            const fill = try c.a.dupe(u32, c.user_off[0..n]);
            for (c.insts, 0..) |inst, i| for (0..opCount(inst)) |k| {
                const x = getOp(inst, k);
                if (x != .inst) continue;
                c.user_list[fill[x.inst]] = @intCast(i);
                fill[x.inst] += 1;
            };
        }
        return c.user_list[c.user_off[v]..c.user_off[v + 1]];
    }

    /// Values merging would carry through the kept copy: defined between
    /// the copies' common dominator and a copy's entry, read where that
    /// copy's exit leads.
    fn liveThrough(c: *Ctx, rs: []const *const Region) Allocator.Error!u32 {
        const g = &c.g;
        var d = rs[0].s;
        for (rs[1..]) |r| d = g.ncd(d, r.s);
        var total: u32 = 0;
        for (rs) |r| {
            c.mb.fill(g, r.blocks);
            var x = g.idom[r.s];
            while (x != d and x != none) : (x = g.idom[x]) {
                for (g.block_start[x]..g.block_start[x + 1]) |v| for (try c.users(@intCast(v))) |u| {
                    const ub = g.block_of[u];
                    if (c.mb.hasBlock(ub) or !g.reachable(ub)) continue;
                    if (g.reaches(r.t, ub)) {
                        total += 1;
                        break;
                    }
                };
            }
        }
        return total;
    }

    /// Whether the copies (with `extra`) each sit at the top of an arm of
    /// one branch: the branch (their common dominator) leads to a block the
    /// copy's entry post-dominates, and the branch's merge post-dominates
    /// the copy's exit. Merging them then keeps the control flow
    /// structured: the arms before the copies, the merged copy, the arms
    /// after it.
    fn topLevel(c: *const Ctx, rs: []const *const Region, extra: *const Region) bool {
        const g = &c.g;
        var b = extra.s;
        for (rs) |r| b = g.ncd(b, r.s);
        const j = g.ipdom[b];
        if (j == none) return false;
        for (0..rs.len + 1) |ri| {
            const r = if (ri < rs.len) rs[ri] else extra;
            var arm: u32 = none;
            for (g.succOf(b)) |x| if (g.dominates(x, r.s)) {
                arm = x;
                break;
            };
            if (arm == none) return false;
            var x = arm;
            var steps: u32 = 0;
            while (x != r.s) : (steps += 1) {
                if (x == j or x == none or x == g.nb or steps > 256) return false;
                x = g.ipdom[x];
            }
            x = r.t;
            steps = 0;
            while (x != j) : (steps += 1) {
                if (x == none or x == g.nb or steps > 256) return false;
                x = g.ipdom[x];
            }
        }
        return true;
    }

    /// Levels of ifs to hoist the copies out of to bring them to the top
    /// of the branch's arms; null if something else is in the way (a
    /// loop, a switch, a region not entered from one block).
    fn hoistDepth(c: *Ctx, branch: u32, rs: []const *const Region) ?u32 {
        var total: u32 = 0;
        for (rs) |r| {
            var t = r.t;
            var levels: u32 = 0;
            // (Without changing the graph: each level's exit is the next
            // enclosing if's arm.)
            var x_unit = r.s;
            while (true) {
                switch (findHoist(&c.g, c.insts, x_unit, t, branch)) {
                    .top => break,
                    .fail => return null,
                    .step => |h| {
                        levels += 1;
                        if (levels > 8) return null;
                        // The next level: the hoisted unit is the if
                        // around the copy, in H's arm.
                        x_unit = h.x;
                        t = h.join;
                        // (x_unit is the unit header's block; its single
                        // predecessor is checked by findHoist again.)
                        if (findHoistSkip(&c.g, c.insts, h)) |nx| {
                            x_unit = nx.s;
                            t = nx.t;
                        } else return null;
                    },
                }
            }
            total += levels;
        }
        return total;
    }

    fn context(c: *const Ctx, s: u32) u32 {
        var h = c.g.inner[s];
        while (h != none and c.ma.hasBlock(h)) h = c.g.loop_parent[h];
        return h;
    }

    /// Whether `b` matches `a` (whose positions are in `ma`), with the
    /// operands that differ appended to `diffs` (b's values at a's
    /// instructions).
    /// `holes`: positions whose blocks may differ (see holeOk); with
    /// `find`, positions where they do are added (within budget).
    fn iso(c: *Ctx, ra: *const Region, rb: *const Region, diffs: *std.ArrayList(Diff), holes: []bool, find: bool) Allocator.Error!bool {
        const g = &c.g;
        if (ra.blocks.len != rb.blocks.len) {
            why = 1;
            return false;
        }
        c.mb.fill(g, rb.blocks);
        const start = diffs.items.len;
        errdefer diffs.shrinkRetainingCapacity(start);
        for (ra.blocks, rb.blocks) |ba, bb| {
            const sa = g.succOf(ba);
            const sb = g.succOf(bb);
            if (sa.len != sb.len) {
                why = 2;
                return false;
            }
            for (sa, sb) |x, y| {
                if ((x == ra.t) != (y == rb.t)) {
                    why = 3;
                    return false;
                }
                if (x == ra.t) continue;
                if (!c.ma.hasBlock(x) or !c.mb.hasBlock(y) or c.ma.bpos[x] != c.mb.bpos[y]) {
                    why = 4;
                    return false;
                }
            }
        }
        // Blocks that differ: holes, if they may be.
        var hole_size: u32 = 0;
        for (ra.blocks, rb.blocks, 0..) |ba, bb, k| {
            if (!holes[k] and !c.sameBlock(ba, bb)) {
                if (!find or !c.holeOk(ra.s, ra.t, ba) or !c.holeOk(rb.s, rb.t, bb)) {
                    why = 5;
                    return false;
                }
                holes[k] = true;
            }
            if (holes[k]) hole_size += g.block_start[ba + 1] - g.block_start[ba];
        }
        if (hole_size * 2 > ra.size) {
            why = 6;
            return false;
        }
        for (ra.blocks, rb.blocks, 0..) |ba, bb, bk| {
            if (holes[bk]) continue;
            const la = g.block_start[ba + 1] - g.block_start[ba];
            for (0..la) |o| {
                const ia = g.block_start[ba] + @as(u32, @intCast(o));
                const ib = g.block_start[bb] + @as(u32, @intCast(o));
                const x = c.insts[ia];
                const y = c.insts[ib];
                if (!sameShape(x, y)) {
                    diffs.shrinkRetainingCapacity(start);
                    {
                        why = 7;
                        return false;
                    }
                }
                if (x.op == .phi) for (x.op.phi.incoming, y.op.phi.incoming) |p, q| {
                    if (!c.ma.hasBlock(p.block) or !c.mb.hasBlock(q.block) or c.ma.bpos[p.block] != c.mb.bpos[q.block]) {
                        diffs.shrinkRetainingCapacity(start);
                        {
                            why = 8;
                            return false;
                        }
                    }
                };
                for (0..opCount(x)) |k| {
                    const va = getOp(x, k);
                    const vb = getOp(y, k);
                    // (Values a hole defines count as from outside.)
                    const in_a = c.ma.hasInst(va) and !holes[c.ma.bpos[g.block_of[va.inst]]];
                    const in_b = c.mb.hasInst(vb) and !holes[c.mb.bpos[g.block_of[vb.inst]]];
                    if (in_a != in_b) {
                        diffs.shrinkRetainingCapacity(start);
                        {
                            why = 9;
                            return false;
                        }
                    }
                    if (in_a) {
                        // (By block and place in it: holes shift the rest.)
                        const da = g.block_of[va.inst];
                        const db = g.block_of[vb.inst];
                        if (c.ma.bpos[da] != c.mb.bpos[db] or va.inst - g.block_start[da] != vb.inst - g.block_start[db]) {
                            diffs.shrinkRetainingCapacity(start);
                            {
                                why = 10;
                                return false;
                            }
                        }
                        continue;
                    }
                    if (std.meta.eql(va, vb)) continue;
                    const ok = switch (mayDiffer(x, k)) {
                        .no => false,
                        .value => true,
                        .nonconst => va != .constant and vb != .constant,
                    };
                    const ty = c.typeOf(va);
                    if (!ok or ty != c.typeOf(vb) or !c.isScalar(ty)) {
                        diffs.shrinkRetainingCapacity(start);
                        {
                            why = 11;
                            return false;
                        }
                    }
                    try diffs.append(c.a, .{ .inst = ia, .slot = @intCast(k), .val = vb });
                }
            }
        }
        return true;
    }
};

const Diff = struct { inst: u32, slot: u32, val: Value };

/// A set of copies to merge: the regions (the first stays) and, per copy
/// after the first, the operands that differ from the first's.
const Set = struct {
    regions: []const *const Region,
    diffs: []const []const Diff,
    benefit: i64,
    classes: u32,
    live: u32,
    /// The branch whose arms hold the copies; whether they are at the top
    /// of its arms already (else ifs around them are hoisted first).
    branch: u32,
    top: bool,
    /// Positions of the blocks that differ between copies.
    holes: []const bool,
};

// ---------------------------------------------------------------------
// Editing a function's blocks

const Editor = struct {
    a: Allocator,
    m: *module.Module,
    insts: std.ArrayList(Inst),
    body: std.ArrayList(std.ArrayList(u32)),
    allocas: std.ArrayList(u32) = .empty,
    void_ty: TypeId,

    fn init(a: Allocator, m: *module.Module, insts: []const Inst, block_start: []const u32, nb: u32) Allocator.Error!Editor {
        var e: Editor = .{ .a = a, .m = m, .insts = .empty, .body = .empty, .void_ty = try m.getType(.void) };
        try e.insts.appendSlice(a, insts);
        try e.body.ensureTotalCapacity(a, nb + 16);
        for (0..nb) |b| {
            var l: std.ArrayList(u32) = .empty;
            try l.ensureTotalCapacity(a, block_start[b + 1] - block_start[b]);
            for (block_start[b]..block_start[b + 1]) |i| l.appendAssumeCapacity(@intCast(i));
            e.body.appendAssumeCapacity(l);
        }
        return e;
    }

    fn add(e: *Editor, inst: Inst) Allocator.Error!u32 {
        try e.insts.append(e.a, inst);
        return @intCast(e.insts.items.len - 1);
    }

    fn newBlock(e: *Editor) Allocator.Error!u32 {
        try e.body.append(e.a, .empty);
        return @intCast(e.body.items.len - 1);
    }

    fn alignOf(e: *Editor, ty: TypeId) u32 {
        return switch (e.m.types.items[ty]) {
            .half => 2,
            .double => 8,
            .int => |w| if (w > 32) 8 else 4,
            else => 4,
        };
    }

    fn alloca(e: *Editor, ty: TypeId) Allocator.Error!Value {
        const x = try e.add(.{ .ty = try e.m.ptrType(ty), .op = .{ .alloca = .{ .elem = ty, .size = try e.m.constInt(32, 1) } } });
        try e.allocas.append(e.a, x);
        return .{ .inst = x };
    }

    fn load(e: *Editor, ptr: Value, ty: TypeId) Allocator.Error!u32 {
        return e.add(.{ .ty = ty, .op = .{ .load = .{ .ptr = ptr, .@"align" = e.alignOf(ty) } } });
    }

    fn store(e: *Editor, ptr: Value, val: Value, ty: TypeId) Allocator.Error!u32 {
        return e.add(.{ .ty = e.void_ty, .op = .{ .store = .{ .ptr = ptr, .val = val, .@"align" = e.alignOf(ty) } } });
    }

    fn beforeTerm(e: *Editor, b: u32, x: u32) Allocator.Error!void {
        const l = &e.body.items[b];
        try l.insert(e.a, l.items.len - 1, x);
    }

    /// After the block's phis.
    fn atTop(e: *Editor, b: u32, x: u32) Allocator.Error!void {
        const l = &e.body.items[b];
        var k: usize = 0;
        while (k < l.items.len and e.insts.items[l.items[k]].op == .phi) k += 1;
        try l.insert(e.a, k, x);
    }

    fn after(e: *Editor, b: u32, def: u32, x: u32) Allocator.Error!void {
        const l = &e.body.items[b];
        if (e.insts.items[def].op == .phi) return e.atTop(b, x);
        const k = std.mem.indexOfScalar(u32, l.items, def).?;
        try l.insert(e.a, k + 1, x);
    }

    fn before(e: *Editor, b: u32, use: u32, x: u32) Allocator.Error!void {
        const l = &e.body.items[b];
        const k = std.mem.indexOfScalar(u32, l.items, use).?;
        try l.insert(e.a, k, x);
    }

    fn term(e: *Editor, b: u32) *Inst {
        const l = e.body.items[b].items;
        return &e.insts.items[l[l.len - 1]];
    }

    /// `p`'s edges to `from` go to `to`.
    fn retarget(e: *Editor, p: u32, from: u32, to: u32) Allocator.Error!void {
        const t = e.term(p);
        switch (t.op) {
            .br => |*br| {
                if (br.then == from) br.then = to;
                if (br.@"else") |*x| if (x.* == from) {
                    x.* = to;
                };
            },
            .@"switch" => |*sw| {
                if (sw.default == from) sw.default = to;
                const cs = try e.m.allocator().dupe(Case, sw.cases);
                for (cs) |*x| if (x.block == from) {
                    x.block = to;
                };
                sw.cases = cs;
            },
            else => {},
        }
    }

    /// The function laid out again: block order kept, new allocas first in
    /// the entry block. Null if a block uses an instruction no block holds.
    fn flatten(e: *Editor) Allocator.Error!?struct { insts: []Inst, nb: u32, index: []const u32 } {
        const n = e.insts.items.len;
        const index = try e.a.alloc(u32, n);
        @memset(index, none);
        var count: u32 = 0;
        for (e.allocas.items) |x| {
            index[x] = count;
            count += 1;
        }
        for (e.body.items) |l| for (l.items) |x| {
            index[x] = count;
            count += 1;
        };
        const Map = struct {
            index: []const u32,
            bad: bool = false,
            pub fn visit(s: *@This(), v: Value, _: promote.Role) Value {
                if (v != .inst) return v;
                const y = s.index[v.inst];
                if (y == none) {
                    s.bad = true;
                    return v;
                }
                return .{ .inst = y };
            }
        };
        var map: Map = .{ .index = index };
        const ma = e.m.allocator();
        const out = try ma.alloc(Inst, count);
        var k: usize = 0;
        for (e.allocas.items) |x| {
            out[k] = e.insts.items[x];
            try promote.operands(true, ma, &out[k], &map);
            k += 1;
        }
        for (e.body.items) |l| for (l.items) |x| {
            out[k] = e.insts.items[x];
            try promote.operands(true, ma, &out[k], &map);
            k += 1;
        };
        if (map.bad) return null;
        return .{ .insts = out, .nb = @intCast(e.body.items.len), .index = index };
    }
};

// ---------------------------------------------------------------------

pub const Stats = struct {
    melds: u32 = 0,
    copies: u32 = 0,
    removed: u32 = 0,
    classes: u32 = 0,
    demoted: u32 = 0,
    hoists: u32 = 0,
};
pub var stats: Stats = .{};
var why: u32 = 0;

/// Merges one set of copies (the most profitable); true if it did.
pub fn run(a: Allocator, m: *module.Module, func: u32) Allocator.Error!bool {
    const f = &m.functions.items[func];
    if (f.num_blocks < 4) return false;
    // A conditional branch after other instructions gets a block of its
    // own, so a region can start at it (an `if` whose condition each copy
    // computes its own way). Kept only if something merges.
    const split = try splitBranches(a, m, f.insts.items, f.num_blocks);
    const insts = if (split) |x| x.insts else f.insts.items;
    const nb = if (split) |x| x.nb else f.num_blocks;
    // (Forward reachability is nb^2 bits.)
    if (nb > 16000) return false;
    var c: Ctx = .{
        .a = a,
        .m = m,
        .func = func,
        .insts = insts,
        .g = (try build(a, insts, nb, true)) orelse return false,
        .ma = undefined,
        .mb = undefined,
    };
    c.ma = try Maps.init(a, nb, insts.len);
    c.mb = try Maps.init(a, nb, insts.len);
    const g = &c.g;

    // Candidate regions.
    var regions: std.ArrayList(Region) = .empty;
    {
        var blocks: std.ArrayList(u32) = .empty;
        var stack: std.ArrayList([2]u32) = .empty;
        for (g.rpo) |s| {
            if (s == 0 or c.insts[g.block_start[s]].op == .phi) continue;
            var t = g.ipdom[s];
            var steps: u32 = 0;
            while (t != none and t != nb and steps < max_steps) : ({
                t = g.ipdom[t];
                steps += 1;
            }) {
                const r = try c.collect(s, t, &blocks, &stack) orelse break;
                if (!r) continue;
                var size: u32 = 0;
                for (blocks.items) |b| size += g.block_start[b + 1] - g.block_start[b];
                if (size < exp.cur.meld_min) continue;
                const h = c.hashRegion(blocks.items, t) orelse break;
                if (exp.cur.meld_debug and size >= 400 and size <= 600) std.debug.print("region: s {d} t {d} size {d} blocks {d} skel {x} hash {x} top-block-len {d}\n", .{ s, t, size, blocks.items.len, h[1] & 0xffffff, h[0] & 0xffffff, g.block_start[blocks.items[1 % blocks.items.len] + 1] - g.block_start[blocks.items[1 % blocks.items.len]] });
                try regions.append(a, .{ .s = s, .t = t, .blocks = try a.dupe(u32, blocks.items), .size = size, .hash = h[0], .skel = h[1], .ctx = c.context(s) });
            }
        }
    }
    if (regions.items.len < 2) return false;
    std.mem.sort(Region, regions.items, {}, struct {
        fn lt(_: void, x: Region, y: Region) bool {
            if (x.skel != y.skel) return x.skel < y.skel;
            if (x.hash != y.hash) return x.hash < y.hash;
            return x.s < y.s;
        }
    }.lt);

    // Sets: per group of equal hashes, greedily from its first unused
    // region, the later ones exclusive with every member so far.
    var sets: std.ArrayList(Set) = .empty;
    {
        var lo: usize = 0;
        while (lo < regions.items.len) {
            var hi = lo + 1;
            while (hi < regions.items.len and regions.items[hi].skel == regions.items[lo].skel) hi += 1;
            defer lo = hi;
            if (hi - lo < 2) continue;
            const group = regions.items[lo..hi];
            const used = try a.alloc(bool, group.len);
            @memset(used, false);
            for (group, 0..) |*ra, ia| {
                if (used[ia]) continue;
                used[ia] = true;
                c.ma.fill(g, ra.blocks);
                var members: std.ArrayList(*const Region) = .empty;
                var diffs: std.ArrayList([]const Diff) = .empty;
                try members.append(a, ra);
                var scratch: std.ArrayList(Diff) = .empty;
                var branch: u32 = none;
                const holes = try a.alloc(bool, ra.blocks.len);
                @memset(holes, false);
                const trial = try a.alloc(bool, ra.blocks.len);
                for (group[ia + 1 ..], ia + 1..) |*rb, ib| {
                    if (members.items.len == 64) break;
                    if (used[ib] or rb.ctx != ra.ctx) continue;
                    const ok = for (members.items) |x| {
                        if (g.reaches(x.s, rb.s) or g.reaches(rb.s, x.s)) break false;
                    } else true;
                    if (!ok) continue;
                    // (All in the arms of one branch: the first two's.)
                    const nb2 = g.ncd(if (branch == none) ra.s else branch, rb.s);
                    if (branch != none and nb2 != branch) continue;
                    scratch.clearRetainingCapacity();
                    // (Without hoisting: only members that keep the set at
                    // the top of the branch's arms.)
                    if (exp.cur.meld_nohoist and !c.topLevel(members.items, rb)) continue;
                    @memcpy(trial, holes);
                    if (!try c.iso(ra, rb, &scratch, trial, true)) {
                        if (exp.cur.meld_debug and rb.hash != ra.hash) std.debug.print("iso fails: size {d} vs {d}, reason {d}\n", .{ ra.size, rb.size, why });
                        continue;
                    }
                    @memcpy(holes, trial);
                    used[ib] = true;
                    branch = nb2;
                    try members.append(a, rb);
                    try diffs.append(a, try a.dupe(Diff, scratch.items));
                }
                if (members.items.len < 2) continue;
                // The differing operands again, with every member's holes.
                var any_hole = false;
                for (holes) |hh| any_hole = any_hole or hh;
                if (any_hole) {
                    c.ma.fill(g, ra.blocks);
                    var kept: std.ArrayList(*const Region) = .empty;
                    var kdiffs: std.ArrayList([]const Diff) = .empty;
                    try kept.append(a, ra);
                    for (members.items[1..]) |rb| {
                        scratch.clearRetainingCapacity();
                        if (!try c.iso(ra, rb, &scratch, holes, false)) continue;
                        try kept.append(a, rb);
                        try kdiffs.append(a, try a.dupe(Diff, scratch.items));
                    }
                    if (kept.items.len < 2) continue;
                    members = kept;
                    diffs = kdiffs;
                }
                const ms = members.items;
                const top = c.topLevel(ms[0 .. ms.len - 1], ms[ms.len - 1]);
                var depth: u32 = 0;
                if (!top and !exp.cur.meld_any) {
                    const d = c.hoistDepth(branch, ms) orelse continue;
                    depth = d;
                }
                // Distinct differing operand positions: an upper bound on
                // the inputs each copy passes in.
                var pos: std.AutoHashMapUnmanaged(u64, void) = .empty;
                for (diffs.items) |ds| for (ds) |d| try pos.put(a, @as(u64, d.inst) << 8 | d.slot, {});
                const k: i64 = @intCast(members.items.len);
                const classes: u32 = pos.count();
                var exits: i64 = 0;
                for (members.items) |r| {
                    var i = g.block_start[r.t];
                    while (i < g.block_start[r.t + 1] and c.insts[i].op == .phi) : (i += 1) exits += 1;
                }
                var aligned: i64 = ra.size;
                var nholes: i64 = 0;
                for (holes, ra.blocks) |hh, b| if (hh) {
                    aligned -= g.block_start[b + 1] - g.block_start[b];
                    nholes += 1;
                };
                var benefit = (k - 1) * aligned - 2 * @as(i64, classes) - exits - 4 * k - 8 * @as(i64, depth) - 3 * k * nholes;
                if (exp.cur.meld_debug) std.debug.print("meld?: {d} copies of {d} ({d} aligned, {d} holes), {d} inputs, {d} exit phis, top {}, benefit {d}\n", .{ k, ra.size, aligned, nholes, classes, exits, top, benefit });
                if (benefit < exp.cur.meld_min) continue;
                const live = try c.liveThrough(members.items);
                // (Values carried through the merged copy cost the driver
                // more than their phis: registers held across it.)
                benefit -= 4 * @as(i64, live);
                if (benefit < exp.cur.meld_min or live * 4 > ra.size) continue;
                try sets.append(a, .{ .regions = members.items, .diffs = diffs.items, .benefit = benefit, .classes = classes, .live = live, .branch = branch, .top = top or exp.cur.meld_any, .holes = holes });
            }
        }
    }
    if (sets.items.len == 0) return false;
    std.mem.sort(Set, sets.items, {}, struct {
        fn lt(_: void, x: Set, y: Set) bool {
            return x.benefit > y.benefit;
        }
    }.lt);
    if (exp.cur.meld_hoistonly) {
        for (sets.items) |*set| {
            if (set.top) continue;
            if (try hoistSet(&c, set)) return true;
        }
        return false;
    }
    for (sets.items) |*set| {
        if (set.top) {
            if (try apply(&c, set)) return true;
        } else if (!exp.cur.meld_nohoist) {
            // Hoisted, then merged right away (or undone: hoisting alone
            // only adds branches).
            const saved = f.insts;
            const saved_nb = f.num_blocks;
            if (!try hoistSet(&c, set)) continue;
            try promote.run(a, m, func, &.empty);
            if (try run(a, m, func)) {
                stats.hoists += 1;
                if (exp.cur.meld_log) std.debug.print("meld: (hoisted {d} copies of {d} instructions to the top of their arms first)\n", .{ set.regions.len, set.regions[0].size });
                return true;
            }
            f.insts = saved;
            f.num_blocks = saved_nb;
        }
    }
    return false;
}

fn apply(c: *Ctx, set: *const Set) Allocator.Error!bool {
    const a = c.a;
    const m = c.m;
    const g = &c.g;
    const f = &m.functions.items[c.func];
    const n: u32 = @intCast(c.insts.len);
    const rs = set.regions;
    const k: u32 = @intCast(rs.len);
    const r0 = rs[0];

    // Which copy each block is in (1-based), and its position there.
    const owner = try a.alloc(u32, g.nb);
    @memset(owner, 0);
    const pos = try a.alloc(u32, g.nb);
    // (Holes are no copy's: each copy's stays, as it is.)
    const is_hole = try a.alloc(u32, g.nb);
    @memset(is_hole, 0);
    for (rs, 1..) |r, ci| for (r.blocks, 0..) |b, bi| {
        pos[b] = @intCast(bi);
        if (set.holes[bi]) {
            is_hole[b] = @intCast(ci);
        } else owner[b] = @intCast(ci);
    };
    const S = struct {
        g: *const Graph,
        owner: []const u32,
        pos: []const u32,
        r0: *const Region,
        n: u32,
        /// The kept copy's instruction for a copy's instruction.
        fn counterpart(s: @This(), x: u32) u32 {
            const b = s.g.block_of[x];
            return s.g.block_start[s.r0.blocks[s.pos[b]]] + (x - s.g.block_start[b]);
        }
        fn copyOf(s: @This(), v: Value) u32 {
            if (v != .inst or v.inst >= s.n) return 0;
            return s.owner[s.g.block_of[v.inst]];
        }
        fn mapIn(s: @This(), v: Value) Value {
            return if (s.copyOf(v) != 0) .{ .inst = s.counterpart(v.inst) } else v;
        }
    };
    const sx: S = .{ .g = g, .owner = owner, .pos = pos, .r0 = r0, .n = n };

    var e = try Editor.init(a, m, c.insts, g.block_start, g.nb);
    const ma = m.allocator();
    // Blocks between the copies' common dominator and each copy's entry:
    // the copies (bits) whose own code they are.
    const mask = try a.alloc(u64, g.nb);
    @memset(mask, 0);
    {
        var d = rs[0].s;
        for (rs[1..]) |r| d = g.ncd(d, r.s);
        for (rs, 0..) |r, ci| {
            var x = g.idom[r.s];
            while (x != d and x != none) : (x = g.idom[x]) mask[x] |= @as(u64, 1) << @intCast(ci);
            for (r.blocks, set.holes) |b, hh| if (hh) {
                mask[b] |= @as(u64, 1) << @intCast(ci);
            };
        }
    }
    const entries = try a.alloc(u32, k);

    // The exits' phis become locals, stored by each predecessor (the kept
    // copy's block for a copy's).
    // (Copies leaving to one block store from the kept copy's blocks once:
    // they must agree on the values.)
    var exit_phis: u32 = 0;
    var exits_done: std.ArrayList(u32) = .empty;
    for (rs) |r| {
        const t = r.t;
        if (std.mem.indexOfScalar(u32, exits_done.items, t) != null) continue;
        try exits_done.append(a, t);
        var i = g.block_start[t];
        while (i < g.block_start[t + 1] and c.insts[i].op == .phi) : (i += 1) {
            const phi = c.insts[i];
            const slot = try e.alloca(phi.ty);
            exit_phis += 1;
            var seen: std.ArrayList(u32) = .empty;
            var stored: std.AutoHashMapUnmanaged(u32, Value) = .empty;
            for (phi.op.phi.incoming) |in| {
                if (std.mem.indexOfScalar(u32, seen.items, in.block) != null) continue;
                try seen.append(a, in.block);
                if (!g.reachable(in.block)) continue;
                if (owner[in.block] != 0) {
                    const p0 = r0.blocks[pos[in.block]];
                    const v = sx.mapIn(in.val);
                    const gop = try stored.getOrPut(a, p0);
                    if (gop.found_existing) {
                        if (!std.meta.eql(gop.value_ptr.*, v)) return false;
                        continue;
                    }
                    gop.value_ptr.* = v;
                    try e.beforeTerm(p0, try e.store(slot, v, phi.ty));
                } else {
                    try e.beforeTerm(in.block, try e.store(slot, in.val, phi.ty));
                }
            }
            e.insts.items[i] = .{ .ty = phi.ty, .op = .{ .load = .{ .ptr = slot, .@"align" = e.alignOf(phi.ty) } } };
        }
    }

    // Inputs that differ: one local per distinct tuple of values (one per
    // copy), loaded at the top of the kept copy.
    const Key = struct { inst: u32, slot: u32 };
    var tuples: std.AutoArrayHashMapUnmanaged(Key, []Value) = .empty;
    for (set.diffs, 1..) |ds, ci| for (ds) |d| {
        const gop = try tuples.getOrPut(a, .{ .inst = d.inst, .slot = d.slot });
        if (!gop.found_existing) {
            const t = try a.alloc(Value, k);
            @memset(t, getOp(c.insts[d.inst], d.slot));
            gop.value_ptr.* = t;
        }
        gop.value_ptr.*[ci] = d.val;
    };
    const ClassCtx = struct {
        pub fn hash(_: @This(), t: []const Value) u32 {
            return @truncate(std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(t)));
        }
        pub fn eql(_: @This(), x: []const Value, y: []const Value, _: usize) bool {
            for (x, y) |p, q| if (!std.meta.eql(p, q)) return false;
            return true;
        }
    };
    var classes: std.ArrayHashMapUnmanaged([]const Value, Value, ClassCtx, true) = .empty;
    {
        var it = tuples.iterator();
        while (it.next()) |kv| {
            const key = kv.key_ptr.*;
            const tuple = kv.value_ptr.*;
            const gop = try classes.getOrPut(a, tuple);
            const ty = c.typeOf(getOp(c.insts[key.inst], key.slot));
            if (!gop.found_existing) gop.value_ptr.* = try e.alloca(ty);
            const ld = try e.load(gop.value_ptr.*, ty);
            // (A value a hole defines is stored at the hole's end: read
            // where it is used.)
            const late = for (tuple) |v| {
                if (v == .inst and v.inst < n and is_hole[g.block_of[v.inst]] != 0) break true;
            } else false;
            if (!late) {
                try e.atTop(r0.s, ld);
            } else if (c.insts[key.inst].op == .phi) {
                try e.beforeTerm(c.insts[key.inst].op.phi.incoming[key.slot].block, ld);
            } else try e.before(g.block_of[key.inst], key.inst, ld);
            try setOp(ma, &e.insts.items[key.inst], key.slot, .{ .inst = ld });
        }
    }
    const i32_ty = try m.intType(32);
    const tag = try e.alloca(i32_ty);

    // Each copy enters through a block storing its inputs and number.
    for (rs, 0..) |r, ci| {
        const blk = try e.newBlock();
        entries[ci] = blk;
        var it = classes.iterator();
        while (it.next()) |kv| {
            const v = kv.key_ptr.*[ci];
            if (v == .inst and v.inst < n and is_hole[g.block_of[v.inst]] != 0) {
                try e.beforeTerm(g.block_of[v.inst], try e.store(kv.value_ptr.*, v, c.typeOf(v)));
            } else try e.body.items[blk].append(a, try e.store(kv.value_ptr.*, v, c.typeOf(v)));
        }
        try e.body.items[blk].append(a, try e.store(tag, try m.constInt(32, @intCast(ci)), i32_ty));
        try e.body.items[blk].append(a, try e.add(.{ .ty = e.void_ty, .op = .{ .br = .{ .then = r0.s } } }));
        var seen: std.ArrayList(u32) = .empty;
        for (g.predOf(r.s)) |p| {
            if (owner[p] == ci + 1 or std.mem.indexOfScalar(u32, seen.items, p) != null) continue;
            try seen.append(a, p);
            try e.retarget(p, r.s, blk);
        }
    }

    // The kept copy leaves through a block switching on the number.
    {
        const blk = try e.newBlock();
        var cases: std.ArrayList(Case) = .empty;
        for (rs[1..], 1..) |r, ci| if (r.t != r0.t) try cases.append(ma, .{ .val = try m.constInt(32, @intCast(ci)), .block = r.t });
        if (cases.items.len == 0) {
            try e.body.items[blk].append(a, try e.add(.{ .ty = e.void_ty, .op = .{ .br = .{ .then = r0.t } } }));
        } else {
            const ld = try e.load(tag, i32_ty);
            try e.body.items[blk].append(a, ld);
            try e.body.items[blk].append(a, try e.add(.{ .ty = e.void_ty, .op = .{ .@"switch" = .{ .cond = .{ .inst = ld }, .default = r0.t, .cases = cases.items } } }));
        }
        for (r0.blocks) |b| {
            for (g.succOf(b)) |s| if (s == r0.t) {
                try e.retarget(b, r0.t, blk);
                break;
            };
        }
    }

    // The other copies go; what read their values reads the kept copy's.
    // Each hole: a switch on the copy's number to the copy's block, which
    // then goes on in the kept copy.
    const dispatch = try a.alloc(u32, set.holes.len);
    for (set.holes, 0..) |hh, hp| if (hh) {
        const h0 = r0.blocks[hp];
        const blk = try e.newBlock();
        dispatch[hp] = blk;
        const ld = try e.load(tag, i32_ty);
        try e.body.items[blk].append(a, ld);
        const cases = try ma.alloc(Case, k - 1);
        for (rs[1..], cases, 1..) |r, *cs, ci| cs.* = .{ .val = try m.constInt(32, @intCast(ci)), .block = r.blocks[hp] };
        try e.body.items[blk].append(a, try e.add(.{ .ty = e.void_ty, .op = .{ .@"switch" = .{ .cond = .{ .inst = ld }, .default = h0, .cases = cases } } }));
        var seen: std.ArrayList(u32) = .empty;
        for (g.predOf(h0)) |p| {
            if (std.mem.indexOfScalar(u32, seen.items, p) != null) continue;
            try seen.append(a, p);
            try e.retarget(p, h0, blk);
        }
    };
    // The other copies' holes go on where the kept copy's does (through
    // the next hole's switch, if the next block is one).
    for (set.holes, 0..) |hh, hp| if (hh) {
        const next0 = g.succOf(r0.blocks[hp])[0];
        const np = pos[next0];
        const to = if (set.holes[np]) dispatch[np] else next0;
        for (rs[1..]) |r| {
            const hb = r.blocks[hp];
            try e.retarget(hb, g.succOf(hb)[0], to);
        }
    };
    for (rs[1..]) |r| for (r.blocks, set.holes) |b, hh| {
        if (hh) continue;
        e.body.items[b].clearRetainingCapacity();
        try e.body.items[b].append(a, try e.add(.{ .ty = e.void_ty, .op = .@"unreachable" }));
    };
    {
        const Rw = struct {
            sx: S,
            pub fn visit(s: *@This(), v: Value, _: promote.Role) Value {
                if (s.sx.copyOf(v) > 1) return .{ .inst = s.sx.counterpart(v.inst) };
                return v;
            }
        };
        var rw: Rw = .{ .sx = sx };
        for (e.body.items) |l| for (l.items) |x| {
            try promote.operands(true, ma, &e.insts.items[x], &rw);
        };
    }

    const flat = try e.flatten() orelse return false;
    const new_mask = try a.alloc(u64, flat.insts.len);
    @memset(new_mask, 0);
    for (flat.index[0..n], 0..) |y, x| if (y != none) {
        new_mask[y] = mask[g.block_of[x]];
    };
    const fixed = try repair(a, m, flat.insts, flat.nb, .{ .mask = new_mask, .entries = entries }) orelse return false;
    f.insts = .fromOwnedSlice(fixed.insts);
    f.num_blocks = fixed.nb;
    stats.melds += 1;
    stats.copies += k;
    stats.removed += (k - 1) * r0.size;
    stats.classes += @intCast(classes.count());
    stats.demoted += fixed.demoted;
    if (exp.cur.meld_log) std.debug.print("meld: {d} copies of {d} instructions ({d} blocks), {d} inputs, {d} exit phis, {d} values through locals\n", .{ k, r0.size, r0.blocks.len, classes.count(), exit_phis, fixed.demoted });
    return true;
}

const Hoist = struct {
    /// The unit's entry block (the region's one predecessor), the if
    /// around it (`h`, its arm `tside`, merge `m`).
    x: u32,
    h: u32,
    tside: u32,
    m: u32,
    /// The region's exit (also the unit's: an `if` at `x` goes there the
    /// other way).
    join: u32,
    /// `x` branches on `cond` (to the region when true if `s_then`);
    /// null: straight to it.
    cond: ?Value,
    s_then: bool,
    /// `h` goes to `tside` when its condition is true.
    h_then: bool,
};

/// The if to hoist the region (s, t) out of (the innermost around the
/// unit: the region, or the if at its one predecessor that goes to it or
/// to `t`), `top` if none is left below `branch`.
fn findHoist(g: *const Graph, insts: []const Inst, s: u32, t: u32, branch: u32) union(enum) { top, fail, step: Hoist } {
    const ps = g.predOf(s);
    if (ps.len == 0) return .fail;
    const x = ps[0];
    for (ps) |p| if (p != x) return .fail;
    const xt = insts[g.block_start[x + 1] - 1];
    if (xt.op != .br) return .fail;
    const br = xt.op.br;
    var hs: Hoist = undefined;
    hs.x = x;
    hs.join = t;
    if (br.@"else") |e| {
        if (!((br.then == s and e == t) or (e == s and br.then == t))) return .fail;
        hs.cond = br.cond.?;
        hs.s_then = br.then == s;
    } else {
        if (br.then != s) return .fail;
        hs.cond = null;
        hs.s_then = true;
    }
    // No loop between the branch and the unit.
    {
        var l = g.inner[x];
        while (l != none) : (l = g.loop_parent[l]) {
            if (l != branch and g.dominates(branch, l)) return .fail;
        }
    }
    var h = g.idom[x];
    var steps: u32 = 0;
    while (steps < 256) : (steps += 1) {
        if (h == none) return .fail;
        if (h == branch) return .top;
        const mh = g.ipdom[h];
        if (mh != none and mh != g.nb and g.dominates(mh, x)) {
            // (After h's construct, not in it.)
            h = g.idom[h];
            continue;
        }
        const ht = insts[g.block_start[h + 1] - 1];
        switch (ht.op) {
            .br => |hb| {
                const e = hb.@"else" orelse {
                    h = g.idom[h];
                    continue;
                };
                if (mh == none or mh == g.nb) return .fail;
                const tside = if (g.dominates(hb.then, x)) hb.then else if (g.dominates(e, x)) e else return .fail;
                var y = tside;
                var k: u32 = 0;
                while (y != x) : (k += 1) {
                    if (y == mh or y == none or y == g.nb or k > 256) return .fail;
                    y = g.ipdom[y];
                }
                hs.h = h;
                hs.tside = tside;
                hs.m = mh;
                hs.h_then = tside == hb.then;
                return .{ .step = hs };
            },
            else => return .fail,
        }
    }
    return .fail;
}

/// For hoistDepth: the unit one level up once `h` is hoisted, as a region
/// (s, t) of the graph as it is (before hoisting): the if at the hoisted
/// unit's place.
fn findHoistSkip(g: *const Graph, insts: []const Inst, h: Hoist) ?struct { s: u32, t: u32 } {
    _ = insts;
    _ = g;
    // After hoisting, the copy's unit is `if (p) region` right in h's arm:
    // the next level up is found from h itself (the unit's predecessor is
    // in h's arm, at the top). Approximated by h's own position: the unit
    // (h.tside .. h.m) one level up.
    return .{ .s = h.tside, .t = h.m };
}

/// Lifts the region (s, t) out of the if `hs.h` around it: the arm before
/// it, then `if (p) region`, then the rest of the arm under the if's
/// condition again. `p` is false on the if's other way. Returns the new
/// function and the region's new exit.
fn hoistOne(c: *Ctx, s: u32, hs: Hoist) Allocator.Error!?struct { insts: []Inst, nb: u32, exit: u32 } {
    const a = c.a;
    const m = c.m;
    const g = &c.g;
    var e = try Editor.init(a, m, c.insts, g.block_start, g.nb);
    const bool_ty = try m.intType(1);
    const t = hs.join;
    const h = hs.h;
    const x = hs.x;
    const mm = hs.m;
    // The region's blocks.
    var blocks: std.ArrayList(u32) = .empty;
    var stack: std.ArrayList([2]u32) = .empty;
    if ((try c.collect(s, t, &blocks, &stack)) != true) return null;
    const in_region = try a.alloc(bool, g.nb);
    @memset(in_region, false);
    for (blocks.items) |b| in_region[b] = true;

    // Phis of the region's exit and of the if's merge become locals.
    var demote_blocks: [2]u32 = .{ t, mm };
    const nd: usize = if (t == mm) 1 else 2;
    for (demote_blocks[0..nd]) |db| {
        var i = g.block_start[db];
        while (i < g.block_start[db + 1] and c.insts[i].op == .phi) : (i += 1) {
            const phi = c.insts[i];
            const slot = try e.alloca(phi.ty);
            var seen: std.ArrayList(u32) = .empty;
            for (phi.op.phi.incoming) |in| {
                if (std.mem.indexOfScalar(u32, seen.items, in.block) != null) continue;
                try seen.append(a, in.block);
                if (!g.reachable(in.block)) continue;
                try e.beforeTerm(in.block, try e.store(slot, in.val, phi.ty));
            }
            e.insts.items[i] = .{ .ty = phi.ty, .op = .{ .load = .{ .ptr = slot, .@"align" = e.alignOf(phi.ty) } } };
        }
    }
    _ = &demote_blocks;

    const pv = try e.alloca(bool_ty);
    const f1 = try e.newBlock();
    const f2 = try e.newBlock();
    // The if: p false on its other way.
    try e.beforeTerm(h, try e.store(pv, try m.constInt(1, 0), bool_ty));
    // The unit's entry: p, then to the new test.
    {
        const xl = &e.body.items[x];
        _ = xl.pop();
        var go: Value = try m.constInt(1, 1);
        if (hs.cond) |cond| {
            go = cond;
            if (!hs.s_then) go = .{ .inst = try e.add(.{ .ty = bool_ty, .op = .{ .binop = .{ .op = .xor, .lhs = cond, .rhs = try m.constInt(1, 1) } } }) };
            if (!hs.s_then) try xl.append(a, go.inst);
        }
        try xl.append(a, try e.store(pv, go, bool_ty));
        try xl.append(a, try e.add(.{ .ty = e.void_ty, .op = .{ .br = .{ .then = f1 } } }));
    }
    {
        const ld = try e.load(pv, bool_ty);
        try e.body.items[f1].append(a, ld);
        try e.body.items[f1].append(a, try e.add(.{ .ty = e.void_ty, .op = .{ .br = .{ .cond = .{ .inst = ld }, .then = s, .@"else" = f2 } } }));
    }
    {
        const hc = c.insts[g.block_start[h + 1] - 1].op.br.cond.?;
        if (t == mm) {
            try e.body.items[f2].append(a, try e.add(.{ .ty = e.void_ty, .op = .{ .br = .{ .then = mm } } }));
        } else {
            try e.body.items[f2].append(a, try e.add(.{ .ty = e.void_ty, .op = .{ .br = .{ .cond = hc, .then = if (hs.h_then) t else mm, .@"else" = if (hs.h_then) mm else t } } }));
        }
    }
    // The region leaves to the second test.
    for (blocks.items) |b| for (g.succOf(b)) |y| if (y == t) {
        try e.retarget(b, t, f2);
        break;
    };
    // The if's other way (and what of it reaches the merge) goes to the
    // first test.
    {
        var seen: std.ArrayList(u32) = .empty;
        for (g.predOf(mm)) |pb| {
            if (!g.reachable(pb) or g.dominates(hs.tside, pb) or std.mem.indexOfScalar(u32, seen.items, pb) != null) continue;
            try seen.append(a, pb);
            try e.retarget(pb, mm, f1);
        }
    }
    const flat = try e.flatten() orelse return null;
    // Values the arm defines are undefined on the if's other way.
    const mask = try a.alloc(u64, flat.insts.len);
    @memset(mask, 0);
    for (flat.index[0..c.insts.len], 0..) |y, xi| if (y != none) {
        if (g.dominates(hs.tside, g.block_of[xi])) mask[y] = 2;
    };
    const entries = try a.alloc(u32, 1);
    entries[0] = h;
    const fixed = try repair(a, m, flat.insts, flat.nb, .{ .mask = mask, .entries = entries }) orelse return null;
    return .{ .insts = fixed.insts, .nb = fixed.nb, .exit = f2 };
}

/// Hoists every copy of the set to the top of the branch's arms, one if at
/// a time (promoted after each). False (and the function as it was) if
/// one cannot be.
fn hoistSet(c0: *Ctx, set: *const Set) Allocator.Error!bool {
    const a = c0.a;
    const m = c0.m;
    const f = &m.functions.items[c0.func];
    const saved = f.insts;
    const saved_nb = f.num_blocks;
    const k = set.regions.len;
    const ss = try a.alloc(u32, k);
    const ts = try a.alloc(u32, k);
    for (set.regions, 0..) |r, i| {
        ss[i] = r.s;
        ts[i] = r.t;
    }
    var insts: []Inst = @constCast(c0.insts);
    var nb = c0.g.nb;
    var rounds: u32 = 0;
    var steps: u32 = 0;
    for (0..k) |i| {
        while (true) : (rounds += 1) {
            if (rounds > 64) {
                f.insts = saved;
                f.num_blocks = saved_nb;
                return false;
            }
            var c: Ctx = .{ .a = a, .m = m, .func = c0.func, .insts = insts, .g = (try build(a, insts, nb, true)) orelse break, .ma = undefined, .mb = undefined };
            c.ma = try Maps.init(a, nb, insts.len);
            c.mb = try Maps.init(a, nb, insts.len);
            const step = switch (findHoist(&c.g, insts, ss[i], ts[i], set.branch)) {
                .top => break,
                .fail => {
                    f.insts = saved;
                    f.num_blocks = saved_nb;
                    return false;
                },
                .step => |h| h,
            };
            const r = try hoistOne(&c, ss[i], step) orelse {
                f.insts = saved;
                f.num_blocks = saved_nb;
                return false;
            };
            ts[i] = r.exit;
            steps += 1;
            f.insts = .fromOwnedSlice(r.insts);
            f.num_blocks = r.nb;
            try promote.run(a, m, c0.func, &.empty);
            if (f.num_blocks != r.nb) {
                f.insts = saved;
                f.num_blocks = saved_nb;
                return false;
            }
            insts = f.insts.items;
            nb = f.num_blocks;
        }
    }
    // (Nothing to hoist: the copies are as high as they go, but not where
    // merging them keeps the control flow structured.)
    if (steps == 0) {
        f.insts = saved;
        f.num_blocks = saved_nb;
        return false;
    }
    return true;
}

/// Blocks ending in a conditional branch or switch after other
/// instructions (or phis), split before it. Null if there are none.
fn splitBranches(a: Allocator, m: *module.Module, insts: []const Inst, nb: u32) Allocator.Error!?struct { insts: []Inst, nb: u32 } {
    const block_start = try a.alloc(u32, nb + 1);
    {
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
    }
    var e = try Editor.init(a, m, insts, block_start, nb);
    const ma = m.allocator();
    var any = false;
    for (0..nb) |bi| {
        const b: u32 = @intCast(bi);
        const len = e.body.items[b].items.len;
        if (len < 2) continue;
        const ti = e.body.items[b].items[len - 1];
        const t = e.insts.items[ti];
        const cond = switch (t.op) {
            .br => |br| br.@"else" != null,
            .@"switch" => true,
            else => false,
        };
        if (!cond) continue;
        const nbk = try e.newBlock();
        e.body.items[b].items.len -= 1;
        try e.body.items[b].append(a, try e.add(.{ .ty = e.void_ty, .op = .{ .br = .{ .then = nbk } } }));
        try e.body.items[nbk].append(a, ti);
        // The successors' phis now name the new block.
        var succ: std.ArrayList(u32) = .empty;
        switch (t.op) {
            .br => |br| {
                try succ.append(a, br.then);
                try succ.append(a, br.@"else".?);
            },
            .@"switch" => |sw| {
                try succ.append(a, sw.default);
                for (sw.cases) |x| try succ.append(a, x.block);
            },
            else => unreachable,
        }
        for (succ.items, 0..) |x, xi| {
            if (std.mem.indexOfScalar(u32, succ.items[0..xi], x) != null) continue;
            for (e.body.items[x].items) |pi| {
                const phi = &e.insts.items[pi];
                if (phi.op != .phi) break;
                const ins = try ma.dupe(Edge, phi.op.phi.incoming);
                for (ins) |*in| if (in.block == b) {
                    in.block = nbk;
                };
                phi.op.phi.incoming = ins;
            }
        }
        any = true;
    }
    if (!any) return null;
    const flat = try e.flatten() orelse return null;
    return .{ .insts = flat.insts, .nb = flat.nb };
}

/// Values whose definitions no longer dominate their uses go through a
/// local: stored after the definition, loaded at each such use.
/// `hints`: for each instruction, the copies whose own code it is (a bit
/// each), and each copy's entry block: a value one copy's code defines is
/// undefined on the others' entries (so it is not carried around loops).
fn repair(a: Allocator, m: *module.Module, insts: []Inst, nb: u32, hints: struct { mask: []const u64, entries: []const u32 }) Allocator.Error!?struct { insts: []Inst, nb: u32, demoted: u32 } {
    const g = (try build(a, insts, nb, false)) orelse return null;
    const Use = struct { inst: u32, slot: u32, def: u32 };
    var uses: std.ArrayList(Use) = .empty;
    for (g.rpo) |b| for (g.block_start[b]..g.block_start[b + 1]) |xi| {
        const x: u32 = @intCast(xi);
        const inst = insts[x];
        for (0..opCount(inst)) |k| {
            const v = getOp(inst, k);
            if (v != .inst) continue;
            const d = v.inst;
            const db = g.block_of[d];
            const ok = if (inst.op == .phi) blk: {
                const p = inst.op.phi.incoming[k].block;
                if (!g.reachable(p)) break :blk true;
                break :blk g.reachable(db) and g.dominates(db, p);
            } else if (db == b) d < x else g.reachable(db) and g.dominates(db, b);
            if (!ok) try uses.append(a, .{ .inst = x, .slot = @intCast(k), .def = d });
        }
    };
    if (uses.items.len == 0) return .{ .insts = insts, .nb = nb, .demoted = 0 };
    var e = try Editor.init(a, m, insts, g.block_start, nb);
    var slots: std.AutoHashMapUnmanaged(u32, Value) = .empty;
    const ma = m.allocator();
    for (uses.items) |u| {
        const ty = insts[u.def].ty;
        switch (m.types.items[ty]) {
            .half, .float, .double, .int => {},
            else => return null,
        }
        const gop = try slots.getOrPut(a, u.def);
        if (!gop.found_existing) {
            gop.value_ptr.* = try e.alloca(ty);
            try e.after(g.block_of[u.def], u.def, try e.store(gop.value_ptr.*, .{ .inst = u.def }, ty));
            const bits = hints.mask[u.def];
            if (bits != 0) for (hints.entries, 0..) |eb, ci| {
                if ((bits >> @intCast(ci)) & 1 != 0) continue;
                const un = try m.constant(.{ .ty = ty, .kind = .undef });
                try e.beforeTerm(eb, try e.store(gop.value_ptr.*, un, ty));
            };
        }
        const ld = try e.load(gop.value_ptr.*, ty);
        const inst = insts[u.inst];
        if (inst.op == .phi) {
            try e.beforeTerm(inst.op.phi.incoming[u.slot].block, ld);
        } else try e.before(g.block_of[u.inst], u.inst, ld);
        try setOp(ma, &e.insts.items[u.inst], u.slot, .{ .inst = ld });
    }
    const flat = try e.flatten() orelse return null;
    return .{ .insts = flat.insts, .nb = flat.nb, .demoted = slots.count() };
}

/// After melding (and the cleanup that follows it): no instruction may
/// read `undef` (the validator rejects it; phis may). A select with an
/// undefined arm is its other arm; any other undefined operand is zero.
pub fn cleanUndef(a: Allocator, m: *module.Module, func: u32) Allocator.Error!void {
    const f = &m.functions.items[func];
    const insts = f.insts.items;
    const n = insts.len;
    const isUndef = struct {
        fn check(mm: *const module.Module, v: Value) bool {
            return v == .constant and mm.constants.items[v.constant].kind == .undef;
        }
    }.check;
    var any = false;
    // (Calls keep theirs: unused coordinates and offsets of dx.op calls
    // must be undef.)
    for (insts) |inst| {
        if (inst.op == .phi or inst.op == .call) continue;
        for (0..opCount(inst)) |k| if (isUndef(m, getOp(inst, k))) {
            any = true;
        };
    }
    if (!any) return;
    const repl = try a.alloc(?Value, n);
    @memset(repl, null);
    for (insts, 0..) |inst, i| if (inst.op == .select) {
        const sel = inst.op.select;
        if (isUndef(m, sel.t) and !isUndef(m, sel.f)) repl[i] = sel.f else if (isUndef(m, sel.f) and !isUndef(m, sel.t)) repl[i] = sel.t;
    };
    const Rw = struct {
        repl: []const ?Value,
        pub fn visit(s: *@This(), v: Value, _: promote.Role) Value {
            var x = v;
            var guard: usize = 0;
            while (x == .inst and s.repl[x.inst] != null and guard < 64) : (guard += 1) x = s.repl[x.inst].?;
            return x;
        }
    };
    var rw: Rw = .{ .repl = repl };
    const ma = m.allocator();
    for (insts) |*inst| try promote.operands(true, ma, inst, &rw);
    for (insts) |*inst| {
        if (inst.op == .phi or inst.op == .call) continue;
        for (0..opCount(inst.*)) |k| {
            const v = getOp(inst.*, k);
            if (!isUndef(m, v)) continue;
            const ty = m.constants.items[v.constant].ty;
            const z: module.Constant = switch (m.types.items[ty]) {
                .half, .float, .double => .{ .ty = ty, .kind = .{ .float_bits = 0 } },
                .int => .{ .ty = ty, .kind = .{ .int = 0 } },
                else => continue,
            };
            try setOp(ma, inst, k, try m.constant(z));
        }
    }
}

/// Phis of one block and type whose defined inputs come in on different
/// edges (undef on the others, as melding leaves the values each copy's
/// arm carries through the merged copy) become one phi: where one is
/// undefined, any value will do. Fewer values live through the merged
/// copy (each arm's, not all of them). True if any were merged.
pub fn packPhis(a: Allocator, m: *module.Module, func: u32) Allocator.Error!bool {
    const f = &m.functions.items[func];
    const insts = f.insts.items;
    const n = insts.len;
    const g = (try build(a, insts, f.num_blocks, false)) orelse return false;
    const isUndef = struct {
        fn check(mm: *const module.Module, v: Value) bool {
            return v == .constant and mm.constants.items[v.constant].kind == .undef;
        }
    }.check;
    const repl = try a.alloc(?Value, n);
    @memset(repl, null);
    var changed = false;
    const ma = m.allocator();
    for (0..g.nb) |bi| {
        const b: u32 = @intCast(bi);
        var end = g.block_start[b];
        while (end < g.block_start[b + 1] and insts[end].op == .phi) end += 1;
        const nphi = end - g.block_start[b];
        if (nphi < 2) continue;
        // Distinct predecessors: the edge positions.
        var preds: std.ArrayList(u32) = .empty;
        for (g.predOf(b)) |p| if (std.mem.indexOfScalar(u32, preds.items, p) == null) try preds.append(a, p);
        const np = preds.items.len;
        if (np < 2) continue;
        // Bins of merged phis: per edge, the value (null: undefined).
        const Bin = struct { phi: u32, ty: TypeId, vals: []?Value };
        var bins: std.ArrayList(Bin) = .empty;
        var vals = try a.alloc(?Value, np);
        for (g.block_start[b]..end) |pi| {
            const phi = insts[pi];
            @memset(vals, null);
            var ok = true;
            for (phi.op.phi.incoming) |in| {
                const k = std.mem.indexOfScalar(u32, preds.items, in.block) orelse {
                    ok = false;
                    break;
                };
                if (!isUndef(m, in.val)) vals[k] = in.val;
            }
            if (!ok) continue;
            var defined: usize = 0;
            for (vals) |v| defined += @intFromBool(v != null);
            if (defined == np) continue; // (nothing to share)
            const fit = for (bins.items) |*bin| {
                if (bin.ty != phi.ty) continue;
                const clash = for (bin.vals, vals) |x, y| {
                    if (x != null and y != null and !std.meta.eql(x.?, y.?)) break true;
                } else false;
                if (!clash) break bin;
            } else null;
            if (fit) |bin| {
                for (bin.vals, vals) |*x, y| if (x.* == null) {
                    x.* = y;
                };
                repl[pi] = .{ .inst = bin.phi };
                changed = true;
            } else {
                try bins.append(a, .{ .phi = @intCast(pi), .ty = phi.ty, .vals = try a.dupe(?Value, vals) });
            }
        }
        // The bins' phis take the merged inputs.
        for (bins.items) |bin| {
            const old = insts[bin.phi].op.phi.incoming;
            const ins = try ma.dupe(Edge, old);
            for (ins) |*in| {
                const k = std.mem.indexOfScalar(u32, preds.items, in.block).?;
                if (bin.vals[k]) |v| in.val = v;
            }
            insts[bin.phi].op.phi.incoming = ins;
        }
    }
    if (!changed) return false;
    const Rw = struct {
        repl: []const ?Value,
        pub fn visit(s: *@This(), v: Value, _: promote.Role) Value {
            var x = v;
            var guard: usize = 0;
            while (x == .inst and s.repl[x.inst] != null and guard < 64) : (guard += 1) x = s.repl[x.inst].?;
            return x;
        }
    };
    var rw: Rw = .{ .repl = repl };
    for (insts) |*inst| try promote.operands(true, ma, inst, &rw);
    return true;
}

/// EXPERIMENT, for measuring only (it changes what the GPU runs): each
/// integer constant a loop's exit or back edge compares against becomes
/// WaveActiveMax of itself, the same value, but one the driver cannot see
/// is constant, so it no longer knows the trip count. True if any
/// changed.
pub fn opaqueTrips(a: Allocator, m: *module.Module, func: u32) Allocator.Error!bool {
    const i32_ty = try m.intType(32);
    const i8_ty = try m.intType(8);
    const fname = "dx.op.waveActiveOp.i32";
    // (Declared before `f` is taken: adding a function can move the module's
    // function list, and the edits would go to the old copy.)
    const callee = m.findFunction(fname) orelse try m.addFunction(.{ .name = fname, .ty = try m.fnType(i32_ty, &.{ i32_ty, i32_ty, i8_ty, i8_ty }), .attrs = .nounwind });
    const f = &m.functions.items[func];
    const insts = f.insts.items;
    const g = (try build(a, insts, f.num_blocks, true)) orelse return false;
    var e = try Editor.init(a, m, insts, g.block_start, g.nb);
    const ma = m.allocator();
    var changed = false;
    // (Only loops that write memory other threads can see, as ShaderPrint's
    // glyph loops do, unless opaque_trip_all: the driver's unrolling of
    // sampling loops, and of loops filling local arrays, which unrolled
    // become registers, pays at run time.)
    var writes: std.AutoHashMapUnmanaged(u32, bool) = .empty;
    for (g.rpo) |b| {
        const term = insts[g.block_start[b + 1] - 1];
        if (term.op != .br) continue;
        const br = term.op.br;
        const other = br.@"else" orelse continue;
        const h = g.inner[b];
        if (h == none) continue;
        if (!(br.then == h or other == h or !inLoop(&g, br.then, h) or !inLoop(&g, other, h))) continue;
        if (!exp.cur.opaque_trip_all) {
            const gop = try writes.getOrPut(a, h);
            if (!gop.found_existing) gop.value_ptr.* = loopWrites(&g, m, insts, h);
            if (!gop.value_ptr.*) continue;
        }
        const cv = br.cond orelse continue;
        if (cv != .inst) continue;
        const ci = insts[cv.inst];
        if (ci.op != .cmp) continue;
        for (0..2) |k| {
            const v = if (k == 0) ci.op.cmp.lhs else ci.op.cmp.rhs;
            if (v != .constant) continue;
            const kc = m.constants.items[v.constant];
            if (kc.kind != .int) continue;
            switch (m.types.items[kc.ty]) {
                .int => |w| if (w != 32) continue,
                else => continue,
            }
            const call = try e.add(.{ .ty = i32_ty, .op = .{ .call = .{ .callee = callee, .args = try ma.dupe(Value, &.{ try m.constInt(32, 119), v, try m.constInt(8, 3), try m.constInt(8, 1) }) } } });
            try e.before(g.block_of[cv.inst], cv.inst, call);
            try setOp(ma, &e.insts.items[cv.inst], k, .{ .inst = call });
            changed = true;
            break;
        }
    }
    if (!changed) return false;
    const flat = try e.flatten() orelse return false;
    f.insts = .fromOwnedSlice(flat.insts);
    f.num_blocks = flat.nb;
    return true;
}

fn inLoop(g: *const Graph, b: u32, h: u32) bool {
    var x = g.inner[b];
    while (x != none) : (x = g.loop_parent[x]) if (x == h) return true;
    return false;
}

/// Whether the loop at header `h` writes memory other threads can see
/// (`sharedWrite`).
fn loopWrites(g: *const Graph, m: *const module.Module, insts: []const Inst, h: u32) bool {
    for (0..g.nb) |xi| {
        const x: u32 = @intCast(xi);
        if (!g.reachable(x) or !inLoop(g, x, h)) continue;
        for (insts[g.block_start[x]..g.block_start[x + 1]]) |inst| if (sharedWrite(m, insts, inst)) return true;
    }
    return false;
}

/// Whether `inst` writes memory other threads can see: a store to
/// groupshared memory, an atomic (DXIL has them only on groupshared), or a
/// dx.op buffer or texture store, atomic or counter update. Stores to
/// private memory (allocas, static arrays) don't count.
pub fn sharedWrite(m: *const module.Module, insts: []const Inst, inst: Inst) bool {
    return switch (inst.op) {
        .store => |s| addrSpace(m, insts, s.ptr) == 3,
        .atomicrmw, .cmpxchg => true,
        .call => |c| visibleWrite(m.functions.items[c.callee].name),
        else => false,
    };
}

/// Whether the function named `name` is a dx.op call that writes memory
/// other threads can see.
fn visibleWrite(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "dx.op.")) return false;
    for ([_][]const u8{ "Store", "atomic", "UpdateCounter" }) |s| {
        if (std.mem.indexOf(u8, name, s) != null) return true;
    }
    return false;
}

/// The address space of pointer `v` (0, private, when it has no pointer
/// type).
fn addrSpace(m: *const module.Module, insts: []const Inst, v: Value) u32 {
    const ty = switch (v) {
        .inst => |i| insts[i].ty,
        .global => |gi| m.globals.items[gi].ptr_ty,
        .constant => |c| m.constants.items[c].ty,
        else => return 0,
    };
    return switch (m.types.items[ty]) {
        .pointer => |p| p.addr_space,
        else => 0,
    };
}

test "opaque_trip keeps its edits when declaring the wave op moves the function list" {
    // for (i = 0; i < 4; i++) bufferStore(0, i), in a module whose function
    // list is full, so that declaring dx.op.waveActiveOp.i32 moves it.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var m: module.Module = .init(std.testing.allocator);
    defer m.deinit();
    const ma = m.allocator();
    const i32_ty = try m.intType(32);
    const i1_ty = try m.intType(1);
    const void_ty = try m.getType(.void);
    const store = try m.addFunction(.{ .name = "dx.op.bufferStore.i32", .ty = try m.fnType(void_ty, &.{ i32_ty, i32_ty }), .attrs = .nounwind });
    const f = try m.addFunction(.{ .name = "f", .ty = try m.fnType(void_ty, &.{}), .num_blocks = 3 });
    const zero = try m.constInt(32, 0);
    _ = try m.addInst(f, .{ .ty = void_ty, .op = .{ .br = .{ .then = 1 } } });
    const i = try m.addInst(f, .{ .ty = i32_ty, .op = .{ .phi = .{ .incoming = &.{} } } });
    _ = try m.addInst(f, .{ .ty = void_ty, .op = .{ .call = .{ .callee = store, .args = try ma.dupe(Value, &.{ zero, i }) } } });
    const n = try m.addInst(f, .{ .ty = i32_ty, .op = .{ .binop = .{ .op = .add, .lhs = i, .rhs = try m.constInt(32, 1) } } });
    const c = try m.addInst(f, .{ .ty = i1_ty, .op = .{ .cmp = .{ .pred = 36, .lhs = n, .rhs = try m.constInt(32, 4) } } });
    _ = try m.addInst(f, .{ .ty = void_ty, .op = .{ .br = .{ .then = 1, .@"else" = 2, .cond = c } } });
    _ = try m.addInst(f, .{ .ty = void_ty, .op = .{ .ret = null } });
    m.functions.items[f].insts.items[i.inst].op.phi.incoming = try ma.dupe(Edge, &.{ .{ .val = zero, .block = 0 }, .{ .val = n, .block = 1 } });
    while (m.functions.items.len < m.functions.capacity) _ = try m.addFunction(.{ .name = "pad", .ty = try m.fnType(void_ty, &.{}) });
    const list = m.functions.items.ptr;
    try std.testing.expect(try opaqueTrips(arena.allocator(), &m, f));
    try std.testing.expect(m.functions.items.ptr != list);
    const wave = m.findFunction("dx.op.waveActiveOp.i32").?;
    var calls: u32 = 0;
    for (m.functions.items[f].insts.items) |inst| switch (inst.op) {
        .call => |cl| calls += @intFromBool(cl.callee == wave),
        else => {},
    };
    try std.testing.expectEqual(1, calls);
}
