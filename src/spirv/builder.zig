//! SPIR-V module builder. Instructions go into per-section buffers that are
//! concatenated in the order required by the SPIR-V logical layout.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Id = u32;

/// Opcodes used so far. Will be replaced by tables generated from
/// vendor/spirv grammar JSON.
pub const Op = enum(u16) {
    name = 5,
    memory_model = 14,
    entry_point = 15,
    execution_mode = 16,
    capability = 17,
    type_void = 19,
    type_function = 33,
    function = 54,
    function_end = 56,
    label = 248,
    @"return" = 253,
};

pub const Section = enum {
    capabilities,
    extensions,
    ext_inst_imports,
    memory_model,
    entry_points,
    execution_modes,
    debug_names,
    annotations,
    types_globals,
    functions,
};

pub const Builder = struct {
    gpa: Allocator,
    sections: std.EnumArray(Section, std.ArrayList(u32)) = .initFill(.empty),
    next_id: Id = 1,

    pub fn init(gpa: Allocator) Builder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(b: *Builder) void {
        for (&b.sections.values) |*s| s.deinit(b.gpa);
    }

    pub fn newId(b: *Builder) Id {
        defer b.next_id += 1;
        return b.next_id;
    }

    /// Emit an instruction; `operands` are raw words.
    pub fn emit(b: *Builder, section: Section, op: Op, operands: []const u32) !void {
        const s = b.sections.getPtr(section);
        const count: u32 = @intCast(operands.len + 1);
        try s.append(b.gpa, (count << 16) | @backingInt(op));
        try s.appendSlice(b.gpa, operands);
    }

    /// Emit an instruction with a literal string operand placed after `pre`
    /// and followed by `post`.
    pub fn emitWithString(b: *Builder, section: Section, op: Op, pre: []const u32, str: []const u8, post: []const u32) !void {
        const str_words = str.len / 4 + 1;
        const s = b.sections.getPtr(section);
        const count: u32 = @intCast(1 + pre.len + str_words + post.len);
        try s.append(b.gpa, (count << 16) | @backingInt(op));
        try s.appendSlice(b.gpa, pre);
        for (0..str_words) |wi| {
            var word: [4]u8 = @splat(0);
            for (0..4) |ci| {
                const idx = wi * 4 + ci;
                if (idx < str.len) word[ci] = str[idx];
            }
            try s.append(b.gpa, std.mem.readInt(u32, &word, .little));
        }
        try s.appendSlice(b.gpa, post);
    }

    /// Serialize as little-endian bytes.
    pub fn finish(b: *Builder, version: u32) ![]u8 {
        var total: usize = 5;
        for (b.sections.values) |s| total += s.items.len;
        const out = try b.gpa.alloc(u8, total * 4);
        const header = [5]u32{ 0x07230203, version, generator_magic, b.next_id, 0 };
        var off: usize = 0;
        for (header) |word| {
            std.mem.writeInt(u32, out[off..][0..4], word, .little);
            off += 4;
        }
        for (b.sections.values) |s| {
            for (s.items) |word| {
                std.mem.writeInt(u32, out[off..][0..4], word, .little);
                off += 4;
            }
        }
        return out;
    }
};

/// Unregistered generator ID (tool 0), version 0.
const generator_magic = 0;

pub const spv_1_0: u32 = 0x00010000;

pub const ComputeInfo = struct {
    entry: []const u8 = "main",
    num_threads: [3]u32,
};

pub fn buildEmptyCompute(gpa: Allocator, info: ComputeInfo) ![]u8 {
    var b = Builder.init(gpa);
    defer b.deinit();

    const void_ty = b.newId();
    const fn_ty = b.newId();
    const main_fn = b.newId();
    const entry_label = b.newId();

    try b.emit(.capabilities, .capability, &.{1}); // Shader
    try b.emit(.memory_model, .memory_model, &.{ 0, 1 }); // Logical GLSL450
    try b.emitWithString(.entry_points, .entry_point, &.{ 5, main_fn }, info.entry, &.{}); // GLCompute
    try b.emit(.execution_modes, .execution_mode, &.{ main_fn, 17, info.num_threads[0], info.num_threads[1], info.num_threads[2] }); // LocalSize
    try b.emitWithString(.debug_names, .name, &.{main_fn}, info.entry, &.{});
    try b.emit(.types_globals, .type_void, &.{void_ty});
    try b.emit(.types_globals, .type_function, &.{ fn_ty, void_ty });
    try b.emit(.functions, .function, &.{ void_ty, main_fn, 0, fn_ty });
    try b.emit(.functions, .label, &.{entry_label});
    try b.emit(.functions, .@"return", &.{});
    try b.emit(.functions, .function_end, &.{});

    return b.finish(spv_1_0);
}

test "string operands are NUL-terminated and padded" {
    var b = Builder.init(std.testing.allocator);
    defer b.deinit();
    try b.emitWithString(.debug_names, .name, &.{7}, "main", &.{});
    const words = b.sections.get(.debug_names).items;
    try std.testing.expectEqual(@as(usize, 4), words.len); // opcode, id, "main", "\0\0\0\0"
    try std.testing.expectEqual(@as(u32, 0), words[3]);
}
