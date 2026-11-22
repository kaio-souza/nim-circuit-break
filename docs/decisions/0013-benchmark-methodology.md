# ADR-0013: Benchmark methodology

- Status: Accepted
- Date: 2026-11-19
- Requirements: R1, R4, P6, P7, EV2, EV6

## Context

Performance numbers are only worth something if they are reproducible and measure allocations, not just time. Shared CI runners are noisy, which makes fixed-limit timing gates prone to false positives.

## Decision

- Own harness in `benchmarks/harness.nim`, no dependencies: warm-up, 30 samples, median, p95, p99 and minimum; optional JSON output (`BENCH_JSON_DIR`); a volatile `keep` variable stops the compiler from eliminating the measured code.
- Flags: `-d:release --opt:speed --threads:on`.
- **Timings measured with ORC** (Nim's default). **Allocations measured with ARC** and `-d:nimAllocStats`: in Nim 2.2.4, ORC with `-d:nimAllocStats` crashes when re-raising exceptions (minimal reproduction in [`docs/upstream/repro_orc_allocstats.nim`](../upstream/repro_orc_allocstats.nim)). ARC and ORC make the same allocations in this code, which creates no cycles.
- The suite also runs compiled with `-d:cbDisabled` to measure the baseline cost.
- In CI, the benchmark workflow is **informational**: it publishes the numbers in the job summary and never fails. The regression gate (R4) measures base and PR in the same job: see [ADR-0020](0020-performance-regression-gate.md).
- The README publishes the numbers with date, hardware, Nim version and flags.

## Consequences

- Laptop numbers vary between runs; comparisons are valid on the same machine.
- Until R4 exists, timing regressions are caught in review, not automatically.

## Evidence

`nimble bench`; BM0–BM9 in `benchmarks/`. README table (2026-11-19, Intel Core i5-10210U).
