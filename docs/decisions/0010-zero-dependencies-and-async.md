# ADR-0010: Zero dependencies; async in an optional module

- Status: Accepted
- Date: 2026-11-19
- Requirements: P8, A5, Y1, Y2

## Context

An infrastructure library ends up in many projects; every transitive dependency is an adoption cost and a risk. The Nim ecosystem has two incompatible async runtimes (`std/asyncdispatch` and Chronos).

## Decision

- The core uses **only the standard library**. Requires Nim >= 2.2.4.
- Optional features live in explicitly imported modules: `circuit_breaker/async`, `circuit_breaker/keyed`, `circuit_breaker/testing`. Code that does not import them does not pay for them.
- `callAsync` supports `std/asyncdispatch` in v0.2. Chronos (Y2) will come in a separate module, again without forcing the dependency on those who do not use it.

## Consequences

- `nimble install` downloads nothing but the package.
- `Future` cancellation (Y3) and per-call timeouts (T5) were planned together with Chronos; delivered by [ADR-0016](0016-chronos-cancellation-and-timeouts.md).

## Evidence

`circuit_breaker.nimble`: only `requires "nim >= 2.2.4"`. `t_async`: Y1/A5, Y1.
