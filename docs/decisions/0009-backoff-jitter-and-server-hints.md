# ADR-0009: Exponential backoff, delay-only jitter and server hints

- Status: Accepted
- Date: 2026-11-19
- Requirements: T3, T4, G4, G5, S7, S8

## Context

A fixed open period makes the breaker probe a service that is still down at the same pace, forever. Several instances that opened together also probe together (thundering herd). And the server sometimes says when it will be back (`Retry-After`).

## Decision

- **Backoff**: on each consecutive reopening, the open period is `openTimeout * backoffMultiplier^n`, capped at `maxOpenTimeout`. Closing the circuit resets `n`. `backoffMultiplier = 1.0` disables it.
- **Jitter**: adds a random fraction of up to `jitter` to the period. It **only delays, never advances**, so a probe never happens before the configured minimum. The seed is configurable (`seed`) for deterministic tests.
- **Server hint**: the classifier can return `countAsFailure(openFor = ...)`; the circuit opens for exactly that duration, ignoring backoff and jitter.
- **Probes**: in `HalfOpen`, up to `halfOpenMaxProbes` concurrent calls; `successThreshold` successes close it; any failure reopens it with a longer backoff.

## Consequences

- The actual period may exceed `maxOpenTimeout` by up to `jitter` times its value.
- `diagnose()` warns about ineffective or risky combinations (e.g. backoff with `maxOpenTimeout == openTimeout`, `jitter > 0.5`).

## Evidence

`t_transitions`: T3/G4, T4 (within bounds, delay only), S7, S8. `t_policies`: G5. `t_values`: V-T4 (jitter spreads the probes of instances that opened together).
