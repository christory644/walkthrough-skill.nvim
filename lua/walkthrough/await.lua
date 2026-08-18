-- The bounded read behind `walkthrough await`. Invoked as:
--   nvim --headless --clean -l await.lua <fifo> <budget_ms> [<ready_file>]
--
-- Argv only, like validate.lua: the FIFO path is data and never source.
--
-- Why this is a Lua script and not `timeout N head -1 < fifo`: macOS has no
-- timeout(1), so a bounded read is not spellable in portable shell at all.
-- That is reason enough on its own.
--
-- O_RDONLY|O_NONBLOCK is used because the open returns immediately rather
-- than blocking until a writer shows up — which is exactly the block a
-- timeout would otherwise be needed to bound. (An O_RDWR open, the shape
-- `exec 3<>fifo` produces, also counts as a reader to a writer's
-- O_WRONLY|O_NONBLOCK open — tested directly, on this machine, in bash, in
-- nvim, and via a raw open(2); an earlier version of this comment claimed
-- the opposite and was wrong. So O_RDONLY|O_NONBLOCK is not the only shape
-- that works here — it is simply the simpler correct one, and the one that
-- does not also hold this process open as a writer on its own FIFO.)
--
-- What a Lua reader buys over `head -1 < fifo` that is worth the extra file:
-- exact budget control (the while-loop below, not a wrapper process), and
-- surviving a stray open-close-without-write. Measured both ways: a bare
-- probe (open, no write, close) ends `head -1 < fifo` with rc=0 and zero
-- bytes — indistinguishable from "someone asked nothing" — while this
-- script's read of that same probe comes back as 0 bytes with NO error
-- (see the EOF-vs-error branch below), so the loop just keeps waiting and
-- still delivers the next real question whole. That is the reason a bare
-- EOF is not treated as a question here: only a complete newline-terminated
-- line counts. A partial read is held and waited on; nothing else is ever
-- printed.
local uv = vim.uv or vim.loop

local path = _G.arg[1]
local budget_ms = tonumber(_G.arg[2] or "")
local ready = _G.arg[3]

if type(path) ~= "string" or path == "" or not budget_ms then
  io.stderr:write("usage: await.lua <fifo> <budget_ms> [<ready_file>]\n")
  os.exit(2)
end

local RDONLY_NONBLOCK = bit.bor(uv.constants.O_RDONLY, uv.constants.O_NONBLOCK)
local fd, err, name = uv.fs_open(path, RDONLY_NONBLOCK, tonumber("600", 8))
if not fd then
  io.stderr:write(string.format(
    "walkthrough: the dialog channel could not be opened (%s): %s\n",
    tostring(name), tostring(err)))
  os.exit(3)
end

-- Only after the fd exists, because the whole point of the signal is "a writer
-- may now open without ENXIO". Used by the tests to distinguish a delivered
-- question from a reader that was never waiting.
if ready and ready ~= "" then
  local f = io.open(ready, "w")
  if f then f:write("r") f:close() end
end

local started = uv.hrtime() / 1e6
local buf = ""
while (uv.hrtime() / 1e6 - started) < budget_ms do
  local chunk, rerr, rname = uv.fs_read(fd, 4096, -1)
  if chunk == nil and rname ~= "EAGAIN" then
    uv.fs_close(fd)
    io.stderr:write(string.format("walkthrough: the dialog channel failed: %s\n",
      tostring(rerr)))
    os.exit(3)
  end
  if chunk and #chunk > 0 then
    buf = buf .. chunk
    local line = buf:match("^([^\n]*)\n")
    if line then
      uv.fs_close(fd)
      io.write(line, "\n")
      os.exit(0)
    end
  end
  uv.sleep(10)
end

uv.fs_close(fd)
io.stderr:write("walkthrough: nobody asked anything (waited "
  .. tostring(math.floor(budget_ms / 1000)) .. "s)\n")
os.exit(4)
