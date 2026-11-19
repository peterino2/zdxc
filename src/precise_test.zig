//! Tests for `precise` and -Gis (IEEE strictness): which instructions
//! are precise in DXIL (dxil/precise.zig) and SPIR-V (ir/precise.zig), as
//! checked against dxc (its DXIL listings and `spirv-dis`).

const std = @import("std");
const compile = @import("compile.zig");
const module = @import("dxil/module.zig");
const cse = @import("dxil/cse.zig");
const test_dxil = @import("test_dxil.zig");

const expectEqual = std.testing.expectEqual;

fn run(a: std.mem.Allocator, profile: []const u8, extra: []const []const u8, src: []const u8) !compile.Result {
    return test_dxil.compile(a, profile, extra, src, null);
}

/// What a DXIL compile makes precise.
const Dxil = test_dxil.FloatOps;

/// `.{ fast, precise }`.
fn expectOps(expected: [2]usize, actual: [2]usize) !void {
    try std.testing.expectEqualSlices(usize, &expected, &actual);
}

test "precise: what flows into a precise local, through the locals it reads" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // dxc: everything but the two additions writing o[0] (y is read by
    // the precise z, so its computation is precise too).
    const c = try Dxil.of(arena.allocator(), "cs_6_0",
        \\RWStructuredBuffer<float> o; cbuffer C { float s, t, u; }
        \\[numthreads(1,1,1)] void main() {
        \\  float shared_ = s * t;
        \\  precise float x = shared_ * t + s;
        \\  float y = x * u + shared_;
        \\  precise float z;
        \\  z = y / 7;
        \\  z += u * u;
        \\  o[0] = x + y + z;
        \\}
    );
    try expectOps(.{ 2, 3 }, c.fadd);
    try expectOps(.{ 0, 4 }, c.fmul);
    try expectOps(.{ 0, 1 }, c.fdiv);
}

test "precise: only the stores that reach a read (as dxc's, after mem2reg)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // `s * t`, overwritten before the precise read, stays fast.
    const c = try Dxil.of(arena.allocator(), "cs_6_0",
        \\RWStructuredBuffer<float> o; cbuffer C { float s, t, u; }
        \\[numthreads(1,1,1)] void main() { float t0 = s * t; o[1] = t0; t0 = u * u; precise float x = t0; o[0] = x; }
    );
    try expectOps(.{ 1, 1 }, c.fmul);
}

test "precise: a struct's precise member, not its others" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const c = try Dxil.of(arena.allocator(), "vs_6_0",
        \\cbuffer C { float k; }
        \\struct O { precise float4 pos : SV_Position; float4 c : COLOR; };
        \\O main(float4 p : P) { O o; o.pos = p * p + k; o.c = p * k + 1; return o; }
    );
    try expectOps(.{ 4, 4 }, c.fmul);
    try expectOps(.{ 4, 4 }, c.fadd);
}

test "precise: a dynamic index makes the whole local precise" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // dxc: the multiply and add stored to arr[0] are precise, though
    // `.y` of the loaded element is member 1 (of the element, not arr).
    const load = try Dxil.of(a, "cs_6_0",
        \\RWStructuredBuffer<float> o; cbuffer C { float s, t; uint i; }
        \\[numthreads(1,1,1)] void main() {
        \\  float2 arr[2];
        \\  arr[0] = float2(s * t, s * t + 1);
        \\  arr[1] = float2(s, t);
        \\  precise float x = arr[i].y;
        \\  o[0] = x;
        \\}
    );
    try expectOps(.{ 0, 1 }, load.fmul);
    try expectOps(.{ 0, 1 }, load.fadd);
    // A store through a dynamic index into a partly precise local: all
    // of the stored value.
    const store = try Dxil.of(a, "cs_6_0",
        \\RWStructuredBuffer<float> o; cbuffer C { float s, t; uint i; }
        \\[numthreads(1,1,1)] void main() {
        \\  float2 arr[2];
        \\  arr[0] = float2(s, t);
        \\  arr[1] = float2(s, t);
        \\  arr[i] = float2(s * t, s + t);
        \\  precise float x = arr[1].y;
        \\  o[0] = x;
        \\}
    );
    try expectOps(.{ 0, 1 }, store.fmul);
    try expectOps(.{ 0, 1 }, store.fadd);
}

test "precise: out parameters and the entry's result" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try Dxil.of(a, "vs_6_0",
        \\cbuffer C { float k; }
        \\void main(float4 p : P, out precise float4 pos : SV_Position, out float4 c : COLOR) { pos = p * p + k; c = p * k + 1; }
    );
    try expectOps(.{ 4, 4 }, out.fmul);
    // `p` reaches the precise code: its loadInputs are `!dx.precise`.
    try expectEqual(@as(usize, 4), out.precise_calls);
    const ret = try Dxil.of(a, "ps_6_0",
        \\cbuffer C { float k; }
        \\precise float4 main(float4 p : P) : SV_Target { return p * p + k; }
    );
    try expectOps(.{ 0, 4 }, ret.fmul);
    try expectOps(.{ 0, 4 }, ret.fadd);
}

test "precise: DXIL follows calls (dxc marks after inlining), SPIR-V does not" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\RWStructuredBuffer<float> o; cbuffer C { float s, u; }
        \\float helper(float v) { return v * u + 3; }
        \\[numthreads(1,1,1)] void main() { precise float x = helper(s); o[0] = x; }
    ;
    try expectOps(.{ 0, 1 }, (try Dxil.of(a, "cs_6_0", src)).fmul);
    const spirv = try SpirvModule.of(a, "cs_6_0", &.{}, src);
    try expectEqual(@as(usize, 0), spirv.count(.decorate, &.{ null, no_contraction }));
}

test "precise: through static and groupshared globals" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // dxc's DXIL: `set`'s stores to g and h.y are precise, h.x's is not;
    // its SPIR-V: only main's add (it does not follow g into `set`).
    const across =
        \\RWStructuredBuffer<float> o; cbuffer C { float s, u; }
        \\static float g;
        \\static float2 h;
        \\void set(float x) { g = x * s + u; h.x = x * u; h.y = x + s; }
        \\[numthreads(1,1,1)] void main() { set(o[1]); precise float z = g + h.y; o[0] = z + h.x; }
    ;
    const dxil = try Dxil.of(a, "cs_6_0", across);
    try expectOps(.{ 1, 1 }, dxil.fmul);
    try expectOps(.{ 1, 3 }, dxil.fadd);
    const spirv = try SpirvModule.of(a, "cs_6_0", &.{}, across);
    try expectEqual(@as(usize, 1), spirv.count(.decorate, &.{ null, no_contraction }));
    // Within one function both follow it, groupshared too.
    const within =
        \\RWStructuredBuffer<float> o; cbuffer C { float s, u; }
        \\groupshared float g;
        \\[numthreads(1,1,1)] void main() { g = o[1] * s + u; GroupMemoryBarrierWithGroupSync(); precise float z = g; o[0] = z; }
    ;
    const dxil_in = try Dxil.of(a, "cs_6_0", within);
    try expectOps(.{ 0, 1 }, dxil_in.fmul);
    try expectOps(.{ 0, 1 }, dxil_in.fadd);
    const spirv_in = try SpirvModule.of(a, "cs_6_0", &.{}, within);
    try expectEqual(@as(usize, 2), spirv_in.count(.decorate, &.{ null, no_contraction }));
}

test "precise: by-value arguments only as the callee's precise code reads them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // dxc: `s * t` (read by the precise result) is precise, `s + t` (only
    // stored) is not; its SPIR-V marks neither (no crossing calls).
    const src =
        \\RWStructuredBuffer<float> o; cbuffer C { float s, t, u; }
        \\float helper(float v, float w) { o[1] = w; return v * u + 3; }
        \\[numthreads(1,1,1)] void main() { precise float x = helper(s * t, s + t); o[0] = x; }
    ;
    const dxil = try Dxil.of(a, "cs_6_0", src);
    try expectOps(.{ 0, 2 }, dxil.fmul);
    try expectOps(.{ 1, 1 }, dxil.fadd); // `s + t`, `+ 3`
    const spirv = try SpirvModule.of(a, "cs_6_0", &.{}, src);
    try expectEqual(@as(usize, 0), spirv.count(.decorate, &.{ null, no_contraction }));
}

test "precise: a callee's precise code reading an inout parameter" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // dxc: the caller's `s + t`, stored to the argument, is precise.
    const c = try Dxil.of(arena.allocator(), "cs_6_0",
        \\RWStructuredBuffer<float> o; cbuffer C { float s, t, u; }
        \\void h(inout float v) { precise float z = v * u; o[0] = z; }
        \\[numthreads(1,1,1)] void main() { float a = s + t; h(a); }
    );
    try expectOps(.{ 0, 1 }, c.fadd);
}

test "precise: DXIL marks a callee per call site" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // dxc: `helper(t)` stays fast; as if inlined by hand.
    const calls = try run(a, "cs_6_0", &.{},
        \\RWStructuredBuffer<float> o; cbuffer C { float s, t, u; }
        \\float helper(float v) { return v * u + 3; }
        \\[numthreads(1,1,1)] void main() { precise float x = helper(s); o[0] = x; o[1] = helper(t); }
    );
    const inlined = try run(a, "cs_6_0", &.{},
        \\RWStructuredBuffer<float> o; cbuffer C { float s, t, u; }
        \\[numthreads(1,1,1)] void main() { precise float x = s * u + 3; o[0] = x; o[1] = t * u + 3; }
    );
    const both = try run(a, "cs_6_0", &.{},
        \\RWStructuredBuffer<float> o; cbuffer C { float s, t, u; }
        \\[numthreads(1,1,1)] void main() { precise float x = s * u + 3; o[0] = x; precise float y = t * u + 3; o[1] = y; }
    );
    try std.testing.expectEqualSlices(u8, inlined.object.?, calls.object.?);
    try std.testing.expect(!std.mem.eql(u8, both.object.?, calls.object.?));
}

test "precise: DXIL marks the conditions deciding a precise value, SPIR-V does not" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hdr = "RWStructuredBuffer<float> o; cbuffer C { float s, t, u; }\n[numthreads(1,1,1)] void main() { ";
    // A select's condition.
    const sel = hdr ++ "precise float x = (s * t > u) ? s : t; o[0] = x; }";
    const sel_c = try Dxil.of(a, "cs_6_0", sel);
    try expectOps(.{ 0, 1 }, sel_c.fmul);
    try expectOps(.{ 0, 1 }, sel_c.fcmp);
    try expectEqual(@as(usize, 0), (try SpirvModule.of(a, "cs_6_0", &.{}, sel)).count(.decorate, &.{ null, no_contraction }));
    // A branch a precise store depends on, and (transitively) the branch
    // that one depends on: dxc marks both multiplies.
    const nested = try Dxil.of(a, "cs_6_0", hdr ++
        \\precise float x = s;
        \\if (s * t > u) { o[3] = 3; if (t * u > s) { x = u; o[2] = 2; } }
        \\o[0] = x; }
    );
    try expectOps(.{ 0, 2 }, nested.fmul);
    // `&&`, through the bool local it is lowered to.
    const both = try Dxil.of(a, "cs_6_0", hdr ++ "precise float x = (s * t > u && t * u > s) ? s : t; o[0] = x; }");
    try expectOps(.{ 0, 2 }, both.fmul);
    // Not a branch whose blocks hold nothing precise.
    const unrelated = try Dxil.of(a, "cs_6_0", hdr ++ "if (s * t > u) o[1] = 1; precise float x = s + u; o[0] = x; }");
    try expectOps(.{ 1, 0 }, unrelated.fmul);
    // A precise local declared inside the branch: dxc marks it too.
    const inside = try Dxil.of(a, "cs_6_0", hdr ++ "if (s * t > u) { precise float x = s + u; o[0] = x; o[1] = 1; } }");
    try expectOps(.{ 0, 1 }, inside.fmul);
    // A loop's break.
    const loop = try Dxil.of(a, "cs_6_0",
        \\RWStructuredBuffer<float> o; cbuffer C { float s, t, u; uint n; }
        \\[numthreads(1,1,1)] void main() { precise float x = s; for (uint i = 0; i < n; i++) { if (u * t > s) break; x += t; } o[0] = x; }
    );
    try expectOps(.{ 0, 1 }, loop.fmul);
}

test "precise: DXIL conditions are those of where a value is computed, not stored (as dxc)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hdr = "RWStructuredBuffer<float> o; cbuffer C { float s, t, u; }\n";
    const cs = "[numthreads(1,1,1)] void main() { ";
    // Computed before the branch, into a local mem2reg promotes: dxc's
    // branch stays fast.
    const before = try Dxil.of(a, "cs_6_0", hdr ++ cs ++ "precise float x = 0; float m = t * u; if (s * t > u) x = m; o[0] = x; }");
    try expectOps(.{ 1, 1 }, before.fmul);
    // Through a callee that only forwards its argument: the same.
    const fwd = try Dxil.of(a, "cs_6_0", hdr ++ "float h(float a) { return a; }\n" ++ cs ++ "precise float x = 0; float m = s + t; if (s * t > u) x = h(m); o[0] = x; }");
    try expectOps(.{ 0, 1 }, fwd.fadd);
    try expectOps(.{ 1, 0 }, fwd.fmul);
    // A callee computing it, called in the branch: the call's conditions.
    const callee = try Dxil.of(a, "cs_6_0", hdr ++ "float g(float a) { return a + u; }\n" ++ cs ++ "precise float x = 0; if (s * t > u) x = g(s); o[0] = x; }");
    try expectOps(.{ 0, 1 }, callee.fmul);
    // A constant in one branch (mem2reg's phi with a constant incoming
    // value): that branch's conditions.
    const phi = try Dxil.of(a, "cs_6_0", hdr ++ cs ++ "float m = s + u; if (s * t > u) m = 0; precise float x = m; o[0] = x; }");
    try expectOps(.{ 0, 1 }, phi.fmul);
    // A precise local read in the branch (dxc keeps it in memory).
    const load = try Dxil.of(a, "cs_6_0", hdr ++ cs ++ "precise float y = s + u; precise float x = 0; if (s * t > u) x = y; o[0] = x; }");
    try expectOps(.{ 0, 1 }, load.fmul);
    // A vector stored to a precise local in the branch: dxc marks it by
    // lanes extracted at the store.
    const vec = try Dxil.of(a, "cs_6_0", "RWStructuredBuffer<float4> o; cbuffer C { float s, t, u; float4 v; }\n" ++ cs ++ "precise float4 x = 0; float4 m = v * t; if (s * t > u) x = m; o[0] = x; }");
    try expectOps(.{ 0, 5 }, vec.fmul);
    // The entry's outputs are written in place: a precise member of the
    // returned struct, and a precise out parameter.
    const ret = try Dxil.of(a, "vs_6_0",
        \\struct O { precise float4 pos : SV_Position; float4 c : COLOR; };
        \\O main(float4 p : P) { O r; r.pos = 0; r.c = p; if (p.x * p.y > 0) r.pos = p; return r; }
    );
    try expectOps(.{ 0, 1 }, ret.fmul);
    const out = try Dxil.of(a, "vs_6_0", "void main(float4 p : P, out precise float4 pos : SV_Position) { pos = 0; if (p.x * p.y > 0) pos = p; }");
    try expectOps(.{ 0, 1 }, out.fmul);
    // Not a plain local (dxc's DXIL ignores it).
    const plain = try Dxil.of(a, "ps_6_0", "float4 main(float4 p : P) : SV_Target { float4 r = 0; if (p.x * p.y > 0) r = p; return r; }");
    try expectOps(.{ 1, 0 }, plain.fmul);
}

test "precise: a hull shader's precise patch constants, not the others" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // dxc: the two edge factors' multiplies, and the two control point
    // reads they come from; not the inside factor's.
    const c = try Dxil.of(arena.allocator(), "hs_6_0",
        \\struct CP { float4 p : POS; };
        \\struct PC { precise float e[3] : SV_TessFactor; float i : SV_InsideTessFactor; };
        \\cbuffer C { float k; }
        \\PC pcf(InputPatch<CP,3> ip) { PC o; o.e[0] = ip[0].p.x * k + 1; o.e[1] = ip[1].p.x * k; o.e[2] = 2; o.i = ip[2].p.y * k; return o; }
        \\[domain("tri")][partitioning("integer")][outputtopology("triangle_cw")][outputcontrolpoints(3)][patchconstantfunc("pcf")]
        \\CP main(InputPatch<CP,3> ip, uint id : SV_OutputControlPointID) { CP o; o.p = ip[id].p * k; return o; }
    );
    try expectOps(.{ 5, 2 }, c.fmul);
    try expectOps(.{ 0, 1 }, c.fadd);
    try expectEqual(@as(usize, 2), c.precise_calls);
}

test "precise: DXIL fcmp is fast outside precise code (as dxc), not in it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A comparison is the only floating-point operation. (The same shape
    // each: a local leaves its type in the module.)
    const src =
        \\RWStructuredBuffer<float> o; cbuffer C { float s, t; }
        \\[numthreads(1,1,1)] void main() { float x = s < t ? 1 : 2; o[0] = x; }
    ;
    const plain = try run(a, "cs_6_0", &.{}, src);
    const strict = try run(a, "cs_6_0", &.{"-Gis"}, src);
    const precise = try run(a, "cs_6_0", &.{},
        \\RWStructuredBuffer<float> o; cbuffer C { float s, t; }
        \\[numthreads(1,1,1)] void main() { precise float x = s < t ? 1 : 2; o[0] = x; }
    );
    try std.testing.expect(!std.mem.eql(u8, plain.object.?, strict.object.?));
    try std.testing.expectEqualSlices(u8, strict.object.?, precise.object.?);
    const container = @import("dxil/container.zig");
    try std.testing.expect(container.hashMatches(plain.object.?));
}

test "precise: a dx.op call merged with a precise one stays precise" {
    var m: module.Module = .init(std.testing.allocator);
    defer m.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const f32_ty = try m.getType(.float);
    const i32_ty = try m.intType(32);
    const unary = try m.addFunction(.{ .name = "dx.op.unary.f32", .ty = try m.fnType(f32_ty, &.{ i32_ty, f32_ty }), .attrs = .nounwind_readnone });
    const f = try m.addFunction(.{ .name = "main", .ty = try m.fnType(f32_ty, &.{}), .num_blocks = 1 });
    const one = try m.constant(.{ .ty = f32_ty, .kind = .{ .float_bits = @as(u32, @bitCast(@as(f32, 2))) } });
    const args = try m.allocator().dupe(module.Value, &.{ try m.constInt(32, 24), one });
    // (The plain call first: the one CSE keeps.)
    const x = try m.addInst(f, .{ .ty = f32_ty, .op = .{ .call = .{ .callee = unary, .args = args } } });
    const y = try m.addInst(f, .{ .ty = f32_ty, .op = .{ .call = .{ .callee = unary, .args = args } }, .md = try m.preciseMd() });
    const z = try m.addInst(f, .{ .ty = f32_ty, .op = .{ .binop = .{ .op = .add, .lhs = x, .rhs = y } } });
    _ = try m.addInst(f, .{ .ty = try m.getType(.void), .op = .{ .ret = z } });
    try std.testing.expect(try cse.run(arena.allocator(), &m, f));
    const insts = m.functions.items[f].insts.items;
    try expectEqual(@as(usize, 3), insts.len);
    try expectEqual(m.precise_md, insts[0].md);
}

// ----------------------------------------------------------------------
// SPIR-V

const no_contraction = 42;

const SpirvModule = struct {
    words: []const u32,

    const Op = enum(u16) { extension = 10, ext_inst = 12, capability = 17, spec_constant = 50, execution_mode = 16, decorate = 71, f_mul = 133 };

    fn of(a: std.mem.Allocator, profile: []const u8, extra: []const []const u8, src: []const u8) !SpirvModule {
        var args: std.ArrayList([]const u8) = .empty;
        try args.append(a, "-spirv");
        try args.appendSlice(a, extra);
        const obj = (try run(a, profile, args.items, src)).object.?;
        const words = try a.alloc(u32, obj.len / 4);
        @memcpy(std.mem.sliceAsBytes(words), obj[0 .. words.len * 4]);
        return .{ .words = words };
    }

    /// Instructions `op` whose operands start with `args` (null: any).
    fn count(m: SpirvModule, op: Op, args: []const ?u32) usize {
        var n: usize = 0;
        var w = m.words[5..];
        while (w.len > 0) {
            const len = w[0] >> 16;
            const ops = w[1..len];
            if (@as(u16, @truncate(w[0])) == @backingInt(op) and ops.len >= args.len) {
                for (args, ops[0..args.len]) |x, y| {
                    if (x != null and x.? != y) break;
                } else n += 1;
            }
            w = w[len..];
        }
        return n;
    }

    fn hasExtension(m: SpirvModule, name: []const u8) bool {
        var w = m.words[5..];
        while (w.len > 0) {
            const len = w[0] >> 16;
            if (@as(u16, @truncate(w[0])) == @backingInt(Op.extension)) {
                const s = std.mem.sliceAsBytes(w[1..len]);
                if (std.mem.eql(u8, std.mem.sliceTo(s, 0), name)) return true;
            }
            w = w[len..];
        }
        return false;
    }
};

test "precise: SPIR-V NoContraction on the arithmetic of the entry's precise outputs" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // (As dxc: a multiply and an add each.)
    const field = try SpirvModule.of(a, "vs_6_0", &.{},
        \\cbuffer C { float k; }
        \\struct O { precise float4 pos : SV_Position; float4 c : COLOR; };
        \\O main(float4 p : P) { O o; o.pos = p * p + k; o.c = p * k + 1; return o; }
    );
    try expectEqual(@as(usize, 2), field.count(.decorate, &.{ null, no_contraction }));
    const param = try SpirvModule.of(a, "vs_6_0", &.{},
        \\cbuffer C { float k; }
        \\void main(float4 p : P, out precise float4 pos : SV_Position, out float4 c : COLOR) { pos = p * p + k; c = p * k + 1; }
    );
    try expectEqual(@as(usize, 2), param.count(.decorate, &.{ null, no_contraction }));
    // dxc decorates a float `mad` (GLSL Fma) even outside precise code.
    const mad = try SpirvModule.of(a, "cs_6_0", &.{},
        \\RWStructuredBuffer<float4> o; cbuffer C { float4 x, y, z; int4 i; }
        \\[numthreads(1,1,1)] void main() { o[0] = mad(x, y, z) + x * y + float4(mad(i, i, i)); }
    );
    try expectEqual(@as(usize, 3), mad.count(.decorate, &.{ null, no_contraction })); // Fma, IMul, IAdd
}

test "precise: SPIR-V honors precise functions and parameters, DXIL does not (as dxc)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A precise function: what it returns (its multiply and add), not the
    // caller's use of it.
    const func =
        \\RWStructuredBuffer<float> o; cbuffer C { float s, t, u; }
        \\precise float pf(float v) { return v * s + t; }
        \\[numthreads(1,1,1)] void main() { o[0] = pf(u) * t; }
    ;
    try expectEqual(@as(usize, 2), (try SpirvModule.of(a, "cs_6_0", &.{}, func)).count(.decorate, &.{ null, no_contraction }));
    try expectEqual(@as(usize, 0), (try Dxil.of(a, "cs_6_0", func)).precise());
    // Precise parameters are precise storage in the callee: `pin`'s store
    // to `v` (not `v * u`), `pio`'s to `r`, `pr`'s to `r` (not its
    // result). In the caller, the arguments: `s * u` stored to the `r`
    // passed to `pio`, and `u * t` passed to `pin`. dxc: 5 multiplies and
    // 2 adds.
    const params =
        \\RWStructuredBuffer<float> o; cbuffer C { float s, t, u; }
        \\float pin(precise float v) { v = v * s + t; return v * u; }
        \\void pio(inout precise float r) { r = r * t + s; }
        \\float pr(float v, precise out float r) { r = v * t; return v * s; }
        \\[numthreads(1,1,1)] void main() { float r = s * u; pio(r); float q; o[0] = pin(u * t) + r + pr(s, q) + q; }
    ;
    try expectEqual(@as(usize, 7), (try SpirvModule.of(a, "cs_6_0", &.{}, params)).count(.decorate, &.{ null, no_contraction }));
    try expectEqual(@as(usize, 0), (try Dxil.of(a, "cs_6_0", params)).precise());
}

test "precise: SPIR-V does not merge a precise multiply with an equal plain one" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // dxc: two OpFMul, the precise one NoContraction.
    const m = try SpirvModule.of(arena.allocator(), "cs_6_0", &.{},
        \\RWStructuredBuffer<float> o; cbuffer C { float s, t; }
        \\[numthreads(1,1,1)] void main() { float a = s * t; precise float p = s * t; o[0] = a; o[1] = p; }
    );
    try expectEqual(@as(usize, 2), m.count(.f_mul, &.{}));
    try expectEqual(@as(usize, 1), m.count(.decorate, &.{ null, no_contraction }));
}

test "precise: -fspv-fusemuladd fuses no precise arithmetic" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const m = try SpirvModule.of(arena.allocator(), "cs_6_0", &.{"-fspv-fusemuladd"},
        \\RWStructuredBuffer<float> o; cbuffer C { float a, b, c; }
        \\[numthreads(1,1,1)] void main() { precise float x = a * b + c; o[0] = x; o[1] = a * c + b; }
    );
    try expectEqual(@as(usize, 1), m.count(.ext_inst, &.{ null, null, null, 50 })); // the plain one's Fma
    try expectEqual(@as(usize, 2), m.count(.decorate, &.{ null, no_contraction }));
    const strict = try SpirvModule.of(arena.allocator(), "cs_6_0", &.{ "-fspv-fusemuladd", "-Gis" },
        \\RWStructuredBuffer<float> o; cbuffer C { float a, b, c; }
        \\[numthreads(1,1,1)] void main() { o[1] = a * c + b; }
    );
    try expectEqual(@as(usize, 0), strict.count(.ext_inst, &.{ null, null, null, 50 }));
}

test "constant expressions round to their type at each step (IEEE, as dxc)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const m = try SpirvModule.of(arena.allocator(), "cs_6_0", &.{},
        \\[[vk::constant_id(0)]] const float k0 = 16777216.0f + 1.0f - 16777216.0f;
        \\[[vk::constant_id(1)]] const float k1 = 1e30f * 1e30f / 1e30f;
        \\RWStructuredBuffer<float> o;
        \\[numthreads(1,1,1)] void main() { o[0] = k0 + k1; }
    );
    // (In f64: 1 and 1e30.)
    try expectEqual(@as(usize, 1), m.count(.spec_constant, &.{ null, null, 0 }));
    try expectEqual(@as(usize, 1), m.count(.spec_constant, &.{ null, null, 0x7f800000 }));
}

const strict_src =
    \\RWStructuredBuffer<float4> o; cbuffer C { float4 a, b, c; float s; }
    \\[numthreads(1,1,1)] void main() { o[0] = mad(a, b, c) + a * s - b / c + sqrt(s); }
;

test "-Gis: SPIR-V preserves signed zeros, infinities and NaNs, and contracts nothing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plain = try SpirvModule.of(a, "cs_6_0", &.{}, strict_src);
    try expectEqual(@as(usize, 1), plain.count(.decorate, &.{ null, no_contraction })); // `mad` only (as dxc)
    try expectEqual(@as(usize, 0), plain.count(.capability, &.{4466}));

    const m = try SpirvModule.of(a, "cs_6_0", &.{"-Gis"}, strict_src);
    try expectEqual(@as(usize, 1), m.count(.capability, &.{4466})); // SignedZeroInfNanPreserve
    try expectEqual(@as(usize, 1), m.count(.execution_mode, &.{ null, 4461, 32 }));
    try std.testing.expect(m.hasExtension("SPV_KHR_float_controls"));
    // Fma (mad), the multiply, subtract, divide and two adds; not Sqrt.
    try expectEqual(@as(usize, 6), m.count(.decorate, &.{ null, no_contraction }));

    // Core from SPIR-V 1.4.
    const v13 = try SpirvModule.of(a, "cs_6_0", &.{ "-Gis", "-fspv-target-env=vulkan1.3" }, strict_src);
    try expectEqual(@as(usize, 1), v13.count(.capability, &.{4466}));
    try std.testing.expect(!v13.hasExtension("SPV_KHR_float_controls"));
}

// ----------------------------------------------------------------------
// DXIL

test "-Gis: DXIL as if everything were precise" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Everything in strict_src flows into one precise local: no `fast`
    // flags, `!dx.precise` on Sqrt and FMad, as -Gis.
    const all_precise =
        \\RWStructuredBuffer<float4> o; cbuffer C { float4 a, b, c; float s; }
        \\[numthreads(1,1,1)] void main() { precise float4 r = mad(a, b, c) + a * s - b / c + sqrt(s); o[0] = r; }
    ;
    const strict = try Dxil.ofWith(a, "cs_6_0", &.{"-Gis"}, strict_src);
    const plain = try Dxil.of(a, "cs_6_0", strict_src);
    const precise = try Dxil.of(a, "cs_6_0", all_precise);
    try expectEqual(precise, strict);
    try expectEqual(@as(usize, 0), plain.precise());
    try expectEqual(@as(usize, 20), strict.precise());
    try expectEqual(@as(usize, 5), strict.precise_calls); // FMad, Sqrt
}

test "-Gis and precise compile to DXIL" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const container = @import("dxil/container.zig");
    for ([_][]const []const u8{ &.{}, &.{"-Gis"} }) |extra| {
        const r = try run(a, "cs_6_0", extra, strict_src);
        try std.testing.expect(container.hashMatches(r.object.?));
    }
    const p = try run(a, "cs_6_0", &.{},
        \\RWStructuredBuffer<float> o; cbuffer C { float s, t; }
        \\[numthreads(1,1,1)] void main() { precise float x = sqrt(s) * t + s; o[0] = x; }
    );
    try std.testing.expect(container.hashMatches(p.object.?));
}

test "no precise: every floating-point op is fast, whatever pass made it (as dxc)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Unrolled, melded, folded and merged arithmetic, and a comparison.
    const src =
        \\RWStructuredBuffer<float> o; cbuffer C { float s, t, u; float4 v; }
        \\[numthreads(4,1,1)] void main(uint i : SV_GroupIndex) {
        \\  float acc = 0;
        \\  [unroll] for (int k = 0; k < 4; k++) acc += v[k] * s + t;
        \\  float r = (i & 1) ? acc * u : acc / u;
        \\  if (r > s * t) r -= s * t;
        \\  o[i] = r + s * t;
        \\}
    ;
    for ([_][]const []const u8{ &.{}, &.{"-Od"} }) |extra| {
        const c = try Dxil.ofWith(a, "cs_6_0", extra, src);
        try expectEqual(@as(usize, 0), c.precise());
        try std.testing.expect(c.fadd[0] + c.fmul[0] + c.fcmp[0] > 0);
    }
    // A float binop built the way a pass builds one (no `precise` given)
    // is written `fast`; marked precise (as -Gis marks everything), it is
    // not.
    var m: module.Module = .init(std.testing.allocator);
    defer m.deinit();
    const f32_ty = try m.getType(.float);
    const add: module.Inst = .{ .ty = f32_ty, .op = .{ .binop = .{ .op = .add, .lhs = .{ .inst = 0 }, .rhs = .{ .inst = 0 } } } };
    try std.testing.expect(module.fastMath(&m, add));
    var marked = add;
    marked.op.binop.precise = true;
    try std.testing.expect(!module.fastMath(&m, marked));
}

/// A -Zi -Od compile's llvm.dbg.value calls: which variables have one,
/// and whether every function's are in order and name its instructions.
const DbgVars = struct {
    a: std.mem.Allocator,
    names: std.StringHashMapUnmanaged(usize) = .empty,
    well_formed: bool = true,

    pub fn observe(c: *DbgVars, m: *const module.Module) void {
        for (m.functions.items) |f| {
            var last: u32 = 0;
            for (f.dbg_values.items) |dv| {
                if (dv.before < last or dv.before > f.insts.items.len) c.well_formed = false;
                if (dv.val == .inst and dv.val.inst >= f.insts.items.len) c.well_formed = false;
                last = dv.before;
                const name = m.dbg.items[m.dbg.items[dv.variable].local_var.name].string;
                const gop = c.names.getOrPut(c.a, name) catch return;
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
        }
    }
};

test "precise -Zi -Od: a precise local keeps its debug values (promoted after dxil/precise.zig)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\RWStructuredBuffer<float> o;
        \\[numthreads(1, 1, 1)]
        \\void main(uint i : SV_DispatchThreadID) {
        \\    precise float p = o[i] * 2.0;
        \\    float q = o[i + 1] + 1.0;
        \\    p = p + q;
        \\    o[0] = p;
        \\}
    ;
    for ([_][]const []const u8{ &.{ "-Zi", "-Od" }, &.{ "-Zi", "-Od", "-Gis" } }) |extra| {
        var c: DbgVars = .{ .a = arena.allocator() };
        _ = try test_dxil.inspect(arena.allocator(), "cs_6_0", extra, src, &c);
        try std.testing.expect(c.well_formed);
        try std.testing.expect((c.names.get("q") orelse 0) >= 1);
        try std.testing.expect((c.names.get("p") orelse 0) >= 2);
    }
}
