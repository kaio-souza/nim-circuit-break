# Package

version       = "0.3.0"
author        = "Kaio Souza"
description   = "Circuit breaker for Nim: correct state machine, rate and slow-call policies, metrics, async and keyed breakers."
license       = "MIT"
srcDir        = "src"
skipDirs      = @["tests", "benchmarks", "examples", "scripts", "docs"]
# Tags are declared when publishing to nim-lang/packages (packages.json).

# Dependencies

requires "nim >= 2.2.4"

# Test-only: the model test (V2/Q5) uses proptest's stateful testing.
taskRequires "test", "https://github.com/kaio-souza/nim-proptest >= 0.2.0"

# Tasks

const benchFlags = "nim c -r -d:release --opt:speed --threads:on --hints:off --warnings:off "

task bench, "Run the benchmark suite (BM1-BM9)":
  # Timings with ORC (the default memory manager).
  for f in ["b_core", "b_window", "b_threads", "b_keyed"]:
    exec benchFlags & "--mm:orc benchmarks/" & f & ".nim"
  # Allocation counts with ARC: -d:nimAllocStats crashes ORC on re-raise in
  # Nim 2.2.4 (docs/upstream/repro_orc_allocstats.nim). Same allocations.
  for f in ["b_core", "b_window", "b_keyed"]:
    exec benchFlags & "--mm:arc -d:nimAllocStats benchmarks/" & f & ".nim"
  # N3: the same core suite compiled with -d:cbDisabled.
  exec benchFlags & "--mm:orc -d:cbDisabled benchmarks/b_core.nim"

task trace, "Check the traceability matrix (EV1/EV2)":
  exec "nim r --hints:off scripts/check_traceability.nim"

task doccheck, "Check that every exported symbol has a doc comment (D3)":
  exec "nim r --hints:off scripts/check_docs.nim"
