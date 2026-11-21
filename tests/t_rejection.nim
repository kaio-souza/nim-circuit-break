## Rejection while Open, checked on the locked path. (A lock-free rejection was
## measured against it and reverted: the clock read dominates both paths.)
## Checks:
## - the rejection carries the same retry hint as the locked path;
## - at the exact deadline the call is admitted as a probe;
## - under 8 threads, every rejection is counted exactly once.

import std/[unittest, os]
import helpers

when compileOption("threads"):
  import std/[typedthreads, atomics]

  const
    threadCount = 8
    iterations = 20_000

  var gBreaker: CircuitBreaker
  var gRejected: Atomic[int]

  proc worker(id: int) {.thread.} =
    {.cast(gcsafe).}:
      for i in 0 ..< iterations:
        var p: Permit
        if not gBreaker.tryAcquire(p):
          gRejected.atomicInc()
        else:
          p.success()

  suite "lock-free rejection":
    test "rejection hint matches the open deadline":
      let clock = newFakeClock()
      let cb = newCircuitBreaker(BreakerConfig(failureThreshold: 1,
        openTimeout: ms(1000), clock: clock.source))
      discard cb.fail()
      clock.advance(ms(300))
      var p: Permit
      check not cb.tryAcquire(p)
      check cb.metrics.rejected == 1
      expect CircuitOpenError:
        discard cb.acquire()
      check cb.metrics.rejected == 2
      # the hint of the last rejection: 1000 - 300 = 700 ms
      try:
        discard cb.acquire()
      except CircuitOpenError as e:
        check e.retryAfter == ms(700)

    test "at the deadline the fast path hands over and admits a probe":
      let clock = newFakeClock()
      let cb = newCircuitBreaker(BreakerConfig(failureThreshold: 1,
        openTimeout: ms(1000), clock: clock.source))
      discard cb.fail()
      clock.advance(ms(999))
      var p: Permit
      check not cb.tryAcquire(p)
      clock.advance(ms(1))
      check cb.tryAcquire(p)
      check p.isProbe
      p.success()
      check cb.state == Closed

    test "shadow mode keeps the locked path (it must not reject)":
      let clock = newFakeClock()
      let cb = newCircuitBreaker(BreakerConfig(failureThreshold: 1,
        openTimeout: ms(1000), clock: clock.source, shadowMode: true))
      discard cb.fail()
      var p: Permit
      check cb.tryAcquire(p)
      check p.isShadow
      check cb.metrics.shadowRejected == 1
      check cb.metrics.rejected == 0

    test "real clock: far from the deadline the hint stays within the open period":
      # On Linux this takes the coarse-clock path; elsewhere the precise one.
      let cb = newCircuitBreaker(BreakerConfig(failureThreshold: 1,
        openTimeout: initDuration(hours = 1), maxOpenTimeout: initDuration(hours = 1)))
      discard cb.fail()
      for i in 0 ..< 3:
        try:
          discard cb.acquire()
          check false
        except CircuitOpenError as e:
          check e.retryAfter <= initDuration(hours = 1) + ms(50)
          check e.retryAfter > initDuration(hours = 1) - initDuration(seconds = 5)
      check cb.metrics.rejected == 3

    test "real clock: a short open period ends on time (precise path near the deadline)":
      let cb = newCircuitBreaker(BreakerConfig(failureThreshold: 1,
        openTimeout: ms(30), maxOpenTimeout: ms(30)))
      discard cb.fail()
      var p: Permit
      check not cb.tryAcquire(p)
      sleep(45)
      check cb.tryAcquire(p)
      check p.isProbe
      p.success()

    when compileOption("threads"):
      test "every rejection counted exactly once under 8 threads":
        gBreaker = newCircuitBreaker(BreakerConfig(failureThreshold: 1,
          openTimeout: initDuration(hours = 1), maxOpenTimeout: initDuration(hours = 1)))
        discard gBreaker.fail()
        gRejected.store(0)
        var threads: array[threadCount, Thread[int]]
        for i in 0 ..< threadCount:
          startThread(threads[i], worker, i)
        joinThreads(threads)
        check gRejected.load == threadCount * iterations
        check gBreaker.metrics.rejected == int64(threadCount * iterations)
