---
type: api
order: 13
title: zdxc_result_free
kind: function
line: 126
---

```c
void zdxc_result_free(zdxc_result *result);
```

Releases a result and all of its outputs. Any output pointers previously
obtained from it become invalid.
