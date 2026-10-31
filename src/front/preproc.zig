//! C preprocessor for HLSL, modelled on clang's: a stack of token sources
//! (files and macro expansions), with macros disabled while their expansion
//! is being rescanned and identifiers painted `no_expand` when they name a
//! disabled macro.

const std = @import("std");
const Allocator = std.mem.Allocator;
const source = @import("source.zig");
const lexer = @import("lexer.zig");
const Diagnostics = @import("../diag.zig").Diagnostics;
const Token = lexer.Token;
const Kind = lexer.Kind;
const Loc = source.Loc;

pub const Define = struct {
    name: []const u8,
    /// null means `1`, as with `-D NAME`.
    value: ?[]const u8 = null,
};

pub const Options = struct {
    defines: []const Define = &.{},
    include_dirs: []const []const u8 = &.{},
    /// DXIL::ShaderKind of the target profile.
    stage: u32 = 5,
    major: u32 = 6,
    minor: u32 = 0,
    spirv: bool = false,
    enable_16bit: bool = false,
};

const Builtin = enum {
    none,
    line,
    file,
    counter,
    include_level,
    base_file,
    /// `__has_feature(x)`: function-like, valid anywhere (as in clang).
    has_feature,
    /// `__has_builtin(x)` and friends: always 0.
    has_nothing,
};

const Macro = struct {
    name: []const u8,
    function_like: bool = false,
    variadic: bool = false,
    params: []const []const u8 = &.{},
    body: []const Token = &.{},
    builtin: Builtin = .none,
    disabled: bool = false,
    loc: Loc = .none,

    fn paramIndex(m: *const Macro, t: Token) ?usize {
        if (!m.function_like or t.kind != .identifier) return null;
        for (m.params, 0..) |p, i| {
            if (std.mem.eql(u8, p, t.text)) return i;
        }
        return null;
    }

    fn sameDefinition(a: *const Macro, b: *const Macro) bool {
        if (a.function_like != b.function_like or a.variadic != b.variadic) return false;
        if (a.params.len != b.params.len or a.body.len != b.body.len) return false;
        for (a.params, b.params) |x, y| if (!std.mem.eql(u8, x, y)) return false;
        for (a.body, b.body, 0..) |x, y, i| {
            if (x.kind != y.kind or !std.mem.eql(u8, x.text, y.text)) return false;
            if (i > 0 and x.flags.space != y.flags.space) return false;
        }
        return true;
    }
};

const Context = struct {
    tokens: []const Token,
    pos: usize = 0,
    /// Macro re-enabled when this context is exhausted.
    macro: ?*Macro = null,
    /// Barrier for isolated expansion (macro arguments, #if): returns eof
    /// instead of reading past it.
    barrier: bool = false,
};

const Cond = struct {
    /// Some group in this #if chain has been taken.
    taken: bool,
    seen_else: bool,
    loc: Loc,
};

const IncludeFrame = struct {
    lex: lexer.Lexer,
    /// Directory of this file, for quoted includes.
    dir: []const u8,
    cond_base: usize,
};

const LineOverride = struct {
    /// Physical line of the #line directive.
    phys_line: u32,
    line: u32,
    name: ?[]const u8,
};

pub const Error = Allocator.Error;

pub const PresumedLoc = struct { file: []const u8, line: u32 };

const max_include_depth = 200;
const embedded_prefix = "<built-in:hlsl>/";
const hlsl_headers = @import("hlsl_headers");

pub const Preprocessor = struct {
    arena: Allocator,
    sm: *source.SourceManager,
    diags: *Diagnostics,
    opts: Options,
    macros: std.StringHashMapUnmanaged(*Macro) = .empty,
    contexts: std.ArrayList(Context) = .empty,
    includes: std.ArrayList(IncludeFrame) = .empty,
    conds: std.ArrayList(Cond) = .empty,
    pushback: std.ArrayList(Raw) = .empty,
    pragma_once: std.StringHashMapUnmanaged(void) = .empty,
    line_overrides: std.AutoHashMapUnmanaged(source.FileId, std.ArrayList(LineOverride)) = .empty,
    counter: u32 = 0,
    main_file: ?source.FileId = null,

    const Raw = struct { tok: Token, from_file: bool };

    /// `arena` owns everything the preprocessor allocates, including the
    /// text of returned tokens.
    pub fn init(arena: Allocator, sm: *source.SourceManager, diags: *Diagnostics, opts: Options) Preprocessor {
        return .{ .arena = arena, .sm = sm, .diags = diags, .opts = opts };
    }

    /// Enter the main file. Returns false (with a diagnostic) if it cannot
    /// be read.
    pub fn enterMainFile(pp: *Preprocessor, path: []const u8) !bool {
        const id = try pp.sm.load(path) orelse {
            pp.diags.err(.none, "cannot open file '{s}'", .{path});
            return false;
        };
        try pp.enterFileId(id);
        pp.main_file = id;
        try pp.enterPredefines();
        return true;
    }

    /// Enter in-memory main file text (used by tests and the library API).
    pub fn enterMainText(pp: *Preprocessor, path: []const u8, text: []const u8) !void {
        const id = try pp.sm.addFile(path, text);
        try pp.enterFileId(id);
        pp.main_file = id;
        try pp.enterPredefines();
    }

    fn enterFileId(pp: *Preprocessor, id: source.FileId) !void {
        const f = pp.sm.file(id);
        try pp.includes.append(pp.arena, .{
            .lex = .init(f.text, id),
            .dir = std.fs.path.dirname(f.path) orelse ".",
            .cond_base = pp.conds.items.len,
        });
    }

    /// Predefined macros are processed as a pseudo-file of #defines entered
    /// on top of the main file, so they are seen first.
    fn enterPredefines(pp: *Preprocessor) !void {
        const builtins = [_]struct { []const u8, Builtin }{
            .{ "__LINE__", .line },                        .{ "__FILE__", .file },
            .{ "__COUNTER__", .counter },                  .{ "__INCLUDE_LEVEL__", .include_level },
            .{ "__BASE_FILE__", .base_file },              .{ "__has_feature", .has_feature },
            .{ "__has_extension", .has_feature },          .{ "__has_builtin", .has_nothing },
            .{ "__has_attribute", .has_nothing },          .{ "__has_cpp_attribute", .has_nothing },
            .{ "__has_declspec_attribute", .has_nothing },
        };
        for (builtins) |b| {
            const m = try pp.arena.create(Macro);
            m.* = .{ .name = b[0], .builtin = b[1] };
            try pp.macros.put(pp.arena, b[0], m);
        }

        var text: std.Io.Writer.Allocating = .init(pp.arena);
        const w = &text.writer;
        const o = pp.opts;
        try w.writeAll(
            \\#define __hlsl_dx_compiler 1
            \\#define __clang__ 1
            \\#define __clang_major__ 3
            \\#define __clang_minor__ 7
            \\#define __clang_patchlevel__ 0
            \\#define __llvm__ 1
            \\#define __DXC_VERSION_MAJOR 1
            \\#define __DXC_VERSION_MINOR 10
            \\#define __DXC_VERSION_RELEASE 0
            \\#define __DXC_VERSION_COMMITS 0
            \\#define __HLSL_VERSION 2021
            \\#define __SHADER_STAGE_VERTEX 1
            \\#define __SHADER_STAGE_PIXEL 0
            \\#define __SHADER_STAGE_GEOMETRY 2
            \\#define __SHADER_STAGE_HULL 3
            \\#define __SHADER_STAGE_DOMAIN 4
            \\#define __SHADER_STAGE_COMPUTE 5
            \\#define __SHADER_STAGE_AMPLIFICATION 14
            \\#define __SHADER_STAGE_MESH 13
            \\#define __SHADER_STAGE_LIBRARY 6
            \\
        );
        try w.print("#define __SHADER_TARGET_STAGE {d}\n#define __SHADER_TARGET_MAJOR {d}\n#define __SHADER_TARGET_MINOR {d}\n", .{ o.stage, o.major, o.minor });
        if (o.enable_16bit) try w.writeAll("#define __HLSL_ENABLE_16_BIT 1\n");
        if (o.spirv) try w.writeAll("#define __spirv__ 1\n#define __SPIRV_MAJOR_VERSION__ 1\n#define __SPIRV_MINOR_VERSION__ 0\n");
        for (o.defines) |d| try w.print("#define {s} {s}\n", .{ d.name, d.value orelse "1" });

        const id = try pp.sm.addFile("<built-in>", text.written());
        try pp.enterFileId(id);
    }

    // ---------------------------------------------------------------------
    // Raw token sources

    fn currentLexer(pp: *Preprocessor) ?*lexer.Lexer {
        if (pp.includes.items.len == 0) return null;
        return &pp.includes.items[pp.includes.items.len - 1].lex;
    }

    fn lexRaw(pp: *Preprocessor) Error!Raw {
        if (pp.pushback.pop()) |r| return r;
        while (pp.contexts.items.len > 0) {
            const ctx = &pp.contexts.items[pp.contexts.items.len - 1];
            if (ctx.barrier) return .{ .tok = .{ .kind = .eof, .text = "", .loc = .none }, .from_file = false };
            if (ctx.pos < ctx.tokens.len) {
                defer ctx.pos += 1;
                return .{ .tok = ctx.tokens[ctx.pos], .from_file = false };
            }
            if (ctx.macro) |m| m.disabled = false;
            _ = pp.contexts.pop();
        }
        while (pp.includes.items.len > 0) {
            const frame = &pp.includes.items[pp.includes.items.len - 1];
            const t = frame.lex.next();
            if (t.kind != .eof) return .{ .tok = t, .from_file = true };
            // End of file: diagnose unterminated conditionals, pop.
            while (pp.conds.items.len > frame.cond_base) {
                const c = pp.conds.pop().?;
                pp.diags.err(c.loc, "unterminated conditional directive", .{});
            }
            if (pp.includes.items.len == 1) {
                return .{ .tok = t, .from_file = true };
            }
            _ = pp.includes.pop();
        }
        return .{ .tok = .{ .kind = .eof, .text = "", .loc = .none }, .from_file = true };
    }

    /// Raw token with directives handled. `#pragma` lines come back as
    /// `.pragma` tokens.
    fn lexRawSkipDirectives(pp: *Preprocessor) Error!Raw {
        while (true) {
            const r = try pp.lexRaw();
            if (r.from_file and r.tok.kind == .hash and r.tok.flags.bol) {
                if (try pp.handleDirective(r.tok)) |pragma| return .{ .tok = pragma, .from_file = true };
                continue;
            }
            return r;
        }
    }

    /// Next fully macro-expanded token.
    pub fn next(pp: *Preprocessor) Error!Token {
        while (true) {
            const r = try pp.lexRawSkipDirectives();
            const t = r.tok;
            if (t.kind != .identifier or t.flags.no_expand) return t;
            const m = pp.macros.get(t.text) orelse return t;
            if (m.disabled) {
                var painted = t;
                painted.flags.no_expand = true;
                return painted;
            }
            if (try pp.expandMacro(m, t)) continue;
            return t;
        }
    }

    // ---------------------------------------------------------------------
    // Macro expansion

    fn expandMacro(pp: *Preprocessor, m: *Macro, name: Token) Error!bool {
        if (m.builtin == .has_feature or m.builtin == .has_nothing) {
            return pp.expandFeatureCheck(m, name);
        }
        if (m.builtin != .none) {
            const tok = try pp.builtinToken(m.builtin, name);
            const toks = try pp.arena.alloc(Token, 1);
            toks[0] = tok;
            try pp.contexts.append(pp.arena, .{ .tokens = toks });
            return true;
        }

        var args: ?[]const []const Token = null;
        if (m.function_like) {
            const r = try pp.lexRawSkipDirectives();
            if (r.tok.kind != .l_paren) {
                try pp.pushback.append(pp.arena, r);
                return false;
            }
            args = try pp.collectArgs(m, name) orelse return true; // error: drop invocation
        }

        const result = try pp.substitute(m, args);
        for (result, 0..) |*t, i| {
            t.loc = name.loc;
            if (i == 0) {
                t.flags.space = name.flags.space;
                t.flags.bol = name.flags.bol;
            } else t.flags.bol = false;
        }
        m.disabled = true;
        try pp.contexts.append(pp.arena, .{ .tokens = result, .macro = m });
        return true;
    }

    /// `__has_feature(name)` and similar: consume `( ident )`, push 0 or 1.
    fn expandFeatureCheck(pp: *Preprocessor, m: *const Macro, name: Token) Error!bool {
        const open = try pp.lexRawSkipDirectives();
        if (open.tok.kind != .l_paren) {
            pp.diags.err(name.loc, "builtin feature check macro requires a parenthesized identifier", .{});
            try pp.pushback.append(pp.arena, open);
            return false;
        }
        const ident = try pp.lexRawSkipDirectives();
        const close = try pp.lexRawSkipDirectives();
        if (ident.tok.kind != .identifier or close.tok.kind != .r_paren) {
            pp.diags.err(name.loc, "builtin feature check macro requires a parenthesized identifier", .{});
            if (close.tok.kind != .r_paren) try pp.pushback.append(pp.arena, close);
            return true;
        }
        const known = m.builtin == .has_feature and pp.opts.spirv and std.mem.eql(u8, ident.tok.text, "hlsl_vk_buffer_pointer");
        const toks = try pp.arena.alloc(Token, 1);
        toks[0] = numberToken(if (known) "1" else "0", name);
        try pp.contexts.append(pp.arena, .{ .tokens = toks });
        return true;
    }

    /// Collect raw argument tokens up to the matching ')'. Null on error.
    fn collectArgs(pp: *Preprocessor, m: *const Macro, name: Token) Error!?[]const []const Token {
        var args: std.ArrayList([]const Token) = .empty;
        var cur: std.ArrayList(Token) = .empty;
        var depth: u32 = 0;
        while (true) {
            const r = try pp.lexRawSkipDirectives();
            var t = r.tok;
            switch (t.kind) {
                .eof => {
                    pp.diags.err(name.loc, "unterminated function-like macro invocation '{s}'", .{m.name});
                    if (!r.from_file) try pp.pushback.append(pp.arena, r);
                    return null;
                },
                .l_paren => depth += 1,
                .r_paren => {
                    if (depth == 0) break;
                    depth -= 1;
                },
                .comma => if (depth == 0 and !(m.variadic and args.items.len + 1 >= m.params.len)) {
                    try args.append(pp.arena, try cur.toOwnedSlice(pp.arena));
                    continue;
                },
                else => {},
            }
            // Identifiers naming a currently disabled macro stay painted.
            if (t.kind == .identifier and !t.flags.no_expand) {
                if (pp.macros.get(t.text)) |am| {
                    if (am.disabled) t.flags.no_expand = true;
                }
            }
            t.flags.bol = false;
            try cur.append(pp.arena, t);
        }
        try args.append(pp.arena, try cur.toOwnedSlice(pp.arena));

        var n = args.items.len;
        if (m.params.len == 0 and n == 1 and args.items[0].len == 0) n = 0;
        if (m.variadic) {
            if (n + 1 < m.params.len) {
                pp.diags.err(name.loc, "too few arguments provided to function-like macro invocation '{s}'", .{m.name});
                return null;
            }
            while (args.items.len < m.params.len) try args.append(pp.arena, &.{});
        } else if (n != m.params.len) {
            if (n < m.params.len) {
                pp.diags.err(name.loc, "too few arguments provided to function-like macro invocation '{s}'", .{m.name});
            } else {
                pp.diags.err(name.loc, "too many arguments provided to function-like macro invocation '{s}'", .{m.name});
            }
            return null;
        }
        return args.items[0..m.params.len];
    }

    /// Fully macro-expand `tokens` in isolation.
    fn expandIsolated(pp: *Preprocessor, tokens: []const Token) Error![]Token {
        const saved_pushback = pp.pushback;
        pp.pushback = .empty;
        defer pp.pushback = saved_pushback;

        const base = pp.contexts.items.len;
        try pp.contexts.append(pp.arena, .{ .tokens = &.{}, .barrier = true });
        try pp.contexts.append(pp.arena, .{ .tokens = tokens });
        var out: std.ArrayList(Token) = .empty;
        while (true) {
            const t = try pp.next();
            if (t.kind == .eof and pp.contexts.items.len == base + 1 and pp.contexts.items[base].barrier) break;
            try out.append(pp.arena, t);
        }
        _ = pp.contexts.pop();
        return out.items;
    }

    fn substitute(pp: *Preprocessor, m: *const Macro, args: ?[]const []const Token) Error![]Token {
        var out: std.ArrayList(Token) = .empty;
        // Parallel flags: true where `out[i]` is a ## operator from the body.
        var paste: std.ArrayList(bool) = .empty;
        var expanded_cache: []?[]Token = &.{};
        if (args) |a| {
            expanded_cache = try pp.arena.alloc(?[]Token, a.len);
            @memset(expanded_cache, null);
        }

        const body = m.body;
        var i: usize = 0;
        while (i < body.len) : (i += 1) {
            const t = body[i];
            if (args) |a| {
                if (t.kind == .hash and i + 1 < body.len) {
                    if (m.paramIndex(body[i + 1])) |p| {
                        var s = try pp.stringify(a[p], t.loc);
                        s.flags.space = t.flags.space;
                        try out.append(pp.arena, s);
                        try paste.append(pp.arena, false);
                        i += 1;
                        continue;
                    }
                }
                // GNU `, ## __VA_ARGS__`: drop the comma when empty.
                if (m.variadic and t.kind == .comma and i + 2 < body.len and body[i + 1].kind == .hash_hash) {
                    if (m.paramIndex(body[i + 2])) |p| if (p == m.params.len - 1) {
                        if (a[p].len != 0) {
                            try out.append(pp.arena, t);
                            try paste.append(pp.arena, false);
                            for (a[p]) |at| {
                                try out.append(pp.arena, at);
                                try paste.append(pp.arena, false);
                            }
                        }
                        i += 2;
                        continue;
                    };
                }
                if (m.paramIndex(t)) |p| {
                    const next_paste = i + 1 < body.len and body[i + 1].kind == .hash_hash;
                    const prev_paste = i > 0 and body[i - 1].kind == .hash_hash;
                    const toks: []const Token = if (next_paste or prev_paste) a[p] else blk: {
                        if (expanded_cache[p] == null) expanded_cache[p] = try pp.expandIsolated(a[p]);
                        break :blk expanded_cache[p].?;
                    };
                    if (toks.len == 0) {
                        // Placemarker, removed after pasting.
                        try out.append(pp.arena, .{ .kind = .invalid, .text = "", .loc = t.loc });
                        try paste.append(pp.arena, false);
                    }
                    for (toks, 0..) |at, j| {
                        var c = at;
                        if (j == 0) c.flags.space = t.flags.space;
                        try out.append(pp.arena, c);
                        try paste.append(pp.arena, false);
                    }
                    continue;
                }
            }
            try out.append(pp.arena, t);
            try paste.append(pp.arena, t.kind == .hash_hash);
        }

        // Token pasting.
        var res: std.ArrayList(Token) = .empty;
        var k: usize = 0;
        while (k < out.items.len) : (k += 1) {
            if (paste.items[k] and res.items.len > 0 and k + 1 < out.items.len) {
                const lhs = res.pop().?;
                const rhs = out.items[k + 1];
                k += 1;
                try res.append(pp.arena, try pp.pasteTokens(lhs, rhs));
                continue;
            }
            try res.append(pp.arena, out.items[k]);
        }
        // Drop placemarkers.
        var w: usize = 0;
        for (res.items) |t| {
            if (t.kind == .invalid and t.text.len == 0) continue;
            res.items[w] = t;
            w += 1;
        }
        return res.items[0..w];
    }

    fn pasteTokens(pp: *Preprocessor, lhs: Token, rhs: Token) Error!Token {
        if (lhs.kind == .invalid and lhs.text.len == 0) return rhs;
        if (rhs.kind == .invalid and rhs.text.len == 0) return lhs;
        const text = try std.mem.concat(pp.arena, u8, &.{ lhs.text, rhs.text });
        var l = lexer.Lexer.init(text, lhs.loc.file);
        const t = l.next();
        var result: Token = .{ .kind = t.kind, .flags = lhs.flags, .text = text, .loc = lhs.loc };
        result.flags.no_expand = false;
        if (t.text.len != text.len) {
            pp.diags.err(lhs.loc, "pasting formed '{s}', an invalid preprocessing token", .{text});
            result.kind = .invalid;
        }
        return result;
    }

    fn stringify(pp: *Preprocessor, toks: []const Token, loc: Loc) Error!Token {
        var buf: std.ArrayList(u8) = .empty;
        try buf.append(pp.arena, '"');
        for (toks, 0..) |t, i| {
            if (i > 0 and t.flags.space) try buf.append(pp.arena, ' ');
            if (t.kind == .string or t.kind == .char) {
                for (t.text) |c| {
                    if (c == '"' or c == '\\') try buf.append(pp.arena, '\\');
                    try buf.append(pp.arena, c);
                }
            } else try buf.appendSlice(pp.arena, t.text);
        }
        try buf.append(pp.arena, '"');
        return .{ .kind = .string, .text = buf.items, .loc = loc };
    }

    fn builtinToken(pp: *Preprocessor, b: Builtin, name: Token) Error!Token {
        var tok: Token = .{ .kind = .number, .flags = name.flags, .text = "", .loc = name.loc };
        switch (b) {
            .none, .has_feature, .has_nothing => unreachable,
            .line => tok.text = try std.fmt.allocPrint(pp.arena, "{d}", .{pp.presumedLoc(name.loc).line}),
            .counter => {
                tok.text = try std.fmt.allocPrint(pp.arena, "{d}", .{pp.counter});
                pp.counter += 1;
            },
            .include_level => tok.text = try std.fmt.allocPrint(pp.arena, "{d}", .{pp.includes.items.len -| 1}),
            .file, .base_file => {
                const path = if (b == .file) pp.presumedLoc(name.loc).file else pp.sm.file(pp.main_file.?).path;
                tok.kind = .string;
                tok.text = try quoteString(pp.arena, path);
            },
        }
        return tok;
    }

    pub fn presumedLoc(pp: *const Preprocessor, loc: Loc) PresumedLoc {
        if (loc.isNone()) return .{ .file = "<unknown>", .line = 0 };
        const phys = pp.sm.lineCol(loc).line;
        var result: PresumedLoc = .{ .file = pp.sm.file(loc.file).path, .line = phys };
        if (pp.line_overrides.get(loc.file)) |list| {
            for (list.items) |ov| {
                if (ov.phys_line >= phys) break;
                result.line = ov.line + (phys - ov.phys_line - 1);
                if (ov.name) |n| result.file = n;
            }
        }
        return result;
    }

    // ---------------------------------------------------------------------
    // Directives

    /// Raw tokens up to the end of the directive line, from the current file.
    fn directiveTokens(pp: *Preprocessor) Error![]Token {
        const lx = pp.currentLexer().?;
        var out: std.ArrayList(Token) = .empty;
        while (true) {
            const saved = lx.*;
            const t = lx.next();
            if (t.kind == .eof or t.flags.bol) {
                lx.* = saved;
                break;
            }
            try out.append(pp.arena, t);
        }
        return out.items;
    }

    fn skipRestOfLine(pp: *Preprocessor) void {
        pp.currentLexer().?.skipLine();
    }

    /// Handle a directive whose `#` has been read. Returns a token for
    /// `#pragma` lines that are passed through.
    fn handleDirective(pp: *Preprocessor, hash: Token) Error!?Token {
        const lx = pp.currentLexer().?;
        const saved = lx.*;
        const name = lx.next();
        if (name.kind == .eof or name.flags.bol) {
            lx.* = saved; // null directive
            return null;
        }
        if (name.kind != .identifier) {
            pp.diags.err(name.loc, "invalid preprocessing directive", .{});
            pp.skipRestOfLine();
            return null;
        }
        const d = name.text;
        if (std.mem.eql(u8, d, "define")) {
            try pp.handleDefine();
        } else if (std.mem.eql(u8, d, "undef")) {
            const toks = try pp.directiveTokens();
            if (toks.len == 0 or toks[0].kind != .identifier) {
                pp.diags.err(name.loc, "macro name missing", .{});
            } else _ = pp.macros.remove(toks[0].text);
        } else if (std.mem.eql(u8, d, "include")) {
            try pp.handleInclude(name);
        } else if (std.mem.eql(u8, d, "if")) {
            const v = try pp.evalCondition(name);
            try pp.conds.append(pp.arena, .{ .taken = v, .seen_else = false, .loc = hash.loc });
            if (!v) try pp.skipGroup();
        } else if (std.mem.eql(u8, d, "ifdef") or std.mem.eql(u8, d, "ifndef")) {
            const toks = try pp.directiveTokens();
            var v = false;
            if (toks.len == 0 or toks[0].kind != .identifier) {
                pp.diags.err(name.loc, "macro name missing", .{});
            } else v = pp.macros.contains(toks[0].text);
            if (d.len == 6) v = !v; // ifndef
            try pp.conds.append(pp.arena, .{ .taken = v, .seen_else = false, .loc = hash.loc });
            if (!v) try pp.skipGroup();
        } else if (std.mem.eql(u8, d, "elif") or std.mem.eql(u8, d, "else")) {
            // Reached from an active group: the chain is done, skip the rest.
            if (!pp.inFileConditional()) {
                pp.diags.err(hash.loc, "#{s} without #if", .{d});
                pp.skipRestOfLine();
                return null;
            }
            const c = &pp.conds.items[pp.conds.items.len - 1];
            if (c.seen_else) pp.diags.err(hash.loc, "#{s} after #else", .{d});
            if (std.mem.eql(u8, d, "else")) c.seen_else = true;
            pp.skipRestOfLine();
            try pp.skipGroup();
        } else if (std.mem.eql(u8, d, "endif")) {
            if (!pp.inFileConditional()) {
                pp.diags.err(hash.loc, "#endif without #if", .{});
            } else _ = pp.conds.pop();
            pp.skipRestOfLine();
        } else if (std.mem.eql(u8, d, "pragma")) {
            const body = lx.restOfLine();
            if (std.mem.eql(u8, body, "once")) {
                const key = try pp.fileKey(pp.sm.file(lx.file).path);
                try pp.pragma_once.put(pp.arena, key, {});
                return null;
            }
            return .{ .kind = .pragma, .flags = .{ .bol = true }, .text = body, .loc = hash.loc };
        } else if (std.mem.eql(u8, d, "error")) {
            pp.diags.err(hash.loc, "{s}", .{lx.restOfLine()});
        } else if (std.mem.eql(u8, d, "warning")) {
            pp.diags.warn(hash.loc, "{s}", .{lx.restOfLine()});
        } else if (std.mem.eql(u8, d, "line")) {
            try pp.handleLine(name);
        } else {
            pp.diags.err(name.loc, "invalid preprocessing directive", .{});
            pp.skipRestOfLine();
        }
        return null;
    }

    fn inFileConditional(pp: *Preprocessor) bool {
        const frame = pp.includes.items[pp.includes.items.len - 1];
        return pp.conds.items.len > frame.cond_base;
    }

    /// Skip a false group. Stops after an #elif that evaluates true, an
    /// #else (when nothing was taken), or the matching #endif.
    fn skipGroup(pp: *Preprocessor) Error!void {
        const lx = pp.currentLexer().?;
        var depth: u32 = 0;
        while (true) {
            const t = lx.next();
            if (t.kind == .eof) {
                // Put it back so lexRaw sees EOF and diagnoses.
                lx.pos = @intCast(lx.text.len);
                return;
            }
            if (!(t.kind == .hash and t.flags.bol)) {
                lx.skipLine();
                continue;
            }
            const saved = lx.*;
            const d = lx.next();
            if (d.flags.bol or d.kind != .identifier) {
                lx.* = saved;
                continue;
            }
            const name = d.text;
            if (std.mem.startsWith(u8, name, "if")) {
                if (std.mem.eql(u8, name, "if") or std.mem.eql(u8, name, "ifdef") or std.mem.eql(u8, name, "ifndef")) depth += 1;
                lx.skipLine();
                continue;
            }
            if (std.mem.eql(u8, name, "endif")) {
                lx.skipLine();
                if (depth == 0) {
                    _ = pp.conds.pop();
                    return;
                }
                depth -= 1;
                continue;
            }
            if (depth > 0) {
                lx.skipLine();
                continue;
            }
            const c = &pp.conds.items[pp.conds.items.len - 1];
            if (std.mem.eql(u8, name, "else")) {
                lx.skipLine();
                if (c.seen_else) pp.diags.err(t.loc, "#else after #else", .{});
                c.seen_else = true;
                if (!c.taken) {
                    c.taken = true;
                    return;
                }
                continue;
            }
            if (std.mem.eql(u8, name, "elif")) {
                if (c.seen_else) pp.diags.err(t.loc, "#elif after #else", .{});
                if (c.taken) {
                    lx.skipLine();
                    continue;
                }
                if (try pp.evalCondition(d)) {
                    c.taken = true;
                    return;
                }
                continue;
            }
            lx.skipLine();
        }
    }

    fn handleDefine(pp: *Preprocessor) Error!void {
        const lx = pp.currentLexer().?;
        const toks = try pp.directiveTokens();
        if (toks.len == 0 or toks[0].kind != .identifier) {
            pp.diags.err(if (toks.len > 0) toks[0].loc else .none, "macro name must be an identifier", .{});
            return;
        }
        _ = lx;
        const name = toks[0];
        if (std.mem.eql(u8, name.text, "defined")) {
            pp.diags.err(name.loc, "'defined' cannot be used as a macro name", .{});
            return;
        }
        const m = try pp.arena.create(Macro);
        m.* = .{ .name = name.text, .loc = name.loc };
        var i: usize = 1;
        // Function-like only when '(' immediately follows the name.
        if (toks.len > 1 and toks[1].kind == .l_paren and !toks[1].flags.space) {
            m.function_like = true;
            var params: std.ArrayList([]const u8) = .empty;
            i = 2;
            while (true) {
                if (i >= toks.len) {
                    pp.diags.err(name.loc, "missing ')' in macro parameter list", .{});
                    return;
                }
                const t = toks[i];
                i += 1;
                if (t.kind == .r_paren and params.items.len == 0) break;
                if (t.kind == .ellipsis) {
                    m.variadic = true;
                    try params.append(pp.arena, "__VA_ARGS__");
                    if (i >= toks.len or toks[i].kind != .r_paren) {
                        pp.diags.err(t.loc, "missing ')' in macro parameter list", .{});
                        return;
                    }
                    i += 1;
                    break;
                }
                if (t.kind != .identifier) {
                    pp.diags.err(t.loc, "invalid token in macro parameter list", .{});
                    return;
                }
                try params.append(pp.arena, t.text);
                if (i < toks.len and toks[i].kind == .ellipsis) {
                    // Named variadic parameter (GNU): `args...`
                    m.variadic = true;
                    i += 1;
                }
                if (i >= toks.len) continue;
                if (toks[i].kind == .comma) {
                    i += 1;
                    continue;
                }
                if (toks[i].kind == .r_paren) {
                    i += 1;
                    break;
                }
                pp.diags.err(toks[i].loc, "expected comma in macro parameter list", .{});
                return;
            }
            m.params = params.items;
        }
        const body = toks[i..];
        if (body.len > 0) {
            if (body[0].kind == .hash_hash or body[body.len - 1].kind == .hash_hash) {
                pp.diags.err(body[0].loc, "'##' cannot appear at either end of a macro expansion", .{});
                return;
            }
            body[0].flags.space = false;
        }
        for (body) |*t| t.flags.bol = false;
        m.body = body;
        if (pp.macros.get(name.text)) |old| {
            if (old.builtin != .none) {
                pp.diags.warn(name.loc, "redefining builtin macro", .{});
            } else if (!old.sameDefinition(m)) {
                pp.diags.warn(name.loc, "'{s}' macro redefined", .{name.text});
            }
        }
        try pp.macros.put(pp.arena, name.text, m);
    }

    fn handleInclude(pp: *Preprocessor, directive: Token) Error!void {
        const lx = pp.currentLexer().?;
        var spelled: []const u8 = undefined;
        var angled = false;
        if (lx.headerName()) |h| {
            spelled = h.text[1 .. h.text.len - 1];
            angled = true;
            pp.skipRestOfLine();
        } else {
            const raw = try pp.directiveTokens();
            const toks = try pp.expandIsolated(raw);
            if (toks.len >= 1 and toks[0].kind == .string and toks[0].text.len >= 2) {
                spelled = toks[0].text[1 .. toks[0].text.len - 1];
            } else if (toks.len >= 2 and toks[0].kind == .less) {
                var buf: std.ArrayList(u8) = .empty;
                for (toks[1..]) |t| {
                    if (t.kind == .greater) break;
                    if (t.flags.space and buf.items.len > 0) try buf.append(pp.arena, ' ');
                    try buf.appendSlice(pp.arena, t.text);
                }
                spelled = buf.items;
                angled = true;
            } else {
                pp.diags.err(directive.loc, "expected \"FILENAME\" or <FILENAME>", .{});
                return;
            }
        }

        if (pp.includes.items.len >= max_include_depth) {
            pp.diags.err(directive.loc, "#include nested too deeply", .{});
            return;
        }
        const id = try pp.resolveInclude(spelled, angled) orelse {
            pp.diags.add(.fatal, directive.loc, "'{s}' file not found", .{spelled});
            return;
        };
        if (pp.pragma_once.contains(try pp.fileKey(pp.sm.file(id).path))) return;
        try pp.enterFileId(id);
    }

    fn resolveInclude(pp: *Preprocessor, spelled: []const u8, angled: bool) Error!?source.FileId {
        if (std.fs.path.isAbsolute(spelled)) return pp.sm.load(spelled);
        const frame = pp.includes.items[pp.includes.items.len - 1];
        const local = try std.fs.path.join(pp.arena, &.{ frame.dir, spelled });
        if (try pp.sm.load(local)) |id| return id;
        for (pp.opts.include_dirs) |dir| {
            const p = try std.fs.path.join(pp.arena, &.{ dir, spelled });
            if (try pp.sm.load(p)) |id| return id;
        }
        // Like dxc, fall back to the compiled-in HLSL headers for <...>.
        if (angled) {
            var name = try pp.arena.dupe(u8, spelled);
            std.mem.replaceScalar(u8, name, '\\', '/');
            if (hlsl_headers.find(name)) |text| {
                name = try std.mem.concat(pp.arena, u8, &.{ embedded_prefix, name });
                for (pp.sm.files.items, 0..) |f, i| {
                    if (std.mem.eql(u8, f.path, name)) return @intCast(i);
                }
                return try pp.sm.addFile(name, text);
            }
        }
        return null;
    }

    fn fileKey(pp: *Preprocessor, path: []const u8) Error![]const u8 {
        return std.fs.path.resolveAlloc(pp.arena, &.{path});
    }

    fn handleLine(pp: *Preprocessor, directive: Token) Error!void {
        const raw = try pp.directiveTokens();
        const toks = try pp.expandIsolated(raw);
        if (toks.len == 0 or toks[0].kind != .number) {
            pp.diags.err(directive.loc, "#line directive requires a positive integer argument", .{});
            return;
        }
        const n = std.fmt.parseInt(u32, toks[0].text, 10) catch {
            pp.diags.err(toks[0].loc, "#line directive requires a simple digit sequence", .{});
            return;
        };
        var name: ?[]const u8 = null;
        if (toks.len > 1) {
            if (toks[1].kind != .string) {
                pp.diags.err(toks[1].loc, "invalid filename for #line directive", .{});
                return;
            }
            name = try unquoteString(pp.arena, toks[1].text);
        }
        const file = pp.currentLexer().?.file;
        const gop = try pp.line_overrides.getOrPut(pp.arena, file);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(pp.arena, .{
            .phys_line = pp.sm.lineCol(directive.loc).line,
            .line = n,
            .name = name,
        });
    }

    // ---------------------------------------------------------------------
    // #if expressions

    fn evalCondition(pp: *Preprocessor, directive: Token) Error!bool {
        const raw = try pp.directiveTokens();
        // Resolve `defined` and feature checks before expansion.
        var pre: std.ArrayList(Token) = .empty;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            const t = raw[i];
            if (t.isIdent("defined")) {
                var j = i + 1;
                const paren = j < raw.len and raw[j].kind == .l_paren;
                if (paren) j += 1;
                if (j >= raw.len or raw[j].kind != .identifier) {
                    pp.diags.err(t.loc, "macro name missing after 'defined'", .{});
                    return false;
                }
                const v = pp.macros.contains(raw[j].text);
                if (paren) {
                    j += 1;
                    if (j >= raw.len or raw[j].kind != .r_paren) {
                        pp.diags.err(t.loc, "missing ')' after 'defined'", .{});
                        return false;
                    }
                }
                try pre.append(pp.arena, numberToken(if (v) "1" else "0", t));
                i = j;
                continue;
            }
            if (t.isIdent("__has_include") or t.isIdent("__has_include_next")) {
                // __has_include("file") / __has_include(<file>)
                var j = i + 1;
                var found = false;
                if (j < raw.len and raw[j].kind == .l_paren) {
                    j += 1;
                    var spelled: std.ArrayList(u8) = .empty;
                    if (j < raw.len and raw[j].kind == .string) {
                        try spelled.appendSlice(pp.arena, raw[j].text[1 .. raw[j].text.len - 1]);
                        j += 1;
                    } else if (j < raw.len and raw[j].kind == .less) {
                        j += 1;
                        while (j < raw.len and raw[j].kind != .greater) : (j += 1) try spelled.appendSlice(pp.arena, raw[j].text);
                        j += 1;
                    }
                    found = try pp.resolveInclude(spelled.items, raw[i + 2].kind == .less) != null;
                }
                if (j >= raw.len or raw[j].kind != .r_paren) {
                    pp.diags.err(t.loc, "missing ')' after '__has_include'", .{});
                    return false;
                }
                try pre.append(pp.arena, numberToken(if (found) "1" else "0", t));
                i = j;
                continue;
            }
            try pre.append(pp.arena, t);
        }
        const toks = try pp.expandIsolated(pre.items);
        if (toks.len == 0) {
            pp.diags.err(directive.loc, "#{s} with no expression", .{directive.text});
            return false;
        }
        var ev: Eval = .{ .pp = pp, .toks = toks };
        const v = ev.expr(0) catch return false;
        if (ev.pos < toks.len) {
            pp.diags.err(toks[ev.pos].loc, "token is not a valid binary operator in a preprocessor subexpression", .{});
            return false;
        }
        return v.v != 0;
    }
};

fn numberToken(text: []const u8, at: Token) Token {
    return .{ .kind = .number, .flags = at.flags, .text = text, .loc = at.loc };
}

fn quoteString(a: Allocator, s: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.append(a, '"');
    for (s) |c| {
        if (c == '"' or c == '\\') try buf.append(a, '\\');
        try buf.append(a, c);
    }
    try buf.append(a, '"');
    return buf.items;
}

fn unquoteString(a: Allocator, s: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 1;
    while (i + 1 < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 2 < s.len) i += 1;
        try buf.append(a, s[i]);
    }
    return buf.items;
}

const Value = struct {
    v: i64,
    unsigned: bool = false,

    fn of(b: bool) Value {
        return .{ .v = @intFromBool(b) };
    }
};

const Eval = struct {
    pp: *Preprocessor,
    toks: []const Token,
    pos: usize = 0,

    const EvalError = error{EvalFailed};

    fn peek(e: *Eval) ?Token {
        return if (e.pos < e.toks.len) e.toks[e.pos] else null;
    }

    fn fail(e: *Eval, comptime msg: []const u8) EvalError {
        const loc = if (e.peek()) |t| t.loc else if (e.toks.len > 0) e.toks[e.toks.len - 1].loc else Loc.none;
        e.pp.diags.err(loc, msg, .{});
        return error.EvalFailed;
    }

    fn precedence(k: Kind) ?u8 {
        return switch (k) {
            .question => 1,
            .pipe_pipe => 2,
            .amp_amp => 3,
            .pipe => 4,
            .caret => 5,
            .amp => 6,
            .equal_equal, .exclaim_equal => 7,
            .less, .less_equal, .greater, .greater_equal => 8,
            .less_less, .greater_greater => 9,
            .plus, .minus => 10,
            .star, .slash, .percent => 11,
            else => null,
        };
    }

    fn expr(e: *Eval, min_prec: u8) EvalError!Value {
        var lhs = try e.unary();
        while (e.peek()) |op| {
            const prec = precedence(op.kind) orelse break;
            if (prec < min_prec) break;
            e.pos += 1;
            if (op.kind == .question) {
                const t = try e.expr(0);
                const colon = e.peek() orelse return e.fail("expected ':' in preprocessor expression");
                if (colon.kind != .colon) return e.fail("expected ':' in preprocessor expression");
                e.pos += 1;
                const f = try e.expr(1);
                lhs = if (lhs.v != 0) t else f;
                lhs.unsigned = t.unsigned or f.unsigned;
                continue;
            }
            const rhs = try e.expr(prec + 1);
            lhs = try e.binary(op, lhs, rhs);
        }
        return lhs;
    }

    fn binary(e: *Eval, op: Token, a: Value, b: Value) EvalError!Value {
        const u = a.unsigned or b.unsigned;
        const au: u64 = @bitCast(a.v);
        const bu: u64 = @bitCast(b.v);
        return switch (op.kind) {
            .pipe_pipe => Value.of(a.v != 0 or b.v != 0),
            .amp_amp => Value.of(a.v != 0 and b.v != 0),
            .pipe => .{ .v = a.v | b.v, .unsigned = u },
            .caret => .{ .v = a.v ^ b.v, .unsigned = u },
            .amp => .{ .v = a.v & b.v, .unsigned = u },
            .equal_equal => Value.of(a.v == b.v),
            .exclaim_equal => Value.of(a.v != b.v),
            .less => Value.of(if (u) au < bu else a.v < b.v),
            .less_equal => Value.of(if (u) au <= bu else a.v <= b.v),
            .greater => Value.of(if (u) au > bu else a.v > b.v),
            .greater_equal => Value.of(if (u) au >= bu else a.v >= b.v),
            .less_less => .{ .v = if (b.v >= 64 or b.v < 0) 0 else a.v << @intCast(b.v), .unsigned = a.unsigned },
            .greater_greater => .{
                .v = if (b.v >= 64 or b.v < 0) 0 else if (a.unsigned) @bitCast(au >> @intCast(b.v)) else a.v >> @intCast(b.v),
                .unsigned = a.unsigned,
            },
            .plus => .{ .v = a.v +% b.v, .unsigned = u },
            .minus => .{ .v = a.v -% b.v, .unsigned = u },
            .star => .{ .v = a.v *% b.v, .unsigned = u },
            .slash, .percent => blk: {
                if (b.v == 0) {
                    e.pp.diags.err(op.loc, "division by zero in preprocessor expression", .{});
                    return error.EvalFailed;
                }
                if (u) break :blk .{ .v = @bitCast(if (op.kind == .slash) au / bu else au % bu), .unsigned = true };
                if (a.v == std.math.minInt(i64) and b.v == -1) break :blk .{ .v = if (op.kind == .slash) a.v else 0 };
                break :blk .{ .v = if (op.kind == .slash) @divTrunc(a.v, b.v) else @rem(a.v, b.v) };
            },
            else => unreachable,
        };
    }

    fn unary(e: *Eval) EvalError!Value {
        const t = e.peek() orelse return e.fail("expected value in expression");
        e.pos += 1;
        switch (t.kind) {
            .plus => return e.unary(),
            .minus => {
                const v = try e.unary();
                return .{ .v = -%v.v, .unsigned = v.unsigned };
            },
            .tilde => {
                const v = try e.unary();
                return .{ .v = ~v.v, .unsigned = v.unsigned };
            },
            .exclaim => return Value.of((try e.unary()).v == 0),
            .l_paren => {
                const v = try e.expr(0);
                const r = e.peek() orelse return e.fail("expected ')' in preprocessor expression");
                if (r.kind != .r_paren) return e.fail("expected ')' in preprocessor expression");
                e.pos += 1;
                return v;
            },
            .number => return parseInt(t.text) orelse {
                e.pp.diags.err(t.loc, "invalid integer constant in preprocessor expression", .{});
                return error.EvalFailed;
            },
            .char => return .{ .v = charValue(t.text) },
            .identifier => {
                // Remaining identifiers are 0, except C++ true/false.
                return .{ .v = @intFromBool(std.mem.eql(u8, t.text, "true")) };
            },
            else => {
                e.pos -= 1;
                return e.fail("invalid token at start of a preprocessor expression");
            },
        }
    }
};

fn parseInt(text: []const u8) ?Value {
    var end = text.len;
    var unsigned = false;
    while (end > 0) {
        const c = text[end - 1];
        if (c == 'u' or c == 'U') {
            unsigned = true;
        } else if (c != 'l' and c != 'L') break;
        end -= 1;
    }
    const digits = text[0..end];
    if (digits.len == 0) return null;
    var base: u8 = 10;
    var body = digits;
    if (digits.len > 2 and digits[0] == '0' and (digits[1] == 'x' or digits[1] == 'X')) {
        base = 16;
        body = digits[2..];
    } else if (digits.len > 2 and digits[0] == '0' and (digits[1] == 'b' or digits[1] == 'B')) {
        base = 2;
        body = digits[2..];
    } else if (digits.len > 1 and digits[0] == '0') {
        base = 8;
        body = digits[1..];
    }
    const v = std.fmt.parseInt(u64, body, base) catch return null;
    return .{ .v = @bitCast(v), .unsigned = unsigned or v > std.math.maxInt(i64) };
}

fn charValue(text: []const u8) i64 {
    if (text.len < 3) return 0;
    const body = text[1 .. text.len - 1];
    if (body[0] != '\\') return body[0];
    if (body.len < 2) return 0;
    return switch (body[1]) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        '0' => 0,
        '\\' => '\\',
        '\'' => '\'',
        '"' => '"',
        else => body[1],
    };
}

// -------------------------------------------------------------------------
// Tests

const TestPP = struct {
    mfs: source.MemoryFs = .{},
    sm: source.SourceManager = undefined,
    diags: Diagnostics = undefined,
    arena: std.heap.ArenaAllocator = undefined,
    pp: Preprocessor = undefined,

    fn init(t: *TestPP, files: []const [2][]const u8, main: []const u8, opts: Options) !void {
        const gpa = std.testing.allocator;
        for (files) |f| try t.mfs.put(gpa, f[0], f[1]);
        t.sm = .init(gpa, t.mfs.fileSystem());
        t.diags = .init(gpa);
        t.arena = .init(gpa);
        t.pp = .init(t.arena.allocator(), &t.sm, &t.diags, opts);
        try t.pp.enterMainText("main.hlsl", main);
    }

    fn deinit(t: *TestPP) void {
        const gpa = std.testing.allocator;
        t.arena.deinit();
        t.diags.deinit();
        t.sm.deinit();
        t.mfs.deinit(gpa);
    }

    /// Expanded tokens joined by single spaces.
    fn output(t: *TestPP) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        const a = t.arena.allocator();
        while (true) {
            const tok = try t.pp.next();
            if (tok.kind == .eof) break;
            if (buf.items.len > 0) try buf.append(a, ' ');
            if (tok.kind == .pragma) try buf.appendSlice(a, "#pragma ");
            try buf.appendSlice(a, tok.text);
        }
        return buf.items;
    }
};

fn expectPP(main: []const u8, expected: []const u8) !void {
    var t: TestPP = .{};
    try t.init(&.{}, main, .{});
    defer t.deinit();
    try std.testing.expectEqualStrings(expected, try t.output());
    for (t.diags.list.items) |d| std.debug.print("unexpected diagnostic: {s}\n", .{d.message});
    try std.testing.expectEqual(@as(u32, 0), t.diags.error_count);
}

test "object and function-like macros" {
    try expectPP("#define A 1 + 2\nint x = A;", "int x = 1 + 2 ;");
    try expectPP("#define F(a, b) a * b\nF(1, (2, 3))", "1 * ( 2 , 3 )");
    try expectPP("#define F(x) x\nF", "F");
    try expectPP("#define E()\nE() x", "x");
}

test "stringify and paste" {
    try expectPP("#define S(x) #x\nS(a  \"b\"  c)", "\"a \\\"b\\\" c\"");
    try expectPP("#define C(a,b) a##b\nC(foo, 12) C(,x) C(y,)", "foo12 x y");
    try expectPP("#define X(n) v##n\n#define v1 one\nX(1)", "one");
}

test "recursion is blocked and painted" {
    try expectPP("#define foo foo bar\nfoo", "foo bar");
    try expectPP("#define f(x) x g\n#define g f\nf(1)(2)", "1 f ( 2 )");
    // Standard example: nested macro arguments are pre-expanded.
    try expectPP("#define x 3\n#define f(a) f(x * (a))\n#undef x\n#define x 2\n#define g f\nf(y+1)", "f ( 2 * ( y + 1 ) )");
}

test "variadic macros" {
    try expectPP("#define V(fmt, ...) p(fmt, __VA_ARGS__)\nV(a, 1, 2)", "p ( a , 1 , 2 )");
    try expectPP("#define V(fmt, ...) p(fmt , ## __VA_ARGS__)\nV(a) V(a,b)", "p ( a ) p ( a , b )");
}

test "conditionals" {
    try expectPP("#if 1 + 1 == 2 && defined(Q) == 0\nyes\n#else\nno\n#endif", "yes");
    try expectPP("#define Q\n#ifdef Q\na\n#elif 1\nb\n#else\nc\n#endif", "a");
    try expectPP("#if 0\n#if 1\nx\n#endif\n#elif 2 > 1\ny\n#endif", "y");
    try expectPP("#if 0\n'unterminated in skipped block\n#endif\nz", "z");
    try expectPP("#if (-1 < 0u) || 0x10 != 16\nbad\n#else\ngood\n#endif", "good");
    try expectPP("#ifndef __HLSL_VERSION\nbad\n#elif __HLSL_VERSION >= 2021\ngood\n#endif", "good");
}

test "include, pragma once, line, builtins" {
    var t: TestPP = .{};
    try t.init(&.{
        .{ "./inc.h", "#pragma once\nint inc;\n" },
        .{ "sys/s.h", "int sys;" },
    }, "#include \"inc.h\"\n#include \"inc.h\"\n#include <s.h>\n#line 50 \"x.hlsl\"\nint l = __LINE__; __FILE__\n#pragma pack_matrix(row_major)\n", .{ .include_dirs = &.{"sys"} });
    defer t.deinit();
    try std.testing.expectEqualStrings("int inc ; int sys ; int l = 50 ; \"x.hlsl\" #pragma pack_matrix(row_major)", try t.output());
    try std.testing.expectEqual(@as(u32, 0), t.diags.error_count);
}

test "errors are diagnosed" {
    var t: TestPP = .{};
    try t.init(&.{}, "#error boom\n#if 1\n", .{});
    defer t.deinit();
    _ = try t.output();
    try std.testing.expectEqual(@as(u32, 2), t.diags.error_count);
}
