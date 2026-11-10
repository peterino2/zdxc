//! Inlining for SPIR-V: calls are replaced by copies of their callees, as
//! dxc's legalization does, so drivers get one function per entry point
//! (and later passes see across call boundaries).
//!
//! Calls are inlined top-down from the entry points. The calling block is
//! split at the call:
//! it branches to the copy of the callee's entry, and the rest of the block
//! (with its terminator and merge) moves to a continuation block. A callee
//! with one return outside every construct branches from it to the
//! continuation. Returns inside selections first become breaks out of a
//! loop that runs once (the callee wrapped in it), with the return value in
//! a local; the loop's merge block is where the callee returns, once.
//! A return inside loops also sets a "returned" flag and breaks out of
//! its loop; the merge block of each loop around a return then breaks out
//! of the next loop out (or the one-trip loop) when the flag is set, as
//! SPIRV-Tools' merge-return does.
//!
//! Functions no root reaches any more are marked dead (and not emitted).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("ir.zig");
const types = @import("../sema/types.zig");
const opt = @import("opt.zig");
const split_resources = @import("split_resources.zig");

const Ref = ir.Ref;
const BlockId = ir.BlockId;
const TypeTable = types.TypeTable;

pub const Error = Allocator.Error;

/// Whether the module is one the pass handles: graphics and compute entry
/// points only (the emitter treats hull, mesh, geometry and ray tracing
/// functions specially), and no rasterizer-ordered views (the pixel
/// shader's call of its entry function is the interlocked region).
pub fn eligible(m: *const ir.Module) bool {
    if (m.entries.items.len == 0) return false;
    for (m.entries.items) |e| switch (e.stage) {
        .vertex, .pixel, .compute => {},
        // Ray tracing entry points stay functions (their payloads and
        // attributes are the emitter's); their callees are inlined, as
        // dxc's legalization does. Unreal runs spirv-opt -O on its SPIR-V,
        // whose ssa-rewrite recursion overflowed the stack on a path
        // tracing library left as 842 functions.
        .raygeneration, .intersection, .anyhit, .closesthit, .miss, .callable => {},
        else => return false,
    };
    for (m.globals.items) |g| {
        var t = g.ty;
        while (m.types.get(t) == .array) t = m.types.get(t).array.elem;
        if (m.types.get(t) == .resource and std.mem.startsWith(u8, m.types.get(t).resource.name, "RasterizerOrdered")) return false;
    }
    return true;
}

pub fn run(m: *ir.Module) Error!void {
    if (!eligible(m)) return;
    const a = m.arena;
    const n = m.functions.items.len;
    // Shapes from the original bodies (inlining a function's callees does
    // not change how it returns).
    const shapes = try a.alloc(?Shape, n);
    for (m.functions.items, shapes) |f, *sh| sh.* = try shapeOf(a, m, f);
    // Top-down from the roots: each call is replaced by a copy of the
    // callee's own body, whose calls are inlined in turn as the scan
    // reaches the copied blocks; a function only gets expanded where it
    // ends up. Callees that stay functions are expanded as roots.
    const done = try a.alloc(bool, n);
    @memset(done, false);
    var work: std.ArrayList(u32) = .empty;
    for (m.entries.items) |e| {
        try work.append(a, e.wrapper);
        if (e.patch_wrapper) |pw| try work.append(a, pw);
    }
    try work.appendSlice(a, m.exports.items);
    while (work.pop()) |fi| {
        if (done[fi]) continue;
        done[fi] = true;
        try inlineCalls(m, m.functions.items[fi], shapes, &work);
    }
    try markDead(m);
}

/// Inlines only the calls of functions that return a resource or a struct
/// holding one, in every kind of module (ray-tracing libraries included),
/// before resources are split out of structs: what such a function
/// returns can be an element of a resource array picked by an index it
/// computes (`bindless[NonUniformResourceIndex(i)]`), which no function
/// signature can pass back. dxc's legalization inlines everything.
pub fn runResourceReturns(m: *ir.Module) Error!void {
    const a = m.arena;
    const n = m.functions.items.len;
    const shapes = try a.alloc(?Shape, n);
    var any = false;
    for (m.functions.items, shapes) |f, *sh| {
        sh.* = .keep;
        if (!isResource(m.types, f.ret) and !split_resources.holdsResources(m.types, f.ret)) continue;
        const shape = try shapeOf(a, m, f);
        sh.* = shape;
        if (shape != .keep) any = true;
    }
    if (!any) return;
    const done = try a.alloc(bool, n);
    @memset(done, false);
    var work: std.ArrayList(u32) = .empty;
    for (m.entries.items) |e| {
        try work.append(a, e.wrapper);
        if (e.patch_wrapper) |pw| try work.append(a, pw);
    }
    try work.appendSlice(a, m.exports.items);
    while (work.pop()) |fi| {
        if (done[fi]) continue;
        done[fi] = true;
        try inlineCalls(m, m.functions.items[fi], shapes, &work);
    }
    try markDead(m);
}

/// How a function returns, for inlining it.
const Shape = union(enum) {
    /// Not inlinable.
    keep,
    /// One return, outside every construct: that block.
    single: u32,
    /// Returns inside selections or loops (or several): wrap in a one-trip
    /// loop.
    wrap: Wrap,
};

const Wrap = struct {
    /// Returns inside loops: the block, and the headers of the loops around
    /// it, innermost first.
    in_loops: []const struct { block: u32, loops: []const u32 } = &.{},
};

fn shapeOf(a: Allocator, m: *const ir.Module, f: *const ir.Function) Error!Shape {
    if (f.no_inline) return .keep;
    for (f.params) |p| {
        if (isRayQuery(m.types, p.ty)) return .keep;
        if (p.by_ref and isResource(m.types, p.ty)) return .keep;
    }
    const nb = f.blocks.items.len;
    // The innermost construct (header block) around each block, from a
    // structured walk: a header's merge is at the header's level, its other
    // successors are inside; exits to an enclosing merge or continue are
    // not followed (their header places those blocks).
    const root = std.math.maxInt(u32);
    const ctx = try a.alloc(u32, nb);
    const seen = try a.alloc(bool, nb);
    const parent = try a.alloc(u32, nb);
    @memset(seen, false);
    @memset(parent, root);
    var stack: std.ArrayList(struct { b: u32, c: u32 }) = .empty;
    try stack.append(a, .{ .b = 0, .c = root });
    while (stack.pop()) |it| {
        if (seen[it.b]) continue;
        seen[it.b] = true;
        ctx[it.b] = it.c;
        const blk = f.blocks.items[it.b];
        var inner = it.c;
        switch (blk.merge) {
            .none => {},
            .selection => |mb| {
                try stack.append(a, .{ .b = mb.index(), .c = it.c });
                parent[it.b] = it.c;
                inner = it.b;
            },
            .loop => |l| {
                try stack.append(a, .{ .b = l.merge.index(), .c = it.c });
                try stack.append(a, .{ .b = l.@"continue".index(), .c = it.b });
                parent[it.b] = it.c;
                inner = it.b;
            },
        }
        for (try successors(a, blk.term)) |s| {
            if (s == .none) continue;
            if (isExit(f, inner, parent, s.index())) continue;
            try stack.append(a, .{ .b = s.index(), .c = inner });
        }
    }
    var rets: u32 = 0;
    var ret_block: u32 = 0;
    var nested = false;
    var in_loops: std.ArrayList(@typeInfo(@FieldType(Wrap, "in_loops")).pointer.child) = .empty;
    for (f.blocks.items, 0..) |blk, bi| {
        if (!seen[bi] or blk.term != .ret) continue;
        rets += 1;
        ret_block = @intCast(bi);
        var loops: std.ArrayList(u32) = .empty;
        var c = ctx[bi];
        while (c != root) : (c = parent[c]) {
            if (f.blocks.items[c].merge == .loop) try loops.append(a, c);
        }
        if (loops.items.len > 0) try in_loops.append(a, .{ .block = @intCast(bi), .loops = loops.items });
        if (ctx[bi] != root) nested = true;
    }
    if (rets == 0) return .keep; // (never returns: leave it alone)
    if (rets == 1 and !nested) return .{ .single = ret_block };
    // A resource returned through a local would be a resource local
    // assigned in several places.
    if (isResource(m.types, f.ret)) return .keep;
    return .{ .wrap = .{ .in_loops = in_loops.items } };
}

/// Whether `s`, a successor of a block whose innermost construct is headed
/// by `inner`, is that construct's (or an enclosing one's) merge or
/// continue target.
fn isExit(f: *const ir.Function, inner: u32, parent: []const u32, s: u32) bool {
    var c = inner;
    while (c != std.math.maxInt(u32)) : (c = parent[c]) {
        switch (f.blocks.items[c].merge) {
            .none => {},
            .selection => |mb| if (mb.index() == s) return true,
            .loop => |l| if (l.merge.index() == s or l.@"continue".index() == s) return true,
        }
    }
    return false;
}

fn successors(a: Allocator, term: ir.Terminator) Error![]const BlockId {
    return switch (term) {
        .br => |b| try a.dupe(BlockId, &.{b}),
        .cond_br => |c| try a.dupe(BlockId, &.{ c.then, c.@"else" }),
        .@"switch" => |sw| blk: {
            const out = try a.alloc(BlockId, sw.cases.len + 1);
            out[0] = sw.default;
            for (sw.cases, out[1..]) |c, *o| o.* = c.block;
            break :blk out;
        },
        else => &.{},
    };
}

fn isRayQuery(t: *TypeTable, ty: types.TypeId) bool {
    return switch (t.get(ty)) {
        .resource => |r| r.kind == .other and std.mem.eql(u8, r.name, "RayQuery"),
        else => false,
    };
}

fn isResource(t: *TypeTable, ty: types.TypeId) bool {
    return switch (t.get(ty)) {
        .resource => !isRayQuery(t, ty),
        .sampler => true,
        .array => |x| isResource(t, x.elem),
        else => false,
    };
}

fn newBlock(a: Allocator, f: *ir.Function, blk: ir.Block) Error!u32 {
    try f.blocks.append(a, blk);
    return @intCast(f.blocks.items.len - 1);
}

fn newInst(a: Allocator, f: *ir.Function, inst: ir.Inst) Error!Ref {
    try f.insts.append(a, inst);
    return @fromBackingInt(@intCast(f.insts.items.len - 1));
}

/// Inlines every call in `f` whose callee has an inlinable shape (calls
/// in the copies included); callees of calls that stay go to `work`.
fn inlineCalls(m: *ir.Module, f: *ir.Function, shapes: []const ?Shape, work: *std.ArrayList(u32)) Error!void {
    const a = m.arena;
    // Call results, replaced by the callees' return values at the end.
    var results: std.AutoHashMapUnmanaged(u32, Ref) = .empty;
    var bi: usize = 0;
    while (bi < f.blocks.items.len) : (bi += 1) {
        var pos: usize = 0;
        while (pos < f.blocks.items[bi].insts.items.len) : (pos += 1) {
            const r = f.blocks.items[bi].insts.items[pos];
            const call = switch (f.inst(r).op) {
                .call => |c| c,
                else => continue,
            };
            const shape = shapes[call.func] orelse .keep;
            // A loop header keeps its instructions (its back edges target it).
            if (shape == .keep or f.blocks.items[bi].merge == .loop) {
                try work.append(a, call.func);
                continue;
            }
            const callee = m.functions.items[call.func];
            const value = try inlineOne(a, m.types, f, @intCast(bi), pos, call.args, callee, shape);
            try results.put(a, r.index(), value);
            // The rest of the block moved to the continuation block, which
            // is later in the block list.
            break;
        }
    }
    if (results.count() == 0) return;
    const Map = struct {
        res: *const std.AutoHashMapUnmanaged(u32, Ref),
        pub fn map(c: @This(), x: Ref) Ref {
            var y = x;
            while (y != .none) {
                y = c.res.get(y.index()) orelse return y;
            }
            return y;
        }
    };
    const mp = Map{ .res = &results };
    const Hit = struct {
        res: *const std.AutoHashMapUnmanaged(u32, Ref),
        hit: *bool,
        pub fn use(c: @This(), x: Ref) void {
            if (x != .none and c.res.contains(x.index())) c.hit.* = true;
        }
    };
    for (f.blocks.items) |*blk| {
        for (blk.insts.items) |r| {
            var hit = false;
            opt.eachOperand(f.inst(r).op, Hit{ .res = &results, .hit = &hit });
            if (hit) f.insts.items[r.index()].op = try opt.mapOp(a, f.inst(r).op, mp);
        }
        blk.term = mapTerm(blk.term, mp);
    }
}

fn mapTerm(term: ir.Terminator, mp: anytype) ir.Terminator {
    return switch (term) {
        .ret => |v| .{ .ret = mp.map(v) },
        .cond_br => |c| .{ .cond_br = .{ .cond = mp.map(c.cond), .then = c.then, .@"else" = c.@"else" } },
        .@"switch" => |s| .{ .@"switch" = .{ .value = mp.map(s.value), .default = s.default, .cases = s.cases } },
        else => term,
    };
}

/// Inlines `callee(args)`, the instruction at `pos` of block `bi` of `f`.
/// Returns the value the call produced (`.none` for void).
fn inlineOne(a: Allocator, m_types: *TypeTable, f: *ir.Function, bi: u32, pos: usize, args: []const Ref, callee: *const ir.Function, shape: Shape) Error!Ref {
    // Continuation: the instructions after the call, the terminator and
    // the merge.
    const cont = try newBlock(a, f, .{});
    {
        const blk = &f.blocks.items[bi];
        try f.blocks.items[cont].insts.appendSlice(a, blk.insts.items[pos + 1 ..]);
        f.blocks.items[cont].term = blk.term;
        f.blocks.items[cont].merge = blk.merge;
        f.blocks.items[cont].selection_control = blk.selection_control;
        blk.insts.shrinkRetainingCapacity(pos);
        blk.merge = .none;
        blk.selection_control = .none;
    }

    // Copies of the callee's blocks and instructions (parameters become
    // the arguments). Only instructions in its blocks are copied up front;
    // others it refers to (locals live in no block) are copied on first
    // use: the callee's array also holds what earlier inlining left behind.
    const bmap = try a.alloc(u32, callee.blocks.items.len);
    for (bmap) |*b| b.* = try newBlock(a, f, .{});
    const imap = try a.alloc(Ref, callee.insts.items.len);
    @memset(imap, .none);
    for (callee.blocks.items) |blk| for (blk.insts.items) |r| {
        const inst = callee.inst(r);
        imap[r.index()] = switch (inst.op) {
            .param => |p| args[p],
            else => try newInst(a, f, inst),
        };
    };
    const Map = struct {
        imap: []Ref,
        f: *ir.Function,
        callee: *const ir.Function,
        args: []const Ref,
        al: Allocator,
        pub fn map(c: *const @This(), x: Ref) Ref {
            if (x == .none) return x;
            if (c.imap[x.index()] != .none) return c.imap[x.index()];
            const inst = c.callee.inst(x);
            const y = switch (inst.op) {
                .param => |p| c.args[p],
                else => newInst(c.al, c.f, inst) catch return x,
            };
            c.imap[x.index()] = y;
            if (inst.op != .param) c.f.insts.items[y.index()].op = opt.mapOp(c.al, inst.op, c) catch inst.op;
            return y;
        }
    };
    const mp = &Map{ .imap = imap, .f = f, .callee = callee, .args = args, .al = a };
    for (callee.blocks.items) |blk| for (blk.insts.items) |r| {
        const inst = callee.inst(r);
        if (inst.op == .param) continue;
        f.insts.items[imap[r.index()].index()].op = try opt.mapOp(a, inst.op, mp);
    };
    const B = struct {
        fn map(bm: []const u32, b: BlockId) BlockId {
            return if (b == .none) b else @fromBackingInt(@intCast(bm[b.index()]));
        }
    };

    // Wrapping: header -> (callee entry) ... -> exit; an unreachable
    // continue block; the return value in a local.
    var exit: u32 = cont;
    var ret_var: Ref = .none;
    var result: Ref = .none;
    var entry_target: u32 = bmap[0];
    // Returns inside loops: the "returned" flag, false on entry.
    var flag: Ref = .none;
    var ret_loop: std.AutoHashMapUnmanaged(u32, u32) = .empty; // callee ret block -> innermost loop header
    if (shape == .wrap and shape.wrap.in_loops.len > 0) {
        const bool_ty = try m_types.scalar(.bool);
        flag = try newInst(a, f, .{ .op = .local_var, .ty = bool_ty, .ptr = .function });
        const no = try newInst(a, f, .{ .op = .{ .constant = .{ .int = 0 } }, .ty = bool_ty });
        const st = try newInst(a, f, .{ .op = .{ .store = .{ .ptr = flag, .value = no } }, .ty = TypeTable.void_type });
        try f.blocks.items[bi].insts.appendSlice(a, &.{ no, st });
        for (shape.wrap.in_loops) |rl| try ret_loop.put(a, rl.block, rl.loops[0]);
    }
    if (shape == .wrap) {
        exit = try newBlock(a, f, .{});
        const header = try newBlock(a, f, .{});
        const latch = try newBlock(a, f, .{ .term = .{ .br = @fromBackingInt(@intCast(header)) } });
        f.blocks.items[header].merge = .{ .loop = .{ .merge = @fromBackingInt(@intCast(exit)), .@"continue" = @fromBackingInt(@intCast(latch)), .unroll = .auto } };
        f.blocks.items[header].term = .{ .br = @fromBackingInt(@intCast(bmap[0])) };
        entry_target = header;
        if (callee.ret != TypeTable.void_type) {
            ret_var = try newInst(a, f, .{ .op = .local_var, .ty = callee.ret, .ptr = .function });
            result = try newInst(a, f, .{ .op = .{ .load = ret_var }, .ty = callee.ret });
            try f.blocks.items[exit].insts.append(a, result);
        }
        f.blocks.items[exit].term = .{ .br = @fromBackingInt(@intCast(cont)) };
    }

    for (callee.blocks.items, 0..) |src, k| {
        var insts: std.ArrayList(Ref) = .empty;
        for (src.insts.items) |r| {
            if (callee.inst(r).op == .param) continue;
            try insts.append(a, mp.map(r));
        }
        var term: ir.Terminator = switch (src.term) {
            .ret => |v| blk: {
                if (shape == .wrap) {
                    if (ret_var != .none and v != .none) {
                        const st = try newInst(a, f, .{ .op = .{ .store = .{ .ptr = ret_var, .value = mp.map(v) } }, .ty = TypeTable.void_type });
                        try insts.append(a, st);
                    }
                    if (ret_loop.get(@intCast(k))) |header| {
                        // Inside loops: set the flag, break out of the
                        // innermost one.
                        const yes = try newInst(a, f, .{ .op = .{ .constant = .{ .int = 1 } }, .ty = try m_types.scalar(.bool) });
                        const st = try newInst(a, f, .{ .op = .{ .store = .{ .ptr = flag, .value = yes } }, .ty = TypeTable.void_type });
                        try insts.appendSlice(a, &.{ yes, st });
                        break :blk .{ .br = B.map(bmap, callee.blocks.items[header].merge.loop.merge) };
                    }
                    break :blk .{ .br = @fromBackingInt(@intCast(exit)) };
                }
                if (v != .none) result = mp.map(v);
                break :blk .{ .br = @fromBackingInt(@intCast(cont)) };
            },
            .br => |b| .{ .br = B.map(bmap, b) },
            .cond_br => |c| .{ .cond_br = .{ .cond = mp.map(c.cond), .then = B.map(bmap, c.then), .@"else" = B.map(bmap, c.@"else") } },
            .@"switch" => |sw| blk: {
                const cases = try a.alloc(@typeInfo(@TypeOf(sw.cases)).pointer.child, sw.cases.len);
                for (sw.cases, cases) |c, *o| o.* = .{ .value = c.value, .block = B.map(bmap, c.block) };
                break :blk .{ .@"switch" = .{ .value = mp.map(sw.value), .default = B.map(bmap, sw.default), .cases = cases } };
            },
            else => src.term,
        };
        _ = &term;
        const merge: ir.Merge = switch (src.merge) {
            .none => .none,
            .selection => |mb| .{ .selection = B.map(bmap, mb) },
            .loop => |l| .{ .loop = .{ .merge = B.map(bmap, l.merge), .@"continue" = B.map(bmap, l.@"continue"), .unroll = l.unroll } },
        };
        f.blocks.items[bmap[k]] = .{ .insts = insts, .term = term, .merge = merge, .selection_control = src.selection_control };
    }
    // The merge block of each loop around a return leaves for the next
    // loop out's merge (or the one-trip loop's) when the flag is set; what
    // it held moves to a block after the check.
    if (flag != .none) {
        var done: std.AutoHashMapUnmanaged(u32, void) = .empty;
        for (shape.wrap.in_loops) |rl| for (rl.loops, 0..) |header, li| {
            if ((try done.fetchPut(a, header, {})) != null) continue;
            const mb = bmap[callee.blocks.items[header].merge.loop.merge.index()];
            const out: u32 = if (li + 1 < rl.loops.len) bmap[callee.blocks.items[rl.loops[li + 1]].merge.loop.merge.index()] else exit;
            const rest = try newBlock(a, f, f.blocks.items[mb]);
            const bool_ty = try m_types.scalar(.bool);
            const ld = try newInst(a, f, .{ .op = .{ .load = flag }, .ty = bool_ty });
            f.blocks.items[mb] = .{ .term = .{ .cond_br = .{ .cond = ld, .then = @fromBackingInt(@intCast(out)), .@"else" = @fromBackingInt(@intCast(rest)) } } };
            try f.blocks.items[mb].insts.append(a, ld);
        };
    }
    f.blocks.items[bi].term = .{ .br = @fromBackingInt(@intCast(entry_target)) };
    return result;
}

/// Marks functions no root (entry wrappers and patch wrappers, exports)
/// reaches through calls as dead.
fn markDead(m: *ir.Module) Error!void {
    const a = m.arena;
    const n = m.functions.items.len;
    const live = try a.alloc(bool, n);
    @memset(live, false);
    var stack: std.ArrayList(u32) = .empty;
    for (m.entries.items) |e| {
        try stack.append(a, e.wrapper);
        if (e.patch_wrapper) |p| try stack.append(a, p);
    }
    try stack.appendSlice(a, m.exports.items);
    while (stack.pop()) |fi| {
        if (live[fi]) continue;
        live[fi] = true;
        const f = m.functions.items[fi];
        for (f.blocks.items) |blk| for (blk.insts.items) |r| if (f.inst(r).op == .call) try stack.append(a, f.inst(r).op.call.func);
    }
    for (m.functions.items, live) |f, l| f.dead = !l;
}
