# ADR-0002: Evidence policy

- Status: Accepted
- Date: 2026-11-19
- Requirements: EV1–EV7, Q1–Q3, R1, V5

## Context

v0.1 claimed "high performance" without a single benchmark, and its only test did not compile. Three serious semantic bugs (counter reset before the call, `HalfOpen` closing before the probe, probe discarded) went unnoticed.

## Decision

A feature is delivered only with:

1. A **test** citing the SPEC ID in its name (`test "S5: ..."`).
2. A **value test** for differentiators: the scenario with the problem without the feature and the fix with it (`tests/t_values.nim`).
3. A **benchmark** when it affects the hot path, memory or concurrency.
4. A **regression test** for every fixed bug.
5. A filled-in row in [`TRACEABILITY.md`](../TRACEABILITY.md), checked automatically.

Tests are deterministic: injected clock, no `sleep`, no network. Performance claims in the README point to measured, reproducible numbers.

## Consequences

- More work per feature; in exchange, the README only claims what the repository proves.
- `scripts/check_traceability.nim` fails CI if a requirement marked done has no test, if a cited benchmark does not exist, or if a test cites an ID missing from the matrix.

## Evidence

- `nimble trace`: 116 requirements, 86 done or partial, all with tests.
- 59 tests, 7 value tests, v0.1 regressions in `t_transitions.nim` (F1, S5, S6).
