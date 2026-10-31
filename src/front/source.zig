//! Source files and locations.

const std = @import("std");
const Allocator = std.mem.Allocator;
const scan = @import("scan.zig");

pub const FileId = u32;

pub const Loc = struct {
    file: FileId,
    /// Byte offset into the file's (line-spliced) text.
    offset: u32,

    pub const none: Loc = .{ .file = std.math.maxInt(FileId), .offset = 0 };

    pub fn isNone(l: Loc) bool {
        return l.file == none.file;
    }
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

/// In-memory file system: path -> contents.
pub const MemoryFs = struct {
    files: std.StringHashMapUnmanaged([]const u8) = .empty,

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
};

pub const LineCol = struct { line: u32, col: u32 };

pub const SourceManager = struct {
    arena: std.heap.ArenaAllocator,
    files: std.ArrayList(File) = .empty,
    fs: FileSystem,
    /// path -> contents, or null if the path could not be read.
    cache: std.StringHashMapUnmanaged(?*Content) = .empty,

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
        const no_bom = if (std.mem.startsWith(u8, raw, "\xEF\xBB\xBF")) raw[3..] else raw;
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

    /// 1-based line and column.
    pub fn lineCol(sm: *const SourceManager, loc: Loc) LineCol {
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
    pub fn lineText(sm: *const SourceManager, loc: Loc) []const u8 {
        const f = sm.file(loc.file);
        const lc = sm.lineCol(loc);
        const start = f.line_starts[lc.line - 1];
        var end = start;
        while (end < f.text.len and f.text[end] != '\n' and f.text[end] != '\r') end += 1;
        return f.text[start..end];
    }
};

fn spliceLines(a: Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, raw.len);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\') {
            var j = i + 1;
            // Clang tolerates whitespace between the backslash and newline.
            while (j < raw.len and (raw[j] == ' ' or raw[j] == '\t')) j += 1;
            if (j < raw.len and raw[j] == '\n') {
                i = j + 1;
                continue;
            }
            if (j + 1 < raw.len and raw[j] == '\r' and raw[j + 1] == '\n') {
                i = j + 2;
                continue;
            }
        }
        out.appendAssumeCapacity(raw[i]);
        i += 1;
    }
    return out.items;
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

test "line splicing" {
    var mfs: MemoryFs = .{};
    var sm = SourceManager.init(std.testing.allocator, mfs.fileSystem());
    defer sm.deinit();
    const id = try sm.addFile("a.hlsl", "#define A 1 \\\n + 2\nx");
    try std.testing.expectEqualStrings("#define A 1  + 2\nx", sm.file(id).text);
}
