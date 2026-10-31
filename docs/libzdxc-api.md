# libzdxc: matching DXC's library API

Status: investigation notes, not yet implemented. Source references are to the
DXC tree at `f9fc72ad3`.

## How DXC works as a library

`dxcompiler` (`libdxcompiler.so` / `.dylib`, `dxcompiler.dll`) exports
exactly two C symbols (`tools/clang/tools/dxcompiler/dxcompiler.def`):

```c
HRESULT DxcCreateInstance (REFCLSID rclsid, REFIID riid, void **ppv);
HRESULT DxcCreateInstance2(IMalloc *pMalloc, REFCLSID rclsid, REFIID riid, void **ppv);
```

Everything else is a COM-style interface reached from those two calls.
`DxcCreateInstance` is a CLSID switch (`dxcapi.cpp`,
`ThreadMallocDxcCreateInstance`) that returns `REGDB_E_CLASSNOTREG`
(0x80040154) for unknown classes. `DxcCreateInstance2` installs a
caller-supplied `IMalloc` as the allocator for that object's lifetime.

The `dxc` executable is itself a thin client. It `dlopen`s dxcompiler through
`include/dxc/Support/dxcapi.use.h` and drives it with `CLSID_DxcCompiler`,
`CLSID_DxcLibrary`, and so on (`tools/clang/tools/dxclib/dxc.cpp`). The command
line and the API share one option parser: the arguments passed to
`IDxcCompiler3::Compile` are dxc command-line flags as wide strings.

### Classes and interfaces

| CLSID | Interfaces it answers `QueryInterface` for | Typical use |
|---|---|---|
| `CLSID_DxcCompiler` | `IDxcCompiler3`, `IDxcVersionInfo`, `IDxcVersionInfo2/3`, `IDxcLangExtensions*`, `IDxcContainerEvent`; legacy `IDxcCompiler`, `IDxcCompiler2` via an adapter sub-object (`dxcompilerobj.cpp:499`) | compile, preprocess, disassemble |
| `CLSID_DxcUtils` == `CLSID_DxcLibrary` (same GUID) | `IDxcUtils`, legacy `IDxcLibrary` | blobs, default include handler, `BuildArguments`, `CreateReflection`, `GetDxilContainerPart` |
| `CLSID_DxcCompilerArgs` | `IDxcCompilerArgs` | building argument lists |
| `CLSID_DxcValidator` | `IDxcValidator`, `IDxcValidator2`, `IDxcVersionInfo` | validation and signing (also exported by the separate `dxil` library) |
| `CLSID_DxcContainerReflection` | `IDxcContainerReflection` | listing container parts, `ID3D12ShaderReflection` |
| `CLSID_DxcContainerBuilder` | `IDxcContainerBuilder` | adding and removing parts |
| `CLSID_DxcAssembler`, `CLSID_DxcOptimizer`, `CLSID_DxcLinker`, `CLSID_DxcPdbUtils`, `CLSID_DxcRewriter`, `CLSID_DxcIntelliSense` | — | LLVM-IR tooling, PDBs, IntelliSense |

### Compile contract (`IDxcCompiler3::Compile`, `dxcompilerobj.cpp:517`)

- Inputs: a `DxcBuffer` (pointer, size, code page; 0 means detect a BOM,
  otherwise treat as UTF-8), `LPCWSTR` argv, an optional `IDxcIncludeHandler`,
  and an `riid` that must be `IDxcResult` or `IDxcOperationResult`. Any other
  `riid`, a null source, or a null argv with `argCount > 0` returns
  `E_INVALIDARG`.
- **Compile errors do not fail the call.** `Compile` returns `S_OK` and the
  result's `GetStatus` reports `E_FAIL`. The call itself fails only for API
  misuse or out-of-memory. Clients depend on this.
- Outputs are keyed by `DXC_OUT_KIND`: `OBJECT` (DXIL container or SPIR-V
  words), `ERRORS` (UTF-8 diagnostic text, also present on success when there
  are warnings), `HLSL` (`-P`), `REFLECTION`, `SHADER_HASH`, `ROOT_SIGNATURE`,
  `PDB`, and others. Each output can carry a name taken from the flags (`-Fo`,
  `-Fre`, `-Fsh`, ...). The library never writes files; the client does.
- The source name is the first positional argument, or `hlsl.hlsl` if there is
  none (`dxcompilerobj.cpp:588`). That name appears in diagnostics.
- Includes go through a virtual file system (`dxcfilesystem.cpp`). Clang's
  header search builds each candidate path (including file's directory, then
  `-I` directories) and passes it through `NormalizePathW` (`Support/Path.h`):
  `\` becomes `/` on Unix, doubled slashes collapse, and relative paths get a
  `./` prefix. Each candidate is then handed to `LoadSource`. **A failed
  `LoadSource` means "try the next candidate", not "abort".** With a null
  handler, nothing except the main buffer resolves, and DXC never touches the
  disk itself. `IDxcUtils::CreateDefaultIncludeHandler` is the one that reads
  from disk (`dxclibrary.cpp:41`).

## ABI facts libzdxc must match

These are exactly where a "looks right" reimplementation silently breaks.

1. **Vtable layout.** On Unix, `IUnknown` has three pure virtuals and *no
   virtual destructor*. The destructor was removed specifically for ABI
   (`47f31378a`, #3793). An interface pointer points at a vptr, and the vtable
   is the base's slots followed by each derived interface's methods in
   declaration order. This holds on both Itanium and MSVC, so one Zig
   `extern struct { vtable: *const VTable }` layout serves both.
2. **Calling convention.** `STDMETHODCALLTYPE` and `__stdcall` are empty on Unix
   (plain C convention). On Windows, use `callconv(.winapi)`. Two methods,
   `IDxcResult::GetOutputByIndex` and `PrimaryOutput`, are declared without
   `STDMETHODCALLTYPE`. They only differ on 32-bit Windows (`__thiscall`), which
   can be ignored unless x86-32 is a target.
3. **`BOOL` is `bool` (1 byte) on Unix** (`WinAdapter.h:306`) and `int`
   (4 bytes) on Windows. This affects `IDxcResult::HasOutput`,
   `IDxcBlobEncoding::GetEncoding(BOOL *)`, and `IDxcPdbUtils::IsFullPDB`.
4. **`WCHAR` is `wchar_t`: UTF-32 on Unix, UTF-16 on Windows.** All `LPCWSTR`
   arguments, file names passed to `LoadSource`, and `IDxcBlobWide` contents
   follow this. `DXC_CP_WIDE` is `DXC_CP_UTF32` on Unix.
5. **`ULONG` is `unsigned long` on Unix** (64-bit on LP64). That is what
   `AddRef`/`Release` return; in Zig that is `c_ulong`.
6. **GUIDs.** `__uuidof` is emulated on the client side through
   `CROSS_PLATFORM_UUIDOF` templates, so the library only needs to compare
   16-byte `GUID` values.
7. **HRESULTs** use the Windows values: `E_NOINTERFACE` 0x80004002, `E_NOTIMPL`
   0x80004001, `E_POINTER` 0x80004003, `E_INVALIDARG`, `E_OUTOFMEMORY`,
   `E_FAIL`, `REGDB_E_CLASSNOTREG`.
8. **Ownership.** Every returned interface carries one reference. Reference
   counts must be atomic: DXC lets separate instances run on separate threads,
   and clients release objects from any thread. Objects that clients pass in
   (include handler, blobs) are borrowed; take an `AddRef` only when keeping
   them.
9. **No unwinding across the boundary.** Every exported function and vtable
   entry must catch every Zig error and turn it into an HRESULT.

## Proposed shape

### Layering

```
src/compile.zig     Zig-native API: compile(gpa, Request) -> Result
                    Request { source, name, args: []const []const u8, fs: source.FileSystem }
                    Result  { status, outputs: [kind]?Output }  (bytes + name + code page)
src/options.zig     dxc argv parser built on options_table (moved out of main.zig)
src/capi/           COM layer; the only code that knows about GUIDs and vtables
  types.zig         GUID, HRESULT, BOOL/WCHAR per target, CLSIDs/IIDs from dxcapi.h
  object.zig        Object(Impl, .{ interfaces... }) — atomic refcount, comptime QI table
  blob.zig          IDxcBlob / Encoding / Utf8 / Wide over owned, pinned, or IMalloc memory
  result.zig        IDxcResult + IDxcOperationResult over compile.Result
  include.zig       IDxcIncludeHandler -> source.FileSystem adapter (+ default disk handler)
  compiler.zig      IDxcCompiler3 (+ legacy IDxcCompiler/2 adapter), IDxcVersionInfo
  utils.zig         IDxcUtils, IDxcLibrary, IDxcCompilerArgs
  exports.zig       export fn DxcCreateInstance / DxcCreateInstance2
src/main.zig        CLI built on compile.zig — the same relationship dxc has with dxcompiler
```

The important split is that `compile.zig` is the real library and `capi/` is a
translation shell. The CLI and the COM layer then exercise one code path. Zig
users can import the `zdxc` module and call `compile` directly with no COM.

Existing pieces already fit:

- `source.FileSystem` is a vtable, so an `IDxcIncludeHandler` adapter is a
  single `read` implementation. It converts the candidate path to `WCHAR`,
  calls `LoadSource`, decodes the blob to UTF-8, and maps failure to `null`.
  The preprocessor must still produce dxc's candidate-path sequence and
  `NormalizePathW` spelling, because handlers often match on exact strings.
  Add an oracle test that logs `LoadSource` calls from both libraries.
- `Diagnostics.render` already writes to an `Io.Writer`. `DXC_OUT_ERRORS` is
  that text rendered without color, in dxc's default format.
- `DxcCreateInstance2`'s `IMalloc` wraps directly into a `std.mem.Allocator`
  (`Alloc` / `Realloc` / `Free`), which becomes the `gpa` for that object.

### Build artifacts

- `zig build` installs `libzdxc` both as a static library and as a shared
  library. An option such as `-Ddxcompiler-name` would also name the shared
  library `libdxcompiler.{so,dylib}` / `dxcompiler.dll`, so existing loaders
  (`dxcapi.use.h`, hassle-rs, engines that `dlopen` by name) work unmodified.
- Optionally, add a `dxil` shim exporting `DxcCreateInstance` for
  `CLSID_DxcValidator` only. Some clients, such as wgpu through hassle-rs,
  require `dxil.dll` to load. Since zdxc signs its own output, that validator
  can re-check the hash and return `S_OK`.
- Ship no headers of our own: clients keep using DXC's `dxcapi.h`. The ABI is
  the contract.

### Staging

| Stage | Surface | Who needs it |
|---|---|---|
| L0 | exports, `IUnknown` machinery, blob family, `IDxcUtils` (`CreateBlob`, `CreateBlobFromPinned`, `LoadFile`, `CreateDefaultIncludeHandler`, `GetBlobAsUtf8`), `IDxcCompiler3::Compile` (no `Disassemble`), `IDxcResult`, `IDxcVersionInfo` | modern engines; enough to run the drop-in oracle |
| L1 | legacy `IDxcLibrary`, `IDxcCompiler`/`IDxcCompiler2` (`Compile`, `Preprocess`), `IDxcOperationResult`, `IDxcCompilerArgs`, `IDxcUtils::BuildArguments` | hassle-rs and wgpu, older engines, `-P` users |
| L2 | `IDxcContainerReflection` (part listing), `IDxcUtils::GetDxilContainerPart`, `IDxcContainerBuilder`, `IDxcValidator` (hash check) | tooling that inspects containers |
| L3 | `IDxcUtils::CreateReflection` / `GetPartReflection` → `ID3D12ShaderReflection` (`d3d12shader.h`) | engines building root signatures from reflection |
| — | `Disassemble`, assembler, optimizer, linker, PDB utils, IntelliSense, rewriter, DIA | return `E_NOTIMPL` or `REGDB_E_CLASSNOTREG`, matching the plan's dropped list |

L3 is the expensive stage. DXC's `ID3D12ShaderReflection` reads the DXIL
module from the container's STAT part and walks its metadata, plus RDAT for
libraries. zdxc can serve it from bytes it wrote itself, but the reflection
interface is large (types, variables, constant buffers, bindings). Because
`CreateReflection` takes only a blob, the data must come from the container,
not from the compiler's memory. Schedule this alongside M0.1's reflection-match
exit criterion. SPIR-V clients use SPIRV-Reflect, not DXC, so it is DXIL-only.

Versioning: `IDxcVersionInfo::GetVersion` should report the DXC version
whose behavior zdxc matches (clients gate features on it), and
`IDxcVersionInfo3::GetCustomVersionString` should report `zdxc <version>`.

## Being a backend for Slang and SDL_shadercross

Read from Slang `c959b56` (`source/compiler-core/slang-dxc-compiler.cpp`) and
SDL_shadercross `1ff05be` (`src/SDL_shadercross.c`,
`cmake/FindDirectXShaderCompiler.cmake`). Neither client needs code changes:
both reach DXC only through `DxcCreateInstance`, so a library that matches the
ABI and is installed under DXC's names is a drop-in replacement. Both feed
DXC *machine-generated* HLSL, which makes them good acceptance corpora.

### SDL_shadercross (smallest surface; best first target)

- **Linking:** the DXC library is linked at build time (`extern
  DxcCreateInstance`), not loaded with `dlopen`. CMake finds it either as a
  vendored DXC subproject or through `FindDirectXShaderCompiler.cmake` with
  `DirectXShaderCompiler_ROOT`. On non-Windows, that module *requires*
  `dxcapi.h` in an include directory plus `libdxcompiler` and `libdxil`
  libraries, even though the C code declares its own vtables and never includes
  the header. So a zdxc install tree would need `include/dxcapi.h` (a
  placeholder file would satisfy the lookup), `lib/libdxcompiler.*`, and a
  `lib/libdxil.*` stub.
- **API used:** `CLSID_DxcCompiler`→`IDxcCompiler3::Compile`,
  `CLSID_DxcUtils`→`IDxcUtils::CreateDefaultIncludeHandler`, and on
  `IDxcResult`: `GetStatus`, `GetOutput(DXC_OUT_OBJECT, IID_IDxcBlob)`,
  `GetOutput(DXC_OUT_ERRORS, IID_IDxcBlobUtf8)` (read on success too, for
  warnings). That is exactly L0.
- **Inputs:** `DxcBuffer.Size = strlen + 1`, so **the source buffer includes
  its NUL terminator**, and the encoding is `DXC_CP_ACP` (0). Arguments are
  `-D…`, `-E`, `-I <dir>`, `-T {vs,ps,cs}_6_0` only, an optional bare source
  name, and `-Zi` for debug builds. For SPIR-V: `-spirv
  -fspv-flatten-resource-arrays -fspv-preserve-interface`, plus
  `-fspv-preserve-bindings` unless unused bindings are culled, and
  `-fspv-debug=vulkan-with-source` for debug builds. There is no `-HV`, so
  dxc's default of 2021 applies.
- **Pipeline:** by default, `CompileDXILFromHLSL` **round-trips**:
  HLSL →(DXC `-spirv`)→ SPIR-V →(SPIRV-Cross, `HLSL_SHADER_MODEL`)→ HLSL
  →(DXC)→ DXIL. MSL output and all resource reflection come from SPIRV-Cross
  reading DXC's SPIR-V, and DXC's own reflection is never used. Consequences:
  - Both backends are on the critical path, and the DXIL backend must accept
    SPIRV-Cross-generated HLSL.
  - zdxc's SPIR-V must satisfy SPIRV-Cross, not just `spirv-val`. That means
    the names, decorations, and interface variables reflection depends on, and
    the three `-fspv-*` flags above.
  - No `ID3D12ShaderReflection`, linker, or disassembler is needed.
- **Fit with the plan:** vs/ps/cs at 6.0 is inside M0.1. Shadercross is the
  cheapest real client: L0 plus four `-fspv-*` flags.

### Slang

- **Platform gate:** `SLANG_ENABLE_DXIL_SUPPORT` defaults to **0 on Apple
  platforms**, so stock Slang on macOS never calls dxcompiler. Testing on this
  Mac needs a Slang build configured with it set to 1, or a Linux/Windows host.
- **Loading:** `dlopen("dxcompiler")` (or a path set with
  `setDownstreamCompilerPath(SLANG_PASS_THROUGH_DXC, …)`). It tries `dxil`
  first but ignores failure, so no dxil stub is needed.
  `findFuncByName("DxcCreateInstance")`.
- **API used (legacy interfaces, so L1 is required):**
  - `IDxcCompiler` and `IDxcLibrary::CreateBlobWithEncodingFromPinned`
    (code page 0).
  - `IDxcCompiler::Compile(source, name, entry, profile, args, …, includeHandler)`
    with no defines.
  - On `IDxcOperationResult`: `GetStatus`, `GetResult`, `GetErrorBuffer`.
  - It queries `IDxcResult` from the operation result for `DXC_OUT_PDB` only
    when PDB output is requested.
- **Version probing decides the language version.** Slang calls
  `IDxcVersionInfo::GetVersion`, `IDxcVersionInfo2::GetCommitInfo`, and
  `IDxcVersionInfo3::GetCustomVersionString`, and adds `-HV 2021` only if the
  version is ≥ 1.7. The oracle reports `1.11(5583-f9fc72ad)`, so libzdxc should
  report 1.11. The strings returned by `GetCommitInfo` and
  `GetCustomVersionString` are freed by the client with `CoTaskMemFree`, which
  is `free` on Unix (`WinAdapter.h:47`) and `CoTaskMemAlloc` on Windows. **So
  libzdxc must allocate those with libc `malloc` / `CoTaskMemAlloc`, not a Zig
  allocator**, which means the shared library links libc.
- **Include handler blobs are not real DXC blobs.** Slang's `LoadSource`
  returns an `ISlangBlob` cast to `IDxcBlob*`. Only `GetBufferPointer` and
  `GetBufferSize` can be trusted, and `QueryInterface` for `IDxcBlobEncoding`
  fails. libzdxc must treat such blobs as raw bytes with BOM detection, never
  assume they are its own blob type, and never downcast. Slang also resolves
  includes itself from its search directories, so its handler is called with
  dxc's candidate paths.
- **Arguments:** `-Zpr`, `-Gis`, `-denorm <mode>`, `-O0..3`/`-Od`, `-Zi`,
  `-WX`, `-no-warnings` (always), `-enable-16bit-types`,
  `-enable/-disable-payload-qualifiers`, plus user pass-through. Profiles
  cover every stage, including `lib_6_x` for ray tracing.
- **Diagnostics:** Slang parses `ERRORS` as clang-style
  `file:line:col: error|warning: msg`. That is zdxc's `clang` format, which
  must stay the default for library output.
- **Optional extras:**
  - `IDxcLinker` (`RegisterLibrary` + `Link`), used only when linking
    precompiled DXIL modules. Slang then compiles the source as `lib_6_x`.
  - `IDxcCompiler::Disassemble`, used only for `-target dxil-asm`.

  Both are on the plan's dropped list; with them returning
  `REGDB_E_CLASSNOTREG` / `E_NOTIMPL`, ordinary single-module compiles still
  work.
- **Fit with the plan:** single-entry vs/ps/cs is M0.1. The rest of Slang's
  stage coverage follows the plan's later milestones (hs/ds, ms/as, then `lib_`
  at M0.5).

### Revised staging

1. **L0 + shadercross acceptance.** Build `test/clients/shadercross.sh`: build
   shadercross against a zdxc install tree, run its CLI over its test shaders
   for SPIR-V, DXIL (round-trip), and MSL, and compare with the same run
   against DXC (DXIL through `dxv`, SPIR-V through `spirv-val`, MSL text
   directly).
2. **L1 + Slang acceptance** on Linux, or a Slang built with
   `SLANG_ENABLE_DXIL_SUPPORT=1`. Corpus: `slangc -target hlsl` output from
   Slang's tests, compiled through both libraries.
3. Linker and disassembler only if Slang's precompiled-module or `dxil-asm`
   paths turn out to matter.

## Testing

An ABI harness under `test/capi/`, written in C++ and compiled with
`zig c++` against the DXC tree's `include/dxc/dxcapi.h` (read in place, not
vendored). It `dlopen`s a library by path and runs a fixed script: create each
CLSID, query each IID, compile the oracle corpus through `IDxcCompiler3` and
the legacy interface, use a logging include handler, and dump status, the
output kinds present, error text, and object bytes. Running it against
`build/lib/libdxcompiler.dylib` and against libzdxc, then diffing (objects
compared through `dxv`, as the CLI oracle already does), gives drop-in
compatibility the same oracle treatment as the CLI.

## Open questions

- Should `zig build` produce the drop-in name by default, or opt-in only?
- Acceptance order: SDL_shadercross first, then Slang (see above). hassle-rs
  and wgpu also use the legacy interfaces, so L1 for Slang covers them too
  (not yet verified against hassle-rs source).
- Shadercross's lookup needs a `dxcapi.h` to exist. Ship a placeholder, or
  install DXC's header? Its license (NCSA) allows redistribution, but the
  project rule only allows vendoring data files.
- Does any target need 32-bit Windows? That would force the `__thiscall`
  handling for the two `IDxcResult` methods.
