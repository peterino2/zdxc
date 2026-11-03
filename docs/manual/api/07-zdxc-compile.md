---
type: api
order: 7
title: zdxc_compile
kind: function
line: 99
---

```c
zdxc_result *zdxc_compile(const zdxc_compile_info *info);
```

Runs one compilation. It returns NULL only for an invalid or too-small
descriptor, or when memory is exhausted. Every compilation failure is reported
by the result's status and diagnostics.

The compiler has no global state. Independent calls may run concurrently on
any number of threads.
