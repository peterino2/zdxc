//! D3D12 root signature compiler: parses the HLSL root signature language
//! (`[RootSignature("...")]`, `-T rootsig_1_x -E RS`) and serializes it to
//! the binary blob stored in the RTS0 container part.
//!
//! Ported from dxc:
//!   tools/clang/lib/Parse/HLSLRootSignature.cpp   (tokenizer + parser)
//!   lib/DxilRootSignature/DxilRootSignatureValidator.cpp (VerifyRootSignature)
//!   lib/DxilRootSignature/DxilRootSignatureSerializer.cpp
//!     (SerializeRootSignatureTemplate)
//!   include/dxc/DxilRootSignature/DxilRootSignature.h (enums, layouts)
//!
//! dxc always parses to a 1.1 description (all flags default to 0) and
//! down-converts to 1.0 when asked, dropping the flags. Flags are rejected by
//! the parser in 1.0 mode. The validator up-converts 1.0 signatures with
//! "volatile" flags, which never trigger flag errors, so the only flag
//! checks that matter are those on explicit 1.1 flags.
//!
//! Self-contained: depends on std only.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Version = enum(u32) {
    v1_0 = 1,
    v1_1 = 2,
};

/// DxilRootSignatureCompilationFlags. `-T rootsig_*` uses `none`; local /
/// global are used for DXR subobjects.
pub const CompilationFlags = enum { none, local, global };

pub const Options = struct {
    version: Version = .v1_1,
    flags: CompilationFlags = .none,
};

/// Error text for a rejected root signature. The message is kept as dxc
/// builds it (minus the trailing newline the verifier appends).
pub const Diagnostic = struct {
    /// How dxc reports it: `root_signature` as
    /// "root signature error - <message>"; `validation` (the root-signature
    /// container validator, which deserializes the blob) as
    /// "root signature validation errors\r\n<message>".
    kind: enum { root_signature, validation } = .root_signature,
    buf: [1024]u8 = undefined,
    len: usize = 0,

    pub fn message(d: *const Diagnostic) []const u8 {
        return d.buf[0..d.len];
    }

    fn set(d: *Diagnostic, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&d.buf, fmt, args) catch blk: {
            break :blk d.buf[0..];
        };
        var n = s.len;
        while (n > 0 and (d.buf[n - 1] == '\n' or d.buf[n - 1] == ' ')) n -= 1;
        d.len = n;
    }
};

/// Compile root signature text to the serialized blob. Returns null (and
/// fills `diag`) if dxc would reject the signature. Caller owns the result.
pub fn compile(gpa: Allocator, text: []const u8, version: Version, diag: *Diagnostic) Allocator.Error!?[]u8 {
    return compileWithOptions(gpa, text, .{ .version = version }, diag);
}

pub fn compileWithOptions(gpa: Allocator, text: []const u8, opts: Options, diag: *Diagnostic) Allocator.Error!?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var p: Parser = .{
        .arena = arena,
        .tok = .{ .src = text },
        .version = opts.version,
        .flags = opts.flags,
        .diag = diag,
    };
    p.tok.prime();
    const rs = p.parseRootSignature() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseFailed => return null,
    };
    verify(arena, &rs, opts.version, diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.VerifyFailed => return null,
    };
    const blob = try serialize(gpa, &rs, opts.version);
    if (!deserializeBoundsOk(blob, &rs, opts.version)) {
        gpa.free(blob);
        diag.kind = .validation;
        diag.set("Validation failed.", .{});
        return null;
    }
    return blob;
}

/// dxc validates the RTS0 part by deserializing it
/// (DeserializeRootSignatureTemplate). Its bounds check for a descriptor
/// table requires room for one range even when the table has none, so an
/// empty table near the end of the blob is rejected.
fn deserializeBoundsOk(blob: []const u8, rs: *const RootSignature, version: Version) bool {
    const range_size: usize = if (version == .v1_1) 24 else 20;
    for (rs.parameters, 0..) |param, i| {
        if (param.parameter_type != .descriptor_table) continue;
        const payload = std.mem.readInt(u32, blob[24 + 12 * i + 8 ..][0..4], .little);
        const ranges = std.mem.readInt(u32, blob[payload + 4 ..][0..4], .little);
        if (ranges + range_size > blob.len) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Description (always the 1.1 shape; see DxilRootSignature.h)

pub const DescriptorRangeOffsetAppend: u32 = 0xffffffff;
pub const SystemReservedRegisterSpaceValuesStart: u32 = 0xfffffff0;
pub const SystemReservedRegisterSpaceValuesEnd: u32 = 0xffffffff;
const MipLodBiasMax: f32 = 15.99;
const MipLodBiasMin: f32 = -16.0;
const Float32Max: f32 = std.math.floatMax(f32);
const MaxAnisotropy: u32 = 16;

pub const RootSignatureFlags = struct {
    pub const none: u32 = 0;
    pub const allow_input_assembler_input_layout: u32 = 0x1;
    pub const deny_vertex_shader_root_access: u32 = 0x2;
    pub const deny_hull_shader_root_access: u32 = 0x4;
    pub const deny_domain_shader_root_access: u32 = 0x8;
    pub const deny_geometry_shader_root_access: u32 = 0x10;
    pub const deny_pixel_shader_root_access: u32 = 0x20;
    pub const allow_stream_output: u32 = 0x40;
    pub const local_root_signature: u32 = 0x80;
    pub const deny_amplification_shader_root_access: u32 = 0x100;
    pub const deny_mesh_shader_root_access: u32 = 0x200;
    pub const cbv_srv_uav_heap_directly_indexed: u32 = 0x400;
    pub const sampler_heap_directly_indexed: u32 = 0x800;
    pub const valid: u32 = 0x80000fff;
};

pub const RootDescriptorFlags = struct {
    pub const data_volatile: u32 = 0x2;
    pub const data_static_while_set_at_execute: u32 = 0x4;
    pub const data_static: u32 = 0x8;
    pub const valid: u32 = 0xe;
};

pub const DescriptorRangeFlags = struct {
    pub const descriptors_volatile: u32 = 0x1;
    pub const data_volatile: u32 = 0x2;
    pub const data_static_while_set_at_execute: u32 = 0x4;
    pub const data_static: u32 = 0x8;
    pub const descriptors_static_keeping_buffer_bounds_checks: u32 = 0x10000;
    pub const valid: u32 = 0x1000f;
};

pub const RangeType = enum(u32) { srv = 0, uav = 1, cbv = 2, sampler = 3 };
pub const ParameterType = enum(u32) { descriptor_table = 0, constants_32bit = 1, cbv = 2, srv = 3, uav = 4 };
pub const ShaderVisibility = enum(u32) { all = 0, vertex = 1, hull = 2, domain = 3, geometry = 4, pixel = 5, amplification = 6, mesh = 7 };

pub const DescriptorRange = struct {
    range_type: RangeType,
    num_descriptors: u32 = 1,
    base_shader_register: u32 = 0,
    register_space: u32 = 0,
    flags: u32 = 0,
    offset: u32 = DescriptorRangeOffsetAppend,
};

pub const RootParameter = struct {
    parameter_type: ParameterType,
    visibility: ShaderVisibility = .all,
    /// Root constants / root descriptor payload.
    shader_register: u32 = 0,
    register_space: u32 = 0,
    num_32bit_values: u32 = 0,
    flags: u32 = 0,
    /// Descriptor table payload.
    ranges: []const DescriptorRange = &.{},
};

pub const StaticSampler = struct {
    filter: u32 = 0x55, // ANISOTROPIC
    address_u: u32 = 1, // WRAP
    address_v: u32 = 1,
    address_w: u32 = 1,
    mip_lod_bias: f32 = 0,
    max_anisotropy: u32 = 16,
    comparison_func: u32 = 4, // LESS_EQUAL
    border_color: u32 = 2, // OPAQUE_WHITE
    min_lod: f32 = 0,
    max_lod: f32 = Float32Max,
    shader_register: u32 = 0,
    register_space: u32 = 0,
    visibility: ShaderVisibility = .all,
};

pub const RootSignature = struct {
    flags: u32 = 0,
    parameters: []const RootParameter = &.{},
    static_samplers: []const StaticSampler = &.{},
};

// ---------------------------------------------------------------------------
// Tokenizer (RootSignatureTokenizer)

const max_token_length = 127;

/// Token kinds. Everything after `ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT` is a
/// keyword whose spelling is its tag name (matched case-insensitively).
const Kind = enum {
    Unknown,
    EOL,
    Comma,
    LParen,
    RParen,
    EQ,
    OR,
    NumberU32,
    NumberI32,
    NumberFloat,
    TReg,
    SReg,
    UReg,
    BReg,
    // keywords
    ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT,
    ALLOW_STREAM_OUTPUT,
    addressU,
    addressV,
    addressW,
    borderColor,
    CBV,
    comparisonFunc,
    COMPARISON_NONE,
    COMPARISON_NEVER,
    COMPARISON_LESS,
    COMPARISON_EQUAL,
    COMPARISON_LESS_EQUAL,
    COMPARISON_GREATER,
    COMPARISON_NOT_EQUAL,
    COMPARISON_GREATER_EQUAL,
    COMPARISON_ALWAYS,
    CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED,
    DescriptorTable,
    DESCRIPTOR_RANGE_OFFSET_APPEND,
    DENY_VERTEX_SHADER_ROOT_ACCESS,
    DENY_HULL_SHADER_ROOT_ACCESS,
    DENY_DOMAIN_SHADER_ROOT_ACCESS,
    DENY_GEOMETRY_SHADER_ROOT_ACCESS,
    DENY_PIXEL_SHADER_ROOT_ACCESS,
    DENY_AMPLIFICATION_SHADER_ROOT_ACCESS,
    DENY_MESH_SHADER_ROOT_ACCESS,
    DESCRIPTORS_VOLATILE,
    DATA_VOLATILE,
    DATA_STATIC,
    DATA_STATIC_WHILE_SET_AT_EXECUTE,
    DESCRIPTORS_STATIC_KEEPING_BUFFER_BOUNDS_CHECKS,
    flags,
    filter,
    FILTER_MIN_MAG_MIP_POINT,
    FILTER_MIN_MAG_POINT_MIP_LINEAR,
    FILTER_MIN_POINT_MAG_LINEAR_MIP_POINT,
    FILTER_MIN_POINT_MAG_MIP_LINEAR,
    FILTER_MIN_LINEAR_MAG_MIP_POINT,
    FILTER_MIN_LINEAR_MAG_POINT_MIP_LINEAR,
    FILTER_MIN_MAG_LINEAR_MIP_POINT,
    FILTER_MIN_MAG_MIP_LINEAR,
    FILTER_ANISOTROPIC,
    FILTER_COMPARISON_MIN_MAG_MIP_POINT,
    FILTER_COMPARISON_MIN_MAG_POINT_MIP_LINEAR,
    FILTER_COMPARISON_MIN_POINT_MAG_LINEAR_MIP_POINT,
    FILTER_COMPARISON_MIN_POINT_MAG_MIP_LINEAR,
    FILTER_COMPARISON_MIN_LINEAR_MAG_MIP_POINT,
    FILTER_COMPARISON_MIN_LINEAR_MAG_POINT_MIP_LINEAR,
    FILTER_COMPARISON_MIN_MAG_LINEAR_MIP_POINT,
    FILTER_COMPARISON_MIN_MAG_MIP_LINEAR,
    FILTER_COMPARISON_ANISOTROPIC,
    FILTER_MINIMUM_MIN_MAG_MIP_POINT,
    FILTER_MINIMUM_MIN_MAG_POINT_MIP_LINEAR,
    FILTER_MINIMUM_MIN_POINT_MAG_LINEAR_MIP_POINT,
    FILTER_MINIMUM_MIN_POINT_MAG_MIP_LINEAR,
    FILTER_MINIMUM_MIN_LINEAR_MAG_MIP_POINT,
    FILTER_MINIMUM_MIN_LINEAR_MAG_POINT_MIP_LINEAR,
    FILTER_MINIMUM_MIN_MAG_LINEAR_MIP_POINT,
    FILTER_MINIMUM_MIN_MAG_MIP_LINEAR,
    FILTER_MINIMUM_ANISOTROPIC,
    FILTER_MAXIMUM_MIN_MAG_MIP_POINT,
    FILTER_MAXIMUM_MIN_MAG_POINT_MIP_LINEAR,
    FILTER_MAXIMUM_MIN_POINT_MAG_LINEAR_MIP_POINT,
    FILTER_MAXIMUM_MIN_POINT_MAG_MIP_LINEAR,
    FILTER_MAXIMUM_MIN_LINEAR_MAG_MIP_POINT,
    FILTER_MAXIMUM_MIN_LINEAR_MAG_POINT_MIP_LINEAR,
    FILTER_MAXIMUM_MIN_MAG_LINEAR_MIP_POINT,
    FILTER_MAXIMUM_MIN_MAG_MIP_LINEAR,
    FILTER_MAXIMUM_ANISOTROPIC,
    LOCAL_ROOT_SIGNATURE,
    maxAnisotropy,
    mipLODBias,
    minLOD,
    maxLOD,
    numDescriptors,
    num32BitConstants,
    offset,
    RootFlags,
    RootConstants,
    space,
    Sampler,
    StaticSampler,
    SRV,
    SAMPLER_HEAP_DIRECTLY_INDEXED,
    SHADER_VISIBILITY_ALL,
    SHADER_VISIBILITY_VERTEX,
    SHADER_VISIBILITY_HULL,
    SHADER_VISIBILITY_DOMAIN,
    SHADER_VISIBILITY_GEOMETRY,
    SHADER_VISIBILITY_PIXEL,
    SHADER_VISIBILITY_AMPLIFICATION,
    SHADER_VISIBILITY_MESH,
    STATIC_BORDER_COLOR_TRANSPARENT_BLACK,
    STATIC_BORDER_COLOR_OPAQUE_BLACK,
    STATIC_BORDER_COLOR_OPAQUE_WHITE,
    STATIC_BORDER_COLOR_OPAQUE_BLACK_UINT,
    STATIC_BORDER_COLOR_OPAQUE_WHITE_UINT,
    TEXTURE_ADDRESS_WRAP,
    TEXTURE_ADDRESS_MIRROR,
    TEXTURE_ADDRESS_CLAMP,
    TEXTURE_ADDRESS_BORDER,
    TEXTURE_ADDRESS_MIRROR_ONCE,
    unbounded,
    UAV,
    visibility,
};

const first_keyword = @intFromEnum(Kind.ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT);
const kind_count = @typeInfo(Kind).@"enum".field_names.len;

const Token = struct {
    kind: Kind,
    str: []const u8,
    /// u32 / i32 bit pattern (registers, numbers) or f32 bits.
    bits: u32 = 0,

    fn u32Value(t: Token) u32 {
        return t.bits;
    }
    fn i32Value(t: Token) i32 {
        return @bitCast(t.bits);
    }
    fn floatValue(t: Token) f32 {
        return @bitCast(t.bits);
    }
};

const Tokenizer = struct {
    src: []const u8,
    pos: usize = 0,
    next: Token = undefined,
    /// dxc reads tokens alternately into two fixed C buffers and token
    /// strings point into them. A malformed number skips the NUL
    /// terminator, so its text runs on into stale bytes of an older token
    /// (e.g. "mipLODBias=." reports '.ipLODBias'); this is reproduced so
    /// error messages match.
    bufs: [2][max_token_length + 8]u8 = @splat(@splat(0)),
    which: u1 = 0,

    /// Reads the first token. Call once the tokenizer is at its final
    /// address (token strings point into `bufs`).
    fn prime(t: *Tokenizer) void {
        t.next = t.read();
    }

    fn peek(t: *const Tokenizer) Token {
        return t.next;
    }

    fn get(t: *Tokenizer) Token {
        const tok = t.next;
        t.next = t.read();
        return tok;
    }

    fn cur(t: *const Tokenizer) u8 {
        return if (t.pos == t.src.len) 0 else t.src[t.pos];
    }

    fn isSeparator(c: u8) bool {
        return switch (c) {
            ',', '=', '|', '(', ')', ' ', '\t', '\n' => true,
            else => false,
        };
    }

    fn read(t: *Tokenizer) Token {
        // EatSpace: only ' ' is skipped.
        while (t.pos < t.src.len and t.src[t.pos] == ' ') t.pos += 1;

        const start = t.pos;
        var len: usize = 0;
        var is_float = false;
        var ch = t.cur();
        unknown: {
            if (isSeparator(ch)) {
                t.pos += 1;
                len = 1;
            } else if (std.ascii.isDigit(ch) or ch == '+' or ch == '-' or ch == '.') {
                if (ch == '+' or ch == '-') {
                    t.pos += 1;
                    len += 1;
                    ch = t.cur();
                }
                var seen_digit = false;
                while (std.ascii.isDigit(ch) and len < max_token_length) {
                    t.pos += 1;
                    len += 1;
                    ch = t.cur();
                    seen_digit = true;
                }
                if (ch == '.') {
                    is_float = true;
                    t.pos += 1;
                    len += 1;
                    ch = t.cur();
                    if (!seen_digit and !std.ascii.isDigit(ch)) break :unknown;
                    while (std.ascii.isDigit(ch) and len < max_token_length) {
                        t.pos += 1;
                        len += 1;
                        ch = t.cur();
                        seen_digit = true;
                    }
                }
                if (!seen_digit) break :unknown;
                if (ch == 'e' or ch == 'E') {
                    is_float = true;
                    t.pos += 1;
                    len += 1;
                    ch = t.cur();
                    if (ch == '+' or ch == '-') {
                        t.pos += 1;
                        len += 1;
                        ch = t.cur();
                    }
                    if (!std.ascii.isDigit(ch)) break :unknown;
                    while (std.ascii.isDigit(ch) and len < max_token_length) {
                        t.pos += 1;
                        len += 1;
                        ch = t.cur();
                    }
                }
                if (ch == 'f' or ch == 'F') {
                    is_float = true;
                    t.pos += 1;
                    len += 1;
                }
            } else if (std.ascii.isAlphabetic(ch) or ch == '_') {
                while ((std.ascii.isAlphabetic(ch) or ch == '_' or std.ascii.isDigit(ch)) and
                    len < max_token_length)
                {
                    t.pos += 1;
                    len += 1;
                    ch = t.cur();
                }
            } else {
                while (t.pos < t.src.len and len < max_token_length) {
                    t.pos += 1;
                    len += 1;
                }
            }

            const s = t.src[start..][0..len];
            var tok = classify(s, is_float);
            const b = t.nextBuf(s);
            b[len] = 0;
            tok.str = b[0..len];
            return tok;
        }
        // No NUL terminator written (see `bufs`).
        const b = t.nextBuf(t.src[start..][0..len]);
        const n = std.mem.indexOfScalar(u8, b, 0) orelse b.len;
        return .{ .kind = .Unknown, .str = b[0..n] };
    }

    fn nextBuf(t: *Tokenizer, s: []const u8) []u8 {
        const b = &t.bufs[t.which];
        t.which ^= 1;
        @memcpy(b[0..s.len], s);
        return b;
    }

    fn classify(s: []const u8, is_float: bool) Token {
        // An embedded NUL terminates the C token buffer.
        const c: u8 = if (s.len == 0) 0 else s[0];
        switch (c) {
            0 => return .{ .kind = .EOL, .str = "" },
            ',' => return .{ .kind = .Comma, .str = s },
            '(' => return .{ .kind = .LParen, .str = s },
            ')' => return .{ .kind = .RParen, .str = s },
            '=' => return .{ .kind = .EQ, .str = s },
            '|' => return .{ .kind = .OR, .str = s },
            else => {},
        }

        if (std.ascii.isDigit(c) or c == '+' or c == '-' or c == '.') {
            if (is_float) {
                if (toFloat(s)) |v| return .{ .kind = .NumberFloat, .str = s, .bits = @bitCast(v) };
            } else if (c == '-') {
                const n = atoi64(s);
                if (n >= std.math.minInt(i32) and n <= std.math.maxInt(i32))
                    return .{ .kind = .NumberI32, .str = s, .bits = @bitCast(@as(i32, @intCast(n))) };
            } else {
                const n = atoi64(s);
                if (n >= 0 and n <= std.math.maxInt(u32))
                    return .{ .kind = .NumberU32, .str = s, .bits = @intCast(n) };
            }
            return .{ .kind = .Unknown, .str = s };
        }

        // Register (lower-case prefix only).
        if (s.len > 1 and std.ascii.isDigit(s[1]) and (c == 't' or c == 's' or c == 'u' or c == 'b')) {
            const n = atoi64(s[1..]);
            if (n >= 0 and n <= std.math.maxInt(u32)) {
                const kind: Kind = switch (c) {
                    't' => .TReg,
                    's' => .SReg,
                    'u' => .UReg,
                    else => .BReg,
                };
                return .{ .kind = kind, .str = s, .bits = @intCast(n) };
            }
        }

        // Keywords (case-insensitive).
        var i: usize = first_keyword;
        while (i < kind_count) : (i += 1) {
            const k: Kind = @enumFromInt(i);
            if (std.ascii.eqlIgnoreCase(@tagName(k), s)) return .{ .kind = k, .str = s };
        }
        return .{ .kind = .Unknown, .str = s };
    }

    /// atoll: optional sign then leading digits; saturates on overflow.
    fn atoi64(s: []const u8) i64 {
        var i: usize = 0;
        var neg = false;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) {
            neg = s[i] == '-';
            i += 1;
        }
        var v: i128 = 0;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
            v = v * 10 + (s[i] - '0');
            if (v > std.math.maxInt(i64) + 1) break;
        }
        if (neg) v = -v;
        if (v > std.math.maxInt(i64)) return std.math.maxInt(i64);
        if (v < std.math.minInt(i64)) return std.math.minInt(i64);
        return @intCast(v);
    }

    /// strtod + range check + cast to float (RootSignatureTokenizer::ToFloat).
    fn toFloat(s: []const u8) ?f32 {
        var body = s;
        if (body.len > 0 and (body[body.len - 1] == 'f' or body[body.len - 1] == 'F'))
            body = body[0 .. body.len - 1];
        const d = std.fmt.parseFloat(f64, body) catch return null;
        // strtod reports ERANGE on overflow and on underflow to zero/denormal.
        if (std.math.isInf(d)) return null;
        if (d != 0 and @abs(d) < std.math.floatMin(f64)) return null;
        if (d == 0) {
            const mant_end = std.mem.indexOfAny(u8, body, "eE") orelse body.len;
            for (body[0..mant_end]) |ch| if (ch >= '1' and ch <= '9') return null;
        }
        const fmax: f64 = std.math.floatMax(f32);
        if (d > fmax or d < -fmax) return null;
        return @floatCast(d);
    }
};

// ---------------------------------------------------------------------------
// Parser (RootSignatureParser)

const Parser = struct {
    arena: Allocator,
    tok: Tokenizer,
    version: Version,
    flags: CompilationFlags,
    diag: *Diagnostic,

    const Error = error{ ParseFailed, OutOfMemory };

    fn fail(p: *Parser, comptime fmt: []const u8, args: anytype) Error {
        p.diag.set(fmt, args);
        return error.ParseFailed;
    }

    fn match(p: *Parser, kind: Kind) Error!Token {
        const t = p.tok.get();
        if (t.kind != kind) return p.fail("Unexpected token '{s}'", .{t.str});
        return t;
    }

    fn mark(p: *Parser, seen: *bool, name: []const u8) Error!void {
        if (seen.*) return p.fail("Parameter '{s}' can be specified only once", .{name});
        seen.* = true;
    }

    /// After a parameter: ')' ends the list, ',' continues it.
    fn endOrComma(p: *Parser) Error!bool {
        const t = p.tok.get();
        if (t.kind == .RParen) return true;
        if (t.kind != .Comma) return p.fail("Unexpected token '{s}'", .{t.str});
        return false;
    }

    fn parseRootSignature(p: *Parser) Error!RootSignature {
        var rs: RootSignature = .{};
        var seen_flags = false;
        var params: std.ArrayList(RootParameter) = .empty;
        var samplers: std.ArrayList(StaticSampler) = .empty;

        var t = p.tok.peek();
        while (t.kind != .EOL) {
            switch (t.kind) {
                .RootFlags => {
                    if (seen_flags) return p.fail("RootFlags cannot be specified more than once", .{});
                    rs.flags = try p.parseRootSignatureFlags();
                    seen_flags = true;
                },
                .RootConstants => try params.append(p.arena, try p.parseRootConstants()),
                .CBV => try params.append(p.arena, try p.parseRootShaderResource(.CBV, .BReg, .cbv)),
                .SRV => try params.append(p.arena, try p.parseRootShaderResource(.SRV, .TReg, .srv)),
                .UAV => try params.append(p.arena, try p.parseRootShaderResource(.UAV, .UReg, .uav)),
                .DescriptorTable => try params.append(p.arena, try p.parseDescriptorTable()),
                .StaticSampler => try samplers.append(p.arena, try p.parseStaticSampler()),
                else => return p.fail("Unexpected token '{s}' when parsing root signature", .{t.str}),
            }
            t = p.tok.get();
            if (t.kind == .EOL) break;
            if (t.kind != .Comma) return p.fail("Expected ',', found: '{s}'", .{t.str});
            t = p.tok.peek();
        }

        rs.parameters = params.items;
        rs.static_samplers = samplers.items;
        if (p.flags == .local) rs.flags |= RootSignatureFlags.local_root_signature;
        return rs;
    }

    fn parseRootSignatureFlags(p: *Parser) Error!u32 {
        _ = try p.match(.RootFlags);
        _ = try p.match(.LParen);
        var flags: u32 = 0;
        if (p.tok.peek().kind == .NumberU32) {
            const t = try p.match(.NumberU32);
            if (t.u32Value() != 0)
                return p.fail("Root signature flag values can only be 0 or flag enum values, found: '{s}'", .{t.str});
        } else {
            while (true) {
                const t = p.tok.get();
                const F = RootSignatureFlags;
                flags |= switch (t.kind) {
                    .ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT => F.allow_input_assembler_input_layout,
                    .DENY_VERTEX_SHADER_ROOT_ACCESS => F.deny_vertex_shader_root_access,
                    .DENY_HULL_SHADER_ROOT_ACCESS => F.deny_hull_shader_root_access,
                    .DENY_DOMAIN_SHADER_ROOT_ACCESS => F.deny_domain_shader_root_access,
                    .DENY_GEOMETRY_SHADER_ROOT_ACCESS => F.deny_geometry_shader_root_access,
                    .DENY_PIXEL_SHADER_ROOT_ACCESS => F.deny_pixel_shader_root_access,
                    .DENY_AMPLIFICATION_SHADER_ROOT_ACCESS => F.deny_amplification_shader_root_access,
                    .DENY_MESH_SHADER_ROOT_ACCESS => F.deny_mesh_shader_root_access,
                    .ALLOW_STREAM_OUTPUT => F.allow_stream_output,
                    .LOCAL_ROOT_SIGNATURE => blk: {
                        if (p.flags == .global)
                            return p.fail("LOCAL_ROOT_SIGNATURE flag used in global root signature", .{});
                        break :blk F.local_root_signature;
                    },
                    .CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED => F.cbv_srv_uav_heap_directly_indexed,
                    .SAMPLER_HEAP_DIRECTLY_INDEXED => F.sampler_heap_directly_indexed,
                    else => return p.fail("Expected a root signature flag value, found: '{s}'", .{t.str}),
                };
                if (p.tok.peek().kind == .RParen) break;
                _ = try p.match(.OR);
            }
        }
        _ = try p.match(.RParen);
        return flags;
    }

    fn parseRootConstants(p: *Parser) Error!RootParameter {
        // RootConstants(num32BitConstants=3, b2 [, space=1, visibility=...])
        var rp: RootParameter = .{ .parameter_type = .constants_32bit };
        var seen_num = false;
        var seen_reg = false;
        var seen_space = false;
        var seen_vis = false;
        _ = try p.match(.RootConstants);
        _ = try p.match(.LParen);
        while (true) {
            const t = p.tok.peek();
            switch (t.kind) {
                .num32BitConstants => {
                    try p.mark(&seen_num, "num32BitConstants");
                    _ = try p.match(.num32BitConstants);
                    _ = try p.match(.EQ);
                    rp.num_32bit_values = (try p.match(.NumberU32)).u32Value();
                },
                .BReg => {
                    try p.mark(&seen_reg, "cbuffer register b#");
                    rp.shader_register = try p.parseRegister(.BReg);
                },
                .space => {
                    try p.mark(&seen_space, "space");
                    rp.register_space = try p.parseSpace();
                },
                .visibility => {
                    try p.mark(&seen_vis, "visibility");
                    rp.visibility = try p.parseVisibility();
                },
                else => return p.fail("Unexpected token '{s}'", .{t.str}),
            }
            if (try p.endOrComma()) break;
        }
        if (!seen_num) return p.fail("num32BitConstants must be defined for each RootConstants", .{});
        if (!seen_reg) return p.fail("Constant buffer register b# must be defined for each RootConstants", .{});
        return rp;
    }

    fn parseRootShaderResource(p: *Parser, tok_kind: Kind, reg_kind: Kind, ty: ParameterType) Error!RootParameter {
        // CBV(b0 [, space=3, flags=0, visibility=VISIBILITY_ALL])
        var rp: RootParameter = .{ .parameter_type = ty };
        var seen_reg = false;
        var seen_flags = false;
        var seen_space = false;
        var seen_vis = false;
        _ = try p.match(tok_kind);
        _ = try p.match(.LParen);
        while (true) {
            const t = p.tok.peek();
            switch (t.kind) {
                .BReg, .TReg, .UReg => {
                    try p.mark(&seen_reg, "shader register");
                    rp.shader_register = try p.parseRegister(reg_kind);
                },
                .flags => {
                    try p.mark(&seen_flags, "flags");
                    rp.flags = try p.parseRootDescFlags();
                },
                .space => {
                    try p.mark(&seen_space, "space");
                    rp.register_space = try p.parseSpace();
                },
                .visibility => {
                    try p.mark(&seen_vis, "visibility");
                    rp.visibility = try p.parseVisibility();
                },
                else => return p.fail("Unexpected token '{s}'", .{t.str}),
            }
            if (try p.endOrComma()) break;
        }
        if (!seen_reg) return p.fail("shader register must be defined for each CBV/SRV/UAV", .{});
        return rp;
    }

    fn parseDescriptorTable(p: *Parser) Error!RootParameter {
        var rp: RootParameter = .{ .parameter_type = .descriptor_table };
        var seen_vis = false;
        var ranges: std.ArrayList(DescriptorRange) = .empty;
        _ = try p.match(.DescriptorTable);
        _ = try p.match(.LParen);
        while (true) {
            const t = p.tok.peek();
            switch (t.kind) {
                .CBV => try ranges.append(p.arena, try p.parseDescTableResource(.CBV, .BReg, .cbv)),
                .SRV => try ranges.append(p.arena, try p.parseDescTableResource(.SRV, .TReg, .srv)),
                .UAV => try ranges.append(p.arena, try p.parseDescTableResource(.UAV, .UReg, .uav)),
                .Sampler => try ranges.append(p.arena, try p.parseDescTableResource(.Sampler, .SReg, .sampler)),
                .visibility => {
                    try p.mark(&seen_vis, "visibility");
                    rp.visibility = try p.parseVisibility();
                },
                else => return p.fail("Unexpected token '{s}'", .{t.str}),
            }
            if (try p.endOrComma()) break;
        }
        rp.ranges = ranges.items;
        return rp;
    }

    fn parseDescTableResource(p: *Parser, tok_kind: Kind, reg_kind: Kind, ty: RangeType) Error!DescriptorRange {
        // CBV(b0 [, numDescriptors=1, space=0, flags=0, offset=DESCRIPTOR_RANGE_OFFSET_APPEND])
        var r: DescriptorRange = .{ .range_type = ty };
        var seen_reg = false;
        var seen_num = false;
        var seen_space = false;
        var seen_flags = false;
        var seen_offset = false;
        _ = try p.match(tok_kind);
        _ = try p.match(.LParen);
        while (true) {
            const t = p.tok.peek();
            switch (t.kind) {
                .BReg, .TReg, .UReg, .SReg => {
                    try p.mark(&seen_reg, "shader register");
                    r.base_shader_register = try p.parseRegister(reg_kind);
                },
                .numDescriptors => {
                    try p.mark(&seen_num, "numDescriptors");
                    _ = try p.match(.numDescriptors);
                    _ = try p.match(.EQ);
                    if (p.tok.peek().kind == .unbounded) {
                        _ = try p.match(.unbounded);
                        r.num_descriptors = std.math.maxInt(u32);
                    } else {
                        r.num_descriptors = (try p.match(.NumberU32)).u32Value();
                    }
                },
                .space => {
                    try p.mark(&seen_space, "space");
                    r.register_space = try p.parseSpace();
                },
                .flags => {
                    try p.mark(&seen_flags, "flags");
                    r.flags = try p.parseDescRangeFlags();
                },
                .offset => {
                    try p.mark(&seen_offset, "offset");
                    _ = try p.match(.offset);
                    _ = try p.match(.EQ);
                    if (p.tok.peek().kind == .DESCRIPTOR_RANGE_OFFSET_APPEND) {
                        _ = try p.match(.DESCRIPTOR_RANGE_OFFSET_APPEND);
                        r.offset = DescriptorRangeOffsetAppend;
                    } else {
                        r.offset = (try p.match(.NumberU32)).u32Value();
                    }
                },
                else => return p.fail("Unexpected token '{s}'", .{t.str}),
            }
            if (try p.endOrComma()) break;
        }
        if (!seen_reg) return p.fail("shader register must be defined for each CBV/SRV/UAV", .{});
        return r;
    }

    fn parseRegister(p: *Parser, reg_kind: Kind) Error!u32 {
        const t = p.tok.peek();
        switch (t.kind) {
            .BReg, .TReg, .UReg, .SReg => _ = p.tok.get(),
            else => return p.fail("Expected a register token (CBV, SRV, UAV, Sampler), found: '{s}'", .{t.str}),
        }
        if (t.kind != reg_kind) {
            return switch (reg_kind) {
                .BReg => p.fail("Incorrect register type '{s}' in CBV (expected b#)", .{t.str}),
                .TReg => p.fail("Incorrect register type '{s}' in SRV (expected t#)", .{t.str}),
                .UReg => p.fail("Incorrect register type '{s}' in UAV (expected u#)", .{t.str}),
                else => p.fail("Incorrect register type '{s}' in Sampler/StaticSampler (expected s#)", .{t.str}),
            };
        }
        return t.u32Value();
    }

    fn parseSpace(p: *Parser) Error!u32 {
        _ = try p.match(.space);
        _ = try p.match(.EQ);
        return (try p.match(.NumberU32)).u32Value();
    }

    fn parseRootDescFlags(p: *Parser) Error!u32 {
        if (p.version == .v1_0)
            return p.fail("Root descriptor flags cannot be specified for root_sig_1_0", .{});
        _ = try p.match(.flags);
        _ = try p.match(.EQ);
        var flags: u32 = 0;
        if (p.tok.peek().kind == .NumberU32) {
            const t = try p.match(.NumberU32);
            if (t.u32Value() != 0)
                return p.fail("Root descriptor flag values can only be 0 or flag enum values, found: '{s}'", .{t.str});
        } else {
            while (true) {
                const t = p.tok.get();
                const F = RootDescriptorFlags;
                flags |= switch (t.kind) {
                    .DATA_VOLATILE => F.data_volatile,
                    .DATA_STATIC => F.data_static,
                    .DATA_STATIC_WHILE_SET_AT_EXECUTE => F.data_static_while_set_at_execute,
                    else => return p.fail("Expected a root descriptor flag value, found: '{s}'", .{t.str}),
                };
                const k = p.tok.peek().kind;
                if (k == .RParen or k == .Comma) break;
                _ = try p.match(.OR);
            }
        }
        return flags;
    }

    fn parseDescRangeFlags(p: *Parser) Error!u32 {
        if (p.version == .v1_0)
            return p.fail("Descriptor range flags cannot be specified for root_sig_1_0", .{});
        _ = try p.match(.flags);
        _ = try p.match(.EQ);
        var flags: u32 = 0;
        if (p.tok.peek().kind == .NumberU32) {
            const t = try p.match(.NumberU32);
            if (t.u32Value() != 0)
                return p.fail("Descriptor range flag values can only be 0 or flag enum values, found: '{s}'", .{t.str});
        } else {
            while (true) {
                const t = p.tok.get();
                const F = DescriptorRangeFlags;
                flags |= switch (t.kind) {
                    .DESCRIPTORS_VOLATILE => F.descriptors_volatile,
                    .DATA_VOLATILE => F.data_volatile,
                    .DATA_STATIC => F.data_static,
                    .DATA_STATIC_WHILE_SET_AT_EXECUTE => F.data_static_while_set_at_execute,
                    .DESCRIPTORS_STATIC_KEEPING_BUFFER_BOUNDS_CHECKS => F.descriptors_static_keeping_buffer_bounds_checks,
                    else => return p.fail("Expected a descriptor range flag value, found: '{s}'", .{t.str}),
                };
                const k = p.tok.peek().kind;
                if (k == .RParen or k == .Comma) break;
                _ = try p.match(.OR);
            }
        }
        return flags;
    }

    fn parseVisibility(p: *Parser) Error!ShaderVisibility {
        _ = try p.match(.visibility);
        _ = try p.match(.EQ);
        const t = p.tok.get();
        return switch (t.kind) {
            .SHADER_VISIBILITY_ALL => .all,
            .SHADER_VISIBILITY_VERTEX => .vertex,
            .SHADER_VISIBILITY_HULL => .hull,
            .SHADER_VISIBILITY_DOMAIN => .domain,
            .SHADER_VISIBILITY_GEOMETRY => .geometry,
            .SHADER_VISIBILITY_PIXEL => .pixel,
            .SHADER_VISIBILITY_AMPLIFICATION => .amplification,
            .SHADER_VISIBILITY_MESH => .mesh,
            else => p.fail("Unexpected visibility value: '{s}'.", .{t.str}),
        };
    }

    fn parseStaticSampler(p: *Parser) Error!StaticSampler {
        var s: StaticSampler = .{};
        var seen_filter = false;
        var seen_u = false;
        var seen_v = false;
        var seen_w = false;
        var seen_bias = false;
        var seen_aniso = false;
        var seen_cmp = false;
        var seen_border = false;
        var seen_min = false;
        var seen_max = false;
        var seen_reg = false;
        var seen_space = false;
        var seen_vis = false;
        _ = try p.match(.StaticSampler);
        _ = try p.match(.LParen);
        while (true) {
            const t = p.tok.peek();
            switch (t.kind) {
                .filter => {
                    try p.mark(&seen_filter, "filter");
                    s.filter = try p.parseFilter();
                },
                .addressU => {
                    try p.mark(&seen_u, "addressU");
                    s.address_u = try p.parseTextureAddressMode();
                },
                .addressV => {
                    try p.mark(&seen_v, "addressV");
                    s.address_v = try p.parseTextureAddressMode();
                },
                .addressW => {
                    try p.mark(&seen_w, "addressW");
                    s.address_w = try p.parseTextureAddressMode();
                },
                .mipLODBias => {
                    try p.mark(&seen_bias, "mipLODBias");
                    _ = try p.match(.mipLODBias);
                    _ = try p.match(.EQ);
                    s.mip_lod_bias = try p.parseFloat();
                },
                .maxAnisotropy => {
                    try p.mark(&seen_aniso, "maxAnisotropy");
                    _ = try p.match(.maxAnisotropy);
                    _ = try p.match(.EQ);
                    s.max_anisotropy = (try p.match(.NumberU32)).u32Value();
                },
                .comparisonFunc => {
                    try p.mark(&seen_cmp, "comparisonFunc");
                    s.comparison_func = try p.parseComparisonFunc();
                },
                .borderColor => {
                    try p.mark(&seen_border, "borderColor");
                    s.border_color = try p.parseBorderColor();
                },
                .minLOD => {
                    try p.mark(&seen_min, "minLOD");
                    _ = try p.match(.minLOD);
                    _ = try p.match(.EQ);
                    s.min_lod = try p.parseFloat();
                },
                .maxLOD => {
                    try p.mark(&seen_max, "maxLOD");
                    _ = try p.match(.maxLOD);
                    _ = try p.match(.EQ);
                    s.max_lod = try p.parseFloat();
                },
                .SReg => {
                    try p.mark(&seen_reg, "sampler register s#");
                    s.shader_register = try p.parseRegister(.SReg);
                },
                .space => {
                    try p.mark(&seen_space, "space");
                    s.register_space = try p.parseSpace();
                },
                .visibility => {
                    try p.mark(&seen_vis, "visibility");
                    s.visibility = try p.parseVisibility();
                },
                else => return p.fail("Unexpected token '{s}'", .{t.str}),
            }
            if (try p.endOrComma()) break;
        }
        if (!seen_reg) return p.fail("Sampler register s# must be defined for each static sampler", .{});
        return s;
    }

    fn parseFilter(p: *Parser) Error!u32 {
        _ = try p.match(.filter);
        _ = try p.match(.EQ);
        const t = p.tok.get();
        return switch (t.kind) {
            .FILTER_MIN_MAG_MIP_POINT => 0x0,
            .FILTER_MIN_MAG_POINT_MIP_LINEAR => 0x1,
            .FILTER_MIN_POINT_MAG_LINEAR_MIP_POINT => 0x4,
            .FILTER_MIN_POINT_MAG_MIP_LINEAR => 0x5,
            .FILTER_MIN_LINEAR_MAG_MIP_POINT => 0x10,
            .FILTER_MIN_LINEAR_MAG_POINT_MIP_LINEAR => 0x11,
            .FILTER_MIN_MAG_LINEAR_MIP_POINT => 0x14,
            .FILTER_MIN_MAG_MIP_LINEAR => 0x15,
            .FILTER_ANISOTROPIC => 0x55,
            .FILTER_COMPARISON_MIN_MAG_MIP_POINT => 0x80,
            .FILTER_COMPARISON_MIN_MAG_POINT_MIP_LINEAR => 0x81,
            .FILTER_COMPARISON_MIN_POINT_MAG_LINEAR_MIP_POINT => 0x84,
            .FILTER_COMPARISON_MIN_POINT_MAG_MIP_LINEAR => 0x85,
            .FILTER_COMPARISON_MIN_LINEAR_MAG_MIP_POINT => 0x90,
            .FILTER_COMPARISON_MIN_LINEAR_MAG_POINT_MIP_LINEAR => 0x91,
            .FILTER_COMPARISON_MIN_MAG_LINEAR_MIP_POINT => 0x94,
            .FILTER_COMPARISON_MIN_MAG_MIP_LINEAR => 0x95,
            .FILTER_COMPARISON_ANISOTROPIC => 0xd5,
            .FILTER_MINIMUM_MIN_MAG_MIP_POINT => 0x100,
            .FILTER_MINIMUM_MIN_MAG_POINT_MIP_LINEAR => 0x101,
            .FILTER_MINIMUM_MIN_POINT_MAG_LINEAR_MIP_POINT => 0x104,
            .FILTER_MINIMUM_MIN_POINT_MAG_MIP_LINEAR => 0x105,
            .FILTER_MINIMUM_MIN_LINEAR_MAG_MIP_POINT => 0x110,
            .FILTER_MINIMUM_MIN_LINEAR_MAG_POINT_MIP_LINEAR => 0x111,
            .FILTER_MINIMUM_MIN_MAG_LINEAR_MIP_POINT => 0x114,
            .FILTER_MINIMUM_MIN_MAG_MIP_LINEAR => 0x115,
            .FILTER_MINIMUM_ANISOTROPIC => 0x155,
            .FILTER_MAXIMUM_MIN_MAG_MIP_POINT => 0x180,
            .FILTER_MAXIMUM_MIN_MAG_POINT_MIP_LINEAR => 0x181,
            .FILTER_MAXIMUM_MIN_POINT_MAG_LINEAR_MIP_POINT => 0x184,
            .FILTER_MAXIMUM_MIN_POINT_MAG_MIP_LINEAR => 0x185,
            .FILTER_MAXIMUM_MIN_LINEAR_MAG_MIP_POINT => 0x190,
            .FILTER_MAXIMUM_MIN_LINEAR_MAG_POINT_MIP_LINEAR => 0x191,
            .FILTER_MAXIMUM_MIN_MAG_LINEAR_MIP_POINT => 0x194,
            .FILTER_MAXIMUM_MIN_MAG_MIP_LINEAR => 0x195,
            .FILTER_MAXIMUM_ANISOTROPIC => 0x1d5,
            else => p.fail("Unexpected filter value: '{s}'.", .{t.str}),
        };
    }

    fn parseTextureAddressMode(p: *Parser) Error!u32 {
        _ = p.tok.get(); // addressU / addressV / addressW
        _ = try p.match(.EQ);
        const t = p.tok.get();
        return switch (t.kind) {
            .TEXTURE_ADDRESS_WRAP => 1,
            .TEXTURE_ADDRESS_MIRROR => 2,
            .TEXTURE_ADDRESS_CLAMP => 3,
            .TEXTURE_ADDRESS_BORDER => 4,
            .TEXTURE_ADDRESS_MIRROR_ONCE => 5,
            else => p.fail("Unexpected texture address mode value: '{s}'.", .{t.str}),
        };
    }

    fn parseComparisonFunc(p: *Parser) Error!u32 {
        _ = try p.match(.comparisonFunc);
        _ = try p.match(.EQ);
        const t = p.tok.get();
        return switch (t.kind) {
            .COMPARISON_NONE => 0,
            .COMPARISON_NEVER => 1,
            .COMPARISON_LESS => 2,
            .COMPARISON_EQUAL => 3,
            .COMPARISON_LESS_EQUAL => 4,
            .COMPARISON_GREATER => 5,
            .COMPARISON_NOT_EQUAL => 6,
            .COMPARISON_GREATER_EQUAL => 7,
            .COMPARISON_ALWAYS => 8,
            else => p.fail("Unexpected comparison function value: '{s}'.", .{t.str}),
        };
    }

    fn parseBorderColor(p: *Parser) Error!u32 {
        _ = try p.match(.borderColor);
        _ = try p.match(.EQ);
        const t = p.tok.get();
        return switch (t.kind) {
            .STATIC_BORDER_COLOR_TRANSPARENT_BLACK => 0,
            .STATIC_BORDER_COLOR_OPAQUE_BLACK => 1,
            .STATIC_BORDER_COLOR_OPAQUE_WHITE => 2,
            .STATIC_BORDER_COLOR_OPAQUE_BLACK_UINT => 3,
            .STATIC_BORDER_COLOR_OPAQUE_WHITE_UINT => 4,
            else => p.fail("Unexpected border color value: '{s}'.", .{t.str}),
        };
    }

    fn parseFloat(p: *Parser) Error!f32 {
        const t = p.tok.get();
        return switch (t.kind) {
            .NumberU32 => @floatFromInt(t.u32Value()),
            .NumberI32 => @floatFromInt(t.i32Value()),
            .NumberFloat => t.floatValue(),
            else => p.fail("Expected float, found token '{s}'", .{t.str}),
        };
    }
};

// ---------------------------------------------------------------------------
// Verifier (RootSignatureVerifier::VerifyRootSignature)

const NodeType = enum { descriptor_table_entry, root_descriptor, root_constant, static_sampler };

const RegisterRange = struct {
    nt: NodeType,
    space: u32,
    lb: u32, // inclusive
    ub: u32, // inclusive
    irp: u32,
    idts: u32,
};

const vis_names = [_][]const u8{ "ALL", "VERTEX", "HULL", "DOMAIN", "GEOMETRY", "PIXEL", "AMPLIFICATION", "MESH" };
const range_type_names = [_][]const u8{ "SRV", "UAV", "CBV", "SAMPLER" };

const Verifier = struct {
    arena: Allocator,
    diag: *Diagnostic,
    /// [visibility][range type], each a set of non-overlapping intervals.
    ranges: [8][4]std.ArrayList(RegisterRange) = @splat(@splat(.empty)),

    const Error = error{ VerifyFailed, OutOfMemory };

    fn fail(v: *Verifier, comptime fmt: []const u8, args: anytype) Error {
        v.diag.set(fmt, args);
        return error.VerifyFailed;
    }

    /// std::set<RegisterRange>::find with the "overlap means equal"
    /// comparator: the lowest interval (space, lb order) overlapping `r`.
    fn findIntersecting(set: *const std.ArrayList(RegisterRange), r: RegisterRange) ?*const RegisterRange {
        var best: ?*const RegisterRange = null;
        for (set.items) |*e| {
            if (e.space != r.space) continue;
            if (e.ub < r.lb or e.lb > r.ub) continue;
            if (best == null or e.lb < best.?.lb) best = e;
        }
        return best;
    }

    fn describe(buf: []u8, nt: NodeType, irp: u32, vis: ShaderVisibility, idts: u32, is_node: bool) []const u8 {
        const vn = vis_names[@intFromEnum(vis)];
        return switch (nt) {
            .descriptor_table_entry => if (is_node)
                std.fmt.bufPrint(buf, "(root parameter[{d}], visibility {s}, descriptor table slot [{d}])", .{ irp, vn, idts }) catch buf
            else
                std.fmt.bufPrint(buf, "(root parameter [{d}], visibility {s}, descriptor table slot [{d}])", .{ irp, vn, idts }) catch buf,
            .root_descriptor, .root_constant => std.fmt.bufPrint(buf, "(root parameter [{d}], visibility {s})", .{ irp, vn }) catch buf,
            .static_sampler => std.fmt.bufPrint(buf, "(static sampler [{d}], visibility {s})", .{ irp, vn }) catch buf,
        };
    }

    fn addRegisterRange(
        v: *Verifier,
        irp: u32,
        nt: NodeType,
        idts: u32,
        desc_type: RangeType,
        vis: ShaderVisibility,
        num: u32,
        base: u32,
        space: u32,
    ) Error!void {
        const interval: RegisterRange = .{
            .nt = nt,
            .space = space,
            .lb = base,
            .ub = if (num != std.math.maxInt(u32)) base +% num -% 1 else std.math.maxInt(u32),
            .irp = irp,
            .idts = idts,
        };

        if (space >= SystemReservedRegisterSpaceValuesStart and space <= SystemReservedRegisterSpaceValuesEnd) {
            if (nt == .descriptor_table_entry) {
                return v.fail("Root parameter [{d}] descriptor table entry [{d}] specifies RegisterSpace=0x{x}, which is invalid since RegisterSpace values in the range [0x{x},0x{x}] are reserved for system use.", .{ irp, idts, space, SystemReservedRegisterSpaceValuesStart, SystemReservedRegisterSpaceValuesEnd });
            } else {
                return v.fail("Root parameter [{d}] specifies RegisterSpace=0x{x}, which is invalid since RegisterSpace values in the range [0x{x},0x{x}] are reserved for system use.", .{ irp, space, SystemReservedRegisterSpaceValuesStart, SystemReservedRegisterSpaceValuesEnd });
            }
        }

        const dt = @intFromEnum(desc_type);
        var node: ?*const RegisterRange = null;
        var node_vis = vis;
        if (vis == .all) {
            for (0..8) |ivt| {
                node = findIntersecting(&v.ranges[ivt][dt], interval);
                if (node != null) break;
            }
        } else {
            node = findIntersecting(&v.ranges[@intFromEnum(vis)][dt], interval);
            if (node == null) {
                node = findIntersecting(&v.ranges[0][dt], interval);
                node_vis = .all;
            }
        }

        if (node) |n| {
            var b1: [160]u8 = undefined;
            var b2: [160]u8 = undefined;
            const test_str = describe(&b1, nt, irp, vis, idts, false);
            const node_str = describe(&b2, n.nt, n.irp, node_vis, n.idts, true);
            return v.fail("Shader register range of type {s} {s} overlaps with another shader register range {s}.", .{ range_type_names[dt], test_str, node_str });
        }

        try v.ranges[@intFromEnum(vis)][dt].append(v.arena, interval);
    }

    fn verifyDescriptorTable(v: *Verifier, ranges: []const DescriptorRange, irp: u32) Error!void {
        var has_samplers = false;
        var has_resources = false;
        var append_start: u64 = 0;
        const uint_max: u64 = std.math.maxInt(u32);
        for (ranges, 0..) |r, idts| {
            switch (r.range_type) {
                .srv, .uav, .cbv => has_resources = true,
                .sampler => has_samplers = true,
            }
            if (has_resources and has_samplers)
                return v.fail("Samplers cannot be mixed with other resource types in a descriptor table (root parameter [{d}]).", .{irp});
            if (r.num_descriptors == 0)
                return v.fail("NumDescriptors cannot be 0 (descriptor table slot [{d}], root parameter [{d}]).", .{ idts, irp });

            var start = append_start;
            if (r.offset != DescriptorRangeOffsetAppend) start = r.offset;
            if (start > uint_max)
                return v.fail("Cannot append range with implicit lower bound after an unbounded range (descriptor table slot [{d}], root parameter [{d}]).", .{ idts, irp });

            if (r.num_descriptors != std.math.maxInt(u32)) {
                const ub1 = @as(u64, r.base_shader_register) + r.num_descriptors - 1;
                if (ub1 > uint_max)
                    return v.fail("Overflow for shader register range: BaseShaderRegister={d}, NumDescriptor={d}; (descriptor table slot [{d}], root parameter [{d}]).", .{ r.base_shader_register, r.num_descriptors, idts, irp });
                const ub2 = start + r.num_descriptors - 1;
                if (ub2 > uint_max)
                    return v.fail("Overflow for descriptor range (descriptor table slot [{d}], root parameter [{d}])", .{ idts, irp });
                append_start = start + r.num_descriptors;
            } else {
                append_start = uint_max + 1;
            }
        }
    }

    fn verifyStaticSampler(v: *Verifier, s: *const StaticSampler) Error!void {
        const is_comparison = switch (s.filter) {
            0x100, 0x101, 0x104, 0x105, 0x110, 0x111, 0x114, 0x115, 0x155 => false,
            0x180, 0x181, 0x184, 0x185, 0x190, 0x191, 0x194, 0x195, 0x1d5 => false,
            0x0, 0x1, 0x4, 0x5, 0x10, 0x11, 0x14, 0x15, 0x55 => false,
            0x80, 0x81, 0x84, 0x85, 0x90, 0x91, 0x94, 0x95, 0xd5 => true,
            else => return v.fail("Static sampler: Filter unrecognized.", .{}),
        };
        if (s.address_u < 1 or s.address_u > 5) return v.fail("Static sampler: AddressU unrecognized.", .{});
        if (s.address_v < 1 or s.address_v > 5) return v.fail("Static sampler: AddressV unrecognized.", .{});
        if (s.address_w < 1 or s.address_w > 5) return v.fail("Static sampler: AddressW unrecognized.", .{});

        if (std.math.isNan(s.mip_lod_bias) or s.mip_lod_bias < MipLodBiasMin or s.mip_lod_bias > MipLodBiasMax) {
            var b1: [32]u8 = undefined;
            var b2: [32]u8 = undefined;
            var b3: [32]u8 = undefined;
            return v.fail("Static sampler: MipLODBias must be in the range [{s} to {s}].  {s}specified.", .{
                fmtE(&b1, MipLodBiasMin), fmtE(&b2, MipLodBiasMax), fmtE(&b3, s.mip_lod_bias),
            });
        }
        if (s.max_anisotropy > MaxAnisotropy)
            return v.fail("Static sampler: MaxAnisotropy must be in the range [0 to {d}].  {d} specified.", .{ MaxAnisotropy, s.max_anisotropy });
        if (is_comparison and (s.comparison_func < 1 or s.comparison_func > 8))
            return v.fail("Static sampler: ComparisonFunc unrecognized.", .{});
        if (std.math.isNan(s.min_lod)) {
            var b: [32]u8 = undefined;
            return v.fail("Static sampler: MinLOD be in the range [-INF to +INF].  {s} specified.", .{fmtE(&b, s.min_lod)});
        }
        if (std.math.isNan(s.max_lod)) {
            var b: [32]u8 = undefined;
            return v.fail("Static sampler: MaxLOD be in the range [-INF to +INF].  {s} specified.", .{fmtE(&b, s.max_lod)});
        }
    }
};

/// C printf "%e" (as llvm::raw_ostream prints a double).
fn fmtE(buf: []u8, x: f32) []const u8 {
    const d: f64 = x;
    if (d == 0 and std.math.signbit(d)) return "-0.000000e+00";
    var tmp: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{e:.6}", .{d}) catch return "?";
    const e = std.mem.indexOfScalar(u8, s, 'e') orelse return std.fmt.bufPrint(buf, "{s}", .{s}) catch "?";
    var exp = s[e + 1 ..];
    var sign: u8 = '+';
    if (exp.len > 0 and exp[0] == '-') {
        sign = '-';
        exp = exp[1..];
    }
    if (exp.len == 1)
        return std.fmt.bufPrint(buf, "{s}e{c}0{s}", .{ s[0..e], sign, exp }) catch "?";
    return std.fmt.bufPrint(buf, "{s}e{c}{s}", .{ s[0..e], sign, exp }) catch "?";
}

fn verify(arena: Allocator, rs: *const RootSignature, version: Version, diag: *Diagnostic) Verifier.Error!void {
    var v: Verifier = .{ .arena = arena, .diag = diag };

    if (rs.flags & ~RootSignatureFlags.valid != 0)
        return v.fail("Unsupported bit-flag set (root signature flags 0x{x}).", .{rs.flags});

    for (rs.parameters, 0..) |*param, i| {
        const irp: u32 = @intCast(i);
        const vis = param.visibility;
        switch (param.parameter_type) {
            .descriptor_table => {
                try v.verifyDescriptorTable(param.ranges, irp);
                for (param.ranges, 0..) |r, j| {
                    const idts: u32 = @intCast(j);
                    // A 1.0 signature is up-converted with volatile flags.
                    const flags: u32 = if (version == .v1_0)
                        (if (r.range_type == .sampler)
                            DescriptorRangeFlags.descriptors_volatile
                        else
                            DescriptorRangeFlags.descriptors_volatile | DescriptorRangeFlags.data_volatile)
                    else
                        r.flags;
                    const F = DescriptorRangeFlags;
                    if (flags & ~F.valid != 0)
                        return v.fail("Unsupported bit-flag set (descriptor range flags {d}).", .{flags});
                    if (r.range_type == .sampler) {
                        if (flags & (F.data_volatile | F.data_static | F.data_static_while_set_at_execute) != 0)
                            return v.fail("Sampler descriptor ranges can't specify DATA_* flags since there is no data pointed to by samplers (descriptor range flags {d}).", .{flags});
                    } else {
                        var n: u32 = 0;
                        if (flags & F.data_volatile != 0) n += 1;
                        if (flags & F.data_static != 0) n += 1;
                        if (flags & F.data_static_while_set_at_execute != 0) n += 1;
                        if (n > 1)
                            return v.fail("Descriptor range flags cannot specify more than one DATA_* flag at a time (descriptor range flags {d}).", .{flags});
                        if (flags & F.data_static != 0 and flags & F.descriptors_volatile != 0)
                            return v.fail("Descriptor range flags cannot specify DESCRIPTORS_VOLATILE with the DATA_STATIC flag at the same time (descriptor range flags {d}). DATA_STATIC_WHILE_SET_AT_EXECUTE is fine to combine with DESCRIPTORS_VOLATILE, since DESCRIPTORS_VOLATILE still requires descriptors don't change during execution.", .{flags});
                    }
                    try v.addRegisterRange(irp, .descriptor_table_entry, idts, r.range_type, vis, r.num_descriptors, r.base_shader_register, r.register_space);
                }
            },
            .constants_32bit => try v.addRegisterRange(irp, .root_constant, std.math.maxInt(u32), .cbv, vis, 1, param.shader_register, param.register_space),
            .cbv, .srv, .uav => {
                const flags: u32 = if (version == .v1_0) RootDescriptorFlags.data_volatile else param.flags;
                const F = RootDescriptorFlags;
                if (flags & ~F.valid != 0)
                    return v.fail("Unsupported bit-flag set (root descriptor flags 0x{x}).", .{flags});
                var n: u32 = 0;
                if (flags & F.data_volatile != 0) n += 1;
                if (flags & F.data_static != 0) n += 1;
                if (flags & F.data_static_while_set_at_execute != 0) n += 1;
                if (n > 1)
                    return v.fail("Root descriptor flags cannot specify more than one DATA_* flag at a time (root descriptor flags {d}).", .{n});
                const rt: RangeType = switch (param.parameter_type) {
                    .cbv => .cbv,
                    .srv => .srv,
                    else => .uav,
                };
                try v.addRegisterRange(irp, .root_descriptor, std.math.maxInt(u32), rt, vis, 1, param.shader_register, param.register_space);
            },
        }
    }

    for (rs.static_samplers, 0..) |*s, i| {
        try v.verifyStaticSampler(s);
        try v.addRegisterRange(@intCast(i), .static_sampler, std.math.maxInt(u32), .sampler, s.visibility, 1, s.shader_register, s.register_space);
    }
}

// ---------------------------------------------------------------------------
// Serializer (SerializeRootSignatureTemplate)
//
// Layout (all little-endian u32, every block 4-byte aligned):
//   DxilContainerRootSignatureDesc  { Version, NumParameters,
//     RootParametersOffset, NumStaticSamplers, StaticSamplersOffset, Flags }
//   DxilContainerRootParameter[N]   { ParameterType, ShaderVisibility,
//     PayloadOffset }
//   per parameter, in order:
//     table:     { NumDescriptorRanges, DescriptorRangesOffset } + ranges
//                1.0 range: { RangeType, NumDescriptors, BaseShaderRegister,
//                             RegisterSpace, OffsetInDescriptorsFromTableStart }
//                1.1 range: { ..., RegisterSpace, Flags, Offset... }
//     constants: { ShaderRegister, RegisterSpace, Num32BitValues }
//     CBV/SRV/UAV: { ShaderRegister, RegisterSpace [, Flags (1.1)] }
//   DxilStaticSamplerDesc[M] (13 u32 each)

pub fn serialize(gpa: Allocator, rs: *const RootSignature, version: Version) Allocator.Error![]u8 {
    const v11 = version == .v1_1;
    const range_size: u32 = if (v11) 24 else 20;
    const desc_size: u32 = if (v11) 12 else 8;

    var size: u32 = 24 + 12 * @as(u32, @intCast(rs.parameters.len));
    for (rs.parameters) |param| {
        size += switch (param.parameter_type) {
            .descriptor_table => 8 + range_size * @as(u32, @intCast(param.ranges.len)),
            .constants_32bit => 12,
            .cbv, .srv, .uav => desc_size,
        };
    }
    size += 52 * @as(u32, @intCast(rs.static_samplers.len));

    const out = try gpa.alloc(u8, size);
    errdefer gpa.free(out);
    var w: Writer = .{ .buf = out };

    const params_off: u32 = 24;
    var payload_off: u32 = params_off + 12 * @as(u32, @intCast(rs.parameters.len));

    w.put(@intFromEnum(version));
    w.put(@intCast(rs.parameters.len));
    w.put(params_off);
    w.put(@intCast(rs.static_samplers.len));
    w.put(size - 52 * @as(u32, @intCast(rs.static_samplers.len)));
    w.put(rs.flags);

    // Parameter array with payload offsets.
    for (rs.parameters) |param| {
        w.put(@intFromEnum(param.parameter_type));
        w.put(@intFromEnum(param.visibility));
        w.put(payload_off);
        payload_off += switch (param.parameter_type) {
            .descriptor_table => 8 + range_size * @as(u32, @intCast(param.ranges.len)),
            .constants_32bit => 12,
            .cbv, .srv, .uav => desc_size,
        };
    }

    // Payloads.
    for (rs.parameters) |param| {
        switch (param.parameter_type) {
            .descriptor_table => {
                w.put(@intCast(param.ranges.len));
                w.put(@intCast(w.pos + 4));
                for (param.ranges) |r| {
                    w.put(@intFromEnum(r.range_type));
                    w.put(r.num_descriptors);
                    w.put(r.base_shader_register);
                    w.put(r.register_space);
                    if (v11) w.put(r.flags);
                    w.put(r.offset);
                }
            },
            .constants_32bit => {
                w.put(param.shader_register);
                w.put(param.register_space);
                w.put(param.num_32bit_values);
            },
            .cbv, .srv, .uav => {
                w.put(param.shader_register);
                w.put(param.register_space);
                if (v11) w.put(param.flags);
            },
        }
    }

    for (rs.static_samplers) |s| {
        w.put(s.filter);
        w.put(s.address_u);
        w.put(s.address_v);
        w.put(s.address_w);
        w.put(@bitCast(s.mip_lod_bias));
        w.put(s.max_anisotropy);
        w.put(s.comparison_func);
        w.put(s.border_color);
        w.put(@bitCast(s.min_lod));
        w.put(@bitCast(s.max_lod));
        w.put(s.shader_register);
        w.put(s.register_space);
        w.put(@intFromEnum(s.visibility));
    }
    std.debug.assert(w.pos == out.len);
    return out;
}

const Writer = struct {
    buf: []u8,
    pos: usize = 0,

    fn put(w: *Writer, v: u32) void {
        std.mem.writeInt(u32, w.buf[w.pos..][0..4], v, .little);
        w.pos += 4;
    }
};

// ---------------------------------------------------------------------------
// Tests. Expected blobs are the RTS0 part contents produced by
// `dxc -T rootsig_1_x -E RS` for `#define RS "<text>"`.

fn expectBlob(text: []const u8, version: Version, expected: []const u32) !void {
    const gpa = std.testing.allocator;
    var diag: Diagnostic = .{};
    const got = (try compile(gpa, text, version, &diag)) orelse {
        std.debug.print("unexpected error: {s}\n", .{diag.message()});
        return error.TestUnexpectedResult;
    };
    defer gpa.free(got);
    const exp_bytes = std.mem.sliceAsBytes(expected);
    try std.testing.expectEqualSlices(u8, exp_bytes, got);
}

fn expectError(text: []const u8, version: Version, expected: []const u8) !void {
    const gpa = std.testing.allocator;
    var diag: Diagnostic = .{};
    const got = try compile(gpa, text, version, &diag);
    if (got) |g| {
        gpa.free(g);
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqualStrings(expected, diag.message());
}

test "rootsig bytes: root descriptor, table with unbounded range, default static sampler" {
    const text = "RootFlags(0), CBV(b0), DescriptorTable(UAV(u1), SRV(t0, numDescriptors=unbounded)), StaticSampler(s0)";
    try expectBlob(text, .v1_0, &.{ 0x1, 0x2, 0x18, 0x1, 0x68, 0x0, 0x2, 0x0, 0x30, 0x0, 0x0, 0x38, 0x0, 0x0, 0x2, 0x40, 0x1, 0x1, 0x1, 0x0, 0xffffffff, 0x0, 0xffffffff, 0x0, 0x0, 0xffffffff, 0x55, 0x1, 0x1, 0x1, 0x0, 0x10, 0x4, 0x2, 0x0, 0x7f7fffff, 0x0, 0x0, 0x0 });
    try expectBlob(text, .v1_1, &.{ 0x2, 0x2, 0x18, 0x1, 0x74, 0x0, 0x2, 0x0, 0x30, 0x0, 0x0, 0x3c, 0x0, 0x0, 0x0, 0x2, 0x44, 0x1, 0x1, 0x1, 0x0, 0x0, 0xffffffff, 0x0, 0xffffffff, 0x0, 0x0, 0x0, 0xffffffff, 0x55, 0x1, 0x1, 0x1, 0x0, 0x10, 0x4, 0x2, 0x0, 0x7f7fffff, 0x0, 0x0, 0x0 });
}

test "rootsig bytes: empty signature" {
    const text = "";
    try expectBlob(text, .v1_0, &.{ 0x1, 0x0, 0x18, 0x0, 0x18, 0x0 });
    try expectBlob(text, .v1_1, &.{ 0x2, 0x0, 0x18, 0x0, 0x18, 0x0 });
}

test "rootsig bytes: every root flag" {
    const text = "RootFlags(ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT | DENY_VERTEX_SHADER_ROOT_ACCESS | DENY_HULL_SHADER_ROOT_ACCESS | DENY_DOMAIN_SHADER_ROOT_ACCESS | DENY_GEOMETRY_SHADER_ROOT_ACCESS | DENY_PIXEL_SHADER_ROOT_ACCESS | DENY_AMPLIFICATION_SHADER_ROOT_ACCESS | DENY_MESH_SHADER_ROOT_ACCESS | ALLOW_STREAM_OUTPUT | LOCAL_ROOT_SIGNATURE | CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED | SAMPLER_HEAP_DIRECTLY_INDEXED)";
    try expectBlob(text, .v1_1, &.{ 0x2, 0x0, 0x18, 0x0, 0x18, 0xfff });
}

test "rootsig bytes: case-insensitive keywords, space and visibility" {
    const text = "rootflags(allow_input_assembler_input_layout), cbv(b0, SPACE=3, VISIBILITY=shader_visibility_pixel), Srv(t1), uAv(u2, visibility=SHADER_VISIBILITY_MESH)";
    try expectBlob(text, .v1_0, &.{ 0x1, 0x3, 0x18, 0x0, 0x54, 0x1, 0x2, 0x5, 0x3c, 0x3, 0x0, 0x44, 0x4, 0x7, 0x4c, 0x0, 0x3, 0x1, 0x0, 0x2, 0x0 });
    try expectBlob(text, .v1_1, &.{ 0x2, 0x3, 0x18, 0x0, 0x60, 0x1, 0x2, 0x5, 0x3c, 0x3, 0x0, 0x48, 0x4, 0x7, 0x54, 0x0, 0x3, 0x0, 0x1, 0x0, 0x0, 0x2, 0x0, 0x0 });
}

test "rootsig bytes: root constants" {
    const text = "RootConstants(num32BitConstants=4, b0), RootConstants(b1, num32BitConstants=1, space=7, visibility=SHADER_VISIBILITY_AMPLIFICATION)";
    try expectBlob(text, .v1_0, &.{ 0x1, 0x2, 0x18, 0x0, 0x48, 0x0, 0x1, 0x0, 0x30, 0x1, 0x6, 0x3c, 0x0, 0x0, 0x4, 0x1, 0x7, 0x1 });
}

test "rootsig bytes: 1.1 root descriptor flags" {
    const text = "CBV(b0, flags=DATA_VOLATILE), SRV(t0, flags=DATA_STATIC), UAV(u0, flags=DATA_STATIC_WHILE_SET_AT_EXECUTE), CBV(b1, flags=0)";
    try expectBlob(text, .v1_1, &.{ 0x2, 0x4, 0x18, 0x0, 0x78, 0x0, 0x2, 0x0, 0x48, 0x3, 0x0, 0x54, 0x4, 0x0, 0x60, 0x2, 0x0, 0x6c, 0x0, 0x0, 0x2, 0x0, 0x0, 0x8, 0x0, 0x0, 0x4, 0x1, 0x0, 0x0 });
}

test "rootsig bytes: 1.1 descriptor range flags and offsets" {
    const text = "DescriptorTable(CBV(b0, numDescriptors=3, space=1, flags=DESCRIPTORS_VOLATILE | DATA_VOLATILE, offset=5), SRV(t2, flags=DATA_STATIC), UAV(u3, numDescriptors=2, flags=DESCRIPTORS_VOLATILE|DATA_STATIC_WHILE_SET_AT_EXECUTE, offset=DESCRIPTOR_RANGE_OFFSET_APPEND), SRV(t9, flags=DESCRIPTORS_STATIC_KEEPING_BUFFER_BOUNDS_CHECKS), visibility=SHADER_VISIBILITY_PIXEL)";
    try expectBlob(text, .v1_1, &.{ 0x2, 0x1, 0x18, 0x0, 0x8c, 0x0, 0x0, 0x5, 0x24, 0x4, 0x2c, 0x2, 0x3, 0x0, 0x1, 0x3, 0x5, 0x0, 0x1, 0x2, 0x0, 0x8, 0xffffffff, 0x1, 0x2, 0x3, 0x0, 0x5, 0xffffffff, 0x0, 0x1, 0x9, 0x0, 0x10000, 0xffffffff });
}

test "rootsig bytes: sampler tables" {
    const text = "DescriptorTable(Sampler(s0, numDescriptors=4, flags=DESCRIPTORS_VOLATILE), Sampler(s4, space=2, offset=10)), DescriptorTable(Sampler(s0, numDescriptors=unbounded, space=1))";
    try expectBlob(text, .v1_1, &.{ 0x2, 0x2, 0x18, 0x0, 0x88, 0x0, 0x0, 0x0, 0x30, 0x0, 0x0, 0x68, 0x2, 0x38, 0x3, 0x4, 0x0, 0x0, 0x1, 0xffffffff, 0x3, 0x1, 0x4, 0x2, 0x0, 0xa, 0x1, 0x70, 0x3, 0xffffffff, 0x0, 0x1, 0x0, 0xffffffff });
}

test "rootsig bytes: static sampler with every field" {
    const text = "StaticSampler(s0, filter=FILTER_MIN_MAG_MIP_POINT, addressU=TEXTURE_ADDRESS_MIRROR, addressV=TEXTURE_ADDRESS_CLAMP, addressW=TEXTURE_ADDRESS_BORDER, mipLODBias=1.5, maxAnisotropy=8, comparisonFunc=COMPARISON_NEVER, borderColor=STATIC_BORDER_COLOR_TRANSPARENT_BLACK, minLOD=0.25, maxLOD=12.0f, space=3, visibility=SHADER_VISIBILITY_PIXEL)";
    try expectBlob(text, .v1_0, &.{ 0x1, 0x0, 0x18, 0x1, 0x18, 0x0, 0x0, 0x2, 0x3, 0x4, 0x3fc00000, 0x8, 0x1, 0x0, 0x3e800000, 0x41400000, 0x0, 0x3, 0x5 });
    try expectBlob(text, .v1_1, &.{ 0x2, 0x0, 0x18, 0x1, 0x18, 0x0, 0x0, 0x2, 0x3, 0x4, 0x3fc00000, 0x8, 0x1, 0x0, 0x3e800000, 0x41400000, 0x0, 0x3, 0x5 });
}

test "rootsig bytes: static sampler float forms" {
    const text = "StaticSampler(s0, mipLODBias=0.1, minLOD=1.1e-5, maxLOD=+7.25E+2F), StaticSampler(s1, mipLODBias=-0.3333333, minLOD=4294967295, maxLOD=-2147483648)";
    try expectBlob(text, .v1_1, &.{ 0x2, 0x0, 0x18, 0x2, 0x18, 0x0, 0x55, 0x1, 0x1, 0x1, 0x3dcccccd, 0x10, 0x4, 0x2, 0x37388ca4, 0x44354000, 0x0, 0x0, 0x0, 0x55, 0x1, 0x1, 0x1, 0xbeaaaaaa, 0x10, 0x4, 0x2, 0x4f800000, 0xcf000000, 0x1, 0x0, 0x0 });
}

test "rootsig bytes: static sampler comparison filter" {
    const text = "StaticSampler(s1, filter=FILTER_COMPARISON_MIN_MAG_LINEAR_MIP_POINT, addressU=TEXTURE_ADDRESS_MIRROR_ONCE, addressV=TEXTURE_ADDRESS_WRAP, comparisonFunc=COMPARISON_GREATER_EQUAL, borderColor=STATIC_BORDER_COLOR_OPAQUE_BLACK, mipLODBias=-16, minLOD=-3, maxLOD=1e3)";
    try expectBlob(text, .v1_1, &.{ 0x2, 0x0, 0x18, 0x1, 0x18, 0x0, 0x94, 0x5, 0x1, 0x1, 0xc1800000, 0x10, 0x7, 0x1, 0xc0400000, 0x447a0000, 0x1, 0x0, 0x0 });
}

test "rootsig bytes: empty table followed by enough data" {
    const text = "DescriptorTable(visibility=SHADER_VISIBILITY_GEOMETRY), StaticSampler(s0)";
    try expectBlob(text, .v1_1, &.{ 0x2, 0x1, 0x18, 0x1, 0x2c, 0x0, 0x0, 0x4, 0x24, 0x0, 0x2c, 0x55, 0x1, 0x1, 0x1, 0x0, 0x10, 0x4, 0x2, 0x0, 0x7f7fffff, 0x0, 0x0, 0x0 });
}

test "rootsig bytes: mixed parameters in order" {
    const text = "CBV(b0), DescriptorTable(SRV(t0)), RootConstants(num32BitConstants=2, b1), SRV(t1), UAV(u0), StaticSampler(s0), DescriptorTable(Sampler(s1)), StaticSampler(s2)";
    try expectBlob(text, .v1_0, &.{ 0x1, 0x6, 0x18, 0x2, 0xbc, 0x0, 0x2, 0x0, 0x60, 0x0, 0x0, 0x68, 0x1, 0x0, 0x84, 0x3, 0x0, 0x90, 0x4, 0x0, 0x98, 0x0, 0x0, 0xa0, 0x0, 0x0, 0x1, 0x70, 0x0, 0x1, 0x0, 0x0, 0xffffffff, 0x1, 0x0, 0x2, 0x1, 0x0, 0x0, 0x0, 0x1, 0xa8, 0x3, 0x1, 0x1, 0x0, 0xffffffff, 0x55, 0x1, 0x1, 0x1, 0x0, 0x10, 0x4, 0x2, 0x0, 0x7f7fffff, 0x0, 0x0, 0x0, 0x55, 0x1, 0x1, 0x1, 0x0, 0x10, 0x4, 0x2, 0x0, 0x7f7fffff, 0x2, 0x0, 0x0 });
    try expectBlob(text, .v1_1, &.{ 0x2, 0x6, 0x18, 0x2, 0xd0, 0x0, 0x2, 0x0, 0x60, 0x0, 0x0, 0x6c, 0x1, 0x0, 0x8c, 0x3, 0x0, 0x98, 0x4, 0x0, 0xa4, 0x0, 0x0, 0xb0, 0x0, 0x0, 0x0, 0x1, 0x74, 0x0, 0x1, 0x0, 0x0, 0x0, 0xffffffff, 0x1, 0x0, 0x2, 0x1, 0x0, 0x0, 0x0, 0x0, 0x0, 0x1, 0xb8, 0x3, 0x1, 0x1, 0x0, 0x0, 0xffffffff, 0x55, 0x1, 0x1, 0x1, 0x0, 0x10, 0x4, 0x2, 0x0, 0x7f7fffff, 0x0, 0x0, 0x0, 0x55, 0x1, 0x1, 0x1, 0x0, 0x10, 0x4, 0x2, 0x0, 0x7f7fffff, 0x2, 0x0, 0x0 });
}

test "rootsig rejected like dxc" {
    try expectError("CBV(b0), CBV(b0)", .v1_1, "Shader register range of type CBV (root parameter [1], visibility ALL) overlaps with another shader register range (root parameter [0], visibility ALL).");
    try expectError("CBV(b0, visibility=SHADER_VISIBILITY_PIXEL), CBV(b0)", .v1_1, "Shader register range of type CBV (root parameter [1], visibility ALL) overlaps with another shader register range (root parameter [0], visibility ALL).");
    try expectError("DescriptorTable(SRV(t20, numDescriptors=10), SRV(t5, numDescriptors=10)), SRV(t7, visibility=SHADER_VISIBILITY_DOMAIN)", .v1_1, "Shader register range of type SRV (root parameter [1], visibility DOMAIN) overlaps with another shader register range (root parameter[0], visibility ALL, descriptor table slot [1]).");
    try expectError("StaticSampler(s3), DescriptorTable(Sampler(s0, numDescriptors=8))", .v1_1, "Shader register range of type SAMPLER (static sampler [0], visibility ALL) overlaps with another shader register range (root parameter[0], visibility ALL, descriptor table slot [0]).");
    try expectError("DescriptorTable(Sampler(s0), CBV(b0))", .v1_1, "Samplers cannot be mixed with other resource types in a descriptor table (root parameter [0]).");
    try expectError("DescriptorTable(CBV(b0, numDescriptors=0))", .v1_1, "NumDescriptors cannot be 0 (descriptor table slot [0], root parameter [0]).");
    try expectError("DescriptorTable(CBV(b0, numDescriptors=unbounded), CBV(b1))", .v1_1, "Cannot append range with implicit lower bound after an unbounded range (descriptor table slot [1], root parameter [0]).");
    try expectError("DescriptorTable(CBV(b4294967295, numDescriptors=2))", .v1_1, "Overflow for shader register range: BaseShaderRegister=4294967295, NumDescriptor=2; (descriptor table slot [0], root parameter [0]).");
    try expectError("CBV(b0, space=4294967280)", .v1_1, "Root parameter [0] specifies RegisterSpace=0xfffffff0, which is invalid since RegisterSpace values in the range [0xfffffff0,0xffffffff] are reserved for system use.");
    try expectError("DescriptorTable(CBV(b0, flags=DATA_STATIC|DESCRIPTORS_VOLATILE))", .v1_1, "Descriptor range flags cannot specify DESCRIPTORS_VOLATILE with the DATA_STATIC flag at the same time (descriptor range flags 9). DATA_STATIC_WHILE_SET_AT_EXECUTE is fine to combine with DESCRIPTORS_VOLATILE, since DESCRIPTORS_VOLATILE still requires descriptors don't change during execution.");
    try expectError("DescriptorTable(Sampler(s0, flags=DATA_VOLATILE))", .v1_1, "Sampler descriptor ranges can't specify DATA_* flags since there is no data pointed to by samplers (descriptor range flags 2).");
    try expectError("CBV(b0, flags=DATA_VOLATILE|DATA_STATIC)", .v1_1, "Root descriptor flags cannot specify more than one DATA_* flag at a time (root descriptor flags 2).");
    try expectError("StaticSampler(s0, mipLODBias=16)", .v1_1, "Static sampler: MipLODBias must be in the range [-1.600000e+01 to 1.599000e+01].  1.600000e+01specified.");
    try expectError("StaticSampler(s0, maxAnisotropy=17)", .v1_1, "Static sampler: MaxAnisotropy must be in the range [0 to 16].  17 specified.");
    try expectError("StaticSampler(s0, filter=FILTER_COMPARISON_ANISOTROPIC, comparisonFunc=COMPARISON_NONE)", .v1_1, "Static sampler: ComparisonFunc unrecognized.");
    try expectError("StaticSampler(s0, minLOD=1e39)", .v1_1, "Expected float, found token '1e39'");
    try expectError("StaticSampler(s0, mipLODBias=1e)", .v1_1, "Expected float, found token '1epLODBias'");
    try expectError("CBV(t0)", .v1_1, "Incorrect register type 't0' in CBV (expected b#)");
    try expectError("RootFlags(1)", .v1_1, "Root signature flag values can only be 0 or flag enum values, found: '1'");
    try expectError("RootFlags(0), RootFlags(0)", .v1_1, "RootFlags cannot be specified more than once");
    try expectError("RootConstants(num32BitConstants=3)", .v1_1, "Constant buffer register b# must be defined for each RootConstants");
    try expectError("CBV(b0) CBV(b1)", .v1_1, "Expected ',', found: 'CBV'");
    try expectError("CBV(b0), #", .v1_1, "Unexpected token '#' when parsing root signature");
    try expectError("DescriptorTable()", .v1_1, "Unexpected token ')'");
    try expectError("StaticSampler(s0, filter=FILTER_ANISOTROPIC, filter=FILTER_ANISOTROPIC)", .v1_1, "Parameter 'filter' can be specified only once");
    try expectError("CBV(b0, flags=DATA_VOLATILE)", .v1_0, "Root descriptor flags cannot be specified for root_sig_1_0");
    try expectError("DescriptorTable(CBV(b0, flags=DATA_VOLATILE))", .v1_0, "Descriptor range flags cannot be specified for root_sig_1_0");
}

test "rootsig empty table at end fails container validation" {
    // dxc: "root signature validation errors ... Validation failed."
    const gpa = std.testing.allocator;
    var diag: Diagnostic = .{};
    try std.testing.expect((try compile(gpa, "DescriptorTable(visibility=SHADER_VISIBILITY_GEOMETRY), CBV(b0)", .v1_1, &diag)) == null);
    try std.testing.expect(diag.kind == .validation);
}

test "rootsig compilation flags" {
    const gpa = std.testing.allocator;
    var diag: Diagnostic = .{};
    try std.testing.expect((try compileWithOptions(gpa, "RootFlags(LOCAL_ROOT_SIGNATURE)", .{ .flags = .global }, &diag)) == null);
    try std.testing.expectEqualStrings("LOCAL_ROOT_SIGNATURE flag used in global root signature", diag.message());
    const blob = (try compileWithOptions(gpa, "CBV(b0)", .{ .flags = .local }, &diag)).?;
    defer gpa.free(blob);
    try std.testing.expectEqual(@as(u32, RootSignatureFlags.local_root_signature), std.mem.readInt(u32, blob[20..24], .little));
}
