# ADR-0011: `KeyedBreaker` with a capacity cap and LRU eviction

- Status: Accepted
- Date: 2026-11-19
- Requirements: N2, A13

## Context

In microservices, one breaker per destination (host, endpoint, tenant) keeps a bad dependency from taking down calls to healthy ones. But keys may be unbounded (e.g. one tenant per customer), and an unbounded map leaks memory.

## Decision

- `KeyedBreaker[K]` creates one breaker per key on demand, from a `configFor(key)` factory. An empty or `"default"` name becomes `$key`.
- A capacity cap is mandatory; above it, the least recently used key is evicted. Implementation: `Table[K, node]` + a doubly linked list, O(1) per access.
- Designed for single-threaded and async code. With threads there is a lock, but breakers are shared `ref`s: `--mm:atomicArc` is required, and the returned breaker must stay referenced while in use.

## Consequences

- An evicted key loses its state; if it comes back, it starts `Closed`. The cap must be larger than the number of active keys.
- `evictions` reports how many evictions happened, to tune the cap.

## Evidence

`t_keyed`: N2 (independence per key, capacity and LRU, invalid capacity). `t_values`: V-N2 (200k distinct keys stay within the cap). BM7: hit lookup 65 ns, 0 allocations.
