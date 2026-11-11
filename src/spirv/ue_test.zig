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

    /// The member index OpMemberName gives `name`, or null.
    fn memberNamed(m: Module, name: []const u8) ?u32 {
        var it = m.ops();
        while (it.next()) |i| if (i.op == 6) { // OpMemberName
            const s = std.mem.sliceAsBytes(i.args[2..]);
            if (std.mem.eql(u8, std.mem.sliceTo(s, 0), name)) return i.args[1];
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

test "storing one component of a texel reads, updates and writes it back" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "RWTexture2D<float4> T; cbuffer C { uint k; }; [numthreads(1,1,1)] void main(uint2 id : SV_DispatchThreadID) { T[id].y = 3; T[id][k] = 4; }";
    const m = try ok(a, "cs_6_6", &.{}, src);
    var reads: usize = 0;
    var writes: usize = 0;
    var it = m.ops();
    while (it.next()) |i| switch (i.op) {
        98 => reads += 1, // OpImageRead
        99 => writes += 1, // OpImageWrite
        else => {},
    };
    try expectEqual(@as(usize, 2), reads);
    try expectEqual(@as(usize, 2), writes);
}

test "byte-address loads and stores of structs with bitfields" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // (Unreal's FAnimBankBlockHeader.)
    const src =
        \\struct H { float Time; uint A; uint F : 16; uint G : 16; };
        \\RWByteAddressBuffer Buf; RWStructuredBuffer<uint> O;
        \\[numthreads(1,1,1)] void main() { H h = Buf.Load<H>(0); O[0] = h.G; h.F = 7; Buf.Store<H>(16, h); }
    ;
    _ = try ok(a, "cs_6_6", &.{ "-HV", "2021" }, src);
}

test "textures of 64-bit integers (Nanite's visibility buffer)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "Texture2D<uint64_t> T; RWTexture2D<uint64_t> V; [numthreads(1,1,1)] void main(uint2 id : SV_DispatchThreadID) { uint64_t x = T[id]; InterlockedMax(V[id], x); V[id + 1] = x + 1; }";
    const m = try ok(a, "cs_6_6", &.{"-fspv-target-env=vulkan1.3"}, src);
    var it = m.ops();
    var caps: [2]bool = .{ false, false };
    var r64ui = false;
    while (it.next()) |i| {
        if (i.op == 17 and i.args[0] == 5016) caps[0] = true; // OpCapability Int64ImageEXT
        if (i.op == 17 and i.args[0] == 12) caps[1] = true; // Int64Atomics
        if (i.op == 25 and i.args[7] == 40) r64ui = true; // OpTypeImage ... R64ui
    }
    try std.testing.expect(caps[0] and caps[1] and r64ui);
}

test "-fspv-reflect: built-in inputs get their UserSemantic too" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "float4 main(float4 p : POSITION, uint vid : SV_VertexID, uint iid : SV_InstanceID) : SV_Position { return p + vid + iid; }";
    const m = try ok(a, "vs_6_6", &.{"-fspv-reflect"}, src);
    var it = m.ops();
    var n: usize = 0;
    while (it.next()) |i| {
        if (i.op == 5632 and i.args[1] == 5635) n += 1; // OpDecorateString UserSemantic
    }
    // POSITION, SV_VertexID, SV_InstanceID, SV_Position (as dxc).
    try expectEqual(@as(usize, 4), n);
}

test "a source named by a path starting with '/' is not an option (Unreal's virtual paths)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    // "/Engine/..." parsed as an argument would be /E "ngine/...".
    for ([_][]const u8{ "/Engine/Private/HairStrands/HairStrandsSkinUpdate.usf", "" }) |name| {
        const r = try compile.compile(a, .{ .args = &.{ "-T", "cs_6_6", "-E", "main", "-spirv" }, .source = "[numthreads(1,1,1)] void main() {}", .source_name = name, .io = threaded.io(), .compat_notes = false });
        if (r.status != .ok) std.debug.print("{s}\n", .{r.diagnostics});
        try std.testing.expectEqual(compile.Status.ok, r.status);
    }
}

fn countOp(m: Module, op: u16) usize {
    var n: usize = 0;
    var it = m.ops();
    while (it.next()) |i| {
        if (i.op == op) n += 1;
    }
    return n;
}

/// Function-storage OpVariables (what spirv-opt's ssa-rewrite would have to
/// rewrite; dxc's legalized SPIR-V has next to none).
fn functionVars(m: Module) usize {
    var n: usize = 0;
    var it = m.ops();
    while (it.next()) |i| {
        if (i.op == 59 and i.args[2] == 7) n += 1; // OpVariable Function
    }
    return n;
}

test "callees returning from inside loops are inlined (ray generation too)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\RWStructuredBuffer<float> O; cbuffer C { uint n; float lim; };
        \\float find(uint start) {
        \\    for (uint i = start; i < n; i++) {
        \\        for (uint j = 0; j < n; j++) { if (O[i * n + j] > lim) return O[j]; }
        \\        if (O[i] < 0) return -1;
        \\    }
        \\    return 0;
        \\}
        \\[numthreads(1,1,1)] void mainCS() { O[0] = find(1) + find(2); }
        \\[shader("raygeneration")] void mainRG() { O[0] = find(1) + find(2); }
    ;
    const cs = try ok(a, "cs_6_6", &.{ "-E", "mainCS" }, src);
    try expectEqual(@as(usize, 1), countOp(cs, 54)); // OpFunction
    try expectEqual(@as(usize, 0), functionVars(cs));
    const rg = try ok(a, "lib_6_6", &.{ "-E", "mainRG", "-fspv-target-env=vulkan1.3" }, src);
    try expectEqual(@as(usize, 1), countOp(rg, 54));
    try expectEqual(@as(usize, 0), functionVars(rg));
}

test "inlining leaves no chains of blocks" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\RWStructuredBuffer<float> O;
        \\float f(float x) { return x * 2 + 1; }
        \\[numthreads(1,1,1)] void main() { O[0] = f(f(f(f(f(f(f(f(O[1])))))))); }
    ;
    const m = try ok(a, "cs_6_6", &.{}, src);
    try expectEqual(@as(usize, 1), countOp(m, 248)); // OpLabel: one block
}

test "statics of a fully inlined shader are promoted, not Private variables" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // (Unreal's ray tracing shaders copy their uniforms into statics.)
    const src =
        \\RWStructuredBuffer<float4> O; cbuffer C { float4 u; float4x4 w; };
        \\static float4 su; static float4x4 sw;
        \\float4 use() { return mul(sw, su); }
        \\[shader("raygeneration")] void main() { su = u; sw = w; O[0] = use(); }
    ;
    const m = try ok(a, "lib_6_6", &.{"-fspv-target-env=vulkan1.3"}, src);
    var it = m.ops();
    var private_uses: usize = 0;
    var private_vars: std.AutoHashMapUnmanaged(u32, void) = .empty;
    while (it.next()) |i| if (i.op == 59 and i.args[2] == 6) try private_vars.put(a, i.args[1], {}); // OpVariable Private
    it = m.ops();
    while (it.next()) |i| switch (i.op) {
        61, 65 => if (private_vars.contains(i.args[2])) {
            private_uses += 1; // OpLoad / OpAccessChain
        },
        62 => if (private_vars.contains(i.args[0])) {
            private_uses += 1; // OpStore
        },
        else => {},
    };
    try expectEqual(@as(usize, 0), private_uses);
    try expectEqual(@as(usize, 0), functionVars(m));
}

test "locals indexed by a dynamic component are promoted" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // (Unreal's FDFVector3 and DFGetComponent.)
    const src =
        \\struct V3 { float3 High; float3 Low; };
        \\RWStructuredBuffer<float> O; cbuffer C { float3 h, l; int k; };
        \\float get(V3 v, int c) { return v.High[c] + v.Low[c]; }
        \\[numthreads(1,1,1)] void main() {
        \\    V3 v; v.High = h; v.Low = l;
        \\    float3 x = h; x[k] = 7;
        \\    O[0] = get(v, k) + x[k ^ 1];
        \\}
    ;
    const m = try ok(a, "cs_6_6", &.{}, src);
    try expectEqual(@as(usize, 0), functionVars(m));
}

test "a static const struct holding resources (Nanite's FOutputQueue)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\struct FWorkQueueState { uint ReadOffset; uint WriteOffset; int TaskCount; };
        \\struct FOutputQueue {
        \\    RWByteAddressBuffer DataBuffer; RWStructuredBuffer<FWorkQueueState> StateBuffer; uint StateIndex; uint Size;
        \\    uint Add() { uint w; InterlockedAdd(StateBuffer[StateIndex].WriteOffset, 1, w); return w; }
        \\    void Store4(uint at, uint4 v) { DataBuffer.Store4(at, v); }
        \\};
        \\RWByteAddressBuffer D; RWStructuredBuffer<FWorkQueueState> S; cbuffer C { uint MaxN; };
        \\static const FOutputQueue Q = { D, S, 0, MaxN };
        \\[numthreads(64,1,1)] void main(uint3 id : SV_DispatchThreadID) { uint w = Q.Add(); if (w < Q.Size) Q.Store4(w * 16, uint4(id, 1)); }
    ;
    const m = try ok(a, "cs_6_6", &.{}, src);
    try expectEqual(@as(usize, 1), countOp(m, 234)); // OpAtomicIAdd
}

test "a struct copied with a resource member never set" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // (Unreal's FComputeBoneMatrixInputs.SectionBoneMap; every resource of
    // its type is in a bindless heap.)
    const src =
        \\struct In { Buffer<float4> M; Buffer<uint> Unused; uint Off; };
        \\typedef Buffer<float4> SafeT; SafeT Heap[]; cbuffer C { uint o0; uint idx; };
        \\static const SafeT S0 = Heap[idx];
        \\RWBuffer<float4> O;
        \\In make(Buffer<float4> b, uint off) { In r; r.M = b; r.Off = off; return r; }
        \\float4 use(In i, uint k) { return i.M[i.Off + k]; }
        \\[numthreads(64,1,1)] void main(uint3 id : SV_DispatchThreadID) { In x = make(S0, o0); O[id.x] = use(x, id.x); }
    ;
    _ = try ok(a, "cs_6_6", &.{}, src);
    // Used, with only a heap of its type: the heap's first element.
    const used =
        \\struct In { Buffer<uint> Unused; uint Off; };
        \\typedef Buffer<uint> SafeT; SafeT Heap[]; RWBuffer<uint> O;
        \\uint use(In i) { return i.Unused[i.Off]; }
        \\[numthreads(1,1,1)] void main() { In x; x.Off = 1; O[0] = use(x) + Heap[2][0]; }
    ;
    _ = try ok(a, "cs_6_6", &.{}, used);
}

test "counters of a buffer reached through a static const bindless handle" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\typedef RWStructuredBuffer<uint> SafeT; SafeT Heap[]; cbuffer C { uint idx; };
        \\static const SafeT B = Heap[idx];
        \\[numthreads(64,1,1)] void main(uint3 id : SV_DispatchThreadID) { uint k = B.IncrementCounter(); B[k] = id.x; }
    ;
    const m = try ok(a, "cs_6_6", &.{ "-fvk-allow-rwstructuredbuffer-arrays", "-fspv-target-env=vulkan1.3" }, src);
    try expectEqual(@as(usize, 1), countOp(m, 234)); // OpAtomicIAdd
}

test "the same bindless resource assigned to a variable twice" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // (Each use of a `static const` handle evaluates the heap access anew.)
    const src =
        \\typedef Texture2D<float4> SafeT; SafeT Heap[]; cbuffer C { uint idx; uint n; };
        \\static const SafeT T = Heap[idx];
        \\RWStructuredBuffer<float4> O;
        \\[numthreads(1,1,1)] void main() { Texture2D<float4> t = T; float4 s = 0; for (uint i = 0; i < n; i++) { t = T; s += t.Load(int3(i, 0, 0)); } O[0] = s; }
    ;
    _ = try ok(a, "cs_6_6", &.{}, src);
}

test "constant buffers nothing reads are left out ($Globals included)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // (Unreal's Vulkan format accepts no $Globals beside its root parameter
    // buffer; dxc's optimizer drops an unread one.)
    const src =
        \\cbuffer Unused { float4 u; }; float4 g_unused; cbuffer Used { float4 v; }; RWStructuredBuffer<float4> O;
        \\[numthreads(1,1,1)] void main() { O[0] = v; }
    ;
    const m = try ok(a, "cs_6_6", &.{}, src);
    try std.testing.expect(m.named("Used") != null);
    try std.testing.expect(m.named("Unused") == null);
    try std.testing.expect(m.named("$Globals") == null);
}

test "branches on constant arguments fold away, with what they read" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // (Lumen: AccumulateResults(..., bRayTraceSkyLightContribution = false).)
    const src =
        \\RWStructuredBuffer<float4> O; Texture2D<float4> Sky; int SkyMips; float4 tint;
        \\float4 shade(bool sky, float4 c) {
        \\    float4 r = c * tint;
        \\    if (sky) r += Sky.Load(int3(0, 0, SkyMips - 1));
        \\    return r;
        \\}
        \\[numthreads(1,1,1)] void main(uint3 id : SV_DispatchThreadID) { O[id.x] = shade(false, O[id.x]) + shade(id.x > 3, 1); }
    ;
    const m = try ok(a, "cs_6_6", &.{}, src);
    // (Both calls read tint; only the second can read the sky, so $Globals
    // stays, but the folded call has one block less.)
    try std.testing.expect(m.named("$Globals") != null);
    const only_false = try ok(a, "cs_6_6", &.{}, std.mem.replaceOwned(u8, a, src, "shade(id.x > 3, 1)", "1") catch unreachable);
    // Nothing reads Sky or SkyMips any more: no image fetch.
    try expectEqual(@as(usize, 0), countOp(only_false, 95)); // OpImageFetch
}

test "a bindless handle passed along and never read leaves no binding" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // (Unreal's FarFieldTLAS: its heap and its $Globals index are gone from
    // dxc's SPIR-V, and Unreal's Vulkan format rejects $Globals beside a
    // root parameter buffer.)
    const src =
        \\uint BindlessSRV_Far; typedef Texture2D<float4> SafeT; SafeT SRVHeap_Far[];
        \\static const SafeT Far = SRVHeap_Far[NonUniformResourceIndex(BindlessSRV_Far)];
        \\Texture2D<float4> Near; RWStructuredBuffer<float4> O;
        \\float4 light(Texture2D<float4> near, Texture2D<float4> far, uint i) { return near.Load(int3(i, 0, 0)); }
        \\[numthreads(1,1,1)] void main(uint3 id : SV_DispatchThreadID) { O[id.x] = light(Near, Far, id.x); }
    ;
    const m = try ok(a, "cs_6_6", &.{"-fspv-target-env=vulkan1.3"}, src);
    try std.testing.expect(m.named("SRVHeap_Far") == null);
    try std.testing.expect(m.named("$Globals") == null);
    try std.testing.expect(m.named("Near") != null);
}

test "a loop whose results nothing uses goes, with what it reads" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // (Lumen: a light loop over ForwardLightStruct whose sum is unused.)
    const src =
        \\cbuffer Lights { uint NumLights; float4 LightColor[16]; };
        \\RWStructuredBuffer<float4> O; float4 base;
        \\float4 lights() { float4 s = 0; for (uint i = 0; i < NumLights; i++) s += LightColor[i & 15]; return s; }
        \\[numthreads(1,1,1)] void main(uint3 id : SV_DispatchThreadID) { float4 unused = lights(); O[id.x] = base; }
    ;
    const m = try ok(a, "cs_6_6", &.{}, src);
    try expectEqual(@as(usize, 0), countOp(m, 246)); // OpLoopMerge
    try std.testing.expect(m.named("Lights") == null);
    // Used: it stays.
    const used = try ok(a, "cs_6_6", &.{}, std.mem.replaceOwned(u8, a, src, "O[id.x] = base;", "O[id.x] = base + unused;") catch unreachable);
    try expectEqual(@as(usize, 1), countOp(used, 246));
    // A loop that writes stays even if it computes nothing used.
    const writes = try ok(a, "cs_6_6", &.{}, "RWStructuredBuffer<uint> O; cbuffer C { uint n; }; [numthreads(1,1,1)] void main() { for (uint i = 0; i < n; i++) O[i] = i; }");
    try expectEqual(@as(usize, 1), countOp(writes, 246));
}

test "buffer struct members nothing reads go" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // (Unreal's shader record: VulkanShaderRecordLooseParameterData is
    // gone from dxc's SPIR-V when DiffuseColorBoost is unused, and Unreal
    // reflects the members left as the loose parameters a shader uses.)
    const src =
        \\struct Root { uint Config; uint Offset; uint First; uint User; };
        \\struct Loose { float Boost; };
        \\struct Params { Root R; uint Index; uint Vertex; uint UBs[32]; Loose Globals; };
        \\[[vk::shader_record_ext]] ConstantBuffer<Params> P;
        \\cbuffer C { float4 unused0; float4 used; float4 unused1; };
        \\RWStructuredBuffer<float4> O;
        \\[numthreads(1,1,1)] void main(uint3 id : SV_DispatchThreadID) { O[id.x] = used + float(P.R.First + P.Vertex); }
    ;
    const m = try ok(a, "cs_6_6", &.{}, src);
    try std.testing.expect(m.memberNamed("Boost") == null);
    try std.testing.expect(m.named("Loose") == null);
    try std.testing.expect(m.memberNamed("UBs") == null);
    try std.testing.expect(m.memberNamed("User") == null);
    try std.testing.expect(m.memberNamed("unused0") == null);
    try std.testing.expect(m.memberNamed("unused1") == null);
    // What is used stays at its offset, renumbered.
    try expectEqual(@as(?u32, 0), m.memberNamed("used"));
    try expectEqual(@as(?u32, 1), m.memberNamed("Vertex"));
    try expectEqual(@as(?u32, 0), m.memberNamed("First"));
    const c = m.named("type.C").?;
    try expectEqual(@as(?u32, 16), m.memberDeco(c, 0, offset));
    // Used, Boost stays.
    const used = try ok(a, "cs_6_6", &.{}, std.mem.replaceOwned(u8, a, src, "P.Vertex)", "P.Vertex) + P.Globals.Boost") catch unreachable);
    try std.testing.expect(used.memberNamed("Boost") != null);
    try std.testing.expect(used.named("Loose") != null);
}

test "struct locals indexed by an unrolled loop's counter are split" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // (Unreal's TSR: its register structs, indexed by lane in [unroll]
    // loops; the index is a constant only once the counter is promoted.
    // Left whole, they are tens of thousands of locals Unreal's spirv-opt
    // then spends tens of seconds on.)
    const src =
        \\template<typename T, uint N, uint C>
        \\struct Regs { vector<T, N> Array[C];
        \\  vector<T, N> GetElement(const uint i) { return Array[i]; }
        \\  void SetElement(const uint i, vector<T, N> v) { Array[i] = v; } };
        \\template<typename T, uint N, uint X, uint Y>
        \\struct Lane { static const uint SimdSize = X * Y; Regs<T, N, X * Y> Registers;
        \\  vector<T, N> GetElement(const uint i) { return Registers.GetElement(i); }
        \\  void SetElement(const uint i, vector<T, N> v) { Registers.SetElement(i, v); } };
        \\template<typename T, uint N, uint X, uint Y>
        \\Lane<T, N, X, Y> Add(Lane<T, N, X, Y> a, Lane<T, N, X, Y> b) {
        \\  Lane<T, N, X, Y> r;
        \\  [unroll] for (uint i = 0; i < Lane<T, N, X, Y>::SimdSize; i++) r.SetElement(i, a.GetElement(i) + b.GetElement(i));
        \\  return r; }
        \\RWStructuredBuffer<float3> O; StructuredBuffer<float3> I;
        \\[numthreads(64,1,1)] void main(uint3 id : SV_DispatchThreadID) {
        \\  Lane<float, 3, 1, 2> a, b;
        \\  [unroll] for (uint i = 0; i < 2; i++) { a.SetElement(i, I[id.x * 2 + i]); b.SetElement(i, I[id.x * 2 + i + 1]); }
        \\  Lane<float, 3, 1, 2> c = Add(a, b); c = Add(c, a);
        \\  O[id.x] = c.GetElement(0) + c.GetElement(1);
        \\}
    ;
    const m = try ok(a, "cs_6_6", &.{"-HV", "2021"}, src);
    try expectEqual(@as(usize, 0), functionVars(m));
}

test "branches on members of a returned struct of constants fold" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // (Unreal's FWaveBroadcastSettings: InitWaveRotateLaneGroup returns
    // Operation = 4, and the broadcast branches on it.)
    const src =
        \\struct Settings { uint Op; uint Mask; uint Xor; };
        \\Settings InitSettings(uint op, uint mask) { Settings s; s.Op = op; s.Mask = mask; s.Xor = 0; return s; }
        \\uint Lane(const Settings s, uint id) {
        \\  if (s.Op == 1) return id ^ s.Mask;
        \\  else if (s.Op == 2) return id & s.Mask;
        \\  else if (s.Op == 4) return id + s.Xor;
        \\  return id;
        \\}
        \\RWStructuredBuffer<uint> O;
        \\[numthreads(64,1,1)] void main(uint3 id : SV_DispatchThreadID) {
        \\  const Settings s = InitSettings(4, 3);
        \\  O[id.x] = WaveReadLaneAt(id.x, Lane(s, WaveGetLaneIndex()));
        \\}
    ;
    const m = try ok(a, "cs_6_6", &.{"-fspv-target-env=vulkan1.3"}, src);
    try expectEqual(@as(usize, 0), countOp(m, 247)); // OpSelectionMerge
    try expectEqual(@as(usize, 0), countOp(m, 170)); // OpIEqual
}
