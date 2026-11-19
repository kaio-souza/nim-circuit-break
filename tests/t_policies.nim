import std/unittest
import helpers

type HttpError = object of CatchableError
  status: int

proc httpError(status: int): ref HttpError =
  result = newException(HttpError, "HTTP " & $status)
  result.status = status

suite "policies":
  test "F2/G1: failure rate in a count window opens after minimumCalls":
    let cb = newCircuitBreaker(initBreakerConfig(policy = FailureRate,
      failureRateThreshold = 0.5, minimumCalls = 10, windowSize = 10,
      clock = newFakeClock().source))
    for i in 1 .. 9:
      if i mod 2 == 0: discard cb.fail() else: discard cb.succeed()
    check cb.state == Closed            # only 9 calls: below minimumCalls
    discard cb.fail()                   # 10 calls, 5 failures = 50%
    check cb.state == Open
    check cb.explain[^1].reason == trFailureRate
    check cb.explain[^1].stats.calls == 10

  test "F2: the count window forgets old calls":
    let cb = newCircuitBreaker(initBreakerConfig(policy = FailureRate,
      failureRateThreshold = 0.6, minimumCalls = 5, windowSize = 5,
      clock = newFakeClock().source))
    for _ in 1 .. 2: discard cb.fail()
    for _ in 1 .. 5: discard cb.succeed()  # the two failures slide out
    check cb.metrics.window.failures == 0
    check cb.metrics.window.calls == 5

  test "F3: time window expires calls older than windowDuration":
    let clock = newFakeClock()
    let cb = newCircuitBreaker(initBreakerConfig(policy = FailureRate,
      failureRateThreshold = 0.5, minimumCalls = 4, windowKind = TimeWindow,
      windowDuration = ms(10_000), windowBuckets = 10, clock = clock.source))
    for _ in 1 .. 3: discard cb.fail()
    check cb.state == Closed
    clock.advance(ms(11_000))
    check cb.metrics.window.calls == 0  # old failures expired
    discard cb.fail()
    check cb.state == Closed            # 1 call: below minimumCalls
    for _ in 1 .. 3: discard cb.fail()
    check cb.state == Open

  test "F4/G2: slow calls open the circuit":
    let clock = newFakeClock()
    let cb = newCircuitBreaker(initBreakerConfig(failureThreshold = 100,
      slowCallDuration = ms(2000), slowCallRateThreshold = 0.5, minimumCalls = 4,
      windowSize = 4, clock = clock.source))
    for _ in 1 .. 4:
      discard cb.tryCall(proc(): int =
        clock.advance(ms(3000))
        200)
    check cb.state == Open
    check cb.explain[^1].reason == trSlowCallRate
    check cb.metrics.slowCalls == 4

  test "F5/F6/G3: classifier ignores client errors and counts server errors":
    let cb = newCircuitBreaker(initBreakerConfig(failureThreshold = 2,
      clock = newFakeClock().source,
      classifyError = proc(e: ref CatchableError): Verdict =
        if e of HttpError and (ref HttpError)(e).status < 500: ignoreCall()
        else: countAsFailure()))
    for _ in 1 .. 10:
      discard cb.tryCall(proc(): int = raise httpError(404))
    check cb.state == Closed
    check cb.metrics.ignored == 10
    discard cb.tryCall(proc(): int = raise httpError(503))
    discard cb.tryCall(proc(): int = raise httpError(503))
    check cb.state == Open

  test "F7: a returned value can count as a failure and is still returned":
    let cb = newBreaker(newFakeClock(), failureThreshold = 2)
    for _ in 1 .. 2:
      let status = cb.call(proc(): int = 503, proc(s: int): bool = s >= 500)
      check status == 503
    check cb.state == Open

  test "F8: Defects propagate and are not counted":
    let cb = newBreaker(newFakeClock(), failureThreshold = 1)
    expect AssertionDefect:
      discard cb.call(proc(): int = raise newException(AssertionDefect, "bug"))
    check cb.state == Closed
    check cb.metrics.failures == 0
    check cb.metrics.ignored == 1

  test "G5: a failure carrying a server hint opens for that duration":
    let clock = newFakeClock()
    let cb = newCircuitBreaker(initBreakerConfig(failureThreshold = 100,
      openTimeout = ms(1000), clock = clock.source,
      classifyError = proc(e: ref CatchableError): Verdict =
        countAsFailure(openFor = initDuration(seconds = 60))))
    discard cb.fail()
    check cb.state == Open
    check cb.explain[^1].reason == trServerHint
    check cb.retryAfter == initDuration(seconds = 60)
