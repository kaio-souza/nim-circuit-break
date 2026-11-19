## BM2: scalability of `call` in Closed with N threads sharing one breaker.
## Reports wall time per operation (all threads) and total throughput.

import std/[monotimes, times, strformat, typedthreads, algorithm]
import harness
import ../src/circuit_breaker

const opsPerThread = 500_000

var gBreaker: CircuitBreaker

proc worker(dummy: int) {.thread.} =
  {.cast(gcsafe).}:
    let fn = proc(): int = 1
    var acc = 0
    for _ in 0 ..< opsPerThread:
      acc += gBreaker.call(fn)
    keep = acc

proc run(threads: int): float =
  var ts = newSeq[Thread[int]](threads)
  let t0 = getMonoTime()
  for i in 0 ..< threads: createThread(ts[i], worker, i)
  joinThreads(ts)
  (getMonoTime() - t0).inNanoseconds.float

proc main() =
  echo "\n## BM2 threads (call in Closed, shared breaker)"
  echo &"""{"threads":>8} {"ns/op (wall)":>14} {"Mops/s total":>14}"""
  gBreaker = newCircuitBreaker(initBreakerConfig())
  for threads in [1, 2, 4, 8]:
    var runs: seq[float]
    for _ in 1 .. 5: runs.add run(threads)
    runs.sort()
    let ns = runs[2]                       # median of 5
    let ops = float(threads * opsPerThread)
    echo &"{threads:>8} {ns / ops:>14.1f} {ops / ns * 1000.0:>14.1f}"

main()
