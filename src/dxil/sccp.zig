//! Sparse conditional constant propagation (Wegman and Zadeck) on a DXIL
//! function in SSA form, over integer values: optimistic, so values carried
//! round a loop that only ever hold one constant are found, and code only
//! reachable through branches that never go that way is left out. (A flag
//! that starts false and is passed back unchanged through a loop, or a loop
//! whose first test already fails, as dxc's optimizer finds them.)
//!
//! The results go into the function as constants: the uses of values found
//! constant, and the conditions of branches found to go one way; promotion
//! then drops what that leaves dead or unreachable.

const std = @import("std");
const Allocator = std.mem.Allocator;
const module = @import("module.zig");
const unroll = @import("unroll.zig");

const Value = module.Value;
const Inst = module.Inst;

const none = std.math.maxInt(u32);

/// Not yet known (optimistically anything), one constant, or varying.
const Lat = union(enum) {
    top,
    k: i64,
    bot,

    fn meet(x: Lat, y: Lat) Lat {
        return switch (x) {
            .top => y,
            .bot => .bot,
            .k => |a| switch (y) {
                .top => x,
                .bot => .bot,
                .k => |b| if (a == b) x else .bot,
            },
        };
    }

    fn eql(x: Lat, y: Lat) bool {
        return std.meta.eql(x, y);
    }
};

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

fn successors(term: Inst) Succs {
    return switch (term.op) {
        .br => |br| if (br.@"else") |e| .{ .br = .{ br.then, e }, .len = 2 } else .{ .br = .{ br.then, 0 }, .len = 1 },
        .@"switch" => |sw| .{ .sw = sw, .len = 1 + sw.cases.len },
        else => .{},
    };
}

/// Runs the propagation on `func`; true if it changed anything.
pub fn run(a: Allocator, m: *module.Module, func: u32) Allocator.Error!bool {
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
                    const x = bitsOf(l.k, w);
                    const y = bitsOf(r.k, w);
                    const sx = stored(x, w);
                    const sy = stored(y, w);
                    const p: u64 = switch (b.op) {
                        .add => x +% y,
                        .sub => x -% y,
                        .mul => x *% y,
                        .@"and" => x & y,
                        .@"or" => x | y,
                        .xor => x ^ y,
                        .shl => if (y < w) x << @intCast(y) else return .bot,
                        .lshr => if (y < w) x >> @intCast(y) else return .bot,
                        .ashr => if (y < w) @bitCast(sx >> @intCast(y)) else return .bot,
                        .udiv => if (y != 0) x / y else return .bot,
                        .urem => if (y != 0) x % y else return .bot,
                        .sdiv => if (sy != 0 and !(sy == -1 and sx == std.math.minInt(i64))) @bitCast(@divTrunc(sx, sy)) else return .bot,
                        .srem => if (sy != 0 and sy != -1) @bitCast(@rem(sx, sy)) else return .bot,
                    };
                    return .{ .k = stored(bitsOf(@bitCast(p), w), w) };
                },
                .cast => |c| {
                    if (c.op != .zext and c.op != .sext and c.op != .trunc) return .bot;
                    const from = intWidth(s.m, typeOf(s.m, s.f, c.val) orelse return .bot) orelse return .bot;
                    const v = s.of(c.val);
                    if (v != .k) return v;
                    const x = bitsOf(v.k, from);
                    const out: u64 = switch (c.op) {
                        .sext => if (from == 1) (if (x & 1 != 0) ~@as(u64, 0) else 0) else @bitCast(stored(x, from)),
                        else => x,
                    };
                    return .{ .k = stored(bitsOf(@bitCast(out), w), w) };
                },
                .cmp => |c| {
                    if (c.pred < 32 or c.pred > 41) return .bot;
                    const cw = intWidth(s.m, typeOf(s.m, s.f, c.lhs) orelse return .bot) orelse return .bot;
                    const l = s.of(c.lhs);
                    const r = s.of(c.rhs);
                    if (l == .bot or r == .bot) return .bot;
                    if (l == .top or r == .top) return .top;
                    const x = bitsOf(l.k, cw);
                    const y = bitsOf(r.k, cw);
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
                    return .{ .k = @intFromBool(t) };
                },
                .select => |sel| {
                    const c = s.of(sel.cond);
                    return switch (c) {
                        .top => .top,
                        .k => |x| s.of(if (x & 1 != 0) sel.t else sel.f),
                        .bot => s.of(sel.t).meet(s.of(sel.f)),
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
                            .bot => .{ br.then, br.@"else" },
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
                        var taken: ?u32 = null;
                        if (c == .k) {
                            taken = sw.default;
                            for (sw.cases) |cs| if (ev.of(cs.val) == .k and ev.of(cs.val).k == c.k) {
                                taken = cs.block;
                            };
                        }
                        var list: std.ArrayList(u32) = .empty;
                        if (taken) |t| try list.append(a, t) else {
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
    for (insts) |*inst| try unroll.operandsMap(ma, inst, &mapper);
    return any;
}
