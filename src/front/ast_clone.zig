//! Deep copies of AST subtrees. Template instantiation checks a fresh copy
//! of the template's declaration per argument list, since Sema records
//! types and resolutions in the nodes themselves.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");

/// A copy of `v` sharing only strings (and other byte slices); expression
/// nodes come back unchecked.
pub fn clone(a: Allocator, comptime T: type, v: T) Allocator.Error!T {
    switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .one => {
                const out = try a.create(p.child);
                out.* = try clone(a, p.child, v.*);
                return out;
            },
            .slice => {
                if (p.child == u8) return v;
                const out = try a.alloc(p.child, v.len);
                for (v, out) |x, *o| o.* = try clone(a, p.child, x);
                return out;
            },
            else => return v,
        },
        .optional => |o| return if (v) |x| try clone(a, o.child, x) else null,
        .@"struct" => |st| {
            var out: T = undefined;
            inline for (st.field_names, st.field_types) |fname, ftype| @field(out, fname) = try clone(a, ftype, @field(v, fname));
            if (T == ast.Expr) {
                out.ty = 0;
                out.info = 0;
            }
            return out;
        },
        .@"union" => |u| {
            if (u.tag_type == null) return v;
            switch (v) {
                inline else => |payload, tag| return @unionInit(T, @tagName(tag), try clone(a, @TypeOf(payload), payload)),
            }
        },
        else => return v,
    }
}

test "clone shares strings and resets expression info" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lit = try a.create(ast.Expr);
    lit.* = .{ .loc = .none, .kind = .{ .int_lit = "42" }, .ty = 7, .info = 3 };
    const neg = try a.create(ast.Expr);
    neg.* = .{ .loc = .none, .kind = .{ .unary = .{ .op = .minus, .operand = lit } }, .ty = 7 };
    const c = try clone(a, *ast.Expr, neg);
    try std.testing.expect(c != neg);
    try std.testing.expect(c.kind.unary.operand != lit);
    try std.testing.expectEqual(@as(u32, 0), c.ty);
    try std.testing.expectEqual(@as(u32, 0), c.kind.unary.operand.info);
    try std.testing.expectEqual(lit.kind.int_lit.ptr, c.kind.unary.operand.kind.int_lit.ptr);
}
