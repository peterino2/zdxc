# The C API: libzdxc

zdxc is also a library with a small C API, [`include/zdxc.h`](../include/zdxc.h).
Unlike dxcompiler, it links statically: there is no DLL to ship or load, no
COM, and nothing to link besides the platform's C library.

```sh
zig build                       # zig-out/lib/libzdxc.a, zig-out/include/zdxc.h
zig build -Dlinkage=dynamic     # libzdxc.so / .dylib / zdxc.dll instead
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
```

Link `libzdxc.a` like any static library (`cc app.c -Izig-out/include
zig-out/lib/libzdxc.a`). It exports
only the `zdxc_*` functions; the compiler runtime it carries is hidden. For
a macOS binary you ship, give the target a minimum version
(`-Dtarget=aarch64-macos.13.0`), or the linker warns that the library was
built for a newer macOS than the app.

## Compiling

A compilation is a dxc command line, with the outputs returned in memory:

```c
#include <zdxc.h>

const char *args[] = {"-T", "ps_6_0", "-E", "PS", "-D", "SHADOWS=1"};
zdxc_compile_info info = {
    .size = sizeof info,
    .args = args,
    .arg_count = 6,
    .source = text,
    .source_size = text_size,
    .source_name = "mesh.hlsl",
};
zdxc_result *r = zdxc_compile(&info);
if (!r) return OUT_OF_MEMORY;

const char *diags = zdxc_result_output(r, ZDXC_OUTPUT_DIAGNOSTICS, NULL);
if (diags) fputs(diags, stderr);            /* errors, or warnings on success */

if (zdxc_result_status(r) == ZDXC_STATUS_OK) {
    size_t size;
    const void *dxil = zdxc_result_output(r, ZDXC_OUTPUT_OBJECT, &size);
    upload(dxil, size);
}
zdxc_result_free(r);
```

- **Options** are exactly the command line's (`-T`, `-E`, `-D`, `-I`,
  `-spirv`, `-fvk-*`, `-Zpr`, `-O3`, ...), without the program name.
- **The source** is in memory (`source`, with or without a trailing NUL),
  or, when `source` is NULL, the input file named in the options.
- **Files** — the input when given by name, and every `#include` candidate —
  are read from disk relative to the current directory, unless you pass a
  `read_file` callback. The callback gets each candidate path (the
  including file's directory, then each `-I` directory) and returns 0 with
  the file's bytes, or nonzero to try the next candidate. Returned memory
  only has to last until `zdxc_compile` returns.
- **Status** is `ZDXC_STATUS_OK` (0), `ZDXC_STATUS_FAILED` (1: bad options,
  unreadable input) or `ZDXC_STATUS_COMPILE_FAILED` (5: errors in the
  source) — the command line's exit codes. `zdxc_compile` returns NULL only
  when out of memory.
- **Outputs** are `OBJECT` (a DXIL container or SPIR-V module),
  `DIAGNOSTICS`, `PREPROCESSED` (`-P`), `ROOT_SIGNATURE` (`-Frs`) and `TEXT`
  (`-help`, `--version`). Each is NUL-terminated for convenience and lives
  until `zdxc_result_free`. `zdxc_result_output_name` gives the name an
  option assigned (`-Fo`, `-Fi`, `-Frs`); zdxc never writes files.

The output is byte-for-byte what the command line writes for the same
options and files.

## Threads

zdxc has no global state. Any number of threads may call `zdxc_compile` at
once, and a result may be read or freed on any thread.

## Zig

Zig projects can skip the C API: depend on this package and import the
`zdxc` module, whose `compile.compile(arena, request)` is what the C API
wraps.
