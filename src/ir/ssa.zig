//! Promotion of locals to SSA values for SPIR-V (dxc's SPIR-V gets it from
//! its optimizer's ssa-rewrite and local-access-chain-convert): drivers get
//! values instead of Function variables, and inlined code its parameters
//! and temporaries as values.
//!
//! 1. A local struct or array accessed only with constant indices (and
//!    whole) is split into one local per leaf member / element (scalar
//!    replacement): whole reads construct the value, whole writes store
//!    each part. Promoting whole aggregates instead would turn each member
//!    write into a copy of the aggregate, which drivers do not undo.
//! 2. Locals then only loaded and stored whole (not resources) are
//!    promoted: phis where values of a variable live across blocks meet
//!    (semi-pruned SSA over dominance frontiers), loads replaced by the
//!    value reaching them, stores and the locals removed. A read before any
//!    write is `undef`.
//!
//! Phis get one incoming value per predecessor the emitter writes out,
//! unreachable merge and continue targets included (`undef` from those).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("ir.zig");
const types = @import("../sema/types.zig");
const opt = @import("opt.zig");

const Ref = ir.Ref;
const BlockId = ir.BlockId;
const TypeId = types.TypeId;
const TypeTable = types.TypeTable;

pub const Error = Allocator.Error;

pub fn run(m: *ir.Module) Error!void {
    // (The same modules as inlining, for now.)
    if (!@import("inline.zig").eligible(m)) return;
    try privateToLocal(m);
    for (m.functions.items) |f| {
        if (f.dead) continue;
        try splitLocals(m, f);
        try dynamicComponents(m, f);
        try promote(m, f);
        // Values that were behind locals may fold now, and branches on
        // them (constant arguments of inlined calls).
        try opt.fold(m.arena, m.types, f);
        if (try opt.foldBranches(m.arena, f)) try opt.fold(m.arena, m.types, f);
        // The straight-line chains inlining (and folding) left.
        try opt.mergeBlocks(m.arena, f);
    }
}

/// With one function left (everything inlined into it), its `static`
/// globals of plain types are its locals, which the passes below promote
/// (SPIRV-Tools' private-to-local; dxc's SPIR-V has none left). Unreal's
/// ray tracing shaders read hundreds of such statics, copies of their
/// shader record and view uniforms, and spirv-opt -O, which Unreal runs
/// on them, overflowed its stack rewriting them as locals over 8,000
/// blocks. (Private variables have no initializer, so neither do the
/// locals.)
fn privateToLocal(m: *ir.Module) Error!void {
    var only: ?*ir.Function = null;
    for (m.functions.items) |f| {
        if (f.dead) continue;
        if (only != null) return;
        only = f;
    }
    const f = only orelse return;
    const a = m.arena;
    const canon = try a.alloc(Ref, m.globals.items.len);
    @memset(canon, .none);
    var any_dup = false;
    for (f.insts.items, 0..) |*inst, i| {
        if (inst.op != .global) continue;
        const gi = inst.op.global;
        const g = m.globals.items[gi];
        if (g.space != .private or g.ext.builtin != null or g.ext.storage_class != null or !plainType(m.types, g.ty)) continue;
        if (canon[gi] == .none) {
            canon[gi] = @enumFromInt(i);
            inst.* = .{ .op = .local_var, .ty = inst.ty, .ptr = .function };
        } else any_dup = true;
    }
    defer retagPointers(f);
    if (!any_dup) return;
    // Other references to the same global use the first one's local.
    const dup = try a.alloc(Ref, f.insts.items.len);
    @memset(dup, .none);
    for (f.insts.items, 0..) |inst, i| {
        if (inst.op == .global and canon[inst.op.global] != .none) dup[i] = canon[inst.op.global];
    }
    const Map = struct {
        dup: []const Ref,
        pub fn map(c: @This(), x: Ref) Ref {
            if (x == .none or x.index() >= c.dup.len) return x;
            return if (c.dup[x.index()] != .none) c.dup[x.index()] else x;
        }
    };
    const mp = Map{ .dup = dup };
    for (f.insts.items) |*inst| inst.op = try opt.mapOp(a, inst.op, mp);
    for (f.blocks.items) |*blk| blk.term = switch (blk.term) {
        .ret => |v| .{ .ret = mp.map(v) },
        .cond_br => |c| .{ .cond_br = .{ .cond = mp.map(c.cond), .then = c.then, .@"else" = c.@"else" } },
        .@"switch" => |sw| .{ .@"switch" = .{ .value = mp.map(sw.value), .default = sw.default, .cases = sw.cases } },
        else => blk.term,
    };
}

/// Pointers into the locals privateToLocal made (access chains, through
/// any depth) point at Function storage now.
fn retagPointers(f: *ir.Function) void {
    var changed = true;
    while (changed) {
        changed = false;
        for (f.insts.items) |*inst| {
            if (inst.op != .access or inst.ptr != .private) continue;
            const base = f.insts.items[inst.op.access.base.index()];
            if (base.ptr == .function) {
                inst.ptr = .function;
                changed = true;
            }
        }
    }
}

/// `v[i]` with `i` not constant, on a vector local only loaded or stored
/// through: the load is a select over the components, the store builds
/// the vector with the component at `i` replaced, so the local can be
/// promoted (dxc's SPIR-V has OpVectorExtractDynamic and
/// OpVectorInsertDynamic there). Unreal's large-world-coordinate helpers
/// (DFGetComponent) index float3 members this way.
fn dynamicComponents(m: *ir.Module, f: *ir.Function) Error!void {
    const a = m.arena;
    const t = m.types;
    const n = f.insts.items.len;
    // The accesses to rewrite, and whether every use of each qualifies.
    const target = try a.alloc(bool, n);
    @memset(target, false);
    var any = false;
    for (f.blocks.items) |blk| for (blk.insts.items) |r| {
        const inst = f.inst(r);
        if (inst.op != .access or inst.op.access.indices.len != 1) continue;
        const base = f.inst(inst.op.access.base);
        if (base.op != .local_var or base.ptr != .function or t.get(base.ty) != .vector) continue;
        if (constIndex(f, inst.op.access.indices[0]) != null) continue;
        target[r.index()] = true;
        any = true;
    };
    if (!any) return;
    const Check = struct {
        f: *const ir.Function,
        target: []bool,
        user: Ref,
        pub fn use(c: @This(), x: Ref) void {
            if (!c.target[x.index()]) return;
            const fine = switch (c.f.inst(c.user).op) {
                .load => true,
                .store => |st| st.ptr == x and st.value != x,
                else => false,
            };
            if (!fine) c.target[x.index()] = false;
        }
    };
    for (f.blocks.items) |blk| {
        for (blk.insts.items) |r| try forOperands(a, f.inst(r).op, Check{ .f = f, .target = target, .user = r });
        const tr = termOperand(blk.term);
        if (tr != .none) target[tr.index()] = false;
    }
    const bool_ty = try t.scalar(.bool);
    for (f.blocks.items) |*blk| {
        var out: std.ArrayList(Ref) = .empty;
        for (blk.insts.items) |r| {
            const inst = f.inst(r);
            switch (inst.op) {
                .access => if (target[r.index()]) continue,
                .load => |p| if (target[p.index()]) {
                    const acc = f.inst(p).op.access;
                    const vec_ty = f.inst(acc.base).ty;
                    const len = t.get(vec_ty).vector.len;
                    const w = try addInst(a, f, .{ .op = .{ .load = acc.base }, .ty = vec_ty });
                    try out.append(a, w);
                    var v = try addInst(a, f, .{ .op = .{ .extract = .{ .agg = w, .index = len - 1 } }, .ty = inst.ty });
                    try out.append(a, v);
                    var k: u32 = len - 1;
                    while (k > 0) {
                        k -= 1;
                        const e = try addInst(a, f, .{ .op = .{ .extract = .{ .agg = w, .index = k } }, .ty = inst.ty });
                        const c = try indexIs(a, f, acc.indices[0], k, bool_ty, &out);
                        try out.append(a, e);
                        v = try addInst(a, f, .{ .op = .{ .select = .{ .cond = c, .t = e, .f = v } }, .ty = inst.ty });
                        try out.append(a, v);
                    }
                    // The load becomes the selected value.
                    f.insts.items[r.index()].op = f.inst(v).op;
                    out.items[out.items.len - 1] = r;
                    continue;
                },
                .store => |st| if (target[st.ptr.index()]) {
                    const acc = f.inst(st.ptr).op.access;
                    const vec_ty = f.inst(acc.base).ty;
                    const vt = t.get(vec_ty).vector;
                    const comp_ty = try t.scalar(vt.elem);
                    const w = try addInst(a, f, .{ .op = .{ .load = acc.base }, .ty = vec_ty });
                    try out.append(a, w);
                    const comps = try a.alloc(Ref, vt.len);
                    for (comps, 0..) |*cp, k| {
                        const e = try addInst(a, f, .{ .op = .{ .extract = .{ .agg = w, .index = @intCast(k) } }, .ty = comp_ty });
                        const c = try indexIs(a, f, acc.indices[0], @intCast(k), bool_ty, &out);
                        try out.append(a, e);
                        cp.* = try addInst(a, f, .{ .op = .{ .select = .{ .cond = c, .t = st.value, .f = e } }, .ty = comp_ty });
                        try out.append(a, cp.*);
                    }
                    const nv = try addInst(a, f, .{ .op = .{ .construct = comps }, .ty = vec_ty });
                    try out.append(a, nv);
                    f.insts.items[r.index()].op = .{ .store = .{ .ptr = acc.base, .value = nv } };
                },
                else => {},
            }
            try out.append(a, r);
        }
        blk.insts = out;
    }
}

/// `index == k` (as `index`'s type), appended to `out`.
fn indexIs(a: Allocator, f: *ir.Function, index: Ref, k: u32, bool_ty: TypeId, out: *std.ArrayList(Ref)) Error!Ref {
    const kc = try addInst(a, f, .{ .op = .{ .constant = .{ .int = k } }, .ty = f.inst(index).ty });
    const c = try addInst(a, f, .{ .op = .{ .cmp = .{ .op = .eq, .lhs = index, .rhs = kc } }, .ty = bool_ty });
    try out.appendSlice(a, &.{ kc, c });
    return c;
}

// ----------------------------------------------------------------------
// Uses

fn addInst(a: Allocator, f: *ir.Function, inst: ir.Inst) Error!Ref {
    try f.insts.append(a, inst);
    return @fromBackingInt(@intCast(f.insts.items.len - 1));
}

/// Calls `ctx.use(r)` for every operand of `op` (not `.none`).
fn forOperands(a: Allocator, op: ir.Op, ctx: anytype) Error!void {
    _ = a;
    const Skip = struct {
        inner: @TypeOf(ctx),
        pub fn use(c: @This(), r: Ref) void {
            if (r != .none) c.inner.use(r);
        }
    };
    opt.eachOperand(op, Skip{ .inner = ctx });
}

fn termOperand(term: ir.Terminator) Ref {
    return switch (term) {
        .ret => |r| r,
        .cond_br => |c| c.cond,
        .@"switch" => |s| s.value,
        else => .none,
    };
}

fn successors(a: Allocator, term: ir.Terminator) Error![]const BlockId {
    return switch (term) {
        .br => |b| try a.dupe(BlockId, &.{b}),
        .cond_br => |c| if (c.then == c.@"else") try a.dupe(BlockId, &.{c.then}) else try a.dupe(BlockId, &.{ c.then, c.@"else" }),
        .@"switch" => |sw| blk: {
            var out: std.ArrayList(BlockId) = .empty;
            try out.append(a, sw.default);
            for (sw.cases) |c| {
                if (std.mem.indexOfScalar(BlockId, out.items, c.block) == null) try out.append(a, c.block);
            }
            break :blk out.items;
        },
        else => &.{},
    };
}

/// A local's type is promotable: no resources, ray queries or other opaque
/// values anywhere in it.
fn plainType(t: *TypeTable, ty: TypeId) bool {
    return switch (t.get(ty)) {
        .scalar, .vector, .matrix, .@"enum" => true,
        .array => |x| x.len > 0 and plainType(t, x.elem),
        .@"struct" => |st| {
            for (st.fields.items) |fld| if (!plainType(t, fld.type)) return false;
            for (st.bases.items) |_| return false;
            return true;
        },
        else => false,
    };
}

// ----------------------------------------------------------------------
// 1. Scalar replacement

/// Where each instruction is: block and position (for instructions in a
/// block).
const Place = struct { block: u32, pos: u32 };

fn constIndex(f: *const ir.Function, r: Ref) ?u32 {
    const i = f.inst(r);
    if (i.op != .constant or i.op.constant != .int) return null;
    const v = i.op.constant.int;
    if (v < 0 or v > std.math.maxInt(u32)) return null;
    return @intCast(v);
}

/// The type one constant index into `ty` selects (structs and arrays).
fn stepType(t: *TypeTable, ty: TypeId, k: u32) ?TypeId {
    return switch (t.get(ty)) {
        .@"struct" => |st| if (k < st.fields.items.len) st.fields.items[k].type else null,
        .array => |x| if (k < x.len) x.elem else null,
        else => null,
    };
}

fn splitLocals(m: *ir.Module, f: *ir.Function) Error!void {
    const a = m.arena;
    const t = m.types;
    const n = f.insts.items.len;
    // Uses of every instruction (in blocks), and whether each is in one.
    const in_block = try a.alloc(bool, n);
    @memset(in_block, false);
    for (f.blocks.items) |blk| for (blk.insts.items) |r| {
        in_block[r.index()] = true;
    };
    // root[x]: the local an access chain `x` is rooted at (none if not one
    // of a convertible chain); path from the root.
    const root = try a.alloc(Ref, n);
    @memset(root, .none);
    const paths = try a.alloc([]const u32, n);
    // tail[x]: indices of chain `x` past its leaf (into a vector or
    // matrix member, constant or not): `x` becomes an access into that
    // member's local.
    const tail = try a.alloc([]const Ref, n);
    @memset(tail, &.{});
    // Candidate locals: struct / array locals of plain types.
    const cand = try a.alloc(bool, n);
    @memset(cand, false);
    var any = false;
    for (f.insts.items, 0..) |inst, i| {
        // (Locals are function-wide: some live in no block.)
        if (inst.op != .local_var or inst.ptr != .function) continue;
        const k = t.get(inst.ty);
        if ((k == .@"struct" or k == .array) and plainType(t, inst.ty)) {
            cand[i] = true;
            root[i] = @fromBackingInt(@intCast(i));
            paths[i] = &.{};
            any = true;
        }
    }
    if (!any) return;
    // Chains in instruction order: an access's base precedes it in f.insts
    // when lowering made it; iterate to a fixed point to be safe.
    var changed = true;
    while (changed) {
        changed = false;
        for (f.insts.items, 0..) |inst, i| {
            if (!in_block[i] or root[i] != .none) continue;
            const acc = switch (inst.op) {
                .access => |x| x,
                else => continue,
            };
            const rb = root[acc.base.index()];
            if (rb == .none or !cand[rb.index()]) continue;
            var ty = f.inst(acc.base).ty;
            var path: std.ArrayList(u32) = .empty;
            try path.appendSlice(a, paths[acc.base.index()]);
            var j: usize = 0;
            // (A chain past a leaf goes no further.)
            var ok = tail[acc.base.index()].len == 0;
            while (ok and j < acc.indices.len) : (j += 1) {
                if (!isAggregate(t, ty)) break;
                const k = constIndex(f, acc.indices[j]) orelse {
                    ok = false;
                    break;
                };
                ty = stepType(t, ty, k) orelse {
                    ok = false;
                    break;
                };
                try path.append(a, k);
            }
            if (!ok) {
                cand[rb.index()] = false;
                continue;
            }
            tail[i] = acc.indices[j..];
            root[i] = rb;
            paths[i] = path.items;
            changed = true;
        }
    }
    // Every use of a chain (or of the local) must be a load, a store to it
    // or a further chain; anything else disqualifies the local.
    const Check = struct {
        f: *const ir.Function,
        root: []const Ref,
        cand: []bool,
        user: Ref,
        pub fn use(c: @This(), x: Ref) void {
            const rt = c.root[x.index()];
            if (rt == .none) return;
            const u = c.f.inst(c.user).op;
            const fine = switch (u) {
                .load => true,
                .store => |s| s.ptr == x and s.value != x,
                .access => |acc| acc.base == x and c.root[c.user.index()] == rt,
                else => false,
            };
            if (!fine) c.cand[rt.index()] = false;
        }
    };
    for (f.blocks.items) |blk| {
        for (blk.insts.items) |r| try forOperands(a, f.inst(r).op, Check{ .f = f, .root = root, .cand = cand, .user = r });
        const tr = termOperand(blk.term);
        if (tr != .none and root[tr.index()] != .none) cand[root[tr.index()].index()] = false;
    }
    // Split each remaining candidate into one local per leaf (scalar,
    // vector or matrix member / element), in depth-first order; aggregates
    // with too many leaves stay whole.
    const leaf_base = try a.alloc(u32, n); // first leaf local of a candidate
    var leaves: std.ArrayList(Ref) = .empty;
    for (0..n) |i| {
        if (!cand[i]) continue;
        const count = leafCount(t, f.inst(@fromBackingInt(@intCast(i))).ty);
        if (count > max_leaves) {
            cand[i] = false;
            continue;
        }
        leaf_base[i] = @intCast(leaves.items.len);
        try addLeaves(a, f, t, f.inst(@fromBackingInt(@intCast(i))).ty, &leaves);
    }
    defer for (0..n) |i| if (cand[i]) {
        // Split: the aggregate local is gone (the emitter declares every
        // local_var).
        f.insts.items[i] = .{ .op = .undef, .ty = f.insts.items[i].ty };
    };
    // Rewrite loads and stores through the candidates and their chains.
    for (f.blocks.items) |*blk| {
        var out: std.ArrayList(Ref) = .empty;
        for (blk.insts.items) |r| {
            const inst = f.inst(r);
            switch (inst.op) {
                .access => if (root[r.index()] != .none and cand[root[r.index()].index()]) {
                    const rt = root[r.index()];
                    if (tail[r.index()].len == 0) continue;
                    // Into a vector or matrix member: an access into its
                    // local.
                    const at = leafAt(t, f.inst(rt).ty, paths[r.index()]);
                    f.insts.items[r.index()].op = .{ .access = .{ .base = leaves.items[leaf_base[rt.index()] + at.offset], .indices = tail[r.index()] } };
                },
                .local_var => if (cand[r.index()]) continue,
                .load => |p| {
                    const rt = root[p.index()];
                    if (rt != .none and cand[rt.index()] and tail[p.index()].len == 0) {
                        const at = leafAt(t, f.inst(rt).ty, paths[p.index()]);
                        const base = leaves.items[leaf_base[rt.index()] + at.offset ..];
                        const v = try gather(a, f, t, at.ty, base, &out);
                        // The load becomes the gathered value.
                        f.insts.items[r.index()].op = f.inst(v).op;
                        if (out.items.len > 0 and out.items[out.items.len - 1] == v) out.items[out.items.len - 1] = r else try out.append(a, r);
                        continue;
                    }
                },
                .store => |st| {
                    const rt = root[st.ptr.index()];
                    if (rt != .none and cand[rt.index()] and tail[st.ptr.index()].len == 0) {
                        const at = leafAt(t, f.inst(rt).ty, paths[st.ptr.index()]);
                        const base = leaves.items[leaf_base[rt.index()] + at.offset ..];
                        try scatter(a, f, t, at.ty, base, st.value, &out);
                        continue;
                    }
                },
                else => {},
            }
            try out.append(a, r);
        }
        blk.insts = out;
    }
}

/// Aggregates split into at most this many locals.
const max_leaves = 1024;

fn isAggregate(t: *TypeTable, ty: TypeId) bool {
    return switch (t.get(ty)) {
        .@"struct", .array => true,
        else => false,
    };
}

fn leafCount(t: *TypeTable, ty: TypeId) u32 {
    return switch (t.get(ty)) {
        .@"struct" => |st| blk: {
            var c: u32 = 0;
            for (st.fields.items) |fld| c +|= leafCount(t, fld.type);
            break :blk c;
        },
        .array => |x| x.len *| leafCount(t, x.elem),
        else => 1,
    };
}

fn addLeaves(a: Allocator, f: *ir.Function, t: *TypeTable, ty: TypeId, out: *std.ArrayList(Ref)) Error!void {
    switch (t.get(ty)) {
        .@"struct" => |st| for (st.fields.items) |fld| try addLeaves(a, f, t, fld.type, out),
        .array => |x| for (0..x.len) |_| try addLeaves(a, f, t, x.elem, out),
        else => try out.append(a, try addInst(a, f, .{ .op = .local_var, .ty = ty, .ptr = .function })),
    }
}

/// The member a path selects: its type and first leaf (depth-first).
fn leafAt(t: *TypeTable, ty0: TypeId, path: []const u32) struct { ty: TypeId, offset: u32 } {
    var ty = ty0;
    var off: u32 = 0;
    for (path) |k| switch (t.get(ty)) {
        .@"struct" => |st| {
            for (st.fields.items[0..k]) |fld| off += leafCount(t, fld.type);
            ty = st.fields.items[k].type;
        },
        .array => |x| {
            off += k * leafCount(t, x.elem);
            ty = x.elem;
        },
        else => unreachable,
    };
    return .{ .ty = ty, .offset = off };
}

/// The value of type `ty` held in the leaf locals from `leaves[0]`: a load
/// of a leaf, or a construct of its members' values.
fn gather(a: Allocator, f: *ir.Function, t: *TypeTable, ty: TypeId, leaves: []const Ref, out: *std.ArrayList(Ref)) Error!Ref {
    if (!isAggregate(t, ty)) {
        const v = try addInst(a, f, .{ .op = .{ .load = leaves[0] }, .ty = ty });
        try out.append(a, v);
        return v;
    }
    var parts: std.ArrayList(Ref) = .empty;
    var off: u32 = 0;
    switch (t.get(ty)) {
        .@"struct" => |st| for (st.fields.items) |fld| {
            try parts.append(a, try gather(a, f, t, fld.type, leaves[off..], out));
            off += leafCount(t, fld.type);
        },
        .array => |x| for (0..x.len) |_| {
            try parts.append(a, try gather(a, f, t, x.elem, leaves[off..], out));
            off += leafCount(t, x.elem);
        },
        else => unreachable,
    }
    const v = try addInst(a, f, .{ .op = .{ .construct = parts.items }, .ty = ty });
    try out.append(a, v);
    return v;
}

/// Stores value `v` of type `ty` into the leaf locals from `leaves[0]`.
fn scatter(a: Allocator, f: *ir.Function, t: *TypeTable, ty: TypeId, leaves: []const Ref, v: Ref, out: *std.ArrayList(Ref)) Error!void {
    if (!isAggregate(t, ty)) {
        try out.append(a, try addInst(a, f, .{ .op = .{ .store = .{ .ptr = leaves[0], .value = v } }, .ty = TypeTable.void_type }));
        return;
    }
    var off: u32 = 0;
    switch (t.get(ty)) {
        .@"struct" => |st| for (st.fields.items, 0..) |fld, k| {
            const x = try addInst(a, f, .{ .op = .{ .extract = .{ .agg = v, .index = @intCast(k) } }, .ty = fld.type });
            try out.append(a, x);
            try scatter(a, f, t, fld.type, leaves[off..], x, out);
            off += leafCount(t, fld.type);
        },
        .array => |arr| for (0..arr.len) |k| {
            const x = try addInst(a, f, .{ .op = .{ .extract = .{ .agg = v, .index = @intCast(k) } }, .ty = arr.elem });
            try out.append(a, x);
            try scatter(a, f, t, arr.elem, leaves[off..], x, out);
            off += leafCount(t, arr.elem);
        },
        else => unreachable,
    }
}

// ----------------------------------------------------------------------
// 2. Promotion

fn promote(m: *ir.Module, f: *ir.Function) Error!void {
    const a = m.arena;
    const t = m.types;
    const nb = f.blocks.items.len;
    const ni = f.insts.items.len;

    // Promotable locals: plain types, every use a whole load or a store to
    // them.
    const var_of = try a.alloc(u32, ni); // inst -> var index (maxInt: none)
    const none = std.math.maxInt(u32);
    @memset(var_of, none);
    var vars: std.ArrayList(Ref) = .empty;
    const in_block = try a.alloc(bool, ni);
    @memset(in_block, false);
    for (f.blocks.items) |blk| for (blk.insts.items) |r| {
        in_block[r.index()] = true;
    };
    for (f.insts.items, 0..) |inst, i| {
        if (inst.op != .local_var or inst.ptr != .function or !plainType(t, inst.ty)) continue;
        var_of[i] = @intCast(vars.items.len);
        try vars.append(a, @fromBackingInt(@intCast(i)));
    }
    if (vars.items.len == 0) return;
    const ok = try a.alloc(bool, vars.items.len);
    @memset(ok, true);
    const Check = struct {
        f: *const ir.Function,
        var_of: []const u32,
        ok: []bool,
        user: Ref,
        pub fn use(c: @This(), x: Ref) void {
            const v = c.var_of[x.index()];
            if (v == std.math.maxInt(u32)) return;
            const fine = switch (c.f.inst(c.user).op) {
                .load => true,
                .store => |s| s.ptr == x and s.value != x,
                else => false,
            };
            if (!fine) c.ok[v] = false;
        }
    };
    for (f.blocks.items) |blk| {
        for (blk.insts.items) |r| try forOperands(a, f.inst(r).op, Check{ .f = f, .var_of = var_of, .ok = ok, .user = r });
        const tr = termOperand(blk.term);
        if (tr != .none and var_of[tr.index()] != none) ok[var_of[tr.index()]] = false;
    }
    // Renumber the promoted ones.
    var pvars: std.ArrayList(Ref) = .empty;
    for (vars.items, 0..) |v, k| {
        if (ok[k]) {
            var_of[v.index()] = @intCast(pvars.items.len);
            try pvars.append(a, v);
        } else var_of[v.index()] = none;
    }
    const nv = pvars.items.len;
    if (nv == 0) return;
    // CFG: reachable blocks (from the entry) and emitted ones (reachable,
    // plus unreachable merge / continue targets and what they reach, as
    // the emitter's block order).
    const succs = try a.alloc([]const BlockId, nb);
    for (f.blocks.items, succs) |blk, *s| s.* = try successors(a, blk.term);
    const reach = try a.alloc(bool, nb);
    @memset(reach, false);
    var rpo: std.ArrayList(u32) = .empty;
    {
        // Iterative DFS post-order.
        var post: std.ArrayList(u32) = .empty;
        var stack: std.ArrayList(struct { b: u32, next: u32 }) = .empty;
        reach[0] = true;
        try stack.append(a, .{ .b = 0, .next = 0 });
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const ss = succs[top.b];
            if (top.next < ss.len) {
                const s = ss[top.next].index();
                top.next += 1;
                if (!reach[s]) {
                    reach[s] = true;
                    try stack.append(a, .{ .b = s, .next = 0 });
                }
            } else {
                try post.append(a, top.b);
                _ = stack.pop();
            }
        }
        var i = post.items.len;
        while (i > 0) {
            i -= 1;
            try rpo.append(a, post.items[i]);
        }
    }
    const emitted = try a.alloc(bool, nb);
    @memcpy(emitted, reach);
    {
        var changed = true;
        while (changed) {
            changed = false;
            for (f.blocks.items, 0..) |blk, bi| {
                if (!emitted[bi]) continue;
                const targets: [2]BlockId = switch (blk.merge) {
                    .none => .{ .none, .none },
                    .selection => |mb| .{ mb, .none },
                    .loop => |l| .{ l.merge, l.@"continue" },
                };
                for (targets) |tb| if (tb != .none and !emitted[tb.index()]) {
                    emitted[tb.index()] = true;
                    changed = true;
                };
                for (succs[bi]) |s| if (!emitted[s.index()]) {
                    emitted[s.index()] = true;
                    changed = true;
                };
            }
        }
    }
    // Predecessors (emitted ones).
    var preds = try a.alloc(std.ArrayList(u32), nb);
    for (preds) |*p| p.* = .empty;
    for (0..nb) |bi| {
        if (!emitted[bi]) continue;
        for (succs[bi]) |s| try preds[s.index()].append(a, @intCast(bi));
    }
    // Dominators over reachable blocks (Cooper, Harvey, Kennedy).
    const rpo_num = try a.alloc(u32, nb);
    @memset(rpo_num, none);
    for (rpo.items, 0..) |b, k| rpo_num[b] = @intCast(k);
    const idom = try a.alloc(u32, nb);
    @memset(idom, none);
    idom[0] = 0;
    {
        var changed = true;
        while (changed) {
            changed = false;
            for (rpo.items[1..]) |b| {
                var new: u32 = none;
                for (preds[b].items) |p| {
                    if (!reach[p] or idom[p] == none) continue;
                    if (new == none) {
                        new = p;
                        continue;
                    }
                    // intersect
                    var x = p;
                    var y = new;
                    while (x != y) {
                        while (rpo_num[x] > rpo_num[y]) x = idom[x];
                        while (rpo_num[y] > rpo_num[x]) y = idom[y];
                    }
                    new = x;
                }
                if (new != none and idom[b] != new) {
                    idom[b] = new;
                    changed = true;
                }
            }
        }
    }
    // Dominance frontiers.
    var df = try a.alloc(std.ArrayList(u32), nb);
    for (df) |*d| d.* = .empty;
    for (rpo.items) |b| {
        var rp: u32 = 0;
        for (preds[b].items) |p| if (reach[p]) {
            rp += 1;
        };
        if (rp < 2) continue;
        for (preds[b].items) |p| {
            if (!reach[p]) continue;
            var runner = p;
            while (runner != idom[b]) {
                if (std.mem.indexOfScalar(u32, df[runner].items, b) == null) try df[runner].append(a, b);
                runner = idom[runner];
            }
        }
    }
    // Semi-pruned: variables read in some block before being written there
    // (live into it) get phis; the others are block-local.
    const global = try a.alloc(bool, nv);
    @memset(global, false);
    var def_blocks = try a.alloc(std.ArrayList(u32), nv);
    for (def_blocks) |*d| d.* = .empty;
    {
        const written = try a.alloc(u32, nv); // block that last wrote it (+1)
        @memset(written, 0);
        for (rpo.items) |b| {
            for (f.blocks.items[b].insts.items) |r| switch (f.inst(r).op) {
                .load => |p| {
                    const v = var_of[p.index()];
                    if (v != none and written[v] != b + 1) global[v] = true;
                },
                .store => |s| {
                    const v = var_of[s.ptr.index()];
                    if (v != none) {
                        if (written[v] != b + 1) try def_blocks[v].append(a, b);
                        written[v] = b + 1;
                    }
                },
                else => {},
            };
        }
    }
    // Phi placement: phi_of[b] lists (var, phi ref).
    var phis = try a.alloc(std.ArrayList(struct { v: u32, r: Ref }), nb);
    for (phis) |*p| p.* = .empty;
    {
        const has_phi = try a.alloc(u32, nb); // var + 1 that last placed one
        const in_work = try a.alloc(u32, nb);
        @memset(has_phi, 0);
        @memset(in_work, 0);
        var work: std.ArrayList(u32) = .empty;
        for (0..nv) |v| {
            if (!global[v]) continue;
            const tag: u32 = @intCast(v + 1);
            work.clearRetainingCapacity();
            for (def_blocks[v].items) |b| {
                in_work[b] = tag;
                try work.append(a, b);
            }
            while (work.pop()) |b| {
                for (df[b].items) |d| {
                    if (has_phi[d] == tag) continue;
                    has_phi[d] = tag;
                    const ty = f.inst(pvars.items[v]).ty;
                    const r = try addInst(a, f, .{ .op = .{ .phi = &.{} }, .ty = ty });
                    try phis[d].append(a, .{ .v = @intCast(v), .r = r });
                    if (in_work[d] != tag) {
                        in_work[d] = tag;
                        try work.append(a, d);
                    }
                }
            }
        }
    }
    // Undefined values, one per variable (made on first use).
    const undefs = try a.alloc(Ref, nv);
    @memset(undefs, .none);
    const Undef = struct {
        fn get(al: Allocator, fx: *ir.Function, us: []Ref, pv: []const Ref, v: u32) Error!Ref {
            if (us[v] == .none) us[v] = try addInst(al, fx, .{ .op = .undef, .ty = fx.inst(pv[v]).ty });
            return us[v];
        }
    };

    // Renaming over the dominator tree.
    var children = try a.alloc(std.ArrayList(u32), nb);
    for (children) |*c| c.* = .empty;
    for (rpo.items[1..]) |b| if (idom[b] != none) try children[idom[b]].append(a, b);
    // Incoming values: per phi, (value, block) as preds are processed.
    var incoming = try a.alloc(std.ArrayList(@typeInfo(@FieldType(ir.Op, "phi")).pointer.child), f.insts.items.len);
    for (incoming) |*x| x.* = .empty;
    // Replacements (promoted loads, trivial phis), by instruction; the
    // values made later (undefs) have none.
    const Repl = struct {
        to: []Ref,
        fn put(r: *@This(), k: u32, v: Ref) void {
            r.to[k] = v;
        }
        fn get(r: *const @This(), k: u32) ?Ref {
            if (k >= r.to.len or r.to[k] == .none) return null;
            return r.to[k];
        }
        fn contains(r: *const @This(), k: u32) bool {
            return r.get(k) != null;
        }
    };
    var repl = Repl{ .to = try a.alloc(Ref, f.insts.items.len) };
    @memset(repl.to, .none);
    const cur = try a.alloc(Ref, nv);
    for (cur, 0..) |*c, v| c.* = try Undef.get(a, f, undefs, pvars.items, @intCast(v));
    var log: std.ArrayList(struct { v: u32, old: Ref }) = .empty;
    var stack: std.ArrayList(struct { b: u32, mark: usize, enter: bool }) = .empty;
    try stack.append(a, .{ .b = 0, .mark = 0, .enter = true });
    while (stack.pop()) |fr| {
        if (!fr.enter) {
            while (log.items.len > fr.mark) {
                const e = log.pop().?;
                cur[e.v] = e.old;
            }
            continue;
        }
        const b = fr.b;
        try stack.append(a, .{ .b = b, .mark = log.items.len, .enter = false });
        for (phis[b].items) |p| {
            try log.append(a, .{ .v = p.v, .old = cur[p.v] });
            cur[p.v] = p.r;
        }
        for (f.blocks.items[b].insts.items) |r| switch (f.inst(r).op) {
            .load => |p| {
                const v = var_of[p.index()];
                if (v != none) repl.put(r.index(), cur[v]);
            },
            .store => |s| {
                const v = var_of[s.ptr.index()];
                if (v != none) {
                    try log.append(a, .{ .v = v, .old = cur[v] });
                    cur[v] = s.value;
                }
            },
            else => {},
        };
        for (succs[b]) |s| for (phis[s.index()].items) |p| {
            try incoming[p.r.index()].append(a, .{ .value = cur[p.v], .block = @fromBackingInt(@intCast(b)) });
        };
        for (children[b].items) |c| try stack.append(a, .{ .b = c, .mark = 0, .enter = true });
    }
    // Unreachable emitted blocks: loads read undef; their edges into phis
    // carry undef.
    for (0..nb) |bi| {
        if (reach[bi]) continue;
        for (f.blocks.items[bi].insts.items) |r| switch (f.inst(r).op) {
            .load => |p| {
                const v = var_of[p.index()];
                if (v != none) repl.put(r.index(), try Undef.get(a, f, undefs, pvars.items, v));
            },
            else => {},
        };
        if (!emitted[bi]) continue;
        for (succs[bi]) |s| for (phis[s.index()].items) |p| {
            try incoming[p.r.index()].append(a, .{ .value = try Undef.get(a, f, undefs, pvars.items, p.v), .block = @fromBackingInt(@intCast(bi)) });
        };
    }
    // Resolve: replacements may name other replaced loads; trivial phis
    // (one distinct incoming value besides themselves) become that value.
    const Resolve = struct {
        repl: *const Repl,
        pub fn map(c: @This(), x: Ref) Ref {
            var y = x;
            var n: u32 = 0;
            while (y != .none and n < 1 << 20) : (n += 1) {
                y = c.repl.get(y.index()) orelse return y;
            }
            return y;
        }
    };
    const rs = Resolve{ .repl = &repl };
    const Hit = struct {
        repl: *const Repl,
        hit: *bool,
        pub fn use(c: @This(), x: Ref) void {
            if (c.repl.contains(x.index())) c.hit.* = true;
        }
    };
    // Phi incoming lists in place; then fold trivial phis to a fixed point.
    var all_phis: std.ArrayList(Ref) = .empty;
    for (phis) |ps| for (ps.items) |p| {
        f.insts.items[p.r.index()].op = .{ .phi = incoming[p.r.index()].items };
        try all_phis.append(a, p.r);
    };
    var changed = true;
    while (changed) {
        changed = false;
        for (all_phis.items) |p| {
            if (repl.contains(p.index())) continue;
            var same: Ref = .none;
            var trivial = true;
            for (f.inst(p).op.phi) |in| {
                const v = rs.map(in.value);
                if (v == p or v == same) continue;
                if (same != .none) {
                    trivial = false;
                    break;
                }
                same = v;
            }
            if (trivial and same != .none) {
                repl.put(p.index(), same);
                changed = true;
            }
        }
    }
    // Rewrite every block: drop promoted loads / stores / locals, place the
    // remaining phis first, map operands.
    for (f.blocks.items, 0..) |*blk, bi| {
        var out: std.ArrayList(Ref) = .empty;
        for (phis[bi].items) |p| if (!repl.contains(p.r.index())) try out.append(a, p.r);
        for (blk.insts.items) |r| {
            const op = f.inst(r).op;
            switch (op) {
                .local_var => if (var_of[r.index()] != none) continue,
                .load => |p| if (var_of[p.index()] != none) continue,
                .store => |s| if (var_of[s.ptr.index()] != none) continue,
                else => {},
            }
            try out.append(a, r);
        }
        for (out.items) |r| {
            var hit = false;
            try forOperands(a, f.inst(r).op, Hit{ .repl = &repl, .hit = &hit });
            if (hit) f.insts.items[r.index()].op = try opt.mapOp(a, f.inst(r).op, rs);
        }
        blk.insts = out;
        blk.term = switch (blk.term) {
            .ret => |v| .{ .ret = rs.map(v) },
            .cond_br => |c| .{ .cond_br = .{ .cond = rs.map(c.cond), .then = c.then, .@"else" = c.@"else" } },
            .@"switch" => |s| .{ .@"switch" = .{ .value = rs.map(s.value), .default = s.default, .cases = s.cases } },
            else => blk.term,
        };
    }
    // The promoted locals are gone (the emitter declares every local_var).
    for (pvars.items) |v| f.insts.items[v.index()] = .{ .op = .undef, .ty = f.inst(v).ty };
    try removeDeadPhis(a, f);
}

/// Drops phis nothing but dead phis uses: phis are live when a non-phi
/// instruction or a terminator uses them, or a live phi does (dead cycles
/// through loop headers go too).
fn removeDeadPhis(a: Allocator, f: *ir.Function) Error!void {
    const n = f.insts.items.len;
    const live = try a.alloc(bool, n);
    @memset(live, false);
    var work: std.ArrayList(Ref) = .empty;
    const Mark = struct {
        f: *const ir.Function,
        live: []bool,
        work: *std.ArrayList(Ref),
        al: Allocator,
        pub fn use(c: @This(), x: Ref) void {
            if (c.live[x.index()] or c.f.inst(x).op != .phi) return;
            c.live[x.index()] = true;
            c.work.append(c.al, x) catch {};
        }
    };
    const mk = Mark{ .f = f, .live = live, .work = &work, .al = a };
    for (f.blocks.items) |blk| {
        for (blk.insts.items) |r| if (f.inst(r).op != .phi) try forOperands(a, f.inst(r).op, mk);
        const tr = termOperand(blk.term);
        if (tr != .none) mk.use(tr);
    }
    while (work.pop()) |r| for (f.inst(r).op.phi) |in| mk.use(in.value);
    for (f.blocks.items) |*blk| {
        var k: usize = 0;
        while (k < blk.insts.items.len) {
            const r = blk.insts.items[k];
            if (f.inst(r).op == .phi and !live[r.index()]) {
                _ = blk.insts.orderedRemove(k);
            } else k += 1;
        }
    }
}
