<p align="center">
  <img src="docs/assets/logo.svg" width="320" alt="zdxc" />
</p>

<p align="center">
  <strong>A small, fast HLSL compiler. Built to shorten the edit–compile–run loop.</strong>
</p>

<p align="center">
  HLSL 2021 → DXIL / SPIR-V · Written in Zig · No LLVM dependency
</p>

<p align="center">
  <a href="#quick-start">Quick start</a> ·
  <a href="docs/dropin.md">DXC drop-in</a> ·
  <a href="docs/c-api.md">C API</a> ·
  <a href="docs/batch.md">Batch compilation</a>
</p>

---

zdxc is an HLSL 2021 compiler written from scratch in Zig. It emits DXIL and
SPIR-V, supports DXC-style command lines, and provides a DXC-compatible COM
interface for existing engine integrations.

Use it as a development drop-in replacement for DXC, link its small C API directly,
or import it as a Zig module. The compiler has no package dependencies and
signs its own DXIL, so there is no separate `dxil.dll` to ship.

| Fast iteration | Small footprint | Easy to embed |
| :--- | :--- | :--- |
| About **14× faster compilation** in the Hyperion benchmark below. | **4.2 MB** Windows drop-in, compared with **19.3 MB** for DXC plus its DXIL library. | A **static library** by default, with a C API and a native Zig module. |

## Quick start

Requires **Zig 0.17**. Build the command-line compiler and library:

```sh
git clone https://github.com/peterino2/zdxc.git
cd zdxc
zig build -Doptimize=ReleaseFast
```

Compile the same shader to either backend:

```sh
# DirectX / DXIL
zig-out/bin/zdxc -T ps_6_0 -E main shader.hlsl -Fo shader.dxil

# Vulkan / SPIR-V
zig-out/bin/zdxc -spirv -T ps_6_0 -E main shader.hlsl -Fo shader.spv
```

The build installs the compiler in `zig-out/bin/`, the library in
`zig-out/lib/`, and the public header in `zig-out/include/`.

### Automated builds

Pushes to `main` run the [cross-platform build workflow](.github/workflows/build.yml)
with Zig 0.17.0. It cross-compiles ReleaseFast builds on Linux for Windows x86-64,
Linux x86-64 (glibc 2.28 or newer), and macOS 13 or newer on both Apple Silicon
and Intel. Each artifact contains the CLI, static C library, header, and DXC
drop-in. These are build checks; they do not run the binaries on each target OS.

Download the `.tar.gz` bundles from a successful run's **Artifacts** section
on [GitHub Actions](https://github.com/peterino2/zdxc/actions). Artifacts are
retained for 14 days. The workflow can also be started manually.

## Use it your way

### Replace DXC in an existing integration

```sh
zig build dropin -Doptimize=ReleaseFast
```

This builds `dxc` and the platform's `dxcompiler` shared library. Place them
where your application looks for DXC. The library exports `DxcCreateInstance`
and `DxcCreateInstance2`, including support for `IDxcCompiler3::Compile`.

See the [drop-in guide](docs/dropin.md) for supported interfaces and behavior.

### Link the compiler into your application

The default build produces a static library with a [small C API](docs/c-api.md).
Pass source and options in; get compiled objects and diagnostics back in
memory. Supply an include callback to integrate with your own filesystem.

Prefer a shared library? Build with `-Dlinkage=dynamic`. Zig projects can
import the `zdxc` module and supply an allocator directly to the compilation
API.

### Compile a whole batch

```sh
zig-out/bin/zdxc --job=shaders.json
```

Compile many shaders in one process, with parallel workers and output files
specified per job. See the [batch guide](docs/batch.md) for the JSON format
and threading options.

## Performance in an engine

In a Windows DXIL benchmark, Hyperion cooked Glide's 2,688 shader assets
using either DXC or zdxc through the engine's existing compiler interface.
The machine used a Ryzen 9 7900 with 24 threads; the DXC version was 1.8.2505.

| Measurement | DXC | zdxc | Speedup |
| :--- | ---: | ---: | ---: |
| Complete shader cook, wall time | 58.9 s | 23.2 s | **2.5×** |
| Compile step, summed across workers | 241.3 s | 17.4 s | **13.9×** |
| Median compile call | 12.6 ms | 1.0 ms | **12.7×**¹ |

¹ Ratios use the unrounded measurements.

These are measurements of one engine workload, not a universal speedup.
The complete cook includes preprocessing and asset processing, so its
improvement is smaller than the compile step's. Both builds rendered the
same tested scene; compilation throughput is separate from GPU performance.

## Status

zdxc is **alpha software**, focused on HLSL 2021 (`-HV 2021`). DXC compatibility
is still being developed; not every DXC interface or feature is implemented.
The [drop-in guide](docs/dropin.md) documents the current interface coverage.

To run the unit tests:

```sh
zig build test
```

If you find a problem, [open an issue](https://github.com/peterino2/zdxc/issues)
with a minimal shader, the compiler arguments, your platform, and the
expected result.

---

Created by [Peterino](https://peterino.com) as an experiment in agentic
engineering. Open source, MIT licensed.
