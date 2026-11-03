//! The DXC drop-in: dxcompiler's COM API (dxcapi.h) over `compile`, so a
//! client that loads libdxcompiler / dxcompiler.dll and calls
//! DxcCreateInstance (SDL_shadercross, for one) runs on zdxc unchanged.
//!
//! Classes: CLSID_DxcCompiler (IDxcCompiler3, IDxcVersionInfo) and
//! CLSID_DxcUtils, which is CLSID_DxcLibrary (IDxcUtils), plus the result,
//! blob and include-handler objects they hand out. Other classes return
//! REGDB_E_CLASSNOTREG and methods without an implementation E_NOTIMPL.
//!
//! The ABI follows dxcapi.h and WinAdapter.h: an interface pointer points
//! at a vtable pointer; IUnknown has no virtual destructor; on Unix, BOOL is
//! a 1-byte bool, WCHAR is a 4-byte wchar_t and ULONG is unsigned long.
//! Where the header leaves behavior open, this follows what DXC's library
//! does (test/dropin in the development repo compares the two).

const std = @import("std");
const BumpArena = @import("zdxc").BumpArena;
const builtin = @import("builtin");
const zdxc = @import("zdxc");
const compile = zdxc.compile;
const FileSystem = zdxc.front.source.FileSystem;

const windows = builtin.os.tag == .windows;
const cc: std.builtin.CallingConvention = .c;
const gpa = std.heap.smp_allocator;

const HRESULT = i32;
const ULONG = c_ulong;
const BOOL = if (windows) i32 else bool;
const WCHAR = if (windows) u16 else u32;

fn code(comptime v: u32) HRESULT {
    return @bitCast(v);
}
const S_OK: HRESULT = 0;
const E_FAIL = code(0x80004005);
const E_NOTIMPL = code(0x80004001);
const E_NOINTERFACE = code(0x80004002);
const E_POINTER = code(0x80004003);
const E_INVALIDARG = code(0x80070057);
const E_OUTOFMEMORY = code(0x8007000E);
const REGDB_E_CLASSNOTREG = code(0x80040154);
const FILE_NOT_FOUND = code(0x80070002); // HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND)

const CP_ACP = 0;
const CP_UTF8 = 65001;
const CP_UTF16 = 1200;
const CP_UTF32 = 12000;
const CP_WIDE = if (windows) CP_UTF16 else CP_UTF32;

/// DXC_OUT_KIND.
const OutKind = enum(u32) {
    none = 0,
    object = 1,
    errors = 2,
    shader_hash = 4,
    hlsl = 6,
    text = 7,
    reflection = 8,
    root_signature = 9,
    remarks = 11,
    _,
};

/// DxcBuffer.
const Buffer = extern struct {
    ptr: ?[*]const u8,
    size: usize,
    encoding: c_uint,
};

const GUID = extern struct {
    a: u32,
    b: u16,
    c: u16,
    d: [8]u8,

    fn parse(comptime s: []const u8) GUID {
        @setEvalBranchQuota(10000);
        const hex = struct {
            fn f(t: []const u8) u64 {
                return std.fmt.parseInt(u64, t, 16) catch unreachable;
            }
        }.f;
        var d: [8]u8 = undefined;
        d[0] = @intCast(hex(s[19..21]));
        d[1] = @intCast(hex(s[21..23]));
        for (0..6) |i| d[2 + i] = @intCast(hex(s[24 + 2 * i ..][0..2]));
        return .{ .a = @intCast(hex(s[0..8])), .b = @intCast(hex(s[9..13])), .c = @intCast(hex(s[14..18])), .d = d };
    }

    fn eql(x: *const GUID, y: GUID) bool {
        return std.mem.eql(u8, std.mem.asBytes(x), std.mem.asBytes(&y));
    }
};

const CLSID_DxcCompiler = GUID.parse("73e22d93-e6ce-47f3-b5bf-f0664f39c1b0");
const CLSID_DxcUtils = GUID.parse("6245d6af-66e0-48fd-80b4-4d271796748c"); // == CLSID_DxcLibrary
const CLSID_DxcContainerReflection = GUID.parse("b9f54489-55b8-400c-ba3a-1675e4728b91");
const CLSID_DxcContainerBuilder = GUID.parse("94134294-411f-4574-b4d0-8741e25240d2");
const IID_IDxcLibrary = GUID.parse("e5204dc7-d18c-4c3c-bdfb-851673980fe7");
const IID_IDxcContainerReflection = GUID.parse("d2c21b26-8350-4bdc-976a-331ce6f4c54c");
const IID_IDxcContainerBuilder = GUID.parse("334b1f50-2292-4b35-99a1-25588d8c17fe");
const IID_ID3D12ShaderReflection = GUID.parse("5a58797d-a72c-478d-8ba2-efc6b0efe88e");
const IID_ID3D12LibraryReflection = GUID.parse("8e349d19-54db-4a56-9dc9-119d87bdb804");
const IID_IUnknown = GUID.parse("00000000-0000-0000-c000-000000000046");
const IID_IDxcBlob = GUID.parse("8ba5fb08-5195-40e2-ac58-0d989c3a0102");
const IID_IDxcBlobEncoding = GUID.parse("7241d424-2646-4191-97c0-98e96e42fc68");
const IID_IDxcBlobUtf8 = GUID.parse("3da636c9-ba71-4024-a301-30cbf125305b");
const IID_IDxcBlobWide = GUID.parse("a3f84eab-0faa-497e-a39c-ee6ed60b2d84");
const IID_IDxcIncludeHandler = GUID.parse("7f61fc7d-950d-467f-b3e3-3c02fb49187c");
const IID_IDxcOperationResult = GUID.parse("cedb484a-d4e9-445a-b991-ca21ca157dc2");
const IID_IDxcResult = GUID.parse("58346cda-dde7-4497-9461-6f87af5e0659");
const IID_IDxcCompiler3 = GUID.parse("228b4687-5a6a-4730-900c-9702b2203f54");
const IID_IDxcUtils = GUID.parse("4605c4cb-2019-492a-ada4-65f20bb7d67f");
const IID_IDxcVersionInfo = GUID.parse("b04f5b50-2059-4f12-a8ff-a1e0cde1cc7e");

/// The version DXC clients see: zdxc follows DXC 1.11's behavior (Slang,
/// for one, passes -HV 2021 only to 1.7 and later).
const version_major = 1;
const version_minor = 11;

// ---------------------------------------------------------------------------
// Objects

const This = *anyopaque;
const Out = *?*anyopaque;

const UnknownVtbl = extern struct {
    QueryInterface: *const fn (This, *const GUID, ?Out) callconv(cc) HRESULT,
    AddRef: *const fn (This) callconv(cc) ULONG,
    Release: *const fn (This) callconv(cc) ULONG,
};

/// What every object shares: an atomic reference count and how to free it.
const RefCount = struct {
    refs: std.atomic.Value(u32) = .init(1),

    fn addRef(r: *RefCount) ULONG {
        return r.refs.fetchAdd(1, .monotonic) + 1;
    }

    /// The count after releasing; the caller frees the object at 0.
    fn release(r: *RefCount) u32 {
        const n = r.refs.fetchSub(1, .acq_rel) - 1;
        return n;
    }
};

/// An interface pointer: a pointer to its vtable pointer.
fn Iface(comptime Vtbl: type) type {
    return extern struct { vtbl: *const Vtbl };
}

/// The vtable of a COM object we did not necessarily create.
fn vtblOf(comptime Vtbl: type, obj: *anyopaque) *const Vtbl {
    return @as(*const *const Vtbl, @ptrCast(@alignCast(obj))).*;
}

fn parent(comptime T: type, comptime field: []const u8, this: This) *T {
    return @fieldParentPtr(field, @as(*@FieldType(T, field), @ptrCast(@alignCast(this))));
}

fn put(out: ?Out, value: ?*anyopaque) HRESULT {
    const o = out orelse return E_POINTER;
    o.* = value;
    return S_OK;
}

// ---- Blobs ----------------------------------------------------------------

/// IDxcBlob, IDxcBlobEncoding and IDxcBlobUtf8 / IDxcBlobWide share one
/// vtable chain; which of them a blob answers depends on its kind.
const BlobVtbl = extern struct {
    unknown: UnknownVtbl,
    GetBufferPointer: *const fn (This) callconv(cc) ?*const anyopaque,
    GetBufferSize: *const fn (This) callconv(cc) usize,
    GetEncoding: *const fn (This, ?*BOOL, ?*u32) callconv(cc) HRESULT,
    GetStringPointer: *const fn (This) callconv(cc) ?*const anyopaque,
    GetStringLength: *const fn (This) callconv(cc) usize,
};

const Blob = struct {
    iface: Iface(BlobVtbl) = .{ .vtbl = &vtbl },
    rc: RefCount = .{},
    kind: Kind,
    /// The bytes GetBufferPointer returns. For utf8 and wide blobs with
    /// text, a NUL follows `bytes` (and GetBufferSize counts it, as DXC's
    /// do).
    bytes: []const u8,
    /// Freed with the blob, unless the blob is pinned.
    owned: bool,
    code_page: u32 = CP_ACP,

    const Kind = enum { binary, encoded, utf8, wide };

    const vtbl: BlobVtbl = .{
        .unknown = .{ .QueryInterface = queryInterface, .AddRef = addRef, .Release = release },
        .GetBufferPointer = getBufferPointer,
        .GetBufferSize = getBufferSize,
        .GetEncoding = getEncoding,
        .GetStringPointer = getStringPointer,
        .GetStringLength = getStringLength,
    };

    fn of(this: This) *Blob {
        return parent(Blob, "iface", this);
    }

    fn ptr(b: *Blob) *anyopaque {
        return &b.iface;
    }

    fn create(kind: Kind, bytes: []const u8, owned: bool, code_page: u32) !*Blob {
        const b = gpa.create(Blob) catch |e| {
            if (owned) gpa.free(bytes);
            return e;
        };
        b.* = .{ .kind = kind, .bytes = bytes, .owned = owned, .code_page = code_page };
        return b;
    }

    /// A blob holding a copy of `data`.
    fn copy(kind: Kind, data: []const u8, code_page: u32) !*Blob {
        return create(kind, try gpa.dupe(u8, data), true, code_page);
    }

    /// A UTF-8 text blob: GetBufferSize is the length plus its NUL, or 0
    /// when empty.
    fn utf8(text: []const u8) !*Blob {
        const z = try gpa.dupeSentinel(u8, text, 0);
        return create(.utf8, z[0 .. z.len + @intFromBool(z.len > 0)], true, CP_UTF8);
    }

    /// A wide text blob (for output names).
    fn wide(text: []const u8) !*Blob {
        const w = try toWide(gpa, text);
        const bytes = std.mem.sliceAsBytes(w.ptr[0 .. w.len + 1]);
        return create(.wide, bytes, true, CP_WIDE);
    }

    fn queryInterface(this: This, iid: *const GUID, out: ?Out) callconv(cc) HRESULT {
        const b = of(this);
        const ok = iid.eql(IID_IUnknown) or iid.eql(IID_IDxcBlob) or
            (b.kind != .binary and iid.eql(IID_IDxcBlobEncoding)) or
            (b.kind == .utf8 and iid.eql(IID_IDxcBlobUtf8)) or
            (b.kind == .wide and iid.eql(IID_IDxcBlobWide));
        if (!ok) {
            _ = put(out, null);
            return E_NOINTERFACE;
        }
        _ = b.rc.addRef();
        return put(out, this);
    }

    fn addRef(this: This) callconv(cc) ULONG {
        return of(this).rc.addRef();
    }

    fn release(this: This) callconv(cc) ULONG {
        const b = of(this);
        const n = b.rc.release();
        if (n == 0) {
            if (b.owned) gpa.free(b.allocation());
            gpa.destroy(b);
        }
        return n;
    }

    /// Everything allocated for `bytes`, including a trailing NUL.
    fn allocation(b: *Blob) []const u8 {
        return switch (b.kind) {
            .utf8 => b.bytes.ptr[0 .. b.textLen() + 1],
            else => b.bytes,
        };
    }

    fn textLen(b: *Blob) usize {
        return switch (b.kind) {
            .utf8 => if (b.bytes.len == 0) 0 else b.bytes.len - 1,
            .wide => b.bytes.len / @sizeOf(WCHAR) - 1,
            else => b.bytes.len,
        };
    }

    fn getBufferPointer(this: This) callconv(cc) ?*const anyopaque {
        const b = of(this);
        return if (b.bytes.len == 0 and b.kind == .binary) null else b.bytes.ptr;
    }

    fn getBufferSize(this: This) callconv(cc) usize {
        return of(this).bytes.len;
    }

    fn getEncoding(this: This, known: ?*BOOL, code_page: ?*u32) callconv(cc) HRESULT {
        const b = of(this);
        if (known) |k| k.* = if (windows) 1 else true;
        if (code_page) |c| c.* = b.code_page;
        return S_OK;
    }

    fn getStringPointer(this: This) callconv(cc) ?*const anyopaque {
        return of(this).bytes.ptr;
    }

    fn getStringLength(this: This) callconv(cc) usize {
        return of(this).textLen();
    }
};

/// The bytes of any IDxcBlob, ours or the client's: only GetBufferPointer
/// and GetBufferSize are trusted (Slang, for one, passes its own blobs).
fn blobBytes(blob: *anyopaque) []const u8 {
    const v = vtblOf(BlobVtbl, blob);
    const size = v.GetBufferSize(blob);
    const p: ?[*]const u8 = @ptrCast(v.GetBufferPointer(blob));
    return if (p) |q| q[0..size] else &.{};
}

fn releaseUnknown(obj: *anyopaque) void {
    const v = vtblOf(UnknownVtbl, obj);
    _ = v.Release(obj);
}

// ---- Text -----------------------------------------------------------------

/// A NUL-terminated wide string, as UTF-8.
fn fromWide(a: std.mem.Allocator, w: [*:0]const WCHAR) ![]u8 {
    return fromWideSlice(a, std.mem.span(w));
}

fn fromWideSlice(a: std.mem.Allocator, w: []const WCHAR) ![]u8 {
    if (WCHAR == u16) return std.unicode.utf16LeToUtf8Alloc(a, w) catch error.InvalidArgument;
    var out: std.ArrayList(u8) = .empty;
    for (w) |c| {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(std.math.cast(u21, c) orelse return error.InvalidArgument, &buf) catch return error.InvalidArgument;
        try out.appendSlice(a, buf[0..n]);
    }
    return out.toOwnedSlice(a);
}

/// UTF-8 as a NUL-terminated wide string.
fn toWide(a: std.mem.Allocator, s: []const u8) ![:0]WCHAR {
    if (WCHAR == u16) return std.unicode.utf8ToUtf16LeAllocZ(a, s) catch error.InvalidArgument;
    var out: std.ArrayList(WCHAR) = .empty;
    var it = (std.unicode.Utf8View.init(s) catch return error.InvalidArgument).iterator();
    while (it.nextCodepoint()) |c| try out.append(a, c);
    return out.toOwnedSliceSentinel(a, 0);
}

/// Text in `code_page` (or, for CP_ACP, as its BOM says, else UTF-8) as
/// UTF-8, without a BOM or trailing NULs.
fn decodeText(a: std.mem.Allocator, bytes: []const u8, code_page: u32) ![]const u8 {
    var cp = code_page;
    var b = bytes;
    if (cp == CP_ACP or cp == CP_UTF8) {
        if (std.mem.startsWith(u8, b, "\xEF\xBB\xBF")) {
            b = b[3..];
        } else if (cp == CP_ACP and std.mem.startsWith(u8, b, "\xFF\xFE\x00\x00")) {
            cp = CP_UTF32;
        } else if (cp == CP_ACP and std.mem.startsWith(u8, b, "\xFF\xFE")) {
            cp = CP_UTF16;
        }
    }
    switch (cp) {
        CP_UTF16 => {
            if (std.mem.startsWith(u8, b, "\xFF\xFE")) b = b[2..];
            const units = try a.alloc(u16, b.len / 2);
            for (units, 0..) |*u, i| u.* = std.mem.readInt(u16, b[2 * i ..][0..2], .little);
            const text = std.unicode.utf16LeToUtf8Alloc(a, units) catch return error.InvalidArgument;
            return std.mem.trimEnd(u8, text, "\x00");
        },
        CP_UTF32 => {
            if (std.mem.startsWith(u8, b, "\xFF\xFE\x00\x00")) b = b[4..];
            var out: std.ArrayList(u8) = .empty;
            var i: usize = 0;
            while (i + 4 <= b.len) : (i += 4) {
                const c = std.mem.readInt(u32, b[i..][0..4], .little);
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(std.math.cast(u21, c) orelse return error.InvalidArgument, &buf) catch return error.InvalidArgument;
                try out.appendSlice(a, buf[0..n]);
            }
            return std.mem.trimEnd(u8, out.items, "\x00");
        },
        else => return std.mem.trimEnd(u8, b, "\x00"),
    }
}

/// DXC's spelling of a path handed to an include handler (NormalizePathW
/// in DXC's Support/Path.h): native slashes, repeated slashes removed after
/// the leading ones, and "./" in front of a relative path.
fn normalizePath(a: std.mem.Allocator, path: []const u8) ![]u8 {
    const to: u8 = if (windows) '\\' else '/';
    const from: u8 = if (windows) '/' else '\\';
    var out: std.ArrayList(u8) = .empty;
    const relative = !isAbsoluteOrCurDirRelative(path);
    if (relative) try out.appendSlice(a, &.{ '.', to });
    var seen_non_slash = relative;
    for (path) |c0| {
        const c = if (c0 == from) to else c0;
        if (c == to and out.items.len > 0 and out.items[out.items.len - 1] == to and seen_non_slash) continue;
        seen_non_slash = seen_non_slash or c != to;
        try out.append(a, c);
    }
    return out.toOwnedSlice(a);
}

fn isAbsoluteOrCurDirRelative(p: []const u8) bool {
    if (p.len == 1 and p[0] == '.') return true;
    if (p.len >= 2 and p[0] == '.' and (p[1] == '/' or p[1] == '\\')) return true;
    if (p.len >= 3 and p[1] == ':' and (p[2] == '\\' or p[2] == '/')) return true;
    if (p.len >= 2 and p[0] == '\\') return p[1] == '\\';
    if (!windows and p.len >= 1 and p[0] == '/') return true;
    return false;
}

// ---- Include handlers -----------------------------------------------------

const IncludeHandlerVtbl = extern struct {
    unknown: UnknownVtbl,
    LoadSource: *const fn (This, ?[*:0]const WCHAR, ?Out) callconv(cc) HRESULT,
};

/// IDxcUtils::CreateDefaultIncludeHandler's handler: reads from disk.
const DiskHandler = struct {
    iface: Iface(IncludeHandlerVtbl) = .{ .vtbl = &vtbl },
    rc: RefCount = .{},

    const vtbl: IncludeHandlerVtbl = .{
        .unknown = .{ .QueryInterface = queryInterface, .AddRef = addRef, .Release = release },
        .LoadSource = loadSource,
    };

    fn of(this: This) *DiskHandler {
        return parent(DiskHandler, "iface", this);
    }

    fn queryInterface(this: This, iid: *const GUID, out: ?Out) callconv(cc) HRESULT {
        if (!iid.eql(IID_IUnknown) and !iid.eql(IID_IDxcIncludeHandler)) {
            _ = put(out, null);
            return E_NOINTERFACE;
        }
        _ = of(this).rc.addRef();
        return put(out, this);
    }

    fn addRef(this: This) callconv(cc) ULONG {
        return of(this).rc.addRef();
    }

    fn release(this: This) callconv(cc) ULONG {
        const h = of(this);
        const n = h.rc.release();
        if (n == 0) gpa.destroy(h);
        return n;
    }

    fn loadSource(_: This, name: ?[*:0]const WCHAR, out: ?Out) callconv(cc) HRESULT {
        const o = out orelse return E_POINTER;
        o.* = null;
        const path = fromWide(gpa, name orelse return E_INVALIDARG) catch return E_INVALIDARG;
        defer gpa.free(path);
        const bytes = readDisk(gpa, path) orelse return FILE_NOT_FOUND;
        const b = Blob.create(.encoded, bytes, true, CP_ACP) catch return E_OUTOFMEMORY;
        o.* = b.ptr();
        return S_OK;
    }
};

fn readDisk(a: std.mem.Allocator, path: []const u8) ?[]u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, a, .limited(256 << 20)) catch null;
}

/// A client's IDxcIncludeHandler as the compiler's file system.
const ClientFs = struct {
    handler: *anyopaque,

    fn fileSystem(c: *ClientFs) FileSystem {
        return .{ .ctx = c, .readFn = read };
    }

    fn read(ctx: *anyopaque, a: std.mem.Allocator, path: []const u8) ?[]const u8 {
        const c: *ClientFs = @ptrCast(@alignCast(ctx));
        const name = normalizePath(a, path) catch return null;
        const w = toWide(a, name) catch return null;
        const v = vtblOf(IncludeHandlerVtbl, c.handler);
        var blob: ?*anyopaque = null;
        if (v.LoadSource(c.handler, w.ptr, &blob) != S_OK) {
            if (blob) |b| releaseUnknown(b);
            return null;
        }
        const b = blob orelse return null;
        defer releaseUnknown(b);
        const text = decodeText(a, blobBytes(b), CP_ACP) catch return null;
        return a.dupe(u8, text) catch null;
    }
};

/// No include handler: nothing but the main file resolves (DXC never
/// touches the disk on its own).
const NoFs = struct {
    fn fileSystem() FileSystem {
        return .{ .ctx = undefined, .readFn = read };
    }
    fn read(_: *anyopaque, _: std.mem.Allocator, _: []const u8) ?[]const u8 {
        return null;
    }
};

// ---- Results --------------------------------------------------------------

const ResultVtbl = extern struct {
    unknown: UnknownVtbl,
    GetStatus: *const fn (This, ?*HRESULT) callconv(cc) HRESULT,
    GetResult: *const fn (This, ?Out) callconv(cc) HRESULT,
    GetErrorBuffer: *const fn (This, ?Out) callconv(cc) HRESULT,
    HasOutput: *const fn (This, OutKind) callconv(cc) BOOL,
    GetOutput: *const fn (This, OutKind, *const GUID, ?Out, ?Out) callconv(cc) HRESULT,
    GetNumOutputs: *const fn (This) callconv(cc) u32,
    GetOutputByIndex: *const fn (This, u32) callconv(cc) OutKind,
    PrimaryOutput: *const fn (This) callconv(cc) OutKind,
};

const Output = struct { kind: OutKind, blob: *Blob, name: ?*Blob = null };

const Result = struct {
    iface: Iface(ResultVtbl) = .{ .vtbl = &vtbl },
    rc: RefCount = .{},
    status: HRESULT,
    primary: OutKind,
    outputs: std.ArrayList(Output) = .empty,

    const vtbl: ResultVtbl = .{
        .unknown = .{ .QueryInterface = queryInterface, .AddRef = addRef, .Release = release },
        .GetStatus = getStatus,
        .GetResult = getResult,
        .GetErrorBuffer = getErrorBuffer,
        .HasOutput = hasOutput,
        .GetOutput = getOutput,
        .GetNumOutputs = getNumOutputs,
        .GetOutputByIndex = getOutputByIndex,
        .PrimaryOutput = primaryOutput,
    };

    fn of(this: This) *Result {
        return parent(Result, "iface", this);
    }

    fn destroy(r: *Result) void {
        for (r.outputs.items) |o| {
            _ = Blob.release(o.blob.ptr());
            if (o.name) |n| _ = Blob.release(n.ptr());
        }
        r.outputs.deinit(gpa);
        gpa.destroy(r);
    }

    fn find(r: *Result, kind: OutKind) ?Output {
        for (r.outputs.items) |o| if (o.kind == kind) return o;
        return null;
    }

    fn queryInterface(this: This, iid: *const GUID, out: ?Out) callconv(cc) HRESULT {
        if (!iid.eql(IID_IUnknown) and !iid.eql(IID_IDxcOperationResult) and !iid.eql(IID_IDxcResult)) {
            _ = put(out, null);
            return E_NOINTERFACE;
        }
        _ = of(this).rc.addRef();
        return put(out, this);
    }

    fn addRef(this: This) callconv(cc) ULONG {
        return of(this).rc.addRef();
    }

    fn release(this: This) callconv(cc) ULONG {
        const r = of(this);
        const n = r.rc.release();
        if (n == 0) r.destroy();
        return n;
    }

    fn getStatus(this: This, status: ?*HRESULT) callconv(cc) HRESULT {
        (status orelse return E_POINTER).* = of(this).status;
        return S_OK;
    }

    /// The primary output, or null.
    fn getResult(this: This, out: ?Out) callconv(cc) HRESULT {
        return putBlob(out, if (of(this).find(of(this).primary)) |o| o.blob else null);
    }

    fn getErrorBuffer(this: This, out: ?Out) callconv(cc) HRESULT {
        return putBlob(out, if (of(this).find(.errors)) |o| o.blob else null);
    }

    fn hasOutput(this: This, kind: OutKind) callconv(cc) BOOL {
        const has = of(this).find(kind) != null;
        return if (windows) @intFromBool(has) else has;
    }

    fn getOutput(this: This, kind: OutKind, iid: *const GUID, out: ?Out, name: ?Out) callconv(cc) HRESULT {
        if (out) |o| o.* = null;
        if (name) |n| n.* = null;
        const o = of(this).find(kind) orelse return E_INVALIDARG;
        if (out) |p| {
            const result = Blob.queryInterface(o.blob.ptr(), iid, p);
            if (result != S_OK) return result;
        }
        if (name) |n| if (o.name) |nb| {
            _ = nb.rc.addRef();
            n.* = nb.ptr();
        };
        return S_OK;
    }

    fn getNumOutputs(this: This) callconv(cc) u32 {
        return @intCast(of(this).outputs.items.len);
    }

    fn getOutputByIndex(this: This, index: u32) callconv(cc) OutKind {
        const r = of(this);
        return if (index < r.outputs.items.len) r.outputs.items[index].kind else .none;
    }

    fn primaryOutput(this: This) callconv(cc) OutKind {
        return of(this).primary;
    }
};

fn putBlob(out: ?Out, blob: ?*Blob) HRESULT {
    const o = out orelse return E_POINTER;
    if (blob) |b| {
        _ = b.rc.addRef();
        o.* = b.ptr();
    } else o.* = null;
    return S_OK;
}

/// A compilation's outputs, shaped as DXC shapes them: an option error
/// leaves only ERRORS (status E_INVALIDARG); a compile error leaves an
/// empty OBJECT, ERRORS and REMARKS (E_FAIL); a success adds the object or
/// the -P text, and for DXIL the shader hash.
fn makeResult(c: compile.Result) !*Result {
    const r = try gpa.create(Result);
    r.* = .{ .status = S_OK, .primary = .object };
    errdefer r.destroy();
    switch (c.status) {
        .failed => {
            r.status = E_INVALIDARG;
            r.primary = .none;
            try addOutput(r, .errors, try Blob.utf8(c.diagnostics), null);
            return r;
        },
        .compile_failed => {
            r.status = E_FAIL;
            try addOutput(r, .object, try Blob.copy(.binary, "", CP_ACP), null);
        },
        .ok => if (c.preprocessed) |text| {
            r.primary = .hlsl;
            try addOutput(r, .hlsl, try Blob.utf8(text), c.preprocessed_name);
        } else if (c.object) |obj| {
            try addOutput(r, .object, try Blob.copy(.binary, obj, CP_ACP), c.object_name);
            if (shaderHash(obj)) |h| try addOutput(r, .shader_hash, try Blob.copy(.binary, &h, CP_ACP), null);
            if (c.reflection) |refl| try addOutput(r, .reflection, try Blob.copy(.binary, refl, CP_ACP), null);
        } else {
            r.primary = .text;
        },
    }
    try addOutput(r, .errors, try Blob.utf8(c.diagnostics), null);
    if (c.root_signature) |rs| try addOutput(r, .root_signature, try Blob.copy(.binary, rs, CP_ACP), c.root_signature_name);
    if (c.text.len > 0) try addOutput(r, .text, try Blob.utf8(c.text), null);
    try addOutput(r, .remarks, try Blob.utf8(""), null);
    std.mem.sortUnstable(Output, r.outputs.items, {}, struct {
        fn lt(_: void, x: Output, y: Output) bool {
            return @backingInt(x.kind) < @backingInt(y.kind);
        }
    }.lt);
    return r;
}

fn addOutput(r: *Result, kind: OutKind, blob: *Blob, name: ?[]const u8) !void {
    errdefer _ = Blob.release(blob.ptr());
    const n = if (name) |s| try Blob.wide(s) else null;
    errdefer if (n) |b| {
        _ = Blob.release(b.ptr());
    };
    try r.outputs.append(gpa, .{ .kind = kind, .blob = blob, .name = n });
}

/// A DXIL container's DxcShaderHash (flags, then digest): its HASH part,
/// or, as DXC computes that part, flags 0 and the MD5 of the DXIL part's
/// bitcode.
fn shaderHash(obj: []const u8) ?[20]u8 {
    var h: [20]u8 = undefined;
    if (containerPart(obj, fourCC("HASH"))) |part| {
        if (part.len != h.len) return null;
        @memcpy(&h, part);
        return h;
    }
    // DxilProgramHeader: version, size in dwords, then DxilBitcodeHeader:
    // magic, version, offset (from the magic), size.
    const program = containerPart(obj, fourCC("DXIL")) orelse return null;
    if (program.len < 24) return null;
    const offset = std.mem.readInt(u32, program[16..20], .little);
    const size = std.mem.readInt(u32, program[20..24], .little);
    if (offset > program.len - 8 or size > program.len - 8 - offset) return null;
    @memset(h[0..4], 0);
    std.crypto.hash.Md5.hash(program[8 + offset ..][0..size], h[4..20], .{});
    return h;
}

fn fourCC(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .little);
}

/// A part of a DXIL container, in place.
fn containerPart(obj: []const u8, fourcc: u32) ?[]const u8 {
    if (obj.len < 32 or !std.mem.eql(u8, obj[0..4], "DXBC")) return null;
    const count = std.mem.readInt(u32, obj[28..32], .little);
    if (count > (obj.len - 32) / 4) return null;
    for (0..count) |i| {
        const at = std.mem.readInt(u32, obj[32 + 4 * i ..][0..4], .little);
        if (at > obj.len - 8) return null;
        const size = std.mem.readInt(u32, obj[at + 4 ..][0..4], .little);
        if (size > obj.len - at - 8) return null;
        if (std.mem.readInt(u32, obj[at..][0..4], .little) == fourcc) return obj[at + 8 ..][0..size];
    }
    return null;
}

// ---- The compiler ---------------------------------------------------------

const Compiler3Vtbl = extern struct {
    unknown: UnknownVtbl,
    Compile: *const fn (This, ?*const Buffer, ?[*]const ?[*:0]const WCHAR, u32, ?*anyopaque, *const GUID, ?Out) callconv(cc) HRESULT,
    Disassemble: *const fn (This, ?*const Buffer, *const GUID, ?Out) callconv(cc) HRESULT,
};

const VersionInfoVtbl = extern struct {
    unknown: UnknownVtbl,
    GetVersion: *const fn (This, ?*u32, ?*u32) callconv(cc) HRESULT,
    GetFlags: *const fn (This, ?*u32) callconv(cc) HRESULT,
};

const Compiler = struct {
    compiler: Iface(Compiler3Vtbl) = .{ .vtbl = &compiler_vtbl },
    version: Iface(VersionInfoVtbl) = .{ .vtbl = &version_vtbl },
    rc: RefCount = .{},

    const compiler_vtbl: Compiler3Vtbl = .{
        .unknown = .{ .QueryInterface = queryInterface, .AddRef = addRef, .Release = release },
        .Compile = compileFn,
        .Disassemble = disassemble,
    };
    const version_vtbl: VersionInfoVtbl = .{
        .unknown = .{ .QueryInterface = versionQueryInterface, .AddRef = versionAddRef, .Release = versionRelease },
        .GetVersion = getVersion,
        .GetFlags = getFlags,
    };

    fn of(this: This) *Compiler {
        return parent(Compiler, "compiler", this);
    }

    fn query(c: *Compiler, iid: *const GUID, out: ?Out) HRESULT {
        const p: ?*anyopaque = if (iid.eql(IID_IUnknown) or iid.eql(IID_IDxcCompiler3))
            &c.compiler
        else if (iid.eql(IID_IDxcVersionInfo))
            &c.version
        else
            null;
        if (p == null) {
            _ = put(out, null);
            return E_NOINTERFACE;
        }
        _ = c.rc.addRef();
        return put(out, p);
    }

    fn queryInterface(this: This, iid: *const GUID, out: ?Out) callconv(cc) HRESULT {
        return of(this).query(iid, out);
    }
    fn addRef(this: This) callconv(cc) ULONG {
        return of(this).rc.addRef();
    }
    fn release(this: This) callconv(cc) ULONG {
        const c = of(this);
        const n = c.rc.release();
        if (n == 0) gpa.destroy(c);
        return n;
    }
    fn versionOf(this: This) *Compiler {
        return parent(Compiler, "version", this);
    }
    fn versionQueryInterface(this: This, iid: *const GUID, out: ?Out) callconv(cc) HRESULT {
        return versionOf(this).query(iid, out);
    }
    fn versionAddRef(this: This) callconv(cc) ULONG {
        return versionOf(this).rc.addRef();
    }
    fn versionRelease(this: This) callconv(cc) ULONG {
        return release(&versionOf(this).compiler);
    }

    fn getVersion(_: This, major: ?*u32, minor: ?*u32) callconv(cc) HRESULT {
        (major orelse return E_POINTER).* = version_major;
        (minor orelse return E_POINTER).* = version_minor;
        return S_OK;
    }

    fn getFlags(_: This, flags: ?*u32) callconv(cc) HRESULT {
        (flags orelse return E_POINTER).* = 0;
        return S_OK;
    }

    fn compileFn(_: This, source: ?*const Buffer, args: ?[*]const ?[*:0]const WCHAR, count: u32, include: ?*anyopaque, iid: *const GUID, out: ?Out) callconv(cc) HRESULT {
        const o = out orelse return E_POINTER;
        o.* = null;
        if (!iid.eql(IID_IDxcResult) and !iid.eql(IID_IDxcOperationResult)) return E_INVALIDARG;
        const src = source orelse return E_INVALIDARG;
        if (count > 0 and args == null) return E_INVALIDARG;
        const r = run(src, if (args) |a| a[0..count] else &.{}, include) catch |e| return switch (e) {
            error.OutOfMemory => E_OUTOFMEMORY,
            error.InvalidArgument => E_INVALIDARG,
        };
        o.* = &r.iface;
        return S_OK;
    }

    fn disassemble(_: This, _: ?*const Buffer, _: *const GUID, out: ?Out) callconv(cc) HRESULT {
        _ = put(out, null);
        return E_NOTIMPL;
    }
};

/// Each thread's compile arena, kept between calls. Freeing it per call
/// gives its blocks back to the OS (smp_allocator maps 64 KiB and up
/// directly), and faulting fresh pages in again costs more than the compile
/// on many threads. What a thread keeps is capped at `retain_limit`.
threadlocal var thread_arena: ?BumpArena = null;
const retain_limit = 64 << 20;

fn run(source: *const Buffer, wargs: []const ?[*:0]const WCHAR, include: ?*anyopaque) error{ OutOfMemory, InvalidArgument }!*Result {
    if (thread_arena == null) thread_arena = .init(gpa);
    const arena = &thread_arena.?;
    defer _ = arena.reset(.{ .retain_with_limit = retain_limit });
    const a = arena.allocator();
    const args = try a.alloc([]const u8, wargs.len);
    for (args, wargs) |*d, w| d.* = try fromWide(a, w orelse return error.InvalidArgument);
    const bytes: []const u8 = if (source.ptr) |p| p[0..source.size] else &.{};
    var client: ClientFs = undefined;
    var threaded: std.Io.Threaded = .init_single_threaded;
    var req: compile.Request = .{
        .args = args,
        .source = try decodeText(a, bytes, source.encoding),
        .io = threaded.io(),
        .fs = NoFs.fileSystem(),
        .compat_notes = false,
    };
    if (include) |h| {
        // Our own disk handler reads directly; a client's is called with
        // DXC's path spellings.
        const v = vtblOf(IncludeHandlerVtbl, h);
        if (v == &DiskHandler.vtbl) {
            req.fs = null;
        } else {
            client = .{ .handler = h };
            req.fs = client.fileSystem();
        }
    }
    const c = try compile.compile(a, req);
    return makeResult(c);
}

// ---- Utils ----------------------------------------------------------------

const UtilsVtbl = extern struct {
    unknown: UnknownVtbl,
    CreateBlobFromBlob: *const fn (This, ?*anyopaque, u32, u32, ?Out) callconv(cc) HRESULT,
    CreateBlobFromPinned: *const fn (This, ?[*]const u8, u32, u32, ?Out) callconv(cc) HRESULT,
    MoveToBlob: *const fn (This, ?[*]const u8, ?*anyopaque, u32, u32, ?Out) callconv(cc) HRESULT,
    CreateBlob: *const fn (This, ?[*]const u8, u32, u32, ?Out) callconv(cc) HRESULT,
    LoadFile: *const fn (This, ?[*:0]const WCHAR, ?*u32, ?Out) callconv(cc) HRESULT,
    CreateReadOnlyStreamFromBlob: *const fn (This, ?*anyopaque, ?Out) callconv(cc) HRESULT,
    CreateDefaultIncludeHandler: *const fn (This, ?Out) callconv(cc) HRESULT,
    GetBlobAsUtf8: *const fn (This, ?*anyopaque, ?Out) callconv(cc) HRESULT,
    GetBlobAsWide: *const fn (This, ?*anyopaque, ?Out) callconv(cc) HRESULT,
    GetDxilContainerPart: *const fn (This, ?*const Buffer, u32, ?*?*const anyopaque, ?*u32) callconv(cc) HRESULT,
    CreateReflection: *const fn (This, ?*const Buffer, *const GUID, ?Out) callconv(cc) HRESULT,
    BuildArguments: *const fn (This) callconv(cc) HRESULT,
    GetPDBContents: *const fn (This, ?*anyopaque, ?Out, ?Out) callconv(cc) HRESULT,
};

/// IMalloc, for MoveToBlob.
const MallocVtbl = extern struct {
    unknown: UnknownVtbl,
    Alloc: *const fn (This, usize) callconv(cc) ?*anyopaque,
    Realloc: *const fn (This, ?*anyopaque, usize) callconv(cc) ?*anyopaque,
    Free: *const fn (This, ?*anyopaque) callconv(cc) void,
};

/// IDxcLibrary: the older blob helpers on the same object.
const LibraryVtbl = extern struct {
    unknown: UnknownVtbl,
    SetMalloc: *const fn (This, ?*anyopaque) callconv(cc) HRESULT,
    CreateBlobFromBlob: *const fn (This, ?*anyopaque, u32, u32, ?Out) callconv(cc) HRESULT,
    CreateBlobFromFile: *const fn (This, ?[*:0]const WCHAR, ?*u32, ?Out) callconv(cc) HRESULT,
    CreateBlobWithEncodingFromPinned: *const fn (This, ?[*]const u8, u32, u32, ?Out) callconv(cc) HRESULT,
    CreateBlobWithEncodingOnHeapCopy: *const fn (This, ?[*]const u8, u32, u32, ?Out) callconv(cc) HRESULT,
    CreateBlobWithEncodingOnMalloc: *const fn (This, ?[*]const u8, ?*anyopaque, u32, u32, ?Out) callconv(cc) HRESULT,
    CreateIncludeHandler: *const fn (This, ?Out) callconv(cc) HRESULT,
    CreateStreamFromBlobReadOnly: *const fn (This, ?*anyopaque, ?Out) callconv(cc) HRESULT,
    GetBlobAsUtf8: *const fn (This, ?*anyopaque, ?Out) callconv(cc) HRESULT,
    GetBlobAsUtf16: *const fn (This, ?*anyopaque, ?Out) callconv(cc) HRESULT,
};

const Utils = struct {
    iface: Iface(UtilsVtbl) = .{ .vtbl = &vtbl },
    library: Iface(LibraryVtbl) = .{ .vtbl = &library_vtbl },
    rc: RefCount = .{},

    const library_vtbl: LibraryVtbl = .{
        .unknown = .{ .QueryInterface = libraryQueryInterface, .AddRef = libraryAddRef, .Release = libraryRelease },
        .SetMalloc = setMalloc,
        .CreateBlobFromBlob = createBlobFromBlob,
        .CreateBlobFromFile = loadFile,
        .CreateBlobWithEncodingFromPinned = createBlobFromPinned,
        .CreateBlobWithEncodingOnHeapCopy = createBlob,
        .CreateBlobWithEncodingOnMalloc = moveToBlob,
        .CreateIncludeHandler = createDefaultIncludeHandler,
        .CreateStreamFromBlobReadOnly = notImplemented2,
        .GetBlobAsUtf8 = getBlobAsUtf8,
        .GetBlobAsUtf16 = getBlobAsWide,
    };

    fn libraryOf(this: This) *Utils {
        return parent(Utils, "library", this);
    }
    fn libraryQueryInterface(this: This, iid: *const GUID, out: ?Out) callconv(cc) HRESULT {
        return queryInterface(&libraryOf(this).iface, iid, out);
    }
    fn libraryAddRef(this: This) callconv(cc) ULONG {
        return libraryOf(this).rc.addRef();
    }
    fn libraryRelease(this: This) callconv(cc) ULONG {
        return release(&libraryOf(this).iface);
    }
    fn setMalloc(_: This, _: ?*anyopaque) callconv(cc) HRESULT {
        return S_OK;
    }

    const vtbl: UtilsVtbl = .{
        .unknown = .{ .QueryInterface = queryInterface, .AddRef = addRef, .Release = release },
        .CreateBlobFromBlob = createBlobFromBlob,
        .CreateBlobFromPinned = createBlobFromPinned,
        .MoveToBlob = moveToBlob,
        .CreateBlob = createBlob,
        .LoadFile = loadFile,
        .CreateReadOnlyStreamFromBlob = notImplemented2,
        .CreateDefaultIncludeHandler = createDefaultIncludeHandler,
        .GetBlobAsUtf8 = getBlobAsUtf8,
        .GetBlobAsWide = getBlobAsWide,
        .GetDxilContainerPart = getDxilContainerPart,
        .CreateReflection = createReflection,
        .BuildArguments = notImplemented0,
        .GetPDBContents = getPdbContents,
    };

    fn of(this: This) *Utils {
        return parent(Utils, "iface", this);
    }

    fn queryInterface(this: This, iid: *const GUID, out: ?Out) callconv(cc) HRESULT {
        const u = of(this);
        const p: *anyopaque = if (iid.eql(IID_IUnknown) or iid.eql(IID_IDxcUtils))
            &u.iface
        else if (iid.eql(IID_IDxcLibrary))
            &u.library
        else {
            _ = put(out, null);
            return E_NOINTERFACE;
        };
        _ = u.rc.addRef();
        return put(out, p);
    }
    fn addRef(this: This) callconv(cc) ULONG {
        return of(this).rc.addRef();
    }
    fn release(this: This) callconv(cc) ULONG {
        const u = of(this);
        const n = u.rc.release();
        if (n == 0) gpa.destroy(u);
        return n;
    }

    fn give(out: ?Out, blob: anyerror!*Blob) HRESULT {
        const o = out orelse return E_POINTER;
        o.* = null;
        const b = blob catch |e| return if (e == error.OutOfMemory) E_OUTOFMEMORY else E_INVALIDARG;
        o.* = b.ptr();
        return S_OK;
    }

    fn createBlobFromBlob(_: This, blob: ?*anyopaque, offset: u32, length: u32, out: ?Out) callconv(cc) HRESULT {
        const bytes = blobBytes(blob orelse return E_INVALIDARG);
        if (@as(u64, offset) + length > bytes.len) return E_INVALIDARG;
        return give(out, Blob.copy(.binary, bytes[offset..][0..length], CP_ACP));
    }

    fn createBlobFromPinned(_: This, data: ?[*]const u8, size: u32, code_page: u32, out: ?Out) callconv(cc) HRESULT {
        const bytes: []const u8 = if (data) |d| d[0..size] else &.{};
        return give(out, Blob.create(.encoded, bytes, false, code_page));
    }

    fn moveToBlob(_: This, data: ?[*]const u8, malloc: ?*anyopaque, size: u32, code_page: u32, out: ?Out) callconv(cc) HRESULT {
        const bytes: []const u8 = if (data) |d| d[0..size] else &.{};
        const result = give(out, Blob.copy(.encoded, bytes, code_page));
        // The blob owns the data now; it keeps a copy.
        if (result == S_OK) if (malloc) |m| if (data) |d| {
            const v = vtblOf(MallocVtbl, m);
            v.Free(m, @constCast(d));
        };
        return result;
    }

    fn createBlob(_: This, data: ?[*]const u8, size: u32, code_page: u32, out: ?Out) callconv(cc) HRESULT {
        const bytes: []const u8 = if (data) |d| d[0..size] else &.{};
        return give(out, Blob.copy(.encoded, bytes, code_page));
    }

    fn loadFile(_: This, name: ?[*:0]const WCHAR, code_page: ?*u32, out: ?Out) callconv(cc) HRESULT {
        const o = out orelse return E_POINTER;
        o.* = null;
        const path = fromWide(gpa, name orelse return E_INVALIDARG) catch return E_INVALIDARG;
        defer gpa.free(path);
        const bytes = readDisk(gpa, path) orelse return FILE_NOT_FOUND;
        const b = Blob.create(.encoded, bytes, true, if (code_page) |c| c.* else CP_ACP) catch return E_OUTOFMEMORY;
        o.* = b.ptr();
        return S_OK;
    }

    fn createDefaultIncludeHandler(_: This, out: ?Out) callconv(cc) HRESULT {
        const o = out orelse return E_POINTER;
        const h = gpa.create(DiskHandler) catch {
            o.* = null;
            return E_OUTOFMEMORY;
        };
        h.* = .{};
        o.* = &h.iface;
        return S_OK;
    }

    /// A blob's text as UTF-8, by its encoding when it is one of ours.
    fn blobText(a: std.mem.Allocator, blob: *anyopaque) ![]const u8 {
        const v = vtblOf(BlobVtbl, blob);
        var cp: u32 = CP_ACP;
        if (v == &Blob.vtbl) {
            const b = Blob.of(blob);
            cp = b.code_page;
            if (b.kind == .utf8) return a.dupe(u8, b.bytes[0..b.textLen()]);
            if (b.kind == .wide) cp = CP_WIDE;
        }
        return decodeText(a, blobBytes(blob), cp);
    }

    fn getBlobAsUtf8(_: This, blob: ?*anyopaque, out: ?Out) callconv(cc) HRESULT {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const text = blobText(arena.allocator(), blob orelse return E_INVALIDARG) catch |e| return give(out, e);
        return give(out, Blob.utf8(text));
    }

    fn getBlobAsWide(_: This, blob: ?*anyopaque, out: ?Out) callconv(cc) HRESULT {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const text = blobText(arena.allocator(), blob orelse return E_INVALIDARG) catch |e| return give(out, e);
        return give(out, Blob.wide(text));
    }

    fn getDxilContainerPart(_: This, shader: ?*const Buffer, fourcc: u32, data: ?*?*const anyopaque, size: ?*u32) callconv(cc) HRESULT {
        const d = data orelse return E_POINTER;
        const s = size orelse return E_POINTER;
        d.* = null;
        s.* = 0;
        const buf = shader orelse return E_INVALIDARG;
        const bytes = (buf.ptr orelse return E_INVALIDARG)[0..buf.size];
        if (bytes.len < 32 or !std.mem.eql(u8, bytes[0..4], "DXBC")) return E_INVALIDARG;
        const part = containerPart(bytes, fourcc) orelse return E_FAIL;
        d.* = part.ptr;
        s.* = @intCast(part.len);
        return S_OK;
    }

    /// ID3D12ShaderReflection / ID3D12LibraryReflection over a
    /// DXC_OUT_REFLECTION blob of ours.
    fn createReflection(_: This, data: ?*const Buffer, iid: *const GUID, out: ?Out) callconv(cc) HRESULT {
        const o = out orelse return E_POINTER;
        o.* = null;
        const buf = data orelse return E_INVALIDARG;
        const bytes = (buf.ptr orelse return E_INVALIDARG)[0..buf.size];
        const r = ShaderReflection.create(bytes) catch |e| return switch (e) {
            error.OutOfMemory => E_OUTOFMEMORY,
            else => E_INVALIDARG,
        };
        defer _ = ShaderReflection.release(&r.shader);
        return r.query(iid, o);
    }

    fn getPdbContents(_: This, _: ?*anyopaque, hash: ?Out, container: ?Out) callconv(cc) HRESULT {
        _ = put(hash, null);
        _ = put(container, null);
        return E_NOTIMPL;
    }

    fn notImplemented0(_: This) callconv(cc) HRESULT {
        return E_NOTIMPL;
    }

    fn notImplemented2(_: This, _: ?*anyopaque, out: ?Out) callconv(cc) HRESULT {
        _ = put(out, null);
        return E_NOTIMPL;
    }
};

// ---- Shader reflection ----------------------------------------------------
//
// ID3D12ShaderReflection and ID3D12LibraryReflection (d3d12shader.h) over
// the reflection blob zdxc returns as DXC_OUT_REFLECTION (dxil/reflect.zig).
// Their constant buffer, variable, type and function objects are not
// IUnknowns: they live as long as the reflection object. A lookup that
// finds nothing returns an object whose GetDesc fails, as D3D's do.

const reflect = zdxc.dxil.reflect;
const LPCSTR = ?[*:0]const u8;

const ShaderDesc = extern struct {
    Version: u32 = 0,
    Creator: LPCSTR = null,
    Flags: u32 = 0,
    ConstantBuffers: u32 = 0,
    BoundResources: u32 = 0,
    InputParameters: u32 = 0,
    OutputParameters: u32 = 0,
    InstructionCount: u32 = 0,
    TempRegisterCount: u32 = 0,
    TempArrayCount: u32 = 0,
    DefCount: u32 = 0,
    DclCount: u32 = 0,
    TextureNormalInstructions: u32 = 0,
    TextureLoadInstructions: u32 = 0,
    TextureCompInstructions: u32 = 0,
    TextureBiasInstructions: u32 = 0,
    TextureGradientInstructions: u32 = 0,
    FloatInstructionCount: u32 = 0,
    IntInstructionCount: u32 = 0,
    UintInstructionCount: u32 = 0,
    StaticFlowControlCount: u32 = 0,
    DynamicFlowControlCount: u32 = 0,
    MacroInstructionCount: u32 = 0,
    ArrayInstructionCount: u32 = 0,
    CutInstructionCount: u32 = 0,
    EmitInstructionCount: u32 = 0,
    GSOutputTopology: u32 = 0,
    GSMaxOutputVertexCount: u32 = 0,
    InputPrimitive: u32 = 0,
    PatchConstantParameters: u32 = 0,
    cGSInstanceCount: u32 = 0,
    cControlPoints: u32 = 0,
    HSOutputPrimitive: u32 = 0,
    HSPartitioning: u32 = 0,
    TessellatorDomain: u32 = 0,
    cBarrierInstructions: u32 = 0,
    cInterlockedInstructions: u32 = 0,
    cTextureStoreInstructions: u32 = 0,
};

const BufferDesc = extern struct { Name: LPCSTR = null, Type: u32 = 0, Variables: u32 = 0, Size: u32 = 0, uFlags: u32 = 0 };

const VariableDesc = extern struct {
    Name: LPCSTR = null,
    StartOffset: u32 = 0,
    Size: u32 = 0,
    uFlags: u32 = 0,
    DefaultValue: ?*anyopaque = null,
    StartTexture: u32 = 0xFFFFFFFF,
    TextureSize: u32 = 0,
    StartSampler: u32 = 0xFFFFFFFF,
    SamplerSize: u32 = 0,
};

const TypeDesc = extern struct { Class: u32 = 0, Type: u32 = 0, Rows: u32 = 0, Columns: u32 = 0, Elements: u32 = 0, Members: u32 = 0, Offset: u32 = 0, Name: LPCSTR = null };

const BindDesc = extern struct { Name: LPCSTR = null, Type: u32 = 0, BindPoint: u32 = 0, BindCount: u32 = 0, uFlags: u32 = 0, ReturnType: u32 = 0, Dimension: u32 = 0, NumSamples: u32 = 0, Space: u32 = 0, uID: u32 = 0 };

const SignatureParamDesc = extern struct { SemanticName: LPCSTR = null, SemanticIndex: u32 = 0, Register: u32 = 0, SystemValueType: u32 = 0, ComponentType: u32 = 0, Mask: u8 = 0, ReadWriteMask: u8 = 0, Stream: u32 = 0, MinPrecision: u32 = 0 };

const LibraryDesc = extern struct { Creator: LPCSTR = null, Flags: u32 = 0, FunctionCount: u32 = 0 };

const FunctionDesc = extern struct {
    Version: u32 = 0,
    Creator: LPCSTR = null,
    Flags: u32 = 0,
    ConstantBuffers: u32 = 0,
    BoundResources: u32 = 0,
    InstructionCount: u32 = 0,
    TempRegisterCount: u32 = 0,
    TempArrayCount: u32 = 0,
    DefCount: u32 = 0,
    DclCount: u32 = 0,
    TextureNormalInstructions: u32 = 0,
    TextureLoadInstructions: u32 = 0,
    TextureCompInstructions: u32 = 0,
    TextureBiasInstructions: u32 = 0,
    TextureGradientInstructions: u32 = 0,
    FloatInstructionCount: u32 = 0,
    IntInstructionCount: u32 = 0,
    UintInstructionCount: u32 = 0,
    StaticFlowControlCount: u32 = 0,
    DynamicFlowControlCount: u32 = 0,
    MacroInstructionCount: u32 = 0,
    ArrayInstructionCount: u32 = 0,
    MovInstructionCount: u32 = 0,
    MovcInstructionCount: u32 = 0,
    ConversionInstructionCount: u32 = 0,
    BitwiseInstructionCount: u32 = 0,
    MinFeatureLevel: u32 = 0,
    RequiredFeatureFlags: u64 = 0,
    Name: LPCSTR = null,
    FunctionParameterCount: i32 = 0,
    HasReturn: i32 = 0,
    Has10Level9VertexShader: i32 = 0,
    Has10Level9PixelShader: i32 = 0,
};

const creator: [*:0]const u8 = "zdxc";
/// D3D_FEATURE_LEVEL_12_0.
const feature_level_12_0 = 0xc000;

const CBufferVtbl = extern struct {
    GetDesc: *const fn (This, ?*BufferDesc) callconv(cc) HRESULT,
    GetVariableByIndex: *const fn (This, u32) callconv(cc) *anyopaque,
    GetVariableByName: *const fn (This, LPCSTR) callconv(cc) *anyopaque,
};

const VariableVtbl = extern struct {
    GetDesc: *const fn (This, ?*VariableDesc) callconv(cc) HRESULT,
    GetType: *const fn (This) callconv(cc) *anyopaque,
    GetBuffer: *const fn (This) callconv(cc) *anyopaque,
    GetInterfaceSlot: *const fn (This, u32) callconv(cc) u32,
};

const TypeVtbl = extern struct {
    GetDesc: *const fn (This, ?*TypeDesc) callconv(cc) HRESULT,
    GetMemberTypeByIndex: *const fn (This, u32) callconv(cc) *anyopaque,
    GetMemberTypeByName: *const fn (This, LPCSTR) callconv(cc) *anyopaque,
    GetMemberTypeName: *const fn (This, u32) callconv(cc) LPCSTR,
    IsEqual: *const fn (This, ?*anyopaque) callconv(cc) HRESULT,
    GetSubType: *const fn (This) callconv(cc) ?*anyopaque,
    GetBaseClass: *const fn (This) callconv(cc) ?*anyopaque,
    GetNumInterfaces: *const fn (This) callconv(cc) u32,
    GetInterfaceByIndex: *const fn (This, u32) callconv(cc) ?*anyopaque,
    IsOfType: *const fn (This, ?*anyopaque) callconv(cc) HRESULT,
    ImplementsInterface: *const fn (This, ?*anyopaque) callconv(cc) HRESULT,
};

const ShaderReflectionVtbl = extern struct {
    unknown: UnknownVtbl,
    GetDesc: *const fn (This, ?*ShaderDesc) callconv(cc) HRESULT,
    GetConstantBufferByIndex: *const fn (This, u32) callconv(cc) *anyopaque,
    GetConstantBufferByName: *const fn (This, LPCSTR) callconv(cc) *anyopaque,
    GetResourceBindingDesc: *const fn (This, u32, ?*BindDesc) callconv(cc) HRESULT,
    GetInputParameterDesc: *const fn (This, u32, ?*SignatureParamDesc) callconv(cc) HRESULT,
    GetOutputParameterDesc: *const fn (This, u32, ?*SignatureParamDesc) callconv(cc) HRESULT,
    GetPatchConstantParameterDesc: *const fn (This, u32, ?*SignatureParamDesc) callconv(cc) HRESULT,
    GetVariableByName: *const fn (This, LPCSTR) callconv(cc) *anyopaque,
    GetResourceBindingDescByName: *const fn (This, LPCSTR, ?*BindDesc) callconv(cc) HRESULT,
    GetMovInstructionCount: *const fn (This) callconv(cc) u32,
    GetMovcInstructionCount: *const fn (This) callconv(cc) u32,
    GetConversionInstructionCount: *const fn (This) callconv(cc) u32,
    GetBitwiseInstructionCount: *const fn (This) callconv(cc) u32,
    GetGSInputPrimitive: *const fn (This) callconv(cc) u32,
    IsSampleFrequencyShader: *const fn (This) callconv(cc) BOOL,
    GetNumInterfaceSlots: *const fn (This) callconv(cc) u32,
    GetMinFeatureLevel: *const fn (This, ?*u32) callconv(cc) HRESULT,
    GetThreadGroupSize: *const fn (This, ?*u32, ?*u32, ?*u32) callconv(cc) u32,
    GetRequiresFlags: *const fn (This) callconv(cc) u64,
};

const LibraryReflectionVtbl = extern struct {
    unknown: UnknownVtbl,
    GetDesc: *const fn (This, ?*LibraryDesc) callconv(cc) HRESULT,
    GetFunctionByIndex: *const fn (This, i32) callconv(cc) *anyopaque,
};

const FunctionVtbl = extern struct {
    GetDesc: *const fn (This, ?*FunctionDesc) callconv(cc) HRESULT,
    GetConstantBufferByIndex: *const fn (This, u32) callconv(cc) *anyopaque,
    GetConstantBufferByName: *const fn (This, LPCSTR) callconv(cc) *anyopaque,
    GetResourceBindingDesc: *const fn (This, u32, ?*BindDesc) callconv(cc) HRESULT,
    GetVariableByName: *const fn (This, LPCSTR) callconv(cc) *anyopaque,
    GetResourceBindingDescByName: *const fn (This, LPCSTR, ?*BindDesc) callconv(cc) HRESULT,
    GetFunctionParameter: *const fn (This, i32) callconv(cc) *anyopaque,
};

const ParameterVtbl = extern struct {
    GetDesc: *const fn (This, ?*anyopaque) callconv(cc) HRESULT,
};

fn eqlZ(a: LPCSTR, b: [*:0]const u8) bool {
    return std.mem.eql(u8, std.mem.span(a orelse return false), std.mem.span(b));
}

/// A constant buffer of a reflection.
const CBufferObj = struct {
    iface: Iface(CBufferVtbl) = .{ .vtbl = &vtbl },
    desc: BufferDesc,
    vars: []VariableObj,

    const vtbl: CBufferVtbl = .{ .GetDesc = getDesc, .GetVariableByIndex = getVariableByIndex, .GetVariableByName = getVariableByName };
    fn of(this: This) *CBufferObj {
        return parent(CBufferObj, "iface", this);
    }
    fn getDesc(this: This, d: ?*BufferDesc) callconv(cc) HRESULT {
        const c = of(this);
        if (c == &invalid_cbuffer) return E_FAIL;
        (d orelse return E_INVALIDARG).* = c.desc;
        return S_OK;
    }
    fn getVariableByIndex(this: This, i: u32) callconv(cc) *anyopaque {
        const c = of(this);
        return if (i < c.vars.len) &c.vars[i].iface else &invalid_variable.iface;
    }
    fn getVariableByName(this: This, name: LPCSTR) callconv(cc) *anyopaque {
        for (of(this).vars) |*v| if (eqlZ(name, v.desc.Name.?)) return &v.iface;
        return &invalid_variable.iface;
    }
};

const VariableObj = struct {
    iface: Iface(VariableVtbl) = .{ .vtbl = &vtbl },
    desc: VariableDesc,
    ty: *TypeObj,
    buffer: *CBufferObj,

    const vtbl: VariableVtbl = .{ .GetDesc = getDesc, .GetType = getType, .GetBuffer = getBuffer, .GetInterfaceSlot = getInterfaceSlot };
    fn of(this: This) *VariableObj {
        return parent(VariableObj, "iface", this);
    }
    fn getDesc(this: This, d: ?*VariableDesc) callconv(cc) HRESULT {
        const v = of(this);
        if (v == &invalid_variable) return E_FAIL;
        (d orelse return E_INVALIDARG).* = v.desc;
        return S_OK;
    }
    fn getType(this: This) callconv(cc) *anyopaque {
        return &of(this).ty.iface;
    }
    fn getBuffer(this: This) callconv(cc) *anyopaque {
        return &of(this).buffer.iface;
    }
    fn getInterfaceSlot(_: This, _: u32) callconv(cc) u32 {
        return 0xFFFFFFFF;
    }
};

const TypeObj = struct {
    iface: Iface(TypeVtbl) = .{ .vtbl = &vtbl },
    desc: TypeDesc,
    members: []const *TypeObj = &.{},
    member_names: []const [*:0]const u8 = &.{},

    const vtbl: TypeVtbl = .{
        .GetDesc = getDesc,
        .GetMemberTypeByIndex = getMemberTypeByIndex,
        .GetMemberTypeByName = getMemberTypeByName,
        .GetMemberTypeName = getMemberTypeName,
        .IsEqual = isEqual,
        .GetSubType = getNull,
        .GetBaseClass = getNull,
        .GetNumInterfaces = getZero,
        .GetInterfaceByIndex = getNullIndex,
        .IsOfType = isEqual,
        .ImplementsInterface = notImplementedObj,
    };
    fn of(this: This) *TypeObj {
        return parent(TypeObj, "iface", this);
    }
    fn getDesc(this: This, d: ?*TypeDesc) callconv(cc) HRESULT {
        const t = of(this);
        if (t == &invalid_type) return E_FAIL;
        (d orelse return E_INVALIDARG).* = t.desc;
        return S_OK;
    }
    fn getMemberTypeByIndex(this: This, i: u32) callconv(cc) *anyopaque {
        const t = of(this);
        return if (i < t.members.len) &t.members[i].iface else &invalid_type.iface;
    }
    fn getMemberTypeByName(this: This, name: LPCSTR) callconv(cc) *anyopaque {
        const t = of(this);
        for (t.member_names, t.members) |n, m| if (eqlZ(name, n)) return &m.iface;
        return &invalid_type.iface;
    }
    fn getMemberTypeName(this: This, i: u32) callconv(cc) LPCSTR {
        const t = of(this);
        return if (i < t.member_names.len) t.member_names[i] else null;
    }
    fn isEqual(this: This, other: ?*anyopaque) callconv(cc) HRESULT {
        // S_FALSE when they differ.
        return if (other == this) S_OK else 1;
    }
    fn getNull(_: This) callconv(cc) ?*anyopaque {
        return null;
    }
    fn getNullIndex(_: This, _: u32) callconv(cc) ?*anyopaque {
        return null;
    }
    fn getZero(_: This) callconv(cc) u32 {
        return 0;
    }
    fn notImplementedObj(_: This, _: ?*anyopaque) callconv(cc) HRESULT {
        return E_NOTIMPL;
    }
};

var invalid_type: TypeObj = .{ .desc = .{} };
var invalid_cbuffer: CBufferObj = .{ .desc = .{}, .vars = &.{} };
var invalid_variable: VariableObj = .{ .desc = .{}, .ty = &invalid_type, .buffer = &invalid_cbuffer };

/// A library function: its own resources and constant buffers.
const FunctionObj = struct {
    iface: Iface(FunctionVtbl) = .{ .vtbl = &vtbl },
    desc: FunctionDesc,
    binds: []const *const BindDesc,
    cbuffers: []const *CBufferObj,

    const vtbl: FunctionVtbl = .{
        .GetDesc = getDesc,
        .GetConstantBufferByIndex = getConstantBufferByIndex,
        .GetConstantBufferByName = getConstantBufferByName,
        .GetResourceBindingDesc = getResourceBindingDesc,
        .GetVariableByName = getVariableByName,
        .GetResourceBindingDescByName = getResourceBindingDescByName,
        .GetFunctionParameter = getFunctionParameter,
    };
    fn of(this: This) *FunctionObj {
        return parent(FunctionObj, "iface", this);
    }
    fn getDesc(this: This, d: ?*FunctionDesc) callconv(cc) HRESULT {
        const f = of(this);
        if (f == &invalid_function) return E_FAIL;
        (d orelse return E_INVALIDARG).* = f.desc;
        return S_OK;
    }
    fn getConstantBufferByIndex(this: This, i: u32) callconv(cc) *anyopaque {
        const f = of(this);
        return if (i < f.cbuffers.len) &f.cbuffers[i].iface else &invalid_cbuffer.iface;
    }
    fn getConstantBufferByName(this: This, name: LPCSTR) callconv(cc) *anyopaque {
        for (of(this).cbuffers) |c| if (eqlZ(name, c.desc.Name.?)) return &c.iface;
        return &invalid_cbuffer.iface;
    }
    fn getResourceBindingDesc(this: This, i: u32, d: ?*BindDesc) callconv(cc) HRESULT {
        const f = of(this);
        const out = d orelse return E_INVALIDARG;
        if (i >= f.binds.len) return E_INVALIDARG;
        out.* = f.binds[i].*;
        return S_OK;
    }
    fn getVariableByName(this: This, name: LPCSTR) callconv(cc) *anyopaque {
        for (of(this).cbuffers) |c| for (c.vars) |*v| if (eqlZ(name, v.desc.Name.?)) return &v.iface;
        return &invalid_variable.iface;
    }
    fn getResourceBindingDescByName(this: This, name: LPCSTR, d: ?*BindDesc) callconv(cc) HRESULT {
        const out = d orelse return E_INVALIDARG;
        for (of(this).binds) |b| if (eqlZ(name, b.Name.?)) {
            out.* = b.*;
            return S_OK;
        };
        return E_INVALIDARG;
    }
    fn getFunctionParameter(_: This, _: i32) callconv(cc) *anyopaque {
        return &invalid_parameter;
    }
};

var invalid_function: FunctionObj = .{ .desc = .{}, .binds = &.{}, .cbuffers = &.{} };
const invalid_parameter_vtbl: ParameterVtbl = .{ .GetDesc = struct {
    fn f(_: This, _: ?*anyopaque) callconv(cc) HRESULT {
        return E_FAIL;
    }
}.f };
var invalid_parameter: Iface(ParameterVtbl) = .{ .vtbl = &invalid_parameter_vtbl };

/// ID3D12ShaderReflection and ID3D12LibraryReflection: one object, with
/// everything decoded up front into its arena.
const ShaderReflection = struct {
    shader: Iface(ShaderReflectionVtbl) = .{ .vtbl = &shader_vtbl },
    library: Iface(LibraryReflectionVtbl) = .{ .vtbl = &library_vtbl },
    rc: RefCount = .{},
    arena: std.heap.ArenaAllocator,
    r: reflect.Reflection,
    desc: ShaderDesc,
    binds: []BindDesc,
    cbuffers: []CBufferObj,
    inputs: []SignatureParamDesc,
    outputs: []SignatureParamDesc,
    patch: []SignatureParamDesc,
    functions: []FunctionObj,

    const shader_vtbl: ShaderReflectionVtbl = .{
        .unknown = .{ .QueryInterface = queryInterface, .AddRef = addRef, .Release = release },
        .GetDesc = getDesc,
        .GetConstantBufferByIndex = getConstantBufferByIndex,
        .GetConstantBufferByName = getConstantBufferByName,
        .GetResourceBindingDesc = getResourceBindingDesc,
        .GetInputParameterDesc = getInputParameterDesc,
        .GetOutputParameterDesc = getOutputParameterDesc,
        .GetPatchConstantParameterDesc = getPatchConstantParameterDesc,
        .GetVariableByName = getVariableByName,
        .GetResourceBindingDescByName = getResourceBindingDescByName,
        .GetMovInstructionCount = zero,
        .GetMovcInstructionCount = zero,
        .GetConversionInstructionCount = zero,
        .GetBitwiseInstructionCount = zero,
        .GetGSInputPrimitive = getGSInputPrimitive,
        .IsSampleFrequencyShader = isSampleFrequencyShader,
        .GetNumInterfaceSlots = zero,
        .GetMinFeatureLevel = getMinFeatureLevel,
        .GetThreadGroupSize = getThreadGroupSize,
        .GetRequiresFlags = getRequiresFlags,
    };
    const library_vtbl: LibraryReflectionVtbl = .{
        .unknown = .{ .QueryInterface = libraryQueryInterface, .AddRef = libraryAddRef, .Release = libraryRelease },
        .GetDesc = getLibraryDesc,
        .GetFunctionByIndex = getFunctionByIndex,
    };

    fn of(this: This) *ShaderReflection {
        return parent(ShaderReflection, "shader", this);
    }
    fn libraryOf(this: This) *ShaderReflection {
        return parent(ShaderReflection, "library", this);
    }

    fn create(blob: []const u8) !*ShaderReflection {
        const s = try gpa.create(ShaderReflection);
        errdefer gpa.destroy(s);
        s.* = .{ .arena = .init(gpa), .r = undefined, .desc = .{}, .binds = &.{}, .cbuffers = &.{}, .inputs = &.{}, .outputs = &.{}, .patch = &.{}, .functions = &.{} };
        errdefer s.arena.deinit();
        try s.load(blob);
        return s;
    }

    fn load(s: *ShaderReflection, blob: []const u8) !void {
        const a = s.arena.allocator();
        const bytes = try a.dupe(u8, blob);
        const json = containerPart(bytes, reflect.part) orelse return error.InvalidArgument;
        const r = try reflect.decode(a, json);
        s.r = r;

        const types = try a.alloc(TypeObj, r.types.len);
        for (types, r.types) |*t, rt| {
            const members = try a.alloc(*TypeObj, rt.members.len);
            const names = try a.alloc([*:0]const u8, rt.members.len);
            for (members, names, rt.members) |*m, *n, rm| {
                m.* = if (rm.ty < types.len) &types[rm.ty] else &invalid_type;
                n.* = try a.dupeSentinel(u8, rm.name, 0);
            }
            t.* = .{
                .desc = .{ .Class = rt.class, .Type = rt.kind, .Rows = rt.rows, .Columns = rt.cols, .Elements = rt.elements, .Members = @intCast(rt.members.len), .Offset = rt.offset, .Name = try a.dupeSentinel(u8, rt.name, 0) },
                .members = members,
                .member_names = names,
            };
        }
        s.cbuffers = try a.alloc(CBufferObj, r.cbuffers.len);
        for (s.cbuffers, r.cbuffers) |*c, rc| {
            const vars = try a.alloc(VariableObj, rc.vars.len);
            c.* = .{ .desc = .{ .Name = try a.dupeSentinel(u8, rc.name, 0), .Type = rc.kind, .Variables = @intCast(rc.vars.len), .Size = rc.size, .uFlags = rc.flags }, .vars = vars };
            for (vars, rc.vars) |*v, rv| v.* = .{
                .desc = .{ .Name = try a.dupeSentinel(u8, rv.name, 0), .StartOffset = rv.offset, .Size = rv.size, .uFlags = rv.flags },
                .ty = if (rv.ty < types.len) &types[rv.ty] else &invalid_type,
                .buffer = c,
            };
        }
        s.binds = try a.alloc(BindDesc, r.binds.len);
        for (s.binds, r.binds) |*b, rb| b.* = .{
            .Name = try a.dupeSentinel(u8, rb.name, 0),
            .Type = rb.type,
            .BindPoint = rb.bind_point,
            .BindCount = rb.bind_count,
            .uFlags = rb.flags,
            .ReturnType = rb.return_type,
            .Dimension = rb.dimension,
            .NumSamples = rb.num_samples,
            .Space = rb.space,
            .uID = rb.id,
        };
        s.inputs = try signatureParams(a, containerPart(bytes, reflect.input_part));
        s.outputs = try signatureParams(a, containerPart(bytes, reflect.output_part));
        s.patch = try signatureParams(a, containerPart(bytes, reflect.patch_part));
        s.desc = .{
            .Version = r.version,
            .Creator = creator,
            .ConstantBuffers = @intCast(r.cbuffers.len),
            .BoundResources = @intCast(r.binds.len),
            .InputParameters = @intCast(s.inputs.len),
            .OutputParameters = @intCast(s.outputs.len),
            .InstructionCount = r.instructions,
            .GSOutputTopology = r.gs_output_topology,
            .GSMaxOutputVertexCount = r.gs_max_vertices,
            .InputPrimitive = r.input_primitive,
            .PatchConstantParameters = @intCast(s.patch.len),
            .cGSInstanceCount = r.gs_instances,
            .cControlPoints = r.control_points,
            .HSOutputPrimitive = r.hs_output_primitive,
            .HSPartitioning = r.hs_partitioning,
            .TessellatorDomain = r.tess_domain,
        };
        s.functions = try a.alloc(FunctionObj, r.functions.len);
        for (s.functions, r.functions) |*f, rf| {
            const binds = try a.alloc(*const BindDesc, rf.binds.len);
            for (binds, rf.binds) |*b, i| b.* = if (i < s.binds.len) &s.binds[i] else &.{};
            const cbs = try a.alloc(*CBufferObj, rf.cbuffers.len);
            for (cbs, rf.cbuffers) |*c, i| c.* = if (i < s.cbuffers.len) &s.cbuffers[i] else &invalid_cbuffer;
            f.* = .{
                .desc = .{
                    .Version = rf.version,
                    .Creator = creator,
                    .ConstantBuffers = @intCast(cbs.len),
                    .BoundResources = @intCast(binds.len),
                    .MinFeatureLevel = feature_level_12_0,
                    .RequiredFeatureFlags = rf.requires,
                    .Name = try a.dupeSentinel(u8, rf.name, 0),
                },
                .binds = binds,
                .cbuffers = cbs,
            };
        }
    }

    /// The parameters of a DxilProgramSignature part (ISG1, OSG1, PSG1),
    /// which are D3D12_SIGNATURE_PARAMETER_DESC's fields.
    fn signatureParams(a: std.mem.Allocator, part: ?[]const u8) ![]SignatureParamDesc {
        const p = part orelse return &.{};
        if (p.len < 8) return &.{};
        const count = std.mem.readInt(u32, p[0..4], .little);
        const first = std.mem.readInt(u32, p[4..8], .little);
        if (first > p.len or count > (p.len - first) / 32) return error.InvalidArgument;
        const out = try a.alloc(SignatureParamDesc, count);
        for (out, 0..) |*d, i| {
            const rec = p[first + 32 * i ..][0..32];
            const word = struct {
                fn f(b: []const u8, k: usize) u32 {
                    return std.mem.readInt(u32, b[4 * k ..][0..4], .little);
                }
            }.f;
            const name_off = word(rec, 1);
            const name: LPCSTR = if (name_off < p.len) blk: {
                const end = std.mem.indexOfScalarPos(u8, p, name_off, 0) orelse return error.InvalidArgument;
                const n = try a.dupeSentinel(u8, p[name_off..end], 0);
                // System values read back uppercase, as D3D reports them.
                if (word(rec, 3) != 0) _ = std.ascii.upperString(n, n);
                break :blk n.ptr;
            } else null;
            // Minimum-precision values are reported as their 32-bit types
            // (UINT16/SINT16/FLOAT16 -> UINT32/SINT32/FLOAT32).
            const comp = word(rec, 4);
            d.* = .{
                .SemanticName = name,
                .SemanticIndex = word(rec, 2),
                .Register = word(rec, 5),
                .SystemValueType = word(rec, 3),
                .ComponentType = if (word(rec, 7) != 0 and comp >= 4 and comp <= 6) comp - 3 else comp,
                .Mask = rec[24],
                .ReadWriteMask = rec[25],
                .Stream = word(rec, 0),
                .MinPrecision = word(rec, 7),
            };
        }
        return out;
    }

    fn query(s: *ShaderReflection, iid: *const GUID, out: Out) HRESULT {
        const p: *anyopaque = if (iid.eql(IID_IUnknown) or iid.eql(IID_ID3D12ShaderReflection))
            &s.shader
        else if (iid.eql(IID_ID3D12LibraryReflection))
            &s.library
        else {
            out.* = null;
            return E_NOINTERFACE;
        };
        _ = s.rc.addRef();
        out.* = p;
        return S_OK;
    }

    fn queryInterface(this: This, iid: *const GUID, out: ?Out) callconv(cc) HRESULT {
        return of(this).query(iid, out orelse return E_POINTER);
    }
    fn addRef(this: This) callconv(cc) ULONG {
        return of(this).rc.addRef();
    }
    fn release(this: This) callconv(cc) ULONG {
        const s = of(this);
        const n = s.rc.release();
        if (n == 0) {
            s.arena.deinit();
            gpa.destroy(s);
        }
        return n;
    }
    fn libraryQueryInterface(this: This, iid: *const GUID, out: ?Out) callconv(cc) HRESULT {
        return libraryOf(this).query(iid, out orelse return E_POINTER);
    }
    fn libraryAddRef(this: This) callconv(cc) ULONG {
        return libraryOf(this).rc.addRef();
    }
    fn libraryRelease(this: This) callconv(cc) ULONG {
        return release(&libraryOf(this).shader);
    }

    fn getDesc(this: This, d: ?*ShaderDesc) callconv(cc) HRESULT {
        (d orelse return E_INVALIDARG).* = of(this).desc;
        return S_OK;
    }
    fn getConstantBufferByIndex(this: This, i: u32) callconv(cc) *anyopaque {
        const s = of(this);
        return if (i < s.cbuffers.len) &s.cbuffers[i].iface else &invalid_cbuffer.iface;
    }
    fn getConstantBufferByName(this: This, name: LPCSTR) callconv(cc) *anyopaque {
        for (of(this).cbuffers) |*c| if (eqlZ(name, c.desc.Name.?)) return &c.iface;
        return &invalid_cbuffer.iface;
    }
    fn getResourceBindingDesc(this: This, i: u32, d: ?*BindDesc) callconv(cc) HRESULT {
        const s = of(this);
        const out = d orelse return E_INVALIDARG;
        if (i >= s.binds.len) return E_INVALIDARG;
        out.* = s.binds[i];
        return S_OK;
    }
    fn paramDesc(params: []const SignatureParamDesc, i: u32, d: ?*SignatureParamDesc) HRESULT {
        const out = d orelse return E_INVALIDARG;
        if (i >= params.len) return E_INVALIDARG;
        out.* = params[i];
        return S_OK;
    }
    fn getInputParameterDesc(this: This, i: u32, d: ?*SignatureParamDesc) callconv(cc) HRESULT {
        return paramDesc(of(this).inputs, i, d);
    }
    fn getOutputParameterDesc(this: This, i: u32, d: ?*SignatureParamDesc) callconv(cc) HRESULT {
        return paramDesc(of(this).outputs, i, d);
    }
    fn getPatchConstantParameterDesc(this: This, i: u32, d: ?*SignatureParamDesc) callconv(cc) HRESULT {
        return paramDesc(of(this).patch, i, d);
    }
    fn getVariableByName(this: This, name: LPCSTR) callconv(cc) *anyopaque {
        for (of(this).cbuffers) |*c| for (c.vars) |*v| if (eqlZ(name, v.desc.Name.?)) return &v.iface;
        return &invalid_variable.iface;
    }
    fn getResourceBindingDescByName(this: This, name: LPCSTR, d: ?*BindDesc) callconv(cc) HRESULT {
        const out = d orelse return E_INVALIDARG;
        for (of(this).binds) |b| if (eqlZ(name, b.Name.?)) {
            out.* = b;
            return S_OK;
        };
        return E_INVALIDARG;
    }
    fn zero(_: This) callconv(cc) u32 {
        return 0;
    }
    fn getGSInputPrimitive(this: This) callconv(cc) u32 {
        return of(this).r.input_primitive;
    }
    /// DXC's reflection answers false.
    fn isSampleFrequencyShader(_: This) callconv(cc) BOOL {
        return if (windows) 0 else false;
    }
    fn getMinFeatureLevel(_: This, level: ?*u32) callconv(cc) HRESULT {
        (level orelse return E_INVALIDARG).* = feature_level_12_0;
        return S_OK;
    }
    fn getThreadGroupSize(this: This, x: ?*u32, y: ?*u32, z: ?*u32) callconv(cc) u32 {
        const t = of(this).r.thread_group;
        if (x) |p| p.* = t[0];
        if (y) |p| p.* = t[1];
        if (z) |p| p.* = t[2];
        return t[0] * t[1] * t[2];
    }
    fn getRequiresFlags(this: This) callconv(cc) u64 {
        return of(this).r.requires;
    }
    fn getLibraryDesc(this: This, d: ?*LibraryDesc) callconv(cc) HRESULT {
        (d orelse return E_INVALIDARG).* = .{ .Creator = creator, .FunctionCount = @intCast(libraryOf(this).functions.len) };
        return S_OK;
    }
    fn getFunctionByIndex(this: This, i: i32) callconv(cc) *anyopaque {
        const s = libraryOf(this);
        return if (i >= 0 and i < s.functions.len) &s.functions[@intCast(i)].iface else &invalid_function.iface;
    }
};

// ---- Containers -------------------------------------------------------------

/// The parts of a DXIL container, as (fourcc, bytes) slices into it.
fn containerParts(a: std.mem.Allocator, obj: []const u8) !std.ArrayList(zdxc.dxil.container.Part) {
    const view = zdxc.dxil.container.parse(a, obj) catch return error.InvalidArgument;
    return view.parts;
}

const ContainerReflectionVtbl = extern struct {
    unknown: UnknownVtbl,
    Load: *const fn (This, ?*anyopaque) callconv(cc) HRESULT,
    GetPartCount: *const fn (This, ?*u32) callconv(cc) HRESULT,
    GetPartKind: *const fn (This, u32, ?*u32) callconv(cc) HRESULT,
    GetPartContent: *const fn (This, u32, ?Out) callconv(cc) HRESULT,
    FindFirstPartKind: *const fn (This, u32, ?*u32) callconv(cc) HRESULT,
    GetPartReflection: *const fn (This, u32, *const GUID, ?Out) callconv(cc) HRESULT,
};

/// IDxcContainerReflection: the parts of a loaded container.
const ContainerReflection = struct {
    iface: Iface(ContainerReflectionVtbl) = .{ .vtbl = &vtbl },
    rc: RefCount = .{},
    bytes: []u8 = &.{},
    parts: std.ArrayList(zdxc.dxil.container.Part) = .empty,

    const vtbl: ContainerReflectionVtbl = .{
        .unknown = .{ .QueryInterface = queryInterface, .AddRef = addRef, .Release = release },
        .Load = load,
        .GetPartCount = getPartCount,
        .GetPartKind = getPartKind,
        .GetPartContent = getPartContent,
        .FindFirstPartKind = findFirstPartKind,
        .GetPartReflection = getPartReflection,
    };

    fn of(this: This) *ContainerReflection {
        return parent(ContainerReflection, "iface", this);
    }
    fn clear(c: *ContainerReflection) void {
        c.parts.deinit(gpa);
        c.parts = .empty;
        gpa.free(c.bytes);
        c.bytes = &.{};
    }
    fn queryInterface(this: This, iid: *const GUID, out: ?Out) callconv(cc) HRESULT {
        if (!iid.eql(IID_IUnknown) and !iid.eql(IID_IDxcContainerReflection)) {
            _ = put(out, null);
            return E_NOINTERFACE;
        }
        _ = of(this).rc.addRef();
        return put(out, this);
    }
    fn addRef(this: This) callconv(cc) ULONG {
        return of(this).rc.addRef();
    }
    fn release(this: This) callconv(cc) ULONG {
        const c = of(this);
        const n = c.rc.release();
        if (n == 0) {
            c.clear();
            gpa.destroy(c);
        }
        return n;
    }
    fn load(this: This, blob: ?*anyopaque) callconv(cc) HRESULT {
        const c = of(this);
        c.clear();
        const b = blob orelse return E_INVALIDARG;
        c.bytes = gpa.dupe(u8, blobBytes(b)) catch return E_OUTOFMEMORY;
        c.parts = containerParts(gpa, c.bytes) catch |e| {
            c.clear();
            return if (e == error.OutOfMemory) E_OUTOFMEMORY else E_INVALIDARG;
        };
        return S_OK;
    }
    fn getPartCount(this: This, count: ?*u32) callconv(cc) HRESULT {
        (count orelse return E_INVALIDARG).* = @intCast(of(this).parts.items.len);
        return S_OK;
    }
    fn getPartKind(this: This, i: u32, kind: ?*u32) callconv(cc) HRESULT {
        const c = of(this);
        const k = kind orelse return E_INVALIDARG;
        if (i >= c.parts.items.len) return E_INVALIDARG;
        k.* = c.parts.items[i].fourcc;
        return S_OK;
    }
    fn getPartContent(this: This, i: u32, out: ?Out) callconv(cc) HRESULT {
        const c = of(this);
        const o = out orelse return E_INVALIDARG;
        o.* = null;
        if (i >= c.parts.items.len) return E_INVALIDARG;
        const b = Blob.copy(.binary, c.parts.items[i].data, CP_ACP) catch return E_OUTOFMEMORY;
        o.* = b.ptr();
        return S_OK;
    }
    fn findFirstPartKind(this: This, kind: u32, index: ?*u32) callconv(cc) HRESULT {
        const c = of(this);
        const out = index orelse return E_INVALIDARG;
        for (c.parts.items, 0..) |p, i| if (p.fourcc == kind) {
            out.* = @intCast(i);
            return S_OK;
        };
        return code(0x80AA0013); // DXC_E_MISSING_PART
    }
    /// Reflection of one of our reflection blobs' parts is the blob's.
    fn getPartReflection(this: This, _: u32, iid: *const GUID, out: ?Out) callconv(cc) HRESULT {
        const c = of(this);
        const o = out orelse return E_INVALIDARG;
        o.* = null;
        const r = ShaderReflection.create(c.bytes) catch |e| return if (e == error.OutOfMemory) E_OUTOFMEMORY else E_NOTIMPL;
        defer _ = ShaderReflection.release(&r.shader);
        return r.query(iid, o);
    }
};

const ContainerBuilderVtbl = extern struct {
    unknown: UnknownVtbl,
    Load: *const fn (This, ?*anyopaque) callconv(cc) HRESULT,
    AddPart: *const fn (This, u32, ?*anyopaque) callconv(cc) HRESULT,
    RemovePart: *const fn (This, u32) callconv(cc) HRESULT,
    SerializeContainer: *const fn (This, ?Out) callconv(cc) HRESULT,
};

/// IDxcContainerBuilder: adds and removes parts, then writes the container
/// again (signed, as the validator signs).
const ContainerBuilder = struct {
    iface: Iface(ContainerBuilderVtbl) = .{ .vtbl = &vtbl },
    rc: RefCount = .{},
    arena: std.heap.ArenaAllocator = .init(gpa),
    parts: std.ArrayList(zdxc.dxil.container.Part) = .empty,

    const vtbl: ContainerBuilderVtbl = .{
        .unknown = .{ .QueryInterface = queryInterface, .AddRef = addRef, .Release = release },
        .Load = load,
        .AddPart = addPart,
        .RemovePart = removePart,
        .SerializeContainer = serializeContainer,
    };

    fn of(this: This) *ContainerBuilder {
        return parent(ContainerBuilder, "iface", this);
    }
    fn queryInterface(this: This, iid: *const GUID, out: ?Out) callconv(cc) HRESULT {
        if (!iid.eql(IID_IUnknown) and !iid.eql(IID_IDxcContainerBuilder)) {
            _ = put(out, null);
            return E_NOINTERFACE;
        }
        _ = of(this).rc.addRef();
        return put(out, this);
    }
    fn addRef(this: This) callconv(cc) ULONG {
        return of(this).rc.addRef();
    }
    fn release(this: This) callconv(cc) ULONG {
        const c = of(this);
        const n = c.rc.release();
        if (n == 0) {
            c.arena.deinit();
            gpa.destroy(c);
        }
        return n;
    }
    fn load(this: This, blob: ?*anyopaque) callconv(cc) HRESULT {
        const c = of(this);
        const a = c.arena.allocator();
        const b = blob orelse return E_INVALIDARG;
        const bytes = a.dupe(u8, blobBytes(b)) catch return E_OUTOFMEMORY;
        c.parts = containerParts(a, bytes) catch |e| return if (e == error.OutOfMemory) E_OUTOFMEMORY else E_INVALIDARG;
        return S_OK;
    }
    fn addPart(this: This, fourcc: u32, blob: ?*anyopaque) callconv(cc) HRESULT {
        const c = of(this);
        const a = c.arena.allocator();
        const b = blob orelse return E_INVALIDARG;
        for (c.parts.items) |p| if (p.fourcc == fourcc) return code(0x80AA0014); // DXC_E_DUPLICATE_PART
        const data = a.dupe(u8, blobBytes(b)) catch return E_OUTOFMEMORY;
        c.parts.append(a, .{ .fourcc = fourcc, .data = data }) catch return E_OUTOFMEMORY;
        return S_OK;
    }
    /// Removing a part the container does not have succeeds: zdxc's
    /// objects carry no STAT part, which clients strip as a matter of
    /// course.
    fn removePart(this: This, fourcc: u32) callconv(cc) HRESULT {
        const c = of(this);
        var i: usize = 0;
        while (i < c.parts.items.len) {
            if (c.parts.items[i].fourcc == fourcc) _ = c.parts.orderedRemove(i) else i += 1;
        }
        return S_OK;
    }
    fn serializeContainer(this: This, out: ?Out) callconv(cc) HRESULT {
        const c = of(this);
        const o = out orelse return E_POINTER;
        o.* = null;
        const bytes = zdxc.dxil.container.assemble(gpa, c.parts.items) catch return E_OUTOFMEMORY;
        defer gpa.free(bytes);
        const r = gpa.create(Result) catch return E_OUTOFMEMORY;
        r.* = .{ .status = S_OK, .primary = .object };
        addOutput(r, .object, Blob.copy(.binary, bytes, CP_ACP) catch {
            r.destroy();
            return E_OUTOFMEMORY;
        }, null) catch {
            r.destroy();
            return E_OUTOFMEMORY;
        };
        o.* = &r.iface;
        return S_OK;
    }
};

// ---------------------------------------------------------------------------
// Exports

fn createInstance(clsid: ?*const GUID, iid: ?*const GUID, out: ?Out) HRESULT {
    const o = out orelse return E_POINTER;
    o.* = null;
    const class = clsid orelse return E_INVALIDARG;
    const want = iid orelse return E_INVALIDARG;
    if (class.eql(CLSID_DxcCompiler)) {
        const c = gpa.create(Compiler) catch return E_OUTOFMEMORY;
        c.* = .{};
        defer _ = Compiler.release(&c.compiler);
        return c.query(want, o);
    }
    if (class.eql(CLSID_DxcUtils)) {
        const u = gpa.create(Utils) catch return E_OUTOFMEMORY;
        u.* = .{};
        defer _ = Utils.release(&u.iface);
        return Utils.queryInterface(&u.iface, want, o);
    }
    if (class.eql(CLSID_DxcContainerReflection)) {
        const c = gpa.create(ContainerReflection) catch return E_OUTOFMEMORY;
        c.* = .{};
        defer _ = ContainerReflection.release(&c.iface);
        return ContainerReflection.queryInterface(&c.iface, want, o);
    }
    if (class.eql(CLSID_DxcContainerBuilder)) {
        const c = gpa.create(ContainerBuilder) catch return E_OUTOFMEMORY;
        c.* = .{};
        defer _ = ContainerBuilder.release(&c.iface);
        return ContainerBuilder.queryInterface(&c.iface, want, o);
    }
    return REGDB_E_CLASSNOTREG;
}

export fn DxcCreateInstance(clsid: ?*const GUID, iid: ?*const GUID, out: ?Out) callconv(cc) HRESULT {
    return createInstance(clsid, iid, out);
}

/// The IMalloc is not used: zdxc allocates for itself.
export fn DxcCreateInstance2(_: ?*anyopaque, clsid: ?*const GUID, iid: ?*const GUID, out: ?Out) callconv(cc) HRESULT {
    return createInstance(clsid, iid, out);
}

test "normalizePath follows DXC" {
    if (windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "inc/common.hlsli", "./inc/common.hlsli" },
        .{ "./inc//x.h", "./inc/x.h" },
        .{ "/abs//path", "/abs/path" },
        .{ "..\\up/x.h", "./../up/x.h" },
        .{ ".", "." },
    };
    for (cases) |c| {
        const n = try normalizePath(a, c[0]);
        defer a.free(n);
        try std.testing.expectEqualStrings(c[1], n);
    }
}

test "GUID.parse" {
    try std.testing.expectEqual(@as(u32, 0x73e22d93), CLSID_DxcCompiler.a);
    try std.testing.expectEqual(@as(u8, 0xb5), CLSID_DxcCompiler.d[0]);
    try std.testing.expectEqual(@as(u8, 0xb0), CLSID_DxcCompiler.d[7]);
}
