# cmux backend. A tab (surface), not a split: a split would put the agent's
# conversation and the tour side by side, competing for attention.
#
# No shebang, deliberately: a backend is sourced by the CLI, never executed.
# The directive names the dialect for shellcheck without pretending otherwise.
# shellcheck shell=bash
CMUX_BIN="${CMUX_BIN:-$(command -v cmux || echo /Applications/cmux.app/Contents/Resources/bin/cmux)}"
CMUX_UUID_RE='[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}'

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

  "$CMUX_BIN" send --surface "$handle" "$cmd" >/dev/null 2>&1
  "$CMUX_BIN" send-key --surface "$handle" enter >/dev/null 2>&1
  echo "$handle"
}

backend_close() {
  # Never hand cmux an empty or malformed surface argument. What cmux does
  # with `close-surface --surface ""` is undetermined, and the standing rule
  # is to never risk closing a surface we did not create.
  echo "$1" | grep -qE "^$CMUX_UUID_RE\$" || return 1
  "$CMUX_BIN" close-surface --surface "$1" >/dev/null 2>&1
  return 0
}
