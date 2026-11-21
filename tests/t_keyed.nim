import std/unittest
import helpers
import circuit_breaker/keyed

suite "keyed breakers":
  test "N2: one independent breaker per key":
    let clock = newFakeClock()
    let kb = newKeyedBreaker[string](10, proc(key: string): BreakerConfig =
      BreakerConfig(failureThreshold: 1, clock: clock.source))
    expect IOError:
      kb.call("a", proc() = raise newException(IOError, "down"))
    check kb.get("a").state == Open
    check kb.get("b").state == Closed
    check kb.get("a").name == "a"
    check kb.call("b", proc(): int = 7) == 7

  test "N2: capacity is enforced with LRU eviction":
    let kb = newKeyedBreaker[int](3, proc(key: int): BreakerConfig = BreakerConfig())
    for k in 1 .. 3: discard kb.get(k)
    discard kb.get(1)                 # 1 becomes most recently used
    discard kb.get(4)                 # evicts 2, the least recently used
    check kb.len == 3
    check 1 in kb and 3 in kb and 4 in kb
    check 2 notin kb
    check kb.evictions == 1

  test "N2: invalid capacity":
    expect ValueError:
      discard newKeyedBreaker[int](0, proc(key: int): BreakerConfig = BreakerConfig())
