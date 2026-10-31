//! zdxc: an HLSL 2021 compiler targeting DXIL and SPIR-V.

pub const dxil = struct {
    pub const bitstream = @import("dxil/bitstream.zig");
    pub const container = @import("dxil/container.zig");
    pub const hash = @import("dxil/hash.zig");
    pub const module = @import("dxil/module.zig");
    pub const shader = @import("dxil/shader.zig");
};

pub const spirv = struct {
    pub const builder = @import("spirv/builder.zig");
};

pub const version = "0.0.0";

test {
    const std = @import("std");
    std.testing.refAllDecls(dxil);
    std.testing.refAllDecls(spirv);
}
