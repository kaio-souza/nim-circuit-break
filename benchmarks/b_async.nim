## BM13: overhead of `callAsync` on `std/asyncdispatch` (Y1, T5) against the
## same future awaited without a breaker.

import std/[asyncdispatch, times]
import harness
import ../src/circuit_breaker
import ../src/circuit_breaker/async

const n = 50_000

proc op(): Future[int] {.async.} = return 1

proc main() =
  header("async (asyncdispatch)")
  let cb = newCircuitBreaker(BreakerConfig(name: "bench"))
  let timed = newCircuitBreaker(BreakerConfig(name: "bench-timeout",
    callTimeout: initDuration(seconds = 1)))
  bench("BM13 baseline: waitFor op()", n):
    keep = waitFor op()
  bench("BM13 waitFor callAsync(op)", n):
    keep = waitFor cb.callAsync(op)
  bench("BM13 waitFor callAsync(op) with callTimeout", n):
    keep = waitFor timed.callAsync(op)

main()
writeJson("b_async.json")
