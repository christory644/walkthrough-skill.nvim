-- Dialog properties that need no transport: what an answer is allowed to be,
-- and what the editor looks like while one is open.
local T = dofile("tests/harness.lua")
T.load_plugin()

local wt = require("walkthrough")
local dialog = require("walkthrough.dialog")

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

wt.close()
T.done()
