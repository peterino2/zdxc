//! Source files and locations.

const std = @import("std");
const BumpArena = @import("../BumpArena.zig");
const Allocator = std.mem.Allocator;
const scan = @import("scan.zig");

pub const FileId = u32;

/// A source location. Either a file location (`file` is a FileId,
/// `offset` a byte offset), or a macro location (`file` has the top bit set
/// and `offset` indexes SourceManager.expansions), as in clang.
pub const Loc = struct {
    file: FileId,
    /// Byte offset into the file's (line-spliced) text, or an expansion
    /// index for macro locations.
    offset: u32,

    pub const none: Loc = .{ .file = std.math.maxInt(FileId), .offset = 0 };
    const macro_bit: FileId = 1 << 31;

    pub fn isNone(l: Loc) bool {
        return l.file == none.file;
    }

    pub fn isMacro(l: Loc) bool {
        return !l.isNone() and l.file & macro_bit != 0;
    }

    pub fn advance(l: Loc, n: u32) Loc {
        if (l.isNone() or l.isMacro()) return l;
        return .{ .file = l.file, .offset = l.offset + n };
    }
};

/// One token produced by a macro expansion.
pub const Expansion = struct {
    /// Where the token was spelled: in the macro definition, or for
    /// argument tokens at the invocation. May itself be a macro location.
    spelling: Loc,
    /// Location of the macro name being expanded (may be a macro location
    /// for nested expansions).
    expansion: Loc,
    macro_name: []const u8,
    /// The token came from a macro argument: it is reported at its own
    /// spelling rather than at the macro name.
    is_arg: bool,
};

/// Reads files on behalf of the compiler (real filesystem, or in-memory for
/// tests and for in-process callers).
pub const FileSystem = struct {
    ctx: *anyopaque,
    readFn: *const fn (ctx: *anyopaque, gpa: Allocator, path: []const u8) ?[]const u8,

    pub fn read(fs: FileSystem, gpa: Allocator, path: []const u8) ?[]const u8 {
        return fs.readFn(fs.ctx, gpa, path);
    }
};

/// In-memory file system: path -> contents. Paths compare as on the disk:
/// on Windows `\` and `/` are the same separator, so a file put as
/// "inc/a.h" reads as "inc\a.h" (the preprocessor joins -I directories with
/// the OS's separator, as dxc does).
pub const MemoryFs = struct {
    files: std.HashMapUnmanaged([]const u8, []const u8, PathContext, std.hash_map.default_max_load_percentage) = .empty,

    const PathContext = struct {
        pub fn hash(_: PathContext, path: []const u8) u64 {
            var h: std.hash.Wyhash = .init(0);
            for (path) |c| h.update(&.{fold(c)});
            return h.final();
        }

        pub fn eql(_: PathContext, a: []const u8, b: []const u8) bool {
            if (a.len != b.len) return false;
            for (a, b) |x, y| if (fold(x) != fold(y)) return false;
            return true;
        }

        fn fold(c: u8) u8 {
            return if (std.fs.path.isSep(c)) '/' else c;
        }
    };

    pub fn put(m: *MemoryFs, gpa: Allocator, path: []const u8, text: []const u8) !void {
        try m.files.put(gpa, path, text);
    }

    pub fn deinit(m: *MemoryFs, gpa: Allocator) void {
        m.files.deinit(gpa);
    }

    pub fn fileSystem(m: *MemoryFs) FileSystem {
        return .{ .ctx = m, .readFn = readImpl };
    }

    fn readImpl(ctx: *anyopaque, gpa: Allocator, path: []const u8) ?[]const u8 {
        const m: *MemoryFs = @ptrCast(@alignCast(ctx));
        const text = m.files.get(path) orelse return null;
        return gpa.dupe(u8, text) catch null;
    }
};

/// Real file system through std.Io.
pub const DiskFs = struct {
    io: std.Io,

    pub fn fileSystem(d: *DiskFs) FileSystem {
        return .{ .ctx = d, .readFn = readImpl };
    }

    fn readImpl(ctx: *anyopaque, gpa: Allocator, path: []const u8) ?[]const u8 {
        const d: *DiskFs = @ptrCast(@alignCast(ctx));
        return std.Io.Dir.cwd().readFileAlloc(d.io, path, gpa, .limited(256 << 20)) catch null;
    }
};

/// Text of a source file, shared by every inclusion of it.
pub const Content = struct {
    text: []const u8,
    /// Offsets of the first byte of each line.
    line_starts: []const u32,
    /// Include-guard macro, computed lazily by the preprocessor.
    guard: Guard = .unknown,

    pub const Guard = union(enum) {
        unknown,
        none,
        macro: []const u8,
    };
};

/// One inclusion of a file. Each `#include` gets its own FileId (so that
/// `#line` and other per-inclusion state stay separate) but shares Content.
pub const File = struct {
    path: []const u8,
    text: []const u8,
    line_starts: []const u32,
    content: *Content,
    /// Location of the `#include` that entered this file (none for the
    /// main file and pseudo-files).
    included_from: Loc = .none,
};

pub const LineCol = struct { line: u32, col: u32 };

/// A `#line` directive: lines after `phys_line` are renumbered from `line`.
pub const LineOverride = struct {
    phys_line: u32,
    line: u32,
    name: ?[]const u8,
};

/// File name and line as remapped by `#line`.
pub const PresumedLoc = struct { file: []const u8, line: u32 };

pub const SourceManager = struct {
    arena: BumpArena,
    files: std.ArrayList(File) = .empty,
    fs: FileSystem,
    /// path -> contents, or null if the path could not be read.
    cache: std.StringHashMapUnmanaged(?*Content) = .empty,
    expansions: std.ArrayList(Expansion) = .empty,
    line_overrides: std.AutoHashMapUnmanaged(FileId, std.ArrayList(LineOverride)) = .empty,

    pub fn init(gpa: Allocator, fs: FileSystem) SourceManager {
        return .{ .arena = .init(gpa), .fs = fs };
    }

    pub fn deinit(sm: *SourceManager) void {
        sm.arena.deinit();
    }

    pub fn allocator(sm: *SourceManager) Allocator {
        return sm.arena.allocator();
    }

    /// Load a file through the cache; null if it cannot be read. Each call
    /// returns a new FileId, but the file system is read once per path.
    pub fn load(sm: *SourceManager, path: []const u8) !?FileId {
        const a = sm.allocator();
        const gop = try sm.cache.getOrPut(a, path);
        if (!gop.found_existing) {
            gop.key_ptr.* = try a.dupe(u8, path);
            gop.value_ptr.* = if (sm.fs.read(a, path)) |raw| try sm.makeContent(raw) else null;
        }
        const content = gop.value_ptr.* orelse return null;
        return try sm.addInclusion(path, content);
    }

    /// Register in-memory text under `path`, through the same cache as
    /// `load` (used for compiled-in headers).
    pub fn loadText(sm: *SourceManager, path: []const u8, raw: []const u8) !FileId {
        const a = sm.allocator();
        const gop = try sm.cache.getOrPut(a, path);
        if (!gop.found_existing or gop.value_ptr.* == null) {
            gop.key_ptr.* = try a.dupe(u8, path);
            gop.value_ptr.* = try sm.makeContent(raw);
        }
        return sm.addInclusion(path, gop.value_ptr.*.?);
    }

    /// Register uncached text under `path` (main file text, predefines).
    pub fn addFile(sm: *SourceManager, path: []const u8, raw: []const u8) !FileId {
        return sm.addInclusion(path, try sm.makeContent(raw));
    }

    /// Backslash-newline sequences are removed (translation phase 2), so
    /// offsets refer to the spliced text.
    fn makeContent(sm: *SourceManager, raw: []const u8) !*Content {
        const a = sm.allocator();
        const utf8 = try decodeUtf16(a, raw) orelse raw;
        const no_bom = if (std.mem.startsWith(u8, utf8, "\xEF\xBB\xBF")) utf8[3..] else utf8;
        const text = try spliceLines(a, no_bom);
        var starts: std.ArrayList(u32) = .empty;
        try starts.ensureTotalCapacity(a, text.len / 32 + 16);
        starts.appendAssumeCapacity(0);
        try scan.appendLineStarts(a, &starts, text);
        const content = try a.create(Content);
        content.* = .{ .text = text, .line_starts = try starts.toOwnedSlice(a) };
        return content;
    }

    fn addInclusion(sm: *SourceManager, path: []const u8, content: *Content) !FileId {
        const a = sm.allocator();
        try sm.files.append(a, .{
            .path = try a.dupe(u8, path),
            .text = content.text,
            .line_starts = content.line_starts,
            .content = content,
        });
        return @intCast(sm.files.items.len - 1);
    }

    pub fn file(sm: *const SourceManager, id: FileId) *const File {
        return &sm.files.items[id];
    }

    pub fn addLineOverride(sm: *SourceManager, id: FileId, ov: LineOverride) !void {
        const a = sm.allocator();
        const gop = try sm.line_overrides.getOrPut(a, id);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, ov);
    }

    /// File name and line of `loc` after `#line` remapping.
    pub fn presumedLoc(sm: *const SourceManager, loc: Loc) PresumedLoc {
        if (loc.isNone()) return .{ .file = "<unknown>", .line = 0 };
        const fl = sm.fileLoc(loc);
        return sm.presumedLine(fl.file, sm.lineCol(fl).line);
    }

    pub fn presumedLine(sm: *const SourceManager, id: FileId, phys: u32) PresumedLoc {
        var result: PresumedLoc = .{ .file = sm.file(id).path, .line = phys };
        if (sm.line_overrides.count() == 0) return result;
        if (sm.line_overrides.get(id)) |list| {
            for (list.items) |ov| {
                if (ov.phys_line >= phys) break;
                result.line = ov.line + (phys - ov.phys_line - 1);
                if (ov.name) |n| result.file = n;
            }
        }
        return result;
    }

    pub fn setIncludedFrom(sm: *SourceManager, id: FileId, loc: Loc) void {
        sm.files.items[id].included_from = loc;
    }

    /// Record a macro-expanded token and return its macro location.
    pub fn addExpansion(sm: *SourceManager, e: Expansion) !Loc {
        try sm.expansions.append(sm.allocator(), e);
        return .{ .file = Loc.macro_bit, .offset = @intCast(sm.expansions.items.len - 1) };
    }

    pub fn expansion(sm: *const SourceManager, loc: Loc) *const Expansion {
        std.debug.assert(loc.isMacro());
        return &sm.expansions.items[loc.offset];
    }

    /// The file location a (possibly macro) location is reported at: the
    /// outermost expansion point, or for argument tokens their own position.
    pub fn fileLoc(sm: *const SourceManager, loc: Loc) Loc {
        var l = loc;
        while (l.isMacro()) {
            const e = sm.expansion(l);
            l = if (e.is_arg) e.spelling else e.expansion;
        }
        return l;
    }

    /// Where the token was actually written.
    pub fn spellingLoc(sm: *const SourceManager, loc: Loc) Loc {
        var l = loc;
        while (l.isMacro()) l = sm.expansion(l).spelling;
        return l;
    }

    /// 1-based line and column (macro locations are resolved to fileLoc).
    pub fn lineCol(sm: *const SourceManager, loc_in: Loc) LineCol {
        const loc = sm.fileLoc(loc_in);
        const f = sm.file(loc.file);
        const idx = std.sort.upperBound(u32, f.line_starts, loc.offset, struct {
            fn cmp(target: u32, x: u32) std.math.Order {
                return std.math.order(target, x);
            }
        }.cmp);
        const line: u32 = @intCast(idx);
        return .{ .line = line, .col = loc.offset - f.line_starts[line - 1] + 1 };
    }

    /// Text of the line containing `loc`, without the newline.
    pub fn lineText(sm: *const SourceManager, loc_in: Loc) []const u8 {
        const loc = sm.fileLoc(loc_in);
        const f = sm.file(loc.file);
        const lc = sm.lineCol(loc);
        const start = f.line_starts[lc.line - 1];
        var end = start;
        while (end < f.text.len and f.text[end] != '\n' and f.text[end] != '\r') end += 1;
        return f.text[start..end];
    }
};

/// UTF-16 text with a byte-order mark is converted to UTF-8 (as dxc does);
/// returns null for anything else.
fn decodeUtf16(a: Allocator, raw: []const u8) !?[]const u8 {
    if (raw.len < 2) return null;
    const little = raw[0] == 0xFF and raw[1] == 0xFE;
    const big = raw[0] == 0xFE and raw[1] == 0xFF;
    if (!little and !big) return null;
    const units = try a.alloc(u16, (raw.len - 2) / 2);
    for (units, 0..) |*u, i| {
        const b = raw[2 + 2 * i ..][0..2];
        u.* = if (little) std.mem.readInt(u16, b, .little) else std.mem.readInt(u16, b, .big);
    }
    // Lone surrogates make the text invalid; fall back to the raw bytes.
    return std.unicode.utf16LeToUtf8Alloc(a, units) catch null;
}

fn spliceLines(a: Allocator, raw: []const u8) ![]const u8 {
    var i = std.mem.indexOfScalar(u8, raw, '\\') orelse return raw;
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, raw.len);
    out.appendSliceAssumeCapacity(raw[0..i]);
    // At a backslash: a splice, or the backslash kept; then the run to the
    // next backslash, copied whole.
    while (i < raw.len) {
        var j = i + 1;
        // Clang tolerates whitespace between the backslash and newline.
        while (j < raw.len and (raw[j] == ' ' or raw[j] == '\t')) j += 1;
        if (j < raw.len and raw[j] == '\n') {
            i = j + 1;
        } else if (j + 1 < raw.len and raw[j] == '\r' and raw[j + 1] == '\n') {
            i = j + 2;
        } else {
            out.appendAssumeCapacity('\\');
            i += 1;
        }
        const next = std.mem.indexOfScalarPos(u8, raw, i, '\\') orelse raw.len;
        out.appendSliceAssumeCapacity(raw[i..next]);
        i = next;
    }
    return out.items;
}

test spliceLines {
    const cases = [_][2][]const u8{
        .{ "a\\\nb", "ab" },
        .{ "a\\ \t\r\nb\\", "ab\\" },
        .{ "\\x\\\\\ny", "\\x\\y" },
        .{ "no splice", "no splice" },
        .{ "#define A 1 \\\n + 2\n", "#define A 1  + 2\n" },
    };
    for (cases) |c| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectEqualStrings(c[1], try spliceLines(arena.allocator(), c[0]));
    }
}

test "line and column lookup" {
    var mfs: MemoryFs = .{};
    var sm = SourceManager.init(std.testing.allocator, mfs.fileSystem());
    defer sm.deinit();
    const id = try sm.addFile("a.hlsl", "ab\ncd\n\nx");
    try std.testing.expectEqual(LineCol{ .line = 1, .col = 1 }, sm.lineCol(.{ .file = id, .offset = 0 }));
    try std.testing.expectEqual(LineCol{ .line = 2, .col = 2 }, sm.lineCol(.{ .file = id, .offset = 4 }));
    try std.testing.expectEqual(LineCol{ .line = 4, .col = 1 }, sm.lineCol(.{ .file = id, .offset = 7 }));
    try std.testing.expectEqualStrings("cd", sm.lineText(.{ .file = id, .offset = 3 }));
}

test "files are read once per path" {
    var mfs: MemoryFs = .{};
    defer mfs.deinit(std.testing.allocator);
    try mfs.put(std.testing.allocator, "a.h", "x");
    var sm = SourceManager.init(std.testing.allocator, mfs.fileSystem());
    defer sm.deinit();
    const a = (try sm.load("a.h")).?;
    const b = (try sm.load("a.h")).?;
    try std.testing.expect(a != b);
    try std.testing.expectEqual(sm.file(a).content, sm.file(b).content);
    try std.testing.expect(try sm.load("missing.h") == null);
    try std.testing.expect(try sm.load("missing.h") == null);
}

test "UTF-16 sources are decoded" {
    var mfs: MemoryFs = .{};
    var sm = SourceManager.init(std.testing.allocator, mfs.fileSystem());
    defer sm.deinit();
    const id = try sm.addFile("le.hlsl", "\xFF\xFEi\x00n\x00t\x00");
    try std.testing.expectEqualStrings("int", sm.file(id).text);
    const id2 = try sm.addFile("be.hlsl", "\xFE\xFF\x00x");
    try std.testing.expectEqualStrings("x", sm.file(id2).text);
}

test "line splicing" {
    var mfs: MemoryFs = .{};
    var sm = SourceManager.init(std.testing.allocator, mfs.fileSystem());
    defer sm.deinit();
    const id = try sm.addFile("a.hlsl", "#define A 1 \\\n + 2\nx");
    try std.testing.expectEqualStrings("#define A 1  + 2\nx", sm.file(id).text);
}
