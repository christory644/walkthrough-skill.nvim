#!/usr/bin/env bash
# What backend_close refuses, and that it refuses BEFORE the multiplexer is
# called.
#
# This is one rule every backend owes the user, so it is tested in one place
# across all of them rather than once per backend suite -- a new backend
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

[ "$fail" -eq 0 ] && echo "BACKEND GUARDS PASSED"
exit "$fail"
