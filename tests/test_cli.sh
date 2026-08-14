#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.." || exit 1
REPO="$PWD"
WT="$REPO/bin/walkthrough"
fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; else echo "  FAIL: $1 (want $2, got $3)"; fail=1; fi }

# Everything this suite creates lives under one temp directory. It used to do
# `mkdir -p .tours` and `rm -rf .tours` in the repository itself — which would
# delete a real, committed .tours/ the moment one existed. Nothing below writes
# to the repo.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/walkthrough-test.XXXXXX")" || exit 1
# Point the CLI's state directory at $WORK too, so the suite can never disturb
# (or be disturbed by) a walkthrough the developer actually has open.
export XDG_RUNTIME_DIR="$WORK/xdg"
mkdir -p "$XDG_RUNTIME_DIR"
STATE_FILE="$XDG_RUNTIME_DIR/walkthrough-${USER:-x}/state"

# A headless nvim standing in for the tour's player: a real --remote-expr
# target, with no terminal surface and no backend involved. This is what makes
# the injection checks below discriminate — without a live socket the CLI would
# bail at "no active walkthrough" long before reaching the vulnerable call.
SOCK="$WORK/player.sock"
nvim --headless --listen "$SOCK" >/dev/null 2>&1 &
NVIM_PID=$!
trap 'kill "$NVIM_PID" 2>/dev/null; wait "$NVIM_PID" 2>/dev/null; rm -rf "$WORK"' EXIT
i=0
while [ "$i" -lt 300 ]; do
  nvim --server "$SOCK" --remote-expr '1' >/dev/null 2>&1 && break
  i=$((i + 1))
done

# Write a state file using the CLI's own writer, so these tests exercise the
# real format rather than a hand-rolled imitation of it.
plant_state() { # backend handle socket tour
  ( cd "$REPO" && bash -c '
      set -uo pipefail
      source ./bin/walkthrough --help >/dev/null 2>&1
      state_write "$1" "$2" "$3" "$4"
    ' _ "$1" "$2" "$3" "$4" )
}

# ---------------------------------------------------------------------------
# The original contract
# ---------------------------------------------------------------------------

# validate: exit 0 for a good tour, non-zero for a broken one
"$WT" validate tests/fixtures/two_files.tour >/dev/null 2>&1
check "valid tour exits 0" "0" "$?"

cat > "$WORK/bad.tour" <<'EOF'
{ "steps": [] }
EOF
"$WT" validate "$WORK/bad.tour" >/dev/null 2>&1
check "invalid tour exits non-zero" "1" "$?"

# a tour pointing at a deleted file is invalid too — this is what CI catches
cat > "$WORK/rotted.tour" <<'EOF'
{ "title": "t", "steps": [ { "file": "does/not/exist.py", "line": 1, "description": "d" } ] }
EOF
"$WT" validate "$WORK/rotted.tour" >/dev/null 2>&1
check "rotted tour exits non-zero" "1" "$?"

# schema is machine-readable so an agent can self-check
"$WT" schema | grep -q '"steps"'
check "schema mentions steps" "0" "$?"

# list finds tours in .tours/ — exercised inside $WORK, so the default path is
# still covered without creating (or deleting) the repo's own .tours/
mkdir -p "$WORK/listdir/.tours" && cp tests/fixtures/two_files.tour "$WORK/listdir/.tours/"
( cd "$WORK/listdir" && "$WT" list | grep -q 'two_files.tour' )
check "list finds tours" "0" "$?"

"$WT" --help >/dev/null 2>&1
check "help exits 0" "0" "$?"

# ---------------------------------------------------------------------------
# C-2 — validate must fail CLOSED, whatever the tour is called
#
# The old implementation pasted the path into a Lua string literal and ran
# `-c 'qa!'` after the chunk. A path containing a quote or a backslash broke
# the chunk at COMPILE time; the trailing qa! still ran, so nvim exited 0 and
# `validate` reported "playable" about a tour it had never parsed. Rot
# detection in CI is the entire reason validate exists, so failing open here
# silently defeats the feature. Every one of these names must now exit 1.
# ---------------------------------------------------------------------------
c2_fail=0
c2_bad=""
c2_names=( "plain.tour" "has space.tour" "has'quote.tour" 'has"dquote.tour' \
           'back\slash.tour' "dollar\$var.tour" 'semi;touch pwned;.tour' \
           'newline
in-name.tour' )
mkdir -p "$WORK/c2"
for n in "${c2_names[@]}"; do
  printf '{ "steps": [] }\n' > "$WORK/c2/$n"
  "$WT" validate "$WORK/c2/$n" >/dev/null 2>&1
  if [ "$?" -ne 1 ]; then c2_fail=1; c2_bad="$c2_bad $(printf %q "$n")"; fi
  rm -f "$WORK/c2/$n"
done
[ -n "$c2_bad" ] && echo "    names that failed open:$c2_bad"
check "C-2 an invalid tour fails closed at every hostile filename" "0" "$c2_fail"

# That property rests entirely on `nvim -l` propagating the script's exit
# status. If that ever stops being true the fix is silently undone, so assert
# it directly rather than trusting it.
printf 'os.exit(3)\n' > "$WORK/exit3.lua"
nvim --headless --clean -l "$WORK/exit3.lua" >/dev/null 2>&1
check "C-2 nvim -l propagates os.exit status" "3" "$?"
printf 'local x = (\n' > "$WORK/broken.lua"
nvim --headless --clean -l "$WORK/broken.lua" >/dev/null 2>&1
check "C-2 nvim -l fails closed on a compile error" "1" "$?"

# ---------------------------------------------------------------------------
# C-1 — a tour FILENAME must never become Lua
#
# `t'..(os.execute("touch PWNED_C1") and "")..'.tour` used to close the Lua
# string literal the path was pasted into, and os.execute ran. The path now
# reaches Lua through _G.arg, so it is a name, not code.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/c1"
printf 'x\n' > "$WORK/c1/target.txt"
c1name='t'"'"'..(os.execute("touch PWNED_C1") and "")..'"'"'.tour'
printf '{ "title": "t", "steps": [ { "file": "target.txt", "line": 1, "description": "d" } ] }\n' \
  > "$WORK/c1/$c1name"
( cd "$WORK/c1" && "$WT" validate "$c1name" >/dev/null 2>&1 )
check "C-1 a hostile filename is judged on its own merits" "0" "$?"
[ -e "$WORK/c1/PWNED_C1" ] && c1exec=1 || c1exec=0
check "C-1 the filename did not execute (no os.execute)" "0" "$c1exec"

# ---------------------------------------------------------------------------
# C-3 — the state file is data, never shell
#
# It used to be written unquoted and then `.`-sourced, so a tour path
# containing `;touch X;` ran on every step/reload/close, in the user's own
# shell. Values are base64 now and the file is parsed, not executed. It also
# lives in a 0700 directory we verify we own, rather than a predictable
# /tmp/walkthrough-$USER.state that another local user could pre-create.
# ---------------------------------------------------------------------------
c3hostile="mytour;touch $WORK/PWNED_C3;.tour"
c3res="$( cd "$REPO" && bash -c '
    set -uo pipefail
    source ./bin/walkthrough --help >/dev/null 2>&1
    state_write "cmux" "H" "/nope.sock" "$1"
    grep -qE "^tour=[A-Za-z0-9+/=]+$" "$STATE" || { echo not-base64; exit 0; }
    state_read
    [ "$ST_tour" = "$1" ] || { echo roundtrip-broke; exit 0; }
    [ "$(ls -ld "$STATE_DIR" | cut -c1-10)" = "drwx------" ] || { echo dir-perms; exit 0; }
    [ "$(ls -l  "$STATE"     | cut -c1-10)" = "-rw-------" ] || { echo file-perms; exit 0; }
    echo ok
  ' _ "$c3hostile" )"
check "C-3 state is base64, 0600 in a 0700 dir, and round-trips a hostile path" "ok" "$c3res"
[ -e "$WORK/PWNED_C3" ] && c3exec=1 || c3exec=0
check "C-3 writing and reading state did not execute the path" "0" "$c3exec"

# An attacker who does manage to write the state file must not get execution
# out of it either: a value that is not base64 is corruption, not a command.
mkdir -p "$XDG_RUNTIME_DIR/walkthrough-${USER:-x}"
chmod 700 "$XDG_RUNTIME_DIR/walkthrough-${USER:-x}"
# The socket named here is a dead path, NOT $SOCK: `close` unlinks the socket
# its state file names, and naming the live player's socket here would leave
# every later test talking to a socket that no longer exists — which quietly
# turns "the CLI never reached nvim" assertions into tautologies.
printf 'backend=%s\nhandle=%s\nsocket=%s\ntour=;touch %s/PWNED_C3B;\n' \
  "$(printf %s cmux | base64 | tr -d '\n')" \
  "$(printf %s h | base64 | tr -d '\n')" \
  "$(printf %s "$WORK/dead.sock" | base64 | tr -d '\n')" \
  "$WORK" > "$STATE_FILE"
"$WT" close >/dev/null 2>&1
[ -e "$WORK/PWNED_C3B" ] && c3b=1 || c3b=0
check "C-3 a planted state file is refused, not executed" "0" "$c3b"
rm -f "$STATE_FILE"

# ---------------------------------------------------------------------------
# C-4 — nothing but base64 crosses the --remote-expr boundary
#
# The five values used to be pasted into a vimscript single-quoted list inside
# a double-quoted shell word. A tour path containing a quote closed the
# vimscript string and ran vimscript — system() included — in the tour's nvim.
# ---------------------------------------------------------------------------
c4payload="/tmp/x'.system('touch $WORK/PWNED_C4').'y.tour"
c4expr="$( cd "$REPO" && bash -c '
    set -uo pipefail
    source ./bin/walkthrough --help >/dev/null 2>&1
    BACKEND=cmux
    open_expr "$1" "HANDLE"
  ' _ "$c4payload" )"
printf %s "$c4expr" | grep -q "system(" && c4leak=1 || c4leak=0
check "C-4 no attacker text reaches the remote expression" "0" "$c4leak"
# The quote count is the sharp version of the same claim: the expression is
# luaeval('<chunk>', ['a','b','c','d','e']) — two quotes around the chunk plus
# ten around the five base64 arguments, twelve in total, and not one of them
# comes from the tour path. Any injected quote changes this number.
c4quotes="$(printf %s "$c4expr" | tr -cd "'" | wc -c | tr -d ' ')"
check "C-4 the remote expression holds exactly its own 12 quotes" "12" "$c4quotes"

# ...and the far side gets the payload back, verbatim, as data.
c4b64="$(printf %s "$c4payload" | base64 | tr -d '\n')"
c4out64="$(printf %s "$WORK/c4decoded.txt" | base64 | tr -d '\n')"
nvim --headless --clean \
  -c "let g:r = luaeval('(function(a) local d = vim.base64.decode local f = io.open(d(a[2]), \"w\") f:write(d(a[1])) f:close() return 1 end)(_A)', ['$c4b64','$c4out64'])" \
  -c 'qa!' >/dev/null 2>&1
check "C-4 base64 carries the payload across intact" "$c4payload" "$(cat "$WORK/c4decoded.txt" 2>/dev/null)"
[ -e "$WORK/PWNED_C4" ] && c4exec=1 || c4exec=0
check "C-4 vimscript system() never ran" "0" "$c4exec"

# ---------------------------------------------------------------------------
# I-3 — the step argument is an integer or it is refused
#
# It used to be interpolated raw into the remote expression. The state file
# planted here points at the live headless nvim above, so a reverted guard
# really would reach it.
# ---------------------------------------------------------------------------
plant_state cmux not-a-uuid "$SOCK" "$WORK/t.tour"
"$WT" step "system('touch $WORK/PWNED_I3')" >/dev/null 2>&1
check "I-3 a non-numeric step argument is refused" "1" "$?"
[ -e "$WORK/PWNED_I3" ] && i3=1 || i3=0
check "I-3 the step argument never reached nvim" "0" "$i3"

# ---------------------------------------------------------------------------
# S-0 — `step` against a walkthrough that is not open must FAIL
#
# M.goto_step returned quietly when nothing was active, so --remote-expr
# succeeded and the CLI exited 0: `walkthrough step +1` reported success having
# moved nothing. SKILL.md tells the agent driving this to trust that exit
# status ("never claim the walkthrough is open without checking"), so the agent
# went on to narrate a step the reader was never taken to. The headless nvim
# below is a real player with no walkthrough open in it — exactly the state a
# failed reload or a closed surface leaves behind.
# ---------------------------------------------------------------------------
nvim --server "$SOCK" --remote-expr \
  "luaeval('(function(a) vim.opt.runtimepath:append(vim.base64.decode(a)) return 1 end)(_A)', '$(printf %s "$REPO" | base64 | tr -d '\n')')" \
  >/dev/null 2>&1
plant_state cmux not-a-uuid "$SOCK" "$WORK/t.tour"
s0err="$("$WT" step +1 2>&1 >/dev/null)"
check "S-0 stepping a walkthrough that is not open exits non-zero" "1" "$?"
printf %s "$s0err" | grep -q 'nothing to step'
check "S-0 ...saying there is nothing to step" "0" "$?"
printf %s "$s0err" | grep -q 'stack traceback'
check "S-0 ...and not as a raw Lua traceback" "1" "$?"

# ---------------------------------------------------------------------------
# I-1 — close honours the backend the state file recorded
#
# It used to re-detect from the environment, so closing from any terminal other
# than the one that opened the tour died with "no backend for 'none'" — naming
# a backend the state file directly contradicts — and left both the surface and
# the stale state file behind. The handle here is deliberately not a UUID, so
# the cmux backend's own guard refuses it before any cmux command runs: no live
# operation, no surface touched. The socket is a dead path for the same reason
# as in C-3 above: close unlinks the socket its state file names, and taking
# the live player down here would make every later "the CLI never reached
# nvim" assertion true for the wrong reason.
# ---------------------------------------------------------------------------
plant_state cmux not-a-uuid "$WORK/dead.sock" "$WORK/t.tour"
i1out="$(env -u CMUX_SURFACE_ID -u TMUX -u WALKTHROUGH_BACKEND "$WT" close 2>&1)"
printf %s "$i1out" | grep -q "no backend for" && i1=1 || i1=0
check "I-1 close uses the recorded backend, not re-detection" "0" "$i1"
[ -e "$STATE_FILE" ] && i1s=1 || i1s=0
check "I-1 close clears the state file" "0" "$i1s"

# ---------------------------------------------------------------------------
# I-1b — ...and it clears the state file even when the BACKEND itself is gone
#
# `load_backend` exited on a backend file it could not find, and it was called
# before the cleanup. So the one case where `close` can do least — a partial
# install, or a checkout moved out from under the symlinked bundle, which the
# README warns about — was the case where it also did nothing: the surface
# stayed open (nothing can close it without its backend) AND the stale state
# survived it, so every later `step` addressed a walkthrough the user had just
# been told they closed.
#
# Loud is right. Loud and leaving the wreckage is not: the failure is reported,
# the handle is handed to the user (who is now the only one who can close that
# surface), and the record of a walkthrough that is no longer running goes.
# ---------------------------------------------------------------------------
printf 'not a socket\n' > "$WORK/i1b.sock"
plant_state absent_backend surface-42 "$WORK/i1b.sock" "$WORK/t.tour"
i1bout="$(env -u CMUX_SURFACE_ID -u TMUX -u WALKTHROUGH_BACKEND "$WT" close 2>&1)"
check "I-1b close still fails when the recorded backend is missing" "1" "$?"
printf %s "$i1bout" | grep -q "no backend for 'absent_backend'"
check "I-1b ...naming the backend it could not load" "0" "$?"
printf %s "$i1bout" | grep -q 'surface-42'
check "I-1b ...and the handle, so the surface can be closed by hand" "0" "$?"
[ -e "$STATE_FILE" ] && i1bs=1 || i1bs=0
check "I-1b ...but the state file is gone" "0" "$i1bs"
[ -e "$WORK/i1b.sock" ] && i1bk=1 || i1bk=0
check "I-1b ...and so is the socket it named" "0" "$i1bk"

# The consequence that made this worth fixing: with the state gone, a later
# `step` is refused as "no active walkthrough" instead of addressing the
# walkthrough the user believes they closed.
i1bstep="$("$WT" step +1 2>&1)"
check "I-1b a later step is refused" "1" "$?"
printf %s "$i1bstep" | grep -q 'no active walkthrough'
check "I-1b ...because there is no walkthrough left to address" "0" "$?"

# ---------------------------------------------------------------------------
# I-2 — a source path containing a space survives to the player
#
# `set -- $files` word-split before wt_nvim_cmd's `printf %q` ran, so it quoted
# the fragments rather than the path and the player opened two bogus empty
# buffers instead of the file. The list is NUL-separated now.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/i2/spaced dir"
printf 'x\n' > "$WORK/i2/spaced dir/one file.txt"
printf '{ "title": "t", "steps": [ { "file": "spaced dir/one file.txt", "line": 1, "description": "d" } ] }\n' \
  > "$WORK/i2/sp.tour"
i2n=0; i2last=""
while IFS= read -r -d '' f; do i2n=$((i2n + 1)); i2last="$f"; done \
  < <( cd "$WORK/i2" && nvim --headless --clean -l "$REPO/lua/walkthrough/validate.lua" files sp.tour )
check "I-2 the file list yields exactly one path" "1" "$i2n"
check "I-2 the space in that path survived" "one file.txt" "$(basename "$i2last")"

# ...and the same path, all the way through the real cmd_open into the command
# the backend is asked to run. The backend is stubbed out (and the socket wait
# is made to fail immediately) so this opens no surface at all: it only
# captures the argv cmd_open built.
i2cmdfile="$WORK/i2/cmd.txt"
rm -f "$i2cmdfile"
( cd "$WORK/i2" && REPO="$REPO" CMDFILE="$i2cmdfile" bash -c '
    set -uo pipefail
    source "$REPO/bin/walkthrough" --help >/dev/null 2>&1
    load_backend()       { BACKEND=stub; }
    backend_open()       { printf %s "$1" > "$CMDFILE"; echo stub-handle; }
    backend_close()      { :; }
    wt_wait_for_socket() { return 1; }
    cmd_open sp.tour
  ' _ ) >/dev/null 2>&1
grep -qF -- "$(printf %q "$i2last")" "$i2cmdfile" 2>/dev/null
check "I-2 cmd_open passes that path to the backend as one argument" "0" "$?"

# ---------------------------------------------------------------------------
# I-4 — tour paths are absolutised, and an unresolvable one is an error
#
# The state file used to record the path as typed, and cmd_reload rebuilt it
# with an UNCHECKED `cd`, so reloading from another directory silently became
# /<basename> and re-rendered the wrong file.
# ---------------------------------------------------------------------------
i4res="$( cd "$REPO" && bash -c '
    set -uo pipefail
    source ./bin/walkthrough --help >/dev/null 2>&1
    wt_abspath "tests/fixtures/two_files.tour"
  ' _ )"
case "$i4res" in /*) i4=0 ;; *) i4=1 ;; esac
check "I-4 tour paths are absolutised" "0" "$i4"
( cd "$REPO" && bash -c '
    set -uo pipefail
    source ./bin/walkthrough --help >/dev/null 2>&1
    wt_abspath "/no/such/dir/x.tour"
  ' _ ) >/dev/null 2>&1
check "I-4 an unresolvable directory errors instead of yielding /basename" "1" "$?"

# The check above exercises wt_abspath in ISOLATION, where a `die` inside it
# looks like a working abort. In real use it runs inside a command
# substitution, so `die` could only ever exit that subshell: the caller carried
# on with an EMPTY path and asked the player to reload it. The property is
# therefore asserted on the CALLER, and "nothing was sent to the player" is
# observed rather than assumed — the stand-in module below records the argument
# reload() is called with, so an empty path arriving cannot go unnoticed.
nvim --server "$SOCK" --remote-expr \
  'luaeval("(function() package.loaded.walkthrough = { reload = function(p) vim.g.wt_reload_arg = p end } return 1 end)()")' \
  >/dev/null 2>&1
plant_state cmux not-a-uuid "$SOCK" "$WORK/t.tour"
"$WT" reload "/no/such/dir/x.tour" >/dev/null 2>&1
check "I-4 an unresolvable path aborts reload instead of continuing" "1" "$?"
i4arg="$(nvim --server "$SOCK" --remote-expr 'get(g:, "wt_reload_arg", "UNSENT")' 2>/dev/null)"
check "I-4 the player was never asked to reload an empty path" "UNSENT" "$i4arg"

# ---------------------------------------------------------------------------
# V-1 — validate takes MANY tours and fails if ANY of them fails
#
# The README advertises `walkthrough validate .tours/*.tour` as the CI check.
# cmd_validate read $1 only, so a glob expanding to several tours validated the
# first and silently ignored the rest: CI went green over rotted tours.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/v"
printf '{ "title": "ok",  "steps": [ { "file": "tests/fixtures/alpha.txt", "line": 1, "description": "d" } ] }\n' \
  > "$WORK/v/good.tour"
printf '{ "title": "rot", "steps": [ { "file": "gone/missing.txt", "line": 1, "description": "d" } ] }\n' \
  > "$WORK/v/rot.tour"

"$WT" validate "$WORK/v/good.tour" "$WORK/v/good.tour" >/dev/null 2>&1
check "V-1 several good tours exit 0" "0" "$?"
v1out="$("$WT" validate "$WORK/v/good.tour" "$WORK/v/rot.tour" 2>&1)"
check "V-1 a rotted tour AFTER a good one exits non-zero" "1" "$?"
printf %s "$v1out" | grep -q "rot.tour"
check "V-1 the failure names the tour that failed" "0" "$?"
"$WT" validate "$WORK/v/rot.tour" "$WORK/v/good.tour" >/dev/null 2>&1
check "V-1 a rotted tour BEFORE a good one exits non-zero" "1" "$?"
"$WT" validate "$WORK/v/good.tour" "$WORK/v/no-such.tour" >/dev/null 2>&1
check "V-1 a path that does not exist at all exits non-zero" "1" "$?"

# ---------------------------------------------------------------------------
# V-2 — validate says WHERE each pattern step resolved
#
# `pattern` is a vim regex, so a tour that looks right can quietly park a step
# on the wrong line. Authoring one meant grepping by hand to confirm each
# pattern hit the intended line; validate now answers that question, in
# `file:line:` form so the output reads by eye and pipes into `nvim -q`.
# ---------------------------------------------------------------------------
v2out="$("$WT" validate tests/fixtures/two_files.tour 2>&1)"
check "V-2 a tour with a pattern step still exits 0" "0" "$?"
printf %s "$v2out" | grep -q '^tests/fixtures/alpha.txt:5:'
check "V-2 a pattern step reports the file and line it resolved to" "0" "$?"
printf %s "$v2out" | grep -q 'back again'
check "V-2 the report names the step" "0" "$?"
v2quiet="$(printf %s "$v2out" | grep -c 'beta.txt' || true)"
check "V-2 line-number steps stay quiet" "0" "$v2quiet"

# an ambiguous pattern resolves to the first match, and says so
printf '{ "title": "amb", "steps": [ { "title": "two of them", "file": "tests/fixtures/beta.txt", "pattern": "^beta", "description": "d" } ] }\n' \
  > "$WORK/v/amb.tour"
v2amb="$("$WT" validate "$WORK/v/amb.tour" 2>&1)"
check "V-2 an ambiguous pattern is not an error" "0" "$?"
printf %s "$v2amb" | grep -qE '^tests/fixtures/beta.txt:1:.*2 matches'
check "V-2 ...but the report says the pattern is ambiguous" "0" "$?"

# a pattern that matches nothing is rot, exactly like a file that was deleted
printf '{ "title": "gone", "steps": [ { "title": "stale", "file": "tests/fixtures/alpha.txt", "pattern": "^nope$", "description": "d" } ] }\n' \
  > "$WORK/v/nomatch.tour"
v2none="$("$WT" validate "$WORK/v/nomatch.tour" 2>&1)"
check "V-2 a pattern that matches nothing exits non-zero" "1" "$?"
printf %s "$v2none" | grep -q 'nope'
check "V-2 ...and names the pattern that no longer matches" "0" "$?"

# ---------------------------------------------------------------------------
# V-2s — ...and it stays relative when the caller stands behind a symlink
#
# The report is relative so it reads by eye and pipes into `nvim -q -`. It is
# made relative by comparing the file against the CLI's invocation directory —
# and those two arrive spelled differently whenever a symlink is involved. We
# run FROM the workspace root, where nvim's cwd is the real directory
# (`/private/var/...`); `$PWD` keeps the hop the caller walked through
# (`/var/...`, `/tmp/...`). One directory, two spellings, and a text prefix
# test says they are unrelated — so every path came out absolute.
#
# Nothing about the tour was wrong, which is what made this expensive: on macOS
# both `/tmp` and `$TMPDIR` are symlinks, so a contributor who cloned into one
# ran a clean tree and watched V-2 above go red on code they had never touched.
#
# Reproduced HERE rather than by hoping the checkout is symlinked: the link is
# built, so this fails on any machine when the fix is reverted, including a
# checkout sitting on a perfectly literal path.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/sl/real/src"
printf 'alpha\nbeta\ngamma\n' > "$WORK/sl/real/src/app.txt"
ln -s "$WORK/sl/real" "$WORK/sl/link"
printf '%s\n' '{ "title": "behind a symlink", "steps": [
  { "title": "p", "file": "src/app.txt", "pattern": "^beta$", "description": "d" } ] }' \
  > "$WORK/sl/real/sym.tour"
slout="$( cd "$WORK/sl/link" && "$WT" validate sym.tour 2>&1 )"
check "V-2s a tour under a symlinked directory still validates" "0" "$?"
printf %s "$slout" | grep -q '^src/app.txt:2:'
check "V-2s ...and the report is relative to where the caller stands" "0" "$?"
printf %s "$slout" | grep -q '^/'
check "V-2s ...not an absolute path the reader has to re-read" "1" "$?"

# the same for a step whose file is GONE: that message names a path too, and it
# is resolved before anyone knows the file is missing.
printf '%s\n' '{ "title": "behind a symlink, rotted", "steps": [
  { "title": "g", "file": "src/gone.txt", "line": 1, "description": "d" } ] }' \
  > "$WORK/sl/real/symrot.tour"
slrot="$( cd "$WORK/sl/link" && "$WT" validate symrot.tour 2>&1 )"
check "V-2s a missing file behind a symlink still fails" "1" "$?"
printf %s "$slrot" | grep -q 'file not found: src/gone.txt'
check "V-2s ...naming it relative to the caller as well" "0" "$?"

# ...and a file that is itself a symlink pointing OUT of the workspace is still
# named where the reader can see it, not at its target. The realpath comparison
# is a second chance for paths that would otherwise print absolute; it must not
# reach the ones that already resolve.
mkdir -p "$WORK/sl/outside"
printf 'alpha\nbeta\ngamma\n' > "$WORK/sl/outside/elsewhere.txt"
ln -s "$WORK/sl/outside/elsewhere.txt" "$WORK/sl/real/src/linked.txt"
printf '%s\n' '{ "title": "a symlinked file", "steps": [
  { "title": "p", "file": "src/linked.txt", "pattern": "^beta$", "description": "d" } ] }' \
  > "$WORK/sl/real/symfile.tour"
slfile="$( cd "$WORK/sl/link" && "$WT" validate symfile.tour 2>&1 )"
check "V-2s a step whose file is a symlink out of the tree still validates" "0" "$?"
printf %s "$slfile" | grep -q '^src/linked.txt:2:'
check "V-2s ...and is named as the tour spells it, not at its target" "0" "$?"

# ---------------------------------------------------------------------------
# V-3 — validate checks `line` steps too
#
# A step carrying a `line` used to be exempt from every check but its file's
# existence. Measured before the fix: `"line": 9999` against a five-line file
# exited 0 with no output, and the player then parked the reader on line 5 with
# the narration anchored there, `skipped` empty and no message. That is rot
# invisible to the gate whose entire purpose is catching rot — and asymmetric
# with `pattern`, which is checked strictly. SKILL.md's own worked example uses
# `line`, so the format the tool teaches was the one it could not check.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/v3"
printf 'one\ntwo\nthree\nfour\nfive\n' > "$WORK/v3/five.txt"
v3_tour() { # $1 = file to write, $2 = the line field, verbatim JSON
  printf '{ "title": "t", "steps": [ { "title": "past", "file": "%s", "line": %s, "description": "d" } ] }\n' \
    "$WORK/v3/five.txt" "$2" > "$1"
}
v3_tour "$WORK/v3/past.tour" 9999
v3out="$("$WT" validate "$WORK/v3/past.tour" 2>&1)"
check "V-3 a line past the end of the file exits non-zero" "1" "$?"
printf %s "$v3out" | grep -q 'past the end'
check "V-3 ...saying the line is past the end" "0" "$?"
printf %s "$v3out" | grep -q '5 lines'
check "V-3 ...and how long the file actually is" "0" "$?"

v3_tour "$WORK/v3/zero.tour" 0
"$WT" validate "$WORK/v3/zero.tour" >/dev/null 2>&1
check "V-3 line 0 exits non-zero too" "1" "$?"

v3_tour "$WORK/v3/float.tour" 2.7
v3f="$("$WT" validate "$WORK/v3/float.tour" 2>&1)"
check "V-3 a line that is not a whole number exits non-zero" "1" "$?"
printf %s "$v3f" | grep -q 'whole number'
check "V-3 ...saying which way it is malformed" "0" "$?"

v3_tour "$WORK/v3/good.tour" 5
"$WT" validate "$WORK/v3/good.tour" >/dev/null 2>&1
check "V-3 a line that IS in the file still exits 0" "0" "$?"
v3q="$("$WT" validate "$WORK/v3/good.tour" 2>&1)"
check "V-3 ...and line steps still report nothing" "" "$v3q"

# ---------------------------------------------------------------------------
# V-4 — a step that names no file is reported, not silently tolerated
#
# `check` skipped file-less steps entirely, so a CodeTour `directory` step (a
# form we deliberately do not implement) entered no problems and `validate`
# exited 0 — while `open` counted the same step as unplayable and died with
# "tour is not playable (run: walkthrough validate <tour>)". The error named a
# command that then said the tour was fine, and the reader went round in a
# circle. The two must agree.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/v4"
printf '%s\n' '{ "title": "with a directory step", "steps": [
  { "title": "dir", "directory": "src", "description": "d" },
  { "title": "s2", "file": "'"$WORK"'/v3/five.txt", "line": 1, "description": "d" } ] }' \
  > "$WORK/v4/dir.tour"
v4out="$("$WT" validate "$WORK/v4/dir.tour" 2>&1)"
check "V-4 a step with no file exits non-zero" "1" "$?"
printf %s "$v4out" | grep -q "no 'file'"
check "V-4 ...saying the step names no file" "0" "$?"
printf %s "$v4out" | grep -q 'dir'
check "V-4 ...and naming the step" "0" "$?"

# ...and `skips` — the question `open` asks — reports the same step rather than
# dropping it in silence, while still opening the rest of the tour.
v4skips="$( cd "$REPO" && nvim --headless --clean -l lua/walkthrough/validate.lua \
  skips "$WORK/v4/dir.tour" 2>/dev/null )"
check "V-4 skips exits 0 while a playable step remains" "0" "$?"
printf %s "$v4skips" | grep -q "no 'file'"
check "V-4 ...having named the dropped step on stdout, where open reports it" "0" "$?"

# ---------------------------------------------------------------------------
# OD — `open` DEGRADES where `validate` REFUSES
#
# The spec's error table: "Spec references a missing file/line -> Plugin skips
# that hunk, renders the rest, reports which were dropped. Partial is better
# than nothing; silence is not."
#
# `open` used to run the STRICT check as a precondition and die before nvim was
# ever launched, so one pattern that had drifted made a six-step tour
# unopenable. And past that gate the plugin dropped such a step in SILENCE:
# tour.validate calls a step playable if it merely HAS a `pattern` field, so an
# unmatched pattern never entered `skipped`, the cursor never moved and no
# narration rendered. Exit status alone cannot see the second half, so these
# checks look at what the player actually did.
#
# `validate` is unchanged and must stay that way: it is the CI rot gate.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/od/src"
printf 'alpha\nbeta\ngamma\n' > "$WORK/od/src/app.txt"
git -C "$WORK/od" init -q >/dev/null 2>&1

# step 2 is the rotted one in each; steps 1 and 3 are perfectly good.
printf '%s\n' '{ "title": "one stale pattern", "steps": [
  { "title": "s1", "file": "src/app.txt", "line": 1, "description": "d" },
  { "title": "stale", "file": "src/app.txt", "pattern": "^nope$", "description": "d" },
  { "title": "s3", "file": "src/app.txt", "line": 3, "description": "d" } ] }' > "$WORK/od/stale.tour"
printf '%s\n' '{ "title": "one missing file", "steps": [
  { "title": "s1", "file": "src/app.txt", "line": 1, "description": "d" },
  { "title": "vanished", "file": "src/gone.txt", "line": 1, "description": "d" },
  { "title": "s3", "file": "src/app.txt", "line": 3, "description": "d" } ] }' > "$WORK/od/missing.tour"
printf '%s\n' '{ "title": "nothing left", "steps": [
  { "title": "a", "file": "src/app.txt", "pattern": "^nope$", "description": "d" },
  { "title": "b", "file": "src/gone.txt", "line": 1, "description": "d" } ] }' > "$WORK/od/dead.tour"

od_err="$WORK/od/err.txt"
od_open() { # $1 = tour path, relative to $WORK/od
  od_out="$( cd "$WORK/od" && REPO="$REPO" XDG_CONFIG_HOME="$WORK/od/noconfig" bash -c '
      set -uo pipefail
      source "$REPO/bin/walkthrough" --help >/dev/null 2>&1
      load_backend()  { BACKEND=stub; }
      backend_close() { :; }
      backend_open()  {
        ( eval "${1/#nvim/nvim --headless}" ) </dev/null >/dev/null 2>&1 &
        echo stub-handle
      }
      cmd_open "$1"
    ' _ "$1" 2>"$od_err" )"
  od_rc=$?
  od_sock="$(printf %s "$od_out" | tail -1)"
}
od_player() { nvim --server "$od_sock" --remote-expr "$1" 2>/dev/null; }
od_skipped() {
  od_player 'luaeval("table.concat(require([[walkthrough]]).state().skipped, [[,]])")'
}
od_end() { nvim --server "$od_sock" --remote-expr 'execute("qa!")' >/dev/null 2>&1
           rm -f "$od_sock" "$STATE_FILE"; }

# 1. one pattern that matches nothing
"$WT" validate "$WORK/od/stale.tour" >/dev/null 2>&1
check "OD validate still hard-fails on a stale pattern" "1" "$?"
od_open stale.tour
check "OD open succeeds despite a stale pattern" "0" "$od_rc"
# Naming the step is not enough on its own to prove `open` DEGRADED: the old
# strict gate named it too, on its way to refusing the tour. So this check
# requires the name to appear under the drop banner, and requires the refusal
# to be absent — otherwise it stays green for a version of `open` that will
# not open anything.
grep -q 'stale' "$od_err" \
  && grep -q 'dropping unplayable step(s)' "$od_err" \
  && ! grep -q 'tour is not playable' "$od_err"
check "OD ...and open names the step it dropped, as a drop and not a refusal" "0" "$?"
grep -q 'matches nothing' "$od_err"
check "OD ...and says why" "0" "$?"
check "OD the player parked on step 1, in the workspace's own file" "1:alpha" \
  "$(od_player 'line(".") . ":" . getline(".")')"
# Exit status cannot see this half: the step is dropped INSIDE the player, and
# it must be named there too rather than leaving the cursor stranded.
check "OD nothing is skipped before the reader goes near the stale step" "" "$(od_skipped)"
od_player 'luaeval("(function() require([[walkthrough]]).goto_step(2) return 1 end)()")' >/dev/null
check "OD asking for the stale step names it in state().skipped" "stale" "$(od_skipped)"
check "OD ...and moves the reader on to a step that plays" "3" \
  "$(od_player 'luaeval("require([[walkthrough]]).state().index")')"
check "OD ...parked on that step's line, not left on line 1" "3:gamma" \
  "$(od_player 'line(".") . ":" . getline(".")')"
od_end

# 2. one file that is gone — named in the spec's error table by that exact name
"$WT" validate "$WORK/od/missing.tour" >/dev/null 2>&1
check "OD validate still hard-fails on a missing file" "1" "$?"
od_open missing.tour
check "OD open succeeds despite a missing file" "0" "$od_rc"
grep -q 'vanished' "$od_err" \
  && grep -q 'dropping unplayable step(s)' "$od_err" \
  && ! grep -q 'tour is not playable' "$od_err"
check "OD ...and open names the step it dropped, as a drop and not a refusal" "0" "$?"
check "OD the player reports the missing step in state().skipped" "vanished" "$(od_skipped)"
check "OD the player still plays the steps that remain" "1:alpha" \
  "$(od_player 'line(".") . ":" . getline(".")')"
od_end

# 3. nothing left to play is still a refusal — degrading is not surrendering
od_open dead.tour
check "OD open refuses a tour with no playable step at all" "1" "$od_rc"
grep -q 'no playable steps' "$od_err"
check "OD ...saying so" "0" "$?"
"$WT" validate "$WORK/od/dead.tour" >/dev/null 2>&1
check "OD validate refuses it too" "1" "$?"

# 4. a pattern that is not a vim regex AT ALL — the same drop, through the
# whole CLI. This is not the stale-pattern case wearing a different hat:
# `vim.regex` RAISES on an uncompilable pattern, and the raise reaches the
# player from render.apply (which draws every step in the buffer it is
# entering, from a BufEnter autocmd), not from nav.goto_index, whose pcall
# only ever guards the step being navigated TO. Measured before the fix: this
# printed the correct drop banner and then exited 1 with
# `E5108 ... couldn't parse regex: Vim:E53`, leaving a tour with two good
# steps unopenable. The bad step here is one the reader never asks for, so
# only the render pass can reach it.
printf '%s\n' '{ "title": "one uncompilable pattern", "steps": [
  { "title": "s1", "file": "src/app.txt", "line": 1, "description": "d" },
  { "title": "badre", "file": "src/app.txt", "pattern": "\\%(", "description": "d" },
  { "title": "s3", "file": "src/app.txt", "line": 3, "description": "d" } ] }' > "$WORK/od/badre.tour"
"$WT" validate "$WORK/od/badre.tour" >/dev/null 2>&1
check "OD validate still hard-fails on an uncompilable pattern" "1" "$?"
od_open badre.tour
check "OD open survives a pattern that is not a valid vim regex" "0" "$od_rc"
grep -q 'badre' "$od_err" \
  && grep -q 'dropping unplayable step(s)' "$od_err" \
  && ! grep -q 'E5108' "$od_err"
check "OD ...naming the dropped step without dying on it" "0" "$?"
check "OD the player is open and parked on the step that plays" "1:alpha" \
  "$(od_player 'line(".") . ":" . getline(".")')"
check "OD the uncompilable step is demoted inside the player too" "badre" "$(od_skipped)"
check "OD ...and the rest of the tour still plays" "3" \
  "$(od_player 'luaeval("(function() require([[walkthrough]]).goto_step(3) return require([[walkthrough]]).state().index end)()")')"
od_end

# 5a. a field vim cannot USE — the shape that outlived five layers of this fix
# and two independent fuzz runs.
#
# JSON numbers decode as doubles, so `1e30` is a WHOLE number: every `% 1 == 0`
# guard in the codebase waved it through. It does not fit in an int64, so vim
# converted it as a Float and `setqflist` raised E805 — inside nav.populate,
# the one step-field consumer with no pcall and no drop path. Measured before
# the fix, through this exact harness: the CLI printed the drop banner, having
# correctly decided the step was droppable, and the player then died anyway
# with `E5108: Lua: Vim:E805` and a stack traceback on the shell's stderr.
# 1e18 is BELOW the cliff and behaves perfectly, which is how a fuzz that
# stopped there came back clean.
printf '%s\n' '{ "title": "a line beyond int64", "steps": [
  { "title": "s1", "file": "src/app.txt", "line": 1, "description": "d" },
  { "title": "big", "file": "src/app.txt", "line": 1e30, "description": "d" },
  { "title": "s3", "file": "src/app.txt", "line": 3, "description": "d" } ] }' > "$WORK/od/bigline.tour"
bigout="$( cd "$WORK/od" && "$WT" validate bigline.tour 2>&1 )"
check "OD5a validate refuses a line beyond int64" "1" "$?"
printf %s "$bigout" | grep -q '1e+30'
check "OD5a ...naming the number the author actually wrote" "0" "$?"
printf %s "$bigout" | grep -q '9223372036854775807'
check "OD5a ...and not int64 max, a line that appears nowhere in the tour" "1" "$?"
od_open bigline.tour
check "OD5a open survives it" "0" "$od_rc"
grep -qE 'E805|stack traceback' "$od_err"
check "OD5a ...with no E805 and no traceback reaching the shell" "1" "$?"
grep -q 'dropping unplayable step(s)' "$od_err" && grep -q 'big' "$od_err"
check "OD5a ...reported as a drop, naming the step" "0" "$?"
check "OD5a the player is open and parked on the step that plays" "1:alpha" \
  "$(od_player 'line(".") . ":" . getline(".")')"
check "OD5a the step is demoted inside the player too" "big" "$(od_skipped)"
check "OD5a ...and the rest of the tour still plays" "3" \
  "$(od_player 'luaeval("(function() require([[walkthrough]]).goto_step(3) return require([[walkthrough]]).state().index end)()")')"
od_end

# 5b. a NUL in a drawable string. `"\u0000"` is legal JSON and decodes to a Lua
# string that passes `type(x) == "string"` — but vimscript has no string type
# that can hold a NUL, so the conversion produced a Blob and `setqflist` raised
# E976. `validate` exited 0 on this and `open` died on it: the complete
# validate/player asymmetry, one field over from where the previous wave closed
# it. The step's id is "2" because a title vim cannot hold is not a handle
# either — it would raise E976 again on its way back out through --remote-expr.
printf '%s\n' '{ "title": "a NUL in a title", "steps": [
  { "title": "s1", "file": "src/app.txt", "line": 1, "description": "d" },
  { "title": "n\u0000t", "file": "src/app.txt", "line": 2, "description": "d" },
  { "title": "s3", "file": "src/app.txt", "line": 3, "description": "d" } ] }' > "$WORK/od/nul.tour"
nulout="$( cd "$WORK/od" && "$WT" validate nul.tour 2>&1 )"
check "OD5b validate refuses a NUL in a title, where it used to exit 0" "1" "$?"
printf %s "$nulout" | grep -q 'NUL'
check "OD5b ...saying which field and why" "0" "$?"
od_open nul.tour
check "OD5b open survives it" "0" "$od_rc"
grep -qE 'E976|stack traceback' "$od_err"
check "OD5b ...with no E976 and no traceback reaching the shell" "1" "$?"
check "OD5b the player is open and parked on the step that plays" "1:alpha" \
  "$(od_player 'line(".") . ":" . getline(".")')"
check "OD5b the step is demoted inside the player too" "2" "$(od_skipped)"
od_end

# 5c. a malformed `selection` costs the step NOTHING. It is decoration — it
# moves a highlight and nothing else — and it used to be judged two opposite
# ways: `"selection": 5` fell back to the step's own line and played, while
# `{"start":{"character":1}}` raised inside math.max and lost the whole step.
# Both fall back now, and neither fails the CI gate over a highlight.
printf '%s\n' '{ "title": "a malformed selection", "steps": [
  { "title": "s1", "file": "src/app.txt", "line": 1, "description": "d",
    "selection": { "start": { "character": 1 }, "end": { "character": 4 } } },
  { "title": "s2", "file": "src/app.txt", "line": 2, "description": "d",
    "selection": 5 } ] }' > "$WORK/od/sel.tour"
selout="$( cd "$WORK/od" && "$WT" validate sel.tour 2>&1 )"
check "OD5c validate does not fail a tour over a decorative selection" "0" "$?"
printf %s "$selout" | grep -q 'selection'
check "OD5c ...but says the highlight fell back to the step's own line" "0" "$?"
od_open sel.tour
check "OD5c open plays it" "0" "$od_rc"
grep -q 'dropping unplayable step(s)' "$od_err"
check "OD5c ...dropping nothing" "1" "$?"
check "OD5c nothing is in skipped" "" "$(od_skipped)"
check "OD5c the reader is parked on the step's own line" "1:alpha" \
  "$(od_player 'line(".") . ":" . getline(".")')"
od_end

# 5d. ...and a selection that is not there at all is not a malformed one.
#
# `null` is JSON for "no value", and `vim.json.decode` renders it as `vim.NIL`
# — userdata, which is not `nil`. So the `s.selection ~= nil` test that guards
# the note above said yes about a field the document had explicitly declined
# to give, and `validate` reported a highlight falling back for a selection
# nobody wrote. Harmless to the step, and exactly the kind of report that
# teaches an author to stop reading them: it names a field they did not get
# wrong. Run through the CLI because that is where an author meets it — the
# note is printed by the real out-of-process `validate`, not in Lua.
printf '%s\n' '{ "title": "an absent selection", "steps": [
  { "title": "s1", "file": "src/app.txt", "line": 1, "description": "d",
    "selection": null },
  { "title": "s2", "file": "src/app.txt", "line": 2, "description": "d" } ] }' > "$WORK/od/nullsel.tour"
nullselout="$( cd "$WORK/od" && "$WT" validate nullsel.tour 2>&1 )"
check "OD5d validate passes a tour whose selection is null" "0" "$?"
printf %s "$nullselout" | grep -q 'selection'
check "OD5d ...and says nothing about a selection that was never there" "1" "$?"
check "OD5d ...leaving no report at all, as for a step with no selection" "" "$nullselout"
od_open nullsel.tour
check "OD5d open plays it" "0" "$od_rc"
grep -q 'dropping unplayable step(s)' "$od_err"
check "OD5d ...dropping nothing" "1" "$?"
check "OD5d the reader is parked on the step's own line" "1:alpha" \
  "$(od_player 'line(".") . ":" . getline(".")')"
od_end

# 5. a field that is the wrong SHAPE. schema.json declares `title` a string;
# nothing enforced the schema, so a title that is an object reached string
# concatenation inside the render pass, threw through the BufEnter autocmd and
# out of open() with a Lua traceback, every time, for the life of the tour
# file. A tour from a cloned repository is untrusted input by this project's
# own threat model, so an unanticipated shape has to degrade like everything
# else. `tour.validate` now type-checks the field, so `validate` refuses this
# tour and the player drops the one step — the two agree, which is the point.
# The malformed step is one the reader never asks for. Its id is "2" because a
# non-string title is not a handle.
printf '%s\n' '{ "title": "one malformed title", "steps": [
  { "title": "s1", "file": "src/app.txt", "line": 1, "description": "d" },
  { "title": { "x": 1 }, "file": "src/app.txt", "line": 2, "description": "d" },
  { "title": "s3", "file": "src/app.txt", "line": 3, "description": "d" } ] }' > "$WORK/od/shape.tour"
od_open shape.tour
check "OD open survives a step whose title is an object" "0" "$od_rc"
grep -q 'E5108' "$od_err"
check "OD ...without a Lua traceback reaching the shell" "1" "$?"
check "OD the player is open and parked on the step that plays" "1:alpha" \
  "$(od_player 'line(".") . ":" . getline(".")')"
check "OD the step that could not be drawn is demoted inside the player" "2" "$(od_skipped)"
check "OD ...and the rest of the tour still plays" "3" \
  "$(od_player 'luaeval("(function() require([[walkthrough]]).goto_step(3) return require([[walkthrough]]).state().index end)()")')"

# ---------------------------------------------------------------------------
# RL — a reload that cannot play leaves the walkthrough it had, and says so
#
# cmd_reload threw away the exit status of its --remote-expr call, so a failed
# reload looked exactly like a successful one to the shell (and to the agent
# reading that status). On the player's side reload() had already flipped
# inactive, detached every keymap and re-read every buffer before open() could
# fail — leaving `active = false` while state() still described the old tour,
# with no close key and a raw Lua traceback coming back through the CLI.
#
# This runs against the player left open by the case above, through the real
# state file the real cmd_open wrote.
# ---------------------------------------------------------------------------
rlerr="$("$WT" reload "$WORK/od/dead.tour" 2>&1 >/dev/null)"
check "RL a reload whose tour cannot play exits non-zero" "1" "$?"
printf %s "$rlerr" | grep -q 'reload failed'
check "RL ...saying the reload failed" "0" "$?"
printf %s "$rlerr" | grep -q 'stack traceback'
check "RL ...and not as a raw Lua traceback" "1" "$?"
check "RL the player is still active" "true" \
  "$(od_player 'luaeval("tostring(require([[walkthrough]]).state().active)")')"
check "RL ...on the tour it had before the reload" "one malformed title" \
  "$(od_player 'luaeval("require([[walkthrough]]).state().title")')"
od_end

# ---------------------------------------------------------------------------
# WR — a workspace root that cannot be entered says so
#
# Every out-of-process tour inspection runs FROM the workspace root, because
# that is what a step's `file` is relative to. That cd used to fail in
# silence — so a root deleted (or made unreadable) under a long session came
# back as `open` saying "tour is not playable (run: walkthrough validate ...)",
# sending the reader off to fix a tour that was never wrong. Two different
# repairs; they must not share a message.
# ---------------------------------------------------------------------------
wr_err="$( cd "$REPO" && bash -c '
    set -uo pipefail
    source ./bin/walkthrough --help >/dev/null 2>&1
    lua_tour check "$1" "$2"
  ' _ "$REPO/tests/fixtures/two_files.tour" "$WORK/no/such/root" 2>&1 >/dev/null )"
wr_rc=$?
# The exit status alone proves nothing here — the silent version exited 1 too.
# What the failure SAYS is the whole finding, so it is asserted with it.
[ "$wr_rc" = 1 ] && printf %s "$wr_err" | grep -q 'cannot enter the workspace root'
check "WR a missing workspace root fails, saying that is what it could not enter" "0" "$?"
[ "$wr_rc" = 1 ] && printf %s "$wr_err" | grep -qF "$WORK/no/such/root"
check "WR ...and naming the root, not the tour" "0" "$?"

# ...and `open` must not go on to launch a player over no files at all. The
# file list crosses a process substitution, which throws the exit status away,
# so an empty list is the only evidence left that it never ran. (Without the
# guard `open` does eventually fail — nine seconds later, waiting for a socket
# that was never going to appear, having already opened a surface.)
rm -f "$WORK/od/launched"
( cd "$WORK/od" && REPO="$REPO" WORK="$WORK" bash -c '
    set -uo pipefail
    source "$REPO/bin/walkthrough" --help >/dev/null 2>&1
    load_backend()  { BACKEND=stub; }
    backend_close() { :; }
    backend_open()  { echo launched > "$WORK/od/launched"; echo stub-handle; }
    tour_files()    { :; }
    cmd_open stale.tour
  ' >/dev/null 2>"$WORK/od/wr_err.txt" )
wr_rc=$?
[ "$wr_rc" = 1 ] && grep -q 'no files to open' "$WORK/od/wr_err.txt"
check "WR open refuses an empty file list, saying that is what was empty" "0" "$?"
if [ -e "$WORK/od/launched" ]; then wr_launched=yes; else wr_launched=no; fi
check "WR ...and refuses before a surface is opened over nothing" "no" "$wr_launched"

# ---------------------------------------------------------------------------
# GD — the workspace root comes from the DIRECTORY, not from inherited git env
#
# GIT_DIR and GIT_WORK_TREE set together make `rev-parse --show-toplevel`
# answer about a different repository, which would move the base every step's
# `file` resolves against. Not execution (the value stays base64-armoured and
# is only a chdir target), but the wrong workspace all the same.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/gd/a" "$WORK/gd/b"
git -C "$WORK/gd/a" init -q >/dev/null 2>&1
git -C "$WORK/gd/b" init -q >/dev/null 2>&1
gd_want="$( cd "$WORK/gd/b" && pwd -P )"
gd_got="$( cd "$WORK/gd/b" && REPO="$REPO" \
    GIT_DIR="$WORK/gd/a/.git" GIT_WORK_TREE="$WORK/gd/a" bash -c '
      set -uo pipefail
      source "$REPO/bin/walkthrough" --help >/dev/null 2>&1
      wt_workspace_root
    ' _ )"
check "GD an inherited GIT_DIR/GIT_WORK_TREE pair does not move the workspace root" \
  "$gd_want" "$gd_got"

# ---------------------------------------------------------------------------
# R3 — the "which tours failed" line must be readable back
#
# `${failed[*]}` joins with a space, so `a b.tour` and `a.tour b.tour` printed
# identically: the one line whose whole job is naming the failures could not be
# used to name them.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/r3"
printf '{ "title": "rot", "steps": [ { "file": "gone.txt", "line": 1, "description": "d" } ] }\n' \
  > "$WORK/r3/a b.tour"
cp "$WORK/r3/a b.tour" "$WORK/r3/c.tour"
r3out="$("$WT" validate "$WORK/r3/a b.tour" "$WORK/r3/c.tour" 2>&1 >/dev/null)"
r3n="$(printf '%s\n' "$r3out" | grep -c '^  ' || true)"
check "R3 the summary lists one failed tour per line" "2" "$r3n"
r3hit="$(printf '%s\n' "$r3out" | grep -cFx "  $WORK/r3/a b.tour" || true)"
check "R3 a tour path containing a space survives whole on its own line" "1" "$r3hit"

# ---------------------------------------------------------------------------
# R4 — validate's report must be usable from where the READER is standing
#
# The report is produced from the workspace root, because that is what a step's
# `file` is relative to, but it is printed to a shell whose cwd may be a
# subdirectory. `src/app.txt:2:` typed back at someone sitting in sub/ names a
# different file or none at all, and the `nvim -q -` pipe the format advertises
# resolves it against THEIR cwd.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/r4/src" "$WORK/r4/sub" "$WORK/r4/.tours"
git -C "$WORK/r4" init -q >/dev/null 2>&1
printf 'alpha\nbeta\ngamma\n' > "$WORK/r4/src/app.txt"
printf '%s\n' '{ "title": "t", "steps": [ { "title": "s1", "file": "src/app.txt",
  "pattern": "^beta$", "description": "d" } ] }' > "$WORK/r4/.tours/t.tour"
r4line="$( cd "$WORK/r4/sub" && "$WT" validate "$WORK/r4/.tours/t.tour" 2>&1 | head -1 )"
r4path="${r4line%%:*}"
r4num="$(printf %s "$r4line" | cut -d: -f2)"
check "R4 the report still names the resolved line number" "2" "$r4num"
r4got="$( cd "$WORK/r4/sub" && sed -n "${r4num}p" "$r4path" 2>/dev/null )"
check "R4 the reported path opens, from the subdirectory it was printed to" "beta" "$r4got"

# ---------------------------------------------------------------------------
# L5 — `list` and `usage` must agree about which .tours/ is meant
#
# usage() says paths resolve against the workspace root; cmd_list resolved its
# default against the CLI's cwd, so `walkthrough list` from a subdirectory
# reported "no tours" about a project that has them.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/l5/.tours" "$WORK/l5/deep/deeper"
git -C "$WORK/l5" init -q >/dev/null 2>&1
cp tests/fixtures/two_files.tour "$WORK/l5/.tours/"
( cd "$WORK/l5/deep/deeper" && "$WT" list | grep -q 'two_files.tour' )
check "L5 list finds the workspace root's tours from a subdirectory" "0" "$?"
( cd "$WORK/l5/deep" && "$WT" list ../.tours | grep -q 'two_files.tour' )
check "L5 an explicit directory is still taken relative to the cwd" "0" "$?"
( cd "$WORK/l5/deep" && "$WT" list ../../.tours >/dev/null 2>&1 )
check "L5 ...and an explicit directory that has no tours still fails" "1" "$?"

# ---------------------------------------------------------------------------
# WS — a step's `file` resolves against the WORKSPACE ROOT, wherever the CLI
#      was invoked and wherever the .tour file itself happens to live
#
# CodeTour paths are relative to the workspace root. Nothing used to pin the
# spawned nvim's cwd, so the player resolved every step's `file` against
# whatever directory the fresh terminal happened to start in: with a same-named
# file there it silently played a stranger's code, and without one `open` died
# with "no playable steps". Every other test in this file misses it because
# they all run from the repo root, which is the one directory where the bug is
# invisible.
#
# The root is the git root of the CLI's invocation directory (an agent's cwd is
# unpredictable, so `open` has to work from anywhere in the tree), falling back
# to that directory when there is no repository. The .tour file's own location
# is deliberately NOT consulted: a durable tour lives next to what it explains
# (sub/.tours/x.tour) and a throwaway one lives in a temp directory outside the
# repository, and both carry repo-root-relative paths.
#
# The stub backend below runs the launch command from a DIFFERENT directory,
# which is exactly what a freshly spawned terminal does. The command is run for
# real — only `--headless` is added — so this exercises the actual launch
# command, the real socket wait and the real open expression.
# ---------------------------------------------------------------------------

# One fixture workspace, used by every case below.
#   repo/            a git repository
#     src/app.txt        the file the tours name, repo-root-relative
#     src/only-here.txt  exists ONLY at the root
#     sub/               a subdirectory the CLI is invoked from
#     sub/src/app.txt    a DECOY: what "src/app.txt" means from sub/
#     sub/.tours/        a nested tour directory
#   elsewhere/src/app.txt  another decoy: what it means in the terminal's cwd
mkdir -p "$WORK/ws/repo/src" "$WORK/ws/repo/sub/src" "$WORK/ws/repo/sub/.tours" \
         "$WORK/ws/repo/.tours" "$WORK/ws/elsewhere/src" "$WORK/ws/loose/src" \
         "$WORK/ws/tmptour"
printf 'alpha\nbeta\ngamma\n' > "$WORK/ws/repo/src/app.txt"
printf 'only here\n'          > "$WORK/ws/repo/src/only-here.txt"
printf 'WRONG\nWRONG\nWRONG\n' > "$WORK/ws/repo/sub/src/app.txt"
printf 'WRONG\nWRONG\nWRONG\n' > "$WORK/ws/elsewhere/src/app.txt"
printf 'alpha\nbeta\ngamma\n' > "$WORK/ws/loose/src/app.txt"
printf 'only here\n'          > "$WORK/ws/loose/src/only-here.txt"
git -C "$WORK/ws/repo" init -q >/dev/null 2>&1

# Step 1 covers the silent form of the bug (a decoy of the same name sits at
# every wrong base, so a wrong root parks the player in a stranger's file);
# step 2 covers the loud form (it exists only at the true root, so a wrong root
# reports it missing and refuses to open the tour at all).
ws_tour() { # $1 = path to write the tour to
  cat > "$1" <<'TOUR'
{ "title": "repo-root-relative paths",
  "steps": [ { "title": "s1", "file": "src/app.txt", "pattern": "^beta$",
               "description": "resolved against the workspace root" },
             { "title": "s2", "file": "src/only-here.txt", "line": 1,
               "description": "exists only at the workspace root" } ] }
TOUR
}
ws_tour "$WORK/ws/repo/.tours/root.tour"       # a tour at the repository root
ws_tour "$WORK/ws/repo/sub/.tours/nested.tour" # co-located with what it explains
ws_tour "$WORK/ws/tmptour/throwaway.tour"      # written outside the repository
ws_tour "$WORK/ws/loose/loose.tour"            # no repository at all

ws_open() { # $1 = directory to invoke the CLI from, $2 = tour path
  ws_out="$( cd "$1" && \
    REPO="$REPO" ELSEWHERE="$WORK/ws/elsewhere" XDG_CONFIG_HOME="$WORK/ws/noconfig" \
    bash -c '
      set -uo pipefail
      source "$REPO/bin/walkthrough" --help >/dev/null 2>&1
      load_backend()  { BACKEND=stub; }
      backend_close() { :; }
      # A fresh terminal, somewhere else, running the command it was handed.
      # The subshell as a whole is detached from this stdout, or the command
      # substitution capturing the handle would wait for nvim to exit.
      backend_open()  {
        ( cd "$ELSEWHERE" && eval "${1/#nvim/nvim --headless}" ) </dev/null >/dev/null 2>&1 &
        echo stub-handle
      }
      cmd_open "$1"
    ' _ "$2" 2>/dev/null )"
  ws_rc=$?
  ws_sock="$(printf %s "$ws_out" | tail -1)"
}

ws_expect() { # $1 = label, $2 = glob the played buffer must match
  check "WS $1: open succeeds" "0" "$ws_rc"
  check "WS $1: parked on the step's line, in the workspace's own file" "2:beta" \
    "$(nvim --server "$ws_sock" --remote-expr 'line(".") . ":" . getline(".")' 2>/dev/null)"
  ws_buf="$(nvim --server "$ws_sock" --remote-expr 'expand("%:p")' 2>/dev/null)"
  # shellcheck disable=SC2254  # $2 is a glob on purpose
  case "$ws_buf" in $2) ws_b=0 ;; *) ws_b=1 ;; esac
  check "WS $1: the buffer is the workspace file, not a same-named decoy" "0" "$ws_b"
  check "WS $1: no step was skipped as unreadable" "0" \
    "$(nvim --server "$ws_sock" \
        --remote-expr 'luaeval("#require([[walkthrough]]).state().skipped")' 2>/dev/null)"
  nvim --server "$ws_sock" --remote-expr 'execute("qa!")' >/dev/null 2>&1
  rm -f "$ws_sock" "$STATE_FILE"
}

# 1. invoked from a subdirectory, tour at the repository root — the reported bug
ws_open "$WORK/ws/repo/sub" "../.tours/root.tour"
ws_expect "root tour from a subdirectory" '*/ws/repo/src/app.txt'

# 2. invoked from a subdirectory, tour co-located in sub/.tours/
ws_open "$WORK/ws/repo/sub" ".tours/nested.tour"
ws_expect "nested tour from a subdirectory" '*/ws/repo/src/app.txt'

# 3. invoked from a subdirectory, tour in a temp directory outside the repo
ws_open "$WORK/ws/repo/sub" "$WORK/ws/tmptour/throwaway.tour"
ws_expect "throwaway tour outside the repository" '*/ws/repo/src/app.txt'

# 4. no repository anywhere: the invocation directory IS the root
ws_open "$WORK/ws/loose" "loose.tour"
ws_expect "no repository, invocation directory is the root" '*/ws/loose/src/app.txt'

[ "$fail" -eq 0 ] && echo "CLI TESTS PASSED"
exit "$fail"
