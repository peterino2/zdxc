//! LLVM bitstream writer (the container format under LLVM bitcode).
//! Only unabbreviated records are emitted for now; they are always valid and
//! the LLVM 3.7 reader accepts them everywhere.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const abbrev_end_block = 0;
pub const abbrev_enter_subblock = 1;
pub const abbrev_define = 2;
pub const abbrev_unabbrev_record = 3;

pub const Writer = struct {
    gpa: Allocator,
    bytes: std.ArrayList(u8) = .empty,
    cur: u64 = 0,
    cur_bits: u6 = 0,
    abbrev_width: u32 = 2,
    blocks: std.ArrayList(Block) = .empty,

    const Block = struct { prev_width: u32, size_word_index: usize };

    pub fn init(gpa: Allocator) Writer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(w: *Writer) void {
        w.bytes.deinit(w.gpa);
        w.blocks.deinit(w.gpa);
    }

    pub fn emit(w: *Writer, value: u64, width: u32) !void {
        std.debug.assert(width <= 32);
        if (width == 0) return;
        std.debug.assert(width == 32 or value >> @intCast(width) == 0);
        w.cur |= value << w.cur_bits;
        const total = @as(u32, w.cur_bits) + width;
        if (total >= 32) {
            var word: [4]u8 = undefined;
            std.mem.writeInt(u32, &word, @truncate(w.cur), .little);
            try w.bytes.appendSlice(w.gpa, &word);
            w.cur >>= 32;
            w.cur_bits = @intCast(total - 32);
        } else {
            w.cur_bits = @intCast(total);
        }
    }

    pub fn emitVbr(w: *Writer, value: u64, width: u32) !void {
        const threshold: u64 = @as(u64, 1) << @intCast(width - 1);
        var v = value;
        while (v >= threshold) {
            try w.emit((v & (threshold - 1)) | threshold, width);
            v >>= @intCast(width - 1);
        }
        try w.emit(v, width);
    }

    pub fn alignTo32(w: *Writer) !void {
        if (w.cur_bits > 0) try w.emit(0, 32 - @as(u32, w.cur_bits));
    }

    pub fn enterBlock(w: *Writer, block_id: u32, abbrev_width: u32) !void {
        try w.emit(abbrev_enter_subblock, w.abbrev_width);
        try w.emitVbr(block_id, 8);
        try w.emitVbr(abbrev_width, 4);
        try w.alignTo32();
        const idx = w.bytes.items.len;
        try w.emit(0, 32); // block size in words, patched in endBlock
        try w.blocks.append(w.gpa, .{ .prev_width = w.abbrev_width, .size_word_index = idx });
        w.abbrev_width = abbrev_width;
    }

    pub fn endBlock(w: *Writer) !void {
        try w.emit(abbrev_end_block, w.abbrev_width);
        try w.alignTo32();
        const blk = w.blocks.pop().?;
        const words: u32 = @intCast((w.bytes.items.len - blk.size_word_index - 4) / 4);
        std.mem.writeInt(u32, w.bytes.items[blk.size_word_index..][0..4], words, .little);
        w.abbrev_width = blk.prev_width;
    }

    pub fn record(w: *Writer, code: u32, ops: []const u64) !void {
        try w.emit(abbrev_unabbrev_record, w.abbrev_width);
        try w.emitVbr(code, 6);
        try w.emitVbr(ops.len, 6);
        for (ops) |op| try w.emitVbr(op, 6);
    }

    /// Record whose operands are the bytes of `str`, optionally prefixed.
    pub fn recordString(w: *Writer, code: u32, prefix: []const u64, str: []const u8) !void {
        try w.emit(abbrev_unabbrev_record, w.abbrev_width);
        try w.emitVbr(code, 6);
        try w.emitVbr(prefix.len + str.len, 6);
        for (prefix) |op| try w.emitVbr(op, 6);
        for (str) |c| try w.emitVbr(c, 6);
    }

    /// Flush pending bits and return the finished stream (caller owns it).
    pub fn finish(w: *Writer) ![]u8 {
        std.debug.assert(w.blocks.items.len == 0);
        try w.alignTo32();
        return w.bytes.toOwnedSlice(w.gpa);
    }
};

test "vbr and fixed fields pack little-endian" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    try w.emit('B', 8);
    try w.emit('C', 8);
    try w.emit(0x0, 4);
    try w.emit(0xC, 4);
    try w.emit(0xE, 4);
    try w.emit(0xD, 4);
    const out = try w.finish();
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualSlices(u8, &.{ 'B', 'C', 0xC0, 0xDE }, out);
}
