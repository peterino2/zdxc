//! Syntax tree for HLSL 2021. Purely syntactic: names are not resolved and
//! types are recorded as written. Nodes live in the parser's arena.

const std = @import("std");
const source = @import("source.zig");
pub const Loc = source.Loc;

/// A possibly qualified name as written: `foo`, `N::foo`, `::foo`.
pub const Name = struct {
    loc: Loc,
    /// Components without separators; a leading empty component means
    /// a global-scope `::` prefix.
    parts: []const []const u8,
    /// Template arguments per part (`S<T>::value`); empty when no part has
    /// any, otherwise the same length as `parts`.
    args: []const []const TemplateArg = &.{},

    pub fn last(n: Name) []const u8 {
        return n.parts[n.parts.len - 1];
    }

    pub fn isSimple(n: Name, s: []const u8) bool {
        return n.parts.len == 1 and std.mem.eql(u8, n.parts[0], s);
    }
};

pub const TemplateArg = union(enum) {
    type: *TypeRef,
    expr: *Expr,
};

/// A type as written: `float4`, `Texture2D<float4>`, `vector<float, 4>`,
/// `N::S<T>`. Resolution happens in Sema.
pub const TypeRef = struct {
    loc: Loc,
    name: Name,
    args: []const TemplateArg = &.{},
    /// Array dimensions on type arguments: `StructuredBuffer<float[3]>`.
    array_dims: []const ?*Expr = &.{},
    /// `[[...]]` attributes after the type (`__builtin_LinAlgMatrix [[...]]`).
    attrs: []const Attribute = &.{},
    /// `unorm` / `snorm` inside resource element types.
    norm: enum { none, unorm, snorm } = .none,
    /// `__decltype(expr)`: the type of `expr` (`name` is `__decltype`).
    decltype: ?*Expr = null,
    /// Spelled with `unsigned` (only integer types may be).
    unsigned_spec: bool = false,
    /// Type attributes written on this reference, in order: `row_major`,
    /// `column_major`, `unorm`, `snorm` (template arguments, typedefs).
    attr_words: []const QualWord = &.{},
};

/// Storage classes, type qualifiers and parameter / interpolation
/// modifiers that may precede a declaration.
pub const Qualifiers = packed struct(u64) {
    @"const": bool = false,
    static: bool = false,
    uniform: bool = false,
    @"extern": bool = false,
    @"volatile": bool = false,
    precise: bool = false,
    groupshared: bool = false,
    shared: bool = false,
    in: bool = false,
    out: bool = false,
    row_major: bool = false,
    column_major: bool = false,
    nointerpolation: bool = false,
    linear: bool = false,
    centroid: bool = false,
    sample: bool = false,
    noperspective: bool = false,
    globallycoherent: bool = false,
    reordercoherent: bool = false,
    @"inline": bool = false,
    @"export": bool = false,
    // Geometry shader input primitive types.
    point: bool = false,
    line: bool = false,
    triangle: bool = false,
    lineadj: bool = false,
    triangleadj: bool = false,
    // Mesh shader output / payload modifiers.
    vertices: bool = false,
    indices: bool = false,
    primitives: bool = false,
    payload: bool = false,
    center: bool = false,
    _: u33 = 0,
};

/// A qualifier keyword as written: some diagnostics depend on the order
/// and position of qualifiers, which `Qualifiers` does not keep.
pub const QualWord = struct { loc: Loc, word: []const u8 };

/// `[name(args)]` or `[[ns::name(args)]]`.
pub const Attribute = struct {
    loc: Loc,
    /// e.g. `numthreads`, `vk::binding`.
    name: []const u8,
    args: []const *Expr,
    double_bracket: bool,
};

/// Text after `:` on a declarator.
pub const Semantic = struct {
    loc: Loc,
    /// `access` is a ray payload qualifier: `read(caller)`, `write(miss)`.
    kind: enum { semantic, register, packoffset, access },
    /// Semantic name (`SV_Target0`), or the comma-separated arguments of
    /// register(...) / packoffset(...) with internal tokens joined
    /// (`t0`, `space1`, `c0.x`).
    values: []const []const u8,
};

pub const UnaryOp = enum { plus, minus, not, bit_not, pre_inc, pre_dec, post_inc, post_dec };

pub const BinaryOp = enum {
    mul,
    div,
    rem,
    add,
    sub,
    shl,
    shr,
    lt,
    gt,
    le,
    ge,
    eq,
    ne,
    bit_and,
    bit_xor,
    bit_or,
    log_and,
    log_or,
    comma,
};

pub const AssignOp = enum { assign, mul, div, rem, add, sub, shl, shr, bit_and, bit_xor, bit_or };

pub const Expr = struct {
    loc: Loc,
    kind: Kind,
    /// Filled in by Sema: the expression's type (a sema TypeId; 0 is the
    /// error type) and an index into Sema's per-expression information.
    ty: u32 = 0,
    info: u32 = 0,

    pub const Kind = union(enum) {
        int_lit: []const u8,
        float_lit: []const u8,
        bool_lit: bool,
        string_lit: []const u8,
        name: Name,
        this,
        unary: struct { op: UnaryOp, operand: *Expr },
        binary: struct { op: BinaryOp, lhs: *Expr, rhs: *Expr },
        assign: struct { op: AssignOp, lhs: *Expr, rhs: *Expr },
        conditional: struct { cond: *Expr, then: *Expr, @"else": *Expr },
        /// Function or method call; `template_args` for `f<T>(...)`.
        call: struct { callee: *Expr, args: []const *Expr, template_args: []const TemplateArg = &.{} },
        /// Type used as a function: `float4(...)`, `vector<float, 2>(...)`.
        construct: struct { type: *TypeRef, args: []const *Expr },
        cast: struct { type: *TypeRef, array_dims: []const ?*Expr = &.{}, operand: *Expr },
        /// `.name` (field, swizzle or method); `arrow` is accepted for
        /// error reporting.
        member: struct { base: *Expr, name: []const u8, name_loc: Loc },
        index: struct { base: *Expr, index: *Expr },
        init_list: []const *Expr,
        sizeof_type: *TypeRef,
        sizeof_expr: *Expr,
        /// `std::is_same<A, B>::value` (a dxc builtin).
        is_same: struct { a: *TypeRef, b: *TypeRef },
    };
};

pub const Stmt = struct {
    loc: Loc,
    attrs: []const Attribute = &.{},
    kind: Kind,

    pub const Kind = union(enum) {
        compound: []const *Stmt,
        /// Local declarations: variables, typedefs, structs.
        decl: []const *Decl,
        expr: *Expr,
        empty,
        /// `cond_decl` is set for `if (T x = e)`; `cond` then names `x`.
        @"if": struct { cond_decl: ?*Decl = null, cond: *Expr, then: *Stmt, @"else": ?*Stmt },
        @"for": struct { init: ?*Stmt, cond: ?*Expr, inc: ?*Expr, body: *Stmt },
        @"while": struct { cond_decl: ?*Decl = null, cond: *Expr, body: *Stmt },
        do_while: struct { body: *Stmt, cond: *Expr },
        @"switch": struct { cond_decl: ?*Decl = null, cond: *Expr, body: *Stmt },
        case: struct { value: *Expr, stmt: *Stmt },
        default: *Stmt,
        @"break",
        @"continue",
        @"return": ?*Expr,
        discard,
    };
};

pub const VarDecl = struct {
    attrs: []const Attribute,
    /// Non-empty for variable templates.
    template_params: []const TemplateParam = &.{},
    /// Qualified out-of-line definitions (`int S::x = 1;`) keep the full
    /// spelled name, e.g. `S::x`.
    quals: Qualifiers,
    /// The qualifiers in source order.
    qual_words: []const QualWord = &.{},
    type: *TypeRef,
    name: []const u8,
    name_loc: Loc,
    array_dims: []const ?*Expr,
    semantics: []const Semantic,
    bitfield: ?*Expr = null,
    init: ?*Expr = null,
    /// Arguments of a variable template specialization: `v<T, T>`.
    specialization_args: []const TemplateArg = &.{},
};

pub const TemplateParam = struct {
    loc: Loc,
    name: []const u8,
    /// null for `typename T` / `class T`; the type for value parameters.
    value_type: ?*TypeRef,
    default: ?TemplateArg,
};

pub const FuncDecl = struct {
    attrs: []const Attribute,
    quals: Qualifiers,
    qual_words: []const QualWord = &.{},
    template_params: []const TemplateParam,
    /// `template <class T> template <class U> R S<T>::f()`: the class
    /// template's parameters (`template_params` are the member's own).
    outer_template_params: []const TemplateParam = &.{},
    ret: *TypeRef,
    /// Function name; for operators `operator+`, `operator[]`, `operator()`.
    name: Name,
    params: []const VarDecl,
    ret_semantics: []const Semantic,
    /// Array dimensions after the parameter list (`T f()[N]`).
    ret_dims: []const ?*Expr = &.{},
    /// Trailing `const` on methods.
    is_const: bool,
    body: ?*Stmt,
};

pub const StructDecl = struct {
    attrs: []const Attribute,
    keyword: enum { @"struct", class, interface },
    template_params: []const TemplateParam,
    name: ?[]const u8,
    /// Arguments of a partial / explicit specialization: `S<true, T>`.
    specialization_args: []const TemplateArg = &.{},
    bases: []const *TypeRef,
    /// Null for a forward declaration.
    members: ?[]const *Decl,
};

pub const CBufferDecl = struct {
    attrs: []const Attribute = &.{},
    tbuffer: bool,
    name: []const u8,
    semantics: []const Semantic,
    members: []const *Decl,
};

pub const EnumDecl = struct {
    name: ?[]const u8,
    scoped: bool,
    underlying: ?*TypeRef,
    values: []const struct { loc: Loc, name: []const u8, value: ?*Expr },
};

pub const Decl = struct {
    loc: Loc,
    kind: Kind,

    pub const Kind = union(enum) {
        @"var": VarDecl,
        func: FuncDecl,
        @"struct": StructDecl,
        cbuffer: CBufferDecl,
        /// `alias`: written `using name = type;`.
        typedef: struct { name: []const u8, type: *TypeRef, array_dims: []const ?*Expr, template_params: []const TemplateParam = &.{}, qual_words: []const QualWord = &.{}, attrs: []const Attribute = &.{}, alias: bool = false },
        @"enum": EnumDecl,
        namespace: struct { name: []const u8, decls: []const *Decl },
        /// `using namespace N;`
        using_namespace: Name,
        /// `using N::name;`
        using_decl: Name,
        pragma: []const u8,
        static_assert: struct { cond: *Expr, message: ?[]const u8 },
    };
};

pub const TranslationUnit = struct {
    decls: []const *Decl,
};
