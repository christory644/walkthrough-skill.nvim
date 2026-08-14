local T = dofile("tests/harness.lua")
T.load_plugin()
local wt = require("walkthrough")

-- Fixtures live in a private temp directory, not in `.tmp/` under the
-- checkout. Two concurrent runs of this suite -- two sessions working the
-- repository at once, which is now routine -- shared that one path: each
-- rewrote a.txt under the other mid-assertion, and whichever finished first
-- deleted it out from under the other. An aborted run also left it behind.
--
-- `fs_realpath`, not `os_tmpdir()` alone: a temp dir on macOS is reached
-- through /var -> /private/var, and a step matches a buffer by plain string
-- equality on `abspath` (nav.lua, render.apply). A fixture named through the
-- unresolved hop matches NO buffer, so the renderer draws nothing and every
-- assertion below passes by measuring an empty editor. tests/test_fuzz.lua
-- carries the same guard for the same reason.
local uv = vim.uv or vim.loop
local scratch = assert(uv.fs_mkdtemp((uv.os_tmpdir() or "/tmp") .. "/wtreload.XXXXXX"))
scratch = uv.fs_realpath(scratch) or scratch
local A = scratch .. "/a.txt"
local GONE = scratch .. "/no-such-file.txt"

-- The assertion that keeps the above true: a fixture path that has drifted back
-- inside the checkout is what this whole preamble exists to prevent, and
-- nothing else here would notice.
T.ok(scratch:sub(1, #vim.fn.getcwd()) ~= vim.fn.getcwd(),
  "fixtures live outside the checkout, so two concurrent runs cannot collide")

vim.fn.writefile({ "one", "two", "three", "four", "five" }, A)

local function tour_with(offset)
  return { title = "t", steps = {
    { title = "s1", file = A, line = 2 + offset, description = "one" },
    { title = "s2", file = A, line = 5 + offset, description = "two" },
  } }
end

-- The reload tour inserts an unplayable step ahead of s1/s2 so that "s2"
-- moves to a different index than it held before the reload. Restore-by-id
-- and restore-by-index now diverge: only a by-id implementation lands back
-- on s2 (index 2 -> index 3). The inserted step carries no `file`, so it is
-- unplayable and contributes no extmark, keeping the annotation count below
-- unaffected.
local function reload_tour(offset)
  return { title = "t", steps = {
    { title = "s0", description = "zero" },
    { title = "s1", file = A, line = 2 + offset, description = "one" },
    { title = "s2", file = A, line = 5 + offset, description = "two" },
  } }
end

wt.open(tour_with(0))
wt.step(1)
T.eq(wt.state().id, "s2", "on s2 before the edit")

-- a line is inserted at the top: every subsequent line number shifts
vim.fn.writefile({ "NEW", "one", "two", "three", "four", "five" }, A)
wt.reload(reload_tour(1))

T.eq(wt.state().id, "s2", "position restored BY ID, not index or line")
T.eq(vim.api.nvim_win_get_cursor(0)[1], 6, "cursor followed the shift")
T.eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], "NEW", "buffer reloaded from disk")

local render = require("walkthrough.render")
local virt = 0
for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, render.NS, 0, -1, { details = true })) do
  if m[4] and m[4].virt_lines then virt = virt + 1 end
end
T.eq(virt, 2, "no duplicated annotations after reload")

-- pattern steps survive the same edit with no new line numbers at all. Wipe
-- the buffer first so no residual cursor position from the earlier visit
-- can mask a broken `tour.resolve` pattern branch: a freshly loaded buffer
-- starts at line 1 unless `resolve` genuinely finds the pattern.
wt.close()
vim.cmd("bwipeout! " .. vim.fn.bufadd(A))
wt.open({ title = "t", steps = {
  { title = "p", file = A, pattern = "^five$", description = "by pattern" } } })
T.eq(vim.api.nvim_win_get_cursor(0)[1], 6, "pattern step found the shifted line unaided")

wt.close()

-- A reload either succeeds or leaves the reader exactly where they were.
--
-- It used to do neither. reload() flipped state.active to false, detached every
-- keymap and re-read every buffer BEFORE calling open() -- so an open() that
-- failed left a zombie: `active = false` while state() still described the OLD
-- tour, no keymaps (so the close key was gone), and a raw Lua traceback coming
-- back out through the CLI. Recovery needed a shell command the reader had no
-- way to know about.
wt.open({ title = "before reload", steps = {
  { title = "s1", file = A, line = 2, description = "one" },
  { title = "s2", file = A, line = 3, description = "two" },
} })
wt.goto_step(2)
local live_buf = vim.api.nvim_get_current_buf()

local function reload_refused(new_tour, label)
  local ok, err = pcall(wt.reload, new_tour)
  T.ok(not ok, label .. ": the reload fails")
  T.ok(tostring(err):match("reload failed") ~= nil,
    label .. ": ...saying so, in one line: " .. tostring(err))
  T.ok(tostring(err):match("stack traceback") == nil,
    label .. ": ...not as a raw Lua traceback")
  T.ok(wt.state().active, label .. ": ...the previous walkthrough is still ACTIVE")
  T.eq(wt.state().title, "before reload", label .. ": ...and is still the previous tour")
  T.eq(wt.state().id, "s2", label .. ": ...on the step the reader was on")
  local m = {}
  for _, k in ipairs(vim.api.nvim_buf_get_keymap(vim.api.nvim_get_current_buf(), "n")) do
    m[k.lhs] = true
  end
  T.ok(m["]w"], label .. ": ...with its keys still attached, so it can still be closed")
end

-- a tour that will not parse: caught before anything is dismantled
reload_refused({ steps = {} }, "a tour with no title")
-- a tour that parses but has nothing left to play: caught after, and undone
reload_refused({ title = "nothing plays", steps = {
  { title = "gone", file = GONE, line = 1, description = "d" } } },
  "a tour whose every step is unplayable")

T.ok(vim.api.nvim_buf_is_valid(live_buf), "the reader's buffer survived both refusals")

-- ...and a reload that CAN play still replaces the tour, from that same state.
wt.reload({ title = "after reload", steps = {
  { title = "s2", file = A, line = 4, description = "two" },
} })
T.eq(wt.state().title, "after reload", "a good reload still replaces the tour")
T.eq(wt.state().id, "s2", "...restoring position by id")

wt.close()
vim.fn.delete(scratch, "rf")
T.done()
