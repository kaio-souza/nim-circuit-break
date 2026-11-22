## D1 / v1.0 criterion 5: the README snippets compile against the installed
## package. Every ```nim block preceded by `<!-- check:readme -->` is
## extracted and built with `nim c` from a scratch directory, with no `--path`
## to the checkout: it resolves `circuit_breaker` the way a user would, after
## `nimble install`. Usage: `nim r scripts/check_readme.nim <scratch dir>`.
## The application functions the snippets call come from `readme_stubs.nim`.

import std/[os, osproc, strutils]

let root = currentSourcePath().parentDir.parentDir
if paramCount() != 1: quit "usage: check_readme <empty scratch dir>"
let work = paramStr(1)
createDir(work)

var blocks: seq[string]
var armed, inside = false
var cur: seq[string]
for line in readFile(root / "README.md").splitLines:
  if inside:
    if line.startsWith("```"):
      blocks.add cur.join("\n"); cur = @[]; inside = false
    else: cur.add line
  elif line.strip == "<!-- check:readme -->": armed = true
  elif armed and line.startsWith("```nim"): inside = true; armed = false
  elif line.strip.len > 0: armed = false

if blocks.len == 0: quit "no <!-- check:readme --> blocks found in README.md"

copyFile(root / "scripts" / "readme_stubs.nim", work / "readme_stubs.nim")
var failed = 0
for i, b in blocks:
  let file = work / ("readme_" & $i & ".nim")
  writeFile(file, "import readme_stubs\n" & b & "\n")
  let (output, code) = execCmdEx("nim c --hints:off --warnings:off --threads:on -o:" &
                                 quoteShell(work / ("readme_" & $i)) & " " & quoteShell(file))
  if code != 0:
    inc failed
    echo "README block ", i, " does not compile:\n", output
  else: echo "README block ", i, ": ok"
if failed > 0: quit 1
