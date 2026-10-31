//! Lowers a checked translation unit (AST plus Sema's types and
//! resolutions) to memory-form IR: the entry function, everything it
//! reaches, the globals it uses, and a parameterless wrapper that reads the
//! entry's inputs and writes its outputs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../front/ast.zig");
const ir = @import("ir.zig");
const semamod = @import("../sema/sema.zig");
const types = @import("../sema/types.zig");
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
    const entry_fn = for (s.all_functions.items) |f| {
        if (f.owner == null and f.defined and std.mem.eql(u8, f.name, opts.entry)) break f;
    } else {
        l.unsupported(.none, "missing entry point definition", .{});
        return error.Unsupported;
    };
    const main = try l.functionIndex(entry_fn);
    try l.drain();
    try l.buildEntry(entry_fn, main, opts);
    return l.m;
}

const Lowerer = struct {
    arena: Allocator,
    s: *Sema,
    m: ir.Module,
    funcs: std.AutoHashMapUnmanaged(*const semamod.Function, u32) = .empty,
    pending: std.ArrayList(*const semamod.Function) = .empty,
    globals: std.AutoHashMapUnmanaged(*const Variable, u32) = .empty,
    /// cbuffer globals by declaration (0: `$Globals`), and where each
    /// member variable lives.
    cbuffers: std.AutoHashMapUnmanaged(usize, u32) = .empty,
    cbuffer_members: std.AutoHashMapUnmanaged(*const Variable, struct { global: u32, field: u32 }) = .empty,

    // Per function.
    b: ir.Builder = undefined,
    vars: std.AutoHashMapUnmanaged(*const Variable, Ref) = .empty,
    loops: std.ArrayList(struct { brk: BlockId, cont: BlockId }) = .empty,
    ret_ty: TypeId = TypeTable.void_type,

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
        const params = try l.arena.alloc(ir.Param, f.params.len);
        for (f.params, params) |p, *out| out.* = .{ .name = p.name, .ty = p.type, .by_ref = p.dir != .in };
        const i = try l.m.addFunction(.{ .name = f.name, .params = params, .ret = f.ret });
        try l.funcs.put(l.arena, f, i);
        try l.pending.append(l.arena, f);
        return i;
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
        for (f.params, 0..) |p, i| {
            const pv = try l.b.add(.{ .op = .{ .param = @intCast(i) }, .ty = p.type, .ptr = if (p.dir != .in) .function else .none });
            const storage = if (p.dir != .in) pv else blk: {
                const local = try l.b.add(.{ .op = .local_var, .ty = p.type, .ptr = .function });
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
            .global_static, .constant => if (l.s.types.get(v.type) == .resource or l.s.types.get(v.type) == .sampler) .resource else .private,
            .global_uniform, .cbuffer => unreachable, // see cbufferMember
            else => unreachable,
        };
        var binding: ir.Binding = .{};
        if (v.decl) |d| for (d.semantics) |sem| {
            if (sem.kind != .register) continue;
            binding = parseBinding(sem.values);
        };
        try l.m.globals.append(l.arena, .{ .name = v.name, .ty = v.type, .space = space, .binding = binding });
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
        if (v.block) |b| {
            const cb = b.kind.cbuffer;
            if (cb.tbuffer) {
                l.unsupported(v.loc, "tbuffer variables are not supported yet", .{});
                return error.Unsupported;
            }
            name = cb.name;
            for (cb.members) |m| if (m.kind == .@"var") {
                if (l.s.decl_vars.get(&m.kind.@"var")) |mv| try members.append(l.arena, mv);
            };
            for (cb.semantics) |sem| if (sem.kind == .register) {
                binding = parseBinding(sem.values);
            };
        } else {
            for (l.s.uniform_globals.items) |g| {
                if (l.s.types.get(g.type) == .resource or l.s.types.get(g.type) == .sampler) continue;
                try members.append(l.arena, g);
            }
        }
        const info = try l.arena.create(@import("../sema/types.zig").StructInfo);
        info.* = .{ .name = name, .complete = true };
        for (members.items) |mv| try info.fields.append(l.arena, .{ .name = mv.name, .type = mv.type, .row_major = mv.row_major });
        const ty = try l.s.types.intern(.{ .@"struct" = info });
        try l.m.globals.append(l.arena, .{ .name = name, .ty = ty, .space = .cbuffer, .binding = binding });
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
                try l.loop(x.cond, x.inc, x.body, false);
            },
            .@"while" => |x| {
                if (x.cond_decl != null) {
                    l.unsupported(st.loc, "declarations in while conditions are not supported yet", .{});
                    return error.Unsupported;
                }
                try l.loop(x.cond, null, x.body, false);
            },
            .do_while => |x| try l.loop(x.cond, null, x.body, true),
            .@"break" => {
                const target = l.loops.getLast();
                l.b.terminate(.{ .br = target.brk });
            },
            .@"continue" => {
                const target = l.loops.getLast();
                l.b.terminate(.{ .br = target.cont });
            },
            .discard => l.b.terminate(.discard),
            .@"switch", .case, .default => {
                l.unsupported(st.loc, "switch statements are not supported yet", .{});
                return error.Unsupported;
            },
        }
    }

    /// header (loop merge) -> cond -> body -> continue (inc) -> header.
    /// `do` loops test at the end of the continue block.
    fn loop(l: *Lowerer, cond: ?*ast.Expr, inc: ?*ast.Expr, body: *const ast.Stmt, do_while: bool) Error!void {
        const header = try l.b.newBlock();
        const body_b = try l.b.newBlock();
        const cont = try l.b.newBlock();
        const merge = try l.b.newBlock();
        l.b.terminate(.{ .br = header });
        l.b.setBlock(header);
        l.b.f.block(header).merge = .{ .loop = .{ .merge = merge, .@"continue" = cont } };
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
                    l.unsupported(d.loc, "static locals are not supported yet", .{});
                    return error.Unsupported;
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
            .scalar, .@"enum" => try out.append(l.arena, v),
            .vector, .matrix => for (0..t.componentCount(ty).?) |k| try out.append(l.arena, try l.component(v, @intCast(k))),
            .array => |a| for (0..a.len) |i| try l.flatten(try l.b.add(.{ .op = .{ .extract = .{ .agg = v, .index = @intCast(i) } }, .ty = a.elem }), out),
            .@"struct" => |st| for (st.fields.items, 0..) |f, i| try l.flatten(try l.b.add(.{ .op = .{ .extract = .{ .agg = v, .index = @intCast(i) } }, .ty = f.type }), out),
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
                for (parts, st.fields.items) |*p, f| p.* = try l.fromFlat(f.type, comps, next);
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
                    .variable => return l.b.load(try l.lvalue(e)),
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
                const bt = t.get(x.base.ty);
                if (bt == .resource) {
                    const res = try l.rvalue(x.base);
                    const idx = try l.indexValue(x.index, bt.resource.kind.indexDims());
                    return l.b.add(.{ .op = .{ .res_load = .{ .res = res, .index = idx } }, .ty = try l.concrete(e.ty) });
                }
                if (isAddressable(x.base)) return l.b.load(try l.lvalue(e));
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
            .this, .init_list, .string_lit => return l.fail(e, "this expression"),
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
        const need = l.types().componentCount(ty) orelse return l.fail(e, "this initializer list");
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
            .@"struct" => {
                if (isAddressable(base)) return l.b.load(try l.lvalue(e));
                const v = try l.rvalue(base);
                const r = l.s.resolution(e) orelse return l.fail(e, "this member");
                return l.b.add(.{ .op = .{ .extract = .{ .agg = v, .index = r.field } }, .ty = e.ty });
            },
            else => return l.fail(e, "this member access"),
        }
    }

    fn call(l: *Lowerer, e: *ast.Expr, callee: *ast.Expr, args: []const *ast.Expr) Error!Ref {
        const r = l.s.resolution(e) orelse return l.fail(e, "this call");
        const ret_ty = try l.concrete(e.ty);
        switch (r) {
            .function => |f| {
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
                return l.userCall(f, fi, full, ret_ty);
            },
            else => return l.callOther(e, r, callee, args, ret_ty),
        }
    }

    fn userCall(l: *Lowerer, f: *const semamod.Function, fi: u32, args: []const *ast.Expr, ret_ty: TypeId) Error!Ref {
        {
            {
                const vals = try l.arena.alloc(Ref, args.len);
                const temps = try l.arena.alloc(Ref, args.len);
                for (args, f.params, 0..) |a, p, i| {
                    if (p.dir == .in) {
                        vals[i] = try l.converted(a, p.type);
                    } else {
                        // Copy-in / copy-out through a temporary.
                        temps[i] = try l.b.add(.{ .op = .local_var, .ty = p.type, .ptr = .function });
                        if (p.dir == .inout) try l.b.store(temps[i], try l.converted(a, p.type));
                        vals[i] = temps[i];
                    }
                }
                const res = try l.b.add(.{ .op = .{ .call = .{ .func = fi, .args = vals } }, .ty = ret_ty });
                for (args, f.params, 0..) |a, p, i| {
                    if (p.dir == .in) continue;
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
                const vals = try l.arena.alloc(Ref, args.len);
                for (args, 0..) |a, i| {
                    if (i < spec.params.len and spec.params[i].qual != .in) {
                        return l.fail(a, "out arguments of intrinsics");
                    }
                    vals[i] = try l.converted(a, try l.concrete(it.params[i]));
                }
                return l.b.add(.{ .op = .{ .intrinsic = .{ .name = name, .args = vals } }, .ty = ret_ty });
            },
            else => return l.fail(e, "this call"),
        }
    }

    /// Pointer to the storage `e` designates.
    fn lvalue(l: *Lowerer, e: *ast.Expr) Error!Ref {
        const t = l.types();
        switch (e.kind) {
            .name => {
                const r = l.s.resolution(e) orelse return l.fail(e, "this name");
                if (r != .variable) return l.fail(e, "this name");
                const v = r.variable;
                if (l.vars.get(v)) |p| return p;
                switch (v.storage) {
                    .local, .param, .local_static => return l.fail(e, "this variable"),
                    .global_uniform, .cbuffer => {
                        if (l.s.types.get(v.type) == .resource or l.s.types.get(v.type) == .sampler) {
                            l.unsupported(e.loc, "resource '{s}' declared as a uniform is not supported yet", .{v.name});
                            return error.Unsupported;
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
            },
            .member => |m| {
                const r = l.s.resolution(e) orelse return l.fail(e, "this member");
                if (r != .field) return l.fail(e, "this member");
                const base = try l.lvalue(m.base);
                const idx = try l.b.constInt(try t.scalar(.uint), r.field);
                return l.b.add(.{ .op = .{ .access = .{ .base = base, .indices = try l.arena.dupe(Ref, &.{idx}) } }, .ty = e.ty, .ptr = l.b.f.inst(base).ptr });
            },
            .index => |x| {
                const base = try l.lvalue(x.base);
                const idx = try l.converted(x.index, try t.scalar(.uint));
                return l.b.add(.{ .op = .{ .access = .{ .base = base, .indices = try l.arena.dupe(Ref, &.{idx}) } }, .ty = e.ty, .ptr = l.b.f.inst(base).ptr });
            },
            .cast => |c| return l.lvalue(c.operand),
            else => return l.fail(e, "this assignment target"),
        }
    }

    /// Stores `value` (already of `lhs`'s type) into what `lhs` designates.
    fn storeTo(l: *Lowerer, lhs: *ast.Expr, value: Ref) Error!void {
        const t = l.types();
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

        /// A field's modifiers, inheriting the enclosing interpolation.
        fn field(outer: SigAttrs, fld: Field) SigAttrs {
            const own: u8 = @bitCast(fld.interp);
            return .{ .interp = if (own != 0) fld.interp else outer.interp, .row_major = fld.row_major };
        }
    };

    fn withAttrs(el: ir.SigElement, attrs: SigAttrs) ir.SigElement {
        var r = el;
        r.interp = attrs.interp;
        r.row_major = attrs.row_major;
        return r;
    }

    /// An entry input of type `ty`: one signature element, or for structs
    /// without a semantic one per field (recursively).
    fn entryInput(l: *Lowerer, entry: *ir.Entry, ty: TypeId, semantic: ?[]const u8, attrs: SigAttrs, loc: ast.Loc, what: []const u8) Error!Ref {
        if (semantic) |sem| if (l.s.types.get(ty) == .@"struct") {
            // A semantic on a struct numbers its fields: X, X1, X2, ...
            var el = sigElement(sem, ty);
            return l.structInput(entry, ty, el.semantic, &el.semantic_index, attrs);
        };
        if (semantic) |sem| {
            try entry.inputs.append(l.arena, withAttrs(sigElement(sem, ty), attrs));
            return l.b.add(.{ .op = .{ .input = @intCast(entry.inputs.items.len - 1) }, .ty = ty });
        }
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
            try entry.inputs.append(l.arena, withAttrs(.{ .semantic = name, .semantic_index = index.*, .ty = fld.type, .system_value = std.ascii.startsWithIgnoreCase(name, "SV_") }, attrs.field(fld)));
            index.* += 1;
            p.* = try l.b.add(.{ .op = .{ .input = @intCast(entry.inputs.items.len - 1) }, .ty = fld.type });
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
            try entry.outputs.append(l.arena, withAttrs(.{ .semantic = name, .semantic_index = index.*, .ty = fld.type, .system_value = std.ascii.startsWithIgnoreCase(name, "SV_") }, attrs.field(fld)));
            index.* += 1;
            _ = try l.b.add(.{ .op = .{ .output = .{ .element = @intCast(entry.outputs.items.len - 1), .value = v } }, .ty = TypeTable.void_type });
        }
    }

    fn entryOutput(l: *Lowerer, entry: *ir.Entry, ty: TypeId, semantic: ?[]const u8, attrs: SigAttrs, value: Ref, loc: ast.Loc, what: []const u8) Error!void {
        if (semantic) |sem| if (l.s.types.get(ty) == .@"struct") {
            var el = sigElement(sem, ty);
            return l.structOutput(entry, ty, el.semantic, &el.semantic_index, value, attrs);
        };
        if (semantic) |sem| {
            try entry.outputs.append(l.arena, withAttrs(sigElement(sem, ty), attrs));
            _ = try l.b.add(.{ .op = .{ .output = .{ .element = @intCast(entry.outputs.items.len - 1), .value = value } }, .ty = TypeTable.void_type });
            return;
        }
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
        var inits: std.AutoHashMapUnmanaged(*const Variable, u32) = .empty;
        var changed = true;
        while (changed) {
            changed = false;
            for (l.s.static_globals.items) |v| {
                const init_e = v.init orelse continue;
                if (!l.globals.contains(v) or inits.contains(v)) continue;
                if (l.s.types.get(v.type) == .resource or l.s.types.get(v.type) == .sampler) continue;
                const fi = try l.m.addFunction(.{ .name = try std.fmt.allocPrint(l.arena, "init.{s}", .{v.name}), .params = &.{}, .ret = v.type });
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
        return inits;
    }

    fn buildEntry(l: *Lowerer, f: *const semamod.Function, main: u32, opts: Options) Error!void {
        const inits = try l.staticInits();
        var entry: ir.Entry = .{ .func = main, .name = opts.entry, .stage = opts.stage };
        for (f.decl.attrs) |a| {
            if (std.ascii.eqlIgnoreCase(a.name, "numthreads") and a.args.len == 3) {
                for (a.args, 0..) |arg, i| entry.num_threads[i] = @intCast(@max(1, l.s.evalInt(arg) orelse 1));
            }
        }
        const wrapper = try l.m.addFunction(.{ .name = opts.entry, .params = &.{}, .ret = TypeTable.void_type });
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
        for (f.decl.params, f.params, 0..) |pd, p, i| {
            locals[i] = try l.b.add(.{ .op = .local_var, .ty = p.type, .ptr = .function });
            if (p.dir != .out) {
                const v = try l.entryInput(&entry, p.type, semanticOf(pd.semantics), paramAttrs(pd.quals), pd.name_loc, pd.name);
                try l.b.store(locals[i], v);
            }
            args[i] = if (p.dir == .in) try l.b.load(locals[i]) else locals[i];
        }
        const ret = try l.b.add(.{ .op = .{ .call = .{ .func = main, .args = args } }, .ty = f.ret });
        if (f.ret != TypeTable.void_type) try l.entryOutput(&entry, f.ret, semanticOf(f.decl.ret_semantics), paramAttrs(f.decl.quals), ret, f.loc, "return value");
        for (f.decl.params, f.params, 0..) |pd, p, i| {
            if (p.dir == .in) continue;
            const v = try l.b.load(locals[i]);
            try l.entryOutput(&entry, p.type, semanticOf(pd.semantics), paramAttrs(pd.quals), v, pd.name_loc, pd.name);
        }
        l.b.terminate(.{ .ret = .none });
        entry.wrapper = wrapper;
        // The HLSL entry keeps its name with a prefix (as dxc's SPIR-V).
        l.m.functions.items[main].name = try std.fmt.allocPrint(l.arena, "src.{s}", .{opts.entry});
        l.m.entry = entry;
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
    };
}

/// `register(t3, space1)` -> class 't', index 3, space 1.
fn parseBinding(values: []const []const u8) ir.Binding {
    var b: ir.Binding = .{};
    for (values) |v| {
        if (std.mem.startsWith(u8, v, "space")) {
            b.space = std.fmt.parseInt(u32, v[5..], 10) catch 0;
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

fn isAddressable(e: *const ast.Expr) bool {
    return switch (e.kind) {
        .name => true,
        .member => |m| isAddressable(m.base),
        .index => |x| isAddressable(x.base),
        else => false,
    };
}

fn flattenList(a: Allocator, e: *ast.Expr, out: *std.ArrayList(*ast.Expr)) Allocator.Error!void {
    if (e.kind == .init_list) {
        for (e.kind.init_list) |item| try flattenList(a, item, out);
    } else try out.append(a, e);
}
