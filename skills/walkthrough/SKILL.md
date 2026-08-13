---
name: walkthrough
description: Guided, annotated walkthroughs of any code, played in the user's editor - a dedicated nvim surface with the cursor parked on each step and narration rendered beside the code. Use when the user wants to be walked through or shown how something works - onboarding onto an unfamiliar codebase, a module or directory, a subsystem, a call chain or execution path, "how does X work" - and equally when they want a change set, diff or PR explained before review. Invoked in conversation or as /walkthrough <what to tour>.
---

# Walkthrough

Author a `.tour` file, then play it by shelling out to the CLI that ships in this
skill's directory. Tours are CodeTour format, unmodified, so the same file plays
in VS Code and reads fine by hand.

Two words, used consistently below: a **tour** is the `.tour` file; a
**walkthrough** is a tour open and playing in the user's nvim.

## What ships here, and how to run it

This directory carries the tool as well as these instructions. Beside this file:

- **`bin/walkthrough`** — the CLI. Run it. Every command below is one of its
  subcommands.
- **`schema.json`** — the tour format, also printed by `walkthrough schema`.
  Read it only if you need a field this file does not cover.
- **`lua/` and `backends/`** — the nvim renderer and the terminal backends. The
  CLI loads them itself. Do not read them.

**Invoke the CLI by its bundled path**: the `bin/walkthrough` inside this
skill's own directory — the directory this SKILL.md was loaded from, which is
`~/.agents/skills/walkthrough/bin/walkthrough` for a standard install. Putting
`bin/` on `PATH` is optional and most installs skip it, so do not assume a bare
`walkthrough` resolves; the bundled path always does. If `walkthrough` happens
to be on `PATH` it is the same binary and is fine to use. Wherever this file
writes `walkthrough <command>`, run that binary with that subcommand. The CLI
needs `nvim` on `PATH` and nothing else.

## When to use

The user asks to be walked through code, to have something explained, or to
review a change set. For a single question about one line, just answer it.

## Arguments

As a slash command the trailing text names the target — `/walkthrough the auth
module`, `/walkthrough how a request becomes a credential`. Read it as the
description of what to tour.

With no arguments, infer the target from the conversation: the change you just
made, the file under discussion, the thing the user has been asking about. Say
what you picked in one line before you build it, so a wrong guess is cheap.

## Steps

1. **Work out what to walk through.** Any of these is a valid tour:

   - a change set — `git diff`, `git diff --staged`, or against a base branch
   - a module, package or directory
   - a call chain or execution path — "how a request becomes a credential"
   - a subsystem, or the whole repository, for onboarding
   - a "how does X work" question, where the narrative *is* the answer

   Read the code before you write about it. A tour is only worth playing if you
   understood the thing first.

2. **Decide whether the tour is durable**, because that decides where it lives.

   - **Durable** — onboarding, a module, a subsystem, a call chain: anything
     that stays true and is worth committing. Write it where git will capture
     it, **co-located as near as possible to what it explains**. A tour about
     `src/auth/` belongs at `src/auth/.tours/<name>.tour`; a repo-wide
     architecture tour at `.tours/<name>.tour`. The directory signals ownership
     and scope, and CodeTour discovers `**/*.tour`, so a nested tour is found by
     VS Code exactly as readily as a root-level one.
   - **Throwaway** — this change set, this PR, this debugging session: write it
     to a system temp directory (`mktemp -d`). Nothing ephemeral touches the
     working tree, so there is no gitignore entry to add and nothing to commit
     by accident.

   Say which you chose and why, briefly. Ask before overwriting an existing
   `.tour` file that you did not write.

3. **Decide the narrative order.** This is the real work and it is *not* file
   order. Find the entry point — the thing everything else hangs off — then
   order the rest so each step makes sense given the ones before it. Crossing
   between files mid-narrative is expected; a tour that walks files
   alphabetically has not explained anything.

4. **Write the tour.** A real two-step one, against this repository:

   ```json
   {
     "title": "How a step finds its line",
     "steps": [
       {
         "title": "resolving a step",
         "file": "lua/walkthrough/tour.lua",
         "pattern": "^function M\\.resolve_in_lines",
         "description": "The one place a step turns into a line number, so every question about where a walkthrough lands is answered here. Note the escaped dot in this step's own pattern: written M.resolve_in_lines, vim reads the dot as any character, and the pattern can land somewhere you did not mean without saying so."
       },
       {
         "title": "why patterns follow vim's rules",
         "file": "lua/walkthrough/tour.lua",
         "line": 64,
         "selection": { "start": { "line": 61, "character": 1 },
                        "end":   { "line": 73, "character": 1 } },
         "description": "A single call to vim.regex is the whole reason a pattern is a vim regex rather than a PCRE. This step is addressed by line instead, which is the trade: exact today, stale the moment anything above it moves."
       }
     ]
   }
   ```

   - `line` parks the cursor; `selection` is what gets highlighted.
   - Prefer `"pattern"` over `line` for code that may shift — it re-locates
     itself instead of going stale. Every step needs a `file` plus one of
     `line` or `pattern` — a step with neither cannot be played and is dropped.
   - `title` is the stable handle; position is restored by it across a reload.
   - `description` is prose about *why*. Never restate the code.
   - The nvim renderer draws `description` as plain text, breaking on `\n`. It
     does not render markdown, so write sentences, not bullets and backticks.
     (CodeTour in VS Code *does* render markdown from the same field.)
   - Two fields fail silently — read **Common mistakes** below before you write
     a single `file` path or `pattern`.

5. **Check your own output:** `walkthrough validate <tour>`

   Non-zero means a step does not resolve. It also prints `file:line:` for
   every pattern step and says when a pattern matched more than once, so
   *reading that output is how you check a pattern landed where you meant.*
   Do not skip it because the tour parsed.

   If it exits non-zero, or a pattern resolved to a line you did not mean, fix
   the tour and run `validate` again. Repeat until it passes clean, and only
   then open it. Do not lean on `open` to absorb a bad step: `validate` is
   strict and fails the whole tour on one unplayable step, while `open`
   degrades — it drops the steps it cannot play, reports which, and plays the
   rest. That is a safety net for a tour that rotted later, not a substitute
   for validating; taking it means the user gets the narrative with holes in it.

6. **Open the walkthrough:** `walkthrough open <tour>` — it prints a handle and
   a socket.

7. **Narrate the shape in the terminal** — what the tour covers and where to
   start. The user reads the detail in nvim; do not paste the descriptions back.

8. **Drive it in response to questions:** `walkthrough step +1`,
   `walkthrough step 3`. After editing a file, rewrite the tour and run
   `walkthrough reload`.

## Common mistakes

Everything else in a tour fails loudly. These two validate, open, and land the
reader somewhere subtly wrong.

- **Writing `file` relative to the `.tour` file.** `file` is relative to the
  WORKSPACE ROOT, always — the git root of the directory you run `walkthrough`
  from. Never relative to the `.tour` file's own directory. A tour at
  `src/auth/.tours/how-auth-works.tour` still writes `src/auth/session.ex`, not
  `session.ex`. This holds for temp-directory tours too: the tour's location
  carries no path-resolution meaning whatsoever, which is what keeps tours
  portable. Run the CLI from inside the repository so the workspace root is the
  one you meant.
- **Writing `pattern` as a PCRE.** `pattern` is a VIM regex, resolved with
  `vim.regex` — not a PCRE, not a Lua pattern. In vim's default magic mode `.`
  is any character (escape it `\.`), `(` `)` are literal (group with `\(` `\)`),
  and `+` `?` are literal (use `\+` `\?`, or lead with `\v` for PCRE-ish
  syntax). A wrong pattern usually does not error — it quietly matches some
  other line, which is why the line `validate` prints is worth reading.

## Rules

- **Never claim the walkthrough is open without checking** — `open` prints a
  handle and socket, and fails loudly otherwise.
- **If a command reports the walkthrough is gone**, the user closed it. Say so and
  continue in the terminal. Do not reopen it; they closed it deliberately.
- **Do not close the walkthrough yourself.** The user's close key does it and
  returns their focus.
- A durable tour is a committed artifact. Ask before overwriting one you did not
  write.
