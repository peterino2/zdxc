//! C preprocessor for HLSL, modelled on clang's: a stack of token sources
//! (files and macro expansions), with macros disabled while their expansion
//! is being rescanned and identifiers painted `no_expand` when they name a
//! disabled macro.

const std = @import("std");
const BumpArena = @import("../BumpArena.zig");
const Allocator = std.mem.Allocator;
const source = @import("source.zig");
const lexer = @import("lexer.zig");
const Diagnostics = @import("../diag.zig").Diagnostics;
const Report = @import("../diag.zig").Report;
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
    /// SPIR-V 1.x of the target environment.
    spirv_minor: u32 = 0,
    enable_16bit: bool = false,
    hlsl_version: u16 = 2021,
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

const MacroFilter = struct {
    bits: [filter_words]u64 = @splat(0),

    const filter_words = 16; // 1024 bits

    fn slot(name: []const u8) u10 {
        const first: u32 = name[0];
        const last: u32 = name[name.len - 1];
        const len: u32 = @truncate(name.len);
        return @truncate(first *% 31 +% last *% 7 +% len *% 131);
    }

    fn add(f: *MacroFilter, name: []const u8) void {
        const s = slot(name);
        f.bits[s >> 6] |= @as(u64, 1) << @as(u6, @truncate(s));
    }

    fn mayContain(f: *const MacroFilter, name: []const u8) bool {
        const s = slot(name);
        return f.bits[s >> 6] & (@as(u64, 1) << @as(u6, @truncate(s))) != 0;
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

pub const Error = Allocator.Error;

pub const PresumedLoc = source.PresumedLoc;

const max_include_depth = 200;
/// Nesting limit for macro-argument pre-expansion (`F(F(F(...)))`) and for
/// parentheses in #if expressions; deeper input would exhaust the stack.
/// dxc itself crashes at a few thousand levels.
const max_nesting_depth = 512;
const embedded_prefix = "<built-in:hlsl>/";
const hlsl_headers = @import("hlsl_headers");

pub const Preprocessor = struct {
    arena: Allocator,
    sm: *source.SourceManager,
    diags: *Diagnostics,
    opts: Options,
    macros: std.StringHashMapUnmanaged(*Macro) = .empty,
    /// Conservative filter over defined macro names (bits are never
    /// cleared), letting most identifiers skip the hash lookup.
    macro_filter: MacroFilter = .{},
    contexts: std.ArrayList(Context) = .empty,
    includes: std.ArrayList(IncludeFrame) = .empty,
    conds: std.ArrayList(Cond) = .empty,
    pushback: std.ArrayList(Raw) = .empty,
    pragma_once: std.StringHashMapUnmanaged(void) = .empty,
    counter: u32 = 0,
    main_file: ?source.FileId = null,
    isolated_depth: u32 = 0,
    nesting_reported: bool = false,

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
        return pp.enterFileFrom(id, .none);
    }

    fn enterFileFrom(pp: *Preprocessor, id: source.FileId, included_from: Loc) !void {
        pp.sm.setIncludedFrom(id, included_from);
        const f = pp.sm.file(id);
        try pp.includes.append(pp.arena, .{
            .lex = .init(f.text, id),
            // The predefines pseudo-file has no directory to search.
            .dir = if (std.mem.eql(u8, f.path, "<built-in>")) "" else std.fs.path.dirname(f.path) orelse ".",
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
        try pp.macros.ensureTotalCapacity(pp.arena, 64);
        for (builtins) |b| {
            const m = try pp.arena.create(Macro);
            m.* = .{ .name = b[0], .builtin = b[1] };
            try pp.defineMacro(b[0], m);
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
            \\
        );
        try w.print("#define __HLSL_VERSION {d}\n", .{o.hlsl_version});
        try w.writeAll(
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
        if (o.spirv) try w.print("#define __spirv__ 1\n#define __SPIRV_MAJOR_VERSION__ 1\n#define __SPIRV_MINOR_VERSION__ {d}\n", .{o.spirv_minor});
        for (o.defines) |d| try w.print("#define {s} {s}\n", .{ d.name, d.value orelse "1" });

        const id = try pp.sm.addFile("<built-in>", text.written());
        try pp.enterFileId(id);
    }

    fn defineMacro(pp: *Preprocessor, name: []const u8, m: *Macro) Error!void {
        pp.macro_filter.add(name);
        try pp.macros.put(pp.arena, name, m);
    }

    fn lookupMacro(pp: *const Preprocessor, name: []const u8) ?*Macro {
        if (!pp.macro_filter.mayContain(name)) return null;
        return pp.macros.get(name);
    }

    // ---------------------------------------------------------------------
    // Raw token sources

    fn currentLexer(pp: *Preprocessor) ?*lexer.Lexer {
        if (pp.includes.items.len == 0) return null;
        return &pp.includes.items[pp.includes.items.len - 1].lex;
    }

    fn lexRaw(pp: *Preprocessor) Error!Raw {
        // After a fatal error (or too many errors) nothing more is produced.
        if (pp.diags.stopped) return .{ .tok = .{ .kind = .eof, .text = "", .loc = .none }, .from_file = true };
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
            const t = @call(.always_inline, lexer.Lexer.next, .{&frame.lex});
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
            if (t.text.len == 7 and t.text[0] == '_' and std.mem.eql(u8, t.text, "_Pragma")) {
                if (try pp.pragmaOperator(t)) |pragma| return pragma;
                continue;
            }
            const m = pp.lookupMacro(t.text) orelse return t;
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
            // Each expanded token gets a macro location recording where it
            // was spelled and which expansion produced it.
            const is_arg = t.flags.from_arg;
            t.flags.from_arg = false;
            t.loc = try pp.sm.addExpansion(.{ .spelling = t.loc, .expansion = name.loc, .macro_name = m.name, .is_arg = is_arg });
            if (i == 0) {
                t.flags.space = name.flags.space;
                t.flags.bol = name.flags.bol;
            } else t.flags.bol = false;
        }
        m.disabled = true;
        try pp.contexts.append(pp.arena, .{ .tokens = result, .macro = m });
        return true;
    }

    /// `_Pragma("...")`: destringize the operand and treat it like a
    /// `#pragma` line.
    fn pragmaOperator(pp: *Preprocessor, op: Token) Error!?Token {
        const open = try pp.lexRawSkipDirectives();
        const str = try pp.lexRawSkipDirectives();
        const close = try pp.lexRawSkipDirectives();
        if (open.tok.kind != .l_paren or str.tok.kind != .string or close.tok.kind != .r_paren) {
            pp.diags.err(op.loc, "_Pragma takes a parenthesized string literal", .{});
            if (close.tok.kind != .r_paren) try pp.pushback.append(pp.arena, close);
            return null;
        }
        const body = try unquoteString(pp.arena, str.tok.text);
        return pp.handlePragma(std.mem.trim(u8, body, " \t"), op.loc);
    }

    /// Handle a pragma body. `#pragma once` is consumed; anything else is
    /// returned as a `.pragma` token for the parser.
    fn handlePragma(pp: *Preprocessor, body: []const u8, loc: Loc) Error!?Token {
        if (std.mem.eql(u8, body, "once")) {
            const file = pp.currentLexer().?.file;
            if (file == pp.main_file) {
                _ = pp.diags.report(.{ .severity = .warning, .loc = loc, .group = "pragma-once-outside-header" }, "#pragma once in main file", .{});
            } else {
                try pp.pragma_once.put(pp.arena, try pp.fileKey(pp.sm.file(file).path), {});
            }
            return null;
        }
        return .{ .kind = .pragma, .flags = .{ .bol = true }, .text = body, .loc = loc };
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
                if (pp.lookupMacro(t.text)) |am| {
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
        if (pp.isolated_depth >= max_nesting_depth) {
            if (!pp.nesting_reported) {
                const loc = if (tokens.len > 0) tokens[0].loc else Loc.none;
                pp.diags.err(loc, "macro arguments nested too deeply (limit {d})", .{max_nesting_depth});
                pp.nesting_reported = true;
            }
            return pp.arena.dupe(Token, tokens);
        }
        pp.isolated_depth += 1;
        defer pp.isolated_depth -= 1;
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
                                var c = at;
                                c.flags.from_arg = true;
                                try out.append(pp.arena, c);
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
                        c.flags.from_arg = true;
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
        return pp.sm.presumedLoc(loc);
    }

    /// Tracks the physical line of the previous lookup so that a stream of
    /// increasing locations (as when printing) costs O(1) per token instead
    /// of a binary search.
    pub const LineCursor = struct {
        file: source.FileId = Loc.none.file,
        /// 0-based index into line_starts of the current line.
        line_index: u32 = 0,
    };

    pub fn presumedLocCursor(pp: *const Preprocessor, loc_in: Loc, cursor: *LineCursor) PresumedLoc {
        if (loc_in.isNone()) return .{ .file = "<unknown>", .line = 0 };
        const loc = pp.sm.fileLoc(loc_in);
        const starts = pp.sm.file(loc.file).line_starts;
        if (cursor.file != loc.file or starts[cursor.line_index] > loc.offset) {
            cursor.* = .{ .file = loc.file, .line_index = pp.sm.lineCol(loc).line - 1 };
        } else {
            while (cursor.line_index + 1 < starts.len and starts[cursor.line_index + 1] <= loc.offset) cursor.line_index += 1;
        }
        return pp.sm.presumedLine(loc.file, cursor.line_index + 1);
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
        if (name.kind == .number) {
            // GNU line marker: `# <line> ["file" [flags...]]`.
            const rest = try pp.directiveTokens();
            const toks = try pp.arena.alloc(Token, rest.len + 1);
            toks[0] = name;
            @memcpy(toks[1..], rest);
            try pp.applyLine(hash, toks[0..@min(toks.len, 2)]);
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
            try pp.conds.append(pp.arena, .{ .taken = v, .seen_else = false, .loc = name.loc });
            if (!v) try pp.skipGroup();
        } else if (std.mem.eql(u8, d, "ifdef") or std.mem.eql(u8, d, "ifndef")) {
            const toks = try pp.directiveTokens();
            var v = false;
            if (toks.len == 0 or toks[0].kind != .identifier) {
                pp.diags.err(name.loc, "macro name missing", .{});
            } else v = pp.macros.contains(toks[0].text);
            if (d.len == 6) v = !v; // ifndef
            try pp.conds.append(pp.arena, .{ .taken = v, .seen_else = false, .loc = name.loc });
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
            return pp.handlePragma(lx.restOfLine(), hash.loc);
        } else if (std.mem.eql(u8, d, "error")) {
            pp.diags.err(name.loc, "{s}", .{lx.restOfLine()});
        } else if (std.mem.eql(u8, d, "warning")) {
            _ = pp.diags.report(.{ .severity = .warning, .loc = name.loc, .group = "#warnings" }, "{s}", .{lx.restOfLine()});
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
        if (m.function_like) {
            for (body, 0..) |t, j| {
                if (t.kind != .hash) continue;
                if (j + 1 >= body.len or m.paramIndex(body[j + 1]) == null) {
                    pp.diags.err(t.loc, "'#' is not followed by a macro parameter", .{});
                    return;
                }
            }
        }
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
            const len: u32 = @intCast(name.text.len);
            if (old.builtin != .none) {
                _ = pp.diags.report(.{ .severity = .warning, .loc = name.loc, .len = len, .group = "builtin-macro-redefined" }, "redefining builtin macro", .{});
            } else if (!old.sameDefinition(m)) {
                const d = pp.diags.report(.{ .severity = .warning, .loc = name.loc, .len = len, .group = "macro-redefined" }, "'{s}' macro redefined", .{name.text});
                if (!old.loc.isNone()) pp.diags.note(d, old.loc, len, "previous definition is here", .{});
            }
        }
        try pp.defineMacro(name.text, m);
    }

    fn handleInclude(pp: *Preprocessor, directive: Token) Error!void {
        const lx = pp.currentLexer().?;
        var spelled: []const u8 = undefined;
        var angled = false;
        // Location and length of the file name, for diagnostics and the
        // include chain.
        var name_loc = directive.loc;
        var name_len: u32 = @intCast(directive.text.len);
        if (lx.headerName()) |h| {
            spelled = h.text[1 .. h.text.len - 1];
            angled = true;
            name_loc = h.loc;
            name_len = @intCast(h.text.len);
            pp.skipRestOfLine();
        } else {
            const raw = try pp.directiveTokens();
            const toks = try pp.expandIsolated(raw);
            if (raw.len > 0) {
                name_loc = raw[0].loc;
                name_len = @intCast(raw[0].text.len);
            }
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
            const r: Report = .{ .severity = .fatal, .loc = name_loc, .len = name_len };
            if (angled and try pp.resolveInclude(spelled, false) != null) {
                _ = pp.diags.report(r, "'{s}' file not found with <angled> include; use \"quotes\" instead", .{spelled});
            } else {
                _ = pp.diags.report(r, "'{s}' file not found", .{spelled});
            }
            return;
        };
        // Multiple-include optimization: a guarded file whose guard macro is
        // defined would contribute nothing, so do not even enter it.
        if (includeGuard(pp.sm.file(id).content)) |guard| {
            if (pp.macros.contains(guard)) return;
        }
        if (pp.pragma_once.contains(try pp.fileKey(pp.sm.file(id).path))) return;
        try pp.enterFileFrom(id, name_loc);
    }

    /// Search order (matching dxc):
    /// - "quoted": the directory of each file on the include stack, innermost
    ///   first, then each -I directory;
    /// - <angled>: each -I directory, then the compiled-in HLSL headers.
    fn resolveInclude(pp: *Preprocessor, spelled: []const u8, angled: bool) Error!?source.FileId {
        if (std.fs.path.isAbsolute(spelled)) return pp.sm.load(spelled);
        if (!angled) {
            var i = pp.includes.items.len;
            while (i > 0) {
                i -= 1;
                const frame = pp.includes.items[i];
                if (frame.dir.len == 0) continue; // predefines pseudo-file
                // Joined with '/' on every OS, as dxc (clang) joins a quoted
                // include onto its includer's directory: on Windows too the
                // file is "./sub/b.h" in diagnostics and __FILE__.
                const sep: []const u8 = if (std.fs.path.isSep(frame.dir[frame.dir.len - 1])) "" else "/";
                const p = try std.mem.concat(pp.arena, u8, &.{ frame.dir, sep, spelled });
                if (try pp.sm.load(p)) |id| return id;
            }
        }
        for (pp.opts.include_dirs) |dir| {
            // With the OS's separator, as dxc joins -I directories.
            const p = try std.fs.path.join(pp.arena, &.{ dir, spelled });
            if (try pp.sm.load(p)) |id| return id;
        }
        if (angled) {
            const name = try pp.arena.dupe(u8, spelled);
            std.mem.replaceScalar(u8, name, '\\', '/');
            if (hlsl_headers.find(name)) |text| {
                return try pp.sm.loadText(try std.mem.concat(pp.arena, u8, &.{ embedded_prefix, name }), text);
            }
        }
        return null;
    }

    /// The macro guarding `content`, if the whole file is wrapped in
    /// `#ifndef X` / `#if !defined(X)` ... `#endif` with no `#else`/`#elif`
    /// at the top level and nothing outside. Computed once per content.
    fn includeGuard(content: *source.Content) ?[]const u8 {
        switch (content.guard) {
            .none => return null,
            .macro => |m| return m,
            .unknown => {},
        }
        content.guard = .none;
        var lx = lexer.Lexer.init(content.text, 0);
        const hash = lx.next();
        if (hash.kind != .hash) return null;
        const d = lx.next();
        var name: ?Token = null;
        if (d.isIdent("ifndef")) {
            name = lx.next();
        } else if (d.isIdent("if")) {
            if (lx.next().kind != .exclaim) return null;
            if (!lx.next().isIdent("defined")) return null;
            var t = lx.next();
            if (t.kind == .l_paren) {
                name = lx.next();
                t = lx.next();
                if (t.kind != .r_paren) return null;
            } else name = t;
        }
        const macro = name orelse return null;
        if (macro.kind != .identifier) return null;
        lx.skipLine();
        var depth: u32 = 1;
        while (true) {
            const t = lx.next();
            if (t.kind == .eof) return null;
            if (!(t.kind == .hash and t.flags.bol)) {
                lx.skipLine();
                continue;
            }
            const dir = lx.next();
            if (dir.flags.bol) {
                // Null directive: `dir` starts the next line; re-examine it.
                lx.pos = dir.loc.offset;
                lx.at_bol = true;
                continue;
            }
            if (dir.isIdent("if") or dir.isIdent("ifdef") or dir.isIdent("ifndef")) {
                depth += 1;
            } else if (dir.isIdent("endif")) {
                depth -= 1;
                if (depth == 0) {
                    lx.skipLine();
                    if (lx.next().kind != .eof) return null;
                    content.guard = .{ .macro = macro.text };
                    return macro.text;
                }
            } else if (depth == 1 and (dir.isIdent("else") or dir.isIdent("elif"))) {
                return null;
            }
            lx.skipLine();
        }
    }

    fn fileKey(pp: *Preprocessor, path: []const u8) Error![]const u8 {
        return std.fs.path.resolveAlloc(pp.arena, &.{path});
    }

    fn handleLine(pp: *Preprocessor, directive: Token) Error!void {
        const raw = try pp.directiveTokens();
        try pp.applyLine(directive, try pp.expandIsolated(raw));
    }

    /// Record a `#line` / line marker: `toks` is `<number> ["file"]`.
    fn applyLine(pp: *Preprocessor, directive: Token, toks: []const Token) Error!void {
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
        try pp.sm.addLineOverride(file, .{
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
    /// Nonzero while evaluating an operand whose value is discarded (the
    /// right side of a short-circuited && or ||, the unused arm of ?:).
    /// Errors such as division by zero are not reported there.
    unevaluated: u32 = 0,
    depth: u32 = 0,

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
                const cond = lhs.v != 0;
                const t = try e.operand(0, !cond);
                const colon = e.peek() orelse return e.fail("expected ':' in preprocessor expression");
                if (colon.kind != .colon) return e.fail("expected ':' in preprocessor expression");
                e.pos += 1;
                const f = try e.operand(1, cond);
                lhs = if (cond) t else f;
                lhs.unsigned = t.unsigned or f.unsigned;
                continue;
            }
            const skip = (op.kind == .amp_amp and lhs.v == 0) or (op.kind == .pipe_pipe and lhs.v != 0);
            const rhs = try e.operand(prec + 1, skip);
            lhs = try e.binary(op, lhs, rhs);
        }
        return lhs;
    }

    /// Parse an operand, marking it unevaluated when `skip` is set.
    fn operand(e: *Eval, min_prec: u8, skip: bool) EvalError!Value {
        if (skip) e.unevaluated += 1;
        defer if (skip) {
            e.unevaluated -= 1;
        };
        return e.expr(min_prec);
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
                    if (e.unevaluated != 0) break :blk .{ .v = 0, .unsigned = u };
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
        if (e.depth >= max_nesting_depth) return e.fail("preprocessor expression nested too deeply");
        e.depth += 1;
        defer e.depth -= 1;
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
            .char => return .{ .v = lexer.charValue(t.text) orelse {
                e.pp.diags.err(t.loc, "empty character constant", .{});
                return error.EvalFailed;
            } },
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

// -------------------------------------------------------------------------
// Tests

const TestPP = struct {
    mfs: source.MemoryFs = .{},
    sm: source.SourceManager = undefined,
    diags: Diagnostics = undefined,
    arena: BumpArena = undefined,
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
    try expectPP("#if 'a' == 97 && '\\n' == 10 && '\\x41' == 65 && '\\101' == 65 && '\\0' == 0\ngood\n#endif", "good");
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

test "an empty character constant is diagnosed in #if" {
    var t: TestPP = .{};
    try t.init(&.{}, "#if ''\n#endif\n", .{});
    defer t.deinit();
    _ = try t.output();
    try std.testing.expectEqual(@as(u32, 1), t.diags.error_count);
}

test "#if short-circuits && || ?:" {
    try expectPP("#if 0 && (1/0)\na\n#endif\n#if 1 || (1/0)\nb\n#endif\n#if 0 ? 1/0 : 2\nc\n#endif\n#if 1 ? 3 : 1%0\nd\n#endif", "b c d");
    try expectPP("#if defined(N) && (64 / N > 2)\nbad\n#else\nok\n#endif", "ok");
}

test "quoted includes search the include stack innermost first, then -I" {
    var t: TestPP = .{};
    try t.init(&.{
        .{ "./sub/b.h", "#include \"deeper/e.h\"\n" },
        .{ "./sub/deeper/e.h", "#include \"f.h\"\n#include \"g.h\"\n#include <a.h>\n" },
        .{ "./sub/f.h", "f_sub" },
        .{ "./f.h", "f_main" },
        .{ "./g.h", "g_main" },
        .{ "inc/g.h", "g_inc" },
        .{ "inc/a.h", "a_inc" },
        .{ "./sub/deeper/a.h", "a_includer" },
    }, "#include \"sub/b.h\"\n", .{ .include_dirs = &.{"inc"} });
    defer t.deinit();
    try std.testing.expectEqualStrings("f_sub g_main a_inc", try t.output());
    try std.testing.expectEqual(@as(u32, 0), t.diags.error_count);
}

test "an included file's path is its includer's directory, '/', the spelling" {
    // As dxc names it on every OS (`dxc -P` on Windows writes "./sub/f.h").
    var t: TestPP = .{};
    try t.init(&.{
        .{ "./sub/f.h", "#include \"g.h\"\n__FILE__" },
        .{ "./sub/g.h", "__FILE__" },
    }, "#include \"sub/f.h\"\n", .{});
    defer t.deinit();
    try std.testing.expectEqualStrings("\"./sub/g.h\" \"./sub/f.h\"", try t.output());
    try std.testing.expectEqual(@as(u32, 0), t.diags.error_count);
}

test "angled includes do not search the includer's directory" {
    var t: TestPP = .{};
    try t.init(&.{.{ "./a.h", "a" }}, "#include <a.h>\n", .{});
    defer t.deinit();
    _ = try t.output();
    try std.testing.expectEqual(@as(u32, 1), t.diags.error_count);
    try std.testing.expect(std.mem.indexOf(u8, t.diags.list.items[0].message, "use \"quotes\"") != null);
}

test "include guards are detected and guarded files are not re-entered" {
    var t: TestPP = .{};
    try t.init(&.{
        .{ "./g.h", "// header\n#ifndef G_H\n#define G_H\nint g;\n#if 1\n#endif\n#endif // G_H\n" },
        .{ "./d.h", "#if !defined(D_H)\n#define D_H\nint d;\n#endif\n" },
        .{ "./e.h", "#ifndef E_H\n#define E_H\nint e;\n#else\nint again;\n#endif\n" },
        .{ "./o.h", "#ifndef O_H\n#define O_H\n#endif\nint outside;\n" },
    }, "#include \"g.h\"\n#include \"g.h\"\n#include \"d.h\"\n#include \"d.h\"\n#include \"e.h\"\n#include \"e.h\"\n#include \"o.h\"\n#include \"o.h\"\n", .{});
    defer t.deinit();
    try std.testing.expectEqualStrings("int g ; int d ; int e ; int again ; int outside ; int outside ;", try t.output());
    const sm = &t.sm;
    var guards: [4]?[]const u8 = undefined;
    for ([_][]const u8{ "./g.h", "./d.h", "./e.h", "./o.h" }, 0..) |path, i| {
        guards[i] = Preprocessor.includeGuard(sm.cache.get(path).?.?);
    }
    try std.testing.expectEqualStrings("G_H", guards[0].?);
    try std.testing.expectEqualStrings("D_H", guards[1].?);
    try std.testing.expect(guards[2] == null);
    try std.testing.expect(guards[3] == null);
}

test "skipped blocks are skipped token by token" {
    try expectPP("#if 0\nx = \"/*\";\n#endif\nok", "ok");
}

test "'#' must name a parameter in function-like macros" {
    var t: TestPP = .{};
    try t.init(&.{}, "#define O # x\nO\n#define F(x) #x #\nF(1)\n", .{});
    defer t.deinit();
    try std.testing.expectEqualStrings("# x F ( 1 )", try t.output());
    try std.testing.expectEqual(@as(u32, 1), t.diags.error_count);
}

test "_Pragma operator" {
    try expectPP("#define P(x) _Pragma(#x) int a;\nP(pack_matrix(row_major))\n_Pragma(\"dxc diagnostic ignored \\\"-Wfoo\\\"\") int b;", "#pragma pack_matrix(row_major) int a ; #pragma dxc diagnostic ignored \"-Wfoo\" int b ;");
}

test "GNU line markers" {
    try expectPP("a\n# 40 \"foo.hlsl\" 1 3\nb __LINE__ __FILE__\n#90\nc __LINE__", "a b 40 \"foo.hlsl\" c 90");
}

test "deep nesting is diagnosed instead of overflowing the stack" {
    const gpa = std.testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "#define F(x) (x)\n");
    for (0..20000) |_| try src.appendSlice(gpa, "F(");
    try src.append(gpa, '1');
    for (0..20000) |_| try src.append(gpa, ')');
    try src.appendSlice(gpa, "\n#if ");
    for (0..20000) |_| try src.append(gpa, '(');
    try src.append(gpa, '1');
    for (0..20000) |_| try src.append(gpa, ')');
    try src.appendSlice(gpa, "\n#endif\n");
    var t: TestPP = .{};
    try t.init(&.{}, src.items, .{});
    defer t.deinit();
    _ = try t.output();
    try std.testing.expectEqual(@as(u32, 2), t.diags.error_count);
}
