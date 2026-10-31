//! SPIR-V module builder. Instructions go into per-section buffers that are
//! concatenated in the order required by the SPIR-V logical layout.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Id = u32;

/// SPIR-V opcodes (unified1 core grammar numbering).
pub const Op = enum(u16) {
    undef = 1,
    source = 3,
    name = 5,
    member_name = 6,
    extension = 10,
    ext_inst_import = 11,
    ext_inst = 12,
    memory_model = 14,
    entry_point = 15,
    execution_mode = 16,
    capability = 17,
    type_void = 19,
    type_bool = 20,
    type_int = 21,
    type_float = 22,
    type_vector = 23,
    type_matrix = 24,
    type_image = 25,
    type_sampler = 26,
    type_sampled_image = 27,
    type_array = 28,
    type_runtime_array = 29,
    type_struct = 30,
    type_pointer = 32,
    type_function = 33,
    constant_true = 41,
    constant_false = 42,
    constant = 43,
    constant_composite = 44,
    constant_null = 46,
    function = 54,
    function_parameter = 55,
    function_end = 56,
    function_call = 57,
    variable = 59,
    load = 61,
    store = 62,
    access_chain = 65,
    decorate = 71,
    member_decorate = 72,
    vector_extract_dynamic = 77,
    vector_insert_dynamic = 78,
    vector_shuffle = 79,
    composite_construct = 80,
    composite_extract = 81,
    composite_insert = 82,
    copy_object = 83,
    transpose = 84,
    array_length = 68,
    sampled_image = 86,
    image_sample_implicit_lod = 87,
    image_sample_explicit_lod = 88,
    image_sample_dref_implicit_lod = 89,
    image_sample_dref_explicit_lod = 90,
    image_fetch = 95,
    image_gather = 96,
    image_dref_gather = 97,
    image_read = 98,
    image_write = 99,
    image_query_size_lod = 103,
    image_query_size = 104,
    image_query_lod = 105,
    image_query_levels = 106,
    image_query_samples = 107,
    convert_f_to_u = 109,
    convert_f_to_s = 110,
    convert_s_to_f = 111,
    convert_u_to_f = 112,
    u_convert = 113,
    s_convert = 114,
    f_convert = 115,
    bitcast = 124,
    s_negate = 126,
    f_negate = 127,
    i_add = 128,
    f_add = 129,
    i_sub = 130,
    f_sub = 131,
    i_mul = 132,
    f_mul = 133,
    u_div = 134,
    s_div = 135,
    f_div = 136,
    u_mod = 137,
    s_rem = 138,
    s_mod = 139,
    f_rem = 140,
    f_mod = 141,
    vector_times_scalar = 142,
    matrix_times_scalar = 143,
    vector_times_matrix = 144,
    matrix_times_vector = 145,
    matrix_times_matrix = 146,
    dot = 148,
    any = 154,
    all = 155,
    is_nan = 156,
    is_inf = 157,
    logical_equal = 164,
    logical_not_equal = 165,
    logical_or = 166,
    logical_and = 167,
    logical_not = 168,
    select = 169,
    i_equal = 170,
    i_not_equal = 171,
    u_greater_than = 172,
    s_greater_than = 173,
    u_greater_than_equal = 174,
    s_greater_than_equal = 175,
    u_less_than = 176,
    s_less_than = 177,
    u_less_than_equal = 178,
    s_less_than_equal = 179,
    f_ord_equal = 180,
    f_ord_not_equal = 182,
    f_unord_not_equal = 183,
    f_ord_less_than = 184,
    f_ord_greater_than = 186,
    f_ord_less_than_equal = 188,
    f_ord_greater_than_equal = 190,
    shift_right_logical = 194,
    shift_right_arithmetic = 195,
    shift_left_logical = 196,
    bitwise_or = 197,
    bitwise_xor = 198,
    bitwise_and = 199,
    not_ = 200,
    bit_reverse = 204,
    bit_count = 205,
    dpdx = 207,
    dpdy = 208,
    fwidth = 209,
    control_barrier = 224,
    memory_barrier = 225,
    phi = 245,
    loop_merge = 246,
    selection_merge = 247,
    label = 248,
    branch = 249,
    branch_conditional = 250,
    @"switch" = 251,
    kill = 252,
    @"return" = 253,
    return_value = 254,
    @"unreachable" = 255,
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
