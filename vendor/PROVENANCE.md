# Vendored data

zdxc vendors **data files only** from the DXC tree (never C++ sources).
Each entry records the source path and the DXC commit it was copied from.

| File | Source in DXC | DXC commit | License |
|---|---|---|---|
| `dxc/HLSLOptions.td` | `include/dxc/Support/HLSLOptions.td` | d02056da2 | University of Illinois/NCSA (DXC) |
| `hlsl-headers/` (all files) | `tools/clang/lib/Headers/hlsl/` | ecb18fb18 | Apache-2.0 WITH LLVM-exception (`hlsl-headers/LICENSE.txt`) |

DXC is distributed under the University of Illinois/NCSA license (LICENSE.TXT
in the DXC tree); SPIRV-Headers files are under the Khronos MIT-style license.
