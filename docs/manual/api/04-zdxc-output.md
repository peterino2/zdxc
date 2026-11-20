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
    ZDXC_OUTPUT_TEXT = 4,
    ZDXC_OUTPUT_DEPENDENCIES = 5
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

### ZDXC_OUTPUT_DEPENDENCIES

The includes, as dxc's make rule, requested with `-M`, `-MD`, or `-MF`. These
options preprocess only, so there is no object. As in dxc, preprocessing goes on
after errors, an include that was not found is listed as spelled, and the rule
is present even when the status is `ZDXC_STATUS_COMPILE_FAILED`. Its name is the
`-MF` file or, for `-MD`, the input path up to its last `.` plus `.d` (dxc's
naming: `dir.v2/shader` gives `dir.d`). For the list of files read, without
`-M`, use `zdxc_result_dependency`.
