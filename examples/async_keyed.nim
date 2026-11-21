## Async calls with one breaker per host (keyed breakers).
## Run: nim c -r examples/async_keyed.nim

import std/[asyncdispatch, times, strutils]
import circuit_breaker, circuit_breaker/[async, keyed]

let breakers = newKeyedBreaker[string](capacity = 100, proc(host: string): BreakerConfig =
  BreakerConfig(failureThreshold: 2, openTimeout: initDuration(seconds = 10)))

proc fetch(host: string): Future[string] {.async.} =
  await sleepAsync(5)
  if host == "down.example":
    raise newException(IOError, "connection refused")
  return "200 OK from " & host

proc main() {.async.} =
  for round in 1 .. 3:
    for host in ["api.example", "down.example"]:
      let cb = breakers.get(host)
      try:
        let body = await cb.callAsync(proc(): Future[string] = fetch(host))
        echo round, " ", host, ": ", body
      except CircuitOpenError as e:
        echo round, " ", host, ": skipped, circuit ", e.state
      except IOError as e:
        echo round, " ", host, ": ", e.msg.splitLines[0]   # asyncdispatch appends a traceback
  echo "\nbreakers: ", breakers.len
  for host in ["api.example", "down.example"]:
    echo host, " -> ", breakers.get(host).state

waitFor main()
