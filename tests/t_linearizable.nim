## Linearizability of the breaker with nimlinear (plan: nim-linear-notas-breaker/INTEGRACAO-CIRCUIT-BREAKER.md).
##
## - Sequential: random single-thread runs of the breaker and of the model
##   agree on every result, state and generation (validates the model first).
## - Concurrent (--threads:on): small recorded rounds (3 threads x 4 ops) are
##   checked for linearizability; a failing history is saved for replay.
##
## The breaker's `Permit`s are kept in global slots, one per tag; each
## acquire is reported by the same thread later, or never granted.


import std/[hashes, random, times, unittest]
import circuit_breaker, circuit_breaker/testing
import nimlinear

include linearizable_common

# ------------------------------------------------------------ tests

suite "CircuitBreaker: model agrees with the breaker (sequential)":
  test "random single-thread runs: result, state and generation match":
    var rng = initRand(2026)
    for run in 0 ..< 3000:
      gRound = run    # alternates scenario A and B
      var cb: CircuitBreaker
      setupRound(cb)
      var st = gInit
      var pending: seq[int]
      var nextTag = 0
      for _ in 0 ..< 40:
        let r = rng.rand(9)
        var op: BOp
        if (r < 4 or pending.len == 0) and nextTag < 60:
          op = BOp(kind: okAcquire, tag: nextTag)
          pending.add nextTag
          inc nextTag
        elif r < 7 and pending.len > 0:
          let i = rng.rand(pending.high)
          op = BOp(kind: okReport, tag: pending[i], ok: rng.rand(1) == 0)
          pending.delete(i)
        elif r == 7: op = BOp(kind: okForce)
        elif r == 8: op = BOp(kind: okReset)
        else: op = BOp(kind: okTick)
        let want = BModel.step(st, op)
        let got = exec(addr cb, op)
        checkpoint "run " & $run & ", op " & $op & ", state " & $st.phase
        check got == want.res
        check cb.state == stateOf(want.next.phase)
        check cb.metrics.transitions == want.next.gen
        st = want.next
      # every permit is reported, so no permit is dropped with an outcome
      for tag in pending:
        let op = BOp(kind: okReport, tag: tag, ok: rng.rand(1) == 0)
        discard BModel.step(st, op)
        discard exec(addr cb, op)

when compileOption("threads"):
  const
    roundsToRun = 20_000
    budget = 500_000

  proc checkRounds(threads, opsPerThread, rounds, seed: int): bool =
    ## `rounds` recorded rounds under the OS scheduler; on the first failure
    ## the history is shrunk, saved and printed. True when all pass.
    let r = runRounds(RoundsConfig(threads: threads, opsPerThread: opsPerThread, rounds: rounds,
                                   seed: seed, budget: budget, saveDir: ".", name: "t_linearizable"),
                      initOf, BModel, setupInfo, genRoundOp, exec)
    if not r.passed: echo r.describe
    r.passed

  suite "CircuitBreaker: linearizable under real threads":
    test "3 threads x 4 ops, probe limit 1 and 2":
      check checkRounds(threads = 3, opsPerThread = 4, rounds = roundsToRun, seed = 7)

    test "4 threads x 6 ops, probe limit 1 and 2":
      check checkRounds(threads = 4, opsPerThread = 6, rounds = 500, seed = 11)
else:
  suite "CircuitBreaker: linearizable under real threads":
    test "V-L: skipped (compile with --threads:on)":
      skip()
