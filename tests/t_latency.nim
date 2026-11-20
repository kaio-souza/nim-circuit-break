## O4: latency histogram. Unit tests of the bucket math, a value test with a
## known bimodal workload (the percentiles must show the slow tail that the
## mean hides), and checks that tracking stays off unless asked for.

import std/[unittest, math]
import helpers
import circuit_breaker/latency

suite "latency histogram (O4)":
  test "O4: bucket bounds bracket every value within 1/k relative width":
    for k in 1 .. maxLatencyPrecision:
      for ns in [1'i64, 2, 3, 7, 15, 16, 17, 100, 999, 1000, 1023, 1024,
                 123_456, 1_000_000, 987_654_321, 1 shl 40, (1'i64 shl 61) + 12345]:
        let idx = latencyBucketOf(ns, k)
        let lo = latencyBucketLower(idx, k)
        let hi = latencyBucketLower(idx + 1, k)
        # one nanosecond of slack for the float rounding of the bounds
        check lo <= ns + 1
        check ns < hi + 1
        if ns >= 16:
          # relative slack for the float rounding of the bounds at large values
          check float(hi - lo) <= float(lo) / float(k) * (1.0 + 1e-9) + 2.0

  test "bucket index is monotonic in the duration":
    for k in [1, 4, 8]:
      var prev = -1
      var ns = 1'i64
      while ns < 1'i64 shl 40:
        let idx = latencyBucketOf(ns, k)
        check idx >= prev
        prev = idx
        ns += max(1'i64, ns div 97)

  test "percentile of an empty histogram is zero":
    check latencyPercentile(newSeq[int64](latencyBucketCount(4)), 4, 0.5) == 0

  test "O4: value test: the p95 shows a 100 ms tail that the 1 ms median hides":
    # 90% of calls take 1 ms, 10% take 100 ms. The mean is 10.9 ms, which
    # describes none of the calls. The percentiles tell the two modes apart.
    let clock = newFakeClock()
    let k = 8
    let cb = newCircuitBreaker(initBreakerConfig(
      name = "bimodal", failureThreshold = 1000, clock = clock.source,
      latencyPrecision = k))
    for i in 0 ..< 1000:
      let cost = if i mod 10 == 9: ms(100) else: ms(1)
      cb.call(proc() = clock.advance(cost))
    let m = cb.metrics
    check m.latencyCount == 1000
    let p50 = m.latencyQuantile(0.5).inNanoseconds
    let p95 = m.latencyQuantile(0.95).inNanoseconds
    # the quantile is the bucket's lower bound: at most 1/k below the truth
    check p50 <= 1_000_000
    check float(p50) * (1.0 + 1.0 / float(k)) >= 1_000_000.0
    check p95 <= 100_000_000
    check float(p95) * (1.0 + 1.0 / float(k)) >= 100_000_000.0

  test "O4: tracking is off by default: no buckets, zero quantiles":
    let clock = newFakeClock()
    let cb = newCircuitBreaker(initBreakerConfig(clock = clock.source))
    cb.call(proc() = clock.advance(ms(5)))
    let m = cb.metrics
    check m.latencyPrecision == 0
    check m.latencyCount == 0
    check m.latencyBuckets.len == 0
    check m.latencyQuantile(0.99) == initDuration()

  test "O4: failures are sampled too":
    let clock = newFakeClock()
    let cb = newCircuitBreaker(initBreakerConfig(
      name = "mixed", failureThreshold = 1000, clock = clock.source,
      latencyPrecision = 4))
    cb.call(proc() = clock.advance(ms(2)))
    expect ValueError:
      cb.call(proc() =
        clock.advance(ms(2))
        raise newException(ValueError, "boom"))
    check cb.metrics.latencyCount == 2
    check cb.metrics.successes == 1
    check cb.metrics.failures == 1

  test "O4: invalid precision is rejected by validation":
    expect ValueError:
      discard newCircuitBreaker(initBreakerConfig(latencyPrecision = 9))
    expect ValueError:
      discard newCircuitBreaker(initBreakerConfig(latencyPrecision = -1))
