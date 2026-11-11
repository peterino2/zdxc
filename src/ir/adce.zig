//! Aggressive dead code elimination on structured control flow, as
//! SPIRV-Tools' eliminate-dead-code-aggressive leaves dxc's SPIR-V: an
//! instruction is live if it has side effects or a live instruction uses
//! it; a selection's branch is live only if something live depends on it
//! (a live instruction inside the selection, a live phi at its merge, or a
//! way out of it other than its merge). A selection whose branch is not
//! live goes straight to its merge, and what it held goes with it.
//!
//! Unreal computes values it does not use (Lumen's sky light RGS:
//! `FScreenSpaceData ScreenSpaceData = GetScreenSpaceData(UV);`), whose
//! decoding branches on what it reads; the buffers read are bindings dxc's
//! SPIR-V does not have, and Unreal's cooker rejects a shader with a
//! uniform buffer its parameters do not declare.
//!
//! Loops and switches stay as they are (their branches are live).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("ir.zig");
const opt = @import("opt.zig");

const Ref = ir.Ref;
const BlockId = ir.BlockId;

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

/// Operations whose results are their only effect.
fn isPure(f: *const ir.Function, op: ir.Op) bool {
    return switch (op) {
        .constant, .global, .load, .access, .binary, .unary, .cmp, .convert, .bitcast, .splat, .extract, .insert, .construct, .shuffle, .select, .heap_resource, .phi, .undef, .res_load, .local_var, .param, .input, .input_vertex, .patch_input => true,
        .intrinsic => |x| opt.isPureIntrinsic(f, x.name, x.args),
        .method => |x| blk: {
            const reads = [_][]const u8{ "Load", "Sample", "SampleLevel", "SampleGrad", "SampleBias", "SampleCmp", "SampleCmpLevelZero", "SampleCmpLevel", "Gather", "GatherRed", "GatherGreen", "GatherBlue", "GatherAlpha", "GatherCmp", "GatherCmpRed", "CalculateLevelOfDetail", "CalculateLevelOfDetailUnclamped" };
            const known = for (reads) |r| {
                if (std.mem.eql(u8, x.name, r)) break true;
            } else false;
            if (!known) break :blk false;
            for (x.args) |arg| if (f.inst(arg).ptr != .none) break :blk false;
            break :blk true;
        },
        else => false,
    };
}

fn placedOp(op: ir.Op) bool {
    return switch (op) {
        .local_var, .constant, .undef, .param, .global, .spec_constant => false,
        else => true,
    };
}

pub fn run(a: Allocator, f: *ir.Function) Allocator.Error!void {
    const nb = f.blocks.items.len;
    const ni = f.insts.items.len;
    if (nb == 0) return;
    const none = std.math.maxInt(u32);

    // The innermost construct header around each block, and each header's
    // enclosing header (a structured walk, as inline.zig's).
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

    // The innermost loop around each block (none: in no loop).
    const loop_of = try a.alloc(u32, nb);
    for (0..nb) |bi| {
        var c: u32 = if (f.blocks.items[bi].merge == .loop) @intCast(bi) else ctx[bi];
        while (c != none and f.blocks.items[c].merge != .loop) c = parent[c];
        loop_of[bi] = c;
    }
    const live = try a.alloc(bool, ni);
    @memset(live, false);
    // Selection headers whose branch is live.
    const branch_live = try a.alloc(bool, nb);
    @memset(branch_live, false);
    const block_of = try a.alloc(u32, ni);
    @memset(block_of, none);
    for (f.blocks.items, 0..) |b, bi| for (b.insts.items) |r| {
        block_of[r.index()] = @intCast(bi);
    };

    var work: std.ArrayList(Ref) = .empty;
    const Mark = struct {
        live: []bool,
        work: *std.ArrayList(Ref),
        al: Allocator,
        fn ref(m: @This(), r: Ref) void {
            if (r == .none or r.index() >= m.live.len or m.live[r.index()]) return;
            m.live[r.index()] = true;
            m.work.append(m.al, r) catch {};
        }
        pub fn use(m: @This(), r: Ref) void {
            m.ref(r);
        }
    };
    const mark = Mark{ .live = live, .work = &work, .al = a };

    // Selection headers enclosing block `b` (up to the first loop).
    const headersLive = struct {
        fn f2(fn_: *const ir.Function, ctx_: []const u32, parent_: []const u32, bl: []bool, b: u32, mk: Mark, nn: u32) void {
            var c = ctx_[b];
            while (c != nn) : (c = parent_[c]) {
                switch (fn_.blocks.items[c].merge) {
                    // (Marked headers had theirs marked too.)
                    .selection => if (bl[c]) return else {
                        bl[c] = true;
                        if (fn_.blocks.items[c].term == .cond_br) mk.ref(fn_.blocks.items[c].term.cond_br.cond);
                        if (fn_.blocks.items[c].term == .@"switch") mk.ref(fn_.blocks.items[c].term.@"switch".value);
                    },
                    else => {},
                }
            }
        }
    }.f2;

    // Locals used only through loads, stores and access chains (not
    // escaping): a store into one (whole or through a chain) is live when a
    // load from it is. root_of[x]: the local a pointer `x` is rooted at.
    const root_of = try a.alloc(u32, ni);
    @memset(root_of, none);
    for (f.insts.items, 0..) |inst, i| {
        if (inst.op == .local_var and inst.ptr == .function) root_of[i] = @intCast(i);
    }
    {
        var grew = true;
        while (grew) {
            grew = false;
            for (f.insts.items, 0..) |inst, i| {
                if (root_of[i] != none) continue;
                if (inst.op != .access) continue;
                const rb = root_of[inst.op.access.base.index()];
                if (rb == none) continue;
                root_of[i] = rb;
                grew = true;
            }
        }
    }
    const escapes = try a.alloc(bool, ni);
    @memset(escapes, false);
    {
        const Esc = struct {
            f: *const ir.Function,
            escapes: []bool,
            root_of: []const u32,
            user: Ref,
            pub fn use(c: @This(), x: Ref) void {
                if (x == .none or x.index() >= c.escapes.len) return;
                const rt = c.root_of[x.index()];
                if (rt == std.math.maxInt(u32)) return;
                const fine = switch (c.f.inst(c.user).op) {
                    .load => true,
                    .store => |st| st.ptr == x and st.value != x,
                    .access => |acc| acc.base == x,
                    else => false,
                };
                if (!fine) c.escapes[rt] = true;
            }
        };
        for (f.blocks.items) |b| for (b.insts.items) |r| opt.eachOperand(f.inst(r).op, Esc{ .f = f, .escapes = escapes, .root_of = root_of, .user = r });
        for (f.blocks.items) |b| switch (b.term) {
            .ret => |v| if (v != .none and root_of[v.index()] != none) {
                escapes[root_of[v.index()]] = true;
            },
            else => {},
        };
    }
    var stores_of: std.AutoHashMapUnmanaged(u32, std.ArrayList(Ref)) = .empty;
    for (f.blocks.items) |b| for (b.insts.items) |r| switch (f.inst(r).op) {
        .store => |st| {
            const rt = root_of[st.ptr.index()];
            if (rt == none or escapes[rt]) continue;
            const gop = try stores_of.getOrPut(a, rt);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(a, r);
        },
        else => {},
    };
    const isLocalStore = struct {
        fn f2(fn_: *const ir.Function, esc: []const bool, roots: []const u32, r: Ref) bool {
            const st = switch (fn_.inst(r).op) {
                .store => |x| x,
                else => return false,
            };
            const rt = roots[st.ptr.index()];
            return rt != std.math.maxInt(u32) and !esc[rt];
        }
    }.f2;

    // Roots.
    for (f.blocks.items, 0..) |b, bi| {
        if (!seen[bi]) continue;
        for (b.insts.items) |r| if (!isPure(f, f.inst(r).op) and !isLocalStore(f, escapes, root_of, r)) mark.ref(r);
        switch (b.term) {
            .ret => |v| {
                mark.ref(v);
                headersLive(f, ctx, parent, branch_live, @intCast(bi), mark, none);
            },
            .discard, .@"unreachable", .none => headersLive(f, ctx, parent, branch_live, @intCast(bi), mark, none),
            .cond_br => |c| {
                // Branches not heading a selection (a loop's, and breaks)
                // stay, unless they are a loop's: those are live when the
                // loop is (below).
                if (b.merge != .selection and loop_of[bi] == none) {
                    mark.ref(c.cond);
                    headersLive(f, ctx, parent, branch_live, @intCast(bi), mark, none);
                }
            },
            .@"switch" => |sw| {
                if (b.merge != .selection) mark.ref(sw.value);
                // (Switches stay.)
                branch_live[bi] = true;
                mark.ref(sw.value);
                headersLive(f, ctx, parent, branch_live, @intCast(bi), mark, none);
            },
            .br => {},
        }
        // A way out of enclosing selections other than through their
        // merges (a loop's break or continue) keeps the selections left.
        for (try successors(a, b.term)) |s| {
            if (s == .none) continue;
            var c = ctx[bi];
            var left: std.ArrayList(u32) = .empty;
            const exits = while (c != none) : (c = parent[c]) switch (f.blocks.items[c].merge) {
                .selection => |mb| {
                    if (mb == s) break false; // the selection's own way out
                    try left.append(a, c);
                },
                .loop => |l| break (l.merge == s or l.@"continue" == s),
                .none => {},
            } else false;
            if (!exits) continue;
            for (left.items) |h| if (!branch_live[h]) {
                branch_live[h] = true;
                if (f.blocks.items[h].term == .cond_br) mark.ref(f.blocks.items[h].term.cond_br.cond);
                headersLive(f, ctx, parent, branch_live, h, mark, none);
            };
        }
    }
    // The selection header each merge block closes.
    const merge_of = try a.alloc(u32, nb);
    @memset(merge_of, none);
    for (f.blocks.items, 0..) |hb, hi| switch (hb.merge) {
        .selection => |mb| merge_of[mb.index()] = @intCast(hi),
        else => {},
    };
    // Loops whose control is live.
    const loop_live = try a.alloc(bool, nb);
    @memset(loop_live, false);
    var loops_changed = true;
    while (loops_changed) {
    loops_changed = false;
    // Propagate.
    while (work.pop()) |r| {
        const inst = f.inst(r);
        opt.eachOperand(inst.op, mark);
        // A live load of a local: the stores into it.
        if (inst.op == .load) {
            const rt = root_of[inst.op.load.index()];
            if (rt != none) if (stores_of.get(rt)) |list| {
                for (list.items) |st| mark.ref(st);
            };
        }
        const bi = block_of[r.index()];
        // (Where a local, a constant or a reference to a global sits says
        // nothing about which branch was taken.)
        const placed = switch (inst.op) {
            .local_var, .constant, .undef, .param, .global, .spec_constant => false,
            else => true,
        };
        if (bi != none and placed) {
            headersLive(f, ctx, parent, branch_live, bi, mark, none);
            // A live phi: the selections that chose which edge reaches it
            // (around an incoming block but not around the phi's block).
            if (inst.op == .phi) for (inst.op.phi) |in| {
                var c = ctx[in.block.index()];
                while (c != none) : (c = parent[c]) {
                    // Stop at a construct around the phi's block too.
                    var around = false;
                    var d = ctx[bi];
                    while (d != none) : (d = parent[d]) if (d == c) {
                        around = true;
                        break;
                    };
                    if (around) break;
                    if (f.blocks.items[c].merge == .selection and !branch_live[c]) {
                        branch_live[c] = true;
                        if (f.blocks.items[c].term == .cond_br) mark.ref(f.blocks.items[c].term.cond_br.cond);
                        headersLive(f, ctx, parent, branch_live, c, mark, none);
                    }
                }
            };
            if (inst.op == .phi) {
                // The header whose merge this block is.
                if (merge_of[bi] != none and !branch_live[merge_of[bi]]) {
                    const hi = merge_of[bi];
                    branch_live[hi] = true;
                    const hb = f.blocks.items[hi];
                    if (hb.term == .cond_br) mark.ref(hb.term.cond_br.cond);
                    headersLive(f, ctx, parent, branch_live, hi, mark, none);
                }
            }
        }
    }

    // A loop is live if anything live is inside it, or a block in it
    // returns, discards, or leaves it other than by its merge.
    for (f.blocks.items, 0..) |b, bi| {
        if (!seen[bi]) continue;
        const l = loop_of[bi];
        if (l == none) continue;
        var reason = false;
        for (b.insts.items) |r| if (live[r.index()] and placedOp(f.inst(r).op)) {
            reason = true;
            break;
        };
        switch (b.term) {
            .ret, .discard, .@"unreachable", .none => reason = true,
            else => {},
        }
        if (!reason) for (try successors(a, b.term)) |s2| {
            if (s2 == .none) continue;
            // Inside this loop, or its merge: fine.
            if (s2 == f.blocks.items[l].merge.loop.merge) continue;
            var c = loop_of[s2.index()];
            var inside = false;
            while (c != none) : (c = if (parent[c] == none) none else loop_of[parent[c]]) if (c == l) {
                inside = true;
                break;
            };
            if (!inside and s2.index() != l) reason = true;
        };
        if (!reason) continue;
        // This loop and those around it.
        var c = l;
        while (c != none) : (c = if (parent[c] == none) none else loop_of[parent[c]]) {
            if (loop_live[c]) break;
            loop_live[c] = true;
            loops_changed = true;
        }
    }
    // The control of live loops: branches in them not heading a selection.
    if (loops_changed) for (f.blocks.items, 0..) |b, bi| {
        if (!seen[bi] or loop_of[bi] == none or !loop_live[loop_of[bi]]) continue;
        switch (b.term) {
            .cond_br => |cb| if (b.merge != .selection and !live[cb.cond.index()]) {
                mark.ref(cb.cond);
                headersLive(f, ctx, parent, branch_live, @intCast(bi), mark, none);
            },
            else => {},
        }
    };
    }
    // Dead loops: their header goes to their merge.
    var changed = false;
    for (f.blocks.items, 0..) |*b, bi| {
        if (!seen[bi] or b.merge != .loop or loop_live[bi]) continue;
        b.term = .{ .br = b.merge.loop.merge };
        b.merge = .none;
        changed = true;
    }
    // Selections whose branch is not live go to their merge.
    for (f.blocks.items, 0..) |*b, bi| {
        if (!seen[bi] or b.merge != .selection or branch_live[bi]) continue;
        if (b.term != .cond_br) continue;
        b.term = .{ .br = b.merge.selection };
        b.merge = .none;
        b.selection_control = .none;
        changed = true;
    }
    // Instructions not live go (in blocks; locals stay declared).
    for (f.blocks.items) |*b| {
        var out: std.ArrayList(Ref) = .empty;
        for (b.insts.items) |r| {
            if (live[r.index()] or f.inst(r).op == .local_var) try out.append(a, r);
        }
        b.insts = out;
    }
    if (changed) try opt.fixPhis(a, f);
}

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
