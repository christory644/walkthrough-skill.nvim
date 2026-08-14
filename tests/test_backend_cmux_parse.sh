#!/usr/bin/env bash
# Reading `cmux tree`: which surface has focus, and what order the tabs are in.
#
# These two parses decide the verdict of tests/test_backend_cmux.sh, and that
# suite only runs inside cmux -- so on CI, and on any machine without cmux,
# nothing has ever checked them. They live here, as stdin filters over fixture
# text, so the parse can be wrong in a way a test notices.
#
# SOURCED, this file defines the filters. EXECUTED, it runs the fixtures below.
#
# The defect (#20): `active()` set a flag at the selected workspace and never
# cleared it, so it went on matching surfaces in every workspace -- and every
# WINDOW -- that followed. It returned the right answer only because `◀ active`
# happens to be globally unique in the trees anyone had looked at. That is a
# property of the output, not of the parse, and cmux windows are the case
# where it stops holding: open a second cmux window and there is a second
# focused surface in the tree.

# The focused surface: inside the CURRENT window, inside its SELECTED
# workspace, the surface marked `◀ active`.
#
# Not `◀ here`, which marks the surface the calling script runs in and never
# moves -- reading that would make every focus assertion in the cmux suite a
# tautology, which is the mistake that suite was already written to avoid.
cmux_tree_active() {
  awk '
    /window [0-9A-F]{8}-/    { inwin = ($0 ~ /\[current\]/); inws = 0; next }
    !inwin                   { next }
    /workspace [0-9A-F]{8}-/ { inws  = ($0 ~ /\[selected\]/); next }
    !inws                    { next }
    /surface [0-9A-F]{8}-/ && /◀ active/ { print; exit }
  ' | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1
}

# Tab order of the selected workspace of the current window, left to right.
cmux_tree_order() {
  awk '
    /window [0-9A-F]{8}-/    { inwin = ($0 ~ /\[current\]/); inws = 0; next }
    !inwin                   { next }
    /workspace [0-9A-F]{8}-/ { inws  = ($0 ~ /\[selected\]/); next }
    !inws                    { next }
    /surface [0-9A-F]{8}-/   { print }
  ' | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | tr '\n' ' '
}

# The title cmux shows for one surface. In `cmux tree` that is the quoted
# string after the surface's type:
#   surface <uuid> [terminal] "~/repos/thing" tty=ttys000
# An untitled surface shows its working directory here, which is exactly why
# the walkthrough tab was indistinguishable from a stray shell (#24).
cmux_tree_title() { # $1 = surface uuid; tree on stdin
  awk -v id="$1" '
    $0 ~ id && /surface [0-9A-F]{8}-/ {
      if (match($0, /"[^"]*"/)) { print substr($0, RSTART + 1, RLENGTH - 2); exit }
    }'
}

# Sourced for the definitions above? Then we are done.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

# ---------------------------------------------------------------------------
set -u
fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; else echo "  FAIL: $1 (want [$2], got [$3])"; fail=1; fi; }

U() { printf '%s%s-0000-0000-0000-000000000000' "$1" "$2"; }
S1="$(U AAAA 1111)"; S2="$(U AAAA 2222)"
S3="$(U BBBB 3333)"; S4="$(U BBBB 4444)"

# A. The ordinary tree: one window, one selected workspace, focus inside it.
read -r -d '' TREE_A <<EOF
window CCCC0000-0000-0000-0000-000000000000 [current] ◀ active
├── workspace DDDD0000-0000-0000-0000-000000000000 "work" [selected] ◀ active
│   └── pane EEEE0000-0000-0000-0000-000000000000 [focused] ◀ active
│       ├── surface $S1 [terminal] "~/a" tty=ttys000
│       └── surface $S2 [terminal] "~/b" [selected] ◀ active tty=ttys001
EOF
check "A focused surface" "$S2" "$(printf '%s\n' "$TREE_A" | cmux_tree_active)"
check "A tab order"       "$S1 $S2 " "$(printf '%s\n' "$TREE_A" | cmux_tree_order)"

# B. TWO cmux windows -- the case that breaks the unbounded parse.
#
# Each window has its own selected workspace and its own focused surface, so
# `◀ active` is no longer globally unique. The unbounded version latched onto
# the FIRST selected workspace in the file, which belongs to the window that
# is not current, and returned a surface from the wrong window entirely.
read -r -d '' TREE_B <<EOF
window 11110000-0000-0000-0000-000000000000
├── workspace 22220000-0000-0000-0000-000000000000 "other" [selected] ◀ active
│   └── pane 33330000-0000-0000-0000-000000000000 [focused] ◀ active
│       ├── surface $S1 [terminal] "~/a" [selected] ◀ active tty=ttys000
│       └── surface $S2 [terminal] "~/b" tty=ttys001
window 44440000-0000-0000-0000-000000000000 [current] ◀ active
├── workspace 55550000-0000-0000-0000-000000000000 "mine" [selected] ◀ active
│   └── pane 66660000-0000-0000-0000-000000000000 [focused] ◀ active
│       ├── surface $S3 [terminal] "~/c" tty=ttys002
│       └── surface $S4 [terminal] "~/d" [selected] ◀ active tty=ttys003
EOF
check "B focused surface is in the CURRENT window" "$S4" \
  "$(printf '%s\n' "$TREE_B" | cmux_tree_active)"
check "B tab order is the CURRENT window's" "$S3 $S4 " \
  "$(printf '%s\n' "$TREE_B" | cmux_tree_order)"

# C. The selected workspace has no focused surface, and a LATER workspace in
#    the same window does. The right answer is nothing: an empty result fails
#    the caller's assertion loudly, where a stranger's surface would quietly
#    satisfy it.
read -r -d '' TREE_C <<EOF
window CCCC0000-0000-0000-0000-000000000000 [current] ◀ active
├── workspace DDDD0000-0000-0000-0000-000000000000 "work" [selected]
│   └── pane EEEE0000-0000-0000-0000-000000000000 [focused]
│       └── surface $S1 [terminal] "~/a" [selected] tty=ttys000
├── workspace FFFF0000-0000-0000-0000-000000000000 "next"
│   └── pane 77770000-0000-0000-0000-000000000000 [focused]
│       └── surface $S2 [terminal] "~/b" ◀ active tty=ttys001
EOF
check "C no focused surface in the selected workspace" "" \
  "$(printf '%s\n' "$TREE_C" | cmux_tree_active)"
check "C tab order stops at the workspace boundary" "$S1 " \
  "$(printf '%s\n' "$TREE_C" | cmux_tree_order)"

# D. `◀ here` is not `◀ active`. The caller's own surface never moves; reading
#    it instead of focus is what made an earlier version of the cmux suite
#    unable to fail.
read -r -d '' TREE_D <<EOF
window CCCC0000-0000-0000-0000-000000000000 [current] ◀ active
├── workspace DDDD0000-0000-0000-0000-000000000000 "work" [selected] ◀ active
│   └── pane EEEE0000-0000-0000-0000-000000000000 [focused] ◀ active
│       ├── surface $S1 [terminal] "~/a" ◀ here tty=ttys000
│       └── surface $S2 [terminal] "~/b" [selected] ◀ active tty=ttys001
EOF
check "D focus is the active surface, not the caller's" "$S2" \
  "$(printf '%s\n' "$TREE_D" | cmux_tree_active)"

# E. Titles. A titled walkthrough tab is the whole of #24, and reading the
#    title back is how the cmux suite checks it landed.
read -r -d '' TREE_E <<EOF
window CCCC0000-0000-0000-0000-000000000000 [current] ◀ active
├── workspace DDDD0000-0000-0000-0000-000000000000 "work" [selected] ◀ active
│   └── pane EEEE0000-0000-0000-0000-000000000000 [focused] ◀ active
│       ├── surface $S1 [terminal] "~/repos/thing" tty=ttys000
│       └── surface $S2 [terminal] "◆ walkthrough" [selected] ◀ active tty=ttys001
EOF
# shellcheck disable=SC2088  # a literal ~, as cmux prints it -- not a path to expand
check "E an untitled tab reads as its directory" "~/repos/thing" \
  "$(printf '%s\n' "$TREE_E" | cmux_tree_title "$S1")"
check "E the walkthrough tab reads as its label" "◆ walkthrough" \
  "$(printf '%s\n' "$TREE_E" | cmux_tree_title "$S2")"

[ "$fail" -eq 0 ] && echo "CMUX TREE PARSE PASSED"
exit "$fail"
