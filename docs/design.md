# nvim-walkthrough — design

**Status:** draft, awaiting review
**Date:** 2026-08-12

## Problem

Claude writes most of the code now. Reading the resulting diff in terminal
scrollback is a poor way to understand it: the narration and the code are in
different places, and there is no way to say "wait, why this?" while looking at
the line that prompted the question.

The goal is to walk through changes *in the editor*, with Claude parking the
cursor, annotating the relevant hunks, and answering questions about a specific
hunk without leaving nvim.

## Non-goals

- Not a chat UI for general Claude use. It is scoped to walking through code.
- Not an editing surface. The walkthrough buffer is for reading and asking.
- Not a replacement for the terminal session. The agent's own UI (tool calls,
  diffs, permissions) stays where it is.
- Not tied to any agent. An agent is one way to author a tour, not a requirement
  for playing one.

## Decisions

Each of these was chosen deliberately; the rationale matters more than the choice.

| Decision | Choice | Why |
|---|---|---|
| Terminal substrate | **Pluggable backend, auto-detected** | cmux and tmux both verified working. Detection via `$CMUX_SURFACE_ID` / `$TMUX`. A new backend is one file, not a refactor. |
| Tour format | **CodeTour `.tour`, unmodified** | Tours are portable to VS Code, already hand-authorable, already a convention (`.tours/` in-repo). Their `pattern` field gives edit-resilience we would otherwise have to invent. No proprietary fields. |
| Agent integration | **One `SKILL.md`** | Agent Skills is an open standard supported across harnesses; `.agents/skills/` is the cross-client location. No per-harness adapters. |
| Entry point | **A CLI** | Every consumer — agent, human, CI — goes through `walkthrough`. This is what keeps it harness-agnostic. |
| Surface shape | **A tab, not a split** | A split puts the Claude chat and the walkthrough side by side — two conversation surfaces competing for attention. A tab gives the code the whole pane and keeps the chat one switch away. Measured: **181 columns in a tab vs ~90 in the split**. |
| nvim instance | **Spawn dedicated** | Works when no editor is open (the normal state). Cannot disturb unsaved work. Scoped to the changed files. |
| Pacing | **Overview first, then drill** | All hunks annotated at once for shape; cursor parked at the entry point; depth on request. Matches onboarding someone to a PR. |
| Control transport | **nvim RPC over a socket** | `nvim --listen <sock>` + `nvim --server <sock> --remote-expr`. No daemon, no MCP server, no extra process. |
| Architecture | **Thin plugin + JSON spec** | Claude decides *what to say*; the plugin owns *how to draw it*. Plugin is testable from a fixture spec with no Claude in the loop. |
| Dialog | **In-nvim, per-hunk** | From a hunk, open a dialog and discuss *that hunk*. This is the core interaction, not a later phase. |

### Rejected

- **MCP server wrapping nvim.** A third process with its own lifecycle to do
  what one Bash call already does.
- **Attaching to an existing nvim.** Requires an editor already open and moves
  the cursor out from under in-progress work.
- **End-of-line virtual text for narration.** Rejected on evidence: a live probe
  truncated `":noreply — caller parked in st"` at the pane edge. Narration is
  sentences; eol virtual text cannot hold a sentence.

## Architecture

```
  author                        player
  ──────                        ──────
  agent (SKILL.md)  ┐
  human, by hand    ├─►  .tours/*.tour  ─►  walkthrough CLI
  generator script  ┘         (CodeTour)          │
                                                  ├─► backend: cmux | tmux | window
                                                  │        opens a full-size surface
                                                  └─► nvim RPC ─► walkthrough.nvim
                                                           renders virt_lines,
                                                           quickfix, keymaps
```

Nothing in the player knows how the tour was authored, and nothing above the
backend knows which terminal it is running in.

Four components, each independently understandable:

### 1. `walkthrough.nvim` (lua plugin)

The only stateful piece. Public API is deliberately tiny:

```lua
require("walkthrough").start(spec)    -- render; populates the quickfix list
require("walkthrough").step(delta)    -- move along the narrative (wraps :cnext/:cprev)
require("walkthrough").ask()          -- open dialog for the current hunk
require("walkthrough").refresh(spec)  -- reload after Claude edits; restores position by hunk id
require("walkthrough").stop()         -- clear everything and close the tab
```

Everything else is internal. `start()` takes the spec below and owns all
rendering; it never talks to Claude directly.

### 2. Tour format — CodeTour-compatible

The native format is Microsoft's [CodeTour](https://github.com/microsoft/codetour)
`.tour` file, not an invention of ours. Tours live in `.tours/*.tour` in the
repository, exactly where CodeTour puts them.

Reasons this is worth the constraint:

- **Tours are portable.** A tour authored here plays in VS Code and vice versa;
  a repo can carry one set of tours for a mixed-editor team.
- **It is already hand-authorable and commonly committed**, which is the
  agent-free use case we want (see below).
- **`pattern` solves edit-resilience better than we did.** A step can locate its
  line by regex instead of number, so a tour survives edits that shift lines. Our
  `id`-based refresh only survives edits because Claude regenerates the document.

```json
{
  "title": "Credential lookups move off the critical path",
  "description": "Optional overview shown before the first step.",
  "ref": "main",
  "steps": [
    {
      "title": "the async clause",
      "file": "lib/cred_agent.ex",
      "line": 4,
      "description": "Task.async hands the NPI lookup to a separate process, so this GenServer stays free to take other calls.",
      "selection": { "start": { "line": 4, "character": 1 },
                     "end":   { "line": 6, "character": 1 } }
    },
    {
      "title": "the retry",
      "file": "lib/client.ex",
      "pattern": "def get\\(npi\\)",
      "description": "Locating by pattern instead of line number: this step survives edits above it."
    }
  ]
}
```

Mapping onto the renderer:

| CodeTour | Our use |
|---|---|
| `steps[]` order | the narrative — already ordered, already crosses files |
| `step.file` + `step.line` | where the cursor parks and the note anchors |
| `step.pattern` | alternative to `line`: first regex match locates the step |
| `step.selection` | the highlighted range (`start.line`..`end.line`) |
| `step.description` | the note text |
| `step.title` | the stable identifier used to restore position across a refresh |

**Fields we deliberately do not implement**, because they have no meaning in this
context: `commands` (VS Code command URIs), `view` (VS Code view ids), `uri`
(non-file resources), and `directory` steps. A tour containing them still plays;
those steps are skipped and reported, per the degradation rule.

**Identity for refresh.** CodeTour has no step `id`. `step.title` is used when
present and unique; otherwise the step index is used, with the caveat that an
index is only stable if Claude regenerates the whole document — which it does.
No proprietary `id` field is added, because a file with unknown keys is a file
other tools may refuse.

**Markdown.** CodeTour descriptions are markdown. The renderer treats them as
plain text with `\n` breaks — it does not render bold, links or code fences.
This is a stated limitation, not a bug: `virt_lines` is not a markdown viewport.

### 3. Terminal backends

One job, one interface, several implementations:

```
open(cmd)    -> handle          # a full-size surface running cmd
close(handle)                   # tear it down
```

The backend is **auto-detected**, and each is a single file so adding one is
additive:

| Detected by | Backend | Status |
|---|---|---|
| `$CMUX_SURFACE_ID` set | cmux tab | **implemented in v0.1** |
| `$TMUX` set | tmux window | detected; not implemented yet (proven feasible) |
| neither | plain window | detected; not implemented yet |

Only cmux ships in v0.1. The abstraction exists anyway because the seam is nearly
free while writing fresh code and expensive to retrofit — and because a detected
terminal with no backend must fail with a message saying exactly that. A
half-working fallback is worse than a refusal: the user cannot tell "unsupported"
from "broken".

Nothing above the backend knows which one is in use: the Lua plugin, the tour
format and the CLI are all backend-agnostic. `WALKTHROUGH_BACKEND` overrides
detection.

#### cmux backend

Gives a full-pane tab running a command, and a handle to close it.

```
open(cmd)   -> cmux new-surface --type terminal --focus false --id-format uuids
               cmux move-surface --surface <uuid> --before <chat-uuid>
               cmux rpc surface.focus '{"surface_id":"<uuid>"}'
               cmux send --surface <uuid> "<cmd>"; send-key enter
               returns surface UUID
close(uuid) -> cmux close-surface --surface <uuid>
```

The launch command itself:

```
nvim -c 'silent! SessionDisableAutoSave' --listen <sock> <files...>
```

Created unfocused, positioned left of the chat tab, *then* focused — so that
closing it later returns the user to the chat without anyone asking.

`new-surface` (a tab in the current pane), not `new-split`. Verified: nvim comes
up at 181x55 in a tab versus roughly half that in a split.

#### Teardown — the plugin closes its own tab

The walkthrough is a bracket around a normal working session: you are mid-task,
you ask for a walkthrough, you read it, you quit, and you come back here to ask
for changes or say ship it. Teardown should not need a conversation.

**Position the tab immediately left of the chat tab at launch.** cmux selects the
next tab to the *right* when a tab closes, so a walkthrough tab placed directly
left of the chat means quitting lands the user back on the chat with no further
action. Verified:

```
new-surface                          -> temp tab
move-surface --before <chat>         -> positioned left of chat
close-surface <temp>                 -> active = chat   ✓ for free
```

So `stop()` clears annotations, unbinds keys, and closes its own surface. That is
the whole teardown. No signal, no listener, no round-trip, and it works even if
the Claude session has exited.

```lua
function M.stop()
  clear_annotations()
  local me = vim.env.CMUX_SURFACE_ID
  if me and vim.fn.exepath("cmux") ~= "" then
    vim.fn.jobstart({ "cmux", "close-surface", "--surface", me })
  else
    -- no cmux: leave the buffer clean and say so, rather than promise anything
    vim.api.nvim_echo({ { "walkthrough ended - close this tab when ready", "Comment" } }, false, {})
  end
end
```

**Never promise an action the plugin cannot perform.** An earlier iteration
printed "Claude will close this tab" and then relied on Claude noticing. Claude
only acts when it has a turn, so the tab sat open until the user came back and
mentioned it. If teardown cannot happen locally, say what is true.

##### Findings that constrain the above

Measured while getting here; they still bound any future change to this design.

- **`close-surface` overrides focus, always.** Focusing the chat and *then*
  closing the walkthrough lands on a third tab — and this holds even when closing
  a surface that was not focused. Any explicit focus call must come *after* the
  close, never before. The position trick avoids needing one at all.
- **A plugin cannot focus anything after closing its own surface.** A detached
  helper does run, but its cmux socket dies with the surface:
  `Failed to write to socket (Broken pipe, errno 32)`. No amount of detaching
  fixes it. This is why teardown must be positional rather than corrective.
- **`surface.focus` is an RPC method, not a CLI subcommand.** Absent from
  `cmux --help`; discoverable via `cmux capabilities`. Needed only if the
  position trick is ever abandoned. AppleScript's `focus` is *not* a substitute —
  it moves windows, not cmux tab selection.
- **Never use a FIFO for lifecycle events.** Writing to a FIFO with no reader
  blocks the writer and would freeze nvim. A FIFO is fine for the dialog, where
  Claude is blocked by construction; anything else uses an append-only file.

### 4. The `walkthrough` CLI

The CLI is the contract every consumer uses — agents, editors, humans, CI. Keeping
it the only entry point is what makes the project harness-agnostic.

```
walkthrough open <tour.tour> [--step N]   # open a tour; prints handle + nvim socket
walkthrough step  <+1|-1|N>               # move along the narrative
walkthrough reload <tour.tour>            # re-render after files changed on disk
walkthrough close                         # end the walkthrough
walkthrough list                          # tours found in .tours/
walkthrough validate <tour.tour>          # exit 0 if the tour is playable
walkthrough schema                        # print the JSON schema
```

`validate` and `schema` exist so an agent can check its own output and discover
the format without being told, and so CI can assert that committed tours still
resolve after a refactor.

### 5. Agent integration — one skill, every harness

Integration is a single `SKILL.md` in the [Agent Skills](https://agentskills.io)
format — an open standard supported by Claude Code, Codex, Cursor, Copilot,
Gemini CLI, Amp, Goose and others. There are no per-harness adapters.

Installed to the cross-client convention, most-portable first:

```
.agents/skills/walkthrough/SKILL.md      # repo-local, committed
~/.agents/skills/walkthrough/SKILL.md    # user-wide, all harnesses
```

Harness-specific directories (`~/.claude/skills`, …) are symlinked to the
`~/.agents` copy for clients that do not yet search the shared location.

The skill's whole job is: read the diff, decide the narrative order, write a
`.tour` file, call `walkthrough open`. Everything it does is a documented CLI
call, so a user can do the same thing by hand.

## Interaction model

### Keymaps — which-key, leader-driven

The prototype's `]w`/`[w` were placeholders. Real bindings live under a
which-key group so the menu is discoverable by pausing after `<leader>`.

`<leader>a` — "agent" — is proposed as the group. Free per `init.lua`
(taken: `b c d D e f g h l m n p r s t T u w x`). which-key v3 is installed, so
registration uses `wk.add`:

```lua
require("which-key").add({
  { "<leader>a",  group = "agent" },
  { "<leader>aw", function() require("walkthrough").start_last() end, desc = "walkthrough: start" },
  { "<leader>aa", function() require("walkthrough").ask()        end, desc = "ask about this hunk" },
  { "<leader>an", function() require("walkthrough").step(1)      end, desc = "next hunk" },
  { "<leader>ap", function() require("walkthrough").step(-1)     end, desc = "prev hunk" },
  { "<leader>aq", function() require("walkthrough").stop()       end, desc = "end walkthrough, close tab" },
})
```

Additionally, and idiomatically: `]w` / `[w` remain as **motions** only, mapped
buffer-locally, matching vim's `]c`/`[c` hunk-motion convention. Motions stay on
brackets; commands live under leader. Both are configurable; nothing is bound
globally.

### Rendering

- Notes render as `virt_lines` **above** their hunk — full width, wraps
  naturally, never truncated.
- **All** notes stay visible, dimmed (`Comment`), so the whole shape of the
  change is legible at a glance.
- The **current** hunk's note is emphasised (`DiagnosticInfo`) and its code
  range highlighted; the cursor parks on its first line, centred with `zz`.
- A gutter sign marks the entry point.
- Position (`hunk 2/7`) shows in the message line, and via `cmux set-status` in
  the UI chrome.

### Dialog — the core interaction

From a hunk, `<leader>aa` opens an nvim split *inside the walkthrough tab*, with
a prompt buffer scoped to that hunk.

Note the distinction that drove the tab decision: **code beside dialog is
coherent** — both are the walkthrough, both are nvim, and you want them visible
together while asking about a specific hunk. **Chat beside nvim was not** — two
conversation surfaces competing for the same attention. So the split moves
inside nvim, and the terminal chat gets a tab of its own to switch back to.

```
┌─ ask: cred_agent.ex:4-6 ──────────────┐
│ Claude: Task.async hands the NPI      │
│ lookup off so this GenServer stays    │
│ free to take other calls.             │
│                                       │
│ > why not a plain spawn here?_        │
└───────────────────────────────────────┘
```

Mechanism, already proven end to end:

1. Plugin writes `{hunk_id, question}` as one JSON line to the session FIFO.
2. Claude is blocked on `head -1 < $FIFO` inside a Bash call, and unblocks with
   the question mid-turn.
3. Claude answers by calling back over nvim RPC — appending to the dialog buffer,
   and optionally moving the cursor or adding hunks if the answer points
   elsewhere.

The blocking read is bounded (`timeout`) so a walkthrough cannot wedge the
session; on timeout Claude reports that it stopped waiting and the user can
resume with another question.

## Error handling

| Failure | Handling |
|---|---|
| nvim socket never appears | Bounded retry, then report the pane failed to start. No silent hang. |
| Pane closed mid-walkthrough | RPC calls fail; detect, stop cleanly, tell the user. Never respawn silently. |
| Spec references a missing file/line | Plugin skips that hunk, renders the rest, reports which were dropped. Partial is better than nothing; silence is not. |
| FIFO read times out | Bounded wait, then report. Session stays usable. |
| Stale socket/FIFO from a dead session | Session-scoped paths include the session id; clean up on `stop()`. |
| Unknown spec version | Plugin refuses and says so, rather than rendering something wrong. |

## Testing

The spec/render seam is what makes this testable:

- **Plugin, headless** — `nvim --headless` loads a fixture spec, asserts extmark
  count, positions, cursor line, sign placement. No Claude involved.
- **Adapter** — open a pane, assert a socket appears, close it, assert the
  surface is gone. Asserts UUIDs are used.
- **Dialog** — write a line into the FIFO, assert the blocking reader returns it.
  (Already proven manually.)
- **Degradation** — fixture spec with a bad path asserts the rest still renders.

## Narrative order, not file order

A change set is not reviewed top-to-bottom through each file. The walkthrough is
an **ordered list of hunks that crosses files freely** — entry point first, then
wherever the explanation leads. `hunks[]` is that order; file boundaries are
incidental.

This makes `:next` the wrong primary navigation: the args list walks files in
file order, which is the order we are explicitly rejecting.

### The quickfix list is the right vehicle

vim already has a first-class structure for "an ordered set of locations across
files that you step through": the quickfix list. `start()` populates it from
`hunks[]`, in narrative order.

What this buys, all of it free:

- `:cnext` / `:cprev` step the narrative, switching buffers automatically.
- `:copen` gives a table-of-contents view of the whole change set — the overview
  the user asked for, without building any UI.
- `:cc 4` jumps straight to hunk 4.
- It composes with whatever quickfix UI is already installed (trouble.nvim etc.)
  rather than competing with it.
- Files open as real buffers, so syntax, treesitter and LSP all work.

Division of labour: **quickfix is the index, `virt_lines` is the narration.**
Quickfix entries are one line each (`file:line: h3 — first sentence`), while the
full multi-line note renders above the code in the buffer.

`<leader>an` / `<leader>ap` and `]w` / `[w` wrap `:cnext`/`:cprev` so the
walkthrough keeps its own bindings, but the underlying list is a plain quickfix
list the user can drive with anything.

Annotations render per-buffer on entry (a `BufEnter` autocmd keyed to the
session), so a fifty-file walkthrough does not eagerly load fifty buffers.

**No clobbering.** The quickfix list belongs to the nvim *process*, and the
walkthrough runs in a dedicated instance that is created and destroyed with the
session. There is no pre-existing list to preserve. (An earlier draft warned about
this; the warning was a leftover from the rejected attach-to-existing-nvim design
and did not apply.)

**Session managers are the real hazard, not quickfix.** The config runs
`auto-session`. Inbound is safe — `auto_restore_enabled = false`, so nothing is
restored into the walkthrough instance. Outbound is not automatically safe:
auto-session still auto-*saves* on exit, so a walkthrough launched with its cwd
inside a project would write a session full of walkthrough buffers and
annotations, which the user's next `SessionRestore` in that project would load.

This did not occur during prototyping only because the walkthrough's cwd happened
to be `~/repos`, which is in the suppress list. That is luck, not design.

**The harm is overwriting, not littering.** Annotations are extmarks — runtime
state that `:mksession` never writes — so the walkthrough leaves no debris. The
damage is that saving *at all* replaces the user's existing session for that
project with the walkthrough's layout. Sessions already exist for several project
directories, so this is live, not theoretical.

This also means "clean up our buffers before exiting" does not help, and actively
hurts: it would overwrite a real session with an empty one.

**Fix, verified:** launch with `-c 'silent! SessionDisableAutoSave'`.

```
nvim -c 'silent! SessionDisableAutoSave' --listen <sock> <files...>
```

`SessionDisableAutoSave` is a user command provided by auto-session. Measured
against the installed version (2.5.1) with the user's real config:

```
default                      -> auto_save = true
after SessionDisableAutoSave -> auto_save = false
```

`silent!` so the launch still succeeds on a machine without auto-session.

(While checking this: the config uses the legacy option names
`auto_restore_enabled` and `auto_session_suppress_dirs`. 2.5.1 still aliases them
to `auto_restore` and `suppressed_dirs`, so the existing config is correct.)

## Live refresh — the walkthrough is not a snapshot

The code buffer is read-only to the user, but **not static**. If the dialog
surfaces a needed change, Claude makes the edit in the background and refreshes
the walkthrough in place, rather than the user leaving to go fix it.

```
user asks about a hunk  ->  Claude edits the file on disk
                        ->  Claude regenerates the spec (line numbers moved)
                        ->  require("walkthrough").refresh(spec)
```

`refresh(spec)` reloads changed buffers (`:checktime` / `:e!`), rebuilds the
quickfix list, re-renders all annotations, and restores the current hunk by `id`
— not by index or line number, both of which move under an edit.

Two consequences worth stating, because they are easy to get wrong:

- **Extmarks do not survive a disk-edit reload.** Editing the file underneath the
  buffer and reloading discards every extmark, so refresh must re-render from a
  freshly generated spec. It cannot patch in place.
- **Line numbers in the old spec are invalid the moment Claude edits.** The spec
  is regenerated after the edit, never adjusted. This is why hunks carry a stable
  `id`: it is the only thing that survives a refresh.

Read-only is enforced with `nomodifiable` on code buffers; the dialog buffer is
writable. The user never edits the walkthrough — they ask, and it changes.

## Known fragility

**Teardown leans on undocumented cmux behaviour.** Placing the walkthrough tab
left of the chat tab works because cmux happens to select the next tab to the
right on close. That is observed, not specified, and could change in any cmux
release. It is a deliberate trade: it buys a teardown with no dependency on
Claude being alive or listening, which is worth more than purity here.

The failure mode is mild and obvious — quitting lands on the wrong tab, and the
user switches manually. If that starts happening, the fallback is already proven:
Claude runs `close-surface` then `surface.focus` from its own surface (which
must be in that order — see the findings above).

Worth an integration test that asserts the landing tab, so a cmux upgrade
surfaces the change as a test failure rather than as daily friction.

## Open questions

None. Every question raised during design has been closed by measurement or by
an explicit decision; see Resolved below. The spec is ready to become an
implementation plan.

### Resolved

- **`<leader>a` ("agent") is the group key.** Confirmed.
- **Code buffers are read-only**, dialog buffer writable — with live refresh, so
  read-only never means "go somewhere else to change it".
- **Multi-file is required**, ordered by narrative rather than by file, built on
  the quickfix list.

## Authoring tours without an agent

Tours are played through the CLI, whoever asks for it — an agent, or a human
typing `walkthrough open`. Authoring is the part that does not require an agent.

- `.tours/*.tour` files are plain JSON, committed to the repo, and hand-editable.
  A tour is onboarding documentation that lives next to the code.
- `walkthrough list` discovers them; `walkthrough open .tours/onboarding.tour`
  plays one.
- `walkthrough validate` exits non-zero when a step no longer resolves, so a tour
  that has rotted fails CI instead of misleading a new hire six months later.
- Steps using `pattern` instead of `line` survive ordinary refactors without
  edits.

This is also the honest test of the format: if a tour is unpleasant to write by
hand, it is the wrong format, regardless of how well an agent emits it.

## Installation

Three independent pieces, each with a conventional install path:

**One install: the skill bundle.** `install.sh` links `skills/walkthrough` —
carrying `SKILL.md`, the CLI, the backends and the renderer — into
`~/.agents/skills/` (user-wide) or `.agents/skills/` (repo-local), plus
harness-specific directories for clients that do not yet read the shared
location.

Nothing else is installed. The CLI adds the bundle to nvim's runtimepath at
launch, so there is no plugin to manage and no version skew between the CLI and
the renderer — they ship as one directory. Putting `bin/` on `PATH` is optional
and only for driving it by hand.

### Editor support

**nvim only, deliberately, for now.** vim was assessed against the real system
build (9.1 on macOS):

| Capability | vim 9.1 | Verdict |
|---|---|---|
| `+textprop` | yes | virtual text below a line is achievable |
| `-lua` | no | renderer would need a vim9script rewrite |
| `-clientserver` | **no** | **blocker** — the CLI cannot drive it at all |

Without `+clientserver` there is no `walkthrough step`, no `reload`, and no agent
integration — and macOS ships vim that way, so it is the common case rather than
an edge one. `+channel`/`+job` are present, so a vim plugin could serve its own
socket instead, but that is a subproject, not a port. Revisit only if someone
wants it enough to build that.

Supported nvim versions: 0.10 and later (`vim.json`, extmarks with `virt_lines`,
`vim.keymap.set`). CI runs the headless suite against 0.10, 0.11 and 0.12.

## Phasing

Build order. Each phase leaves something usable.

1. **Tour format + renderer.** Load a `.tour`, render it, navigate it. Fixture
   driven, no agent, no backend — `nvim -c 'lua require("walkthrough").open(...)'`.
   Already useful: hand-authored tours play.
2. **CLI + backend abstraction + cmux and tmux backends.** `walkthrough open`
   works from any terminal. This is the first release worth publishing.
3. **Skill.** Agents can author tours. One `SKILL.md`, no per-harness work.
4. **Dialog.** Ask about a hunk from inside nvim; the agent answers in place.
   Requires an agent, so it is deliberately last — everything before it works
   without one.

## Reference environment

The environment this was designed and verified against. Nothing here is a
requirement — it is recorded so a reader can tell which findings are universal
and which are local.

- macOS 26, nvim 0.12.1, cmux with Ghostty, zsh.
- Login shell is Apple's `/bin/zsh`; the nixpkgs zsh build hangs in a
  `getoutput()` SIGCHLD race. **This is local, but the lesson is general:** never
  treat "the shell reached a prompt" as a readiness signal. Backends wait for the
  nvim socket to appear, which is the only thing that actually proves readiness.
- Config generated by nixvim; `init.lua` is a read-only symlink into
  `/nix/store`. **Lesson is general:** never write to the user's config. Install
  via the plugin manager, and expose behaviour through setup options.
- `auto-session` is installed, so the player launches nvim with
  `-c 'silent! SessionDisableAutoSave'`. **Lesson is general:** the player opens a
  throwaway editor; it must not let session managers persist that state over the
  user's real sessions.
