//! HLSL types, interned in a TypeTable so that type identity is an integer
//! comparison.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TypeId = u32;

/// Scalar (component) types. `literal_*` are the types of unsuffixed
/// literals, which adapt to the other operand as in dxc.
pub const Scalar = enum(u8) {
    bool,
    int,
    uint,
    half,
    float,
    double,
    min16float,
    min10float,
    min16int,
    min12int,
    min16uint,
    int16,
    uint16,
    int64,
    uint64,
    float16,
    literal_int,
    literal_float,
    int8_4packed,
    uint8_4packed,

    pub fn isFloat(s: Scalar) bool {
        return switch (s) {
            .half, .float, .double, .min16float, .min10float, .float16, .literal_float => true,
            else => false,
        };
    }

    pub fn isInt(s: Scalar) bool {
        return switch (s) {
            .int, .uint, .min16int, .min12int, .min16uint, .int16, .uint16, .int64, .uint64, .literal_int, .int8_4packed, .uint8_4packed => true,
            else => false,
        };
    }

    pub fn isUnsigned(s: Scalar) bool {
        return switch (s) {
            .uint, .min16uint, .uint16, .uint64, .uint8_4packed => true,
            else => false,
        };
    }

    /// dxc's BPROP_INTEGER: integers, bool and integer literals.
    pub fn isIntegral(s: Scalar) bool {
        return s == .bool or s.isInt();
    }

    pub fn isLiteral(s: Scalar) bool {
        return s == .literal_int or s == .literal_float;
    }

    const Props = packed struct(u16) {
        boolean: bool = false,
        literal: bool = false,
        floating: bool = false,
        integer: bool = false,
        unsigned: bool = false,
        min_precision: bool = false,
        /// `half` without -enable-16bit-types (32-bit, partial precision).
        partial_precision: bool = false,
        _: u9 = 0,
    };

    /// dxc's basic-kind properties (g_uBasicKindProps in SemaHLSL.cpp):
    /// bit width (0 for bool and literals) and flags.
    fn props(s: Scalar) struct { bits: u8, p: Props } {
        return switch (s) {
            .bool => .{ .bits = 0, .p = .{ .boolean = true, .integer = true } },
            .literal_float => .{ .bits = 0, .p = .{ .floating = true, .literal = true } },
            .literal_int => .{ .bits = 0, .p = .{ .integer = true, .literal = true } },
            .float16 => .{ .bits = 16, .p = .{ .floating = true } },
            .half => .{ .bits = 32, .p = .{ .floating = true, .partial_precision = true } },
            .float => .{ .bits = 32, .p = .{ .floating = true } },
            .double => .{ .bits = 64, .p = .{ .floating = true } },
            .int16 => .{ .bits = 16, .p = .{ .integer = true } },
            .uint16 => .{ .bits = 16, .p = .{ .integer = true, .unsigned = true } },
            .int => .{ .bits = 32, .p = .{ .integer = true } },
            .uint, .int8_4packed, .uint8_4packed => .{ .bits = 32, .p = .{ .integer = true, .unsigned = true } },
            .int64 => .{ .bits = 64, .p = .{ .integer = true } },
            .uint64 => .{ .bits = 64, .p = .{ .integer = true, .unsigned = true } },
            .min10float => .{ .bits = 10, .p = .{ .floating = true, .min_precision = true } },
            .min16float => .{ .bits = 16, .p = .{ .floating = true, .min_precision = true } },
            .min12int => .{ .bits = 12, .p = .{ .integer = true, .min_precision = true } },
            .min16int => .{ .bits = 16, .p = .{ .integer = true, .min_precision = true } },
            .min16uint => .{ .bits = 16, .p = .{ .integer = true, .unsigned = true, .min_precision = true } },
        };
    }

    /// The component type of a binary operation on `a` and `b`: a port of
    /// dxc's CombineBasicTypes.
    pub fn combine(a: Scalar, b: Scalar) Scalar {
        if (a == b) return a;
        const l = a.props();
        const r = b.props();
        var bits = @max(l.bits, r.bits);
        const lb: u16 = @bitCast(l.p);
        const rb: u16 = @bitCast(r.p);
        const both: Props = @bitCast(lb & rb);
        const either: Props = @bitCast(lb | rb);
        if (both.boolean) return .bool;
        const float_result = either.floating;
        if (both.literal) return if (float_result) .literal_float else .literal_int;
        var res: Props = .{
            .integer = both.integer,
            .min_precision = both.min_precision,
            .partial_precision = both.partial_precision,
            .floating = either.floating,
            .unsigned = !float_result and either.unsigned,
        };
        // A literal or bool operand takes its precision from the other.
        if (either.literal or either.boolean) {
            res.min_precision = either.min_precision;
            res.partial_precision = res.partial_precision or either.partial_precision;
        }
        if (res.partial_precision) return .half;
        // Only one side is floating: the result comes from that side.
        if (float_result and !both.floating) {
            const f = if (l.p.floating) l else r;
            res = f.p;
            bits = f.bits;
        }
        if (bits == 0) bits = 32;
        if (float_result) return switch (bits) {
            10 => .min10float,
            16 => if (res.min_precision) .min16float else .float16,
            64 => .double,
            else => .float,
        };
        return switch (bits) {
            12 => .min12int,
            16 => if (res.unsigned)
                (if (res.min_precision) .min16uint else .uint16)
            else
                (if (res.min_precision) .min16int else .int16),
            64 => if (res.unsigned) .uint64 else .int64,
            else => if (res.unsigned) .uint else .int,
        };
    }

    /// Rank for the usual arithmetic conversions: higher wins.
    pub fn rank(s: Scalar) u8 {
        return switch (s) {
            .bool => 0,
            .literal_int => 1,
            .min12int, .min16int => 2,
            .min16uint => 3,
            .int16 => 4,
            .uint16 => 5,
            .int, .int8_4packed => 6,
            .uint, .uint8_4packed => 7,
            .int64 => 8,
            .uint64 => 9,
            .literal_float => 10,
            .min10float, .min16float => 11,
            .float16 => 12,
            .half => 13,
            .float => 14,
            .double => 15,
        };
    }

    /// Size in bytes of the component as stored (32-bit unless noted).
    pub fn size(s: Scalar) u32 {
        return switch (s) {
            .double, .int64, .uint64 => 8,
            .int16, .uint16, .float16 => 2,
            else => 4,
        };
    }

    /// The concrete type a literal becomes when nothing else decides.
    pub fn concrete(s: Scalar) Scalar {
        return switch (s) {
            .literal_int => .int,
            .literal_float => .float,
            else => s,
        };
    }

    /// HLSL spelling, as dxc prints it.
    pub fn name(s: Scalar) []const u8 {
        return switch (s) {
            .bool => "bool",
            .int => "int",
            .uint => "uint",
            .half => "half",
            .float => "float",
            .double => "double",
            .min16float => "min16float",
            .min10float => "min10float",
            .min16int => "min16int",
            .min12int => "min12int",
            .min16uint => "min16uint",
            .int16 => "int16_t",
            .uint16 => "uint16_t",
            .int64 => "int64_t",
            .uint64 => "uint64_t",
            .float16 => "float16_t",
            .literal_int => "literal int",
            .literal_float => "literal float",
            .int8_4packed => "int8_t4_packed",
            .uint8_4packed => "uint8_t4_packed",
        };
    }

    /// Scalar named by an HLSL keyword (`dword`, `float32_t` are aliases).
    pub fn fromName(n: []const u8) ?Scalar {
        const map = [_]struct { []const u8, Scalar }{
            .{ "bool", .bool },                   .{ "int", .int },                       .{ "uint", .uint },
            .{ "dword", .uint },                  .{ "half", .half },                     .{ "float", .float },
            .{ "double", .double },               .{ "min16float", .min16float },         .{ "min10float", .min10float },
            .{ "min16int", .min16int },           .{ "min12int", .min12int },             .{ "min16uint", .min16uint },
            .{ "int16_t", .int16 },               .{ "uint16_t", .uint16 },               .{ "int32_t", .int },
            .{ "uint32_t", .uint },               .{ "int64_t", .int64 },                 .{ "uint64_t", .uint64 },
            .{ "float16_t", .float16 },           .{ "float32_t", .float },               .{ "float64_t", .double },
            .{ "int8_t4_packed", .int8_4packed }, .{ "uint8_t4_packed", .uint8_4packed },
        };
        for (map) |m| if (std.mem.eql(u8, m[0], n)) return m[1];
        return null;
    }
};

pub const ResourceKind = enum(u8) {
    buffer,
    rw_buffer,
    byte_address_buffer,
    rw_byte_address_buffer,
    structured_buffer,
    rw_structured_buffer,
    append_structured_buffer,
    consume_structured_buffer,
    texture1d,
    texture1d_array,
    texture2d,
    texture2d_array,
    texture2dms,
    texture2dms_array,
    texture3d,
    texture_cube,
    texture_cube_array,
    rw_texture1d,
    rw_texture1d_array,
    rw_texture2d,
    rw_texture2d_array,
    rw_texture2dms,
    rw_texture2dms_array,
    rw_texture3d,
    constant_buffer,
    texture_buffer,
    raytracing_acceleration_structure,
    feedback_texture2d,
    feedback_texture2d_array,
    /// vk::SampledTexture*: combined image samplers (SPIR-V only).
    sampled_texture1d,
    sampled_texture1d_array,
    sampled_texture2d,
    sampled_texture2d_array,
    sampled_texture2dms,
    sampled_texture2dms_array,
    sampled_texture3d,
    sampled_texture_cube,
    sampled_texture_cube_array,
    /// Any other builtin object (RayQuery, node records, vk:: types...):
    /// accepted, with methods resolved through the intrinsic table.
    other,

    pub fn isWritable(k: ResourceKind) bool {
        return switch (k) {
            .rw_buffer, .rw_byte_address_buffer, .rw_structured_buffer, .append_structured_buffer, .rw_texture1d, .rw_texture1d_array, .rw_texture2d, .rw_texture2d_array, .rw_texture2dms, .rw_texture2dms_array, .rw_texture3d => true,
            else => false,
        };
    }

    /// Dimensions of the integer index used by operator[] (0: no indexing).
    pub fn indexDims(k: ResourceKind) u8 {
        return switch (k) {
            .buffer, .rw_buffer, .structured_buffer, .rw_structured_buffer, .texture1d, .rw_texture1d, .sampled_texture1d => 1,
            .texture1d_array, .rw_texture1d_array, .texture2d, .rw_texture2d, .texture2dms, .rw_texture2dms, .sampled_texture1d_array, .sampled_texture2d, .sampled_texture2dms => 2,
            .texture2d_array, .rw_texture2d_array, .texture2dms_array, .rw_texture2dms_array, .texture3d, .rw_texture3d, .sampled_texture2d_array, .sampled_texture2dms_array, .sampled_texture3d => 3,
            else => 0,
        };
    }

    pub const names = [_]struct { []const u8, ResourceKind }{
        .{ "Buffer", .buffer },                                                     .{ "RWBuffer", .rw_buffer },
        .{ "ByteAddressBuffer", .byte_address_buffer },                             .{ "RWByteAddressBuffer", .rw_byte_address_buffer },
        .{ "StructuredBuffer", .structured_buffer },                                .{ "RWStructuredBuffer", .rw_structured_buffer },
        .{ "AppendStructuredBuffer", .append_structured_buffer },                   .{ "ConsumeStructuredBuffer", .consume_structured_buffer },
        .{ "Texture1D", .texture1d },                                               .{ "Texture1DArray", .texture1d_array },
        .{ "Texture2D", .texture2d },                                               .{ "Texture2DArray", .texture2d_array },
        .{ "Texture2DMS", .texture2dms },                                           .{ "Texture2DMSArray", .texture2dms_array },
        .{ "Texture3D", .texture3d },                                               .{ "TextureCube", .texture_cube },
        .{ "TextureCubeArray", .texture_cube_array },                               .{ "RWTexture1D", .rw_texture1d },
        .{ "RWTexture1DArray", .rw_texture1d_array },                               .{ "RWTexture2D", .rw_texture2d },
        .{ "RWTexture2DArray", .rw_texture2d_array },                               .{ "RWTexture2DMS", .rw_texture2dms },
        .{ "RWTexture2DMSArray", .rw_texture2dms_array },                           .{ "RWTexture3D", .rw_texture3d },
        .{ "ConstantBuffer", .constant_buffer },                                    .{ "TextureBuffer", .texture_buffer },
        .{ "RaytracingAccelerationStructure", .raytracing_acceleration_structure }, .{ "FeedbackTexture2D", .feedback_texture2d },
        .{ "FeedbackTexture2DArray", .feedback_texture2d_array },
        // Rasterizer-ordered views behave like their RW counterparts.
                          .{ "RasterizerOrderedBuffer", .rw_buffer },
        .{ "RasterizerOrderedByteAddressBuffer", .rw_byte_address_buffer },         .{ "RasterizerOrderedStructuredBuffer", .rw_structured_buffer },
        .{ "RasterizerOrderedTexture1D", .rw_texture1d },                           .{ "RasterizerOrderedTexture1DArray", .rw_texture1d_array },
        .{ "RasterizerOrderedTexture2D", .rw_texture2d },                           .{ "RasterizerOrderedTexture2DArray", .rw_texture2d_array },
        .{ "RasterizerOrderedTexture3D", .rw_texture3d },
    };

    /// vk::SampledTexture* by name.
    pub const vk_names = [_]struct { []const u8, ResourceKind }{
        .{ "SampledTexture1D", .sampled_texture1d },               .{ "SampledTexture1DArray", .sampled_texture1d_array },
        .{ "SampledTexture2D", .sampled_texture2d },               .{ "SampledTexture2DArray", .sampled_texture2d_array },
        .{ "SampledTexture2DMS", .sampled_texture2dms },           .{ "SampledTexture2DMSArray", .sampled_texture2dms_array },
        .{ "SampledTexture3D", .sampled_texture3d },               .{ "SampledTextureCUBE", .sampled_texture_cube },
        .{ "SampledTextureCUBEArray", .sampled_texture_cube_array },
    };

    pub fn fromName(n: []const u8) ?ResourceKind {
        for (names) |m| if (std.mem.eql(u8, m[0], n)) return m[1];
        return null;
    }
};

pub const Field = struct {
    name: []const u8,
    type: TypeId,
    /// Matrices in the field are row_major (layout only).
    row_major: bool = false,
    /// The field's semantic (`float4 pos : SV_Position;`).
    semantic: ?[]const u8 = null,
    /// Interpolation modifiers (for entry-point inputs and outputs).
    interp: Interp = .{},
    /// Hidden storage for consecutive bitfields (see StructInfo.bitfields).
    bits: bool = false,
    /// [[vk::location(n)]], [[vk::index(n)]], [[vk::offset(n)]].
    vk_location: ?u32 = null,
    vk_index: ?u32 = null,
    vk_offset: ?u32 = null,
};

/// A bitfield member: `width` bits at `offset` in storage field `storage`.
pub const Bitfield = struct {
    name: []const u8,
    type: TypeId,
    storage: u32,
    offset: u8,
    width: u8,
};

/// Interpolation modifiers written on a parameter, field or function.
pub const Interp = packed struct(u8) {
    nointerpolation: bool = false,
    linear: bool = false,
    centroid: bool = false,
    sample: bool = false,
    noperspective: bool = false,
    _pad: u3 = 0,
};

/// A struct's layout-relevant information. Methods live in Sema.
pub const StructInfo = struct {
    name: []const u8,
    fields: std.ArrayList(Field) = .empty,
    /// Direct base structs (HLSL 2021 single inheritance, in practice).
    bases: std.ArrayList(*StructInfo) = .empty,
    /// Bitfield members, in declaration order (their storage fields are in
    /// `fields`, unnamed).
    bitfields: std.ArrayList(Bitfield) = .empty,
    /// Opaque pointer to Sema's per-struct data (methods, base).
    sema: ?*anyopaque = null,
    complete: bool = false,
    /// Had errors in its members (sizeof gives 1, as in clang).
    invalid: bool = false,
    /// Declares operator overloads (milestone 0.2): uses of operators on
    /// it are not diagnosed.
    has_operators: bool = false,

    /// The bitfields stored in field `storage` (consecutive).
    pub fn bitfieldsIn(info: *const StructInfo, storage: u32) []const Bitfield {
        var lo: usize = 0;
        while (lo < info.bitfields.items.len and info.bitfields.items[lo].storage != storage) lo += 1;
        var hi = lo;
        while (hi < info.bitfields.items.len and info.bitfields.items[hi].storage == storage) hi += 1;
        return info.bitfields.items[lo..hi];
    }

    pub fn overloadsOperators(info: *const StructInfo) bool {
        if (info.has_operators) return true;
        for (info.bases.items) |b| if (b.overloadsOperators()) return true;
        return false;
    }
};

pub const EnumInfo = struct {
    name: []const u8,
    underlying: Scalar,
    scoped: bool,
};

pub const Type = union(enum) {
    void,
    /// The type of an ill-formed expression: suppresses follow-on errors.
    @"error",
    scalar: Scalar,
    vector: struct { elem: Scalar, len: u8 },
    matrix: struct { elem: Scalar, rows: u8, cols: u8 },
    /// `len == 0` means unsized (`float a[]`).
    array: struct { elem: TypeId, len: u32 },
    @"struct": *StructInfo,
    @"enum": *EnumInfo,
    /// `elem` is the template argument (or the void type when absent).
    /// `flags`: RayQuery's constant ray flags (template arguments).
    resource: struct { kind: ResourceKind, elem: TypeId, name: []const u8, flags: u32 = 0, flags2: u32 = 0 },
    sampler: struct { comparison: bool },
    string,
    /// PointStream / LineStream / TriangleStream<T>.
    stream: struct { kind: enum { point, line, triangle }, elem: TypeId },
    /// InputPatch / OutputPatch<T, N>.
    patch: struct { output: bool, elem: TypeId, count: u32 },
    /// ResourceDescriptorHeap / SamplerDescriptorHeap (SM 6.6).
    descriptor_heap: struct { sampler: bool },
    /// `ResourceDescriptorHeap[i]`: converts to any resource / sampler.
    dynamic_resource,
    /// `tex.mips` / `tex.sample` and their slices (`tex.mips[level]`).
    texture_view: struct { texture: TypeId, kind: enum { mips, mips_slice, sample, sample_slice } },
};

/// Interns types. Ids 0 and 1 are `error` and `void`.
pub const TypeTable = struct {
    gpa: Allocator,
    types: std.ArrayList(Type) = .empty,
    map: std.AutoHashMapUnmanaged(Key, TypeId) = .empty,

    pub const error_type: TypeId = 0;
    pub const void_type: TypeId = 1;

    /// Hashable identity of structural types.
    const Key = struct { tag: u8, a: u64, b: u64 };

    pub fn init(gpa: Allocator) !TypeTable {
        var t: TypeTable = .{ .gpa = gpa };
        try t.types.append(gpa, .@"error");
        try t.types.append(gpa, .void);
        return t;
    }

    pub fn deinit(t: *TypeTable) void {
        t.types.deinit(t.gpa);
        t.map.deinit(t.gpa);
    }

    pub fn get(t: *const TypeTable, id: TypeId) Type {
        return t.types.items[id];
    }

    fn keyOf(ty: Type) ?Key {
        return switch (ty) {
            .void, .@"error" => null,
            .scalar => |s| .{ .tag = 1, .a = @backingInt(s), .b = 0 },
            .vector => |v| .{ .tag = 2, .a = @backingInt(v.elem), .b = v.len },
            .matrix => |m| .{ .tag = 3, .a = @backingInt(m.elem), .b = (@as(u64, m.rows) << 8) | m.cols },
            .array => |a| .{ .tag = 4, .a = a.elem, .b = a.len },
            .@"struct" => |s| .{ .tag = 5, .a = @intFromPtr(s), .b = 0 },
            .@"enum" => |e| .{ .tag = 6, .a = @intFromPtr(e), .b = 0 },
            .resource => |r| .{ .tag = 7, .a = (@as(u64, @backingInt(r.kind)) << 32) | r.elem, .b = std.hash.Wyhash.hash(r.flags | (@as(u64, r.flags2) << 32), r.name) },
            .sampler => |s| .{ .tag = 8, .a = @intFromBool(s.comparison), .b = 0 },
            .string => .{ .tag = 9, .a = 0, .b = 0 },
            .stream => |s| .{ .tag = 10, .a = @backingInt(s.kind), .b = s.elem },
            .patch => |p| .{ .tag = 11, .a = (@as(u64, @intFromBool(p.output)) << 32) | p.elem, .b = p.count },
            .descriptor_heap => |h| .{ .tag = 12, .a = @intFromBool(h.sampler), .b = 0 },
            .dynamic_resource => .{ .tag = 13, .a = 0, .b = 0 },
            .texture_view => |v| .{ .tag = 14, .a = v.texture, .b = @backingInt(v.kind) },
        };
    }

    pub fn intern(t: *TypeTable, ty: Type) !TypeId {
        const key = keyOf(ty) orelse return if (ty == .void) void_type else error_type;
        const gop = try t.map.getOrPut(t.gpa, key);
        if (gop.found_existing) return gop.value_ptr.*;
        try t.types.append(t.gpa, ty);
        gop.value_ptr.* = @intCast(t.types.items.len - 1);
        return gop.value_ptr.*;
    }

    pub fn scalar(t: *TypeTable, s: Scalar) !TypeId {
        return t.intern(.{ .scalar = s });
    }

    /// `len == 1` vectors are kept distinct from scalars (float1 != float).
    pub fn vector(t: *TypeTable, s: Scalar, len: u8) !TypeId {
        return t.intern(.{ .vector = .{ .elem = s, .len = len } });
    }

    pub fn matrix(t: *TypeTable, s: Scalar, rows: u8, cols: u8) !TypeId {
        return t.intern(.{ .matrix = .{ .elem = s, .rows = rows, .cols = cols } });
    }

    pub fn array(t: *TypeTable, elem: TypeId, len: u32) !TypeId {
        return t.intern(.{ .array = .{ .elem = elem, .len = len } });
    }

    /// Component type of a numeric (scalar / vector / matrix) type.
    pub fn component(t: *const TypeTable, id: TypeId) ?Scalar {
        return switch (t.get(id)) {
            .scalar => |s| s,
            .vector => |v| v.elem,
            .matrix => |m| m.elem,
            .@"enum" => |e| e.underlying,
            else => null,
        };
    }

    pub const Shape = struct {
        rows: u8,
        cols: u8,
        kind: enum { scalar, vector, matrix },

        pub fn count(sh: Shape) u32 {
            return @as(u32, sh.rows) * sh.cols;
        }
    };

    pub const DimConv = enum { identity, scalar, splat, truncation, conversion };

    /// Whether a value of shape `src` converts to shape `target`, and how:
    /// a port of dxc's ConvertDimensions (identical for implicit and
    /// explicit conversions).
    pub fn convertDimensions(target: Shape, src: Shape) ?DimConv {
        const tn = target.count();
        const sn = src.count();
        return switch (target.kind) {
            .scalar => switch (src.kind) {
                .scalar => .identity,
                .vector, .matrix => if (sn > 1) .truncation else .scalar,
            },
            .vector => switch (src.kind) {
                .scalar => .splat,
                .vector => if (target.cols > src.cols)
                    (if (src.cols == 1) .splat else null)
                else if (target.cols < src.cols) .truncation else .identity,
                .matrix => if (sn == 1 and target.cols != 1)
                    .splat
                else if (src.rows == 1 or src.cols == 1)
                    (if (target.cols > sn) null else if (target.cols < sn) .truncation else .conversion)
                else if (target.cols == 1)
                    .truncation
                else if (target.cols != sn) null else .conversion,
            },
            .matrix => switch (src.kind) {
                .scalar => .splat,
                .vector => if (src.cols == 1 and tn != 1)
                    .splat
                else if (tn == src.cols)
                    .conversion
                else if (tn == 1)
                    .truncation
                else if ((target.rows == 1 or target.cols == 1) and tn < src.cols) .truncation else null,
                .matrix => if (sn == 1 and tn != 1)
                    .splat
                else if (tn == 1)
                    .truncation
                else if (target.rows > src.rows or target.cols > src.cols)
                    null
                else if (target.rows < src.rows or target.cols < src.cols) .truncation else .identity,
            },
        };
    }

    /// The shape of a binary operation's result (dxc's CombineDimensions:
    /// prefer the larger operand, or the left on a tie), or null if the
    /// shapes do not combine.
    pub fn combineDimensions(l: Shape, r: Shape) ?Shape {
        if (l.count() >= r.count()) {
            if (convertDimensions(l, r) != null) return l;
            if (convertDimensions(r, l) != null) return r;
        } else {
            if (convertDimensions(r, l) != null) return r;
            if (convertDimensions(l, r) != null) return l;
        }
        return null;
    }

    /// Shape of a numeric type: scalars are 1x1, vectors 1xN.
    pub fn shape(t: *const TypeTable, id: TypeId) ?Shape {
        return switch (t.get(id)) {
            .scalar, .@"enum" => .{ .rows = 1, .cols = 1, .kind = .scalar },
            .vector => |v| .{ .rows = 1, .cols = v.len, .kind = .vector },
            .matrix => |m| .{ .rows = m.rows, .cols = m.cols, .kind = .matrix },
            else => null,
        };
    }

    pub fn isNumeric(t: *const TypeTable, id: TypeId) bool {
        return t.component(id) != null;
    }

    /// Build a numeric type of `shape` with component `s`.
    pub fn withShape(t: *TypeTable, s: Scalar, sh: Shape) !TypeId {
        return switch (sh.kind) {
            .scalar => t.scalar(s),
            .vector => t.vector(s, sh.cols),
            .matrix => t.matrix(s, sh.rows, sh.cols),
        };
    }

    /// Same shape as `id`, different component.
    pub fn withComponent(t: *TypeTable, id: TypeId, s: Scalar) !TypeId {
        return t.withShape(s, t.shape(id) orelse return error_type);
    }

    /// Number of scalar components (flattened), or null for non-numeric
    /// aggregates whose size is not defined.
    pub fn componentCount(t: *const TypeTable, id: TypeId) ?u32 {
        return switch (t.get(id)) {
            .scalar, .@"enum" => 1,
            .vector => |v| v.len,
            .matrix => |m| @as(u32, m.rows) * m.cols,
            .array => |a| if (a.len == 0) null else if (t.componentCount(a.elem)) |n| n * a.len else null,
            .@"struct" => |s| blk: {
                var n: u32 = 0;
                for (s.fields.items, 0..) |f, i| n += if (f.bits) @as(u32, @intCast(s.bitfieldsIn(@intCast(i)).len)) else t.componentCount(f.type) orelse break :blk null;
                break :blk n;
            },
            else => null,
        };
    }

    /// Spelling for diagnostics, close to dxc's (`vector<float, 3>`,
    /// `float4`, `MyStruct`, `Texture2D<float4>`).
    pub fn format(t: *const TypeTable, gpa: Allocator, id: TypeId) Allocator.Error![]const u8 {
        return switch (t.get(id)) {
            .void => "void",
            .@"error" => "<error>",
            .scalar => |s| s.name(),
            .vector => |v| std.fmt.allocPrint(gpa, "vector<{s}, {d}>", .{ v.elem.name(), v.len }),
            .matrix => |m| std.fmt.allocPrint(gpa, "matrix<{s}, {d}, {d}>", .{ m.elem.name(), m.rows, m.cols }),
            .array => |a| if (a.len == 0)
                std.fmt.allocPrint(gpa, "{s}[]", .{try t.format(gpa, a.elem)})
            else
                std.fmt.allocPrint(gpa, "{s}[{d}]", .{ try t.format(gpa, a.elem), a.len }),
            .@"struct" => |s| s.name,
            .@"enum" => |e| e.name,
            .resource => |r| if (r.elem == void_type) r.name else templateName(gpa, r.name, try t.format(gpa, r.elem), ""),
            .sampler => |s| if (s.comparison) "SamplerComparisonState" else "SamplerState",
            .string => "string",
            .stream => |s| templateName(gpa, switch (s.kind) {
                .point => "PointStream",
                .line => "LineStream",
                .triangle => "TriangleStream",
            }, try t.format(gpa, s.elem), ""),
            .patch => |p| templateName(gpa, if (p.output) "OutputPatch" else "InputPatch", try t.format(gpa, p.elem), try std.fmt.allocPrint(gpa, ", {d}", .{p.count})),
            .descriptor_heap => |h| if (h.sampler) "SamplerDescriptorHeap" else "ResourceDescriptorHeap",
            .dynamic_resource => "<dynamic resource>",
            .texture_view => |v| std.fmt.allocPrint(gpa, "{s}::{s}", .{ try t.format(gpa, v.texture), switch (v.kind) {
                .mips => "mips_type",
                .mips_slice => "mips_slice_type",
                .sample => "sample_type",
                .sample_slice => "sample_slice_type",
            } }),
        };
    }
};

/// `name<arg rest>`, spelled as clang does: `> >` when `arg rest` ends
/// in `>`.
fn templateName(gpa: Allocator, name: []const u8, arg: []const u8, rest: []const u8) Allocator.Error![]const u8 {
    const inner = try std.mem.concat(gpa, u8, &.{ arg, rest });
    const space = if (std.mem.endsWith(u8, inner, ">")) " " else "";
    return std.fmt.allocPrint(gpa, "{s}<{s}{s}>", .{ name, inner, space });
}

test "interning and shapes" {
    var t = try TypeTable.init(std.testing.allocator);
    defer t.deinit();
    const f4 = try t.vector(.float, 4);
    try std.testing.expectEqual(f4, try t.vector(.float, 4));
    try std.testing.expect(f4 != try t.vector(.float, 3));
    try std.testing.expect(try t.vector(.float, 1) != try t.scalar(.float));
    const m = try t.matrix(.float, 4, 4);
    try std.testing.expectEqual(@as(?u32, 16), t.componentCount(m));
    try std.testing.expectEqual(try t.vector(.int, 4), try t.withComponent(f4, .int));
    const s = try t.format(std.testing.allocator, f4);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("vector<float, 4>", s);
}
