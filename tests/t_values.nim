## EV3: value tests. Each one shows the problem without the feature and the
## fix with it, using the scenarios of SPEC.md section 26.

import std/[unittest, sets]
import helpers
import circuit_breaker/keyed

suite "value tests":
  test "V-E2: a forgotten outcome leaves a manual API stuck; the guard recovers":
    let clock = newFakeClock()
    let cfg = initBreakerConfig(failureThreshold = 1, openTimeout = ms(100),
                                clock = clock.source)
    # Without the guard: emulate a manual allow/record API where the caller
    # returns early and never records the probe outcome.
    let manual = newCircuitBreaker(cfg)
    discard manual.fail()
    clock.advance(ms(101))
    block:
      var p = manual.acquire()
      wasMoved(p)                     # what a manual API does: nothing
    for _ in 1 .. 100: check manual.succeed() == crRejected
    check manual.state == HalfOpen    # stuck forever
    # With the guard: the same mistake is recorded as a failure automatically.
    let guarded = newCircuitBreaker(cfg)
    discard guarded.fail()
    clock.advance(ms(101))
    block:
      let p = guarded.acquire()
      discard p
    check guarded.state == Open       # the probe failure was recorded
    clock.advance(ms(101))
    check guarded.succeed() == crOk   # and the breaker recovers on its own
    check guarded.state == Closed

  test "V-F2: 30% intermittent errors never trip consecutive counting; the rate policy does":
    proc run(cb: CircuitBreaker): bool =
      for i in 0 ..< 1000:
        if i mod 10 in [0, 3, 6]: discard cb.fail() else: discard cb.succeed()
        if cb.state == Open: return true
    let consecutive = newCircuitBreaker(initBreakerConfig(failureThreshold = 5,
      clock = newFakeClock().source))
    let rate = newCircuitBreaker(initBreakerConfig(policy = FailureRate,
      failureRateThreshold = 0.25, minimumCalls = 20, windowSize = 50,
      clock = newFakeClock().source))
    check not run(consecutive)
    check run(rate)

  test "V-F4: a service answering 200 in 10s only trips with the slow call policy":
    proc run(slowCall: Duration): CircuitState =
      let clock = newFakeClock()
      let cb = newCircuitBreaker(initBreakerConfig(failureThreshold = 5,
        slowCallDuration = slowCall, slowCallRateThreshold = 0.5, minimumCalls = 5,
        windowSize = 10, clock = clock.source))
      for _ in 1 .. 20:
        discard cb.tryCall(proc(): int =
          clock.advance(initDuration(seconds = 10))
          200)
      cb.state
    check run(Duration()) == Closed
    check run(initDuration(seconds = 2)) == Open

  test "V-T4: jitter spreads the probes of instances that opened together":
    proc probeTimes(jitter: float): HashSet[Duration] =
      for i in 1 .. 100:
        let cb = newCircuitBreaker(initBreakerConfig(failureThreshold = 1,
          openTimeout = ms(1000), jitter = jitter, seed = int64(i),
          clock = newFakeClock().source))
        discard cb.fail()
        result.incl cb.metrics.currentOpenTimeout
    check probeTimes(0.0).len == 1    # thundering herd: all probe at once
    check probeTimes(0.5).len >= 95   # spread over [1000ms, 1500ms]

  test "V-N1: shadow mode takes the same decisions without blocking":
    let clockA = newFakeClock()
    let clockB = newFakeClock()
    let real = newCircuitBreaker(initBreakerConfig(failureThreshold = 3,
      openTimeout = ms(50), clock = clockA.source))
    let shadow = newCircuitBreaker(initBreakerConfig(failureThreshold = 3,
      openTimeout = ms(50), shadowMode = true, clock = clockB.source))
    var blocked = 0
    for i in 0 ..< 500:
      let failing = (i div 20) mod 2 == 0     # alternating outage periods
      for cb in [real, shadow]:
        let r = if failing: cb.fail() else: cb.succeed()
        if r == crRejected: inc blocked
      clockA.advance(ms(10))
      clockB.advance(ms(10))
    proc pairs(cb: CircuitBreaker): seq[(CircuitState, CircuitState)] =
      for ev in cb.explain: result.add (ev.fromState, ev.toState)
    check real.metrics.rejected > 0
    check shadow.metrics.rejected == 0
    check shadow.metrics.shadowRejected == real.metrics.rejected
    check blocked == real.metrics.rejected.int
    check pairs(shadow) == pairs(real)

  test "V-N2: 200k distinct keys stay within the configured capacity":
    let kb = newKeyedBreaker[int](1000, proc(key: int): BreakerConfig =
      initBreakerConfig())
    for k in 0 ..< 10_000: discard kb.get(k)
    let memAt10k = getOccupiedMem()
    for k in 10_000 ..< 200_000: discard kb.get(k)
    check kb.len == 1000
    check kb.evictions == 199_000
    when not defined(useMalloc):        # getOccupiedMem is not tracked with useMalloc
      check getOccupiedMem() < memAt10k * 2   # memory does not grow with keys

  test "V-B4: explain answers why the circuit opened":
    let cb = newCircuitBreaker(initBreakerConfig(policy = FailureRate,
      failureRateThreshold = 0.5, minimumCalls = 4, windowSize = 4,
      clock = newFakeClock().source))
    discard cb.succeed()
    discard cb.fail()
    discard cb.succeed()
    discard cb.fail()
    let why = cb.explain[^1]
    check why.reason == trFailureRate
    check why.stats.calls == 4 and why.stats.failures == 2
    check why.stats.failureRate == 0.5
