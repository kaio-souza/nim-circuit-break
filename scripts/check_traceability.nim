## Validates docs/TRACEABILITY.md against the test and benchmark sources
## (EV1/EV2). Exit code 1 lists every problem found.

import std/[os, strutils, sets, tables]

proc isId(s: string): bool =
  ## One or two capital letters followed by digits, e.g. "S5", "BM1" excluded by caller.
  var i = 0
  while i < s.len and s[i] in {'A'..'Z'}: inc i
  i in 1..2 and i < s.len and s[i ..< s.len].allCharsInSet({'0'..'9'})

let root = currentSourcePath().parentDir.parentDir

proc read(dir, pattern: string): string =
  for f in walkFiles(root / dir / pattern): result.add readFile(f) & "\n"

let testSrc = read("tests", "t*.nim")
let benchSrc = read("benchmarks", "b_*.nim")

# IDs mentioned in test names, e.g. test "A1/A2/E1: ..." or test "V-E2: ..."
var testedIds = initHashSet[string]()
for line in testSrc.splitLines:
  let t = line.strip
  if not t.startsWith("test \""): continue
  let name = t[6 .. ^1]
  let head = name.split(':')[0]
  for part in head.split('/'):
    let id = part.strip.replace("V-", "")
    if id.isId: testedIds.incl id

var problems: seq[string]
var rows = initTable[string, string]()
var done = 0

for line in readFile(root / "docs" / "TRACEABILITY.md").splitLines:
  let cols = line.split('|')
  if cols.len < 7: continue
  let id = cols[1].strip
  if not id.isId: continue
  let status = cols[3].strip
  let tests = cols[4].strip
  let bench = cols[5].strip
  if id in rows: problems.add id & ": duplicated row"
  rows[id] = status
  if status notin ["done", "partial", "pending", "deferred"]:
    problems.add id & ": unknown status '" & status & "'"
  if status in ["done", "partial"]:
    inc done
    if tests != "CI" and id notin testedIds:
      problems.add id & ": marked '" & status & "' but no test name mentions it"
    if bench.startsWith("BM") and not benchSrc.contains(bench & " "):
      problems.add id & ": benchmark " & bench & " not found in benchmarks/"

for id in testedIds:
  if id notin rows:
    problems.add id & ": cited by a test but missing from TRACEABILITY.md"

# Every requirement of the SPEC (a table row "| ID | P0 |") needs a matrix row,
# so a requirement can never be silently left out of the evidence.
for line in readFile(root / "docs" / "SPEC.md").splitLines:
  let cols = line.split('|')
  if cols.len < 4: continue
  let id = cols[1].strip
  let pri = cols[2].strip
  if id.isId and pri.len == 2 and pri[0] == 'P' and pri[1] in {'0'..'9'} and
     id notin rows:
    problems.add id & ": in SPEC.md but missing from TRACEABILITY.md"

if problems.len > 0:
  echo "Traceability check FAILED:"
  for p in problems: echo "  - ", p
  quit 1
echo "Traceability OK: ", rows.len, " requirements, ", done,
  " done or partial, ", testedIds.len, " IDs cited by tests."
