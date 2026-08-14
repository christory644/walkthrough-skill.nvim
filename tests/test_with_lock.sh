#!/usr/bin/env bash
#
# scripts/with-lock, under real concurrency.
#
# A mutex that has not been tested under contention is a comment. Everything
# below runs actual concurrent processes; nothing here reasons about the lock
# from the outside. In particular the mutual-exclusion test is run twice — once
# against the real script and once against a copy whose atomic acquire has been
# neutered — because a contention test that passes without the lock proves
# nothing at all, and this repository has twice shipped a measurement that
# could not tell success from failure.
#
# No cmux surface is opened here, and no test touches the developer's $HOME:
# the whole suite is sleeps and files inside one mktemp -d.
set -u
cd "$(dirname "$0")/.." || exit 1
REPO="$PWD"
LOCKBIN="$REPO/scripts/with-lock"
fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; else echo "  FAIL: $1 (want $2, got $3)"; fail=1; fi }

[ -x "$LOCKBIN" ] || { echo "  FAIL: $LOCKBIN is missing or not executable"; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/walkthrough-lock-test.XXXXXX")" || exit 1

# Locks live inside $WORK for every case but the cross-worktree one at the
# bottom, which is about the default path and therefore has to use it.
export LOCK_DIR="$WORK/locks"
export LOCK_POLL=0.02

# Background holders are tracked by PID and killed by PID. Never pkill: the
# name "with-lock" or "sleep" belongs to every other session on this machine
# too, and killing theirs is exactly the class of collateral damage this whole
# exercise exists to prevent.
BG_PIDS=""
trap 'for p in $BG_PIDS; do kill -TERM "$p" 2>/dev/null; done
      for p in $BG_PIDS; do wait "$p" 2>/dev/null; done
      rm -rf "$WORK"' EXIT

HOST="${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"

wait_for() { # path tries(0.05s each)
  local i=0
  while [ "$i" -lt "${2:-100}" ]; do
    [ -e "$1" ] && return 0
    sleep 0.05; i=$((i + 1))
  done
  return 1
}

info_val() { # lockdir key
  grep "^$2=" "$1/info" 2>/dev/null | head -1 | cut -d= -f2-
}

# ---------------------------------------------------------------------------
# The holder's card
#
# A lock that blocks you anonymously is worse than no lock: you cannot tell a
# colleague's five-minute test run from a crashed process you should break.
# ---------------------------------------------------------------------------
echo "== holder metadata"
LOCK_OWNER="alpha-session" "$LOCKBIN" meta sleep 5 &
BG_PIDS="$BG_PIDS $!"
META="$LOCK_DIR/meta.lock"
if wait_for "$META/info"; then
  check "the lock records its owner" "alpha-session" "$(info_val "$META" owner)"
  check "...and a live pid" "0" \
    "$( kill -0 "$(info_val "$META" pid)" 2>/dev/null; echo $? )"
  check "...and the host it was taken on" "$HOST" "$(info_val "$META" host)"
  printf %s "$(info_val "$META" acquired)" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
  check "...and an ISO-8601 acquisition time" "0" "$?"
  check "...and what the holder is running" "sleep 5" "$(info_val "$META" command)"
else
  echo "  FAIL: the lock's info file never appeared"; fail=1
fi
kill -TERM "$(info_val "$META" pid)" 2>/dev/null
wait_for "$META" 1 >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Mutual exclusion under real contention
#
# Each holder appends "start <id>", sleeps, then appends "end <id>". Under a
# working lock the log is strictly paired: every start is followed by its own
# end. One interleaved pair anywhere means two processes were inside the
# critical section at once.
#
# 12 concurrent workers x 4 rounds = 48 critical sections, all of them
# hammering the same lock with a 20ms poll — the workers spend nearly all of
# their time contending, which is where a check-then-create race lives.
# ---------------------------------------------------------------------------
WORKERS=12
ROUNDS=4
HOLD=0.03

cat > "$WORK/section.sh" <<'EOF'
#!/usr/bin/env bash
# The critical section: two writes with a gap between them.
set -u
printf 'start %s\n' "$1" >> "$2"
sleep "$3"
printf 'end %s\n' "$1" >> "$2"
EOF
chmod +x "$WORK/section.sh"

cat > "$WORK/worker.sh" <<'EOF'
#!/usr/bin/env bash
# lockbin name id rounds log hold section
set -u
r=0
while [ "$r" -lt "$4" ]; do
  LOCK_OWNER="worker-$3" "$1" "$2" "$7" "$3" "$5" "$6" || exit 1
  r=$((r + 1))
done
EOF
chmod +x "$WORK/worker.sh"

# "clean" only if the log is a sequence of matched start/end pairs. An empty
# log is "empty", never "clean": a run whose workers all died before reaching
# the critical section would otherwise look like perfect mutual exclusion,
# which is precisely the false pass this suite exists to rule out.
pairing() { # logfile
  awk '
    { if (NR % 2 == 1) { if ($1 != "start") bad = 1; else id = $2 }
      else            { if ($1 != "end" || $2 != id) bad = 1 } }
    END { if (NR == 0) print "empty"; else print (bad ? "interleaved" : "clean") }
  ' "$1"
}

contend() { # lockbin lockname logfile
  local pids="" i=0 rc=0 p
  : > "$3"
  while [ "$i" -lt "$WORKERS" ]; do
    LOCK_TIMEOUT=60 LOCK_MAX_AGE=3600 \
      "$WORK/worker.sh" "$1" "$2" "$i" "$ROUNDS" "$3" "$HOLD" "$WORK/section.sh" \
      >>"$WORK/worker.err" 2>&1 &
    pids="$pids $!"
    i=$((i + 1))
  done
  for p in $pids; do wait "$p" || rc=1; done
  return "$rc"
}

echo "== mutual exclusion ($WORKERS concurrent workers x $ROUNDS rounds = $((WORKERS * ROUNDS)) critical sections)"
: > "$WORK/worker.err"
contend "$LOCKBIN" cs "$WORK/cs.log"
check "every worker completed" "0" "$?"
check "every critical section ran" "$((WORKERS * ROUNDS * 2))" "$(wc -l < "$WORK/cs.log" | tr -d ' ')"
check "the critical sections never interleaved" "clean" "$(pairing "$WORK/cs.log")"

# ---------------------------------------------------------------------------
# ...and the same run FAILS with the acquire neutered
#
# The only edit is `mkdir` (atomic: it created the directory or it did not) to
# `mkdir -p` (always succeeds) — the check-then-create race, in one character.
# Everything else about the copy is identical: same metadata, same trap, same
# release. If this run comes out "clean" the test above is measuring nothing,
# and that is a failure of THIS suite, not of the script.
# ---------------------------------------------------------------------------
echo "== the same test, with the atomic acquire neutered (must fail)"
NEUTERED="$WORK/with-lock-neutered"

# Two edits, and the second is only there to keep the first honest:
#
#   mkdir  -> mkdir -p   the acquire, atomic ("did I create it?") turned racy
#                        ("is it there? fine, carry on") — the check-then-create
#                        bug in one character.
#   die    -> true       without exclusion the holders' metadata writes trample
#                        each other, and the real script rightly aborts when it
#                        cannot record a holder. Aborting there would mean the
#                        racy copy never reaches the critical section at all,
#                        and a run that never enters the section cannot show an
#                        interleaving. Nothing else about the copy changes.
#
# The `$LOCK` in these patterns is literal text inside the script being edited;
# expanding it here would rewrite nothing and check nothing. Hence the single
# quotes, and hence the directive — which covers the whole function.
# shellcheck disable=SC2016
neuter() { # src dst; non-zero if the edits did not land
  # `#` as the sed delimiter, not `|`: the second pattern contains `||`.
  sed -e 's#if mkdir "$LOCK" 2>/dev/null; then#if mkdir -p "$LOCK" 2>/dev/null; then#' \
      -e 's#info_write "$@" || die "acquired $LOCK but could not record the holder"#info_write "$@" || true#' \
      "$1" > "$2" || return 1
  chmod +x "$2"
  # the atomic acquire must be gone...
  grep -qF 'if mkdir "$LOCK" 2>/dev/null; then' "$2" && return 1
  # ...and replaced by the racy one
  grep -qF 'if mkdir -p "$LOCK" 2>/dev/null; then' "$2" || return 1
  grep -qF 'info_write "$@" || true' "$2" || return 1
  return 0
}
neuter "$LOCKBIN" "$NEUTERED"
check "the neutering landed: atomic acquire replaced by a racy one" "0" "$?"

contend "$NEUTERED" ncs "$WORK/ncs.log"
echo "  (the unlocked run wrote $(wc -l < "$WORK/ncs.log" | tr -d ' ') of $((WORKERS * ROUNDS * 2)) lines)"
check "without the lock, the critical sections DO interleave" "interleaved" \
  "$(pairing "$WORK/ncs.log")"
echo "  evidence (first interleaving in the unlocked log):"
awk '
  { if (NR % 2 == 1) { if ($1 != "start") { print "    " NR ": " $0; exit } id = $2 }
    else if ($1 != "end" || $2 != id) { print "    " NR ": " $0 " (expected end " id ")"; exit } }
' "$WORK/ncs.log"

# ---------------------------------------------------------------------------
# Exit status passthrough
#
# This wraps test runs. A lock that swallowed a failing status would be worse
# than no lock: CI would go green on a red suite.
# ---------------------------------------------------------------------------
echo "== exit status"
"$LOCKBIN" st true >/dev/null 2>&1
check "success passes through" "0" "$?"
"$LOCKBIN" st bash -c 'exit 42' >/dev/null 2>&1
check "a failing status passes through unchanged" "42" "$?"
"$LOCKBIN" st bash -c 'kill -TERM $$' >/dev/null 2>&1
check "a signalled command reports 128+signal" "143" "$?"
check "...and the lock is released either way" "no" \
  "$( [ -e "$LOCK_DIR/st.lock" ] && echo yes || echo no )"

# ---------------------------------------------------------------------------
# Release on signal
#
# A holder killed mid-hold must not wedge the repository for everyone else.
# ---------------------------------------------------------------------------
echo "== release on signal"
"$LOCKBIN" sig sleep 30 &
SIG_PID=$!
BG_PIDS="$BG_PIDS $SIG_PID"
if wait_for "$LOCK_DIR/sig.lock/info"; then
  CHILD_PID="$(pgrep -P "$SIG_PID" 2>/dev/null | head -1)"
  kill -TERM "$SIG_PID"
  wait "$SIG_PID" 2>/dev/null
  check "the lock is gone after the holder is killed" "no" \
    "$( [ -e "$LOCK_DIR/sig.lock" ] && echo yes || echo no )"
  LOCK_TIMEOUT=3 "$LOCKBIN" sig true >/dev/null 2>&1
  check "the next waiter acquires it" "0" "$?"
  if [ -n "$CHILD_PID" ]; then
    check "the wrapped command was killed too, not orphaned holding nothing" "1" \
      "$( kill -0 "$CHILD_PID" 2>/dev/null; echo $? )"
  else
    echo "  ok: (no pgrep -P; skipped the orphan check)"
  fi
else
  echo "  FAIL: the signal holder never took the lock"; fail=1
fi

# ---------------------------------------------------------------------------
# Breaking a stale lease
#
# Both rules are exercised separately, because each covers a case the other
# cannot see: a dead PID is the common local crash, and age is the backstop for
# a holder on another machine or a PID that has since been reused.
# ---------------------------------------------------------------------------
plant_lock() { # dir owner pid host epoch
  mkdir -p "$1" || return 1
  printf 'planted-token\n' > "$1/token"
  { printf 'owner=%s\n' "$2"
    printf 'pid=%s\n' "$3"
    printf 'host=%s\n' "$4"
    printf 'epoch=%s\n' "$5"
    printf 'acquired=%s\n' \
      "$(date -u -r "$5" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
         || date -u -d "@$5" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
    printf 'command=%s\n' 'planted by the test'
  } > "$1/info"
}

echo "== stale: the holder's pid is gone"
# A pid that has exited AND been reaped, so it cannot be signalled.
bash -c 'exit 0' & DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null
plant_lock "$LOCK_DIR/dead.lock" "ghost-session" "$DEAD_PID" "$HOST" "$(date -u +%s)"
err="$(LOCK_MAX_AGE=99999 LOCK_TIMEOUT=5 "$LOCKBIN" dead true 2>&1 >/dev/null)"
check "a lock held by a dead pid is taken anyway" "0" "$?"
printf %s "$err" | grep -q 'BROKE STALE LOCK'
check "...loudly" "0" "$?"
printf %s "$err" | grep -qF "pid $DEAD_PID"
check "...naming the pid it broke" "0" "$?"
printf %s "$err" | grep -qF 'ghost-session'
check "...and who held it" "0" "$?"
printf %s "$err" | grep -q 'is gone'
check "...and that the reason was the dead holder, not age" "0" "$?"

echo "== stale: the lease is too old"
# A LIVE pid (this test's own), so the dead-pid rule cannot fire and age is
# demonstrably the only thing breaking this lease.
plant_lock "$LOCK_DIR/old.lock" "elsewhere-session" "$$" "$HOST" "$(( $(date -u +%s) - 100 ))"
err="$(LOCK_MAX_AGE=10 LOCK_TIMEOUT=5 "$LOCKBIN" old true 2>&1 >/dev/null)"
check "a lease past its maximum age is taken" "0" "$?"
printf %s "$err" | grep -q 'the lease is 1[0-9][0-9]s old, past the 10s maximum'
check "...saying how old it was and what the maximum is" "0" "$?"
printf %s "$err" | grep -q 'is gone'
check "...and not blaming a pid that is plainly alive" "1" "$?"

echo "== a fresh lease held by a live process is NOT stolen"
plant_lock "$LOCK_DIR/live.lock" "busy-session" "$$" "$HOST" "$(date -u +%s)"
err="$(LOCK_MAX_AGE=3600 LOCK_TIMEOUT=1 "$LOCKBIN" live true 2>&1 >/dev/null)"
check "it waits and then gives up instead" "75" "$?"
printf %s "$err" | grep -q 'BROKE STALE LOCK'
check "...breaking nothing" "1" "$?"
rm -rf "$LOCK_DIR/live.lock"

# ---------------------------------------------------------------------------
# Timeout
#
# Never wait forever, and never block anonymously.
# ---------------------------------------------------------------------------
echo "== timeout"
LOCK_OWNER="the-other-session" "$LOCKBIN" busy sleep 20 &
BUSY_PID=$!
BG_PIDS="$BG_PIDS $BUSY_PID"
if wait_for "$LOCK_DIR/busy.lock/info"; then
  err="$(LOCK_TIMEOUT=1 "$LOCKBIN" busy true 2>&1 >/dev/null)"
  check "a blocked waiter gives up non-zero" "75" "$?"
  printf %s "$err" | grep -q 'timed out'
  check "...saying it timed out" "0" "$?"
  printf %s "$err" | grep -qF 'the-other-session'
  check "...naming who holds it" "0" "$?"
  printf %s "$err" | grep -qF 'since 2'
  check "...and since when" "0" "$?"
  check "...and the holder still holds it" "yes" \
    "$( [ -e "$LOCK_DIR/busy.lock" ] && echo yes || echo no )"
  # ...and the moment the holder lets go, the waiter gets in.
  kill -TERM "$BUSY_PID"; wait "$BUSY_PID" 2>/dev/null
  LOCK_TIMEOUT=5 "$LOCKBIN" busy true >/dev/null 2>&1
  check "and it acquires once the holder is done" "0" "$?"
else
  echo "  FAIL: the busy holder never took the lock"; fail=1
fi

# ---------------------------------------------------------------------------
# The default lock path is shared across worktrees of the same repository
#
# This is the property the whole design turns on: the parallel sessions work in
# separate git worktrees, so a lock stored inside one worktree is invisible to
# the others and guards nothing. Proved end to end in a throwaway repository —
# a holder in the main checkout must block a waiter in a linked worktree.
# ---------------------------------------------------------------------------
echo "== the default lock path is shared by every worktree"
GITREPO="$WORK/repo"
mkdir -p "$GITREPO"
if git -C "$GITREPO" init -q >/dev/null 2>&1 \
   && git -C "$GITREPO" -c user.email=t@example.com -c user.name=t \
        -c commit.gpgsign=false commit -q --allow-empty -m init >/dev/null 2>&1 \
   && git -C "$GITREPO" worktree add -q "$WORK/wt" -b other >/dev/null 2>&1; then
  ( cd "$GITREPO" && env -u LOCK_DIR LOCK_OWNER=main-checkout "$LOCKBIN" xw sleep 20 ) &
  XW_PID=$!
  BG_PIDS="$BG_PIDS $XW_PID"
  COMMON="$GITREPO/.git/walkthrough-locks"
  if wait_for "$COMMON/xw.lock/info"; then
    check "the lock lands in the common git dir" "yes" \
      "$( [ -d "$COMMON/xw.lock" ] && echo yes || echo no )"
    check "...and nowhere inside the worktree" "no" \
      "$( [ -e "$WORK/wt/.git/walkthrough-locks" ] && echo yes || echo no )"
    err="$( cd "$WORK/wt" && env -u LOCK_DIR LOCK_TIMEOUT=1 "$LOCKBIN" xw true 2>&1 >/dev/null )"
    check "a waiter in the linked worktree sees the SAME lock" "75" "$?"
    printf %s "$err" | grep -qF 'main-checkout'
    check "...and names the holder in the other worktree" "0" "$?"
  else
    echo "  FAIL: the cross-worktree holder never took the lock"; fail=1
  fi
  kill -TERM "$XW_PID" 2>/dev/null; wait "$XW_PID" 2>/dev/null
else
  echo "  SKIP: git could not create a scratch repository with a worktree"
fi

[ "$fail" -eq 0 ] && echo "WITH-LOCK PASSED"
exit "$fail"
