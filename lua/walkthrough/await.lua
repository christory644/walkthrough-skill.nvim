-- The bounded read behind `walkthrough await`. Invoked as:
--   nvim --headless --clean -l await.lua <fifo> <budget_ms> [<ready_file>]
--
-- Argv only, like validate.lua: the FIFO path is data and never source.
--
-- Why this is a Lua script and not `timeout N head -1 < fifo`:
--
--   1. macOS has no timeout(1), so that spelling is not portable at all; and
--   2. the obvious portable substitute — bash's `exec 3<>fifo` plus `read -t` —
--      opens the FIFO O_RDWR, and a O_RDWR holder MEASURES AS NO READER from
--      the writer's side. nvim's O_WRONLY|O_NONBLOCK open returns ENXIO while
--      that reader is attached and waiting, so every question would be refused
--      while an agent was listening. Measured on the reference machine;
--      tests/test_dialog_fifo.sh pins it.
--
-- O_RDONLY|O_NONBLOCK is the only shape that both returns immediately (rather
-- than blocking in open() until a writer shows up, which is what would need the
-- timeout we cannot spell) AND counts as a reader for the writer's ENXIO check.
--
-- One more rule, and it is the reason a bare EOF is not a question: a writer
-- that opens and closes WITHOUT writing ends a blocked reader with an empty,
-- SUCCESSFUL read. Only a complete newline-terminated line counts here. A
-- partial read is held and waited on; nothing else is ever printed.
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
