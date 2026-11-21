# ADR-0019: API review before v1.0

- Status: Accepted
- Date: 2026-11-21
- Requirements: K1, A3, O1, O3, F5, Y2, N2

## Context

A 1.0 release freezes the public API under semantic versioning. A review of
the library against Nim idioms found inconsistent enum naming (no prefix,
`vk`, `tr`, `co`, `cr`), a 26-parameter `initBreakerConfig` repeating the 26
fields of `BreakerConfig`, callback types without effects, so the Chronos
module needed seven `{.cast(gcsafe).}` blocks, internal modules (`window`,
`latency`) importable as if public, and rules duplicated between code paths.

## Decision

- `BreakerConfig` declares its defaults on the fields (Nim 2.0 object field
  defaults). `initBreakerConfig` is removed: `BreakerConfig(name: "x",
  failureThreshold: 3)` builds a configuration.
- Enum values have no prefix, relying on Nim 2 overloadable enums, and no two
  public enums share a value name, so unqualified use is never ambiguous:
  - `VerdictKind`: `Success`, `Failure`, `Ignore`.
  - `TransitionReason`: `FailureThresholdReached`, `FailureRateReached`,
    `SlowCallRateReached`, `ServerHint`, `OpenTimeoutElapsed`,
    `ProbeSucceeded`, `ProbeFailed`, `Manual` (their `$` text is unchanged).
  - `CallOutcome` (`onCall`): `Succeeded`, `Failed`, `Ignored`, `Rejected`,
    `ShadowRejected`.
  - `CallResultKind` (`tryCall`): `Returned`, `Raised`, `Refused`.
  `Ok` was rejected: Nim compares identifiers case-insensitively after the
  first letter, so it clashes with `unittest`'s `OK`.
- `ErrorClassifier`, `TransitionCallback` and `CallCallback` are `{.gcsafe.}`:
  they run on whichever thread makes the call. The Chronos `callAsync` takes
  a `{.gcsafe, raises: [].}` `fn`, as Chronos async procs are, and needs no
  casts.
- Internal modules live in `src/circuit_breaker/private`. The call APIs are in
  `calls.nim` and `report` in `report.nim`; `circuit_breaker` re-exports them
  and the core, except `newCallTimeoutError` (for the async modules).
- Stability: the core, `async`, `chronos_async`, `testing`, `logs` and
  `prometheus` are stable for 1.0. `keyed` is experimental until its
  thread-safety does not depend on `--mm:atomicArc`.

## Consequences

- Breaking for 0.3 users: config construction, enum names and callbacks that
  touch GC'd globals (a single-threaded program can wrap them in
  `{.cast(gcsafe).}`).
- New numeric settings are reconfigurable by default (`reconfigure` copies
  every field except an explicit list).
- ADRs written before this one keep the old names as historical record.

## Evidence

`src/circuit_breaker/types.nim`, `calls.nim`, `chronos_async.nim`,
`private/`; the whole test suite passes unchanged in behavior.
