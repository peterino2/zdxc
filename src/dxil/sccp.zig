//! Sparse conditional constant propagation (Wegman and Zadeck) on a DXIL
//! function in SSA form, over integer values: optimistic, so values carried
//! round a loop that only ever hold one constant are found, and code only
//! reachable through branches that never go that way is left out. (A flag
//! that starts false and is passed back unchanged through a loop, or a loop
//! whose first test already fails, as dxc's optimizer finds them.)
//!
//! A value may also be found to be one of a few constants (a flag picked
//! by `c ? 1 : 0`, or a phi of such): arithmetic, casts and compares work
//! on each, a compare every one of them decides is a constant, and a
//! switch goes only to the cases they can take. (Unreal's MegaLights sets
//! a shading model `ID = valid ? 1 : 0` and switches on it over every
//! shading model's BRDF; dxc keeps only the first.)
//!
//! The results go into the function as constants: the uses of values found
//! constant, the conditions of branches found to go one way, and the cases
//! a switch cannot take; promotion then drops what that leaves dead or
//! unreachable.

const std = @import("std");
const Allocator = std.mem.Allocator;
const module = @import("module.zig");
const stats = @import("../stats.zig");
const unroll = @import("unroll.zig");

const Value = module.Value;
const Inst = module.Inst;

const none = std.math.maxInt(u32);

/// The most constants a value is followed as being one of.
const max_set = 8;

/// A few distinct constants, in order (the rest of `v` zero).
const Vals = struct {
    len: u8 = 0,
    v: [max_set]i64 = @splat(0),

    fn slice(s: *const Vals) []const i64 {
        return s.v[0..s.len];
    }

    /// Adds `x`; false if that makes too many.
    fn add(s: *Vals, x: i64) bool {
        var k: usize = 0;
        while (k < s.len and s.v[k] < x) : (k += 1) {}
        if (k < s.len and s.v[k] == x) return true;
        if (s.len == max_set) return false;
        var j: usize = s.len;
        while (j > k) : (j -= 1) s.v[j] = s.v[j - 1];
        s.v[k] = x;
        s.len += 1;
        return true;
    }

    fn lat(s: Vals) Lat {
        return switch (s.len) {
            0 => .top,
            1 => .{ .k = s.v[0] },
            else => .{ .set = s },
        };
    }
};

/// Not yet known (optimistically anything), one constant, one of a few,
/// or varying.
const Lat = union(enum) {
    top,
    k: i64,
    set: Vals,
    bot,

    /// The constants it may be (for `k` and `set`).
    fn vals(x: Lat) ?Vals {
        return switch (x) {
            .k => |a| blk: {
                var s: Vals = .{};
                _ = s.add(a);
                break :blk s;
            },
            .set => |s| s,
            else => null,
        };
    }

    fn known(x: Lat) bool {
        return x == .k or x == .set;
    }

    fn meet(x: Lat, y: Lat) Lat {
        if (x == .top) return y;
        if (y == .top) return x;
        var s = x.vals() orelse return .bot;
        const t = y.vals() orelse return .bot;
        for (t.slice()) |b| if (!s.add(b)) return .bot;
        return s.lat();
    }

    fn eql(x: Lat, y: Lat) bool {
        return std.meta.eql(x, y);
    }
};

/// `f` of each pair of constants `l` and `r` may be: null if `f` cannot
/// say for one, or that gives too many.
fn lift2(l: Lat, r: Lat, ctx: anytype, comptime f: fn (@TypeOf(ctx), i64, i64) ?i64) Lat {
    const ls = l.vals().?;
    const rs = r.vals().?;
    var out: Vals = .{};
    for (ls.slice()) |x| for (rs.slice()) |y| {
        const z = f(ctx, x, y) orelse return .bot;
        if (!out.add(z)) return .bot;
    };
    return out.lat();
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

fn typeOf(m: *const module.Module, f: *const module.Function, v: Value) ?module.TypeId {
    return switch (v) {
        .inst => |i| f.insts.items[i].ty,
        .constant => |c| m.constants.items[c].ty,
        .arg => |k| m.types.items[f.ty].function.params[k],
        else => null,
    };
}

fn isTerminator(inst: Inst) bool {
    return switch (inst.op) {
        .ret, .br, .@"switch", .@"unreachable" => true,
        else => false,
    };
}

/// A terminator's successor blocks.
const Succs = struct {
    br: [2]u32 = undefined,
    sw: ?@FieldType(@FieldType(Inst, "op"), "switch") = null,
    len: usize = 0,

    fn get(s: Succs, k: usize) u32 {
        if (s.sw) |sw| return if (k == 0) sw.default else sw.cases[k - 1].block;
        return s.br[k];
    }
};

const Switch = @FieldType(@FieldType(Inst, "op"), "switch");
const Case = @typeInfo(@FieldType(Switch, "cases")).pointer.child;

/// The block a switch goes to for the value `x`.
fn caseTarget(ev: anytype, sw: Switch, x: i64) u32 {
    for (sw.cases) |cs| {
        const v = ev.of(cs.val);
        if (v == .k and v.k == x) return cs.block;
    }
    return sw.default;
}

fn successors(term: Inst) Succs {
    return switch (term.op) {
        .br => |br| if (br.@"else") |e| .{ .br = .{ br.then, e }, .len = 2 } else .{ .br = .{ br.then, 0 }, .len = 1 },
        .@"switch" => |sw| .{ .sw = sw, .len = 1 + sw.cases.len },
        else => .{},
    };
}

/// Runs the propagation on `func`; true if it changed anything.
pub fn run(a: Allocator, m: *module.Module, func: u32) Allocator.Error!bool {
    const zone = stats.begin(.sccp);
    defer zone.end();
    const f = &m.functions.items[func];
    const insts = f.insts.items;
    const n: u32 = @intCast(insts.len);
    const nb = f.num_blocks;
    if (n == 0 or nb == 0) return false;

    const block_start = try a.alloc(u32, nb + 1);
    const block_of = try a.alloc(u32, n);
    {
        var b: u32 = 0;
        block_start[0] = 0;
        for (insts, 0..) |inst, i| {
            if (b >= nb) return false;
            block_of[i] = b;
            if (isTerminator(inst)) {
                b += 1;
                block_start[b] = @intCast(i + 1);
            }
        }
        if (b != nb) return false;
    }

    const lat = try a.alloc(Lat, n);
    @memset(lat, .top);
    const exec = try a.alloc(bool, nb);
    @memset(exec, false);
    exec[0] = true;
    var edges: std.AutoHashMapUnmanaged(u64, void) = .empty;
    const S = struct {
        fn key(from: u32, to: u32) u64 {
            return @as(u64, from) << 32 | to;
        }
    };

    const Eval = struct {
        m: *const module.Module,
        f: *const module.Function,
        lat: []const Lat,

        fn of(s: @This(), v: Value) Lat {
            return switch (v) {
                .inst => |i| s.lat[i],
                .constant => |c| switch (s.m.constants.items[c].kind) {
                    .int => |x| .{ .k = x },
                    else => .bot,
                },
                else => .bot,
            };
        }

        const Bin = struct { op: @FieldType(@FieldType(@FieldType(Inst, "op"), "binop"), "op"), w: u32 };

        fn bin(b: Bin, lk: i64, rk: i64) ?i64 {
            const w = b.w;
            const x = bitsOf(lk, w);
            const y = bitsOf(rk, w);
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
        }

        const Cmp = struct { pred: u32, w: u32 };

        fn cmp(c: Cmp, lk: i64, rk: i64) ?i64 {
            const x = bitsOf(lk, c.w);
            const y = bitsOf(rk, c.w);
            const sx = stored(x, c.w);
            const sy = stored(y, c.w);
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
        }

        fn inst(s: @This(), i: u32) Lat {
            const in = s.f.insts.items[i];
            const w = intWidth(s.m, in.ty) orelse return .bot;
            switch (in.op) {
                .binop => |b| {
                    const l = s.of(b.lhs);
                    const r = s.of(b.rhs);
                    if (l == .bot or r == .bot) {
                        // (Varying, but a zero still decides these.)
                        const z = if (l == .k and l.k == 0) true else if (r == .k and r.k == 0) true else false;
                        if (z and (b.op == .@"and" or b.op == .mul)) return .{ .k = 0 };
                        return .bot;
                    }
                    if (l == .top or r == .top) return .top;
                    return lift2(l, r, Bin{ .op = b.op, .w = w }, bin);
                },
                .cast => |c| {
                    if (c.op != .zext and c.op != .sext and c.op != .trunc) return .bot;
                    const from = intWidth(s.m, typeOf(s.m, s.f, c.val) orelse return .bot) orelse return .bot;
                    const v = s.of(c.val);
                    const vs = v.vals() orelse return v;
                    var out: Vals = .{};
                    for (vs.slice()) |k| {
                        const x = bitsOf(k, from);
                        const o: u64 = switch (c.op) {
                            .sext => if (from == 1) (if (x & 1 != 0) ~@as(u64, 0) else 0) else @bitCast(stored(x, from)),
                            else => x,
                        };
                        if (!out.add(stored(bitsOf(@bitCast(o), w), w))) return .bot;
                    }
                    return out.lat();
                },
                .cmp => |c| {
                    if (c.pred < 32 or c.pred > 41) return .bot;
                    const cw = intWidth(s.m, typeOf(s.m, s.f, c.lhs) orelse return .bot) orelse return .bot;
                    const l = s.of(c.lhs);
                    const r = s.of(c.rhs);
                    if (l == .bot or r == .bot) return .bot;
                    if (l == .top or r == .top) return .top;
                    return lift2(l, r, Cmp{ .pred = c.pred, .w = cw }, cmp);
                },
                .select => |sel| {
                    const c = s.of(sel.cond);
                    return switch (c) {
                        .top => .top,
                        .k => |x| s.of(if (x & 1 != 0) sel.t else sel.f),
                        .set, .bot => s.of(sel.t).meet(s.of(sel.f)),
                    };
                },
                else => return .bot,
            }
        }
    };
    const ev: Eval = .{ .m = m, .f = f, .lat = lat };

    // Blocks in reverse postorder: definitions before uses except round
    // loops, so the fixed point takes a few passes (the lattice is three
    // levels deep).
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
            const succs = successors(insts[block_start[top.b + 1] - 1]);
            if (top.next < succs.len) {
                const t = succs.get(top.next);
                top.next += 1;
                if (!seen[t]) {
                    seen[t] = true;
                    try stack.append(a, .{ .b = t, .next = 0 });
                }
            } else {
                try post.append(a, top.b);
                _ = stack.pop();
            }
        }
        var k = post.items.len;
        while (k > 0) {
            k -= 1;
            try rpo.append(a, post.items[k]);
        }
    }
    var changed = true;
    var rounds: u32 = 0;
    while (changed) : (rounds += 1) {
        if (rounds > 1000) return false;
        changed = false;
        for (rpo.items) |b| {
            if (!exec[b]) continue;
            for (block_start[b]..block_start[b + 1]) |ii| {
                const i: u32 = @intCast(ii);
                const inst = insts[i];
                var new: Lat = undefined;
                switch (inst.op) {
                    .phi => |p| {
                        if (intWidth(m, inst.ty) == null) {
                            new = .bot;
                        } else {
                            new = .top;
                            for (p.incoming) |in| {
                                if (!edges.contains(S.key(in.block, b))) continue;
                                new = new.meet(ev.of(in.val));
                            }
                        }
                    },
                    .br => |br| {
                        const targets: [2]?u32 = if (br.cond) |c| switch (ev.of(c)) {
                            .top => .{ null, null },
                            .k => |x| .{ if (x & 1 != 0) br.then else br.@"else", null },
                            .set, .bot => .{ br.then, br.@"else" },
                        } else .{ br.then, null };
                        for (targets) |t| if (t) |tb| {
                            const gop = try edges.getOrPut(a, S.key(b, tb));
                            if (!gop.found_existing) {
                                exec[tb] = true;
                                changed = true;
                            }
                        };
                        continue;
                    },
                    .@"switch" => |sw| {
                        const c = ev.of(sw.cond);
                        if (c == .top) continue;
                        var list: std.ArrayList(u32) = .empty;
                        if (c.vals()) |vs| {
                            // Where each value it may be goes.
                            for (vs.slice()) |x| try list.append(a, caseTarget(ev, sw, x));
                        } else {
                            try list.append(a, sw.default);
                            for (sw.cases) |cs| try list.append(a, cs.block);
                        }
                        for (list.items) |tb| {
                            const gop = try edges.getOrPut(a, S.key(b, tb));
                            if (!gop.found_existing) {
                                exec[tb] = true;
                                changed = true;
                            }
                        }
                        continue;
                    },
                    else => new = ev.inst(i),
                }
                const merged = lat[i].meet(new);
                if (!merged.eql(lat[i])) {
                    lat[i] = merged;
                    changed = true;
                }
            }
        }
    }

    // Constants into the function: the uses of integer values found
    // constant, and branch conditions.
    const repl = try a.alloc(?Value, n);
    @memset(repl, null);
    var any = false;
    for (insts, 0..) |inst, i| {
        if (!exec[block_of[i]]) continue;
        if (lat[i] != .k) continue;
        if (intWidth(m, inst.ty) == null) continue;
        repl[i] = try m.constant(.{ .ty = inst.ty, .kind = .{ .int = lat[i].k } });
    }
    const Mapper = struct {
        repl: []const ?Value,
        any: *bool,
        pub fn visit(c: *@This(), v: Value, _: anytype) Value {
            if (v == .inst and v.inst < c.repl.len) if (c.repl[v.inst]) |r| {
                c.any.* = true;
                return r;
            };
            return v;
        }
    };
    var mapper: Mapper = .{ .repl = repl, .any = &any };
    const ma = m.allocator();

    // Switches on one of a few constants: the cases none of them takes
    // dropped, or a branch where they all go one way. (Only edges go:
    // promotion drops the phis' inputs from them, and what no path
    // reaches any more.)
    for (insts, 0..) |*inst, i| {
        if (inst.op != .@"switch" or !exec[block_of[i]]) continue;
        const sw = inst.op.@"switch";
        const c = ev.of(sw.cond);
        if (c != .set) continue;
        const vs = c.set;
        const first = caseTarget(ev, sw, vs.v[0]);
        var one_way = true;
        for (vs.slice()[1..]) |x| {
            if (caseTarget(ev, sw, x) != first) one_way = false;
        }
        if (one_way) {
            inst.op = .{ .br = .{ .then = first } };
            any = true;
            continue;
        }
        var keep: std.ArrayList(Case) = .empty;
        for (sw.cases) |cs| {
            const v = ev.of(cs.val);
            if (v == .k and std.mem.indexOfScalar(i64, vs.slice(), v.k) != null) try keep.append(ma, cs);
        }
        if (keep.items.len == sw.cases.len) continue;
        inst.op.@"switch".cases = keep.items;
        any = true;
    }

    for (insts) |*inst| try unroll.operandsMap(ma, inst, &mapper);
    return any;
}

/// A function `i32 f(i32 %a)` for the tests: block 0 computes
/// `%c = %a != 0` and `%s = select %c, k1, k2`, and goes to block 1 if %c,
/// else to block 2; block 1 goes to block 2; block 2 starts with
/// `%p = phi [k0, 0], [%s, 1]` and ends with `tail` (then `ret %a` for
/// each further block it may go to).
const TestFn = struct {
    m: module.Module,
    func: u32,
    i32_ty: module.TypeId,

    fn init(gpa: Allocator, k: [3]i64, extra_blocks: u32) !TestFn {
        var t: TestFn = .{ .m = .init(gpa), .func = 0, .i32_ty = 0 };
        const m = &t.m;
        const i32_ty = try m.intType(32);
        t.i32_ty = i32_ty;
        const i1_ty = try m.intType(1);
        const void_ty = try m.getType(.void);
        t.func = try m.addFunction(.{ .name = "f", .ty = try m.fnType(i32_ty, &.{i32_ty}), .num_blocks = 3 + extra_blocks });
        const a: Value = .{ .arg = 0 };
        const c = try m.addInst(t.func, .{ .ty = i1_ty, .op = .{ .cmp = .{ .pred = 33, .lhs = a, .rhs = try m.constInt(32, 0) } } });
        const s = try m.addInst(t.func, .{ .ty = i32_ty, .op = .{ .select = .{ .cond = c, .t = try m.constInt(32, k[1]), .f = try m.constInt(32, k[2]) } } });
        _ = try m.addInst(t.func, .{ .ty = void_ty, .op = .{ .br = .{ .then = 1, .@"else" = 2, .cond = c } } });
        _ = try m.addInst(t.func, .{ .ty = void_ty, .op = .{ .br = .{ .then = 2 } } });
        const ins = try m.allocator().dupe(@typeInfo(@FieldType(@FieldType(@FieldType(Inst, "op"), "phi"), "incoming")).pointer.child, &.{
            .{ .val = try m.constInt(32, k[0]), .block = 0 },
            .{ .val = s, .block = 1 },
        });
        _ = try m.addInst(t.func, .{ .ty = i32_ty, .op = .{ .phi = .{ .incoming = ins } } });
        return t;
    }

    /// `%p`, the phi starting block 2.
    const p: Value = .{ .inst = 4 };

    fn add(t: *TestFn, inst: Inst) !Value {
        return t.m.addInst(t.func, inst);
    }

    fn finish(t: *TestFn, extra_blocks: u32) !void {
        const void_ty = try t.m.getType(.void);
        for (0..extra_blocks) |_| _ = try t.add(.{ .ty = void_ty, .op = .{ .ret = .{ .arg = 0 } } });
    }

    fn term(t: *TestFn, b: usize) Inst {
        var seen: usize = 0;
        for (t.m.functions.items[t.func].insts.items) |inst| if (isTerminator(inst)) {
            if (seen == b) return inst;
            seen += 1;
        };
        unreachable;
    }

    fn cases(m: *module.Module, ks: []const [2]i64) ![]const Case {
        const out = try m.allocator().alloc(Case, ks.len);
        for (ks, out) |kb, *o| o.* = .{ .val = try m.constInt(32, kb[0]), .block = @intCast(kb[1]) };
        return out;
    }
};

test "a switch on one of a few constants keeps only the cases they take" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // %p is 0 or 1: of `switch %p [1, 2, 5]` only case 1 and default can run.
    var t = try TestFn.init(std.testing.allocator, .{ 0, 1, 0 }, 4);
    defer t.m.deinit();
    const void_ty = try t.m.getType(.void);
    _ = try t.add(.{ .ty = void_ty, .op = .{ .@"switch" = .{ .cond = TestFn.p, .default = 3, .cases = try TestFn.cases(&t.m, &.{ .{ 1, 4 }, .{ 2, 5 }, .{ 5, 6 } }) } } });
    try t.finish(4);
    try std.testing.expect(try run(arena.allocator(), &t.m, t.func));
    const sw = t.term(2).op.@"switch";
    try std.testing.expectEqual(@as(u32, 3), sw.default);
    try std.testing.expectEqual(@as(usize, 1), sw.cases.len);
    try std.testing.expectEqual(@as(u32, 4), sw.cases[0].block);
}

test "a switch every value it may be takes one way is a branch there" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // %p is 2 or 3, both case 3's block.
    var t = try TestFn.init(std.testing.allocator, .{ 2, 3, 3 }, 3);
    defer t.m.deinit();
    const void_ty = try t.m.getType(.void);
    _ = try t.add(.{ .ty = void_ty, .op = .{ .@"switch" = .{ .cond = TestFn.p, .default = 5, .cases = try TestFn.cases(&t.m, &.{ .{ 2, 3 }, .{ 3, 3 }, .{ 4, 4 } }) } } });
    try t.finish(3);
    try std.testing.expect(try run(arena.allocator(), &t.m, t.func));
    const br = t.term(2).op.br;
    try std.testing.expectEqual(@as(u32, 3), br.then);
    try std.testing.expectEqual(@as(?u32, null), br.@"else");
}

test "a compare every value decides is a constant" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // %p is 0 or 1 (through `* 4 + 1`: 1 or 5); `== 2` is never true and
    // `u< 6` always.
    var t = try TestFn.init(std.testing.allocator, .{ 0, 1, 0 }, 2);
    defer t.m.deinit();
    const void_ty = try t.m.getType(.void);
    const i1_ty = try t.m.intType(1);
    const mul = try t.add(.{ .ty = t.i32_ty, .op = .{ .binop = .{ .op = .mul, .lhs = TestFn.p, .rhs = try t.m.constInt(32, 4) } } });
    const q = try t.add(.{ .ty = t.i32_ty, .op = .{ .binop = .{ .op = .add, .lhs = mul, .rhs = try t.m.constInt(32, 1) } } });
    const eq = try t.add(.{ .ty = i1_ty, .op = .{ .cmp = .{ .pred = 32, .lhs = q, .rhs = try t.m.constInt(32, 2) } } });
    const lt = try t.add(.{ .ty = i1_ty, .op = .{ .cmp = .{ .pred = 36, .lhs = q, .rhs = try t.m.constInt(32, 6) } } });
    const both = try t.add(.{ .ty = i1_ty, .op = .{ .binop = .{ .op = .@"or", .lhs = eq, .rhs = lt } } });
    _ = try t.add(.{ .ty = void_ty, .op = .{ .br = .{ .then = 3, .@"else" = 4, .cond = both } } });
    try t.finish(2);
    try std.testing.expect(try run(arena.allocator(), &t.m, t.func));
    const br = t.term(2).op.br;
    const cond = br.cond.?;
    try std.testing.expect(cond == .constant);
    try std.testing.expectEqual(@as(i64, 1), t.m.constants.items[cond.constant].kind.int);
}

test "more constants than are followed are varying" {
    var x: Lat = .top;
    for (0..max_set) |k| x = x.meet(.{ .k = @intCast(k * 3) });
    try std.testing.expect(x == .set);
    try std.testing.expectEqual(@as(u8, max_set), x.set.len);
    try std.testing.expect(x.meet(.{ .k = 1 }) == .bot);
    try std.testing.expect(x.meet(.{ .k = 3 }).eql(x));
}
