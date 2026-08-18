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

echo
[ "$fail" -eq 0 ] && echo "DIALOG FIFO TESTS PASSED" || echo "DIALOG FIFO TESTS FAILED"
exit "$fail"
