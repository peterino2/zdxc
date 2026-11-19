//! Test helpers: compiling HLSL in memory and looking at the DXIL module
//! the emitter made, before it is written (zdxc does not read its bitcode
//! back; see compile.Request.inspect_dxil).

const std = @import("std");
const compile_ = @import("compile.zig");
const module = @import("dxil/module.zig");
const emit = @import("dxil/emit.zig");

/// Compiles `src`'s `main` for `profile` with the `extra` options; a
/// failed compile fails the test, its diagnostics printed.
pub fn compile(a: std.mem.Allocator, profile: []const u8, extra: []const []const u8, src: []const u8, inspect_dxil: ?emit.Inspect) !compile_.Result {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ "-T", profile, "-E", "main" });
    try args.appendSlice(a, extra);
    const r = try compile_.compile(a, .{ .args = args.items, .source = src, .io = threaded.io(), .compat_notes = false, .inspect_dxil = inspect_dxil });
    if (r.status != .ok) {
        std.debug.print("{s}\n", .{r.diagnostics});
        return error.TestUnexpectedResult;
    }
    return r;
}

/// Compiles as `compile` does, calling `observer.observe(m)` with the
/// finished DXIL module.
pub fn inspect(a: std.mem.Allocator, profile: []const u8, extra: []const []const u8, src: []const u8, observer: anytype) !compile_.Result {
    const T = @typeInfo(@TypeOf(observer)).pointer.child;
    const thunk = struct {
        fn call(ctx: *anyopaque, m: *const module.Module) void {
            const o: *T = @ptrCast(@alignCast(ctx));
            o.observe(m);
        }
    };
    return compile(a, profile, extra, src, .{ .ctx = observer, .call = thunk.call });
}

/// A DXIL compile's floating-point arithmetic and comparisons, each
/// `.{ fast, precise }`, and its floating-point dx.op calls marked
/// `!dx.precise`.
pub const FloatOps = struct {
    fadd: [2]usize = .{ 0, 0 },
    fsub: [2]usize = .{ 0, 0 },
    fmul: [2]usize = .{ 0, 0 },
    fdiv: [2]usize = .{ 0, 0 },
    fcmp: [2]usize = .{ 0, 0 },
    precise_calls: usize = 0,

    pub fn of(a: std.mem.Allocator, profile: []const u8, src: []const u8) !FloatOps {
        return ofWith(a, profile, &.{}, src);
    }

    pub fn ofWith(a: std.mem.Allocator, profile: []const u8, extra: []const []const u8, src: []const u8) !FloatOps {
        var c: FloatOps = .{};
        _ = try inspect(a, profile, extra, src, &c);
        return c;
    }

    pub fn observe(c: *FloatOps, m: *const module.Module) void {
        for (m.functions.items) |f| for (f.insts.items) |inst| switch (inst.op) {
            .binop => |b| if (m.isFloatType(inst.ty)) {
                const slot: ?*[2]usize = switch (b.op) {
                    .add => &c.fadd,
                    .sub => &c.fsub,
                    .mul => &c.fmul,
                    .sdiv => &c.fdiv, // (fdiv's code)
                    else => null,
                };
                if (slot) |s| s[@intFromBool(!module.fastMath(m, inst))] += 1;
            },
            .cmp => |x| if (x.pred <= 15) {
                c.fcmp[@intFromBool(!module.fastMath(m, inst))] += 1;
            },
            .call => if (inst.md != .none and inst.md == m.precise_md) {
                c.precise_calls += 1;
            },
            else => {},
        };
    }

    /// How many floating-point operations are precise.
    pub fn precise(c: FloatOps) usize {
        return c.fadd[1] + c.fsub[1] + c.fmul[1] + c.fdiv[1] + c.fcmp[1];
    }
};
