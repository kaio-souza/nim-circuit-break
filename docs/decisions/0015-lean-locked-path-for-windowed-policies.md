# ADR-0015: Lock-free success only for the consecutive policy; a lean locked path for windowed policies

- Status: Accepted
- Date: 2026-11-20
- Requirements: P2 (amends its scope), P5, F2, F3

## Context

P2 asks for `Closed` without locks, with atomic operations only. That holds for
the consecutive-failures policy since v0.2. With a sliding window (the
`FailureRate` policy, or slow-call detection), a success updates the window and
may open the circuit, so the window and the decision must change together.

Measured in v0.3 (interleaved runs, minimum of rounds, single thread):

- the lock costs about 7 ns of the 56 ns that a `FailureRate` success cost;
- most of the rest was event bookkeeping, paid even when no callback was set;
- a lean locked path without that bookkeeping brought a success to about 45 ns.

A lock-free window would need the counters, the ring or buckets, and the trip
decision to stay consistent under concurrent writers, for at most the 7 ns of
the lock.

## Decision

- P2 is satisfied as: **lock-free success and rejection for the consecutive
  policy; for windowed policies, a lean locked success path** when no callback
  is set, and the general path otherwise.
- The lean path must decide exactly like the general path. A differential test
  (`tests/t_lean_path.nim`) checks it on random sequences.
- A lock-free window is reconsidered only with a measured case where the lock
  dominates (for example contention on one breaker from many threads with a
  windowed policy).

## Consequences

- P2 moves to done with this scope; the SPEC row notes the amendment.
- Windowed policies keep a lock per success (about 7 ns uncontended). Under
  heavy contention on one breaker, a windowed policy scales worse than the
  consecutive one; the README states it.

## Evidence

`t_lean_path` (P2: 600 random sequences, three configurations; F2 regression
tests). BM1 with `FailureRate`: -8% minimum against v0.2 in interleaved runs.
Breakdown measured with a dedicated micro-benchmark during v0.3.
