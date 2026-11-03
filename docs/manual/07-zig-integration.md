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
