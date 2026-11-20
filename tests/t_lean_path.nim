## P2: differential test of the lean success path. Two breakers with the same
## configuration get the same random operations, each on its own fake clock.
## One has an `onCall` callback, which forces the general path (`recordCore`);
## the other takes the lean path. After every step, state and metrics must be
## identical. Covers count and time windows, with and without slow-call
## detection, so a divergence in the duplicated decision logic shows up.

import std/[unittest, random]
import helpers

type Op = enum opSuccess, opFailure, opAdvance

proc sameObservable(a, b: CircuitBreaker): bool =
  let ma = a.metrics
  let mb = b.metrics
  ma.state == mb.state and ma.successes == mb.successes and
    ma.failures == mb.failures and ma.rejected == mb.rejected and
    ma.slowCalls == mb.slowCalls and ma.transitions == mb.transitions and
    ma.consecutiveFailures == mb.consecutiveFailures and
    ma.window.calls == mb.window.calls and ma.window.failures == mb.window.failures and
    ma.window.slowCalls == mb.window.slowCalls

proc runScenario(cfgFor: proc(clock: FakeClock; observed: bool): BreakerConfig;
                 seed: int64; steps: int): bool =
  var rng = initRand(seed)
  let clockA = newFakeClock()
  let clockB = newFakeClock()
  let general = newCircuitBreaker(cfgFor(clockA, true))
  let lean = newCircuitBreaker(cfgFor(clockB, false))
  for step in 0 ..< steps:
    let op = Op(rng.rand(2))
    let cost = ms(rng.rand(0 .. 300))
    case op
    of opSuccess:
      discard general.tryCall(proc() = clockA.advance(cost))
      discard lean.tryCall(proc() = clockB.advance(cost))
    of opFailure:
      discard general.tryCall(proc() =
        clockA.advance(cost)
        raise newException(IOError, "down"))
      discard lean.tryCall(proc() =
        clockB.advance(cost)
        raise newException(IOError, "down"))
    of opAdvance:
      let d = ms(rng.rand(0 .. 3000))
      clockA.advance(d)
      clockB.advance(d)
    if not sameObservable(general, lean):
      checkpoint "diverged at step " & $step & " (seed " & $seed & ", op " & $op & ")"
      return false
  true

suite "lean success path (P2)":
  test "F2: a success that trips the failure rate opens for the full timeout (regression)":
    # Count window, no slow-call detection, no callbacks: the success reads no
    # clock. It used to compute the deadline from time 0, so the circuit was
    # already past its open period and the next call became a probe.
    let clock = newFakeClock()
    let cb = newCircuitBreaker(initBreakerConfig(policy = FailureRate,
      windowKind = CountWindow, windowSize = 10, minimumCalls = 5,
      failureRateThreshold = 0.5, openTimeout = ms(1000), clock = clock.source))
    for i in 0 ..< 3: discard cb.fail()
    discard cb.succeed()
    check cb.state == Closed            # 4 calls, below minimumCalls
    discard cb.succeed()                # 5 calls, 60% failures: trips on a success
    check cb.state == Open
    var p: Permit
    check not cb.tryAcquire(p)          # still within the open period
    check cb.retryAfter == ms(1000)
    clock.advance(ms(1000))
    check cb.tryAcquire(p)
    check p.isProbe
    p.success()

  test "F2: the general path has the same fix (onTransition set, no clock on success)":
    let clock = newFakeClock()
    var events = 0
    let cb = newCircuitBreaker(initBreakerConfig(policy = FailureRate,
      windowKind = CountWindow, windowSize = 10, minimumCalls = 5,
      failureRateThreshold = 0.5, openTimeout = ms(1000), clock = clock.source,
      onTransition = proc(e: TransitionEvent) = inc events))
    for i in 0 ..< 3: discard cb.fail()
    discard cb.succeed()
    discard cb.succeed()
    check cb.state == Open
    var p: Permit
    check not cb.tryAcquire(p)
    check cb.explain()[^1].atNanos == clock.now

  test "P2: count window with FailureRate matches the general path":
    for seed in 1'i64 .. 200:
      check runScenario(proc(clock: FakeClock; observed: bool): BreakerConfig =
        initBreakerConfig(policy = FailureRate, windowKind = CountWindow,
          windowSize = 10, minimumCalls = 5, failureRateThreshold = 0.5,
          openTimeout = ms(1000), clock = clock.source,
          onCall = (if observed: (proc(e: CallEvent) = discard) else: nil)),
        seed, 300)

  test "P2: time window with FailureRate and slow calls matches the general path":
    for seed in 1'i64 .. 200:
      check runScenario(proc(clock: FakeClock; observed: bool): BreakerConfig =
        initBreakerConfig(policy = FailureRate, windowKind = TimeWindow,
          windowDuration = ms(2000), windowBuckets = 4, minimumCalls = 4,
          failureRateThreshold = 0.6, slowCallDuration = ms(200),
          slowCallRateThreshold = 0.5, openTimeout = ms(1000),
          clock = clock.source,
          onCall = (if observed: (proc(e: CallEvent) = discard) else: nil)),
        seed, 300)

  test "P2: consecutive policy with slow-call detection matches the general path":
    for seed in 1'i64 .. 200:
      check runScenario(proc(clock: FakeClock; observed: bool): BreakerConfig =
        initBreakerConfig(failureThreshold = 3, slowCallDuration = ms(150),
          slowCallRateThreshold = 0.5, minimumCalls = 4, openTimeout = ms(1000),
          clock = clock.source,
          onCall = (if observed: (proc(e: CallEvent) = discard) else: nil)),
        seed, 300)
