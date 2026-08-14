#!/usr/bin/env bash
# wt_wait_for_socket: what it spends, and what it says when it gives up.
#
# The defect (#17) was not the budget. It was that the loop asked its question
# by SPAWNING A WHOLE NVIM, with no delay between attempts -- so waiting for
# nvim to start meant running 300 nvims against the one that was trying to
# start. And then it returned 1 in silence, leaving the caller to invent a
# reason it could not possibly know.
#
# So the assertions are: how many processes the wait spawns while there is
# nothing to talk to (must be none), and whether the diagnostic tells apart
# the two failures that call for different repairs -- nvim never STARTED
# versus nvim started and never ANSWERED.
#
# Every nvim this suite starts is recorded by PID and killed by that PID.
# Nothing is matched by name; the name belongs to the user's editor too.
set -u
cd "$(dirname "$0")/.." || exit 1
. ./backends/common.sh

fail=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fail=1; }

REAL_NVIM="$(command -v nvim)"
[ -n "$REAL_NVIM" ] || { echo "SKIP: nvim not installed"; exit 0; }

TMP="$(mktemp -d)"
PIDS=""
# Invoked by the EXIT trap below. Static analysis cannot see through a trap, and
# the complaint arrives under a DIFFERENT CODE depending on the version: 0.11.0
# files it as SC2329, older builds as SC2317 ("unreachable"). Both are silenced,
# because silencing one is how this passed locally and reddened CI. No comment
# line here may begin with the word shellcheck -- 0.10.0 reads such a line as a
# malformed directive and fails the file outright, which 0.11.0 does not.
# shellcheck disable=SC2329,SC2317
cleanup() {
  for p in $PIDS; do kill -9 "$p" 2>/dev/null; done
  rm -rf "$TMP"
}
trap cleanup EXIT

# A stub standing in for nvim, which records every time it is run. With this
# on PATH the wait cannot reach a real editor, so the spawn count below is
# exactly the number of processes the wait chose to create.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/nvim" <<'STUB'
#!/bin/sh
echo x >> "$NVIM_SPAWN_LOG"
exit 1
STUB
chmod +x "$TMP/bin/nvim"
export NVIM_SPAWN_LOG="$TMP/spawns"

spawns() { [ -f "$NVIM_SPAWN_LOG" ] && wc -l < "$NVIM_SPAWN_LOG" | tr -d ' ' || echo 0; }

# ---------------------------------------------------------------------------
# A. Nothing is listening and nothing ever will be.
# ---------------------------------------------------------------------------
echo "== a socket that never appears"
: > "$NVIM_SPAWN_LOG"
errA="$(PATH="$TMP/bin:$PATH" wt_wait_for_socket "$TMP/never.sock" 10 2>&1 >/dev/null)"; rcA=$?
if [ "$rcA" -eq 1 ]; then ok "gives up with status 1"; else bad "expected status 1, got $rcA"; fi

# THE assertion for #17. The old loop spawned one nvim per try -- 10 here,
# 300 at the real call site -- every one of them competing with the nvim it
# was waiting for. There is no socket on disk, so there is nobody to ask.
n="$(spawns)"
if [ "$n" -eq 0 ]; then ok "spawns no probe while the socket is absent (was: one per try)"
else bad "spawned $n process(es) with no socket to talk to"; fi

case "$errA" in
  *"never started"*) ok "says nvim never started" ;;
  *) bad "diagnostic does not say nvim never started: $errA" ;;
esac
case "$errA" in
  *"$TMP/never.sock"*) ok "names the socket it waited on" ;;
  *) bad "diagnostic does not name the socket" ;;
esac
[ -n "$errA" ] || bad "gave up silently -- the caller has nothing to report"

# ---------------------------------------------------------------------------
# B. The socket exists but nothing behind it answers.
#
# A real nvim binds the path, then is SIGKILLed so it cannot unlink it. This
# is the shape of the failure the old code could not distinguish from A, and
# the two need different repairs: A is "your editor did not start", B is
# "your editor is too slow or wedged".
# ---------------------------------------------------------------------------
echo "== a socket with nothing behind it"
STALE="$TMP/stale.sock"
"$REAL_NVIM" --headless --clean --listen "$STALE" >/dev/null 2>&1 &
np=$!; PIDS="$PIDS $np"
i=0; while [ ! -S "$STALE" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
if [ ! -S "$STALE" ]; then
  echo "  skip: nvim never bound $STALE"
else
  kill -9 "$np" 2>/dev/null; wait "$np" 2>/dev/null
  if [ ! -S "$STALE" ]; then
    echo "  skip: the socket did not survive the kill on this platform"
  else
    : > "$NVIM_SPAWN_LOG"
    errB="$(PATH="$TMP/bin:$PATH" wt_wait_for_socket "$STALE" 5 2>&1 >/dev/null)"; rcB=$?
    if [ "$rcB" -eq 1 ]; then ok "gives up with status 1"; else bad "expected status 1, got $rcB"; fi
    # The mirror of A: here there IS something to ask, so it must ask.
    n="$(spawns)"
    if [ "$n" -gt 0 ]; then ok "does probe once the socket exists ($n attempts)"
    else bad "never probed a socket that was present"; fi
    case "$errB" in
      *"never answered"*) ok "says nvim started but never answered" ;;
      *) bad "diagnostic does not distinguish this from a dead start: $errB" ;;
    esac
    # A and B must not produce the same words, or the diagnostic is decoration.
    if [ "$errA" = "$errB" ]; then bad "both failures produce an identical message"
    else ok "the two failures read differently"; fi
  fi
fi

# ---------------------------------------------------------------------------
# C. The success path, including a socket that shows up late -- the case the
#    cheap stat gate could plausibly have broken by never looking again.
# ---------------------------------------------------------------------------
echo "== a socket that appears"
LATE="$TMP/late.sock"
( sleep 0.7; exec "$REAL_NVIM" --headless --clean --listen "$LATE" >/dev/null 2>&1 ) &
lp=$!; PIDS="$PIDS $lp"
start=$(date +%s)
wt_wait_for_socket "$LATE" 300 >/dev/null 2>&1; rcC=$?
el=$(( $(date +%s) - start ))
if [ "$rcC" -eq 0 ]; then ok "returns 0 for a socket that appears late"
else bad "missed a socket that appeared late (rc=$rcC)"; fi
# It must return when nvim is ready, not burn the whole budget. The budget is
# ~11s; anything under 8 proves it noticed rather than timed out into a pass.
if [ "$el" -lt 8 ]; then ok "returned promptly (${el}s), not at the end of the budget"
else bad "took ${el}s -- it is not noticing the socket, it is running out"; fi
# Kill the nvim we started, by the PID we started, before asserting anything
# else. pkill would take the user's editor with it.
pkill_target="$(pgrep -P "$lp" 2>/dev/null || true)"
for p in $lp $pkill_target; do kill -9 "$p" 2>/dev/null; done

[ "$fail" -eq 0 ] && echo "BACKEND SOCKET PASSED"
exit "$fail"
