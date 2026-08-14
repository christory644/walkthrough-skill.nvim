#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.." || exit 1
. ./backends/common.sh

fail=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  ok: $1"; else echo "  FAIL: $1 (want $2, got $3)"; fail=1; fi
}

# Each case sets the whole environment detection looks at, so a variable that
# happens to be set in the developer's own terminal cannot decide the result.
# The empty ones are written VAR='' rather than VAR=: identical to the shell,
# and unambiguous to a reader (and to shellcheck, which reads a bare `VAR= cmd`
# as a likely typo for `VAR=cmd`).
check "explicit override wins" "tmux" \
  "$(WALKTHROUGH_BACKEND=tmux CMUX_SURFACE_ID=x wt_detect_backend)"
check "cmux detected"         "cmux" \
  "$(WALKTHROUGH_BACKEND='' CMUX_SURFACE_ID=abc TMUX='' wt_detect_backend)"
check "tmux detected"         "tmux" \
  "$(WALKTHROUGH_BACKEND='' CMUX_SURFACE_ID='' TMUX=/tmp/x,1,0 wt_detect_backend)"
check "cmux wins over tmux"   "cmux" \
  "$(WALKTHROUGH_BACKEND='' CMUX_SURFACE_ID=abc TMUX=/tmp/x,1,0 wt_detect_backend)"
check "unknown terminal"      "none" \
  "$(WALKTHROUGH_BACKEND='' CMUX_SURFACE_ID='' TMUX='' wt_detect_backend)"

# A detected-but-unimplemented backend must fail loudly, not half-work.
# The name here has to be one that genuinely ships no backend: this assertion
# used to name tmux, which made it a test of "tmux is unimplemented" rather
# than of the refusal, and it would have started failing the day tmux landed.
( . ./backends/common.sh; wt_require_backend kitty ) >/dev/null 2>&1
check "unimplemented backend errors" "1" "$?"

# ...and an IMPLEMENTED one must not be refused. Without this the assertion
# above passes just as happily when wt_require_backend refuses everything,
# which is exactly the bug #18 produced.
( . ./backends/common.sh; wt_require_backend cmux ) >/dev/null 2>&1
check "implemented backend accepted" "0" "$?"
( . ./backends/common.sh; wt_require_backend tmux ) >/dev/null 2>&1
check "tmux is implemented now, and accepted" "0" "$?"

# ---------------------------------------------------------------------------
# The refusal messages, which are somebody else's fixture.
#
# README.md and skills/walkthrough/SKILL.md quote the FIRST line verbatim, so
# it is load-bearing text and not prose to tidy. The body below it is ours.
# ---------------------------------------------------------------------------
none_msg="$( . ./backends/common.sh; wt_require_backend none 2>&1 >/dev/null )"
first_line="${none_msg%%$'\n'*}"
check "the quoted first line is byte-identical" \
  "walkthrough: no backend for 'none'." "$first_line"

# `none` is the sentinel wt_detect_backend returns when it recognised nothing
# -- it is not the name of a terminal. The generic advice used to interpolate
# it, telling the reader to write `backends/none.sh`: a file that would never
# be loaded, as the answer to a problem whose real fix is "you are not inside
# a multiplexer". Two situations were sharing one message.
case "$none_msg" in
  *"backends/none.sh"*) echo "  FAIL: the 'none' refusal still advises writing backends/none.sh"; fail=1 ;;
  *) echo "  ok: the 'none' refusal does not advise writing backends/none.sh" ;;
esac
# shellcheck disable=SC2016  # matching the LITERAL text "$TMUX" in the message
case "$none_msg" in
  *'$TMUX'*) echo "  ok: the 'none' refusal names the variables detection looks at" ;;
  *) echo "  FAIL: the 'none' refusal does not say what was looked for"; fail=1 ;;
esac
# A genuinely unimplemented, genuinely named terminal still gets the advice
# that fits IT -- the two branches must not collapse into one.
kitty_msg="$( . ./backends/common.sh; wt_require_backend kitty 2>&1 >/dev/null )"
case "$kitty_msg" in
  *"backends/kitty.sh"*) echo "  ok: a named terminal is still told which file to add" ;;
  *) echo "  FAIL: a named terminal lost its add-a-backend advice"; fail=1 ;;
esac

# ---------------------------------------------------------------------------
# Sourcing from a strict POSIX shell (#18)
#
# `${BASH_SOURCE[0]:-$0}` is a fatal `Bad substitution` under dash, and the
# failed expansion left the root empty -- so the refusal that followed named a
# backend that was present on disk. Both halves are asserted: no diagnostic
# from the shell itself, and the right verdict for a backend that exists.
#
# /bin/sh is checked because that is what a third-party backend or an `sh`
# test would use; on Linux CI it IS dash, while on macOS it is bash in POSIX
# mode and cannot see this class of bug at all -- which is why dash is checked
# by name as well whenever it is installed.
# ---------------------------------------------------------------------------
posix_source_check() { # $1 = shell to try
  local sh="$1" out rc
  command -v "$sh" >/dev/null 2>&1 || { echo "  skip: $sh not installed"; return; }
  out="$("$sh" -c '. ./backends/common.sh; wt_require_backend cmux' 2>&1)"; rc=$?
  check "$sh: sources and accepts cmux" "0" "$rc"
  case "$out" in
    *"Bad substitution"*|*"bad substitution"*)
      echo "  FAIL: $sh: shell error while sourcing: $out"; fail=1 ;;
    *"no backend for"*)
      echo "  FAIL: $sh: refused a backend that exists: $out"; fail=1 ;;
    *) echo "  ok: $sh: sourced without a shell diagnostic" ;;
  esac
}
posix_source_check sh
posix_source_check dash
posix_source_check ksh

# When the root genuinely cannot be found, the refusal must say THAT rather
# than blaming the terminal. These are two different repairs, so they cannot
# share a message. Run from a directory with no backends/ and no
# WALKTHROUGH_ROOT, which is the only way POSIX sh can fail to locate itself.
if command -v dash >/dev/null 2>&1; then
  # Resolved HERE, before the cd: `$PWD` inside the subshell below would be
  # `/`, and the test would silently source nothing and assert on the wrong
  # failure. (It would still have gone green -- an unreadable file cannot
  # define wt_require_backend either.)
  here="$PWD"
  root_msg="$(cd / && WALKTHROUGH_ROOT='' dash -c \
    ". '$here'/backends/common.sh; wt_require_backend cmux" 2>&1)"
  case "$root_msg" in
    *"cannot locate the walkthrough checkout"*) echo "  ok: unlocatable root says so" ;;
    *) echo "  FAIL: unlocatable root reported as: $root_msg"; fail=1 ;;
  esac
  # ...and WALKTHROUGH_ROOT is the documented escape hatch out of exactly that.
  ( cd / && WALKTHROUGH_ROOT="$here" dash -c \
      ". '$here'/backends/common.sh; wt_require_backend cmux" ) >/dev/null 2>&1
  check "WALKTHROUGH_ROOT rescues an unlocatable root" "0" "$?"
fi

[ "$fail" -eq 0 ] && echo "BACKEND DETECT PASSED"
exit "$fail"
