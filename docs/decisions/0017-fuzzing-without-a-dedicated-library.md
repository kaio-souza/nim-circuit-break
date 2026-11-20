# ADR-0017: Fuzzing without a dedicated library; ThreadSanitizer first

- Status: Accepted
- Date: 2026-11-20
- Requirements: V4, Q-criterion 4 (SPEC §13)

## Context

The plan listed "state-machine fuzzing (V4), via nim-proptest". That conflated
two techniques:

- **Property-based testing** (nim-proptest): typed generators, properties and
  shrinking. Fits structured inputs, such as a sequence of operations checked
  against a reference model. `t_model` already does this.
- **Coverage-guided fuzzing** (libFuzzer, AFL): mutates bytes and uses code
  coverage to reach hard branches. Pays off when the input is an
  attacker-controlled format: parsers, protocols, deserialization.

The question was whether to write a separate Nim fuzzing library.

## Decision

- **No dedicated fuzzing library.** The breaker parses no untrusted input
  (JSON config, K4, is post-1.0); its state space is small and structured,
  which model-based PBT already covers. A third library would split effort
  with nim-proptest, still in design, before v1.0.
- **ThreadSanitizer in CI (P1).** The main remaining risk is concurrency,
  which fuzzing does not address. A Linux job builds the concurrency tests
  with clang and `-fsanitize=thread` and runs them.
- **libFuzzer harness without a library (P2).** `tests/fuzz/` holds a harness
  that exports `LLVMFuzzerTestOneInput`, decodes the bytes into a sequence of
  breaker operations and compares the result with the reference model of
  `t_model`. Built with clang and `-fsanitize=fuzzer,address`, run in the
  nightly job with a time budget, corpus kept in the repository.

## Consequences

- V4 is covered by the harness, not by nim-proptest.
- Revisit a dedicated library only if several Nim projects need a reusable
  libFuzzer/AFL harness (nimble integration, corpus handling, CI). That would
  be a project of its own, with its own audience.
- Existing community options (for example drchaos, structured fuzzing on
  libFuzzer) are to be checked for maintenance before being adopted.

## Evidence

Pending: TSan job (phase C) and fuzz harness (after C5) in `docs/PLAN.md`.
