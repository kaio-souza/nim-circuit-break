## Internal: locking that compiles away without `--threads:on`.

when defined(nimlinearIntercept):
  # Test builds only: see the import note in core.nim.
  import nimlinear/intercept
  export intercept
else:
  import std/locks
  export locks

const threadsOn* = compileOption("threads")
  ## Whether locks are compiled in.

template initLockIfThreads*(l: var Lock) =
  ## `initLock` with threads on; nothing otherwise.
  when threadsOn: initLock(l)

template withLockIfThreads*(l: var Lock; body: untyped) =
  ## Runs `body` holding `l` with threads on; just `body` otherwise.
  when threadsOn:
    acquire(l)
    try:
      body
    finally:
      release(l)
  else:
    body
