---
type: api
order: 5
title: zdxc_read_file_fn
kind: callback
line: 75
---

```c
typedef int (*zdxc_read_file_fn)(void *user, const char *path, const char **data, size_t *size);
```

Reads the main input or an `#include` candidate. On success, set `data` and
`size` and return 0. Return nonzero to let zdxc try the next candidate. The
returned bytes need only remain valid until `zdxc_compile` returns.
