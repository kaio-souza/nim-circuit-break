## Fallback instead of exceptions: `callOr` serves a cached value when the call
## fails or the circuit is open. Run: nim c -r examples/fallback.nim

import std/[times, tables]
import circuit_breaker

var cache = {"user:1": "Ada (cached)"}.toTable

proc fetchUser(id: int): string =
  if id mod 2 == 0: raise newException(IOError, "profile service timeout")
  "User " & $id

let cb = newCircuitBreaker(BreakerConfig(
  name: "profiles", failureThreshold: 2,
  openTimeout: initDuration(seconds = 30)))

for id in [1, 2, 4, 6, 1]:
  # The fallback receives the error: the original one, or CircuitOpenError.
  let who = cb.callOr(
    proc(): string = fetchUser(id),
    proc(e: ref CatchableError): string =
      echo "  fallback for ", id, ": ", e.name
      cache.getOrDefault("user:" & $id, "anonymous"))
  echo id, " -> ", who
echo "state: ", cb.state
