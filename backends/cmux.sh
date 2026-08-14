# cmux backend. A tab (surface), not a split: a split would put the agent's
# conversation and the tour side by side, competing for attention.
#
# No shebang, deliberately: a backend is sourced by the CLI, never executed.
# The directive names the dialect for shellcheck without pretending otherwise.
# shellcheck shell=bash
CMUX_BIN="${CMUX_BIN:-$(command -v cmux || echo /Applications/cmux.app/Contents/Resources/bin/cmux)}"
CMUX_UUID_RE='[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}'

# Is this a surface UUID -- the WHOLE of it, and nothing else?
#
# Deliberately not `grep -qE "^$CMUX_UUID_RE\$"`, which is what this used to
# be. That reads as an anchored match and is not one: grep works a LINE at a
# time, so any value whose FIRST line is a well-formed UUID passes, and the
# rest of it is handed to cmux regardless. Handles are decoded from base64 in
# the CLI's state file, so a value carrying a newline is one that can actually
# turn up here rather than a thought experiment.
#
# The first pattern pins the length and the dash positions; the second rejects
# every character outside the alphabet, a newline included. Both match the
# whole string, which is the property `grep` could not give.
cmux_is_surface_id() {
  case "$1" in ????????-????-????-????-????????????) ;; *) return 1 ;; esac
  case "$1" in *[!0-9A-F-]*) return 1 ;; esac
  return 0
}

backend_open() {
  cmd="$1"
  caller="${CMUX_SURFACE_ID:?cmux backend requires CMUX_SURFACE_ID}"

  # UUIDs only. Positional refs (surface:19) are indexes that shift as tabs are
  # created and destroyed, and will eventually close an unrelated tab.
  handle="$("$CMUX_BIN" new-surface --type terminal --focus false --id-format uuids \
    | grep -oE "$CMUX_UUID_RE" | head -1)"
  [ -n "$handle" ] || return 1

  # Position immediately LEFT of the caller. cmux selects the tab to the right
  # when one closes, so this returns the user to where they came from with no
  # focus call at teardown — which matters because a process cannot talk to cmux
  # after its own surface is gone (the socket dies with it).
  "$CMUX_BIN" move-surface --surface "$handle" --before "$caller" >/dev/null 2>&1
  "$CMUX_BIN" rpc surface.focus "{\"surface_id\":\"$handle\"}" >/dev/null 2>&1

  # Label it before the shell in it has said anything (#24). Untitled, the tab
  # showed its working directory and was indistinguishable from a terminal the
  # user had opened themselves -- found by live use, when the owner lost track
  # of which tab the walkthrough was in.
  backend_title "$handle" "$(wt_title_text)"

  "$CMUX_BIN" send --surface "$handle" "$cmd" >/dev/null 2>&1
  "$CMUX_BIN" send-key --surface "$handle" enter >/dev/null 2>&1
  echo "$handle"
}

backend_title() { # $1 = surface uuid, $2 = text
  cmux_is_surface_id "$1" || return 1
  "$CMUX_BIN" rename-tab --surface "$1" "$2" >/dev/null 2>&1
}

# Is this surface still one cmux knows about? Prints present / absent /
# unknown -- see the backend_close contract in backends/common.sh.
#
# `--all`, because the tab can be dragged into another cmux window and a tree
# scoped to the current one would then call a live surface absent. Measured:
# `tree` lists a surface right up to the moment it closes and never after, and
# a uuid is 36 characters of fixed shape, so a substring match cannot land
# inside a different id.
#
# Output that cannot be read is `unknown`, never `absent`. An empty tree is the
# same: cmux always has at least the surface we are running in, so nothing at
# all means we did not reach cmux rather than that cmux has nothing.
cmux_surface_state() { # $1 = surface uuid
  local tree
  tree="$("$CMUX_BIN" tree --all --id-format uuids 2>/dev/null)" \
    || { echo unknown; return 0; }
  [ -n "$tree" ] || { echo unknown; return 0; }
  case "$tree" in
    *"$1"*) echo present ;;
    *)      echo absent  ;;
  esac
}

backend_close() {
  # Never hand cmux an empty or malformed surface argument. `--surface` is an
  # OPTIONAL flag (`cmux close-surface --help`), so an empty one does not fail
  # -- it falls through to whatever cmux considers the current surface and
  # closes that. This is not theoretical caution: the tmux backend's
  # equivalent was measured, and `kill-window -t ''` there killed the
  # session's remaining window and exited 0 -- the destructive case reporting
  # success.
  cmux_is_surface_id "$1" || return 1

  # And never the caller's own surface. $CMUX_SURFACE_ID is the tab the
  # session driving us is running in; closing it kills that session mid-call.
  # A well-formed UUID is not enough of a check when it is THAT UUID.
  if [ -n "${CMUX_SURFACE_ID:-}" ] && [ "$1" = "$CMUX_SURFACE_ID" ]; then
    echo "walkthrough: refusing to close the calling surface ($1)" >&2
    return 1
  fi

  # Measured (cmux CLI shipped in /Applications/cmux.app, 2026-08), against a
  # surface this backend had created moments before:
  #
  #   --surface <live>                 -> 0, "OK surface:132 workspace:1"
  #   --surface <closed a moment ago>  -> 1, "Error: not_found: Surface not found"
  #   --surface <never existed>        -> 1, the same message
  #
  # so the status says "failed" for the ordinary case where the reader had
  # already closed the tab. It is the tree that can tell those apart.
  if "$CMUX_BIN" close-surface --surface "$1" >/dev/null 2>&1; then
    return 0
  fi
  case "$(cmux_surface_state "$1")" in
    absent) return 2 ;;   # nothing to close -- see backends/common.sh
    *)      return 1 ;;   # still there, or we could not find out
  esac
}
