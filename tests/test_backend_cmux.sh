#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.." || exit 1
[ -n "${CMUX_SURFACE_ID:-}" ] || { echo "SKIP: not inside cmux"; exit 0; }

# This test asserts that focus MOVED to the surface it opened and RETURNED when
# it closed. Focus is one global property of the terminal, so a second session
# opening or closing a surface mid-run flips those assertions and the test
# reports a confident wrong answer. Take the mutex here rather than asking every
# caller to remember: a safety rule nothing enforces is a safety rule that holds
# right up until the day it matters. Skipping runs never reach this, so a
# machine without cmux waits for nothing.
if [ -z "${WALKTHROUGH_CMUX_LOCK_HELD:-}" ]; then
  export WALKTHROUGH_CMUX_LOCK_HELD=1
  exec ./scripts/with-lock cmux "$0" "$@"
fi

. ./backends/common.sh
. ./backends/cmux.sh

UUID='[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}'
CM="$(command -v cmux || echo /Applications/cmux.app/Contents/Resources/bin/cmux)"

cmux_tree() { "$CM" tree --id-format uuids 2>/dev/null; }

# The FOCUSED surface is the one marked "◀ active". Not "◀ here", which marks
# the surface this script itself runs in (the caller) and never moves — reading
# that marker instead would make every focus assertion below a tautology.
active() {
  cmux_tree \
    | awk '/workspace .*\[selected\]/{w=1} w && /surface/ && /◀ active/{print; exit}' \
    | grep -oE "$UUID" | head -1
}

# Tab order of the selected workspace, left to right.
tab_order() {
  cmux_tree \
    | awk '/workspace .*\[selected\]/{w=1; next} /workspace /{if (w) exit} w && /surface/{print}' \
    | grep -oE "$UUID" | tr '\n' ' '
}

# cmux applies focus asynchronously, so focus is polled, never slept on: this
# returns the instant focus lands and spends its full budget only when the
# property is genuinely broken. A fixed sleep would be both slower and a
# coin flip.
wait_active() {
  want="$1"; i=0
  while [ "$i" -lt 25 ]; do
    [ "$(active)" = "$want" ] && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

SOCK="${TMPDIR:-/tmp}/wt-cmux-$$.sock"; rm -f "$SOCK"
handle=$(backend_open "$(wt_nvim_cmd "$PWD" "$SOCK" tests/fixtures/alpha.txt)")

fail=0
echo "$handle" | grep -qE "^$UUID$" || { echo "FAIL: handle is not a uuid"; rm -f "$SOCK"; exit 1; }
wt_wait_for_socket "$SOCK" 300 || { echo "FAIL: nvim never came up"; fail=1; }

# Our half of the teardown contract: the walkthrough tab must sit immediately
# LEFT of the caller. Teardown cannot issue a focus call to correct a bad
# position — the cmux socket dies with the surface — so placement is the only
# lever, and it has to be right before the tab is ever closed.
tab_order | grep -qF "$handle $CMUX_SURFACE_ID" \
  || { echo "FAIL: walkthrough tab is not immediately left of the caller"; fail=1; }

# Opening must genuinely move focus onto the walkthrough tab. Without this the
# post-close assertion is vacuous: if focus never left the caller, "focus is on
# the caller" afterwards is true for the wrong reason and proves nothing.
wait_active "$handle" || { echo "FAIL: focus did not move to walkthrough tab"; fail=1; }

# The property this test exists for. cmux selects the tab to the RIGHT of a
# closed tab. That is undocumented behaviour we depend on and cannot correct
# for, so a future cmux that changes it must break the build here rather than
# quietly stranding users on a stranger's tab every time they quit a tour.
backend_close "$handle"
wait_active "$CMUX_SURFACE_ID" || { echo "FAIL: focus did not return to caller"; fail=1; }

rm -f "$SOCK"
[ "$fail" -eq 0 ] && echo "CMUX BACKEND PASSED"
exit "$fail"
