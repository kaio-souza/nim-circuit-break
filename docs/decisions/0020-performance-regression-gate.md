# ADR-0020: Performance regression gate

- Status: Accepted
- Date: 2026-11-22
- Requirements: R4, P7, EV2, EV6 (replaces the "informational" stance of ADR-0013)

## Context

ADR-0013 left the benchmark workflow informational because a fixed timing
limit on shared runners gives false positives: single runs vary by 2x. v1.0
needs a gate that still catches a real slowdown.

## Decision

`nimble benchcheck` (`scripts/benchcheck.nim`), run on every pull request
(`.github/workflows/benchcheck.yml`):

- **Same job, interleaved.** The merge base (`git archive`, its own
  `benchmarks/` and `src/`) and the change are built side by side and run
  alternately for 8 rounds; the order flips every round. Machine drift hits
  both sides.
- **Statistic.** Per benchmark and round, ratio = change / base of the median
  ns/op. The gate fails when the **median** of the 8 ratios exceeds
  `1 + limit` (default 0.25) **and the minimum is above 1.0** (no round was
  faster than the base). A noisy round moves the minimum or maximum, not the
  median; a real slowdown moves every round.
- **Allocations.** Deterministic: the suite is built with ARC and
  `-d:nimAllocStats` and every benchmark listed in
  `benchmarks/zero_alloc.txt` must stay under 0.001 allocations per
  operation (the harness itself makes a handful per run).
- **Single-threaded suites only** (`b_core`, `b_window`, `b_keyed`). The
  thread, async and Chronos benchmarks depend on scheduling and stay
  informational (`bench.yml`).
- Baselines change only through an explicit PR: `zero_alloc.txt` is
  versioned, and the base is always the PR's merge base.

## Calibration

Measured 2026-11-22 on the development machine (shared laptop, Nim 2.2.4):

- **A/A** (the same commit against itself, 8 rounds, 27 benchmarks): no
  benchmark failed. Medians stayed between 0.44 and 1.11; single rounds
  ranged from 0.41x to 2.3x, which is why the minimum alone cannot be the
  statistic. Time-window benchmarks showed a median near 0.5 in this run, a
  bimodal machine effect that is below the limit and so is ignored.
- **Planted slowdown** (a 60-iteration loop in `call`, 4 rounds): the gate
  failed `BM1 call (Closed, success)` with a median ratio of 6.8x, plus five
  more benchmarks, and exited non-zero. Reverted afterwards.
- The 0.25 limit has not been calibrated on GitHub's runners yet. Run the
  workflow with `aa: true` (workflow_dispatch) a few times and move the limit
  if the A/A medians leave the 0.75 to 1.25 band.

## Consequences

- A gate failure can be a false positive on a very noisy runner: rerun the job.
  A slowdown below the limit is not caught; review still covers it.
- A PR that makes a benchmark allocate must either fix it or remove the line
  from `zero_alloc.txt` explicitly, which a reviewer sees.
- The job takes about 5 minutes on the development machine.

## Evidence

`nimble benchcheck`; A/A and planted-slowdown runs above.
