# Tuning guide

How to choose each setting of `BreakerConfig`, and the mistakes that make a
breaker useless. Each recommendation names the test or the check that backs
it. Defaults are in [`types.nim`](../src/circuit_breaker/types.nim) (K1);
`diagnose(config)` returns warnings for the risky combinations below (N8), and
`newCircuitBreaker` rejects the invalid ones (K2).

Start from the defaults and change one setting at a time. Use `explain` and
`report` to see why the circuit opened before you tune anything.

## Which policy

| Situation | Policy | Why |
|---|---|---|
| Low or bursty traffic, a hard-down dependency | `ConsecutiveFailures` (default) | Needs no minimum volume; `t_transitions` F1 |
| Steady traffic, a dependency that fails partially | `FailureRate` | Ignores isolated errors; opens when a fraction fails (`t_policies` F2) |
| Slowness is the failure mode | `FailureRate` + `slowCallDuration` | Slow calls open the circuit even when they succeed (`t_policies` F4) |

The consecutive policy is also the fastest path (lock-free success,
ADR-0015, BM1). Choose the rate policy for correctness of the signal, not
for speed.

## failureThreshold (consecutive policy)

- Roughly the number of failures you can tolerate in a row before you prefer
  to fail fast: 3 to 10 for a typical service call.
- **Threshold 1 is a trap**: one transient error opens the circuit. `diagnose`
  warns about it (`t_api` N8).
- Too high a threshold delays protection: at 100 req/s a threshold of 50
  means half a second of failing calls before the first rejection.

## Rate policy: failureRateThreshold, minimumCalls, window

- `failureRateThreshold` 0.5 is a sound start. Lower it for dependencies where
  a 20% error rate already hurts users.
- `minimumCalls` is the evidence you need before judging. Below about 5 the
  rate is noise (`diagnose` warns). Pick it so that it is reached within a few
  seconds at your normal traffic; at low traffic the circuit never opens.
- **A count window smaller than `minimumCalls` never evaluates**: the config is
  rejected at creation (`t_api` K2).
- `CountWindow` (`windowSize` calls) adapts to traffic; `TimeWindow`
  (`windowDuration`, `windowBuckets`) forgets by age, so a quiet dependency does
  not stay judged by calls from an hour ago (`t_policies` F2, F3). Use the time
  window when traffic varies a lot. Buckets trade precision for memory; 10 is
  enough.

## slowCallDuration and slowCallRateThreshold

- Set `slowCallDuration` to the latency above which a response is as bad as
  an error for your callers: slightly above your p99 under normal load.
- `slowCallRateThreshold` is the fraction of slow calls that opens the circuit
  (default 1.0: only when every call in the window is slow). Lower it (0.8) to
  react earlier.
- **Keep `slowCallDuration` well below `openTimeout`.** A single slow call
  that lasts longer than the open period makes no sense; `diagnose` warns.
- Slow-call detection reads the clock twice per call (BM1: about 107 ns versus
  31 ns). Leave it off (zero) where the dependency never gets slow.

## openTimeout, backoff and jitter

- `openTimeout` is how long to give the dependency to recover before probing.
  Match it to the dependency's real recovery time: 5 to 30 s for a service
  restart, longer for a failover.
- `backoffMultiplier` above 1.0 lengthens the period after each failed probe,
  up to `maxOpenTimeout` (`t_transitions` T3). `maxOpenTimeout` equal to
  `openTimeout` makes the multiplier useless; `diagnose` warns.
- `jitter` (fraction added on top) keeps many instances from probing together
  after a shared outage (`t_transitions` T4: it only delays, never earlier).
  0.1 to 0.3 is plenty; above 0.5 the period becomes unpredictable.
- A server that says when to come back (HTTP 429/503 with `Retry-After`):
  return `countAsFailure(openFor = ...)` from the classifier. The hint wins over
  the configured period (`t_policies` G5).

## halfOpenMaxProbes and successThreshold

- `halfOpenMaxProbes` caps concurrent probes (`t_transitions` S7). Keep it at 1
  for fragile dependencies; raise it when a single probe says little (many
  backends behind one name).
- `successThreshold` is how many probe successes close the circuit
  (`t_transitions` S8). Above 1 you demand more evidence. If it exceeds
  `halfOpenMaxProbes`, recovery needs several probe rounds; `diagnose` warns.

## What counts as a failure

- Return `ignoreCall()` for errors that are the caller's fault (HTTP 4xx,
  validation): they say nothing about the dependency (`t_policies` F5, F6).
- Use the result classifier for failures that do not raise, such as an HTTP 503
  that is returned (`t_policies` F7).
- `Defect`s are never counted and propagate (`t_policies` F8).
- With Chronos, a cancelled call is ignored by default (`onCancel`), so a
  caller giving up does not open the circuit.

## Latency tracking

`latencyPrecision` 1..8 sub-buckets per octave: 4 is a good start, with 80 ns
per call (BM10); higher values only refine the percentile estimate. 0 turns it
off and costs nothing.

## Common pitfalls

1. **Retry inside the breaker.** Each retry becomes a separate failure and the
   circuit opens from one logical call. Retry outside, and stop on
   `CircuitOpenError` ([COMPOSITION](COMPOSITION.md)).
2. **A timeout that is not raised.** A client timeout must surface as an
   exception (or through the result classifier) to count. Sync calls cannot be
   interrupted: rely on the dependency's own timeout. For async code use
   `callTimeout` (T5, ADR-0016).
3. **One breaker for many dependencies.** One bad host opens the circuit for all
   of them. Use `KeyedBreaker` per host, endpoint or tenant (ADR-0011).
4. **Shadow mode left on.** The breaker never rejects; `diagnose` warns. Use it
   to size thresholds against real traffic, then turn it off (N1).
5. **Tuning without the test clock.** Test time-based settings with
   `FakeClock`: no `sleep`, no flakiness (`t_api` V1/N9/T6).
6. **Swallowing `CircuitOpenError`.** It carries `retryAfter`; use it for the
   `Retry-After` header or for your own scheduling.
