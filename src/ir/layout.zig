//! Constant buffer layouts.
//!
//! `dx_legacy` is D3D's cbuffer packing (DXIL): 16-byte registers; vectors
//! may not straddle a register; arrays, structs and matrices start on a
//! register and every array element but the last fills whole registers.
//!
//! `vk_relaxed` is dxc's default SPIR-V layout for cbuffers: std140 with
//! relaxed vector alignment (component-size aligned unless the vector
//! would straddle a 16-byte boundary); arrays and structs are 16-byte
//! aligned and padded to multiples of 16.
//!
//! Matrices are column-major (dxc's default without -Zpr).

const std = @import("std");
const types = @import("../sema/types.zig");

const TypeId = types.TypeId;
const TypeTable = types.TypeTable;

pub const Rules = enum { dx_legacy, vk_relaxed };

pub const Error = error{Unsupported};

fn scalarSize(t: *const TypeTable, ty: TypeId) u32 {
    const c = t.component(ty).?;
    return switch (c) {
        .double, .int64, .uint64 => 8,
        .int16, .uint16, .float16 => 2,
        else => 4,
    };
}

fn roundUp(v: u32, a: u32) u32 {
    return (v + a - 1) / a * a;
}

/// Size in bytes (for dx_legacy, the last element / member is not padded).
pub fn sizeOf(t: *const TypeTable, ty: TypeId, rules: Rules) Error!u32 {
    switch (t.get(ty)) {
        .scalar, .@"enum" => return scalarSize(t, ty),
        .vector => |v| return v.len * scalarSize(t, ty),
        .matrix => |m| {
            // Column-major: one register per column of `rows` components.
            const col = m.rows * scalarSize(t, ty);
            return switch (rules) {
                .dx_legacy => (m.cols - 1) * 16 + col,
                .vk_relaxed => m.cols * 16,
            };
        },
        .array => |a| {
            const stride = try arrayStride(t, a.elem, rules);
            return switch (rules) {
                .dx_legacy => (a.len - 1) * stride + try sizeOf(t, a.elem, rules),
                .vk_relaxed => a.len * stride,
            };
        },
        .@"struct" => |s| {
            var off: u32 = 0;
            for (s.fields.items) |f| off = try place(t, off, f.type, rules) + try sizeOf(t, f.type, rules);
            return switch (rules) {
                .dx_legacy => off,
                .vk_relaxed => roundUp(off, 16),
            };
        },
        else => return error.Unsupported,
    }
}

/// Byte distance between array elements.
pub fn arrayStride(t: *const TypeTable, elem: TypeId, rules: Rules) Error!u32 {
    return roundUp(try sizeOf(t, elem, rules), 16);
}

/// Offset where a member of type `ty` goes when the previous one ended at
/// `off`.
pub fn place(t: *const TypeTable, off: u32, ty: TypeId, rules: Rules) Error!u32 {
    switch (t.get(ty)) {
        .scalar, .@"enum", .vector => {
            const size = try sizeOf(t, ty, rules);
            const comp = scalarSize(t, ty);
            var o = roundUp(off, comp);
            // No straddling a 16-byte register.
            if (o / 16 != (o + size - 1) / 16) o = roundUp(o, 16);
            return o;
        },
        .matrix, .array, .@"struct" => return roundUp(off, 16),
        else => return error.Unsupported,
    }
}

/// Offsets of a struct's fields.
pub fn fieldOffsets(a: std.mem.Allocator, t: *const TypeTable, info: *const types.StructInfo, rules: Rules) (Error || std.mem.Allocator.Error)![]u32 {
    const out = try a.alloc(u32, info.fields.items.len);
    var off: u32 = 0;
    for (info.fields.items, out) |f, *o| {
        o.* = try place(t, off, f.type, rules);
        off = o.* + try sizeOf(t, f.type, rules);
    }
    return out;
}

/// Byte offset of flattened component `k` of a value of type `ty` (row-major
/// component order for matrices, as the IR flattens them).
pub fn componentOffset(a: std.mem.Allocator, t: *const TypeTable, ty: TypeId, k: u32, rules: Rules) (Error || std.mem.Allocator.Error)!u32 {
    switch (t.get(ty)) {
        .scalar, .@"enum" => return 0,
        .vector => return k * scalarSize(t, ty),
        .matrix => |m| {
            const r = k / m.cols;
            const c = k % m.cols;
            return c * 16 + r * scalarSize(t, ty);
        },
        .array => |arr| {
            const n = try flatCount(t, arr.elem);
            return (k / n) * try arrayStride(t, arr.elem, rules) + try componentOffset(a, t, arr.elem, k % n, rules);
        },
        .@"struct" => |s| {
            const offs = try fieldOffsets(a, t, s, rules);
            var kk = k;
            for (s.fields.items, offs) |f, o| {
                const n = try flatCount(t, f.type);
                if (kk < n) return o + try componentOffset(a, t, f.type, kk, rules);
                kk -= n;
            }
            return error.Unsupported;
        },
        else => return error.Unsupported,
    }
}

pub fn flatCount(t: *const TypeTable, ty: TypeId) Error!u32 {
    return switch (t.get(ty)) {
        .scalar, .@"enum" => 1,
        .vector => |v| v.len,
        .matrix => |m| @as(u32, m.rows) * m.cols,
        .array => |a| a.len * try flatCount(t, a.elem),
        .@"struct" => |s| blk: {
            var n: u32 = 0;
            for (s.fields.items) |f| n += try flatCount(t, f.type);
            break :blk n;
        },
        else => error.Unsupported,
    };
}

test "dx legacy packing" {
    var t = try TypeTable.init(std.testing.allocator);
    defer t.deinit();
    const f = try t.scalar(.float);
    const f2 = try t.vector(.float, 2);
    const f3 = try t.vector(.float, 3);
    const f4a = try t.array(try t.vector(.float, 4), 2);
    try std.testing.expectEqual(@as(u32, 4), try place(&t, 4, f2, .dx_legacy));
    try std.testing.expectEqual(@as(u32, 16), try place(&t, 12, f3, .dx_legacy));
    try std.testing.expectEqual(@as(u32, 32), try sizeOf(&t, f4a, .dx_legacy));
    try std.testing.expectEqual(@as(u32, 20), try sizeOf(&t, try t.array(f, 2), .dx_legacy));
    try std.testing.expectEqual(@as(u32, 32), try sizeOf(&t, try t.array(f, 2), .vk_relaxed));
}
