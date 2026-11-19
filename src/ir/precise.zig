//! `precise` for SPIR-V: marks every instruction whose result flows into
//! `precise` storage, as dxc's SPIR-V precise visitor does; the emitter
//! decorates their arithmetic NoContraction. With -Gis (ieee_strict),
//! every instruction is precise. (DXIL marks its own, as dxc's DXIL does
//! after inlining and mem2reg: dxil/precise.zig.)
//!
//! The roots are the values stored to `precise` locals (`precise` on
//! their `local_var`) and written to `precise` outputs and patch
//! constants. From a root, marking follows operands backwards. A load from
//! a local makes that local precise too, so the values stored to it are
//! marked in turn (as dxc, where `precise float z = y / 7` makes the
//! computation of `y` precise). Locals are tracked by top-level member: a
//! struct whose `precise` field is read leaves its other fields alone. An
//! access through a dynamic index stands for any member. Static and
//! groupshared globals are tracked as locals are, within each function
//! (dxc follows a global only to the stores within the function reading
//! it).
//!
//! Calls: only an entry wrapper's call of the HLSL entry is followed into
//! the callee, which is marked for what the wrapper needs of it: its
//! result, and its stores through by-reference parameters to storage the
//! wrapper has precise. Back in the wrapper, by-value arguments the
//! callee's precise code reads are marked, and so is the wrapper's storage
//! behind by-reference parameters it reads. Each (function, need) pair is
//! marked once; a function's marks are the union of its pairs'.
//!
//! Declarations: dxc's SPIR-V also honors `precise` on a function and on
//! its parameters. A precise function's returned values are precise; a
//! precise parameter is precise storage (a by-value one: the local it is
//! copied to), and the caller's arguments to it are precise too (its
//! value, or what of the caller's storage it points to).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("ir.zig");
const opt = @import("opt.zig");

const Ref = ir.Ref;

pub fn run(gpa: Allocator, m: *ir.Module) Allocator.Error!void {
    if (m.ieee_strict) {
        for (m.functions.items) |f| for (f.insts.items) |*inst| {
            inst.precise = true;
        };
        return;
    }
    if (!anyPrecise(m)) return;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const n = m.functions.items.len;
    const wrapper = try a.alloc(bool, n);
    @memset(wrapper, false);
    for (m.entries.items) |en| {
        if (en.wrapper < n) wrapper[en.wrapper] = true;
        if (en.patch_wrapper) |w| if (w < n) {
            wrapper[w] = true;
        };
    }
    var p: Pass = .{ .a = a, .m = m, .wrapper = wrapper };
    for (m.functions.items, 0..) |f, fi| {
        const params = try a.alloc(Parts, f.params.len);
        @memset(params, .empty);
        _ = try p.context(@intCast(fi), .{ .params = params });
    }
}

/// Whether anything is declared `precise` (most shaders: nothing to do).
fn anyPrecise(m: *const ir.Module) bool {
    for (m.entries.items) |en| {
        for (en.outputs.items) |o| if (o.precise) return true;
        for (en.patch_constants.items) |o| if (o.precise) return true;
    }
    for (m.functions.items) |f| {
        if (f.precise) return true;
        for (f.params) |p| if (p.precise) return true;
        for (f.insts.items) |inst| if (inst.op == .local_var and inst.op.local_var.precise) return true;
    }
    return false;
}

/// Which parts of a value or storage are precise: all of it, or some of
/// its top-level members.
const Parts = struct {
    whole: bool = false,
    members: std.ArrayList(u32) = .empty,

    const empty: Parts = .{};
    const all: Parts = .{ .whole = true };

    fn any(p: Parts) bool {
        return p.whole or p.members.items.len > 0;
    }

    fn has(p: Parts, member: u32) bool {
        return p.whole or std.mem.indexOfScalar(u32, p.members.items, member) != null;
    }

    /// Adds `member` (null: the whole); whether that changed anything.
    fn add(p: *Parts, a: Allocator, member: ?u32) Allocator.Error!bool {
        if (p.whole) return false;
        const k = member orelse {
            p.whole = true;
            return true;
        };
        if (std.mem.indexOfScalar(u32, p.members.items, k) != null) return false;
        try p.members.append(a, k);
        return true;
    }

    /// Adds everything `other` has.
    fn merge(p: *Parts, a: Allocator, other: Parts) Allocator.Error!bool {
        if (other.whole) return p.add(a, null);
        var changed = false;
        for (other.members.items) |k| changed = (try p.add(a, k)) or changed;
        return changed;
    }

    fn clone(p: Parts, a: Allocator) Allocator.Error!Parts {
        return .{ .whole = p.whole, .members = .fromOwnedSlice(try a.dupe(u32, p.members.items)) };
    }

    /// Appends a canonical encoding (for context keys).
    fn encode(p: Parts, a: Allocator, out: *std.ArrayList(u32)) Allocator.Error!void {
        if (p.whole) return out.append(a, 1);
        const ms = try a.dupe(u32, p.members.items);
        std.mem.sortUnstable(u32, ms, {}, std.sort.asc(u32));
        try out.appendSlice(a, &.{ 0, @intCast(ms.len) });
        try out.appendSlice(a, ms);
    }
};

/// What a caller needs of a callee: of its result, and of the storage
/// behind each by-reference parameter.
const Need = struct {
    ret: Parts = .empty,
    params: []Parts,
};

/// What a callee tells its caller: which by-value parameters its precise
/// code reads, and what of each by-reference parameter's storage is
/// precise (its stores to it marked, its loads from it precise).
const Summary = struct {
    values: []const bool,
    params: []const Parts,
};

const Pass = struct {
    a: Allocator,
    m: *ir.Module,
    wrapper: []const bool,
    /// Summaries by key (function and need); null while marking.
    memo: std.StringHashMapUnmanaged(?Summary) = .empty,

    /// Marks function `fi` for `need`, if not yet; its summary (null for
    /// a call back into a function being marked: recursion).
    fn context(p: *Pass, fi: u32, need: Need) Allocator.Error!?Summary {
        var key: std.ArrayList(u32) = .empty;
        try key.append(p.a, fi);
        try need.ret.encode(p.a, &key);
        for (need.params) |q| try q.encode(p.a, &key);
        const gop = try p.memo.getOrPut(p.a, std.mem.sliceAsBytes(key.items));
        if (gop.found_existing) return gop.value_ptr.*;
        gop.value_ptr.* = null;
        const f = p.m.functions.items[fi];
        var mk: Marker = .{
            .p = p,
            .fi = fi,
            .marks = try p.a.alloc(bool, f.insts.items.len),
            .ret = try need.ret.clone(p.a),
            .params = try p.a.alloc(Parts, f.params.len),
            .values = try p.a.alloc(bool, f.params.len),
        };
        @memset(mk.marks, false);
        @memset(mk.values, false);
        for (mk.params, 0..) |*q, k| q.* = if (k < need.params.len) try need.params[k].clone(p.a) else .empty;
        if (f.precise) mk.ret = .all;
        for (f.params, mk.params) |fp, *q| if (fp.precise and fp.by_ref) {
            q.* = .all;
        };
        try mk.run();
        for (mk.marks, f.insts.items) |on, *inst| if (on) {
            inst.precise = true;
        };
        const s: Summary = .{ .values = mk.values, .params = mk.params };
        // (Looked up again: marking callees may have grown the map.)
        p.memo.getPtr(std.mem.sliceAsBytes(key.items)).?.* = s;
        return s;
    }
};

/// One (function, need) pair's marking.
const Marker = struct {
    p: *Pass,
    fi: u32,
    marks: []bool,
    /// What the caller needs of the result.
    ret: Parts,
    /// Precise parts of the storage behind by-reference parameters.
    params: []Parts,
    /// By-value parameters the precise code reads.
    values: []bool,
    /// Precise parts of the function's locals (by local_var ref).
    locals: std.AutoHashMapUnmanaged(Ref, Parts) = .empty,
    /// Precise parts of static and groupshared globals (by global id).
    globals: std.AutoHashMapUnmanaged(u32, Parts) = .empty,
    /// What is needed of each call's result.
    call_rets: std.AutoHashMapUnmanaged(Ref, Parts) = .empty,
    work: std.ArrayList(Demand) = .empty,
    seen: std.AutoHashMapUnmanaged(Demand, void) = .empty,
    /// Storage or a call's needed result grew this round.
    changed: bool = false,

    const Demand = struct { ref: Ref, member: ?u32 };

    fn f(mk: *const Marker) *ir.Function {
        return mk.p.m.functions.items[mk.fi];
    }

    /// Whether calls are followed into their callees (an entry wrapper's).
    fn cross(mk: *const Marker) bool {
        return mk.p.wrapper[mk.fi];
    }

    /// What of its storage a pointer selects: all of it (no access), one
    /// constant top-level member, or a top-level member chosen at run time.
    const Sel = union(enum) { whole, member: u32, dynamic };

    /// The local or parameter `ptr` points into, and what of it.
    fn place(mk: *const Marker, ptr: Ref) struct { root: Ref, sel: Sel } {
        const fun = mk.f();
        var p = ptr;
        var sel: Sel = .whole;
        while (true) switch (fun.inst(p).op) {
            .access => |x| {
                // (The access nearest the root decides.)
                if (x.indices.len > 0) sel = switch (fun.inst(x.indices[0]).op) {
                    .constant => |c| switch (c) {
                        .int => |v| if (v >= 0) .{ .member = @intCast(v) } else .dynamic,
                        .float => .dynamic,
                    },
                    else => .dynamic,
                };
                p = x.base;
            },
            else => return .{ .root = p, .sel = sel },
        };
    }

    /// The precise parts of the storage at `root`, when it is tracked.
    fn storage(mk: *Marker, root: Ref) Allocator.Error!?*Parts {
        const fun = mk.f();
        switch (fun.inst(root).op) {
            .local_var => {
                const gop = try mk.locals.getOrPut(mk.p.a, root);
                if (!gop.found_existing) gop.value_ptr.* = .{ .whole = fun.inst(root).op.local_var.precise };
                return gop.value_ptr;
            },
            .param => |n| return if (fun.inst(root).ptr != .none and n < mk.params.len) &mk.params[n] else null,
            .global => |g| {
                const globals = mk.p.m.globals.items;
                if (g >= globals.len) return null;
                switch (globals[g].space) {
                    .private, .groupshared => {},
                    else => return null,
                }
                const gop = try mk.globals.getOrPut(mk.p.a, g);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                return gop.value_ptr;
            },
            else => return null,
        }
    }

    /// What of the storage `sel` selects is precise, as parts of the
    /// selected value.
    fn selected(mk: *Marker, parts: Parts, sel: Sel) Allocator.Error!Parts {
        return switch (sel) {
            .whole => parts.clone(mk.p.a),
            .member => |k| if (parts.has(k)) .all else .empty,
            .dynamic => if (parts.any()) .all else .empty,
        };
    }

    /// Makes `value`'s precise parts precise in the storage `sel` selects;
    /// whether that changed anything.
    fn widen(mk: *Marker, parts: *Parts, sel: Sel, value: Parts) Allocator.Error!bool {
        if (!value.any()) return false;
        return switch (sel) {
            .whole => parts.merge(mk.p.a, value),
            .member => |k| parts.add(mk.p.a, k),
            .dynamic => parts.add(mk.p.a, null),
        };
    }

    fn push(mk: *Marker, ref: Ref, member: ?u32) Allocator.Error!void {
        if (ref == .none) return;
        try mk.work.append(mk.p.a, .{ .ref = ref, .member = member });
    }

    fn pushParts(mk: *Marker, ref: Ref, parts: Parts) Allocator.Error!void {
        if (parts.whole) return mk.push(ref, null);
        for (parts.members.items) |k| try mk.push(ref, k);
    }

    fn run(mk: *Marker) Allocator.Error!void {
        const fun = mk.f();
        const m = mk.p.m;
        const entry: ?*const ir.Entry = if (fun.entry < m.entries.items.len) &m.entries.items[fun.entry] else null;
        // Precise local declarations.
        for (fun.insts.items, 0..) |inst, i| if (inst.op == .local_var and inst.op.local_var.precise) {
            _ = try mk.storage(@fromBackingInt(@intCast(i)));
        };
        // The locals precise by-value parameters are copied to.
        for (fun.insts.items) |inst| switch (inst.op) {
            .store => |x| switch (fun.inst(x.value).op) {
                .param => |k| if (fun.inst(x.value).ptr == .none and k < fun.params.len and fun.params[k].precise) {
                    const pl = mk.place(x.ptr);
                    if (pl.sel == .whole and fun.inst(pl.root).op == .local_var) {
                        if (try mk.storage(pl.root)) |parts| _ = try parts.add(mk.p.a, null);
                    }
                },
                else => {},
            },
            else => {},
        };
        while (true) {
            mk.changed = false;
            for (fun.blocks.items) |blk| {
                for (blk.insts.items) |r| switch (fun.inst(r).op) {
                    .output => |x| if (entry) |en| {
                        if (x.element < en.outputs.items.len and en.outputs.items[x.element].precise) try mk.push(x.value, null);
                    },
                    .patch_output => |x| if (entry) |en| {
                        if (x.element < en.patch_constants.items.len and en.patch_constants.items[x.element].precise) try mk.push(x.value, null);
                    },
                    .store => |x| {
                        const pl = mk.place(x.ptr);
                        const parts = (try mk.storage(pl.root)) orelse continue;
                        try mk.pushParts(x.value, try mk.selected(parts.*, pl.sel));
                    },
                    else => {},
                };
                switch (blk.term) {
                    .ret => |v| if (v != .none and mk.ret.any()) try mk.pushParts(v, mk.ret),
                    else => {},
                }
            }
            try mk.propagate();
            try mk.followCalls();
            try mk.propagate();
            if (!mk.changed) return;
        }
    }

    /// Each call's callee, for what is needed of it; then what that
    /// callee's precise code reads of the arguments.
    fn followCalls(mk: *Marker) Allocator.Error!void {
        const fun = mk.f();
        const a = mk.p.a;
        for (fun.insts.items, 0..) |inst, i| {
            const c = switch (inst.op) {
                .call => |c| c,
                else => continue,
            };
            const r: Ref = @fromBackingInt(@intCast(i));
            const callee = mk.p.m.functions.items[c.func];
            const params = try a.alloc(Parts, callee.params.len);
            @memset(params, .empty);
            var need: Need = .{ .params = params };
            if (mk.cross()) {
                if (mk.call_rets.get(r)) |q| need.ret = q;
                for (c.args, 0..) |arg, k| if (k < params.len and fun.inst(arg).ptr != .none) {
                    const pl = mk.place(arg);
                    const parts = (try mk.storage(pl.root)) orelse continue;
                    params[k] = try mk.selected(parts.*, pl.sel);
                };
            }
            const summary = try mk.p.context(c.func, need);
            // Arguments to precise parameters, whether or not the call is
            // followed.
            for (c.args, 0..) |arg, k| if (k < callee.params.len and callee.params[k].precise) {
                if (fun.inst(arg).ptr == .none) {
                    try mk.push(arg, null);
                    continue;
                }
                const pl = mk.place(arg);
                const parts = (try mk.storage(pl.root)) orelse continue;
                if (try mk.widen(parts, pl.sel, .all)) mk.changed = true;
            };
            if (!mk.cross()) continue;
            const s = summary orelse continue;
            for (c.args, 0..) |arg, k| {
                if (k >= s.values.len) break;
                if (fun.inst(arg).ptr == .none) {
                    if (s.values[k]) try mk.push(arg, null);
                    continue;
                }
                const pl = mk.place(arg);
                const parts = (try mk.storage(pl.root)) orelse continue;
                if (try mk.widen(parts, pl.sel, s.params[k])) mk.changed = true;
            }
        }
    }

    fn propagate(mk: *Marker) Allocator.Error!void {
        const fun = mk.f();
        const a = mk.p.a;
        while (mk.work.pop()) |d| {
            const gop = try mk.seen.getOrPut(a, d);
            if (gop.found_existing) continue;
            const inst = fun.inst(d.ref);
            switch (inst.op) {
                .load => |ptr| {
                    const pl = mk.place(ptr);
                    const parts = (try mk.storage(pl.root)) orelse continue;
                    // `d.member` is a member of the loaded value: of the
                    // storage only when the load is of all of it.
                    const member: ?u32 = switch (pl.sel) {
                        .whole => d.member,
                        .member => |k| k,
                        .dynamic => null,
                    };
                    if (try parts.add(a, member)) mk.changed = true;
                },
                // A member of an aggregate: only that member is needed.
                .extract => |x| try mk.push(x.agg, x.index),
                .insert => |x| if (d.member) |k| {
                    if (k == x.index) try mk.push(x.value, null) else try mk.push(x.agg, k);
                } else {
                    try mk.push(x.agg, null);
                    try mk.push(x.value, null);
                },
                .construct => |xs| if (d.member != null and mk.p.m.types.get(inst.ty) == .@"struct" and d.member.? < xs.len) {
                    try mk.push(xs[d.member.?], null);
                } else for (xs) |x| try mk.push(x, null),
                .phi => |ps| for (ps) |p| try mk.push(p.value, d.member),
                .select => |x| {
                    try mk.push(x.t, d.member);
                    try mk.push(x.f, d.member);
                },
                // The callee's result, as followCalls asks for it; not the
                // arguments, unless its precise code reads them.
                .call => if (mk.cross()) {
                    const g = try mk.call_rets.getOrPut(a, d.ref);
                    if (!g.found_existing) g.value_ptr.* = .empty;
                    if (try g.value_ptr.add(a, d.member)) mk.changed = true;
                },
                // A by-value parameter: the callers' arguments.
                .param => |k| if (inst.ptr == .none and k < mk.values.len) {
                    mk.values[k] = true;
                },
                // Storage, not values.
                .local_var, .global, .access => {},
                else => {
                    // Arithmetic and the rest: all of it.
                    mk.marks[d.ref.index()] = true;
                    const Push = struct {
                        mk: *Marker,
                        failed: *bool,
                        pub fn use(s: @This(), x: Ref) void {
                            s.mk.push(x, null) catch {
                                s.failed.* = true;
                            };
                        }
                    };
                    var failed = false;
                    opt.eachOperand(inst.op, Push{ .mk = mk, .failed = &failed });
                    if (failed) return error.OutOfMemory;
                },
            }
        }
    }
};
