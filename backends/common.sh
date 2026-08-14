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
#
# Two things were wrong with the old loop (#17).
#
# It polled with NO delay, so `tries` measured the machine's CPU rather than
# any amount of time -- and every single try spawned a whole nvim just to ask
# a question. 300 tries meant 300 processes racing the one nvim we were
# waiting for. The wait was starving the thing it waited on.
#
# And it returned 1 in silence, so the caller had to invent a reason. The
# caller's guess ("nvim never came up") cannot tell apart the two failures
# that call for different repairs: nvim never STARTED, or nvim started and
# never ANSWERED. The socket file distinguishes them, so this says which.
#
# Measured on this machine, socket that never appears, tries=300:
#
#                nvim processes spawned    wall clock
#   before                          300         10.5s
#   after                             0         11.3s
#
# The budget is deliberately left where it was -- the call site in cmd_open
# picked 300 against a measured cold nvim start and lowering it would break
# that -- but it is now spent WAITING rather than spinning, and `tries` is a
# count of intervals instead of a measurement of how fast this CPU is. The
# extra 0.8s is the poll interval times the cost of `sleep` being its own
# process; it is only ever paid on a failure that was going to be reported.
#
# Fractional sleep is not in POSIX, but scripts/with-lock (LOCK_POLL=0.25) and
# the cmux suite already require it, so this assumes no more than they do.
WT_SOCKET_POLL="${WT_SOCKET_POLL:-0.03}"

wt_wait_for_socket() {
  _wt_sk="$1"; _wt_tries="${2:-60}"
  _wt_i=0; _wt_seen=0; _wt_perr=''
  _wt_t0="$(date +%s)"

  while [ "$_wt_i" -lt "$_wt_tries" ]; do
    # A stat, not a process. nvim binds the socket path when it is ready to
    # serve it, so until that path exists there is nobody to ask and no
    # reason to spawn anything -- which is exactly the window the old loop
    # spent all its processes on. (`--listen` also accepts host:port, which
    # never appears on disk, so the gate only applies to a path.)
    case "$_wt_sk" in
      */*) [ -S "$_wt_sk" ] && _wt_seen=1 ;;
      *)   _wt_seen=1 ;;
    esac
    if [ "$_wt_seen" -eq 1 ]; then
      # Keep the probe's own complaint: when the socket is there but nvim
      # will not answer, that message is the only evidence of why.
      _wt_perr="$(nvim --server "$_wt_sk" --remote-expr '1' 2>&1 >/dev/null)" && return 0
    fi
    _wt_i=$((_wt_i + 1))
    sleep "$WT_SOCKET_POLL"
  done

  _wt_el=$(( $(date +%s) - _wt_t0 ))
  echo "walkthrough: nvim did not answer on $_wt_sk" >&2
  if [ "$_wt_seen" -eq 0 ]; then
    echo "  Waited ${_wt_el}s over $_wt_tries polls and the socket was never created," >&2
    echo "  so nvim never started. Look at the surface that opened: a shell rc that" >&2
    echo "  errors, or an nvim that exits during startup, both land here." >&2
  else
    echo "  Waited ${_wt_el}s over $_wt_tries polls. The socket exists, so nvim" >&2
    echo "  started -- it just never answered. A configuration slow enough to miss" >&2
    echo "  the budget is the usual cause." >&2
    [ -n "$_wt_perr" ] && echo "  Last reply from the probe: $_wt_perr" >&2
  fi
  echo "  Raise the budget with WT_SOCKET_POLL (seconds per poll, now $WT_SOCKET_POLL)." >&2
  return 1
}

# base64 is the armour for every value that has to cross into another language
# (see the threat model at the top of bin/walkthrough). Encoding strips the
# newlines GNU/BSD base64 insert at 76 columns so a value is always exactly one
# token on one line. Defined here rather than in the CLI because the launch
# command built below needs it too, and the two must not disagree about the
# encoding.
wt_b64() { printf %s "$1" | base64 | tr -d '\n'; }

# Quote one argument for a shell we do not get to choose.
#
# The string this builds is TYPED INTO THE USER'S LOGIN SHELL (cmux `send`) or
# handed to whatever `sh` the multiplexer runs it with. `printf %q` was the
# obvious tool and the wrong one: it emits bash/zsh `$'...'` for a value
# containing a control character, and measured against real parsers that is
#
#   sh/bash/zsh/ksh   $'nl\nb.txt'  -> correct
#   dash              $'nl\nb.txt'  -> opens a file literally named $nl\nb.txt
#   csh/tcsh          $'nl\nb.txt'  -> "Illegal variable name."
#
# dash is the one that matters: it does not fail, it silently opens a
# different file. A wrong walkthrough is worse than no walkthrough.
#
# POSIX single-quote armour instead: everything between '...' is literal in
# every one of those shells, and an embedded quote closes the run, contributes
# an escaped quote, and reopens. csh and tcsh accept that form too, because
# their backslash escaping outside quotes agrees with POSIX here.
#
# Residual, stated rather than hidden: csh and tcsh cannot carry a literal
# NEWLINE in an argument at all, so such a filename fails loudly there. Loud
# is the point -- that is the case dash used to get wrong in silence.
wt_shquote() {
  _wt_rest="$1"; _wt_acc=''
  while [ "${_wt_rest#*\'}" != "$_wt_rest" ]; do
    _wt_acc="$_wt_acc${_wt_rest%%\'*}'\\''"
    _wt_rest="${_wt_rest#*\'}"
  done
  printf "'%s'" "$_wt_acc$_wt_rest"
}

wt_nvim_cmd() { # $1=workspace root, $2=socket, rest=files
  _wt_cwd="$1"; _wt_sock="$2"; shift 2
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
  #
  # Every argument goes through wt_shquote -- the --cmd chunk, the socket and
  # each file alike. One quoting rule for the whole line, rather than a
  # hand-placed double quote here, a hand-placed single quote there and an
  # unquoted socket path in the middle: the socket sits under $TMPDIR, which
  # is a directory the user names and may contain a space.
  printf 'nvim --cmd %s -c %s --listen %s' \
    "$(wt_shquote "lua vim.fn.chdir(vim.base64.decode('$(wt_b64 "$_wt_cwd")'))")" \
    "$(wt_shquote 'silent! SessionDisableAutoSave')" \
    "$(wt_shquote "$_wt_sock")"
  for _wt_f in "$@"; do printf ' %s' "$(wt_shquote "$_wt_f")"; done
}
