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

## Diagnostics and exit status

Diagnostics follow dxc's command-line format. Exit status is 0 for success,
1 for bad options or input/output failures, and 5 for source compilation
errors. Warnings can appear in successful compilations.
