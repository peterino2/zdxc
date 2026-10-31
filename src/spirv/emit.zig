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
    buffer_elem_ptr: []Id = &.{},
    /// Entry inputs / outputs: interface variable and its value type.
    inputs: []Interface = &.{},
    outputs: []Interface = &.{},
    interface_ids: std.ArrayList(Id) = .empty,

    // Per function.
    vals: []Id = &.{},
    f: *const ir.Function = undefined,

    const Interface = struct { var_id: Id, ty: TypeId };
    const LayoutKey = struct { TypeId, layout.Rules, bool };
    const PtrLayout = struct { rules: layout.Rules, row_major: bool };

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
            .@"struct" => |st| {
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
                try e.b.emitWithString(.debug_names, .name, &.{id}, st.name, &.{});
            },
            else => return e.unsupported("buffer members of type '{s}' are not supported yet", .{try e.t.format(e.arena, ty)}),
        }
        try e.layout_types.put(e.arena, key, id);
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
                            const elem_ty = if (r.kind == .byte_address_buffer or r.kind == .rw_byte_address_buffer) try e.t.scalar(.uint) else r.elem;
                            if (e.isTrueMatrix(elem_ty)) return e.unsupported("buffers of matrices are not supported yet", .{});
                            const elem = try e.layoutTypeId(elem_ty, .std430, false);
                            const stride = layout.arrayStride(e.t, elem_ty, false, .std430) catch return e.unsupported("buffer element type '{s}'", .{try e.t.format(e.arena, elem_ty)});
                            const rt = e.b.newId();
                            try e.b.emit(.types_globals, .type_runtime_array, &.{ rt, elem });
                            try e.b.emit(.annotations, .decorate, &.{ rt, 6, stride }); // ArrayStride
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
                    const st = try e.layoutTypeId(g.ty, .vk_relaxed, false);
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
        e.ptr_layouts = try e.arena.alloc(?PtrLayout, f.insts.items.len);
        @memset(e.ptr_layouts, null);
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
            .global => |g| {
                e.vals[ri] = e.global_vars[g];
                e.ptr_layouts[ri] = switch (e.m.globals.items[g].space) {
                    .cbuffer => .{ .rules = .vk_relaxed, .row_major = false },
                    .resource => .{ .rules = .std430, .row_major = false },
                    else => null,
                };
            },
            .load => |p| {
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
                if (e.ptr_layouts[s.ptr.index()]) |pl| {
                    const v = try e.toLayout(e.val(s.value), f.inst(s.value).ty, pl.rules, pl.row_major);
                    try e.b.emit(.functions, .store, &.{ e.val(s.ptr), v });
                    return;
                }
                try e.b.emit(.functions, .store, &.{ e.val(s.ptr), e.val(s.value) });
            },
            .access => |a| {
                const sc: StorageClass = switch (i.ptr) {
                    .function => .function,
                    .private => .private,
                    .groupshared => .workgroup,
                    .cbuffer, .resource => .uniform,
                    else => return e.unsupported("access into this storage is not supported yet", .{}),
                };
                var pl = e.ptr_layouts[a.base.index()];
                var ops: std.ArrayList(u32) = .empty;
                try ops.appendSlice(e.arena, &.{ 0, 0, e.val(a.base) });
                var cur = f.inst(a.base).ty;
                var indices = a.indices;
                if (e.t.get(cur) == .resource) {
                    // buffer[i]...: member 0 (the runtime array), element i.
                    const rk = e.t.get(cur).resource;
                    if (e.buffer_elem_ptr[e.globalOf(a.base) orelse return e.unsupported("resources not tied to a global", .{})] == 0) return e.unsupported("indexing this resource is not supported yet", .{});
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
                try ops.append(e.arena, e.func_ids[c.func]);
                for (c.args) |a| try ops.append(e.arena, e.val(a));
                e.vals[ri] = try e.op1(.function_call, i.ty, ops.items);
            },
            .intrinsic => |c| e.vals[ri] = try e.intrinsic(c.name, i.ty, c.args),
            .res_load => |x| {
                const ptr = try e.bufferElement(x.res, x.index);
                const raw = try e.opRaw(.load, try e.layoutTypeId(i.ty, .std430, false), &.{ptr});
                e.vals[ri] = try e.fromLayout(raw, i.ty, .std430, false);
            },
            .res_store => |x| {
                const ptr = try e.bufferElement(x.res, x.index);
                const v = try e.toLayout(e.val(x.value), f.inst(x.value).ty, .std430, false);
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
        const tys = try e.arena.alloc(TypeId, args.len);
        for (args, ids, tys) |a, *id, *t| {
            id.* = e.val(a);
            t.* = e.f.inst(a).ty;
        }
        // Component-wise intrinsics on matrices apply row by row (GLSL
        // instructions take scalars and vectors).
        const whole = [_][]const u8{ "mul", "transpose", "determinant", "any", "all", "length", "dot" };
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
        if (std.mem.eql(u8, name, "dot") and fl) return e.op1(.dot, ty, ids);
        const deriv = for ([_][]const u8{ "ddx", "ddy", "ddx_coarse", "ddy_coarse", "ddx_fine", "ddy_fine", "fwidth" }) |d| {
            if (eqn(u8, name, d)) break true;
        } else false;
        if (deriv and e.m.entry.?.stage != .pixel) return e.unsupported("derivatives outside pixel shaders are not supported yet", .{});
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
