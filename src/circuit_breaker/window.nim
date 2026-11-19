## Sliding windows with O(1) updates and fixed memory (F2, F3, P3).

import types

type
  TimeBucket = object
    epoch: int64
    calls, failures, slow: int

  SlidingWindow* = object
    calls, failures, slow: int
    case kind: WindowKind
    of CountWindow:
      flags: seq[uint8]   # bit 0: failure, bit 1: slow
      head, filled: int
    of TimeWindow:
      buckets: seq[TimeBucket]
      bucketNanos: int64
      lastEpoch: int64

proc initSlidingWindow*(kind: WindowKind; size: int; durationNs: int64;
                        buckets: int): SlidingWindow =
  case kind
  of CountWindow:
    result = SlidingWindow(kind: CountWindow, flags: newSeq[uint8](size))
  of TimeWindow:
    result = SlidingWindow(kind: TimeWindow, buckets: newSeq[TimeBucket](buckets),
                           bucketNanos: max(1'i64, durationNs div buckets))

proc kind*(w: SlidingWindow): WindowKind {.inline.} = w.kind

proc expire(w: var SlidingWindow; now: int64) {.inline.} =
  ## Clears only the slots of the epochs that passed since the last call:
  ## amortized O(1), at most `buckets` slots per call.
  let cur = now div w.bucketNanos
  if cur <= w.lastEpoch: return
  let n = w.buckets.len.int64
  for e in w.lastEpoch + 1 .. w.lastEpoch + min(cur - w.lastEpoch, n):
    let b = addr w.buckets[int(e mod n)]
    w.calls -= b.calls
    w.failures -= b.failures
    w.slow -= b.slow
    b[] = TimeBucket(epoch: e)
  w.lastEpoch = cur

proc add*(w: var SlidingWindow; now: int64; failed, slow: bool) =
  ## Records one call outcome.
  case w.kind
  of CountWindow:
    let flag = uint8(ord(failed)) or (uint8(ord(slow)) shl 1)
    if w.filled == w.flags.len:
      let old = w.flags[w.head]
      dec w.calls
      if (old and 1) != 0: dec w.failures
      if (old and 2) != 0: dec w.slow
    else:
      inc w.filled
    w.flags[w.head] = flag
    inc w.head
    if w.head == w.flags.len: w.head = 0
  of TimeWindow:
    w.expire(now)
    let cur = now div w.bucketNanos
    let i = int(cur mod w.buckets.len.int64)
    inc w.buckets[i].calls
    if failed: inc w.buckets[i].failures
    if slow: inc w.buckets[i].slow
  inc w.calls
  if failed: inc w.failures
  if slow: inc w.slow

proc stats*(w: var SlidingWindow; now: int64): WindowStats =
  if w.kind == TimeWindow: w.expire(now)
  result = WindowStats(calls: w.calls, failures: w.failures, slowCalls: w.slow)
  if w.calls > 0:
    result.failureRate = w.failures / w.calls
    result.slowCallRate = w.slow / w.calls

proc clear*(w: var SlidingWindow) =
  w.calls = 0
  w.failures = 0
  w.slow = 0
  case w.kind
  of CountWindow:
    for f in w.flags.mitems: f = 0
    w.head = 0
    w.filled = 0
  of TimeWindow:
    for b in w.buckets.mitems: b = TimeBucket()
    w.lastEpoch = 0
