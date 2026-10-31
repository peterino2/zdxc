//! DXIL entry-point signatures: how each semantic is interpreted at a
//! signature point, element packing (a port of dxc's prefix-stable
//! DxilSignatureAllocator, so registers match dxc and shaders from both
//! compilers link), and the ISG1/OSG1 container parts.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const SemanticKind = enum(u8) {
    arbitrary,
    vertex_id,
    instance_id,
    position,
    render_target_array_index,
    viewport_array_index,
    clip_distance,
    cull_distance,
    output_control_point_id,
    domain_location,
    primitive_id,
    gs_instance_id,
    sample_index,
    is_front_face,
    coverage,
    inner_coverage,
    target,
    depth,
    depth_less_equal,
    depth_greater_equal,
    stencil_ref,
    dispatch_thread_id,
    group_id,
    group_index,
    group_thread_id,
    tess_factor,
    inside_tess_factor,
    view_id,
    barycentrics,
    shading_rate,
    cull_primitive,
    start_vertex_location,
    start_instance_location,
    invalid,
};

const sv_names = [_][]const u8{
    "",                          "SV_VertexID",             "SV_InstanceID",        "SV_Position",
    "SV_RenderTargetArrayIndex", "SV_ViewportArrayIndex",   "SV_ClipDistance",      "SV_CullDistance",
    "SV_OutputControlPointID",   "SV_DomainLocation",       "SV_PrimitiveID",       "SV_GSInstanceID",
    "SV_SampleIndex",            "SV_IsFrontFace",          "SV_Coverage",          "SV_InnerCoverage",
    "SV_Target",                 "SV_Depth",                "SV_DepthLessEqual",    "SV_DepthGreaterEqual",
    "SV_StencilRef",             "SV_DispatchThreadID",     "SV_GroupID",           "SV_GroupIndex",
    "SV_GroupThreadID",          "SV_TessFactor",           "SV_InsideTessFactor",  "SV_ViewID",
    "SV_Barycentrics",           "SV_ShadingRate",          "SV_CullPrimitive",     "SV_StartVertexLocation",
    "SV_StartInstanceLocation",
};

/// The semantic a name (without its index) denotes: arbitrary unless it has
/// the `SV_` prefix.
pub fn kindByName(name: []const u8) SemanticKind {
    if (!std.ascii.startsWithIgnoreCase(name, "SV_")) return .arbitrary;
    for (sv_names[1..], 1..) |n, i| {
        if (std.ascii.eqlIgnoreCase(name, n)) return @enumFromInt(i);
    }
    return .invalid;
}

/// The canonical spelling of a system-value semantic.
pub fn canonicalName(kind: SemanticKind) []const u8 {
    return sv_names[@intFromEnum(kind)];
}

pub const Interpretation = enum(u8) { na, sv, sgv, arb, not_in_sig, not_packed, target, tess_factor, shadow, clip_cull };

pub const SigPoint = enum {
    vs_in,
    vs_out,
    pc_in,
    hs_in,
    hs_cp_in,
    hs_cp_out,
    pc_out,
    ds_in,
    ds_cp_in,
    ds_out,
    gs_v_in,
    gs_in,
    gs_out,
    ps_in,
    ps_out,
    cs_in,
    ms_in,
    ms_out,
    ms_p_out,
    as_in,

    fn packing(sp: SigPoint) enum { none, input_assembler, vertex, target } {
        return switch (sp) {
            .vs_in => .input_assembler,
            .vs_out, .hs_cp_in, .hs_cp_out, .pc_out, .ds_in, .ds_cp_in, .ds_out, .gs_v_in, .gs_out, .ps_in, .ms_out, .ms_p_out => .vertex,
            .ps_out => .target,
            .pc_in, .hs_in, .gs_in, .cs_in, .ms_in, .as_in => .none,
        };
    }

    pub fn isInput(sp: SigPoint) bool {
        return switch (sp) {
            .vs_in, .pc_in, .hs_in, .hs_cp_in, .ds_in, .ds_cp_in, .gs_v_in, .gs_in, .ps_in, .cs_in, .ms_in, .as_in => true,
            else => false,
        };
    }
};

/// How `kind` is treated at `sp` in shader model 6.`minor` (dxc's
/// DxilSigPoint interpretation table).
pub fn interpretation(kind: SemanticKind, sp: SigPoint, minor: u8) Interpretation {
    const I = Interpretation;
    // Columns: VSIn, VSOut, PCIn, HSIn, HSCPIn, HSCPOut, PCOut, DSIn,
    // DSCPIn, DSOut, GSVIn, GSIn, GSOut, PSIn, PSOut, CSIn, MSIn, MSOut,
    // MSPOut, ASIn.
    const Row = [20]I;
    const na: I = .na;
    const arb: I = .arb;
    const sv: I = .sv;
    const nis: I = .not_in_sig;
    const cc: I = .clip_cull;
    const row: Row = switch (kind) {
        .arbitrary => .{ arb, arb, na, na, arb, arb, arb, arb, arb, arb, arb, na, arb, arb, na, na, na, arb, arb, na },
        .vertex_id => .{ sv, na, na, na, na, na, na, na, na, na, na, na, na, na, na, na, na, na, na, na },
        .instance_id => .{ sv, arb, na, na, arb, arb, na, na, arb, arb, arb, na, arb, arb, na, na, na, na, na, na },
        .position => .{ arb, sv, na, na, sv, sv, arb, arb, sv, sv, sv, na, sv, sv, na, na, na, sv, na, na },
        .render_target_array_index, .viewport_array_index => .{ arb, sv, na, na, sv, sv, arb, arb, sv, sv, sv, na, sv, sv, na, na, na, na, sv, na },
        .clip_distance, .cull_distance => .{ arb, cc, na, na, cc, cc, arb, arb, cc, cc, cc, na, cc, cc, na, na, na, cc, na, na },
        .output_control_point_id => .{ na, na, na, nis, na, na, na, na, na, na, na, na, na, na, na, na, na, na, na, na },
        .domain_location => .{ na, na, na, na, na, na, na, nis, na, na, na, na, na, na, na, na, na, na, na, na },
        .primitive_id => .{ na, na, nis, nis, na, na, na, nis, na, na, na, .shadow, .sgv, .sgv, na, na, na, na, sv, na },
        .gs_instance_id => .{ na, na, na, na, na, na, na, na, na, na, na, nis, na, na, na, na, na, na, na, na },
        .sample_index => .{ na, na, na, na, na, na, na, na, na, na, na, na, na, .shadow, na, na, na, na, na, na },
        .is_front_face => .{ na, na, na, na, na, na, na, na, na, na, na, na, .sgv, .sgv, na, na, na, na, na, na },
        .coverage => .{ na, na, na, na, na, na, na, na, na, na, na, na, na, nis, .not_packed, na, na, na, na, na },
        .inner_coverage => .{ na, na, na, na, na, na, na, na, na, na, na, na, na, nis, na, na, na, na, na, na },
        .target => .{ na, na, na, na, na, na, na, na, na, na, na, na, na, na, .target, na, na, na, na, na },
        .depth, .depth_less_equal, .depth_greater_equal, .stencil_ref => .{ na, na, na, na, na, na, na, na, na, na, na, na, na, na, .not_packed, na, na, na, na, na },
        .dispatch_thread_id, .group_id, .group_index, .group_thread_id => .{ na, na, na, na, na, na, na, na, na, na, na, na, na, na, na, nis, nis, na, na, nis },
        .tess_factor, .inside_tess_factor => .{ na, na, na, na, na, na, .tess_factor, .tess_factor, na, na, na, na, na, na, na, na, na, na, na, na },
        .view_id => if (minor >= 1) .{ nis, na, nis, nis, na, na, na, nis, na, na, na, nis, na, nis, na, na, nis, na, na, na } else @splat(na),
        .barycentrics => if (minor >= 1) .{ na, na, na, na, na, na, na, na, na, na, na, na, na, .not_packed, na, na, na, na, na, na } else @splat(na),
        .shading_rate => if (minor >= 4) .{ na, sv, na, na, sv, sv, na, na, sv, sv, sv, na, sv, sv, na, na, na, na, sv, na } else @splat(na),
        .cull_primitive => .{ na, na, na, na, na, na, na, na, na, na, na, na, na, nis, na, na, na, na, .not_packed, na },
        .start_vertex_location, .start_instance_location => if (minor >= 8) .{ nis, na, na, na, na, na, na, na, na, na, na, na, na, na, na, na, na, na, na, na } else @splat(na),
        else => @splat(na),
    };
    return row[@intFromEnum(sp)];
}

pub fn shouldBeAllocated(i: Interpretation) bool {
    return switch (i) {
        .na, .not_in_sig, .not_packed, .shadow => false,
        else => true,
    };
}

pub const InterpMode = enum(u8) {
    undefined,
    constant,
    linear,
    linear_centroid,
    linear_noperspective,
    linear_noperspective_centroid,
    linear_sample,
    linear_noperspective_sample,

    pub fn isAnySample(m: InterpMode) bool {
        return m == .linear_sample or m == .linear_noperspective_sample;
    }
};

/// DXIL component types (DXIL::ComponentType).
pub const CompType = enum(u8) {
    invalid,
    i1,
    i16,
    u16,
    i32,
    u32,
    i64,
    u64,
    f16,
    f32,
    f64,

    pub fn isFloat(c: CompType) bool {
        return c == .f16 or c == .f32 or c == .f64;
    }

    /// DxilProgramSigCompType.
    pub fn sigCompType(c: CompType) u32 {
        return switch (c) {
            .i1, .u32 => 1,
            .i32 => 2,
            .f32 => 3,
            .u16 => 4,
            .i16 => 5,
            .f16 => 6,
            .u64 => 7,
            .i64 => 8,
            .f64 => 9,
            .invalid => 0,
        };
    }

    /// DxilProgramSigMinPrecision (min-precision mode).
    fn minPrecision(c: CompType) u32 {
        return switch (c) {
            .f16 => 1,
            .i16 => 4,
            .u16 => 5,
            else => 0,
        };
    }
};

pub const Element = struct {
    id: u32,
    /// Semantic name without its index, as written.
    name: []const u8,
    kind: SemanticKind,
    interpretation: Interpretation,
    comp: CompType,
    interp: InterpMode,
    rows: u32,
    cols: u32,
    indices: []const u32,
    start_row: ?u32 = null,
    start_col: u32 = 0,
    /// Components read (inputs) or written (outputs).
    usage: u8 = 0,
    stream: u32 = 0,

    pub fn colsMask(e: Element) u8 {
        const m: u8 = @intCast((@as(u32, 1) << @intCast(e.cols)) - 1);
        return m << @intCast(if (e.start_row != null) e.start_col else 0);
    }
};

// ----------------------------------------------------------------------
// Packing (DxilSignatureAllocator)

const ef_occupied: u8 = 1 << 0;
const ef_arbitrary: u8 = 1 << 1;
const ef_sgv: u8 = 1 << 2;
const ef_sv: u8 = 1 << 3;
const ef_tess_factor: u8 = 1 << 4;
const ef_clip_cull: u8 = 1 << 5;
const ef_conflicts_with_indexed: u8 = ef_sgv | ef_sv;

const indexed_up: u8 = 1 << 0;
const indexed_down: u8 = 1 << 1;

fn indexFlags(row: u32, rows: u32) u8 {
    return (if (row > 0) indexed_up else 0) | (if (row < rows - 1) indexed_down else 0);
}

/// What the allocator needs to know about an element.
const PackElement = struct {
    kind: SemanticKind = .arbitrary,
    interp: InterpMode = .undefined,
    interpretation: Interpretation = .arb,
    rows: u32 = 1,
    cols: u32 = 1,
    row: ?u32 = null,
    col: u32 = 0,

    fn flags(e: PackElement) u8 {
        return switch (e.interpretation) {
            .arb => ef_arbitrary,
            .sv => ef_sv,
            .sgv => ef_sgv,
            .tess_factor => ef_tess_factor,
            .clip_cull => ef_clip_cull,
            else => 0,
        };
    }
};

/// Element flags that may not be placed to the left of an element.
fn conflictFlagsLeft(f: u8) u8 {
    var c: u8 = 0;
    if (f & ef_arbitrary != 0) c |= ef_sgv | ef_sv | ef_tess_factor | ef_clip_cull;
    if (f & (ef_sv | ef_tess_factor | ef_clip_cull) != 0) c |= ef_sgv;
    return c;
}

/// Element flags that may not be placed to the right of an element.
fn conflictFlagsRight(f: u8) u8 {
    var c: u8 = 0;
    if (f & ef_sgv != 0) c |= ef_arbitrary | ef_sv | ef_tess_factor | ef_clip_cull;
    if (f & (ef_sv | ef_tess_factor | ef_clip_cull) != 0) c |= ef_arbitrary;
    return c;
}

const Register = struct {
    flags: [4]u8 = @splat(0),
    interp: InterpMode = .undefined,
    index_flags: u8 = 0,
    indexing_fixed: bool = false,

    fn rowConflict(r: Register, flags: u8, index: u8, interp: InterpMode, width: u32) bool {
        if (r.index_flags != 0 and flags & ef_conflicts_with_indexed != 0) return true;
        if (r.indexing_fixed and (index | r.index_flags) != r.index_flags) return true;
        if (flags & ef_tess_factor != 0 and (index | r.index_flags) != index) return true;
        if (r.interp != .undefined and r.interp != interp) return true;
        // (All packed data is 32 bits wide in min-precision mode.)
        var free: u32 = 0;
        for (r.flags) |f| {
            if (f & ef_occupied != 0 or f & flags != 0) free = 0 else free += 1;
            if (width <= free) return false;
        }
        return true;
    }

    fn colConflict(r: Register, flags: u8, col: u32, width: u32) bool {
        if (col + width > 4) return true;
        for (r.flags[col..][0..width]) |f| if (f & (flags | ef_occupied) != 0) return true;
        return false;
    }

    fn place(r: *Register, flags: u8, index: u8, interp: InterpMode, col: u32, width: u32) void {
        r.interp = interp;
        r.index_flags |= index;
        if (flags & (ef_conflicts_with_indexed | ef_tess_factor) != 0) r.indexing_fixed = true;
        const left = conflictFlagsLeft(flags);
        const right = conflictFlagsRight(flags);
        for (&r.flags, 0..) |*f, i| {
            if (f.* & ef_occupied != 0) continue;
            if (i < col) f.* |= left else if (i < col + width) f.* = ef_occupied | flags else f.* |= right;
        }
    }
};

const Allocator32 = struct {
    regs: []Register,

    fn rowConflict(a: *const Allocator32, e: *const PackElement, row: u32) bool {
        if (e.rows + row > a.regs.len) return true;
        for (0..e.rows) |i| {
            if (a.regs[row + i].rowConflict(e.flags(), indexFlags(@intCast(i), e.rows), e.interp, e.cols)) return true;
        }
        return false;
    }

    fn colConflict(a: *const Allocator32, e: *const PackElement, row: u32, col: u32) bool {
        for (0..e.rows) |i| if (a.regs[row + i].colConflict(e.flags(), col, e.cols)) return true;
        return false;
    }

    fn place(a: *Allocator32, e: *const PackElement, row: u32, col: u32) void {
        for (0..e.rows) |i| a.regs[row + i].place(e.flags(), indexFlags(@intCast(i), e.rows), e.interp, col, e.cols);
    }

    /// First free location at or after `start_row`; returns the row after
    /// the element, or 0 if it does not fit.
    fn findNext(a: *const Allocator32, row_out: *u32, col_out: *u32, e: *const PackElement, start_row: u32, num_rows: u32, start_col: u32) u32 {
        if (e.rows > num_rows) return 0;
        var row = start_row;
        while (row <= start_row + num_rows - e.rows) : (row += 1) {
            if (a.rowConflict(e, row)) continue;
            var col = start_col;
            while (col + e.cols <= 4) : (col += 1) {
                if (a.colConflict(e, row, col)) continue;
                row_out.* = row;
                col_out.* = col;
                return row + e.rows;
            }
        }
        return 0;
    }

    fn packNext(a: *Allocator32, e: *PackElement, start_row: u32, num_rows: u32, start_col: u32) u32 {
        var row: u32 = 0;
        var col: u32 = 0;
        const used = a.findNext(&row, &col, e, start_row, num_rows, start_col);
        if (used != 0) {
            a.place(e, row, col);
            e.row = row;
            e.col = col;
        }
        return used;
    }

    /// PackPrefixStable: elements are placed in order; appending elements
    /// never moves earlier ones.
    fn packPrefixStable(a: *Allocator32, elements: []*PackElement, start_row: u32, num_rows: u32) u32 {
        var rows_used: u32 = 0;
        // Clip/cull elements share at most two registers and are kept apart
        // from other elements.
        var cc_regs_buf: [2]Register = .{ .{}, .{} };
        var cc: Allocator32 = .{ .regs = &cc_regs_buf };
        var cc_used: u32 = 0;
        var cc_indexed = false;
        var cc_temp: [2]PackElement = .{ .{}, .{} };
        for (elements) |e| {
            e.row = null;
            switch (e.interpretation) {
                .clip_cull => {
                    var row: u32 = 0;
                    var col: u32 = 0;
                    const used = cc.findNext(&row, &col, e, 0, 2, 0);
                    if (used == 0) continue;
                    if (e.rows > 1 and !cc_indexed) {
                        if (cc_used == 2 and cc_temp[0].row.? + 1 != cc_temp[1].row.?) continue;
                        cc_indexed = true;
                    }
                    if (used > cc_used) {
                        const de = &cc_temp[cc_used];
                        de.* = .{ .kind = e.kind, .interp = e.interp, .interpretation = e.interpretation, .rows = 1, .cols = 4 };
                        if (cc_indexed) {
                            if (cc_used < 1) {
                                de.rows = 2;
                                rows_used = @max(rows_used, a.packNext(de, start_row, num_rows, 0));
                                if (de.row == null) continue;
                                cc_temp[1] = de.*;
                                cc_temp[1].row = de.row.? + 1;
                                cc_temp[1].rows = 1;
                            } else {
                                rows_used = @max(rows_used, a.packNext(de, cc_temp[0].row.? + 1, cc_temp[0].row.? + 2, 0));
                                if (de.row == null) continue;
                            }
                            cc_used = 2;
                        } else {
                            rows_used = @max(rows_used, a.packNext(de, start_row, num_rows, 0));
                            if (de.row == null) continue;
                            cc_used = used;
                        }
                    }
                    cc.place(e, row, col);
                    e.row = cc_temp[row].row;
                    e.col = col;
                    continue;
                },
                .tess_factor => if (e.rows > 1) {
                    rows_used = @max(rows_used, a.packNext(e, start_row, num_rows, 3));
                    continue;
                },
                else => {},
            }
            rows_used = @max(rows_used, a.packNext(e, start_row, num_rows, 0));
        }
        return rows_used;
    }
};

pub const PackError = error{SignatureFull} || Allocator.Error;

/// Assigns registers to the allocatable elements of a signature, as dxc's
/// PackDxilSignature does with the default (prefix-stable) strategy.
pub fn pack(gpa: Allocator, elements: []Element, sp: SigPoint) PackError!void {
    switch (sp.packing()) {
        .none => {},
        .input_assembler => {
            var row: u32 = 0;
            for (elements) |*e| if (shouldBeAllocated(e.interpretation)) {
                e.start_row = row;
                e.start_col = 0;
                row += e.rows;
            };
            if (row > 32) return error.SignatureFull;
        },
        .target => for (elements) |*e| if (e.kind == .target) {
            e.start_row = e.indices[0];
            e.start_col = 0;
        },
        .vertex => {
            // One allocator per output stream.
            for (0..4) |stream| {
                var pes: std.ArrayList(PackElement) = .empty;
                defer pes.deinit(gpa);
                var owners: std.ArrayList(*Element) = .empty;
                defer owners.deinit(gpa);
                for (elements) |*e| if (shouldBeAllocated(e.interpretation) and e.stream == stream) {
                    try pes.append(gpa, .{ .kind = e.kind, .interp = e.interp, .interpretation = e.interpretation, .rows = e.rows, .cols = e.cols });
                    try owners.append(gpa, e);
                };
                if (pes.items.len == 0) continue;
                const ptrs = try gpa.alloc(*PackElement, pes.items.len);
                defer gpa.free(ptrs);
                for (ptrs, pes.items) |*p, *pe| p.* = pe;
                var regs: [32]Register = @splat(.{});
                var alloc: Allocator32 = .{ .regs = &regs };
                _ = alloc.packPrefixStable(ptrs, 0, 32);
                for (pes.items, owners.items) |pe, e| {
                    e.start_row = pe.row orelse return error.SignatureFull;
                    e.start_col = pe.col;
                }
            }
        },
    }
}

/// Rows used by the allocated elements of `stream`.
pub fn vectorsUsed(elements: []const Element, stream: u32) u32 {
    var n: u32 = 0;
    for (elements) |e| if (e.start_row) |r| if (e.stream == stream) {
        n = @max(n, r + e.rows);
    };
    return n;
}

// ----------------------------------------------------------------------
// ISG1 / OSG1

/// D3D system-value code of a semantic (DxilProgramSigSemantic).
pub const Domain = enum(u8) { undefined = 0, isoline = 1, tri = 2, quad = 3 };

fn systemValue(kind: SemanticKind, domain: Domain) u32 {
    return switch (kind) {
        .tess_factor => switch (domain) {
            .isoline => 16, // FinalLineDensityTessfactor (then Detail)
            .tri => 13,
            .quad => 11,
            .undefined => 0,
        },
        .inside_tess_factor => switch (domain) {
            .tri => 14,
            .quad => 12,
            else => 0,
        },
        .arbitrary, .invalid => 0,
        .position => 1,
        .clip_distance => 2,
        .cull_distance => 3,
        .render_target_array_index => 4,
        .viewport_array_index => 5,
        .vertex_id => 6,
        .primitive_id => 7,
        .instance_id => 8,
        .is_front_face => 9,
        .sample_index => 10,
        .barycentrics => 23,
        .shading_rate => 24,
        .cull_primitive => 25,
        .target => 64,
        .depth => 65,
        .coverage => 66,
        .depth_greater_equal => 67,
        .depth_less_equal => 68,
        .stencil_ref => 69,
        .inner_coverage => 70,
        else => 0,
    };
}

/// A DxilProgramSignature part (ISG1 or OSG1) for elements in the
/// signature (not NotInSig ones).
pub fn programSignature(gpa: Allocator, elements: []const Element, is_input: bool, domain: Domain) Allocator.Error![]u8 {
    const Rec = struct { stream: u32, name: u32, index: u32, sv: u32, comp: u32, reg: u32, mask: u8, rw: u8, min_prec: u32 };
    var recs: std.ArrayList(Rec) = .empty;
    defer recs.deinit(gpa);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    var name_offsets: std.ArrayList(u32) = .empty;
    defer name_offsets.deinit(gpa);

    var count: u32 = 0;
    for (elements) |e| count += @intCast(e.indices.len);
    var str_off: u32 = 8 + 32 * count;
    for (elements) |e| {
        const name_off = for (names.items, name_offsets.items) |n, o| {
            if (std.mem.eql(u8, n, e.name)) break o;
        } else blk: {
            try names.append(gpa, e.name);
            try name_offsets.append(gpa, str_off);
            str_off += @intCast(e.name.len + 1);
            break :blk str_off - @as(u32, @intCast(e.name.len + 1));
        };
        var usage = e.usage;
        if (e.start_row != null) usage <<= @intCast(e.start_col);
        const rw: u8 = if (is_input) usage else (usage ^ 0xF) & 0xF;
        var reg: u32 = e.start_row orelse 0xFFFFFFFF;
        var sv = systemValue(e.kind, domain);
        for (e.indices) |idx| {
            try recs.append(gpa, .{ .stream = e.stream, .name = name_off, .index = idx, .sv = sv, .comp = e.comp.sigCompType(), .reg = reg, .mask = e.colsMask(), .rw = rw, .min_prec = e.comp.minPrecision() });
            if (e.start_row != null) reg += 1;
            if (sv == 16) sv = 15; // isoline: density, then detail
        }
    }
    std.sort.insertion(Rec, recs.items, {}, struct {
        fn lt(_: void, a: Rec, b: Rec) bool {
            if (a.stream != b.stream) return a.stream < b.stream;
            if (a.reg != b.reg) return a.reg < b.reg;
            return a.name < b.name;
        }
    }.lt);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try put32(&out, gpa, count);
    try put32(&out, gpa, 8);
    for (recs.items) |r| {
        for ([_]u32{ r.stream, r.name, r.index, r.sv, r.comp, r.reg }) |v| try put32(&out, gpa, v);
        try out.appendSlice(gpa, &.{ r.mask, r.rw, 0, 0 });
        try put32(&out, gpa, r.min_prec);
    }
    for (names.items) |n| {
        try out.appendSlice(gpa, n);
        try out.append(gpa, 0);
    }
    while (out.items.len % 4 != 0) try out.append(gpa, 0);
    return out.toOwnedSlice(gpa);
}

pub fn put32(out: *std.ArrayList(u8), gpa: Allocator, v: u32) Allocator.Error!void {
    var tmp: [4]u8 = undefined;
    std.mem.writeInt(u32, &tmp, v, .little);
    try out.appendSlice(gpa, &tmp);
}

test "prefix-stable packing matches dxc" {
    const gpa = std.testing.allocator;
    // dxc: PS input { SV_Position; float2 TEXCOORD0; nointerpolation uint
    // TEXCOORD1; float3 NORMAL; bool SV_IsFrontFace } packs to rows 0, 1,
    // 2, 3 and 2.y.
    const idx0 = [_]u32{0};
    const idx1 = [_]u32{1};
    var els = [_]Element{
        .{ .id = 0, .name = "SV_Position", .kind = .position, .interpretation = .sv, .comp = .f32, .interp = .linear_noperspective, .rows = 1, .cols = 4, .indices = &idx0 },
        .{ .id = 1, .name = "TEXCOORD", .kind = .arbitrary, .interpretation = .arb, .comp = .f32, .interp = .linear, .rows = 1, .cols = 2, .indices = &idx0 },
        .{ .id = 2, .name = "TEXCOORD", .kind = .arbitrary, .interpretation = .arb, .comp = .u32, .interp = .constant, .rows = 1, .cols = 1, .indices = &idx1 },
        .{ .id = 3, .name = "NORMAL", .kind = .arbitrary, .interpretation = .arb, .comp = .f32, .interp = .linear, .rows = 1, .cols = 3, .indices = &idx0 },
        .{ .id = 4, .name = "SV_IsFrontFace", .kind = .is_front_face, .interpretation = .sgv, .comp = .u32, .interp = .constant, .rows = 1, .cols = 1, .indices = &idx0 },
    };
    try pack(gpa, &els, .ps_in);
    const want = [_][2]u32{ .{ 0, 0 }, .{ 1, 0 }, .{ 2, 0 }, .{ 3, 0 }, .{ 2, 1 } };
    for (els, want) |e, w| {
        try std.testing.expectEqual(w[0], e.start_row.?);
        try std.testing.expectEqual(w[1], e.start_col);
    }
    try std.testing.expectEqual(@as(u32, 4), vectorsUsed(&els, 0));
}
