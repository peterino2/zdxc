---
type: api
order: 9
title: zdxc_result_output
kind: function
line: 110
---

```c
const void *zdxc_result_output(const zdxc_result *result, zdxc_output output, size_t *size);
```

Returns the selected output's bytes, 4-byte aligned: a SPIR-V object can be
passed to `vkCreateShaderModule` as its `pCode` without copying. The bytes
are followed by a NUL for convenience; `size` does not count that terminator
and may be NULL. If the output was not produced, returns NULL and stores zero
in `size`.

The pointer remains valid until `zdxc_result_free`. Binary object outputs can
contain interior NUL bytes; always use the returned size.
