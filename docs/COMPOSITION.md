# Composing a circuit breaker

The breaker decides whether a call may run and records its outcome. It does
not retry, limit concurrency or enforce deadlines. Those are separate patterns,
and this guide shows how to combine them. The runnable version is
[`examples/composition.nim`](../examples/composition.nim), compiled in CI.

## The order matters

```
retry ─► breaker ─► timeout ─► dependency
          │
          └─ bulkhead wraps the whole attempt
```

- **Retry outside the breaker.** A `CircuitOpenError` means the dependency is
  known to be down. Retrying immediately only adds load to the breaker. Stop
  the retry loop on that error and let the open timeout do its job.
- **Breaker outside the timeout.** A timeout is a failure. The breaker must
  see it as one, so raise it as an exception the breaker counts.
- **Bulkhead outside the breaker.** A rejection by the bulkhead must not reach
  the breaker, otherwise a full bulkhead would look like a failing dependency.

## Retry with backoff

Use the rejection's `retryAfter` when the call was rejected, and exponential
backoff for failures:

```nim
except CircuitOpenError:
  raise                       # do not retry a known outage
except DependencyError:
  clock.advance(backoff)      # or sleep in production
  backoff = backoff * 2
```

Add jitter in production (`initBreakerConfig(jitter = ...)` covers the breaker's
own open period; the retry loop needs its own) so that many clients do not retry
in lockstep.

## Timeout

A breaker cannot interrupt a running call. Enforce the deadline where the
dependency is called (socket timeout, HTTP client timeout, or the timeout of your async
runtime), and raise the timeout as an exception so the
breaker records it as a failure.

The example checks the elapsed time after the call returns. That only classifies
a slow call; it does not stop it. Use a timeout inside the dependency call for
real protection.

## Bulkhead

A bulkhead caps concurrent calls, so one slow dependency cannot exhaust every
worker. A minimal version uses an atomic counter:

```nim
if not bulkhead.tryEnter():
  raise newException(DependencyError, "bulkhead full")
try:
  cb.call(...)
finally:
  bulkhead.leave()
```

The library does not ship a bulkhead on purpose
([ADR-0001](decisions/0001-scope-circuit-breaker-only.md)): the primitive depends
on the runtime (threads, async) and composes cleanly outside the breaker.

## Classifying errors

Not every error should open the circuit. A bad request from the caller is not a
dependency failure. Use `classifyError` to ignore those errors:

```nim
initBreakerConfig(classifyError = proc(e: ref CatchableError): Verdict =
  if e of ValidationError: ignoreCall() else: countAsFailure())  # ValidationError: your own type
```

## Testing the composition

Run the composition on a `FakeClock` (`circuit_breaker/testing`) so that open
periods, backoff and timeouts are deterministic, as in the example.
