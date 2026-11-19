## HTTP-style policies: failure rate, slow calls, ignoring client errors,
## honoring Retry-After, fallback and shadow mode. The "server" is simulated.
## Run: nim c -r examples/http_policies.nim

import std/times
import circuit_breaker

type HttpError = object of CatchableError
  status: int
  retryAfter: Duration

proc httpError(status: int; retryAfter = Duration()): ref HttpError =
  result = newException(HttpError, "HTTP " & $status)
  result.status = status
  result.retryAfter = retryAfter

proc classify(e: ref CatchableError): Verdict =
  if e of HttpError:
    let h = (ref HttpError)(e)
    if h.status < 500: return ignoreCall()                 # client errors
    if h.status == 503 and h.retryAfter > Duration():
      return countAsFailure(openFor = h.retryAfter)        # server hint
  countAsFailure()

let cfg = initBreakerConfig(
  name = "payments-api",
  policy = FailureRate,
  failureRateThreshold = 0.5,
  minimumCalls = 10,
  windowKind = TimeWindow,
  windowDuration = initDuration(seconds = 30),
  slowCallDuration = initDuration(seconds = 2),
  slowCallRateThreshold = 0.8,
  openTimeout = initDuration(seconds = 5),
  backoffMultiplier = 2.0,
  maxOpenTimeout = initDuration(minutes = 2),
  jitter = 0.2,
  classifyError = classify)

for warning in cfg.diagnose: echo "config warning: ", warning
let cb = newCircuitBreaker(cfg)

proc getBalance(i: int): string =
  if i mod 5 == 0: raise httpError(404)
  if i >= 8: raise httpError(500)
  "balance ok"

let fallback = proc(e: ref CatchableError): string = "cached balance (" & $e.name & ")"
for i in 1 .. 25:
  echo i, ": ", cb.callOr(proc(): string = getBalance(i), fallback)

echo "\n", cb.report
echo "\nwhy it opened: ", cb.explain[^1].reason, ", failure rate ",
  cb.explain[^1].stats.failureRate * 100, "%"

# A Retry-After hint from the server overrides the open timeout.
let hinted = newCircuitBreaker(initBreakerConfig(name = "hinted",
  failureThreshold = 100, classifyError = classify))
discard hinted.tryCall(proc(): int = raise httpError(503, initDuration(seconds = 60)))
echo "\nRetry-After honored: ", hinted.state, ", retry in ", hinted.retryAfter.inSeconds + 1, " s"

# Shadow mode: adopt the breaker in production without blocking anything.
let shadow = newCircuitBreaker(initBreakerConfig(name = "shadow",
  failureThreshold = 2, shadowMode = true))
for _ in 1 .. 5: discard shadow.tryCall(proc(): int = raise httpError(500))
let m = shadow.metrics
echo "shadow: state ", m.state, ", would have rejected ", m.shadowRejected,
  " calls, actually rejected ", m.rejected
