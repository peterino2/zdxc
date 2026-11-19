//! `precise` for DXIL: marks precise (so not `fast`: module.fastMath), and
//! `!dx.precise`, every instruction whose result flows into `precise`
//! storage, as dxc's DxilPrecisePropagate does. Like dxc's, it runs on the
//! function once everything is inlined and mem2reg has run (the first
//! promote.run), with the `precise` locals still in memory. With -Gis
//! (`strict`), every instruction is precise.
//!
//! The emitter marks the roots (Inst.precise): the allocas of `precise`
//! locals (`root`), whose every store is precise, and the storeOutput and
//! storePatchConstant calls of `precise` outputs (`root`). From a root,
//! marking follows operands backwards; a load from memory follows the
//! stores to what it reads (by constant index; a dynamic one reads and
//! writes all of it).
//!
//! Conditions: the branches each precise instruction's block is control
//! dependent on are precise too, and so are the conditions of the blocks
//! those branches are in, transitively (`if (s * t > u) x = s + u;` with
//! `x` precise: `s * t` is precise). What counts is where a value is
//! computed, not where it is stored (`float n = t * u; if (s * t > u) x =
//! n;`: the branch is not precise), except:
//! - a phi's constant incoming value: the incoming block's conditions;
//! - a select: its condition;
//! - a store of one lane of a vector (Inst.precise.vector) to storage
//!   kept in memory (`keep`): the store's block's, as dxc marks the lane
//!   extracted at the store. The emitter keeps the HLSL entry's outputs in
//!   memory too (its returned local and its out parameters): dxc writes
//!   those in place, at each store.
//!
//! Afterwards the allocas are no longer kept: the next promote.run
//! promotes them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const module = @import("module.zig");
const promote = @import("promote.zig");

const Inst = module.Inst;
const Value = module.Value;

const none = std.math.maxInt(u32);

pub fn run(a: Allocator, m: *module.Module, func: u32, strict: bool) Allocator.Error!void {
    const f = &m.functions.items[func];
    const insts = f.insts.items;
    defer for (insts) |*inst| {
        inst.precise.keep = false;
    };
    if (strict) {
        for (insts) |*inst| try makePrecise(m, inst);
        return;
    }
    for (insts) |inst| {
        if (inst.precise.root) break;
    } else return;
    var mk: Marker = try .init(a, m, func);
    try mk.mark();
    for (insts, mk.marked) |*inst, on| if (on) try makePrecise(m, inst);
}

/// Arithmetic not `fast`; `!dx.precise` on a floating-point dx.op call.
fn makePrecise(m: *module.Module, inst: *Inst) Allocator.Error!void {
    switch (inst.op) {
        .binop => |*b| b.precise = true,
        .cmp => |*c| c.precise = true,
        .call => |c| if (m.isFloatType(inst.ty) and std.mem.startsWith(u8, m.functions.items[c.callee].name, "dx.op.")) {
            inst.md = try m.preciseMd();
        },
        else => {},
    }
}

fn isTerminator(inst: Inst) bool {
    return switch (inst.op) {
        .ret, .br, .@"switch", .@"unreachable" => true,
        else => false,
    };
}

/// What memory a pointer addresses: a base (an alloca, or a global) and
/// the constant indices into it, `null` for a dynamic one. An access with
/// fewer indices covers all the longer ones it is a prefix of.
const Place = struct {
    base: Value,
    path: []const ?i64,

    fn overlaps(x: Place, y: Place) bool {
        if (!std.meta.eql(x.base, y.base)) return false;
        for (x.path[0..@min(x.path.len, y.path.len)], y.path[0..@min(x.path.len, y.path.len)]) |p, q| {
            if (p != null and q != null and p.? != q.?) return false;
        }
        return true;
    }
};

const Marker = struct {
    a: Allocator,
    m: *const module.Module,
    insts: []const Inst,
    /// Per instruction: its block.
    block_of: []const u32,
    /// Per block: its terminator.
    term: []const u32,
    /// Per block: the blocks whose branch decides whether it runs.
    deps: []const []const u32,
    /// The stores, with what they write.
    stores: []const struct { inst: u32, place: Place },
    marked: []bool,
    /// Per instruction: a store already made precise (preciseStore once
    /// each: every load overlapping it would otherwise queue its value
    /// again, loads × stores entries with dynamic indices).
    store_done: []bool,
    controlled: []bool,
    work: std.ArrayList(u32) = .empty,

    fn init(a: Allocator, m: *const module.Module, func: u32) Allocator.Error!Marker {
        const f = &m.functions.items[func];
        const insts = f.insts.items;
        const nb = f.num_blocks;
        const block_of = try a.alloc(u32, insts.len);
        const term = try a.alloc(u32, nb);
        var b: u32 = 0;
        for (insts, 0..) |inst, i| {
            block_of[i] = b;
            if (isTerminator(inst)) {
                if (b < nb) term[b] = @intCast(i);
                b += 1;
            }
        }
        var mk: Marker = .{
            .a = a,
            .m = m,
            .insts = insts,
            .block_of = block_of,
            .term = term,
            .deps = try controlDependences(a, insts, term),
            .stores = &.{},
            .marked = try a.alloc(bool, insts.len),
            .store_done = try a.alloc(bool, insts.len),
            .controlled = try a.alloc(bool, nb),
        };
        @memset(mk.marked, false);
        @memset(mk.controlled, false);
        @memset(mk.store_done, false);
        var stores: std.ArrayList(@typeInfo(@TypeOf(mk.stores)).pointer.child) = .empty;
        for (insts, 0..) |inst, i| switch (inst.op) {
            .store => |s| try stores.append(a, .{ .inst = @intCast(i), .place = try mk.place(s.ptr) }),
            else => {},
        };
        mk.stores = stores.items;
        return mk;
    }

    fn place(mk: *const Marker, ptr: Value) Allocator.Error!Place {
        var path: std.ArrayList(?i64) = .empty;
        var p = ptr;
        while (p == .inst) switch (mk.insts[p.inst].op) {
            .gep => |g| {
                // (An outer getelementptr's first index steps over its
                // pointer: it adds to this one's last.)
                var idx: std.ArrayList(?i64) = .empty;
                for (g.indices) |x| try idx.append(mk.a, mk.constInt(x));
                if (path.items.len > 0 and idx.items.len > 0) {
                    const last = &idx.items[idx.items.len - 1];
                    const step = path.orderedRemove(0);
                    last.* = if (last.* != null and step != null) last.*.? + step.? else null;
                }
                try path.insertSlice(mk.a, 0, idx.items);
                p = g.ptr;
            },
            .cast => |c| {
                // (Reinterpreted: all of what it points into.)
                path.clearRetainingCapacity();
                p = c.val;
            },
            else => break,
        };
        return .{ .base = p, .path = path.items };
    }

    fn constInt(mk: *const Marker, v: Value) ?i64 {
        if (v != .constant) return null;
        return switch (mk.m.constants.items[v.constant].kind) {
            .int => |x| x,
            else => null,
        };
    }

    /// Whether `base` is an alloca the emitter keeps in memory until now.
    fn kept(mk: *const Marker, base: Value) bool {
        return base == .inst and mk.insts[base.inst].op == .alloca and mk.insts[base.inst].precise.keep;
    }

    fn push(mk: *Marker, v: Value) Allocator.Error!void {
        if (v == .inst and !mk.marked[v.inst]) try mk.work.append(mk.a, v.inst);
    }

    /// The value of store `i` is precise.
    fn preciseStore(mk: *Marker, i: u32, p: Place) Allocator.Error!void {
        if (mk.store_done[i]) return;
        mk.store_done[i] = true;
        try mk.push(mk.insts[i].op.store.val);
        if (mk.insts[i].precise.vector and mk.kept(p.base)) try mk.control(mk.block_of[i]);
    }

    /// Makes precise the conditions deciding whether block `b` runs, and
    /// in turn those deciding whether theirs do.
    fn control(mk: *Marker, b: u32) Allocator.Error!void {
        if (b >= mk.controlled.len or mk.controlled[b]) return;
        mk.controlled[b] = true;
        for (mk.deps[b]) |c| {
            switch (mk.insts[mk.term[c]].op) {
                .br => |br| if (br.cond) |cond| try mk.push(cond),
                .@"switch" => |sw| try mk.push(sw.cond),
                else => {},
            }
            try mk.control(c);
        }
    }

    fn mark(mk: *Marker) Allocator.Error!void {
        for (mk.insts, 0..) |inst, i| {
            if (!inst.precise.root) continue;
            switch (inst.op) {
                // A precise output.
                .call => |c| {
                    try mk.push(c.args[c.args.len - 1]);
                    if (inst.precise.vector) try mk.control(mk.block_of[i]);
                },
                else => {},
            }
        }
        // A precise local's stores.
        for (mk.stores) |s| {
            const base = s.place.base;
            if (base == .inst and mk.insts[base.inst].op == .alloca and mk.insts[base.inst].precise.root) try mk.preciseStore(s.inst, s.place);
        }
        while (mk.work.pop()) |i| {
            if (mk.marked[i]) continue;
            mk.marked[i] = true;
            const inst = mk.insts[i];
            const b = mk.block_of[i];
            switch (inst.op) {
                .load => |l| {
                    const p = try mk.place(l.ptr);
                    for (mk.stores) |s| if (p.overlaps(s.place)) try mk.preciseStore(s.inst, s.place);
                    try mk.control(b);
                },
                .phi => |ph| {
                    try mk.control(b);
                    for (ph.incoming) |in| {
                        try mk.push(in.val);
                        if (in.val == .constant) try mk.control(in.block);
                    }
                },
                // Storage, not values.
                .alloca, .gep => {},
                else => {
                    try mk.control(b);
                    const Push = struct {
                        mk: *Marker,
                        err: ?Allocator.Error = null,
                        pub fn visit(s: *@This(), v: Value, role: promote.Role) Value {
                            if (role == .other) s.mk.push(v) catch |e| {
                                s.err = e;
                            };
                            return v;
                        }
                    };
                    var ctx: Push = .{ .mk = mk };
                    var copy = inst;
                    try promote.operands(false, mk.a, &copy, &ctx);
                    if (ctx.err) |e| return e;
                },
            }
        }
    }
};

/// Per block: the blocks with a conditional branch or switch deciding
/// whether it runs. From post-dominators (Cooper, Harvey and Kennedy, on
/// the reversed graph with one exit after every block that leaves the
/// function): for each branch `b` and successor `s`, `s` and its
/// post-dominators up to `b`'s immediate one depend on `b`. Blocks from
/// which the function cannot return have no post-dominator, and stop the
/// walk.
fn controlDependences(a: Allocator, insts: []const Inst, term: []const u32) Allocator.Error![]const []const u32 {
    const nb: u32 = @intCast(term.len);
    const exit = nb;
    const succs = try a.alloc([]const u32, nb);
    const preds = try a.alloc(std.ArrayList(u32), nb + 1);
    @memset(preds, .empty);
    for (term, succs, 0..) |t, *ss, b| {
        ss.* = switch (insts[t].op) {
            .br => |br| if (br.@"else") |e| try a.dupe(u32, &.{ br.then, e }) else try a.dupe(u32, &.{br.then}),
            .@"switch" => |sw| blk: {
                const out = try a.alloc(u32, sw.cases.len + 1);
                out[0] = sw.default;
                for (sw.cases, out[1..]) |c, *o| o.* = c.block;
                break :blk out;
            },
            else => &.{},
        };
        if (ss.len == 0) try preds[exit].append(a, @intCast(b));
        for (ss.*) |s| try preds[s].append(a, @intCast(b));
    }
    // Postorder of the reversed graph from the exit.
    const order = try a.alloc(u32, nb + 1);
    @memset(order, none);
    var post: std.ArrayList(u32) = .empty;
    {
        const Frame = struct { b: u32, i: u32 };
        var stack: std.ArrayList(Frame) = .empty;
        const visited = try a.alloc(bool, nb + 1);
        @memset(visited, false);
        visited[exit] = true;
        try stack.append(a, .{ .b = exit, .i = 0 });
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const ps = preds[top.b].items;
            if (top.i < ps.len) {
                const p = ps[top.i];
                top.i += 1;
                if (!visited[p]) {
                    visited[p] = true;
                    try stack.append(a, .{ .b = p, .i = 0 });
                }
            } else {
                order[top.b] = @intCast(post.items.len);
                try post.append(a, top.b);
                _ = stack.pop();
            }
        }
    }
    const ipdom = try a.alloc(u32, nb + 1);
    @memset(ipdom, none);
    ipdom[exit] = exit;
    var changed = true;
    while (changed) {
        changed = false;
        var k = post.items.len;
        while (k > 0) {
            k -= 1;
            const b = post.items[k];
            if (b == exit) continue;
            var new: u32 = none;
            const exit_only = [_]u32{exit};
            const ss: []const u32 = if (succs[b].len == 0) &exit_only else succs[b];
            for (ss) |s| {
                if (ipdom[s] == none) continue;
                if (new == none) {
                    new = s;
                    continue;
                }
                var x = s;
                var y = new;
                while (x != y) {
                    while (order[x] < order[y]) x = ipdom[x];
                    while (order[y] < order[x]) y = ipdom[y];
                }
                new = x;
            }
            if (new != ipdom[b]) {
                ipdom[b] = new;
                changed = true;
            }
        }
    }
    const deps = try a.alloc(std.ArrayList(u32), nb);
    @memset(deps, .empty);
    for (succs, 0..) |ss, b| {
        if (ss.len < 2) continue;
        const stop = ipdom[b];
        for (ss) |s| {
            var r = s;
            while (r != stop and r < nb) {
                // (A branch's entries are added together: last if any.)
                const l = &deps[r];
                if (l.items.len == 0 or l.items[l.items.len - 1] != b) try l.append(a, @intCast(b));
                r = ipdom[r];
            }
        }
    }
    const out = try a.alloc([]const u32, nb);
    for (deps, out) |d, *o| o.* = d.items;
    return out;
}
