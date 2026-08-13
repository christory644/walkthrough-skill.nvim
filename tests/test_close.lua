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

T.done()
