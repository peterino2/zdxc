//! Tests for the options of Epic's DXC fork (Unreal Engine's
//! ShaderConductor passes them): each compiles HLSL to SPIR-V through
//! `compile` and reads the module's decorations, as checked against
//! Unreal's own DXC (`spirv-dis` of both).

const std = @import("std");
const compile = @import("../compile.zig");

const Module = struct {
    words: []const u32,

    fn ops(m: Module) Iter {
        return .{ .w = m.words[5..] };
    }

    const Inst = struct { op: u16, args: []const u32 };
    const Iter = struct {
        w: []const u32,
        fn next(it: *Iter) ?Inst {
            if (it.w.len == 0) return null;
            const n = it.w[0] >> 16;
            const r: Inst = .{ .op = @truncate(it.w[0]), .args = it.w[1..n] };
            it.w = it.w[n..];
            return r;
        }
    };

    /// The id OpName names `name`.
    fn named(m: Module, name: []const u8) ?u32 {
        var it = m.ops();
        while (it.next()) |i| if (i.op == 5) { // OpName
            const s = std.mem.sliceAsBytes(i.args[1..]);
            if (std.mem.eql(u8, std.mem.sliceTo(s, 0), name)) return i.args[0];
        };
        return null;
    }

    /// The literal of member decoration `deco` on member `member` of `id`.
    fn memberDeco(m: Module, id: u32, member: u32, d: u32) ?u32 {
        var it = m.ops();
        while (it.next()) |i| if (i.op == 72 and i.args[0] == id and i.args[1] == member and i.args[2] == d) return i.args[3]; // OpMemberDecorate
        return null;
    }

    /// The literal of decoration `deco` on `id` (0 for none), or null.
    fn deco(m: Module, id: u32, d: u32) ?u32 {
        var it = m.ops();
        while (it.next()) |i| if (i.op == 71 and i.args[0] == id and i.args[1] == d) return if (i.args.len > 2) i.args[2] else 0; // OpDecorate
        return null;
    }

    /// How many instructions decorate anything with `d`.
    fn decoCount(m: Module, d: u32) usize {
        var n: usize = 0;
        var it = m.ops();
        while (it.next()) |i| {
            if (i.op == 71 and i.args[1] == d) n += 1;
        }
        return n;
    }

    /// How many GLSL.std.450 instructions `inst` there are.
    fn extInstCount(m: Module, inst: u32) usize {
        var n: usize = 0;
        var it = m.ops();
        while (it.next()) |i| {
            if (i.op == 12 and i.args[3] == inst) n += 1; // OpExtInst
        }
        return n;
    }

    /// The ArrayStride of the type of member `member` of struct `id`.
    fn memberStride(m: Module, id: u32, member: u32) ?u32 {
        var it = m.ops();
        while (it.next()) |i| if (i.op == 30 and i.args[0] == id) return m.deco(i.args[1 + member], 6); // OpTypeStruct; ArrayStride
        return null;
    }
};

const Out = struct { m: ?Module, diagnostics: []const u8 };

fn spirv(a: std.mem.Allocator, profile: []const u8, extra: []const []const u8, src: []const u8) !Out {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ "-T", profile, "-E", "main", "-spirv" });
    try args.appendSlice(a, extra);
    const r = try compile.compile(a, .{ .args = args.items, .source = src, .io = threaded.io(), .compat_notes = false });
    const obj = r.object orelse return .{ .m = null, .diagnostics = r.diagnostics };
    const words = try a.alloc(u32, obj.len / 4);
    @memcpy(std.mem.sliceAsBytes(words), obj[0 .. words.len * 4]);
    return .{ .m = .{ .words = words }, .diagnostics = r.diagnostics };
}

fn ok(a: std.mem.Allocator, profile: []const u8, extra: []const []const u8, src: []const u8) !Module {
    const o = try spirv(a, profile, extra, src);
    if (o.m == null) std.debug.print("{s}\n", .{o.diagnostics});
    return o.m orelse error.TestUnexpectedResult;
}

const offset = 35;
const expectEqual = std.testing.expectEqual;

const layout_src =
    \\cbuffer CB { float a; float3 b; float c[2]; float2 d; };
    \\float g0; float3 g1; float g2[2];
    \\struct S { float x; float3 y; };
    \\StructuredBuffer<S> SB;
    \\RWStructuredBuffer<float4> O;
    \\[numthreads(1,1,1)] void main() { O[0] = float4(a + b.x + c[1] + d.y, g0 + g1.y + g2[1], SB[0].x + SB[1].y.z, 0); }
;

test "-fvk-ue5-layout: strict std140 constant buffers, relaxed std430 the rest" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // (Offsets as Unreal's DXC gives them.)
    const m = try ok(a, "cs_6_6", &.{"-fvk-ue5-layout"}, layout_src);
    const cb = m.named("type.CB").?;
    try expectEqual(@as(?u32, 16), m.memberDeco(cb, 1, offset)); // float3 b: vector alignment, not 4
    try expectEqual(@as(?u32, 32), m.memberDeco(cb, 2, offset));
    try expectEqual(@as(?u32, 16), m.memberStride(cb, 2)); // float c[2]
    try expectEqual(@as(?u32, 64), m.memberDeco(cb, 3, offset)); // float2 d: after the array
    const g = m.named("type.$Globals").?;
    try expectEqual(@as(?u32, 16), m.memberDeco(g, 1, offset));
    try expectEqual(@as(?u32, 32), m.memberDeco(g, 2, offset));
    // Structured buffers: relaxed std430, as by default.
    const s = m.named("S").?;
    try expectEqual(@as(?u32, 4), m.memberDeco(s, 1, offset));

    // Without it: relaxed std140 (float3 at 4).
    const d = try ok(a, "cs_6_6", &.{}, layout_src);
    try expectEqual(@as(?u32, 4), d.memberDeco(d.named("type.CB").?, 1, offset));
}

test "-fvk-ue5-layout with -fvk-use-scalar-layout: $Globals stays std140" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // (Unreal's Vulkan SM6 shaders pass both.)
    const m = try ok(a, "cs_6_6", &.{ "-fvk-ue5-layout", "-fvk-use-scalar-layout" }, layout_src);
    const cb = m.named("type.CB").?;
    try expectEqual(@as(?u32, 4), m.memberDeco(cb, 1, offset)); // scalar
    try expectEqual(@as(?u32, 4), m.memberStride(cb, 2));
    const g = m.named("type.$Globals").?;
    try expectEqual(@as(?u32, 16), m.memberDeco(g, 1, offset)); // std140
    try expectEqual(@as(?u32, 16), m.memberStride(g, 2));
}

const vs_src =
    \\struct VSOut { precise float4 pos : SV_Position; float4 c : COLOR; };
    \\VSOut main(float4 p : POSITION) { VSOut o; o.pos = p * 2 + 1; o.c = p; return o; }
;

test "-fspv-support-precise-outputs: NoContraction on precise built-in outputs" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const no_contraction = 42;
    try expectEqual(@as(usize, 0), (try ok(a, "vs_6_6", &.{}, vs_src)).decoCount(no_contraction));
    const m = try ok(a, "vs_6_6", &.{"-fspv-support-precise-outputs"}, vs_src);
    try expectEqual(@as(usize, 1), m.decoCount(no_contraction));
    try expectEqual(@as(?u32, 0), m.deco(m.named("out.var.SV_Position").?, no_contraction));
    // A precise parameter and a precise function, too.
    const p = try ok(a, "vs_6_6", &.{"-fspv-support-precise-outputs"}, "void main(float4 p : POSITION, out precise float4 pos : SV_Position) { pos = p; }");
    try expectEqual(@as(usize, 1), p.decoCount(no_contraction));
    const f = try ok(a, "vs_6_6", &.{"-fspv-support-precise-outputs"}, "precise float4 main(float4 p : POSITION) : SV_Position { return p; }");
    try expectEqual(@as(usize, 1), f.decoCount(no_contraction));
}

test "-fspv-svposition-implicit-invariant and -fvk-ue5-layout: SV_Position outputs are Invariant" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const invariant = 18;
    try expectEqual(@as(usize, 0), (try ok(a, "vs_6_6", &.{}, vs_src)).decoCount(invariant));
    try expectEqual(@as(usize, 1), (try ok(a, "vs_6_6", &.{"-fspv-svposition-implicit-invariant"}, vs_src)).decoCount(invariant));
    const m = try ok(a, "vs_6_6", &.{"-fvk-ue5-layout"}, vs_src);
    try expectEqual(@as(?u32, 0), m.deco(m.named("out.var.SV_Position").?, invariant));
    // Not a pixel shader's SV_Position input, nor a geometry shader's
    // Append (as Epic's DXC).
    try expectEqual(@as(usize, 0), (try ok(a, "ps_6_6", &.{"-fvk-ue5-layout"}, "float4 main(float4 p : SV_Position) : SV_Target { return p; }")).decoCount(invariant));
    const gs =
        \\struct V { float4 p : SV_Position; };
        \\[maxvertexcount(3)] void main(triangle V i[3], inout TriangleStream<V> s) { for (int k = 0; k < 3; k++) s.Append(i[k]); }
    ;
    try expectEqual(@as(usize, 0), (try ok(a, "gs_6_6", &.{"-fvk-ue5-layout"}, gs)).decoCount(invariant));
}

test "-fspv-fusemuladd: an add of a multiply is an Fma, when optimizing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\RWStructuredBuffer<float4> O; cbuffer C { float4 x, y, z, w; };
        \\[numthreads(1,1,1)] void main() { O[0] = x * y + z; O[1] = z + x * y; O[2] = x * y - z; O[3] = x * y + z * w; }
    ;
    const fma = 50;
    try expectEqual(@as(usize, 0), (try ok(a, "cs_6_6", &.{}, src)).extInstCount(fma));
    // O[0], O[1] and O[3]; not the subtraction.
    try expectEqual(@as(usize, 3), (try ok(a, "cs_6_6", &.{"-fspv-fusemuladd"}, src)).extInstCount(fma));
    try expectEqual(@as(usize, 0), (try ok(a, "cs_6_6", &.{ "-fspv-fusemuladd", "-Od" }, src)).extInstCount(fma));
    try expectEqual(@as(usize, 0), (try ok(a, "cs_6_6", &.{ "-fspv-fusemuladd", "-O0" }, src)).extInstCount(fma));
}

test "-fspv-force-subpass-image-depth-false: subpass images are not depth" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "[[vk::input_attachment_index(0)]] SubpassInput<float4> In0; float4 main() : SV_Target { return In0.SubpassLoad(); }";
    for ([_]struct { []const []const u8, u32 }{ .{ &.{}, 2 }, .{ &.{"-fspv-force-subpass-image-depth-false"}, 0 } }) |c| {
        const m = try ok(a, "ps_6_6", c[0], src);
        var it = m.ops();
        var depth: ?u32 = null;
        while (it.next()) |i| if (i.op == 25 and i.args[2] == 6) { // OpTypeImage, SubpassData
            depth = i.args[3];
        };
        try expectEqual(@as(?u32, c[1]), depth);
    }
}

test "-fspv-no-scalar-block-layout: structured buffer elements that need padding fail" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad = "struct Q { float3 a; }; StructuredBuffer<Q> B; float4 main() : SV_Target { return B[0].a.x; }";
    const good = "struct P { float3 a; float b; }; StructuredBuffer<P> B; float4 main() : SV_Target { return B[0].b; }";
    _ = try ok(a, "ps_6_6", &.{}, bad);
    const o = try spirv(a, "ps_6_6", &.{"-fspv-no-scalar-block-layout"}, bad);
    try std.testing.expect(o.m == null);
    try std.testing.expect(std.mem.indexOf(u8, o.diagnostics, "'VK_EXT_scalar_block_layout' not supported") != null);
    _ = try ok(a, "ps_6_6", &.{"-fspv-no-scalar-block-layout"}, good);
}

test "Epic's other options are accepted" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "RWStructuredBuffer<float4> B[4]; [numthreads(1,1,1)] void main(uint3 id : SV_DispatchThreadID) { B[id.x & 3][id.y] = 1; }";
    // ShaderConductor's SPIR-V arguments for an Unreal Vulkan SM6 shader.
    _ = try ok(a, "cs_6_6", &.{ "-fvk-ue5-layout", "-fvk-use-dx-position-w", "-fspv-reflect", "-fvk-use-scalar-layout", "-fspv-preserve-storage-input", "-fspv-svposition-implicit-invariant", "-fvk-allow-rwstructuredbuffer-arrays", "-fspv-use-legacy-buffer-matrix-order", "-fspv-target-env=vulkan1.3" }, src);
    // Fragment shaders keep their unused inputs with or without
    // -fspv-preserve-storage-input.
    const ps = "float4 main(float4 unused : TEXCOORD0, float4 used : TEXCOORD1) : SV_Target { return used; }";
    try std.testing.expect((try ok(a, "ps_6_6", &.{"-fspv-preserve-storage-input"}, ps)).named("in.var.TEXCOORD0") != null);
}

test "[[vk::location, vk::index]] after a parameter's name (Unreal's dual-source blending)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "void main(out float4 c0 [[vk::location(0), vk::index(0)]] : SV_Target0, out float4 c1 [[vk::location(0), vk::index(1)]] : SV_Target1) { c0 = 1; c1 = 2; }";
    const m = try ok(a, "ps_6_6", &.{}, src);
    const t1 = m.named("out.var.SV_Target1").?;
    try expectEqual(@as(?u32, 0), m.deco(t1, 30)); // Location
    try expectEqual(@as(?u32, 1), m.deco(t1, 32)); // Index
}
