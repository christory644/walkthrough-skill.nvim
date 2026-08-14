# Working this repository in parallel

Several sessions (people or agents) routinely work this repository at the same
time, in separate git worktrees. This is the reference for doing that without
one session's test run silently deciding another session's verdict.

## What is namespaced, and how

| Resource | How it is kept private | Where |
| --- | --- | --- |
| The CLI state file | `XDG_RUNTIME_DIR` points at the suite's own temp dir, so `walkthrough open/step/close` cannot see — or disturb — a walkthrough anyone actually has open | `tests/test_cli.sh` |
| The installer's targets | a scratch `HOME` from `mktemp -d`, **and** `CODEX_HOME` / `CLAUDE_CONFIG_DIR` cleared — see below; `install.sh` writes symlinks into `~/.agents`, `~/.claude`, … and must never be pointed at a real one, least of all for the refusal cases | `tests/test_skill_bundle.sh` |
| nvim processes and sockets | started by the suite, recorded by PID, killed by that PID in an `EXIT` trap | `tests/test_cli.sh`, `tests/test_with_lock.sh` |
| Scratch files | one `mktemp -d` per suite, removed on exit; nothing is written into the checkout | all shell suites |
| The checkout itself | one `git worktree` per session | `.worktrees/` |

**Never `pkill nvim`** (or `pkill -f walkthrough`, or anything else matched by
name). The name belongs to every other session on the machine as well, and to
the user's own editor. Kill the PIDs you started, and only those.

## A scratch `HOME` is no longer enough for `install.sh`

`install.sh` honours `$CODEX_HOME` and `$CLAUDE_CONFIG_DIR` and installs into
whatever they name, creating it if absent. That is correct for a user — those
variables are the authoritative statement of where a harness lives — and it is
an escape hatch straight out of your sandbox, because neither is relative to
`$HOME`.

This is not hypothetical. `CLAUDE_CONFIG_DIR` is set to `~/.claude-personal` in
at least one agent harness on this machine, and a run of
`tests/test_skill_bundle.sh` with a perfectly good scratch `HOME` replaced the
developer's live `~/.claude-personal/skills/walkthrough` with a link into a
`mktemp -d` that the suite then deleted — a dangling skill in a real config
directory, from a test that reported success.

So clear both, every time:

```sh
env -u CODEX_HOME -u CLAUDE_CONFIG_DIR HOME="$scratch" ./install.sh
```

`tests/test_skill_bundle.sh` routes every invocation through an
`install_scratch` helper that does exactly this, and sets the variables
deliberately only in the cases that are *about* them, pointed inside the
scratch tree. Do the same in anything you run by hand.

## The one thing that cannot be namespaced: cmux

`tests/test_backend_cmux.sh` opens a cmux surface and asserts that focus
**moved to** it, then closes it and asserts that focus **returned** to the
caller. Focus is a single global property of the user's terminal: there is no
environment variable that gives a session its own.

So if a second session opens or closes a surface while those assertions run,
the test does not fail noisily — it reports a verdict that is not about the
code. Focus can land back on the caller because the backend positioned the tab
correctly, or because someone else's surface happened to close at that instant,
and the assertion cannot tell those apart. This project has twice shipped on a
measurement that could not distinguish success from failure; that is why this
one resource gets a mutex instead of a convention.

## Using `scripts/with-lock`

Wrap anything that opens, closes or focuses a cmux surface:

```sh
scripts/with-lock cmux ./tests/test_backend_cmux.sh
scripts/with-lock cmux walkthrough open .tours/architecture.tour
```

It exits with the wrapped command's status, unchanged, and releases the lock
however the command ends — including on `Ctrl-C`, a `SIGTERM`, or a crash.

* **Where locks live:** `<common git dir>/walkthrough-locks/<name>.lock`.
  `git rev-parse --git-common-dir` resolves to the same absolute path from the
  main checkout and from every linked worktree, which is the point — a lock
  stored inside one worktree is invisible to the others and guards nothing.
  Outside a git repository it falls back to `$TMPDIR/walkthrough-locks-$USER`.
* **Who holds it:** every message that makes you wait or fail names the owner,
  their PID and host, when they took it, and what they are running. Set
  `LOCK_OWNER` to something recognisable (it defaults to
  `$USER@$HOSTNAME:$$`).
* **Waiting is bounded:** `LOCK_TIMEOUT` seconds (default 300), then it gives
  up with exit status **75** — distinct from any status the wrapped command
  could return, so "never got the lock" is never mistaken for "the tests
  failed".
* **Stale leases are broken, loudly:** if the holder's PID is gone (same host),
  or the lease is older than `LOCK_MAX_AGE` (default 1800s), the lock is taken
  and exactly what was broken, and why, is printed to stderr. A crashed session
  cannot wedge the repository.
* **Other knobs:** `LOCK_POLL` (default 0.25s), `LOCK_DIR` (override the
  location — the test suite uses this; day-to-day work should not).

`tests/test_with_lock.sh` proves all of the above under real concurrency,
including a run with the atomic acquire neutered, which must fail.

## Run the same shellcheck CI runs: **0.11.0**

CI pins it (`.github/workflows/test.yml`, the "pin shellcheck" step). Match it
locally, because an unpinned linter is not a gate — it is a moving target that
happens to agree with you most days.

```sh
shellcheck --version     # want: 0.11.0
```

This is written down because of a real failure. The runner image shipped an
older shellcheck that reported trap-invoked cleanup functions as **SC2317**
("command appears to be unreachable") where 0.11.0 reports the same false
positive as **SC2329**. Three sessions each verified `shellcheck rc=0`
completely honestly, against a different tool than the one gating the build,
and `main` was red for four pushes while every local run was green.

Two lessons that generalise past shellcheck:

* **Suppressing one code for a false positive is not enough** when another
  version of the tool files the same complaint under a different code. The
  cleanup functions in `scripts/with-lock`, `tests/test_backend_socket.sh` and
  `tests/test_backend_tmux.sh` now disable both.
* **"It passes locally" is a claim about your toolchain, not about the gate.**
  If a tool decides whether work lands, pin it, and print its version in the
  job so the next drift is visible in the log rather than in a mystery failure.

## Standing rules

* **Nobody runs `gh auth switch`.** GitHub auth is global to the machine: a
  switch changes the account under every other session mid-command, and the
  push or PR they were making lands as the wrong user or not at all. Work with
  whatever account is already active, and ask the human if it is wrong.
* **Do not run `install.sh` against your real `$HOME`** while testing. Give it
  a scratch one, and clear `CODEX_HOME` and `CLAUDE_CONFIG_DIR` as well — a
  scratch `HOME` alone does not contain it.
* **Kill what you start**, by PID, before you finish.
* **Leave no artifacts:** `git status --porcelain` is clean when you are done.
