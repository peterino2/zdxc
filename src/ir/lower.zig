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
        for (members.items) |mv| try info.fields.append(l.arena, .{ .name = mv.name, .type = mv.type });
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
        const fs = t.shape(inst.ty) orelse return v; // objects, structs: same type
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
        // Shape first, in the source component type.
        var cur = v;
        if (fs.count() == 1 and ts.count() > 1) {
            const sc = if (fs.kind == .scalar) cur else try l.b.add(.{ .op = .{ .extract = .{ .agg = cur, .index = 0 } }, .ty = try t.scalar(t.component(inst.ty).?) });
            const conv = try l.convert(sc, try t.scalar(tc));
            return l.b.add(.{ .op = .{ .splat = conv }, .ty = target });
        }
        if (ts.kind == .scalar and fs.kind != .scalar) {
            cur = try l.b.add(.{ .op = .{ .extract = .{ .agg = cur, .index = 0 } }, .ty = try t.scalar(t.component(inst.ty).?) });
        } else if (ts.kind == .vector and fs.kind == .vector and ts.cols < fs.cols) {
            const comps = try l.arena.alloc(u8, ts.cols);
            for (comps, 0..) |*c, i| c.* = @intCast(i);
            cur = try l.b.add(.{ .op = .{ .shuffle = .{ .vec = cur, .components = comps } }, .ty = try t.vector(t.component(inst.ty).?, ts.cols) });
        } else if (fs.kind != ts.kind or fs.rows != ts.rows or fs.cols != ts.cols) {
            if (!(fs.count() == 1 and ts.count() == 1)) {
                l.unsupported(.none, "conversion from '{s}' to '{s}' is not supported yet", .{ l.s.typeName(inst.ty), l.s.typeName(target) });
                return error.Unsupported;
            }
            if (fs.kind != .scalar) cur = try l.b.add(.{ .op = .{ .extract = .{ .agg = cur, .index = 0 } }, .ty = try t.scalar(t.component(inst.ty).?) });
        }
        const cur_ty = l.b.f.inst(cur).ty;
        if (cur_ty == target) return cur;
        const same_shape_target = try t.withComponent(cur_ty, tc);
        if (same_shape_target != cur_ty) cur = try l.b.add(.{ .op = .{ .convert = cur }, .ty = same_shape_target });
        if (same_shape_target != target) {
            // float1 <-> float
            if (ts.kind == .scalar) return l.b.add(.{ .op = .{ .extract = .{ .agg = cur, .index = 0 } }, .ty = target });
            return l.b.add(.{ .op = .{ .construct = try l.arena.dupe(Ref, &.{cur}) }, .ty = target });
        }
        return cur;
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
        // Explicit casts additionally allow truncation to fewer components,
        // which `convert` already performs.
        return l.convert(v, target);
    }

    fn construct(l: *Lowerer, e: *ast.Expr, ty: TypeId, args: []const *ast.Expr) Error!Ref {
        const t = l.types();
        const comp = t.component(ty) orelse return l.fail(e, "this constructor");
        const scalar_ty = try t.scalar(comp);
        var comps: std.ArrayList(Ref) = .empty;
        for (args) |a| {
            const v = try l.rvalue(a);
            const vt = l.b.f.inst(v).ty;
            const n = t.componentCount(vt) orelse return l.fail(a, "this constructor argument");
            if (t.get(vt) == .scalar or t.get(vt) == .@"enum") {
                try comps.append(l.arena, try l.convert(v, scalar_ty));
            } else {
                const ec = try t.scalar(t.component(vt).?);
                for (0..n) |i| {
                    const x = try l.b.add(.{ .op = .{ .extract = .{ .agg = v, .index = @intCast(i) } }, .ty = ec });
                    try comps.append(l.arena, try l.convert(x, scalar_ty));
                }
            }
        }
        if (t.get(ty) == .scalar) return comps.items[0];
        if (comps.items.len == 1) return l.b.add(.{ .op = .{ .splat = comps.items[0] }, .ty = ty });
        return l.b.add(.{ .op = .{ .construct = comps.items }, .ty = ty });
    }

    fn initList(l: *Lowerer, e: *ast.Expr, ty: TypeId) Error!Ref {
        const t = l.types();
        if (t.shape(ty) == null) return l.fail(e, "this initializer list");
        // Flatten the list's scalars into a constructor of `ty`.
        var flat: std.ArrayList(*ast.Expr) = .empty;
        try flattenList(l.arena, e, &flat);
        return l.construct(e, ty, flat.items);
    }

    fn member(l: *Lowerer, e: *ast.Expr, base: *ast.Expr, name: []const u8) Error!Ref {
        const t = l.types();
        const bt = t.get(base.ty);
        switch (bt) {
            .scalar, .vector => {
                const v = try l.rvalue(base);
                const comps = swizzleComponents(name) orelse return l.fail(e, "this swizzle");
                const ty = try l.concrete(e.ty);
                if (bt == .scalar) {
                    if (comps.len == 1) return v;
                    return l.b.add(.{ .op = .{ .splat = v }, .ty = ty });
                }
                if (comps.len == 1) return l.b.add(.{ .op = .{ .extract = .{ .agg = v, .index = comps[0] } }, .ty = ty });
                return l.b.add(.{ .op = .{ .shuffle = .{ .vec = v, .components = comps } }, .ty = ty });
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
                if (it.object) |_| {
                    const obj = callee.kind.member.base;
                    const res = try l.rvalue(obj);
                    const vals = try l.arena.alloc(Ref, args.len);
                    for (args, 0..) |a, i| vals[i] = try l.converted(a, try l.concrete(it.params[i]));
                    return l.b.add(.{ .op = .{ .method = .{ .name = name, .res = res, .args = vals } }, .ty = ret_ty });
                }
                const spec = table.intrinsics[it.index];
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
            .member => |m| if (t.get(m.base.ty) == .vector or t.get(m.base.ty) == .scalar) {
                // Swizzle store: read, replace the named components, write.
                const comps = swizzleComponents(m.name) orelse return error.Unsupported;
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
        try l.b.store(try l.lvalue(lhs), value);
    }

    // ------------------------------------------------------------------
    // Entry point

    fn buildEntry(l: *Lowerer, f: *const semamod.Function, main: u32, opts: Options) Error!void {
        var entry: ir.Entry = .{ .func = main, .name = opts.entry, .stage = opts.stage };
        for (f.decl.attrs) |a| {
            if (std.ascii.eqlIgnoreCase(a.name, "numthreads") and a.args.len == 3) {
                for (a.args, 0..) |arg, i| entry.num_threads[i] = @intCast(@max(1, l.s.evalInt(arg) orelse 1));
            }
        }
        const wrapper = try l.m.addFunction(.{ .name = opts.entry, .params = &.{}, .ret = TypeTable.void_type });
        l.b = .{ .m = &l.m, .f = l.m.functions.items[wrapper] };
        l.b.setBlock(try l.b.newBlock());
        const args = try l.arena.alloc(Ref, f.params.len);
        const locals = try l.arena.alloc(Ref, f.params.len);
        for (f.decl.params, f.params, 0..) |pd, p, i| {
            const sem = semanticOf(pd.semantics) orelse {
                l.unsupported(pd.name_loc, "entry parameter '{s}' needs a semantic", .{pd.name});
                return error.Unsupported;
            };
            locals[i] = try l.b.add(.{ .op = .local_var, .ty = p.type, .ptr = .function });
            if (p.dir != .out) {
                try entry.inputs.append(l.arena, sigElement(sem, p.type));
                const v = try l.b.add(.{ .op = .{ .input = @intCast(entry.inputs.items.len - 1) }, .ty = p.type });
                try l.b.store(locals[i], v);
            }
            args[i] = if (p.dir == .in) try l.b.load(locals[i]) else locals[i];
        }
        const ret = try l.b.add(.{ .op = .{ .call = .{ .func = main, .args = args } }, .ty = f.ret });
        if (f.ret != TypeTable.void_type) {
            const sem = semanticOf(f.decl.ret_semantics) orelse {
                l.unsupported(f.loc, "entry return value needs a semantic", .{});
                return error.Unsupported;
            };
            try entry.outputs.append(l.arena, sigElement(sem, f.ret));
            _ = try l.b.add(.{ .op = .{ .output = .{ .element = @intCast(entry.outputs.items.len - 1), .value = ret } }, .ty = TypeTable.void_type });
        }
        for (f.decl.params, f.params, 0..) |pd, p, i| {
            if (p.dir == .in) continue;
            try entry.outputs.append(l.arena, sigElement(semanticOf(pd.semantics).?, p.type));
            const v = try l.b.load(locals[i]);
            _ = try l.b.add(.{ .op = .{ .output = .{ .element = @intCast(entry.outputs.items.len - 1), .value = v } }, .ty = TypeTable.void_type });
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
fn swizzleComponents(name: []const u8) ?[]const u8 {
    if (name.len == 0 or name.len > 4) return null;
    const static = struct {
        var buf: [16][4]u8 = undefined;
        var next: usize = 0;
    };
    const out = &static.buf[static.next % 16];
    static.next += 1;
    for (name, 0..) |c, i| {
        out[i] = switch (c) {
            'x', 'r' => 0,
            'y', 'g' => 1,
            'z', 'b' => 2,
            'w', 'a' => 3,
            else => return null,
        };
    }
    return out[0..name.len];
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
