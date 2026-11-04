//! Promotes locals from memory to SSA values, as LLVM's SROA and mem2reg do
//! for dxc. The emitter gives every local a flattened `[N x scalar]` alloca
//! (or a scalar one); an alloca whose every access is a load or store,
//! directly or through a getelementptr with constant indices, becomes one
//! SSA variable per element, with phis where control flow merges. Locals
//! indexed dynamically stay in memory, but only the components the dynamic
//! index can reach (`dyn`, from the emitter: the indexed array's extent);
//! the rest of such a local is still promoted. Locals used any other way
//! stay in memory.
//!
//! The phis go at the iterated dominance frontiers of the stores (Cytron et
//! al.), dominators by Cooper, Harvey and Kennedy's iteration. Phis whose
//! inputs are all one value, and phis nothing reads, are removed again.

const std = @import("std");
const Allocator = std.mem.Allocator;
const module = @import("module.zig");
const stats = @import("../stats.zig");

const Value = module.Value;
const Inst = module.Inst;
const TypeId = module.TypeId;

const none = std.math.maxInt(u32);

pub const Role = enum { load_ptr, store_ptr, gep_base, other };

const Edge = @typeInfo(@FieldType(@FieldType(@FieldType(Inst, "op"), "phi"), "incoming")).pointer.child;

/// Visits each operand of `inst` (with the way it is used) through
/// `ctx.visit(value, role) Value`. With `write`, the results replace the
/// operands, in newly allocated slices where the operands are slices.
pub fn operands(comptime write: bool, a: Allocator, inst: *Inst, ctx: anytype) Allocator.Error!void {
    const S = struct {
        fn one(c: anytype, v: *Value, role: Role) void {
            const r = c.visit(v.*, role);
            if (write) v.* = r;
        }
        fn many(al: Allocator, c: anytype, vs: *[]const Value) Allocator.Error!void {
            if (!write) {
                for (vs.*) |v| _ = c.visit(v, .other);
                return;
            }
            const out = try al.alloc(Value, vs.len);
            for (vs.*, out) |v, *o| o.* = c.visit(v, .other);
            vs.* = out;
        }
    };
    switch (inst.op) {
        .ret => |*v| if (v.*) |*x| S.one(ctx, x, .other),
        .br => |*b| if (b.cond) |*c| S.one(ctx, c, .other),
        .@"switch" => |*sw| S.one(ctx, &sw.cond, .other),
        .call => |*c| try S.many(a, ctx, &c.args),
        .binop => |*b| {
            S.one(ctx, &b.lhs, .other);
            S.one(ctx, &b.rhs, .other);
        },
        .cast => |*c| S.one(ctx, &c.val, .other),
        .cmp => |*c| {
            S.one(ctx, &c.lhs, .other);
            S.one(ctx, &c.rhs, .other);
        },
        .select => |*s| {
            S.one(ctx, &s.cond, .other);
            S.one(ctx, &s.t, .other);
            S.one(ctx, &s.f, .other);
        },
        .extractvalue => |*x| S.one(ctx, &x.agg, .other),
        .phi => |*p| {
            if (!write) {
                for (p.incoming) |in| _ = ctx.visit(in.val, .other);
            } else {
                const out = try a.alloc(Edge, p.incoming.len);
                for (p.incoming, out) |in, *o| o.* = .{ .val = ctx.visit(in.val, .other), .block = in.block };
                p.incoming = out;
            }
        },
        .alloca => |*x| S.one(ctx, &x.size, .other),
        .load => |*x| S.one(ctx, &x.ptr, .load_ptr),
        .store => |*x| {
            S.one(ctx, &x.ptr, .store_ptr);
            S.one(ctx, &x.val, .other);
        },
        .gep => |*x| {
            S.one(ctx, &x.ptr, .gep_base);
            try S.many(a, ctx, &x.indices);
        },
        .atomicrmw => |*x| {
            S.one(ctx, &x.ptr, .other);
            S.one(ctx, &x.val, .other);
        },
        .cmpxchg => |*x| {
            S.one(ctx, &x.ptr, .other);
            S.one(ctx, &x.cmp, .other);
            S.one(ctx, &x.new, .other);
        },
        .@"unreachable" => {},
        .extractelement => |*x| {
            S.one(ctx, &x.vec, .other);
            S.one(ctx, &x.index, .other);
        },
        .insertelement => |*x| {
            S.one(ctx, &x.vec, .other);
            S.one(ctx, &x.val, .other);
            S.one(ctx, &x.index, .other);
        },
    }
}

fn isTerminator(inst: Inst) bool {
    return switch (inst.op) {
        .ret, .br, .@"switch", .@"unreachable" => true,
        else => false,
    };
}

fn isScalar(m: *const module.Module, ty: TypeId) bool {
    return switch (m.types.items[ty]) {
        .half, .float, .double, .int => true,
        else => false,
    };
}

/// `dyn` maps the dynamically indexed getelementptrs into locals to the
/// components [lo, hi) they can reach; one missing from it can reach all.
pub fn run(a: Allocator, m: *module.Module, func: u32, dyn: *const std.AutoHashMapUnmanaged(u32, [2]u32)) Allocator.Error!void {
    const zone = stats.begin(.promote);
    stats.add(.promote_runs, 1);
    defer zone.end();
    const f = &m.functions.items[func];
    const insts = f.insts.items;
    const n: u32 = @intCast(insts.len);
    const nb = f.num_blocks;
    if (n == 0 or nb == 0) return;

    // Blocks: instruction ranges, successors and predecessors (one entry
    // per edge, so a switch's repeated target counts once per case).
    const block_start = try a.alloc(u32, nb + 1);
    const block_of = try a.alloc(u32, n);
    // The allocas, getelementptrs, and loads and stores, in order: the
    // passes over just those walk these, not every instruction.
    var allocas: std.ArrayList(u32) = .empty;
    var geps: std.ArrayList(u32) = .empty;
    var mems: std.ArrayList(u32) = .empty;
    {
        var b: u32 = 0;
        block_start[0] = 0;
        for (insts, 0..) |inst, i| {
            if (b >= nb) return; // not the block layout this pass expects
            block_of[i] = b;
            switch (inst.op) {
                .alloca => try allocas.append(a, @intCast(i)),
                .gep => try geps.append(a, @intCast(i)),
                .load, .store => try mems.append(a, @intCast(i)),
                else => if (isTerminator(inst)) {
                    b += 1;
                    block_start[b] = @intCast(i + 1);
                },
            }
        }
        if (b != nb) return;
    }
    const succ_off = try a.alloc(u32, nb + 1);
    var succs: std.ArrayList(u32) = .empty;
    for (0..nb) |b| {
        succ_off[b] = @intCast(succs.items.len);
        switch (insts[block_start[b + 1] - 1].op) {
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
    succ_off[nb] = @intCast(succs.items.len);
    const pred_off = try a.alloc(u32, nb + 1);
    @memset(pred_off, 0);
    for (succs.items) |s| pred_off[s + 1] += 1;
    for (1..nb + 1) |b| pred_off[b] += pred_off[b - 1];
    const preds = try a.alloc(u32, succs.items.len);
    {
        const fill = try a.dupe(u32, pred_off[0..nb]);
        for (0..nb) |b| for (succs.items[succ_off[b]..succ_off[b + 1]]) |s| {
            preds[fill[s]] = @intCast(b);
            fill[s] += 1;
        };
    }

    // Reverse postorder from the entry; unreachable blocks stay `none`.
    const rpo_index = try a.alloc(u32, nb);
    @memset(rpo_index, none);
    const rpo = try a.alloc(u32, nb);
    var nr: u32 = 0;
    {
        const post = try a.alloc(u32, nb);
        var np: u32 = 0;
        const seen = try a.alloc(bool, nb);
        @memset(seen, false);
        const Frame = struct { b: u32, next: u32 };
        var stack: std.ArrayList(Frame) = .empty;
        try stack.append(a, .{ .b = 0, .next = succ_off[0] });
        seen[0] = true;
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            if (top.next < succ_off[top.b + 1]) {
                const s = succs.items[top.next];
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
        for (0..np) |k| {
            rpo[k] = post[np - 1 - k];
            rpo_index[rpo[k]] = @intCast(k);
        }
        nr = np;
    }

    // Immediate dominators.
    const idom = try a.alloc(u32, nb);
    @memset(idom, none);
    idom[0] = 0;
    {
        var changed = true;
        while (changed) {
            changed = false;
            for (rpo[1..nr]) |b| {
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
    }

    // Dominance frontiers.
    const df = try a.alloc(std.ArrayList(u32), nb);
    @memset(df, .empty);
    for (rpo[0..nr]) |b| {
        const ps = preds[pred_off[b]..pred_off[b + 1]];
        if (ps.len < 2) continue;
        for (ps) |p| {
            if (rpo_index[p] == none) continue;
            var r = p;
            while (r != idom[b]) {
                const l = &df[r];
                if (l.items.len == 0 or l.items[l.items.len - 1] != b) try l.append(a, b);
                r = idom[r];
            }
        }
    }

    // Candidate allocas: arrays of scalars and scalars. `var_base[i]` is
    // the variable of an alloca's element 0, `none` if it stays in memory.
    const var_base = try a.alloc(u32, n);
    @memset(var_base, none);
    const elem_ty = try a.alloc(TypeId, n);
    const direct = try a.alloc(bool, n);
    for (allocas.items) |i| {
        const x = insts[i].op.alloca;
        switch (m.types.items[x.elem]) {
            .array => |arr| if (isScalar(m, arr.elem) and arr.len > 0) {
                var_base[i] = 0;
                elem_ty[i] = arr.elem;
                direct[i] = false;
            },
            else => if (isScalar(m, x.elem)) {
                var_base[i] = 0;
                elem_ty[i] = x.elem;
                direct[i] = true;
            },
        }
    }
    // getelementptrs of candidates: the alloca and the element they
    // address (`none` for a dynamic index, which pins its range).
    const gep_alloca = try a.alloc(u32, n);
    @memset(gep_alloca, none);
    const gep_k = try a.alloc(u32, n);
    const Scan = struct {
        insts: []const Inst,
        var_base: []u32,
        direct: []const bool,
        gep_alloca: []const u32,

        fn visit(s: *@This(), v: Value, role: Role) Value {
            if (v != .inst) return v;
            const i = v.inst;
            if (s.var_base[i] != none and s.insts[i].op == .alloca) {
                const ok = switch (role) {
                    .gep_base => !s.direct[i],
                    .load_ptr, .store_ptr => s.direct[i],
                    .other => false,
                };
                if (!ok) s.var_base[i] = none;
            } else if (s.gep_alloca[i] != none and role != .load_ptr and role != .store_ptr) {
                s.var_base[s.gep_alloca[i]] = none;
            }
            return v;
        }
    };
    // (Code no path reaches, such as loops unrolling left behind, does
    // not count.)
    for (geps.items) |i| if (rpo_index[block_of[i]] != none) {
        const g = insts[i].op.gep;
        if (g.ptr == .inst and var_base[g.ptr.inst] != none and insts[g.ptr.inst].op == .alloca) {
            const al = g.ptr.inst;
            if (direct[al]) {
                var_base[al] = none;
                continue;
            }
            const k = constIndex(m, g.indices, m.types.items[insts[al].op.alloca.elem].array.len);
            if (k) |kk| {
                gep_alloca[i] = al;
                gep_k[i] = kk;
            } else if (dyn.contains(i) and g.indices.len == 2 and constInt(m, g.indices[0]) == 0) {
                gep_alloca[i] = al;
                gep_k[i] = none;
            } else var_base[al] = none;
        }
    };
    {
        var scan: Scan = .{ .insts = insts, .var_base = var_base, .direct = direct, .gep_alloca = gep_alloca };
        for (insts, 0..) |*inst, i| if (rpo_index[block_of[i]] != none) try operands(false, a, inst, &scan);
    }
    // Loads and stores must move whole elements of the element type.
    for (mems.items) |i| {
        if (rpo_index[block_of[i]] == none) continue;
        const inst = insts[i];
        const ptr, const ty = switch (inst.op) {
            .load => |x| .{ x.ptr, inst.ty },
            .store => |x| .{ x.ptr, typeOf(m, f, x.val) },
            else => continue,
        };
        if (ptr != .inst) continue;
        const al = if (gep_alloca[ptr.inst] != none) gep_alloca[ptr.inst] else ptr.inst;
        if (var_base[al] != none and insts[al].op == .alloca and ty != elem_ty[al]) var_base[al] = none;
    }

    // Variables.
    var nv: u32 = 0;
    for (allocas.items) |i| {
        const inst = insts[i];
        if (var_base[i] == none) continue;
        var_base[i] = nv;
        nv += if (direct[i]) 1 else @intCast(m.types.items[inst.op.alloca.elem].array.len);
    }
    const var_ty = try a.alloc(TypeId, nv);
    for (allocas.items) |i| {
        const inst = insts[i];
        if (var_base[i] == none) continue;
        const len: u32 = if (direct[i]) 1 else @intCast(m.types.items[inst.op.alloca.elem].array.len);
        @memset(var_ty[var_base[i]..][0..len], elem_ty[i]);
    }
    // Components a dynamic index can reach stay in memory, and so does
    // their alloca.
    const pinned = try a.alloc(bool, nv);
    @memset(pinned, false);
    const keep = try a.alloc(bool, n);
    @memset(keep, false);
    for (geps.items) |i| {
        if (gep_alloca[i] == none or gep_k[i] != none) continue;
        const al = gep_alloca[i];
        if (var_base[al] == none) continue;
        const len: u32 = @intCast(m.types.items[insts[al].op.alloca.elem].array.len);
        const r = dyn.get(i).?;
        const lo = @min(r[0], len);
        const hi = @min(r[1], len);
        @memset(pinned[var_base[al] + lo .. var_base[al] + hi], true);
        keep[al] = true;
    }
    // The variable an instruction loads or stores, or `none`.
    const access = try a.alloc(u32, n);
    @memset(access, none);
    for (mems.items) |i| {
        const ptr = switch (insts[i].op) {
            .load => |x| x.ptr,
            .store => |x| x.ptr,
            else => unreachable,
        };
        if (ptr != .inst) continue;
        const p = ptr.inst;
        if (gep_alloca[p] != none and var_base[gep_alloca[p]] != none) {
            if (gep_k[p] != none and !pinned[var_base[gep_alloca[p]] + gep_k[p]]) access[i] = var_base[gep_alloca[p]] + gep_k[p];
        } else if (insts[p].op == .alloca and var_base[p] != none) {
            access[i] = var_base[p];
        }
    }

    // A variable needs phis unless all its accesses are in one block and
    // the first is a store. Collect the blocks that store the others.
    const first_block = try a.alloc(u32, nv);
    @memset(first_block, none);
    const global = try a.alloc(bool, nv);
    @memset(global, false);
    for (mems.items) |i| {
        const v = access[i];
        if (v == none) continue;
        if (first_block[v] == none) {
            first_block[v] = block_of[i];
            if (insts[i].op == .load) global[v] = true;
        } else if (first_block[v] != block_of[i]) global[v] = true;
    }
    const Def = struct { v: u32, b: u32 };
    var defs: std.ArrayList(Def) = .empty;
    for (mems.items) |i| {
        const v = access[i];
        if (v == none or insts[i].op != .store or !global[v] or rpo_index[block_of[i]] == none) continue;
        try defs.append(a, .{ .v = v, .b = block_of[i] });
    }
    std.sort.pdq(Def, defs.items, {}, struct {
        fn lt(_: void, x: Def, y: Def) bool {
            return if (x.v != y.v) x.v < y.v else x.b < y.b;
        }
    }.lt);

    // Phis at the iterated dominance frontiers.
    var phi_var: std.ArrayList(u32) = .empty;
    var phi_block: std.ArrayList(u32) = .empty;
    {
        const has_phi = try a.alloc(u32, nb);
        @memset(has_phi, none);
        const queued = try a.alloc(u32, nb);
        @memset(queued, none);
        var work: std.ArrayList(u32) = .empty;
        var k: usize = 0;
        while (k < defs.items.len) {
            const v = defs.items[k].v;
            work.clearRetainingCapacity();
            while (k < defs.items.len and defs.items[k].v == v) : (k += 1) {
                const b = defs.items[k].b;
                if (queued[b] != v) {
                    queued[b] = v;
                    try work.append(a, b);
                }
            }
            while (work.pop()) |b| for (df[b].items) |y| {
                if (has_phi[y] == v) continue;
                has_phi[y] = v;
                try phi_var.append(a, v);
                try phi_block.append(a, y);
                if (queued[y] != v) {
                    queued[y] = v;
                    try work.append(a, y);
                }
            };
        }
    }
    const np: u32 = @intCast(phi_var.items.len);
    // Phis per block, and their incoming edges (filled while renaming).
    const bphi_off = try a.alloc(u32, nb + 1);
    @memset(bphi_off, 0);
    for (phi_block.items) |b| bphi_off[b + 1] += 1;
    for (1..nb + 1) |b| bphi_off[b] += bphi_off[b - 1];
    const bphis = try a.alloc(u32, np);
    {
        const fill = try a.dupe(u32, bphi_off[0..nb]);
        for (phi_block.items, 0..) |b, j| {
            bphis[fill[b]] = @intCast(j);
            fill[b] += 1;
        }
    }
    const incoming = try a.alloc([]Edge, np);
    const filled = try a.alloc(u32, np);
    @memset(filled, 0);
    for (incoming, phi_block.items) |*in, b| in.* = try a.alloc(Edge, pred_off[b + 1] - pred_off[b]);

    // Renaming, over the dominator tree. A load's replacement goes to
    // `repl`; phi `j` is the value `.{ .inst = n + j }` until rebuilt.
    // A local read before any store reads zero: the validator rejects
    // instructions that read undef.
    var zeros: std.AutoHashMapUnmanaged(TypeId, Value) = .empty;
    const Zero = struct {
        fn get(al: Allocator, mm: *module.Module, cache: *std.AutoHashMapUnmanaged(TypeId, Value), ty: TypeId) Allocator.Error!Value {
            const gop = try cache.getOrPut(al, ty);
            if (!gop.found_existing) gop.value_ptr.* = try mm.constant(.{ .ty = ty, .kind = switch (mm.types.items[ty]) {
                .int => .{ .int = 0 },
                else => .{ .float_bits = 0 },
            } });
            return gop.value_ptr.*;
        }
    };
    const repl = try a.alloc(?Value, n + np);
    @memset(repl, null);
    const cur = try a.alloc(Value, nv);
    for (cur, var_ty) |*c, t| c.* = try Zero.get(a, m, &zeros, t);
    {
        const child_off = try a.alloc(u32, nb + 1);
        @memset(child_off, 0);
        for (rpo[1..nr]) |b| child_off[idom[b] + 1] += 1;
        for (1..nb + 1) |b| child_off[b] += child_off[b - 1];
        const children = try a.alloc(u32, nr);
        {
            const fill = try a.dupe(u32, child_off[0..nb]);
            for (rpo[1..nr]) |b| {
                children[fill[idom[b]]] = b;
                fill[idom[b]] += 1;
            }
        }
        const Undo = struct { v: u32, old: Value };
        var log: std.ArrayList(Undo) = .empty;
        const Visit = struct { b: u32, mark: u32, enter: bool };
        var stack: std.ArrayList(Visit) = .empty;
        try stack.append(a, .{ .b = 0, .mark = 0, .enter = true });
        while (stack.pop()) |top| {
            if (!top.enter) {
                while (log.items.len > top.mark) {
                    const u = log.pop().?;
                    cur[u.v] = u.old;
                }
                continue;
            }
            const b = top.b;
            try stack.append(a, .{ .b = b, .mark = @intCast(log.items.len), .enter = false });
            for (bphis[bphi_off[b]..bphi_off[b + 1]]) |j| {
                const v = phi_var.items[j];
                try log.append(a, .{ .v = v, .old = cur[v] });
                cur[v] = .{ .inst = n + j };
            }
            for (block_start[b]..block_start[b + 1]) |i| {
                const v = access[i];
                if (v == none) continue;
                switch (insts[i].op) {
                    .load => repl[i] = cur[v],
                    .store => |x| {
                        try log.append(a, .{ .v = v, .old = cur[v] });
                        cur[v] = resolve(repl, x.val);
                    },
                    else => unreachable,
                }
            }
            for (succs.items[succ_off[b]..succ_off[b + 1]]) |s| for (bphis[bphi_off[s]..bphi_off[s + 1]]) |j| {
                incoming[j][filled[j]] = .{ .val = cur[phi_var.items[j]], .block = b };
                filled[j] += 1;
            };
            for (children[child_off[b]..child_off[b + 1]]) |c| try stack.append(a, .{ .b = c, .mark = 0, .enter = true });
        }
    }
    // Edges from unreachable blocks bring zero; loads there read zero.
    for (0..np) |j| {
        const b = phi_block.items[j];
        for (preds[pred_off[b]..pred_off[b + 1]]) |p| {
            if (rpo_index[p] != none) continue;
            incoming[j][filled[j]] = .{ .val = try Zero.get(a, m, &zeros, var_ty[phi_var.items[j]]), .block = p };
            filled[j] += 1;
        }
    }
    for (mems.items) |i| {
        if (access[i] != none and insts[i].op == .load and repl[i] == null)
            repl[i] = try Zero.get(a, m, &zeros, var_ty[access[i]]);
    }

    // Phis whose inputs (besides themselves) are one value become it.
    const removed_phi = try a.alloc(bool, np);
    @memset(removed_phi, false);
    {
        var changed = true;
        while (changed) {
            changed = false;
            for (0..np) |j| {
                if (removed_phi[j]) continue;
                const self: Value = .{ .inst = n + @as(u32, @intCast(j)) };
                var same: ?Value = null;
                var trivial = true;
                for (incoming[j]) |in| {
                    const x = resolve(repl, in.val);
                    if (std.meta.eql(x, self)) continue;
                    if (same) |s| {
                        if (!std.meta.eql(s, x)) {
                            trivial = false;
                            break;
                        }
                    } else same = x;
                }
                if (!trivial) continue;
                repl[n + j] = same orelse try Zero.get(a, m, &zeros, var_ty[phi_var.items[j]]);
                removed_phi[j] = true;
                changed = true;
            }
        }
    }

    // Peepholes on what promotion exposes, in instruction order so they
    // cascade: bitcast round trips (locals mixing ints and floats store
    // i32s), constant integer arithmetic and comparisons, identities, and
    // selects on a constant.
    for (insts, 0..) |inst, i| {
        if (repl[i] != null) continue;
        if (inst.op == .phi) if (try edgePhi(m, insts, block_start, repl, n, block_of[i], inst)) |v| {
            repl[i] = v;
            continue;
        };
        repl[i] = try simplify(m, f, repl, n, phi_var.items, var_ty, inst);
    }

    // Branches on what is now a constant go one way (as dxc's simplifycfg
    // makes them): blocks no longer reachable keep only an `unreachable`,
    // and phis lose the edges that are gone.
    var reach = try foldConstantBranches(a, m, insts, block_start, repl, bphis, bphi_off, incoming);

    // The instructions that go: promoted allocas, their getelementptrs,
    // loads and stores.
    const removed = try a.alloc(bool, n);
    @memset(removed, false);
    for (allocas.items) |i| removed[i] = var_base[i] != none and !keep[i];
    for (geps.items) |i| removed[i] = gep_alloca[i] != none and var_base[gep_alloca[i]] != none and gep_k[i] != none and !pinned[var_base[gep_alloca[i]] + gep_k[i]];
    for (mems.items) |i| removed[i] = access[i] != none;

    // What stays: instructions with effects, and what they read,
    // transitively; new phis likewise. (The loads promotion leaves dead,
    // such as copies of arguments never read, go too.)
    const live = try a.alloc(bool, n + np);
    // (What has effects, worked out once for every round.)
    var effects: std.ArrayList(u32) = .empty;
    for (insts, 0..) |inst, i| if (!removed[i] and hasEffects(m, inst)) try effects.append(a, @intCast(i));
    while (true) {
        @memset(live, false);
        {
            var work: std.ArrayList(u32) = .empty;
            const Mark = struct {
                repl: []const ?Value,
                live: []bool,
                removed: []const bool,
                work: *std.ArrayList(u32),
                a: Allocator,
                failed: bool = false,

                fn visit(s: *@This(), v: Value, _: Role) Value {
                    const x = resolve(s.repl, v);
                    if (x == .inst and !s.live[x.inst] and !(x.inst < s.removed.len and s.removed[x.inst])) {
                        s.live[x.inst] = true;
                        s.work.append(s.a, x.inst) catch {
                            s.failed = true;
                        };
                    }
                    return v;
                }
            };
            var mark: Mark = .{ .repl = repl, .live = live, .removed = removed, .work = &work, .a = a };
            for (effects.items) |i| if (reach[block_of[i]] or i == block_start[block_of[i] + 1] - 1) {
                live[i] = true;
                try work.append(a, i);
            };
            while (work.pop()) |x| {
                if (x < n) {
                    var inst = insts[x];
                    try operands(false, a, &inst, &mark);
                } else for (incoming[x - n]) |in| {
                    _ = mark.visit(in.val, .other);
                }
            }
            if (mark.failed) return error.OutOfMemory;
        }
        // A branch whose arms do nothing (live) and meet again, with the
        // same values for the merge's phis, goes nowhere: its condition
        // becomes `true` (dxc's simplifycfg removes the branch) and liveness
        // runs again without what only the condition read.
        if (!try foldEmptyBranches(a, m, insts, block_start, reach, live, repl, n, bphis, bphi_off, incoming)) break;
        reach = try foldConstantBranches(a, m, insts, block_start, repl, bphis, bphi_off, incoming);
    }

    // New indices: in each block the existing phis, then the new ones,
    // then the rest.
    // (Blocks no path reaches go: the validator rejects `unreachable`.)
    const new_block = try a.alloc(u32, nb);
    var kept: u32 = 0;
    for (new_block, reach) |*nbk, r| {
        nbk.* = if (r) kept else none;
        if (r) kept += 1;
    }
    const index = try a.alloc(u32, n + np);
    @memset(index, none);
    var count: u32 = 0;
    for (0..nb) |b| {
        if (!reach[b]) continue;
        var i = block_start[b];
        while (i < block_start[b + 1] and insts[i].op == .phi) : (i += 1) if (live[i]) {
            index[i] = count;
            count += 1;
        };
        for (bphis[bphi_off[b]..bphi_off[b + 1]]) |j| if (live[n + j]) {
            index[n + j] = count;
            count += 1;
        };
        while (i < block_start[b + 1]) : (i += 1) if (live[i]) {
            index[i] = count;
            count += 1;
        };
    }
    const Map = struct {
        repl: []const ?Value,
        index: []const u32,
        fn visit(s: *@This(), v: Value, _: Role) Value {
            const x = resolve(s.repl, v);
            return if (x == .inst) .{ .inst = s.index[x.inst] } else x;
        }
    };
    var map: Map = .{ .repl = repl, .index = index };
    const ma = m.allocator();
    var out: std.ArrayList(Inst) = .empty;
    try out.ensureTotalCapacityPrecise(ma, count);
    for (0..nb) |b| {
        if (!reach[b]) continue;
        var i = block_start[b];
        while (i < block_start[b + 1] and insts[i].op == .phi) : (i += 1) if (live[i]) {
            var inst = insts[i];
            try operands(true, ma, &inst, &map);
            const edges = try ma.alloc(Edge, inst.op.phi.incoming.len);
            for (inst.op.phi.incoming, edges) |in, *e| e.* = .{ .val = in.val, .block = new_block[in.block] };
            inst.op.phi.incoming = edges;
            out.appendAssumeCapacity(inst);
        };
        for (bphis[bphi_off[b]..bphi_off[b + 1]]) |j| if (live[n + j]) {
            const edges = try ma.alloc(Edge, incoming[j].len);
            for (incoming[j], edges) |in, *e| e.* = .{ .val = map.visit(in.val, .other), .block = new_block[in.block] };
            out.appendAssumeCapacity(.{ .ty = var_ty[phi_var.items[j]], .op = .{ .phi = .{ .incoming = edges } } });
        };
        while (i < block_start[b + 1]) : (i += 1) if (live[i]) {
            var inst = insts[i];
            try operands(true, ma, &inst, &map);
            if (inst.op == .gep) try clampIndex(m, &inst.op.gep);
            switch (inst.op) {
                .br => |*br| {
                    br.then = new_block[br.then];
                    if (br.@"else") |*e| e.* = new_block[e.*];
                },
                .@"switch" => |*sw| {
                    sw.default = new_block[sw.default];
                    const cs = try ma.alloc(@typeInfo(@TypeOf(sw.cases)).pointer.child, sw.cases.len);
                    for (sw.cases, cs) |c, *o| o.* = .{ .val = c.val, .block = new_block[c.block] };
                    sw.cases = cs;
                },
                else => {},
            }
            out.appendAssumeCapacity(inst);
        };
    }
    f.insts = out;
    f.num_blocks = kept;
}

/// See run. Returns the blocks still reachable.
fn foldConstantBranches(a: Allocator, m: *module.Module, insts: []Inst, block_start: []const u32, repl: []const ?Value, bphis: []const u32, bphi_off: []const u32, incoming: [][]Edge) Allocator.Error![]bool {
    const nb = block_start.len - 1;
    for (0..nb) |b| {
        const term = &insts[block_start[b + 1] - 1];
        if (term.op != .br) continue;
        const br = term.op.br;
        const cond = br.cond orelse continue;
        const els = br.@"else" orelse continue;
        const c = constInt(m, resolve(repl, cond)) orelse continue;
        term.op = .{ .br = .{ .then = if (c != 0) br.then else els } };
    }
    // Switches on a constant too.
    for (0..nb) |b| {
        const term = &insts[block_start[b + 1] - 1];
        if (term.op != .@"switch") continue;
        const sw = term.op.@"switch";
        const c = constInt(m, resolve(repl, sw.cond)) orelse continue;
        var target = sw.default;
        for (sw.cases) |cs| if (constInt(m, cs.val) == c) {
            target = cs.block;
        };
        term.op = .{ .br = .{ .then = target } };
    }
    const reach = try a.alloc(bool, nb);
    @memset(reach, false);
    var stack: std.ArrayList(u32) = .empty;
    try stack.append(a, 0);
    while (stack.pop()) |b| {
        if (reach[b]) continue;
        reach[b] = true;
        switch (insts[block_start[b + 1] - 1].op) {
            .br => |br| {
                try stack.append(a, br.then);
                if (br.@"else") |e| try stack.append(a, e);
            },
            .@"switch" => |sw| {
                try stack.append(a, sw.default);
                for (sw.cases) |cs| try stack.append(a, cs.block);
            },
            else => {},
        }
    }
    const Edges = struct {
        insts: []const Inst,
        block_start: []const u32,
        reach: []const bool,
        /// How many edges go from `p` to `t` (a phi has an entry per edge).
        fn count(s: @This(), p: u32, t: u32) u32 {
            if (!s.reach[p]) return 0;
            return switch (s.insts[s.block_start[p + 1] - 1].op) {
                .br => |br| @as(u32, @intFromBool(br.then == t)) + @intFromBool(br.@"else" == t),
                .@"switch" => |sw| blk: {
                    var k: u32 = @intFromBool(sw.default == t);
                    for (sw.cases) |cs| k += @intFromBool(cs.block == t);
                    break :blk k;
                },
                else => 0,
            };
        }
        /// Whether each entry of `ins` (from `ins[x].block`) is one of the
        /// edges to `t` there still are: the k-th entry from a block is,
        /// if the block has more than k edges to `t`. `seen` and `edges_to`
        /// are per-block scratch (0 and `none`), left as they were.
        fn keeps(s: @This(), ins: []const Edge, t: u32, seen: []u32, edges_to: []u32, out: []bool) void {
            for (ins, out) |in, *o| {
                if (edges_to[in.block] == none) edges_to[in.block] = s.count(in.block, t);
                o.* = seen[in.block] < edges_to[in.block];
                seen[in.block] += 1;
            }
            for (ins) |in| {
                seen[in.block] = 0;
                edges_to[in.block] = none;
            }
        }
    };
    const edges: Edges = .{ .insts = insts, .block_start = block_start, .reach = reach };
    const seen = try a.alloc(u32, nb);
    @memset(seen, 0);
    const edges_to = try a.alloc(u32, nb);
    @memset(edges_to, none);
    var kept: std.ArrayList(bool) = .empty;
    // Edges into each block from reachable ones. A phi has an entry per
    // edge, and folding only takes edges away: one with that many entries
    // lost none.
    const into = try a.alloc(u32, nb);
    @memset(into, 0);
    for (0..nb) |p| if (reach[p]) switch (insts[block_start[p + 1] - 1].op) {
        .br => |br| {
            into[br.then] += 1;
            if (br.@"else") |e| into[e] += 1;
        },
        .@"switch" => |sw| {
            into[sw.default] += 1;
            for (sw.cases) |cs| into[cs.block] += 1;
        },
        else => {},
    };
    for (0..nb) |b| {
        const t: u32 = @intCast(b);
        const last = block_start[b + 1] - 1;
        if (!reach[b]) {
            insts[last].op = .@"unreachable";
            continue;
        }
        var i = block_start[b];
        while (i < last and insts[i].op == .phi) : (i += 1) {
            const old = insts[i].op.phi.incoming;
            if (old.len == into[b]) continue;
            kept.clearRetainingCapacity();
            try kept.resize(a, old.len);
            edges.keeps(old, t, seen, edges_to, kept.items);
            const keep = std.mem.count(bool, kept.items, &.{true});
            if (keep == old.len) continue;
            const new = try m.allocator().alloc(Edge, keep);
            var k: usize = 0;
            for (old, kept.items) |in, kp| if (kp) {
                new[k] = in;
                k += 1;
            };
            insts[i].op.phi.incoming = new;
        }
        for (bphis[bphi_off[b]..bphi_off[b + 1]]) |j| {
            // (Kept entries move down; each is checked against those
            // before it in the original order.)
            const ins = incoming[j];
            if (ins.len == into[b]) continue;
            kept.clearRetainingCapacity();
            try kept.resize(a, ins.len);
            edges.keeps(ins, t, seen, edges_to, kept.items);
            var k: usize = 0;
            for (ins, kept.items) |in, kp| if (kp) {
                incoming[j][k] = in;
                k += 1;
            };
            incoming[j] = incoming[j][0..k];
        }
    }
    return reach;
}

/// See run: rewrites such branches' conditions; true if any changed.
fn foldEmptyBranches(a: Allocator, m: *module.Module, insts: []Inst, block_start: []const u32, reach: []const bool, live: []const bool, repl: []const ?Value, n: u32, bphis: []const u32, bphi_off: []const u32, incoming: []const []Edge) Allocator.Error!bool {
    const nb = block_start.len - 1;
    var changed = false;
    const from_of = try a.alloc(u32, nb);
    @memset(from_of, none);
    var marked: std.ArrayList(u32) = .empty;
    for (0..nb) |b| {
        if (!reach[b]) continue;
        const term = &insts[block_start[b + 1] - 1];
        if (term.op != .br) continue;
        const br = term.op.br;
        const cond = br.cond orelse continue;
        if (cond != .inst) continue;
        const f_ = br.@"else" orelse continue;
        // Each side: the block it lands in, and the predecessor that
        // edge reaches it from.
        const Side = struct { land: u32, from: u32 };
        // Each side's way on: the blocks it lands in, through empty blocks
        // (only an unconditional branch live, and no live phis; other
        // branches may enter them too, the way on is the same). The first
        // side's marks each block it lands in with the edge it came by;
        // the second stops where it lands in a marked one.
        var sides: [2]Side = undefined;
        var met = false;
        marked.clearRetainingCapacity();
        for ([2]u32{ br.then, f_ }, 0..) |t0, k| {
            var side: Side = .{ .land = t0, .from = @intCast(b) };
            var steps: usize = 0;
            while (steps <= nb) : (steps += 1) {
                if (k == 0) {
                    if (from_of[side.land] != none) break; // a cycle
                    from_of[side.land] = side.from;
                    try marked.append(a, side.land);
                } else if (from_of[side.land] != none) {
                    sides = .{ .{ .land = side.land, .from = from_of[side.land] }, side };
                    met = true;
                    break;
                }
                const t = side.land;
                const last = block_start[t + 1] - 1;
                if (insts[last].op != .br) break;
                // (A branch on a constant goes one way.)
                const tb = insts[last].op.br;
                const next = if (tb.cond) |c| blk: {
                    const kc = constInt(m, resolve(repl, c)) orelse break;
                    break :blk if (kc != 0) tb.then else tb.@"else" orelse tb.then;
                } else tb.then;
                var empty = true;
                for (block_start[t]..last) |i| if (live[i]) {
                    empty = false;
                };
                for (bphis[bphi_off[t]..bphi_off[t + 1]]) |j| if (live[n + j]) {
                    empty = false;
                };
                if (!empty) break;
                side = .{ .land = next, .from = t };
            }
        }
        for (marked.items) |x| from_of[x] = none;
        if (!met or sides[0].from == sides[1].from) continue;
        const mb = sides[0].land;
        // The merge's phis take the same value from both sides.
        var same = true;
        var i = block_start[mb];
        while (i < block_start[mb + 1] and insts[i].op == .phi) : (i += 1) if (live[i]) {
            var vals: [2]?Value = .{ null, null };
            for (insts[i].op.phi.incoming) |in| for (sides, 0..) |sd, k| if (in.block == sd.from) {
                vals[k] = resolve(repl, in.val);
            };
            if (vals[0] == null or vals[1] == null or !std.meta.eql(vals[0].?, vals[1].?)) same = false;
        };
        for (bphis[bphi_off[mb]..bphi_off[mb + 1]]) |j| if (live[n + j]) {
            var vals: [2]?Value = .{ null, null };
            for (incoming[j]) |in| for (sides, 0..) |sd, k| if (in.block == sd.from) {
                vals[k] = resolve(repl, in.val);
            };
            if (vals[0] == null or vals[1] == null or !std.meta.eql(vals[0].?, vals[1].?)) same = false;
        };
        if (!same) continue;
        term.op.br.cond = try m.constInt(1, 1);
        changed = true;
    }
    return changed;
}

/// An index into an array that folding made a constant out of range (on
/// a path that cannot run: the access would be undefined) becomes 0, as
/// the validator rejects constant out-of-bounds accesses.
fn clampIndex(m: *module.Module, g: *@FieldType(@FieldType(Inst, "op"), "gep")) Allocator.Error!void {
    if (g.indices.len != 2) return;
    const len = switch (m.types.items[g.elem]) {
        .array => |arr| arr.len,
        else => return,
    };
    const k = constInt(m, g.indices[1]) orelse return;
    if (k >= 0 and k < len) return;
    const ix = try m.allocator().dupe(Value, g.indices);
    ix[1] = try m.constant(.{ .ty = m.constants.items[g.indices[1].constant].ty, .kind = .{ .int = 0 } });
    g.indices = ix;
}

/// A simpler value for `inst`, or null.
fn simplify(m: *module.Module, f: *const module.Function, repl: []const ?Value, n: u32, phi_var: []const u32, var_ty: []const TypeId, inst: Inst) Allocator.Error!?Value {
    const S = struct {
        fn ty(mm: *const module.Module, ff: *const module.Function, nn: u32, pv: []const u32, vt: []const TypeId, v: Value) TypeId {
            if (v == .inst and v.inst >= nn) return vt[pv[v.inst - nn]];
            return typeOf(mm, ff, v);
        }
        fn intWidth(mm: *const module.Module, t: TypeId) ?u32 {
            return switch (mm.types.items[t]) {
                .int => |w| w,
                else => null,
            };
        }
        /// `v` as a `w`-bit pattern.
        fn bits(v: i64, w: u32) u64 {
            const u: u64 = @bitCast(v);
            return if (w >= 64) u else u & ((@as(u64, 1) << @intCast(w)) - 1);
        }
        /// A `w`-bit pattern as stored: 0 / 1 for i1, sign-extended above.
        fn stored(p: u64, w: u32) i64 {
            if (w == 1) return @intCast(p & 1);
            if (w >= 64) return @bitCast(p);
            const sh: u6 = @intCast(64 - w);
            return @as(i64, @bitCast(p << sh)) >> sh;
        }
    };
    switch (inst.op) {
        // A phi taking one value on every edge is that value.
        .phi => |p| {
            if (p.incoming.len == 0) return null;
            const first = resolve(repl, p.incoming[0].val);
            if (first == .inst and first.inst < n and std.meta.eql(f.insts.items[first.inst].op, inst.op)) return null;
            for (p.incoming[1..]) |in| if (!std.meta.eql(resolve(repl, in.val), first)) return null;
            return first;
        },
        .cast => |c| {
            // Integer widening and narrowing of a constant.
            if (c.op == .zext or c.op == .sext or c.op == .trunc) {
                const v = resolve(repl, c.val);
                const k = constInt(m, v) orelse return null;
                const from = S.intWidth(m, typeOf(m, f, v)) orelse return null;
                const to = S.intWidth(m, inst.ty) orelse return null;
                const p = S.bits(k, from);
                const out: u64 = switch (c.op) {
                    .zext => p,
                    // (i1 is stored as 0 / 1: true sign-extends to all ones.)
                    .sext => if (from == 1) (if (p & 1 != 0) ~@as(u64, 0) else 0) else @bitCast(S.stored(p, from)),
                    else => p,
                };
                return try m.constant(.{ .ty = inst.ty, .kind = .{ .int = S.stored(S.bits(@bitCast(out), to), to) } });
            }
            if (c.op != .bitcast) return null;
            const x = resolve(repl, c.val);
            if (x == .inst and x.inst < n) {
                const inner = f.insts.items[x.inst].op;
                if (inner == .cast and inner.cast.op == .bitcast) {
                    const src = resolve(repl, inner.cast.val);
                    if (S.ty(m, f, n, phi_var, var_ty, src) == inst.ty) return src;
                }
            }
            if (x == .constant) {
                const k = m.constants.items[x.constant].kind;
                const w: u32 = switch (m.types.items[inst.ty]) {
                    .int => |iw| iw,
                    .half => 16,
                    .float => 32,
                    .double => 64,
                    else => return null,
                };
                const p: u64 = switch (k) {
                    .int => |v| S.bits(v, w),
                    .float_bits => |b| b,
                    else => return null,
                };
                return try m.constant(.{ .ty = inst.ty, .kind = switch (m.types.items[inst.ty]) {
                    .int => .{ .int = S.stored(p, w) },
                    else => .{ .float_bits = p },
                } });
            }
            return null;
        },
        .binop => |b| {
            if (try foldFloat(m, repl, inst)) |v| return v;
            const w = S.intWidth(m, inst.ty) orelse return null;
            const l = resolve(repl, b.lhs);
            const r = resolve(repl, b.rhs);
            const lc = constInt(m, l);
            const rc = constInt(m, r);
            if (lc != null and rc != null) {
                const x = S.bits(lc.?, w);
                const y = S.bits(rc.?, w);
                const sx = S.stored(x, w);
                const sy = S.stored(y, w);
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
                return try m.constant(.{ .ty = inst.ty, .kind = .{ .int = S.stored(S.bits(@bitCast(p), w), w) } });
            }
            if (rc) |y| switch (b.op) {
                .add, .sub, .@"or", .xor, .shl, .lshr, .ashr => if (y == 0) return l,
                .mul, .udiv, .sdiv => if (S.bits(y, w) == 1) return l,
                .@"and" => if (S.bits(y, w) == S.bits(-1, w)) return l,
                else => {},
            };
            if (lc) |x| switch (b.op) {
                .add, .@"or", .xor => if (x == 0) return r,
                .mul => if (S.bits(x, w) == 1) return r,
                .@"and" => if (S.bits(x, w) == S.bits(-1, w)) return r,
                else => {},
            };
            if (b.op == .@"and" and w <= 64) {
                if (rc) |y| return andKnown(m, f, repl, n, l, S.bits(y, w), w, inst.ty);
                if (lc) |x| return andKnown(m, f, repl, n, r, S.bits(x, w), w, inst.ty);
            }
            return null;
        },
        .cmp => |c| {
            const l = resolve(repl, c.lhs);
            const r = resolve(repl, c.rhs);
            if (c.pred <= 15) {
                // Floating-point predicates on two constants (ordered:
                // false with a NaN; unordered: true).
                const x = constFloat(m, l) orelse return null;
                const y = constFloat(m, r) orelse return null;
                const uno = std.math.isNan(x) or std.math.isNan(y);
                const t = switch (c.pred) {
                    0 => false,
                    1 => !uno and x == y,
                    2 => !uno and x > y,
                    3 => !uno and x >= y,
                    4 => !uno and x < y,
                    5 => !uno and x <= y,
                    6 => !uno and x != y,
                    7 => !uno,
                    8 => uno,
                    9 => uno or x == y,
                    10 => uno or x > y,
                    11 => uno or x >= y,
                    12 => uno or x < y,
                    13 => uno or x <= y,
                    14 => uno or x != y,
                    else => true,
                };
                return try m.constant(.{ .ty = inst.ty, .kind = .{ .int = @intFromBool(t) } });
            }
            if (c.pred < 32 or c.pred > 41) return null; // integer predicates
            // A bool widened and compared again: `zext i1 x != 0` and
            // `zext i1 x == 1` are x.
            if (c.pred == 32 or c.pred == 33) if (l == .inst and l.inst < n) {
                const z = f.insts.items[l.inst].op;
                if (z == .cast and z.cast.op == .zext) {
                    const x = resolve(repl, z.cast.val);
                    if (S.intWidth(m, S.ty(m, f, n, phi_var, var_ty, x)) == 1) {
                        if (constInt(m, r)) |k| {
                            if ((c.pred == 33 and k == 0) or (c.pred == 32 and k == 1)) return x;
                        }
                    }
                }
            };
            const w = S.intWidth(m, S.ty(m, f, n, phi_var, var_ty, l)) orelse return null;
            // Each side's possible values: a constant, or selects and phis
            // of constants (`(c ? 2 : 1) == 3` is false, as dxc's
            // instcombine finds); the same answer for every pair folds.
            var lv: Cands = .{};
            var rv: Cands = .{};
            if (!lv.add(m, f, repl, n, l, 2) or !rv.add(m, f, repl, n, r, 2)) return null;
            var result: ?bool = null;
            for (lv.vals[0..lv.len]) |lk| for (rv.vals[0..rv.len]) |rk| {
                const x = S.bits(lk, w);
                const y = S.bits(rk, w);
                const sx = S.stored(x, w);
                const sy = S.stored(y, w);
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
                if (result) |prev| if (prev != t) return null;
                result = t;
            };
            return try m.constant(.{ .ty = inst.ty, .kind = .{ .int = @intFromBool(result orelse return null) } });
        },
        .call => return foldDxOp(m, repl, inst),
        .select => |sl| {
            const t = resolve(repl, sl.t);
            const fv = resolve(repl, sl.f);
            if (std.meta.eql(t, fv)) return t;
            const c = constInt(m, resolve(repl, sl.cond)) orelse return null;
            return if (c != 0) t else fv;
        },
        else => return null,
    }
}

/// Instructions that must stay even when nothing reads their result.
fn hasEffects(m: *const module.Module, inst: Inst) bool {
    return switch (inst.op) {
        .ret, .br, .@"switch", .@"unreachable", .store, .atomicrmw, .cmpxchg => true,
        .call => |c| switch (m.functions.items[c.callee].attrs) {
            .nounwind_readnone, .nounwind_readonly => false,
            else => true,
        },
        else => false,
    };
}

/// Wave and quad operations: declared without readnone (so nothing moves
/// them across control flow), but with no effect besides their result.
/// (Only loop deletion drops them, as dxc's does; dxc's dead code removal
/// keeps them, and with them what they read.)
pub fn isWaveOp(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "dx.op.wave") or std.mem.startsWith(u8, name, "dx.op.quad");
}

/// A phi that is one constant once each input is read on its edge: an input
/// that is the condition of the branch the edge leaves by (or its zext or
/// sext) is known there. (`a && b` with `b` false merges `zext a`, on the
/// edge where `a` is false, with `false`; dxc's optimizer folds it.)
fn edgePhi(m: *module.Module, insts: []const Inst, block_start: []const u32, repl: []const ?Value, n: u32, block: u32, inst: Inst) Allocator.Error!?Value {
    var same: ?i64 = null;
    var known = false;
    for (inst.op.phi.incoming) |in| {
        const x = resolve(repl, in.val);
        var k = constInt(m, x);
        if (k == null) {
            const term = insts[block_start[in.block + 1] - 1].op;
            const br = switch (term) {
                .br => |b| b,
                else => return null,
            };
            const cond = resolve(repl, br.cond orelse return null);
            const other = br.@"else" orelse return null;
            if (br.then == other) return null;
            const truth: i64 = if (block == br.then) 1 else if (block == other) 0 else return null;
            if (std.meta.eql(x, cond)) {
                k = truth;
            } else if (x == .inst and x.inst < n and insts[x.inst].op == .cast) {
                const c = insts[x.inst].op.cast;
                if (!std.meta.eql(resolve(repl, c.val), cond)) return null;
                k = switch (c.op) {
                    .zext => truth,
                    .sext => -truth,
                    else => return null,
                };
            } else return null;
            known = true;
        }
        if (same) |s| {
            if (s != k.?) return null;
        } else same = k;
    }
    if (!known) return null;
    return try m.constant(.{ .ty = inst.ty, .kind = .{ .int = same orelse return null } });
}

/// The integer constants a value can be: itself if constant, or each arm
/// of a select or input of a phi that is (`depth` levels deep).
const Cands = struct {
    vals: [8]i64 = undefined,
    len: usize = 0,

    fn add(c: *Cands, m: *const module.Module, f: *const module.Function, repl: []const ?Value, n: u32, v: Value, depth: u32) bool {
        const x = resolve(repl, v);
        if (constInt(m, x)) |k| {
            for (c.vals[0..c.len]) |e| if (e == k) return true;
            if (c.len == c.vals.len) return false;
            c.vals[c.len] = k;
            c.len += 1;
            return true;
        }
        if (x != .inst or x.inst >= n or depth == 0) return false;
        switch (f.insts.items[x.inst].op) {
            .select => |sl| return c.add(m, f, repl, n, sl.t, depth - 1) and c.add(m, f, repl, n, sl.f, depth - 1),
            .phi => |p| {
                for (p.incoming) |in| {
                    const y = resolve(repl, in.val);
                    if (y == .inst and y.inst == x.inst) continue;
                    if (!c.add(m, f, repl, n, y, depth - 1)) return false;
                }
                return c.len > 0;
            },
            else => return false,
        }
    }
};

/// The bits of the `w`-bit integer `v` known to be zero, from what
/// computes it (`depth` levels deep): constants, masks, shifts by
/// constants, widening, and the bitwise operations and selects of such.
fn knownZero(m: *const module.Module, f: *const module.Function, repl: []const ?Value, n: u32, v: Value, w: u32, depth: u32) u64 {
    const mask: u64 = if (w >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(w)) - 1;
    const x = resolve(repl, v);
    if (constInt(m, x)) |k| return ~@as(u64, @bitCast(k)) & mask;
    if (x != .inst or x.inst >= n or depth == 0) return 0;
    const inst = f.insts.items[x.inst];
    const d = depth - 1;
    return mask & switch (inst.op) {
        .binop => |b| switch (b.op) {
            .@"and" => knownZero(m, f, repl, n, b.lhs, w, d) | knownZero(m, f, repl, n, b.rhs, w, d),
            .@"or", .xor => knownZero(m, f, repl, n, b.lhs, w, d) & knownZero(m, f, repl, n, b.rhs, w, d),
            .shl => blk: {
                const k = constInt(m, resolve(repl, b.rhs)) orelse break :blk 0;
                if (k < 0 or k >= w) break :blk 0;
                const sh: u6 = @intCast(k);
                break :blk (knownZero(m, f, repl, n, b.lhs, w, d) << sh) | ((@as(u64, 1) << sh) - 1);
            },
            .lshr => blk: {
                const k = constInt(m, resolve(repl, b.rhs)) orelse break :blk 0;
                if (k < 0 or k >= w) break :blk 0;
                const sh: u6 = @intCast(k);
                break :blk (knownZero(m, f, repl, n, b.lhs, w, d) >> sh) | ~(mask >> sh);
            },
            else => 0,
        },
        .cast => |c| switch (c.op) {
            .zext => blk: {
                // (A phi promotion made has no instruction to read its
                // type from yet.)
                const src = resolve(repl, c.val);
                if (src == .inst and src.inst >= n) break :blk 0;
                const from = switch (m.types.items[typeOf(m, f, src)]) {
                    .int => |iw| iw,
                    else => break :blk 0,
                };
                const from_mask: u64 = if (from >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(from)) - 1;
                break :blk knownZero(m, f, repl, n, c.val, from, d) | ~from_mask;
            },
            else => 0,
        },
        .select => |sl| knownZero(m, f, repl, n, sl.t, w, d) & knownZero(m, f, repl, n, sl.f, w, d),
        else => 0,
    };
}

/// `x & c` (`w` bits) when known bits decide it, as dxc's instcombine
/// does: 0 if every bit `c` keeps is known zero in `x`; `x` if every bit
/// it clears already is; and through `a | b` where `b` only has bits `c`
/// clears and `a` only bits it keeps, `a`. (Flags packed into one integer
/// with other fields, then tested.)
fn andKnown(m: *module.Module, f: *const module.Function, repl: []const ?Value, n: u32, x: Value, c: u64, w: u32, ty: TypeId) Allocator.Error!?Value {
    const mask: u64 = if (w >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(w)) - 1;
    const kz = knownZero(m, f, repl, n, x, w, 6);
    if (c & ~kz & mask == 0) return try m.constant(.{ .ty = ty, .kind = .{ .int = 0 } });
    if (~c & ~kz & mask == 0) return resolve(repl, x);
    const xr = resolve(repl, x);
    if (xr == .inst and xr.inst < n) {
        const inst = f.insts.items[xr.inst];
        if (inst.op == .binop and inst.op.binop.op == .@"or") {
            const o = inst.op.binop;
            const sides = [2][2]Value{ .{ o.lhs, o.rhs }, .{ o.rhs, o.lhs } };
            for (sides) |ab| {
                const kb = knownZero(m, f, repl, n, ab[1], w, 6);
                const ka = knownZero(m, f, repl, n, ab[0], w, 6);
                if (c & ~kb & mask == 0 and ~c & ~ka & mask == 0) return resolve(repl, ab[0]);
            }
        }
    }
    return null;
}

/// A half, float or double constant of type `ty` with value `x` (rounded
/// to the type).
fn floatConst(m: *module.Module, ty: TypeId, x: f64) Allocator.Error!?Value {
    const b: u64 = switch (m.types.items[ty]) {
        .half => @as(u16, @bitCast(@as(f16, @floatCast(x)))),
        .float => @as(u32, @bitCast(@as(f32, @floatCast(x)))),
        .double => @bitCast(x),
        else => return null,
    };
    return try m.constant(.{ .ty = ty, .kind = .{ .float_bits = b } });
}

/// `x op y` in `T`'s precision.
fn floatOp(comptime T: type, op: module.BinOp, x: f64, y: f64) ?f64 {
    const a: T = @floatCast(x);
    const c: T = @floatCast(y);
    return @floatCast(switch (op) {
        .add => a + c,
        .sub => a - c,
        .mul => a * c,
        .sdiv => a / c,
        .srem => if (c == 0 or std.math.isInf(a) or std.math.isNan(a) or std.math.isNan(c)) std.math.nan(T) else @rem(a, c),
        else => return null,
    });
}

/// Floating-point arithmetic on two constants, and the identities exact
/// in IEEE arithmetic (`x * 1`, `x / 1`, `x - 0`, `x + -0`), as dxc's
/// constant folding and instcombine fold them.
fn foldFloat(m: *module.Module, repl: []const ?Value, inst: Inst) Allocator.Error!?Value {
    const b = inst.op.binop;
    const is_float = switch (m.types.items[inst.ty]) {
        .half, .float, .double => true,
        else => false,
    };
    if (!is_float) return null;
    const l = resolve(repl, b.lhs);
    const r = resolve(repl, b.rhs);
    const lc = constFloat(m, l);
    const rc = constFloat(m, r);
    if (lc != null and rc != null) {
        const x = switch (m.types.items[inst.ty]) {
            .half => floatOp(f16, b.op, lc.?, rc.?),
            .float => floatOp(f32, b.op, lc.?, rc.?),
            else => floatOp(f64, b.op, lc.?, rc.?),
        } orelse return null;
        return floatConst(m, inst.ty, x);
    }
    if (rc) |y| {
        const neg_zero = y == 0 and std.math.signbit(y);
        switch (b.op) {
            .mul, .sdiv => if (y == 1) return l,
            .sub => if (y == 0 and !neg_zero) return l,
            .add => if (neg_zero) return l,
            else => {},
        }
    }
    if (lc) |x| switch (b.op) {
        .mul => if (x == 1) return r,
        .add => if (x == 0 and std.math.signbit(x)) return r,
        else => {},
    };
    return null;
}

/// A dx.op call on constants, folded as dxc folds them (the operations
/// whose result does not depend on the GPU's precision, and the min / max
/// family).
fn foldDxOp(m: *module.Module, repl: []const ?Value, inst: Inst) Allocator.Error!?Value {
    const c = inst.op.call;
    if (!std.mem.startsWith(u8, m.functions.items[c.callee].name, "dx.op.")) return null;
    if (c.args.len < 2) return null;
    const opc = constInt(m, c.args[0]) orelse return null;
    switch (opc) {
        // FAbs, Saturate, Round_ne, Round_ni, Round_pi, Round_z, Sqrt
        6, 7, 24, 26, 27, 28, 29 => {
            if (c.args.len != 2) return null;
            const x = constFloat(m, resolve(repl, c.args[1])) orelse return null;
            if (std.math.isNan(x)) return null;
            const y: f64 = switch (opc) {
                6 => @abs(x),
                7 => @min(@max(x, 0), 1),
                24 => if (x < 0) return null else switch (m.types.items[inst.ty]) {
                    .half => @floatCast(@sqrt(@as(f16, @floatCast(x)))),
                    .float => @floatCast(@sqrt(@as(f32, @floatCast(x)))),
                    else => @sqrt(x),
                },
                // (Halves to even.)
                26 => if (@abs(x - @trunc(x)) == 0.5) 2 * @round(x / 2) else @round(x),
                27 => @floor(x),
                28 => @ceil(x),
                else => @trunc(x),
            };
            return floatConst(m, inst.ty, y);
        },
        // FMax, FMin
        35, 36 => {
            if (c.args.len != 3) return null;
            const x = constFloat(m, resolve(repl, c.args[1])) orelse return null;
            const y = constFloat(m, resolve(repl, c.args[2])) orelse return null;
            if (std.math.isNan(x) or std.math.isNan(y)) return null;
            return floatConst(m, inst.ty, if (opc == 35) @max(x, y) else @min(x, y));
        },
        // IMax, IMin, UMax, UMin
        37, 38, 39, 40 => {
            if (c.args.len != 3) return null;
            const w: u32 = switch (m.types.items[inst.ty]) {
                .int => |iw| iw,
                else => return null,
            };
            const x = constInt(m, resolve(repl, c.args[1])) orelse return null;
            const y = constInt(m, resolve(repl, c.args[2])) orelse return null;
            // (Constants hold their value sign-extended: unsigned order is
            // that of the w-bit patterns.)
            const mask: u64 = if (w >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(w)) - 1;
            const ux = @as(u64, @bitCast(x)) & mask;
            const uy = @as(u64, @bitCast(y)) & mask;
            const pick_x = switch (opc) {
                37 => x >= y,
                38 => x <= y,
                39 => ux >= uy,
                else => ux <= uy,
            };
            return if (pick_x) resolve(repl, c.args[1]) else resolve(repl, c.args[2]);
        },
        else => return null,
    }
}

/// A half, float or double constant's value.
fn constFloat(m: *const module.Module, v: Value) ?f64 {
    if (v != .constant) return null;
    const c = m.constants.items[v.constant];
    const b = switch (c.kind) {
        .float_bits => |b| b,
        else => return null,
    };
    return switch (m.types.items[c.ty]) {
        .half => @floatCast(@as(f16, @bitCast(@as(u16, @truncate(b))))),
        .float => @floatCast(@as(f32, @bitCast(@as(u32, @truncate(b))))),
        .double => @bitCast(b),
        else => null,
    };
}

/// `v` with replaced loads and phis followed to their final value.
fn resolve(repl: []const ?Value, v: Value) Value {
    var x = v;
    while (x == .inst) {
        const r = repl[x.inst] orelse break;
        x = r;
    }
    return x;
}

/// Element `k` of `getelementptr [len x T], %a, 0, k`, or null.
fn constIndex(m: *const module.Module, indices: []const Value, len: u64) ?u32 {
    if (indices.len != 2) return null;
    const first = constInt(m, indices[0]) orelse return null;
    const k = constInt(m, indices[1]) orelse return null;
    if (first != 0 or k < 0 or k >= len) return null;
    return @intCast(k);
}

fn constInt(m: *const module.Module, v: Value) ?i64 {
    if (v != .constant) return null;
    return switch (m.constants.items[v.constant].kind) {
        .int => |x| x,
        else => null,
    };
}

fn typeOf(m: *const module.Module, f: *const module.Function, v: Value) TypeId {
    return switch (v) {
        .inst => |i| f.insts.items[i].ty,
        .constant => |c| m.constants.items[c].ty,
        .arg => |k| m.types.items[f.ty].function.params[k],
        .global => |g| m.globals.items[g].ptr_ty,
        .function => none,
    };
}

/// Drops the function declarations nothing calls or refers to any more
/// (dead code removal can take a dx.op's last call, and the validator
/// rejects unused external functions), renumbering the other functions.
/// Run last: indices the emitter holds go stale. Returns the new index of
/// each old function (`none` for dropped ones), or null if none went.
/// Drops groupshared variables nothing refers to any more (dead code
/// removal can take their last use, and the validator rejects unused
/// internal declarations), renumbering the other globals.
pub fn pruneGlobals(a: Allocator, m: *module.Module) Allocator.Error!void {
    const globals = m.globals.items;
    const used = try a.alloc(bool, globals.len);
    for (globals, used) |g, *u| u.* = g.addr_space != 3;
    const Use = struct {
        used: []bool,
        fn visit(s: *@This(), v: Value, _: Role) Value {
            if (v == .global) s.used[v.global] = true;
            return v;
        }
    };
    var use: Use = .{ .used = used };
    for (m.functions.items) |f| for (f.insts.items) |*inst| try operands(false, a, inst, &use);
    for (m.metadata.items) |md| if (md == .value and md.value.val == .global) {
        used[md.value.val.global] = true;
    };
    if (std.mem.indexOfScalar(bool, used, false) == null) return;
    const index = try a.alloc(u32, globals.len);
    var count: u32 = 0;
    for (used, index) |u, *x| {
        x.* = if (u) count else none;
        if (u) count += 1;
    }
    const Map = struct {
        index: []const u32,
        fn visit(s: *@This(), v: Value, _: Role) Value {
            return if (v == .global) .{ .global = s.index[v.global] } else v;
        }
    };
    var map: Map = .{ .index = index };
    const ma = m.allocator();
    for (m.functions.items) |*f| for (f.insts.items) |*inst| try operands(true, ma, inst, &map);
    for (m.metadata.items) |*md| if (md.* == .value and md.value.val == .global) {
        md.value.val = .{ .global = index[md.value.val.global] };
    };
    var k: usize = 0;
    for (globals, used) |g, u| if (u) {
        globals[k] = g;
        k += 1;
    };
    m.globals.shrinkRetainingCapacity(k);
}

pub fn pruneDeclarations(a: Allocator, m: *module.Module) Allocator.Error!?[]const u32 {
    const funcs = m.functions.items;
    const used = try a.alloc(bool, funcs.len);
    for (funcs, used) |f, *u| u.* = f.num_blocks > 0;
    const Use = struct {
        used: []bool,
        fn visit(s: *@This(), v: Value, _: Role) Value {
            if (v == .function) s.used[v.function] = true;
            return v;
        }
    };
    var use: Use = .{ .used = used };
    for (funcs) |f| for (f.insts.items) |*inst| {
        if (inst.op == .call) used[inst.op.call.callee] = true;
        try operands(false, a, inst, &use);
    };
    for (m.metadata.items) |md| if (md == .value and md.value.val == .function) {
        used[md.value.val.function] = true;
    };
    if (std.mem.indexOfScalar(bool, used, false) == null) return null;

    const index = try a.alloc(u32, funcs.len);
    var count: u32 = 0;
    for (used, index) |u, *x| {
        x.* = if (u) count else none;
        if (u) count += 1;
    }
    const Map = struct {
        index: []const u32,
        fn visit(s: *@This(), v: Value, _: Role) Value {
            return if (v == .function) .{ .function = s.index[v.function] } else v;
        }
    };
    var map: Map = .{ .index = index };
    const ma = m.allocator();
    for (funcs) |*f| for (f.insts.items) |*inst| {
        try operands(true, ma, inst, &map);
        if (inst.op == .call) inst.op.call.callee = index[inst.op.call.callee];
    };
    for (m.metadata.items) |*md| if (md.* == .value and md.value.val == .function) {
        md.value.val = .{ .function = index[md.value.val.function] };
    };
    var k: usize = 0;
    for (funcs, used) |f, u| if (u) {
        funcs[k] = f;
        k += 1;
    };
    m.functions.shrinkRetainingCapacity(k);
    return index;
}
