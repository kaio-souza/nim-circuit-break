## Circuit breaker state machine.
##
## Concurrency model (C1): with `--threads:on` the breaker is thread-safe.
## The state and its generation live in one atomic word, so the hot path in
## `Closed` takes no lock to grant a call; recording an outcome and every
## transition take a short lock. Callbacks run outside the lock.
## A `CircuitBreaker` must outlive the permits it grants, so in multi-threaded
## code keep it in a global or another long-lived owner.

import std/[times, monotimes, atomics, random, locks, math, strutils, strformat]
import types, window

export types

const threadsOn = compileOption("threads")

type
  CircuitBreakerObj = object
    packed: Atomic[int]       # (generation shl 3) or ord(state)
    needsStart: Atomic[bool]  # whether permits must read the clock on grant
    fastSuccess: Atomic[bool] # successes in Closed can skip the lock
    hasConsecutive: Atomic[bool] # mirror of `consecutive > 0`
    successes: Atomic[int64]
    callbackErrors: Atomic[int]
    lock: Lock
    cfg: BreakerConfig
    window: SlidingWindow
    consecutive: int
    openUntil: int64
    openLevel: int
    currentOpenNs: int64
    probesInFlight: int
    probeSuccesses: int
    rng: Rand
    failures, ignored, rejected, shadowRejected, slowCalls, transitions: int64
    history: seq[TransitionEvent]
    historyNext: int

  CircuitBreaker* = ref CircuitBreakerObj
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

# ---------------------------------------------------------------- helpers

template locked(b: BreakerPtr; body: untyped) =
  when threadsOn:
    acquire(b.lock)
    try:
      body
    finally:
      release(b.lock)
  else:
    body

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
  b.needsStart.store(b.cfg.slowCallDuration.nanos > 0 or not b.cfg.onCall.isNil,
                     moRelease)
  b.fastSuccess.store(not b.cfg.tracksWindow and b.cfg.onCall.isNil, moRelease)

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
  when threadsOn: initLock(b.lock)
  b.window = newWindow(cfg)
  b.rng = initRand(if cfg.seed != 0: cfg.seed else: getMonoTime().ticks)
  b.currentOpenNs = cfg.openTimeout.nanos
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
    b.openUntil = now + t
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

proc `=destroy`*(p: Permit) =
  if not p.done and not p.cb.isNil:
    p.cb.recordCore(p.gen, p.startNs, p.probe, p.shadow, countAsFailure())

proc `=copy`*(dst: var Permit; src: Permit) {.error: "a Permit cannot be copied".}
proc `=dup`*(src: Permit): Permit {.error: "a Permit cannot be copied".}

# --------------------------------------------------------------- acquire

proc grantLocked(b: BreakerPtr; gen: int; now: int64; probe, shadow: bool): Permit {.inline.} =
  Permit(cb: b, gen: gen, startNs: now, probe: probe, shadow: shadow)

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
    if s == Open and now >= b.openUntil:
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
      retryAfter = b.openUntil - now
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
        inc b.rejected
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
    (addr cb[]).acquireImpl(permit, retryAfter, s)

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
              let st = b.window.stats(now)
              if st.calls >= b.cfg.minimumCalls:
                if b.cfg.policy == FailureRate and
                   st.failureRate >= b.cfg.failureRateThreshold:
                  b.transitionLocked(Open, trFailureRate, now, p)
                elif slowNs > 0 and st.slowCallRate >= b.cfg.slowCallRateThreshold:
                  b.transitionLocked(Open, trSlowCallRate, now, p)
        of HalfOpen:
          if probe:
            dec b.probesInFlight
            case v.kind
            of vkFailure:
              b.transitionLocked(Open, trProbeFailed, now, p, v.openFor.nanos)
            of vkSuccess:
              inc b.probeSuccesses
              if b.probeSuccesses >= b.cfg.successThreshold:
                b.transitionLocked(Closed, trProbeSucceeded, now, p)
            of vkIgnore:
              discard
        of Open, ForcedOpen, Disabled:
          discard
    b.dispatch(p)
  except Exception:
    discard  # dispatch already contains callback errors; nothing else raises

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
    if b.hasConsecutive.load(moAcquire):
      locked(b):
        let (s, gen) = b.loadState()
        if s == Closed and gen == p.gen: b.setConsecutive(0)
    return
  b.recordCore(p.gen, p.startNs, p.probe, p.shadow, v)

proc success*(p: var Permit) {.inline.} = p.record(countAsSuccess())
proc failure*(p: var Permit; openFor = Duration()) {.inline.} =
  p.record(countAsFailure(openFor))
proc ignore*(p: var Permit) {.inline.} = p.record(ignoreCall())

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

proc isProbe*(p: Permit): bool {.inline.} = p.probe
proc isShadow*(p: Permit): bool {.inline.} =
  ## True when the call would have been rejected but shadow mode let it pass.
  p.shadow
proc isDone*(p: Permit): bool {.inline.} = p.done

# -------------------------------------------------------------- call API

proc call*[T](cb: CircuitBreaker; fn: proc(): T): T =
  ## Runs `fn` under the breaker (E1). Raises `CircuitOpenError` when rejected;
  ## failures of `fn` propagate unchanged (A1, A2). `Defect`s propagate and
  ## are not counted (F8).
  when defined(cbDisabled):
    when T is void: fn() else: return fn()
  else:
    var p = acquire(cb)
    try:
      when T is void:
        fn()
      else:
        result = fn()
    except CatchableError as e:
      p.recordError(e)
      raise
    except Defect:
      p.ignore()
      raise
    p.success()

proc call*(cb: CircuitBreaker; fn: proc()) =
  ## `call` for procs without a return value (A4).
  call[void](cb, fn)

proc call*[T](cb: CircuitBreaker; fn: proc(): T; isFailureResult: proc(x: T): bool): T =
  ## Like `call`, but a returned value can also count as a failure (F7).
  ## The value is still returned to the caller.
  when defined(cbDisabled):
    return fn()
  else:
    var p = acquire(cb)
    try:
      result = fn()
    except CatchableError as e:
      p.recordError(e)
      raise
    except Defect:
      p.ignore()
      raise
    if isFailureResult(result): p.failure() else: p.success()

type
  CallResultKind* = enum
    crOk, crRejected, crFailed

  CallResult*[T] = object
    ## Explicit result of `tryCall` (A3).
    kind*: CallResultKind
    when T isnot void:
      value*: T
    rejection*: ref CircuitOpenError
    error*: ref CatchableError

proc isOk*[T](r: CallResult[T]): bool {.inline.} = r.kind == crOk

proc tryCall*[T](cb: CircuitBreaker; fn: proc(): T): CallResult[T] =
  ## Never raises `CatchableError`: the outcome is in the result.
  try:
    when T is void:
      cb.call(fn)
    else:
      result.value = cb.call(fn)
    result.kind = crOk
  except CircuitOpenError as e:
    result.kind = crRejected
    result.rejection = e
  except CatchableError as e:
    result.kind = crFailed
    result.error = e

proc tryCall*(cb: CircuitBreaker; fn: proc()): CallResult[void] =
  tryCall[void](cb, fn)

proc callOr*[T](cb: CircuitBreaker; fn: proc(): T;
                fallback: proc(e: ref CatchableError): T): T =
  ## Runs `fallback` when the call is rejected or fails (A6). The fallback
  ## receives the `CircuitOpenError` or the original exception.
  try:
    when T is void:
      cb.call(fn)
    else:
      result = cb.call(fn)
  except CatchableError as e:
    when T is void:
      fallback(e)
    else:
      result = fallback(e)

proc callOr*(cb: CircuitBreaker; fn: proc(); fallback: proc(e: ref CatchableError)) =
  callOr[void](cb, fn, fallback)

template withBreaker*(cb: CircuitBreaker; body: untyped) =
  ## Runs `body` under the breaker without allocating a closure (E3).
  ## Leaving `body` normally, or through `return`/`break`, counts as success.
  when defined(cbDisabled):
    body
  else:
    var permit = acquire(cb)
    try:
      body
    except CatchableError as e:
      permit.recordError(e)
      raise
    except Defect:
      permit.ignore()
      raise
    finally:
      if not permit.isDone: permit.success()

# ------------------------------------------------------- inspection / control

proc name*(cb: CircuitBreaker): string = cb.cfg.name

proc state*(cb: CircuitBreaker): CircuitState =
  ## Current state. `Open` is reported until a call triggers `HalfOpen` (S4).
  (addr cb[]).loadState().state

proc isClosed*(cb: CircuitBreaker): bool = cb.state == Closed
proc isOpen*(cb: CircuitBreaker): bool = cb.state in {Open, ForcedOpen}
proc isHalfOpen*(cb: CircuitBreaker): bool = cb.state == HalfOpen

proc config*(cb: CircuitBreaker): BreakerConfig =
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
      ignored: b.ignored, rejected: b.rejected, shadowRejected: b.shadowRejected,
      slowCalls: b.slowCalls, transitions: b.transitions,
      window: b.window.stats(now), consecutiveFailures: b.consecutive,
      probesInFlight: b.probesInFlight,
      currentOpenTimeout: initDuration(nanoseconds = b.currentOpenNs),
      retryAfter: (if s == Open: initDuration(nanoseconds = max(0'i64, b.openUntil - now))
                   else: Duration()))
  result.callbackErrors = b.callbackErrors.load(moAcquire)

proc consecutiveFailures*(cb: CircuitBreaker): int = cb.metrics.consecutiveFailures
proc retryAfter*(cb: CircuitBreaker): Duration = cb.metrics.retryAfter

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
proc forceOpen*(cb: CircuitBreaker) = manualTransition(cb, ForcedOpen)
proc disable*(cb: CircuitBreaker) = manualTransition(cb, Disabled)

proc reconfigure*(cb: CircuitBreaker; cfg: BreakerConfig) =
  ## Atomically replaces the numeric settings (N4). `name`, `clock`,
  ## `classifyError`, `onTransition`, `onCall` and `seed` are kept.
  ## Changing the window shape clears the window; the state is preserved.
  validate(cfg)
  let b = addr cb[]
  locked(b):
    let windowChanged = cfg.windowKind != b.cfg.windowKind or
      cfg.windowSize != b.cfg.windowSize or cfg.windowDuration != b.cfg.windowDuration or
      cfg.windowBuckets != b.cfg.windowBuckets
    b.cfg.policy = cfg.policy
    b.cfg.failureThreshold = cfg.failureThreshold
    b.cfg.failureRateThreshold = cfg.failureRateThreshold
    b.cfg.minimumCalls = cfg.minimumCalls
    b.cfg.windowKind = cfg.windowKind
    b.cfg.windowSize = cfg.windowSize
    b.cfg.windowDuration = cfg.windowDuration
    b.cfg.windowBuckets = cfg.windowBuckets
    b.cfg.slowCallDuration = cfg.slowCallDuration
    b.cfg.slowCallRateThreshold = cfg.slowCallRateThreshold
    b.cfg.openTimeout = cfg.openTimeout
    b.cfg.backoffMultiplier = cfg.backoffMultiplier
    b.cfg.maxOpenTimeout = cfg.maxOpenTimeout
    b.cfg.jitter = cfg.jitter
    b.cfg.halfOpenMaxProbes = cfg.halfOpenMaxProbes
    b.cfg.successThreshold = cfg.successThreshold
    b.cfg.shadowMode = cfg.shadowMode
    if cfg.historySize != b.cfg.historySize:
      b.history.setLen(0)
      b.historyNext = 0
      b.cfg.historySize = cfg.historySize
    if windowChanged:
      b.window = newWindow(b.cfg)
      b.setConsecutive(0)
    b.updateFastFlags()

proc fmtDur(d: Duration): string =
  let ms = d.inMilliseconds
  if ms >= 1000: &"{ms.float / 1000.0:.1f}s" else: &"{ms}ms"

proc report*(cb: CircuitBreaker): string =
  ## Human-readable one-block summary for terminals and logs (N10).
  let m = cb.metrics
  result = &"circuit breaker '{m.name}': {m.state}\n" &
    &"  window: {m.window.calls} calls, failure rate {m.window.failureRate * 100:.1f}%, " &
    &"slow rate {m.window.slowCallRate * 100:.1f}%\n" &
    &"  consecutive failures: {m.consecutiveFailures}\n" &
    &"  totals: {m.successes} ok, {m.failures} failed, {m.ignored} ignored, " &
    &"{m.rejected} rejected, {m.shadowRejected} shadow-rejected, {m.slowCalls} slow\n" &
    &"  transitions: {m.transitions}, callback errors: {m.callbackErrors}"
  if m.state == Open:
    result &= &"\n  next probe in: {fmtDur(m.retryAfter)} (open period {fmtDur(m.currentOpenTimeout)})"
  let h = cb.explain
  if h.len > 0:
    let last = h[^1]
    result &= &"\n  last transition: {last.fromState} -> {last.toState} ({last.reason})"
  result = result.strip(leading = false)
