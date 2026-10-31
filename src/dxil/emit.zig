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
    return e.run(gpa);
}

/// A lowered IR value.
const Lowered = union(enum) {
    none,
    /// Flattened scalar components.
    scalars: []const Value,
    ptr: Ptr,
    /// A resource handle (index into Emitter.resources).
    handle: u32,
    /// A place in a constant buffer: byte offset plus a dynamic register
    /// offset.
    cbuf: struct { res: u32, offset: u32 = 0, dyn_regs: ?Value = null },
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
};

const Resource = struct {
    global: u32,
    class: Class,
    /// Index within its class (metadata and createHandle range id).
    id: u32 = 0,
    kind: u32,
    handle: Value = undefined,
    elem: TypeId,

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
};

const PInst = struct { inst: module.Inst, id: u32 };

const Emitter = struct {
    arena: Allocator,
    dm: module.Module,
    m: *const ir.Module,
    t: *TypeTable,
    profile: shader.Profile,
    diags: *diag.Diagnostics,

    main_fn: u32 = 0,
    /// Instructions per block, in creation order, with provisional ids.
    blocks: std.ArrayList(std.ArrayList(PInst)) = .empty,
    prologue: std.ArrayList(PInst) = .empty,
    next_id: u32 = 0,
    cur: u32 = 0,

    resources: std.ArrayList(Resource) = .empty,
    resource_of_global: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    uses_double: bool = false,
    uses_int64: bool = false,

    handle_ty: DType = 0,

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
            .int16, .uint16 => e.dm.intType(16),
            .int64, .uint64 => blk: {
                e.uses_int64 = true;
                break :blk e.dm.intType(64);
            },
            .float, .half, .min16float, .min10float, .literal_float => e.dm.getType(.float),
            .float16 => e.dm.getType(.half),
            .double => blk: {
                e.uses_double = true;
                break :blk e.dm.getType(.double);
            },
        };
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
        return storageScalar(e.t.component(ty) orelse .int);
    }

    /// Number of flattened scalar components of `ty`.
    fn flatCount(e: *Emitter, ty: TypeId) Error!u32 {
        return switch (e.t.get(ty)) {
            .scalar, .@"enum" => 1,
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
        const entry = m.entry orelse return e.unsupported("no entry point", .{});
        if (entry.stage != .compute) return e.unsupported("only compute shaders are supported yet", .{});
        const void_ty = try e.voidTy();
        const fn_ty = try e.dm.fnType(void_ty, &.{});
        e.main_fn = try e.dm.addFunction(.{ .name = entry.name, .ty = fn_ty, .num_blocks = 1 });
        const i8p = try e.dm.ptrType(try e.dm.intType(8));
        e.handle_ty = try e.dm.getType(.{ .@"struct" = .{ .name = "dx.types.Handle", .elems = &.{i8p} } });

        try e.collectResources();
        e.cur = try e.newBlock();
        try e.createHandles();
        _ = try e.inlineCall(entry.wrapper, &.{});
        try e.finish();

        const bitcode = try e.writeModule(entry);
        defer gpa.free(bitcode);
        return e.assemble(gpa, entry, bitcode);
    }

    fn collectResources(e: *Emitter) Error!void {
        var counts = [_]u32{ 0, 0, 0, 0 };
        // Constant buffers: `$Globals` first, then the others in order.
        for ([_]bool{ true, false }) |globals_pass| for (e.m.globals.items, 0..) |g, gi| {
            if (g.space != .cbuffer or std.mem.eql(u8, g.name, "$Globals") != globals_pass) continue;
            try e.resources.append(e.arena, .{ .global = @intCast(gi), .class = .cbuffer, .id = counts[2], .kind = 13, .elem = g.ty });
            counts[2] += 1;
            try e.resource_of_global.put(e.arena, @intCast(gi), @intCast(e.resources.items.len - 1));
        };
        for (e.m.globals.items, 0..) |g, gi| {
            if (g.space != .resource) continue;
            const r = switch (e.t.get(g.ty)) {
                .resource => |r| r,
                else => return e.unsupported("global '{s}' is not supported yet", .{g.name}),
            };
            const kind: u32 = switch (r.kind) {
                .structured_buffer, .rw_structured_buffer => 12,
                .byte_address_buffer, .rw_byte_address_buffer => 11,
                .buffer, .rw_buffer => 10,
                else => return e.unsupported("resource type '{s}' is not supported yet", .{r.name}),
            };
            const class: Resource.Class = if (r.kind.isWritable()) .uav else .srv;
            if (g.binding.explicit and g.binding.class != @as(u8, if (class == .uav) 'u' else 't')) {
                return e.unsupported("binding '{s}' to the wrong register class", .{g.name});
            }
            try e.resources.append(e.arena, .{ .global = @intCast(gi), .class = class, .id = counts[@backingInt(class)], .kind = kind, .elem = r.elem });
            counts[@backingInt(class)] += 1;
            try e.resource_of_global.put(e.arena, @intCast(gi), @intCast(e.resources.items.len - 1));
        }
        // Unbound resources take the next free register of their class.
        var used: std.AutoHashMapUnmanaged(struct { u8, u32, u32 }, void) = .empty;
        for (e.resources.items) |res| {
            const b = e.m.globals.items[res.global].binding;
            if (b.explicit) try used.put(e.arena, .{ @backingInt(res.class), b.space, b.index }, {});
        }
        for (e.resources.items) |res| {
            const g = &e.m.globals.items[res.global];
            if (g.binding.explicit) continue;
            var i: u32 = 0;
            while (used.contains(.{ @backingInt(res.class), g.binding.space, i })) i += 1;
            try used.put(e.arena, .{ @backingInt(res.class), g.binding.space, i }, {});
            // Globals are const in the module; record the chosen binding.
            @constCast(g).binding.index = i;
        }
    }

    fn binding(e: *Emitter, res: Resource) ir.Binding {
        return e.m.globals.items[res.global].binding;
    }

    fn createHandles(e: *Emitter) Error!void {
        const i32t = try e.dm.intType(32);
        const i1t = try e.dm.intType(1);
        const i8t = try e.dm.intType(8);
        if (self_sm66(e)) {
            const bind_ty = try e.dm.getType(.{ .@"struct" = .{ .name = "dx.types.ResBind", .elems = &.{ i32t, i32t, i32t, i8t } } });
            const props_ty = try e.dm.getType(.{ .@"struct" = .{ .name = "dx.types.ResourceProperties", .elems = &.{ i32t, i32t } } });
            const create = try e.dxOp("dx.op.createHandleFromBinding", e.handle_ty, &.{ i32t, bind_ty, i32t, i1t }, .nounwind_readnone);
            const annotate = try e.dxOp("dx.op.annotateHandle", e.handle_ty, &.{ i32t, e.handle_ty, props_ty }, .nounwind_readnone);
            for (e.resources.items) |*res| {
                const b = e.binding(res.*);
                const lb = try e.dm.constant(.{ .ty = i32t, .kind = .{ .int = b.index } });
                const space = try e.dm.constant(.{ .ty = i32t, .kind = .{ .int = b.space } });
                const cls = try e.dm.constant(.{ .ty = i8t, .kind = .{ .int = @backingInt(res.class) } });
                const bind = try e.dm.constant(.{ .ty = bind_ty, .kind = .{ .aggregate = try e.arena.dupe(module.ConstId, &.{ lb.constant, lb.constant, space.constant, cls.constant }) } });
                const raw = try e.addPrologue(e.handle_ty, .{ .call = .{ .callee = create, .args = try e.arena.dupe(Value, &.{ try e.i32Const(217), bind, try e.i32Const(b.index), try e.dm.constant(.{ .ty = i1t, .kind = .{ .int = 0 } }) }) } });
                const p = try e.resourceProperties(res.*);
                const p0 = try e.dm.constant(.{ .ty = i32t, .kind = .{ .int = p[0] } });
                const p1 = try e.dm.constant(.{ .ty = i32t, .kind = .{ .int = p[1] } });
                const props = try e.dm.constant(.{ .ty = props_ty, .kind = .{ .aggregate = try e.arena.dupe(module.ConstId, &.{ p0.constant, p1.constant }) } });
                res.handle = try e.addPrologue(e.handle_ty, .{ .call = .{ .callee = annotate, .args = try e.arena.dupe(Value, &.{ try e.i32Const(216), raw, props }) } });
            }
        } else {
            const create = try e.dxOp("dx.op.createHandle", e.handle_ty, &.{ i32t, i8t, i32t, i32t, i1t }, .nounwind_readonly);
            for (e.resources.items) |*res| {
                const b = e.binding(res.*);
                res.handle = try e.addPrologue(e.handle_ty, .{ .call = .{ .callee = create, .args = try e.arena.dupe(Value, &.{
                    try e.i32Const(57),
                    try e.dm.constant(.{ .ty = i8t, .kind = .{ .int = @backingInt(res.class) } }),
                    try e.i32Const(res.id),
                    try e.i32Const(b.index),
                    try e.dm.constant(.{ .ty = i1t, .kind = .{ .int = 0 } }),
                }) } });
            }
        }
    }

    fn self_sm66(e: *Emitter) bool {
        return e.profile.minor >= 6;
    }

    /// DxilResourceProperties for annotateHandle.
    fn resourceProperties(e: *Emitter, res: Resource) Error![2]i64 {
        var basic: i64 = res.kind;
        if (res.class == .uav) basic |= 0x1000;
        const extra: i64 = switch (res.kind) {
            13 => try e.cbufferSize(res),
            12 => try e.stride(res.elem),
            10 => blk: {
                const n = try e.flatCount(res.elem);
                break :blk try e.compType(e.compOf(res.elem)) | (@as(i64, n) << 8);
            },
            else => 0,
        };
        return .{ basic, extra };
    }

    /// Structured buffer element stride (tightly packed scalars).
    fn stride(e: *Emitter, ty: TypeId) Error!i64 {
        const n = try e.flatCount(ty);
        const c = try e.uniformScalar(ty);
        return @as(i64, n) * c.size();
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
            .bool => 1,
            .int64 => 6,
            .uint64 => 7,
            .double => 10,
            else => e.unsupported("typed buffers of this element type are not supported yet", .{}),
        };
    }

    /// Assigns final instruction indices: prologue first, then blocks in
    /// creation order.
    fn finish(e: *Emitter) Error!void {
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
        const f = &e.dm.functions.items[e.main_fn];
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

    fn remapInst(a: Allocator, map: []const u32, inst: module.Inst, comptime R: type) Allocator.Error!module.Inst {
        var out = inst;
        switch (out.op) {
            .ret => |*v| if (v.*) |x| {
                v.* = R.v(map, x);
            },
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
            .@"unreachable" => {},
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
        const is_entry = e.cur == 0 and e.blocks.items[0].items.len == 0 and fi == e.m.entry.?.wrapper;
        if (!is_entry) frame.cont = try e.newBlock();
        // The callee's entry continues the current block.
        frame.blocks[0] = e.cur;
        const reachable = try reachableBlocks(e.arena, f);
        for (f.blocks.items, 0..) |_, bi| {
            if (!reachable[bi]) continue;
            e.cur = try e.blockFor(&frame, @intCast(bi));
            try e.emitBlock(&frame, @intCast(bi));
        }
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
                    if (v != .none) try frame.rets.append(e.arena, .{ .block = e.cur, .vals = try e.scalars(frame, v) });
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
            .@"switch" => return e.unsupported("switch", .{}),
            .discard => return e.unsupported("discard", .{}),
        }
    }

    fn scalars(e: *Emitter, frame: *Frame, r: Ref) Error![]const Value {
        return switch (frame.vals[r.index()]) {
            .scalars => |s| s,
            else => e.unsupported("internal: expected a value", .{}),
        };
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
            .global => |g| {
                const ri = e.resource_of_global.get(g) orelse return e.unsupported("global '{s}' is not supported yet", .{e.m.globals.items[g].name});
                if (e.resources.items[ri].class == .cbuffer) return .{ .cbuf = .{ .res = ri } };
                return .{ .handle = ri };
            },
            .local_var => {
                const n = try e.flatCount(i.ty);
                const c = try e.uniformScalar(i.ty);
                const store_c = if (c == .bool) Scalar.int else c;
                const st = try e.scalarTy(store_c);
                const arr = try e.dm.getType(.{ .array = .{ .len = n, .elem = st } });
                const ptr_ty = try e.dm.ptrType(arr);
                const base = try e.addPrologue(ptr_ty, .{ .alloca = .{ .elem = arr, .size = try e.i32Const(1) } });
                return .{ .ptr = .{ .base = base, .array_ty = arr, .scalar_ty = st, .bool_storage = c == .bool } };
            },
            .load => |p| switch (frame.vals[p.index()]) {
                .handle => |h| return .{ .handle = h },
                .cbuf => |c| return e.cbufferLoad(c.res, c.offset, c.dyn_regs, i.ty),
                .ptr => |ptr| return e.loadPtr(ptr, try e.flatCount(i.ty)),
                else => return e.unsupported("internal: load from a non-pointer", .{}),
            },
            .store => |s| {
                const ptr = switch (frame.vals[s.ptr.index()]) {
                    .ptr => |p| p,
                    else => return e.unsupported("internal: store to a non-pointer", .{}),
                };
                try e.storePtr(ptr, try e.scalars(frame, s.value));
                return .none;
            },
            .access => |a| {
                if (frame.vals[a.base.index()] == .cbuf) return e.cbufferAccess(frame, frame.vals[a.base.index()].cbuf, f.inst(a.base).ty, a.indices);
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
                const v = try e.scalars(frame, x.agg);
                const at = f.inst(x.agg).ty;
                const range = try e.componentRange(at, x.index);
                return e.list(v[range[0]..range[1]]);
            },
            .insert => |x| {
                const v = try e.scalars(frame, x.agg);
                const out = try e.arena.dupe(Value, v);
                const range = try e.componentRange(i.ty, x.index);
                const part = try e.scalars(frame, x.value);
                @memcpy(out[range[0]..range[1]], part);
                return .{ .scalars = out };
            },
            .construct => |xs| {
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
                const args = try e.arena.alloc(Lowered, c.args.len);
                for (c.args, args) |a, *o| o.* = frame.vals[a.index()];
                const res = try e.inlineCall(c.func, args);
                return if (res.len == 0) .none else .{ .scalars = res };
            },
            .intrinsic => |c| return e.intrinsic(frame, c.name, i.ty, c.args),
            .res_load => |x| return e.resourceLoad(frame, x.res, x.index, i.ty),
            .res_store => |x| {
                try e.resourceStore(frame, x.res, x.index, x.value);
                return .none;
            },
            .method => |x| return e.unsupported("method '{s}' is not supported yet", .{x.name}),
            .input => |k| return e.input(k, i.ty),
            .output => return e.unsupported("stage outputs are not supported yet", .{}),
            .phi => return e.unsupported("phi", .{}),
        }
    }

    /// Components [start, end) of member / element / component `index`.
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
            .float => e.dm.constant(.{ .ty = dt, .kind = .{ .float_bits = @as(u64, @bitCast(@as(f64, @as(f32, @floatCast(fv))))) } }),
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

    fn loadPtr(e: *Emitter, ptr: Ptr, n: u32) Error!Lowered {
        const out = try e.arena.alloc(Value, n);
        for (out, 0..) |*o, c| {
            const p = try e.elementPtr(ptr, @intCast(c));
            const raw = try e.add(ptr.scalar_ty, .{ .load = .{ .ptr = p, .@"align" = 4 } });
            o.* = if (ptr.bool_storage) try e.add(try e.dm.intType(1), .{ .cmp = .{ .pred = 33, .lhs = raw, .rhs = try e.i32Const(0) } }) else raw;
        }
        return .{ .scalars = out };
    }

    fn storePtr(e: *Emitter, ptr: Ptr, vals: []const Value) Error!void {
        const void_ty = try e.voidTy();
        for (vals, 0..) |v, c| {
            const p = try e.elementPtr(ptr, @intCast(c));
            const sv = if (ptr.bool_storage) try e.add(ptr.scalar_ty, .{ .cast = .{ .op = .zext, .val = v } }) else v;
            _ = try e.add(void_ty, .{ .store = .{ .ptr = p, .val = sv, .@"align" = 4 } });
        }
    }

    fn elementPtr(e: *Emitter, ptr: Ptr, c: u32) Error!Value {
        var idx = try e.i32Const(ptr.offset_const + c);
        if (ptr.offset_dyn) |d| idx = try e.add(try e.dm.intType(32), .{ .binop = .{ .op = .add, .lhs = d, .rhs = idx } });
        const pt = try e.dm.ptrType(ptr.scalar_ty);
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
        var a: [4][]const Value = undefined;
        for (args, 0..) |x, k| a[k] = try e.scalars(frame, x);
        const ac = if (args.len > 0) e.compOf(frame.f.inst(args[0]).ty) else e.compOf(ty);
        const rc = e.compOf(ty);
        const rt = try e.scalarTy(rc);
        const at = try e.scalarTy(ac);
        const fl = ac.isFloat();
        const n = if (args.len > 0) a[0].len else 1;
        const out = try e.arena.alloc(Value, try e.flatCount(ty));
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
        if (eq(u8, name, "GroupMemoryBarrierWithGroupSync") or eq(u8, name, "GroupMemoryBarrier") or eq(u8, name, "AllMemoryBarrierWithGroupSync") or eq(u8, name, "DeviceMemoryBarrierWithGroupSync")) {
            // Barrier flags: SyncThreadGroup 1, AccessUAVGlobal 2,
            // AccessGroupShared 8 (as dxc).
            const flags: i64 = if (eq(u8, name, "GroupMemoryBarrierWithGroupSync")) 9 else if (eq(u8, name, "GroupMemoryBarrier")) 8 else if (eq(u8, name, "AllMemoryBarrierWithGroupSync")) 11 else 3;
            const i32t = try e.dm.intType(32);
            const fn_i = try e.dxOp("dx.op.barrier", try e.voidTy(), &.{ i32t, i32t }, .nounwind);
            _ = try e.callOp(fn_i, try e.voidTy(), &.{ try e.i32Const(80), try e.i32Const(flags) });
            return .none;
        }
        return e.unsupported("intrinsic '{s}' is not supported yet", .{name});
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
        const g = e.m.globals.items[res.global];
        return layout.sizeOf(e.t, g.ty, .dx_legacy) catch e.unsupported("constant buffer '{s}' contains types that are not supported yet", .{g.name});
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
                    cur = st.fields.items[k].type;
                },
                .array => |arr| {
                    const stride_b = layout.arrayStride(e.t, arr.elem, .dx_legacy) catch return e.unsupported("constant buffer array element types", .{});
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
                    // Row r of a column-major matrix: component r of each column.
                    _ = mt;
                    return e.unsupported("row access into constant buffer matrices", .{});
                },
                else => return e.unsupported("indexing this constant buffer member", .{}),
            }
        }
        return .{ .cbuf = c };
    }

    fn cbufferLoad(e: *Emitter, ri: u32, offset: u32, dyn_regs: ?Value, ty: TypeId) Error!Lowered {
        const res = e.resources.items[ri];
        const n = try e.flatCount(ty);
        const out = try e.arena.alloc(Value, n);
        const i32t = try e.dm.intType(32);
        var cache_reg: ?u32 = null;
        var cache_val: Value = undefined;
        var cache_c: Scalar = .int;
        for (out, 0..) |*o, k| {
            const comp_ty = try e.componentType(ty, @intCast(k));
            const c = e.compOf(comp_ty);
            const mem_c: Scalar = if (c == .bool) .uint else c;
            if (mem_c.size() != 4) return e.unsupported("{d}-bit constant buffer members are not supported yet", .{mem_c.size() * 8});
            const off = offset + (layout.componentOffset(e.arena, e.t, ty, @intCast(k), .dx_legacy) catch return e.unsupported("constant buffer member types", .{}));
            const reg = off / 16;
            const st = try e.scalarTy(mem_c);
            const same_kind = (mem_c.isFloat() == cache_c.isFloat());
            if (cache_reg == null or cache_reg.? != reg or !same_kind) {
                const ret_name = try std.fmt.allocPrint(e.arena, "dx.types.CBufRet.{s}", .{e.overloadName(st)});
                const ret_ty = try e.dm.getType(.{ .@"struct" = .{ .name = ret_name, .elems = &.{ st, st, st, st } } });
                const fn_i = try e.dxOp(try std.fmt.allocPrint(e.arena, "dx.op.cbufferLoadLegacy.{s}", .{e.overloadName(st)}), ret_ty, &.{ i32t, e.handle_ty, i32t }, .nounwind_readonly);
                var reg_v = try e.i32Const(reg);
                if (dyn_regs) |d| reg_v = try e.add(i32t, .{ .binop = .{ .op = .add, .lhs = d, .rhs = reg_v } });
                cache_val = try e.callOp(fn_i, ret_ty, &.{ try e.i32Const(59), res.handle, reg_v });
                cache_reg = reg;
                cache_c = mem_c;
            }
            const v = try e.add(st, .{ .extractvalue = .{ .agg = cache_val, .index = (off % 16) / 4 } });
            o.* = if (c == .bool) try e.convertScalar(v, .uint, .bool) else v;
        }
        return .{ .scalars = out };
    }

    /// The scalar type of flattened component `k` of `ty`.
    fn componentType(e: *Emitter, ty: TypeId, k: u32) Error!TypeId {
        switch (e.t.get(ty)) {
            .scalar, .@"enum" => return ty,
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

    fn resourceLoad(e: *Emitter, frame: *Frame, res_ref: Ref, index_ref: Ref, ty: TypeId) Error!Lowered {
        const res = try e.resourceOf(frame, res_ref);
        const idx = (try e.scalars(frame, index_ref))[0];
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

    fn resourceStore(e: *Emitter, frame: *Frame, res_ref: Ref, index_ref: Ref, value_ref: Ref) Error!void {
        const res = try e.resourceOf(frame, res_ref);
        const idx = (try e.scalars(frame, index_ref))[0];
        const vals = try e.scalars(frame, value_ref);
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

    fn input(e: *Emitter, k: u32, ty: TypeId) Error!Lowered {
        const el = e.m.entry.?.inputs.items[k];
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
        return e.unsupported("input '{s}' is not supported yet", .{el.semantic});
    }

    // ------------------------------------------------------------------
    // Module metadata and container

    fn shaderFlags(e: *Emitter) u64 {
        var flags: u64 = 0;
        if (e.uses_double) flags |= 1 << 2;
        if (e.uses_int64) flags |= 1 << 20;
        var uavs: u32 = 0;
        for (e.resources.items) |r| {
            if (r.kind == 11 or r.kind == 12) flags |= 1 << 4;
            if (r.class == .uav) uavs += 1;
        }
        if (uavs > 8) flags |= 1 << 15;
        // Resources may not alias (DXIL 1.7+, when UAVs are used).
        if (uavs > 0 and e.profile.minor >= 7) flags |= 1 << 33;
        return flags;
    }

    fn writeModule(e: *Emitter, entry: ir.Entry) Error![]u8 {
        const dm = &e.dm;
        const i32t = try dm.intType(32);
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
        _ = i32t;

        const ident = try dm.mdNode(&.{try dm.mdString("zdxc 0.0.0")});
        const version = try dm.mdNode(&.{ try mdI32(dm, 1), try mdI32(dm, e.profile.minor) });
        const val_ver = try dm.mdNode(&.{ try mdI32(dm, 1), try mdI32(dm, 11) });
        const sm = try dm.mdNode(&.{ try dm.mdString(e.profile.kind.profilePrefix()), try mdI32(dm, e.profile.major), try mdI32(dm, e.profile.minor) });

        // Resource lists by class.
        var lists: [4]std.ArrayList(?module.MdId) = .{ .empty, .empty, .empty, .empty };
        for (e.resources.items) |r| {
            const g = e.m.globals.items[r.global];
            if (r.class == .cbuffer) {
                const f32t = try dm.getType(.float);
                const cb_ty = try dm.getType(.{ .@"struct" = .{ .name = g.name, .elems = &.{f32t} } });
                const undef_cb = try dm.constant(.{ .ty = try dm.ptrType(cb_ty), .kind = .undef });
                const b = g.binding;
                try lists[2].append(e.arena, try dm.mdNode(&.{ try mdI32(dm, r.id), try dm.mdValue(try dm.ptrType(cb_ty), undef_cb), try dm.mdString(""), try mdI32(dm, b.space), try mdI32(dm, b.index), try mdI32(dm, 1), try mdI32(dm, try e.cbufferSize(r)), null }));
                continue;
            }
            const rt = e.t.get(g.ty).resource;
            const class_name = try std.fmt.allocPrint(e.arena, "class.{s}<{s}>", .{ rt.name, try e.t.format(e.arena, r.elem) });
            const elem_dt = try e.scalarTy(if (r.kind == 11) .uint else try e.uniformScalar(r.elem));
            const class_ty = try dm.getType(.{ .@"struct" = .{ .name = class_name, .elems = &.{elem_dt} } });
            const undef_ptr = try dm.constant(.{ .ty = try dm.ptrType(class_ty), .kind = .undef });
            const b = g.binding;
            var fields: std.ArrayList(?module.MdId) = .empty;
            try fields.appendSlice(e.arena, &.{ try mdI32(dm, r.id), try dm.mdValue(try dm.ptrType(class_ty), undef_ptr), try dm.mdString(""), try mdI32(dm, b.space), try mdI32(dm, b.index), try mdI32(dm, 1), try mdI32(dm, r.kind) });
            if (r.class == .uav) {
                try fields.appendSlice(e.arena, &.{ try mdBool(dm, i1t, false), try mdBool(dm, i1t, false), try mdBool(dm, i1t, false) });
            } else try fields.append(e.arena, try mdI32(dm, 0)); // sample count
            const extra: ?module.MdId = switch (r.kind) {
                12 => try dm.mdNode(&.{ try mdI32(dm, 1), try mdI32(dm, try e.stride(r.elem)) }),
                10 => try dm.mdNode(&.{ try mdI32(dm, 0), try mdI32(dm, try e.compType(e.compOf(r.elem))) }),
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

        // Entry properties: shader flags and thread group size.
        var props: std.ArrayList(?module.MdId) = .empty;
        const flags = e.shaderFlags();
        if (flags != 0) {
            const i64t = try dm.intType(64);
            try props.appendSlice(e.arena, &.{ try mdI32(dm, 0), try dm.mdValue(i64t, try dm.constant(.{ .ty = i64t, .kind = .{ .int = @bitCast(flags) } })) });
        }
        const threads = try dm.mdNode(&.{ try mdI32(dm, entry.num_threads[0]), try mdI32(dm, entry.num_threads[1]), try mdI32(dm, entry.num_threads[2]) });
        try props.appendSlice(e.arena, &.{ try mdI32(dm, 4), threads });
        const props_node = try dm.mdNode(props.items);
        const main_ty = dm.functions.items[e.main_fn].ty;
        const fn_ref = try dm.mdValue(try dm.ptrType(main_ty), .{ .function = e.main_fn });
        const entry_md = try dm.mdNode(&.{ fn_ref, try dm.mdString(entry.name), null, resources, props_node });

        try dm.addNamedMetadata("llvm.ident", &.{ident});
        try dm.addNamedMetadata("dx.version", &.{version});
        try dm.addNamedMetadata("dx.valver", &.{val_ver});
        try dm.addNamedMetadata("dx.shaderModel", &.{sm});
        if (resources) |r| try dm.addNamedMetadata("dx.resources", &.{r});
        try dm.addNamedMetadata("dx.entryPoints", &.{entry_md});
        return dm.writeBitcode(dm.arena.child_allocator);
    }

    fn assemble(e: *Emitter, gpa: Allocator, entry: ir.Entry, bitcode: []const u8) Error![]u8 {
        const dxil_part = try shader.programPart(gpa, e.profile, bitcode);
        defer gpa.free(dxil_part);
        var binds: std.ArrayList(shader.ResourceBind) = .empty;
        // PSV lists CBVs, samplers, SRVs, then UAVs.
        for ([_]Resource.Class{ .cbuffer, .sampler, .srv, .uav }) |cls| for (e.resources.items) |r| if (r.class == cls) {
            const b = e.binding(r);
            const res_type: u32 = switch (r.class) {
                .srv => switch (r.kind) {
                    12 => 5,
                    11 => 4,
                    else => 3,
                },
                .uav => switch (r.kind) {
                    12 => 8,
                    11 => 7,
                    else => 6,
                },
                .cbuffer => 2,
                .sampler => 1,
            };
            try binds.append(e.arena, .{ .res_type = res_type, .space = b.space, .lower = b.index, .upper = b.index, .kind = r.kind });
        };
        const psv = try shader.psvCompute(gpa, entry.name, entry.num_threads, binds.items);
        defer gpa.free(psv);
        const empty_sig = [_]u8{ 0, 0, 0, 0, 8, 0, 0, 0 };
        var sfi0: [8]u8 = @splat(0);
        var feature: u64 = 0;
        if (e.uses_double) feature |= 0x1;
        if (e.uses_int64) feature |= 0x8000;
        std.mem.writeInt(u64, &sfi0, feature, .little);
        const parts = [_]container.Part{
            .{ .fourcc = container.fourcc("SFI0"), .data = &sfi0 },
            .{ .fourcc = container.fourcc("ISG1"), .data = &empty_sig },
            .{ .fourcc = container.fourcc("OSG1"), .data = &empty_sig },
            .{ .fourcc = container.fourcc("PSV0"), .data = psv },
            .{ .fourcc = container.fourcc("DXIL"), .data = dxil_part },
        };
        return container.assemble(gpa, &parts);
    }
};

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
