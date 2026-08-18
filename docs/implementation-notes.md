# Implementation notes — where the shipped code diverges from the plan

`docs/plan.md` and `docs/design.md` are the documents
this tool was built from. They are kept because they explain *why* most of it
looks the way it does — but review overturned parts of both, so following them
literally will mislead you. Every divergence that matters is below, with its
reason. **Where the two disagree with the code, the code is right.**

## Interface

**The public Lua API is `open` / `reload` / `close`** — not the spec's
`start` / `refresh` / `stop` (spec §"The Lua API"). The plan's own code used the
shipped names throughout and the spec's names never existed; the plan was
treated as authoritative when the two conflicted.

**`validate` takes any number of tours** and exits non-zero if any one of them
fails. The plan's `cmd_validate` read only `$1`, which silently made the
documented CI example (`walkthrough validate .tours/*.tour`) validate the first
tour and ignore the rest — CI green with rotted tours. Rot detection is the
feature's whole point, so the CLI was widened rather than the example narrowed.

**The CLI is plumbing, not the product surface.** A late scope change made the
Agent Skill the documented interface: an agent is handed the repo, installs it,
and drives `bin/walkthrough` itself. The CLI is unchanged and still supported;
it simply stopped being what the docs lead with.

**A walkthrough is of any code**, not only a change set. The plan's skill
workflow began at `git diff` and stopped if nothing had changed — the one line
that made an agent refuse "walk me through the auth module".

**Both cmux and tmux ship.** The plan lists cmux / tmux / plain window as
auto-detected and says only cmux would be implemented in v0.1; `backends/tmux.sh`
now exists and is covered by `tests/test_backend_tmux.sh`, which self-hosts a
private `tmux -L` server so CI exercises real focus and teardown rather than a
skip guard. There is still no plain-window backend: a terminal that is neither
is detected and refused by name.

The two teardowns are not the same mechanism, which is why the seam was worth
having. cmux selects the tab to the *right* of a closed one, so the walkthrough
tab is positioned immediately left of the caller and quitting returns you where
you started. tmux selects the *most recently used* window, so position is
cosmetic there and teardown follows the reader instead — measured, not assumed,
and asserted so a future "fix" that reintroduces positioning breaks a test.

## Semantics

**`pattern` is a vim regex.** The plan's Global Constraints call it "a
Lua-compatible regex"; `tour.resolve_in_lines` uses `vim.regex`, and CodeTour's
own `pattern` is a JavaScript regex, which vim regex resembles far more closely
than Lua patterns do. This is a documentation slip in the plan, and it matters:
`(`, `)` and `.` do not mean what a PCRE user expects, and a near-miss captures
the wrong line in silence.

**`open` degrades; `validate` stays strict.** The plan's error handling made an
unlocatable step fail both. What ships: `validate` (the CI rot gate) fails on
any step it cannot play, while `open` drops those steps, names them, and plays
the rest — refusing only a tour with nothing left. `validate.lua` grew a third
mode, `skips`, which asks `open`'s question ("what would playing this lose?")
rather than `validate`'s.

**Paths resolve against the git root of the CLI's *invocation* cwd**
(`wt_workspace_root`), falling back to that directory outside a repository —
never against the `.tour` file's own directory. The plan pinned nvim's cwd
nowhere at all, so relative `file` entries resolved against whatever directory
the backend's terminal happened to start in. The rule is one line: `file` paths
are relative to the workspace root, and the workspace is where you are working.
A tour's location says who owns it and nothing about path resolution.

**Tours are stored co-located when durable, in a system temp dir when
throwaway.** The plan puts every tour in `.tours/` at the repo root. What ships:
a tour worth keeping lives as near as possible to what it describes
(`src/auth/.tours/how-auth-works.tour`, committed — CodeTour's own discovery
glob is `**/*.tour`, so VS Code finds it there too), and a throwaway tour is
written to a system temp directory so nothing ephemeral touches the working
tree. `walkthrough list` still defaults to `<workspace root>/.tours/`.

**A malformed step field costs the step, not the document.** The plan's
`tour.validate` checked field *presence*. What ships judges the type and usable
range of every field a consumer touches — `title`, `description`, `file`,
`pattern`, `line` — once, in `tour.step_problem`, before any consumer sees it,
and records the verdict on the step. `validate` names the field and fails;
`open` drops that step and plays on. They cannot disagree, because they read one
answer. `line` is bounded by `linenr_T` (2147483647), because integrality is not
magnitude: `1e30` satisfies `% 1 == 0` and reaches `setqflist` as a Float.

**A malformed `selection` costs the step nothing.** The plan built `s.range`
from `selection` unconditionally, which raised at draw time for a selection with
no `line`. A range is now taken only when both ends are usable line numbers;
anything else falls back to the step's own line and is noted without failing.
`range` and `range_note` are derived fields that `validate` owns outright — a
document may name an unknown field, but it may not write one we compute.

**A `line` past the end of its file resolves to nothing** rather than being
clamped to the last line. Clamping parked the reader on plausible-looking
wrongness with nothing reported; rot in a `line` is now the same kind of rot as
a pattern that no longer matches, and travels the same demote-and-report path.

## Mechanics worth knowing before you edit

**`WALKTHROUGH_CLI` is injected by the CLI and preferred by `M.close`.** The
plan's `M.close` ran `jobstart({ "walkthrough", … })`, but putting `bin/` on
`PATH` is explicitly optional — so in-nvim teardown silently no-oped on a
default install, leaving the tab open. The CLI now passes its own absolute path;
the `PATH` lookup remains as a fallback.

**Quickfix entries for `pattern` steps carry vim's native `pattern` field**,
not `lnum = s.line or 1`. Resolving a pattern needs a loaded buffer, and nothing
may load fifty files to build a table of contents; vim searches for the pattern
on jump instead. Entries are appended **one at a time under `pcall`**, with a
drop hook, and a failed append restores the list — `setqflist` converts field by
field and can fail part way through one.

**Buffers are found with `bufadd`, not `bufnr(path)`.** `bufnr` treats its
argument as a pattern and can return an unrelated buffer whose name merely
contains the path — silently annotating and locking the wrong file.

**`state.active` is set last**, after the quickfix list, the autocmd and the
first jump have all succeeded, and `open` tears itself down if any of them fail.

**`reload` shape-checks the new tour before dismantling the old one**, and puts
the previous walkthrough back (on the same step) if the new one will not open.

**The socket wait is 300 tries at the call site**, not the helper's default 60:
60 measured at ~1.8 s of wall clock, which is shorter than a cold nvim start
with a real configuration.

**`walkthrough await` is an `nvim -l` reader, not `timeout N head -1 < fifo`.**
Issue #21 and `docs/design.md` both describe the `head` shape. The reason it is
wrong is **macOS has no `timeout(1)`**, so a bounded read is not spellable in
portable shell — that is sufficient on its own. A Lua reader also buys exact
budget control and survives a stray open-close-without-write, which `head -1`
does not.

*An earlier draft of this note gave a second reason: that bash's `exec 3<>fifo`
opens the FIFO `O_RDWR` and therefore measures as no reader to a non-blocking
writer. **That was measured during this build and is false** — an `O_RDWR`
holder does count as a reader, verified in bash, in nvim, and via a raw open.
The claim is recorded here only so nobody reinstates it.* `O_RDONLY|O_NONBLOCK`
remains the right choice because it returns immediately rather than blocking in
`open()` until a writer appears, and because it does not also hold the reader
open as a writer on its own FIFO — not because it is the only shape that works.

**Nothing probes the dialog FIFO for liveness.** The reason is that a probe
**buys nothing**: `O_WRONLY|O_NONBLOCK` makes liveness and delivery the same
syscall — the open either is `ENXIO` or is the write — so a separate probe is a
second fact that can disagree with the first. This is why OQ-3's auto-send retry
tick *is* a send attempt.

*A bare probe does end a `head -1 < fifo` reader with an empty, successful read
— measured — but it does **not** end `await.lua`, which keeps waiting and still
delivers the next real question whole. So "a probe would break our reader" is
not the justification; the one above is. It also means OQ-3's "beat to cancel"
could have been a literal countdown; the standing notice is a choice (the whole
pending window is cancellable, and no probe means nothing to disagree with the
send), not something physics forced.*

**The dialog buffer is not in `state.touched`.** `docs/dialog-design.md` § 3
says it should be, so that `teardown` finds it. It is closed explicitly instead,
from `teardown` and from `M.reload`, because `reload` runs `silent! edit!` over
every buffer in `state.touched` — wrong for a `buftype=prompt` buffer, and it
would destroy a transcript the reload was very likely caused by. An answer that
rewrites the tour goes through `reload`; the dialog has to survive it.

**A socket path over 104 characters is refused, not truncated.** Past that
length, nvim silently truncates the path to fit `sun_path` and binds the socket
somewhere else — dropping the last path component — while still reporting the
path it was given as `v:servername`. RPC connects either way, so it looks like
success from every angle except the one that matters: the socket would not
actually be inside `STATE_DIR`, whose ownership `cmd_open` checked, and `close`
would `rm -f` a path that deletes nothing. `cmd_open` measures `${#sock}`
against 104 (macOS's `sun_path` limit; Linux allows 108, so 104 is the portable
bound) before ever calling nvim, and dies with the path and a suggestion to set
a shorter `$XDG_RUNTIME_DIR` rather than let the mismatch happen silently.

## Verified, not assumed

Two claims the plan makes as reasoning were later measured, and both hold: a
tour authored here plays in VS Code's CodeTour extension (v0.0.61, both shipped
tours validate against CodeTour's own schema), and the malformed-field class is
closed at `tour.step_problem` rather than at its five former consumers —
`tests/test_fuzz.lua` is what keeps it closed.
