//! The SM 6.10 linear algebra usage the PSV0 part records (and the
//! validator recomputes from the module): matrix constructions, matrix-
//! vector and matrix-matrix multiplies, outer products and accumulating
//! stores. A port of dxc's LinAlgRuntimeInfoCollector.

const std = @import("std");
const Allocator = std.mem.Allocator;
const module = @import("module.zig");

/// A matrix type's attributes (`!dx.targetTypes`).
pub const Matrix = struct { comp: u32, m: u32, n: u32, use: u32, scope: u32 };

pub const Shape = struct { m: u32, n: u32, k: u32 };

/// The serialized tables (PSVLinAlg*0 records) and the shape index runs to
/// put in the semantic index table first.
pub const Tables = struct {
    shapes: []const Shape,
    /// PSVLinAlgRuntimeInfo0 record bytes, per table in declaration order:
    /// constructions, thread mat-vec multiplies, wave multiplies,
    /// thread-group multiplies, outer products, accumulate stores.
    records: [6][]const u8,
    counts: [6]u32,
    sizes: [6]u32 = .{ 12, 4, 12, 12, 4, 4 },
    semantic_indices: []const u32,

    pub fn empty(t: Tables) bool {
        if (t.shapes.len > 0) return false;
        for (t.counts) |c| if (c > 0) return false;
        return true;
    }
};

const Key2 = [2]u8;
const Key3 = [3]u8;
const Key4 = [4]u8;

const Info = struct {
    constructions: std.AutoArrayHashMapUnmanaged(Key2, std.AutoArrayHashMapUnmanaged(Shape, void)) = .empty,
    matvec: std.AutoArrayHashMapUnmanaged(Key3, u8) = .empty,
    multiplies: std.AutoArrayHashMapUnmanaged(Key4, std.AutoArrayHashMapUnmanaged(Shape, void)) = .empty,
    outer: std.AutoArrayHashMapUnmanaged(Key2, void) = .empty,
    accumulate: std.AutoArrayHashMapUnmanaged(u8, u8) = .empty,
};

const transposed: u8 = 1;
const non_mul_optimal: u8 = 2;

/// Collects the usage in every function of `m`; `matrices` maps matrix
/// types to their attributes.
pub fn collect(a: Allocator, m: *const module.Module, matrices: []const struct { module.TypeId, Matrix }) Allocator.Error!Tables {
    var info: Info = .{};
    const C = struct {
        m: *const module.Module,
        mats: []const struct { module.TypeId, Matrix },

        fn matrix(c: @This(), ty: ?module.TypeId) ?Matrix {
            const t = ty orelse return null;
            for (c.mats) |x| if (x[0] == t) return x[1];
            return null;
        }

        fn constInt(c: @This(), v: module.Value) ?u32 {
            if (v != .constant) return null;
            return switch (c.m.constants.items[v.constant].kind) {
                .int => |x| @truncate(@as(u64, @bitCast(x))),
                else => null,
            };
        }

        /// DXIL::ComponentType of a scalar (or a vector's element).
        fn component(c: @This(), ty: module.TypeId, signed: bool) u8 {
            const t = switch (c.m.types.items[ty]) {
                .vector => |v| c.m.types.items[v.elem],
                else => |x| x,
            };
            return switch (t) {
                .half => 8,
                .float => 9,
                .double => 10,
                .int => |w| switch (w) {
                    8 => if (signed) 19 else 20,
                    16 => if (signed) 2 else 3,
                    32 => if (signed) 4 else 5,
                    64 => if (signed) 6 else 7,
                    else => 0,
                },
                else => 0,
            };
        }
    };
    const c: C = .{ .m = m, .mats = matrices };
    for (m.functions.items) |*f| {
        const fty = m.types.items[f.ty].function;
        const typeOf = struct {
            fn t(mm: *const module.Module, ff: *const module.Function, ft: @FieldType(module.Type, "function"), v: module.Value) ?module.TypeId {
                return switch (v) {
                    .global => |g| mm.globals.items[g].ptr_ty,
                    .function => null,
                    .constant => |k| mm.constants.items[k].ty,
                    .arg => |x| ft.params[x],
                    .inst => |i| ff.insts.items[i].ty,
                };
            }
        }.t;
        for (f.insts.items) |inst| {
            if (inst.op != .call) continue;
            const call = inst.op.call;
            if (!std.mem.startsWith(u8, m.functions.items[call.callee].name, "dx.op.linAlg") or call.args.len == 0) continue;
            const op = c.constInt(call.args[0]) orelse continue;
            const arg = struct {
                fn t(cc: C, ff: *const module.Function, ft: @FieldType(module.Type, "function"), args: []const module.Value, k: usize) ?module.TypeId {
                    return if (k < args.len) typeOf(cc.m, ff, ft, args[k]) else null;
                }
            }.t;
            switch (op) {
                336, 337 => {
                    const mat = c.matrix(arg(c, f, fty, call.args, 1)) orelse continue;
                    const signed = (c.constInt(call.args[2]) orelse 0) != 0;
                    const key: Key3 = .{ c.component(inst.ty, signed), @intCast(mat.comp), @intCast(c.constInt(call.args[4]) orelse 0) };
                    const gop = try info.matvec.getOrPut(a, key);
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* |= layoutFlags(c, f, call.args[1]);
                },
                334, 322 => {
                    const r = c.matrix(inst.ty) orelse continue;
                    const ma = c.matrix(arg(c, f, fty, call.args, 1)) orelse continue;
                    const mb = c.matrix(arg(c, f, fty, call.args, 2)) orelse continue;
                    const key: Key4 = .{ @intCast(r.scope), @intCast(r.comp), @intCast(ma.comp), @intCast(mb.comp) };
                    const gop = try info.multiplies.getOrPut(a, key);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.put(a, .{ .m = ma.m, .n = mb.n, .k = ma.n }, {});
                },
                340 => {
                    const r = c.matrix(inst.ty) orelse continue;
                    const signed = (c.constInt(call.args[1]) orelse 0) != 0;
                    const vt = arg(c, f, fty, call.args, 2) orelse continue;
                    try info.outer.put(a, .{ @intCast(r.comp), c.component(vt, signed) }, {});
                },
                338, 339 => {
                    const mat = c.matrix(arg(c, f, fty, call.args, 1)) orelse continue;
                    const gop = try info.accumulate.getOrPut(a, @intCast(mat.comp));
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* |= if (op == 338) 1 else 2;
                },
                342 => {
                    const vt = arg(c, f, fty, call.args, 4) orelse continue;
                    const gop = try info.accumulate.getOrPut(a, c.component(vt, true));
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* |= 1;
                },
                else => {
                    try construction(a, &info, c.matrix(inst.ty));
                    for (call.args, 0..) |_, k| try construction(a, &info, c.matrix(arg(c, f, fty, call.args, k)));
                },
            }
        }
    }
    return serialize(a, &info);
}

fn construction(a: Allocator, info: *Info, mat: ?Matrix) Allocator.Error!void {
    const x = mat orelse return;
    if (x.scope == 0) return; // Thread
    const shape: Shape = .{
        .m = if (x.use == 1) 0 else x.m,
        .n = if (x.use == 0) 0 else x.n,
        .k = if (x.use == 2) 0 else if (x.use == 0) x.n else x.m,
    };
    const gop = try info.constructions.getOrPut(a, .{ @intCast(x.comp), @intCast(x.use) });
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.put(a, shape, {});
}

/// How a mat-vec multiply's matrix was loaded (both flags when unknown:
/// zdxc's matrices pass through local variables).
fn layoutFlags(c: anytype, f: *const module.Function, v0: module.Value) u8 {
    var v = v0;
    var flags: u8 = 0;
    var steps: usize = 0;
    while (steps < 64) : (steps += 1) {
        if (v != .inst) return transposed | non_mul_optimal;
        const inst = f.insts.items[v.inst];
        if (inst.op != .call) return transposed | non_mul_optimal;
        const call = inst.op.call;
        const op = if (call.args.len > 0) c.constInt(call.args[0]) else null;
        if (op == 324) {
            v = call.args[1];
            continue;
        }
        if (op == 325) {
            const layout = c.constInt(call.args[4]) orelse return transposed | non_mul_optimal;
            if (layout == 3) flags |= transposed else if (layout != 2) flags |= non_mul_optimal;
            return flags;
        }
        return transposed | non_mul_optimal;
    }
    return transposed | non_mul_optimal;
}

fn lessShape(_: void, x: Shape, y: Shape) bool {
    if (x.m != y.m) return x.m < y.m;
    if (x.n != y.n) return x.n < y.n;
    return x.k < y.k;
}

fn sortedShapes(a: Allocator, set: std.AutoArrayHashMapUnmanaged(Shape, void)) Allocator.Error![]Shape {
    const out = try a.dupe(Shape, set.keys());
    std.sort.insertion(Shape, out, {}, lessShape);
    return out;
}

fn sortedKeys(comptime K: type, a: Allocator, keys: []const K) Allocator.Error![]K {
    const out = try a.dupe(K, keys);
    std.sort.insertion(K, out, {}, struct {
        fn lt(_: void, x: K, y: K) bool {
            return std.mem.order(u8, std.mem.asBytes(&x), std.mem.asBytes(&y)) == .lt;
        }
    }.lt);
    return out;
}

const Writer = struct {
    a: Allocator,
    shapes: std.ArrayList(Shape) = .empty,
    indices: std.ArrayList(u32) = .empty,

    /// AddLinAlgShapes: shape table indexes, as a run in the semantic
    /// index table (shared with an equal earlier run).
    fn shapeRun(w: *Writer, shapes: []const Shape) Allocator.Error![2]u32 {
        var idx: std.ArrayList(u32) = .empty;
        for (shapes) |s| {
            const k = for (w.shapes.items, 0..) |x, i| {
                if (std.meta.eql(x, s)) break i;
            } else blk: {
                try w.shapes.append(w.a, s);
                break :blk w.shapes.items.len - 1;
            };
            try idx.append(w.a, @intCast(k));
        }
        var off: usize = 0;
        while (off + idx.items.len <= w.indices.items.len) : (off += 1) {
            if (std.mem.eql(u32, w.indices.items[off..][0..idx.items.len], idx.items)) return .{ @intCast(off), @intCast(idx.items.len) };
        }
        const at: u32 = @intCast(w.indices.items.len);
        try w.indices.appendSlice(w.a, idx.items);
        return .{ at, @intCast(idx.items.len) };
    }
};

fn put32(a: Allocator, out: *std.ArrayList(u8), v: u32) Allocator.Error!void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(a, &b);
}

fn serialize(a: Allocator, info: *Info) Allocator.Error!Tables {
    var w: Writer = .{ .a = a };
    var recs: [6]std.ArrayList(u8) = .{ .empty, .empty, .empty, .empty, .empty, .empty };
    var counts: [6]u32 = .{ 0, 0, 0, 0, 0, 0 };
    // (std::map order: keys sorted.)
    for (try sortedKeys(Key2, a, info.constructions.keys())) |k| {
        const run = try w.shapeRun(try sortedShapes(a, info.constructions.get(k).?));
        try put32(a, &recs[0], run[0]);
        try put32(a, &recs[0], run[1]);
        try recs[0].appendSlice(a, &.{ k[0], 0, 0, 0 });
        counts[0] += 1;
    }
    for (try sortedKeys(Key3, a, info.matvec.keys())) |k| {
        try recs[1].appendSlice(a, &.{ k[0], k[1], k[2], info.matvec.get(k).? });
        counts[1] += 1;
    }
    for (try sortedKeys(Key4, a, info.multiplies.keys())) |k| {
        const run = try w.shapeRun(try sortedShapes(a, info.multiplies.get(k).?));
        const t: usize = if (k[0] == 1) 2 else 3; // Wave, else ThreadGroup
        try put32(a, &recs[t], run[0]);
        try put32(a, &recs[t], run[1]);
        try recs[t].appendSlice(a, &.{ k[1], k[2], k[3], 0 });
        counts[t] += 1;
    }
    for (try sortedKeys(Key2, a, info.outer.keys())) |k| {
        try recs[4].appendSlice(a, &.{ k[0], k[1], 0, 0 });
        counts[4] += 1;
    }
    for (try sortedKeys(u8, a, info.accumulate.keys())) |k| {
        try recs[5].appendSlice(a, &.{ k, info.accumulate.get(k).?, 0, 0 });
        counts[5] += 1;
    }
    return .{
        .shapes = w.shapes.items,
        .records = .{ recs[0].items, recs[1].items, recs[2].items, recs[3].items, recs[4].items, recs[5].items },
        .counts = counts,
        .semantic_indices = w.indices.items,
    };
}

/// The PSV0 LinAlg block: PSVLinAlgRuntimeInfo0, then each non-empty
/// table as its record size and records.
pub fn psvBlock(a: Allocator, t: Tables, out: *std.ArrayList(u8)) Allocator.Error!void {
    try put32(a, out, 28); // sizeof(PSVLinAlgRuntimeInfo0)
    try put32(a, out, @intCast(t.shapes.len));
    for (t.counts) |n| try put32(a, out, n);
    if (t.shapes.len > 0) {
        try put32(a, out, 12);
        for (t.shapes) |s| for ([_]u32{ s.m, s.n, s.k }) |v| try put32(a, out, v);
    }
    for (t.records, t.counts, t.sizes) |r, n, sz| if (n > 0) {
        try put32(a, out, sz);
        try out.appendSlice(a, r);
    };
}
