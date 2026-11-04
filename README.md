<p align="center">
  <img src="docs/assets/logo.svg" width="100" alt="zdxc" />
</p>

<p align="center">
  <strong>A small, fast HLSL compiler. Built to shorten the edit–compile–run loop.</strong>
</p>

<p align="center">
  HLSL 2021 → DXIL / SPIR-V · Written in Zig · No LLVM dependency
</p>

<p align="center">
  <a href="https://zdxc.org">zdxc.org</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="https://zdxc.org/manual.html">Manual</a> ·
  <a href="docs/manual/">Manual source</a>
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
| About **15× faster compilation** in the Hyperion benchmark. | **4.2 MB** Windows drop-in, compared with **19.3 MB** for DXC plus its DXIL library. | A **static library** by default, with a C API and a native Zig module. |

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

## Documentation and downloads

Read the [manual on zdxc.org](https://zdxc.org/manual.html) for command-line
options, batch compilation, the C API, DXC drop-in support, and Zig integration.
The [manual Markdown sources](docs/manual/) live in this repository.

For an existing DXC integration, build the drop-in executable and shared library:

```sh
zig build dropin -Doptimize=ReleaseFast
```

Download Windows, Linux, and macOS bundles from a successful run's **Artifacts**
section on [GitHub Actions](https://github.com/peterino2/zdxc/actions).
Each bundle includes the CLI, static C library, header, and DXC drop-in.

See the [case studies](https://zdxc.org/case-studies.html) for benchmark
measurements and methodology. In Hyperion's Windows DXIL cook, zdxc's compile
step was **15.5× faster** and the complete shader cook was **2.5× faster**;
Unreal Engine 5.8's editor compiled its 11,156 startup shaders **4.3× faster**.

## Status

zdxc is **alpha software**, focused on HLSL 2021 (`-HV 2021`). DXC compatibility
is still being developed; not every DXC interface or feature is implemented.
The [drop-in manual](https://zdxc.org/manual.html#section-dxc-drop-in) documents
the current interface coverage.

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
