//! An arena for one thread: what std.heap.ArenaAllocator does, without the
//! atomic operations that make that one safe to share between threads (an
//! atomic add on every allocation). A compile runs on one thread and
//! allocates millions of times.
//!
//! Memory comes from the child allocator in chunks, each larger than the
//! last; freeing or resizing an allocation works in place only for the
//! most recent one. reset can keep the chunks for the next use.
const BumpArena = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

child: Allocator,
/// Chunks in use, newest first; allocations bump `end` in the newest.
used: ?*Chunk = null,
/// Chunks a reset kept, for reuse.
spare: ?*Chunk = null,
end: usize = 0,

const Chunk = struct {
    next: ?*Chunk,
    /// Bytes after the header.
    len: usize,

    fn data(c: *Chunk) [*]u8 {
        return @as([*]u8, @ptrCast(c)) + @sizeOf(Chunk);
    }
};

const chunk_align: Alignment = .@"16";
const min_chunk = 64 << 10;

pub fn init(child: Allocator) BumpArena {
    return .{ .child = child };
}

pub fn deinit(b: *BumpArena) void {
    freeList(b.child, b.used);
    freeList(b.child, b.spare);
    b.* = undefined;
}

fn freeList(child: Allocator, first: ?*Chunk) void {
    var c = first;
    while (c) |chunk| {
        c = chunk.next;
        const bytes: [*]u8 = @ptrCast(chunk);
        child.rawFree(bytes[0 .. @sizeOf(Chunk) + chunk.len], chunk_align, @returnAddress());
    }
}

pub fn allocator(b: *BumpArena) Allocator {
    return .{ .ptr = b, .vtable = &vtable };
}

const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

/// Total bytes of the chunks held (in use and spare).
pub fn queryCapacity(b: *const BumpArena) usize {
    var n: usize = 0;
    inline for (.{ b.used, b.spare }) |first| {
        var c = first;
        while (c) |chunk| : (c = chunk.next) n += chunk.len;
    }
    return n;
}

pub const ResetMode = std.heap.ArenaAllocator.ResetMode;

/// Frees every allocation. `.retain_capacity` keeps the chunks for reuse;
/// `.retain_with_limit` keeps them up to that many bytes (largest first
/// kept); `.free_all` gives them back.
pub fn reset(b: *BumpArena, mode: ResetMode) bool {
    const limit: usize = switch (mode) {
        .free_all => 0,
        .retain_capacity => std.math.maxInt(usize),
        .retain_with_limit => |l| l,
    };
    // All chunks, then keep the largest that fit under the limit.
    var all = b.used;
    if (all) |first| {
        var last = first;
        while (last.next) |nx| last = nx;
        last.next = b.spare;
    } else all = b.spare;
    b.used = null;
    b.spare = null;
    b.end = 0;
    var kept: usize = 0;
    var c = all;
    while (c) |chunk| {
        c = chunk.next;
        if (kept + chunk.len <= limit) {
            kept += chunk.len;
            chunk.next = null;
            b.addSpare(chunk);
        } else {
            const bytes: [*]u8 = @ptrCast(chunk);
            b.child.rawFree(bytes[0 .. @sizeOf(Chunk) + chunk.len], chunk_align, @returnAddress());
        }
    }
    return true;
}

/// Adds a chunk to the spare list, largest first.
fn addSpare(b: *BumpArena, chunk: *Chunk) void {
    var link = &b.spare;
    while (link.*) |s| : (link = &s.next) if (s.len < chunk.len) break;
    chunk.next = link.*;
    link.* = chunk;
}

fn alloc(ctx: *anyopaque, n: usize, alignment: Alignment, ra: usize) ?[*]u8 {
    const b: *BumpArena = @ptrCast(@alignCast(ctx));
    if (b.used) |c| {
        const base = c.data();
        const start = alignment.forward(@intFromPtr(base) + b.end) - @intFromPtr(base);
        if (start + n <= c.len) {
            b.end = start + n;
            return base + start;
        }
    }
    return b.allocSlow(n, alignment, ra);
}

fn allocSlow(b: *BumpArena, n: usize, alignment: Alignment, ra: usize) ?[*]u8 {
    const need = n + alignment.toByteUnits();
    // A spare chunk big enough (the largest is first), else a new one half
    // again as large as the current.
    const chunk: *Chunk = if (b.spare != null and b.spare.?.len >= need) blk: {
        const s = b.spare.?;
        b.spare = s.next;
        break :blk s;
    } else blk: {
        const grow = if (b.used) |c| c.len + c.len / 2 else 0;
        const len = @max(need, grow, min_chunk);
        const bytes = b.child.rawAlloc(@sizeOf(Chunk) + len, chunk_align, ra) orelse return null;
        const c: *Chunk = @ptrCast(@alignCast(bytes));
        c.len = len;
        break :blk c;
    };
    chunk.next = b.used;
    b.used = chunk;
    const base = chunk.data();
    const start = alignment.forward(@intFromPtr(base)) - @intFromPtr(base);
    b.end = start + n;
    return base + start;
}

/// Whether `buf` is the newest allocation (the only one that can change
/// in place).
fn isLast(b: *const BumpArena, buf: []u8) bool {
    const c = b.used orelse return false;
    return buf.ptr + buf.len == c.data() + b.end;
}

fn resize(ctx: *anyopaque, buf: []u8, _: Alignment, new_len: usize, _: usize) bool {
    const b: *BumpArena = @ptrCast(@alignCast(ctx));
    if (!b.isLast(buf)) return new_len <= buf.len;
    const c = b.used.?;
    const start = @intFromPtr(buf.ptr) - @intFromPtr(c.data());
    if (start + new_len > c.len) return false;
    b.end = start + new_len;
    return true;
}

fn remap(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
    return if (resize(ctx, buf, alignment, new_len, ra)) buf.ptr else null;
}

fn free(ctx: *anyopaque, buf: []u8, _: Alignment, _: usize) void {
    const b: *BumpArena = @ptrCast(@alignCast(ctx));
    if (b.isLast(buf)) b.end -= buf.len;
}

test "allocations, growth in place, reset" {
    var b: BumpArena = .init(std.testing.allocator);
    defer b.deinit();
    const a = b.allocator();
    var list: std.ArrayList(u32) = .empty;
    for (0..100_000) |k| try list.append(a, @intCast(k));
    for (list.items, 0..) |x, k| try std.testing.expectEqual(k, x);
    const big = try a.alignedAlloc(u8, .@"64", 1 << 20);
    try std.testing.expect(std.mem.isAligned(@intFromPtr(big.ptr), 64));
    const cap = b.queryCapacity();
    _ = b.reset(.retain_capacity);
    try std.testing.expectEqual(cap, b.queryCapacity());
    _ = try a.alloc(u8, 100);
    _ = b.reset(.{ .retain_with_limit = 0 });
    try std.testing.expectEqual(0, b.queryCapacity());
}
