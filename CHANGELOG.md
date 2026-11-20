# Changelog

All notable changes. Versions follow semantic versioning.

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
