## The call APIs (E1, E3, A1-A6), built on `acquire` and the permit outcomes
## of `core`. Re-exported by `circuit_breaker`.

import types, core

template guarded(permit: var Permit; body: untyped) =
  ## Runs `body` and records its outcome on `permit`: a `CatchableError` goes
  ## through the classifier and is re-raised, a `Defect` is not counted (F8).
  ## The caller records success, because only it knows whether the result
  ## counts as one.
  try:
    body
  except CatchableError as e:
    permit.recordError(e)
    raise
  except Defect:
    permit.ignore()
    raise

proc call*[T](cb: CircuitBreaker; fn: proc(): T): T =
  ## Runs `fn` under the breaker (E1). Raises `CircuitOpenError` when rejected;
  ## failures of `fn` propagate unchanged (A1, A2). `Defect`s propagate and
  ## are not counted (F8).
  when defined(cbDisabled):
    when T is void: fn() else: return fn()
  else:
    var p = acquire(cb)
    guarded(p):
      when T is void:
        fn()
      else:
        result = fn()
    p.success()

proc call*(cb: CircuitBreaker; fn: proc()) =
  ## `call` for procs without a return value (A4).
  call[void](cb, fn)

proc call*[T](cb: CircuitBreaker; fn: proc(): T; isFailureResult: proc(x: T): bool): T =
  ## Like `call`, but a returned value can also count as a failure (F7).
  ## The value is still returned to the caller.
  when defined(cbDisabled):
    return fn()
  else:
    var p = acquire(cb)
    guarded(p):
      result = fn()
    if isFailureResult(result): p.failure() else: p.success()

type
  CallResultKind* = enum
    ## Outcome of `tryCall`.
    crOk        ## `fn` ran and succeeded; `value` holds its result.
    crRejected  ## The breaker rejected the call; see `rejection`.
    crFailed    ## `fn` raised; see `error`.

  CallResult*[T] = object
    ## Explicit result of `tryCall` (A3).
    kind*: CallResultKind
    when T isnot void:
      value*: T
    rejection*: ref CircuitOpenError
    error*: ref CatchableError

proc isOk*[T](r: CallResult[T]): bool {.inline.} =
  ## True when the call ran and succeeded.
  r.kind == crOk

proc tryCall*[T](cb: CircuitBreaker; fn: proc(): T): CallResult[T] =
  ## Never raises `CatchableError`: the outcome is in the result.
  try:
    when T is void:
      cb.call(fn)
    else:
      result.value = cb.call(fn)
    result.kind = crOk
  except CircuitOpenError as e:
    result.kind = crRejected
    result.rejection = e
  except CatchableError as e:
    result.kind = crFailed
    result.error = e

proc tryCall*(cb: CircuitBreaker; fn: proc()): CallResult[void] =
  ## `tryCall` for a `fn` without a result.
  tryCall[void](cb, fn)

proc callOr*[T](cb: CircuitBreaker; fn: proc(): T;
                fallback: proc(e: ref CatchableError): T): T =
  ## Runs `fallback` when the call is rejected or fails (A6). The fallback
  ## receives the `CircuitOpenError` or the original exception.
  try:
    when T is void:
      cb.call(fn)
    else:
      result = cb.call(fn)
  except CatchableError as e:
    when T is void:
      fallback(e)
    else:
      result = fallback(e)

proc callOr*(cb: CircuitBreaker; fn: proc(); fallback: proc(e: ref CatchableError)) =
  ## `callOr` for a `fn` without a result.
  callOr[void](cb, fn, fallback)

template withBreaker*(cb: CircuitBreaker; body: untyped) =
  ## Runs `body` under the breaker without allocating a closure (E3).
  ## Leaving `body` normally, or through `return`/`break`, counts as success.
  when defined(cbDisabled):
    body
  else:
    var permit = acquire(cb)
    try:
      guarded(permit, body)
    finally:
      if not permit.isDone: permit.success()
