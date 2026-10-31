//! Semantic analysis for HLSL 2021: name resolution, types, implicit
//! conversions, overload resolution (user functions, intrinsics, builtin
//! methods) and the HLSL-specific rules, annotating the AST with types.
//!
//! Where a construct is not modelled yet, Sema falls back to the error type
//! without a diagnostic so that unimplemented features never produce false
//! errors; follow-on errors are suppressed for error-typed expressions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../front/ast.zig");
const ast_clone = @import("../front/ast_clone.zig");
const source = @import("../front/source.zig");
const diag = @import("../diag.zig");
const types = @import("types.zig");
const intrinsics = @import("intrinsics.zig");
const Loc = source.Loc;
const TypeId = types.TypeId;
const TypeTable = types.TypeTable;
const Scalar = types.Scalar;

pub const Options = struct {
    /// Entry point to require (null: library or check-only).
    entry: ?[]const u8 = null,
    spirv: bool = false,
    enable_16bit: bool = false,
    /// Target shader model 6.x (long vectors need 6.9).
    sm_minor: u8 = 10,
    /// Library target (`lib_6_x`): exported functions are the roots of
    /// translation-unit checks; otherwise `root` (the entry point name).
    library: bool = true,
    root: ?[]const u8 = null,
};

/// Matrix orientation and float normalization written on a type: sugar
/// that does not change type identity.
pub const TypeAttrs = struct { orientation: ?[]const u8 = null, norm: ?[]const u8 = null };

pub const Storage = enum { global_uniform, global_static, groupshared, cbuffer, local, local_static, param, constant };

pub const Variable = struct {
    name: []const u8,
    type: TypeId,
    quals: ast.Qualifiers,
    storage: Storage,
    loc: Loc,
    /// Not assignable (const, uniform, cbuffer member, `in` resources...).
    read_only: bool,
    /// Initializer of `static const` / `const` variables, for constants.
    init: ?*ast.Expr = null,
    /// The declaration (globals, locals): register bindings, semantics.
    decl: ?*const ast.VarDecl = null,
    /// Position among the function's parameters (storage == .param).
    param_index: u32 = 0,
    /// The `cbuffer` / `tbuffer` declaration holding the variable.
    block: ?*const ast.Decl = null,
    /// Matrices in the variable are row_major (layout only).
    row_major: bool = false,
};

/// What an expression refers to, recorded by Sema for lowering
/// (`Expr.info` is an index into `Sema.resolutions` plus one).
pub const Resolution = union(enum) {
    variable: *Variable,
    enumerator: i64,
    /// A call to a user function or method.
    function: *Function,
    /// A call to an intrinsic or builtin method (`object` is the method's
    /// object type).
    intrinsic: struct { index: u16, params: []const TypeId, object: ?TypeId = null },
    /// A struct field (member expression).
    field: u32,
    /// A field named without `this.` inside a method.
    this_field: u32,
};

pub const Param = struct {
    name: []const u8,
    type: TypeId,
    dir: enum { in, out, inout },
    has_default: bool,
    /// `groupshared` parameter (SM 6.8 groupshared arguments).
    groupshared: bool = false,
};

pub const Function = struct {
    name: []const u8,
    decl: *const ast.FuncDecl,
    loc: Loc,
    ret: TypeId,
    params: []Param,
    defined: bool,
    /// Struct the method belongs to.
    owner: ?*types.StructInfo = null,
    /// Functions called from the body (call graph for recursion checks).
    callees: std.ArrayList(*Function) = .empty,
    /// The parameters' variables, created when the body is checked
    /// (null for unnamed parameters).
    param_vars: []?*Variable = &.{},
};

/// A bound template argument.
pub const Bound = union(enum) { type: TypeId, value: i64 };

pub const FuncSet = struct {
    funcs: std.ArrayList(*Function) = .empty,
};

pub const Symbol = union(enum) {
    variable: *Variable,
    functions: *FuncSet,
    type: TypeId,
    namespace: *Scope,
    enumerator: struct { type: TypeId, value: i64 },
    /// Templates of one name: primaries (function overloads) and
    /// specializations.
    template: *TemplateSet,
};

pub const TemplateSet = struct {
    decls: std.ArrayList(*const ast.Decl) = .empty,
    specs: std.ArrayList(*const ast.Decl) = .empty,
};

pub const Scope = struct {
    parent: ?*Scope,
    syms: std.StringHashMapUnmanaged(Symbol) = .empty,
    kind: enum { global, namespace, function, block, @"struct" } = .block,
    name: []const u8 = "",
};

/// Per-struct data kept by Sema (methods, nested scope).
const StructSema = struct {
    scope: *Scope,
    decl: *const ast.Decl,
};

/// Result of checking an expression.
const Typed = struct {
    ty: TypeId,
    lvalue: bool = false,
    read_only: bool = false,
    /// The expression names a function or overload set (only valid as a
    /// call's callee).
    callee: ?Callee = null,
};

const Callee = union(enum) {
    functions: *FuncSet,
    intrinsic: []const u8,
    /// `obj.Method`: methods of a builtin object, or of a struct.
    method: struct { object: TypeId, name: []const u8, object_lvalue: bool },
    type: TypeId,
    /// Function templates (instantiated per call).
    template: *TemplateSet,
    /// A callable zdxc does not model yet: the call is unconstrained.
    unknown,
};

pub const Sema = struct {
    arena: Allocator,
    diags: *diag.Diagnostics,
    types: TypeTable,
    opts: Options,
    global: *Scope,
    scope: *Scope,
    current_fn: ?*Function = null,
    current_struct: ?*types.StructInfo = null,
    /// Every function and method, in declaration order.
    all_functions: std.ArrayList(*Function) = .empty,
    /// Type attributes carried by typedef names (clang's attributed-type
    /// sugar: `typedef row_major float4x4 rm;`). Keyed by name.
    typedef_attrs: std.StringHashMapUnmanaged(TypeAttrs) = .empty,
    /// Type attributes of the last resolveType result.
    last_attrs: TypeAttrs = .{},
    resolutions: std.ArrayList(Resolution) = .empty,
    /// Variable of each checked variable declaration (for lowering).
    decl_vars: std.AutoHashMapUnmanaged(*const ast.VarDecl, *Variable) = .empty,
    /// Global uniforms outside cbuffers (dxc's `$Globals`), in order.
    uniform_globals: std.ArrayList(*Variable) = .empty,
    /// `static` (and `static const`) globals and static members, in
    /// declaration order.
    static_globals: std.ArrayList(*Variable) = .empty,
    current_block: ?*const ast.Decl = null,
    loop_depth: u32 = 0,
    switch_depth: u32 = 0,
    intrinsic_db: intrinsics.Db,
    enum_scopes: std.AutoHashMapUnmanaged(*types.EnumInfo, *Scope) = .empty,
    /// Where each template was declared (its names resolve from there).
    template_scopes: std.AutoHashMapUnmanaged(*const ast.Decl, *Scope) = .empty,
    /// Nesting of template instances being checked.
    instance_depth: u32 = 0,
    /// Instances by template and arguments.
    template_instances: std.StringHashMapUnmanaged(Symbol) = .empty,
    /// The template and arguments of each struct instance (for deduction).
    struct_instances: std.AutoHashMapUnmanaged(TypeId, struct { decl: *const ast.Decl, args: []const Bound }) = .empty,

    pub fn init(arena: Allocator, diags: *diag.Diagnostics, opts: Options) !Sema {
        const global = try arena.create(Scope);
        global.* = .{ .parent = null, .kind = .global };
        var s: Sema = .{
            .arena = arena,
            .diags = diags,
            .types = try TypeTable.init(arena),
            .opts = opts,
            .global = global,
            .scope = global,
            .intrinsic_db = try intrinsics.Db.init(arena),
        };
        try s.declareBuiltins();
        return s;
    }

    // ------------------------------------------------------------------
    // Diagnostics

    pub fn err(s: *Sema, loc: Loc, comptime fmt: []const u8, args: anytype) void {
        _ = s.diags.report(.{ .severity = .@"error", .loc = loc }, fmt, args);
    }

    fn warn(s: *Sema, loc: Loc, group: ?[]const u8, comptime fmt: []const u8, args: anytype) void {
        _ = s.diags.report(.{ .severity = .warning, .loc = loc, .group = group }, fmt, args);
    }

    pub fn typeName(s: *Sema, ty: TypeId) []const u8 {
        return s.types.format(s.arena, ty) catch "?";
    }

    // ------------------------------------------------------------------
    // Scopes

    fn pushScope(s: *Sema, kind: @FieldType(Scope, "kind")) !*Scope {
        const sc = try s.arena.create(Scope);
        sc.* = .{ .parent = s.scope, .kind = kind };
        s.scope = sc;
        return sc;
    }

    fn popScope(s: *Sema) void {
        s.scope = s.scope.parent.?;
    }

    fn declare(s: *Sema, name: []const u8, sym: Symbol, loc: Loc) !void {
        if (name.len == 0) return;
        const gop = try s.scope.syms.getOrPut(s.arena, name);
        if (gop.found_existing) {
            // Functions overload; anything else is a redefinition.
            if (sym == .functions and gop.value_ptr.* == .functions) return;
            // Template overloads and specializations (milestone 0.2):
            // plain functions take precedence over templates of the same name.
            if (sym == .template or gop.value_ptr.* == .template) {
                if (gop.value_ptr.* != .functions) gop.value_ptr.* = sym;
                return;
            }
            // A typedef may be redeclared with the same type (C++).
            if (sym == .type and gop.value_ptr.* == .type) {
                const old = gop.value_ptr.type;
                if (old != sym.type and old != TypeTable.error_type and sym.type != TypeTable.error_type and s.types.get(old) != .@"struct") {
                    s.err(loc, "typedef redefinition with different types ('{s}' vs '{s}')", .{ s.typeName(sym.type), s.typeName(old) });
                    return;
                }
                if (s.types.get(old) != .@"struct" or old == sym.type) return;
            }
            if (s.scope.kind == .global or s.scope.kind == .namespace or s.scope.kind == .@"struct" or s.scope.kind == .block or s.scope.kind == .function) {
                s.err(loc, "redefinition of '{s}'", .{name});
            }
        }
        gop.value_ptr.* = sym;
    }

    fn declareTemplate(s: *Sema, name: []const u8, d: *const ast.Decl) !void {
        return s.addTemplate(name, d, false);
    }

    /// Adds a template (or a specialization) to the name's set here.
    fn addTemplate(s: *Sema, name: []const u8, d: *const ast.Decl, spec: bool) !void {
        try s.template_scopes.put(s.arena, d, s.scope);
        const set = blk: {
            if (s.scope.syms.get(name)) |sym| switch (sym) {
                .template => |t| break :blk t,
                // Plain functions take precedence over templates.
                .functions => return,
                else => {},
            };
            const set = try s.arena.create(TemplateSet);
            set.* = .{};
            try s.declare(name, .{ .template = set }, d.loc);
            break :blk set;
        };
        // A definition replaces a forward-declared struct template, and
        // completes instances made before it.
        if (!spec and d.kind == .@"struct" and set.decls.items.len > 0 and set.decls.items[0].kind == .@"struct") {
            const old = set.decls.items[0];
            if (old.kind.@"struct".members == null and d.kind.@"struct".members != null) {
                set.decls.items[0] = d;
                try s.template_scopes.put(s.arena, d, s.template_scopes.get(old) orelse s.scope);
                var it = s.struct_instances.iterator();
                while (it.next()) |kv| {
                    if (kv.value_ptr.decl != old) continue;
                    kv.value_ptr.decl = d;
                    const info = s.types.get(kv.key_ptr.*).@"struct";
                    if (info.complete) continue;
                    try s.completeInstance(d, kv.key_ptr.*, kv.value_ptr.args);
                }
                return;
            }
        }
        try (if (spec) &set.specs else &set.decls).append(s.arena, d);
    }

    /// Checks a struct template's body for an existing instance type.
    fn completeInstance(s: *Sema, d: *const ast.Decl, ty: TypeId, args: []const Bound) Allocator.Error!void {
        const params = templateParams(d);
        const sc = try s.arena.create(Scope);
        sc.* = .{ .parent = s.template_scopes.get(d) orelse s.global, .kind = .block };
        for (params, args) |p, a| switch (a) {
            .type => |t| try sc.syms.put(s.arena, p.name, .{ .type = t }),
            .value => |v| {
                const saved = s.scope;
                s.scope = sc;
                defer s.scope = saved;
                try sc.syms.put(s.arena, p.name, .{ .enumerator = .{ .type = try s.resolveType(p.value_type.?), .value = v } });
            },
        };
        const info = s.types.get(ty).@"struct";
        try sc.syms.put(s.arena, info.name, .{ .type = ty });
        const copy = try ast_clone.clone(s.arena, *const ast.Decl, d);
        const cd: *ast.Decl = @constCast(copy);
        cd.kind.@"struct".template_params = &.{};
        cd.kind.@"struct".name = info.name;
        const ctx = s.enterInstance(sc);
        defer s.leaveInstance(ctx);
        try s.structDecl(cd, &cd.kind.@"struct");
    }

    fn specializationArgs(d: *const ast.Decl) []const ast.TemplateArg {
        return switch (d.kind) {
            .@"struct" => |st| st.specialization_args,
            .@"var" => |v| v.specialization_args,
            else => &.{},
        };
    }

    /// Binds a specialization's parameters if its pattern matches `args`.
    fn matchSpecialization(s: *Sema, spec: *const ast.Decl, args: []const Bound) Allocator.Error!?*Scope {
        const pats = specializationArgs(spec);
        if (pats.len != args.len) return null;
        const params = templateParams(spec);
        const sc = try s.arena.create(Scope);
        sc.* = .{ .parent = s.template_scopes.get(spec) orelse s.global, .kind = .block };
        const bound = try s.arena.alloc(?Bound, params.len);
        @memset(bound, null);
        const saved = s.scope;
        s.scope = sc;
        defer s.scope = saved;
        for (pats, args) |pat, arg| {
            const pname: ?[]const u8 = switch (pat) {
                .type => |t| if (t.name.parts.len == 1 and t.args.len == 0 and t.array_dims.len == 0) t.name.parts[0] else null,
                .expr => |e| if (e.kind == .name and e.kind.name.parts.len == 1) e.kind.name.parts[0] else null,
            };
            const pi: ?usize = if (pname) |n| for (params, 0..) |p, i| {
                if (eql(p.name, n)) break i;
            } else null else null;
            if (pi) |i| {
                if (bound[i]) |old| {
                    if (!std.meta.eql(old, arg)) return null;
                } else bound[i] = arg;
                continue;
            }
            // A concrete pattern must equal the argument.
            switch (arg) {
                .type => |t| {
                    const pt = (try s.typeArg(pat)) orelse return null;
                    if (pt != t) return null;
                },
                .value => |v| if ((s.constArg(pat) orelse return null) != v) return null,
            }
        }
        for (params, bound) |p, b| {
            const v = b orelse return null;
            switch (v) {
                .type => |t| try sc.syms.put(s.arena, p.name, .{ .type = t }),
                .value => |x| try sc.syms.put(s.arena, p.name, .{ .enumerator = .{ .type = try s.resolveType(p.value_type.?), .value = x } }),
            }
        }
        return sc;
    }

    fn templateParams(d: *const ast.Decl) []const ast.TemplateParam {
        return switch (d.kind) {
            .@"struct" => |st| st.template_params,
            .func => |f| f.template_params,
            .typedef => |td| td.template_params,
            .@"var" => |v| v.template_params,
            else => &.{},
        };
    }

    /// Binds a template's parameters: explicit arguments, then deduced
    /// ones, then defaults (which may use earlier parameters). Returns the
    /// instance scope and its cache key, or null after reporting an error.
    const Binding = struct { scope: *Scope, key: []const u8, args: []const Bound };

    fn bindTemplate(s: *Sema, d: *const ast.Decl, explicit: []const ast.TemplateArg, deduced: []const ?Bound, loc: Loc) Allocator.Error!?Binding {
        return s.bindTemplateMode(d, explicit, deduced, loc, false);
    }

    fn bindTemplateMode(s: *Sema, d: *const ast.Decl, explicit: []const ast.TemplateArg, deduced: []const ?Bound, loc: Loc, quiet: bool) Allocator.Error!?Binding {
        const params = templateParams(d);
        if (explicit.len > params.len) {
            if (!quiet) s.err(loc, "too many template arguments", .{});
            return null;
        }
        const sc = try s.arena.create(Scope);
        sc.* = .{ .parent = s.template_scopes.get(d) orelse s.global, .kind = .block };
        const bound = try s.arena.alloc(Bound, params.len);
        var key: std.ArrayList(u8) = .empty;
        try key.print(s.arena, "{x}:", .{@intFromPtr(d)});
        const saved = s.scope;
        defer s.scope = saved;
        for (params, 0..) |p, i| {
            // Explicit arguments and defaults are evaluated in the caller's
            // scope and the instance scope (earlier parameters) respectively.
            const arg: ?ast.TemplateArg = if (i < explicit.len) explicit[i] else null;
            s.scope = if (arg != null) saved else sc;
            if (p.value_type) |vt| {
                const v: ?i64 = if (arg) |x| s.constArg(x) else if (i < deduced.len and deduced[i] != null) deduced[i].?.value else if (p.default) |dflt| s.constArg(dflt) else null;
                const value = v orelse {
                    if (!quiet) {
                        if (arg != null) s.err(loc, "this template argument for '{s}' is not supported yet", .{p.name}) else s.err(loc, "could not deduce template argument '{s}'", .{p.name});
                    }
                    return null;
                };
                s.scope = sc;
                const ty = try s.resolveType(vt);
                bound[i] = .{ .value = value };
                const gop = try sc.syms.getOrPut(s.arena, p.name);
                gop.value_ptr.* = .{ .enumerator = .{ .type = ty, .value = value } };
                try key.print(s.arena, "v{d},", .{value});
            } else {
                const t: ?TypeId = if (arg) |x| try s.typeArg(x) else if (i < deduced.len and deduced[i] != null) deduced[i].?.type else if (p.default) |dflt| try s.typeArg(dflt) else null;
                const ty = t orelse {
                    if (!quiet) s.err(loc, "could not deduce template argument '{s}'", .{p.name});
                    return null;
                };
                bound[i] = .{ .type = ty };
                const gop = try sc.syms.getOrPut(s.arena, p.name);
                gop.value_ptr.* = .{ .type = ty };
                try key.print(s.arena, "t{d},", .{ty});
            }
        }
        return .{ .scope = sc, .key = key.items, .args = bound };
    }

    /// The context Sema saves around checking a template instance.
    const Context = struct { scope: *Scope, func: ?*Function, strct: ?*types.StructInfo, block: ?*const ast.Decl, loops: u32, switches: u32 };

    fn enterInstance(s: *Sema, sc: *Scope) Context {
        const c: Context = .{ .scope = s.scope, .func = s.current_fn, .strct = s.current_struct, .block = s.current_block, .loops = s.loop_depth, .switches = s.switch_depth };
        s.instance_depth += 1;
        s.scope = sc;
        s.current_fn = null;
        s.current_struct = null;
        s.current_block = null;
        s.loop_depth = 0;
        s.switch_depth = 0;
        return c;
    }

    fn leaveInstance(s: *Sema, c: Context) void {
        s.instance_depth -= 1;
        s.scope = c.scope;
        s.current_fn = c.func;
        s.current_struct = c.strct;
        s.current_block = c.block;
        s.loop_depth = c.loops;
        s.switch_depth = c.switches;
    }

    /// `name<float, 3>`: an instance's readable name.
    fn instanceName(s: *Sema, name: []const u8, args: []const Bound) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.print(s.arena, "{s}<", .{name});
        for (args, 0..) |a, i| {
            if (i > 0) try out.appendSlice(s.arena, ", ");
            switch (a) {
                .type => |t| try out.appendSlice(s.arena, s.typeName(t)),
                .value => |v| try out.print(s.arena, "{d}", .{v}),
            }
        }
        try out.append(s.arena, '>');
        return out.items;
    }

    /// `S<args>`: a struct template instance (or a template typedef).
    fn instantiateType(s: *Sema, set: *TemplateSet, args: []const ast.TemplateArg, loc: Loc) Allocator.Error!TypeId {
        if (set.decls.items.len == 0) {
            s.err(loc, "this template cannot be used as a type", .{});
            return TypeTable.error_type;
        }
        const d = set.decls.items[0];
        // dxc accepted this code, so a failure here is a gap in zdxc.
        var b = (try s.bindTemplateMode(d, args, &.{}, loc, true)) orelse {
            s.err(loc, "this use of a class template is not supported yet", .{});
            return TypeTable.error_type;
        };
        if (s.template_instances.get(b.key)) |sym| return if (sym == .type) sym.type else TypeTable.error_type;
        // A matching specialization replaces the primary definition.
        var body = d;
        for (set.specs.items) |sp| if (try s.matchSpecialization(sp, b.args)) |sc| {
            body = sp;
            b.scope = sc;
            break;
        };
        switch (d.kind) {
            .typedef => |td| {
                const ctx = s.enterInstance(b.scope);
                defer s.leaveInstance(ctx);
                const ty = try s.applyArrayDims(try s.resolveType(td.type), td.array_dims);
                try s.template_instances.put(s.arena, b.key, .{ .type = ty });
                return ty;
            },
            .@"struct" => |st| {
                // A readable name: S<float, 3>.
                var name: std.ArrayList(u8) = .empty;
                try name.print(s.arena, "{s}<", .{st.name orelse "?"});
                for (b.args, 0..) |a, i| {
                    if (i > 0) try name.appendSlice(s.arena, ", ");
                    switch (a) {
                        .type => |t| try name.appendSlice(s.arena, s.typeName(t)),
                        .value => |v| try name.print(s.arena, "{d}", .{v}),
                    }
                }
                try name.append(s.arena, '>');
                const copy = try ast_clone.clone(s.arena, *const ast.Decl, body);
                const cd: *ast.Decl = @constCast(copy);
                cd.kind.@"struct".template_params = &.{};
                cd.kind.@"struct".specialization_args = &.{};
                cd.kind.@"struct".name = name.items;
                // Register the type before checking members, so the struct
                // may name itself.
                const info = try s.arena.create(types.StructInfo);
                info.* = .{ .name = name.items };
                const ty = try s.types.intern(.{ .@"struct" = info });
                try b.scope.syms.put(s.arena, name.items, .{ .type = ty });
                try s.template_instances.put(s.arena, b.key, .{ .type = ty });
                try s.struct_instances.put(s.arena, ty, .{ .decl = d, .args = b.args });
                const ctx = s.enterInstance(b.scope);
                defer s.leaveInstance(ctx);
                try s.structDecl(cd, &cd.kind.@"struct");
                return ty;
            },
            else => {
                s.err(loc, "this template cannot be used as a type", .{});
                return TypeTable.error_type;
            },
        }
    }

    /// Deduces template arguments from one parameter type and argument.
    fn deduce(s: *Sema, params: []const ast.TemplateParam, pt: *const ast.TypeRef, dims: []const ?*ast.Expr, arg: TypeId, out: []?Bound) void {
        var at = arg;
        // `T x[N]`: through the array.
        if (dims.len > 0) {
            if (s.types.get(at) != .array) return;
            const arr = s.types.get(at).array;
            if (dims[0]) |de| if (de.kind == .name and de.kind.name.parts.len == 1) {
                for (params, 0..) |p, i| if (p.value_type != null and eql(p.name, de.kind.name.parts[0]) and out[i] == null) {
                    out[i] = .{ .value = arr.len };
                };
            };
            at = arr.elem;
        }
        if (s.types.component(at)) |c| if (c.isLiteral()) {
            at = s.types.withComponent(at, c.concrete()) catch at;
        };
        const n = pt.name;
        if (n.parts.len != 1) return;
        const name = n.parts[0];
        const bindName = struct {
            fn f(ps: []const ast.TemplateParam, o: []?Bound, nm: []const u8, v: Bound) void {
                for (ps, 0..) |p, i| if (eql(p.name, nm) and o[i] == null and ((p.value_type == null) == (v == .type))) {
                    o[i] = v;
                };
            }
        }.f;
        const argName = struct {
            fn f(x: ast.TemplateArg) ?[]const u8 {
                return switch (x) {
                    .type => |t| if (t.name.parts.len == 1 and t.args.len == 0) t.name.parts[0] else null,
                    .expr => |e| if (e.kind == .name and e.kind.name.parts.len == 1) e.kind.name.parts[0] else null,
                };
            }
        }.f;
        if (pt.args.len == 0) {
            bindName(params, out, name, .{ .type = at });
            return;
        }
        // vector<T, N> / matrix<T, R, C>.
        if (eql(name, "vector") and pt.args.len == 2) {
            const v = switch (s.types.get(at)) {
                .vector => |v| v,
                else => return,
            };
            if (argName(pt.args[0])) |tn| bindName(params, out, tn, .{ .type = s.types.scalar(v.elem) catch return });
            if (argName(pt.args[1])) |nn| bindName(params, out, nn, .{ .value = v.len });
            return;
        }
        if (eql(name, "matrix") and pt.args.len == 3) {
            const m = switch (s.types.get(at)) {
                .matrix => |m| m,
                else => return,
            };
            if (argName(pt.args[0])) |tn| bindName(params, out, tn, .{ .type = s.types.scalar(m.elem) catch return });
            if (argName(pt.args[1])) |rn| bindName(params, out, rn, .{ .value = m.rows });
            if (argName(pt.args[2])) |cn| bindName(params, out, cn, .{ .value = m.cols });
            return;
        }
        // S<T, ...> against an instance of S.
        const inst = s.struct_instances.get(at) orelse return;
        const sym = s.lookupName(pt.name) orelse return;
        if (sym != .template or std.mem.indexOfScalar(*const ast.Decl, sym.template.decls.items, inst.decl) == null) return;
        for (pt.args, 0..) |x, i| {
            if (i >= inst.args.len) break;
            if (argName(x)) |an| bindName(params, out, an, inst.args[i]);
        }
    }

    /// A call to a function template: deduce, instantiate (once per
    /// argument list), then resolve as an ordinary call.
    fn callTemplate(s: *Sema, e: *ast.Expr, tset: *TemplateSet, explicit: []const ast.TemplateArg, args: []const intrinsics.ArgInfo, callee: *ast.Expr) Allocator.Error!TypeId {
        // Every overload that deduces contributes its instance.
        const all = try s.arena.create(FuncSet);
        all.* = .{};
        for (tset.decls.items) |d| {
            if (d.kind != .func) continue;
            const inst = try s.instantiateCall(d, explicit, args, callee, tset.decls.items.len > 1);
            if (inst) |set| try all.funcs.appendSlice(s.arena, set.funcs.items);
        }
        if (all.funcs.items.len == 0) {
            s.err(callee.loc, "this call to a function template is not supported yet", .{});
            return TypeTable.error_type;
        }
        // Instances with the same parameters would need C++ partial
        // ordering, which zdxc does not model.
        for (all.funcs.items, 0..) |a, i| for (all.funcs.items[i + 1 ..]) |b2| if (sameSignature(a, b2)) {
            s.err(callee.loc, "choosing among these function templates is not supported yet", .{});
            return TypeTable.error_type;
        };
        return s.resolveUserCall(e, all, args, callee);
    }

    fn instantiateCall(s: *Sema, d: *const ast.Decl, explicit: []const ast.TemplateArg, args: []const intrinsics.ArgInfo, callee: *ast.Expr, quiet: bool) Allocator.Error!?*FuncSet {
        const f = d.kind.func;
        const deduced = try s.arena.alloc(?Bound, f.template_params.len);
        @memset(deduced, null);
        for (f.params, 0..) |p, i| {
            if (i >= args.len) break;
            s.deduce(f.template_params, p.type, p.array_dims, args[i].ty, deduced);
        }
        if (f.params.len < args.len) return null;
        const b = (try s.bindTemplateMode(d, explicit, deduced, callee.loc, quiet)) orelse return null;
        const set = blk: {
            if (s.template_instances.get(b.key)) |sym| break :blk sym.functions;
            const copy = try ast_clone.clone(s.arena, *const ast.Decl, d);
            const cd: *ast.Decl = @constCast(copy);
            cd.kind.func.template_params = &.{};
            // A distinct name, so the template stays visible in the body.
            const iname = try s.instanceName(f.name.last(), b.args);
            const parts = try s.arena.dupe([]const u8, f.name.parts);
            parts[parts.len - 1] = iname;
            cd.kind.func.name = .{ .loc = f.name.loc, .parts = parts };
            const set = try s.arena.create(FuncSet);
            set.* = .{};
            try s.template_instances.put(s.arena, b.key, .{ .functions = set });
            const ctx = s.enterInstance(b.scope);
            defer s.leaveInstance(ctx);
            try s.funcDeclMode(cd, &cd.kind.func, null, .both);
            if (b.scope.syms.get(iname)) |sym| if (sym == .functions) {
                try set.funcs.appendSlice(s.arena, sym.functions.funcs.items);
            };
            break :blk set;
        };
        return set;
    }

    /// `v<args>`: a variable template instance (or its specialization).
    fn instantiateVar(s: *Sema, e: *ast.Expr, set: *TemplateSet, args: []const ast.TemplateArg) Allocator.Error!Typed {
        const d = for (set.decls.items) |x| {
            if (x.kind == .@"var") break x;
        } else {
            s.err(e.loc, "this template cannot be used as a value", .{});
            return err_typed;
        };
        var b = (try s.bindTemplate(d, args, &.{}, e.loc)) orelse return err_typed;
        const v = blk: {
            if (s.template_instances.get(b.key)) |sym| break :blk sym.variable;
            var body = d;
            for (set.specs.items) |sp| if (try s.matchSpecialization(sp, b.args)) |sc| {
                body = sp;
                b.scope = sc;
                break;
            };
            const copy = try ast_clone.clone(s.arena, *const ast.Decl, body);
            const cd: *ast.Decl = @constCast(copy);
            cd.kind.@"var".template_params = &.{};
            cd.kind.@"var".specialization_args = &.{};
            cd.kind.@"var".name = try std.fmt.allocPrint(s.arena, "{s}<{s}>", .{ d.kind.@"var".name, b.key });
            const ctx = s.enterInstance(b.scope);
            defer s.leaveInstance(ctx);
            try s.varDecl(cd, &cd.kind.@"var", .global);
            const sym = b.scope.syms.get(cd.kind.@"var".name) orelse return err_typed;
            if (sym != .variable) return err_typed;
            try s.template_instances.put(s.arena, b.key, sym);
            break :blk sym.variable;
        };
        s.record(e, .{ .variable = v });
        return .{ .ty = v.type, .lvalue = true, .read_only = v.read_only };
    }

    fn lookup(s: *Sema, name: []const u8) ?Symbol {
        var sc: ?*Scope = s.scope;
        while (sc) |c| : (sc = c.parent) {
            if (c.syms.get(name)) |sym| return sym;
        }
        return null;
    }

    /// Resolve a possibly qualified name.
    fn lookupName(s: *Sema, n: ast.Name) ?Symbol {
        if (n.parts.len == 1) return s.lookup(n.parts[0]);
        var sc: *Scope = if (n.parts[0].len == 0) s.global else blk: {
            const first = s.lookup(n.parts[0]) orelse return null;
            break :blk s.scopeOf(first) orelse return null;
        };
        const start: usize = 1;
        for (n.parts[start .. n.parts.len - 1]) |part| {
            const sym = sc.syms.get(part) orelse return null;
            sc = s.scopeOf(sym) orelse return null;
        }
        return sc.syms.get(n.last());
    }

    /// The scope named by a namespace, struct or enum symbol.
    fn scopeOf(s: *Sema, sym: Symbol) ?*Scope {
        return switch (sym) {
            .namespace => |sc| sc,
            .type => |t| switch (s.types.get(t)) {
                .@"struct" => |info| if (info.sema) |p| @as(*StructSema, @ptrCast(@alignCast(p))).scope else null,
                .@"enum" => |e| s.enum_scopes.get(e),
                else => null,
            },
            else => null,
        };
    }

    // ------------------------------------------------------------------
    // Builtins

    fn declareBuiltins(s: *Sema) !void {
        // RayDesc and BuiltInTriangleIntersectionAttributes are structs.
        const f3 = try s.types.vector(.float, 3);
        const f = try s.types.scalar(.float);
        const ray = try s.arena.create(types.StructInfo);
        ray.* = .{ .name = "RayDesc", .complete = true };
        try ray.fields.appendSlice(s.arena, &.{ .{ .name = "Origin", .type = f3 }, .{ .name = "TMin", .type = f }, .{ .name = "Direction", .type = f3 }, .{ .name = "TMax", .type = f } });
        try s.global.syms.put(s.arena, "RayDesc", .{ .type = try s.types.intern(.{ .@"struct" = ray }) });
        const attr = try s.arena.create(types.StructInfo);
        attr.* = .{ .name = "BuiltInTriangleIntersectionAttributes", .complete = true };
        try attr.fields.append(s.arena, .{ .name = "barycentrics", .type = try s.types.vector(.float, 2) });
        try s.global.syms.put(s.arena, "BuiltInTriangleIntersectionAttributes", .{ .type = try s.types.intern(.{ .@"struct" = attr }) });

        // SM 6.6 descriptor heaps.
        for ([_]struct { []const u8, bool }{ .{ "ResourceDescriptorHeap", false }, .{ "SamplerDescriptorHeap", true } }) |h| {
            const v = try s.arena.create(Variable);
            v.* = .{ .name = h[0], .type = try s.types.intern(.{ .descriptor_heap = .{ .sampler = h[1] } }), .quals = .{}, .storage = .global_static, .loc = .none, .read_only = true };
            try s.global.syms.put(s.arena, h[0], .{ .variable = v });
        }

        // Builtin `static const uint` constants and the pseudo-enum typedefs
        // they belong to (from dxc's ASTContextHLSL.cpp / DxilConstants.h).
        const uint_ty = try s.types.scalar(.uint);
        for (builtin_constants) |c| try s.global.syms.put(s.arena, c[0], .{ .enumerator = .{ .type = uint_ty, .value = c[1] } });
        for ([_][]const u8{ "RAY_FLAG", "RAYQUERY_FLAG", "COMMITTED_STATUS", "CANDIDATE_TYPE", "MEMORY_TYPE_FLAG", "BARRIER_SEMANTIC_FLAG" }) |n| {
            try s.global.syms.put(s.arena, n, .{ .type = uint_ty });
        }

        // The implicit `vk` namespace (SPIR-V only): memory scope constants.
        if (s.opts.spirv) {
            const vk = try s.arena.create(Scope);
            vk.* = .{ .parent = s.global, .kind = .namespace, .name = "vk" };
            for ([_]struct { []const u8, i64 }{ .{ "CrossDeviceScope", 0 }, .{ "DeviceScope", 1 }, .{ "WorkgroupScope", 2 }, .{ "SubgroupScope", 3 }, .{ "InvocationScope", 4 }, .{ "QueueFamilyScope", 5 } }) |c| {
                try vk.syms.put(s.arena, c[0], .{ .enumerator = .{ .type = uint_ty, .value = c[1] } });
            }
            try s.global.syms.put(s.arena, "vk", .{ .namespace = vk });
        }
    }

    const builtin_constants = [_]struct { []const u8, i64 }{
        .{ "RAY_FLAG_NONE", 0x00 },                                                      .{ "RAY_FLAG_FORCE_OPAQUE", 0x01 },
        .{ "RAY_FLAG_FORCE_NON_OPAQUE", 0x02 },                                          .{ "RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH", 0x04 },
        .{ "RAY_FLAG_SKIP_CLOSEST_HIT_SHADER", 0x08 },                                   .{ "RAY_FLAG_CULL_BACK_FACING_TRIANGLES", 0x10 },
        .{ "RAY_FLAG_CULL_FRONT_FACING_TRIANGLES", 0x20 },                               .{ "RAY_FLAG_CULL_OPAQUE", 0x40 },
        .{ "RAY_FLAG_CULL_NON_OPAQUE", 0x80 },                                           .{ "RAY_FLAG_SKIP_TRIANGLES", 0x100 },
        .{ "RAY_FLAG_SKIP_PROCEDURAL_PRIMITIVES", 0x200 },                               .{ "RAY_FLAG_FORCE_OMM_2_STATE", 0x400 },
        .{ "RAYQUERY_FLAG_NONE", 0 },                                                    .{ "RAYQUERY_FLAG_ALLOW_OPACITY_MICROMAPS", 1 },
        .{ "COMMITTED_NOTHING", 0 },                                                     .{ "COMMITTED_TRIANGLE_HIT", 1 },
        .{ "COMMITTED_PROCEDURAL_PRIMITIVE_HIT", 2 },                                    .{ "CANDIDATE_NON_OPAQUE_TRIANGLE", 0 },
        .{ "CANDIDATE_PROCEDURAL_PRIMITIVE", 1 },                                        .{ "HIT_KIND_NONE", 0x00 },
        .{ "HIT_KIND_TRIANGLE_FRONT_FACE", 0xFE },                                       .{ "HIT_KIND_TRIANGLE_BACK_FACE", 0xFF },
        .{ "CLUSTER_ID_INVALID", 0xffffffff },                                           .{ "STATE_OBJECT_FLAGS_ALLOW_LOCAL_DEPENDENCIES_ON_EXTERNAL_DEFINITONS", 0x1 },
        .{ "STATE_OBJECT_FLAGS_ALLOW_EXTERNAL_DEPENDENCIES_ON_LOCAL_DEFINITIONS", 0x2 }, .{ "STATE_OBJECT_FLAG_ALLOW_LOCAL_DEPENDENCIES_ON_EXTERNAL_DEFINITONS", 0x1 },
        .{ "STATE_OBJECT_FLAG_ALLOW_EXTERNAL_DEPENDENCIES_ON_LOCAL_DEFINITIONS", 0x2 },  .{ "STATE_OBJECT_FLAG_ALLOW_STATE_OBJECT_ADDITIONS", 0x4 },
        .{ "RAYTRACING_PIPELINE_FLAG_NONE", 0x0 },                                       .{ "RAYTRACING_PIPELINE_FLAG_SKIP_TRIANGLES", 0x100 },
        .{ "RAYTRACING_PIPELINE_FLAG_SKIP_PROCEDURAL_PRIMITIVES", 0x200 },               .{ "RAYTRACING_PIPELINE_FLAG_ALLOW_OPACITY_MICROMAPS", 0x400 },
        .{ "SAMPLER_FEEDBACK_MIN_MIP", 0 },                                              .{ "SAMPLER_FEEDBACK_MIP_REGION_USED", 1 },
        .{ "UAV_MEMORY", 0x1 },                                                          .{ "GROUP_SHARED_MEMORY", 0x2 },
        .{ "NODE_INPUT_MEMORY", 0x4 },                                                   .{ "NODE_OUTPUT_MEMORY", 0x8 },
        .{ "ALL_MEMORY", 0xF },                                                          .{ "GROUP_SYNC", 0x1 },
        .{ "GROUP_SCOPE", 0x2 },                                                         .{ "DEVICE_SCOPE", 0x4 },
        .{ "REORDER_SCOPE", 0x8 },
    };

    // ------------------------------------------------------------------
    // Types

    /// Scalar, vector (`float4`) or matrix (`float4x4`) named by `n`.
    fn numericTypeByName(s: *Sema, n: []const u8) !?TypeId {
        if (s.scalarByName(n)) |sc| return try s.types.scalar(sc);
        if (n.len < 2) return null;
        const last = n[n.len - 1];
        if (last < '1' or last > '4') return null;
        if (n.len >= 4 and n[n.len - 2] == 'x' and n[n.len - 3] >= '1' and n[n.len - 3] <= '4') {
            if (s.scalarByName(n[0 .. n.len - 3])) |sc| return try s.types.matrix(sc, n[n.len - 3] - '0', last - '0');
        }
        if (s.scalarByName(n[0 .. n.len - 1])) |sc| return try s.types.vector(sc, last - '0');
        return null;
    }

    /// `half` is `float16_t` with -enable-16bit-types, else a distinct
    /// 32-bit partial-precision float.
    fn scalarByName(s: *const Sema, n: []const u8) ?Scalar {
        const sc = Scalar.fromName(n) orelse return null;
        return if (sc == .half and s.opts.enable_16bit) .float16 else sc;
    }

    /// The element type of `vector` / `matrix` must be a scalar.
    fn requireScalarArg(s: *Sema, arg: ast.TemplateArg, elem: TypeId) bool {
        if (elem == TypeTable.error_type or s.types.get(elem) == .scalar) return true;
        s.err(templateArgLoc(arg), "'{s}' cannot be used as a type parameter where a scalar is required", .{s.typeName(elem)});
        return false;
    }

    /// A non-type template argument that must be a constant.
    fn requireConstArg(s: *Sema, arg: ast.TemplateArg) Allocator.Error!?i64 {
        switch (arg) {
            .expr => |e| {
                if (s.evalInt(e)) |v| return v;
                const t = try s.expr(e);
                if (t.ty != TypeTable.error_type) s.err(e.loc, "non-type template argument of type '{s}' is not an integral constant expression", .{s.typeName(t.ty)});
                return null;
            },
            .type => |t| {
                s.err(t.loc, "template argument for non-type template parameter must be an expression", .{});
                return null;
            },
        }
    }

    fn constArg(s: *Sema, arg: ast.TemplateArg) ?i64 {
        return switch (arg) {
            .expr => |e| s.evalInt(e),
            .type => null,
        };
    }

    fn typeArg(s: *Sema, arg: ast.TemplateArg) !?TypeId {
        return switch (arg) {
            .type => |t| try s.resolveType(t),
            .expr => |e| blk: {
                // A bare name parsed as an expression may still be a type.
                if (e.kind == .name) {
                    if (s.lookupName(e.kind.name)) |sym| if (sym == .type) break :blk sym.type;
                }
                break :blk null;
            },
        };
    }

    pub fn resolveType(s: *Sema, t: *const ast.TypeRef) Allocator.Error!TypeId {
        var attrs: TypeAttrs = .{};
        const base = if (t.decltype) |e| (try s.expr(e)).ty else try s.resolveTypeName(t, &attrs);
        s.last_attrs = .{};
        if (t.unsigned_spec) if (s.types.component(base)) |c| {
            // dxc's IS_BASIC_UNSIGNABLE: 16 / 32 / 64-bit integers.
            const unsignable = c.isInt() and c != .min12int and !c.isLiteral();
            if (!unsignable) {
                s.err(t.loc, "'{s}' cannot be signed or unsigned", .{c.name()});
                return TypeTable.error_type;
            }
        };
        for (t.attr_words) |w| s.applyTypeAttr(w, base, &attrs);
        var ty = base;
        // Array dimensions on template arguments (`float[3]`).
        var i = t.array_dims.len;
        while (i > 0) {
            i -= 1;
            ty = try s.types.array(ty, try s.arrayLen(t.array_dims[i]));
        }
        s.last_attrs = attrs;
        return ty;
    }

    /// Applies a type attribute (dxc's handleHLSLTypeAttr checks).
    fn applyTypeAttr(s: *Sema, w: ast.QualWord, ty: TypeId, a: *TypeAttrs) void {
        if (ty == TypeTable.error_type) return;
        if (eql(w.word, "row_major") or eql(w.word, "column_major")) {
            if (s.types.get(ty) != .matrix) {
                s.err(w.loc, "'{s}' can only be used with a matrix type", .{w.word});
            } else if (a.orientation) |o| {
                if (eql(o, w.word)) {
                    s.warn(w.loc, "ignored-attributes", "attribute '{s}' is already applied", .{w.word});
                } else s.err(w.loc, "'row_major' and 'column_major' attributes are not compatible", .{});
            } else a.orientation = w.word;
        } else if (eql(w.word, "unorm") or eql(w.word, "snorm")) {
            const c = s.types.component(ty);
            if (c == null or !c.?.isFloat()) {
                s.err(w.loc, "snorm and unorm qualifier can only be used on floating-point types", .{});
            } else if (a.norm) |n| {
                if (eql(n, w.word)) {
                    s.warn(w.loc, "ignored-attributes", "attribute '{s}' is already applied", .{w.word});
                } else s.err(w.loc, "'unorm' and 'snorm' attributes are not compatible", .{});
            } else a.norm = w.word;
        }
    }

    /// `attrs` receives the attributes the named type carries (a typedef's,
    /// or a vector / matrix element's normalization).
    fn resolveTypeName(s: *Sema, t: *const ast.TypeRef, attrs: *TypeAttrs) Allocator.Error!TypeId {
        const n = t.name.last();
        const args = t.args;
        // User types may reuse builtin object names (`struct sampler2D`).
        if (args.len == 0 and t.name.parts.len == 1) {
            if (s.lookup(n)) |sym| if (sym == .type) {
                if (s.typedef_attrs.get(n)) |ta| attrs.* = ta;
                return sym.type;
            };
        }
        if (t.name.parts.len == 1) {
            if (try s.numericTypeByName(n)) |nt| return nt;
            if (std.mem.eql(u8, n, "void")) return TypeTable.void_type;
            if (std.mem.eql(u8, n, "string")) return s.types.intern(.string);
            if (std.mem.eql(u8, n, "vector")) {
                if (args.len == 0) return s.types.vector(.float, 4);
                const elem = try s.typeArg(args[0]) orelse return TypeTable.error_type;
                attrs.norm = s.last_attrs.norm;
                if (!s.requireScalarArg(args[0], elem)) return TypeTable.error_type;
                const len = if (args.len > 1) try s.requireConstArg(args[1]) orelse return TypeTable.error_type else 4;
                const comp = s.types.component(elem) orelse return TypeTable.error_type;
                const max: i64 = if (s.opts.sm_minor >= 9) 1024 else 4;
                if (len < 1 or len > max) {
                    s.err(templateArgLoc(args[1]), "invalid value, valid range is between 1 and {d} inclusive", .{max});
                    return TypeTable.error_type;
                }
                if (len > 4) return TypeTable.error_type; // long vectors: not modelled
                return s.types.vector(comp, @intCast(len));
            }
            if (std.mem.eql(u8, n, "matrix")) {
                if (args.len == 0) return s.types.matrix(.float, 4, 4);
                const elem = try s.typeArg(args[0]) orelse return TypeTable.error_type;
                attrs.norm = s.last_attrs.norm;
                if (!s.requireScalarArg(args[0], elem)) return TypeTable.error_type;
                const r = if (args.len > 1) try s.requireConstArg(args[1]) orelse return TypeTable.error_type else 4;
                const c = if (args.len > 2) try s.requireConstArg(args[2]) orelse return TypeTable.error_type else 4;
                const comp = s.types.component(elem) orelse return TypeTable.error_type;
                if (r < 1 or r > 4 or c < 1 or c > 4) {
                    s.err(templateArgLoc(args[if (r < 1 or r > 4) 1 else 2]), "invalid value, valid range is between 1 and 4 inclusive", .{});
                    return TypeTable.error_type;
                }
                return s.types.matrix(comp, @intCast(r), @intCast(c));
            }
            if (std.mem.eql(u8, n, "SamplerState") or std.mem.eql(u8, n, "sampler") or std.mem.eql(u8, n, "sampler1D") or std.mem.eql(u8, n, "sampler2D") or std.mem.eql(u8, n, "sampler3D") or std.mem.eql(u8, n, "samplerCUBE") or std.mem.eql(u8, n, "sampler_state")) {
                return s.types.intern(.{ .sampler = .{ .comparison = false } });
            }
            if (std.mem.eql(u8, n, "SamplerComparisonState")) return s.types.intern(.{ .sampler = .{ .comparison = true } });
            if (types.ResourceKind.fromName(n)) |kind| {
                const rov = std.mem.startsWith(u8, n, "RasterizerOrdered");
                const typed = isTextureOrTypedBuffer(kind) or (rov and !std.mem.endsWith(u8, n, "StructuredBuffer") and !std.mem.endsWith(u8, n, "ByteAddressBuffer"));
                const needs_args = rov or kind.isWritable() or switch (kind) {
                    .structured_buffer, .constant_buffer, .texture_buffer => true,
                    else => false,
                };
                const max_args: usize = switch (kind) {
                    .texture2dms, .texture2dms_array, .rw_texture2dms, .rw_texture2dms_array => 2,
                    .byte_address_buffer, .rw_byte_address_buffer => 0,
                    else => 1,
                };
                if (args.len == 0 and needs_args and kind != .rw_byte_address_buffer) {
                    s.err(t.loc, "use of class template '{s}' requires template arguments", .{n});
                    return TypeTable.error_type;
                }
                if (args.len > max_args and kind != .other) {
                    s.err(t.loc, "too many template arguments for class template '{s}'", .{n});
                    return TypeTable.error_type;
                }
                var elem: TypeId = TypeTable.void_type;
                if (args.len > 0) {
                    elem = try s.typeArg(args[0]) orelse TypeTable.error_type;
                } else if (isTextureOrTypedBuffer(kind)) {
                    elem = try s.types.vector(.float, 4); // Texture2D == Texture2D<float4>
                }
                if (typed and args.len > 0 and elem != TypeTable.error_type) {
                    switch (s.types.get(elem)) {
                        .vector => |v| if (v.len > 4 or v.len * v.elem.size() > 16) {
                            s.err(templateArgLoc(args[0]), "elements of typed buffers and textures must fit in four 32-bit quantities", .{});
                            return TypeTable.error_type;
                        },
                        .scalar => {},
                        else => {
                            s.err(templateArgLoc(args[0]), "elements of typed buffers and textures must be scalars or vectors", .{});
                            return TypeTable.error_type;
                        },
                    }
                }
                return s.types.intern(.{ .resource = .{ .kind = kind, .elem = elem, .name = n } });
            }
            const streams = [_]struct { []const u8, @FieldType(@FieldType(types.Type, "stream"), "kind") }{ .{ "PointStream", .point }, .{ "LineStream", .line }, .{ "TriangleStream", .triangle } };
            for (streams) |st| if (std.mem.eql(u8, n, st[0])) {
                const elem = if (args.len > 0) try s.typeArg(args[0]) orelse TypeTable.error_type else TypeTable.error_type;
                return s.types.intern(.{ .stream = .{ .kind = st[1], .elem = elem } });
            };
            if (std.mem.eql(u8, n, "InputPatch") or std.mem.eql(u8, n, "OutputPatch")) {
                const elem = if (args.len > 0) try s.typeArg(args[0]) orelse TypeTable.error_type else TypeTable.error_type;
                const count: u32 = if (args.len > 1) @intCast(@max(0, s.constArg(args[1]) orelse 0)) else 0;
                return s.types.intern(.{ .patch = .{ .output = n[0] == 'O', .elem = elem, .count = count } });
            }
        }
        if (s.lookupName(t.name)) |sym| switch (sym) {
            .type => |ty| return ty,
            .template => |set| return s.instantiateType(set, args, t.loc),
            else => {
                s.err(t.loc, "'{s}' does not name a type", .{n});
                return TypeTable.error_type;
            },
        };
        // Any other builtin object (RayQuery, node records, vk:: types...).
        if (isOtherBuiltinObject(n)) {
            var elem: TypeId = TypeTable.void_type;
            if (args.len > 0) elem = try s.typeArg(args[0]) orelse TypeTable.void_type;
            return s.types.intern(.{ .resource = .{ .kind = .other, .elem = elem, .name = n } });
        }
        // The parser already reported unknown type names.
        return TypeTable.error_type;
    }

    fn arrayLen(s: *Sema, dim: ?*ast.Expr) Allocator.Error!u32 {
        const e = dim orelse return 0;
        _ = try s.expr(e);
        const v = s.evalInt(e) orelse {
            if (e.ty != TypeTable.error_type) s.err(e.loc, "array size is not a constant expression", .{});
            return 1;
        };
        if (v <= 0) {
            s.err(e.loc, "array size must be greater than zero", .{});
            return 1;
        }
        return @intCast(v);
    }

    /// Only the outermost array dimension may be unsized.
    fn checkArrayDims(s: *Sema, loc: Loc, base: TypeId, dims: []const ?*ast.Expr) Allocator.Error!void {
        if (dims.len < 2) return;
        for (dims[1..], 1..) |d, i| if (d == null) {
            const inner = try s.applyArrayDims(base, dims[i + 1 ..]);
            s.err(loc, "array has incomplete element type '{s} []'", .{s.typeName(inner)});
            return;
        };
    }

    fn applyArrayDims(s: *Sema, base: TypeId, dims: []const ?*ast.Expr) Allocator.Error!TypeId {
        var ty = base;
        var i = dims.len;
        while (i > 0) {
            i -= 1;
            ty = try s.types.array(ty, try s.arrayLen(dims[i]));
        }
        return ty;
    }

    // ------------------------------------------------------------------
    // Constant evaluation (array sizes, case labels, template arguments)

    pub fn evalInt(s: *Sema, e: *const ast.Expr) ?i64 {
        return switch (s.evalConst(e) orelse return null) {
            .int => |v| v,
            .float => |v| if (std.math.isFinite(v)) @intFromFloat(@trunc(v)) else null,
            .bool => |b| @intFromBool(b),
        };
    }

    const Const = union(enum) { int: i64, float: f64, bool: bool };

    /// The intrinsics dxc folds in constant expressions: asuint, max, min.
    fn evalIntrinsic(s: *Sema, callee: *const ast.Expr, args: []const *ast.Expr) ?Const {
        if (callee.kind != .name or callee.kind.name.parts.len != 1) return null;
        const name = callee.kind.name.parts[0];
        if (s.lookupName(callee.kind.name) != null) return null; // user function
        if (std.mem.eql(u8, name, "asuint") and args.len == 1) {
            return switch (s.evalConst(args[0]) orelse return null) {
                .int => |v| .{ .int = @as(u32, @truncate(@as(u64, @bitCast(v)))) },
                .float => |v| .{ .int = @as(u32, @bitCast(@as(f32, @floatCast(v)))) },
                .bool => null,
            };
        }
        const is_max = std.mem.eql(u8, name, "max");
        if ((is_max or std.mem.eql(u8, name, "min")) and args.len == 2) {
            const a = s.evalConst(args[0]) orelse return null;
            const b = s.evalConst(args[1]) orelse return null;
            if (a == .int and b == .int) return if ((a.int > b.int) == is_max) a else b;
            if (a == .float and b == .float) return if ((a.float > b.float) == is_max) a else b;
        }
        return null;
    }

    fn evalConst(s: *Sema, e: *const ast.Expr) ?Const {
        return switch (e.kind) {
            .int_lit => |t| .{ .int = parseIntLiteral(t) orelse return null },
            .float_lit => |t| .{ .float = parseFloatLiteral(t) orelse return null },
            .bool_lit => |b| .{ .bool = b },
            .is_same => .{ .bool = e.info != 0 },
            .call => |c| s.evalIntrinsic(c.callee, c.args),
            .name => |n| blk: {
                const sym = s.lookupName(n) orelse break :blk null;
                switch (sym) {
                    .enumerator => |en| break :blk .{ .int = en.value },
                    .variable => |v| {
                        if (!v.quals.@"const" or v.init == null) break :blk null;
                        break :blk s.evalConst(v.init.?);
                    },
                    else => break :blk null,
                }
            },
            .unary => |u| blk: {
                const v = s.evalConst(u.operand) orelse break :blk null;
                break :blk switch (u.op) {
                    .plus => v,
                    .minus => switch (v) {
                        .int => |x| .{ .int = -%x },
                        .float => |x| .{ .float = -x },
                        .bool => |b| .{ .int = -@as(i64, @intFromBool(b)) },
                    },
                    .not => .{ .bool = !truthy(v) },
                    .bit_not => switch (v) {
                        .int => |x| .{ .int = ~x },
                        else => null,
                    },
                    else => null,
                };
            },
            .binary => |b| blk: {
                const l = s.evalConst(b.lhs) orelse break :blk null;
                const r = s.evalConst(b.rhs) orelse break :blk null;
                break :blk evalBinary(b.op, l, r);
            },
            .conditional => |c| blk: {
                const cond = s.evalConst(c.cond) orelse break :blk null;
                break :blk if (truthy(cond)) s.evalConst(c.then) else s.evalConst(c.@"else");
            },
            .cast => |c| s.evalConst(c.operand),
            .construct => |c| if (c.args.len == 1) s.evalConst(c.args[0]) else null,
            .sizeof_type, .sizeof_expr => null,
            else => null,
        };
    }

    // ------------------------------------------------------------------
    // Top level

    pub fn checkUnit(s: *Sema, tu: ast.TranslationUnit) Allocator.Error!void {
        for (tu.decls) |d| try s.decl(d, .global);
        if (s.opts.entry) |entry| {
            const found = if (s.global.syms.get(entry)) |sym| sym == .functions else false;
            if (!found) _ = s.diags.report(.{ .severity = .@"error", .loc = .none }, "missing entry point definition", .{});
        }
        // Whole-program checks run only on an otherwise valid unit (as in
        // dxc's DiagnoseTranslationUnit).
        if (s.diags.error_count == 0) try s.checkRecursion();
    }

    /// Roots of the call graph: exported functions and shader entry points
    /// for libraries (in declaration order), else the entry point.
    fn graphRoots(s: *Sema) Allocator.Error![]const *Function {
        var roots: std.ArrayList(*Function) = .empty;
        for (s.all_functions.items) |f| {
            if (!f.defined) continue;
            if (s.opts.library) {
                if (f.owner != null) continue;
                const shader = for (f.decl.attrs) |a| {
                    if (eql(a.name, "shader")) break true;
                } else false;
                if (shader or (f.decl.quals.@"export" and !f.decl.quals.static)) try roots.append(s.arena, f);
            } else if (s.opts.root) |r| {
                if (f.owner == null and eql(f.name, r) and s.global.syms.get(r) != null) try roots.append(s.arena, f);
            }
        }
        return roots.items;
    }

    /// dxc's ValidateNoRecursion for every root; each recursive function is
    /// reported once.
    fn checkRecursion(s: *Sema) Allocator.Error!void {
        var reported: std.AutoHashMapUnmanaged(*Function, void) = .empty;
        for (try s.graphRoots()) |root| {
            var memo: std.AutoHashMapUnmanaged(*Function, ?*Function) = .empty;
            var stack: std.AutoHashMapUnmanaged(*Function, void) = .empty;
            const rec = try findRecursion(s.arena, &memo, &stack, root) orelse continue;
            if ((try reported.getOrPut(s.arena, rec)).found_existing) continue;
            s.err(rec.loc, "recursive functions are not allowed: function '{s}' calls recursive function '{s}'", .{ try s.qualifiedName(root), try s.qualifiedName(rec) });
        }
    }

    fn findRecursion(a: Allocator, memo: *std.AutoHashMapUnmanaged(*Function, ?*Function), stack: *std.AutoHashMapUnmanaged(*Function, void), f: *Function) Allocator.Error!?*Function {
        if (memo.get(f)) |r| return r;
        if ((try stack.getOrPut(a, f)).found_existing) return f;
        for (f.callees.items) |c| {
            if (try findRecursion(a, memo, stack, c)) |r| {
                try memo.put(a, f, r);
                return r;
            }
        }
        _ = stack.remove(f);
        try memo.put(a, f, null);
        return null;
    }

    fn qualifiedName(s: *Sema, f: *const Function) Allocator.Error![]const u8 {
        const owner = f.owner orelse return f.name;
        return std.fmt.allocPrint(s.arena, "{s}::{s}", .{ owner.name, f.name });
    }

    const DeclCtx = enum { global, local, member, cbuffer };

    fn decl(s: *Sema, d: *const ast.Decl, ctx: DeclCtx) Allocator.Error!void {
        switch (d.kind) {
            .@"var" => |*v| try s.varDecl(d, v, ctx),
            .func => |*f| try s.funcDecl(d, f, null),
            .@"struct" => |*st| try s.structDecl(d, st),
            .cbuffer => |cb| {
                for (cb.semantics) |sem| {
                    if (sem.kind != .register) continue;
                    const reg = s.parseRegister(sem) orelse continue;
                    if (reg.type == 0) continue;
                    const want: u8 = if (cb.tbuffer) 't' else 'b';
                    if (std.ascii.toLower(reg.type) != want) {
                        s.err(sem.loc, "invalid register specification, expected '{c}' binding", .{want});
                    } else if (reg.profile != null) {
                        s.err(sem.loc, "user defined constant buffer slots cannot be target specific", .{});
                    }
                }
                s.current_block = d;
                defer s.current_block = null;
                for (cb.members) |m| try s.decl(m, .cbuffer);
                if (cb.name.len > 0 and s.scope.syms.get(cb.name) == null) {
                    // The buffer name is not usable as a value; reserve it.
                }
            },
            .typedef => |td| {
                if (td.template_params.len > 0) return s.declareTemplate(td.name, d);
                if (ctx == .member and s.instance_depth == 0) {
                    s.err(d.loc, "nested typedefs are not supported in HLSL", .{});
                    return;
                }
                const base = try s.resolveType(td.type);
                const attrs = s.checkModifiers(.typedef, td.qual_words, d.loc, base, s.last_attrs);
                const ty = try s.applyArrayDims(base, td.array_dims);
                try s.declare(td.name, .{ .type = ty }, d.loc);
                if (attrs.orientation != null or attrs.norm != null) try s.typedef_attrs.put(s.arena, td.name, attrs);
            },
            .@"enum" => |e| try s.enumDecl(d, e),
            .namespace => |n| {
                const sc = blk: {
                    if (s.scope.syms.get(n.name)) |sym| if (sym == .namespace) break :blk sym.namespace;
                    const sc = try s.arena.create(Scope);
                    sc.* = .{ .parent = s.scope, .kind = .namespace, .name = n.name };
                    try s.declare(n.name, .{ .namespace = sc }, d.loc);
                    break :blk sc;
                };
                const saved = s.scope;
                s.scope = sc;
                defer s.scope = saved;
                for (n.decls) |m| try s.decl(m, .global);
            },
            .using_namespace => |n| {
                // Bring the namespace's names into this scope.
                const sym = s.lookupName(n) orelse {
                    // dxc's builtin `dx` namespace (HitObject, linalg, ...)
                    // exists in every shader model; its contents are not
                    // modelled as a scope here.
                    if (eql(n.parts[0], "dx")) return;
                    return s.err(d.loc, "unknown namespace '{s}'", .{n.last()});
                };
                if (sym != .namespace) return s.err(d.loc, "'{s}' is not a namespace", .{n.last()});
                var it = sym.namespace.syms.iterator();
                while (it.next()) |kv| {
                    if (s.scope.syms.get(kv.key_ptr.*) == null) try s.scope.syms.put(s.arena, kv.key_ptr.*, kv.value_ptr.*);
                }
            },
            .using_decl => |n| {
                if (s.lookupName(n)) |sym| try s.scope.syms.put(s.arena, n.last(), sym);
            },
            .pragma => {},
            .static_assert => |sa| {
                const t = try s.expr(sa.cond);
                if (t.ty == TypeTable.error_type) return;
                const v = s.evalConst(sa.cond) orelse {
                    s.err(sa.cond.loc, "static_assert expression is not an integral constant expression", .{});
                    return;
                };
                if (!truthy(v)) s.err(d.loc, "static_assert failed {s}", .{sa.message orelse "\"\""});
            },
        }
    }

    fn enumDecl(s: *Sema, d: *const ast.Decl, e: ast.EnumDecl) Allocator.Error!void {
        const info = try s.arena.create(types.EnumInfo);
        var underlying: Scalar = .int;
        if (e.underlying) |u| {
            const ut = try s.resolveType(u);
            underlying = s.types.component(ut) orelse .int;
        }
        info.* = .{ .name = e.name orelse "<anonymous enum>", .underlying = underlying, .scoped = e.scoped };
        const ty = try s.types.intern(.{ .@"enum" = info });
        if (e.name) |n| try s.declare(n, .{ .type = ty }, d.loc);
        const sc = try s.arena.create(Scope);
        sc.* = .{ .parent = s.scope, .kind = .namespace, .name = info.name };
        try s.enum_scopes.put(s.arena, info, sc);
        var next: i64 = 0;
        for (e.values) |v| {
            if (v.value) |ve| {
                _ = try s.expr(ve);
                next = s.evalInt(ve) orelse blk: {
                    s.err(ve.loc, "expression is not an integral constant expression", .{});
                    break :blk next;
                };
            }
            const sym: Symbol = .{ .enumerator = .{ .type = ty, .value = next } };
            try sc.syms.put(s.arena, v.name, sym);
            if (!e.scoped) try s.declare(v.name, sym, v.loc);
            next += 1;
        }
    }

    fn structDecl(s: *Sema, d: *const ast.Decl, st: *const ast.StructDecl) Allocator.Error!void {
        const name = st.name orelse "<anonymous struct>";
        if (st.template_params.len > 0 or st.specialization_args.len > 0) {
            try s.addTemplate(name, d, st.specialization_args.len > 0);
            return;
        }
        // Reuse a forward-declared struct.
        var info: *types.StructInfo = undefined;
        var ty: TypeId = undefined;
        if (s.scope.syms.get(name)) |sym| blk: {
            if (sym == .type) if (s.types.get(sym.type) == .@"struct") {
                info = s.types.get(sym.type).@"struct";
                ty = sym.type;
                if (info.complete and st.members != null) s.err(d.loc, "redefinition of '{s}'", .{name});
                break :blk;
            };
            s.err(d.loc, "redefinition of '{s}' as a different kind of symbol", .{name});
            return;
        } else {
            info = try s.arena.create(types.StructInfo);
            info.* = .{ .name = name };
            ty = try s.types.intern(.{ .@"struct" = info });
            try s.declare(name, .{ .type = ty }, d.loc);
        }
        const members = st.members orelse return;
        const sc = try s.arena.create(Scope);
        sc.* = .{ .parent = s.scope, .kind = .@"struct", .name = name };
        const ss = try s.arena.create(StructSema);
        ss.* = .{ .scope = sc, .decl = d };
        info.sema = ss;

        // Base classes contribute their fields first; their members are
        // found through the base's scope (so derived members hide them).
        var base_fields: usize = 0;
        for (st.bases) |b| {
            const bt = try s.resolveType(b);
            if (s.types.get(bt) == .@"struct") {
                const base = s.types.get(bt).@"struct";
                try info.fields.appendSlice(s.arena, base.fields.items);
                try info.bases.append(s.arena, base);
                base_fields = info.fields.items.len;
                if (base.sema) |bp| {
                    // The base's scope (and through it, its own bases).
                    const bs: *StructSema = @ptrCast(@alignCast(bp));
                    sc.parent = bs.scope;
                }
            } else if (bt != TypeTable.error_type) {
                // Builtin types are final; scalars are not classes at all.
                const base_name: ?[]const u8 = switch (s.types.get(bt)) {
                    .vector => "vector",
                    .matrix => "matrix",
                    .resource => |r| r.name,
                    .sampler => |sm| if (sm.comparison) "SamplerComparisonState" else "SamplerState",
                    .scalar, .@"enum" => null,
                    else => s.typeName(bt),
                };
                if (base_name) |n| s.err(b.loc, "base '{s}' is marked 'final'", .{n}) else s.err(b.loc, "expected class name", .{});
            }
        }

        const saved = s.scope;
        s.scope = sc;
        defer s.scope = saved;
        // Fields and nested types first, then methods (which may use any
        // field regardless of order).
        for (members) |m| switch (m.kind) {
            .@"var" => |v| {
                if (v.quals.static) {
                    try s.varDecl(m, &m.kind.@"var", .member);
                    continue;
                }
                if (v.bitfield != null) {
                    s.err(m.loc, "bitfields are not supported yet (planned for milestone 0.2)", .{});
                }
                const fbase = try s.resolveType(v.type);
                const start = if (v.qual_words.len > 0) v.qual_words[0].loc else v.type.loc;
                if (v.array_dims.len > 0 and v.array_dims[0] == null) {
                    s.err(start, "array dimensions of struct/class members must be explicit", .{});
                    continue;
                }
                const fattrs = s.checkModifiers(.field, v.qual_words, start, fbase, s.last_attrs);
                const ft = try s.applyArrayDims(fbase, v.array_dims);
                s.checkSemantics(.field, v.semantics, ft, false);
                if (s.types.get(fbase) == .string) s.err(v.name_loc, "string declaration may only appear in global scope", .{});
                for (info.fields.items[base_fields..]) |f| if (std.mem.eql(u8, f.name, v.name)) s.err(v.name_loc, "duplicate member '{s}'", .{v.name});
                var fsem: ?[]const u8 = null;
                for (v.semantics) |sem| if (sem.kind == .semantic) {
                    fsem = sem.values[0];
                };
                try info.fields.append(s.arena, .{ .name = v.name, .type = ft, .row_major = isRowMajor(fattrs), .semantic = fsem, .interp = interpOf(v.quals) });
            },
            .func => {},
            else => try s.decl(m, .member),
        };
        info.complete = true;
        const saved_struct = s.current_struct;
        s.current_struct = info;
        defer s.current_struct = saved_struct;
        // All method signatures first, then bodies, so methods can call
        // methods defined later in the struct.
        for (members) |m| if (m.kind == .func) try s.funcDeclMode(m, &m.kind.func, info, .declare_only);
        for (members) |m| if (m.kind == .func) try s.funcDeclMode(m, &m.kind.func, info, .body_only);
    }

    const DeclKind = enum {
        local_variable,
        typedef,
        function,
        method,
        global_variable,
        parameter,
        field,

        fn text(k: DeclKind) []const u8 {
            return switch (k) {
                .local_variable => "local variable",
                .global_variable => "global variable",
                inline else => |t| @tagName(t),
            };
        }
    };

    /// Which declarations each qualifier may modify, and which qualifiers
    /// conflict: a port of dxc's DiagnoseHLSLDecl (modifier part) and its
    /// matrix-orientation type-attribute checks. `start` is where the
    /// declaration begins; `ty` is the declared (or return) type before
    /// declarator array dimensions.
    /// Returns the declaration's type attributes (`type_attrs` plus any
    /// orientation written among the qualifiers).
    fn checkModifiers(s: *Sema, kind: DeclKind, words: []const ast.QualWord, start: Loc, ty: TypeId, type_attrs: TypeAttrs) TypeAttrs {
        var attrs = type_attrs;
        if (words.len == 0) return attrs;
        const what = kind.text();
        // Storage classes: the first one wins (typedef counts as one).
        var storage: ?[]const u8 = if (kind == .typedef) "typedef" else null;
        var is_const = false;
        var is_volatile = false;
        for (words) |w| {
            if (eql(w.word, "static") or eql(w.word, "extern")) {
                if (storage) |prev| {
                    if (eql(prev, w.word)) {
                        s.warn(w.loc, "duplicate-decl-specifier", "duplicate '{s}' declaration specifier", .{w.word});
                    } else s.err(w.loc, "cannot combine with previous '{s}' declaration specifier", .{prev});
                } else storage = w.word;
            } else if (eql(w.word, "const")) {
                is_const = true;
            } else if (eql(w.word, "volatile")) {
                is_volatile = true;
            } else if (eql(w.word, "row_major") or eql(w.word, "column_major")) {
                s.applyTypeAttr(w, ty, &attrs);
            }
        }
        const is_static = storage != null and eql(storage.?, "static");
        const is_extern = storage != null and eql(storage.?, "extern");
        if (is_extern and !(kind == .function or kind == .global_variable)) s.err(start, "'extern' is not a valid modifier for a {s}", .{what});
        if (is_static and (kind == .typedef or kind == .parameter)) s.err(start, "'static' is not a valid modifier for a {s}", .{what});
        if (is_volatile and !(kind == .local_variable or kind == .typedef)) s.err(start, "'volatile' is not a valid modifier for a {s}", .{what});
        if (is_const and kind == .field and !is_static) s.err(start, "'const' is not a valid modifier for a {s}", .{what});

        const param = kind == .parameter;
        const param_field_fn = param or kind == .field or kind == .function;
        var uniform: ?ast.QualWord = null;
        var usage: ?ast.QualWord = null;
        var nointerp: ?ast.QualWord = null;
        var any_linear: ?ast.QualWord = null;
        var linear = false;
        var center: ?ast.QualWord = null;
        var noperspective = false;
        var sample: ?ast.QualWord = null;
        var centroid: ?ast.QualWord = null;
        var topology: ?ast.QualWord = null;
        var mesh: ?ast.QualWord = null;
        var usage_in = false;
        var usage_out = false;
        var groupshared = false;
        // clang keeps declaration attributes in reverse source order.
        var i = words.len;
        while (i > 0) {
            i -= 1;
            const w = words[i];
            const word = w.word;
            if (eql(word, "shared")) {
                if (kind != .global_variable) s.err(w.loc, "'shared' is not a valid modifier for a {s}", .{what});
                if (is_static) s.err(w.loc, "'static' and 'shared' cannot be used together for a {s}", .{what});
            } else if (eql(word, "groupshared")) {
                groupshared = true;
                if (param and (usage_in or usage_out)) {
                    s.err(w.loc, "'{s}' and 'groupshared' cannot be used together for a {s}", .{ if (usage_in and usage_out) "inout" else if (usage_in) "in" else "out", what });
                }
                if (!(kind == .global_variable or param)) s.err(w.loc, "'groupshared' is not a valid modifier for a {s}", .{what});
                if (is_extern) s.err(w.loc, "'extern' and 'groupshared' cannot be used together for a {s}", .{what});
            } else if (eql(word, "uniform")) {
                if (!(kind == .global_variable or param)) s.err(w.loc, "'uniform' is not a valid modifier for a {s}", .{what});
                if (is_static) s.err(w.loc, "'static' and 'uniform' cannot be used together for a {s}", .{what});
                uniform = w;
            } else if (eql(word, "in") or eql(word, "out") or eql(word, "inout")) {
                if (!param) {
                    s.err(w.loc, "HLSL usage '{s}' is only valid on a parameter", .{word});
                } else if (groupshared) {
                    s.err(w.loc, "'{s}' and 'groupshared' cannot be used together for a {s}", .{ word, what });
                }
                const compatible = if (eql(word, "in")) !usage_in else if (eql(word, "out")) !usage_out else !(usage_in or usage_out);
                if (eql(word, "in") or eql(word, "inout")) usage_in = true;
                if (eql(word, "out") or eql(word, "inout")) usage_out = true;
                if (!compatible) s.err(w.loc, "duplicate HLSL parameter usages '{s}'", .{word});
                usage = w;
            } else if (eql(word, "nointerpolation")) {
                if (!param_field_fn) s.err(w.loc, "'nointerpolation' is not a valid modifier for a {s}", .{what});
                if (nointerp != null) s.warn(w.loc, "ignored-attributes", "duplicate HLSL specifier 'nointerpolation'", .{});
                nointerp = w;
            } else if (eql(word, "linear") or eql(word, "center") or eql(word, "noperspective") or eql(word, "sample") or eql(word, "centroid")) {
                if (!param_field_fn) s.err(w.loc, "'{s}' is not a valid modifier for a {s}", .{ word, what });
                if (any_linear == null) any_linear = w;
                const dup = if (eql(word, "linear")) linear else if (eql(word, "center")) center != null else if (eql(word, "noperspective")) noperspective else if (eql(word, "sample")) sample != null else centroid != null;
                if (dup) s.warn(w.loc, "ignored-attributes", "duplicate HLSL specifier '{s}'", .{word});
                if (eql(word, "linear")) linear = true;
                if (eql(word, "center")) center = w;
                if (eql(word, "noperspective")) noperspective = true;
                if (eql(word, "sample")) sample = w;
                if (eql(word, "centroid")) centroid = w;
            } else if (eql(word, "point") or eql(word, "line") or eql(word, "lineadj") or eql(word, "triangle") or eql(word, "triangleadj")) {
                if (!param) s.err(w.loc, "'{s}' is not a valid modifier for a {s}", .{ word, what });
                if (topology) |t| {
                    if (eql(t.word, word)) {
                        s.warn(w.loc, "ignored-attributes", "duplicate HLSL specifier '{s}'", .{word});
                    } else s.err(w.loc, "'{s}' and '{s}' cannot be used together for a {s}", .{ word, t.word, what });
                }
                topology = w;
            } else if (eql(word, "export")) {
                if (kind != .function) s.err(w.loc, "'export' is not a valid modifier for a {s}", .{what});
                if (is_static) s.err(w.loc, "'static' and 'export' cannot be used together for a {s}", .{what});
            } else if (eql(word, "indices") or eql(word, "vertices") or eql(word, "primitives") or eql(word, "payload")) {
                if (!param) s.err(w.loc, "'{s}' is not a valid modifier for a {s}", .{ word, what });
                if (mesh) |m| {
                    if (eql(m.word, word)) {
                        s.warn(w.loc, "ignored-attributes", "duplicate HLSL specifier '{s}'", .{word});
                    } else s.err(w.loc, "'{s}' and '{s}' cannot be used together for a {s}", .{ word, m.word, what });
                }
                mesh = w;
            }
        }
        if (nointerp) |n| if (any_linear) |l| s.err(n.loc, "'nointerpolation' and '{s}' cannot be used together for a {s}", .{ l.word, what });
        if (sample) |sm| if (centroid) |c| s.warn(c.loc, "specifier-override", "'centroid' will be overridden by '{s}'", .{sm.word});
        if (center) |c| if (centroid) |_| s.warn(c.loc, "specifier-override", "'center' will be overridden by 'centroid'", .{});
        if (sample) |_| if (center) |c| s.warn(c.loc, "specifier-override", "'center' will be overridden by 'sample'", .{});
        const non_uniform = any_linear orelse nointerp orelse topology;
        if (uniform) |u| if (non_uniform) |nu| s.err(u.loc, "'{s}' and 'uniform' cannot be used together for a {s}", .{ nu.word, what });
        if (any_linear) |l| if (topology) |t| s.err(l.loc, "'{s}' and '{s}' cannot be used together for a {s}", .{ t.word, l.word, what });
        if (nointerp) |n| if (topology) |t| s.err(n.loc, "'{s}' and 'nointerpolation' cannot be used together for a {s}", .{ t.word, what });
        if (uniform) |u| if (usage) |us| if (!eql(us.word, "in")) s.err(u.loc, "'{s}' and 'uniform' cannot be used together for a {s}", .{ us.word, what });
        if (mesh) |m| {
            if (eql(m.word, "payload")) {
                if (!usage_in) s.err(start, "'payload' object must be an in parameter", .{});
            } else if (!usage_out) s.err(start, "'{s}' object must be an out parameter", .{m.word});
        }
        if (param and !(usage_in and usage_out) and s.types.get(ty) == .stream) s.err(start, "stream-output object must be an inout parameter", .{});
        return attrs;
    }

    /// Conflicting repeated function attributes. clang applies them in
    /// reverse order, so the last one written is the one kept.
    fn checkFunctionAttrs(s: *Sema, attrs: []const ast.Attribute) void {
        var last_shader: ?[]const u8 = null;
        var last_wavesize: ?ast.Attribute = null;
        var i = attrs.len;
        while (i > 0) {
            i -= 1;
            const a = attrs[i];
            if (std.ascii.eqlIgnoreCase(a.name, "shader") and a.args.len == 1 and a.args[0].kind == .string_lit) {
                const lit = a.args[0].kind.string_lit;
                const stage = if (lit.len >= 2) lit[1 .. lit.len - 1] else lit;
                if (last_shader) |kept| {
                    if (!eql(kept, stage)) s.err(a.loc, "shader attribute type '{s}' conflicts with shader attribute type '{s}'", .{ stage, kept });
                } else last_shader = stage;
            } else if (std.ascii.eqlIgnoreCase(a.name, "wavesize")) {
                if (last_wavesize) |kept| {
                    var same = kept.args.len == a.args.len;
                    if (same) for (kept.args, a.args) |x, y| {
                        if (s.evalInt(x) != s.evalInt(y)) same = false;
                    };
                    if (!same) s.err(a.loc, "shader attribute type 'wavesize' conflicts with shader attribute type 'wavesize'", .{});
                } else last_wavesize = a;
            }
        }
    }

    const Register = struct { type: u8, profile: ?[]const u8 = null, number: []const u8 = "", offset: []const u8 = "" };

    /// Checks the syntax of `register([profile,] Tn[sub] [, spaceN])` as
    /// dxc's parser does; null after an error. A space-only binding has
    /// type 0.
    fn parseRegister(s: *Sema, sem: ast.Semantic) ?Register {
        var vals = sem.values;
        var profile: ?[]const u8 = null;
        if (vals.len > 0 and isProfileLike(vals[0])) {
            profile = vals[0];
            vals = vals[1..];
        }
        if (vals.len == 0) return null;
        if (std.mem.startsWith(u8, vals[0], "space")) {
            if (!s.checkSpace(sem.loc, vals[0])) return null;
            return .{ .type = 0, .profile = profile };
        }
        const reg = vals[0];
        if (reg.len == 0 or std.mem.indexOfScalar(u8, "bcistu", std.ascii.toLower(reg[0])) == null) {
            s.err(sem.loc, "register type is unsupported - available types are 'b', 'c', 'i', 's', 't', 'u'", .{});
            return null;
        }
        const bracket = std.mem.indexOfScalar(u8, reg, '[') orelse reg.len;
        const num = reg[1..bracket];
        if (num.len > 0) _ = std.fmt.parseInt(u32, num, 10) catch {
            s.err(sem.loc, "register number should be an integral numeric string", .{});
            return null;
        };
        if (vals.len > 1 and !s.checkSpace(sem.loc, vals[1])) return null;
        return .{ .type = reg[0], .profile = profile, .number = num, .offset = reg[bracket..] };
    }

    fn checkSpace(s: *Sema, loc: Loc, text: []const u8) bool {
        if (!std.mem.startsWith(u8, text, "space")) {
            s.err(loc, "expected space definition with syntax 'spaceX', where X is an integral value", .{});
            return false;
        }
        _ = std.fmt.parseInt(u32, text["space".len..], 10) catch {
            s.err(loc, "space number should be an integral numeric string", .{});
            return false;
        };
        return true;
    }

    /// Semantics and register bindings on a declaration (dxc's
    /// DiagnoseHLSLDecl annotations part and DiagnoseRegisterType).
    fn checkSemantics(s: *Sema, kind: DeclKind, sems: []const ast.Semantic, ty: TypeId, in_cbuffer: bool) void {
        var regs: [8]?Register = @splat(null);
        for (sems, 0..) |sem, i| switch (sem.kind) {
            .semantic => if (kind == .local_variable or kind == .typedef) {
                s.err(sem.loc, "semantic is not a valid modifier for a {s}", .{kind.text()});
            },
            .register => {
                const reg = s.parseRegister(sem) orelse continue;
                if (i < regs.len) regs[i] = reg;
                if (reg.type == 0) continue;
                s.checkRegisterType(sem.loc, ty, std.ascii.toLower(reg.type));
            },
            .packoffset => s.checkPackoffset(sem, ty, kind == .global_variable and in_cbuffer),
            else => {},
        };
        // Two bindings in the same register bank and profile that differ.
        for (sems, 0..) |sem, i| {
            const a = (if (i < regs.len) regs[i] else null) orelse continue;
            if (a.type == 0) continue;
            for (sems[i + 1 ..], i + 1..) |_, j| {
                const b = (if (j < regs.len) regs[j] else null) orelse continue;
                const same_profile = a.profile == null or b.profile == null or eql(a.profile.?, b.profile.?);
                if (same_profile and a.type == b.type and (!eql(a.number, b.number) or !eql(a.offset, b.offset))) {
                    s.err(sem.loc, "conflicting register semantics", .{});
                }
            }
        }
    }

    /// `packoffset(c<n>[.component])` (dxc's parser checks plus
    /// DiagnosePackingOffset).
    fn checkPackoffset(s: *Sema, sem: ast.Semantic, ty: TypeId, in_cbuffer: bool) void {
        if (sem.values.len == 0) return;
        const text = sem.values[0];
        const dot = std.mem.indexOfScalar(u8, text, '.') orelse text.len;
        const sub = text[0..dot];
        if (sub.len == 0 or std.ascii.toLower(sub[0]) != 'c') {
            s.err(sem.loc, "register type is unsupported - available types are 'b', 'c', 'i', 's', 't', 'u'", .{});
            return;
        }
        if (sub.len > 1) _ = std.fmt.parseInt(u32, sub[1..], 10) catch {
            s.err(sem.loc, "register number should be an integral numeric string", .{});
            return;
        };
        var offset: u32 = 0;
        if (dot < text.len) {
            const comp = text[dot + 1 ..];
            offset = if (comp.len != 1) 4 else switch (comp[0]) {
                'r', 'x' => 0,
                'g', 'y' => 1,
                'b', 'z' => 2,
                'a', 'w' => 3,
                else => 4,
            };
            if (offset == 4) {
                s.err(sem.loc, "packoffset component should indicate offset with one of x, y, z, w, r, g, b, or a", .{});
                return;
            }
        }
        if (!in_cbuffer) {
            s.err(sem.loc, "packoffset is only allowed in a constant buffer", .{});
            return;
        }
        if (offset == 0 or ty == TypeTable.error_type) return;
        switch (s.types.get(ty)) {
            .scalar, .vector => if (s.types.componentCount(ty).? > 4 - offset) s.err(sem.loc, "register or offset bind not valid", .{}),
            .matrix, .array, .@"struct" => s.err(sem.loc, "register or offset bind not valid", .{}),
            else => {},
        }
    }

    fn checkRegisterType(s: *Sema, loc: Loc, ty: TypeId, reg: u8) void {
        var elem = ty;
        while (s.types.get(elem) == .array) elem = s.types.get(elem).array.elem;
        const Want = struct { expected: []const u8, ok: []const u8, warning: bool = false };
        const want: Want = switch (s.types.get(elem)) {
            .scalar, .vector, .matrix => .{ .expected = "'b', 'c', or 'i'", .ok = "bci" },
            .sampler => .{ .expected = "'s' or 't'", .ok = "st" },
            .stream, .patch => .{ .expected = "none", .ok = "", .warning = true },
            .resource => |r| blk: {
                const n = r.name;
                const u_names = [_][]const u8{ "RWTexture1D", "RWTexture1DArray", "RWTexture2D", "RWTexture2DArray", "RWTexture3D", "RWBuffer", "RWByteAddressBuffer", "RWStructuredBuffer", "AppendStructuredBuffer", "ConsumeStructuredBuffer", "FeedbackTexture2D", "FeedbackTexture2DArray" };
                const t_names = [_][]const u8{ "Buffer", "ByteAddressBuffer", "StructuredBuffer", "TextureBuffer" };
                const ts_names = [_][]const u8{ "Texture1D", "Texture1DArray", "Texture2D", "Texture2DArray", "Texture3D", "TextureCube", "TextureCubeArray", "Texture2DMS", "Texture2DMSArray" };
                for (u_names) |u| if (eql(n, u)) break :blk .{ .expected = "'u'", .ok = "u" };
                if (std.mem.startsWith(u8, n, "RasterizerOrdered")) break :blk .{ .expected = "'u'", .ok = "u" };
                for (t_names) |t| if (eql(n, t)) break :blk .{ .expected = "'t'", .ok = "t" };
                for (ts_names) |t| if (eql(n, t)) break :blk .{ .expected = "'t' or 's'", .ok = "ts" };
                if (eql(n, "ConstantBuffer")) break :blk .{ .expected = "'b'", .ok = "b" };
                return;
            },
            else => return,
        };
        if (std.mem.indexOfScalar(u8, want.ok, reg) != null) return;
        if (want.warning) {
            s.warn(loc, null, "invalid register specification, expected {s} binding", .{want.expected});
        } else s.err(loc, "invalid register specification, expected {s} binding", .{want.expected});
    }

    fn varDecl(s: *Sema, d: *const ast.Decl, v: *const ast.VarDecl, ctx: DeclCtx) Allocator.Error!void {
        if (v.template_params.len > 0 or v.specialization_args.len > 0) return s.addTemplate(v.name, d, v.specialization_args.len > 0);
        if (std.mem.indexOf(u8, v.name, "::") != null) return; // out-of-line static member definition
        const is_auto = v.type.name.isSimple("auto");
        const base = if (is_auto) TypeTable.error_type else try s.resolveType(v.type);
        const decl_attrs = s.checkModifiers(switch (ctx) {
            .local => .local_variable,
            .member => .field,
            .global, .cbuffer => .global_variable,
        }, v.qual_words, if (v.qual_words.len > 0) v.qual_words[0].loc else v.type.loc, base, if (is_auto) .{} else s.last_attrs);
        try s.checkArrayDims(v.name_loc, base, v.array_dims);
        var ty = try s.applyArrayDims(base, v.array_dims);
        if (is_auto) {
            // `auto x = init`: the initializer's type (literals become
            // concrete).
            if (v.init) |init_e| {
                const t = try s.expr(init_e);
                ty = t.ty;
                if (s.types.component(ty)) |c| if (c.isLiteral()) {
                    ty = try s.types.withComponent(ty, c.concrete());
                };
            }
        }
        if (ty == TypeTable.void_type) {
            s.err(v.name_loc, "variable has incomplete type 'void'", .{});
            ty = TypeTable.error_type;
        }
        s.checkSemantics(if (ctx == .local) .local_variable else if (ctx == .member) .field else .global_variable, v.semantics, ty, ctx == .cbuffer);
        if (s.types.get(base) == .string) {
            if (v.array_dims.len > 0) {
                s.err(v.name_loc, "array of type string is not supported", .{});
            } else if (ctx != .global) s.err(v.name_loc, "string declaration may only appear in global scope", .{});
        }
        const q = v.quals;
        const storage: Storage = switch (ctx) {
            .cbuffer => .cbuffer,
            .local => if (q.static) .local_static else .local,
            .global, .member => if (q.groupshared) .groupshared else if (q.static and q.@"const") .constant else if (q.static) .global_static else if (s.isObject(ty)) .global_static else .global_uniform,
        };
        // Uniform globals and cbuffer members are read-only, as are consts.
        const read_only = q.@"const" or storage == .cbuffer or storage == .global_uniform;
        // The variable is in scope in its own initializer (as in C++).
        const variable = try s.arena.create(Variable);
        variable.* = .{
            .name = v.name,
            .type = ty,
            .quals = q,
            .storage = storage,
            .loc = v.name_loc,
            .read_only = read_only,
            .init = v.init,
            .decl = v,
            .row_major = isRowMajor(decl_attrs),
        };
        try s.declare(v.name, .{ .variable = variable }, v.name_loc);
        try s.decl_vars.put(s.arena, v, variable);
        if (ctx == .cbuffer) variable.block = s.current_block;
        if (storage == .global_uniform) try s.uniform_globals.append(s.arena, variable);
        if (storage == .global_static or storage == .constant or storage == .local_static) try s.static_globals.append(s.arena, variable);
        // Unsized arrays take their size from the initializer.
        if (v.init) |init_e| if (!is_auto) {
            if (s.types.get(ty) == .array and s.types.get(ty).array.len == 0 and init_e.kind == .init_list) {
                const elem = s.types.get(ty).array.elem;
                const elem_count = s.types.componentCount(elem) orelse 1;
                const flat = s.flatCount(init_e);
                ty = try s.types.array(elem, @intCast(@max(1, (flat + elem_count - 1) / @max(1, elem_count))));
            }
            variable.type = ty;
            // Uses of a declaration with a bad initializer are not
            // diagnosed again (clang marks it invalid).
            if (!try s.checkInitializer(ty, init_e)) variable.type = TypeTable.error_type;
        };
    }

    /// The expression designates (part of) a groupshared variable.
    fn isGroupshared(s: *Sema, e: *const ast.Expr) bool {
        return switch (e.kind) {
            .name => |n| if (s.lookupName(n)) |sym| sym == .variable and sym.variable.storage == .groupshared else false,
            .member => |m| s.isGroupshared(m.base),
            .index => |x| s.isGroupshared(x.base),
            else => false,
        };
    }

    fn isObject(s: *Sema, ty: TypeId) bool {
        return switch (s.types.get(ty)) {
            .resource, .sampler, .stream, .patch => true,
            .array => |a| s.isObject(a.elem),
            else => false,
        };
    }

    fn funcDecl(s: *Sema, d: *const ast.Decl, f: *const ast.FuncDecl, owner: ?*types.StructInfo) Allocator.Error!void {
        return s.funcDeclMode(d, f, owner, .both);
    }

    const FuncMode = enum { both, declare_only, body_only };

    fn funcDeclMode(s: *Sema, d: *const ast.Decl, f: *const ast.FuncDecl, owner: ?*types.StructInfo, mode: FuncMode) Allocator.Error!void {
        const name = f.name.last();
        if (mode == .body_only) {
            if (f.template_params.len > 0 or (std.mem.startsWith(u8, name, "operator") and owner == null) or f.name.parts.len > 1) return;
            const sym = s.scope.syms.get(name) orelse return;
            if (sym != .functions) return;
            for (sym.functions.funcs.items) |func| if (func.decl == f) return s.funcBody(func, f);
            return;
        }
        if (std.mem.startsWith(u8, name, "operator")) if (owner) |o| {
            o.has_operators = true;
        };
        if (f.template_params.len > 0) return s.declareTemplate(name, d);
        // HLSL 2021 overloads operators as member functions only.
        if (std.mem.startsWith(u8, name, "operator") and owner == null) {
            s.err(d.loc, "non-member operator overloading is not supported yet", .{});
            return;
        }
        if (f.name.parts.len > 1) return; // out-of-line method definition: not modelled yet
        // `auto` return types are deduced in HLSL 202x; unconstrained here.
        const ret = if (f.ret.name.isSimple("auto")) TypeTable.error_type else try s.applyArrayDims(try s.resolveType(f.ret), f.ret_dims);
        const params = try s.arena.alloc(Param, f.params.len);
        _ = s.checkModifiers(if (owner != null) .method else .function, f.qual_words, if (f.qual_words.len > 0) f.qual_words[0].loc else f.ret.loc, ret, s.last_attrs);
        s.checkFunctionAttrs(f.attrs);
        for (f.params, params) |p, *out| {
            const pbase = try s.resolveType(p.type);
            _ = s.checkModifiers(.parameter, p.qual_words, if (p.qual_words.len > 0) p.qual_words[0].loc else p.type.loc, pbase, s.last_attrs);
            try s.checkArrayDims(p.name_loc, pbase, p.array_dims);
            const pt = try s.applyArrayDims(pbase, p.array_dims);
            s.checkSemantics(.parameter, p.semantics, pt, false);
            if (s.types.get(pbase) == .string) s.err(p.name_loc, "parameter of type string is not supported", .{});
            out.* = .{
                .name = p.name,
                .type = pt,
                .dir = if (p.quals.in and p.quals.out) .inout else if (p.quals.out) .out else .in,
                .has_default = p.init != null,
                .groupshared = p.quals.groupshared,
            };
            if (p.init) |init_e| _ = try s.checkInitializer(pt, init_e);
        }
        const func = try s.arena.create(Function);
        func.* = .{ .name = name, .decl = f, .loc = d.loc, .ret = ret, .params = params, .defined = f.body != null, .owner = owner };

        // Add to the overload set, matching an earlier prototype if any.
        const set = blk: {
            if (s.scope.syms.get(name)) |sym| {
                if (sym == .functions) break :blk sym.functions;
                if (sym != .template) {
                    s.err(d.loc, "redefinition of '{s}' as a different kind of symbol", .{name});
                    return;
                }
            }
            const set = try s.arena.create(FuncSet);
            set.* = .{};
            try s.declare(name, .{ .functions = set }, d.loc);
            break :blk set;
        };
        var existing: ?*Function = null;
        for (set.funcs.items) |other| {
            if (sameSignature(other, func)) existing = other;
        }
        if (existing) |e| {
            if (e.defined and func.defined) {
                s.err(d.loc, "redefinition of '{s}'", .{name});
            } else if (e.ret != func.ret and e.ret != TypeTable.error_type and func.ret != TypeTable.error_type) {
                s.err(d.loc, "functions that differ only in their return type cannot be overloaded", .{});
            }
            if (func.defined) e.* = func.*;
        } else {
            try set.funcs.append(s.arena, func);
            try s.all_functions.append(s.arena, func);
        }
        if (mode == .declare_only) return;
        // A definition completing a prototype keeps the prototype's identity
        // (call-graph edges attach to it).
        try s.funcBody(if (existing) |e| (if (func.defined) e else func) else func, f);
    }

    fn funcBody(s: *Sema, func: *Function, f: *const ast.FuncDecl) Allocator.Error!void {
        const params = func.params;
        const body = f.body orelse return;
        const saved_fn = s.current_fn;
        s.current_fn = func;
        defer s.current_fn = saved_fn;
        _ = try s.pushScope(.function);
        defer s.popScope();
        func.param_vars = try s.arena.alloc(?*Variable, params.len);
        @memset(func.param_vars, null);
        for (f.params, params, 0..) |*p, pp, pi| {
            if (p.name.len == 0) continue;
            const pv = try s.arena.create(Variable);
            pv.* = .{ .name = p.name, .type = pp.type, .quals = p.quals, .storage = .param, .loc = p.name_loc, .read_only = p.quals.@"const", .decl = p, .param_index = @intCast(pi) };
            func.param_vars[pi] = pv;
            try s.declare(p.name, .{ .variable = pv }, p.name_loc);
        }
        // The body's top-level block shares the parameter scope.
        for (body.kind.compound) |st| try s.stmt(st);
    }

    fn sameSignature(a: *const Function, b: *const Function) bool {
        if (a.params.len != b.params.len) return false;
        for (a.params, b.params) |x, y| {
            // Unresolved parameter types (templates) never collide.
            if (x.type == TypeTable.error_type or y.type == TypeTable.error_type) return false;
            if (x.type != y.type or x.dir != y.dir or x.groupshared != y.groupshared) return false;
        }
        return true;
    }

    // ------------------------------------------------------------------
    // Statements

    fn stmt(s: *Sema, st: *const ast.Stmt) Allocator.Error!void {
        switch (st.kind) {
            .compound => |list| {
                _ = try s.pushScope(.block);
                defer s.popScope();
                for (list) |c| try s.stmt(c);
            },
            .decl => |list| for (list) |d| try s.decl(d, .local),
            .expr => |e| _ = try s.expr(e),
            .empty => {},
            .@"if" => |x| {
                _ = try s.pushScope(.block);
                defer s.popScope();
                if (x.cond_decl) |d| try s.decl(d, .local);
                try s.condition(x.cond, "if statement conditional expressions must evaluate to a scalar");
                try s.stmt(x.then);
                if (x.@"else") |e| try s.stmt(e);
            },
            .@"for" => |x| {
                // HLSL 2021: the init declaration is scoped to the loop.
                _ = try s.pushScope(.block);
                defer s.popScope();
                if (x.init) |i| try s.stmt(i);
                if (x.cond) |c| try s.condition(c, "for statement conditional expressions must evaluate to a scalar");
                if (x.inc) |i| _ = try s.expr(i);
                s.loop_depth += 1;
                defer s.loop_depth -= 1;
                try s.stmt(x.body);
            },
            .@"while" => |x| {
                _ = try s.pushScope(.block);
                defer s.popScope();
                if (x.cond_decl) |d| try s.decl(d, .local);
                try s.condition(x.cond, "while statement conditional expressions must evaluate to a scalar");
                s.loop_depth += 1;
                defer s.loop_depth -= 1;
                try s.stmt(x.body);
            },
            .do_while => |x| {
                s.loop_depth += 1;
                try s.stmt(x.body);
                s.loop_depth -= 1;
                try s.condition(x.cond, "do-while statement conditional expressions must evaluate to a scalar");
            },
            .@"switch" => |x| {
                _ = try s.pushScope(.block);
                defer s.popScope();
                if (x.cond_decl) |d| try s.decl(d, .local);
                const t = try s.expr(x.cond);
                if (t.ty != TypeTable.error_type) {
                    const comp = s.types.component(t.ty);
                    const sh = s.types.shape(t.ty);
                    if (comp == null or sh == null or sh.?.kind != .scalar) {
                        s.err(x.cond.loc, "statement requires expression of integer type ('{s}' invalid)", .{s.typeName(t.ty)});
                    }
                }
                s.switch_depth += 1;
                defer s.switch_depth -= 1;
                try s.stmt(x.body);
            },
            .case => |c| {
                _ = try s.expr(c.value);
                if (c.value.ty != TypeTable.error_type and s.evalInt(c.value) == null) {
                    s.err(c.value.loc, "expression is not an integral constant expression", .{});
                }
                if (s.switch_depth == 0) s.err(st.loc, "'case' statement not in switch statement", .{});
                try s.stmt(c.stmt);
            },
            .default => |b| {
                if (s.switch_depth == 0) s.err(st.loc, "'default' statement not in switch statement", .{});
                try s.stmt(b);
            },
            .@"break" => if (s.loop_depth == 0 and s.switch_depth == 0) s.err(st.loc, "'break' statement not in loop or switch statement", .{}),
            .@"continue" => if (s.loop_depth == 0) s.err(st.loc, "'continue' statement not in loop statement", .{}),
            .discard => {},
            .@"return" => |v| try s.returnStmt(st, v),
        }
    }

    fn returnStmt(s: *Sema, st: *const ast.Stmt, v: ?*ast.Expr) Allocator.Error!void {
        const f = s.current_fn orelse return;
        const ret = f.ret;
        if (v) |e| {
            if (ret == TypeTable.void_type) {
                const t = try s.expr(e);
                if (t.ty != TypeTable.void_type and t.ty != TypeTable.error_type) s.err(e.loc, "void function '{s}' should not return a value", .{f.name});
                return;
            }
            _ = try s.checkInitializer(ret, e);
        } else if (ret != TypeTable.void_type and ret != TypeTable.error_type) {
            s.err(st.loc, "non-void function '{s}' should return a value", .{f.name});
        }
    }

    /// A condition: scalar, convertible to bool (HLSL 2021).
    fn condition(s: *Sema, e: *ast.Expr, comptime scalar_msg: []const u8) Allocator.Error!void {
        const t = try s.expr(e);
        if (t.ty == TypeTable.error_type) return;
        const sh = s.types.shape(t.ty) orelse {
            s.err(e.loc, "value of type '{s}' is not contextually convertible to 'bool'", .{s.typeName(t.ty)});
            return;
        };
        if (sh.kind != .scalar and !(sh.rows == 1 and sh.cols == 1)) s.err(e.loc, scalar_msg, .{});
    }

    // ------------------------------------------------------------------
    // Expressions

    fn record(s: *Sema, e: *ast.Expr, r: Resolution) void {
        s.resolutions.append(s.arena, r) catch return;
        e.info = @intCast(s.resolutions.items.len);
    }

    /// The resolution Sema recorded for `e`, if any.
    pub fn resolution(s: *const Sema, e: *const ast.Expr) ?Resolution {
        return if (e.info == 0) null else s.resolutions.items[e.info - 1];
    }

    fn setType(e: *ast.Expr, t: Typed) Typed {
        e.ty = t.ty;
        return t;
    }

    /// Reports an invalid numeric literal suffix (`1#INF`, `1.5q`);
    /// returns false if there was one.
    fn checkLiteralSuffix(s: *Sema, loc: Loc, text: []const u8) bool {
        if (text[0] == '\'') return true;
        const lit = scanLiteral(text);
        const suffix = text[lit.end..];
        if (lit.float) if (fixedFloatSuffix(text)) |suf| if (suf.ptr == suffix.ptr) {
            s.warn(loc.advance(@intCast(lit.end)), "hlsl-202x-extensions", "fixed-size floating-point literal suffix '{s}' is a HLSL 202x extension", .{suf});
            if (suf[1] == '1' and !s.opts.enable_16bit) {
                s.err(loc.advance(@intCast(lit.end)), "16-bit floating-point literal suffix '{s}' requires '-enable-16bit-types'", .{suf});
                return false;
            }
            return true;
        };
        const ok = if (lit.float)
            suffix.len == 0 or (suffix.len == 1 and std.mem.indexOfScalar(u8, "fFhHlL", suffix[0]) != null)
        else
            isIntSuffix(suffix) or (!lit.inf and suffix.len == 1 and std.mem.indexOfScalar(u8, "fFhH", suffix[0]) != null);
        if (ok) return true;
        s.err(loc.advance(@intCast(lit.end)), "invalid suffix '{s}' on {s} constant", .{ suffix, if (lit.float) "floating" else "integer" });
        return false;
    }

    fn rvalue(ty: TypeId) Typed {
        return .{ .ty = ty };
    }

    const err_typed: Typed = .{ .ty = TypeTable.error_type };

    pub fn expr(s: *Sema, e: *ast.Expr) Allocator.Error!Typed {
        const t = try s.exprInner(e);
        if (t.callee != null and t.ty == TypeTable.error_type) {
            // A function name used as a value is diagnosed by callers.
        }
        return setType(e, t);
    }

    fn exprInner(s: *Sema, e: *ast.Expr) Allocator.Error!Typed {
        switch (e.kind) {
            .int_lit => |t| {
                if (!s.checkLiteralSuffix(e.loc, t)) return err_typed;
                return rvalue(try s.types.scalar(intLiteralType(t)));
            },
            .float_lit => |t| {
                if (!s.checkLiteralSuffix(e.loc, t)) return err_typed;
                const sc = floatLiteralType(t);
                // `1.5h` is float unless 16-bit types are enabled.
                return rvalue(try s.types.scalar(if (sc == .half) (if (s.opts.enable_16bit) .float16 else .float) else sc));
            },
            .bool_lit => return rvalue(try s.types.scalar(.bool)),
            .string_lit => return rvalue(try s.types.intern(.string)),
            .this => {
                const info = s.current_struct orelse {
                    s.err(e.loc, "invalid use of 'this' outside of a non-static member function", .{});
                    return err_typed;
                };
                return .{ .ty = try s.types.intern(.{ .@"struct" = info }), .lvalue = true };
            },
            .name => |n| return s.nameExpr(e, n),
            .unary => |u| return s.unaryExpr(e, u.op, u.operand),
            .binary => |b| return s.binaryExpr(e, b.op, b.lhs, b.rhs),
            .assign => |a| return s.assignExpr(e, a.op, a.lhs, a.rhs),
            .conditional => |c| return s.conditionalExpr(e, c.cond, c.then, c.@"else"),
            .call => |c| return s.callExpr(e, c.callee, c.args, c.template_args),
            .construct => |c| return s.constructExpr(e, c.type, c.args),
            .cast => |c| {
                const target = try s.applyArrayDims(try s.resolveType(c.type), c.array_dims);
                const from = try s.expr(c.operand);
                if (target != TypeTable.error_type and from.ty != TypeTable.error_type and !s.explicitConvertible(from.ty, target)) {
                    s.err(e.loc, "cannot convert from '{s}' to '{s}'", .{ s.typeName(from.ty), s.typeName(target) });
                }
                // A cast of an lvalue to the same or a related struct type
                // is still an lvalue (`(Derived)x = y`).
                const ft = s.types.get(from.ty);
                const tt = s.types.get(target);
                // So is a numeric cast that keeps the component type
                // (`((int3)i4).x = 1`).
                const same_comp = s.types.component(from.ty) != null and s.types.component(from.ty) == s.types.component(target);
                const related = target == from.ty or same_comp or (ft == .@"struct" and tt == .@"struct" and (derivesFrom(ft.@"struct", tt.@"struct") or derivesFrom(tt.@"struct", ft.@"struct")));
                return .{ .ty = target, .lvalue = from.lvalue and related, .read_only = from.read_only };
            },
            .member => |m| return s.memberExpr(e, m.base, m.name, m.name_loc),
            .index => |x| return s.indexExpr(e, x.base, x.index),
            .init_list => |items| {
                for (items) |i| _ = try s.expr(i);
                return err_typed; // typed by checkInitializer
            },
            .sizeof_type => |t| {
                _ = try s.resolveType(t);
                return rvalue(try s.types.scalar(.uint));
            },
            .sizeof_expr => |x| {
                _ = try s.expr(x);
                return rvalue(try s.types.scalar(.uint));
            },
            .is_same => |x| {
                const a = try s.resolveType(x.a);
                const b = try s.resolveType(x.b);
                // The answer is kept for constant evaluation.
                e.info = @intFromBool(a == b);
                if (a == TypeTable.error_type or b == TypeTable.error_type) return err_typed;
                return rvalue(try s.types.scalar(.bool));
            },
        }
    }

    fn nameExpr(s: *Sema, e: *ast.Expr, n: ast.Name) Allocator.Error!Typed {
        if (s.lookupName(n)) |sym| switch (sym) {
            .variable => |v| {
                s.record(e, .{ .variable = v });
                return .{ .ty = v.type, .lvalue = true, .read_only = v.read_only };
            },
            .functions => |set| return .{ .ty = TypeTable.error_type, .callee = .{ .functions = set } },
            .enumerator => |en| return rvalue(en.type),
            .type => |t| return .{ .ty = TypeTable.error_type, .callee = .{ .type = t } },
            .namespace => {
                s.err(e.loc, "unexpected namespace name '{s}'", .{n.last()});
                return err_typed;
            },
            .template => |set| {
                if (set.decls.items.len > 0 and set.decls.items[0].kind == .func) return .{ .ty = TypeTable.error_type, .callee = .{ .template = set } };
                const targs: []const ast.TemplateArg = if (n.args.len > 0) n.args[n.args.len - 1] else &.{};
                return s.instantiateVar(e, set, targs);
            },
        };
        // Builtin type names used as values (`half4` in an expression).
        if (n.parts.len == 1) {
            if (try s.numericTypeByName(n.parts[0])) |t| return .{ .ty = TypeTable.error_type, .callee = .{ .type = t } };
        }
        // Struct fields and methods used unqualified inside methods.
        if (s.current_struct) |info| {
            if (n.parts.len == 1) {
                for (info.fields.items, 0..) |f, k| if (std.mem.eql(u8, f.name, n.parts[0])) {
                    s.record(e, .{ .this_field = @intCast(k) });
                    return .{ .ty = f.type, .lvalue = true };
                };
            }
        }
        if (n.parts.len > 1) {
            for (n.parts[0 .. n.parts.len - 1], 0..) |part, i| {
                // `dx::HitObject::MakeNop()` and other static members of
                // builtin objects: not modelled yet, accepted unconstrained.
                if (isOtherBuiltinObject(part)) return .{ .ty = TypeTable.error_type, .callee = .unknown };
                // `S<T>::member`, or members of a template.
                if (n.args.len > 0 and n.args[i].len > 0) {
                    s.err(e.loc, "templates are not supported yet (planned for milestone 0.2)", .{});
                    return err_typed;
                }
                const prefix: ast.Name = .{ .loc = n.loc, .parts = n.parts[0 .. i + 1] };
                if (s.lookupName(prefix)) |sym| {
                    if (sym == .template) {
                        s.err(e.loc, "templates are not supported yet (planned for milestone 0.2)", .{});
                        return err_typed;
                    }
                    // Members of a type that already failed to resolve
                    // (e.g. an alias of a template): reported there.
                    if (sym == .type and sym.type == TypeTable.error_type) return err_typed;
                }
            }
        }
        if (s.intrinsic_db.has(n.last(), s.opts.spirv)) return .{ .ty = TypeTable.error_type, .callee = .{ .intrinsic = n.last() } };
        if (n.parts.len > 1 and std.mem.eql(u8, n.parts[0], "dx")) return .{ .ty = TypeTable.error_type, .callee = .unknown };
        s.err(e.loc, "use of undeclared identifier '{s}'", .{n.last()});
        return err_typed;
    }

    /// `obj op args`: a call to the struct's `operator<op>` method
    /// (recorded on `e`), or null when it declares none.
    fn operatorCall(s: *Sema, e: *ast.Expr, obj: TypeId, name: []const u8, args: []const intrinsics.ArgInfo) Allocator.Error!?TypeId {
        const info = switch (s.types.get(obj)) {
            .@"struct" => |info| info,
            else => return null,
        };
        const ss: *StructSema = @ptrCast(@alignCast(info.sema orelse return null));
        const sym = structMember(ss, name) orelse return null;
        if (sym != .functions) return null;
        return s.resolveUserCall(e, sym.functions, args, e);
    }

    fn argInfo(s: *Sema, e: *ast.Expr, t: Typed) intrinsics.ArgInfo {
        return .{ .ty = t.ty, .lvalue = t.lvalue and !t.read_only, .loc = e.loc, .groupshared = s.isGroupshared(e) };
    }

    fn binaryOpName(op: ast.BinaryOp) ?[]const u8 {
        return switch (op) {
            .mul => "operator*",
            .div => "operator/",
            .rem => "operator%",
            .add => "operator+",
            .sub => "operator-",
            .shl => "operator<<",
            .shr => "operator>>",
            .lt => "operator<",
            .gt => "operator>",
            .le => "operator<=",
            .ge => "operator>=",
            .eq => "operator==",
            .ne => "operator!=",
            .bit_and => "operator&",
            .bit_xor => "operator^",
            .bit_or => "operator|",
            .log_and => "operator&&",
            .log_or => "operator||",
            .comma => null,
        };
    }

    /// A port of dxc's CheckUnaryOpForHLSL.
    fn unaryExpr(s: *Sema, e: *ast.Expr, op: ast.UnaryOp, operand: *ast.Expr) Allocator.Error!Typed {
        const t = try s.expr(operand);
        if (t.ty == TypeTable.error_type) return err_typed;
        if (s.types.get(t.ty) == .@"struct" and s.types.get(t.ty).@"struct".overloadsOperators()) {
            const name: []const u8 = switch (op) {
                .plus => "operator+",
                .minus => "operator-",
                .not => "operator!",
                .bit_not => "operator~",
                .pre_inc, .post_inc => "operator++",
                .pre_dec, .post_dec => "operator--",
            };
            if (try s.operatorCall(e, t.ty, name, &.{})) |rt| return rvalue(rt);
            s.err(e.loc, "invalid argument type '{s}' to unary expression", .{s.typeName(t.ty)});
            return err_typed;
        }
        const inc_dec = switch (op) {
            .pre_inc, .pre_dec, .post_inc, .post_dec => true,
            else => false,
        };
        if (inc_dec) {
            if (s.types.get(t.ty) == .@"enum") {
                s.err(e.loc, "cannot {s} expression of enum type '{s}'", .{ if (op == .pre_inc or op == .post_inc) "increment" else "decrement", s.typeName(t.ty) });
                return err_typed;
            }
            if (!t.lvalue) {
                s.err(e.loc, "expression is not assignable", .{});
                return err_typed;
            }
            if (t.read_only) {
                s.err(e.loc, "cannot assign to {s} with const-qualified type '{s}'", .{ describeTarget(operand), s.constTypeName(t.ty) });
                return err_typed;
            }
            if (s.types.component(t.ty) == .bool) {
                s.err(e.loc, "operator cannot be used with a bool lvalue", .{});
                return err_typed;
            }
        }
        const comp = s.types.component(t.ty) orelse {
            s.err(e.loc, "scalar, vector, or matrix expected", .{});
            return err_typed;
        };
        switch (op) {
            .not => return rvalue(try s.types.withComponent(t.ty, .bool)),
            .bit_not => {
                if (!comp.isIntegral()) {
                    s.err(e.loc, "int or unsigned int type required", .{});
                    return err_typed;
                }
                return rvalue(try s.types.withComponent(t.ty, if (comp == .bool) .int else comp));
            },
            .plus, .minus => return rvalue(try s.types.withComponent(t.ty, if (comp == .bool) .int else comp)),
            // Prefix forms are lvalues, as in C++.
            .pre_inc, .pre_dec, .post_inc, .post_dec => return .{ .ty = t.ty, .lvalue = op == .pre_inc or op == .pre_dec },
        }
    }

    fn binaryExpr(s: *Sema, e: *ast.Expr, op: ast.BinaryOp, lhs: *ast.Expr, rhs: *ast.Expr) Allocator.Error!Typed {
        const l = try s.expr(lhs);
        const r = try s.expr(rhs);
        if (binaryOpName(op)) |name| if (l.ty != TypeTable.error_type and r.ty != TypeTable.error_type) {
            if (try s.operatorCall(e, l.ty, name, &.{s.argInfo(rhs, r)})) |rt| return rvalue(rt);
        };
        if (op == .comma) return rvalue(r.ty);
        if (l.ty == TypeTable.error_type or r.ty == TypeTable.error_type) return err_typed;
        return rvalue(try s.binaryOp(e.loc, op, l.ty, r.ty, false, lhs.loc, rhs.loc) orelse return err_typed);
    }

    /// The type of `l op r` (for a compound assignment, `l op= r`), or null
    /// after an error: a port of dxc's CheckBinOpForHLSL after its
    /// assignability checks.
    fn binaryOp(s: *Sema, loc: Loc, op: ast.BinaryOp, lt: TypeId, rt: TypeId, compound: bool, lhs_loc: Loc, rhs_loc: Loc) Allocator.Error!?TypeId {
        const arith = switch (op) {
            .mul, .div, .rem, .add, .sub => true,
            else => false,
        };
        const order = switch (op) {
            .lt, .gt, .le, .ge => true,
            else => false,
        };
        const equality = op == .eq or op == .ne;
        const logical = op == .log_and or op == .log_or;
        const shift = op == .shl or op == .shr;
        const bitwise = shift or op == .bit_and or op == .bit_or or op == .bit_xor;
        const numeric = arith or order or logical;
        const bool_lvalue = compound and !(op == .bit_and or op == .bit_or or op == .bit_xor) and s.types.component(lt) == .bool;
        // Overloaded operators (milestone 0.2) were reported at their
        // declaration; clang resolves them before the builtin checks.
        for ([2]TypeId{ lt, rt }) |t| {
            if (s.types.get(t) == .@"struct" and s.types.get(t).@"struct".overloadsOperators()) return null;
        }

        for ([2]TypeId{ lt, rt }) |t| {
            if ((numeric or bitwise) and s.types.shape(t) == null) {
                s.err(loc, "scalar, vector, or matrix expected", .{});
                return null;
            }
            if (bitwise and !s.types.component(t).?.isIntegral()) {
                s.err(loc, "int or unsigned int type required", .{});
                return null;
            }
        }
        if (bool_lvalue) {
            s.err(loc, "operator cannot be used with a bool lvalue", .{});
            return null;
        }
        // What is left for non-numeric operands: `==` and `!=`.
        for ([2]TypeId{ lt, rt }) |t| {
            if (s.isObject(t)) {
                s.err(loc, "operator cannot be used with built-in type '{s}'", .{s.typeName(t)});
                return null;
            }
        }
        for ([2]TypeId{ lt, rt }) |t| {
            if (s.types.get(t) == .@"struct") {
                s.err(loc, "operator cannot be used with user-defined type '{s}'", .{s.typeName(t)});
                return null;
            }
        }
        if (equality and (s.types.get(lt) == .array or s.types.get(rt) == .array)) {
            s.err(loc, "equality operators cannot be used with array types", .{});
            return null;
        }
        const ls = s.types.shape(lt) orelse return s.invalidOperands(loc, lt, rt);
        const rs = s.types.shape(rt) orelse return s.invalidOperands(loc, lt, rt);
        if (logical) {
            if (ls.kind != .scalar or rs.kind != .scalar) {
                s.err(loc, "operands for short-circuiting logical binary operator must be scalar, for non-scalar types use '{s}'", .{if (op == .log_and) "and" else "or"});
                return null;
            }
            return try s.types.scalar(.bool);
        }

        // Component type.
        const lc = s.types.component(lt).?;
        const rc = s.types.component(rt).?;
        var comp = lc;
        if (!shift and lc != rc) {
            comp = Scalar.combine(lc, rc);
        } else if (shift and lc.isLiteral() and !rc.isLiteral()) {
            s.warn(loc, "ambig-lit-shift", "ambiguous type for bit shift; use a type suffix on literal values, like 'L' or 'U', or a cast", .{});
            comp = if (rc == .uint) .uint else .int;
        } else if (comp == .bool and (arith or bitwise)) {
            comp = .int;
        }

        // Shape: compound assignments keep the left operand's.
        const sh = if (compound) ls else TypeTable.combineDimensions(ls, rs) orelse {
            s.convertError(rhs_loc, rt, try s.types.withShape(comp, ls));
            return null;
        };
        if (compound and TypeTable.convertDimensions(ls, rs) == null) {
            s.convertError(rhs_loc, rt, lt);
            return null;
        }
        if (!shift and rs.count() > sh.count()) s.warn(rhs_loc, "conversion", "implicit truncation of vector type", .{});
        if (!compound and ls.count() > sh.count()) s.warn(lhs_loc, "conversion", "implicit truncation of vector type", .{});

        if ((op == .div or op == .rem) and (comp == .min12int or comp == .min16int)) {
            s.err(loc, "signed integer division is not supported on minimum-precision types, cast to int to use 32-bit division", .{});
            return null;
        }
        if (op == .rem and comp == .double) {
            s.err(loc, "modulo cannot be used with doubles, cast to float first", .{});
            return null;
        }
        if (compound) return lt;
        return try s.types.withShape(if (order or equality) .bool else comp, sh);
    }

    fn invalidOperands(s: *Sema, loc: Loc, lt: TypeId, rt: TypeId) ?TypeId {
        s.err(loc, "invalid operands to binary expression ('{s}' and '{s}')", .{ s.typeName(lt), s.typeName(rt) });
        return null;
    }

    /// Usual arithmetic conversions of two numeric operands: the result
    /// type, or null after an error.
    fn arithmetic(s: *Sema, e: *ast.Expr, a: TypeId, b: TypeId) ?TypeId {
        const ac = s.types.component(a);
        const bc = s.types.component(b);
        if (s.types.get(a) == .@"struct" or s.types.get(b) == .@"struct") {
            s.err(e.loc, "operator overloading is not supported yet (planned for milestone 0.2)", .{});
            return null;
        }
        if (ac == null or bc == null) {
            s.err(e.loc, "invalid operands to binary expression ('{s}' and '{s}')", .{ s.typeName(a), s.typeName(b) });
            return null;
        }
        const comp = Scalar.combine(ac.?, bc.?);
        const as = s.types.shape(a).?;
        const bs = s.types.shape(b).?;
        const sh = TypeTable.combineDimensions(as, bs) orelse {
            s.err(e.loc, "invalid operands to binary expression ('{s}' and '{s}')", .{ s.typeName(a), s.typeName(b) });
            return null;
        };
        if (as.count() > sh.count() or bs.count() > sh.count()) s.warn(e.loc, "conversion", "implicit truncation of vector type", .{});
        return s.types.withShape(comp, sh) catch null;
    }

    fn assignExpr(s: *Sema, e: *ast.Expr, op: ast.AssignOp, lhs: *ast.Expr, rhs: *ast.Expr) Allocator.Error!Typed {
        const l = try s.expr(lhs);
        if (l.ty == TypeTable.error_type) {
            _ = try s.expr(rhs);
            return err_typed;
        }
        if (!l.lvalue) {
            _ = try s.expr(rhs);
            s.err(lhs.loc, "expression is not assignable", .{});
            return err_typed;
        }
        if (l.read_only) {
            s.err(lhs.loc, "cannot assign to {s} with const-qualified type '{s}'", .{ describeTarget(lhs), s.constTypeName(l.ty) });
        }
        if (op == .assign) {
            if (rhs.kind == .init_list) {
                _ = try s.checkInitializer(l.ty, rhs);
            } else {
                const r = try s.expr(rhs);
                if (r.callee != null and r.ty == TypeTable.error_type) {
                    if (r.callee.? != .type) s.err(rhs.loc, "reference to overloaded function could not be resolved", .{});
                } else if (r.ty != TypeTable.error_type) {
                    if (s.conversionCost(r.ty, l.ty) == null) {
                        s.convertError(e.loc, r.ty, l.ty);
                    } else s.conversionWarnings(rhs, r.ty, l.ty);
                }
            }
        } else {
            const r = try s.expr(rhs);
            // `a op= b` on a struct: its operator op= (or operator op).
            if (s.types.get(l.ty) == .@"struct" and r.ty != TypeTable.error_type) {
                const bop = std.meta.stringToEnum(ast.BinaryOp, @tagName(op)).?;
                const base = binaryOpName(bop).?;
                const compound = try std.fmt.allocPrint(s.arena, "{s}=", .{base});
                if (try s.operatorCall(e, l.ty, compound, &.{s.argInfo(rhs, r)})) |rt| return rvalue(rt);
                if (try s.operatorCall(e, l.ty, base, &.{s.argInfo(rhs, r)})) |rt| {
                    if (s.conversionCost(rt, l.ty) == null) s.convertError(e.loc, rt, l.ty);
                    return .{ .ty = l.ty };
                }
            }
            if (r.ty != TypeTable.error_type) {
                const bop = std.meta.stringToEnum(ast.BinaryOp, @tagName(op)).?;
                _ = try s.binaryOp(e.loc, bop, l.ty, r.ty, true, lhs.loc, rhs.loc);
            }
        }
        // The result of an assignment is an lvalue, as in C++.
        return .{ .ty = l.ty, .lvalue = true };
    }

    fn constTypeName(s: *Sema, ty: TypeId) []const u8 {
        return std.fmt.allocPrint(s.arena, "const {s}", .{s.shortTypeName(ty)}) catch "const";
    }

    /// dxc spells vectors `float4` in "const-qualified" messages.
    fn shortTypeName(s: *Sema, ty: TypeId) []const u8 {
        return switch (s.types.get(ty)) {
            .vector => |v| std.fmt.allocPrint(s.arena, "{s}{d}", .{ v.elem.name(), v.len }) catch "?",
            .matrix => |m| std.fmt.allocPrint(s.arena, "{s}{d}x{d}", .{ m.elem.name(), m.rows, m.cols }) catch "?",
            else => s.typeName(ty),
        };
    }

    fn conditionalExpr(s: *Sema, e: *ast.Expr, cond: *ast.Expr, then: *ast.Expr, else_e: *ast.Expr) Allocator.Error!Typed {
        const c = try s.expr(cond);
        const t = try s.expr(then);
        const f = try s.expr(else_e);
        if (c.ty != TypeTable.error_type) {
            if (s.types.shape(c.ty)) |sh| {
                if (sh.kind != .scalar) {
                    s.err(cond.loc, "condition for short-circuiting ternary operator must be scalar, for non-scalar types use 'select'", .{});
                    return err_typed;
                }
            }
        }
        if (t.ty == TypeTable.error_type or f.ty == TypeTable.error_type) return err_typed;
        if (t.ty == f.ty) return rvalue(t.ty);
        if (s.types.isNumeric(t.ty) and s.types.isNumeric(f.ty)) {
            return rvalue(s.arithmetic(e, t.ty, f.ty) orelse return err_typed);
        }
        s.err(e.loc, "incompatible operand types ('{s}' and '{s}')", .{ s.typeName(t.ty), s.typeName(f.ty) });
        return err_typed;
    }

    fn memberExpr(s: *Sema, e: *ast.Expr, base: *ast.Expr, name: []const u8, name_loc: Loc) Allocator.Error!Typed {
        const b = try s.expr(base);
        if (b.ty == TypeTable.error_type) return err_typed;
        switch (s.types.get(b.ty)) {
            .scalar, .vector => {
                const comp = s.types.component(b.ty).?;
                const len: u8 = if (s.types.get(b.ty) == .vector) s.types.get(b.ty).vector.len else 1;
                const sw = parseSwizzle(name, len) orelse {
                    s.err(name_loc, "invalid format for vector swizzle '{s}'", .{name});
                    return err_typed;
                };
                const ty = if (sw.count == 1) try s.types.scalar(comp) else try s.types.vector(comp, sw.count);
                return .{ .ty = ty, .lvalue = b.lvalue and !sw.repeats, .read_only = b.read_only };
            },
            .matrix => |m| {
                const sw = parseMatrixSwizzle(name, m.rows, m.cols) orelse {
                    if (std.mem.indexOf(u8, name, "_m") != null and std.mem.indexOf(u8, name, "_1") != null or
                        std.mem.indexOf(u8, name, "_m") != null and std.mem.indexOf(u8, name, "_2") != null or
                        std.mem.indexOf(u8, name, "_m") != null and std.mem.indexOf(u8, name, "_3") != null or
                        std.mem.indexOf(u8, name, "_m") != null and std.mem.indexOf(u8, name, "_4") != null)
                    {
                        s.err(name_loc, "matrix subscript '{s}' mixes one-based and zero-based references", .{name});
                    } else s.err(name_loc, "invalid format for matrix subscript '{s}'", .{name});
                    return err_typed;
                };
                const ty = if (sw.count == 1) try s.types.scalar(m.elem) else try s.types.vector(m.elem, sw.count);
                return .{ .ty = ty, .lvalue = b.lvalue and !sw.repeats, .read_only = b.read_only };
            },
            .@"struct" => |info| {
                // Search from the end: derived fields hide base fields.
                var fi = info.fields.items.len;
                while (fi > 0) {
                    fi -= 1;
                    const f = info.fields.items[fi];
                    if (std.mem.eql(u8, f.name, name)) {
                        s.record(e, .{ .field = @intCast(fi) });
                        return .{ .ty = f.type, .lvalue = b.lvalue, .read_only = b.read_only };
                    }
                }
                if (info.sema) |p| {
                    const ss: *StructSema = @ptrCast(@alignCast(p));
                    if (structMember(ss, name)) |sym| switch (sym) {
                        .functions => return .{ .ty = TypeTable.error_type, .callee = .{ .method = .{ .object = b.ty, .name = name, .object_lvalue = b.lvalue } } },
                        .variable => |v| return .{ .ty = v.type, .lvalue = true, .read_only = v.read_only },
                        .template => {
                            s.err(name_loc, "templates are not supported yet (planned for milestone 0.2)", .{});
                            return err_typed;
                        },
                        else => {},
                    };
                }
                s.err(name_loc, "no member named '{s}' in '{s}'", .{ name, info.name });
                return err_typed;
            },
            .resource => |r| {
                // ConstantBuffer<S> / TextureBuffer<S>: members of S.
                if (r.kind == .constant_buffer or r.kind == .texture_buffer) {
                    if (s.types.get(r.elem) == .@"struct") {
                        const info = s.types.get(r.elem).@"struct";
                        for (info.fields.items) |f| {
                            if (std.mem.eql(u8, f.name, name)) return .{ .ty = f.type, .lvalue = true, .read_only = true };
                        }
                        if (info.sema) |p| {
                            const ss: *StructSema = @ptrCast(@alignCast(p));
                            if (ss.scope.syms.get(name)) |sym| if (sym == .functions) {
                                return .{ .ty = TypeTable.error_type, .callee = .{ .method = .{ .object = r.elem, .name = name, .object_lvalue = false } } };
                            };
                        }
                        s.err(name_loc, "no member named '{s}' in '{s}'", .{ name, s.typeName(b.ty) });
                    }
                    return err_typed;
                }
                const view: ?@FieldType(@FieldType(types.Type, "texture_view"), "kind") = switch (r.kind) {
                    .texture1d, .texture1d_array, .texture2d, .texture2d_array, .texture3d => if (eql(name, "mips")) .mips else null,
                    .texture2dms, .texture2dms_array, .rw_texture2dms, .rw_texture2dms_array => if (eql(name, "sample")) .sample else null,
                    else => null,
                };
                if (view) |k| return rvalue(try s.types.intern(.{ .texture_view = .{ .texture = b.ty, .kind = k } }));
                if (methodNamespace(s.types.get(b.ty))) |ns| if (!s.intrinsic_db.hasMethod(ns, name)) {
                    s.err(name_loc, "no member named '{s}' in '{s}'", .{ name, s.typeName(b.ty) });
                    return err_typed;
                };
                return .{ .ty = TypeTable.error_type, .callee = .{ .method = .{ .object = b.ty, .name = name, .object_lvalue = b.lvalue } } };
            },
            .stream, .patch => return .{ .ty = TypeTable.error_type, .callee = .{ .method = .{ .object = b.ty, .name = name, .object_lvalue = b.lvalue } } },
            else => {
                s.err(name_loc, "member reference base type '{s}' is not a structure", .{s.typeName(b.ty)});
                return err_typed;
            },
        }
    }

    /// A resource index converts to `uint<dims>`: exactly `dims`
    /// components (no splat or truncation in overload resolution).
    fn indexMatches(s: *Sema, index: TypeId, dims: u8) bool {
        if (index == TypeTable.error_type) return true;
        const sh = s.types.shape(index) orelse return true; // reported elsewhere
        return sh.kind != .matrix and sh.count() == dims;
    }

    fn noViableSubscript(s: *Sema, loc: Loc, ty: TypeId) Typed {
        s.err(loc, "no viable overloaded operator[] for type '{s}'", .{s.typeName(ty)});
        return err_typed;
    }

    fn indexExpr(s: *Sema, e: *ast.Expr, base: *ast.Expr, index: *ast.Expr) Allocator.Error!Typed {
        const b = try s.expr(base);
        const i = try s.expr(index);
        if (b.ty == TypeTable.error_type) return err_typed;
        if (i.ty != TypeTable.error_type and !s.types.isNumeric(i.ty)) {
            s.err(index.loc, "array subscript is not an integer", .{});
        }
        switch (s.types.get(b.ty)) {
            .array => |a| return .{ .ty = a.elem, .lvalue = b.lvalue, .read_only = b.read_only },
            .vector => |v| {
                if (s.evalInt(index)) |k| if (k < 0 or k >= v.len) {
                    s.err(index.loc, "vector element index '{d}' is out of bounds", .{k});
                    return err_typed;
                };
                return .{ .ty = try s.types.scalar(v.elem), .lvalue = b.lvalue, .read_only = b.read_only };
            },
            .matrix => |m| {
                if (s.evalInt(index)) |k| if (k < 0 or k >= m.rows) {
                    s.err(index.loc, "matrix row index '{d}' is out of bounds", .{k});
                    return err_typed;
                };
                return .{ .ty = try s.types.vector(m.elem, m.cols), .lvalue = b.lvalue, .read_only = b.read_only };
            },
            .resource => |r| {
                if (r.kind.indexDims() == 0 or r.elem == TypeTable.void_type) {
                    if (r.kind == .other) return err_typed;
                    s.err(e.loc, "type '{s}' does not provide a subscript operator", .{s.typeName(b.ty)});
                    return err_typed;
                }
                if (!s.indexMatches(i.ty, r.kind.indexDims())) return s.noViableSubscript(e.loc, b.ty);
                return .{ .ty = r.elem, .lvalue = true, .read_only = !r.kind.isWritable() };
            },
            .texture_view => |v| {
                const tex = s.types.get(v.texture).resource;
                switch (v.kind) {
                    .mips, .sample => {
                        if (!s.indexMatches(i.ty, 1)) return s.noViableSubscript(e.loc, b.ty);
                        return rvalue(try s.types.intern(.{ .texture_view = .{ .texture = v.texture, .kind = if (v.kind == .mips) .mips_slice else .sample_slice } }));
                    },
                    .mips_slice, .sample_slice => {
                        if (!s.indexMatches(i.ty, tex.kind.indexDims())) return s.noViableSubscript(e.loc, b.ty);
                        return .{ .ty = tex.elem, .lvalue = true, .read_only = !tex.kind.isWritable() };
                    },
                }
            },
            .patch => |p| return .{ .ty = p.elem, .lvalue = true, .read_only = !p.output },
            .descriptor_heap => return rvalue(try s.types.intern(.dynamic_resource)),
            // Structs declaring operator[] were already reported as
            // milestone 0.2 at the declaration.
            .@"struct" => |info| {
                if (i.ty != TypeTable.error_type) if (try s.operatorCall(e, b.ty, "operator[]", &.{s.argInfo(index, i)})) |rt| return rvalue(rt);
                if (!info.overloadsOperators()) s.err(e.loc, "type '{s}' does not provide a subscript operator", .{s.typeName(b.ty)});
                return err_typed;
            },
            else => {
                s.err(e.loc, "subscripted value is not an array, matrix, or vector", .{});
                return err_typed;
            },
        }
    }

    fn constructExpr(s: *Sema, e: *ast.Expr, ty_ref: *const ast.TypeRef, args: []const *ast.Expr) Allocator.Error!Typed {
        const target = try s.resolveType(ty_ref);
        var total: u32 = 0;
        var any_error = false;
        for (args) |a| {
            const t = try s.expr(a);
            if (t.ty == TypeTable.error_type) {
                any_error = true;
                continue;
            }
            total += s.types.componentCount(t.ty) orelse blk: {
                if (s.types.isNumeric(target)) {
                    s.err(a.loc, "'{s}' cannot be used to construct '{s}'", .{ s.typeName(t.ty), s.typeName(target) });
                    any_error = true;
                }
                break :blk 0;
            };
        }
        if (target == TypeTable.error_type or any_error) return rvalue(target);
        if (!s.types.isNumeric(target)) return rvalue(target); // vk::BufferPointer(addr) and other objects
        switch (s.types.get(target)) {
            .scalar, .vector, .matrix => {
                const want = s.types.componentCount(target).?;
                // `float4(x)` with a scalar splats; otherwise counts must match.
                if (total != want and !(args.len == 1 and total == 1)) {
                    if (total < want) {
                        s.err(e.loc, "too few elements in vector initialization (expected {d} elements, have {d})", .{ want, total });
                    } else {
                        s.err(e.loc, "too many elements in vector initialization (expected {d} elements, have {d})", .{ want, total });
                    }
                }
            },
            else => {},
        }
        return rvalue(target);
    }

    // ------------------------------------------------------------------
    // Calls

    fn callExpr(s: *Sema, e: *ast.Expr, callee: *ast.Expr, args: []const *ast.Expr, template_args: []const ast.TemplateArg) Allocator.Error!Typed {
        const c = try s.expr(callee);
        var arg_types = try s.arena.alloc(intrinsics.ArgInfo, args.len);
        for (args, 0..) |a, i| {
            const t = try s.expr(a);
            arg_types[i] = .{ .ty = t.ty, .lvalue = t.lvalue and !t.read_only, .loc = a.loc, .groupshared = s.isGroupshared(a) };
        }
        const target = c.callee orelse {
            if (s.types.get(c.ty) == .@"struct") {
                for (arg_types) |a| if (a.ty == TypeTable.error_type) return err_typed;
                if (try s.operatorCall(e, c.ty, "operator()", arg_types)) |rt| return rvalue(rt);
                if (!s.types.get(c.ty).@"struct".overloadsOperators()) s.err(callee.loc, "type '{s}' does not provide a call operator", .{s.typeName(c.ty)});
            } else if (c.ty != TypeTable.error_type) s.err(callee.loc, "called object type '{s}' is not a function", .{s.typeName(c.ty)});
            return err_typed;
        };
        for (arg_types) |a| if (a.ty == TypeTable.error_type) return err_typed;
        switch (target) {
            .functions => |set| return rvalue(s.resolveUserCall(e, set, arg_types, callee)),
            .template => |set| return rvalue(try s.callTemplate(e, set, template_args, arg_types, callee)),
            .intrinsic => |name| {
                var explicit: ?TypeId = null;
                if (template_args.len > 0) explicit = try s.typeArg(template_args[0]);
                const r = try s.intrinsic_db.resolve(s, e.loc, if (s.opts.spirv and isVkQualified(callee)) "VkIntrinsics" else "Intrinsics", name, null, arg_types, explicit);
                if (r.ok) s.record(e, .{ .intrinsic = .{ .index = r.index, .params = r.params } });
                return rvalue(r.ret);
            },
            .method => |m| {
                switch (s.types.get(m.object)) {
                    .@"struct" => |info| {
                        const ss: *StructSema = @ptrCast(@alignCast(info.sema.?));
                        const sym = structMember(ss, m.name) orelse return err_typed;
                        if (sym != .functions) return err_typed;
                        return rvalue(s.resolveUserCall(e, sym.functions, arg_types, callee));
                    },
                    else => {
                        var explicit: ?TypeId = null;
                        if (template_args.len > 0) explicit = try s.typeArg(template_args[0]);
                        const ns = methodNamespace(s.types.get(m.object)) orelse return err_typed;
                        const r = try s.intrinsic_db.resolve(s, e.loc, ns, m.name, m.object, arg_types, explicit);
                        if (r.ok) s.record(e, .{ .intrinsic = .{ .index = r.index, .params = r.params, .object = m.object } });
                        return rvalue(r.ret);
                    },
                }
            },
            .unknown => return err_typed,
            .type => |t| {
                // `T(args)` with a user type: only a single-argument cast.
                if (args.len == 1) {
                    if (!s.explicitConvertible(arg_types[0].ty, t)) s.err(e.loc, "cannot convert from '{s}' to '{s}'", .{ s.typeName(arg_types[0].ty), s.typeName(t) });
                    return rvalue(t);
                }
                return rvalue(t);
            },
        }
    }

    /// Overload resolution among user functions by conversion cost.
    fn resolveUserCall(s: *Sema, e: *ast.Expr, set: *FuncSet, args: []const intrinsics.ArgInfo, callee: *ast.Expr) TypeId {
        var best: ?*Function = null;
        var best_cost: u32 = std.math.maxInt(u32);
        var ambiguous = false;
        for (set.funcs.items) |f| {
            if (args.len > f.params.len) continue;
            var required: usize = 0;
            for (f.params) |p| {
                if (!p.has_default) required += 1;
            }
            if (args.len < required) continue;
            var cost: u32 = 0;
            var ok = true;
            for (args, 0..) |a, i| {
                const p = f.params[i];
                const c = s.conversionCost(a.ty, p.type);
                // groupshared parameters bind only groupshared arguments
                // (and are preferred for them).
                if (c == null or (p.groupshared and !a.groupshared)) {
                    ok = false;
                    break;
                }
                cost += c.?;
                if (a.groupshared and !p.groupshared) cost += 1;
            }
            if (!ok) continue;
            if (cost < best_cost) {
                best = f;
                best_cost = cost;
                ambiguous = false;
            } else if (cost == best_cost) ambiguous = true;
        }
        const f = best orelse {
            const name = if (set.funcs.items.len > 0) set.funcs.items[0].name else "?";
            s.err(callee.loc, "no matching function for call to '{s}'", .{name});
            return TypeTable.error_type;
        };
        if (ambiguous) {
            s.err(callee.loc, "call to '{s}' is ambiguous", .{f.name});
            return TypeTable.error_type;
        }
        for (args, 0..) |a, i| {
            if (f.params[i].dir != .in and !a.lvalue) {
                s.err(a.loc, "cannot bind non-lvalue argument to {s} parameter", .{if (f.params[i].dir == .out) "out" else "inout"});
            }
        }
        if (s.current_fn) |caller| caller.callees.append(s.arena, f) catch {};
        s.record(e, .{ .function = f });
        return f.ret;
    }

    // ------------------------------------------------------------------
    // Conversions

    /// Cost of an implicit conversion (0: exact), or null if impossible.
    pub fn conversionCost(s: *Sema, from: TypeId, to: TypeId) ?u32 {
        if (from == to or from == TypeTable.error_type or to == TypeTable.error_type) return 0;
        const ft = s.types.get(from);
        const tt = s.types.get(to);
        const fc = s.types.component(from);
        const tc = s.types.component(to);
        if (fc != null and tc != null and (ft != .@"enum" or tt != .@"enum")) {
            if (tt == .@"enum" and (tt.@"enum".scoped or ft == .@"enum")) return null; // needs a cast
            const fs = s.types.shape(from).?;
            const ts = s.types.shape(to).?;
            var cost: u32 = if (fc.? == tc.?) 0 else if (fc.?.isLiteral()) 1 else if (fc.?.isFloat() == tc.?.isFloat() and tc.?.rank() > fc.?.rank()) 2 else 3;
            cost += switch (TypeTable.convertDimensions(ts, fs) orelse return null) {
                .identity => 0,
                .scalar => 1, // float1 -> float
                .splat => if (ts.count() == 1) 1 else 4,
                .conversion => 6, // vector <-> matrix of the same size
                .truncation => if (ts.count() == 1) 10 else 8,
            };
            return cost;
        }
        // A descriptor heap element converts to any resource or sampler.
        if (ft == .dynamic_resource and (tt == .resource or tt == .sampler)) return 0;
        // Derived structs convert to their bases.
        if (ft == .@"struct" and tt == .@"struct" and derivesFrom(ft.@"struct", tt.@"struct")) return 2;
        // int -> unscoped enum (dxc accepts it).
        if (tt == .@"enum" and !tt.@"enum".scoped and s.types.isNumeric(from) and ft != .@"enum") return 3;
        // ConstantBuffer<S> / TextureBuffer<S> are usable as an S value.
        if (ft == .resource and (ft.resource.kind == .constant_buffer or ft.resource.kind == .texture_buffer) and ft.resource.elem == to) return 1;
        return switch (ft) {
            .array => |fa| switch (tt) {
                .array => |ta| if ((ta.len == fa.len or ta.len == 0) and s.conversionCost(fa.elem, ta.elem) == 0) 0 else null,
                else => null,
            },
            .resource => |fr| switch (tt) {
                .resource => |tr| if (fr.kind == tr.kind and (fr.elem == tr.elem or tr.elem == TypeTable.void_type)) 0 else null,
                else => null,
            },
            else => null,
        };
    }

    fn hasUnmodelledMember(s: *Sema, ty: TypeId) bool {
        return switch (s.types.get(ty)) {
            .@"error" => true,
            .array => |a| s.hasUnmodelledMember(a.elem),
            .@"struct" => |info| for (info.fields.items) |f| {
                if (s.hasUnmodelledMember(f.type)) break true;
            } else false,
            else => false,
        };
    }

    fn explicitConvertible(s: *Sema, from: TypeId, to: TypeId) bool {
        if (to == TypeTable.void_type) return true;
        if (s.conversionCost(from, to) != null) return true;
        // Numeric casts follow the same shape rules as implicit ones.
        if (s.types.shape(from)) |fs| if (s.types.shape(to)) |ts| {
            return TypeTable.convertDimensions(ts, fs) != null;
        };
        // vk::BufferPointer and other opaque objects to / from integers.
        if (s.types.get(from) == .resource and s.types.get(from).resource.kind == .other and s.types.isNumeric(to)) return true;
        const fc = s.types.componentCount(from);
        const tc = s.types.componentCount(to);
        // Scalar to aggregate (`(S)0`), and flattening casts between
        // aggregates with enough components.
        if (fc == 1 and tc != null) return true;
        // Structs with members this checker does not model (long vectors).
        if (tc == null and s.types.get(to) == .@"struct" and s.hasUnmodelledMember(to)) return true;
        if (fc != null and tc != null and fc.? >= tc.?) return true;
        if (s.types.get(to) == .@"enum" and s.types.isNumeric(from)) return true;
        return false;
    }

    /// Check `e` as an initializer / assigned value for `target`.
    /// Checks `e` as an initializer of a `target` value; false after an
    /// error (the declaration is then invalid).
    pub fn checkInitializer(s: *Sema, target: TypeId, e: *ast.Expr) Allocator.Error!bool {
        if (e.kind == .init_list) {
            for (e.kind.init_list) |item| {
                if (item.kind != .init_list) _ = try s.expr(item) else _ = try s.checkInitializer(TypeTable.error_type, item);
            }
            e.ty = target;
            if (target == TypeTable.error_type) return true;
            const want = if (s.types.get(target) == .string) 1 else s.types.componentCount(target) orelse return true;
            const have = s.flatCount(e);
            if (have != want and have != 0) {
                if (have < want) {
                    s.err(e.loc, "too few elements in vector initialization (expected {d} element{s}, have {d})", .{ want, if (want == 1) "" else "s", have });
                } else {
                    s.err(e.loc, "too many elements in vector initialization (expected {d} element{s}, have {d})", .{ want, if (want == 1) "" else "s", have });
                }
                return false;
            }
            return true;
        }
        const t = try s.expr(e);
        if (t.callee != null and t.ty == TypeTable.error_type) {
            if (t.callee.? != .type) s.err(e.loc, "reference to overloaded function could not be resolved", .{});
            return false;
        }
        if (t.ty == TypeTable.error_type or target == TypeTable.error_type) return true;
        if (s.conversionCost(t.ty, target)) |_| {
            s.conversionWarnings(e, t.ty, target);
            return true;
        }
        s.err(e.loc, "cannot initialize a variable of type '{s}' with an {s} of type '{s}'", .{ s.typeName(target), if (t.lvalue) "lvalue" else "rvalue", s.typeName(t.ty) });
        return false;
    }

    /// dxc's err_hlsl_cannot_convert: "implicitly" only when an explicit
    /// cast would work.
    fn convertError(s: *Sema, loc: Loc, from: TypeId, to: TypeId) void {
        if (s.explicitConvertible(from, to)) {
            s.err(loc, "cannot implicitly convert from '{s}' to '{s}'", .{ s.typeName(from), s.typeName(to) });
        } else s.err(loc, "cannot convert from '{s}' to '{s}'", .{ s.typeName(from), s.typeName(to) });
    }

    fn conversionWarnings(s: *Sema, e: *ast.Expr, from: TypeId, to: TypeId) void {
        const fs = s.types.shape(from) orelse return;
        const ts = s.types.shape(to) orelse return;
        if (fs.kind != .scalar and (ts.rows < fs.rows or ts.cols < fs.cols)) {
            s.warn(e.loc, "conversion", "implicit truncation of vector type", .{});
        }
        const fc = s.types.component(from).?;
        const tc = s.types.component(to).?;
        if (fc == .literal_float and tc.isInt()) {
            if (s.evalConst(e)) |v| if (v == .float and v.float != @trunc(v.float)) {
                s.warn(e.loc, "literal-conversion", "implicit conversion from 'literal float' to '{s}' changes value from {d} to {d}", .{ tc.name(), v.float, @trunc(v.float) });
            };
        }
    }

    /// Number of scalars in an initializer list (nested lists flatten).
    fn flatCount(s: *Sema, e: *const ast.Expr) u32 {
        if (e.kind == .init_list) {
            var n: u32 = 0;
            for (e.kind.init_list) |item| n += s.flatCount(item);
            return n;
        }
        return s.types.componentCount(e.ty) orelse 1;
    }
};

// -------------------------------------------------------------------------
// Helpers

fn truthy(v: Sema.Const) bool {
    return switch (v) {
        .int => |x| x != 0,
        .float => |x| x != 0,
        .bool => |b| b,
    };
}

fn evalBinary(op: ast.BinaryOp, l: Sema.Const, r: Sema.Const) ?Sema.Const {
    if (op == .log_and) return .{ .bool = truthy(l) and truthy(r) };
    if (op == .log_or) return .{ .bool = truthy(l) or truthy(r) };
    const is_float = l == .float or r == .float;
    if (is_float) {
        const a: f64 = switch (l) {
            .int => |x| @floatFromInt(x),
            .float => |x| x,
            .bool => |b| @floatFromInt(@intFromBool(b)),
        };
        const b: f64 = switch (r) {
            .int => |x| @floatFromInt(x),
            .float => |x| x,
            .bool => |x| @floatFromInt(@intFromBool(x)),
        };
        return switch (op) {
            .add => .{ .float = a + b },
            .sub => .{ .float = a - b },
            .mul => .{ .float = a * b },
            .div => .{ .float = a / b },
            .lt => .{ .bool = a < b },
            .gt => .{ .bool = a > b },
            .le => .{ .bool = a <= b },
            .ge => .{ .bool = a >= b },
            .eq => .{ .bool = a == b },
            .ne => .{ .bool = a != b },
            else => null,
        };
    }
    const a: i64 = switch (l) {
        .int => |x| x,
        .bool => |b| @intFromBool(b),
        .float => unreachable,
    };
    const b: i64 = switch (r) {
        .int => |x| x,
        .bool => |x| @intFromBool(x),
        .float => unreachable,
    };
    return switch (op) {
        .add => .{ .int = a +% b },
        .sub => .{ .int = a -% b },
        .mul => .{ .int = a *% b },
        .div => if (b == 0) null else .{ .int = @divTrunc(a, b) },
        .rem => if (b == 0) null else .{ .int = @rem(a, b) },
        .shl => .{ .int = if (b < 0 or b >= 64) 0 else a << @intCast(b) },
        .shr => .{ .int = if (b < 0 or b >= 64) 0 else a >> @intCast(b) },
        .bit_and => .{ .int = a & b },
        .bit_or => .{ .int = a | b },
        .bit_xor => .{ .int = a ^ b },
        .lt => .{ .bool = a < b },
        .gt => .{ .bool = a > b },
        .le => .{ .bool = a <= b },
        .ge => .{ .bool = a >= b },
        .eq => .{ .bool = a == b },
        .ne => .{ .bool = a != b },
        else => null,
    };
}

pub fn parseIntLiteral(text: []const u8) ?i64 {
    var end = text.len;
    while (end > 0 and std.mem.indexOfScalar(u8, "uUlL", text[end - 1]) != null) end -= 1;
    const digits = text[0..end];
    if (digits.len == 0) return null;
    if (digits[0] == '\'') return if (digits.len >= 3) digits[1] else null;
    var base: u8 = 10;
    var body = digits;
    if (digits.len > 2 and digits[0] == '0' and (digits[1] == 'x' or digits[1] == 'X')) {
        base = 16;
        body = digits[2..];
    } else if (digits.len > 1 and digits[0] == '0') {
        base = 8;
        body = digits[1..];
    }
    const v = std.fmt.parseInt(u64, body, base) catch return null;
    return @bitCast(v);
}

pub fn parseFloatLiteral(text: []const u8) ?f64 {
    if (std.mem.indexOf(u8, text, ".#INF") != null) return std.math.inf(f64);
    var end = text.len;
    while (end > 0 and std.mem.indexOfScalar(u8, "fFhHlL", text[end - 1]) != null) end -= 1;
    return std.fmt.parseFloat(f64, text[0..end]) catch null;
}

/// The digits of a numeric literal (clang's NumericLiteralParser, with
/// dxc's `.#INF`): where the suffix starts and whether it is floating.
fn scanLiteral(text: []const u8) struct { end: usize, float: bool, inf: bool = false } {
    var i: usize = 0;
    const hex = text.len > 1 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X');
    if (hex) i = 2;
    const isDigit = struct {
        fn f(c: u8, h: bool) bool {
            return if (h) std.ascii.isHex(c) else std.ascii.isDigit(c);
        }
    }.f;
    while (i < text.len and isDigit(text[i], hex)) i += 1;
    var float = false;
    if (i < text.len and text[i] == '.') {
        float = true;
        i += 1;
        while (i < text.len and isDigit(text[i], hex)) i += 1;
    }
    const exp_chars: []const u8 = if (hex) "pP" else "eE";
    if (i < text.len and std.mem.indexOfScalar(u8, exp_chars, text[i]) != null) {
        var j = i + 1;
        if (j < text.len and (text[j] == '+' or text[j] == '-')) j += 1;
        if (j < text.len and std.ascii.isDigit(text[j])) {
            float = true;
            i = j;
            while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
        }
    }
    if (float and std.mem.startsWith(u8, text[i..], "#INF")) return .{ .end = i + 4, .float = true, .inf = true };
    return .{ .end = i, .float = float };
}

/// `f16` / `f32` / `f64` (any case) at the end of a float literal.
fn fixedFloatSuffix(text: []const u8) ?[]const u8 {
    if (text.len < 4) return null;
    const suf = text[text.len - 3 ..];
    if (suf[0] != 'f' and suf[0] != 'F') return null;
    for ([_][]const u8{ "16", "32", "64" }) |w| if (std.mem.eql(u8, suf[1..], w)) return suf;
    return null;
}

fn isIntSuffix(suffix: []const u8) bool {
    const valid = [_][]const u8{ "", "u", "l", "ul", "lu", "ll", "ull", "llu" };
    var buf: [3]u8 = undefined;
    if (suffix.len > buf.len) return false;
    const lower = std.ascii.lowerString(&buf, suffix);
    for (valid) |v| if (std.mem.eql(u8, v, lower)) return true;
    return false;
}

fn intLiteralType(text: []const u8) Scalar {
    if (text.len > 0 and text[0] == '\'') return .literal_int;
    var unsigned = false;
    var longs: u8 = 0;
    var i = text.len;
    while (i > 0) : (i -= 1) {
        switch (text[i - 1]) {
            'u', 'U' => unsigned = true,
            'l', 'L' => longs += 1,
            else => break,
        }
    }
    // dxc: `l` is 32-bit, `ll` is 64-bit.
    if (longs >= 2) return if (unsigned) .uint64 else .int64;
    if (longs == 1) return if (unsigned) .uint else .int;
    if (unsigned) return .uint;
    return .literal_int;
}

fn floatLiteralType(text: []const u8) Scalar {
    if (fixedFloatSuffix(text)) |suf| return switch (suf[1]) {
        '1' => .half, // f16: float16_t with 16-bit types
        '3' => .float,
        else => .double,
    };
    const last = text[text.len - 1];
    return switch (last) {
        'f', 'F' => .float,
        'h', 'H' => .half,
        'l', 'L' => .double,
        else => .literal_float,
    };
}

const Swizzle = struct { count: u8, repeats: bool };

/// `xyzw` / `rgba` swizzles (no mixing), up to 4 components.
fn parseSwizzle(name: []const u8, len: u8) ?Swizzle {
    if (name.len == 0 or name.len > 4) return null;
    const sets = [_][]const u8{ "xyzw", "rgba" };
    for (sets) |set| {
        var seen: u8 = 0;
        var repeats = false;
        var ok = true;
        for (name) |c| {
            const idx = std.mem.indexOfScalar(u8, set, c) orelse {
                ok = false;
                break;
            };
            if (idx >= len) {
                ok = false;
                break;
            }
            const bit = @as(u8, 1) << @intCast(idx);
            if (seen & bit != 0) repeats = true;
            seen |= bit;
        }
        if (ok) return .{ .count = @intCast(name.len), .repeats = repeats };
    }
    return null;
}

/// `_m00_m11` (zero-based) or `_11_22` (one-based) matrix subscripts.
fn parseMatrixSwizzle(name: []const u8, rows: u8, cols: u8) ?Swizzle {
    var i: usize = 0;
    var count: u8 = 0;
    var seen: u16 = 0;
    var repeats = false;
    var form: ?bool = null; // zero-based?
    while (i < name.len) {
        if (name[i] != '_') return null;
        i += 1;
        var zero_based = false;
        if (i < name.len and name[i] == 'm') {
            zero_based = true;
            i += 1;
        }
        if (form != null and form.? != zero_based) return null; // mixed forms
        form = zero_based;
        if (i + 2 > name.len) return null;
        var r: i32 = @as(i32, name[i]) - '0';
        var c: i32 = @as(i32, name[i + 1]) - '0';
        i += 2;
        if (!zero_based) {
            r -= 1;
            c -= 1;
        }
        if (r < 0 or c < 0 or r >= rows or c >= cols) return null;
        const bit = @as(u16, 1) << @intCast(r * 4 + c);
        if (seen & bit != 0) repeats = true;
        seen |= bit;
        count += 1;
        if (count > 4) return null;
    }
    if (count == 0) return null;
    return .{ .count = count, .repeats = repeats };
}

fn describeTarget(e: *const ast.Expr) []const u8 {
    return switch (e.kind) {
        .name => "variable",
        else => "expression",
    };
}

/// Struct member lookup that also searches base structs.
fn structMember(ss: *const StructSema, name: []const u8) ?Symbol {
    var sc: ?*Scope = ss.scope;
    while (sc) |c| : (sc = c.parent) {
        if (c.kind != .@"struct") return null;
        if (c.syms.get(name)) |sym| return sym;
    }
    return null;
}

/// Resources whose element type defaults to float4 when omitted.
fn isTextureOrTypedBuffer(k: types.ResourceKind) bool {
    return switch (k) {
        .buffer, .rw_buffer, .texture1d, .texture1d_array, .texture2d, .texture2d_array, .texture2dms, .texture2dms_array, .texture3d, .texture_cube, .texture_cube_array, .rw_texture1d, .rw_texture1d_array, .rw_texture2d, .rw_texture2d_array, .rw_texture2dms, .rw_texture2dms_array, .rw_texture3d => true,
        else => false,
    };
}

fn derivesFrom(derived: *const types.StructInfo, base: *const types.StructInfo) bool {
    for (derived.bases.items) |b| {
        if (b == base or derivesFrom(b, base)) return true;
    }
    return false;
}

fn isVkQualified(callee: *const ast.Expr) bool {
    return callee.kind == .name and callee.kind.name.parts.len > 1 and std.mem.eql(u8, callee.kind.name.parts[0], "vk");
}

fn isOtherBuiltinObject(n: []const u8) bool {
    const names = [_][]const u8{
        "RayQuery",                 "HitObject",                 "NodeOutput",                    "NodeOutputArray",
        "EmptyNodeOutput",          "EmptyNodeOutputArray",      "DispatchNodeInputRecord",       "RWDispatchNodeInputRecord",
        "GroupNodeInputRecords",    "RWGroupNodeInputRecords",   "ThreadNodeInputRecord",         "RWThreadNodeInputRecord",
        "EmptyNodeInput",           "GroupNodeOutputRecords",    "ThreadNodeOutputRecords",       "StateObjectConfig",
        "GlobalRootSignature",      "LocalRootSignature",        "SubobjectToExportsAssociation", "RaytracingShaderConfig",
        "RaytracingPipelineConfig", "RaytracingPipelineConfig1", "TriangleHitGroup",              "ProceduralPrimitiveHitGroup",
        "SubpassInput",             "SubpassInputMS",            "SpirvType",                     "SpirvOpaqueType",
        "Literal",                  "integral_constant",         "ext_type",                      "ext_result_id",
        "BufferPointer",            "SampledTexture2D",          "SampledTexture2DArray",         "SampledTexture1D",
        "SampledTexture1DArray",    "SampledTexture3D",          "SampledTextureCUBE",            "SampledTextureCUBEArray",
        "SampledTexture2DMS",       "SampledTexture2DMSArray",   "WorkgroupSpirvPointer",         "__builtin_LinAlgMatrix",
        "BuiltInTrianglePositions", "texture",                   "Texture",                       "auto",
    };
    for (names) |k| if (std.mem.eql(u8, k, n)) return true;
    return false;
}

/// Intrinsic-table namespace holding the methods of a builtin object type.
fn methodNamespace(t: types.Type) ?[]const u8 {
    return switch (t) {
        .stream => "StreamMethods",
        .resource => |r| switch (r.kind) {
            .buffer => "BufferMethods",
            .rw_buffer => "RWBufferMethods",
            .byte_address_buffer => "ByteAddressBufferMethods",
            .rw_byte_address_buffer => "RWByteAddressBufferMethods",
            .structured_buffer => "StructuredBufferMethods",
            .rw_structured_buffer => "RWStructuredBufferMethods",
            .append_structured_buffer => "AppendStructuredBufferMethods",
            .consume_structured_buffer => "ConsumeStructuredBufferMethods",
            .texture1d => "Texture1DMethods",
            .texture1d_array => "Texture1DArrayMethods",
            .texture2d => "Texture2DMethods",
            .texture2d_array => "Texture2DArrayMethods",
            .texture2dms => "Texture2DMSMethods",
            .texture2dms_array => "Texture2DArrayMSMethods",
            .texture3d => "Texture3DMethods",
            .texture_cube => "TextureCUBEMethods",
            .texture_cube_array => "TextureCUBEArrayMethods",
            .rw_texture1d => "RWTexture1DMethods",
            .rw_texture1d_array => "RWTexture1DArrayMethods",
            .rw_texture2d => "RWTexture2DMethods",
            .rw_texture2d_array => "RWTexture2DArrayMethods",
            .rw_texture2dms => "RWTexture2DMSMethods",
            .rw_texture2dms_array => "RWTexture2DMSArrayMethods",
            .rw_texture3d => "RWTexture3DMethods",
            .feedback_texture2d => "FeedbackTexture2DMethods",
            .feedback_texture2d_array => "FeedbackTexture2DArrayMethods",
            .constant_buffer, .texture_buffer, .raytracing_acceleration_structure => null,
            .other => null,
        },
        else => null,
    };
}

/// dxc's IsShaderProfileLike / IsShaderProfileShort: `ps_5_0`, `vs`.
fn isProfileLike(text: []const u8) bool {
    if (text.len == 2 and text[1] == 's' and std.mem.indexOfScalar(u8, "vpgc", text[0]) != null) return true;
    var underscore = false;
    var digit = false;
    var letter = false;
    for (text) |c| switch (c) {
        '0'...'9' => digit = true,
        'a'...'z' => letter = true,
        '_' => underscore = true,
        else => return false,
    };
    return underscore and digit and letter;
}

fn templateArgLoc(arg: ast.TemplateArg) Loc {
    return switch (arg) {
        .expr => |e| e.loc,
        .type => |t| t.loc,
    };
}

pub fn interpOf(q: ast.Qualifiers) types.Interp {
    return .{ .nointerpolation = q.nointerpolation, .linear = q.linear, .centroid = q.centroid, .sample = q.sample, .noperspective = q.noperspective };
}

fn isRowMajor(a: TypeAttrs) bool {
    return if (a.orientation) |o| eql(o, "row_major") else false;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ----------------------------------------------------------------------
// Tests

const testing = std.testing;

/// Runs Sema over `text` (a library: no entry point) and checks every
/// diagnostic, in source order, as "line: severity: message".
fn expectDiags(text: []const u8, opts: Options, expected: []const []const u8) !void {
    const gpa = testing.allocator;
    var mfs: source.MemoryFs = .{};
    var sm: source.SourceManager = .init(gpa, mfs.fileSystem());
    defer sm.deinit();
    var diags: diag.Diagnostics = .init(gpa);
    defer diags.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var pp = @import("../front/preproc.zig").Preprocessor.init(a, &sm, &diags, .{});
    try pp.enterMainText("t.hlsl", text);
    var p = try @import("../front/parser.zig").Parser.fromPreprocessor(a, &diags, &pp);
    const tu = try p.parseTranslationUnit();
    var s = try Sema.init(a, &diags, opts);
    try s.checkUnit(tu);
    var got: std.ArrayList([]const u8) = .empty;
    for (diags.sorted()) |d| {
        try got.append(a, try std.fmt.allocPrint(a, "{d}: {s}: {s}", .{ sm.presumedLoc(d.loc).line, @tagName(d.severity), d.message }));
    }
    const joined_got = try std.mem.join(a, "\n", got.items);
    const joined_want = try std.mem.join(a, "\n", expected);
    try testing.expectEqualStrings(joined_want, joined_got);
}

test "operator result types follow dxc's CombineBasicTypes" {
    try expectDiags(
        \\int i; uint u; half h; min16int m16i; min16uint m16u; min12int m12i; min10float m10f; min16float m16f; bool b;
        \\_Static_assert(std::is_same<uint, __decltype(i ^ m16u)>::value, "");
        \\_Static_assert(std::is_same<float, __decltype(h - i)>::value, "");
        \\_Static_assert(std::is_same<half, __decltype(h * 2.0)>::value, "");
        \\_Static_assert(std::is_same<float, __decltype(h - m16f)>::value, "");
        \\_Static_assert(std::is_same<min16int, __decltype(m12i + m16i)>::value, "");
        \\_Static_assert(std::is_same<min16float, __decltype(m10f - m16f)>::value, "");
        \\_Static_assert(std::is_same<min16uint, __decltype(b + m16u)>::value, "");
        \\_Static_assert(std::is_same<int, __decltype(b & b)>::value, "");
        \\_Static_assert(std::is_same<int, __decltype(i << u)>::value, "");
        \\_Static_assert(std::is_same<min12int, __decltype(m12i << u)>::value, "");
        \\_Static_assert(std::is_same<int, __decltype(b << m16i)>::value, "");
        \\_Static_assert(std::is_same<uint, __decltype(1 << u)>::value, "");
        \\_Static_assert(std::is_same<float2, __decltype(float2(1, 2) * i)>::value, "wrong");
        \\_Static_assert(std::is_same<int, __decltype(i)>::value, "fails");
        \\_Static_assert(std::is_same<uint, __decltype(i)>::value, "fails");
    , .{}, &.{
        "13: warning: ambiguous type for bit shift; use a type suffix on literal values, like 'L' or 'U', or a cast",
        "16: error: static_assert failed \"fails\"",
    });
}

test "literal suffixes" {
    try expectDiags(
        \\_Static_assert(std::is_same<int, __decltype(2l)>::value, "");
        \\_Static_assert(std::is_same<int64_t, __decltype(2ll)>::value, "");
        \\_Static_assert(std::is_same<uint, __decltype(2ul)>::value, "");
        \\_Static_assert(std::is_same<uint64_t, __decltype(2ull)>::value, "");
        \\_Static_assert(std::is_same<float, __decltype(1.5h)>::value, "");
        \\_Static_assert(0x7f800000 == asuint(1.#INF), "");
        \\_Static_assert(max(1, -2) == 1, "");
        \\float a = 1#INF;
        \\float b = 1.#INFI;
    , .{}, &.{
        "8: error: invalid suffix '#INF' on integer constant",
        "9: error: invalid suffix 'I' on floating constant",
    });
    try expectDiags(
        \\_Static_assert(std::is_same<half, float16_t>::value, "");
        \\_Static_assert(std::is_same<float16_t, __decltype(1.5h)>::value, "");
    , .{ .enable_16bit = true }, &.{});
}

test "declaration modifiers" {
    try expectDiags(
        \\void f(nointerpolation linear sample float2 g, point line float a, uniform out float b) {}
        \\extern static float2 g_ext_sta;
        \\typedef extern float2 t_ext;
        \\typedef uniform float2 t_uni;
        \\groupshared extern float g_gro_ext;
        \\struct S { const float c; linear float l; static const float k = 1; };
        \\void g() { in float x; groupshared float y; linear float z; }
        \\row_major float3 notMatrix;
        \\row_major column_major float2x2 both;
        \\linear sample centroid float2 h(float2 p : P) : SV_Target { return p; }
    , .{}, &.{
        "1: error: 'nointerpolation' and 'sample' cannot be used together for a parameter",
        "1: error: 'point' and 'line' cannot be used together for a parameter",
        "1: error: 'out' and 'uniform' cannot be used together for a parameter",
        "2: error: cannot combine with previous 'extern' declaration specifier",
        "3: error: cannot combine with previous 'typedef' declaration specifier",
        "4: error: 'uniform' is not a valid modifier for a typedef",
        "5: error: 'extern' and 'groupshared' cannot be used together for a global variable",
        "6: error: 'const' is not a valid modifier for a field",
        "7: error: HLSL usage 'in' is only valid on a parameter",
        "7: error: 'groupshared' is not a valid modifier for a local variable",
        "7: error: 'linear' is not a valid modifier for a local variable",
        "8: error: 'row_major' can only be used with a matrix type",
        "9: error: 'row_major' and 'column_major' attributes are not compatible",
        "10: warning: 'centroid' will be overridden by 'sample'",
    });
}

test "valid code has no diagnostics" {
    try expectDiags(
        \\struct Base { float a; float get() { return a; } };
        \\struct Derived : Base { float b; };
        \\enum E { A, B };
        \\cbuffer C : register(b0) { float4 tint; row_major float4x4 m; };
        \\Texture2D<float4> tex : register(t0);
        \\SamplerState samp : register(s0);
        \\RWStructuredBuffer<uint> buf : register(u0);
        \\groupshared float shared_data[64];
        \\float use(Base b) { return b.get(); }
        \\float4 main(float2 uv : TEXCOORD, nointerpolation uint id : ID) : SV_Target {
        \\  Derived d; d.a = 1; d.b = 2;
        \\  E e = A;
        \\  auto k = uv.x * 2;
        \\  uint n = asuint(k) >> 3u;
        \\  InterlockedAdd(buf[id], n);
        \\  float4 c = tex.Sample(samp, uv) * tint;
        \\  c.xyz = mul(m, c).xyz + max(c.rgb, 0.5);
        \\  return c * use((Base)d) * (e == B ? 2.0 : 1.0);
        \\}
    , .{}, &.{});
}

test "operator checks follow CheckBinOpForHLSL" {
    try expectDiags(
        \\struct S { float a; };
        \\Texture2D t;
        \\void f(S x, S y, float a[2], float b[2], bool bb, min16int m, double d, int e, float2x4 mat, float2 v, float4x4 m44, float4x1 m41) {
        \\  x + y;
        \\  x == y;
        \\  t == t;
        \\  a == b;
        \\  bb += true;
        \\  bb |= true;
        \\  m / m;
        \\  d % d;
        \\  ~1.5;
        \\  e << 1.5;
        \\  v = mat;
        \\  m44 += m41;
        \\  v + mat;
        \\  x[0];
        \\}
    , .{}, &.{
        "4: error: scalar, vector, or matrix expected",
        "5: error: operator cannot be used with user-defined type 'S'",
        "6: error: operator cannot be used with built-in type 'Texture2D<vector<float, 4> >'",
        "7: error: equality operators cannot be used with array types",
        "8: error: operator cannot be used with a bool lvalue",
        "10: error: signed integer division is not supported on minimum-precision types, cast to int to use 32-bit division",
        "11: error: modulo cannot be used with doubles, cast to float first",
        "12: error: int or unsigned int type required",
        "13: error: int or unsigned int type required",
        "14: error: cannot convert from 'matrix<float, 2, 4>' to 'vector<float, 2>'",
        "15: error: cannot convert from 'matrix<float, 4, 1>' to 'matrix<float, 4, 4>'",
        "16: error: cannot convert from 'matrix<float, 2, 4>' to 'vector<float, 2>'",
        "17: error: type 'S' does not provide a subscript operator",
    });
}

test "registers, resource indexing and type attributes" {
    try expectDiags(
        \\Texture2D<float4> t : register(u0);
        \\RWBuffer<float> rw : register(t1);
        \\float4 c : register(x0);
        \\SamplerState s0 : register(s0) : register(s1);
        \\Buffer<float4> b;
        \\Buffer<float3x3> bm;
        \\typedef column_major float4x4 cm;
        \\typedef row_major cm rcm;
        \\matrix<snorm unorm float, 2, 2> sn;
        \\float4 f() {
        \\  float4 r = b[int2(1, 2)];
        \\  r += t.mips[0][1];
        \\  float2 v; v[2] = 1;
        \\  return r + t.Bogus;
        \\}
    , .{}, &.{
        "1: error: invalid register specification, expected 't' or 's' binding",
        "2: error: invalid register specification, expected 'u' binding",
        "3: error: register type is unsupported - available types are 'b', 'c', 'i', 's', 't', 'u'",
        "4: error: conflicting register semantics",
        "6: error: elements of typed buffers and textures must be scalars or vectors",
        "8: error: 'row_major' and 'column_major' attributes are not compatible",
        "9: error: 'unorm' and 'snorm' attributes are not compatible",
        "11: error: no viable overloaded operator[] for type 'Buffer<vector<float, 4> >'",
        "12: error: no viable overloaded operator[] for type 'Texture2D<vector<float, 4> >::mips_slice_type'",
        "13: error: vector element index '2' is out of bounds",
        "14: error: no member named 'Bogus' in 'Texture2D<vector<float, 4> >'",
    });
}

test "recursion is reported from exported functions" {
    try expectDiags(
        \\void recurse(inout float4 f) { recurse(f); }
        \\export void entry(inout float4 f) { recurse(f); }
    , .{}, &.{
        "1: error: recursive functions are not allowed: function 'entry' calls recursive function 'recurse'",
    });
}
