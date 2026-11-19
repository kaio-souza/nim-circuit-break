## Helpers for testing code that uses circuit breakers (V1, N9).
##
## .. code-block:: nim
##   import circuit_breaker, circuit_breaker/testing
##   let clock = newFakeClock()
##   let cb = newCircuitBreaker(initBreakerConfig(clock = clock.source))
##   clock.advance(initDuration(seconds = 30))  # no sleep needed

import std/[times, atomics]
import types

type
  FakeClockObj = object
    nanos: Atomic[int64]
  FakeClock* = ref FakeClockObj
    ## Manually driven monotonic clock. Thread-safe.

proc newFakeClock*(start = 1_000_000_000'i64): FakeClock =
  result = FakeClock()
  result.nanos.store(start)

proc now*(c: FakeClock): int64 = c.nanos.load(moAcquire)

proc advance*(c: FakeClock; d: Duration) =
  discard c.nanos.fetchAdd(d.inNanoseconds, moAcquireRelease)

proc source*(c: FakeClock): Clock =
  ## The `Clock` to pass to `initBreakerConfig(clock = ...)`.
  ## The breaker must not outlive `c`.
  let p = addr c[]
  result = proc(): int64 {.gcsafe, raises: [].} = p.nanos.load(moAcquire)
