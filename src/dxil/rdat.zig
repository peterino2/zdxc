//! The runtime data part (RDAT) of DXIL libraries, built the way dxc's
//! DxilRDATWriter / DxilRDATBuilder build it: the validator regenerates
//! the part from the module and requires the same bytes.
//!
//! Layout: a header (version, part count), part offsets, then each
//! non-empty part as (type, size) and its 4-byte aligned contents. Parts
//! come in the order dxc adds them: strings, resources, functions, index
//! arrays, raw bytes, subobjects, then the record tables of the extended
//! function properties (SM 6.10 linear algebra).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const null_ref: u32 = 0xffff_ffff;

pub const Resource = struct {
    class: u32,
    kind: u32,
    id: u32,
    space: u32,
    lower: u32,
    upper: u32,
    name: u32,
    flags: u32 = 0,
};

/// RuntimeDataFunctionInfo3 (validator 1.10+).
pub const Function = struct {
    name: u32,
    unmangled_name: u32,
    resources: u32 = null_ref,
    function_dependencies: u32 = null_ref,
    shader_kind: u32,
    payload_size: u32 = 0,
    attribute_size: u32 = 0,
    feature_info1: u32 = 0,
    feature_info2: u32 = 0,
    shader_stage_flag: u32,
    min_shader_target: u32,
    min_wave_lanes: u8 = 0,
    max_wave_lanes: u8 = 0,
    shader_flags: u16 = 0,
    raw_shader_ref: u32 = null_ref,
    extended_properties: u32 = null_ref,
};

/// The extended function property tables, in part order (part types
/// 13..20).
pub const Ext = enum(u32) {
    properties = 13,
    shapes,
    constructions,
    thread_matvec,
    wave_multiplies,
    group_multiplies,
    outer_products,
    accumulate_stores,

    /// Record size in bytes.
    pub fn stride(t: Ext) usize {
        return switch (t) {
            .shapes => 12,
            .properties, .constructions, .wave_multiplies, .group_multiplies => 8,
            .thread_matvec, .outer_products, .accumulate_stores => 4,
        };
    }
};

pub const Builder = struct {
    gpa: Allocator,
    strings: std.ArrayList(u8) = .empty,
    string_map: std.StringHashMapUnmanaged(u32) = .empty,
    indices: std.ArrayList(u32) = .empty,
    resources: std.ArrayList([8]u32) = .empty,
    functions: std.ArrayList([14]u32) = .empty,
    raw: std.ArrayList(u8) = .empty,
    subobjects: std.ArrayList([6]u32) = .empty,
    ext: [8]std.ArrayList(u8) = @splat(.empty),

    pub fn init(gpa: Allocator) Allocator.Error!Builder {
        var b: Builder = .{ .gpa = gpa };
        _ = try b.string("");
        return b;
    }

    /// Offset of `s` in the string buffer (each string once).
    pub fn string(b: *Builder, s: []const u8) Allocator.Error!u32 {
        if (b.string_map.get(s)) |off| return off;
        const off: u32 = @intCast(b.strings.items.len);
        try b.strings.appendSlice(b.gpa, s);
        try b.strings.append(b.gpa, 0);
        try b.string_map.put(b.gpa, s, off);
        return off;
    }

    /// Offset of the index array (count, then the values); identical
    /// arrays are shared.
    pub fn array(b: *Builder, vals: []const u32) Allocator.Error!u32 {
        var at: usize = 0;
        while (at < b.indices.items.len) {
            const n = b.indices.items[at];
            if (n == vals.len and std.mem.eql(u32, b.indices.items[at + 1 ..][0..n], vals)) return @intCast(at);
            at += n + 1;
        }
        const off: u32 = @intCast(b.indices.items.len);
        try b.indices.append(b.gpa, @intCast(vals.len));
        try b.indices.appendSlice(b.gpa, vals);
        return off;
    }

    pub fn addResource(b: *Builder, r: Resource) Allocator.Error!void {
        try b.resources.append(b.gpa, .{ r.class, r.kind, r.id, r.space, r.lower, r.upper, r.name, r.flags });
    }

    pub fn addFunction(b: *Builder, f: Function) Allocator.Error!void {
        const packed_wave: u32 = @as(u32, f.min_wave_lanes) | (@as(u32, f.max_wave_lanes) << 8) | (@as(u32, f.shader_flags) << 16);
        try b.functions.append(b.gpa, .{
            f.name,                f.unmangled_name,  f.resources,         f.function_dependencies,
            f.shader_kind,         f.payload_size,    f.attribute_size,    f.feature_info1,
            f.feature_info2,       f.shader_stage_flag, f.min_shader_target, packed_wave,
            f.raw_shader_ref,      f.extended_properties,
        });
    }

    /// RuntimeDataSubobjectInfo: kind, name, then four kind-specific
    /// words.
    pub fn addSubobject(b: *Builder, rec: [6]u32) Allocator.Error!void {
        try b.subobjects.append(b.gpa, rec);
    }

    /// Index of a record in table `t`; an identical record is shared
    /// (record deduplication, validator 1.7+).
    pub fn record(b: *Builder, t: Ext, rec: []const u8) Allocator.Error!u32 {
        std.debug.assert(rec.len == t.stride());
        const tab = &b.ext[@intFromEnum(t) - 13];
        var at: usize = 0;
        while (at < tab.items.len) : (at += rec.len) {
            if (std.mem.eql(u8, tab.items[at..][0..rec.len], rec)) return @intCast(at / rec.len);
        }
        try tab.appendSlice(b.gpa, rec);
        return @intCast(at / rec.len);
    }

    /// Offset of `bytes` in the raw bytes part.
    pub fn bytes(b: *Builder, data: []const u8) Allocator.Error!u32 {
        const off: u32 = @intCast(b.raw.items.len);
        try b.raw.appendSlice(b.gpa, data);
        return off;
    }

    /// The finished part.
    pub fn finish(b: *Builder) Allocator.Error![]u8 {
        const Part = struct { ty: u32, data: []const u8 };
        var parts: std.ArrayList(Part) = .empty;
        defer parts.deinit(b.gpa);
        var tables: std.ArrayList([]u8) = .empty;
        defer {
            for (tables.items) |t| b.gpa.free(t);
            tables.deinit(b.gpa);
        }
        if (b.strings.items.len > 0) try parts.append(b.gpa, .{ .ty = 1, .data = b.strings.items });
        if (b.resources.items.len > 0) {
            const t = try table(b.gpa, 8, std.mem.sliceAsBytes(b.resources.items), b.resources.items.len);
            try tables.append(b.gpa, t);
            try parts.append(b.gpa, .{ .ty = 3, .data = t });
        }
        if (b.functions.items.len > 0) {
            const t = try table(b.gpa, 14, std.mem.sliceAsBytes(b.functions.items), b.functions.items.len);
            try tables.append(b.gpa, t);
            try parts.append(b.gpa, .{ .ty = 4, .data = t });
        }
        if (b.indices.items.len > 0) try parts.append(b.gpa, .{ .ty = 2, .data = std.mem.sliceAsBytes(b.indices.items) });
        if (b.raw.items.len > 0) try parts.append(b.gpa, .{ .ty = 5, .data = b.raw.items });
        if (b.subobjects.items.len > 0) {
            const t = try table(b.gpa, 6, std.mem.sliceAsBytes(b.subobjects.items), b.subobjects.items.len);
            try tables.append(b.gpa, t);
            try parts.append(b.gpa, .{ .ty = 6, .data = t });
        }
        for (b.ext, 13..) |rows, ty| if (rows.items.len > 0) {
            const stride = @as(Ext, @enumFromInt(ty)).stride();
            const t = try table(b.gpa, stride / 4, rows.items, rows.items.len / stride);
            try tables.append(b.gpa, t);
            try parts.append(b.gpa, .{ .ty = @intCast(ty), .data = t });
        };

        var size: usize = 8 + 4 * parts.items.len;
        for (parts.items) |p| size += 8 + std.mem.alignForward(usize, p.data.len, 4);
        const out = try b.gpa.alloc(u8, size);
        @memset(out, 0);
        std.mem.writeInt(u32, out[0..4], 0x10, .little); // RDAT_Version_10
        std.mem.writeInt(u32, out[4..8], @intCast(parts.items.len), .little);
        var at: usize = 8 + 4 * parts.items.len;
        for (parts.items, 0..) |p, k| {
            std.mem.writeInt(u32, out[8 + 4 * k ..][0..4], @intCast(at), .little);
            const padded = std.mem.alignForward(usize, p.data.len, 4);
            std.mem.writeInt(u32, out[at..][0..4], p.ty, .little);
            std.mem.writeInt(u32, out[at + 4 ..][0..4], @intCast(padded), .little);
            @memcpy(out[at + 8 ..][0..p.data.len], p.data);
            at += 8 + padded;
        }
        return out;
    }

    fn table(gpa: Allocator, words: usize, rows: []const u8, count: usize) Allocator.Error![]u8 {
        const t = try gpa.alloc(u8, 8 + rows.len);
        std.mem.writeInt(u32, t[0..4], @intCast(count), .little);
        std.mem.writeInt(u32, t[4..8], @intCast(words * 4), .little);
        @memcpy(t[8..], rows);
        return t;
    }

    pub fn deinit(b: *Builder) void {
        b.strings.deinit(b.gpa);
        b.string_map.deinit(b.gpa);
        b.indices.deinit(b.gpa);
        b.resources.deinit(b.gpa);
        b.functions.deinit(b.gpa);
        b.raw.deinit(b.gpa);
        b.subobjects.deinit(b.gpa);
        for (&b.ext) |*t| t.deinit(b.gpa);
    }
};

test "rdat of one resource and function" {
    var b = try Builder.init(std.testing.allocator);
    defer b.deinit();
    const n = try b.string("buf");
    try b.addResource(.{ .class = 1, .kind = 12, .id = 0, .space = 0, .lower = 0, .upper = 0, .name = n });
    const res = try b.array(&.{0});
    try std.testing.expectEqual(res, try b.array(&.{0}));
    try b.addFunction(.{ .name = try b.string("cs"), .unmangled_name = try b.string("cs"), .resources = res, .shader_kind = 5, .shader_stage_flag = 32, .min_shader_target = 0x50060 });
    const out = try b.finish();
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, out[4..8], .little));
}
