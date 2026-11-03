---
type: guide
order: 1
title: Introduction
---

zdxc is a from-scratch HLSL 2021 compiler written in Zig. It emits DXIL and
SPIR-V and has no package dependencies. The same compiler is available through
four interfaces:

| Interface | Use |
| --- | --- |
| `zdxc` | A dxc-style command-line compiler. |
| `libzdxc` | A small C API that returns compilation outputs in memory. |
| `zdxc` Zig module | Direct access to the compiler from a Zig build. |
| `dxc` / `dxcompiler` | Drop-in names and entry points for existing DXC clients. |

The source language is HLSL 2021; `-HV 2021` is the only language version.
DXIL output is signed by zdxc itself, so no separate `dxil` library is needed.
