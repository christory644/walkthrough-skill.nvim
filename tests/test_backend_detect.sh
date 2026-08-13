#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.." || exit 1
. ./backends/common.sh

fail=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  ok: $1"; else echo "  FAIL: $1 (want $2, got $3)"; fail=1; fi
}

# Each case sets the whole environment detection looks at, so a variable that
# happens to be set in the developer's own terminal cannot decide the result.
# The empty ones are written VAR='' rather than VAR=: identical to the shell,
# and unambiguous to a reader (and to shellcheck, which reads a bare `VAR= cmd`
# as a likely typo for `VAR=cmd`).
check "explicit override wins" "tmux" \
  "$(WALKTHROUGH_BACKEND=tmux CMUX_SURFACE_ID=x wt_detect_backend)"
check "cmux detected"         "cmux" \
  "$(WALKTHROUGH_BACKEND='' CMUX_SURFACE_ID=abc TMUX='' wt_detect_backend)"
check "tmux detected"         "tmux" \
  "$(WALKTHROUGH_BACKEND='' CMUX_SURFACE_ID='' TMUX=/tmp/x,1,0 wt_detect_backend)"
check "cmux wins over tmux"   "cmux" \
  "$(WALKTHROUGH_BACKEND='' CMUX_SURFACE_ID=abc TMUX=/tmp/x,1,0 wt_detect_backend)"
check "unknown terminal"      "none" \
  "$(WALKTHROUGH_BACKEND='' CMUX_SURFACE_ID='' TMUX='' wt_detect_backend)"

# a detected-but-unimplemented backend must fail loudly, not half-work
( . ./backends/common.sh; wt_require_backend tmux ) >/dev/null 2>&1
check "unimplemented backend errors" "1" "$?"

[ "$fail" -eq 0 ] && echo "BACKEND DETECT PASSED"
exit "$fail"
