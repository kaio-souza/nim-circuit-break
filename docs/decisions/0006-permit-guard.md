# ADR-0006: `Permit` guard with automatic failure recording

- Status: Accepted
- Date: 2026-11-19
- Requirements: E2, E3, E4, A7, P4

## Context

A low-level manual API ("allow" + "record outcome") is needed for advanced cases, but it has a serious failure mode: if code forgets to record the outcome of a probe (early return, unexpected exception), the breaker stays stuck in `HalfOpen` forever, because the probe slot is never released.

## Decision

- The low-level API returns a `Permit` (`acquire` raises `CircuitOpenError`; `tryAcquire` returns a `bool`).
- `Permit` has a destructor (`=destroy`): if it leaves scope without `success`, `failure`, `ignore` or `record`, it **records a failure**.
- Copies are forbidden at compile time (`=copy` and `=dup` with `{.error.}`), so an outcome is never recorded twice.
- `call`, `withBreaker` and `callAsync` are built on the same `Permit`: there is a single core.
- `withBreaker` is a template: the body is inlined, with no closure. Leaving normally or through `return`/`break` counts as success.
- `Permit` holds a `ptr` to the breaker, not a `ref`, to avoid reference counting on the hot path.

## Consequences

- The breaker must **outlive** the permits it grants. In multi-threaded code, keep it in a global or another long-lived owner. This is documented in the module and the README.
- Recording a failure automatically is the conservative choice: a forgotten outcome never closes the circuit by mistake.

## Evidence

`t_api`: E2 (automatic recording), E2 (copy does not compile, via `tests/compile_fail/permit_copy.nim`), E3/A7, E4. `t_values`: V-E2 (a manual API gets stuck × the guard recovers). BM6: `withBreaker` 41 ns, `tryAcquire` + `success` 54 ns, 0 allocations.
