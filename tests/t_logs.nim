## O7: logging hook. A capturing logger checks the lines produced by a
## breaker that goes through Closed, Open, HalfOpen and Closed again, and that
## a callback already set on the config still runs.

import std/[unittest, logging, strutils]
import helpers
import circuit_breaker/logs

type CaptureLogger = ref object of Logger
  lines: seq[string]

method log*(logger: CaptureLogger, level: Level, args: varargs[string, `$`]) =
  logger.lines.add args.join("")

type BrokenLogger = ref object of Logger

method log*(logger: BrokenLogger, level: Level, args: varargs[string, `$`]) =
  raise newException(IOError, "disk full")

suite "logging hook (O7)":
  test "O7: transitions are logged in order with their reasons":
    let clock = newFakeClock()
    let log = CaptureLogger(levelThreshold: lvlDebug)
    let cfg = withTransitionLog(BreakerConfig(
      name: "payments", failureThreshold: 1, openTimeout: ms(1000),
      successThreshold: 1, clock: clock.source), log)
    let cb = newCircuitBreaker(cfg)
    discard cb.fail()                    # Closed -> Open
    clock.advance(ms(1000))
    discard cb.tryCall(proc() = discard) # Open -> HalfOpen -> Closed
    check log.lines.len == 3
    check log.lines[0].startsWith("circuit breaker 'payments': Closed -> Open")
    check "open for 1000 ms" in log.lines[0]
    check log.lines[1].startsWith("circuit breaker 'payments': Open -> HalfOpen")
    check log.lines[2].startsWith("circuit breaker 'payments': HalfOpen -> Closed")

  test "O7: a callback already in the config still runs":
    let clock = newFakeClock()
    let log = CaptureLogger(levelThreshold: lvlDebug)
    var seen = 0
    let base = BreakerConfig(failureThreshold: 1, clock: clock.source,
                             onTransition: proc(e: TransitionEvent) = inc seen)
    let cb = newCircuitBreaker(withTransitionLog(base, log))
    discard cb.fail()
    check seen == 1
    check log.lines.len == 1

  test "O7: a failing logger does not stop the breaker":
    let clock = newFakeClock()
    let cb = newCircuitBreaker(withTransitionLog(
      BreakerConfig(failureThreshold: 1, clock: clock.source),
      BrokenLogger(levelThreshold: lvlDebug)))
    discard cb.fail()
    check cb.state == Open
    check cb.metrics.callbackErrors == 0
