# Changelog

All notable changes. Versions follow semantic versioning.

## Unreleased

### Added
- Y2: Chronos support in `circuit_breaker/chronos_async` (Chronos is not a
  package dependency; install it to use the module).
- Y3: with Chronos, cancelling a call cancels `fn`, frees a probe slot and is
  not counted by default (`onCancel`).
- T5: `callTimeout` for the async APIs; expiry counts as a failure and raises
  `CallTimeoutError`.
- D2: transition table in the README. D3: every exported symbol documented,
  checked in CI.
- CI on Nim 2.0.16, 2.2.4, 2.2.14, 2.4 and devel, and on macOS and Windows
  (ADR-0018).

### Changed
- Requires Nim >= 2.0.0 (was 2.2.4).
- Tests require proptest >= 1.0.0.

## 0.3.0 - 2026-11-20

### Fixed
- A success that tripped the `FailureRate` policy on a count window, with no
  slow-call detection and no `onCall` callback, computed the open deadline from
  time 0. The open period was already over, so the next call became a probe at
  once. Probe successes closing the circuit also recorded a zero timestamp.
  Both now read the clock when a transition happens.

### Added
- O4: latency percentiles, opt-in with `latencyPrecision` (log-bucket
  histogram, `latencyQuantile`).
- O6/B3: Prometheus text exposition in `circuit_breaker/prometheus`.
- O7: transition logging with `std/logging` in `circuit_breaker/logs`.
- I1: composition guide (`docs/COMPOSITION.md`, `examples/composition.nim`).

### Performance
- Rejections take no lock: about 22 ns in `ForcedOpen` (was 53) and about
  31 ns in `Open`, below the cost of a success.
- Successes with a sliding window and no callbacks take a leaner locked path
  (`FailureRate` about 56 to 45 ns in isolation).
- Hot counters on separate cache lines: 31 to 45% less per call with 2 to 8
  threads sharing a breaker.
- Latency samples are recorded without the lock.

## 0.2.0 - 2026-11-20

Rewrite of the library. The 0.1 API (`call` returning `Option[T]`, public
`transitionTo`) is not compatible.

### Fixed (bugs of 0.1, each with a regression test)
- The failure counter was reset before every call, so a `failureThreshold`
  above 1 never opened the circuit (F1).
- `HalfOpen` switched to `Closed` before running the probe, firing `onClose`
  even when the probe failed (S5).
- The call that moved `Open` to `HalfOpen` returned without running the
  function (S6).
- Wall-clock time (`DateTime`) replaced by a monotonic clock (T1); the open
  period now starts at the end of the failing call (T2).
- Rejections and failures were both `none(T)`; failures now propagate the
  original exception and rejections raise `CircuitOpenError` (A1, A2).

### Added
- Failure-rate policy with count or time windows (O(1)), slow-call
  detection, error and result classifiers, `Retry-After` hints.
- Exponential backoff with jitter, `successThreshold`, `halfOpenMaxProbes`.
- `tryCall`, `callOr`, `withBreaker`, `Permit` guard (`acquire`/`tryAcquire`),
  support for procs returning `void`.
- Events (`onTransition`, `onCall`), `metrics`, `explain`, `report`.
- Shadow mode, `diagnose`, `reconfigure`, `reset`/`forceOpen`/`disable`,
  `-d:cbDisabled`.
- `circuit_breaker/async` (`callAsync`), `circuit_breaker/keyed`
  (`KeyedBreaker` with LRU), `circuit_breaker/testing` (`FakeClock`).
- Thread safety with an atomic state word and a lock-free success path.
- Test suite, value tests, benchmarks, traceability check, CI workflows.

### Removed
- Boilerplate `submodule.nim`, the placeholder test and the committed binary.
