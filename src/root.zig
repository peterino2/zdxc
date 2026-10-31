//! zdxc: an HLSL 2021 compiler targeting DXIL and SPIR-V.

pub const diag = @import("diag.zig");
pub const options = @import("options.zig");
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
    pub const emit = @import("dxil/emit.zig");
};

pub const ir = struct {
    pub const ir = @import("ir/ir.zig");
    pub const lower = @import("ir/lower.zig");
};

pub const sema = struct {
    pub const types = @import("sema/types.zig");
    pub const intrinsics = @import("sema/intrinsics.zig");
    pub const Sema = @import("sema/sema.zig").Sema;
};

pub const spirv = struct {
    pub const builder = @import("spirv/builder.zig");
    pub const emit = @import("spirv/emit.zig");
};

pub const version = "0.0.0";

test {
    const std = @import("std");
    std.testing.refAllDecls(front);
    std.testing.refAllDecls(dxil);
    _ = @import("sema/types.zig");
    _ = @import("sema/sema.zig");
    std.testing.refAllDecls(spirv);
    _ = @import("diag.zig");
    _ = @import("options.zig");
}
