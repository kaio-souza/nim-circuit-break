## Chronos: a call with a time limit and cancellation safety (Y2, Y3, T5).
## Needs Chronos (`nimble install chronos`).
## Run: nim c -r examples/chronos_basic.nim

import std/times except Duration
import pkg/chronos
import circuit_breaker, circuit_breaker/chronos_async

let cb = newCircuitBreaker(BreakerConfig(
  name: "slow-api", failureThreshold: 2,
  callTimeout: initDuration(milliseconds = 50),   # cancels fn and counts a failure
  openTimeout: initDuration(seconds = 30)))

var delayMs = 5

proc fetch(): Future[string] {.async.} =
  await sleepAsync(chronos.milliseconds(delayMs))   # cancelled by callTimeout
  return "response after " & $delayMs & " ms"

proc main() {.async.} =
  # Chronos procs are gcsafe; this single-threaded program shares `cb`.
  {.cast(gcsafe).}:
    for delay in [5, 200, 200, 5]:
      delayMs = delay
      try:
        echo await cb.callAsync(fetch)
      except CallTimeoutError:
        echo "timed out after the ", delay, " ms call"
      except CircuitOpenError as e:
        echo "rejected, circuit ", e.state

waitFor main()
