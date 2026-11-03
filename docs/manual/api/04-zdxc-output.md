---
type: api
order: 4
title: zdxc_output
kind: type
line: 54
---

```c
typedef enum zdxc_output {
    ZDXC_OUTPUT_OBJECT = 0,
    ZDXC_OUTPUT_DIAGNOSTICS = 1,
    ZDXC_OUTPUT_PREPROCESSED = 2,
    ZDXC_OUTPUT_ROOT_SIGNATURE = 3,
    ZDXC_OUTPUT_TEXT = 4
} zdxc_output;
```

Selects one output from a compilation result.

### ZDXC_OUTPUT_OBJECT

The DXIL container or SPIR-V module.

### ZDXC_OUTPUT_DIAGNOSTICS

Errors, warnings, and notes in command-line format.

### ZDXC_OUTPUT_PREPROCESSED

Preprocessed source requested with `-P`.

### ZDXC_OUTPUT_ROOT_SIGNATURE

The root-signature container requested with `-Frs`.

### ZDXC_OUTPUT_TEXT

Other command-line text, such as `-help` or `--version`.
