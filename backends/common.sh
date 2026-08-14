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

# Where this checkout lives.
#
# POSIX sh has no BASH_SOURCE, and the expansion this used to use --
# ${BASH_SOURCE[0]:-$0} -- is not merely unavailable under dash but a fatal
# `Bad substitution`. The damage was not the error line: the failed expansion
# left `root` empty, so the refusal that followed named a backend that was
# sitting right there on disk. The helper's failure to find ITSELF was reported
# as the user's terminal being unsupported, which sends the reader to fix
# something that was never wrong.
#
# So: candidates in order of authority, and -- the part that matters -- a
# DIFFERENT refusal when none of them is a walkthrough checkout at all.
wt_root() {
  if [ -n "${WALKTHROUGH_ROOT:-}" ]; then printf '%s\n' "$WALKTHROUGH_ROOT"; return 0; fi

  # ${BASH_SOURCE[0]} is array syntax, which dash cannot expand at all. `eval`
  # keeps it out of dash's way (the string is only ever parsed by a shell that
  # understands it), while bash still resolves it to the file the function was
  # DEFINED in -- this one -- which is the whole reason to prefer it over $0.
  _wt_src=''
  if [ -n "${BASH_VERSION:-}" ]; then
    _wt_src="$(eval 'printf %s "${BASH_SOURCE[0]:-}"' 2>/dev/null)"
  fi
  [ -n "$_wt_src" ] || _wt_src="$0"

  # $0 is only a path when it contains a slash. Under `dash -c` it is the
  # string "dash", and dirname would hand back "." -- a plausible-looking
  # answer that is simply the caller's directory wearing a disguise.
  case "$_wt_src" in
    */*) _wt_cand="$(CDPATH='' cd -- "$(dirname -- "$_wt_src")/.." 2>/dev/null && pwd)" ;;
    *)   _wt_cand='' ;;
  esac
  if [ -n "$_wt_cand" ] && [ -d "$_wt_cand/backends" ]; then
    printf '%s\n' "$_wt_cand"; return 0
  fi

  # Last resort: the caller is standing in the checkout. This is what makes
  # `sh -c '. ./backends/common.sh; ...'` work in a shell that cannot introspect
  # its own source file.
  if [ -d "$PWD/backends" ]; then printf '%s\n' "$PWD"; return 0; fi
  return 1
}

# The backends actually present, one per line. Read off the disk rather than
# hard-coded, so a refusal cannot go stale the moment a backend is added --
# the old message said "v0.1 supports cmux" and would have kept saying it.
wt_list_backends() {
  _wt_root="$1"
  for _wt_b in "$_wt_root"/backends/*.sh; do
    [ -f "$_wt_b" ] || continue
    _wt_b="${_wt_b##*/}"; _wt_b="${_wt_b%.sh}"
    [ "$_wt_b" = "common" ] && continue   # helpers, not a backend
    printf '%s\n' "$_wt_b"
  done
}

# A detected terminal with no backend must say so plainly: a half-working
# fallback is worse than a clear refusal, because the user cannot tell the
# difference between "unsupported" and "broken".
wt_require_backend() {
  _wt_name="$1"
  if ! _wt_r="$(wt_root)"; then
    echo "walkthrough: cannot locate the walkthrough checkout (no backends/ found)." >&2
    echo "  This is not about your terminal. Set WALKTHROUGH_ROOT to the" >&2
    echo "  directory that contains backends/, or run from inside it." >&2
    return 1
  fi
  if [ ! -f "$_wt_r/backends/$_wt_name.sh" ]; then
    echo "walkthrough: no backend for '$_wt_name'." >&2
    echo "  available: $(wt_list_backends "$_wt_r" | tr '\n' ' ')" >&2
    echo "  Adding one is a single file: backends/$_wt_name.sh, defining" >&2
    echo "  backend_open and backend_close. Override detection with" >&2
    echo "  WALKTHROUGH_BACKEND." >&2
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
