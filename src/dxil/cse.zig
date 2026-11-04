//! Common subexpression elimination over the dominator tree, as dxc's
//! EarlyCSE and GVN do it: an instruction that computes what one in a
//! dominating position already computed (same operation, same operands)
//! is replaced by it. Only instructions without effects and whose result
//! depends on nothing but their operands: arithmetic, comparisons, casts,
//! selects, address computations, readnone dx.op calls, and the readonly
//! ones that read what cannot change during the shader (constant buffer
//! loads, handle creation).
//!
//! Inlining every call and lowering each use of a cbuffer field to its own
//! load leaves many such repeats.

const std = @import("std");
const Allocator = std.mem.Allocator;
const module = @import("module.zig");
const promote = @import("promote.zig");
const stats = @import("../stats.zig");

const Value = module.Value;
const Inst = module.Inst;

const none = std.math.maxInt(u32);

fn isTerminator(inst: Inst) bool {
    return switch (inst.op) {
        .ret, .br, .@"switch", .@"unreachable" => true,
        else => false,
    };
}

/// dx.op readonly operations that read only what a dispatch cannot change:
/// CreateHandle, CBufferLoad, CBufferLoadLegacy, CreateHandleForLib,
/// CreateHandleFromBinding, CreateHandleFromHeap.
fn stableReadonly(opcode: i64) bool {
    return switch (opcode) {
        57, 58, 59, 160, 217, 218 => true,
        else => false,
    };
}

fn eligible(m: *const module.Module, inst: Inst) bool {
    return switch (inst.op) {
        .binop, .cast, .cmp, .select, .extractvalue, .gep, .extractelement, .insertelement => true,
        .call => |c| {
            const callee = m.functions.items[c.callee];
            if (callee.num_blocks != 0 or !std.mem.startsWith(u8, callee.name, "dx.op.")) return false;
            switch (callee.attrs) {
                .nounwind_readnone => return true,
                .nounwind_readonly => {
                    if (c.args.len == 0 or c.args[0] != .constant) return false;
                    return switch (m.constants.items[c.args[0].constant].kind) {
                        .int => |k| stableReadonly(k),
                        else => false,
                    };
                },
                else => return false,
            }
        },
        else => false,
    };
}

/// An instruction's identity as bytes: its operation, type, the fields
/// that are not operands, and its operands (resolved through replaced
/// instructions).
const Key = struct {
    buf: std.ArrayList(u8) = .empty,
    a: Allocator,
    repl: []const ?Value,
    failed: bool = false,

    fn resolve(k: *const Key, v: Value) Value {
        var x = v;
        while (x == .inst) {
            const r = k.repl[x.inst] orelse break;
            x = r;
        }
        return x;
    }

    fn word(k: *Key, w: u64) void {
        k.buf.appendSlice(k.a, std.mem.asBytes(&w)) catch {
            k.failed = true;
        };
    }

    pub fn visit(k: *Key, v: Value, _: promote.Role) Value {
        const x = k.resolve(v);
        const tag: u64 = @backingInt(std.meta.activeTag(x));
        const id: u64 = switch (x) {
            inline else => |i| i,
        };
        k.word(tag << 32 | id);
        return v;
    }

    fn build(k: *Key, inst: Inst) Allocator.Error![]const u8 {
        k.buf.clearRetainingCapacity();
        k.word(@backingInt(std.meta.activeTag(inst.op)));
        k.word(inst.ty);
        switch (inst.op) {
            .binop => |b| k.word(@as(u64, @backingInt(b.op)) << 32 | b.flags),
            .cast => |c| k.word(@backingInt(c.op)),
            .cmp => |c| k.word(c.pred),
            .extractvalue => |x| k.word(x.index),
            .gep => |g| k.word(g.elem),
            .call => |c| k.word(c.callee),
            else => {},
        }
        var copy = inst;
        try promote.operands(false, k.a, &copy, k);
        if (k.failed) return error.OutOfMemory;
        return k.buf.items;
    }
};

/// Replaces `func`'s repeated computations; true if any.
pub fn run(a: Allocator, m: *module.Module, func: u32) Allocator.Error!bool {
    const zone = stats.begin(.cse);
    defer zone.end();
    const f = &m.functions.items[func];
    const insts = f.insts.items;
    const n: u32 = @intCast(insts.len);
    const nb = f.num_blocks;
    if (n == 0 or nb == 0) return false;

    const block_start = try a.alloc(u32, nb + 1);
    {
        var b: u32 = 0;
        block_start[0] = 0;
        for (insts, 0..) |inst, i| if (isTerminator(inst)) {
            if (b >= nb) return false;
            b += 1;
            block_start[b] = @intCast(i + 1);
        };
        if (b != nb or block_start[nb] != n) return false;
    }
    // Successors, predecessors.
    const succ_off = try a.alloc(u32, nb + 1);
    var succs: std.ArrayList(u32) = .empty;
    for (0..nb) |b| {
        succ_off[b] = @intCast(succs.items.len);
        switch (insts[block_start[b + 1] - 1].op) {
            .br => |br| {
                try succs.append(a, br.then);
                if (br.@"else") |e| try succs.append(a, e);
            },
            .@"switch" => |sw| {
                try succs.append(a, sw.default);
                for (sw.cases) |c| try succs.append(a, c.block);
            },
            else => {},
        }
    }
    succ_off[nb] = @intCast(succs.items.len);
    const pred_off = try a.alloc(u32, nb + 1);
    @memset(pred_off, 0);
    for (succs.items) |s| pred_off[s + 1] += 1;
    for (1..nb + 1) |b| pred_off[b] += pred_off[b - 1];
    const preds = try a.alloc(u32, succs.items.len);
    {
        const fill = try a.dupe(u32, pred_off[0..nb]);
        for (0..nb) |b| for (succs.items[succ_off[b]..succ_off[b + 1]]) |s| {
            preds[fill[s]] = @intCast(b);
            fill[s] += 1;
        };
    }
    // Reverse postorder, then immediate dominators (Cooper, Harvey and
    // Kennedy).
    const rpo_index = try a.alloc(u32, nb);
    @memset(rpo_index, none);
    const rpo = try a.alloc(u32, nb);
    var nr: u32 = 0;
    {
        const post = try a.alloc(u32, nb);
        var np: u32 = 0;
        const seen = try a.alloc(bool, nb);
        @memset(seen, false);
        const Frame = struct { b: u32, next: u32 };
        var stack: std.ArrayList(Frame) = .empty;
        try stack.append(a, .{ .b = 0, .next = succ_off[0] });
        seen[0] = true;
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            if (top.next < succ_off[top.b + 1]) {
                const s = succs.items[top.next];
                top.next += 1;
                if (!seen[s]) {
                    seen[s] = true;
                    try stack.append(a, .{ .b = s, .next = succ_off[s] });
                }
            } else {
                post[np] = top.b;
                np += 1;
                _ = stack.pop();
            }
        }
        for (0..np) |k| {
            rpo[k] = post[np - 1 - k];
            rpo_index[rpo[k]] = @intCast(k);
        }
        nr = np;
    }
    const idom = try a.alloc(u32, nb);
    @memset(idom, none);
    idom[0] = 0;
    {
        var changed = true;
        while (changed) {
            changed = false;
            for (rpo[1..nr]) |b| {
                var new: u32 = none;
                for (preds[pred_off[b]..pred_off[b + 1]]) |p| {
                    if (idom[p] == none) continue;
                    if (new == none) {
                        new = p;
                        continue;
                    }
                    var x = p;
                    var y = new;
                    while (x != y) {
                        while (rpo_index[x] > rpo_index[y]) x = idom[x];
                        while (rpo_index[y] > rpo_index[x]) y = idom[y];
                    }
                    new = x;
                }
                if (new != idom[b]) {
                    idom[b] = new;
                    changed = true;
                }
            }
        }
    }
    // Dominator tree children, in reverse postorder.
    const child_off = try a.alloc(u32, nb + 1);
    @memset(child_off, 0);
    for (rpo[1..nr]) |b| child_off[idom[b] + 1] += 1;
    for (1..nb + 1) |b| child_off[b] += child_off[b - 1];
    const children = try a.alloc(u32, if (nr > 0) nr - 1 else 0);
    {
        const fill = try a.dupe(u32, child_off[0..nb]);
        for (rpo[1..nr]) |b| {
            children[fill[idom[b]]] = b;
            fill[idom[b]] += 1;
        }
    }

    const repl = try a.alloc(?Value, n);
    @memset(repl, null);
    // The keys of the instructions available (in the dominating blocks),
    // to the instruction.
    var table: std.StringHashMapUnmanaged(u32) = .empty;
    var added: std.ArrayList([]const u8) = .empty;
    var key: Key = .{ .a = a, .repl = repl };
    var found = false;

    const Frame = struct { b: u32, next: u32, mark: usize };
    var stack: std.ArrayList(Frame) = .empty;
    try stack.append(a, .{ .b = 0, .next = child_off[0], .mark = 0 });
    var entered = true;
    while (stack.items.len > 0) {
        const top = &stack.items[stack.items.len - 1];
        if (entered) {
            entered = false;
            top.mark = added.items.len;
            for (block_start[top.b]..block_start[top.b + 1]) |i| {
                const inst = insts[i];
                if (!eligible(m, inst)) continue;
                // (The key is built in one buffer, and kept only if new.)
                const gop = try table.getOrPut(a, try key.build(inst));
                if (gop.found_existing) {
                    repl[i] = .{ .inst = gop.value_ptr.* };
                    found = true;
                } else {
                    gop.key_ptr.* = try a.dupe(u8, key.buf.items);
                    gop.value_ptr.* = @intCast(i);
                    try added.append(a, gop.key_ptr.*);
                }
            }
        }
        if (top.next < child_off[top.b + 1]) {
            const c = children[top.next];
            top.next += 1;
            try stack.append(a, .{ .b = c, .next = child_off[c], .mark = 0 });
            entered = true;
        } else {
            for (added.items[top.mark..]) |k| _ = table.remove(k);
            added.shrinkRetainingCapacity(top.mark);
            _ = stack.pop();
        }
    }
    if (!found) return false;

    // Renumber without the replaced instructions.
    const index = try a.alloc(u32, n);
    var count: u32 = 0;
    for (0..n) |i| {
        index[i] = count;
        if (repl[i] == null) count += 1;
    }
    const Map = struct {
        repl: []const ?Value,
        index: []const u32,
        pub fn visit(ctx: *@This(), v: Value, _: promote.Role) Value {
            var x = v;
            while (x == .inst) {
                const r = ctx.repl[x.inst] orelse break;
                x = r;
            }
            return if (x == .inst) .{ .inst = ctx.index[x.inst] } else x;
        }
    };
    var map: Map = .{ .repl = repl, .index = index };
    const ma = m.allocator();
    var out: std.ArrayList(Inst) = .empty;
    try out.ensureTotalCapacityPrecise(ma, count);
    for (insts, 0..) |inst, i| {
        if (repl[i] != null) continue;
        var copy = inst;
        try promote.operands(true, ma, &copy, &map);
        out.appendAssumeCapacity(copy);
    }
    f.insts = out;
    return true;
}
