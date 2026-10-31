//! Microsoft-style C++ name mangling of library functions and resource
//! globals, as dxc spells them (`\x01?name@@YAXXZ`). D3D12 refers to
//! library exports by the unmangled name (recorded in RDAT next to this
//! one), so near enough is good enough for unusual types.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../sema/types.zig");
const TypeTable = types.TypeTable;
const TypeId = types.TypeId;

pub const Param = struct { ty: TypeId, by_ref: bool = false };

/// `\x01?name@@YA<ret><params>Z`.
pub fn function(a: Allocator, t: *TypeTable, name: []const u8, ret: TypeId, params: []const Param) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "\x01?{s}@@YA", .{name});
    var refs: std.ArrayList([]const u8) = .empty;
    const rt = t.get(ret);
    if (rt == .@"struct" or rt == .matrix or (rt == .vector and rt.vector.len > 1) or rt == .resource) try out.appendSlice(a, "?A");
    try typeCode(a, t, ret, &out);
    if (params.len == 0) {
        try out.append(a, 'X');
    } else {
        for (params) |p| {
            var code: std.ArrayList(u8) = .empty;
            if (p.by_ref) try code.appendSlice(a, "AIA");
            try typeCode(a, t, p.ty, &code);
            if (code.items.len == 1) {
                try out.appendSlice(a, code.items);
                continue;
            }
            // Repeated multi-character types are back-references.
            const back = for (refs.items, 0..) |r, k| {
                if (std.mem.eql(u8, r, code.items)) break k;
            } else null;
            if (back) |k| if (k < 10) {
                try out.append(a, '0' + @as(u8, @intCast(k)));
                continue;
            };
            try out.appendSlice(a, code.items);
            if (back == null) try refs.append(a, code.items);
        }
        try out.append(a, '@');
    }
    try out.append(a, 'Z');
    return out.items;
}

/// `\x01?name@@3<type>A` (a global variable).
pub fn global(a: Allocator, t: *TypeTable, name: []const u8, ty: TypeId) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "\x01?{s}@@3", .{name});
    try typeCode(a, t, ty, &out);
    try out.append(a, 'A');
    return out.items;
}

fn number(a: Allocator, n: u64, out: *std.ArrayList(u8)) Allocator.Error!void {
    if (n >= 1 and n <= 10) return out.append(a, '0' + @as(u8, @intCast(n - 1)));
    if (n == 0) return out.appendSlice(a, "A@");
    var buf: [16]u8 = undefined;
    var k: usize = buf.len;
    var v = n;
    while (v != 0) : (v >>= 4) {
        k -= 1;
        buf[k] = 'A' + @as(u8, @intCast(v & 0xf));
    }
    try out.appendSlice(a, buf[k..]);
    try out.append(a, '@');
}

fn scalarCode(s: types.Scalar) []const u8 {
    return switch (s) {
        .bool => "_N",
        .int, .literal_int => "H",
        .uint => "I",
        .float, .literal_float => "M",
        .double => "N",
        .half => "$halff@",
        .float16 => "$f16@",
        .int16 => "F",
        .uint16 => "G",
        .int64 => "_J",
        .uint64 => "_K",
        .min16float => "$min16f@",
        .min10float => "$min10f@",
        .min16int => "$min16i@",
        .min12int => "$min12i@",
        .min16uint => "$min16ui@",
        else => "H",
    };
}

fn typeCode(a: Allocator, t: *TypeTable, ty: TypeId, out: *std.ArrayList(u8)) Allocator.Error!void {
    if (ty == TypeTable.void_type) return out.append(a, 'X');
    switch (t.get(ty)) {
        .scalar => |s| try out.appendSlice(a, scalarCode(s)),
        .@"enum" => |en| try out.print(a, "W4{s}@@", .{en.name}),
        .vector => |v| {
            try out.print(a, "V?$vector@{s}", .{scalarCode(v.elem)});
            try out.append(a, '$');
            try number(a, v.len, out);
            try out.appendSlice(a, "@@");
        },
        .matrix => |m| {
            try out.print(a, "V?$matrix@{s}", .{scalarCode(m.elem)});
            try out.append(a, '$');
            try number(a, m.rows, out);
            try out.append(a, '$');
            try number(a, m.cols, out);
            try out.appendSlice(a, "@@");
        },
        .array => |arr| {
            // Y<dims - 1><dim>...<element>
            var dims: std.ArrayList(u32) = .empty;
            var et = ty;
            while (t.get(et) == .array) : (et = t.get(et).array.elem) try dims.append(a, t.get(et).array.len);
            _ = arr;
            try out.append(a, 'Y');
            try number(a, dims.items.len - 1, out);
            for (dims.items) |d| try number(a, d, out);
            try typeCode(a, t, et, out);
        },
        .@"struct" => |st| try out.print(a, "U{s}@@", .{st.name}),
        .resource => |r| {
            if (r.elem == TypeTable.void_type or r.kind == .raytracing_acceleration_structure) return out.print(a, "U{s}@@", .{r.name});
            try out.print(a, "V?${s}@", .{r.name});
            try typeCode(a, t, r.elem, out);
            try out.appendSlice(a, "@@");
        },
        .sampler => |s| try out.appendSlice(a, if (s.comparison) "USamplerComparisonState@@" else "USamplerState@@"),
        else => try out.append(a, 'X'),
    }
}
