# ADR-0005: State in one atomic word, short lock on transitions

- Status: Accepted
- Date: 2026-11-19
- Requirements: C1–C6, P1, P2, S7

## Context

A breaker is shared by every call to a service; in multi-threaded servers it sits on the path of every request. A global lock serializes everything; a fully lock-free design (CAS across the whole policy) is hard to prove correct, especially with sliding windows and history.

## Decision

- **State and generation in one atomic word** (`packed = (generation shl 3) or state`). Every transition increments the generation.
- **Granting** in `Closed`/`Disabled` only reads that word: no lock.
- **Recording a success** in `Closed` with the consecutive-failures policy and no `onCall` takes no lock: it increments an atomic counter and only takes the lock if there are consecutive failures to reset (atomic `hasConsecutive` flag).
- **Everything else** (failures, window, transitions, probes) runs under a short lock. The `Open → HalfOpen` transition and the probe count happen under that lock, so only one thread performs the transition. Requirement C3 asked for CAS; the lock gives the same guarantee with simpler code, and its cost only shows up off the happy path.
- **Generation in the `Permit`**: an outcome that arrives after a transition (e.g. a stale probe) is counted in metrics but does not affect the policy.
- Without `--threads:on`, the lock is compiled out (`when compileOption("threads")`).
- No global state: every breaker is independent.

## Consequences

- `call` in `Closed`: 46 ns, 0 allocations; 11.7 Mops/s with 1 thread, 20.2 Mops/s with 8 threads sharing the breaker.
- With `FailureRate` or slow-call detection, successes also go through the lock (73–127 ns). Rejection in `Open` goes through the lock (63 ns). Both are on the v0.3 roadmap.
- Atomic counters have no false-sharing padding yet (P5).
- A `Permit` holds a raw pointer to the breaker (ADR-0006).

## Evidence

`t_concurrency`: V3/S7/C1/C2/C3, 8-thread stress (1000 consecutive runs without failure), ThreadSanitizer clean. BM1 and BM2. orc/arc × threads on/off matrix in CI.
