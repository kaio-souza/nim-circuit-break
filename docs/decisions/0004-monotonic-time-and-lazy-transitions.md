# ADR-0004: Injectable monotonic clock and lazy transitions

- Status: Accepted
- Date: 2026-11-19
- Requirements: S4, T1, T2, T6, V1, N9

## Context

v0.1 used `DateTime` (wall clock), which is subject to NTP, daylight saving time and manual changes: the circuit could stay open for hours or close early. The open period counted from the start of the failing call, so a slow call shortened the pause. Testing time-based behavior required `sleep`.

## Decision

- Time is a `Clock = proc(): int64` in nanoseconds. The default is `getMonoTime().ticks`; tests and users can inject another.
- `circuit_breaker/testing` exports `FakeClock` (thread-safe, moved with `advance`), so **library users** can also test without `sleep`.
- The `Open → HalfOpen` transition is **lazy**: it happens on the first call after the deadline. There is no timer and no background thread.
- The open period starts at the **end** of the failing call.
- The clock is only read when needed: in `Closed`, without slow-call detection and without `onCall`, granting a permit does not read the clock.

## Consequences

- `state()` keeps reporting `Open` after the deadline until a call happens. This is documented on `state()`; `retryAfter` tells how long is left.
- No helper threads: nothing to start, stop or leak.

## Evidence

`t_transitions`: T1, T2, S4. `t_api`: V1/N9/T6. The whole test suite runs on `FakeClock`.
