---
type: api
order: 12
title: zdxc_result_dependency
kind: function
line: 124
---

```c
const char *zdxc_result_dependency(const zdxc_result *result, size_t index, int *missing);
```

Returns the path of dependency `index`, as the compiler read it (relative paths
stay relative, without a leading `./`), or NULL when `index` is out of range.
If `missing` is not NULL, it is set to 1 when the dependency is an include that
was not found, and to 0 otherwise. A missing include's path is its spelling in
the `#include`, not a file that was searched for. Watch it anyway, or watch the
include directories, so that the build reruns when the file appears. The string
remains valid until `zdxc_result_free`. Available since API version 2.
