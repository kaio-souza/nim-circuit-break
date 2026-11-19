# ADR-0014: CI on the official Nim image

- Status: Accepted
- Date: 2026-11-19
- Requirements: Q6, Q8, C4, D3

## Context

The breaker's behavior depends on the memory manager (`orc`, `arc`) and on whether threads are on (the lock is compiled conditionally). Third-party actions that install Nim are an external dependency of the build chain.

## Decision

- Jobs run in the official `nimlang/nim` container, pinned by version (`2.2.4`). The only action used is `actions/checkout`.
- Matrix: `orc`/`arc` × threads on/off, each in release and in debug (with runtime checks).
- A separate job builds every example, generates the API docs (`nim doc`) and validates the traceability matrix.
- Minimal permissions (`contents: read`); repeated runs on the same ref are cancelled.
- Linux only for now. macOS, Windows, Nim `devel`, coverage and sanitizers come once the current matrix is stable on GitHub (SPEC 27.5). Sanitizers (ASan, TSan) were run locally.

## Consequences

- Upgrading Nim is an explicit one-line change in the workflow.
- `nimble test` needs a commit in the repository; the CI checkout already has one.

## Evidence

`.github/workflows/ci.yml` and `.github/workflows/bench.yml`. First real run pending (see the [roadmap](../ROADMAP.md)).
