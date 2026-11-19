## Shared helpers for the test suite (not a test file: no `t` prefix).

import std/times
import circuit_breaker, circuit_breaker/testing
export times, circuit_breaker, testing

proc ms*(n: int): Duration = initDuration(milliseconds = n)

proc newBreaker*(clock: FakeClock; failureThreshold = 3; openTimeout = ms(1000);
                 onTransition: TransitionCallback = nil): CircuitBreaker =
  newCircuitBreaker(initBreakerConfig(
    name = "test", failureThreshold = failureThreshold, openTimeout = openTimeout,
    onTransition = onTransition, clock = clock.source, seed = 42))

proc succeed*(cb: CircuitBreaker): CallResultKind =
  cb.tryCall(proc(): int = 1).kind

proc fail*(cb: CircuitBreaker): CallResultKind =
  cb.tryCall(proc(): int = raise newException(IOError, "simulated")).kind

proc openIt*(cb: CircuitBreaker; failures = 3) =
  for _ in 1 .. failures: discard cb.fail()
  doAssert cb.state == Open, "expected Open, got " & $cb.state
