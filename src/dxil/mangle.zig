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

/// Names already spelled (the function's own first): later uses of a
/// struct or class template name are back-references (`U1@`, `V1@`).
const Names = struct {
    list: std.ArrayList([]const u8) = .empty,

    fn find(n: *Names, name: []const u8) ?usize {
        for (n.list.items, 0..) |x, k| if (std.mem.eql(u8, x, name)) return k;
        return null;
    }

    fn add(n: *Names, a: Allocator, name: []const u8) Allocator.Error!void {
        if (n.list.items.len < 10 and n.find(name) == null) try n.list.append(a, name);
    }
};

/// `\x01?name@@YA<ret><params>Z`.
pub fn function(a: Allocator, t: *TypeTable, name: []const u8, ret: TypeId, params: []const Param) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var names: Names = .{};
    try names.add(a, name);
    try out.print(a, "\x01?{s}@@YA", .{name});
    // Parameter types spelled with more than one character are numbered;
    // repeats are back-references.
    var refs: std.ArrayList(Param) = .empty;
    const rt = t.get(ret);
    if (rt == .@"struct" or rt == .matrix or (rt == .vector and rt.vector.len > 1) or rt == .resource) try out.appendSlice(a, "?A");
    try typeCode(a, t, ret, &out, &names);
    if (params.len == 0) {
        try out.append(a, 'X');
    } else {
        for (params) |p0| {
            // (inout structs are passed as values, as in dxc.)
            const p: Param = .{ .ty = p0.ty, .by_ref = p0.by_ref and t.get(p0.ty) != .@"struct" };
            const back = for (refs.items, 0..) |r, k| {
                if (r.ty == p.ty and r.by_ref == p.by_ref) break k;
            } else null;
            if (back) |k| if (k < 10) {
                try out.append(a, '0' + @as(u8, @intCast(k)));
                continue;
            };
            var code: std.ArrayList(u8) = .empty;
            if (p.by_ref) try code.appendSlice(a, "AIA");
            try typeCode(a, t, p.ty, &code, &names);
            try out.appendSlice(a, code.items);
            if (code.items.len > 1 and back == null) try refs.append(a, p);
        }
        try out.append(a, '@');
    }
    try out.append(a, 'Z');
    return out.items;
}

/// `\x01?name@@3<type>A` (a global variable).
pub fn global(a: Allocator, t: *TypeTable, name: []const u8, ty: TypeId) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var names: Names = .{};
    try names.add(a, name);
    try out.print(a, "\x01?{s}@@3", .{name});
    // An array global: a pointer to its element.
    if (t.get(ty) == .array) {
        try out.appendSlice(a, "PA");
        try typeCode(a, t, t.get(ty).array.elem, &out, &names);
    } else try typeCode(a, t, ty, &out, &names);
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

fn typeCode(a: Allocator, t: *TypeTable, ty: TypeId, out: *std.ArrayList(u8), names: *Names) Allocator.Error!void {
    if (ty == TypeTable.void_type) return out.append(a, 'X');
    switch (t.get(ty)) {
        .scalar => |s| try out.appendSlice(a, scalarCode(s)),
        .@"enum" => |en| try qualifiedName(a, t, "W4", en.name, en.scopes, out, names),
        .vector => |v| {
            var args: std.ArrayList(u8) = .empty;
            try args.appendSlice(a, scalarCode(v.elem));
            try args.appendSlice(a, "$0");
            try number(a, v.len, &args);
            try className(a, 'V', try std.fmt.allocPrint(a, "?$vector@{s}@", .{args.items}), out, names);
        },
        .matrix => |m| {
            var args: std.ArrayList(u8) = .empty;
            try args.appendSlice(a, scalarCode(m.elem));
            try args.appendSlice(a, "$0");
            try number(a, m.rows, &args);
            try args.appendSlice(a, "$0");
            try number(a, m.cols, &args);
            try className(a, 'V', try std.fmt.allocPrint(a, "?$matrix@{s}@", .{args.items}), out, names);
        },
        .array => {
            // Y<dims - 1><dim>...<element>
            var dims: std.ArrayList(u32) = .empty;
            var et = ty;
            while (t.get(et) == .array) : (et = t.get(et).array.elem) try dims.append(a, t.get(et).array.len);
            try out.append(a, 'Y');
            try number(a, dims.items.len, out);
            for (dims.items) |d| try number(a, d, out);
            try typeCode(a, t, et, out, names);
        },
        .@"struct" => |st| try qualifiedName(a, t, if (st.is_class) "V" else "U", try structName(a, t, st), st.scopes, out, names),
        .resource => |r| {
            if (r.elem == TypeTable.void_type or r.kind == .raytracing_acceleration_structure) return className(a, 'U', r.name, out, names);
            // Template arguments have names of their own.
            var args: std.ArrayList(u8) = .empty;
            var inner: Names = .{};
            try inner.add(a, r.name);
            try typeCode(a, t, r.elem, &args, &inner);
            try className(a, 'V', try std.fmt.allocPrint(a, "?${s}@{s}@", .{ r.name, args.items }), out, names);
        },
        .sampler => |s| try className(a, 'U', if (s.comparison) "SamplerComparisonState" else "SamplerState", out, names),
        .patch => |p| {
            var args: std.ArrayList(u8) = .empty;
            var inner: Names = .{};
            const pname = if (p.output) "OutputPatch" else "InputPatch";
            try inner.add(a, pname);
            try typeCode(a, t, p.elem, &args, &inner);
            try args.appendSlice(a, "$0");
            try number(a, p.count, &args);
            try className(a, 'V', try std.fmt.allocPrint(a, "?${s}@{s}@", .{ pname, args.items }), out, names);
        },
        else => try out.append(a, 'X'),
    }
}

/// A struct's own name: `name`, or `?$name@<args>@` for a template
/// instance (its arguments with names of their own).
fn structName(a: Allocator, t: *TypeTable, st: *const types.StructInfo) Allocator.Error![]const u8 {
    const base = st.base_name orelse return st.name;
    var out: std.ArrayList(u8) = .empty;
    var inner: Names = .{};
    try inner.add(a, base);
    try out.print(a, "?${s}@", .{base});
    for (st.template_args) |arg| switch (arg) {
        .type => |ty| try typeCode(a, t, ty, &out, &inner),
        .value => |v| {
            try out.appendSlice(a, "$0");
            if (v < 0) try out.append(a, '?');
            try number(a, @abs(v), &out);
        },
    };
    try out.append(a, '@');
    return out.items;
}

/// `<kind><name><scope>@...@`: the name and each enclosing scope's,
/// innermost first, each a back-reference when already spelled.
fn qualifiedName(a: Allocator, t: *TypeTable, kind: []const u8, name: []const u8, scopes: []const types.ScopeName, out: *std.ArrayList(u8), names: *Names) Allocator.Error!void {
    try out.appendSlice(a, kind);
    try namePart(a, name, out, names);
    for (scopes) |sc| try namePart(a, switch (sc) {
        .name => |n| n,
        .strct => |st| try structName(a, t, st),
    }, out, names);
    try out.append(a, '@');
}

/// One part of a qualified name: `name@` (template instances end in `@`
/// themselves), or a back-reference digit.
fn namePart(a: Allocator, name: []const u8, out: *std.ArrayList(u8), names: *Names) Allocator.Error!void {
    if (names.find(name)) |k| return out.append(a, '0' + @as(u8, @intCast(k)));
    try out.appendSlice(a, name);
    if (name[0] != '?') try out.append(a, '@');
    try names.add(a, name);
}

/// `<kind><name>@@`, or `<kind><backref>@` for a name already spelled
/// (template instances `?$name@args@` end in `@` themselves).
fn className(a: Allocator, kind: u8, name: []const u8, out: *std.ArrayList(u8), names: *Names) Allocator.Error!void {
    try out.append(a, kind);
    if (names.find(name)) |k| {
        try out.append(a, '0' + @as(u8, @intCast(k)));
        return out.append(a, '@');
    }
    try out.appendSlice(a, name);
    if (name[0] != '?') try out.append(a, '@');
    try out.append(a, '@');
    try names.add(a, name);
}
