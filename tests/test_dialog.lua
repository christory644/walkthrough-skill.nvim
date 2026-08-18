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

T.done()
