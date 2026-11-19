## One breaker per key (host, endpoint, tenant...) with a capacity limit and
## least-recently-used eviction (N2), so unbounded keys never leak memory.
##
## Thread-safety: designed for single-threaded and async code. With threads,
## compile with `--mm:atomicArc` and keep each returned breaker referenced
## while it is in use.

import std/[tables, lists, locks]
import types, core

const threadsOn = compileOption("threads")

type
  Entry[K] = object
    key: K
    breaker: CircuitBreaker

  ConfigFactory*[K] = proc(key: K): BreakerConfig

  KeyedBreaker*[K] = ref object
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
  when threadsOn: initLock(result.lock)

template withLock(kb: KeyedBreaker; body: untyped) =
  when threadsOn:
    acquire(kb.lock)
    try:
      body
    finally:
      release(kb.lock)
  else:
    body

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
  withLock(kb):
    result = key in kb.index

proc len*[K](kb: KeyedBreaker[K]): int =
  withLock(kb):
    result = kb.index.len

proc evictions*[K](kb: KeyedBreaker[K]): int =
  withLock(kb):
    result = kb.evictions

proc call*[K, T](kb: KeyedBreaker[K]; key: K; fn: proc(): T): T =
  ## Runs `fn` under the breaker of `key`.
  kb.get(key).call(fn)

proc call*[K](kb: KeyedBreaker[K]; key: K; fn: proc()) =
  kb.get(key).call(fn)
