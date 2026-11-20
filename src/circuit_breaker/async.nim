## `std/asyncdispatch` support (Y1), with the per-call timeout (T5). Import
## explicitly: `import circuit_breaker, circuit_breaker/async`.
##
## `asyncdispatch` has no cancellation: a call that exceeds `callTimeout`
## counts as a failure and raises `CallTimeoutError`, but `fn` keeps running in
## the background until it finishes (its late outcome is ignored). Its timers
## cannot be cancelled either: each pending call with a timeout keeps one timer
## alive for `callTimeout`. For calls that must be cancelled, or for high call
## rates with long timeouts, use `circuit_breaker/chronos_async` (Y3).

import std/[asyncdispatch, times]
import types, core

proc callAsync*[T](cb: CircuitBreaker; fn: proc(): Future[T]): Future[T] {.async.} =
  ## Async version of `call`: raises `CircuitOpenError` when rejected and
  ## propagates failures of `fn` unchanged.
  var p = acquire(cb)
  let limit = cb.callTimeout
  try:
    let fut = fn()
    if limit > Duration() and not fut.finished:
      # `withTimeout` arms a timer that asyncdispatch cannot cancel: it stays
      # pending for `limit` even when the call ends first. Skipping finished
      # calls avoids it; for pending calls, live timers stay bounded by
      # call rate x callTimeout.
      # whole milliseconds, rounded up so that the limit is never shortened
      let ms = int((limit.inNanoseconds + 999_999) div 1_000_000)
      if not await fut.withTimeout(ms):
        p.failure()
        # Recorded above: the handler below sees a done permit and only
        # re-raises. A `CallTimeoutError` raised by `fn` itself (a nested
        # breaker) goes through the classifier like any other error.
        raise cb.newCallTimeoutError(limit)
    when T is void:
      await fut
    else:
      result = await fut
  except CatchableError as e:
    p.recordError(e)
    raise e
  p.success()

proc callAsync*(cb: CircuitBreaker; fn: proc(): Future[void]): Future[void] =
  ## `callAsync` for a `fn` without a result.
  callAsync[void](cb, fn)
