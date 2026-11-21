## Y2/Y3/T5: Chronos support. Same contract as `t_async` for values,
## failures and rejections; plus cancellation (Y3) and the per-call timeout
## (T5), which Chronos can enforce by cancelling the call.

import std/unittest
import helpers
import pkg/chronos except Duration, milliseconds, nanoseconds
import circuit_breaker/chronos_async

proc okOp(): Future[int] {.async.} =
  await sleepAsync(chronos.milliseconds(1))
  return 42

proc failingOp(): Future[int] {.async.} =
  await sleepAsync(chronos.milliseconds(1))
  raise newException(IOError, "chronos failure")

proc voidOp(): Future[void] {.async.} =
  await sleepAsync(chronos.milliseconds(1))

var slowFinished = false
proc slowOp(): Future[int] {.async.} =
  await sleepAsync(chronos.milliseconds(200))
  slowFinished = true
  return 7

proc tripAndWait(cb: CircuitBreaker; clock: FakeClock) =
  ## Opens the circuit and lets the open period elapse: the next call is a probe.
  for _ in 1 .. 2:
    expect IOError:
      discard waitFor cb.callAsync(failingOp)
  check cb.state == Open
  clock.advance(ms(1000))

suite "chronos (Y2)":
  test "Y2/A5: callAsync returns values and records success":
    let cb = newBreaker(newFakeClock())
    check waitFor(cb.callAsync(okOp)) == 42
    waitFor cb.callAsync(voidOp)
    check cb.metrics.successes == 2

  test "Y2: failures propagate unchanged and open the circuit; rejections raise":
    let cb = newBreaker(newFakeClock(), failureThreshold = 2)
    for _ in 1 .. 2:
      expect IOError:
        discard waitFor cb.callAsync(failingOp)
    check cb.state == Open
    expect CircuitOpenError:
      discard waitFor cb.callAsync(okOp)
    check cb.metrics.rejected == 1

suite "chronos cancellation (Y3)":
  test "Y3: a cancelled probe frees its slot and is not counted":
    let clock = newFakeClock()
    let cb = newBreaker(clock, failureThreshold = 2)
    tripAndWait(cb, clock)
    let probe = cb.callAsync(slowOp)            # the probe: HalfOpen, slot taken
    waitFor sleepAsync(chronos.milliseconds(5))
    check cb.state == HalfOpen
    waitFor probe.cancelAndWait()
    check probe.cancelled()
    check cb.metrics.probesInFlight == 0        # slot released
    check cb.metrics.failures == 2              # the cancellation did not count
    check cb.state == HalfOpen
    check waitFor(cb.callAsync(okOp)) == 42     # a new probe is admitted
    check cb.state == Closed

  test "Y3: onCancel = countAsFailure makes a cancelled probe reopen the circuit":
    let clock = newFakeClock()
    let cb = newBreaker(clock, failureThreshold = 2)
    tripAndWait(cb, clock)
    let probe = cb.callAsync(slowOp, onCancel = countAsFailure())
    waitFor sleepAsync(chronos.milliseconds(5))
    waitFor probe.cancelAndWait()
    check cb.metrics.failures == 3
    check cb.state == Open

  test "Y3: value test: without the policy, client cancellations reopen a healthy dependency":
    # Problem: a wrapper that only records success or failure leaves the permit
    # to its guard on cancellation, which counts a failure. Clients that give
    # up (timeouts upstream, disconnects) then keep the circuit open although
    # the dependency is fine.
    let clock = newFakeClock()
    let naive = newBreaker(clock, failureThreshold = 2)
    tripAndWait(naive, clock)
    proc naiveCall(): Future[int] {.async.} =
      var p: Permit
      {.cast(gcsafe).}:
        p = naive.acquire()
      let v = await slowOp()                    # cancellation skips the record
      {.cast(gcsafe).}:
        p.success()
      return v
    let f1 = naiveCall()
    waitFor sleepAsync(chronos.milliseconds(5))
    waitFor f1.cancelAndWait()
    check naive.state == Open                   # the guard counted a failure

    # Fix: callAsync records the cancellation as not counted.
    let clock2 = newFakeClock()
    let cb = newBreaker(clock2, failureThreshold = 2)
    tripAndWait(cb, clock2)
    let f2 = cb.callAsync(slowOp)
    waitFor sleepAsync(chronos.milliseconds(5))
    waitFor f2.cancelAndWait()
    check cb.state == HalfOpen                  # still recovering
    check waitFor(cb.callAsync(okOp)) == 42
    check cb.state == Closed

suite "chronos per-call timeout (T5)":
  test "T5: exceeding callTimeout cancels the call, counts a failure, raises CallTimeoutError":
    slowFinished = false
    let cb = newCircuitBreaker(BreakerConfig(name: "slow", failureThreshold: 5,
      callTimeout: ms(20)))
    expect CallTimeoutError:
      discard waitFor cb.callAsync(slowOp)
    check cb.metrics.failures == 1
    waitFor sleepAsync(chronos.milliseconds(250))
    check not slowFinished                      # the call was cancelled, not abandoned
    check cb.metrics.successes == 0

  test "T5: a call within callTimeout is unaffected":
    let cb = newCircuitBreaker(BreakerConfig(name: "fast", callTimeout: ms(500)))
    check waitFor(cb.callAsync(okOp)) == 42
    check cb.metrics.successes == 1

  test "T5: a CallTimeoutError from a nested breaker is classified by the outer one":
    let inner = newCircuitBreaker(BreakerConfig(name: "inner", callTimeout: ms(20)))
    let outer = newCircuitBreaker(BreakerConfig(name: "outer",
      classifyError: proc(e: ref CatchableError): Verdict =
        if e of CallTimeoutError: ignoreCall() else: countAsFailure()))
    proc viaInner(): Future[int] {.async.} =
      var f: Future[int]
      {.cast(gcsafe).}:
        f = inner.callAsync(slowOp)
      return await f
    expect CallTimeoutError:
      discard waitFor outer.callAsync(viaInner)
    check inner.metrics.failures == 1
    check outer.metrics.failures == 0
    check outer.metrics.successes == 0
