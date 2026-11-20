# Architecture Decision Records

Each file records one decision: its context, what was decided, the consequences, and where the evidence lives (test, benchmark or code). An accepted decision is not edited afterwards; if it changes, a new ADR supersedes it and the old one is marked **Superseded**.

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-scope-circuit-breaker-only.md) | Scope: circuit breaker only, composed with retry/bulkhead/rate limiting | Accepted |
| [0002](0002-evidence-policy.md) | No feature without a test, a value test and a benchmark | Accepted |
| [0003](0003-errors-and-rejection.md) | Failures propagate the original exception; rejection is `CircuitOpenError` | Accepted |
| [0004](0004-monotonic-time-and-lazy-transitions.md) | Injectable monotonic clock and timer-free transitions | Accepted |
| [0005](0005-concurrency-model.md) | State in one atomic word, short lock on transitions | Accepted |
| [0006](0006-permit-guard.md) | `Permit` guard records a failure when the outcome is forgotten | Accepted |
| [0007](0007-callbacks-outside-the-lock.md) | Callbacks outside the lock and isolated from exceptions | Accepted |
| [0008](0008-o1-sliding-windows.md) | O(1) sliding windows with fixed memory | Accepted |
| [0009](0009-backoff-jitter-and-server-hints.md) | Exponential backoff, delay-only jitter, `Retry-After` hints | Accepted |
| [0010](0010-zero-dependencies-and-async.md) | Zero dependencies; async through `asyncdispatch` in an optional module | Accepted |
| [0011](0011-keyed-breaker-lru.md) | `KeyedBreaker` with a capacity cap and LRU eviction | Accepted |
| [0012](0012-safe-adoption-switches.md) | `-d:cbDisabled`, shadow mode and `diagnose` for safe adoption | Accepted |
| [0013](0013-benchmark-methodology.md) | Own harness; allocations measured with ARC; informational benchmarks in CI | Accepted |
| [0014](0014-continuous-integration.md) | CI on the official Nim image, no third-party actions | Accepted |
| [0015](0015-lean-locked-path-for-windowed-policies.md) | Lock-free success for the consecutive policy; lean locked path for windowed policies (P2 scope) | Accepted |

## Template

```markdown
# ADR-NNNN: Title

- Status: Proposed | Accepted | Superseded by ADR-XXXX
- Date: YYYY-MM-DD
- Requirements: SPEC IDs

## Context
## Decision
## Consequences
## Evidence
```
