import std/[unittest, strutils, os]
import helpers

proc failIO() =
  # A plain call, not a `raise` statement: `expect` would flag the code after
  # a bare `raise` as unreachable.
  raise newException(IOError, "x")

proc guardedWork(cb: CircuitBreaker; earlyReturn: bool): int =
  withBreaker(cb):
    if earlyReturn: return 1
    result = 2

suite "api":
  test "A1/A2/E1: failures propagate the original exception unchanged":
    let cb = newBreaker(newFakeClock())
    try:
      discard cb.call(proc(): int = raise newException(KeyError, "original"))
      fail()
    except KeyError as e:
      check e.msg == "original"

  test "A3/E5: rejection raises CircuitOpenError with retryAfter":
    let clock = newFakeClock()
    let cb = newBreaker(clock, openTimeout = ms(1000))
    cb.openIt()
    clock.advance(ms(400))
    try:
      discard cb.call(proc(): int = 1)
      fail()
    except CircuitOpenError as e:
      check e.breakerName == "test"
      check e.state == Open
      check e.retryAfter == ms(600)

  test "A4: procs without a return value":
    let cb = newBreaker(newFakeClock())
    var n = 0
    cb.call(proc() = inc n)
    check n == 1
    check cb.tryCall(proc() = inc n).isOk
    check n == 2

  test "A3: tryCall reports ok, failed and rejected without raising":
    let cb = newBreaker(newFakeClock(), failureThreshold = 1)
    let ok = cb.tryCall(proc(): string = "x")
    check ok.kind == Returned and ok.value == "x"
    let failed = cb.tryCall(proc(): string = raise newException(IOError, "boom"))
    check failed.kind == Raised and failed.error.msg == "boom"
    let rejected = cb.tryCall(proc(): string = "x")
    check rejected.kind == Refused and rejected.rejection.state == Open

  test "A6: callOr runs the fallback on failure and on rejection":
    let cb = newBreaker(newFakeClock(), failureThreshold = 1)
    var seen: seq[string]
    let fallback = proc(e: ref CatchableError): string =
      seen.add $e.name
      "fallback"
    check cb.callOr(proc(): string = raise newException(IOError, "x"), fallback) == "fallback"
    check cb.callOr(proc(): string = "never runs", fallback) == "fallback"
    check seen == @["IOError", "CircuitOpenError"]

  test "E3/A7: withBreaker counts normal exit and early return as success":
    let cb = newBreaker(newFakeClock())
    check guardedWork(cb, earlyReturn = true) == 1
    check guardedWork(cb, earlyReturn = false) == 2
    check cb.metrics.successes == 2

  test "E3: withBreaker records failures and re-raises":
    let cb = newBreaker(newFakeClock(), failureThreshold = 1)
    expect IOError:
      withBreaker(cb):
        failIO()
    check cb.state == Open

  test "E2: an unresolved permit records a failure when it goes out of scope":
    let cb = newBreaker(newFakeClock(), failureThreshold = 1)
    block:
      let p = cb.acquire()
      discard p
    check cb.metrics.failures == 1
    check cb.state == Open

  test "E2: permits cannot be copied (compiles a forbidden program)":
    const dir = currentSourcePath().parentDir
    const res = gorgeEx(getCurrentCompilerExe() & " c --hints:off --path:" &
      dir / ".." / "src" & " --nimcache:" & dir / "compile_fail" / "cache " &
      dir / "compile_fail" / "permit_copy.nim")
    check res.exitCode != 0
    check "'=copy' is not available for type <Permit>" in res.output

  test "K2: invalid configs are rejected at creation":
    expect ValueError: discard newCircuitBreaker(BreakerConfig(failureThreshold: 0))
    expect ValueError: discard newCircuitBreaker(BreakerConfig(jitter: 2.0))
    expect ValueError: discard newCircuitBreaker(BreakerConfig(
      openTimeout: ms(10_000), maxOpenTimeout: ms(1000)))
    expect ValueError: discard newCircuitBreaker(BreakerConfig(
      policy: FailureRate, minimumCalls: 50, windowSize: 10))

  test "N8: diagnose warns about risky but valid configs":
    check BreakerConfig().diagnose.len == 0
    let warnings = BreakerConfig(failureThreshold: 1, shadowMode: true).diagnose
    check warnings.len == 2

  test "B2/O4/O5: metrics snapshot counts every outcome":
    let cb = newBreaker(newFakeClock(), failureThreshold = 2)
    discard cb.succeed()
    discard cb.fail()
    discard cb.fail()
    discard cb.succeed()
    let m = cb.metrics
    check m.successes == 1 and m.failures == 2 and m.rejected == 1
    check m.state == Open and m.transitions == 1

  test "B4: explain tells why the circuit opened":
    let cb = newBreaker(newFakeClock())
    cb.openIt()
    let last = cb.explain[^1]
    check last.reason == FailureThresholdReached
    check last.consecutiveFailures == 3
    check last.openFor == ms(1000)
    check last.breaker == "test"

  test "B4: history keeps only the last historySize transitions":
    let clock = newFakeClock()
    let cb = newCircuitBreaker(BreakerConfig(failureThreshold: 1,
      historySize: 3, clock: clock.source))
    for _ in 1 .. 5:
      discard cb.fail()
      cb.reset()
    let h = cb.explain
    check h.len == 3
    check h[^1].toState == Closed and h[^1].reason == Manual

  test "O1/O3/B1: transition and call events carry context":
    var transitions: seq[TransitionEvent]
    var calls: seq[CallOutcome]
    let cb = newCircuitBreaker(BreakerConfig(name: "svc", failureThreshold: 1,
      clock: newFakeClock().source,
      # Single-threaded test: the seqs are globals of the test block.
      onTransition: (proc(e: TransitionEvent) = {.cast(gcsafe).}: transitions.add e),
      onCall: (proc(e: CallEvent) = {.cast(gcsafe).}: calls.add e.outcome)))
    discard cb.succeed()
    discard cb.fail()
    discard cb.succeed()
    check calls == @[Succeeded, Failed, Rejected]
    check transitions.len == 1
    check transitions[0].breaker == "svc" and transitions[0].fromState == Closed

  test "O2: a raising callback never corrupts the breaker":
    let cb = newCircuitBreaker(BreakerConfig(failureThreshold: 1,
      clock: newFakeClock().source,
      onTransition: (proc(e: TransitionEvent) = raise newException(ValueError, "bad")),
      onCall: (proc(e: CallEvent) = raise newException(ValueError, "bad"))))
    check cb.fail() == Raised       # the original error, not the callback's
    check cb.state == Open
    check cb.metrics.callbackErrors == 2

  test "N1: shadow mode evaluates but never rejects":
    let cb = newCircuitBreaker(BreakerConfig(failureThreshold: 1,
      shadowMode: true, clock: newFakeClock().source))
    discard cb.fail()
    check cb.state == Open
    for _ in 1 .. 5: check cb.succeed() == Returned
    check cb.metrics.shadowRejected == 5
    check cb.metrics.rejected == 0

  test "N4/K3: reconfigure changes thresholds and keeps the state":
    let cb = newBreaker(newFakeClock(), failureThreshold = 5)
    discard cb.fail()
    discard cb.fail()
    var cfg = cb.config
    cfg.failureThreshold = 3
    cb.reconfigure(cfg)
    check cb.consecutiveFailures == 2
    discard cb.fail()
    check cb.state == Open
    cfg.failureThreshold = 0
    expect ValueError: cb.reconfigure(cfg)

  test "N10: report is human readable":
    let cb = newBreaker(newFakeClock())
    cb.openIt()
    let r = cb.report
    check "'test': Open" in r
    check "next probe in" in r
    check "Closed -> Open" in r

  test "K1/A8: defaults are documented and valid":
    let c = BreakerConfig()
    check c.failureThreshold == 5 and c.openTimeout == initDuration(seconds = 30)
    check c.halfOpenMaxProbes == 1 and c.successThreshold == 1
    validate(c)                       # does not raise

  test "A9/A12: read-only getters expose state without mutable fields":
    let cb = newCircuitBreaker(BreakerConfig(name: "orders",
      clock: newFakeClock().source))
    check cb.name == "orders"
    check cb.isClosed and not cb.isOpen and not cb.isHalfOpen
    check cb.consecutiveFailures == 0 and cb.retryAfter == Duration()
    check not compiles(cb.consecutive)
    check not compiles(cb.cfg)

  test "E4: low-level tryAcquire shares the core with call":
    let cb = newBreaker(newFakeClock(), failureThreshold = 1)
    var p: Permit
    check cb.tryAcquire(p)
    p.failure()
    check cb.state == Open
    var q: Permit
    check not cb.tryAcquire(q)        # rejected without allocating an exception
    check cb.metrics.rejected == 1

  test "V1/N9/T6: FakeClock drives time without sleeping":
    let clock = newFakeClock(start = 5_000)
    check clock.now == 5_000
    clock.advance(ms(2))
    check clock.now == 5_000 + 2_000_000
    let cb = newBreaker(clock, failureThreshold = 1, openTimeout = ms(1000))
    discard cb.fail()
    clock.advance(ms(999))
    check cb.succeed() == Refused
    clock.advance(ms(1))
    check cb.succeed() == Returned
