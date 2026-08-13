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

-- setup() while a walkthrough is active must not orphan the mapping that was
-- actually bound; close() must detach what attach() really attached, not
-- whatever config.keys happens to hold at close time.
wt.open("tests/fixtures/two_files.tour")
local orphan_buf = vim.api.nvim_get_current_buf()
wt.setup({ keys = { next = "<Tab>" } })
wt.close()
local orphan_maps = {}
for _, m in ipairs(vim.api.nvim_buf_get_keymap(orphan_buf, "n")) do orphan_maps[m.lhs] = true end
T.ok(not orphan_maps["]w"], "close() removes the key that was really bound, even after setup() changed config")

-- configurable keys; nothing is bound globally
wt.setup({ keys = { next = "<Tab>", prev = "<S-Tab>" } })
wt.open("tests/fixtures/two_files.tour")
maps = {}
for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do maps[m.lhs] = true end
T.ok(maps["<Tab>"], "custom next key bound")
wt.close()

-- reload must not leak keymaps onto a buffer that drops out of the tour
wt.setup({ keys = { next = "]w", prev = "[w", close = "<leader>aq", next_cmd = "<leader>an", prev_cmd = "<leader>ap" } })
wt.open("tests/fixtures/two_files.tour")
wt.goto_step(2)
local dropped_buf = vim.api.nvim_get_current_buf()
wt.reload({
  title = "Two-file tour",
  description = "alpha only, for reload test",
  steps = {
    { title = "first", file = "tests/fixtures/alpha.txt", line = 2, description = "First note." },
  },
})
wt.close()
local dropped_maps = {}
for _, m in ipairs(vim.api.nvim_buf_get_keymap(dropped_buf, "n")) do dropped_maps[m.lhs] = true end
T.ok(not dropped_maps["]w"], "reload does not leak keymaps onto a buffer dropped from the tour")

-- a bad tour must not leave a half-open walkthrough
T.err(function() wt.open({ steps = {} }) end, "title", "invalid tour rejected")
T.ok(not wt.state().active, "still inactive")

-- A step whose pattern no longer matches must reach state().skipped, so the
-- report the CLI and the plugin both make is telling the truth. It cannot be
-- known before the buffer is loaded, so it appears the moment we navigate
-- there -- and at open() already, when it is the step open() lands on.
wt.setup({ keys = vim.deepcopy(require("walkthrough.keys").defaults) })
wt.open({
  title = "Stale in the middle",
  steps = {
    { title = "ok1", file = "tests/fixtures/alpha.txt", line = 1, description = "d" },
    { title = "rotted", file = "tests/fixtures/alpha.txt", pattern = "^nope$", description = "d" },
    { title = "ok3", file = "tests/fixtures/alpha.txt", line = 3, description = "d" },
  },
})
T.ok(wt.state().active, "a tour with one stale pattern still opens")
T.eq(wt.state().skipped, {}, "nothing is skipped before we go anywhere near the stale step")

-- The quickfix list is the other view of the same narrative, and it was built
-- before the stale step was known to be unplayable. Its entry must not go on
-- claiming to be playable: `:cc 2` onto a dropped step raises nothing, finds
-- no match for the pattern, lands the cursor on line 1 and still announces
-- "(2 of 3)" -- the reader is told they are on step 2 while sitting on step 1.
local function qf_text(n) return (vim.fn.getqflist()[n] or {}).text or "" end
T.ok(not qf_text(2):find("DROPPED", 1, true),
  "the quickfix entry is not marked while the step is still believed playable")
vim.cmd("cc 1")
T.eq(vim.fn.getqflist({ idx = 0 }).idx, 1, "the reader is at entry 1 of the list")

wt.goto_step(2)
T.eq(wt.state().skipped, { "rotted" }, "the stale step is named in skipped once reached")
T.eq(wt.state().index, 3, "...and the reader is moved on to a step that plays")
T.ok(qf_text(2):find("DROPPED", 1, true) ~= nil,
  "...and its quickfix entry says it was dropped instead of lying about being step 2")
T.ok(qf_text(2):find("[2/3] rotted", 1, true) ~= nil,
  "...retitled, keeping what the entry already said")
T.eq(#vim.fn.getqflist(), 3, "...in place: the list is not repopulated")
T.eq(vim.fn.getqflist({ idx = 0 }).idx, 1, "...and the reader's position in it is untouched")
T.ok(not qf_text(1):find("DROPPED", 1, true), "...only the dropped entry is marked")
wt.close()

-- ...and at open() when the stale step is the one open() would land on.
wt.open({
  title = "Stale first",
  steps = {
    { title = "rotted", file = "tests/fixtures/alpha.txt", pattern = "^nope$", description = "d" },
    { title = "ok2", file = "tests/fixtures/alpha.txt", line = 4, description = "d" },
  },
})
T.eq(wt.state().skipped, { "rotted" }, "a stale FIRST step is reported by open() itself")
T.eq(wt.state().index, 2, "open() starts on the first step that actually plays")
T.eq(vim.api.nvim_win_get_cursor(0)[1], 4, "...parked on its line, not left on line 1")
wt.close()

-- A pattern that is not a vim regex AT ALL is a different failure from one
-- that merely no longer matches: vim.regex RAISES on it. And the raise does
-- not arrive anywhere nav can catch it. render.apply draws EVERY step that
-- lives in the buffer being entered, and it runs from the BufEnter autocmd
-- open() installs -- so a step the reader never asked for throws while a
-- perfectly good step is being displayed, straight through the autocmd, past
-- goto_index's pcall (which only ever guards the step it is navigating TO)
-- and out of open(). Measured before the fix: `walkthrough open` printed the
-- right drop banner and then died with `E5108 ... couldn't parse regex:
-- Vim:E53`, so a tour with two good steps could not be opened at all.
--
-- The invalid pattern is therefore on a step this test never navigates to and
-- open() never lands on. NOTHING but the render pass reaches it, which is what
-- makes this exercise the path the direct goto_index test in test_nav.lua
-- cannot: there, no autocmd is installed and render.apply is never involved.
local opened, oerr = pcall(wt.open, {
  title = "Invalid regex in the middle",
  steps = {
    { title = "ok1", file = "tests/fixtures/alpha.txt", line = 1, description = "d" },
    { title = "badre", file = "tests/fixtures/alpha.txt", pattern = "\\%(", description = "d" },
    { title = "ok3", file = "tests/fixtures/alpha.txt", line = 3, description = "d" },
  },
})
T.ok(opened, "a step whose pattern will not compile does not abort open(): " .. tostring(oerr))
T.ok(wt.state().active, "...the tour is open")
T.eq(wt.state().skipped, { "badre" }, "...and the bad step is demoted and named, not swallowed")
T.eq(wt.state().index, 1, "...the reader is on the step open() meant to land on")
T.eq(vim.api.nvim_win_get_cursor(0)[1], 1, "...parked on its line")
-- The autocmd is the surface that used to leak the throw: fire it directly.
T.ok(pcall(vim.api.nvim_exec_autocmds, "BufEnter", { buffer = vim.api.nvim_get_current_buf() }),
  "...and the BufEnter render pass itself does not raise")
wt.goto_step(3)
T.eq(wt.state().index, 3, "...while the rest of the tour still plays")
wt.close()

-- ...and the same for a step that resolves perfectly well but cannot be DRAWN.
--
-- `title`, `selection` and `line` are hand-written JSON that reaches nvim's API
-- unchecked: schema.json declares them, nothing enforces it. A title that is an
-- object cannot be concatenated and a selection whose ends carry no `line`
-- makes math.max(nil, 1) raise -- and both raises leave through the same
-- BufEnter autocmd the uncompilable pattern used to, taking the whole of open()
-- with them, on a tour `walkthrough validate` had just exited 0 on.
--
-- Each malformed step below sits in the MIDDLE of its tour, on a step nothing
-- ever navigates to: the render pass is the only thing that reaches it, which
-- is what makes these exercise the real path (open() with its autocmd
-- installed) rather than a direct call to render.apply. Its id is "2" because
-- step_id will not take a non-string title as a handle.
local function opens_dropping(title, bad_step, want_skipped, label)
  local ok_open, oerr = pcall(wt.open, {
    title = title,
    steps = {
      { title = "ok1", file = "tests/fixtures/alpha.txt", line = 1, description = "d" },
      bad_step,
      { title = "ok3", file = "tests/fixtures/alpha.txt", line = 3, description = "d" },
    },
  })
  T.ok(ok_open, label .. ": does not abort open(): " .. tostring(oerr))
  T.ok(wt.state().active, label .. ": ...the tour is open")
  T.eq(wt.state().skipped, want_skipped, label .. ": ...and the bad step is named, not swallowed")
  T.eq(wt.state().index, 1, label .. ": ...the reader is on the step open() meant to land on")
  T.ok(pcall(vim.api.nvim_exec_autocmds, "BufEnter", { buffer = vim.api.nvim_get_current_buf() }),
    label .. ": ...and the BufEnter render pass itself does not raise")
  wt.goto_step(3)
  T.eq(wt.state().index, 3, label .. ": ...while the rest of the tour still plays")
  wt.close()
end

opens_dropping("Object title", { title = { x = 1 },
  file = "tests/fixtures/alpha.txt", line = 2, description = "d" },
  { "2" }, "a title that is an object")

-- A malformed `selection`, on the other hand, must cost the step NOTHING.
--
-- It is decoration -- it moves a highlight, and that is all -- while the
-- narration and the cursor park are the whole value of a step. This used to
-- take the step, and inconsistently: `"selection": 5` fell back to the step's
-- own line and played, while `{"start":{"character":1}}` raised inside math.max
-- and lost the step, so the author whose selection looked MORE like a real one
-- was punished harder. Both shapes now fall back to the step's own line.
--
-- The selection is only drawn for the step the reader is ON, so the malformed
-- one is the step open() lands on: the case that used to demote the very step
-- being displayed.
local sel_ok, sel_err = pcall(wt.open, {
  title = "Selection with no line",
  steps = {
    { title = "sel", file = "tests/fixtures/alpha.txt", line = 2, description = "d",
      selection = { start = { character = 1 }, ["end"] = { character = 4 } } },
    { title = "ok2", file = "tests/fixtures/alpha.txt", line = 4, description = "d" },
  },
})
T.ok(sel_ok, "a selection whose ends carry no line does not abort open(): " .. tostring(sel_err))
T.ok(wt.state().active, "...the tour is open")
T.eq(wt.state().skipped, {}, "...and costs the step nothing: nothing is dropped")
T.eq(wt.state().index, 1, "...the reader is on the step that carries it")
T.eq(vim.api.nvim_win_get_cursor(0)[1], 2, "...parked on its own line")
T.eq(wt.state().id, "sel", "...playing the step, not stepping over it")
wt.close()

-- A `line` that is not a position in the file is rot, not a rounding error. It
-- used to be CLAMPED: "line": 9999 in a five-line file parked the reader on
-- line 5 with the narration anchored there, state().skipped empty and no
-- message -- and `line`: 2.7 raised E805 out of the render pass, out of the
-- quickfix list, and out of the cursor move. Both now resolve to nothing and
-- travel the demote-and-report path a stale pattern travels.
--
-- `eager` says WHERE it is caught, and the difference is the whole shape of
-- this fix. Whether a line is inside its file is a question about the file, so
-- it can only be answered when that buffer is loaded -- lazily, on arrival.
-- Whether a line is a line AT ALL is a question about the document, so it is
-- answered once, in tour.validate, before any consumer touches it: the step is
-- dropped by open() itself and `validate` refuses the tour for the same reason
-- in the same words.
local function line_rot(bad_line, eager, label)
  wt.open({
    title = "Line rot",
    steps = {
      { title = "ok1", file = "tests/fixtures/alpha.txt", line = 1, description = "d" },
      { title = "rotted", file = "tests/fixtures/alpha.txt", line = bad_line, description = "d" },
      { title = "ok3", file = "tests/fixtures/alpha.txt", line = 3, description = "d" },
    },
  })
  if eager then
    T.eq(wt.state().skipped, { "rotted" },
      label .. ": open() itself names it, without loading a thing")
  else
    T.eq(wt.state().skipped, {}, label .. ": nothing is skipped before the reader goes near it")
  end
  T.eq(wt.state().index, 1, label .. ": ...the tour opens on its first good step either way")
  wt.goto_step(2)
  T.eq(wt.state().skipped, { "rotted" }, label .. ": ...it is named in skipped once reached")
  T.eq(wt.state().index, 3, label .. ": ...and the reader is moved on to a step that plays")
  T.eq(vim.api.nvim_win_get_cursor(0)[1], 3, label .. ": ...parked on that step's line")
  wt.close()
end

line_rot(9999, false, "a line past the end of the file")
line_rot(2.7, true, "a line that is not a whole number")
-- The shape that killed the whole `open`: an integral double too big for
-- int64. `% 1 == 0` holds for it, so every integrality check in the codebase
-- passed it straight through to `setqflist`, which raised E805 and took the
-- tour down with a traceback. 1e18 is BELOW that cliff and behaved perfectly,
-- which is how two fuzz runs came back clean.
line_rot(1e19, true, "a line beyond int64")
line_rot(1e308, true, "a line at the top of the double range")
line_rot(math.huge, true, "an infinite line")
line_rot(-1e30, true, "a hugely negative line")
line_rot(0, true, "line zero")
-- ...and a NUL in a drawable string, which `validate` used to exit 0 on while
-- `open` died with E976 the moment the quickfix list was built.
local NUL = string.char(0)
local function field_rot(field, value, label)
  local bad = { title = "rotted", file = "tests/fixtures/alpha.txt", line = 2, description = "d" }
  bad[field] = value
  local id = (field == "title") and "2" or "rotted"
  local ok_open, oerr = pcall(wt.open, {
    title = "Field rot",
    steps = {
      { title = "ok1", file = "tests/fixtures/alpha.txt", line = 1, description = "d" },
      bad,
      { title = "ok3", file = "tests/fixtures/alpha.txt", line = 3, description = "d" },
    },
  })
  T.ok(ok_open, label .. ": does not abort open(): " .. tostring(oerr))
  T.eq(wt.state().skipped, { id }, label .. ": ...the step is dropped and named")
  T.eq(wt.state().index, 1, label .. ": ...the reader is on the first step that plays")
  T.ok(pcall(vim.api.nvim_exec_autocmds, "BufEnter", { buffer = vim.api.nvim_get_current_buf() }),
    label .. ": ...and the render pass does not raise either")
  T.ok(pcall(vim.cmd, "cc 2"), label .. ": ...nor does jumping through the quickfix list")
  wt.goto_step(3)
  T.eq(wt.state().index, 3, label .. ": ...while the rest of the tour still plays")
  wt.close()
end

field_rot("title", "n" .. NUL .. "t", "a NUL in title")
field_rot("description", "d" .. NUL .. "x", "a NUL in description")
field_rot("file", "tests/fixtures/alpha.txt" .. NUL, "a NUL in file")
field_rot("pattern", "al" .. NUL, "a NUL in pattern")
field_rot("title", { x = 1 }, "a title that is an object")
field_rot("file", 7, "a file that is a number")

-- ...and the same, one layer down, for a field `tour.validate` does not know
-- about YET. That is not a hypothetical: it is the description of all five
-- previous layers of this bug, each found by someone who believed the check
-- above them was complete. So the check is disabled here and a shape it would
-- otherwise catch is fed through the real open(), which reaches nav.populate
-- with a step it believes is playable -- the exact position N-1 and N-2 held.
-- open() must still drop that step, name it, and play the rest.
local tour_mod = require("walkthrough.tour")
local real_step_problem = tour_mod.step_problem
tour_mod.step_problem = function() return nil end
local blind_ok, blind_err = pcall(wt.open, {
  title = "A shape validate does not know about",
  steps = {
    { title = "ok1", file = "tests/fixtures/alpha.txt", line = 1, description = "d" },
    { title = "unlistable", file = "tests/fixtures/alpha.txt", line = 2,
      description = "d" .. string.char(0) .. "x" },
    { title = "ok3", file = "tests/fixtures/alpha.txt", line = 3, description = "d" },
  },
})
tour_mod.step_problem = real_step_problem
T.ok(blind_ok, "a field validate let through does not abort open(): " .. tostring(blind_err))
T.ok(wt.state().active, "...the tour is open")
T.eq(wt.state().skipped, { "unlistable" }, "...the step is dropped by populate and named")
T.eq(wt.state().index, 1, "...the reader is on the first step that plays")
T.eq(#vim.fn.getqflist(), 2, "...the quickfix list holds the steps that could be listed")
T.ok(vim.fn.getqflist({ title = 0 }).title:sub(1, 13) == "walkthrough: ",
  "...under the walkthrough's own title")
wt.goto_step(3)
T.eq(wt.state().index, 3, "...and the rest of the tour still plays")
wt.close()

-- A tour where NOTHING resolves is refused, exactly like one whose files are
-- all missing -- and leaves no half-open walkthrough behind.
T.err(function()
  wt.open({
    title = "All stale",
    steps = {
      { title = "a", file = "tests/fixtures/alpha.txt", pattern = "^nope$", description = "d" },
      { title = "b", file = "tests/fixtures/alpha.txt", pattern = "^also nope$", description = "d" },
    },
  })
end, "no playable steps", "a tour with no resolvable step is refused")
T.ok(not wt.state().active, "...and leaves no half-open walkthrough")

-- Stepping a walkthrough that is not open must FAIL. It used to return quietly,
-- which reaches the CLI as exit 0 -- and SKILL.md tells the agent driving this
-- to trust that status, so the agent narrated a step the reader was never
-- taken to.
T.ok(not wt.state().active, "no walkthrough is open")
T.err(function() wt.step(1) end, "nothing to step", "stepping a dead walkthrough is an error")
T.err(function() wt.goto_step(2) end, "nothing to step", "...and so is jumping to a step")

-- `state.active` means "this walkthrough is fully installed", and it has to be
-- true only when it is. It was set BEFORE the quickfix list, the autocmd and the
-- first jump, which was harmless only while none of those could fail -- and a
-- step that cannot be drawn now demotes itself mid-jump. Anything that does
-- fail in there must leave the editor as it found it, not a walkthrough that
-- answers `active` and has no keys to close it. The jump is made to fail here
-- directly, because a fix that depends on nothing ever failing is not a fix.
local nav = require("walkthrough.nav")
local real_goto_index = nav.goto_index
nav.goto_index = function() error("boom: the first jump failed") end
local half_ok = pcall(wt.open, {
  title = "half open",
  steps = { { title = "s1", file = "tests/fixtures/alpha.txt", line = 1, description = "d" } },
})
nav.goto_index = real_goto_index
T.ok(not half_ok, "a failure during open()'s first jump fails open()")
T.ok(not wt.state().active, "...and does not leave a walkthrough reporting itself active")
T.eq(wt.state().count, 0, "...nor a tour behind in state()")
T.eq(wt.state().title, nil, "...nor its title")
T.eq(#vim.fn.getqflist(), 0, "...and the quickfix list it had populated is cleared")
local half_maps = {}
for _, m in ipairs(vim.api.nvim_buf_get_keymap(vim.api.nvim_get_current_buf(), "n")) do
  half_maps[m.lhs] = true
end
T.ok(not half_maps["]w"], "...and no buffer is left holding the walkthrough's keys")

T.done()
