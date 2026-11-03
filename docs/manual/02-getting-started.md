---
type: guide
order: 2
title: Getting started
---

```quickstart
{
  "title": "Quick start",
  "tabs": [
    {
      "label": "Download",
      "steps": [
        {"title": "Get the bundle", "code": "unzip zdxc-VERSION-PLATFORM.zip && cd zdxc-VERSION-PLATFORM", "text": "Download it for your platform from the [releases](https://github.com/peterino2/zdxc/releases). `bin/` holds `zdxc` and the DXC drop-in; `lib/` and `include/` hold `libzdxc` and `zdxc.h`."},
        {"title": "Drop in for DXC", "code": "cp bin/dxc* bin/*dxcompiler* ENGINE/bin/", "text": "Put `dxc` and `dxcompiler` where your engine looks for DXC's. There is no `dxil.dll` to copy."},
        {"title": "Compile a shader", "code": "bin/zdxc -T ps_6_0 -E main shader.hlsl -Fo shader.dxil", "text": "dxc's command line. Add `-spirv` for SPIR-V, or compile many shaders at once with `--job`."}
      ],
      "links": [
        {"href": "https://github.com/peterino2/zdxc/releases", "label": "Releases"}
      ]
    },
    {
      "label": "Build from source",
      "steps": [
        {"title": "Get the source", "code": "git clone https://github.com/peterino2/zdxc.git && cd zdxc", "text": "One Zig codebase with no dependencies."},
        {"title": "Build", "code": "zig build -Doptimize=ReleaseFast", "text": "Needs Zig 0.17 and nothing else. You get `zdxc`, `libzdxc.a` and `zdxc.h` in `zig-out`."},
        {"title": "Drop in for DXC", "code": "zig build dropin -Doptimize=ReleaseFast", "text": "Builds `dxc` and `dxcompiler`. Put them where your engine looks for DXC's; there is no `dxil.dll` to copy."},
        {"title": "Compile a shader", "code": "zig-out/bin/zdxc -T ps_6_0 -E main shader.hlsl -Fo shader.dxil", "text": "dxc's command line. Add `-spirv` for SPIR-V, or compile many shaders at once with `--job`."}
      ],
      "links": [
        {"href": "https://github.com/peterino2/zdxc", "label": "Source on GitHub"}
      ]
    }
  ]
}
```

## Requirements

Install Zig 0.17.0 or newer. zdxc has no library or package dependencies.

## Build

Run the build from the zdxc package directory:

```sh
zig build -Doptimize=ReleaseFast
```

The default install contains:

```text
zig-out/bin/zdxc          command-line compiler
zig-out/lib/libzdxc.a     static C library
zig-out/include/zdxc.h    public C header
```

Build a shared C library instead with `-Dlinkage=dynamic`. Cross-compilation
uses Zig's usual target option:

```sh
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
```

## Compile a shader

The command line follows dxc. Specify a target profile, entry point, input,
and output file:

```sh
./zig-out/bin/zdxc -T cs_6_0 -E main shader.hlsl -Fo shader.dxil
./zig-out/bin/zdxc -T vs_6_0 -E main -spirv shader.hlsl -Fo shader.spv
```

Use `zdxc -help` for the complete option list and `zdxc --version` for the
compiler version.
