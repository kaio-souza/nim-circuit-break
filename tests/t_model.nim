## V2/Q5: model test. Random sequences of successful calls, failing calls and
## clock advances run against the real breaker and against a small
## executable model of the SPEC; after every step both must agree on the call
## outcome, the state and the consecutive failure count. Built with
## proptest's stateful testing: a failure is reported as the shortest
## sequence, printed as a `replayCommands` block to paste below.
##
## Checked against planted model mistakes (closing after 1 probe instead of
## 2, opening after 4 failures instead of 3, backoff without its cap): each
## was found and shrunk to its minimal sequence, e.g. the cap to
## 3 failures, then probe failures after waiting 1000, 2000, 4000, 8000, 8000 ms.

import std/[unittest, math]
import proptest
import helpers

const
  threshold = 3          # failureThreshold
  probesToClose = 2      # successThreshold
  baseMs = 1000          # openTimeout
  maxMs = 8000           # maxOpenTimeout
  multiplier = 2.0       # backoffMultiplier

type BreakerModel = object
  state: CircuitState    # as reported by `state`: Open until a call arrives (S4)
  consecutive: int
  level: int             # reopenings since the last Closed (backoff)
  probeOk: int
  now, openUntil: int64  # milliseconds

proc timeoutMs(level: int): int64 =
  int64(min(baseMs.float * pow(multiplier, level.float), maxMs.float))

proc admits(m: BreakerModel): bool =
  ## Whether the next call is let through.
  m.state != Open or m.now >= m.openUntil

proc trip(m: var BreakerModel) =
  m.state = Open
  m.openUntil = m.now + timeoutMs(m.level)
  inc m.level

proc record(m: var BreakerModel; failed: bool) =
  if m.state == Open and m.now >= m.openUntil:
    m.state = HalfOpen
    m.probeOk = 0
  case m.state
  of Closed:
    if failed:
      inc m.consecutive
      if m.consecutive >= threshold: m.trip()
    else:
      m.consecutive = 0
  of HalfOpen:
    if failed:
      m.trip()
    else:
      inc m.probeOk
      if m.probeOk >= probesToClose:
        m.state = Closed
        m.consecutive = 0
        m.level = 0
  of Open, ForcedOpen, Disabled:
    discard  # rejected: not recorded

stateMachine Breaker:
  model: BreakerModel()
  setup:
    let clock = newFakeClock()
    let cb = newCircuitBreaker(initBreakerConfig(
      name = "model", failureThreshold = threshold, openTimeout = ms(baseMs),
      backoffMultiplier = multiplier, maxOpenTimeout = ms(maxMs),
      successThreshold = probesToClose, clock = clock.source, seed = 42))

  command callOk():
    run: cb.succeed()
    postcondition: result == (if model.admits: crOk else: crRejected)
    update: model.record(failed = false)

  command callFails():
    run: cb.fail()
    postcondition: result == (if model.admits: crFailed else: crRejected)
    update: model.record(failed = true)

  # Up to past the longest open period (8 s), so backoff and its cap are
  # reached: with 3 s at most, a model missing the cap was never caught.
  command advance(t in ints(0, 9000)):
    run: clock.advance(ms(t))
    update: model.now += t

  invariant:
    check cb.state == model.state
    check cb.consecutiveFailures == model.consecutive

suite "model test":
  test "V2/Q5: the breaker matches the reference model on random sequences":
    checkStateMachine(Breaker, initSettings(cases = 1000, maxSteps = 60))

  test "V2: a hand-picked sequence through backoff replays as written":
    # Trip, wait out 1 s, fail the probe (reopen for 2 s), then close.
    replayCommands Breaker:
      callFails()
      callFails()
      callFails()
      callOk()          # rejected
      advance(1000)
      callFails()       # probe fails: Open for 2000 ms (backoff)
      advance(1999)
      callOk()          # still rejected
      advance(1)
      callOk()
      callOk()          # second probe success: Closed
      callFails()
