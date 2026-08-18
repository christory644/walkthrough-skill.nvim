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
# THE REGRESSION THAT MATTERS (Measurement E).
#
# A reader that holds the FIFO O_RDWR — which is what bash's `exec 3<>fifo`
# does, and the obvious way to bound a read in portable shell — measures as NO
# READER from the writer's side: the writer's O_WRONLY|O_NONBLOCK open returns
# ENXIO while that reader is attached and waiting. Every question would be
# refused while an agent was listening.
#
# So this asserts the property directly: while await's reader is up, a
# non-blocking writer's open must SUCCEED. If anyone ever "simplifies"
# await.lua to `exec 3<>`, this is what fails.
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
check "a non-blocking writer sees await's reader" "OPENED" "$opened"
wait "$RPID"; check "reader exits 0 once a question arrives" "0" "$?"
check "reader printed the question verbatim" '{"question":"why"}' "$(cat "$WORK/q1")"

echo
[ "$fail" -eq 0 ] && echo "DIALOG FIFO TESTS PASSED" || echo "DIALOG FIFO TESTS FAILED"
exit "$fail"
