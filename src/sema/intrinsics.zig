//! Intrinsic and builtin-method overload resolution against the table
//! generated from dxc's gen_intrin_main.txt.
//!
//! Each declaration's types are indexed 0 (return) .. n (parameters).
//! `$match<L, C>` links a type's layout to type L and its component to
//! type C (`$typeN` = `$match<N, N>`); unlinked types are their own group.
//! For each group the component is the common type of its arguments,
//! coerced into the group's class (`float_like`, `numeric`, `any_int`...),
//! and the layout is taken from the declared dimensions (binding symbolic
//! sizes like `c` and `r2` across arguments) or, for `<>`, from the
//! arguments. Candidates are ranked by total conversion cost.

const std = @import("std");
const Allocator = std.mem.Allocator;
const table = @import("intrinsics_table");
const types = @import("types.zig");
const source = @import("../front/source.zig");
const TypeId = types.TypeId;
const TypeTable = types.TypeTable;
const Scalar = types.Scalar;

pub const ArgInfo = struct {
    ty: TypeId,
    /// Assignable (for out / inout parameters).
    lvalue: bool,
    loc: source.Loc,
    /// Names (part of) a groupshared variable.
    groupshared: bool = false,
};

pub const Db = struct {
    /// "Namespace::name" -> indices into table.intrinsics.
    by_name: std.StringHashMapUnmanaged(std.ArrayList(u16)) = .empty,
    /// Plain intrinsic names (Intrinsics / VkIntrinsics / DxIntrinsics).
    globals: std.StringHashMapUnmanaged(void) = .empty,
    vk_globals: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(a: Allocator) !Db {
        var db: Db = .{};
        for (table.intrinsics, 0..) |it, i| {
            const key = try std.fmt.allocPrint(a, "{s}::{s}", .{ it.namespace, it.name });
            const gop = try db.by_name.getOrPut(a, key);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(a, @intCast(i));
            if (std.mem.eql(u8, it.namespace, "Intrinsics") or std.mem.eql(u8, it.namespace, "DxIntrinsics")) try db.globals.put(a, it.name, {});
            if (std.mem.eql(u8, it.namespace, "VkIntrinsics")) try db.vk_globals.put(a, it.name, {});
        }
        return db;
    }

    /// `ns` (e.g. `Texture2DMethods`) declares a method `name`.
    pub fn hasMethod(db: *const Db, ns: []const u8, name: []const u8) bool {
        var buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}::{s}", .{ ns, name }) catch return true;
        return db.by_name.contains(key);
    }

    pub fn has(db: *const Db, name: []const u8, spirv: bool) bool {
        return db.globals.contains(name) or (spirv and db.vk_globals.contains(name));
    }

    fn candidates(db: *const Db, a: Allocator, ns: []const u8, name: []const u8) ![]const u16 {
        var list: std.ArrayList(u16) = .empty;
        const namespaces: []const []const u8 = if (std.mem.eql(u8, ns, "Intrinsics")) &.{ "Intrinsics", "DxIntrinsics" } else &.{ns};
        for (namespaces) |n| {
            const key = try std.fmt.allocPrint(a, "{s}::{s}", .{ n, name });
            if (db.by_name.get(key)) |l| try list.appendSlice(a, l.items);
        }
        return list.items;
    }

    /// Resolve a call; reports a diagnostic and returns the error type when
    /// no overload matches. `sema` is the calling Sema (for conversions and
    /// diagnostics); `object` is the method's object type, if any.
    /// A resolved intrinsic call: the table entry and its concrete
    /// parameter types (the argument's type where the table leaves a
    /// parameter unconstrained).
    pub const Resolved = struct { ret: TypeId, index: u16 = 0, params: []const TypeId = &.{}, ok: bool = false };

    pub fn resolve(db: *const Db, sema: anytype, loc: source.Loc, ns: []const u8, name: []const u8, object: ?TypeId, args: []const ArgInfo, explicit: ?TypeId) !Resolved {
        const cands = try db.candidates(sema.arena, ns, name);
        if (cands.len == 0) {
            if (object) |o| {
                sema.err(loc, "no member named '{s}' in '{s}'", .{ name, sema.typeName(o) });
            } else sema.err(loc, "use of undeclared identifier '{s}'", .{name});
            return .{ .ret = TypeTable.error_type };
        }
        var best: ?Match = null;
        for (cands) |ci| {
            var m = try matchOne(sema, &table.intrinsics[ci], object, args, explicit) orelse continue;
            m.index = ci;
            if (best == null or m.cost < best.?.cost) best = m;
        }
        // vk::static_pointer_cast / reinterpret_pointer_cast return a
        // BufferPointer of the template argument: not modelled yet.
        if (best != null and (std.mem.eql(u8, name, "static_pointer_cast") or std.mem.eql(u8, name, "reinterpret_pointer_cast"))) return .{ .ret = TypeTable.error_type };
        const m = best orelse {
            sema.err(loc, "no matching function for call to '{s}'", .{name});
            return .{ .ret = TypeTable.error_type };
        };
        for (args, 0..) |a, i| {
            if (i < m.out_params.len and m.out_params[i] and !a.lvalue) {
                sema.err(a.loc, "cannot bind non-lvalue argument to out parameter", .{});
            }
        }
        return .{ .ret = m.ret, .index = m.index, .params = m.params, .ok = true };
    }
};

const Match = struct {
    ret: TypeId,
    cost: u32,
    out_params: []const bool,
    index: u16 = 0,
    params: []const TypeId = &.{},
};

const Layout = struct { rows: u8, cols: u8, kind: TypeTable.Shape };

/// Symbolic dimension bindings (`r`, `c`, `r2`, `c2`, ...).
const Bindings = struct {
    names: [8][]const u8 = undefined,
    values: [8]u8 = undefined,
    n: usize = 0,
    /// The widest shape of the arguments declared `<>`: all such types of
    /// an intrinsic share their dimensions (dxc's r / c), scalars
    /// splatting to the widest.
    any_shape: ?TypeTable.Shape = null,

    fn get(b: *const Bindings, name: []const u8) ?u8 {
        for (b.names[0..b.n], b.values[0..b.n]) |k, v| if (std.mem.eql(u8, k, name)) return v;
        return null;
    }

    /// Bind or check; false on conflict.
    fn bind(b: *Bindings, name: []const u8, v: u8) bool {
        if (b.get(name)) |old| return old == v;
        if (b.n == b.names.len) return false;
        b.names[b.n] = name;
        b.values[b.n] = v;
        b.n += 1;
        return true;
    }
};

fn matchOne(sema: anytype, it: *const table.Intrinsic, object: ?TypeId, args: []const ArgInfo, explicit: ?TypeId) !?Match {
    const t = &sema.types;
    if (args.len < it.params.len) return null;
    if (args.len > it.params.len and !it.varargs) return null;
    const n = it.params.len + 1;
    const specs = try sema.arena.alloc(*const table.Spec, n);
    specs[0] = &it.ret;
    for (it.params, 1..) |*p, i| specs[i] = p;

    const obj_elem: TypeId = if (object) |o| switch (t.get(o)) {
        .resource => |r| r.elem,
        .stream => |s| s.elem,
        .patch => |p| p.elem,
        else => TypeTable.error_type,
    } else TypeTable.error_type;

    // Groups: index of the type that owns a type's layout / component.
    const comp_group = try sema.arena.alloc(usize, n);
    const layout_group = try sema.arena.alloc(usize, n);
    for (specs, 0..) |s, i| {
        comp_group[i] = i;
        layout_group[i] = i;
        if (s.special == .type_n) {
            comp_group[i] = s.type_n;
            layout_group[i] = s.type_n;
        } else {
            if (s.match_comp) |c| if (c >= 0 and c < n) {
                comp_group[i] = @intCast(c);
            };
            if (s.match_layout) |l| if (l >= 0 and l < n) {
                layout_group[i] = @intCast(l);
            };
        }
    }

    // Components: common type of the arguments in each group.
    const group_comp = try sema.arena.alloc(?Scalar, n);
    @memset(group_comp, null);
    for (args[0..it.params.len], 1..) |a, i| {
        const g = comp_group[i];
        const c = t.component(a.ty) orelse continue;
        group_comp[g] = if (group_comp[g]) |old| common(old, c) else c;
    }

    var bindings: Bindings = .{};
    for (args[0..it.params.len], 1..) |a, i| {
        if (!specs[i].any_layout) continue;
        const sh = t.shape(a.ty) orelse continue;
        if (bindings.any_shape == null or sh.count() > bindings.any_shape.?.count()) bindings.any_shape = sh;
    }
    var cost: u32 = 0;
    const out_params = try sema.arena.alloc(bool, args.len);
    @memset(out_params, false);
    const param_types = try sema.arena.alloc(TypeId, args.len);

    // Parameter types, checked against the arguments.
    for (args, 0..) |a, ai| {
        if (ai >= it.params.len) break; // varargs: anything goes
        const i = ai + 1;
        const s = specs[i];
        out_params[ai] = s.qual == .out or s.qual == .inout or s.qual == .ref;
        const pt = try paramType(sema, specs, i, comp_group, layout_group, group_comp, &bindings, args, obj_elem, explicit) orelse return null;
        param_types[ai] = if (pt == TypeTable.error_type) a.ty else pt;
        if (pt == TypeTable.error_type) continue; // unconstrained object / unknown class
        const c = sema.conversionCost(a.ty, pt) orelse return null;
        cost += c;
    }

    // Return type.
    const ret = try paramType(sema, specs, 0, comp_group, layout_group, group_comp, &bindings, args, obj_elem, explicit) orelse return null;
    for (args[@min(args.len, it.params.len)..], @min(args.len, it.params.len)..) |a, ai| param_types[ai] = a.ty; // varargs
    return .{ .ret = ret, .cost = cost, .out_params = out_params, .params = param_types };
}

/// The concrete type of spec `i`, or null if the arguments cannot fit.
/// Returns the error type for types zdxc does not constrain (objects,
/// strings, classes it does not model).
fn paramType(
    sema: anytype,
    specs: []const *const table.Spec,
    i: usize,
    comp_group: []const usize,
    layout_group: []const usize,
    group_comp: []const ?Scalar,
    bindings: *Bindings,
    args: []const ArgInfo,
    obj_elem: TypeId,
    explicit: ?TypeId,
) !?TypeId {
    const t = &sema.types;
    const s = specs[i];
    switch (s.special) {
        .class_t => return obj_elem,
        // `$funcT`: the explicit template argument; without one, a return
        // defaults to uint (ByteAddressBuffer.Load) and a parameter is
        // unconstrained (Store of a struct).
        .func_t => return explicit orelse if (i == 0) try t.scalar(.uint) else TypeTable.error_type,
        else => {},
    }
    // Owner specs define the class and layout of linked types. `$match`
    // links the layout's kind; explicit dimensions on the spec itself win
    // (`$match<2, 2> float<2> ddx`, transpose's `any<c, r>`).
    const cs = specs[comp_group[i]];
    const ls = if (s.dims.len > 0) s else specs[layout_group[i]];

    // Non-numeric classes.
    const base = if (cs.special == .none) cs.base else s.base;
    if (!std.mem.eql(u8, base, "void") and !isNumericClass(base)) {
        // Objects (samplers are checked) and classes zdxc does not model
        // (HitObject, node records, LinAlg...): unconstrained.
        if (i > 0 and i - 1 < args.len and isObjectClass(base)) return objectCheck(sema, base, args[i - 1].ty);
        return TypeTable.error_type;
    }
    if (isObjectClass(base)) {
        if (i > 0 and i - 1 < args.len) return objectCheck(sema, base, args[i - 1].ty);
        return TypeTable.error_type;
    }
    if (std.mem.eql(u8, base, "void")) {
        // `$match<0, -1> void<4>`: the object's component type.
        if (s.match_comp != null and s.match_comp.? == -1 and obj_elem != TypeTable.error_type) {
            const comp = t.component(obj_elem) orelse return TypeTable.error_type;
            return try layoutType(sema, ls, comp, layout_group[i], bindings, args);
        }
        if (s.match_layout != null and s.match_layout.? == -1) return obj_elem;
        return TypeTable.void_type;
    }

    var comp = classComponent(base, group_comp[comp_group[i]]) orelse return null;
    if (comp.isLiteral()) comp = comp.concrete();
    return try layoutType(sema, ls, comp, layout_group[i], bindings, args);
}

fn layoutType(sema: anytype, ls: *const table.Spec, comp: Scalar, group: usize, bindings: *Bindings, args: []const ArgInfo) !?TypeId {
    const t = &sema.types;
    if (ls.any_layout) {
        // `<>`: the shape of the group's arguments (scalars splat to the
        // widest one).
        var shape: ?TypeTable.Shape = null;
        if (group > 0 and group - 1 < args.len) shape = t.shape(args[group - 1].ty);
        // A scalar (or no argument of its own) takes the shared shape.
        if (shape == null or shape.?.count() == 1) shape = bindings.any_shape orelse shape;
        if (shape == null) return try t.scalar(comp);
        return try t.withShape(comp, shape.?);
    }
    if (ls.dims.len == 0) return try t.scalar(comp);
    const arg_shape: ?TypeTable.Shape = if (group > 0 and group - 1 < args.len) t.shape(args[group - 1].ty) else null;
    if (ls.dims.len == 1) {
        const len = dimValue(ls.dims[0], bindings, if (arg_shape) |sh| (if (sh.kind == .vector) sh.cols else if (sh.kind == .scalar) 1 else sh.cols) else null) orelse return null;
        if (len < 1 or len > 4) return null;
        return try t.vector(comp, len);
    }
    const rows = dimValue(ls.dims[0], bindings, if (arg_shape) |sh| sh.rows else null) orelse return null;
    const cols = dimValue(ls.dims[1], bindings, if (arg_shape) |sh| sh.cols else null) orelse return null;
    if (rows < 1 or rows > 4 or cols < 1 or cols > 4) return null;
    return try t.matrix(comp, rows, cols);
}

/// A layout dimension: a number, or a symbol bound from the argument.
fn dimValue(dim: []const u8, b: *Bindings, from_arg: ?u8) ?u8 {
    if (std.fmt.parseInt(u8, dim, 10)) |v| return v else |_| {}
    if (b.get(dim)) |v| return v;
    const v = from_arg orelse return null;
    if (!b.bind(dim, v)) return null;
    return v;
}

fn common(a: Scalar, b: Scalar) Scalar {
    return Scalar.combine(a, b);
}

/// The component a class gives for argument component `c` (null: no
/// argument decided it). Concrete classes ignore the arguments.
fn classComponent(base: []const u8, c: ?Scalar) ?Scalar {
    const fixed = [_]struct { []const u8, Scalar }{
        .{ "bool", .bool },       .{ "int", .int },                     .{ "uint", .uint },                     .{ "float", .float },
        .{ "double", .double },   .{ "u64", .uint64 },                  .{ "i64", .int64 },                     .{ "int16_t", .int16 },
        .{ "uint16_t", .uint16 }, .{ "float16_t", .float16 },           .{ "half", .half },                     .{ "int64_t", .int64 },
        .{ "uint64_t", .uint64 }, .{ "uint_only", .uint },              .{ "int32_only", .int },                .{ "int64_only", .int64 },
        .{ "any_int32", .int },   .{ "any_int64", .int64 },             .{ "uint_only32", .uint },              .{ "p32i8", .uint },
        .{ "p32u8", .uint },      .{ "int8_t4_packed", .int8_4packed }, .{ "uint8_t4_packed", .uint8_4packed },
    };
    for (fixed) |f| {
        if (std.mem.eql(u8, f[0], base)) {
            // Classes that only fix the width keep the argument's type
            // when it fits (int32_only accepts int and uint).
            if (c) |arg| {
                if (std.mem.eql(u8, base, "int32_only") or std.mem.eql(u8, base, "any_int32") or std.mem.eql(u8, base, "uint_only")) {
                    if (arg.isInt() and arg.size() == 4) return arg.concrete();
                }
                if (std.mem.eql(u8, base, "int64_only") or std.mem.eql(u8, base, "any_int64")) {
                    if (arg.isInt() and arg.size() == 8) return arg;
                }
            }
            return f[1];
        }
    }
    const arg = c orelse return switch (base.len) {
        else => if (std.mem.eql(u8, base, "float_like") or std.mem.eql(u8, base, "any_float")) Scalar.float else Scalar.int,
    };
    if (std.mem.eql(u8, base, "float_like") or std.mem.eql(u8, base, "any_float") or std.mem.eql(u8, base, "float32_only") or std.mem.eql(u8, base, "fldbl") or std.mem.eql(u8, base, "float_like16")) {
        return if (arg.isFloat()) arg.concrete() else .float;
    }
    if (std.mem.eql(u8, base, "any_int") or std.mem.eql(u8, base, "any_int16or32") or std.mem.eql(u8, base, "sint16or32_only") or std.mem.eql(u8, base, "int16_only")) {
        return if (arg.isInt()) arg.concrete() else .int;
    }
    if (std.mem.eql(u8, base, "numeric32_only")) return if (arg.size() == 4 and arg != .bool) arg.concrete() else if (arg.isFloat()) .float else .int;
    if (std.mem.eql(u8, base, "numeric16_only")) return if (arg.size() == 2) arg else .int16;
    if (std.mem.eql(u8, base, "numeric")) return if (arg == .bool) .int else arg.concrete();
    // any, any_sampler... and unmodelled classes: keep the argument's type.
    return arg.concrete();
}

/// Component classes that denote numeric types.
fn isNumericClass(base: []const u8) bool {
    const names = [_][]const u8{
        "bool",           "int",             "uint",            "float",        "double",         "u64",            "i64",
        "int16_t",        "uint16_t",        "float16_t",       "half",         "int64_t",        "uint64_t",       "uint_only",
        "int32_only",     "int64_only",      "any_int32",       "any_int64",    "uint_only32",    "p32i8",          "p32u8",
        "int8_t4_packed", "uint8_t4_packed", "float_like",      "any_float",    "float32_only",   "fldbl",          "float_like16",
        "any_int",        "any_int16or32",   "sint16or32_only", "int16_only",   "numeric32_only", "numeric16_only", "numeric",
        "any",            "float16_t_only",  "float32_t_only",  "int16_t_only", "uint16_t_only",
    };
    for (names) |k| if (std.mem.eql(u8, k, base)) return true;
    return false;
}

fn isObjectClass(base: []const u8) bool {
    const names = [_][]const u8{
        "sampler",   "sampler_cmp",         "any_sampler", "sampler1d",   "sampler2d", "sampler3d",    "sampler_cube",       "string",                 "wave",
        "ray_desc",  "acceleration_struct", "udt",         "resource",    "LinAlg",    "LinAlgMatrix", "node_record_or_uav", "any_node_output_record", "Texture1D",
        "Texture2D", "Texture2DArray",      "Texture3D",   "TextureCube",
    };
    for (names) |k| if (std.mem.eql(u8, k, base)) return true;
    return false;
}

/// Object parameters: check samplers; anything else is accepted.
fn objectCheck(sema: anytype, base: []const u8, arg: TypeId) ?TypeId {
    const t = &sema.types;
    const ty = t.get(arg);
    if (std.mem.eql(u8, base, "sampler") or std.mem.eql(u8, base, "sampler_cmp") or std.mem.eql(u8, base, "any_sampler")) {
        if (ty != .sampler) return if (ty == .@"error") TypeTable.error_type else null;
        if (std.mem.eql(u8, base, "sampler_cmp") and !ty.sampler.comparison) return null;
        if (std.mem.eql(u8, base, "sampler") and ty.sampler.comparison) return null;
        return TypeTable.error_type;
    }
    return TypeTable.error_type;
}
