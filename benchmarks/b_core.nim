## BM1 (Closed hot path), BM3 (rejection), BM6 (API styles), BM8 (shadow,
## cbDisabled when compiled with -d:cbDisabled), BM9 (metrics/explain).

import std/times
import harness
import ../src/circuit_breaker

const n = 200_000

proc work(): int = 1
let fn = proc(): int = work()

proc main() =
  header("core")
  let cb = newCircuitBreaker(initBreakerConfig(name = "bench"))

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

  let slow = newCircuitBreaker(initBreakerConfig(
    slowCallDuration = initDuration(seconds = 1)))
  bench("BM1 call with slow-call detection (reads clock)", n):
    keep = slow.call(fn)

  let rate = newCircuitBreaker(initBreakerConfig(policy = FailureRate))
  bench("BM1 call with FailureRate policy (window 100)", n):
    keep = rate.call(fn)

  var events = 0
  let observed = newCircuitBreaker(initBreakerConfig(
    onCall = proc(e: CallEvent) = inc events))
  bench("BM1 call with onCall event", n):
    keep = observed.call(fn)

  let open = newCircuitBreaker(initBreakerConfig(failureThreshold = 1,
    openTimeout = initDuration(hours = 1), maxOpenTimeout = initDuration(hours = 1)))
  open.forceOpen()
  bench("BM3 rejection via tryAcquire (no exception)", n):
    var p: Permit
    keep = ord(open.tryAcquire(p))
  bench("BM3 rejection via call (raises CircuitOpenError)", n div 10):
    try:
      keep = open.call(fn)
    except CircuitOpenError:
      keep = 0

  let shadow = newCircuitBreaker(initBreakerConfig(failureThreshold = 1,
    shadowMode = true, openTimeout = initDuration(hours = 1),
    maxOpenTimeout = initDuration(hours = 1)))
  discard shadow.tryCall(proc(): int = raise newException(IOError, "x"))
  bench("BM8 shadow mode while Open (would reject)", n):
    keep = shadow.call(fn)

  bench("BM9 metrics() snapshot", n div 10):
    keep = cb.metrics.successes.int
  bench("BM9 explain() (empty history)", n div 10):
    keep = cb.explain.len

  writeJson(when defined(cbDisabled): "b_core_disabled.json" else: "b_core.json")

main()
