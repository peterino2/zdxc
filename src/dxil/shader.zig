//! Builds a complete DXIL container for a shader entry point. For now this
//! only covers an empty compute shader; later milestones feed it from the IR.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Module = @import("module.zig").Module;
const container = @import("container.zig");

pub const ShaderKind = enum(u8) {
    pixel = 0,
    vertex = 1,
    geometry = 2,
    hull = 3,
    domain = 4,
    compute = 5,

    pub fn profilePrefix(k: ShaderKind) []const u8 {
        return switch (k) {
            .pixel => "ps",
            .vertex => "vs",
            .geometry => "gs",
            .hull => "hs",
            .domain => "ds",
            .compute => "cs",
        };
    }
};

pub const Profile = struct {
    kind: ShaderKind,
    major: u8,
    minor: u8,

    pub fn parse(s: []const u8) ?Profile {
        if (s.len != 6 or s[2] != '_' or s[4] != '_') return null;
        const kind: ShaderKind = for (std.enums.values(ShaderKind)) |k| {
            if (std.mem.eql(u8, s[0..2], k.profilePrefix())) break k;
        } else return null;
        if (s[3] != '6' or s[5] < '0' or s[5] > '9') return null;
        return .{ .kind = kind, .major = 6, .minor = s[5] - '0' };
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
    const psv = try psvCompute(gpa, info.entry, info.num_threads);
    defer gpa.free(psv);
    const empty_sig = [_]u8{ 0, 0, 0, 0, 8, 0, 0, 0 }; // ParamCount 0, ParamOffset 8

    const parts = [_]container.Part{
        .{ .fourcc = container.fourcc("SFI0"), .data = &@as([8]u8, @splat(0)) },
        .{ .fourcc = container.fourcc("ISG1"), .data = &empty_sig },
        .{ .fourcc = container.fourcc("OSG1"), .data = &empty_sig },
        .{ .fourcc = container.fourcc("PSV0"), .data = psv },
        .{ .fourcc = container.fourcc("DXIL"), .data = dxil_part },
    };
    return container.assemble(gpa, &parts);
}

/// DxilProgramHeader + DxilBitcodeHeader + bitcode.
fn programPart(gpa: Allocator, profile: Profile, bitcode: []const u8) ![]u8 {
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

/// PSV0 with PSVRuntimeInfo4 (60 bytes), as produced for validator 1.11.
fn psvCompute(gpa: Allocator, entry: []const u8, num_threads: [3]u32) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    const w = struct {
        fn u32_(b: *std.ArrayList(u8), a: Allocator, v: u32) !void {
            var tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &tmp, v, .little);
            try b.appendSlice(a, &tmp);
        }
    }.u32_;

    try w(&buf, gpa, 60); // sizeof(PSVRuntimeInfo4)
    // PSVRuntimeInfo0
    try buf.appendNTimes(gpa, 0, 16); // stage-specific union
    try w(&buf, gpa, 0); // MinimumExpectedWaveLaneCount
    try w(&buf, gpa, 0xFFFFFFFF); // MaximumExpectedWaveLaneCount
    // PSVRuntimeInfo1
    try buf.appendSlice(gpa, &.{ @backingInt(ShaderKind.compute), 0, 0, 0 }); // stage, UsesViewID, union
    try buf.appendNTimes(gpa, 0, 4); // sig element counts, SigInputVectors
    try buf.appendNTimes(gpa, 0, 4); // SigOutputVectors[4]
    // PSVRuntimeInfo2
    for (num_threads) |t| try w(&buf, gpa, t);
    // PSVRuntimeInfo3: EntryFunctionName offset into string table (after leading NUL)
    try w(&buf, gpa, 1);
    // PSVRuntimeInfo4
    try w(&buf, gpa, 0); // NumBytesGroupSharedMemory
    try w(&buf, gpa, 0); // Flags

    try w(&buf, gpa, 0); // resource count

    // String table: "\0" ++ entry ++ "\0", padded to 4 bytes.
    const strtab_len = std.mem.alignForward(usize, entry.len + 2, 4);
    try w(&buf, gpa, @intCast(strtab_len));
    try buf.append(gpa, 0);
    try buf.appendSlice(gpa, entry);
    try buf.appendNTimes(gpa, 0, strtab_len - entry.len - 1);

    try w(&buf, gpa, 0); // semantic index table count
    return buf.toOwnedSlice(gpa);
}

test "profile parsing" {
    const p = Profile.parse("cs_6_6").?;
    try std.testing.expectEqual(ShaderKind.compute, p.kind);
    try std.testing.expectEqual(@as(u8, 6), p.minor);
    try std.testing.expect(Profile.parse("cs_5_0") == null);
    try std.testing.expect(Profile.parse("lib_6_3") == null);
}
