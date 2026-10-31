//! dxc-compatible command-line parsing.
//!
//! The option table is generated from dxc's own definitions
//! (vendor/dxc/HLSLOptions.td) and matched with the same rules as LLVM's
//! OptTable, which dxc uses: `-`, `/` and `--` prefixes, longest spelling
//! first, flags must match exactly, joined / separate / joined-or-separate
//! values, and `/`-prefixed arguments that match nothing are input paths.
//! A few zdxc-only options (`-zdxc-*`, color control) are added on top under
//! names dxc does not use.
//!
//! Every dxc option has a support level: implemented, accepted with no
//! effect yet, or unsupported (with a reason), so that a dxc command line
//! either works or fails with a clear message.

const std = @import("std");
const Allocator = std.mem.Allocator;
const table = @import("options_table");

pub const Id = table.Id;
pub const Kind = table.Kind;
pub const Option = table.Option;

/// zdxc-only options. They use the same matching rules.
pub const Extra = enum {
    zdxc_empty,
    zdxc_check_hash,
    zdxc_lex,
    zdxc_parse,
    zdxc_ast,
    zdxc_sema,
    zdxc_ir,
    fcolor_diagnostics,
    fno_color_diagnostics,
};

const extra_options = [_]struct { id: Extra, spelling: []const u8, help: []const u8 }{
    .{ .id = .zdxc_empty, .spelling = "zdxc-empty", .help = "Emit an empty shader for -T instead of compiling the input (development)" },
    .{ .id = .zdxc_check_hash, .spelling = "zdxc-check-hash", .help = "Verify the container hash of the input (development)" },
    .{ .id = .zdxc_lex, .spelling = "zdxc-lex", .help = "Print the input's tokens, one per line (development)" },
    .{ .id = .zdxc_parse, .spelling = "zdxc-parse", .help = "Preprocess and parse the input, reporting syntax errors only (development)" },
    .{ .id = .zdxc_ast, .spelling = "zdxc-ast", .help = "Preprocess, parse and dump the syntax tree (development)" },
    .{ .id = .zdxc_sema, .spelling = "zdxc-sema", .help = "Run the front end through semantic analysis only (development)" },
    .{ .id = .zdxc_ir, .spelling = "zdxc-ir", .help = "Print the lowered IR instead of compiling (development)" },
    .{ .id = .fcolor_diagnostics, .spelling = "fcolor-diagnostics", .help = "Always use colors in diagnostics" },
    .{ .id = .fno_color_diagnostics, .spelling = "fno-color-diagnostics", .help = "Never use colors in diagnostics" },
};

pub const Arg = struct {
    which: union(enum) { dxc: Id, extra: Extra },
    /// The argument as written, for messages (`-T`, `/Fo`).
    spelling: []const u8,
    values: []const []const u8,

    pub fn is(a: Arg, id: Id) bool {
        return a.which == .dxc and a.which.dxc == id;
    }

    pub fn value(a: Arg) []const u8 {
        return if (a.values.len > 0) a.values[0] else "";
    }
};

pub const Parsed = struct {
    args: []const Arg,
    inputs: []const []const u8,
};

pub const ParseError = error{ UnknownArgument, MissingArgument } || Allocator.Error;

/// Details of the last ParseError, for the error message.
pub const Failure = struct { arg: []const u8 = "" };

/// Parse `argv` (without the program name).
pub fn parse(arena: Allocator, argv: []const []const u8, failure: *Failure) ParseError!Parsed {
    var args: std.ArrayList(Arg) = .empty;
    var inputs: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < argv.len) {
        const str = argv[i];
        if (!isOptionLike(str)) {
            try inputs.append(arena, str);
            i += 1;
            continue;
        }
        const r = try parseOne(arena, argv, &i, failure);
        if (r) |a| {
            try args.append(arena, a);
        } else if (str[0] == '/') {
            // Not an option: a path such as /Users/me/shader.hlsl.
            try inputs.append(arena, str);
            i += 1;
        } else {
            failure.arg = str;
            return error.UnknownArgument;
        }
    }
    return .{ .args = args.items, .inputs = inputs.items };
}

fn isOptionLike(s: []const u8) bool {
    if (s.len < 2) return false; // "-" alone is an input (stdin)
    return s[0] == '-' or s[0] == '/';
}

/// Candidate match: an option (dxc or extra) whose prefix + spelling
/// starts `str`.
const Candidate = struct {
    which: @FieldType(Arg, "which"),
    kind: Kind,
    count: u8,
    prefix_len: usize,
    spelling_len: usize,
};

fn prefixFits(str: []const u8, pre: []const u8, spelling: []const u8) bool {
    return std.mem.startsWith(u8, str, pre) and std.mem.startsWith(u8, str[pre.len..], spelling);
}

fn parseOne(arena: Allocator, argv: []const []const u8, index: *usize, failure: *Failure) ParseError!?Arg {
    const str = argv[index.*];
    var cands: [16]Candidate = undefined;
    var n: usize = 0;
    for (table.options) |o| {
        const prefixes = [_]struct { bool, []const u8 }{ .{ o.dash_dash, "--" }, .{ o.dash, "-" }, .{ o.slash, "/" } };
        for (prefixes) |pp| {
            if (!pp[0] or !prefixFits(str, pp[1], o.spelling)) continue;
            if (n < cands.len) {
                cands[n] = .{ .which = .{ .dxc = o.alias orelse o.id }, .kind = o.kind, .count = o.count, .prefix_len = pp[1].len, .spelling_len = o.spelling.len };
                n += 1;
            }
            break;
        }
    }
    for (extra_options) |o| {
        if (prefixFits(str, "-", o.spelling) and n < cands.len) {
            cands[n] = .{ .which = .{ .extra = o.id }, .kind = .flag, .count = 0, .prefix_len = 1, .spelling_len = o.spelling.len };
            n += 1;
        }
    }
    // Longest spelling first, as OptTable's sorted search does.
    std.mem.sort(Candidate, cands[0..n], {}, struct {
        fn gt(_: void, a: Candidate, b: Candidate) bool {
            return a.spelling_len > b.spelling_len;
        }
    }.gt);

    for (cands[0..n]) |c| {
        const name_end = c.prefix_len + c.spelling_len;
        const rest = str[name_end..];
        const spelling = str[0..name_end];
        switch (c.kind) {
            .flag => {
                if (rest.len != 0) continue;
                index.* += 1;
                return .{ .which = c.which, .spelling = spelling, .values = &.{} };
            },
            .joined => {
                index.* += 1;
                return .{ .which = c.which, .spelling = spelling, .values = try dupeOne(arena, rest) };
            },
            .comma_joined => {
                index.* += 1;
                var vals: std.ArrayList([]const u8) = .empty;
                var it = std.mem.splitScalar(u8, rest, ',');
                while (it.next()) |v| try vals.append(arena, v);
                return .{ .which = c.which, .spelling = spelling, .values = vals.items };
            },
            .separate, .joined_or_separate => {
                if (rest.len != 0) {
                    if (c.kind == .separate) continue;
                    index.* += 1;
                    return .{ .which = c.which, .spelling = spelling, .values = try dupeOne(arena, rest) };
                }
                if (index.* + 1 >= argv.len) {
                    failure.arg = spelling;
                    return error.MissingArgument;
                }
                index.* += 2;
                return .{ .which = c.which, .spelling = spelling, .values = try dupeOne(arena, argv[index.* - 1]) };
            },
            .multi_arg => {
                if (rest.len != 0) continue;
                if (index.* + c.count >= argv.len) {
                    failure.arg = spelling;
                    return error.MissingArgument;
                }
                const vals = try arena.dupe([]const u8, argv[index.* + 1 ..][0..c.count]);
                index.* += 1 + c.count;
                return .{ .which = c.which, .spelling = spelling, .values = vals };
            },
        }
    }
    return null;
}

fn dupeOne(arena: Allocator, v: []const u8) Allocator.Error![]const []const u8 {
    const vals = try arena.alloc([]const u8, 1);
    vals[0] = v;
    return vals;
}

// -------------------------------------------------------------------------
// Support levels

pub const Support = union(enum) {
    implemented,
    /// Accepted for compatibility; has no effect (yet).
    ignored,
    /// Rejected with this reason.
    unsupported: []const u8,
};

const dropped_debug = "debug information and PDBs are not supported by zdxc";
const dropped_disasm = "disassembly is not part of zdxc; use dxc -dumpbin to inspect output";
const dropped_tooling = "this dxc tooling option is not part of zdxc";
const dropped_internal = "dxc-internal (LLVM pass / codegen debugging) options are not supported";
const not_yet = "not supported by zdxc yet";

/// The support level of each dxc option. Options not listed are
/// unsupported ("not supported by zdxc yet").
pub fn support(id: Id) Support {
    return switch (id) {
        // Core compilation.
        .target_profile, .entrypoint, .Fo, .D, .I, .P, .Fi, .hlsl_version, .spirv, .enable_16bit_types, .fspv_target_env_EQ => .implemented,
        // Diagnostics.
        ._SLASH_WX, .no_warnings, .W_Joined, .Wno_vk_ignored_features, .Wno_vk_emulated_features => .implemented,
        .fdiagnostics_format_EQ, .ferror_limit_EQ, .fdiagnostics_color, .fdiagnostics_color_EQ => .implemented,
        // Information.
        .help, ._help_question, ._help_hidden, ._version, .nologo => .implemented,
        // Optimization levels: recorded; zdxc's optimizer is simpler.
        .O0, .O1, .O2, .O3, .Od => .implemented,
        // zdxc signs its own output and has no separate validation step.
        .VD, .validator_version => .implemented,

        // Accepted for build-script compatibility; no effect yet.
        .Zpr, .Zpc, .Gis, .Gfa, .Gfp, .Ges, .Gec, .denorm, .all_resources_bound, .all_resources_bound_, .res_may_alias, .res_may_alias_, .pack_optimized, .pack_optimized_, .pack_prefix_stable, .pack_prefix_stable_, .ffinite_math_only, .fno_finite_math_only, .flegacy_macro_expansion, .flegacy_resource_reservation, .no_legacy_cbuf_layout, .not_use_legacy_cbuf_load_, .enable_payload_qualifiers, .disable_payload_qualifiers, .enable_lifetime_markers, .disable_lifetime_markers, .force_zero_store_lifetimes, .ignore_line_directives, .Qunused_arguments, .fdiagnostics_show_option, .fno_diagnostics_show_option, .fdiagnostics_show_category_EQ, ._vi, .verbose, .v, .encoding, .Wall, .Wdeprecated, ._all_warnings, .Fh, .Vn, .Fsh, .Frs, .Fre, .Zss, .Zsb, .Qstrip_reflect, .Qstrip_debug, .Qstrip_priv, .Qstrip_rootsignature, .Qkeep_reflect_in_dxil, .Qstrip_reflect_from_dxil, .force_rootsig_ver, .force_rootsig_ver_, .rootsig_define, .auto_binding_space, .exports, .export_shaders_only, .default_linkage, .fvk_stage_io_order_EQ, .fvk_b_shift, .fvk_t_shift, .fvk_s_shift, .fvk_u_shift, .fvk_bind_globals, .fvk_bind_register, .vkbr, .fvk_invert_y, .fvk_use_dx_position_w, .fvk_support_nonzero_base_instance, .fvk_support_nonzero_base_vertex, .fvk_use_gl_layout, .fvk_use_dx_layout, .fvk_use_scalar_layout, .fspv_use_legacy_buffer_matrix_order, .fspv_reflect, .fspv_extension_EQ, .fspv_flatten_resource_arrays, .fspv_reduce_load_size, .fspv_fix_func_call_arguments, .fspv_entrypoint_name_EQ, .fspv_enable_maximal_reconvergence, .fspv_use_vulkan_memory_model, .fspv_use_unknown_image_format, .fvk_auto_shift_bindings, .fspv_preserve_bindings, .fspv_preserve_interface, .Oconfig => .ignored,

        // Dropped by design (see the zdxc plan).
        ._SLASH_Zi, .Zs, .Fd, .Qembed_debug, .Qsource_in_debug_module, .Qpdb_in_private, .fspv_debug_EQ => .{ .unsupported = dropped_debug },
        .Fc, .Cc, .Ni, .No, .Lx, .dumpbin => .{ .unsupported = dropped_disasm },
        .recompile, .link, .ast_dump, .verify, .metal, .external_lib, .external_fn, .setprivate, .getprivate, .setrootsignature, .extractrootsignature, .verifyrootsignature, .rw_unchanged, .rw_skip_function_body, .rw_skip_static, .rw_global_extern_by_default, .rw_keep_user_macro, .rw_extract_entry_uniforms, .rw_remove_unused_globals, .rw_remove_unused_functions, .rw_line_directive, .rw_decl_global_cb, .import_binding_table, .binding_table_define, .ftime_report, .ftime_trace, .ftime_trace_EQ, .ftime_trace_granularity_EQ => .{ .unsupported = dropped_tooling },
        .Odump, .fcgl, .print_before_all, .print_before, .print_after_all, .print_after, .opt_disable, .opt_enable, .opt_select, .memdep_block_scan_limit, .fdisable_loc_tracking, .fnew_inlining_behavior, .preserve_intermediate_values, .skip_serialization, .d_Flag, .d_Joined, .ignore_opt_semdefs, .ignore_semdef, .override_semdef, .precise_output, .disable_exception_handling, .fspv_print_all, .fspv_max_id => .{ .unsupported = dropped_internal },

        else => .{ .unsupported = not_yet },
    };
}

/// The definition of `id` in the generated table.
pub fn info(id: Id) *const Option {
    for (&table.options) |*o| if (o.id == id) return o;
    unreachable;
}

pub fn extraHelp(id: Extra) []const u8 {
    for (extra_options) |o| if (o.id == id) return o.help;
    unreachable;
}

/// `-help`: dxc's option groups, listing implemented and accepted options
/// with dxc's help text, then zdxc's own options.
pub fn printHelp(w: *std.Io.Writer, show_hidden: bool) !void {
    try w.writeAll(
        \\OVERVIEW: zdxc - HLSL 2021 to DXIL / SPIR-V compiler (dxc-compatible command line)
        \\
        \\USAGE: zdxc [options] <input>
        \\
        \\Options are spelled as in dxc (-T, /T, -Tcs_6_0 ...). Options dxc accepts
        \\but zdxc does not implement yet are accepted with a note; dropped dxc
        \\features (debug info, disassembly, linking, ...) are reported as errors.
        \\
    );
    for (table.groups) |g| {
        var printed_title = false;
        for (table.options) |o| {
            if (!std.mem.eql(u8, o.group, g.name) or o.alias != null) continue;
            if (o.hidden and !show_hidden) continue;
            if (support(o.id) == .unsupported) continue;
            if (!printed_title) {
                try w.print("\n{s}:\n", .{if (g.help.len > 0) g.help else g.title});
                printed_title = true;
            }
            try printOption(w, o.spelling, o.kind, o.meta, o.help, support(o.id) == .ignored);
        }
    }
    try w.writeAll("\nzdxc options:\n");
    for (extra_options) |o| try printOption(w, o.spelling, .flag, "", o.help, false);
}

fn printOption(w: *std.Io.Writer, spelling: []const u8, kind: Kind, meta: []const u8, help: []const u8, ignored: bool) !void {
    var buf: [64]u8 = undefined;
    const sep: []const u8 = if (kind == .separate or kind == .multi_arg) " " else "";
    const left = std.fmt.bufPrint(&buf, "-{s}{s}{s}", .{ spelling, sep, meta }) catch spelling;
    try w.print("  {s}", .{left});
    if (left.len < 26) try w.splatByteAll(' ', 26 - left.len) else try w.writeAll("\n                            ");
    // dxc help text can contain newlines and tabs; keep it on one line.
    for (help) |c| try w.writeByte(if (c == '\n' or c == '\t') ' ' else c);
    if (ignored) try w.writeAll(" [accepted, no effect yet]");
    try w.writeByte('\n');
}

// -------------------------------------------------------------------------
// Tests

test "dxc spellings: dash, slash, joined and separate" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Failure = .{};
    const p = try parse(a, &.{ "-T", "cs_6_0", "/Emain2", "-Foout.dxo", "/Fi", "x.i", "-DA=1", "-D", "B", "-Iinc", "-WX", "/O3", "-Wno-macro-redefined", "-fvk-b-shift", "1", "0", "/Users/me/s.hlsl", "-", "-zdxc-ast" }, &f);
    try std.testing.expectEqual(@as(usize, 2), p.inputs.len);
    try std.testing.expectEqualStrings("/Users/me/s.hlsl", p.inputs[0]);
    try std.testing.expectEqualStrings("-", p.inputs[1]);
    const expect = [_]struct { Id, []const u8 }{
        .{ .target_profile, "cs_6_0" }, .{ .entrypoint, "main2" },            .{ .Fo, "out.dxo" }, .{ .Fi, "x.i" },
        .{ .D, "A=1" },                 .{ .D, "B" },                         .{ .I, "inc" },      .{ ._SLASH_WX, "" },
        .{ .O3, "" },                   .{ .W_Joined, "no-macro-redefined" },
    };
    for (expect, 0..) |e, i| {
        try std.testing.expect(p.args[i].is(e[0]));
        try std.testing.expectEqualStrings(e[1], p.args[i].value());
    }
    try std.testing.expect(p.args[10].is(.fvk_b_shift));
    try std.testing.expectEqual(@as(usize, 2), p.args[10].values.len);
    try std.testing.expect(p.args[11].which == .extra and p.args[11].which.extra == .zdxc_ast);
}

test "unknown and missing arguments, flags need exact matches" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Failure = .{};
    try std.testing.expectError(error.UnknownArgument, parse(a, &.{"-bogus"}, &f));
    try std.testing.expectEqualStrings("-bogus", f.arg);
    try std.testing.expectError(error.MissingArgument, parse(a, &.{"-T"}, &f));
    try std.testing.expectEqualStrings("-T", f.arg);
    // `-tcs_6_0`: options are case-sensitive, as in dxc.
    try std.testing.expectError(error.UnknownArgument, parse(a, &.{"-tcs_6_0"}, &f));
    // `-WXy` is not the -WX flag; it is the joined -W<warning> option.
    const p = try parse(a, &.{"-WXy"}, &f);
    try std.testing.expect(p.args[0].is(.W_Joined));
}

test "every option has a support level and a table entry" {
    for (table.options) |o| {
        _ = support(o.id);
        try std.testing.expect(info(o.id).id == o.id);
    }
}
