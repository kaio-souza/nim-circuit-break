## `std/asyncdispatch` support (Y1). Import explicitly:
## `import circuit_breaker, circuit_breaker/async`.

import std/asyncdispatch
import core

proc callAsync*[T](cb: CircuitBreaker; fn: proc(): Future[T]): Future[T] {.async.} =
  ## Async version of `call`: raises `CircuitOpenError` when rejected and
  ## propagates failures of `fn` unchanged.
  var p = acquire(cb)
  try:
    when T is void:
      await fn()
    else:
      result = await fn()
  except CatchableError as e:
    p.recordError(e)
    raise e
  p.success()

proc callAsync*(cb: CircuitBreaker; fn: proc(): Future[void]): Future[void] =
  callAsync[void](cb, fn)
