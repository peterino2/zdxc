//! Diagnostics: collected during compilation and rendered clang-style.

const std = @import("std");
const Allocator = std.mem.Allocator;
const source = @import("front/source.zig");

pub const Severity = enum {
    note,
    warning,
    @"error",
    fatal,
};

pub const Diagnostic = struct {
    severity: Severity,
    loc: source.Loc,
    message: []const u8,
};

pub const Diagnostics = struct {
    arena: std.heap.ArenaAllocator,
    list: std.ArrayList(Diagnostic) = .empty,
    error_count: u32 = 0,
    warning_count: u32 = 0,
    /// -WX
    warnings_as_errors: bool = false,
    /// -no-warnings
    suppress_warnings: bool = false,

    pub fn init(gpa: Allocator) Diagnostics {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(d: *Diagnostics) void {
        d.arena.deinit();
    }

    pub fn add(d: *Diagnostics, severity: Severity, loc: source.Loc, comptime fmt: []const u8, args: anytype) void {
        var sev = severity;
        if (sev == .warning) {
            if (d.suppress_warnings) return;
            if (d.warnings_as_errors) sev = .@"error";
        }
        const a = d.arena.allocator();
        const msg = std.fmt.allocPrint(a, fmt, args) catch "out of memory formatting diagnostic";
        d.list.append(a, .{ .severity = sev, .loc = loc, .message = msg }) catch return;
        switch (sev) {
            .@"error", .fatal => d.error_count += 1,
            .warning => d.warning_count += 1,
            .note => {},
        }
    }

    pub fn err(d: *Diagnostics, loc: source.Loc, comptime fmt: []const u8, args: anytype) void {
        d.add(.@"error", loc, fmt, args);
    }

    pub fn warn(d: *Diagnostics, loc: source.Loc, comptime fmt: []const u8, args: anytype) void {
        d.add(.warning, loc, fmt, args);
    }

    pub fn hasErrors(d: *const Diagnostics) bool {
        return d.error_count != 0;
    }

    /// Render all diagnostics as `file:line:col: error: message` followed by
    /// the source line and a caret.
    pub fn render(d: *const Diagnostics, sm: *const source.SourceManager, w: *std.Io.Writer) !void {
        for (d.list.items) |diag| {
            if (diag.loc.isNone()) {
                try w.print("{s}: {s}\n", .{ @tagName(diag.severity), diag.message });
                continue;
            }
            const f = sm.file(diag.loc.file);
            const lc = sm.lineCol(diag.loc);
            try w.print("{s}:{d}:{d}: {s}: {s}\n", .{ f.path, lc.line, lc.col, @tagName(diag.severity), diag.message });
            const line = sm.lineText(diag.loc);
            try w.print("{s}\n", .{line});
            for (0..lc.col - 1) |i| try w.writeByte(if (i < line.len and line[i] == '\t') '\t' else ' ');
            try w.writeAll("^\n");
        }
    }
};
