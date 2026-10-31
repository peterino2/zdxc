//! Texture and typed-buffer methods, decoded for the backends: which
//! argument plays which role (sampler, coordinate, offset, LOD, ...) in
//! each overload from dxc's intrinsic table.

const std = @import("std");
const types = @import("../sema/types.zig");

pub const Kind = types.ResourceKind;

pub const Dim = enum { d1, d2, d3, cube, buffer };

pub const Shape = struct {
    dim: Dim,
    array: bool = false,
    ms: bool = false,
    rw: bool = false,

    /// Coordinate components, without the array index.
    pub fn coords(s: Shape) u8 {
        return switch (s.dim) {
            .d1, .buffer => 1,
            .d2 => 2,
            .d3, .cube => 3,
        };
    }

    /// Components of a texel offset (none for cubes and buffers).
    pub fn offsets(s: Shape) u8 {
        return switch (s.dim) {
            .d1 => 1,
            .d2 => 2,
            .d3 => 3,
            .cube, .buffer => 0,
        };
    }

    /// Whether the resource has mip levels (Load takes one, GetDimensions
    /// reports them).
    pub fn hasMips(s: Shape) bool {
        return !s.rw and !s.ms and s.dim != .buffer;
    }
};

pub fn shape(kind: Kind) ?Shape {
    return switch (kind) {
        .buffer => .{ .dim = .buffer },
        .rw_buffer => .{ .dim = .buffer, .rw = true },
        .texture1d => .{ .dim = .d1 },
        .texture1d_array => .{ .dim = .d1, .array = true },
        .texture2d => .{ .dim = .d2 },
        .texture2d_array => .{ .dim = .d2, .array = true },
        .texture2dms => .{ .dim = .d2, .ms = true },
        .texture2dms_array => .{ .dim = .d2, .array = true, .ms = true },
        .texture3d => .{ .dim = .d3 },
        .texture_cube => .{ .dim = .cube },
        .texture_cube_array => .{ .dim = .cube, .array = true },
        .rw_texture1d => .{ .dim = .d1, .rw = true },
        .rw_texture1d_array => .{ .dim = .d1, .array = true, .rw = true },
        .rw_texture2d => .{ .dim = .d2, .rw = true },
        .rw_texture2d_array => .{ .dim = .d2, .array = true, .rw = true },
        .rw_texture2dms => .{ .dim = .d2, .ms = true, .rw = true },
        .rw_texture2dms_array => .{ .dim = .d2, .array = true, .ms = true, .rw = true },
        .rw_texture3d => .{ .dim = .d3, .rw = true },
        else => null,
    };
}

pub const Op = enum {
    sample,
    sample_bias,
    sample_level,
    sample_grad,
    sample_cmp,
    sample_cmp_level_zero,
    sample_cmp_level,
    sample_cmp_bias,
    sample_cmp_grad,
    gather,
    gather_cmp,
    load,
    calc_lod,
    calc_lod_unclamped,
    sample_position,

    pub fn isCmp(op: Op) bool {
        return switch (op) {
            .sample_cmp, .sample_cmp_level_zero, .sample_cmp_level, .sample_cmp_bias, .sample_cmp_grad, .gather_cmp => true,
            else => false,
        };
    }

    /// Needs implicit derivatives (pixel shaders only, for zdxc).
    pub fn implicitLod(op: Op) bool {
        return switch (op) {
            .sample, .sample_bias, .sample_cmp, .sample_cmp_bias, .calc_lod, .calc_lod_unclamped => true,
            else => false,
        };
    }
};

/// Argument positions of one method call (null: absent).
pub const Call = struct {
    op: Op,
    sampler: ?u8 = null,
    coord: u8 = 0,
    compare: ?u8 = null,
    bias: ?u8 = null,
    lod: ?u8 = null,
    ddx: ?u8 = null,
    ddy: ?u8 = null,
    /// One offset, or the first of four (Gather with per-texel offsets).
    offset: ?u8 = null,
    offsets4: bool = false,
    clamp: ?u8 = null,
    status: ?u8 = null,
    sample_index: ?u8 = null,
    /// Gather channel: 0 red ... 3 alpha.
    channel: u2 = 0,
};

const Sampled = struct { name: []const u8, op: Op, extra: []const Role, has_clamp: bool };
const Role = enum { compare, bias, lod, ddx, ddy };

const sampled = [_]Sampled{
    .{ .name = "Sample", .op = .sample, .extra = &.{}, .has_clamp = true },
    .{ .name = "SampleBias", .op = .sample_bias, .extra = &.{.bias}, .has_clamp = true },
    .{ .name = "SampleLevel", .op = .sample_level, .extra = &.{.lod}, .has_clamp = false },
    .{ .name = "SampleGrad", .op = .sample_grad, .extra = &.{ .ddx, .ddy }, .has_clamp = true },
    .{ .name = "SampleCmp", .op = .sample_cmp, .extra = &.{.compare}, .has_clamp = true },
    .{ .name = "SampleCmpLevelZero", .op = .sample_cmp_level_zero, .extra = &.{.compare}, .has_clamp = false },
    .{ .name = "SampleCmpLevel", .op = .sample_cmp_level, .extra = &.{ .compare, .lod }, .has_clamp = false },
    .{ .name = "SampleCmpBias", .op = .sample_cmp_bias, .extra = &.{ .compare, .bias }, .has_clamp = true },
    .{ .name = "SampleCmpGrad", .op = .sample_cmp_grad, .extra = &.{ .compare, .ddx, .ddy }, .has_clamp = true },
};

/// Decodes `name(args...)` on a resource of shape `s`; null for methods
/// that are not texture operations (GetDimensions is handled apart).
pub fn decode(name: []const u8, s: Shape, nargs: usize) ?Call {
    const eq = std.mem.eql;
    const n: u8 = @intCast(nargs);
    for (sampled) |sm| if (eq(u8, name, sm.name)) {
        var c: Call = .{ .op = sm.op, .sampler = 0, .coord = 1 };
        var i: u8 = 2;
        for (sm.extra) |r| {
            switch (r) {
                .compare => c.compare = i,
                .bias => c.bias = i,
                .lod => c.lod = i,
                .ddx => c.ddx = i,
                .ddy => c.ddy = i,
            }
            i += 1;
        }
        if (i < n and s.offsets() > 0) {
            c.offset = i;
            i += 1;
        }
        if (sm.has_clamp and i < n and n - i >= 1) {
            // Clamp comes before status; an overload with status has both.
            c.clamp = i;
            i += 1;
        }
        if (i < n) c.status = i;
        return c;
    };
    if (std.mem.startsWith(u8, name, "Gather")) {
        var rest = name["Gather".len..];
        var c: Call = .{ .op = .gather, .sampler = 0, .coord = 1 };
        if (std.mem.startsWith(u8, rest, "Cmp")) {
            c.op = .gather_cmp;
            c.compare = 2;
            rest = rest[3..];
        }
        if (eq(u8, rest, "Raw")) return null;
        c.channel = if (rest.len == 0 or eq(u8, rest, "Red")) 0 else if (eq(u8, rest, "Green")) 1 else if (eq(u8, rest, "Blue")) 2 else if (eq(u8, rest, "Alpha")) 3 else return null;
        const first: u8 = if (c.compare != null) 3 else 2;
        const left = n - first;
        if (s.offsets() == 0) {
            // Cubes take no offsets: only a status.
            if (left == 1) c.status = first;
            return c;
        }
        if (left == 1 or left == 2) c.offset = first;
        if (left == 4 or left == 5) {
            c.offset = first;
            c.offsets4 = true;
        }
        if (left == 2 or left == 5) c.status = n - 1;
        return c;
    }
    if (eq(u8, name, "Load")) {
        var c: Call = .{ .op = .load, .coord = 0 };
        var i: u8 = 1;
        if (s.ms) {
            c.sample_index = 1;
            i = 2;
        }
        if (i < n and s.offsets() > 0 and !s.rw) {
            c.offset = i;
            i += 1;
        }
        if (i < n) c.status = i;
        return c;
    }
    if (eq(u8, name, "CalculateLevelOfDetail")) return .{ .op = .calc_lod, .sampler = 0, .coord = 1 };
    if (eq(u8, name, "CalculateLevelOfDetailUnclamped")) return .{ .op = .calc_lod_unclamped, .sampler = 0, .coord = 1 };
    if (eq(u8, name, "GetSamplePosition")) return .{ .op = .sample_position, .sample_index = 0 };
    return null;
}

/// GetDimensions(...) out parameters, in order, as the components of dxc's
/// `Dimensions` result they receive (0..2: sizes, 3: levels or samples).
pub const Dims = struct {
    /// Index of the mip-level argument, if given.
    mip: ?u8 = null,
    /// (argument index, result component) pairs.
    outs: [4]struct { arg: u8, comp: u8 } = undefined,
    count: u8 = 0,
};

pub fn getDimensions(s: Shape, nargs: usize) Dims {
    var d: Dims = .{};
    var first: u8 = 0;
    if (s.hasMips() and nargs == @as(usize, s.coords() - @intFromBool(s.dim == .cube)) + @intFromBool(s.array) + 2) {
        d.mip = 0;
        first = 1;
    }
    const n: u8 = @intCast(nargs);
    var comp: u8 = 0;
    var i = first;
    while (i < n) : (i += 1) {
        // The last of several is levels / samples (component 3), as in
        // dxc's TranslateGetDimensions.
        const last_special = (d.mip != null or s.ms or s.hasMips()) and i == n - 1 and i > first;
        const want_levels = d.mip != null or s.ms;
        const c: u8 = if (last_special and want_levels) 3 else comp;
        d.outs[d.count] = .{ .arg = i, .comp = c };
        d.count += 1;
        comp += 1;
    }
    return d;
}

test "decode texture methods" {
    const t2: Shape = .{ .dim = .d2 };
    const c = decode("SampleGrad", t2, 6).?;
    try std.testing.expectEqual(@as(?u8, 2), c.ddx);
    try std.testing.expectEqual(@as(?u8, 4), c.offset);
    try std.testing.expectEqual(@as(?u8, 5), c.clamp);
    const g = decode("GatherCmpGreen", t2, 7).?;
    try std.testing.expect(g.offsets4);
    try std.testing.expectEqual(@as(u2, 1), g.channel);
    const l = decode("Load", .{ .dim = .d2, .ms = true }, 3).?;
    try std.testing.expectEqual(@as(?u8, 1), l.sample_index);
    try std.testing.expectEqual(@as(?u8, 2), l.offset);
    // GetDimensions(mip, w, h, levels) on Texture2D.
    const d = getDimensions(t2, 4);
    try std.testing.expectEqual(@as(?u8, 0), d.mip);
    try std.testing.expectEqual(@as(u8, 3), d.outs[2].comp);
    // GetDimensions(w, h) without a mip level.
    const d2 = getDimensions(t2, 2);
    try std.testing.expectEqual(@as(u8, 1), d2.outs[1].comp);
}
