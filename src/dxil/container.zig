//! DXIL container ("DXBC" header + parts). See
//! include/dxc/DxilContainer/DxilContainer.h.

const std = @import("std");
const Allocator = std.mem.Allocator;
const hash = @import("hash.zig");

pub fn fourcc(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .little);
}

pub const Part = struct {
    fourcc: u32,
    data: []const u8,
};

const header_size = 32; // FourCC, hash[16], version, size, part count

/// Assemble parts into a container and sign it (as the validator would).
pub fn assemble(gpa: Allocator, parts: []const Part) ![]u8 {
    var size: usize = header_size + 4 * parts.len;
    for (parts) |p| size += 8 + std.mem.alignForward(usize, p.data.len, 4);
    const out = try gpa.alloc(u8, size);
    @memset(out, 0);

    std.mem.writeInt(u32, out[0..4], fourcc("DXBC"), .little);
    std.mem.writeInt(u16, out[20..22], 1, .little); // version major
    std.mem.writeInt(u16, out[22..24], 0, .little); // version minor
    std.mem.writeInt(u32, out[24..28], @intCast(size), .little);
    std.mem.writeInt(u32, out[28..32], @intCast(parts.len), .little);

    var off: usize = header_size + 4 * parts.len;
    for (parts, 0..) |p, i| {
        std.mem.writeInt(u32, out[header_size + 4 * i ..][0..4], @intCast(off), .little);
        std.mem.writeInt(u32, out[off..][0..4], p.fourcc, .little);
        const padded = std.mem.alignForward(usize, p.data.len, 4);
        std.mem.writeInt(u32, out[off + 4 ..][0..4], @intCast(padded), .little);
        @memcpy(out[off + 8 ..][0..p.data.len], p.data);
        off += 8 + padded;
    }
    hash.signContainer(out);
    return out;
}

pub const ParseError = error{InvalidContainer};

/// Parsed view into a container; part data slices alias `bytes`.
pub const View = struct {
    bytes: []const u8,
    parts: std.ArrayList(Part),

    pub fn deinit(v: *View, gpa: Allocator) void {
        v.parts.deinit(gpa);
    }

    pub fn find(v: *const View, cc: u32) ?[]const u8 {
        for (v.parts.items) |p| if (p.fourcc == cc) return p.data;
        return null;
    }
};

pub fn parse(gpa: Allocator, bytes: []const u8) !View {
    if (bytes.len < header_size) return error.InvalidContainer;
    if (std.mem.readInt(u32, bytes[0..4], .little) != fourcc("DXBC")) return error.InvalidContainer;
    const size = std.mem.readInt(u32, bytes[24..28], .little);
    const count = std.mem.readInt(u32, bytes[28..32], .little);
    if (size > bytes.len or header_size + 4 * @as(usize, count) > size) return error.InvalidContainer;
    var parts: std.ArrayList(Part) = .empty;
    errdefer parts.deinit(gpa);
    for (0..count) |i| {
        const off = std.mem.readInt(u32, bytes[header_size + 4 * i ..][0..4], .little);
        if (@as(usize, off) + 8 > size) return error.InvalidContainer;
        const cc = std.mem.readInt(u32, bytes[off..][0..4], .little);
        const len = std.mem.readInt(u32, bytes[off + 4 ..][0..4], .little);
        if (@as(usize, off) + 8 + len > size) return error.InvalidContainer;
        try parts.append(gpa, .{ .fourcc = cc, .data = bytes[off + 8 ..][0..len] });
    }
    return .{ .bytes = bytes[0..size], .parts = parts };
}

/// True if the stored hash matches a fresh ComputeHashRetail of the container.
pub fn hashMatches(bytes: []const u8) bool {
    const digest = hash.computeRetail(bytes[hash.hash_start_offset..]);
    return std.mem.eql(u8, &digest, bytes[4..20]);
}

test "assemble round-trips through parse and verifies its hash" {
    const gpa = std.testing.allocator;
    const parts = [_]Part{
        .{ .fourcc = fourcc("SFI0"), .data = &@as([8]u8, @splat(0)) },
        .{ .fourcc = fourcc("PRIV"), .data = "abc" },
    };
    const out = try assemble(gpa, &parts);
    defer gpa.free(out);
    try std.testing.expect(hashMatches(out));
    var view = try parse(gpa, out);
    defer view.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), view.parts.items.len);
    try std.testing.expectEqualSlices(u8, "abc\x00", view.find(fourcc("PRIV")).?);
}
