---
type: api
order: 3
title: zdxc_status
kind: type
line: 46
---

```c
typedef enum zdxc_status {
    ZDXC_STATUS_OK = 0,
    ZDXC_STATUS_FAILED = 1,
    ZDXC_STATUS_COMPILE_FAILED = 5
} zdxc_status;
```

A compilation's outcome. The values match dxc's command-line exit codes.

### ZDXC_STATUS_OK

Compilation succeeded. Diagnostics may still contain warnings.

### ZDXC_STATUS_FAILED

Bad options or an input that could not be read.

### ZDXC_STATUS_COMPILE_FAILED

The source contains compilation errors.
