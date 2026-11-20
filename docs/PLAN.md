# Plan to v1.0

Written 2026-11-20, after the v0.3.0 release. Goal: close every gap between
the current state and the v1.0 acceptance criteria ([SPEC §13](SPEC.md)), so
that v1.0 only needs the final evidence runs and the publication.

The phases organize the work; they are not releases. Releases are cut when a
large set of changes is ready, not per phase; the version number is chosen at
release time.

Every feature follows the Definition of Done ([SPEC §29](SPEC.md)): documented
public API, unit tests with edge cases, a value test, a benchmark with a
recorded result, and a filled matrix row. Performance claims use the
interleaved A/B method of v0.3 (base and change built side by side, 8 rounds
alternated, minimum and median ratio), because single runs on shared machines
vary by 2x.

## 1. Audit: gaps found before planning

| Gap | Evidence | Fixed in |
|---|---|---|
| D1–D8 are missing from the traceability matrix; three are P0 (D1, D2, D7) | `docs/TRACEABILITY.md` has 116 rows, SPEC has 124 IDs | Phase A |
| 54 of 97 exported symbols have no doc comment (criterion 6: 100%) | `nim jsondoc` over `src/` | Phase A |
| README describes v0.2: performance table, "59 tests", no latency, Prometheus, logging or composition | `README.md` | Phase A |
| The README quickstart is not validated in CI, nor installed through `nimble` (criterion 5, D1) | `ci.yml` builds `examples/` only | Phase C |
| No evidence of 1000 runs without failure for model and concurrency tests (criterion 4) | no job runs them repeatedly | Phase C |
| No gate for "zero warnings" (criterion 2); today the library builds with 0 warnings in the 4 modes, but nothing keeps it so | manual check, 2026-11-20 | Phase C |
| P2 (P0) was partial: windowed policies record successes under a lock | `docs/ROADMAP.md`, v0.3 | Decided (D-1, ADR-0015) |
| A5 (P0) is partial: no Chronos support | `src/circuit_breaker/async.nim` | Phase B |
| Upstream ORC issue drafted, not filed | `docs/upstream/` | Decision D-5 |

## 2. Decisions (taken 2026-11-20, as recommended)

| ID | Decision | Follow-up |
|---|---|---|
| D-1 | P2 amended: lock-free for the consecutive policy, lean locked path for windowed policies | [ADR-0015](decisions/0015-lean-locked-path-for-windowed-policies.md); P2 row done |
| D-2 | Nim `devel` informational (`continue-on-error`); Windows and macOS blocking | Phase C |
| D-3 | Coverage reported in the job summary; a minimum is set after the first measured value; no third-party service | Phase C |
| D-4 | `nim doc` published on GitHub Pages | Owner enables Pages in the repository settings (source: GitHub Actions) |
| D-5 | Upstream ORC issue filed by the owner after review | Owner action |
| D-6 | Equivalence table covers Resilience4j, Polly, gobreaker, pybreaker and opossum, checked against their current docs | Phase E |
| D-7 | No dedicated fuzzing library: ThreadSanitizer in CI (P1), libFuzzer harness against the model without a library (P2) | [ADR-0017](decisions/0017-fuzzing-without-a-dedicated-library.md) |

## 3. Priorities (revised 2026-11-20)

Phases A and B are done. The remaining work is ranked below; the phases in
section 4 describe each item.

| Priority | Item | Status / scope | Phase |
|---|---|---|---|
| P0 | Multi-platform CI: Linux, Windows, macOS (+ `devel` informational) | Linux only; `std/posix` and thread tests are the risks | C1 |
| P0 | Quickstart validated through `nimble install` in CI | release blocker: a broken install is the first thing a user sees | C3 |
| P0 | Concurrency and state coverage: nightly 1000 runs of `t_model` and `t_concurrency`, coverage report | criterion 4, Q7 | C4, C5 |
| P0 | Close Chronos: example, Chronos pinned in CI, Chronos tests on the new platforms | Y2, Y3, T5, A5 already done | B, E3 |
| P1 | Warnings gate | small, belongs with the CI work | C2 |
| P1 | ThreadSanitizer job for the concurrency tests (Linux, clang) | main remaining risk is concurrency; ADR-0017 | C |
| P1 | Composition docs: link from README, cancellation and `callTimeout` sections | `docs/COMPOSITION.md` exists | E |
| P1 | Examples: HTTP (exists), PostgreSQL (connection pool), Redis | D5 | E3 |
| P1 | Performance gate `nimble benchcheck` | v1.0 exit criterion (R4) | D |
| P1 | `docs/TUNING.md` | D4, P0 doc requirement for v1.0 | E2 |
| P2 | OpenTelemetry integration (B5), as a separate module, no core dependency | | post-v1.0 candidate |
| P2 | Examples with Nim servers (Jester/Prologue/HappyX, Chronos HTTP) | | E3 |
| P2 | State-machine fuzzing (V4): libFuzzer harness in `tests/fuzz/` against the model, nightly; no dedicated library | [ADR-0017](decisions/0017-fuzzing-without-a-dedicated-library.md) | after C5 |

## 4. Phases

The phases are ordered by dependency. A and C can overlap; B before the async
examples of E; D needs the CI work of C.

### Phase A: documentation debt and matrix (no code risk)

1. **Matrix:** add rows D1–D8 with their evidence. D1 (README, quickstart),
   D2 (state diagram, table), D6 (CHANGELOG, semver) and D7 (LICENSE,
   `.gitignore`) are done today and only need the row; D3, D4, D5, D8 stay
   pending until their phase. Extend `scripts/check_traceability.nim` to fail
   when a SPEC ID has no row, so this cannot happen again.
2. **API documentation to 100%:** write `##` for the 54 symbols. Decide per
   symbol: document it, or stop exporting it from the main module
   (`window` is an internal module; the `=destroy`/`=copy`/`=dup` hooks get a
   one-line note). Add `scripts/check_docs.nim` (from `nim jsondoc`) and run it
   in CI: fails on any exported symbol without a description.
3. **README:** features (O4, O6, O7, composition), the performance table
   with v0.3 numbers and the full method of SPEC 27.3 (date, hardware, Nim,
   flags, command), the multi-thread numbers, and the quality section (90
   tests, model and differential tests).
   - Tests: `check_docs` in CI; quickstart validation comes in Phase C.

### Phase B: async (A5, Y2, Y3, T5)

1. **Y2, Chronos:** module `circuit_breaker/chronos` with `callAsync` for
   Chronos futures, without the dependency in the core (`taskRequires` for
   tests, like proptest). Same semantics as the `asyncdispatch` version.
2. **Y3, cancellation:** a cancelled future must not leave the breaker in
   `HalfOpen` with a probe slot taken, and does not count as a failure by
   default. Config: `onCancel = ignoreCall()` (default) or `countAsFailure()`.
   Applies to Chronos (it has cancellation); for `asyncdispatch`, document that
   it has no cancellation and that an abandoned future is handled by the
   `Permit` guard.
3. **T5, per-call timeout:** `callTimeout` for the async APIs; exceeding it
   cancels the call (Chronos) or abandons it (`asyncdispatch`) and counts as a
   failure. Sync calls cannot be interrupted without a thread per call:
   document this and point to the dependency's own timeout
   (`docs/COMPOSITION.md`).
4. **A5:** row to done once Y2 is in.
   - Tests: Chronos suite mirroring `t_async`; cancellation of a probe while
     `HalfOpen` (slot released, state not stuck); timeout counted as failure;
     concurrency of many futures.
   - Value test: a cancelled probe used to leave the breaker unable to recover;
     with Y3 it recovers.
   - Benchmark: `callAsync` overhead for both runtimes (BM13, BM14).

### Phase C: CI, platforms and evidence (Q6, Q7, criteria 2, 4, 5)

1. **Q6, matrix:** Linux, macOS, Windows × `orc`, `arc` × threads on/off,
   Nim 2.2.4; plus Nim `devel` on Linux (D-2). Risks to check: `std/posix`
   in the core is Linux-only (guarded by `when defined(linux)`), the coarse
   clock path falls back to the precise one elsewhere, thread tests on
   Windows.
2. **Criterion 2, warnings gate:** a step that builds the library in the four
   modes and fails on any warning that points into `src/`.
3. **Criterion 5 and D1, quickstart:** `nimble install` from the checkout,
   then extract the Nim blocks of the README marked as quickstart and build
   them with package imports (no `../src`).
4. **Q7, coverage:** a Linux job with `--passC:--coverage`, `lcov` report in
   the job summary (D-3).
5. **Criterion 4, 1000 runs:** a scheduled workflow (nightly) that runs
   `t_model` and `t_concurrency` 1000 times each with fresh seeds, reports the
   first failing seed. Also kept as a manual trigger.

### Phase D: performance gate (R4)

1. `nimble benchcheck`: builds the merge base and the change in the same job,
   runs them interleaved (8 rounds), and compares per benchmark the minimum and
   the median of the per-round ratios.
2. **Calibration:** run A/A (base against base) on the CI runners to measure
   the noise, and set the limit above it (expected around 15 to 25%).
3. **Allocation gate:** fails if any benchmark marked "zero allocation"
   allocates (deterministic, ARC + `-d:nimAllocStats`).
4. Baselines change only through an explicit PR (SPEC 27.4).
   - Value test: a planted slowdown (an extra lock in the success path) must
     fail the gate; an A/A run must pass.

### Phase E: documentation and examples (D3, D4, D5, I4/D8)

1. **D3:** publish `nim doc` to GitHub Pages from CI on tags (D-4).
2. **D4:** `docs/TUNING.md`: how to pick `failureThreshold`, the rate
   policy's window and `minimumCalls`, `openTimeout` and backoff, slow-call
   duration, `successThreshold`, `halfOpenMaxProbes`, latency precision; and
   common pitfalls (threshold 1, window smaller than `minimumCalls`, retry
   inside the breaker, timeouts not raised as failures). Each recommendation
   tied to a test or a measured behaviour.
3. **D5, examples:** add database (connection pool), metrics (a `/metrics`
   endpoint serving `renderPrometheus`), fallback (`callOr`), and Chronos;
   HTTP client and async already exist. All compiled in CI.
4. **I4/D8:** `docs/EQUIVALENCE.md`: concept and parameter mapping for the
   libraries of D-6, including what has no equivalent.

### Also before v1.0

- **P7:** refresh the evidence with the v0.3 numbers (28 to 37 ns minimum on
  the development machine) and mark it done if it holds on the README machine.
- Keep the Post-1.0 list unchanged (Y4, N12, B5 and the rest).

## 5. Exit criteria

- Every P0 and P1 requirement done, or amended by an accepted ADR (D-1).
- Matrix covers every SPEC ID, checked in CI.
- 100% of the public API documented, checked in CI.
- CI green on Linux, macOS and Windows; `devel` reported.
- The nightly 1000-run job has passed at least once.
- `nimble benchcheck` calibrated and running on PRs.

With these, v1.0 needs only: the README benchmark refreshed on the reference
machine, a final review of the API for 1.0 stability, and the tag.
