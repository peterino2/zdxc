//! HLSL standard headers that dxc compiles in and resolves for angled
//! includes when no file is found on disk (e.g. `#include <dx/linalg.h>`).
//! Copied from tools/clang/lib/Headers/hlsl; see hlsl-headers/LICENSE.txt.

pub const Header = struct { name: []const u8, text: []const u8 };

pub const headers = [_]Header{
    .{ .name = "enable_if", .text = @embedFile("hlsl-headers/enable_if") },
    .{ .name = "type_traits", .text = @embedFile("hlsl-headers/type_traits") },
    .{ .name = "vector_utils", .text = @embedFile("hlsl-headers/vector_utils") },
    .{ .name = "dx/linalg.h", .text = @embedFile("hlsl-headers/dx/linalg.h") },
    .{ .name = "vk/opcode_selector.h", .text = @embedFile("hlsl-headers/vk/opcode_selector.h") },
    .{ .name = "vk/spirv.h", .text = @embedFile("hlsl-headers/vk/spirv.h") },
    .{ .name = "vk/khr/cooperative_matrix.h", .text = @embedFile("hlsl-headers/vk/khr/cooperative_matrix.h") },
    .{ .name = "vk/khr/cooperative_matrix.impl", .text = @embedFile("hlsl-headers/vk/khr/cooperative_matrix.impl") },
};

pub fn find(name: []const u8) ?[]const u8 {
    for (headers) |h| {
        if (std.mem.eql(u8, h.name, name)) return h.text;
    }
    return null;
}

const std = @import("std");
