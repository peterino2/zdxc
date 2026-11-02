//! Shader reflection: what D3D12's ID3D12ShaderReflection and
//! ID3D12LibraryReflection report about a compiled shader. The DXIL emitter
//! builds it; the DXC drop-in hands it out as DXC_OUT_REFLECTION and reads
//! it back in IDxcUtils::CreateReflection.
//!
//! The blob is a DXIL container: the object's SFI0 part, its signatures'
//! records in declaration order (the parameters reflection reports), and a
//! ZRFL part holding the rest as JSON.

const std = @import("std");
const Allocator = std.mem.Allocator;
const container = @import("container.zig");

pub const part = container.fourcc("ZRFL");
/// The signatures in declaration order (ISG1 / OSG1 / PSG1's records, which
/// those parts sort by register).
pub const input_part = container.fourcc("ZIS1");
pub const output_part = container.fourcc("ZOS1");
pub const patch_part = container.fourcc("ZPS1");

/// The feature bits reflection reports as required (D3D_SHADER_REQUIRES_*):
/// the bits from 40 up are DXC's optional feature info.
pub const required_features: u64 = (1 << 40) - 1;

/// D3D12_SHADER_INPUT_BIND_DESC.
pub const Bind = struct {
    name: []const u8,
    /// D3D_SHADER_INPUT_TYPE.
    type: u32,
    bind_point: u32,
    /// 0 for an unbounded range.
    bind_count: u32,
    /// D3D_SHADER_INPUT_FLAGS.
    flags: u32 = 0,
    /// D3D_RESOURCE_RETURN_TYPE.
    return_type: u32 = 0,
    /// D3D_SRV_DIMENSION.
    dimension: u32 = 0,
    /// The sample count of multisampled textures; the stride of structured
    /// buffers.
    num_samples: u32 = 0,
    space: u32,
    id: u32,
};

/// D3D12_SHADER_TYPE_DESC (members by index into Reflection.types).
pub const Type = struct {
    /// D3D_SHADER_VARIABLE_CLASS.
    class: u32,
    /// D3D_SHADER_VARIABLE_TYPE.
    kind: u32,
    rows: u32 = 0,
    cols: u32 = 0,
    elements: u32 = 0,
    offset: u32 = 0,
    name: []const u8 = "",
    members: []const Member = &.{},
};

pub const Member = struct { name: []const u8, ty: u32 };

/// D3D12_SHADER_VARIABLE_DESC.
pub const Variable = struct {
    name: []const u8,
    offset: u32,
    size: u32,
    /// D3D_SHADER_VARIABLE_FLAGS: `used` when the shader reads it.
    flags: u32,
    ty: u32,
};

/// D3D12_SHADER_BUFFER_DESC and its variables.
pub const CBuffer = struct {
    name: []const u8,
    /// D3D_CBUFFER_TYPE.
    kind: u32,
    size: u32,
    flags: u32 = 0,
    vars: []const Variable,
};

/// A library function (ID3D12FunctionReflection): indices into
/// Reflection.binds and Reflection.cbuffers.
pub const Function = struct {
    name: []const u8,
    version: u32,
    requires: u64,
    binds: []const u32,
    cbuffers: []const u32,
};

pub const Reflection = struct {
    /// D3D12_SHVER: program type << 16, major << 4, minor.
    version: u32,
    requires: u64 = 0,
    instructions: u32 = 0,
    thread_group: [3]u32 = .{ 0, 0, 0 },
    binds: []const Bind = &.{},
    cbuffers: []const CBuffer = &.{},
    types: []const Type = &.{},
    functions: []const Function = &.{},
    /// Geometry and tessellation state (D3D12_SHADER_DESC).
    input_primitive: u32 = 0,
    gs_output_topology: u32 = 0,
    gs_max_vertices: u32 = 0,
    gs_instances: u32 = 0,
    control_points: u32 = 0,
    hs_output_primitive: u32 = 0,
    hs_partitioning: u32 = 0,
    tess_domain: u32 = 0,
    sample_frequency: bool = false,
};

// D3D enums (d3dcommon.h) used here.
pub const sit = struct {
    pub const cbuffer = 0;
    pub const tbuffer = 1;
    pub const texture = 2;
    pub const sampler = 3;
    pub const uav_rwtyped = 4;
    pub const structured = 5;
    pub const uav_rwstructured = 6;
    pub const byteaddress = 7;
    pub const uav_rwbyteaddress = 8;
    pub const uav_append_structured = 9;
    pub const uav_consume_structured = 10;
    pub const uav_rwstructured_with_counter = 11;
    pub const rtaccelerationstructure = 12;
    pub const uav_feedbacktexture = 13;
};
pub const sif_userpacked = 1;
pub const sif_comparison_sampler = 2;
pub const svf_userpacked = 1;
pub const svf_used = 2;
pub const ct_cbuffer = 0;
pub const ct_tbuffer = 1;
pub const ct_resource_bind_info = 3;
pub const svc = struct {
    pub const scalar = 0;
    pub const vector = 1;
    pub const matrix_rows = 2;
    pub const matrix_columns = 3;
    pub const object = 4;
    pub const @"struct" = 5;
};
pub const ret = struct {
    pub const unorm = 1;
    pub const snorm = 2;
    pub const sint = 3;
    pub const uint = 4;
    pub const float = 5;
    pub const mixed = 6;
    pub const double = 7;
};

/// D3D12_SHVER program types.
pub fn programType(stage: []const u8) u32 {
    const names = [_][]const u8{ "pixel", "vertex", "geometry", "hull", "domain", "compute", "library", "raygeneration", "intersection", "anyhit", "closesthit", "miss", "callable", "mesh", "amplification", "node" };
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, stage)) return @intCast(i);
    return 5;
}

pub fn version(program_type: u32, major: u32, minor: u32) u32 {
    return program_type << 16 | major << 4 | minor;
}

/// The reflection blob: `parts` (SFI0 and the signatures) and the ZRFL
/// part.
pub fn encode(gpa: Allocator, r: Reflection, parts: []const container.Part) Allocator.Error![]u8 {
    const json = try std.json.Stringify.valueAlloc(gpa, r, .{});
    defer gpa.free(json);
    var all: std.ArrayList(container.Part) = .empty;
    defer all.deinit(gpa);
    try all.appendSlice(gpa, parts);
    try all.append(gpa, .{ .fourcc = part, .data = json });
    return container.assemble(gpa, all.items);
}

/// The ZRFL part of a reflection blob (padding included), parsed into
/// `arena`.
pub fn decode(arena: Allocator, json: []const u8) !Reflection {
    const text = std.mem.trimEnd(u8, json, "\x00");
    return std.json.parseFromSliceLeaky(Reflection, arena, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

test "encode and decode" {
    const a = std.testing.allocator;
    const r: Reflection = .{
        .version = version(0, 6, 6),
        .requires = 1 << 40,
        .binds = &.{.{ .name = "Tex", .type = sit.texture, .bind_point = 3, .bind_count = 1, .space = 0, .id = 0 }},
        .cbuffers = &.{.{ .name = "$Globals", .kind = ct_cbuffer, .size = 16, .vars = &.{.{ .name = "A", .offset = 0, .size = 16, .flags = svf_used, .ty = 0 }} }},
        .types = &.{.{ .class = svc.vector, .kind = 3, .rows = 1, .cols = 4, .name = "float4" }},
    };
    const blob = try encode(a, r, &.{});
    defer a.free(blob);
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const view = try container.parse(arena.allocator(), blob);
    const back = try decode(arena.allocator(), view.find(part) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(r.version, back.version);
    try std.testing.expectEqual(r.requires, back.requires);
    try std.testing.expectEqualStrings("Tex", back.binds[0].name);
    try std.testing.expectEqualStrings("$Globals", back.cbuffers[0].name);
    try std.testing.expectEqual(@as(u32, svf_used), back.cbuffers[0].vars[0].flags);
}
