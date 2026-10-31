//! Per-function shader flags and compatibility (valid stages, minimum
//! shader model) of a DXIL library, computed from the emitted
//! instructions the way dxc's ShaderFlags::CollectShaderFlags and
//! DxilModule::ComputeShaderCompatInfo compute them (validator 1.8+):
//! the validator rebuilds RDAT from these and compares.

const std = @import("std");
const module = @import("module.zig");
const op_compat = @import("op_compat.zig");

/// What a resource global (by module global index) is, for flags that
/// depend on the handles a function uses.
pub const GlobalRes = struct { uav: bool, typed_multi: bool = false };

pub const Options = struct {
    /// -enable-16bit-types (native low precision).
    native16: bool,
    /// DXIL 1.7+: functions using UAVs set ResMayNotAlias.
    res_may_not_alias: bool,
    globals: []const ?GlobalRes,
};

pub const Info = struct {
    /// Shader flags (bit positions of dxc's ShaderFlags raw value).
    flags: u64 = 0,
    min_minor: u8 = 0,
    mask: u32 = op_compat.all_stages,
};

pub const bit = struct {
    pub const double = 1 << 2;
    pub const raw_structured = 1 << 4;
    pub const low_precision = 1 << 5;
    pub const double_extensions = 1 << 6;
    pub const msad = 1 << 7;
    pub const inner_coverage = 1 << 10;
    pub const tiled_resources = 1 << 12;
    pub const typed_uav_load = 1 << 13;
    pub const wave = 1 << 19;
    pub const int64 = 1 << 20;
    pub const view_id = 1 << 21;
    pub const barycentrics = 1 << 22;
    pub const native_low_precision = 1 << 23;
    pub const raytracing_1_1 = 1 << 25;
    pub const sampler_feedback = 1 << 26;
    pub const resource_heap = 1 << 30;
    pub const sampler_heap = 1 << 31;
    pub const res_may_not_alias = 1 << 33;
    pub const advanced_texture_ops = 1 << 34;
    pub const extended_command_info = 1 << 38;
    pub const uses_derivatives = 1 << 39;
    pub const requires_group = 1 << 40;
    /// Not part of the module's flags.
    pub const local = uses_derivatives | requires_group;
};

const stage_group: u32 = (1 << 5) | (1 << 13) | (1 << 14) | (1 << 15) | (1 << 6); // CS, MS, AS, Node, Library

pub fn analyze(m: *const module.Module, f: *const module.Function, o: Options) Info {
    var info: Info = .{};
    const fty = m.types.items[f.ty].function;
    var fl: u64 = 0;
    var has16 = false;
    var check_access = false;
    var lod_clamp = false;
    var uses_uav = false;
    for (f.insts.items) |inst| {
        // Calls to other functions only count through their dx ops.
        var op: ?u32 = null;
        if (inst.op == .call) {
            const callee = m.functions.items[inst.op.call.callee];
            if (!std.mem.startsWith(u8, callee.name, "dx.op.")) continue;
            if (inst.op.call.args.len > 0) op = constInt(m, inst.op.call.args[0]);
        }
        var types_seen: [8]module.TypeId = undefined;
        var n: usize = 0;
        types_seen[n] = inst.ty;
        n += 1;
        var operands: [4]?module.Value = .{ null, null, null, null };
        const all_args: []const module.Value = switch (inst.op) {
            .call => |c| c.args,
            .gep => |g| g.indices,
            else => &.{},
        };
        switch (inst.op) {
            .binop => |b| operands = .{ b.lhs, b.rhs, null, null },
            .cast => |c| operands[0] = c.val,
            .cmp => |c| operands = .{ c.lhs, c.rhs, null, null },
            .select => |s| operands = .{ s.cond, s.t, s.f, null },
            .extractvalue => |x| operands[0] = x.agg,
            .load => |x| operands[0] = x.ptr,
            .store => |x| operands = .{ x.ptr, x.val, null, null },
            .gep => |g| operands[0] = g.ptr,
            .atomicrmw => |x| operands = .{ x.ptr, x.val, null, null },
            .cmpxchg => |x| operands = .{ x.ptr, x.cmp, x.new, null },
            .ret => |r| operands[0] = r,
            .br => |b| operands[0] = b.cond,
            .@"switch" => |s| operands[0] = s.cond,
            .alloca => |a| operands[0] = a.size,
            else => {},
        }
        var is_double = false;
        var is_int64 = false;
        var is16 = false;
        const visit = struct {
            fn t(mm: *const module.Module, ty: module.TypeId, d: *bool, i64_: *bool, h: *bool, group: *bool) void {
                switch (mm.types.items[ty]) {
                    .double => d.* = true,
                    .half => h.* = true,
                    .int => |w| {
                        if (w == 64) i64_.* = true;
                        if (w == 16) h.* = true;
                    },
                    .pointer => |p| if (p.addr_space == 3) {
                        group.* = true;
                    },
                    else => {},
                }
            }
        };
        var group = false;
        visit.t(m, inst.ty, &is_double, &is_int64, &is16, &group);
        for (operands) |ov| if (ov) |v| if (valueType(m, f, fty, v)) |vt| visit.t(m, vt, &is_double, &is_int64, &is16, &group);
        for (all_args) |v| if (valueType(m, f, fty, v)) |vt| visit.t(m, vt, &is_double, &is_int64, &is16, &group);
        if (group) fl |= bit.requires_group;
        if (is_double) {
            fl |= bit.double;
            switch (inst.op) {
                // (fdiv is sdiv on floating point types)
                .binop => |b| if (b.op == .sdiv and isFloatOp(m, inst.ty)) {
                    fl |= bit.double_extensions;
                },
                .cast => |c| switch (c.op) {
                    .uitofp, .sitofp, .fptoui, .fptosi => fl |= bit.double_extensions,
                    else => {},
                },
                else => {},
            }
        }
        if (is_int64) fl |= bit.int64;
        if (is16) has16 = true;
        const code = op orelse continue;
        const c = op_compat.get(code);
        info.min_minor = @max(info.min_minor, c.minor);
        info.mask &= c.mask;
        const args = inst.op.call.args;
        if ((code >= 110 and code <= 123) or (code >= 135 and code <= 136) or (code >= 165 and code <= 167) or code == 222 or (code >= 312 and code <= 313)) fl |= bit.wave;
        if (code >= 174 and code <= 177) fl |= bit.sampler_feedback;
        switch (code) {
            71 => check_access = true,
            50 => fl |= bit.msad,
            91 => fl |= bit.inner_coverage,
            138 => fl |= bit.view_id,
            137 => fl |= bit.barycentrics,
            178, 258, 213 => fl |= bit.raytracing_1_1,
            60, 61, 64, 81, 83, 84, 85, 86 => {
                fl |= bit.uses_derivatives;
                if (code != 81 and code < 83 and clampArg(m, code, args)) lod_clamp = true;
            },
            62, 63 => if (code == 63 and clampArg(m, code, args)) {
                lod_clamp = true;
            },
            68, 66 => if (handleRes(m, f, o, args[1])) |r| if (r.uav and r.typed_multi) {
                fl |= bit.typed_uav_load;
            },
            218 => {
                if (args.len > 2 and constInt(m, args[2]) == 1) fl |= bit.sampler_heap else fl |= bit.resource_heap;
            },
            57 => if (args.len > 1 and constInt(m, args[1]) == 1) {
                uses_uav = true;
            },
            160 => if (handleRes(m, f, o, args[1])) |r| if (r.uav) {
                uses_uav = true;
            },
            216 => if (args.len > 2 and annotateIsUav(m, args[2])) {
                uses_uav = true;
            },
            256, 257 => fl |= bit.extended_command_info,
            80 => if (args.len > 1) if (constInt(m, args[1])) |mode| if (mode != 2) {
                fl |= bit.requires_group;
                info.mask &= stage_group;
            },
            else => {},
        }
    }
    if (has16) fl |= bit.low_precision;
    if (has16 and o.native16) fl |= bit.native_low_precision;
    if (check_access or lod_clamp) fl |= bit.tiled_resources;
    if (o.res_may_not_alias and uses_uav) fl |= bit.res_may_not_alias;
    info.flags = fl;
    return info;
}

/// The minimum shader model of an entry (or library function) given its
/// flags (AdjustMinimumShaderModelAndFlags).
pub fn minMinor(info: Info, kind: ?u32) u8 {
    var v = info.min_minor;
    const fl = info.flags;
    if (kind) |k| {
        if (fl & bit.uses_derivatives != 0 and (k == 5 or k == 13 or k == 14)) v = @max(v, 6);
        if (k == 13 or k == 14) v = @max(v, 5) else if (k >= 7 and k <= 12) v = @max(v, 3) else if (k == 15) v = @max(v, 8);
    }
    if (fl & bit.extended_command_info != 0) {
        v = @max(v, 8);
    } else if (fl & bit.advanced_texture_ops != 0) {
        v = @max(v, 7);
    } else if (fl & (bit.resource_heap | bit.sampler_heap) != 0) {
        v = @max(v, 6);
    } else if (fl & (bit.raytracing_1_1 | bit.sampler_feedback) != 0) {
        v = @max(v, 5);
    } else if (fl & bit.low_precision != 0 and fl & bit.native_low_precision != 0) {
        v = @max(v, 2);
    } else if (fl & (bit.view_id | bit.barycentrics) != 0) {
        v = @max(v, 1);
    }
    return v;
}

/// Feature info bits (SFI0 / RDAT) of shader flags.
pub fn featureInfo(fl: u64) u64 {
    const map = [_][2]u64{
        .{ bit.double, 0x1 },          .{ 1 << 16, 0x4 },                .{ 1 << 15, 0x8 },
        .{ bit.double_extensions, 0x20 }, .{ bit.msad, 0x40 },           .{ 1 << 11, 0x200 },
        .{ bit.inner_coverage, 0x400 }, .{ 1 << 9, 0x2000 },             .{ bit.int64, 0x8000 },
        .{ bit.view_id, 0x10000 },     .{ 1 << 24, 0x80000 },            .{ bit.wave, 0x4000 },
        .{ bit.typed_uav_load, 0x800 }, .{ bit.resource_heap, 0x2000000 }, .{ bit.sampler_heap, 0x4000000 },
        .{ bit.barycentrics, 0x20000 }, .{ bit.extended_command_info, 0x100000000 }, .{ bit.tiled_resources, 0x100 },
        .{ 1 << 29, 0x1000000 },       .{ bit.raytracing_1_1, 0x100000 }, .{ bit.sampler_feedback, 0x200000 },
        .{ bit.advanced_texture_ops, 0x20000000 }, .{ bit.uses_derivatives, 0x100 << 32 }, .{ bit.requires_group, 0x200 << 32 },
    };
    var out: u64 = 0;
    for (map) |e| if (fl & e[0] != 0) {
        out |= e[1];
    };
    if (fl & bit.low_precision != 0) out |= if (fl & bit.native_low_precision != 0) 0x40000 else 0x10;
    return out;
}

fn constInt(m: *const module.Module, v: module.Value) ?u32 {
    if (v != .constant) return null;
    const c = m.constants.items[v.constant];
    return switch (c.kind) {
        .int => |x| @truncate(@as(u64, @bitCast(x))),
        else => null,
    };
}

fn isFloatOp(m: *const module.Module, ty: module.TypeId) bool {
    return switch (m.types.items[ty]) {
        .half, .float, .double => true,
        else => false,
    };
}

/// Sample / SampleBias / SampleCmp and SampleGrad: a clamp operand that is
/// not undef.
fn clampArg(m: *const module.Module, code: u32, args: []const module.Value) bool {
    const idx: usize = switch (code) {
        60 => 10,
        61 => 11,
        64 => 11,
        63 => 16,
        else => return false,
    };
    if (idx >= args.len) return false;
    const v = args[idx];
    if (v != .constant) return true;
    return m.constants.items[v.constant].kind != .undef;
}

fn annotateIsUav(m: *const module.Module, props: module.Value) bool {
    if (props != .constant) return false;
    const c = m.constants.items[props.constant];
    if (c.kind != .aggregate or c.kind.aggregate.len == 0) return false;
    const basic = m.constants.items[c.kind.aggregate[0]];
    return basic.kind == .int and basic.kind.int & 0x1000 != 0;
}

/// The resource global behind a handle made by createHandleForLib (of a
/// loaded global), possibly annotated.
fn handleRes(m: *const module.Module, f: *const module.Function, o: Options, h: module.Value) ?GlobalRes {
    var v = h;
    var steps: u32 = 0;
    while (steps < 4) : (steps += 1) {
        if (v != .inst) return null;
        const inst = f.insts.items[v.inst];
        switch (inst.op) {
            .call => |c| {
                const code = if (c.args.len > 0) constInt(m, c.args[0]) else null;
                if (code == 216 or code == 160) {
                    v = c.args[1];
                    continue;
                }
                return null;
            },
            .load => |l| {
                if (l.ptr == .global) return o.globals[l.ptr.global];
                return null;
            },
            else => return null,
        }
    }
    return null;
}

fn valueType(m: *const module.Module, f: *const module.Function, fty: @FieldType(module.Type, "function"), v: module.Value) ?module.TypeId {
    return switch (v) {
        .global => |g| m.globals.items[g].ptr_ty,
        .function => null,
        .constant => |c| m.constants.items[c].ty,
        .arg => |a| fty.params[a],
        .inst => |i| f.insts.items[i].ty,
    };
}
