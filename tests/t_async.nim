import std/[unittest, asyncdispatch]
import helpers
import circuit_breaker/async

proc okOp(): Future[int] {.async.} =
  await sleepAsync(1)
  return 42

proc failingOp(): Future[int] {.async.} =
  await sleepAsync(1)
  raise newException(IOError, "async failure")

proc voidOp(): Future[void] {.async.} =
  await sleepAsync(1)

# unittest's `test` and `check` turn BareExcept on for the code they wrap, and
# asyncmacro's `except Exception` would then warn where `callAsync[int]` is
# first instantiated. Instantiating it here, at module level, keeps it quiet.
proc callInt(cb: CircuitBreaker; fn: proc(): Future[int]): Future[int] {.used.} =
  cb.callAsync(fn)

suite "async":
  test "Y1/A5: callAsync returns values and records success":
    let cb = newBreaker(newFakeClock())
    check waitFor(cb.callAsync(okOp)) == 42
    waitFor cb.callAsync(voidOp)
    check cb.metrics.successes == 2

  test "Y1: callAsync propagates failures and opens the circuit":
    let cb = newBreaker(newFakeClock(), failureThreshold = 2)
    for _ in 1 .. 2:
      expect IOError:
        discard waitFor cb.callAsync(failingOp)
    check cb.state == Open
    expect CircuitOpenError:
      discard waitFor cb.callAsync(okOp)

proc slowOp(): Future[int] {.async.} =
  await sleepAsync(200)
  return 7

suite "async per-call timeout (T5)":
  test "T5: exceeding callTimeout raises CallTimeoutError and counts a failure":
    let cb = newCircuitBreaker(initBreakerConfig(name = "slow", failureThreshold = 5,
      callTimeout = ms(20)))
    expect CallTimeoutError:
      discard waitFor cb.callAsync(slowOp)
    check cb.metrics.failures == 1
    check cb.metrics.successes == 0
    # the abandoned call finishes later; its outcome must not be recorded
    waitFor sleepAsync(250)
    check cb.metrics.successes == 0
    check cb.metrics.failures == 1

  test "T5: a call within callTimeout is unaffected":
    let cb = newCircuitBreaker(initBreakerConfig(name = "fast", callTimeout = ms(500)))
    check waitFor(cb.callAsync(okOp)) == 42
    check cb.metrics.successes == 1

  test "T5: callTimeout is validated and changed by reconfigure":
    expect ValueError:
      discard newCircuitBreaker(initBreakerConfig(callTimeout = ms(-1)))
    let cb = newCircuitBreaker(initBreakerConfig(callTimeout = ms(10)))
    cb.reconfigure(initBreakerConfig(callTimeout = ms(30)))
    check cb.callTimeout == ms(30)

  test "T5: a CallTimeoutError from a nested breaker is classified by the outer one":
    # The inner breaker times out; the outer one must treat that error like any
    # other failure of its `fn`: through its classifier, here "ignore".
    let inner = newCircuitBreaker(initBreakerConfig(name = "inner", callTimeout = ms(20)))
    let outer = newCircuitBreaker(initBreakerConfig(name = "outer",
      classifyError = proc(e: ref CatchableError): Verdict =
        if e of CallTimeoutError: ignoreCall() else: countAsFailure()))
    proc viaInner(): Future[int] = inner.callAsync(slowOp)
    expect CallTimeoutError:
      discard waitFor outer.callAsync(viaInner)
    check inner.metrics.failures == 1
    check outer.metrics.failures == 0
    check outer.metrics.successes == 0
