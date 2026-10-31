//! `-P` output: preprocessed text with `#line` markers, laid out like
//! clang's PrintPreprocessedOutput.

const std = @import("std");
const lexer = @import("lexer.zig");
const Preprocessor = @import("preproc.zig").Preprocessor;
const Token = lexer.Token;

pub fn print(pp: *Preprocessor, w: *std.Io.Writer) !void {
    var cur_file: ?[]const u8 = null;
    var cur_line: u32 = 0;
    var prev: ?Token = null;
    var line_has_tokens = false;
    var cursor: Preprocessor.LineCursor = .{};
    while (true) {
        const t = try pp.next();
        if (t.kind == .eof) break;
        const p = pp.presumedLocCursor(t.loc, &cursor);
        // Paths usually share storage, so compare pointers before bytes.
        const same_file = if (cur_file) |cf| (cf.ptr == p.file.ptr and cf.len == p.file.len) or std.mem.eql(u8, cf, p.file) else false;
        if (!same_file) {
            if (line_has_tokens) try w.writeByte('\n');
            try w.print("#line {d} \"", .{p.line});
            try writeEscaped(w, p.file);
            try w.writeAll("\"\n");
            cur_file = p.file;
            cur_line = p.line;
            line_has_tokens = false;
            prev = null;
        } else if (p.line > cur_line) {
            // Short gaps are reproduced with newlines; long ones get a marker.
            const gap = p.line - cur_line;
            if (gap < 8) {
                try w.splatByteAll('\n', gap);
            } else {
                if (line_has_tokens) try w.writeByte('\n');
                try w.print("#line {d} \"", .{p.line});
                try writeEscaped(w, p.file);
                try w.writeAll("\"\n");
            }
            cur_line = p.line;
            line_has_tokens = false;
            prev = null;
        } else if (t.kind == .pragma and line_has_tokens) {
            try w.writeByte('\n');
            cur_line += 1;
            line_has_tokens = false;
            prev = null;
        }

        if (t.kind == .pragma) {
            try w.print("#pragma {s}\n", .{t.text});
            cur_line += 1;
            line_has_tokens = false;
            prev = null;
            continue;
        }
        if (prev) |pv| {
            if (t.flags.space or avoidConcat(pv, t)) try w.writeByte(' ');
        } else if (t.flags.space and line_has_tokens) try w.writeByte(' ');
        try w.writeAll(t.text);
        prev = t;
        line_has_tokens = true;
    }
    if (line_has_tokens) try w.writeByte('\n');
}

fn writeEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        if (c == '"' or c == '\\') try w.writeByte('\\');
        try w.writeByte(c);
    }
}

/// True when printing `b` directly after `a` would lex differently.
fn avoidConcat(a: Token, b: Token) bool {
    if (a.text.len == 0 or b.text.len == 0) return false;
    const last = a.text[a.text.len - 1];
    const first = b.text[0];
    if (lexer.isIdentChar(last) and (lexer.isIdentChar(first) or first == '.')) return true;
    if (a.kind == .number and (first == '+' or first == '-' or first == '.')) return true;
    var buf: [8]u8 = undefined;
    if (a.text.len > 3 or b.text.len > 3 or !a.kind.isPunct() or !b.kind.isPunct()) return false;
    const joined = std.fmt.bufPrint(&buf, "{s}{s}", .{ a.text, b.text }) catch return true;
    var l = lexer.Lexer.init(joined, 0);
    return l.next().text.len != a.text.len;
}
