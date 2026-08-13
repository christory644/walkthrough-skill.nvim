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

-- Finding 1: pattern-only steps carry the quickfix `pattern` field, not lnum 1.
T.eq(qf[3].pattern, "^five$", "pattern-only step's quickfix entry carries its pattern")
T.eq(qf[3].lnum, 0, "pattern-only step's quickfix entry has no explicit lnum")
vim.cmd("cc 3")
T.eq(vim.api.nvim_win_get_cursor(0)[1], 5,
  ":cc on a pattern-only entry jumps to the matched line, not line 1")

local state = { tour = t, index = 1 }
T.eq(nav.goto_index(state, 2), 2, "moved to step 2")
T.eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"), "beta.txt", "switched file")
T.eq(nav.goto_index(state, 3), 3, "moved to step 3")
T.eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"), "alpha.txt", "switched back")
T.eq(vim.api.nvim_win_get_cursor(0)[1], 5, "pattern step parked on its match")
T.eq(nav.goto_index(state, 99), 3, "clamps at the end")
T.eq(nav.goto_index(state, -1), 1, "clamps at the start")

-- Finding 2: a non-playable step at the requested (or clamped) index must
-- not crash goto_index; it should land on the nearest playable step instead.
local mixed = tour.validate({
  title = "Mixed playability",
  steps = {
    { description = "no file: not playable" },
    { title = "middle", file = "tests/fixtures/alpha.txt", line = 1, description = "playable" },
    { description = "no file: not playable" },
  },
})
local mixed_state = { tour = mixed, index = 2 }
local landed = nav.goto_index(mixed_state, 1)
T.eq(landed, 2, "requested a non-playable step; landed on the nearest playable one")
T.ok(mixed.steps[landed].playable, "landed step is playable")

local none_playable = tour.validate({
  title = "No playable steps",
  steps = {
    { description = "no file 1" },
    { description = "no file 2" },
  },
})
local none_state = { tour = none_playable, index = 1 }
T.eq(nav.goto_index(none_state, 2), 1,
  "tour with no playable steps at all: returns current index unchanged, no crash")

-- A step whose location cannot be resolved AGAINST THE BUFFER is unplayable,
-- and must be treated exactly like one whose file is missing: demoted, added
-- to skipped, and stepped over. `tour.validate` cannot know this -- it sets
-- playable from field PRESENCE, and a pattern that no longer matches is still
-- a string -- so it used to be discovered nowhere: goto_index selected the
-- step, resolve returned nil, the cursor never moved, nothing rendered, and
-- nothing was reported. Resolvability is a question about buffer contents, so
-- it is answered where the buffer is loaded and nowhere earlier.
local stale = tour.validate({
  title = "Stale pattern",
  steps = {
    { title = "s1", file = "tests/fixtures/alpha.txt", line = 1, description = "d" },
    { title = "rotted", file = "tests/fixtures/alpha.txt", pattern = "^nope$", description = "d" },
    { title = "s3", file = "tests/fixtures/alpha.txt", line = 3, description = "d" },
  },
})
T.ok(stale.steps[2].playable, "field presence alone still calls a stale pattern playable")
local stale_state = { tour = stale, index = 1, skipped = {} }
T.eq(nav.goto_index(stale_state, 2), 3,
  "a step whose pattern matches nothing is stepped over, not silently parked on")
T.ok(not stale.steps[2].playable, "...the step is demoted to unplayable")
T.eq(stale_state.skipped, { "rotted" }, "...and named in the skipped list")
T.eq(vim.api.nvim_win_get_cursor(0)[1], 3, "landed on the next playable step's line")

-- The same for a pattern that is not a vim regex at all: resolve THROWS there,
-- which used to propagate out of goto_index and end the step.
local badre = tour.validate({
  title = "Bad regex",
  steps = {
    { title = "bad", file = "tests/fixtures/alpha.txt", pattern = "\\%(", description = "d" },
    { title = "good", file = "tests/fixtures/alpha.txt", line = 2, description = "d" },
  },
})
local badre_state = { tour = badre, index = 2, skipped = {} }
T.eq(nav.goto_index(badre_state, 1), 2, "an invalid pattern is skipped, not raised")
T.eq(badre_state.skipped, { "bad" }, "...and named in the skipped list")

-- populate() was the one step-field consumer with no pcall and no drop path,
-- which is what made it the place this bug class kept resurfacing. Everything
-- it puts in an item crosses into VIMSCRIPT inside setqflist -- not while the
-- item table is being built -- so the guard has to be around the call, and a
-- step it cannot list has to be demoted like a step that cannot be drawn.
--
-- The malformation is applied AFTER validate has passed the step, because that
-- is what the shape we have not thought of yet looks like from here: a step
-- believed playable, carrying a field vim will refuse.
local function unlistable(mutate, label)
  local ul = tour.validate({
    title = "Unlistable",
    steps = {
      { title = "ok1", file = "tests/fixtures/alpha.txt", line = 1, description = "d" },
      { title = "bad", file = "tests/fixtures/alpha.txt", line = 2, description = "d" },
      { title = "ok3", file = "tests/fixtures/alpha.txt", line = 3, description = "d" },
    },
  })
  mutate(ul.steps[2])
  T.ok(ul.steps[2].playable, label .. ": the step is still believed playable")
  local dropped = {}
  local ok_pop = pcall(nav.populate, ul,
    function(i, why) table.insert(dropped, { i = i, why = why }) end)
  T.ok(ok_pop, label .. ": populate does not raise")
  T.eq(#dropped, 1, label .. ": ...the step is handed to on_drop instead")
  T.eq(dropped[1] and dropped[1].i, 2, label .. ": ...naming which step")
  T.ok(dropped[1] and dropped[1].why:match("cannot be listed") ~= nil,
    label .. ": ...and saying why")
  T.eq(#vim.fn.getqflist(), 2, label .. ": ...while the rest of the tour is still listed")
  T.eq(vim.fn.getqflist({ title = 0 }).title, "walkthrough: Unlistable",
    label .. ": ...under the walkthrough's own title, so a drop can still be marked in it")
end

-- E976: vimscript has no string type that can hold a NUL.
unlistable(function(s) s.title = "n" .. string.char(0) end, "a NUL in the entry text")
unlistable(function(s) s.abspath = s.abspath .. string.char(0) end, "a NUL in the filename")
unlistable(function(s) s.line = nil s.pattern = "a" .. string.char(0) end,
  "a NUL in the quickfix pattern")
-- ...and a shape nobody has thought about at all.
unlistable(function(s) s.abspath = { 1 } end, "a filename that is an object")

-- N-1 exactly: an integral double too big for int64. `% 1 == 0` holds for it,
-- so the old guard admitted it, and setqflist raised E805 and took the whole
-- open() down. It is now stopped TWICE over -- tour.validate makes the step
-- unplayable, so it is never listed at all, and the lnum guard here would omit
-- the field even if it were. This asserts the second one, on a step forced
-- playable, because a guard that is only reachable through the first is a guard
-- nobody would notice losing.
local big = tour.validate({ title = "Big", steps = {
  { title = "big", file = "tests/fixtures/alpha.txt", line = 1, description = "d" },
} })
big.steps[1].line = 1e30
local big_dropped = {}
T.ok(pcall(nav.populate, big, function(i) table.insert(big_dropped, i) end),
  "a line past int64 does not raise out of populate")
T.eq(big_dropped, {}, "...the entry is listed rather than dropped")
T.eq(vim.fn.getqflist()[1].lnum, 0,
  "...without an lnum vim would have to convert as a Float")

-- populate() takes no on_drop when the caller has no state to record into
-- (test_nav's own calls above, and any embedder's) and must not raise for the
-- want of one.
local nohook = tour.validate({ title = "No hook", steps = {
  { title = "bad", file = "tests/fixtures/alpha.txt", line = 1, description = "d" },
} })
nohook.steps[1].line = 1e30
T.ok(pcall(nav.populate, nohook), "populate with no drop hook still does not raise")

-- Finding 3: buffer lookup must be exact-path, not a substring/pattern match
-- that can silently pick a decoy buffer (e.g. "alpha.txt.bak").
local decoy_name = t.steps[2].abspath .. ".bak"
local decoy_buf = vim.fn.bufadd(decoy_name)
vim.fn.bufload(decoy_buf)
local decoy_state = { tour = t, index = 1 }
nav.goto_index(decoy_state, 2)
T.eq(vim.api.nvim_buf_get_name(0), t.steps[2].abspath,
  "exact-path lookup lands on the real file, not a decoy with the path as a substring")
T.ok(vim.api.nvim_get_current_buf() ~= decoy_buf, "did not select the decoy buffer")

T.done()
