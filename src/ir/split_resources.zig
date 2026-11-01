//! Resources inside structs, taken apart for SPIR-V (dxc gets there by
//! legalization: inlining and scalar replacement). After this pass no
//! struct value or local carries a resource: each resource member of a
//! local is a resource local of its own, each struct value has its
//! resources alongside, function parameters holding resources gain a
//! resource parameter per member, and functions returning resources
//! return the parameter or global they come from. The SPIR-V emitter
//! leaves resource members out of struct types.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("ir.zig");
const types = @import("../sema/types.zig");
const opt = @import("opt.zig");
const diag = @import("../diag.zig");

const Ref = ir.Ref;
const TypeId = types.TypeId;
const TypeTable = types.TypeTable;

pub const Error = Allocator.Error || error{Unsupported};

fn isOpaque(t: *const TypeTable, ty: TypeId) bool {
    return switch (t.get(ty)) {
        .resource => |r| !std.mem.eql(u8, r.name, "RayQuery"),
        .sampler => true,
        .array => |a| isOpaque(t, a.elem),
        else => false,
    };
}

/// A struct (or array of structs) with a resource in it.
pub fn holdsResources(t: *const TypeTable, ty: TypeId) bool {
    return switch (t.get(ty)) {
        .array => |a| holdsResources(t, a.elem),
        .@"struct" => |st| for (st.fields.items) |f| {
            if (isOpaque(t, f.type) or holdsResources(t, f.type)) break true;
        } else false,
        else => false,
    };
}

/// The resource members (resources, or arrays of them) of `ty`, in order.
fn leafTypes(a: Allocator, t: *const TypeTable, ty: TypeId, out: *std.ArrayList(TypeId)) Allocator.Error!void {
    if (isOpaque(t, ty)) return out.append(a, ty);
    switch (t.get(ty)) {
        .array => |arr| for (0..arr.len) |_| try leafTypes(a, t, arr.elem, out),
        .@"struct" => |st| for (st.fields.items) |f| try leafTypes(a, t, f.type, out),
        else => {},
    }
}

fn leafCount(t: *const TypeTable, ty: TypeId) u32 {
    if (isOpaque(t, ty)) return 1;
    return switch (t.get(ty)) {
        .array => |arr| arr.len * leafCount(t, arr.elem),
        .@"struct" => |st| blk: {
            var n: u32 = 0;
            for (st.fields.items) |f| n += leafCount(t, f.type);
            break :blk n;
        },
        else => 0,
    };
}

/// Member / element `k`'s place among `ty`'s leaves, and its type.
fn member(t: *const TypeTable, ty: TypeId, k: u32) struct { start: u32, ty: TypeId } {
    switch (t.get(ty)) {
        .array => |arr| return .{ .start = k * leafCount(t, arr.elem), .ty = arr.elem },
        .@"struct" => |st| {
            var s: u32 = 0;
            for (st.fields.items[0..k]) |f| s += leafCount(t, f.type);
            return .{ .start = s, .ty = st.fields.items[k].type };
        },
        else => return .{ .start = 0, .ty = ty },
    }
}

/// Where a returned resource comes from.
const Source = union(enum) { param: u32, global: u32 };

const FuncInfo = struct {
    done: bool = false,
    /// Original parameter index -> index of its first leaf parameter.
    leaf_params: []?u32 = &.{},
    /// The returned resources' origins (functions returning resources).
    ret: ?[]const Source = null,
    /// The function returned only resources and now returns nothing.
    ret_void: bool = false,
};

const Pass = struct {
    a: Allocator,
    m: *ir.Module,
    t: *TypeTable,
    diags: *diag.Diagnostics,
    infos: []FuncInfo,

    fn fail(p: *Pass, comptime fmt: []const u8, args: anytype) Error {
        p.diags.err(.none, "SPIR-V code generation: " ++ fmt ++ " is not supported yet", args);
        return error.Unsupported;
    }

    /// Adds a leaf parameter per resource member of each parameter that
    /// holds resources (by value or by reference).
    fn signature(p: *Pass, fi: u32) Allocator.Error!void {
        const f = p.m.functions.items[fi];
        const info = &p.infos[fi];
        info.leaf_params = try p.a.alloc(?u32, f.params.len);
        @memset(info.leaf_params, null);
        var params: std.ArrayList(ir.Param) = .empty;
        try params.appendSlice(p.a, f.params);
        for (f.params, 0..) |prm, k| {
            if (!holdsResources(p.t, prm.ty)) continue;
            info.leaf_params[k] = @intCast(params.items.len);
            var leaves: std.ArrayList(TypeId) = .empty;
            try leafTypes(p.a, p.t, prm.ty, &leaves);
            for (leaves.items, 0..) |lt, n| try params.append(p.a, .{ .name = try std.fmt.allocPrint(p.a, "{s}.{d}", .{ prm.name, n }), .ty = lt, .by_ref = false, .sema_ty = lt });
        }
        f.params = params.items;
    }

    fn add(f: *ir.Function, a: Allocator, inst: ir.Inst) Allocator.Error!Ref {
        try f.insts.append(a, inst);
        return @enumFromInt(f.insts.items.len - 1);
    }

    fn function(p: *Pass, fi: u32) Error!void {
        const info = &p.infos[fi];
        if (info.done) return;
        info.done = true;
        const f = p.m.functions.items[fi];
        // Callees first: their returns may be resources.
        for (f.insts.items) |inst| if (inst.op == .call) try p.function(inst.op.call.func);

        var leaves: std.AutoHashMapUnmanaged(Ref, []const Ref) = .empty;
        var pleaves: std.AutoHashMapUnmanaged(Ref, []const Ref) = .empty;
        var repl: std.AutoHashMapUnmanaged(Ref, Ref) = .empty;
        const Map = struct {
            r: *std.AutoHashMapUnmanaged(Ref, Ref),
            pub fn map(c: @This(), x: Ref) Ref {
                return c.r.get(x) orelse x;
            }
        };
        const mp: Map = .{ .r = &repl };
        var rets: std.ArrayList([]const Ref) = .empty;
        const n_old = f.insts.items.len;
        const ret_holds = holdsResources(p.t, f.ret) or isOpaque(p.t, f.ret);

        for (f.blocks.items, 0..) |*blk, bi| {
            var out: std.ArrayList(Ref) = .empty;
            for (blk.insts.items) |r| {
                const old = f.insts.items[r.index()];
                const op = try opt.mapOp(p.a, old.op, mp);
                f.insts.items[r.index()].op = op;
                const ty = old.ty;
                switch (op) {
                    .param => |pi| if (pi < info.leaf_params.len) if (info.leaf_params[pi]) |first| {
                        try out.append(p.a, r);
                        var lts: std.ArrayList(TypeId) = .empty;
                        try leafTypes(p.a, p.t, ty, &lts);
                        const vals = try p.a.alloc(Ref, lts.items.len);
                        for (vals, lts.items, 0..) |*v, lt, n| {
                            v.* = try add(f, p.a, .{ .op = .{ .param = first + @as(u32, @intCast(n)) }, .ty = lt });
                            try out.append(p.a, v.*);
                        }
                        if (old.ptr != .none) {
                            // By reference (`this`, inout): locals of its
                            // own, initialized from the leaf parameters.
                            const ptrs = try p.a.alloc(Ref, vals.len);
                            for (ptrs, vals, lts.items) |*pp, v, lt| {
                                pp.* = try add(f, p.a, .{ .op = .local_var, .ty = lt, .ptr = .function });
                                try out.append(p.a, pp.*);
                                try out.append(p.a, try add(f, p.a, .{ .op = .{ .store = .{ .ptr = pp.*, .value = v } }, .ty = TypeTable.void_type }));
                            }
                            try pleaves.put(p.a, r, ptrs);
                        } else try leaves.put(p.a, r, vals);
                        continue;
                    },
                    .local_var => if (holdsResources(p.t, ty)) {
                        try out.append(p.a, r);
                        var lts: std.ArrayList(TypeId) = .empty;
                        try leafTypes(p.a, p.t, ty, &lts);
                        const ptrs = try p.a.alloc(Ref, lts.items.len);
                        for (ptrs, lts.items) |*pp, lt| {
                            pp.* = try add(f, p.a, .{ .op = .local_var, .ty = lt, .ptr = .function });
                            try out.append(p.a, pp.*);
                        }
                        try pleaves.put(p.a, r, ptrs);
                        continue;
                    },
                    .access => |acc| if (pleaves.get(acc.base)) |base_leaves| {
                        var cur = f.insts.items[acc.base.index()].ty;
                        var start: u32 = 0;
                        for (acc.indices) |x| {
                            if (!holdsResources(p.t, cur)) break;
                            const xi = f.insts.items[x.index()];
                            if (xi.op != .constant) return p.fail("dynamically indexing an array of structs holding resources", .{});
                            const mb = member(p.t, cur, @intCast(xi.op.constant.int));
                            start += mb.start;
                            cur = mb.ty;
                        }
                        if (isOpaque(p.t, cur) and cur == ty) {
                            // A resource member: its own local.
                            try repl.put(p.a, r, base_leaves[start]);
                            continue;
                        }
                        try out.append(p.a, r);
                        if (holdsResources(p.t, ty)) try pleaves.put(p.a, r, base_leaves[start..][0..leafCount(p.t, ty)]);
                        continue;
                    },
                    .load => |ptr| if (pleaves.get(ptr)) |pl| {
                        try out.append(p.a, r);
                        const vals = try p.a.alloc(Ref, pl.len);
                        for (vals, pl) |*v, pp| {
                            v.* = try add(f, p.a, .{ .op = .{ .load = pp }, .ty = f.insts.items[pp.index()].ty });
                            try out.append(p.a, v.*);
                        }
                        try leaves.put(p.a, r, vals);
                        continue;
                    },
                    .store => |st| if (pleaves.get(st.ptr)) |pl| {
                        try out.append(p.a, r);
                        const vals = leaves.get(st.value) orelse return p.fail("storing this value holding resources", .{});
                        for (pl, vals) |pp, v| try out.append(p.a, try add(f, p.a, .{ .op = .{ .store = .{ .ptr = pp, .value = v } }, .ty = TypeTable.void_type }));
                        continue;
                    },
                    .construct => |parts| if (holdsResources(p.t, ty)) {
                        try out.append(p.a, r);
                        var vals: std.ArrayList(Ref) = .empty;
                        for (parts) |x| {
                            const xt = f.insts.items[x.index()].ty;
                            if (isOpaque(p.t, xt)) {
                                try vals.append(p.a, x);
                            } else if (holdsResources(p.t, xt)) {
                                try vals.appendSlice(p.a, leaves.get(x) orelse return p.fail("this value holding resources", .{}));
                            }
                        }
                        try leaves.put(p.a, r, vals.items);
                        continue;
                    },
                    .extract => |x| if (leaves.get(x.agg)) |vals| {
                        const mb = member(p.t, f.insts.items[x.agg.index()].ty, x.index);
                        if (isOpaque(p.t, ty)) {
                            try repl.put(p.a, r, vals[mb.start]);
                            continue;
                        }
                        try out.append(p.a, r);
                        if (holdsResources(p.t, ty)) try leaves.put(p.a, r, vals[mb.start..][0..leafCount(p.t, ty)]);
                        continue;
                    },
                    .insert => |x| if (holdsResources(p.t, ty)) {
                        try out.append(p.a, r);
                        const whole = leaves.get(x.agg) orelse return p.fail("this value holding resources", .{});
                        const vals = try p.a.dupe(Ref, whole);
                        const mb = member(p.t, ty, x.index);
                        const vt = f.insts.items[x.value.index()].ty;
                        if (isOpaque(p.t, vt)) {
                            vals[mb.start] = x.value;
                        } else if (holdsResources(p.t, vt)) {
                            const part = leaves.get(x.value) orelse return p.fail("this value holding resources", .{});
                            @memcpy(vals[mb.start..][0..part.len], part);
                        }
                        try leaves.put(p.a, r, vals);
                        continue;
                    },
                    .select => |x| if (holdsResources(p.t, ty) or isOpaque(p.t, ty)) {
                        _ = x;
                        return p.fail("selecting between values holding resources", .{});
                    },
                    .call => |c| {
                        const ci = &p.infos[c.func];
                        var args: std.ArrayList(Ref) = .empty;
                        try args.appendSlice(p.a, c.args);
                        for (c.args, 0..) |arg, k| {
                            if (k >= ci.leaf_params.len or ci.leaf_params[k] == null) continue;
                            if (leaves.get(arg)) |vals| {
                                try args.appendSlice(p.a, vals);
                            } else if (pleaves.get(arg)) |pl| {
                                for (pl) |pp| {
                                    const v = try add(f, p.a, .{ .op = .{ .load = pp }, .ty = f.insts.items[pp.index()].ty });
                                    try out.append(p.a, v);
                                    try args.append(p.a, v);
                                }
                            } else return p.fail("passing this value holding resources to a function", .{});
                        }
                        f.insts.items[r.index()].op = .{ .call = .{ .func = c.func, .args = args.items } };
                        if (ci.ret_void) f.insts.items[r.index()].ty = TypeTable.void_type;
                        try out.append(p.a, r);
                        // What the callee returns: its arguments or
                        // globals.
                        if (ci.ret) |srcs| {
                            const vals = try p.a.alloc(Ref, srcs.len);
                            var lts: std.ArrayList(TypeId) = .empty;
                            try leafTypes(p.a, p.t, ty, &lts);
                            for (vals, srcs, lts.items) |*v, src, lt| v.* = switch (src) {
                                .param => |pi| args.items[pi],
                                .global => |g| blk: {
                                    const gp = try add(f, p.a, .{ .op = .{ .global = g }, .ty = lt, .ptr = .resource });
                                    try out.append(p.a, gp);
                                    const l = try add(f, p.a, .{ .op = .{ .load = gp }, .ty = lt });
                                    try out.append(p.a, l);
                                    break :blk l;
                                },
                            };
                            if (isOpaque(p.t, ty)) try repl.put(p.a, r, vals[0]) else try leaves.put(p.a, r, vals);
                        }
                        continue;
                    },
                    else => {},
                }
                try out.append(p.a, r);
            }
            blk.insts = out;
            // The terminator's operand too.
            switch (blk.term) {
                .ret => |v| if (v != .none) {
                    const mv = mp.map(v);
                    blk.term = .{ .ret = mv };
                    if (ret_holds) {
                        if (isOpaque(p.t, f.ret)) {
                            try rets.append(p.a, try p.a.dupe(Ref, &.{mv}));
                            blk.term = .{ .ret = .none };
                        } else try rets.append(p.a, leaves.get(mv) orelse return p.fail("returning this value holding resources", .{}));
                    }
                },
                .cond_br => |cb| blk.term = .{ .cond_br = .{ .cond = mp.map(cb.cond), .then = cb.then, .@"else" = cb.@"else" } },
                .@"switch" => |sw| blk.term = .{ .@"switch" = .{ .value = mp.map(sw.value), .default = sw.default, .cases = sw.cases } },
                else => {},
            }
            _ = bi;
        }
        _ = n_old;
        if (ret_holds) {
            var srcs: ?[]Source = null;
            for (rets.items) |vals| {
                const here = try p.a.alloc(Source, vals.len);
                for (here, vals) |*s, v| s.* = p.trace(f, v) orelse return p.fail("returning a resource that is not a parameter or global", .{});
                if (srcs) |prev| {
                    for (prev, here) |x, y| if (!std.meta.eql(x, y)) return p.fail("returning different resources from one function", .{});
                } else srcs = here;
            }
            info.ret = srcs orelse return p.fail("a function returning resources with no return", .{});
            if (isOpaque(p.t, f.ret)) {
                info.ret_void = true;
                f.ret = TypeTable.void_type;
            }
        }
    }

    /// The parameter or global a resource value comes from.
    fn trace(p: *Pass, f: *const ir.Function, v0: Ref) ?Source {
        var v = v0;
        var steps: u32 = 0;
        while (steps < 64) : (steps += 1) {
            const inst = f.insts.items[v.index()];
            switch (inst.op) {
                .load => |x| v = x,
                .param => |pi| return .{ .param = pi },
                .global => |g| return .{ .global = g },
                // A resource local: what is stored into it.
                .local_var => v = for (f.insts.items) |i| {
                    if (i.op == .store and i.op.store.ptr == v) break i.op.store.value;
                } else return null,
                else => return null,
            }
        }
        _ = p;
        return null;
    }
};

/// Splits every function's resource-holding aggregates (SPIR-V only).
pub fn run(a: Allocator, m: *ir.Module, diags: *diag.Diagnostics) Error!void {
    var any = false;
    for (m.functions.items) |f| {
        for (f.params) |prm| if (holdsResources(m.types, prm.ty)) {
            any = true;
        };
        if (holdsResources(m.types, f.ret) or isOpaque(m.types, f.ret)) any = true;
        for (f.insts.items) |inst| if (holdsResources(m.types, inst.ty)) {
            any = true;
        };
    }
    if (!any) return;
    var p: Pass = .{ .a = a, .m = m, .t = m.types, .diags = diags, .infos = try a.alloc(FuncInfo, m.functions.items.len) };
    @memset(p.infos, .{});
    for (0..m.functions.items.len) |fi| try p.signature(@intCast(fi));
    for (0..m.functions.items.len) |fi| try p.function(@intCast(fi));
}
