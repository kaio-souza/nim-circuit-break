#!/usr/bin/env bash
# v1.0 criterion 4: run a test binary many times and report the first failure
# with its full output. Usage: repeat_tests.sh <test.nim> <runs> [nim flags...]
set -u
test_file=$1; runs=$2; shift 2
bin_dir=$(mktemp -d)
nim c --hints:off --threads:on "$@" -o:"$bin_dir/t" "$test_file" || exit 2
for i in $(seq 1 "$runs"); do
  if ! out=$("$bin_dir/t" 2>&1); then
    echo "FAILED on run $i of $runs ($test_file)"; echo "$out"; exit 1
  fi
done
echo "$test_file: $runs runs, 0 failures"
