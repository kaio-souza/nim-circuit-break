# Traceability matrix

Status of every requirement in [`SPEC.md`](SPEC.md). Validated by `scripts/check_traceability.nim` (`nimble trace`, CI job). Per-version view: [`ROADMAP.md`](ROADMAP.md).

Script rules:
- **done** and **partial** require a test whose name contains the ID (`test "S5: ..."`), unless the Tests column says `CI`. In that case the evidence is the CI matrix (memory managers, threads).
- If the Benchmark column cites `BMx`, that benchmark must exist in `benchmarks/`.
- Every ID cited in a test name must be in this table.
- **pending** and **deferred** are not checked; they stay visible here.

| ID | Requirement | Status | Tests | Benchmark | Notes |
|----|-------------|--------|-------|-----------|-------|
| S1 | Three states | done | t_transitions | n/a | |
| S2 | Administrative states | done | t_transitions | n/a | `ForcedOpen`, `Disabled` |
| S3 | Only valid transitions | done | t_transitions | n/a | |
| S4 | Lazy Open→HalfOpen | done | t_transitions | n/a | |
| S5 | Closes only after a success | done | t_transitions | n/a | v0.1 regression |
| S6 | The probe runs `fn` | done | t_transitions | n/a | v0.1 regression |
| S7 | Probe limit | done | t_transitions, t_concurrency | n/a | |
| S8 | `successThreshold` | done | t_transitions | n/a | |
| F1 | Correct consecutive failures | done | t_transitions | n/a | v0.1 regression |
| F2 | Failure rate | done | t_policies, t_values | BM5 | |
| F3 | Count and time windows | done | t_policies | BM5 | amortized O(1) expiration |
| F4 | Slow calls | done | t_policies, t_values | BM1 | |
| F5 | Error classifier | done | t_policies | n/a | |
| F6 | Ignored exceptions | done | t_policies | n/a | |
| F7 | Failure by result | done | t_policies | n/a | |
| F8 | `Defect` does not count | done | t_policies | n/a | |
| F9 | Pluggable policy | deferred | | | |
| T1 | Monotonic clock | done | t_transitions | n/a | |
| T2 | Open period starts at the end of the call | done | t_transitions | n/a | |
| T3 | Exponential backoff | done | t_transitions | n/a | |
| T4 | Jitter | done | t_transitions, t_values | n/a | only delays, never earlier |
| T5 | Per-call timeout | deferred | | | needs cancellation (Y3) |
| T6 | Injectable clock | done | t_api | n/a | `FakeClock` |
| A1 | Open vs. failure distinguished | done | t_api | n/a | |
| A2 | Original exception propagated | done | t_api | n/a | |
| A3 | `CircuitOpenError` and `tryCall` | done | t_api | BM3 | |
| A4 | `void` support | done | t_api | n/a | |
| A5 | Sync and async | partial | t_async | n/a | `asyncdispatch` yes; Chronos deferred (Y2) |
| A6 | `callOr` fallback | done | t_api | n/a | |
| A7 | Template without closure | done | t_api | BM6 | `withBreaker` (= E3) |
| A8 | Validated config | done | t_api | n/a | |
| A9 | State getters | done | t_api | BM9 | |
| A10 | Manual control | done | t_transitions | n/a | |
| A11 | `transitionTo` not public | done | t_transitions | n/a | |
| A12 | Breaker name | done | t_api | n/a | |
| A13 | Global registry | deferred | | | `KeyedBreaker` covers part of it |
| A14 | Bulkhead | deferred | | | composition, see I1 |
| O1 | Events with context | done | t_api | n/a | |
| O2 | Callbacks isolated from exceptions | done | t_api | n/a | |
| O3 | Call events | done | t_api | BM1 | |
| O4 | Latency percentiles | done | t_latency | BM10 | opt-in via `latencyPrecision`; log-bucket histogram, 1/k relative error |
| O5 | Immutable snapshot | done | t_api | BM9 | = B2 |
| O6 | Prometheus exporter | done | t_prometheus | BM11 | `renderPrometheus`, separate module; the app serves the text |
| O7 | Logging hook | done | t_logs | BM12 | `withTransitionLog`, transitions only; composes with `onTransition` |
| C1 | Documented threading | done | t_concurrency | n/a | |
| C2 | Atomics on the hot path | done | t_concurrency | BM2 | |
| C3 | Single Open→HalfOpen transition | done | t_concurrency | n/a | short lock, not CAS (ADR-0005) |
| C4 | orc/arc without warnings | done | CI | n/a | |
| C5 | No lock without threads | done | CI | n/a | `when compileOption("threads")` |
| C6 | No global state | done | CI | n/a | |
| P1 | Zero allocation in Closed | done | CI | BM1 | 0.00 alloc/op |
| P2 | Lock-free Closed | done | t_lean_path | BM1 | scope amended by [ADR-0015](decisions/0015-lean-locked-path-for-windowed-policies.md): lock-free for the consecutive policy, lean locked path for windowed policies |
| P3 | O(1) window | done | CI | BM5 | |
| P4 | No closure per call | done | CI | BM6 | |
| P5 | False-sharing padding | done | CI | BM2 | hot groups 64 bytes apart, compile-time `offsetOf` checks; -31 to -45% per call at 2 to 8 threads |
| P6 | Benchmark suite | done | CI | BM1 | regression gate deferred (R4) |
| P7 | < 50 ns in Closed | partial | CI | BM1 | 41–51 ns measured; see README |
| P8 | No dependencies | done | CI | n/a | |
| K1 | Documented defaults | done | t_api | n/a | |
| K2 | Validation at creation | done | t_api | n/a | |
| K3 | Immutable config or `reconfigure` | done | t_api | n/a | = N4 |
| K4 | JSON config | deferred | | | |
| Q1 | Transition tests | done | CI | n/a | |
| Q2 | Deterministic tests | done | CI | n/a | via V1 |
| Q3 | Edge cases | done | CI | n/a | |
| Q4 | Concurrency tests | done | CI | n/a | via V3 |
| Q5 | Model test | done | t_model | n/a | see V2 |
| Q6 | Multi-platform CI | partial | CI | n/a | Linux only for now (SPEC 27.5) |
| Q7 | Coverage | deferred | | | |
| Q8 | Examples compiled in CI | done | CI | n/a | |
| D1 | README in one language, quickstart via `nimble install` | partial | CI | n/a | README in English; quickstart not yet built in CI after `nimble install` (v0.4 phase C) |
| D2 | State diagram and transition table | done | CI | n/a | README "States": diagram and transition table; SPEC §12 |
| D3 | Doc comments on the public API, published `nim doc` | partial | CI | n/a | 97 of 97 exported symbols documented, checked by `scripts/check_docs.nim` in CI; not yet published (Pages, D-4) |
| D4 | Parameter guide and pitfalls | pending | | | v0.4 phase E |
| D5 | Examples: HTTP, database, async, fallback, metrics | partial | CI | n/a | HTTP, async, composition compiled in CI; database, metrics, fallback missing (v0.4 phase E) |
| D6 | CHANGELOG and semantic versioning | done | CI | n/a | `CHANGELOG.md`; tags v0.2.0, v0.3.0 |
| D7 | LICENSE, `.gitignore`, git repository | done | CI | n/a | `LICENSE` (MIT), `.gitignore` excludes binaries |
| D8 | Concept and parameter mapping to other languages | pending | | | = I4, v0.4 phase E |
| E1 | `call`/`tryCall`/`callOr` | done | t_api | BM1 | |
| E2 | RAII guard | done | t_api, t_values | BM6 | |
| E3 | `withBreaker` | done | t_api | BM6 | |
| E4 | Low-level API on the same core | done | t_api | BM6 | `tryAcquire` |
| E5 | `retryAfter` | done | t_api | n/a | |
| V1 | Public `FakeClock` | done | t_api | n/a | |
| V2 | Model test | done | t_model | n/a | proptest `stateMachine`; 1000 sequences, planted model mistakes found |
| V3 | Multi-thread stress | done | t_concurrency | n/a | also under ThreadSanitizer |
| V4 | Fuzzing | deferred | | | |
| V5 | Quality section in README | done | CI | n/a | |
| V6 | Formal spec | deferred | | | |
| G1 | Rate over a window | done | t_policies | BM5 | = F2 |
| G2 | Slow calls | done | t_policies | BM1 | = F4 |
| G3 | Classifiers | done | t_policies | n/a | = F5/F7 |
| G4 | Backoff + jitter | done | t_transitions | n/a | = T3/T4 |
| G5 | Server hint | done | t_policies | n/a | |
| G6 | Gradual ramp-up | deferred | | | |
| G7 | Active probe | deferred | | | |
| B1 | Events with context | done | t_api | n/a | |
| B2 | `metrics()` | done | t_api | BM9 | |
| B3 | Prometheus | done | t_prometheus | BM11 | same exporter as O6; no dependency in the core |
| B4 | `explain()` | done | t_api, t_values | BM9 | |
| B5 | Tracing | deferred | | | |
| R1 | Reproducible benchmarks | done | CI | BM0 | |
| R3 | Atomics and padding | done | CI | BM2 | atomics and padding (P5) |
| R4 | Regression gate | deferred | | | SPEC 27.4 |
| Y1 | `callAsync` (asyncdispatch) | done | t_async | n/a | |
| Y2 | Chronos | deferred | | | |
| Y3 | Cancellation | deferred | | | |
| Y4 | JS target | deferred | | | |
| I1 | Composition guide | done | CI | n/a | `docs/COMPOSITION.md`; `examples/composition.nim` compiled in CI (Q8) |
| I2 | HTTP/web adapters | deferred | | | |
| I3 | C API | deferred | | | |
| I4 | Concept equivalence with other languages | deferred | | | |
| N1 | Shadow mode | done | t_api, t_values | BM8 | |
| N2 | Keyed breakers | done | t_keyed, t_values | BM7 | multi-thread needs `--mm:atomicArc` |
| N3 | `-d:cbDisabled` | done | t_cbdisabled | BM8 | |
| N4 | `reconfigure` | done | t_api | n/a | |
| N5 | Distributed state | deferred | | | |
| N6 | Priorities | deferred | | | |
| N7 | SLO-based threshold | deferred | | | |
| N8 | Config diagnostics | done | t_api | n/a | |
| N9 | `testing` module | done | t_api | n/a | |
| N10 | `report()` | done | t_api | n/a | |
| N11 | Breaker groups | deferred | | | |
| N12 | Restricted targets | deferred | | | |
