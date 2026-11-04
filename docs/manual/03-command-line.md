---
type: guide
order: 3
title: Command line
---

zdxc accepts dxc command-line arguments. A compilation can read its input from
a file or, through the library interfaces, from memory.

| Option | Meaning |
| --- | --- |
| `-T <profile>` | Target profile, such as `vs_6_0`, `ps_6_0`, or `cs_6_0`. |
| `-E <name>` | Shader entry point. |
| `-HV <version>` | HLSL language version: `2021` (default), `2018`, `2017`, or `2016`. |
| `-D <name[=value]>` | Define a preprocessor macro. |
| `-I <directory>` | Add an include search directory. |
| `-Fo <file>` | Write the object to a file. |
| `-Fi <file>` | Write preprocessed output when used with `-P`. |
| `-Frs <file>` | Write a root-signature container. |
| `-P` | Preprocess instead of compiling. |
| `-spirv` | Emit SPIR-V instead of DXIL. |
| `-Zpr` / `-Zpc` | Select row- or column-major matrix packing. |
| `-O0` … `-O3`, `-Od` | Select the optimization level. `-Od`, as in dxc, still promotes locals to SSA values and removes dead code, but does nothing else. |
| `--job=<file>` | Compile a JSON batch of shaders in one process. |

DXIL is the default backend. Add `-spirv` for SPIR-V, with the `-fvk-*` and
`-fspv-*` options controlling Vulkan bindings, layout, and target environment.

## HLSL language versions

Use `-HV 2018` when compiling shaders written for HLSL 2018:

```sh
zdxc -HV 2018 -T ps_6_0 -E main shader.hlsl -Fo shader.dxil
zdxc -HV 2018 -spirv -T ps_6_0 -E main shader.hlsl -Fo shader.spv
```

The default is `-HV 2021`. In the legacy modes (`2016`, `2017`, and `2018`),
`&&` and `||` evaluate both operands and operate component-wise on vectors;
numeric `?:` evaluates both branches and permits a vector condition to
select per component. In 2021 mode, logical operands and the conditional
test are scalar, and evaluation short-circuits. Code that relies on an
unevaluated expression to avoid side effects needs particular care when
switching to a legacy mode.

The preprocessor macro `__HLSL_VERSION` reflects the selected version.
`-HV` selects language semantics; `-T` independently selects the shader
stage and shader model. These options also work in batch jobs and through
the C API and DXC drop-in.

## Compute thread groups and work graphs

Compute shaders use `[numthreads(x, y, z)]` to declare their thread group
size, `groupshared` for group-local storage, and intrinsics such as
`GroupMemoryBarrierWithGroupSync()` for synchronization. Compile them with
a compute profile, for example `-T cs_6_0 -E main`, for DXIL or SPIR-V.

For DXIL, `[WaveSize]` is emitted in entry-point and runtime metadata,
including the minimum, maximum, and preferred sizes for SM 6.8 wave-size
ranges. SM 6.8's `Barrier()` supports memory flags, UAVs, and node records.

Work graphs use node shaders in a shader library. Compile with `-T lib_6_8`
and mark each node with `[Shader("node")]` and its `[NodeLaunch]` mode;
there is no single `-E` entry point for the library. The supported launch
modes are `broadcasting`, `coalescing`, and `thread`. Node input/output
records, record allocation and completion, dispatch grids, node IDs, and
`GetRemainingRecursionLevels()` are supported by the DXIL backend.

For example, save this broadcasting node as `node.hlsl`:

```hlsl
RWStructuredBuffer<uint> values : register(u0);

[Shader("node")]
[NodeLaunch("broadcasting")]
[NodeDispatchGrid(1, 1, 1)]
[numthreads(64, 1, 1)]
void Fill(uint3 id : SV_DispatchThreadID)
{
    values[id.x] = id.x;
}
```

```sh
zdxc -T lib_6_8 node.hlsl -Fo node.dxil
```

This produces a node shader library for a host application's work graph.
Work graph nodes are DXIL-only; compiling them with `-spirv` reports an
unsupported-feature error.

## Diagnostics and exit status

Diagnostics follow dxc's command-line format. Exit status is 0 for success,
1 for bad options or input/output failures, and 5 for source compilation
errors. Warnings can appear in successful compilations.
