# ADR-0018: Supported Nim versions and platforms

- Status: Accepted
- Date: 2026-11-21
- Requirements: Q6, Q8, C4

## Context

CI ran only Nim 2.2.4 on Linux (ADR-0014), while Nim 2.4 is the current
stable line. The breaker uses threads, atomics, locks and monotonic clocks,
which differ between operating systems. Raising the bar for a published
package means testing what users actually run.

Checked locally on 2026-11-21: the full suite passes on Nim 2.0.16, 2.2.14
and 2.4.2 without warnings. Nim 2.0 needed one change: a proc named like a
field of the breaker object (`rejectFast`) was resolved to the field, so the
proc became `tryRejectFast`.

## Decision

- The package requires `nim >= 2.0.0`.
- Linux, in the official `nimlang/nim` container: 2.2.4, 2.2.14 and 2.4.0,
  each with `orc`/`arc` x threads on/off, release and debug. Nim `devel`
  runs one configuration and does not fail the build.
- Nim 2.0.16 on Linux, from the official binary: every test except the model
  test, because proptest (test-only) requires Nim 2.2.4.
- Windows (official binary, 2.4.2) and macOS (Homebrew's current Nim): `orc`
  with threads, release and debug.
- Still no third-party actions: Nim comes from the official image, the
  official binaries on nim-lang.org, or Homebrew.

## Consequences

- The macOS job follows Homebrew's Nim version and is not pinned.
- Supporting Nim 2.0 rules out 2.2-only language and library features in
  `src/`.
- Partially supersedes ADR-0014 (versions and platforms); the rest of it
  stands.

## Evidence

`.github/workflows/ci.yml`.
