//! Byte-scanning primitives for the lexer and source manager, written with
//! portable `@Vector`s (the vector length comes from
//! std.simd.suggestVectorLength; no per-platform code).

const std = @import("std");

const vec_len = std.simd.suggestVectorLength(u8) orelse 16;
const V = @Vector(vec_len, u8);
const Mask = @Int(.unsigned, vec_len);

inline fn load(text: []const u8, i: usize) V {
    return text[i..][0..vec_len].*;
}

inline fn bits(m: @Vector(vec_len, bool)) Mask {
    return @bitCast(m);
}

/// Index of the first byte at or after `start` that is not ' ' or '\t',
/// or text.len.
pub fn skipBlanks(text: []const u8, start: usize) usize {
    var i = start;
    while (i + vec_len <= text.len) : (i += vec_len) {
        const b = load(text, i);
        const blank = bits(b == @as(V, @splat(' '))) | bits(b == @as(V, @splat('\t')));
        if (blank != std.math.maxInt(Mask)) return i + @ctz(~blank);
    }
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    return i;
}

/// Index of the first '\n' at or after `start`, or text.len.
pub fn findNewline(text: []const u8, start: usize) usize {
    return std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
}

/// Index just past the `*/` closing a block comment whose body starts at
/// `start`, or text.len if it is unterminated.
pub fn skipBlockComment(text: []const u8, start: usize) usize {
    var i = start;
    while (std.mem.indexOfScalarPos(u8, text, i, '*')) |star| {
        if (star + 1 < text.len and text[star + 1] == '/') return star + 2;
        i = star + 1;
    }
    return text.len;
}

/// Append the offset of the byte after every '\n' in `text`.
pub fn appendLineStarts(gpa: std.mem.Allocator, list: *std.ArrayList(u32), text: []const u8) !void {
    var i: usize = 0;
    while (i + vec_len <= text.len) : (i += vec_len) {
        var m = bits(load(text, i) == @as(V, @splat('\n')));
        if (m == 0) continue;
        try list.ensureUnusedCapacity(gpa, @popCount(m));
        while (m != 0) : (m &= m - 1) {
            list.appendAssumeCapacity(@intCast(i + @ctz(m) + 1));
        }
    }
    while (i < text.len) : (i += 1) {
        if (text[i] == '\n') try list.append(gpa, @intCast(i + 1));
    }
}

/// Number of '\n' bytes in `text`.
pub fn countNewlines(text: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i + vec_len <= text.len) : (i += vec_len) {
        n += @popCount(bits(load(text, i) == @as(V, @splat('\n'))));
    }
    while (i < text.len) : (i += 1) n += @intFromBool(text[i] == '\n');
    return n;
}

/// Character classes for the scalar lexer paths (identifiers are usually
/// shorter than a vector, so a table lookup beats SIMD there).
pub const ident_char: [256]bool = blk: {
    var t: [256]bool = @splat(false);
    for ('a'..'z' + 1) |c| t[c] = true;
    for ('A'..'Z' + 1) |c| t[c] = true;
    for ('0'..'9' + 1) |c| t[c] = true;
    t['_'] = true;
    break :blk t;
};

/// Index of the first non-identifier byte at or after `start`.
pub fn skipIdent(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len and ident_char[text[i]]) i += 1;
    return i;
}

fn refLineStarts(gpa: std.mem.Allocator, text: []const u8) ![]u32 {
    var l: std.ArrayList(u32) = .empty;
    for (text, 0..) |c, i| if (c == '\n') try l.append(gpa, @intCast(i + 1));
    return l.toOwnedSlice(gpa);
}

test "vector scans agree with scalar references" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const r = prng.random();
    const alphabet = " \t\n/*ab_9\"\\";
    for (0..300) |_| {
        const len = r.uintLessThan(usize, 200);
        const text = try gpa.alloc(u8, len);
        defer gpa.free(text);
        for (text) |*c| c.* = alphabet[r.uintLessThan(usize, alphabet.len)];
        const start = if (len == 0) 0 else r.uintLessThan(usize, len);

        var blanks = start;
        while (blanks < len and (text[blanks] == ' ' or text[blanks] == '\t')) blanks += 1;
        try std.testing.expectEqual(blanks, skipBlanks(text, start));

        const ref_end = if (std.mem.indexOfPos(u8, text, start, "*/")) |e| e + 2 else len;
        try std.testing.expectEqual(ref_end, skipBlockComment(text, start));

        const ref = try refLineStarts(gpa, text);
        defer gpa.free(ref);
        var got: std.ArrayList(u32) = .empty;
        defer got.deinit(gpa);
        try appendLineStarts(gpa, &got, text);
        try std.testing.expectEqualSlices(u32, ref, got.items);
        try std.testing.expectEqual(ref.len, countNewlines(text));
    }
}
