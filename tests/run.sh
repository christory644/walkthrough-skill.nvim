#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
for f in tests/test_*.lua; do
  echo "== $f"
  nvim --headless --clean -l "$f" || { fail=1; echo "  ^ FAILED"; }
done
[ "$fail" -eq 0 ] && echo "ALL TESTS PASSED" || echo "TESTS FAILED"
exit "$fail"
