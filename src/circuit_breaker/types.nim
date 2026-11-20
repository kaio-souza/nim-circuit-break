## Public types shared by every module of the library.

import std/times

type
  CircuitState* = enum
    ## States of a circuit breaker.
    Closed      ## Calls pass through; outcomes are evaluated by the policy.
    Open        ## Calls are rejected until the open timeout elapses.
    HalfOpen    ## A limited number of probe calls are allowed.
    ForcedOpen  ## Administrative: every call is rejected until `reset`.
    Disabled    ## Administrative: every call passes and nothing is evaluated.

  PolicyKind* = enum
    ## How `Closed` decides to open.
    ConsecutiveFailures  ## Opens after `failureThreshold` failures in a row.
    FailureRate          ## Opens when the failure rate of the window crosses a threshold.

  WindowKind* = enum
    ## Shape of the sliding window used by the rate policies.
    CountWindow  ## The last `windowSize` calls.
    TimeWindow   ## Calls of the last `windowDuration`, split in `windowBuckets`.

  VerdictKind* = enum
    ## How a call outcome counts.
    vkSuccess  ## Counts as a success.
    vkFailure  ## Counts as a failure.
    vkIgnore   ## Not counted (e.g. a caller error).

  Verdict* = object
    ## How a call outcome must be counted.
    kind*: VerdictKind
    openFor*: Duration  ## Only for failures: server hint (e.g. `Retry-After`). Zero means none.

  TransitionReason* = enum
    ## Why a transition happened; `$` gives a readable text.
    trConsecutiveFailures = "consecutive failure threshold reached"
    trFailureRate = "failure rate threshold reached"
    trSlowCallRate = "slow call rate threshold reached"
    trServerHint = "failure carried a retry-after hint"
    trOpenTimeoutElapsed = "open timeout elapsed"
    trProbeSucceeded = "probe calls succeeded"
    trProbeFailed = "probe call failed"
    trManual = "manual operation"

  WindowStats* = object
    ## Snapshot of the sliding window.
    calls*: int
    failures*: int
    slowCalls*: int
    failureRate*: float  ## 0.0 .. 1.0
    slowCallRate*: float ## 0.0 .. 1.0

  TransitionEvent* = object
    ## Passed to `onTransition` and kept by `explain`.
    breaker*: string
    fromState*: CircuitState
    toState*: CircuitState
    reason*: TransitionReason
    stats*: WindowStats         ## Window statistics at the moment of the transition.
    consecutiveFailures*: int
    openFor*: Duration          ## Length of the open period when `toState` is `Open`.
    atNanos*: int64             ## Monotonic timestamp (nanoseconds).

  CallOutcome* = enum
    ## Outcome reported to `onCall`.
    coSuccess         ## Ran and counted as a success.
    coFailure         ## Ran and counted as a failure.
    coIgnored         ## Ran and was not counted.
    coRejected        ## Rejected by the breaker.
    coShadowRejected  ## Would have been rejected; let through by shadow mode.

  CallEvent* = object
    ## Passed to `onCall` after every call or rejection.
    breaker*: string
    outcome*: CallOutcome
    slow*: bool
    elapsed*: Duration  ## Zero for rejections.
    state*: CircuitState

  CircuitOpenError* = object of CatchableError
    ## Raised when a call is rejected. Never raised for failures of the
    ## protected function: those propagate unchanged.
    breakerName*: string
    state*: CircuitState
    retryAfter*: Duration  ## Time until the next probe is allowed (zero if unknown).

  Clock* = proc(): int64 {.gcsafe, raises: [].}
    ## Monotonic time source in nanoseconds.
  ErrorClassifier* = proc(e: ref CatchableError): Verdict
    ## Decides how an exception raised by the call counts (F5).
  TransitionCallback* = proc(e: TransitionEvent)
    ## Called outside the lock after each transition (ADR-0007).
  CallCallback* = proc(e: CallEvent)
    ## Called outside the lock after each call; makes every success take the
    ## general path, so it costs more than a plain call.

  BreakerConfig* = object
    ## Configuration. Build with `initBreakerConfig`; validated by `newCircuitBreaker`.
    ## `name`, `clock`, `classifyError`, `onTransition`, `onCall`, `seed` and
    ## `latencyPrecision` are fixed at creation; `reconfigure` changes only the
    ## other numeric settings.
    name*: string
    policy*: PolicyKind
    failureThreshold*: int
    failureRateThreshold*: float
    minimumCalls*: int
    windowKind*: WindowKind
    windowSize*: int
    windowDuration*: Duration
    windowBuckets*: int
    slowCallDuration*: Duration       ## Zero disables slow call detection.
    slowCallRateThreshold*: float
    openTimeout*: Duration
    backoffMultiplier*: float         ## 1.0 disables backoff.
    maxOpenTimeout*: Duration
    jitter*: float                    ## 0.0 .. 1.0, fraction added on top of the open timeout.
    halfOpenMaxProbes*: int
    successThreshold*: int
    shadowMode*: bool                 ## Evaluate but never reject.
    historySize*: int                 ## Transitions kept for `explain`.
    latencyPrecision*: int            ## O4: sub-buckets per octave, 1..8; 0 disables latency tracking.
    classifyError*: ErrorClassifier
    onTransition*: TransitionCallback
    onCall*: CallCallback
    clock*: Clock
    seed*: int64                      ## Jitter seed; 0 picks one from the clock.

  BreakerMetrics* = object
    ## Immutable snapshot returned by `metrics` (B2).
    name*: string
    state*: CircuitState
    successes*: int64
    failures*: int64
    ignored*: int64
    rejected*: int64
    shadowRejected*: int64
    slowCalls*: int64
    transitions*: int64
    callbackErrors*: int64
    window*: WindowStats
    consecutiveFailures*: int
    probesInFlight*: int
    currentOpenTimeout*: Duration  ## Open period currently in effect (with backoff).
    retryAfter*: Duration          ## Time until the next probe when Open.
    latencyPrecision*: int         ## 0 when latency tracking is off.
    latencyCount*: int64           ## Samples in the latency histogram.
    latencyBuckets*: seq[int64]    ## Histogram counts; see `latencyPercentile`.
    latencySumNs*: int64          ## Sum of the sampled latencies.

proc countAsSuccess*(): Verdict {.inline.} =
  ## Verdict: the call counts as a success.
  Verdict(kind: vkSuccess)
proc countAsFailure*(openFor = Duration()): Verdict {.inline.} =
  ## Verdict: the call counts as a failure; a positive `openFor` opens the
  ## circuit for that long (server hint).
  Verdict(kind: vkFailure, openFor: openFor)
proc ignoreCall*(): Verdict {.inline.} =
  ## Verdict: the call is not counted.
  Verdict(kind: vkIgnore)

proc initBreakerConfig*(
    name = "default",
    policy = ConsecutiveFailures,
    failureThreshold = 5,
    failureRateThreshold = 0.5,
    minimumCalls = 10,
    windowKind = CountWindow,
    windowSize = 100,
    windowDuration = initDuration(seconds = 60),
    windowBuckets = 10,
    slowCallDuration = Duration(),
    slowCallRateThreshold = 1.0,
    openTimeout = initDuration(seconds = 30),
    backoffMultiplier = 1.0,
    maxOpenTimeout = initDuration(minutes = 5),
    jitter = 0.0,
    halfOpenMaxProbes = 1,
    successThreshold = 1,
    shadowMode = false,
    historySize = 32,
    latencyPrecision = 0,
    classifyError: ErrorClassifier = nil,
    onTransition: TransitionCallback = nil,
    onCall: CallCallback = nil,
    clock: Clock = nil,
    seed = 0'i64
): BreakerConfig =
  ## Builds a configuration with documented defaults (K1).
  BreakerConfig(
    name: name, policy: policy, failureThreshold: failureThreshold,
    failureRateThreshold: failureRateThreshold, minimumCalls: minimumCalls,
    windowKind: windowKind, windowSize: windowSize, windowDuration: windowDuration,
    windowBuckets: windowBuckets, slowCallDuration: slowCallDuration,
    slowCallRateThreshold: slowCallRateThreshold, openTimeout: openTimeout,
    backoffMultiplier: backoffMultiplier, maxOpenTimeout: maxOpenTimeout,
    jitter: jitter, halfOpenMaxProbes: halfOpenMaxProbes,
    successThreshold: successThreshold, shadowMode: shadowMode,
    historySize: historySize, latencyPrecision: latencyPrecision,
    classifyError: classifyError,
    onTransition: onTransition, onCall: onCall, clock: clock, seed: seed)

proc validate*(c: BreakerConfig) {.raises: [ValueError].} =
  ## Raises `ValueError` describing the first invalid setting (K2).
  template req(cond: bool; msg: string) =
    if not cond: raise newException(ValueError, "invalid circuit breaker config: " & msg)
  req c.failureThreshold >= 1, "failureThreshold must be >= 1"
  req c.failureRateThreshold > 0.0 and c.failureRateThreshold <= 1.0,
    "failureRateThreshold must be in (0, 1]"
  req c.minimumCalls >= 1, "minimumCalls must be >= 1"
  req c.windowSize >= 1, "windowSize must be >= 1"
  req c.windowBuckets >= 1, "windowBuckets must be >= 1"
  req c.windowDuration.inNanoseconds >= c.windowBuckets,
    "windowDuration must be at least windowBuckets nanoseconds"
  req c.slowCallDuration.inNanoseconds >= 0, "slowCallDuration must be >= 0"
  req c.slowCallRateThreshold > 0.0 and c.slowCallRateThreshold <= 1.0,
    "slowCallRateThreshold must be in (0, 1]"
  req c.openTimeout.inNanoseconds > 0, "openTimeout must be > 0"
  req c.backoffMultiplier >= 1.0, "backoffMultiplier must be >= 1.0"
  req c.maxOpenTimeout >= c.openTimeout, "maxOpenTimeout must be >= openTimeout"
  req c.jitter >= 0.0 and c.jitter <= 1.0, "jitter must be in [0, 1]"
  req c.halfOpenMaxProbes >= 1, "halfOpenMaxProbes must be >= 1"
  req c.successThreshold >= 1, "successThreshold must be >= 1"
  req c.historySize >= 0, "historySize must be >= 0"
  req c.latencyPrecision >= 0 and c.latencyPrecision <= 8,
    "latencyPrecision must be in 0..8"
  if c.policy == FailureRate and c.windowKind == CountWindow:
    req c.minimumCalls <= c.windowSize,
      "minimumCalls must be <= windowSize, otherwise the rate is never evaluated"

proc diagnose*(c: BreakerConfig): seq[string] =
  ## Warnings about valid but risky combinations (N8). Empty when nothing stands out.
  if c.policy == ConsecutiveFailures and c.failureThreshold == 1:
    result.add "failureThreshold = 1 opens the circuit on any single failure"
  if c.policy == FailureRate and c.minimumCalls < 5:
    result.add "minimumCalls < 5 makes the failure rate very noisy"
  if c.slowCallDuration.inNanoseconds > 0 and c.slowCallDuration >= c.openTimeout:
    result.add "slowCallDuration >= openTimeout: a single slow call outlasts the open period"
  if c.jitter > 0.5:
    result.add "jitter > 0.5 makes the open period highly unpredictable"
  if c.successThreshold > c.halfOpenMaxProbes:
    result.add "successThreshold > halfOpenMaxProbes: recovery needs several probe rounds"
  if c.backoffMultiplier > 1.0 and c.maxOpenTimeout == c.openTimeout:
    result.add "backoffMultiplier has no effect because maxOpenTimeout == openTimeout"
  if c.shadowMode:
    result.add "shadowMode is on: the breaker never rejects calls"
