## BM7: keyed breakers: lookup of an existing key and miss with eviction.

import harness
import ../src/circuit_breaker, ../src/circuit_breaker/keyed

const n = 100_000

proc main() =
  header("keyed breakers (capacity 1000)")
  let kb = newKeyedBreaker[int](1000, proc(key: int): BreakerConfig =
    initBreakerConfig())
  for k in 0 ..< 1000: discard kb.get(k)
  var k = 0
  bench("BM7 get existing key (hit, LRU move)", n):
    keep = ord(kb.get(k mod 1000).state)
    inc k
  var miss = 1_000_000
  bench("BM7 get new key (miss + create + evict)", n div 10):
    keep = ord(kb.get(miss).state)
    inc miss
  let fn = proc(): int = 1
  bench("BM7 keyed call (hit)", n):
    keep = kb.call(k mod 1000, fn)
    inc k
  writeJson("b_keyed.json")

main()
