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

    /// Whether member `member` of `id` is decorated with `d`.
    fn memberDecorated(m: Module, id: u32, member: u32, d: u32) bool {
        var it = m.ops();
        while (it.next()) |i| if (i.op == 72 and i.args[0] == id and i.args[1] == member and i.args[2] == d) return true; // OpMemberDecorate
        return false;
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
    // Without it, only the arithmetic computing the precise field (as any
    // dxc: precise.zig).
    try expectEqual(@as(usize, 2), (try ok(a, "vs_6_6", &.{}, vs_src)).decoCount(no_contraction));
    const m = try ok(a, "vs_6_6", &.{"-fspv-support-precise-outputs"}, vs_src);
    try expectEqual(@as(usize, 3), m.decoCount(no_contraction));
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
        \\[numthreads(1,1,1)] void main() { O[0] = x * y + z; O[1] = w + x * y; O[2] = x * y - z; O[3] = x * y + z * w; }
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

/// The number of OpAccessChains based on the variable named `name`.
fn chainsInto(m: Module, name: []const u8) usize {
    const v = m.named(name) orelse return 0;
    var n: usize = 0;
    var it = m.ops();
    while (it.next()) |i| {
        if (i.op == 65 and i.args[2] == v) n += 1; // OpAccessChain
    }
    return n;
}

test "an unused static struct goes, with its types and constants" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // (Unreal's ResolvedView, a Private struct a pixel shader never reads:
    // a literal equal to its id kept it, and constants never went.)
    const src =
        \\struct View { float4x4 M; float4 V[16]; uint Flags; float Scale; };
        \\static View RV;
        \\void Resolve() { RV.Flags = 7; RV.Scale = 0.5; for (int i = 0; i < 16; i++) RV.V[i] = float4(i, i + 1, i + 2, i + 3); }
        \\RWStructuredBuffer<float> O;
        \\[numthreads(1,1,1)] void main() { Resolve(); O[0] = 1; }
    ;
    const m = try ok(a, "cs_6_6", &.{}, src);
    try expectEqual(@as(usize, 1), countOp(m, 59)); // OpVariable: O only
    try std.testing.expect(countOp(m, 43) <= 3); // OpConstant: O's index, 1.0 and the like
}

test "an array returned in a struct and copied whole comes apart once" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\struct R { float v[4]; };
        \\cbuffer C { float4 x; };
        \\R make() { R r; r.v[0] = x.x; r.v[1] = x.y; r.v[2] = x.z; r.v[3] = x.w; return r; }
        \\RWStructuredBuffer<float> O;
        \\[numthreads(1,1,1)] void main() { R r = make(); float t[4] = r.v; O[0] = t[0] + t[3]; }
    ;
    const m = try ok(a, "cs_6_6", &.{}, src);
    try expectEqual(@as(usize, 0), countOp(m, 80)); // OpCompositeConstruct
    try expectEqual(@as(usize, 0), functionVars(m));
}

test "loops that run once are no loops" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A back edge that folds (spirv-val rejects a loop header left without
    // one), and an inlined callee with a return inside a selection.
    const src =
        \\RWStructuredBuffer<float> O; cbuffer C { float k; };
        \\float f(float x) { if (x > 1) { x = x * 2; } return x + 1; }
        \\[numthreads(1,1,1)] void main() { do { O[0] = f(k); } while (false); }
    ;
    const m = try ok(a, "cs_6_6", &.{}, src);
    try expectEqual(@as(usize, 0), countOp(m, 246)); // OpLoopMerge
}

test "a constant buffer member read in a block and one it dominates is one read" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\RWStructuredBuffer<float> O; cbuffer C { float k; float j; };
        \\float twice() { return k * 2; }
        \\[numthreads(1,1,1)] void main() { float a = k * 2; if (O[0] > 0) O[1] = twice(); O[2] = a + k; }
    ;
    const m = try ok(a, "cs_6_6", &.{}, src);
    try expectEqual(@as(usize, 1), chainsInto(m, "C"));
    try expectEqual(@as(usize, 1), countOp(m, 133)); // OpFMul: k * 2 once
}

test "a local's array of one element, indexed by a variable, still splits" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // (Unreal's FSSDKernelConfig: BufferColorSpace[MultiplexId], a batch
    // of one signal.)
    const src =
        \\struct Config { uint Sets[1]; uint Mode; };
        \\RWStructuredBuffer<uint> O; cbuffer C { uint k; };
        \\[numthreads(1,1,1)] void main() {
        \\  Config c; c.Mode = 2; c.Sets[k] = 5;
        \\  if (c.Mode == 2) O[0] = c.Sets[0]; else O[1] = 3;
        \\}
    ;
    const m = try ok(a, "cs_6_6", &.{}, src);
    try expectEqual(@as(usize, 0), functionVars(m));
    try expectEqual(@as(usize, 0), countOp(m, 247)); // OpSelectionMerge: the branch folded
}

test "a struct with a dynamically indexed array member keeps only the array a local" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // (Unreal's FPrimitiveSceneData and its CustomPrimitiveData[i].)
    const src =
        \\struct Prim { float4 Custom[9]; uint Flags; float Scale; float3 Pos; };
        \\RWStructuredBuffer<float4> O; cbuffer C { uint k; uint j; float4 v; };
        \\Prim load() { Prim p; p.Flags = 1; p.Scale = 2; p.Pos = v.xyz; for (int i = 0; i < 9; i++) p.Custom[i] = v * i; p.Custom[k] = 0; return p; }
        \\[numthreads(1,1,1)] void main() {
        \\  Prim p = load();
        \\  if (p.Flags == 1) O[0] = p.Custom[j] * p.Scale + p.Pos.x; else O[1] = 0;
        \\}
    ;
    const m = try ok(a, "cs_6_6", &.{}, src);
    // Custom, twice: the callee's and the caller's copy of it (copies of
    // whole locals are not forwarded yet).
    try expectEqual(@as(usize, 2), functionVars(m));
    try expectEqual(@as(usize, 0), countOp(m, 247)); // OpSelectionMerge: Flags is 1
}

test "a struct holding resources splits around them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // (Unreal's FShaderPrintContext: its bIsActive left in a local kept all
    // of a shader's debug printing.)
    const src =
        \\struct Buffers { Buffer<uint> State; RWBuffer<uint> Entries; };
        \\struct Ctx { bool Active; float2 Pos; Buffers B; };
        \\Buffer<uint> S; RWBuffer<uint> E; RWStructuredBuffer<float> O;
        \\Ctx init(bool on) { Ctx c; c.Active = on; c.Pos = 0; c.B.State = S; c.B.Entries = E; return c; }
        \\void print(inout Ctx c, float x) { if (c.Active) { uint i; InterlockedAdd(c.B.Entries[0], 1, i); c.B.Entries[i + 1] = asuint(x) + c.B.State[0]; c.Pos.x += 1; } }
        \\[numthreads(1,1,1)] void main() { Ctx c = init(false); print(c, 1); print(c, 2); O[0] = c.Pos.y; }
    ;
    const m = try ok(a, "cs_6_6", &.{}, src);
    try expectEqual(@as(usize, 0), functionVars(m));
    try expectEqual(@as(usize, 0), countOp(m, 247)); // OpSelectionMerge: printing is off
}

test "matrix and vector locals written by row and component are promoted" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\RWStructuredBuffer<float3> O; cbuffer C { float3 x, y, z; };
        \\[numthreads(1,1,1)] void main() {
        \\  float3x3 m; m[0] = x; m[1] = y; m[2] = z; m[1][2] = 4;
        \\  float3 v; v.x = x.y; v.y = 1; v.z = m[2][0];
        \\  O[0] = mul(m, v);
        \\}
    ;
    const m = try ok(a, "cs_6_6", &.{}, src);
    try expectEqual(@as(usize, 0), functionVars(m));
}

test "out arguments of atomics and sincos are values, not locals" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\groupshared uint G; RWStructuredBuffer<float> O; RWStructuredBuffer<uint> U; cbuffer C { float x; };
        \\[numthreads(64,1,1)] void main(uint3 id : SV_DispatchThreadID) {
        \\  uint old; InterlockedAdd(G, 1, old);
        \\  uint prev; InterlockedCompareExchange(U[0], 0, id.x, prev);
        \\  float s, c; sincos(x, s, c);
        \\  O[old] = s + c + prev;
        \\}
    ;
    const m = try ok(a, "cs_6_6", &.{}, src);
    try expectEqual(@as(usize, 0), functionVars(m));
    try expectEqual(@as(usize, 1), countOp(m, 234)); // OpAtomicIAdd
    try expectEqual(@as(usize, 1), countOp(m, 230)); // OpAtomicCompareExchange
}

/// The Aligned literals of loads (OpLoad) or stores (OpStore) through
/// PhysicalStorageBuffer pointers, in order.
fn physicalAlignments(a: std.mem.Allocator, m: Module, op: u16) ![]const u32 {
    var psb_ptrs: std.AutoHashMapUnmanaged(u32, void) = .empty; // pointer types
    var ptrs: std.AutoHashMapUnmanaged(u32, void) = .empty; // values of them
    var out: std.ArrayList(u32) = .empty;
    var it = m.ops();
    while (it.next()) |i| switch (i.op) {
        32 => if (i.args[1] == 5349) try psb_ptrs.put(a, i.args[0], {}), // OpTypePointer PhysicalStorageBuffer
        124 => if (psb_ptrs.contains(i.args[0])) try ptrs.put(a, i.args[1], {}), // OpBitcast
        61, 62 => if (i.op == op) {
            const p = if (op == 61) i.args[2] else i.args[0];
            const mem = if (op == 61) i.args[3..] else i.args[2..];
            if (ptrs.contains(p) and mem.len == 2 and mem[0] == 2) try out.append(a, mem[1]); // Aligned
        },
        else => {},
    };
    return out.items;
}

test "vk::RawBufferLoad / RawBufferStore: PhysicalStorageBuffer pointers from addresses" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\struct T { float a; float3 b; bool c; };
        \\struct PC { uint64_t addr; };
        \\[[vk::push_constant]] PC pc;
        \\[numthreads(1,1,1)] void main() {
        \\  float4 v = vk::RawBufferLoad<float4>(pc.addr, 16);
        \\  T t = vk::RawBufferLoad<T>(pc.addr + 16);
        \\  uint x = vk::RawBufferLoad(pc.addr + 64);
        \\  vk::RawBufferStore(pc.addr + 64, x + 1);
        \\  uint y = vk::RawBufferLoad(pc.addr + 64);
        \\  t.c = !t.c;
        \\  vk::RawBufferStore<T>(pc.addr + 80, t, 8);
        \\  vk::RawBufferStore<float4>(pc.addr + 112, v * (x + y), 16);
        \\}
    ;
    const m = try ok(a, "cs_6_0", &.{}, src);
    var it = m.ops();
    var caps: usize = 0;
    var addressing: ?u32 = null;
    while (it.next()) |i| switch (i.op) {
        17 => if (i.args[0] == 5347) {
            caps += 1; // OpCapability PhysicalStorageBufferAddresses
        },
        14 => addressing = i.args[0], // OpMemoryModel
        else => {},
    };
    try expectEqual(@as(usize, 1), caps);
    try expectEqual(@as(?u32, 5348), addressing); // PhysicalStorageBuffer64
    // Both loads of pc.addr + 64 stay: the store between them changes it.
    try std.testing.expectEqualSlices(u32, &.{ 16, 4, 4, 4 }, try physicalAlignments(a, m, 61));
    try std.testing.expectEqualSlices(u32, &.{ 4, 8, 16 }, try physicalAlignments(a, m, 62));
    // Storage buffer layout (relaxed std430 by default), the bool a uint.
    const t = m.named("T").?;
    try expectEqual(@as(?u32, 4), m.memberDeco(t, 1, offset));
    try expectEqual(@as(?u32, 16), m.memberDeco(t, 2, offset));
    // Strict std430 with -fvk-use-gl-layout (as dxc).
    const gl = try ok(a, "cs_6_0", &.{"-fvk-use-gl-layout"}, src);
    try expectEqual(@as(?u32, 16), gl.memberDeco(gl.named("T").?, 1, offset));
    try expectEqual(@as(?u32, 28), gl.memberDeco(gl.named("T").?, 2, offset));
}

test "vk::RawBufferLoad: the pointee follows the storage buffer layout options" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\struct I { float3 v; };
        \\struct A { float3 a[2]; float c; };
        \\struct M { float3x3 m; float c; };
        \\struct N { I i[2]; float c; };
        \\struct PC { uint64_t addr; };
        \\[[vk::push_constant]] PC pc;
        \\RWStructuredBuffer<float> o;
        \\[numthreads(1,1,1)] void main() {
        \\  A x = vk::RawBufferLoad<A>(pc.addr);
        \\  M y = vk::RawBufferLoad<M>(pc.addr + 64);
        \\  N z = vk::RawBufferLoad<N>(pc.addr + 128);
        \\  o[0] = x.c + y.c + z.c;
        \\}
    ;
    const matrix_stride = 7;
    // Offsets of each struct's `c` and its strides, as dxc: 16-byte
    // strides by default (valid without scalarBlockLayout), tight ones
    // with -fvk-use-scalar-layout.
    const Case = struct { opt: []const []const u8, stride: u32, c_a: u32, c_m: u32, c_n: u32 };
    for ([_]Case{
        .{ .opt = &.{}, .stride = 16, .c_a = 32, .c_m = 48, .c_n = 32 },
        .{ .opt = &.{"-fvk-use-gl-layout"}, .stride = 16, .c_a = 32, .c_m = 48, .c_n = 32 },
        .{ .opt = &.{"-fvk-use-scalar-layout"}, .stride = 12, .c_a = 24, .c_m = 36, .c_n = 24 },
    }) |c| {
        const m = try ok(a, "cs_6_0", c.opt, src);
        const sa = m.named("A").?;
        const sm = m.named("M").?;
        const sn = m.named("N").?;
        try expectEqual(@as(?u32, c.stride), m.memberStride(sa, 0));
        try expectEqual(@as(?u32, c.c_a), m.memberDeco(sa, 1, offset));
        try expectEqual(@as(?u32, c.stride), m.memberDeco(sm, 0, matrix_stride));
        try expectEqual(@as(?u32, c.c_m), m.memberDeco(sm, 1, offset));
        try expectEqual(@as(?u32, c.stride), m.memberStride(sn, 0));
        try expectEqual(@as(?u32, c.c_n), m.memberDeco(sn, 1, offset));
    }
}

test "vk::RawBufferLoad / RawBufferStore: alignments are constant powers of two, reported where written" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pre = "struct PC { uint64_t addr; uint al; }; [[vk::push_constant]] PC pc; static const uint A = 16;\n";
    const dynamic = try spirv(a, "cs_6_0", &.{}, pre ++ "[numthreads(1,1,1)] void main() { vk::RawBufferStore(pc.addr, vk::RawBufferLoad(pc.addr, pc.al)); }");
    try std.testing.expect(dynamic.m == null);
    try std.testing.expect(std.mem.startsWith(u8, dynamic.diagnostics, "hlsl.hlsl:2:90: error: alignment argument must be a constant unsigned integer"));
    for ([_][]const u8{ "3", "0" }) |al| {
        const r = try spirv(a, "cs_6_0", &.{}, try std.fmt.allocPrint(a, "{s}[numthreads(1,1,1)] void main() {{ vk::RawBufferStore(pc.addr, 1u, {s}); }}", .{ pre, al }));
        try std.testing.expect(r.m == null);
        try std.testing.expect(std.mem.startsWith(u8, r.diagnostics, "hlsl.hlsl:2:67: error: alignment argument must be a power of two"));
    }
    const big = try spirv(a, "cs_6_0", &.{}, pre ++ "[numthreads(1,1,1)] void main() { vk::RawBufferStore(pc.addr, 1u, 0x200000000); }");
    try std.testing.expect(big.m == null);
    try std.testing.expect(std.mem.startsWith(u8, big.diagnostics, "hlsl.hlsl:2:67: error: alignment argument must fit in 32 bits"));
    // Floats and bools are not integers, even when they convert to one.
    // Nor are negative ones unsigned (as dxc).
    for ([_][]const u8{ "16.5", "16.0", "true", "-4" }) |al| {
        const r = try spirv(a, "cs_6_0", &.{}, try std.fmt.allocPrint(a, "{s}[numthreads(1,1,1)] void main() {{ vk::RawBufferStore(pc.addr, 1u, {s}); }}", .{ pre, al }));
        try std.testing.expect(r.m == null);
        try std.testing.expect(std.mem.startsWith(u8, r.diagnostics, "hlsl.hlsl:2:67: error: alignment argument must be a constant unsigned integer"));
    }
    // Constant expressions, not only literals.
    _ = try ok(a, "cs_6_0", &.{}, pre ++ "[numthreads(1,1,1)] void main() { vk::RawBufferStore(pc.addr, vk::RawBufferLoad(pc.addr, A), A / 2 * sizeof(uint)); }");
    // At least the largest scalar accessed (VUID-...-06314).
    const small = try spirv(a, "cs_6_0", &.{}, pre ++ "struct S { float a; double b; };\n[numthreads(1,1,1)] void main() { S s = vk::RawBufferLoad<S>(pc.addr, 4); }");
    try std.testing.expect(small.m == null);
    try std.testing.expect(std.mem.startsWith(u8, small.diagnostics, "hlsl.hlsl:3:71: error: alignment argument must be at least 8, the size of the largest scalar accessed"));
    // Only plain data.
    const res = try spirv(a, "cs_6_0", &.{}, pre ++ "[numthreads(1,1,1)] void main() { Texture2D t = vk::RawBufferLoad<Texture2D>(pc.addr); }");
    try std.testing.expect(res.m == null);
    try std.testing.expect(std.mem.indexOf(u8, res.diagnostics, "error: cannot access a value of type 'Texture2D") != null);
    // Nor data holding one, reported at the call.
    const held = try spirv(a, "cs_6_0", &.{}, pre ++ "struct R { float a; Texture2D t[2]; };\n[numthreads(1,1,1)] void main() { R r = vk::RawBufferLoad<R>(pc.addr); }");
    try std.testing.expect(held.m == null);
    try std.testing.expect(std.mem.startsWith(u8, held.diagnostics, "hlsl.hlsl:3:41: error: cannot access a value of type 'R' at an address"));
}

test "vk::RawBufferLoad / RawBufferStore: default alignment covers 64-bit scalars" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // dxc's default of 4 everywhere is invalid for 8-byte scalars.
    const m = try ok(a, "cs_6_0", &.{},
        \\struct S { float a; double b; };
        \\struct PC { uint64_t addr; };
        \\[[vk::push_constant]] PC pc;
        \\[numthreads(1,1,1)] void main() {
        \\  vk::RawBufferStore<uint64_t>(pc.addr, 7);
        \\  S s = vk::RawBufferLoad<S>(pc.addr + 8);
        \\  vk::RawBufferStore<double>(pc.addr + 24, s.b);
        \\  vk::RawBufferStore<uint>(pc.addr + 32, 1u);
        \\}
    );
    try std.testing.expectEqualSlices(u32, &.{8}, try physicalAlignments(a, m, 61));
    try std.testing.expectEqualSlices(u32, &.{ 8, 8, 4 }, try physicalAlignments(a, m, 62));
}

test "vk::RawBufferLoad / RawBufferStore: default alignment of 16-bit types is their own" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Claiming 4 (dxc 1.10) for 2-byte data at addr + 2 would be false.
    const m = try ok(a, "cs_6_2", &.{"-enable-16bit-types"},
        \\struct H { half a; int16_t b; };
        \\struct PC { uint64_t addr; };
        \\[[vk::push_constant]] PC pc;
        \\[numthreads(1,1,1)] void main() {
        \\  int16_t x = vk::RawBufferLoad<int16_t>(pc.addr + 2);
        \\  H h = vk::RawBufferLoad<H>(pc.addr + 6);
        \\  vk::RawBufferStore<half>(pc.addr + 10, h.a + x);
        \\  vk::RawBufferStore<uint16_t>(pc.addr + 12, h.b);
        \\}
    );
    try std.testing.expectEqualSlices(u32, &.{ 2, 2 }, try physicalAlignments(a, m, 61));
    try std.testing.expectEqualSlices(u32, &.{ 2, 2 }, try physicalAlignments(a, m, 62));
}

test "vk::RawBufferLoad / RawBufferStore: matrices outside structs are wrapped to be laid out" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A matrix pointee has no MatrixStride or majorness (they decorate
    // members only): it goes in a struct of its own, oriented as written,
    // by #pragma pack_matrix, or by -Zpr.
    const src =
        \\struct PC { uint64_t addr; };
        \\[[vk::push_constant]] PC pc;
        \\RWStructuredBuffer<float4> o;
        \\typedef float3x3 A[2];
        \\[numthreads(1,1,1)] void main() {
        \\  float4x4 m = vk::RawBufferLoad<float4x4>(pc.addr);
        \\  row_major float2x3 r = vk::RawBufferLoad<row_major float2x3>(pc.addr + 64);
        \\  A x = vk::RawBufferLoad<A>(pc.addr + 128);
        \\  vk::RawBufferStore<float4x4>(pc.addr + 256, m);
        \\  vk::RawBufferStore(pc.addr + 320, x);
        \\  o[0] = m[1] + r[1].xyzz + x[1][2].xyzz;
        \\}
    ;
    const matrix_stride = 7;
    const row_major = 4; // (SPIR-V's: HLSL column_major)
    const col_major = 5;
    for ([_]struct { opt: []const []const u8, rm: bool }{ .{ .opt = &.{}, .rm = false }, .{ .opt = &.{"-Zpr"}, .rm = true } }) |c| {
        const m = try ok(a, "cs_6_0", c.opt, src);
        const w4 = m.named("type.RawBuffer.mat4v4float").?;
        try expectEqual(@as(?u32, 0), m.memberDeco(w4, 0, offset));
        try expectEqual(@as(?u32, 16), m.memberDeco(w4, 0, matrix_stride));
        try std.testing.expect(m.memberDecorated(w4, 0, if (c.rm) col_major else row_major));
        // Written row_major, whatever -Zpr says; 3-vectors 16 apart.
        const w23 = m.named("type.RawBuffer.mat2v3float").?;
        try expectEqual(@as(?u32, 16), m.memberDeco(w23, 0, matrix_stride));
        try std.testing.expect(m.memberDecorated(w23, 0, col_major));
        // Arrays of them too (the store infers the type).
        const wa = m.named("type.RawBuffer.mat3v3float[2]").?;
        try expectEqual(@as(?u32, 16), m.memberDeco(wa, 0, matrix_stride));
        try std.testing.expect(m.memberDecorated(wa, 0, if (c.rm) col_major else row_major));
        try std.testing.expectEqualSlices(u32, &.{ 4, 4, 4 }, try physicalAlignments(a, m, 61));
        try std.testing.expectEqualSlices(u32, &.{ 4, 4 }, try physicalAlignments(a, m, 62));
    }
    const pragma = try ok(a, "cs_6_0", &.{}, "#pragma pack_matrix(row_major)\n" ++ src);
    try std.testing.expect(pragma.memberDecorated(pragma.named("type.RawBuffer.mat4v4float").?, 0, col_major));
    // A store inferring the type lays the value out as it is declared, so
    // what a load reads, a store of it writes back unchanged (one wrapper).
    for ([_][]const u8{
        "#pragma pack_matrix(row_major)\n" ++
            \\struct PC { uint64_t addr; };
            \\[[vk::push_constant]] PC pc;
            \\[numthreads(1,1,1)] void main() {
            \\  float4x4 m = vk::RawBufferLoad<float4x4>(pc.addr);
            \\  vk::RawBufferStore(pc.addr + 64, m);
            \\}
        ,
        \\struct PC { uint64_t addr; };
        \\[[vk::push_constant]] PC pc;
        \\[numthreads(1,1,1)] void main() {
        \\  row_major float4x4 m = vk::RawBufferLoad<row_major float4x4>(pc.addr);
        \\  vk::RawBufferStore(pc.addr + 64, m);
        \\}
        ,
        \\struct S { row_major float4x4 m; };
        \\struct PC { uint64_t addr; };
        \\[[vk::push_constant]] PC pc;
        \\StructuredBuffer<S> sb;
        \\[numthreads(1,1,1)] void main() {
        \\  S s = vk::RawBufferLoad<S>(pc.addr);
        \\  vk::RawBufferStore(pc.addr + 64, s.m);
        \\  vk::RawBufferStore(pc.addr + 128, sb[0].m);
        \\  vk::RawBufferStore(pc.addr + 192, vk::RawBufferLoad<row_major float4x4>(pc.addr));
        \\}
        ,
        \\struct PC { uint64_t addr; };
        \\[[vk::push_constant]] PC pc;
        \\row_major float4x4 f() { return vk::RawBufferLoad<row_major float4x4>(pc.addr); }
        \\[numthreads(1,1,1)] void main() {
        \\  row_major float4x4 ms[2];
        \\  ms[0] = f(); ms[1] = f();
        \\  vk::RawBufferStore(pc.addr + 64, ms[1]);
        \\  vk::RawBufferStore(pc.addr + 128, f());
        \\}
        ,
        \\struct PC { uint64_t addr; };
        \\[[vk::push_constant]] PC pc;
        \\void put(row_major float4x4 p) { vk::RawBufferStore(pc.addr + 64, p); }
        \\[numthreads(1,1,1)] void main() { put(vk::RawBufferLoad<row_major float4x4>(pc.addr)); }
        ,
        // (A typedef's orientation is lost only in entry signatures: a
        // helper's parameters and return value keep it.)
        \\typedef row_major float4x4 RM;
        \\struct PC { uint64_t addr; };
        \\[[vk::push_constant]] PC pc;
        \\RM get() { return vk::RawBufferLoad<RM>(pc.addr); }
        \\void put(RM p) { vk::RawBufferStore(pc.addr + 64, p); }
        \\[numthreads(1,1,1)] void main() { put(get()); vk::RawBufferStore(pc.addr + 128, get()); }
        ,
        // (The orientation is the type's: a conditional of two row_major
        // values, or an assignment's value, is row_major too.)
        \\struct PC { uint64_t addr; bool c; };
        \\[[vk::push_constant]] PC pc;
        \\[numthreads(1,1,1)] void main() {
        \\  row_major float4x4 a = vk::RawBufferLoad<row_major float4x4>(pc.addr);
        \\  row_major float4x4 b = a, d;
        \\  vk::RawBufferStore(pc.addr + 64, pc.c ? a : b);
        \\  vk::RawBufferStore(pc.addr + 128, (d = a));
        \\}
        ,
    }) |s| {
        const r = try ok(a, "cs_6_0", &.{}, s);
        try std.testing.expect(r.memberDecorated(r.named("type.RawBuffer.mat4v4float").?, 0, col_major));
        var n: usize = 0;
        var i = r.ops();
        while (i.next()) |o| if (o.op == 5 and std.mem.startsWith(u8, std.mem.sliceAsBytes(o.args[1..]), "type.RawBuffer")) {
            n += 1; // OpName of a wrapper
        };
        try expectEqual(@as(usize, 1), n);
    }
    // Vectors, integer matrices (arrays of rows) and structs stay as they are.
    const plain = try ok(a, "cs_6_0", &.{},
        \\struct PC { uint64_t addr; };
        \\[[vk::push_constant]] PC pc;
        \\RWStructuredBuffer<float4> o;
        \\[numthreads(1,1,1)] void main() {
        \\  row_major int2x2 i = vk::RawBufferLoad<row_major int2x2>(pc.addr);
        \\  o[0] = vk::RawBufferLoad<float4>(pc.addr + 16) + i[1].xyxy + vk::RawBufferLoad<float1x4>(pc.addr + 32);
        \\}
    );
    var it = plain.ops();
    while (it.next()) |i| if (i.op == 5) try std.testing.expect(!std.mem.startsWith(u8, std.mem.sliceAsBytes(i.args[1..]), "type.RawBuffer")); // OpName
}

test "structured buffers of matrices are read, written and measured as their elements are laid out" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // row_major float3x2 in std430: 3 rows of float2, 24 bytes (column
    // major it would be 2 float3 columns, 32): GetDimensions' stride is
    // the buffer's ArrayStride. Whole row_major integer matrices load and
    // store as the buffer holds them (arrays of rows).
    const r = try ok(a, "cs_6_0", &.{},
        \\RWStructuredBuffer<row_major float3x2> m;
        \\RWStructuredBuffer<row_major int2x3> i;
        \\RWStructuredBuffer<uint> o;
        \\[numthreads(1,1,1)] void main(uint t : SV_GroupIndex) {
        \\  uint n, stride;
        \\  m.GetDimensions(n, stride);
        \\  o[t] = stride;
        \\  i[t] = i[t + 1] + (int2x3)1;
        \\}
    );
    try expectEqual(@as(?u32, 24), r.memberStride(r.named("type.RWStructuredBuffer.mat3v2float").?, 0));
    var constants: [2]bool = .{ false, false };
    var it = r.ops();
    while (it.next()) |inst| if (inst.op == 43) { // OpConstant
        if (inst.args[2] == 24) constants[0] = true;
        if (inst.args[2] == 32) constants[1] = true;
    };
    try std.testing.expect(constants[0] and !constants[1]);
}

test "structured buffers of matrices pass to parameters whatever their orientation" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // (As in clang, the orientation is sugar on the template argument: one
    // buffer type. Each buffer keeps its own layout: a row_major int2x3 is
    // 2 rows of int3, 32 bytes, where column-major ones are unsupported.)
    const r = try ok(a, "cs_6_0", &.{},
        \\StructuredBuffer<row_major float4x4> b;
        \\#pragma pack_matrix(row_major)
        \\StructuredBuffer<float4x4> c;
        \\RWStructuredBuffer<int2x3> i;
        \\#pragma pack_matrix(column_major)
        \\RWStructuredBuffer<float4> o;
        \\float4 f(StructuredBuffer<float4x4> x) { return x[0][1]; }
        \\float4 g(RWStructuredBuffer<int2x3> x) {
        \\  x[1] = x[0];
        \\  x[2][1] = x.Load(3)[0];
        \\  uint n, s;
        \\  x.GetDimensions(n, s);
        \\  return s;
        \\}
        \\[numthreads(1,1,1)] void main() { o[0] = f(b) + f(c) + g(i); }
    );
    const st = r.named("type.StructuredBuffer.mat4v4float").?;
    try std.testing.expect(r.memberDecorated(st, 0, 5)); // ColMajor: HLSL row_major
    try expectEqual(@as(?u32, 32), r.memberStride(r.named("type.RWStructuredBuffer.mat2v3int").?, 0));
}

test "buffers keep their binding's layout in functions that are not inlined" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The callees are specialized for the buffers passed (Vulkan cannot
    // pass them): their parameters' column-major element types do not
    // lay the buffers out. A row_major float3x4[2] is two 48-byte
    // matrices (column-major they would be 64: no such array type may
    // appear), with its majorness decorated as an array of matrices'; a
    // row_major int2x2 is an array of rows.
    for ([_][]const []const u8{ &.{}, &.{"-Od"} }) |extra| {
        const r = try ok(a, "cs_6_0", extra,
            \\StructuredBuffer<row_major float3x4[2]> b;
            \\StructuredBuffer<row_major int2x2> i;
            \\RWStructuredBuffer<float4> o;
            \\[noinline] float4 f(StructuredBuffer<float3x4[2]> x, uint k) { return x[k][1][2]; }
            \\[noinline] float4 g(StructuredBuffer<int2x2> x, uint k) { return float4(x[k][1], x.Load(k)[0]); }
            \\[numthreads(1,1,1)] void main(uint t : SV_GroupIndex) { o[0] = f(b, t) + g(i, t); }
        );
        var strides: [2]usize = .{ 0, 0 };
        var it = r.ops();
        while (it.next()) |inst| if (inst.op == 71 and inst.args[1] == 6) { // OpDecorate ArrayStride
            if (inst.args[2] == 48) strides[0] += 1;
            if (inst.args[2] == 64) strides[1] += 1;
        };
        try std.testing.expect(strides[0] > 0 and strides[1] == 0);
        const st = r.named("type.StructuredBuffer.matrix<float, 3, 4>[2]").?;
        try expectEqual(@as(?u32, 16), r.memberDeco(st, 0, 7)); // MatrixStride
        try std.testing.expect(r.memberDecorated(st, 0, 5)); // ColMajor: HLSL row_major
    }
}

test "a struct template holds buffers of either orientation: one instance" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // (StructuredBuffer<row_major float4x4> is a StructuredBuffer<float4x4>,
    // as in clang: W of either is one type, and the buffer keeps its own
    // layout through it.)
    const r = try ok(a, "cs_6_0", &.{},
        \\StructuredBuffer<row_major float4x4> b;
        \\RWStructuredBuffer<float4> o;
        \\template<typename B> struct W { B buf; float4 get() { return buf[0][1]; } };
        \\[numthreads(1,1,1)] void main() {
        \\  W<StructuredBuffer<row_major float4x4> > w; w.buf = b;
        \\  W<StructuredBuffer<float4x4> > v = w;
        \\  o[0] = v.get();
        \\}
    );
    try std.testing.expect(r.memberDecorated(r.named("type.StructuredBuffer.mat4v4float").?, 0, 5)); // ColMajor: HLSL row_major
}

test "descriptor heap buffers are laid out as the variable they initialize is declared" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try ok(a, "cs_6_6", &.{},
        \\RWStructuredBuffer<float4> o;
        \\[numthreads(1,1,1)] void main() {
        \\  StructuredBuffer<row_major float4x4> b = ResourceDescriptorHeap[1];
        \\  o[0] = b[0][1];
        \\}
    );
    try std.testing.expect(r.memberDecorated(r.named("type.StructuredBuffer.mat4v4float").?, 0, 5)); // ColMajor: HLSL row_major
}

test "vk::RawBufferLoad: a vector address is truncated, with a warning" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try spirv(a, "cs_6_0", &.{}, "RWStructuredBuffer<float4> o;\n[numthreads(1,1,1)] void main() { uint2 p = uint2(1, 2); o[0] = vk::RawBufferLoad<float4>(p); }");
    try std.testing.expect(r.m != null);
    try std.testing.expect(std.mem.startsWith(u8, r.diagnostics, "hlsl.hlsl:2:91: warning: implicit truncation of vector type"));
}
