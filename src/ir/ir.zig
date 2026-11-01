//! zdxc IR: typed values in a control-flow graph that keeps its structure
//! (selection and loop headers name their merge and continue blocks), shared
//! by the DXIL and SPIR-V backends.
//!
//! Lowering produces memory form: locals and parameters live in `local_var`
//! storage accessed by `load` / `store`, as dxc's SPIR-V backend emits them.
//! Functions and calls are kept (SPIR-V wants real functions); the DXIL
//! backend inlines, promotes memory to SSA values and scalarizes.
//!
//! Value types are Sema's TypeTable ids (scalars, vectors, matrices,
//! arrays, structs, resources). A value whose `ptr` space is not `.none` is
//! a pointer to storage of that type.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../sema/types.zig");

pub const TypeId = types.TypeId;
pub const TypeTable = types.TypeTable;

/// An instruction result within a function.
pub const Ref = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn index(r: Ref) u32 {
        return @backingInt(r);
    }
};

pub const BlockId = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn index(b: BlockId) u32 {
        return @backingInt(b);
    }
};

/// Where a pointer points.
pub const Space = enum { none, function, private, groupshared, resource, input, output, cbuffer, mesh, ray };

/// Ray tracing shader storage an entry receives: the incoming payload,
/// the hit attributes and the incoming callable data.
pub const RayIncoming = enum { payload, attributes, callable };

pub const BinaryOp = enum {
    add,
    sub,
    mul,
    div,
    rem,
    shl,
    shr,
    bit_and,
    bit_or,
    bit_xor,
    log_and,
    log_or,
};

pub const CmpOp = enum { eq, ne, lt, le, gt, ge };

pub const UnaryOp = enum { neg, not, bit_not };

pub const Constant = union(enum) {
    /// Integer or bool bits, sign-extended for signed types.
    int: i64,
    float: f64,
};

pub const Op = union(enum) {
    /// A scalar constant (or a vector of one constant, splatted).
    constant: Constant,
    /// The function's `n`th parameter (a pointer for out / inout).
    param: u32,
    /// Pointer to a module global (resource, groupshared, static).
    global: u32,
    /// Function-local storage of the result type (result is a pointer).
    local_var,
    load: Ref,
    store: struct { ptr: Ref, value: Ref },
    /// Pointer to a member / element of the storage `base` points at.
    access: struct { base: Ref, indices: []const Ref },
    binary: struct { op: BinaryOp, lhs: Ref, rhs: Ref },
    unary: struct { op: UnaryOp, operand: Ref },
    cmp: struct { op: CmpOp, lhs: Ref, rhs: Ref },
    /// Component-wise numeric conversion to the result type (same shape).
    convert: Ref,
    /// Bit reinterpretation (asuint, asfloat, ...).
    bitcast: Ref,
    /// Scalar replicated to the result vector / matrix.
    splat: Ref,
    /// Constant component / member / element.
    extract: struct { agg: Ref, index: u32 },
    insert: struct { agg: Ref, value: Ref, index: u32 },
    /// Vector / matrix / struct / array from its components.
    construct: []const Ref,
    /// Vector components picked by index (swizzles, truncation).
    shuffle: struct { vec: Ref, components: []const u8 },
    select: struct { cond: Ref, t: Ref, f: Ref },
    call: struct { func: u32, args: []const Ref },
    /// A math / bit / derivative intrinsic by HLSL name (`sqrt`, `mad`, ...).
    intrinsic: struct { name: []const u8, args: []const Ref },
    /// `resource[index]` read and write (structured / typed / raw buffers,
    /// textures).
    res_load: struct { res: Ref, index: Ref },
    res_store: struct { res: Ref, index: Ref, value: Ref },
    /// A builtin method call on a resource (`Load`, `Sample`, ...).
    method: struct { name: []const u8, res: Ref, args: []const Ref },
    /// An entry-point input / output element (index into the entry's
    /// signature).
    input: u32,
    /// A per-vertex input (geometry shaders): element, vertex index.
    input_vertex: struct { element: u32, vertex: u32 },
    output: struct { element: u32, value: Ref },
    /// Hull / domain shaders: a patch constant read (domain) or written
    /// (hull patch constant function), and a hull output control point
    /// read back by the patch constant function.
    patch_input: u32,
    /// Mesh shaders: an output array (a pointer in the `mesh` space; stores
    /// through it write vertices, primitives or indices), and the payload
    /// from the amplification shader.
    mesh_output: MeshOutput,
    mesh_payload,
    /// `ResourceDescriptorHeap[index]` / `SamplerDescriptorHeap[index]`
    /// as a resource of the instruction's type.
    heap_resource: struct { index: Ref, sampler: bool },
    /// Ray tracing entries: pointer (`ray` space) to the storage of an
    /// incoming value of the instruction's type.
    ray_incoming: RayIncoming,
    /// SPIR-V specialization constant (index into Module.spec_constants).
    spec_constant: u32,
    /// Inline SPIR-V (`[[vk::ext_instruction]]` functions): an instruction
    /// of `set` (null: core), with the capabilities and extensions it needs.
    spirv_inst: *const SpirvInst,
    patch_output: struct { element: u32, value: Ref },
    output_vertex: struct { element: u32, vertex: u32 },
    /// Geometry shaders: emit the vertex written to the outputs of a stream,
    /// or end its strip.
    emit: u32,
    cut: u32,
    phi: []const struct { value: Ref, block: BlockId },
};

pub const Inst = struct {
    op: Op,
    ty: TypeId,
    /// Non-`none` when the result is a pointer to `ty` storage.
    ptr: Space = .none,
};

pub const Terminator = union(enum) {
    /// Not yet terminated (lowering in progress).
    none,
    ret: Ref,
    br: BlockId,
    cond_br: struct { cond: Ref, then: BlockId, @"else": BlockId },
    @"switch": struct { value: Ref, default: BlockId, cases: []const struct { value: i64, block: BlockId } },
    /// After `discard`, or where control cannot reach.
    @"unreachable",
    discard,
};

/// Structured control flow: a header block names where its construct
/// merges and (for loops) where iterations continue.
pub const Merge = union(enum) {
    none,
    selection: BlockId,
    loop: struct { merge: BlockId, @"continue": BlockId, unroll: Unroll = .auto },
};

/// `[unroll]` / `[loop]` on a loop.
pub const Unroll = enum { auto, unroll, dont };

pub const Block = struct {
    insts: std.ArrayList(Ref) = .empty,
    term: Terminator = .none,
    merge: Merge = .none,
};

pub const Param = struct {
    name: []const u8,
    ty: TypeId,
    /// out / inout: passed as a pointer to caller storage.
    by_ref: bool,
    /// `groupshared` parameters: a pointer to the caller's groupshared
    /// variable (by_ref too).
    groupshared: bool = false,
    /// in, out, inout (library function annotations).
    dir: enum { in, out, inout } = .in,
    /// The HLSL type (before patches become arrays), for mangled names.
    sema_ty: TypeId = 0,
    semantic: ?[]const u8 = null,
};

pub const Function = struct {
    name: []const u8,
    params: []const Param,
    ret: TypeId,
    /// The entry (index into `Module.entries`) the function was lowered
    /// for first.
    entry: u32 = 0,
    ret_semantic: ?[]const u8 = null,
    /// Declaration order of the HLSL function (libraries define functions
    /// in this order).
    decl_order: u32 = std.math.maxInt(u32),
    insts: std.ArrayList(Inst) = .empty,
    blocks: std.ArrayList(Block) = .empty,

    pub fn inst(f: *const Function, r: Ref) Inst {
        return f.insts.items[r.index()];
    }

    pub fn block(f: *Function, b: BlockId) *Block {
        return &f.blocks.items[b.index()];
    }
};

pub const Binding = struct {
    /// Register class: 'b', 't', 'u', 's' (0: none given).
    class: u8 = 0,
    index: u32 = 0,
    space: u32 = 0,
    explicit: bool = false,
    /// `spaceN` was written.
    space_given: bool = false,
};

/// Vulkan binding options (-fvk-*-shift, -fvk-bind-globals,
/// -auto-binding-space).
pub const VkOptions = struct {
    /// Per register class (b, t, s, u): shifts by set; `all` applies to
    /// every set without one of its own.
    shifts: [4]std.ArrayList(struct { shift: u32, set: ?u32 }) = .{ .empty, .empty, .empty, .empty },
    bind_globals: ?[2]u32 = null,
    auto_binding_space: u32 = 0,
    /// -fvk-auto-shift-bindings: implicit bindings start at their class's
    /// shift too.
    auto_shift: bool = false,
    /// -fvk-stage-io-order=alpha: locations by semantic, not declaration.
    alpha_io_order: bool = false,
    /// -fvk-use-gl-layout, -fvk-use-dx-layout, -fvk-use-scalar-layout.
    layout: enum { default, gl, dx, scalar } = .default,
    /// -fspv-entrypoint-name=, -fspv-enable-maximal-reconvergence,
    /// -fvk-support-nonzero-base-instance / -vertex,
    /// -fspv-use-unknown-image-format.
    entry_name: ?[]const u8 = null,
    /// -fspv-reflect: SPV_GOOGLE semantic / user type / counter
    /// decorations.
    reflect: bool = false,
    /// -fspv-extension=: the only extensions allowed (empty: any).
    extensions: std.ArrayList([]const u8) = .empty,
    maximal_reconvergence: bool = false,
    nonzero_base_instance: bool = false,
    nonzero_base_vertex: bool = false,
    unknown_image_format: bool = false,
    /// -fvk-invert-y, -fvk-use-dx-position-w.
    invert_y: bool = false,
    dx_position_w: bool = false,
    /// -fspv-flatten-resource-arrays: one variable (and binding) per
    /// element of an array of resources.
    flatten_arrays: bool = false,
    /// -fspv-use-legacy-buffer-matrix-order: byte-address buffer matrices
    /// are row major (dxc's old, incorrect assumption).
    legacy_matrix_order: bool = false,
    /// -fspv-use-vulkan-memory-model.
    vulkan_memory_model: bool = false,
    /// -fvk-bind-register: every resource's (set, binding) by register.
    bind_register: std.ArrayList(struct { class: u8, index: u32, space: u32, binding: u32, set: u32 }) = .empty,

    pub fn shift(o: VkOptions, class: u8, set: u32) u32 {
        const k: usize = switch (class) {
            'b' => 0,
            't' => 1,
            's' => 2,
            'u' => 3,
            else => return 0,
        };
        var all: u32 = 0;
        for (o.shifts[k].items) |x| {
            if (x.set) |s0| {
                if (s0 == set) return x.shift;
            } else all = x.shift;
        }
        return all;
    }
};

/// A descriptor declaration, in declaration order: SPIR-V numbers implicit
/// bindings over all of them, used or not (as dxc).
pub const BindingDecl = struct {
    /// The IR global (null: unused; it still takes a binding number).
    global: ?u32,
    reg: Binding = .{},
    /// `register(spaceN)` without a register.
    space_only: bool = false,
    /// [[vk::binding(binding, set)]], [[vk::counter_binding(binding)]].
    vk_binding: ?u32 = null,
    vk_set: ?u32 = null,
    vk_counter: ?u32 = null,
    /// Append / Consume buffers: their counter is numbered right after.
    acs: bool = false,
    /// `$Globals`.
    globals_buffer: bool = false,
    /// [[vk::combinedImageSampler]]: `s` registers shift like `t` ones.
    combined: bool = false,
    /// Resources in the declaration (array elements).
    count: u32 = 1,
};

pub const Global = struct {
    name: []const u8,
    ty: TypeId,
    space: Space,
    binding: Binding = .{},
    /// A `tbuffer` block (space `cbuffer`): a texture buffer with the
    /// constant buffer layout.
    tbuffer: bool = false,
    /// `[[vk::shader_record_ext]]` / `[[vk::shader_record_nv]]` buffers
    /// (SPIR-V ShaderRecordBufferKHR storage).
    shader_record: bool = false,
    /// `[[vk::push_constant]]` buffers (SPIR-V PushConstant storage).
    push_constant: bool = false,
    /// [[vk::input_attachment_index(n)]] (SubpassInput).
    input_attachment: ?u32 = null,
    /// [[vk::image_format("...")]]: the SPIR-V ImageFormat.
    image_format: ?u32 = null,
    /// `globallycoherent` resources.
    globally_coherent: bool = false,
    ext: SpirvExt = .{},
};

pub const Stage = enum {
    vertex,
    pixel,
    geometry,
    hull,
    domain,
    compute,
    mesh,
    amplification,
    library,
    raygeneration,
    intersection,
    anyhit,
    closesthit,
    miss,
    callable,

    pub fn isRayTracing(s: Stage) bool {
        return @backingInt(s) >= @backingInt(Stage.raygeneration);
    }
};

/// One entry-point input or output (a semantic on a parameter, field or
/// the return value).
pub const SigElement = struct {
    semantic: []const u8,
    semantic_index: u32,
    ty: TypeId,
    system_value: bool,
    interp: types.Interp = .{},
    /// Matrices in the element are row_major (signature layout only).
    row_major: bool = false,
    /// Geometry shader output stream.
    stream: u32 = 0,
    /// One value per vertex of the input primitive (geometry shaders).
    per_vertex: bool = false,
    /// The semantic as written (`TEXCOORD`, `TEXCOORD3`).
    spelling: ?[]const u8 = null,
    /// [[vk::location(n)]], [[vk::index(n)]], [[vk::builtin("...")]].
    vk_location: ?u32 = null,
    vk_index: ?u32 = null,
    vk_builtin: ?[]const u8 = null,
    ext_decorations: []const ExtDecoration = &.{},
};

pub const Primitive = enum(u8) { point = 1, line = 2, triangle = 3, line_adj = 6, triangle_adj = 7 };

pub const GeometryInfo = struct {
    input: Primitive = .triangle,
    /// Vertices per input primitive.
    input_vertices: u32 = 3,
    max_vertex_count: u32 = 1,
    instance_count: u32 = 1,
    /// Output topology per stream (null: stream unused).
    streams: [4]?enum { point, line, triangle } = .{ null, null, null, null },
};

pub const Domain = enum(u8) { isoline = 1, tri = 2, quad = 3 };
pub const Partitioning = enum(u8) { integer = 1, pow2 = 2, fractional_odd = 3, fractional_even = 4 };
pub const OutputTopology = enum(u8) { point = 1, line = 2, triangle_cw = 3, triangle_ccw = 4 };

pub const MeshOutput = enum { vertices, primitives, indices };

pub const MeshInfo = struct {
    max_vertices: u32 = 0,
    max_primitives: u32 = 0,
    /// DXIL::MeshOutputTopology.
    topology: enum(u8) { line = 1, triangle = 2 } = .triangle,
    /// The payload struct (read by a mesh shader, sent by an amplification
    /// shader's DispatchMesh).
    payload: ?TypeId = null,
};

pub const TessInfo = struct {
    domain: Domain = .tri,
    partitioning: Partitioning = .integer,
    output_topology: OutputTopology = .triangle_cw,
    /// Control points per input patch (hull: InputPatch; domain:
    /// OutputPatch).
    input_control_points: u32 = 0,
    output_control_points: u32 = 0,
    max_tess_factor: f32 = 64,
};

pub const Entry = struct {
    /// The function the entry wraps (the HLSL entry, in memory form).
    func: u32,
    name: []const u8,
    stage: Stage,
    num_threads: [3]u32 = .{ 1, 1, 1 },
    geometry: GeometryInfo = .{},
    tess: TessInfo = .{},
    mesh: MeshInfo = .{},
    inputs: std.ArrayList(SigElement) = .empty,
    outputs: std.ArrayList(SigElement) = .empty,
    /// Patch constants: written by the hull shader's patch constant
    /// function, read by the domain shader.
    patch_constants: std.ArrayList(SigElement) = .empty,
    /// Hull shaders: the wrapper of the patch constant function (no
    /// parameters; reads inputs and output control points, writes patch
    /// constants).
    patch_wrapper: ?u32 = null,
    /// The HLSL patch constant function.
    patch_func: ?u32 = null,
    /// `[RootSignature("...")]`: the root signature text.
    root_signature: ?[]const u8 = null,
    /// Inline SPIR-V capabilities / extensions of the entry function.
    ext: SpirvExt = .{},
    /// The wrapper with no parameters that reads `inputs`, calls `func`
    /// and writes `outputs`.
    wrapper: u32 = 0,
};

/// `[[vk::ext_decorate(...)]]`, `ext_decorate_id`, `ext_decorate_string`.
pub const ExtDecoration = struct {
    decoration: u32,
    kind: enum { literal, id, string },
    /// Literal words, or the constants for `id`.
    ints: []const u32 = &.{},
    strings: []const []const u8 = &.{},
};

/// Inline SPIR-V attributes of a declaration.
pub const SpirvExt = struct {
    decorations: []const ExtDecoration = &.{},
    capabilities: []const u32 = &.{},
    extensions: []const []const u8 = &.{},
    /// `[[vk::ext_builtin_input(n)]]` / `ext_builtin_output(n)`.
    builtin: ?u32 = null,
    builtin_output: bool = false,
    /// `[[vk::ext_storage_class(n)]]`.
    storage_class: ?u32 = null,
};

pub const SpirvInst = struct {
    opcode: u32,
    set: ?[]const u8 = null,
    /// Values, pointers (`[[vk::ext_reference]]`) or literal words.
    operands: []const union(enum) { value: Ref, literal: u32, type: TypeId },
    capabilities: []const u32 = &.{},
    extensions: []const []const u8 = &.{},
};

/// A ray tracing state object subobject (DXIL::SubobjectKind values).
pub const Subobject = struct {
    name: []const u8,
    kind: Kind,
    /// Flags, sizes, depths and hit group type, by kind.
    ints: [2]u32 = .{ 0, 0 },
    /// Hit group shaders (any hit, closest hit, intersection); the
    /// associated subobject; root signature text.
    strings: [3][]const u8 = .{ "", "", "" },
    /// Associations: the exports.
    exports: []const []const u8 = &.{},

    pub const Kind = enum(u32) {
        state_object_config = 0,
        global_root_signature = 1,
        local_root_signature = 2,
        subobject_to_exports_association = 8,
        raytracing_shader_config = 9,
        raytracing_pipeline_config = 10,
        hit_group = 11,
        raytracing_pipeline_config1 = 12,
    };
};

pub const Module = struct {
    arena: Allocator,
    types: *TypeTable,
    globals: std.ArrayList(Global) = .empty,
    /// By pointer: lowering appends callees while building a caller.
    functions: std.ArrayList(*Function) = .empty,
    /// Entry points (one, or a library's shaders in declaration order).
    entries: std.ArrayList(Entry) = .empty,
    /// Libraries: functions exported by name (`export`).
    exports: std.ArrayList(u32) = .empty,
    /// Libraries: state object subobjects, in declaration order.
    subobjects: std.ArrayList(Subobject) = .empty,
    /// [[vk::constant_id(n)]] constants (SPIR-V).
    spec_constants: std.ArrayList(struct { name: []const u8, ty: TypeId, id: u32, value: Constant }) = .empty,
    /// Descriptor declarations in declaration order.
    binding_decls: std.ArrayList(BindingDecl) = .empty,
    vk: VkOptions = .{},
    /// A global struct holds resources (dxc's SPIR-V then numbers array
    /// elements' bindings separately, as with -fspv-flatten-resource-arrays).
    resource_structs: bool = false,
    /// -enable-16bit-types: half and 16-bit integers are native types.
    native_16bit: bool = false,
    /// Root signatures: version 1.0 or 1.1 (-force-rootsig-ver), and
    /// -Qstrip_rootsignature.
    rootsig_version: enum { v1_0, v1_1 } = .v1_1,
    strip_rootsig: bool = false,

    pub fn addFunction(m: *Module, f: Function) !u32 {
        const p = try m.arena.create(Function);
        p.* = f;
        try m.functions.append(m.arena, p);
        return @intCast(m.functions.items.len - 1);
    }
};

/// Appends instructions to a function at a current block.
pub const Builder = struct {
    m: *Module,
    f: *Function,
    cur: BlockId = .none,

    pub fn newBlock(b: *Builder) !BlockId {
        try b.f.blocks.append(b.m.arena, .{});
        return @fromBackingInt(@intCast(b.f.blocks.items.len - 1));
    }

    pub fn setBlock(b: *Builder, blk: BlockId) void {
        b.cur = blk;
    }

    /// The current block is still open (no terminator yet).
    pub fn open(b: *Builder) bool {
        return b.cur != .none and b.f.block(b.cur).term == .none;
    }

    pub fn add(b: *Builder, inst: Inst) !Ref {
        try b.f.insts.append(b.m.arena, inst);
        const r: Ref = @fromBackingInt(@intCast(b.f.insts.items.len - 1));
        // Instructions after a terminator (dead code) go to a fresh block.
        if (!b.open()) b.cur = try b.newBlock();
        try b.f.block(b.cur).insts.append(b.m.arena, r);
        return r;
    }

    pub fn terminate(b: *Builder, t: Terminator) void {
        if (!b.open()) return;
        b.f.block(b.cur).term = t;
    }

    pub fn constInt(b: *Builder, ty: TypeId, v: i64) !Ref {
        return b.add(.{ .op = .{ .constant = .{ .int = v } }, .ty = ty });
    }

    pub fn constFloat(b: *Builder, ty: TypeId, v: f64) !Ref {
        return b.add(.{ .op = .{ .constant = .{ .float = v } }, .ty = ty });
    }

    pub fn load(b: *Builder, ptr: Ref) !Ref {
        const p = b.f.inst(ptr);
        return b.add(.{ .op = .{ .load = ptr }, .ty = p.ty });
    }

    pub fn store(b: *Builder, ptr: Ref, value: Ref) !void {
        _ = try b.add(.{ .op = .{ .store = .{ .ptr = ptr, .value = value } }, .ty = TypeTable.void_type });
    }
};

/// Prints a module in a readable text form (for `-zdxc-ir` and tests).
pub fn dump(m: *const Module, w: *std.Io.Writer) !void {
    for (m.globals.items, 0..) |g, i| {
        try w.print("global @{d} {s}: {s} {s}", .{ i, g.name, @tagName(g.space), try m.types.format(m.arena, g.ty) });
        if (g.binding.class != 0) try w.print(" : register({c}{d}, space{d})", .{ g.binding.class, g.binding.index, g.binding.space });
        try w.writeByte('\n');
    }
    for (m.functions.items, 0..) |f, fi| {
        try w.print("fn @{d} {s}(", .{ fi, f.name });
        for (f.params, 0..) |p, i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("{s}{s}: {s}", .{ if (p.by_ref) "ref " else "", p.name, try m.types.format(m.arena, p.ty) });
        }
        try w.print(") -> {s} {{\n", .{try m.types.format(m.arena, f.ret)});
        for (f.blocks.items, 0..) |blk, bi| {
            try w.print("b{d}:", .{bi});
            switch (blk.merge) {
                .none => {},
                .selection => |mb| try w.print("  ; selection merge b{d}", .{mb.index()}),
                .loop => |l| try w.print("  ; loop merge b{d} continue b{d}", .{ l.merge.index(), l.@"continue".index() }),
            }
            try w.writeByte('\n');
            for (blk.insts.items) |r| try dumpInst(m, f, r, w);
            try w.writeAll("  ");
            switch (blk.term) {
                .none => try w.writeAll("<open>"),
                .ret => |v| if (v == .none) try w.writeAll("ret") else try w.print("ret %{d}", .{v.index()}),
                .br => |t| try w.print("br b{d}", .{t.index()}),
                .cond_br => |c| try w.print("br %{d}, b{d}, b{d}", .{ c.cond.index(), c.then.index(), c.@"else".index() }),
                .@"switch" => |sw| {
                    try w.print("switch %{d} default b{d}", .{ sw.value.index(), sw.default.index() });
                    for (sw.cases) |c| try w.print(", {d}: b{d}", .{ c.value, c.block.index() });
                },
                .@"unreachable" => try w.writeAll("unreachable"),
                .discard => try w.writeAll("discard"),
            }
            try w.writeByte('\n');
        }
        try w.writeAll("}\n");
    }
}

fn dumpInst(m: *const Module, f: *const Function, r: Ref, w: *std.Io.Writer) !void {
    const inst = f.inst(r);
    try w.writeAll("  ");
    if (inst.ty != TypeTable.void_type) {
        try w.print("%{d}: {s}{s} = ", .{ r.index(), if (inst.ptr != .none) "*" else "", try m.types.format(m.arena, inst.ty) });
    }
    switch (inst.op) {
        .constant => |c| switch (c) {
            .int => |v| try w.print("const {d}", .{v}),
            .float => |v| try w.print("const {d}", .{v}),
        },
        .param => |p| try w.print("param {d}", .{p}),
        .global => |g| try w.print("global @{d}", .{g}),
        .local_var => try w.writeAll("local_var"),
        .load => |p| try w.print("load %{d}", .{p.index()}),
        .store => |s| try w.print("store %{d}, %{d}", .{ s.ptr.index(), s.value.index() }),
        .access => |a| {
            try w.print("access %{d}", .{a.base.index()});
            for (a.indices) |i| try w.print(", %{d}", .{i.index()});
        },
        .binary => |b| try w.print("{s} %{d}, %{d}", .{ @tagName(b.op), b.lhs.index(), b.rhs.index() }),
        .unary => |u| try w.print("{s} %{d}", .{ @tagName(u.op), u.operand.index() }),
        .cmp => |c| try w.print("cmp.{s} %{d}, %{d}", .{ @tagName(c.op), c.lhs.index(), c.rhs.index() }),
        .convert => |x| try w.print("convert %{d}", .{x.index()}),
        .bitcast => |x| try w.print("bitcast %{d}", .{x.index()}),
        .splat => |x| try w.print("splat %{d}", .{x.index()}),
        .extract => |x| try w.print("extract %{d}, {d}", .{ x.agg.index(), x.index }),
        .insert => |x| try w.print("insert %{d}, %{d}, {d}", .{ x.agg.index(), x.value.index(), x.index }),
        .construct => |xs| {
            try w.writeAll("construct");
            for (xs, 0..) |x, i| try w.print("{s} %{d}", .{ if (i > 0) "," else "", x.index() });
        },
        .shuffle => |s| {
            try w.print("shuffle %{d}", .{s.vec.index()});
            for (s.components) |c| try w.print(", {d}", .{c});
        },
        .select => |s| try w.print("select %{d}, %{d}, %{d}", .{ s.cond.index(), s.t.index(), s.f.index() }),
        .call => |c| {
            try w.print("call @{d}", .{c.func});
            for (c.args) |a| try w.print(", %{d}", .{a.index()});
        },
        .intrinsic => |c| {
            try w.print("{s}", .{c.name});
            for (c.args, 0..) |a, i| try w.print("{s} %{d}", .{ if (i > 0) "," else "", a.index() });
        },
        .input_vertex => |x| try w.print("input {d} vertex {d}", .{ x.element, x.vertex }),
        .emit => |k| try w.print("emit stream {d}", .{k}),
        .patch_input => |k| try w.print("patch input {d}", .{k}),
        .mesh_output => |k| try w.print("mesh output {s}", .{@tagName(k)}),
        .mesh_payload => try w.print("mesh payload", .{}),
        .ray_incoming => |k| try w.print("ray incoming {s}", .{@tagName(k)}),
        .spec_constant => |k| try w.print("spec constant {d}", .{k}),
        .spirv_inst => |x| try w.print("spirv op {d}", .{x.opcode}),
        .heap_resource => |h| try w.print("{s}[%{d}]", .{ if (h.sampler) "SamplerDescriptorHeap" else "ResourceDescriptorHeap", h.index.index() }),
        .patch_output => |x| try w.print("patch output {d} = %{d}", .{ x.element, x.value.index() }),
        .output_vertex => |x| try w.print("output {d} vertex {d}", .{ x.element, x.vertex }),
        .cut => |k| try w.print("cut stream {d}", .{k}),
        .res_load => |x| try w.print("res_load %{d}[%{d}]", .{ x.res.index(), x.index.index() }),
        .res_store => |x| try w.print("res_store %{d}[%{d}], %{d}", .{ x.res.index(), x.index.index(), x.value.index() }),
        .method => |x| {
            try w.print("%{d}.{s}(", .{ x.res.index(), x.name });
            for (x.args, 0..) |a, i| try w.print("{s}%{d}", .{ if (i > 0) ", " else "", a.index() });
            try w.writeByte(')');
        },
        .input => |i| try w.print("input {d}", .{i}),
        .output => |o| try w.print("output {d}, %{d}", .{ o.element, o.value.index() }),
        .phi => |ins| {
            try w.writeAll("phi");
            for (ins, 0..) |in, i| try w.print("{s} [%{d}, b{d}]", .{ if (i > 0) "," else "", in.value.index(), in.block.index() });
        },
    }
    try w.writeByte('\n');
}
