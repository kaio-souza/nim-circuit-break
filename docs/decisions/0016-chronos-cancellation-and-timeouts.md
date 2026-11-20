# ADR-0016: Chronos module, cancellation policy and per-call timeouts

- Status: Accepted
- Date: 2026-11-20
- Requirements: Y2, Y3, T5, A5

## Context

ADR-0010 kept the core free of dependencies and planned Chronos in a separate
module. Chronos and `std/asyncdispatch` differ in two ways that matter here:
Chronos can cancel a future (and its timers), `asyncdispatch` cannot; and
Chronos requires `{.async.}` procs to be `gcsafe` and to declare what they raise.

## Decision

- `circuit_breaker/chronos_async` provides `callAsync` for Chronos. Chronos is
  **not** in `requires`: only programs that import this module need it. It is a
  `taskRequires` for the `test` and `bench` tasks.
- The breaker's operations are called under `{.cast(gcsafe).}` inside that
  module: they call user callbacks and clocks, which the effect system cannot
  prove gcsafe, and they are thread-safe by construction (ADR-0005, ADR-0007).
  `fn` must be `raises: []`, which every Chronos `{.async.}` proc is.
- **Cancellation (Y3):** cancelling the future returned by `callAsync` cancels
  `fn` and records `onCancel`, by default `ignoreCall()`: a client giving up says
  nothing about the dependency's health. A cancelled probe frees its slot.
  `onCancel = countAsFailure()` is available for callers that cancel only on
  dependency trouble.
- **Timeout (T5):** `callTimeout` in the config (zero: off), applied by both
  async modules with `withTimeout`, not `wait`: `wait` signals expiry with
  `AsyncTimeoutError`, which `fn` itself may raise. Expiry counts as a failure
  and raises `CallTimeoutError`, the same type in both runtimes. A call that has
  already finished arms no timer.
- Sync calls ignore `callTimeout`: a running Nim proc cannot be interrupted
  without a thread per call. Callers enforce timeouts in the dependency call
  (`docs/COMPOSITION.md`).

## Consequences

- With `asyncdispatch`, a timed-out call keeps running in the background (its
  late outcome is ignored), and each pending call with a timeout keeps one timer
  alive for `callTimeout` (no timer cancellation). Live timers are bounded by
  call rate x timeout. The module documentation says so and points to Chronos.
- On `asyncdispatch`, `callAsync` costs about 300 ns more than awaiting `fn`
  directly (an extra future and async frame). On Chronos the difference is
  within noise (BM14). Either way it is negligible next to I/O.
- A `CallTimeoutError` raised by `fn` itself (a nested breaker that timed out)
  is an ordinary failure of `fn` for the outer breaker: it goes through the
  outer classifier.

## Evidence

`t_chronos`: Y2/A5, Y3 (cancelled probe frees its slot; `onCancel`; value test:
a naive wrapper keeps a healthy dependency open after client cancellations),
T5 (cancelled on expiry). `t_async`: T5 (abandoned call not recorded,
validation, `reconfigure`). Both: a nested breaker's `CallTimeoutError` is
classified by the outer breaker. BM13 and BM14: overhead of `callAsync` with and
without `callTimeout`; before arming no timer for finished calls, a 1 s
`callTimeout` on `asyncdispatch` cost 1.5 to 2.5 µs per call (p95 6 to 8 µs)
from accumulated timers, after it about 0.5 µs, the same as without a timeout.
