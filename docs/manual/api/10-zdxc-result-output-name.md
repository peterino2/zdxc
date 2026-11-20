---
type: api
order: 10
title: zdxc_result_output_name
kind: function
line: 114
---

```c
const char *zdxc_result_output_name(const zdxc_result *result, zdxc_output output);
```

Returns the file name assigned by `-Fo`, `-Fi`, `-Frs`, `-MF`, or `-MD`, or NULL when the
output has no assigned name. zdxc does not write that file itself.
