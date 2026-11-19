## BM5: sliding window cost must not grow with the window size (O(1)).

import std/times
import harness
import ../src/circuit_breaker

const n = 200_000

proc main() =
  header("sliding window (FailureRate policy, call in Closed)")
  let fn = proc(): int = 1
  for size in [10, 100, 1_000, 100_000]:
    let cb = newCircuitBreaker(initBreakerConfig(policy = FailureRate,
      windowSize = size, minimumCalls = min(10, size)))
    bench("BM5 count window size " & $size, n):
      keep = cb.call(fn)
  for buckets in [10, 60, 600]:
    let cb = newCircuitBreaker(initBreakerConfig(policy = FailureRate,
      windowKind = TimeWindow, windowDuration = initDuration(seconds = 60),
      windowBuckets = buckets))
    bench("BM5 time window " & $buckets & " buckets", n):
      keep = cb.call(fn)
  writeJson("b_window.json")

main()
