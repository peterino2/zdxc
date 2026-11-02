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

const Value = module.Value;
const Inst = module.Inst;
const TypeId = module.TypeId;

const none = std.math.maxInt(u32);

const Role = enum { load_ptr, store_ptr, gep_base, other };

const Edge = @typeInfo(@FieldType(@FieldType(@FieldType(Inst, "op"), "phi"), "incoming")).pointer.child;

/// Visits each operand of `inst` (with the way it is used) through
/// `ctx.visit(value, role) Value`. With `write`, the results replace the
/// operands, in newly allocated slices where the operands are slices.
fn operands(comptime write: bool, a: Allocator, inst: *Inst, ctx: anytype) Allocator.Error!void {
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
    const f = &m.functions.items[func];
    const insts = f.insts.items;
    const n: u32 = @intCast(insts.len);
    const nb = f.num_blocks;
    if (n == 0 or nb == 0) return;

    // Blocks: instruction ranges, successors and predecessors (one entry
    // per edge, so a switch's repeated target counts once per case).
    const block_start = try a.alloc(u32, nb + 1);
    const block_of = try a.alloc(u32, n);
    {
        var b: u32 = 0;
        block_start[0] = 0;
        for (insts, 0..) |inst, i| {
            if (b >= nb) return; // not the block layout this pass expects
            block_of[i] = b;
            if (isTerminator(inst)) {
                b += 1;
                block_start[b] = @intCast(i + 1);
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
    for (insts, 0..) |inst, i| switch (inst.op) {
        .alloca => |x| switch (m.types.items[x.elem]) {
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
        },
        else => {},
    };
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
    for (insts, 0..) |inst, i| switch (inst.op) {
        .gep => |g| if (g.ptr == .inst and var_base[g.ptr.inst] != none and insts[g.ptr.inst].op == .alloca) {
            const al = g.ptr.inst;
            if (direct[al]) {
                var_base[al] = none;
                continue;
            }
            const k = constIndex(m, g.indices, m.types.items[insts[al].op.alloca.elem].array.len);
            if (k) |kk| {
                gep_alloca[i] = al;
                gep_k[i] = kk;
            } else if (dyn.contains(@intCast(i)) and g.indices.len == 2 and constInt(m, g.indices[0]) == 0) {
                gep_alloca[i] = al;
                gep_k[i] = none;
            } else var_base[al] = none;
        },
        else => {},
    };
    {
        var scan: Scan = .{ .insts = insts, .var_base = var_base, .direct = direct, .gep_alloca = gep_alloca };
        for (insts) |*inst| try operands(false, a, inst, &scan);
    }
    // Loads and stores must move whole elements of the element type.
    for (insts) |inst| {
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
    for (insts, 0..) |inst, i| {
        if (inst.op != .alloca or var_base[i] == none) continue;
        var_base[i] = nv;
        nv += if (direct[i]) 1 else @intCast(m.types.items[inst.op.alloca.elem].array.len);
    }
    if (nv == 0) return;
    const var_ty = try a.alloc(TypeId, nv);
    for (insts, 0..) |inst, i| {
        if (inst.op != .alloca or var_base[i] == none) continue;
        const len: u32 = if (direct[i]) 1 else @intCast(m.types.items[inst.op.alloca.elem].array.len);
        @memset(var_ty[var_base[i]..][0..len], elem_ty[i]);
    }
    // Components a dynamic index can reach stay in memory, and so does
    // their alloca.
    const pinned = try a.alloc(bool, nv);
    @memset(pinned, false);
    const keep = try a.alloc(bool, n);
    @memset(keep, false);
    for (insts, 0..) |inst, i| {
        if (inst.op != .gep or gep_alloca[i] == none or gep_k[i] != none) continue;
        const al = gep_alloca[i];
        if (var_base[al] == none) continue;
        const len: u32 = @intCast(m.types.items[insts[al].op.alloca.elem].array.len);
        const r = dyn.get(@intCast(i)).?;
        const lo = @min(r[0], len);
        const hi = @min(r[1], len);
        @memset(pinned[var_base[al] + lo .. var_base[al] + hi], true);
        keep[al] = true;
    }
    // The variable an instruction loads or stores, or `none`.
    const access = try a.alloc(u32, n);
    @memset(access, none);
    for (insts, 0..) |inst, i| {
        const ptr = switch (inst.op) {
            .load => |x| x.ptr,
            .store => |x| x.ptr,
            else => continue,
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
    for (insts, 0..) |inst, i| {
        const v = access[i];
        if (v == none) continue;
        if (first_block[v] == none) {
            first_block[v] = block_of[i];
            if (inst.op == .load) global[v] = true;
        } else if (first_block[v] != block_of[i]) global[v] = true;
    }
    const Def = struct { v: u32, b: u32 };
    var defs: std.ArrayList(Def) = .empty;
    for (insts, 0..) |inst, i| {
        const v = access[i];
        if (v == none or inst.op != .store or !global[v] or rpo_index[block_of[i]] == none) continue;
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
    for (insts, 0..) |inst, i| {
        if (access[i] != none and inst.op == .load and repl[i] == null)
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

    // The instructions that go: promoted allocas, their getelementptrs,
    // loads and stores.
    const removed = try a.alloc(bool, n);
    for (insts, 0..) |inst, i| removed[i] = switch (inst.op) {
        .alloca => var_base[i] != none and !keep[i],
        .gep => gep_alloca[i] != none and var_base[gep_alloca[i]] != none and gep_k[i] != none and !pinned[var_base[gep_alloca[i]] + gep_k[i]],
        .load, .store => access[i] != none,
        else => false,
    };

    // What stays: instructions with effects, and what they read,
    // transitively; new phis likewise. (The loads promotion leaves dead,
    // such as copies of arguments never read, go too.)
    const live = try a.alloc(bool, n + np);
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
        for (insts, 0..) |inst, i| if (!removed[i] and hasEffects(m, inst)) {
            live[i] = true;
            try work.append(a, @intCast(i));
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

    // New indices: in each block the existing phis, then the new ones,
    // then the rest.
    const index = try a.alloc(u32, n + np);
    @memset(index, none);
    var count: u32 = 0;
    for (0..nb) |b| {
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
        var i = block_start[b];
        while (i < block_start[b + 1] and insts[i].op == .phi) : (i += 1) if (live[i]) {
            var inst = insts[i];
            try operands(true, ma, &inst, &map);
            out.appendAssumeCapacity(inst);
        };
        for (bphis[bphi_off[b]..bphi_off[b + 1]]) |j| if (live[n + j]) {
            const edges = try ma.alloc(Edge, incoming[j].len);
            for (incoming[j], edges) |in, *e| e.* = .{ .val = map.visit(in.val, .other), .block = in.block };
            out.appendAssumeCapacity(.{ .ty = var_ty[phi_var.items[j]], .op = .{ .phi = .{ .incoming = edges } } });
        };
        while (i < block_start[b + 1]) : (i += 1) if (live[i]) {
            var inst = insts[i];
            try operands(true, ma, &inst, &map);
            out.appendAssumeCapacity(inst);
        };
    }
    f.insts = out;
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
