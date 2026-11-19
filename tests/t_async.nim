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
