## O7: optional `std/logging` hook. It logs every state transition of a breaker.
## Because a breaker has one `onTransition` slot, the hook composes with any
## callback already set: the previous callback still runs afterwards. Errors
## from the logger never reach the breaker (they are swallowed here, and
## callbacks already count their own errors in `callbackErrors`).
##
## .. code-block:: nim
##   import circuit_breaker, circuit_breaker/logs, std/logging
##   let cfg = withTransitionLog(initBreakerConfig(name = "payments"),
##                               newConsoleLogger(lvlWarn))

import std/[logging, strformat, times]
import types

proc describe*(e: TransitionEvent): string =
  ## One-line summary of a transition.
  result = &"circuit breaker '{e.breaker}': {e.fromState} -> {e.toState} ({e.reason})"
  if e.toState == Open:
    result.add &", open for {e.openFor.inMilliseconds} ms"

proc withTransitionLog*(cfg: BreakerConfig; logger: Logger;
                        level = lvlInfo): BreakerConfig =
  ## Returns `cfg` with a transition logger installed in front of its existing
  ## `onTransition` callback.
  result = cfg
  let previous = cfg.onTransition
  result.onTransition = proc(e: TransitionEvent) =
    try:
      logger.log(level, describe(e))
    except CatchableError:
      discard
    if not previous.isNil:
      previous(e)
