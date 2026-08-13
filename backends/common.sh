# Shared backend helpers. Sourced, never executed.
#
# No shebang, deliberately: this file is not a program. The directive below is
# how shellcheck is told which dialect to check it as — it is sourced by
# bin/walkthrough and by the test scripts, all of which are bash.
# shellcheck shell=bash

# cmux first: if both are present we are inside cmux running tmux, and the
# outer multiplexer owns the surface the user actually sees.
wt_detect_backend() {
  if [ -n "${WALKTHROUGH_BACKEND:-}" ]; then echo "$WALKTHROUGH_BACKEND"; return; fi
  if [ -n "${CMUX_SURFACE_ID:-}" ]; then echo "cmux"; return; fi
  if [ -n "${TMUX:-}" ]; then echo "tmux"; return; fi
  echo "none"
}

# Only cmux ships in v0.1. Anything else must say so plainly: a half-working
# fallback is worse than a clear refusal, because the user cannot tell the
# difference between "unsupported" and "broken".
wt_require_backend() {
  name="$1"
  root="${WALKTHROUGH_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)}"
  if [ ! -f "$root/backends/$name.sh" ]; then
    echo "walkthrough: no backend for '$name'." >&2
    echo "  v0.1 supports cmux. Adding a backend is one file:" >&2
    echo "  backends/$name.sh defining backend_open and backend_close." >&2
    echo "  Override detection with WALKTHROUGH_BACKEND." >&2
    return 1
  fi
  return 0
}

# Readiness is the socket, never the shell prompt: a slow or broken shell rc
# can leave a terminal that never reaches a prompt at all.
wt_wait_for_socket() {
  sock="$1"; tries="${2:-60}"
  i=0
  while [ "$i" -lt "$tries" ]; do
    if nvim --server "$sock" --remote-expr '1' >/dev/null 2>&1; then return 0; fi
    i=$((i + 1))
  done
  return 1
}

# base64 is the armour for every value that has to cross into another language
# (see the threat model at the top of bin/walkthrough). Encoding strips the
# newlines GNU/BSD base64 insert at 76 columns so a value is always exactly one
# token on one line. Defined here rather than in the CLI because the launch
# command built below needs it too, and the two must not disagree about the
# encoding.
wt_b64() { printf %s "$1" | base64 | tr -d '\n'; }

wt_nvim_cmd() { # $1=workspace root, $2=socket, rest=files
  cwd="$1"; sock="$2"; shift 2
  # --cmd pins the player's working directory to the workspace root the tour's
  # `file` entries are relative to (see wt_workspace_root in bin/walkthrough).
  # The terminal the backend spawns starts in whatever directory it likes, so
  # without this the player resolves every relative step against a stranger's
  # directory — silently opening a same-named file if one happens to be there,
  # and reporting every step as missing if not.
  #
  # --cmd, not a shell `cd` in front of nvim and not a late `:cd`: it runs
  # before the user's config is sourced and before any buffer is read, so
  # plugins, LSP root detection and the tour all see one cwd from the first
  # line of startup — and the directory crosses as base64, so it cannot
  # terminate a quote in the shell, in vimscript or in Lua on the way.
  #
  # SessionDisableAutoSave: the player is a throwaway editor and must not let a
  # session manager persist its state over the user's own sessions.
  printf "nvim --cmd \"lua vim.fn.chdir(vim.base64.decode('%s'))\" -c 'silent! SessionDisableAutoSave' --listen %s" \
    "$(wt_b64 "$cwd")" "$sock"
  for f in "$@"; do printf " %s" "$(printf %q "$f")"; done
}
