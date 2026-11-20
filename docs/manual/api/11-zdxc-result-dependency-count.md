---
type: api
order: 11
title: zdxc_result_dependency_count
kind: function
line: 121
---

```c
size_t zdxc_result_dependency_count(const zdxc_result *result);
```

Returns the number of files the compilation depends on: the main file first,
then each `#include` once, in the order first included, the same list that `-M`
prints. An include that was not found is counted too and is marked by
`zdxc_result_dependency`. Preprocessing stops at a missing include, so later
includes are not listed until it is found. Compiled-in headers are not counted.
Unlike `ZDXC_OUTPUT_DEPENDENCIES`, the list is filled by every
compilation, without `-M`, and also after a compile error once the input was
read, so a failed build still knows which files to watch. Available since API
version 2.
