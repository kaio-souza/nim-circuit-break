## BM14: overhead of `callAsync` on Chronos (Y2, Y3, T5) against the same
## future awaited without a breaker.

import std/times except Duration
import pkg/chronos except Duration, milliseconds, nanoseconds
import harness
import ../src/circuit_breaker
import ../src/circuit_breaker/chronos_async

const n = 50_000

proc op(): Future[int] {.async.} = return 1

proc main() =
  header("async (chronos)")
  let cb = newCircuitBreaker(initBreakerConfig(name = "bench"))
  let timed = newCircuitBreaker(initBreakerConfig(name = "bench-timeout",
    callTimeout = initDuration(seconds = 1)))
  bench("BM14 baseline: waitFor op()", n):
    keep = waitFor op()
  bench("BM14 waitFor callAsync(op)", n):
    keep = waitFor cb.callAsync(op)
  bench("BM14 waitFor callAsync(op) with callTimeout", n):
    keep = waitFor timed.callAsync(op)

main()
writeJson("b_chronos.json")
