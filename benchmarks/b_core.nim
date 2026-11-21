## BM1 (Closed hot path), BM3 (rejection), BM6 (API styles), BM8 (shadow,
## cbDisabled when compiled with -d:cbDisabled), BM9 (metrics/explain),
## BM10 (latency histogram on, O4), BM11 (Prometheus render, O6), BM12 (logging
## hook on the call path, O7).

import std/[times, logging]
import harness
import ../src/circuit_breaker
import ../src/circuit_breaker/[prometheus, logs]

type NullLogger = ref object of Logger

method log*(logger: NullLogger, level: Level, args: varargs[string, `$`]) = discard

const n = 200_000

proc work(): int = 1
let fn = proc(): int = work()

proc main() =
  header("core")
  let cb = newCircuitBreaker(BreakerConfig(name: "bench"))
  let cbLogged = newCircuitBreaker(withTransitionLog(BreakerConfig(name: "bench-log"), NullLogger(levelThreshold: lvlDebug)))
  let cbLatency = newCircuitBreaker(BreakerConfig(name: "bench-latency", latencyPrecision: 4))

  bench("BM0 baseline: direct closure call", n):
    keep = fn()
  bench("BM1 call (Closed, success)", n):
    keep = cb.call(fn)
  bench("BM6 withBreaker (no closure)", n):
    withBreaker(cb):
      keep = work()
  bench("BM6 tryAcquire + success (guard)", n):
    var p: Permit
    if cb.tryAcquire(p):
      keep = work()
      p.success()
  bench("BM6 tryCall (explicit result)", n):
    keep = cb.tryCall(fn).value

  let slow = newCircuitBreaker(BreakerConfig(
    slowCallDuration: initDuration(seconds = 1)))
  bench("BM1 call with slow-call detection (reads clock)", n):
    keep = slow.call(fn)

  let rate = newCircuitBreaker(BreakerConfig(policy: FailureRate))
  bench("BM12 call with transition logging hook (O7, no transition)", n):
    keep = cbLogged.call(fn)
  bench("BM10 call with latency histogram (O4, precision 4)", n):
    keep = cbLatency.call(fn)
  bench("BM1 call with FailureRate policy (window 100)", n):
    keep = rate.call(fn)

  var events = 0
  let observed = newCircuitBreaker(BreakerConfig(
    onCall: proc(e: CallEvent) = inc events))
  bench("BM1 call with onCall event", n):
    keep = observed.call(fn)

  let open = newCircuitBreaker(BreakerConfig(failureThreshold: 1,
    openTimeout: initDuration(hours = 1), maxOpenTimeout: initDuration(hours = 1)))
  open.forceOpen()
  bench("BM3 rejection while ForcedOpen via tryAcquire", n):
    var p: Permit
    keep = ord(open.tryAcquire(p))
  let tripped = newCircuitBreaker(BreakerConfig(failureThreshold: 1,
    openTimeout: initDuration(hours = 1), maxOpenTimeout: initDuration(hours = 1)))
  discard tripped.tryCall(proc(): int = raise newException(IOError, "x"))
  bench("BM3 rejection while Open via tryAcquire (reads clock)", n):
    var p: Permit
    keep = ord(tripped.tryAcquire(p))
  bench("BM3 rejection via call (raises CircuitOpenError)", n div 10):
    try:
      keep = open.call(fn)
    except CircuitOpenError:
      keep = 0

  let shadow = newCircuitBreaker(BreakerConfig(failureThreshold: 1,
    shadowMode: true, openTimeout: initDuration(hours = 1),
    maxOpenTimeout: initDuration(hours = 1)))
  discard shadow.tryCall(proc(): int = raise newException(IOError, "x"))
  bench("BM8 shadow mode while Open (would reject)", n):
    keep = shadow.call(fn)

  bench("BM11 renderPrometheus, 2 breakers (O6)", n div 100):
    keep = renderPrometheus([cb, cbLatency]).len
  bench("BM9 metrics() snapshot", n div 10):
    keep = cb.metrics.successes.int
  bench("BM9 explain() (empty history)", n div 10):
    keep = cb.explain.len

  writeJson(when defined(cbDisabled): "b_core_disabled.json" else: "b_core.json")

main()
