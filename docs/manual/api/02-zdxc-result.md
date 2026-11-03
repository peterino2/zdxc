---
type: api
order: 2
title: zdxc_result
kind: type
line: 43
---

```c
typedef struct zdxc_result zdxc_result;
```

An opaque compilation result. It owns the object, diagnostics, and other
outputs returned by `zdxc_compile`. Read its outputs with
`zdxc_result_output` and release it with `zdxc_result_free`.
