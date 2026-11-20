## O4: latency histogram. Logarithmic buckets: each power of two (octave) is
## split into `k` sub-buckets, so a bucket's width is at most 1/k of its lower
## bound. `k` is the `latencyPrecision` setting (1..8, 0 disables tracking).
## Only integer work on the recording path; no allocation per sample.

import std/[math, bitops]

const
  maxLatencyPrecision* = 8  ## Largest accepted `latencyPrecision`.
  maxOctave = 62  # ns values are int64 and non-negative, so octave <= 62

proc latencyBucketCount*(k: int): int {.inline.} =
  ## Number of buckets of a histogram with precision `k`.
  (maxOctave + 1) * k

proc latencyBucketOf*(ns: int64; k: int): int {.inline.} =
  ## Bucket index of a duration in nanoseconds (non-positive values go to 0).
  if ns <= 0: return 0
  let u = uint64(ns)
  let oct = 63 - countLeadingZeroBits(u)
  let off = u - (1'u64 shl oct)              # < 2^oct
  let sub =
    if oct >= 8: int(((off shr uint(oct - 8)) * uint64(k)) shr 8)
    else: int((off * uint64(k)) shr uint(oct))
  oct * k + min(sub, k - 1)

proc latencyBucketLower*(idx: int; k: int): int64 =
  ## Lower bound (ns) of a bucket. Values in bucket `idx` are at least this,
  ## and below the lower bound of `idx + 1`, up to float rounding.
  let oct = idx div k
  let sub = idx mod k
  let base = pow(2.0, float(oct))
  let bound = base + base * float(sub) / float(k)
  if bound >= 9.2e18: high(int64) else: int64(bound)

proc latencyPercentile*(counts: openArray[int64]; k: int; p: float): int64 =
  ## Lower bound of the bucket holding the `p`-quantile (0 < p <= 1) of the
  ## recorded samples; 0 when there are none. The true value is at most
  ## 1/k (relative) above the result.
  var total = 0'i64
  for c in counts: total += c
  if total == 0: return 0
  let rank = max(1'i64, int64(ceil(p * float(total))))
  var acc = 0'i64
  for i, c in counts:
    acc += c
    if acc >= rank: return latencyBucketLower(i, k)
  latencyBucketLower(counts.high, k)
