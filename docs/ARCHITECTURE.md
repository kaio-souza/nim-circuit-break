# Architecture

The code as it stands in v0.3.0. The reasons behind each choice are in [`decisions/`](decisions/README.md).

## Modules

```
src/
  circuit_breaker.nim          # entry point: re-exports types, core, calls and report
  circuit_breaker/
    types.nim                  # enums, BreakerConfig (with defaults), validate/diagnose, events, metrics, errors
    core.nim                   # state machine, Permit, acquire/record, control and inspection
    calls.nim                  # call/tryCall/callOr/withBreaker on top of Permit
    report.nim                 # report: human-readable summary (N10)
    prometheus.nim             # renderPrometheus: text exposition (O6/B3), explicit import
    logs.nim                   # withTransitionLog: std/logging hook (O7), explicit import
    async.nim                  # callAsync (std/asyncdispatch) with callTimeout, explicit import
    chronos_async.nim          # callAsync for Chronos: cancellation (Y3) and callTimeout (T5); needs Chronos
    keyed.nim                  # KeyedBreaker[K]: one breaker per key with LRU, explicit import (experimental)
    testing.nim                # FakeClock, explicit import
    private/                   # internal, not part of the API (ADR-0019)
      window.nim               # SlidingWindow: count and time windows, O(1)
      latency.nim              # log-bucket latency histogram math (O4)
      sync.nim                 # lock that compiles away without --threads:on
```

Module dependencies: `types` ← (`private/window`, `private/latency`, `private/sync`) ← `core` ← (`calls`, `report`, `async`, `chronos_async`, `prometheus`); `keyed` also uses `calls`. `logs` and `testing` depend only on `types`. The core never imports the optional modules (checked by a test in `t_prometheus`). No dependency outside the standard library ([ADR-0010](decisions/0010-zero-dependencies-and-async.md)), except Chronos for `chronos_async`, which is not a package dependency ([ADR-0016](decisions/0016-chronos-cancellation-and-timeouts.md)).

## Call flow

Every API (`call`, `tryCall`, `callOr`, `withBreaker`, `callAsync`, `KeyedBreaker.call`) is built on the same **acquire permit → record outcome** pair:

```
call(fn)
  └─ acquire()                 → Permit  or  CircuitOpenError
       ├─ Closed/Disabled: reads the atomic word, grants without a lock
       ├─ ForcedOpen: rejects without a lock or a clock read (BM3)
       ├─ Open, deadline far: rejects without a lock; on Linux the coarse
       │  monotonic clock proves the deadline has not passed (BM3)
       └─ other states: short lock
            ├─ Open and deadline passed → transition to HalfOpen (lazy)
            ├─ HalfOpen: grants if probesInFlight < halfOpenMaxProbes
            └─ otherwise: rejects (or grants in shadow mode)
  └─ fn()
  └─ Permit.record(verdict)
       ├─ success in Closed with the consecutive policy: no lock (fast path)
       ├─ success with a window and no callbacks: lean locked path
       │  (ADR-0015; checked against recordCore by t_lean_path)
       └─ other cases: recordCore under the lock
            ├─ updates counters and window
            ├─ evaluates the policy → transition to Open/Closed
            └─ queues pending events
  └─ dispatch: callbacks run outside the lock
```

- A `Permit` stores the **generation** of the state it was granted in. If the state changed meanwhile, its outcome only feeds metrics ([ADR-0005](decisions/0005-concurrency-model.md)).
- A `Permit` destroyed without an outcome records a failure ([ADR-0006](decisions/0006-permit-guard.md)).

## Internal state

`CircuitBreakerObj` (in `core.nim`) separates what is read without a lock from what the lock protects:

Fields are grouped by how threads touch them, and each group written by every call has its own cache line (64-byte pads; P5/R3). Compile-time `offsetOf` checks keep the layout from regressing.

| Group | Fields | Access | Purpose |
|---|---|---|---|
| read by every call | `packed`, `needsStart`, `fastSuccess`, `hasConsecutive`, `rejectFast`, `openUntil`, `cfg`, `latency` | atomic or fixed | state word `(generation shl 3) or state`, fast-path flags, open deadline (written before the state's release store) |
| written by every success | `successes` | atomic, own line | |
| written by every rejection | `rejected` | atomic, own line | |
| written by every sample | `latencySum` | atomic, own line | O4 |
| under the lock | `window`, `consecutive`, `openLevel`, `probesInFlight`, history, other counters | `lock` | policy and transition state |

Without `--threads:on` the lock is compiled out.

## Sliding windows

`private/window.nim` implements two variants with O(1) cost per call and fixed memory ([ADR-0008](decisions/0008-o1-sliding-windows.md)):

- **Count**: a ring buffer of `uint8` (bit 0 = failure, bit 1 = slow) with incremental totals.
- **Time**: `windowBuckets` buckets indexed by epoch (`now div bucketNanos`); only the buckets of elapsed epochs are cleared.

The window is only fed when the policy is `FailureRate` or slow-call detection is on.

## Tests and benchmarks

```
tests/
  config.nims            # path to ../src
  helpers.nim            # shared helpers
  t_transitions.nim      # S*, F1, T*, A10, A11
  t_policies.nim         # F2–F8, G5
  t_api.nim              # A*, E*, O*, B*, K*, N1, N4, N8–N10, V1
  t_values.nim           # value tests (problem without the feature × fix with it)
  t_concurrency.nim      # 8-thread stress (V3, S7, C1–C3)
  t_async.nim            # Y1, T5
  t_chronos.nim          # Y2, Y3, T5 (needs Chronos)
  t_keyed.nim            # N2
  t_model.nim            # V2/Q5: model test with proptest (1000 random sequences)
  t_latency.nim          # O4
  t_prometheus.nim       # O6, B3
  t_logs.nim             # O7
  t_rejection.nim        # rejections: hints, deadline handover, real clock, 8 threads
  t_lean_path.nim        # P2 differential test, F2 regressions
  t_cbdisabled.nim(s)    # N3, compiled with -d:cbDisabled
  compile_fail/          # programs that must NOT compile (Permit is not copyable)
benchmarks/
  harness.nim            # warm-up, 30 samples, median/p95/p99, allocations, optional JSON
  b_core.nim             # BM0, BM1, BM3, BM6, BM8, BM9, BM10 (O4), BM11 (O6), BM12 (O7)
  b_window.nim           # BM5
  b_threads.nim          # BM2
  b_keyed.nim            # BM7
  b_async.nim            # BM13: callAsync on asyncdispatch
  b_chronos.nim          # BM14: callAsync on Chronos
scripts/
  check_traceability.nim # validates docs/TRACEABILITY.md against SPEC, tests and benchmarks
  check_docs.nim         # every exported symbol has a doc comment (D3)
```

Each test name cites the SPEC IDs it verifies (`test "S5: ..."`); the traceability script relies on these names ([ADR-0002](decisions/0002-evidence-policy.md)).

## Commands

```sh
nimble test            # all tests
nimble bench           # benchmarks (timings with ORC, allocations with ARC, cbDisabled variant)
nimble trace           # traceability matrix
nimble doccheck        # public API documentation coverage
nim doc --project --outdir:htmldocs src/circuit_breaker.nim
```

`nimble test` requires the repository to have at least one commit. Without one, run tests directly: `nim c -r tests/t_api.nim`.

## CI

- `.github/workflows/ci.yml`: tests on orc/arc × threads on/off, release and debug; builds the examples; generates the API docs; validates the matrix.
- `.github/workflows/bench.yml`: runs `nimble bench` on `main` and publishes the numbers in the job summary, without failing.

Details in [ADR-0013](decisions/0013-benchmark-methodology.md) and [ADR-0014](decisions/0014-continuous-integration.md).
