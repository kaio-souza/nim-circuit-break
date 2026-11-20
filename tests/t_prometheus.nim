## O6/B3: Prometheus exposition. Structural checks of the text (every family
## declared once, one-hot state, cumulative histogram ending in +Inf), a golden
## check for a known breaker, label escaping, and a value test: an operator's
## view of a tripped dependency. Also checks that the core does not depend on
## the exporter.

import std/[unittest, strutils, sequtils, os]
import helpers
import circuit_breaker/prometheus
import circuit_breaker/testing

proc sampleLines(body: string): seq[string] =
  for line in body.splitLines:
    if line.len > 0 and not line.startsWith("#"): result.add line

proc valueOf(line: string): float =
  parseFloat(line[line.rfind(' ') + 1 .. ^1])

proc body_has_histogram(body: string): bool =
  "call_duration_seconds" in body

suite "Prometheus exposition (O6/B3)":
  test "O6: every family is declared once and every sample line is well formed":
    let clock = newFakeClock()
    let a = newCircuitBreaker(initBreakerConfig(name = "a", clock = clock.source,
                                                latencyPrecision = 2))
    let b = newCircuitBreaker(initBreakerConfig(name = "b", clock = clock.source))
    a.call(proc() = clock.advance(ms(3)))
    b.call(proc() = discard)
    let body = renderPrometheus([a, b])
    var helps, types: seq[string]
    for line in body.splitLines:
      if line.startsWith("# HELP "): helps.add line.split(' ')[2]
      if line.startsWith("# TYPE "): types.add line.split(' ')[2]
    check helps.len == types.len
    check helps.len == types.deduplicate.len       # no family declared twice
    for line in sampleLines(body):
      check '{' in line and "} " in line
      let name = line[0 ..< line.find('{')]
      check name.startsWith("circuit_breaker_")
      check name in types or name.rsplit('_', 1)[0] in types or
            name.rsplit('_', 1)[0].rsplit('_', 1)[0] in types
      discard valueOf(line)                      # must parse as a number

  test "O6: exactly one state is 1 for each breaker":
    let clock = newFakeClock()
    let cb = newCircuitBreaker(initBreakerConfig(name = "s", failureThreshold = 1,
                                                 clock = clock.source))
    discard cb.fail()
    let ones = sampleLines(renderPrometheus([cb])).filterIt("circuit_breaker_state{" in it and it.endsWith(" 1"))
    check ones.len == 1
    check "state=\"Open\"" in ones[0]

  test "O6: histogram buckets are cumulative and end at +Inf equal to the count":
    let clock = newFakeClock()
    let cb = newCircuitBreaker(initBreakerConfig(name = "h", clock = clock.source,
                                                 latencyPrecision = 4))
    for cost in [ms(1), ms(1), ms(5), ms(50)]:
      cb.call(proc() = clock.advance(cost))
    var last = -1.0
    var seenInf = false
    var count = -1.0
    for line in sampleLines(renderPrometheus([cb])):
      if "_bucket{" in line:
        let v = valueOf(line)
        check v >= last                          # cumulative, never decreasing
        last = v
        if "le=\"+Inf\"" in line: seenInf = true
      if "_count{" in line: count = valueOf(line)
    check seenInf
    check last == 4.0
    check count == 4.0

  test "O6: label values are escaped":
    let clock = newFakeClock()
    let cb = newCircuitBreaker(initBreakerConfig(name = "say \"hi\"\\n",
                                                 clock = clock.source))
    let body = renderPrometheus([cb])
    check "name=\"say \\\"hi\\\"\\\\n\"" in body

  test "O6: golden output for a breaker with known state":
    let clock = newFakeClock()
    let cb = newCircuitBreaker(initBreakerConfig(name = "g", failureThreshold = 2,
                                                 clock = clock.source))
    discard cb.fail()
    discard cb.fail()
    let lines = sampleLines(renderPrometheus([cb]))
    check "circuit_breaker_calls_total{name=\"g\",outcome=\"failure\"} 2" in lines
    check "circuit_breaker_transitions_total{name=\"g\"} 1" in lines
    check "circuit_breaker_consecutive_failures{name=\"g\"} 2" in lines
    check "circuit_breaker_state{name=\"g\",state=\"Open\"} 1" in lines
    check "circuit_breaker_open_timeout_seconds{name=\"g\"} 30" in lines
    # no latency histogram when tracking is off
    check not body_has_histogram(renderPrometheus([cb]))

  test "O6: value test: a tripped dependency is visible to an alert":
    # Operator's question: is the payments dependency down, and how many calls
    # is it turning away? The exposition answers with the state and the
    # rejected count, which an alert rule can use directly.
    let clock = newFakeClock()
    let cb = newCircuitBreaker(initBreakerConfig(name = "payments", failureThreshold = 3,
                                                 clock = clock.source))
    for i in 0 ..< 3:
      discard cb.tryCall(proc() = raise newException(ValueError, "timeout"))
    for i in 0 ..< 5:
      discard cb.tryCall(proc() = discard)       # rejected while Open
    let lines = sampleLines(renderPrometheus([cb]))
    check "circuit_breaker_state{name=\"payments\",state=\"Open\"} 1" in lines
    check "circuit_breaker_calls_total{name=\"payments\",outcome=\"rejected\"} 5" in lines

  test "B3: the core does not depend on the exporter":
    let root = currentSourcePath().parentDir.parentDir / "src" / "circuit_breaker"
    for f in ["types.nim", "core.nim", "window.nim", "latency.nim", "keyed.nim", "async.nim"]:
      let src = readFile(root / f)
      check "prometheus" notin src.toLowerAscii
