---
type: guide
order: 1
title: Introduction
---

zdxc is a from-scratch HLSL compiler written in Zig. It emits DXIL and
SPIR-V and has no package dependencies. The same compiler is available through
four interfaces:

| Interface | Use |
| --- | --- |
| `zdxc` | A dxc-style command-line compiler. |
| `libzdxc` | A small C API that returns compilation outputs in memory. |
| `zdxc` Zig module | Direct access to the compiler from a Zig build. |
| `dxc` / `dxcompiler` | Drop-in names and entry points for existing DXC clients. |

HLSL 2021 is the default language version. Select HLSL 2018 with `-HV 2018`;
`-HV 2016` and `-HV 2017` are also accepted with the same legacy operator
semantics. The language version is independent of the target shader model.

Compute shaders support thread groups, `groupshared` storage, and group
barriers. The DXIL backend also supports work graph node shaders in
`lib_6_8` libraries, SM 6.8 `Barrier()`, and `[WaveSize]` metadata. Work graph
nodes are not supported in SPIR-V. See the
[command-line guide](03-command-line.md) for language and work graph examples.

DXIL output is signed by zdxc itself, so no separate `dxil` library is needed.
