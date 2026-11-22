## A breaker in front of a database connection pool. Constraint violations are
## the caller's fault and must not open the circuit; connection errors and
## slow queries must. Run: nim c -r examples/database_pool.nim

import std/[times, strutils]
import circuit_breaker

type
  ConnectionError = object of CatchableError
  UniqueViolation = object of CatchableError

var tick = 0   # the "database" is down for queries 4..9

proc query(sql: string): seq[string] =
  inc tick
  if tick in 4 .. 9: raise newException(ConnectionError, "pool exhausted")
  if "duplicate" in sql: raise newException(UniqueViolation, "duplicate key")
  @["row"]

let cfg = BreakerConfig(
  name: "postgres",
  policy: FailureRate,
  minimumCalls: 5, windowSize: 10, failureRateThreshold: 0.5,
  slowCallDuration: initDuration(seconds = 1),
  openTimeout: initDuration(seconds = 5),
  halfOpenMaxProbes: 2, successThreshold: 2,
  classifyError: proc(e: ref CatchableError): Verdict =
    if e of UniqueViolation: ignoreCall()        # not the database's health
    else: countAsFailure())

for w in cfg.diagnose: echo "config warning: ", w
let db = newCircuitBreaker(cfg)

for i in 1 .. 12:
  let sql = if i == 2: "insert duplicate" else: "select 1"
  try:
    discard db.call(proc(): seq[string] = query(sql))
    echo i, ": ok"
  except UniqueViolation as e:
    echo i, ": ", e.msg, " (ignored by the breaker)"
  except ConnectionError as e:
    echo i, ": ", e.msg
  except CircuitOpenError as e:
    echo i, ": rejected, ", e.state, ", retry in ", e.retryAfter.inSeconds, " s"
echo db.report
