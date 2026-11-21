## Circuit breaker state machine.
##
## Concurrency model (C1): with `--threads:on` the breaker is thread-safe.
## The state and its generation live in one atomic word, so the hot path in
## `Closed` takes no lock to grant a call; recording an outcome and every
## transition take a short lock. Callbacks run outside the lock.
## A `CircuitBreaker` must outlive the permits it grants, so in multi-threaded
## code keep it in a global or another long-lived owner.

import std/[times, monotimes, atomics, random, math]
import types, private/[window, latency, sync]

export types

type
  CircuitBreakerObj = object
    # P5/R3: fields are grouped by how threads touch them, and each group that
    # every call writes sits on its own cache line (64-byte pads; the heap
    # only guarantees 16-byte alignment, so a full line of padding is what
    # keeps two groups apart). Measured with BM2 at 2, 4 and 8 threads: 30 to
    # 36% lower cost per call than with the counters next to the state.
    #
    # Read by every call, written only on transitions or reconfiguration:
    packed: Atomic[int]       # (generation shl 3) or ord(state)
    needsStart: Atomic[bool]  # whether permits must read the clock on grant
    fastSuccess: Atomic[bool] # successes in Closed can skip the lock
    hasConsecutive: Atomic[bool] # mirror of `consecutive > 0`
    rejectFast: Atomic[bool]  # rejections may skip the lock (BM3)
    openUntil: Atomic[int64]  # read without the lock by the rejection fast path (BM3)
    cfg: BreakerConfig
    latency: seq[Atomic[int64]]  # O4: empty unless latencyPrecision > 0
    pad0: array[64, byte]
    # Written by every success:
    successes: Atomic[int64]
    pad1: array[64, byte]
    # Written by every rejection:
    rejected: Atomic[int64]
    pad2: array[64, byte]
    # Written by every sampled call when latency tracking is on:
    latencySum: Atomic[int64]    # O4: total sampled nanoseconds (for _sum)
    pad3: array[64, byte]
    # Under the lock:
    callbackErrors: Atomic[int]
    lock: Lock
    window: SlidingWindow
    consecutive: int
    openLevel: int
    currentOpenNs: int64
    probesInFlight: int
    probeSuccesses: int
    rng: Rand
    failures, ignored, shadowRejected, slowCalls, transitions: int64
    history: seq[TransitionEvent]
    historyNext: int

  CircuitBreaker* = ref CircuitBreakerObj
    ## A circuit breaker. Create with `newCircuitBreaker`; safe to share between
    ## threads. Must outlive the `Permit`s it grants.
  BreakerPtr = ptr CircuitBreakerObj

  Permit* = object
    ## Permission to run one call (E2). If it goes out of scope without
    ## `success`, `failure`, `ignore` or `record`, a failure is recorded
    ## automatically, so a forgotten outcome never leaves the breaker stuck.
    cb: BreakerPtr
    gen: int
    startNs: int64
    probe: bool
    shadow: bool
    done: bool

# P5/R3: the hot groups must stay a full cache line apart.
static:
  const
    latencyAt = offsetOf(CircuitBreakerObj, latency)
    successesAt = offsetOf(CircuitBreakerObj, successes)
    rejectedAt = offsetOf(CircuitBreakerObj, rejected)
    latencySumAt = offsetOf(CircuitBreakerObj, latencySum)
  doAssert successesAt - latencyAt >= 64 + sizeof(seq[int])
  doAssert rejectedAt - successesAt >= 64
  doAssert latencySumAt - rejectedAt >= 64

# ---------------------------------------------------------------- helpers

template locked(b: BreakerPtr; body: untyped) =
  withLockIfThreads(b.lock, body)

when defined(linux):
  import std/posix
  const
    clockMonotonicCoarse = ClockId(6)  # CLOCK_MONOTONIC_COARSE
    coarseMarginNs = 20_000_000'i64
      ## The coarse clock lags the precise one by about one tick (1.4 ms was
      ## measured against a declared 1 ms resolution). Rejections closer than
      ## this to the deadline use the precise clock.

  proc coarseNowNs(): int64 {.inline.} =
    ## Same time base as `getMonoTime` (CLOCK_MONOTONIC), never ahead of it,
    ## at about 8 ns instead of 19 ns per read.
    var ts: Timespec
    discard clock_gettime(clockMonotonicCoarse, ts)
    ts.tv_sec.int64 * 1_000_000_000 + ts.tv_nsec.int64

proc nowNs(b: BreakerPtr): int64 {.inline.} =
  if b.cfg.clock.isNil: getMonoTime().ticks else: b.cfg.clock()

proc loadState(b: BreakerPtr): tuple[state: CircuitState; gen: int] {.inline.} =
  let v = b.packed.load(moAcquire)
  (CircuitState(v and 7), v shr 3)

proc storeState(b: BreakerPtr; s: CircuitState; gen: int) {.inline.} =
  b.packed.store((gen shl 3) or ord(s), moRelease)

proc nanos(d: Duration): int64 {.inline.} = d.inNanoseconds

proc tracksWindow(c: BreakerConfig): bool {.inline.} =
  ## The sliding window is only needed by the rate and slow-call policies.
  c.policy == FailureRate or c.slowCallDuration.nanos > 0

proc updateFastFlags(b: BreakerPtr) =
  b.needsStart.store(b.cfg.slowCallDuration.nanos > 0 or not b.cfg.onCall.isNil or
                     b.cfg.latencyPrecision > 0, moRelease)
  b.fastSuccess.store(not b.cfg.tracksWindow and b.cfg.onCall.isNil, moRelease)
  # A rejection has no side effect besides the counter, unless shadow mode
  # lets it through or an onCall event must be built.
  b.rejectFast.store(not b.cfg.shadowMode and b.cfg.onCall.isNil, moRelease)

proc setConsecutive(b: BreakerPtr; v: int) {.inline.} =
  b.consecutive = v
  b.hasConsecutive.store(v > 0, moRelease)

proc newWindow(c: BreakerConfig): SlidingWindow =
  initSlidingWindow(c.windowKind, c.windowSize, c.windowDuration.nanos, c.windowBuckets)

# ------------------------------------------------------------- creation

proc newCircuitBreaker*(cfg: BreakerConfig): CircuitBreaker =
  ## Creates a breaker. Raises `ValueError` for an invalid config (K2).
  validate(cfg)
  result = CircuitBreaker(cfg: cfg)
  let b = addr result[]
  initLockIfThreads(b.lock)
  b.window = newWindow(cfg)
  b.rng = initRand(if cfg.seed != 0: cfg.seed else: getMonoTime().ticks)
  b.currentOpenNs = cfg.openTimeout.nanos
  if cfg.latencyPrecision > 0:
    b.latency = newSeq[Atomic[int64]](latencyBucketCount(cfg.latencyPrecision))
  b.storeState(Closed, 0)
  b.updateFastFlags()

proc newCircuitBreaker*(name: string; failureThreshold: int;
                        openTimeout: Duration): CircuitBreaker =
  ## Shortcut for the common consecutive-failures setup.
  newCircuitBreaker(initBreakerConfig(name = name, failureThreshold = failureThreshold,
                                      openTimeout = openTimeout))

# ---------------------------------------------------------- transitions

type Pending = object
  transitions: seq[TransitionEvent]
  call: CallEvent
  hasCall: bool

proc transitionLocked(b: BreakerPtr; to: CircuitState; reason: TransitionReason;
                      now: int64; p: var Pending; hint = 0'i64) =
  let (frm, gen) = b.loadState()
  if frm == to: return
  var ev = TransitionEvent(fromState: frm, toState: to, reason: reason,
                           consecutiveFailures: b.consecutive, atNanos: now,
                           stats: b.window.stats(now))
  # Probes belong to the previous generation; their late outcomes are stale.
  b.probesInFlight = 0
  b.probeSuccesses = 0
  case to
  of Open:
    var t: int64
    if hint > 0:
      t = hint
    else:
      let base = b.cfg.openTimeout.nanos.float
      let maxT = b.cfg.maxOpenTimeout.nanos.float
      var f = min(base * pow(b.cfg.backoffMultiplier, b.openLevel.float), maxT)
      if b.cfg.jitter > 0.0:
        f += f * b.rng.rand(b.cfg.jitter)  # only ever later, never earlier
      t = int64(f)
    inc b.openLevel
    b.currentOpenNs = t
    b.openUntil.store(now + t, moRelaxed)  # published by storeState (release)
    ev.openFor = initDuration(nanoseconds = t)
  of HalfOpen:
    discard
  of Closed:
    b.window.clear()
    b.setConsecutive(0)
    b.openLevel = 0
    b.currentOpenNs = b.cfg.openTimeout.nanos
  of ForcedOpen, Disabled:
    discard
  b.storeState(to, gen + 1)
  inc b.transitions
  if b.cfg.historySize > 0:
    if b.history.len < b.cfg.historySize:
      b.history.add ev
    else:
      b.history[b.historyNext] = ev
    b.historyNext = (b.historyNext + 1) mod b.cfg.historySize
  if not b.cfg.onTransition.isNil:
    ev.breaker = b.cfg.name
    p.transitions.add ev

proc dispatch(b: BreakerPtr; p: var Pending) =
  ## Runs callbacks outside the lock; their exceptions never escape (O2).
  for ev in p.transitions:
    try:
      b.cfg.onTransition(ev)
    except Exception:
      discard b.callbackErrors.fetchAdd(1)
  if p.hasCall:
    p.call.breaker = b.cfg.name
    try:
      b.cfg.onCall(p.call)
    except Exception:
      discard b.callbackErrors.fetchAdd(1)

proc recordCore(b: BreakerPtr; gen: int; startNs: int64; probe, shadow: bool;
                v: Verdict) {.raises: [].}

proc rateTripLocked(b: BreakerPtr; now, slowNs: int64;
                    reason: var TransitionReason): bool {.inline.} =
  ## The rate policies of `Closed` (failure rate, slow-call rate), in one
  ## place for every recording path. True when the circuit must open.
  let st = b.window.stats(now)
  if st.calls < b.cfg.minimumCalls: return false
  if b.cfg.policy == FailureRate and st.failureRate >= b.cfg.failureRateThreshold:
    reason = trFailureRate
    return true
  if slowNs > 0 and st.slowCallRate >= b.cfg.slowCallRateThreshold:
    reason = trSlowCallRate
    return true

proc recordForgotten(p: Permit) {.noinline.} =
  ## Cold path: the permit went out of scope without an outcome.
  p.cb.recordCore(p.gen, p.startNs, p.probe, p.shadow, countAsFailure())

proc `=destroy`*(p: Permit) {.inline.} =
  ## Records a failure if the permit goes out of scope without an outcome (E2).
  # Inlined so that the common case (outcome recorded, or no permit granted)
  # is two loads and a branch.
  if not p.done and not p.cb.isNil: recordForgotten(p)

proc `=copy`*(dst: var Permit; src: Permit) {.error: "a Permit cannot be copied".}
  ## A permit cannot be copied: each grant has exactly one outcome.
proc `=dup`*(src: Permit): Permit {.error: "a Permit cannot be copied".}
  ## A permit cannot be duplicated: each grant has exactly one outcome.

# --------------------------------------------------------------- acquire

proc grantLocked(b: BreakerPtr; gen: int; now: int64; probe, shadow: bool): Permit {.inline.} =
  Permit(cb: b, gen: gen, startNs: now, probe: probe, shadow: shadow)

proc tryRejectFast(b: BreakerPtr; s0: CircuitState; retryAfter: var int64;
                   rejState: var CircuitState): bool {.inline.} =
  ## BM3: rejections without the lock, kept out of `acquireImpl` so the common
  ## case does not pay for that proc's locals and cleanup. ForcedOpen needs no
  ## clock. For Open, the state was loaded (acquire) before the deadline, so
  ## the deadline is at least as new as the state; a rejection that races with
  ## a transition linearizes just before it.
  if not b.rejectFast.load(moAcquire): return false
  if s0 == ForcedOpen:
    discard b.rejected.fetchAdd(1, moRelaxed)
    rejState = ForcedOpen
    retryAfter = 0
    return true
  if s0 == Open:
    let until = b.openUntil.load(moRelaxed)
    when defined(linux):
      if b.cfg.clock.isNil:
        # The coarse clock is never ahead of the precise one, so far from the
        # deadline it proves the open period has not ended. The hint may be
        # longer than the truth by the coarse clock's lag (about 1 ms).
        let coarse = coarseNowNs()
        if until - coarse > coarseMarginNs:
          discard b.rejected.fetchAdd(1, moRelaxed)
          rejState = Open
          retryAfter = until - coarse
          return true
    let now = b.nowNs()
    if now < until:
      discard b.rejected.fetchAdd(1, moRelaxed)
      rejState = Open
      retryAfter = until - now
      return true

proc acquireImpl(b: BreakerPtr; permit: var Permit; retryAfter: var int64;
                 rejState: var CircuitState): bool =
  let (s0, gen0) = b.loadState()
  if s0 == Closed or s0 == Disabled:
    let start = if b.needsStart.load(moAcquire): b.nowNs() else: 0'i64
    permit = Permit(cb: b, gen: gen0, startNs: start)
    return true
  var p: Pending
  let now = b.nowNs()
  locked(b):
    var (s, gen) = b.loadState()
    if s == Open and now >= b.openUntil.load(moRelaxed):
      b.transitionLocked(HalfOpen, trOpenTimeoutElapsed, now, p)
      (s, gen) = b.loadState()
    case s
    of Closed, Disabled:
      permit = b.grantLocked(gen, now, false, false)
      result = true
    of HalfOpen:
      if b.probesInFlight < b.cfg.halfOpenMaxProbes:
        inc b.probesInFlight
        permit = b.grantLocked(gen, now, true, false)
        result = true
    of Open:
      retryAfter = b.openUntil.load(moRelaxed) - now
    of ForcedOpen:
      retryAfter = 0
    if not result:
      rejState = s
      if b.cfg.shadowMode and s != ForcedOpen:
        inc b.shadowRejected
        permit = b.grantLocked(gen, now, false, true)
        result = true
        if not b.cfg.onCall.isNil:
          p.call = CallEvent(outcome: coShadowRejected, state: s)
          p.hasCall = true
      else:
        discard b.rejected.fetchAdd(1, moRelaxed)
        if not b.cfg.onCall.isNil:
          p.call = CallEvent(outcome: coRejected, state: s)
          p.hasCall = true
  b.dispatch(p)

proc newOpenError(b: BreakerPtr; s: CircuitState; retryAfter: int64): ref CircuitOpenError =
  result = newException(CircuitOpenError,
    "circuit breaker '" & b.cfg.name & "' is " & $s & ", call rejected")
  result.breakerName = b.cfg.name
  result.state = s
  result.retryAfter = initDuration(nanoseconds = max(0'i64, retryAfter))

proc acquire*(cb: CircuitBreaker): Permit {.raises: [CircuitOpenError].} =
  ## Grants a permit or raises `CircuitOpenError` (E2, E5).
  when defined(cbDisabled):
    result = Permit(done: true)
  else:
    let b = addr cb[]
    var retryAfter = 0'i64
    var s = Closed
    let s0 = b.loadState().state
    if s0 in {Open, ForcedOpen} and b.tryRejectFast(s0, retryAfter, s):
      raise b.newOpenError(s, retryAfter)
    if not b.acquireImpl(result, retryAfter, s):
      raise b.newOpenError(s, retryAfter)

proc tryAcquire*(cb: CircuitBreaker; permit: var Permit): bool =
  ## Like `acquire`, without allocating an exception on rejection.
  when defined(cbDisabled):
    permit = Permit(done: true)
    true
  else:
    var retryAfter = 0'i64
    var s = Closed
    let b = addr cb[]
    let s0 = b.loadState().state
    if s0 in {Open, ForcedOpen} and b.tryRejectFast(s0, retryAfter, s): return false
    b.acquireImpl(permit, retryAfter, s)

# ---------------------------------------------------------------- record

proc recordCore(b: BreakerPtr; gen: int; startNs: int64; probe, shadow: bool;
                v: Verdict) {.raises: [].} =
  var p: Pending
  try:
    locked(b):
      # The clock is only read when something below needs it.
      let needNow = startNs > 0 or v.kind == vkFailure or
                    (b.window.kind == TimeWindow and b.cfg.tracksWindow)
      let now = if needNow: b.nowNs() else: 0'i64
      let elapsed = if startNs > 0: now - startNs else: 0'i64
      let slowNs = b.cfg.slowCallDuration.nanos
      let slow = slowNs > 0 and startNs > 0 and elapsed >= slowNs and v.kind != vkIgnore
      case v.kind
      of vkSuccess: discard b.successes.fetchAdd(1, moRelaxed)
      of vkFailure: inc b.failures
      of vkIgnore: inc b.ignored
      if slow: inc b.slowCalls
      if b.cfg.latencyPrecision > 0 and startNs > 0 and v.kind != vkIgnore:
        discard b.latency[latencyBucketOf(elapsed, b.cfg.latencyPrecision)]
          .fetchAdd(1, moRelaxed)
        discard b.latencySum.fetchAdd(elapsed, moRelaxed)
      let (s, curGen) = b.loadState()
      if not b.cfg.onCall.isNil:
        p.hasCall = true
        p.call = CallEvent(outcome: (case v.kind
                                     of vkSuccess: coSuccess
                                     of vkFailure: coFailure
                                     of vkIgnore: coIgnored),
                           slow: slow, elapsed: initDuration(nanoseconds = elapsed),
                           state: s)
      if shadow or gen != curGen:
        discard  # stale or shadow permit: metrics only
      else:
        case s
        of Closed:
          if v.kind != vkIgnore:
            let failed = v.kind == vkFailure
            if b.cfg.tracksWindow: b.window.add(now, failed, slow)
            b.setConsecutive(if failed: b.consecutive + 1 else: 0)
            let hint = v.openFor.nanos
            if failed and hint > 0:
              b.transitionLocked(Open, trServerHint, now, p, hint)
            elif b.cfg.policy == ConsecutiveFailures and
                 b.consecutive >= b.cfg.failureThreshold:
              b.transitionLocked(Open, trConsecutiveFailures, now, p)
            else:
              var reason: TransitionReason
              if b.rateTripLocked(now, slowNs, reason):
                # a success may trip here without having read the clock
                b.transitionLocked(Open, reason, (if needNow: now else: b.nowNs()), p)
        of HalfOpen:
          if probe:
            dec b.probesInFlight
            case v.kind
            of vkFailure:
              b.transitionLocked(Open, trProbeFailed, now, p, v.openFor.nanos)
            of vkSuccess:
              inc b.probeSuccesses
              if b.probeSuccesses >= b.cfg.successThreshold:
                b.transitionLocked(Closed, trProbeSucceeded,
                                   (if needNow: now else: b.nowNs()), p)
            of vkIgnore:
              discard
        of Open, ForcedOpen, Disabled:
          discard
    b.dispatch(p)
  except Exception:
    discard  # dispatch already contains callback errors; nothing else raises

proc sampleElapsed(b: BreakerPtr; elapsed: int64) {.inline.} =
  ## O4: one histogram sample; atomics only, callable with or without the lock.
  discard b.latency[latencyBucketOf(elapsed, b.cfg.latencyPrecision)].fetchAdd(1, moRelaxed)
  discard b.latencySum.fetchAdd(elapsed, moRelaxed)

proc tripLocked(b: BreakerPtr; reason: TransitionReason; now: int64) {.noinline.} =
  ## Rare branch of `recordSuccessLean`: callbacks are off, so the pending
  ## events are dropped instead of dispatched.
  var p: Pending
  try:
    b.transitionLocked(Open, reason, now, p)
  except Exception:
    discard

proc recordSuccessLean(b: BreakerPtr; gen: int; startNs: int64) =
  ## P2: a success that must go through the lock (sliding window, slow-call
  ## detection) when no callback is set. Same decisions as the Closed branch
  ## of `recordCore` for a success (both use `rateTripLocked`), without its
  ## event bookkeeping, which cost more than the lock itself.
  locked(b):
    let needNow = startNs > 0 or (b.window.kind == TimeWindow and b.cfg.tracksWindow)
    let now = if needNow: b.nowNs() else: 0'i64
    let elapsed = if startNs > 0: now - startNs else: 0'i64
    let slowNs = b.cfg.slowCallDuration.nanos
    let slow = slowNs > 0 and startNs > 0 and elapsed >= slowNs
    discard b.successes.fetchAdd(1, moRelaxed)
    if slow: inc b.slowCalls
    if b.cfg.latencyPrecision > 0 and startNs > 0: b.sampleElapsed(elapsed)
    let (s, curGen) = b.loadState()
    if s == Closed and gen == curGen:
      if b.cfg.tracksWindow: b.window.add(now, false, slow)
      b.setConsecutive(0)
      var reason: TransitionReason
      if b.rateTripLocked(now, slowNs, reason):
        b.tripLocked(reason, if needNow: now else: b.nowNs())

proc record*(p: var Permit; v: Verdict) =
  ## Records the outcome of the call guarded by `p`. Later calls are no-ops.
  if p.done or p.cb.isNil: return
  p.done = true
  let b = p.cb
  if v.kind == vkSuccess and not p.probe and not p.shadow and
     b.fastSuccess.load(moAcquire):
    # Lock-free hot path (P1/P2): a success in Closed only resets the
    # consecutive counter, and that needs the lock only when it is not zero.
    discard b.successes.fetchAdd(1, moRelaxed)
    if b.cfg.latencyPrecision > 0 and p.startNs > 0:
      b.sampleElapsed(b.nowNs() - p.startNs)
    if b.hasConsecutive.load(moAcquire):
      locked(b):
        let (s, gen) = b.loadState()
        if s == Closed and gen == p.gen: b.setConsecutive(0)
    return
  if v.kind == vkSuccess and not p.probe and not p.shadow and
     b.cfg.onCall.isNil and b.cfg.onTransition.isNil:
    b.recordSuccessLean(p.gen, p.startNs)
    return
  b.recordCore(p.gen, p.startNs, p.probe, p.shadow, v)

proc success*(p: var Permit) {.inline.} =
  ## Records the guarded call as a success.
  p.record(countAsSuccess())
proc failure*(p: var Permit; openFor = Duration()) {.inline.} =
  ## Records the guarded call as a failure. A positive `openFor` (for example
  ## from a `Retry-After` header) opens the circuit for that long.
  p.record(countAsFailure(openFor))
proc ignore*(p: var Permit) {.inline.} =
  ## Releases the permit without counting the call either way.
  p.record(ignoreCall())

proc recordError*(p: var Permit; e: ref CatchableError) =
  ## Records an exception, using the configured classifier (F5, F6).
  if p.done or p.cb.isNil: return
  var v = countAsFailure()
  let classify = p.cb.cfg.classifyError
  if not classify.isNil:
    try:
      v = classify(e)
    except Exception:
      discard p.cb.callbackErrors.fetchAdd(1)
  p.record(v)

proc isProbe*(p: Permit): bool {.inline.} =
  ## True when the permit is a `HalfOpen` probe: its outcome decides recovery.
  p.probe
proc isShadow*(p: Permit): bool {.inline.} =
  ## True when the call would have been rejected but shadow mode let it pass.
  p.shadow
proc isDone*(p: Permit): bool {.inline.} =
  ## True once an outcome was recorded (later records are no-ops).
  p.done

# ------------------------------------------------------- inspection / control

proc name*(cb: CircuitBreaker): string =
  ## The breaker's name, as used in errors, events and metrics.
  cb.cfg.name

proc state*(cb: CircuitBreaker): CircuitState =
  ## Current state. `Open` is reported until a call triggers `HalfOpen` (S4).
  (addr cb[]).loadState().state

proc isClosed*(cb: CircuitBreaker): bool =
  ## True in `Closed`.
  cb.state == Closed
proc isOpen*(cb: CircuitBreaker): bool =
  ## True in `Open` or `ForcedOpen`.
  cb.state in {Open, ForcedOpen}
proc isHalfOpen*(cb: CircuitBreaker): bool =
  ## True in `HalfOpen`.
  cb.state == HalfOpen

proc config*(cb: CircuitBreaker): BreakerConfig =
  ## A copy of the current configuration.
  let b = addr cb[]
  locked(b):
    result = b.cfg

proc metrics*(cb: CircuitBreaker): BreakerMetrics =
  ## Immutable snapshot (B2).
  let b = addr cb[]
  locked(b):
    let now = b.nowNs()
    let s = b.loadState().state
    result = BreakerMetrics(
      name: b.cfg.name, state: s, successes: b.successes.load(moRelaxed),
      failures: b.failures,
      ignored: b.ignored, rejected: b.rejected.load(moRelaxed), shadowRejected: b.shadowRejected,
      slowCalls: b.slowCalls, transitions: b.transitions,
      window: b.window.stats(now), consecutiveFailures: b.consecutive,
      probesInFlight: b.probesInFlight,
      currentOpenTimeout: initDuration(nanoseconds = b.currentOpenNs),
      retryAfter: (if s == Open: initDuration(nanoseconds = max(0'i64, b.openUntil.load(moRelaxed) - now))
                   else: Duration()),
      latencyPrecision: b.cfg.latencyPrecision,
      latencySumNs: b.latencySum.load(moRelaxed))
    for i in 0 ..< b.latency.len:
      let c = b.latency[i].load(moRelaxed)
      result.latencyBuckets.add c
      result.latencyCount += c
  result.callbackErrors = b.callbackErrors.load(moAcquire)

proc consecutiveFailures*(cb: CircuitBreaker): int =
  ## Failures in a row counted in `Closed`.
  let b = addr cb[]
  locked(b):
    result = b.consecutive

proc latencyQuantile*(m: BreakerMetrics; p: float): Duration =
  ## O4: the `p`-quantile of the call latency (0 < p <= 1), within 1/k relative
  ## error, where k is `latencyPrecision`. Zero when tracking is off or empty.
  initDuration(nanoseconds = latencyPercentile(m.latencyBuckets, m.latencyPrecision, p))
proc callTimeout*(cb: CircuitBreaker): Duration =
  ## T5: the per-call limit applied by the async APIs (zero: none). Read under
  ## the lock, since `reconfigure` may change it.
  let b = addr cb[]
  locked(b):
    result = b.cfg.callTimeout

proc newCallTimeoutError*(cb: CircuitBreaker; timeout: Duration): ref CallTimeoutError =
  ## The error raised by the async APIs when `timeout` is exceeded.
  result = newException(CallTimeoutError,
    "circuit breaker '" & cb.name & "': call exceeded " &
    $timeout.inMilliseconds & " ms")
  result.breakerName = cb.name
  result.timeout = timeout

proc retryAfter*(cb: CircuitBreaker): Duration =
  ## Time until the next probe while `Open`; zero in the other states.
  let b = addr cb[]
  if b.loadState().state == Open:
    result = initDuration(nanoseconds = max(0'i64, b.openUntil.load(moAcquire) - b.nowNs()))

proc explain*(cb: CircuitBreaker): seq[TransitionEvent] =
  ## Last transitions, oldest first, with reason and window statistics (B4).
  let b = addr cb[]
  locked(b):
    let n = b.history.len
    if n < b.cfg.historySize or n == 0:
      result = b.history
    else:
      for i in 0 ..< n:
        result.add b.history[(b.historyNext + i) mod n]
  for ev in result.mitems: ev.breaker = b.cfg.name

proc manualTransition(cb: CircuitBreaker; to: CircuitState) =
  let b = addr cb[]
  var p: Pending
  locked(b):
    b.transitionLocked(to, trManual, b.nowNs(), p)
  b.dispatch(p)

proc reset*(cb: CircuitBreaker) =
  ## Closes the circuit and clears counters of the window (A10).
  manualTransition(cb, Closed)
proc forceOpen*(cb: CircuitBreaker) =
  ## Rejects every call until `reset` (A10), e.g. during maintenance.
  manualTransition(cb, ForcedOpen)
proc disable*(cb: CircuitBreaker) =
  ## Lets every call through without evaluating outcomes until `reset` (A10).
  manualTransition(cb, Disabled)

const fixedAtCreation = ["name", "clock", "classifyError", "onTransition",
                         "onCall", "seed", "latencyPrecision"]
  ## Settings that `reconfigure` keeps; every other field is copied, so a new
  ## numeric setting is reconfigurable without touching `reconfigure`.

proc reconfigure*(cb: CircuitBreaker; cfg: BreakerConfig) =
  ## Atomically replaces the numeric settings (N4). `name`, `clock`,
  ## `classifyError`, `onTransition`, `onCall`, `seed` and `latencyPrecision`
  ## (the histogram is sized at creation) are kept.
  ## Changing the window shape clears the window; the state is preserved.
  validate(cfg)
  let b = addr cb[]
  locked(b):
    let windowChanged = cfg.windowKind != b.cfg.windowKind or
      cfg.windowSize != b.cfg.windowSize or cfg.windowDuration != b.cfg.windowDuration or
      cfg.windowBuckets != b.cfg.windowBuckets
    for field, dst, src in fieldPairs(b.cfg, cfg):
      when field notin fixedAtCreation and field != "historySize":
        dst = src
    if cfg.historySize != b.cfg.historySize:
      b.history.setLen(0)
      b.historyNext = 0
      b.cfg.historySize = cfg.historySize
    if windowChanged:
      b.window = newWindow(b.cfg)
      b.setConsecutive(0)
    b.updateFastFlags()
