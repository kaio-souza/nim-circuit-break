## D3 / v1.0 criterion 6: every exported symbol of the library has a doc
## comment. Runs `nim jsondoc` on each module of `src/` and fails listing the
## symbols with an empty description. Object fields are not checked here (they
## are documented inline where they need it).

import std/[os, osproc, json, strutils]

let root = currentSourcePath().parentDir.parentDir
let outDir = getTempDir() / "cb_check_docs_" & $getCurrentProcessId()
createDir(outDir)

var modules = @[root / "src" / "circuit_breaker.nim"]
for f in walkFiles(root / "src" / "circuit_breaker" / "*.nim"): modules.add f

var missing: seq[string]
var total = 0
for m in modules:
  let (output, code) = execCmdEx("nim jsondoc --hints:off --warnings:off --outdir:" &
                                 quoteShell(outDir) & " " & quoteShell(m))
  if code != 0:
    echo output
    quit "nim jsondoc failed for " & m
  let jsonFile = outDir / m.extractFilename.changeFileExt("json")
  for e in parseFile(jsonFile){"entries"}.getElems:
    inc total
    if e{"description"}.getStr.strip.len == 0:
      missing.add m.extractFilename & ": " & e{"type"}.getStr.replace("sk", "") &
                  " " & e{"name"}.getStr

if missing.len > 0:
  echo "Documentation check FAILED: ", missing.len, " of ", total,
       " exported symbols have no doc comment:"
  for x in missing: echo "  - ", x
  quit 1
echo "Documentation OK: ", total, " exported symbols, all documented."
