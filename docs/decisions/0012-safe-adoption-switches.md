# ADR-0012: Safe adoption with `-d:cbDisabled`, shadow mode and `diagnose`

- Status: Accepted
- Date: 2026-11-19
- Requirements: N1, N3, N4, N8, S2, A10

## Context

The biggest obstacle to adopting a circuit breaker in production is the fear that a wrong configuration will reject legitimate traffic. Being able to remove it completely, to debug or to measure, is also useful.

## Decision

- **`-d:cbDisabled`**: at compile time, `call`, `withBreaker`, `acquire` and `tryAcquire` become a direct pass-through. Cost equal to calling without a breaker.
- **Shadow mode** (`shadowMode`): the policy is evaluated and events and metrics are emitted (`coShadowRejected`, `shadowRejected`), but no call is rejected. Thresholds can be calibrated on real traffic. `ForcedOpen` still rejects in shadow mode, because it is an explicit operator action.
- **`diagnose()`**: lists warnings about valid but risky configurations, on top of the strict `validate()`.
- **`reconfigure()`**: replaces the numeric settings at runtime without losing state (the window is only rebuilt if its shape changes).
- **Administrative states**: `forceOpen()`, `disable()` and `reset()`.

## Consequences

- `-d:cbDisabled` applies to the whole binary; it does not disable a single breaker (use `disable()` for that).
- Shadow mode has the normal evaluation cost.

## Evidence

`t_cbdisabled` (compiled with `-d:cbDisabled`): N3. `t_api`: N1, N4/K3, N8. `t_transitions`: A10/S2. `t_values`: V-N1 (same decisions, nothing blocked). BM8.
