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

type
  BOpKind = enum okAcquire, okReport, okTick, okForce, okReset
  BOp = object
    kind: BOpKind
    tag: int        ## acquire: its own tag; report: the tag of the acquire
    ok: bool        ## report only: outcome recorded
  BResKind = enum rGranted, rRejected, rAck
  BRes = object
    kind: BResKind
    probe: bool     ## granted only: the permit is a HalfOpen probe

  Phase = enum phClosed, phOpen, phHalfOpen, phForced
  Grant = object
    tag, gen: int
    probe: bool
  BState = object
    phase: Phase
    gen: int          ## equals the breaker's number of transitions
    failures: int    ## consecutive failures in Closed
    probes: int      ## probes in flight in the current generation
    cooled: bool     ## the open period has elapsed
    grants: seq[Grant]  ## granted, not yet reported permits
    threshold: int  ## test constants: part of the state (D-04)
    maxProbes: int
  BModel = object

const
  failureThreshold = 2

  openTimeout = 1000  ## ms; the clock never moves inside a round

func `$`(op: BOp): string =
  case op.kind
  of okAcquire: "acquire#" & $op.tag
  of okReport: "report#" & $op.tag & (if op.ok: " ok" else: " failure")
  of okTick: "tick"
  of okForce: "forceOpen"
  of okReset: "reset"

func `$`(r: BRes): string =
  case r.kind
  of rGranted: (if r.probe: "granted(probe)" else: "granted")
  of rRejected: "rejected"
  of rAck: "ack"

func `==`(a, b: Grant): bool = a.tag == b.tag and a.gen == b.gen and a.probe == b.probe

func `==`(a, b: BState): bool =
  a.phase == b.phase and a.gen == b.gen and a.failures == b.failures and
    a.probes == b.probes and a.cooled == b.cooled and a.grants == b.grants and
    a.threshold == b.threshold and a.maxProbes == b.maxProbes

func hash(s: BState): Hash =
  var h: Hash = 0
  h = h !& hash(ord(s.phase))
  h = h !& hash(s.gen)
  h = h !& hash(s.failures)
  h = h !& hash(s.probes)
  h = h !& hash(s.cooled)
  h = h !& hash(s.threshold)
  h = h !& hash(s.maxProbes)
  for g in s.grants:
    h = h !& hash(g.tag)
    h = h !& hash(g.gen)
    h = h !& hash(g.probe)
  !$h

func `==`(a, b: BRes): bool = a.kind == b.kind and a.probe == b.probe

func granted(probe: bool): BRes = BRes(kind: rGranted, probe: probe)
func rejected(): BRes = BRes(kind: rRejected)
func ack(): BRes = BRes(kind: rAck)

func step*(m: typedesc[BModel], s: BState, op: BOp): Expected[BState, BRes] {.raises: [].} =
  type E = Expected[BState, BRes]
  var n = s
  case op.kind
  of okAcquire:
    case s.phase
    of phClosed:
      n.grants.add Grant(tag: op.tag, gen: s.gen, probe: false)
      result = E(next: n, res: granted(false))
    of phOpen:
      if not s.cooled:
        result = E(next: s, res: rejected(), why: "open")
      else:
        n.phase = phHalfOpen
        inc n.gen
        n.probes = 1
        n.cooled = false
        n.grants.add Grant(tag: op.tag, gen: n.gen, probe: true)
        result = E(next: n, res: granted(true))
    of phHalfOpen:
      if s.probes < s.maxProbes:
        inc n.probes
        n.grants.add Grant(tag: op.tag, gen: s.gen, probe: true)
        result = E(next: n, res: granted(true))
      else:
        result = E(next: s, res: rejected(), why: "probe in progress")
    of phForced:
      result = E(next: s, res: rejected(), why: "forced open")
  of okReport:
    var idx = -1
    for i in 0 ..< s.grants.len:
      if s.grants[i].tag == op.tag:
        idx = i
        break
    if idx < 0:
      return E(next: s, res: ack())   # the acquire was rejected: nothing to report
    let g = s.grants[idx]
    n.grants.delete(idx)
    if g.gen != s.gen:
      return E(next: n, res: ack())   # stale permit: metrics only (D-09)
    if g.probe:
      n.phase = if op.ok: phClosed else: phOpen
      inc n.gen
      n.failures = 0
      n.probes = 0
      n.cooled = false
    elif op.ok:
      n.failures = 0
    else:
      inc n.failures
      if n.failures >= s.threshold:
        n.phase = phOpen
        inc n.gen
        n.failures = 0
        n.probes = 0
        n.cooled = false
    result = E(next: n, res: ack())
  of okTick:
    n.cooled = true
    result = E(next: n, res: ack())
  of okForce:
    if s.phase != phForced:
      n.phase = phForced
      inc n.gen
      n.probes = 0
      n.cooled = false
    result = E(next: n, res: ack())
  of okReset:
    # Closed -> Closed is a no-op in the breaker (no transition, no reset)
    if s.phase != phClosed:
      n.phase = phClosed
      inc n.gen
      n.failures = 0
      n.probes = 0
      n.cooled = false
    result = E(next: n, res: ack())

# ------------------------------------------------------------ the breaker

var
  gClock: FakeClock
  gSlots: array[64, Permit]       ## one slot per tag; each is reported once
  gGranted: array[64, bool]
  gInit: BState                   ## initial model state of the current round
  gRound: int                     ## round number, read by `setupRound`
  gMaxProbes: int                 ## probe limit of the current round (1 or 2)

proc newTestBreaker(clock: FakeClock): CircuitBreaker =
  newCircuitBreaker(BreakerConfig(
    name: "linearizable", policy: ConsecutiveFailures,
    failureThreshold: failureThreshold, openTimeout: initDuration(milliseconds = openTimeout),
    halfOpenMaxProbes: gMaxProbes, successThreshold: 1,
    backoffMultiplier: 1.0, jitter: 0.0,
    clock: clock.source, seed: 42))

proc openedBreaker(cb: CircuitBreaker, clock: FakeClock) =
  ## Two failures open the circuit; the clock then passes the open timeout.
  for _ in 1 .. failureThreshold:
    var p: Permit
    doAssert cb.tryAcquire(p)
    p.failure()
  clock.advance(initDuration(milliseconds = openTimeout))

proc stateOf(phase: Phase): CircuitState =
  case phase
  of phClosed: Closed
  of phOpen: Open
  of phHalfOpen: HalfOpen
  of phForced: ForcedOpen

proc exec(obj: ptr CircuitBreaker, op: BOp): BRes {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    case op.kind
    of okAcquire:
      if obj[].tryAcquire(gSlots[op.tag]):
        gGranted[op.tag] = true
        result = granted(gSlots[op.tag].isProbe)
      else:
        result = rejected()
    of okReport:
      if gGranted[op.tag]:
        gGranted[op.tag] = false
        if op.ok: gSlots[op.tag].success() else: gSlots[op.tag].failure()
      result = ack()
    of okTick:
      gClock.advance(initDuration(milliseconds = openTimeout))
      result = ack()
    of okForce:
      obj[].forceOpen()
      result = ack()
    of okReset:
      obj[].reset()
      result = ack()

proc setupRound(obj: var CircuitBreaker) {.nimcall.} =
  {.cast(gcsafe).}:
    gMaxProbes = 1 + (gRound div 2) mod 2
    gClock = newFakeClock()
    obj = newTestBreaker(gClock)
    gGranted = default(array[64, bool])
    if gRound mod 2 == 0:
      # scenario A: Open whose timeout has elapsed (HalfOpen races)
      openedBreaker(obj, gClock)
      gInit = BState(phase: phOpen, gen: obj.metrics.transitions, cooled: true,
                     threshold: failureThreshold, maxProbes: gMaxProbes)
    else:
      # scenario B: Closed (concurrent Closed -> Open, stale permits)
      gInit = BState(phase: phClosed, gen: obj.metrics.transitions,
                     threshold: failureThreshold, maxProbes: gMaxProbes)

# ------------------------------------------------------------ generators

proc genRoundOp(rng: var Rand, thread, index: int): BOp {.nimcall.} =
  ## Per thread: acquire, report, acquire, report. The report of an
  ## acquire that was rejected (or an admin pair) is a no-op.
  let tag = thread * 10 + index div 2
  if index mod 2 == 0:
    if rng.rand(9) == 0:
      BOp(kind: (if rng.rand(1) == 0: okForce else: okReset), tag: tag)
    else:
      BOp(kind: okAcquire, tag: tag)
  else:
    BOp(kind: okReport, tag: tag, ok: rng.rand(1) == 0)

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

  proc saveFailure(round: int, h: History[BOp, BRes]) =
    let path = "t_linearizable-round" & $round & ".jsonl"
    try: writeFile(path, h.toJsonLines()) except IOError: discard
    echo "history saved to ", path

  proc checkRounds(threads, opsPerThread, rounds, seed: int): bool =
    ## Runs `rounds` recorded rounds; stops and saves at the first failure.
    ## True when every round is linearizable.
    let cfg = RoundsConfig(threads: threads, opsPerThread: opsPerThread,
                           seed: seed, budget: budget)
    for round in 1 .. rounds:
      gRound = round
      let h = runRound(cfg, round, setupRound, genRoundOp, exec)
      let v = checkLinearizable(h, gInit, BModel, budget)
      if v.kind != vkLinearizable:
        saveFailure(round, h)
        echo report(v, h)
        return false
    true

  suite "CircuitBreaker: linearizable under real threads":
    test "3 threads x 4 ops, probe limit 1 and 2":
      check checkRounds(threads = 3, opsPerThread = 4, rounds = roundsToRun, seed = 7)

    test "4 threads x 6 ops, probe limit 1 and 2":
      check checkRounds(threads = 4, opsPerThread = 6, rounds = 500, seed = 11)
else:
  suite "CircuitBreaker: linearizable under real threads":
    test "V-L: skipped (compile with --threads:on)":
      skip()
