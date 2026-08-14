# tmux backend. A window, not a split: a split would put the agent's
# conversation and the tour side by side, competing for attention.
#
# No shebang, deliberately: a backend is sourced by the CLI, never executed.
# The directive names the dialect for shellcheck without pretending otherwise.
# shellcheck shell=bash
TMUX_BIN="${TMUX_BIN:-$(command -v tmux || echo tmux)}"
# Is this a tmux window id -- @ followed by digits, the WHOLE of it and
# nothing else? NOT session:index: an index shifts as windows come and go,
# exactly like a cmux positional ref, and will eventually name someone else's
# window.
#
# Deliberately not `grep -qE '^@[0-9]+$'`, which is what the cmux backend used
# and what this was first written as. That reads as an anchored match and is
# not one: grep works a LINE at a time, so any value whose FIRST line is a
# well-formed id passes, and the rest of it is handed to tmux regardless.
# Handles are decoded from base64 in the CLI's state file, so a value carrying
# a newline can genuinely arrive here. `*[!0-9]*` is a whole-string test and
# rejects a newline along with everything else that is not a digit.
tmux_is_window_id() {
  case "$1" in @?*) ;; *) return 1 ;; esac
  case "${1#@}" in *[!0-9]*) return 1 ;; esac
  return 0
}

# ---------------------------------------------------------------------------
# Teardown, measured -- and it is NOT the cmux mechanism.
#
# The cmux backend positions its tab immediately LEFT of the caller because
# cmux selects the tab to the right when one closes. That trick has no
# analogue here, and copying it would have been cargo cult. tmux 3.6a,
# measured on a private server across a three-window session:
#
#   walkthrough inserted AFTER caller,  kill-window   -> lands on caller
#   walkthrough inserted BEFORE caller, kill-window   -> lands on caller
#   walkthrough inserted AFTER caller,  process exits -> lands on caller
#   walkthrough inserted BEFORE caller, process exits -> lands on caller
#   base-index 0, renumber-windows on                 -> lands on caller
#
# Every case landed on the caller, which is precisely the result that proves
# nothing on its own: "next window" and "previous window" both happen to BE
# the caller when the walkthrough is adjacent to it. So the hypothesis was
# tested where the rules disagree -- caller far away, and a DIFFERENT window
# visited most recently:
#
#   visit w4, then w1(caller); walkthrough after w4; close  -> lands on w1
#   visit w1, then w3;         walkthrough before w1; close -> lands on w3
#   caller w2, user wanders to w4 mid-tour, returns, close  -> lands on w4
#
# tmux selects the MOST RECENTLY USED window. Not a neighbour. So:
#
#   * Position is cosmetic here, not load-bearing. Nothing needs to be moved,
#     and a `move-window` copied from cmux.sh would be a lie about why it
#     works.
#   * The caller is by construction the most recently used window at the
#     moment the walkthrough is selected, so quitting returns there for free.
#   * Better than the cmux trick, it follows the user: wander off mid-tour and
#     quitting returns you where you actually were, not where you started.
#
# The last row is the one to keep in mind if this is ever "fixed" to be
# positional -- that would be a regression, and tests/test_backend_tmux.sh
# asserts it.
# ---------------------------------------------------------------------------

backend_open() {
  cmd="$1"
  [ -n "$cmd" ] || { echo "walkthrough: tmux backend given no command" >&2; return 1; }
  [ -n "${TMUX:-}" ] || {
    echo "walkthrough: the tmux backend needs to run inside tmux (\$TMUX is unset)." >&2
    return 1
  }

  # The caller's WINDOW. $TMUX_PANE is the reliable handle on "where the CLI
  # was invoked" -- the current window can change under us if the user
  # switches while this runs. Measured: new-window rejects a pane target
  # outright ("can't specify pane here"), so the pane is resolved to its
  # window first rather than passed through.
  if [ -n "${TMUX_PANE:-}" ]; then
    caller="$("$TMUX_BIN" display-message -p -t "$TMUX_PANE" '#{window_id}' 2>/dev/null)"
  else
    caller="$("$TMUX_BIN" display-message -p '#{window_id}' 2>/dev/null)"
  fi
  [ -n "$caller" ] || { echo "walkthrough: cannot identify the calling tmux window" >&2; return 1; }

  # Created detached, then selected -- the same shape as the cmux backend, and
  # the shape the teardown measurements above were taken against. `-a -t
  # <caller>` puts it next to where the reader was, which is a courtesy
  # rather than a mechanism (see above). `-n` names it so the window is not
  # just another `sh` in the status bar (#24); measured: passing -n turns
  # automatic-rename off for that window, so the name sticks.
  #
  # tmux runs this string through `default-shell` -- measured: ksh, zsh and
  # dash each ran it -- which is why wt_nvim_cmd quotes for a shell it does
  # not get to choose rather than with `printf %q` (#14).
  handle="$("$TMUX_BIN" new-window -d -P -F '#{window_id}' \
    -a -t "$caller" -n "$(wt_title_text)" "$cmd" 2>/dev/null)"
  tmux_is_window_id "$handle" || {
    echo "walkthrough: tmux did not return a window id (got: '$handle')" >&2
    return 1
  }

  "$TMUX_BIN" select-window -t "$handle" >/dev/null 2>&1
  echo "$handle"
}

backend_title() { # $1 = window id, $2 = text
  tmux_is_window_id "$1" || return 1
  "$TMUX_BIN" rename-window -t "$1" "$2" >/dev/null 2>&1
}

backend_close() {
  # Never hand tmux an empty or malformed target. This is not hypothetical:
  # measured on tmux 3.6a, `kill-window -t ''` killed the session's remaining
  # window and EXITED 0 -- the destructive case reports success. A bogus but
  # well-formed id (`@99999`) correctly exits 1, so only the empty and
  # malformed cases need catching here, and both are caught before tmux is
  # ever invoked.
  tmux_is_window_id "$1" || return 1

  # And never close the window we were called from. $TMUX_PANE belongs to the
  # session driving us; killing it takes the caller down with it.
  if [ -n "${TMUX_PANE:-}" ]; then
    self="$("$TMUX_BIN" display-message -p -t "$TMUX_PANE" '#{window_id}' 2>/dev/null)"
    [ "$1" = "$self" ] && {
      echo "walkthrough: refusing to close the calling window ($1)" >&2
      return 1
    }
  fi

  "$TMUX_BIN" kill-window -t "$1" >/dev/null 2>&1
  return 0
}
