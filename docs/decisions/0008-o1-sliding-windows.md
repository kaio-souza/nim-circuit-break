# ADR-0008: O(1) sliding windows with fixed memory

- Status: Accepted
- Date: 2026-11-19
- Requirements: F2, F3, F4, P3

## Context

Consecutive failures miss intermittent errors: with 30% failures spread out, the counter resets on every success and the circuit never opens. A failure rate needs a window. A naive window (list of calls, recounted on every query) costs proportionally to its size and allocates.

## Decision

- **Count window**: a ring buffer of `uint8` with `windowSize` slots (bit 0 = failure, bit 1 = slow). Totals are kept incrementally: overwriting a slot subtracts the old value.
- **Time window**: `windowBuckets` buckets, each covering `windowDuration / windowBuckets`. The index is `epoch mod buckets`. Expiration clears only the buckets of the epochs elapsed since the last call (at most `windowBuckets` per call, amortized O(1)).
- The window is preallocated at creation and only fed when needed (`FailureRate` or slow-call detection).
- `minimumCalls` avoids opening on too little data; `validate` rejects `minimumCalls > windowSize` on count windows, because the rate would never be evaluated.
- Slow calls use the same window (separate bit) and open via `slowCallRateThreshold`.

## Consequences

- Constant cost regardless of size: count windows from 10 to 100 000 slots cost 68–72 ns; time windows from 10 to 600 buckets, 135–155 ns. Zero allocations.
- Time windows have a resolution of one bucket.

## Evidence

`t_policies`: F2/G1, F2 (forgets old calls), F3, F4/G2. `t_values`: V-F2 (30% intermittent), V-F4 (200 responses in 10 s). BM5 in `b_window.nim`.
