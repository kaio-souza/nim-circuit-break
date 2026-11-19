# Must NOT compile: a Permit cannot be copied (E2).
import circuit_breaker
let cb = newCircuitBreaker(initBreakerConfig())
var p = cb.acquire()
var q = p
p.success()
q.success()
