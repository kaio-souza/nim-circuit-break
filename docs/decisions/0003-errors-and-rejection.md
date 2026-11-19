# ADR-0003: Failures propagate the original exception; rejection is `CircuitOpenError`

- Status: Accepted
- Date: 2026-11-19
- Requirements: A1–A4, A6, E5, F5–F8

## Context

In v0.1, `call` returned `Option[T]`: rejection and failure of the function were both `none(T)`. The caller could not tell whether to retry later (open circuit) or handle a real error, and lost the exception and its stack trace.

## Decision

- **Failure of the function**: the original exception is re-raised unchanged (`raise`) after being recorded.
- **Rejection**: `CircuitOpenError` (a `CatchableError`) with `breakerName`, `state` and `retryAfter`, which makes it easy to answer with an HTTP `Retry-After`.
- Alternative styles on the same core, for those who do not want exceptions:
  - `tryCall` → `CallResult[T]` with `crOk`, `crRejected` or `crFailed`;
  - `callOr` → runs a fallback that receives the rejection or the original exception;
  - `tryAcquire` → a boolean, with no exception allocated on rejection.
- **`Defect`** (bugs, asserts) propagates and does **not** count as a failure: a local bug must not open the circuit of a healthy remote service.
- What counts as a failure is decided by `classifyError` (exceptions) and `isFailureResult` (returned values, e.g. HTTP 503 without an exception). The classifier can ignore the call or return a `Retry-After` hint (ADR-0009).

## Consequences

- Rejecting through `call` allocates the exception (270 ns, 3 allocations in BM3). Hot paths that expect mass rejection should use `tryAcquire` (63 ns, 0 allocations).
- `call` works with `void` procs (dedicated overload).

## Evidence

`t_api`: A1/A2/E1, A3/E5, A3 (`tryCall`), A4, A6. `t_policies`: F5/F6/G3, F7, F8. BM3 in `b_core.nim`.
