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
  snapshot, `explain()` (why did it open?), `report()` for logs.
- **Safe adoption**: shadow mode evaluates everything but never rejects;
  `diagnose()` warns about risky configs; `reconfigure()` at runtime;
  `-d:cbDisabled` turns every breaker into a zero-cost pass-through.
- **Async and keyed**: `callAsync` for `std/asyncdispatch`; one breaker per
  key (host, endpoint, tenant) with a capacity limit and LRU eviction.
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
`async_keyed.nim`.

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

## Thread safety

With `--threads:on` a `CircuitBreaker` can be shared between threads. The
state lives in one atomic word; a success in `Closed` with the
consecutive-failures policy takes no lock; transitions take a short lock;
callbacks run outside it. Keep the breaker in a long-lived owner (e.g. a
global): permits reference it without reference counting. Callbacks are not
required to be `gcsafe`; in threaded code wrap them with `{.cast(gcsafe).}`.
`KeyedBreaker` is meant for single-threaded and async code (or `--mm:atomicArc`).

## Performance

Median of 30 samples, `-d:release --opt:speed --mm:orc --threads:on`,
Nim 2.2.4, Intel Core i5-10210U (laptop), 2026-11-19. Reproduce with
`nimble bench`.

| Benchmark | ns/op | allocs/op |
|---|---:|---:|
| Baseline: direct closure call | 4.7 | 0 |
| `call` in Closed (success) | 46 | 0 |
| `withBreaker` (no closure) | 41 | 0 |
| `tryAcquire` + `success` | 54 | 0 |
| `call` with `FailureRate` policy | 73 | 0 |
| `call` with slow-call detection (reads the clock) | 127 | 0 |
| Rejection via `tryAcquire` (no exception) | 63 | 0 |
| Rejection via `call` (raises `CircuitOpenError`) | 270 | 3 |
| Count window, size 10 to 100 000 | 68–72 | 0 |
| Time window, 10 to 600 buckets | 135–155 | 0 |
| Keyed breaker lookup (hit) | 65 | 0 |

Shared breaker, `call` in Closed: 11.7 Mops/s with 1 thread, 20.2 Mops/s total
with 8 threads. Numbers on a laptop vary between runs; compare runs on the
same machine.

## Quality

- 59 tests across `orc`/`arc`, threads on/off, release and debug.
- Value tests that show the problem without each feature and the fix with it
  (`tests/t_values.nim`).
- Multi-threaded stress test, also run under ThreadSanitizer (no races
  reported); API and value tests run under AddressSanitizer (no errors or leaks).
- Requirement traceability: [`docs/TRACEABILITY.md`](docs/TRACEABILITY.md),
  checked by `nimble trace` in CI.

## Documentation

- [Roadmap](docs/ROADMAP.md): current status, next versions, known limitations.
- [Architecture](docs/ARCHITECTURE.md): modules, call flow, concurrency model.
- [Design decisions](docs/decisions/README.md): one ADR per technical choice.
- [Specification](docs/SPEC.md): every requirement with its ID.
- [Changelog](CHANGELOG.md).

## Installation

Not yet published to the Nimble index. Install from the repository:

```
nimble install https://<repository-url>
```

Requires Nim >= 2.2.4. No dependencies outside the standard library.

## License

MIT
