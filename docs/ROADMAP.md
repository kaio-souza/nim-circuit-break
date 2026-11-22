# Roadmap

Updated 2026-11-20. IDs refer to [`SPEC.md`](SPEC.md); the detailed status of each one is in [`TRACEABILITY.md`](TRACEABILITY.md).

Legend: [x] done · [ ] pending · [~] deferred

## Where we are

**v0.3.0 is released** (tag `v0.3.0`). v0.2.0 was the full rewrite of v0.1; v0.3.0 adds observability (latency percentiles, Prometheus, logging), the model test, a correctness fix for `FailureRate`, and performance work on rejections and multi-threaded use. Next: the work toward v1.0 below; releases are cut for large sets of changes, not per phase.

| Indicator | Value |
|---|---|
| Requirements in the matrix | 116 |
| Done or partial (with tests) | 93 (89 done, 4 partial; 23 deferred, none pending) |
| Tests | 90, all passing |
| Value tests | 9 (`tests/t_values.nim`, O4, O6) |
| Model and differential tests | proptest model (1000 sequences), lean-path differential (600 sequences) |
| Benchmarks | BM0–BM12 (`nimble bench`) |
| `call` in `Closed` | 28–37 ns/op (minimum of interleaved runs), 0 allocations (P7 target: < 50 ns) |
| Rejection (`tryAcquire`) | about 22 ns `ForcedOpen`, about 31 ns `Open`; below a success |
| Dependencies | none beyond the standard library (proptest for tests only) |

## v0.2.0: delivered

### Core
- [x] Fixed state machine, with regression tests for the v0.1 bugs (S1–S8, F1, T2, A11)
- [x] Injectable monotonic clock and public `FakeClock` (T1, T6, V1, N9)
- [x] Validated config with documented defaults; `CircuitOpenError` with `retryAfter` (K1, K2, A3, E5)
- [x] `call`, `tryCall`, `callOr`, `void` support, original error propagated (A1–A4, A6)

### Ergonomics and robustness
- [x] `Permit` guard with automatic recording and forbidden copies (E2, E4)
- [x] `withBreaker` without a closure (E3, A7)
- [x] Error and result classifiers; `Defect` does not count (F5–F8)
- [x] Exponential backoff, jitter that only delays, server `Retry-After` hints (T3, T4, G5)
- [x] `reset`, `forceOpen`, `disable`, read-only getters (A9, A10)

### Policies and observability
- [x] Failure rate over a count or time window, O(1) and fixed memory (F2, F3, P3)
- [x] Slow calls (F4)
- [x] Transition and call events, isolated from exceptions (O1–O3, B1)
- [x] `metrics()`, `explain()`, `report()` (B2, B4, N10)
- [x] Shadow mode, `diagnose`, `reconfigure` (N1, N8, N4)

### Concurrency, performance, async and keys
- [x] Atomic state; lock-free success with the consecutive policy; short lock on transitions (C1–C3)
- [x] `-d:cbDisabled`: zero-cost pass-through (N3)
- [x] `callAsync` for `std/asyncdispatch` (Y1)
- [x] `KeyedBreaker` with a capacity cap and LRU eviction (N2)

### Evidence and infrastructure
- [x] orc/arc × threads × release/debug matrix with no failures
- [x] 8-thread stress test (1000 consecutive runs without failure), ThreadSanitizer clean
- [x] AddressSanitizer clean (API, values, transitions, keyed, core benchmark)
- [x] Traceability matrix checked by a script (`nimble trace`)
- [x] CI and benchmark workflows, README, 3 examples, CHANGELOG, LICENSE
- [x] Technical decisions recorded as ADRs ([`decisions/`](decisions/README.md))

## Publishing v0.2.0: done

- [x] Workflows trigger on `master`, the local branch (the rename to `main` is no longer needed)
- [x] First commit and push to GitHub
- [x] First real CI run (validates the `nimlang/nim:2.2.4` image and `nimble test` with a commit)
- [x] Replace `<repository-url>` in the README with the real URL
- [x] Tag `v0.2.0` and date it in the CHANGELOG
- [~] Publish to the `nim-lang/packages` index (name `circuit_breaker`, tags in `packages.json`): deferred until the library is more mature; installing from the git URL and tag works meanwhile

## v0.3.0: delivered (close performance, proof and observability gaps)

- [x] V2/Q5: model test (random sequences compared against a reference model), `tests/t_model.nim` with proptest stateful testing
- [~] P2: success recording with the `FailureRate` policy. Measured first: the lock was about 7 ns of 56 ns; most of the rest was event bookkeeping paid even without callbacks. Done instead: a lean locked success path when no callback is set (56 to 45 ns; BM1 FailureRate -8% min, slow-call path -6% min), checked against the general path by a differential test (`tests/t_lean_path.nim`, 600 random sequences). A lock-free window is not pursued: the remaining lock cost does not justify it
- [x] BM3: lock-free rejection. `ForcedOpen` needs no clock (53 to 22 ns); `Open` uses the coarse monotonic clock on Linux when the deadline is more than 20 ms away, the precise clock otherwise (about 31 ns). Both are now below a success (about 39 ns). Also inlined the `Permit` destructor (10 to 2.5 ns per permit). An earlier attempt was measured wrongly: the benchmark used `ForcedOpen`, which that attempt did not cover
- [x] P5/R3: fields grouped by access pattern with 64-byte padding between hot groups, checked at compile time. BM2 median per call: -31% at 2 threads, -44% at 4, -45% at 8; unchanged at 1. Cost: 256 bytes per breaker. The first measurement, called inconclusive, came from a noisy method
- [x] O4: latency percentiles (p50/p95/p99) in metrics, opt-in via `latencyPrecision`
- [x] O6/B3: Prometheus/OpenMetrics exporter in a separate module (no dependency in the core), exposes the O4 metrics
- [x] O7: optional `std/logging` hook over the transition callback (call events not logged, to avoid noise)
- [x] I1: composition guide with retry, backoff, bulkhead and timeout (`docs/COMPOSITION.md`, `examples/composition.nim`)
- [~] Report the ORC + `-d:nimAllocStats` crash upstream: reproduced on Nim 2.2.4, issue drafted in [`upstream/ISSUE-orc-allocstats.md`](upstream/ISSUE-orc-allocstats.md), not yet filed (waiting for review)

## Toward v1.0: async, documentation and platforms

Detailed plan, audit of gaps and open decisions: [`PLAN.md`](PLAN.md). The phases organize the work; they are not releases.

Phase A, documentation debt:
- [x] Matrix rows for D1–D8; `check_traceability` fails when a SPEC ID has no row
- [x] D3: 100% of the public API documented (97 of 97), checked in CI (`nimble doccheck`)
- [x] README updated for v0.3 (features, transition table, performance per SPEC 27.3 with the lowest of 8 runs, quality; ThreadSanitizer re-run on v0.3.0)

Phase B, async:
- [x] Y2: Chronos support in a separate module (closes A5), [ADR-0016](decisions/0016-chronos-cancellation-and-timeouts.md)
- [x] Y3: safety under `Future` cancellation (Chronos; not counted by default)
- [x] T5: per-call timeout for the async APIs (`callTimeout`); finished calls arm no timer

Phase C, CI and evidence:
- [x] Q6: CI on macOS and Windows, Nim `devel`
- [x] Zero-warnings gate in the four build modes plus `cbDisabled` (v1.0 criterion 2); also ThreadSanitizer on the concurrency tests
- [x] README quickstart built in CI after `nimble install` (D1, v1.0 criterion 5)
- [x] Q7: code coverage report (gcc + lcov); a minimum is set after the first CI value
- [x] Nightly 1000 runs of the model and concurrency tests (v1.0 criterion 4); it still has to pass once on GitHub

Phase D, performance gate:
- [x] R4: benchmark regression gate, [ADR-0020](decisions/0020-performance-regression-gate.md); limit still to be calibrated on GitHub's runners

Phase E, documentation and examples:
- [x] D3: publish `nim doc` (GitHub Pages) on tags; needs the owner to enable Pages
- [x] D4: parameter selection guide and pitfalls (`TUNING.md`)
- [x] D5: database, metrics, fallback and Chronos examples
- [x] I4/D8: concept equivalence table (`EQUIVALENCE.md`); library versions to re-check before v1.0

Decisions:
- [x] P2 (P0): amended by [ADR-0015](decisions/0015-lean-locked-path-for-windowed-policies.md) (D-1)
- [x] `devel` informational, Windows and macOS blocking (D-2); coverage reported first (D-3); equivalence libraries chosen (D-6)
- [ ] Owner: enable GitHub Pages (D-4) and file the upstream ORC issue (D-5)

## v1.0: acceptance criteria

As in SPEC §13: every P0 and P1 implemented and tested; zero warnings on orc/arc with and without threads; benchmarks published; model and concurrency tests stable (1000 runs); quickstart validated in CI; public API 100% documented.

## Post-1.0 (deferred, on demand)

- [~] F9 pluggable policy, A13 registry, N11 breaker groups
- [~] A14 bulkhead (composition preferred, [ADR-0001](decisions/0001-scope-circuit-breaker-only.md))
- [~] G6 gradual recovery (ramp-up), G7 active probe
- [~] B5 tracing
- [~] I2 HTTP/web adapters, I3 C API, Y4/N12 JS/WASM targets
- [~] N5 distributed state, N6 priorities, N7 SLO-based threshold
- [~] K4 JSON config, V4 fuzzing, V6 formal spec

## Known limitations of v0.3.0

- Rejection via `call` allocates the exception (about 175 ns). Use `tryAcquire` on hot paths (about 22 to 31 ns, no allocation).
- With the `FailureRate` policy or slow-call detection, recording a success takes the lock (lean path, about 45 ns in isolation; more with a clock read).
- Latency tracking (O4) reads the precise clock twice per call: about 47 ns extra when enabled.
- `KeyedBreaker` in multi-threaded code requires `--mm:atomicArc` ([ADR-0011](decisions/0011-keyed-breaker-lru.md)).
- A `CircuitBreaker` must outlive the `Permit`s it grants ([ADR-0006](decisions/0006-permit-guard.md)).
- CI runs on Linux only.
