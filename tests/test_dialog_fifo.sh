#!/usr/bin/env bash
# The dialog transport. Two negative controls are mandatory here, not
# nice-to-have (docs/dialog-design.md § Decisions, OQ-1): a write with no
# reader must return ENXIO without blocking, and every "the question arrived"
# assertion must distinguish arrival from a reader that was never blocked.
set -u
cd "$(dirname "$0")/.." || exit 1
REPO="$PWD"
fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; else echo "  FAIL: $1 (want $2, got $3)"; fail=1; fi }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/walkthrough-dialog.XXXXXX")" || exit 1
export XDG_RUNTIME_DIR="$WORK/xdg"
mkdir -p "$XDG_RUNTIME_DIR"
PIDS=()
# shellcheck disable=SC2317,SC2329  # invoked by trap; shellcheck 0.11.0 files
# this false positive as SC2329 and older versions as SC2317.
cleanup() {
  for p in ${PIDS+"${PIDS[@]}"}; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT

FIFO="$WORK/dialog.fifo"; mkfifo -m 600 "$FIFO"

# ---------------------------------------------------------------------------
# The reader returns non-zero and prints NOTHING when nobody asks.
#
# This is the control that gives every "it arrived" assertion below its
# meaning. Without it, a reader that returns empty immediately passes an
# arrival test that only checks exit status.
# ---------------------------------------------------------------------------
t0=$(date +%s)
out="$(nvim --headless --clean -l "$REPO/lua/walkthrough/await.lua" "$FIFO" 1200 2>"$WORK/e1")"
rc=$?
t1=$(date +%s)
check "no question: exits 4" "4" "$rc"
check "no question: prints nothing" "" "$out"
if [ $((t1 - t0)) -le 8 ]; then within_budget=0; else within_budget=1; fi
check "no question: returns inside its budget" "0" "$within_budget"

# ---------------------------------------------------------------------------
# Delivery while a reader is attached.
#
# This asserts the property directly: while await's reader is up, a
# non-blocking writer's open must SUCCEED and the write must be delivered.
# That is the whole mechanism the transport depends on.
#
# NOT a regression guard against `exec 3<>fifo`: an earlier version of this
# comment claimed an O_RDWR reader (what `exec 3<>fifo` produces) measures as
# no reader to the writer, so this test would catch a "simplification" to
# that spelling. Tested directly and that claim was wrong — an O_RDWR reader
# is also seen as a reader here, in bash, in nvim, and via a raw open(2). This
# test still checks a real, necessary property (see await.lua's own header
# comment for why O_RDONLY|O_NONBLOCK is used anyway), but it does not
# distinguish that implementation from an O_RDWR one, and must not be read as
# proof against it.
# ---------------------------------------------------------------------------
cat > "$WORK/try-open.lua" <<'LUA'
local uv = vim.uv or vim.loop
local fd, _, name = uv.fs_open(_G.arg[1],
  bit.bor(uv.constants.O_WRONLY, uv.constants.O_NONBLOCK), tonumber("600", 8))
if fd then uv.fs_write(fd, _G.arg[2]) uv.fs_close(fd) io.write("OPENED\n") os.exit(0) end
io.write(tostring(name), "\n") os.exit(1)
LUA
nvim --headless --clean -l "$REPO/lua/walkthrough/await.lua" "$FIFO" 6000 "$WORK/ready" \
  > "$WORK/q1" 2>/dev/null &
RPID=$!; PIDS+=("$RPID")
n=0; while [ ! -f "$WORK/ready" ] && [ "$n" -lt 200000 ]; do n=$((n + 1)); done
kill -0 "$RPID" 2>/dev/null; check "reader is still running before the write" "0" "$?"
check "reader has printed nothing before the write" "0" "$(wc -c < "$WORK/q1" | tr -d ' ')"
opened="$(nvim --headless --clean -l "$WORK/try-open.lua" "$FIFO" '{"question":"why"}
')"
check "a non-blocking writer can deliver to await's reader" "OPENED" "$opened"
wait "$RPID"; check "reader exits 0 once a question arrives" "0" "$?"
check "reader printed the question verbatim" '{"question":"why"}' "$(cat "$WORK/q1")"

# ---------------------------------------------------------------------------
# P1 — a question with no agent attached is refused, FAST, and nothing blocks.
#
# Identical-if-broken: asserting only "an error was reported" passes on an
# implementation that blocked for nine seconds first and then gave up. So the
# assertion is on the WALL CLOCK as well as on the message.
# ---------------------------------------------------------------------------
cat > "$WORK/send.lua" <<'LUA'
vim.opt.runtimepath:append(vim.env.WT_REPO)
local channel = require("walkthrough.channel")
local uv = vim.uv or vim.loop
local t0 = uv.hrtime() / 1e6
local ok, reason, msg = channel.send(_G.arg[1], _G.arg[2] or "hello")
-- io.write, not print: nvim's `print` in --headless -l mode writes to
-- STDERR (verified directly), not stdout, so a bare $(...) capture of it is
-- always empty regardless of channel.lua's correctness. Every other script
-- in this suite (await.lua, try-open.lua, validate.lua) already avoids
-- print() for exactly this reason.
io.write(string.format("%s|%s|%s|%.1f\n", tostring(ok), tostring(reason),
  tostring(msg), uv.hrtime() / 1e6 - t0))
os.exit(0)
LUA
res="$(WT_REPO="$REPO" nvim --headless --clean -l "$WORK/send.lua" "$FIFO")"
check "no reader: send refuses"        "false"     "$(echo "$res" | cut -d'|' -f1)"
check "no reader: reason is no_reader" "no_reader" "$(echo "$res" | cut -d'|' -f2)"
case "$(echo "$res" | cut -d'|' -f3)" in
  *"no agent is listening"*) check "no reader: the message names it" "0" "0" ;;
  *) check "no reader: the message names it" "0" "1 ($res)" ;;
esac
took="$(echo "$res" | cut -d'|' -f4)"
awk -v t="$took" 'BEGIN { exit !(t < 100) }'
check "no reader: refused in under 100ms (took ${took}ms)" "0" "$?"

# The negative control the design mandates: with the non-blocking flag removed,
# the SAME write must hang. Without this, "it returned quickly" is a claim about
# nothing — it would read the same on a platform where the flag does not matter.
cat > "$WORK/blocking.lua" <<'LUA'
local uv = vim.uv or vim.loop
uv.fs_open(_G.arg[1], uv.constants.O_WRONLY, tonumber("600", 8))
print("RETURNED")
os.exit(0)
LUA
nvim --headless --clean -l "$WORK/blocking.lua" "$FIFO" > "$WORK/blocked" 2>&1 &
BPID=$!; PIDS+=("$BPID")
n=0; while [ "$n" -lt 400000 ]; do n=$((n + 1)); done
kill -0 "$BPID" 2>/dev/null
check "control: WITHOUT O_NONBLOCK the same open hangs" "0" "$?"
check "control: and it printed nothing"                 "0" "$(wc -c < "$WORK/blocked" | tr -d ' ')"
# -9, not a plain TERM: verified directly on this machine that a process
# blocked in a synchronous open(2) on a FIFO with no reader does not respond
# to SIGTERM (open() is restarted after EINTR), so a plain `kill` here would
# leave this reap — and the whole suite — hanging forever.
kill -9 "$BPID" 2>/dev/null; wait "$BPID" 2>/dev/null

# A question longer than the cap is refused before any fd is opened. Issue #11
# notes no field in this project has a size limit; this one does, because on a
# non-blocking fd a write past PIPE_BUF may be short, and a short write must be
# reported rather than retried — retrying is how a non-blocking writer talks
# itself back into blocking.
#
# A live reader is attached first so ok=false can only mean too_long: with no
# reader at all, ok=false is also exactly what no_reader looks like, and
# "refused" below could not tell the two apart (caught in review — reverting
# MAX_BYTES alone produced only 1 FAIL, not 2, because this check was
# decorative). Nothing is ever delivered to this reader — the oversized send
# is refused before any fd is opened — so it is reaped by PID right after,
# not left to run out its budget.
nvim --headless --clean -l "$REPO/lua/walkthrough/await.lua" "$FIFO" 5000 "$WORK/ready2" \
  > "$WORK/q2" 2>/dev/null &
OPID=$!; PIDS+=("$OPID")
n=0; while [ ! -f "$WORK/ready2" ] && [ "$n" -lt 200000 ]; do n=$((n + 1)); done
kill -0 "$OPID" 2>/dev/null; check "oversized question: reader is attached before the send" "0" "$?"

big="$(awk 'BEGIN { for (i = 0; i < 3000; i++) printf "x" }')"
res="$(WT_REPO="$REPO" nvim --headless --clean -l "$WORK/send.lua" "$FIFO" "$big")"
check "oversized question: refused" "false"    "$(echo "$res" | cut -d'|' -f1)"
check "oversized question: reason"  "too_long" "$(echo "$res" | cut -d'|' -f2)"

# Reap: a plain TERM is enough here (the reader is parked in a sleep loop, not
# a blocking syscall — unlike the O_WRONLY control above, which is why that
# one needed -9), but escalate if it somehow doesn't go down.
kill "$OPID" 2>/dev/null
n=0; while kill -0 "$OPID" 2>/dev/null && [ "$n" -lt 50 ]; do n=$((n + 1)); sleep 0.1; done
kill -0 "$OPID" 2>/dev/null && kill -9 "$OPID" 2>/dev/null
wait "$OPID" 2>/dev/null


# ---------------------------------------------------------------------------
# P5 — teardown removes the FIFO on the path the reader ACTUALLY uses.
#
# Identical-if-broken: asserting only "the path does not exist afterwards"
# passes if the FIFO was never created, and passes on the `walkthrough close`
# path while leaking on the common one. So: assert it exists WHILE the
# walkthrough is open, then that <leader>aq's own code path removed it.
# ---------------------------------------------------------------------------
P5="$WORK/p5"; mkdir -p "$P5"
mkfifo -m 600 "$P5/dialog.fifo"; touch "$P5/state" "$P5/sock"
cat > "$P5/drive.lua" <<'LUA'
vim.opt.runtimepath:append(vim.env.WT_REPO)
vim.env.WALKTHROUGH_STATE  = vim.env.WT_STATE
vim.env.WALKTHROUGH_SOCKET = vim.env.WT_SOCKET
vim.env.WALKTHROUGH_DIALOG = vim.env.WT_FIFO
local wt = require("walkthrough")
wt.setup({ close_surface = false })
wt.open(vim.env.WT_TOUR)
assert(vim.uv.fs_stat(vim.env.WT_FIFO), "the FIFO must exist while the walkthrough is open")
-- This is what <leader>aq is bound to. Not the CLI's close.
wt.close()
os.exit(0)
LUA
( cd "$REPO" && WT_REPO="$REPO" WT_STATE="$P5/state" WT_SOCKET="$P5/sock" \
    WT_FIFO="$P5/dialog.fifo" WT_TOUR="$REPO/tests/fixtures/two_files.tour" \
    nvim --headless --clean -l "$P5/drive.lua" >/dev/null 2>&1 )
check "the FIFO existed while the walkthrough was open" "0" "$?"
if [ -e "$P5/dialog.fifo" ]; then fifo_gone=0; else fifo_gone=1; fi
check "<leader>aq removes the FIFO" "1" "$fifo_gone"

# ---------------------------------------------------------------------------
# OQ-3 — a question refused for want of a reader is KEPT and sent when one
# arrives. The failure this must not produce is a question landing minutes later
# that the reader had lost interest in, so: it announces itself, it can be
# cancelled for as long as it is pending, and it does not fire if the reader
# changed their mind.
# ---------------------------------------------------------------------------
Q="$WORK/q"; mkdir -p "$Q"; mkfifo -m 600 "$Q/dialog.fifo"
cat > "$Q/pending.lua" <<'LUA'
vim.opt.runtimepath:append(vim.env.WT_REPO)
vim.env.WALKTHROUGH_DIALOG = vim.env.WT_FIFO
local wt = require("walkthrough")
local dialog = require("walkthrough.dialog")
wt.setup({ close_surface = false })
wt.open(vim.env.WT_TOUR)
wt.ask()
-- No reader exists yet: this must be refused, kept, and announced.
dialog.submit("why not a plain spawn here?")
local p = dialog.pending()
-- write/close as SEPARATE statements: this nvim's Lua file:write() returns a
-- bare `true`, not the file handle, so a chained :write(...):close() throws
-- "attempt to index a boolean value" -- caught only by running this, not by
-- reading it.
local f = io.open(vim.env.WT_OUT, "w")
f:write(table.concat({
  tostring(p ~= nil),
  tostring(p and p.text or ""),
  tostring(vim.iter(vim.api.nvim_buf_get_lines(dialog.bufnr(), 0, -1, false))
    :any(function(l) return l:find("will send", 1, true) end)),
}, "|"))
f:close()
os.exit(0)
LUA
( cd "$REPO" && WT_REPO="$REPO" WT_FIFO="$Q/dialog.fifo" WT_OUT="$Q/out" \
    WT_TOUR="$REPO/tests/fixtures/two_files.tour" \
    nvim --headless --clean -l "$Q/pending.lua" >/dev/null 2>&1 )
res="$(cat "$Q/out")"
check "refused: the question is kept"          "true" "$(echo "$res" | cut -d'|' -f1)"
check "refused: kept verbatim"  "why not a plain spawn here?" "$(echo "$res" | cut -d'|' -f2)"
check "refused: the wait announces itself"     "true" "$(echo "$res" | cut -d'|' -f3)"

# ...and it actually goes when a reader turns up. The reader is started FIRST
# here and observed waiting, so "it arrived" is not confused with "it was never
# refused in the first place".
cat > "$Q/autosend.lua" <<'LUA'
vim.opt.runtimepath:append(vim.env.WT_REPO)
vim.env.WALKTHROUGH_DIALOG = vim.env.WT_FIFO
local wt = require("walkthrough")
local dialog = require("walkthrough.dialog")
wt.setup({ close_surface = false })
wt.open(vim.env.WT_TOUR)
wt.ask()
dialog.submit("why not a plain spawn here?")
assert(dialog.pending(), "must be pending: no reader yet")
-- Let the retry timer run. vim.wait pumps the event loop, which uv timers need.
vim.wait(20000, function() return dialog.pending() == nil end, 100)
local f = io.open(vim.env.WT_OUT, "w")
f:write(tostring(dialog.pending() == nil))
f:close()
os.exit(0)
LUA
( cd "$REPO" && WT_REPO="$REPO" WT_FIFO="$Q/dialog.fifo" WT_OUT="$Q/sent" \
    WT_TOUR="$REPO/tests/fixtures/two_files.tour" \
    nvim --headless --clean -l "$Q/autosend.lua" >/dev/null 2>&1 ) &
APID=$!; PIDS+=("$APID")
# The reader arrives late, on purpose.
n=0; while [ "$n" -lt 400000 ]; do n=$((n + 1)); done
got="$(nvim --headless --clean -l "$REPO/lua/walkthrough/await.lua" "$Q/dialog.fifo" 15000 2>/dev/null)"
wait "$APID"
check "auto-send: the kept question reached a reader that arrived later" "1" \
  "$(printf '%s' "$got" | grep -c 'plain spawn' | tr -d ' ')"
check "auto-send: the pending queue is empty afterwards" "true" "$(cat "$Q/sent")"

# ---------------------------------------------------------------------------
# OQ-3, the other binding half: a queued question does NOT fire if the reader
# edited or cleared the prompt line since. Submitted with NO reader attached
# (so it queues, exactly like the pending/auto-send tests above), edited
# immediately after, and only THEN does a reader turn up -- late, same as the
# auto-send test, so this cannot pass merely because no reader ever arrived.
# If the guard in `attempt` were missing, this late reader would receive the
# stale question instead of timing out with nothing.
# ---------------------------------------------------------------------------
cat > "$Q/edited.lua" <<'LUA'
vim.opt.runtimepath:append(vim.env.WT_REPO)
vim.env.WALKTHROUGH_DIALOG = vim.env.WT_FIFO
local wt = require("walkthrough")
local dialog = require("walkthrough.dialog")
wt.setup({ close_surface = false })
wt.open(vim.env.WT_TOUR)
wt.ask()
dialog.submit("why not a plain spawn here?")
assert(dialog.pending(), "must be pending: no reader yet")
-- The reader changed their mind before any reader turned up.
local buf = dialog.bufnr()
local last = vim.api.nvim_buf_line_count(buf)
vim.api.nvim_buf_set_lines(buf, last - 1, last, false, { "> never mind" })
vim.wait(20000, function() return dialog.pending() == nil end, 100)
local dropped_msg = vim.iter(vim.api.nvim_buf_get_lines(buf, 0, -1, false)):any(function(l)
  return l:find("you changed the question", 1, true)
end)
local f = io.open(vim.env.WT_OUT, "w")
f:write(table.concat({
  tostring(dialog.pending() == nil),
  tostring(dropped_msg),
}, "|"))
f:close()
os.exit(0)
LUA
( cd "$REPO" && WT_REPO="$REPO" WT_FIFO="$Q/dialog.fifo" WT_OUT="$Q/e_out" \
    WT_TOUR="$REPO/tests/fixtures/two_files.tour" \
    nvim --headless --clean -l "$Q/edited.lua" >/dev/null 2>&1 ) &
EPID=$!; PIDS+=("$EPID")
# The reader arrives late, on purpose -- same delay as the auto-send test, so
# a reader IS listening by the time the retry ticks, and would receive the
# stale question if the "you changed it" guard were not there.
n=0; while [ "$n" -lt 400000 ]; do n=$((n + 1)); done
e_got="$(nvim --headless --clean -l "$REPO/lua/walkthrough/await.lua" "$Q/dialog.fifo" 6000 2>/dev/null)"
e_grc=$?
wait "$EPID"
eres="$(cat "$Q/e_out")"
check "edited: the stale question is dropped, not kept forever" "true" "$(echo "$eres" | cut -d'|' -f1)"
check "edited: the drop is announced"                            "true" "$(echo "$eres" | cut -d'|' -f2)"
check "edited: the late reader received NOTHING (times out)"    "4"    "$e_grc"
check "edited: ...and printed nothing"           "0" "$(printf '%s' "$e_got" | wc -c | tr -d ' ')"

# ---------------------------------------------------------------------------
# P2 — a question delivered to a blocked reader arrives BECAUSE it was written.
#
# Identical-if-broken: start a reader, write, assert the reader printed the
# line. That passes whether delivery was instant, whether the reader had been
# spinning on a poll loop, and whether it was ever waiting at all.
#
# Three things make it decidable:
#   * the reader is observed STILL RUNNING (kill -0) and its output file EMPTY
#     immediately before the write;
#   * it returns within 5 seconds of the write, measured across the write
#     (second granularity via `date +%s` is enough for a 5s bound; no python3,
#     per the controller ruling -- none of this repo's other tests depend on
#     it). Mutation-tested: with the write removed the reader returns at its
#     own 20s budget and this fails, 15s clear of the bound. The companion
#     `back_at >= wrote_at` conjunct in the assertion carries NOTHING and is
#     not claimed here: `date +%s` is non-decreasing and back_at is sampled
#     later in program order, so nothing under test can falsify it -- it
#     printed true under the failing mutation too. It is kept only as an
#     ordering sanity check on the two samples;
#   * and the control below -- the same run with NO WRITE -- must time out
#     non-zero and print nothing. Without that control, a reader that returns
#     empty immediately passes an "it arrived" test that only checks status.
# ---------------------------------------------------------------------------
P2="$WORK/p2"; mkdir -p "$P2"; mkfifo -m 600 "$P2/f"
nvim --headless --clean -l "$REPO/lua/walkthrough/await.lua" "$P2/f" 20000 "$P2/ready" \
  > "$P2/out" 2>/dev/null &
RP=$!; PIDS+=("$RP")
n=0; while [ ! -f "$P2/ready" ] && [ "$n" -lt 200000 ]; do n=$((n + 1)); done
kill -0 "$RP" 2>/dev/null;  check "P2 control: the reader is blocked before the write" "0" "$?"
check "P2 control: it has printed nothing yet" "0" "$(wc -c < "$P2/out" | tr -d ' ')"
wrote_at="$(date +%s)"
cat > "$P2/send.lua" <<'LUA'
vim.opt.runtimepath:append(vim.env.WT_REPO)
local ok, reason = require("walkthrough.channel").send(_G.arg[1],
  '{"tour":"/tmp/t.tour","step_id":"the retry","index":1,"question":"why not a plain spawn?","nonce":"n1"}')
-- io.write, not print: nvim's `print` in --headless -l mode writes to STDERR
-- (see the header comment on $WORK/send.lua above), so a bare $(...) capture
-- of it -- which P3 and P6 both do -- would always read empty regardless of
-- whether the send was actually refused.
io.write(tostring(ok) .. "|" .. tostring(reason) .. "\n")
os.exit(ok and 0 or 1)
LUA
WT_REPO="$REPO" nvim --headless --clean -l "$P2/send.lua" "$P2/f" >/dev/null
check "P2: the send reported success" "0" "$?"
wait "$RP"; rc=$?
back_at="$(date +%s)"
check "P2: the reader exited 0" "0" "$rc"
printf '%s' "$(cat "$P2/out")" | grep -q '"question":"why not a plain spawn?"'
check "P2: it printed the question that was written" "0" "$?"
if [ "$back_at" -ge "$wrote_at" ] && [ $((back_at - wrote_at)) -le 5 ]; then within_delta=0; else within_delta=1; fi
check "P2: it returned within 5s of the write" "0" "$within_delta"

# The control that gives the above its meaning.
mkfifo -m 600 "$P2/f2"
out2="$(nvim --headless --clean -l "$REPO/lua/walkthrough/await.lua" "$P2/f2" 1200 2>/dev/null)"
check "P2 control: with NO write, the reader exits non-zero" "4" "$?"
check "P2 control: and prints nothing"                       ""  "$out2"

# ---------------------------------------------------------------------------
# P3 — a second question before the first is answered is never silently lost.
#
# Identical-if-broken: asserting the second write "succeeded" CANNOT FAIL --
# with a reader attached the kernel buffers it and reports success even though
# nobody will ever read it. So the assertion is on the far side: the reader
# consumed the first and exited, and the second was REFUSED, visibly (OQ-3:
# refuse the transport, keep the text).
# ---------------------------------------------------------------------------
P3="$WORK/p3"; mkdir -p "$P3"; mkfifo -m 600 "$P3/f"
nvim --headless --clean -l "$REPO/lua/walkthrough/await.lua" "$P3/f" 20000 "$P3/ready" \
  > "$P3/first" 2>/dev/null &
RP3=$!; PIDS+=("$RP3")
n=0; while [ ! -f "$P3/ready" ] && [ "$n" -lt 200000 ]; do n=$((n + 1)); done
WT_REPO="$REPO" nvim --headless --clean -l "$P2/send.lua" "$P3/f" >/dev/null
check "P3: the first question was sent" "0" "$?"
wait "$RP3"; check "P3: the reader took it and exited" "0" "$?"
res="$(WT_REPO="$REPO" nvim --headless --clean -l "$P2/send.lua" "$P3/f")"
check "P3: the second is refused, not buffered for nobody" \
  "false|no_reader" "$res"

# ---------------------------------------------------------------------------
# P6 — a dead session's FIFO is never adopted.
#
# Identical-if-broken: plant a stale FIFO, open a new walkthrough, assert it
# works -- that passes either way. The discriminating assertions are that a
# write into the STALE path reaches nobody, and that the live path is the one
# named in the CURRENT state file.
# ---------------------------------------------------------------------------
P6="$WORK/p6"; mkdir -p "$P6"
STALE="$XDG_RUNTIME_DIR/walkthrough-${USER:-x}/dialog-99999.fifo"
mkdir -p "$(dirname "$STALE")"; mkfifo -m 600 "$STALE"
( cd "$REPO" && bash -c '
    set -uo pipefail
    source ./bin/walkthrough --help >/dev/null 2>&1
    state_write b h /tmp/s /tmp/t.tour "$1"
    state_read
    printf "%s\n" "$ST_dialog"
  ' _ "$P6/live.fifo" ) > "$P6/named"
check "P6: the state file names the live FIFO, not the stale one" \
  "$P6/live.fifo" "$(cat "$P6/named")"
res="$(WT_REPO="$REPO" nvim --headless --clean -l "$P2/send.lua" "$STALE")"
check "P6: a write into the stale FIFO reaches nobody" "false|no_reader" "$res"

# ---------------------------------------------------------------------------
# cmd_await — the CLI verb the agent actually invokes has no coverage of its
# own (carried over from Task 4: only await.lua, its inner script, was ever
# exercised). Two things are covered here: argument validation, and the exit-
# status contract end to end (0 = a question arrived, 4 = nobody asked -- a
# NORMAL outcome the agent must not treat as an error -- other = a real
# failure), including that `nvim -l` propagates await.lua's own status rather
# than flattening every non-zero exit to 1.
# ---------------------------------------------------------------------------
WT="$REPO/bin/walkthrough"
CA="$WORK/cmd_await"; mkdir -p "$CA"
STATE_UNDER_TEST="$XDG_RUNTIME_DIR/walkthrough-${USER:-x}/state"
rm -f "$STATE_UNDER_TEST"

# Argument validation runs BEFORE with_state. Identical-if-broken: with no
# active walkthrough, a bad --timeout dies either way (with_state's own "no
# active walkthrough" also exits non-zero), so checking exit status alone
# cannot tell "checked first" from "checked second". The discriminating
# assertion is the MESSAGE: with no state file present at all, a refusal that
# names --timeout can only have come from the argument check running before
# with_state ever touched the (nonexistent) state file.
err="$("$WT" await --timeout abc 2>&1 1>/dev/null)"; rc=$?
check "await --timeout abc: exits non-zero" "1" "$rc"
case "$err" in
  *"await --timeout takes whole seconds"*) check "await --timeout abc: refused on its own terms, before touching state" "0" "0" ;;
  *) check "await --timeout abc: refused on its own terms, before touching state" "0" "1 ($err)" ;;
esac

err="$("$WT" await --timeout 0 2>&1 1>/dev/null)"; rc=$?
check "await --timeout 0: exits non-zero" "1" "$rc"
case "$err" in
  *"must be between 1 and 3600 seconds"*) check "await --timeout 0: out of range, low, refused before touching state" "0" "0" ;;
  *) check "await --timeout 0: out of range, low, refused before touching state" "0" "1 ($err)" ;;
esac

err="$("$WT" await --timeout 3601 2>&1 1>/dev/null)"; rc=$?
check "await --timeout 3601: exits non-zero" "1" "$rc"
case "$err" in
  *"must be between 1 and 3600 seconds"*) check "await --timeout 3601: out of range, high, refused before touching state" "0" "0" ;;
  *) check "await --timeout 3601: out of range, high, refused before touching state" "0" "1 ($err)" ;;
esac
if [ ! -e "$STATE_UNDER_TEST" ]; then no_state_created=0; else no_state_created=1; fi
check "await --timeout <bad>: no state file was ever created by any of the above" "0" "$no_state_created"

# Write state with the CLI's own writer, so this exercises the real format --
# and the same helper as tests/test_cli.sh, deliberately, so the two suites
# cannot come to disagree about what a planted state file looks like.
plant_state() { # backend handle socket tour [dialog]
  ( cd "$REPO" && bash -c '
      set -uo pipefail
      source ./bin/walkthrough --help >/dev/null 2>&1
      state_write "$1" "$2" "$3" "$4" "${5:-}"
    ' _ "$1" "$2" "$3" "$4" "${5:-}" )
}

# A real --remote-expr target, exactly as tests/test_cli.sh uses one: without
# it, `with_state` dies at "the walkthrough is gone" before cmd_await ever
# reaches the transport, and every case below would collapse to the same rc=1.
SOCK2="$CA/player.sock"
nvim --headless --listen "$SOCK2" >/dev/null 2>&1 &
SPID=$!; PIDS+=("$SPID")
n=0
while [ "$n" -lt 300 ]; do
  nvim --server "$SOCK2" --remote-expr '1' >/dev/null 2>&1 && break
  n=$((n + 1))
done
nvim --server "$SOCK2" --remote-expr '1' >/dev/null 2>&1
check "cmd_await fixture: the stand-in player is reachable" "0" "$?"

# 4 -- nobody asked. A real FIFO, a real state file, nobody ever writes.
mkfifo -m 600 "$CA/dialog.fifo"
plant_state tmux h "$SOCK2" /tmp/t.tour "$CA/dialog.fifo"
"$WT" await --timeout 1 >"$CA/out4" 2>"$CA/err4"
check "await: exits 4 when nobody asks (not an error, a normal outcome)" "4" "$?"
check "await: prints nothing on stdout when nobody asks" "0" "$(wc -c < "$CA/out4" | tr -d ' ')"

# 0 -- a question arrived. There is no ready-file hook through the CLI verb
# (unlike the direct await.lua invocations above), so this waits on the same
# fixed-iteration delay the O_WRONLY control earlier in this suite uses, then
# writes for real.
"$WT" await --timeout 20 >"$CA/out0" 2>"$CA/err0" &
CAP=$!; PIDS+=("$CAP")
n=0; while [ "$n" -lt 400000 ]; do n=$((n + 1)); done
WT_REPO="$REPO" nvim --headless --clean -l "$P2/send.lua" "$CA/dialog.fifo" >/dev/null
check "await: the send into the CLI's own reader reported success" "0" "$?"
wait "$CAP"
check "await: exits 0 when a question arrives" "0" "$?"
grep -q '"question":"why not a plain spawn?"' "$CA/out0"
check "await: the question printed is the one that was written" "0" "$?"

# other -- a real failure, and it must be visibly distinct from "nobody
# asked": rc 4 and rc 1 must not collapse into "any nonzero is an error" on
# the agent's side, which is exactly why 4 is carved out as its own contract.
plant_state tmux h "$SOCK2" /tmp/t.tour "$CA/not-a-fifo"
touch "$CA/not-a-fifo"
"$WT" await --timeout 1 >/dev/null 2>"$CA/errX"
rcX=$?
if [ "$rcX" != "0" ] && [ "$rcX" != "4" ]; then other_is_distinct=0; else other_is_distinct=1; fi
check "await: a real failure (dialog path is not a FIFO) is neither 0 nor 4" "0" "$other_is_distinct"
case "$(cat "$CA/errX")" in
  *"dialog channel is missing"*) check "await: the real failure names what's wrong" "0" "0" ;;
  *) check "await: the real failure names what's wrong" "0" "1 ($(cat "$CA/errX"))" ;;
esac

rm -f "$STATE_UNDER_TEST"

echo
[ "$fail" -eq 0 ] && echo "DIALOG FIFO TESTS PASSED" || echo "DIALOG FIFO TESTS FAILED"
exit "$fail"
