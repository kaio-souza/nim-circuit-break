# ADR-0001: Scope limited to the circuit breaker

- Status: Accepted
- Date: 2026-11-19
- Requirements: A13, A14, I1

## Context

Resilience patterns usually come together (retry, rate limiting, bulkhead, timeout, fallback). Implementing all of them dilutes the effort and widens the bug surface. The value of a circuit breaker lies in semantic details that are easy to get wrong: when the state changes, who is a probe, what counts as a failure, how an opening is explained.

## Decision

The library does **only circuit breaking**, in depth: several opening policies, classifiers, observability, shadow mode, keyed breakers. Fallback is included because it is a natural part of the protected call (`callOr`).

Retry, rate limiting, bulkhead and timeout are out of scope. The library must **compose** with implementations of those patterns, and this will be documented in a guide (I1).

## Consequences

- Small, cohesive API; every feature can be proven thoroughly (ADR-0002).
- Users who need retry or a bulkhead combine this library with another one. The composition guide (I1) is required before v1.0 so this does not become friction.
- A14 (bulkhead) and A13 (global registry) are deferred; `KeyedBreaker` covers the most common registry use case.

## Evidence

`src/circuit_breaker/`: no module outside the breaker's scope. I1 is pending in the [roadmap](../ROADMAP.md).
