//! Loops that run once stop being loops: the one-trip loops inlining wraps
//! callees with returns inside selections in, and loops whose back edge
//! folded to their merge (`do { ... } while (false)`, a loop folding left
//! one iteration of). Unreal's inlined helpers leave thousands, each a
//! header, a latch and phis Unreal's spirv-opt then works through (dxc's
//! SPIR-V has them only where it still needs them).
//!
//! A loop goes when nothing branches back to its header and every branch
//! to its merge or continue block is an unconditional one from the loop's
//! own level (no break from inside a nested selection or switch, or on a
//! condition, which only the loop makes structured): its header becomes a
//! plain block and its continue block, if reached, branches to the merge.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("ir.zig");
const opt = @import("opt.zig");

const BlockId = ir.BlockId;
const none = std.math.maxInt(u32);

fn successors(a: Allocator, term: ir.Terminator) Allocator.Error![]const BlockId {
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

fn isExit(f: *const ir.Function, inner: u32, parent: []const u32, s: u32) bool {
    var c = inner;
    while (c != none) : (c = parent[c]) {
        switch (f.blocks.items[c].merge) {
            .none => {},
            .selection => |mb| if (mb.index() == s) return true,
            .loop => |l| if (l.merge.index() == s or l.@"continue".index() == s) return true,
        }
    }
    return false;
}

/// Whether a continue block leaves for the merge, its branch back (if any)
/// on a constant that is not taken.
fn constantExit(f: *const ir.Function, term: ir.Terminator, header: u32, merge: u32) bool {
    return switch (term) {
        .br => |b| b.index() == merge,
        .cond_br => |c| blk: {
            const ci = f.inst(c.cond);
            if (ci.op != .constant) break :blk false;
            const take = switch (ci.op.constant) {
                .int => |v| v != 0,
                .float => |v| v != 0,
            };
            const taken = if (take) c.then else c.@"else";
            break :blk taken.index() == merge and taken.index() != header;
        },
        else => false,
    };
}

pub fn run(a: Allocator, f: *ir.Function) Allocator.Error!bool {
    var any = false;
    var sweep: u32 = 0;
    while (sweep < 8) : (sweep += 1) {
        if (!try once(a, f)) break;
        any = true;
    }
    if (any) try opt.fixPhis(a, f);
    return any;
}

fn once(a: Allocator, f: *ir.Function) Allocator.Error!bool {
    const nb = f.blocks.items.len;
    if (nb == 0) return false;
    // Reachable blocks.
    const live = try a.alloc(bool, nb);
    @memset(live, false);
    {
        var stack: std.ArrayList(u32) = .empty;
        try stack.append(a, 0);
        live[0] = true;
        while (stack.pop()) |b| for (try successors(a, f.blocks.items[b].term)) |s| {
            if (s == .none or live[s.index()]) continue;
            live[s.index()] = true;
            try stack.append(a, s.index());
        };
    }
    // The innermost construct header around each block (adce.zig's walk).
    const ctx = try a.alloc(u32, nb);
    const parent = try a.alloc(u32, nb);
    const seen = try a.alloc(bool, nb);
    @memset(ctx, none);
    @memset(parent, none);
    @memset(seen, false);
    {
        var stack: std.ArrayList(struct { b: u32, c: u32 }) = .empty;
        try stack.append(a, .{ .b = 0, .c = none });
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
    }
    // Reachable predecessors.
    const preds = try a.alloc(std.ArrayList(u32), nb);
    for (preds) |*p| p.* = .empty;
    for (f.blocks.items, 0..) |b, bi| {
        if (!live[bi]) continue;
        for (try successors(a, b.term)) |s| if (s != .none) try preds[s.index()].append(a, @intCast(bi));
    }
    var changed = false;
    for (0..nb) |hi| {
        if (!live[hi]) continue;
        const l = switch (f.blocks.items[hi].merge) {
            .loop => |l| l,
            else => continue,
        };
        const m = l.merge.index();
        const c = l.@"continue".index();
        if (c == hi) continue;
        // Nothing branches back: the continue block, if reached, leaves
        // for the merge, and nothing else inside the loop goes to the
        // header.
        if (live[c] and !constantExit(f, f.blocks.items[c].term, @intCast(hi), m)) continue;
        const back = for (preds[hi].items) |p| {
            if (p != c and inside(ctx, parent, p, @intCast(hi))) break true;
        } else false;
        if (back) continue;
        // The header branches on unconditionally (a conditional branch
        // needs the construct), and breaks and continues are unconditional
        // branches from the loop's own level (a branch out of a nested
        // construct, or one with two ways out, is structured only as the
        // loop's break).
        if (f.blocks.items[hi].term != .br) continue;
        const level = blk: for ([_]u32{ m, c }) |t| {
            for (preds[t].items) |p| {
                if (p == hi or p == c) continue;
                const pb = f.blocks.items[p];
                if (ctx[p] != hi or pb.term != .br or pb.merge != .none) break :blk false;
            }
        } else true;
        if (!level) continue;
        f.blocks.items[hi].merge = .none;
        if (live[c]) f.blocks.items[c].term = .{ .br = l.merge };
        changed = true;
    }
    return changed;
}

fn inside(ctx: []const u32, parent: []const u32, b: u32, header: u32) bool {
    var c = ctx[b];
    while (c != none) : (c = parent[c]) if (c == header) return true;
    return false;
}
