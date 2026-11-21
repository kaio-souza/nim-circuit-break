## O6/B3: Prometheus / OpenMetrics text exposition. This module only renders
## a string; serving it over HTTP is up to the application. It is separate
## from the core, so programs that do not import it pay nothing and need no
## dependency.
##
## .. code-block:: nim
##   import circuit_breaker, circuit_breaker/prometheus
##   let body = renderPrometheus([payments, search])
##   # serve `body` on /metrics with content type text/plain; version=0.0.4

import std/[strutils, strformat, times]
import types, core, private/latency

proc escapeLabel(s: string): string =
  ## Label values escape backslash, double quote and newline.
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '\\': result.add "\\\\"
    of '"': result.add "\\\""
    of '\n': result.add "\\n"
    else: result.add c

proc num(v: float): string =
  ## Plain decimal, no exponent, so every parser accepts it; trailing zeros dropped.
  result = formatFloat(v, ffDecimal, 9)
  if '.' in result:
    result = result.strip(leading = false, trailing = true, chars = {'0'})
    result = result.strip(leading = false, trailing = true, chars = {'.'})
  if result.len == 0 or result == "-": result = "0"

proc family(buf: var string; name, kind, help: string) =
  buf.add "# HELP " & name & " " & help & "\n"
  buf.add "# TYPE " & name & " " & kind & "\n"

proc sample(buf: var string; name, labels: string; value: string) =
  buf.add name & "{" & labels & "} " & value & "\n"

type MetricValue = proc(m: BreakerMetrics): string {.nimcall.}

proc seconds(d: Duration): string = num(d.inNanoseconds.float / 1e9)

const scalarFamilies: array[9, (string, string, string, MetricValue)] = [
  ("circuit_breaker_slow_calls_total", "counter",
   "Calls slower than the slow-call duration.",
   proc(m: BreakerMetrics): string {.nimcall.} = $m.slowCalls),
  ("circuit_breaker_transitions_total", "counter", "State transitions.",
   proc(m: BreakerMetrics): string {.nimcall.} = $m.transitions),
  ("circuit_breaker_consecutive_failures", "gauge",
   "Failures in a row, counted in Closed.",
   proc(m: BreakerMetrics): string {.nimcall.} = $m.consecutiveFailures),
  ("circuit_breaker_probes_in_flight", "gauge", "Probe calls running in HalfOpen.",
   proc(m: BreakerMetrics): string {.nimcall.} = $m.probesInFlight),
  ("circuit_breaker_open_timeout_seconds", "gauge",
   "Open period in effect, including backoff.",
   proc(m: BreakerMetrics): string {.nimcall.} = seconds(m.currentOpenTimeout)),
  ("circuit_breaker_retry_after_seconds", "gauge",
   "Time until the next probe while Open, zero otherwise.",
   proc(m: BreakerMetrics): string {.nimcall.} = seconds(m.retryAfter)),
  ("circuit_breaker_window_calls", "gauge", "Calls in the sliding window.",
   proc(m: BreakerMetrics): string {.nimcall.} = $m.window.calls),
  ("circuit_breaker_window_failure_rate", "gauge",
   "Failure rate in the sliding window, 0 to 1.",
   proc(m: BreakerMetrics): string {.nimcall.} = num(m.window.failureRate)),
  ("circuit_breaker_window_slow_call_rate", "gauge",
   "Slow-call rate in the sliding window, 0 to 1.",
   proc(m: BreakerMetrics): string {.nimcall.} = num(m.window.slowCallRate))]
  # Families with one sample per breaker, in exposition order.

const stateFamilyAfter = 1
  # The state family (one sample per state) follows this index, which keeps
  # the order of earlier releases.

proc renderPrometheus*(breakers: openArray[CircuitBreaker]): string =
  ## Renders the metrics of every breaker in one exposition body. Each family
  ## is declared once, followed by the samples of all breakers.
  let ms = block:
    var v = newSeq[BreakerMetrics]()
    for cb in breakers: v.add cb.metrics
    v
  var buf = ""

  buf.family("circuit_breaker_calls_total", "counter",
             "Calls by outcome.")
  for m in ms:
    let n = escapeLabel(m.name)
    for (outcome, value) in [("success", m.successes), ("failure", m.failures),
                             ("ignored", m.ignored), ("rejected", m.rejected),
                             ("shadow_rejected", m.shadowRejected)]:
      buf.sample("circuit_breaker_calls_total",
                 &"name=\"{n}\",outcome=\"{outcome}\"", $value)

  for i, (name, kind, help, value) in scalarFamilies:
    buf.family(name, kind, help)
    for m in ms:
      buf.sample(name, &"name=\"{escapeLabel(m.name)}\"", value(m))
    if i == stateFamilyAfter:
      buf.family("circuit_breaker_state", "gauge",
                 "1 for the current state of each breaker, 0 for the others.")
      for m in ms:
        let n = escapeLabel(m.name)
        for s in CircuitState:
          buf.sample("circuit_breaker_state", &"name=\"{n}\",state=\"{s}\"",
                     if m.state == s: "1" else: "0")

  # O4 histogram. Prometheus histograms are cumulative over `le` bounds; only
  # bounds where the count grows are emitted, and bounds that round to the same
  # seconds value are merged into the later one, so `le` stays unique.
  var anyLatency = false
  for m in ms: anyLatency = anyLatency or m.latencyPrecision > 0
  if anyLatency:
    buf.family("circuit_breaker_call_duration_seconds", "histogram",
               "Call latency (O4), log buckets with relative width 1/k.")
  for m in ms:
    if m.latencyPrecision == 0: continue
    let n = escapeLabel(m.name)
    let k = m.latencyPrecision
    var les: seq[(string, int64)]  # (le, cumulative count)
    var acc = 0'i64
    for idx, c in m.latencyBuckets:
      if c == 0: continue
      acc += c
      let le = num(latencyBucketLower(idx + 1, k).float / 1e9)
      if les.len > 0 and les[^1][0] == le:
        les[^1][1] = acc
      else:
        les.add (le, acc)
    for (le, cum) in les:
      buf.sample("circuit_breaker_call_duration_seconds_bucket",
                 &"name=\"{n}\",le=\"{le}\"", $cum)
    buf.sample("circuit_breaker_call_duration_seconds_bucket",
               &"name=\"{n}\",le=\"+Inf\"", $m.latencyCount)
    buf.sample("circuit_breaker_call_duration_seconds_sum",
               &"name=\"{n}\"", num(m.latencySumNs.float / 1e9))
    buf.sample("circuit_breaker_call_duration_seconds_count",
               &"name=\"{n}\"", $m.latencyCount)

  result = buf
