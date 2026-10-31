//! zdxc: an HLSL 2021 compiler targeting DXIL and SPIR-V.

pub const diag = @import("diag.zig");
pub const Diagnostics = diag.Diagnostics;

pub const front = struct {
    pub const source = @import("front/source.zig");
    pub const lexer = @import("front/lexer.zig");
    pub const scan = @import("front/scan.zig");
    pub const preproc = @import("front/preproc.zig");
    pub const pp_print = @import("front/pp_print.zig");
    pub const ast = @import("front/ast.zig");
    pub const parser = @import("front/parser.zig");
    pub const ast_dump = @import("front/ast_dump.zig");
};

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
    std.testing.refAllDecls(front);
    std.testing.refAllDecls(dxil);
    std.testing.refAllDecls(spirv);
    _ = @import("diag.zig");
}
