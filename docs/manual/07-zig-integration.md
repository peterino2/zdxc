---
type: guide
order: 7
title: Zig integration
---

Declare zdxc as a package dependency, then make its module available to your
executable or library:

```zig
const zdxc = b.dependency("zdxc", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zdxc", zdxc.module("zdxc"));
```

Import the module and call the same compilation layer used by the command line
and C API:

```zig
const std = @import("std");
const zdxc = @import("zdxc");

pub fn compileShader(arena: std.mem.Allocator, io: std.Io, source: []const u8) !zdxc.compile.Result {
    return zdxc.compile.compile(arena, .{
        .args = &.{ "-T", "ps_6_0", "-E", "PS", "-D", "SHADOWS=1" },
        .source = source,
        .source_name = "mesh.hlsl",
        .io = io,
    });
}
```

The returned result contains the status, object, diagnostics, and any requested
auxiliary outputs. Its allocations belong to the supplied arena. The compiler
does not write files; `-Fo`, `-Fi`, and `-Frs` only name the corresponding
in-memory outputs.

Every result also lists the files the compilation depends on in
`dependencies`: the main file first, then each `#include` once, in the order
first included. An include that was not found is listed as spelled, with
`missing` set. Compiled-in headers are left out. The list is filled after
compile errors too, so a file watcher or build cache still knows what to watch
when a build fails, including the header whose absence failed it:

```zig
const result = try compileShader(arena, io, source);
for (result.dependencies) |dep| try watcher.add(dep.path);
```

With `-M`, `-MD`, or `-MF`, the compiler only preprocesses, and
`dependency_rule` holds dxc's make rule, named by `dependency_rule_name`. As in
dxc, the rule also lists includes that were not found (as spelled) and is given
after preprocessing errors too.
