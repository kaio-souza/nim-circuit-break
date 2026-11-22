# Equivalence with other circuit breakers

How the concepts and settings of `circuit_breaker` map to the best-known
libraries (D8, I4). "None" means the library has no equivalent, which is
different from "not needed".

Status: written 2026-11-22 from each project's documented behavior and not yet
re-checked against the current release of each; re-verify the version column
before v1.0 (plan D-6).

| Library | Language |
|---|---|
| Resilience4j `CircuitBreaker` | Java |
| Polly `CircuitBreakerStrategy` (v8) | .NET |
| `sony/gobreaker` | Go |
| `pybreaker` | Python |
| `opossum` | Node.js |

## States

| circuit_breaker | Resilience4j | Polly | gobreaker | pybreaker | opossum |
|---|---|---|---|---|---|
| `Closed` | CLOSED | Closed | StateClosed | closed | closed |
| `Open` | OPEN | Open | StateOpen | open | open |
| `HalfOpen` | HALF_OPEN | HalfOpen | StateHalfOpen | half-open | halfOpen |
| `ForcedOpen` (`forceOpen`) | FORCED_OPEN | Isolated | none | none | none |
| `Disabled` (`disable`) | DISABLED | none | none | none | none |

Transitions are lazy here: no timer moves `Open` to `HalfOpen`; the first call
after the timeout does (ADR-0004). Resilience4j has an optional automatic
transition; the others also decide on the next call.

## Settings

| circuit_breaker | Resilience4j | Polly | gobreaker | pybreaker | opossum |
|---|---|---|---|---|---|
| `failureThreshold` (consecutive) | none | none | `ReadyToTrip` on `ConsecutiveFailures` | `fail_max` | none |
| `failureRateThreshold` | `failureRateThreshold` | `FailureRatio` | `ReadyToTrip` on a computed rate | none | `errorThresholdPercentage` |
| `minimumCalls` | `minimumNumberOfCalls` | `MinimumThroughput` | in `ReadyToTrip` | none | `volumeThreshold` |
| `windowKind: CountWindow`, `windowSize` | `COUNT_BASED`, `slidingWindowSize` | none | none | none | none |
| `windowKind: TimeWindow`, `windowDuration` | `TIME_BASED` | `SamplingDuration` | `Interval` | none | `rollingCountTimeout` |
| `slowCallDuration` | `slowCallDurationThreshold` | none | none | none | none |
| `slowCallRateThreshold` | `slowCallRateThreshold` | none | none | none | none |
| `openTimeout` | `waitDurationInOpenState` | `BreakDuration` | `Timeout` | `reset_timeout` | `resetTimeout` |
| `backoffMultiplier`, `maxOpenTimeout` | `IntervalFunction` (exponential) | `BreakDurationGenerator` | none | none | none |
| `jitter` | none | none | none | none | none |
| `halfOpenMaxProbes` | `permittedNumberOfCallsInHalfOpenState` | none (one probe) | `MaxRequests` | none (one probe) | none (one probe) |
| `successThreshold` | none (probes decide by rate) | none | none | `success_threshold` | none |
| `classifyError` | `recordException` / `ignoreExceptions` | `ShouldHandle` | `IsSuccessful` | `exclude` | `errorFilter` |
| result classifier (`isFailureResult`) | `recordResultPredicate` | `ShouldHandle` on results | `IsSuccessful` | none | none |
| `callTimeout` (async) | `TimeLimiter` (separate) | `TimeoutStrategy` (separate) | none | none | `timeout` |
| server hint (`countAsFailure(openFor)`) | none | `BreakDurationGenerator` with the outcome | none | none | none |
| `shadowMode` | none | none | none | none | none |
| `onTransition` | event publisher | `OnOpened`, `OnClosed`, `OnHalfOpened` | `OnStateChange` | listeners | events |
| `metrics`, `explain`, `report` | metrics, Micrometer | telemetry | `Counts` | `fail_counter` | stats |
| `KeyedBreaker` | registry | none (one pipeline per key) | one instance per key | one instance per key | one instance per key |
| `reconfigure` | none (immutable config) | none | none | none | none |

## Behavior differences worth knowing

- **Rejection is an exception with data.** `CircuitOpenError` carries
  `retryAfter`; a rejected call is never confused with a failure of your
  function (A3, E5). `tryCall` and `callOr` offer non-throwing forms.
- **Time is monotonic and injectable.** `FakeClock` drives every time-based
  behavior in tests (T1, T6); most of the libraries above use the wall clock or
  need their own test hooks.
- **Callbacks run outside the lock** (ADR-0007) and cannot corrupt the
  breaker if they raise (O2).
- **A forgotten permit counts as a failure.** The low-level `acquire` guard
  records a failure if it goes out of scope unresolved (E2, ADR-0006).
- **No built-in retry, bulkhead or timeout for sync calls.** See
  [COMPOSITION](COMPOSITION.md). Resilience4j and Polly ship those patterns;
  here they are left to the caller on purpose (ADR-0001).

## Migrating

- gobreaker's `Settings{MaxRequests, Interval, Timeout, ReadyToTrip}` becomes
  `halfOpenMaxProbes`, `windowDuration`, `openTimeout` and a policy.
- Resilience4j's `CircuitBreakerConfig` maps field by field using the table; set
  `policy: FailureRate` and `windowKind` to match `slidingWindowType`.
- Polly's `FailureRatio` + `SamplingDuration` + `MinimumThroughput` +
  `BreakDuration` is `FailureRate` + `TimeWindow` + `minimumCalls` +
  `openTimeout`.
- pybreaker's `fail_max` and `reset_timeout` are `failureThreshold` and
  `openTimeout`.
