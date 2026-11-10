//! Dead code in a finished module, as spirv-opt's dead code and dead
//! variable elimination leave dxc's SPIR-V: results of instructions without
//! side effects that nothing uses, and resource, uniform and private
//! variables nothing uses (with their names, decorations and entry point
//! interface entries).
//!
//! Unreal's Vulkan format reflects every descriptor binding of a module. A
//! buffer only dead code reads (a `static const` bindless handle evaluated
//! and never used, its index read from $Globals) is a binding dxc's SPIR-V
//! does not have, and $Globals beside a root parameter buffer fails
//! Unreal's checks.
//!
//! Uses are counted conservatively: every operand word of an instruction
//! that is the id of something counts, so a literal that happens to equal
//! an id can only keep an instruction, never remove one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const builder = @import("builder.zig");

const Section = builder.Section;

/// Opcodes with a result type and result id and no side effects.
fn removable(op: u16, words: []const u32) bool {
    return switch (op) {
        // OpLoad, unless volatile.
        61 => !(words.len > 4 and words[4] & 1 != 0),
        // OpAccessChain, OpInBoundsAccessChain, OpCopyObject.
        65, 66, 83 => true,
        // OpVectorExtractDynamic, OpVectorShuffle, OpCompositeConstruct,
        // OpCompositeExtract, OpCompositeInsert.
        77, 79, 80, 81, 82 => true,
        // Conversions: OpConvertUToF, OpUConvert, OpSConvert, OpBitcast.
        112, 113, 114, 124 => true,
        // Integer and float arithmetic without traps: OpIAdd, OpFAdd,
        // OpISub, OpFSub, OpIMul, OpFMul.
        128, 129, 130, 131, 132, 133 => true,
        // OpLogicalOr, OpLogicalAnd, OpLogicalNot, OpSelect, OpIEqual,
        // OpINotEqual, OpUGreaterThan, OpSGreaterThan, OpUGreaterThanEqual,
        // OpSGreaterThanEqual, OpULessThan, OpSLessThan.
        166, 167, 168, 169, 170, 171, 172, 173, 174, 175, 176, 177 => true,
        // Shifts and bitwise: OpShiftRightLogical, OpShiftRightArithmetic,
        // OpShiftLeftLogical, OpBitwiseOr, OpBitwiseXor, OpBitwiseAnd.
        194, 195, 196, 197, 198, 199 => true,
        // OpPhi.
        245 => true,
        else => false,
    };
}

/// Storage classes of variables to drop when unused: UniformConstant,
/// Uniform, Private, StorageBuffer.
fn droppableStorage(sc: u32) bool {
    return sc == 0 or sc == 2 or sc == 6 or sc == 12;
}

const Inst = struct { section: Section, start: usize, len: usize };

fn instructions(a: Allocator, words: []const u32, section: Section, out: *std.ArrayList(Inst)) !void {
    var pos: usize = 0;
    while (pos < words.len) {
        const len = @max(words[pos] >> 16, 1);
        try out.append(a, .{ .section = section, .start = pos, .len = len });
        pos += len;
    }
}

pub fn run(a: Allocator, b: *builder.Builder) !void {
    const bound = b.next_id;
    const uses = try a.alloc(u32, bound);
    @memset(uses, 0);
    // Instructions of the sections that use ids (not names, decorations or
    // the entry point interfaces).
    var insts: std.ArrayList(Inst) = .empty;
    for ([_]Section{ .execution_modes, .types_globals, .functions }) |sec| {
        try instructions(a, b.sections.getPtr(sec).items, sec, &insts);
    }
    for (insts.items) |in| {
        const w = b.sections.getPtr(in.section).items[in.start..][0..in.len];
        for (w[1..]) |x| if (x < bound) {
            uses[x] += 1;
        };
    }
    // (Every id the entry point declares stays: its function.)
    {
        var eps: std.ArrayList(Inst) = .empty;
        try instructions(a, b.sections.getPtr(.entry_points).items, .entry_points, &eps);
        for (eps.items) |in| {
            const w = b.sections.getPtr(.entry_points).items[in.start..][0..in.len];
            if (w.len > 2 and w[2] < bound) uses[w[2]] += 1;
        }
    }
    const dead = try a.alloc(bool, bound);
    @memset(dead, false);
    const gone = try a.alloc(bool, insts.items.len);
    @memset(gone, false);
    var changed = true;
    while (changed) {
        changed = false;
        for (insts.items, 0..) |in, k| {
            if (gone[k]) continue;
            const w = b.sections.getPtr(in.section).items[in.start..][0..in.len];
            const op: u16 = @truncate(w[0]);
            const ok = switch (in.section) {
                .functions => removable(op, w) and w.len >= 3,
                .types_globals => op == 59 and w.len >= 4 and droppableStorage(w[3]), // OpVariable
                else => false,
            };
            if (!ok) continue;
            const result = w[2];
            // (The instruction's own result word counted once.)
            if (result >= bound or uses[result] > 1) continue;
            gone[k] = true;
            dead[result] = true;
            changed = true;
            for (w[1..]) |x| if (x < bound and uses[x] > 0) {
                uses[x] -= 1;
            };
        }
    }
    // Rebuild the sections.
    for ([_]Section{ .types_globals, .functions }) |sec| {
        const s = b.sections.getPtr(sec);
        var out: std.ArrayList(u32) = .empty;
        for (insts.items, 0..) |in, k| {
            if (in.section != sec or gone[k]) continue;
            try out.appendSlice(a, s.items[in.start..][0..in.len]);
        }
        s.clearRetainingCapacity();
        try s.appendSlice(b.gpa, out.items);
    }
    // Names and decorations of what is gone.
    for ([_]Section{ .debug_names, .annotations }) |sec| {
        const s = b.sections.getPtr(sec);
        var list: std.ArrayList(Inst) = .empty;
        try instructions(a, s.items, sec, &list);
        var out: std.ArrayList(u32) = .empty;
        for (list.items) |in| {
            const w = s.items[in.start..][0..in.len];
            const op: u16 = @truncate(w[0]);
            // OpName, OpDecorate, OpDecorateId, OpDecorateString.
            const target_gone = (op == 5 or op == 71 or op == 332 or op == 5632) and w.len > 1 and w[1] < bound and dead[w[1]];
            if (!target_gone) try out.appendSlice(a, w);
        }
        s.clearRetainingCapacity();
        try s.appendSlice(b.gpa, out.items);
    }
    // Entry point interfaces: OpEntryPoint model, function, name, ids.
    {
        const s = b.sections.getPtr(.entry_points);
        var list: std.ArrayList(Inst) = .empty;
        try instructions(a, s.items, .entry_points, &list);
        var out: std.ArrayList(u32) = .empty;
        for (list.items) |in| {
            const w = s.items[in.start..][0..in.len];
            if (@as(u16, @truncate(w[0])) != 15 or w.len < 4) {
                try out.appendSlice(a, w);
                continue;
            }
            // The name: words up to the one with a zero byte.
            var p: usize = 3;
            while (p < w.len) : (p += 1) {
                const x = w[p];
                if (x & 0xff == 0 or x & 0xff00 == 0 or x & 0xff0000 == 0 or x & 0xff000000 == 0) break;
            }
            p += 1;
            var ids: std.ArrayList(u32) = .empty;
            for (w[@min(p, w.len)..]) |id| if (id >= bound or !dead[id]) try ids.append(a, id);
            const n: u32 = @intCast(@min(p, w.len) + ids.items.len);
            try out.append(a, (n << 16) | 15);
            try out.appendSlice(a, w[1..@min(p, w.len)]);
            try out.appendSlice(a, ids.items);
        }
        s.clearRetainingCapacity();
        try s.appendSlice(b.gpa, out.items);
    }
}
