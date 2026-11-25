## Linearizability of the breaker under nimlinear's PCT scheduler, with the
## breaker's atomics and lock intercepted (nimlinear/intercept, D-26 of
## nim-linear): every atomic write and lock acquire in `core` is a switch
## point, so narrow races on the lock-free paths are explored without any
## `perturb()` in `src/`. Deterministic: the same seed gives the same rounds.
## Compiled with -d:nimlinearPerturb -d:nimlinearIntercept
## (t_linearizable_sched.nims); needs --threads:on.

import std/[hashes, random, times, unittest]
import circuit_breaker, circuit_breaker/testing
import nimlinear

include linearizable_common

when compileOption("threads"):
  proc scheduledRounds(threads, opsPerThread, rounds, seed: int): RoundsResult[BOp, BRes] =
    runRounds(RoundsConfig(threads: threads, opsPerThread: opsPerThread, rounds: rounds,
                           seed: seed, budget: 500_000, schedule: true, depth: 4,
                           saveDir: ".", name: "t_linearizable_sched"),
              initOf, BModel, setupInfo, genRoundOp, exec)

  suite "CircuitBreaker: linearizable under the PCT scheduler (intercepted)":
    test "3 threads x 4 ops, probe limit 1 and 2":
      let r = scheduledRounds(threads = 3, opsPerThread = 4, rounds = 5_000, seed = 7)
      if not r.passed: echo r.describe
      check r.passed
      check r.steps > 0              # calibrated on round 1 (switch points really happen)

    test "4 threads x 6 ops, probe limit 1 and 2":
      let r = scheduledRounds(threads = 4, opsPerThread = 6, rounds = 1_000, seed = 11)
      if not r.passed: echo r.describe
      check r.passed
else:
  suite "CircuitBreaker: linearizable under the PCT scheduler (intercepted)":
    test "skipped (compile with --threads:on)":
      skip()
