## I1: composing a circuit breaker with retry, backoff, a bulkhead and a
## timeout. The breaker only decides whether a call may run and records the
## outcome; the other patterns wrap it. Runs deterministically on a fake clock.

import std/[atomics, strformat, times]
import circuit_breaker
import circuit_breaker/testing

type
  DependencyError = object of CatchableError

  Bulkhead = object
    ## Caps concurrent calls: a rejection here never reaches the breaker.
    inFlight: Atomic[int]
    limit: int

proc tryEnter(b: var Bulkhead): bool =
  if b.inFlight.fetchAdd(1) < b.limit: return true
  discard b.inFlight.fetchSub(1)
  false

proc leave(b: var Bulkhead) = discard b.inFlight.fetchSub(1)

var calls = 0

proc flakyService(clock: FakeClock; cost: int): int =
  ## A dependency that fails twice, then answers. Each call costs `cost` ms.
  inc calls
  clock.advance(initDuration(milliseconds = cost))
  if calls <= 2:
    raise newException(DependencyError, "unavailable")
  42

proc withTimeout(clock: FakeClock; limitMs: int; fn: proc(): int): int =
  ## A timeout is a failure for the breaker, so it must be raised as one.
  let start = clock.now()
  result = fn()
  if clock.now() - start > initDuration(milliseconds = limitMs).inNanoseconds:
    raise newException(DependencyError, "timeout after " & $limitMs & " ms")

proc callWithRetry(clock: FakeClock; cb: CircuitBreaker; bulkhead: var Bulkhead;
                   attempts: int): int =
  ## Retry sits OUTSIDE the breaker. A CircuitOpenError stops the retries at once:
  ## waiting out a rejection is the breaker's job, not the retry loop's.
  var backoff = initDuration(milliseconds = 100)
  for attempt in 1 .. attempts:
    if not bulkhead.tryEnter():
      raise newException(DependencyError, "bulkhead full")
    try:
      return cb.call(proc(): int = withTimeout(clock, 50, proc(): int = flakyService(clock, 30)))
    except CircuitOpenError:
      raise
    except DependencyError as e:
      echo &"  attempt {attempt} failed: {e.msg}"
      if attempt == attempts: raise
      clock.advance(backoff)
      backoff = backoff * 2
    finally:
      bulkhead.leave()
  raise newException(DependencyError, "unreachable")

when isMainModule:
  let clock = newFakeClock()
  let cb = newCircuitBreaker(initBreakerConfig(
    name = "inventory", failureThreshold = 3, openTimeout = initDuration(milliseconds = 5000),
    clock = clock.source))
  var bulkhead = Bulkhead(limit: 4)
  echo "call 1: retries until the service answers"
  echo "  result = ", callWithRetry(clock, cb, bulkhead, attempts = 4)
  echo "breaker state: ", cb.state
