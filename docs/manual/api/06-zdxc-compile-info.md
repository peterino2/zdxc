---
type: api
order: 6
title: zdxc_compile_info
kind: struct
line: 77
---

```c
typedef struct zdxc_compile_info {
    uint32_t size;
    const char *const *args;
    size_t arg_count;
    const char *source;
    size_t source_size;
    const char *source_name;
    zdxc_read_file_fn read_file;
    void *user;
} zdxc_compile_info;
```

Describes one in-memory or file-based compilation. Initialize `size` to
`sizeof(zdxc_compile_info)` so later API versions can add fields.

### size

The structure size in bytes; use `sizeof(zdxc_compile_info)`.

### args

dxc command-line options without the program name.

### arg_count

Number of arguments in `args`.

### source

The main source text, or NULL to read the named input file.

### source_size

Source byte length; a trailing NUL is allowed.

### source_name

Name used in diagnostics and relative include resolution.

### read_file

Optional file callback; NULL reads from disk.

### user

Opaque pointer passed to `read_file`.
