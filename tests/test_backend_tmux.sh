#!/usr/bin/env bash
# tmux backend, exercised for real: open a window, wait for the socket, assert
# focus MOVED there, close it, assert focus RETURNED to the caller.
#
# Why the transition and not just the endpoint. An earlier version of the cmux
# suite asserted only "focus is on the caller afterwards", which cannot fail --
# the caller is already focused when the test starts, so the assertion is true
# before the code under test runs. Both halves are asserted here for the same
# reason.
#
# Why no mutex, when the cmux suite takes one. cmux focus is a single global
# property of the terminal application, so a second session opening a surface
# anywhere flips this suite's verdict. tmux focus is a property of a tmux
# SESSION: this suite only ever selects windows in the session it is running
# in, and CI runs it on a private server. That is a real difference in the
# resource, not an optimisation -- see docs/parallel-work.md.
set -u
cd "$(dirname "$0")/.." || exit 1

. ./backends/common.sh
. ./backends/tmux.sh

# Not inside tmux? If tmux is installed, re-run inside a PRIVATE server rather
# than skipping.
#
# The cmux suite has no choice but to skip: cmux is a terminal application
# that has to be running. tmux has no such requirement -- `-L <name>` starts a
# server of its own that shares nothing with any tmux the user is running, so
# the whole suite can be exercised on a headless runner. CI has tmux, and a
# backend CI never runs is a backend nobody notices breaking, which is the
# same argument the cmux SKIP guard is kept in CI for.
#
# Only a machine with no tmux at all skips. Set WALKTHROUGH_TMUX_SELFHOST=0 to
# get the plain skip instead.
if [ -z "${TMUX:-}" ]; then
  command -v tmux >/dev/null 2>&1 || { echo "SKIP: tmux not installed"; exit 0; }
  [ "${WALKTHROUGH_TMUX_SELFHOST:-1}" = 1 ] || { echo "SKIP: not inside tmux"; exit 0; }

  srv="wt-selfhost-$$"
  sh_out="$(mktemp)"; sh_rc="$(mktemp)"
  trap 'tmux -L "$srv" kill-server >/dev/null 2>&1; rm -f "$sh_out" "$sh_rc"' EXIT
  tmux -L "$srv" kill-server >/dev/null 2>&1

  # Neighbours on both sides of the caller, so "focus returned to the caller"
  # has somewhere else it could plausibly have landed. A single-window session
  # would make that assertion true by having no alternative.
  tmux -L "$srv" new-session -d -s wt -n left 'sleep 600' 2>/dev/null
  tmux -L "$srv" new-window -d -t wt: -n caller 'sh' >/dev/null 2>&1
  tmux -L "$srv" new-window -d -t wt: -n right 'sleep 600' >/dev/null 2>&1
  cw="$(tmux -L "$srv" list-windows -t wt: -F '#{window_id} #{window_name}' \
        | awk '$2=="caller"{print $1}')"
  [ -n "$cw" ] || { echo "FAIL: could not build a self-hosted tmux session"; exit 1; }
  tmux -L "$srv" select-window -t "$cw" >/dev/null 2>&1

  echo "(not inside tmux: re-running inside a private tmux server -L $srv)"
  # wt_shquote, not printf %q: the receiving shell is whatever tmux's
  # default-shell is, which is the entire point of #14.
  tmux -L "$srv" send-keys -t "$cw" \
    "cd $(wt_shquote "$PWD") && ./tests/test_backend_tmux.sh > $(wt_shquote "$sh_out") 2>&1; echo \$? > $(wt_shquote "$sh_rc")" Enter

  i=0
  while [ ! -s "$sh_rc" ] && [ "$i" -lt 180 ]; do sleep 1; i=$((i + 1)); done
  cat "$sh_out"
  status="$(cat "$sh_rc" 2>/dev/null)"
  [ -n "$status" ] || { echo "  FAIL: the self-hosted run never finished"; status=1; }
  exit "$status"
fi

TM="$(command -v tmux || echo tmux)"
WINRE='@[0-9]+'
fail=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fail=1; }

# The FOCUSED window is the session's active one. Measured trap, and it is the
# mirror image of the cmux suite's `◀ here` vs `◀ active`: here it is
# `display-message -t "$TMUX_PANE"` that names the CALLER and never moves,
# while window_active tracks focus. Reading the first would make every
# assertion below a tautology.
focused() { "$TM" list-windows -F '#{window_id} #{?window_active,A,-}' \
              | awk '$2=="A"{print $1; exit}'; }
caller()  { "$TM" display-message -p -t "$TMUX_PANE" '#{window_id}'; }
windows() { "$TM" list-windows -F '#{window_id}' | sort | tr '\n' ' '; }

# tmux applies selection asynchronously, so poll rather than sleep: this
# returns the instant focus lands and spends its budget only when the property
# is genuinely broken.
wait_focus() {
  want="$1"; i=0
  while [ "$i" -lt 25 ]; do
    [ "$(focused)" = "$want" ] && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

CALLER="$(caller)"
BEFORE="$(windows)"
SOCK="${TMPDIR:-/tmp}/wt-tmux-$$.sock"; rm -f "$SOCK"
handle=""
# Invoked by the EXIT trap below. Static analysis cannot see through a trap, and
# the complaint arrives under a DIFFERENT CODE depending on the version: 0.11.0
# files it as SC2329, older builds as SC2317 ("unreachable"). Both are silenced,
# because silencing one is how this passed locally and reddened CI. No comment
# line here may begin with the word shellcheck -- 0.10.0 reads such a line as a
# malformed directive and fails the file outright, which 0.11.0 does not.
# shellcheck disable=SC2329,SC2317
cleanup() {
  [ -n "$handle" ] && "$TM" kill-window -t "$handle" 2>/dev/null
  rm -f "$SOCK"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
echo "== open"
handle="$(backend_open "$(wt_nvim_cmd "$PWD" "$SOCK" tests/fixtures/alpha.txt)")"
if echo "$handle" | grep -qE "^$WINRE$"; then
  ok "handle is a window id ($handle)"
else
  # Diagnosed here rather than in a second `case` after the fact: this branch
  # exits, so anything downstream of it would be unreachable and would look
  # like an assertion while never being one.
  case "$handle" in
    *:*) bad "handle is a session:index ref ('$handle'). An index shifts as windows come and go and will eventually name a window we did not create -- the same defect as a cmux positional ref." ;;
    *)   bad "handle is not a window id: '$handle'" ;;
  esac
  rm -f "$SOCK"; exit 1
fi

wt_wait_for_socket "$SOCK" 300 || bad "nvim never came up"

if wait_focus "$handle"; then ok "focus moved to the walkthrough window"
else bad "focus did not move to the walkthrough window"; fi

# #24 -- the window must not read as just another shell in the status bar.
name="$("$TM" display-message -p -t "$handle" '#{window_name}')"
if [ "$name" = "$(wt_title_text)" ]; then ok "window is labelled '$name'"
else bad "window is labelled '$name', not '$(wt_title_text)'"; fi
auto="$("$TM" show-options -w -t "$handle" automatic-rename 2>/dev/null)"
case "$auto" in
  *off*) ok "automatic-rename is off, so the label survives" ;;
  *)     bad "automatic-rename is [$auto]; the label will be overwritten" ;;
esac

# ---------------------------------------------------------------------------
echo "== close"
# The property this suite exists for. tmux selects the MOST RECENTLY USED
# window when one closes -- measured, and unlike cmux, which selects the
# neighbour to the right. The caller is the most recently used window at this
# point, so it gets focus back with no focus call, which matters because a
# process cannot talk to tmux after its own window is gone.
backend_close "$handle"
if wait_focus "$CALLER"; then ok "focus returned to the caller"
else bad "focus did not return to the caller (landed on $(focused))"; fi

if [ "$(windows)" = "$BEFORE" ]; then ok "the window set is unchanged"
else bad "orphan or casualty: before [$BEFORE] after [$(windows)]"; fi
handle=""

# ---------------------------------------------------------------------------
# Teardown follows the READER, not the starting point. This is the row that
# distinguishes most-recently-used from any positional rule, and it is the one
# that would break first if someone "fixed" this backend to copy cmux's
# move-before-the-caller trick.
echo "== close, after the reader wandered off mid-tour"
away="$("$TM" new-window -d -P -F '#{window_id}' -n wt-elsewhere 'sleep 60')"
h2="$(backend_open "$(wt_nvim_cmd "$PWD" "$SOCK" tests/fixtures/alpha.txt)")"
wait_focus "$h2" || bad "focus did not move to the second walkthrough window"
"$TM" select-window -t "$away" >/dev/null 2>&1   # the reader wanders
wait_focus "$away" || bad "could not move focus away"
"$TM" select-window -t "$h2" >/dev/null 2>&1     # ...and comes back
wait_focus "$h2" || bad "could not return focus to the tour"
backend_close "$h2"
if wait_focus "$away"; then ok "teardown lands where the reader actually was"
else bad "landed on $(focused), expected the wandered-to window $away"; fi
"$TM" kill-window -t "$away" 2>/dev/null

# What backend_close REFUSES is not tested here. It is the same rule for every
# backend, it needs no multiplexer to check, and duplicating it per suite means
# two places to update and one of them going stale -- see
# tests/test_backend_guards.sh, which runs everywhere including CI.
#
# What belongs here is the live half: a well-formed id for a window that no
# longer exists must be tmux's problem, not ours. It is indistinguishable from
# a window the reader closed a moment before teardown ran, which is a race
# that happens in ordinary use.
echo "== a valid id for a window that is already gone"
before_stale="$(windows)"
backend_close "@99999" >/dev/null 2>&1
if [ "$(windows)" = "$before_stale" ]; then ok "a stale id harms nothing"
else bad "a stale id changed the window set: [$before_stale] -> [$(windows)]"; fi

[ "$fail" -eq 0 ] && echo "TMUX BACKEND PASSED"
exit "$fail"
