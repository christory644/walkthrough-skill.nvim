#!/usr/bin/env bash
# The launch command wt_nvim_cmd builds is TYPED INTO A SHELL WE DO NOT CHOOSE
# -- the user's login shell, via cmux `send`, or whatever `sh` a multiplexer
# runs it with. So the only honest test is to hand the real emitted string to
# real parsers and compare the argv that arrives against the argv that was
# meant.
#
# `nvim` here is a stub on PATH that base64s each argument, one per line: a
# filename containing a space, a quote or a NEWLINE compares exactly, and no
# editor is ever launched.
#
# What this caught (issue #14). `printf %q` emits bash/zsh `$'...'`:
#   sh/bash/zsh/ksh   $'nl\nb.txt'  -> correct
#   dash              $'nl\nb.txt'  -> opens a file literally named $nl\nb.txt
#   csh/tcsh          $'nl\nb.txt'  -> "Illegal variable name."
# dash is the one that mattered: not a failure, a DIFFERENT FILE, in silence.
set -u
cd "$(dirname "$0")/.." || exit 1
. ./backends/common.sh

fail=0
ok()   { echo "  ok: $1"; }
bad()  { echo "  FAIL: $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$2], got [$3])"; fi; }

TMP="$(mktemp -d)"                      # nothing is written into the checkout
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/nvim" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do printf %s "$a" | base64 | tr -d '\n'; echo; done
STUB
chmod +x "$TMP/nvim"

b64line() { printf %s "$1" | base64 | tr -d '\n'; echo; }

# ---------------------------------------------------------------------------
# wt_shquote on its own. Armouring is only worth anything if it round-trips
# the values nobody thinks about.
# ---------------------------------------------------------------------------
echo "== wt_shquote"
roundtrip() { # $1 = the value that must survive
  local got
  got="$(bash -c "printf %s $(wt_shquote "$1")")"
  check "round-trips: $(printf %s "$1" | tr '\n' '~')" "$1" "$got"
}
roundtrip "plain.txt"
roundtrip "with space.txt"
roundtrip "it's.txt"
roundtrip "'"
roundtrip "'''"
roundtrip "a'b'c"
# Not expanding is the whole assertion: these are FILENAMES that happen to
# contain shell metacharacters, and they must reach nvim unexpanded.
# shellcheck disable=SC2016
roundtrip 'dollar$HOME and `backtick`'
roundtrip 'semi;rm -rf /'
roundtrip ''
roundtrip '*'
# The emitted form must be single-quoted, never bash's $'...'. This is the
# assertion that actually names the defect: a future `printf %q` would still
# round-trip under bash above and pass every check but this one.
case "$(wt_shquote "$(printf 'nl\nb.txt')")" in
  \$\'*) bad "a newline is armoured as bash-only \$'...'" ;;
  \'*)   ok  "a newline is armoured with POSIX single quotes, not \$'...'" ;;
  *)     bad "a newline is not quoted at all" ;;
esac

# ---------------------------------------------------------------------------
# The whole launch command, through every shell installed here.
# ---------------------------------------------------------------------------
CWD="/tmp/ws root"                      # a workspace root with a space in it
SOCK="$TMP/dir with space/wt.sock"      # ...and a socket path with one too

expected_argv() { # rest = files
  b64line "--cmd"
  b64line "lua vim.fn.chdir(vim.base64.decode('$(wt_b64 "$CWD")'))"
  b64line "-c"; b64line "silent! SessionDisableAutoSave"
  b64line "--listen"; b64line "$SOCK"
  local f; for f in "$@"; do b64line "$f"; done
}

run_in() { # $1=shell $2=command  -> argv as base64 lines
  case "$1" in
    csh|tcsh) PATH="$TMP:$PATH" "$1" -f -c "$2" 2>&1 ;;
    *)        PATH="$TMP:$PATH" "$1" -c "$2" 2>&1 ;;
  esac
}

# Filenames that need quoting but hold no control character. EVERY shell that
# could be a login shell must carry these exactly -- csh and tcsh included.
# shellcheck disable=SC2016  # again: filenames, deliberately unexpanded
AWKWARD=( "plain.txt" "with space.txt" "it's.txt" 'a"b.txt' 'semi;rm -rf x.txt'
          'dollar$HOME.txt' 'star*.txt' 'tilde~.txt' 'paren(1).txt' )
NEWLINE="$(printf 'nl\nb.txt')"

echo "== the launch command, parsed by real shells"
for sh in sh bash zsh dash ksh csh tcsh fish; do
  command -v "$sh" >/dev/null 2>&1 || { echo "  skip: $sh not installed"; continue; }

  got="$(run_in "$sh" "$(wt_nvim_cmd "$CWD" "$SOCK" "${AWKWARD[@]}")")"
  want="$(expected_argv "${AWKWARD[@]}")"
  if [ "$got" = "$want" ]; then ok "$sh: awkward filenames arrive exactly"
  else bad "$sh: awkward filenames were mangled"; fi

  # A literal newline. csh and tcsh cannot represent one in an argument at
  # all, so the requirement there is not "works" but "does not silently open
  # the wrong file" -- which is precisely what dash used to do.
  got="$(run_in "$sh" "$(wt_nvim_cmd "$CWD" "$SOCK" "$NEWLINE")")"
  want="$(expected_argv "$NEWLINE")"
  case "$sh" in
    csh|tcsh)
      if [ "$got" = "$want" ]; then ok "$sh: newline filename arrives exactly"
      elif printf %s "$got" | grep -q "$(b64line "$NEWLINE" | head -c 12)"; then
        bad "$sh: newline filename partially arrived -- ambiguous"
      else ok "$sh: newline filename refused loudly, nothing wrong opened"; fi ;;
    *)
      if [ "$got" = "$want" ]; then ok "$sh: newline filename arrives exactly"
      else bad "$sh: newline filename was mangled (this is #14)"; fi ;;
  esac
done

[ "$fail" -eq 0 ] && echo "BACKEND QUOTING PASSED"
exit "$fail"
