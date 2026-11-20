# Draft issue for nim-lang/Nim (not yet filed)

**Title:** ORC with `-d:nimAllocStats` segfaults in `registerCycle` when an exception is re-raised

**Environment:** Nim 2.2.4 (Linux amd64), `--mm:orc`.

**Reproduction:** [`repro_orc_allocstats.nim`](repro_orc_allocstats.nim)

```
nim c -r -d:release --mm:orc -d:nimAllocStats repro_orc_allocstats.nim
```

**Expected:** prints `survived`.

**Actual:** `SIGSEGV: Illegal storage access. (Attempt to read from nil?)`, in `registerCycle`.

**Scope:** the same program prints `survived` without `-d:nimAllocStats`, and with
`--mm:arc` (with or without the flag). The crash needs a generic proc that catches
a `CatchableError`, uses the exception, and re-raises it, called from a loop of
`try`/`except` blocks.

**Workaround in use:** the benchmark suite of nim-circuit-breaker runs the
allocation counts with `--mm:arc -d:nimAllocStats`
(see the `bench` task in `circuit_breaker.nimble`).
