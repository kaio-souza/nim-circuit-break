#!/usr/bin/env bash
# Q7: line coverage of src/ by the test suite, as a Markdown summary on stdout.
# Each test is built with gcc --coverage into its own nimcache, run once, and
# the per-test lcov captures are merged. Needs gcc and lcov.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
cd "$root"
# lcov 2.x needs these to accept Nim's generated C; lcov 1.x rejects them.
lcov_opts=()
if lcov --version | grep -qE 'version 2\.'; then
  lcov_opts=(--rc geninfo_unexecuted_blocks=1 --ignore-errors mismatch,gcov,source,inconsistent)
  merge_opts=(--ignore-errors inconsistent)
else
  merge_opts=()
fi
captures=()
for f in tests/t_*.nim; do
  name=$(basename "$f" .nim)
  [ "$name" = t_chronos ] && continue   # needs the optional dependency
  nim c -r --hints:off --warnings:off --threads:on --mm:orc --lineDir:on \
    --passC:--coverage --passL:--coverage --nimcache:"$work/nc_$name" \
    -o:"$work/$name" "$f" > "$work/$name.log" 2>&1 || { cat "$work/$name.log" >&2; exit 1; }
  lcov --quiet --capture --directory "$work/nc_$name" --output-file "$work/$name.info" \
    ${lcov_opts[@]+"${lcov_opts[@]}"} 2>/dev/null
  captures+=(--add-tracefile "$work/$name.info")
done
lcov --quiet "${captures[@]}" --output-file "$work/all.info" ${merge_opts[@]+"${merge_opts[@]}"}
lcov --quiet --extract "$work/all.info" "$root/src/*" --output-file "$work/src.info"
echo "## Coverage of src/"
echo
echo '```'
lcov --list "$work/src.info" 2>/dev/null
echo '```'
