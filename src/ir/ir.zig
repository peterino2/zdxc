//! zdxc IR: typed values in a control-flow graph that keeps its structure
//! (selection and loop headers name their merge and continue blocks), shared
//! by the DXIL and SPIR-V backends.
//!
//! Lowering produces memory form: locals and parameters live in `local_var`
//! storage accessed by `load` / `store`, as dxc's SPIR-V backend emits them.
//! Functions and calls are kept (SPIR-V wants real functions); the DXIL
//! backend inlines, promotes memory to SSA values and scalarizes.
//!
//! Value types are Sema's TypeTable ids (scalars, vectors, matrices,
//! arrays, structs, resources). A value whose `ptr` space is not `.none` is
//! a pointer to storage of that type.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../sema/types.zig");

pub const TypeId = types.TypeId;
pub const TypeTable = types.TypeTable;

/// An instruction result within a function.
pub const Ref = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn index(r: Ref) u32 {
        return @backingInt(r);
    }
};

pub const BlockId = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn index(b: BlockId) u32 {
        return @backingInt(b);
    }
};

/// Where a pointer points.
pub const Space = enum { none, function, private, groupshared, resource, input, output, cbuffer };

pub const BinaryOp = enum {
    add,
    sub,
    mul,
    div,
    rem,
    shl,
    shr,
    bit_and,
    bit_or,
    bit_xor,
    log_and,
    log_or,
};

pub const CmpOp = enum { eq, ne, lt, le, gt, ge };

pub const UnaryOp = enum { neg, not, bit_not };

pub const Constant = union(enum) {
    /// Integer or bool bits, sign-extended for signed types.
    int: i64,
    float: f64,
};

pub const Op = union(enum) {
    /// A scalar constant (or a vector of one constant, splatted).
    constant: Constant,
    /// The function's `n`th parameter (a pointer for out / inout).
    param: u32,
    /// Pointer to a module global (resource, groupshared, static).
    global: u32,
    /// Function-local storage of the result type (result is a pointer).
    local_var,
    load: Ref,
    store: struct { ptr: Ref, value: Ref },
    /// Pointer to a member / element of the storage `base` points at.
    access: struct { base: Ref, indices: []const Ref },
    binary: struct { op: BinaryOp, lhs: Ref, rhs: Ref },
    unary: struct { op: UnaryOp, operand: Ref },
    cmp: struct { op: CmpOp, lhs: Ref, rhs: Ref },
    /// Component-wise numeric conversion to the result type (same shape).
    convert: Ref,
    /// Bit reinterpretation (asuint, asfloat, ...).
    bitcast: Ref,
    /// Scalar replicated to the result vector / matrix.
    splat: Ref,
    /// Constant component / member / element.
    extract: struct { agg: Ref, index: u32 },
    insert: struct { agg: Ref, value: Ref, index: u32 },
    /// Vector / matrix / struct / array from its components.
    construct: []const Ref,
    /// Vector components picked by index (swizzles, truncation).
    shuffle: struct { vec: Ref, components: []const u8 },
    select: struct { cond: Ref, t: Ref, f: Ref },
    call: struct { func: u32, args: []const Ref },
    /// A math / bit / derivative intrinsic by HLSL name (`sqrt`, `mad`, ...).
    intrinsic: struct { name: []const u8, args: []const Ref },
    /// `resource[index]` read and write (structured / typed / raw buffers,
    /// textures).
    res_load: struct { res: Ref, index: Ref },
    res_store: struct { res: Ref, index: Ref, value: Ref },
    /// A builtin method call on a resource (`Load`, `Sample`, ...).
    method: struct { name: []const u8, res: Ref, args: []const Ref },
    /// An entry-point input / output element (index into the entry's
    /// signature).
    input: u32,
    output: struct { element: u32, value: Ref },
    phi: []const struct { value: Ref, block: BlockId },
};

pub const Inst = struct {
    op: Op,
    ty: TypeId,
    /// Non-`none` when the result is a pointer to `ty` storage.
    ptr: Space = .none,
};

pub const Terminator = union(enum) {
    /// Not yet terminated (lowering in progress).
    none,
    ret: Ref,
    br: BlockId,
    cond_br: struct { cond: Ref, then: BlockId, @"else": BlockId },
    @"switch": struct { value: Ref, default: BlockId, cases: []const struct { value: i64, block: BlockId } },
    /// After `discard`, or where control cannot reach.
    @"unreachable",
    discard,
};

/// Structured control flow: a header block names where its construct
/// merges and (for loops) where iterations continue.
pub const Merge = union(enum) {
    none,
    selection: BlockId,
    loop: struct { merge: BlockId, @"continue": BlockId },
};

pub const Block = struct {
    insts: std.ArrayList(Ref) = .empty,
    term: Terminator = .none,
    merge: Merge = .none,
};

pub const Param = struct {
    name: []const u8,
    ty: TypeId,
    /// out / inout: passed as a pointer to caller storage.
    by_ref: bool,
};

pub const Function = struct {
    name: []const u8,
    params: []const Param,
    ret: TypeId,
    insts: std.ArrayList(Inst) = .empty,
    blocks: std.ArrayList(Block) = .empty,

    pub fn inst(f: *const Function, r: Ref) Inst {
        return f.insts.items[r.index()];
    }

    pub fn block(f: *Function, b: BlockId) *Block {
        return &f.blocks.items[b.index()];
    }
};

pub const Binding = struct {
    /// Register class: 'b', 't', 'u', 's' (0: none given).
    class: u8 = 0,
    index: u32 = 0,
    space: u32 = 0,
    explicit: bool = false,
};

pub const Global = struct {
    name: []const u8,
    ty: TypeId,
    space: Space,
    binding: Binding = .{},
};

pub const Stage = enum { vertex, pixel, geometry, hull, domain, compute, library };

/// One entry-point input or output (a semantic on a parameter, field or
/// the return value).
pub const SigElement = struct {
    semantic: []const u8,
    semantic_index: u32,
    ty: TypeId,
    system_value: bool,
    interp: types.Interp = .{},
    /// Matrices in the element are row_major (signature layout only).
    row_major: bool = false,
};

pub const Entry = struct {
    /// The function the entry wraps (the HLSL entry, in memory form).
    func: u32,
    name: []const u8,
    stage: Stage,
    num_threads: [3]u32 = .{ 1, 1, 1 },
    inputs: std.ArrayList(SigElement) = .empty,
    outputs: std.ArrayList(SigElement) = .empty,
    /// The wrapper with no parameters that reads `inputs`, calls `func`
    /// and writes `outputs`.
    wrapper: u32 = 0,
};

pub const Module = struct {
    arena: Allocator,
    types: *TypeTable,
    globals: std.ArrayList(Global) = .empty,
    /// By pointer: lowering appends callees while building a caller.
    functions: std.ArrayList(*Function) = .empty,
    entry: ?Entry = null,

    pub fn addFunction(m: *Module, f: Function) !u32 {
        const p = try m.arena.create(Function);
        p.* = f;
        try m.functions.append(m.arena, p);
        return @intCast(m.functions.items.len - 1);
    }
};

/// Appends instructions to a function at a current block.
pub const Builder = struct {
    m: *Module,
    f: *Function,
    cur: BlockId = .none,

    pub fn newBlock(b: *Builder) !BlockId {
        try b.f.blocks.append(b.m.arena, .{});
        return @fromBackingInt(@intCast(b.f.blocks.items.len - 1));
    }

    pub fn setBlock(b: *Builder, blk: BlockId) void {
        b.cur = blk;
    }

    /// The current block is still open (no terminator yet).
    pub fn open(b: *Builder) bool {
        return b.cur != .none and b.f.block(b.cur).term == .none;
    }

    pub fn add(b: *Builder, inst: Inst) !Ref {
        try b.f.insts.append(b.m.arena, inst);
        const r: Ref = @fromBackingInt(@intCast(b.f.insts.items.len - 1));
        // Instructions after a terminator (dead code) go to a fresh block.
        if (!b.open()) b.cur = try b.newBlock();
        try b.f.block(b.cur).insts.append(b.m.arena, r);
        return r;
    }

    pub fn terminate(b: *Builder, t: Terminator) void {
        if (!b.open()) return;
        b.f.block(b.cur).term = t;
    }

    pub fn constInt(b: *Builder, ty: TypeId, v: i64) !Ref {
        return b.add(.{ .op = .{ .constant = .{ .int = v } }, .ty = ty });
    }

    pub fn constFloat(b: *Builder, ty: TypeId, v: f64) !Ref {
        return b.add(.{ .op = .{ .constant = .{ .float = v } }, .ty = ty });
    }

    pub fn load(b: *Builder, ptr: Ref) !Ref {
        const p = b.f.inst(ptr);
        return b.add(.{ .op = .{ .load = ptr }, .ty = p.ty });
    }

    pub fn store(b: *Builder, ptr: Ref, value: Ref) !void {
        _ = try b.add(.{ .op = .{ .store = .{ .ptr = ptr, .value = value } }, .ty = TypeTable.void_type });
    }
};

/// Prints a module in a readable text form (for `-zdxc-ir` and tests).
pub fn dump(m: *const Module, w: *std.Io.Writer) !void {
    for (m.globals.items, 0..) |g, i| {
        try w.print("global @{d} {s}: {s} {s}", .{ i, g.name, @tagName(g.space), try m.types.format(m.arena, g.ty) });
        if (g.binding.class != 0) try w.print(" : register({c}{d}, space{d})", .{ g.binding.class, g.binding.index, g.binding.space });
        try w.writeByte('\n');
    }
    for (m.functions.items, 0..) |f, fi| {
        try w.print("fn @{d} {s}(", .{ fi, f.name });
        for (f.params, 0..) |p, i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("{s}{s}: {s}", .{ if (p.by_ref) "ref " else "", p.name, try m.types.format(m.arena, p.ty) });
        }
        try w.print(") -> {s} {{\n", .{try m.types.format(m.arena, f.ret)});
        for (f.blocks.items, 0..) |blk, bi| {
            try w.print("b{d}:", .{bi});
            switch (blk.merge) {
                .none => {},
                .selection => |mb| try w.print("  ; selection merge b{d}", .{mb.index()}),
                .loop => |l| try w.print("  ; loop merge b{d} continue b{d}", .{ l.merge.index(), l.@"continue".index() }),
            }
            try w.writeByte('\n');
            for (blk.insts.items) |r| try dumpInst(m, f, r, w);
            try w.writeAll("  ");
            switch (blk.term) {
                .none => try w.writeAll("<open>"),
                .ret => |v| if (v == .none) try w.writeAll("ret") else try w.print("ret %{d}", .{v.index()}),
                .br => |t| try w.print("br b{d}", .{t.index()}),
                .cond_br => |c| try w.print("br %{d}, b{d}, b{d}", .{ c.cond.index(), c.then.index(), c.@"else".index() }),
                .@"switch" => |sw| {
                    try w.print("switch %{d} default b{d}", .{ sw.value.index(), sw.default.index() });
                    for (sw.cases) |c| try w.print(", {d}: b{d}", .{ c.value, c.block.index() });
                },
                .@"unreachable" => try w.writeAll("unreachable"),
                .discard => try w.writeAll("discard"),
            }
            try w.writeByte('\n');
        }
        try w.writeAll("}\n");
    }
}

fn dumpInst(m: *const Module, f: *const Function, r: Ref, w: *std.Io.Writer) !void {
    const inst = f.inst(r);
    try w.writeAll("  ");
    if (inst.ty != TypeTable.void_type) {
        try w.print("%{d}: {s}{s} = ", .{ r.index(), if (inst.ptr != .none) "*" else "", try m.types.format(m.arena, inst.ty) });
    }
    switch (inst.op) {
        .constant => |c| switch (c) {
            .int => |v| try w.print("const {d}", .{v}),
            .float => |v| try w.print("const {d}", .{v}),
        },
        .param => |p| try w.print("param {d}", .{p}),
        .global => |g| try w.print("global @{d}", .{g}),
        .local_var => try w.writeAll("local_var"),
        .load => |p| try w.print("load %{d}", .{p.index()}),
        .store => |s| try w.print("store %{d}, %{d}", .{ s.ptr.index(), s.value.index() }),
        .access => |a| {
            try w.print("access %{d}", .{a.base.index()});
            for (a.indices) |i| try w.print(", %{d}", .{i.index()});
        },
        .binary => |b| try w.print("{s} %{d}, %{d}", .{ @tagName(b.op), b.lhs.index(), b.rhs.index() }),
        .unary => |u| try w.print("{s} %{d}", .{ @tagName(u.op), u.operand.index() }),
        .cmp => |c| try w.print("cmp.{s} %{d}, %{d}", .{ @tagName(c.op), c.lhs.index(), c.rhs.index() }),
        .convert => |x| try w.print("convert %{d}", .{x.index()}),
        .bitcast => |x| try w.print("bitcast %{d}", .{x.index()}),
        .splat => |x| try w.print("splat %{d}", .{x.index()}),
        .extract => |x| try w.print("extract %{d}, {d}", .{ x.agg.index(), x.index }),
        .insert => |x| try w.print("insert %{d}, %{d}, {d}", .{ x.agg.index(), x.value.index(), x.index }),
        .construct => |xs| {
            try w.writeAll("construct");
            for (xs, 0..) |x, i| try w.print("{s} %{d}", .{ if (i > 0) "," else "", x.index() });
        },
        .shuffle => |s| {
            try w.print("shuffle %{d}", .{s.vec.index()});
            for (s.components) |c| try w.print(", {d}", .{c});
        },
        .select => |s| try w.print("select %{d}, %{d}, %{d}", .{ s.cond.index(), s.t.index(), s.f.index() }),
        .call => |c| {
            try w.print("call @{d}", .{c.func});
            for (c.args) |a| try w.print(", %{d}", .{a.index()});
        },
        .intrinsic => |c| {
            try w.print("{s}", .{c.name});
            for (c.args, 0..) |a, i| try w.print("{s} %{d}", .{ if (i > 0) "," else "", a.index() });
        },
        .res_load => |x| try w.print("res_load %{d}[%{d}]", .{ x.res.index(), x.index.index() }),
        .res_store => |x| try w.print("res_store %{d}[%{d}], %{d}", .{ x.res.index(), x.index.index(), x.value.index() }),
        .method => |x| {
            try w.print("%{d}.{s}(", .{ x.res.index(), x.name });
            for (x.args, 0..) |a, i| try w.print("{s}%{d}", .{ if (i > 0) ", " else "", a.index() });
            try w.writeByte(')');
        },
        .input => |i| try w.print("input {d}", .{i}),
        .output => |o| try w.print("output {d}, %{d}", .{ o.element, o.value.index() }),
        .phi => |ins| {
            try w.writeAll("phi");
            for (ins, 0..) |in, i| try w.print("{s} [%{d}, b{d}]", .{ if (i > 0) "," else "", in.value.index(), in.block.index() });
        },
    }
    try w.writeByte('\n');
}
