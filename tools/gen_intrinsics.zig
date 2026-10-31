//! Build-time generator: reads dxc's intrinsic declarations
//! (vendor/dxc/gen_intrin_main.txt) and writes a Zig table that Sema uses
//! for intrinsic and builtin-method overload resolution.
//!
//! Usage: gen_intrinsics <gen_intrin_main.txt> <out.zig>
//!
//! Declaration syntax (see the header of gen_intrin_main.txt):
//!   <type> [[attrs]] <name>(<qual> <type> <name>, ...) [: <op>];
//! grouped into `namespace X { ... } namespace` blocks.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Spec = struct {
    qual: []const u8 = "in",
    match_layout: i32 = std.math.minInt(i32),
    match_comp: i32 = std.math.minInt(i32),
    special: []const u8 = "none",
    type_n: u32 = 0,
    base: []const u8 = "",
    any_layout: bool = false,
    dims: std.ArrayList([]const u8) = .empty,
    name: []const u8 = "",
};

const Decl = struct {
    ns: []const u8,
    name: []const u8,
    ret: Spec,
    params: std.ArrayList(Spec) = .empty,
    varargs: bool = false,
    attrs: []const u8,
    op: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) return error.Usage;
    const text = try std.Io.Dir.cwd().readFileAlloc(io, args[1], a, .limited(1 << 20));

    var decls: std.ArrayList(Decl) = .empty;
    var ns: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    var lineno: usize = 0;
    while (lines.next()) |raw| {
        lineno += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "//") or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "namespace ")) {
            ns = std.mem.trim(u8, line["namespace ".len..], " {");
            continue;
        }
        if (line[0] == '}') continue;
        const d = parseDecl(a, ns, line) catch |e| {
            std.debug.print("gen_intrinsics: line {d}: {s}: {s}\n", .{ lineno, @errorName(e), line });
            return e;
        };
        try decls.append(a, d);
    }

    var out: std.Io.Writer.Allocating = .init(a);
    try emit(&out.writer, decls.items);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = out.written() });
}

fn parseDecl(a: Allocator, ns: []const u8, line_in: []const u8) !Decl {
    var line = std.mem.trimEnd(u8, line_in, ";");
    // Optional `: op` after the closing parenthesis.
    var op: []const u8 = "";
    const close = std.mem.lastIndexOfScalar(u8, line, ')') orelse return error.NoParen;
    if (std.mem.indexOfScalarPos(u8, line, close, ':')) |colon| {
        op = std.mem.trim(u8, line[colon + 1 ..], " ");
        line = line[0..colon];
    }
    const open_attr = std.mem.indexOf(u8, line, "[[") orelse return error.NoAttrs;
    const close_attr = std.mem.indexOfPos(u8, line, open_attr, "]]") orelse return error.NoAttrs;
    const ret_text = std.mem.trim(u8, line[0..open_attr], " ");
    const attrs = line[open_attr + 2 .. close_attr];
    const rest = std.mem.trim(u8, line[close_attr + 2 ..], " ");
    const lp = std.mem.indexOfScalar(u8, rest, '(') orelse return error.NoParen;
    const rp = std.mem.lastIndexOfScalar(u8, rest, ')') orelse return error.NoParen;
    var d: Decl = .{
        .ns = ns,
        .name = std.mem.trim(u8, rest[0..lp], " "),
        .ret = try parseSpec(a, ret_text, false),
        .attrs = attrs,
        .op = op,
    };
    const params_text = std.mem.trim(u8, rest[lp + 1 .. rp], " ");
    if (params_text.len > 0) {
        var depth: u32 = 0;
        var start: usize = 0;
        for (params_text, 0..) |c, i| {
            if (c == '<') depth += 1;
            if (c == '>') depth -= 1;
            if ((c == ',' and depth == 0) or i == params_text.len - 1) {
                const end = if (c == ',' and depth == 0) i else i + 1;
                const p = std.mem.trim(u8, params_text[start..end], " ");
                start = i + 1;
                if (std.mem.eql(u8, p, "...")) {
                    d.varargs = true;
                    continue;
                }
                try d.params.append(a, try parseSpec(a, p, true));
            }
        }
    }
    return d;
}

/// `[qual...] type [name]`, where type is `$classT`, `$funcT`, `$typeN`,
/// or `[$match<X, Y>] base[<dims>]`.
fn parseSpec(a: Allocator, text: []const u8, is_param: bool) !Spec {
    var s: Spec = .{};
    var t = text;
    // Qualifiers.
    while (true) {
        t = std.mem.trimStart(u8, t, " ");
        const quals = [_][]const u8{ "inout ", "in ", "out ", "ref ", "row_major ", "col_major " };
        var matched = false;
        for (quals) |q| {
            if (std.mem.startsWith(u8, t, q)) {
                const word = q[0 .. q.len - 1];
                if (!std.mem.eql(u8, word, "row_major") and !std.mem.eql(u8, word, "col_major")) s.qual = word;
                t = t[q.len..];
                matched = true;
            }
        }
        if (!matched) break;
    }
    if (std.mem.startsWith(u8, t, "$match<")) {
        const end = std.mem.indexOfScalar(u8, t, '>') orelse return error.BadMatch;
        var it = std.mem.splitScalar(u8, t["$match<".len..end], ',');
        s.match_layout = try std.fmt.parseInt(i32, std.mem.trim(u8, it.next().?, " "), 10);
        s.match_comp = try std.fmt.parseInt(i32, std.mem.trim(u8, it.next() orelse return error.BadMatch, " "), 10);
        t = std.mem.trimStart(u8, t[end + 1 ..], " ");
    }
    if (std.mem.startsWith(u8, t, "$classT")) {
        s.special = "class_t";
        t = t["$classT".len..];
    } else if (std.mem.startsWith(u8, t, "$funcT")) {
        s.special = "func_t";
        t = t["$funcT".len..];
    } else if (std.mem.startsWith(u8, t, "$type")) {
        var i: usize = "$type".len;
        while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
        s.special = "type_n";
        s.type_n = try std.fmt.parseInt(u32, t["$type".len..i], 10);
        t = t[i..];
    } else {
        var i: usize = 0;
        while (i < t.len and (std.ascii.isAlphanumeric(t[i]) or t[i] == '_')) i += 1;
        s.base = t[0..i];
        t = t[i..];
        if (t.len > 0 and t[0] == '<') {
            const end = std.mem.indexOfScalar(u8, t, '>') orelse return error.BadLayout;
            const inner = std.mem.trim(u8, t[1..end], " ");
            if (inner.len == 0) {
                s.any_layout = true;
            } else {
                var it = std.mem.splitScalar(u8, inner, ',');
                while (it.next()) |dim| try s.dims.append(a, std.mem.trim(u8, dim, " "));
            }
            t = t[end + 1 ..];
        }
    }
    if (is_param) s.name = std.mem.trim(u8, t, " ");
    return s;
}

fn emitSpec(w: *std.Io.Writer, s: Spec) !void {
    try w.print(".{{ .qual = .{s}, .special = .{s}, .type_n = {d}, .base = \"{s}\", .any_layout = {}, .dims = &.{{", .{ if (std.mem.eql(u8, s.qual, "inout")) "inout" else if (std.mem.eql(u8, s.qual, "out")) "out" else if (std.mem.eql(u8, s.qual, "ref")) "ref" else "in", s.special, s.type_n, s.base, s.any_layout });
    for (s.dims.items, 0..) |d, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("\"{s}\"", .{d});
    }
    try w.writeAll("}, .match_layout = ");
    if (s.match_layout == std.math.minInt(i32)) try w.writeAll("null") else try w.print("{d}", .{s.match_layout});
    try w.writeAll(", .match_comp = ");
    if (s.match_comp == std.math.minInt(i32)) try w.writeAll("null") else try w.print("{d}", .{s.match_comp});
    try w.print(", .name = \"{s}\" }}", .{s.name});
}

fn emit(w: *std.Io.Writer, decls: []const Decl) !void {
    try w.writeAll(
        \\//! Generated by tools/gen_intrinsics.zig from vendor/dxc/gen_intrin_main.txt.
        \\//! Do not edit.
        \\
        \\pub const Qual = enum { in, out, inout, ref };
        \\pub const Special = enum { none, class_t, func_t, type_n };
        \\
        \\pub const Spec = struct {
        \\    qual: Qual,
        \\    special: Special,
        \\    type_n: u32,
        \\    /// Component class: `float_like`, `numeric`, `uint`, `sampler`, ...
        \\    base: []const u8,
        \\    /// `<>`: any scalar / vector / matrix layout.
        \\    any_layout: bool,
        \\    /// Layout dimensions: none (scalar), `{"4"}`, `{"c"}`, `{"r", "c"}` ...
        \\    dims: []const []const u8,
        \\    match_layout: ?i32,
        \\    match_comp: ?i32,
        \\    name: []const u8,
        \\};
        \\
        \\pub const Intrinsic = struct {
        \\    namespace: []const u8,
        \\    name: []const u8,
        \\    ret: Spec,
        \\    params: []const Spec,
        \\    varargs: bool,
        \\    attrs: []const u8,
        \\    op: []const u8,
        \\};
        \\
        \\pub const intrinsics = [_]Intrinsic{
        \\
    );
    for (decls) |d| {
        try w.print("    .{{ .namespace = \"{s}\", .name = \"{s}\", .ret = ", .{ d.ns, d.name });
        try emitSpec(w, d.ret);
        try w.writeAll(", .params = &.{");
        for (d.params.items, 0..) |p, i| {
            if (i > 0) try w.writeAll(", ");
            try emitSpec(w, p);
        }
        try w.print("}}, .varargs = {}, .attrs = \"{s}\", .op = \"{s}\" }},\n", .{ d.varargs, d.attrs, d.op });
    }
    try w.writeAll("};\n");
}
