## N3: with -d:cbDisabled (see t_cbdisabled.nims) the breaker is a pass-through.

import std/unittest
import helpers

suite "cbDisabled":
  test "N3: calls pass through even when the circuit is forced open":
    let cb = newBreaker(newFakeClock())
    cb.forceOpen()
    check cb.call(proc(): int = 5) == 5
    var ran = false
    withBreaker(cb):
      ran = true
    check ran
    check cb.metrics.successes == 0   # nothing is evaluated
