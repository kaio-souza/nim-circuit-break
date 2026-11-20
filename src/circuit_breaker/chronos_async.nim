## Chronos support (Y2), with cancellation safety (Y3) and the per-call
## timeout (T5). Import explicitly; the core does not depend on Chronos:
##
## .. code-block:: nim
##   import circuit_breaker, circuit_breaker/chronos_async, chronos
##   let body = await cb.callAsync(proc(): Future[string] {.async.} = await fetch())
##
## - A rejected call raises `CircuitOpenError` before `fn` runs.
## - A failure of `fn` is classified like in `call` and propagates unchanged.
## - Exceeding `callTimeout` cancels `fn`, counts as a failure and raises
##   `CallTimeoutError`.
## - Cancelling the returned future cancels `fn` and records `onCancel`
##   (default: not counted). A cancelled probe frees its slot, so the breaker
##   is never left stuck in `HalfOpen`; `CancelledError` propagates.

import std/times except Duration
import pkg/chronos
import types, core

proc toChronos(d: times.Duration): chronos.Duration {.inline.} =
  chronos.nanoseconds(d.inNanoseconds)

proc callAsync*[T](cb: CircuitBreaker; fn: proc(): Future[T] {.raises: [].};
                   onCancel = ignoreCall()): Future[T] {.async.} =
  ## Runs `fn` under the breaker on the Chronos event loop. `fn` reports its
  ## errors through the future, as every Chronos `{.async.}` proc does.
  # Chronos requires `gcsafe` async procs. The breaker's operations call user
  # callbacks and clocks, which the type system cannot prove gcsafe; they are
  # thread-safe by construction (ADR-0005, ADR-0007), so the calls are cast.
  var p: Permit
  {.cast(gcsafe).}:
    p = acquire(cb)
  var limit: times.Duration
  {.cast(gcsafe).}:
    limit = cb.callTimeout
  try:
    var fut: Future[T]
    {.cast(gcsafe).}:
      fut = fn()    # closures over refs are allowed, as in `call`
    if limit > times.Duration() and not fut.finished:
      if not await fut.withTimeout(limit.toChronos):
        # `withTimeout` has cancelled `fut`.
        {.cast(gcsafe).}:
          p.failure()
          # Recorded above: the handler below sees a done permit and only
          # re-raises. A `CallTimeoutError` raised by `fn` itself (a nested
          # breaker) goes through the classifier like any other error.
          raise cb.newCallTimeoutError(limit)
    when T is void:
      await fut
    else:
      result = await fut
  except CancelledError as e:
    {.cast(gcsafe).}:
      p.record(onCancel)
    raise e
  except CatchableError as e:
    {.cast(gcsafe).}:
      p.recordError(e)
    raise e
  {.cast(gcsafe).}:
    p.success()

proc callAsync*(cb: CircuitBreaker; fn: proc(): Future[void] {.raises: [].};
                onCancel = ignoreCall()): Future[void] =
  ## `callAsync` for a `fn` without a result.
  callAsync[void](cb, fn, onCancel)
