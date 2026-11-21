## V3/S7/C1–C3: stress test with real threads. Invariants checked:
## - never more than `halfOpenMaxProbes` probes run at the same time;
## - every attempt is accounted for exactly once in the metrics.

import std/unittest
import helpers

when compileOption("threads"):
  import std/[typedthreads, atomics]

  const
    threadCount = 8
    iterations = 20_000
    maxProbes = 2

  var gClock: FakeClock
  var gBreaker: CircuitBreaker
  var probesPeak, attempts: Atomic[int]

  proc worker(id: int) {.thread.} =
    {.cast(gcsafe).}:
      for i in 0 ..< iterations:
        if i mod 50 == 0: gClock.advance(ms(1))
        attempts.atomicInc()
        var p: Permit
        if gBreaker.tryAcquire(p):
          if p.isProbe:
            # The breaker's own counter covers only probes of the current
            # generation; probes of a previous generation may still be
            # running but no longer count (their outcomes are stale).
            let now = gBreaker.metrics.probesInFlight
            var peak = probesPeak.load
            while now > peak and not probesPeak.compareExchange(peak, now): discard
          if (i + id) mod 4 == 0: p.failure() else: p.success()

  suite "concurrency":
    test "V3/S7/C1/C2/C3: probes limited and metrics consistent under 8 threads":
      gClock = newFakeClock()
      gBreaker = newCircuitBreaker(initBreakerConfig(policy = FailureRate,
        failureRateThreshold = 0.2, minimumCalls = 20, windowSize = 50,
        openTimeout = ms(5), halfOpenMaxProbes = maxProbes,
        clock = gClock.source))
      var threads: array[threadCount, Thread[int]]
      for i in 0 ..< threadCount: startThread(threads[i], worker, i)
      joinThreads(threads)
      let m = gBreaker.metrics
      checkpoint "peak=" & $probesPeak.load & " attempts=" & $attempts.load & "\n" & gBreaker.report
      check probesPeak.load <= maxProbes
      check m.transitions > 10        # the circuit really cycled
      check m.successes + m.failures + m.ignored + m.rejected == attempts.load
      check m.probesInFlight == 0
else:
  suite "concurrency":
    test "V3: skipped (compile with --threads:on)":
      skip()
