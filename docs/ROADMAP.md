# Roadmap

Updated 2026-11-19. IDs refer to [`SPEC.md`](SPEC.md); the detailed status of each one is in [`TRACEABILITY.md`](TRACEABILITY.md).

Legend: [x] done · [ ] pending · [~] deferred

## Where we are

**v0.2.0 is implemented but not yet published.** It is a full rewrite of v0.1 and delivered at once most of what the original plan spread across v0.2 to v0.7.

| Indicator | Value |
|---|---|
| Requirements in the matrix | 116 |
| Done or partial (with tests) | 86 |
| Tests | 59, all passing (orc/arc × threads on/off × release/debug) |
| Value tests | 7 (`tests/t_values.nim`) |
| Benchmarks | BM0–BM9 (`nimble bench`) |
| `call` in `Closed` | 46 ns/op, 0 allocations (P7 target: < 50 ns) |
| Dependencies | none beyond the standard library |

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

## Publishing v0.2.0 (next step)

- [x] Workflows trigger on `master`, the local branch (the rename to `main` is no longer needed)
- [ ] First commit and push to GitHub
- [ ] First real CI run (validates the `nimlang/nim:2.2.4` image and `nimble test` with a commit)
- [x] Replace `<repository-url>` in the README with the real URL
- [ ] Tag `v0.2.0` and date it in the CHANGELOG
- [ ] Publish to the `nim-lang/packages` index (name `circuit_breaker`, tags in `packages.json`)

## v0.3: close performance and proof gaps

- [x] V2/Q5: model test (random sequences compared against a reference model), `tests/t_model.nim` with proptest stateful testing
- [ ] P2: make success recording lock-free with the `FailureRate` policy too
- [ ] BM3: lock-free rejection in `Open` (63 ns today, more expensive than a success; the spec wants the opposite)
- [ ] P5/R3: padding against false sharing on atomic counters
- [ ] O4: latency percentiles (p50/p95/p99) in metrics
- [ ] I1: composition guide with retry, backoff, bulkhead and timeout
- [ ] Report the ORC + `-d:nimAllocStats` crash upstream ([repro](upstream/repro_orc_allocstats.nim))

## v0.4: async, documentation and platforms

- [ ] Y2: Chronos support in a separate module
- [ ] Y3: safety under `Future` cancellation
- [ ] T5: per-call timeout (depends on Y3)
- [ ] D3: publish `nim doc` (GitHub Pages)
- [ ] D4: parameter selection guide and pitfalls
- [ ] D5: database and metrics examples
- [ ] Q6: CI on macOS and Windows, Nim `devel`
- [ ] Q7: code coverage
- [ ] R4: benchmark regression gate (base and PR measured in the same job, see SPEC 27.4)
- [ ] I4/D8: concept equivalence table with other languages

## v1.0: acceptance criteria

As in SPEC §13: every P0 and P1 implemented and tested; zero warnings on orc/arc with and without threads; benchmarks published; model and concurrency tests stable (1000 runs); quickstart validated in CI; public API 100% documented.

## Post-1.0 (deferred, on demand)

- [~] F9 pluggable policy, A13 registry, N11 breaker groups
- [~] A14 bulkhead (composition preferred, [ADR-0001](decisions/0001-scope-circuit-breaker-only.md))
- [~] G6 gradual recovery (ramp-up), G7 active probe
- [~] O6/B3 Prometheus exporter, B5 tracing, O7 logging hook
- [~] I2 HTTP/web adapters, I3 C API, Y4/N12 JS/WASM targets
- [~] N5 distributed state, N6 priorities, N7 SLO-based threshold
- [~] K4 JSON config, V4 fuzzing, V6 formal spec

## Known limitations of v0.2.0

- Rejection in `Open` takes the lock (63 ns via `tryAcquire`); via `call` it allocates the exception (270 ns, 3 allocations). Use `tryAcquire` on hot paths.
- With the `FailureRate` policy or slow-call detection, recording a success takes the lock (73–127 ns).
- `KeyedBreaker` in multi-threaded code requires `--mm:atomicArc` ([ADR-0011](decisions/0011-keyed-breaker-lru.md)).
- A `CircuitBreaker` must outlive the `Permit`s it grants ([ADR-0006](decisions/0006-permit-guard.md)).
- CI runs on Linux only.
