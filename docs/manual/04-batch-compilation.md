---
type: guide
order: 4
title: Batch compilation
---

`zdxc --job=build/shaders.json` compiles every shader a job file lists in
one process, on all cores. Starting a process costs more than compiling most
shaders (about 2 ms against a few hundred microseconds), so a build with many
shaders is much faster this way than with one compiler run per shader.

On the 1,481 corpus shaders zdxc compiles (10-core M-series Mac, release
build):

| How                                         | Wall time |
| ------------------------------------------- | --------: |
| `zdxc --job`, all cores                     |  0.064 s  |
| `zdxc --job`, `"threads": 1`                |  0.24 s   |
| one `zdxc` per shader, 10 in parallel       |  1.09 s   |
| one `dxc` per shader, 10 in parallel        |  1.68 s   |

## The job file

```json
{
  "threads": 8,
  "args": ["-HV", "2021", "-I", "shaders/include"],
  "jobs": [
    { "args": ["-T", "cs_6_0", "shaders/blur.hlsl", "-Fo", "out/blur.dxo"] },
    { "args": ["-T", "ps_6_0", "-E", "PS", "shaders/mesh.hlsl", "-Fo", "out/mesh_ps.dxo"] },
    { "args": ["-T", "vs_6_0", "-E", "VS", "-spirv", "shaders/mesh.hlsl", "-Fo", "out/mesh_vs.spv"] }
  ]
}
```

- `jobs` (required): each job's `args` is a dxc command line without the
  program name — any option zdxc accepts on its own command line.
- `args` (optional): options shared by every job.
- `threads` (optional): how many shaders compile at once. Defaults to the
  number of CPUs.

A job's full command line is the file's `args`, then any options given next
to `--job` on the real command line, then the job's own `args`. So
`zdxc --job=shaders.json -O3 -Qstrip_debug` adds `-O3 -Qstrip_debug` to every
job, and a job can override a shared option where a later option wins on the
command line. Unknown fields are errors, reported with their line and column.

Paths in the file are relative to the current directory, as on the command
line, not to the job file. `--job` cannot appear inside a job file.

## Output and exit code

Every job writes its own `-Fo` / `-Fh` / ... outputs. What a job prints —
diagnostics, and text output such as `-P` without a file — comes out
exactly as one zdxc run of that command line would print it, kept together
and in job order, whatever order the jobs finish in. The outputs are
byte-identical to separate runs.

When jobs fail, the other jobs still run, and a last line says how many
failed:

```text
zdxc: 2 of 112 jobs failed
```

The exit code is 0 when every job succeeds; otherwise 1 if any job failed
on its command line or on I/O (a missing input, an unwritable output), else
5 (compile errors) — the codes one zdxc run uses.

Reading and writing files is kept off the compiling threads: one thread
reads the jobs' input files ahead of the compiles, and another writes
their outputs after them. Files the jobs include are read once for the
whole run, so a header that every shader includes is opened once (a file
that changes while the run is going is not read again). An output that
cannot be written is reported after every job's output, and fails its job.
