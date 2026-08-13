# Known issues

Every entry here was verified against the code as it stands, not copied from a
review. Thirty candidates were collected from the build's ledger and its review
reports; nine no longer reproduce and were dropped rather than repeated.

Nothing below is a crash. A malformed step costs you that step, not the
walkthrough — that property is covered by `tests/test_fuzz.lua`, and the items
here are the corners where the tool is *quietly* less helpful than it looks.

---

## Playing a tour

### An ambiguous `pattern` is silent at play time

`validate` reports `(3 matches, first used)`; the player says nothing at all and
parks you on the first match.

*When you hit it:* a hand-written pattern like `^end$` that matched one line
when the tour was written and matches four after a refactor. The walkthrough
opens, nothing is dropped, and you are simply standing in the wrong place.

*Why deferred:* the player has no honest fix that is not noise — every
`pattern` step would have to announce its match count on arrival. `validate` is
where an author is looking for this, and it does say so. Run
`walkthrough validate` on your tours in CI (`README.md`) and the ambiguity is
reported before a reader ever meets it.

### Lazily-discovered drops are forgotten across a `reload`

A step demoted by navigation — a `line` past the end of its own file, a
`pattern` that no longer matches — is in `state().skipped` until you reload,
and gone from it afterwards. Measured: `open` → `{}`, visit step 2 → `{"rot"}`,
`reload` → `{}` again.

*When you hit it:* an agent rewrites the files, calls `reload`, and asks the
player what it dropped. The answer under-reports until you navigate back over
the same steps.

*Why deferred:* inherent to lazy discovery. `reload` is a fresh `open`, and
`open` deliberately does not read every file in the tour up front — that is the
whole reason `nav.populate` builds the quickfix list from `pattern` fields
instead of loading fifty buffers. It costs a repeated message and nothing else;
`validate` still reports the step.

### A step with a valid `line` and a malformed `pattern` is dropped

`tour.step_problem` judges `pattern` whenever it is present, even though `line`
wins everywhere it is consumed, so `{"line": 2, "pattern": 7}` is unplayable
though the pattern would never have been read.

*When you hit it:* only on a tour that is already malformed. `validate` names
the field, and the fix is one character.

*Why deferred:* deliberate. Making a check conditional on another field's
presence is exactly the subtlety that grew this codebase five successive layers
of the same crash; one unconditional list is worth one over-strict verdict on a
document that is broken anyway.

### `"selection": null` draws a spurious note

`validate` prints `'selection' is not a usable line range; highlighting the
step's own line instead` for a selection that was explicitly absent. `null`
decodes to `vim.NIL`, which is not `nil`, so the "was a selection given?" test
says yes.

*When you hit it:* only if you write `"selection": null`, which nothing tells
you to do. The note is informational — `validate` still exits 0 and the step
plays normally.

*Why deferred:* cosmetic, on a field nobody writes.

### `close()` leaves your buffers `nomodifiable`

The player sets `modifiable = false` on every buffer it shows and never sets it
back. `teardown()` clears the annotations, the signs and the keymaps; the option
stays.

*When you hit it:* only if you load this plugin into a long-lived editor and
close a walkthrough there. In the surface the CLI opens — a throwaway nvim that
exits with the tab — it is invisible. (`reload` does restore it, because it has
to re-read the buffers.)

*Why deferred:* correct for the way the tool actually runs, and restoring it
would mean recording each buffer's original value to avoid clobbering a
genuinely read-only file.

### `close()` clears whatever quickfix list is current

`teardown()` calls `setqflist({}, "r", …)` unconditionally. If you ran a `:grep`
after opening the walkthrough, closing it replaces your results with an empty
list titled `walkthrough`.

*When you hit it:* a long-lived editor again, and only if you used the quickfix
list for something else mid-tour.

*Why deferred:* `nav.mark_dropped_in_qflist` already refuses to touch a list
that is not ours, by title; teardown does not make the same check. One-line fix
whenever the long-lived-editor case stops being hypothetical.

### Tour buffers are unlisted

`nav.buffer_for` uses `bufadd()`, which creates unlisted buffers, so the files
in a tour do not appear in `:ls` and `:bnext` skips them.

*When you hit it:* trying to move around the tour's files with ordinary buffer
commands instead of `]w` / `[w` / the quickfix list.

*Why deferred:* `bufadd` was chosen over `bufnr(path)` because the latter does
substring matching and can silently annotate and lock the *wrong* file — a much
worse failure. Listing is the cost.

### The quickfix list numbers steps differently from the walkthrough

`populate` adds entries only for playable steps, so on a tour with a dropped
step, `:cc 2` is not step 2. The entry text carries the true index (`[3/5] …`)
and a dropped step's entry is retitled `— DROPPED`, but the positions diverge.

*When you hit it:* using `:cc N` as a step number on a tour that dropped
something.

*Why deferred:* nothing breaks today. It is recorded because it is a trap for
any future code that wires `:cnext` to `goto_step` by position.

### A step's file is matched by exact string, with no symlink resolution

`s.abspath == path` (in `nav` and in the `BufEnter` autocmd) is plain equality
after `fnamemodify(':p')`, which does not resolve symlinks. A tour whose `file`
reaches a buffer by a different symlink hop — or by different case on a
case-insensitive filesystem — matches nothing, and the annotations simply do
not appear.

*When you hit it:* a workspace reached through a symlink (`/tmp` → `/private/tmp`
on macOS is the classic), or a repo opened by two different paths.

*Why deferred:* it fails closed and silently, which is unpleasant, but resolving
every path on every comparison is a change to the one identity rule the whole
renderer hangs on. It is real enough that `tests/test_fuzz.lua` resolves its own
fixtures through `fs_realpath` and asserts that the renderer actually drew — a
review fuzz was invalidated by exactly this.

The same mismatch surfaces in `validate`'s output: it prints each pattern step
as a workspace-root-relative `file:line:` so the report pipes into `nvim -q`,
but when the workspace root and the invocation directory differ only by a
symlink it cannot form a relative path and falls back to an absolute one. The
report is still correct; `tests/test_cli.sh`'s V-2 assertions, which match on
`^tests/fixtures/...`, are what actually fail. A contributor who clones into a
symlinked path sees red tests on an unmodified tree.

### No field has a size limit

A multi-megabyte `title` or `description` is accepted and slows `open` down
roughly linearly: ~0.4 s per MB of `title` (measured 1.68 s at 4 MB).

*When you hit it:* a generated tour that inlines a file into a description.

*Why deferred:* latency, not breakage, on a document no author writes by hand.
Recorded because size — rather than type — is the likeliest shape of the next
defect in the malformed-field class, which is otherwise closed.

### `BufEnter` fires once with a stale step index

Inside `nav.goto_index`, the `:buffer` switch triggers the plugin's own
`BufEnter`, which renders with the previous `state.index` before `goto_index`
renders again with the right one.

*When you hit it:* never visibly; it is one redundant render per jump between
files.

*Why deferred:* self-correcting, and the ordering that fixes it is the ordering
that made `state.active` unsafe to set early.

### `sign_define` runs when the module is required

`lua/walkthrough/render.lua` defines its sign at module load, so
`require("walkthrough.render")` mutates global editor state whether or not a
walkthrough is ever opened.

*When you hit it:* only if you have a sign of the same name. It is idempotent
and group-scoped.

*Why deferred:* harmless, and moving it means a lazy-definition check on every
draw.

---

## The CLI and the surface

### The walkthrough tab looks like a stray shell

Nothing labels the surface the CLI opens, so in a cmux tab list it is
indistinguishable from a terminal you started yourself.

*When you hit it:* every time, cosmetically.

*Why deferred:* it is a feature (a backend-specific tab title), not a fix, and
was explicitly kept out of the fix waves.

### `printf %q` output breaks under fish and csh

`wt_nvim_cmd` quotes each filename with `printf %q`, which emits bash/zsh
`$'…'` syntax. The command is typed into the shell running inside the new
surface, so a user whose default shell is fish or csh gets a syntax error
instead of a player — for filenames that actually need quoting.

*When you hit it:* fish or csh as your login shell **and** a path with a space,
a quote or a control character.

*Why deferred:* not an injection risk (the quoting is stricter than those shells
need, never looser), and the fix is a shell-detection matrix in a script that
otherwise assumes POSIX-ish behaviour.

### `state_read` checks the state file's owner but not its directory's

`state_dir_ready` verifies `-O "$STATE_DIR"` when *writing*; `state_read`
verifies only `-O "$STATE"`. A directory owned by someone else cannot produce a
state file we own, but it can delete, rename or symlink around one.

*When you hit it:* a shared `/tmp` with no `XDG_RUNTIME_DIR`, and a hostile
local user — the residual half of a hole that was otherwise closed (the file is
parsed, never sourced; every value is base64 and character-checked).

*Why deferred:* the remaining exposure is denial of service and pointing the CLI
at a socket of your own, not code execution. Calling `state_dir_ready` from
`state_read` closes it.

### `walkthrough close` keeps the state file if the recorded backend is gone

`cmd_close` loads the backend named in the state file; if that file is missing,
`load_backend` exits before `rm -f "$STATE"`, so the tab and the stale state
both survive.

*When you hit it:* a broken or partial install of the tool between `open` and
`close`.

*Why deferred:* it fails loudly and names the backend, and the recovery is
deleting one file.

### `wt_wait_for_socket` has no delay and no diagnostic

The readiness loop retries `nvim --server … --remote-expr 1` with no sleep
between attempts — measured at ~1.8 s for the default 60 tries — and returns 1
silently, leaving the caller to say what went wrong. The one call site raises
the bound to 300 tries (~9 s) for exactly this reason.

*When you hit it:* an nvim configuration slow enough to miss the budget; you
get the caller's "nvim never came up" and a torn-down surface.

*Why deferred:* the bound is generous where it matters, and a tight no-sleep
poll was separately found to *starve* the thing it waits for — worth fixing
together, deliberately, rather than by adding one `sleep`.

### `backends/common.sh` cannot be sourced by a strict POSIX shell

`${BASH_SOURCE[0]:-$0}` in `wt_require_backend` is a `Bad substitution` under
dash, despite the file's POSIX-where-possible intent.

*When you hit it:* only if you source the backend helpers from something other
than `bin/walkthrough`, which is bash.

*Why deferred:* the CLI sets `WALKTHROUGH_ROOT`, which is the designed escape
hatch, so the expansion is never the path that matters in practice.

---

## Tests and packaging

### The Lua suite writes fixtures into `.tmp/` in the repo root

`tests/test_reload.lua` (and friends) write to `.tmp/` rather than a temp
directory of their own. Correct under the serial `./tests/run.sh`; two
concurrent runs would race.

*Why deferred:* the suite is serial by construction. (`tests/test_fuzz.lua`
uses its own `fs_mkdtemp` and cleans up after itself.)

### The cmux test's workspace scoping is inert

In `tests/test_backend_cmux.sh`, `active()`'s awk never resets its `w` flag
after the selected workspace, so the scoping works only because `◀ active` is
globally unique — not because the parse guarantees it.

*Why deferred:* the assertion it guards is correct today; the parse is one
`next` away from being correct for the right reason.

