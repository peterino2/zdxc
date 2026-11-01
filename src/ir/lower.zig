//! Lowers a checked translation unit (AST plus Sema's types and
//! resolutions) to memory-form IR: the entry function, everything it
//! reaches, the globals it uses, and a parameterless wrapper that reads the
//! entry's inputs and writes its outputs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../front/ast.zig");
const ir = @import("ir.zig");
const layout = @import("layout.zig");
const semamod = @import("../sema/sema.zig");
const types = @import("../sema/types.zig");
const Bitfield = types.Bitfield;
const Interp = types.Interp;
const Field = types.Field;
const table = @import("intrinsics_table");

const Sema = semamod.Sema;
const Variable = semamod.Variable;
const TypeId = types.TypeId;
const TypeTable = types.TypeTable;
const Scalar = types.Scalar;
const Ref = ir.Ref;
const BlockId = ir.BlockId;

pub const Options = struct {
    entry: []const u8,
    stage: ir.Stage,
};

pub const Error = Allocator.Error || error{Unsupported};

/// Lowers the entry point and what it reaches. Constructs the lowering does
/// not handle yet fail with `error.Unsupported` after reporting why.
pub fn lowerUnit(arena: Allocator, s: *Sema, opts: Options) Error!ir.Module {
    var l: Lowerer = .{ .arena = arena, .s = s, .m = .{ .arena = arena, .types = &s.types } };
    if (opts.stage == .library) {
        // Every function with a shader attribute, in declaration order.
        for (s.all_functions.items) |f| {
            if (f.owner != null or !f.defined) continue;
            const stage = for (f.decl.attrs) |a| {
                if (!std.ascii.eqlIgnoreCase(a.name, "shader") or a.args.len != 1 or a.args[0].kind != .string_lit) continue;
                const lit = a.args[0].kind.string_lit;
                break stageNamed(lit[1 .. lit.len - 1]) orelse {
                    l.unsupported(a.loc, "{s} shaders are not supported yet", .{lit});
                    return error.Unsupported;
                };
            } else continue;
            try l.lowerEntry(f, f.name, stage);
        }
        try l.subobjects();
        for (s.all_functions.items) |f| {
            if (f.owner != null or !f.defined or !f.decl.quals.@"export" or f.decl.quals.static) continue;
            l.cur_entry = 0;
            const fi = try l.functionIndex(f);
            try l.drain();
            try l.m.exports.append(l.arena, fi);
        }
        try l.bindingDecls();
        return l.m;
    }
    const entry_fn = for (s.all_functions.items) |f| {
        if (f.owner == null and f.defined and std.mem.eql(u8, f.name, opts.entry)) break f;
    } else {
        l.unsupported(.none, "missing entry point definition", .{});
        return error.Unsupported;
    };
    try l.lowerEntry(entry_fn, opts.entry, opts.stage);
    try l.bindingDecls();
    return l.m;
}

/// The stage a `[shader("...")]` attribute names.
fn stageNamed(name: []const u8) ?ir.Stage {
    const names = [_]struct { []const u8, ir.Stage }{
        .{ "vertex", .vertex },               .{ "pixel", .pixel },           .{ "geometry", .geometry },
        .{ "hull", .hull },                   .{ "domain", .domain },         .{ "compute", .compute },
        .{ "mesh", .mesh },                   .{ "amplification", .amplification }, .{ "raygeneration", .raygeneration },
        .{ "intersection", .intersection },   .{ "anyhit", .anyhit },         .{ "closesthit", .closesthit },
        .{ "miss", .miss },                   .{ "callable", .callable },
    };
    for (names) |t| if (std.ascii.eqlIgnoreCase(name, t[0])) return t[1];
    return null;
}

const Stream = struct { param: u32, ty: TypeId, first: u32, kind: @FieldType(types.Type, "stream") };

const Lowerer = struct {
    arena: Allocator,
    s: *Sema,
    m: ir.Module,
    funcs: std.AutoHashMapUnmanaged(*const semamod.Function, u32) = .empty,
    pending: std.ArrayList(*const semamod.Function) = .empty,
    globals: std.AutoHashMapUnmanaged(*const Variable, u32) = .empty,
    /// Resources inside global structs (`g.tex`): a global each, by
    /// variable and member path.
    leaf_globals: std.StringHashMapUnmanaged(u32) = .empty,
    /// cbuffer globals by declaration (0: `$Globals`), and where each
    /// member variable lives.
    cbuffers: std.AutoHashMapUnmanaged(usize, u32) = .empty,
    cbuffer_members: std.AutoHashMapUnmanaged(*const Variable, struct { global: u32, field: u32 }) = .empty,

    // Per function.
    b: ir.Builder = undefined,
    vars: std.AutoHashMapUnmanaged(*const Variable, Ref) = .empty,
    /// Variables bound to values instead of storage: inline SPIR-V
    /// pointers (`vk::WorkgroupSpirvPointer`), which Vulkan does not let
    /// variables hold.
    value_vars: std.AutoHashMapUnmanaged(*const Variable, Ref) = .empty,
    loops: std.ArrayList(struct { brk: BlockId, cont: BlockId }) = .empty,
    /// Geometry shaders: output elements registered before lowering (by
    /// stream parameter), and each stream's element layout.
    early_outputs: std.ArrayList(ir.SigElement) = .empty,
    streams: std.ArrayList(Stream) = .empty,
    entry_fn: ?*const semamod.Function = null,
    /// Entry inputs / outputs go to the patch constants (domain shader
    /// inputs other than control points; hull patch constant outputs).
    patch_io: bool = false,
    /// Per-vertex reads come from the hull shader's output control points.
    vertex_from_outputs: bool = false,
    /// The payload type an amplification shader dispatches.
    mesh_payload: ?TypeId = null,
    /// The current method's object pointer.
    this_ptr: Ref = .none,
    ret_ty: TypeId = TypeTable.void_type,
    /// The entry being lowered (index into the module's entries).
    cur_entry: u32 = 0,
    /// Initializer functions of static globals (made once).
    inits: std.AutoHashMapUnmanaged(*const Variable, u32) = .empty,

    /// Lowers one entry point and what it reaches (functions shared with
    /// earlier entries are already lowered).
    fn lowerEntry(l: *Lowerer, f: *const semamod.Function, name: []const u8, stage: ir.Stage) Error!void {
        l.cur_entry = @intCast(l.m.entries.items.len);
        l.early_outputs = .empty;
        l.streams = .empty;
        l.entry_fn = null;
        l.mesh_payload = null;
        if (stage == .geometry) try l.registerStreams(f);
        const main = try l.functionIndex(f);
        try l.drain();
        try l.buildEntry(f, main, .{ .entry = name, .stage = stage });
    }

    /// The inline SPIR-V attributes among `attrs` (SPIR-V only).
    fn spirvExt(l: *Lowerer, attrs: []const ast.Attribute) Error!ir.SpirvExt {
        if (!l.s.opts.spirv) return .{};
        var x: ir.SpirvExt = .{};
        var decs: std.ArrayList(ir.ExtDecoration) = .empty;
        var caps: std.ArrayList(u32) = .empty;
        var exts: std.ArrayList([]const u8) = .empty;
        for (attrs) |a| {
            const eq = std.mem.eql;
            const int = struct {
                fn f(ll: *Lowerer, e: *const ast.Expr) ?u32 {
                    const v = ll.s.evalInt(e) orelse return null;
                    return @truncate(@as(u64, @bitCast(v)));
                }
            }.f;
            if (eq(u8, a.name, "vk::ext_capability")) {
                for (a.args) |arg| if (int(l, arg)) |c| try caps.append(l.arena, c);
            } else if (eq(u8, a.name, "vk::ext_extension")) {
                for (a.args) |arg| if (arg.kind == .string_lit) try exts.append(l.arena, try stringContents(l.arena, arg.kind.string_lit));
            } else if (eq(u8, a.name, "vk::ext_builtin_input") or eq(u8, a.name, "vk::ext_builtin_output")) {
                if (a.args.len == 1) x.builtin = int(l, a.args[0]);
                x.builtin_output = eq(u8, a.name, "vk::ext_builtin_output");
            } else if (eq(u8, a.name, "vk::ext_storage_class")) {
                if (a.args.len == 1) x.storage_class = int(l, a.args[0]);
            } else if ((eq(u8, a.name, "vk::ext_decorate") or eq(u8, a.name, "vk::ext_decorate_id") or eq(u8, a.name, "vk::ext_decorate_string")) and a.args.len >= 1) {
                var d: ir.ExtDecoration = .{ .decoration = int(l, a.args[0]) orelse continue, .kind = if (eq(u8, a.name, "vk::ext_decorate")) .literal else if (eq(u8, a.name, "vk::ext_decorate_id")) .id else .string };
                var ints: std.ArrayList(u32) = .empty;
                var strs: std.ArrayList([]const u8) = .empty;
                var ok = true;
                for (a.args[1..]) |arg| {
                    if (arg.kind == .string_lit) {
                        try strs.append(l.arena, try stringContents(l.arena, arg.kind.string_lit));
                    } else if (int(l, arg)) |v| {
                        try ints.append(l.arena, v);
                    } else ok = false;
                }
                if (!ok) continue;
                d.ints = ints.items;
                d.strings = strs.items;
                try decs.append(l.arena, d);
            }
        }
        x.decorations = decs.items;
        x.capabilities = caps.items;
        x.extensions = exts.items;
        return x;
    }

    /// `[[vk::constant_id(n)]] const T x = v;` (SPIR-V only).
    fn isSpecConstant(l: *Lowerer, v: *const Variable) bool {
        if (!l.s.opts.spirv or v.storage != .global_uniform) return false;
        const d = v.decl orelse return false;
        return hasAttr(d.attrs, "vk::constant_id");
    }

    fn specConstant(l: *Lowerer, v: *const Variable) Error!Ref {
        const k: u32 = for (l.m.spec_constants.items, 0..) |sc, i| {
            if (std.mem.eql(u8, sc.name, v.name)) break @intCast(i);
        } else blk: {
            const init_e = v.init orelse {
                l.unsupported(v.loc, "specialization constant '{s}' without an initializer", .{v.name});
                return error.Unsupported;
            };
            const c = l.s.evalConst(init_e) orelse {
                l.unsupported(v.loc, "specialization constant '{s}' with this initializer is not supported yet", .{v.name});
                return error.Unsupported;
            };
            const value: ir.Constant = switch (c) {
                .int => |x| .{ .int = x },
                .float => |x| .{ .float = x },
                .bool => |x| .{ .int = @intFromBool(x) },
            };
            try l.m.spec_constants.append(l.arena, .{ .name = v.name, .ty = v.type, .id = l.s.vkAttrInt(v.decl.?.attrs, "vk::constant_id") orelse 0, .value = value });
            break :blk @intCast(l.m.spec_constants.items.len - 1);
        };
        return l.b.add(.{ .op = .{ .spec_constant = k }, .ty = v.type });
    }

    /// `[[vk::push_constant]] struct {...} pc;` (SPIR-V only; dxc's DXIL
    /// keeps it in `$Globals`).
    fn isPushConstantStruct(l: *Lowerer, v: *const Variable) bool {
        if (!l.s.opts.spirv or v.storage != .global_uniform) return false;
        const d = v.decl orelse return false;
        return hasAttr(d.attrs, "vk::push_constant") and l.s.types.get(v.type) == .@"struct";
    }

    /// The module's descriptor declarations in declaration order, each with
    /// its IR global when used.
    fn bindingDecls(l: *Lowerer) Error!void {
        var globals_done = false;
        for (l.s.global_order.items) |gd| switch (gd) {
            .variable => |v| {
                // A struct of resources: a binding per resource (used or
                // not), the first taking the struct's register.
                if (v.storage == .global_uniform and holdsResources(&l.s.types, v.type)) {
                    l.m.resource_structs = true;
                    if (l.s.opts.spirv) {
                        if (structHoldsBuffer(&l.s.types, v.type)) {
                            l.unsupported(v.loc, "global structures containing buffers are not supported", .{});
                            return error.Unsupported;
                        }
                        if (layout.flatCount(&l.s.types, v.type) catch 0 > 0) {
                            l.unsupported(v.loc, "global structures containing both resources and non-resources are not supported", .{});
                            return error.Unsupported;
                        }
                    }
                    var leaves: std.ArrayList(LeafPath) = .empty;
                    try l.resourceLeaves(v.type, &.{}, &leaves);
                    // One range for the whole struct (as dxc): each
                    // resource at its offset.
                    var bd: ir.BindingDecl = if (v.decl) |d| try l.bindingDecl(d.semantics, d.attrs, null) else .{ .global = null };
                    bd.global = null;
                    var members: std.ArrayList(@typeInfo(@FieldType(ir.BindingDecl, "members")).pointer.child) = .empty;
                    var offset: u32 = 0;
                    for (leaves.items) |leaf| {
                        try members.append(l.arena, .{ .global = l.leaf_globals.get(try l.leafName(v, leaf.path)), .offset = offset });
                        var n: u32 = 1;
                        var at = leaf.ty;
                        while (l.s.types.get(at) == .array) : (at = l.s.types.get(at).array.elem) n *= @max(1, l.s.types.get(at).array.len);
                        offset += n;
                    }
                    bd.count = @max(1, offset);
                    bd.members = members.items;
                    try l.m.binding_decls.append(l.arena, bd);
                    if (layout.flatCount(&l.s.types, v.type) catch 0 == 0) continue;
                }
                if (!isObject(&l.s.types, v.type)) {
                    if (v.storage != .global_uniform or globals_done or l.isPushConstantStruct(v) or l.isSpecConstant(v)) continue;
                    globals_done = true;
                    try l.m.binding_decls.append(l.arena, .{ .global = l.cbuffers.get(0), .globals_buffer = true });
                    continue;
                }
                var et = v.type;
                while (l.s.types.get(et) == .array) et = l.s.types.get(et).array.elem;
                const r = switch (l.s.types.get(et)) {
                    .resource => |r| r,
                    else => null,
                };
                if (r) |res| if (res.kind == .other and !std.mem.startsWith(u8, res.name, "SubpassInput")) continue;
                const d = v.decl orelse continue;
                if (isShaderRecord(d.attrs) or hasAttr(d.attrs, "vk::push_constant")) continue;
                var bd = try l.bindingDecl(d.semantics, d.attrs, l.globals.get(v));
                var at = v.type;
                while (l.s.types.get(at) == .array) : (at = l.s.types.get(at).array.elem) bd.count *= @max(1, l.s.types.get(at).array.len);
                if (r) |res| bd.acs = res.kind == .append_structured_buffer or res.kind == .consume_structured_buffer;
                try l.m.binding_decls.append(l.arena, bd);
            },
            .cbuffer => |d| {
                const cb = d.kind.cbuffer;
                if (isShaderRecord(cb.attrs) or hasAttr(cb.attrs, "vk::push_constant")) continue;
                try l.m.binding_decls.append(l.arena, try l.bindingDecl(cb.semantics, cb.attrs, l.cbuffers.get(@intFromPtr(d))));
            },
        };
    }

    fn bindingDecl(l: *Lowerer, sems: []const ast.Semantic, attrs: []const ast.Attribute, global: ?u32) Error!ir.BindingDecl {
        var bd: ir.BindingDecl = .{ .global = global };
        for (sems) |sem| if (sem.kind == .register) {
            bd.reg = parseBinding(sem.values);
            bd.space_only = !bd.reg.explicit;
        };
        for (attrs) |a| {
            if (std.mem.eql(u8, a.name, "vk::binding") and a.args.len >= 1) {
                bd.vk_binding = @intCast(@max(0, l.s.evalInt(a.args[0]) orelse 0));
                if (a.args.len >= 2) bd.vk_set = @intCast(@max(0, l.s.evalInt(a.args[1]) orelse 0));
            }
            if (std.mem.eql(u8, a.name, "vk::counter_binding") and a.args.len >= 1) bd.vk_counter = @intCast(@max(0, l.s.evalInt(a.args[0]) orelse 0));
            if (std.mem.eql(u8, a.name, "vk::combinedImageSampler")) bd.combined = true;
        }
        return bd;
    }

    /// The library's subobject declarations (`TriangleHitGroup hg = {...};`).
    fn subobjects(l: *Lowerer) Error!void {
        const Kind = ir.Subobject.Kind;
        const kinds = [_]struct { []const u8, Kind }{
            .{ "StateObjectConfig", .state_object_config },                       .{ "GlobalRootSignature", .global_root_signature },
            .{ "LocalRootSignature", .local_root_signature },                     .{ "SubobjectToExportsAssociation", .subobject_to_exports_association },
            .{ "RaytracingShaderConfig", .raytracing_shader_config },             .{ "RaytracingPipelineConfig", .raytracing_pipeline_config },
            .{ "TriangleHitGroup", .hit_group },                                  .{ "ProceduralPrimitiveHitGroup", .hit_group },
            .{ "RaytracingPipelineConfig1", .raytracing_pipeline_config1 },
        };
        // (Builtin objects are static globals.)
        for (l.s.static_globals.items) |v| {
            const r = switch (l.s.types.get(v.type)) {
                .resource => |r| r,
                else => continue,
            };
            if (r.kind != .other) continue;
            const kind = for (kinds) |k| {
                if (std.mem.eql(u8, r.name, k[0])) break k[1];
            } else continue;
            const init_e = v.init orelse continue;
            const items: []const *ast.Expr = if (init_e.kind == .init_list) init_e.kind.init_list else &.{init_e};
            var so: ir.Subobject = .{ .name = v.name, .kind = kind };
            var strs: std.ArrayList([]const u8) = .empty;
            var ints: std.ArrayList(u32) = .empty;
            for (items) |it| switch (it.kind) {
                .string_lit => |lit| try strs.append(l.arena, try stringContents(l.arena, lit)),
                else => try ints.append(l.arena, @truncate(@as(u64, @bitCast(l.s.evalInt(it) orelse 0)))),
            };
            for (ints.items[0..@min(2, ints.items.len)], 0..) |x, k| so.ints[k] = x;
            switch (kind) {
                .hit_group => {
                    // Triangle groups: any hit, closest hit; procedural ones
                    // add the intersection shader.
                    so.ints[0] = @intFromBool(std.mem.eql(u8, r.name, "ProceduralPrimitiveHitGroup"));
                    for (strs.items[0..@min(3, strs.items.len)], 0..) |x, k| so.strings[k] = x;
                },
                .subobject_to_exports_association => {
                    if (strs.items.len > 0) so.strings[0] = strs.items[0];
                    var exports: std.ArrayList([]const u8) = .empty;
                    if (strs.items.len > 1) {
                        var it = std.mem.splitScalar(u8, strs.items[1], ';');
                        while (it.next()) |x| {
                            const t = std.mem.trim(u8, x, " \t");
                            if (t.len > 0) try exports.append(l.arena, t);
                        }
                    }
                    so.exports = exports.items;
                },
                .global_root_signature, .local_root_signature => if (strs.items.len > 0) {
                    so.strings[0] = strs.items[0];
                },
                else => {},
            }
            try l.m.subobjects.append(l.arena, so);
        }
    }

    fn unsupported(l: *Lowerer, loc: ast.Loc, comptime fmt: []const u8, args: anytype) void {
        _ = l.s.diags.report(.{ .severity = .@"error", .loc = loc }, "code generation: " ++ fmt, args);
    }

    fn types(l: *Lowerer) *TypeTable {
        return &l.s.types;
    }

    // ------------------------------------------------------------------
    // Functions

    /// The IR function for a Sema function, queued for lowering on first use.
    fn functionIndex(l: *Lowerer, f: *const semamod.Function) Error!u32 {
        if (l.funcs.get(f)) |i| return i;
        // Stream-output objects exist only at compile time: no parameter.
        var params: std.ArrayList(ir.Param) = .empty;
        // Methods take the object first (`this`, by reference).
        if (isMethod(f)) try params.append(l.arena, .{ .name = "this", .ty = try l.s.types.intern(.{ .@"struct" = f.owner.? }), .by_ref = true });
        for (f.params, 0..) |p, k| {
            if (l.s.types.get(p.type) == .stream) continue;
            const sem = if (k < f.decl.params.len) semanticOf(f.decl.params[k].semantics) else null;
            try params.append(l.arena, .{ .name = p.name, .ty = l.irType(p.type), .by_ref = p.dir != .in or p.groupshared, .groupshared = p.groupshared, .dir = switch (p.dir) {
                .in => .in,
                .out => .out,
                .inout => .inout,
            }, .semantic = sem, .sema_ty = p.type });
        }
        const order: u32 = @intCast(std.mem.indexOfScalar(*semamod.Function, l.s.all_functions.items, @constCast(f)) orelse std.math.maxInt(u32));
        const i = try l.m.addFunction(.{ .name = f.name, .params = params.items, .ret = f.ret, .entry = l.cur_entry, .ret_semantic = semanticOf(f.decl.ret_semantics), .decl_order = order });
        try l.funcs.put(l.arena, f, i);
        try l.pending.append(l.arena, f);
        return i;
    }

    /// The IR type of a value of Sema type `ty`: InputPatch / OutputPatch
    /// are arrays of control points.
    fn irType(l: *Lowerer, ty: TypeId) TypeId {
        return switch (l.s.types.get(ty)) {
            .patch => |p| l.s.types.array(p.elem, p.count) catch ty,
            else => ty,
        };
    }

    fn drain(l: *Lowerer) Error!void {
        while (l.pending.pop()) |f| try l.lowerFunction(f);
    }

    fn lowerFunction(l: *Lowerer, f: *const semamod.Function) Error!void {
        const func = l.m.functions.items[l.funcs.get(f).?];
        const body = f.decl.body orelse {
            l.unsupported(f.loc, "function '{s}' has no definition", .{f.name});
            return error.Unsupported;
        };
        l.b = .{ .m = &l.m, .f = func };
        l.vars = .empty;
        l.loops = .empty;
        l.ret_ty = f.ret;
        l.b.setBlock(try l.b.newBlock());
        // Parameters: by-value ones get local storage, out / inout ones
        // are the caller's pointers.
        var ir_index: u32 = 0;
        l.this_ptr = .none;
        if (isMethod(f)) {
            l.this_ptr = try l.b.add(.{ .op = .{ .param = 0 }, .ty = try l.s.types.intern(.{ .@"struct" = f.owner.? }), .ptr = .function });
            ir_index = 1;
        }
        for (f.params, 0..) |p, i| {
            if (l.s.types.get(p.type) == .stream) continue;
            const pty = l.irType(p.type);
            const mq = if (i < f.decl.params.len) f.decl.params[i].quals else ast.Qualifiers{};
            const space: ir.Space = if (mq.vertices or mq.indices or mq.primitives) .mesh else if (p.groupshared) .groupshared else if (p.dir != .in) .function else .none;
            const pv = try l.b.add(.{ .op = .{ .param = ir_index }, .ty = pty, .ptr = space });
            ir_index += 1;
            if (p.dir == .in and isSpirvPointer(&l.s.types, p.type)) {
                if (i < f.param_vars.len) if (f.param_vars[i]) |v| try l.value_vars.put(l.arena, v, pv);
                continue;
            }
            const storage = if (p.dir != .in or p.groupshared) pv else blk: {
                const local = try l.b.add(.{ .op = .local_var, .ty = pty, .ptr = .function });
                try l.b.store(local, pv);
                break :blk local;
            };
            if (i < f.param_vars.len) if (f.param_vars[i]) |v| try l.vars.put(l.arena, v, storage);
        }
        try l.stmts(body.kind.compound);
        if (l.b.open()) {
            if (f.ret != TypeTable.void_type) {
                l.b.terminate(.@"unreachable");
            } else l.b.terminate(.{ .ret = .none });
        }
    }

    // ------------------------------------------------------------------
    // Globals

    fn globalIndex(l: *Lowerer, v: *const Variable) Error!u32 {
        if (l.globals.get(v)) |i| return i;
        const space: ir.Space = switch (v.storage) {
            .groupshared => .groupshared,
            .global_static, .constant, .local_static => if (isObject(&l.s.types, v.type)) .resource else .private,
            .global_uniform, .cbuffer => unreachable, // see cbufferMember
            else => unreachable,
        };
        var binding: ir.Binding = .{};
        if (v.decl) |d| for (d.semantics) |sem| {
            if (sem.kind != .register) continue;
            binding = parseBinding(sem.values);
        };
        const shader_record = if (v.decl) |d| isShaderRecord(d.attrs) else false;
        const push_constant = if (v.decl) |d| hasAttr(d.attrs, "vk::push_constant") else false;
        try l.m.globals.append(l.arena, .{ .name = v.name, .ty = v.type, .space = space, .binding = binding, .shader_record = shader_record, .push_constant = push_constant, .input_attachment = if (v.decl) |d| l.s.vkAttrInt(d.attrs, "vk::input_attachment_index") else null, .image_format = if (v.decl) |d| imageFormatNamed(semamod.Sema.vkAttrString(d.attrs, "vk::image_format")) else null, .globally_coherent = if (v.decl) |d| d.quals.globallycoherent else false, .ext = if (v.decl) |d| try l.spirvExt(d.attrs) else .{} });
        const i: u32 = @intCast(l.m.globals.items.len - 1);
        try l.globals.put(l.arena, v, i);
        return i;
    }

    /// The cbuffer global holding `v` (created with all its members on
    /// first use, since their layout depends on every member).
    fn cbufferMember(l: *Lowerer, v: *const Variable) Error!struct { global: u32, field: u32 } {
        if (l.cbuffer_members.get(v)) |m| return .{ .global = m.global, .field = m.field };
        const key: usize = if (v.block) |b| @intFromPtr(b) else 0;
        if (l.cbuffers.contains(key)) unreachable; // members are registered with their block
        var members: std.ArrayList(*const Variable) = .empty;
        var name: []const u8 = "$Globals";
        var binding: ir.Binding = .{};
        var is_tbuffer = false;
        var shader_record = false;
        var push_constant = false;
        if (v.block) |b| {
            const cb = b.kind.cbuffer;
            is_tbuffer = cb.tbuffer;
            shader_record = isShaderRecord(cb.attrs);
            push_constant = hasAttr(cb.attrs, "vk::push_constant");
            name = cb.name;
            for (cb.members) |m| if (m.kind == .@"var") {
                if (l.s.decl_vars.get(&m.kind.@"var")) |mv| try members.append(l.arena, mv);
            };
            for (cb.semantics) |sem| if (sem.kind == .register) {
                binding = parseBinding(sem.values);
            };
        } else {
            for (l.s.uniform_globals.items) |g| {
                if (isObject(&l.s.types, g.type) or l.isPushConstantStruct(g) or l.isSpecConstant(g)) continue;
                try members.append(l.arena, g);
            }
        }
        const info = try l.arena.create(@import("../sema/types.zig").StructInfo);
        info.* = .{ .name = name, .complete = true };
        for (members.items) |mv| try info.fields.append(l.arena, .{ .name = mv.name, .type = mv.type, .row_major = mv.row_major, .pack_offset = packOffset(mv), .vk_offset = if (mv.decl != null and l.s.opts.spirv) l.s.vkAttrInt(mv.decl.?.attrs, "vk::offset") else null });
        const ty = try l.s.types.intern(.{ .@"struct" = info });
        try l.m.globals.append(l.arena, .{ .name = name, .ty = ty, .space = .cbuffer, .binding = binding, .tbuffer = is_tbuffer, .shader_record = shader_record, .push_constant = push_constant });
        const gi: u32 = @intCast(l.m.globals.items.len - 1);
        try l.cbuffers.put(l.arena, key, gi);
        for (members.items, 0..) |mv, fi| try l.cbuffer_members.put(l.arena, mv, .{ .global = gi, .field = @intCast(fi) });
        const m = l.cbuffer_members.get(v) orelse {
            l.unsupported(v.loc, "constant buffer variable '{s}' is not supported yet", .{v.name});
            return error.Unsupported;
        };
        return .{ .global = m.global, .field = m.field };
    }

    // ------------------------------------------------------------------
    // Statements

    fn stmts(l: *Lowerer, list: []const *ast.Stmt) Error!void {
        for (list) |st| try l.stmt(st);
    }

    fn stmt(l: *Lowerer, st: *const ast.Stmt) Error!void {
        switch (st.kind) {
            .compound => |list| try l.stmts(list),
            .empty => {},
            .expr => |e| _ = try l.rvalue(e),
            .decl => |decls| for (decls) |d| try l.localDecl(d),
            .@"return" => |v| {
                if (v != null and v.?.ty == TypeTable.void_type) {
                    _ = try l.rvalue(v.?);
                    l.b.terminate(.{ .ret = .none });
                } else if (v) |e| {
                    const val = try l.converted(e, l.ret_ty);
                    l.b.terminate(.{ .ret = val });
                } else l.b.terminate(.{ .ret = .none });
            },
            .@"if" => |x| {
                if (x.cond_decl) |d| try l.localDecl(d);
                const cond = try l.condition(x.cond);
                const then_b = try l.b.newBlock();
                const merge = try l.b.newBlock();
                const else_b = if (x.@"else" != null) try l.b.newBlock() else merge;
                l.b.f.block(l.b.cur).merge = .{ .selection = merge };
                l.b.terminate(.{ .cond_br = .{ .cond = cond, .then = then_b, .@"else" = else_b } });
                l.b.setBlock(then_b);
                try l.stmt(x.then);
                l.b.terminate(.{ .br = merge });
                if (x.@"else") |e| {
                    l.b.setBlock(else_b);
                    try l.stmt(e);
                    l.b.terminate(.{ .br = merge });
                }
                l.b.setBlock(merge);
            },
            .@"for" => |x| {
                if (x.init) |i| try l.stmt(i);
                try l.loop(x.cond, x.inc, x.body, false, st.attrs);
            },
            .@"while" => |x| {
                if (x.cond_decl != null) {
                    l.unsupported(st.loc, "declarations in while conditions are not supported yet", .{});
                    return error.Unsupported;
                }
                try l.loop(x.cond, null, x.body, false, st.attrs);
            },
            .do_while => |x| try l.loop(x.cond, null, x.body, true, st.attrs),
            .@"break" => {
                const target = l.loops.getLast();
                l.b.terminate(.{ .br = target.brk });
            },
            .@"continue" => {
                const target = l.loops.getLast();
                l.b.terminate(.{ .br = target.cont });
            },
            .discard => l.b.terminate(.discard),
            .@"switch" => |x| try l.switchStmt(x),
            .case, .default => {
                l.unsupported(st.loc, "case labels outside a switch body", .{});
                return error.Unsupported;
            },
        }
    }

    /// `switch`: the header branches to one block per label (labels in a
    /// row get their own, falling through); `break` goes to the merge.
    fn switchStmt(l: *Lowerer, x: @FieldType(ast.Stmt.Kind, "switch")) Error!void {
        if (x.cond_decl) |d| try l.localDecl(d);
        const t = l.types();
        var cond_ty = x.cond.ty;
        if (t.component(cond_ty)) |c| cond_ty = try t.scalar(if (c.isUnsigned()) .uint else .int);
        const cond = try l.converted(x.cond, cond_ty);
        const header = l.b.cur;
        const merge = try l.b.newBlock();
        // Segments: a label and the statements up to the next one.
        const Seg = struct { block: BlockId, value: ?i64, stmts: std.ArrayList(*const ast.Stmt) = .empty };
        var segs: std.ArrayList(Seg) = .empty;
        const body: []const *ast.Stmt = switch (x.body.kind) {
            .compound => |c| c,
            else => &.{x.body},
        };
        for (body) |st| {
            var cur: *const ast.Stmt = st;
            while (true) switch (cur.kind) {
                .case => |c| {
                    const v = l.s.evalInt(c.value) orelse {
                        l.unsupported(cur.loc, "case values that are not constants", .{});
                        return error.Unsupported;
                    };
                    try segs.append(l.arena, .{ .block = try l.b.newBlock(), .value = v });
                    cur = c.stmt;
                },
                .default => |d| {
                    try segs.append(l.arena, .{ .block = try l.b.newBlock(), .value = null });
                    cur = d;
                },
                else => break,
            };
            // Statements before the first label never run.
            if (segs.items.len > 0) try segs.items[segs.items.len - 1].stmts.append(l.arena, cur);
        }
        var default: BlockId = merge;
        var cases: std.ArrayList(@typeInfo(@FieldType(@FieldType(ir.Terminator, "switch"), "cases")).pointer.child) = .empty;
        for (segs.items) |sg| {
            if (sg.value) |v| try cases.append(l.arena, .{ .value = v, .block = sg.block }) else default = sg.block;
        }
        l.b.f.block(header).merge = .{ .selection = merge };
        l.b.terminate(.{ .@"switch" = .{ .value = cond, .default = default, .cases = cases.items } });
        const cont: BlockId = if (l.loops.items.len > 0) l.loops.getLast().cont else .none;
        try l.loops.append(l.arena, .{ .brk = merge, .cont = cont });
        for (segs.items, 0..) |sg, k| {
            l.b.setBlock(sg.block);
            for (sg.stmts.items) |st| try l.stmt(st);
            // Fall through to the next label, or leave the switch.
            l.b.terminate(.{ .br = if (k + 1 < segs.items.len) segs.items[k + 1].block else merge });
        }
        _ = l.loops.pop();
        l.b.setBlock(merge);
    }

    /// header (loop merge) -> cond -> body -> continue (inc) -> header.
    /// `do` loops test at the end of the continue block.
    fn loop(l: *Lowerer, cond: ?*ast.Expr, inc: ?*ast.Expr, body: *const ast.Stmt, do_while: bool, attrs: []const ast.Attribute) Error!void {
        var hint: ir.Unroll = .auto;
        for (attrs) |a| {
            if (std.ascii.eqlIgnoreCase(a.name, "unroll")) hint = .unroll;
            if (std.ascii.eqlIgnoreCase(a.name, "loop")) hint = .dont;
        }
        const header = try l.b.newBlock();
        const body_b = try l.b.newBlock();
        const cont = try l.b.newBlock();
        const merge = try l.b.newBlock();
        l.b.terminate(.{ .br = header });
        l.b.setBlock(header);
        l.b.f.block(header).merge = .{ .loop = .{ .merge = merge, .@"continue" = cont, .unroll = hint } };
        if (!do_while and cond != null) {
            const check = try l.b.newBlock();
            l.b.terminate(.{ .br = check });
            l.b.setBlock(check);
            const c = try l.condition(cond.?);
            l.b.terminate(.{ .cond_br = .{ .cond = c, .then = body_b, .@"else" = merge } });
        } else l.b.terminate(.{ .br = body_b });

        try l.loops.append(l.arena, .{ .brk = merge, .cont = cont });
        l.b.setBlock(body_b);
        try l.stmt(body);
        l.b.terminate(.{ .br = cont });
        _ = l.loops.pop();

        l.b.setBlock(cont);
        if (inc) |e| _ = try l.rvalue(e);
        if (do_while and cond != null) {
            const c = try l.condition(cond.?);
            l.b.terminate(.{ .cond_br = .{ .cond = c, .then = header, .@"else" = merge } });
        } else l.b.terminate(.{ .br = header });
        l.b.setBlock(merge);
    }

    fn localDecl(l: *Lowerer, d: *const ast.Decl) Error!void {
        switch (d.kind) {
            .@"var" => |*v| {
                const variable = l.s.decl_vars.get(v) orelse return;
                if (variable.storage == .local_static) {
                    // A private global, initialized on entry with the other
                    // statics.
                    const gi = try l.globalIndex(variable);
                    const glob = l.m.globals.items[gi];
                    try l.vars.put(l.arena, variable, try l.b.add(.{ .op = .{ .global = gi }, .ty = glob.ty, .ptr = glob.space }));
                    return;
                }
                // (A resource local is an alias of what is stored into it:
                // reading it before that is reported by the backends.)
                if (isSpirvPointer(&l.s.types, variable.type)) {
                    const init_e = v.init orelse {
                        l.unsupported(d.loc, "uninitialized inline SPIR-V pointer '{s}' is not supported", .{variable.name});
                        return error.Unsupported;
                    };
                    try l.value_vars.put(l.arena, variable, try l.converted(init_e, variable.type));
                    return;
                }
                const local = try l.b.add(.{ .op = .local_var, .ty = variable.type, .ptr = .function });
                try l.vars.put(l.arena, variable, local);
                if (v.init) |init_e| {
                    if (init_e.kind == .init_list) {
                        const val = try l.initList(init_e, variable.type);
                        try l.b.store(local, val);
                    } else try l.b.store(local, try l.converted(init_e, variable.type));
                }
            },
            .typedef, .@"struct", .@"enum", .static_assert, .pragma => {},
            else => {
                l.unsupported(d.loc, "this local declaration is not supported yet", .{});
                return error.Unsupported;
            },
        }
    }

    fn condition(l: *Lowerer, e: *ast.Expr) Error!Ref {
        return l.converted(e, try l.types().scalar(.bool));
    }

    // ------------------------------------------------------------------
    // Expressions

    fn concrete(l: *Lowerer, ty: TypeId) Error!TypeId {
        const c = l.types().component(ty) orelse return ty;
        if (!c.isLiteral()) return ty;
        return l.types().withComponent(ty, c.concrete());
    }

    /// `e` converted to `target` (implicit conversion rules: component
    /// conversion, scalar splat, vector truncation).
    fn converted(l: *Lowerer, e: *ast.Expr, target: TypeId) Error!Ref {
        const v = try l.rvalue(e);
        return l.convert(v, target);
    }

    fn convert(l: *Lowerer, v: Ref, target: TypeId) Error!Ref {
        const t = l.types();
        const inst = l.b.f.inst(v);
        if (inst.ty == target) return v;
        // A descriptor heap element takes the type it is used as.
        if (t.get(inst.ty) == .dynamic_resource and inst.op == .heap_resource) {
            return l.b.add(.{ .op = .{ .heap_resource = inst.op.heap_resource }, .ty = target });
        }
        // ConstantBuffer<S> read as an S: member by member.
        if (t.get(inst.ty) == .resource and t.get(target) == .@"struct") {
            const rs = t.get(inst.ty).resource;
            if ((rs.kind == .constant_buffer or rs.kind == .texture_buffer) and rs.elem == target) {
                const fields = t.get(target).@"struct".fields.items;
                const parts = try l.arena.alloc(Ref, fields.len);
                for (parts, fields, 0..) |*p, fld, k| {
                    const idx = try l.b.constInt(try t.scalar(.uint), @intCast(k));
                    p.* = try l.b.load(try l.b.add(.{ .op = .{ .access = .{ .base = v, .indices = try l.arena.dupe(Ref, &.{idx}) } }, .ty = fld.type, .ptr = .cbuffer }));
                }
                return l.b.add(.{ .op = .{ .construct = parts }, .ty = target });
            }
        }
        // Derived structs convert to a base: its fields are a prefix.
        if (t.get(inst.ty) == .@"struct" and t.get(target) == .@"struct") {
            const tf = t.get(target).@"struct".fields.items;
            const parts = try l.arena.alloc(Ref, tf.len);
            for (parts, tf, 0..) |*p, fld, k| p.* = try l.b.add(.{ .op = .{ .extract = .{ .agg = v, .index = @intCast(k) } }, .ty = fld.type });
            return l.b.add(.{ .op = .{ .construct = parts }, .ty = target });
        }
        const fs = t.shape(inst.ty) orelse return v; // objects: same type
        const ts = t.shape(target) orelse return v;
        const tc = t.component(target).?;
        // Constants convert at compile time.
        if (inst.op == .constant and fs.count() == 1) {
            const scalar_ty = try t.scalar(tc);
            const c = inst.op.constant;
            const k = if (tc.isFloat())
                try l.b.constFloat(scalar_ty, switch (c) {
                    .int => |i| @floatFromInt(i),
                    .float => |f| f,
                })
            else if (tc == .bool)
                try l.b.constInt(scalar_ty, switch (c) {
                    .int => |i| @intFromBool(i != 0),
                    .float => |f| @intFromBool(f != 0),
                })
            else
                try l.b.constInt(scalar_ty, switch (c) {
                    .int => |i| i,
                    .float => |f| saturatingInt(f),
                });
            if (ts.count() == 1 and ts.kind == .scalar) return k;
            return l.b.add(.{ .op = .{ .splat = k }, .ty = target });
        }
        const sc = t.component(inst.ty).?;
        // Scalar sources splat.
        if (fs.count() == 1) {
            const target_scalar = try t.scalar(tc);
            var one = try l.component(v, 0);
            if (l.b.f.inst(one).ty != target_scalar) one = try l.b.add(.{ .op = .{ .convert = one }, .ty = target_scalar });
            if (ts.kind == .scalar) return one;
            if (ts.count() == 1) return l.b.add(.{ .op = .{ .construct = try l.arena.dupe(Ref, &.{one}) }, .ty = target });
            return l.b.add(.{ .op = .{ .splat = one }, .ty = target });
        }
        // Truncation to a scalar keeps the first component.
        if (ts.kind == .scalar) return l.convert(try l.component(v, 0), target);
        // Same shape: component conversion.
        if (fs.kind == ts.kind and fs.rows == ts.rows and fs.cols == ts.cols) {
            if (fs.kind == .matrix) {
                // Row by row (SPIR-V converts vectors, not matrices).
                const rows = try l.arena.alloc(Ref, fs.rows);
                const src_row = try t.vector(sc, fs.cols);
                const dst_row = try t.vector(tc, fs.cols);
                for (rows, 0..) |*r, i| {
                    const row = try l.b.add(.{ .op = .{ .extract = .{ .agg = v, .index = @intCast(i) } }, .ty = src_row });
                    r.* = try l.b.add(.{ .op = .{ .convert = row }, .ty = dst_row });
                }
                return l.flatConstruct(target, rows, fs.cols);
            }
            return l.b.add(.{ .op = .{ .convert = v }, .ty = target });
        }
        // Vector truncation keeps a shuffle.
        if (fs.kind == .vector and ts.kind == .vector) {
            const comps = try l.arena.alloc(u8, ts.cols);
            for (comps, 0..) |*c, i| c.* = @intCast(i);
            const sh = try l.b.add(.{ .op = .{ .shuffle = .{ .vec = v, .components = comps } }, .ty = try t.vector(sc, ts.cols) });
            return l.convert(sh, target);
        }
        // Other reshapes (matrix truncation, vector <-> matrix) go through
        // components: matrices map (row, col) to (row, col), everything else
        // flattened index to index.
        const n = ts.count();
        const comps = try l.arena.alloc(Ref, n);
        for (comps, 0..) |*c, k| {
            const src: u32 = if (fs.kind == .matrix and ts.kind == .matrix)
                @intCast((k / ts.cols) * fs.cols + k % ts.cols)
            else
                @intCast(k);
            c.* = try l.convert(try l.component(v, src), try t.scalar(tc));
        }
        return l.b.add(.{ .op = .{ .construct = comps }, .ty = target });
    }

    /// Scalar component `k` of a scalar / vector / matrix value (matrices in
    /// row-major order: `extract` on a matrix yields a row).
    fn component(l: *Lowerer, v: Ref, k: u32) Error!Ref {
        const t = l.types();
        const ty = l.b.f.inst(v).ty;
        const c = t.component(ty).?;
        switch (t.get(ty)) {
            .scalar, .@"enum" => return v,
            .vector => return l.b.add(.{ .op = .{ .extract = .{ .agg = v, .index = k } }, .ty = try t.scalar(c) }),
            .matrix => |m| {
                const row = try l.b.add(.{ .op = .{ .extract = .{ .agg = v, .index = k / m.cols } }, .ty = try t.vector(c, m.cols) });
                return l.b.add(.{ .op = .{ .extract = .{ .agg = row, .index = k % m.cols } }, .ty = try t.scalar(c) });
            },
            else => return error.Unsupported,
        }
    }

    /// A vector or matrix from its rows (`per_row` components each).
    fn flatConstruct(l: *Lowerer, ty: TypeId, rows: []const Ref, per_row: u32) Error!Ref {
        // Constructors take scalars: split the rows.
        const t = l.types();
        var comps: std.ArrayList(Ref) = .empty;
        for (rows) |r| for (0..per_row) |k| try comps.append(l.arena, try l.component(r, @intCast(k)));
        _ = t;
        return l.b.add(.{ .op = .{ .construct = comps.items }, .ty = ty });
    }

    /// Appends the scalar components of `v` (structs and arrays member by
    /// member).
    fn flatten(l: *Lowerer, v: Ref, out: *std.ArrayList(Ref)) Error!void {
        const t = l.types();
        const ty = l.b.f.inst(v).ty;
        switch (t.get(ty)) {
            // (Resources in structs are leaves of their own.)
            .scalar, .@"enum", .resource, .sampler => try out.append(l.arena, v),
            .vector, .matrix => for (0..t.componentCount(ty).?) |k| try out.append(l.arena, try l.component(v, @intCast(k))),
            .array => |a| for (0..a.len) |i| try l.flatten(try l.b.add(.{ .op = .{ .extract = .{ .agg = v, .index = @intCast(i) } }, .ty = a.elem }), out),
            .@"struct" => |st| for (st.fields.items, 0..) |f, i| {
                const fv = try l.b.add(.{ .op = .{ .extract = .{ .agg = v, .index = @intCast(i) } }, .ty = f.type });
                if (f.bits) {
                    for (st.bitfieldsIn(@intCast(i))) |bf| try out.append(l.arena, try l.bitRead(fv, bf));
                } else try l.flatten(fv, out);
            },
            else => {
                l.unsupported(.none, "flattening values of type '{s}' is not supported yet", .{l.s.typeName(ty)});
                return error.Unsupported;
            },
        }
    }

    /// A value of `ty` built from flattened scalars, consumed from `next`.
    fn fromFlat(l: *Lowerer, ty: TypeId, comps: []const Ref, next: *usize) Error!Ref {
        const t = l.types();
        switch (t.get(ty)) {
            .resource, .sampler => {
                defer next.* += 1;
                return comps[next.*];
            },
            .scalar, .@"enum" => {
                defer next.* += 1;
                return l.convert(comps[next.*], ty);
            },
            .vector, .matrix => {
                const n = t.componentCount(ty).?;
                const sc = try t.scalar(t.component(ty).?);
                const parts = try l.arena.alloc(Ref, n);
                for (parts) |*p| {
                    p.* = try l.convert(comps[next.*], sc);
                    next.* += 1;
                }
                if (n == 1 and t.get(ty) == .vector) return l.b.add(.{ .op = .{ .construct = parts }, .ty = ty });
                return l.b.add(.{ .op = .{ .construct = parts }, .ty = ty });
            },
            .array => |a| {
                const parts = try l.arena.alloc(Ref, a.len);
                for (parts) |*p| p.* = try l.fromFlat(a.elem, comps, next);
                return l.b.add(.{ .op = .{ .construct = parts }, .ty = ty });
            },
            .@"struct" => |st| {
                const parts = try l.arena.alloc(Ref, st.fields.items.len);
                for (parts, st.fields.items, 0..) |*p, f, i| {
                    if (f.bits) {
                        p.* = try l.b.constInt(f.type, 0);
                        for (st.bitfieldsIn(@intCast(i))) |bf| {
                            p.* = try l.bitInsert(p.*, bf, try l.convert(comps[next.*], bf.type));
                            next.* += 1;
                        }
                    } else p.* = try l.fromFlat(f.type, comps, next);
                }
                return l.b.add(.{ .op = .{ .construct = parts }, .ty = ty });
            },
            else => {
                l.unsupported(.none, "building values of type '{s}' is not supported yet", .{l.s.typeName(ty)});
                return error.Unsupported;
            },
        }
    }

    fn rvalue(l: *Lowerer, e: *ast.Expr) Error!Ref {
        const t = l.types();
        switch (e.kind) {
            .binary, .unary, .index, .assign => if (l.s.resolution(e)) |r| if (r == .function) return l.operatorCall(e, r.function),
            else => {},
        }
        switch (e.kind) {
            .int_lit => |text| {
                const ty = try l.concrete(e.ty);
                return l.b.constInt(ty, semamod.parseIntLiteral(text) orelse 0);
            },
            .float_lit => |text| {
                const ty = try l.concrete(e.ty);
                return l.b.constFloat(ty, semamod.parseFloatLiteral(text) orelse 0);
            },
            .bool_lit => |b| return l.b.constInt(try t.scalar(.bool), @intFromBool(b)),
            .name => {
                const r = l.s.resolution(e) orelse return l.fail(e, "this name");
                switch (r) {
                    .this_field => return l.b.load(try l.lvalue(e)),
                    .this_bitfield => |bf| {
                        if (l.this_ptr == .none) return l.fail(e, "this name");
                        return l.bitRead(try l.b.load(try l.bitStorage(l.this_ptr, bf)), bf);
                    },
                    .variable => |v| {
                        if (l.value_vars.get(v)) |val| return val;
                        if (v.storage == .global_uniform and holdsResources(&l.s.types, v.type)) return l.uniformValue(v, &.{}, v.type);
                        if (l.isSpecConstant(v)) return l.specConstant(v);
                        // Integer `static const` scalars are constants.
                        if (v.storage == .constant and v.init != null and isIntConstantType(&l.s.types, v.type)) {
                            if (l.s.evalVarInt(v)) |val| return l.b.constInt(try l.concrete(e.ty), val);
                        }
                        return l.b.load(try l.lvalue(e));
                    },
                    .enumerator => |v| return l.b.constInt(try l.concrete(e.ty), v),
                    else => return l.fail(e, "this name"),
                }
            },
            .binary => |x| return l.binary(e, x.op, x.lhs, x.rhs),
            .unary => |x| return l.unary(e, x.op, x.operand),
            .assign => |x| {
                const lt = x.lhs.ty;
                var value: Ref = undefined;
                if (x.op == .assign) {
                    value = try l.converted(x.rhs, lt);
                } else {
                    const old = try l.rvalue(x.lhs);
                    const rhs = try l.rvalue(x.rhs);
                    const bop = std.meta.stringToEnum(ast.BinaryOp, @tagName(x.op)).?;
                    const res = try l.arith(bop, old, rhs, lt, x.lhs.ty, x.rhs.ty);
                    value = try l.convert(res, lt);
                }
                try l.storeTo(x.lhs, value);
                return value;
            },
            .conditional => |x| {
                const ty = try l.concrete(e.ty);
                const tmp = try l.b.add(.{ .op = .local_var, .ty = ty, .ptr = .function });
                const cond = try l.condition(x.cond);
                const then_b = try l.b.newBlock();
                const else_b = try l.b.newBlock();
                const merge = try l.b.newBlock();
                l.b.f.block(l.b.cur).merge = .{ .selection = merge };
                l.b.terminate(.{ .cond_br = .{ .cond = cond, .then = then_b, .@"else" = else_b } });
                l.b.setBlock(then_b);
                try l.b.store(tmp, try l.converted(x.then, ty));
                l.b.terminate(.{ .br = merge });
                l.b.setBlock(else_b);
                try l.b.store(tmp, try l.converted(x.@"else", ty));
                l.b.terminate(.{ .br = merge });
                l.b.setBlock(merge);
                return l.b.load(tmp);
            },
            .call => |c| return l.call(e, c.callee, c.args),
            .construct => |c| return l.construct(e, try l.concrete(e.ty), c.args),
            .cast => |c| {
                const v = try l.rvalue(c.operand);
                return l.convertExplicit(v, try l.concrete(e.ty));
            },
            .member => |m| return l.member(e, m.base, m.name),
            .index => |x| {
                if (l.uniformPath(e)) |up| return l.uniformValue(up.v, up.path, e.ty);
                const bt = t.get(x.base.ty);
                if (bt == .descriptor_heap) {
                    const idx = try l.converted(x.index, try t.scalar(.uint));
                    return l.b.add(.{ .op = .{ .heap_resource = .{ .index = idx, .sampler = bt.descriptor_heap.sampler } }, .ty = e.ty });
                }
                if (bt == .resource) {
                    const res = try l.rvalue(x.base);
                    const idx = try l.indexValue(x.index, bt.resource.kind.indexDims());
                    return l.b.add(.{ .op = .{ .res_load = .{ .res = res, .index = idx } }, .ty = try l.concrete(e.ty) });
                }
                if (isAddressable(l.s, x.base)) return l.b.load(try l.lvalue(e));
                const base = try l.rvalue(x.base);
                if (l.s.evalInt(x.index)) |k| return l.b.add(.{ .op = .{ .extract = .{ .agg = base, .index = @intCast(k) } }, .ty = try l.concrete(e.ty) });
                // Dynamic index into a value: spill to storage.
                const tmp = try l.b.add(.{ .op = .local_var, .ty = l.b.f.inst(base).ty, .ptr = .function });
                try l.b.store(tmp, base);
                const idx = try l.converted(x.index, try t.scalar(.uint));
                const p = try l.b.add(.{ .op = .{ .access = .{ .base = tmp, .indices = try l.arena.dupe(Ref, &.{idx}) } }, .ty = try l.concrete(e.ty), .ptr = .function });
                return l.b.load(p);
            },
            .sizeof_type, .sizeof_expr, .is_same => {
                if (l.s.evalInt(e)) |v| return l.b.constInt(try l.concrete(e.ty), v);
                return l.fail(e, "this expression");
            },
            .this => {
                if (l.this_ptr == .none) return l.fail(e, "this expression");
                return l.b.load(l.this_ptr);
            },
            .init_list, .string_lit => return l.fail(e, "this expression"),
        }
    }

    fn fail(l: *Lowerer, e: *const ast.Expr, comptime what: []const u8) Error {
        l.unsupported(e.loc, what ++ " is not supported yet", .{});
        return error.Unsupported;
    }

    /// Index for `resource[i]`: uint, or uintN for multi-dimensional
    /// resources.
    fn indexValue(l: *Lowerer, e: *ast.Expr, dims: u8) Error!Ref {
        const t = l.types();
        const ty = if (dims <= 1) try t.scalar(.uint) else try t.vector(.uint, dims);
        return l.converted(e, ty);
    }

    fn binary(l: *Lowerer, e: *ast.Expr, op: ast.BinaryOp, lhs: *ast.Expr, rhs: *ast.Expr) Error!Ref {
        const t = l.types();
        switch (op) {
            .comma => {
                _ = try l.rvalue(lhs);
                return l.rvalue(rhs);
            },
            .log_and, .log_or => {
                // Short-circuit (HLSL 2021: scalar operands).
                const bool_ty = try t.scalar(.bool);
                const tmp = try l.b.add(.{ .op = .local_var, .ty = bool_ty, .ptr = .function });
                const a = try l.condition(lhs);
                try l.b.store(tmp, a);
                const rhs_b = try l.b.newBlock();
                const merge = try l.b.newBlock();
                l.b.f.block(l.b.cur).merge = .{ .selection = merge };
                l.b.terminate(.{ .cond_br = .{ .cond = a, .then = if (op == .log_and) rhs_b else merge, .@"else" = if (op == .log_and) merge else rhs_b } });
                l.b.setBlock(rhs_b);
                try l.b.store(tmp, try l.condition(rhs));
                l.b.terminate(.{ .br = merge });
                l.b.setBlock(merge);
                return l.b.load(tmp);
            },
            else => {},
        }
        const a = try l.rvalue(lhs);
        const b = try l.rvalue(rhs);
        return l.arith(op, a, b, try l.concrete(e.ty), lhs.ty, rhs.ty);
    }

    /// `a op b` with Sema's operand types and the expression's result type
    /// (bool-shaped for comparisons).
    fn arith(l: *Lowerer, op: ast.BinaryOp, a: Ref, b: Ref, result_ty: TypeId, a_ty: TypeId, b_ty: TypeId) Error!Ref {
        const t = l.types();
        const cmp: ?ir.CmpOp = switch (op) {
            .eq => .eq,
            .ne => .ne,
            .lt => .lt,
            .le => .le,
            .gt => .gt,
            .ge => .ge,
            else => null,
        };
        // The computation type: the result type, or for comparisons the
        // combined operand type in the result's shape.
        var comp_ty = result_ty;
        if (cmp != null) {
            const c = Scalar.combine(t.component(a_ty).?, t.component(b_ty).?);
            comp_ty = try t.withComponent(result_ty, if (c.isLiteral()) c.concrete() else c);
        }
        if (op == .shl or op == .shr) {
            const av = try l.convert(a, comp_ty);
            const bv = try l.convert(b, comp_ty);
            return l.b.add(.{ .op = .{ .binary = .{ .op = if (op == .shl) .shl else .shr, .lhs = av, .rhs = bv } }, .ty = comp_ty });
        }
        const av = try l.convert(a, comp_ty);
        const bv = try l.convert(b, comp_ty);
        if (cmp) |c| return l.b.add(.{ .op = .{ .cmp = .{ .op = c, .lhs = av, .rhs = bv } }, .ty = result_ty });
        const bop: ir.BinaryOp = switch (op) {
            .add => .add,
            .sub => .sub,
            .mul => .mul,
            .div => .div,
            .rem => .rem,
            .bit_and => .bit_and,
            .bit_or => .bit_or,
            .bit_xor => .bit_xor,
            else => unreachable,
        };
        return l.b.add(.{ .op = .{ .binary = .{ .op = bop, .lhs = av, .rhs = bv } }, .ty = comp_ty });
    }

    fn unary(l: *Lowerer, e: *ast.Expr, op: ast.UnaryOp, operand: *ast.Expr) Error!Ref {
        const t = l.types();
        const ty = try l.concrete(e.ty);
        switch (op) {
            .plus => return l.converted(operand, ty),
            .minus => return l.b.add(.{ .op = .{ .unary = .{ .op = .neg, .operand = try l.converted(operand, ty) } }, .ty = ty }),
            .bit_not => return l.b.add(.{ .op = .{ .unary = .{ .op = .bit_not, .operand = try l.converted(operand, ty) } }, .ty = ty }),
            .not => return l.b.add(.{ .op = .{ .unary = .{ .op = .not, .operand = try l.converted(operand, ty) } }, .ty = ty }),
            .pre_inc, .pre_dec, .post_inc, .post_dec => {
                const old = try l.rvalue(operand);
                const vty = l.b.f.inst(old).ty;
                const one = try l.convert(try l.b.constInt(try t.scalar(.int), 1), vty);
                const new = try l.b.add(.{ .op = .{ .binary = .{ .op = if (op == .pre_inc or op == .post_inc) .add else .sub, .lhs = old, .rhs = one } }, .ty = vty });
                try l.storeTo(operand, new);
                return if (op == .pre_inc or op == .pre_dec) new else old;
            },
        }
    }

    fn convertExplicit(l: *Lowerer, v: Ref, target: TypeId) Error!Ref {
        const t = l.types();
        const from = l.b.f.inst(v).ty;
        if (from == target) return v;
        if (t.get(from) == .dynamic_resource) return l.convert(v, target);
        const aggregate = switch (t.get(target)) {
            .@"struct", .array => true,
            else => switch (t.get(from)) {
                .@"struct", .array => true,
                else => false,
            },
        };
        if (!aggregate) return l.convert(v, target);
        // Aggregate casts: `(S)0` replicates a scalar; otherwise the source's
        // flattened components fill the target in order.
        var comps: std.ArrayList(Ref) = .empty;
        try l.flatten(v, &comps);
        const need = t.componentCount(target) orelse return error.Unsupported;
        if (comps.items.len == 1) {
            while (comps.items.len < need) try comps.append(l.arena, comps.items[0]);
        }
        if (comps.items.len < need) return error.Unsupported;
        var next: usize = 0;
        return l.fromFlat(target, comps.items, &next);
    }

    fn construct(l: *Lowerer, e: *ast.Expr, ty: TypeId, args: []const *ast.Expr) Error!Ref {
        const t = l.types();
        if (args.len == 0 and isRayQuery(t, ty)) {
            // A new query object.
            return l.b.load(try l.b.add(.{ .op = .local_var, .ty = ty, .ptr = .function }));
        }
        var comps: std.ArrayList(Ref) = .empty;
        for (args) |a| try l.flatten(try l.rvalue(a), &comps);
        if (comps.items.len == 0) return l.fail(e, "this constructor");
        const need = t.componentCount(ty) orelse return l.fail(e, "this constructor");
        if (comps.items.len == 1 and need > 1) {
            const sc = try l.convert(comps.items[0], try t.scalar(t.component(ty).?));
            return l.b.add(.{ .op = .{ .splat = sc }, .ty = ty });
        }
        var next: usize = 0;
        return l.fromFlat(ty, comps.items, &next);
    }

    fn initList(l: *Lowerer, e: *ast.Expr, ty: TypeId) Error!Ref {
        // The list's scalars, in order, fill `ty`.
        var flat: std.ArrayList(*ast.Expr) = .empty;
        try flattenList(l.arena, e, &flat);
        var comps: std.ArrayList(Ref) = .empty;
        for (flat.items) |x| try l.flatten(try l.rvalue(x), &comps);
        const need = flatLength(l.types(), ty) orelse return l.fail(e, "this initializer list");
        if (comps.items.len < need) return l.fail(e, "this initializer list");
        var next: usize = 0;
        return l.fromFlat(ty, comps.items, &next);
    }

    fn member(l: *Lowerer, e: *ast.Expr, base: *ast.Expr, name: []const u8) Error!Ref {
        const t = l.types();
        const bt = t.get(base.ty);
        switch (bt) {
            .scalar, .vector => {
                const v = try l.rvalue(base);
                const comps = (try swizzleComponents(l.arena, name)) orelse return l.fail(e, "this swizzle");
                const ty = try l.concrete(e.ty);
                if (bt == .scalar) {
                    if (comps.len == 1) return v;
                    return l.b.add(.{ .op = .{ .splat = v }, .ty = ty });
                }
                if (comps.len == 1) return l.b.add(.{ .op = .{ .extract = .{ .agg = v, .index = comps[0] } }, .ty = ty });
                return l.b.add(.{ .op = .{ .shuffle = .{ .vec = v, .components = comps } }, .ty = ty });
            },
            .matrix => |m| {
                const v = try l.rvalue(base);
                const ks = matrixSwizzle(l.arena, name, m.cols) orelse return l.fail(e, "this matrix swizzle");
                if (ks.len == 1) return l.component(v, ks[0]);
                const parts = try l.arena.alloc(Ref, ks.len);
                for (parts, ks) |*p, k| p.* = try l.component(v, k);
                return l.b.add(.{ .op = .{ .construct = parts }, .ty = try l.concrete(e.ty) });
            },
            .@"struct" => |info| {
                if (l.uniformPath(e)) |up| return l.uniformValue(up.v, up.path, e.ty);
                const r = l.s.resolution(e) orelse return l.fail(e, "this member");
                // A static member through an object.
                if (r == .variable) {
                    const v = r.variable;
                    if (v.storage == .constant and v.init != null and isIntConstantType(&l.s.types, v.type)) {
                        if (l.s.evalVarInt(v)) |val| return l.b.constInt(try l.concrete(e.ty), val);
                    }
                    return l.b.load(try l.variableLvalue(e, v));
                }
                if (r == .bitfield) {
                    const bf = r.bitfield;
                    const storage = if (isAddressable(l.s, base))
                        try l.b.load(try l.bitStorage(try l.lvalue(base), bf))
                    else
                        try l.b.add(.{ .op = .{ .extract = .{ .agg = try l.rvalue(base), .index = bf.storage } }, .ty = info.fields.items[bf.storage].type });
                    return l.bitRead(storage, bf);
                }
                if (isAddressable(l.s, base)) return l.b.load(try l.lvalue(e));
                const v = try l.rvalue(base);
                return l.b.add(.{ .op = .{ .extract = .{ .agg = v, .index = r.field } }, .ty = e.ty });
            },
            // ConstantBuffer<S> / TextureBuffer<S>: members of S.
            .resource => |rs| {
                if (rs.kind != .constant_buffer and rs.kind != .texture_buffer) return l.fail(e, "this member access");
                const r = l.s.resolution(e) orelse return l.fail(e, "this member");
                if (r == .bitfield) {
                    const bf = r.bitfield;
                    const idx = try l.b.constInt(try t.scalar(.uint), bf.storage);
                    const sty = t.get(rs.elem).@"struct".fields.items[bf.storage].type;
                    const ptr = try l.b.add(.{ .op = .{ .access = .{ .base = try l.rvalue(base), .indices = try l.arena.dupe(Ref, &.{idx}) } }, .ty = sty, .ptr = .cbuffer });
                    return l.bitRead(try l.b.load(ptr), bf);
                }
                return l.b.load(try l.lvalue(e));
            },
            else => return l.fail(e, "this member access"),
        }
    }

    /// A call of a `[[vk::ext_instruction(opcode[, set])]]` function: the
    /// instruction itself (SPIR-V only).
    fn spirvInstCall(l: *Lowerer, e: *ast.Expr, f: *const semamod.Function, args: []const *ast.Expr, ret_ty: TypeId) Error!Ref {
        if (!l.s.opts.spirv) return l.fail(e, "inline SPIR-V outside SPIR-V");
        var inst: ir.SpirvInst = .{ .opcode = 0, .operands = &.{} };
        var caps: std.ArrayList(u32) = .empty;
        var exts: std.ArrayList([]const u8) = .empty;
        for (f.decl.attrs) |a| {
            if (std.mem.eql(u8, a.name, "vk::ext_instruction") and a.args.len >= 1) {
                inst.opcode = @intCast(l.s.evalInt(a.args[0]) orelse return l.fail(e, "this inline SPIR-V instruction"));
                if (a.args.len >= 2 and a.args[1].kind == .string_lit) inst.set = try stringContents(l.arena, a.args[1].kind.string_lit);
            }
            if (std.mem.eql(u8, a.name, "vk::ext_capability")) for (a.args) |x| {
                try caps.append(l.arena, @intCast(l.s.evalInt(x) orelse continue));
            };
            if (std.mem.eql(u8, a.name, "vk::ext_extension")) for (a.args) |x| if (x.kind == .string_lit) {
                try exts.append(l.arena, try stringContents(l.arena, x.kind.string_lit));
            };
        }
        const Operand = @typeInfo(@TypeOf(inst.operands)).pointer.child;
        var ops: std.ArrayList(Operand) = .empty;
        // Missing trailing arguments take the parameters' defaults.
        var full = args;
        if (args.len < f.decl.params.len) {
            const all = try l.arena.alloc(*ast.Expr, f.decl.params.len);
            @memcpy(all[0..args.len], args);
            for (all[args.len..], f.decl.params[args.len..]) |*x, pd| x.* = pd.init orelse return l.fail(e, "this call");
            full = all;
        }
        for (full, 0..) |a, i| {
            const pd = if (i < f.decl.params.len) f.decl.params[i] else null;
            const pattrs: []const ast.Attribute = if (pd) |x| x.attrs else &.{};
            if (hasAttr(pattrs, "vk::ext_literal")) {
                const v = l.s.evalInt(a) orelse return l.fail(a, "a non-constant [[vk::ext_literal]] argument");
                try ops.append(l.arena, .{ .literal = @truncate(@as(u64, @bitCast(v))) });
            } else if (hasAttr(pattrs, "vk::ext_reference")) {
                try ops.append(l.arena, .{ .value = try l.lvalue(a) });
            } else {
                const pt = if (i < f.params.len) f.params[i].type else a.ty;
                try ops.append(l.arena, .{ .value = try l.converted(a, pt) });
            }
        }
        inst.operands = ops.items;
        inst.capabilities = caps.items;
        inst.extensions = exts.items;
        const p = try l.arena.create(ir.SpirvInst);
        p.* = inst;
        return l.b.add(.{ .op = .{ .spirv_inst = p }, .ty = ret_ty });
    }

    fn call(l: *Lowerer, e: *ast.Expr, callee: *ast.Expr, args: []const *ast.Expr) Error!Ref {
        const r = l.s.resolution(e) orelse return l.fail(e, "this call");
        const ret_ty = try l.concrete(e.ty);
        switch (r) {
            .function => |f| {
                if (!f.defined and hasAttr(f.decl.attrs, "vk::ext_instruction")) return l.spirvInstCall(e, f, args, ret_ty);
                // OpCooperativeMatrixLengthKHR of the template argument.
                if (!f.defined and std.mem.startsWith(u8, f.name, "__builtin_spv_CooperativeMatrixLengthKHR") and f.template_args.len == 1 and f.template_args[0] == .type and l.s.opts.spirv) {
                    const p = try l.arena.create(ir.SpirvInst);
                    const ops = try l.arena.alloc(@typeInfo(@TypeOf(p.operands)).pointer.child, 1);
                    ops[0] = .{ .type = f.template_args[0].type };
                    p.* = .{ .opcode = 4460, .operands = ops };
                    return l.b.add(.{ .op = .{ .spirv_inst = p }, .ty = ret_ty });
                }
                const fi = try l.functionIndex(f);
                // Missing trailing arguments take the parameters' defaults.
                var full = args;
                if (args.len < f.params.len) {
                    const all = try l.arena.alloc(*ast.Expr, f.params.len);
                    @memcpy(all[0..args.len], args);
                    for (all[args.len..], f.decl.params[args.len..]) |*a, pd| {
                        a.* = pd.init orelse return l.fail(e, "this call");
                    }
                    full = all;
                }
                // `obj.method(...)`: the object's storage (a temporary for
                // rvalues).
                // (A struct value called directly uses its operator().)
                const base: ?*ast.Expr = if (!isMethod(f)) null else if (callee.kind == .member) callee.kind.member.base else if (l.s.types.get(callee.ty) == .@"struct") callee else null;
                return l.methodCall(f, fi, base, full, ret_ty);
            },
            else => return l.callOther(e, r, callee, args, ret_ty),
        }
    }

    /// A call to `f` with `base_expr` as the object of a method (null:
    /// the current `this`, or no object).
    fn methodCall(l: *Lowerer, f: *const semamod.Function, fi: u32, base_expr: ?*ast.Expr, args: []const *ast.Expr, ret_ty: TypeId) Error!Ref {
            var object: ?Ref = null;
            var write_back: ?Ref = null;
            const owner_ty = if (isMethod(f)) try l.s.types.intern(.{ .@"struct" = f.owner.? }) else TypeTable.void_type;
            if (base_expr) |base| {
                const direct = if (isAddressable(l.s, base)) try l.lvalue(base) else null;
                const plain = if (direct) |p| l.b.f.inst(p).op == .local_var or l.b.f.inst(p).op == .param else false;
                if (direct != null and plain and base.ty == owner_ty) {
                    object = direct;
                } else {
                    // Through a function-local copy of the method's own
                    // struct (a base prefix of derived objects), written
                    // back afterwards to writable storage.
                    const tmp = try l.b.add(.{ .op = .local_var, .ty = owner_ty, .ptr = .function });
                    var whole = if (direct) |p| try l.b.load(p) else try l.rvalue(base);
                    var whole_ty = base.ty;
                    if (l.s.types.get(base.ty) == .resource) {
                        // A method of ConstantBuffer<S>'s S: on a copy of S.
                        whole_ty = l.s.types.get(base.ty).resource.elem;
                        whole = try l.convert(whole, whole_ty);
                    }
                    try l.b.store(tmp, try l.basePrefix(whole, whole_ty, owner_ty));
                    object = tmp;
                    if (direct) |p| switch (l.b.f.inst(p).ptr) {
                        .function, .private, .groupshared => write_back = p,
                        else => {},
                    };
                }
            }
            const res = try l.userCall(f, fi, args, ret_ty, object);
            if (write_back) |p| {
                const updated = try l.b.load(object.?);
                if (base_expr.?.ty == owner_ty) {
                    try l.b.store(p, updated);
                } else {
                    // Only the base's fields.
                    for (l.s.types.get(owner_ty).@"struct".fields.items, 0..) |fld, k| {
                        const idx = try l.b.constInt(try l.types().scalar(.uint), @intCast(k));
                        const fp = try l.b.add(.{ .op = .{ .access = .{ .base = p, .indices = try l.arena.dupe(Ref, &.{idx}) } }, .ty = fld.type, .ptr = l.b.f.inst(p).ptr });
                        try l.b.store(fp, try l.b.add(.{ .op = .{ .extract = .{ .agg = updated, .index = @intCast(k) } }, .ty = fld.type }));
                    }
                }
            }
            return res;
    }

    /// An overloaded operator: a method call on the first operand.
    fn operatorCall(l: *Lowerer, e: *ast.Expr, f: *const semamod.Function) Error!Ref {
        const fi = try l.functionIndex(f);
        const ret_ty = try l.concrete(f.ret);
        switch (e.kind) {
            .binary => |x| return l.methodCall(f, fi, x.lhs, &.{x.rhs}, ret_ty),
            .unary => |x| return l.methodCall(f, fi, x.operand, &.{}, ret_ty),
            .index => |x| return l.methodCall(f, fi, x.base, &.{x.index}, ret_ty),
            .call => |x| return l.methodCall(f, fi, x.callee, x.args, ret_ty),
            .assign => |x| {
                const r = try l.methodCall(f, fi, x.lhs, &.{x.rhs}, ret_ty);
                // `a op= b` through operator op: assign the result.
                if (!std.mem.endsWith(u8, f.name, "=")) {
                    const v = try l.convert(r, x.lhs.ty);
                    try l.storeTo(x.lhs, v);
                    return v;
                }
                return r;
            },
            else => return l.fail(e, "this operator"),
        }
    }

    fn userCall(l: *Lowerer, f: *const semamod.Function, fi: u32, args: []const *ast.Expr, ret_ty: TypeId, object: ?Ref) Error!Ref {
        {
            {
                const vals = try l.arena.alloc(Ref, args.len);
                const temps = try l.arena.alloc(Ref, args.len);
                var n_vals: usize = 0;
                for (args, f.params, 0..) |a, p, i| {
                    if (l.s.types.get(p.type) == .stream) continue;
                    n_vals += 1;
                    if (p.groupshared) {
                        // The caller's groupshared variable itself.
                        vals[i] = try l.lvalue(a);
                        temps[i] = .none;
                    } else if (p.dir == .in) {
                        vals[i] = try l.converted(a, p.type);
                    } else {
                        // Copy-in / copy-out through a temporary.
                        temps[i] = try l.b.add(.{ .op = .local_var, .ty = p.type, .ptr = .function });
                        if (p.dir == .inout) try l.b.store(temps[i], try l.converted(a, p.type));
                        vals[i] = temps[i];
                    }
                }
                // (Stream arguments are dropped.)
                var packed_vals: std.ArrayList(Ref) = .empty;
                for (f.params, 0..) |p, i| if (l.s.types.get(p.type) != .stream) try packed_vals.append(l.arena, vals[i]);
                std.debug.assert(packed_vals.items.len == n_vals);
                if (isMethod(f)) try packed_vals.insert(l.arena, 0, object orelse (if (l.this_ptr != .none) l.this_ptr else return error.Unsupported));
                const res = try l.b.add(.{ .op = .{ .call = .{ .func = fi, .args = packed_vals.items } }, .ty = ret_ty });
                for (args, f.params, 0..) |a, p, i| {
                    if (p.dir == .in or p.groupshared or l.s.types.get(p.type) == .stream) continue;
                    const back = try l.b.load(temps[i]);
                    try l.storeTo(a, try l.convert(back, a.ty));
                }
                return res;
            }
        }
    }

    fn callOther(l: *Lowerer, e: *ast.Expr, r: semamod.Resolution, callee: *ast.Expr, args: []const *ast.Expr, ret_ty: TypeId) Error!Ref {
        switch (r) {
            .intrinsic => |it| {
                const name = table.intrinsics[it.index].name;
                const spec = table.intrinsics[it.index];
                if (it.object) |_| if (l.s.types.get(callee.kind.member.base.ty) == .stream) {
                    return l.streamMethod(e, callee.kind.member.base, name, args);
                };
                if (it.object) |_| {
                    const obj = callee.kind.member.base;
                    const res = try l.rvalue(obj);
                    // Out parameters (GetDimensions, ...) are passed as
                    // pointers to temporaries, copied back afterwards.
                    const vals = try l.arena.alloc(Ref, args.len);
                    var any_out = false;
                    for (args, 0..) |a, i| {
                        const pt = try l.concrete(it.params[i]);
                        if (i < spec.params.len and spec.params[i].qual != .in) {
                            vals[i] = try l.b.add(.{ .op = .local_var, .ty = pt, .ptr = .function });
                            any_out = true;
                        } else vals[i] = try l.converted(a, pt);
                    }
                    const result = try l.b.add(.{ .op = .{ .method = .{ .name = name, .res = res, .args = vals } }, .ty = ret_ty });
                    if (any_out) for (args, 0..) |a, i| {
                        if (i >= spec.params.len or spec.params[i].qual == .in) continue;
                        try l.storeTo(a, try l.convert(try l.b.load(vals[i]), a.ty));
                    };
                    return result;
                }
                if (std.mem.eql(u8, name, "DispatchMesh") and args.len == 4) {
                    // The payload goes by reference (a groupshared
                    // variable).
                    const vals = try l.arena.alloc(Ref, 4);
                    for (vals[0..3], args[0..3]) |*v, a| v.* = try l.converted(a, try l.types().scalar(.uint));
                    vals[3] = try l.lvalue(args[3]);
                    l.mesh_payload = args[3].ty;
                    return l.b.add(.{ .op = .{ .intrinsic = .{ .name = name, .args = vals } }, .ty = TypeTable.void_type });
                }
                // SM 6.10 matrices: results go straight to the `out` /
                // `ref` argument's storage; groupshared arrays by reference.
                if (std.mem.startsWith(u8, name, "__builtin_LinAlg_")) {
                    const vals = try l.arena.alloc(Ref, args.len);
                    for (args, 0..) |a, i| {
                        const q = if (i < spec.params.len) spec.params[i].qual else .in;
                        const pt = it.params[i];
                        vals[i] = if (q != .in or l.s.types.get(a.ty) == .array)
                            try l.lvalue(a)
                        else if (pt == TypeTable.error_type or l.s.types.get(pt) == .resource)
                            try l.rvalue(a)
                        else
                            try l.converted(a, try l.concrete(pt));
                    }
                    return l.b.add(.{ .op = .{ .intrinsic = .{ .name = name, .args = vals } }, .ty = ret_ty });
                }
                // `out` parameters go through temporaries copied back
                // afterwards; `ref` ones (atomic destinations) pass the
                // storage itself.
                const vals = try l.arena.alloc(Ref, args.len);
                var any_out = false;
                for (args, 0..) |a, i| {
                    const q = if (i < spec.params.len) spec.params[i].qual else .in;
                    const pt = try l.concrete(it.params[i]);
                    switch (q) {
                        .in => vals[i] = try l.converted(a, pt),
                        .ref => vals[i] = try l.lvalue(a),
                        .out, .inout => {
                            vals[i] = try l.b.add(.{ .op = .local_var, .ty = pt, .ptr = .function });
                            if (q == .inout) try l.b.store(vals[i], try l.converted(a, pt));
                            any_out = true;
                        },
                    }
                }
                const result = try l.b.add(.{ .op = .{ .intrinsic = .{ .name = name, .args = vals } }, .ty = ret_ty });
                if (any_out) for (args, 0..) |a, i| {
                    const q = if (i < spec.params.len) spec.params[i].qual else .in;
                    if (q != .out and q != .inout) continue;
                    try l.storeTo(a, try l.convert(try l.b.load(vals[i]), a.ty));
                };
                return result;
            },
            else => return l.fail(e, "this call"),
        }
    }

    /// Pointer to the storage `e` designates.
    /// `g.a.b`, rooted at a global uniform struct holding resources: the
    /// variable and the member indices.
    fn uniformPath(l: *Lowerer, e: *ast.Expr) ?struct { v: *const Variable, path: []const u32 } {
        switch (e.kind) {
            .name => {
                const r = l.s.resolution(e) orelse return null;
                if (r != .variable) return null;
                const v = r.variable;
                if (v.storage != .global_uniform or !holdsResources(&l.s.types, v.type)) return null;
                return .{ .v = v, .path = &.{} };
            },
            .member => |m| {
                if (l.s.types.get(m.base.ty) != .@"struct") return null;
                const base = l.uniformPath(m.base) orelse return null;
                const r = l.s.resolution(e) orelse return null;
                if (r != .field) return null;
                const path = std.mem.concat(l.arena, u32, &.{ base.path, &.{r.field} }) catch return null;
                return .{ .v = base.v, .path = path };
            },
            // An element of an array of structs holding resources (at a
            // constant index).
            .index => |x| {
                const bt = l.s.types.get(x.base.ty);
                if (bt != .array or !holdsResources(&l.s.types, x.base.ty) or isResourceLike(&l.s.types, bt.array.elem)) return null;
                const base = l.uniformPath(x.base) orelse return null;
                const k = l.s.evalInt(x.index) orelse return null;
                if (k < 0 or k >= bt.array.len) return null;
                const path = std.mem.concat(l.arena, u32, &.{ base.path, &.{@intCast(k)} }) catch return null;
                return .{ .v = base.v, .path = path };
            },
            else => return null,
        }
    }

    const LeafPath = struct { path: []const u32, ty: TypeId };

    /// The resources of a struct type, in member order.
    fn resourceLeaves(l: *Lowerer, ty: TypeId, prefix: []const u32, out: *std.ArrayList(LeafPath)) Error!void {
        const t = l.types();
        if (isResourceLike(t, ty) or layout.isOpaque(t, ty)) return out.append(l.arena, .{ .path = prefix, .ty = ty });
        if (t.get(ty) == .array) {
            for (0..t.get(ty).array.len) |k| try l.resourceLeaves(t.get(ty).array.elem, try std.mem.concat(l.arena, u32, &.{ prefix, &.{@intCast(k)} }), out);
            return;
        }
        if (t.get(ty) != .@"struct") return;
        for (t.get(ty).@"struct".fields.items, 0..) |f, k| {
            if (!layout.isOpaque(t, f.type) and !holdsResources(t, f.type)) continue;
            try l.resourceLeaves(f.type, try std.mem.concat(l.arena, u32, &.{ prefix, &.{@intCast(k)} }), out);
        }
    }

    /// `g.inner.tex`.
    /// (Array elements by flattened index, as dxc: `g[5].tex`.)
    fn leafName(l: *Lowerer, v: *const Variable, path: []const u32) Error![]const u8 {
        var name: std.ArrayList(u8) = .empty;
        try name.appendSlice(l.arena, v.name);
        var cur = v.type;
        var flat: ?u32 = null;
        for (path) |k| switch (l.s.types.get(cur)) {
            .array => |arr| {
                flat = (flat orelse 0) * arr.len + k;
                cur = arr.elem;
            },
            .@"struct" => |st| {
                if (flat) |fl| try name.print(l.arena, "[{d}]", .{fl});
                flat = null;
                const f = st.fields.items[k];
                try name.print(l.arena, ".{s}", .{f.name});
                cur = f.type;
            },
            else => {},
        };
        if (flat) |fl| try name.print(l.arena, "[{d}]", .{fl});
        return name.items;
    }

    /// The global of a resource inside a global struct, named by its path
    /// (`g.tex`) and bound like any other unbound resource.
    fn leafGlobal(l: *Lowerer, v: *const Variable, path: []const u32, ty: TypeId) Error!Ref {
        const name = try l.leafName(v, path);
        const gop = try l.leaf_globals.getOrPut(l.arena, name);
        if (!gop.found_existing) {
            try l.m.globals.append(l.arena, .{ .name = name, .ty = ty, .space = .resource });
            gop.value_ptr.* = @intCast(l.m.globals.items.len - 1);
        }
        return l.b.add(.{ .op = .{ .global = gop.value_ptr.* }, .ty = ty, .ptr = .resource });
    }

    /// The value at `path` in a global struct holding resources: its
    /// resources from their globals, its data from $Globals.
    fn uniformValue(l: *Lowerer, v: *const Variable, path: []const u32, ty: TypeId) Error!Ref {
        const t = l.types();
        if (layout.isOpaque(t, ty)) return l.b.load(try l.leafGlobal(v, path, ty));
        if (holdsResources(t, ty)) {
            if (t.get(ty) == .array) {
                const arr = t.get(ty).array;
                const parts = try l.arena.alloc(Ref, arr.len);
                for (parts, 0..) |*p, k| p.* = try l.uniformValue(v, try std.mem.concat(l.arena, u32, &.{ path, &.{@intCast(k)} }), arr.elem);
                return l.b.add(.{ .op = .{ .construct = parts }, .ty = ty });
            }
            const st = t.get(ty).@"struct";
            const parts = try l.arena.alloc(Ref, st.fields.items.len);
            for (parts, st.fields.items, 0..) |*p, f, k| p.* = try l.uniformValue(v, try std.mem.concat(l.arena, u32, &.{ path, &.{@intCast(k)} }), f.type);
            return l.b.add(.{ .op = .{ .construct = parts }, .ty = ty });
        }
        const cm = try l.cbufferMember(v);
        const glob = l.m.globals.items[cm.global];
        const base = try l.b.add(.{ .op = .{ .global = cm.global }, .ty = glob.ty, .ptr = .cbuffer });
        const idx = try l.arena.alloc(Ref, path.len + 1);
        idx[0] = try l.b.constInt(try t.scalar(.uint), cm.field);
        for (path, idx[1..]) |k, *x| x.* = try l.b.constInt(try t.scalar(.uint), k);
        return l.b.load(try l.b.add(.{ .op = .{ .access = .{ .base = base, .indices = idx } }, .ty = ty, .ptr = .cbuffer }));
    }

    /// Storage of a variable that is not a local (locals are in `vars`).
    fn variableLvalue(l: *Lowerer, e: *ast.Expr, v: *const Variable) Error!Ref {
        const t = l.types();
        if (l.vars.get(v)) |p| return p;
        switch (v.storage) {
            .local, .param, .local_static => return l.fail(e, "this variable"),
            .global_uniform, .cbuffer => {
                if (isObject(&l.s.types, v.type)) {
                    l.unsupported(e.loc, "resource '{s}' declared as a uniform is not supported yet", .{v.name});
                    return error.Unsupported;
                }
                if (l.isPushConstantStruct(v)) {
                    // A buffer of its own (SPIR-V push constants).
                    const g = l.globals.get(v) orelse blk: {
                        try l.m.globals.append(l.arena, .{ .name = v.name, .ty = v.type, .space = .cbuffer, .push_constant = true });
                        const gi: u32 = @intCast(l.m.globals.items.len - 1);
                        try l.globals.put(l.arena, v, gi);
                        break :blk gi;
                    };
                    return l.b.add(.{ .op = .{ .global = g }, .ty = v.type, .ptr = .cbuffer });
                }
                const cm = try l.cbufferMember(v);
                const glob = l.m.globals.items[cm.global];
                const base = try l.b.add(.{ .op = .{ .global = cm.global }, .ty = glob.ty, .ptr = .cbuffer });
                const idx = try l.b.constInt(try t.scalar(.uint), cm.field);
                return l.b.add(.{ .op = .{ .access = .{ .base = base, .indices = try l.arena.dupe(Ref, &.{idx}) } }, .ty = v.type, .ptr = .cbuffer });
            },
            else => {},
        }
        const g = try l.globalIndex(v);
        const glob = l.m.globals.items[g];
        return l.b.add(.{ .op = .{ .global = g }, .ty = glob.ty, .ptr = glob.space });
    }

    fn lvalue(l: *Lowerer, e: *ast.Expr) Error!Ref {
        const t = l.types();
        // A resource inside a global struct: its own global.
        if (e.kind == .member or e.kind == .index) if (l.uniformPath(e)) |up| if (layout.isOpaque(t, e.ty)) return l.leafGlobal(up.v, up.path, e.ty);
        switch (e.kind) {
            .this => {
                if (l.this_ptr == .none) return l.fail(e, "this expression");
                return l.this_ptr;
            },
            .name => {
                const r = l.s.resolution(e) orelse return l.fail(e, "this name");
                if (r == .this_field) {
                    if (l.this_ptr == .none) return l.fail(e, "this name");
                    const idx = try l.b.constInt(try t.scalar(.uint), r.this_field);
                    return l.b.add(.{ .op = .{ .access = .{ .base = l.this_ptr, .indices = try l.arena.dupe(Ref, &.{idx}) } }, .ty = e.ty, .ptr = l.b.f.inst(l.this_ptr).ptr });
                }
                if (r != .variable) return l.fail(e, "this name");
                return l.variableLvalue(e, r.variable);
            },
            .member => |m| {
                const r = l.s.resolution(e) orelse return l.fail(e, "this member");
                // A static member through an object.
                if (r == .variable) return l.variableLvalue(e, r.variable);
                if (r != .field) return l.fail(e, "this member");
                const idx = try l.b.constInt(try t.scalar(.uint), r.field);
                if (t.get(m.base.ty) == .resource) {
                    // A member of a ConstantBuffer<S>: inside the buffer.
                    const res = try l.rvalue(m.base);
                    return l.b.add(.{ .op = .{ .access = .{ .base = res, .indices = try l.arena.dupe(Ref, &.{idx}) } }, .ty = e.ty, .ptr = .cbuffer });
                }
                const base = try l.lvalue(m.base);
                return l.b.add(.{ .op = .{ .access = .{ .base = base, .indices = try l.arena.dupe(Ref, &.{idx}) } }, .ty = e.ty, .ptr = l.b.f.inst(base).ptr });
            },
            .index => |x| {
                if (t.get(x.base.ty) == .resource) {
                    // An element of a buffer or texture (atomics' `ref`).
                    const base = try l.rvalue(x.base);
                    const idx = try l.indexValue(x.index, t.get(x.base.ty).resource.kind.indexDims());
                    return l.b.add(.{ .op = .{ .access = .{ .base = base, .indices = try l.arena.dupe(Ref, &.{idx}) } }, .ty = e.ty, .ptr = .resource });
                }
                const base = try l.lvalue(x.base);
                const idx = try l.converted(x.index, try t.scalar(.uint));
                return l.b.add(.{ .op = .{ .access = .{ .base = base, .indices = try l.arena.dupe(Ref, &.{idx}) } }, .ty = e.ty, .ptr = l.b.f.inst(base).ptr });
            },
            .cast => |c| return l.lvalue(c.operand),
            else => return l.fail(e, "this assignment target"),
        }
    }

    /// Whether `e` designates part of a mesh shader output array.
    fn isMeshOutput(l: *Lowerer, e: *const ast.Expr) bool {
        var x = e;
        while (true) switch (x.kind) {
            .member => |m| x = m.base,
            .index => |ix| x = ix.base,
            .name => {
                const r = l.s.resolution(x) orelse return false;
                if (r != .variable) return false;
                const p = l.vars.get(r.variable) orelse return false;
                return l.b.f.inst(p).ptr == .mesh;
            },
            else => return false,
        };
    }

    /// Pointer to the storage field holding bitfield `bf` of the struct
    /// `ptr` points to.
    fn bitStorage(l: *Lowerer, ptr: Ref, bf: Bitfield) Error!Ref {
        const t = l.types();
        const info = t.get(l.b.f.inst(ptr).ty).@"struct";
        const idx = try l.b.constInt(try t.scalar(.uint), bf.storage);
        return l.b.add(.{ .op = .{ .access = .{ .base = ptr, .indices = try l.arena.dupe(Ref, &.{idx}) } }, .ty = info.fields.items[bf.storage].type, .ptr = l.b.f.inst(ptr).ptr });
    }

    /// The value of bitfield `bf` in its storage word, zero- or
    /// sign-extended.
    fn bitRead(l: *Lowerer, storage: Ref, bf: Bitfield) Error!Ref {
        const t = l.types();
        const sc = t.component(bf.type).?;
        const st = try t.scalar(if (sc == .bool) .uint else sc);
        const bits: u8 = @intCast(sc.size() * 8);
        const x = try l.convert(storage, st);
        var v: Ref = undefined;
        if (t.get(st).scalar.isUnsigned()) {
            const shifted = if (bf.offset == 0) x else try l.b.add(.{ .op = .{ .binary = .{ .op = .shr, .lhs = x, .rhs = try l.b.constInt(st, bf.offset) } }, .ty = st });
            v = if (bf.width == bits) shifted else try l.b.add(.{ .op = .{ .binary = .{ .op = .bit_and, .lhs = shifted, .rhs = try l.constBits(st, lowMask(bf.width)) } }, .ty = st });
        } else {
            // Shift the field to the top, then arithmetically back down.
            const up = bits - bf.offset - bf.width;
            const hi = if (up == 0) x else try l.b.add(.{ .op = .{ .binary = .{ .op = .shl, .lhs = x, .rhs = try l.b.constInt(st, up) } }, .ty = st });
            v = if (bf.width == bits) hi else try l.b.add(.{ .op = .{ .binary = .{ .op = .shr, .lhs = hi, .rhs = try l.b.constInt(st, bits - bf.width) } }, .ty = st });
        }
        return l.convert(v, bf.type);
    }

    /// An integer constant of scalar type `ty` with bit pattern `v`.
    fn constBits(l: *Lowerer, ty: TypeId, v: u64) Error!Ref {
        const sc = l.types().component(ty).?;
        const bits: u8 = @intCast(sc.size() * 8);
        if (sc.isUnsigned()) return l.b.constInt(ty, @bitCast(v & lowMask(bits)));
        return l.b.constInt(ty, signExtend(v, bits));
    }

    /// `storage` with bitfield `bf` replaced by `value`.
    fn bitInsert(l: *Lowerer, storage: Ref, bf: Bitfield, value: Ref) Error!Ref {
        const t = l.types();
        const st = l.b.f.inst(storage).ty;
        const bits: u8 = @intCast(t.component(st).?.size() * 8);
        const mask = lowMask(bf.width);
        const field_mask = mask << @intCast(bf.offset);
        const keep_bits: u64 = if (bits == 64) ~field_mask else ~field_mask & lowMask(bits);
        const keep = try l.b.add(.{ .op = .{ .binary = .{ .op = .bit_and, .lhs = storage, .rhs = try l.constBits(st, keep_bits) } }, .ty = st });
        var v = try l.convert(value, st);
        if (bf.width < bits) v = try l.b.add(.{ .op = .{ .binary = .{ .op = .bit_and, .lhs = v, .rhs = try l.constBits(st, mask) } }, .ty = st });
        if (bf.offset > 0) v = try l.b.add(.{ .op = .{ .binary = .{ .op = .shl, .lhs = v, .rhs = try l.b.constInt(st, bf.offset) } }, .ty = st });
        return l.b.add(.{ .op = .{ .binary = .{ .op = .bit_or, .lhs = keep, .rhs = v } }, .ty = st });
    }

    /// Stores `value` (already of `lhs`'s type) into what `lhs` designates.
    fn storeTo(l: *Lowerer, lhs: *ast.Expr, value: Ref) Error!void {
        const t = l.types();
        if (lhs.kind == .member or lhs.kind == .name) if (l.s.resolution(lhs)) |r| switch (r) {
            .bitfield, .this_bitfield => |bf| {
                const struct_ptr = if (r == .bitfield) try l.lvalue(lhs.kind.member.base) else l.this_ptr;
                if (struct_ptr == .none) return l.fail(lhs, "this assignment target");
                const ptr = try l.bitStorage(struct_ptr, bf);
                try l.b.store(ptr, try l.bitInsert(try l.b.load(ptr), bf, value));
                return;
            },
            else => {},
        };
        switch (lhs.kind) {
            .index => |x| if (t.get(x.base.ty) == .resource) {
                const res = try l.rvalue(x.base);
                const idx = try l.indexValue(x.index, t.get(x.base.ty).resource.kind.indexDims());
                _ = try l.b.add(.{ .op = .{ .res_store = .{ .res = res, .index = idx, .value = value } }, .ty = TypeTable.void_type });
                return;
            },
            .member => |m| if (t.get(m.base.ty) == .matrix) {
                const mt = t.get(m.base.ty).matrix;
                const ks = matrixSwizzle(l.arena, m.name, mt.cols) orelse return error.Unsupported;
                var whole = try l.rvalue(m.base);
                const row_ty = try t.vector(mt.elem, mt.cols);
                for (ks, 0..) |k, i| {
                    const part = if (ks.len == 1) value else try l.component(value, @intCast(i));
                    const r = k / mt.cols;
                    const row = try l.b.add(.{ .op = .{ .extract = .{ .agg = whole, .index = r } }, .ty = row_ty });
                    const new_row = try l.b.add(.{ .op = .{ .insert = .{ .agg = row, .value = part, .index = k % mt.cols } }, .ty = row_ty });
                    whole = try l.b.add(.{ .op = .{ .insert = .{ .agg = whole, .value = new_row, .index = r } }, .ty = m.base.ty });
                }
                return l.storeTo(m.base, whole);
            } else if (t.get(m.base.ty) == .vector or t.get(m.base.ty) == .scalar) {
                // Swizzle store: read, replace the named components, write.
                const comps = (try swizzleComponents(l.arena, m.name)) orelse return error.Unsupported;
                if (t.get(m.base.ty) == .scalar) return l.storeTo(m.base, value);
                if (l.isMeshOutput(m.base)) {
                    // Outputs cannot be read back: store each component.
                    const base_ptr = try l.lvalue(m.base);
                    const ec = try t.scalar(t.component(m.base.ty).?);
                    for (comps, 0..) |c, i| {
                        const part = if (comps.len == 1) value else try l.b.add(.{ .op = .{ .extract = .{ .agg = value, .index = @intCast(i) } }, .ty = ec });
                        const idx = try l.b.constInt(try t.scalar(.uint), c);
                        try l.b.store(try l.b.add(.{ .op = .{ .access = .{ .base = base_ptr, .indices = try l.arena.dupe(Ref, &.{idx}) } }, .ty = ec, .ptr = .mesh }), part);
                    }
                    return;
                }
                var whole = try l.rvalue(m.base);
                const ec = try t.scalar(t.component(m.base.ty).?);
                for (comps, 0..) |c, i| {
                    const part = if (comps.len == 1) value else try l.b.add(.{ .op = .{ .extract = .{ .agg = value, .index = @intCast(i) } }, .ty = ec });
                    whole = try l.b.add(.{ .op = .{ .insert = .{ .agg = whole, .value = part, .index = c } }, .ty = m.base.ty });
                }
                return l.storeTo(m.base, whole);
            },
            else => {},
        }
        if (lhs.kind == .cast and t.get(lhs.ty) == .@"struct" and lhs.ty != lhs.kind.cast.operand.ty) {
            // `(Base)derived = v`: the base's fields are a prefix.
            const base_ptr = try l.lvalue(lhs.kind.cast.operand);
            const space = l.b.f.inst(base_ptr).ptr;
            for (t.get(lhs.ty).@"struct".fields.items, 0..) |fld, k| {
                const idx = try l.b.constInt(try t.scalar(.uint), @intCast(k));
                const p = try l.b.add(.{ .op = .{ .access = .{ .base = base_ptr, .indices = try l.arena.dupe(Ref, &.{idx}) } }, .ty = fld.type, .ptr = space });
                try l.b.store(p, try l.b.add(.{ .op = .{ .extract = .{ .agg = value, .index = @intCast(k) } }, .ty = fld.type }));
            }
            return;
        }
        try l.b.store(try l.lvalue(lhs), value);
    }

    // ------------------------------------------------------------------
    // Entry point

    /// Per-element modifiers that reach the signature.
    const SigAttrs = struct {
        interp: Interp = .{},
        row_major: bool = false,
        vk_location: ?u32 = null,
        vk_index: ?u32 = null,
        vk_builtin: ?[]const u8 = null,
        ext_decorations: []const ir.ExtDecoration = &.{},

        /// A field's modifiers, inheriting the enclosing interpolation.
        fn field(outer: SigAttrs, fld: Field) SigAttrs {
            const own: u8 = @bitCast(fld.interp);
            return .{ .interp = if (own != 0) fld.interp else outer.interp, .row_major = fld.row_major, .vk_location = fld.vk_location, .vk_index = fld.vk_index, .vk_builtin = fld.vk_builtin };
        }
    };

    fn withAttrs(el: ir.SigElement, attrs: SigAttrs) ir.SigElement {
        var r = el;
        r.interp = attrs.interp;
        r.row_major = attrs.row_major;
        r.vk_location = attrs.vk_location;
        r.vk_index = attrs.vk_index;
        r.vk_builtin = attrs.vk_builtin;
        r.ext_decorations = attrs.ext_decorations;
        return r;
    }

    /// A parameter's (or, with the function's attributes, the return
    /// value's) signature modifiers.
    fn sigAttrs(l: *Lowerer, q: ast.Qualifiers, attrs: []const ast.Attribute) SigAttrs {
        var a = paramAttrs(q);
        a.vk_location = l.s.vkAttrInt(attrs, "vk::location");
        a.vk_index = l.s.vkAttrInt(attrs, "vk::index");
        for (attrs) |at| if (std.mem.eql(u8, at.name, "vk::builtin") and at.args.len == 1 and at.args[0].kind == .string_lit) {
            const lit = at.args[0].kind.string_lit;
            a.vk_builtin = lit[1 .. lit.len - 1];
        };
        a.ext_decorations = (l.spirvExt(attrs) catch ir.SpirvExt{}).decorations;
        return a;
    }

    fn addInput(l: *Lowerer, entry: *ir.Entry, el: ir.SigElement) Error!Ref {
        if (l.patch_io) {
            try entry.patch_constants.append(l.arena, el);
            return l.b.add(.{ .op = .{ .patch_input = @intCast(entry.patch_constants.items.len - 1) }, .ty = el.ty });
        }
        try entry.inputs.append(l.arena, el);
        return l.b.add(.{ .op = .{ .input = @intCast(entry.inputs.items.len - 1) }, .ty = el.ty });
    }

    fn addOutput(l: *Lowerer, entry: *ir.Entry, el: ir.SigElement, value: Ref) Error!void {
        if (l.patch_io) {
            try entry.patch_constants.append(l.arena, el);
            _ = try l.b.add(.{ .op = .{ .patch_output = .{ .element = @intCast(entry.patch_constants.items.len - 1), .value = value } }, .ty = TypeTable.void_type });
            return;
        }
        try entry.outputs.append(l.arena, el);
        _ = try l.b.add(.{ .op = .{ .output = .{ .element = @intCast(entry.outputs.items.len - 1), .value = value } }, .ty = TypeTable.void_type });
    }

    /// An entry input of type `ty`: one signature element, or for structs
    /// without a semantic one per field (recursively).
    fn entryInput(l: *Lowerer, entry: *ir.Entry, ty: TypeId, semantic: ?[]const u8, attrs: SigAttrs, loc: ast.Loc, what: []const u8) Error!Ref {
        if (semantic) |sem| if (l.s.types.get(ty) == .@"struct") {
            // A semantic on a struct numbers its fields: X, X1, X2, ...
            var el = sigElement(sem, ty);
            return l.structInput(entry, ty, el.semantic, &el.semantic_index, attrs);
        };
        if (semantic) |sem| return l.addInput(entry, withAttrs(sigElement(sem, ty), attrs));
        switch (l.s.types.get(ty)) {
            .@"struct" => |st| {
                const parts = try l.arena.alloc(Ref, st.fields.items.len);
                for (parts, st.fields.items) |*p, fld| p.* = try l.entryInput(entry, fld.type, fld.semantic, attrs.field(fld), loc, fld.name);
                return l.b.add(.{ .op = .{ .construct = parts }, .ty = ty });
            },
            else => {
                l.unsupported(loc, "entry parameter '{s}' needs a semantic", .{what});
                return error.Unsupported;
            },
        }
    }

    fn structInput(l: *Lowerer, entry: *ir.Entry, ty: TypeId, name: []const u8, index: *u32, attrs: SigAttrs) Error!Ref {
        const st = l.s.types.get(ty).@"struct";
        const parts = try l.arena.alloc(Ref, st.fields.items.len);
        for (parts, st.fields.items) |*p, fld| {
            if (l.s.types.get(fld.type) == .@"struct") {
                p.* = try l.structInput(entry, fld.type, name, index, attrs.field(fld));
                continue;
            }
            p.* = try l.addInput(entry, withAttrs(.{ .semantic = name, .semantic_index = index.*, .ty = fld.type, .system_value = std.ascii.startsWithIgnoreCase(name, "SV_") }, attrs.field(fld)));
            index.* += 1;
        }
        return l.b.add(.{ .op = .{ .construct = parts }, .ty = ty });
    }

    fn structOutput(l: *Lowerer, entry: *ir.Entry, ty: TypeId, name: []const u8, index: *u32, value: Ref, attrs: SigAttrs) Error!void {
        const st = l.s.types.get(ty).@"struct";
        for (st.fields.items, 0..) |fld, k| {
            const v = try l.b.add(.{ .op = .{ .extract = .{ .agg = value, .index = @intCast(k) } }, .ty = fld.type });
            if (l.s.types.get(fld.type) == .@"struct") {
                try l.structOutput(entry, fld.type, name, index, v, attrs.field(fld));
                continue;
            }
            try l.addOutput(entry, withAttrs(.{ .semantic = name, .semantic_index = index.*, .ty = fld.type, .system_value = std.ascii.startsWithIgnoreCase(name, "SV_") }, attrs.field(fld)), v);
            index.* += 1;
        }
    }

    fn entryOutput(l: *Lowerer, entry: *ir.Entry, ty: TypeId, semantic: ?[]const u8, attrs: SigAttrs, value: Ref, loc: ast.Loc, what: []const u8) Error!void {
        if (semantic) |sem| if (l.s.types.get(ty) == .@"struct") {
            var el = sigElement(sem, ty);
            return l.structOutput(entry, ty, el.semantic, &el.semantic_index, value, attrs);
        };
        if (semantic) |sem| return l.addOutput(entry, withAttrs(sigElement(sem, ty), attrs), value);
        switch (l.s.types.get(ty)) {
            .@"struct" => |st| for (st.fields.items, 0..) |fld, k| {
                const v = try l.b.add(.{ .op = .{ .extract = .{ .agg = value, .index = @intCast(k) } }, .ty = fld.type });
                try l.entryOutput(entry, fld.type, fld.semantic, attrs.field(fld), v, loc, fld.name);
            },
            else => {
                l.unsupported(loc, "entry {s} needs a semantic", .{what});
                return error.Unsupported;
            },
        }
    }

    /// Lowers the initializers of the static globals the program uses,
    /// each into its own function (an initializer may use earlier statics,
    /// which then need initializing too). Returns them by global.
    fn staticInits(l: *Lowerer) Error!std.AutoHashMapUnmanaged(*const Variable, u32) {
        const inits = &l.inits;
        var changed = true;
        while (changed) {
            changed = false;
            for (l.s.static_globals.items) |v| {
                const init_e = v.init orelse continue;
                if (!l.globals.contains(v) or inits.contains(v)) continue;
                if (isObject(&l.s.types, v.type)) continue;
                const fi = try l.m.addFunction(.{ .name = try std.fmt.allocPrint(l.arena, "init.{s}", .{v.name}), .params = &.{}, .ret = v.type, .entry = l.cur_entry });
                try inits.put(l.arena, v, fi);
                l.b = .{ .m = &l.m, .f = l.m.functions.items[fi] };
                l.vars = .empty;
                l.loops = .empty;
                l.ret_ty = v.type;
                l.b.setBlock(try l.b.newBlock());
                const val = if (init_e.kind == .init_list) try l.initList(init_e, v.type) else try l.converted(init_e, v.type);
                l.b.terminate(.{ .ret = val });
                try l.drain();
                changed = true;
            }
        }
        return inits.*;
    }

    /// One leaf at a time of a signature value of type `ty`: registers
    /// elements into `list` (when non-null) or writes `value`'s leaves to
    /// consecutive output elements starting at `next`.
    fn streamOut(l: *Lowerer, list: ?*std.ArrayList(ir.SigElement), ty: TypeId, semantic: ?[]const u8, attrs: SigAttrs, value: ?Ref, next: *u32, stream: u32, numbered: ?*ir.SigElement, loc: ast.Loc) Error!void {
        const t = l.types();
        const leaf = struct {
            fn f(lw: *Lowerer, lst: ?*std.ArrayList(ir.SigElement), el: ir.SigElement, v: ?Ref, nx: *u32) Error!void {
                if (lst) |x| try x.append(lw.arena, el) else _ = try lw.b.add(.{ .op = .{ .output = .{ .element = nx.*, .value = v.? } }, .ty = TypeTable.void_type });
                nx.* += 1;
            }
        }.f;
        const part = struct {
            fn f(lw: *Lowerer, v: ?Ref, k: usize, fty: TypeId) Error!?Ref {
                return if (v) |x| try lw.b.add(.{ .op = .{ .extract = .{ .agg = x, .index = @intCast(k) } }, .ty = fty }) else null;
            }
        }.f;
        if (numbered) |num| {
            // A semantic on a struct numbers its leaves.
            if (t.get(ty) == .@"struct") {
                for (t.get(ty).@"struct".fields.items, 0..) |fld, k| try l.streamOut(list, fld.type, null, attrs.field(fld), try part(l, value, k, fld.type), next, stream, num, loc);
                return;
            }
            var el = withAttrs(.{ .semantic = num.semantic, .semantic_index = num.semantic_index, .ty = ty, .system_value = num.system_value }, attrs);
            el.stream = stream;
            num.semantic_index += 1;
            return leaf(l, list, el, value, next);
        }
        if (semantic) |sem| {
            var el = withAttrs(sigElement(sem, ty), attrs);
            el.stream = stream;
            if (t.get(ty) == .@"struct") return l.streamOut(list, ty, null, attrs, value, next, stream, &el, loc);
            return leaf(l, list, el, value, next);
        }
        if (t.get(ty) != .@"struct") {
            l.unsupported(loc, "stream output elements need semantics", .{});
            return error.Unsupported;
        }
        for (t.get(ty).@"struct".fields.items, 0..) |fld, k| try l.streamOut(list, fld.type, fld.semantic, attrs.field(fld), try part(l, value, k, fld.type), next, stream, null, loc);
    }

    /// Registers the output elements of each stream parameter of the entry
    /// (in parameter order, as dxc).
    fn registerStreams(l: *Lowerer, f: *const semamod.Function) Error!void {
        l.entry_fn = f;
        for (f.params, 0..) |p, i| {
            const st = switch (l.s.types.get(p.type)) {
                .stream => |st| st,
                else => continue,
            };
            const k: u32 = @intCast(l.streams.items.len);
            if (k >= 4) {
                l.unsupported(f.loc, "more than four streams", .{});
                return error.Unsupported;
            }
            var next: u32 = @intCast(l.early_outputs.items.len);
            const first = next;
            try l.streamOut(&l.early_outputs, st.elem, null, .{}, null, &next, k, null, f.decl.params[i].name_loc);
            try l.streams.append(l.arena, .{ .param = @intCast(i), .ty = st.elem, .first = first, .kind = st });
        }
    }

    /// `stream.Append(v)` / `stream.RestartStrip()`.
    fn streamMethod(l: *Lowerer, e: *ast.Expr, obj: *ast.Expr, name: []const u8, args: []const *ast.Expr) Error!Ref {
        if (l.streams.items.len == 0) return l.fail(e, "streams outside geometry shaders");
        // Which stream: the entry's stream parameter named, or the only one.
        var k: usize = 0;
        if (l.streams.items.len > 1) {
            const r = l.s.resolution(obj) orelse return l.fail(e, "this stream");
            const ef = l.entry_fn.?;
            k = for (l.streams.items, 0..) |sm, j| {
                if (r == .variable and sm.param < ef.param_vars.len and ef.param_vars[sm.param] == r.variable) break j;
            } else return l.fail(e, "selecting among several streams through a function parameter");
        }
        const sm = l.streams.items[k];
        if (std.mem.eql(u8, name, "Append")) {
            const v = try l.converted(args[0], sm.ty);
            var next = sm.first;
            try l.streamOut(null, sm.ty, null, .{}, v, &next, @intCast(k), null, e.loc);
            _ = try l.b.add(.{ .op = .{ .emit = @intCast(k) }, .ty = TypeTable.void_type });
        } else _ = try l.b.add(.{ .op = .{ .cut = @intCast(k) }, .ty = TypeTable.void_type });
        return .none;
    }

    /// A per-vertex input value of type `ty` for `vertex`, registering its
    /// elements when `register` (the first vertex).
    fn vertexIn(l: *Lowerer, entry: *ir.Entry, ty: TypeId, semantic: ?[]const u8, attrs: SigAttrs, vertex: u32, register: bool, next: *u32, numbered: ?*ir.SigElement, loc: ast.Loc) Error!Ref {
        const t = l.types();
        const leaf = struct {
            fn f(lw: *Lowerer, en: *ir.Entry, el: ir.SigElement, vx: u32, reg: bool, nx: *u32) Error!Ref {
                if (lw.vertex_from_outputs) {
                    const r = try lw.b.add(.{ .op = .{ .output_vertex = .{ .element = nx.*, .vertex = vx } }, .ty = el.ty });
                    nx.* += 1;
                    return r;
                }
                var e2 = el;
                e2.per_vertex = true;
                if (reg) try en.inputs.append(lw.arena, e2);
                const r = try lw.b.add(.{ .op = .{ .input_vertex = .{ .element = nx.*, .vertex = vx } }, .ty = el.ty });
                nx.* += 1;
                return r;
            }
        }.f;
        if (numbered) |num| {
            if (t.get(ty) == .@"struct") {
                const st = t.get(ty).@"struct";
                const parts = try l.arena.alloc(Ref, st.fields.items.len);
                for (parts, st.fields.items) |*p, fld| p.* = try l.vertexIn(entry, fld.type, null, attrs.field(fld), vertex, register, next, num, loc);
                return l.b.add(.{ .op = .{ .construct = parts }, .ty = ty });
            }
            const el = withAttrs(.{ .semantic = num.semantic, .semantic_index = num.semantic_index, .ty = ty, .system_value = num.system_value }, attrs);
            num.semantic_index += 1;
            return leaf(l, entry, el, vertex, register, next);
        }
        if (semantic) |sem| {
            var el = withAttrs(sigElement(sem, ty), attrs);
            if (t.get(ty) == .@"struct") return l.vertexIn(entry, ty, null, attrs, vertex, register, next, &el, loc);
            return leaf(l, entry, el, vertex, register, next);
        }
        if (t.get(ty) != .@"struct") {
            l.unsupported(loc, "per-vertex inputs need semantics", .{});
            return error.Unsupported;
        }
        const st = t.get(ty).@"struct";
        const parts = try l.arena.alloc(Ref, st.fields.items.len);
        for (parts, st.fields.items) |*p, fld| p.* = try l.vertexIn(entry, fld.type, fld.semantic, attrs.field(fld), vertex, register, next, null, loc);
        return l.b.add(.{ .op = .{ .construct = parts }, .ty = ty });
    }

    /// `value` (of struct `from`) as its base struct `to` (the leading
    /// fields).
    fn basePrefix(l: *Lowerer, value: Ref, from: TypeId, to: TypeId) Error!Ref {
        if (from == to) return value;
        const fields = l.s.types.get(to).@"struct".fields.items;
        const parts = try l.arena.alloc(Ref, fields.len);
        for (parts, fields, 0..) |*p, fld, k| p.* = try l.b.add(.{ .op = .{ .extract = .{ .agg = value, .index = @intCast(k) } }, .ty = fld.type });
        return l.b.add(.{ .op = .{ .construct = parts }, .ty = to });
    }

    /// `[domain(...)]`, `[partitioning(...)]` and the other hull / domain
    /// attributes.
    fn tessAttributes(l: *Lowerer, f: *const semamod.Function, entry: *ir.Entry) void {
        for (f.decl.attrs) |a| {
            const name = a.name;
            const eqi = std.ascii.eqlIgnoreCase;
            const str: []const u8 = if (a.args.len == 1 and a.args[0].kind == .string_lit) blk: {
                const lit = a.args[0].kind.string_lit;
                break :blk if (lit.len >= 2) lit[1 .. lit.len - 1] else lit;
            } else "";
            if (eqi(name, "domain")) {
                entry.tess.domain = std.meta.stringToEnum(ir.Domain, str) orelse entry.tess.domain;
            } else if (eqi(name, "partitioning")) {
                entry.tess.partitioning = std.meta.stringToEnum(ir.Partitioning, str) orelse entry.tess.partitioning;
            } else if (eqi(name, "outputtopology")) {
                entry.tess.output_topology = std.meta.stringToEnum(ir.OutputTopology, str) orelse entry.tess.output_topology;
            } else if (eqi(name, "outputcontrolpoints") and a.args.len == 1) {
                entry.tess.output_control_points = @intCast(@max(0, l.s.evalInt(a.args[0]) orelse 0));
            } else if (eqi(name, "maxtessfactor") and a.args.len == 1) {
                if (l.s.evalConst(a.args[0])) |c| entry.tess.max_tess_factor = switch (c) {
                    .float => |x| @floatCast(x),
                    .int => |x| @floatFromInt(x),
                    .bool => |x| @floatFromInt(@intFromBool(x)),
                };
            }
        }
    }

    /// Reads the control points of a patch parameter (registering their
    /// elements when `register`) and stores them into `local`.
    fn storeControlPoints(l: *Lowerer, entry: *ir.Entry, local: Ref, pty: TypeId, pd: ast.VarDecl, first: u32, register: bool) Error!void {
        const patch = l.s.types.get(pty).patch;
        if (!l.vertex_from_outputs) entry.tess.input_control_points = patch.count;
        const points = try l.arena.alloc(Ref, patch.count);
        for (points, 0..) |*v, k| {
            var next = first;
            v.* = try l.vertexIn(entry, patch.elem, semanticOf(pd.semantics), l.sigAttrs(pd.quals, pd.attrs), @intCast(k), register and k == 0, &next, null, pd.name_loc);
        }
        try l.b.store(local, try l.b.add(.{ .op = .{ .construct = points }, .ty = l.irType(pty) }));
    }

    fn writesTessFactor(l: *Lowerer, f: *const semamod.Function) bool {
        if (f.ret != TypeTable.void_type and l.hasTessFactor(f.ret, semanticOf(f.decl.ret_semantics))) return true;
        for (f.decl.params, f.params) |pd, p| {
            if (p.dir != .in and l.hasTessFactor(p.type, semanticOf(pd.semantics))) return true;
        }
        return false;
    }

    /// An SV_TessFactor array in `ty` (dxc's HasTessFactorSemanticRecurse).
    fn hasTessFactor(l: *Lowerer, ty: TypeId, semantic: ?[]const u8) bool {
        switch (l.s.types.get(ty)) {
            .@"struct" => |st| {
                for (st.fields.items) |fld| if (l.hasTessFactor(fld.type, fld.semantic)) return true;
                return false;
            },
            .array => {
                const sem = semantic orelse return false;
                return std.ascii.eqlIgnoreCase(sigElement(sem, ty).semantic, "SV_TessFactor");
            },
            else => return false,
        }
    }

    /// The hull shader's patch constant function, wrapped like the entry:
    /// reads control points (the entry's inputs and outputs), writes the
    /// patch constants.
    fn patchConstantWrapper(l: *Lowerer, f: *const semamod.Function, entry: *ir.Entry, cp_first: ?u32) Error!void {
        const name: []const u8 = for (f.decl.attrs) |a| {
            if (std.ascii.eqlIgnoreCase(a.name, "patchconstantfunc") and a.args.len == 1 and a.args[0].kind == .string_lit) {
                const lit = a.args[0].kind.string_lit;
                break if (lit.len >= 2) lit[1 .. lit.len - 1] else lit;
            }
        } else {
            l.unsupported(f.loc, "hull shader without a patch constant function", .{});
            return error.Unsupported;
        };
        // Among overloads, the one that can be a patch constant function
        // (writes a tess factor array), as dxc.
        const pcf = for (l.s.all_functions.items) |g| {
            if (g.owner == null and g.defined and std.mem.eql(u8, g.name, name) and l.writesTessFactor(g)) break g;
        } else {
            l.unsupported(f.loc, "patch constant function '{s}' has no definition", .{name});
            return error.Unsupported;
        };
        const pci = try l.functionIndex(pcf);
        entry.patch_func = pci;
        try l.drain();
        const wrapper = try l.m.addFunction(.{ .name = try std.fmt.allocPrint(l.arena, "{s}.wrapper", .{name}), .params = &.{}, .ret = TypeTable.void_type, .entry = l.cur_entry });
        l.b = .{ .m = &l.m, .f = l.m.functions.items[wrapper] };
        l.b.setBlock(try l.b.newBlock());
        const args = try l.arena.alloc(Ref, pcf.params.len);
        const locals = try l.arena.alloc(Ref, pcf.params.len);
        for (pcf.decl.params, pcf.params, 0..) |pd, p, i| {
            locals[i] = try l.b.add(.{ .op = .local_var, .ty = l.irType(p.type), .ptr = .function });
            if (l.s.types.get(p.type) == .patch) {
                if (l.s.types.get(p.type).patch.output) {
                    // The entry's output control points, read back.
                    l.vertex_from_outputs = true;
                    defer l.vertex_from_outputs = false;
                    try l.storeControlPoints(entry, locals[i], p.type, pd, 0, false);
                } else {
                    const first = cp_first orelse @as(u32, @intCast(entry.inputs.items.len));
                    try l.storeControlPoints(entry, locals[i], p.type, pd, first, cp_first == null);
                }
                args[i] = try l.b.load(locals[i]);
                continue;
            }
            if (p.dir != .out) try l.b.store(locals[i], try l.entryInput(entry, p.type, semanticOf(pd.semantics), l.sigAttrs(pd.quals, pd.attrs), pd.name_loc, pd.name));
            args[i] = if (p.dir == .in) try l.b.load(locals[i]) else locals[i];
        }
        const ret = try l.b.add(.{ .op = .{ .call = .{ .func = pci, .args = args } }, .ty = pcf.ret });
        l.patch_io = true;
        defer l.patch_io = false;
        if (pcf.ret != TypeTable.void_type) try l.entryOutput(entry, pcf.ret, semanticOf(pcf.decl.ret_semantics), paramAttrs(pcf.decl.quals), ret, pcf.loc, "return value");
        for (pcf.decl.params, pcf.params, 0..) |pd, p, i| {
            if (p.dir == .in) continue;
            try l.entryOutput(entry, p.type, semanticOf(pd.semantics), l.sigAttrs(pd.quals, pd.attrs), try l.b.load(locals[i]), pd.name_loc, pd.name);
        }
        l.b.terminate(.{ .ret = .none });
        entry.patch_wrapper = wrapper;
    }

    fn buildEntry(l: *Lowerer, f: *const semamod.Function, main: u32, opts: Options) Error!void {
        const inits = try l.staticInits();
        var entry: ir.Entry = .{ .func = main, .name = opts.entry, .stage = opts.stage, .ext = try l.spirvExt(f.decl.attrs) };
        entry.outputs = l.early_outputs;
        for (f.decl.attrs) |a| {
            if (std.ascii.eqlIgnoreCase(a.name, "numthreads") and a.args.len == 3) {
                for (a.args, 0..) |arg, i| entry.num_threads[i] = @intCast(@max(1, l.s.evalInt(arg) orelse 1));
            }
            if (std.ascii.eqlIgnoreCase(a.name, "maxvertexcount") and a.args.len == 1) entry.geometry.max_vertex_count = @intCast(@max(1, l.s.evalInt(a.args[0]) orelse 1));
            if (std.ascii.eqlIgnoreCase(a.name, "instance") and a.args.len == 1) entry.geometry.instance_count = @intCast(@max(1, l.s.evalInt(a.args[0]) orelse 1));
            if (std.ascii.eqlIgnoreCase(a.name, "RootSignature") and a.args.len == 1 and a.args[0].kind == .string_lit) entry.root_signature = try stringContents(l.arena, a.args[0].kind.string_lit);
        }
        for (l.streams.items, 0..) |sm, k| entry.geometry.streams[k] = switch (sm.kind.kind) {
            .point => .point,
            .line => .line,
            .triangle => .triangle,
        };
        const wrapper = try l.m.addFunction(.{ .name = opts.entry, .params = &.{}, .ret = TypeTable.void_type, .entry = l.cur_entry });
        l.b = .{ .m = &l.m, .f = l.m.functions.items[wrapper] };
        l.b.setBlock(try l.b.newBlock());
        for (l.s.static_globals.items) |v| if (inits.get(v)) |fi| {
            const g = l.globals.get(v).?;
            const glob = l.m.globals.items[g];
            const ptr = try l.b.add(.{ .op = .{ .global = g }, .ty = glob.ty, .ptr = glob.space });
            try l.b.store(ptr, try l.b.add(.{ .op = .{ .call = .{ .func = fi, .args = &.{} } }, .ty = v.type }));
        };
        const args = try l.arena.alloc(Ref, f.params.len);
        const locals = try l.arena.alloc(Ref, f.params.len);
        const ray_srcs = try l.arena.alloc(Ref, f.params.len);
        @memset(ray_srcs, .none);
        var n_args: usize = 0;
        if (opts.stage == .mesh) for (f.decl.attrs) |a| {
            if (std.ascii.eqlIgnoreCase(a.name, "outputtopology") and a.args.len == 1 and a.args[0].kind == .string_lit) {
                if (std.mem.indexOf(u8, a.args[0].kind.string_lit, "line") != null) entry.mesh.topology = .line;
            }
        };
        if (opts.stage == .amplification) entry.mesh.payload = l.mesh_payload;
        const tess = opts.stage == .hull or opts.stage == .domain;
        if (tess) l.tessAttributes(f, &entry);
        // Hull shaders: where the control point inputs start.
        var cp_first: ?u32 = null;
        for (f.decl.params, f.params, 0..) |pd, p, i| {
            if (l.s.types.get(p.type) == .stream) continue;
            n_args += 1;
            const q = pd.quals;
            if (opts.stage == .mesh and (q.vertices or q.indices or q.primitives) and l.s.types.get(p.type) == .array) {
                // Output arrays: stores through them write the outputs.
                const arr = l.s.types.get(p.type).array;
                const kind: ir.MeshOutput = if (q.vertices) .vertices else if (q.primitives) .primitives else .indices;
                switch (kind) {
                    .vertices => {
                        entry.mesh.max_vertices = arr.len;
                        var next: u32 = @intCast(entry.outputs.items.len);
                        try l.streamOut(&entry.outputs, arr.elem, semanticOf(pd.semantics), l.sigAttrs(q, pd.attrs), null, &next, 0, null, pd.name_loc);
                    },
                    .primitives => {
                        entry.mesh.max_primitives = arr.len;
                        var next: u32 = @intCast(entry.patch_constants.items.len);
                        try l.streamOut(&entry.patch_constants, arr.elem, semanticOf(pd.semantics), l.sigAttrs(q, pd.attrs), null, &next, 0, null, pd.name_loc);
                    },
                    .indices => {
                        entry.mesh.max_primitives = arr.len;
                        if (l.s.types.get(arr.elem) == .vector and l.s.types.get(arr.elem).vector.len == 2) entry.mesh.topology = .line;
                    },
                }
                locals[i] = try l.b.add(.{ .op = .{ .mesh_output = kind }, .ty = p.type, .ptr = .mesh });
                args[i] = locals[i];
                continue;
            }
            locals[i] = try l.b.add(.{ .op = .local_var, .ty = l.irType(p.type), .ptr = .function });
            if (opts.stage == .mesh and q.payload) {
                entry.mesh.payload = p.type;
                try l.b.store(locals[i], try l.b.add(.{ .op = .mesh_payload, .ty = p.type }));
                args[i] = try l.b.load(locals[i]);
                continue;
            }
            if (tess and l.s.types.get(p.type) == .patch) {
                // Control points: one value per point of the patch.
                const first: u32 = @intCast(entry.inputs.items.len);
                cp_first = first;
                try l.storeControlPoints(&entry, locals[i], p.type, pd, first, true);
                args[i] = try l.b.load(locals[i]);
                continue;
            }
            if (opts.stage == .domain and p.dir != .out) {
                // Everything else a domain shader reads is per patch.
                l.patch_io = true;
                defer l.patch_io = false;
                try l.b.store(locals[i], try l.entryInput(&entry, p.type, semanticOf(pd.semantics), l.sigAttrs(pd.quals, pd.attrs), pd.name_loc, pd.name));
                args[i] = if (p.dir == .in) try l.b.load(locals[i]) else locals[i];
                continue;
            }
            if (opts.stage == .geometry and (q.point or q.line or q.triangle or q.lineadj or q.triangleadj) and l.s.types.get(p.type) == .array) {
                // Per-vertex inputs: one value per vertex of the primitive.
                const arr = l.s.types.get(p.type).array;
                entry.geometry.input = if (q.point) .point else if (q.line) .line else if (q.triangle) .triangle else if (q.lineadj) .line_adj else .triangle_adj;
                entry.geometry.input_vertices = arr.len;
                const first: u32 = @intCast(entry.inputs.items.len);
                const verts = try l.arena.alloc(Ref, arr.len);
                for (verts, 0..) |*v, vx| {
                    var next = first;
                    v.* = try l.vertexIn(&entry, arr.elem, semanticOf(pd.semantics), l.sigAttrs(pd.quals, pd.attrs), @intCast(vx), vx == 0, &next, null, pd.name_loc);
                }
                try l.b.store(locals[i], try l.b.add(.{ .op = .{ .construct = verts }, .ty = p.type }));
                args[i] = try l.b.load(locals[i]);
                continue;
            }
            if (opts.stage.isRayTracing()) {
                // Payload, hit attributes or callable data: copied in from
                // (and inout ones back to) the shader's incoming storage.
                const kind: ir.RayIncoming = if (opts.stage == .callable) .callable else if (i == 0) .payload else .attributes;
                ray_srcs[i] = try l.b.add(.{ .op = .{ .ray_incoming = kind }, .ty = p.type, .ptr = .ray });
                try l.b.store(locals[i], try l.b.load(ray_srcs[i]));
                args[i] = if (p.dir == .in) try l.b.load(locals[i]) else locals[i];
                continue;
            }
            if (p.dir != .out) {
                const v = try l.entryInput(&entry, p.type, semanticOf(pd.semantics), l.sigAttrs(pd.quals, pd.attrs), pd.name_loc, pd.name);
                try l.b.store(locals[i], v);
            }
            args[i] = if (p.dir == .in) try l.b.load(locals[i]) else locals[i];
        }
        var call_args: std.ArrayList(Ref) = .empty;
        for (f.params, 0..) |p, i| if (l.s.types.get(p.type) != .stream) try call_args.append(l.arena, args[i]);
        std.debug.assert(call_args.items.len == n_args);
        const ret = try l.b.add(.{ .op = .{ .call = .{ .func = main, .args = call_args.items } }, .ty = f.ret });
        if (f.ret != TypeTable.void_type) try l.entryOutput(&entry, f.ret, semanticOf(f.decl.ret_semantics), l.sigAttrs(f.decl.quals, f.decl.attrs), ret, f.loc, "return value");
        for (f.decl.params, f.params, 0..) |pd, p, i| {
            if (p.dir == .in or l.s.types.get(p.type) == .stream) continue;
            if (l.b.f.inst(locals[i]).ptr == .mesh) continue;
            const v = try l.b.load(locals[i]);
            if (ray_srcs[i] != .none) {
                try l.b.store(ray_srcs[i], v);
                continue;
            }
            try l.entryOutput(&entry, p.type, semanticOf(pd.semantics), l.sigAttrs(pd.quals, pd.attrs), v, pd.name_loc, pd.name);
        }
        l.b.terminate(.{ .ret = .none });
        entry.wrapper = wrapper;
        if (opts.stage == .mesh) {
            // Vertex and primitive outputs are arrays.
            for (entry.outputs.items) |*el| el.per_vertex = true;
            for (entry.patch_constants.items) |*el| el.per_vertex = true;
        }
        if (opts.stage == .hull) {
            // Output control points are arrays over the patch.
            for (entry.outputs.items) |*el| el.per_vertex = true;
            try l.patchConstantWrapper(f, &entry, cp_first);
        }
        // The HLSL entry keeps its name with a prefix (as dxc's SPIR-V).
        l.m.functions.items[main].name = try std.fmt.allocPrint(l.arena, "src.{s}", .{opts.entry});
        try l.m.entries.append(l.arena, entry);
    }
};

/// Float to integer for constants: truncates toward zero, saturating out of
/// range (NaN gives 0).
pub fn saturatingInt(f: f64) i64 {
    if (std.math.isNan(f)) return 0;
    if (f >= 9.2233720368547758e18) return std.math.maxInt(i64);
    if (f <= -9.2233720368547758e18) return std.math.minInt(i64);
    return @intFromFloat(@trunc(f));
}

/// Non-static member functions take their object as a hidden first
/// parameter.
/// (dxc's SPIR-V supports textures and samplers in global structs, not
/// buffers.)
fn structHoldsBuffer(t: *const TypeTable, ty: TypeId) bool {
    return switch (t.get(ty)) {
        .resource => |r| switch (r.kind) {
            .buffer, .rw_buffer, .byte_address_buffer, .rw_byte_address_buffer, .structured_buffer, .rw_structured_buffer, .append_structured_buffer, .consume_structured_buffer, .constant_buffer, .texture_buffer => true,
            else => false,
        },
        .array => |a| structHoldsBuffer(t, a.elem),
        .@"struct" => |st| for (st.fields.items) |f| {
            if (structHoldsBuffer(t, f.type)) break true;
        } else false,
        else => false,
    };
}

fn isResourceLike(t: *const TypeTable, ty: TypeId) bool {
    return switch (t.get(ty)) {
        .resource, .sampler => true,
        else => false,
    };
}

/// A struct or array with a resource in it.
fn holdsResources(t: *const TypeTable, ty: TypeId) bool {
    return switch (t.get(ty)) {
        .array => |a| isResourceLike(t, a.elem) or holdsResources(t, a.elem),
        .@"struct" => |st| for (st.fields.items) |f| {
            if (isResourceLike(t, f.type) or holdsResources(t, f.type)) break true;
        } else false,
        else => false,
    };
}

/// Leaves of an initializer list for `ty` (components, and resources).
fn flatLength(t: *const TypeTable, ty: TypeId) ?u32 {
    return switch (t.get(ty)) {
        .resource, .sampler => 1,
        .array => |a| if (flatLength(t, a.elem)) |n| n * a.len else null,
        .@"struct" => |st| blk: {
            var n: u32 = 0;
            for (st.fields.items, 0..) |f, i| {
                if (f.bits) {
                    n += @intCast(st.bitfieldsIn(@intCast(i)).len);
                } else n += flatLength(t, f.type) orelse break :blk null;
            }
            break :blk n;
        },
        else => t.componentCount(ty),
    };
}

/// Integer (and enum) `static const` values are folded to constants.
fn isIntConstantType(t: *const TypeTable, ty: TypeId) bool {
    return switch (t.get(ty)) {
        .scalar => |sc| !sc.isFloat(),
        .@"enum" => true,
        else => false,
    };
}

/// `vk::SpirvOpaqueType<OpTypePointer, ...>` (WorkgroupSpirvPointer).
fn isSpirvPointer(t: *const TypeTable, ty: TypeId) bool {
    return t.get(ty) == .spirv and t.get(ty).spirv.opcode == 32;
}

fn isMethod(f: *const semamod.Function) bool {
    return f.owner != null and !f.decl.quals.static;
}

/// The characters of a string literal (quotes removed, escapes
/// resolved).
pub fn stringContents(a: Allocator, lit: []const u8) Allocator.Error![]const u8 {
    const body = if (lit.len >= 2 and lit[0] == '"') lit[1 .. lit.len - 1] else lit;
    if (std.mem.indexOfScalar(u8, body, '\\') == null) return body;
    var out: std.ArrayList(u8) = .empty;
    var k: usize = 0;
    while (k < body.len) : (k += 1) {
        if (body[k] != '\\' or k + 1 == body.len) {
            try out.append(a, body[k]);
            continue;
        }
        k += 1;
        try out.append(a, switch (body[k]) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            '0' => 0,
            else => body[k],
        });
    }
    return out.items;
}

/// A constant buffer member's `packoffset(cN.x)` / `register(cN)` offset
/// in bytes.
fn packOffset(v: *const Variable) ?u32 {
    const d = v.decl orelse return null;
    for (d.semantics) |sem| {
        if (sem.kind != .packoffset and sem.kind != .register) continue;
        if (sem.values.len == 0) continue;
        const text = sem.values[0];
        if (text.len < 2 or std.ascii.toLower(text[0]) != 'c') continue;
        const dot = std.mem.indexOfScalar(u8, text, '.') orelse text.len;
        const reg = std.fmt.parseInt(u32, text[1..dot], 10) catch continue;
        var comp: u32 = 0;
        if (dot + 1 < text.len) comp = switch (text[dot + 1]) {
            'y', 'g' => 1,
            'z', 'b' => 2,
            'w', 'a' => 3,
            else => 0,
        };
        return reg * 16 + comp * 4;
    }
    return null;
}

/// The SPIR-V ImageFormat a `[[vk::image_format]]` names.
fn imageFormatNamed(name: ?[]const u8) ?u32 {
    const n = name orelse return null;
    const names = [_][]const u8{
        "unknown",     "rgba32f",     "rgba16f",   "r32f",       "rgba8",      "rgba8snorm",  "rg32f",    "rg16f",
        "r11g11b10f",  "r16f",        "rgba16",    "rgb10a2",    "rg16",       "rg8",         "r16",      "r8",
        "rgba16snorm", "rg16snorm",   "rg8snorm",  "r16snorm",   "r8snorm",    "rgba32i",     "rgba16i",  "rgba8i",
        "r32i",        "rg32i",       "rg16i",     "rg8i",       "r16i",       "r8i",         "rgba32ui", "rgba16ui",
        "rgba8ui",     "r32ui",       "rgb10a2ui", "rg32ui",     "rg16ui",     "rg8ui",       "r16ui",    "r8ui",
        "r64ui",       "r64i",
    };
    for (names, 0..) |x, k| if (std.ascii.eqlIgnoreCase(x, n)) return @intCast(k);
    return null;
}

fn hasAttr(attrs: []const ast.Attribute, name: []const u8) bool {
    for (attrs) |a| if (std.mem.eql(u8, a.name, name)) return true;
    return false;
}

fn isShaderRecord(attrs: []const ast.Attribute) bool {
    for (attrs) |a| {
        if (std.mem.eql(u8, a.name, "vk::shader_record_ext") or std.mem.eql(u8, a.name, "vk::shader_record_nv")) return true;
    }
    return false;
}

/// RayQuery objects: stateful, they live in function storage.
pub fn isRayQuery(t: *TypeTable, ty: TypeId) bool {
    return switch (t.get(ty)) {
        .resource => |r| r.kind == .other and std.mem.eql(u8, r.name, "RayQuery"),
        else => false,
    };
}

/// Resources, samplers and arrays of them.
pub fn isObject(t: *TypeTable, ty: TypeId) bool {
    return switch (t.get(ty)) {
        .resource, .sampler => true,
        .array => |a| isObject(t, a.elem),
        else => false,
    };
}

fn paramAttrs(q: ast.Qualifiers) Lowerer.SigAttrs {
    return .{ .interp = semamod.interpOf(q), .row_major = q.row_major };
}

fn semanticOf(sems: []const ast.Semantic) ?[]const u8 {
    for (sems) |sem| if (sem.kind == .semantic) return sem.values[0];
    return null;
}

/// `SV_Target1` -> name `SV_Target`, index 1.
fn sigElement(semantic: []const u8, ty: TypeId) ir.SigElement {
    var end = semantic.len;
    while (end > 0 and std.ascii.isDigit(semantic[end - 1])) end -= 1;
    const index = std.fmt.parseInt(u32, semantic[end..], 10) catch 0;
    return .{
        .semantic = semantic[0..end],
        .semantic_index = index,
        .ty = ty,
        .system_value = std.ascii.startsWithIgnoreCase(semantic, "SV_"),
        .spelling = semantic,
    };
}

/// `register(t3, space1)` -> class 't', index 3, space 1.
fn parseBinding(values: []const []const u8) ir.Binding {
    var b: ir.Binding = .{};
    for (values) |v| {
        if (std.mem.startsWith(u8, v, "space")) {
            b.space = std.fmt.parseInt(u32, v[5..], 10) catch 0;
            b.space_given = true;
        } else if (v.len > 0 and std.mem.indexOfScalar(u8, "bcistu", std.ascii.toLower(v[0])) != null) {
            const end = std.mem.indexOfScalar(u8, v, '[') orelse v.len;
            b.class = std.ascii.toLower(v[0]);
            b.index = std.fmt.parseInt(u32, v[1..end], 10) catch 0;
            b.explicit = true;
        }
    }
    return b;
}

/// `xyzw` / `rgba` swizzle -> component indices.
fn swizzleComponents(a: Allocator, name: []const u8) Allocator.Error!?[]const u8 {
    if (name.len == 0 or name.len > 4) return null;
    const out = try a.alloc(u8, name.len);
    for (name, out) |c, *o| {
        o.* = switch (c) {
            'x', 'r' => 0,
            'y', 'g' => 1,
            'z', 'b' => 2,
            'w', 'a' => 3,
            else => return null,
        };
    }
    return out;
}

/// `_m01_m10` (zero-based) or `_12_21` (one-based) -> row-major component
/// indices.
fn matrixSwizzle(a: Allocator, name: []const u8, cols: u8) ?[]const u32 {
    var out: std.ArrayList(u32) = .empty;
    var i: usize = 0;
    while (i < name.len) {
        if (name[i] != '_') return null;
        i += 1;
        var zero = false;
        if (i < name.len and name[i] == 'm') {
            zero = true;
            i += 1;
        }
        if (i + 2 > name.len) return null;
        var r: u32 = name[i] -% '0';
        var c: u32 = name[i + 1] -% '0';
        if (!zero) {
            r -%= 1;
            c -%= 1;
        }
        if (r > 3 or c > 3) return null;
        out.append(a, r * cols + c) catch return null;
        i += 2;
    }
    return if (out.items.len == 0) null else out.items;
}

fn lowMask(width: u8) u64 {
    return if (width >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(width)) - 1;
}

/// `v`'s low `bits` bits as a sign-extended constant (ir.Constant.int).
fn signExtend(v: u64, bits: u8) i64 {
    if (bits >= 64) return @bitCast(v);
    const sh: u6 = @intCast(64 - bits);
    return @as(i64, @bitCast(v << sh)) >> sh;
}

/// Whether `e` designates storage (a variable, or a part of one) rather
/// than a temporary such as an operator call's result.
fn isAddressable(s: *const Sema, e: *const ast.Expr) bool {
    return switch (e.kind) {
        .name, .this => true,
        .member => |m| isAddressable(s, m.base),
        .index => |x| if (s.resolution(e)) |r| r != .function and isAddressable(s, x.base) else isAddressable(s, x.base),
        else => false,
    };
}

fn flattenList(a: Allocator, e: *ast.Expr, out: *std.ArrayList(*ast.Expr)) Allocator.Error!void {
    if (e.kind == .init_list) {
        for (e.kind.init_list) |item| try flattenList(a, item, out);
    } else try out.append(a, e);
}
