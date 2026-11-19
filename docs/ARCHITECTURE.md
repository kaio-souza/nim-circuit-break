# Architecture

The code as it stands in v0.2.0. The reasons behind each choice are in [`decisions/`](decisions/README.md).

## Modules

```
src/
  circuit_breaker.nim          # entry point: re-exports types and core
  circuit_breaker/
    types.nim                  # enums, BreakerConfig, validate/diagnose, events, metrics, CircuitOpenError
    window.nim                 # SlidingWindow: count and time windows, O(1)
    core.nim                   # state machine, Permit, call/tryCall/callOr/withBreaker, control and inspection
    async.nim                  # callAsync (std/asyncdispatch), explicit import
    keyed.nim                  # KeyedBreaker[K]: one breaker per key with LRU, explicit import
    testing.nim                # FakeClock, explicit import
```

Module dependencies: `types` ← `window` ← `core` ← (`async`, `keyed`). `testing` depends only on `types`. No dependency outside the standard library ([ADR-0010](decisions/0010-zero-dependencies-and-async.md)).

## Call flow

Every API (`call`, `tryCall`, `callOr`, `withBreaker`, `callAsync`, `KeyedBreaker.call`) is built on the same **acquire permit → record outcome** pair:

```
call(fn)
  └─ acquire()                 → Permit  or  CircuitOpenError
       ├─ Closed/Disabled: reads the atomic word, grants without a lock
       └─ other states: short lock
            ├─ Open and deadline passed → transition to HalfOpen (lazy)
            ├─ HalfOpen: grants if probesInFlight < halfOpenMaxProbes
            └─ otherwise: rejects (or grants in shadow mode)
  └─ fn()
  └─ Permit.record(verdict)
       ├─ success in Closed with the consecutive policy: no lock (fast path)
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

| Field | Access | Purpose |
|---|---|---|
| `packed` | atomic | `(generation shl 3) or state` in one word |
| `needsStart`, `fastSuccess`, `hasConsecutive` | atomic | flags that let the fast path skip the clock and the lock |
| `successes`, `callbackErrors` | atomic | counters incremented outside the lock |
| `window`, `consecutive`, `openUntil`, `openLevel`, `probesInFlight`, history, other counters | under `lock` | policy and transition state |

Without `--threads:on` the lock is compiled out.

## Sliding windows

`window.nim` implements two variants with O(1) cost per call and fixed memory ([ADR-0008](decisions/0008-o1-sliding-windows.md)):

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
  t_async.nim            # Y1
  t_keyed.nim            # N2
  t_cbdisabled.nim(s)    # N3, compiled with -d:cbDisabled
  compile_fail/          # programs that must NOT compile (Permit is not copyable)
benchmarks/
  harness.nim            # warm-up, 30 samples, median/p95/p99, allocations, optional JSON
  b_core.nim             # BM0, BM1, BM3, BM6, BM8, BM9
  b_window.nim           # BM5
  b_threads.nim          # BM2
  b_keyed.nim            # BM7
scripts/
  check_traceability.nim # validates docs/TRACEABILITY.md against tests and benchmarks
```

Each test name cites the SPEC IDs it verifies (`test "S5: ..."`); the traceability script relies on these names ([ADR-0002](decisions/0002-evidence-policy.md)).

## Commands

```sh
nimble test            # all tests
nimble bench           # benchmarks (timings with ORC, allocations with ARC, cbDisabled variant)
nimble trace           # traceability matrix
nim doc --project --outdir:htmldocs src/circuit_breaker.nim
```

`nimble test` requires the repository to have at least one commit. Without one, run tests directly: `nim c -r tests/t_api.nim`.

## CI

- `.github/workflows/ci.yml`: tests on orc/arc × threads on/off, release and debug; builds the examples; generates the API docs; validates the matrix.
- `.github/workflows/bench.yml`: runs `nimble bench` on `main` and publishes the numbers in the job summary, without failing.

Details in [ADR-0013](decisions/0013-benchmark-methodology.md) and [ADR-0014](decisions/0014-continuous-integration.md).
