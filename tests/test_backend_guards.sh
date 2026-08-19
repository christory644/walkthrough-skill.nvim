#!/usr/bin/env bash
# What backend_close refuses, that it refuses BEFORE the multiplexer is
# called, and what it REPORTS about what happened (#29).
#
# These are the rules every backend owes the user, so they are tested in one
# place across all of them rather than once per backend suite -- a new backend
# author has a single file to read and to extend.
#
# It is not defensive style. Measured on tmux 3.6a: `kill-window -t ''` killed
# the session's remaining window AND EXITED 0. The destructive case reports
# success, so nothing downstream can notice it happened. The cmux equivalent
# has never been characterised, and deliberately never will be -- there is no
# safe way to find out what `close-surface --surface ""` does to somebody's
# live session.
#
# Both multiplexer binaries are replaced by a recorder, so this needs neither
# cmux nor tmux and runs everywhere, including CI. Nothing is opened, focused
# or closed.
#
# Each case runs in a subshell that sets the environment the backend it sources
# expects (which binary to call, which surface is the caller, what the recorder
# should replay) and then exits. shellcheck sees the same NAMES set in two of
# those subshells and warns that one modification might be lost in the other --
# SC2030/SC2031. There is nothing to lose: no value set inside a case is read
# outside it, and the isolation is the point, since a case that leaked into the
# next would be one measuring the wrong stub. Disabled for the file, because
# the pattern is the file.
# shellcheck disable=SC2030,SC2031
set -u
cd "$(dirname "$0")/.." || exit 1

fail=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/rec" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$CALLS"
# The tmux guard asks which window the caller is in before refusing it, so the
# recorder has to answer. Without this the "refuses the caller" case would
# pass for the wrong reason: an empty answer matches nothing, so the guard
# would fall through and we would be measuring the stub.
case "$1" in display-message) printf '%s\n' "${STUB_CALLER:-}" ;; esac
exit 0
STUB
chmod +x "$TMP/rec"
export CALLS="$TMP/calls"

# $1 backend, $2 destructive verb, $3 caller handle, $4 a valid foreign handle
suite() {
  local backend="$1" verb="$2" caller="$3" valid="$4"
  echo "== $backend"

  close_with() { # $1 = handle -> prints rc, leaves the call log in $CALLS
    : > "$CALLS"
    (
      export STUB_CALLER="$caller"
      case "$backend" in
        cmux) export CMUX_BIN="$TMP/rec" CMUX_SURFACE_ID="$caller" ;;
        tmux) export TMUX_BIN="$TMP/rec" TMUX_PANE="%1" ;;
      esac
      . "./backends/common.sh"
      # shellcheck source=/dev/null
      . "./backends/$backend.sh"
      backend_close "$1" >/dev/null 2>&1
      echo $?
    )
  }

  refuses() { # $1 = label, $2 = handle
    local rc; rc="$(close_with "$2")"
    if [ "$rc" = 0 ]; then bad "$backend: $1 -- returned 0, it was accepted"; return; fi
    if grep -q -- "$verb" "$CALLS" 2>/dev/null; then
      bad "$backend: $1 -- refused, but still ran $verb [$(tr '\n' ';' < "$CALLS")]"
    else
      ok "$backend: $1 -- refused, and $verb was never run"
    fi
  }

  refuses "an empty handle"                 ""
  refuses "a whitespace handle"             "   "
  refuses "a malformed handle"              "not-a-handle"
  refuses "a positional ref"                "$5"
  refuses "a handle with a shell metachar"  "$valid; echo pwned"
  refuses "a handle with a newline"         "$(printf '%s\n%s' "$valid" "$caller")"
  refuses "the caller's own handle"         "$caller"

  # The positive control, and the reason the rest of this suite means
  # anything. Without it a backend_close that refuses EVERYTHING -- including
  # the tab the reader is trying to shut -- passes every assertion above.
  local rc; rc="$(close_with "$valid")"
  if [ "$rc" != 0 ]; then bad "$backend: a valid foreign handle was refused (rc=$rc)"
  elif ! grep -q -- "$verb" "$CALLS" 2>/dev/null; then
    bad "$backend: a valid foreign handle returned 0 but never ran $verb"
  else
    ok "$backend: a valid foreign handle IS closed ($verb was run)"
  fi
}

CALLER_UUID='AAAAAAAA-1111-2222-3333-444444444444'
OTHER_UUID='BBBBBBBB-5555-6666-7777-888888888888'
suite cmux close-surface "$CALLER_UUID" "$OTHER_UUID" "surface:19"
suite tmux kill-window   "@1"           "@7"          "session:1"

# ---------------------------------------------------------------------------
# The deliberate self-close bypass: $2 = "self" to backend_close, written at
# exactly one call site in the whole CLI -- bin/walkthrough's `_close_surface`
# dispatch arm, which exists only so <leader>aq can close the surface its own
# nvim is running in (see the "the caller's own handle" case in `suite` above,
# and the comment on backend_close in each backends/*.sh). This is the OTHER
# half of that guard's contract, and both halves have to hold for the fix to
# be correct rather than merely permissive:
#
#   * marked "self", the caller's own handle must now be CLOSED -- this is
#     the bug (#21): before the fix, <leader>aq's own call was refused by the
#     identical check that protects `cmd_close`, because the walkthrough's own
#     nvim inherits $CMUX_SURFACE_ID / a $TMUX_PANE resolving to the window it
#     runs in, so the handle it asks to close IS the caller's.
#   * unmarked, `cmd_close`'s protection must be untouched -- already covered
#     above by "the caller's own handle", which never passes "self" and must
#     keep refusing. That assertion is what makes this one mean anything: a
#     backend_close that ignored $2 entirely and always allowed the caller's
#     own handle would pass THIS suite while reopening the bug the guard
#     exists for.
self_close() { # $1 backend, $2 destructive verb, $3 caller handle
  local backend="$1" verb="$2" caller="$3" rc
  echo "== $backend: the deliberate self-close bypass"
  : > "$CALLS"
  rc="$(
    export STUB_CALLER="$caller"
    case "$backend" in
      cmux) export CMUX_BIN="$TMP/rec" CMUX_SURFACE_ID="$caller" ;;
      tmux) export TMUX_BIN="$TMP/rec" TMUX_PANE="%1" ;;
    esac
    . "./backends/common.sh"
    # shellcheck source=/dev/null
    . "./backends/$backend.sh"
    backend_close "$caller" self >/dev/null 2>&1
    echo $?
  )"
  if [ "$rc" != 0 ]; then
    bad "$backend: self-close of the caller's own handle was refused (rc=$rc), wanted 0"
  elif ! grep -q -- "$verb" "$CALLS" 2>/dev/null; then
    bad "$backend: self-close returned 0 but never ran $verb [$(tr '\n' ';' < "$CALLS")]"
  else
    ok "$backend: self-close (\$2=self) on the caller's own handle IS permitted ($verb was run)"
  fi
}
self_close cmux close-surface "$CALLER_UUID"
self_close tmux kill-window   "@1"

# ---------------------------------------------------------------------------
# What backend_close REPORTS (#29)
#
# `walkthrough close` runs long after the reader has usually closed the surface
# themselves, so "there was nothing to close" is the ordinary path -- and both
# multiplexers report it as a FAILURE. Measured, on the real things:
#
#   cmux  close-surface --surface <gone> -> 1, "Error: not_found: Surface not found"
#   tmux  kill-window   -t <gone>        -> 1, "can't find window: @1"
#
# So a backend cannot hand its multiplexer's status back, and cannot read
# "already gone" out of it either. It has to ask the inventory. The contract
# (backends/common.sh): 0 closed, 2 already gone, other non-zero attempted and
# possibly still open.
#
# The multiplexer is a recorder here, replaying those measured outputs, so this
# runs on CI where neither is installed. The live halves -- which is what makes
# the recorder's script the real thing rather than a story about it -- are in
# tests/test_backend_tmux.sh (self-hosts a tmux server, so CI runs it) and
# tests/test_backend_cmux.sh (needs a running cmux).
# ---------------------------------------------------------------------------
cat > "$TMP/mux" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$CALLS"
case "$1" in
  display-message) printf '%s\n' "${STUB_CALLER:-}"; exit 0 ;;
  close-surface|kill-window)
    [ "${STUB_CLOSE_RC:-0}" = 0 ] && { echo "OK surface:132 workspace:1"; exit 0; }
    case "$1" in
      close-surface) echo "Error: not_found: Surface not found" >&2 ;;
      kill-window)   echo "can't find window: $STUB_HANDLE" >&2 ;;
    esac
    exit 1 ;;
  # The inventories. `present` and `absent` differ only in whether the handle
  # is in the answer; `fail` is a multiplexer we could not interrogate at all,
  # and `noserver` is tmux's own words for a server that has gone away.
  tree)
    case "${STUB_INV:-absent}" in
      present)  printf 'surface %s [terminal] "x"\n' "$STUB_HANDLE" ;;
      absent)   printf 'surface %s [terminal] "x"\n' "$STUB_OTHER" ;;
      empty)    : ;;
      fail)     echo "Error: could not reach cmux" >&2; exit 1 ;;
      noserver) echo "Error: could not reach cmux" >&2; exit 1 ;;
    esac
    exit 0 ;;
  list-windows)
    case "${STUB_INV:-absent}" in
      present)  printf '%s\n' "$STUB_HANDLE" ;;
      absent)   printf '%s\n' "$STUB_OTHER" ;;
      empty)    : ;;
      fail)     echo "some other tmux failure" >&2; exit 1 ;;
      noserver) echo "no server running on /tmp/tmux-501/default" >&2; exit 1 ;;
    esac
    exit 0 ;;
esac
exit 0
STUB
chmod +x "$TMP/mux"

# $1 backend, $2 inventory verb, $3 caller handle, $4 a valid foreign handle,
# $5 another valid handle that is NOT the one being closed
reports() {
  local backend="$1" inv="$2" caller="$3" handle="$4" other="$5"
  echo "== $backend: what close reports"

  close_status() { # $1 = close rc to replay, $2 = inventory state -> prints rc
    : > "$CALLS"
    (
      export STUB_CALLER="$caller" STUB_HANDLE="$handle" STUB_OTHER="$other"
      export STUB_CLOSE_RC="$1" STUB_INV="$2"
      case "$backend" in
        cmux) export CMUX_BIN="$TMP/mux" CMUX_SURFACE_ID="$caller" ;;
        tmux) export TMUX_BIN="$TMP/mux" TMUX_PANE="%1" ;;
      esac
      . "./backends/common.sh"
      # shellcheck source=/dev/null
      . "./backends/$backend.sh"
      backend_close "$handle" >/dev/null 2>&1
      echo $?
    )
  }

  says() { # $1 = label, $2 = want rc, $3 = close rc, $4 = inventory
    local rc; rc="$(close_status "$3" "$4")"
    if [ "$rc" = "$2" ]; then ok "$backend: $1 -- reported $rc"
    else bad "$backend: $1 -- reported $rc, wanted $2"; fi
  }

  # 0 and 2 are BOTH success to the caller, and they are asserted apart on
  # purpose: a test that accepted either could not tell this contract from the
  # bug it replaced, which returned 0 for everything including a close that
  # never happened.
  says "the multiplexer closed it"                      0 0 present
  says "it was already gone"                            2 1 absent
  says "the close failed and the surface is still there" 1 1 present
  says "the close failed and the inventory is unreadable" 1 1 fail
  says "the close failed and the inventory came back empty" 1 1 empty

  # The inventory costs a round trip to the multiplexer and answers a question
  # nobody asked when the close worked. Asking anyway would also invite the
  # answer to contradict a close that succeeded.
  close_status 0 present >/dev/null
  if grep -q -- "$inv" "$CALLS" 2>/dev/null; then
    bad "$backend: the inventory was consulted after a close that SUCCEEDED"
  else
    ok "$backend: a successful close asks the multiplexer nothing further"
  fi
}

reports cmux tree         "$CALLER_UUID" "$OTHER_UUID" 'CCCCCCCC-9999-AAAA-BBBB-CCCCCCCCCCCC'
reports tmux list-windows "@1"           "@7"          '@8'

# tmux only: a server that is not running cannot be hiding our window, so that
# is `already gone` and not `cannot tell`. It is the reader quitting tmux
# outright with a walkthrough still recorded, and it must not be reported as a
# surface left open. cmux has no measured equivalent -- there is no safe way to
# take the user's terminal application away to find out -- so it stays under
# "cannot tell" there, which is the conservative half of the contract.
echo "== tmux: the whole server has gone away"
(
  export STUB_CALLER="@1" STUB_HANDLE="@7" STUB_OTHER="@8"
  export STUB_CLOSE_RC=1 STUB_INV=noserver TMUX_BIN="$TMP/mux" TMUX_PANE="%1"
  : > "$CALLS"
  . ./backends/common.sh
  . ./backends/tmux.sh
  backend_close "@7" >/dev/null 2>&1
  echo $?
) > "$TMP/noserver.rc"
if [ "$(cat "$TMP/noserver.rc")" = 2 ]; then
  ok "tmux: no server running is already gone, not a surface left open"
else
  bad "tmux: no server running reported $(cat "$TMP/noserver.rc"), wanted 2"
fi

[ "$fail" -eq 0 ] && echo "BACKEND GUARDS PASSED"
exit "$fail"
