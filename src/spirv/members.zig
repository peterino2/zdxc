//! Members of buffer structs nothing reads are removed, as spirv-opt's
//! eliminate-dead-members leaves dxc's SPIR-V: from the structs of uniform,
//! push constant and shader record buffers, the members no access chain or
//! extract reaches go, with their names and decorations, and the indices of
//! the rest are renumbered (their Offsets stay).
//!
//! Unreal's Vulkan format finds the loose parameters a shader uses by the
//! members of `$Globals` and of a shader record's
//! `VulkanShaderRecordLooseParameterData` that are left; "The compiler
//! doesn't decorate unused members". A member left that the shader does not
//! use is a parameter Unreal looks for and, for ray tracing, a fatal cook
//! error.
//!
//! Anything the walk cannot follow (a whole struct copied, stored, passed or
//! selected) keeps every member of that struct and what it contains.

const std = @import("std");
const Allocator = std.mem.Allocator;
const builder = @import("builder.zig");

const Section = builder.Section;

const Kind = enum { none, structure, array, pointer, vector, other };
const TypeInfo = struct {
    kind: Kind = .none,
    /// The element (array, vector, matrix) or pointee (pointer).
    elem: u32 = 0,
    storage: u32 = 0,
    /// Members of a struct: the start of its member words in types_globals.
    start: usize = 0,
    len: usize = 0,
};

fn forEach(words: []const u32, ctx: anytype, f: fn (@TypeOf(ctx), usize, []const u32) Allocator.Error!void) !void {
    var pos: usize = 0;
    while (pos < words.len) {
        const len = @max(words[pos] >> 16, 1);
        if (pos + len > words.len) return;
        try f(ctx, pos, words[pos..][0..len]);
        pos += len;
    }
}

const Ctx = struct {
    a: Allocator,
    b: *builder.Builder,
    bound: u32,
    types: []TypeInfo,
    /// Struct id → used flags per member (candidates only).
    used: std.AutoHashMapUnmanaged(u32, []bool) = .empty,
    /// Structs reached from storage other than the candidate classes.
    excluded: []bool,
    /// Value and pointer ids → their type, for tracked results.
    value_type: []u32,
    constants: std.AutoHashMapUnmanaged(u32, struct { ty: u32, value: u32 }) = .empty,

    fn members(c: *Ctx, s: u32) []const u32 {
        const t = c.types[s];
        return c.b.sections.getPtr(.types_globals).items[t.start..][0..t.len];
    }

    /// Whether a type is or contains (through arrays, pointers and members)
    /// a candidate struct.
    fn involves(c: *Ctx, ty: u32, depth: u32) bool {
        if (ty >= c.bound or depth > 64) return false;
        const t = c.types[ty];
        return switch (t.kind) {
            .structure => blk: {
                if (c.used.contains(ty)) break :blk true;
                for (c.members(ty)) |m| if (c.involves(m, depth + 1)) break :blk true;
                break :blk false;
            },
            .array, .pointer => c.involves(t.elem, depth + 1),
            else => false,
        };
    }

    fn markAll(c: *Ctx, ty: u32, depth: u32) void {
        if (ty >= c.bound or depth > 64) return;
        const t = c.types[ty];
        switch (t.kind) {
            .structure => {
                if (c.used.get(ty)) |u| @memset(u, true);
                for (c.members(ty)) |m| c.markAll(m, depth + 1);
            },
            .array, .pointer => c.markAll(t.elem, depth + 1),
            else => {},
        }
    }

    fn markValue(c: *Ctx, id: u32) void {
        if (id < c.bound and c.value_type[id] != 0) c.markAll(c.value_type[id], 0);
    }

    /// Walks indices from `ty`: ids of constants (`literal` false) or literals.
    fn walk(c: *Ctx, start: u32, indices: []const u32, literal: bool) void {
        var ty = start;
        for (indices) |ix| {
            if (ty >= c.bound) return;
            const t = c.types[ty];
            switch (t.kind) {
                .structure => {
                    const k: u32 = if (literal) ix else if (c.constants.get(ix)) |k| k.value else {
                        c.markAll(ty, 0);
                        return;
                    };
                    const ms = c.members(ty);
                    if (k >= ms.len) return;
                    if (c.used.get(ty)) |u| u[k] = true;
                    ty = ms[k];
                },
                .array, .vector => ty = t.elem,
                else => return,
            }
        }
        // What the chain ends at is used as a whole by whoever uses it,
        // decided at those uses.
    }
};

fn collectTypes(c: *Ctx, pos: usize, w: []const u32) Allocator.Error!void {
    const op: u16 = @truncate(w[0]);
    switch (op) {
        30 => if (w.len >= 2 and w[1] < c.bound) {
            c.types[w[1]] = .{ .kind = .structure, .start = pos + 2, .len = w.len - 2 };
        },
        28, 29 => if (w.len >= 3 and w[1] < c.bound) {
            c.types[w[1]] = .{ .kind = .array, .elem = w[2] };
        },
        23, 24 => if (w.len >= 3 and w[1] < c.bound) {
            c.types[w[1]] = .{ .kind = .vector, .elem = w[2] };
        },
        32 => if (w.len >= 4 and w[1] < c.bound) {
            c.types[w[1]] = .{ .kind = .pointer, .storage = w[2], .elem = w[3] };
        },
        43 => if (w.len >= 4) try c.constants.put(c.a, w[2], .{ .ty = w[1], .value = w[3] }),
        else => {},
    }
}

fn candidateStorage(sc: u32) bool {
    // Uniform, PushConstant, ShaderRecordBufferKHR.
    return sc == 2 or sc == 9 or sc == 5343;
}

fn reach(c: *Ctx, ty: u32, candidate: bool, depth: u32) !void {
    if (ty >= c.bound or depth > 64) return;
    const t = c.types[ty];
    switch (t.kind) {
        .structure => {
            if (candidate) {
                if (!c.used.contains(ty)) {
                    const u = try c.a.alloc(bool, t.len);
                    @memset(u, false);
                    try c.used.put(c.a, ty, u);
                }
            } else c.excluded[ty] = true;
            for (c.members(ty)) |m| try reach(c, m, candidate, depth + 1);
        },
        .array => try reach(c, t.elem, candidate, depth + 1),
        else => {},
    }
}

fn trackDefs(c: *Ctx, _: usize, w: []const u32) Allocator.Error!void {
    const op: u16 = @truncate(w[0]);
    switch (op) {
        59, 61, 65, 66, 67 => if (w.len >= 3 and w[2] < c.bound and c.involves(w[1], 0)) {
            c.value_type[w[2]] = w[1];
        },
        else => {},
    }
}

fn uses(c: *Ctx, _: usize, w: []const u32) Allocator.Error!void {
    const op: u16 = @truncate(w[0]);
    switch (op) {
        // OpVariable (a local of a candidate type: what is stored decides).
        59 => return,
        // OpLoad: the value's uses decide.
        61 => if (w.len >= 4 and w[2] < c.bound and c.value_type[w[2]] != 0) return,
        65, 66 => if (w.len >= 4 and w[3] < c.bound and c.value_type[w[3]] != 0) {
            const pt = c.types[c.value_type[w[3]]];
            c.walk(pt.elem, w[4..], false);
            return;
        },
        67 => if (w.len >= 5 and w[3] < c.bound and c.value_type[w[3]] != 0) {
            const pt = c.types[c.value_type[w[3]]];
            c.walk(pt.elem, w[5..], false);
            return;
        },
        81 => if (w.len >= 4 and w[3] < c.bound and c.value_type[w[3]] != 0) {
            c.walk(c.value_type[w[3]], w[4..], true);
            return;
        },
        else => {},
    }
    // Anything else: every tracked id among its words, and a candidate
    // result type, keeps everything.
    for (w[1..]) |x| c.markValue(x);
    if (w.len >= 2 and w[1] < c.bound and c.types[w[1]].kind == .structure) c.markAll(w[1], 0);
}

fn globalsUses(c: *Ctx, _: usize, w: []const u32) Allocator.Error!void {
    const op: u16 = @truncate(w[0]);
    switch (op) {
        // Type declarations and variables.
        19...39, 59 => {},
        // OpConstant and the like of a struct type, OpConstantComposite,
        // OpUndef, OpConstantNull: whole.
        else => if (w.len >= 2) c.markAll(w[1], 0),
    }
}

/// Whether anything changed.
pub fn run(a: Allocator, b: *builder.Builder) Allocator.Error!bool {
    const bound: u32 = b.next_id;
    var c: Ctx = .{
        .a = a,
        .b = b,
        .bound = bound,
        .types = try a.alloc(TypeInfo, bound),
        .excluded = try a.alloc(bool, bound),
        .value_type = try a.alloc(u32, bound),
    };
    @memset(c.types, .{});
    @memset(c.excluded, false);
    @memset(c.value_type, 0);
    const globals = b.sections.getPtr(.types_globals).items;
    try forEach(globals, &c, collectTypes);
    // Candidates: structs reached from candidate pointers, less those also
    // reached from any other storage.
    for (c.types) |t| if (t.kind == .pointer) try reach(&c, t.elem, candidateStorage(t.storage), 0);
    {
        var it = c.used.keyIterator();
        var drop: std.ArrayList(u32) = .empty;
        while (it.next()) |k| if (c.excluded[k.*]) try drop.append(a, k.*);
        for (drop.items) |k| _ = c.used.remove(k);
    }
    if (c.used.count() == 0) return false;
    try forEach(globals, &c, globalsUses);
    try forEach(globals, &c, trackDefs);
    try forEach(b.sections.getPtr(.functions).items, &c, trackDefs);
    try forEach(b.sections.getPtr(.functions).items, &c, uses);
    // Member maps of the structs that lose members: old index → new, or
    // null. (A struct none of whose members is used is left: dead code
    // elimination removes what nothing reaches.)
    var maps: std.AutoHashMapUnmanaged(u32, []?u32) = .empty;
    {
        var it = c.used.iterator();
        while (it.next()) |e| {
            const u = e.value_ptr.*;
            var n: u32 = 0;
            for (u) |x| n += @intFromBool(x);
            if (n == 0 or n == u.len) continue;
            const map = try a.alloc(?u32, u.len);
            var k: u32 = 0;
            for (u, 0..) |x, i| {
                map[i] = if (x) k else null;
                if (x) k += 1;
            }
            try maps.put(a, e.key_ptr.*, map);
        }
    }
    if (maps.count() == 0) return false;
    try rewrite(&c, &maps);
    return true;
}

const Rewrite = struct {
    c: *Ctx,
    maps: *std.AutoHashMapUnmanaged(u32, []?u32),
    out: std.ArrayList(u32) = .empty,
    /// (type, value) → constant id, for renumbered indices.
    by_value: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    new_constants: std.ArrayList(u32) = .empty,

    fn constant(r: *Rewrite, ty: u32, value: u32) !u32 {
        const key = (@as(u64, ty) << 32) | value;
        if (r.by_value.get(key)) |id| return id;
        const id = r.c.b.newId();
        try r.new_constants.appendSlice(r.c.a, &.{ (4 << 16) | 43, ty, id, value });
        try r.by_value.put(r.c.a, key, id);
        return id;
    }

    /// Renumbers indices from `start`, in place in `idx`.
    fn renumber(r: *Rewrite, start: u32, idx: []u32, literal: bool) !void {
        const c = r.c;
        var ty = start;
        for (idx) |*ix| {
            if (ty >= c.bound) return;
            const t = c.types[ty];
            switch (t.kind) {
                .structure => {
                    const k: u32 = if (literal) ix.* else if (c.constants.get(ix.*)) |k| k.value else return;
                    const ms = c.members(ty);
                    if (k >= ms.len) return;
                    if (r.maps.get(ty)) |map| {
                        const nk = map[k] orelse return;
                        if (nk != k) {
                            if (literal) ix.* = nk else ix.* = try r.constant(c.constants.get(ix.*).?.ty, nk);
                        }
                    }
                    ty = ms[k];
                },
                .array, .vector => ty = t.elem,
                else => return,
            }
        }
    }
};

fn rewriteGlobals(r: *Rewrite, _: usize, w: []const u32) Allocator.Error!void {
    const op: u16 = @truncate(w[0]);
    if (op == 30 and w.len >= 2) if (r.maps.get(w[1])) |map| {
        var n: u32 = 2;
        for (map) |m| n += @intFromBool(m != null);
        try r.out.append(r.c.a, (n << 16) | 30);
        try r.out.append(r.c.a, w[1]);
        for (map, w[2..]) |m, ty| if (m != null) try r.out.append(r.c.a, ty);
        return;
    };
    try r.out.appendSlice(r.c.a, w);
}

fn rewriteFunctions(r: *Rewrite, _: usize, w: []const u32) Allocator.Error!void {
    const c = r.c;
    const op: u16 = @truncate(w[0]);
    const start = r.out.items.len;
    try r.out.appendSlice(c.a, w);
    const nw = r.out.items[start..];
    switch (op) {
        65, 66 => if (w.len >= 4 and w[3] < c.bound and c.value_type[w[3]] != 0) {
            try r.renumber(c.types[c.value_type[w[3]]].elem, nw[4..], false);
        },
        67 => if (w.len >= 5 and w[3] < c.bound and c.value_type[w[3]] != 0) {
            try r.renumber(c.types[c.value_type[w[3]]].elem, nw[5..], false);
        },
        81 => if (w.len >= 4 and w[3] < c.bound and c.value_type[w[3]] != 0) {
            try r.renumber(c.value_type[w[3]], nw[4..], true);
        },
        else => {},
    }
}

fn rewriteAnnotations(r: *Rewrite, _: usize, w: []const u32) Allocator.Error!void {
    const op: u16 = @truncate(w[0]);
    // OpMemberName, OpMemberDecorate, OpMemberDecorateString.
    if ((op == 6 or op == 72 or op == 5633) and w.len >= 3) if (r.maps.get(w[1])) |map| {
        if (w[2] >= map.len) return;
        const nk = map[w[2]] orelse return;
        try r.out.appendSlice(r.c.a, w);
        r.out.items[r.out.items.len - w.len + 2] = nk;
        return;
    };
    try r.out.appendSlice(r.c.a, w);
}

fn rewrite(c: *Ctx, maps: *std.AutoHashMapUnmanaged(u32, []?u32)) !void {
    var r: Rewrite = .{ .c = c, .maps = maps };
    {
        var it = c.constants.iterator();
        while (it.next()) |e| try r.by_value.put(c.a, (@as(u64, e.value_ptr.ty) << 32) | e.value_ptr.value, e.key_ptr.*);
    }
    // Functions first: they may need new constants.
    try forEach(c.b.sections.getPtr(.functions).items, &r, rewriteFunctions);
    const functions = r.out.items;
    r.out = .empty;
    try forEach(c.b.sections.getPtr(.types_globals).items, &r, rewriteGlobals);
    try r.out.appendSlice(c.a, r.new_constants.items);
    const globals = r.out.items;
    for ([_]Section{ .debug_names, .annotations }) |sec| {
        r.out = .empty;
        try forEach(c.b.sections.getPtr(sec).items, &r, rewriteAnnotations);
        const s = c.b.sections.getPtr(sec);
        s.clearRetainingCapacity();
        try s.appendSlice(c.b.gpa, r.out.items);
    }
    inline for (.{ .{ Section.functions, functions }, .{ Section.types_globals, globals } }) |p| {
        const s = c.b.sections.getPtr(p[0]);
        s.clearRetainingCapacity();
        try s.appendSlice(c.b.gpa, p[1]);
    }
}
