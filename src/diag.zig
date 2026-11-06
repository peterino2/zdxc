//! Diagnostics: collected during compilation, rendered clang-style (or
//! msvc / vi style) with source snippets, ranges, notes, fix-it hints,
//! include chains and macro expansion backtraces.

const std = @import("std");
const BumpArena = @import("BumpArena.zig");
const Allocator = std.mem.Allocator;
const source = @import("front/source.zig");
const Loc = source.Loc;

pub const Severity = enum {
    note,
    warning,
    @"error",
    fatal,

    fn label(s: Severity) []const u8 {
        return switch (s) {
            .note => "note",
            .warning => "warning",
            .@"error" => "error",
            .fatal => "fatal error",
        };
    }
};

pub const Note = struct {
    loc: Loc,
    /// Length in bytes of the highlighted range starting at `loc`.
    len: u32 = 0,
    message: []const u8,
};

pub const Diagnostic = struct {
    severity: Severity,
    loc: Loc,
    len: u32 = 0,
    message: []const u8,
    /// Warning group, shown as `[-Wgroup]` and controlled by `-Wno-group`.
    group: ?[]const u8 = null,
    /// The warning was promoted by -WX.
    promoted: bool = false,
    /// Text to insert at `loc` (shown under the caret).
    fixit: ?[]const u8 = null,
    notes: std.ArrayList(Note) = .empty,
    /// Ordering key: diagnostics are rendered sorted by position (stable),
    /// so preprocessor and parser messages interleave in source order.
    position: u64 = 0,
};

pub const Report = struct {
    severity: Severity,
    loc: Loc,
    len: u32 = 0,
    group: ?[]const u8 = null,
    fixit: ?[]const u8 = null,
};

pub const Diagnostics = struct {
    arena: BumpArena,
    list: std.ArrayList(*Diagnostic) = .empty,
    error_count: u32 = 0,
    warning_count: u32 = 0,
    /// -WX
    warnings_as_errors: bool = false,
    /// -no-warnings
    suppress_warnings: bool = false,
    /// Groups disabled with -Wno-<group>.
    disabled_groups: std.StringHashMapUnmanaged(void) = .empty,
    /// Render at most this many errors (0 = no limit), like clang's
    /// -ferror-limit. Applied in source order when rendering.
    error_limit: u32 = 20,
    /// Set by producers (preprocessor token count, parser token index)
    /// and captured by each new diagnostic.
    position: u64 = 0,
    /// A fatal error was reported or the error limit reached: producers
    /// should stop.
    stopped: bool = false,
    /// Position at which compilation stopped. Diagnostics for earlier
    /// positions are still accepted: the preprocessor runs ahead of the
    /// parser, so a fatal error late in the file must not hide parse
    /// errors before it.
    stop_position: u64 = std.math.maxInt(u64),

    pub fn init(gpa: Allocator) Diagnostics {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(d: *Diagnostics) void {
        d.arena.deinit();
    }

    pub fn disableGroup(d: *Diagnostics, group: []const u8) !void {
        const a = d.arena.allocator();
        try d.disabled_groups.put(a, try a.dupe(u8, group), {});
    }

    /// Report a diagnostic. Returns null when it is suppressed (disabled
    /// warning, or after the compilation was stopped); otherwise notes can
    /// be attached to the result with `note`.
    /// True once compilation has stopped at or before `position`.
    pub fn stoppedAt(d: *const Diagnostics, position: u64) bool {
        return d.stopped and position >= d.stop_position;
    }

    pub fn report(d: *Diagnostics, r: Report, comptime fmt: []const u8, args: anytype) ?*Diagnostic {
        if (d.stoppedAt(d.position)) return null;
        var sev = r.severity;
        var promoted = false;
        if (sev == .warning) {
            if (d.suppress_warnings) return null;
            if (r.group) |g| if (d.disabled_groups.contains(g)) return null;
            if (d.warnings_as_errors) {
                sev = .@"error";
                promoted = true;
            }
        }
        const a = d.arena.allocator();
        const diag = a.create(Diagnostic) catch return null;
        diag.* = .{
            .severity = sev,
            .loc = r.loc,
            .len = r.len,
            .message = std.fmt.allocPrint(a, fmt, args) catch "out of memory formatting diagnostic",
            .group = r.group,
            .promoted = promoted,
            .fixit = r.fixit,
            .position = d.position,
        };
        d.list.append(a, diag) catch return null;
        switch (sev) {
            .@"error" => d.error_count += 1,
            .fatal => {
                d.error_count += 1;
                if (!d.stopped or d.position < d.stop_position) d.stop_position = d.position;
                d.stopped = true;
            },
            .warning => d.warning_count += 1,
            .note => {},
        }
        return diag;
    }

    /// Attach a note to `diag` (no-op when the diagnostic was suppressed).
    pub fn note(d: *Diagnostics, diag: ?*Diagnostic, loc: Loc, len: u32, comptime fmt: []const u8, args: anytype) void {
        const target = diag orelse return;
        const a = d.arena.allocator();
        const msg = std.fmt.allocPrint(a, fmt, args) catch return;
        target.notes.append(a, .{ .loc = loc, .len = len, .message = msg }) catch {};
    }

    pub fn err(d: *Diagnostics, loc: Loc, comptime fmt: []const u8, args: anytype) void {
        _ = d.report(.{ .severity = .@"error", .loc = loc }, fmt, args);
    }

    pub fn warn(d: *Diagnostics, loc: Loc, comptime fmt: []const u8, args: anytype) void {
        _ = d.report(.{ .severity = .warning, .loc = loc }, fmt, args);
    }

    /// Compatibility shim for callers that pass a severity directly.
    pub fn add(d: *Diagnostics, severity: Severity, loc: Loc, comptime fmt: []const u8, args: anytype) void {
        _ = d.report(.{ .severity = severity, .loc = loc }, fmt, args);
    }

    /// A point to roll back to (substitution failures are not errors).
    pub const Mark = struct { len: usize, errors: u32, warnings: u32 };

    pub fn mark(d: *const Diagnostics) Mark {
        return .{ .len = d.list.items.len, .errors = d.error_count, .warnings = d.warning_count };
    }

    pub fn rollback(d: *Diagnostics, m: Mark) void {
        d.list.shrinkRetainingCapacity(m.len);
        d.error_count = m.errors;
        d.warning_count = m.warnings;
    }

    pub fn hasErrors(d: *const Diagnostics) bool {
        return d.error_count != 0;
    }

    /// Diagnostics sorted for output (stable by position).
    pub fn sorted(d: *Diagnostics) []const *Diagnostic {
        std.sort.insertion(*Diagnostic, d.list.items, {}, struct {
            fn lt(_: void, a: *Diagnostic, b: *Diagnostic) bool {
                return a.position < b.position;
            }
        }.lt);
        return d.list.items;
    }

    pub fn render(d: *Diagnostics, sm: *const source.SourceManager, w: *std.Io.Writer, style: Style) !void {
        var r: Renderer = .{ .sm = sm, .w = w, .style = style };
        var errors: u32 = 0;
        for (d.sorted()) |diag| {
            if (diag.severity == .@"error" or diag.severity == .fatal) {
                if (d.error_limit != 0 and errors == d.error_limit) {
                    try r.message(.fatal, .none, 0, "too many errors emitted, stopping now", null, null);
                    return;
                }
                errors += 1;
            }
            try r.diagnostic(diag);
        }
    }
};

pub const Format = enum {
    /// `file:line:col: error: message`
    clang,
    /// `file(line,col): error: message` (clickable in Visual Studio)
    msvc,
    /// `file +line:col: error: message`
    vi,
};

pub const Style = struct {
    format: Format = .clang,
    color: bool = false,
    /// Show source lines, carets and fix-its.
    snippets: bool = true,
    /// The file diagnostics without a location name, at 1:1 (null: none).
    unplaced: ?[]const u8 = null,
};

const Renderer = struct {
    sm: *const source.SourceManager,
    w: *std.Io.Writer,
    style: Style,
    /// File of the previous top-level diagnostic, to print include chains
    /// only when they change (as clang does).
    last_file: ?source.FileId = null,

    const reset = "\x1b[0m";
    const bold = "\x1b[1m";

    fn color(r: *Renderer, code: []const u8) !void {
        if (r.style.color) try r.w.writeAll(code);
    }

    fn sevColor(sev: Severity) []const u8 {
        return switch (sev) {
            .note => "\x1b[1;30m",
            .warning => "\x1b[1;35m",
            .@"error", .fatal => "\x1b[1;31m",
        };
    }

    fn diagnostic(r: *Renderer, d: *const Diagnostic) !void {
        const file_loc = if (d.loc.isNone()) d.loc else r.sm.fileLoc(d.loc);
        if (!file_loc.isNone()) try r.includeChain(file_loc.file);
        var group_buf: [128]u8 = undefined;
        const group: ?[]const u8 = if (d.group) |g|
            (if (d.promoted)
                std.fmt.bufPrint(&group_buf, "-Werror,-W{s}", .{g}) catch g
            else
                std.fmt.bufPrint(&group_buf, "-W{s}", .{g}) catch g)
        else
            null;
        try r.message(d.severity, d.loc, d.len, d.message, group, d.fixit);
        try r.macroBacktrace(d.loc);
        for (d.notes.items) |n| {
            try r.message(.note, n.loc, n.len, n.message, null, null);
            try r.macroBacktrace(n.loc);
        }
    }

    fn includeChain(r: *Renderer, file: source.FileId) !void {
        if (r.last_file == file) return;
        r.last_file = file;
        // Outermost include first, one "In file included from" per level,
        // matching dxc.
        var chain: [64]Loc = undefined;
        var n: usize = 0;
        var inc = r.sm.file(file).included_from;
        while (!inc.isNone() and n < chain.len) {
            chain[n] = inc;
            n += 1;
            inc = r.sm.file(r.sm.fileLoc(inc).file).included_from;
        }
        while (n > 0) {
            n -= 1;
            const p = r.sm.presumedLoc(chain[n]);
            try r.color(bold);
            try r.w.print("In file included from {s}:{d}:\n", .{ p.file, p.line });
            try r.color(reset);
        }
    }

    /// `expanded from macro` notes for each macro level of `loc`,
    /// outermost first (as dxc prints them); argument levels are skipped.
    fn macroBacktrace(r: *Renderer, loc: Loc) !void {
        var levels: [32]*const source.Expansion = undefined;
        var n: usize = 0;
        var cur = loc;
        while (cur.isMacro() and n < levels.len) {
            const e = r.sm.expansion(cur);
            if (e.is_arg) {
                cur = e.spelling;
                continue;
            }
            levels[n] = e;
            n += 1;
            cur = e.expansion;
        }
        while (n > 0) {
            n -= 1;
            const e = levels[n];
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "expanded from macro '{s}'", .{e.macro_name}) catch "expanded from macro";
            try r.message(.note, r.sm.spellingLoc(e.spelling), 0, msg, null, null);
        }
    }

    fn message(r: *Renderer, sev: Severity, loc: Loc, len: u32, msg: []const u8, group: ?[]const u8, fixit: ?[]const u8) !void {
        const w = r.w;
        try r.color(bold);
        if (!loc.isNone()) {
            const p = r.sm.presumedLoc(loc);
            const col = r.sm.lineCol(loc).col;
            switch (r.style.format) {
                .clang => try w.print("{s}:{d}:{d}: ", .{ p.file, p.line, col }),
                .msvc => try w.print("{s}({d},{d}): ", .{ p.file, p.line, col }),
                .vi => try w.print("{s} +{d}:{d}: ", .{ p.file, p.line, col }),
            }
        } else if (r.style.unplaced) |file| switch (r.style.format) {
            .clang => try w.print("{s}:1:1: ", .{file}),
            .msvc => try w.print("{s}(1,1): ", .{file}),
            .vi => try w.print("{s} +1:1: ", .{file}),
        };
        try r.color(sevColor(sev));
        try w.print("{s}: ", .{sev.label()});
        try r.color(reset);
        try r.color(bold);
        try w.writeAll(msg);
        if (group) |g| try w.print(" [{s}]", .{g});
        try r.color(reset);
        try w.writeByte('\n');
        if (loc.isNone() or !r.style.snippets) return;
        try r.snippet(loc, len, fixit);
    }

    fn snippet(r: *Renderer, loc: Loc, len: u32, fixit: ?[]const u8) !void {
        const w = r.w;
        const line = r.sm.lineText(loc);
        const col = r.sm.lineCol(loc).col;
        try w.print("{s}\n", .{line});
        const caret_at = col - 1;
        // Indentation keeps tabs so the caret lines up with the source.
        for (0..caret_at) |i| try w.writeByte(if (i < line.len and line[i] == '\t') '\t' else ' ');
        try r.color("\x1b[1;32m");
        try w.writeByte('^');
        if (len > 1) {
            const end = @min(caret_at + len, line.len);
            if (end > caret_at + 1) try w.splatByteAll('~', end - caret_at - 1);
        }
        try r.color(reset);
        try w.writeByte('\n');
        if (fixit) |text| {
            for (0..caret_at) |i| try w.writeByte(if (i < line.len and line[i] == '\t') '\t' else ' ');
            try r.color("\x1b[0;32m");
            try w.writeAll(text);
            try r.color(reset);
            try w.writeByte('\n');
        }
    }
};

test "rendering: ranges, notes, fix-its, groups, formats" {
    const gpa = std.testing.allocator;
    var mfs: source.MemoryFs = .{};
    var sm = source.SourceManager.init(gpa, mfs.fileSystem());
    defer sm.deinit();
    const f = try sm.addFile("a.hlsl", "float x = foo(1\n\tint y;\n");
    var d = Diagnostics.init(gpa);
    defer d.deinit();
    const e = d.report(.{ .severity = .@"error", .loc = .{ .file = f, .offset = 15 }, .fixit = ")" }, "expected ')'", .{});
    d.note(e, .{ .file = f, .offset = 13 }, 1, "to match this '('", .{});
    _ = d.report(.{ .severity = .warning, .loc = .{ .file = f, .offset = 17 }, .len = 3, .group = "demo" }, "suspicious", .{});

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try d.render(&sm, &out.writer, .{});
    try std.testing.expectEqualStrings(
        \\a.hlsl:1:16: error: expected ')'
        \\float x = foo(1
        \\               ^
        \\               )
        \\a.hlsl:1:14: note: to match this '('
        \\float x = foo(1
        \\             ^
        \\a.hlsl:2:2: warning: suspicious [-Wdemo]
        \\
    ++ "\tint y;\n\t^~~\n", out.written());

    var out2: std.Io.Writer.Allocating = .init(gpa);
    defer out2.deinit();
    try d.render(&sm, &out2.writer, .{ .format = .msvc, .snippets = false });
    try std.testing.expectEqualStrings(
        \\a.hlsl(1,16): error: expected ')'
        \\a.hlsl(1,14): note: to match this '('
        \\a.hlsl(2,2): warning: suspicious [-Wdemo]
        \\
    , out2.written());
}

test "warning policy and error limit" {
    const gpa = std.testing.allocator;
    var d = Diagnostics.init(gpa);
    defer d.deinit();
    try d.disableGroup("quiet");
    try std.testing.expect(d.report(.{ .severity = .warning, .loc = .none, .group = "quiet" }, "x", .{}) == null);
    d.warnings_as_errors = true;
    const w = d.report(.{ .severity = .warning, .loc = .none, .group = "loud" }, "y", .{}).?;
    try std.testing.expectEqual(Severity.@"error", w.severity);
    d.error_limit = 2;
    d.err(.none, "e2", .{});
    d.err(.none, "e3", .{});
    var mfs: source.MemoryFs = .{};
    var sm = source.SourceManager.init(gpa, mfs.fileSystem());
    defer sm.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try d.render(&sm, &out.writer, .{});
    try std.testing.expectEqualStrings(
        \\error: y [-Werror,-Wloud]
        \\error: e2
        \\fatal error: too many errors emitted, stopping now
        \\
    , out.written());
}

test "a fatal error hides only what follows it" {
    const gpa = std.testing.allocator;
    var d = Diagnostics.init(gpa);
    defer d.deinit();
    d.position = 10;
    d.add(.fatal, .none, "missing include", .{});
    try std.testing.expect(d.stoppedAt(10) and !d.stoppedAt(9));
    d.position = 5;
    d.err(.none, "earlier parse error", .{});
    d.position = 12;
    d.err(.none, "later error", .{});
    try std.testing.expectEqual(@as(usize, 2), d.list.items.len);
    try std.testing.expectEqualStrings("earlier parse error", d.sorted()[0].message);
}
