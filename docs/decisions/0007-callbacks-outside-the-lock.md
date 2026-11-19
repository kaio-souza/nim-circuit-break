# ADR-0007: Callbacks outside the lock and isolated from exceptions

- Status: Accepted
- Date: 2026-11-19
- Requirements: O1–O3, B1, B4

## Context

User callbacks (logging, metrics, alerts) may be slow, raise, or call the breaker itself. Run under the lock, they cause deadlocks or stall every call; if they raise, they can corrupt the state or mask the result of the protected call.

## Decision

- Two callbacks: `onTransition(TransitionEvent)` and `onCall(CallEvent)`. Events carry the name, states, reason, window statistics at that moment, `openFor` and a monotonic timestamp.
- Under the lock, events are only **queued** (`Pending`). After the lock is released, `dispatch` runs the callbacks.
- Exceptions in callbacks (including `Exception`) are caught and counted in `callbackErrors` (visible in `metrics()`). They never change the state or the call result.
- Callbacks do not need to be `gcsafe`; in multi-threaded code users wrap them in `{.cast(gcsafe).}`.
- Regardless of callbacks, the last `historySize` transitions are kept in a ring buffer read by `explain()`, which answers "why did it open?" without logs.

## Consequences

- Callbacks always see a consistent state.
- Setting `onCall` disables the fast success path (the event must be built under the lock).

## Evidence

`t_api`: O1/O3/B1, O2 (a raising callback does not corrupt the breaker), B4. `t_values`: V-B4. BM1 "call with onCall event", BM9.
