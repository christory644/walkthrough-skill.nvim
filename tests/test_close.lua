-- Correction 3: M.close() must prefer WALKTHROUGH_CLI (the absolute path the
-- CLI injects at open time) over a PATH lookup for "walkthrough", so teardown
-- works even when bin/ was never put on PATH (install.sh documents that as
-- optional). Proven here without a real cmux surface: point WALKTHROUGH_CLI
-- at a stub script that just touches a marker file, close(), and assert the
-- marker appeared.
local T = dofile("tests/harness.lua")
T.load_plugin()
local wt = require("walkthrough")

local marker = vim.fn.tempname()
local stub = vim.fn.tempname()
vim.fn.writefile({
  "#!/usr/bin/env bash",
  'touch "' .. marker .. '"',
}, stub)
vim.fn.setfperm(stub, "rwxr-xr-x")

vim.env.WALKTHROUGH_HANDLE = "fake-handle"
vim.env.WALKTHROUGH_BACKEND = "fake-backend"
vim.env.WALKTHROUGH_CLI = stub

-- Capture the job id close() starts (it does not expose one), so we can wait
-- on it properly with jobwait rather than sleeping and hoping.
local job_id
local orig_jobstart = vim.fn.jobstart
vim.fn.jobstart = function(...)
  job_id = orig_jobstart(...)
  return job_id
end

wt.open("tests/fixtures/two_files.tour")
wt.close()

vim.fn.jobstart = orig_jobstart

T.ok(job_id ~= nil, "close() started a job")
if job_id then
  vim.fn.jobwait({ job_id }, 2000)
end

T.ok(vim.fn.filereadable(marker) == 1, "close() invoked WALKTHROUGH_CLI (marker file appeared)")

vim.fn.delete(marker)
vim.fn.delete(stub)
vim.env.WALKTHROUGH_HANDLE = nil
vim.env.WALKTHROUGH_BACKEND = nil
vim.env.WALKTHROUGH_CLI = nil

-- Issue #6: teardown must clear OUR quickfix list and no one else's.
--
-- The walkthrough runs in a dedicated nvim, so for a long time there was no
-- other list to protect -- but the reader can make one at any moment. Run a
-- `:grep` mid-tour and the quickfix list is theirs; `close()` then replaced it
-- with an empty list titled "walkthrough", and the results they had just
-- gathered were gone with no way back.
--
-- The guard this needs already existed twenty lines away, in
-- nav.mark_dropped_in_qflist, which refuses to retitle an entry in a list that
-- is not ours. Both now ask nav.is_our_qflist, so they cannot drift apart:
-- "only ever edit our own list" is one rule with one implementation.
local nav = require("walkthrough.nav")

wt.open("tests/fixtures/two_files.tour")
T.ok(nav.is_our_qflist(), "the walkthrough's own list is current while it plays")

-- the reader greps mid-tour; the list is now theirs
vim.fn.setqflist({}, " ", { title = "grep results", items = {
  { filename = "tests/fixtures/alpha.txt", lnum = 1, text = "a match" },
  { filename = "tests/fixtures/beta.txt", lnum = 2, text = "another" },
} })
wt.close()

local foreign = vim.fn.getqflist({ title = 0, items = 0 })
T.eq(foreign.title, "grep results", "close() left the reader's own quickfix list alone")
T.eq(#foreign.items, 2, "...with every entry they had gathered still in it")

-- ...and the converse, so the guard cannot be satisfied by simply never
-- clearing anything: a walkthrough still cleans up the list it made itself.
wt.open("tests/fixtures/two_files.tour")
T.eq(#vim.fn.getqflist(), 3, "a fresh walkthrough populates its own list again")
wt.close()
T.eq(#vim.fn.getqflist(), 0, "...and closing clears THAT one")

T.done()
