## R4: performance gate (ADR-0020, SPEC 27.4). Builds the benchmark suite for
## a base revision and for the change, runs them interleaved, and compares
## each benchmark's median across rounds; then checks that the benchmarks
## listed in `benchmarks/zero_alloc.txt` do not allocate.
##
##   nim r scripts/benchcheck.nim [--base=REF] [--rounds=8] [--limit=0.25]
##                                [--aa] [--skip-alloc] [--only-alloc]
##
## - base: `git merge-base HEAD origin/master` (else `master`, else HEAD~1).
## - the change is the working tree; `--aa` compares REF against itself
##   (two binaries of the same source) to measure the noise of the machine.
## - per benchmark the per-round ratio is change/base of the median ns/op.
##   The gate fails when the MEDIAN ratio exceeds 1 + limit and no round was
##   faster than the base (min > 1): a real slowdown shows in every round, while
##   a noisy round (A/A runs showed single rounds at 0.4x and 2.3x) moves the
##   minimum or the maximum but not the median. See ADR-0020.
## - the allocation gate is deterministic: ARC + -d:nimAllocStats, one run.
## Linux only (shell redirection, tar, git).

import std/[os, osproc, strutils, json, algorithm, tables, strformat, tempfiles, sequtils]

const
  benches = ["b_core", "b_window", "b_keyed"]
  flags = "-d:release --opt:speed --threads:on --hints:off --warnings:off --mm:orc"
  allocFlags = "-d:release --opt:speed --threads:on --hints:off --warnings:off " &
               "--mm:arc -d:nimAllocStats"

let root = currentSourcePath().parentDir.parentDir

proc sh(cmd: string; dir = root): string =
  let (o, c) = execCmdEx(cmd, workingDir = dir)
  if c != 0: quit "command failed: " & cmd & "\n" & o
  o.strip

var
  baseRef = ""
  rounds = 8
  limit = 0.25
  aa, skipAlloc, onlyAlloc = false
for a in commandLineParams():
  if a.startsWith("--base="): baseRef = a[7 .. ^1]
  elif a.startsWith("--rounds="): rounds = parseInt(a[9 .. ^1])
  elif a.startsWith("--limit="): limit = parseFloat(a[8 .. ^1])
  elif a == "--aa": aa = true
  elif a == "--skip-alloc": skipAlloc = true
  elif a == "--only-alloc": onlyAlloc = true
  else: quit "unknown argument: " & a

proc refExists(r: string): bool =
  execCmdEx("git rev-parse --verify --quiet " & quoteShell(r & "^{commit}"),
            workingDir = root).exitCode == 0

if baseRef.len == 0:
  if aa: baseRef = "HEAD"
  else:
    for cand in ["origin/master", "master"]:
      if refExists(cand):
        baseRef = sh("git merge-base HEAD " & cand); break
    if baseRef.len == 0: baseRef = "HEAD~1"

let work = createTempDir("benchcheck_", "")
echo "work dir: ", work, "  base: ", baseRef, "  rounds: ", rounds, "  limit: ", limit

proc readResults(dir, file: string): Table[string, JsonNode] =
  for r in parseFile(dir / file){"results"}.getElems: result[r["name"].getStr] = r

var failures: seq[string]

if not onlyAlloc:
  # Base tree: only src and benchmarks, so its own benchmarks match its API.
  let baseDir = work / "base"
  createDir(baseDir)
  discard sh("git archive " & quoteShell(baseRef) & " src benchmarks | tar -x -C " & quoteShell(baseDir))
  let sideDir = {"base": baseDir, "change": (if aa: baseDir else: root)}.toTable

  for side in ["base", "change"]:
    for b in benches:
      let src = sideDir[side] / "benchmarks" / (b & ".nim")
      if not fileExists(src): continue
      echo "building ", side, " ", b
      discard sh("nim c " & flags & " --nimcache:" & quoteShell(work / "nc_" & side & "_" & b) &
                 " -o:" & quoteShell(work / (side & "_" & b)) & " " & quoteShell(src))

  # ratios[bench name] = per-round change/base
  var ratios: Table[string, seq[float]]
  for r in 1 .. rounds:
    # Alternate who runs first so a drifting machine does not favour a side.
    let order = if r mod 2 == 1: @["base", "change"] else: @["change", "base"]
    for b in benches:
      if not fileExists(work / ("base_" & b)): continue
      for side in order:
        let jd = work / ("json_" & side & "_" & $r)
        discard sh("BENCH_JSON_DIR=" & quoteShell(jd) & " " & quoteShell(work / (side & "_" & b)) & " > /dev/null")
      let jb = readResults(work / ("json_base_" & $r), b & ".json")
      let jc = readResults(work / ("json_change_" & $r), b & ".json")
      for name, rb in jb:
        if name in jc and rb["medianNs"].getFloat > 0:
          ratios.mgetOrPut(name, @[]).add jc[name]["medianNs"].getFloat / rb["medianNs"].getFloat
    echo "round ", r, " done"

  echo ""
  echo &"""{"benchmark":<56} {"min":>6} {"median":>7} {"max":>6}"""
  var names = toSeq(ratios.keys)
  names.sort()
  for n in names:
    var xs = ratios[n]
    xs.sort()
    let med = xs[xs.len div 2]
    let slower = med > 1.0 + limit
    let flag = if slower and xs[0] > 1.0: "  REGRESSION" elif slower: "  (noisy)" else: ""
    echo &"{n:<56} {xs[0]:>6.2f} {med:>7.2f} {xs[^1]:>6.2f}{flag}"
    if slower and xs[0] > 1.0:
      failures.add &"{n}: slower in every round, median ratio {med:.2f} > {1.0 + limit:.2f}"

if not skipAlloc:
  let ad = work / "alloc"
  for b in ["b_core", "b_window", "b_keyed"]:
    let src = root / "benchmarks" / (b & ".nim")
    discard sh("nim c " & allocFlags & " --nimcache:" & quoteShell(work / ("nc_alloc_" & b)) &
               " -o:" & quoteShell(work / ("alloc_" & b)) & " " & quoteShell(src))
    discard sh("BENCH_JSON_DIR=" & quoteShell(ad) & " " & quoteShell(work / ("alloc_" & b)) & " > /dev/null")
  var all: Table[string, JsonNode]
  for b in ["b_core", "b_window", "b_keyed"]:
    for k, v in readResults(ad, b & ".json"): all[k] = v
  var checked = 0
  for line in readFile(root / "benchmarks" / "zero_alloc.txt").splitLines:
    let n = line.strip
    if n.len == 0 or n.startsWith("#"): continue
    inc checked
    if n notin all: failures.add "zero_alloc.txt names an unknown benchmark: " & n
    elif all[n]["allocsPerOp"].getFloat >= 0.001:
      failures.add &"{n}: allocates {all[n][\"allocsPerOp\"].getFloat:.2f} per op (must be zero)"
  echo "allocation gate: ", checked, " zero-allocation benchmarks checked"

if failures.len > 0:
  echo "\nFAILED:"
  for f in failures: echo "  ", f
  quit 1
echo "\nbenchcheck passed (work dir kept at ", work, ")"
