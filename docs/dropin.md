# The DXC drop-in

Programs that run DXC usually do it in one of two ways: they call the `dxc`
executable, or they load `dxcompiler` (`dxcompiler.dll`,
`libdxcompiler.so`, `libdxcompiler.dylib`) and call `DxcCreateInstance`.
SDL_shadercross, for one, does the second. The `dropin` step builds both on
top of zdxc, so these programs can use zdxc without being changed:

```sh
zig build dropin                # zig-out/bin/dxc, zig-out/lib/libdxcompiler.{so,dylib}
zig build dropin -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
                                # zig-out/bin/dxc.exe, dxcompiler.dll, lib/dxcompiler.lib
```

Put them where the program looks for DXC, in place of DXC's files. There is
no `dxil.dll`: zdxc signs DXIL itself.

- `dxc` is the zdxc command line under DXC's name.
- `dxcompiler` exports `DxcCreateInstance` and `DxcCreateInstance2`, with
  `dxcapi.h`'s ABI. On Windows it imports only `kernel32` and `ntdll`. On
  other platforms it links the C library and nothing else.

## What the library implements

| Class | Interfaces |
|---|---|
| `CLSID_DxcCompiler` | `IDxcCompiler3` (`Compile`), `IDxcVersionInfo` (reports 1.11) |
| `CLSID_DxcUtils` (also reached as `CLSID_DxcLibrary`) | `IDxcUtils`: blob creation, `LoadFile`, `CreateDefaultIncludeHandler`, `GetBlobAsUtf8` / `GetBlobAsWide`, `GetDxilContainerPart` |

`Compile` takes the same arguments as the command line and follows DXC:

- **Status.** A compile error is a successful call whose status is
  `E_FAIL`. A bad option has status `E_INVALIDARG`.
- **Outputs.** The result holds the same outputs DXC's does: the object,
  the errors (UTF-8, empty when there are none), the shader hash for DXIL,
  the root signature, `-P` text, and the names given with `-Fo`, `-Fi` and
  `-Frs`.
- **Includes.** Includes go through the `IDxcIncludeHandler` you pass,
  with paths spelled the way DXC spells them (`./inc/common.hlsli`). With no
  handler, includes fail, as they do in DXC.
- **Accepted-but-ignored options.** Options that zdxc accepts but does not
  act on yet produce no note here. Many clients treat any diagnostic text
  as a warning.

Classes and methods that are not implemented return `REGDB_E_CLASSNOTREG`
or `E_NOTIMPL`. These include:
- the legacy `IDxcCompiler` and `IDxcCompiler2` interfaces;
- `Disassemble`;
- `CreateReflection`, `BuildArguments` and `GetPDBContents`;
- the validator, linker, container and PDB classes.

The result has no `DXC_OUT_REFLECTION` output (the reflection container
that `CreateReflection` reads).

Language support is zdxc's own: HLSL 2021, with `-HV 2021` as the only
version.
