//! A minimal LLVM 3.7 IR model plus its bitcode encoder: just enough of LLVM
//! to express DXIL. Mirrors lib/Bitcode/Writer/BitcodeWriter.cpp, emitting
//! unabbreviated records only.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bitstream = @import("bitstream.zig");

pub const TypeId = u32;
pub const ConstId = u32;
pub const MdId = u32;

pub const Type = union(enum) {
    void,
    label,
    metadata,
    half,
    float,
    double,
    int: u32,
    pointer: struct { elem: TypeId, addr_space: u32 = 0 },
    function: struct { ret: TypeId, params: []const TypeId },
    @"struct": struct { name: []const u8, elems: []const TypeId, @"packed": bool = false },
    array: struct { len: u64, elem: TypeId },
    vector: struct { len: u32, elem: TypeId },

    fn eql(a: Type, b: Type) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .void, .label, .metadata, .half, .float, .double => true,
            .int => |w| w == b.int,
            .pointer => |p| p.elem == b.pointer.elem and p.addr_space == b.pointer.addr_space,
            .function => |f| f.ret == b.function.ret and std.mem.eql(TypeId, f.params, b.function.params),
            // Named structs are nominal.
            .@"struct" => |s| std.mem.eql(u8, s.name, b.@"struct".name),
            .array => |x| x.len == b.array.len and x.elem == b.array.elem,
            .vector => |x| x.len == b.vector.len and x.elem == b.vector.elem,
        };
    }
};

pub const Constant = struct {
    ty: TypeId,
    kind: union(enum) {
        int: i64,
        /// Raw IEEE bits (f16/f32/f64 per type).
        float_bits: u64,
        undef,
        null,
        /// Struct / array / vector of earlier constants.
        aggregate: []const ConstId,
    },
};

pub const Linkage = enum(u32) { external = 0, internal = 3 };

/// Attribute group for function declarations (e.g. dx.op functions).
pub const FnAttrs = enum { none, nounwind, nounwind_readnone, nounwind_readonly };

pub const Value = union(enum) {
    /// Index into Module.globals (a pointer to the variable).
    global: u32,
    /// Index into Module.functions.
    function: u32,
    constant: ConstId,
    arg: u32,
    /// Index into Function.insts; must produce a value.
    inst: u32,
};

pub const BinOp = enum(u32) { add = 0, sub = 1, mul = 2, udiv = 3, sdiv = 4, urem = 5, srem = 6, shl = 7, lshr = 8, ashr = 9, @"and" = 10, @"or" = 11, xor = 12 };
pub const RmwOp = enum(u32) { xchg = 0, add = 1, sub = 2, @"and" = 3, nand = 4, @"or" = 5, xor = 6, max = 7, min = 8, umax = 9, umin = 10 };

/// A module-level variable (groupshared memory: address space 3),
/// declared without an initializer as dxc does.
pub const GlobalVar = struct { name: []const u8, ty: TypeId, addr_space: u32, ptr_ty: TypeId };

pub const CastOp = enum(u32) { trunc = 0, zext = 1, sext = 2, fptoui = 3, fptosi = 4, uitofp = 5, sitofp = 6, fptrunc = 7, fpext = 8, ptrtoint = 9, inttoptr = 10, bitcast = 11 };

pub const Inst = struct {
    /// Result type; `void` for instructions without a result.
    ty: TypeId,
    op: union(enum) {
        ret: ?Value,
        br: struct { then: u32, @"else": ?u32 = null, cond: ?Value = null },
        /// Case values are constants.
        @"switch": struct { cond: Value, default: u32, cases: []const struct { val: Value, block: u32 } },
        call: struct { callee: u32, args: []const Value },
        binop: struct { op: BinOp, lhs: Value, rhs: Value, flags: u32 = 0 },
        cast: struct { op: CastOp, val: Value },
        cmp: struct { pred: u32, lhs: Value, rhs: Value },
        select: struct { cond: Value, t: Value, f: Value },
        extractvalue: struct { agg: Value, index: u32 },
        phi: struct { incoming: []const struct { val: Value, block: u32 } },
        /// `ty` is the pointer type; `elem` the allocated type.
        alloca: struct { elem: TypeId, size: Value },
        load: struct { ptr: Value, @"align": u32 },
        store: struct { ptr: Value, val: Value, @"align": u32 },
        /// `ty` is the result pointer type; `elem` the source element type.
        gep: struct { elem: TypeId, ptr: Value, indices: []const Value },
        /// Sequentially consistent read-modify-write; yields the old value.
        atomicrmw: struct { op: RmwOp, ptr: Value, val: Value },
        /// Yields `{ old, success }` (`ty` is that literal struct).
        cmpxchg: struct { ptr: Value, cmp: Value, new: Value },
        @"unreachable",
    },
};

pub const Function = struct {
    name: []const u8,
    ty: TypeId,
    linkage: Linkage = .external,
    attrs: FnAttrs = .none,
    /// Declarations have no blocks.
    num_blocks: u32 = 0,
    /// Instructions in block order; a terminator ends each block.
    insts: std.ArrayList(Inst) = .empty,
};

pub const Metadata = union(enum) {
    string: []const u8,
    value: struct { ty: TypeId, val: Value },
    /// Operands: null entries encode as 0 (no metadata).
    node: []const ?MdId,
};

pub const Module = struct {
    arena: std.heap.ArenaAllocator,
    triple: []const u8 = "dxil-ms-dx",
    datalayout: []const u8 = "e-m:e-p:32:32-i1:32-i8:32-i16:32-i32:32-i64:64-f16:32-f32:32-f64:64-n8:16:32:64",
    types: std.ArrayList(Type) = .empty,
    constants: std.ArrayList(Constant) = .empty,
    functions: std.ArrayList(Function) = .empty,
    globals: std.ArrayList(GlobalVar) = .empty,
    metadata: std.ArrayList(Metadata) = .empty,
    named_metadata: std.ArrayList(struct { name: []const u8, nodes: []const MdId }) = .empty,

    pub fn init(gpa: Allocator) Module {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(m: *Module) void {
        m.arena.deinit();
    }

    pub fn allocator(m: *Module) Allocator {
        return m.arena.allocator();
    }

    pub fn getType(m: *Module, t: Type) !TypeId {
        for (m.types.items, 0..) |existing, i| {
            if (existing.eql(t)) return @intCast(i);
        }
        const a = m.allocator();
        var owned = t;
        switch (owned) {
            .function => |*f| f.params = try a.dupe(TypeId, f.params),
            .@"struct" => |*s| {
                s.name = try a.dupe(u8, s.name);
                s.elems = try a.dupe(TypeId, s.elems);
            },
            else => {},
        }
        try m.types.append(a, owned);
        return @intCast(m.types.items.len - 1);
    }

    pub fn intType(m: *Module, bits: u32) !TypeId {
        return m.getType(.{ .int = bits });
    }

    pub fn fnType(m: *Module, ret: TypeId, params: []const TypeId) !TypeId {
        return m.getType(.{ .function = .{ .ret = ret, .params = params } });
    }

    pub fn ptrType(m: *Module, elem: TypeId) !TypeId {
        return m.getType(.{ .pointer = .{ .elem = elem } });
    }

    /// Lookup of an existing pointer type, used while encoding. Function
    /// pointer types are created by addFunction.
    fn ptrTypeConst(m: *const Module, elem: TypeId) TypeId {
        for (m.types.items, 0..) |t, i| {
            if (t == .pointer and t.pointer.elem == elem and t.pointer.addr_space == 0) return @intCast(i);
        }
        unreachable;
    }

    pub fn addGlobal(m: *Module, name: []const u8, ty: TypeId, addr_space: u32) !Value {
        const ptr_ty = try m.getType(.{ .pointer = .{ .elem = ty, .addr_space = addr_space } });
        try m.globals.append(m.allocator(), .{ .name = try m.allocator().dupe(u8, name), .ty = ty, .addr_space = addr_space, .ptr_ty = ptr_ty });
        return .{ .global = @intCast(m.globals.items.len - 1) };
    }

    pub fn constant(m: *Module, c: Constant) !Value {
        for (m.constants.items, 0..) |existing, i| {
            if (existing.ty == c.ty and std.meta.eql(existing.kind, c.kind)) return .{ .constant = @intCast(i) };
        }
        try m.constants.append(m.allocator(), c);
        return .{ .constant = @intCast(m.constants.items.len - 1) };
    }

    pub fn constInt(m: *Module, bits: u32, v: i64) !Value {
        return m.constant(.{ .ty = try m.intType(bits), .kind = .{ .int = v } });
    }

    pub fn addFunction(m: *Module, f: Function) !u32 {
        var owned = f;
        owned.name = try m.allocator().dupe(u8, f.name);
        _ = try m.ptrType(f.ty);
        try m.functions.append(m.allocator(), owned);
        return @intCast(m.functions.items.len - 1);
    }

    pub fn findFunction(m: *Module, name: []const u8) ?u32 {
        for (m.functions.items, 0..) |f, i| if (std.mem.eql(u8, f.name, name)) return @intCast(i);
        return null;
    }

    pub fn addInst(m: *Module, func: u32, inst: Inst) !Value {
        const f = &m.functions.items[func];
        try f.insts.append(m.allocator(), inst);
        return .{ .inst = @intCast(f.insts.items.len - 1) };
    }

    pub fn mdString(m: *Module, s: []const u8) !MdId {
        for (m.metadata.items, 0..) |md, i| {
            if (md == .string and std.mem.eql(u8, md.string, s)) return @intCast(i);
        }
        try m.metadata.append(m.allocator(), .{ .string = try m.allocator().dupe(u8, s) });
        return @intCast(m.metadata.items.len - 1);
    }

    pub fn mdValue(m: *Module, ty: TypeId, val: Value) !MdId {
        for (m.metadata.items, 0..) |md, i| {
            if (md == .value and md.value.ty == ty and std.meta.eql(md.value.val, val)) return @intCast(i);
        }
        try m.metadata.append(m.allocator(), .{ .value = .{ .ty = ty, .val = val } });
        return @intCast(m.metadata.items.len - 1);
    }

    pub fn mdI32(m: *Module, v: i64) !MdId {
        return m.mdValue(try m.intType(32), try m.constInt(32, v));
    }

    pub fn mdNode(m: *Module, ops: []const ?MdId) !MdId {
        try m.metadata.append(m.allocator(), .{ .node = try m.allocator().dupe(?MdId, ops) });
        return @intCast(m.metadata.items.len - 1);
    }

    pub fn addNamedMetadata(m: *Module, name: []const u8, nodes: []const MdId) !void {
        const a = m.allocator();
        try m.named_metadata.append(a, .{ .name = try a.dupe(u8, name), .nodes = try a.dupe(MdId, nodes) });
    }

    /// Encode the module as raw LLVM bitcode (starting with 'BC' 0xC0DE).
    pub fn writeBitcode(m: *Module, gpa: Allocator) ![]u8 {
        var enc: Encoder = .{ .m = m, .w = .init(gpa) };
        defer enc.w.deinit();
        return enc.write();
    }
};

const block_module = 8;
const block_paramattr = 9;
const block_paramattr_group = 10;
const block_constants = 11;
const block_function = 12;
const block_value_symtab = 14;
const block_metadata = 15;
const block_type = 17;

const Encoder = struct {
    m: *Module,
    w: bitstream.Writer,
    ops: std.ArrayList(u64) = .empty,

    fn gpa(e: *Encoder) Allocator {
        return e.w.gpa;
    }

    fn rec(e: *Encoder, code: u32) !void {
        try e.w.record(code, e.ops.items);
        e.ops.clearRetainingCapacity();
    }

    fn push(e: *Encoder, v: u64) !void {
        try e.ops.append(e.gpa(), v);
    }

    fn moduleValueCount(e: *Encoder) u32 {
        return @intCast(e.m.globals.items.len + e.m.functions.items.len + e.m.constants.items.len);
    }

    /// Absolute value ID. Module values: globals, functions, constants.
    fn valueId(e: *Encoder, f: ?*const Function, v: Value) u32 {
        const nglobals: u32 = @intCast(e.m.globals.items.len);
        const nfuncs: u32 = @intCast(e.m.functions.items.len);
        return switch (v) {
            .global => |i| i,
            .function => |i| nglobals + i,
            .constant => |c| nglobals + nfuncs + c,
            .arg => |a| e.moduleValueCount() + a,
            .inst => |i| blk: {
                const func = f.?;
                const nargs: u32 = @intCast(e.m.types.items[func.ty].function.params.len);
                var n: u32 = 0;
                for (func.insts.items[0..i]) |prev| {
                    if (e.m.types.items[prev.ty] != .void) n += 1;
                }
                break :blk e.moduleValueCount() + nargs + n;
            },
        };
    }

    fn typeOf(e: *Encoder, f: ?*const Function, v: Value) TypeId {
        return switch (v) {
            .global => |i| e.m.globals.items[i].ptr_ty,
            .function => |i| e.m.ptrTypeConst(e.m.functions.items[i].ty),
            .constant => |c| e.m.constants.items[c].ty,
            .arg => |a| e.m.types.items[f.?.ty].function.params[a],
            .inst => |i| f.?.insts.items[i].ty,
        };
    }

    fn pushValueAndType(e: *Encoder, f: *const Function, inst_id: u32, v: Value) !void {
        const id = e.valueId(f, v);
        try e.push(inst_id -% id);
        if (id >= inst_id) try e.push(e.typeOf(f, v));
    }

    fn pushValue(e: *Encoder, f: *const Function, inst_id: u32, v: Value) !void {
        try e.push(inst_id -% e.valueId(f, v));
    }

    fn write(e: *Encoder) ![]u8 {
        defer e.ops.deinit(e.gpa());
        const w = &e.w;
        try w.emit('B', 8);
        try w.emit('C', 8);
        try w.emit(0x0, 4);
        try w.emit(0xC, 4);
        try w.emit(0xE, 4);
        try w.emit(0xD, 4);

        try w.enterBlock(block_module, 3);
        try e.push(1);
        try e.rec(1); // MODULE_CODE_VERSION: relative value IDs

        try e.writeAttributes();
        try e.writeTypes();
        try w.recordString(2, &.{}, e.m.triple);
        try w.recordString(3, &.{}, e.m.datalayout);
        for (e.m.globals.items) |g| {
            // GLOBALVAR: [type, addrspace << 2 | explicit type, init (none),
            //             linkage (external), align 4, section]
            try e.ops.appendSlice(e.gpa(), &.{ g.ty, (@as(u64, g.addr_space) << 2) | 2, 0, 0, 3, 0 });
            try e.rec(7);
        }
        for (e.m.functions.items) |f| {
            // FUNCTION: [type, cc, isproto, linkage, paramattr, align, section,
            //            visibility, gc, unnamed_addr, prologue, dllstorage,
            //            comdat, prefix, personality]
            const is_proto: u64 = @intFromBool(f.num_blocks == 0);
            try e.ops.appendSlice(e.gpa(), &.{ f.ty, 0, is_proto, @backingInt(f.linkage), attrId(f.attrs), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
            try e.rec(8);
        }
        try e.writeConstants();
        try e.writeMetadata();
        try e.writeSymtab();
        for (e.m.functions.items) |*f| {
            if (f.num_blocks != 0) try e.writeFunction(f);
        }
        try w.endBlock();
        return w.finish();
    }

    fn attrId(a: FnAttrs) u64 {
        return @backingInt(a);
    }

    fn writeAttributes(e: *Encoder) !void {
        // Groups 1..3 match FnAttrs order; each applies to the function (index 0xFFFFFFFF).
        // Attribute kinds: nounwind = 18, readnone = 20, readonly = 21.
        const w = &e.w;
        try w.enterBlock(block_paramattr_group, 3);
        const groups = [_][]const u64{ &.{18}, &.{ 18, 20 }, &.{ 18, 21 } };
        for (groups, 1..) |kinds, id| {
            try e.push(id);
            try e.push(0xFFFFFFFF);
            for (kinds) |k| {
                try e.push(0); // enum attribute
                try e.push(k);
            }
            try e.rec(3); // PARAMATTR_GRP_CODE_ENTRY
        }
        try w.endBlock();
        try w.enterBlock(block_paramattr, 3);
        for (0..groups.len) |i| {
            try e.push(i + 1);
            try e.rec(2); // PARAMATTR_CODE_ENTRY: [group ids]
        }
        try w.endBlock();
    }

    fn writeTypes(e: *Encoder) !void {
        const w = &e.w;
        try w.enterBlock(block_type, 4);
        try e.push(e.m.types.items.len);
        try e.rec(1); // NUMENTRY
        for (e.m.types.items) |t| {
            switch (t) {
                .void => try e.rec(2),
                .float => try e.rec(3),
                .double => try e.rec(4),
                .label => try e.rec(5),
                .half => try e.rec(10),
                .metadata => try e.rec(16),
                .int => |bits| {
                    try e.push(bits);
                    try e.rec(7);
                },
                .pointer => |p| {
                    try e.push(p.elem);
                    try e.push(p.addr_space);
                    try e.rec(8);
                },
                .function => |f| {
                    try e.push(0);
                    try e.push(f.ret);
                    for (f.params) |p| try e.push(p);
                    try e.rec(21);
                },
                .@"struct" => |s| {
                    if (s.name.len != 0) try w.recordString(19, &.{}, s.name);
                    try e.push(@intFromBool(s.@"packed"));
                    for (s.elems) |el| try e.push(el);
                    try e.rec(if (s.name.len != 0) 20 else 18);
                },
                .array => |a| {
                    try e.push(a.len);
                    try e.push(a.elem);
                    try e.rec(11);
                },
                .vector => |v| {
                    try e.push(v.len);
                    try e.push(v.elem);
                    try e.rec(12);
                },
            }
        }
        try w.endBlock();
    }

    fn writeConstants(e: *Encoder) !void {
        if (e.m.constants.items.len == 0) return;
        const w = &e.w;
        try w.enterBlock(block_constants, 4);
        var cur_ty: ?TypeId = null;
        for (e.m.constants.items) |c| {
            if (cur_ty != c.ty) {
                try e.push(c.ty);
                try e.rec(1); // SETTYPE
                cur_ty = c.ty;
            }
            switch (c.kind) {
                .int => |v| {
                    try e.push(encodeSigned(v));
                    try e.rec(4);
                },
                .float_bits => |b| {
                    try e.push(b);
                    try e.rec(6);
                },
                .undef => try e.rec(3),
                .null => try e.rec(2),
                .aggregate => |elems| {
                    for (elems) |el| try e.push(e.valueId(null, .{ .constant = el }));
                    try e.rec(7); // CST_CODE_AGGREGATE
                },
            }
        }
        try w.endBlock();
    }

    fn writeMetadata(e: *Encoder) !void {
        const m = e.m;
        if (m.metadata.items.len == 0 and m.named_metadata.items.len == 0) return;
        const w = &e.w;
        try w.enterBlock(block_metadata, 3);
        for (m.metadata.items) |md| {
            switch (md) {
                .string => |s| try w.recordString(1, &.{}, s),
                .value => |v| {
                    try e.push(v.ty);
                    try e.push(e.valueId(null, v.val));
                    try e.rec(2);
                },
                .node => |ops| {
                    for (ops) |op| try e.push(if (op) |id| id + 1 else 0);
                    try e.rec(3);
                },
            }
        }
        for (m.named_metadata.items) |nmd| {
            try w.recordString(4, &.{}, nmd.name);
            for (nmd.nodes) |n| try e.push(n);
            try e.rec(10);
        }
        try w.endBlock();
    }

    fn writeSymtab(e: *Encoder) !void {
        const w = &e.w;
        // dxc sorts entries by name for deterministic output.
        const order = try e.gpa().alloc(u32, e.m.functions.items.len);
        defer e.gpa().free(order);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        const funcs = e.m.functions.items;
        std.mem.sort(u32, order, funcs, struct {
            fn lt(fs: []const Function, a: u32, b: u32) bool {
                return std.mem.lessThan(u8, fs[a].name, fs[b].name);
            }
        }.lt);
        try w.enterBlock(block_value_symtab, 4);
        const nglobals: u32 = @intCast(e.m.globals.items.len);
        for (e.m.globals.items, 0..) |g, i| try w.recordString(1, &.{i}, g.name);
        for (order) |i| try w.recordString(1, &.{nglobals + i}, funcs[i].name); // VST_ENTRY
        try w.endBlock();
    }

    fn writeFunction(e: *Encoder, f: *const Function) !void {
        const w = &e.w;
        try w.enterBlock(block_function, 4);
        try e.push(f.num_blocks);
        try e.rec(1); // DECLAREBLOCKS

        const nargs: u32 = @intCast(e.m.types.items[f.ty].function.params.len);
        var inst_id: u32 = e.moduleValueCount() + nargs;
        for (f.insts.items) |inst| {
            switch (inst.op) {
                .ret => |v| {
                    if (v) |val| try e.pushValueAndType(f, inst_id, val);
                    try e.rec(10);
                },
                .@"switch" => |sw| {
                    // SWITCH: [opty, cond, default, (case value id, block)...]
                    try e.push(e.typeOf(f, sw.cond));
                    try e.pushValue(f, inst_id, sw.cond);
                    try e.push(sw.default);
                    for (sw.cases) |c| {
                        try e.push(e.valueId(f, c.val));
                        try e.push(c.block);
                    }
                    try e.rec(12);
                },
                .br => |b| {
                    try e.push(b.then);
                    if (b.@"else") |el| {
                        try e.push(el);
                        try e.pushValue(f, inst_id, b.cond.?);
                    }
                    try e.rec(11);
                },
                .call => |c| {
                    const callee = e.m.functions.items[c.callee];
                    try e.push(0); // paramattrs on the call site
                    try e.push(1 << 15); // explicit function type, ccc
                    try e.push(callee.ty);
                    try e.pushValueAndType(f, inst_id, .{ .function = c.callee });
                    for (c.args) |arg| try e.pushValue(f, inst_id, arg);
                    try e.rec(34);
                },
                .binop => |b| {
                    try e.pushValueAndType(f, inst_id, b.lhs);
                    try e.pushValue(f, inst_id, b.rhs);
                    try e.push(@backingInt(b.op));
                    if (b.flags != 0) try e.push(b.flags);
                    try e.rec(2);
                },
                .cast => |c| {
                    try e.pushValueAndType(f, inst_id, c.val);
                    try e.push(inst.ty);
                    try e.push(@backingInt(c.op));
                    try e.rec(3);
                },
                .cmp => |c| {
                    try e.pushValueAndType(f, inst_id, c.lhs);
                    try e.pushValue(f, inst_id, c.rhs);
                    try e.push(c.pred);
                    try e.rec(28);
                },
                .select => |s| {
                    try e.pushValueAndType(f, inst_id, s.t);
                    try e.pushValue(f, inst_id, s.f);
                    try e.pushValueAndType(f, inst_id, s.cond);
                    try e.rec(29);
                },
                .extractvalue => |x| {
                    try e.pushValueAndType(f, inst_id, x.agg);
                    try e.push(x.index);
                    try e.rec(26);
                },
                .alloca => |a| {
                    try e.push(a.elem);
                    try e.push(e.typeOf(f, a.size));
                    try e.push(e.valueId(f, a.size)); // absolute
                    try e.push(@as(u64, std.math.log2_int(u32, 4)) + 1 | (1 << 6)); // align 4, explicit type
                    try e.rec(19);
                },
                .load => |l| {
                    try e.pushValueAndType(f, inst_id, l.ptr);
                    try e.push(inst.ty);
                    try e.push(@as(u64, std.math.log2_int(u32, l.@"align")) + 1);
                    try e.push(0);
                    try e.rec(20);
                },
                .store => |s| {
                    try e.pushValueAndType(f, inst_id, s.ptr);
                    try e.pushValueAndType(f, inst_id, s.val);
                    try e.push(@as(u64, std.math.log2_int(u32, s.@"align")) + 1);
                    try e.push(0);
                    try e.rec(44);
                },
                .gep => |g| {
                    try e.push(1); // inbounds
                    try e.push(g.elem);
                    try e.pushValueAndType(f, inst_id, g.ptr);
                    for (g.indices) |x| try e.pushValueAndType(f, inst_id, x);
                    try e.rec(43);
                },
                .@"unreachable" => try e.rec(15),
                .atomicrmw => |a| {
                    // ATOMICRMW: [ptr, val, op, volatile, ordering, scope]
                    try e.pushValueAndType(f, inst_id, a.ptr);
                    try e.pushValue(f, inst_id, a.val);
                    try e.ops.appendSlice(e.gpa(), &.{ @backingInt(a.op), 0, 6, 1 }); // seq_cst, cross-thread
                    try e.rec(38);
                },
                .cmpxchg => |c| {
                    // CMPXCHG: [ptr, cmp, new, volatile, success ordering,
                    //           scope, failure ordering, weak]
                    try e.pushValueAndType(f, inst_id, c.ptr);
                    try e.pushValueAndType(f, inst_id, c.cmp);
                    try e.pushValue(f, inst_id, c.new);
                    try e.ops.appendSlice(e.gpa(), &.{ 0, 6, 1, 6, 0 });
                    try e.rec(46);
                },
                .phi => |p| {
                    try e.push(inst.ty);
                    for (p.incoming) |in| {
                        const diff = @as(i64, inst_id) - @as(i64, e.valueId(f, in.val));
                        try e.push(encodeSigned(diff));
                        try e.push(in.block);
                    }
                    try e.rec(16);
                },
            }
            if (e.m.types.items[inst.ty] != .void) inst_id += 1;
        }
        try w.endBlock();
    }
};

fn encodeSigned(v: i64) u64 {
    return if (v >= 0) @as(u64, @intCast(v)) << 1 else (@as(u64, @intCast(-v)) << 1) | 1;
}

test "encodeSigned" {
    try std.testing.expectEqual(@as(u64, 4), encodeSigned(2));
    try std.testing.expectEqual(@as(u64, 3), encodeSigned(-1));
}
