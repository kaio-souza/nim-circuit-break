## `report`: a human-readable summary of a breaker (N10). Re-exported by
## `circuit_breaker`.

import std/[times, strutils, strformat]
import types, core

proc fmtDur(d: Duration): string =
  let ms = d.inMilliseconds
  if ms >= 1000: &"{ms.float / 1000.0:.1f}s" else: &"{ms}ms"

proc report*(cb: CircuitBreaker): string =
  ## Human-readable one-block summary for terminals and logs (N10).
  let m = cb.metrics
  result = &"circuit breaker '{m.name}': {m.state}\n" &
    &"  window: {m.window.calls} calls, failure rate {m.window.failureRate * 100:.1f}%, " &
    &"slow rate {m.window.slowCallRate * 100:.1f}%\n" &
    &"  consecutive failures: {m.consecutiveFailures}\n" &
    &"  totals: {m.successes} ok, {m.failures} failed, {m.ignored} ignored, " &
    &"{m.rejected} rejected, {m.shadowRejected} shadow-rejected, {m.slowCalls} slow\n" &
    &"  transitions: {m.transitions}, callback errors: {m.callbackErrors}"
  if m.state == Open:
    result &= &"\n  next probe in: {fmtDur(m.retryAfter)} (open period {fmtDur(m.currentOpenTimeout)})"
  let h = cb.explain
  if h.len > 0:
    let last = h[^1]
    result &= &"\n  last transition: {last.fromState} -> {last.toState} ({last.reason})"
  result = result.strip(leading = false)
