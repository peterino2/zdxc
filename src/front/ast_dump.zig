//! Compact S-expression dump of the AST, for tests and debugging.

const std = @import("std");
const ast = @import("ast.zig");
const W = std.Io.Writer;

pub fn dumpUnit(w: *W, tu: ast.TranslationUnit) W.Error!void {
    for (tu.decls) |d| {
        try decl(w, d, 0);
        try w.writeByte('\n');
    }
}

fn indent(w: *W, n: usize) W.Error!void {
    try w.splatByteAll(' ', n * 2);
}

fn name(w: *W, n: ast.Name) W.Error!void {
    for (n.parts, 0..) |part, i| {
        if (i > 0) try w.writeAll("::");
        try w.writeAll(part);
        if (n.args.len > 0 and n.args[i].len > 0) try templateArgs(w, n.args[i]);
    }
}

fn templateArgs(w: *W, args: []const ast.TemplateArg) W.Error!void {
    try w.writeByte('<');
    for (args, 0..) |a, i| {
        if (i > 0) try w.writeAll(", ");
        switch (a) {
            .type => |ty| try typeRef(w, ty),
            .expr => |e| try expr(w, e),
        }
    }
    try w.writeByte('>');
}

pub fn typeRef(w: *W, t: *const ast.TypeRef) W.Error!void {
    if (t.norm != .none) try w.print("{s} ", .{@tagName(t.norm)});
    try name(w, t.name);
    if (t.args.len > 0) try templateArgs(w, t.args);
    try dims(w, t.array_dims);
}

fn quals(w: *W, q: ast.Qualifiers) W.Error!void {
    const info = @typeInfo(ast.Qualifiers).@"struct";
    inline for (info.field_names, info.field_types) |fname, ftype| {
        if (ftype == bool and @field(q, fname)) try w.print("{s} ", .{fname});
    }
}

fn attrs(w: *W, list: []const ast.Attribute) W.Error!void {
    for (list) |a| {
        try w.print("[{s}", .{a.name});
        if (a.args.len > 0) {
            try w.writeByte('(');
            for (a.args, 0..) |e, i| {
                if (i > 0) try w.writeAll(", ");
                try expr(w, e);
            }
            try w.writeByte(')');
        }
        try w.writeAll("] ");
    }
}

fn semantics(w: *W, list: []const ast.Semantic) W.Error!void {
    for (list) |s| {
        switch (s.kind) {
            .semantic => try w.print(" : {s}", .{s.values[0]}),
            .register, .packoffset, .access => {
                try w.print(" : {s}(", .{@tagName(s.kind)});
                for (s.values, 0..) |v, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.writeAll(v);
                }
                try w.writeByte(')');
            },
        }
    }
}

fn dims(w: *W, list: []const ?*ast.Expr) W.Error!void {
    for (list) |d| {
        try w.writeByte('[');
        if (d) |e| try expr(w, e);
        try w.writeByte(']');
    }
}

fn varDecl(w: *W, v: ast.VarDecl) W.Error!void {
    try templateParams(w, v.template_params);
    try attrs(w, v.attrs);
    try quals(w, v.quals);
    try typeRef(w, v.type);
    try w.print(" {s}", .{v.name});
    try dims(w, v.array_dims);
    if (v.bitfield) |b| {
        try w.writeAll(" : ");
        try expr(w, b);
    }
    try semantics(w, v.semantics);
    if (v.init) |e| {
        try w.writeAll(" = ");
        try expr(w, e);
    }
}

fn templateParams(w: *W, params: []const ast.TemplateParam) W.Error!void {
    if (params.len == 0) return;
    try w.writeAll("template<");
    for (params, 0..) |tp, i| {
        if (i > 0) try w.writeAll(", ");
        if (tp.value_type) |vt| {
            try typeRef(w, vt);
            try w.print(" {s}", .{tp.name});
        } else try w.print("typename {s}", .{tp.name});
    }
    try w.writeAll("> ");
}

pub fn decl(w: *W, d: *const ast.Decl, depth: usize) W.Error!void {
    try indent(w, depth);
    switch (d.kind) {
        .@"var" => |v| {
            try w.writeAll("(var ");
            try varDecl(w, v);
            try w.writeByte(')');
        },
        .func => |f| {
            try w.writeAll("(func ");
            try templateParams(w, f.template_params);
            try attrs(w, f.attrs);
            try quals(w, f.quals);
            try typeRef(w, f.ret);
            try w.writeByte(' ');
            try name(w, f.name);
            try w.writeByte('(');
            for (f.params, 0..) |prm, i| {
                if (i > 0) try w.writeAll(", ");
                try varDecl(w, prm);
            }
            try w.writeByte(')');
            try dims(w, f.ret_dims);
            if (f.is_const) try w.writeAll(" const");
            try semantics(w, f.ret_semantics);
            if (f.body) |b| {
                try w.writeByte('\n');
                try stmt(w, b, depth + 1);
            }
            try w.writeByte(')');
        },
        .@"struct" => |s| {
            try w.print("({s} ", .{@tagName(s.keyword)});
            try templateParams(w, s.template_params);
            try attrs(w, s.attrs);
            try w.writeAll(s.name orelse "<anon>");
            if (s.specialization_args.len > 0) try templateArgs(w, s.specialization_args);
            for (s.bases) |b| {
                try w.writeAll(" : ");
                try typeRef(w, b);
            }
            if (s.members) |members| {
                for (members) |m| {
                    try w.writeByte('\n');
                    try decl(w, m, depth + 1);
                }
            } else try w.writeAll(" <fwd>");
            try w.writeByte(')');
        },
        .cbuffer => |c| {
            try w.print("({s} {s}", .{ if (c.tbuffer) "tbuffer" else "cbuffer", c.name });
            try semantics(w, c.semantics);
            for (c.members) |m| {
                try w.writeByte('\n');
                try decl(w, m, depth + 1);
            }
            try w.writeByte(')');
        },
        .typedef => |t| {
            try w.writeAll("(typedef ");
            try templateParams(w, t.template_params);
            try typeRef(w, t.type);
            try w.print(" {s}", .{t.name});
            try dims(w, t.array_dims);
            try w.writeByte(')');
        },
        .@"enum" => |e| {
            try w.print("(enum{s} {s}", .{ if (e.scoped) " class" else "", e.name orelse "<anon>" });
            for (e.values) |v| {
                try w.print(" {s}", .{v.name});
                if (v.value) |x| {
                    try w.writeByte('=');
                    try expr(w, x);
                }
            }
            try w.writeByte(')');
        },
        .namespace => |n| {
            try w.print("(namespace {s}", .{n.name});
            for (n.decls) |m| {
                try w.writeByte('\n');
                try decl(w, m, depth + 1);
            }
            try w.writeByte(')');
        },
        .using_namespace => |n| {
            try w.writeAll("(using namespace ");
            try name(w, n);
            try w.writeByte(')');
        },
        .using_decl => |n| {
            try w.writeAll("(using ");
            try name(w, n);
            try w.writeByte(')');
        },
        .pragma => |p| try w.print("(pragma {s})", .{p}),
        .static_assert => |s| {
            try w.writeAll("(static_assert ");
            try expr(w, s.cond);
            try w.writeByte(')');
        },
    }
}

pub fn stmt(w: *W, s: *const ast.Stmt, depth: usize) W.Error!void {
    try indent(w, depth);
    try attrs(w, s.attrs);
    switch (s.kind) {
        .compound => |list| {
            try w.writeAll("{");
            for (list) |c| {
                try w.writeByte('\n');
                try stmt(w, c, depth + 1);
            }
            try w.writeAll("}");
        },
        .decl => |list| {
            for (list, 0..) |d, i| {
                if (i > 0) try w.writeByte('\n');
                try decl(w, d, if (i == 0) 0 else depth);
            }
        },
        .expr => |e| try expr(w, e),
        .empty => try w.writeAll("(empty)"),
        .@"if" => |x| {
            try w.writeAll("(if ");
            if (x.cond_decl) |d| {
                try decl(w, d, 0);
                try w.writeByte(' ');
            }
            try expr(w, x.cond);
            try w.writeByte('\n');
            try stmt(w, x.then, depth + 1);
            if (x.@"else") |e| {
                try w.writeByte('\n');
                try stmt(w, e, depth + 1);
            }
            try w.writeByte(')');
        },
        .@"for" => |x| {
            try w.writeAll("(for ");
            if (x.init) |i| try stmt(w, i, 0) else try w.writeAll("-");
            try w.writeAll("; ");
            if (x.cond) |c| try expr(w, c) else try w.writeAll("-");
            try w.writeAll("; ");
            if (x.inc) |c| try expr(w, c) else try w.writeAll("-");
            try w.writeByte('\n');
            try stmt(w, x.body, depth + 1);
            try w.writeByte(')');
        },
        .@"while" => |x| {
            try w.writeAll("(while ");
            try expr(w, x.cond);
            try w.writeByte('\n');
            try stmt(w, x.body, depth + 1);
            try w.writeByte(')');
        },
        .do_while => |x| {
            try w.writeAll("(do\n");
            try stmt(w, x.body, depth + 1);
            try w.writeAll(" while ");
            try expr(w, x.cond);
            try w.writeByte(')');
        },
        .@"switch" => |x| {
            try w.writeAll("(switch ");
            try expr(w, x.cond);
            try w.writeByte('\n');
            try stmt(w, x.body, depth + 1);
            try w.writeByte(')');
        },
        .case => |x| {
            try w.writeAll("(case ");
            try expr(w, x.value);
            try w.writeByte('\n');
            try stmt(w, x.stmt, depth + 1);
            try w.writeByte(')');
        },
        .default => |x| {
            try w.writeAll("(default\n");
            try stmt(w, x, depth + 1);
            try w.writeByte(')');
        },
        .@"break" => try w.writeAll("(break)"),
        .@"continue" => try w.writeAll("(continue)"),
        .discard => try w.writeAll("(discard)"),
        .@"return" => |v| {
            try w.writeAll("(return");
            if (v) |e| {
                try w.writeByte(' ');
                try expr(w, e);
            }
            try w.writeByte(')');
        },
    }
}

pub fn expr(w: *W, e: *const ast.Expr) W.Error!void {
    switch (e.kind) {
        .int_lit, .float_lit, .string_lit => |t| try w.writeAll(t),
        .bool_lit => |b| try w.writeAll(if (b) "true" else "false"),
        .name => |n| try name(w, n),
        .this => try w.writeAll("this"),
        .unary => |u| {
            try w.print("({s} ", .{@tagName(u.op)});
            try expr(w, u.operand);
            try w.writeByte(')');
        },
        .binary => |b| {
            try w.print("({s} ", .{@tagName(b.op)});
            try expr(w, b.lhs);
            try w.writeByte(' ');
            try expr(w, b.rhs);
            try w.writeByte(')');
        },
        .assign => |a| {
            try w.print("({s}= ", .{if (a.op == .assign) "" else @tagName(a.op)});
            try expr(w, a.lhs);
            try w.writeByte(' ');
            try expr(w, a.rhs);
            try w.writeByte(')');
        },
        .conditional => |c| {
            try w.writeAll("(? ");
            try expr(w, c.cond);
            try w.writeByte(' ');
            try expr(w, c.then);
            try w.writeByte(' ');
            try expr(w, c.@"else");
            try w.writeByte(')');
        },
        .call => |c| {
            try w.writeAll("(call ");
            try expr(w, c.callee);
            if (c.template_args.len > 0) {
                const tmp: ast.TypeRef = .{ .loc = e.loc, .name = .{ .loc = e.loc, .parts = &.{""} }, .args = c.template_args };
                try typeRef(w, &tmp);
            }
            for (c.args) |a| {
                try w.writeByte(' ');
                try expr(w, a);
            }
            try w.writeByte(')');
        },
        .construct => |c| {
            try w.writeAll("(construct ");
            try typeRef(w, c.type);
            for (c.args) |a| {
                try w.writeByte(' ');
                try expr(w, a);
            }
            try w.writeByte(')');
        },
        .cast => |c| {
            try w.writeAll("(cast ");
            try typeRef(w, c.type);
            try dims(w, c.array_dims);
            try w.writeByte(' ');
            try expr(w, c.operand);
            try w.writeByte(')');
        },
        .member => |m| {
            try w.writeAll("(. ");
            try expr(w, m.base);
            try w.print(" {s})", .{m.name});
        },
        .index => |x| {
            try w.writeAll("([] ");
            try expr(w, x.base);
            try w.writeByte(' ');
            try expr(w, x.index);
            try w.writeByte(')');
        },
        .init_list => |list| {
            try w.writeByte('{');
            for (list, 0..) |a, i| {
                if (i > 0) try w.writeAll(", ");
                try expr(w, a);
            }
            try w.writeByte('}');
        },
        .sizeof_type => |t| {
            try w.writeAll("(sizeof ");
            try typeRef(w, t);
            try w.writeByte(')');
        },
        .sizeof_expr => |x| {
            try w.writeAll("(sizeof ");
            try expr(w, x);
            try w.writeByte(')');
        },
    }
}
