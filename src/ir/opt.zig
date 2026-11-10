//! IR optimizations shared by both backends: full unrolling of loops with
//! a constant trip count (`[unroll]`, and loops whose texel offsets must
//! become constants, as dxc's unrolling makes them) and constant folding.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("ir.zig");
const types = @import("../sema/types.zig");
const texture = @import("texture.zig");
const lower = @import("lower.zig");

const Ref = ir.Ref;
const BlockId = ir.BlockId;
const Op = ir.Op;
const Constant = ir.Constant;
const TypeId = types.TypeId;
const TypeTable = types.TypeTable;
const Scalar = types.Scalar;

pub fn run(a: Allocator, m: *ir.Module) Allocator.Error!void {
    for (m.functions.items) |f| {
        try unrollLoops(a, m.types, f);
        try fold(a, m.types, f);
    }
}

// ----------------------------------------------------------------------
// Scalar folding

fn scalarOf(t: *TypeTable, ty: TypeId) ?Scalar {
    return switch (t.get(ty)) {
        .scalar => |s| s,
        else => null,
    };
}

fn bits(s: Scalar) u7 {
    return switch (s) {
        .literal_int, .int64, .uint64 => 64,
        .int16, .uint16 => 16,
        else => 32,
    };
}

/// `v` wrapped to the width and signedness of `s`.
fn wrapInt(s: Scalar, v: i64) i64 {
    if (s == .bool) return @intFromBool(v != 0);
    const n = bits(s);
    if (n == 64) return v;
    const mask = (@as(u64, 1) << @intCast(n)) - 1;
    const u = @as(u64, @bitCast(v)) & mask;
    if (s.isUnsigned()) return @intCast(u);
    const sign = @as(u64, 1) << @intCast(n - 1);
    return @bitCast(if (u & sign != 0) u | ~mask else u);
}

fn normalize(s: Scalar, c: Constant) Constant {
    if (s.isFloat()) {
        const v = switch (c) {
            .float => |x| x,
            .int => |x| @as(f64, @floatFromInt(x)),
        };
        return .{ .float = switch (s) {
            .double => v,
            .float16 => @as(f64, @as(f16, @floatCast(v))),
            else => @as(f64, @as(f32, @floatCast(v))),
        } };
    }
    return .{ .int = wrapInt(s, switch (c) {
        .int => |x| x,
        .float => |x| lower.saturatingInt(x),
    }) };
}

fn asFloat(c: Constant) f64 {
    return switch (c) {
        .float => |x| x,
        .int => |x| @floatFromInt(x),
    };
}

fn asInt(c: Constant) i64 {
    return switch (c) {
        .int => |x| x,
        .float => |x| lower.saturatingInt(x),
    };
}

pub fn foldBinary(s: Scalar, op: ir.BinaryOp, x: Constant, y: Constant) ?Constant {
    if (s.isFloat()) {
        const p = asFloat(x);
        const q = asFloat(y);
        return normalize(s, .{ .float = switch (op) {
            .add => p + q,
            .sub => p - q,
            .mul => p * q,
            .div => p / q,
            .rem => if (q == 0) return null else @rem(p, q),
            else => return null,
        } });
    }
    const p = asInt(x);
    const q = asInt(y);
    const n: u6 = @intCast(bits(s) - 1);
    const r: i64 = switch (op) {
        .add => p +% q,
        .sub => p -% q,
        .mul => p *% q,
        .div => if (q == 0) return null else if (s.isUnsigned()) @intCast(@as(u64, @bitCast(p)) / @as(u64, @bitCast(q))) else if (p == std.math.minInt(i64) and q == -1) return null else @divTrunc(p, q),
        .rem => if (q == 0) return null else if (s.isUnsigned()) @intCast(@as(u64, @bitCast(p)) % @as(u64, @bitCast(q))) else if (q == -1) 0 else @rem(p, q),
        .shl => p << @intCast(@as(u64, @bitCast(q)) & n),
        .shr => if (s.isUnsigned()) @bitCast(@as(u64, @bitCast(p)) >> @intCast(@as(u64, @bitCast(q)) & n)) else p >> @intCast(@as(u64, @bitCast(q)) & n),
        .bit_and, .log_and => p & q,
        .bit_or, .log_or => p | q,
        .bit_xor => p ^ q,
    };
    return normalize(s, .{ .int = r });
}

pub fn foldCmp(s: Scalar, op: ir.CmpOp, x: Constant, y: Constant) ?Constant {
    const r: bool = if (s.isFloat()) blk: {
        const p = asFloat(x);
        const q = asFloat(y);
        break :blk switch (op) {
            .eq => p == q,
            .ne => p != q,
            .lt => p < q,
            .le => p <= q,
            .gt => p > q,
            .ge => p >= q,
        };
    } else if (s.isUnsigned()) blk: {
        const p: u64 = @bitCast(asInt(x));
        const q: u64 = @bitCast(asInt(y));
        break :blk switch (op) {
            .eq => p == q,
            .ne => p != q,
            .lt => p < q,
            .le => p <= q,
            .gt => p > q,
            .ge => p >= q,
        };
    } else blk: {
        const p = asInt(x);
        const q = asInt(y);
        break :blk switch (op) {
            .eq => p == q,
            .ne => p != q,
            .lt => p < q,
            .le => p <= q,
            .gt => p > q,
            .ge => p >= q,
        };
    };
    return .{ .int = @intFromBool(r) };
}

pub fn foldUnary(s: Scalar, op: ir.UnaryOp, x: Constant) ?Constant {
    return switch (op) {
        .neg => if (s.isFloat()) normalize(s, .{ .float = -asFloat(x) }) else normalize(s, .{ .int = 0 -% asInt(x) }),
        .not => .{ .int = @intFromBool(asInt(x) == 0) },
        .bit_not => if (s.isFloat()) null else normalize(s, .{ .int = ~asInt(x) }),
    };
}

pub fn foldConvert(from: Scalar, to: Scalar, x: Constant) Constant {
    if (to == .bool) return .{ .int = @intFromBool(if (from.isFloat()) asFloat(x) != 0 else asInt(x) != 0) };
    if (from.isFloat() and !to.isFloat() and to.isUnsigned() and asFloat(x) < 0) return .{ .int = 0 };
    return normalize(to, x);
}

// ----------------------------------------------------------------------
// Operand mapping

fn mapRefs(a: Allocator, xs: []const Ref, ctx: anytype) Allocator.Error![]const Ref {
    const out = try a.alloc(Ref, xs.len);
    for (xs, out) |x, *o| o.* = ctx.map(x);
    return out;
}

/// `op` with every operand passed through `ctx.map`.
pub fn mapOp(a: Allocator, op: Op, ctx: anytype) Allocator.Error!Op {
    return switch (op) {
        .constant, .param, .global, .local_var, .input, .input_vertex, .emit, .cut, .patch_input, .output_vertex, .mesh_output, .mesh_payload, .ray_incoming, .spec_constant, .undef, .node_io => op,
        .load => |p| .{ .load = ctx.map(p) },
        .store => |x| .{ .store = .{ .ptr = ctx.map(x.ptr), .value = ctx.map(x.value) } },
        .access => |x| .{ .access = .{ .base = ctx.map(x.base), .indices = try mapRefs(a, x.indices, ctx) } },
        .binary => |x| .{ .binary = .{ .op = x.op, .lhs = ctx.map(x.lhs), .rhs = ctx.map(x.rhs) } },
        .unary => |x| .{ .unary = .{ .op = x.op, .operand = ctx.map(x.operand) } },
        .cmp => |x| .{ .cmp = .{ .op = x.op, .lhs = ctx.map(x.lhs), .rhs = ctx.map(x.rhs) } },
        .convert => |x| .{ .convert = ctx.map(x) },
        .bitcast => |x| .{ .bitcast = ctx.map(x) },
        .splat => |x| .{ .splat = ctx.map(x) },
        .extract => |x| .{ .extract = .{ .agg = ctx.map(x.agg), .index = x.index } },
        .insert => |x| .{ .insert = .{ .agg = ctx.map(x.agg), .value = ctx.map(x.value), .index = x.index } },
        .construct => |xs| .{ .construct = try mapRefs(a, xs, ctx) },
        .shuffle => |x| .{ .shuffle = .{ .vec = ctx.map(x.vec), .components = x.components } },
        .select => |x| .{ .select = .{ .cond = ctx.map(x.cond), .t = ctx.map(x.t), .f = ctx.map(x.f) } },
        .call => |x| .{ .call = .{ .func = x.func, .args = try mapRefs(a, x.args, ctx) } },
        .intrinsic => |x| .{ .intrinsic = .{ .name = x.name, .args = try mapRefs(a, x.args, ctx) } },
        .res_load => |x| .{ .res_load = .{ .res = ctx.map(x.res), .index = ctx.map(x.index) } },
        .res_store => |x| .{ .res_store = .{ .res = ctx.map(x.res), .index = ctx.map(x.index), .value = ctx.map(x.value) } },
        .method => |x| .{ .method = .{ .name = x.name, .res = ctx.map(x.res), .args = try mapRefs(a, x.args, ctx) } },
        .output => |x| .{ .output = .{ .element = x.element, .value = ctx.map(x.value) } },
        .heap_resource => |h| .{ .heap_resource = .{ .index = ctx.map(h.index), .sampler = h.sampler } },
        .spirv_inst => |x| blk: {
            const ops = try a.dupe(@typeInfo(@TypeOf(x.operands)).pointer.child, x.operands);
            for (ops) |*o| switch (o.*) {
                .value => |*v| v.* = ctx.map(v.*),
                .literal, .type, .string => {},
            };
            const n = try a.create(ir.SpirvInst);
            n.* = x.*;
            n.operands = ops;
            break :blk .{ .spirv_inst = n };
        },
        .patch_output => |x| .{ .patch_output = .{ .element = x.element, .value = ctx.map(x.value) } },
        .phi => |ps| blk: {
            const out = try a.alloc(@typeInfo(@TypeOf(ps)).pointer.child, ps.len);
            for (ps, out) |p, *o| o.* = .{ .value = ctx.map(p.value), .block = p.block };
            break :blk .{ .phi = out };
        },
    };
}

/// Calls `ctx.use(r)` for every operand of `op` (none skipped), without
/// allocating.
pub fn eachOperand(op: Op, ctx: anytype) void {
    switch (op) {
        .constant, .param, .global, .local_var, .input, .input_vertex, .emit, .cut, .patch_input, .output_vertex, .mesh_output, .mesh_payload, .ray_incoming, .spec_constant, .undef, .node_io => {},
        .load => |p| ctx.use(p),
        .store => |x| {
            ctx.use(x.ptr);
            ctx.use(x.value);
        },
        .access => |x| {
            ctx.use(x.base);
            for (x.indices) |r| ctx.use(r);
        },
        .binary => |x| {
            ctx.use(x.lhs);
            ctx.use(x.rhs);
        },
        .unary => |x| ctx.use(x.operand),
        .cmp => |x| {
            ctx.use(x.lhs);
            ctx.use(x.rhs);
        },
        .convert, .bitcast, .splat => |x| ctx.use(x),
        .extract => |x| ctx.use(x.agg),
        .insert => |x| {
            ctx.use(x.agg);
            ctx.use(x.value);
        },
        .construct => |xs| for (xs) |r| ctx.use(r),
        .shuffle => |x| ctx.use(x.vec),
        .select => |x| {
            ctx.use(x.cond);
            ctx.use(x.t);
            ctx.use(x.f);
        },
        .call => |x| for (x.args) |r| ctx.use(r),
        .intrinsic => |x| for (x.args) |r| ctx.use(r),
        .res_load => |x| {
            ctx.use(x.res);
            ctx.use(x.index);
        },
        .res_store => |x| {
            ctx.use(x.res);
            ctx.use(x.index);
            ctx.use(x.value);
        },
        .method => |x| {
            ctx.use(x.res);
            for (x.args) |r| ctx.use(r);
        },
        .output => |x| ctx.use(x.value),
        .heap_resource => |h| ctx.use(h.index),
        .spirv_inst => |x| for (x.operands) |o| switch (o) {
            .value => |v| ctx.use(v),
            .literal, .type, .string => {},
        },
        .patch_output => |x| ctx.use(x.value),
        .phi => |ps| for (ps) |pp| ctx.use(pp.value),
    }
}

/// Calls `ctx.use(r)` for every operand of `op` and of terminator `term`.
fn forOperands(a: Allocator, op: Op, ctx: anytype) Allocator.Error!void {
    const Collect = struct {
        inner: @TypeOf(ctx),
        fn map(c: @This(), r: Ref) Ref {
            if (r != .none) c.inner.use(r);
            return r;
        }
    };
    _ = try mapOp(a, op, Collect{ .inner = ctx });
}

fn termRefs(term: ir.Terminator) [1]Ref {
    return .{switch (term) {
        .ret => |r| r,
        .cond_br => |c| c.cond,
        .@"switch" => |s| s.value,
        else => .none,
    }};
}

fn successors(a: Allocator, term: ir.Terminator) Allocator.Error![]const BlockId {
    return switch (term) {
        .br => |b| try a.dupe(BlockId, &.{b}),
        .cond_br => |c| try a.dupe(BlockId, &.{ c.then, c.@"else" }),
        .@"switch" => |s| blk: {
            const out = try a.alloc(BlockId, s.cases.len + 1);
            out[0] = s.default;
            for (s.cases, out[1..]) |c, *o| o.* = c.block;
            break :blk out;
        },
        else => &.{},
    };
}

fn reachable(a: Allocator, f: *ir.Function) Allocator.Error![]bool {
    const seen = try a.alloc(bool, f.blocks.items.len);
    @memset(seen, false);
    var stack: std.ArrayList(u32) = .empty;
    try stack.append(a, 0);
    while (stack.pop()) |b| {
        if (seen[b]) continue;
        seen[b] = true;
        for (try successors(a, f.blocks.items[b].term)) |s| try stack.append(a, s.index());
    }
    return seen;
}

// ----------------------------------------------------------------------
// Constant folding

/// Component `k` of `r` if it is a known constant.
fn componentConst(t: *TypeTable, f: *ir.Function, r: Ref, k: usize) ?Constant {
    const i = f.inst(r);
    switch (i.op) {
        .constant => |c| return c,
        .construct => |xs| {
            if (t.get(i.ty) != .vector or k >= xs.len) return null;
            const p = f.inst(xs[k]);
            return if (p.op == .constant and scalarOf(t, p.ty) != null) p.op.constant else null;
        },
        else => return null,
    }
}

fn isConst(t: *TypeTable, f: *ir.Function, r: Ref) bool {
    const i = f.inst(r);
    const n = componentCount(t, i.ty) orelse return false;
    for (0..n) |k| if (componentConst(t, f, r, k) == null) return false;
    return true;
}

fn componentCount(t: *TypeTable, ty: TypeId) ?usize {
    return switch (t.get(ty)) {
        .scalar => 1,
        .vector => |v| v.len,
        else => null,
    };
}

fn addInst(a: Allocator, f: *ir.Function, inst: ir.Inst) Allocator.Error!Ref {
    try f.insts.append(a, inst);
    return @enumFromInt(f.insts.items.len - 1);
}

/// Folds operations on scalar and vector constants in place (vector
/// results become constructs of new constant scalars).
pub fn fold(a: Allocator, t: *TypeTable, f: *ir.Function) Allocator.Error!void {
    const live = try reachable(a, f);
    for (f.blocks.items, 0..) |*blk, bi| {
        if (!live[bi]) continue;
        var pos: usize = 0;
        while (pos < blk.insts.items.len) : (pos += 1) {
            const r = blk.insts.items[pos];
            const i = f.inst(r);
            const n = componentCount(t, i.ty) orelse continue;
            const rs = t.component(i.ty) orelse continue;
            var comps: [4]Constant = undefined;
            if (n > 4) continue;
            const ok = for (0..n) |k| {
                comps[k] = (switch (i.op) {
                    .binary => |x| blk2: {
                        const p = componentConst(t, f, x.lhs, k) orelse break :blk2 null;
                        const q = componentConst(t, f, x.rhs, k) orelse break :blk2 null;
                        break :blk2 foldBinary(rs, x.op, p, q);
                    },
                    .unary => |x| foldUnary(rs, x.op, componentConst(t, f, x.operand, k) orelse break false),
                    .cmp => |x| blk2: {
                        const os = t.component(f.inst(x.lhs).ty) orelse break :blk2 null;
                        const p = componentConst(t, f, x.lhs, k) orelse break :blk2 null;
                        const q = componentConst(t, f, x.rhs, k) orelse break :blk2 null;
                        break :blk2 foldCmp(os, x.op, p, q);
                    },
                    .convert => |x| blk2: {
                        const fs = t.component(f.inst(x).ty) orelse break :blk2 null;
                        break :blk2 foldConvert(fs, rs, componentConst(t, f, x, k) orelse break :blk2 null);
                    },
                    .splat => |x| componentConst(t, f, x, 0),
                    .extract => |x| if (t.get(f.inst(x.agg).ty) == .vector) componentConst(t, f, x.agg, x.index) else null,
                    .shuffle => |x| componentConst(t, f, x.vec, x.components[k]),
                    else => null,
                }) orelse break false;
            } else true;
            if (!ok) continue;
            if (n == 1) {
                f.insts.items[r.index()].op = .{ .constant = comps[0] };
                continue;
            }
            // New scalar constants go just before the folded instruction.
            const st = try t.scalar(rs);
            const parts = try a.alloc(Ref, n);
            for (parts, comps[0..n]) |*p, c| {
                p.* = try addInst(a, f, .{ .op = .{ .constant = c }, .ty = st });
                try blk.insts.insert(a, pos, p.*);
                pos += 1;
            }
            f.insts.items[r.index()].op = .{ .construct = parts };
        }
    }
}

// ----------------------------------------------------------------------
// Loop unrolling

const unroll_limit = 1024;
/// Trip limit for loops unrolled only to make texel offsets constant.
const auto_unroll_limit = 64;

/// Evaluates scalar `r` with the induction variable `iv` holding `v`.
fn eval(t: *TypeTable, f: *ir.Function, r: Ref, iv: Ref, v: ?Constant, depth: u32) ?Constant {
    if (depth > 64) return null;
    const i = f.inst(r);
    const s = scalarOf(t, i.ty) orelse return null;
    return switch (i.op) {
        .constant => |c| c,
        .load => |p| if (p == iv) v else null,
        .convert => |x| foldConvert(scalarOf(t, f.inst(x).ty) orelse return null, s, eval(t, f, x, iv, v, depth + 1) orelse return null),
        .binary => |x| foldBinary(s, x.op, eval(t, f, x.lhs, iv, v, depth + 1) orelse return null, eval(t, f, x.rhs, iv, v, depth + 1) orelse return null),
        .unary => |x| foldUnary(s, x.op, eval(t, f, x.operand, iv, v, depth + 1) orelse return null),
        .cmp => |x| foldCmp(scalarOf(t, f.inst(x.lhs).ty) orelse return null, x.op, eval(t, f, x.lhs, iv, v, depth + 1) orelse return null, eval(t, f, x.rhs, iv, v, depth + 1) orelse return null),
        else => null,
    };
}

fn unrollLoops(a: Allocator, t: *TypeTable, f: *ir.Function) Allocator.Error!void {
    var kept: std.AutoHashMapUnmanaged(u32, void) = .empty;
    while (true) {
        const live = try reachable(a, f);
        // An innermost loop not yet tried: no other candidate inside it.
        var pick: ?u32 = null;
        var sets: std.AutoHashMapUnmanaged(u32, []bool) = .empty;
        for (f.blocks.items, 0..) |blk, bi| {
            if (!live[bi] or blk.merge != .loop or kept.contains(@intCast(bi))) continue;
            try sets.put(a, @intCast(bi), try loopBlocks(a, f, @intCast(bi)));
        }
        var it = sets.iterator();
        outer: while (it.next()) |kv| {
            var it2 = sets.iterator();
            while (it2.next()) |other| {
                if (other.key_ptr.* != kv.key_ptr.* and kv.value_ptr.*[other.key_ptr.*]) continue :outer;
            }
            pick = kv.key_ptr.*;
            break;
        }
        const h = pick orelse return;
        if (!try unrollOne(a, t, f, h, sets.get(h).?, live)) try kept.put(a, h, {});
    }
}

/// Blocks of the loop headed by `h` (header excluded, merge excluded).
fn loopBlocks(a: Allocator, f: *ir.Function, h: u32) Allocator.Error![]bool {
    const set = try a.alloc(bool, f.blocks.items.len);
    @memset(set, false);
    const merge = f.blocks.items[h].merge.loop.merge.index();
    var stack: std.ArrayList(u32) = .empty;
    for (try successors(a, f.blocks.items[h].term)) |s| try stack.append(a, s.index());
    while (stack.pop()) |b| {
        if (b == h or b == merge or set[b]) continue;
        set[b] = true;
        for (try successors(a, f.blocks.items[b].term)) |s| try stack.append(a, s.index());
    }
    return set;
}

fn isPure(op: Op) bool {
    return switch (op) {
        .constant, .load, .binary, .unary, .cmp, .convert, .splat, .extract, .shuffle, .construct => true,
        else => false,
    };
}

/// Whether the loop body samples or loads with texel offsets (which DXIL
/// and Vulkan need as constants).
fn hasTexelOffsets(t: *TypeTable, f: *ir.Function, set: []const bool) bool {
    for (f.blocks.items, 0..) |blk, bi| {
        if (!set[bi]) continue;
        for (blk.insts.items) |r| {
            const m = switch (f.inst(r).op) {
                .method => |m| m,
                else => continue,
            };
            const rk = switch (t.get(f.inst(m.res).ty)) {
                .resource => |rk| rk,
                else => continue,
            };
            const sh = texture.shape(rk.kind) orelse continue;
            const call = texture.decode(m.name, sh, m.args.len) orelse continue;
            if (call.offset != null) return true;
        }
    }
    return false;
}

fn unrollOne(a: Allocator, t: *TypeTable, f: *ir.Function, h: u32, set: []const bool, live: []const bool) Allocator.Error!bool {
    const hb = f.blocks.items[h];
    const lp = hb.merge.loop;
    if (lp.unroll == .dont) return false;
    const merge = lp.merge.index();
    const cont = lp.@"continue".index();
    // header: `br check`; check: `br cond, body, merge`; continue: `br header`.
    if (hb.insts.items.len != 0 or hb.term != .br) return false;
    const check = hb.term.br.index();
    if (!set[check] or !set[cont]) return false;
    const cb = f.blocks.items[check];
    if (cb.term != .cond_br or cb.term.cond_br.@"else".index() != merge) return false;
    const body = cb.term.cond_br.then.index();
    if (body == cont or f.blocks.items[cont].term != .br or f.blocks.items[cont].term.br.index() != h) return false;
    for (cb.insts.items) |r| if (!isPure(f.inst(r).op)) return false;

    // No break (other edges to merge), no continue (several edges to the
    // continue block): their unrolled jumps would leave structured regions.
    var preheader: ?u32 = null;
    var cont_preds: u32 = 0;
    for (f.blocks.items, 0..) |blk, bi| {
        if (!live[bi]) continue;
        for (try successors(a, blk.term)) |s| {
            const si = s.index();
            if (si == merge and set[bi] and bi != check) return false;
            if (si == cont and set[bi]) cont_preds += 1;
            if (si == h and !set[bi]) {
                if (preheader != null) return false;
                preheader = @intCast(bi);
            }
        }
    }
    if (cont_preds != 1) return false;
    const pre = preheader orelse return false;

    // The induction variable: the one local the condition reads.
    var iv: Ref = .none;
    for (cb.insts.items) |r| switch (f.inst(r).op) {
        .load => |p| {
            if (f.inst(p).op != .local_var) return false;
            if (iv != .none and iv != p) return false;
            iv = p;
        },
        else => {},
    };
    if (iv == .none or scalarOf(t, f.inst(iv).ty) == null) return false;
    // Only loads and stores touch it; inside the loop only the continue
    // block stores to it, once.
    var step: Ref = .none;
    var step_pos: usize = 0;
    for (f.blocks.items, 0..) |blk, bi| {
        if (!live[bi]) continue;
        for (blk.insts.items, 0..) |r, pos| {
            const op = f.inst(r).op;
            switch (op) {
                .load => continue,
                .store => |s| {
                    if (s.value == iv) return false;
                    if (s.ptr == iv and set[bi]) {
                        if (bi != cont or step != .none) return false;
                        step = s.value;
                        step_pos = pos;
                    }
                    continue;
                },
                else => {},
            }
            const Uses = struct {
                iv: Ref,
                bad: *bool,
                fn use(c: @This(), x: Ref) void {
                    if (x == c.iv) c.bad.* = true;
                }
            };
            var bad = false;
            try forOperands(a, op, Uses{ .iv = iv, .bad = &bad });
            if (bad) return false;
        }
    }
    if (step == .none) return false;
    // Its value on entry: the last store in the preheader.
    const pb = f.blocks.items[pre];
    if (pb.term != .br) return false;
    var init: ?Constant = null;
    var k = pb.insts.items.len;
    while (k > 0) {
        k -= 1;
        const op = f.inst(pb.insts.items[k]).op;
        if (op == .store and op.store.ptr == iv) {
            init = eval(t, f, op.store.value, .none, null, 0) orelse return false;
            break;
        }
    }
    var v = init orelse return false;

    // EXPERIMENT (dxil/exp.zig): unroll_none keeps only the unrolling texel
    // offsets need (they must be constants).
    const texel = hasTexelOffsets(t, f, set);
    const wanted = (lp.unroll == .unroll and @import("../dxil/exp.zig").cur.unroll != .none) or texel;
    if (!wanted) return false;
    const limit: usize = if (lp.unroll == .unroll) unroll_limit else auto_unroll_limit;
    const cond = cb.term.cond_br.cond;
    var values: std.ArrayList(Constant) = .empty;
    while (true) {
        const c = eval(t, f, cond, iv, v, 0) orelse return false;
        if (asInt(c) == 0) break;
        if (values.items.len >= limit) return false;
        try values.append(a, v);
        v = eval(t, f, step, iv, v, 0) orelse return false;
    }

    // The condition block is dropped: nothing else may use its values.
    {
        var from_check: std.AutoHashMapUnmanaged(u32, void) = .empty;
        for (cb.insts.items) |r| try from_check.put(a, r.index(), {});
        const Uses = struct {
            defined: *const std.AutoHashMapUnmanaged(u32, void),
            bad: *bool,
            fn use(c: @This(), x: Ref) void {
                if (c.defined.contains(x.index())) c.bad.* = true;
            }
        };
        var bad = false;
        for (f.blocks.items, 0..) |blk, bi| {
            if (!live[bi] or bi == check) continue;
            for (blk.insts.items) |r| try forOperands(a, f.inst(r).op, Uses{ .defined = &from_check, .bad = &bad });
            const tr = termRefs(blk.term)[0];
            if (tr != .none and from_check.contains(tr.index())) bad = true;
        }
        if (bad) return false;
    }

    // Values made inside the loop must not be used after it.
    var defined: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (f.blocks.items, 0..) |blk, bi| if (set[bi]) for (blk.insts.items) |r| try defined.put(a, r.index(), {});
    for (f.blocks.items, 0..) |blk, bi| {
        if (!live[bi] or set[bi] or bi == h) continue;
        const Uses = struct {
            defined: *const std.AutoHashMapUnmanaged(u32, void),
            bad: *bool,
            fn use(c: @This(), x: Ref) void {
                if (c.defined.contains(x.index())) c.bad.* = true;
            }
        };
        var bad = false;
        for (blk.insts.items) |r| try forOperands(a, f.inst(r).op, Uses{ .defined = &defined, .bad = &bad });
        const tr = termRefs(blk.term)[0];
        if (tr != .none and defined.contains(tr.index())) bad = true;
        if (bad) return false;
    }

    // Clone the body and continue block once per iteration, chained.
    const iv_ty = f.inst(iv).ty;
    const iv_s = scalarOf(t, iv_ty).?;
    const entries = try a.alloc(u32, values.items.len);
    const conts = try a.alloc(u32, values.items.len);
    const n_blocks = f.blocks.items.len;
    for (values.items, 0..) |val, iter| {
        const next = foldStep(t, f, step, iv, val);
        var bmap: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        for (0..n_blocks) |bi| {
            if (!set[bi] or bi == check) continue;
            try f.blocks.append(a, .{});
            try bmap.put(a, @intCast(bi), @intCast(f.blocks.items.len - 1));
        }
        var imap: std.AutoHashMapUnmanaged(u32, Ref) = .empty;
        for (0..n_blocks) |bi| {
            if (!set[bi] or bi == check) continue;
            for (f.blocks.items[bi].insts.items) |r| {
                try imap.put(a, r.index(), try addInst(a, f, f.inst(r)));
            }
        }
        const Map = struct {
            m: *const std.AutoHashMapUnmanaged(u32, Ref),
            fn map(c: @This(), x: Ref) Ref {
                if (x == .none) return x;
                return c.m.get(x.index()) orelse x;
            }
        };
        const mp = Map{ .m = &imap };
        for (0..n_blocks) |bi| {
            if (!set[bi] or bi == check) continue;
            const src = f.blocks.items[bi];
            const nb = bmap.get(@intCast(bi)).?;
            var insts: std.ArrayList(Ref) = .empty;
            for (src.insts.items, 0..) |r, pos| {
                const nr = imap.get(r.index()).?;
                const op = f.inst(r).op;
                if (op == .load and op.load == iv) {
                    // Loads after the step store see the next value.
                    const c = if (bi == cont and pos > step_pos) next orelse return false else val;
                    f.insts.items[nr.index()] = .{ .op = .{ .constant = normalize(iv_s, c) }, .ty = f.inst(r).ty };
                } else {
                    f.insts.items[nr.index()].op = try mapOp(a, op, mp);
                }
                try insts.append(a, nr);
            }
            const mapBlock = struct {
                fn g(bm: *const std.AutoHashMapUnmanaged(u32, u32), b: BlockId) BlockId {
                    return if (bm.get(b.index())) |x| @enumFromInt(x) else b;
                }
            }.g;
            var term = src.term;
            switch (term) {
                .ret => |x| term = .{ .ret = mp.map(x) },
                .br => |b| term = .{ .br = mapBlock(&bmap, b) },
                .cond_br => |c| term = .{ .cond_br = .{ .cond = mp.map(c.cond), .then = mapBlock(&bmap, c.then), .@"else" = mapBlock(&bmap, c.@"else") } },
                .@"switch" => |sw| {
                    const cases = try a.alloc(@typeInfo(@TypeOf(sw.cases)).pointer.child, sw.cases.len);
                    for (sw.cases, cases) |c, *o| o.* = .{ .value = c.value, .block = mapBlock(&bmap, c.block) };
                    term = .{ .@"switch" = .{ .value = mp.map(sw.value), .default = mapBlock(&bmap, sw.default), .cases = cases } };
                },
                else => {},
            }
            const mg: ir.Merge = switch (src.merge) {
                .none => .none,
                .selection => |b| .{ .selection = mapBlock(&bmap, b) },
                .loop => |l| .{ .loop = .{ .merge = mapBlock(&bmap, l.merge), .@"continue" = mapBlock(&bmap, l.@"continue"), .unroll = l.unroll } },
            };
            f.blocks.items[nb] = .{ .insts = insts, .term = term, .merge = mg, .selection_control = src.selection_control };
        }
        entries[iter] = bmap.get(body).?;
        conts[iter] = bmap.get(cont).?;
    }
    for (conts, 0..) |c, iter| {
        f.blocks.items[c].term = .{ .br = @enumFromInt(if (iter + 1 < entries.len) entries[iter + 1] else merge) };
    }
    f.blocks.items[pre].term = .{ .br = @enumFromInt(if (entries.len > 0) entries[0] else merge) };
    return true;
}

fn foldStep(t: *TypeTable, f: *ir.Function, step: Ref, iv: Ref, v: Constant) ?Constant {
    return eval(t, f, step, iv, v, 0);
}

test "constant folding helpers" {
    try std.testing.expectEqual(@as(i64, -2147483648), foldBinary(.int, .add, .{ .int = 2147483647 }, .{ .int = 1 }).?.int);
    try std.testing.expectEqual(@as(i64, 4294967295), foldBinary(.uint, .sub, .{ .int = 0 }, .{ .int = 1 }).?.int);
    try std.testing.expect(foldBinary(.int, .div, .{ .int = 1 }, .{ .int = 0 }) == null);
    try std.testing.expectEqual(@as(i64, 1), foldCmp(.uint, .gt, .{ .int = 4294967295 }, .{ .int = 1 }).?.int);
    try std.testing.expectEqual(@as(i64, 0), foldCmp(.int, .gt, .{ .int = -1 }, .{ .int = 1 }).?.int);
    try std.testing.expectEqual(@as(i64, 3), foldConvert(.float, .int, .{ .float = 3.7 }).int);
}

// ----------------------------------------------------------------------
// Block merging

/// Merges each block into its predecessor where the predecessor ends in
/// an unconditional branch to it and nothing else reaches it, as dxc's
/// optimizer does (merge-blocks). Inlining leaves a chain of such blocks
/// per call; Unreal runs spirv-opt -O on its SPIR-V, and SPIRV-Tools'
/// ssa-rewrite recurses once per block along a chain (a path tracing
/// library of 34,565 blocks overflowed its stack).
///
/// Left alone: merge and continue targets and loop headers (structured
/// control flow names them), blocks heading a construct as predecessor,
/// and blocks with phis. A merged block is left empty and unreachable;
/// the emitter skips it.
pub fn mergeBlocks(a: Allocator, f: *ir.Function) Allocator.Error!void {
    const n = f.blocks.items.len;
    if (n < 2) return;
    const live = try reachable(a, f);
    const preds = try a.alloc(u32, n);
    @memset(preds, 0);
    const pinned = try a.alloc(bool, n);
    @memset(pinned, false);
    pinned[0] = true;
    for (f.blocks.items, 0..) |b, i| {
        if (!live[i]) continue;
        for (try successors(a, b.term)) |s| preds[s.index()] += 1;
        switch (b.merge) {
            .none => {},
            .selection => |m| pinned[m.index()] = true,
            .loop => |l| {
                pinned[i] = true;
                pinned[l.merge.index()] = true;
                pinned[l.@"continue".index()] = true;
            },
        }
    }
    for (0..n) |bi| {
        if (!live[bi]) continue;
        // Absorb successors for as long as the chain goes on.
        while (true) {
            const b = &f.blocks.items[bi];
            if (b.merge != .none or b.term != .br) break;
            const ci = b.term.br.index();
            if (ci == bi or pinned[ci] or preds[ci] != 1) break;
            const c = &f.blocks.items[ci];
            const has_phi = for (c.insts.items) |r| {
                if (f.inst(r).op == .phi) break true;
            } else false;
            if (has_phi) break;
            try b.insts.appendSlice(a, c.insts.items);
            b.term = c.term;
            b.merge = c.merge;
            b.selection_control = c.selection_control;
            // Phis in the successors now come from `b`.
            for (try successors(a, c.term)) |s| {
                for (f.blocks.items[s.index()].insts.items) |r| {
                    const inst = &f.insts.items[r.index()];
                    if (inst.op != .phi) continue;
                    const ins = try a.dupe(@typeInfo(@TypeOf(inst.op.phi)).pointer.child, inst.op.phi);
                    for (ins) |*in| if (in.block.index() == ci) {
                        in.block = @enumFromInt(bi);
                    };
                    inst.op = .{ .phi = ins };
                }
            }
            c.insts = .empty;
            c.term = .@"unreachable";
            c.merge = .none;
            live[ci] = false;
        }
    }
}

// ----------------------------------------------------------------------
// Constant branches

/// A conditional branch on a constant goes to the side it takes (a
/// selection header so folded heads no construct; the side not taken loses
/// this block from its phis). As dxc's dead branch elimination: Unreal
/// passes constant flags to the functions it calls (Lumen's
/// `bRayTraceSkyLightContribution = false`), and the code under them reads
/// buffers its reflection must not see. Returns whether anything changed.
pub fn foldBranches(a: Allocator, f: *ir.Function) Allocator.Error!bool {
    var changed = false;
    for (f.blocks.items, 0..) |*b, bi| {
        if (b.term != .cond_br) continue;
        const c = b.term.cond_br;
        const ci = f.inst(c.cond);
        if (ci.op != .constant) continue;
        const take = switch (ci.op.constant) {
            .int => |v| v != 0,
            .float => |v| v != 0,
        };
        const taken = if (take) c.then else c.@"else";
        const untaken = if (take) c.@"else" else c.then;
        b.term = .{ .br = taken };
        if (b.merge == .selection) {
            b.merge = .none;
            b.selection_control = .none;
        }
        if (untaken != taken) {
            for (f.blocks.items[untaken.index()].insts.items) |r| {
                const inst = &f.insts.items[r.index()];
                if (inst.op != .phi) continue;
                var ins: std.ArrayList(@typeInfo(@TypeOf(inst.op.phi)).pointer.child) = .empty;
                for (inst.op.phi) |in| if (in.block.index() != bi) try ins.append(a, in);
                inst.op = .{ .phi = ins.items };
            }
        }
        changed = true;
    }
    if (changed) try fixPhis(a, f);
    return changed;
}

/// Phis after branch folding: one entry per predecessor the emitter still
/// writes out (reachable blocks, and the merge and continue targets of the
/// constructs they head), `undef` from those not reachable.
fn fixPhis(a: Allocator, f: *ir.Function) Allocator.Error!void {
    const n = f.blocks.items.len;
    const live = try reachable(a, f);
    const emitted = try a.dupe(bool, live);
    var grew = true;
    while (grew) {
        grew = false;
        for (f.blocks.items, 0..) |b, i| {
            if (!emitted[i]) continue;
            const targets: [2]BlockId = switch (b.merge) {
                .none => .{ .none, .none },
                .selection => |mb| .{ mb, .none },
                .loop => |l| .{ l.merge, l.@"continue" },
            };
            for (targets) |t| if (t != .none and !emitted[t.index()]) {
                emitted[t.index()] = true;
                grew = true;
            };
        }
    }
    // Where each instruction is defined.
    const def_block = try a.alloc(u32, f.insts.items.len);
    @memset(def_block, std.math.maxInt(u32));
    for (f.blocks.items, 0..) |b, i| for (b.insts.items) |r| {
        def_block[r.index()] = @intCast(i);
    };
    for (f.blocks.items, 0..) |b, si| {
        if (!emitted[si]) continue;
        for (b.insts.items) |r| {
            const inst = f.insts.items[r.index()];
            if (inst.op != .phi) continue;
            var ins: std.ArrayList(@typeInfo(@TypeOf(inst.op.phi)).pointer.child) = .empty;
            for (inst.op.phi) |in| {
                const pb = in.block.index();
                if (!emitted[pb]) continue;
                const goes_here = for (try successors(a, f.blocks.items[pb].term)) |t| {
                    if (t.index() == si) break true;
                } else false;
                if (!goes_here) continue;
                const db = def_block[in.value.index()];
                const dead = !live[pb] or (db != std.math.maxInt(u32) and !live[db]);
                const v = if (dead) try addInst(a, f, .{ .op = .undef, .ty = inst.ty }) else in.value;
                try ins.append(a, .{ .value = v, .block = in.block });
            }
            f.insts.items[r.index()].op = .{ .phi = ins.items };
        }
    }
    _ = n;
}
