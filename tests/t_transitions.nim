import std/[unittest, monotimes]
import helpers

suite "state machine":
  test "S1/S3: starts Closed and only valid transitions happen":
    let clock = newFakeClock()
    let cb = newBreaker(clock)
    check cb.state == Closed
    cb.openIt()
    clock.advance(ms(1001))
    check cb.fail() == crFailed          # probe fails: HalfOpen -> Open
    clock.advance(ms(1001))
    check cb.succeed() == crOk           # probe succeeds: HalfOpen -> Closed
    const allowed = [(Closed, Open), (Open, HalfOpen), (HalfOpen, Open), (HalfOpen, Closed)]
    var seen: seq[(CircuitState, CircuitState)]
    for ev in cb.explain: seen.add (ev.fromState, ev.toState)
    check seen == @[(Closed, Open), (Open, HalfOpen), (HalfOpen, Open),
                    (Open, HalfOpen), (HalfOpen, Closed)]
    for pair in seen: check pair in allowed

  test "F1: threshold > 1 opens the circuit (regression: v0.1 never opened)":
    let cb = newBreaker(newFakeClock(), failureThreshold = 3)
    discard cb.fail()
    discard cb.fail()
    check cb.state == Closed
    discard cb.fail()
    check cb.state == Open

  test "F1: consecutive counter resets only after a success":
    let cb = newBreaker(newFakeClock(), failureThreshold = 3)
    discard cb.fail()
    discard cb.fail()
    check cb.consecutiveFailures == 2
    check cb.succeed() == crOk
    check cb.consecutiveFailures == 0
    discard cb.fail()
    discard cb.fail()
    check cb.state == Closed

  test "S4: Open -> HalfOpen happens lazily, without timers":
    let clock = newFakeClock()
    let cb = newBreaker(clock)
    cb.openIt()
    clock.advance(ms(5000))
    check cb.state == Open               # nothing changes until a call arrives
    var p = cb.acquire()
    check cb.state == HalfOpen
    check p.isProbe
    p.success()
    check cb.state == Closed

  test "S6: the call that triggers HalfOpen executes fn (regression)":
    let clock = newFakeClock()
    let cb = newBreaker(clock)
    cb.openIt()
    clock.advance(ms(1001))
    var ran = false
    cb.call(proc() = ran = true)
    check ran
    check cb.state == Closed

  test "S5: a failed probe never reports Closed (regression)":
    var events: seq[CircuitState]
    let clock = newFakeClock()
    let cb = newBreaker(clock, onTransition = proc(e: TransitionEvent) =
      events.add e.toState)
    cb.openIt()
    clock.advance(ms(1001))
    check cb.fail() == crFailed
    check cb.state == Open
    check events == @[Open, HalfOpen, Open]

  test "S7: HalfOpen limits concurrent probes":
    let clock = newFakeClock()
    let cb = newCircuitBreaker(initBreakerConfig(failureThreshold = 1,
      openTimeout = ms(100), halfOpenMaxProbes = 2, clock = clock.source))
    discard cb.fail()
    clock.advance(ms(101))
    var p1 = cb.acquire()
    var p2 = cb.acquire()
    check p1.isProbe and p2.isProbe
    expect CircuitOpenError:
      discard cb.acquire()
    p1.success()
    check cb.state == Closed
    p2.success()                          # stale probe: metrics only
    check cb.state == Closed
    check cb.metrics.probesInFlight == 0

  test "S8: successThreshold consecutive probe successes close the circuit":
    let clock = newFakeClock()
    let cb = newCircuitBreaker(initBreakerConfig(failureThreshold = 1,
      openTimeout = ms(100), successThreshold = 2, clock = clock.source))
    discard cb.fail()
    clock.advance(ms(101))
    check cb.succeed() == crOk
    check cb.state == HalfOpen
    check cb.succeed() == crOk
    check cb.state == Closed

  test "T1: default clock is monotonic (MonoTime)":
    let cb = newCircuitBreaker(initBreakerConfig(failureThreshold = 1))
    let before = getMonoTime().ticks
    discard cb.fail()
    let at = cb.explain[^1].atNanos
    check at >= before and at <= getMonoTime().ticks

  test "T2: the open period starts at the end of the failing call":
    let clock = newFakeClock()
    let cb = newBreaker(clock, failureThreshold = 1, openTimeout = ms(1000))
    let r = cb.tryCall(proc(): int =
      clock.advance(ms(500))
      raise newException(IOError, "slow failure"))
    check r.kind == crFailed
    clock.advance(ms(900))
    check cb.succeed() == crRejected     # 900 ms after the end: still open
    clock.advance(ms(101))
    check cb.succeed() == crOk

  test "T3/G4: exponential backoff on consecutive reopenings, capped":
    let clock = newFakeClock()
    let cb = newCircuitBreaker(initBreakerConfig(failureThreshold = 1,
      openTimeout = ms(1000), backoffMultiplier = 2.0, maxOpenTimeout = ms(3000),
      clock = clock.source))
    discard cb.fail()
    check cb.metrics.currentOpenTimeout == ms(1000)
    clock.advance(ms(1000))
    discard cb.fail()
    check cb.metrics.currentOpenTimeout == ms(2000)
    clock.advance(ms(2000))
    discard cb.fail()
    check cb.metrics.currentOpenTimeout == ms(3000)
    clock.advance(ms(3000))
    check cb.succeed() == crOk
    check cb.state == Closed
    discard cb.fail()
    check cb.metrics.currentOpenTimeout == ms(1000)   # backoff resets after recovery

  test "T4: jitter only delays the probe, within the configured bound":
    let clock = newFakeClock()
    let cb = newCircuitBreaker(initBreakerConfig(failureThreshold = 1,
      openTimeout = ms(1000), jitter = 0.5, clock = clock.source, seed = 7))
    for _ in 1 .. 50:
      discard cb.fail()
      let t = cb.metrics.currentOpenTimeout
      check t >= ms(1000) and t <= ms(1500)
      cb.reset()

  test "A10/S2: reset, forceOpen and disable":
    let cb = newBreaker(newFakeClock())
    cb.forceOpen()
    check cb.succeed() == crRejected
    check cb.isOpen
    cb.reset()
    check cb.state == Closed and cb.succeed() == crOk
    cb.disable()
    for _ in 1 .. 10: discard cb.fail()
    check cb.state == Disabled
    check cb.succeed() == crOk

  test "A11: internal transitions are not public":
    let cb = newBreaker(newFakeClock())
    check not compiles(cb.transitionTo(Open))
    check not compiles(cb.transitionLocked(Open))
