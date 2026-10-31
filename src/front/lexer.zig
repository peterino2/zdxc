//! HLSL lexer producing preprocessing tokens. Keywords are not distinguished
//! here; the parser classifies identifiers.

const std = @import("std");
const source = @import("source.zig");
const scan = @import("scan.zig");

pub const Kind = enum(u8) {
    eof,
    /// Unlexable input (stray character, unterminated literal).
    invalid,
    identifier,
    /// pp-number: integer and floating literals with suffixes.
    number,
    string,
    char,
    /// Produced by the preprocessor for `#pragma` lines; text holds the
    /// pragma body.
    pragma,

    l_paren,
    r_paren,
    l_brace,
    r_brace,
    l_square,
    r_square,
    semi,
    comma,
    colon,
    colon_colon,
    question,
    period,
    ellipsis,
    arrow,
    plus,
    plus_plus,
    plus_equal,
    minus,
    minus_minus,
    minus_equal,
    star,
    star_equal,
    slash,
    slash_equal,
    percent,
    percent_equal,
    amp,
    amp_amp,
    amp_equal,
    pipe,
    pipe_pipe,
    pipe_equal,
    caret,
    caret_equal,
    tilde,
    exclaim,
    exclaim_equal,
    equal,
    equal_equal,
    less,
    less_equal,
    less_less,
    less_less_equal,
    greater,
    greater_equal,
    greater_greater,
    greater_greater_equal,
    hash,
    hash_hash,

    pub fn isPunct(k: Kind) bool {
        return @backingInt(k) >= @backingInt(Kind.l_paren);
    }
};

pub const Flags = packed struct(u8) {
    /// First token on its (physical) line.
    bol: bool = false,
    /// Preceded by whitespace or a comment.
    space: bool = false,
    /// Painted by the preprocessor: never macro-expand this identifier.
    no_expand: bool = false,
    /// Transient, during macro substitution: the token came from an argument.
    from_arg: bool = false,
    _: u4 = 0,
};

pub const Token = struct {
    kind: Kind,
    flags: Flags = .{},
    /// Spelling. Points into the source text, or into preprocessor-owned
    /// memory for tokens created by `#` and `##`.
    text: []const u8,
    loc: source.Loc,

    pub fn is(t: Token, kind: Kind) bool {
        return t.kind == kind;
    }

    pub inline fn isIdent(t: Token, name: []const u8) bool {
        // Length first: most keyword checks fail on it without a call.
        return t.kind == .identifier and t.text.len == name.len and std.mem.eql(u8, t.text, name);
    }
};

pub const Lexer = struct {
    text: []const u8,
    file: source.FileId,
    pos: u32 = 0,
    at_bol: bool = true,

    pub fn init(text: []const u8, file: source.FileId) Lexer {
        return .{ .text = text, .file = file };
    }

    fn peekAt(l: *const Lexer, i: usize) u8 {
        return if (i < l.text.len) l.text[i] else 0;
    }

    /// Skip whitespace and comments; report whether any was seen and whether
    /// a newline was crossed.
    fn skipTrivia(l: *Lexer) struct { space: bool, newline: bool } {
        var space = false;
        var newline = false;
        while (l.pos < l.text.len) {
            const c = l.text[l.pos];
            switch (c) {
                ' ', '\t', '\r', 0x0b, 0x0c => {
                    space = true;
                    l.pos += 1;
                },
                '\n' => {
                    newline = true;
                    space = false;
                    l.pos += 1;
                },
                '/' => {
                    const n = l.peekAt(l.pos + 1);
                    if (n == '/') {
                        l.pos = @intCast(scan.findNewline(l.text, l.pos + 2));
                        space = true;
                    } else if (n == '*') {
                        // A newline inside a block comment does not start a
                        // new line for directive purposes (the comment is one
                        // space after translation phase 3). An unterminated
                        // comment runs to EOF.
                        l.pos = @intCast(scan.skipBlockComment(l.text, l.pos + 2));
                        space = true;
                    } else break;
                },
                else => break,
            }
        }
        return .{ .space = space, .newline = newline };
    }

    pub fn next(l: *Lexer) Token {
        const trivia = l.skipTrivia();
        if (trivia.newline) l.at_bol = true;
        var flags: Flags = .{ .bol = l.at_bol, .space = trivia.space };
        if (l.at_bol) flags.space = false;
        l.at_bol = false;
        const start = l.pos;
        const kind = l.lexToken();
        return .{
            .kind = kind,
            .flags = flags,
            .text = l.text[start..l.pos],
            .loc = .{ .file = l.file, .offset = start },
        };
    }

    /// Rest of the current line, used for `#error`, `#pragma` and similar.
    /// Leaves the lexer at the newline.
    pub fn restOfLine(l: *Lexer) []const u8 {
        const start = l.pos;
        while (l.pos < l.text.len and l.text[l.pos] != '\n') {
            // Block comments may contain newlines; skip them as a unit.
            if (l.text[l.pos] == '/' and l.peekAt(l.pos + 1) == '*') {
                if (std.mem.indexOfPos(u8, l.text, l.pos + 2, "*/")) |end| {
                    l.pos = @intCast(end + 2);
                    continue;
                }
            }
            if (l.text[l.pos] == '/' and l.peekAt(l.pos + 1) == '/') {
                const s = l.text[start..l.pos];
                while (l.pos < l.text.len and l.text[l.pos] != '\n') l.pos += 1;
                return std.mem.trim(u8, s, " \t\r");
            }
            l.pos += 1;
        }
        return std.mem.trim(u8, l.text[start..l.pos], " \t\r");
    }

    /// After `#include`, lex `<...>` as a header name. Returns null if the
    /// next token does not start with `<`.
    pub fn headerName(l: *Lexer) ?Token {
        const trivia = l.skipTrivia();
        if (trivia.newline) {
            l.at_bol = true;
            return null;
        }
        if (l.peekAt(l.pos) != '<') return null;
        const start = l.pos;
        var i = l.pos + 1;
        while (i < l.text.len and l.text[i] != '>' and l.text[i] != '\n') i += 1;
        if (i >= l.text.len or l.text[i] != '>') return null;
        l.pos = @intCast(i + 1);
        return .{ .kind = .string, .flags = .{ .space = trivia.space }, .text = l.text[start..l.pos], .loc = .{ .file = l.file, .offset = start } };
    }

    /// Skip the rest of the current line (used for skipped conditional
    /// blocks and after directives). Works token by token so that `/*` or
    /// `//` inside string literals is not mistaken for a comment.
    pub fn skipLine(l: *Lexer) void {
        // At the start of a line, its first token is part of this line.
        var line_start = l.at_bol;
        while (true) {
            const saved = l.*;
            const t = l.next();
            if (t.kind == .eof or (t.flags.bol and !line_start)) {
                l.* = saved;
                return;
            }
            line_start = false;
        }
    }

    fn lexToken(l: *Lexer) Kind {
        if (l.pos >= l.text.len) return .eof;
        const c = l.text[l.pos];
        l.pos += 1;
        switch (c) {
            'a'...'z', 'A'...'Z', '_' => {
                l.pos = @intCast(scan.skipIdent(l.text, l.pos));
                return .identifier;
            },
            '0'...'9' => {
                l.lexPpNumber();
                return .number;
            },
            '.' => {
                if (std.ascii.isDigit(l.peekAt(l.pos))) {
                    l.lexPpNumber();
                    return .number;
                }
                if (l.peekAt(l.pos) == '.' and l.peekAt(l.pos + 1) == '.') {
                    l.pos += 2;
                    return .ellipsis;
                }
                return .period;
            },
            '"' => return l.lexQuoted('"', .string),
            '\'' => return l.lexQuoted('\'', .char),
            '(' => return .l_paren,
            ')' => return .r_paren,
            '{' => return .l_brace,
            '}' => return .r_brace,
            '[' => return .l_square,
            ']' => return .r_square,
            ';' => return .semi,
            ',' => return .comma,
            '?' => return .question,
            '~' => return .tilde,
            ':' => return if (l.eat(':')) .colon_colon else .colon,
            '+' => return if (l.eat('+')) .plus_plus else if (l.eat('=')) .plus_equal else .plus,
            '-' => return if (l.eat('-')) .minus_minus else if (l.eat('=')) .minus_equal else if (l.eat('>')) .arrow else .minus,
            '*' => return if (l.eat('=')) .star_equal else .star,
            '/' => return if (l.eat('=')) .slash_equal else .slash,
            '%' => return if (l.eat('=')) .percent_equal else .percent,
            '&' => return if (l.eat('&')) .amp_amp else if (l.eat('=')) .amp_equal else .amp,
            '|' => return if (l.eat('|')) .pipe_pipe else if (l.eat('=')) .pipe_equal else .pipe,
            '^' => return if (l.eat('=')) .caret_equal else .caret,
            '!' => return if (l.eat('=')) .exclaim_equal else .exclaim,
            '=' => return if (l.eat('=')) .equal_equal else .equal,
            '#' => return if (l.eat('#')) .hash_hash else .hash,
            '<' => {
                if (l.eat('<')) return if (l.eat('=')) .less_less_equal else .less_less;
                return if (l.eat('=')) .less_equal else .less;
            },
            '>' => {
                if (l.eat('>')) return if (l.eat('=')) .greater_greater_equal else .greater_greater;
                return if (l.eat('=')) .greater_equal else .greater;
            },
            else => return .invalid,
        }
    }

    fn eat(l: *Lexer, c: u8) bool {
        if (l.peekAt(l.pos) == c) {
            l.pos += 1;
            return true;
        }
        return false;
    }

    fn lexPpNumber(l: *Lexer) void {
        while (l.pos < l.text.len) {
            const c = l.text[l.pos];
            if ((c == '+' or c == '-') and l.pos > 0) {
                const p = l.text[l.pos - 1];
                if (p == 'e' or p == 'E' or p == 'p' or p == 'P') {
                    l.pos += 1;
                    continue;
                }
                break;
            }
            if (isIdentChar(c) or c == '.') {
                l.pos += 1;
                continue;
            }
            break;
        }
    }

    fn lexQuoted(l: *Lexer, quote: u8, kind: Kind) Kind {
        while (l.pos < l.text.len) {
            const c = l.text[l.pos];
            if (c == '\n') return .invalid;
            l.pos += 1;
            if (c == '\\' and l.pos < l.text.len) {
                l.pos += 1;
                continue;
            }
            if (c == quote) return kind;
        }
        return .invalid;
    }
};

pub fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn expectKinds(text: []const u8, kinds: []const Kind) !void {
    var l = Lexer.init(text, 0);
    for (kinds) |k| try std.testing.expectEqual(k, l.next().kind);
    try std.testing.expectEqual(Kind.eof, l.next().kind);
}

test "punctuators and literals" {
    try expectKinds("a+=b<<=c>>1.5e-3f", &.{ .identifier, .plus_equal, .identifier, .less_less_equal, .identifier, .greater_greater, .number });
    try expectKinds("x::y->z...", &.{ .identifier, .colon_colon, .identifier, .arrow, .identifier, .ellipsis });
    try expectKinds("\"a\\\"b\" 'c' .5h 0x1Fu", &.{ .string, .char, .number, .number });
    try expectKinds("# ## #x", &.{ .hash, .hash_hash, .hash, .identifier });
}

test "skipLine ignores comment markers inside strings" {
    var l = Lexer.init("x = \"/*\"; y\n#endif\n", 0);
    l.skipLine();
    const t = l.next();
    try std.testing.expect(t.kind == .hash and t.flags.bol);
}

test "comments, flags and lines" {
    var l = Lexer.init("a /* x\n y */ b // c\n  c", 0);
    const a = l.next();
    try std.testing.expect(a.flags.bol);
    const b = l.next();
    try std.testing.expect(!b.flags.bol and b.flags.space);
    const c = l.next();
    try std.testing.expect(c.flags.bol);
    try std.testing.expectEqualStrings("c", c.text);
}
