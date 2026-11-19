# Repro: ORC + -d:nimAllocStats crash on re-raise (Nim 2.2.4)
# nim c -r -d:release --mm:orc -d:nimAllocStats repro_orc_allocstats.nim  -> SIGSEGV in registerCycle
# Without -d:nimAllocStats, or with --mm:arc: prints 'survived'.
proc g[T](fn: proc(): T): T =
  try:
    result = fn()
  except CatchableError as e:
    discard e.msg.len
    raise
proc main() =
  for i in 0 ..< 3:
    try:
      discard g(proc(): int = raise newException(IOError, "x"))
    except IOError:
      discard
  echo "survived"
main()
