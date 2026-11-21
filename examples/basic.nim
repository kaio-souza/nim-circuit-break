## Basic usage: wrap a flaky dependency, react to rejections, inspect state.
## Run: nim c -r examples/basic.nim

import std/[times, os]
import circuit_breaker

proc flakyService(i: int): string =
  if i in 3 .. 6: raise newException(IOError, "service unavailable")
  "response #" & $i

let cb = newCircuitBreaker(BreakerConfig(
  name: "inventory",
  failureThreshold: 3,
  openTimeout: initDuration(milliseconds = 200),
  onTransition: proc(e: TransitionEvent) =
    echo "  [", e.breaker, "] ", e.fromState, " -> ", e.toState, " (", e.reason, ")"))

for i in 0 .. 12:
  try:
    echo i, ": ", cb.call(proc(): string = flakyService(i))
  except CircuitOpenError as e:
    echo i, ": rejected, retry in ", e.retryAfter.inMilliseconds, " ms"
    sleep(int(e.retryAfter.inMilliseconds) + 1)
  except IOError as e:
    echo i, ": failed: ", e.msg

echo "\n", cb.report
