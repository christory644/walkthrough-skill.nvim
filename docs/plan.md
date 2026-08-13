# walkthrough.nvim — Implementation Plan (open-source v0.1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Play guided, annotated walkthroughs of a codebase inside nvim — authored by hand or by any coding agent — with the cursor parked on each step, narration rendered beside the code, and narrative order that crosses files freely.

**Architecture:** Three loosely-coupled layers. A Lua plugin renders CodeTour-format `.tour` files and knows nothing about terminals or agents. A shell CLI is the single entry point for every consumer. A pluggable, auto-detected backend (cmux / tmux / plain window) opens the surface nvim runs in. An Agent Skill is one optional consumer of the CLI, not a dependency.

**Tech Stack:** Lua (nvim 0.10+: extmarks, quickfix, autocmds), POSIX shell for the CLI and backends, CodeTour `.tour` JSON, Agent Skills (`SKILL.md`), GitHub Actions CI.

**Spec:** `docs/design.md`

**Out of scope (separate plan):** the in-nvim dialog — asking an agent about a step from inside nvim. Everything here works without an agent; the dialog is the only part that cannot.

## Global Constraints

- **nvim 0.10+.** No plugin dependencies in `lua/` — must load under `--clean`. which-key is optional and probed with `pcall`.
- **Tour format is CodeTour, unmodified.** No proprietary fields. Unknown fields are preserved on read and ignored.
- **Required by CodeTour:** tour has `title` and `steps`; each step has `description`. Everything else is optional.
- **Step location is `line` OR `pattern`.** `pattern` is a Lua-compatible regex resolved against buffer content at render time.
- **Narration renders as `virt_lines` above the step**, never end-of-line (truncates at pane width).
- **Position across a reload is restored by step `title`** when present and unique, else by index.
- **Code buffers are `nomodifiable`.**
- **Backends are auto-detected**: `$CMUX_SURFACE_ID` → cmux, `$TMUX` → tmux, else window. `WALKTHROUGH_BACKEND` overrides.
- **cmux surfaces are addressed by UUID only** (`--id-format uuids`); positional refs shift and will close an unrelated tab.
- **Never treat a shell prompt as readiness.** Wait for the nvim socket to appear.
- **The player must not persist state over the user's own**: launch nvim with `-c 'silent! SessionDisableAutoSave'`.
- Tests: `nvim --headless --clean -l <file>`; signal failure with `vim.cmd("cq")`.
- Shell is POSIX `sh` where possible; `bash` only where arrays are needed, declared with `#!/usr/bin/env bash`.

---

### Task 1: Repo scaffold, test harness, and tour loading

**Files:**
- Create: `lua/walkthrough/tour.lua`
- Create: `tests/harness.lua`
- Create: `tests/fixtures/two_files.tour`
- Create: `tests/fixtures/alpha.txt`, `tests/fixtures/beta.txt`
- Create: `tests/test_tour.lua`
- Create: `tests/run.sh`
- Create: `.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: `tour.load(path) -> tour`; `tour.validate(tbl) -> tour`; `tour.resolve(step, bufnr) -> line|nil` (honours `pattern`); `tour.step_id(tour, i) -> string`. Harness: `T.eq/T.ok/T.err/T.done/T.load_plugin`.

- [ ] **Step 1: Scaffold**

```bash
cd ~/repos/nvim-walkthrough
mkdir -p lua/walkthrough tests/fixtures bin backends skills/walkthrough .github/workflows
printf '*.log\n.tmp/\n' > .gitignore
git init 2>/dev/null || true
```

- [ ] **Step 2: Write the test harness**

Create `tests/harness.lua`:

```lua
-- Minimal assert harness. No plugin deps: tests run under `nvim --clean`.
local T = { failures = 0, checks = 0 }

local function report(ok, msg)
  T.checks = T.checks + 1
  if not ok then
    T.failures = T.failures + 1
    io.write("  FAIL: ", msg or "(no message)", "\n")
  end
end

function T.ok(cond, msg) report(cond and true or false, msg) end

function T.eq(a, b, msg)
  report(vim.deep_equal(a, b), string.format("%s\n    expected: %s\n    actual:   %s",
    msg or "values differ", vim.inspect(b), vim.inspect(a)))
end

function T.err(fn, pat, msg)
  local ok, e = pcall(fn)
  if ok then
    report(false, (msg or "expected an error") .. " (none raised)")
  else
    report(tostring(e):match(pat) ~= nil,
      string.format("%s\n    error %q did not match %q", msg or "wrong error", tostring(e), pat))
  end
end

function T.done()
  io.write(string.format("  %d checks, %d failures\n", T.checks, T.failures))
  if T.failures > 0 then vim.cmd("cq") end
end

function T.load_plugin() vim.opt.runtimepath:append(vim.fn.getcwd()) end

return T
```

- [ ] **Step 3: Write fixtures**

Create `tests/fixtures/two_files.tour` — real CodeTour shape; narrative order deliberately crosses files and comes back:

```json
{
  "title": "Two-file tour",
  "description": "Fixture: narrative order is not file order.",
  "steps": [
    {
      "title": "first",
      "file": "tests/fixtures/alpha.txt",
      "line": 2,
      "description": "First note.\nSecond line of the first note.",
      "selection": { "start": { "line": 2, "character": 1 },
                     "end":   { "line": 3, "character": 1 } }
    },
    {
      "title": "other file",
      "file": "tests/fixtures/beta.txt",
      "line": 1,
      "description": "Note in the other file."
    },
    {
      "title": "back again",
      "file": "tests/fixtures/alpha.txt",
      "pattern": "^five$",
      "description": "Located by pattern, not line number."
    }
  ]
}
```

```bash
printf 'one\ntwo\nthree\nfour\nfive\n' > tests/fixtures/alpha.txt
printf 'beta one\nbeta two\n' > tests/fixtures/beta.txt
```

- [ ] **Step 4: Write the failing test**

Create `tests/test_tour.lua`:

```lua
local T = dofile("tests/harness.lua")
T.load_plugin()
local tour = require("walkthrough.tour")

local t = tour.load("tests/fixtures/two_files.tour")
T.eq(t.title, "Two-file tour", "title parsed")
T.eq(#t.steps, 3, "three steps")
T.eq(t.steps[2].file, "tests/fixtures/beta.txt", "narrative order crosses files")
T.ok(t.steps[1].abspath:sub(1, 1) == "/", "abspath resolved")

-- selection becomes the highlighted range
T.eq(t.steps[1].range, { 2, 3 }, "selection mapped to a line range")
-- a step with no selection highlights just its own line
T.eq(t.steps[2].range, { 1, 1 }, "range defaults to the single line")

-- ids come from titles, which is what survives a reload
T.eq(tour.step_id(t, 1), "first", "id from step title")

-- CodeTour requires description; a step without one is invalid
T.err(function() tour.validate({ title = "x", steps = { { file = "a", line = 1 } } }) end,
  "description", "step without description rejected")
-- tour without title or steps is invalid
T.err(function() tour.validate({ steps = {} }) end, "title", "tour without title rejected")
T.err(function() tour.validate({ title = "x" }) end, "steps", "tour without steps rejected")

-- pattern resolution happens against buffer content
vim.cmd("edit tests/fixtures/alpha.txt")
local buf = vim.api.nvim_get_current_buf()
T.eq(tour.resolve(t.steps[3], buf), 5, "pattern located line 5")
T.eq(tour.resolve(t.steps[1], buf), 2, "explicit line used when present")
T.eq(tour.resolve({ pattern = "^nope$" }, buf), nil, "unmatched pattern returns nil")

-- unknown top-level fields survive (forward compatibility with CodeTour)
local kept = tour.validate({ title = "x", nextTour = "y", steps = {
  { description = "d", file = "tests/fixtures/alpha.txt", line = 1 } } })
T.eq(kept.nextTour, "y", "unknown fields preserved")

T.done()
```

- [ ] **Step 5: Write the test runner**

Create `tests/run.sh`:

```bash
#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
for f in tests/test_*.lua; do
  echo "== $f"
  nvim --headless --clean -l "$f" || { fail=1; echo "  ^ FAILED"; }
done
[ "$fail" -eq 0 ] && echo "ALL TESTS PASSED" || echo "TESTS FAILED"
exit "$fail"
```

```bash
chmod +x tests/run.sh
```

- [ ] **Step 6: Run to verify failure**

Run: `./tests/run.sh`
Expected: FAIL — `module 'walkthrough.tour' not found`

- [ ] **Step 7: Implement the tour module**

Create `lua/walkthrough/tour.lua`:

```lua
local M = {}

-- Validate a CodeTour document. We validate shape only: whether a file exists
-- is a question about the world at render time, not about the document.
-- Unknown fields are preserved so tours written for newer CodeTour versions,
-- or for other players, survive a round trip through us.
function M.validate(t)
  if type(t) ~= "table" then error("tour must be an object") end
  if type(t.title) ~= "string" or t.title == "" then
    error("tour is missing required field 'title'")
  end
  if type(t.steps) ~= "table" or #t.steps == 0 then
    error("tour is missing a non-empty 'steps' array")
  end

  for i, s in ipairs(t.steps) do
    if type(s.description) ~= "string" then
      error(string.format("step %d: missing required field 'description'", i))
    end
    -- A step is playable if it names a file and can locate a line in it.
    s.playable = type(s.file) == "string"
      and (type(s.line) == "number" or type(s.pattern) == "string")
    if s.file then s.abspath = vim.fn.fnamemodify(s.file, ":p") end

    -- selection is CodeTour's range; collapse it to whole lines for highlighting
    if type(s.selection) == "table" and s.selection.start and s.selection["end"] then
      s.range = { s.selection.start.line, s.selection["end"].line }
    elseif type(s.line) == "number" then
      s.range = { s.line, s.line }
    end
  end
  return t
end

function M.load(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then error("cannot read tour: " .. path) end
  local decoded_ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decoded_ok then error("tour is not valid JSON: " .. tostring(decoded)) end
  return M.validate(decoded)
end

-- CodeTour has no step id. `title` is the closest stable, human-meaningful
-- handle; index is the fallback. This is what position is restored by.
function M.step_id(t, i)
  local s = t.steps[i]
  if s and type(s.title) == "string" and s.title ~= "" then return s.title end
  return tostring(i)
end

-- Resolve a step to a line in `bufnr`. An explicit line wins; otherwise the
-- first line matching `pattern`. Returns nil when it cannot be located, which
-- the caller must treat as "skip and report", never as line 1.
function M.resolve(step, bufnr)
  if type(step.line) == "number" then return step.line end
  if type(step.pattern) ~= "string" then return nil end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, l in ipairs(lines) do
    if vim.regex(step.pattern):match_str(l) then return i end
  end
  return nil
end

return M
```

- [ ] **Step 8: Run to verify pass**

Run: `./tests/run.sh`
Expected: `ALL TESTS PASSED`

- [ ] **Step 9: Commit**

```bash
git add lua/walkthrough/tour.lua tests/ .gitignore
git commit -m "feat: load and validate CodeTour .tour files"
```

---

### Task 2: Rendering

**Files:**
- Create: `lua/walkthrough/render.lua`
- Create: `tests/test_render.lua`

**Interfaces:**
- Consumes: `tour.resolve`, step fields `abspath`, `range`, `description`, `title`.
- Produces: `render.NS`; `render.apply(bufnr, tour, current_index)`; `render.clear(bufnr)`; `render.park(winid, bufnr, line)`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_render.lua`:

```lua
local T = dofile("tests/harness.lua")
T.load_plugin()
local tour   = require("walkthrough.tour")
local render = require("walkthrough.render")

local t = tour.load("tests/fixtures/two_files.tour")
vim.cmd("edit tests/fixtures/alpha.txt")
local buf = vim.api.nvim_get_current_buf()

render.apply(buf, t, 1)
local marks = vim.api.nvim_buf_get_extmarks(buf, render.NS, 0, -1, { details = true })
T.ok(#marks > 0, "extmarks placed")

local virt = 0
for _, m in ipairs(marks) do if m[4] and m[4].virt_lines then virt = virt + 1 end end
T.eq(virt, 2, "only alpha.txt steps render here (step 2 is in beta.txt)")

for _, m in ipairs(marks) do
  if m[4] and m[4].virt_lines then
    T.ok(m[4].virt_lines_above == true, "narration renders above the code")
    T.ok(m[4].virt_text == nil, "never end-of-line virtual text")
  end
end

-- the pattern-located step is anchored at the line the pattern matched (5)
local anchored_at_five = false
for _, m in ipairs(marks) do
  if m[4] and m[4].virt_lines and m[2] == 4 then anchored_at_five = true end
end
T.ok(anchored_at_five, "pattern step anchored at its resolved line")

render.clear(buf)
T.eq(#vim.api.nvim_buf_get_extmarks(buf, render.NS, 0, -1, {}), 0, "cleared")

render.park(0, buf, 5)
T.eq(vim.api.nvim_win_get_cursor(0)[1], 5, "parked")
render.park(0, buf, 999)
T.eq(vim.api.nvim_win_get_cursor(0)[1], 5, "clamped to last line, no error")

T.done()
```

- [ ] **Step 2: Run to verify failure**

Run: `nvim --headless --clean -l tests/test_render.lua`
Expected: FAIL — `module 'walkthrough.render' not found`

- [ ] **Step 3: Implement**

Create `lua/walkthrough/render.lua`:

```lua
local tour = require("walkthrough.tour")

local M = {}
M.NS = vim.api.nvim_create_namespace("walkthrough")

local SIGN_GROUP, SIGN_NAME = "walkthrough", "WalkthroughStep"
vim.fn.sign_define(SIGN_NAME, { text = "▶", texthl = "DiagnosticInfo" })

function M.clear(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, M.NS, 0, -1)
  pcall(vim.fn.sign_unplace, SIGN_GROUP, { buffer = bufnr })
end

-- Every step for this buffer is drawn: all visible so the shape of the tour is
-- legible at a glance, the current one emphasised so there is a focus.
function M.apply(bufnr, t, current_index)
  M.clear(bufnr)
  local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")
  local total, count = #t.steps, vim.api.nvim_buf_line_count(bufnr)

  for i, s in ipairs(t.steps) do
    if s.playable and s.abspath == path then
      local line = tour.resolve(s, bufnr)
      if line then
        local cur = (i == current_index)
        local hl = cur and "DiagnosticInfo" or "Comment"
        local virt = { { { string.format("  %s step %d/%d%s", cur and "▶" or " ", i, total,
          s.title and ("  " .. s.title) or ""), cur and "DiagnosticInfo" or "NonText" } } }
        for _, l in ipairs(vim.split(s.description, "\n", { plain = true })) do
          table.insert(virt, { { "  │ " .. l, hl } })
        end

        local anchor = math.min(math.max(line, 1), count)
        vim.api.nvim_buf_set_extmark(bufnr, M.NS, anchor - 1, 0,
          { virt_lines = virt, virt_lines_above = true })

        if cur then
          local r = s.range or { line, line }
          for l = math.max(r[1], 1), math.min(r[2], count) do
            vim.api.nvim_buf_set_extmark(bufnr, M.NS, l - 1, 0, { line_hl_group = "Visual" })
          end
          vim.fn.sign_place(0, SIGN_GROUP, SIGN_NAME, bufnr, { lnum = anchor, priority = 100 })
        end
      end
    end
  end
end

function M.park(winid, bufnr, line)
  local count = vim.api.nvim_buf_line_count(bufnr)
  vim.api.nvim_win_set_cursor(winid, { math.min(math.max(line, 1), count), 0 })
  vim.api.nvim_win_call(winid, function() vim.cmd("normal! zz") end)
end

return M
```

- [ ] **Step 4: Run to verify pass**

Run: `nvim --headless --clean -l tests/test_render.lua`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lua/walkthrough/render.lua tests/test_render.lua
git commit -m "feat: render steps as virt_lines above the code"
```

---

### Task 3: Narrative navigation on the quickfix list

**Files:**
- Create: `lua/walkthrough/nav.lua`
- Create: `tests/test_nav.lua`

**Interfaces:**
- Consumes: `tour.resolve`, `render.apply`, `render.park`.
- Produces: `nav.populate(t)`; `nav.goto_index(state, i) -> index` where `state = { tour = <tour>, index = <n> }`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_nav.lua`:

```lua
local T = dofile("tests/harness.lua")
T.load_plugin()
local tour = require("walkthrough.tour")
local nav  = require("walkthrough.nav")

local t = tour.load("tests/fixtures/two_files.tour")
nav.populate(t)
local qf = vim.fn.getqflist()
T.eq(#qf, 3, "one quickfix entry per step")

local names = {}
for _, e in ipairs(qf) do
  table.insert(names, vim.fn.fnamemodify(vim.fn.bufname(e.bufnr), ":t"))
end
T.eq(names, { "alpha.txt", "beta.txt", "alpha.txt" }, "narrative order, not file order")
T.ok(qf[1].text:match("first") ~= nil, "entry text carries the step title")

local state = { tour = t, index = 1 }
T.eq(nav.goto_index(state, 2), 2, "moved to step 2")
T.eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"), "beta.txt", "switched file")
T.eq(nav.goto_index(state, 3), 3, "moved to step 3")
T.eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"), "alpha.txt", "switched back")
T.eq(vim.api.nvim_win_get_cursor(0)[1], 5, "pattern step parked on its match")
T.eq(nav.goto_index(state, 99), 3, "clamps at the end")
T.eq(nav.goto_index(state, -1), 1, "clamps at the start")

T.done()
```

- [ ] **Step 2: Run to verify failure**

Run: `nvim --headless --clean -l tests/test_nav.lua`
Expected: FAIL — `module 'walkthrough.nav' not found`

- [ ] **Step 3: Implement**

Create `lua/walkthrough/nav.lua`:

```lua
local tour   = require("walkthrough.tour")
local render = require("walkthrough.render")

local M = {}

-- The quickfix list IS the narrative: ordered, crosses files, and gives
-- :cnext/:cprev/:copen for free.
function M.populate(t)
  local items = {}
  for i, s in ipairs(t.steps) do
    if s.playable then
      local first = vim.split(s.description, "\n", { plain = true })[1] or ""
      table.insert(items, {
        filename = s.abspath,
        lnum = s.line or 1,
        col = 1,
        text = string.format("[%d/%d] %s — %s", i, #t.steps, s.title or ("step " .. i), first),
      })
    end
  end
  vim.fn.setqflist({}, " ", { title = "walkthrough: " .. t.title, items = items })
end

function M.goto_index(state, i)
  local t = state.tour
  i = math.max(1, math.min(#t.steps, i))
  local s = t.steps[i]

  local bufnr = vim.fn.bufnr(s.abspath)
  if bufnr == -1 or not vim.api.nvim_buf_is_loaded(bufnr) then
    vim.cmd("edit " .. vim.fn.fnameescape(s.abspath))
    bufnr = vim.api.nvim_get_current_buf()
  elseif vim.api.nvim_get_current_buf() ~= bufnr then
    vim.cmd("buffer " .. bufnr)
  end

  state.index = i
  render.apply(bufnr, t, i)
  local line = tour.resolve(s, bufnr)
  if line then render.park(0, bufnr, line) end
  vim.bo[bufnr].modifiable = false

  vim.api.nvim_echo({ { string.format("  [%d/%d] %s", i, #t.steps, s.title or ""), "ModeMsg" } },
    false, {})
  return i
end

return M
```

- [ ] **Step 4: Run to verify pass**

Run: `nvim --headless --clean -l tests/test_nav.lua`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lua/walkthrough/nav.lua tests/test_nav.lua
git commit -m "feat: narrative navigation on the quickfix list"
```

---

### Task 4: Public API and keymaps

**Files:**
- Create: `lua/walkthrough/init.lua`
- Create: `lua/walkthrough/keys.lua`
- Create: `tests/test_api.lua`

**Interfaces:**
- Consumes: `tour.*`, `render.*`, `nav.*`.
- Produces: `walkthrough.setup(opts)`, `walkthrough.open(path_or_tour)`, `walkthrough.step(delta)`, `walkthrough.goto_step(n)`, `walkthrough.close()`, `walkthrough.state()`, `walkthrough.list(dir)`.

There are no `:Walkthrough*` user commands. The entry point is always the CLI
(driven by an agent harness), so commands for driving nvim by hand would be
surface area with no consumer.

- [ ] **Step 1: Write the failing test**

Create `tests/test_api.lua`:

```lua
local T = dofile("tests/harness.lua")
T.load_plugin()
local wt = require("walkthrough")

wt.open("tests/fixtures/two_files.tour")
local st = wt.state()
T.ok(st.active, "active")
T.eq(st.count, 3, "three steps")
T.eq(st.index, 1, "starts at step 1")
T.eq(st.id, "first", "id from step title")
T.ok(vim.bo.modifiable == false, "code buffer read-only")

local maps = {}
for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do maps[m.lhs] = true end
T.ok(maps["]w"], "]w bound buffer-locally")

wt.step(1)
T.eq(wt.state().index, 2, "stepped forward")
wt.step(-5)
T.eq(wt.state().index, 1, "clamps, does not wrap")
wt.goto_step(3)
T.eq(wt.state().id, "back again", "goto_step by index")

wt.close()
T.ok(not wt.state().active, "closed")
local render = require("walkthrough.render")
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_loaded(b) then
    T.eq(#vim.api.nvim_buf_get_extmarks(b, render.NS, 0, -1, {}), 0, "annotations gone")
  end
end

-- configurable keys; nothing is bound globally
wt.setup({ keys = { next = "<Tab>", prev = "<S-Tab>" } })
wt.open("tests/fixtures/two_files.tour")
maps = {}
for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do maps[m.lhs] = true end
T.ok(maps["<Tab>"], "custom next key bound")
wt.close()

-- a bad tour must not leave a half-open walkthrough
T.err(function() wt.open({ steps = {} }) end, "title", "invalid tour rejected")
T.ok(not wt.state().active, "still inactive")

T.done()
```

- [ ] **Step 2: Run to verify failure**

Run: `nvim --headless --clean -l tests/test_api.lua`
Expected: FAIL — `module 'walkthrough' not found`

- [ ] **Step 3: Implement keymaps**

Create `lua/walkthrough/keys.lua`:

```lua
local M = {}

M.defaults = {
  next = "]w", prev = "[w", close = "<leader>aq",
  next_cmd = "<leader>an", prev_cmd = "<leader>ap",
}

function M.attach(bufnr, keys)
  local wt = require("walkthrough")
  local o = function(d) return { buffer = bufnr, silent = true, desc = d } end
  local map = function(lhs, fn, desc)
    if lhs and lhs ~= "" then vim.keymap.set("n", lhs, fn, o(desc)) end
  end

  map(keys.next, function() wt.step(1) end, "walkthrough: next step")
  map(keys.prev, function() wt.step(-1) end, "walkthrough: prev step")
  map(keys.next_cmd, function() wt.step(1) end, "next step")
  map(keys.prev_cmd, function() wt.step(-1) end, "prev step")
  map(keys.close, function() wt.close() end, "end walkthrough")

  local ok, wk = pcall(require, "which-key")
  if ok and wk.add and keys.close and keys.close:match("^<leader>a") then
    wk.add({ { "<leader>a", group = "agent", buffer = bufnr } })
  end
end

function M.detach(bufnr, keys)
  for _, lhs in pairs(keys) do
    if type(lhs) == "string" and lhs ~= "" then
      pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
    end
  end
end

return M
```

- [ ] **Step 4: Implement the public API**

Create `lua/walkthrough/init.lua`:

```lua
local tour_mod = require("walkthrough.tour")
local render   = require("walkthrough.render")
local nav      = require("walkthrough.nav")
local keys_mod = require("walkthrough.keys")

local M = {}

local config = { keys = vim.deepcopy(keys_mod.defaults), close_surface = true }
local state  = { active = false, tour = nil, index = 0, touched = {}, skipped = {} }

function M.setup(opts)
  opts = opts or {}
  if opts.keys then config.keys = vim.tbl_extend("force", config.keys, opts.keys) end
  if opts.close_surface ~= nil then config.close_surface = opts.close_surface end
end

function M.state()
  return {
    active = state.active,
    index = state.index,
    count = state.tour and #state.tour.steps or 0,
    id = state.tour and tour_mod.step_id(state.tour, state.index) or nil,
    skipped = state.skipped,
    title = state.tour and state.tour.title or nil,
  }
end

local function remember(b) state.touched[b] = true end

local function install_autocmd()
  state.augroup = vim.api.nvim_create_augroup("Walkthrough", { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = state.augroup,
    callback = function(ev)
      if not state.active then return end
      local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(ev.buf), ":p")
      for _, s in ipairs(state.tour.steps) do
        if s.abspath == path then
          render.apply(ev.buf, state.tour, state.index)
          keys_mod.attach(ev.buf, config.keys)
          vim.bo[ev.buf].modifiable = false
          remember(ev.buf)
          return
        end
      end
    end,
  })
end

function M.open(path_or_tour)
  local t = type(path_or_tour) == "string"
    and tour_mod.load(path_or_tour)
    or tour_mod.validate(path_or_tour)

  -- report steps we cannot play rather than silently shortening the tour
  local skipped = {}
  for i, s in ipairs(t.steps) do
    if not s.playable then
      table.insert(skipped, tour_mod.step_id(t, i))
    elseif vim.fn.filereadable(s.abspath) == 0 then
      s.playable = false
      table.insert(skipped, tour_mod.step_id(t, i))
    end
  end
  local playable = false
  for _, s in ipairs(t.steps) do if s.playable then playable = true break end end
  if not playable then error("no playable steps: every referenced file is missing") end

  state.tour, state.index, state.touched, state.skipped, state.active =
    t, 1, {}, skipped, true

  nav.populate(t)
  install_autocmd()

  local first = 1
  for i, s in ipairs(t.steps) do if s.playable then first = i break end end
  nav.goto_index({ tour = t, index = first }, first)
  state.index = first

  local buf = vim.api.nvim_get_current_buf()
  keys_mod.attach(buf, config.keys)
  remember(buf)

  if #skipped > 0 then
    vim.api.nvim_echo({ { string.format(
      "walkthrough: skipped %d unplayable step(s): %s",
      #skipped, table.concat(skipped, ", ")), "WarningMsg" } }, true, {})
  end
  return M.state()
end

function M.goto_step(n)
  if not state.active then return end
  local s = { tour = state.tour, index = state.index }
  state.index = nav.goto_index(s, n)
  local buf = vim.api.nvim_get_current_buf()
  keys_mod.attach(buf, config.keys)
  remember(buf)
end

function M.step(delta) M.goto_step(state.index + delta) end

-- Files changed on disk. Extmarks do not survive a reload, so re-render from
-- the tour rather than patching. Position is restored by step id.
function M.reload(path_or_tour)
  if not state.active then return M.open(path_or_tour) end
  local previous = tour_mod.step_id(state.tour, state.index)
  for b in pairs(state.touched) do
    if vim.api.nvim_buf_is_valid(b) then
      render.clear(b)
      vim.bo[b].modifiable = true
      vim.api.nvim_buf_call(b, function() vim.cmd("silent! edit!") end)
    end
  end
  state.active = false
  M.open(path_or_tour)
  for i = 1, #state.tour.steps do
    if tour_mod.step_id(state.tour, i) == previous then M.goto_step(i) break end
  end
  return M.state()
end

function M.close()
  if not state.active then return end
  for b in pairs(state.touched) do
    if vim.api.nvim_buf_is_valid(b) then
      render.clear(b)
      keys_mod.detach(b, config.keys)
    end
  end
  if state.augroup then pcall(vim.api.nvim_del_augroup_by_id, state.augroup) end
  state.augroup, state.active, state.tour, state.index, state.touched =
    nil, false, nil, 0, {}
  vim.fn.setqflist({}, "r", { title = "walkthrough", items = {} })

  -- Close our own surface if a backend gave us one. The backend positioned it
  -- so that closing returns the user where they came from.
  if config.close_surface then
    local handle = vim.env.WALKTHROUGH_HANDLE
    local backend = vim.env.WALKTHROUGH_BACKEND
    if handle and backend and vim.fn.executable("walkthrough") == 1 then
      vim.fn.jobstart({ "walkthrough", "_close_surface", backend, handle })
    end
  end
end

-- Tours discovered in the repository, CodeTour's convention.
function M.list(dir)
  return vim.fn.glob((dir or ".tours") .. "/*.tour", false, true)
end

return M
```

- [ ] **Step 5: Run to verify pass, then the suite**

Run: `nvim --headless --clean -l tests/test_api.lua`
Expected: PASS

Run: `./tests/run.sh`
Expected: `ALL TESTS PASSED`

- [ ] **Step 6: Commit**

```bash
git add lua/walkthrough/init.lua lua/walkthrough/keys.lua tests/test_api.lua
git commit -m "feat: public API, configurable keymaps, user commands"
```

---

### Task 5: Reload after files change on disk

**Files:**
- Create: `tests/test_reload.lua`

**Interfaces:**
- Consumes: `walkthrough.reload` (written in Task 4).
- Produces: no new API; this task proves the behaviour and fixes what it finds.

- [ ] **Step 1: Write the failing test**

Create `tests/test_reload.lua`:

```lua
local T = dofile("tests/harness.lua")
T.load_plugin()
local wt = require("walkthrough")

vim.fn.mkdir(".tmp", "p")
vim.fn.writefile({ "one", "two", "three", "four", "five" }, ".tmp/a.txt")

local function tour_with(offset)
  return { title = "t", steps = {
    { title = "s1", file = ".tmp/a.txt", line = 2 + offset, description = "one" },
    { title = "s2", file = ".tmp/a.txt", line = 5 + offset, description = "two" },
  } }
end

wt.open(tour_with(0))
wt.step(1)
T.eq(wt.state().id, "s2", "on s2 before the edit")

-- a line is inserted at the top: every subsequent line number shifts
vim.fn.writefile({ "NEW", "one", "two", "three", "four", "five" }, ".tmp/a.txt")
wt.reload(tour_with(1))

T.eq(wt.state().id, "s2", "position restored BY ID, not index or line")
T.eq(vim.api.nvim_win_get_cursor(0)[1], 6, "cursor followed the shift")
T.eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], "NEW", "buffer reloaded from disk")

local render = require("walkthrough.render")
local virt = 0
for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, render.NS, 0, -1, { details = true })) do
  if m[4] and m[4].virt_lines then virt = virt + 1 end
end
T.eq(virt, 2, "no duplicated annotations after reload")

-- pattern steps survive the same edit with no new line numbers at all
wt.close()
wt.open({ title = "t", steps = {
  { title = "p", file = ".tmp/a.txt", pattern = "^five$", description = "by pattern" } } })
T.eq(vim.api.nvim_win_get_cursor(0)[1], 6, "pattern step found the shifted line unaided")

wt.close()
vim.fn.delete(".tmp", "rf")
T.done()
```

- [ ] **Step 2: Run it**

Run: `nvim --headless --clean -l tests/test_reload.lua`
Expected: PASS if Task 4's `reload` is correct. If it fails, fix `M.reload` in `lua/walkthrough/init.lua` until it passes — do not modify the test.

- [ ] **Step 3: Run the suite**

Run: `./tests/run.sh`
Expected: `ALL TESTS PASSED`

- [ ] **Step 4: Commit**

```bash
git add tests/test_reload.lua lua/walkthrough/init.lua
git commit -m "test: reload restores position by id and pattern steps self-locate"
```

---

### Task 6: Backend interface and detection

**Files:**
- Create: `backends/common.sh`
- Create: `tests/test_backend_detect.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `wt_detect_backend()` → a backend name; each backend file defines `backend_open <cmd>` (prints a handle) and `backend_close <handle>`.

**cmux is the only backend implemented in v0.1.** Detection and the file layout
exist so adding another is one file with two functions and no changes anywhere
else — that seam is cheap now and expensive to retrofit. Detecting a terminal we
have no backend for must fail with a message that says exactly that, never fall
through to something that half-works.

- [ ] **Step 1: Write the failing test**

Create `tests/test_backend_detect.sh`:

```bash
#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.." || exit 1
. ./backends/common.sh

fail=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  ok: $1"; else echo "  FAIL: $1 (want $2, got $3)"; fail=1; fi
}

check "explicit override wins" "tmux" \
  "$(WALKTHROUGH_BACKEND=tmux CMUX_SURFACE_ID=x wt_detect_backend)"
check "cmux detected"         "cmux" \
  "$(WALKTHROUGH_BACKEND= CMUX_SURFACE_ID=abc TMUX= wt_detect_backend)"
check "tmux detected"         "tmux" \
  "$(WALKTHROUGH_BACKEND= CMUX_SURFACE_ID= TMUX=/tmp/x,1,0 wt_detect_backend)"
check "cmux wins over tmux"   "cmux" \
  "$(WALKTHROUGH_BACKEND= CMUX_SURFACE_ID=abc TMUX=/tmp/x,1,0 wt_detect_backend)"
check "unknown terminal"      "none" \
  "$(WALKTHROUGH_BACKEND= CMUX_SURFACE_ID= TMUX= wt_detect_backend)"

# a detected-but-unimplemented backend must fail loudly, not half-work
( . ./backends/common.sh; wt_require_backend tmux ) >/dev/null 2>&1
check "unimplemented backend errors" "1" "$?"

[ "$fail" -eq 0 ] && echo "BACKEND DETECT PASSED"
exit "$fail"
```

```bash
chmod +x tests/test_backend_detect.sh
```

- [ ] **Step 2: Run to verify failure**

Run: `./tests/test_backend_detect.sh`
Expected: FAIL — `./backends/common.sh: No such file or directory`

- [ ] **Step 3: Implement detection and the fallback backend**

Create `backends/common.sh`:

```bash
# Shared backend helpers. Sourced, never executed.

# cmux first: if both are present we are inside cmux running tmux, and the
# outer multiplexer owns the surface the user actually sees.
wt_detect_backend() {
  if [ -n "${WALKTHROUGH_BACKEND:-}" ]; then echo "$WALKTHROUGH_BACKEND"; return; fi
  if [ -n "${CMUX_SURFACE_ID:-}" ]; then echo "cmux"; return; fi
  if [ -n "${TMUX:-}" ]; then echo "tmux"; return; fi
  echo "none"
}

# Only cmux ships in v0.1. Anything else must say so plainly: a half-working
# fallback is worse than a clear refusal, because the user cannot tell the
# difference between "unsupported" and "broken".
wt_require_backend() {
  name="$1"
  root="${WALKTHROUGH_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)}"
  if [ ! -f "$root/backends/$name.sh" ]; then
    echo "walkthrough: no backend for '$name'." >&2
    echo "  v0.1 supports cmux. Adding a backend is one file:" >&2
    echo "  backends/$name.sh defining backend_open and backend_close." >&2
    echo "  Override detection with WALKTHROUGH_BACKEND." >&2
    return 1
  fi
  return 0
}

# Readiness is the socket, never the shell prompt: a slow or broken shell rc
# can leave a terminal that never reaches a prompt at all.
wt_wait_for_socket() {
  sock="$1"; tries="${2:-60}"
  i=0
  while [ "$i" -lt "$tries" ]; do
    if nvim --server "$sock" --remote-expr '1' >/dev/null 2>&1; then return 0; fi
    i=$((i + 1))
  done
  return 1
}

wt_nvim_cmd() { # $1=socket, rest=files
  sock="$1"; shift
  # SessionDisableAutoSave: the player is a throwaway editor and must not let a
  # session manager persist its state over the user's own sessions.
  printf "nvim -c 'silent! SessionDisableAutoSave' --listen %s" "$sock"
  for f in "$@"; do printf " %s" "$(printf %q "$f")"; done
}
```

- [ ] **Step 4: Run to verify pass**

Run: `./tests/test_backend_detect.sh`
Expected: `BACKEND DETECT PASSED`

- [ ] **Step 5: Commit**

```bash
git add backends/common.sh tests/test_backend_detect.sh
git commit -m "feat: backend detection with a loud failure for unimplemented backends"
```

---

### Task 7: cmux backend

**Files:**
- Create: `backends/cmux.sh`
- Create: `tests/test_backend_cmux.sh`

**Interfaces:**
- Consumes: `backends/common.sh`.
- Produces: `backend_open`/`backend_close` for cmux; handle is a surface UUID.

- [ ] **Step 1: Write the failing test**

Create `tests/test_backend_cmux.sh`:

```bash
#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.." || exit 1
[ -n "${CMUX_SURFACE_ID:-}" ] || { echo "SKIP: not inside cmux"; exit 0; }

. ./backends/common.sh
. ./backends/cmux.sh

UUID='[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}'
CM="$(command -v cmux || echo /Applications/cmux.app/Contents/Resources/bin/cmux)"
active() {
  "$CM" tree --id-format uuids 2>/dev/null \
    | awk '/workspace .*\[selected\]/{w=1} w && /surface/ && /◀ active/{print; exit}' \
    | grep -oE "$UUID" | head -1
}

SOCK="${TMPDIR:-/tmp}/wt-cmux-$$.sock"; rm -f "$SOCK"
handle=$(backend_open "$(wt_nvim_cmd "$SOCK" tests/fixtures/alpha.txt)")

fail=0
echo "$handle" | grep -qE "^$UUID$" || { echo "FAIL: handle is not a uuid"; fail=1; }
wt_wait_for_socket "$SOCK" 60 || { echo "FAIL: nvim never came up"; fail=1; }

# closing must land the user back where they started
backend_close "$handle"
sleep 1
[ "$(active)" = "$CMUX_SURFACE_ID" ] || { echo "FAIL: focus did not return"; fail=1; }

rm -f "$SOCK"
[ "$fail" -eq 0 ] && echo "CMUX BACKEND PASSED"
exit "$fail"
```

```bash
chmod +x tests/test_backend_cmux.sh
```

- [ ] **Step 2: Run to verify failure**

Run: `./tests/test_backend_cmux.sh`
Expected: FAIL — `./backends/cmux.sh: No such file or directory` (or `SKIP` outside cmux)

- [ ] **Step 3: Implement**

Create `backends/cmux.sh`:

```bash
# cmux backend. A tab (surface), not a split: a split would put the agent's
# conversation and the tour side by side, competing for attention.
CMUX_BIN="${CMUX_BIN:-$(command -v cmux || echo /Applications/cmux.app/Contents/Resources/bin/cmux)}"
CMUX_UUID_RE='[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}'

backend_open() {
  cmd="$1"
  caller="${CMUX_SURFACE_ID:?cmux backend requires CMUX_SURFACE_ID}"

  # UUIDs only. Positional refs (surface:19) are indexes that shift as tabs are
  # created and destroyed, and will eventually close an unrelated tab.
  handle="$("$CMUX_BIN" new-surface --type terminal --focus false --id-format uuids \
    | grep -oE "$CMUX_UUID_RE" | head -1)"
  [ -n "$handle" ] || return 1

  # Position immediately LEFT of the caller. cmux selects the tab to the right
  # when one closes, so this returns the user to where they came from with no
  # focus call at teardown — which matters because a process cannot talk to cmux
  # after its own surface is gone (the socket dies with it).
  "$CMUX_BIN" move-surface --surface "$handle" --before "$caller" >/dev/null 2>&1
  "$CMUX_BIN" rpc surface.focus "{\"surface_id\":\"$handle\"}" >/dev/null 2>&1

  "$CMUX_BIN" send --surface "$handle" "$cmd" >/dev/null 2>&1
  "$CMUX_BIN" send-key --surface "$handle" enter >/dev/null 2>&1
  echo "$handle"
}

backend_close() {
  "$CMUX_BIN" close-surface --surface "$1" >/dev/null 2>&1
  return 0
}
```

- [ ] **Step 4: Run to verify pass**

Run: `./tests/test_backend_cmux.sh`
Expected: `CMUX BACKEND PASSED`

- [ ] **Step 5: Commit**

```bash
git add backends/cmux.sh tests/test_backend_cmux.sh
git commit -m "feat: cmux backend with positional focus return"
```

---

### Task 8: The `walkthrough` CLI

**Files:**
- Create: `bin/walkthrough`
- Create: `schema.json`
- Create: `tests/test_cli.sh`

**Interfaces:**
- Consumes: `backends/*`, the Lua API.
- Produces: `walkthrough open|step|reload|close|list|validate|schema`; state cached in `${XDG_RUNTIME_DIR:-/tmp}/walkthrough-$USER.state`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_cli.sh`:

```bash
#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; else echo "  FAIL: $1 (want $2, got $3)"; fail=1; fi }

# validate: exit 0 for a good tour, non-zero for a broken one
./bin/walkthrough validate tests/fixtures/two_files.tour >/dev/null 2>&1
check "valid tour exits 0" "0" "$?"

cat > .tmp-bad.tour <<'EOF'
{ "steps": [] }
EOF
./bin/walkthrough validate .tmp-bad.tour >/dev/null 2>&1
check "invalid tour exits non-zero" "1" "$?"
rm -f .tmp-bad.tour

# a tour pointing at a deleted file is invalid too — this is what CI catches
cat > .tmp-rotted.tour <<'EOF'
{ "title": "t", "steps": [ { "file": "does/not/exist.py", "line": 1, "description": "d" } ] }
EOF
./bin/walkthrough validate .tmp-rotted.tour >/dev/null 2>&1
check "rotted tour exits non-zero" "1" "$?"
rm -f .tmp-rotted.tour

# schema is machine-readable so an agent can self-check
./bin/walkthrough schema | grep -q '"steps"'
check "schema mentions steps" "0" "$?"

# list finds tours in .tours/
mkdir -p .tours && cp tests/fixtures/two_files.tour .tours/
./bin/walkthrough list | grep -q 'two_files.tour'
check "list finds tours" "0" "$?"
rm -rf .tours

./bin/walkthrough --help >/dev/null 2>&1
check "help exits 0" "0" "$?"

[ "$fail" -eq 0 ] && echo "CLI TESTS PASSED"
exit "$fail"
```

```bash
chmod +x tests/test_cli.sh
```

- [ ] **Step 2: Run to verify failure**

Run: `./tests/test_cli.sh`
Expected: FAIL — `./bin/walkthrough: No such file or directory`

- [ ] **Step 3: Write the JSON schema**

Create `schema.json`:

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "walkthrough tour (CodeTour-compatible)",
  "type": "object",
  "required": ["title", "steps"],
  "properties": {
    "title": { "type": "string" },
    "description": { "type": "string" },
    "ref": { "type": "string" },
    "steps": {
      "type": "array",
      "minItems": 1,
      "items": {
        "type": "object",
        "required": ["description"],
        "properties": {
          "title": { "type": "string" },
          "description": { "type": "string" },
          "file": { "type": "string" },
          "line": { "type": "integer", "minimum": 1 },
          "pattern": { "type": "string" },
          "selection": {
            "type": "object",
            "required": ["start", "end"],
            "properties": {
              "start": { "type": "object", "required": ["line", "character"] },
              "end":   { "type": "object", "required": ["line", "character"] }
            }
          }
        }
      }
    }
  }
}
```

- [ ] **Step 4: Implement the CLI**

Create `bin/walkthrough`:

```bash
#!/usr/bin/env bash
# walkthrough — play guided code tours in nvim.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${XDG_RUNTIME_DIR:-/tmp}/walkthrough-${USER:-x}.state"
. "$ROOT/backends/common.sh"

die() { echo "walkthrough: $*" >&2; exit 1; }

load_backend() {
  BACKEND="$(wt_detect_backend)"
  [ -f "$ROOT/backends/$BACKEND.sh" ] || die "unknown backend: $BACKEND"
  . "$ROOT/backends/$BACKEND.sh"
}

# Validate via the plugin itself, so the CLI and the player can never disagree
# about what a valid tour is.
lua_validate() {
  nvim --headless --clean \
    --cmd "set rtp+=$ROOT" \
    -c "lua local ok,e = pcall(function()
          local t = require('walkthrough.tour').load('$1')
          for i,s in ipairs(t.steps) do
            if s.file and vim.fn.filereadable(vim.fn.fnamemodify(s.file,':p'))==0 then
              error(('step %d: file not found: %s'):format(i, s.file))
            end
          end
        end)
        if not ok then io.stderr:write(tostring(e),'\n') vim.cmd('cq') end" \
    -c 'qa!' 2>&1
}

cmd_validate() { [ -f "${1:-}" ] || die "no such tour: ${1:-<none>}"; lua_validate "$1" || exit 1; }
cmd_schema()   { cat "$ROOT/schema.json"; }
cmd_list()     { ls -1 "${1:-.tours}"/*.tour 2>/dev/null || { echo "no tours in ${1:-.tours}/" >&2; exit 1; }; }

cmd_open() {
  tour="${1:-}"; [ -f "$tour" ] || die "no such tour: $tour"
  lua_validate "$tour" >/dev/null || die "tour is not playable (run: walkthrough validate $tour)"
  load_backend

  files="$(nvim --headless --clean --cmd "set rtp+=$ROOT" \
    -c "lua local t=require('walkthrough.tour').load('$tour')
        local seen={} for _,s in ipairs(t.steps) do
          if s.abspath and not seen[s.abspath] then seen[s.abspath]=true io.write(s.abspath,'\n') end
        end" -c 'qa!' 2>/dev/null)"

  sock="${TMPDIR:-/tmp}/walkthrough-$$.sock"; rm -f "$sock"
  # shellcheck disable=SC2086
  handle="$(backend_open "$(wt_nvim_cmd "$sock" $files)")" || die "backend failed to open a surface"

  wt_wait_for_socket "$sock" 60 || { backend_close "$handle"; die "nvim never came up on $sock"; }

  nvim --server "$sock" --remote-expr \
    "luaeval('(function() vim.opt.runtimepath:append(_A[1]) vim.env.WALKTHROUGH_HANDLE=_A[3] vim.env.WALKTHROUGH_BACKEND=_A[4] require(\"walkthrough\").open(_A[2]) return 1 end)()', ['$ROOT','$(cd "$(dirname "$tour")" && pwd)/$(basename "$tour")','$handle','$BACKEND'])" \
    >/dev/null || { backend_close "$handle"; die "failed to render the tour"; }

  printf 'backend=%s\nhandle=%s\nsocket=%s\ntour=%s\n' "$BACKEND" "$handle" "$sock" "$tour" > "$STATE"
  echo "$handle"; echo "$sock"
}

with_state() {
  [ -f "$STATE" ] || die "no active walkthrough"
  # shellcheck disable=SC1090
  . "$STATE"
  nvim --server "$socket" --remote-expr '1' >/dev/null 2>&1 \
    || die "the walkthrough is gone (the user closed it)"
}

cmd_step() {
  with_state
  case "${1:-+1}" in
    +*|-*) nvim --server "$socket" --remote-expr \
             "luaeval('require(\"walkthrough\").step(_A)', ${1#+})" >/dev/null ;;
    *)     nvim --server "$socket" --remote-expr \
             "luaeval('require(\"walkthrough\").goto_step(_A)', $1)" >/dev/null ;;
  esac
}

cmd_reload() {
  with_state
  t="$(cd "$(dirname "${1:-$tour}")" && pwd)/$(basename "${1:-$tour}")"
  nvim --server "$socket" --remote-expr \
    "luaeval('require(\"walkthrough\").reload(_A)', '$t')" >/dev/null
}

cmd_close() {
  [ -f "$STATE" ] || return 0
  # shellcheck disable=SC1090
  . "$STATE"
  load_backend
  backend_close "$handle"
  rm -f "$STATE" "$socket"
}

usage() {
  cat <<'EOF'
walkthrough — play guided code tours in nvim

  walkthrough open <tour.tour>     open a tour (prints handle and socket)
  walkthrough step <+1|-1|N>       move along the narrative
  walkthrough reload [tour.tour]   re-render after files changed on disk
  walkthrough close                end the walkthrough
  walkthrough list [dir]           list tours (default: .tours/)
  walkthrough validate <tour>      exit 0 if the tour is playable
  walkthrough schema               print the JSON schema

Backend is auto-detected (cmux, tmux, else a plain window).
Override with WALKTHROUGH_BACKEND.
EOF
}

case "${1:-}" in
  open) shift; cmd_open "$@" ;;
  step) shift; cmd_step "$@" ;;
  reload) shift; cmd_reload "$@" ;;
  close) shift; cmd_close "$@" ;;
  list) shift; cmd_list "$@" ;;
  validate) shift; cmd_validate "$@" ;;
  schema) cmd_schema ;;
  _close_surface) shift; WALKTHROUGH_BACKEND="$1"; load_backend; backend_close "$2" ;;
  -h|--help|help|"") usage ;;
  *) die "unknown command: $1 (try --help)" ;;
esac
```

```bash
chmod +x bin/walkthrough
```

- [ ] **Step 5: Run to verify pass**

Run: `./tests/test_cli.sh`
Expected: `CLI TESTS PASSED`

- [ ] **Step 6: End-to-end, in whatever terminal you are in**

Run:
```bash
mkdir -p .tours && cp tests/fixtures/two_files.tour .tours/
./bin/walkthrough open .tours/two_files.tour
```
Expected: a new surface opens with the tour rendered. Then `./bin/walkthrough close`.

- [ ] **Step 7: Commit**

```bash
git add bin/walkthrough schema.json tests/test_cli.sh
git commit -m "feat: walkthrough CLI with backend auto-detection"
```

---

### Task 9: The Agent Skill

**Files:**
- Create: `skills/walkthrough/SKILL.md`
- Create: `install.sh`
- Create: `tests/test_skill_bundle.sh`

**Interfaces:**
- Consumes: `bin/walkthrough`, `backends/`, `lua/`.
- Produces: a self-contained skill *bundle* installable to `.agents/skills/` (repo) or `~/.agents/skills/` (user).

A skill is a directory, not a single file. Bundling the CLI, backends and Lua
alongside `SKILL.md` makes the skill a complete distribution — and because the
CLI launches nvim with `--cmd 'set rtp+=<bundle>'`, an agent user needs no
plugin-manager install at all.

- [ ] **Step 1: Write the skill**

Create `skills/walkthrough/SKILL.md`:

```markdown
---
name: walkthrough
description: Walk the user through code in their editor - a dedicated nvim surface with the cursor parked on each step and narration rendered beside the code. Use when the user asks to be walked through changes, asks you to explain code you just wrote, or wants to review a diff before opening a PR.
---

# Walkthrough

Author a `.tour` file and play it in nvim. Tours are CodeTour format, so they are
also readable by VS Code and by humans.

## When to use

The user asks to be walked through code, to have changes explained, or to review
before a PR. For a single question about one line, just answer it.

## Steps

1. **Collect what to walk through** — `git diff`, `git diff --staged`, or the
   diff against the base branch. If nothing changed, say so and stop.

2. **Decide the narrative order.** This is the real work and it is *not* file
   order. Find the entry point — the change everything else hangs off — then
   order the rest so each step makes sense given the ones before it. Crossing
   between files mid-narrative is expected.

3. **Write the tour** to `.tours/<name>.tour`:

   ```json
   {
     "title": "<what this change set does>",
     "steps": [
       {
         "title": "<short handle>",
         "file": "<path>",
         "line": <n>,
         "description": "<why this exists>",
         "selection": { "start": { "line": <n>, "character": 1 },
                        "end":   { "line": <m>, "character": 1 } }
       }
     ]
   }
   ```

   - `line` parks the cursor; `selection` is what gets highlighted.
   - Prefer `"pattern": "<regex>"` over `line` for steps in code that may shift —
     it re-locates itself instead of going stale.
   - `title` is the stable handle; position is restored by it across a reload.
   - `description` is prose about *why*. Never restate the code.

4. **Check your own output:** `walkthrough validate .tours/<name>.tour`
   Non-zero means a step does not resolve. Fix it before opening.

5. **Open it:** `walkthrough open .tours/<name>.tour`

6. **Narrate the shape in the terminal** — what changed and where to start. The
   user reads the detail in nvim; do not paste the descriptions back.

7. **Drive it in response to questions:** `walkthrough step +1`, `walkthrough step 3`.
   After editing a file, rewrite the tour and run `walkthrough reload`.

## Rules

- **Never claim the tour is open without checking** — `open` prints a handle and
  socket, and fails loudly otherwise.
- **If a command reports the walkthrough is gone**, the user closed it. Say so and
  continue in the terminal. Do not reopen it; they closed it deliberately.
- **Do not close the tour yourself.** The user's close key does it and returns
  their focus.
- Tours are committed artifacts. Ask before overwriting an existing `.tour` file
  that you did not write.
```

- [ ] **Step 2: Write the installer**

Create `install.sh`:

```bash
#!/usr/bin/env bash
# Install the walkthrough skill and CLI.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A skill is a directory. Bundle the CLI, backends and renderer alongside
# SKILL.md so installing the skill installs the whole tool - the CLI adds the
# bundle to nvim's runtimepath itself, so no plugin install is required.
DEST=~/.agents/skills/walkthrough
mkdir -p "$DEST"
for part in skills/walkthrough/SKILL.md bin backends lua schema.json; do
  ln -sfn "$REPO/$part" "$DEST/$(basename "$part")"
done
echo "skill  -> $DEST (bundling CLI, backends, renderer)"

# Older clients that only search their own directory.
for p in ~/.claude ~/.claude-personal ~/.claude-work ~/.claude-work-sub ~/.codex ~/.cursor; do
  [ -d "$p" ] || continue
  mkdir -p "$p/skills"
  ln -sfn ../../.agents/skills/walkthrough "$p/skills/walkthrough" 2>/dev/null || true
  echo "skill  -> $p/skills/walkthrough"
done

echo
echo "Done. Ask your agent to walk you through your changes."
echo
echo "To drive it yourself, add the CLI to PATH:"
echo "  export PATH=\"$REPO/bin:\$PATH\""
```

```bash
chmod +x install.sh
```

- [ ] **Step 3: Write the bundle test**

Create `tests/test_skill_bundle.sh` — asserts the bundle is self-contained, i.e.
that a fresh machine with only the skill directory can play a tour:

```bash
#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0

# Build the bundle the way install.sh publishes it
BUNDLE="$(mktemp -d)/walkthrough"
mkdir -p "$BUNDLE"
cp -R skills/walkthrough/SKILL.md bin backends lua schema.json "$BUNDLE"/

for want in SKILL.md bin/walkthrough backends/common.sh lua/walkthrough/init.lua schema.json; do
  [ -e "$BUNDLE/$want" ] || { echo "  FAIL: bundle missing $want"; fail=1; }
done

# the bundled CLI must work with no plugin installed anywhere
out=$("$BUNDLE/bin/walkthrough" validate tests/fixtures/two_files.tour 2>&1)
[ $? -eq 0 ] || { echo "  FAIL: bundled CLI cannot validate: $out"; fail=1; }

"$BUNDLE/bin/walkthrough" schema | grep -q '"steps"' \
  || { echo "  FAIL: bundled schema unreadable"; fail=1; }

rm -rf "$(dirname "$BUNDLE")"
[ "$fail" -eq 0 ] && echo "SKILL BUNDLE PASSED"
exit "$fail"
```

```bash
chmod +x tests/test_skill_bundle.sh
```

- [ ] **Step 4: Verify the skill is well-formed and installs**

Run:
```bash
head -4 skills/walkthrough/SKILL.md
./install.sh
test -f ~/.agents/skills/walkthrough/SKILL.md && echo "SKILL RESOLVES"
```
Expected: YAML frontmatter with `name:` and `description:`, then `SKILL RESOLVES`

- [ ] **Step 5: Run the bundle test**

Run: `./tests/test_skill_bundle.sh`
Expected: `SKILL BUNDLE PASSED`

- [ ] **Step 6: Commit**

```bash
git add skills/walkthrough/SKILL.md install.sh tests/test_skill_bundle.sh
git commit -m "feat: self-contained agent skill bundle and installer"
```

---

### Task 10: README, LICENSE, and CI

**Files:**
- Create: `README.md`
- Create: `LICENSE`
- Create: `.github/workflows/test.yml`

**Interfaces:**
- Consumes: everything.
- Produces: a publishable repository.

- [ ] **Step 1: Write the README**

Create `README.md`:

````markdown
# walkthrough.nvim

Guided, annotated walkthroughs of a codebase, played inside nvim. The cursor
parks on each step, narration renders beside the code, and the narrative crosses
files in whatever order actually explains the change — not top-to-bottom per file.

Tours are [CodeTour](https://github.com/microsoft/codetour) `.tour` files, so
they are portable to VS Code, hand-editable, and worth committing.

## Why

Reading a diff top to bottom is a poor way to understand a change. A walkthrough
puts the explanation next to the line that prompts the question, in the editor,
in an order someone chose deliberately.

Two ways to author one:

- **By hand** — a tour is onboarding documentation that lives in the repo and
  fails CI when it rots.
- **With an agent** — install the skill and ask to be walked through your changes.

Playing a tour requires no agent.

## Requirements

- nvim 0.10+ (vim is not supported — see below)
- [cmux](https://cmuxterm.com) — the only terminal backend in v0.1

Backends are pluggable and auto-detected; cmux is simply the one that ships
first. Adding another is one file defining `backend_open` and `backend_close`.

### Why not vim?

vim 9.1 has `+textprop`, so the rendering is achievable. The blocker is
`-clientserver`, which is how macOS ships it: without remote control the CLI
cannot drive the editor at all, so there is no stepping, no reload and no agent
integration. `+channel`/`+job` would allow a vim plugin to serve its own socket
instead — a real subproject, and one nobody has asked for yet.

## Install

The entry point is a coding agent, so installing the skill installs everything —
the bundle carries the CLI, the backends and the renderer, and adds itself to
nvim's runtimepath at launch. There is no plugin to install.

```bash
git clone https://github.com/user/walkthrough.nvim
cd walkthrough.nvim && ./install.sh
```

That links the bundle into `~/.agents/skills/`, which Claude Code, Codex, Cursor,
Copilot, Gemini CLI, Amp and others all read. Then ask your agent to walk you
through your changes.

To drive it yourself, put `bin/` on `PATH` and use the CLI directly.

## Use

```bash
walkthrough list                      # tours in .tours/
walkthrough open .tours/onboarding.tour
walkthrough validate .tours/*.tour    # in CI: fail when a tour rots
```

Once a walkthrough is open, in nvim:

| key | action |
|---|---|
| `]w` / `[w` | next / previous step |
| `<leader>an` / `<leader>ap` | next / previous step |
| `<leader>aq` | end the walkthrough |
| `:copen` | the whole tour as a list |

All keys are configurable:

```lua
require("walkthrough").setup({
  keys = { next = "]w", prev = "[w", close = "<leader>aq" },
})
```

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

Save it under `.tours/`, commit it, and it plays for anyone who clones the repo.

## Prior art

[CodeTour](https://github.com/microsoft/codetour) for VS Code, whose file format
this uses unmodified.

## License

MIT
````

- [ ] **Step 2: Add the license**

```bash
curl -s https://raw.githubusercontent.com/licenses/license-templates/master/templates/mit.txt \
  | sed "s/{{ year }}/2026/; s/{{ organization }}/$(git config user.name || echo 'Contributors')/" \
  > LICENSE
head -3 LICENSE
```

If `curl` is unavailable, write the standard MIT text with year `2026` manually.

- [ ] **Step 3: Add CI**

Create `.github/workflows/test.yml`:

```yaml
name: test
on: [push, pull_request]

jobs:
  lua:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        nvim: ['v0.10.4', 'v0.11.3', 'stable']
    steps:
      - uses: actions/checkout@v4
      - uses: rhysd/action-setup-vim@v1
        with:
          neovim: true
          version: ${{ matrix.nvim }}
      - name: headless suite
        run: ./tests/run.sh

  shell:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: rhysd/action-setup-vim@v1
        with: { neovim: true, version: stable }
      - name: shellcheck
        run: shellcheck bin/walkthrough backends/*.sh install.sh tests/*.sh
      - name: backend detection
        run: ./tests/test_backend_detect.sh
      - name: cli
        run: ./tests/test_cli.sh
```

- [ ] **Step 4: Verify CI config parses and shellcheck is clean**

Run:
```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/test.yml')); print('YAML OK')"
shellcheck bin/walkthrough backends/*.sh install.sh tests/*.sh && echo "SHELLCHECK CLEAN"
```
Expected: `YAML OK` then `SHELLCHECK CLEAN`. Fix any shellcheck findings before committing.

- [ ] **Step 5: Run everything**

Run:
```bash
./tests/run.sh && ./tests/test_backend_detect.sh && ./tests/test_cli.sh
```
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add README.md LICENSE .github/
git commit -m "docs: README, license, and CI across nvim 0.10-0.12"
```

---

### Task 11: Dogfood — a tour of this repository

**Files:**
- Create: `.tours/architecture.tour`

**Interfaces:**
- Consumes: the whole tool.
- Produces: the repository's own onboarding tour, and the honest test of the format.

If the format is unpleasant to hand-author, it is the wrong format — better to
find that out here than after publishing.

- [ ] **Step 1: Write a tour of this repo, by hand**

Create `.tours/architecture.tour` — five steps, hand-written, using `pattern` so
it survives refactors:

```json
{
  "title": "How walkthrough.nvim is put together",
  "description": "A tour of the tour player, written by hand.",
  "steps": [
    {
      "title": "the format",
      "file": "lua/walkthrough/tour.lua",
      "pattern": "^function M.validate",
      "description": "Everything starts with a CodeTour document. We validate shape only - whether a file exists is a question about the world at render time, not about the document."
    },
    {
      "title": "locating a step",
      "file": "lua/walkthrough/tour.lua",
      "pattern": "^function M.resolve",
      "description": "A step says where it lives with either a line number or a pattern. Patterns re-locate themselves after edits, which is why tours committed to a repo do not rot as fast as you would expect."
    },
    {
      "title": "narration",
      "file": "lua/walkthrough/render.lua",
      "pattern": "virt_lines_above",
      "description": "Notes render ABOVE the code, never at end-of-line. End-of-line virtual text is truncated by window width, and narration is sentences."
    },
    {
      "title": "the narrative is a quickfix list",
      "file": "lua/walkthrough/nav.lua",
      "pattern": "^function M.populate",
      "description": "vim already has a structure for an ordered set of locations across files. Using it means :cnext, :copen and every quickfix plugin work on tours for free."
    },
    {
      "title": "terminals are pluggable",
      "file": "backends/common.sh",
      "pattern": "wt_detect_backend",
      "description": "Nothing above this line knows which terminal it is in. Adding a backend is one file with two functions."
    }
  ]
}
```

- [ ] **Step 2: Validate and play it**

Run:
```bash
./bin/walkthrough validate .tours/architecture.tour && echo "VALID"
./bin/walkthrough open .tours/architecture.tour
```
Expected: `VALID`, then the tour opens on the first step. Walk it with `]w`.

- [ ] **Step 3: Note anything painful**

Write down anything awkward about hand-authoring — a missing field, an
unhelpful error, boilerplate. Fix what is cheap now; open issues for the rest.
This is the last checkpoint before the format is public and hard to change.

- [ ] **Step 4: Commit**

```bash
git add .tours/architecture.tour
git commit -m "docs: a hand-written tour of this repository"
```

---

## Verification

Done when all of these hold:

1. `./tests/run.sh` passes on nvim 0.10, 0.11 and 0.12 (CI proves this).
2. `walkthrough open .tours/architecture.tour` works under cmux.
3. Running outside cmux fails with a message naming the missing backend and how
   to add one — never a half-working fallback.
4. `walkthrough validate` exits non-zero for a tour whose file was deleted.
5. A tour authored here opens in VS Code's CodeTour extension.
6. The skill bundle plays a tour when copied somewhere else, with no plugin
   installed anywhere (`tests/test_skill_bundle.sh`).
7. The skill works in at least two harnesses without modification.
8. Closing the walkthrough returns focus to the tab the agent is running in.
9. The user's own nvim sessions are untouched after a walkthrough
   (`ls -l ~/.local/share/nvim/sessions/` — mtimes unchanged).
