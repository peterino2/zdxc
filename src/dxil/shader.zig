//! Builds a complete DXIL container for a shader entry point. For now this
//! only covers an empty compute shader; later milestones feed it from the IR.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Module = @import("module.zig").Module;
const container = @import("container.zig");
const signature = @import("signature.zig");

pub const ShaderKind = enum(u8) {
    pixel = 0,
    vertex = 1,
    geometry = 2,
    hull = 3,
    domain = 4,
    compute = 5,
    library = 6,
    mesh = 13,
    amplification = 14,

    pub fn profilePrefix(k: ShaderKind) []const u8 {
        return switch (k) {
            .pixel => "ps",
            .vertex => "vs",
            .geometry => "gs",
            .hull => "hs",
            .domain => "ds",
            .compute => "cs",
            .library => "lib",
            .mesh => "ms",
            .amplification => "as",
        };
    }
};

/// Highest shader model minor version accepted (matches the oracle dxc).
pub const max_minor = 11;

pub const Profile = struct {
    kind: ShaderKind,
    major: u8,
    minor: u8,

    /// Parses `<stage>_6_<minor>`, e.g. `cs_6_6` or `lib_6_10`.
    pub fn parse(s: []const u8) ?Profile {
        var it = std.mem.splitScalar(u8, s, '_');
        const prefix = it.next() orelse return null;
        const major_str = it.next() orelse return null;
        const minor_str = it.next() orelse return null;
        if (it.next() != null) return null;
        const kind: ShaderKind = for (std.enums.values(ShaderKind)) |k| {
            if (std.mem.eql(u8, prefix, k.profilePrefix())) break k;
        } else return null;
        if (!std.mem.eql(u8, major_str, "6")) return null;
        const minor = std.fmt.parseInt(u8, minor_str, 10) catch return null;
        if (minor > max_minor) return null;
        const min_minor: u8 = switch (kind) {
            .library => 1,
            .mesh, .amplification => 5,
            else => 0,
        };
        if (minor < min_minor) return null;
        return .{ .kind = kind, .major = 6, .minor = minor };
    }
};

pub const ComputeInfo = struct {
    entry: []const u8 = "main",
    profile: Profile,
    num_threads: [3]u32,
};

/// Validator version we claim in !dx.valver (matches the oracle dxc).
const valver = .{ 1, 11 };

pub fn buildEmptyCompute(gpa: Allocator, info: ComputeInfo) ![]u8 {
    var m = Module.init(gpa);
    defer m.deinit();

    const void_ty = try m.getType(.void);
    const fn_ty = try m.fnType(void_ty, &.{});
    const main_fn = try m.addFunction(.{ .name = info.entry, .ty = fn_ty, .num_blocks = 1 });
    _ = try m.addInst(main_fn, .{ .ty = void_ty, .op = .{ .ret = null } });

    // Metadata, in the same shape dxc emits.
    const ident = try m.mdNode(&.{try m.mdString("zdxc 0.0.0")});
    const version = try m.mdNode(&.{ try m.mdI32(1), try m.mdI32(info.profile.minor) });
    const val_ver = try m.mdNode(&.{ try m.mdI32(valver[0]), try m.mdI32(valver[1]) });
    const sm = try m.mdNode(&.{ try m.mdString(info.profile.kind.profilePrefix()), try m.mdI32(info.profile.major), try m.mdI32(info.profile.minor) });
    const threads = try m.mdNode(&.{ try m.mdI32(info.num_threads[0]), try m.mdI32(info.num_threads[1]), try m.mdI32(info.num_threads[2]) });
    const props = try m.mdNode(&.{ try m.mdI32(4), threads }); // kDxilNumThreadsTag
    const fn_ref = try m.mdValue(try m.ptrType(fn_ty), .{ .function = main_fn });
    const entry = try m.mdNode(&.{ fn_ref, try m.mdString(info.entry), null, null, props });

    try m.addNamedMetadata("llvm.ident", &.{ident});
    try m.addNamedMetadata("dx.version", &.{version});
    try m.addNamedMetadata("dx.valver", &.{val_ver});
    try m.addNamedMetadata("dx.shaderModel", &.{sm});
    try m.addNamedMetadata("dx.entryPoints", &.{entry});

    const bitcode = try m.writeBitcode(gpa);
    defer gpa.free(bitcode);

    const dxil_part = try programPart(gpa, info.profile, bitcode);
    defer gpa.free(dxil_part);
    const psv_part = try psvCompute(gpa, info.entry, info.num_threads, &.{});
    defer gpa.free(psv_part);
    const empty_sig = [_]u8{ 0, 0, 0, 0, 8, 0, 0, 0 }; // ParamCount 0, ParamOffset 8

    const parts = [_]container.Part{
        .{ .fourcc = container.fourcc("SFI0"), .data = &@as([8]u8, @splat(0)) },
        .{ .fourcc = container.fourcc("ISG1"), .data = &empty_sig },
        .{ .fourcc = container.fourcc("OSG1"), .data = &empty_sig },
        .{ .fourcc = container.fourcc("PSV0"), .data = psv_part },
        .{ .fourcc = container.fourcc("DXIL"), .data = dxil_part },
    };
    return container.assemble(gpa, &parts);
}

/// DxilProgramHeader + DxilBitcodeHeader + bitcode.
pub fn programPart(gpa: Allocator, profile: Profile, bitcode: []const u8) ![]u8 {
    const padded = std.mem.alignForward(usize, bitcode.len, 4);
    const out = try gpa.alloc(u8, 24 + padded);
    @memset(out, 0);
    const program_version: u32 = (@as(u32, @backingInt(profile.kind)) << 16) | (@as(u32, profile.major) << 4) | profile.minor;
    std.mem.writeInt(u32, out[0..4], program_version, .little);
    std.mem.writeInt(u32, out[4..8], @intCast(out.len / 4), .little);
    std.mem.writeInt(u32, out[8..12], container.fourcc("DXIL"), .little);
    std.mem.writeInt(u32, out[12..16], (1 << 8) | @as(u32, profile.minor), .little); // DXIL version
    std.mem.writeInt(u32, out[16..20], 16, .little); // bitcode offset from bitcode header
    std.mem.writeInt(u32, out[20..24], @intCast(bitcode.len), .little);
    @memcpy(out[24..][0..bitcode.len], bitcode);
    return out;
}

/// One PSVResourceBindInfo1 record.
pub const ResourceBind = struct { res_type: u32, space: u32, lower: u32, upper: u32, kind: u32, flags: u32 = 0 };

pub const PsvInfo = struct {
    kind: ShaderKind,
    entry: []const u8,
    /// The stage-specific PSVRuntimeInfo0 union.
    stage_info: [16]u8 = @splat(0),
    num_threads: [3]u32 = .{ 0, 0, 0 },
    resources: []const ResourceBind = &.{},
    inputs: []const signature.Element = &.{},
    outputs: []const signature.Element = &.{},
    patch_constants: []const signature.Element = &.{},
    groupshared_bytes: u32 = 0,
    max_vertex_count: u16 = 0,
    mesh_topology: u8 = 0,
    uses_view_id: bool = false,
};

pub fn psvCompute(gpa: Allocator, entry: []const u8, num_threads: [3]u32, resources: []const ResourceBind) ![]u8 {
    return psv(gpa, .{ .kind = .compute, .entry = entry, .num_threads = num_threads, .resources = resources });
}

/// PSV0 with PSVRuntimeInfo4 (60 bytes), as produced for validator 1.11.
pub fn psv(gpa: Allocator, info: PsvInfo) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    const w = signature.put32;
    const in_vectors = signature.vectorsUsed(info.inputs, 0);
    var out_vectors: [4]u32 = undefined;
    for (&out_vectors, 0..) |*v, s| v.* = signature.vectorsUsed(info.outputs, @intCast(s));
    const pc_vectors = signature.vectorsUsed(info.patch_constants, 0);

    try w(&buf, gpa, 60); // sizeof(PSVRuntimeInfo4)
    // PSVRuntimeInfo0
    try buf.appendSlice(gpa, &info.stage_info);
    try w(&buf, gpa, 0); // MinimumExpectedWaveLaneCount
    try w(&buf, gpa, 0xFFFFFFFF); // MaximumExpectedWaveLaneCount
    // PSVRuntimeInfo1: stage, UsesViewID, MaxVertexCount, element counts,
    // vector counts.
    // (The MaxVertexCount union holds SigPatchConstOrPrimVectors for hull
    // and domain shaders.)
    // (Mesh shaders: SigPrimVectors and MeshOutputTopology.)
    const union16: u16 = switch (info.kind) {
        .hull, .domain => @intCast(pc_vectors),
        .mesh => @as(u16, @intCast(pc_vectors)) | (@as(u16, info.mesh_topology) << 8),
        else => info.max_vertex_count,
    };
    try buf.appendSlice(gpa, &.{ @backingInt(info.kind), @intFromBool(info.uses_view_id), @truncate(union16), @truncate(union16 >> 8) });
    try buf.appendSlice(gpa, &.{ @intCast(info.inputs.len), @intCast(info.outputs.len), @intCast(info.patch_constants.len), @intCast(in_vectors) });
    for (out_vectors) |v| try buf.append(gpa, @intCast(v));
    // PSVRuntimeInfo2
    for (info.num_threads) |t| try w(&buf, gpa, t);

    // String table: "\0", arbitrary semantic names, the entry name.
    var strings: std.ArrayList(u8) = .empty;
    defer strings.deinit(gpa);
    try strings.append(gpa, 0);
    // Semantic index table, with runs shared between elements.
    var indices: std.ArrayList(u32) = .empty;
    defer indices.deinit(gpa);
    var records: std.ArrayList(u8) = .empty;
    defer records.deinit(gpa);
    for ([_][]const signature.Element{ info.inputs, info.outputs, info.patch_constants }) |els| for (els) |e| {
        var name_off: u32 = 0;
        if (e.kind == .arbitrary and e.name.len > 0) {
            name_off = @intCast(strings.items.len);
            try strings.appendSlice(gpa, e.name);
            try strings.append(gpa, 0);
        }
        const idx_off: u32 = blk: {
            var off: usize = 0;
            while (off + e.indices.len <= indices.items.len) : (off += 1) {
                if (std.mem.eql(u32, indices.items[off..][0..e.indices.len], e.indices)) break :blk @intCast(off);
            }
            try indices.appendSlice(gpa, e.indices);
            break :blk @intCast(indices.items.len - e.indices.len);
        };
        try w(&records, gpa, name_off);
        try w(&records, gpa, idx_off);
        var cols_and_start: u8 = @intCast(e.cols);
        if (e.start_row != null) cols_and_start |= 0x40 | @as(u8, @intCast(e.start_col << 4));
        try records.appendSlice(gpa, &.{ @intCast(e.rows), @intCast(e.start_row orelse 0), cols_and_start, @intFromEnum(e.kind), @intCast(e.comp.sigCompType()), @intFromEnum(e.interp), @intCast((e.stream & 3) << 4), 0 });
    };
    const entry_off: u32 = @intCast(strings.items.len);
    try strings.appendSlice(gpa, info.entry);
    try strings.append(gpa, 0);
    while (strings.items.len % 4 != 0) try strings.append(gpa, 0);

    // PSVRuntimeInfo3: EntryFunctionName
    try w(&buf, gpa, entry_off);
    // PSVRuntimeInfo4
    try w(&buf, gpa, info.groupshared_bytes); // NumBytesGroupSharedMemory
    try w(&buf, gpa, 0); // Flags

    try w(&buf, gpa, @intCast(info.resources.len));
    if (info.resources.len > 0) {
        try w(&buf, gpa, 24); // sizeof(PSVResourceBindInfo1)
        for (info.resources) |r| {
            for ([_]u32{ r.res_type, r.space, r.lower, r.upper, r.kind, r.flags }) |v| try w(&buf, gpa, v);
        }
    }

    try w(&buf, gpa, @intCast(strings.items.len));
    try buf.appendSlice(gpa, strings.items);
    try w(&buf, gpa, @intCast(indices.items.len));
    for (indices.items) |v| try w(&buf, gpa, v);
    if (info.inputs.len + info.outputs.len + info.patch_constants.len > 0) {
        try w(&buf, gpa, 16); // sizeof(PSVSignatureElement0)
        try buf.appendSlice(gpa, records.items);
    }
    // Outputs depending on the ViewID (left empty, like the dependency
    // tables below).
    if (info.uses_view_id) {
        for (out_vectors, 0..) |ov, stream| {
            if (stream > 0 and info.kind != .geometry) break;
            if (ov > 0) try buf.appendNTimes(gpa, 0, ((ov + 7) >> 3) * 4);
        }
        if ((info.kind == .hull or info.kind == .mesh) and pc_vectors > 0) try buf.appendNTimes(gpa, 0, ((pc_vectors + 7) >> 3) * 4);
    }
    // Input-to-output dependency table (no ViewID). Left empty: the
    // validator only checks it against dx.viewIdState, which zdxc omits.
    // (One per output stream for geometry shaders.)
    for (out_vectors, 0..) |ov, stream| {
        if (stream > 0 and info.kind != .geometry) break;
        if (info.kind != .mesh and in_vectors > 0 and ov > 0) try buf.appendNTimes(gpa, 0, tableDwords(in_vectors, ov) * 4);
    }
    // Inputs to patch constants (hull), patch constants to outputs
    // (domain).
    if (info.kind == .hull and pc_vectors > 0 and in_vectors > 0) try buf.appendNTimes(gpa, 0, tableDwords(in_vectors, pc_vectors) * 4);
    if (info.kind == .domain and out_vectors[0] > 0 and pc_vectors > 0) try buf.appendNTimes(gpa, 0, tableDwords(pc_vectors, out_vectors[0]) * 4);
    return buf.toOwnedSlice(gpa);
}

/// PSVComputeInputOutputTableDwords.
fn tableDwords(in_vectors: u32, out_vectors: u32) u32 {
    return ((out_vectors + 7) >> 3) * in_vectors * 4;
}

test "profile parsing" {
    const p = Profile.parse("cs_6_6").?;
    try std.testing.expectEqual(ShaderKind.compute, p.kind);
    try std.testing.expectEqual(@as(u8, 6), p.minor);
    try std.testing.expect(Profile.parse("cs_5_0") == null);
    try std.testing.expectEqual(ShaderKind.library, Profile.parse("lib_6_3").?.kind);
    try std.testing.expectEqual(@as(u8, 10), Profile.parse("cs_6_10").?.minor);
    try std.testing.expect(Profile.parse("ms_6_4") == null);
}
