-- The dialog surface. This file owns the split, the prompt buffer and the
-- transcript; walkthrough.channel owns the write.
local channel = require("walkthrough.channel")

local M = {}

M.NS = vim.api.nvim_create_namespace("walkthrough-dialog")

-- Nonces issued this session, newest last: nonce -> { step = <label>, answered = false }
M.issued = {}

-- S is the live-window state: buf/win handles, the ctx `M.open` was called
-- with, and a monotonic counter for nonces. Reset to nil/0 on `M.close`.
local S = { buf = nil, win = nil, ctx = nil, seq = 0 }

M.HEIGHT = 12

function M.is_open()
  return S.win ~= nil and vim.api.nvim_win_is_valid(S.win)
    and S.buf ~= nil and vim.api.nvim_buf_is_valid(S.buf)
end

function M.bufnr() return S.buf end
function M.winid() return S.win end

local function make_buffer()
  local buf = vim.api.nvim_create_buf(false, true)
  -- buftype=prompt gives Enter-to-submit for free, and it restricts normal-mode
  -- editing to the last (prompt) line regardless of 'modifiable' — verified:
  -- entering insert mode with the cursor parked above the prompt line moves the
  -- cursor to the prompt line before the keystroke lands. 'modifiable' itself
  -- stays true for the buffer's whole life (a fresh scratch buffer already
  -- defaults to it, and nvim_buf_set_lines needs it to stay true to write the
  -- transcript at all) — it is buftype=prompt, not 'modifiable', that makes
  -- "the transcript is not editable, the input is" hold.
  vim.bo[buf].buftype = "prompt"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.fn.prompt_setprompt(buf, "> ")
  vim.api.nvim_buf_set_name(buf, "walkthrough://dialog")

  -- Never written to disk. The transcript holds agent-authored text, and a file
  -- on disk is a thing an agent can later read back as if it were instructions.
  --
  -- A bare `nofile`-style buftype would already skip nvim's own file write, but
  -- this buffer is buftype=prompt, and a prompt buffer with no BufWriteCmd
  -- writes an empty file successfully (measured) -- `:write` just reports
  -- success on nothing written. So the refusal has to be an actual error, not
  -- only a warning message: nvim_echo alone leaves `:write` reporting success,
  -- which is not "refuses". `error()` inside a BufWriteCmd callback is what
  -- makes `:write` itself fail.
  --
  -- No `return true`: per :h nvim_create_autocmd, returning true from a
  -- callback deletes the autocmd -- which would mean only the FIRST write
  -- attempt is refused and every one after it silently succeeds.
  vim.api.nvim_create_autocmd({ "BufWriteCmd", "FileWriteCmd" }, {
    buffer = buf,
    callback = function()
      vim.api.nvim_echo({ { "walkthrough: the dialog is not written to disk", "WarningMsg" } },
        true, {})
      error("walkthrough: the dialog is not written to disk", 0)
    end,
  })

  vim.fn.prompt_setcallback(buf, function(text) M.submit(text) end)
  return buf
end

function M.open(ctx)
  S.ctx = ctx or S.ctx
  if M.is_open() then
    M.refresh()
    vim.api.nvim_set_current_win(S.win)
    vim.cmd("startinsert")
    return
  end
  -- Bottom split, full width, inside the walkthrough's own tab (OQ-2). `botright`
  -- is what makes it span every column rather than only the current one's.
  vim.cmd(string.format("botright %dsplit", M.HEIGHT))
  S.win = vim.api.nvim_get_current_win()
  S.buf = make_buffer()
  vim.api.nvim_buf_create_user_command(S.buf, "WalkthroughCancel",
    function() M.cancel_pending() end, { desc = "drop the queued question" })
  vim.api.nvim_win_set_buf(S.win, S.buf)
  vim.wo[S.win].number = false
  vim.wo[S.win].relativenumber = false
  vim.wo[S.win].signcolumn = "no"
  vim.wo[S.win].wrap = true
  M.refresh()
  vim.cmd("startinsert")
end

-- A reload re-renders everything the reader is looking at, and the step the
-- transcript is scoped to may have moved or gone. Say so in the transcript
-- rather than silently re-scoping: a question two lines above the notice was
-- asked about a different version of the tour.
function M.on_reload(ctx)
  if not M.is_open() then return end
  S.ctx = ctx
  M.append({ "— the tour was reloaded —" }, "Comment")
  M.refresh()
end

function M.close()
  M.cancel_pending(true)
  if S.win and vim.api.nvim_win_is_valid(S.win) then
    pcall(vim.api.nvim_win_close, S.win, true)
  end
  if S.buf and vim.api.nvim_buf_is_valid(S.buf) then
    pcall(vim.api.nvim_buf_delete, S.buf, { force = true })
  end
  S.buf, S.win, S.ctx = nil, nil, nil
  M.issued = {}
end

-- The ONLY writer to the transcript, and it goes through nvim_buf_set_lines --
-- never :put, never execute, never anything that would read the text as a
-- command.
--
-- Lines are inserted ABOVE the prompt line, so the input stays at the bottom
-- where the reader is typing.
--
-- No 'modifiable' toggling here: make_buffer leaves it true for the buffer's
-- whole life (measured — see make_buffer's comment), and this buffer is never
-- written to disk, so there is nothing 'modifiable' is protecting here. What
-- keeps the transcript read-only to the READER is buftype=prompt confining
-- normal-mode edits to the last line, not this flag.
function M.append(lines, hl)
  if not M.is_open() then return end
  local last = vim.api.nvim_buf_line_count(S.buf)
  local at = math.max(last - 1, 0)
  vim.api.nvim_buf_set_lines(S.buf, at, at, false, lines)
  if hl then
    for i = 0, #lines - 1 do
      vim.api.nvim_buf_set_extmark(S.buf, M.NS, at + i, 0,
        { line_hl_group = hl, end_row = at + i + 1 })
    end
  end
  if vim.api.nvim_win_is_valid(S.win) then
    vim.api.nvim_win_set_cursor(S.win, { vim.api.nvim_buf_line_count(S.buf), 0 })
  end
end

-- Grown into the winbar in the "agent is working" task; a no-op until then so
-- nothing here has a dangling call.
function M.refresh() end

-- Frame the question and hand it to the channel. One JSON line: JSON escaping
-- IS the encoding, so a quote or a newline in the question is data rather than
-- a framing problem.
--
-- The nonce is for correctness, not secrecy: it is what makes "which question
-- does this answer" decidable when an answer arrives after its question timed
-- out. hrtime plus a counter rather than uv.random, because it needs nothing
-- newer than nvim 0.10.4 and uniqueness is the whole requirement.
local function next_nonce()
  S.seq = S.seq + 1
  return string.format("%x-%d", (vim.uv or vim.loop).hrtime(), S.seq)
end

-- The retry interval. Each tick is a full send ATTEMPT, not a probe: there is
-- no way to ask "is anyone listening?" without an open, and an open that does
-- not write ends the agent's read with an empty, successful result. A refused
-- attempt costs an ENXIO at 0.03 ms, so a one-second tick is free.
M.RETRY_MS = 1000
-- After ten minutes nobody is coming. The text stays in the prompt line; only
-- the timer stops. A question that lands after the reader has forgotten it is
-- the failure OQ-3 exists to prevent, and an unbounded timer is how you get one.
M.PENDING_LIMIT_MS = 600000

local P = nil  -- { text, nonce, timer, since }

function M.pending()
  if not P then return nil end
  return { text = P.text, since_ms = (vim.uv or vim.loop).hrtime() / 1e6 - P.since }
end

function M.cancel_pending(quiet)
  if not P then return end
  if P.timer then pcall(function() P.timer:stop() P.timer:close() end) end
  P = nil
  if not quiet then
    M.append({ "walkthrough: the question was not sent." }, "Comment")
  end
end

-- The prompt line as the reader currently has it. The queued question is only
-- auto-sent while this still matches: "does not fire if the buffer has been
-- edited or cleared since" is the binding half of OQ-3.
local function prompt_text()
  if not M.is_open() then return nil end
  local lines = vim.api.nvim_buf_get_lines(S.buf, -2, -1, false)
  local line = lines[1] or ""
  return (line:gsub("^" .. vim.pesc(vim.fn.prompt_getprompt(S.buf)), ""))
end

-- Puts `text` back in the (last) prompt line. M.submit is reached two ways:
-- a real keystroke, where the prompt line already shows what was typed, and a
-- programmatic call (attempt's own retry, and anything else that calls
-- M.submit/M.send_now directly) where nothing was ever typed at all -- the
-- buffer's prompt line is still bare. Without this, `prompt_text() == P.text`
-- would never hold for a programmatic submission, and OQ-3's own auto-send
-- would refuse itself as "you changed the question" on its very first tick.
-- Measured: writing here during the prompt callback is NOT clobbered by nvim
-- afterwards -- nvim only fills the last line with the bare prompt when the
-- callback left it untouched.
local function set_prompt_text(text)
  if not M.is_open() then return end
  local last = vim.api.nvim_buf_line_count(S.buf)
  vim.api.nvim_buf_set_lines(S.buf, last - 1, last, false,
    { vim.fn.prompt_getprompt(S.buf) .. text })
end

local function attempt()
  if not P then return end
  if not M.is_open() then M.cancel_pending(true) return end
  -- The reader changed their mind, or typed something else. Their edit wins.
  if vim.trim(prompt_text() or "") ~= P.text then
    M.append({ "walkthrough: you changed the question, so the earlier one was dropped." },
      "Comment")
    M.cancel_pending(true)
    return
  end
  if (vim.uv or vim.loop).hrtime() / 1e6 - P.since > M.PENDING_LIMIT_MS then
    M.append({ "walkthrough: no agent came, so this was not sent. Ask again when one is." },
      "WarningMsg")
    M.cancel_pending(true)
    return
  end
  local ok = M.send_now(P.text, P.nonce)
  if ok then M.cancel_pending(true) end
end

function M.on_refused(text, reason, message)
  -- Only the transport is refused, and only for want of a reader. Everything
  -- else -- too long, a NUL, a short write -- is the reader's problem to fix and
  -- queueing it would just repeat the same failure every second.
  if reason ~= "no_reader" and reason ~= "gone" then
    M.append({ "walkthrough: " .. tostring(message) }, "WarningMsg")
    return
  end
  M.append({
    "walkthrough: " .. tostring(message) .. " — your question is kept and will send",
    "  itself as soon as one is. :WalkthroughCancel drops it; editing the line",
    "  below drops it too.",
  }, "WarningMsg")
  set_prompt_text(text)
  P = { text = text, nonce = nil, since = (vim.uv or vim.loop).hrtime() / 1e6 }
  P.timer = (vim.uv or vim.loop).new_timer()
  P.timer:start(M.RETRY_MS, M.RETRY_MS, vim.schedule_wrap(attempt))
end

-- Returns true, nonce when the question actually reached a reader; otherwise
-- false, reason, message. The nonce is returned on success (not just recorded
-- in M.issued) because M.submit is a public interface and Task 7's test
-- asserts on the nonce it hands back.
function M.send_now(text, nonce)
  local ctx = S.ctx or {}
  nonce = nonce or next_nonce()
  local payload = vim.json.encode({
    tour = ctx.tour or "", step_id = ctx.step_id or "", index = ctx.index or 0,
    question = text, nonce = nonce,
  })
  local ok, reason, message = channel.send(ctx.fifo, payload)
  if ok then
    M.issued[nonce] = { step = ctx.step_id, index = ctx.index, answered = false }
    -- text is allowed to contain \n (M.submit's control-char guard deliberately
    -- lets \n and \t through), and nvim_buf_set_lines refuses any array element
    -- that embeds a newline -- an unsanitised "you: " .. text raises "'replacement
    -- string' item contains newlines" for a multi-line question, AFTER the send
    -- already succeeded and the nonce is already recorded. Route through
    -- M.sanitise, exactly as M.answer does, so the echo is one buffer line per
    -- source line, same as the transcript for an agent's answer. This path is
    -- reached both from a keystroke (M.submit) and programmatically, with no
    -- keystroke at all, from the auto-send retry (attempt) -- the sanitising
    -- has to live here, not in the caller, so both keep it.
    local echo = M.sanitise(text)
    echo[1] = "you: " .. echo[1]
    M.append(echo, nil)
    M.clear_prompt()
    M.on_sent(nonce)
    return true, nonce
  end
  return false, reason, message
end

function M.clear_prompt()
  if not M.is_open() then return end
  local last = vim.api.nvim_buf_line_count(S.buf)
  vim.api.nvim_buf_set_lines(S.buf, last - 1, last, false,
    { vim.fn.prompt_getprompt(S.buf) })
end

-- Grown into the spinner in the next task.
function M.on_sent(_nonce) end

function M.submit(text)
  text = vim.trim(tostring(text or ""))
  if text == "" then return end

  -- Refused at the buffer, before anything is framed: control characters and
  -- NUL have no meaning in a question and a NUL cannot survive the round trip.
  if text:find("[%z\1-\8\11\12\14-\31]") then
    M.append({ "walkthrough: a question cannot contain control characters." }, "WarningMsg")
    return
  end

  M.cancel_pending(true)  -- a new question replaces a queued one
  local ok, a, b = M.send_now(text)
  if ok then return true, a end  -- a is the nonce
  M.on_refused(text, a, b)  -- a, b are reason, message
  return false, a
end

-- Control characters and NUL are stripped at the boundary, not deeper in.
--
-- NUL is not cosmetic: it crosses --remote-expr as a Blob and raises E976 — the
-- same fact that makes tour.step_id fall back to the index for a title
-- containing one. Everything else that is not a newline or a tab would corrupt
-- the buffer's rendering without saying so.
function M.sanitise(text)
  local clean = tostring(text)
    :gsub("\r\n", "\n")
    :gsub("[%z\1-\8\11\12\13\14-\31\127]", "")
  return vim.split(clean, "\n", { plain = true })
end

-- Stub receipt path: records the answer against the nonce it was issued
-- under. Task 7 replaces this with the real renderer/transcript.
function M.answer(nonce, text)
  local q = M.issued[nonce]
  if not q then
    return false, "no question is waiting on that nonce: " .. tostring(nonce)
  end
  q.lines = M.sanitise(text)
  q.answered = true
  return true
end

return M
