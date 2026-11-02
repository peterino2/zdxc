//! IR -> DXIL. Everything is inlined into the entry function while
//! emitting (each call instantiates its callee); values are scalarized
//! (DXIL has no vectors); locals become flattened `[N x scalar]` allocas;
//! resources become handles created on entry. The result is a signed DXIL
//! container.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("../ir/ir.zig");
const types = @import("../sema/types.zig");
const diag = @import("../diag.zig");
const module = @import("module.zig");
const shader = @import("shader.zig");
const container = @import("container.zig");
const hash = @import("hash.zig");
const layout = @import("../ir/layout.zig");
const signature = @import("signature.zig");
const texture = @import("../ir/texture.zig");
const mangle = @import("mangle.zig");
const rdat = @import("rdat.zig");
const linalg_info = @import("linalg_info.zig");
const libinfo = @import("libinfo.zig");
const rootsig = @import("rootsig.zig");

const TypeId = types.TypeId;
const TypeTable = types.TypeTable;
const Scalar = types.Scalar;
const Ref = ir.Ref;
const DType = module.TypeId;
const Value = module.Value;

pub const Error = Allocator.Error || error{Unsupported};

pub fn emit(gpa: Allocator, m: *const ir.Module, profile: shader.Profile, diags: *diag.Diagnostics) Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var e: Emitter = .{ .arena = arena_state.allocator(), .dm = .init(gpa), .m = m, .t = m.types, .profile = profile, .diags = diags };
    defer e.dm.deinit();
    // Native 16-bit types are laid out at their own size.
    if (m.native_16bit) e.dm.datalayout = "e-m:e-p:32:32-i1:32-i8:8-i16:16-i32:32-i64:64-f16:16-f32:32-f64:64-n8:16:32:64";
    return e.run(gpa);
}

/// A lowered IR value.
const Lowered = union(enum) {
    none,
    /// Flattened scalar components.
    scalars: []const Value,
    /// A struct or array value holding resources: its data components
    /// (flattened, resources counting none) and its resources, in order.
    agg: struct { vals: []const Value, res: []const Lowered },
    /// A local holding resources: its data storage (.ptr or .typed; null
    /// when it has no data) and one resource slot (Emitter.res_locals)
    /// per resource, each an alias of what is stored into it.
    agg_ptr: struct { data: ?*const Lowered, slots: []const u32, ty: TypeId },
    ptr: Ptr,
    /// A resource handle (index into Emitter.resources).
    handle: u32,
    /// A local holding a resource (index into Emitter.res_locals): an
    /// alias of the one resource stored into it.
    res_local: u32,
    /// A RayQuery local (index into Emitter.rq_locals) and a query handle.
    rq_local: u32,
    ray_query: Value,
    /// An element of a typed buffer or texture (atomics' destination).
    texel: struct { res: u32, coords: []const Value },
    /// An array of resources (or a sub-array), with the flattened index so
    /// far.
    res_array: struct { res: u32, index: ?Value = null, ty: TypeId },
    /// A place in a constant buffer: byte offset plus a dynamic register
    /// offset.
    cbuf: struct { res: u32, offset: u32 = 0, dyn_regs: ?Value = null, row_major: bool = false },
    /// A place in a mesh shader output array: the vertex / primitive index
    /// and a flattened component offset within it.
    mesh: struct { kind: ir.MeshOutput, index: ?Value = null, offset: u32 = 0, ty: TypeId },
    /// Struct-typed memory (mesh payloads): the base pointer, its pointee
    /// type, the GEP path so far and the HLSL type there.
    typed: struct { base: Value, dty: DType, addr_space: u32, ty: TypeId, path: []const Value = &.{} },
    /// A place inside a structured buffer element: element index plus byte
    /// offset (constant and dynamic).
    buf: struct {
        res: u32,
        index: Value,
        offset: u32 = 0,
        dyn: ?Value = null,
        row_major: bool = false,
        /// A row (and component) of the matrix at the place: read from
        /// the whole matrix (a row need not be contiguous).
        mat: ?struct { ty: TypeId, row: Value, col: ?u32 = null } = null,
    },
};

/// Pointer into a flattened local: alloca `base` of `[n x scalar]`, at
/// component `offset_const` (+ `offset_dyn` if dynamic).
const Ptr = struct {
    base: Value,
    array_ty: DType,
    scalar_ty: DType,
    offset_const: u32 = 0,
    offset_dyn: ?Value = null,
    /// bools are stored as i32.
    bool_storage: bool = false,
    /// Mixed 32-bit component types share i32 storage (floats bitcast).
    mixed: bool = false,
    /// 3 for groupshared memory.
    addr_space: u32 = 0,
};

const Resource = struct {
    global: u32,
    class: Class,
    /// Index within its class (metadata and createHandle range id).
    id: u32 = 0,
    kind: u32,
    handle: Value = undefined,
    elem: TypeId,
    /// SamplerComparisonState.
    comparison: bool = false,
    /// Structured UAV with a hidden counter (IncrementCounter, Append...).
    has_counter: bool = false,
    /// `globallycoherent` UAVs and rasterizer-ordered views.
    coherent: bool = false,
    rov: bool = false,
    /// Registers in the range (arrays of resources); maxInt for unsized.
    count: u32 = 1,
    /// An array element's handle made at its use: a copy of the array's
    /// entry, skipped by metadata. (Descriptor heap resources are views
    /// with no global.)
    view: bool = false,
    /// The resource type (without array dimensions); 0 for cbuffer blocks.
    rty: TypeId = 0,
    /// Libraries: the module global standing for the resource.
    lib_global: ?u32 = null,

    const Class = enum(u8) { srv = 0, uav = 1, cbuffer = 2, sampler = 3 };
};

const Frame = struct {
    f: *const ir.Function,
    vals: []Lowered,
    params: []const Lowered,
    blocks: []?u32,
    /// For inlined calls: where `ret` goes and the incoming return values.
    cont: ?u32 = null,
    rets: std.ArrayList(struct { block: u32, vals: []const Value }) = .empty,
    /// The resources a function returns (every return the same ones).
    ret_res: ?[]const Lowered = null,
};

const PInst = struct { inst: module.Inst, id: u32 };

const Emitter = struct {
    arena: Allocator,
    dm: module.Module,
    m: *const ir.Module,
    t: *TypeTable,
    profile: shader.Profile,
    entry: ir.Entry = undefined,
    diags: *diag.Diagnostics,

    main_fn: u32 = 0,
    /// Hull shaders: the patch constant function.
    pc_fn: ?u32 = null,
    /// Amplification shaders: the variable sent by DispatchMesh (laid out
    /// as a struct, not flattened): a groupshared global or a local.
    payload_global: ?u32 = null,
    payload_local: ?struct { func: *const ir.Function, inst: u32 } = null,
    /// Instructions per block, in creation order, with provisional ids.
    blocks: std.ArrayList(std.ArrayList(PInst)) = .empty,
    prologue: std.ArrayList(PInst) = .empty,
    next_id: u32 = 0,
    cur: u32 = 0,

    resources: std.ArrayList(Resource) = .empty,
    resource_of_global: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    private_globals: std.AutoHashMapUnmanaged(u32, Ptr) = .empty,
    private_typed: std.AutoHashMapUnmanaged(u32, @FieldType(Lowered, "typed")) = .empty,
    res_locals: std.ArrayList(?Lowered) = .empty,
    /// Indices marked with NonUniformResourceIndex.
    nonuniform: std.AutoHashMapUnmanaged(Value, void) = .empty,
    uses_double: bool = false,
    uses_int64: bool = false,
    /// 16-bit min-precision values cross the signature.
    uses_min_precision: bool = false,
    uses_view_id: bool = false,
    uses_wave: bool = false,
    groupshared_bytes: u32 = 0,
    /// A typed UAV load of more than one component.
    uses_typed_uav_load: bool = false,
    uses_inner_coverage: bool = false,
    uses_resource_heap: bool = false,
    uses_extended_command_info: bool = false,
    uses_tiled_resources: bool = false,
    uses_mesh_derivatives: bool = false,
    uses_ray_query: bool = false,
    /// SM 6.10 matrix types used (`!dx.targetTypes`), in first-use order.
    linalg_types: std.ArrayList(struct { ty: TypeId, dty: DType }) = .empty,
    uses_linalg: bool = false,
    /// The resources the last inlined call returned.
    last_ret_res: ?[]const Lowered = null,
    /// RayQuery locals: the query handle (allocated in the prologue on
    /// first use, or a copy of another query) and the query type.
    rq_locals: std.ArrayList(struct { h: ?Value, ty: TypeId }) = .empty,
    /// The ResRet of the last texture operation (for status arguments).
    last_resret: Value = undefined,
    /// Status values, forwarded through locals within a block: the
    /// validator wants CheckAccessFullyMapped's operand to be one.
    status_vals: std.AutoHashMapUnmanaged(Value, void) = .empty,
    forwarded: std.AutoHashMapUnmanaged(struct { Value, u32 }, struct { v: Value, block: u32 }) = .empty,
    uses_barycentrics: bool = false,
    uses_sampler_heap: bool = false,

    sig_in: []signature.Element = &.{},
    sig_out: []signature.Element = &.{},
    /// Patch constants (hull output, domain input).
    sig_pc: []signature.Element = &.{},
    pc_elem: []?u32 = &.{},
    /// IR entry input / output index -> signature element; null for system
    /// values read with an intrinsic instead.
    in_elem: []?u32 = &.{},
    out_elem: []?u32 = &.{},
    /// Rows of an SV_Target array split into one element per row (the
    /// last row's element comes first, as in dxc); 0 if not split.
    out_split: []u32 = &.{},

    handle_ty: DType = 0,

    /// Libraries: each entry is a function of its own; resources are
    /// globals whose handles are made in each function that uses them.
    lib: bool = false,
    /// The current function's arguments (ray tracing payload / attributes).
    lib_args: []const Value = &.{},
    /// Libraries: `[noinline]` functions kept as functions of their own
    /// (IR function -> module function).
    lib_calls: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Each HLSL struct's module type (struct types are named, and two
    /// structs may share a name: `A<int>::In`, `A<float>::In`).
    struct_types: std.AutoHashMapUnmanaged(TypeId, DType) = .empty,
    /// Prologue instructions dropped again if unused (resource handles).
    lib_removable: std.AutoHashMapUnmanaged(u32, void) = .empty,

    fn unsupported(e: *Emitter, comptime fmt: []const u8, args: anytype) Error {
        _ = e.diags.report(.{ .severity = .@"error", .loc = .none }, "DXIL code generation: " ++ fmt, args);
        return error.Unsupported;
    }

    // ------------------------------------------------------------------
    // Instructions

    fn newBlock(e: *Emitter) Error!u32 {
        try e.blocks.append(e.arena, .empty);
        return @intCast(e.blocks.items.len - 1);
    }

    fn add(e: *Emitter, ty: DType, op: @FieldType(module.Inst, "op")) Error!Value {
        const id = e.next_id;
        e.next_id += 1;
        try e.blocks.items[e.cur].append(e.arena, .{ .inst = .{ .ty = ty, .op = op }, .id = id });
        return .{ .inst = id };
    }

    fn addPrologue(e: *Emitter, ty: DType, op: @FieldType(module.Inst, "op")) Error!Value {
        const id = e.next_id;
        e.next_id += 1;
        try e.prologue.append(e.arena, .{ .inst = .{ .ty = ty, .op = op }, .id = id });
        return .{ .inst = id };
    }

    fn voidTy(e: *Emitter) Error!DType {
        return e.dm.getType(.void);
    }

    fn i32Const(e: *Emitter, v: i64) Error!Value {
        return e.dm.constInt(32, v);
    }

    /// The DXIL scalar type of an HLSL scalar (min precision: 32 bits).
    fn scalarTy(e: *Emitter, s: Scalar) Error!DType {
        return switch (s) {
            .bool => e.dm.intType(1),
            .int, .uint, .min16int, .min12int, .min16uint, .literal_int, .int8_4packed, .uint8_4packed => e.dm.intType(32),
            .int16, .uint16 => blk: {
                e.uses_min_precision = true;
                break :blk e.dm.intType(16);
            },
            .int64, .uint64 => blk: {
                e.uses_int64 = true;
                break :blk e.dm.intType(64);
            },
            .float, .half, .min16float, .min10float, .literal_float => e.dm.getType(.float),
            .float16 => blk: {
                e.uses_min_precision = true;
                break :blk e.dm.getType(.half);
            },
            .double => blk: {
                e.uses_double = true;
                break :blk e.dm.getType(.double);
            },
        };
    }

    /// The scalar a component is kept as in struct-typed memory.
    fn memScalar(s: Scalar) Scalar {
        return if (s == .bool) .uint else storageScalar(s);
    }

    fn storageScalar(s: Scalar) Scalar {
        return switch (s) {
            .min16int, .min12int, .literal_int, .int8_4packed => .int,
            .min16uint, .uint8_4packed => .uint,
            .half, .min16float, .min10float, .literal_float => .float,
            else => s,
        };
    }

    fn compOf(e: *Emitter, ty: TypeId) Scalar {
        if (e.t.get(ty) == .array) return e.compOf(e.t.get(ty).array.elem);
        return storageScalar(e.t.component(ty) orelse .int);
    }

    /// Number of flattened scalar components of `ty`.
    fn flatCount(e: *Emitter, ty: TypeId) Error!u32 {
        return switch (e.t.get(ty)) {
            // (A matrix handle is one opaque component; resources are not
            // data.)
            .scalar, .@"enum", .linalg => 1,
            .resource, .sampler => 0,
            .vector => |v| v.len,
            .matrix => |m| @as(u32, m.rows) * m.cols,
            .array => |a| a.len * try e.flatCount(a.elem),
            .@"struct" => |s| blk: {
                var n: u32 = 0;
                for (s.fields.items) |f| n += try e.flatCount(f.type);
                break :blk n;
            },
            else => e.unsupported("values of type '{s}' are not supported yet", .{try e.t.format(e.arena, ty)}),
        };
    }

    /// The single scalar type all components of `ty` share.
    fn uniformScalar(e: *Emitter, ty: TypeId) Error!Scalar {
        return switch (e.t.get(ty)) {
            .scalar, .vector, .matrix, .@"enum" => storageScalar(e.t.component(ty).?),
            .array => |a| e.uniformScalar(a.elem),
            .@"struct" => |s| blk: {
                var first: ?Scalar = null;
                for (s.fields.items) |f| {
                    if (try e.flatCount(f.type) == 0) continue;
                    const c = try e.uniformScalar(f.type);
                    if (first != null and first.? != c) return e.unsupported("structs with mixed component types are not supported yet", .{});
                    first = c;
                }
                break :blk first orelse .int;
            },
            else => e.unsupported("values of type '{s}' are not supported yet", .{try e.t.format(e.arena, ty)}),
        };
    }

    fn dxOp(e: *Emitter, name: []const u8, ret: DType, params: []const DType, attrs: module.FnAttrs) Error!u32 {
        if (e.dm.findFunction(name)) |i| return i;
        const fn_ty = try e.dm.fnType(ret, params);
        return e.dm.addFunction(.{ .name = name, .ty = fn_ty, .attrs = attrs });
    }

    fn overloadName(e: *Emitter, ty: DType) []const u8 {
        return switch (e.dm.types.items[ty]) {
            .half => "f16",
            .float => "f32",
            .double => "f64",
            .int => |w| switch (w) {
                1 => "i1",
                16 => "i16",
                64 => "i64",
                else => "i32",
            },
            else => "i32",
        };
    }

    fn callOp(e: *Emitter, func: u32, ret: DType, args: []const Value) Error!Value {
        return e.add(ret, .{ .call = .{ .callee = func, .args = try e.arena.dupe(Value, args) } });
    }

    // ------------------------------------------------------------------
    // Driver

    fn run(e: *Emitter, gpa: Allocator) Error![]u8 {
        const m = e.m;
        if (e.profile.kind == .library) return e.runLibrary(gpa);
        if (m.entries.items.len != 1) return e.unsupported("several entry points are not supported here", .{});
        const entry = m.entries.items[0];
        e.entry = entry;
        switch (entry.stage) {
            .compute, .vertex, .pixel, .geometry, .hull, .domain, .mesh, .amplification => {},
            else => return e.unsupported("{s} shaders are not supported yet", .{@tagName(entry.stage)}),
        }
        const void_ty = try e.voidTy();
        const fn_ty = try e.dm.fnType(void_ty, &.{});
        e.main_fn = try e.dm.addFunction(.{ .name = entry.name, .ty = fn_ty, .num_blocks = 1 });
        const i8p = try e.dm.ptrType(try e.dm.intType(8));
        e.handle_ty = try e.dm.getType(.{ .@"struct" = .{ .name = "dx.types.Handle", .elems = &.{i8p} } });

        try e.collectResources();
        try e.buildSignatures(entry);
        if (entry.stage == .amplification) e.findDispatchPayload();
        e.cur = try e.newBlock();
        try e.createHandles();
        _ = try e.inlineCall(entry.wrapper, &.{});
        try e.finish(e.main_fn);
        if (entry.patch_wrapper) |pw| {
            // The patch constant function is a function of its own.
            e.blocks = .empty;
            e.prologue = .empty;
            e.next_id = 0;
            e.private_globals = .empty;
            e.private_typed = .empty;
            e.nonuniform = .empty;
            const name = m.functions.items[pw].name;
            e.pc_fn = try e.dm.addFunction(.{ .name = name[0 .. name.len - ".wrapper".len], .ty = fn_ty, .num_blocks = 1 });
            e.cur = try e.newBlock();
            try e.createHandles();
            _ = try e.inlineCall(pw, &.{});
            try e.finish(e.pc_fn.?);
        }

        const bitcode = try e.writeModule(entry);
        defer gpa.free(bitcode);
        return e.assemble(gpa, entry, bitcode);
    }

    /// The resource entry for a value of resource type `ty` (global,
    /// id and count left for the caller).
    fn resourceFor(e: *Emitter, ty: TypeId) Error!Resource {
        if (e.t.get(ty) == .sampler) return .{ .global = 0, .class = .sampler, .kind = 14, .elem = ty, .comparison = e.t.get(ty).sampler.comparison, .rty = ty };
        const r = e.t.get(ty).resource;
        const kind: u32 = switch (r.kind) {
            .structured_buffer, .rw_structured_buffer, .append_structured_buffer, .consume_structured_buffer => 12,
            .byte_address_buffer, .rw_byte_address_buffer => 11,
            .buffer, .rw_buffer => 10,
            .texture1d, .rw_texture1d => 1,
            .texture2d, .rw_texture2d => 2,
            .texture2dms, .rw_texture2dms => 3,
            .texture3d, .rw_texture3d => 4,
            .texture_cube => 5,
            .texture1d_array, .rw_texture1d_array => 6,
            .texture2d_array, .rw_texture2d_array => 7,
            .texture2dms_array, .rw_texture2dms_array => 8,
            .texture_cube_array => 9,
            .constant_buffer => 13,
            .texture_buffer => 15,
            .raytracing_acceleration_structure => 16,
            else => return e.unsupported("resource type '{s}' is not supported yet", .{r.name}),
        };
        const class: Resource.Class = if (kind == 13) .cbuffer else if (r.kind.isWritable() or r.kind == .consume_structured_buffer) .uav else .srv;
        return .{ .global = 0, .class = class, .kind = kind, .elem = r.elem, .rty = ty, .has_counter = r.kind == .append_structured_buffer or r.kind == .consume_structured_buffer, .rov = std.mem.startsWith(u8, r.name, "RasterizerOrdered") };
    }

    // ------------------------------------------------------------------
    // Libraries

    const LibFunc = struct {
        func: u32,
        name: []const u8,
        unmangled: []const u8,
        stage: ir.Stage,
        entry: ir.Entry,
        payload_size: u32 = 0,
        attr_size: u32 = 0,
        /// Function annotation: the return value, then each parameter.
        ann: []const ParamAnn = &.{},
        /// Graphics entries: signatures; entry properties of the stage.
        sigs: ?module.MdId = null,
        stage_props: []const ?module.MdId = &.{},
    };

    /// Input qualifier (0 in, 1 out, 2 inout), component type and
    /// semantic of a library function parameter.
    const ParamAnn = struct { qual: u32, comp: ?i64 = null, semantic: ?[]const u8 = null };

    fn shaderKind(stage: ir.Stage) u32 {
        return switch (stage) {
            .pixel => 0,
            .vertex => 1,
            .geometry => 2,
            .hull => 3,
            .domain => 4,
            .compute => 5,
            .library => 6,
            .raygeneration => 7,
            .intersection => 8,
            .anyhit => 9,
            .closesthit => 10,
            .miss => 11,
            .callable => 12,
            .mesh => 13,
            .amplification => 14,
        };
    }

    fn runLibrary(e: *Emitter, gpa: Allocator) Error![]u8 {
        const m = e.m;
        e.lib = true;
        // Prerelease shader models get experimental RDAT tables.
        if (e.profile.minor >= 11 and m.entries.items.len > 0) return e.unsupported("libraries for prerelease shader models (experimental RDAT) are not supported yet", .{});
        // Prerelease shader models get experimental RDAT tables.
        if (e.profile.minor >= 11 and m.entries.items.len > 0) return e.unsupported("libraries for prerelease shader models (experimental RDAT) are not supported yet", .{});
        const i8p = try e.dm.ptrType(try e.dm.intType(8));
        e.handle_ty = try e.dm.getType(.{ .@"struct" = .{ .name = "dx.types.Handle", .elems = &.{i8p} } });
        try e.collectResources();
        // A global per resource, named as dxc mangles it.
        for (e.resources.items) |*r| {
            if (r.view) continue;
            if (r.count != 1) return e.unsupported("resource arrays in libraries are not supported yet", .{});
            const g = m.globals.items[r.global];
            const ty = try e.classType(r.*);
            const name = if (g.space == .resource) try mangle.global(e.arena, e.t, g.name, g.ty) else g.name;
            const v = try e.dm.addGlobal(name, ty, 0);
            e.dm.globals.items[v.global].constant = true;
            r.lib_global = v.global;
        }
        // Definitions in declaration order (as dxc): create them all first.
        const Unit = struct { order: u32, kind: enum { entry, patch, exported, internal }, index: u32 };
        var units: std.ArrayList(Unit) = .empty;
        for (m.entries.items, 0..) |entry, k| {
            switch (entry.stage) {
                .compute, .raygeneration, .intersection, .anyhit, .closesthit, .miss, .callable, .vertex, .pixel, .geometry, .hull, .domain, .mesh, .amplification => {},
                else => return e.unsupported("{s} shaders in libraries are not supported yet", .{@tagName(entry.stage)}),
            }
            try units.append(e.arena, .{ .order = m.functions.items[entry.func].decl_order, .kind = .entry, .index = @intCast(k) });
            if (entry.patch_func) |pf| try units.append(e.arena, .{ .order = m.functions.items[pf].decl_order, .kind = .patch, .index = @intCast(k) });
        }
        for (m.exports.items, 0..) |fi, k| try units.append(e.arena, .{ .order = m.functions.items[fi].decl_order, .kind = .exported, .index = @intCast(k) });
        for (m.functions.items, 0..) |f, fi| if (e.libCallable(@intCast(fi))) {
            try units.append(e.arena, .{ .order = f.decl_order, .kind = .internal, .index = @intCast(fi) });
        };
        std.sort.insertion(Unit, units.items, {}, struct {
            fn lt(_: void, x: Unit, y: Unit) bool {
                return x.order < y.order;
            }
        }.lt);
        const entry_fn = try e.arena.alloc(u32, m.entries.items.len);
        const patch_fn = try e.arena.alloc(u32, m.entries.items.len);
        const export_fn = try e.arena.alloc(LibFunc, m.exports.items.len);
        var internal_fn: std.ArrayList(struct { u32, LibFunc }) = .empty;
        for (units.items) |u| switch (u.kind) {
            .entry => {
                const entry = m.entries.items[u.index];
                const sig = try e.entrySignature(entry);
                entry_fn[u.index] = try e.dm.addFunction(.{ .name = sig.name, .ty = sig.ty, .num_blocks = 1 });
            },
            .patch => {
                const pf = m.functions.items[m.entries.items[u.index].patch_func.?];
                const mparams = try e.arena.alloc(mangle.Param, pf.params.len);
                for (mparams, pf.params) |*mp, p| mp.* = .{ .ty = p.sema_ty };
                const name = try mangle.function(e.arena, e.t, pf.name, pf.ret, mparams);
                patch_fn[u.index] = try e.dm.addFunction(.{ .name = name, .ty = try e.dm.fnType(try e.voidTy(), &.{}), .num_blocks = 1 });
            },
            .exported => export_fn[u.index] = try e.exportSignature(m.exports.items[u.index], false),
            .internal => {
                const lf = try e.exportSignature(u.index, true);
                try internal_fn.append(e.arena, .{ u.index, lf });
                try e.lib_calls.put(e.arena, u.index, lf.func);
            },
        };

        var funcs: std.ArrayList(LibFunc) = .empty;
        for (m.entries.items, 0..) |entry, k| {
            e.entry = entry;
            e.blocks = .empty;
            e.prologue = .empty;
            e.next_id = 0;
            e.private_globals = .empty;
            e.private_typed = .empty;
            e.nonuniform = .empty;
            e.res_locals = .empty;
            e.rq_locals = .empty;
            e.forwarded = .empty;
            e.status_vals = .empty;
            e.payload_global = null;
            e.payload_local = null;
            e.groupshared_bytes = 0;
            e.sig_in = &.{};
            e.sig_out = &.{};
            e.sig_pc = &.{};
            if (entry.stage == .amplification) e.findDispatchPayload();
            const sig = try e.entrySignature(entry);
            var lf: LibFunc = .{ .func = entry_fn[k], .name = sig.name, .unmangled = entry.name, .stage = entry.stage, .entry = entry, .ann = sig.ann, .payload_size = sig.payload_size, .attr_size = sig.attr_size };
            const args = try e.arena.alloc(Value, sig.nparams);
            for (args, 0..) |*a, j| a.* = .{ .arg = @intCast(j) };
            e.lib_args = args;
            try e.buildSignatures(entry);
            e.cur = try e.newBlock();
            try e.libHandles();
            _ = try e.inlineCall(entry.wrapper, &.{});
            try e.finish(lf.func);
            var pc_func: ?LibFunc = null;
            if (entry.patch_wrapper) |pw| {
                // The patch constant function: a function of its own.
                e.blocks = .empty;
                e.prologue = .empty;
                e.next_id = 0;
                e.private_globals = .empty;
                e.private_typed = .empty;
                e.nonuniform = .empty;
                e.pc_fn = patch_fn[k];
                e.cur = try e.newBlock();
                try e.libHandles();
                _ = try e.inlineCall(pw, &.{});
                try e.finish(e.pc_fn.?);
                const pname = e.dm.functions.items[patch_fn[k]].name;
                pc_func = .{ .func = patch_fn[k], .name = pname, .unmangled = m.functions.items[entry.patch_func.?].name, .stage = .library, .entry = entry, .ann = &.{.{ .qual = 0 }} };
            }
            if (e.sig_in.len + e.sig_out.len + e.sig_pc.len > 0) {
                lf.sigs = try e.dm.mdNode(&.{ try e.signatureMetadata(e.sig_in), try e.signatureMetadata(e.sig_out), try e.signatureMetadata(e.sig_pc) });
            }
            var sp: std.ArrayList(?module.MdId) = .empty;
            try e.stageProps(entry, &sp);
            lf.stage_props = sp.items;
            try funcs.append(e.arena, lf);
            if (pc_func) |pf| try funcs.append(e.arena, pf);
        }
        for (m.exports.items, export_fn) |fi, lf| try funcs.append(e.arena, try e.emitExport(fi, lf));
        for (internal_fn.items) |x| try funcs.append(e.arena, try e.emitExport(x[0], x[1]));
        std.sort.insertion(LibFunc, funcs.items, {}, struct {
            fn lt(_: void, x: LibFunc, y: LibFunc) bool {
                return x.func < y.func;
            }
        }.lt);
        const bitcode = try e.writeLibraryModule(funcs.items);
        defer gpa.free(bitcode);
        return e.assembleLibrary(gpa, funcs.items, bitcode);
    }

    const EntrySig = struct { name: []const u8, ty: DType, ann: []const ParamAnn, nparams: usize, payload_size: u32 = 0, attr_size: u32 = 0 };

    /// A library entry's function: ray tracing shaders take their payload
    /// / attributes by pointer under a mangled name; others take nothing.
    fn entrySignature(e: *Emitter, entry: ir.Entry) Error!EntrySig {
        const hf = e.m.functions.items[entry.func];
        const ray = entry.stage.isRayTracing();
        var params: std.ArrayList(DType) = .empty;
        var mparams: std.ArrayList(mangle.Param) = .empty;
        var ann: std.ArrayList(ParamAnn) = .empty;
        try ann.append(e.arena, .{ .qual = if (ray) 1 else 0 });
        var sig: EntrySig = .{ .name = entry.name, .ty = 0, .ann = &.{}, .nparams = 0 };
        if (ray) for (hf.params, 0..) |p, k| {
            try params.append(e.arena, try e.dm.ptrType(try e.memoryType(p.ty)));
            try mparams.append(e.arena, .{ .ty = p.ty });
            try ann.append(e.arena, .{ .qual = if (p.by_ref) 2 else 0 });
            const size = try e.payloadSize(p.ty);
            if (k == 0) sig.payload_size = size else sig.attr_size = size;
        };
        if (ray) sig.name = try mangle.function(e.arena, e.t, entry.name, TypeTable.void_type, mparams.items);
        sig.ann = ann.items;
        sig.ty = try e.dm.fnType(try e.voidTy(), params.items);
        sig.nparams = params.items.len;
        return sig;
    }

    /// The LLVM type of a library function argument / result: scalars
    /// and vectors.
    fn libValueType(e: *Emitter, ty: TypeId) Error!DType {
        return switch (e.t.get(ty)) {
            .scalar, .@"enum" => e.scalarTy(e.compOf(ty)),
            .vector => |v| if (v.len == 1) e.scalarTy(e.compOf(ty)) else e.dm.getType(.{ .vector = .{ .len = v.len, .elem = try e.scalarTy(e.compOf(ty)) } }),
            else => e.unsupported("exported functions with values of type '{s}' are not supported yet", .{try e.t.format(e.arena, ty)}),
        };
    }

    /// Components of a library argument value (vectors element by
    /// element).
    fn libSplit(e: *Emitter, v: Value, ty: TypeId) Error![]const Value {
        const n = try e.flatCount(ty);
        if (e.t.get(ty) != .vector or n == 1) return e.arena.dupe(Value, &.{v});
        const et = try e.scalarTy(e.compOf(ty));
        const out = try e.arena.alloc(Value, n);
        for (out, 0..) |*o, k| o.* = try e.add(et, .{ .extractelement = .{ .vec = v, .index = try e.i32Const(@intCast(k)) } });
        return out;
    }

    fn libJoin(e: *Emitter, vals: []const Value, ty: TypeId) Error!Value {
        if (e.t.get(ty) != .vector or vals.len == 1) return vals[0];
        const vt = try e.libValueType(ty);
        var v = try e.dm.constant(.{ .ty = vt, .kind = .undef });
        for (vals, 0..) |c, k| v = try e.add(vt, .{ .insertelement = .{ .vec = v, .val = c, .index = try e.dm.constInt(64, @intCast(k)) } });
        return v;
    }

    /// Whether IR function `fi` stays a function of its own in a library:
    /// `[noinline]`, not exported, with values exportSignature can pass
    /// and the validator allows (others are inlined).
    fn libCallable(e: *Emitter, fi: u32) bool {
        const f = e.m.functions.items[fi];
        if (!f.no_inline or std.mem.indexOfScalar(u32, e.m.exports.items, fi) != null) return false;
        for (f.params) |p| {
            if (p.groupshared) return false;
            switch (e.t.get(p.ty)) {
                .scalar, .@"enum", .vector => {},
                // (The validator counts matrix handles as resources, which
                // no signature may hold.)
                .@"struct" => if (e.holdsResources(p.ty) or e.containsLinAlg(p.ty)) return false,
                else => return false,
            }
        }
        return f.ret == TypeTable.void_type or switch (e.t.get(f.ret)) {
            .scalar, .@"enum", .vector => true,
            else => false,
        };
    }

    /// An exported (or, `internal`, a `[noinline]`) function's definition:
    /// scalars and vectors by value, structs and out / inout values by
    /// pointer, under its mangled name.
    fn exportSignature(e: *Emitter, fi: u32, internal: bool) Error!LibFunc {
        const f = e.m.functions.items[fi];
        var params: std.ArrayList(DType) = .empty;
        var mparams: std.ArrayList(mangle.Param) = .empty;
        var ann: std.ArrayList(ParamAnn) = .empty;
        const ret_void = f.ret == TypeTable.void_type;
        if (!internal) {
            // (dxc's check; the validator counts matrix handles as
            // resources too.)
            const holds = struct {
                fn check(em: *Emitter, ty: TypeId) bool {
                    return isResourceType(em.t, ty) or em.holdsResources(ty) or em.containsLinAlg(ty);
                }
            }.check;
            var bad = holds(e, f.ret);
            for (f.params) |p| bad = bad or holds(e, p.ty);
            if (bad) {
                const mps = try e.arena.alloc(mangle.Param, f.params.len);
                for (mps, f.params) |*mp, p| mp.* = .{ .ty = p.ty, .by_ref = p.by_ref };
                _ = e.diags.report(.{ .severity = .@"error", .loc = .none }, "Exported function \\01{s} must not contain a resource in parameter or return type.", .{(try mangle.function(e.arena, e.t, f.name, f.ret, mps))[1..]});
                return error.Unsupported;
            }
        }
        try ann.append(e.arena, .{ .qual = 1, .comp = if (ret_void) null else try e.compType(e.compOf(f.ret)), .semantic = f.ret_semantic });
        for (f.params) |p| {
            // Structs go by pointer.
            const is_struct = e.t.get(p.ty) == .@"struct";
            const vt = if (is_struct) try e.memoryType(p.ty) else try e.libValueType(p.ty);
            try params.append(e.arena, if (p.by_ref or is_struct) try e.dm.ptrType(vt) else vt);
            try mparams.append(e.arena, .{ .ty = p.ty, .by_ref = p.by_ref });
            try ann.append(e.arena, .{ .qual = switch (p.dir) {
                .in => 0,
                .out => 1,
                .inout => 2,
            }, .comp = if (is_struct) null else try e.compType(e.compOf(p.ty)), .semantic = p.semantic });
        }
        const ret_ty = if (ret_void) try e.voidTy() else try e.libValueType(f.ret);
        const name = try mangle.function(e.arena, e.t, f.name, f.ret, mparams.items);
        const func = try e.dm.addFunction(.{ .name = name, .ty = try e.dm.fnType(ret_ty, params.items), .num_blocks = 1, .linkage = if (internal) .internal else .external, .attrs = if (internal) .noinline_nounwind else .none });
        return .{ .func = func, .name = name, .unmangled = f.name, .stage = .library, .entry = undefined, .ann = ann.items };
    }

    /// The body of exported function `fi` (its definition made by
    /// exportSignature).
    fn emitExport(e: *Emitter, fi: u32, lf0: LibFunc) Error!LibFunc {
        const f = e.m.functions.items[fi];
        e.entry = .{ .func = fi, .name = f.name, .stage = .library, .wrapper = std.math.maxInt(u32) };
        e.blocks = .empty;
        e.prologue = .empty;
        e.next_id = 0;
        e.private_globals = .empty;
        e.private_typed = .empty;
        e.nonuniform = .empty;
        e.res_locals = .empty;
        e.rq_locals = .empty;
        e.forwarded = .empty;
        e.status_vals = .empty;
        e.lib_args = &.{};
        const ret_void = f.ret == TypeTable.void_type;
        const func = lf0.func;
        e.cur = try e.newBlock();
        try e.libHandles();
        // Arguments: components, and local copies of out / inout ones.
        const args = try e.arena.alloc(Lowered, f.params.len);
        const copies = try e.arena.alloc(?Ptr, f.params.len);
        for (f.params, args, copies, 0..) |p, *a, *cp, k| {
            const arg: Value = .{ .arg = @intCast(k) };
            if (e.t.get(p.ty) == .@"struct") {
                const tp: @FieldType(Lowered, "typed") = .{ .base = arg, .dty = try e.memoryType(p.ty), .addr_space = 0, .ty = p.ty };
                if (!p.by_ref) {
                    a.* = try e.typedLoad(tp, p.ty);
                    cp.* = null;
                    continue;
                }
                a.* = tp_copy: {
                    const local = try e.alloca(p.ty);
                    try e.storePtr(local, (try e.typedLoad(tp, p.ty)).scalars, p.ty);
                    cp.* = local;
                    break :tp_copy .{ .ptr = local };
                };
                continue;
            }
            if (!p.by_ref) {
                a.* = .{ .scalars = try e.libSplit(arg, p.ty) };
                cp.* = null;
                continue;
            }
            const local = try e.alloca(p.ty);
            const vt = try e.libValueType(p.ty);
            const cur_v = try e.add(vt, .{ .load = .{ .ptr = arg, .@"align" = 4 } });
            try e.storePtr(local, try e.libSplit(cur_v, p.ty), p.ty);
            a.* = .{ .ptr = local };
            cp.* = local;
        }
        const res = try e.inlineCall(fi, args);
        const void_ty = try e.voidTy();
        for (f.params, copies, 0..) |p, cp, k| if (cp) |local| {
            const vals = (try e.loadPtr(local, p.ty)).scalars;
            if (e.t.get(p.ty) == .@"struct") {
                try e.typedStore(.{ .base = .{ .arg = @intCast(k) }, .dty = try e.memoryType(p.ty), .addr_space = 0, .ty = p.ty }, vals, p.ty);
                continue;
            }
            _ = try e.add(void_ty, .{ .store = .{ .ptr = .{ .arg = @intCast(k) }, .val = try e.libJoin(vals, p.ty), .@"align" = 4 } });
        };
        _ = try e.add(void_ty, .{ .ret = if (ret_void) null else try e.libJoin(res, f.ret) });
        try e.finish(func);
        var lf = lf0;
        lf.entry = e.entry;
        return lf;
    }

    /// Handles of the library's resources for the current function (in
    /// the prologue; dropped again where unused).
    fn libHandles(e: *Emitter) Error!void {
        const i32t = try e.dm.intType(32);
        for (e.resources.items) |*res| {
            const lg = res.lib_global orelse continue;
            const gty = e.dm.globals.items[lg].ty;
            const loaded = try e.addPrologue(gty, .{ .load = .{ .ptr = .{ .global = lg }, .@"align" = 4 } });
            try e.lib_removable.put(e.arena, loaded.inst, {});
            const struct_name = e.dm.types.items[gty].@"struct".name;
            const create = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.createHandleForLib.{s}", .{struct_name}), e.handle_ty, &.{ i32t, gty }, .nounwind_readonly);
            var h = try e.addPrologue(e.handle_ty, .{ .call = .{ .callee = create, .args = try e.arena.dupe(Value, &.{ try e.i32Const(160), loaded }) } });
            try e.lib_removable.put(e.arena, h.inst, {});
            if (e.self_sm66()) {
                const props_ty = try e.dm.getType(.{ .@"struct" = .{ .name = "dx.types.ResourceProperties", .elems = &.{ i32t, i32t } } });
                const annotate = try e.dxOp("dx.op.annotateHandle", e.handle_ty, &.{ i32t, e.handle_ty, props_ty }, .nounwind_readnone);
                h = try e.addPrologue(e.handle_ty, .{ .call = .{ .callee = annotate, .args = try e.arena.dupe(Value, &.{ try e.i32Const(216), h, try e.propertiesConst(res.*) }) } });
                try e.lib_removable.put(e.arena, h.inst, {});
            }
            res.handle = h;
        }
    }

    /// Ray tracing intrinsics (library shaders); null for other names.
    fn rayIntrinsic(e: *Emitter, frame: *Frame, name: []const u8, ty: TypeId, args: []const Ref) Error!?Lowered {
        const eq = std.mem.eql;
        const i32t = try e.dm.intType(32);
        const i8t = try e.dm.intType(8);
        const f32t = try e.dm.getType(.float);
        const void_ty = try e.voidTy();
        const Sys = struct { []const u8, i64, []const u8, enum { scalar, vector, m34, m43 } };
        const table = [_]Sys{
            .{ "DispatchRaysIndex", 145, "dispatchRaysIndex", .vector },        .{ "DispatchRaysDimensions", 146, "dispatchRaysDimensions", .vector },
            .{ "WorldRayOrigin", 147, "worldRayOrigin", .vector },             .{ "WorldRayDirection", 148, "worldRayDirection", .vector },
            .{ "ObjectRayOrigin", 149, "objectRayOrigin", .vector },           .{ "ObjectRayDirection", 150, "objectRayDirection", .vector },
            .{ "RayTMin", 153, "rayTMin", .scalar },                           .{ "RayTCurrent", 154, "rayTCurrent", .scalar },
            .{ "InstanceID", 141, "instanceID", .scalar },                     .{ "InstanceIndex", 142, "instanceIndex", .scalar },
            .{ "HitKind", 143, "hitKind", .scalar },                           .{ "RayFlags", 144, "rayFlags", .scalar },
            .{ "PrimitiveIndex", 161, "primitiveIndex", .scalar },             .{ "GeometryIndex", 213, "geometryIndex", .scalar },
            .{ "ObjectToWorld3x4", 151, "objectToWorld", .m34 },               .{ "ObjectToWorld", 151, "objectToWorld", .m34 },
            .{ "ObjectToWorld4x3", 151, "objectToWorld", .m43 },               .{ "WorldToObject3x4", 152, "worldToObject", .m34 },
            .{ "WorldToObject", 152, "worldToObject", .m34 },                  .{ "WorldToObject4x3", 152, "worldToObject", .m43 },
        };
        for (table) |x| {
            if (!eq(u8, name, x[0])) continue;
            const rt = try e.scalarTy(e.compOf(ty));
            const fname = try std.fmt.allocPrint(e.arena, "dx.op.{s}.{s}", .{ x[2], e.overloadName(rt) });
            // (RayTCurrent changes during intersection shaders.)
            const attrs: module.FnAttrs = if (x[1] == 154) .nounwind_readonly else .nounwind_readnone;
            switch (x[3]) {
                .scalar => {
                    const f = try e.dxOp(fname, rt, &.{i32t}, attrs);
                    return try e.list(&.{try e.callOp(f, rt, &.{try e.i32Const(x[1])})});
                },
                .vector => {
                    const f = try e.dxOp(fname, rt, &.{ i32t, i8t }, attrs);
                    const out = try e.arena.alloc(Value, try e.flatCount(ty));
                    for (out, 0..) |*o, k| o.* = try e.callOp(f, rt, &.{ try e.i32Const(x[1]), try e.dm.constInt(8, @intCast(k)) });
                    return .{ .scalars = out };
                },
                .m34, .m43 => {
                    const f = try e.dxOp(fname, rt, &.{ i32t, i32t, i8t }, attrs);
                    const mt = e.t.get(ty).matrix;
                    const out = try e.arena.alloc(Value, @as(usize, mt.rows) * mt.cols);
                    for (0..mt.rows) |r| for (0..mt.cols) |c| {
                        const row, const col = if (x[3] == .m34) .{ r, c } else .{ c, r };
                        out[r * mt.cols + c] = try e.callOp(f, rt, &.{ try e.i32Const(x[1]), try e.i32Const(@intCast(row)), try e.dm.constInt(8, @intCast(col)) });
                    };
                    return .{ .scalars = out };
                },
            }
        }
        if (eq(u8, name, "IgnoreHit") or eq(u8, name, "AcceptHitAndEndSearch")) {
            const ignore = eq(u8, name, "IgnoreHit");
            const f = try e.dxOp(if (ignore) "dx.op.ignoreHit" else "dx.op.acceptHitAndEndSearch", void_ty, &.{i32t}, .noreturn_nounwind);
            _ = try e.callOp(f, void_ty, &.{try e.i32Const(if (ignore) 155 else 156)});
            _ = try e.add(void_ty, .@"unreachable");
            // What follows is unreachable.
            e.cur = try e.newBlock();
            return .none;
        }
        if (eq(u8, name, "TraceRay") or eq(u8, name, "CallShader") or eq(u8, name, "ReportHit")) {
            if (!e.lib) return e.unsupported("'{s}' outside library shaders", .{name});
            // The payload / parameter / attributes go in struct-typed
            // memory of their own.
            const data = args[args.len - 1];
            const dty_hl = frame.f.inst(data).ty;
            const dty = try e.memoryType(dty_hl);
            const ptr_t = try e.dm.ptrType(dty);
            const mem = try e.addPrologue(ptr_t, .{ .alloca = .{ .elem = dty, .size = try e.i32Const(1) } });
            const tp: @FieldType(Lowered, "typed") = .{ .base = mem, .dty = dty, .addr_space = 0, .ty = dty_hl };
            const report = eq(u8, name, "ReportHit");
            const vals = if (report) try e.scalars(frame, data) else (try e.loadPtr(try e.outPtr(frame, data), dty_hl)).scalars;
            try e.typedStore(tp, vals, dty_hl);
            const sname = e.dm.types.items[dty].@"struct".name;
            if (report) {
                const i1t = try e.dm.intType(1);
                const f = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.reportHit.{s}", .{sname}), i1t, &.{ i32t, f32t, i32t, ptr_t }, .nounwind);
                return try e.list(&.{try e.callOp(f, i1t, &.{ try e.i32Const(158), (try e.scalars(frame, args[0]))[0], (try e.scalars(frame, args[1]))[0], mem })});
            }
            if (eq(u8, name, "TraceRay")) {
                const accel = try e.resourceOf(frame, args[0]);
                var ps: [16]DType = undefined;
                ps[0] = i32t;
                ps[1] = e.handle_ty;
                for (ps[2..7]) |*p| p.* = i32t;
                for (ps[7..15]) |*p| p.* = f32t;
                ps[15] = ptr_t;
                const f = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.traceRay.{s}", .{sname}), void_ty, &ps, .nounwind);
                var call_args: std.ArrayList(Value) = .empty;
                try call_args.appendSlice(e.arena, &.{ try e.i32Const(157), accel.handle });
                for (args[1..6]) |a| try call_args.append(e.arena, (try e.scalars(frame, a))[0]);
                try call_args.appendSlice(e.arena, try e.scalars(frame, args[6]));
                try call_args.append(e.arena, mem);
                _ = try e.callOp(f, void_ty, call_args.items);
            } else {
                const f = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.callShader.{s}", .{sname}), void_ty, &.{ i32t, i32t, ptr_t }, .nounwind);
                _ = try e.callOp(f, void_ty, &.{ try e.i32Const(159), (try e.scalars(frame, args[0]))[0], mem });
            }
            const back = try e.typedLoad(tp, dty_hl);
            try e.storePtr(try e.outPtr(frame, data), back.scalars, dty_hl);
            return .none;
        }
        return null;
    }

    fn collectResources(e: *Emitter) Error!void {
        var counts = [_]u32{ 0, 0, 0, 0 };
        // Constant buffers: `$Globals` first, then the others in order.
        for ([_]bool{ true, false }) |globals_pass| for (e.m.globals.items, 0..) |g, gi| {
            if (g.space != .cbuffer or g.tbuffer or std.mem.eql(u8, g.name, "$Globals") != globals_pass) continue;
            try e.resources.append(e.arena, .{ .global = @intCast(gi), .class = .cbuffer, .id = counts[2], .kind = 13, .elem = g.ty });
            counts[2] += 1;
            try e.resource_of_global.put(e.arena, @intCast(gi), @intCast(e.resources.items.len - 1));
        };
        for (e.m.globals.items, 0..) |g, gi| {
            if (g.tbuffer) {
                // tbuffer blocks: SRVs (TBuffer) laid out like cbuffers.
                try e.resources.append(e.arena, .{ .global = @intCast(gi), .class = .srv, .id = counts[0], .kind = 15, .elem = g.ty });
                counts[0] += 1;
                try e.resource_of_global.put(e.arena, @intCast(gi), @intCast(e.resources.items.len - 1));
                continue;
            }
            if (g.space != .resource) continue;
            // Arrays of resources are register ranges.
            var gty = g.ty;
            var count: u32 = 1;
            while (e.t.get(gty) == .array) {
                const arr = e.t.get(gty).array;
                count = if (arr.len == 0 or count == std.math.maxInt(u32)) std.math.maxInt(u32) else count * arr.len;
                gty = arr.elem;
            }
            if (e.t.get(gty) == .sampler) {
                if (g.binding.explicit and g.binding.class != 's') return e.unsupported("binding '{s}' to the wrong register class", .{g.name});
                try e.resources.append(e.arena, .{ .global = @intCast(gi), .class = .sampler, .id = counts[3], .kind = 14, .elem = gty, .comparison = e.t.get(gty).sampler.comparison, .count = count });
                counts[3] += 1;
                try e.resource_of_global.put(e.arena, @intCast(gi), @intCast(e.resources.items.len - 1));
                continue;
            }
            if (e.t.get(gty) != .resource) return e.unsupported("global '{s}' is not supported yet", .{g.name});
            var res = try e.resourceFor(gty);
            res.coherent = g.globally_coherent and res.class == .uav;
            const class = res.class;
            const want: u8 = switch (class) {
                .uav => 'u',
                .srv => 't',
                .cbuffer => 'b',
                .sampler => 's',
            };
            if (g.binding.explicit and g.binding.class != want) {
                return e.unsupported("binding '{s}' to the wrong register class", .{g.name});
            }
            res.global = @intCast(gi);
            res.id = counts[@backingInt(class)];
            res.count = count;
            try e.resources.append(e.arena, res);
            counts[@backingInt(class)] += 1;
            try e.resource_of_global.put(e.arena, @intCast(gi), @intCast(e.resources.items.len - 1));
        }
        // Counters must be known before handles are made (SM 6.6 encodes
        // them in the handle's properties).
        for (e.m.functions.items) |f| for (f.insts.items) |inst| {
            const mt = switch (inst.op) {
                .method => |mt| mt,
                else => continue,
            };
            const eq = std.mem.eql;
            if (!(eq(u8, mt.name, "IncrementCounter") or eq(u8, mt.name, "DecrementCounter"))) continue;
            var r = mt.res;
            const g: ?u32 = while (true) switch (f.inst(r).op) {
                .load => |p| r = p,
                .access => |a| r = a.base,
                .global => |gi| break gi,
                else => break null,
            };
            if (g) |gi| if (e.resource_of_global.get(gi)) |ri| {
                e.resources.items[ri].has_counter = true;
            };
        };
        // Unbound resources take the next free register of their class.
        var used: std.AutoHashMapUnmanaged(struct { u8, u32, u32 }, void) = .empty;
        // (Unsized ranges are taken to hold 64 registers here.)
        const span = struct {
            fn f(n: u32) u32 {
                return if (n == std.math.maxInt(u32)) 64 else n;
            }
        }.f;
        for (e.resources.items) |res| {
            const b = e.m.globals.items[res.global].binding;
            if (b.explicit) for (0..span(res.count)) |k| try used.put(e.arena, .{ @backingInt(res.class), b.space, b.index + @as(u32, @intCast(k)) }, {});
        }
        for (e.resources.items) |res| {
            const g = &e.m.globals.items[res.global];
            if (g.binding.explicit) continue;
            if (e.lib) {
                // Libraries leave them unbound (-1) until linked.
                @constCast(g).binding.index = std.math.maxInt(u32);
                @constCast(g).binding.space = std.math.maxInt(u32);
                continue;
            }
            var i: u32 = 0;
            while (true) : (i += 1) {
                const free = for (0..span(res.count)) |k| {
                    if (used.contains(.{ @backingInt(res.class), g.binding.space, i + @as(u32, @intCast(k)) })) break false;
                } else true;
                if (free) break;
            }
            for (0..span(res.count)) |k| try used.put(e.arena, .{ @backingInt(res.class), g.binding.space, i + @as(u32, @intCast(k)) }, {});
            // Globals are const in the module; record the chosen binding.
            @constCast(g).binding.index = i;
        }
    }

    fn binding(e: *Emitter, res: Resource) ir.Binding {
        return e.m.globals.items[res.global].binding;
    }

    fn createHandles(e: *Emitter) Error!void {
        for (e.resources.items) |*res| {
            // Array elements get their handles where they are used.
            if (res.count != 1) continue;
            res.handle = try e.makeHandle(res.*, try e.i32Const(e.binding(res.*).index), false, true);
        }
    }

    /// A handle to register `index` of `res`'s range (in the prologue, or
    /// at the current point).
    fn makeHandle(e: *Emitter, res: Resource, index: Value, nonuniform: bool, prologue: bool) Error!Value {
        const i32t = try e.dm.intType(32);
        const i1t = try e.dm.intType(1);
        const i8t = try e.dm.intType(8);
        const b = e.binding(res);
        const nu = try e.dm.constant(.{ .ty = i1t, .kind = .{ .int = @intFromBool(nonuniform) } });
        const emitCall = struct {
            fn f(em: *Emitter, pro: bool, callee: u32, args: []const Value) Error!Value {
                const op: @FieldType(module.Inst, "op") = .{ .call = .{ .callee = callee, .args = try em.arena.dupe(Value, args) } };
                return if (pro) em.addPrologue(em.handle_ty, op) else em.add(em.handle_ty, op);
            }
        }.f;
        if (self_sm66(e)) {
            const bind_ty = try e.dm.getType(.{ .@"struct" = .{ .name = "dx.types.ResBind", .elems = &.{ i32t, i32t, i32t, i8t } } });
            const props_ty = try e.dm.getType(.{ .@"struct" = .{ .name = "dx.types.ResourceProperties", .elems = &.{ i32t, i32t } } });
            const create = try e.dxOp("dx.op.createHandleFromBinding", e.handle_ty, &.{ i32t, bind_ty, i32t, i1t }, .nounwind_readnone);
            const annotate = try e.dxOp("dx.op.annotateHandle", e.handle_ty, &.{ i32t, e.handle_ty, props_ty }, .nounwind_readnone);
            const ub: i64 = if (res.count == std.math.maxInt(u32)) -1 else b.index + res.count - 1;
            const lb_c = try e.dm.constant(.{ .ty = i32t, .kind = .{ .int = b.index } });
            const ub_c = try e.dm.constant(.{ .ty = i32t, .kind = .{ .int = ub } });
            const space = try e.dm.constant(.{ .ty = i32t, .kind = .{ .int = b.space } });
            const cls = try e.dm.constant(.{ .ty = i8t, .kind = .{ .int = @backingInt(res.class) } });
            const bind = try e.dm.constant(.{ .ty = bind_ty, .kind = .{ .aggregate = try e.arena.dupe(module.ConstId, &.{ lb_c.constant, ub_c.constant, space.constant, cls.constant }) } });
            const raw = try emitCall(e, prologue, create, &.{ try e.i32Const(217), bind, index, nu });
            return emitCall(e, prologue, annotate, &.{ try e.i32Const(216), raw, try e.propertiesConst(res) });
        }
        const create = try e.dxOp("dx.op.createHandle", e.handle_ty, &.{ i32t, i8t, i32t, i32t, i1t }, .nounwind_readonly);
        return emitCall(e, prologue, create, &.{
            try e.i32Const(57),
            try e.dm.constant(.{ .ty = i8t, .kind = .{ .int = @backingInt(res.class) } }),
            try e.i32Const(res.id),
            index,
            nu,
        });
    }

    /// Derivatives (and implicit-LOD sampling): pixel shaders, and from SM
    /// 6.6 compute, mesh and amplification shaders.
    fn checkDerivatives(e: *Emitter) Error!void {
        switch (e.entry.stage) {
            // (Library functions record the use; their callers decide.)
            .pixel, .library => {},
            .compute, .mesh, .amplification => if (e.profile.minor < 6) return e.unsupported("derivatives outside pixel shaders need shader model 6.6", .{}),
            else => return e.unsupported("derivatives are not available in {s} shaders", .{@tagName(e.entry.stage)}),
        }
        if (e.entry.stage == .mesh or e.entry.stage == .amplification) e.uses_mesh_derivatives = true;
    }

    /// The ResourceProperties constant annotating `res`'s handles.
    fn propertiesConst(e: *Emitter, res: Resource) Error!Value {
        const i32t = try e.dm.intType(32);
        const props_ty = try e.dm.getType(.{ .@"struct" = .{ .name = "dx.types.ResourceProperties", .elems = &.{ i32t, i32t } } });
        const p = try e.resourceProperties(res);
        const p0 = try e.dm.constant(.{ .ty = i32t, .kind = .{ .int = p[0] } });
        const p1 = try e.dm.constant(.{ .ty = i32t, .kind = .{ .int = p[1] } });
        return e.dm.constant(.{ .ty = props_ty, .kind = .{ .aggregate = try e.arena.dupe(module.ConstId, &.{ p0.constant, p1.constant }) } });
    }

    /// annotateHandle at the current point.
    fn annotateHandle(e: *Emitter, res: Resource, raw: Value) Error!Value {
        const i32t = try e.dm.intType(32);
        const props_ty = try e.dm.getType(.{ .@"struct" = .{ .name = "dx.types.ResourceProperties", .elems = &.{ i32t, i32t } } });
        const fn_i = try e.dxOp("dx.op.annotateHandle", e.handle_ty, &.{ i32t, e.handle_ty, props_ty }, .nounwind_readnone);
        return e.callOp(fn_i, e.handle_ty, &.{ try e.i32Const(216), raw, try e.propertiesConst(res) });
    }

    fn self_sm66(e: *Emitter) bool {
        return e.profile.minor >= 6;
    }

    /// DxilResourceProperties for annotateHandle.
    fn resourceProperties(e: *Emitter, res: Resource) Error![2]i64 {
        var basic: i64 = res.kind;
        if (res.class == .uav) basic |= 0x1000;
        if (res.rov) basic |= 0x2000;
        if (res.coherent) basic |= 0x4000;
        if (res.comparison or res.has_counter) basic |= 0x8000;
        const extra: i64 = switch (res.kind) {
            13 => try e.cbufferSize(res),
            12 => try e.stride(res.elem),
            14 => 0,
            1...10 => blk: {
                const n = try e.flatCount(res.elem);
                break :blk try e.compType(e.compOf(res.elem)) | (@as(i64, n) << 8);
            },
            else => 0,
        };
        return .{ basic, extra };
    }

    /// Structured buffer element stride (packed layout).
    fn stride(e: *Emitter, ty: TypeId) Error!i64 {
        return layout.sizeOf(e.t, ty, false, .dx_packed) catch e.unsupported("buffer element type '{s}'", .{try e.t.format(e.arena, ty)});
    }

    /// DXIL ComponentType of a typed buffer element.
    fn compType(e: *Emitter, s: Scalar) Error!i64 {
        return switch (s) {
            .int => 4,
            .uint => 5,
            .float => 9,
            .int16 => 2,
            .uint16 => 3,
            .float16 => 8,
            .bool => 5, // stored as U32
            .int64 => 6,
            .uint64 => 7,
            .double => 10,
            else => e.unsupported("typed buffers of this element type are not supported yet", .{}),
        };
    }

    /// Assigns final instruction indices: prologue first, then blocks in
    /// creation order.
    fn finish(e: *Emitter, func: u32) Error!void {
        if (e.lib_removable.count() > 0) try e.pruneProlog();
        const map = try e.arena.alloc(u32, e.next_id);
        var n: u32 = 0;
        for (e.prologue.items) |pi| {
            map[pi.id] = n;
            n += 1;
        }
        for (e.blocks.items) |blk| for (blk.items) |pi| {
            map[pi.id] = n;
            n += 1;
        };
        const f = &e.dm.functions.items[func];
        f.num_blocks = @intCast(e.blocks.items.len);
        const remap = struct {
            fn v(mp: []const u32, x: Value) Value {
                return if (x == .inst) .{ .inst = mp[x.inst] } else x;
            }
            fn vs(a: Allocator, mp: []const u32, xs: []const Value) Allocator.Error![]const Value {
                const out = try a.alloc(Value, xs.len);
                for (xs, out) |x, *o| o.* = v(mp, x);
                return out;
            }
        };
        const all = [_][]const PInst{e.prologue.items};
        for (all) |items| for (items) |pi| try f.insts.append(e.dm.allocator(), try remapInst(e.arena, map, pi.inst, remap));
        for (e.blocks.items) |blk| for (blk.items) |pi| try f.insts.append(e.dm.allocator(), try remapInst(e.arena, map, pi.inst, remap));
    }

    /// Drops removable prologue instructions nothing uses (repeatedly: a
    /// handle's load goes once the handle has).
    fn pruneProlog(e: *Emitter) Error!void {
        const used = try e.arena.alloc(bool, e.next_id);
        var changed = true;
        while (changed) {
            changed = false;
            @memset(used, false);
            const all = [_][]const PInst{e.prologue.items};
            for (all) |items| for (items) |pi| markUses(e.arena, pi.inst, used);
            for (e.blocks.items) |blk| for (blk.items) |pi| markUses(e.arena, pi.inst, used);
            var k: usize = 0;
            while (k < e.prologue.items.len) {
                const pi = e.prologue.items[k];
                if (e.lib_removable.contains(pi.id) and !used[pi.id]) {
                    _ = e.prologue.orderedRemove(k);
                    changed = true;
                } else k += 1;
            }
        }
        e.lib_removable = .empty;
    }

    fn markUses(a: Allocator, inst: module.Inst, used: []bool) void {
        const M = struct {
            var u: []bool = &.{};
            fn v(_: []const u32, x: Value) Value {
                if (x == .inst) u[x.inst] = true;
                return x;
            }
            fn vs(_: Allocator, _: []const u32, xs: []const Value) Allocator.Error![]const Value {
                for (xs) |x| _ = v(&.{}, x);
                return xs;
            }
        };
        M.u = used;
        _ = remapInst(a, &.{}, inst, M) catch {};
    }

    fn remapInst(a: Allocator, map: []const u32, inst: module.Inst, comptime R: type) Allocator.Error!module.Inst {
        var out = inst;
        switch (out.op) {
            .ret => |*v| if (v.*) |x| {
                v.* = R.v(map, x);
            },
            .@"switch" => |*sw| sw.cond = R.v(map, sw.cond),
            .br => |*b| if (b.cond) |c| {
                b.cond = R.v(map, c);
            },
            .call => |*c| c.args = try R.vs(a, map, c.args),
            .binop => |*b| {
                b.lhs = R.v(map, b.lhs);
                b.rhs = R.v(map, b.rhs);
            },
            .cast => |*c| c.val = R.v(map, c.val),
            .cmp => |*c| {
                c.lhs = R.v(map, c.lhs);
                c.rhs = R.v(map, c.rhs);
            },
            .select => |*s| {
                s.cond = R.v(map, s.cond);
                s.t = R.v(map, s.t);
                s.f = R.v(map, s.f);
            },
            .extractvalue => |*x| x.agg = R.v(map, x.agg),
            .phi => |*p| {
                const ins = try a.alloc(@typeInfo(@TypeOf(p.incoming)).pointer.child, p.incoming.len);
                for (p.incoming, ins) |in, *o| o.* = .{ .val = R.v(map, in.val), .block = in.block };
                p.incoming = ins;
            },
            .alloca => |*x| x.size = R.v(map, x.size),
            .load => |*x| x.ptr = R.v(map, x.ptr),
            .store => |*x| {
                x.ptr = R.v(map, x.ptr);
                x.val = R.v(map, x.val);
            },
            .gep => |*x| {
                x.ptr = R.v(map, x.ptr);
                x.indices = try R.vs(a, map, x.indices);
            },
            .atomicrmw => |*x| {
                x.ptr = R.v(map, x.ptr);
                x.val = R.v(map, x.val);
            },
            .cmpxchg => |*x| {
                x.ptr = R.v(map, x.ptr);
                x.cmp = R.v(map, x.cmp);
                x.new = R.v(map, x.new);
            },
            .@"unreachable" => {},
            .extractelement => |*x| {
                x.vec = R.v(map, x.vec);
                x.index = R.v(map, x.index);
            },
            .insertelement => |*x| {
                x.vec = R.v(map, x.vec);
                x.val = R.v(map, x.val);
                x.index = R.v(map, x.index);
            },
        }
        return out;
    }

    // ------------------------------------------------------------------
    // Functions (inlined)

    /// Emits function `fi` inline at the current block with `args`; returns
    /// its result components and leaves the current block after the call.
    fn inlineCall(e: *Emitter, fi: u32, args: []const Lowered) Error![]const Value {
        const f = e.m.functions.items[fi];
        var frame: Frame = .{
            .f = f,
            .vals = try e.arena.alloc(Lowered, f.insts.items.len),
            .params = args,
            .blocks = try e.arena.alloc(?u32, f.blocks.items.len),
        };
        @memset(frame.vals, .none);
        @memset(frame.blocks, null);
        const is_entry = e.cur == 0 and e.blocks.items[0].items.len == 0 and (fi == e.entry.wrapper or fi == e.entry.patch_wrapper);
        if (!is_entry) frame.cont = try e.newBlock();
        // The callee's entry continues the current block.
        frame.blocks[0] = e.cur;
        const reachable = try reachableBlocks(e.arena, f);
        for (f.blocks.items, 0..) |_, bi| {
            if (!reachable[bi]) continue;
            e.cur = try e.blockFor(&frame, @intCast(bi));
            try e.emitBlock(&frame, @intCast(bi));
        }
        e.last_ret_res = frame.ret_res;
        if (frame.cont) |cont| {
            e.cur = cont;
            if (f.ret == TypeTable.void_type or frame.rets.items.len == 0) return &.{};
            const n = frame.rets.items[0].vals.len;
            const out = try e.arena.alloc(Value, n);
            for (0..n) |c| {
                const ins = try e.arena.alloc(@typeInfo(@FieldType(@FieldType(@FieldType(module.Inst, "op"), "phi"), "incoming")).pointer.child, frame.rets.items.len);
                for (frame.rets.items, ins) |r, *in| in.* = .{ .val = r.vals[c], .block = r.block };
                const ty = try e.valueType(frame.rets.items[0].vals[c]);
                out[c] = if (ins.len == 1) ins[0].val else try e.add(ty, .{ .phi = .{ .incoming = ins } });
            }
            return out;
        }
        return &.{};
    }

    /// A call of `[noinline]` function `fi` (module function `func`), as
    /// exportSignature passes values: out / inout values and structs
    /// through temporaries.
    fn libCall(e: *Emitter, frame: *Frame, fi: u32, func: u32, refs: []const Ref) Error!Lowered {
        const f = e.m.functions.items[fi];
        const void_ty = try e.voidTy();
        const args = try e.arena.alloc(Value, refs.len);
        const temps = try e.arena.alloc(?Value, refs.len);
        for (f.params, refs, args, temps) |p, r, *a, *tmp| {
            tmp.* = null;
            const is_struct = e.t.get(p.ty) == .@"struct";
            if (!p.by_ref and !is_struct) {
                a.* = try e.libJoin(try e.scalars(frame, r), p.ty);
                continue;
            }
            const dty = if (is_struct) try e.memoryType(p.ty) else try e.libValueType(p.ty);
            const base = try e.addPrologue(try e.dm.ptrType(dty), .{ .alloca = .{ .elem = dty, .size = try e.i32Const(1) } });
            a.* = base;
            const vals: ?[]const Value = if (!p.by_ref) try e.scalars(frame, r) else if (p.dir == .out) null else switch (frame.vals[r.index()]) {
                .ptr => |ptr| (try e.loadPtr(ptr, p.ty)).scalars,
                .typed => |tp| (try e.typedLoad(tp, p.ty)).scalars,
                else => return e.unsupported("this argument of a [noinline] function is not supported yet", .{}),
            };
            if (vals) |vs| {
                if (is_struct)
                    try e.typedStore(.{ .base = base, .dty = dty, .addr_space = 0, .ty = p.ty }, vs, p.ty)
                else
                    _ = try e.add(void_ty, .{ .store = .{ .ptr = base, .val = try e.libJoin(vs, p.ty), .@"align" = 4 } });
            }
            if (p.by_ref) tmp.* = base;
        }
        const ret_ty = if (f.ret == TypeTable.void_type) void_ty else try e.libValueType(f.ret);
        const res = try e.add(ret_ty, .{ .call = .{ .callee = func, .args = args } });
        // (Locals may have changed through the pointers.)
        e.forwarded.clearRetainingCapacity();
        for (f.params, refs, temps) |p, r, tmp| if (tmp) |base| {
            const vals = if (e.t.get(p.ty) == .@"struct")
                (try e.typedLoad(.{ .base = base, .dty = try e.memoryType(p.ty), .addr_space = 0, .ty = p.ty }, p.ty)).scalars
            else
                try e.libSplit(try e.add(try e.libValueType(p.ty), .{ .load = .{ .ptr = base, .@"align" = 4 } }), p.ty);
            switch (frame.vals[r.index()]) {
                .ptr => |ptr| try e.storePtr(ptr, vals, p.ty),
                .typed => |tp| try e.typedStore(tp, vals, p.ty),
                else => return e.unsupported("this argument of a [noinline] function is not supported yet", .{}),
            }
        };
        if (f.ret == TypeTable.void_type) return .none;
        return .{ .scalars = try e.libSplit(res, f.ret) };
    }

    fn blockFor(e: *Emitter, frame: *Frame, bi: u32) Error!u32 {
        if (frame.blocks[bi]) |b| return b;
        const b = try e.newBlock();
        frame.blocks[bi] = b;
        return b;
    }

    /// The DXIL type of a value (constant or instruction).
    fn valueType(e: *Emitter, v: Value) Error!DType {
        return switch (v) {
            .constant => |c| e.dm.constants.items[c].ty,
            .inst => |id| blk: {
                for (e.prologue.items) |pi| if (pi.id == id) break :blk pi.inst.ty;
                for (e.blocks.items) |b| for (b.items) |pi| if (pi.id == id) break :blk pi.inst.ty;
                unreachable;
            },
            else => e.unsupported("value kind", .{}),
        };
    }

    fn emitBlock(e: *Emitter, frame: *Frame, bi: u32) Error!void {
        const f = frame.f;
        const blk = f.blocks.items[bi];
        for (blk.insts.items) |r| {
            frame.vals[r.index()] = try e.emitInst(frame, r);
        }
        const void_ty = try e.voidTy();
        switch (blk.term) {
            .ret => |v| {
                if (frame.cont) |cont| {
                    if (v != .none) {
                        const rty = frame.f.inst(v).ty;
                        if ((isResourceType(e.t, rty) and !isRayQuery(e.t, rty)) or e.holdsResources(rty)) {
                            const parts = try e.aggParts(frame.vals[v.index()], rty);
                            if (frame.ret_res) |old| {
                                if (old.len != parts.res.len) return e.unsupported("returning different resources from one function is not supported yet", .{});
                                for (old, parts.res) |a, b| if (!std.meta.eql(a, b)) return e.unsupported("returning different resources from one function is not supported yet", .{});
                            }
                            frame.ret_res = parts.res;
                            try frame.rets.append(e.arena, .{ .block = e.cur, .vals = parts.vals });
                        } else try frame.rets.append(e.arena, .{ .block = e.cur, .vals = try e.scalars(frame, v) });
                    }
                    _ = try e.add(void_ty, .{ .br = .{ .then = cont } });
                } else _ = try e.add(void_ty, .{ .ret = null });
            },
            .br => |t| _ = try e.add(void_ty, .{ .br = .{ .then = try e.blockFor(frame, t.index()) } }),
            .cond_br => |c| {
                const cond = (try e.scalars(frame, c.cond))[0];
                const then_b = try e.blockFor(frame, c.then.index());
                const else_b = try e.blockFor(frame, c.@"else".index());
                _ = try e.add(void_ty, .{ .br = .{ .then = then_b, .@"else" = else_b, .cond = cond } });
            },
            .none, .@"unreachable" => _ = try e.add(void_ty, .@"unreachable"),
            .@"switch" => |sw| {
                const cond = (try e.scalars(frame, sw.value))[0];
                const cases = try e.arena.alloc(@typeInfo(@FieldType(@FieldType(@FieldType(module.Inst, "op"), "switch"), "cases")).pointer.child, sw.cases.len);
                for (sw.cases, cases) |c, *o| o.* = .{ .val = try e.i32Const(@as(i32, @truncate(c.value))), .block = try e.blockFor(frame, c.block.index()) };
                _ = try e.add(void_ty, .{ .@"switch" = .{ .cond = cond, .default = try e.blockFor(frame, sw.default.index()), .cases = cases } });
            },
            .discard => {
                // Like SPIR-V's OpKill: the invocation stops here.
                const i32t = try e.dm.intType(32);
                const i1t = try e.dm.intType(1);
                const fn_i = try e.dxOp("dx.op.discard", void_ty, &.{ i32t, i1t }, .nounwind);
                _ = try e.callOp(fn_i, void_ty, &.{ try e.i32Const(82), try e.dm.constInt(1, 1) });
                _ = try e.add(void_ty, .{ .ret = null });
            },
        }
    }

    fn scalars(e: *Emitter, frame: *Frame, r: Ref) Error![]const Value {
        return switch (frame.vals[r.index()]) {
            .scalars => |s| s,
            else => e.unsupported("internal: expected a value", .{}),
        };
    }

    /// The flattened storage shape for `ty` (base not yet set).
    fn storageFor(e: *Emitter, ty: TypeId) Error!Ptr {
        const n = try e.flatCount(ty);
        if (try e.mixedStorage(ty)) {
            const st = try e.dm.intType(32);
            return .{ .base = undefined, .array_ty = try e.dm.getType(.{ .array = .{ .len = n, .elem = st } }), .scalar_ty = st, .mixed = true };
        }
        const c = try e.uniformScalar(ty);
        if (c.size() != 4) return e.unsupported("groupshared values of type '{s}' are not supported yet", .{try e.t.format(e.arena, ty)});
        const st = try e.scalarTy(if (c == .bool) Scalar.int else c);
        return .{ .base = undefined, .array_ty = try e.dm.getType(.{ .array = .{ .len = n, .elem = st } }), .scalar_ty = st, .bool_storage = c == .bool };
    }

    /// Flattened storage for a value of type `ty`, allocated on entry.
    fn alloca(e: *Emitter, ty: TypeId) Error!Ptr {
        const n = try e.flatCount(ty);
        if (try e.mixedStorage(ty)) {
            const st = try e.dm.intType(32);
            const arr = try e.dm.getType(.{ .array = .{ .len = n, .elem = st } });
            const base = try e.addPrologue(try e.dm.ptrType(arr), .{ .alloca = .{ .elem = arr, .size = try e.i32Const(1) } });
            return .{ .base = base, .array_ty = arr, .scalar_ty = st, .mixed = true };
        }
        const c = try e.uniformScalar(ty);
        const store_c = if (c == .bool) Scalar.int else c;
        const st = try e.scalarTy(store_c);
        const arr = try e.dm.getType(.{ .array = .{ .len = n, .elem = st } });
        const base = try e.addPrologue(try e.dm.ptrType(arr), .{ .alloca = .{ .elem = arr, .size = try e.i32Const(1) } });
        return .{ .base = base, .array_ty = arr, .scalar_ty = st, .bool_storage = c == .bool };
    }

    fn list(e: *Emitter, vals: []const Value) Error!Lowered {
        return .{ .scalars = try e.arena.dupe(Value, vals) };
    }

    fn emitInst(e: *Emitter, frame: *Frame, r: Ref) Error!Lowered {
        const f = frame.f;
        const i = f.inst(r);
        switch (i.op) {
            .constant => |c| return e.list(&.{try e.constant(i.ty, c)}),
            .param => |p| return frame.params[p],
            .spec_constant => return e.unsupported("specialization constants outside SPIR-V", .{}),
            .spirv_inst => return e.unsupported("inline SPIR-V outside SPIR-V", .{}),
            .ray_incoming => |k| {
                // The shader's payload / attribute / parameter argument.
                const idx: usize = if (k == .attributes) 1 else 0;
                if (idx >= e.lib_args.len) return e.unsupported("ray tracing shaders outside libraries", .{});
                return .{ .typed = .{ .base = e.lib_args[idx], .dty = try e.memoryType(i.ty), .addr_space = 0, .ty = i.ty } };
            },
            .heap_resource => |h| {
                if (e.t.get(i.ty) != .resource and e.t.get(i.ty) != .sampler) return .none;
                if (e.profile.minor < 6) return e.unsupported("descriptor heaps need shader model 6.6", .{});
                var res = try e.resourceFor(i.ty);
                res.global = std.math.maxInt(u32);
                res.view = true;
                const idx = (try e.scalars(frame, h.index))[0];
                const i32t = try e.dm.intType(32);
                const i1t = try e.dm.intType(1);
                const create = try e.dxOp("dx.op.createHandleFromHeap", e.handle_ty, &.{ i32t, i32t, i1t, i1t }, .nounwind_readnone);
                const raw = try e.callOp(create, e.handle_ty, &.{ try e.i32Const(218), idx, try e.dm.constant(.{ .ty = i1t, .kind = .{ .int = @intFromBool(h.sampler) } }), try e.dm.constant(.{ .ty = i1t, .kind = .{ .int = @intFromBool(e.nonuniform.contains(idx)) } }) });
                res.handle = try e.annotateHandle(res, raw);
                if (h.sampler) e.uses_sampler_heap = true else e.uses_resource_heap = true;
                try e.resources.append(e.arena, res);
                return .{ .handle = @intCast(e.resources.items.len - 1) };
            },
            .mesh_output => |k| return .{ .mesh = .{ .kind = k, .ty = i.ty } },
            .mesh_payload => {
                const dty = try e.memoryType(i.ty);
                const ptr_ty = try e.dm.ptrType(dty);
                const fn_i = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.getMeshPayload.{s}", .{e.dm.types.items[dty].@"struct".name}), ptr_ty, &.{try e.dm.intType(32)}, .nounwind_readonly);
                const base = try e.callOp(fn_i, ptr_ty, &.{try e.i32Const(170)});
                return e.typedLoad(.{ .base = base, .dty = dty, .addr_space = 0, .ty = i.ty }, i.ty);
            },
            .global => |g| {
                if (e.payload_global == g) {
                    const gop = try e.private_globals.getOrPut(e.arena, g);
                    if (!gop.found_existing) {
                        const dty = try e.memoryType(e.m.globals.items[g].ty);
                        const gv = try e.dm.addGlobal(e.m.globals.items[g].name, dty, 3);
                        gop.value_ptr.* = .{ .base = gv, .array_ty = dty, .scalar_ty = dty, .addr_space = 3 };
                        e.groupshared_bytes += try e.payloadSize(e.m.globals.items[g].ty);
                    }
                    return .{ .typed = .{ .base = gop.value_ptr.base, .dty = gop.value_ptr.array_ty, .addr_space = 3, .ty = e.m.globals.items[g].ty } };
                }
                // Static globals live in the entry function (everything is
                // inlined into it).
                if (e.m.globals.items[g].space == .private) {
                    const gty = e.m.globals.items[g].ty;
                    if (try e.mixedSizes(gty) or e.containsLinAlg(gty)) {
                        const tg = try e.private_typed.getOrPut(e.arena, g);
                        if (!tg.found_existing) {
                            const dty = try e.memoryType(gty);
                            const base = try e.addPrologue(try e.dm.ptrType(dty), .{ .alloca = .{ .elem = dty, .size = try e.i32Const(1) } });
                            tg.value_ptr.* = .{ .base = base, .dty = dty, .addr_space = 0, .ty = gty };
                        }
                        return .{ .typed = tg.value_ptr.* };
                    }
                    const gop = try e.private_globals.getOrPut(e.arena, g);
                    if (!gop.found_existing) gop.value_ptr.* = try e.alloca(e.m.globals.items[g].ty);
                    return .{ .ptr = gop.value_ptr.* };
                }
                if (e.m.globals.items[g].space == .groupshared) {
                    // Address-space-3 module variables, flattened like locals.
                    const gop = try e.private_globals.getOrPut(e.arena, g);
                    if (!gop.found_existing) {
                        var p = try e.storageFor(e.m.globals.items[g].ty);
                        const gv = try e.dm.addGlobal(e.m.globals.items[g].name, p.array_ty, 3);
                        p.base = gv;
                        p.addr_space = 3;
                        gop.value_ptr.* = p;
                        e.groupshared_bytes += @intCast(e.dm.types.items[p.array_ty].array.len * 4);
                    }
                    return .{ .ptr = gop.value_ptr.* };
                }
                const ri = e.resource_of_global.get(g) orelse return e.unsupported("global '{s}' is not supported yet", .{e.m.globals.items[g].name});
                if (e.m.globals.items[g].space == .cbuffer) return .{ .cbuf = .{ .res = ri } };
                if (e.resources.items[ri].count != 1) return .{ .res_array = .{ .res = ri, .ty = e.m.globals.items[g].ty } };
                return .{ .handle = ri };
            },
            .local_var => {
                if (e.payload_local) |pl| if (pl.func == f and pl.inst == r.index()) {
                    const dty = try e.memoryType(i.ty);
                    const base = try e.addPrologue(try e.dm.ptrType(dty), .{ .alloca = .{ .elem = dty, .size = try e.i32Const(1) } });
                    return .{ .typed = .{ .base = base, .dty = dty, .addr_space = 0, .ty = i.ty } };
                };
                if (isRayQuery(e.t, i.ty)) {
                    try e.rq_locals.append(e.arena, .{ .h = null, .ty = i.ty });
                    return .{ .rq_local = @intCast(e.rq_locals.items.len - 1) };
                }
                // (An array of resources is one alias too: of an array.)
                if (isResourceType(e.t, i.ty) or e.isResourceArray(i.ty)) {
                    try e.res_locals.append(e.arena, null);
                    return .{ .res_local = @intCast(e.res_locals.items.len - 1) };
                }
                if (e.holdsResources(i.ty)) return e.aggLocal(i.ty);
                if (try e.mixedSizes(i.ty) or e.containsLinAlg(i.ty)) {
                    // Components of several sizes (or matrix handles): a
                    // struct-typed alloca.
                    const dty = try e.memoryType(i.ty);
                    const base = try e.addPrologue(try e.dm.ptrType(dty), .{ .alloca = .{ .elem = dty, .size = try e.i32Const(1) } });
                    return .{ .typed = .{ .base = base, .dty = dty, .addr_space = 0, .ty = i.ty } };
                }
                return .{ .ptr = try e.alloca(i.ty) };
            },
            .load => |p| switch (frame.vals[p.index()]) {
                .handle => |h| return .{ .handle = h },
                .agg_ptr => |ap| {
                    const vals: []const Value = if (ap.data) |d| switch (d.*) {
                        .ptr => |ptr| (try e.loadPtr(ptr, ap.ty)).scalars,
                        .typed => |tp| (try e.typedLoad(tp, ap.ty)).scalars,
                        else => unreachable,
                    } else &.{};
                    const res = try e.arena.alloc(Lowered, ap.slots.len);
                    for (res, ap.slots) |*o, sl| o.* = e.res_locals.items[sl] orelse return e.unsupported("a resource in a local read before it is assigned", .{});
                    return .{ .agg = .{ .vals = vals, .res = res } };
                },
                .rq_local => |k| return .{ .ray_query = try e.rqHandle(k) },
                .res_local => |k| return e.res_locals.items[k] orelse return e.unsupported("a resource local read before it is assigned", .{}),
                .res_array => |ra| return .{ .res_array = ra },
                .texel => |tx| {
                    const res = e.resources.items[tx.res];
                    const mip = if (res.class == .uav) try e.dm.constant(.{ .ty = try e.dm.intType(32), .kind = .undef }) else try e.i32Const(0);
                    if (res.kind == 10) return .{ .scalars = try e.typedBufferLoad(res, tx.coords[0], i.ty) };
                    return .{ .scalars = try e.textureLoad(res, mip, tx.coords, null, i.ty) };
                },
                .cbuf => |c| return e.cbufferLoad(c.res, c.offset, c.dyn_regs, c.row_major, i.ty),
                .buf => |b| {
                    const mat = b.mat orelse return .{ .scalars = try e.structuredLoad(e.resources.items[b.res], b.index, b.offset, b.dyn, b.row_major, i.ty) };
                    const m = e.t.get(mat.ty).matrix;
                    const whole = try e.structuredLoad(e.resources.items[b.res], b.index, b.offset, b.dyn, b.row_major, mat.ty);
                    const cols: []const u32 = if (mat.col) |c| &.{c} else blk: {
                        const all = try e.arena.alloc(u32, m.cols);
                        for (all, 0..) |*x, k| x.* = @intCast(k);
                        break :blk all;
                    };
                    const out = try e.arena.alloc(Value, cols.len);
                    for (out, cols) |*o, c| {
                        if (e.constIntOf(mat.row)) |row| {
                            o.* = whole[@as(u32, @intCast(row)) * m.cols + c];
                            continue;
                        }
                        // A dynamic row: select among the rows.
                        var v = whole[c];
                        for (1..m.rows) |row| {
                            const is_r = try e.add(try e.dm.intType(1), .{ .cmp = .{ .pred = 32, .lhs = mat.row, .rhs = try e.i32Const(@intCast(row)) } });
                            v = try e.select(is_r, whole[row * m.cols + c], v, try e.valueType(v));
                        }
                        o.* = v;
                    }
                    return .{ .scalars = out };
                },
                .ptr => |ptr| return e.loadPtr(ptr, i.ty),
                .typed => |tp| return e.typedLoad(tp, i.ty),
                .mesh => return e.unsupported("reading mesh shader outputs is not supported", .{}),
                else => return e.unsupported("internal: load from a non-pointer", .{}),
            },
            .store => |s| {
                if (frame.vals[s.ptr.index()] == .rq_local) {
                    // A copy of a query is the same query.
                    const v = frame.vals[s.value.index()];
                    if (v != .ray_query) return e.unsupported("this RayQuery assignment is not supported yet", .{});
                    e.rq_locals.items[frame.vals[s.ptr.index()].rq_local].h = v.ray_query;
                    return .none;
                }
                if (frame.vals[s.ptr.index()] == .res_local) {
                    const slot = &e.res_locals.items[frame.vals[s.ptr.index()].res_local];
                    const h = frame.vals[s.value.index()];
                    if (h != .handle and h != .res_array) return e.unsupported("resources not tied to a global are not supported yet", .{});
                    // Selecting between resources at run time has no
                    // handle-based lowering here; one assignment is fine.
                    if (slot.*) |old| if (!std.meta.eql(old, h)) return e.unsupported("assigning different resources to one variable is not supported yet", .{});
                    slot.* = h;
                    return .none;
                }
                if (frame.vals[s.ptr.index()] == .agg_ptr) {
                    try e.aggStore(frame.vals[s.ptr.index()].agg_ptr, frame.vals[s.value.index()]);
                    return .none;
                }
                // A resource written back to the global it is (an inout
                // argument): nothing to do.
                if (frame.vals[s.ptr.index()] == .handle or frame.vals[s.ptr.index()] == .res_array) {
                    if (std.meta.eql(frame.vals[s.ptr.index()], frame.vals[s.value.index()])) return .none;
                    return e.unsupported("assigning another resource to a global resource", .{});
                }
                if (frame.vals[s.ptr.index()] == .mesh) {
                    try e.meshStore(frame.vals[s.ptr.index()].mesh, try e.scalars(frame, s.value), f.inst(s.value).ty);
                    return .none;
                }
                if (frame.vals[s.ptr.index()] == .typed) {
                    try e.typedStore(frame.vals[s.ptr.index()].typed, try e.scalars(frame, s.value), f.inst(s.value).ty);
                    return .none;
                }
                if (frame.vals[s.ptr.index()] == .buf) {
                    const b = frame.vals[s.ptr.index()].buf;
                    if (b.mat) |mat| {
                        try e.matrixPartStore(b, mat, try e.scalars(frame, s.value));
                        return .none;
                    }
                    try e.structuredStore(e.resources.items[b.res], b.index, b.offset, b.dyn, b.row_major, f.inst(s.value).ty, try e.scalars(frame, s.value));
                    return .none;
                }
                const ptr = switch (frame.vals[s.ptr.index()]) {
                    .ptr => |p| p,
                    else => return e.unsupported("internal: store to a non-pointer", .{}),
                };
                try e.storePtr(ptr, try e.scalars(frame, s.value), f.inst(s.value).ty);
                return .none;
            },
            .access => |a| {
                if (frame.vals[a.base.index()] == .mesh) return e.meshAccess(frame, frame.vals[a.base.index()].mesh, a.indices);
                if (frame.vals[a.base.index()] == .typed) {
                    var tp = frame.vals[a.base.index()].typed;
                    var path: std.ArrayList(Value) = .empty;
                    try path.appendSlice(e.arena, tp.path);
                    for (a.indices) |x| {
                        try path.append(e.arena, (try e.scalars(frame, x))[0]);
                        tp.ty = switch (e.t.get(tp.ty)) {
                            .@"struct" => |st| st.fields.items[@intCast(f.inst(x).op.constant.int)].type,
                            .array => |arr| arr.elem,
                            .vector => |v| try e.t.scalar(v.elem),
                            .matrix => |mt| try e.t.vector(mt.elem, mt.cols),
                            else => return e.unsupported("indexing this payload member is not supported yet", .{}),
                        };
                    }
                    tp.path = path.items;
                    return .{ .typed = tp };
                }
                if (frame.vals[a.base.index()] == .agg_ptr) return e.aggAccess(frame, frame.vals[a.base.index()].agg_ptr, a.indices);
                // An element of a local array of resources: of the array
                // it aliases.
                if (frame.vals[a.base.index()] == .res_local) {
                    const held = e.res_locals.items[frame.vals[a.base.index()].res_local] orelse return e.unsupported("a resource local read before it is assigned", .{});
                    if (held != .res_array) return e.unsupported("indexing this resource is not supported yet", .{});
                    return e.arrayElement(frame, held.res_array, a.indices);
                }
                if (frame.vals[a.base.index()] == .res_array) return e.arrayElement(frame, frame.vals[a.base.index()].res_array, a.indices);
                if (frame.vals[a.base.index()] == .cbuf) return e.cbufferAccess(frame, frame.vals[a.base.index()].cbuf, f.inst(a.base).ty, a.indices);
                if (frame.vals[a.base.index()] == .handle) {
                    const ri = frame.vals[a.base.index()].handle;
                    const rk = e.resources.items[ri].kind;
                    if (rk == 13 or rk == 15) return e.cbufferAccess(frame, .{ .res = ri }, e.resources.items[ri].elem, a.indices);
                    if (rk >= 1 and rk <= 10) return .{ .texel = .{ .res = ri, .coords = try e.scalars(frame, a.indices[0]) } };
                    if (rk != 12) return e.unsupported("member access into this resource is not supported yet", .{});
                    const start: @FieldType(Lowered, "buf") = .{ .res = ri, .index = (try e.scalars(frame, a.indices[0]))[0], .row_major = e.m.row_major };
                    return e.bufferAccess(frame, start, e.t.get(f.inst(a.base).ty).resource.elem, a.indices[1..]);
                }
                if (frame.vals[a.base.index()] == .buf) return e.bufferAccess(frame, frame.vals[a.base.index()].buf, f.inst(a.base).ty, a.indices);
                var ptr = switch (frame.vals[a.base.index()]) {
                    .ptr => |p| p,
                    else => return e.unsupported("access into this storage is not supported yet", .{}),
                };
                var cur = f.inst(a.base).ty;
                for (a.indices) |x| {
                    const xi = f.inst(x);
                    switch (e.t.get(cur)) {
                        .@"struct" => |st| {
                            const k: u32 = @intCast(xi.op.constant.int);
                            for (st.fields.items[0..k]) |fld| ptr.offset_const += try e.flatCount(fld.type);
                            cur = st.fields.items[k].type;
                        },
                        else => {
                            const elem: TypeId = switch (e.t.get(cur)) {
                                .array => |arr| arr.elem,
                                .vector => |v| try e.t.scalar(v.elem),
                                .matrix => |mt| try e.t.vector(mt.elem, mt.cols),
                                else => return e.unsupported("indexing this type is not supported yet", .{}),
                            };
                            const s: u32 = try e.flatCount(elem);
                            if (xi.op == .constant) {
                                ptr.offset_const += @as(u32, @intCast(xi.op.constant.int)) * s;
                            } else {
                                const idx = (try e.scalars(frame, x))[0];
                                const scaled = if (s == 1) idx else try e.add(try e.dm.intType(32), .{ .binop = .{ .op = .mul, .lhs = idx, .rhs = try e.i32Const(s) } });
                                ptr.offset_dyn = if (ptr.offset_dyn) |d| try e.add(try e.dm.intType(32), .{ .binop = .{ .op = .add, .lhs = d, .rhs = scaled } }) else scaled;
                            }
                            cur = elem;
                        },
                    }
                }
                return .{ .ptr = ptr };
            },
            .binary => |x| return e.binary(x.op, i.ty, try e.scalars(frame, x.lhs), try e.scalars(frame, x.rhs)),
            .unary => |x| {
                const v = try e.scalars(frame, x.operand);
                const c = e.compOf(i.ty);
                const ty = try e.scalarTy(c);
                const out = try e.arena.alloc(Value, v.len);
                for (v, out) |a, *o| o.* = switch (x.op) {
                    .neg => if (c.isFloat())
                        try e.add(ty, .{ .binop = .{ .op = .sub, .lhs = try e.constant(try e.t.scalar(c), .{ .float = -0.0 }), .rhs = a } })
                    else
                        try e.add(ty, .{ .binop = .{ .op = .sub, .lhs = try e.constant(try e.t.scalar(c), .{ .int = 0 }), .rhs = a } }),
                    .not => try e.add(ty, .{ .binop = .{ .op = .xor, .lhs = a, .rhs = try e.constant(try e.t.scalar(.bool), .{ .int = 1 }) } }),
                    .bit_not => try e.add(ty, .{ .binop = .{ .op = .xor, .lhs = a, .rhs = try e.constant(try e.t.scalar(c), .{ .int = -1 }) } }),
                };
                return .{ .scalars = out };
            },
            .cmp => |x| {
                const a = try e.scalars(frame, x.lhs);
                const b = try e.scalars(frame, x.rhs);
                const c = e.compOf(f.inst(x.lhs).ty);
                const pred: u32 = if (c.isFloat()) switch (x.op) {
                    .eq => 1,
                    .gt => 2,
                    .ge => 3,
                    .lt => 4,
                    .le => 5,
                    .ne => 14, // une
                } else if (c.isUnsigned() or c == .bool) switch (x.op) {
                    .eq => 32,
                    .ne => 33,
                    .gt => 34,
                    .ge => 35,
                    .lt => 36,
                    .le => 37,
                } else switch (x.op) {
                    .eq => 32,
                    .ne => 33,
                    .gt => 38,
                    .ge => 39,
                    .lt => 40,
                    .le => 41,
                };
                const bt = try e.dm.intType(1);
                const out = try e.arena.alloc(Value, a.len);
                for (a, b, out) |av, bv, *o| o.* = try e.add(bt, .{ .cmp = .{ .pred = pred, .lhs = av, .rhs = bv } });
                return .{ .scalars = out };
            },
            .convert => |x| {
                const v = try e.scalars(frame, x);
                const out = try e.arena.alloc(Value, v.len);
                for (v, out) |a, *o| o.* = try e.convertScalar(a, e.compOf(f.inst(x).ty), e.compOf(i.ty));
                return .{ .scalars = out };
            },
            .bitcast => |x| {
                const v = try e.scalars(frame, x);
                const ty = try e.scalarTy(e.compOf(i.ty));
                const out = try e.arena.alloc(Value, v.len);
                for (v, out) |a, *o| o.* = try e.add(ty, .{ .cast = .{ .op = .bitcast, .val = a } });
                return .{ .scalars = out };
            },
            .splat => |x| {
                const v = (try e.scalars(frame, x))[0];
                const out = try e.arena.alloc(Value, try e.flatCount(i.ty));
                @memset(out, v);
                return .{ .scalars = out };
            },
            .extract => |x| {
                if (frame.vals[x.agg.index()] == .agg) return e.aggExtract(frame.vals[x.agg.index()].agg, f.inst(x.agg).ty, x.index);
                const v = try e.scalars(frame, x.agg);
                const at = f.inst(x.agg).ty;
                const range = try e.componentRange(at, x.index);
                return e.list(v[range[0]..range[1]]);
            },
            .insert => |x| {
                if (e.holdsResources(i.ty)) {
                    const whole = try e.aggParts(frame.vals[x.agg.index()], i.ty);
                    const part = try e.aggParts(frame.vals[x.value.index()], f.inst(x.value).ty);
                    const vals = try e.arena.dupe(Value, whole.vals);
                    const res = try e.arena.dupe(Lowered, whole.res);
                    const dr = try e.componentRange(i.ty, x.index);
                    const rr = try e.resRange(i.ty, x.index);
                    @memcpy(vals[dr[0]..dr[1]], part.vals);
                    @memcpy(res[rr[0]..rr[1]], part.res);
                    return .{ .agg = .{ .vals = vals, .res = res } };
                }
                const v = try e.scalars(frame, x.agg);
                const out = try e.arena.dupe(Value, v);
                const range = try e.componentRange(i.ty, x.index);
                const part = try e.scalars(frame, x.value);
                @memcpy(out[range[0]..range[1]], part);
                return .{ .scalars = out };
            },
            .construct => |xs| {
                if (e.holdsResources(i.ty)) {
                    var vals: std.ArrayList(Value) = .empty;
                    var res: std.ArrayList(Lowered) = .empty;
                    for (xs) |x| {
                        const part = try e.aggParts(frame.vals[x.index()], f.inst(x).ty);
                        try vals.appendSlice(e.arena, part.vals);
                        try res.appendSlice(e.arena, part.res);
                    }
                    return .{ .agg = .{ .vals = vals.items, .res = res.items } };
                }
                var out: std.ArrayList(Value) = .empty;
                for (xs) |x| try out.appendSlice(e.arena, try e.scalars(frame, x));
                return .{ .scalars = out.items };
            },
            .shuffle => |x| {
                const v = try e.scalars(frame, x.vec);
                const out = try e.arena.alloc(Value, x.components.len);
                for (x.components, out) |c, *o| o.* = v[c];
                return .{ .scalars = out };
            },
            .select => |x| {
                const c = try e.scalars(frame, x.cond);
                const a = try e.scalars(frame, x.t);
                const b = try e.scalars(frame, x.f);
                const ty = try e.scalarTy(e.compOf(i.ty));
                const out = try e.arena.alloc(Value, a.len);
                for (a, b, out, 0..) |av, bv, *o, k| o.* = try e.add(ty, .{ .select = .{ .cond = c[if (c.len == 1) 0 else k], .t = av, .f = bv } });
                return .{ .scalars = out };
            },
            .call => |c| {
                if (e.lib_calls.get(c.func)) |func| return e.libCall(frame, c.func, func, c.args);
                const args = try e.arena.alloc(Lowered, c.args.len);
                for (c.args, args) |a, *o| o.* = frame.vals[a.index()];
                const res = try e.inlineCall(c.func, args);
                // Functions returning resources (or structs of them).
                if (isResourceType(e.t, i.ty) and !isRayQuery(e.t, i.ty)) {
                    const rr = e.last_ret_res orelse return e.unsupported("a function returning a resource with no return value", .{});
                    return rr[0];
                }
                if (e.holdsResources(i.ty)) return .{ .agg = .{ .vals = res, .res = e.last_ret_res orelse return e.unsupported("a function returning resources with no return value", .{}) } };
                return if (res.len == 0) .none else .{ .scalars = res };
            },
            .intrinsic => |c| return e.intrinsic(frame, c.name, i.ty, c.args),
            .res_load => |x| return e.resourceLoad(frame, x.res, x.index, i.ty),
            .res_store => |x| {
                try e.resourceStore(frame, x.res, x.index, x.value);
                return .none;
            },
            .method => |x| return e.method(frame, x.name, x.res, x.args, i.ty),
            .input => |k| return e.input(k, i.ty),
            .input_vertex => |x| return e.inputAt(x.element, i.ty, x.vertex),
            .emit, .cut => |stream| {
                const i8t = try e.dm.intType(8);
                const fn_i = try e.dxOp(if (i.op == .emit) "dx.op.emitStream" else "dx.op.cutStream", try e.voidTy(), &.{ try e.dm.intType(32), i8t }, .nounwind);
                _ = try e.callOp(fn_i, try e.voidTy(), &.{ try e.i32Const(if (i.op == .emit) 97 else 98), try e.dm.constant(.{ .ty = i8t, .kind = .{ .int = stream } }) });
                return .none;
            },
            .output => |o| {
                try e.output(frame, o.element, o.value);
                return .none;
            },
            .patch_input => |k| return e.patchInput(k, i.ty),
            .patch_output => |o| {
                try e.patchOutput(frame, o.element, o.value);
                return .none;
            },
            .output_vertex => |x| return e.outputControlPoint(x.element, i.ty, x.vertex),
            .phi => return e.unsupported("phi", .{}),
            .undef => return e.unsupported("undef", .{}),
        }
    }

    /// Components [start, end) of member / element / component `index`.
    // ------------------------------------------------------------------
    // Structs and arrays holding resources

    /// Resources in a value of `ty`, in flattened order.
    fn resCount(e: *Emitter, ty: TypeId) u32 {
        return switch (e.t.get(ty)) {
            .resource, .sampler => if (isRayQuery(e.t, ty)) 0 else 1,
            .array => |a| a.len * e.resCount(a.elem),
            .@"struct" => |st| blk: {
                var n: u32 = 0;
                for (st.fields.items) |f| n += e.resCount(f.type);
                break :blk n;
            },
            else => 0,
        };
    }

    fn isResourceArray(e: *Emitter, ty: TypeId) bool {
        var t = ty;
        if (e.t.get(t) != .array) return false;
        while (e.t.get(t) == .array) t = e.t.get(t).array.elem;
        return isResourceType(e.t, t) and !isRayQuery(e.t, t);
    }

    /// A struct or array with resources in it.
    fn holdsResources(e: *Emitter, ty: TypeId) bool {
        return switch (e.t.get(ty)) {
            .array, .@"struct" => e.resCount(ty) > 0,
            else => false,
        };
    }

    /// Where element / member `index`'s resources are among a value's.
    fn resRange(e: *Emitter, ty: TypeId, index: u32) Error![2]u32 {
        switch (e.t.get(ty)) {
            .array => |a| {
                const n = e.resCount(a.elem);
                return .{ index * n, (index + 1) * n };
            },
            .@"struct" => |st| {
                var start: u32 = 0;
                for (st.fields.items[0..index]) |fld| start += e.resCount(fld.type);
                return .{ start, start + e.resCount(st.fields.items[index].type) };
            },
            else => return .{ 0, 0 },
        }
    }

    /// The data and resources of a value of `ty`.
    fn aggParts(e: *Emitter, v: Lowered, ty: TypeId) Error!@FieldType(Lowered, "agg") {
        return switch (v) {
            .agg => |a| a,
            .scalars => |vals| if (e.resCount(ty) == 0) .{ .vals = vals, .res = &.{} } else e.unsupported("this value with resources is not supported yet", .{}),
            .handle, .res_array => .{ .vals = &.{}, .res = try e.arena.dupe(Lowered, &.{v}) },
            .none => .{ .vals = &.{}, .res = &.{} },
            else => e.unsupported("this value with resources is not supported yet", .{}),
        };
    }

    fn aggLocal(e: *Emitter, ty: TypeId) Error!Lowered {
        const slots = try e.arena.alloc(u32, e.resCount(ty));
        for (slots) |*sl| {
            sl.* = @intCast(e.res_locals.items.len);
            try e.res_locals.append(e.arena, null);
        }
        var data: ?*const Lowered = null;
        if (try e.flatCount(ty) > 0) {
            const d = try e.arena.create(Lowered);
            if (try e.mixedSizes(ty)) {
                const dty = try e.memoryType(ty);
                const base = try e.addPrologue(try e.dm.ptrType(dty), .{ .alloca = .{ .elem = dty, .size = try e.i32Const(1) } });
                d.* = .{ .typed = .{ .base = base, .dty = dty, .addr_space = 0, .ty = ty } };
            } else d.* = .{ .ptr = try e.alloca(ty) };
            data = d;
        }
        return .{ .agg_ptr = .{ .data = data, .slots = slots, .ty = ty } };
    }

    /// A member or element of a local holding resources.
    fn aggAccess(e: *Emitter, frame: *Frame, start: @FieldType(Lowered, "agg_ptr"), indices: []const Ref) Error!Lowered {
        var cur = start.ty;
        var slot: u32 = 0;
        var data: ?Lowered = if (start.data) |d| d.* else null;
        var path: std.ArrayList(Value) = .empty;
        if (data) |d| if (d == .typed) try path.appendSlice(e.arena, d.typed.path);
        for (indices) |x| {
            const xi = frame.f.inst(x);
            const konst: ?u32 = if (xi.op == .constant) @intCast(xi.op.constant.int) else null;
            var data_off: u32 = 0;
            var data_dyn: ?Value = null;
            switch (e.t.get(cur)) {
                .@"struct" => |st| {
                    const k = konst.?;
                    for (st.fields.items[0..k]) |fld| {
                        slot += e.resCount(fld.type);
                        data_off += try e.flatCount(fld.type);
                    }
                    cur = st.fields.items[k].type;
                },
                .array => |arr| {
                    if (e.resCount(arr.elem) > 0) {
                        const k = konst orelse return e.unsupported("dynamically indexing an array holding resources in a local is not supported yet", .{});
                        slot += k * e.resCount(arr.elem);
                        data_off = k * try e.flatCount(arr.elem);
                    } else if (konst) |k| {
                        data_off = k * try e.flatCount(arr.elem);
                    } else {
                        const idx = (try e.scalars(frame, x))[0];
                        const n = try e.flatCount(arr.elem);
                        data_dyn = if (n == 1) idx else try e.add(try e.dm.intType(32), .{ .binop = .{ .op = .mul, .lhs = idx, .rhs = try e.i32Const(n) } });
                    }
                    cur = arr.elem;
                },
                else => return e.unsupported("indexing this type is not supported yet", .{}),
            }
            if (data) |*d| switch (d.*) {
                .ptr => |*ptr| {
                    ptr.offset_const += data_off;
                    if (data_dyn) |dd| ptr.offset_dyn = if (ptr.offset_dyn) |old| try e.add(try e.dm.intType(32), .{ .binop = .{ .op = .add, .lhs = old, .rhs = dd } }) else dd;
                },
                .typed => try path.append(e.arena, (try e.scalars(frame, x))[0]),
                else => {},
            };
        }
        if (isResourceType(e.t, cur)) return .{ .res_local = start.slots[slot] };
        if (data) |*d| if (d.* == .typed) {
            d.typed.path = path.items;
            d.typed.ty = cur;
        };
        if (e.holdsResources(cur)) {
            var sub: ?*const Lowered = null;
            if (data != null and try e.flatCount(cur) > 0) {
                const p = try e.arena.create(Lowered);
                p.* = data.?;
                sub = p;
            }
            return .{ .agg_ptr = .{ .data = sub, .slots = start.slots[slot..][0..e.resCount(cur)], .ty = cur } };
        }
        return data orelse e.unsupported("this member of a local holding resources", .{});
    }

    fn aggStore(e: *Emitter, ap: @FieldType(Lowered, "agg_ptr"), v: Lowered) Error!void {
        const parts = try e.aggParts(v, ap.ty);
        if (ap.data) |d| switch (d.*) {
            .ptr => |ptr| try e.storePtr(ptr, parts.vals, ap.ty),
            .typed => |tp| try e.typedStore(tp, parts.vals, ap.ty),
            else => unreachable,
        };
        if (parts.res.len != ap.slots.len) return e.unsupported("this assignment of resources is not supported yet", .{});
        for (ap.slots, parts.res) |sl, r| {
            const slot = &e.res_locals.items[sl];
            if (slot.*) |old| if (!std.meta.eql(old, r)) return e.unsupported("assigning different resources to one variable is not supported yet", .{});
            slot.* = r;
        }
    }

    fn aggExtract(e: *Emitter, a: @FieldType(Lowered, "agg"), ty: TypeId, index: u32) Error!Lowered {
        const field: TypeId = switch (e.t.get(ty)) {
            .array => |arr| arr.elem,
            .@"struct" => |st| st.fields.items[index].type,
            else => return e.unsupported("extracting from this type is not supported yet", .{}),
        };
        const dr = try e.componentRange(ty, index);
        const rr = try e.resRange(ty, index);
        if (isResourceType(e.t, field)) return a.res[rr[0]];
        if (e.holdsResources(field)) return .{ .agg = .{ .vals = a.vals[dr[0]..dr[1]], .res = a.res[rr[0]..rr[1]] } };
        return e.list(a.vals[dr[0]..dr[1]]);
    }

    fn componentRange(e: *Emitter, ty: TypeId, index: u32) Error![2]u32 {
        switch (e.t.get(ty)) {
            .vector, .scalar => return .{ index, index + 1 },
            .matrix => |m| return .{ index * m.cols, (index + 1) * m.cols },
            .array => |a| {
                const n = try e.flatCount(a.elem);
                return .{ index * n, (index + 1) * n };
            },
            .@"struct" => |s| {
                var start: u32 = 0;
                for (s.fields.items[0..index]) |fld| start += try e.flatCount(fld.type);
                return .{ start, start + try e.flatCount(s.fields.items[index].type) };
            },
            else => return e.unsupported("extracting from this type is not supported yet", .{}),
        }
    }

    fn constant(e: *Emitter, ty: TypeId, c: ir.Constant) Error!Value {
        const s = e.compOf(ty);
        const dt = try e.scalarTy(s);
        const fv: f64 = switch (c) {
            .int => |v| @floatFromInt(v),
            .float => |v| v,
        };
        const iv: i64 = switch (c) {
            .int => |v| v,
            .float => |v| @import("../ir/lower.zig").saturatingInt(v),
        };
        return switch (s) {
            .bool => e.dm.constant(.{ .ty = dt, .kind = .{ .int = @intFromBool(iv != 0) } }),
            // Bitcode stores a float constant as its own 32-bit pattern.
            .float => e.dm.constant(.{ .ty = dt, .kind = .{ .float_bits = @as(u32, @bitCast(@as(f32, @floatCast(fv)))) } }),
            .double => e.dm.constant(.{ .ty = dt, .kind = .{ .float_bits = @bitCast(fv) } }),
            .float16 => e.dm.constant(.{ .ty = dt, .kind = .{ .float_bits = @as(u16, @bitCast(@as(f16, @floatCast(fv)))) } }),
            .uint, .uint16 => e.dm.constant(.{ .ty = dt, .kind = .{ .int = signExtend(iv, s.size()) } }),
            else => e.dm.constant(.{ .ty = dt, .kind = .{ .int = signExtend(iv, s.size()) } }),
        };
    }

    /// LLVM stores integer constants sign-extended from their width.
    fn signExtend(v: i64, bytes: u32) i64 {
        return switch (bytes) {
            2 => @as(i16, @truncate(v)),
            4 => @as(i32, @truncate(v)),
            else => v,
        };
    }

    /// Whether `ty`'s components are of several sizes (kept in struct-typed
    /// memory rather than a flat array).
    fn mixedSizes(e: *Emitter, ty: TypeId) Error!bool {
        if (e.t.get(ty) != .@"struct" and e.t.get(ty) != .array) return false;
        const n = try e.flatCount(ty);
        var size: ?u32 = null;
        for (0..n) |k| {
            const sz = memScalar(e.compOf(try e.componentType(ty, @intCast(k)))).size();
            if (size != null and size.? != sz) return true;
            size = sz;
        }
        return false;
    }

    /// Whether `ty`'s components differ in type (all 32-bit), so storage is
    /// i32 with bitcasts.
    fn mixedStorage(e: *Emitter, ty: TypeId) Error!bool {
        const n = try e.flatCount(ty);
        var first: ?Scalar = null;
        var mixed = false;
        for (0..n) |k| {
            const c = e.compOf(try e.componentType(ty, @intCast(k)));
            const mc: Scalar = if (c == .bool) .int else c;
            if (mc.size() != 4) {
                if (first != null and first.? != mc) return e.unsupported("structs mixing 32-bit and other component sizes are not supported yet", .{});
            }
            if (first != null and first.? != mc) mixed = true;
            if (first == null) first = mc;
        }
        return mixed;
    }

    fn loadPtr(e: *Emitter, ptr: Ptr, ty: TypeId) Error!Lowered {
        const n = try e.flatCount(ty);
        const out = try e.arena.alloc(Value, n);
        for (out, 0..) |*o, c| {
            if (ptr.offset_dyn == null) if (e.forwarded.get(.{ ptr.base, ptr.offset_const + @as(u32, @intCast(c)) })) |fw| if (fw.block == e.cur) {
                o.* = fw.v;
                continue;
            };
            const p = try e.elementPtr(ptr, @intCast(c));
            const raw = try e.add(ptr.scalar_ty, .{ .load = .{ .ptr = p, .@"align" = 4 } });
            const ct = e.compOf(try e.componentType(ty, @intCast(c)));
            o.* = if (ptr.bool_storage or (ptr.mixed and ct == .bool))
                try e.add(try e.dm.intType(1), .{ .cmp = .{ .pred = 33, .lhs = raw, .rhs = try e.i32Const(0) } })
            else if (ptr.mixed and ct.isFloat())
                try e.add(try e.scalarTy(ct), .{ .cast = .{ .op = .bitcast, .val = raw } })
            else
                raw;
        }
        return .{ .scalars = out };
    }

    fn storePtr(e: *Emitter, ptr: Ptr, vals: []const Value, ty: TypeId) Error!void {
        const void_ty = try e.voidTy();
        for (vals, 0..) |v, c| {
            if (ptr.offset_dyn == null) {
                const key = .{ ptr.base, ptr.offset_const + @as(u32, @intCast(c)) };
                // (Constants too, in locals: ops such as linear algebra
                // layouts need immediates passed through parameters.)
                const forward = e.status_vals.contains(v) or (v == .constant and ptr.addr_space == 0);
                if (forward) try e.forwarded.put(e.arena, key, .{ .v = v, .block = e.cur }) else _ = e.forwarded.remove(key);
            } else e.forwarded.clearRetainingCapacity();
            const p = try e.elementPtr(ptr, @intCast(c));
            const ct = e.compOf(try e.componentType(ty, @intCast(c)));
            const sv = if (ptr.bool_storage or (ptr.mixed and ct == .bool))
                try e.add(ptr.scalar_ty, .{ .cast = .{ .op = .zext, .val = v } })
            else if (ptr.mixed and ct.isFloat())
                try e.add(ptr.scalar_ty, .{ .cast = .{ .op = .bitcast, .val = v } })
            else
                v;
            _ = try e.add(void_ty, .{ .store = .{ .ptr = p, .val = sv, .@"align" = 4 } });
        }
    }

    fn elementPtr(e: *Emitter, ptr: Ptr, c: u32) Error!Value {
        var idx = try e.i32Const(ptr.offset_const + c);
        if (ptr.offset_dyn) |d| idx = try e.add(try e.dm.intType(32), .{ .binop = .{ .op = .add, .lhs = d, .rhs = idx } });
        const pt = try e.dm.getType(.{ .pointer = .{ .elem = ptr.scalar_ty, .addr_space = ptr.addr_space } });
        return e.add(pt, .{ .gep = .{ .elem = ptr.array_ty, .ptr = ptr.base, .indices = try e.arena.dupe(Value, &.{ try e.i32Const(0), idx }) } });
    }

    fn convertScalar(e: *Emitter, v: Value, from: Scalar, to: Scalar) Error!Value {
        if (from == to) return v;
        const tt = try e.scalarTy(to);
        if (to == .bool) {
            const zero = try e.constant(try e.t.scalar(from), .{ .int = 0 });
            return e.add(tt, .{ .cmp = .{ .pred = if (from.isFloat()) 14 else 33, .lhs = v, .rhs = zero } });
        }
        if (from == .bool) {
            if (to.isFloat()) return e.add(tt, .{ .cast = .{ .op = .uitofp, .val = v } });
            return e.add(tt, .{ .cast = .{ .op = .zext, .val = v } });
        }
        const op: module.CastOp = if (from.isFloat() and to.isFloat())
            (if (to.size() > from.size()) .fpext else .fptrunc)
        else if (from.isFloat())
            (if (to.isUnsigned()) .fptoui else .fptosi)
        else if (to.isFloat())
            (if (from.isUnsigned()) .uitofp else .sitofp)
        else if (to.size() == from.size())
            return v
        else if (to.size() < from.size())
            .trunc
        else if (from.isUnsigned())
            .zext
        else
            .sext;
        return e.add(tt, .{ .cast = .{ .op = op, .val = v } });
    }

    fn binary(e: *Emitter, op: ir.BinaryOp, ty: TypeId, a: []const Value, b: []const Value) Error!Lowered {
        const c = e.compOf(ty);
        const dt = try e.scalarTy(c);
        const fl = c.isFloat();
        const un = c.isUnsigned();
        const out = try e.arena.alloc(Value, a.len);
        for (a, b, out) |av, bv, *o| {
            const bop: module.BinOp = switch (op) {
                .add => .add,
                .sub => .sub,
                .mul => .mul,
                .div => if (fl) .sdiv else if (un) .udiv else .sdiv, // fdiv shares sdiv's code
                .rem => if (fl) .srem else if (un) .urem else .srem, // frem shares srem's code
                .bit_and, .log_and => .@"and",
                .bit_or, .log_or => .@"or",
                .bit_xor => .xor,
                .shl, .shr => {
                    const mask = try e.constant(try e.t.scalar(c), .{ .int = @as(i64, c.size()) * 8 - 1 });
                    const amount = try e.add(dt, .{ .binop = .{ .op = .@"and", .lhs = bv, .rhs = mask } });
                    o.* = try e.add(dt, .{ .binop = .{ .op = if (op == .shl) .shl else if (un) .lshr else .ashr, .lhs = av, .rhs = amount } });
                    continue;
                },
            };
            o.* = try e.add(dt, .{ .binop = .{ .op = bop, .lhs = av, .rhs = bv } });
        }
        return .{ .scalars = out };
    }

    // ------------------------------------------------------------------
    // Intrinsics

    fn unaryOp(e: *Emitter, opcode: i64, class: []const u8, v: Value, ty: DType) Error!Value {
        const i32t = try e.dm.intType(32);
        const name = try std.fmt.allocPrint(e.arena, "dx.op.{s}.{s}", .{ class, e.overloadName(ty) });
        const fn_i = try e.dxOp(name, ty, &.{ i32t, ty }, .nounwind_readnone);
        return e.callOp(fn_i, ty, &.{ try e.i32Const(opcode), v });
    }

    fn binaryOp(e: *Emitter, opcode: i64, a: Value, b: Value, ty: DType) Error!Value {
        const i32t = try e.dm.intType(32);
        const name = try std.fmt.allocPrint(e.arena, "dx.op.binary.{s}", .{e.overloadName(ty)});
        const fn_i = try e.dxOp(name, ty, &.{ i32t, ty, ty }, .nounwind_readnone);
        return e.callOp(fn_i, ty, &.{ try e.i32Const(opcode), a, b });
    }

    fn tertiaryOp(e: *Emitter, opcode: i64, a: Value, b: Value, c: Value, ty: DType) Error!Value {
        const i32t = try e.dm.intType(32);
        const name = try std.fmt.allocPrint(e.arena, "dx.op.tertiary.{s}", .{e.overloadName(ty)});
        const fn_i = try e.dxOp(name, ty, &.{ i32t, ty, ty, ty }, .nounwind_readnone);
        return e.callOp(fn_i, ty, &.{ try e.i32Const(opcode), a, b, c });
    }

    fn intrinsic(e: *Emitter, frame: *Frame, name: []const u8, ty: TypeId, args: []const Ref) Error!Lowered {
        const eq = std.mem.eql;
        if (try e.rayIntrinsic(frame, name, ty, args)) |r| return r;
        if (try e.outIntrinsic(frame, name, ty, args)) |r| return r;
        if (std.mem.startsWith(u8, name, "__builtin_LinAlg_")) return e.linAlg(frame, name[17..], ty, args);
        if (eq(u8, name, "DispatchMesh")) {
            const tp = switch (frame.vals[args[3].index()]) {
                .typed => |x| x,
                else => return e.unsupported("DispatchMesh with this payload is not supported yet", .{}),
            };
            const i32t = try e.dm.intType(32);
            // A member of a variable: a pointer to it.
            const dty = if (tp.path.len > 0) try e.memoryType(tp.ty) else tp.dty;
            if (e.dm.types.items[dty] != .@"struct") return e.unsupported("DispatchMesh payloads must be structs", .{});
            const pt = try e.dm.getType(.{ .pointer = .{ .elem = dty, .addr_space = tp.addr_space } });
            const ptr = if (tp.path.len == 0) tp.base else blk: {
                const idx = try e.arena.alloc(Value, tp.path.len + 1);
                idx[0] = try e.i32Const(0);
                @memcpy(idx[1..], tp.path);
                break :blk try e.add(pt, .{ .gep = .{ .elem = tp.dty, .ptr = tp.base, .indices = idx } });
            };
            const fn_i = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.dispatchMesh.{s}", .{e.dm.types.items[dty].@"struct".name}), try e.voidTy(), &.{ i32t, i32t, i32t, i32t, pt }, .nounwind);
            _ = try e.callOp(fn_i, try e.voidTy(), &.{ try e.i32Const(173), (try e.scalars(frame, args[0]))[0], (try e.scalars(frame, args[1]))[0], (try e.scalars(frame, args[2]))[0], ptr });
            return .none;
        }
        if (eq(u8, name, "SetMeshOutputCounts")) {
            const i32t = try e.dm.intType(32);
            const fn_i = try e.dxOp("dx.op.setMeshOutputCounts", try e.voidTy(), &.{ i32t, i32t, i32t }, .nounwind);
            _ = try e.callOp(fn_i, try e.voidTy(), &.{ try e.i32Const(168), (try e.scalars(frame, args[0]))[0], (try e.scalars(frame, args[1]))[0] });
            return .none;
        }
        for (args) |x| if (frame.vals[x.index()] != .scalars) return e.unsupported("intrinsic '{s}' is not supported yet", .{name});
        var a: [4][]const Value = undefined;
        for (args, 0..) |x, k| a[k] = try e.scalars(frame, x);
        const ac = if (args.len > 0) e.compOf(frame.f.inst(args[0]).ty) else e.compOf(ty);
        const rc = e.compOf(ty);
        const rt = try e.scalarTy(rc);
        const at = try e.scalarTy(ac);
        const fl = ac.isFloat();
        const n = if (args.len > 0) a[0].len else 1;
        const out = try e.arena.alloc(Value, if (ty == TypeTable.void_type) 0 else try e.flatCount(ty));
        const Unary = struct { name: []const u8, op: i64 };
        const float_unary = [_]Unary{
            .{ .name = "sqrt", .op = 24 },  .{ .name = "rsqrt", .op = 25 },   .{ .name = "sin", .op = 13 },  .{ .name = "cos", .op = 12 },
            .{ .name = "tan", .op = 14 },   .{ .name = "asin", .op = 16 },    .{ .name = "acos", .op = 15 }, .{ .name = "atan", .op = 17 },
            .{ .name = "frac", .op = 22 },  .{ .name = "floor", .op = 27 },   .{ .name = "ceil", .op = 28 }, .{ .name = "trunc", .op = 29 },
            .{ .name = "round", .op = 26 }, .{ .name = "saturate", .op = 7 }, .{ .name = "exp2", .op = 21 }, .{ .name = "log2", .op = 23 },
            .{ .name = "sinh", .op = 19 },  .{ .name = "cosh", .op = 18 },    .{ .name = "tanh", .op = 20 },
        };
        for (float_unary) |u| if (eq(u8, name, u.name) and fl) {
            for (out, 0..) |*o, k| o.* = try e.unaryOp(u.op, "unary", a[0][k], at);
            return .{ .scalars = out };
        };
        if (eq(u8, name, "abs")) {
            for (out, 0..) |*o, k| {
                if (fl) {
                    o.* = try e.unaryOp(6, "unary", a[0][k], at);
                } else if (ac.isUnsigned()) {
                    o.* = a[0][k];
                } else {
                    const neg = try e.add(at, .{ .binop = .{ .op = .sub, .lhs = try e.constant(try e.t.scalar(ac), .{ .int = 0 }), .rhs = a[0][k] } });
                    o.* = try e.binaryOp(37, a[0][k], neg, at);
                }
            }
            return .{ .scalars = out };
        }
        if (eq(u8, name, "exp") or eq(u8, name, "log")) {
            // DXIL's Exp / Log are base 2.
            const k2 = try e.constant(try e.t.scalar(ac), .{ .float = if (eq(u8, name, "exp")) 1.4426950408889634 else 0.6931471805599453 });
            for (out, 0..) |*o, k| {
                if (eq(u8, name, "exp")) {
                    const s = try e.add(at, .{ .binop = .{ .op = .mul, .lhs = a[0][k], .rhs = k2 } });
                    o.* = try e.unaryOp(21, "unary", s, at);
                } else {
                    const l = try e.unaryOp(23, "unary", a[0][k], at);
                    o.* = try e.add(at, .{ .binop = .{ .op = .mul, .lhs = l, .rhs = k2 } });
                }
            }
            return .{ .scalars = out };
        }
        if (eq(u8, name, "min") or eq(u8, name, "max")) {
            const is_max = eq(u8, name, "max");
            const op: i64 = if (fl) (if (is_max) 35 else 36) else if (ac.isUnsigned()) (if (is_max) 39 else 40) else (if (is_max) 37 else 38);
            for (out, 0..) |*o, k| o.* = try e.binaryOp(op, a[0][k], a[1][k], at);
            return .{ .scalars = out };
        }
        if (eq(u8, name, "clamp")) {
            const mx: i64 = if (fl) 35 else if (ac.isUnsigned()) 39 else 37;
            const mn: i64 = if (fl) 36 else if (ac.isUnsigned()) 40 else 38;
            for (out, 0..) |*o, k| o.* = try e.binaryOp(mn, try e.binaryOp(mx, a[0][k], a[1][k], at), a[2][k], at);
            return .{ .scalars = out };
        }
        if (eq(u8, name, "mad")) {
            const op: i64 = if (fl) 46 else if (ac.isUnsigned()) 49 else 48;
            for (out, 0..) |*o, k| o.* = try e.tertiaryOp(op, a[0][k], a[1][k], a[2][k], at);
            return .{ .scalars = out };
        }
        if (eq(u8, name, "lerp")) {
            for (out, 0..) |*o, k| {
                const d = try e.add(at, .{ .binop = .{ .op = .sub, .lhs = a[1][k], .rhs = a[0][k] } });
                const s = try e.add(at, .{ .binop = .{ .op = .mul, .lhs = a[2][k], .rhs = d } });
                o.* = try e.add(at, .{ .binop = .{ .op = .add, .lhs = a[0][k], .rhs = s } });
            }
            return .{ .scalars = out };
        }
        if (eq(u8, name, "pow")) {
            for (out, 0..) |*o, k| {
                const l = try e.unaryOp(23, "unary", a[0][k], at);
                const m = try e.add(at, .{ .binop = .{ .op = .mul, .lhs = l, .rhs = a[1][k] } });
                o.* = try e.unaryOp(21, "unary", m, at);
            }
            return .{ .scalars = out };
        }
        if (eq(u8, name, "dot") or eq(u8, name, "length") or eq(u8, name, "normalize")) {
            const b = if (eq(u8, name, "dot")) a[1] else a[0];
            const d = try e.dot(a[0], b, at, fl);
            if (eq(u8, name, "dot")) {
                out[0] = d;
            } else if (eq(u8, name, "length")) {
                out[0] = try e.unaryOp(24, "unary", d, at);
            } else {
                const inv = try e.unaryOp(25, "unary", d, at);
                for (out, 0..) |*o, k| o.* = try e.add(at, .{ .binop = .{ .op = .mul, .lhs = a[0][k], .rhs = inv } });
            }
            return .{ .scalars = out };
        }
        if (eq(u8, name, "mul") and args.len == 2) {
            // Flattened row-major: vectors on the left are rows, on the
            // right columns.
            const at0 = frame.f.inst(args[0]).ty;
            const bt0 = frame.f.inst(args[1]).ty;
            const as = e.t.shape(at0).?;
            const bs = e.t.shape(bt0).?;
            if (as.count() == 1 or bs.count() == 1) {
                const sv = if (as.count() == 1) a[0][0] else a[1][0];
                const other = if (as.count() == 1) a[1] else a[0];
                for (out, other) |*o, x| o.* = try e.add(rt, .{ .binop = .{ .op = .mul, .lhs = x, .rhs = sv } });
                return .{ .scalars = out };
            }
            const ar: u32 = if (as.kind == .vector) 1 else as.rows;
            const ak: u32 = as.cols;
            const bc: u32 = if (bs.kind == .vector) 1 else bs.cols;
            for (0..ar) |ii| for (0..bc) |j| {
                var acc: ?Value = null;
                for (0..ak) |kk| {
                    const x = a[0][ii * ak + kk];
                    const y = if (bs.kind == .vector) a[1][kk] else a[1][kk * bc + j];
                    const p = try e.add(rt, .{ .binop = .{ .op = .mul, .lhs = x, .rhs = y } });
                    acc = if (acc) |s0| try e.add(rt, .{ .binop = .{ .op = .add, .lhs = s0, .rhs = p } }) else p;
                }
                out[ii * bc + j] = acc.?;
            };
            return .{ .scalars = out };
        }
        if (eq(u8, name, "transpose")) {
            const as = e.t.shape(frame.f.inst(args[0]).ty).?;
            for (0..as.cols) |c| for (0..as.rows) |r| {
                out[c * as.rows + r] = a[0][r * as.cols + c];
            };
            return .{ .scalars = out };
        }
        if (eq(u8, name, "rcp")) {
            for (out, 0..) |*o, k| o.* = try e.add(at, .{ .binop = .{ .op = .sdiv, .lhs = try e.constant(try e.t.scalar(ac), .{ .float = 1 }), .rhs = a[0][k] } });
            return .{ .scalars = out };
        }
        if (eq(u8, name, "asuint") or eq(u8, name, "asint") or eq(u8, name, "asfloat")) {
            if (args.len != 1) return e.unsupported("intrinsic '{s}' with {d} arguments", .{ name, args.len });
            for (out, 0..) |*o, k| o.* = if (at == rt) a[0][k] else try e.add(rt, .{ .cast = .{ .op = .bitcast, .val = a[0][k] } });
            return .{ .scalars = out };
        }
        if (eq(u8, name, "countbits") or eq(u8, name, "reversebits")) {
            const op: i64 = if (eq(u8, name, "countbits")) 31 else 30;
            for (out, 0..) |*o, k| {
                const i32t = try e.dm.intType(32);
                if (op == 31) {
                    const fn_i = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.unaryBits.{s}", .{e.overloadName(at)}), i32t, &.{ i32t, at }, .nounwind_readnone);
                    o.* = try e.callOp(fn_i, i32t, &.{ try e.i32Const(op), a[0][k] });
                } else o.* = try e.unaryOp(op, "unary", a[0][k], at);
            }
            return .{ .scalars = out };
        }
        if (eq(u8, name, "CheckAccessFullyMapped")) {
            const i1t = try e.dm.intType(1);
            const i32t = try e.dm.intType(32);
            const fn_i = try e.dxOp("dx.op.checkAccessFullyMapped.i32", i1t, &.{ i32t, i32t }, .nounwind_readonly);
            out[0] = try e.callOp(fn_i, i1t, &.{ try e.i32Const(71), a[0][0] });
            e.uses_tiled_resources = true;
            return .{ .scalars = out };
        }
        if (eq(u8, name, "IsHelperLane")) {
            const i1t = try e.dm.intType(1);
            const i32t = try e.dm.intType(32);
            const fn_i = try e.dxOp("dx.op.isHelperLane.i1", i1t, &.{i32t}, .nounwind_readonly);
            out[0] = try e.callOp(fn_i, i1t, &.{try e.i32Const(221)});
            return .{ .scalars = out };
        }
        if (eq(u8, name, "firstbitlow") or eq(u8, name, "firstbithigh")) {
            const i32t = try e.dm.intType(32);
            const bits: i64 = @as(i64, ac.size()) * 8;
            for (out, 0..) |*o, k| {
                const op: i64 = if (eq(u8, name, "firstbitlow")) 32 else if (ac.isUnsigned()) 33 else 34;
                const fn_i = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.unaryBits.{s}", .{e.overloadName(at)}), i32t, &.{ i32t, at }, .nounwind_readnone);
                const r = try e.callOp(fn_i, i32t, &.{ try e.i32Const(op), a[0][k] });
                if (op == 32) {
                    o.* = r;
                    continue;
                }
                // FirstbitHi counts from the top bit; HLSL from bit 0.
                const flipped = try e.add(i32t, .{ .binop = .{ .op = .sub, .lhs = try e.i32Const(bits - 1), .rhs = r } });
                const none = try e.add(try e.dm.intType(1), .{ .cmp = .{ .pred = 32, .lhs = r, .rhs = try e.i32Const(-1) } });
                o.* = try e.select(none, try e.i32Const(-1), flipped, i32t);
            }
            return .{ .scalars = out };
        }
        if (eq(u8, name, "f32tof16") or eq(u8, name, "f16tof32")) {
            const i32t = try e.dm.intType(32);
            const ft = try e.dm.getType(.float);
            const to16 = eq(u8, name, "f32tof16");
            const fn_i = if (to16)
                try e.dxOp("dx.op.legacyF32ToF16", i32t, &.{ i32t, ft }, .nounwind_readnone)
            else
                try e.dxOp("dx.op.legacyF16ToF32", ft, &.{ i32t, i32t }, .nounwind_readnone);
            for (out, 0..) |*o, k| o.* = try e.callOp(fn_i, if (to16) i32t else ft, &.{ try e.i32Const(if (to16) 130 else 131), a[0][k] });
            return .{ .scalars = out };
        }
        if (eq(u8, name, "and") or eq(u8, name, "or")) {
            const i1t = try e.dm.intType(1);
            for (out, 0..) |*o, k| {
                const x = try e.convertScalar(a[0][if (a[0].len == 1) 0 else k], e.compOf(frame.f.inst(args[0]).ty), .bool);
                const y = try e.convertScalar(a[1][if (a[1].len == 1) 0 else k], e.compOf(frame.f.inst(args[1]).ty), .bool);
                o.* = try e.add(i1t, .{ .binop = .{ .op = if (eq(u8, name, "and")) .@"and" else .@"or", .lhs = x, .rhs = y } });
            }
            return .{ .scalars = out };
        }
        if (eq(u8, name, "select") and args.len == 3) {
            for (out, 0..) |*o, k| {
                const c = try e.convertScalar(a[0][if (a[0].len == 1) 0 else k], ac, .bool);
                const tv = a[1][if (a[1].len == 1) 0 else k];
                const fv = a[2][if (a[2].len == 1) 0 else k];
                o.* = try e.select(c, tv, fv, try e.valueType(tv));
            }
            return .{ .scalars = out };
        }
        if (eq(u8, name, "any") or eq(u8, name, "all")) {
            const i1t = try e.dm.intType(1);
            var acc: ?Value = null;
            for (0..n) |k| {
                const b = try e.convertScalar(a[0][k], ac, .bool);
                acc = if (acc) |x| try e.add(i1t, .{ .binop = .{ .op = if (eq(u8, name, "any")) .@"or" else .@"and", .lhs = x, .rhs = b } }) else b;
            }
            out[0] = acc.?;
            return .{ .scalars = out };
        }
        const barriers = [_]struct { []const u8, i64 }{
            .{ "GroupMemoryBarrierWithGroupSync", 9 }, .{ "GroupMemoryBarrier", 8 },
            .{ "AllMemoryBarrierWithGroupSync", 11 },  .{ "AllMemoryBarrier", 10 },
            .{ "DeviceMemoryBarrierWithGroupSync", 3 }, .{ "DeviceMemoryBarrier", 2 },
        };
        const barrier: ?i64 = for (barriers) |b| {
            if (eq(u8, name, b[0])) break b[1];
        } else null;
        if (barrier) |flags| {
            // Barrier flags: SyncThreadGroup 1, AccessUAVGlobal 2,
            // AccessGroupShared 8 (as dxc).
            const i32t = try e.dm.intType(32);
            const fn_i = try e.dxOp("dx.op.barrier", try e.voidTy(), &.{ i32t, i32t }, .nounwind);
            _ = try e.callOp(fn_i, try e.voidTy(), &.{ try e.i32Const(80), try e.i32Const(flags) });
            return .none;
        }
        if (try e.mathIntrinsic(name, a[0..args.len], ac, rc, out)) return .{ .scalars = out };
        if (std.mem.startsWith(u8, name, "Wave") or std.mem.startsWith(u8, name, "Quad")) {
            if (try e.waveIntrinsic(name, a[0..args.len], ac, out)) return .{ .scalars = out };
        }
        if (eq(u8, name, "NonUniformResourceIndex")) {
            try e.nonuniform.put(e.arena, a[0][0], {});
            return .{ .scalars = a[0] };
        }
        const Deriv = struct { name: []const u8, op: i64 };
        const derivs = [_]Deriv{
            .{ .name = "ddx", .op = 83 },      .{ .name = "ddx_coarse", .op = 83 }, .{ .name = "ddy", .op = 84 },
            .{ .name = "ddy_coarse", .op = 84 }, .{ .name = "ddx_fine", .op = 85 },   .{ .name = "ddy_fine", .op = 86 },
        };
        const is_deriv = eq(u8, name, "fwidth") or for (derivs) |d| {
            if (eq(u8, name, d.name)) break true;
        } else false;
        if (is_deriv) try e.checkDerivatives();
        for (derivs) |d| if (eq(u8, name, d.name)) {
            for (out, 0..) |*o, k| o.* = try e.unaryOp(d.op, "unary", a[0][k], at);
            return .{ .scalars = out };
        };
        if (eq(u8, name, "fwidth")) {
            // abs(ddx(x)) + abs(ddy(x)), coarse, as dxc.
            for (out, 0..) |*o, k| {
                const dx = try e.unaryOp(6, "unary", try e.unaryOp(83, "unary", a[0][k], at), at);
                const dy = try e.unaryOp(6, "unary", try e.unaryOp(84, "unary", a[0][k], at), at);
                o.* = try e.add(at, .{ .binop = .{ .op = .add, .lhs = dx, .rhs = dy } });
            }
            return .{ .scalars = out };
        }
        if (eq(u8, name, "clip")) {
            // discard(any(x < 0)).
            const i1t = try e.dm.intType(1);
            const zero = try e.constant(try e.t.scalar(ac), .{ .float = 0 });
            var cond: ?Value = null;
            for (a[0]) |x| {
                const lt = try e.add(i1t, .{ .cmp = .{ .pred = 4, .lhs = x, .rhs = zero } }); // fcmp olt
                cond = if (cond) |c| try e.add(i1t, .{ .binop = .{ .op = .@"or", .lhs = c, .rhs = lt } }) else lt;
            }
            const i32t = try e.dm.intType(32);
            const fn_i = try e.dxOp("dx.op.discard", try e.voidTy(), &.{ i32t, i1t }, .nounwind);
            _ = try e.callOp(fn_i, try e.voidTy(), &.{ try e.i32Const(82), cond.? });
            return .none;
        }
        return e.unsupported("intrinsic '{s}' is not supported yet", .{name});
    }

    /// The pointer an out argument was lowered to.
    fn outPtr(e: *Emitter, frame: *Frame, r: Ref) Error!Ptr {
        return switch (frame.vals[r.index()]) {
            .ptr => |p| p,
            else => e.unsupported("internal: out argument is not a pointer", .{}),
        };
    }

    /// Intrinsics with out parameters (null for the others).
    fn outIntrinsic(e: *Emitter, frame: *Frame, name: []const u8, ty: TypeId, args: []const Ref) Error!?Lowered {
        const eq = std.mem.eql;
        if (eq(u8, name, "sincos") or eq(u8, name, "modf") or eq(u8, name, "frexp")) {
            const xty = frame.f.inst(args[0]).ty;
            const xs = try e.scalars(frame, args[0]);
            const ft = try e.scalarTy(e.compOf(xty));
            const n = xs.len;
            const a1 = try e.arena.alloc(Value, n);
            const a2 = try e.arena.alloc(Value, n);
            if (eq(u8, name, "sincos")) {
                for (xs, a1, a2) |x, *sv, *cv| {
                    sv.* = try e.unaryOp(13, "unary", x, ft);
                    cv.* = try e.unaryOp(12, "unary", x, ft);
                }
                try e.storePtr(try e.outPtr(frame, args[1]), a1, frame.f.inst(args[1]).ty);
                try e.storePtr(try e.outPtr(frame, args[2]), a2, frame.f.inst(args[2]).ty);
                return .none;
            }
            if (eq(u8, name, "modf")) {
                // ip = trunc(x), result x - ip.
                for (xs, a1, a2) |x, *ip, *fr| {
                    ip.* = try e.unaryOp(29, "unary", x, ft);
                    fr.* = try e.fbin(.sub, x, ip.*, ft);
                }
                try e.storePtr(try e.outPtr(frame, args[1]), a1, frame.f.inst(args[1]).ty);
                return .{ .scalars = a2 };
            }
            // frexp, as dxc: exponent and mantissa from the bits.
            const i32t = try e.dm.intType(32);
            for (xs, a1, a2) |x, *ex, *mn| {
                const nz = try e.add(i32t, .{ .cast = .{ .op = .sext, .val = try e.fcmp(14, x, try e.constant(try e.t.scalar(.float), .{ .float = 0 })) } });
                const bitsv = try e.add(i32t, .{ .cast = .{ .op = .bitcast, .val = x } });
                var t = try e.fbin(.@"and", bitsv, try e.i32Const(0x7f800000), i32t);
                t = try e.fbin(.add, t, try e.i32Const(-0x3f000000), i32t);
                t = try e.fbin(.@"and", t, nz, i32t);
                t = try e.fbin(.ashr, t, try e.i32Const(23), i32t);
                ex.* = try e.add(ft, .{ .cast = .{ .op = .sitofp, .val = t } });
                var m = try e.fbin(.@"and", bitsv, try e.i32Const(0x007fffff), i32t);
                m = try e.fbin(.@"or", m, try e.i32Const(0x3f000000), i32t);
                m = try e.fbin(.@"and", m, nz, i32t);
                mn.* = try e.add(ft, .{ .cast = .{ .op = .bitcast, .val = m } });
            }
            try e.storePtr(try e.outPtr(frame, args[1]), a1, frame.f.inst(args[1]).ty);
            _ = ty;
            return .{ .scalars = a2 };
        }
        if (std.mem.startsWith(u8, name, "Interlocked")) return try e.atomic(frame, name, args);
        if (eq(u8, name, "asuint") and args.len == 3) {
            // SplitDouble.
            const i32t = try e.dm.intType(32);
            const f64t = try e.dm.getType(.double);
            e.uses_double = true;
            const st = try e.dm.getType(.{ .@"struct" = .{ .name = "dx.types.splitdouble", .elems = &.{ i32t, i32t } } });
            const fn_i = try e.dxOp("dx.op.splitDouble.f64", st, &.{ i32t, f64t }, .nounwind_readnone);
            const ds = try e.scalars(frame, args[0]);
            const lo = try e.arena.alloc(Value, ds.len);
            const hi = try e.arena.alloc(Value, ds.len);
            for (ds, lo, hi) |d, *l, *h| {
                const r = try e.callOp(fn_i, st, &.{ try e.i32Const(102), d });
                l.* = try e.add(i32t, .{ .extractvalue = .{ .agg = r, .index = 0 } });
                h.* = try e.add(i32t, .{ .extractvalue = .{ .agg = r, .index = 1 } });
            }
            try e.storePtr(try e.outPtr(frame, args[1]), lo, frame.f.inst(args[1]).ty);
            try e.storePtr(try e.outPtr(frame, args[2]), hi, frame.f.inst(args[2]).ty);
            return .none;
        }
        return null;
    }

    /// Interlocked*(dest, value(s) [, out original]) on groupshared memory,
    /// buffer elements and texels.
    fn atomic(e: *Emitter, frame: *Frame, name: []const u8, args: []const Ref) Error!Lowered {
        const eq = std.mem.eql;
        const op_name = name["Interlocked".len..];
        const dest_ty = frame.f.inst(args[0]).ty;
        const dc = e.compOf(dest_ty);
        if (dc.size() != 4 or dc.isFloat()) return e.unsupported("'{s}' on '{s}' is not supported yet", .{ name, try e.t.format(e.arena, dest_ty) });
        const i32t = try e.dm.intType(32);
        const is_cmp = std.mem.startsWith(u8, op_name, "Compare");
        const has_orig = (is_cmp and eq(u8, op_name, "CompareExchange")) or (!is_cmp and args.len == 3);
        const val = (try e.scalars(frame, args[if (is_cmp) 2 else 1]))[0];
        const cmp = if (is_cmp) (try e.scalars(frame, args[1]))[0] else null;
        const orig: Value = switch (frame.vals[args[0].index()]) {
            .ptr => |p| blk: {
                if (p.addr_space != 3) return e.unsupported("'{s}' on this variable is not supported yet", .{name});
                const ptr = try e.elementPtr(p, 0);
                if (cmp) |cv| {
                    const pair = try e.dm.getType(.{ .@"struct" = .{ .name = "", .elems = &.{ i32t, try e.dm.intType(1) } } });
                    const r = try e.add(pair, .{ .cmpxchg = .{ .ptr = ptr, .cmp = cv, .new = val } });
                    break :blk try e.add(i32t, .{ .extractvalue = .{ .agg = r, .index = 0 } });
                }
                const rmw: module.RmwOp = if (eq(u8, op_name, "Add")) .add else if (eq(u8, op_name, "And")) .@"and" else if (eq(u8, op_name, "Or")) .@"or" else if (eq(u8, op_name, "Xor")) .xor else if (eq(u8, op_name, "Min")) (if (dc.isUnsigned()) .umin else .min) else if (eq(u8, op_name, "Max")) (if (dc.isUnsigned()) .umax else .max) else if (eq(u8, op_name, "Exchange")) .xchg else return e.unsupported("'{s}' is not supported yet", .{name});
                break :blk try e.add(i32t, .{ .atomicrmw = .{ .op = rmw, .ptr = ptr, .val = val } });
            },
            .buf => |b| blk: {
                const res = e.resources.items[b.res];
                var off = try e.i32Const(b.offset);
                if (b.dyn) |d| off = try e.add(i32t, .{ .binop = .{ .op = .add, .lhs = d, .rhs = off } });
                break :blk try e.resourceAtomic(res, &.{ b.index, off }, op_name, dc, val, cmp);
            },
            .texel => |tx| try e.resourceAtomic(e.resources.items[tx.res], tx.coords, op_name, dc, val, cmp),
            else => return e.unsupported("'{s}' on this destination is not supported yet", .{name}),
        };
        if (has_orig) try e.storePtr(try e.outPtr(frame, args[args.len - 1]), &.{orig}, frame.f.inst(args[args.len - 1]).ty);
        return .none;
    }

    /// dx.op.atomicBinOp / atomicCompareExchange at `coords` (padded with
    /// undef to three).
    fn resourceAtomic(e: *Emitter, res: Resource, coords: []const Value, op_name: []const u8, dc: Scalar, val: Value, cmp: ?Value) Error!Value {
        const eq = std.mem.eql;
        const i32t = try e.dm.intType(32);
        const c = try e.padded(coords, coords.len, 3, i32t);
        if (cmp) |cv| {
            const fn_i = try e.dxOp("dx.op.atomicCompareExchange.i32", i32t, &.{ i32t, e.handle_ty, i32t, i32t, i32t, i32t, i32t }, .nounwind);
            return e.callOp(fn_i, i32t, &.{ try e.i32Const(79), res.handle, c[0], c[1], c[2], cv, val });
        }
        const op: i64 = if (eq(u8, op_name, "Add")) 0 else if (eq(u8, op_name, "And")) 1 else if (eq(u8, op_name, "Or")) 2 else if (eq(u8, op_name, "Xor")) 3 else if (eq(u8, op_name, "Min")) (if (dc.isUnsigned()) 6 else 4) else if (eq(u8, op_name, "Max")) (if (dc.isUnsigned()) 7 else 5) else if (eq(u8, op_name, "Exchange")) 8 else return e.unsupported("'Interlocked{s}' is not supported yet", .{op_name});
        const fn_i = try e.dxOp("dx.op.atomicBinOp.i32", i32t, &.{ i32t, e.handle_ty, i32t, i32t, i32t, i32t, i32t }, .nounwind);
        return e.callOp(fn_i, i32t, &.{ try e.i32Const(78), res.handle, try e.i32Const(op), c[0], c[1], c[2], val });
    }

    /// Wave and quad intrinsics (component-wise on vectors).
    fn waveIntrinsic(e: *Emitter, name: []const u8, a: []const []const Value, ac: Scalar, out: []Value) Error!bool {
        const eq = std.mem.eql;
        const i32t = try e.dm.intType(32);
        const i1t = try e.dm.intType(1);
        const i8t = try e.dm.intType(8);
        const at = try e.scalarTy(ac);
        e.uses_wave = true;
        const i8c = struct {
            fn f(em: *Emitter, v: i64) Error!Value {
                return em.dm.constant(.{ .ty = try em.dm.intType(8), .kind = .{ .int = v } });
            }
        }.f;
        const Nullary = struct { name: []const u8, op: i64, fname: []const u8, ret_bool: bool };
        for ([_]Nullary{
            .{ .name = "WaveIsFirstLane", .op = 110, .fname = "dx.op.waveIsFirstLane", .ret_bool = true },
            .{ .name = "WaveGetLaneIndex", .op = 111, .fname = "dx.op.waveGetLaneIndex", .ret_bool = false },
            .{ .name = "WaveGetLaneCount", .op = 112, .fname = "dx.op.waveGetLaneCount", .ret_bool = false },
        }) |w| if (eq(u8, name, w.name)) {
            const rt = if (w.ret_bool) i1t else i32t;
            out[0] = try e.callOp(try e.dxOp(w.fname, rt, &.{i32t}, .nounwind), rt, &.{try e.i32Const(w.op)});
            return true;
        };
        // Bool reductions over the wave.
        const BoolOp = struct { name: []const u8, op: i64, fname: []const u8, ret: enum { bool, int } };
        for ([_]BoolOp{
            .{ .name = "WaveActiveAnyTrue", .op = 113, .fname = "dx.op.waveAnyTrue", .ret = .bool },
            .{ .name = "WaveActiveAllTrue", .op = 114, .fname = "dx.op.waveAllTrue", .ret = .bool },
            .{ .name = "WaveActiveCountBits", .op = 135, .fname = "dx.op.waveAllOp", .ret = .int },
            .{ .name = "WavePrefixCountBits", .op = 136, .fname = "dx.op.wavePrefixOp", .ret = .int },
        }) |w| if (eq(u8, name, w.name)) {
            const rt = if (w.ret == .bool) i1t else i32t;
            out[0] = try e.callOp(try e.dxOp(w.fname, rt, &.{ i32t, i1t }, .nounwind), rt, &.{ try e.i32Const(w.op), a[0][0] });
            return true;
        };
        if (eq(u8, name, "WaveActiveBallot")) {
            const st = try e.dm.getType(.{ .@"struct" = .{ .name = "dx.types.fouri32", .elems = &.{ i32t, i32t, i32t, i32t } } });
            const r = try e.callOp(try e.dxOp("dx.op.waveActiveBallot", st, &.{ i32t, i1t }, .nounwind), st, &.{ try e.i32Const(116), a[0][0] });
            for (out, 0..) |*o, k| o.* = try e.add(i32t, .{ .extractvalue = .{ .agg = r, .index = @intCast(k) } });
            return true;
        }
        const ovl = e.overloadName(at);
        const sign: i64 = if (ac.isUnsigned()) 1 else 0;
        // Component-wise operations on values.
        const Op = struct { name: []const u8, op: i64, fname: []const u8, extra: []const i64 = &.{}, lane: bool = false, ret_bool: bool = false, signed: bool = false };
        const ops = [_]Op{
            .{ .name = "WaveActiveAllEqual", .op = 115, .fname = "waveActiveAllEqual", .ret_bool = true },
            .{ .name = "WaveReadLaneAt", .op = 117, .fname = "waveReadLaneAt", .lane = true },
            .{ .name = "WaveReadLaneFirst", .op = 118, .fname = "waveReadLaneFirst" },
            .{ .name = "WaveActiveSum", .op = 119, .fname = "waveActiveOp", .extra = &.{0}, .signed = true },
            .{ .name = "WaveActiveProduct", .op = 119, .fname = "waveActiveOp", .extra = &.{1}, .signed = true },
            .{ .name = "WaveActiveMin", .op = 119, .fname = "waveActiveOp", .extra = &.{2}, .signed = true },
            .{ .name = "WaveActiveMax", .op = 119, .fname = "waveActiveOp", .extra = &.{3}, .signed = true },
            .{ .name = "WaveActiveBitAnd", .op = 120, .fname = "waveActiveBit", .extra = &.{0} },
            .{ .name = "WaveActiveBitOr", .op = 120, .fname = "waveActiveBit", .extra = &.{1} },
            .{ .name = "WaveActiveBitXor", .op = 120, .fname = "waveActiveBit", .extra = &.{2} },
            .{ .name = "WavePrefixSum", .op = 121, .fname = "wavePrefixOp", .extra = &.{0}, .signed = true },
            .{ .name = "WavePrefixProduct", .op = 121, .fname = "wavePrefixOp", .extra = &.{1}, .signed = true },
            .{ .name = "QuadReadLaneAt", .op = 122, .fname = "quadReadLaneAt", .lane = true },
            .{ .name = "QuadReadAcrossX", .op = 123, .fname = "quadOp", .extra = &.{0} },
            .{ .name = "QuadReadAcrossY", .op = 123, .fname = "quadOp", .extra = &.{1} },
            .{ .name = "QuadReadAcrossDiagonal", .op = 123, .fname = "quadOp", .extra = &.{2} },
        };
        for (ops) |w| if (eq(u8, name, w.name)) {
            var params: std.ArrayList(DType) = .empty;
            try params.appendSlice(e.arena, &.{ i32t, at });
            if (w.lane) try params.append(e.arena, i32t);
            for (w.extra) |_| try params.append(e.arena, i8t);
            if (w.signed) try params.append(e.arena, i8t);
            const rt = if (w.ret_bool) i1t else at;
            const fn_i = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.{s}.{s}", .{ w.fname, ovl }), rt, params.items, .nounwind);
            for (out, 0..) |*o, k| {
                var args: std.ArrayList(Value) = .empty;
                try args.appendSlice(e.arena, &.{ try e.i32Const(w.op), a[0][k] });
                if (w.lane) try args.append(e.arena, a[1][0]);
                for (w.extra) |x| try args.append(e.arena, try i8c(e, x));
                if (w.signed) try args.append(e.arena, try i8c(e, sign));
                o.* = try e.callOp(fn_i, rt, args.items);
            }
            return true;
        };
        if (eq(u8, name, "QuadAny") or eq(u8, name, "QuadAll")) {
            const fn_i = try e.dxOp("dx.op.quadVote.i1", i1t, &.{ i32t, i1t, i8t }, .nounwind);
            out[0] = try e.callOp(fn_i, i1t, &.{ try e.i32Const(222), a[0][0], try i8c(e, if (eq(u8, name, "QuadAll")) 1 else 0) });
            return true;
        }
        return false;
    }

    fn fbin(e: *Emitter, op: module.BinOp, x: Value, y: Value, ty: DType) Error!Value {
        return e.add(ty, .{ .binop = .{ .op = op, .lhs = x, .rhs = y } });
    }

    fn fcmp(e: *Emitter, pred: u32, x: Value, y: Value) Error!Value {
        return e.add(try e.dm.intType(1), .{ .cmp = .{ .pred = pred, .lhs = x, .rhs = y } });
    }

    fn select(e: *Emitter, cond: Value, t: Value, f: Value, ty: DType) Error!Value {
        return e.add(ty, .{ .select = .{ .cond = cond, .t = t, .f = f } });
    }

    /// Math intrinsics built from arithmetic (as dxc's HLOperationLower);
    /// false if `name` is not one of them.
    fn mathIntrinsic(e: *Emitter, name: []const u8, a: []const []const Value, ac: Scalar, rc: Scalar, out: []Value) Error!bool {
        const eq = std.mem.eql;
        if (!ac.isFloat() and !eq(u8, name, "sign")) return false;
        const at = try e.scalarTy(ac);
        const fk = try e.t.scalar(ac);
        const fc = struct {
            fn f(em: *Emitter, k: TypeId, v: f64) Error!Value {
                return em.constant(k, .{ .float = v });
            }
        }.f;
        const zero = try fc(e, fk, 0);
        const one = try fc(e, fk, 1);
        // LLVM fcmp predicates.
        const oeq = 1;
        const ogt = 2;
        const oge = 3;
        const olt = 4;
        if (eq(u8, name, "atan2")) {
            const pi = std.math.pi;
            for (out, a[0], a[1]) |*o, y, x| {
                const atan = try e.unaryOp(17, "unary", try e.fbin(.sdiv, y, x, at), at);
                const add_pi = try e.fbin(.add, atan, try fc(e, fk, pi), at);
                const sub_pi = try e.fbin(.sub, atan, try fc(e, fk, pi), at);
                const x_lt0 = try e.fcmp(olt, x, zero);
                const x_eq0 = try e.fcmp(oeq, x, zero);
                const y_ge0 = try e.fcmp(oge, y, zero);
                const y_lt0 = try e.fcmp(olt, y, zero);
                const i1t = try e.dm.intType(1);
                var r = try e.select(try e.fbin(.@"and", x_lt0, y_ge0, i1t), add_pi, atan, at);
                r = try e.select(try e.fbin(.@"and", x_lt0, y_lt0, i1t), sub_pi, r, at);
                r = try e.select(try e.fbin(.@"and", x_eq0, y_lt0, i1t), try fc(e, fk, -pi / 2.0), r, at);
                o.* = try e.select(try e.fbin(.@"and", x_eq0, y_ge0, i1t), try fc(e, fk, pi / 2.0), r, at);
            }
        } else if (eq(u8, name, "fmod")) {
            const neg_zero = try fc(e, fk, -0.0);
            for (out, a[0], a[1]) |*o, x, y| {
                const div = try e.fbin(.sdiv, x, y, at);
                const ge = try e.fcmp(oge, div, try e.fbin(.sub, neg_zero, div, at));
                const frc = try e.unaryOp(22, "unary", try e.unaryOp(6, "unary", div, at), at);
                const real = try e.select(ge, frc, try e.fbin(.sub, neg_zero, frc, at), at);
                o.* = try e.fbin(.mul, real, y, at);
            }
        } else if (eq(u8, name, "isnan") or eq(u8, name, "isinf") or eq(u8, name, "isfinite") or eq(u8, name, "isnormal")) {
            const op: i64 = if (eq(u8, name, "isnan")) 8 else if (eq(u8, name, "isinf")) 9 else if (eq(u8, name, "isfinite")) 10 else 11;
            const i1t = try e.dm.intType(1);
            const i32t = try e.dm.intType(32);
            if (e.dm.types.items[at] == .half and e.profile.minor < 9) {
                // 16-bit overloads need SM 6.9: test the bits (as dxc).
                const i16t = try e.dm.intType(16);
                const k = struct {
                    fn f(em: *Emitter, v: i64) Error!Value {
                        return em.dm.constInt(16, v);
                    }
                }.f;
                for (out, a[0]) |*o, x| {
                    const bits = try e.add(i16t, .{ .cast = .{ .op = .bitcast, .val = x } });
                    const r = switch (op) {
                        9 => try e.fbin(.@"or", try e.add(i1t, .{ .cmp = .{ .pred = 32, .lhs = bits, .rhs = try k(e, 0x7c00) } }), try e.add(i1t, .{ .cmp = .{ .pred = 32, .lhs = bits, .rhs = try k(e, -1024) } }), i1t),
                        8 => blk: {
                            const ex = try e.fbin(.@"and", bits, try k(e, 0x7c00), i16t);
                            const is_ex = try e.add(i1t, .{ .cmp = .{ .pred = 32, .lhs = ex, .rhs = try k(e, 0x7c00) } });
                            const man = try e.fbin(.@"and", bits, try k(e, 0x3ff), i16t);
                            const nz = try e.add(i1t, .{ .cmp = .{ .pred = 33, .lhs = man, .rhs = try k(e, 0) } });
                            break :blk try e.fbin(.@"and", is_ex, nz, i1t);
                        },
                        10 => try e.add(i1t, .{ .cmp = .{ .pred = 33, .lhs = try e.fbin(.@"and", bits, try k(e, 0x7c00), i16t), .rhs = try k(e, 0x7c00) } }),
                        else => blk: {
                            const ex = try e.fbin(.@"and", bits, try k(e, 0x7c00), i16t);
                            const nz = try e.add(i1t, .{ .cmp = .{ .pred = 33, .lhs = ex, .rhs = try k(e, 0) } });
                            const ninf = try e.add(i1t, .{ .cmp = .{ .pred = 33, .lhs = ex, .rhs = try k(e, 0x7c00) } });
                            break :blk try e.fbin(.@"and", nz, ninf, i1t);
                        },
                    };
                    o.* = try e.convertScalar(r, .bool, rc);
                }
            } else {
                const fn_i = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.isSpecialFloat.{s}", .{e.overloadName(at)}), i1t, &.{ i32t, at }, .nounwind_readnone);
                for (out, a[0]) |*o, x| o.* = try e.convertScalar(try e.callOp(fn_i, i1t, &.{ try e.i32Const(op), x }), .bool, rc);
            }
        } else if (eq(u8, name, "sign")) {
            const i32t = try e.dm.intType(32);
            const z = try e.constant(fk, if (ac.isFloat()) .{ .float = 0 } else .{ .int = 0 });
            const gt_pred: u32 = if (ac.isFloat()) ogt else if (ac.isUnsigned()) 34 else 38;
            const lt_pred: u32 = if (ac.isFloat()) olt else if (ac.isUnsigned()) 36 else 40;
            for (out, a[0]) |*o, x| {
                const gt = try e.add(i32t, .{ .cast = .{ .op = .zext, .val = try e.fcmp(gt_pred, x, z) } });
                const lt = try e.add(i32t, .{ .cast = .{ .op = .zext, .val = try e.fcmp(lt_pred, x, z) } });
                o.* = try e.convertScalar(try e.fbin(.sub, gt, lt, i32t), .int, rc);
            }
        } else if (eq(u8, name, "step")) {
            for (out, a[0], a[1]) |*o, edge, x| o.* = try e.select(try e.fcmp(olt, x, edge), zero, one, at);
        } else if (eq(u8, name, "smoothstep")) {
            for (out, a[0], a[1], a[2]) |*o, lo, hi, x| {
                const t = try e.unaryOp(7, "unary", try e.fbin(.sdiv, try e.fbin(.sub, x, lo, at), try e.fbin(.sub, hi, lo, at), at), at);
                const s = try e.fbin(.sub, try fc(e, fk, 3), try e.fbin(.mul, try fc(e, fk, 2), t, at), at);
                o.* = try e.fbin(.mul, try e.fbin(.mul, t, t, at), s, at);
            }
        } else if (eq(u8, name, "degrees") or eq(u8, name, "radians")) {
            const k = try fc(e, fk, if (eq(u8, name, "degrees")) 180.0 / std.math.pi else std.math.pi / 180.0);
            for (out, a[0]) |*o, x| o.* = try e.fbin(.mul, x, k, at);
        } else if (eq(u8, name, "ldexp")) {
            for (out, a[0], a[1]) |*o, x, p| o.* = try e.fbin(.mul, x, try e.unaryOp(21, "unary", p, at), at);
        } else if (eq(u8, name, "distance")) {
            const d = try e.arena.alloc(Value, a[0].len);
            for (d, a[0], a[1]) |*o, x, y| o.* = try e.fbin(.sub, x, y, at);
            out[0] = try e.unaryOp(24, "unary", try e.dot(d, d, at, true), at);
        } else if (eq(u8, name, "reflect")) {
            // i - 2 * dot(n, i) * n
            const d2 = try e.fbin(.mul, try fc(e, fk, 2), try e.dot(a[1], a[0], at, true), at);
            for (out, a[0], a[1]) |*o, i, n| o.* = try e.fbin(.sub, i, try e.fbin(.mul, d2, n, at), at);
        } else if (eq(u8, name, "refract")) {
            // k = 1 - eta^2 (1 - dot(n, i)^2); k < 0 ? 0 : eta i - (eta dot(n, i) + sqrt(k)) n
            const eta = a[2][0];
            const d = try e.dot(a[1], a[0], at, true);
            const k = try e.fbin(.sub, one, try e.fbin(.mul, try e.fbin(.mul, eta, eta, at), try e.fbin(.sub, one, try e.fbin(.mul, d, d, at), at), at), at);
            const neg = try e.fcmp(olt, k, zero);
            const s = try e.fbin(.add, try e.fbin(.mul, eta, d, at), try e.unaryOp(24, "unary", k, at), at);
            for (out, a[0], a[1]) |*o, i, n| {
                const r = try e.fbin(.sub, try e.fbin(.mul, eta, i, at), try e.fbin(.mul, s, n, at), at);
                o.* = try e.select(neg, zero, r, at);
            }
        } else if (eq(u8, name, "faceforward")) {
            // dot(i, ng) < 0 ? n : -n
            const neg = try e.fcmp(olt, try e.dot(a[1], a[2], at, true), zero);
            const neg_zero = try fc(e, fk, -0.0);
            for (out, a[0]) |*o, n| o.* = try e.select(neg, n, try e.fbin(.sub, neg_zero, n, at), at);
        } else if (eq(u8, name, "cross")) {
            const x = a[0];
            const y = a[1];
            for (out, 0..) |*o, k| {
                const p = (k + 1) % 3;
                const q = (k + 2) % 3;
                o.* = try e.fbin(.sub, try e.fbin(.mul, x[p], y[q], at), try e.fbin(.mul, x[q], y[p], at), at);
            }
        } else if (eq(u8, name, "determinant")) {
            const n = std.math.sqrt(a[0].len);
            if (n * n != a[0].len or n < 1 or n > 4) return false;
            out[0] = try e.determinant(a[0], n, at);
        } else return false;
        return true;
    }

    /// Determinant of an n x n matrix (row-major components), by cofactor
    /// expansion along the first row.
    fn determinant(e: *Emitter, m: []const Value, n: usize, ty: DType) Error!Value {
        if (n == 1) return m[0];
        if (n == 2) return e.fbin(.sub, try e.fbin(.mul, m[0], m[3], ty), try e.fbin(.mul, m[1], m[2], ty), ty);
        var acc: ?Value = null;
        var minor: [9]Value = undefined;
        for (0..n) |c| {
            var k: usize = 0;
            for (1..n) |r| for (0..n) |cc| if (cc != c) {
                minor[k] = m[r * n + cc];
                k += 1;
            };
            const term = try e.fbin(.mul, m[c], try e.determinant(minor[0..k], n - 1, ty), ty);
            acc = if (acc) |s| try e.fbin(if (c % 2 == 0) .add else .sub, s, term, ty) else term;
        }
        return acc.?;
    }

    fn dot(e: *Emitter, a: []const Value, b: []const Value, ty: DType, fl: bool) Error!Value {
        if (fl and a.len >= 2 and a.len <= 4) {
            const i32t = try e.dm.intType(32);
            const name = try std.fmt.allocPrint(e.arena, "dx.op.dot{d}.{s}", .{ a.len, e.overloadName(ty) });
            var params: std.ArrayList(DType) = .empty;
            try params.append(e.arena, i32t);
            for (0..a.len * 2) |_| try params.append(e.arena, ty);
            const fn_i = try e.dxOp(name, ty, params.items, .nounwind_readnone);
            var args: std.ArrayList(Value) = .empty;
            try args.append(e.arena, try e.i32Const(@as(i64, 52) + @as(i64, @intCast(a.len))));
            try args.appendSlice(e.arena, a);
            try args.appendSlice(e.arena, b);
            return e.callOp(fn_i, ty, args.items);
        }
        var acc = try e.add(ty, .{ .binop = .{ .op = .mul, .lhs = a[0], .rhs = b[0] } });
        for (a[1..], b[1..]) |x, y| {
            const p = try e.add(ty, .{ .binop = .{ .op = .mul, .lhs = x, .rhs = y } });
            acc = try e.add(ty, .{ .binop = .{ .op = .add, .lhs = acc, .rhs = p } });
        }
        return acc;
    }

    // ------------------------------------------------------------------
    // Constant buffers

    fn cbufferSize(e: *Emitter, res: Resource) Error!i64 {
        return layout.sizeOf(e.t, res.elem, false, .dx_legacy) catch e.unsupported("constant buffer '{s}' contains types that are not supported yet", .{try e.t.format(e.arena, res.elem)});
    }

    /// Byte offset of a member / element inside a constant buffer.
    fn cbufferAccess(e: *Emitter, frame: *Frame, start: @FieldType(Lowered, "cbuf"), base_ty: TypeId, indices: []const Ref) Error!Lowered {
        var c = start;
        var cur = base_ty;
        for (indices) |x| {
            const xi = frame.f.inst(x);
            switch (e.t.get(cur)) {
                .@"struct" => |st| {
                    const k: u32 = @intCast(xi.op.constant.int);
                    const offs = layout.fieldOffsets(e.arena, e.t, st, .dx_legacy) catch return e.unsupported("constant buffer member types", .{});
                    c.offset += offs[k];
                    c.row_major = st.fields.items[k].row_major;
                    cur = st.fields.items[k].type;
                },
                .array => |arr| {
                    const stride_b = layout.arrayStride(e.t, arr.elem, c.row_major, .dx_legacy) catch return e.unsupported("constant buffer array element types", .{});
                    if (xi.op == .constant) {
                        c.offset += @as(u32, @intCast(xi.op.constant.int)) * stride_b;
                    } else {
                        const i32t = try e.dm.intType(32);
                        const idx = (try e.scalars(frame, x))[0];
                        const regs = if (stride_b == 16) idx else try e.add(i32t, .{ .binop = .{ .op = .mul, .lhs = idx, .rhs = try e.i32Const(stride_b / 16) } });
                        c.dyn_regs = if (c.dyn_regs) |d| try e.add(i32t, .{ .binop = .{ .op = .add, .lhs = d, .rhs = regs } }) else regs;
                    }
                    cur = arr.elem;
                },
                .vector => |v| {
                    if (xi.op != .constant) return e.unsupported("dynamic indexing of constant buffer vectors", .{});
                    c.offset += @as(u32, @intCast(xi.op.constant.int)) * storageScalar(v.elem).size();
                    cur = try e.t.scalar(v.elem);
                },
                .matrix => |mt| {
                    if (xi.op != .constant) return e.unsupported("dynamic indexing of constant buffer matrices", .{});
                    if (!c.row_major) return e.unsupported("row access into column-major constant buffer matrices", .{});
                    c.offset += @as(u32, @intCast(xi.op.constant.int)) * 16;
                    cur = try e.t.vector(mt.elem, mt.cols);
                },
                else => return e.unsupported("indexing this constant buffer member", .{}),
            }
        }
        return .{ .cbuf = c };
    }

    fn cbufferLoad(e: *Emitter, ri: u32, offset: u32, dyn_regs: ?Value, row_major: bool, ty: TypeId) Error!Lowered {
        const res = e.resources.items[ri];
        const n = try e.flatCount(ty);
        const out = try e.arena.alloc(Value, n);
        const i32t = try e.dm.intType(32);
        var cache_reg: ?u32 = null;
        var cache_val: Value = undefined;
        var cache_st: DType = 0;
        for (out, 0..) |*o, k| {
            const comp_ty = try e.componentType(ty, @intCast(k));
            const c = e.compOf(comp_ty);
            const mem_c: Scalar = if (c == .bool) .uint else c;
            // A register holds 16 bytes: 4 32-bit, 2 64-bit or 8 16-bit values.
            const sz = mem_c.size();
            const off = offset + (layout.componentOffset(e.arena, e.t, ty, row_major, @intCast(k), .dx_legacy) catch return e.unsupported("constant buffer member types", .{}));
            const reg = off / 16;
            const st = try e.scalarTy(mem_c);
            if (res.kind == 15) {
                // tbuffer: whole registers as i32 (bufferLoad).
                if (sz != 4 and sz != 8) return e.unsupported("16-bit tbuffer members are not supported yet", .{});
                if (cache_reg == null or cache_reg.? != reg) {
                    const it = try e.scalarTy(.uint);
                    const rt = try e.resRetType(it);
                    const fn_i = try e.dxOp("dx.op.bufferLoad.i32", rt, &.{ i32t, e.handle_ty, i32t, i32t }, .nounwind_readonly);
                    var reg_v = try e.i32Const(reg);
                    if (dyn_regs) |d| reg_v = try e.add(i32t, .{ .binop = .{ .op = .add, .lhs = d, .rhs = reg_v } });
                    cache_val = try e.callOp(fn_i, rt, &.{ try e.i32Const(68), res.handle, reg_v, try e.dm.constant(.{ .ty = i32t, .kind = .undef }) });
                    cache_reg = reg;
                }
                const it = try e.scalarTy(.uint);
                const w0 = try e.add(it, .{ .extractvalue = .{ .agg = cache_val, .index = (off % 16) / 4 } });
                const v = if (sz == 8)
                    try e.joinWords(w0, try e.add(it, .{ .extractvalue = .{ .agg = cache_val, .index = (off % 16) / 4 + 1 } }), mem_c)
                else if (mem_c.isFloat())
                    try e.add(st, .{ .cast = .{ .op = .bitcast, .val = w0 } })
                else
                    w0;
                o.* = if (c == .bool) try e.convertScalar(v, .uint, .bool) else v;
                continue;
            }
            if (cache_reg == null or cache_reg.? != reg or cache_st != st) {
                const ret_name = try std.fmt.allocPrint(e.arena, "dx.types.CBufRet.{s}{s}", .{ e.overloadName(st), if (sz == 2) ".8" else "" });
                const elems: []const DType = switch (sz) {
                    8 => &.{ st, st },
                    2 => &.{ st, st, st, st, st, st, st, st },
                    else => &.{ st, st, st, st },
                };
                const ret_ty = try e.dm.getType(.{ .@"struct" = .{ .name = ret_name, .elems = try e.arena.dupe(DType, elems) } });
                const fn_i = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.cbufferLoadLegacy.{s}", .{e.overloadName(st)}), ret_ty, &.{ i32t, e.handle_ty, i32t }, .nounwind_readonly);
                var reg_v = try e.i32Const(reg);
                if (dyn_regs) |d| reg_v = try e.add(i32t, .{ .binop = .{ .op = .add, .lhs = d, .rhs = reg_v } });
                cache_val = try e.callOp(fn_i, ret_ty, &.{ try e.i32Const(59), res.handle, reg_v });
                cache_reg = reg;
                cache_st = st;
            }
            const v = try e.add(st, .{ .extractvalue = .{ .agg = cache_val, .index = (off % 16) / sz } });
            o.* = if (c == .bool) try e.convertScalar(v, .uint, .bool) else v;
        }
        return .{ .scalars = out };
    }

    /// The scalar type of flattened component `k` of `ty`.
    fn componentType(e: *Emitter, ty: TypeId, k: u32) Error!TypeId {
        switch (e.t.get(ty)) {
            .scalar, .@"enum", .linalg => return ty,
            .vector, .matrix => return e.t.scalar(e.t.component(ty).?),
            .array => |a| return e.componentType(a.elem, k % try e.flatCount(a.elem)),
            .@"struct" => |s| {
                var kk = k;
                for (s.fields.items) |f| {
                    const n = try e.flatCount(f.type);
                    if (kk < n) return e.componentType(f.type, kk);
                    kk -= n;
                }
                return e.unsupported("struct component", .{});
            },
            else => return e.unsupported("component type", .{}),
        }
    }

    // ------------------------------------------------------------------
    // Resources and stage inputs

    /// `array[i]...` on a resource array: a sub-array, or the element's
    /// handle (created here, at register lower bound + flattened index).
    fn arrayElement(e: *Emitter, frame: *Frame, start: @FieldType(Lowered, "res_array"), indices: []const Ref) Error!Lowered {
        var ra = start;
        const i32t = try e.dm.intType(32);
        var nonuniform = false;
        for (indices) |x| {
            const arr = switch (e.t.get(ra.ty)) {
                .array => |arr| arr,
                else => return e.unsupported("indexing this resource is not supported yet", .{}),
            };
            var inner: u32 = 1;
            var et = arr.elem;
            while (e.t.get(et) == .array) : (et = e.t.get(et).array.elem) inner *= e.t.get(et).array.len;
            const xv = (try e.scalars(frame, x))[0];
            if (e.nonuniform.contains(xv)) nonuniform = true;
            const scaled = try e.intArith(.mul, xv, try e.i32Const(inner));
            ra.index = if (ra.index) |old| try e.intArith(.add, old, scaled) else scaled;
            ra.ty = arr.elem;
        }
        _ = i32t;
        if (e.t.get(ra.ty) == .array) return .{ .res_array = ra };
        const res = e.resources.items[ra.res];
        const lb = e.binding(res).index;
        const idx = try e.intArith(.add, ra.index orelse try e.i32Const(0), try e.i32Const(lb));
        var view = res;
        view.view = true;
        view.handle = try e.makeHandle(res, idx, nonuniform, false);
        try e.resources.append(e.arena, view);
        return .{ .handle = @intCast(e.resources.items.len - 1) };
    }

    fn constIntOf(e: *Emitter, v: Value) ?i64 {
        if (v != .constant) return null;
        return switch (e.dm.constants.items[v.constant].kind) {
            .int => |x| x,
            else => null,
        };
    }

    /// i32 `a op b`, folded when both are constants (and identities).
    fn intArith(e: *Emitter, op: module.BinOp, a: Value, b: Value) Error!Value {
        const x = e.constIntOf(a);
        const y = e.constIntOf(b);
        if (x != null and y != null) return e.i32Const(@as(i32, @truncate(if (op == .add) x.? + y.? else x.? * y.?)));
        if (op == .add and y == 0) return a;
        if (op == .mul and y == 1) return a;
        return e.add(try e.dm.intType(32), .{ .binop = .{ .op = op, .lhs = a, .rhs = b } });
    }

    fn resourceKind(e: *Emitter, res: Resource) types.ResourceKind {
        if (res.rty != 0) return e.t.get(res.rty).resource.kind;
        var ty = e.m.globals.items[res.global].ty;
        while (e.t.get(ty) == .array) ty = e.t.get(ty).array.elem;
        return e.t.get(ty).resource.kind;
    }

    /// The scalar a texture's ResRet carries for elements of `elem`.
    fn texelScalar(e: *Emitter, elem: TypeId) Error!Scalar {
        const c = e.compOf(elem);
        return switch (c) {
            .bool => .uint,
            .float, .int, .uint => c,
            else => e.unsupported("textures of '{s}' are not supported yet", .{try e.t.format(e.arena, elem)}),
        };
    }

    /// Components [0, n) of a ResRet, converted to `ty`'s component type.
    fn resRetComponents(e: *Emitter, call: Value, st: DType, via: Scalar, ty: TypeId) Error![]const Value {
        const n = try e.flatCount(ty);
        const out = try e.arena.alloc(Value, n);
        for (out, 0..) |*o, k| {
            const v = try e.add(st, .{ .extractvalue = .{ .agg = call, .index = @intCast(k) } });
            o.* = try e.convertScalar(v, via, e.compOf(ty));
        }
        return out;
    }

    /// `n` values from `src` padded with undef to `width`.
    fn padded(e: *Emitter, src: []const Value, n: usize, width: usize, ty: DType) Error![]Value {
        const out = try e.arena.alloc(Value, width);
        const undef = try e.dm.constant(.{ .ty = ty, .kind = .undef });
        for (out, 0..) |*o, k| o.* = if (k < n and k < src.len) src[k] else undef;
        return out;
    }

    fn typedBufferLoad(e: *Emitter, res: Resource, idx: Value, ty: TypeId) Error![]const Value {
        const via = try e.texelScalar(res.elem);
        const st = try e.scalarTy(via);
        const ret_ty = try e.resRetType(st);
        const i32t = try e.dm.intType(32);
        if (res.class == .uav and try e.flatCount(res.elem) > 1) e.uses_typed_uav_load = true;
        const fn_i = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.bufferLoad.{s}", .{e.overloadName(st)}), ret_ty, &.{ i32t, e.handle_ty, i32t, i32t }, .nounwind_readonly);
        const call = try e.callOp(fn_i, ret_ty, &.{ try e.i32Const(68), res.handle, idx, try e.dm.constant(.{ .ty = i32t, .kind = .undef }) });
        e.last_resret = call;
        return e.resRetComponents(call, st, via, ty);
    }

    fn textureLoad(e: *Emitter, res: Resource, mip: Value, coords: []const Value, offset: ?[]const Value, ty: TypeId) Error![]const Value {
        const via = try e.texelScalar(res.elem);
        const st = try e.scalarTy(via);
        const ret_ty = try e.resRetType(st);
        const i32t = try e.dm.intType(32);
        if (res.class == .uav and try e.flatCount(res.elem) > 1) e.uses_typed_uav_load = true;
        const fn_i = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.textureLoad.{s}", .{e.overloadName(st)}), ret_ty, &.{ i32t, e.handle_ty, i32t, i32t, i32t, i32t, i32t, i32t, i32t }, .nounwind_readonly);
        const c = try e.padded(coords, coords.len, 3, i32t);
        const o = try e.padded(offset orelse &.{}, if (offset) |x| x.len else 0, 3, i32t);
        const call = try e.callOp(fn_i, ret_ty, &.{ try e.i32Const(66), res.handle, mip, c[0], c[1], c[2], o[0], o[1], o[2] });
        e.last_resret = call;
        return e.resRetComponents(call, st, via, ty);
    }

    /// Stores the status (the ResRet's fifth element) of the last texture
    /// operation into an out argument.
    fn storeStatus(e: *Emitter, frame: *Frame, status_ref: Ref) Error!void {
        const i32t = try e.dm.intType(32);
        const v = try e.add(i32t, .{ .extractvalue = .{ .agg = e.last_resret, .index = 4 } });
        try e.status_vals.put(e.arena, v, {});
        try e.storePtr(try e.outPtr(frame, status_ref), &.{v}, try e.t.scalar(.uint));
    }

    fn textureStore(e: *Emitter, res: Resource, coords: []const Value, vals: []const Value, vty: TypeId) Error!void {
        const via = try e.texelScalar(res.elem);
        const st = try e.scalarTy(via);
        const i32t = try e.dm.intType(32);
        const i8t = try e.dm.intType(8);
        const void_ty = try e.voidTy();
        const fn_i = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.textureStore.{s}", .{e.overloadName(st)}), void_ty, &.{ i32t, e.handle_ty, i32t, i32t, i32t, st, st, st, st, i8t }, .nounwind);
        const from = e.compOf(vty);
        // Typed stores write all four components (replicated, as dxc).
        var v: [4]Value = undefined;
        for (&v, 0..) |*x, k| x.* = try e.convertScalar(vals[if (k < vals.len) k else 0], from, via);
        const c = try e.padded(coords, coords.len, 3, i32t);
        const mask = try e.dm.constant(.{ .ty = i8t, .kind = .{ .int = 15 } });
        _ = try e.callOp(fn_i, void_ty, &.{ try e.i32Const(67), res.handle, c[0], c[1], c[2], v[0], v[1], v[2], v[3], mask });
    }

    fn method(e: *Emitter, frame: *Frame, name: []const u8, res_ref: Ref, arg_refs: []const Ref, ty: TypeId) Error!Lowered {
        if (frame.vals[res_ref.index()] == .ray_query) return e.rayQueryMethod(frame, frame.vals[res_ref.index()].ray_query, name, arg_refs, ty);
        const res = try e.resourceOf(frame, res_ref);
        const kind = e.resourceKind(res.*);
        const eq = std.mem.eql;
        const i32t = try e.dm.intType(32);
        if (eq(u8, name, "GetDimensions")) return e.getDimensions(frame, res.*, kind, arg_refs);
        if (res.kind == 10 and eq(u8, name, "Load")) {
            if (arg_refs.len > 1) {
                const r = Lowered{ .scalars = try e.typedBufferLoad(res.*, (try e.scalars(frame, arg_refs[0]))[0], ty) };
                try e.storeStatus(frame, arg_refs[1]);
                return r;
            }
            return e.resourceLoad(frame, res_ref, arg_refs[0], ty);
        }
        if (res.kind == 12 and eq(u8, name, "Load")) return e.resourceLoad(frame, res_ref, arg_refs[0], ty);
        if (res.kind == 11) {
            // Byte-address buffers: Load/Load2..4, Store/Store2..4, atomics.
            if (std.mem.startsWith(u8, name, "Load") and arg_refs.len == 1) return e.resourceLoad(frame, res_ref, arg_refs[0], ty);
            if (std.mem.startsWith(u8, name, "Store") and arg_refs.len == 2) {
                try e.resourceStore(frame, res_ref, arg_refs[0], arg_refs[1]);
                return .none;
            }
            if (std.mem.startsWith(u8, name, "Interlocked")) {
                const op_name = name["Interlocked".len..];
                const is_cmp = std.mem.startsWith(u8, op_name, "Compare");
                const off = (try e.scalars(frame, arg_refs[0]))[0];
                const val = (try e.scalars(frame, arg_refs[if (is_cmp) 2 else 1]))[0];
                const cmp = if (is_cmp) (try e.scalars(frame, arg_refs[1]))[0] else null;
                const vty = frame.f.inst(arg_refs[if (is_cmp) 2 else 1]).ty;
                if (e.compOf(vty).size() != 4) return e.unsupported("64-bit '{s}' is not supported yet", .{name});
                const orig = try e.resourceAtomic(res.*, &.{off}, op_name, e.compOf(vty), val, cmp);
                const has_orig = if (is_cmp) eq(u8, op_name, "CompareExchange") else arg_refs.len == 3;
                if (has_orig) try e.storePtr(try e.outPtr(frame, arg_refs[arg_refs.len - 1]), &.{orig}, frame.f.inst(arg_refs[arg_refs.len - 1]).ty);
                return .none;
            }
        }
        if (res.kind == 12 and (eq(u8, name, "IncrementCounter") or eq(u8, name, "DecrementCounter") or eq(u8, name, "Append") or eq(u8, name, "Consume"))) {
            if (res.global != std.math.maxInt(u32)) for (e.resources.items) |*r2| if (r2.global == res.global) {
                r2.has_counter = true;
            };
            const i8t = try e.dm.intType(8);
            const inc = eq(u8, name, "IncrementCounter") or eq(u8, name, "Append");
            const fn_i = try e.dxOp("dx.op.bufferUpdateCounter", i32t, &.{ i32t, e.handle_ty, i8t }, .nounwind);
            const n = try e.callOp(fn_i, i32t, &.{ try e.i32Const(70), res.handle, try e.dm.constant(.{ .ty = i8t, .kind = .{ .int = if (inc) 1 else -1 } }) });
            if (eq(u8, name, "Append")) {
                try e.structuredStore(res.*, n, 0, null, e.m.row_major, frame.f.inst(arg_refs[0]).ty, try e.scalars(frame, arg_refs[0]));
                return .none;
            }
            if (eq(u8, name, "Consume")) return .{ .scalars = try e.structuredLoad(res.*, n, 0, null, e.m.row_major, ty) };
            // (BufferUpdateCounter returns the old value for increments and
            // the new one for decrements, matching HLSL.)
            return e.list(&.{n});
        }
        const sh = texture.shape(kind) orelse return e.unsupported("method '{s}' is not supported yet", .{name});
        const call = texture.decode(name, sh, arg_refs.len) orelse return e.unsupported("method '{s}' is not supported yet", .{name});
        if (call.offsets4) {
            // Four offsets: a gather per offset, component k of the k-th.
            if (call.status != null) return e.unsupported("Gather with four offsets and a status is not supported yet", .{});
            const out = try e.arena.alloc(Value, try e.flatCount(ty));
            for (0..4) |k| {
                var one = call;
                one.offsets4 = false;
                one.offset = call.offset.? + @as(u8, @intCast(k));
                const r = try e.textureCall(frame, res, sh, one, name, arg_refs, ty);
                if (k < out.len) out[k] = r.scalars[k];
            }
            return .{ .scalars = out };
        }
        if (call.status) |k| {
            // The operation, then its status.
            var plain = call;
            plain.status = null;
            const r = try e.textureCall(frame, res, sh, plain, name, arg_refs, ty);
            try e.storeStatus(frame, arg_refs[k]);
            return r;
        }
        return e.textureCall(frame, res, sh, call, name, arg_refs, ty);
    }

    fn textureCall(e: *Emitter, frame: *Frame, res: *Resource, sh: texture.Shape, call: texture.Call, name: []const u8, arg_refs: []const Ref, ty: TypeId) Error!Lowered {
        const i32t = try e.dm.intType(32);
        const f32t = try e.dm.getType(.float);
        const undef_i32 = try e.dm.constant(.{ .ty = i32t, .kind = .undef });
        if (call.op.implicitLod()) try e.checkDerivatives();
        const arg = struct {
            fn f(em: *Emitter, fr: *Frame, refs: []const Ref, idx: ?u8) Error!?[]const Value {
                return if (idx) |k| try em.scalars(fr, refs[k]) else null;
            }
        }.f;
        const coord = (try arg(e, frame, arg_refs, call.coord)).?;
        const offset = try arg(e, frame, arg_refs, call.offset);
        if (offset) |off| for (off) |x| if (x != .constant) {
            return e.unsupported("texel offsets that are not constants (they need loop unrolling) are not supported yet", .{});
        };
        if (call.op == .load) {
            const coords = coord[0 .. sh.coords() + @intFromBool(sh.array)];
            const mip = if (call.sample_index) |k| (try e.scalars(frame, arg_refs[k]))[0] else if (sh.hasMips()) coord[coord.len - 1] else undef_i32;
            return .{ .scalars = try e.textureLoad(res.*, mip, coords, offset, ty) };
        }
        if (call.op == .sample_position) {
            const pos_ty = try e.dm.getType(.{ .@"struct" = .{ .name = "dx.types.SamplePos", .elems = &.{ f32t, f32t } } });
            const fn_i = try e.dxOp("dx.op.texture2DMSGetSamplePosition", pos_ty, &.{ i32t, e.handle_ty, i32t }, .nounwind_readonly);
            const pos = try e.callOp(fn_i, pos_ty, &.{ try e.i32Const(75), res.handle, (try e.scalars(frame, arg_refs[0]))[0] });
            const out = try e.arena.alloc(Value, 2);
            for (out, 0..) |*o, k| o.* = try e.add(f32t, .{ .extractvalue = .{ .agg = pos, .index = @intCast(k) } });
            return .{ .scalars = out };
        }
        const smp = try e.resourceOf(frame, arg_refs[call.sampler.?]);
        const ncoord = sh.coords() + @intFromBool(sh.array);
        if (call.op == .calc_lod or call.op == .calc_lod_unclamped) {
            const i1t = try e.dm.intType(1);
            const fn_i = try e.dxOp("dx.op.calculateLOD.f32", f32t, &.{ i32t, e.handle_ty, e.handle_ty, f32t, f32t, f32t, i1t }, .nounwind_readonly);
            const c = try e.padded(coord, sh.coords(), 3, f32t);
            const clamped = try e.dm.constInt(1, @intFromBool(call.op == .calc_lod));
            return e.list(&.{try e.callOp(fn_i, f32t, &.{ try e.i32Const(81), res.handle, smp.handle, c[0], c[1], c[2], clamped })});
        }
        const via = if (call.op.isCmp()) Scalar.float else try e.texelScalar(res.elem);
        const st = try e.scalarTy(via);
        const ret_ty = try e.resRetType(st);
        const c = try e.padded(coord, ncoord, 4, f32t);
        // Absent offsets are zero (undef for cubes and unused components).
        const zero = try e.i32Const(0);
        const n_off: usize = if (call.op == .gather or call.op == .gather_cmp) 2 else 3;
        const o = try e.arena.alloc(Value, n_off);
        for (o, 0..) |*x, k| x.* = if (k >= sh.offsets()) undef_i32 else if (offset) |off| off[k] else zero;
        const undef_f = try e.dm.constant(.{ .ty = f32t, .kind = .undef });
        const scalar1 = struct {
            fn f(em: *Emitter, fr: *Frame, refs: []const Ref, idx: ?u8, dflt: Value) Error!Value {
                return if (idx) |k| (try em.scalars(fr, refs[k]))[0] else dflt;
            }
        }.f;
        const clamp = try scalar1(e, frame, arg_refs, call.clamp, undef_f);
        var args: std.ArrayList(Value) = .empty;
        var params: std.ArrayList(DType) = .empty;
        const Spec = struct { op: i64, fname: []const u8 };
        const spec: Spec = switch (call.op) {
            .sample => .{ .op = 60, .fname = "sample" },
            .sample_bias => .{ .op = 61, .fname = "sampleBias" },
            .sample_level => .{ .op = 62, .fname = "sampleLevel" },
            .sample_grad => .{ .op = 63, .fname = "sampleGrad" },
            .sample_cmp => .{ .op = 64, .fname = "sampleCmp" },
            .sample_cmp_level_zero => .{ .op = 65, .fname = "sampleCmpLevelZero" },
            .sample_cmp_level => .{ .op = 224, .fname = "sampleCmpLevel" },
            .sample_cmp_grad => .{ .op = 254, .fname = "sampleCmpGrad" },
            .sample_cmp_bias => .{ .op = 255, .fname = "sampleCmpBias" },
            .gather => .{ .op = 73, .fname = "textureGather" },
            .gather_cmp => .{ .op = 74, .fname = "textureGatherCmp" },
            else => unreachable,
        };
        const min_minor: u8 = switch (call.op) {
            .sample_cmp_level => 7,
            .sample_cmp_grad, .sample_cmp_bias => 8,
            else => 0,
        };
        if (e.profile.minor < min_minor) return e.unsupported("'{s}' needs shader model 6.{d}", .{ name, min_minor });
        try args.appendSlice(e.arena, &.{ try e.i32Const(spec.op), res.handle, smp.handle });
        try params.appendSlice(e.arena, &.{ i32t, e.handle_ty, e.handle_ty });
        for (c) |x| {
            try args.append(e.arena, x);
            try params.append(e.arena, f32t);
        }
        for (o) |x| {
            try args.append(e.arena, x);
            try params.append(e.arena, i32t);
        }
        const pushF = struct {
            fn f(em: *Emitter, a: *std.ArrayList(Value), p: *std.ArrayList(DType), v: Value) Error!void {
                try a.append(em.arena, v);
                try p.append(em.arena, try em.dm.getType(.float));
            }
        }.f;
        if (call.op == .gather or call.op == .gather_cmp) {
            try args.append(e.arena, try e.i32Const(call.channel));
            try params.append(e.arena, i32t);
        }
        if (call.compare) |k| try pushF(e, &args, &params, (try e.scalars(frame, arg_refs[k]))[0]);
        if (call.bias) |k| try pushF(e, &args, &params, (try e.scalars(frame, arg_refs[k]))[0]);
        if (call.lod) |k| try pushF(e, &args, &params, (try e.scalars(frame, arg_refs[k]))[0]);
        if (call.ddx) |k| {
            for (try e.padded(try e.scalars(frame, arg_refs[k]), sh.coords(), 3, f32t)) |x| try pushF(e, &args, &params, x);
            for (try e.padded(try e.scalars(frame, arg_refs[call.ddy.?]), sh.coords(), 3, f32t)) |x| try pushF(e, &args, &params, x);
        }
        switch (call.op) {
            .sample, .sample_bias, .sample_grad, .sample_cmp, .sample_cmp_bias, .sample_cmp_grad => try pushF(e, &args, &params, clamp),
            else => {},
        }
        const fname = try std.fmt.allocPrint(e.arena, "dx.op.{s}.{s}", .{ spec.fname, e.overloadName(st) });
        const fn_i = try e.dxOp(fname, ret_ty, params.items, .nounwind_readonly);
        const result = try e.callOp(fn_i, ret_ty, args.items);
        e.last_resret = result;
        // A LOD clamp needs tiled resources.
        if (call.clamp != null) e.uses_tiled_resources = true;
        return .{ .scalars = try e.resRetComponents(result, st, via, ty) };
    }

    fn getDimensions(e: *Emitter, frame: *Frame, res: Resource, kind: types.ResourceKind, arg_refs: []const Ref) Error!Lowered {
        const i32t = try e.dm.intType(32);
        const dims_ty = try e.dm.getType(.{ .@"struct" = .{ .name = "dx.types.Dimensions", .elems = &.{ i32t, i32t, i32t, i32t } } });
        const fn_i = try e.dxOp("dx.op.getDimensions", dims_ty, &.{ i32t, e.handle_ty, i32t }, .nounwind_readonly);
        const store = struct {
            fn f(em: *Emitter, fr: *Frame, ref: Ref, v: Value) Error!void {
                const ptr = switch (fr.vals[ref.index()]) {
                    .ptr => |p| p,
                    else => return em.unsupported("internal: out argument is not a pointer", .{}),
                };
                const ty = fr.f.inst(ref).ty;
                try em.storePtr(ptr, &.{try em.convertScalar(v, .int, em.compOf(ty))}, ty);
            }
        }.f;
        const undef_i32 = try e.dm.constant(.{ .ty = i32t, .kind = .undef });
        if (res.kind == 12 or res.kind == 11 or res.kind == 10) {
            const dims = try e.callOp(fn_i, dims_ty, &.{ try e.i32Const(72), res.handle, undef_i32 });
            try store(e, frame, arg_refs[0], try e.add(i32t, .{ .extractvalue = .{ .agg = dims, .index = 0 } }));
            if (res.kind == 12 and arg_refs.len > 1) try store(e, frame, arg_refs[1], try e.i32Const(try e.stride(res.elem)));
            return .none;
        }
        const sh = texture.shape(kind) orelse return e.unsupported("GetDimensions on this resource is not supported yet", .{});
        const d = texture.getDimensions(sh, arg_refs.len);
        const mip = if (d.mip) |k| (try e.scalars(frame, arg_refs[k]))[0] else try e.i32Const(0);
        const dims = try e.callOp(fn_i, dims_ty, &.{ try e.i32Const(72), res.handle, mip });
        for (d.outs[0..d.count]) |o| {
            try store(e, frame, arg_refs[o.arg], try e.add(i32t, .{ .extractvalue = .{ .agg = dims, .index = o.comp } }));
        }
        return .none;
    }

    /// The handle of RayQuery local `k`, allocated in the prologue on first
    /// use.
    fn rqHandle(e: *Emitter, k: u32) Error!Value {
        const slot = &e.rq_locals.items[k];
        if (slot.h) |h| return h;
        const i32t = try e.dm.intType(32);
        const r = e.t.get(slot.ty).resource;
        e.uses_ray_query = true;
        if (r.flags2 != 0) {
            const f = try e.dxOp("dx.op.allocateRayQuery2", i32t, &.{ i32t, i32t, i32t }, .nounwind);
            slot.h = try e.addPrologue(i32t, .{ .call = .{ .callee = f, .args = try e.arena.dupe(Value, &.{ try e.i32Const(258), try e.i32Const(r.flags), try e.i32Const(r.flags2) }) } });
        } else {
            const f = try e.dxOp("dx.op.allocateRayQuery", i32t, &.{ i32t, i32t }, .nounwind);
            slot.h = try e.addPrologue(i32t, .{ .call = .{ .callee = f, .args = try e.arena.dupe(Value, &.{ try e.i32Const(178), try e.i32Const(r.flags) }) } });
        }
        return slot.h.?;
    }

    /// RayQuery methods: dx.op.rayQuery_*.
    fn rayQueryMethod(e: *Emitter, frame: *Frame, q: Value, name: []const u8, args: []const Ref, ty: TypeId) Error!Lowered {
        const eq = std.mem.eql;
        const i32t = try e.dm.intType(32);
        const i8t = try e.dm.intType(8);
        const f32t = try e.dm.getType(.float);
        const void_ty = try e.voidTy();
        if (eq(u8, name, "TraceRayInline")) {
            const accel = try e.resourceOf(frame, args[0]);
            const flags = (try e.scalars(frame, args[1]))[0];
            const mask = (try e.scalars(frame, args[2]))[0];
            const d = try e.scalars(frame, args[3]);
            var ps: [13]DType = undefined;
            ps[0] = i32t;
            ps[1] = i32t;
            ps[2] = e.handle_ty;
            ps[3] = i32t;
            ps[4] = i32t;
            for (ps[5..]) |*x| x.* = f32t;
            const f = try e.dxOp("dx.op.rayQuery_TraceRayInline", void_ty, &ps, .nounwind);
            _ = try e.callOp(f, void_ty, &.{ try e.i32Const(179), q, accel.handle, flags, mask, d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7] });
            return .none;
        }
        const Plain = struct { []const u8, i64 };
        const plain = [_]Plain{ .{ "Abort", 181 }, .{ "CommitNonOpaqueTriangleHit", 182 } };
        for (plain) |x| if (eq(u8, name, x[0])) {
            const f = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.rayQuery_{s}", .{x[0]}), void_ty, &.{ i32t, i32t }, .nounwind);
            _ = try e.callOp(f, void_ty, &.{ try e.i32Const(x[1]), q });
            return .none;
        };
        if (eq(u8, name, "CommitProceduralPrimitiveHit")) {
            const f = try e.dxOp("dx.op.rayQuery_CommitProceduralPrimitiveHit", void_ty, &.{ i32t, i32t, f32t }, .nounwind);
            _ = try e.callOp(f, void_ty, &.{ try e.i32Const(183), q, (try e.scalars(frame, args[0]))[0] });
            return .none;
        }
        if (eq(u8, name, "Proceed")) {
            const i1t = try e.dm.intType(1);
            const f = try e.dxOp("dx.op.rayQuery_Proceed.i1", i1t, &.{ i32t, i32t }, .nounwind);
            return e.list(&.{try e.callOp(f, i1t, &.{ try e.i32Const(180), q })});
        }
        const State = struct { []const u8, i64 };
        const table = [_]State{
            .{ "CommittedStatus", 184 },                               .{ "CandidateType", 185 },                                 .{ "CandidateObjectToWorld3x4", 186 },
            .{ "CandidateWorldToObject3x4", 187 },                     .{ "CommittedObjectToWorld3x4", 188 },                     .{ "CommittedWorldToObject3x4", 189 },
            .{ "CandidateProceduralPrimitiveNonOpaque", 190 },         .{ "CandidateTriangleFrontFace", 191 },                    .{ "CommittedTriangleFrontFace", 192 },
            .{ "CandidateTriangleBarycentrics", 193 },                 .{ "CommittedTriangleBarycentrics", 194 },                 .{ "RayFlags", 195 },
            .{ "WorldRayOrigin", 196 },                                .{ "WorldRayDirection", 197 },                             .{ "RayTMin", 198 },
            .{ "CandidateTriangleRayT", 199 },                         .{ "CommittedRayT", 200 },                                 .{ "CandidateInstanceIndex", 201 },
            .{ "CandidateInstanceID", 202 },                           .{ "CandidateGeometryIndex", 203 },                        .{ "CandidatePrimitiveIndex", 204 },
            .{ "CandidateObjectRayOrigin", 205 },                      .{ "CandidateObjectRayDirection", 206 },                   .{ "CommittedInstanceIndex", 207 },
            .{ "CommittedInstanceID", 208 },                           .{ "CommittedGeometryIndex", 209 },                        .{ "CommittedPrimitiveIndex", 210 },
            .{ "CommittedObjectRayOrigin", 211 },                      .{ "CommittedObjectRayDirection", 212 },                   .{ "CandidateInstanceContributionToHitGroupIndex", 214 },
            .{ "CommittedInstanceContributionToHitGroupIndex", 215 },  .{ "CandidateObjectToWorld4x3", 186 },                     .{ "CandidateWorldToObject4x3", 187 },
            .{ "CommittedObjectToWorld4x3", 188 },                     .{ "CommittedWorldToObject4x3", 189 },
        };
        const op = for (table) |x| {
            if (eq(u8, name, x[0])) break x[1];
        } else return e.unsupported("RayQuery method '{s}' is not supported yet", .{name});
        const rt = try e.scalarTy(e.compOf(ty));
        const suffix = e.overloadName(rt);
        switch (e.t.get(ty)) {
            .matrix => |m| {
                // Elements of the 3x4 matrix (4x3: transposed).
                const f = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.rayQuery_StateMatrix.{s}", .{suffix}), rt, &.{ i32t, i32t, i32t, i8t }, .nounwind_readonly);
                const out = try e.arena.alloc(Value, @as(usize, m.rows) * m.cols);
                for (0..m.rows) |r| for (0..m.cols) |c| {
                    const row, const col = if (m.rows == 3) .{ r, c } else .{ c, r };
                    out[r * m.cols + c] = try e.callOp(f, rt, &.{ try e.i32Const(op), q, try e.i32Const(@intCast(row)), try e.dm.constant(.{ .ty = i8t, .kind = .{ .int = @intCast(col) } }) });
                };
                return .{ .scalars = out };
            },
            .vector => |v| {
                const f = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.rayQuery_StateVector.{s}", .{suffix}), rt, &.{ i32t, i32t, i8t }, .nounwind_readonly);
                const out = try e.arena.alloc(Value, v.len);
                for (out, 0..) |*o, k| o.* = try e.callOp(f, rt, &.{ try e.i32Const(op), q, try e.dm.constant(.{ .ty = i8t, .kind = .{ .int = @intCast(k) } }) });
                return .{ .scalars = out };
            },
            else => {
                const f = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.rayQuery_StateScalar.{s}", .{suffix}), rt, &.{ i32t, i32t }, .nounwind_readonly);
                return e.list(&.{try e.callOp(f, rt, &.{ try e.i32Const(op), q })});
            },
        }
    }

    fn resourceOf(e: *Emitter, frame: *Frame, r: Ref) Error!*Resource {
        return switch (frame.vals[r.index()]) {
            .handle => |h| &e.resources.items[h],
            else => e.unsupported("resources not tied to a global are not supported yet", .{}),
        };
    }

    fn resRetType(e: *Emitter, scalar: DType) Error!DType {
        const i32t = try e.dm.intType(32);
        const name = try std.fmt.allocPrint(e.arena, "dx.types.ResRet.{s}", .{e.overloadName(scalar)});
        return e.dm.getType(.{ .@"struct" = .{ .name = name, .elems = &.{ scalar, scalar, scalar, scalar, i32t } } });
    }

    /// `buffer[i].member...` in a structured buffer: byte offsets in the
    /// packed element layout.
    fn bufferAccess(e: *Emitter, frame: *Frame, start: @FieldType(Lowered, "buf"), elem_ty: TypeId, indices: []const Ref) Error!Lowered {
        var b = start;
        var cur = elem_ty;
        const i32t = try e.dm.intType(32);
        for (indices) |x| {
            const xi = frame.f.inst(x);
            switch (e.t.get(cur)) {
                .@"struct" => |st| {
                    const k: u32 = @intCast(xi.op.constant.int);
                    const offs = layout.fieldOffsets(e.arena, e.t, st, .dx_packed) catch return e.unsupported("buffer member types", .{});
                    b.offset += offs[k];
                    b.row_major = st.fields.items[k].row_major;
                    cur = st.fields.items[k].type;
                },
                .array, .vector => {
                    if (b.mat) |*mt| {
                        // A component of a matrix row.
                        if (mt.col != null or xi.op != .constant) return e.unsupported("indexing this buffer member is not supported yet", .{});
                        mt.col = @intCast(xi.op.constant.int);
                        cur = try e.t.scalar(e.t.get(cur).vector.elem);
                        continue;
                    }
                    const elem = if (e.t.get(cur) == .array) e.t.get(cur).array.elem else try e.t.scalar(e.t.get(cur).vector.elem);
                    const stride_b = layout.arrayStride(e.t, elem, b.row_major, .dx_packed) catch return e.unsupported("buffer element types", .{});
                    if (xi.op == .constant) {
                        b.offset += @as(u32, @intCast(xi.op.constant.int)) * stride_b;
                    } else {
                        const idx = (try e.scalars(frame, x))[0];
                        const bytes = try e.add(i32t, .{ .binop = .{ .op = .mul, .lhs = idx, .rhs = try e.i32Const(stride_b) } });
                        b.dyn = if (b.dyn) |d| try e.add(i32t, .{ .binop = .{ .op = .add, .lhs = d, .rhs = bytes } }) else bytes;
                    }
                    cur = elem;
                },
                .matrix => |m| {
                    if (b.mat != null) return e.unsupported("indexing this buffer member is not supported yet", .{});
                    b.mat = .{ .ty = cur, .row = (try e.scalars(frame, x))[0] };
                    cur = try e.t.vector(m.elem, m.cols);
                },
                else => return e.unsupported("indexing this buffer member is not supported yet", .{}),
            }
        }
        return .{ .buf = b };
    }

    /// Stores a row (or one component) of a matrix in a structured buffer
    /// element by element: the row need not be contiguous.
    fn matrixPartStore(e: *Emitter, b: @FieldType(Lowered, "buf"), mat: @typeInfo(@FieldType(@FieldType(Lowered, "buf"), "mat")).optional.child, vals: []const Value) Error!void {
        const m = e.t.get(mat.ty).matrix;
        const ec = try e.t.scalar(m.elem);
        const i32t = try e.dm.intType(32);
        const res = e.resources.items[b.res];
        for (vals, 0..) |v, j| {
            const c: u32 = mat.col orelse @intCast(j);
            const off0 = layout.componentOffset(e.arena, e.t, mat.ty, b.row_major, c, .dx_packed) catch return e.unsupported("buffer element types", .{});
            const const_row: ?i64 = if (m.rows == 1) 0 else e.constIntOf(mat.row);
            if (const_row) |row| {
                const off = layout.componentOffset(e.arena, e.t, mat.ty, b.row_major, @as(u32, @intCast(row)) * m.cols + c, .dx_packed) catch return e.unsupported("buffer element types", .{});
                try e.structuredStore(res, b.index, b.offset + off, b.dyn, b.row_major, ec, &.{v});
                continue;
            }
            // A dynamic row: rows are a constant byte step apart.
            const step = (layout.componentOffset(e.arena, e.t, mat.ty, b.row_major, m.cols + c, .dx_packed) catch return e.unsupported("buffer element types", .{})) - off0;
            var dyn = try e.add(i32t, .{ .binop = .{ .op = .mul, .lhs = mat.row, .rhs = try e.i32Const(step) } });
            if (b.dyn) |d| dyn = try e.add(i32t, .{ .binop = .{ .op = .add, .lhs = d, .rhs = dyn } });
            try e.structuredStore(res, b.index, b.offset + off0, dyn, b.row_major, ec, &.{v});
        }
    }

    /// Loads a value of `ty` at a byte offset of a structured buffer
    /// element: contiguous components of one type are read together.
    fn structuredLoad(e: *Emitter, res: Resource, idx: Value, base: u32, dyn: ?Value, row_major: bool, ty: TypeId) Error![]const Value {
        const n = try e.flatCount(ty);
        const out = try e.arena.alloc(Value, n);
        const i32t = try e.dm.intType(32);
        const i8t = try e.dm.intType(8);
        var k: u32 = 0;
        while (k < n) {
            const c0 = e.compOf(try e.componentType(ty, k));
            const mem: Scalar = if (c0 == .bool) .uint else c0;
            const off0 = layout.componentOffset(e.arena, e.t, ty, row_major, k, .dx_packed) catch return e.unsupported("buffer element types", .{});
            var count: u32 = 1;
            while (k + count < n and count < 4) : (count += 1) {
                const cn = e.compOf(try e.componentType(ty, k + count));
                const mn: Scalar = if (cn == .bool) .uint else cn;
                const on = layout.componentOffset(e.arena, e.t, ty, row_major, k + count, .dx_packed) catch break;
                if (mn != mem or on != off0 + count * mem.size()) break;
            }
            const st = try e.scalarTy(mem);
            const ret_ty = try e.resRetType(st);
            var off = try e.i32Const(base + off0);
            if (dyn) |d| off = try e.add(i32t, .{ .binop = .{ .op = .add, .lhs = d, .rhs = off } });
            if (e.profile.minor < 3 and mem.size() == 8) {
                // No 64-bit loads before SM 6.3: i32 words joined in pairs
                // (as dxc).
                count = @min(count, 2);
                const wt = try e.resRetType(i32t);
                const words = if (e.profile.minor >= 2) blk: {
                    const fn_w = try e.dxOp("dx.op.rawBufferLoad.i32", wt, &.{ i32t, e.handle_ty, i32t, i32t, i8t, i32t }, .nounwind_readonly);
                    break :blk try e.callOp(fn_w, wt, &.{ try e.i32Const(139), res.handle, idx, off, try e.dm.constant(.{ .ty = i8t, .kind = .{ .int = (@as(i64, 1) << @intCast(2 * count)) - 1 } }), try e.i32Const(8) });
                } else blk: {
                    const fn_w = try e.dxOp("dx.op.bufferLoad.i32", wt, &.{ i32t, e.handle_ty, i32t, i32t }, .nounwind_readonly);
                    break :blk try e.callOp(fn_w, wt, &.{ try e.i32Const(68), res.handle, idx, off });
                };
                for (0..count) |j| {
                    const lo = try e.add(i32t, .{ .extractvalue = .{ .agg = words, .index = @intCast(2 * j) } });
                    const hi = try e.add(i32t, .{ .extractvalue = .{ .agg = words, .index = @intCast(2 * j + 1) } });
                    out[k + j] = try e.joinWords(lo, hi, mem);
                }
                k += count;
                continue;
            }
            const call = if (e.profile.minor >= 2) blk: {
                const fn_i = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.rawBufferLoad.{s}", .{e.overloadName(st)}), ret_ty, &.{ i32t, e.handle_ty, i32t, i32t, i8t, i32t }, .nounwind_readonly);
                const mask = try e.dm.constant(.{ .ty = i8t, .kind = .{ .int = (@as(i64, 1) << @intCast(count)) - 1 } });
                break :blk try e.callOp(fn_i, ret_ty, &.{ try e.i32Const(139), res.handle, idx, off, mask, try e.i32Const(mem.size()) });
            } else blk: {
                const fn_i = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.bufferLoad.{s}", .{e.overloadName(st)}), ret_ty, &.{ i32t, e.handle_ty, i32t, i32t }, .nounwind_readonly);
                break :blk try e.callOp(fn_i, ret_ty, &.{ try e.i32Const(68), res.handle, idx, off });
            };
            for (0..count) |j| {
                const v = try e.add(st, .{ .extractvalue = .{ .agg = call, .index = @intCast(j) } });
                const cj = e.compOf(try e.componentType(ty, k + @as(u32, @intCast(j))));
                out[k + j] = if (cj == .bool) try e.convertScalar(v, .uint, .bool) else v;
            }
            k += count;
        }
        return out;
    }

    fn structuredStore(e: *Emitter, res: Resource, idx: Value, base: u32, dyn: ?Value, row_major: bool, ty: TypeId, vals: []const Value) Error!void {
        const n: u32 = @intCast(vals.len);
        const i32t = try e.dm.intType(32);
        const i8t = try e.dm.intType(8);
        const void_ty = try e.voidTy();
        var k: u32 = 0;
        while (k < n) {
            const c0 = e.compOf(try e.componentType(ty, k));
            const mem: Scalar = if (c0 == .bool) .uint else c0;
            const off0 = layout.componentOffset(e.arena, e.t, ty, row_major, k, .dx_packed) catch return e.unsupported("buffer element types", .{});
            var count: u32 = 1;
            while (k + count < n and count < 4) : (count += 1) {
                const cn = e.compOf(try e.componentType(ty, k + count));
                const mn: Scalar = if (cn == .bool) .uint else cn;
                const on = layout.componentOffset(e.arena, e.t, ty, row_major, k + count, .dx_packed) catch break;
                if (mn != mem or on != off0 + count * mem.size()) break;
            }
            const st = try e.scalarTy(mem);
            if (e.profile.minor < 3 and mem.size() == 8) {
                // No 64-bit stores before SM 6.3: i32 words (as dxc).
                count = @min(count, 2);
                const undef_w = try e.dm.constant(.{ .ty = i32t, .kind = .undef });
                var ws: [4]Value = .{ undef_w, undef_w, undef_w, undef_w };
                for (0..count) |j| {
                    const w = try e.splitWords(vals[k + j], mem);
                    ws[2 * j] = w[0];
                    ws[2 * j + 1] = w[1];
                }
                var woff = try e.i32Const(base + off0);
                if (dyn) |d| woff = try e.add(i32t, .{ .binop = .{ .op = .add, .lhs = d, .rhs = woff } });
                const wmask = try e.dm.constant(.{ .ty = i8t, .kind = .{ .int = (@as(i64, 1) << @intCast(2 * count)) - 1 } });
                if (e.profile.minor >= 2) {
                    const fn_w = try e.dxOp("dx.op.rawBufferStore.i32", void_ty, &.{ i32t, e.handle_ty, i32t, i32t, i32t, i32t, i32t, i32t, i8t, i32t }, .nounwind);
                    _ = try e.callOp(fn_w, void_ty, &.{ try e.i32Const(140), res.handle, idx, woff, ws[0], ws[1], ws[2], ws[3], wmask, try e.i32Const(8) });
                } else {
                    const fn_w = try e.dxOp("dx.op.bufferStore.i32", void_ty, &.{ i32t, e.handle_ty, i32t, i32t, i32t, i32t, i32t, i32t, i8t }, .nounwind);
                    _ = try e.callOp(fn_w, void_ty, &.{ try e.i32Const(69), res.handle, idx, woff, ws[0], ws[1], ws[2], ws[3], wmask });
                }
                k += count;
                continue;
            }
            const undef_v = try e.dm.constant(.{ .ty = st, .kind = .undef });
            var comps: [4]Value = .{ undef_v, undef_v, undef_v, undef_v };
            for (0..count) |j| {
                const cj = e.compOf(try e.componentType(ty, k + @as(u32, @intCast(j))));
                comps[j] = if (cj == .bool) try e.convertScalar(vals[k + j], .bool, .uint) else vals[k + j];
            }
            var off = try e.i32Const(base + off0);
            if (dyn) |d| off = try e.add(i32t, .{ .binop = .{ .op = .add, .lhs = d, .rhs = off } });
            const mask = try e.dm.constant(.{ .ty = i8t, .kind = .{ .int = (@as(i64, 1) << @intCast(count)) - 1 } });
            if (e.profile.minor >= 2) {
                const fn_i = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.rawBufferStore.{s}", .{e.overloadName(st)}), void_ty, &.{ i32t, e.handle_ty, i32t, i32t, st, st, st, st, i8t, i32t }, .nounwind);
                _ = try e.callOp(fn_i, void_ty, &.{ try e.i32Const(140), res.handle, idx, off, comps[0], comps[1], comps[2], comps[3], mask, try e.i32Const(mem.size()) });
            } else {
                const fn_i = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.bufferStore.{s}", .{e.overloadName(st)}), void_ty, &.{ i32t, e.handle_ty, i32t, i32t, st, st, st, st, i8t }, .nounwind);
                _ = try e.callOp(fn_i, void_ty, &.{ try e.i32Const(69), res.handle, idx, off, comps[0], comps[1], comps[2], comps[3], mask });
            }
            k += count;
        }
    }

    fn resourceLoad(e: *Emitter, frame: *Frame, res_ref: Ref, index_ref: Ref, ty: TypeId) Error!Lowered {
        const res = try e.resourceOf(frame, res_ref);
        if (res.kind >= 1 and res.kind <= 9) {
            const coords = try e.scalars(frame, index_ref);
            const sh = texture.shape(e.resourceKind(res.*)).?;
            const i32t = try e.dm.intType(32);
            const mip = if (sh.hasMips() or sh.ms) try e.i32Const(0) else try e.dm.constant(.{ .ty = i32t, .kind = .undef });
            return .{ .scalars = try e.textureLoad(res.*, mip, coords, null, ty) };
        }
        const idx = (try e.scalars(frame, index_ref))[0];
        if (res.kind == 12) return .{ .scalars = try e.structuredLoad(res.*, idx, 0, null, e.m.row_major, ty) };
        if (res.kind == 11 and !try e.simpleRaw(ty)) return .{ .scalars = try e.rawLoad(res.*, idx, ty) };
        const n = try e.flatCount(ty);
        const c = try e.uniformScalar(ty);
        const mem_c = if (c == .bool) Scalar.uint else c;
        const st = try e.scalarTy(mem_c);
        const ret_ty = try e.resRetType(st);
        const i32t = try e.dm.intType(32);
        const i8t = try e.dm.intType(8);
        const undef_i32 = try e.dm.constant(.{ .ty = i32t, .kind = .undef });
        var out = try e.arena.alloc(Value, n);
        // At most four components per load.
        var done: u32 = 0;
        while (done < n) {
            const chunk = @min(4, n - done);
            var call: Value = undefined;
            if (res.kind == 10) {
                if (res.class == .uav and try e.flatCount(res.elem) > 1) e.uses_typed_uav_load = true;
                const fn_i = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.bufferLoad.{s}", .{e.overloadName(st)}), ret_ty, &.{ i32t, e.handle_ty, i32t, i32t }, .nounwind_readonly);
                call = try e.callOp(fn_i, ret_ty, &.{ try e.i32Const(68), res.handle, idx, undef_i32 });
            } else {
                const offset = try e.i32Const(done * mem_c.size());
                const coord: Value, const off: Value = if (res.kind == 11) .{ idx, undef_i32 } else .{ idx, offset };
                if (e.profile.minor >= 2) {
                    const fn_i = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.rawBufferLoad.{s}", .{e.overloadName(st)}), ret_ty, &.{ i32t, e.handle_ty, i32t, i32t, i8t, i32t }, .nounwind_readonly);
                    const mask = try e.dm.constant(.{ .ty = i8t, .kind = .{ .int = (@as(i64, 1) << @intCast(chunk)) - 1 } });
                    call = try e.callOp(fn_i, ret_ty, &.{ try e.i32Const(139), res.handle, coord, off, mask, try e.i32Const(mem_c.size()) });
                } else {
                    const fn_i = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.bufferLoad.{s}", .{e.overloadName(st)}), ret_ty, &.{ i32t, e.handle_ty, i32t, i32t }, .nounwind_readonly);
                    call = try e.callOp(fn_i, ret_ty, &.{ try e.i32Const(68), res.handle, coord, off });
                }
            }
            for (0..chunk) |k| {
                const v = try e.add(st, .{ .extractvalue = .{ .agg = call, .index = @intCast(k) } });
                out[done + k] = if (c == .bool) try e.convertScalar(v, .uint, .bool) else v;
            }
            done += chunk;
            if (res.kind != 12 and done < n) return e.unsupported("loads wider than four components from this resource", .{});
        }
        _ = &out;
        return .{ .scalars = out };
    }

    /// Whether a byte-address Load/Store of `ty` is a single access of up
    /// to four 32-bit components.
    fn simpleRaw(e: *Emitter, ty: TypeId) Error!bool {
        const n = try e.flatCount(ty);
        if (n > 4 or e.t.get(ty) == .matrix) return false;
        const c = e.uniformScalar(ty) catch return false;
        return storageScalar(c).size() == 4;
    }

    /// Byte offsets of the components of `ty` in a byte-address buffer
    /// (templated Load / Store: natural alignment; dxc's DXIL lays
    /// matrices out by row here, its SPIR-V by column).
    fn rawOffset(e: *Emitter, ty: TypeId, k: u32) Error!u32 {
        return layout.componentOffset(e.arena, e.t, ty, true, k, .dx_packed) catch e.unsupported("byte-address buffer accesses of type '{s}' are not supported yet", .{try e.t.format(e.arena, ty)});
    }

    /// A templated byte-address Load: one raw load per component.
    fn rawLoad(e: *Emitter, res: Resource, base: Value, ty: TypeId) Error![]const Value {
        if (e.profile.minor < 2) return e.unsupported("templated loads of '{s}' need shader model 6.2", .{try e.t.format(e.arena, ty)});
        const i32t = try e.dm.intType(32);
        const i8t = try e.dm.intType(8);
        const undef_i32 = try e.dm.constant(.{ .ty = i32t, .kind = .undef });
        const out = try e.arena.alloc(Value, try e.flatCount(ty));
        for (out, 0..) |*o, k| {
            const c = e.compOf(try e.componentType(ty, @intCast(k)));
            const mem_c = if (c == .bool) Scalar.uint else storageScalar(c);
            const addr = try e.intArith(.add, base, try e.i32Const(try e.rawOffset(ty, @intCast(k))));
            if (mem_c.size() == 8 and e.profile.minor < 3) {
                // 64-bit overloads need SM 6.3: two words.
                const ut = try e.scalarTy(.uint);
                const rt = try e.resRetType(ut);
                const fn_i = try e.dxOp("dx.op.rawBufferLoad.i32", rt, &.{ i32t, e.handle_ty, i32t, i32t, i8t, i32t }, .nounwind_readonly);
                const call = try e.callOp(fn_i, rt, &.{ try e.i32Const(139), res.handle, addr, undef_i32, try e.dm.constInt(8, 3), try e.i32Const(4) });
                const lo = try e.add(ut, .{ .extractvalue = .{ .agg = call, .index = 0 } });
                const hi = try e.add(ut, .{ .extractvalue = .{ .agg = call, .index = 1 } });
                o.* = try e.joinWords(lo, hi, mem_c);
                continue;
            }
            const st = try e.scalarTy(mem_c);
            const ret_ty = try e.resRetType(st);
            const fn_i = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.rawBufferLoad.{s}", .{e.overloadName(st)}), ret_ty, &.{ i32t, e.handle_ty, i32t, i32t, i8t, i32t }, .nounwind_readonly);
            const call = try e.callOp(fn_i, ret_ty, &.{ try e.i32Const(139), res.handle, addr, undef_i32, try e.dm.constInt(8, 1), try e.i32Const(mem_c.size()) });
            const v = try e.add(st, .{ .extractvalue = .{ .agg = call, .index = 0 } });
            o.* = if (c == .bool) try e.convertScalar(v, .uint, .bool) else v;
        }
        return out;
    }

    /// A 64-bit value from its low and high words (makeDouble for
    /// doubles).
    fn joinWords(e: *Emitter, lo: Value, hi: Value, c: Scalar) Error!Value {
        const i32t = try e.dm.intType(32);
        if (c == .double) {
            const dt = try e.scalarTy(.double);
            const fn_i = try e.dxOp("dx.op.makeDouble.f64", dt, &.{ i32t, i32t, i32t }, .nounwind_readnone);
            return e.callOp(fn_i, dt, &.{ try e.i32Const(101), lo, hi });
        }
        const i64t = try e.scalarTy(c);
        const l = try e.add(i64t, .{ .cast = .{ .op = .zext, .val = lo } });
        const h = try e.add(i64t, .{ .cast = .{ .op = .zext, .val = hi } });
        const sh = try e.add(i64t, .{ .binop = .{ .op = .shl, .lhs = h, .rhs = try e.dm.constant(.{ .ty = i64t, .kind = .{ .int = 32 } }) } });
        return e.add(i64t, .{ .binop = .{ .op = .@"or", .lhs = sh, .rhs = l } });
    }

    /// The low and high words of a 64-bit value (splitDouble for doubles).
    fn splitWords(e: *Emitter, v: Value, c: Scalar) Error![2]Value {
        const i32t = try e.dm.intType(32);
        if (c == .double) {
            const st = try e.dm.getType(.{ .@"struct" = .{ .name = "dx.types.splitdouble", .elems = &.{ i32t, i32t } } });
            const fn_i = try e.dxOp("dx.op.splitDouble.f64", st, &.{ i32t, try e.scalarTy(.double) }, .nounwind_readnone);
            const r = try e.callOp(fn_i, st, &.{ try e.i32Const(102), v });
            return .{ try e.add(i32t, .{ .extractvalue = .{ .agg = r, .index = 0 } }), try e.add(i32t, .{ .extractvalue = .{ .agg = r, .index = 1 } }) };
        }
        const i64t = try e.scalarTy(c);
        const lo = try e.add(i32t, .{ .cast = .{ .op = .trunc, .val = v } });
        const sh = try e.add(i64t, .{ .binop = .{ .op = .lshr, .lhs = v, .rhs = try e.dm.constant(.{ .ty = i64t, .kind = .{ .int = 32 } }) } });
        return .{ lo, try e.add(i32t, .{ .cast = .{ .op = .trunc, .val = sh } }) };
    }

    fn rawStore(e: *Emitter, res: Resource, base: Value, ty: TypeId, vals: []const Value) Error!void {
        if (e.profile.minor < 2) return e.unsupported("templated stores of '{s}' need shader model 6.2", .{try e.t.format(e.arena, ty)});
        const i32t = try e.dm.intType(32);
        const i8t = try e.dm.intType(8);
        const void_ty = try e.voidTy();
        const undef_i32 = try e.dm.constant(.{ .ty = i32t, .kind = .undef });
        for (vals, 0..) |v, k| {
            const c = e.compOf(try e.componentType(ty, @intCast(k)));
            const mem_c = if (c == .bool) Scalar.uint else storageScalar(c);
            const addr = try e.intArith(.add, base, try e.i32Const(try e.rawOffset(ty, @intCast(k))));
            if (mem_c.size() == 8 and e.profile.minor < 3) {
                const ut = try e.scalarTy(.uint);
                const words = try e.splitWords(v, mem_c);
                const undef_u = try e.dm.constant(.{ .ty = ut, .kind = .undef });
                const fn_i = try e.dxOp("dx.op.rawBufferStore.i32", void_ty, &.{ i32t, e.handle_ty, i32t, i32t, ut, ut, ut, ut, i8t, i32t }, .nounwind);
                _ = try e.callOp(fn_i, void_ty, &.{ try e.i32Const(140), res.handle, addr, undef_i32, words[0], words[1], undef_u, undef_u, try e.dm.constInt(8, 3), try e.i32Const(4) });
                continue;
            }
            const st = try e.scalarTy(mem_c);
            const undef_v = try e.dm.constant(.{ .ty = st, .kind = .undef });
            const fn_i = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.rawBufferStore.{s}", .{e.overloadName(st)}), void_ty, &.{ i32t, e.handle_ty, i32t, i32t, st, st, st, st, i8t, i32t }, .nounwind);
            const sv = if (c == .bool) try e.convertScalar(v, .bool, .uint) else v;
            _ = try e.callOp(fn_i, void_ty, &.{ try e.i32Const(140), res.handle, addr, undef_i32, sv, undef_v, undef_v, undef_v, try e.dm.constInt(8, 1), try e.i32Const(mem_c.size()) });
        }
    }

    fn resourceStore(e: *Emitter, frame: *Frame, res_ref: Ref, index_ref: Ref, value_ref: Ref) Error!void {
        const res = try e.resourceOf(frame, res_ref);
        if (res.kind >= 1 and res.kind <= 9) return e.textureStore(res.*, try e.scalars(frame, index_ref), try e.scalars(frame, value_ref), frame.f.inst(value_ref).ty);
        const idx = (try e.scalars(frame, index_ref))[0];
        const vals = try e.scalars(frame, value_ref);
        if (res.kind == 12) return e.structuredStore(res.*, idx, 0, null, e.m.row_major, frame.f.inst(value_ref).ty, vals);
        if (res.kind == 11 and !try e.simpleRaw(frame.f.inst(value_ref).ty)) return e.rawStore(res.*, idx, frame.f.inst(value_ref).ty, vals);
        const vt = frame.f.inst(value_ref).ty;
        const c = try e.uniformScalar(vt);
        const mem_c = if (c == .bool) Scalar.uint else c;
        const st = try e.scalarTy(mem_c);
        const i32t = try e.dm.intType(32);
        const i8t = try e.dm.intType(8);
        const void_ty = try e.voidTy();
        const undef_i32 = try e.dm.constant(.{ .ty = i32t, .kind = .undef });
        const undef_v = try e.dm.constant(.{ .ty = st, .kind = .undef });
        var done: u32 = 0;
        while (done < vals.len) {
            const chunk: u32 = @intCast(@min(4, vals.len - done));
            var comps: [4]Value = .{ undef_v, undef_v, undef_v, undef_v };
            for (0..chunk) |k| comps[k] = if (c == .bool) try e.convertScalar(vals[done + k], .bool, .uint) else vals[done + k];
            var mask: i64 = (@as(i64, 1) << @intCast(chunk)) - 1;
            if (res.kind == 10) {
                // Typed stores write every component (replicated).
                for (chunk..4) |k| comps[k] = comps[0];
                mask = 15;
                if (vals.len > 4) return e.unsupported("typed stores wider than four components", .{});
            }
            const mask_c = try e.dm.constant(.{ .ty = i8t, .kind = .{ .int = mask } });
            const coord = idx;
            const off = if (res.kind == 12) try e.i32Const(done * mem_c.size()) else undef_i32;
            if (res.kind != 10 and e.profile.minor >= 2) {
                const fn_i = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.rawBufferStore.{s}", .{e.overloadName(st)}), void_ty, &.{ i32t, e.handle_ty, i32t, i32t, st, st, st, st, i8t, i32t }, .nounwind);
                _ = try e.callOp(fn_i, void_ty, &.{ try e.i32Const(140), res.handle, coord, off, comps[0], comps[1], comps[2], comps[3], mask_c, try e.i32Const(mem_c.size()) });
            } else {
                const fn_i = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.bufferStore.{s}", .{e.overloadName(st)}), void_ty, &.{ i32t, e.handle_ty, i32t, i32t, st, st, st, st, i8t }, .nounwind);
                _ = try e.callOp(fn_i, void_ty, &.{ try e.i32Const(69), res.handle, coord, off, comps[0], comps[1], comps[2], comps[3], mask_c });
            }
            done += chunk;
        }
    }

    // ------------------------------------------------------------------
    // Signatures

    fn buildSignatures(e: *Emitter, entry: ir.Entry) Error!void {
        const points: [3]?signature.SigPoint = switch (entry.stage) {
            .vertex => .{ .vs_in, .vs_out, null },
            .pixel => .{ .ps_in, .ps_out, null },
            .geometry => .{ .gs_v_in, .gs_out, null },
            .hull => .{ .hs_cp_in, .hs_cp_out, .pc_out },
            .domain => .{ .ds_cp_in, .ds_out, .ds_in },
            .mesh => .{ null, .ms_out, .ms_p_out },
            else => .{ null, null, null },
        };
        e.in_elem = try e.arena.alloc(?u32, entry.inputs.items.len);
        @memset(e.in_elem, null);
        e.out_elem = try e.arena.alloc(?u32, entry.outputs.items.len);
        @memset(e.out_elem, null);
        e.out_split = try e.arena.alloc(u32, entry.outputs.items.len);
        @memset(e.out_split, 0);
        if (points[0]) |sp| e.sig_in = try e.buildSignature(entry.inputs.items, sp, e.in_elem, null);
        if (points[1]) |sp| e.sig_out = try e.buildSignature(entry.outputs.items, sp, e.out_elem, e.out_split);
        e.pc_elem = try e.arena.alloc(?u32, entry.patch_constants.items.len);
        @memset(e.pc_elem, null);
        if (points[2]) |sp| e.sig_pc = try e.buildSignature(entry.patch_constants.items, sp, e.pc_elem, null);
    }

    fn buildSignature(e: *Emitter, els: []const ir.SigElement, sp: signature.SigPoint, map: []?u32, split: ?[]u32) Error![]signature.Element {
        var out: std.ArrayList(signature.Element) = .empty;
        for (els, 0..) |el, k| {
            const kind = signature.kindByName(el.semantic);
            if (kind == .invalid) return e.unsupported("semantic '{s}' is not supported yet", .{el.semantic});
            // Geometry inputs that are not per vertex belong to GSIn.
            const esp: signature.SigPoint = if (sp == .gs_v_in and !el.per_vertex) .gs_in else if (sp == .hs_cp_in and !el.per_vertex) .hs_in else sp;
            const interp = signature.interpretation(kind, esp, e.profile.minor);
            switch (interp) {
                .na => return e.unsupported("semantic '{s}' is not supported as this {s} yet", .{ el.semantic, if (sp.isInput()) "input" else "output" }),
                .not_in_sig => continue,
                else => {},
            }
            const shape = try e.sigShape(el.ty, el.row_major);
            var comp = try e.sigCompType(el.ty);
            if (kind == .is_front_face and comp == .i1) comp = .u32;
            if (kind == .barycentrics) e.uses_barycentrics = true;
            if (comp == .f16 or comp == .i16 or comp == .u16) e.uses_min_precision = true;
            const eff_kind: signature.SemanticKind = if (interp == .arb) .arbitrary else kind;
            map[k] = @intCast(out.items.len);
            if (kind == .target and shape.rows > 1) {
                // One element per render target, last first (as dxc).
                split.?[k] = shape.rows;
                var r = shape.rows;
                while (r > 0) {
                    r -= 1;
                    try out.append(e.arena, .{
                        .id = @intCast(out.items.len),
                        .name = signature.canonicalName(kind),
                        .kind = kind,
                        .interpretation = interp,
                        .comp = comp,
                        .interp = .undefined,
                        .rows = 1,
                        .cols = shape.cols,
                        .indices = try e.arena.dupe(u32, &.{el.semantic_index + r}),
                    });
                }
                continue;
            }
            const indices = try e.arena.alloc(u32, shape.rows);
            for (indices, 0..) |*x, i| x.* = el.semantic_index + @as(u32, @intCast(i));
            try out.append(e.arena, .{
                .id = @intCast(out.items.len),
                .name = if (eff_kind == .arbitrary) el.semantic else signature.canonicalName(eff_kind),
                .kind = eff_kind,
                .interpretation = interp,
                .comp = comp,
                .interp = interpMode(el.interp, esp, comp, eff_kind),
                .stream = el.stream,
                .rows = shape.rows,
                .cols = shape.cols,
                .indices = indices,
            });
        }
        signature.pack(e.arena, out.items, sp) catch |err| switch (err) {
            error.SignatureFull => return e.unsupported("the signature does not fit in 32 registers", .{}),
            error.OutOfMemory => return error.OutOfMemory,
        };
        return out.items;
    }

    /// The interpolation mode of an element: the written modifiers, else
    /// linear for floats and constant for the rest; SV_Position never
    /// interpolates with perspective.
    fn interpMode(q: types.Interp, sp: signature.SigPoint, comp: signature.CompType, kind: signature.SemanticKind) signature.InterpMode {
        if (sp == .vs_in or sp == .ps_out or sp == .gs_in or sp == .pc_out or sp == .ds_in) return .undefined;
        if (sp == .ms_p_out) return .constant; // per primitive: never interpolated
        var m: signature.InterpMode = if (q.nointerpolation)
            .constant
        else if (q.sample)
            (if (q.noperspective) .linear_noperspective_sample else .linear_sample)
        else if (q.centroid)
            (if (q.noperspective) .linear_noperspective_centroid else .linear_centroid)
        else if (q.noperspective)
            .linear_noperspective
        else if (q.linear or comp.isFloat())
            .linear
        else
            .constant;
        if (kind == .position) m = switch (m) {
            .linear => .linear_noperspective,
            .linear_centroid => .linear_noperspective_centroid,
            .linear_sample => .linear_noperspective_sample,
            else => m,
        };
        return m;
    }

    const Shape = struct { rows: u32, cols: u32 };

    /// Rows and columns a signature element occupies.
    fn sigShape(e: *Emitter, ty: TypeId, row_major: bool) Error!Shape {
        return switch (e.t.get(ty)) {
            .scalar, .@"enum" => .{ .rows = 1, .cols = 1 },
            .vector => |v| .{ .rows = 1, .cols = v.len },
            .matrix => |m| if (row_major) .{ .rows = m.rows, .cols = m.cols } else .{ .rows = m.cols, .cols = m.rows },
            .array => |a| blk: {
                const s = try e.sigShape(a.elem, row_major);
                break :blk .{ .rows = s.rows * a.len, .cols = s.cols };
            },
            else => e.unsupported("signature elements of type '{s}' are not supported yet", .{try e.t.format(e.arena, ty)}),
        };
    }

    /// Row and column (within its element) of flattened component `k`.
    fn sigComponent(e: *Emitter, ty: TypeId, row_major: bool, k: u32) Error![2]u32 {
        switch (e.t.get(ty)) {
            .vector => return .{ 0, k },
            .matrix => |m| {
                const r = k / m.cols;
                const c = k % m.cols;
                return if (row_major) .{ r, c } else .{ c, r };
            },
            .array => |a| {
                const n = try e.flatCount(a.elem);
                const s = try e.sigShape(a.elem, row_major);
                const inner = try e.sigComponent(a.elem, row_major, k % n);
                return .{ (k / n) * s.rows + inner[0], inner[1] };
            },
            else => return .{ 0, 0 },
        }
    }

    fn sigCompType(e: *Emitter, ty: TypeId) Error!signature.CompType {
        if (e.t.get(ty) == .array) return e.sigCompType(e.t.get(ty).array.elem);
        const s = e.t.component(ty) orelse return e.unsupported("signature elements of type '{s}' are not supported yet", .{try e.t.format(e.arena, ty)});
        return switch (s) {
            .bool => .i1,
            .int, .literal_int => .i32,
            .uint => .u32,
            .float, .half, .literal_float => .f32,
            .min16float, .min10float => .f16,
            .min16int, .min12int => .i16,
            .min16uint => .u16,
            else => e.unsupported("signature elements of type '{s}' are not supported yet", .{try e.t.format(e.arena, ty)}),
        };
    }

    /// The scalar a signature component travels as.
    fn sigScalar(c: signature.CompType) Scalar {
        return switch (c) {
            .f32 => .float,
            .f16 => .float16,
            .i16 => .int16,
            .u16 => .uint16,
            .i32 => .int,
            else => .uint,
        };
    }

    /// A system value read with its own intrinsic (not a loadInput).
    fn systemValueInput(e: *Emitter, semantic: []const u8, ty: TypeId) Error!Lowered {
        const kind = signature.kindByName(semantic);
        const i32t = try e.dm.intType(32);
        const Sv = struct { kind: signature.SemanticKind, op: i64, fname: []const u8 };
        const svs = [_]Sv{
            .{ .kind = .sample_index, .op = 90, .fname = "dx.op.sampleIndex.i32" },
            .{ .kind = .coverage, .op = 91, .fname = "dx.op.coverage.i32" },
            .{ .kind = .inner_coverage, .op = 92, .fname = "dx.op.innerCoverage.i32" },
            .{ .kind = .view_id, .op = 138, .fname = "dx.op.viewID.i32" },
            .{ .kind = .start_vertex_location, .op = 256, .fname = "dx.op.startVertexLocation.i32" },
            .{ .kind = .start_instance_location, .op = 257, .fname = "dx.op.startInstanceLocation.i32" },
            .{ .kind = .primitive_id, .op = 108, .fname = "dx.op.primitiveID.i32" },
            .{ .kind = .gs_instance_id, .op = 100, .fname = "dx.op.gsInstanceID.i32" },
            .{ .kind = .output_control_point_id, .op = 107, .fname = "dx.op.outputControlPointID.i32" },
        };
        const out = try e.arena.alloc(Value, try e.flatCount(ty));
        if (kind == .cull_primitive) {
            for (out) |*o| o.* = try e.constant(try e.t.scalar(e.compOf(ty)), .{ .int = 0 });
            return .{ .scalars = out };
        }
        if (kind == .view_id) e.uses_view_id = true;
        if (kind == .inner_coverage) e.uses_inner_coverage = true;
        if (kind == .start_vertex_location or kind == .start_instance_location) e.uses_extended_command_info = true;
        if (kind == .domain_location) {
            const ft = try e.dm.getType(.float);
            const fn_i = try e.dxOp("dx.op.domainLocation.f32", ft, &.{ i32t, try e.dm.intType(8) }, .nounwind_readnone);
            for (out, 0..) |*o, c| {
                const v = try e.callOp(fn_i, ft, &.{ try e.i32Const(105), try e.dm.constInt(8, @intCast(c)) });
                o.* = try e.convertScalar(v, .float, e.compOf(ty));
            }
            return .{ .scalars = out };
        }
        for (svs) |sv| if (sv.kind == kind) {
            const fn_i = try e.dxOp(sv.fname, i32t, &.{i32t}, .nounwind_readnone);
            const v = try e.callOp(fn_i, i32t, &.{try e.i32Const(sv.op)});
            for (out) |*o| o.* = try e.convertScalar(v, .uint, e.compOf(ty));
            return .{ .scalars = out };
        };
        return e.unsupported("input '{s}' is not supported yet", .{semantic});
    }

    fn input(e: *Emitter, k: u32, ty: TypeId) Error!Lowered {
        return e.inputAt(k, ty, null);
    }

    fn inputAt(e: *Emitter, k: u32, ty: TypeId, vertex: ?u32) Error!Lowered {
        const entry = e.entry;
        if (entry.stage == .compute or entry.stage == .mesh or entry.stage == .amplification) return e.computeInput(k, ty);
        const el = entry.inputs.items[k];
        const se = if (e.in_elem[k]) |ei| &e.sig_in[ei] else return e.systemValueInput(el.semantic, ty);
        if (se.interpretation == .shadow) return e.systemValueInput(el.semantic, ty);
        const i32t = try e.dm.intType(32);
        const i8t = try e.dm.intType(8);
        const via = sigScalar(se.comp);
        const vt = try e.scalarTy(via);
        const fn_i = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.loadInput.{s}", .{e.overloadName(vt)}), vt, &.{ i32t, i32t, i32t, i8t, i32t }, .nounwind_readnone);
        const vx = if (vertex) |v| try e.i32Const(v) else try e.dm.constant(.{ .ty = i32t, .kind = .undef });
        const out = try e.arena.alloc(Value, try e.flatCount(ty));
        const to = e.compOf(ty);
        for (out, 0..) |*o, c| {
            const rc = try e.sigComponent(el.ty, el.row_major, @intCast(c));
            const v = try e.callOp(fn_i, vt, &.{ try e.i32Const(4), try e.i32Const(se.id), try e.i32Const(rc[0]), try e.dm.constInt(8, rc[1]), vx });
            o.* = try e.convertScalar(v, via, to);
            se.usage |= @as(u8, 1) << @intCast(rc[1]);
        }
        return .{ .scalars = out };
    }

    fn output(e: *Emitter, frame: *Frame, k: u32, value: Ref) Error!void {
        const el = e.entry.outputs.items[k];
        const se = if (e.out_elem[k]) |ei| &e.sig_out[ei] else return e.unsupported("output '{s}' is not supported yet", .{el.semantic});
        const vals = try e.scalars(frame, value);
        const i32t = try e.dm.intType(32);
        const i8t = try e.dm.intType(8);
        const void_ty = try e.voidTy();
        const via = sigScalar(se.comp);
        const vt = try e.scalarTy(via);
        const fn_i = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.storeOutput.{s}", .{e.overloadName(vt)}), void_ty, &.{ i32t, i32t, i32t, i8t, vt }, .nounwind);
        const from = e.compOf(el.ty);
        const split = e.out_split[k];
        for (vals, 0..) |v, c| {
            var rc = try e.sigComponent(el.ty, el.row_major, @intCast(c));
            var target = se;
            if (split > 0) {
                target = &e.sig_out[se.id + split - 1 - rc[0]];
                rc[0] = 0;
            }
            const sv = try e.convertScalar(v, from, via);
            _ = try e.callOp(fn_i, void_ty, &.{ try e.i32Const(5), try e.i32Const(target.id), try e.i32Const(rc[0]), try e.dm.constInt(8, rc[1]), sv });
            target.usage |= @as(u8, 1) << @intCast(rc[1]);
        }
    }

    /// A domain shader's patch constant (or a system value read with its
    /// own intrinsic).
    fn patchInput(e: *Emitter, k: u32, ty: TypeId) Error!Lowered {
        const el = e.entry.patch_constants.items[k];
        const se = if (e.pc_elem[k]) |ei| &e.sig_pc[ei] else return e.systemValueInput(el.semantic, ty);
        const i32t = try e.dm.intType(32);
        const i8t = try e.dm.intType(8);
        const via = sigScalar(se.comp);
        const vt = try e.scalarTy(via);
        const fn_i = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.loadPatchConstant.{s}", .{e.overloadName(vt)}), vt, &.{ i32t, i32t, i32t, i8t }, .nounwind_readnone);
        const out = try e.arena.alloc(Value, try e.flatCount(ty));
        for (out, 0..) |*o, c| {
            const rc = try e.sigComponent(el.ty, el.row_major, @intCast(c));
            const v = try e.callOp(fn_i, vt, &.{ try e.i32Const(104), try e.i32Const(se.id), try e.i32Const(rc[0]), try e.dm.constInt(8, rc[1]) });
            o.* = try e.convertScalar(v, via, e.compOf(ty));
            se.usage |= @as(u8, 1) << @intCast(rc[1]);
        }
        return .{ .scalars = out };
    }

    /// A patch constant written by the hull shader's patch constant
    /// function.
    fn patchOutput(e: *Emitter, frame: *Frame, k: u32, value: Ref) Error!void {
        const el = e.entry.patch_constants.items[k];
        const se = if (e.pc_elem[k]) |ei| &e.sig_pc[ei] else return e.unsupported("patch constant '{s}' is not supported yet", .{el.semantic});
        const vals = try e.scalars(frame, value);
        const i32t = try e.dm.intType(32);
        const i8t = try e.dm.intType(8);
        const void_ty = try e.voidTy();
        const via = sigScalar(se.comp);
        const vt = try e.scalarTy(via);
        const fn_i = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.storePatchConstant.{s}", .{e.overloadName(vt)}), void_ty, &.{ i32t, i32t, i32t, i8t, vt }, .nounwind);
        for (vals, 0..) |v, c| {
            const rc = try e.sigComponent(el.ty, el.row_major, @intCast(c));
            _ = try e.callOp(fn_i, void_ty, &.{ try e.i32Const(106), try e.i32Const(se.id), try e.i32Const(rc[0]), try e.dm.constInt(8, rc[1]), try e.convertScalar(v, e.compOf(el.ty), via) });
            se.usage |= @as(u8, 1) << @intCast(rc[1]);
        }
    }

    /// An output control point of the hull shader, read by its patch
    /// constant function.
    fn outputControlPoint(e: *Emitter, k: u32, ty: TypeId, point: u32) Error!Lowered {
        const el = e.entry.outputs.items[k];
        const se = if (e.out_elem[k]) |ei| &e.sig_out[ei] else return e.unsupported("output '{s}' is not supported yet", .{el.semantic});
        const i32t = try e.dm.intType(32);
        const i8t = try e.dm.intType(8);
        const via = sigScalar(se.comp);
        const vt = try e.scalarTy(via);
        const fn_i = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.loadOutputControlPoint.{s}", .{e.overloadName(vt)}), vt, &.{ i32t, i32t, i32t, i8t, i32t }, .nounwind_readnone);
        const out = try e.arena.alloc(Value, try e.flatCount(ty));
        for (out, 0..) |*o, c| {
            const rc = try e.sigComponent(el.ty, el.row_major, @intCast(c));
            const v = try e.callOp(fn_i, vt, &.{ try e.i32Const(103), try e.i32Const(se.id), try e.i32Const(rc[0]), try e.dm.constInt(8, rc[1]), try e.i32Const(point) });
            o.* = try e.convertScalar(v, via, e.compOf(ty));
        }
        return .{ .scalars = out };
    }

    /// The groupshared variable an amplification shader passes to
    /// DispatchMesh.
    fn findDispatchPayload(e: *Emitter) void {
        for (e.m.functions.items) |f| for (f.insts.items) |inst| switch (inst.op) {
            .intrinsic => |it| if (std.mem.eql(u8, it.name, "DispatchMesh") and it.args.len == 4) {
                var x = it.args[3];
                while (true) switch (f.inst(x).op) {
                    .global => |g| {
                        e.payload_global = g;
                        return;
                    },
                    .local_var => {
                        e.payload_local = .{ .func = f, .inst = x.index() };
                        return;
                    },
                    .access => |a| x = a.base,
                    else => break,
                };
            },
            else => {},
        };
    }

    /// The memory type of an HLSL value in struct-typed memory: vectors
    /// and matrices (by row) become arrays, bools 32-bit integers.
    // ------------------------------------------------------------------
    // SM 6.10 linear algebra

    /// `%dx.types.LinAlgMatrixC<c>M<m>N<n>U<use>S<scope>` = { i8* }.
    fn matrixType(e: *Emitter, ty: TypeId) Error!DType {
        for (e.linalg_types.items) |x| if (x.ty == ty) return x.dty;
        const la = e.t.get(ty).linalg;
        const name = try std.fmt.allocPrint(e.arena, "dx.types.LinAlgMatrixC{d}M{d}N{d}U{d}S{d}", .{ la.comp, la.m, la.n, la.use, la.scope });
        const dty = try e.dm.getType(.{ .@"struct" = .{ .name = name, .elems = &.{try e.dm.ptrType(try e.dm.intType(8))} } });
        try e.linalg_types.append(e.arena, .{ .ty = ty, .dty = dty });
        return dty;
    }

    fn containsLinAlg(e: *Emitter, ty: TypeId) bool {
        return switch (e.t.get(ty)) {
            .linalg => true,
            .array => |a| e.containsLinAlg(a.elem),
            .@"struct" => |st| for (st.fields.items) |fld| {
                if (e.containsLinAlg(fld.type)) break true;
            } else false,
            else => false,
        };
    }

    /// The overload suffix of an operand: `mC4M5N4U1S2`, `v4f32`, `f32`.
    fn linAlgSuffix(e: *Emitter, ty: TypeId) Error![]const u8 {
        return switch (e.t.get(ty)) {
            .linalg => |la| std.fmt.allocPrint(e.arena, "mC{d}M{d}N{d}U{d}S{d}", .{ la.comp, la.m, la.n, la.use, la.scope }),
            .vector => |v| std.fmt.allocPrint(e.arena, "v{d}{s}", .{ v.len, e.overloadName(try e.scalarTy(e.compOf(ty))) }),
            else => e.overloadName(try e.scalarTy(e.compOf(ty))),
        };
    }

    /// An operand of a linear algebra op: a matrix handle, a native vector
    /// or a scalar, with its LLVM type.
    fn linAlgValue(e: *Emitter, frame: *Frame, r: Ref) Error!struct { Value, DType } {
        const ty = frame.f.inst(r).ty;
        const vals = try e.scalars(frame, r);
        if (e.t.get(ty) == .linalg) return .{ vals[0], try e.matrixType(ty) };
        if (e.t.get(ty) == .vector) {
            const vt = try e.linAlgVectorType(ty);
            var v = try e.dm.constant(.{ .ty = vt, .kind = .undef });
            for (vals, 0..) |c, k| v = try e.add(vt, .{ .insertelement = .{ .vec = v, .val = c, .index = try e.dm.constInt(64, @intCast(k)) } });
            return .{ v, vt };
        }
        return .{ vals[0], try e.valueType(vals[0]) };
    }

    /// Writes an op result (a matrix, vector or scalar) to an `out`
    /// argument's storage.
    fn linAlgStore(e: *Emitter, frame: *Frame, dst: Ref, v: Value) Error!void {
        const ty = frame.f.inst(dst).ty;
        const vals = if (e.t.get(ty) == .vector) try e.linAlgSplit(v, ty) else try e.arena.dupe(Value, &.{v});
        switch (frame.vals[dst.index()]) {
            .typed => |tp| try e.typedStore(tp, vals, ty),
            .ptr => |p| try e.storePtr(p, vals, ty),
            else => return e.unsupported("this destination of a linear algebra result is not supported yet", .{}),
        }
    }

    /// A groupshared array argument: a pointer to its first element.
    fn linAlgMemory(e: *Emitter, frame: *Frame, r: Ref) Error!struct { Value, DType, []const u8 } {
        const arr = frame.f.inst(r).ty;
        if (e.t.get(arr) != .array) return e.unsupported("linear algebra memory that is not a groupshared array", .{});
        const elem = e.t.get(arr).array.elem;
        if (e.t.get(elem) != .scalar) return e.unsupported("groupshared arrays of type '{s}' for linear algebra are not supported yet", .{try e.t.format(e.arena, arr)});
        const p = switch (frame.vals[r.index()]) {
            .ptr => |x| x,
            else => return e.unsupported("linear algebra memory that is not a groupshared array", .{}),
        };
        if (p.addr_space != 3 or p.mixed or p.bool_storage) return e.unsupported("linear algebra memory that is not a groupshared array", .{});
        const pt = try e.dm.getType(.{ .pointer = .{ .elem = p.scalar_ty, .addr_space = 3 } });
        const off = if (p.offset_dyn) |d| d else try e.i32Const(@intCast(p.offset_const));
        const ptr = try e.add(pt, .{ .gep = .{ .elem = p.array_ty, .ptr = p.base, .indices = try e.arena.dupe(Value, &.{ try e.i32Const(0), off }) } });
        return .{ ptr, pt, e.overloadName(p.scalar_ty) };
    }

    /// `dx::__builtin_LinAlg_<name>(...)`: DXIL ops 322-342. Results go to
    /// the first (`out` / `ref`) argument, or are returned.
    fn linAlg(e: *Emitter, frame: *Frame, name: []const u8, ty: TypeId, args: []const Ref) Error!Lowered {
        const eq = std.mem.eql;
        if (e.profile.minor < 10) return e.unsupported("linear algebra needs shader model 6.10", .{});
        e.uses_linalg = true;
        const i32t = try e.dm.intType(32);
        const Op = struct { code: u32, op: []const u8 };
        const table = [_]struct { []const u8, Op }{
            .{ "MatrixMatrixMultiplyAccumulate", .{ .code = 322, .op = "linAlgMatrixMultiplyAccumulate" } },
            .{ "FillMatrix", .{ .code = 323, .op = "linAlgFillMatrix" } },
            .{ "CopyConvertMatrix", .{ .code = 324, .op = "linAlgCopyConvertMatrix" } },
            .{ "MatrixLoadFromDescriptor", .{ .code = 325, .op = "linAlgMatrixLoadFromDescriptor" } },
            .{ "MatrixLoadFromMemory", .{ .code = 326, .op = "linAlgMatrixLoadFromMemory" } },
            .{ "MatrixLength", .{ .code = 327, .op = "linAlgMatrixLength" } },
            .{ "MatrixGetCoordinate", .{ .code = 328, .op = "linAlgMatrixGetCoordinate" } },
            .{ "MatrixGetElement", .{ .code = 329, .op = "linAlgMatrixGetElement" } },
            .{ "MatrixSetElement", .{ .code = 330, .op = "linAlgMatrixSetElement" } },
            .{ "MatrixStoreToDescriptor", .{ .code = 331, .op = "linAlgMatrixStoreToDescriptor" } },
            .{ "MatrixStoreToMemory", .{ .code = 332, .op = "linAlgMatrixStoreToMemory" } },
            .{ "MatrixQueryAccumulatorLayout", .{ .code = 333, .op = "linAlgMatrixQueryAccumulatorLayout" } },
            .{ "MatrixMatrixMultiply", .{ .code = 334, .op = "linAlgMatrixMultiply" } },
            .{ "MatrixAccumulate", .{ .code = 335, .op = "linAlgMatrixAccumulate" } },
            .{ "MatrixVectorMultiply", .{ .code = 336, .op = "linAlgMatVecMul" } },
            .{ "MatrixVectorMultiplyAdd", .{ .code = 337, .op = "linAlgMatVecMulAdd" } },
            .{ "MatrixAccumulateToDescriptor", .{ .code = 338, .op = "linAlgMatrixAccumulateToDescriptor" } },
            .{ "MatrixAccumulateToMemory", .{ .code = 339, .op = "linAlgMatrixAccumulateToMemory" } },
            .{ "MatrixOuterProduct", .{ .code = 340, .op = "linAlgMatrixOuterProduct" } },
            .{ "Convert", .{ .code = 341, .op = "linAlgConvert" } },
            .{ "VectorAccumulateToDescriptor", .{ .code = 342, .op = "linAlgVectorAccumulateToDescriptor" } },
        };
        const op = for (table) |x| {
            if (eq(u8, x[0], name)) break x[1];
        } else return e.unsupported("linear algebra builtin '{s}' is not supported yet", .{name});

        // Which leading argument receives the result (out / ref), and the
        // overload suffixes in dxc's order.
        const out_first = switch (op.code) {
            322, 323, 324, 325, 326, 329, 330, 334, 335, 336, 337, 340, 341 => true,
            else => false,
        };
        var params: std.ArrayList(DType) = .empty;
        var vals: std.ArrayList(Value) = .empty;
        var suffix: std.ArrayList(u8) = .empty;
        try params.append(e.arena, i32t);
        try vals.append(e.arena, try e.i32Const(op.code));
        const ret_ty: DType = blk: {
            if (out_first) {
                const dst_ty = frame.f.inst(args[0]).ty;
                try suffix.print(e.arena, ".{s}", .{try e.linAlgSuffix(dst_ty)});
                break :blk if (e.t.get(dst_ty) == .linalg) try e.matrixType(dst_ty) else if (e.t.get(dst_ty) == .vector) try e.linAlgVectorType(dst_ty) else try e.scalarTy(e.compOf(dst_ty));
            }
            if (ty == TypeTable.void_type) break :blk try e.voidTy();
            break :blk if (e.t.get(ty) == .vector) try e.linAlgVectorType(ty) else try e.scalarTy(e.compOf(ty));
        };
        for (args[@intFromBool(out_first)..], @intFromBool(out_first)..) |a, k| {
            const aty = frame.f.inst(a).ty;
            // The `ref` destination of SetElement / accumulates is not an
            // operand (its value is the result).
            if (e.t.get(aty) == .array) {
                const mem = try e.linAlgMemory(frame, a);
                try vals.append(e.arena, mem[0]);
                try params.append(e.arena, mem[1]);
                try suffix.print(e.arena, ".{s}", .{mem[2]});
                continue;
            }
            if (e.t.get(aty) == .resource) {
                try vals.append(e.arena, (try e.resourceOf(frame, a)).handle);
                try params.append(e.arena, e.handle_ty);
                continue;
            }
            const v = try e.linAlgValue(frame, a);
            try vals.append(e.arena, v[0]);
            try params.append(e.arena, v[1]);
            const overloaded = e.t.get(aty) == .linalg or e.t.get(aty) == .vector or
                // The filled / set value.
                (op.code == 323 and k == 2) or (op.code == 330 and k == 3);
            if (overloaded) try suffix.print(e.arena, ".{s}", .{try e.linAlgSuffix(aty)});
        }
        // GetElement and the vector results name their result first.
        const fname = try std.fmt.allocPrint(e.arena, "dx.op.{s}{s}", .{ op.op, suffix.items });
        const attrs: module.FnAttrs = switch (op.code) {
            327, 328, 329, 333 => .nounwind_readnone,
            else => .nounwind,
        };
        const fn_i = try e.dxOp(fname, ret_ty, params.items, attrs);
        const r = try e.callOp(fn_i, ret_ty, vals.items);
        if (out_first) {
            try e.linAlgStore(frame, args[0], r);
            return .none;
        }
        if (ty == TypeTable.void_type) return .none;
        if (e.t.get(ty) == .vector) return .{ .scalars = try e.linAlgSplit(r, ty) };
        return .{ .scalars = try e.arena.dupe(Value, &.{r}) };
    }

    /// LinAlg vectors are native vectors, even of one element.
    fn linAlgVectorType(e: *Emitter, ty: TypeId) Error!DType {
        const v = e.t.get(ty).vector;
        return e.dm.getType(.{ .vector = .{ .len = v.len, .elem = try e.scalarTy(e.compOf(ty)) } });
    }

    fn linAlgSplit(e: *Emitter, v: Value, ty: TypeId) Error![]const Value {
        const n = e.t.get(ty).vector.len;
        const et = try e.scalarTy(e.compOf(ty));
        const out = try e.arena.alloc(Value, n);
        for (out, 0..) |*o, k| o.* = try e.add(et, .{ .extractelement = .{ .vec = v, .index = try e.i32Const(@intCast(k)) } });
        return out;
    }

    /// What the module does with matrices (PSV0), when it has any.
    fn linAlgTables(e: *Emitter) Error!?linalg_info.Tables {
        if (!e.uses_linalg) return null;
        return try linalg_info.collect(e.arena, &e.dm, try e.linAlgMatrices());
    }

    /// Each matrix type's attributes.
    fn linAlgMatrices(e: *Emitter) Error!linalg_info.Matrices {
        const mats = try e.arena.alloc(struct { module.TypeId, linalg_info.Matrix }, e.linalg_types.items.len);
        for (mats, e.linalg_types.items) |*m, x| {
            const la = e.t.get(x.ty).linalg;
            m.* = .{ x.dty, .{ .comp = la.comp, .m = la.m, .n = la.n, .use = la.use, .scope = la.scope } };
        }
        return mats;
    }

    /// `!dx.targetTypes`: each matrix type with its attributes.
    fn targetTypesMd(e: *Emitter) Error!void {
        if (e.linalg_types.items.len == 0) return;
        const dm = &e.dm;
        var nodes: std.ArrayList(module.MdId) = .empty;
        for (e.linalg_types.items) |x| {
            const la = e.t.get(x.ty).linalg;
            const undef = try dm.constant(.{ .ty = x.dty, .kind = .undef });
            try nodes.append(e.arena, try dm.mdNode(&.{ try dm.mdValue(x.dty, undef), try dm.mdI32(la.comp), try dm.mdI32(la.m), try dm.mdI32(la.n), try dm.mdI32(la.use), try dm.mdI32(la.scope) }));
        }
        try dm.addNamedMetadata("dx.targetTypes", nodes.items);
    }

    fn memoryType(e: *Emitter, ty: TypeId) Error!DType {
        return switch (e.t.get(ty)) {
            .linalg => e.matrixType(ty),
            // (A resource member's place in a struct-typed local.)
            .resource, .sampler => e.dm.intType(32),
            .scalar, .@"enum" => e.scalarTy(memScalar(e.compOf(ty))),
            .vector => |v| e.dm.getType(.{ .array = .{ .len = v.len, .elem = try e.scalarTy(memScalar(e.compOf(ty))) } }),
            .matrix => |m| e.dm.getType(.{ .array = .{ .len = m.rows, .elem = try e.dm.getType(.{ .array = .{ .len = m.cols, .elem = try e.scalarTy(memScalar(e.compOf(ty))) } }) } }),
            .array => |a| e.dm.getType(.{ .array = .{ .len = a.len, .elem = try e.memoryType(a.elem) } }),
            .@"struct" => |st| blk: {
                if (e.struct_types.get(ty)) |d| break :blk d;
                const elems = try e.arena.alloc(DType, st.fields.items.len);
                for (elems, st.fields.items) |*x, fld| x.* = try e.memoryType(fld.type);
                // A name another struct has taken gets a suffix, as LLVM's.
                const base = try std.fmt.allocPrint(e.arena, "struct.{s}", .{st.name});
                var name = base;
                var n: u32 = 0;
                while (for (e.dm.types.items) |x| {
                    if (x == .@"struct" and std.mem.eql(u8, x.@"struct".name, name)) break true;
                } else false) : (n += 1) name = try std.fmt.allocPrint(e.arena, "{s}.{d}", .{ base, n });
                const d = try e.dm.getType(.{ .@"struct" = .{ .name = name, .elems = elems } });
                try e.struct_types.put(e.arena, ty, d);
                break :blk d;
            },
            else => e.unsupported("payloads of type '{s}' are not supported yet", .{try e.t.format(e.arena, ty)}),
        };
    }

    /// The byte size of a payload (its memory type's allocation size).
    fn payloadSize(e: *Emitter, ty: TypeId) Error!u32 {
        return (try e.memLayout(ty))[0];
    }

    /// Size and alignment of `ty`'s memory type.
    fn memLayout(e: *Emitter, ty: TypeId) Error![2]u32 {
        switch (e.t.get(ty)) {
            .linalg => return .{ 8, 8 },
            .resource, .sampler => return .{ 4, 4 },
            .scalar, .@"enum", .vector, .matrix => {
                const sz = memScalar(e.compOf(ty)).size();
                return .{ sz * (e.t.componentCount(ty) orelse 1), sz };
            },
            .array => |a| {
                const el = try e.memLayout(a.elem);
                return .{ el[0] * a.len, el[1] };
            },
            .@"struct" => |st| {
                var off: u32 = 0;
                var al: u32 = 1;
                for (st.fields.items) |fld| {
                    const fl = try e.memLayout(fld.type);
                    off = std.mem.alignForward(u32, off, fl[1]) + fl[0];
                    al = @max(al, fl[1]);
                }
                return .{ std.mem.alignForward(u32, off, al), al };
            },
            else => return e.unsupported("payloads of type '{s}' are not supported yet", .{try e.t.format(e.arena, ty)}),
        }
    }

    /// GEP paths to the scalars of a value of `ty`, in flattened order.
    fn scalarPaths(e: *Emitter, ty: TypeId, prefix: []const Value, out: *std.ArrayList([]const Value)) Error!void {
        const sub = struct {
            fn f(em: *Emitter, p: []const Value, k: u32) Error![]const Value {
                const r = try em.arena.alloc(Value, p.len + 1);
                @memcpy(r[0..p.len], p);
                r[p.len] = try em.i32Const(k);
                return r;
            }
        }.f;
        switch (e.t.get(ty)) {
            .scalar, .@"enum", .linalg => try out.append(e.arena, prefix),
            .resource, .sampler => {},
            .vector => |v| for (0..v.len) |k| try out.append(e.arena, try sub(e, prefix, @intCast(k))),
            .matrix => |m| for (0..m.rows) |r| {
                const rp = try sub(e, prefix, @intCast(r));
                for (0..m.cols) |c| try out.append(e.arena, try sub(e, rp, @intCast(c)));
            },
            .array => |a| for (0..a.len) |k| try e.scalarPaths(a.elem, try sub(e, prefix, @intCast(k)), out),
            .@"struct" => |st| for (st.fields.items, 0..) |fld, k| try e.scalarPaths(fld.type, try sub(e, prefix, @intCast(k)), out),
            else => return e.unsupported("payloads of type '{s}' are not supported yet", .{try e.t.format(e.arena, ty)}),
        }
    }

    fn typedScalarPtr(e: *Emitter, tp: @FieldType(Lowered, "typed"), sub: []const Value, st: DType) Error!Value {
        const idx = try e.arena.alloc(Value, 1 + tp.path.len + sub.len);
        idx[0] = try e.i32Const(0);
        @memcpy(idx[1..][0..tp.path.len], tp.path);
        @memcpy(idx[1 + tp.path.len ..], sub);
        const pt = try e.dm.getType(.{ .pointer = .{ .elem = st, .addr_space = tp.addr_space } });
        return e.add(pt, .{ .gep = .{ .elem = tp.dty, .ptr = tp.base, .indices = idx } });
    }

    fn typedLoad(e: *Emitter, tp: @FieldType(Lowered, "typed"), ty: TypeId) Error!Lowered {
        var paths: std.ArrayList([]const Value) = .empty;
        try e.scalarPaths(ty, &.{}, &paths);
        const out = try e.arena.alloc(Value, paths.items.len);
        for (out, paths.items, 0..) |*o, sub, c| {
            const cty = try e.componentType(ty, @intCast(c));
            if (e.t.get(cty) == .linalg) {
                const mt = try e.matrixType(cty);
                o.* = try e.add(mt, .{ .load = .{ .ptr = try e.typedScalarPtr(tp, sub, mt), .@"align" = 0 } });
                continue;
            }
            const ct = e.compOf(cty);
            const st = try e.scalarTy(memScalar(ct));
            const raw = try e.add(st, .{ .load = .{ .ptr = try e.typedScalarPtr(tp, sub, st), .@"align" = memScalar(ct).size() } });
            o.* = if (ct == .bool) try e.add(try e.dm.intType(1), .{ .cmp = .{ .pred = 33, .lhs = raw, .rhs = try e.i32Const(0) } }) else raw;
        }
        return .{ .scalars = out };
    }

    fn typedStore(e: *Emitter, tp: @FieldType(Lowered, "typed"), vals: []const Value, ty: TypeId) Error!void {
        var paths: std.ArrayList([]const Value) = .empty;
        try e.scalarPaths(ty, &.{}, &paths);
        for (vals, paths.items, 0..) |v, sub, c| {
            const cty = try e.componentType(ty, @intCast(c));
            if (e.t.get(cty) == .linalg) {
                _ = try e.add(try e.voidTy(), .{ .store = .{ .ptr = try e.typedScalarPtr(tp, sub, try e.matrixType(cty)), .val = v, .@"align" = 0 } });
                continue;
            }
            const ct = e.compOf(cty);
            const st = try e.scalarTy(memScalar(ct));
            const sv = if (ct == .bool) try e.add(st, .{ .cast = .{ .op = .zext, .val = v } }) else v;
            _ = try e.add(try e.voidTy(), .{ .store = .{ .ptr = try e.typedScalarPtr(tp, sub, st), .val = sv, .@"align" = memScalar(ct).size() } });
        }
    }

    /// Indexes into a mesh output array: the first index picks the vertex
    /// or primitive, the rest a part of it (constant indices only).
    fn meshAccess(e: *Emitter, frame: *Frame, start: @FieldType(Lowered, "mesh"), indices: []const Ref) Error!Lowered {
        var m = start;
        for (indices) |x| {
            if (m.index == null) {
                m.index = (try e.scalars(frame, x))[0];
                m.ty = e.t.get(m.ty).array.elem;
                continue;
            }
            const k: u32 = switch (frame.f.inst(x).op) {
                .constant => |c| @intCast(c.int),
                else => return e.unsupported("dynamic indexing inside a mesh output is not supported yet", .{}),
            };
            switch (e.t.get(m.ty)) {
                .@"struct" => |st| {
                    for (st.fields.items[0..k]) |fld| m.offset += try e.flatCount(fld.type);
                    m.ty = st.fields.items[k].type;
                },
                .array => |arr| {
                    m.offset += k * try e.flatCount(arr.elem);
                    m.ty = arr.elem;
                },
                .vector => |v| {
                    m.offset += k;
                    m.ty = try e.t.scalar(v.elem);
                },
                .matrix => |mt| {
                    m.offset += k * mt.cols;
                    m.ty = try e.t.vector(mt.elem, mt.cols);
                },
                else => return e.unsupported("indexing this mesh output is not supported yet", .{}),
            }
        }
        return .{ .mesh = m };
    }

    /// Writes components [offset, offset + n) of a vertex or primitive, or
    /// a primitive's indices.
    fn meshStore(e: *Emitter, m: @FieldType(Lowered, "mesh"), vals: []const Value, ty: TypeId) Error!void {
        const index = m.index orelse return e.unsupported("storing a whole mesh output array is not supported yet", .{});
        const i32t = try e.dm.intType(32);
        const void_ty = try e.voidTy();
        if (m.kind == .indices) {
            if (m.offset != 0 or vals.len < 2) return e.unsupported("writing part of a primitive's indices is not supported yet", .{});
            const fn_i = try e.dxOp("dx.op.emitIndices", void_ty, &.{ i32t, i32t, i32t, i32t, i32t }, .nounwind);
            const v2 = if (vals.len > 2) vals[2] else try e.dm.constant(.{ .ty = i32t, .kind = .undef });
            _ = try e.callOp(fn_i, void_ty, &.{ try e.i32Const(169), index, vals[0], vals[1], v2 });
            return;
        }
        const entry = e.entry;
        const els = if (m.kind == .vertices) entry.outputs.items else entry.patch_constants.items;
        const map = if (m.kind == .vertices) e.out_elem else e.pc_elem;
        const sig = if (m.kind == .vertices) e.sig_out else e.sig_pc;
        const op: i64 = if (m.kind == .vertices) 171 else 172;
        const op_name = if (m.kind == .vertices) "storeVertexOutput" else "storePrimitiveOutput";
        for (vals, 0..) |v, c| {
            // Which element (leaf) and which of its components.
            var flat = m.offset + @as(u32, @intCast(c));
            var k: usize = 0;
            while (k < els.len) : (k += 1) {
                const n = try e.flatCount(els[k].ty);
                if (flat < n) break;
                flat -= n;
            }
            if (k == els.len) return e.unsupported("internal: mesh output component out of range", .{});
            const el = els[k];
            const se = if (map[k]) |ei| &sig[ei] else return e.unsupported("mesh output '{s}' is not supported yet", .{el.semantic});
            const via = sigScalar(se.comp);
            const vt = try e.scalarTy(via);
            const fn_i = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.{s}.{s}", .{ op_name, e.overloadName(vt) }), void_ty, &.{ i32t, i32t, i32t, try e.dm.intType(8), vt, i32t }, .nounwind);
            const rc = try e.sigComponent(el.ty, el.row_major, flat);
            const from = e.compOf(try e.componentType(ty, @intCast(c)));
            _ = try e.callOp(fn_i, void_ty, &.{ try e.i32Const(op), try e.i32Const(se.id), try e.i32Const(rc[0]), try e.dm.constInt(8, rc[1]), try e.convertScalar(v, from, via), index });
            se.usage |= @as(u8, 1) << @intCast(rc[1]);
        }
    }

    fn computeInput(e: *Emitter, k: u32, ty: TypeId) Error!Lowered {
        const el = e.entry.inputs.items[k];
        const eqi = std.ascii.eqlIgnoreCase;
        const i32t = try e.dm.intType(32);
        const n = try e.flatCount(ty);
        const out = try e.arena.alloc(Value, n);
        const Sv = struct { name: []const u8, op: i64, fname: []const u8 };
        const svs = [_]Sv{
            .{ .name = "SV_DispatchThreadID", .op = 93, .fname = "dx.op.threadId.i32" },
            .{ .name = "SV_GroupID", .op = 94, .fname = "dx.op.groupId.i32" },
            .{ .name = "SV_GroupThreadID", .op = 95, .fname = "dx.op.threadIdInGroup.i32" },
        };
        for (svs) |sv| if (eqi(el.semantic, sv.name)) {
            const fn_i = try e.dxOp(sv.fname, i32t, &.{ i32t, i32t }, .nounwind_readnone);
            for (out, 0..) |*o, c| {
                const v = try e.callOp(fn_i, i32t, &.{ try e.i32Const(sv.op), try e.i32Const(@intCast(c)) });
                o.* = try e.convertScalar(v, .uint, e.compOf(ty));
            }
            return .{ .scalars = out };
        };
        if (eqi(el.semantic, "SV_GroupIndex")) {
            const fn_i = try e.dxOp("dx.op.flattenedThreadIdInGroup.i32", i32t, &.{i32t}, .nounwind_readnone);
            const v = try e.callOp(fn_i, i32t, &.{try e.i32Const(96)});
            for (out) |*o| o.* = try e.convertScalar(v, .uint, e.compOf(ty));
            return .{ .scalars = out };
        }
        return e.systemValueInput(el.semantic, ty);
    }

    // ------------------------------------------------------------------
    // Module metadata and container

    fn shaderFlags(e: *Emitter) u64 {
        var flags: u64 = 0;
        if (e.uses_double) flags |= 1 << 2;
        if (e.uses_int64) flags |= 1 << 20;
        if (e.uses_min_precision) flags |= 1 << 5;
        var uavs: u32 = 0;
        var rov = false;
        for (e.resources.items) |r| {
            if (r.view) continue;
            if (r.kind == 11 or r.kind == 12) flags |= 1 << 4;
            if (r.class == .uav) uavs += @min(r.count, 9);
            if (r.rov) rov = true;
        }
        if (uavs > 8) flags |= 1 << 15;
        if (rov) flags |= 1 << 18;
        if (e.uses_typed_uav_load) flags |= 1 << 13;
        // Resources may not alias (DXIL 1.7+, when UAVs are used).
        if (uavs > 0 and e.profile.minor >= 7) flags |= 1 << 33;
        const stage = e.entry.stage;
        if (uavs > 0 and (stage == .vertex or stage == .geometry or stage == .hull or stage == .domain)) flags |= 1 << 16;
        for (e.sig_out) |el| switch (el.kind) {
            .render_target_array_index, .viewport_array_index => if (stage == .vertex) {
                flags |= 1 << 9;
            },
            .stencil_ref => flags |= 1 << 11,
            .shading_rate => flags |= 1 << 24,
            else => {},
        };
        for (e.sig_in) |el| if (el.kind == .shading_rate) {
            flags |= 1 << 24;
        };
        if (e.uses_view_id) flags |= 1 << 21;
        if (e.uses_resource_heap) flags |= 1 << 30;
        if (e.uses_barycentrics) flags |= 1 << 22;
        if (e.uses_tiled_resources) flags |= 1 << 12;
        if (e.uses_mesh_derivatives) flags |= 1 << 29;
        if (e.uses_extended_command_info) flags |= 1 << 38;
        if (e.uses_sampler_heap) flags |= 1 << 31;
        if (e.uses_wave) flags |= 1 << 19;
        if (e.uses_inner_coverage) flags |= 1 << 10;
        if (e.uses_ray_query) flags |= 1 << 25;
        if (e.uses_linalg) flags |= 1 << 41;
        // UseNativeLowPrecision: set whenever 16-bit types are native.
        if (e.native16()) flags |= 1 << 23;
        return flags;
    }

    /// The LLVM type a resource's metadata (and, in libraries, its global)
    /// points to: a named struct, an array of them for ranges.
    fn classType(e: *Emitter, r: Resource) Error!DType {
        const dm = &e.dm;
        const g = e.m.globals.items[r.global];
        const one: DType = blk: {
            if (r.kind == 15 or r.class == .cbuffer) {
                // tbuffers and cbuffers: a struct of one float.
                const name = if (r.rty != 0) try std.fmt.allocPrint(e.arena, "struct.{s}", .{try e.t.format(e.arena, r.elem)}) else g.name;
                break :blk try dm.getType(.{ .@"struct" = .{ .name = name, .elems = &.{try dm.getType(.float)} } });
            }
            if (r.class == .sampler) break :blk try dm.getType(.{ .@"struct" = .{ .name = if (r.comparison) "struct.SamplerComparisonState" else "struct.SamplerState", .elems = &.{try dm.intType(32)} } });
            if (r.kind == 16) break :blk try dm.getType(.{ .@"struct" = .{ .name = "struct.RaytracingAccelerationStructure", .elems = &.{try dm.intType(32)} } });
            var rty = g.ty;
            while (e.t.get(rty) == .array) rty = e.t.get(rty).array.elem;
            const rt = e.t.get(rty).resource;
            const class_name = try std.fmt.allocPrint(e.arena, "class.{s}<{s}>", .{ rt.name, try e.t.format(e.arena, r.elem) });
            // The class type only names the resource; aggregates get a
            // placeholder element.
            var elem_dt = try e.scalarTy(if (r.kind == 11) .uint else if (e.t.shape(r.elem) == null) .int else e.compOf(r.elem));
            // Typed resources carry their component count in the element
            // (the validator reads it from here).
            if (r.kind >= 1 and r.kind <= 10 and e.t.get(r.elem) == .vector) elem_dt = try dm.getType(.{ .vector = .{ .len = e.t.get(r.elem).vector.len, .elem = elem_dt } });
            break :blk try dm.getType(.{ .@"struct" = .{ .name = class_name, .elems = &.{elem_dt} } });
        };
        if (r.count == 1) return one;
        return dm.getType(.{ .array = .{ .len = if (r.count == std.math.maxInt(u32)) 0 else r.count, .elem = one } });
    }

    /// `dx.resources`: SRVs, UAVs, CBVs and samplers.
    fn resourcesMd(e: *Emitter) Error!?module.MdId {
        const dm = &e.dm;
        const i1t = try dm.intType(1);
        const mdI32 = struct {
            fn f(m: *module.Module, v: i64) !module.MdId {
                return m.mdI32(v);
            }
        }.f;
        const mdBool = struct {
            fn f(m: *module.Module, t: DType, v: bool) !module.MdId {
                return m.mdValue(t, try m.constant(.{ .ty = t, .kind = .{ .int = @intFromBool(v) } }));
            }
        }.f;
        // Resource lists by class.
        var lists: [4]std.ArrayList(?module.MdId) = .{ .empty, .empty, .empty, .empty };
        for (e.resources.items) |r| {
            if (r.view) continue;
            const g = e.m.globals.items[r.global];
            // Ranges: the pointer is to an array; unsized ones have size -1.
            const range: i64 = if (r.count == std.math.maxInt(u32)) -1 else r.count;
            const class_ty = try e.classType(r);
            // Libraries point at the resource's global and name it.
            const sym = if (r.lib_global) |lg| try dm.mdValue(try dm.ptrType(class_ty), .{ .global = lg }) else try dm.mdValue(try dm.ptrType(class_ty), try dm.constant(.{ .ty = try dm.ptrType(class_ty), .kind = .undef }));
            const name = try dm.mdString(if (r.lib_global != null) g.name else "");
            const b = g.binding;
            const head = [_]?module.MdId{ try mdI32(dm, r.id), sym, name, try mdI32(dm, @as(i32, @bitCast(b.space))), try mdI32(dm, @as(i32, @bitCast(b.index))), try mdI32(dm, range) };
            if (r.kind == 15) {
                // tbuffer / TextureBuffer<S>: an SRV of 32-bit elements.
                try lists[0].append(e.arena, try dm.mdNode(&(head ++ [_]?module.MdId{ try mdI32(dm, 15), try mdI32(dm, 0), try dm.mdNode(&.{ try mdI32(dm, 0), try mdI32(dm, 5) }) })));
                continue;
            }
            if (r.class == .cbuffer) {
                try lists[2].append(e.arena, try dm.mdNode(&(head ++ [_]?module.MdId{ try mdI32(dm, try e.cbufferSize(r)), null })));
                continue;
            }
            if (r.class == .sampler) {
                try lists[3].append(e.arena, try dm.mdNode(&(head ++ [_]?module.MdId{ try mdI32(dm, @intFromBool(r.comparison)), null })));
                continue;
            }
            if (r.kind == 16) {
                try lists[0].append(e.arena, try dm.mdNode(&(head ++ [_]?module.MdId{ try mdI32(dm, 16), try mdI32(dm, 0), try dm.mdNode(&.{ try mdI32(dm, 0), try mdI32(dm, 4) }) })));
                continue;
            }
            var fields: std.ArrayList(?module.MdId) = .empty;
            try fields.appendSlice(e.arena, &head);
            try fields.append(e.arena, try mdI32(dm, r.kind));
            if (r.class == .uav) {
                try fields.appendSlice(e.arena, &.{ try mdBool(dm, i1t, r.coherent), try mdBool(dm, i1t, r.has_counter), try mdBool(dm, i1t, r.rov) });
            } else try fields.append(e.arena, try mdI32(dm, 0)); // sample count
            const extra: ?module.MdId = switch (r.kind) {
                12 => try dm.mdNode(&.{ try mdI32(dm, 1), try mdI32(dm, try e.stride(r.elem)) }),
                1...10 => try dm.mdNode(&.{ try mdI32(dm, 0), try mdI32(dm, try e.compType(e.compOf(r.elem))) }),
                else => null,
            };
            try fields.append(e.arena, extra);
            try lists[@backingInt(r.class)].append(e.arena, try dm.mdNode(fields.items));
        }
        var resources: ?module.MdId = null;
        if (e.resources.items.len > 0) {
            var slots: [4]?module.MdId = .{ null, null, null, null };
            for (lists, 0..) |l, k| {
                if (l.items.len > 0) slots[k] = try dm.mdNode(l.items);
            }
            resources = try dm.mdNode(&slots);
        }
        return resources;
    }

    /// Per-function flags and compatibility of a library's functions, and
    /// the module's flags (their union, without function-local ones, plus
    /// resource-wide ones).
    fn libAnalysis(e: *Emitter, funcs: []const LibFunc) Error!struct { infos: []libinfo.Info, flags: u64 } {
        const globals = try e.arena.alloc(?libinfo.GlobalRes, e.dm.globals.items.len);
        @memset(globals, null);
        var uavs: u32 = 0;
        var rov = false;
        var raw = false;
        for (e.resources.items) |r| {
            if (r.view) continue;
            if (r.class == .uav) uavs += @min(r.count, 9);
            if (r.rov) rov = true;
            if ((r.class == .uav or r.class == .srv) and (r.kind == 11 or r.kind == 12)) raw = true;
            const lg = r.lib_global orelse continue;
            globals[lg] = .{ .uav = r.class == .uav, .typed_multi = r.kind >= 1 and r.kind <= 10 and try e.flatCount(r.elem) > 1 };
        }
        const opts: libinfo.Options = .{ .native16 = e.native16(), .res_may_not_alias = e.profile.minor >= 7, .globals = globals };
        const infos = try e.arena.alloc(libinfo.Info, funcs.len);
        var flags: u64 = 0;
        // Each function's own usage, then its callees' merged in (dxc's
        // ComputeShaderCompatInfo).
        const direct = try e.arena.alloc(?libinfo.Info, e.dm.functions.items.len);
        @memset(direct, null);
        for (funcs) |lf| direct[lf.func] = libinfo.analyze(&e.dm, &e.dm.functions.items[lf.func], opts);
        for (funcs, infos) |lf, *info| {
            info.* = direct[lf.func].?;
            var seen: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
            try seen.put(e.arena, lf.func, {});
            var k: usize = 0;
            while (k < seen.count()) : (k += 1) {
                const fi = seen.keys()[k];
                if (k > 0) info.merge(direct[fi] orelse continue);
                for (e.dm.functions.items[fi].insts.items) |inst| if (inst.op == .call) {
                    const callee = inst.op.call.callee;
                    if (e.dm.functions.items[callee].num_blocks > 0) try seen.put(e.arena, callee, {});
                };
            }
            flags |= info.flags;
        }
        flags &= ~@as(u64, libinfo.bit.local);
        if (raw) flags |= libinfo.bit.raw_structured;
        if (uavs > 8) flags |= 1 << 15;
        if (rov) flags |= 1 << 18;
        return .{ .infos = infos, .flags = flags };
    }

    fn native16(e: *Emitter) bool {
        return e.m.native_16bit;
    }

    fn writeLibraryModule(e: *Emitter, funcs: []const LibFunc) Error![]u8 {
        const dm = &e.dm;
        const mdI32 = struct {
            fn f(m: *module.Module, v: i64) !module.MdId {
                return m.mdI32(v);
            }
        }.f;
        const ident = try dm.mdNode(&.{try dm.mdString("zdxc 0.0.0")});
        const version = try dm.mdNode(&.{ try mdI32(dm, 1), try mdI32(dm, e.profile.minor) });
        const val_ver = try dm.mdNode(&.{ try mdI32(dm, 1), try mdI32(dm, 11) });
        const sm = try dm.mdNode(&.{ try dm.mdString("lib"), try mdI32(dm, e.profile.major), try mdI32(dm, e.profile.minor) });
        const resources = try e.resourcesMd();
        const analysis = try e.libAnalysis(funcs);

        // Function annotations: per parameter (return value first) its
        // input qualifier.
        const empty = try dm.mdNode(&.{});
        var annotations: std.ArrayList(?module.MdId) = .empty;
        try annotations.append(e.arena, try mdI32(dm, 1));
        for (funcs) |lf| {
            var ps: std.ArrayList(?module.MdId) = .empty;
            for (lf.ann) |pa| {
                // Field annotation: semantic (tag 4), component type (7).
                var fa: std.ArrayList(?module.MdId) = .empty;
                if (pa.semantic) |sem| try fa.appendSlice(e.arena, &.{ try mdI32(dm, 4), try dm.mdString(sem) });
                if (pa.comp) |ct| try fa.appendSlice(e.arena, &.{ try mdI32(dm, 7), try mdI32(dm, ct) });
                try ps.append(e.arena, try dm.mdNode(&.{ try mdI32(dm, pa.qual), if (fa.items.len > 0) try dm.mdNode(fa.items) else empty, empty }));
            }
            const fty = dm.functions.items[lf.func].ty;
            try annotations.append(e.arena, try dm.mdValue(try dm.ptrType(fty), .{ .function = lf.func }));
            try annotations.append(e.arena, try dm.mdNode(ps.items));
        }
        const type_annotations = try dm.mdNode(annotations.items);

        // Entries: the library's own (resources, module flags), then each
        // shader by name.
        var entries: std.ArrayList(module.MdId) = .empty;
        var lib_props: ?module.MdId = null;
        if (analysis.flags != 0) {
            const i64t = try dm.intType(64);
            lib_props = try dm.mdNode(&.{ try mdI32(dm, 0), try dm.mdValue(i64t, try dm.constant(.{ .ty = i64t, .kind = .{ .int = @bitCast(analysis.flags) } })) });
        }
        try entries.append(e.arena, try dm.mdNode(&.{ null, try dm.mdString(""), null, resources, lib_props }));
        const order = try e.arena.alloc(usize, funcs.len);
        for (order, 0..) |*o, k| o.* = k;
        std.sort.insertion(usize, order, funcs, struct {
            fn lt(fs: []const LibFunc, a: usize, b: usize) bool {
                return std.mem.order(u8, fs[a].name, fs[b].name) == .lt;
            }
        }.lt);
        const auto_space = try dm.mdNode(&.{try mdI32(dm, 0)});
        for (order) |k| {
            const lf = funcs[k];
            if (lf.stage == .library) continue;
            var props: std.ArrayList(?module.MdId) = .empty;
            try props.appendSlice(e.arena, &.{ try mdI32(dm, 8), try mdI32(dm, shaderKind(lf.stage)) });
            try props.appendSlice(e.arena, lf.stage_props);
            switch (lf.stage) {
                .miss, .callable, .anyhit, .closesthit => try props.appendSlice(e.arena, &.{ try mdI32(dm, 6), try mdI32(dm, lf.payload_size) }),
                else => {},
            }
            if (lf.stage == .anyhit or lf.stage == .closesthit) try props.appendSlice(e.arena, &.{ try mdI32(dm, 7), try mdI32(dm, lf.attr_size) });
            try props.appendSlice(e.arena, &.{ try mdI32(dm, 5), auto_space });
            const fty = dm.functions.items[lf.func].ty;
            try entries.append(e.arena, try dm.mdNode(&.{ try dm.mdValue(try dm.ptrType(fty), .{ .function = lf.func }), try dm.mdString(lf.name), lf.sigs, null, try dm.mdNode(props.items) }));
        }

        try e.targetTypesMd();
        try dm.addNamedMetadata("llvm.ident", &.{ident});
        try dm.addNamedMetadata("dx.version", &.{version});
        try dm.addNamedMetadata("dx.valver", &.{val_ver});
        try dm.addNamedMetadata("dx.shaderModel", &.{sm});
        if (resources) |r| try dm.addNamedMetadata("dx.resources", &.{r});
        if (funcs.len > 0) try dm.addNamedMetadata("dx.typeAnnotations", &.{type_annotations});
        try dm.addNamedMetadata("dx.entryPoints", entries.items);
        return dm.writeBitcode(dm.arena.child_allocator);
    }

    /// The library container: feature info, runtime data (RDAT) and the
    /// program.
    fn assembleLibrary(e: *Emitter, gpa: Allocator, funcs: []const LibFunc, bitcode: []const u8) Error![]u8 {
        const dxil_part = try shader.programPart(gpa, e.profile, bitcode);
        defer gpa.free(dxil_part);
        const analysis = try e.libAnalysis(funcs);
        var b = try rdat.Builder.init(gpa);
        defer b.deinit();
        // Resources: CBVs, samplers, SRVs, UAVs.
        var res_index: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        var count: u32 = 0;
        for ([_]Resource.Class{ .cbuffer, .sampler, .srv, .uav }) |cls| for (e.resources.items) |r| if (r.class == cls and !r.view) {
            const bd = e.binding(r);
            const upper: u32 = if (r.count == std.math.maxInt(u32)) std.math.maxInt(u32) else bd.index +% (r.count - 1);
            const rdat_class: u32 = switch (r.class) {
                .srv => 0,
                .uav => 1,
                .cbuffer => 2,
                .sampler => 3,
            };
            try b.addResource(.{ .class = rdat_class, .kind = r.kind, .id = r.id, .space = bd.space, .lower = bd.index, .upper = upper, .name = try b.string(e.m.globals.items[r.global].name), .flags = if (r.class == .uav) @as(u32, @intFromBool(r.coherent)) | @as(u32, @intFromBool(r.has_counter)) << 1 | @as(u32, @intFromBool(r.rov)) << 2 else 0 });
            if (r.lib_global) |lg| try res_index.put(e.arena, lg, count);
            count += 1;
        };
        const mats = try e.linAlgMatrices();
        for (funcs, analysis.infos) |lf, info| {
            const f = &e.dm.functions.items[lf.func];
            const name = try b.string(lf.name);
            const unmangled = try b.string(lf.unmangled);
            // Resources whose globals the function loads, in table order.
            var used: std.ArrayList(u32) = .empty;
            for (f.insts.items) |inst| if (inst.op == .load and inst.op.load.ptr == .global) {
                if (res_index.get(inst.op.load.ptr.global)) |ri| {
                    if (std.mem.indexOfScalar(u32, used.items, ri) == null) try used.append(e.arena, ri);
                }
            };
            std.mem.sort(u32, used.items, {}, std.sort.asc(u32));
            const resources = if (used.items.len > 0) try b.array(used.items) else rdat.null_ref;
            const props = if (e.uses_linalg) try linalg_info.rdatProperties(e.arena, &b, &try linalg_info.functionInfo(e.arena, &e.dm, mats, lf.func)) else rdat.null_ref;
            const kind = shaderKind(lf.stage);
            try b.addFunction(.{
                .name = name,
                .unmangled_name = unmangled,
                .resources = resources,
                .shader_kind = kind,
                .payload_size = lf.payload_size,
                .attribute_size = lf.attr_size,
                .feature_info1 = @truncate(libinfo.featureInfo(info.flags)),
                .feature_info2 = @truncate(libinfo.featureInfo(info.flags) >> 32),
                .shader_stage_flag = if (lf.stage == .library) info.mask & 0xffff else info.mask & (@as(u32, 1) << @intCast(kind)),
                .min_shader_target = (kind << 16) | (6 << 4) | libinfo.minMinor(info, if (lf.stage == .library) null else kind),
                .extended_properties = props,
            });
        }
        for (e.m.subobjects.items) |so| {
            var rec: [6]u32 = .{ @intFromEnum(so.kind), try b.string(so.name), 0, 0, 0, 0 };
            switch (so.kind) {
                .state_object_config, .raytracing_pipeline_config => rec[2] = so.ints[0],
                .raytracing_shader_config, .raytracing_pipeline_config1 => rec[2..4].* = so.ints,
                .subobject_to_exports_association => {
                    rec[2] = try b.string(so.strings[0]);
                    const idx = try e.arena.alloc(u32, so.exports.len);
                    for (idx, so.exports) |*x, name| x.* = try b.string(name);
                    rec[3] = try b.array(idx);
                },
                .hit_group => {
                    rec[2] = so.ints[0];
                    for (so.strings, 0..) |x, k| rec[3 + k] = try b.string(x);
                },
                .global_root_signature, .local_root_signature => {
                    const blob = try e.compileRootSignature(so.strings[0], if (so.kind == .local_root_signature) .local else .global);
                    rec[2] = try b.bytes(blob);
                    rec[3] = @intCast(blob.len);
                },
            }
            try b.addSubobject(rec);
        }
        const rdat_part = try b.finish();
        defer gpa.free(rdat_part);
        var sfi0: [8]u8 = @splat(0);
        std.mem.writeInt(u64, &sfi0, libinfo.featureInfo(analysis.flags), .little);
        return container.assemble(gpa, &.{
            .{ .fourcc = container.fourcc("SFI0"), .data = &sfi0 },
            .{ .fourcc = container.fourcc("RDAT"), .data = rdat_part },
            .{ .fourcc = container.fourcc("DXIL"), .data = dxil_part },
        });
    }

    /// Entry properties of the stage: thread group size and the GS / HS /
    /// DS / MS / AS state.
    fn stageProps(e: *Emitter, entry: ir.Entry, props: *std.ArrayList(?module.MdId)) Error!void {
        const dm = &e.dm;
        const mdI32 = struct {
            fn f(m: *module.Module, v: i64) !module.MdId {
                return m.mdI32(v);
            }
        }.f;
        const threads = try dm.mdNode(&.{ try mdI32(dm, entry.num_threads[0]), try mdI32(dm, entry.num_threads[1]), try mdI32(dm, entry.num_threads[2]) });
        if (entry.stage == .compute) try props.appendSlice(e.arena, &.{ try mdI32(dm, 4), threads });
        const payload_size: u32 = if (entry.mesh.payload) |p| try e.payloadSize(p) else 0;
        if (entry.stage == .mesh) {
            // MS state: thread group, max vertices, max primitives,
            // topology, payload size.
            const ms = entry.mesh;
            const state = try dm.mdNode(&.{ threads, try mdI32(dm, ms.max_vertices), try mdI32(dm, ms.max_primitives), try mdI32(dm, @intFromEnum(ms.topology)), try mdI32(dm, payload_size) });
            try props.appendSlice(e.arena, &.{ try mdI32(dm, 9), state });
        }
        if (entry.stage == .amplification) {
            const state = try dm.mdNode(&.{ threads, try mdI32(dm, payload_size) });
            try props.appendSlice(e.arena, &.{ try mdI32(dm, 10), state });
        }
        if (entry.stage == .geometry) {
            // GS state: input primitive, max vertex count, stream mask,
            // output topology, instance count.
            const gsi = entry.geometry;
            const state = try dm.mdNode(&.{ try mdI32(dm, @intFromEnum(gsi.input)), try mdI32(dm, gsi.max_vertex_count), try mdI32(dm, streamMask(gsi)), try mdI32(dm, gsTopology(gsi)), try mdI32(dm, gsi.instance_count) });
            try props.appendSlice(e.arena, &.{ try mdI32(dm, 1), state });
        }
        if (entry.stage == .hull) {
            // HS state: patch constant function, control point counts,
            // domain, partitioning, output primitive, max tess factor.
            const ts = entry.tess;
            const pc_ty = dm.functions.items[e.pc_fn.?].ty;
            const ft = try dm.getType(.float);
            const state = try dm.mdNode(&.{
                try dm.mdValue(try dm.ptrType(pc_ty), .{ .function = e.pc_fn.? }),
                try mdI32(dm, ts.input_control_points),
                try mdI32(dm, ts.output_control_points),
                try mdI32(dm, @intFromEnum(ts.domain)),
                try mdI32(dm, @intFromEnum(ts.partitioning)),
                try mdI32(dm, @intFromEnum(ts.output_topology)),
                try dm.mdValue(ft, try dm.constant(.{ .ty = ft, .kind = .{ .float_bits = @as(u32, @bitCast(ts.max_tess_factor)) } })),
            });
            try props.appendSlice(e.arena, &.{ try mdI32(dm, 3), state });
        }
        if (entry.stage == .domain) {
            const state = try dm.mdNode(&.{ try mdI32(dm, @intFromEnum(entry.tess.domain)), try mdI32(dm, entry.tess.input_control_points) });
            try props.appendSlice(e.arena, &.{ try mdI32(dm, 2), state });
        }
    }

    /// A root signature's serialized form (RTS0), or an error reported.
    fn compileRootSignature(e: *Emitter, text: []const u8, flags: rootsig.CompilationFlags) Error![]u8 {
        var d: rootsig.Diagnostic = .{};
        const version: rootsig.Version = if (e.m.rootsig_version == .v1_0) .v1_0 else .v1_1;
        const blob = try rootsig.compileWithOptions(e.arena, text, .{ .version = version, .flags = flags }, &d) orelse {
            _ = e.diags.report(.{ .severity = .@"error", .loc = .none }, "root signature error - {s}", .{d.message()});
            return error.Unsupported;
        };
        return blob;
    }

    fn writeModule(e: *Emitter, entry: ir.Entry) Error![]u8 {
        const dm = &e.dm;
        const mdI32 = struct {
            fn f(m: *module.Module, v: i64) !module.MdId {
                return m.mdI32(v);
            }
        }.f;

        const ident = try dm.mdNode(&.{try dm.mdString("zdxc 0.0.0")});
        const version = try dm.mdNode(&.{ try mdI32(dm, 1), try mdI32(dm, e.profile.minor) });
        const val_ver = try dm.mdNode(&.{ try mdI32(dm, 1), try mdI32(dm, 11) });
        const sm = try dm.mdNode(&.{ try dm.mdString(e.profile.kind.profilePrefix()), try mdI32(dm, e.profile.major), try mdI32(dm, e.profile.minor) });

        const resources = try e.resourcesMd();

        // Entry properties: shader flags and thread group size.
        var props: std.ArrayList(?module.MdId) = .empty;
        const flags = e.shaderFlags();
        if (flags != 0) {
            const i64t = try dm.intType(64);
            try props.appendSlice(e.arena, &.{ try mdI32(dm, 0), try dm.mdValue(i64t, try dm.constant(.{ .ty = i64t, .kind = .{ .int = @bitCast(flags) } })) });
        }
        try e.stageProps(entry, &props);
        const props_node = if (props.items.len > 0) try dm.mdNode(props.items) else null;
        var sigs: ?module.MdId = null;
        if (e.sig_in.len + e.sig_out.len + e.sig_pc.len > 0) {
            sigs = try dm.mdNode(&.{ try e.signatureMetadata(e.sig_in), try e.signatureMetadata(e.sig_out), try e.signatureMetadata(e.sig_pc) });
        }
        const main_ty = dm.functions.items[e.main_fn].ty;
        const fn_ref = try dm.mdValue(try dm.ptrType(main_ty), .{ .function = e.main_fn });
        const entry_md = try dm.mdNode(&.{ fn_ref, try dm.mdString(entry.name), sigs, resources, props_node });

        try e.targetTypesMd();
        try dm.addNamedMetadata("llvm.ident", &.{ident});
        try dm.addNamedMetadata("dx.version", &.{version});
        try dm.addNamedMetadata("dx.valver", &.{val_ver});
        try dm.addNamedMetadata("dx.shaderModel", &.{sm});
        if (resources) |r| try dm.addNamedMetadata("dx.resources", &.{r});
        try dm.addNamedMetadata("dx.entryPoints", &.{entry_md});
        return dm.writeBitcode(dm.arena.child_allocator);
    }

    /// `!{id, name, comp, kind, !{indices}, interp, rows, cols, row, col,
    /// !{usage tag, mask}}` per element.
    fn signatureMetadata(e: *Emitter, els: []const signature.Element) Error!?module.MdId {
        if (els.len == 0) return null;
        const dm = &e.dm;
        const i8t = try dm.intType(8);
        const nodes = try e.arena.alloc(?module.MdId, els.len);
        for (els, nodes) |el, *n| {
            const idx = try e.arena.alloc(?module.MdId, el.indices.len);
            for (el.indices, idx) |x, *m| m.* = try dm.mdI32(x);
            // (Libraries leave usage masks out, as dxc.)
            const usage: ?module.MdId = if (el.usage != 0 and !e.lib) try dm.mdNode(&.{ try dm.mdI32(3), try dm.mdI32(el.usage) }) else null;
            const row: i64 = if (el.start_row) |r| r else -1;
            const col: i64 = if (el.start_row != null) el.start_col else -1;
            n.* = try dm.mdNode(&.{
                try dm.mdI32(el.id),                                 try dm.mdString(el.name),
                try dm.mdValue(i8t, try dm.constInt(8, @intFromEnum(el.comp))), try dm.mdValue(i8t, try dm.constInt(8, @intFromEnum(el.kind))),
                try dm.mdNode(idx),                                  try dm.mdValue(i8t, try dm.constInt(8, @intFromEnum(el.interp))),
                try dm.mdI32(el.rows),                               try dm.mdValue(i8t, try dm.constInt(8, el.cols)),
                try dm.mdI32(row),                                   try dm.mdValue(i8t, try dm.constInt(8, col)),
                usage,
            });
        }
        return try dm.mdNode(nodes);
    }

    fn assemble(e: *Emitter, gpa: Allocator, entry: ir.Entry, bitcode: []const u8) Error![]u8 {
        const dxil_part = try shader.programPart(gpa, e.profile, bitcode);
        defer gpa.free(dxil_part);
        var binds: std.ArrayList(shader.ResourceBind) = .empty;
        // PSV lists CBVs, samplers, SRVs, then UAVs.
        for ([_]Resource.Class{ .cbuffer, .sampler, .srv, .uav }) |cls| for (e.resources.items) |r| if (r.class == cls and !r.view) {
            const b = e.binding(r);
            const res_type: u32 = switch (r.class) {
                .srv => switch (r.kind) {
                    12 => 5,
                    11, 16 => 4,
                    else => 3,
                },
                .uav => switch (r.kind) {
                    12 => if (r.has_counter) 9 else 8,
                    11 => 7,
                    else => 6,
                },
                .cbuffer => 2,
                .sampler => 1,
            };
            const upper: u32 = if (r.count == std.math.maxInt(u32)) std.math.maxInt(u32) else b.index + r.count - 1;
            try binds.append(e.arena, .{ .res_type = res_type, .space = b.space, .lower = b.index, .upper = upper, .kind = r.kind });
        };
        var stage_info: [16]u8 = @splat(0);
        switch (entry.stage) {
            .vertex => for (e.sig_out) |el| {
                if (el.kind == .position) stage_info[0] = 1; // OutputPositionPresent
            },
            .pixel => {
                for (e.sig_out) |el| switch (el.kind) {
                    .depth, .depth_less_equal, .depth_greater_equal => stage_info[0] = 1, // DepthOutput
                    else => {},
                };
                for (e.sig_in) |el| {
                    if (el.interp.isAnySample() or el.kind == .sample_index) stage_info[1] = 1; // SampleFrequency
                }
            },
            else => {},
        }
        if (entry.stage == .geometry) {
            const gsi = entry.geometry;
            std.mem.writeInt(u32, stage_info[0..4], @intFromEnum(gsi.input), .little);
            std.mem.writeInt(u32, stage_info[4..8], gsTopology(gsi), .little);
            std.mem.writeInt(u32, stage_info[8..12], streamMask(gsi), .little);
            for (e.sig_out) |el| {
                if (el.kind == .position) stage_info[12] = 1; // OutputPositionPresent
            }
        }
        if (entry.stage == .hull) {
            const ts = entry.tess;
            std.mem.writeInt(u32, stage_info[0..4], ts.input_control_points, .little);
            std.mem.writeInt(u32, stage_info[4..8], ts.output_control_points, .little);
            std.mem.writeInt(u32, stage_info[8..12], @intFromEnum(ts.domain), .little);
            std.mem.writeInt(u32, stage_info[12..16], @intFromEnum(ts.output_topology), .little);
        }
        if (entry.stage == .domain) {
            std.mem.writeInt(u32, stage_info[0..4], entry.tess.input_control_points, .little);
            for (e.sig_out) |el| {
                if (el.kind == .position) stage_info[4] = 1; // OutputPositionPresent
            }
            std.mem.writeInt(u32, stage_info[8..12], @intFromEnum(entry.tess.domain), .little);
        }
        const payload_size: u32 = if (entry.mesh.payload) |p| try e.payloadSize(p) else 0;
        if (entry.stage == .mesh) {
            std.mem.writeInt(u32, stage_info[0..4], e.groupshared_bytes, .little);
            std.mem.writeInt(u32, stage_info[8..12], payload_size, .little);
            std.mem.writeInt(u16, stage_info[12..14], @intCast(entry.mesh.max_vertices), .little);
            std.mem.writeInt(u16, stage_info[14..16], @intCast(entry.mesh.max_primitives), .little);
        }
        if (entry.stage == .amplification) std.mem.writeInt(u32, stage_info[0..4], payload_size, .little);
        const kind: shader.ShaderKind = switch (entry.stage) {
            .vertex => .vertex,
            .pixel => .pixel,
            .geometry => .geometry,
            .hull => .hull,
            .domain => .domain,
            .mesh => .mesh,
            .amplification => .amplification,
            else => .compute,
        };
        const threaded = entry.stage == .compute or entry.stage == .mesh or entry.stage == .amplification;
        const psv = try shader.psv(gpa, .{
            .kind = kind,
            .entry = entry.name,
            .stage_info = stage_info,
            .num_threads = if (threaded) entry.num_threads else .{ 0, 0, 0 },
            .mesh_topology = if (entry.stage == .mesh) @intFromEnum(entry.mesh.topology) else 0,
            .uses_view_id = e.uses_view_id,
            .resources = binds.items,
            .inputs = e.sig_in,
            .outputs = e.sig_out,
            .patch_constants = e.sig_pc,
            .groupshared_bytes = if (threaded) e.groupshared_bytes else 0,
            .max_vertex_count = if (entry.stage == .geometry) @intCast(entry.geometry.max_vertex_count) else 0,
            .linalg = try e.linAlgTables(),
        });
        defer gpa.free(psv);
        const domain: signature.Domain = if (entry.stage == .hull or entry.stage == .domain) @enumFromInt(@intFromEnum(entry.tess.domain)) else .undefined;
        const isg1 = try signature.programSignature(gpa, e.sig_in, true, domain);
        defer gpa.free(isg1);
        const osg1 = try signature.programSignature(gpa, e.sig_out, false, domain);
        defer gpa.free(osg1);
        const psg1 = try signature.programSignature(gpa, e.sig_pc, entry.stage == .domain, domain);
        defer gpa.free(psg1);
        var sfi0: [8]u8 = @splat(0);
        std.mem.writeInt(u64, &sfi0, libinfo.featureInfo(e.shaderFlags()), .little);
        var parts: std.ArrayList(container.Part) = .empty;
        try parts.appendSlice(e.arena, &.{
            .{ .fourcc = container.fourcc("SFI0"), .data = &sfi0 },
            .{ .fourcc = container.fourcc("ISG1"), .data = isg1 },
            .{ .fourcc = container.fourcc("OSG1"), .data = osg1 },
        });
        if (entry.stage == .hull or entry.stage == .domain or entry.stage == .mesh) try parts.append(e.arena, .{ .fourcc = container.fourcc("PSG1"), .data = psg1 });
        try parts.append(e.arena, .{ .fourcc = container.fourcc("PSV0"), .data = psv });
        if (entry.root_signature) |text| if (!e.m.strip_rootsig) {
            try parts.append(e.arena, .{ .fourcc = container.fourcc("RTS0"), .data = try e.compileRootSignature(text, .global) });
        };
        try parts.append(e.arena, .{ .fourcc = container.fourcc("DXIL"), .data = dxil_part });
        return container.assemble(gpa, parts.items);
    }
};

fn streamMask(g: ir.GeometryInfo) u32 {
    var m: u32 = 0;
    for (g.streams, 0..) |st, k| if (st != null) {
        m |= @as(u32, 1) << @intCast(k);
    };
    return if (m == 0) 1 else m;
}

/// DXIL::PrimitiveTopology of the (first used) output stream.
fn gsTopology(g: ir.GeometryInfo) u32 {
    for (g.streams) |st| if (st) |k| return switch (k) {
        .point => 1,
        .line => 3,
        .triangle => 5,
    };
    return 1;
}

fn isResourceType(t: *TypeTable, ty: TypeId) bool {
    return switch (t.get(ty)) {
        .resource, .sampler => true,
        else => false,
    };
}

const isRayQuery = @import("../ir/lower.zig").isRayQuery;

fn reachableBlocks(a: Allocator, f: *const ir.Function) Allocator.Error![]bool {
    const seen = try a.alloc(bool, f.blocks.items.len);
    @memset(seen, false);
    var stack: std.ArrayList(u32) = .empty;
    try stack.append(a, 0);
    while (stack.pop()) |b| {
        if (seen[b]) continue;
        seen[b] = true;
        switch (f.blocks.items[b].term) {
            .br => |t| try stack.append(a, t.index()),
            .cond_br => |c| try stack.appendSlice(a, &.{ c.then.index(), c.@"else".index() }),
            .@"switch" => |sw| {
                try stack.append(a, sw.default.index());
                for (sw.cases) |c| try stack.append(a, c.block.index());
            },
            else => {},
        }
    }
    return seen;
}
