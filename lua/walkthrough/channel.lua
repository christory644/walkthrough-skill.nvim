-- The one place the plugin writes to the dialog FIFO.
--
-- Writing to a FIFO with no reader BLOCKS THE WRITER, and the writer here is
-- nvim — the failure is a frozen editor, the worst thing this project can
-- produce. The design's original answer was "the agent is blocked by
-- construction", which is an assumption about another process and is wrong
-- whenever the agent has died, was never attached, has already answered, or had
-- its turn ended by the user.
--
-- The assumption does not have to be trusted. O_WRONLY|O_NONBLOCK returns ENXIO
-- immediately when no reader holds the FIFO — measured at 0.03 ms on the
-- reference machine. So the liveness check is not a separate probe that can
-- disagree with the write: it IS the open.
--
-- Two rules follow, and both are load-bearing:
--
--   * There is NO liveness probe anywhere in this plugin. An open that closes
--     without writing ends a blocked reader with an empty, SUCCESSFUL read
--     (measured), so a "is anyone listening?" call would silently end the
--     agent's turn with no question in it. The only reason to open this FIFO is
--     to write, immediately, and close.
--   * A short write is REPORTED, never retried. Retrying is how a non-blocking
--     writer talks itself back into blocking.
local uv = vim.uv or vim.loop

local M = {}

-- 2 KB, and the cap is not cosmetic: past PIPE_BUF a write on a non-blocking fd
-- may be short or interleaved, and fs_write returns a byte count, so a short
-- write is detectable — which is only useful if we then refuse rather than
-- retry.
M.MAX_BYTES = 2048

local WRONLY_NONBLOCK = bit.bor(uv.constants.O_WRONLY, uv.constants.O_NONBLOCK)

-- Returns: ok, reason, message.
-- `reason` is for the caller's logic, `message` is what the reader is shown.
function M.send(path, payload)
  if type(path) ~= "string" or path == "" then
    return false, "no_channel",
      "this walkthrough has no dialog channel — reopen it to ask questions"
  end
  local line = payload .. "\n"
  if #line > M.MAX_BYTES then
    return false, "too_long", string.format(
      "the question is too long (%d bytes; the limit is %d)", #line, M.MAX_BYTES)
  end

  local fd, err, name = uv.fs_open(path, WRONLY_NONBLOCK, tonumber("600", 8))
  if not fd then
    -- ENXIO is the ordinary case, not an error condition: nobody is waiting.
    if name == "ENXIO" then
      return false, "no_reader", "no agent is listening"
    end
    return false, "open_failed",
      "the dialog channel could not be opened: " .. tostring(err)
  end

  local n, werr, wname = uv.fs_write(fd, line)
  uv.fs_close(fd)

  if not n then
    -- The reader died between our open and our write. EPIPE is RETURNED here,
    -- not raised as a signal — nvim survives it — so this reports as "the agent
    -- went away", which is a different fact from "no agent is listening": it
    -- WAS there.
    if wname == "EPIPE" then return false, "gone", "the agent went away" end
    return false, "write_failed", "the question could not be sent: " .. tostring(werr)
  end
  if n < #line then
    return false, "short_write", string.format(
      "only %d of %d bytes reached the agent, so the question was not sent", n, #line)
  end
  return true
end

return M
