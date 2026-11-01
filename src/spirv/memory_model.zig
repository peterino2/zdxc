//! The Vulkan memory model (-fspv-use-vulkan-memory-model, or modules that
//! need it): a port of spirv-opt's UpgradeMemoryModel pass, which dxc runs
//! on its output. Coherent and Volatile decorations become flags on the
//! loads, stores, image reads / writes and atomics that reach them, and
//! Device scopes become QueueFamily.

const std = @import("std");
const builder = @import("builder.zig");
const op_caps = @import("op_caps.zig");
const Id = builder.Id;

const coherent_dec = 23;
const volatile_dec = 21;
const scope_device = 1;
const scope_workgroup = 2;
const scope_queue_family = 5;

const Attrs = struct { coherent: bool = false, @"volatile": bool = false };

fn Pass(comptime E: type) type {
    return struct {
        e: E,
        a: std.mem.Allocator,
        /// Result id -> (section, word offset) of its instruction.
        defs: std.AutoHashMapUnmanaged(Id, struct { sec: builder.Section, at: usize }) = .empty,
        /// Decorations: (target, member or maxInt, decoration).
        decs: std.ArrayList([3]u32) = .empty,

        const Self = @This();

        fn words(p: *Self, id: Id) ?[]const u32 {
            const d = p.defs.get(id) orelse return null;
            const s = p.e.b.sections.get(d.sec).items;
            return s[d.at..][0 .. s[d.at] >> 16];
        }

        fn opcode(w: []const u32) u32 {
            return w[0] & 0xffff;
        }

        fn typeOf(p: *Self, id: Id) ?Id {
            const w = p.words(id) orelse return null;
            const l = op_caps.resultLayout(opcode(w));
            return if (l.ty) |t| w[1 + t] else null;
        }

        /// The storage class of a pointer-typed value.
        fn storageOf(p: *Self, id: Id) ?u32 {
            const t = p.words(p.typeOf(id) orelse return null) orelse return null;
            return if (opcode(t) == 32) t[2] else null;
        }

        fn constValue(p: *Self, id: Id) ?u32 {
            const w = p.words(id) orelse return null;
            return if (opcode(w) == 43) w[3] else null;
        }

        fn hasDec(p: *Self, id: Id, member: u32, dec: u32) bool {
            for (p.decs.items) |d| {
                if (d[0] != id or d[2] != dec) continue;
                if (d[1] == std.math.maxInt(u32) or member == std.math.maxInt(u32) or d[1] == member) return true;
            }
            return false;
        }

        /// Coherent / Volatile of a struct member reached through
        /// `indices` (innermost last), then of any type below it.
        fn checkType(p: *Self, ptr_type: Id, indices: []const Id) Attrs {
            var r: Attrs = .{};
            var elem = (p.words(ptr_type) orelse return r)[3];
            var i = indices.len;
            while (i > 0 and !(r.coherent and r.@"volatile")) {
                i -= 1;
                const w = p.words(elem) orelse return r;
                switch (opcode(w)) {
                    32 => elem = w[3],
                    30 => {
                        const k = p.constValue(indices[i]) orelse return r;
                        r.coherent = r.coherent or p.hasMemberDec(elem, k, coherent_dec);
                        r.@"volatile" = r.@"volatile" or p.hasMemberDec(elem, k, volatile_dec);
                        elem = w[2 + k];
                    },
                    else => elem = w[2],
                }
            }
            if (!(r.coherent and r.@"volatile")) {
                const all = p.checkAllTypes(elem);
                r.coherent = r.coherent or all.coherent;
                r.@"volatile" = r.@"volatile" or all.@"volatile";
            }
            return r;
        }

        fn hasMemberDec(p: *Self, st: Id, member: u32, dec: u32) bool {
            for (p.decs.items) |d| if (d[0] == st and d[2] == dec and (d[1] == member or d[1] == std.math.maxInt(u32))) return true;
            return false;
        }

        fn checkAllTypes(p: *Self, ty: Id) Attrs {
            var r: Attrs = .{};
            var stack: std.ArrayList(Id) = .empty;
            var seen: std.AutoHashMapUnmanaged(Id, void) = .empty;
            stack.append(p.a, ty) catch return r;
            while (stack.pop()) |t| {
                if ((seen.getOrPut(p.a, t) catch return r).found_existing) continue;
                const w = p.words(t) orelse continue;
                switch (opcode(w)) {
                    30 => {
                        r.coherent = r.coherent or p.hasMemberDec(t, std.math.maxInt(u32), coherent_dec);
                        r.@"volatile" = r.@"volatile" or p.hasMemberDec(t, std.math.maxInt(u32), volatile_dec);
                        if (r.coherent and r.@"volatile") return r;
                        stack.appendSlice(p.a, w[2..]) catch return r;
                    },
                    23, 24, 28, 29 => stack.append(p.a, w[2]) catch return r,
                    32 => stack.append(p.a, w[3]) catch return r,
                    else => {},
                }
            }
            return r;
        }

        fn isPointerLike(p: *Self, id: Id) bool {
            const t = p.words(p.typeOf(id) orelse return false) orelse return false;
            return switch (opcode(t)) {
                25, 27, 32 => true, // image, sampled image, pointer
                else => false,
            };
        }

        /// Follows a pointer (or image) back to the variables it comes
        /// from.
        fn trace(p: *Self, id: Id, indices0: []const Id, visited: *std.AutoHashMapUnmanaged(Id, void)) std.mem.Allocator.Error!Attrs {
            if ((try visited.getOrPut(p.a, id)).found_existing) return .{};
            const w = p.words(id) orelse return .{};
            var indices: std.ArrayList(Id) = .empty;
            try indices.appendSlice(p.a, indices0);
            switch (opcode(w)) {
                59, 55 => { // OpVariable, OpFunctionParameter
                    var r: Attrs = .{ .coherent = p.hasDec(id, 0, coherent_dec), .@"volatile" = p.hasDec(id, 0, volatile_dec) };
                    if (!(r.coherent and r.@"volatile")) {
                        const t = p.checkType(w[1], indices.items);
                        r.coherent = r.coherent or t.coherent;
                        r.@"volatile" = r.@"volatile" or t.@"volatile";
                    }
                    return r;
                },
                65, 66 => { // OpAccessChain, OpInBoundsAccessChain
                    var i = w.len;
                    while (i > 4) {
                        i -= 1;
                        try indices.append(p.a, w[i]);
                    }
                },
                67, 70 => { // OpPtrAccessChain, OpInBoundsPtrAccessChain
                    var i = w.len;
                    while (i > 5) {
                        i -= 1;
                        try indices.append(p.a, w[i]);
                    }
                },
                else => {},
            }
            var r: Attrs = .{};
            const l = op_caps.resultLayout(opcode(w));
            for (w[1..], 0..) |x, k| {
                if ((l.ty != null and k == l.ty.?) or (l.id != null and k == l.id.?)) continue;
                if (!p.isPointerLike(x)) continue;
                const o = try p.trace(x, indices.items, visited);
                r.coherent = r.coherent or o.coherent;
                r.@"volatile" = r.@"volatile" or o.@"volatile";
            }
            return r;
        }

        fn attributes(p: *Self, ptr: Id) std.mem.Allocator.Error!struct { Attrs, u32 } {
            if (p.storageOf(ptr) == 4) return .{ .{ .coherent = true }, scope_workgroup }; // Workgroup
            var visited: std.AutoHashMapUnmanaged(Id, void) = .empty;
            return .{ try p.trace(ptr, &.{}, &visited), scope_queue_family };
        }
    };
}

/// Rewrites the module for the Vulkan memory model (the caller emits the
/// capability, extension and memory model instruction).
pub fn upgrade(e: anytype, has_tess_control: bool) !void {
    var p: Pass(@TypeOf(e)) = .{ .e = e, .a = e.arena };
    for ([_]builder.Section{ .types_globals, .functions }) |sec| {
        const s = e.b.sections.get(sec).items;
        var at: usize = 0;
        while (at < s.len) : (at += s[at] >> 16) {
            const l = op_caps.resultLayout(s[at] & 0xffff);
            if (l.id) |k| try p.defs.put(p.a, s[at + 1 + k], .{ .sec = sec, .at = at });
        }
    }
    {
        const s = e.b.sections.get(.annotations).items;
        var at: usize = 0;
        while (at < s.len) : (at += s[at] >> 16) switch (s[at] & 0xffff) {
            71, 332 => try p.decs.append(p.a, .{ s[at + 1], std.math.maxInt(u32), s[at + 2] }),
            72 => try p.decs.append(p.a, .{ s[at + 1], s[at + 2], s[at + 3] }),
            else => {},
        };
    }

    // Tessellation control shaders that write outputs: barriers that
    // order memory also order output memory.
    var writes_output = false;
    if (has_tess_control) {
        const s = e.b.sections.get(.functions).items;
        var at: usize = 0;
        while (at < s.len and !writes_output) : (at += s[at] >> 16) {
            for (s[at + 1 .. at + (s[at] >> 16)]) |x| if (p.storageOf(x) == 3) {
                writes_output = true;
            };
        }
    }

    const old = try p.a.dupe(u32, e.b.sections.get(.functions).items);
    var out: std.ArrayList(u32) = .empty;
    var at: usize = 0;
    while (at < old.len) : (at += old[at] >> 16) {
        const n = old[at] >> 16;
        var w: std.ArrayList(u32) = .empty;
        try w.appendSlice(p.a, old[at..][0..n]);
        const op = w.items[0] & 0xffff;
        const l = op_caps.resultLayout(op);
        // Word index of in-operand 0.
        const in0: usize = 1 + @as(usize, @intFromBool(l.ty != null)) + @intFromBool(l.id != null);
        switch (op) {
            61, 62 => { // OpLoad, OpStore
                const ptr = w.items[in0];
                var at_s = try p.attributes(ptr);
                const sc = p.storageOf(ptr);
                if (sc == 7 or sc == 6) at_s[0].coherent = false; // Function, Private
                try flags(e, &w, in0 + @as(usize, if (op == 61) 1 else 2), at_s[0], op == 61, false, at_s[1]);
            },
            98, 99, 4290 => { // OpImageRead, OpImageWrite, OpImageSparseRead
                const at_s = try p.attributes(w.items[in0]);
                try flags(e, &w, in0 + @as(usize, if (op == 99) 3 else 2), at_s[0], op != 99, true, at_s[1]);
            },
            else => {},
        }
        if (isAtomic(op)) {
            const at_s = try p.attributes(w.items[in0]);
            if (at_s[0].@"volatile") {
                w.items[in0 + 2] = try e.constUint((p.constValue(w.items[in0 + 2]) orelse 0) | 0x8000);
                if (op == 230 or op == 231) w.items[in0 + 3] = try e.constUint((p.constValue(w.items[in0 + 3]) orelse 0) | 0x8000);
            }
            if (p.constValue(w.items[in0 + 1]) == scope_device) w.items[in0 + 1] = try e.constUint(scope_queue_family);
        } else if (op == 224) { // OpControlBarrier
            if (p.constValue(w.items[2]) == scope_device) w.items[2] = try e.constUint(scope_queue_family);
            if (writes_output) if (p.constValue(w.items[3])) |sem| if (sem & 0x1e != 0) {
                w.items[3] = try e.constUint(sem | 0x1000); // OutputMemory
            };
        } else if (op == 225) { // OpMemoryBarrier
            if (p.constValue(w.items[1]) == scope_device) w.items[1] = try e.constUint(scope_queue_family);
        }
        w.items[0] = (@as(u32, @intCast(w.items.len)) << 16) | op;
        try out.appendSlice(p.a, w.items);
    }
    const fs = e.b.sections.getPtr(.functions);
    fs.clearRetainingCapacity();
    try fs.appendSlice(e.b.gpa, out.items);

    // Coherent and Volatile decorations are gone.
    const an = e.b.sections.getPtr(.annotations);
    var r: usize = 0;
    var wr: usize = 0;
    while (r < an.items.len) {
        const n = an.items[r] >> 16;
        const dec_word: ?u32 = switch (an.items[r] & 0xffff) {
            71, 332 => an.items[r + 2],
            72 => an.items[r + 3],
            else => null,
        };
        if (dec_word == null or (dec_word.? != coherent_dec and dec_word.? != volatile_dec)) {
            std.mem.copyForwards(u32, an.items[wr..][0..n], an.items[r..][0..n]);
            wr += n;
        }
        r += n;
    }
    an.shrinkRetainingCapacity(wr);
}

fn isAtomic(op: u32) bool {
    return switch (op) {
        227...242, 318, 319, 5614, 5615, 6035 => true,
        else => false,
    };
}

/// Memory access (or image operand) flags for a coherent / volatile
/// access at word `k`, then the scope operand.
fn flags(e: anytype, w: *std.ArrayList(u32), k: usize, at: Attrs, visible: bool, image: bool, scope: u32) !void {
    if (!at.coherent and !at.@"volatile") return;
    var f: u32 = if (k < w.items.len) w.items[k] else 0;
    if (at.coherent) {
        if (image) {
            f |= 0x400 | @as(u32, if (visible) 0x200 else 0x100); // NonPrivateTexel, MakeTexelVisible / Available
        } else {
            f |= 0x20 | @as(u32, if (visible) 0x10 else 0x8); // NonPrivatePointer, MakePointerVisible / Available
        }
    }
    if (at.@"volatile") f |= if (image) 0x800 else 0x1;
    if (k < w.items.len) w.items[k] = f else try w.append(e.arena, f);
    if (at.coherent) try w.append(e.arena, try e.constUint(scope));
}
