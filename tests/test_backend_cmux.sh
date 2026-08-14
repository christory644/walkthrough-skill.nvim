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
# The two `cmux tree` parses live in their own file, where fixture text can be
# fed through them on a machine with no cmux at all. They used to be defined
# here, which meant nothing ever checked them: this suite skips outside cmux,
# so CI never ran a line of the parse that decides its verdict (#20).
#
# source=/dev/null: that file runs its own fixtures when EXECUTED and returns
# early when sourced. shellcheck cannot tell the two apart, so it follows the
# file to its `exit` and then reports everything below here as unreachable.
# shellcheck source=/dev/null
. ./tests/test_backend_cmux_parse.sh

UUID='[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}'
CM="$(command -v cmux || echo /Applications/cmux.app/Contents/Resources/bin/cmux)"

cmux_tree() { "$CM" tree --id-format uuids 2>/dev/null; }

# The FOCUSED surface is the one marked "◀ active". Not "◀ here", which marks
# the surface this script itself runs in (the caller) and never moves — reading
# that marker instead would make every focus assertion below a tautology.
#
# Scoped to the current window's selected workspace. The old parse latched on
# at the first selected workspace and never let go, so it went on matching
# through every later workspace AND every later cmux window; with two cmux
# windows open it answered with a surface from the wrong one.
active()    { cmux_tree | cmux_tree_active; }

# Tab order of the selected workspace, left to right.
tab_order() { cmux_tree | cmux_tree_order; }

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

# Say what focus was ACTUALLY on when an assertion fails, and name the one
# explanation that is not a bug in this repository.
#
# Focus is a single global property of the terminal. This suite holds the cmux
# lease (docs/parallel-work.md), but a lease only excludes sessions that take
# it -- anything else on the machine that opens, closes or selects a surface
# flips the verdict. Observed once during development: a focus assertion here
# failed on a surface belonging to neither the walkthrough nor the caller, and
# did not reproduce on the next three runs.
#
# A bare "focus did not move" sends the reader looking for a bug in the
# backend. Naming the third surface tells them, in the one line they will
# read, that the run was disturbed rather than the code broken.
focus_failure() { # $1 = what we wanted, $2 = human name for it
  got="$(active)"
  echo "FAIL: focus did not $2 (wanted $1)"
  echo "      focus was actually on: ${got:-<nothing parsed>}"
  case "$got" in
    "$handle"|"$CMUX_SURFACE_ID"|"") ;;
    *) echo "      That is neither the walkthrough tab nor the caller. Another"
       echo "      session very likely took focus mid-run -- focus is global and"
       echo "      the lease only excludes sessions that take it. Re-run before"
       echo "      believing this. See docs/parallel-work.md." ;;
  esac
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
wait_active "$handle" || { focus_failure "$handle" "move to the walkthrough tab"; fail=1; }

# #24 — the tab must be labelled, not left showing its working directory like
# any other shell. Polled, not slept on: cmux applies the rename
# asynchronously, and the shell and nvim both emit their own title sequences
# as they start, so this also proves the label is not immediately overwritten
# by whatever comes up in the tab.
want_title="$(wt_title_text)"
i=0
while [ "$i" -lt 25 ]; do
  [ "$(cmux_tree | cmux_tree_title "$handle")" = "$want_title" ] && break
  sleep 0.2; i=$((i + 1))
done
got_title="$(cmux_tree | cmux_tree_title "$handle")"
if [ "$got_title" = "$want_title" ]; then
  echo "  ok: the walkthrough tab is labelled '$got_title'"
else
  echo "FAIL: tab is labelled '$got_title', not '$want_title'"; fail=1
fi

# The property this test exists for. cmux selects the tab to the RIGHT of a
# closed tab. That is undocumented behaviour we depend on and cannot correct
# for, so a future cmux that changes it must break the build here rather than
# quietly stranding users on a stranger's tab every time they quit a tour.
backend_close "$handle"
wait_active "$CMUX_SURFACE_ID" || { focus_failure "$CMUX_SURFACE_ID" "return to the caller"; fail=1; }

rm -f "$SOCK"
[ "$fail" -eq 0 ] && echo "CMUX BACKEND PASSED"
exit "$fail"
