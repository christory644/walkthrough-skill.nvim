# walkthrough-skill.nvim

Guided, annotated walkthroughs of code, played inside nvim. The cursor parks on
each step, narration renders beside the code, and the narrative crosses files in
whatever order actually explains the thing — not top-to-bottom per file.

Any code, not just a diff: onboarding someone onto an unfamiliar system,
explaining a subsystem, tracing a call chain, answering "how does X work" — and,
yes, walking a change set before you open the PR.

Tours are [CodeTour](https://github.com/microsoft/codetour) `.tour` files, so
they are portable to VS Code (verified — see [Portability](#portability)),
hand-editable, and worth committing.

## Why

Reading code top to bottom is a poor way to understand it, whether it is a diff,
a directory or a repository you have never seen. A walkthrough puts the
explanation next to the line that prompts the question, in the editor, in an
order someone chose deliberately.

The interface is your coding agent. Install the skill, then ask — in
conversation ("walk me through the auth module", "walk me through these
changes"), or as a slash command (`/walkthrough how a request becomes a
credential`). The agent reads the code, decides the order, writes the tour and
plays it.

Tours are worth writing by hand too: a tour is onboarding documentation that
lives in the repo and fails CI when it rots. Playing one requires no agent.

## Requirements

- nvim 0.10+ (vim is not supported — see below)
- a terminal with a backend: [cmux](https://cmuxterm.com) or
  [tmux](https://github.com/tmux/tmux)

Both are for *playing* a walkthrough. Writing one needs neither, which is what
makes the skill useful in a GUI editor — see
[If your agent lives in a GUI editor](#if-your-agent-lives-in-a-gui-editor).

Backends are pluggable and auto-detected: `$CMUX_SURFACE_ID` selects cmux,
`$TMUX` selects tmux, and cmux wins when both are set, because then you are
inside cmux running tmux and the outer multiplexer owns the surface you actually
see. Each opens a dedicated surface beside your work — a cmux tab or a tmux
window, never a split of the pane you were using — and returns your focus when
the walkthrough ends.

Adding a third is one file, `backends/<name>.sh`, defining `backend_open` and
`backend_close`. `backend_close` answers with one of three statuses, because
`walkthrough close` reports what it says:

| status | meaning |
|---|---|
| `0` | closed — the surface is gone because we asked |
| `2` | nothing to close — it was already gone when we looked |
| any other non-zero | refused, or attempted and the surface may still be open |

`2` is not a formality. By the time anyone runs `walkthrough close` the reader
has usually shut the surface themselves, and both multiplexers report *that* as
a failure (measured: cmux `Error: not_found`, tmux `can't find window`), so a
backend that hands its multiplexer's status back turns the ordinary teardown
into an error. Attempt the close first; only if it fails, ask the multiplexer's
own inventory (`cmux tree`, `tmux list-windows`) whether the surface is still
there — absent is `2`, present is failure, and an inventory you could not read
is failure too, since it is no evidence that anything closed. The reasoning and
the measurements are in `backends/common.sh`; the rules are asserted for every
backend at once in `tests/test_backend_guards.sh`.

A terminal with no backend fails loudly rather than falling back to something
half-working:

```
walkthrough: no backend for 'none'.
```

The lines after that one list the backends actually on disk, rather than a set
written down somewhere, so the message stays correct as backends are added
without anyone having to remember it.

### Why not vim?

vim 9.1 has `+textprop`, so the rendering is achievable. The blocker is
`-clientserver`, which is how macOS ships it: without remote control the CLI
cannot drive the editor at all, so there is no stepping, no reload and no agent
integration. This is the common case, not an edge one. `+channel`/`+job` would
allow a vim plugin to serve its own socket instead — a real subproject, and one
nobody has asked for yet.

## Install

The entry point is a coding agent, so installing the skill installs everything —
the bundle carries the CLI, the backends and the renderer, and adds itself to
nvim's runtimepath at launch. There is no plugin to install, and no version skew.

```bash
git clone https://github.com/christory644/walkthrough-skill.nvim
cd walkthrough-skill.nvim && ./install.sh
```

That links the bundle into `~/.agents/skills/`, which Claude Code, Codex, Cursor,
Copilot, Gemini CLI, Amp and others all read. Then ask your agent to walk you
through something.

It also links into a harness's own directory when it finds one — every
`~/.claude*` and `~/.codex*` profile you have, plus `$CODEX_HOME` or
`$CLAUDE_CONFIG_DIR` when either is set, since those are the authoritative
answer to where that harness lives. It never creates a directory it merely
guessed at, and it refuses, by name, to touch anything it did not put there.

Putting `bin/` on `PATH` is optional, and only needed to drive the CLI by hand.

The install is symlinks pointing **into this checkout** — nothing is copied. Keep
it where it is: moving or deleting the repository leaves the installed skill
pointing at nothing, and the first sign is usually an agent that can no longer
open a walkthrough. If you do move it, re-run `./install.sh` from the new
location.

Part of that happens inside the checkout: `install.sh` links `bin/`, `backends/`,
`lua/` and `schema.json` in beside `skills/walkthrough/SKILL.md` so that one
directory is the whole skill, and then installs it as a single symlink. Those
links are git-ignored and relative, so they survive the checkout moving. A skill
has to be one self-contained directory for a harness scanner to find it — a
directory of individually-linked files is not the same thing, and Codex skips it.

## Use

Ask, and a walkthrough opens beside you:

> walk me through the auth module
>
> `/walkthrough how a request becomes a credential`
>
> walk me through these changes before I open the PR

The agent judges whether the tour is worth keeping. A durable one — onboarding, a
module, a call chain — is written into the repository next to what it explains,
so `src/auth/`'s tour lands at `src/auth/.tours/how-auth-works.tour` and the
directory says who owns it. A throwaway one — this change set, this debugging
session — is written to a temp directory and never touches your working tree.

Once a walkthrough is open, in nvim:

| key | action |
|---|---|
| `]w` / `[w` | next / previous step |
| `<leader>an` / `<leader>ap` | next / previous step |
| `<leader>aa` | ask about this step |
| `<leader>aq` | end the walkthrough |
| `:copen` | the whole tour as a list |

The player is a real nvim running your own config, not a viewer that imitates
one: syntax, treesitter, LSP and git signs all work on the code a tour walks you
through, so the gutter marks on an agent's edit are the ones you already know.

Nothing is bound globally — keys are attached only to buffers that are part of
an active walkthrough, and all of them are configurable:

```lua
require("walkthrough").setup({
  keys = { next = "]w", prev = "[w", close = "<leader>aq" },
})
```

### If your agent lives in a GUI editor

Authoring a tour and playing one are separable, and only playing needs a
terminal.

Any agent that can read code and run `walkthrough validate` writes a good tour.
A Cursor session did exactly that unprompted — mapped a subsystem, chose the
narrative order, co-located a durable tour under the package it explains, got
the path form right and validated it. What it could not do was play it:
`walkthrough open` drives a real nvim inside a terminal the CLI controls, and the
shell an agent embedded in VS Code or Cursor runs commands in is usually not one.
So it says so:

```
walkthrough: no backend for 'none'.
```

That is the design working, not a broken install — and your tour is not lost.
It is a CodeTour file, unmodified, so open it with
[the CodeTour extension](https://github.com/microsoft/codetour) in the editor
you are already in. Discovery is `**/*.tour`, so a co-located tour is found
wherever the agent put it, and the only difference is presentation: CodeTour
renders the description as markdown where nvim draws it as plain text.

In short — a terminal agent writes the tour and plays it in nvim; a GUI-editor
agent writes the same tour and you play it with CodeTour. Both produce the same
committed artifact, which is the point of using CodeTour's format.

The split is about the terminal, not the editor, so it moves if your terminal
does: an editor whose integrated shell is itself running inside cmux or tmux
sets `$CMUX_SURFACE_ID` or `$TMUX`, and `open` will work from there like any
other terminal. Worth knowing before you conclude your editor cannot play a
tour — check what the agent's shell is actually running in.

### Driving it by hand

The CLI is plumbing — it is what the agent shells out to — but nothing stops you
using it directly once `bin/` is on `PATH`:

```bash
walkthrough open .tours/architecture.tour   # prints a handle and a socket
walkthrough step +1                         # move along the narrative
walkthrough list                            # tours in .tours/ (or a directory you name)
walkthrough validate .tours/*.tour          # in CI: fail when a tour rots
```

`walkthrough --help` lists the rest. Note that `list` reads a single directory
rather than searching the tree, so co-located tours are opened by path.

## Writing a tour by hand

```json
{
  "title": "How a request becomes a credential",
  "steps": [
    {
      "title": "entry point",
      "file": "lib/router.ex",
      "pattern": "post \"/credentials\"",
      "description": "Everything starts here. Note the pattern instead of a line number - this step keeps working when the file moves around."
    }
  ]
}
```

Two things about a step fail *silently* — the tour validates, it opens, and it
lands the reader somewhere subtly wrong. Everything else fails loudly.

**`file` is relative to the workspace root, always** — the git root of wherever
you run `walkthrough` from, or that directory when it is not a repository. It is
never relative to the `.tour` file's own directory. A tour at
`src/auth/.tours/how-auth-works.tour` still writes `src/auth/token.ex`, not
`token.ex`, and the same is true of a tour sitting in a temp directory. The
tour's location carries no path-resolution meaning whatsoever, which is exactly
what lets a tour move without breaking.

**`pattern` is a vim regex**, resolved with `vim.regex` — not a PCRE, and not a
Lua pattern. The differences bite silently, because a pattern that means
something else usually still matches *some* line:

| you write | vim reads it as |
|---|---|
| `.` | any character (escape it: `\.`) |
| `(` `)` | literal parentheses (grouping is `\(` `\)`) |
| `+` `?` | literal (use `\+` `\?`, or write `\v` first for PCRE-ish syntax) |

`walkthrough validate` prints `file:line:` for every pattern step, says when one
matched more than once, and fails when one matches nothing at all — so reading
its output is how you confirm a pattern landed where you meant. Run it while you
write, and again in CI.

A step that has rotted costs you that step, not the tour: `open` drops it, names
it on stderr and plays the rest, while `validate` stays strict and fails the
whole tour on a single unplayable step — which is what makes it a CI gate.

Save it in a `.tours/` directory — at the repository root for a repo-wide tour,
or beside the code it explains for anything narrower — commit it, and it plays
for anyone who clones the repo.

## Portability

The format is CodeTour's, unmodified, and that has been measured rather than
assumed. Both `.tour` files in this repository validate against CodeTour's own
`schema.json` — the one its VS Code extension binds to `*.tour` — and
`.tours/architecture.tour` was opened in VS Code with CodeTour v0.0.61 and
played.

CodeTour discovers tours with `**/*.tour`, so a tour co-located in a nested
`.tours/` directory is found there exactly as readily as a root-level one.
Co-locating costs you no portability.

One honest difference in presentation: nvim renders a step's `description` as
plain text, breaking on `\n`. CodeTour renders the same field as markdown. Write
sentences and both are happy.

## Further reading

- [Known issues](https://github.com/christory644/walkthrough-skill.nvim/issues?q=is%3Aissue+is%3Aopen+label%3Abug) —
  the corners where this is quietly less helpful than it looks, each with when
  you would hit it and why it was left. The ones labelled
  [`deferred-by-design`](https://github.com/christory644/walkthrough-skill.nvim/issues?q=is%3Aissue+is%3Aopen+label%3Adeferred-by-design)
  are deliberate: the reasoning for keeping the current behaviour is in the issue.
- [Good first issues](https://github.com/christory644/walkthrough-skill.nvim/labels/good%20first%20issue) —
  a backend for another terminal is still the highest-leverage thing anyone
  could add, and it is one file: cmux and tmux are the worked examples.
- [`docs/implementation-notes.md`](docs/implementation-notes.md) — where the
  shipped code diverges from the plan and spec in `docs/`, and
  why. Read it before trusting either of those documents.

## Prior art

[CodeTour](https://github.com/microsoft/codetour) for VS Code, whose file format
this uses unmodified.

## License

MIT
