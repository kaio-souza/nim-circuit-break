## v1.0 criterion 2: the library builds with zero warnings. Type-checks every
## module of `src/` with `nim check` in each memory manager and thread mode
## (plus `-d:cbDisabled`) and fails on any warning that points into `src/`.
## Warnings from dependencies (Chronos) are not counted.

import std/[os, osproc, strutils, algorithm]

let root = currentSourcePath().parentDir.parentDir
let src = root / "src"

var modules = @[src / "circuit_breaker.nim"]
for f in walkFiles(src / "circuit_breaker" / "*.nim"): modules.add f
modules.sort()

const modes = [
  "--mm:orc --threads:on", "--mm:orc --threads:off",
  "--mm:arc --threads:on", "--mm:arc --threads:off",
  "--mm:orc --threads:on -d:cbDisabled"]

var bad: seq[string]
for mode in modes:
  for m in modules:
    # The Chronos module needs the optional dependency; skip it if absent.
    let (output, code) = execCmdEx("nim check --hints:off --warnings:on " & mode &
                                   " " & quoteShell(m))
    if code != 0 and m.endsWith("chronos_async.nim") and "cannot open file" in output:
      continue
    if code != 0:
      echo output
      quit "nim check failed: " & mode & " " & m
    for line in output.splitLines:
      if "Warning:" in line and (src / "") in line:
        let entry = "[" & mode & "] " & line
        if entry notin bad: bad.add entry

if bad.len > 0:
  for b in bad: echo b
  quit "warnings found in src/: " & $bad.len
echo "zero warnings in src/ (", modes.len, " modes, ", modules.len, " modules)"
