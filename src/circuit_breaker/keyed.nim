## One breaker per key (host, endpoint, tenant...) with a capacity limit and
## least-recently-used eviction (N2), so unbounded keys never leak memory.
##
## Experimental (ADR-0019): this module may change in a minor release.
##
## Thread-safety: designed for single-threaded and async code. With threads,
## compile with `--mm:atomicArc` and keep each returned breaker referenced
## while it is in use.

import std/[tables, lists]
import types, core, calls, private/sync

type
  Entry[K] = object
    key: K
    breaker: CircuitBreaker

  ConfigFactory*[K] = proc(key: K): BreakerConfig
    ## Builds the configuration of the breaker for a new key.

  KeyedBreaker*[K] = ref object
    ## One breaker per key, created on demand, with a capacity cap and LRU
    ## eviction (N2, ADR-0011).
    lock: Lock
    capacity: int
    configFor: ConfigFactory[K]
    order: DoublyLinkedList[Entry[K]]  # head = most recently used
    index: Table[K, DoublyLinkedNode[Entry[K]]]
    evictions: int

proc newKeyedBreaker*[K](capacity: int; configFor: ConfigFactory[K]): KeyedBreaker[K] =
  ## `configFor` builds the config of a new key. An empty or "default" name
  ## becomes `$key`.
  if capacity < 1:
    raise newException(ValueError, "capacity must be >= 1")
  result = KeyedBreaker[K](capacity: capacity, configFor: configFor)
  initLockIfThreads(result.lock)

template withLock(kb: KeyedBreaker; body: untyped) =
  withLockIfThreads(kb.lock, body)

proc get*[K](kb: KeyedBreaker[K]; key: K): CircuitBreaker =
  ## Returns the breaker of `key`, creating it if needed.
  withLock(kb):
    let node = kb.index.getOrDefault(key)
    if node != nil:
      if node != kb.order.head:
        kb.order.remove(node)
        kb.order.prepend(node)
      result = node.value.breaker
    else:
      var cfg = kb.configFor(key)
      if cfg.name.len == 0 or cfg.name == "default": cfg.name = $key
      result = newCircuitBreaker(cfg)
      let n = newDoublyLinkedNode(Entry[K](key: key, breaker: result))
      kb.order.prepend(n)
      kb.index[key] = n
      if kb.index.len > kb.capacity:
        let victim = kb.order.tail
        kb.order.remove(victim)
        kb.index.del(victim.value.key)
        inc kb.evictions

proc contains*[K](kb: KeyedBreaker[K]; key: K): bool =
  ## True when `key` has a live breaker (not created, not evicted).
  withLock(kb):
    result = key in kb.index

proc len*[K](kb: KeyedBreaker[K]): int =
  ## Number of live breakers.
  withLock(kb):
    result = kb.index.len

proc evictions*[K](kb: KeyedBreaker[K]): int =
  ## Breakers evicted so far to respect the capacity; use it to tune the cap.
  withLock(kb):
    result = kb.evictions

proc call*[K, T](kb: KeyedBreaker[K]; key: K; fn: proc(): T): T =
  ## Runs `fn` under the breaker of `key`.
  kb.get(key).call(fn)

proc call*[K](kb: KeyedBreaker[K]; key: K; fn: proc()) =
  ## Runs `fn` (without a result) under the breaker of `key`.
  kb.get(key).call(fn)
