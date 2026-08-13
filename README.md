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
- [cmux](https://cmuxterm.com) — the only terminal backend in v0.1

Backends are pluggable and auto-detected; cmux is simply the one that ships
first. Adding another is one file defining `backend_open` and `backend_close`.
A detected-but-unimplemented terminal (e.g. tmux, which is detected but has no
backend file) fails loudly rather than falling back to something half-working.

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

Putting `bin/` on `PATH` is optional, and only needed to drive the CLI by hand.

The install is symlinks pointing **into this checkout** — nothing is copied. Keep
it where it is: moving or deleting the repository leaves the installed skill
pointing at nothing, and the first sign is usually an agent that can no longer
open a walkthrough. If you do move it, re-run `./install.sh` from the new
location.

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

- [`docs/known-issues.md`](docs/known-issues.md) — the corners where this is
  quietly less helpful than it looks, each with when you would hit it.
- [`docs/implementation-notes.md`](docs/implementation-notes.md) — where the
  shipped code diverges from the plan and spec in `docs/`, and
  why. Read it before trusting either of those documents.

## Prior art

[CodeTour](https://github.com/microsoft/codetour) for VS Code, whose file format
this uses unmodified.

## License

MIT
