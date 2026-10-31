//! DXIL container hashing. Port of lib/DxilHash/DxilHash.cpp
//! (ComputeHashRetail): a modified MD5 whose final block carries the bit
//! length in word 0 and `1 | (byteCount << 1)` in word 15.

const std = @import("std");

const padding = [_]u8{0x80} ++ [_]u8{0} ** 63;

const shifts = [64]u5{
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9,  14, 20, 5, 9,  14, 20, 5, 9,  14, 20, 5, 9,  14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
};

const constants = blk: {
    var k: [64]u32 = undefined;
    for (&k, 0..) |*v, i| {
        v.* = @truncate(@as(u64, @intFromFloat(@floor(@abs(@sin(@as(f64, @floatFromInt(i + 1)))) * 4294967296.0))));
    }
    break :blk k;
};

fn transform(state: *[4]u32, x: *const [16]u32) void {
    var a = state[0];
    var b = state[1];
    var c = state[2];
    var d = state[3];
    for (0..64) |i| {
        var f: u32 = undefined;
        var g: usize = undefined;
        switch (i / 16) {
            0 => {
                f = (b & c) | (~b & d);
                g = i;
            },
            1 => {
                f = (b & d) | (c & ~d);
                g = (5 * i + 1) % 16;
            },
            2 => {
                f = b ^ c ^ d;
                g = (3 * i + 5) % 16;
            },
            else => {
                f = c ^ (b | ~d);
                g = (7 * i) % 16;
            },
        }
        const t = d;
        d = c;
        c = b;
        b = b +% std.math.rotl(u32, a +% f +% x[g] +% constants[i], shifts[i]);
        a = t;
    }
    state[0] +%= a;
    state[1] +%= b;
    state[2] +%= c;
    state[3] +%= d;
}

fn loadBlock(bytes: *const [64]u8) [16]u32 {
    var x: [16]u32 = undefined;
    for (&x, 0..) |*w, i| w.* = std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little);
    return x;
}

/// ComputeHashRetail from DxilHash.cpp.
pub fn computeRetail(data: []const u8) [16]u8 {
    const byte_count: u32 = @intCast(data.len);
    const left_over = byte_count & 0x3f;
    const two_rows = left_over >= 56;
    const pad_amount: u32 = if (two_rows) 120 - left_over else 56 - left_over;
    const n: u32 = (byte_count + pad_amount + 8) >> 6;

    var state = [4]u32{ 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476 };
    const full_blocks = byte_count >> 6;
    var i: u32 = 0;
    while (i < full_blocks) : (i += 1) {
        const x = loadBlock(data[i * 64 ..][0..64]);
        transform(&state, &x);
    }

    const tail = data[full_blocks * 64 ..];
    var block: [64]u8 = undefined;
    if (!two_rows) {
        std.mem.writeInt(u32, block[0..4], byte_count << 3, .little);
        @memcpy(block[4..][0..tail.len], tail);
        @memcpy(block[4 + tail.len ..][0..pad_amount], padding[0..pad_amount]);
        std.mem.writeInt(u32, block[60..64], 1 | (byte_count << 1), .little);
        const x = loadBlock(&block);
        transform(&state, &x);
    } else {
        @memcpy(block[0..tail.len], tail);
        @memcpy(block[tail.len..][0 .. pad_amount - 56], padding[0 .. pad_amount - 56]);
        var x = loadBlock(&block);
        transform(&state, &x);
        std.mem.writeInt(u32, block[0..4], byte_count << 3, .little);
        @memcpy(block[4..60], padding[pad_amount - 56 ..][0..56]);
        std.mem.writeInt(u32, block[60..64], 1 | (byte_count << 1), .little);
        x = loadBlock(&block);
        transform(&state, &x);
    }
    std.debug.assert(full_blocks + @as(u32, if (two_rows) 2 else 1) == n);

    var out: [16]u8 = undefined;
    for (state, 0..) |s, j| std.mem.writeInt(u32, out[j * 4 ..][0..4], s, .little);
    return out;
}

/// Offset of DxilContainerHeader.Version: hashing covers [20, ContainerSize).
pub const hash_start_offset = 20;

/// Recompute and store the container hash, as dxcvalidator's HashAndUpdate does.
pub fn signContainer(container: []u8) void {
    const digest = computeRetail(container[hash_start_offset..]);
    @memcpy(container[4..20], &digest);
}

test "constants match MD5 table" {
    try std.testing.expectEqual(@as(u32, 0xd76aa478), constants[0]);
    try std.testing.expectEqual(@as(u32, 0x02441453), constants[21]);
    try std.testing.expectEqual(@as(u32, 0xeb86d391), constants[63]);
}
