## Prometheus metrics for a set of breakers. By default prints the payload;
## with `--serve` it answers GET /metrics on port 8080.
## Run: nim c -r examples/metrics_endpoint.nim [--serve]

import std/[asyncdispatch, asynchttpserver, times, os]
import circuit_breaker, circuit_breaker/prometheus

let breakers = @[
  newCircuitBreaker(BreakerConfig(name: "payments", failureThreshold: 3)),
  newCircuitBreaker(BreakerConfig(name: "search", latencyPrecision: 4))]

# Some traffic so the series are not empty.
for cb in breakers:
  for i in 1 .. 5: cb.call(proc() = discard)
try:
  breakers[0].call(proc() = raise newException(IOError, "boom"))
except IOError: discard

proc serve() {.async.} =
  var server = newAsyncHttpServer()
  proc handler(req: Request) {.async, gcsafe.} =
    if req.url.path == "/metrics":
      {.cast(gcsafe).}:
        await req.respond(Http200, renderPrometheus(breakers),
          newHttpHeaders({"Content-Type": "text/plain; version=0.0.4"}))
    else:
      await req.respond(Http404, "not found")
  await server.serve(Port(8080), handler)

if "--serve" in commandLineParams(): waitFor serve()
else: echo renderPrometheus(breakers)
