//! IR -> SPIR-V (Vulkan). Follows dxc's conventions: the HLSL entry is a
//! function called from a parameterless wrapper that loads the stage
//! inputs; resources use dxc's default register-to-binding mapping
//! (binding = register number, descriptor set = register space).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("../ir/ir.zig");
const types = @import("../sema/types.zig");
const texture = @import("../ir/texture.zig");
const builder = @import("builder.zig");
const diag = @import("../diag.zig");
const layout = @import("../ir/layout.zig");

const Builder = builder.Builder;
const Id = builder.Id;
const Op = builder.Op;
const TypeId = types.TypeId;
const TypeTable = types.TypeTable;
const Scalar = types.Scalar;
const Ref = ir.Ref;

pub const Error = Allocator.Error || error{Unsupported};

/// SPIR-V storage classes.
/// Marks a binding that is a recipe (see Emitter.resourceBinding).
const recipe_tag: u32 = 0x8000_0000;

const StorageClass = enum(u32) { uniform_constant = 0, input = 1, uniform = 2, output = 3, workgroup = 4, private = 6, function = 7, image = 11, storage_buffer = 12, task_payload_workgroup = 5402, callable_data_khr = 5328, incoming_callable_data_khr = 5329, ray_payload_khr = 5338, hit_attribute_khr = 5339, incoming_ray_payload_khr = 5342, shader_record_buffer_khr = 5343 };

const Capability = enum(u32) {
    shader = 1,
    linkage = 5,
    geometry = 2,
    tessellation = 3,
    float16 = 9,
    float64 = 10,
    int64 = 11,
    int64_atomics = 12,
    int16 = 22,
    image_gather_extended = 25,
    storage_image_multisample = 27,
    sample_rate_shading = 35,
    derivative_control = 51,
    clip_distance = 32,
    cull_distance = 33,
    draw_parameters = 4427,
    multi_view = 4439,
    fragment_shading_rate_khr = 4422,
    stencil_export_ext = 5013,
    shader_viewport_index_layer_ext = 5254,
    fragment_fully_covered_ext = 5265,
    fragment_barycentric_khr = 5284,
    compute_derivative_group_quads = 5288,
    compute_derivative_group_linear = 5350,
    geometry_streams = 54,
    multi_viewport = 57,
    min_lod = 42,
    sparse_residency = 41,
    sampled1d = 43,
    image1d = 44,
    sampled_cube_array = 45,
    sampled_buffer = 46,
    image_buffer = 47,
    image_ms_array = 48,
    storage_image_extended_formats = 49,
    image_query = 50,
    storage_image_read_without_format = 55,
    storage_image_write_without_format = 56,
    group_non_uniform = 61,
    mesh_shading_ext = 5283,
    ray_tracing_khr = 4479,
    ray_query_khr = 4472,
    ray_traversal_primitive_culling_khr = 4478,
    ray_tracing_position_fetch_khr = 5336,
    ray_query_position_fetch_khr = 5391,
    ray_tracing_opacity_micromap_ext = 5381,
    group_non_uniform_vote = 62,
    group_non_uniform_arithmetic = 63,
    group_non_uniform_ballot = 64,
    group_non_uniform_shuffle = 65,
    group_non_uniform_quad = 68,
    shader_non_uniform = 5301,
    uniform_buffer_array_non_uniform_indexing = 5306,
    runtime_descriptor_array = 5302,
    uniform_texel_buffer_array_non_uniform_indexing = 5311,
    storage_texel_buffer_array_non_uniform_indexing = 5312,
    sampled_image_array_non_uniform_indexing = 5307,
    storage_buffer_array_non_uniform_indexing = 5308,
    storage_image_array_non_uniform_indexing = 5309,
};

/// A Vulkan (or universal) target and the SPIR-V version it implies.
pub const TargetEnv = struct {
    /// SPIR-V minor version (1.x).
    minor: u8,
    /// A universal (not Vulkan) environment: linkage is allowed.
    universal: bool = false,

    pub fn parse(s: []const u8) ?TargetEnv {
        const table = [_]struct { []const u8, u8 }{
            .{ "vulkan1.0", 0 },           .{ "vulkan1.1", 3 }, .{ "vulkan1.1spirv1.3", 3 }, .{ "vulkan1.1spirv1.4", 4 },
            .{ "vulkan1.2", 5 },           .{ "vulkan1.3", 6 }, .{ "vulkan1.4", 6 },         .{ "universal1.5", 5 },
        };
        for (table) |t| if (std.mem.eql(u8, s, t[0])) return .{ .minor = t[1], .universal = std.mem.startsWith(u8, s, "universal") };
        return null;
    }
};

pub fn emit(gpa: Allocator, m: *const ir.Module, diags: *diag.Diagnostics, env: TargetEnv) Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var e: Emitter = .{ .arena = arena_state.allocator(), .b = .init(gpa), .m = m, .t = m.types, .diags = diags, .spv_minor = env.minor, .universal = env.universal };
    defer e.b.deinit();
    try e.module();
    return e.b.finish(0x00010000 | (@as(u32, env.minor) << 8));
}

const Emitter = struct {
    arena: Allocator,
    b: Builder,
    m: *const ir.Module,
    t: *TypeTable,
    diags: *diag.Diagnostics,
    /// SPIR-V 1.x.
    spv_minor: u8 = 0,
    universal: bool = false,

    value_types: std.AutoHashMapUnmanaged(TypeId, Id) = .empty,
    /// Explicitly laid out variants of arrays and structs (buffers).
    layout_types: std.AutoHashMapUnmanaged(LayoutKey, Id) = .empty,
    /// Per instruction (current function): the buffer layout its pointer
    /// result points into, if any.
    ptr_layouts: []?PtrLayout = &.{},
    pointer_types: std.AutoHashMapUnmanaged(struct { StorageClass, Id }, Id) = .empty,
    function_types: std.StringHashMapUnmanaged(Id) = .empty,
    constants: std.AutoHashMapUnmanaged(struct { Id, u64 }, Id) = .empty,
    capabilities: std.AutoArrayHashMapUnmanaged(Capability, void) = .empty,
    glsl: Id = 0,
    void_id: Id = 0,

    func_ids: []Id = &.{},
    /// Per global: the OpVariable and, for buffers, the element pointer
    /// type.
    global_vars: []Id = &.{},
    /// Buffer block structs by resource type.
    buffer_blocks: std.AutoHashMapUnmanaged(TypeId, Id) = .empty,
    /// ConstantBuffer<S> blocks by S.
    cb_blocks: std.AutoHashMapUnmanaged(TypeId, Id) = .empty,
    tb_blocks: std.AutoHashMapUnmanaged(TypeId, Id) = .empty,
    /// Structured buffers whose hidden counter is used.
    counter_globals: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Descriptor heaps: a runtime array variable per (heap, element type),
    /// on the heap's binding.
    heap_vars: std.AutoHashMapUnmanaged(struct { bool, Id }, Id) = .empty,
    heap_bindings: [2]u32 = .{ 0, 0 },
    /// Image types by (sampled type, dim, arrayed, ms, sampled, format).
    image_types: std.AutoHashMapUnmanaged([6]u32, Id) = .empty,
    sampled_image_types: std.AutoHashMapUnmanaged(Id, Id) = .empty,
    sampler_type: Id = 0,
    accel_type: Id = 0,
    ray_query_type: Id = 0,
    counter_vars: []Id = &.{},
    builtin_inputs: std.AutoHashMapUnmanaged(u32, Id) = .empty,
    /// Per instruction (current function): texel places (`tex[i]`).
    texel_places: std.AutoHashMapUnmanaged(u32, struct { res: Ref, coord: Ref, comp: Ref = .none }) = .empty,
    counter_type: Id = 0,
    resource_arrays: std.AutoHashMapUnmanaged([2]u32, Id) = .empty,
    extensions: std.ArrayList([]const u8) = .empty,
    /// Values selected with NonUniformResourceIndex (and resources reached
    /// through them).
    nonuniform_ids: std.AutoHashMapUnmanaged(Id, void) = .empty,
    variants: std.ArrayList(struct { fi: u32, bindings: []const Id, id: Id }) = .empty,
    /// The bindings of the function being emitted (a specialization).
    cur_bindings: []const Id = &.{},
    /// Resource array elements bound to specialized parameters.
    recipes: std.ArrayList(struct { var_id: Id, ptr_ty: Id, indices: []const Id }) = .empty,
    payload_global: ?u32 = null,
    /// Per instruction (current function): places in mesh output arrays.
    mesh_places: std.AutoHashMapUnmanaged(u32, MeshPlace) = .empty,
    /// Parameters receiving mesh output arrays: not real parameters (the
    /// outputs are module variables); by function and parameter index.
    mesh_params: std.AutoHashMapUnmanaged(struct { *const ir.Function, u32 }, ir.MeshOutput) = .empty,
    /// Per entry: its interface state; `st` and `entry` are the current
    /// entry's (the one the function being emitted was lowered for).
    states: []EntryState = &.{},
    st: *EntryState = undefined,
    entry: *const ir.Entry = undefined,
    /// Interface variables each function uses directly, and the functions
    /// it calls (by function id), for the entries' interface lists.
    fn_uses: std.AutoHashMapUnmanaged(Id, std.ArrayList(Id)) = .empty,
    fn_calls: std.AutoHashMapUnmanaged(Id, std.ArrayList(Id)) = .empty,
    cur_fn: Id = 0,
    /// Ray tracing storage by (storage class, value type).
    ray_vars: std.AutoHashMapUnmanaged(struct { StorageClass, TypeId }, Id) = .empty,
    /// Next Location per ray tracing storage class (RayPayloadKHR,
    /// CallableDataKHR).
    ray_locations: std.AutoHashMapUnmanaged(StorageClass, u32) = .empty,

    // Per function.
    vals: []Id = &.{},
    f: *const ir.Function = undefined,

    const Interface = struct {
        var_id: Id,
        ty: TypeId,
        /// An array builtin holding the value's components from `base` on
        /// (TessLevelOuter / TessLevelInner, ClipDistance / CullDistance
        /// shared by several elements, SampleMask), accessed element-wise.
        elem_array: bool = false,
        base: u32 = 0,
    };
    const EntryState = struct {
        /// Entry inputs / outputs: interface variable and its value type.
        inputs: []Interface = &.{},
        outputs: []Interface = &.{},
        patches: []Interface = &.{},
        /// Interface variables made for the entry itself.
        iface: std.ArrayList(Id) = .empty,
        /// Compute derivatives' execution mode (0: none).
        derivative_mode: u32 = 0,
        /// Mesh shaders: the primitive indices builtin and the payload
        /// variable (both made on first use); amplification shaders: the
        /// groupshared variable sent by DispatchMesh.
        indices_var: Id = 0,
        payload_var: Id = 0,
    };
    const LayoutKey = struct { TypeId, layout.Rules, bool };
    const MeshPlace = struct { kind: ir.MeshOutput, index: Ref = .none, offset: u32 = 0, ty: TypeId };
    const PtrLayout = struct { rules: layout.Rules, row_major: bool };

    fn unsupported(e: *Emitter, comptime fmt: []const u8, args: anytype) Error {
        _ = e.diags.report(.{ .severity = .@"error", .loc = .none }, "SPIR-V code generation: " ++ fmt, args);
        return error.Unsupported;
    }

    /// Storage buffers: Uniform + BufferBlock up to SPIR-V 1.3,
    /// StorageBuffer + Block after (BufferBlock was removed).
    fn bufferSc(e: *const Emitter) StorageClass {
        return if (e.spv_minor >= 4) .storage_buffer else .uniform;
    }

    fn bufferBlockDecoration(e: *const Emitter) u32 {
        return if (e.spv_minor >= 4) 2 else 3; // Block / BufferBlock
    }

    fn cap(e: *Emitter, c: Capability) !void {
        try e.capabilities.put(e.arena, c, {});
    }

    // ------------------------------------------------------------------
    // Types and constants

    fn scalarType(e: *Emitter, s: Scalar) Error!Id {
        return e.typeId(try e.t.scalar(storageScalar(s)));
    }

    /// The SPIR-V representation of an HLSL scalar: min-precision and
    /// non-native 16-bit `half` use 32-bit types.
    fn storageScalar(s: Scalar) Scalar {
        return switch (s) {
            .min16int, .min12int, .literal_int, .int8_4packed => .int,
            .min16uint, .uint8_4packed => .uint,
            .half, .min16float, .min10float, .literal_float => .float,
            else => s,
        };
    }

    fn typeId(e: *Emitter, ty: TypeId) Error!Id {
        if (e.value_types.get(ty)) |id| return id;
        const id: Id = switch (e.t.get(ty)) {
            .void => blk: {
                const id = e.b.newId();
                try e.b.emit(.types_globals, .type_void, &.{id});
                break :blk id;
            },
            .scalar => |s| blk: {
                const st = storageScalar(s);
                if (st != s) break :blk try e.typeId(try e.t.scalar(st));
                const id = e.b.newId();
                switch (s) {
                    .bool => try e.b.emit(.types_globals, .type_bool, &.{id}),
                    .int => try e.b.emit(.types_globals, .type_int, &.{ id, 32, 1 }),
                    .uint => try e.b.emit(.types_globals, .type_int, &.{ id, 32, 0 }),
                    .int16, .uint16 => {
                        try e.cap(.int16);
                        try e.b.emit(.types_globals, .type_int, &.{ id, 16, @intFromBool(s == .int16) });
                    },
                    .int64, .uint64 => {
                        try e.cap(.int64);
                        try e.b.emit(.types_globals, .type_int, &.{ id, 64, @intFromBool(s == .int64) });
                    },
                    .float => try e.b.emit(.types_globals, .type_float, &.{ id, 32 }),
                    .float16 => {
                        try e.cap(.float16);
                        try e.b.emit(.types_globals, .type_float, &.{ id, 16 });
                    },
                    .double => {
                        try e.cap(.float64);
                        try e.b.emit(.types_globals, .type_float, &.{ id, 64 });
                    },
                    else => unreachable,
                }
                break :blk id;
            },
            .vector => |v| blk: {
                // vector<T, 1> is a plain T (SPIR-V has no 1-vectors).
                if (v.len == 1) break :blk try e.scalarType(v.elem);
                if (storageScalar(v.elem) != v.elem) break :blk try e.typeId(try e.t.vector(storageScalar(v.elem), v.len));
                const elem = try e.scalarType(v.elem);
                const id = e.b.newId();
                try e.b.emit(.types_globals, .type_vector, &.{ id, elem, v.len });
                break :blk id;
            },
            .array => |a| blk: {
                const elem = try e.typeId(a.elem);
                const len = try e.constUint(a.len);
                const id = e.b.newId();
                try e.b.emit(.types_globals, .type_array, &.{ id, elem, len });
                break :blk id;
            },
            // HLSL rows are SPIR-V columns (as in dxc): floatRxC is R
            // columns of vecC. Non-float matrices are arrays of vectors;
            // 1xN and Nx1 matrices are vectors, 1x1 a scalar.
            .matrix => |mt| blk: {
                if (mt.rows == 1 or mt.cols == 1) break :blk try e.typeId(try e.t.vector(mt.elem, mt.rows * mt.cols));
                if (storageScalar(mt.elem) != mt.elem) break :blk try e.typeId(try e.t.matrix(storageScalar(mt.elem), mt.rows, mt.cols));
                const row_id = try e.typeId(try e.t.vector(mt.elem, mt.cols));
                const id = e.b.newId();
                if (storageScalar(mt.elem).isFloat()) {
                    try e.b.emit(.types_globals, .type_matrix, &.{ id, row_id, mt.rows });
                } else try e.b.emit(.types_globals, .type_array, &.{ id, row_id, try e.constUint(mt.rows) });
                break :blk id;
            },
            .@"struct" => |st| blk: {
                const members = try e.arena.alloc(u32, st.fields.items.len);
                for (st.fields.items, members) |fld, *mid| mid.* = try e.typeId(fld.type);
                const id = e.b.newId();
                var ops: std.ArrayList(u32) = .empty;
                try ops.append(e.arena, id);
                try ops.appendSlice(e.arena, members);
                try e.b.emit(.types_globals, .type_struct, ops.items);
                try e.b.emitWithString(.debug_names, .name, &.{id}, try std.fmt.allocPrint(e.arena, "struct.{s}", .{st.name}), &.{});
                for (st.fields.items, 0..) |fld, k| try e.b.emitWithString(.debug_names, .member_name, &.{ id, @intCast(k) }, fld.name, &.{});
                break :blk id;
            },
            else => return e.unsupported("type '{s}' is not supported yet", .{try e.t.format(e.arena, ty)}),
        };
        try e.value_types.put(e.arena, ty, id);
        return id;
    }

    /// `ty` laid out for a buffer (`rules`): arrays carry ArrayStride,
    /// structs member Offsets and matrix decorations; scalars, vectors and
    /// float matrices are the plain types (bools become uints).
    fn layoutTypeId(e: *Emitter, ty: TypeId, rules: layout.Rules, row_major: bool) Error!Id {
        switch (e.t.get(ty)) {
            .scalar, .vector, .@"enum" => return e.typeId(if (e.t.component(ty) == .bool) try e.t.withComponent(ty, .uint) else ty),
            .matrix => |m| {
                const fl = storageScalar(m.elem).isFloat();
                if (m.rows == 1 or m.cols == 1) {
                    // A SPIR-V vector: contiguous only if the stored vectors
                    // are the whole matrix or single components packed tight.
                    const vectors: u32 = if (row_major) m.rows else m.cols;
                    if (vectors > 1 and layout.matrixStride(e.t, ty, row_major, rules) != storageScalar(m.elem).size()) {
                        return e.unsupported("this 1xN / Nx1 matrix layout is not supported yet", .{});
                    }
                    return e.typeId(ty);
                }
                if (fl) return e.typeId(ty);
                if (!row_major) return e.unsupported("column-major integer matrices in buffers are not supported yet", .{});
            },
            else => {},
        }
        const key: LayoutKey = .{ ty, rules, row_major };
        if (e.layout_types.get(key)) |id| return id;
        const id = e.b.newId();
        switch (e.t.get(ty)) {
            .matrix => |m| {
                // Row-major integer matrix: an array of its rows.
                const row_ty = try e.layoutTypeId(try e.t.vector(m.elem, m.cols), rules, false);
                try e.b.emit(.types_globals, .type_array, &.{ id, row_ty, try e.constUint(m.rows) });
                try e.b.emit(.annotations, .decorate, &.{ id, 6, layout.matrixStride(e.t, ty, true, rules) }); // ArrayStride
            },
            .array => |a| {
                const elem = try e.layoutTypeId(a.elem, rules, row_major);
                try e.b.emit(.types_globals, .type_array, &.{ id, elem, try e.constUint(a.len) });
                const stride = layout.arrayStride(e.t, a.elem, row_major, rules) catch return e.unsupported("buffer member type", .{});
                try e.b.emit(.annotations, .decorate, &.{ id, 6, stride }); // ArrayStride
            },
            .@"struct" => |st| try e.layoutStruct(id, st, rules, st.name),
            else => return e.unsupported("buffer members of type '{s}' are not supported yet", .{try e.t.format(e.arena, ty)}),
        }
        try e.layout_types.put(e.arena, key, id);
        return id;
    }

    /// Emits struct `id` with `st`'s fields laid out by `rules`.
    fn layoutStruct(e: *Emitter, id: Id, st: *const types.StructInfo, rules: layout.Rules, name: []const u8) Error!void {
        {
            {
                var ops: std.ArrayList(u32) = .empty;
                try ops.append(e.arena, id);
                for (st.fields.items) |fld| try ops.append(e.arena, try e.layoutTypeId(fld.type, rules, fld.row_major));
                try e.b.emit(.types_globals, .type_struct, ops.items);
                const offs = layout.fieldOffsets(e.arena, e.t, st, rules) catch return e.unsupported("buffer member type '{s}'", .{st.name});
                for (st.fields.items, offs, 0..) |fld, o, k| {
                    const mk: u32 = @intCast(k);
                    try e.b.emit(.annotations, .member_decorate, &.{ id, mk, 35, o }); // Offset
                    // Float matrices (possibly in arrays): HLSL rows are
                    // SPIR-V columns, so column_major is RowMajor.
                    var inner = fld.type;
                    while (e.t.get(inner) == .array) inner = e.t.get(inner).array.elem;
                    if (e.isTrueMatrix(inner) and storageScalar(e.t.get(inner).matrix.elem).isFloat()) {
                        try e.b.emit(.annotations, .member_decorate, &.{ id, mk, 7, layout.matrixStride(e.t, inner, fld.row_major, rules) }); // MatrixStride
                        try e.b.emit(.annotations, .member_decorate, &.{ id, mk, if (fld.row_major) 5 else 4 }); // ColMajor / RowMajor
                    }
                    try e.b.emitWithString(.debug_names, .member_name, &.{ id, mk }, fld.name, &.{});
                }
                try e.b.emitWithString(.debug_names, .name, &.{id}, name, &.{});
            }
        }
    }

    /// The block of TextureBuffer<S>: S's members, std430, read-only.
    fn textureBufferBlock(e: *Emitter, s: TypeId) Error!Id {
        if (e.tb_blocks.get(s)) |id| return id;
        const st = e.t.get(s).@"struct";
        const id = e.b.newId();
        try e.layoutStruct(id, st, .std430, try std.fmt.allocPrint(e.arena, "type.TextureBuffer.{s}", .{st.name}));
        for (0..st.fields.items.len) |k| try e.b.emit(.annotations, .member_decorate, &.{ id, @intCast(k), 24 }); // NonWritable
        try e.b.emit(.annotations, .decorate, &.{ id, e.bufferBlockDecoration() });
        try e.tb_blocks.put(e.arena, s, id);
        return id;
    }

    /// The Block struct of ConstantBuffer<S>: S's members laid out as a
    /// constant buffer (a type of its own, so S itself can be nested).
    fn constantBufferBlock(e: *Emitter, s: TypeId) Error!Id {
        if (e.cb_blocks.get(s)) |id| return id;
        const st = e.t.get(s).@"struct";
        const id = e.b.newId();
        try e.layoutStruct(id, st, .vk_relaxed, try std.fmt.allocPrint(e.arena, "type.ConstantBuffer.{s}", .{st.name}));
        try e.b.emit(.annotations, .decorate, &.{ id, 2 }); // Block
        try e.cb_blocks.put(e.arena, s, id);
        return id;
    }

    /// A value loaded with a buffer layout, as the plain type.
    fn fromLayout(e: *Emitter, v: Id, ty: TypeId, rules: layout.Rules, row_major: bool) Error!Id {
        return e.relayout(v, ty, rules, row_major, true);
    }

    fn toLayout(e: *Emitter, v: Id, ty: TypeId, rules: layout.Rules, row_major: bool) Error!Id {
        return e.relayout(v, ty, rules, row_major, false);
    }

    fn relayout(e: *Emitter, v: Id, ty: TypeId, rules: layout.Rules, row_major: bool, from: bool) Error!Id {
        const lt = try e.layoutTypeId(ty, rules, row_major);
        const pt = try e.typeId(ty);
        switch (e.t.get(ty)) {
            .scalar, .vector, .@"enum" => {
                if (e.t.component(ty) != .bool) return v;
                const stored = try e.t.withComponent(ty, .uint);
                return if (from) e.convert(v, stored, ty) else e.convert(v, ty, stored);
            },
            .matrix => |m| {
                if (lt == pt) return v;
                // Row-major integer matrix <-> array of rows.
                const rows = try e.arena.alloc(u32, m.rows);
                const row_ty = try e.t.vector(m.elem, m.cols);
                const src_row = if (from) try e.layoutTypeId(row_ty, rules, false) else try e.typeId(row_ty);
                for (rows, 0..) |*rw, k| {
                    const el = try e.opRaw(.composite_extract, src_row, &.{ v, @intCast(k) });
                    rw.* = try e.relayout(el, row_ty, rules, false, from);
                }
                return e.opRaw(.composite_construct, if (from) pt else lt, rows);
            },
            .array => |a| {
                if (lt == pt) return v;
                const parts = try e.arena.alloc(u32, a.len);
                const src_el = if (from) try e.layoutTypeId(a.elem, rules, row_major) else try e.typeId(a.elem);
                for (parts, 0..) |*p, k| {
                    const el = try e.opRaw(.composite_extract, src_el, &.{ v, @intCast(k) });
                    p.* = try e.relayout(el, a.elem, rules, row_major, from);
                }
                return e.opRaw(.composite_construct, if (from) pt else lt, parts);
            },
            .@"struct" => |st| {
                const parts = try e.arena.alloc(u32, st.fields.items.len);
                for (st.fields.items, parts, 0..) |fld, *p, k| {
                    const src_el = if (from) try e.layoutTypeId(fld.type, rules, fld.row_major) else try e.typeId(fld.type);
                    const el = try e.opRaw(.composite_extract, src_el, &.{ v, @intCast(k) });
                    p.* = try e.relayout(el, fld.type, rules, fld.row_major, from);
                }
                return e.opRaw(.composite_construct, if (from) pt else lt, parts);
            },
            else => return e.unsupported("buffer values of type '{s}' are not supported yet", .{try e.t.format(e.arena, ty)}),
        }
    }

    fn opRaw(e: *Emitter, op: Op, ty_id: Id, operands: []const u32) Error!Id {
        const id = e.b.newId();
        var ops: std.ArrayList(u32) = .empty;
        try ops.appendSlice(e.arena, &.{ ty_id, id });
        try ops.appendSlice(e.arena, operands);
        try e.b.emit(.functions, op, ops.items);
        return id;
    }

    fn pointerType(e: *Emitter, sc: StorageClass, pointee: Id) Error!Id {
        if (e.pointer_types.get(.{ sc, pointee })) |id| return id;
        const id = e.b.newId();
        try e.b.emit(.types_globals, .type_pointer, &.{ id, @backingInt(sc), pointee });
        try e.pointer_types.put(e.arena, .{ sc, pointee }, id);
        return id;
    }

    fn functionType(e: *Emitter, ret: Id, params: []const Id) Error!Id {
        var key: std.ArrayList(u8) = .empty;
        try key.print(e.arena, "{d},", .{ret});
        for (params) |p| try key.print(e.arena, "{d},", .{p});
        if (e.function_types.get(key.items)) |id| return id;
        const id = e.b.newId();
        var ops: std.ArrayList(u32) = .empty;
        try ops.appendSlice(e.arena, &.{ id, ret });
        try ops.appendSlice(e.arena, params);
        try e.b.emit(.types_globals, .type_function, ops.items);
        try e.function_types.put(e.arena, key.items, id);
        return id;
    }

    fn constBits(e: *Emitter, ty_id: Id, bits: u64, words: u32) Error!Id {
        if (e.constants.get(.{ ty_id, bits })) |id| return id;
        const id = e.b.newId();
        if (words == 2) {
            try e.b.emit(.types_globals, .constant, &.{ ty_id, id, @truncate(bits), @truncate(bits >> 32) });
        } else try e.b.emit(.types_globals, .constant, &.{ ty_id, id, @truncate(bits) });
        try e.constants.put(e.arena, .{ ty_id, bits }, id);
        return id;
    }

    fn constUint(e: *Emitter, v: u64) Error!Id {
        return e.constBits(try e.scalarType(.uint), v, 1);
    }

    fn constInt(e: *Emitter, v: i64) Error!Id {
        return e.constBits(try e.scalarType(.int), @as(u32, @bitCast(@as(i32, @truncate(v)))), 1);
    }

    /// A scalar constant of HLSL type `ty`.
    fn constant(e: *Emitter, ty: TypeId, c: ir.Constant) Error!Id {
        const s = storageScalar(e.t.component(ty).?);
        const ty_id = try e.scalarType(s);
        switch (s) {
            .bool => {
                const v = switch (c) {
                    .int => |i| i != 0,
                    .float => |f| f != 0,
                };
                if (e.constants.get(.{ ty_id, @intFromBool(v) })) |id| return id;
                const id = e.b.newId();
                try e.b.emit(.types_globals, if (v) .constant_true else .constant_false, &.{ ty_id, id });
                try e.constants.put(e.arena, .{ ty_id, @intFromBool(v) }, id);
                return id;
            },
            .float => return e.constBits(ty_id, @as(u32, @bitCast(@as(f32, @floatCast(floatOf(c))))), 1),
            .double => return e.constBits(ty_id, @bitCast(floatOf(c)), 2),
            .float16 => return e.constBits(ty_id, @as(u16, @bitCast(@as(f16, @floatCast(floatOf(c))))), 1),
            .int64, .uint64 => return e.constBits(ty_id, @bitCast(intOf(c)), 2),
            // Narrow signed literals are sign-extended to the word.
            .int16 => return e.constBits(ty_id, @as(u32, @bitCast(@as(i32, @as(i16, @truncate(intOf(c)))))), 1),
            .uint16 => return e.constBits(ty_id, @as(u16, @truncate(@as(u64, @bitCast(intOf(c))))), 1),
            else => return e.constBits(ty_id, @as(u32, @truncate(@as(u64, @bitCast(intOf(c))))), 1),
        }
    }

    fn floatOf(c: ir.Constant) f64 {
        return switch (c) {
            .int => |i| @floatFromInt(i),
            .float => |f| f,
        };
    }

    fn intOf(c: ir.Constant) i64 {
        return switch (c) {
            .int => |i| i,
            .float => |f| @import("../ir/lower.zig").saturatingInt(f),
        };
    }

    // ------------------------------------------------------------------
    // Module

    fn module(e: *Emitter) Error!void {
        const m = e.m;
        if (m.entries.items.len == 0 and m.exports.items.len == 0) return e.unsupported("no entry point", .{});
        try e.b.emit(.debug_names, .source, &.{ 5, 600 }); // HLSL
        e.void_id = try e.typeId(TypeTable.void_type);
        try e.cap(.shader);
        e.states = try e.arena.alloc(EntryState, @max(1, m.entries.items.len));
        for (e.states) |*st| st.* = .{};
        e.st = &e.states[0];
        if (m.entries.items.len > 0) {
            e.entry = &m.entries.items[0];
        } else {
            // Exports only: functions see no entry interface.
            const none = try e.arena.create(ir.Entry);
            none.* = .{ .func = 0, .name = "", .stage = .library };
            e.entry = none;
        }
        // Vulkan has no linkage: exports are plain functions there.
        const link = m.exports.items.len > 0 and e.universal;
        if (m.entries.items.len == 0 and !link) return e.unsupported("libraries without entry points need a universal target environment (-fspv-target-env=universal1.5)", .{});
        if (link) try e.cap(.linkage);
        for (m.entries.items) |*entry| {
            if (entry.stage == .geometry) try e.cap(.geometry);
            if (entry.stage == .mesh or entry.stage == .amplification) {
                if (e.spv_minor < 4) return e.unsupported("mesh and amplification shaders need SPIR-V 1.4 or later (-fspv-target-env=vulkan1.2 or later)", .{});
                if (m.entries.items.len > 1) return e.unsupported("mesh and amplification shaders in libraries are not supported yet", .{});
                try e.cap(.mesh_shading_ext);
                try e.extension("SPV_EXT_mesh_shader");
                e.payload_global = e.dispatchPayloadGlobal();
                try e.findMeshParams();
            }
            if (entry.stage.isRayTracing()) {
                if (e.spv_minor < 4) return e.unsupported("ray tracing shaders need SPIR-V 1.4 or later (-fspv-target-env=vulkan1.2 or later)", .{});
                try e.cap(.ray_tracing_khr);
                try e.extension("SPV_KHR_ray_tracing");
            }
        }

        e.func_ids = try e.arena.alloc(Id, m.functions.items.len);
        for (e.func_ids) |*id| id.* = e.b.newId();
        if (link) for (m.exports.items) |fi| {
            if (e.hasResourceParams(m.functions.items[fi])) return e.unsupported("exported functions with resource parameters are not supported yet", .{});
            try e.b.emitWithString(.annotations, .decorate, &.{ e.func_ids[fi], 41 }, m.functions.items[fi].name, &.{0}); // LinkageAttributes Export
        };

        try e.emitGlobals();
        for (m.entries.items, 0..) |entry, k| {
            e.setEntry(@intCast(k));
            try e.emitInterface(entry);
        }

        for (m.functions.items, e.func_ids) |f, id| {
            e.setEntry(f.entry);
            if (!e.hasResourceParams(f)) try e.emitFunction(f, id, &.{});
        }
        var vi: usize = 0;
        while (vi < e.variants.items.len) : (vi += 1) {
            const v = e.variants.items[vi];
            e.setEntry(m.functions.items[v.fi].entry);
            try e.emitFunction(m.functions.items[v.fi], v.id, v.bindings);
        }

        for (e.capabilities.keys()) |c| try e.b.emit(.capabilities, .capability, &.{@backingInt(c)});
        if (e.glsl != 0) try e.b.emitWithString(.ext_inst_imports, .ext_inst_import, &.{e.glsl}, "GLSL.std.450", &.{});
        try e.b.emit(.memory_model, .memory_model, &.{ 0, 1 }); // Logical GLSL450
        for (m.entries.items, 0..) |*entry, k| {
            e.setEntry(@intCast(k));
            try e.entryPoint(entry);
        }
        for (m.functions.items, e.func_ids) |f, id| {
            if (!e.hasResourceParams(f)) try e.b.emitWithString(.debug_names, .name, &.{id}, f.name, &.{});
        }
    }

    fn recordCall(e: *Emitter, callee: Id) Error!void {
        const gop = try e.fn_calls.getOrPut(e.arena, e.cur_fn);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(e.arena, callee);
    }

    fn setEntry(e: *Emitter, k: u32) void {
        e.st = &e.states[k];
        if (k < e.m.entries.items.len) e.entry = &e.m.entries.items[k];
    }

    /// Records that the current function (or, outside functions, the
    /// current entry) uses interface variable `v`.
    fn useVar(e: *Emitter, v: Id) Error!void {
        const list = if (e.cur_fn == 0) &e.st.iface else blk: {
            const gop = try e.fn_uses.getOrPut(e.arena, e.cur_fn);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            break :blk gop.value_ptr;
        };
        for (list.items) |x| if (x == v) return;
        try list.append(e.arena, v);
    }

    /// The entry's interface: its own variables and those of every
    /// function it reaches (from SPIR-V 1.4 every global it may use).
    fn entryInterface(e: *Emitter, wrapper: Id) Error![]const Id {
        var out: std.AutoArrayHashMapUnmanaged(Id, void) = .empty;
        for (e.st.iface.items) |v| try out.put(e.arena, v, {});
        var seen: std.AutoHashMapUnmanaged(Id, void) = .empty;
        var stack: std.ArrayList(Id) = .empty;
        try stack.append(e.arena, wrapper);
        while (stack.pop()) |fid| {
            if ((try seen.getOrPut(e.arena, fid)).found_existing) continue;
            if (e.fn_uses.get(fid)) |us| for (us.items) |v| try out.put(e.arena, v, {});
            if (e.fn_calls.get(fid)) |cs| try stack.appendSlice(e.arena, cs.items);
        }
        if (e.spv_minor >= 4) {
            // (Shader record buffers only where used: at most one each.)
            for (e.global_vars, e.m.globals.items) |v, g| if (v != 0 and !g.shader_record) try out.put(e.arena, v, {});
            for (e.counter_vars) |v| if (v != 0) try out.put(e.arena, v, {});
        }
        return out.keys();
    }

    fn entryPoint(e: *Emitter, entry: *const ir.Entry) Error!void {
        const model: u32 = switch (entry.stage) {
            .vertex => 0,
            .hull => 1,
            .domain => 2,
            .geometry => 3,
            .pixel => 4,
            .compute => 5,
            .amplification => 5364, // TaskEXT
            .mesh => 5365, // MeshEXT
            .raygeneration => 5313, // RayGenerationKHR
            .intersection => 5314,
            .anyhit => 5315,
            .closesthit => 5316,
            .miss => 5317,
            .callable => 5318,
            .library => return e.unsupported("library targets are not supported", .{}),
        };
        const wrapper = e.func_ids[entry.wrapper];
        try e.b.emitWithString(.entry_points, .entry_point, &.{ model, wrapper }, entry.name, try e.entryInterface(wrapper));
        switch (entry.stage) {
            .compute => try e.b.emit(.execution_modes, .execution_mode, &.{ wrapper, 17, entry.num_threads[0], entry.num_threads[1], entry.num_threads[2] }),
            .geometry => {
                const gsi = entry.geometry;
                try e.b.emit(.execution_modes, .execution_mode, &.{ wrapper, 0, gsi.instance_count }); // Invocations
                const in_mode: u32 = switch (gsi.input) {
                    .point => 19,
                    .line => 20,
                    .line_adj => 21,
                    .triangle => 22,
                    .triangle_adj => 23,
                };
                try e.b.emit(.execution_modes, .execution_mode, &.{ wrapper, in_mode });
                try e.b.emit(.execution_modes, .execution_mode, &.{ wrapper, 26, gsi.max_vertex_count }); // OutputVertices
                const out_mode: u32 = if (gsi.streams[0]) |k| switch (k) {
                    .point => 27,
                    .line => 28,
                    .triangle => 29,
                } else 27;
                try e.b.emit(.execution_modes, .execution_mode, &.{ wrapper, out_mode });
            },
            .hull => {
                const ts = entry.tess;
                try e.b.emit(.execution_modes, .execution_mode, &.{ wrapper, domainMode(ts.domain) });
                try e.b.emit(.execution_modes, .execution_mode, &.{ wrapper, switch (ts.partitioning) {
                    .integer, .pow2 => 1, // SpacingEqual
                    .fractional_even => 2,
                    .fractional_odd => 3,
                } });
                switch (ts.output_topology) {
                    .triangle_cw => try e.b.emit(.execution_modes, .execution_mode, &.{ wrapper, 4 }), // VertexOrderCw
                    .triangle_ccw => try e.b.emit(.execution_modes, .execution_mode, &.{ wrapper, 5 }), // VertexOrderCcw
                    .point => try e.b.emit(.execution_modes, .execution_mode, &.{ wrapper, 10 }), // PointMode
                    .line => {},
                }
                try e.b.emit(.execution_modes, .execution_mode, &.{ wrapper, 26, ts.output_control_points }); // OutputVertices
            },
            .domain => try e.b.emit(.execution_modes, .execution_mode, &.{ wrapper, domainMode(entry.tess.domain) }),
            .amplification => try e.b.emit(.execution_modes, .execution_mode, &.{ wrapper, 17, entry.num_threads[0], entry.num_threads[1], entry.num_threads[2] }),
            .mesh => {
                const ms = entry.mesh;
                try e.b.emit(.execution_modes, .execution_mode, &.{ wrapper, 17, entry.num_threads[0], entry.num_threads[1], entry.num_threads[2] });
                try e.b.emit(.execution_modes, .execution_mode, &.{ wrapper, if (ms.topology == .line) 5269 else 5298 }); // OutputLinesEXT / OutputTrianglesEXT
                try e.b.emit(.execution_modes, .execution_mode, &.{ wrapper, 26, ms.max_vertices }); // OutputVertices
                try e.b.emit(.execution_modes, .execution_mode, &.{ wrapper, 5270, ms.max_primitives }); // OutputPrimitivesEXT
            },
            .pixel => {
                try e.b.emit(.execution_modes, .execution_mode, &.{ wrapper, 7 }); // OriginUpperLeft
                for (entry.outputs.items) |o| {
                    const eqi = std.ascii.eqlIgnoreCase;
                    if (eqi(o.semantic, "SV_Depth") or eqi(o.semantic, "SV_DepthLessEqual") or eqi(o.semantic, "SV_DepthGreaterEqual")) {
                        try e.b.emit(.execution_modes, .execution_mode, &.{ wrapper, 12 }); // DepthReplacing
                    }
                    if (eqi(o.semantic, "SV_DepthLessEqual")) try e.b.emit(.execution_modes, .execution_mode, &.{ wrapper, 15 }); // DepthLess
                    if (eqi(o.semantic, "SV_DepthGreaterEqual")) try e.b.emit(.execution_modes, .execution_mode, &.{ wrapper, 14 }); // DepthGreater
                }
            },
            else => {},
        }
        if (e.st.derivative_mode != 0) try e.b.emit(.execution_modes, .execution_mode, &.{ wrapper, e.st.derivative_mode });
    }

    fn domainMode(d: ir.Domain) u32 {
        return switch (d) {
            .tri => 22, // Triangles
            .quad => 24, // Quads
            .isoline => 25, // Isolines
        };
    }

    fn emitGlobals(e: *Emitter) Error!void {
        const m = e.m;
        e.global_vars = try e.arena.alloc(Id, m.globals.items.len);

        // Registers without an explicit binding take the next free one.
        var used: std.AutoHashMapUnmanaged(struct { u32, u32 }, void) = .empty;
        for (m.globals.items) |g| if (g.binding.explicit) try used.put(e.arena, .{ g.binding.space, g.binding.index }, {});
        var next_free: u32 = 0;
        for (m.globals.items, 0..) |g, gi| {
            switch (g.space) {
                .resource, .cbuffer => if (g.shader_record) {
                    // Shader record buffers: std430, no descriptor.
                    const st = e.t.get(if (g.space == .resource) e.t.get(g.ty).resource.elem else g.ty);
                    if (st != .@"struct") return e.unsupported("this shader record buffer is not supported yet", .{});
                    const block = e.b.newId();
                    try e.layoutStruct(block, st.@"struct", .std430, try std.fmt.allocPrint(e.arena, "type.ShaderRecord.{s}", .{g.name}));
                    try e.b.emit(.annotations, .decorate, &.{ block, 2 }); // Block
                    const var_id = e.b.newId();
                    try e.b.emit(.types_globals, .variable, &.{ try e.pointerType(.shader_record_buffer_khr, block), var_id, @backingInt(StorageClass.shader_record_buffer_khr) });
                    try e.b.emitWithString(.debug_names, .name, &.{var_id}, g.name, &.{});
                    e.global_vars[gi] = var_id;
                    continue;
                },
                else => {},
            }
            switch (g.space) {
                .resource => {
                    const var_id = e.b.newId();
                    const p = try e.resourcePointee(g.ty);
                    try e.b.emit(.types_globals, .variable, &.{ try e.pointerType(p.sc, p.ty), var_id, @backingInt(p.sc) });
                    var binding = g.binding.index;
                    if (!g.binding.explicit) {
                        while (used.contains(.{ g.binding.space, next_free })) next_free += 1;
                        binding = next_free;
                        try used.put(e.arena, .{ g.binding.space, binding }, {});
                    }
                    try e.b.emit(.annotations, .decorate, &.{ var_id, 34, g.binding.space }); // DescriptorSet
                    try e.b.emit(.annotations, .decorate, &.{ var_id, 33, binding }); // Binding
                    try e.b.emitWithString(.debug_names, .name, &.{var_id}, g.name, &.{});
                    e.global_vars[gi] = var_id;
                },
                .cbuffer => {
                    // tbuffers: read-only storage buffers, std430.
                    const st = try e.layoutTypeId(g.ty, if (g.tbuffer) .std430 else .vk_relaxed, false);
                    try e.b.emit(.annotations, .decorate, &.{ st, if (g.tbuffer) e.bufferBlockDecoration() else 2 }); // Block
                    if (g.tbuffer) for (0..e.t.get(g.ty).@"struct".fields.items.len) |k| {
                        try e.b.emit(.annotations, .member_decorate, &.{ st, @intCast(k), 24 }); // NonWritable
                    };
                    const sc: StorageClass = if (g.tbuffer) e.bufferSc() else .uniform;
                    const ptr = try e.pointerType(sc, st);
                    const var_id = e.b.newId();
                    try e.b.emit(.types_globals, .variable, &.{ ptr, var_id, @backingInt(sc) });
                    var binding = g.binding.index;
                    if (!g.binding.explicit) {
                        while (used.contains(.{ g.binding.space, next_free })) next_free += 1;
                        binding = next_free;
                        try used.put(e.arena, .{ g.binding.space, binding }, {});
                    }
                    try e.b.emit(.annotations, .decorate, &.{ var_id, 34, g.binding.space }); // DescriptorSet
                    try e.b.emit(.annotations, .decorate, &.{ var_id, 33, binding }); // Binding
                    try e.b.emitWithString(.debug_names, .name, &.{st}, try std.fmt.allocPrint(e.arena, "type.{s}", .{g.name}), &.{});
                    try e.b.emitWithString(.debug_names, .name, &.{var_id}, g.name, &.{});
                    e.global_vars[gi] = var_id;
                },
                .groupshared, .private => {
                    const ty = try e.typeId(g.ty);
                    const sc: StorageClass = if (e.payload_global == @as(u32, @intCast(gi))) .task_payload_workgroup else if (g.space == .groupshared) .workgroup else .private;
                    const ptr = try e.pointerType(sc, ty);
                    const var_id = e.b.newId();
                    try e.b.emit(.types_globals, .variable, &.{ ptr, var_id, @backingInt(sc) });
                    try e.b.emitWithString(.debug_names, .name, &.{var_id}, g.name, &.{});
                    e.global_vars[gi] = var_id;
                },
                else => return e.unsupported("global '{s}' is not supported yet", .{g.name}),
            }
        }

        // Descriptor heaps: the next free bindings of set 0 (resources,
        // then samplers), as dxc.
        for ([_]bool{ false, true }) |sampler| {
            const used_heap = for (m.functions.items) |f| {
                const hit = for (f.insts.items) |inst| switch (inst.op) {
                    .heap_resource => |h| if (h.sampler == sampler) break true,
                    else => {},
                } else false;
                if (hit) break true;
            } else false;
            if (!used_heap) continue;
            while (used.contains(.{ 0, next_free })) next_free += 1;
            try used.put(e.arena, .{ 0, next_free }, {});
            e.heap_bindings[@intFromBool(sampler)] = next_free;
        }

        // Hidden counters (as dxc): a `{ int }` buffer per structured buffer
        // that uses one, on the next free binding of its set.
        try e.findCounterGlobals();
        e.counter_vars = try e.arena.alloc(Id, m.globals.items.len);
        @memset(e.counter_vars, 0);
        for (m.globals.items, 0..) |g, gi| {
            if (!e.needsCounter(@intCast(gi))) continue;
            if (e.counter_type == 0) {
                e.counter_type = e.b.newId();
                try e.b.emit(.types_globals, .type_struct, &.{ e.counter_type, try e.scalarType(.int) });
                try e.b.emit(.annotations, .member_decorate, &.{ e.counter_type, 0, 35, 0 }); // Offset 0
                try e.b.emit(.annotations, .decorate, &.{ e.counter_type, e.bufferBlockDecoration() });
                try e.b.emitWithString(.debug_names, .name, &.{e.counter_type}, "type.ACSBuffer.counter", &.{});
            }
            // Arrays of buffers: an array of counters of the same shape.
            var cty = e.counter_type;
            var dims: std.ArrayList(u32) = .empty;
            var at = g.ty;
            while (e.t.get(at) == .array) : (at = e.t.get(at).array.elem) try dims.append(e.arena, e.t.get(at).array.len);
            var di = dims.items.len;
            while (di > 0) {
                di -= 1;
                const arr = e.b.newId();
                if (dims.items[di] == 0) {
                    try e.cap(.runtime_descriptor_array);
                    try e.extension("SPV_EXT_descriptor_indexing");
                    try e.b.emit(.types_globals, .type_runtime_array, &.{ arr, cty });
                } else try e.b.emit(.types_globals, .type_array, &.{ arr, cty, try e.constUint(dims.items[di]) });
                cty = arr;
            }
            const var_id = e.b.newId();
            try e.b.emit(.types_globals, .variable, &.{ try e.pointerType(e.bufferSc(), cty), var_id, @backingInt(e.bufferSc()) });
            while (used.contains(.{ g.binding.space, next_free })) next_free += 1;
            try used.put(e.arena, .{ g.binding.space, next_free }, {});
            try e.b.emit(.annotations, .decorate, &.{ var_id, 34, g.binding.space }); // DescriptorSet
            try e.b.emit(.annotations, .decorate, &.{ var_id, 33, next_free }); // Binding
            try e.b.emitWithString(.debug_names, .name, &.{var_id}, try std.fmt.allocPrint(e.arena, "counter.var.{s}", .{g.name}), &.{});
            e.counter_vars[gi] = var_id;
        }
    }

    /// Append/Consume buffers, and structured buffers whose counter is
    /// incremented or decremented somewhere.
    fn needsCounter(e: *Emitter, gi: u32) bool {
        var gty = e.m.globals.items[gi].ty;
        while (e.t.get(gty) == .array) gty = e.t.get(gty).array.elem;
        const r = switch (e.t.get(gty)) {
            .resource => |r| r,
            else => return false,
        };
        if (r.kind == .append_structured_buffer or r.kind == .consume_structured_buffer) return true;
        if (r.kind != .rw_structured_buffer) return false;
        return e.counter_globals.contains(gi);
    }

    /// The globals whose counter is used: directly, or through the
    /// parameters (and resource locals) of the functions they are passed
    /// to.
    fn findCounterGlobals(e: *Emitter) Error!void {
        const Origin = union(enum) { global: u32, param: struct { *const ir.Function, u32 }, none };
        const origin = struct {
            fn f(func: *const ir.Function, r: Ref) Origin {
                var x = r;
                while (true) switch (func.inst(x).op) {
                    .load => |p| x = p,
                    .access => |a| x = a.base,
                    .local_var => x = for (func.insts.items) |inst| {
                        if (inst.op == .store and inst.op.store.ptr == x) break inst.op.store.value;
                    } else return .none,
                    .global => |g| return .{ .global = g },
                    .param => |p| return .{ .param = .{ func, p } },
                    else => return .none,
                };
            }
        }.f;
        var params: std.AutoHashMapUnmanaged(struct { *const ir.Function, u32 }, void) = .empty;
        const mark = struct {
            fn f(em: *Emitter, ps: *std.AutoHashMapUnmanaged(struct { *const ir.Function, u32 }, void), o: Origin) Error!bool {
                switch (o) {
                    .global => |g| {
                        if (em.counter_globals.contains(g)) return false;
                        try em.counter_globals.put(em.arena, g, {});
                        return true;
                    },
                    .param => |p| {
                        if (ps.contains(p)) return false;
                        try ps.put(em.arena, p, {});
                        return true;
                    },
                    .none => return false,
                }
            }
        }.f;
        for (e.m.functions.items) |f| for (f.insts.items) |inst| switch (inst.op) {
            .method => |mt| {
                const eq = std.mem.eql;
                if (!eq(u8, mt.name, "IncrementCounter") and !eq(u8, mt.name, "DecrementCounter") and !eq(u8, mt.name, "Append") and !eq(u8, mt.name, "Consume")) continue;
                _ = try mark(e, &params, origin(f, mt.res));
            },
            else => {},
        };
        var changed = true;
        while (changed) {
            changed = false;
            for (e.m.functions.items) |f| for (f.insts.items) |inst| switch (inst.op) {
                .call => |c| {
                    const callee = e.m.functions.items[c.func];
                    for (c.args, 0..) |a, k| {
                        if (!params.contains(.{ callee, @intCast(k) })) continue;
                        if (try mark(e, &params, origin(f, a))) changed = true;
                    }
                },
                else => {},
            };
        }
    }

    /// The counter update for IncrementCounter / DecrementCounter / Append /
    /// Consume: returns the index (or counter value) as uint.
    fn counterOp(e: *Emitter, res: Ref, increment: bool, post: bool) Error!Id {
        // An element of an array of buffers: the same element of the
        // counters.
        var indices: std.ArrayList(u32) = .empty;
        var x = res;
        while (true) switch (e.f.inst(x).op) {
            .load => |p| x = p,
            .access => |a| {
                var k = a.indices.len;
                while (k > 0) {
                    k -= 1;
                    try indices.insert(e.arena, 0, e.val(a.indices[k]));
                }
                x = a.base;
            },
            else => break,
        };
        const g = e.globalOf(x) orelse return e.unsupported("counters of resources not tied to a global are not supported yet", .{});
        const cv = e.counter_vars[g];
        if (cv == 0) return e.unsupported("this buffer has no counter", .{});
        const int_ty = try e.t.scalar(.int);
        var ops: std.ArrayList(u32) = .empty;
        try ops.append(e.arena, cv);
        try ops.appendSlice(e.arena, indices.items);
        try ops.append(e.arena, try e.constUint(0));
        const ptr = try e.opRaw(.access_chain, try e.pointerType(e.bufferSc(), try e.scalarType(.int)), ops.items);
        const old = try e.op1(if (increment) .atomic_i_add else .atomic_i_sub, int_ty, &.{ ptr, try e.constUint(1), try e.constUint(0), try e.constInt(1) });
        // Decrements report the new value.
        const v = if (post) try e.op1(.i_sub, int_ty, &.{ old, try e.constInt(1) }) else old;
        return e.op1(.bitcast, try e.t.scalar(.uint), &.{v});
    }

    /// `float`, `v4float`: dxc's type names inside buffer type names.
    fn typeLabel(e: *Emitter, ty: TypeId) Error![]const u8 {
        return switch (e.t.get(ty)) {
            .scalar => |s| storageScalar(s).name(),
            .vector => |v| std.fmt.allocPrint(e.arena, "v{d}{s}", .{ v.len, storageScalar(v.elem).name() }),
            .matrix => |m| std.fmt.allocPrint(e.arena, "mat{d}v{d}{s}", .{ m.rows, m.cols, storageScalar(m.elem).name() }),
            else => e.t.format(e.arena, ty),
        };
    }

    // ------------------------------------------------------------------
    // Entry interface

    const Builtin = struct { id: u32, ty: TypeId };

    fn builtinFor(e: *Emitter, el: ir.SigElement, input: bool, stage: ir.Stage) Error!?Builtin {
        const t = e.t;
        const n = el.semantic;
        const uint3 = try t.vector(.uint, 3);
        const uint1 = try t.scalar(.uint);
        const float4 = try t.vector(.float, 4);
        const eq = std.ascii.eqlIgnoreCase;
        // Builtins exist only for some stages and directions; elsewhere a
        // system value is an ordinary located variable (as in dxc).
        if ((stage == .compute or stage == .mesh or stage == .amplification) and input) {
            if (eq(n, "SV_DispatchThreadID")) return .{ .id = 28, .ty = uint3 }; // GlobalInvocationId
            if (eq(n, "SV_GroupID")) return .{ .id = 26, .ty = uint3 }; // WorkgroupId
            if (eq(n, "SV_GroupThreadID")) return .{ .id = 27, .ty = uint3 }; // LocalInvocationId
            if (eq(n, "SV_GroupIndex")) return .{ .id = 29, .ty = uint1 }; // LocalInvocationIndex
        }
        if (stage == .vertex and input) {
            if (eq(n, "SV_VertexID")) return .{ .id = 42, .ty = uint1 }; // VertexIndex
            if (eq(n, "SV_InstanceID")) return .{ .id = 43, .ty = uint1 }; // InstanceIndex
        }
        if (eq(n, "SV_Position")) {
            if (stage == .pixel and input) return .{ .id = 15, .ty = float4 }; // FragCoord
            if (!(stage == .vertex and input) and !(stage == .pixel)) return .{ .id = 0, .ty = float4 }; // Position
        }
        if (stage == .pixel and input and eq(n, "SV_IsFrontFace")) return .{ .id = 17, .ty = try t.scalar(.bool) }; // FrontFacing
        if (input and (stage == .geometry or stage == .pixel) and eq(n, "SV_PrimitiveID")) {
            try e.cap(.geometry);
            return .{ .id = 7, .ty = uint1 }; // PrimitiveId
        }
        if (input and stage == .geometry and eq(n, "SV_GSInstanceID")) return .{ .id = 8, .ty = uint1 }; // InvocationId
        if (stage == .mesh and !input) {
            if (eq(n, "SV_CullPrimitive")) return .{ .id = 5299, .ty = try t.scalar(.bool) }; // CullPrimitiveEXT
            if (eq(n, "SV_PrimitiveID")) return .{ .id = 7, .ty = uint1 }; // PrimitiveId
        }
        if ((!input and (stage == .geometry or stage == .mesh)) or (input and stage == .pixel)) {
            if (eq(n, "SV_RenderTargetArrayIndex")) {
                try e.cap(.geometry);
                return .{ .id = 9, .ty = uint1 }; // Layer
            }
            if (eq(n, "SV_ViewportArrayIndex")) {
                try e.cap(.geometry);
                try e.cap(.multi_viewport);
                return .{ .id = 10, .ty = uint1 }; // ViewportIndex
            }
        }
        if (input and stage == .pixel and eq(n, "SV_SampleIndex")) {
            try e.cap(.sample_rate_shading);
            return .{ .id = 18, .ty = uint1 }; // SampleId
        }
        if (stage == .pixel and !input and eq(n, "SV_Depth")) return .{ .id = 22, .ty = try t.scalar(.float) }; // FragDepth
        if (stage == .hull or stage == .domain) {
            if (eq(n, "SV_TessFactor")) return .{ .id = 11, .ty = try t.array(try t.scalar(.float), 4) }; // TessLevelOuter
            if (eq(n, "SV_InsideTessFactor")) return .{ .id = 12, .ty = try t.array(try t.scalar(.float), 2) }; // TessLevelInner
            if (input and eq(n, "SV_PrimitiveID")) return .{ .id = 7, .ty = uint1 }; // PrimitiveId
        }
        if (stage == .domain and input and eq(n, "SV_DomainLocation")) return .{ .id = 13, .ty = try t.vector(.float, 3) }; // TessCoord
        if (stage == .hull and input and eq(n, "SV_OutputControlPointID")) return .{ .id = 8, .ty = uint1 }; // InvocationId
        if (input and eq(n, "SV_ViewID")) {
            try e.cap(.multi_view);
            try e.extension("SPV_KHR_multiview");
            return .{ .id = 4440, .ty = uint1 }; // ViewIndex
        }
        if (stage == .vertex and input and (eq(n, "SV_StartVertexLocation") or eq(n, "SV_StartInstanceLocation"))) {
            try e.cap(.draw_parameters);
            try e.extension("SPV_KHR_shader_draw_parameters");
            return .{ .id = if (eq(n, "SV_StartVertexLocation")) 4424 else 4425, .ty = uint1 }; // BaseVertex / BaseInstance
        }
        if (!input and (stage == .vertex or stage == .domain) and (eq(n, "SV_ViewportArrayIndex") or eq(n, "SV_RenderTargetArrayIndex"))) {
            try e.cap(.shader_viewport_index_layer_ext);
            try e.extension("SPV_EXT_shader_viewport_index_layer");
            return .{ .id = if (eq(n, "SV_ViewportArrayIndex")) 10 else 9, .ty = uint1 }; // ViewportIndex / Layer
        }
        if (eq(n, "SV_ShadingRate") and ((input and stage == .pixel) or (!input and (stage == .vertex or stage == .geometry or stage == .mesh)))) {
            try e.cap(.fragment_shading_rate_khr);
            try e.extension("SPV_KHR_fragment_shading_rate");
            return .{ .id = if (input) 4444 else 4432, .ty = uint1 }; // ShadingRateKHR / PrimitiveShadingRateKHR
        }
        if (stage == .pixel) {
            if (eq(n, "SV_Coverage")) return .{ .id = 20, .ty = try t.array(uint1, 1) }; // SampleMask
            if (input and eq(n, "SV_InnerCoverage")) {
                try e.cap(.fragment_fully_covered_ext);
                try e.extension("SPV_EXT_fragment_fully_covered");
                return .{ .id = 5264, .ty = try t.scalar(.bool) }; // FullyCoveredEXT
            }
            if (!input and eq(n, "SV_StencilRef")) {
                try e.cap(.stencil_export_ext);
                try e.extension("SPV_EXT_shader_stencil_export");
                return .{ .id = 5014, .ty = uint1 }; // FragStencilRefEXT
            }
            if (!input and (eq(n, "SV_DepthLessEqual") or eq(n, "SV_DepthGreaterEqual"))) return .{ .id = 22, .ty = try t.scalar(.float) }; // FragDepth
            if (input and eq(n, "SV_Barycentrics")) {
                try e.cap(.fragment_barycentric_khr);
                try e.extension("SPV_KHR_fragment_shader_barycentric");
                return .{ .id = if (el.interp.noperspective) 5287 else 5286, .ty = try t.vector(.float, 3) }; // BaryCoord{NoPersp}KHR
            }
        }
        if (!input and stage == .geometry) {
            if (eq(n, "SV_PrimitiveID")) return .{ .id = 7, .ty = uint1 }; // PrimitiveId
            if (eq(n, "SV_IsFrontFace")) return null; // a located variable
        }
        if (eq(n, "SV_Target") or eq(n, "SV_VertexID") or eq(n, "SV_InstanceID") or eq(n, "SV_Position")) return null;
        if (el.system_value) return e.unsupported("system value '{s}' is not supported yet", .{n});
        return null;
    }

    fn emitInterface(e: *Emitter, entry: ir.Entry) Error!void {
        e.st.inputs = try e.arena.alloc(Interface, entry.inputs.items.len);
        e.st.outputs = try e.arena.alloc(Interface, entry.outputs.items.len);
        e.st.patches = try e.arena.alloc(Interface, entry.patch_constants.items.len);
        if (entry.stage == .hull or entry.stage == .domain) try e.cap(.tessellation);
        // Variables needing a Location, assigned once all exist.
        const Located = struct { var_id: Id, key: []const u8, count: u32, input: bool, target: ?u32 };
        var located: std.ArrayList(Located) = .empty;
        const lists = [_][]const ir.SigElement{ entry.inputs.items, entry.outputs.items, entry.patch_constants.items };
        const ifaces = [_][]Interface{ e.st.inputs, e.st.outputs, e.st.patches };
        for (lists, ifaces, 0..) |els, out, li| {
            const patch = li == 2;
            const input = if (patch) entry.stage == .domain else li == 0;
            // ClipDistance / CullDistance: one float array per direction,
            // the elements packed in semantic index order (as dxc).
            const ClipSlot = struct { kind: u1, base: u32 };
            const slots = try e.arena.alloc(?ClipSlot, els.len);
            @memset(slots, null);
            var clip_vars: [2]Id = .{ 0, 0 };
            var totals: [2]u32 = .{ 0, 0 };
            for (0..2) |kind| {
                var order: std.ArrayList(usize) = .empty;
                // (Vertex shader inputs are ordinary located variables.)
                if (input and entry.stage == .vertex) break;
                for (els, 0..) |el, k| {
                    const want = if (kind == 0) "SV_ClipDistance" else "SV_CullDistance";
                    if (std.ascii.eqlIgnoreCase(el.semantic, want)) try order.append(e.arena, k);
                }
                if (order.items.len == 0) continue;
                std.sort.insertion(usize, order.items, els, struct {
                    fn lt(xs: []const ir.SigElement, a: usize, b: usize) bool {
                        return xs[a].semantic_index < xs[b].semantic_index;
                    }
                }.lt);
                for (order.items) |k| {
                    if (els[k].per_vertex) return e.unsupported("per-vertex {s} inputs are not supported yet", .{els[k].semantic});
                    slots[k] = .{ .kind = @intCast(kind), .base = totals[kind] };
                    totals[kind] += e.t.componentCount(els[k].ty) orelse return e.unsupported("{s} of this type", .{els[k].semantic});
                }
                try e.cap(if (kind == 0) .clip_distance else .cull_distance);
                const arr = try e.t.array(try e.t.scalar(.float), totals[kind]);
                const sc: StorageClass = if (input) .input else .output;
                const v = e.b.newId();
                try e.b.emit(.types_globals, .variable, &.{ try e.pointerType(sc, try e.typeId(arr)), v, @backingInt(sc) });
                try e.b.emit(.annotations, .decorate, &.{ v, 11, if (kind == 0) 3 else 4 }); // BuiltIn ClipDistance / CullDistance
                try e.b.emitWithString(.debug_names, .name, &.{v}, if (kind == 0) "gl_ClipDistance" else "gl_CullDistance", &.{});
                try e.useVar(v);
                clip_vars[kind] = v;
            }
            for (els, out, 0..) |el, *iface, ek| {
                if (slots[ek]) |sl| {
                    iface.* = .{ .var_id = clip_vars[sl.kind], .ty = try e.t.array(try e.t.scalar(.float), totals[sl.kind]), .elem_array = true, .base = sl.base };
                    continue;
                }
                const bi = try e.builtinFor(el, input, entry.stage);
                // bool is not allowed in located interface variables.
                var ty = if (bi) |x| x.ty else if (e.t.component(el.ty) == .bool) try e.t.withComponent(el.ty, .uint) else el.ty;
                // Per-vertex values are arrays over the primitive / patch.
                const vty = ty;
                if (el.per_vertex) ty = try e.t.array(ty, switch (entry.stage) {
                    .geometry => entry.geometry.input_vertices,
                    .hull => if (input) entry.tess.input_control_points else entry.tess.output_control_points,
                    .mesh => if (patch) entry.mesh.max_primitives else entry.mesh.max_vertices,
                    else => entry.tess.input_control_points,
                });
                const sc: StorageClass = if (input) .input else .output;
                if (bi != null and input and !el.per_vertex) {
                    // One variable per input builtin, shared by its uses.
                    iface.* = .{ .var_id = try e.builtinInput(bi.?.id, ty), .ty = vty, .elem_array = e.t.get(ty) == .array };
                    if (bi.?.id == 11 or bi.?.id == 12) try e.b.emit(.annotations, .decorate, &.{ iface.var_id, 15 }); // Patch
                    continue;
                }
                const ptr = try e.pointerType(sc, try e.typeId(ty));
                const var_id = e.b.newId();
                try e.b.emit(.types_globals, .variable, &.{ ptr, var_id, @backingInt(sc) });
                if (patch) try e.b.emit(.annotations, .decorate, if (entry.stage == .mesh) &.{ var_id, 5271 } else &.{ var_id, 15 }); // PerPrimitiveEXT / Patch
                if (bi) |x| {
                    try e.b.emit(.annotations, .decorate, &.{ var_id, 11, x.id }); // BuiltIn
                    if (input and entry.stage == .pixel and !e.t.component(x.ty).?.isFloat() and e.t.component(x.ty).? != .bool) {
                        try e.b.emit(.annotations, .decorate, &.{ var_id, 14 }); // Flat
                    }
                } else {
                    const key = if (el.semantic_index > 0) try std.fmt.allocPrint(e.arena, "{s}{d}", .{ el.semantic, el.semantic_index }) else el.semantic;
                    const target: ?u32 = if (std.ascii.eqlIgnoreCase(el.semantic, "SV_Target")) el.semantic_index else null;
                    try located.append(e.arena, .{ .var_id = var_id, .key = key, .count = try e.locationCount(vty), .input = input, .target = target });
                    // Interpolation (as dxc: pixel inputs and vertex
                    // outputs; integers are always flat).
                    if ((input and entry.stage == .pixel) or (!input and entry.stage == .vertex)) {
                        var et = ty;
                        while (e.t.get(et) == .array) et = e.t.get(et).array.elem;
                        if (!e.t.component(et).?.isFloat() or e.t.component(et).? == .double) {
                            try e.b.emit(.annotations, .decorate, &.{ var_id, 14 }); // Flat
                        } else {
                            if (el.interp.centroid) try e.b.emit(.annotations, .decorate, &.{ var_id, 16 }); // Centroid
                            if (el.interp.nointerpolation) try e.b.emit(.annotations, .decorate, &.{ var_id, 14 }); // Flat
                            if (el.interp.noperspective) try e.b.emit(.annotations, .decorate, &.{ var_id, 13 }); // NoPerspective
                            if (el.interp.sample) {
                                try e.cap(.sample_rate_shading);
                                try e.b.emit(.annotations, .decorate, &.{ var_id, 17 }); // Sample
                            }
                        }
                    }
                }
                if (!input and entry.stage == .geometry and entry.geometry.streams[1] != null) {
                    try e.cap(.geometry_streams);
                    try e.b.emit(.annotations, .decorate, &.{ var_id, 29, el.stream }); // Stream
                }
                const name = try std.fmt.allocPrint(e.arena, "{s}.var.{s}{d}", .{ if (input) "in" else "out", el.semantic, el.semantic_index });
                try e.b.emitWithString(.debug_names, .name, &.{var_id}, name, &.{});
                iface.* = .{ .var_id = var_id, .ty = vty, .elem_array = bi != null and e.t.get(bi.?.ty) == .array };
                try e.useVar(var_id);
            }
        }
        // Locations in declaration order, except hull outputs and domain
        // inputs (control points and patch constants together), which
        // dxc orders by semantic so the two stages agree.
        for ([_]bool{ true, false }) |input| {
            var vars: std.ArrayList(Located) = .empty;
            for (located.items) |x| if (x.input == input) try vars.append(e.arena, x);
            if ((!input and entry.stage == .hull) or (input and entry.stage == .domain)) {
                std.sort.insertion(Located, vars.items, {}, struct {
                    fn lt(_: void, a: Located, b: Located) bool {
                        return std.mem.order(u8, a.key, b.key) == .lt;
                    }
                }.lt);
            }
            var next: u32 = 0;
            for (vars.items) |x| {
                const loc = x.target orelse next;
                try e.b.emit(.annotations, .decorate, &.{ x.var_id, 30, loc }); // Location
                next = @max(next, loc) + x.count;
            }
        }
    }

    /// Locations an interface variable occupies: one per array element and
    /// matrix row; 64-bit 3- and 4-vectors take two.
    fn locationCount(e: *Emitter, ty: TypeId) Error!u32 {
        return switch (e.t.get(ty)) {
            .array => |a| a.len * try e.locationCount(a.elem),
            .matrix => |m| m.rows * (if (m.elem.size() == 8 and m.cols > 2) @as(u32, 2) else 1),
            .vector => |v| if (v.elem.size() == 8 and v.len > 2) 2 else 1,
            else => 1,
        };
    }

    // ------------------------------------------------------------------
    // Functions

    fn hasResourceParams(e: *Emitter, f: *const ir.Function) bool {
        for (f.params) |p| if (isResourceType(e.t, p.ty)) return true;
        return false;
    }

    /// The copy of function `fi` with its resource parameters bound to
    /// `bindings` (resource variables; 0 for other parameters). Vulkan
    /// cannot pass buffer pointers to functions, so each distinct set of
    /// resource arguments gets its own copy (dxc gets there by inlining).
    /// What a resource argument binds a specialized callee's parameter
    /// to: a module variable, or (an element of a resource array) a
    /// recipe the callee re-creates: `recipe_tag | index` into `recipes`.
    fn resourceBinding(e: *Emitter, a: Ref) Error!Id {
        const f = e.f;
        var x = a;
        while (true) switch (f.inst(x).op) {
            .load => |p| x = p,
            // A resource local: what was stored into it.
            .local_var => x = for (f.insts.items) |inst| {
                if (inst.op == .store and inst.op.store.ptr == x) break inst.op.store.value;
            } else return e.val(x),
            else => break,
        };
        switch (f.inst(x).op) {
            .global => return e.val(x),
            .heap_resource => |h| {
                // A heap element at a constant index.
                if (f.inst(h.index).op != .constant) return e.unsupported("passing a resource from a descriptor heap at a dynamic index to a function is not supported yet", .{});
                const p = try e.resourcePointee(f.inst(x).ty);
                const hv = e.heap_vars.get(.{ h.sampler, p.ty }) orelse return e.unsupported("internal: heap variable missing", .{});
                return e.addRecipe(hv, try e.pointerType(p.sc, p.ty), try e.arena.dupe(Id, &.{e.val(h.index)}));
            },
            // A specialized parameter passes on what it is bound to.
            .param => |pi| return if (pi < e.cur_bindings.len and e.cur_bindings[pi] != 0) e.cur_bindings[pi] else e.val(x),
            .access => |acc| {
                var base = acc.base;
                while (f.inst(base).op == .load) base = f.inst(base).op.load;
                if (f.inst(base).op != .global) return e.unsupported("passing this resource to a function is not supported yet", .{});
                const idx = try e.arena.alloc(Id, acc.indices.len);
                for (idx, acc.indices) |*d, r| {
                    if (f.inst(r).op != .constant) return e.unsupported("passing a dynamically selected resource to a function is not supported yet", .{});
                    d.* = e.val(r);
                }
                const p = try e.resourcePointee(f.inst(x).ty);
                return e.addRecipe(e.val(base), try e.pointerType(p.sc, p.ty), idx);
            },
            else => return e.val(x),
        }
    }

    fn addRecipe(e: *Emitter, var_id: Id, ptr_ty: Id, idx: []const Id) Error!Id {
        for (e.recipes.items, 0..) |rc, k| {
            if (rc.var_id == var_id and rc.ptr_ty == ptr_ty and std.mem.eql(Id, rc.indices, idx)) return recipe_tag | @as(Id, @intCast(k));
        }
        try e.recipes.append(e.arena, .{ .var_id = var_id, .ptr_ty = ptr_ty, .indices = idx });
        return recipe_tag | @as(Id, @intCast(e.recipes.items.len - 1));
    }

    fn variantFor(e: *Emitter, fi: u32, bindings: []const Id) Error!Id {
        for (e.variants.items) |v| if (v.fi == fi and std.mem.eql(Id, v.bindings, bindings)) return v.id;
        const id = e.b.newId();
        try e.variants.append(e.arena, .{ .fi = fi, .bindings = try e.arena.dupe(Id, bindings), .id = id });
        try e.b.emitWithString(.debug_names, .name, &.{id}, e.m.functions.items[fi].name, &.{});
        return id;
    }

    fn emitFunction(e: *Emitter, f: *const ir.Function, fn_id: Id, bindings: []const Id) Error!void {
        e.f = f;
        e.cur_fn = fn_id;
        defer e.cur_fn = 0;
        e.cur_bindings = bindings;
        e.texel_places = .empty;
        e.mesh_places = .empty;
        e.vals = try e.arena.alloc(Id, f.insts.items.len);
        @memset(e.vals, 0);
        e.ptr_layouts = try e.arena.alloc(?PtrLayout, f.insts.items.len);
        @memset(e.ptr_layouts, null);
        const ret = try e.typeId(f.ret);
        var params: std.ArrayList(Id) = .empty;
        for (f.params, 0..) |p, k| {
            if (bindings.len > 0 and bindings[k] != 0) continue;
            if (e.mesh_params.contains(.{ f, @intCast(k) })) continue;
            if (isRayQuery(e.t, p.ty)) {
                try params.append(e.arena, try e.pointerType(.function, try e.rayQueryType()));
                continue;
            }
            const t = try e.typeId(p.ty);
            try params.append(e.arena, if (p.by_ref) try e.pointerType(.function, t) else t);
        }
        const fn_ty = try e.functionType(ret, params.items);
        try e.b.emit(.functions, .function, &.{ ret, fn_id, 0, fn_ty });
        const param_ids = try e.arena.alloc(Id, f.params.len);
        var next: usize = 0;
        for (f.params, param_ids, 0..) |p, *id, k| {
            if (bindings.len > 0 and bindings[k] != 0) {
                // Recipes are re-created at the start of the body.
                id.* = if (bindings[k] & recipe_tag != 0) e.b.newId() else bindings[k];
                continue;
            }
            if (e.mesh_params.contains(.{ f, @intCast(k) })) {
                id.* = 0;
                continue;
            }
            id.* = e.b.newId();
            try e.b.emit(.functions, .function_parameter, &.{ params.items[next], id.* });
            next += 1;
            try e.b.emitWithString(.debug_names, .name, &.{id.*}, p.name, &.{});
        }

        const order = try blockOrder(e.arena, f);
        const labels = try e.arena.alloc(Id, f.blocks.items.len);
        for (labels) |*l| l.* = e.b.newId();

        // Constants and parameters first (they may be used in any block).
        for (f.insts.items, 0..) |inst, i| switch (inst.op) {
            .constant => |c| e.vals[i] = try e.constant(inst.ty, c),
            .param => |p| {
                e.vals[i] = param_ids[p];
                if (e.mesh_params.get(.{ f, p })) |kind| try e.mesh_places.put(e.arena, @intCast(i), .{ .kind = kind, .ty = inst.ty });
            },
            else => {},
        };

        for (order, 0..) |bi, oi| {
            try e.b.emit(.functions, .label, &.{labels[bi]});
            if (oi == 0) {
                // OpVariables must open the first block.
                for (f.insts.items, 0..) |inst, i| if (inst.op == .local_var) {
                    if (isRayQuery(e.t, inst.ty)) {
                        try e.cap(.ray_query_khr);
                        try e.extension("SPV_KHR_ray_query");
                        e.vals[i] = e.b.newId();
                        try e.b.emit(.functions, .variable, &.{ try e.pointerType(.function, try e.rayQueryType()), e.vals[i], @backingInt(StorageClass.function) });
                        continue;
                    }
                    // Resource locals alias the one resource stored in them.
                    if (isResourceType(e.t, inst.ty)) continue;
                    const ptr = try e.pointerType(.function, try e.typeId(inst.ty));
                    e.vals[i] = e.b.newId();
                    try e.b.emit(.functions, .variable, &.{ ptr, e.vals[i], @backingInt(StorageClass.function) });
                };
                for (bindings, 0..) |bd, k| if (bd & recipe_tag != 0) {
                    const rc = e.recipes.items[bd & ~recipe_tag];
                    var ops: std.ArrayList(u32) = .empty;
                    try ops.appendSlice(e.arena, &.{ rc.ptr_ty, param_ids[k], rc.var_id });
                    try ops.appendSlice(e.arena, rc.indices);
                    try e.b.emit(.functions, .access_chain, ops.items);
                };
            }
            const blk = f.blocks.items[bi];
            for (blk.insts.items) |r| try e.emitInst(r);
            switch (blk.merge) {
                .none => {},
                .selection => |mb| try e.b.emit(.functions, .selection_merge, &.{ labels[mb.index()], 0 }),
                .loop => |l| try e.b.emit(.functions, .loop_merge, &.{ labels[l.merge.index()], labels[l.@"continue".index()], 0 }),
            }
            switch (blk.term) {
                .none, .@"unreachable" => try e.b.emit(.functions, .@"unreachable", &.{}),
                .ret => |v| if (v == .none) {
                    if (e.hullEpilogue(fn_id)) |pw| {
                        // After the control points: the patch constant
                        // function, once per patch.
                        const uint_ty = try e.t.scalar(.uint);
                        try e.b.emit(.functions, .control_barrier, &.{ try e.constUint(2), try e.constUint(4), try e.constUint(0) });
                        const id = try e.op1(.load, uint_ty, &.{try e.builtinInput(8, uint_ty)});
                        const first = try e.op1(.i_equal, try e.t.scalar(.bool), &.{ id, try e.constUint(0) });
                        const then_l = e.b.newId();
                        const merge_l = e.b.newId();
                        try e.b.emit(.functions, .selection_merge, &.{ merge_l, 0 });
                        try e.b.emit(.functions, .branch_conditional, &.{ first, then_l, merge_l });
                        try e.b.emit(.functions, .label, &.{then_l});
                        _ = try e.op1(.function_call, TypeTable.void_type, &.{pw});
                        try e.b.emit(.functions, .branch, &.{merge_l});
                        try e.b.emit(.functions, .label, &.{merge_l});
                    }
                    try e.b.emit(.functions, .@"return", &.{});
                } else try e.b.emit(.functions, .return_value, &.{e.vals[v.index()]}),
                .br => |t| try e.b.emit(.functions, .branch, &.{labels[t.index()]}),
                .cond_br => |c| try e.b.emit(.functions, .branch_conditional, &.{ e.vals[c.cond.index()], labels[c.then.index()], labels[c.@"else".index()] }),
                .@"switch" => |sw| {
                    var ops: std.ArrayList(u32) = .empty;
                    try ops.appendSlice(e.arena, &.{ e.vals[sw.value.index()], labels[sw.default.index()] });
                    for (sw.cases) |c| try ops.appendSlice(e.arena, &.{ @truncate(@as(u64, @bitCast(c.value))), labels[c.block.index()] });
                    try e.b.emit(.functions, .@"switch", ops.items);
                },
                .discard => try e.b.emit(.functions, .kill, &.{}),
            }
        }
        try e.b.emit(.functions, .function_end, &.{});
    }

    /// For the hull shader's entry wrapper: the patch constant wrapper it
    /// calls before returning.
    fn hullEpilogue(e: *Emitter, fn_id: Id) ?Id {
        const entry = e.entry;
        if (entry.stage != .hull or fn_id != e.func_ids[entry.wrapper]) return null;
        return e.func_ids[entry.patch_wrapper orelse return null];
    }

    /// Scalars, 1-vectors and 1x1 matrices (all a SPIR-V scalar).
    fn isScalarLike(e: *Emitter, ty: TypeId) bool {
        return switch (e.t.get(ty)) {
            .scalar, .@"enum" => true,
            .vector => |v| v.len == 1,
            .matrix => |m| m.rows == 1 and m.cols == 1,
            else => false,
        };
    }

    /// A matrix represented as a SPIR-V matrix (or array of vectors), not
    /// as a vector or scalar.
    fn isTrueMatrix(e: *Emitter, ty: TypeId) bool {
        return switch (e.t.get(ty)) {
            .matrix => |m| m.rows > 1 and m.cols > 1,
            else => false,
        };
    }

    fn row(e: *Emitter, m: Id, row_ty: TypeId, k: u32) Error!Id {
        return e.op1(.composite_extract, row_ty, &.{ m, k });
    }

    /// Scalar component (r, c) of a value viewed as a matrix: vectors are a
    /// row (`as_column` false) or a column.
    fn elementAt(e: *Emitter, v: Id, ty: TypeId, r: u32, c: u32) Error!Id {
        const sc = try e.t.scalar(e.t.component(ty).?);
        switch (e.t.get(ty)) {
            .scalar, .@"enum" => return v,
            .vector => |vec| {
                if (vec.len == 1) return v;
                return e.op1(.composite_extract, sc, &.{ v, r + c });
            },
            .matrix => |m| {
                if (m.rows == 1 and m.cols == 1) return v;
                if (m.rows == 1) return e.op1(.composite_extract, sc, &.{ v, c });
                if (m.cols == 1) return e.op1(.composite_extract, sc, &.{ v, r });
                return e.op1(.composite_extract, sc, &.{ v, r, c });
            },
            else => return e.unsupported("matrix element of this type", .{}),
        }
    }

    /// Builds a value of numeric type `ty` from row-major scalars.
    fn fromScalars(e: *Emitter, ty: TypeId, comps: []const Id) Error!Id {
        if (e.isScalarLike(ty)) return comps[0];
        if (!e.isTrueMatrix(ty)) return e.op1(.composite_construct, ty, comps);
        const m = e.t.get(ty).matrix;
        const rt = try e.t.vector(m.elem, m.cols);
        const rows = try e.arena.alloc(u32, m.rows);
        for (rows, 0..) |*rw, k| rw.* = try e.op1(.composite_construct, rt, comps[k * m.cols ..][0..m.cols]);
        return e.op1(.composite_construct, ty, rows);
    }

    /// HLSL mul(a, b): vectors on the left are rows, on the right columns.
    fn mul(e: *Emitter, ty: TypeId, at: TypeId, bt: TypeId, a: Id, b: Id) Error!Id {
        const t = e.t;
        const as = t.shape(at).?;
        const bs = t.shape(bt).?;
        const fl = e.compOf(ty).isFloat();
        if (as.count() == 1 or bs.count() == 1) {
            // Scalar times anything: component-wise.
            if (e.isTrueMatrix(ty) and fl) return e.op1(.matrix_times_scalar, ty, &.{ if (as.count() == 1) b else a, if (as.count() == 1) a else b });
            const n = t.componentCount(ty).?;
            const comps = try e.arena.alloc(Id, n);
            const s = if (as.count() == 1) try e.elementAt(a, at, 0, 0) else try e.elementAt(b, bt, 0, 0);
            const other = if (as.count() == 1) b else a;
            const ot = if (as.count() == 1) bt else at;
            const sc = try t.scalar(e.t.component(ty).?);
            for (comps, 0..) |*c, k| {
                const os = t.shape(ot).?;
                const x = try e.elementAt(other, ot, @intCast(k / os.cols), @intCast(k % os.cols));
                c.* = try e.binary(.mul, sc, x, s);
            }
            return e.fromScalars(ty, comps);
        }
        // Logical dimensions: a is (ar x k), b is (k x bc).
        const ar: u32 = if (as.kind == .vector) 1 else as.rows;
        const ak: u32 = if (as.kind == .vector) as.cols else as.cols;
        const bc: u32 = if (bs.kind == .vector) 1 else bs.cols;
        if (fl and e.isTrueMatrix(at) and bs.kind == .vector) return e.op1(.vector_times_matrix, ty, &.{ b, a });
        if (fl and as.kind == .vector and e.isTrueMatrix(bt)) return e.op1(.matrix_times_vector, ty, &.{ b, a });
        if (fl and e.isTrueMatrix(at) and e.isTrueMatrix(bt) and e.isTrueMatrix(ty)) return e.op1(.matrix_times_matrix, ty, &.{ b, a });
        if (fl and as.kind == .vector and bs.kind == .vector) return e.op1(.dot, ty, &.{ a, b });
        const sc = try t.scalar(e.t.component(ty).?);
        const comps = try e.arena.alloc(Id, ar * bc);
        for (0..ar) |i| for (0..bc) |j| {
            var acc: ?Id = null;
            for (0..ak) |kk| {
                const x = try e.elementAt(a, at, @intCast(i), @intCast(kk));
                const y = if (bs.kind == .vector) try e.elementAt(b, bt, 0, @intCast(kk)) else try e.elementAt(b, bt, @intCast(kk), @intCast(j));
                const p = try e.binary(.mul, sc, x, y);
                acc = if (acc) |s0| try e.binary(.add, sc, s0, p) else p;
            }
            comps[i * bc + j] = acc.?;
        };
        return e.fromScalars(ty, comps);
    }

    fn val(e: *Emitter, r: Ref) Id {
        return e.vals[r.index()];
    }

    fn compOf(e: *Emitter, ty: TypeId) Scalar {
        return storageScalar(e.t.component(ty) orelse .int);
    }

    fn emitInst(e: *Emitter, r: Ref) Error!void {
        const f = e.f;
        const i = f.inst(r);
        const ri = r.index();
        switch (i.op) {
            .constant, .param, .local_var => {},
            .ray_incoming => |k| e.vals[ri] = try e.rayVar(switch (k) {
                .payload => .incoming_ray_payload_khr,
                .attributes => .hit_attribute_khr,
                .callable => .incoming_callable_data_khr,
            }, i.ty),
            .global => |g| {
                e.vals[ri] = e.global_vars[g];
                if (e.m.globals.items[g].shader_record) {
                    try e.useVar(e.global_vars[g]);
                    e.ptr_layouts[ri] = .{ .rules = .std430, .row_major = false };
                    return;
                }
                e.ptr_layouts[ri] = switch (e.m.globals.items[g].space) {
                    .cbuffer => .{ .rules = if (e.m.globals.items[g].tbuffer) .std430 else .vk_relaxed, .row_major = false },
                    .resource => .{ .rules = .std430, .row_major = false },
                    else => null,
                };
            },
            .load => |p| {
                if (e.texel_places.get(p.index())) |tp| {
                    if (tp.comp == .none) {
                        e.vals[ri] = try e.imageIndexLoad(tp.res, e.val(tp.coord), i.ty);
                    } else {
                        const elem = e.resourceInfo(tp.res).elem;
                        const whole = try e.imageIndexLoad(tp.res, e.val(tp.coord), elem);
                        e.vals[ri] = if (e.isScalarLike(elem)) whole else try e.op1(.vector_extract_dynamic, i.ty, &.{ whole, e.val(tp.comp) });
                    }
                    return;
                }
                // Resources stay as their variables (accessed by chains).
                if (i.ptr == .none and (e.t.get(i.ty) == .resource or e.t.get(i.ty) == .sampler)) {
                    e.vals[ri] = e.val(p);
                    return;
                }
                if (e.ptr_layouts[p.index()]) |pl| {
                    const raw = try e.opRaw(.load, try e.layoutTypeId(i.ty, pl.rules, pl.row_major), &.{e.val(p)});
                    e.vals[ri] = try e.fromLayout(raw, i.ty, pl.rules, pl.row_major);
                    return;
                }
                e.vals[ri] = try e.op1(.load, i.ty, &.{e.val(p)});
            },
            .store => |s| {
                if (e.mesh_places.get(s.ptr.index())) |mp| return e.meshStore(mp, e.val(s.value), f.inst(s.value).ty);
                if (e.texel_places.get(s.ptr.index())) |tp| {
                    if (tp.comp != .none) return e.unsupported("storing one component of a texel is not supported yet", .{});
                    return e.imageWrite(tp.res, e.val(tp.coord), e.val(s.value));
                }
                const target = f.inst(s.ptr);
                if (target.op == .local_var and isRayQuery(e.t, target.ty)) {
                    // A copy of a RayQuery is the same query object.
                    e.vals[s.ptr.index()] = e.val(s.value);
                    return;
                }
                if (target.op == .local_var and isResourceType(e.t, target.ty)) {
                    const old = e.vals[s.ptr.index()];
                    if (old != 0 and old != e.val(s.value)) return e.unsupported("assigning different resources to one variable is not supported yet", .{});
                    e.vals[s.ptr.index()] = e.val(s.value);
                    return;
                }
                if (e.ptr_layouts[s.ptr.index()]) |pl| {
                    const v = try e.toLayout(e.val(s.value), f.inst(s.value).ty, pl.rules, pl.row_major);
                    try e.b.emit(.functions, .store, &.{ e.val(s.ptr), v });
                    return;
                }
                try e.b.emit(.functions, .store, &.{ e.val(s.ptr), e.val(s.value) });
            },
            .access => |a| {
                if (e.t.get(f.inst(a.base).ty) == .array and isResourceType(e.t, f.inst(a.base).ty)) return e.resourceArrayAccess(ri, a, i.ty);
                if (e.texel_places.get(a.base.index())) |tp| {
                    // A component of a texel.
                    if (tp.comp != .none or a.indices.len != 1) return e.unsupported("this texel access is not supported yet", .{});
                    try e.texel_places.put(e.arena, ri, .{ .res = tp.res, .coord = tp.coord, .comp = a.indices[0] });
                    return;
                }
                if (e.isImage(a.base)) {
                    // A texel: read and written as image accesses, or the
                    // pointer of an atomic (made on use).
                    try e.texel_places.put(e.arena, ri, .{ .res = a.base, .coord = a.indices[0] });
                    return;
                }
                // Buffers reached through locals or parameters are still
                // Uniform std430 storage.
                const into_buffer = e.t.get(f.inst(a.base).ty) == .resource;
                const into_cb = into_buffer and e.t.get(f.inst(a.base).ty).resource.kind == .constant_buffer;
                const into_tb = into_buffer and e.t.get(f.inst(a.base).ty).resource.kind == .texture_buffer;
                const base_pl = e.ptr_layouts[a.base.index()];
                if (i.ptr == .mesh) {
                    // Mesh outputs: a place, written component by component.
                    var mp: MeshPlace = e.mesh_places.get(a.base.index()) orelse .{ .kind = f.inst(a.base).op.mesh_output, .ty = f.inst(a.base).ty };
                    for (a.indices) |x| {
                        if (mp.index == .none) {
                            mp.index = x;
                            mp.ty = e.t.get(mp.ty).array.elem;
                            continue;
                        }
                        const k: u32 = switch (f.inst(x).op) {
                            .constant => |c| @intCast(c.int),
                            else => return e.unsupported("dynamic indexing inside a mesh output is not supported yet", .{}),
                        };
                        switch (e.t.get(mp.ty)) {
                            .@"struct" => |st| {
                                for (st.fields.items[0..k]) |fld| mp.offset += e.t.componentCount(fld.type).?;
                                mp.ty = st.fields.items[k].type;
                            },
                            .array => |arr| {
                                mp.offset += k * e.t.componentCount(arr.elem).?;
                                mp.ty = arr.elem;
                            },
                            .vector => |v| {
                                mp.offset += k;
                                mp.ty = try e.t.scalar(v.elem);
                            },
                            else => return e.unsupported("indexing this mesh output is not supported yet", .{}),
                        }
                    }
                    try e.mesh_places.put(e.arena, ri, mp);
                    return;
                }
                const shader_record = e.inShaderRecord(a.base);
                const sc: StorageClass = if (shader_record) .shader_record_buffer_khr else if (into_cb) .uniform else if (into_buffer or (base_pl != null and base_pl.?.rules == .std430)) e.bufferSc() else if (base_pl != null) .uniform else switch (i.ptr) {
                    .function => .function,
                    .private => .private,
                    .groupshared => if (e.payload_global != null and e.rootGlobal(a.base) == e.payload_global) .task_payload_workgroup else .workgroup,
                    .cbuffer, .resource => .uniform,
                    else => return e.unsupported("access into this storage is not supported yet", .{}),
                };
                var pl = if (shader_record) PtrLayout{ .rules = .std430, .row_major = false } else if (into_cb) PtrLayout{ .rules = .vk_relaxed, .row_major = false } else if (into_tb) PtrLayout{ .rules = .std430, .row_major = false } else if (into_buffer) PtrLayout{ .rules = .std430, .row_major = false } else e.ptr_layouts[a.base.index()];
                var ops: std.ArrayList(u32) = .empty;
                try ops.appendSlice(e.arena, &.{ 0, 0, e.val(a.base) });
                var cur = f.inst(a.base).ty;
                var indices = a.indices;
                if (into_cb or into_tb) {
                    cur = e.t.get(cur).resource.elem;
                } else if (e.t.get(cur) == .resource) {
                    // buffer[i]...: member 0 (the runtime array), element i.
                    const rk = e.t.get(cur).resource;
                    if (try e.bufferElemType(cur) == null) return e.unsupported("indexing this resource is not supported yet", .{});
                    try ops.appendSlice(e.arena, &.{ try e.constInt(0), e.val(indices[0]) });
                    cur = if (rk.kind == .byte_address_buffer or rk.kind == .rw_byte_address_buffer) try e.t.scalar(.uint) else rk.elem;
                    indices = indices[1..];
                }
                // Indices into 1-vectors (SPIR-V scalars) are dropped.
                for (indices) |x| {
                    // Row 0 of a 1xN matrix (a SPIR-V vector) is the whole value.
                    const skip = e.isScalarLike(cur) or (e.t.get(cur) == .matrix and e.t.get(cur).matrix.rows == 1);
                    cur = switch (e.t.get(cur)) {
                        .array => |arr| arr.elem,
                        .vector => |v| try e.t.scalar(v.elem),
                        .matrix => |mt| try e.t.vector(mt.elem, mt.cols),
                        .@"struct" => |st| blk: {
                            const k = f.inst(x);
                            if (k.op != .constant) break :blk cur;
                            const fld = st.fields.items[@intCast(k.op.constant.int)];
                            if (pl) |*p| p.row_major = fld.row_major;
                            break :blk fld.type;
                        },
                        else => cur,
                    };
                    if (!skip) try ops.append(e.arena, e.val(x));
                }
                e.ptr_layouts[ri] = pl;
                ops.items[0] = try e.pointerType(sc, if (pl) |p| try e.layoutTypeId(i.ty, p.rules, p.row_major) else try e.typeId(i.ty));
                if (ops.items.len == 3) {
                    e.vals[ri] = e.val(a.base);
                    return;
                }
                e.vals[ri] = e.b.newId();
                ops.items[1] = e.vals[ri];
                try e.b.emit(.functions, .access_chain, ops.items);
                // Elements of a non-uniformly selected buffer.
                if (e.nonuniform_ids.contains(e.val(a.base))) try e.markNonUniform(e.vals[ri], f.inst(a.base).ty);
            },
            .binary => |x| {
                if (e.isTrueMatrix(i.ty)) {
                    const m = e.t.get(i.ty).matrix;
                    const rt = try e.t.vector(m.elem, m.cols);
                    const rows = try e.arena.alloc(u32, m.rows);
                    for (rows, 0..) |*rw, k| rw.* = try e.binary(x.op, rt, try e.row(e.val(x.lhs), rt, @intCast(k)), try e.row(e.val(x.rhs), rt, @intCast(k)));
                    e.vals[ri] = try e.op1(.composite_construct, i.ty, rows);
                    return;
                }
                e.vals[ri] = try e.binary(x.op, i.ty, e.val(x.lhs), e.val(x.rhs));
            },
            .unary => |x| {
                if (e.isTrueMatrix(i.ty)) {
                    const m = e.t.get(i.ty).matrix;
                    const rt = try e.t.vector(m.elem, m.cols);
                    const neg = try e.t.withComponent(rt, m.elem);
                    const rows = try e.arena.alloc(u32, m.rows);
                    const c = e.compOf(i.ty);
                    const op: Op = switch (x.op) {
                        .neg => if (c.isFloat()) .f_negate else .s_negate,
                        .not => .logical_not,
                        .bit_not => .not_,
                    };
                    for (rows, 0..) |*rw, k| rw.* = try e.op1(op, neg, &.{try e.row(e.val(x.operand), rt, @intCast(k))});
                    e.vals[ri] = try e.op1(.composite_construct, i.ty, rows);
                    return;
                }
                const c = e.compOf(i.ty);
                const op: Op = switch (x.op) {
                    .neg => if (c.isFloat()) .f_negate else .s_negate,
                    .not => .logical_not,
                    .bit_not => .not_,
                };
                e.vals[ri] = try e.op1(op, i.ty, &.{e.val(x.operand)});
            },
            .cmp => |x| {
                const c = e.compOf(f.inst(x.lhs).ty);
                const op: Op = if (c.isFloat()) switch (x.op) {
                    .eq => .f_ord_equal,
                    .ne => .f_unord_not_equal,
                    .lt => .f_ord_less_than,
                    .le => .f_ord_less_than_equal,
                    .gt => .f_ord_greater_than,
                    .ge => .f_ord_greater_than_equal,
                } else if (c == .bool) switch (x.op) {
                    .eq => .logical_equal,
                    .ne => .logical_not_equal,
                    else => return e.unsupported("ordered comparison of bools", .{}),
                } else if (c.isUnsigned()) switch (x.op) {
                    .eq => .i_equal,
                    .ne => .i_not_equal,
                    .lt => .u_less_than,
                    .le => .u_less_than_equal,
                    .gt => .u_greater_than,
                    .ge => .u_greater_than_equal,
                } else switch (x.op) {
                    .eq => .i_equal,
                    .ne => .i_not_equal,
                    .lt => .s_less_than,
                    .le => .s_less_than_equal,
                    .gt => .s_greater_than,
                    .ge => .s_greater_than_equal,
                };
                const lt = f.inst(x.lhs).ty;
                if (e.isTrueMatrix(lt)) {
                    const m = e.t.get(lt).matrix;
                    const rt = try e.t.vector(m.elem, m.cols);
                    const bt = try e.t.vector(.bool, m.cols);
                    const rows = try e.arena.alloc(u32, m.rows);
                    for (rows, 0..) |*rw, k| rw.* = try e.op1(op, bt, &.{ try e.row(e.val(x.lhs), rt, @intCast(k)), try e.row(e.val(x.rhs), rt, @intCast(k)) });
                    e.vals[ri] = try e.op1(.composite_construct, i.ty, rows);
                    return;
                }
                e.vals[ri] = try e.op1(op, i.ty, &.{ e.val(x.lhs), e.val(x.rhs) });
            },
            .convert => |x| e.vals[ri] = try e.convert(e.val(x), f.inst(x).ty, i.ty),
            .bitcast => |x| e.vals[ri] = try e.op1(.bitcast, i.ty, &.{e.val(x)}),
            .splat => |x| {
                const n = e.t.componentCount(i.ty).?;
                if (e.isTrueMatrix(i.ty)) {
                    const m = e.t.get(i.ty).matrix;
                    const parts = try e.arena.alloc(u32, m.cols);
                    @memset(parts, e.val(x));
                    const one_row = try e.op1(.composite_construct, try e.t.vector(m.elem, m.cols), parts);
                    const rows = try e.arena.alloc(u32, m.rows);
                    @memset(rows, one_row);
                    e.vals[ri] = try e.op1(.composite_construct, i.ty, rows);
                    return;
                }
                if (n == 1) {
                    e.vals[ri] = e.val(x);
                    return;
                }
                const comps = try e.arena.alloc(u32, n);
                @memset(comps, e.val(x));
                e.vals[ri] = try e.op1(.composite_construct, i.ty, comps);
            },
            .extract => |x| {
                const at = f.inst(x.agg).ty;
                // Row 0 of a 1xN matrix is the whole (vector) value.
                if (e.isScalarLike(at) or (e.t.get(at) == .matrix and e.t.get(at).matrix.rows == 1)) {
                    e.vals[ri] = e.val(x.agg);
                    return;
                }
                e.vals[ri] = try e.op1(.composite_extract, i.ty, &.{ e.val(x.agg), x.index });
            },
            .insert => |x| {
                if (e.isScalarLike(i.ty) or (e.t.get(i.ty) == .matrix and e.t.get(i.ty).matrix.rows == 1)) {
                    e.vals[ri] = e.val(x.value);
                    return;
                }
                e.vals[ri] = try e.op1(.composite_insert, i.ty, &.{ e.val(x.value), e.val(x.agg), x.index });
            },
            .construct => |xs| {
                if (xs.len == 1 and e.isScalarLike(i.ty)) {
                    e.vals[ri] = e.val(xs[0]);
                    return;
                }
                if (e.isTrueMatrix(i.ty) and xs.len != e.t.get(i.ty).matrix.rows) {
                    // From scalars: group them into rows.
                    const m = e.t.get(i.ty).matrix;
                    const rt = try e.t.vector(m.elem, m.cols);
                    const rows = try e.arena.alloc(u32, m.rows);
                    for (rows, 0..) |*rw, k| {
                        const parts = try e.arena.alloc(u32, m.cols);
                        for (parts, 0..) |*p, c| p.* = e.val(xs[k * m.cols + c]);
                        rw.* = try e.op1(.composite_construct, rt, parts);
                    }
                    e.vals[ri] = try e.op1(.composite_construct, i.ty, rows);
                    return;
                }
                const ids = try e.arena.alloc(u32, xs.len);
                for (xs, ids) |x, *id| id.* = e.val(x);
                e.vals[ri] = try e.op1(.composite_construct, i.ty, ids);
            },
            .shuffle => |x| {
                const v = e.val(x.vec);
                if (e.isScalarLike(f.inst(x.vec).ty)) {
                    if (x.components.len == 1) {
                        e.vals[ri] = v;
                    } else {
                        const comps = try e.arena.alloc(u32, x.components.len);
                        @memset(comps, v);
                        e.vals[ri] = try e.op1(.composite_construct, i.ty, comps);
                    }
                    return;
                }
                if (x.components.len == 1) {
                    e.vals[ri] = try e.op1(.composite_extract, i.ty, &.{ v, x.components[0] });
                    return;
                }
                var ops: std.ArrayList(u32) = .empty;
                try ops.appendSlice(e.arena, &.{ v, v });
                for (x.components) |c| try ops.append(e.arena, c);
                e.vals[ri] = try e.op1(.vector_shuffle, i.ty, ops.items);
            },
            .select => |x| {
                if (e.isTrueMatrix(i.ty)) {
                    const m = e.t.get(i.ty).matrix;
                    const rt = try e.t.vector(m.elem, m.cols);
                    const ct = f.inst(x.cond).ty;
                    const rows = try e.arena.alloc(u32, m.rows);
                    for (rows, 0..) |*rw, k| {
                        const c = if (e.isTrueMatrix(ct)) try e.row(e.val(x.cond), try e.t.vector(.bool, m.cols), @intCast(k)) else e.val(x.cond);
                        rw.* = try e.op1(.select, rt, &.{ c, try e.row(e.val(x.t), rt, @intCast(k)), try e.row(e.val(x.f), rt, @intCast(k)) });
                    }
                    e.vals[ri] = try e.op1(.composite_construct, i.ty, rows);
                    return;
                }
                e.vals[ri] = try e.op1(.select, i.ty, &.{ e.val(x.cond), e.val(x.t), e.val(x.f) });
            },
            .call => |c| {
                var ops: std.ArrayList(u32) = .empty;
                const callee = e.m.functions.items[c.func];
                if (e.hasResourceParams(callee)) {
                    const bindings = try e.arena.alloc(Id, c.args.len);
                    for (callee.params, c.args, bindings) |p, a, *bd| bd.* = if (isResourceType(e.t, p.ty)) try e.resourceBinding(a) else 0;
                    const vid = try e.variantFor(c.func, bindings);
                    try e.recordCall(vid);
                    try ops.append(e.arena, vid);
                    for (callee.params, c.args) |p, a| if (!isResourceType(e.t, p.ty)) try ops.append(e.arena, e.val(a));
                    e.vals[ri] = try e.op1(.function_call, i.ty, ops.items);
                    return;
                }
                try e.recordCall(e.func_ids[c.func]);
                try ops.append(e.arena, e.func_ids[c.func]);
                for (c.args, 0..) |a, k| {
                    if (e.mesh_params.contains(.{ callee, @intCast(k) })) continue;
                    try ops.append(e.arena, e.val(a));
                }
                e.vals[ri] = try e.op1(.function_call, i.ty, ops.items);
            },
            .intrinsic => |c| {
                if (std.mem.eql(u8, c.name, "SetMeshOutputCounts")) {
                    try e.b.emit(.functions, .set_mesh_outputs_ext, &.{ e.val(c.args[0]), e.val(c.args[1]) });
                    return;
                }
                if (std.mem.eql(u8, c.name, "DispatchMesh")) {
                    if (e.rootGlobal(c.args[3]) == null or f.inst(c.args[3]).op != .global) return e.unsupported("DispatchMesh with this payload is not supported yet", .{});
                    try e.b.emit(.functions, .emit_mesh_tasks_ext, &.{ e.val(c.args[0]), e.val(c.args[1]), e.val(c.args[2]), e.val(c.args[3]) });
                    // A terminator: what follows is unreachable.
                    try e.b.emit(.functions, .label, &.{e.b.newId()});
                    return;
                }
                if (try e.rayIntrinsic(c.name, i.ty, c.args)) |id| {
                    e.vals[ri] = id;
                    return;
                }
                e.vals[ri] = try e.intrinsic(c.name, i.ty, c.args);
            },
            .res_load => |x| {
                if (e.isImage(x.res)) {
                    e.vals[ri] = try e.imageIndexLoad(x.res, e.val(x.index), i.ty);
                    return;
                }
                const ptr = try e.bufferElement(x.res, x.index);
                const raw = try e.opRaw(.load, try e.layoutTypeId(i.ty, .std430, false), &.{ptr});
                e.vals[ri] = try e.fromLayout(raw, i.ty, .std430, false);
            },
            .res_store => |x| {
                if (e.isImage(x.res)) {
                    try e.imageWrite(x.res, e.val(x.index), e.val(x.value));
                    return;
                }
                const ptr = try e.bufferElement(x.res, x.index);
                const v = try e.toLayout(e.val(x.value), f.inst(x.value).ty, .std430, false);
                try e.b.emit(.functions, .store, &.{ ptr, v });
            },
            .method => |x| e.vals[ri] = try e.method(x.name, x.res, x.args, i.ty),
            .input => |k| e.vals[ri] = try e.loadInterface(e.st.inputs[k], .input, i.ty),
            .input_vertex => |x| {
                const iface = e.st.inputs[x.element];
                const ptr = try e.opRaw(.access_chain, try e.pointerType(.input, try e.typeId(iface.ty)), &.{ iface.var_id, try e.constUint(x.vertex) });
                e.vals[ri] = try e.reshape(try e.op1(.load, iface.ty, &.{ptr}), iface.ty, i.ty);
            },
            .patch_input => |k| e.vals[ri] = try e.loadInterface(e.st.patches[k], .input, i.ty),
            .mesh_output => try e.mesh_places.put(e.arena, ri, .{ .kind = i.op.mesh_output, .ty = i.ty }),
            .heap_resource => |h| {
                if (e.t.get(i.ty) != .resource and e.t.get(i.ty) != .sampler) return;
                const p = try e.resourcePointee(i.ty);
                const key = .{ h.sampler, p.ty };
                const hv = e.heap_vars.get(key) orelse blk: {
                    try e.cap(.runtime_descriptor_array);
                    try e.extension("SPV_EXT_descriptor_indexing");
                    const arr = e.b.newId();
                    try e.b.emit(.types_globals, .type_runtime_array, &.{ arr, p.ty });
                    const v = e.b.newId();
                    try e.b.emit(.types_globals, .variable, &.{ try e.pointerType(p.sc, arr), v, @backingInt(p.sc) });
                    try e.b.emit(.annotations, .decorate, &.{ v, 34, 0 }); // DescriptorSet
                    try e.b.emit(.annotations, .decorate, &.{ v, 33, e.heap_bindings[@intFromBool(h.sampler)] }); // Binding
                    try e.b.emitWithString(.debug_names, .name, &.{v}, if (h.sampler) "SamplerDescriptorHeap" else "ResourceDescriptorHeap", &.{});
                    if (e.spv_minor >= 4) try e.useVar(v);
                    try e.heap_vars.put(e.arena, key, v);
                    break :blk v;
                };
                const id = try e.opRaw(.access_chain, try e.pointerType(p.sc, p.ty), &.{ hv, e.val(h.index) });
                e.vals[ri] = id;
                if (e.nonuniform_ids.contains(e.val(h.index))) try e.markNonUniform(id, i.ty);
            },
            .mesh_payload => {
                if (e.st.payload_var == 0) {
                    e.st.payload_var = e.b.newId();
                    try e.b.emit(.types_globals, .variable, &.{ try e.pointerType(.task_payload_workgroup, try e.typeId(i.ty)), e.st.payload_var, @backingInt(StorageClass.task_payload_workgroup) });
                    try e.b.emitWithString(.debug_names, .name, &.{e.st.payload_var}, "in.var.payload", &.{});
                    try e.useVar(e.st.payload_var);
                }
                e.vals[ri] = try e.op1(.load, i.ty, &.{e.st.payload_var});
            },
            .patch_output => |o| try e.storeInterface(e.st.patches[o.element], f.inst(o.value).ty, e.val(o.value)),
            .output_vertex => |x| {
                const iface = e.st.outputs[x.element];
                const ptr = try e.opRaw(.access_chain, try e.pointerType(.output, try e.typeId(iface.ty)), &.{ iface.var_id, try e.constUint(x.vertex) });
                e.vals[ri] = try e.reshape(try e.op1(.load, iface.ty, &.{ptr}), iface.ty, i.ty);
            },
            .emit, .cut => |stream| {
                const multi = e.entry.geometry.streams[1] != null;
                if (multi) {
                    try e.b.emit(.functions, if (i.op == .emit) .emit_stream_vertex else .end_stream_primitive, &.{try e.constUint(stream)});
                } else try e.b.emit(.functions, if (i.op == .emit) .emit_vertex else .end_primitive, &.{});
            },
            .output => |o| {
                const iface = e.st.outputs[o.element];
                if (iface.elem_array) return e.storeInterface(iface, f.inst(o.value).ty, e.val(o.value));
                const v = try e.reshape(e.val(o.value), f.inst(o.value).ty, iface.ty);
                if (e.entry.outputs.items[o.element].per_vertex) {
                    // Hull output control points: this invocation's element.
                    const id = try e.op1(.load, try e.t.scalar(.uint), &.{try e.builtinInput(8, try e.t.scalar(.uint))});
                    const ptr = try e.opRaw(.access_chain, try e.pointerType(.output, try e.typeId(iface.ty)), &.{ iface.var_id, id });
                    try e.b.emit(.functions, .store, &.{ ptr, v });
                } else try e.b.emit(.functions, .store, &.{ iface.var_id, v });
            },
            .phi => return e.unsupported("phi", .{}),
        }
    }

    /// Parameters that receive mesh output arrays, through any depth of
    /// calls from the entry.
    fn findMeshParams(e: *Emitter) Error!void {
        var changed = true;
        while (changed) {
            changed = false;
            for (e.m.functions.items) |f| for (f.insts.items) |inst| switch (inst.op) {
                .call => |c| for (c.args, 0..) |a, k| {
                    const kind: ?ir.MeshOutput = switch (f.inst(a).op) {
                        .mesh_output => |mk| mk,
                        .param => |p| e.mesh_params.get(.{ f, p }),
                        else => null,
                    };
                    const callee = e.m.functions.items[c.func];
                    if (kind) |mk| if (!e.mesh_params.contains(.{ callee, @intCast(k) })) {
                        try e.mesh_params.put(e.arena, .{ callee, @intCast(k) }, mk);
                        changed = true;
                    };
                },
                else => {},
            };
        }
    }

    /// The global a pointer derives from, if any.
    fn rootGlobal(e: *Emitter, r: Ref) ?u32 {
        var x = r;
        while (true) switch (e.f.inst(x).op) {
            .global => |g| return g,
            .access => |a| x = a.base,
            else => return null,
        };
    }

    /// The groupshared variable an amplification shader passes to
    /// DispatchMesh (its storage becomes the task payload).
    fn dispatchPayloadGlobal(e: *Emitter) ?u32 {
        for (e.m.functions.items) |f| for (f.insts.items) |inst| switch (inst.op) {
            .intrinsic => |it| if (std.mem.eql(u8, it.name, "DispatchMesh") and it.args.len == 4) {
                var x = it.args[3];
                while (true) switch (f.inst(x).op) {
                    .global => |g| return g,
                    .access => |a| x = a.base,
                    else => break,
                };
            },
            else => {},
        };
        return null;
    }

    /// Flattened component `k` of value `v` of type `ty`.
    fn flatComponent(e: *Emitter, v: Id, ty: TypeId, k: u32) Error!struct { Id, TypeId } {
        switch (e.t.get(ty)) {
            .scalar, .@"enum" => return .{ v, ty },
            .vector => |vec| {
                const st = try e.t.scalar(vec.elem);
                return .{ if (vec.len == 1) v else try e.op1(.composite_extract, st, &.{ v, k }), st };
            },
            .matrix => |m| return .{ try e.elementAt(v, ty, k / m.cols, k % m.cols), try e.t.scalar(m.elem) },
            .array => |a| {
                const n = e.t.componentCount(a.elem).?;
                return e.flatComponent(try e.op1(.composite_extract, a.elem, &.{ v, k / n }), a.elem, k % n);
            },
            .@"struct" => |st| {
                var kk = k;
                for (st.fields.items, 0..) |fld, fi| {
                    const n = e.t.componentCount(fld.type).?;
                    if (kk < n) return e.flatComponent(try e.op1(.composite_extract, fld.type, &.{ v, @intCast(fi) }), fld.type, kk);
                    kk -= n;
                }
                return e.unsupported("internal: component out of range", .{});
            },
            else => return e.unsupported("values of type '{s}' are not supported here yet", .{try e.t.format(e.arena, ty)}),
        }
    }

    /// Writes a vertex / primitive output (component by component, into
    /// each attribute's array) or a primitive's indices.
    fn meshStore(e: *Emitter, mp: MeshPlace, v: Id, ty: TypeId) Error!void {
        if (mp.index == .none) return e.unsupported("storing a whole mesh output array is not supported yet", .{});
        const entry = e.entry;
        const index = e.val(mp.index);
        if (mp.kind == .indices) {
            const lines = entry.mesh.topology == .line;
            const vty = try e.t.vector(.uint, if (lines) 2 else 3);
            if (e.st.indices_var == 0) {
                e.st.indices_var = e.b.newId();
                try e.b.emit(.types_globals, .variable, &.{ try e.pointerType(.output, try e.typeId(try e.t.array(vty, entry.mesh.max_primitives))), e.st.indices_var, @backingInt(StorageClass.output) });
                try e.b.emit(.annotations, .decorate, &.{ e.st.indices_var, 11, if (lines) 5295 else 5296 }); // BuiltIn Primitive{Line,Triangle}IndicesEXT
                try e.useVar(e.st.indices_var);
            }
            if (mp.offset == 0 and e.t.componentCount(ty) == e.t.componentCount(vty)) {
                const ptr = try e.opRaw(.access_chain, try e.pointerType(.output, try e.typeId(vty)), &.{ e.st.indices_var, index });
                try e.b.emit(.functions, .store, &.{ ptr, try e.reshape(v, ty, vty) });
                return;
            }
            const ut = try e.t.scalar(.uint);
            for (0..e.t.componentCount(ty).?) |c| {
                const comp = try e.flatComponent(v, ty, @intCast(c));
                const ptr = try e.opRaw(.access_chain, try e.pointerType(.output, try e.typeId(ut)), &.{ e.st.indices_var, index, try e.constUint(mp.offset + @as(u32, @intCast(c))) });
                try e.b.emit(.functions, .store, &.{ ptr, try e.reshape(comp[0], comp[1], ut) });
            }
            return;
        }
        const n = e.t.componentCount(ty) orelse return e.unsupported("mesh outputs of type '{s}' are not supported yet", .{try e.t.format(e.arena, ty)});
        const els = if (mp.kind == .vertices) entry.outputs.items else entry.patch_constants.items;
        const ifaces = if (mp.kind == .vertices) e.st.outputs else e.st.patches;
        for (0..n) |c| {
            const comp = try e.flatComponent(v, ty, @intCast(c));
            var flat = mp.offset + @as(u32, @intCast(c));
            var k: usize = 0;
            while (k < els.len) : (k += 1) {
                const cnt = e.t.componentCount(els[k].ty).?;
                if (flat < cnt) break;
                flat -= cnt;
            }
            if (k == els.len) return e.unsupported("internal: mesh output component out of range", .{});
            const iface = ifaces[k];
            // Indices into the attribute: [vertex] then within it.
            var chain: std.ArrayList(u32) = .empty;
            try chain.appendSlice(e.arena, &.{ 0, 0, iface.var_id, index });
            var leaf = iface.ty;
            switch (e.t.get(leaf)) {
                .scalar, .@"enum" => {},
                .vector => |vec| {
                    if (vec.len > 1) try chain.append(e.arena, try e.constUint(flat));
                    leaf = try e.t.scalar(vec.elem);
                },
                .array => |a| {
                    const per = e.t.componentCount(a.elem).?;
                    try chain.append(e.arena, try e.constUint(flat / per));
                    if (e.t.get(a.elem) == .vector and per > 1) try chain.append(e.arena, try e.constUint(flat % per));
                    leaf = try e.t.scalar(e.t.component(a.elem).?);
                },
                else => return e.unsupported("mesh outputs of type '{s}' are not supported yet", .{try e.t.format(e.arena, leaf)}),
            }
            const ptr = e.b.newId();
            chain.items[0] = try e.pointerType(.output, try e.typeId(leaf));
            chain.items[1] = ptr;
            try e.b.emit(.functions, .access_chain, chain.items);
            try e.b.emit(.functions, .store, &.{ ptr, try e.reshape(comp[0], comp[1], leaf) });
        }
    }

    /// Derivatives outside pixel shaders: compute-like stages, over quads
    /// of the thread group (or linearly, as dxc).
    fn checkDerivatives(e: *Emitter) Error!void {
        const entry = e.entry;
        switch (entry.stage) {
            .pixel => return,
            .compute, .mesh, .amplification => {},
            else => return e.unsupported("derivatives are not available in {s} shaders", .{@tagName(entry.stage)}),
        }
        if (e.st.derivative_mode != 0) return;
        try e.extension("SPV_KHR_compute_shader_derivatives");
        const t = entry.num_threads;
        if (t[0] % 2 == 0 and t[1] % 2 == 0) {
            try e.cap(.compute_derivative_group_quads);
            e.st.derivative_mode = 5289; // DerivativeGroupQuadsKHR
        } else {
            try e.cap(.compute_derivative_group_linear);
            e.st.derivative_mode = 5290; // DerivativeGroupLinearKHR
        }
    }

    /// Reads an interface variable as a value of type `ty`.
    fn loadInterface(e: *Emitter, iface: Interface, sc: StorageClass, ty: TypeId) Error!Id {
        if (!iface.elem_array) return e.reshape(try e.op1(.load, iface.ty, &.{iface.var_id}), iface.ty, ty);
        const et = try e.t.scalar(e.t.component(e.t.get(iface.ty).array.elem).?);
        const n = e.t.componentCount(ty).?;
        const parts = try e.arena.alloc(Id, n);
        for (parts, 0..) |*p, k| {
            const ptr = try e.opRaw(.access_chain, try e.pointerType(sc, try e.typeId(et)), &.{ iface.var_id, try e.constUint(iface.base + @as(u32, @intCast(k))) });
            p.* = try e.convert(try e.op1(.load, et, &.{ptr}), et, (try e.rawLeafScalar(ty, @intCast(k))));
        }
        return e.composeFlat(ty, parts);
    }

    /// The scalar type of flattened component `k` of `ty`.
    fn rawLeafScalar(e: *Emitter, ty: TypeId, k: u32) Error!TypeId {
        var cur = ty;
        var kk = k;
        while (true) switch (e.t.get(cur)) {
            .scalar, .@"enum" => return cur,
            .vector, .matrix => return e.t.scalar(e.t.component(cur).?),
            .array => |a| {
                kk %= e.t.componentCount(a.elem).?;
                cur = a.elem;
            },
            .@"struct" => |st| for (st.fields.items) |fld| {
                const n = e.t.componentCount(fld.type).?;
                if (kk < n) {
                    cur = fld.type;
                    break;
                }
                kk -= n;
            },
            else => return e.unsupported("values of type '{s}' are not supported here yet", .{try e.t.format(e.arena, ty)}),
        };
    }

    /// Writes value `v` of type `ty` to an output interface variable.
    fn storeInterface(e: *Emitter, iface: Interface, ty: TypeId, v: Id) Error!void {
        if (!iface.elem_array) {
            try e.b.emit(.functions, .store, &.{ iface.var_id, try e.reshape(v, ty, iface.ty) });
            return;
        }
        const et = try e.t.scalar(e.t.component(e.t.get(iface.ty).array.elem).?);
        const n = e.t.componentCount(ty).?;
        for (0..n) |k| {
            const ptr = try e.opRaw(.access_chain, try e.pointerType(.output, try e.typeId(et)), &.{ iface.var_id, try e.constUint(iface.base + @as(u32, @intCast(k))) });
            const x = try e.flatComponent(v, ty, @intCast(k));
            try e.b.emit(.functions, .store, &.{ ptr, try e.convert(x[0], x[1], et) });
        }
    }

    /// Emits `op` with a result of HLSL type `ty`; returns the result id.
    fn op1(e: *Emitter, op: Op, ty: TypeId, operands: []const u32) Error!Id {
        const id = e.b.newId();
        var ops: std.ArrayList(u32) = .empty;
        try ops.appendSlice(e.arena, &.{ try e.typeId(ty), id });
        try ops.appendSlice(e.arena, operands);
        try e.b.emit(.functions, op, ops.items);
        return id;
    }

    /// Pointer to `buffer[index]` (structured / byte-address buffers).
    fn bufferElement(e: *Emitter, res: Ref, index: Ref) Error!Id {
        const elem = (try e.bufferElemType(e.f.inst(res).ty)) orelse return e.unsupported("indexing this resource is not supported yet", .{});
        const id = e.b.newId();
        try e.b.emit(.functions, .access_chain, &.{ try e.pointerType(e.bufferSc(), elem), id, e.val(res), try e.constInt(0), e.val(index) });
        return id;
    }

    /// The laid-out element type of a structured / byte-address buffer.
    fn bufferElemType(e: *Emitter, ty: TypeId) Error!?Id {
        const r = switch (e.t.get(ty)) {
            .resource => |r| r,
            else => return null,
        };
        const elem_ty = switch (r.kind) {
            .byte_address_buffer, .rw_byte_address_buffer => try e.t.scalar(.uint),
            .structured_buffer, .rw_structured_buffer, .append_structured_buffer, .consume_structured_buffer => r.elem,
            else => return null,
        };
        return try e.layoutTypeId(elem_ty, .std430, false);
    }

    /// The BufferBlock struct of a buffer type (one per HLSL type, so
    /// functions taking buffers accept every buffer of that type).
    fn bufferBlockType(e: *Emitter, ty: TypeId) Error!Id {
        if (e.buffer_blocks.get(ty)) |id| return id;
        const r = e.t.get(ty).resource;
        const elem_ty = if (r.kind == .byte_address_buffer or r.kind == .rw_byte_address_buffer) try e.t.scalar(.uint) else r.elem;
        const elem = (try e.bufferElemType(ty)).?;
        const stride = layout.arrayStride(e.t, elem_ty, false, .std430) catch return e.unsupported("buffer element type '{s}'", .{try e.t.format(e.arena, elem_ty)});
        const rt = e.b.newId();
        try e.b.emit(.types_globals, .type_runtime_array, &.{ rt, elem });
        try e.b.emit(.annotations, .decorate, &.{ rt, 6, stride }); // ArrayStride
        const st = e.b.newId();
        try e.b.emit(.types_globals, .type_struct, &.{ st, rt });
        try e.b.emit(.annotations, .member_decorate, &.{ st, 0, 35, 0 }); // Offset 0
        if (e.isTrueMatrix(elem_ty) and storageScalar(e.t.get(elem_ty).matrix.elem).isFloat()) {
            // Buffers of (column-major) matrices: HLSL rows are SPIR-V
            // columns.
            try e.b.emit(.annotations, .member_decorate, &.{ st, 0, 7, layout.matrixStride(e.t, elem_ty, false, .std430) }); // MatrixStride
            try e.b.emit(.annotations, .member_decorate, &.{ st, 0, 4 }); // RowMajor
        }
        if (!r.kind.isWritable() and r.kind != .consume_structured_buffer) try e.b.emit(.annotations, .member_decorate, &.{ st, 0, 24 }); // NonWritable
        try e.b.emit(.annotations, .decorate, &.{ st, e.bufferBlockDecoration() });
        try e.b.emitWithString(.debug_names, .name, &.{st}, try std.fmt.allocPrint(e.arena, "type.{s}.{s}", .{ r.name, try e.typeLabel(elem_ty) }), &.{});
        try e.buffer_blocks.put(e.arena, ty, st);
        return st;
    }

    /// The pointer type of a resource variable of HLSL type `ty` (also how
    /// resources are passed to functions).
    fn resourcePtrType(e: *Emitter, ty: TypeId) Error!Id {
        const p = try e.resourcePointee(ty);
        return e.pointerType(p.sc, p.ty);
    }

    const Pointee = struct { sc: StorageClass, ty: Id };

    /// Storage class and type of a resource variable of HLSL type `ty`
    /// (arrays of resources are arrays of these).
    fn resourcePointee(e: *Emitter, ty: TypeId) Error!Pointee {
        switch (e.t.get(ty)) {
            .sampler => return .{ .sc = .uniform_constant, .ty = try e.samplerType() },
            .resource => |r| switch (r.kind) {
                .raytracing_acceleration_structure => return .{ .sc = .uniform_constant, .ty = try e.accelType() },
                .structured_buffer, .rw_structured_buffer, .append_structured_buffer, .consume_structured_buffer, .byte_address_buffer, .rw_byte_address_buffer => return .{ .sc = e.bufferSc(), .ty = try e.bufferBlockType(ty) },
                .constant_buffer => if (e.t.get(r.elem) == .@"struct") return .{ .sc = .uniform, .ty = try e.constantBufferBlock(r.elem) },
                .texture_buffer => if (e.t.get(r.elem) == .@"struct") return .{ .sc = e.bufferSc(), .ty = try e.textureBufferBlock(r.elem) },
                else => if (texture.shape(r.kind)) |sh| {
                    var plain = sh;
                    plain.combined = false;
                    const img = try e.imageType(plain, r.elem);
                    return .{ .sc = .uniform_constant, .ty = if (sh.combined) try e.sampledImageType(img) else img };
                },
            },
            .array => |arr| {
                const inner = try e.resourcePointee(arr.elem);
                const key: [2]u32 = .{ inner.ty, arr.len };
                if (e.resource_arrays.get(key)) |id| return .{ .sc = inner.sc, .ty = id };
                const id = e.b.newId();
                if (arr.len == 0) {
                    try e.cap(.runtime_descriptor_array);
                    try e.extension("SPV_EXT_descriptor_indexing");
                    try e.b.emit(.types_globals, .type_runtime_array, &.{ id, inner.ty });
                } else try e.b.emit(.types_globals, .type_array, &.{ id, inner.ty, try e.constUint(arr.len) });
                try e.resource_arrays.put(e.arena, key, id);
                return .{ .sc = inner.sc, .ty = id };
            },
            else => {},
        }
        return e.unsupported("resource type '{s}' is not supported yet", .{try e.t.format(e.arena, ty)});
    }

    fn extension(e: *Emitter, name: []const u8) Error!void {
        for (e.extensions.items) |x| if (std.mem.eql(u8, x, name)) return;
        try e.extensions.append(e.arena, name);
        try e.b.emitWithString(.extensions, .extension, &.{}, name, &.{});
    }

    /// `array[i]...` into an array of resources: an access chain to the
    /// element (or sub-array) variable.
    fn resourceArrayAccess(e: *Emitter, ri: usize, a: @FieldType(ir.Op, "access"), ty: TypeId) Error!void {
        const p = try e.resourcePointee(ty);
        var ops: std.ArrayList(u32) = .empty;
        const id = e.b.newId();
        var nonuniform = false;
        try ops.appendSlice(e.arena, &.{ try e.pointerType(p.sc, p.ty), id, e.val(a.base) });
        for (a.indices) |x| {
            if (e.nonuniform_ids.contains(e.val(x))) nonuniform = true;
            try ops.append(e.arena, e.val(x));
        }
        try e.b.emit(.functions, .access_chain, ops.items);
        e.vals[ri] = id;
        if (nonuniform) try e.markNonUniform(id, ty);
    }

    /// Decorates a non-uniformly selected resource value (and requires
    /// the matching capability).
    fn markNonUniform(e: *Emitter, id: Id, ty: TypeId) Error!void {
        try e.cap(.shader_non_uniform);
        try e.extension("SPV_EXT_descriptor_indexing");
        var et = ty;
        while (e.t.get(et) == .array) et = e.t.get(et).array.elem;
        const c: Capability = switch (e.t.get(et)) {
            .sampler => .sampled_image_array_non_uniform_indexing,
            .resource => |r| switch (r.kind) {
                .structured_buffer, .rw_structured_buffer, .append_structured_buffer, .consume_structured_buffer, .byte_address_buffer, .rw_byte_address_buffer => .storage_buffer_array_non_uniform_indexing,
                .buffer => .uniform_texel_buffer_array_non_uniform_indexing,
                .constant_buffer => .uniform_buffer_array_non_uniform_indexing,
                .rw_buffer => .storage_texel_buffer_array_non_uniform_indexing,
                else => if (r.kind.isWritable()) .storage_image_array_non_uniform_indexing else .sampled_image_array_non_uniform_indexing,
            },
            else => .shader_non_uniform,
        };
        try e.cap(c);
        try e.b.emit(.annotations, .decorate, &.{ id, 5300 }); // NonUniform
        try e.nonuniform_ids.put(e.arena, id, {});
    }

    // ------------------------------------------------------------------
    // Images and samplers

    fn accelType(e: *Emitter) Error!Id {
        if (e.accel_type == 0) {
            e.accel_type = e.b.newId();
            try e.b.emit(.types_globals, .type_acceleration_structure_khr, &.{e.accel_type});
        }
        return e.accel_type;
    }

    /// The acceleration structure a resource value designates.
    fn loadAccel(e: *Emitter, r: Ref) Error!Id {
        return e.opRaw(.load, try e.accelType(), &.{e.val(r)});
    }

    /// RayDesc's members: Origin, TMin, Direction, TMax.
    fn rayDesc(e: *Emitter, r: Ref) Error![4]Id {
        const f3 = try e.t.vector(.float, 3);
        const f1 = try e.t.scalar(.float);
        const v = e.val(r);
        return .{
            try e.op1(.composite_extract, f3, &.{ v, 0 }), try e.op1(.composite_extract, f1, &.{ v, 1 }),
            try e.op1(.composite_extract, f3, &.{ v, 2 }), try e.op1(.composite_extract, f1, &.{ v, 3 }),
        };
    }

    /// Ray tracing intrinsics (SPV_KHR_ray_tracing): TraceRay and friends,
    /// and the system values as builtins. Null for other names.
    fn rayIntrinsic(e: *Emitter, name: []const u8, ty: TypeId, args: []const Ref) Error!?Id {
        const eq = std.mem.eql;
        if (eq(u8, name, "TraceRay") or eq(u8, name, "CallShader")) {
            // Through the payload / callable data variable, copied in and
            // back out.
            const trace = eq(u8, name, "TraceRay");
            const data = args[args.len - 1];
            const dty = e.f.inst(data).ty;
            const v = try e.rayVar(if (trace) .ray_payload_khr else .callable_data_khr, dty);
            try e.b.emit(.functions, .store, &.{ v, try e.op1(.load, dty, &.{e.val(data)}) });
            if (trace) {
                const d = try e.rayDesc(args[6]);
                try e.b.emit(.functions, .trace_ray_khr, &.{ try e.loadAccel(args[0]), e.val(args[1]), e.val(args[2]), e.val(args[3]), e.val(args[4]), e.val(args[5]), d[0], d[1], d[2], d[3], v });
            } else try e.b.emit(.functions, .execute_callable_khr, &.{ e.val(args[0]), v });
            try e.b.emit(.functions, .store, &.{ e.val(data), try e.op1(.load, dty, &.{v}) });
            return 0;
        }
        if (eq(u8, name, "ReportHit")) {
            const aty = e.f.inst(args[2]).ty;
            const v = try e.rayVar(.hit_attribute_khr, aty);
            try e.b.emit(.functions, .store, &.{ v, e.val(args[2]) });
            return try e.op1(.report_intersection_khr, ty, &.{ e.val(args[0]), e.val(args[1]) });
        }
        if (eq(u8, name, "IgnoreHit") or eq(u8, name, "AcceptHitAndEndSearch")) {
            try e.b.emit(.functions, if (eq(u8, name, "IgnoreHit")) .ignore_intersection_khr else .terminate_ray_khr, &.{});
            // A terminator: what follows is unreachable.
            try e.b.emit(.functions, .label, &.{e.b.newId()});
            return 0;
        }
        const Sys = struct { []const u8, u32, enum { plain, transpose } };
        const table = [_]Sys{
            .{ "DispatchRaysIndex", 5319, .plain },     .{ "DispatchRaysDimensions", 5320, .plain }, .{ "WorldRayOrigin", 5321, .plain },
            .{ "WorldRayDirection", 5322, .plain },     .{ "ObjectRayOrigin", 5323, .plain },        .{ "ObjectRayDirection", 5324, .plain },
            .{ "RayTMin", 5325, .plain },               .{ "RayTCurrent", 5326, .plain },            .{ "InstanceID", 5327, .plain },
            .{ "InstanceIndex", 6, .plain },            .{ "PrimitiveIndex", 7, .plain },            .{ "HitKind", 5333, .plain },
            .{ "RayFlags", 5351, .plain },              .{ "GeometryIndex", 5352, .plain },          .{ "ObjectToWorld4x3", 5330, .plain },
            .{ "WorldToObject4x3", 5331, .plain },      .{ "ObjectToWorld3x4", 5330, .transpose },   .{ "WorldToObject3x4", 5331, .transpose },
            .{ "ObjectToWorld", 5330, .transpose },     .{ "WorldToObject", 5331, .transpose },
        };
        for (table) |x| {
            if (!eq(u8, name, x[0])) continue;
            if (x[2] == .plain) {
                const vty = try e.builtinValueType(x[1], ty);
                return try e.reshape(try e.op1(.load, vty, &.{try e.builtinInput(x[1], vty)}), vty, ty);
            }
            const m = e.t.get(ty).matrix;
            const mty = try e.t.matrix(m.elem, m.cols, m.rows);
            return try e.op1(.transpose, ty, &.{try e.op1(.load, mty, &.{try e.builtinInput(x[1], mty)})});
        }
        return null;
    }

    /// The SPIR-V type of a builtin read as an HLSL value of type `ty`.
    fn builtinValueType(e: *Emitter, builtin: u32, ty: TypeId) Error!TypeId {
        return switch (builtin) {
            5319, 5320 => e.t.vector(.uint, 3),
            5321...5324 => e.t.vector(.float, 3),
            5325, 5326 => e.t.scalar(.float),
            6, 7, 5327, 5333, 5351, 5352 => e.t.scalar(.uint),
            else => ty,
        };
    }

    fn rayQueryType(e: *Emitter) Error!Id {
        if (e.ray_query_type == 0) {
            e.ray_query_type = e.b.newId();
            try e.b.emit(.types_globals, .type_ray_query_khr, &.{e.ray_query_type});
        }
        return e.ray_query_type;
    }

    /// RayQuery methods (SPV_KHR_ray_query).
    fn rayQueryMethod(e: *Emitter, name: []const u8, res: Ref, args: []const Ref, ty: TypeId) Error!Id {
        const eq = std.mem.eql;
        const q = e.val(res);
        if (eq(u8, name, "TraceRayInline")) {
            // The type's constant flags join the call's.
            var flags = e.val(args[1]);
            const tf = e.t.get(e.f.inst(res).ty).resource.flags;
            if (tf != 0) flags = try e.op1(.bitwise_or, try e.t.scalar(.uint), &.{ flags, try e.constUint(tf) });
            const d = try e.rayDesc(args[3]);
            try e.b.emit(.functions, .ray_query_initialize_khr, &.{ q, try e.loadAccel(args[0]), flags, e.val(args[2]), d[0], d[1], d[2], d[3] });
            return 0;
        }
        if (eq(u8, name, "Proceed")) return e.op1(.ray_query_proceed_khr, ty, &.{q});
        if (eq(u8, name, "Abort")) {
            try e.b.emit(.functions, .ray_query_terminate_khr, &.{q});
            return 0;
        }
        if (eq(u8, name, "CommitNonOpaqueTriangleHit")) {
            try e.b.emit(.functions, .ray_query_confirm_intersection_khr, &.{q});
            return 0;
        }
        if (eq(u8, name, "CommitProceduralPrimitiveHit")) {
            try e.b.emit(.functions, .ray_query_generate_intersection_khr, &.{ q, e.val(args[0]) });
            return 0;
        }
        if (eq(u8, name, "RayFlags")) return e.op1(.ray_query_get_ray_flags_khr, ty, &.{q});
        if (eq(u8, name, "WorldRayOrigin")) return e.op1(.ray_query_get_world_ray_origin_khr, ty, &.{q});
        if (eq(u8, name, "WorldRayDirection")) return e.op1(.ray_query_get_world_ray_direction_khr, ty, &.{q});
        if (eq(u8, name, "RayTMin")) return e.op1(.ray_query_get_ray_t_min_khr, ty, &.{q});
        if (eq(u8, name, "CommittedStatus")) return e.op1(.ray_query_get_intersection_type_khr, ty, &.{ q, try e.constUint(1) });
        if (eq(u8, name, "CandidateType")) return e.op1(.ray_query_get_intersection_type_khr, ty, &.{ q, try e.constUint(0) });
        if (eq(u8, name, "CandidateProceduralPrimitiveNonOpaque")) {
            const opaque_ = try e.op1(.ray_query_get_intersection_candidate_aabb_opaque_khr, ty, &.{q});
            return e.op1(.logical_not, ty, &.{opaque_});
        }
        // Candidate* / Committed* getters.
        const committed = std.mem.startsWith(u8, name, "Committed");
        if (!committed and !std.mem.startsWith(u8, name, "Candidate")) return e.unsupported("RayQuery method '{s}' is not supported yet", .{name});
        const rest = name[if (committed) 9 else 9..];
        const which = try e.constUint(@intFromBool(committed));
        const Get = struct { []const u8, Op, bool };
        const table = [_]Get{
            .{ "ObjectToWorld4x3", .ray_query_get_intersection_object_to_world_khr, false }, .{ "ObjectToWorld3x4", .ray_query_get_intersection_object_to_world_khr, true },
            .{ "WorldToObject4x3", .ray_query_get_intersection_world_to_object_khr, false }, .{ "WorldToObject3x4", .ray_query_get_intersection_world_to_object_khr, true },
            .{ "TriangleFrontFace", .ray_query_get_intersection_front_face_khr, false },     .{ "TriangleBarycentrics", .ray_query_get_intersection_barycentrics_khr, false },
            .{ "TriangleRayT", .ray_query_get_intersection_t_khr, false },                   .{ "RayT", .ray_query_get_intersection_t_khr, false },
            .{ "InstanceIndex", .ray_query_get_intersection_instance_id_khr, false },        .{ "InstanceID", .ray_query_get_intersection_instance_custom_index_khr, false },
            .{ "GeometryIndex", .ray_query_get_intersection_geometry_index_khr, false },     .{ "PrimitiveIndex", .ray_query_get_intersection_primitive_index_khr, false },
            .{ "ObjectRayOrigin", .ray_query_get_intersection_object_ray_origin_khr, false }, .{ "ObjectRayDirection", .ray_query_get_intersection_object_ray_direction_khr, false },
            .{ "InstanceContributionToHitGroupIndex", .ray_query_get_intersection_instance_shader_binding_table_record_offset_khr, false },
        };
        for (table) |g| {
            if (!eq(u8, rest, g[0])) continue;
            if (!g[2]) return e.op1(g[1], ty, &.{ q, which });
            const m = e.t.get(ty).matrix;
            const raw = try e.op1(g[1], try e.t.matrix(m.elem, m.cols, m.rows), &.{ q, which });
            return e.op1(.transpose, ty, &.{raw});
        }
        return e.unsupported("RayQuery method '{s}' is not supported yet", .{name});
    }

    fn samplerType(e: *Emitter) Error!Id {
        if (e.sampler_type == 0) {
            e.sampler_type = e.b.newId();
            try e.b.emit(.types_globals, .type_sampler, &.{e.sampler_type});
        }
        return e.sampler_type;
    }

    fn sampledImageType(e: *Emitter, img: Id) Error!Id {
        if (e.sampled_image_types.get(img)) |id| return id;
        const id = e.b.newId();
        try e.b.emit(.types_globals, .type_sampled_image, &.{ id, img });
        try e.sampled_image_types.put(e.arena, img, id);
        return id;
    }

    /// The scalar an image of `elem` texels samples to (bool as uint).
    fn texelScalar(e: *Emitter, elem: TypeId) Error!Scalar {
        const c = storageScalar(e.t.component(elem) orelse return e.unsupported("textures of '{s}' are not supported yet", .{try e.t.format(e.arena, elem)}));
        return switch (c) {
            .float, .int, .uint => c,
            else => e.unsupported("textures of '{s}' are not supported yet", .{try e.t.format(e.arena, elem)}),
        };
    }

    /// dxc's image format for typed buffers and RW textures.
    fn imageFormat(e: *Emitter, elem: TypeId) u32 {
        const n = e.t.componentCount(elem) orelse return 0;
        const c = e.t.component(elem) orelse return 0;
        const k: usize = switch (n) {
            1 => 0,
            2 => 1,
            4 => 2,
            else => return 0,
        };
        const table: [3]u32 = switch (c) {
            .float => .{ 3, 6, 1 }, // R32f, Rg32f, Rgba32f
            .half, .min16float, .min10float => .{ 9, 7, 2 }, // R16f, Rg16f, Rgba16f
            .int => .{ 24, 25, 21 }, // R32i, Rg32i, Rgba32i
            .min16int, .min12int => .{ 28, 26, 22 }, // R16i, Rg16i, Rgba16i
            .uint => .{ 33, 35, 30 }, // R32ui, Rg32ui, Rgba32ui
            .min16uint => .{ 38, 36, 31 }, // R16ui, Rg16ui, Rgba16ui
            else => return 0,
        };
        return table[k];
    }

    fn imageType(e: *Emitter, sh: texture.Shape, elem: TypeId) Error!Id {
        const st = try e.scalarType(try e.texelScalar(elem));
        const dim: u32 = switch (sh.dim) {
            .d1 => 0,
            .d2 => 1,
            .d3 => 2,
            .cube => 3,
            .buffer => 5,
        };
        const sampled: u32 = if (sh.rw) 2 else 1;
        const format: u32 = if (sh.rw or sh.dim == .buffer) e.imageFormat(elem) else 0;
        const key: [6]u32 = .{ st, dim, @intFromBool(sh.array), @intFromBool(sh.ms), sampled, format };
        if (e.image_types.get(key)) |id| return id;
        switch (sh.dim) {
            .d1 => try e.cap(if (sh.rw) .image1d else .sampled1d),
            .buffer => try e.cap(if (sh.rw) .image_buffer else .sampled_buffer),
            .cube => if (sh.array) try e.cap(.sampled_cube_array),
            else => {},
        }
        if (sh.rw and sh.ms) try e.cap(if (sh.array) .image_ms_array else .storage_image_multisample);
        switch (format) {
            6, 7, 9, 25, 26, 28, 35, 36, 38 => try e.cap(.storage_image_extended_formats),
            else => {},
        }
        const id = e.b.newId();
        try e.b.emit(.types_globals, .type_image, &.{ id, st, dim, 2, key[2], key[3], sampled, format });
        try e.image_types.put(e.arena, key, id);
        return id;
    }

    /// Whether `r` is a texture or typed buffer.
    fn isImage(e: *Emitter, r: Ref) bool {
        return switch (e.t.get(e.f.inst(r).ty)) {
            .resource => |rk| texture.shape(rk.kind) != null,
            else => false,
        };
    }

    fn imageTypeOf(e: *Emitter, r: Ref) Error!Id {
        const rk = e.resourceInfo(r);
        return e.imageType(texture.shape(rk.kind).?, rk.elem);
    }

    fn loadImage(e: *Emitter, r: Ref) Error!Id {
        if (texture.shape(e.resourceInfo(r).kind)) |sh| if (sh.combined) {
            // A combined image sampler: its image.
            const si = try e.opRaw(.load, try e.sampledImageType(try e.imageTypeOf(r)), &.{e.val(r)});
            if (e.nonuniform_ids.contains(e.val(r))) try e.markNonUniform(si, e.f.inst(r).ty);
            return e.opRaw(.image, try e.imageTypeOf(r), &.{si});
        };
        const id = try e.opRaw(.load, try e.imageTypeOf(r), &.{e.val(r)});
        if (e.nonuniform_ids.contains(e.val(r))) try e.markNonUniform(id, e.f.inst(r).ty);
        return id;
    }

    fn resourceInfo(e: *Emitter, r: Ref) @FieldType(types.Type, "resource") {
        return e.t.get(e.f.inst(r).ty).resource;
    }

    /// The first components of a four-component texel, as `ty`.
    fn texelResult(e: *Emitter, v4: Id, s: Scalar, ty: TypeId) Error!Id {
        const n = e.t.componentCount(ty) orelse return e.unsupported("texel type '{s}'", .{try e.t.format(e.arena, ty)});
        if (storageScalar(e.t.component(ty).?) != s) return e.unsupported("texel type '{s}'", .{try e.t.format(e.arena, ty)});
        if (n == 4) return v4;
        if (n == 1) return e.op1(.composite_extract, ty, &.{ v4, 0 });
        var ops: std.ArrayList(u32) = .empty;
        try ops.appendSlice(e.arena, &.{ v4, v4 });
        for (0..n) |k| try ops.append(e.arena, @intCast(k));
        return e.op1(.vector_shuffle, ty, ops.items);
    }

    fn vec4Of(e: *Emitter, s: Scalar) Error!Id {
        return e.typeId(try e.t.vector(s, 4));
    }

    /// `res[index]` on a texture or typed buffer.
    fn imageIndexLoad(e: *Emitter, res: Ref, coord: Id, ty: TypeId) Error!Id {
        const r = e.resourceInfo(res);
        const sh = texture.shape(r.kind).?;
        const s = try e.texelScalar(r.elem);
        const img = try e.loadImage(res);
        var v: Id = undefined;
        if (sh.rw) {
            if (e.imageFormat(r.elem) == 0) try e.cap(.storage_image_read_without_format);
            v = if (sh.ms)
                try e.opRaw(.image_read, try e.vec4Of(s), &.{ img, coord, 0x40, try e.constInt(0) })
            else
                try e.opRaw(.image_read, try e.vec4Of(s), &.{ img, coord });
        } else if (sh.dim == .buffer) {
            v = try e.opRaw(.image_fetch, try e.vec4Of(s), &.{ img, coord });
        } else {
            const operand: u32 = if (sh.ms) 0x40 else 0x2; // Sample 0 / Lod 0
            v = try e.opRaw(.image_fetch, try e.vec4Of(s), &.{ img, coord, operand, try e.constUint(0) });
        }
        return e.texelResult(v, s, ty);
    }

    fn imageWrite(e: *Emitter, res: Ref, coord: Id, value: Id) Error!void {
        const r = e.resourceInfo(res);
        _ = try e.texelScalar(r.elem);
        if (e.imageFormat(r.elem) == 0) try e.cap(.storage_image_write_without_format);
        const img = try e.loadImage(res);
        try e.b.emit(.functions, .image_write, &.{ img, coord, value });
    }

    /// The constant id of an IR value built only from constants, or null.
    fn constValue(e: *Emitter, r: Ref) Error!?Id {
        const i = e.f.inst(r);
        switch (i.op) {
            .constant => return e.val(r),
            .construct => |xs| {
                if (e.t.get(i.ty) != .vector) return null;
                // 1-vectors are SPIR-V scalars.
                if (e.isScalarLike(i.ty)) return e.constValue(xs[0]);
                var ops: std.ArrayList(u32) = .empty;
                const id = e.b.newId();
                try ops.appendSlice(e.arena, &.{ try e.typeId(i.ty), id });
                for (xs) |x| try ops.append(e.arena, (try e.constValue(x)) orelse return null);
                try e.b.emit(.types_globals, .constant_composite, ops.items);
                return id;
            },
            else => return null,
        }
    }

    fn method(e: *Emitter, name: []const u8, res: Ref, args: []const Ref, ty: TypeId) Error!Id {
        const eq = std.mem.eql;
        if (e.t.get(e.f.inst(res).ty) != .resource) return e.unsupported("method '{s}' is not supported yet", .{name});
        if (isRayQuery(e.t, e.f.inst(res).ty)) return e.rayQueryMethod(name, res, args, ty);
        const r = e.resourceInfo(res);
        if (eq(u8, name, "GetDimensions")) {
            try e.getDimensions(res, r, args);
            return 0;
        }
        if (r.kind == .byte_address_buffer or r.kind == .rw_byte_address_buffer) return e.byteAddressMethod(name, res, args, ty);
        if (eq(u8, name, "IncrementCounter")) return e.counterOp(res, true, false);
        if (eq(u8, name, "DecrementCounter")) return e.counterOp(res, false, true);
        if (eq(u8, name, "Append") or eq(u8, name, "Consume")) {
            const idx = try e.counterOp(res, eq(u8, name, "Append"), eq(u8, name, "Consume"));
            const elem = (try e.bufferElemType(e.f.inst(res).ty)).?;
            const ptr = try e.opRaw(.access_chain, try e.pointerType(e.bufferSc(), elem), &.{ e.val(res), try e.constUint(0), idx });
            const ety = r.elem;
            if (eq(u8, name, "Append")) {
                try e.b.emit(.functions, .store, &.{ ptr, try e.toLayout(e.val(args[0]), e.f.inst(args[0]).ty, .std430, false) });
                _ = ety;
                return 0;
            }
            return e.fromLayout(try e.opRaw(.load, elem, &.{ptr}), ty, .std430, false);
        }
        if (eq(u8, name, "Load") and (r.kind == .structured_buffer or r.kind == .rw_structured_buffer)) {
            const ptr = try e.bufferElement(res, args[0]);
            const raw = try e.opRaw(.load, try e.layoutTypeId(ty, .std430, false), &.{ptr});
            return e.fromLayout(raw, ty, .std430, false);
        }
        const sh = texture.shape(r.kind) orelse return e.unsupported("method '{s}' is not supported yet", .{name});
        const call = texture.decode(name, sh, args.len) orelse return e.unsupported("method '{s}' is not supported yet", .{name});
        const status: ?Ref = if (call.status) |k| args[k] else null;

        if (call.op.implicitLod()) try e.checkDerivatives();
        const s = try e.texelScalar(r.elem);
        const img = try e.loadImage(res);
        const coord = e.val(args[call.coord]);
        // Image operands, in operand-mask bit order.
        var mask: u32 = 0;
        var extra: std.ArrayList(u32) = .empty;
        if (call.bias) |k| {
            mask |= 0x1;
            try extra.append(e.arena, e.val(args[k]));
        }
        if (call.lod) |k| {
            mask |= 0x2;
            try extra.append(e.arena, e.val(args[k]));
        } else if (call.op == .sample_cmp_level_zero) {
            mask |= 0x2;
            try extra.append(e.arena, try e.constant(try e.t.scalar(.float), .{ .float = 0 }));
        }
        if (call.ddx) |k| {
            mask |= 0x4;
            try extra.appendSlice(e.arena, &.{ e.val(args[k]), e.val(args[call.ddy.?]) });
        }
        var lod_from_coord: ?Id = null;
        var coord_id = coord;
        if (call.op == .load and !sh.rw and !sh.ms and sh.dim != .buffer) {
            // Load(int3 x): the last component is the mip level.
            const n = sh.coords() + @intFromBool(sh.array);
            const ct = try e.t.vector(.int, @intCast(n + 1));
            _ = ct;
            const it = try e.t.scalar(.int);
            lod_from_coord = try e.op1(.composite_extract, it, &.{ coord, n });
            if (n == 1) {
                coord_id = try e.op1(.composite_extract, it, &.{ coord, 0 });
            } else {
                var ops: std.ArrayList(u32) = .empty;
                try ops.appendSlice(e.arena, &.{ coord, coord });
                for (0..n) |k| try ops.append(e.arena, @intCast(k));
                coord_id = try e.op1(.vector_shuffle, try e.t.vector(.int, @intCast(n)), ops.items);
            }
            mask |= 0x2;
            try extra.append(e.arena, lod_from_coord.?);
        }
        if (call.offsets4) {
            // Four offsets: ConstOffsets, an array of constants.
            const k = call.offset.?;
            const ot = try e.t.vector(.int, 2);
            const arr_ty = try e.t.array(ot, 4);
            var ops: std.ArrayList(u32) = .empty;
            const id = e.b.newId();
            try ops.appendSlice(e.arena, &.{ try e.typeId(arr_ty), id });
            for (0..4) |j| {
                const c = (try e.constValue(args[k + j])) orelse return e.unsupported("Gather with four offsets that are not constants is not supported yet", .{});
                try ops.append(e.arena, c);
            }
            try e.b.emit(.types_globals, .constant_composite, ops.items);
            try e.cap(.image_gather_extended);
            mask |= 0x20;
            try extra.append(e.arena, id);
        } else if (call.offset) |k| {
            if (try e.constValue(args[k])) |c| {
                mask |= 0x8;
                try extra.append(e.arena, c);
            } else {
                if (call.op != .gather and call.op != .gather_cmp) return e.unsupported("texel offsets that are not constants (they need loop unrolling) are not supported yet", .{});
                try e.cap(.image_gather_extended);
                mask |= 0x10;
                try extra.append(e.arena, e.val(args[k]));
            }
        }
        if (call.sample_index) |k| {
            mask |= 0x40;
            try extra.append(e.arena, e.val(args[k]));
        }
        if (call.clamp) |k| {
            try e.cap(.min_lod);
            mask |= 0x80;
            try extra.append(e.arena, e.val(args[k]));
        }
        var ops: std.ArrayList(u32) = .empty;
        if (call.op == .load) {
            if (sh.rw and e.imageFormat(r.elem) == 0) try e.cap(.storage_image_read_without_format);
            try ops.appendSlice(e.arena, &.{ img, coord_id });
            if (mask != 0) {
                try ops.append(e.arena, mask);
                try ops.appendSlice(e.arena, extra.items);
            }
            const v = try e.imageOp(if (sh.rw) .image_read else .image_fetch, try e.vec4Of(s), ops.items, status);
            return e.texelResult(v, s, ty);
        }
        if (call.op == .sample_position) return e.unsupported("GetSamplePosition is not supported yet", .{});
        const si = if (sh.combined) blk: {
            const v = try e.opRaw(.load, try e.sampledImageType(try e.imageTypeOf(res)), &.{e.val(res)});
            if (e.nonuniform_ids.contains(e.val(res))) try e.markNonUniform(v, e.f.inst(res).ty);
            break :blk v;
        } else blk: {
            const smp = try e.opRaw(.load, try e.samplerType(), &.{e.val(args[call.sampler.?])});
            if (e.nonuniform_ids.contains(e.val(args[call.sampler.?]))) try e.markNonUniform(smp, e.f.inst(args[call.sampler.?]).ty);
            const v = try e.opRaw(.sampled_image, try e.sampledImageType(try e.imageTypeOf(res)), &.{ img, smp });
            if (e.nonuniform_ids.contains(img) or e.nonuniform_ids.contains(smp)) try e.markNonUniform(v, e.f.inst(res).ty);
            break :blk v;
        };
        if (call.op == .calc_lod or call.op == .calc_lod_unclamped) {
            try e.cap(.image_query);
            const q = try e.opRaw(.image_query_lod, try e.typeId(try e.t.vector(.float, 2)), &.{ si, coord });
            return e.op1(.composite_extract, try e.t.scalar(.float), &.{ q, @intFromBool(call.op == .calc_lod_unclamped) });
        }
        try ops.appendSlice(e.arena, &.{ si, coord });
        if (call.compare) |k| try ops.append(e.arena, e.val(args[k]));
        if (call.op == .gather) try ops.append(e.arena, try e.constInt(call.channel));
        if (call.op == .gather_cmp and call.channel != 0) return e.unsupported("'{s}' is not supported for SPIR-V", .{name});
        try ops.append(e.arena, mask);
        try ops.appendSlice(e.arena, extra.items);
        const op: Op = switch (call.op) {
            .sample, .sample_bias => .image_sample_implicit_lod,
            .sample_level, .sample_grad => .image_sample_explicit_lod,
            .sample_cmp, .sample_cmp_bias => .image_sample_dref_implicit_lod,
            .sample_cmp_level_zero, .sample_cmp_level, .sample_cmp_grad => .image_sample_dref_explicit_lod,
            .gather => .image_gather,
            .gather_cmp => .image_dref_gather,
            else => unreachable,
        };
        if (call.op.isCmp() and call.op != .gather_cmp) return e.imageOp(op, try e.scalarType(s), ops.items, status);
        const v = try e.imageOp(op, try e.vec4Of(s), ops.items, status);
        return e.texelResult(v, s, ty);
    }

    /// An image instruction; with a status argument, its sparse variant
    /// (the residency code goes to the status).
    fn imageOp(e: *Emitter, op: Op, result_ty: Id, ops: []const u32, status: ?Ref) Error!Id {
        const st = status orelse return e.opRaw(op, result_ty, ops);
        try e.cap(.sparse_residency);
        const sparse: Op = switch (op) {
            .image_sample_implicit_lod => .image_sparse_sample_implicit_lod,
            .image_sample_explicit_lod => .image_sparse_sample_explicit_lod,
            .image_sample_dref_implicit_lod => .image_sparse_sample_dref_implicit_lod,
            .image_sample_dref_explicit_lod => .image_sparse_sample_dref_explicit_lod,
            .image_fetch => .image_sparse_fetch,
            .image_gather => .image_sparse_gather,
            .image_dref_gather => .image_sparse_dref_gather,
            .image_read => .image_sparse_read,
            else => return e.unsupported("this texture operation with a status argument is not supported yet", .{}),
        };
        const int_id = try e.scalarType(.int);
        const sty = e.b.newId();
        try e.b.emit(.types_globals, .type_struct, &.{ sty, int_id, result_ty });
        const r = try e.opRaw(sparse, sty, ops);
        const code = try e.opRaw(.composite_extract, int_id, &.{ r, 0 });
        try e.b.emit(.functions, .store, &.{ e.val(st), try e.opRaw(.bitcast, try e.scalarType(.uint), &.{code}) });
        return e.opRaw(.composite_extract, result_ty, &.{ r, 1 });
    }

    /// Load/Store(2..4) and atomics on byte-address buffers (uint words).
    fn byteAddressMethod(e: *Emitter, name: []const u8, res: Ref, args: []const Ref, ty: TypeId) Error!Id {
        const uint_ty = try e.t.scalar(.uint);
        const word = struct {
            fn f(em: *Emitter, base: Id, off: Id, k: u32) Error!Id {
                const ut = try em.t.scalar(.uint);
                var idx = try em.op1(.shift_right_logical, ut, &.{ off, try em.constUint(2) });
                if (k > 0) idx = try em.op1(.i_add, ut, &.{ idx, try em.constUint(k) });
                return em.opRaw(.access_chain, try em.pointerType(em.bufferSc(), try em.scalarType(.uint)), &.{ base, try em.constInt(0), idx });
            }
        }.f;
        const off = try e.convert(e.val(args[0]), e.f.inst(args[0]).ty, uint_ty);
        if (std.mem.startsWith(u8, name, "Load") and args.len == 1) {
            if (e.t.component(ty) != .uint or e.t.get(ty) == .matrix) return e.rawLoad(e.val(res), off, ty);
            const n = e.t.componentCount(ty).?;
            const parts = try e.arena.alloc(Id, n);
            for (parts, 0..) |*p, k| p.* = try e.op1(.load, uint_ty, &.{try word(e, e.val(res), off, @intCast(k))});
            return if (n == 1) parts[0] else e.op1(.composite_construct, ty, parts);
        }
        if (std.mem.startsWith(u8, name, "Store") and args.len == 2) {
            const vty = e.f.inst(args[1]).ty;
            if (e.t.component(vty) != .uint or e.t.get(vty) == .matrix) {
                try e.rawStore(e.val(res), off, vty, e.val(args[1]));
                return 0;
            }
            const n = e.t.componentCount(vty).?;
            for (0..n) |k| {
                const v = if (n == 1) e.val(args[1]) else try e.op1(.composite_extract, uint_ty, &.{ e.val(args[1]), @intCast(k) });
                try e.b.emit(.functions, .store, &.{ try word(e, e.val(res), off, @intCast(k)), v });
            }
            return 0;
        }
        if (std.mem.startsWith(u8, name, "Interlocked")) {
            const vc = e.t.component(e.f.inst(args[1]).ty) orelse return e.unsupported("'{s}' on this value is not supported yet", .{name});
            if (vc.size() != 4) return e.unsupported("64-bit '{s}' is not supported yet", .{name});
            return e.atomicOp(name["Interlocked".len..], try word(e, e.val(res), off, 0), uint_ty, 1, args[1..]);
        }
        return e.unsupported("method '{s}' is not supported yet", .{name});
    }

    /// Pointer to the 32-bit word holding byte `addr` of a byte-address
    /// buffer.
    fn rawWord(e: *Emitter, buf: Id, addr: Id) Error!Id {
        const ut = try e.t.scalar(.uint);
        const idx = try e.op1(.shift_right_logical, ut, &.{ addr, try e.constUint(2) });
        return e.opRaw(.access_chain, try e.pointerType(e.bufferSc(), try e.scalarType(.uint)), &.{ buf, try e.constInt(0), idx });
    }

    /// The scalar type and byte offset of flattened component `k` of a
    /// value of `ty` in a byte-address buffer (natural alignment).
    fn rawComponent(e: *Emitter, ty: TypeId, k: u32) Error!struct { TypeId, u32 } {
        const off = layout.componentOffset(e.arena, e.t, ty, false, k, .dx_packed) catch return e.unsupported("byte-address buffer accesses of type '{s}' are not supported yet", .{try e.t.format(e.arena, ty)});
        var cur = ty;
        var kk = k;
        while (true) switch (e.t.get(cur)) {
            .scalar, .@"enum" => return .{ cur, off },
            .vector, .matrix => return .{ try e.t.scalar(e.t.component(cur).?), off },
            .array => |a| {
                const n = e.t.componentCount(a.elem) orelse return e.unsupported("byte-address buffer accesses of type '{s}' are not supported yet", .{try e.t.format(e.arena, ty)});
                kk %= n;
                cur = a.elem;
            },
            .@"struct" => |st| {
                for (st.fields.items) |fld| {
                    const n = e.t.componentCount(fld.type).?;
                    if (kk < n) {
                        cur = fld.type;
                        break;
                    }
                    kk -= n;
                }
            },
            else => return e.unsupported("byte-address buffer accesses of type '{s}' are not supported yet", .{try e.t.format(e.arena, ty)}),
        };
    }

    /// A templated byte-address Load: 32-bit words, combined for 64-bit
    /// components and split for 16-bit ones.
    fn rawLoad(e: *Emitter, buf: Id, base: Id, ty: TypeId) Error!Id {
        const ut = try e.t.scalar(.uint);
        const n = e.t.componentCount(ty) orelse return e.unsupported("byte-address buffer accesses of type '{s}' are not supported yet", .{try e.t.format(e.arena, ty)});
        const comps = try e.arena.alloc(Id, n);
        for (comps, 0..) |*c, k| {
            const rc = try e.rawComponent(ty, @intCast(k));
            const sc = rc[0];
            const addr = try e.op1(.i_add, ut, &.{ base, try e.constUint(rc[1]) });
            const w0 = try e.op1(.load, ut, &.{try e.rawWord(buf, addr)});
            const comp = storageScalar(e.t.component(sc).?);
            c.* = switch (comp.size()) {
                8 => blk: {
                    const addr1 = try e.op1(.i_add, ut, &.{ addr, try e.constUint(4) });
                    const w1 = try e.op1(.load, ut, &.{try e.rawWord(buf, addr1)});
                    const pair = try e.op1(.composite_construct, try e.t.vector(.uint, 2), &.{ w0, w1 });
                    break :blk try e.op1(.bitcast, sc, &.{pair});
                },
                2 => blk: {
                    const shift = try e.op1(.shift_left_logical, ut, &.{ try e.op1(.bitwise_and, ut, &.{ addr, try e.constUint(2) }), try e.constUint(3) });
                    const bits = try e.op1(.shift_right_logical, ut, &.{ w0, shift });
                    const u16t = try e.t.scalar(.uint16);
                    const h = try e.op1(.u_convert, u16t, &.{bits});
                    break :blk if (comp == .uint16) h else try e.op1(.bitcast, sc, &.{h});
                },
                else => if (comp == .uint) w0 else if (comp == .bool) try e.convert(w0, ut, sc) else try e.op1(.bitcast, sc, &.{w0}),
            };
        }
        return e.composeFlat(ty, comps);
    }

    fn rawStore(e: *Emitter, buf: Id, base: Id, ty: TypeId, v: Id) Error!void {
        const ut = try e.t.scalar(.uint);
        const n = e.t.componentCount(ty) orelse return e.unsupported("byte-address buffer accesses of type '{s}' are not supported yet", .{try e.t.format(e.arena, ty)});
        for (0..n) |k| {
            const rc = try e.rawComponent(ty, @intCast(k));
            const sc = rc[0];
            const x = (try e.flatComponent(v, ty, @intCast(k)))[0];
            const addr = try e.op1(.i_add, ut, &.{ base, try e.constUint(rc[1]) });
            const comp = storageScalar(e.t.component(sc).?);
            switch (comp.size()) {
                8 => {
                    const pair = try e.op1(.bitcast, try e.t.vector(.uint, 2), &.{x});
                    try e.b.emit(.functions, .store, &.{ try e.rawWord(buf, addr), try e.op1(.composite_extract, ut, &.{ pair, 0 }) });
                    const addr1 = try e.op1(.i_add, ut, &.{ addr, try e.constUint(4) });
                    try e.b.emit(.functions, .store, &.{ try e.rawWord(buf, addr1), try e.op1(.composite_extract, ut, &.{ pair, 1 }) });
                },
                2 => {
                    // Replace the half of the word (not atomic, as dxc).
                    const u16t = try e.t.scalar(.uint16);
                    const h = if (comp == .uint16) x else try e.op1(.bitcast, u16t, &.{x});
                    const wide = try e.op1(.u_convert, ut, &.{h});
                    const shift = try e.op1(.shift_left_logical, ut, &.{ try e.op1(.bitwise_and, ut, &.{ addr, try e.constUint(2) }), try e.constUint(3) });
                    const ptr = try e.rawWord(buf, addr);
                    const old = try e.op1(.load, ut, &.{ptr});
                    const keep = try e.op1(.bitwise_and, ut, &.{ old, try e.op1(.not_, ut, &.{try e.op1(.shift_left_logical, ut, &.{ try e.constUint(0xFFFF), shift })}) });
                    try e.b.emit(.functions, .store, &.{ ptr, try e.op1(.bitwise_or, ut, &.{ keep, try e.op1(.shift_left_logical, ut, &.{ wide, shift }) }) });
                },
                else => {
                    const w = if (comp == .uint) x else if (comp == .bool) try e.convert(x, sc, ut) else try e.op1(.bitcast, ut, &.{x});
                    try e.b.emit(.functions, .store, &.{ try e.rawWord(buf, addr), w });
                },
            }
        }
    }

    /// A value of `ty` from its flattened scalar components.
    fn composeFlat(e: *Emitter, ty: TypeId, comps: []const Id) Error!Id {
        switch (e.t.get(ty)) {
            .scalar, .@"enum", .vector, .matrix => return e.fromScalars(ty, comps),
            .array => |a| {
                const n = e.t.componentCount(a.elem).?;
                const parts = try e.arena.alloc(Id, a.len);
                for (parts, 0..) |*p, k| p.* = try e.composeFlat(a.elem, comps[k * n ..][0..n]);
                return e.op1(.composite_construct, ty, parts);
            },
            .@"struct" => |st| {
                const parts = try e.arena.alloc(Id, st.fields.items.len);
                var at: usize = 0;
                for (parts, st.fields.items) |*p, fld| {
                    const n = e.t.componentCount(fld.type).?;
                    p.* = try e.composeFlat(fld.type, comps[at..][0..n]);
                    at += n;
                }
                return e.op1(.composite_construct, ty, parts);
            },
            else => return e.unsupported("values of type '{s}' are not supported yet", .{try e.t.format(e.arena, ty)}),
        }
    }

    fn getDimensions(e: *Emitter, res: Ref, r: @FieldType(types.Type, "resource"), args: []const Ref) Error!void {
        const uint_ty = try e.t.scalar(.uint);
        const store = struct {
            fn f(em: *Emitter, arg: Ref, v: Id) Error!void {
                const ty = em.f.inst(arg).ty;
                const cv = try em.convert(v, try em.t.scalar(.uint), ty);
                try em.b.emit(.functions, .store, &.{ em.val(arg), cv });
            }
        }.f;
        switch (r.kind) {
            .structured_buffer, .rw_structured_buffer, .append_structured_buffer, .consume_structured_buffer, .byte_address_buffer, .rw_byte_address_buffer => {
                const len = try e.op1(.array_length, uint_ty, &.{ e.val(res), 0 });
                if (r.kind == .byte_address_buffer or r.kind == .rw_byte_address_buffer) {
                    try store(e, args[0], try e.op1(.i_mul, uint_ty, &.{ len, try e.constUint(4) }));
                } else {
                    try store(e, args[0], len);
                    if (args.len > 1) {
                        const stride = layout.arrayStride(e.t, r.elem, false, .std430) catch return e.unsupported("buffer element type", .{});
                        try store(e, args[1], try e.constUint(stride));
                    }
                }
                return;
            },
            else => {},
        }
        const sh = texture.shape(r.kind) orelse return e.unsupported("GetDimensions on this resource is not supported yet", .{});
        try e.cap(.image_query);
        const img = try e.loadImage(res);
        const d = texture.getDimensions(sh, args.len);
        const n: u8 = if (sh.dim == .buffer) 1 else (if (sh.dim == .cube) 2 else sh.coords()) + @intFromBool(sh.array);
        const size_ty = if (n == 1) uint_ty else try e.t.vector(.uint, n);
        const size = if (sh.hasMips())
            try e.op1(.image_query_size_lod, size_ty, &.{ img, if (d.mip) |k| e.val(args[k]) else try e.constUint(0) })
        else
            try e.op1(.image_query_size, size_ty, &.{img});
        for (d.outs[0..d.count]) |o| {
            const v = if (o.comp == 3)
                try e.op1(if (sh.ms) .image_query_samples else .image_query_levels, uint_ty, &.{img})
            else if (n == 1)
                size
            else
                try e.op1(.composite_extract, uint_ty, &.{ size, o.comp });
            try store(e, args[o.arg], v);
        }
    }

    /// The global a resource value comes from (`load (global g)`).
    /// Whether pointer / resource `r` reaches into a shader record buffer.
    fn inShaderRecord(e: *Emitter, r: Ref) bool {
        var x = r;
        while (e.f.inst(x).op == .access) x = e.f.inst(x).op.access.base;
        if (e.f.inst(x).op == .global) return e.m.globals.items[e.f.inst(x).op.global].shader_record;
        // ConstantBuffer<T> values (through locals and parameters).
        const t = e.t.get(e.f.inst(x).ty);
        if (t != .resource or t.resource.kind != .constant_buffer) return false;
        const g = e.globalOf(x) orelse return false;
        return e.m.globals.items[g].shader_record;
    }

    fn globalOf(e: *Emitter, r: Ref) ?u32 {
        const i = e.f.inst(r);
        return switch (i.op) {
            .global => |g| g,
            .load => |p| e.globalOf(p),
            .local_var => for (e.f.insts.items) |inst| {
                if (inst.op == .store and inst.op.store.ptr == r) break e.globalOf(inst.op.store.value);
            } else null,
            // A specialized parameter: the global it is bound to.
            .param => |pi| blk: {
                if (pi >= e.cur_bindings.len or e.cur_bindings[pi] == 0 or e.cur_bindings[pi] & recipe_tag != 0) break :blk null;
                for (e.global_vars, 0..) |v, gi| if (v == e.cur_bindings[pi]) break :blk @intCast(gi);
                break :blk null;
            },
            else => null,
        };
    }

    /// Interface values whose builtin type differs from the declared one
    /// (`uint i : SV_DispatchThreadID` reads component x of a uint3).
    fn reshape(e: *Emitter, v: Id, from: TypeId, to: TypeId) Error!Id {
        if (from == to) return v;
        const fs = e.t.shape(from).?;
        const ts = e.t.shape(to).?;
        var cur = v;
        var cur_ty = from;
        if (ts.count() < fs.count()) {
            const ct = e.t.component(from).?;
            if (ts.count() == 1) {
                cur_ty = try e.t.scalar(ct);
                cur = try e.op1(.composite_extract, cur_ty, &.{ cur, 0 });
            } else {
                cur_ty = try e.t.vector(ct, ts.cols);
                var ops: std.ArrayList(u32) = .empty;
                try ops.appendSlice(e.arena, &.{ cur, cur });
                for (0..ts.cols) |c| try ops.append(e.arena, @intCast(c));
                cur = try e.op1(.vector_shuffle, cur_ty, ops.items);
            }
        } else if (ts.count() > fs.count()) {
            return e.unsupported("widening interface values is not supported yet", .{});
        }
        if (cur_ty != to) cur = try e.convert(cur, cur_ty, try e.t.withComponent(cur_ty, e.t.component(to).?));
        return cur;
    }

    fn convert(e: *Emitter, v: Id, from: TypeId, to: TypeId) Error!Id {
        const fc = e.compOf(from);
        const tc = e.compOf(to);
        if (fc == tc) return v;
        if (tc == .bool) {
            const zero = try e.splatConst(from, .{ .int = 0 });
            return e.op1(if (fc.isFloat()) .f_ord_not_equal else .i_not_equal, to, &.{ v, zero });
        }
        if (fc == .bool) {
            const one = try e.splatConst(to, .{ .int = 1 });
            const zero = try e.splatConst(to, .{ .int = 0 });
            return e.op1(.select, to, &.{ v, one, zero });
        }
        const op: Op = if (fc.isFloat() and tc.isFloat())
            .f_convert
        else if (fc.isFloat())
            (if (tc.isUnsigned()) .convert_f_to_u else .convert_f_to_s)
        else if (tc.isFloat())
            (if (fc.isUnsigned()) .convert_u_to_f else .convert_s_to_f)
        else if (fc.size() == tc.size())
            .bitcast
        else {
            // Width change: zero- or sign-extend by the source's
            // signedness into an integer of the target width and the
            // source's signedness, then reinterpret.
            const mid_c: Scalar = switch (tc.size()) {
                2 => if (fc.isUnsigned()) .uint16 else .int16,
                8 => if (fc.isUnsigned()) .uint64 else .int64,
                else => if (fc.isUnsigned()) .uint else .int,
            };
            const mid = try e.t.withComponent(to, mid_c);
            const ext = try e.op1(if (fc.isUnsigned()) .u_convert else .s_convert, mid, &.{v});
            if (mid == to) return ext;
            return e.op1(.bitcast, to, &.{ext});
        };
        return e.op1(op, to, &.{v});
    }

    /// A constant of `ty`'s component, splatted to its shape.
    fn splatConst(e: *Emitter, ty: TypeId, c: ir.Constant) Error!Id {
        const s = try e.constant(try e.t.scalar(e.t.component(ty).?), c);
        const n = e.t.componentCount(ty).?;
        if (e.isScalarLike(ty)) return s;
        const id = e.b.newId();
        var ops: std.ArrayList(u32) = .empty;
        try ops.appendSlice(e.arena, &.{ try e.typeId(ty), id });
        for (0..n) |_| try ops.append(e.arena, s);
        try e.b.emit(.types_globals, .constant_composite, ops.items);
        return id;
    }

    fn binary(e: *Emitter, op: ir.BinaryOp, ty: TypeId, a: Id, b: Id) Error!Id {
        const c = e.compOf(ty);
        const f = c.isFloat();
        const u = c.isUnsigned();
        const sop: Op = switch (op) {
            .add => if (f) .f_add else .i_add,
            .sub => if (f) .f_sub else .i_sub,
            .mul => if (f) .f_mul else .i_mul,
            .div => if (f) .f_div else if (u) .u_div else .s_div,
            .rem => if (f) .f_rem else if (u) .u_mod else .s_rem,
            .bit_and => if (c == .bool) .logical_and else .bitwise_and,
            .bit_or => if (c == .bool) .logical_or else .bitwise_or,
            .bit_xor => if (c == .bool) .logical_not_equal else .bitwise_xor,
            .log_and => .logical_and,
            .log_or => .logical_or,
            .shl, .shr => {
                // HLSL masks the shift amount to the bit width.
                const mask = try e.splatConst(ty, .{ .int = @as(i64, c.size()) * 8 - 1 });
                const amount = try e.op1(.bitwise_and, ty, &.{ b, mask });
                const shop: Op = if (op == .shl) .shift_left_logical else if (u) .shift_right_logical else .shift_right_arithmetic;
                return e.op1(shop, ty, &.{ a, amount });
            },
        };
        return e.op1(sop, ty, &.{ a, b });
    }

    fn glslSet(e: *Emitter) Id {
        if (e.glsl == 0) e.glsl = e.b.newId();
        return e.glsl;
    }

    /// The module variable of ray tracing storage class `sc` holding values
    /// of type `ty` (one per pair; outgoing payloads and callable data get
    /// distinct Locations).
    fn rayVar(e: *Emitter, sc: StorageClass, ty: TypeId) Error!Id {
        const v = e.ray_vars.get(.{ sc, ty }) orelse blk: {
            const v = e.b.newId();
            try e.b.emit(.types_globals, .variable, &.{ try e.pointerType(sc, try e.typeId(ty)), v, @backingInt(sc) });
            if (sc == .ray_payload_khr or sc == .callable_data_khr) {
                const gop = try e.ray_locations.getOrPut(e.arena, sc);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                try e.b.emit(.annotations, .decorate, &.{ v, 30, gop.value_ptr.* }); // Location
                gop.value_ptr.* += 1;
            }
            const name = switch (sc) {
                .incoming_ray_payload_khr => "payload",
                .hit_attribute_khr => "attributes",
                .incoming_callable_data_khr => "callable.data",
                .ray_payload_khr => "ray.payload",
                .callable_data_khr => "callable.param",
                else => "ray.var",
            };
            try e.b.emitWithString(.debug_names, .name, &.{v}, name, &.{});
            try e.ray_vars.put(e.arena, .{ sc, ty }, v);
            break :blk v;
        };
        try e.useVar(v);
        return v;
    }

    /// An Input variable for a builtin the code reads (created once).
    fn builtinInput(e: *Emitter, builtin: u32, ty: TypeId) Error!Id {
        if (e.builtin_inputs.get(builtin)) |v| {
            try e.useVar(v);
            return v;
        }
        const v = e.b.newId();
        try e.b.emit(.types_globals, .variable, &.{ try e.pointerType(.input, try e.typeId(ty)), v, @backingInt(StorageClass.input) });
        try e.b.emit(.annotations, .decorate, &.{ v, 11, builtin }); // BuiltIn
        var et = ty;
        while (e.t.get(et) == .array) et = e.t.get(et).array.elem;
        const c = e.t.component(et).?;
        if (e.entry.stage == .pixel and !c.isFloat() and c != .bool) try e.b.emit(.annotations, .decorate, &.{ v, 14 }); // Flat
        // Values that change during a ray tracing invocation (from SPIR-V
        // 1.6 such reads need Volatile, as in dxc).
        const changing = switch (builtin) {
            36, 41, 4416...4420 => e.entry.stage.isRayTracing(),
            5326 => e.entry.stage == .intersection,
            else => false,
        };
        if (changing and e.spv_minor >= 6) try e.b.emit(.annotations, .decorate, &.{ v, 21 }); // Volatile
        try e.useVar(v);
        try e.builtin_inputs.put(e.arena, builtin, v);
        return v;
    }

    /// Wave and quad intrinsics as GroupNonUniform operations (SPIR-V 1.3).
    fn waveIntrinsic(e: *Emitter, name: []const u8, ty: TypeId, args: []const Ref) Error!?Id {
        const eq = std.mem.eql;
        if (e.spv_minor < 3) return e.unsupported("'{s}' needs a Vulkan 1.1 target (-fspv-target-env=vulkan1.1)", .{name});
        try e.cap(.group_non_uniform);
        const scope = try e.constUint(3); // Subgroup
        const uint_ty = try e.t.scalar(.uint);
        const bool_ty = try e.t.scalar(.bool);
        if (eq(u8, name, "WaveGetLaneIndex") or eq(u8, name, "WaveGetLaneCount")) {
            const v = try e.builtinInput(if (eq(u8, name, "WaveGetLaneIndex")) 41 else 36, uint_ty); // SubgroupLocalInvocationId / SubgroupSize
            return try e.op1(.load, uint_ty, &.{v});
        }
        if (eq(u8, name, "WaveIsFirstLane")) return try e.op1(.group_non_uniform_elect, bool_ty, &.{scope});
        if (eq(u8, name, "WaveActiveAnyTrue") or eq(u8, name, "WaveActiveAllTrue")) {
            try e.cap(.group_non_uniform_vote);
            return try e.op1(if (eq(u8, name, "WaveActiveAnyTrue")) .group_non_uniform_any else .group_non_uniform_all, bool_ty, &.{ scope, e.val(args[0]) });
        }
        const uvec4 = try e.t.vector(.uint, 4);
        if (eq(u8, name, "WaveActiveBallot")) {
            try e.cap(.group_non_uniform_ballot);
            return try e.op1(.group_non_uniform_ballot, uvec4, &.{ scope, e.val(args[0]) });
        }
        if (eq(u8, name, "WaveActiveCountBits") or eq(u8, name, "WavePrefixCountBits")) {
            try e.cap(.group_non_uniform_ballot);
            const ballot = try e.op1(.group_non_uniform_ballot, uvec4, &.{ scope, e.val(args[0]) });
            return try e.op1(.group_non_uniform_ballot_bit_count, uint_ty, &.{ scope, if (eq(u8, name, "WaveActiveCountBits")) 0 else 2, ballot });
        }
        if (eq(u8, name, "WaveActiveAllEqual")) {
            // Per component (the HLSL result is a bool per component).
            try e.cap(.group_non_uniform_vote);
            const xty = e.f.inst(args[0]).ty;
            const n = e.t.componentCount(xty).?;
            if (n == 1) return try e.op1(.group_non_uniform_all_equal, bool_ty, &.{ scope, e.val(args[0]) });
            const parts = try e.arena.alloc(Id, n);
            for (parts, 0..) |*p, k| p.* = try e.op1(.group_non_uniform_all_equal, bool_ty, &.{ scope, (try e.flatComponent(e.val(args[0]), xty, @intCast(k)))[0] });
            return try e.composeFlat(ty, parts);
        }
        if (eq(u8, name, "WaveReadLaneFirst")) {
            try e.cap(.group_non_uniform_ballot);
            return try e.op1(.group_non_uniform_broadcast_first, ty, &.{ scope, e.val(args[0]) });
        }
        if (eq(u8, name, "WaveReadLaneAt")) {
            // Broadcast needs a constant lane before SPIR-V 1.5; Shuffle
            // takes any.
            const lane = try e.convert(e.val(args[1]), e.f.inst(args[1]).ty, uint_ty);
            if ((try e.constValue(args[1])) != null or e.spv_minor >= 5) {
                try e.cap(.group_non_uniform_ballot);
                return try e.op1(.group_non_uniform_broadcast, ty, &.{ scope, e.val(args[0]), lane });
            }
            try e.cap(.group_non_uniform_shuffle);
            return try e.op1(.group_non_uniform_shuffle, ty, &.{ scope, e.val(args[0]), lane });
        }
        if (eq(u8, name, "QuadReadAcrossX") or eq(u8, name, "QuadReadAcrossY") or eq(u8, name, "QuadReadAcrossDiagonal")) {
            try e.cap(.group_non_uniform_quad);
            const dir: u32 = if (eq(u8, name, "QuadReadAcrossX")) 0 else if (eq(u8, name, "QuadReadAcrossY")) 1 else 2;
            return try e.op1(.group_non_uniform_quad_swap, ty, &.{ scope, e.val(args[0]), try e.constUint(dir) });
        }
        if (eq(u8, name, "QuadReadLaneAt")) {
            try e.cap(.group_non_uniform_quad);
            return try e.op1(.group_non_uniform_quad_broadcast, ty, &.{ scope, e.val(args[0]), try e.convert(e.val(args[1]), e.f.inst(args[1]).ty, uint_ty) });
        }
        // Reductions (Reduce) and prefix scans (ExclusiveScan).
        const c = e.t.component(ty) orelse return null;
        const fl = c.isFloat();
        const un = c.isUnsigned();
        const Red = struct { name: []const u8, op: Op, scan: u32 };
        const reds = [_]Red{
            .{ .name = "WaveActiveSum", .op = if (fl) .group_non_uniform_f_add else .group_non_uniform_i_add, .scan = 0 },
            .{ .name = "WaveActiveProduct", .op = if (fl) .group_non_uniform_f_mul else .group_non_uniform_i_mul, .scan = 0 },
            .{ .name = "WaveActiveMin", .op = if (fl) .group_non_uniform_f_min else if (un) .group_non_uniform_u_min else .group_non_uniform_s_min, .scan = 0 },
            .{ .name = "WaveActiveMax", .op = if (fl) .group_non_uniform_f_max else if (un) .group_non_uniform_u_max else .group_non_uniform_s_max, .scan = 0 },
            .{ .name = "WaveActiveBitAnd", .op = .group_non_uniform_bitwise_and, .scan = 0 },
            .{ .name = "WaveActiveBitOr", .op = .group_non_uniform_bitwise_or, .scan = 0 },
            .{ .name = "WaveActiveBitXor", .op = .group_non_uniform_bitwise_xor, .scan = 0 },
            .{ .name = "WavePrefixSum", .op = if (fl) .group_non_uniform_f_add else .group_non_uniform_i_add, .scan = 2 },
            .{ .name = "WavePrefixProduct", .op = if (fl) .group_non_uniform_f_mul else .group_non_uniform_i_mul, .scan = 2 },
        };
        for (reds) |r| if (eq(u8, name, r.name)) {
            try e.cap(.group_non_uniform_arithmetic);
            return try e.op1(r.op, ty, &.{ scope, r.scan, e.val(args[0]) });
        };
        return null;
    }

    /// Intrinsics with out parameters (null for the others).
    fn outIntrinsic(e: *Emitter, name: []const u8, ty: TypeId, args: []const Ref) Error!?Id {
        const eq = std.mem.eql;
        const xty = if (args.len > 0) e.f.inst(args[0]).ty else ty;
        if (eq(u8, name, "sincos") or eq(u8, name, "modf") or eq(u8, name, "frexp")) {
            // Matrices go row by row; each piece gives two results.
            const m = e.isTrueMatrix(xty);
            const nrows: u32 = if (m) e.t.get(xty).matrix.rows else 1;
            const pty = if (m) try e.t.vector(e.t.get(xty).matrix.elem, e.t.get(xty).matrix.cols) else xty;
            const first = try e.arena.alloc(Id, nrows);
            const second = try e.arena.alloc(Id, nrows);
            const n = e.t.componentCount(pty).?;
            const ity = if (n == 1) try e.t.scalar(.int) else try e.t.vector(.int, @intCast(n));
            for (first, second, 0..) |*a, *b, k| {
                const x = if (m) try e.row(e.val(args[0]), pty, @intCast(k)) else e.val(args[0]);
                if (eq(u8, name, "sincos")) {
                    a.* = try e.op1(.ext_inst, pty, &.{ e.glslSet(), 13, x });
                    b.* = try e.op1(.ext_inst, pty, &.{ e.glslSet(), 14, x });
                    continue;
                }
                // ModfStruct {fraction, whole}; FrexpStruct {mantissa, exponent}.
                const is_modf = eq(u8, name, "modf");
                const st = e.b.newId();
                try e.b.emit(.types_globals, .type_struct, &.{ st, try e.typeId(pty), try e.typeId(if (is_modf) pty else ity) });
                const r = try e.opRaw(.ext_inst, st, &.{ e.glslSet(), if (is_modf) 36 else 52, x });
                a.* = try e.op1(.composite_extract, pty, &.{ r, 0 });
                b.* = if (is_modf) try e.op1(.composite_extract, pty, &.{ r, 1 }) else try e.convert(try e.op1(.composite_extract, ity, &.{ r, 1 }), ity, pty);
            }
            const join = struct {
                fn f(em: *Emitter, parts: []const Id, is_m: bool, t: TypeId) Error!Id {
                    return if (is_m) em.op1(.composite_construct, t, parts) else parts[0];
                }
            }.f;
            const av = try join(e, first, m, xty);
            const bv = try join(e, second, m, xty);
            if (eq(u8, name, "sincos")) {
                try e.b.emit(.functions, .store, &.{ e.val(args[1]), av });
                try e.b.emit(.functions, .store, &.{ e.val(args[2]), bv });
                return 0;
            }
            try e.b.emit(.functions, .store, &.{ e.val(args[1]), try e.convert(bv, xty, e.f.inst(args[1]).ty) });
            return av;
        }
        if (std.mem.startsWith(u8, name, "Interlocked")) {
            const dest = e.f.inst(args[0]);
            const scope: u32 = if (dest.ptr == .groupshared) 2 else 1; // Workgroup / Device
            var ptr = e.val(args[0]);
            if (e.texel_places.get(args[0].index())) |tp| {
                const s_ = try e.texelScalar(e.resourceInfo(tp.res).elem);
                ptr = try e.opRaw(.image_texel_pointer, try e.pointerType(.image, try e.scalarType(s_)), &.{ e.val(tp.res), e.val(tp.coord), try e.constUint(0) });
            }
            return try e.atomicOp(name["Interlocked".len..], ptr, dest.ty, scope, args[1..]);
        }
        if (eq(u8, name, "asuint") and args.len == 3) {
            const n = e.t.componentCount(xty).?;
            if (n != 1) return e.unsupported("asuint of double vectors is not supported yet", .{});
            const pair = try e.op1(.bitcast, try e.t.vector(.uint, 2), &.{e.val(args[0])});
            const u = try e.t.scalar(.uint);
            try e.b.emit(.functions, .store, &.{ e.val(args[1]), try e.op1(.composite_extract, u, &.{ pair, 0 }) });
            try e.b.emit(.functions, .store, &.{ e.val(args[2]), try e.op1(.composite_extract, u, &.{ pair, 1 }) });
            return 0;
        }
        return null;
    }

    /// An atomic on `ptr` (to a `dty` scalar); `rest` holds the value(s)
    /// and, last, the optional out original.
    fn atomicOp(e: *Emitter, op_name: []const u8, ptr: Id, dty: TypeId, scope: u32, rest: []const Ref) Error!Id {
        const eq = std.mem.eql;
        const dc = e.t.component(dty) orelse return e.unsupported("atomics on this destination are not supported yet", .{});
        if (dc.isFloat()) return e.unsupported("float atomics are not supported yet", .{});
        if (dc.size() == 8) try e.cap(.int64_atomics);
        const is_cmp = std.mem.startsWith(u8, op_name, "Compare");
        const asDest = struct {
            fn f(em: *Emitter, r: Ref, t: TypeId) Error!Id {
                return em.convert(em.val(r), em.f.inst(r).ty, t);
            }
        }.f;
        const scope_id = try e.constUint(scope);
        const sem = try e.constUint(0);
        var orig: Id = undefined;
        var n_in: usize = 1;
        if (is_cmp) {
            n_in = 2;
            orig = try e.op1(.atomic_compare_exchange, dty, &.{ ptr, scope_id, sem, sem, try asDest(e, rest[1], dty), try asDest(e, rest[0], dty) });
        } else {
            const op: Op = if (eq(u8, op_name, "Add")) .atomic_i_add else if (eq(u8, op_name, "And")) .atomic_and else if (eq(u8, op_name, "Or")) .atomic_or else if (eq(u8, op_name, "Xor")) .atomic_xor else if (eq(u8, op_name, "Min")) (if (dc.isUnsigned()) .atomic_u_min else .atomic_s_min) else if (eq(u8, op_name, "Max")) (if (dc.isUnsigned()) .atomic_u_max else .atomic_s_max) else if (eq(u8, op_name, "Exchange")) .atomic_exchange else return e.unsupported("'Interlocked{s}' is not supported yet", .{op_name});
            orig = try e.op1(op, dty, &.{ ptr, scope_id, sem, try asDest(e, rest[0], dty) });
        }
        const has_orig = if (is_cmp) eq(u8, op_name, "CompareExchange") else rest.len > n_in;
        if (has_orig) {
            const out = rest[rest.len - 1];
            try e.b.emit(.functions, .store, &.{ e.val(out), try e.convert(orig, dty, e.f.inst(out).ty) });
        }
        return 0;
    }

    fn intrinsic(e: *Emitter, name: []const u8, ty: TypeId, args: []const Ref) Error!Id {
        if (try e.outIntrinsic(name, ty, args)) |id| return id;
        if (std.mem.startsWith(u8, name, "Wave") or std.mem.startsWith(u8, name, "Quad")) {
            if (try e.waveIntrinsic(name, ty, args)) |id| return id;
        }
        if (std.mem.eql(u8, name, "NonUniformResourceIndex")) {
            // A decorated copy marks the index (as dxc).
            const id = try e.op1(.copy_object, ty, &.{e.val(args[0])});
            try e.cap(.shader_non_uniform);
            try e.extension("SPV_EXT_descriptor_indexing");
            try e.b.emit(.annotations, .decorate, &.{ id, 5300 }); // NonUniform
            try e.nonuniform_ids.put(e.arena, id, {});
            return id;
        }
        const ids = try e.arena.alloc(u32, args.len);
        const tys = try e.arena.alloc(TypeId, args.len);
        for (args, ids, tys) |a, *id, *t| {
            id.* = e.val(a);
            t.* = e.f.inst(a).ty;
        }
        // Component-wise intrinsics on matrices apply row by row (GLSL
        // instructions take scalars and vectors).
        const whole = [_][]const u8{ "mul", "transpose", "determinant", "any", "all", "length", "dot", "clip" };
        const component_wise = for (whole) |w| {
            if (std.mem.eql(u8, w, name)) break false;
        } else true;
        var any_matrix = e.isTrueMatrix(ty);
        for (tys) |t| any_matrix = any_matrix or e.isTrueMatrix(t);
        if (component_wise and any_matrix) {
            const shape_ty = if (e.isTrueMatrix(ty)) ty else for (tys) |t| {
                if (e.isTrueMatrix(t)) break t;
            } else ty;
            const m = e.t.get(shape_ty).matrix;
            const rows = try e.arena.alloc(u32, m.rows);
            const row_ids = try e.arena.alloc(u32, args.len);
            const row_tys = try e.arena.alloc(TypeId, args.len);
            const rty = try e.t.vector(e.t.component(ty).?, m.cols);
            for (rows, 0..) |*rw, k| {
                for (tys, ids, row_ids, row_tys) |t, id, *rid, *rt| {
                    if (e.isTrueMatrix(t)) {
                        rt.* = try e.t.vector(e.t.component(t).?, m.cols);
                        rid.* = try e.row(id, rt.*, @intCast(k));
                    } else {
                        rt.* = t;
                        rid.* = id;
                    }
                }
                rw.* = try e.intrinsicOn(name, if (e.isTrueMatrix(ty)) rty else ty, row_ids, row_tys);
            }
            if (!e.isTrueMatrix(ty)) return rows[0];
            return e.op1(.composite_construct, ty, rows);
        }
        return e.intrinsicOn(name, ty, ids, tys);
    }

    fn intrinsicOn(e: *Emitter, name: []const u8, ty: TypeId, ids: []const u32, tys: []const TypeId) Error!Id {
        const args = tys; // count and types only
        const arg_c = if (args.len > 0) e.compOf(tys[0]) else e.compOf(ty);
        const fl = arg_c.isFloat();
        const un = arg_c.isUnsigned();
        const Glsl = struct { name: []const u8, f: u32, s: u32 = 0, u: u32 = 0 };
        const glsl_ops = [_]Glsl{
            .{ .name = "round", .f = 2 },                  .{ .name = "trunc", .f = 3 },                  .{ .name = "abs", .f = 4, .s = 5, .u = 5 },
            .{ .name = "sign", .f = 6, .s = 7 },           .{ .name = "floor", .f = 8 },                  .{ .name = "ceil", .f = 9 },
            .{ .name = "frac", .f = 10 },                  .{ .name = "radians", .f = 11 },               .{ .name = "degrees", .f = 12 },
            .{ .name = "sin", .f = 13 },                   .{ .name = "cos", .f = 14 },                   .{ .name = "tan", .f = 15 },
            .{ .name = "asin", .f = 16 },                  .{ .name = "acos", .f = 17 },                  .{ .name = "atan", .f = 18 },
            .{ .name = "sinh", .f = 19 },                  .{ .name = "cosh", .f = 20 },                  .{ .name = "tanh", .f = 21 },
            .{ .name = "atan2", .f = 25 },                 .{ .name = "pow", .f = 26 },                   .{ .name = "exp", .f = 27 },
            .{ .name = "log", .f = 28 },                   .{ .name = "exp2", .f = 29 },                  .{ .name = "log2", .f = 30 },
            .{ .name = "sqrt", .f = 31 },                  .{ .name = "rsqrt", .f = 32 },                 .{ .name = "determinant", .f = 33 },
            .{ .name = "min", .f = 37, .s = 39, .u = 38 }, .{ .name = "max", .f = 40, .s = 42, .u = 41 }, .{ .name = "clamp", .f = 43, .s = 45, .u = 44 },
            .{ .name = "lerp", .f = 46 },                  .{ .name = "step", .f = 48 },                  .{ .name = "smoothstep", .f = 49 },
            .{ .name = "mad", .f = 50 },                   .{ .name = "ldexp", .f = 53 },                 .{ .name = "length", .f = 66 },
            .{ .name = "distance", .f = 67 },              .{ .name = "cross", .f = 68 },                 .{ .name = "normalize", .f = 69 },
            .{ .name = "faceforward", .f = 70 },           .{ .name = "reflect", .f = 71 },               .{ .name = "refract", .f = 72 },
        };
        const eqn = std.mem.eql;
        if (eqn(u8, name, "sign")) {
            // HLSL sign returns int; GLSL's FSign / SSign keep the type.
            const at = tys[0];
            const s = try e.op1(.ext_inst, at, &.{ e.glslSet(), if (fl) 6 else 7, ids[0] });
            return e.convert(s, at, ty);
        }
        if ((eqn(u8, name, "countbits") or eqn(u8, name, "reversebits") or eqn(u8, name, "ddx") or eqn(u8, name, "ddy") or eqn(u8, name, "fwidth") or eqn(u8, name, "ddx_coarse") or eqn(u8, name, "ddy_coarse")) and arg_c.size() != 4) {
            return e.unsupported("intrinsic '{s}' on {d}-bit types is not supported yet", .{ name, arg_c.size() * 8 });
        }
        if (eqn(u8, name, "ldexp")) {
            // x * exp2(e) (HLSL's exponent is a float).
            const p = try e.op1(.ext_inst, ty, &.{ e.glslSet(), 29, ids[1] });
            return e.binary(.mul, ty, ids[0], p);
        }
        for (glsl_ops) |g| if (std.mem.eql(u8, g.name, name)) {
            if (std.mem.eql(u8, name, "mad") and !fl) {
                const p = try e.op1(.i_mul, ty, &.{ ids[0], ids[1] });
                return e.op1(.i_add, ty, &.{ p, ids[2] });
            }
            const op = if (fl) g.f else if (un) g.u else g.s;
            if (op == 0) break;
            var ops: std.ArrayList(u32) = .empty;
            try ops.appendSlice(e.arena, &.{ e.glslSet(), op });
            try ops.appendSlice(e.arena, ids);
            return e.op1(.ext_inst, ty, ops.items);
        };
        if (eqn(u8, name, "mul") and args.len == 2) return e.mul(ty, tys[0], tys[1], ids[0], ids[1]);
        if (eqn(u8, name, "transpose")) {
            const at = tys[0];
            if (e.isTrueMatrix(at) and e.compOf(at).isFloat()) return e.op1(.transpose, ty, ids);
            const as = e.t.shape(at).?;
            const comps = try e.arena.alloc(Id, as.count());
            for (0..as.cols) |c| for (0..as.rows) |r| {
                comps[c * as.rows + r] = try e.elementAt(ids[0], at, @intCast(r), @intCast(c));
            };
            return e.fromScalars(ty, comps);
        }
        if (std.mem.eql(u8, name, "saturate")) {
            const zero = try e.splatConst(ty, .{ .float = 0 });
            const one = try e.splatConst(ty, .{ .float = 1 });
            return e.op1(.ext_inst, ty, &.{ e.glslSet(), 43, ids[0], zero, one });
        }
        if (std.mem.eql(u8, name, "dot") and fl) {
            // 1-vectors are SPIR-V scalars.
            if (e.isScalarLike(tys[0]) or e.isScalarLike(tys[1])) return e.op1(.f_mul, ty, &.{ try e.convert(ids[0], tys[0], ty), try e.convert(ids[1], tys[1], ty) });
            return e.op1(.dot, ty, ids);
        }
        const deriv = for ([_][]const u8{ "ddx", "ddy", "ddx_coarse", "ddy_coarse", "ddx_fine", "ddy_fine", "fwidth" }) |d| {
            if (eqn(u8, name, d)) break true;
        } else false;
        if (deriv) try e.checkDerivatives();
        if (eqn(u8, name, "ddx_fine") or eqn(u8, name, "ddy_fine")) {
            try e.cap(.derivative_control);
            return e.op1(if (eqn(u8, name, "ddx_fine")) .dpdx_fine else .dpdy_fine, ty, ids);
        }
        if (std.mem.eql(u8, name, "ddx") or std.mem.eql(u8, name, "ddx_coarse")) return e.op1(.dpdx, ty, ids);
        if (std.mem.eql(u8, name, "ddy") or std.mem.eql(u8, name, "ddy_coarse")) return e.op1(.dpdy, ty, ids);
        if (std.mem.eql(u8, name, "fwidth")) return e.op1(.fwidth, ty, ids);
        if (std.mem.eql(u8, name, "asuint") or std.mem.eql(u8, name, "asint") or std.mem.eql(u8, name, "asfloat")) {
            if (args.len == 1) return e.op1(.bitcast, ty, ids);
        }
        if (std.mem.eql(u8, name, "countbits")) return e.op1(.bit_count, ty, ids);
        if (std.mem.eql(u8, name, "reversebits")) return e.op1(.bit_reverse, ty, ids);
        if (std.mem.eql(u8, name, "rcp")) {
            const one = try e.splatConst(ty, .{ .float = 1 });
            return e.op1(.f_div, ty, &.{ one, ids[0] });
        }
        // Barriers: (scope, semantics) as dxc: AcquireRelease with
        // workgroup memory (Group), uniform and image memory (Device) or
        // all three (All).
        const barriers = [_]struct { []const u8, u32, u32, bool }{
            .{ "GroupMemoryBarrierWithGroupSync", 2, 0x108, true },  .{ "GroupMemoryBarrier", 2, 0x108, false },
            .{ "DeviceMemoryBarrierWithGroupSync", 1, 0x848, true }, .{ "DeviceMemoryBarrier", 1, 0x848, false },
            .{ "AllMemoryBarrierWithGroupSync", 1, 0x948, true },    .{ "AllMemoryBarrier", 1, 0x948, false },
        };
        for (barriers) |b| if (eqn(u8, name, b[0])) {
            if (b[3]) {
                try e.b.emit(.functions, .control_barrier, &.{ try e.constUint(2), try e.constUint(b[1]), try e.constUint(b[2]) });
            } else try e.b.emit(.functions, .memory_barrier, &.{ try e.constUint(b[1]), try e.constUint(b[2]) });
            return 0;
        };
        const bool_ty = try e.t.withComponent(ty, .bool);
        if (eqn(u8, name, "any") or eqn(u8, name, "all")) {
            const is_any = eqn(u8, name, "any");
            const at = tys[0];
            if (e.isTrueMatrix(at)) {
                // Row by row, combined.
                const m = e.t.get(at).matrix;
                const rt = try e.t.vector(m.elem, m.cols);
                var acc: ?Id = null;
                for (0..m.rows) |r| {
                    const v = try e.intrinsicOn(name, ty, &.{try e.row(ids[0], rt, @intCast(r))}, &.{rt});
                    acc = if (acc) |a| try e.op1(if (is_any) .logical_or else .logical_and, ty, &.{ a, v }) else v;
                }
                return acc.?;
            }
            const b = if (e.compOf(at) == .bool) ids[0] else try e.convert(ids[0], at, try e.t.withComponent(at, .bool));
            if (e.isScalarLike(at)) return b;
            return e.op1(if (is_any) .any else .all, ty, &.{b});
        }
        if (eqn(u8, name, "and") or eqn(u8, name, "or")) {
            const x = try e.convert(ids[0], tys[0], bool_ty);
            const y = try e.convert(ids[1], tys[1], bool_ty);
            return e.op1(if (eqn(u8, name, "and")) .logical_and else .logical_or, ty, &.{ x, y });
        }
        if (eqn(u8, name, "select") and ids.len == 3) {
            var c = try e.convert(ids[0], tys[0], try e.t.withComponent(tys[0], .bool));
            // A scalar condition over vectors: splatted (before SPIR-V 1.4).
            if (e.isScalarLike(tys[0]) and !e.isScalarLike(ty)) {
                const n = e.t.componentCount(ty).?;
                const copies = try e.arena.alloc(Id, n);
                @memset(copies, c);
                c = try e.op1(.composite_construct, try e.t.withComponent(ty, .bool), copies);
            }
            return e.op1(.select, ty, &.{ c, try e.convert(ids[1], tys[1], ty), try e.convert(ids[2], tys[2], ty) });
        }
        if (eqn(u8, name, "isnan")) return e.op1(.is_nan, ty, ids);
        if (eqn(u8, name, "isinf")) return e.op1(.is_inf, ty, ids);
        if (eqn(u8, name, "isfinite") or eqn(u8, name, "isnormal")) {
            const nan = try e.op1(.is_nan, ty, ids);
            const inf = try e.op1(.is_inf, ty, ids);
            var r = try e.op1(.logical_not, ty, &.{try e.op1(.logical_or, ty, &.{ nan, inf })});
            if (eqn(u8, name, "isnormal")) {
                // Not zero or subnormal either.
                const at = tys[0];
                const min_normal: f64 = switch (e.compOf(at)) {
                    .float16 => 6.103515625e-05,
                    .double => 2.2250738585072014e-308,
                    else => 1.1754943508222875e-38,
                };
                const abs = try e.op1(.ext_inst, at, &.{ e.glslSet(), 4, ids[0] });
                const big = try e.op1(.f_ord_greater_than_equal, ty, &.{ abs, try e.splatConst(at, .{ .float = min_normal }) });
                r = try e.op1(.logical_and, ty, &.{ r, big });
            }
            return r;
        }
        if (eqn(u8, name, "fmod")) return e.op1(.f_rem, ty, ids);
        if (eqn(u8, name, "firstbitlow")) return e.op1(.ext_inst, ty, &.{ e.glslSet(), 73, ids[0] }); // FindILsb
        if (eqn(u8, name, "firstbithigh")) return e.op1(.ext_inst, ty, &.{ e.glslSet(), if (e.compOf(tys[0]).isUnsigned()) 75 else 74, ids[0] }); // FindUMsb / FindSMsb
        if (eqn(u8, name, "f32tof16") or eqn(u8, name, "f16tof32")) {
            // PackHalf2x16 / UnpackHalf2x16, a component at a time.
            const to16 = eqn(u8, name, "f32tof16");
            const n = e.t.componentCount(ty).?;
            const parts = try e.arena.alloc(Id, n);
            const ft = try e.t.scalar(.float);
            const ut = try e.t.scalar(.uint);
            for (parts, 0..) |*p, k| {
                const x = if (n == 1) ids[0] else try e.op1(.composite_extract, if (to16) ft else ut, &.{ ids[0], @intCast(k) });
                if (to16) {
                    const pair = try e.op1(.composite_construct, try e.t.vector(.float, 2), &.{ x, try e.constant(ft, .{ .float = 0 }) });
                    p.* = try e.op1(.ext_inst, ut, &.{ e.glslSet(), 58, pair });
                } else {
                    const pair = try e.op1(.ext_inst, try e.t.vector(.float, 2), &.{ e.glslSet(), 62, x });
                    p.* = try e.op1(.composite_extract, ft, &.{ pair, 0 });
                }
            }
            return if (n == 1) parts[0] else e.op1(.composite_construct, ty, parts);
        }
        if (eqn(u8, name, "dot") and !fl) {
            // Integer dot product: the sum of the products.
            const n = e.t.componentCount(tys[0]).?;
            const st = try e.t.scalar(arg_c);
            var acc: ?Id = null;
            for (0..n) |k| {
                const x = if (n == 1) ids[0] else try e.op1(.composite_extract, st, &.{ ids[0], @intCast(k) });
                const y = if (n == 1) ids[1] else try e.op1(.composite_extract, st, &.{ ids[1], @intCast(k) });
                const p = try e.op1(.i_mul, st, &.{ x, y });
                acc = if (acc) |s0| try e.op1(.i_add, st, &.{ s0, p }) else p;
            }
            return acc.?;
        }
        if (eqn(u8, name, "CheckAccessFullyMapped")) {
            try e.cap(.sparse_residency);
            const code = try e.op1(.bitcast, try e.t.scalar(.int), &.{ids[0]});
            return e.op1(.image_sparse_texels_resident, ty, &.{code});
        }
        if (eqn(u8, name, "IsHelperLane")) return e.op1(.load, ty, &.{try e.builtinInput(23, try e.t.scalar(.bool))}); // HelperInvocation
        if (eqn(u8, name, "clip")) {
            // Discard when any component is negative.
            const at = tys[0];
            const bt = try e.t.scalar(.bool);
            const c = if (e.isTrueMatrix(at)) blk: {
                const m = e.t.get(at).matrix;
                const rt = try e.t.vector(m.elem, m.cols);
                var acc: ?Id = null;
                for (0..m.rows) |r| {
                    const neg = try e.op1(.f_ord_less_than, try e.t.withComponent(rt, .bool), &.{ try e.row(ids[0], rt, @intCast(r)), try e.splatConst(rt, .{ .float = 0 }) });
                    const v = try e.op1(.any, bt, &.{neg});
                    acc = if (acc) |a| try e.op1(.logical_or, bt, &.{ a, v }) else v;
                }
                break :blk acc.?;
            } else blk: {
                const neg = try e.op1(.f_ord_less_than, try e.t.withComponent(at, .bool), &.{ ids[0], try e.splatConst(at, .{ .float = 0 }) });
                break :blk if (e.isScalarLike(at)) neg else try e.op1(.any, bt, &.{neg});
            };
            const kill_l = e.b.newId();
            const merge_l = e.b.newId();
            try e.b.emit(.functions, .selection_merge, &.{ merge_l, 0 });
            try e.b.emit(.functions, .branch_conditional, &.{ c, kill_l, merge_l });
            try e.b.emit(.functions, .label, &.{kill_l});
            try e.b.emit(.functions, .kill, &.{});
            try e.b.emit(.functions, .label, &.{merge_l});
            return 0;
        }
        return e.unsupported("intrinsic '{s}' is not supported yet", .{name});
    }
};

/// Blocks in an order where each block follows its dominators: reverse
/// post-order from the entry, then merge / continue targets that are not
/// reachable (they must still exist).
fn blockOrder(a: Allocator, f: *const ir.Function) Allocator.Error![]u32 {
    const n = f.blocks.items.len;
    const seen = try a.alloc(bool, n);
    @memset(seen, false);
    var post: std.ArrayList(u32) = .empty;
    try dfs(a, f, 0, seen, &post);
    var order: std.ArrayList(u32) = .empty;
    var i = post.items.len;
    while (i > 0) {
        i -= 1;
        try order.append(a, post.items[i]);
    }
    // Unreachable merge / continue targets.
    var changed = true;
    while (changed) {
        changed = false;
        for (order.items) |bi| {
            const targets: [2]ir.BlockId = switch (f.blocks.items[bi].merge) {
                .none => .{ .none, .none },
                .selection => |m| .{ m, .none },
                .loop => |l| .{ l.merge, l.@"continue" },
            };
            for (targets) |t| if (t != .none and !seen[t.index()]) {
                var extra: std.ArrayList(u32) = .empty;
                try dfs(a, f, t.index(), seen, &extra);
                var j = extra.items.len;
                while (j > 0) {
                    j -= 1;
                    try order.append(a, extra.items[j]);
                }
                changed = true;
                break;
            };
            if (changed) break;
        }
    }
    return order.items;
}

fn dfs(a: Allocator, f: *const ir.Function, b: u32, seen: []bool, post: *std.ArrayList(u32)) Allocator.Error!void {
    seen[b] = true;
    const blk = f.blocks.items[b];
    var succ: std.ArrayList(u32) = .empty;
    switch (blk.term) {
        .br => |t| try succ.append(a, t.index()),
        .cond_br => |c| try succ.appendSlice(a, &.{ c.then.index(), c.@"else".index() }),
        .@"switch" => |sw| {
            try succ.append(a, sw.default.index());
            for (sw.cases) |c| try succ.append(a, c.block.index());
        },
        else => {},
    }
    for (succ.items) |s| if (!seen[s]) try dfs(a, f, s, seen, post);
    try post.append(a, b);
}

fn isRayQuery(t: *TypeTable, ty: TypeId) bool {
    return switch (t.get(ty)) {
        .resource => |r| r.kind == .other and std.mem.eql(u8, r.name, "RayQuery"),
        else => false,
    };
}

/// Resources and samplers (not RayQuery objects, which are function
/// storage passed by pointer).
fn isResourceType(t: *TypeTable, ty: TypeId) bool {
    return switch (t.get(ty)) {
        .resource => !isRayQuery(t, ty),
        .sampler => true,
        .array => |a| isResourceType(t, a.elem),
        else => false,
    };
}
