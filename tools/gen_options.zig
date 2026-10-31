//! Build-time generator: reads dxc's option definitions
//! (vendor/dxc/HLSLOptions.td, LLVM OptParser tablegen syntax) and writes a
//! Zig table used by the dxc-compatible command-line parser.
//!
//! Usage: gen_options <HLSLOptions.td> <out.zig>
//!
//! Only the subset of tablegen used by that file is understood:
//!   def NAME : Kind<[prefixes], "spelling"[, N]>, Attr<...>, ...;
//! with Group<>, Flags<[...]>, HelpText<"">, MetaVarName<"">, Alias<>.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Def = struct {
    name: []const u8,
    kind: []const u8,
    prefixes: std.ArrayList([]const u8) = .empty,
    spelling: []const u8 = "",
    count: u32 = 0,
    group: []const u8 = "",
    help: []const u8 = "",
    meta: []const u8 = "",
    alias: []const u8 = "",
    hidden: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) return error.Usage;
    const text = try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(1 << 20));

    var p: Parser = .{ .text = text, .a = arena };
    var defs: std.ArrayList(Def) = .empty;
    while (try p.nextDef()) |d| try defs.append(arena, d);

    var out: std.Io.Writer.Allocating = .init(arena);
    try emit(&out.writer, defs.items);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = out.written() });
}

const Parser = struct {
    text: []const u8,
    a: Allocator,
    pos: usize = 0,

    fn skipSpace(p: *Parser) void {
        while (p.pos < p.text.len) {
            const c = p.text[p.pos];
            if (std.ascii.isWhitespace(c)) {
                p.pos += 1;
            } else if (std.mem.startsWith(u8, p.text[p.pos..], "//")) {
                while (p.pos < p.text.len and p.text[p.pos] != '\n') p.pos += 1;
            } else if (std.mem.startsWith(u8, p.text[p.pos..], "/*")) {
                const end = std.mem.indexOfPos(u8, p.text, p.pos + 2, "*/") orelse p.text.len - 2;
                p.pos = end + 2;
            } else break;
        }
    }

    fn ident(p: *Parser) []const u8 {
        p.skipSpace();
        const start = p.pos;
        while (p.pos < p.text.len and (std.ascii.isAlphanumeric(p.text[p.pos]) or p.text[p.pos] == '_')) p.pos += 1;
        return p.text[start..p.pos];
    }

    fn expect(p: *Parser, c: u8) !void {
        p.skipSpace();
        if (p.pos >= p.text.len or p.text[p.pos] != c) {
            std.debug.print("gen_options: expected '{c}' at offset {d}\n", .{ c, p.pos });
            return error.Syntax;
        }
        p.pos += 1;
    }

    fn peekIs(p: *Parser, c: u8) bool {
        p.skipSpace();
        return p.pos < p.text.len and p.text[p.pos] == c;
    }

    /// A double-quoted string with `\` escapes, returned unescaped.
    fn string(p: *Parser) ![]const u8 {
        try p.expect('"');
        var buf: std.ArrayList(u8) = .empty;
        while (p.pos < p.text.len and p.text[p.pos] != '"') {
            var c = p.text[p.pos];
            if (c == '\\' and p.pos + 1 < p.text.len) {
                p.pos += 1;
                c = switch (p.text[p.pos]) {
                    'n' => '\n',
                    't' => '\t',
                    else => p.text[p.pos],
                };
            }
            try buf.append(p.a, c);
            p.pos += 1;
        }
        try p.expect('"');
        return buf.items;
    }

    /// Skip a balanced `<...>` group we do not interpret.
    fn skipAngles(p: *Parser) !void {
        try p.expect('<');
        var depth: u32 = 1;
        while (p.pos < p.text.len and depth > 0) : (p.pos += 1) {
            switch (p.text[p.pos]) {
                '<' => depth += 1,
                '>' => depth -= 1,
                '"' => {
                    _ = try p.string();
                    p.pos -= 1;
                },
                else => {},
            }
        }
    }

    fn nextDef(p: *Parser) !?Def {
        while (true) {
            p.skipSpace();
            if (p.pos >= p.text.len) return null;
            const word = p.ident();
            if (word.len == 0) {
                p.pos += 1;
                continue;
            }
            if (std.mem.eql(u8, word, "include")) {
                _ = try p.string();
                continue;
            }
            if (!std.mem.eql(u8, word, "def")) continue;
            var d: Def = .{ .name = p.ident(), .kind = "" };
            try p.expect(':');
            d.kind = p.ident();
            if (p.peekIs('<')) try p.kindArgs(&d);
            while (p.peekIs(',')) {
                p.pos += 1;
                const attr = p.ident();
                try p.attribute(&d, attr);
            }
            try p.expect(';');
            return d;
        }
    }

    fn kindArgs(p: *Parser, d: *Def) !void {
        try p.expect('<');
        if (std.mem.eql(u8, d.kind, "OptionGroup")) {
            d.spelling = try p.string();
            try p.expect('>');
            return;
        }
        try p.expect('[');
        while (!p.peekIs(']')) {
            try d.prefixes.append(p.a, try p.string());
            if (p.peekIs(',')) p.pos += 1;
        }
        try p.expect(']');
        try p.expect(',');
        d.spelling = try p.string();
        if (p.peekIs(',')) {
            p.pos += 1;
            p.skipSpace();
            const start = p.pos;
            while (p.pos < p.text.len and std.ascii.isDigit(p.text[p.pos])) p.pos += 1;
            d.count = try std.fmt.parseInt(u32, p.text[start..p.pos], 10);
        }
        try p.expect('>');
    }

    fn attribute(p: *Parser, d: *Def, attr: []const u8) !void {
        if (std.mem.eql(u8, attr, "HelpText")) {
            try p.expect('<');
            d.help = try p.string();
            try p.expect('>');
        } else if (std.mem.eql(u8, attr, "MetaVarName")) {
            try p.expect('<');
            d.meta = try p.string();
            try p.expect('>');
        } else if (std.mem.eql(u8, attr, "Group")) {
            try p.expect('<');
            d.group = p.ident();
            try p.expect('>');
        } else if (std.mem.eql(u8, attr, "Alias")) {
            try p.expect('<');
            d.alias = p.ident();
            try p.expect('>');
        } else if (std.mem.eql(u8, attr, "Flags")) {
            const start = p.pos;
            try p.skipAngles();
            d.hidden = std.mem.indexOf(u8, p.text[start..p.pos], "HelpHidden") != null;
        } else {
            try p.skipAngles();
        }
    }
};

fn kindTag(kind: []const u8) ?[]const u8 {
    const map = [_][2][]const u8{
        .{ "Flag", "flag" },
        .{ "Joined", "joined" },
        .{ "JoinedOrSeparate", "joined_or_separate" },
        .{ "Separate", "separate" },
        .{ "MultiArg", "multi_arg" },
        .{ "CommaJoined", "comma_joined" },
    };
    for (map) |m| if (std.mem.eql(u8, m[0], kind)) return m[1];
    return null;
}

fn emit(w: *std.Io.Writer, defs: []const Def) !void {
    try w.writeAll(
        \\//! Generated by tools/gen_options.zig from vendor/dxc/HLSLOptions.td.
        \\//! Do not edit.
        \\
        \\pub const Kind = enum { flag, joined, joined_or_separate, separate, multi_arg, comma_joined };
        \\
        \\pub const Group = struct { name: []const u8, title: []const u8, help: []const u8 };
        \\
        \\pub const Option = struct {
        \\    /// Name of the tablegen def (dxc's OPT_<id>).
        \\    id: Id,
        \\    kind: Kind,
        \\    spelling: []const u8,
        \\    dash: bool,
        \\    slash: bool,
        \\    dash_dash: bool,
        \\    /// Number of following arguments for multi_arg options.
        \\    count: u8,
        \\    group: []const u8,
        \\    help: []const u8,
        \\    meta: []const u8,
        \\    hidden: bool,
        \\    alias: ?Id,
        \\};
        \\
        \\pub const groups = [_]Group{
        \\
    );
    for (defs) |d| {
        if (!std.mem.eql(u8, d.kind, "OptionGroup")) continue;
        try w.print("    .{{ .name = \"{s}\", .title = \"{f}\", .help = \"{f}\" }},\n", .{ d.name, std.zig.fmtString(d.spelling), std.zig.fmtString(d.help) });
    }
    try w.writeAll("};\n\npub const Id = enum {\n");
    for (defs) |d| {
        if (kindTag(d.kind) == null) continue;
        try w.print("    {f},\n", .{std.zig.fmtId(d.name)});
    }
    try w.writeAll("};\n\npub const options = [_]Option{\n");
    for (defs) |d| {
        const tag = kindTag(d.kind) orelse continue;
        var dash = false;
        var slash = false;
        var dash_dash = false;
        for (d.prefixes.items) |pre| {
            if (std.mem.eql(u8, pre, "-")) dash = true;
            if (std.mem.eql(u8, pre, "/")) slash = true;
            if (std.mem.eql(u8, pre, "--")) dash_dash = true;
        }
        try w.print("    .{{ .id = .{f}, .kind = .{s}, .spelling = \"{f}\", .dash = {}, .slash = {}, .dash_dash = {}, .count = {d}, .group = \"{s}\", .help = \"{f}\", .meta = \"{f}\", .hidden = {}, .alias = ", .{
            std.zig.fmtId(d.name), tag, std.zig.fmtString(d.spelling), dash, slash, dash_dash, d.count, d.group, std.zig.fmtString(d.help), std.zig.fmtString(d.meta), d.hidden,
        });
        if (d.alias.len > 0) try w.print(".{f}", .{std.zig.fmtId(d.alias)}) else try w.writeAll("null");
        try w.writeAll(" },\n");
    }
    try w.writeAll("};\n");
}
