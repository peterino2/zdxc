//! IR -> SPIR-V (Vulkan). Follows dxc's conventions: the HLSL entry is a
//! function called from a parameterless wrapper that loads the stage
//! inputs; resources use dxc's default register-to-binding mapping
//! (binding = register number, descriptor set = register space).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("../ir/ir.zig");
const types = @import("../sema/types.zig");
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
const StorageClass = enum(u32) { uniform_constant = 0, input = 1, uniform = 2, output = 3, workgroup = 4, private = 6, function = 7, storage_buffer = 12 };

const Capability = enum(u32) { shader = 1, float16 = 9, float64 = 10, int64 = 11, int16 = 22, sampled_buffer = 46, image_buffer = 47, storage_image_extended_formats = 49, image_query = 50 };

pub fn emit(gpa: Allocator, m: *const ir.Module, diags: *diag.Diagnostics) Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var e: Emitter = .{ .arena = arena_state.allocator(), .b = .init(gpa), .m = m, .t = m.types, .diags = diags };
    defer e.b.deinit();
    try e.module();
    return e.b.finish(builder.spv_1_0);
}

const Emitter = struct {
    arena: Allocator,
    b: Builder,
    m: *const ir.Module,
    t: *TypeTable,
    diags: *diag.Diagnostics,

    value_types: std.AutoHashMapUnmanaged(TypeId, Id) = .empty,
    /// Explicitly laid out variants of arrays and structs (cbuffers).
    layout_types: std.AutoHashMapUnmanaged(TypeId, Id) = .empty,
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
    buffer_elem_ptr: []Id = &.{},
    /// Entry inputs / outputs: interface variable and its value type.
    inputs: []Interface = &.{},
    outputs: []Interface = &.{},
    interface_ids: std.ArrayList(Id) = .empty,

    // Per function.
    vals: []Id = &.{},
    f: *const ir.Function = undefined,

    const Interface = struct { var_id: Id, ty: TypeId };

    fn unsupported(e: *Emitter, comptime fmt: []const u8, args: anytype) Error {
        _ = e.diags.report(.{ .severity = .@"error", .loc = .none }, "SPIR-V code generation: " ++ fmt, args);
        return error.Unsupported;
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
            else => return e.unsupported("type '{s}' is not supported yet", .{try e.t.format(e.arena, ty)}),
        };
        try e.value_types.put(e.arena, ty, id);
        return id;
    }

    /// `ty` with explicit (cbuffer) layout decorations: array strides and
    /// member offsets. Scalars and vectors are the plain types.
    fn layoutTypeId(e: *Emitter, ty: TypeId) Error!Id {
        switch (e.t.get(ty)) {
            // Externally visible storage holds bools as uints.
            .scalar, .vector, .@"enum" => return e.typeId(if (e.t.component(ty) == .bool) try e.t.withComponent(ty, .uint) else ty),
            else => {},
        }
        if (e.layout_types.get(ty)) |id| return id;
        const id = e.b.newId();
        switch (e.t.get(ty)) {
            .array => |a| {
                const elem = try e.layoutTypeId(a.elem);
                try e.b.emit(.types_globals, .type_array, &.{ id, elem, try e.constUint(a.len) });
                const stride = layout.arrayStride(e.t, a.elem, .vk_relaxed) catch return e.unsupported("constant buffer member type", .{});
                try e.b.emit(.annotations, .decorate, &.{ id, 6, stride }); // ArrayStride
            },
            .@"struct" => |s| {
                var ops: std.ArrayList(u32) = .empty;
                try ops.append(e.arena, id);
                for (s.fields.items) |f| try ops.append(e.arena, try e.layoutTypeId(f.type));
                try e.b.emit(.types_globals, .type_struct, ops.items);
                const offs = layout.fieldOffsets(e.arena, e.t, s, .vk_relaxed) catch return e.unsupported("constant buffer member type '{s}'", .{s.name});
                for (s.fields.items, offs, 0..) |f, o, k| {
                    try e.b.emit(.annotations, .member_decorate, &.{ id, @intCast(k), 35, o }); // Offset
                    try e.b.emitWithString(.debug_names, .member_name, &.{ id, @intCast(k) }, f.name, &.{});
                }
            },
            else => return e.unsupported("constant buffer members of type '{s}' are not supported yet", .{try e.t.format(e.arena, ty)}),
        }
        try e.layout_types.put(e.arena, ty, id);
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
            .int16, .uint16 => return e.constBits(ty_id, @as(u16, @truncate(@as(u64, @bitCast(intOf(c))))), 1),
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
        const entry = m.entry orelse return e.unsupported("no entry point", .{});
        try e.b.emit(.debug_names, .source, &.{ 5, 600 }); // HLSL
        e.void_id = try e.typeId(TypeTable.void_type);
        try e.cap(.shader);

        e.func_ids = try e.arena.alloc(Id, m.functions.items.len);
        for (e.func_ids) |*id| id.* = e.b.newId();

        try e.emitGlobals();
        try e.emitInterface(entry);

        for (m.functions.items, 0..) |f, fi| try e.emitFunction(f, @intCast(fi));

        for (e.capabilities.keys()) |c| try e.b.emit(.capabilities, .capability, &.{@backingInt(c)});
        if (e.glsl != 0) try e.b.emitWithString(.ext_inst_imports, .ext_inst_import, &.{e.glsl}, "GLSL.std.450", &.{});
        try e.b.emit(.memory_model, .memory_model, &.{ 0, 1 }); // Logical GLSL450
        const model: u32 = switch (entry.stage) {
            .vertex => 0,
            .hull => 1,
            .domain => 2,
            .geometry => 3,
            .pixel => 4,
            .compute => 5,
            .library => return e.unsupported("library targets are not supported", .{}),
        };
        const wrapper = e.func_ids[entry.wrapper];
        try e.b.emitWithString(.entry_points, .entry_point, &.{ model, wrapper }, entry.name, e.interface_ids.items);
        switch (entry.stage) {
            .compute => try e.b.emit(.execution_modes, .execution_mode, &.{ wrapper, 17, entry.num_threads[0], entry.num_threads[1], entry.num_threads[2] }),
            .pixel => {
                try e.b.emit(.execution_modes, .execution_mode, &.{ wrapper, 7 }); // OriginUpperLeft
                for (entry.outputs.items) |o| if (std.ascii.eqlIgnoreCase(o.semantic, "SV_Depth")) {
                    try e.b.emit(.execution_modes, .execution_mode, &.{ wrapper, 12 }); // DepthReplacing
                };
            },
            else => {},
        }
        for (m.functions.items, e.func_ids) |f, id| try e.b.emitWithString(.debug_names, .name, &.{id}, f.name, &.{});
    }

    fn emitGlobals(e: *Emitter) Error!void {
        const m = e.m;
        e.global_vars = try e.arena.alloc(Id, m.globals.items.len);
        e.buffer_elem_ptr = try e.arena.alloc(Id, m.globals.items.len);
        @memset(e.buffer_elem_ptr, 0);
        // Registers without an explicit binding take the next free one.
        var used: std.AutoHashMapUnmanaged(struct { u32, u32 }, void) = .empty;
        for (m.globals.items) |g| if (g.binding.explicit) try used.put(e.arena, .{ g.binding.space, g.binding.index }, {});
        var next_free: u32 = 0;
        for (m.globals.items, 0..) |g, gi| {
            switch (g.space) {
                .resource => {
                    const r = switch (e.t.get(g.ty)) {
                        .resource => |r| r,
                        else => return e.unsupported("global '{s}' of type '{s}' is not supported yet", .{ g.name, try e.t.format(e.arena, g.ty) }),
                    };
                    const var_id = e.b.newId();
                    switch (r.kind) {
                        .structured_buffer, .rw_structured_buffer, .byte_address_buffer, .rw_byte_address_buffer => {
                            var elem_ty = if (r.kind == .byte_address_buffer or r.kind == .rw_byte_address_buffer) try e.t.scalar(.uint) else r.elem;
                            // Buffers hold bools as uints.
                            if (e.t.component(elem_ty) == .bool) elem_ty = try e.t.withComponent(elem_ty, .uint);
                            const elem = try e.typeId(elem_ty);
                            const elem_layout = try e.std430(elem_ty);
                            const rt = e.b.newId();
                            try e.b.emit(.types_globals, .type_runtime_array, &.{ rt, elem });
                            try e.b.emit(.annotations, .decorate, &.{ rt, 6, elem_layout.size }); // ArrayStride
                            const st = e.b.newId();
                            try e.b.emit(.types_globals, .type_struct, &.{ st, rt });
                            try e.b.emit(.annotations, .member_decorate, &.{ st, 0, 35, 0 }); // Offset 0
                            if (!r.kind.isWritable()) try e.b.emit(.annotations, .member_decorate, &.{ st, 0, 24 }); // NonWritable
                            try e.b.emit(.annotations, .decorate, &.{ st, 3 }); // BufferBlock
                            try e.b.emitWithString(.debug_names, .name, &.{st}, try std.fmt.allocPrint(e.arena, "type.{s}.{s}", .{ r.name, try e.typeLabel(elem_ty) }), &.{});
                            const ptr = try e.pointerType(.uniform, st);
                            try e.b.emit(.types_globals, .variable, &.{ ptr, var_id, @backingInt(StorageClass.uniform) });
                            e.buffer_elem_ptr[gi] = try e.pointerType(.uniform, elem);
                        },
                        else => return e.unsupported("resource type '{s}' is not supported yet", .{r.name}),
                    }
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
                    const st = try e.layoutTypeId(g.ty);
                    try e.b.emit(.annotations, .decorate, &.{ st, 2 }); // Block
                    const ptr = try e.pointerType(.uniform, st);
                    const var_id = e.b.newId();
                    try e.b.emit(.types_globals, .variable, &.{ ptr, var_id, @backingInt(StorageClass.uniform) });
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
                    const sc: StorageClass = if (g.space == .groupshared) .workgroup else .private;
                    const ptr = try e.pointerType(sc, ty);
                    const var_id = e.b.newId();
                    try e.b.emit(.types_globals, .variable, &.{ ptr, var_id, @backingInt(sc) });
                    try e.b.emitWithString(.debug_names, .name, &.{var_id}, g.name, &.{});
                    e.global_vars[gi] = var_id;
                },
                else => return e.unsupported("global '{s}' is not supported yet", .{g.name}),
            }
        }
    }

    /// `float`, `v4float`: dxc's type names inside buffer type names.
    fn typeLabel(e: *Emitter, ty: TypeId) Error![]const u8 {
        return switch (e.t.get(ty)) {
            .scalar => |s| storageScalar(s).name(),
            .vector => |v| std.fmt.allocPrint(e.arena, "v{d}{s}", .{ v.len, storageScalar(v.elem).name() }),
            else => e.t.format(e.arena, ty),
        };
    }

    const Layout = struct { size: u32, alignment: u32 };

    fn std430(e: *Emitter, ty: TypeId) Error!Layout {
        return switch (e.t.get(ty)) {
            .scalar => |s| .{ .size = storageScalar(s).size(), .alignment = storageScalar(s).size() },
            .vector => |v| blk: {
                const s = storageScalar(v.elem).size();
                const n: u32 = if (v.len == 3) 4 else v.len;
                break :blk .{ .size = s * v.len, .alignment = s * n };
            },
            else => e.unsupported("buffer elements of type '{s}' are not supported yet", .{try e.t.format(e.arena, ty)}),
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
        if (stage == .compute and input) {
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
        if (stage == .pixel and !input and eq(n, "SV_Depth")) return .{ .id = 22, .ty = try t.scalar(.float) }; // FragDepth
        if (eq(n, "SV_Target") or eq(n, "SV_VertexID") or eq(n, "SV_InstanceID") or eq(n, "SV_Position")) return null;
        if (el.system_value) return e.unsupported("system value '{s}' is not supported yet", .{n});
        return null;
    }

    fn emitInterface(e: *Emitter, entry: ir.Entry) Error!void {
        e.inputs = try e.arena.alloc(Interface, entry.inputs.items.len);
        e.outputs = try e.arena.alloc(Interface, entry.outputs.items.len);
        var location: [2]u32 = .{ 0, 0 };
        for ([_][]const ir.SigElement{ entry.inputs.items, entry.outputs.items }, 0..) |els, dir| {
            const input = dir == 0;
            const out = if (input) e.inputs else e.outputs;
            for (els, out) |el, *iface| {
                const bi = try e.builtinFor(el, input, entry.stage);
                // bool is not allowed in located interface variables.
                const ty = if (bi) |x| x.ty else if (e.t.component(el.ty) == .bool) try e.t.withComponent(el.ty, .uint) else el.ty;
                const sc: StorageClass = if (input) .input else .output;
                const ptr = try e.pointerType(sc, try e.typeId(ty));
                const var_id = e.b.newId();
                try e.b.emit(.types_globals, .variable, &.{ ptr, var_id, @backingInt(sc) });
                if (bi) |x| {
                    try e.b.emit(.annotations, .decorate, &.{ var_id, 11, x.id }); // BuiltIn
                } else {
                    const loc = if (std.ascii.eqlIgnoreCase(el.semantic, "SV_Target")) el.semantic_index else location[dir];
                    try e.b.emit(.annotations, .decorate, &.{ var_id, 30, loc }); // Location
                    location[dir] = @max(location[dir], loc) + try e.locationCount(ty);
                    // Integer fragment inputs cannot be interpolated.
                    if (input and entry.stage == .pixel and !e.t.component(ty).?.isFloat()) {
                        try e.b.emit(.annotations, .decorate, &.{ var_id, 14 }); // Flat
                    }
                }
                const name = try std.fmt.allocPrint(e.arena, "{s}.var.{s}{d}", .{ if (input) "in" else "out", el.semantic, el.semantic_index });
                try e.b.emitWithString(.debug_names, .name, &.{var_id}, name, &.{});
                iface.* = .{ .var_id = var_id, .ty = ty };
                try e.interface_ids.append(e.arena, var_id);
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

    fn emitFunction(e: *Emitter, f: *const ir.Function, fi: u32) Error!void {
        e.f = f;
        e.vals = try e.arena.alloc(Id, f.insts.items.len);
        @memset(e.vals, 0);
        const ret = try e.typeId(f.ret);
        const params = try e.arena.alloc(Id, f.params.len);
        for (f.params, params) |p, *out| {
            const t = try e.typeId(p.ty);
            out.* = if (p.by_ref) try e.pointerType(.function, t) else t;
        }
        const fn_ty = try e.functionType(ret, params);
        try e.b.emit(.functions, .function, &.{ ret, e.func_ids[fi], 0, fn_ty });
        const param_ids = try e.arena.alloc(Id, f.params.len);
        for (params, param_ids) |p, *id| {
            id.* = e.b.newId();
            try e.b.emit(.functions, .function_parameter, &.{ p, id.* });
        }
        for (f.params, param_ids) |p, id| try e.b.emitWithString(.debug_names, .name, &.{id}, p.name, &.{});

        const order = try blockOrder(e.arena, f);
        const labels = try e.arena.alloc(Id, f.blocks.items.len);
        for (labels) |*l| l.* = e.b.newId();

        // Constants and parameters first (they may be used in any block).
        for (f.insts.items, 0..) |inst, i| switch (inst.op) {
            .constant => |c| e.vals[i] = try e.constant(inst.ty, c),
            .param => |p| e.vals[i] = param_ids[p],
            else => {},
        };

        for (order, 0..) |bi, oi| {
            try e.b.emit(.functions, .label, &.{labels[bi]});
            if (oi == 0) {
                // OpVariables must open the first block.
                for (f.insts.items, 0..) |inst, i| if (inst.op == .local_var) {
                    const ptr = try e.pointerType(.function, try e.typeId(inst.ty));
                    e.vals[i] = e.b.newId();
                    try e.b.emit(.functions, .variable, &.{ ptr, e.vals[i], @backingInt(StorageClass.function) });
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
                .ret => |v| if (v == .none) try e.b.emit(.functions, .@"return", &.{}) else try e.b.emit(.functions, .return_value, &.{e.vals[v.index()]}),
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

    /// Scalars and 1-component vectors (both a SPIR-V scalar).
    fn isScalarLike(e: *Emitter, ty: TypeId) bool {
        return switch (e.t.get(ty)) {
            .scalar, .@"enum" => true,
            .vector => |v| v.len == 1,
            else => false,
        };
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
            .global => |g| e.vals[ri] = e.global_vars[g],
            .load => |p| {
                // Resources stay as their variables (accessed by chains).
                if (i.ptr == .none and (e.t.get(i.ty) == .resource or e.t.get(i.ty) == .sampler)) {
                    e.vals[ri] = e.val(p);
                    return;
                }
                if (f.inst(p).ptr == .cbuffer and e.t.component(i.ty) == .bool and e.t.shape(i.ty) != null) {
                    const stored = try e.t.withComponent(i.ty, .uint);
                    const raw = try e.op1(.load, stored, &.{e.val(p)});
                    e.vals[ri] = try e.convert(raw, stored, i.ty);
                    return;
                }
                if (f.inst(p).ptr == .cbuffer and try e.layoutTypeId(i.ty) != try e.typeId(i.ty)) {
                    return e.unsupported("loading whole arrays or structs from constant buffers is not supported yet", .{});
                }
                e.vals[ri] = try e.op1(.load, i.ty, &.{e.val(p)});
            },
            .store => |s| try e.b.emit(.functions, .store, &.{ e.val(s.ptr), e.val(s.value) }),
            .access => |a| {
                const sc: StorageClass = switch (i.ptr) {
                    .function => .function,
                    .private => .private,
                    .groupshared => .workgroup,
                    .cbuffer => .uniform,
                    else => return e.unsupported("access into this storage is not supported yet", .{}),
                };
                const ptr_ty = try e.pointerType(sc, if (i.ptr == .cbuffer) try e.layoutTypeId(i.ty) else try e.typeId(i.ty));
                var ops: std.ArrayList(u32) = .empty;
                try ops.appendSlice(e.arena, &.{ ptr_ty, 0, e.val(a.base) });
                // Indices into 1-vectors (SPIR-V scalars) are dropped.
                var cur = f.inst(a.base).ty;
                for (a.indices) |x| {
                    const skip = e.isScalarLike(cur);
                    cur = switch (e.t.get(cur)) {
                        .array => |arr| arr.elem,
                        .vector => |v| try e.t.scalar(v.elem),
                        .matrix => |mt| try e.t.vector(mt.elem, mt.cols),
                        .@"struct" => |st| blk: {
                            const k = f.inst(x);
                            break :blk if (k.op == .constant) st.fields.items[@intCast(k.op.constant.int)].type else cur;
                        },
                        else => cur,
                    };
                    if (!skip) try ops.append(e.arena, e.val(x));
                }
                if (ops.items.len == 3) {
                    e.vals[ri] = e.val(a.base);
                    return;
                }
                e.vals[ri] = e.b.newId();
                ops.items[1] = e.vals[ri];
                try e.b.emit(.functions, .access_chain, ops.items);
            },
            .binary => |x| e.vals[ri] = try e.binary(x.op, i.ty, e.val(x.lhs), e.val(x.rhs)),
            .unary => |x| {
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
                e.vals[ri] = try e.op1(op, i.ty, &.{ e.val(x.lhs), e.val(x.rhs) });
            },
            .convert => |x| e.vals[ri] = try e.convert(e.val(x), f.inst(x).ty, i.ty),
            .bitcast => |x| e.vals[ri] = try e.op1(.bitcast, i.ty, &.{e.val(x)}),
            .splat => |x| {
                const n = e.t.componentCount(i.ty).?;
                if (n == 1) {
                    e.vals[ri] = e.val(x);
                    return;
                }
                const comps = try e.arena.alloc(u32, n);
                @memset(comps, e.val(x));
                e.vals[ri] = try e.op1(.composite_construct, i.ty, comps);
            },
            .extract => |x| {
                if (e.isScalarLike(f.inst(x.agg).ty)) {
                    e.vals[ri] = e.val(x.agg);
                    return;
                }
                e.vals[ri] = try e.op1(.composite_extract, i.ty, &.{ e.val(x.agg), x.index });
            },
            .insert => |x| {
                if (e.isScalarLike(i.ty)) {
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
            .select => |x| e.vals[ri] = try e.op1(.select, i.ty, &.{ e.val(x.cond), e.val(x.t), e.val(x.f) }),
            .call => |c| {
                var ops: std.ArrayList(u32) = .empty;
                try ops.append(e.arena, e.func_ids[c.func]);
                for (c.args) |a| try ops.append(e.arena, e.val(a));
                e.vals[ri] = try e.op1(.function_call, i.ty, ops.items);
            },
            .intrinsic => |c| e.vals[ri] = try e.intrinsic(c.name, i.ty, c.args),
            .res_load => |x| {
                const ptr = try e.bufferElement(x.res, x.index);
                if (e.t.component(i.ty) == .bool) {
                    const stored = try e.t.withComponent(i.ty, .uint);
                    const raw = try e.op1(.load, stored, &.{ptr});
                    e.vals[ri] = try e.convert(raw, stored, i.ty);
                } else e.vals[ri] = try e.op1(.load, i.ty, &.{ptr});
            },
            .res_store => |x| {
                const ptr = try e.bufferElement(x.res, x.index);
                var v = e.val(x.value);
                const vt = f.inst(x.value).ty;
                if (e.t.component(vt) == .bool) v = try e.convert(v, vt, try e.t.withComponent(vt, .uint));
                try e.b.emit(.functions, .store, &.{ ptr, v });
            },
            .method => |x| return e.unsupported("method '{s}' is not supported yet", .{x.name}),
            .input => |k| {
                const iface = e.inputs[k];
                const loaded = try e.op1(.load, iface.ty, &.{iface.var_id});
                e.vals[ri] = try e.reshape(loaded, iface.ty, i.ty);
            },
            .output => |o| {
                const iface = e.outputs[o.element];
                const v = try e.reshape(e.val(o.value), f.inst(o.value).ty, iface.ty);
                try e.b.emit(.functions, .store, &.{ iface.var_id, v });
            },
            .phi => return e.unsupported("phi", .{}),
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
        const g = e.globalOf(res) orelse return e.unsupported("resources not tied to a global are not supported yet", .{});
        const elem_ptr = e.buffer_elem_ptr[g];
        if (elem_ptr == 0) return e.unsupported("indexing this resource is not supported yet", .{});
        const id = e.b.newId();
        try e.b.emit(.functions, .access_chain, &.{ elem_ptr, id, e.global_vars[g], try e.constInt(0), e.val(index) });
        return id;
    }

    /// The global a resource value comes from (`load (global g)`).
    fn globalOf(e: *Emitter, r: Ref) ?u32 {
        const i = e.f.inst(r);
        return switch (i.op) {
            .global => |g| g,
            .load => |p| e.globalOf(p),
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

    fn intrinsic(e: *Emitter, name: []const u8, ty: TypeId, args: []const Ref) Error!Id {
        const ids = try e.arena.alloc(u32, args.len);
        for (args, ids) |a, *id| id.* = e.val(a);
        const arg_c = if (args.len > 0) e.compOf(e.f.inst(args[0]).ty) else e.compOf(ty);
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
            const at = e.f.inst(args[0]).ty;
            const s = try e.op1(.ext_inst, at, &.{ e.glslSet(), if (fl) 6 else 7, ids[0] });
            return e.convert(s, at, ty);
        }
        if ((eqn(u8, name, "countbits") or eqn(u8, name, "reversebits") or eqn(u8, name, "ddx") or eqn(u8, name, "ddy") or eqn(u8, name, "fwidth") or eqn(u8, name, "ddx_coarse") or eqn(u8, name, "ddy_coarse")) and arg_c.size() != 4) {
            return e.unsupported("intrinsic '{s}' on {d}-bit types is not supported yet", .{ name, arg_c.size() * 8 });
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
        if (std.mem.eql(u8, name, "saturate")) {
            const zero = try e.splatConst(ty, .{ .float = 0 });
            const one = try e.splatConst(ty, .{ .float = 1 });
            return e.op1(.ext_inst, ty, &.{ e.glslSet(), 43, ids[0], zero, one });
        }
        if (std.mem.eql(u8, name, "dot") and fl) return e.op1(.dot, ty, ids);
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
        if (std.mem.eql(u8, name, "GroupMemoryBarrierWithGroupSync")) {
            // Workgroup execution and memory scope, AcquireRelease |
            // WorkgroupMemory semantics.
            try e.b.emit(.functions, .control_barrier, &.{ try e.constUint(2), try e.constUint(2), try e.constUint(0x108) });
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
