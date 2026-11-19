## Circuit breaker for Nim.
##
## .. code-block:: nim
##   import circuit_breaker, std/times
##
##   let cb = newCircuitBreaker(initBreakerConfig(
##     name = "payments", failureThreshold = 5,
##     openTimeout = initDuration(seconds = 30)))
##
##   try:
##     let body = cb.call(proc(): string = fetchPayment())
##   except CircuitOpenError as e:
##     echo "try again in ", e.retryAfter
##
## Optional modules: `circuit_breaker/async` (asyncdispatch),
## `circuit_breaker/keyed` (one breaker per key) and
## `circuit_breaker/testing` (`FakeClock`).

import circuit_breaker/[types, core]
export types, core
