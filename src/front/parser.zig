//! Recursive-descent parser for HLSL 2021, producing `ast` nodes.
//!
//! Like C/C++, HLSL needs to know which identifiers name types to tell
//! declarations from expressions (`T x;` vs `f(x);`, `(T)x` vs `(a)+b`) and
//! template argument lists from comparisons (`f<T>(x)` vs `a < b`). The
//! parser keeps a scoped table of user type and template names for this;
//! builtin types are recognized by name.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const source = @import("source.zig");
const Diagnostics = @import("../diag.zig").Diagnostics;
const Preprocessor = @import("preproc.zig").Preprocessor;
const Token = lexer.Token;
const Kind = lexer.Kind;
const Loc = source.Loc;

pub const Error = Allocator.Error || error{Syntax};

const NameKind = enum { type, template_type, template_func, value };

pub const Parser = struct {
    arena: Allocator,
    diags: *Diagnostics,
    toks: []Token,
    pos: usize = 0,
    /// name -> kind, innermost declaration wins.
    names: std.StringHashMapUnmanaged(std.ArrayList(NameKind)) = .empty,
    /// Names declared in each open scope, to undo on exit.
    scopes: std.ArrayList(std.ArrayList([]const u8)) = .empty,
    anon_count: u32 = 0,
    /// Name of the struct most recently parsed by parseStructDeclInto
    /// (synthesized for anonymous structs), for `typedef struct ...`.
    last_struct_name: []const u8 = "",
    /// Set while parsing template arguments: a top-level `>` ends the
    /// argument instead of being a comparison.
    no_greater: bool = false,

    /// Collect every token from `pp` and set up a parser over them.
    pub fn fromPreprocessor(arena: Allocator, diags: *Diagnostics, pp: *Preprocessor) !Parser {
        var toks: std.ArrayList(Token) = .empty;
        while (true) {
            const t = try pp.next();
            try toks.append(arena, t);
            if (t.kind == .eof) break;
        }
        return .{ .arena = arena, .diags = diags, .toks = toks.items };
    }

    pub fn parseTranslationUnit(p: *Parser) Allocator.Error!ast.TranslationUnit {
        try p.pushScope();
        var decls: std.ArrayList(*ast.Decl) = .empty;
        while (p.tok().kind != .eof) {
            const start = p.pos;
            p.parseDeclInto(&decls, .global) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Syntax => p.recover(start),
            };
        }
        return .{ .decls = decls.items };
    }

    // ------------------------------------------------------------------
    // Token helpers

    fn tok(p: *const Parser) Token {
        return p.toks[p.pos];
    }

    fn peek(p: *const Parser, n: usize) Token {
        const i = @min(p.pos + n, p.toks.len - 1);
        return p.toks[i];
    }

    fn advance(p: *Parser) Token {
        const t = p.toks[p.pos];
        if (t.kind != .eof) p.pos += 1;
        return t;
    }

    fn at(p: *const Parser, kind: Kind) bool {
        return p.tok().kind == kind;
    }

    fn atIdent(p: *const Parser, text: []const u8) bool {
        return p.tok().isIdent(text);
    }

    fn eat(p: *Parser, kind: Kind) bool {
        if (!p.at(kind)) return false;
        _ = p.advance();
        return true;
    }

    fn eatIdent(p: *Parser, text: []const u8) bool {
        if (!p.atIdent(text)) return false;
        _ = p.advance();
        return true;
    }

    fn fail(p: *Parser, comptime fmt: []const u8, args: anytype) error{Syntax} {
        p.diags.err(p.tok().loc, fmt, args);
        return error.Syntax;
    }

    fn expect(p: *Parser, kind: Kind, what: []const u8) Error!Token {
        if (p.at(kind)) return p.advance();
        return p.fail("expected {s}, found '{s}'", .{ what, describe(p.tok()) });
    }

    fn expectIdent(p: *Parser, what: []const u8) Error!Token {
        const t = p.tok();
        if (t.kind == .identifier and !isReserved(t.text)) return p.advance();
        return p.fail("expected {s}, found '{s}'", .{ what, describe(t) });
    }

    /// Consume a `>` closing a template argument list, splitting `>>`,
    /// `>=` and `>>=` as needed.
    fn expectCloseAngle(p: *Parser) Error!void {
        const t = p.tok();
        const rest: ?Kind = switch (t.kind) {
            .greater => null,
            .greater_greater => .greater,
            .greater_equal => .equal,
            .greater_greater_equal => .greater_equal,
            else => return p.fail("expected '>', found '{s}'", .{describe(t)}),
        };
        if (rest) |k| {
            p.toks[p.pos] = .{ .kind = k, .text = t.text[1..], .loc = .{ .file = t.loc.file, .offset = t.loc.offset + 1 } };
        } else _ = p.advance();
    }

    fn mk(p: *Parser, comptime T: type, value: T) Allocator.Error!*T {
        const ptr = try p.arena.create(T);
        ptr.* = value;
        return ptr;
    }

    fn mkExpr(p: *Parser, loc: Loc, kind: ast.Expr.Kind) Allocator.Error!*ast.Expr {
        return p.mk(ast.Expr, .{ .loc = loc, .kind = kind });
    }

    /// Error recovery: skip to the end of the current declaration or
    /// statement, keeping braces balanced. Always makes progress.
    fn recover(p: *Parser, start: usize) void {
        if (p.pos == start) _ = p.advance();
        var depth: u32 = 0;
        while (true) {
            const t = p.tok();
            switch (t.kind) {
                .eof => return,
                .l_brace => depth += 1,
                .r_brace => {
                    if (depth == 0) return;
                    depth -= 1;
                    if (depth == 0) {
                        _ = p.advance();
                        _ = p.eat(.semi);
                        return;
                    }
                },
                .semi => if (depth == 0) {
                    _ = p.advance();
                    return;
                },
                else => {},
            }
            _ = p.advance();
        }
    }

    // ------------------------------------------------------------------
    // Name table

    fn pushScope(p: *Parser) Allocator.Error!void {
        try p.scopes.append(p.arena, .empty);
    }

    fn popScope(p: *Parser) void {
        var scope = p.scopes.pop().?;
        for (scope.items) |name| {
            if (p.names.getPtr(name)) |list| _ = list.pop();
        }
        scope.deinit(p.arena);
    }

    fn declareName(p: *Parser, name: []const u8, kind: NameKind) Allocator.Error!void {
        const gop = try p.names.getOrPut(p.arena, name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(p.arena, kind);
        try p.scopes.items[p.scopes.items.len - 1].append(p.arena, name);
    }

    fn lookupName(p: *const Parser, name: []const u8) ?NameKind {
        const list = p.names.get(name) orelse return null;
        if (list.items.len == 0) return null;
        return list.items[list.items.len - 1];
    }

    fn isTypeName(p: *const Parser, name: []const u8) bool {
        if (p.lookupName(name)) |k| return k == .type or k == .template_type;
        return isBuiltinType(name);
    }

    fn isTemplateName(p: *const Parser, name: []const u8) bool {
        if (p.lookupName(name)) |k| {
            if (k == .template_type or k == .template_func) return true;
            if (k == .value) return false;
        }
        // Builtin templates keep working when a same-named user type exists
        // in some namespace (the name table is not namespace-aware).
        return isBuiltinTemplate(name);
    }

    /// End index of a type starting at `i` (syntactic scan, no
    /// allocation), or null if no type starts there.
    fn scanType(p: *const Parser, start: usize) ?usize {
        var i = start;
        if (p.toks[i].isIdent("unorm") or p.toks[i].isIdent("snorm")) i += 1;
        if (p.toks[i].isIdent("typename")) return p.scanDependentType(i + 1);
        if (p.toks[i].isIdent("unsigned") or p.toks[i].isIdent("signed")) {
            i += 1;
            if (p.toks[i].kind == .identifier and isBuiltinType(p.toks[i].text)) i += 1;
            return i;
        }
        if (p.toks[i].kind == .colon_colon) i += 1;
        while (true) {
            const t = p.toks[i];
            if (t.kind != .identifier or isReserved(t.text)) return null;
            i += 1;
            var after = i;
            if (p.toks[i].kind == .less and p.isTemplateName(t.text)) {
                after = p.skipAngles(i) orelse return null;
            }
            if (p.toks[after].kind == .colon_colon and p.toks[after + 1].kind == .identifier) {
                i = after + 1;
                continue;
            }
            if (!p.isTypeName(t.text)) return null;
            return p.skipTypeAttrs(after);
        }
    }

    /// After `typename`: any qualified name is a type.
    fn scanDependentType(p: *const Parser, start: usize) ?usize {
        var i = start;
        if (p.toks[i].kind == .colon_colon) i += 1;
        while (true) {
            const t = p.toks[i];
            if (t.kind != .identifier or isReserved(t.text)) return null;
            i += 1;
            if (p.toks[i].kind == .less and p.isTemplateName(t.text)) i = p.skipAngles(i) orelse return null;
            if (p.toks[i].kind == .colon_colon and p.toks[i + 1].kind == .identifier) {
                i += 1;
                continue;
            }
            return p.skipTypeAttrs(i);
        }
    }

    fn skipTypeAttrs(p: *const Parser, start: usize) usize {
        var i = start;
        if (!(p.toks[i].kind == .l_square and p.toks[i + 1].kind == .l_square)) return i;
        var depth: u32 = 0;
        while (true) : (i += 1) {
            switch (p.toks[i].kind) {
                .l_square => depth += 1,
                .r_square => {
                    depth -= 1;
                    if (depth == 0) return i + 1;
                },
                .eof => return start,
                else => {},
            }
        }
    }

    /// Index just past the `>` matching the `<` at `i`, or null.
    fn skipAngles(p: *const Parser, start: usize) ?usize {
        var i = start;
        var depth: u32 = 0;
        var parens: u32 = 0;
        while (true) : (i += 1) {
            switch (p.toks[i].kind) {
                .less => if (parens == 0) {
                    depth += 1;
                },
                .greater => if (parens == 0) {
                    depth -= 1;
                    if (depth == 0) return i + 1;
                },
                .greater_greater => if (parens == 0) {
                    if (depth <= 2) return i + 1;
                    depth -= 2;
                },
                .l_paren => parens += 1,
                .r_paren => {
                    if (parens == 0) return null;
                    parens -= 1;
                },
                .semi, .l_brace, .r_brace, .eof => return null,
                else => {},
            }
        }
    }

    fn isTypeStartAt(p: *const Parser, i: usize) bool {
        return p.scanType(i) != null;
    }

    // ------------------------------------------------------------------
    // Attributes, qualifiers, types

    fn parseAttributes(p: *Parser) Error![]const ast.Attribute {
        var attrs: std.ArrayList(ast.Attribute) = .empty;
        while (p.at(.l_square)) {
            const double = p.peek(1).kind == .l_square;
            _ = p.advance();
            if (double) _ = p.advance();
            while (true) {
                const start = p.tok();
                var name: std.ArrayList(u8) = .empty;
                try name.appendSlice(p.arena, (try p.expectAttrName()).text);
                while (p.eat(.colon_colon)) {
                    try name.appendSlice(p.arena, "::");
                    try name.appendSlice(p.arena, (try p.expectAttrName()).text);
                }
                var args: std.ArrayList(*ast.Expr) = .empty;
                if (p.eat(.l_paren)) {
                    if (!p.at(.r_paren)) {
                        while (true) {
                            try args.append(p.arena, try p.parseAssign());
                            if (!p.eat(.comma)) break;
                        }
                    }
                    _ = try p.expect(.r_paren, "')'");
                }
                try attrs.append(p.arena, .{ .loc = start.loc, .name = name.items, .args = args.items, .double_bracket = double });
                if (!p.eat(.comma)) break;
            }
            _ = try p.expect(.r_square, "']'");
            if (double) _ = try p.expect(.r_square, "']'");
        }
        return attrs.items;
    }

    fn expectAttrName(p: *Parser) Error!Token {
        if (p.at(.identifier)) return p.advance();
        return p.fail("expected attribute name, found '{s}'", .{describe(p.tok())});
    }

    /// Parse leading qualifiers. Contextual keywords (`point`, `sample`,
    /// `line`, ...) count only when a type or another qualifier follows.
    fn parseQualifiers(p: *Parser) ast.Qualifiers {
        var q: ast.Qualifiers = .{};
        while (p.at(.identifier)) {
            const word = p.tok().text;
            const field = qualifierField(word) orelse break;
            if (isContextualQualifier(word)) {
                const n = p.peek(1);
                const next_is_qual = n.kind == .identifier and qualifierField(n.text) != null;
                if (!next_is_qual and !p.isTypeStartAt(p.pos + 1)) break;
            }
            _ = p.advance();
            if (std.mem.eql(u8, word, "inout")) {
                q.in = true;
                q.out = true;
                continue;
            }
            const info = @typeInfo(ast.Qualifiers).@"struct";
            inline for (info.field_names, info.field_types) |fname, ftype| {
                if (ftype == bool and std.mem.eql(u8, fname, field)) @field(q, fname) = true;
            }
        }
        return q;
    }

    fn parseType(p: *Parser) Error!*ast.TypeRef {
        var norm: @FieldType(ast.TypeRef, "norm") = .none;
        if (p.eatIdent("unorm")) {
            norm = .unorm;
        } else if (p.eatIdent("snorm")) norm = .snorm;
        const t = try p.parseTypeInner();
        if (norm != .none) t.norm = norm;
        if (p.at(.l_square) and p.peek(1).kind == .l_square) t.attrs = try p.parseAttributes();
        return t;
    }

    fn parseTypeInner(p: *Parser) Error!*ast.TypeRef {
        const start = p.tok();
        if (p.eatIdent("typename")) {
            // Dependent name: `typename X<T>::type`.
            const n = try p.parseNameWithFinalArgs();
            return p.mk(ast.TypeRef, .{ .loc = start.loc, .name = n.name, .args = n.args });
        }
        if (p.atIdent("unsigned") or p.atIdent("signed")) {
            const signed = p.advance().isIdent("signed");
            var base: []const u8 = "int";
            if (p.at(.identifier) and isBuiltinType(p.tok().text)) base = p.advance().text;
            const name = if (signed) base else try unsignedName(p.arena, base);
            return p.mk(ast.TypeRef, .{ .loc = start.loc, .name = try p.simpleName(start.loc, name) });
        }
        const name = try p.parseName();
        if (!p.isTypeName(name.last())) {
            p.diags.err(start.loc, "unknown type name '{s}'", .{name.last()});
            return error.Syntax;
        }
        var args: []const ast.TemplateArg = &.{};
        if (p.at(.less) and p.isTemplateName(name.last())) args = try p.parseTemplateArgs();
        return p.mk(ast.TypeRef, .{ .loc = start.loc, .name = name, .args = args });
    }

    /// A qualified name whose final part may carry template arguments.
    fn parseNameWithFinalArgs(p: *Parser) Error!struct { name: ast.Name, args: []const ast.TemplateArg } {
        const name = try p.parseName();
        var args: []const ast.TemplateArg = &.{};
        if (p.at(.less) and p.isTemplateName(name.last())) args = try p.parseTemplateArgs();
        return .{ .name = name, .args = args };
    }

    fn simpleName(p: *Parser, loc: Loc, s: []const u8) Allocator.Error!ast.Name {
        const parts = try p.arena.alloc([]const u8, 1);
        parts[0] = s;
        return .{ .loc = loc, .parts = parts };
    }

    fn parseName(p: *Parser) Error!ast.Name {
        const loc = p.tok().loc;
        var parts: std.ArrayList([]const u8) = .empty;
        var args: std.ArrayList([]const ast.TemplateArg) = .empty;
        var any_args = false;
        if (p.eat(.colon_colon)) {
            try parts.append(p.arena, "");
            try args.append(p.arena, &.{});
        }
        while (true) {
            const id = try p.expectIdent("identifier");
            try parts.append(p.arena, id.text);
            var part_args: []const ast.TemplateArg = &.{};
            // `S<T>::member`: arguments followed by `::` belong to this part.
            if (p.at(.less) and p.isTemplateName(id.text)) {
                if (p.skipAngles(p.pos)) |end| {
                    if (p.toks[end].kind == .colon_colon and p.toks[end + 1].kind == .identifier) {
                        part_args = try p.parseTemplateArgs();
                        any_args = true;
                    }
                }
            }
            try args.append(p.arena, part_args);
            if (!(p.at(.colon_colon) and p.peek(1).kind == .identifier and !p.peek(1).isIdent("operator"))) break;
            _ = p.advance();
        }
        return .{ .loc = loc, .parts = parts.items, .args = if (any_args) args.items else &.{} };
    }

    fn parseTemplateArgs(p: *Parser) Error![]const ast.TemplateArg {
        _ = try p.expect(.less, "'<'");
        var args: std.ArrayList(ast.TemplateArg) = .empty;
        const saved = p.no_greater;
        p.no_greater = true;
        defer p.no_greater = saved;
        if (p.at(.greater)) {
            _ = p.advance();
            return args.items;
        }
        while (true) {
            var norm: @FieldType(ast.TypeRef, "norm") = .none;
            if (p.atIdent("unorm")) norm = .unorm;
            if (p.atIdent("snorm")) norm = .snorm;
            if (norm != .none) _ = p.advance();
            _ = p.parseQualifiers(); // e.g. `row_major float4x4`
            if (p.isTypeStartAt(p.pos)) {
                const t = try p.parseType();
                t.norm = norm;
                t.array_dims = try p.parseArrayDims();
                try args.append(p.arena, .{ .type = t });
            } else {
                try args.append(p.arena, .{ .expr = try p.parseConditional() });
            }
            if (!p.eat(.comma)) break;
        }
        try p.expectCloseAngle();
        return args.items;
    }

    fn parseSemantics(p: *Parser, allow_bitfield: bool, bitfield: *?*ast.Expr) Error![]const ast.Semantic {
        var sems: std.ArrayList(ast.Semantic) = .empty;
        while (p.at(.colon)) {
            _ = p.advance();
            const t = p.tok();
            if (allow_bitfield and t.kind != .identifier) {
                bitfield.* = try p.parseConditional();
                continue;
            }
            const ident = try p.expectIdent("semantic");
            const kind: @FieldType(ast.Semantic, "kind") = if (!p.at(.l_paren))
                .semantic
            else if (ident.isIdent("register"))
                .register
            else if (ident.isIdent("packoffset"))
                .packoffset
            else if (ident.isIdent("read") or ident.isIdent("write"))
                .access
            else
                .semantic;
            if (kind == .semantic) {
                const values = try p.arena.alloc([]const u8, 1);
                values[0] = ident.text;
                try sems.append(p.arena, .{ .loc = ident.loc, .kind = .semantic, .values = values });
                continue;
            }
            _ = try p.expect(.l_paren, "'('");
            var values: std.ArrayList([]const u8) = .empty;
            // Access qualifiers keep the qualifier name as the first value.
            if (kind == .access) try values.append(p.arena, ident.text);
            var cur: std.ArrayList(u8) = .empty;
            while (!p.at(.r_paren)) {
                const a = p.advance();
                if (a.kind == .eof) return p.fail("expected ')'", .{});
                if (a.kind == .comma) {
                    try values.append(p.arena, try cur.toOwnedSlice(p.arena));
                    continue;
                }
                try cur.appendSlice(p.arena, a.text);
            }
            _ = p.advance();
            try values.append(p.arena, cur.items);
            try sems.append(p.arena, .{ .loc = ident.loc, .kind = kind, .values = values.items });
        }
        return sems.items;
    }

    fn parseArrayDims(p: *Parser) Error![]const ?*ast.Expr {
        var dims: std.ArrayList(?*ast.Expr) = .empty;
        while (p.eat(.l_square)) {
            if (p.eat(.r_square)) {
                try dims.append(p.arena, null);
                continue;
            }
            try dims.append(p.arena, try p.parseExpr());
            _ = try p.expect(.r_square, "']'");
        }
        return dims.items;
    }

    // ------------------------------------------------------------------
    // Declarations

    /// `typedef` is used for `typedef struct {...} T;`: the struct body is
    /// parsed but declarators are left to the typedef.
    const DeclContext = enum { global, member, local, typedef };

    /// Parse one declaration (possibly several declarators) and append the
    /// resulting nodes.
    fn parseDeclInto(p: *Parser, out: *std.ArrayList(*ast.Decl), ctx: DeclContext) Error!void {
        const start = p.tok();
        if (p.at(.pragma)) {
            _ = p.advance();
            return out.append(p.arena, try p.mk(ast.Decl, .{ .loc = start.loc, .kind = .{ .pragma = start.text } }));
        }
        if (p.eat(.semi)) return;

        var attrs = try p.parseAttributes();
        var template_params: []const ast.TemplateParam = &.{};
        var in_template = false;
        if (p.atIdent("template")) {
            _ = p.advance();
            try p.pushScope();
            in_template = true;
            template_params = try p.parseTemplateParams();
        }
        defer if (in_template) p.popScope();
        const more_attrs = try p.parseAttributes();
        if (more_attrs.len > 0) attrs = try std.mem.concat(p.arena, ast.Attribute, &.{ attrs, more_attrs });

        // Qualifiers may precede a struct definition: `groupshared struct {...} x;`.
        const save = p.pos;
        const lead_quals = p.parseQualifiers();
        const t = p.tok();
        if (t.isIdent("struct") or t.isIdent("class") or t.isIdent("interface")) {
            return p.parseStructDeclInto(out, attrs, lead_quals, template_params, ctx);
        }
        p.pos = save;
        if (t.isIdent("cbuffer") or t.isIdent("tbuffer")) return out.append(p.arena, try p.parseCBuffer());
        if (t.isIdent("typedef")) return p.parseTypedefInto(out);
        if (t.isIdent("using")) return out.append(p.arena, try p.parseUsing(template_params));
        if (t.isIdent("namespace")) return out.append(p.arena, try p.parseNamespace());
        if (t.isIdent("enum")) return p.parseEnumInto(out);
        if (t.isIdent("static_assert")) {
            const d = try p.parseStaticAssert();
            _ = try p.expect(.semi, "';'");
            return out.append(p.arena, d);
        }

        const quals = p.parseQualifiers();
        const ty = try p.parseType();
        try p.parseDeclaratorsInto(out, attrs, quals, template_params, ty, ctx);
    }

    fn parseTemplateParams(p: *Parser) Error![]const ast.TemplateParam {
        _ = try p.expect(.less, "'<'");
        var params: std.ArrayList(ast.TemplateParam) = .empty;
        const saved = p.no_greater;
        p.no_greater = true;
        defer p.no_greater = saved;
        while (!p.at(.greater)) {
            const loc = p.tok().loc;
            if (p.eatIdent("typename") or p.eatIdent("class")) {
                const name = if (p.at(.identifier) and !isReserved(p.tok().text)) p.advance() else Token{ .kind = .identifier, .text = "", .loc = loc };
                var default: ?ast.TemplateArg = null;
                if (p.eat(.equal)) default = .{ .type = try p.parseType() };
                if (name.text.len > 0) try p.declareName(name.text, .type);
                try params.append(p.arena, .{ .loc = loc, .name = name.text, .value_type = null, .default = default });
            } else {
                const ty = try p.parseType();
                const name = if (p.at(.identifier) and !isReserved(p.tok().text)) p.advance() else Token{ .kind = .identifier, .text = "", .loc = loc };
                var default: ?ast.TemplateArg = null;
                if (p.eat(.equal)) default = .{ .expr = try p.parseConditional() };
                if (name.text.len > 0) try p.declareName(name.text, .value);
                try params.append(p.arena, .{ .loc = loc, .name = name.text, .value_type = ty, .default = default });
            }
            if (!p.eat(.comma)) break;
        }
        try p.expectCloseAngle();
        return params.items;
    }

    fn parseStructDeclInto(p: *Parser, out: *std.ArrayList(*ast.Decl), lead_attrs: []const ast.Attribute, quals: ast.Qualifiers, template_params: []const ast.TemplateParam, ctx: DeclContext) Error!void {
        const kw = p.advance();
        // Attributes may also follow the keyword: `struct [raypayload] P`.
        const kw_attrs = try p.parseAttributes();
        const attrs = if (kw_attrs.len == 0) lead_attrs else try std.mem.concat(p.arena, ast.Attribute, &.{ lead_attrs, kw_attrs });
        const keyword: @FieldType(ast.StructDecl, "keyword") = if (kw.isIdent("class")) .class else if (kw.isIdent("interface")) .interface else .@"struct";
        var name: ?[]const u8 = null;
        var name_loc = kw.loc;
        if (p.at(.identifier) and !isReserved(p.tok().text)) {
            const n = p.advance();
            name = n.text;
            name_loc = n.loc;
            // Declared before the body so members can refer to it.
            if (p.lookupName(n.text) == null) {
                try p.declareNameOuter(n.text, if (template_params.len > 0) .template_type else .type, template_params.len > 0);
            }
        }
        // Partial or explicit specialization: `struct S<true, T> { ... }`.
        var spec_args: []const ast.TemplateArg = &.{};
        if (name != null and p.at(.less)) spec_args = try p.parseTemplateArgs();

        p.last_struct_name = name orelse "";
        // `struct S x;` uses an existing struct type; in a typedef the
        // declarators belong to the typedef.
        if (name != null and !p.at(.l_brace) and !p.at(.colon) and !p.at(.semi)) {
            if (ctx == .typedef) return;
            const ty = try p.mk(ast.TypeRef, .{ .loc = name_loc, .name = try p.simpleName(name_loc, name.?) });
            return p.parseDeclaratorsInto(out, attrs, quals, &.{}, ty, ctx);
        }

        var bases: std.ArrayList(*ast.TypeRef) = .empty;
        if (p.eat(.colon)) {
            while (true) {
                _ = p.eatIdent("public") or p.eatIdent("private") or p.eatIdent("protected");
                try bases.append(p.arena, try p.parseType());
                if (!p.eat(.comma)) break;
            }
        }

        var members: ?[]const *ast.Decl = null;
        if (p.eat(.l_brace)) {
            try p.pushScope();
            var list: std.ArrayList(*ast.Decl) = .empty;
            while (!p.at(.r_brace) and !p.at(.eof)) {
                const before = p.pos;
                // Access specifiers: `public:`.
                if ((p.atIdent("public") or p.atIdent("private") or p.atIdent("protected")) and p.peek(1).kind == .colon) {
                    _ = p.advance();
                    _ = p.advance();
                    continue;
                }
                p.parseDeclInto(&list, .member) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Syntax => p.recover(before),
                };
            }
            // Nested types stay visible (unqualified) after the struct so
            // that `S::Inner` resolves; the name table is flat by last name.
            var nested: std.ArrayList(struct { []const u8, NameKind }) = .empty;
            for (p.scopes.items[p.scopes.items.len - 1].items) |n| {
                if (p.lookupName(n)) |k| if (k == .type or k == .template_type) try nested.append(p.arena, .{ n, k });
            }
            p.popScope();
            for (nested.items) |n| try p.declareName(n[0], n[1]);
            _ = try p.expect(.r_brace, "'}'");
            members = list.items;
        }

        if (name == null) {
            p.anon_count += 1;
            name = try std.fmt.allocPrint(p.arena, "__anon_struct_{d}", .{p.anon_count});
        }
        p.last_struct_name = name.?;
        try out.append(p.arena, try p.mk(ast.Decl, .{ .loc = kw.loc, .kind = .{ .@"struct" = .{
            .attrs = attrs,
            .keyword = keyword,
            .template_params = template_params,
            .name = name,
            .specialization_args = spec_args,
            .bases = bases.items,
            .members = members,
        } } }));

        if (ctx == .typedef) return;
        if (p.eat(.semi)) return;
        // `struct S { ... } a, b;`
        const ty = try p.mk(ast.TypeRef, .{ .loc = name_loc, .name = try p.simpleName(name_loc, name.?) });
        try p.parseDeclaratorsInto(out, &.{}, quals, &.{}, ty, ctx);
    }

    /// Declare a name in the scope enclosing an open template scope (so a
    /// template's own name outlives its parameters).
    fn declareNameOuter(p: *Parser, name: []const u8, kind: NameKind, in_template: bool) Allocator.Error!void {
        if (!in_template or p.scopes.items.len < 2) return p.declareName(name, kind);
        const gop = try p.names.getOrPut(p.arena, name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        // Insert below any entries added by the template scope.
        try gop.value_ptr.insert(p.arena, 0, kind);
        try p.scopes.items[p.scopes.items.len - 2].append(p.arena, name);
    }

    fn parseCBuffer(p: *Parser) Error!*ast.Decl {
        const kw = p.advance();
        const name = try p.expectIdent("buffer name");
        var bitfield: ?*ast.Expr = null;
        const sems = try p.parseSemantics(false, &bitfield);
        _ = try p.expect(.l_brace, "'{'");
        var members: std.ArrayList(*ast.Decl) = .empty;
        while (!p.at(.r_brace) and !p.at(.eof)) {
            const before = p.pos;
            p.parseDeclInto(&members, .member) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Syntax => p.recover(before),
            };
        }
        _ = try p.expect(.r_brace, "'}'");
        _ = p.eat(.semi);
        return p.mk(ast.Decl, .{ .loc = kw.loc, .kind = .{ .cbuffer = .{
            .tbuffer = kw.isIdent("tbuffer"),
            .name = name.text,
            .semantics = sems,
            .members = members.items,
        } } });
    }

    fn parseTypedefInto(p: *Parser, out: *std.ArrayList(*ast.Decl)) Error!void {
        const kw = p.advance();
        _ = p.parseQualifiers();
        var ty: *ast.TypeRef = undefined;
        if (p.atIdent("struct") or p.atIdent("class")) {
            // `typedef struct { ... } Name;`
            try p.parseStructDeclInto(out, &.{}, .{}, &.{}, .typedef);
            ty = try p.mk(ast.TypeRef, .{ .loc = kw.loc, .name = try p.simpleName(kw.loc, p.last_struct_name) });
        } else ty = try p.parseType();
        while (true) {
            const name = try p.expectIdent("typedef name");
            const dims = try p.parseArrayDims();
            try p.declareName(name.text, .type);
            try out.append(p.arena, try p.mk(ast.Decl, .{ .loc = kw.loc, .kind = .{ .typedef = .{ .name = name.text, .type = ty, .array_dims = dims } } }));
            if (!p.eat(.comma)) break;
        }
        _ = try p.expect(.semi, "';'");
    }

    fn parseUsing(p: *Parser, template_params: []const ast.TemplateParam) Error!*ast.Decl {
        const kw = p.advance();
        if (p.eatIdent("namespace")) {
            const n = try p.parseName();
            _ = try p.expect(.semi, "';'");
            return p.mk(ast.Decl, .{ .loc = kw.loc, .kind = .{ .using_namespace = n } });
        }
        if (p.peek(1).kind == .colon_colon or p.at(.colon_colon)) {
            const n = try p.parseName();
            _ = try p.expect(.semi, "';'");
            return p.mk(ast.Decl, .{ .loc = kw.loc, .kind = .{ .using_decl = n } });
        }
        const name = try p.expectIdent("alias name");
        _ = try p.parseAttributes(); // e.g. [[vk::ext_capability(...)]]
        _ = try p.expect(.equal, "'='");
        _ = p.parseQualifiers();
        const ty = try p.parseType();
        const dims = try p.parseArrayDims();
        _ = try p.expect(.semi, "';'");
        try p.declareNameOuter(name.text, if (template_params.len > 0) .template_type else .type, template_params.len > 0);
        return p.mk(ast.Decl, .{ .loc = kw.loc, .kind = .{ .typedef = .{ .name = name.text, .type = ty, .array_dims = dims, .template_params = template_params } } });
    }

    fn parseNamespace(p: *Parser) Error!*ast.Decl {
        const kw = p.advance();
        const name = try p.expectIdent("namespace name");
        _ = try p.expect(.l_brace, "'{'");
        var decls: std.ArrayList(*ast.Decl) = .empty;
        while (!p.at(.r_brace) and !p.at(.eof)) {
            const before = p.pos;
            p.parseDeclInto(&decls, .global) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Syntax => p.recover(before),
            };
        }
        _ = try p.expect(.r_brace, "'}'");
        return p.mk(ast.Decl, .{ .loc = kw.loc, .kind = .{ .namespace = .{ .name = name.text, .decls = decls.items } } });
    }

    fn parseEnumInto(p: *Parser, out: *std.ArrayList(*ast.Decl)) Error!void {
        const kw = p.advance();
        const scoped = p.eatIdent("class") or p.eatIdent("struct");
        var name: ?[]const u8 = null;
        if (p.at(.identifier) and !isReserved(p.tok().text)) {
            name = p.advance().text;
            try p.declareName(name.?, .type);
        }
        var underlying: ?*ast.TypeRef = null;
        if (p.eat(.colon)) underlying = try p.parseType();
        _ = try p.expect(.l_brace, "'{'");
        var values: std.ArrayList(@typeInfo(@FieldType(ast.EnumDecl, "values")).pointer.child) = .empty;
        while (!p.at(.r_brace)) {
            const n = try p.expectIdent("enumerator");
            var value: ?*ast.Expr = null;
            if (p.eat(.equal)) value = try p.parseConditional();
            try values.append(p.arena, .{ .loc = n.loc, .name = n.text, .value = value });
            if (!scoped) try p.declareName(n.text, .value);
            if (!p.eat(.comma)) break;
        }
        _ = try p.expect(.r_brace, "'}'");
        try out.append(p.arena, try p.mk(ast.Decl, .{ .loc = kw.loc, .kind = .{ .@"enum" = .{
            .name = name,
            .scoped = scoped,
            .underlying = underlying,
            .values = values.items,
        } } }));
        if (p.eat(.semi)) return;
        const ty = try p.mk(ast.TypeRef, .{ .loc = kw.loc, .name = try p.simpleName(kw.loc, name orelse "int") });
        try p.parseDeclaratorsInto(out, &.{}, .{}, &.{}, ty, .global);
    }

    fn parseStaticAssert(p: *Parser) Error!*ast.Decl {
        const kw = p.advance();
        _ = try p.expect(.l_paren, "'('");
        const cond = try p.parseAssign();
        var message: ?[]const u8 = null;
        if (p.eat(.comma)) message = (try p.expect(.string, "string literal")).text;
        _ = try p.expect(.r_paren, "')'");
        return p.mk(ast.Decl, .{ .loc = kw.loc, .kind = .{ .static_assert = .{ .cond = cond, .message = message } } });
    }

    /// After `quals type`: one function, or a list of variable declarators.
    fn parseDeclaratorsInto(
        p: *Parser,
        out: *std.ArrayList(*ast.Decl),
        attrs: []const ast.Attribute,
        quals: ast.Qualifiers,
        template_params: []const ast.TemplateParam,
        ty: *ast.TypeRef,
        ctx: DeclContext,
    ) Error!void {
        // Function names may be qualified (`S::method`) or operators;
        // variables may be qualified for out-of-line static members.
        const name_loc = p.tok().loc;
        var fname: ?ast.Name = null;
        var qualified_var: ?[]const u8 = null;
        if (p.atIdent("operator")) {
            fname = try p.parseOperatorName();
        } else if (p.at(.identifier) and (p.peek(1).kind == .colon_colon or p.peek(1).kind == .l_paren or p.peek(1).kind == .less)) {
            const save = p.pos;
            var n = try p.parseName();
            if (p.at(.colon_colon) and p.peek(1).isIdent("operator")) {
                _ = p.advance();
                const op = try p.parseOperatorName();
                n.parts = try std.mem.concat(p.arena, []const u8, &.{ n.parts, op.parts });
                if (n.args.len > 0) n.args = try std.mem.concat(p.arena, []const ast.TemplateArg, &.{ n.args, &.{&.{}} });
            }
            if (p.at(.less) and !p.isTemplateName(n.last())) {
                p.pos = save;
            } else {
                // Explicit specialization `f<T>(...)` is not supported yet;
                // accept the syntax.
                if (p.at(.less)) _ = try p.parseTemplateArgs();
                if (p.at(.l_paren)) {
                    fname = n;
                } else if (n.parts.len > 1 or p.toks[p.pos - 1].kind == .greater) {
                    // Qualified static member, or a variable template
                    // specialization `v<T, T>` (arguments are dropped).
                    qualified_var = try std.mem.join(p.arena, "::", n.parts);
                } else p.pos = save;
            }
        }
        if (fname) |n| return out.append(p.arena, try p.parseFunctionRest(attrs, quals, template_params, ty, n, name_loc, ctx));

        var first = true;
        while (true) {
            var name: Token = undefined;
            if (first and qualified_var != null) {
                name = .{ .kind = .identifier, .text = qualified_var.?, .loc = name_loc };
            } else name = try p.expectIdent("declarator name");
            first = false;
            const dims = try p.parseArrayDims();
            var bitfield: ?*ast.Expr = null;
            const sems = try p.parseSemantics(ctx == .member, &bitfield);
            // Legacy effect syntax: `<annotations>` and `{ state block }`.
            if (ctx != .local and p.at(.less)) try p.skipBalanced(.less, .greater);
            var init_expr: ?*ast.Expr = null;
            if (ctx != .local and p.at(.l_brace)) {
                try p.skipBalanced(.l_brace, .r_brace);
            } else if (p.eat(.equal)) init_expr = try p.parseInitializer();
            try out.append(p.arena, try p.mk(ast.Decl, .{ .loc = name.loc, .kind = .{ .@"var" = .{
                .attrs = attrs,
                .template_params = template_params,
                .quals = quals,
                .type = ty,
                .name = name.text,
                .name_loc = name.loc,
                .array_dims = dims,
                .semantics = sems,
                .bitfield = bitfield,
                .init = init_expr,
            } } }));
            if (ctx == .local) try p.declareName(name.text, .value);
            // Variable templates are referenced as `v<Args>`.
            if (template_params.len > 0 and qualified_var == null) try p.declareNameOuter(name.text, .template_func, true);
            if (!p.eat(.comma)) break;
        }
        _ = try p.expect(.semi, "';'");
    }

    /// Skip a balanced `open ... close` group (legacy annotations and state
    /// blocks, which zdxc ignores like dxc does).
    fn skipBalanced(p: *Parser, open: Kind, close: Kind) Error!void {
        _ = try p.expect(open, "group");
        var depth: u32 = 1;
        while (depth > 0) {
            const t = p.advance();
            if (t.kind == .eof) return p.fail("unterminated block", .{});
            if (t.kind == open) depth += 1;
            if (t.kind == close) depth -= 1;
        }
    }

    fn parseOperatorName(p: *Parser) Error!ast.Name {
        const kw = p.advance();
        const t = p.advance();
        const text = switch (t.kind) {
            .l_paren => blk: {
                _ = try p.expect(.r_paren, "')'");
                break :blk "operator()";
            },
            .l_square => blk: {
                _ = try p.expect(.r_square, "']'");
                break :blk "operator[]";
            },
            .eof, .identifier, .number, .string, .char => return p.fail("expected operator after 'operator'", .{}),
            else => try std.mem.concat(p.arena, u8, &.{ "operator", t.text }),
        };
        return p.simpleName(kw.loc, text);
    }

    fn parseFunctionRest(
        p: *Parser,
        attrs: []const ast.Attribute,
        quals: ast.Qualifiers,
        template_params: []const ast.TemplateParam,
        ret: *ast.TypeRef,
        name: ast.Name,
        loc: Loc,
        ctx: DeclContext,
    ) Error!*ast.Decl {
        if (template_params.len > 0) {
            try p.declareNameOuter(name.last(), .template_func, true);
        } else if (ctx != .member) {
            try p.declareName(name.last(), .value);
        }
        _ = try p.expect(.l_paren, "'('");
        try p.pushScope();
        defer p.popScope();
        var params: std.ArrayList(ast.VarDecl) = .empty;
        if (p.atIdent("void") and p.peek(1).kind == .r_paren) _ = p.advance();
        while (!p.at(.r_paren)) {
            const pattrs = try p.parseAttributes();
            const pquals = p.parseQualifiers();
            const pty = try p.parseType();
            var pname: []const u8 = "";
            var pname_loc = p.tok().loc;
            if (p.at(.identifier) and !isReserved(p.tok().text)) {
                const n = p.advance();
                pname = n.text;
                pname_loc = n.loc;
                try p.declareName(n.text, .value);
            }
            const dims = try p.parseArrayDims();
            var bitfield: ?*ast.Expr = null;
            const sems = try p.parseSemantics(false, &bitfield);
            var default: ?*ast.Expr = null;
            if (p.eat(.equal)) default = try p.parseAssign();
            try params.append(p.arena, .{
                .attrs = pattrs,
                .quals = pquals,
                .type = pty,
                .name = pname,
                .name_loc = pname_loc,
                .array_dims = dims,
                .semantics = sems,
                .init = default,
            });
            if (!p.eat(.comma)) break;
        }
        _ = try p.expect(.r_paren, "')'");
        const ret_dims = try p.parseArrayDims();
        const is_const = p.eatIdent("const");
        var bitfield: ?*ast.Expr = null;
        const ret_sems = try p.parseSemantics(false, &bitfield);
        var body: ?*ast.Stmt = null;
        if (p.at(.l_brace)) {
            body = try p.parseCompound();
            _ = p.eat(.semi);
        } else {
            _ = try p.expect(.semi, "';' or function body");
        }
        return p.mk(ast.Decl, .{ .loc = loc, .kind = .{ .func = .{
            .attrs = attrs,
            .quals = quals,
            .template_params = template_params,
            .ret = ret,
            .name = name,
            .params = params.items,
            .ret_semantics = ret_sems,
            .ret_dims = ret_dims,
            .is_const = is_const,
            .body = body,
        } } });
    }

    fn parseInitializer(p: *Parser) Error!*ast.Expr {
        // Legacy `sampler_state { ... }` initializers are ignored, as in dxc.
        if ((p.atIdent("sampler_state") or p.atIdent("SamplerState") or p.atIdent("SamplerComparisonState")) and p.peek(1).kind == .l_brace) {
            const kw = p.advance();
            try p.skipBalanced(.l_brace, .r_brace);
            return p.mkExpr(kw.loc, .{ .init_list = &.{} });
        }
        if (!p.at(.l_brace)) return p.parseAssign();
        const open = p.advance();
        var items: std.ArrayList(*ast.Expr) = .empty;
        while (!p.at(.r_brace)) {
            try items.append(p.arena, try p.parseInitializer());
            if (!p.eat(.comma)) break;
        }
        _ = try p.expect(.r_brace, "'}'");
        return p.mkExpr(open.loc, .{ .init_list = items.items });
    }

    // ------------------------------------------------------------------
    // Statements

    fn parseCompound(p: *Parser) Error!*ast.Stmt {
        const open = try p.expect(.l_brace, "'{'");
        try p.pushScope();
        defer p.popScope();
        var stmts: std.ArrayList(*ast.Stmt) = .empty;
        while (!p.at(.r_brace) and !p.at(.eof)) {
            const before = p.pos;
            const s = p.parseStmt() catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Syntax => {
                    p.recover(before);
                    continue;
                },
            };
            try stmts.append(p.arena, s);
        }
        _ = try p.expect(.r_brace, "'}'");
        return p.mk(ast.Stmt, .{ .loc = open.loc, .kind = .{ .compound = stmts.items } });
    }

    fn mkStmt(p: *Parser, loc: Loc, attrs: []const ast.Attribute, kind: ast.Stmt.Kind) Allocator.Error!*ast.Stmt {
        return p.mk(ast.Stmt, .{ .loc = loc, .attrs = attrs, .kind = kind });
    }

    fn parseStmt(p: *Parser) Error!*ast.Stmt {
        const attrs = try p.parseAttributes();
        const t = p.tok();
        if (t.kind == .l_brace) {
            const s = try p.parseCompound();
            s.attrs = attrs;
            return s;
        }
        if (t.kind == .semi) {
            _ = p.advance();
            return p.mkStmt(t.loc, attrs, .empty);
        }
        if (t.kind == .pragma) {
            _ = p.advance();
            return p.mkStmt(t.loc, attrs, .empty);
        }
        if (t.kind == .identifier) {
            const w = t.text;
            if (std.mem.eql(u8, w, "if")) {
                _ = p.advance();
                _ = try p.expect(.l_paren, "'('");
                try p.pushScope();
                defer p.popScope();
                const c = try p.parseCondition();
                _ = try p.expect(.r_paren, "')'");
                const then = try p.parseStmt();
                var else_stmt: ?*ast.Stmt = null;
                if (p.eatIdent("else")) else_stmt = try p.parseStmt();
                return p.mkStmt(t.loc, attrs, .{ .@"if" = .{ .cond_decl = c.decl, .cond = c.cond, .then = then, .@"else" = else_stmt } });
            }
            if (std.mem.eql(u8, w, "for")) {
                _ = p.advance();
                _ = try p.expect(.l_paren, "'('");
                // HLSL 2021: the loop variable is scoped to the loop.
                try p.pushScope();
                defer p.popScope();
                var init_stmt: ?*ast.Stmt = null;
                if (!p.eat(.semi)) init_stmt = try p.parseSimpleStmt(true);
                var cond: ?*ast.Expr = null;
                if (!p.at(.semi)) cond = try p.parseExpr();
                _ = try p.expect(.semi, "';'");
                var inc: ?*ast.Expr = null;
                if (!p.at(.r_paren)) inc = try p.parseExpr();
                _ = try p.expect(.r_paren, "')'");
                const body = try p.parseStmt();
                return p.mkStmt(t.loc, attrs, .{ .@"for" = .{ .init = init_stmt, .cond = cond, .inc = inc, .body = body } });
            }
            if (std.mem.eql(u8, w, "while")) {
                _ = p.advance();
                _ = try p.expect(.l_paren, "'('");
                try p.pushScope();
                defer p.popScope();
                const c = try p.parseCondition();
                _ = try p.expect(.r_paren, "')'");
                return p.mkStmt(t.loc, attrs, .{ .@"while" = .{ .cond_decl = c.decl, .cond = c.cond, .body = try p.parseStmt() } });
            }
            if (std.mem.eql(u8, w, "do")) {
                _ = p.advance();
                const body = try p.parseStmt();
                if (!p.eatIdent("while")) return p.fail("expected 'while' after do-statement body", .{});
                _ = try p.expect(.l_paren, "'('");
                const cond = try p.parseExpr();
                _ = try p.expect(.r_paren, "')'");
                _ = try p.expect(.semi, "';'");
                return p.mkStmt(t.loc, attrs, .{ .do_while = .{ .body = body, .cond = cond } });
            }
            if (std.mem.eql(u8, w, "switch")) {
                _ = p.advance();
                _ = try p.expect(.l_paren, "'('");
                try p.pushScope();
                defer p.popScope();
                const c = try p.parseCondition();
                _ = try p.expect(.r_paren, "')'");
                return p.mkStmt(t.loc, attrs, .{ .@"switch" = .{ .cond_decl = c.decl, .cond = c.cond, .body = try p.parseStmt() } });
            }
            if (std.mem.eql(u8, w, "case")) {
                _ = p.advance();
                const value = try p.parseConditional();
                _ = try p.expect(.colon, "':'");
                return p.mkStmt(t.loc, attrs, .{ .case = .{ .value = value, .stmt = try p.parseCaseBody() } });
            }
            if (std.mem.eql(u8, w, "default") and p.peek(1).kind == .colon) {
                _ = p.advance();
                _ = p.advance();
                return p.mkStmt(t.loc, attrs, .{ .default = try p.parseCaseBody() });
            }
            if (std.mem.eql(u8, w, "break") or std.mem.eql(u8, w, "continue") or std.mem.eql(u8, w, "discard")) {
                _ = p.advance();
                _ = try p.expect(.semi, "';'");
                const kind: ast.Stmt.Kind = if (w[0] == 'b') .@"break" else if (w[0] == 'c') .@"continue" else .discard;
                return p.mkStmt(t.loc, attrs, kind);
            }
            if (std.mem.eql(u8, w, "return")) {
                _ = p.advance();
                var value: ?*ast.Expr = null;
                if (!p.at(.semi)) value = if (p.at(.l_brace)) try p.parseInitializer() else try p.parseExpr();
                _ = try p.expect(.semi, "';'");
                return p.mkStmt(t.loc, attrs, .{ .@"return" = value });
            }
        }
        const s = try p.parseSimpleStmt(false);
        s.attrs = attrs;
        return s;
    }

    /// `expr`, or `T name = init` (C++ condition declaration).
    fn parseCondition(p: *Parser) Error!struct { decl: ?*ast.Decl, cond: *ast.Expr } {
        if (!p.startsLocalDecl()) return .{ .decl = null, .cond = try p.parseExpr() };
        const quals = p.parseQualifiers();
        const ty = try p.parseType();
        const name = try p.expectIdent("variable name");
        _ = try p.expect(.equal, "'='");
        const init_expr = try p.parseAssign();
        try p.declareName(name.text, .value);
        const decl = try p.mk(ast.Decl, .{ .loc = name.loc, .kind = .{ .@"var" = .{
            .attrs = &.{},
            .quals = quals,
            .type = ty,
            .name = name.text,
            .name_loc = name.loc,
            .array_dims = &.{},
            .semantics = &.{},
            .init = init_expr,
        } } });
        const ref = try p.mkExpr(name.loc, .{ .name = try p.simpleName(name.loc, name.text) });
        return .{ .decl = decl, .cond = ref };
    }

    /// A `case`/`default` label applies to the following statement; an
    /// immediately following label or `}` yields an empty statement.
    fn parseCaseBody(p: *Parser) Error!*ast.Stmt {
        if (p.at(.r_brace)) return p.mkStmt(p.tok().loc, &.{}, .empty);
        return p.parseStmt();
    }

    /// Declaration or expression statement, ending with `;`.
    fn parseSimpleStmt(p: *Parser, in_for: bool) Error!*ast.Stmt {
        _ = in_for;
        const t = p.tok();
        if (p.startsLocalDecl()) {
            var decls: std.ArrayList(*ast.Decl) = .empty;
            try p.parseDeclInto(&decls, .local);
            return p.mkStmt(t.loc, &.{}, .{ .decl = decls.items });
        }
        const e = try p.parseExpr();
        _ = try p.expect(.semi, "';'");
        return p.mkStmt(t.loc, &.{}, .{ .expr = e });
    }

    fn startsLocalDecl(p: *const Parser) bool {
        const t = p.tok();
        if (t.kind != .identifier and t.kind != .colon_colon) return false;
        if (t.kind == .identifier) {
            const w = t.text;
            if (std.mem.eql(u8, w, "struct") or std.mem.eql(u8, w, "class") or std.mem.eql(u8, w, "typedef") or
                std.mem.eql(u8, w, "using") or std.mem.eql(u8, w, "enum") or std.mem.eql(u8, w, "static_assert"))
                return true;
            if (qualifierField(w) != null) {
                if (!isContextualQualifier(w)) return true;
                const n = p.peek(1);
                if ((n.kind == .identifier and qualifierField(n.text) != null) or p.isTypeStartAt(p.pos + 1)) return true;
            }
        }
        // `Type name ...`
        const end = p.scanType(p.pos) orelse return false;
        const n = p.toks[end];
        return n.kind == .identifier and !isReserved(n.text);
    }

    // ------------------------------------------------------------------
    // Expressions

    pub fn parseExpr(p: *Parser) Error!*ast.Expr {
        var lhs = try p.parseAssign();
        while (p.at(.comma)) {
            const op = p.advance();
            const rhs = try p.parseAssign();
            lhs = try p.mkExpr(op.loc, .{ .binary = .{ .op = .comma, .lhs = lhs, .rhs = rhs } });
        }
        return lhs;
    }

    fn parseAssign(p: *Parser) Error!*ast.Expr {
        const lhs = try p.parseConditional();
        const op: ?ast.AssignOp = switch (p.tok().kind) {
            .equal => .assign,
            .star_equal => .mul,
            .slash_equal => .div,
            .percent_equal => .rem,
            .plus_equal => .add,
            .minus_equal => .sub,
            .less_less_equal => .shl,
            .greater_greater_equal => if (p.no_greater) null else .shr,
            .amp_equal => .bit_and,
            .caret_equal => .bit_xor,
            .pipe_equal => .bit_or,
            else => null,
        };
        const o = op orelse return lhs;
        const t = p.advance();
        const rhs = try p.parseAssign();
        return p.mkExpr(t.loc, .{ .assign = .{ .op = o, .lhs = lhs, .rhs = rhs } });
    }

    fn parseConditional(p: *Parser) Error!*ast.Expr {
        const cond = try p.parseBinary(1);
        if (!p.at(.question)) return cond;
        const q = p.advance();
        const saved = p.no_greater;
        p.no_greater = false;
        const then = try p.parseExpr();
        p.no_greater = saved;
        _ = try p.expect(.colon, "':'");
        const else_expr = try p.parseAssign();
        return p.mkExpr(q.loc, .{ .conditional = .{ .cond = cond, .then = then, .@"else" = else_expr } });
    }

    fn binaryOp(p: *const Parser, k: Kind) ?struct { op: ast.BinaryOp, prec: u8 } {
        return switch (k) {
            .pipe_pipe => .{ .op = .log_or, .prec = 1 },
            .amp_amp => .{ .op = .log_and, .prec = 2 },
            .pipe => .{ .op = .bit_or, .prec = 3 },
            .caret => .{ .op = .bit_xor, .prec = 4 },
            .amp => .{ .op = .bit_and, .prec = 5 },
            .equal_equal => .{ .op = .eq, .prec = 6 },
            .exclaim_equal => .{ .op = .ne, .prec = 6 },
            .less => .{ .op = .lt, .prec = 7 },
            .greater => if (p.no_greater) null else .{ .op = .gt, .prec = 7 },
            .less_equal => .{ .op = .le, .prec = 7 },
            .greater_equal => if (p.no_greater) null else .{ .op = .ge, .prec = 7 },
            .less_less => .{ .op = .shl, .prec = 8 },
            .greater_greater => if (p.no_greater) null else .{ .op = .shr, .prec = 8 },
            .plus => .{ .op = .add, .prec = 9 },
            .minus => .{ .op = .sub, .prec = 9 },
            .star => .{ .op = .mul, .prec = 10 },
            .slash => .{ .op = .div, .prec = 10 },
            .percent => .{ .op = .rem, .prec = 10 },
            else => null,
        };
    }

    fn parseBinary(p: *Parser, min_prec: u8) Error!*ast.Expr {
        var lhs = try p.parseUnary();
        while (p.binaryOp(p.tok().kind)) |info| {
            if (info.prec < min_prec) break;
            const t = p.advance();
            const rhs = try p.parseBinary(info.prec + 1);
            lhs = try p.mkExpr(t.loc, .{ .binary = .{ .op = info.op, .lhs = lhs, .rhs = rhs } });
        }
        return lhs;
    }

    fn parseUnary(p: *Parser) Error!*ast.Expr {
        const t = p.tok();
        const op: ?ast.UnaryOp = switch (t.kind) {
            .plus => .plus,
            .minus => .minus,
            .exclaim => .not,
            .tilde => .bit_not,
            .plus_plus => .pre_inc,
            .minus_minus => .pre_dec,
            else => null,
        };
        if (op) |o| {
            _ = p.advance();
            const operand = try p.parseUnary();
            return p.mkExpr(t.loc, .{ .unary = .{ .op = o, .operand = operand } });
        }
        // C-style cast: `(type)expr` or `(type[N])expr`.
        if (t.kind == .l_paren) {
            var type_start = p.pos + 1;
            while (p.toks[type_start].kind == .identifier and qualifierField(p.toks[type_start].text) != null) type_start += 1;
            if (p.scanType(type_start)) |end| {
                var i = end;
                while (p.toks[i].kind == .l_square) {
                    while (p.toks[i].kind != .r_square and p.toks[i].kind != .eof) i += 1;
                    i += 1;
                }
                if (p.toks[i].kind == .r_paren) {
                    _ = p.advance();
                    _ = p.parseQualifiers();
                    const ty = try p.parseType();
                    const dims = try p.parseArrayDims();
                    _ = try p.expect(.r_paren, "')'");
                    const operand = try p.parseUnary();
                    return p.mkExpr(t.loc, .{ .cast = .{ .type = ty, .array_dims = dims, .operand = operand } });
                }
            }
        }
        if (t.isIdent("sizeof")) {
            _ = p.advance();
            if (p.at(.l_paren) and p.isTypeStartAt(p.pos + 1)) {
                _ = p.advance();
                const ty = try p.parseType();
                ty.array_dims = try p.parseArrayDims();
                _ = try p.expect(.r_paren, "')'");
                return p.mkExpr(t.loc, .{ .sizeof_type = ty });
            }
            return p.mkExpr(t.loc, .{ .sizeof_expr = try p.parseUnary() });
        }
        return p.parsePostfix(try p.parsePrimary());
    }

    fn parseArgs(p: *Parser) Error![]const *ast.Expr {
        _ = try p.expect(.l_paren, "'('");
        const saved = p.no_greater;
        p.no_greater = false;
        defer p.no_greater = saved;
        var args: std.ArrayList(*ast.Expr) = .empty;
        while (!p.at(.r_paren)) {
            try args.append(p.arena, try p.parseAssign());
            if (!p.eat(.comma)) break;
        }
        _ = try p.expect(.r_paren, "')'");
        return args.items;
    }

    fn parsePostfix(p: *Parser, base: *ast.Expr) Error!*ast.Expr {
        var e = base;
        while (true) {
            const t = p.tok();
            switch (t.kind) {
                .l_paren => {
                    const args = try p.parseArgs();
                    e = try p.mkExpr(t.loc, .{ .call = .{ .callee = e, .args = args } });
                },
                .l_square => {
                    _ = p.advance();
                    const saved = p.no_greater;
                    p.no_greater = false;
                    const index = try p.parseExpr();
                    p.no_greater = saved;
                    _ = try p.expect(.r_square, "']'");
                    e = try p.mkExpr(t.loc, .{ .index = .{ .base = e, .index = index } });
                },
                .period, .arrow => {
                    _ = p.advance();
                    // C++ disambiguator: `obj.template Load<T>(i)`.
                    const forced_template = p.atIdent("template") and p.peek(1).kind == .identifier;
                    if (forced_template) _ = p.advance();
                    const name = try p.expectMemberName();
                    e = try p.mkExpr(t.loc, .{ .member = .{ .base = e, .name = name.text, .name_loc = name.loc } });
                    // Method template call: `obj.Load<float4>(i)`.
                    if (p.at(.less) and (forced_template or p.looksLikeTemplateCall())) {
                        const targs = try p.parseTemplateArgs();
                        const args = try p.parseArgs();
                        e = try p.mkExpr(t.loc, .{ .call = .{ .callee = e, .args = args, .template_args = targs } });
                    }
                },
                .plus_plus, .minus_minus => {
                    _ = p.advance();
                    e = try p.mkExpr(t.loc, .{ .unary = .{ .op = if (t.kind == .plus_plus) .post_inc else .post_dec, .operand = e } });
                },
                else => return e,
            }
        }
    }

    fn expectMemberName(p: *Parser) Error!Token {
        // Member names may coincide with keywords used as swizzles (e.g.
        // `.x`) or contextual keywords; accept any identifier.
        if (p.at(.identifier)) return p.advance();
        return p.fail("expected member name, found '{s}'", .{describe(p.tok())});
    }

    /// After a member name, `<` starts template arguments if a matching `>`
    /// is followed by `(`.
    fn looksLikeTemplateCall(p: *const Parser) bool {
        var i = p.pos;
        var depth: u32 = 0;
        while (true) : (i += 1) {
            switch (p.toks[i].kind) {
                .less => depth += 1,
                .greater => {
                    depth -= 1;
                    if (depth == 0) return p.toks[i + 1].kind == .l_paren;
                },
                .greater_greater => {
                    if (depth <= 2) return depth == 2 and p.toks[i + 1].kind == .l_paren;
                    depth -= 2;
                },
                .semi, .l_brace, .r_brace, .eof, .amp_amp, .pipe_pipe => return false,
                else => {},
            }
        }
    }

    fn parsePrimary(p: *Parser) Error!*ast.Expr {
        const t = p.tok();
        switch (t.kind) {
            .number => {
                _ = p.advance();
                return p.mkExpr(t.loc, if (isFloatLiteral(t.text)) .{ .float_lit = t.text } else .{ .int_lit = t.text });
            },
            .string => {
                _ = p.advance();
                // Adjacent string literals concatenate.
                var text = t.text;
                while (p.at(.string)) {
                    const n = p.advance();
                    text = try std.mem.concat(p.arena, u8, &.{ text[0 .. text.len - 1], n.text[1..] });
                }
                return p.mkExpr(t.loc, .{ .string_lit = text });
            },
            .char => {
                _ = p.advance();
                return p.mkExpr(t.loc, .{ .int_lit = t.text });
            },
            .l_paren => {
                _ = p.advance();
                const saved = p.no_greater;
                p.no_greater = false;
                const e = try p.parseExpr();
                p.no_greater = saved;
                _ = try p.expect(.r_paren, "')'");
                return e;
            },
            .l_brace => return p.parseInitializer(),
            .identifier, .colon_colon => {},
            else => return p.fail("expected expression, found '{s}'", .{describe(t)}),
        }
        if (t.isIdent("true") or t.isIdent("false")) {
            _ = p.advance();
            return p.mkExpr(t.loc, .{ .bool_lit = t.text[0] == 't' });
        }
        if (t.isIdent("this")) {
            _ = p.advance();
            return p.mkExpr(t.loc, .this);
        }
        if (t.kind == .identifier and isReserved(t.text)) {
            return p.fail("expected expression, found '{s}'", .{t.text});
        }
        // Type used as a constructor: `float4(...)`, `vector<int, 2>(...)`.
        if (p.scanType(p.pos)) |end| {
            if (p.toks[end].kind == .l_paren) {
                const ty = try p.parseType();
                const args = try p.parseArgs();
                return p.mkExpr(t.loc, .{ .construct = .{ .type = ty, .args = args } });
            }
        }
        const name = try p.parseName();
        // Explicit template arguments: `f<float>(x)`.
        if (p.at(.less) and p.isTemplateName(name.last())) {
            const targs = try p.parseTemplateArgs();
            if (!p.at(.l_paren)) {
                // Variable template use: `is_same_v<int, bool>`.
                var n = name;
                const args = try p.arena.alloc([]const ast.TemplateArg, n.parts.len);
                for (args, 0..) |*a, i| a.* = if (n.args.len > 0) n.args[i] else &.{};
                args[args.len - 1] = targs;
                n.args = args;
                return p.mkExpr(t.loc, .{ .name = n });
            }
            const callee = try p.mkExpr(t.loc, .{ .name = name });
            const args = try p.parseArgs();
            return p.mkExpr(t.loc, .{ .call = .{ .callee = callee, .args = args, .template_args = targs } });
        }
        return p.mkExpr(t.loc, .{ .name = name });
    }
};

fn describe(t: Token) []const u8 {
    return if (t.kind == .eof) "end of file" else t.text;
}

fn isFloatLiteral(text: []const u8) bool {
    if (text.len > 1 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) return false;
    if (std.mem.indexOfAny(u8, text, ".eE") != null) return true;
    const last = text[text.len - 1];
    return last == 'f' or last == 'F' or last == 'h' or last == 'H';
}

/// Words that can never be identifiers.
fn isReserved(w: []const u8) bool {
    const words = [_][]const u8{
        "if",            "else",    "for",      "while",       "do",        "switch", "case",
        "default",       "break",   "continue", "return",      "discard",   "struct", "class",
        "interface",     "cbuffer", "tbuffer",  "typedef",     "namespace", "enum",   "template",
        "typename",      "true",    "false",    "this",        "sizeof",    "static", "const",
        "uniform",       "extern",  "volatile", "groupshared", "inline",    "using",  "operator",
        "static_assert", "inout",   "in",       "out",
    };
    for (words) |k| if (std.mem.eql(u8, w, k)) return true;
    return false;
}

/// Maps a qualifier keyword to its ast.Qualifiers field name.
fn qualifierField(w: []const u8) ?[]const u8 {
    const map = [_][2][]const u8{
        .{ "const", "const" },                       .{ "static", "static" },                   .{ "uniform", "uniform" },
        .{ "extern", "extern" },                     .{ "volatile", "volatile" },               .{ "precise", "precise" },
        .{ "groupshared", "groupshared" },           .{ "shared", "shared" },                   .{ "in", "in" },
        .{ "out", "out" },                           .{ "inout", "in" },                        .{ "row_major", "row_major" },
        .{ "column_major", "column_major" },         .{ "nointerpolation", "nointerpolation" }, .{ "linear", "linear" },
        .{ "centroid", "centroid" },                 .{ "sample", "sample" },                   .{ "noperspective", "noperspective" },
        .{ "globallycoherent", "globallycoherent" }, .{ "reordercoherent", "reordercoherent" }, .{ "inline", "inline" },
        .{ "export", "export" },                     .{ "point", "point" },                     .{ "line", "line" },
        .{ "triangle", "triangle" },                 .{ "lineadj", "lineadj" },                 .{ "triangleadj", "triangleadj" },
        .{ "vertices", "vertices" },                 .{ "indices", "indices" },                 .{ "primitives", "primitives" },
        .{ "payload", "payload" },
    };
    for (map) |e| if (std.mem.eql(u8, w, e[0])) return e[1];
    return null;
}

/// Qualifiers that are ordinary identifiers unless a type follows.
fn isContextualQualifier(w: []const u8) bool {
    const words = [_][]const u8{
        "precise",  "shared",        "row_major",        "column_major",    "nointerpolation", "linear",     "centroid",
        "sample",   "noperspective", "globallycoherent", "reordercoherent", "export",          "point",      "line",
        "triangle", "lineadj",       "triangleadj",      "vertices",        "indices",         "primitives", "payload",
    };
    for (words) |k| if (std.mem.eql(u8, w, k)) return true;
    return false;
}

const scalar_types = [_][]const u8{
    "bool",           "int",             "uint",     "dword",    "half",      "float",     "double",
    "min16float",     "min10float",      "min16int", "min12int", "min16uint", "int16_t",   "uint16_t",
    "int32_t",        "uint32_t",        "int64_t",  "uint64_t", "float16_t", "float32_t", "float64_t",
    "int8_t4_packed", "uint8_t4_packed",
};

/// Builtin object and template types (resources, streams, ray tracing...).
const object_types = [_][]const u8{
    "vector",                             "matrix",                                "Buffer",
    "RWBuffer",                           "ByteAddressBuffer",                     "RWByteAddressBuffer",
    "StructuredBuffer",                   "RWStructuredBuffer",                    "AppendStructuredBuffer",
    "ConsumeStructuredBuffer",            "Texture1D",                             "Texture1DArray",
    "Texture2D",                          "Texture2DArray",                        "Texture2DMS",
    "Texture2DMSArray",                   "Texture3D",                             "TextureCube",
    "TextureCubeArray",                   "RWTexture1D",                           "RWTexture1DArray",
    "RWTexture2D",                        "RWTexture2DArray",                      "RWTexture3D",
    "RWTexture2DMS",                      "RWTexture2DMSArray",                    "RasterizerOrderedBuffer",
    "RasterizerOrderedByteAddressBuffer", "RasterizerOrderedStructuredBuffer",     "RasterizerOrderedTexture1D",
    "RasterizerOrderedTexture1DArray",    "RasterizerOrderedTexture2D",            "RasterizerOrderedTexture2DArray",
    "RasterizerOrderedTexture3D",         "FeedbackTexture2D",                     "FeedbackTexture2DArray",
    "SamplerState",                       "SamplerComparisonState",                "sampler",
    "sampler1D",                          "sampler2D",                             "sampler3D",
    "samplerCUBE",                        "sampler_state",                         "texture",
    "Texture",                            "ConstantBuffer",                        "TextureBuffer",
    "PointStream",                        "LineStream",                            "TriangleStream",
    "InputPatch",                         "OutputPatch",                           "RaytracingAccelerationStructure",
    "RayDesc",                            "BuiltInTriangleIntersectionAttributes", "RayQuery",
    "string",                             "void",                                  "SubpassInput",
    "SubpassInputMS",                     "NodeOutput",                            "NodeOutputArray",
    "EmptyNodeOutput",                    "EmptyNodeOutputArray",                  "DispatchNodeInputRecord",
    "RWDispatchNodeInputRecord",          "GroupNodeInputRecords",                 "RWGroupNodeInputRecords",
    "ThreadNodeInputRecord",              "RWThreadNodeInputRecord",               "EmptyNodeInput",
    "GroupNodeOutputRecords",             "ThreadNodeOutputRecords",               "StateObjectConfig",
    "GlobalRootSignature",                "LocalRootSignature",                    "SubobjectToExportsAssociation",
    "RaytracingShaderConfig",             "RaytracingPipelineConfig",              "RaytracingPipelineConfig1",
    "TriangleHitGroup",                   "ProceduralPrimitiveHitGroup",           "HitObject",
    "SpirvType",                          "SpirvOpaqueType",                       "Literal",
    "integral_constant",                  "ext_type",                              "ext_result_id",
    "BufferPointer",                      "SampledTexture2D",                      "SampledTexture2DArray",
    "SampledTexture1D",                   "SampledTexture1DArray",                 "SampledTexture3D",
    "SampledTextureCUBE",                 "SampledTextureCUBEArray",               "SampledTexture2DMS",
    "SampledTexture2DMSArray",            "WorkgroupSpirvPointer",                 "auto",
    "__builtin_LinAlgMatrix",             "BuiltInTrianglePositions",
};

/// Templates among the builtin object types.
const template_types = [_][]const u8{
    "vector",                          "matrix",                            "Buffer",
    "RWBuffer",                        "StructuredBuffer",                  "RWStructuredBuffer",
    "AppendStructuredBuffer",          "ConsumeStructuredBuffer",           "Texture1D",
    "Texture1DArray",                  "Texture2D",                         "Texture2DArray",
    "Texture2DMS",                     "Texture2DMSArray",                  "Texture3D",
    "TextureCube",                     "TextureCubeArray",                  "RWTexture1D",
    "RWTexture1DArray",                "RWTexture2D",                       "RWTexture2DArray",
    "RWTexture3D",                     "RWTexture2DMS",                     "RWTexture2DMSArray",
    "RasterizerOrderedBuffer",         "RasterizerOrderedStructuredBuffer", "RasterizerOrderedTexture1D",
    "RasterizerOrderedTexture1DArray", "RasterizerOrderedTexture2D",        "RasterizerOrderedTexture2DArray",
    "RasterizerOrderedTexture3D",      "FeedbackTexture2D",                 "FeedbackTexture2DArray",
    "ConstantBuffer",                  "TextureBuffer",                     "PointStream",
    "LineStream",                      "TriangleStream",                    "InputPatch",
    "OutputPatch",                     "RayQuery",                          "SubpassInput",
    "SubpassInputMS",                  "NodeOutput",                        "NodeOutputArray",
    "DispatchNodeInputRecord",         "RWDispatchNodeInputRecord",         "GroupNodeInputRecords",
    "RWGroupNodeInputRecords",         "ThreadNodeInputRecord",             "RWThreadNodeInputRecord",
    "GroupNodeOutputRecords",          "ThreadNodeOutputRecords",           "SpirvType",
    "SpirvOpaqueType",                 "Literal",                           "integral_constant",
    "BufferPointer",                   "SampledTexture2D",                  "SampledTexture2DArray",
    "SampledTexture1D",                "SampledTexture1DArray",             "SampledTexture3D",
    "SampledTextureCUBE",              "SampledTextureCUBEArray",           "SampledTexture2DMS",
    "SampledTexture2DMSArray",         "ext_result_id",                     "ext_type",
    "WorkgroupSpirvPointer",
};

/// Builtin function templates called with explicit arguments.
const template_funcs = [_][]const u8{ "RawBufferLoad", "RawBufferStore", "static_pointer_cast", "reinterpret_pointer_cast" };

fn inList(list: []const []const u8, w: []const u8) bool {
    for (list) |k| if (std.mem.eql(u8, w, k)) return true;
    return false;
}

fn isNumericScalar(w: []const u8) bool {
    return inList(&scalar_types, w) and !std.mem.endsWith(u8, w, "_packed");
}

/// Scalars, `<scalar><1-4>` vectors, `<scalar><1-4>x<1-4>` matrices and
/// builtin object types.
pub fn isBuiltinType(w: []const u8) bool {
    if (inList(&scalar_types, w) or inList(&object_types, w)) return true;
    if (w.len < 2) return false;
    const last = w[w.len - 1];
    if (last < '1' or last > '4') return false;
    if (w.len >= 4 and w[w.len - 2] == 'x' and w[w.len - 3] >= '1' and w[w.len - 3] <= '4') {
        if (isNumericScalar(w[0 .. w.len - 3])) return true;
    }
    return isNumericScalar(w[0 .. w.len - 1]);
}

fn isBuiltinTemplate(w: []const u8) bool {
    return inList(&template_types, w) or inList(&template_funcs, w);
}

fn unsignedName(a: Allocator, base: []const u8) Allocator.Error![]const u8 {
    if (std.mem.eql(u8, base, "int")) return "uint";
    if (std.mem.startsWith(u8, base, "int")) return std.mem.concat(a, u8, &.{ "u", base });
    if (std.mem.startsWith(u8, base, "min16int")) return "min16uint";
    return base;
}

// -------------------------------------------------------------------------
// Tests

const testing = std.testing;
const ast_dump = @import("ast_dump.zig");

const TestParse = struct {
    mfs: source.MemoryFs = .{},
    sm: source.SourceManager = undefined,
    diags: Diagnostics = undefined,
    arena: std.heap.ArenaAllocator = undefined,
    out: std.Io.Writer.Allocating = undefined,

    fn run(t: *TestParse, text: []const u8) ![]const u8 {
        const gpa = testing.allocator;
        t.sm = .init(gpa, t.mfs.fileSystem());
        t.diags = .init(gpa);
        t.arena = .init(gpa);
        const a = t.arena.allocator();
        var pp = Preprocessor.init(a, &t.sm, &t.diags, .{});
        try pp.enterMainText("t.hlsl", text);
        var p = try Parser.fromPreprocessor(a, &t.diags, &pp);
        const tu = try p.parseTranslationUnit();
        t.out = .init(a);
        try ast_dump.dumpUnit(&t.out.writer, tu);
        return std.mem.trimEnd(u8, t.out.written(), "\n");
    }

    fn deinit(t: *TestParse) void {
        t.arena.deinit();
        t.diags.deinit();
        t.sm.deinit();
    }
};

fn expectAst(text: []const u8, expected: []const u8) !void {
    var t: TestParse = .{};
    defer t.deinit();
    const got = try t.run(text);
    for (t.diags.list.items) |d| std.debug.print("unexpected diagnostic: {s}\n", .{d.message});
    try testing.expectEqualStrings(expected, got);
    try testing.expectEqual(@as(u32, 0), t.diags.error_count);
}

test "declarations vs expressions and casts" {
    try expectAst(
        \\struct S { float a; };
        \\void f(int a) { S s; (S)a; (a) + 1; float2(1, 2); a < 3; }
    ,
        \\(struct S
        \\  (var float a))
        \\(func void f(int a)
        \\  {
        \\    (var S s)
        \\    (cast S a)
        \\    (add a 1)
        \\    (construct float2 1 2)
        \\    (lt a 3)})
    );
}

test "templates, operators and bitfields parse" {
    try expectAst(
        \\template <typename T, uint N = 2> struct Pair { T v[N]; uint flags : 4; };
        \\template <typename T> T twice(T x) { return x + x; }
        \\struct V { float x; V operator+(V o) { V r; r.x = x + o.x; return r; } };
        \\void g() { Pair<float, 3> p; float y = twice<float>(1.0); Texture2D<vector<float, 4>> t; }
    ,
        \\(struct template<typename T, uint N> Pair
        \\  (var T v[N])
        \\  (var uint flags : 4))
        \\(func template<typename T> T twice(T x)
        \\  {
        \\    (return (add x x))})
        \\(struct V
        \\  (var float x)
        \\  (func V operator+(V o)
        \\    {
        \\      (var V r)
        \\      (= (. r x) (add x (. o x)))
        \\      (return r)}))
        \\(func void g()
        \\  {
        \\    (var Pair<float, 3> p)
        \\    (var float y = (call twice<float> 1.0))
        \\    (var Texture2D<vector<float, 4>> t)})
    );
}

test "contextual keywords stay identifiers" {
    try expectAst(
        \\void f(float sample, float line) { float point = sample + line; point = 1; }
    ,
        \\(func void f(float sample, float line)
        \\  {
        \\    (var float point = (add sample line))
        \\    (= point 1)})
    );
}

test "namespaces, enums, typedef, using" {
    try expectAst(
        \\namespace N { struct T { int i; }; enum class E : uint { A, B = 3 }; }
        \\typedef N::T Alias;
        \\using F4 = float4;
        \\Alias a; F4 b; uint e = (uint)N::E::B;
    ,
        \\(namespace N
        \\  (struct T
        \\    (var int i))
        \\  (enum class E A B=3))
        \\(typedef N::T Alias)
        \\(typedef float4 F4)
        \\(var Alias a)
        \\(var F4 b)
        \\(var uint e = (cast uint N::E::B))
    );
}

test "syntax errors recover at statement boundaries" {
    var t: TestParse = .{};
    defer t.deinit();
    const got = try t.run("void f() { int a = ; a = 2; }\nint b;");
    try testing.expectEqual(@as(u32, 1), t.diags.error_count);
    try testing.expectEqualStrings(
        \\(func void f()
        \\  {
        \\    (= a 2)})
        \\(var int b)
    , got);
}

test "typedef struct forms" {
    try expectAst(
        \\struct Node;
        \\typedef struct Node Node;
        \\typedef struct { int a; } Anon[2];
        \\Node n; Anon x;
    ,
        \\(struct Node <fwd>)
        \\(typedef Node Node)
        \\(struct __anon_struct_1
        \\  (var int a))
        \\(typedef __anon_struct_1 Anon[2])
        \\(var Node n)
        \\(var Anon x)
    );
}

test "C++-isms found in the corpus" {
    try expectAst(
        \\template <class, class> static const bool is_same_v = false;
        \\struct B { float x; };
        \\void f(ByteAddressBuffer buf) {
        \\  bool b = is_same_v<int, bool>;
        \\  B v = buf.template Load<B>(0);
        \\  if (int d = 3) { d = 1; }
        \\  float2x2 m = (row_major float2x2)0;
        \\}
    ,
        \\(var template<typename , typename > const static bool is_same_v = false)
        \\(struct B
        \\  (var float x))
        \\(func void f(ByteAddressBuffer buf)
        \\  {
        \\    (var bool b = is_same_v<int, bool>)
        \\    (var B v = (call (. buf Load)<B> 0))
        \\    (if (var int d = 3) d
        \\      {
        \\        (= d 1)})
        \\    (var float2x2 m = (cast float2x2 0))})
    );
}
