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
    Success  ## Counts as a success.
    Failure  ## Counts as a failure.
    Ignore   ## Not counted (e.g. a caller error).

  Verdict* = object
    ## How a call outcome must be counted.
    kind*: VerdictKind
    openFor*: Duration  ## Only for failures: server hint (e.g. `Retry-After`). Zero means none.

  TransitionReason* = enum
    ## Why a transition happened; `$` gives a readable text.
    FailureThresholdReached = "consecutive failure threshold reached"
    FailureRateReached = "failure rate threshold reached"
    SlowCallRateReached = "slow call rate threshold reached"
    ServerHint = "failure carried a retry-after hint"
    OpenTimeoutElapsed = "open timeout elapsed"
    ProbeSucceeded = "probe calls succeeded"
    ProbeFailed = "probe call failed"
    Manual = "manual operation"

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
    Succeeded       ## Ran and counted as a success.
    Failed          ## Ran and counted as a failure.
    Ignored         ## Ran and was not counted.
    Rejected        ## Rejected by the breaker.
    ShadowRejected  ## Would have been rejected; let through by shadow mode.

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

  CallTimeoutError* = object of CatchableError
    ## Raised by the async APIs when a call exceeds `callTimeout` (T5). The
    ## call counts as a failure.
    breakerName*: string
    timeout*: Duration

  Clock* = proc(): int64 {.gcsafe, raises: [].}
    ## Monotonic time source in nanoseconds.
  ErrorClassifier* = proc(e: ref CatchableError): Verdict {.gcsafe.}
    ## Decides how an exception raised by the call counts (F5). Runs on the
    ## thread that made the call, so it must be `gcsafe`.
  TransitionCallback* = proc(e: TransitionEvent) {.gcsafe.}
    ## Called outside the lock after each transition (ADR-0007), on whichever
    ## thread caused it, so it must be `gcsafe`.
  CallCallback* = proc(e: CallEvent) {.gcsafe.}
    ## Called outside the lock after each call, on the calling thread (must be
    ## `gcsafe`); makes every success take the general path, so it costs more
    ## than a plain call.

  BreakerConfig* = object
    ## Configuration, validated by `newCircuitBreaker`. Every field has a
    ## documented default (K1), so set only what differs:
    ## `BreakerConfig(name: "payments", failureThreshold: 3)`.
    ## `name`, `clock`, `classifyError`, `onTransition`, `onCall`, `seed` and
    ## `latencyPrecision` are fixed at creation; `reconfigure` changes only the
    ## other numeric settings.
    name*: string = "default"
    policy*: PolicyKind = ConsecutiveFailures
    failureThreshold*: int = 5
    failureRateThreshold*: float = 0.5
    minimumCalls*: int = 10
    windowKind*: WindowKind = CountWindow
    windowSize*: int = 100
    windowDuration*: Duration = initDuration(seconds = 60)
    windowBuckets*: int = 10
    slowCallDuration*: Duration       ## Zero disables slow call detection.
    callTimeout*: Duration            ## T5: per-call limit for the async APIs; zero disables it.
                                      ## Sync calls cannot be interrupted and ignore it.
    slowCallRateThreshold*: float = 1.0
    openTimeout*: Duration = initDuration(seconds = 30)
    backoffMultiplier*: float = 1.0   ## 1.0 disables backoff.
    maxOpenTimeout*: Duration = initDuration(minutes = 5)
    jitter*: float                    ## 0.0 .. 1.0, fraction added on top of the open timeout.
    halfOpenMaxProbes*: int = 1
    successThreshold*: int = 1
    shadowMode*: bool                 ## Evaluate but never reject.
    historySize*: int = 32            ## Transitions kept for `explain`.
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
  Verdict(kind: Success)
proc countAsFailure*(openFor = Duration()): Verdict {.inline.} =
  ## Verdict: the call counts as a failure; a positive `openFor` opens the
  ## circuit for that long (server hint).
  Verdict(kind: Failure, openFor: openFor)
proc ignoreCall*(): Verdict {.inline.} =
  ## Verdict: the call is not counted.
  Verdict(kind: Ignore)

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
  req c.callTimeout.inNanoseconds >= 0, "callTimeout must be >= 0"
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
