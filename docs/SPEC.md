# Requirements specification

This document defines what is expected of a complete circuit breaker library. Each requirement has an ID used in issues, test names and benchmarks. Priorities: **P0** mandatory, **P1** expected from a mature library, **P2** differentiator.

- Status of each requirement: [`TRACEABILITY.md`](TRACEABILITY.md).
- Delivery order and versions: [`ROADMAP.md`](ROADMAP.md).
- How the code is organized: [`ARCHITECTURE.md`](ARCHITECTURE.md).
- Why the choices were made: [`decisions/`](decisions/README.md).

---

# Part I: Core requirements

## 1. State model

| ID | Pri | Requirement |
|----|-----|-------------|
| S1 | P0 | Three states: `Closed`, `Open`, `HalfOpen`. |
| S2 | P1 | Optional administrative states: `Disabled` (always passes, ignores metrics) and `ForcedOpen` (always rejects, for maintenance). |
| S3 | P0 | Only valid transitions: Closed→Open, Open→HalfOpen, HalfOpen→Closed, HalfOpen→Open. Any other is impossible by construction. |
| S4 | P0 | `Open→HalfOpen` happens **lazily** (on the first call after the timeout), with no timer or background thread. |
| S5 | P0 | The state only changes **after** the call outcome: HalfOpen closes only after a success, never before running `fn`. |
| S6 | P0 | In `HalfOpen`, the call that triggers the transition **runs** `fn` as a probe; it is not discarded. |
| S7 | P0 | In `HalfOpen`, at most `maxProbes` concurrent calls pass (default 1). The rest are rejected as if the circuit were open. |
| S8 | P1 | `HalfOpen` requires `successThreshold` consecutive successes to close (default 1). |

## 2. Opening criteria (failure policy)

| ID | Pri | Requirement |
|----|-----|-------------|
| F1 | P0 | **Consecutive failures** policy: the counter only resets after a success, never before the call. |
| F2 | P1 | **Failure rate** policy over a sliding window: opens when `failures/total >= failureRate` with `total >= minimumCalls`. |
| F3 | P1 | Window by **count** (last N calls) or by **time** (last T seconds), configurable. |
| F4 | P1 | **Slow call** policy: a call above `slowCallThreshold` counts as slow; opens when `slowRate >= slowCallRate`. |
| F5 | P1 | Configurable failure classifier: `isFailure(exc)` decides what counts (e.g. business 4xx does not count, 5xx and timeouts do). |
| F6 | P1 | Ignored exceptions (count neither as success nor as failure). |
| F7 | P1 | Classification by **result**, not only by exception: `isFailureResult(value)` (e.g. HTTP 503 returned without raising). |
| F8 | P0 | `Defect` (bugs/asserts) does **not** count as a failure by default and is propagated. Documented and configurable. |
| F9 | P2 | Pluggable policy (interface/concept) for custom strategies. |

## 3. Recovery time

| ID | Pri | Requirement |
|----|-----|-------------|
| T1 | P0 | Use a **monotonic clock** (`std/monotimes`), never `DateTime`/`now()`. Immune to NTP, DST and manual changes. |
| T2 | P0 | The open period starts at the **end** of the failing call, not at its start. |
| T3 | P1 | **Exponential backoff** of the open timeout on each consecutive reopening (`base * factor^n`, capped by `maxTimeout`). |
| T4 | P1 | Configurable **jitter** on the timeout, to avoid a thundering herd across instances. |
| T5 | P1 | Optional per-call timeout (`callTimeout`); exceeding it counts as a failure. |
| T6 | P2 | Clock injection (`Clock`) for deterministic tests, without `sleep`. |

## 4. API

| ID | Pri | Requirement |
|----|-----|-------------|
| A1 | P0 | `call` distinguishes an **open circuit** from a **failure of the function**. The caller never confuses the two. |
| A2 | P0 | A failure of the function propagates the **original exception** with its stack trace. It is never swallowed. |
| A3 | P0 | Rejection raises `CircuitOpenError` (with `retryAfter: Duration` and the breaker name), or returns an explicit result type. One style is the default and the other is offered (`tryCall`). |
| A4 | P0 | Supports `fn` returning `void`. |
| A5 | P0 | Supports **sync** and **async** (`Future[T]` from `std/asyncdispatch` and, ideally, Chronos). |
| A6 | P1 | **Fallback**: `callOr(fn, fallback)` runs the fallback when rejected or failed. |
| A7 | P1 | `withBreaker` template for use without an allocated closure (no heap per call). |
| A8 | P1 | Builder or named config object; validation at construction (`failureThreshold >= 1`, durations `> 0`, etc.) with a clear error. |
| A9 | P1 | State getters: `state()`, `failureCount()`, `lastError()`, `nextRetryAt()`, without exposing mutable fields. |
| A10 | P1 | Manual control: `reset()`, `forceOpen()`, `forceClose()`, `disable()`. |
| A11 | P0 | `transitionTo` is **not public**. Invariants are protected. |
| A12 | P1 | Breaker name (for logs and metrics). |
| A13 | P2 | Global/named **registry** to manage breakers per service/endpoint. |
| A14 | P2 | Optional bulkhead (concurrency limit) combinable with the breaker. |

## 5. Events and observability

| ID | Pri | Requirement |
|----|-----|-------------|
| O1 | P0 | `onOpen`/`onClose`/`onHalfOpen` callbacks receive context (name, previous state, reason). |
| O2 | P0 | Callbacks run **after** the state is consistent and **outside** any lock. An exception in a callback is caught and never corrupts the breaker or masks the call result. |
| O3 | P1 | Extra events: `onSuccess`, `onFailure`, `onRejected`, `onSlowCall`. |
| O4 | P1 | Metrics: success/failure/rejection/slow counters, failure rate, time in each state, latency (optional p50/p95/p99). |
| O5 | P1 | Immutable metrics snapshot (`metrics()`), cheap and without unnecessary allocation. |
| O6 | P2 | Prometheus/OpenMetrics exporter in a separate module (no dependency in the core). |
| O7 | P2 | Integration with `std/logging` via an optional hook. |

## 6. Concurrency and thread safety

| ID | Pri | Requirement |
|----|-----|-------------|
| C1 | P0 | Threading behavior **documented**: thread-safe or not, without ambiguity. |
| C2 | P0 | With `--threads:on`, safety through **atomics** (`std/atomics`) on the hot path; locks only on transitions. |
| C3 | P0 | `HalfOpen` race: the Open→HalfOpen transition is done by **CAS**; only one thread wins. |
| C4 | P1 | Works with `--mm:arc`/`orc` and `gcsafe` without warnings. |
| C5 | P1 | In single-threaded async, no lock is needed and no cost is paid (conditional compilation). |
| C6 | P1 | No hidden global state; independent instances. |

## 7. Performance

| ID | Pri | Requirement |
|----|-----|-------------|
| P1 | P0 | Hot path in `Closed` with no heap allocation and no syscalls beyond one clock read (or none, if possible). |
| P2 | P0 | `Closed` without locks: atomic operations only (counters). Scope amended by [ADR-0015](decisions/0015-lean-locked-path-for-windowed-policies.md): windowed policies use a lean locked success path. |
| P3 | P1 | Sliding window as a fixed-size **ring buffer** with preallocated buckets. O(1) per call. |
| P4 | P1 | No closures per call (templates/generics/`{.inline.}` procs). |
| P5 | P1 | Layout that avoids **false sharing** (cache-line padding on atomic counters). |
| P6 | P1 | **Benchmark** suite (ns/op, allocations, contention with N threads) run in CI with a regression limit. |
| P7 | P2 | Reference target: overhead < 50 ns per call in `Closed` (single thread) on common hardware. |
| P8 | P2 | No dependencies beyond the standard library in the core. |

## 8. Configuration

| ID | Pri | Requirement |
|----|-----|-------------|
| K1 | P0 | Sensible, documented defaults. |
| K2 | P0 | Validation at creation; an invalid config fails early. |
| K3 | P1 | Config immutable after creation, or an explicit atomic change (`reconfigure`). |
| K4 | P2 | Loading config from an object/JSON for use in services. |

## 9. Quality and tests

| ID | Pri | Requirement |
|----|-----|-------------|
| Q1 | P0 | Unit tests for **every** transition and every failure criterion. |
| Q2 | P0 | Deterministic tests with an injected clock, without `sleep`. |
| Q3 | P0 | Edge cases: threshold 1, timeout 0, slow `fn`, raising callback, `void`, complex return types. |
| Q4 | P1 | Concurrency tests (stress with N threads, checking invariants: never more than `maxProbes` probes, consistent counters). |
| Q5 | P1 | Property/model-based tests: random event sequences compared against a reference model. |
| Q6 | P1 | CI (GitHub Actions) on Linux/macOS/Windows, Nim stable and devel, `--mm:orc` and `arc`, with and without `--threads:on`. |
| Q7 | P1 | Code coverage reported. |
| Q8 | P1 | Examples compiled in CI so they never break. |

## 10. Documentation and packaging

| ID | Pri | Requirement |
|----|-----|-------------|
| D1 | P0 | README in one consistent language, with a quickstart that works via `nimble install` (package imports, not `../src`). |
| D2 | P0 | State diagram and transition table. |
| D3 | P1 | Doc comments (`##`) on the whole public API and published `nim doc`. |
| D4 | P1 | Guide for choosing parameters (thresholds, timeouts, window) and common pitfalls. |
| D5 | P1 | Examples: HTTP client, database, async, fallback, metrics. |
| D6 | P1 | CHANGELOG and semantic versioning. |
| D7 | P0 | LICENSE file, `.gitignore` (no binaries), git repository. |
| D8 | P1 | Table mapping concepts and parameters to the circuit breaker models established in other languages, for people migrating (see I4). |

## 11. Module structure

The actual structure is described in [`ARCHITECTURE.md`](ARCHITECTURE.md).

## 12. State machine (reference)

```
            failures reach the limit
   ┌────────────────────────────────────┐
   │                                    ▼
Closed ◄──── successThreshold ──── HalfOpen ───── probe fails ──────► Open
   ▲          successes                 ▲                              │
   │                                    └──── recoveryTimeout ─────────┘
   │                                         (with backoff + jitter)
   └─ a success resets consecutive failures
```

Rules:
- `Closed`: runs `fn`. A success resets consecutive failures. A failure updates the policy; if it is violated, go to `Open`.
- `Open`: rejects immediately with `CircuitOpenError`. After `recoveryTimeout` (monotonic), the next call becomes a probe and enters `HalfOpen`.
- `HalfOpen`: up to `maxProbes` concurrent probes. `successThreshold` successes close the circuit. Any failure reopens it, with a longer backoff.

## 13. Acceptance criteria (Definition of Done for v1.0)

1. Every **P0** requirement implemented and tested.
2. Zero warnings with `--mm:orc` and `--mm:arc`, with and without `--threads:on`.
3. Published benchmark with the `Closed` overhead and multi-thread contention.
4. Model and concurrency tests passing reliably (1000 runs without failure).
5. README with a working quickstart, validated in CI.
6. Public API 100% documented.

## 14. Roadmap

See [`ROADMAP.md`](ROADMAP.md).

---

# Part II: Differentiators

Principle: **depth, correctness and ergonomics of the circuit breaker**. Rate limiting, bulkheads and retries are out of scope and are composed with the breaker, not reimplemented ([ADR-0001](decisions/0001-scope-circuit-breaker-only.md)).

## 15. Ergonomics (E)

| ID | Pri | Requirement |
|----|-----|-------------|
| E1 | P0 | `call`, `tryCall` and `callOr` wrap the function; the user never has to record outcomes by hand. |
| E2 | P1 | **RAII guard** (`let permit = cb.acquire()`): if the scope ends without `permit.success()`, a failure is recorded automatically. Removes the "forgot to record" bug that leaves `HalfOpen` stuck. Also offers `permit.failure(err)` and `permit.ignore()`. |
| E3 | P1 | `template withBreaker(cb): body`, with no closure and no heap allocation. |
| E4 | P1 | Low-level API (`allow`/`record*`) available for advanced cases, built on the same core as the guard. |
| E5 | P1 | `CircuitOpenError` carries `breakerName`, `state` and `retryAfter` (to return a correct HTTP `Retry-After`). |

## 16. Demonstrable correctness (V)

| ID | Pri | Requirement |
|----|-----|-------------|
| V1 | P0 | Injectable clock (`Clock`) and a public `FakeClock` in a testing module: users test their own code without `sleep`. |
| V2 | P1 | **Model** test: random event sequences compared against an executable reference model. |
| V3 | P1 | **Multi-thread stress** test with invariants (never more than `maxProbes` probes, consistent counters). |
| V4 | P2 | **Fuzzing** of the state machine and the sliding window. |
| V5 | P1 | Quality section in the README: an objective list of what is tested (model, stress, platforms, memory managers). |
| V6 | P2 | Short formal specification of the state machine (transition table) used to generate part of the tests. |

## 17. Advanced policies (G)

| ID | Pri | Requirement |
|----|-----|-------------|
| G1 | P1 | Failure rate over a sliding window with `minimumCalls` (see F2/F3). |
| G2 | P1 | Slow calls as an opening signal (see F4). |
| G3 | P1 | `isFailure(exc)` and `isFailureResult(value)` classifiers (see F5/F7). |
| G4 | P1 | Exponential backoff with jitter on reopening (see T3/T4). |
| G5 | P1 | Honor server hints: open for `Retry-After` when the failure carries it (`openFor(duration)` from the classifier). |
| G6 | P2 | **Gradual recovery** (ramp-up): instead of a single probe, release a growing share of traffic (e.g. 1% → 5% → 25% → 100%) to avoid overloading a service that just recovered. |
| G7 | P2 | **Active probe**: in `HalfOpen`, an optional `healthCheck` replaces real traffic as the probe. |

## 18. Observability (B)

| ID | Pri | Requirement |
|----|-----|-------------|
| B1 | P1 | Events with context: name, previous state, new state, reason, `retryAfter`. |
| B2 | P1 | `metrics()` as a cheap immutable snapshot. |
| B3 | P2 | Prometheus/OpenMetrics exporter in a separate module. |
| B4 | P1 | **`explain()`**: ring buffer of the last N transitions with reason and window statistics at that moment (answers "why did the circuit open?" without logs). |
| B5 | P2 | Tracing hooks (OpenTelemetry-compatible) without a dependency in the core. |

## 19. Published performance (R)

| ID | Pri | Requirement |
|----|-----|-------------|
| R1 | P1 | Reproducible benchmarks in the repository: ns/op in `Closed`, allocations, contention with N threads. Every performance claim points to a measured number. |
| R3 | P1 | Atomics on the hot path and padding against false sharing (see P1–P5). |
| R4 | P2 | Performance regression gate in CI. |

## 20. Async and runtimes (Y)

| ID | Pri | Requirement |
|----|-----|-------------|
| Y1 | P1 | `callAsync` for `asyncdispatch`. |
| Y2 | P1 | **Chronos** support in a separate module, without forcing the dependency. |
| Y3 | P1 | Cancellation safety: a cancelled `Future` never leaves the breaker stuck in `HalfOpen` and does not count as a failure (configurable policy). |
| Y4 | P2 | `nim js` target supported in the core (no threads/atomics). |

## 21. Interoperability (I)

| ID | Pri | Requirement |
|----|-----|-------------|
| I1 | P1 | Composition guide with retry, backoff, bulkhead and timeout (retry/breaker order, pitfalls, examples). |
| I2 | P2 | Thin optional adapters for `std/httpclient`, Jester and Prologue. |
| I3 | P2 | Optional C API (`--app:lib`) for use from other languages. |
| I4 | P1 | Concept equivalence document with the established circuit breakers of other languages, to ease migration. |

## 22. Additional differentiators (N)

| ID | Pri | Requirement | Value |
|----|-----|-------------|-------|
| N1 | P1 | **Shadow mode (`shadowMode`)**: evaluates the policy and emits events/metrics, but **never rejects**. Allows adopting the breaker in production with zero risk and calibrating thresholds with real data. | High: lowers the barrier to adoption |
| N2 | P1 | **Keyed breakers** (`KeyedBreaker`: per host, endpoint or tenant) with a cardinality cap and LRU eviction, so unbounded keys never leak memory. | High: common microservice use case |
| N3 | P1 | **Compile-time switch-off** (`-d:cbDisabled`): becomes a zero-cost pass-through, useful for benchmarks and debugging. | Medium |
| N4 | P1 | **Hot config reload** (`reconfigure`), atomic, without recreating the breaker or losing state. | Medium |
| N5 | P2 | **State shared across processes** through a `StateStore` interface (local memory by default; Redis or shared memory in external modules): every instance of the service opens together. | High, but costly and outside the core |
| N6 | P2 | **Priority classes**: critical calls may use a more tolerant threshold or always be probes, while low-priority traffic is cut first. | Medium |
| N7 | P2 | **Adaptive threshold** based on an error budget (SLO): opens when the budget burn rate exceeds a pace, instead of a fixed number. | Medium, complex |
| N8 | P1 | **Config linter/diagnostics**: `diagnose()` warns about risky combinations (e.g. `minimumCalls` larger than the window, timeout shorter than typical latency). | Medium |
| N9 | P1 | **`testing` module** with `FakeClock`, `forceState` and assertions for library users. | High: low cost, big adoption gain |
| N10 | P2 | **Text dashboard** (`cb.report()`) readable in terminals/logs with state, rates and time to the next probe. | Low, but appreciated |
| N11 | P2 | **Breaker groups** (`BreakerGroup`): query and control several at once (`openAll`, `statusAll`). | Low |
| N12 | P2 | Support for restricted targets (`--os:standalone`, WASM/JS) for the no-threads variant. | Niche |

## 23. Roadmap

See [`ROADMAP.md`](ROADMAP.md).

---

# Part III: Evidence policy (project rule)

**Nothing enters the project without tests and benchmarks that prove its value and its performance.** A feature without evidence is not delivered. Rationale in [ADR-0002](decisions/0002-evidence-policy.md).

## 24. Rules (EV)

| ID | Rule |
|----|------|
| EV1 | Every requirement (spec ID) has at least **one test** that verifies it, citing the ID in its name (`test "S5: HalfOpen only closes after a success"`). |
| EV2 | Every requirement that affects the execution path, memory or concurrency has **a benchmark** measuring its cost (ns/op, allocations, contention). |
| EV3 | Every **value** feature (ergonomics, differentiators) has a **value test**: a scenario that shows the problem without the feature and the fix with it. |
| EV4 | Every fixed bug gets a **regression test** that fails on the old code. |
| EV5 | A PR is accepted only with tests and benchmarks for the change. Without them, CI fails. |
| EV6 | Public claims ("faster", "zero allocation", "thread-safe") must point to a reproducible benchmark or test in the repository. |
| EV7 | Tests are deterministic: injected clock, no `sleep`, no network. |

## 25. Traceability matrix

`docs/TRACEABILITY.md`, validated by a script in CI, with one row per requirement. CI fails if a requirement marked done has no test, if a cited benchmark does not exist, or if a test cites an ID missing from the matrix.

## 26. Value tests: required scenarios

Each differentiator proves it solves a real problem:

| Differentiator | Scenario that proves the value |
|---|---|
| E1/E2 RAII guard | Code that "forgets" to record: a manual API leaves `HalfOpen` stuck; the guard recovers by itself. |
| F2 failure rate | Intermittent traffic (30% errors) never opens by consecutive failures, but opens by rate. |
| F4 slow calls | A service answering 200 in 10 s: without the slow-call policy the circuit never opens; with it, it does. |
| T3/T4 backoff + jitter | N instances reopening together: with jitter, probes spread over time (measure the spread). |
| N1 shadow mode | On recorded traffic, shadow mode reports the same decisions as the real mode, without blocking any call. |
| N2 keyed breakers | With a very large number of keys, memory stays below the configured cap (LRU eviction works). |
| B4 `explain()` | After an opening, `explain()` returns the reason and the correct window statistics. |
| G6 ramp-up | A service that just recovered never receives more than the planned share at each step. |
| Y3 cancellation | A `Future` cancelled in `HalfOpen` does not leave the breaker stuck. |
| S7 probes | With 64 threads in `HalfOpen`, at most `maxProbes` calls pass. |

## 27. Benchmarks

### 27.1 Methodology (reproducible)
- `benchmarks/` directory, run with `nimble bench`, compiled with `-d:release --opt:speed`.
- **Warm-up** before measuring; at least 30 samples; report median, p95, p99 and spread.
- Measure with a monotonic clock and prevent the compiler from eliminating the measured code.
- Record hardware, Nim version, flags and commit with the result (optional JSON output).
- **Allocations** measured with the allocator counters: the target on the `Closed` path is **zero**.
- Multi-thread scenarios with several thread counts, to show scalability and contention.

Details and current deviations in [ADR-0013](decisions/0013-benchmark-methodology.md).

### 27.2 Minimum suite

| ID | Benchmark | Measures |
|---|---|---|
| BM0 | Direct closure call | baseline |
| BM1 | `call` in `Closed` (success), 1 thread | ns/op and allocations (target: < 50 ns, 0 allocations) |
| BM2 | `call` in `Closed`, N threads | scalability and contention |
| BM3 | Rejection in `Open` | cost of the rejection path (should be cheaper than `Closed`) |
| BM4 | Transition and probes in `HalfOpen` under concurrency | cost of the race |
| BM5 | Sliding window (count and time) | O(1) cost per call, no growth with window size |
| BM6 | RAII guard, `withBreaker` and `call` | cost of each API style; `withBreaker` without a closure |
| BM7 | Keyed breakers with high cardinality | lookup and eviction cost |
| BM8 | Shadow mode and `-d:cbDisabled` | extra overhead vs. direct pass-through |
| BM9 | Metrics and `explain()` | cost of collecting and reading the snapshot |
| BM10 | Async (`callAsync`) | overhead over a plain `Future` |

### 27.3 Publishing numbers
- Results are published in the README with date, hardware, Nim version, flags and the command to reproduce.
- Any scenario below target is published too, together with the roadmap item that fixes it.

### 27.4 Regression gates in CI
- **Current state:** the benchmark workflow is **informational** (publishes the numbers, never fails). Shared runners are noisy and a fixed limit would cause false positives.
- **Target:** a gate that measures **base and PR in the same job** (same machine, same run) and fails above a limit calibrated with real data.
- Fail if any benchmark marked "zero allocation" allocates (allocation counts are deterministic and noise-free).
- Baselines are updated only through an explicit PR with justification.

### 27.5 CI items deferred (risk or cost)
Sanitizers (ASan/TSan), repeated stress, coverage (gcov/lcov), macOS/Windows and Nim `devel` stay out of the initial CI. Sanitizers and stress runs were executed locally for v0.2.0.

## 28. Quality directory layout

The actual layout of `tests/` and `benchmarks/` is in [`ARCHITECTURE.md`](ARCHITECTURE.md#tests-and-benchmarks).

Nimble tasks: `nimble test`, `nimble bench` and `nimble trace` (validates the matrix). `nimble benchcheck` runs the R4 gate (ADR-0020).

## 29. Definition of Done per feature

A feature is done only when:
1. The requirement is implemented and documented (`##` on the public API).
2. There are unit tests, including edge cases, and the value test (EV3), all passing.
3. There is a benchmark with a recorded result within targets.
4. The traceability matrix row is filled in.
5. CI passes on every platform and memory manager.
6. The README reflects the feature, with a measured number whenever it makes a performance claim.
