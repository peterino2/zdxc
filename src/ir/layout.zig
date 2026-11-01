//! Memory layouts of buffer contents.
//!
//! - `dx_legacy`: D3D cbuffer packing (DXIL cbuffers). 16-byte registers;
//!   vectors may not straddle a register; arrays, structs and matrices
//!   start on a register; every array element but the last fills whole
//!   registers.
//! - `vk_relaxed`: dxc's default SPIR-V cbuffer layout. std140 with relaxed
//!   vector placement (component aligned, no 16-byte straddle); arrays and
//!   structs 16-byte aligned and padded; array strides multiples of 16.
//! - `std430`: dxc's default SPIR-V structured-buffer layout. Relaxed vector
//!   placement as above; arrays and structs aligned to their members' std430
//!   alignment (vec3 counts as 16).
//! - `dx_packed`: DXIL structured buffers, tightly packed at scalar
//!   alignment.
//!
//! Matrices are column-major unless their field is `row_major`: a
//! column-major RxC matrix is C vectors of R components.

const std = @import("std");
const types = @import("../sema/types.zig");

const TypeId = types.TypeId;
const TypeTable = types.TypeTable;
const Allocator = std.mem.Allocator;

/// `vk_relaxed` / `std430`: relaxed GLSL std140 / std430 (dxc's Vulkan
/// defaults); `gl_std140` / `gl_std430`: strict ones (-fvk-use-gl-layout);
/// `scalar`: scalar block layout (-fvk-use-scalar-layout).
pub const Rules = enum { dx_legacy, vk_relaxed, std430, dx_packed, gl_std140, gl_std430, scalar };

pub const Error = error{Unsupported} || Allocator.Error;

fn scalarSize(t: *const TypeTable, ty: TypeId) u32 {
    return switch (t.component(ty).?) {
        .double, .int64, .uint64 => 8,
        .int16, .uint16, .float16 => 2,
        else => 4,
    };
}

fn roundUp(v: u32, a: u32) u32 {
    return (v + a - 1) / a * a;
}

/// A matrix as stored: `count` vectors of `len` components.
const MatrixVectors = struct { count: u32, len: u32 };

fn matrixVectors(m: anytype, row_major: bool) MatrixVectors {
    return if (row_major) .{ .count = m.rows, .len = m.cols } else .{ .count = m.cols, .len = m.rows };
}

/// std430 base alignment of an `n`-vector of `s`-byte components.
fn vectorAlign(n: u32, s: u32) u32 {
    return if (n == 1) s else if (n == 2) 2 * s else 4 * s;
}

/// Byte distance between the vectors of a stored matrix.
pub fn matrixStride(t: *const TypeTable, ty: TypeId, row_major: bool, rules: Rules) u32 {
    const m = t.get(ty).matrix;
    const mv = matrixVectors(m, row_major);
    const s = scalarSize(t, ty);
    return switch (rules) {
        .dx_legacy, .vk_relaxed => 16,
        .gl_std140 => roundUp(vectorAlign(mv.len, s), 16),
        .std430, .gl_std430 => vectorAlign(mv.len, s),
        .dx_packed, .scalar => mv.len * s,
    };
}

pub fn alignOf(t: *const TypeTable, ty: TypeId, row_major: bool, rules: Rules) Error!u32 {
    switch (t.get(ty)) {
        .scalar, .@"enum" => return scalarSize(t, ty),
        // (The base alignment; relaxed placement packs 32-bit vectors
        // tighter, see `place`.)
        .vector => |v| return switch (rules) {
            .std430, .vk_relaxed, .gl_std140, .gl_std430 => vectorAlign(v.len, scalarSize(t, ty)),
            else => scalarSize(t, ty),
        },
        .matrix => return switch (rules) {
            .dx_legacy, .vk_relaxed => 16,
            .std430, .gl_std140, .gl_std430 => matrixStride(t, ty, row_major, rules),
            .dx_packed, .scalar => scalarSize(t, ty),
        },
        .array => |a| return switch (rules) {
            .dx_legacy => 16,
            .vk_relaxed, .gl_std140 => @max(16, try alignOf(t, a.elem, row_major, rules)),
            else => alignOf(t, a.elem, row_major, rules),
        },
        .@"struct" => |st| return structAlign(t, st, rules),
        else => return error.Unsupported,
    }
}

/// Size in bytes (dx_legacy does not pad the last element / member).
pub fn sizeOf(t: *const TypeTable, ty: TypeId, row_major: bool, rules: Rules) Error!u32 {
    switch (t.get(ty)) {
        .scalar, .@"enum" => return scalarSize(t, ty),
        .vector => |v| return v.len * scalarSize(t, ty),
        .matrix => |m| {
            const mv = matrixVectors(m, row_major);
            const vec = mv.len * scalarSize(t, ty);
            return switch (rules) {
                .dx_legacy => (mv.count - 1) * 16 + vec,
                else => mv.count * matrixStride(t, ty, row_major, rules),
            };
        },
        .array => |a| {
            const stride = try arrayStride(t, a.elem, row_major, rules);
            return switch (rules) {
                .dx_legacy => (a.len - 1) * stride + try sizeOf(t, a.elem, row_major, rules),
                else => a.len * stride,
            };
        },
        .@"struct" => |s| return structSize(t, s, rules),
        else => return error.Unsupported,
    }
}

/// Byte distance between array elements.
pub fn arrayStride(t: *const TypeTable, elem: TypeId, row_major: bool, rules: Rules) Error!u32 {
    const size = try sizeOf(t, elem, row_major, rules);
    return switch (rules) {
        .dx_legacy, .vk_relaxed => roundUp(size, 16),
        .gl_std140 => roundUp(size, @max(16, try alignOf(t, elem, row_major, rules))),
        .std430, .gl_std430 => roundUp(size, try alignOf(t, elem, row_major, rules)),
        .dx_packed => size,
        .scalar => roundUp(size, try alignOf(t, elem, row_major, rules)),
    };
}

/// Offset where a member of type `ty` goes when the previous one ended at
/// `off`.
pub fn place(t: *const TypeTable, off: u32, ty: TypeId, row_major: bool, rules: Rules) Error!u32 {
    switch (t.get(ty)) {
        .scalar, .@"enum", .vector => {
            const size = try sizeOf(t, ty, row_major, rules);
            switch (rules) {
                // Strict GLSL: vectors at their full alignment.
                .gl_std140, .gl_std430 => return roundUp(off, try alignOf(t, ty, row_major, rules)),
                .scalar => return roundUp(off, scalarSize(t, ty)),
                else => {},
            }
            // Relaxed placement: vectors of 32-bit (or narrower)
            // components align like their components; 64-bit ones keep
            // their full alignment (as dxc).
            const s = scalarSize(t, ty);
            const al = if (t.get(ty) == .vector and s > 4 and (rules == .vk_relaxed or rules == .std430)) vectorAlign(t.get(ty).vector.len, s) else s;
            var o = roundUp(off, al);
            // No straddling a 16-byte boundary (except tightly packed).
            if (rules != .dx_packed and o / 16 != (o + size - 1) / 16) o = roundUp(o, 16);
            return o;
        },
        .matrix, .array, .@"struct" => return roundUp(off, try alignOf(t, ty, row_major, rules)),
        else => return error.Unsupported,
    }
}

fn structAlign(t: *const TypeTable, info: *const types.StructInfo, rules: Rules) Error!u32 {
    switch (rules) {
        .dx_legacy => return 16,
        else => {
            var al: u32 = if (rules == .vk_relaxed or rules == .gl_std140) 16 else 1;
            for (info.fields.items) |f| if (!isOpaque(t, f.type)) {
                al = @max(al, try alignOf(t, f.type, f.row_major, rules));
            };
            return al;
        },
    }
}

fn structSize(t: *const TypeTable, info: *const types.StructInfo, rules: Rules) Error!u32 {
    var buf: [256]u32 = undefined;
    if (info.fields.items.len > buf.len) return error.Unsupported;
    const off = try layoutFields(t, info, rules, buf[0..info.fields.items.len]);
    return switch (rules) {
        .dx_legacy => off,
        // (Packed structs still round up to their widest component: a
        // double and a float3 take 24 bytes.)
        .dx_packed, .vk_relaxed, .std430, .gl_std140, .gl_std430, .scalar => roundUp(off, try structAlign(t, info, rules)),
    };
}

/// Stores the offsets of `info`'s fields in `out`; returns where the last
/// one ends.
fn layoutFields(t: *const TypeTable, info: *const types.StructInfo, rules: Rules, out: []u32) Error!u32 {
    var off: u32 = 0;
    var first: usize = 0;
    if (info.bases.items.len > 0 and rules != .dx_legacy and rules != .dx_packed) {
        // dxc's SPIR-V keeps a base class as a nested struct (padded to
        // its alignment); DXIL lays its fields out in place.
        const base = info.bases.items[0];
        first = base.fields.items.len;
        _ = try layoutFields(t, base, rules, out[0..first]);
        off = try structSize(t, base, rules);
    }
    // Explicit offsets (packoffset / register(cN)): the other members
    // follow the last explicitly placed one.
    var packed_end: ?u32 = null;
    for (info.fields.items[first..]) |f| if (f.pack_offset) |po| {
        packed_end = @max(packed_end orelse 0, po + try sizeOf(t, f.type, f.row_major, rules));
    };
    if (packed_end) |pe| off = @max(off, pe);
    var end: u32 = off;
    for (info.fields.items[first..], out[first..]) |f, *o| {
        // (Resources in structs take no space in buffers.)
        if (isOpaque(t, f.type)) {
            o.* = off;
            continue;
        }
        if (f.pack_offset) |po| {
            o.* = po;
            continue;
        }
        // [[vk::offset]] (SPIR-V only): later members continue from it.
        o.* = if (f.vk_offset) |vo| vo else try place(t, off, f.type, f.row_major, rules);
        off = o.* + try sizeOf(t, f.type, f.row_major, rules);
        end = @max(end, off);
    }
    return @max(end, packed_end orelse 0);
}

/// Offsets of a struct's fields.
pub fn fieldOffsets(a: Allocator, t: *const TypeTable, info: *const types.StructInfo, rules: Rules) Error![]u32 {
    const out = try a.alloc(u32, info.fields.items.len);
    _ = try layoutFields(t, info, rules, out);
    return out;
}

/// Byte offset of flattened component `k` of a value of type `ty` (row-major
/// component order for matrices, as the IR flattens them).
pub fn componentOffset(a: Allocator, t: *const TypeTable, ty: TypeId, row_major: bool, k: u32, rules: Rules) Error!u32 {
    switch (t.get(ty)) {
        .scalar, .@"enum" => return 0,
        .vector => return k * scalarSize(t, ty),
        .matrix => |m| {
            const r = k / m.cols;
            const c = k % m.cols;
            const stride = matrixStride(t, ty, row_major, rules);
            const s = scalarSize(t, ty);
            return if (row_major) r * stride + c * s else c * stride + r * s;
        },
        .array => |arr| {
            const n = try flatCount(t, arr.elem);
            return (k / n) * try arrayStride(t, arr.elem, row_major, rules) + try componentOffset(a, t, arr.elem, row_major, k % n, rules);
        },
        .@"struct" => |s| {
            const offs = try fieldOffsets(a, t, s, rules);
            var kk = k;
            for (s.fields.items, offs) |f, o| {
                const n = try flatCount(t, f.type);
                if (kk < n) return o + try componentOffset(a, t, f.type, f.row_major, kk, rules);
                kk -= n;
            }
            return error.Unsupported;
        },
        else => return error.Unsupported,
    }
}

/// Resources (and arrays of them): no data.
pub fn isOpaque(t: *const TypeTable, ty: TypeId) bool {
    return switch (t.get(ty)) {
        .resource, .sampler => true,
        .array => |a| isOpaque(t, a.elem),
        else => false,
    };
}

pub fn flatCount(t: *const TypeTable, ty: TypeId) Error!u32 {
    return switch (t.get(ty)) {
        .scalar, .@"enum" => 1,
        .resource, .sampler => 0,
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

test "layouts match dxc" {
    var t = try TypeTable.init(std.testing.allocator);
    defer t.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try t.scalar(.float);
    const f2 = try t.vector(.float, 2);
    const f3 = try t.vector(.float, 3);
    try std.testing.expectEqual(@as(u32, 4), try place(&t, 4, f2, false, .dx_legacy));
    try std.testing.expectEqual(@as(u32, 16), try place(&t, 12, f3, false, .dx_legacy));
    try std.testing.expectEqual(@as(u32, 20), try sizeOf(&t, try t.array(f, 2), false, .dx_legacy));
    try std.testing.expectEqual(@as(u32, 32), try sizeOf(&t, try t.array(f, 2), false, .vk_relaxed));
    // struct S { float a; float3 b; float2 c; float d; float3 e; }
    const s = try a.create(types.StructInfo);
    s.* = .{ .name = "S", .complete = true };
    for ([_]TypeId{ f, f3, f2, f, f3 }, 0..) |ft, i| try s.fields.append(a, .{ .name = &[_]u8{@intCast('a' + i)}, .type = ft });
    const st = try t.intern(.{ .@"struct" = s });
    try std.testing.expectEqualSlices(u32, &.{ 0, 4, 16, 24, 32 }, try fieldOffsets(a, &t, s, .std430));
    try std.testing.expectEqual(@as(u32, 48), try sizeOf(&t, st, false, .std430));
    try std.testing.expectEqualSlices(u32, &.{ 0, 4, 16, 24, 28 }, try fieldOffsets(a, &t, s, .dx_packed));
    // float2x3: column-major in std430 is 3 vec2 columns (stride 8).
    const m23 = try t.matrix(.float, 2, 3);
    try std.testing.expectEqual(@as(u32, 24), try sizeOf(&t, m23, false, .std430));
    try std.testing.expectEqual(@as(u32, 32), try sizeOf(&t, m23, true, .std430));
}
