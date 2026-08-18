-- Dialog properties that need no transport: what an answer is allowed to be,
-- and what the editor looks like while one is open.
local T = dofile("tests/harness.lua")
T.load_plugin()

local wt = require("walkthrough")
local dialog = require("walkthrough.dialog")
local channel = require("walkthrough.channel")

local SENTINEL = vim.fn.tempname() .. "-pwned"

-- P4 — an answer is DATA.
--
-- Identical-if-broken: any test with an innocuous answer passes on an
-- implementation that interpolates its argument into a vimscript or Lua
-- expression. So the payload has to be one that would LEAVE EVIDENCE if it were
-- executed — and the assertion is on the evidence as well as on the text.
--
-- This is not hypothetical in this repository: `walkthrough step` used to
-- interpolate its argument, so `walkthrough step '<any vimscript>'` executed in
-- the tour's nvim.
local HOSTILE = table.concat({
  [[it's "quoted" and ]] .. "\\" .. [[escaped]],
  [[<C-\><C-n>:call writefile(['x'], ']] .. SENTINEL .. [['])<CR>]],
  [[") vim.fn.writefile({"x"}, "]] .. SENTINEL .. [[") --]],
  "trailing\tcontrol\1chars\0and a NUL",
}, "\n")

wt.open("tests/fixtures/two_files.tour")

local lines = dialog.sanitise(HOSTILE)
T.ok(not table.concat(lines, "\n"):find("\0", 1, true), "sanitise removes NUL")
T.ok(not table.concat(lines, "\n"):find("\1", 1, true), "sanitise removes control chars")
T.ok(table.concat(lines, "\n"):find([[it's "quoted"]], 1, true) ~= nil,
  "sanitise keeps quotes verbatim")
T.ok(#lines == 4, "sanitise splits on newlines, one buffer line each")

T.ok(vim.fn.filereadable(SENTINEL) == 0, "no sentinel: nothing was executed")

-- An unknown nonce is refused rather than appended to whatever is open.
T.err(function() wt._answer("nonce-that-was-never-issued", "hello") end,
  "no question", "an answer to an unissued nonce is refused")

-- Carried Minor from Task 6: a lone \r (not followed by \n) falls in the gap
-- between the \11-\12 and \14-\31 ranges in the strip class and reaches a
-- buffer line as a raw CR byte, contradicting sanitise's own doc comment.
local cr_lines = dialog.sanitise("before\rafter")
T.ok(not table.concat(cr_lines, "\n"):find("\r", 1, true),
  "sanitise strips a lone CR (not just \\r\\n)")

wt.close()

-- P8 — code buffers stay nomodifiable while the dialog is writable, asserted on
-- the SAME TAB at the SAME MOMENT.
--
-- Identical-if-broken: asserting only that the dialog is writable passes on an
-- implementation that made everything writable.
wt.open("tests/fixtures/two_files.tour")
local code_buf = vim.api.nvim_get_current_buf()
local code_tab = vim.api.nvim_get_current_tabpage()
-- Captured by identity, not by window NUMBER: a vertical split with the
-- default 'nosplitright' opens its new window to the LEFT, which renumbers it
-- to window 1 and would make `vim.fn.win_getid(1)` alias the dialog window
-- itself post-mutation -- comparing a window's width to its own width always
-- passes, which defeats the revert-check this assertion exists to satisfy.
local code_win = vim.api.nvim_get_current_win()

dialog.open({ fifo = nil, tour = "/tmp/t.tour", step_id = "the retry", index = 1, count = 2 })

T.ok(dialog.is_open(), "the dialog is open")
T.eq(vim.api.nvim_win_get_tabpage(dialog.winid()), code_tab,
  "the dialog is in the walkthrough's own tab, not a new one")
T.eq(vim.bo[code_buf].modifiable, false, "the code buffer is still nomodifiable")
T.eq(vim.bo[dialog.bufnr()].buftype, "prompt", "the dialog is a prompt buffer")
T.eq(vim.bo[dialog.bufnr()].swapfile, false, "the dialog has no swapfile")

-- Layout A: full width, at the bottom. A vertical split would halve the code
-- window, and narration is drawn INSIDE it.
T.eq(vim.api.nvim_win_get_width(dialog.winid()),
  vim.api.nvim_win_get_width(code_win),
  "the dialog is full width, so the code keeps its columns")

-- Never written to disk: the transcript must not become a file an agent later
-- reads back as instructions.
vim.api.nvim_buf_call(dialog.bufnr(), function()
  local ok = pcall(vim.cmd, "write " .. vim.fn.tempname())
  T.ok(not ok, "the dialog refuses to be written to disk")
end)

dialog.append({ "agent: because a spawned process has no supervisor." }, "Normal")
local body = vim.api.nvim_buf_get_lines(dialog.bufnr(), 0, -1, false)
T.ok(vim.iter(body):any(function(l) return l:find("no supervisor", 1, true) end),
  "append puts the answer in the transcript")

-- Important, review round 1: M.submit's success echo used to concatenate an
-- UNSANITISED question straight into one nvim_buf_set_lines element ("you: "
-- .. text). The control-char guard in M.submit deliberately lets \n and \t
-- through (a question is allowed to be multi-line), and nvim_buf_set_lines
-- refuses any element that embeds a newline -- so a multi-line question threw
-- 'replacement string' item contains newlines, AFTER channel.send had already
-- succeeded and the nonce was already recorded in M.issued. Not reachable by
-- typing at the prompt (a buffer line cannot contain \n) but M.submit is a
-- public interface, and Task 9's auto-send calls it programmatically.
--
-- channel.send is stubbed here rather than routed through a real FIFO: the
-- defect and its fix live entirely in the echo path, not the transport, and a
-- stub keeps this assertion synchronous and process-free.
local real_send = channel.send
channel.send = function(_path, _payload) return true end
local ok, sent, nonce = pcall(function() return dialog.submit("line one\nline two") end)
channel.send = real_send

T.ok(ok, "submit with an embedded newline does not raise: " .. tostring(sent))
T.eq(sent, true, "...and still reports success")
T.ok(type(nonce) == "string" and #nonce > 0, "...with a nonce")

local echoed = table.concat(vim.api.nvim_buf_get_lines(dialog.bufnr(), 0, -1, false), "\n")
T.ok(echoed:find("you: line one", 1, true) ~= nil,
  "...the echoed first line keeps the you: prefix")
T.ok(echoed:find("\nline two", 1, true) ~= nil,
  "...and the second line survives as its own transcript line, text intact")

dialog.close()
T.ok(not dialog.is_open(), "close takes the dialog away")
T.eq(vim.api.nvim_get_current_tabpage(), code_tab, "and leaves the reader in the tab")
wt.close()

-- The keybinding is buffer-local, configurable, and disabled by "".
--
-- nvim_*_get_keymap's lhs is already resolved through 'mapleader' at
-- registration time (measured directly: with mapleader unset, a mapping set
-- via "<leader>aa" is stored and reported back as the literal two bytes
-- "\aa", never the eight-byte text "<Leader>aa"). So `has` below resolves the
-- same way, rather than comparing against the unresolved "<Leader>aa" text,
-- which would never match any real keymap regardless of correctness.
local leader_aa = (vim.g.mapleader or "\\") .. "aa"
wt.open("tests/fixtures/two_files.tour")
local buf = vim.api.nvim_get_current_buf()
local maps = vim.api.nvim_buf_get_keymap(buf, "n")
local has = function(lhs)
  return vim.iter(maps):any(function(m) return m.lhs == lhs end)
end
T.ok(has(leader_aa), "<leader>aa is mapped in a tour buffer")
wt.close()

require("walkthrough").setup({ keys = { ask = "" } })
wt.open("tests/fixtures/two_files.tour")
maps = vim.api.nvim_buf_get_keymap(vim.api.nvim_get_current_buf(), "n")
T.ok(not has(leader_aa), 'keys.ask = "" disables it')
wt.close()
require("walkthrough").setup({ keys = { ask = "<leader>aa" } })

-- Nothing is bound globally.
T.ok(not vim.iter(vim.api.nvim_get_keymap("n")):any(function(m)
  return m.lhs == leader_aa
end), "nothing is bound globally")

-- teardown takes the dialog with it. The dialog buffer is deliberately NOT in
-- state.touched -- see docs/superpowers/plans § Divergences -- so this is what
-- proves it is not leaked anyway.
wt.open("tests/fixtures/two_files.tour")
wt.ask()
T.ok(dialog.is_open(), "ask opens the dialog")
local dbuf = dialog.bufnr()
wt.close()
T.ok(not dialog.is_open(), "close takes the dialog with it")
T.eq(vim.api.nvim_buf_is_valid(dbuf), false, "and wipes its buffer")

-- ...and a reload KEEPS it, because "a tour rewritten by an answer goes through
-- the existing reload" -- destroying the dialog there would destroy the answer
-- that caused the rewrite.
wt.open("tests/fixtures/two_files.tour")
wt.ask()
dialog.append({ "agent: an answer worth keeping" }, nil)
wt.reload("tests/fixtures/two_files.tour")
T.ok(dialog.is_open(), "a reload keeps the dialog open")
T.ok(vim.iter(vim.api.nvim_buf_get_lines(dialog.bufnr(), 0, -1, false)):any(function(l)
  return l:find("worth keeping", 1, true)
end), "and keeps the transcript")
wt.close()

-- Review round 1, Critical: state.path (and so ctx.tour) went to "" after
-- EVERY reload, permanently, until the walkthrough was closed and reopened.
-- M.reload calls M.open with `t`, the already-parsed/validated TABLE, never
-- with path_or_tour itself -- so M.open's own `type(...) == "string"` gate
-- can never see a string during a reload. The question still crossed the
-- FIFO, it just stopped naming which tour it was about.
--
-- Asserted through dialog.submit's real payload (as P4 does), not a new
-- accessor: that is the actual data that would reach the agent.
local function sent_tour(question)
  local real_send = channel.send
  local payload
  channel.send = function(_path, p) payload = p return true end
  dialog.submit(question)
  channel.send = real_send
  return vim.json.decode(payload).tour
end

local abspath = vim.fn.fnamemodify("tests/fixtures/two_files.tour", ":p")

wt.open("tests/fixtures/two_files.tour")
wt.ask()
wt.reload("tests/fixtures/two_files.tour")
T.eq(sent_tour("what file is this?"), abspath,
  "ctx.tour after a successful reload is the tour's absolute path, not empty")
wt.close()

-- ...and the restore-the-previous-tour branch of a FAILED reload: M.open is
-- called there with previous_tour, ALSO a table (the tour state already held,
-- not the string the walkthrough was originally opened with), so its gate is
-- just as blind. state.path must come back as the path the reader is still
-- actually looking at.
wt.open("tests/fixtures/two_files.tour")
local reload_ok = pcall(wt.reload, { title = "nothing plays", steps = {
  { title = "gone", file = "tests/fixtures/does-not-exist.txt", line = 1, description = "d" },
} })
T.ok(not reload_ok, "a reload to an all-unplayable tour fails")
wt.ask()
T.eq(sent_tour("still about the same tour?"), abspath,
  "ctx.tour after a FAILED reload (previous tour restored) is still the original absolute path")
wt.close()

T.done()
