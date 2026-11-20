# circuit_breaker

A circuit breaker for Nim, built to be correct first and fast second, with
evidence for both: every feature has tests that cite its requirement ID, and
every performance claim below comes from a benchmark in this repository.

```nim
import circuit_breaker, std/times

let cb = newCircuitBreaker(initBreakerConfig(
  name = "payments", failureThreshold = 5,
  openTimeout = initDuration(seconds = 30)))

try:
  let body = cb.call(proc(): string = fetchPayment())
except CircuitOpenError as e:
  echo "payments unavailable, retry in ", e.retryAfter
```

Failures of your function propagate unchanged; a rejected call raises
`CircuitOpenError`, so the two are never confused.

## Features

- **Correct state machine**: `Closed → Open → HalfOpen → Closed/Open`, lazy
  transitions (no timers), a limited number of concurrent probes, and
  administrative `ForcedOpen`/`Disabled` states.
- **Policies**: consecutive failures, failure rate over a count or time window
  (O(1) per call), slow calls, an error classifier (e.g. ignore HTTP 4xx), a
  result classifier (e.g. HTTP 503 returned without raising), and server
  hints (`Retry-After`).
- **Recovery**: exponential backoff on repeated reopenings, jitter that only
  delays (never earlier), configurable `successThreshold`.
- **Ergonomic API**: `call`, `tryCall` (explicit result), `callOr` (fallback),
  `withBreaker` (no closure), and a `Permit` guard that records a failure
  automatically if you forget to record the outcome, so a probe can never
  leave the breaker stuck in `HalfOpen`.
- **Observability**: transition and call events with context, `metrics()`
  snapshot, `explain()` (why did it open?), `report()` for logs; opt-in
  latency percentiles (`latencyPrecision`, `latencyQuantile`); Prometheus text
  exposition (`circuit_breaker/prometheus`); transition logging with
  `std/logging` (`circuit_breaker/logs`).
- **Safe adoption**: shadow mode evaluates everything but never rejects;
  `diagnose()` warns about risky configs; `reconfigure()` at runtime;
  `-d:cbDisabled` turns every breaker into a zero-cost pass-through.
- **Async and keyed**: `callAsync` for `std/asyncdispatch` and for Chronos
  (`circuit_breaker/chronos_async`, Chronos installed by you); with Chronos a
  cancelled call never leaves the breaker stuck and is not counted by default;
  `callTimeout` limits each async call and counts expiry as a failure. One
  breaker per key (host, endpoint, tenant) with a capacity limit and LRU
  eviction.
- **Testing helpers**: `FakeClock` lets you test time-based behavior without
  `sleep`.

## Usage

```nim
import circuit_breaker, std/times

# Failure rate over the last 30 s, with slow calls and HTTP-aware classification.
let cb = newCircuitBreaker(initBreakerConfig(
  name = "orders-api",
  policy = FailureRate,
  failureRateThreshold = 0.5,
  minimumCalls = 20,
  windowKind = TimeWindow,
  windowDuration = initDuration(seconds = 30),
  slowCallDuration = initDuration(seconds = 2),
  slowCallRateThreshold = 0.8,
  backoffMultiplier = 2.0,
  jitter = 0.2,
  classifyError = proc(e: ref CatchableError): Verdict =
    if e of HttpError and (ref HttpError)(e).status < 500: ignoreCall()
    else: countAsFailure()))

# Fallback instead of exceptions:
let orders = cb.callOr(proc(): seq[Order] = fetchOrders(),
                       proc(e: ref CatchableError): seq[Order] = cachedOrders())

# No closure allocated; `return` inside the block counts as success:
withBreaker(cb):
  sendInvoice()

# Explicit result:
let r = cb.tryCall(proc(): int = compute())
case r.kind
of crOk: echo r.value
of crRejected: echo "retry in ", r.rejection.retryAfter
of crFailed: echo "failed: ", r.error.msg

# Why did it open?
echo cb.explain[^1].reason   # e.g. "failure rate threshold reached"
echo cb.report
```

More in [`examples/`](examples): `basic.nim`, `http_policies.nim`,
`async_keyed.nim`, `composition.nim` (retry, backoff, bulkhead and timeout
around a breaker; see [`docs/COMPOSITION.md`](docs/COMPOSITION.md)).

## States

```
                 policy violated
   ┌──────────────────────────────────┐
   │                                  ▼
Closed ◄── successThreshold ── HalfOpen ── probe fails ──► Open
                successes          ▲                       │
                                   └──── openTimeout ──────┘
                                       (backoff + jitter)
```

- **Closed**: calls run; outcomes feed the policy.
- **Open**: calls are rejected with `CircuitOpenError` (carrying `retryAfter`).
  After the open period, the next call becomes a probe.
- **HalfOpen**: up to `halfOpenMaxProbes` probes run. `successThreshold`
  successes close the circuit; any failure reopens it with a longer backoff.

| From | To | When |
|---|---|---|
| `Closed` | `Open` | the policy is violated: `failureThreshold` failures in a row, or the failure rate or slow-call rate of the window reaches its threshold after `minimumCalls`; or a failure carries a server hint (`Retry-After`) |
| `Open` | `HalfOpen` | the first call after the open period (no timer: evaluated lazily) |
| `HalfOpen` | `Closed` | `successThreshold` probe successes |
| `HalfOpen` | `Open` | any probe failure; the open period grows by `backoffMultiplier` up to `maxOpenTimeout` |
| any | `ForcedOpen` / `Disabled` | `forceOpen()` / `disable()` |
| any | `Closed` | `reset()` |

## Thread safety

With `--threads:on` a `CircuitBreaker` can be shared between threads. The
state lives in one atomic word; a success in `Closed` with the
consecutive-failures policy and every rejection take no lock; windowed
policies record a success under a short lock
([ADR-0015](docs/decisions/0015-lean-locked-path-for-windowed-policies.md));
transitions take a short lock; callbacks run outside it. Counters written by
every call sit on their own cache lines, so threads sharing a breaker do not
slow each other down through false sharing. Keep the breaker in a long-lived owner (e.g. a
global): permits reference it without reference counting. Callbacks are not
required to be `gcsafe`; in threaded code wrap them with `{.cast(gcsafe).}`.
`KeyedBreaker` is meant for single-threaded and async code (or `--mm:atomicArc`).

## Performance

Intel Core i5-10210U (laptop), Nim 2.2.4, `-d:release --opt:speed --mm:orc
--threads:on`, 2026-11-20. Each value is the lowest of 8 runs of the median of
30 samples: single runs on this machine vary by up to 2x because of other load,
and the lowest median is the stable figure (the second lowest is within 1 to
3 ns). Allocations counted with `--mm:arc -d:nimAllocStats`. Reproduce with
`nimble bench`.

| Benchmark | ns/op | allocs/op |
|---|---:|---:|
| Baseline: direct closure call | 1.6 | 0 |
| `call` in Closed (success) | 37 | 0 |
| `withBreaker` (no closure) | 34 | 0 |
| `tryAcquire` + `success` | 38 | 0 |
| `tryCall` (explicit result) | 48 | 0 |
| `call` with `FailureRate` policy (window 100) | 60 | 0 |
| `call` with slow-call detection (reads the clock twice) | 103 | 0 |
| `call` with latency histogram (O4, reads the clock twice) | 85 | 0 |
| `call` with an `onCall` callback | 115 | 0 |
| Rejection via `tryAcquire`, `ForcedOpen` | 23 | 0 |
| Rejection via `tryAcquire`, `Open` | 31 | 0 |
| Rejection via `call` (raises `CircuitOpenError`) | 122 | 3 |
| Count window, size 10 to 100 000 | 48–51 | 0 |
| Time window, 10 to 600 buckets | 100–101 | 0 |
| Keyed breaker call (hit) | 68 | 0 |
| `renderPrometheus`, 2 breakers | 32 µs | 527 |

Shared breaker, `call` in Closed, wall time per operation across all threads
(3 runs): 30 ns with 1 thread, 26 ns with 2, 23–25 ns with 4, 17–21 ns with 8
(48–60 Mops/s total). Compare runs on the same machine.

## Quality

- 90 tests, run in CI with `orc`/`arc`, threads on/off, release and debug.
- Value tests that show the problem without each feature and the fix with it
  (`tests/t_values.nim`, and the O4 and O6 suites).
- A model test: 1000 random sequences of calls, failures and clock advances
  compared step by step with an executable model of the specification
  (`tests/t_model.nim`, with [proptest](https://github.com/kaio-souza/nim-proptest)).
- A differential test: the lean success path against the general one on 600
  random sequences (`tests/t_lean_path.nim`).
- Multi-threaded stress and rejection tests, run under ThreadSanitizer for
  v0.3.0 (no races reported); API and value tests run under AddressSanitizer
  for v0.2.0 (no errors or leaks).
- Requirement traceability: [`docs/TRACEABILITY.md`](docs/TRACEABILITY.md),
  checked in CI (every SPEC requirement has a row); every exported symbol is
  documented, also checked in CI.

## Documentation

- [Roadmap](docs/ROADMAP.md): current status, next versions, known limitations.
- [Architecture](docs/ARCHITECTURE.md): modules, call flow, concurrency model.
- [Design decisions](docs/decisions/README.md): one ADR per technical choice.
- [Specification](docs/SPEC.md): every requirement with its ID.
- [Composition](docs/COMPOSITION.md): retry, backoff, bulkhead and timeout around a breaker.
- [Plan to v1.0](docs/PLAN.md): the work left before v1.0.
- [Changelog](CHANGELOG.md).

## Installation

Not yet published to the Nimble index. Install from the repository:

```
nimble install https://github.com/kaio-souza/nim-circuit-break
```

Requires Nim >= 2.2.4. No dependencies outside the standard library.

## License

MIT
