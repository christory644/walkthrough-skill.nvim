-- The dialog surface. This file owns the split, the prompt buffer and the
-- transcript; walkthrough.channel owns the write.
local channel = require("walkthrough.channel")
local keys_mod = require("walkthrough.keys")

local M = {}

M.NS = vim.api.nvim_create_namespace("walkthrough-dialog")

-- Nonces issued this session, newest last: nonce -> { step = <label>, answered = false }
M.issued = {}

-- S is the live-window state: buf/win handles, the ctx `M.open` was called
-- with, and a monotonic counter for nonces. Reset to nil/0 on `M.close`.
local S = { buf = nil, win = nil, ctx = nil, seq = 0 }

M.HEIGHT = 12

-- The transcript lives with the BUFFER; the window is only a view onto it. Ask
-- this, not `is_open()`, before writing to the transcript: an answer that lands
-- while the dialog is dismissed is recorded rather than dropped, and reopening
-- brings back the same conversation instead of a blank one.
function M.has_buffer()
  return S.buf ~= nil and vim.api.nvim_buf_is_valid(S.buf)
end

-- S.win and S.buf being individually valid is NOT enough, and the gap was on
-- the ordinary path. `nav.goto_index` used to retarget whatever window was
-- CURRENT, and `M.open` leaves the dialog's window current and in insert mode --
-- exactly where the reader sits while an answer is being composed, and exactly
-- when the answering agent runs `walkthrough step +1` (SKILL.md § 8 tells it
-- to). The dialog's window then showed a code file while `is_open()` still said
-- true: `M.open` took its reopen branch and only ran `startinsert` in a
-- nomodifiable code buffer, so the dialog never came back, and every later
-- `append` moved the cursor of a window whose buffer no longer had those lines
-- -- which is how `answer` and `reload` came to report failure through the CLI
-- for work that had already succeeded. nav no longer draws into this window;
-- this identity check is what stops that degrading silently again.
function M.is_open()
  return M.has_buffer() and S.win ~= nil and vim.api.nvim_win_is_valid(S.win)
    and vim.api.nvim_win_get_buf(S.win) == S.buf
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
  -- The name is fixed so the reader can find the transcript in `:ls`, which
  -- makes it a resource exactly one buffer can hold: nvim_buf_set_name raises
  -- E95 when another buffer already has it. That is not hypothetical -- the
  -- buffer is bufhidden=hide, so `:q` (or `<C-w>c`, or `:only`) leaves it alive
  -- with the name still claimed, and the NEXT `<leader>aa` threw. M.open reuses
  -- a surviving buffer rather than building a second one, so the only way to
  -- reach here with the name taken is an orphan nothing points at any more:
  -- take the name from it instead of raising.
  local prior = vim.fn.bufnr("^walkthrough://dialog$")
  if prior ~= -1 and prior ~= buf and vim.api.nvim_buf_is_valid(prior) then
    pcall(vim.api.nvim_buf_delete, prior, { force = true })
  end
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
  -- The buffer is resolved BEFORE the split, never after. make_buffer can raise
  -- (it claims a fixed name), and a raise after the split left S.win pointing at
  -- a brand-new window showing a code buffer while S.buf still named the old
  -- transcript -- exactly the mismatched state is_open() now refuses. Nothing is
  -- built until there is a buffer to put in it.
  --
  -- A surviving buffer is REUSED: `:q` on the dialog dismisses the window and
  -- keeps the transcript, so reopening has to bring the same conversation back.
  local buf = M.has_buffer() and S.buf or make_buffer()
  -- Bottom split, full width, inside the walkthrough's own tab (OQ-2). `botright`
  -- is what makes it span every column rather than only the current one's.
  vim.cmd(string.format("botright %dsplit", M.HEIGHT))
  S.win = vim.api.nvim_get_current_win()
  S.buf = buf
  vim.api.nvim_buf_create_user_command(S.buf, "WalkthroughCancel",
    function() M.cancel_pending() end, { desc = "drop the queued question" })
  -- Attached on every open, not once at creation, so a `setup{ keys = ... }`
  -- between two opens is honoured. The keys come from the caller (init passes
  -- its live config) and fall back to the defaults for a direct M.open.
  keys_mod.attach_dialog(S.buf, (S.ctx and S.ctx.keys) or keys_mod.defaults)
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
  -- The notice belongs in the transcript whether or not a window is showing it:
  -- a dismissed dialog still holds the conversation, and reopening it after a
  -- reload must not present questions asked about the OLD tour as if they were
  -- asked about this one.
  if not M.has_buffer() then return end
  S.ctx = ctx
  M.append({ "— the tour was reloaded —" }, "Comment")
  M.refresh()
end

-- Forward-declared: the real definition lives further down, next to the rest
-- of the "agent is working" state (W). M.close is defined here, above it, so
-- this upvalue has to exist before that closure is compiled.
local stop_working

-- Dismissal, and the reason it is not M.close: the reader wants the split out of
-- the way, not the conversation ended. The buffer, the transcript, the queued
-- question and every nonce still outstanding survive, so `<leader>aa` reopens
-- the same conversation. Ending it is the walkthrough's job.
--
-- `:q` and `<C-w>c` reach the same place by a different route -- they close the
-- window and leave the hidden buffer behind -- which is why this is safe to
-- offer as a binding at all: after F2 both spellings reopen.
function M.dismiss()
  if S.win and vim.api.nvim_win_is_valid(S.win) then
    -- Refuses when it is the last window; the reader keeps their editor either
    -- way, and the dialog stays reopenable.
    pcall(vim.api.nvim_win_close, S.win, true)
  end
  S.win = nil
end

function M.close()
  M.cancel_pending(true)
  stop_working()
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
  -- The BUFFER is the transcript, so this writes whether or not a window is
  -- currently showing it -- and it must never raise: it runs on the inbound path
  -- (`walkthrough answer`) and on M.reload's, and a raise there reports failure
  -- through the CLI for work that already happened.
  if not M.has_buffer() then return end
  local last = vim.api.nvim_buf_line_count(S.buf)
  local at = math.max(last - 1, 0)
  vim.api.nvim_buf_set_lines(S.buf, at, at, false, lines)
  if hl then
    for i = 0, #lines - 1 do
      vim.api.nvim_buf_set_extmark(S.buf, M.NS, at + i, 0,
        { line_hl_group = hl, end_row = at + i + 1 })
    end
  end
  -- Only ever moves the cursor of a window that is genuinely showing THIS
  -- buffer. `nvim_win_is_valid` alone was not that question, and the window
  -- displaying a code file with fewer lines is how this raised
  -- "Invalid cursor line: out of range" out of `answer` and out of `reload`.
  if M.is_open() then
    vim.api.nvim_win_set_cursor(S.win, { vim.api.nvim_buf_line_count(S.buf), 0 })
  end
end

-- How long the reader's side waits before saying so. Longer than `await`'s
-- default budget on purpose: await bounds how long the AGENT waits for a
-- question, and the agent still has to compose an answer after receiving one.
-- These are two different clocks measuring two different things.
M.ANSWER_TIMEOUT_MS = 300000

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local W = nil  -- { nonce, since, timer, frame, mark }

-- Tier 1: a live line drawn as an EXTMARK, not as text, so the answer replaces
-- it and the transcript is never littered with dead spinners.
local function draw_working()
  if not (M.is_open() and W) then return end
  local uv = vim.uv or vim.loop
  local secs = math.floor((uv.hrtime() / 1e6 - W.since) / 1000)
  W.frame = (W.frame % #SPINNER) + 1
  local at = math.max(vim.api.nvim_buf_line_count(S.buf) - 1, 0)
  W.mark = vim.api.nvim_buf_set_extmark(S.buf, M.NS, at, 0, {
    id = W.mark,
    virt_lines = { { { string.format("  %s the agent is working (%d:%02d)",
      SPINNER[W.frame], math.floor(secs / 60), secs % 60), "Comment" } } },
    virt_lines_above = true,
  })
  M.refresh()
end

function stop_working()
  if not W then return end
  if W.timer then pcall(function() W.timer:stop() W.timer:close() end) end
  if W.mark and M.is_open() then
    pcall(vim.api.nvim_buf_del_extmark, S.buf, M.NS, W.mark)
  end
  W = nil
  M.refresh()
end

function M.mark_waiting(nonce)
  stop_working()
  local uv = vim.uv or vim.loop
  W = { nonce = nonce, since = uv.hrtime() / 1e6, frame = 0, mark = nil }
  W.timer = uv.new_timer()
  W.timer:start(0, 100, vim.schedule_wrap(function()
    if not W then return end
    if (uv.hrtime() / 1e6 - W.since) > M.ANSWER_TIMEOUT_MS then
      local q = M.issued[W.nonce]
      if q then q.timed_out = true end
      stop_working()
      -- One of four distinguishable terminal states. This one is "the agent
      -- stopped waiting", which is a different fact from "no agent is
      -- listening" (never attached) and from "the agent went away" (died
      -- mid-wait) -- the reader can act on the difference.
      M.append({ "walkthrough: the agent stopped waiting — ask again." }, "WarningMsg")
      return
    end
    draw_working()
  end))
end

function M.on_sent(nonce) M.mark_waiting(nonce) end

-- Replaces the receipt stub.
function M.answer(nonce, text)
  local q = M.issued[nonce]
  if not q then
    return false, "no question is waiting on that nonce: " .. tostring(nonce)
  end
  if W and W.nonce == nonce then stop_working() end
  local lines = M.sanitise(text)
  if q.answered or q.timed_out then
    -- OQ-4: append, clearly marked, and NAME THE STEP. The likeliest moment for
    -- a late answer to land is after the reader has moved on, and the step is
    -- what tells them whether to care without scrolling back.
    table.insert(lines, 1, string.format(
      "agent (late — this answers step %s, \"%s\"):",
      tostring(q.index), tostring(q.step)))
  else
    table.insert(lines, 1, "agent:")
  end
  q.answered = true
  M.append(lines, nil)
  return true
end

-- Tier 2: one line on the dialog window, carrying the step the question is
-- scoped to and the elapsed time. It costs a line, survives scrolling, and is
-- where "an agent is attached / none is" belongs when nothing is in flight.
function M.refresh()
  if not M.is_open() then return end
  local ctx = S.ctx or {}
  local right = "idle"
  if W then
    local secs = math.floor(((vim.uv or vim.loop).hrtime() / 1e6 - W.since) / 1000)
    right = string.format("waiting %d:%02d", math.floor(secs / 60), secs % 60)
  elseif M.pending() then
    right = "queued — waiting for an agent"
  end
  vim.wo[S.win].winbar = string.format("ask · step %s/%s %s · %%=%s ",
    tostring(ctx.index or "?"), tostring(ctx.count or "?"),
    ctx.step_id and ('"' .. ctx.step_id .. '"') or "", right)
end

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

-- The retry interval. Each tick is a full send ATTEMPT, not a probe:
-- O_WRONLY|O_NONBLOCK makes the liveness check and the write the same
-- syscall, so a separate "is anyone listening?" open would be a second fact
-- that can only disagree with the attempt itself — it buys nothing over just
-- trying. (It would also cost something against a naive one-shot reader: an
-- open that closes without writing ends a blocked `head -1 < fifo` with an
-- empty, successful read — measured — though not our own O_RDONLY|O_NONBLOCK
-- reader, which tolerates it.) A refused attempt costs an ENXIO at 0.03 ms,
-- so a one-second tick is free.
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
  -- The queued state just ended (dropped, expired, or delivered) -- the
  -- winbar's "queued — waiting for an agent" text is now stale. This is the
  -- ONLY place P is cleared (M.close, M.submit, and every exit of `attempt`
  -- all clear it by calling here), so refreshing here covers all of them.
  M.refresh()
end

-- The prompt line as the reader currently has it. The queued question is only
-- auto-sent while this still matches: "does not fire if the buffer has been
-- edited or cleared since" is the binding half of OQ-3.
local function prompt_text()
  if not M.has_buffer() then return nil end
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
  if not M.has_buffer() then return end
  local last = vim.api.nvim_buf_line_count(S.buf)
  vim.api.nvim_buf_set_lines(S.buf, last - 1, last, false,
    { vim.fn.prompt_getprompt(S.buf) .. text })
end

local function attempt()
  if not P then return end
  -- The buffer, not the window: a question queued for want of a reader stays
  -- queued while the dialog is dismissed, and the prompt line it is compared
  -- against is still there. Only the conversation ending drops it.
  if not M.has_buffer() then M.cancel_pending(true) return end
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
  -- This is the ONLY place P is created -- the winbar's "idle" text is now
  -- stale until this refreshes it to "queued — waiting for an agent".
  M.refresh()
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
  if not M.has_buffer() then return end
  local last = vim.api.nvim_buf_line_count(S.buf)
  vim.api.nvim_buf_set_lines(S.buf, last - 1, last, false,
    { vim.fn.prompt_getprompt(S.buf) })
end

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

return M
