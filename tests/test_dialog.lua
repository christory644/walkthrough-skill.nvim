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

-- P7 — a timeout is distinguishable from a slow answer.
--
-- Identical-if-broken: "the dialog eventually shows something" passes when the
-- answer merely arrived late. The nonce is what makes this decidable, so assert
-- the timeout state at the budget AND that a later answer is marked late.
wt.open("tests/fixtures/two_files.tour")
wt.ask()
dialog.ANSWER_TIMEOUT_MS = 200
-- send_now returns (true, nonce) on success but (false, reason, message) on
-- failure; there is no channel here, so this is expected to fail, and the
-- second value is a REASON, not a nonce.
local ok, why = dialog.send_now("why not a plain spawn?")
T.eq(ok, false, "with no channel there is nothing to send")

-- Issue a nonce directly: this test is about receipt, not transport.
dialog.issued["n1"] = { step = "the retry", index = 1, answered = false }
dialog.mark_waiting("n1")
vim.wait(1500, function() return dialog.issued["n1"].timed_out end, 50)
T.ok(dialog.issued["n1"].timed_out, "the question times out at its budget")
local body = function()
  return table.concat(vim.api.nvim_buf_get_lines(dialog.bufnr(), 0, -1, false), "\n")
end
T.ok(body():find("stopped waiting", 1, true) ~= nil,
  "and the buffer says the agent stopped waiting")

-- OQ-4 — a late answer is APPENDED, clearly marked, and NAMES THE STEP: the
-- likeliest moment for one to land is after the reader has moved on, and naming
-- the step tells them whether to care without scrolling.
local accepted = dialog.answer("n1", "because a spawned process has no supervisor.")
T.ok(accepted, "a late answer is accepted, not discarded")
T.ok(body():find("no supervisor", 1, true) ~= nil, "its text is appended")
T.ok(body():find("the retry", 1, true) ~= nil, "and it names the step it answers")
T.ok(body():lower():find("late", 1, true) ~= nil, "and it is marked late")

-- An answer to a nonce nobody issued is refused outright.
local ok2, why2 = dialog.answer("never-issued", "hello")
T.eq(ok2, false, "an unissued nonce is refused")
T.ok(tostring(why2):find("no question", 1, true) ~= nil, "and says why")

-- The spinner is an extmark, so the answer replaces it rather than leaving a
-- dead spinner in the transcript.
T.ok(not body():find("⠋", 1, true), "no dead spinner text in the transcript")

-- Tier 2: the winbar carries the step and the elapsed time. Controller ruling:
-- the fixture's first step (the one wt.ask() above actually scoped to) is
-- titled "first", not "the retry" -- "the retry" is only the label stashed on
-- the n1 nonce issued directly above, used by the transcript assertions. Read
-- the live step id from wt.state() rather than hardcoding a title, so this
-- assertion cannot drift from the fixture.
T.ok(tostring(vim.wo[dialog.winid()].winbar):find(wt.state().id, 1, true) ~= nil,
  "the winbar names the step the question is scoped to")
wt.close()

-- Review round 2, Important — the winbar's queued state was unreachable:
-- M.refresh's `elseif M.pending() then` branch is correct in isolation, but
-- nothing called M.refresh while a question sat in the retry queue, so the
-- winbar kept showing "idle" for the whole ten-minute retry window.
--
-- Identical-if-broken: asserting only `dialog.pending() ~= nil` after a
-- refusal passes on the broken implementation too -- that fact was always
-- true, it just never reached the screen. Read the winbar text itself, in
-- BOTH directions: it must appear while queued and disappear once cleared.
wt.open("tests/fixtures/two_files.tour")
wt.ask()
local real_send2 = channel.send
channel.send = function(_path, _payload) return false, "no_reader", "no agent is listening" end
dialog.submit("does anyone answer?")
channel.send = real_send2
T.ok(dialog.pending() ~= nil, "the question is queued")
local winbar = function() return tostring(vim.wo[dialog.winid()].winbar) end
T.ok(winbar():find("queued", 1, true) ~= nil,
  "and the winbar says so while it is queued")
dialog.cancel_pending(true)
T.ok(dialog.pending() == nil, "the queue is cleared")
T.ok(winbar():find("queued", 1, true) == nil,
  "and the winbar stops saying so once cleared")

-- Review round 2, Minor — M.close left the spinner's uv timer running: capture
-- the actual timer handle M.mark_waiting creates and check IT directly, rather
-- than trusting that W being nil afterward says anything about whether its
-- OLD timer was ever stopped.
local uv = vim.uv or vim.loop
local captured_timer
local real_new_timer = uv.new_timer
uv.new_timer = function(...)
  captured_timer = real_new_timer(...)
  return captured_timer
end
dialog.issued["n2"] = { step = "s", index = 1, answered = false }
dialog.mark_waiting("n2")
uv.new_timer = real_new_timer
T.ok(captured_timer ~= nil and captured_timer:is_active(),
  "the spinner timer is running while waiting")
dialog.close()
T.ok(not captured_timer:is_active(), "and M.close stops it")
wt.close()

-- ---------------------------------------------------------------------------
-- Whole-branch review, F1 (Critical) — the walkthrough is DRIVEN while the
-- dialog is up.
--
-- That is the ordinary case, not an exotic one: SKILL.md § 8 tells the
-- answering agent to run `walkthrough step +1` as soon as it has answered, and
-- the reader is sitting in the dialog window the whole time -- `dialog.open`
-- leaves it current and in insert mode. Every suite before this one tested the
-- dialog in isolation, so nothing here was covered.
--
-- Identical-if-broken: an assertion on `dialog.is_open()` alone PASSED on the
-- broken build. is_open() returned true while the dialog's window displayed a
-- code file, the transcript buffer orphaned in no window. So every assertion
-- below is on something the reader can see or do: which buffer each window
-- holds, that an answer lands, and that the two CLI verbs report what really
-- happened rather than the opposite.
-- ---------------------------------------------------------------------------
local function transcript()
  return table.concat(vim.api.nvim_buf_get_lines(dialog.bufnr(), 0, -1, false), "\n")
end
local function win_file(win)
  return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
end

dialog.ANSWER_TIMEOUT_MS = 300000  -- the P7 block above shortened it
wt.open("tests/fixtures/two_files.tour")
local f1_code_win = vim.api.nvim_get_current_win()
wt.ask()
local f1_buf, f1_win = dialog.bufnr(), dialog.winid()
T.eq(vim.api.nvim_get_current_win(), f1_win,
  "the reader is left in the dialog window, which is where a step finds them")

wt.step(1)  -- exactly what `walkthrough step +1` evaluates in the player

T.eq(vim.api.nvim_win_get_buf(f1_win), f1_buf,
  "after a step the dialog window still displays the transcript")
T.ok(dialog.is_open(), "...and the dialog is still open")
T.ok(win_file(f1_code_win):find("beta.txt", 1, true) ~= nil,
  "...the step was drawn in the CODE window")
T.eq(vim.api.nvim_get_current_win(), f1_win,
  "...and the reader's focus was not yanked out of the line they are typing in")
T.ok(tostring(vim.wo[f1_code_win].winbar):find("ask ", 1, true) == nil,
  "...the code window did not sprout the dialog's winbar")
T.ok(not vim.iter(vim.api.nvim_buf_get_keymap(f1_buf, "n")):any(function(m)
  return m.lhs == "]w"
end), "...and the step keys were not attached to the dialog's prompt buffer")

local f1_appended = pcall(dialog.append, { "agent: written after the step" }, nil)
T.ok(f1_appended, "append does not raise after a step")
T.ok(transcript():find("written after the step", 1, true) ~= nil, "...and lands in the transcript")

-- The two CLI verbs. Both used to exit 1 with an internal "Invalid cursor line:
-- out of range" -- `answer` for an answer the reader never saw, and `reload`
-- AFTER the reload had fully succeeded. A status that contradicts what happened
-- is worse than either failure.
dialog.issued["f1"] = { step = "first", index = 1, answered = false }
local f1_ans_ok, f1_ans_err = pcall(wt._answer, "f1", "the answer the reader must see")
T.ok(f1_ans_ok, "`walkthrough answer` succeeds after a step: " .. tostring(f1_ans_err))
T.ok(transcript():find("the answer the reader must see", 1, true) ~= nil,
  "...and the reader can actually see it")
local f1_rl_ok, f1_rl_err = pcall(wt.reload, "tests/fixtures/two_files.tour")
T.ok(f1_rl_ok, "`walkthrough reload` reports the success it really had: " .. tostring(f1_rl_err))
T.ok(wt.state().active, "...and the walkthrough is still active afterwards")
wt.close()

-- The identity check needs a case of its own. nav no longer draws into the
-- dialog's window, so nothing in the block above can reach the mismatch any
-- more -- but anything else in the editor still can: a `:buffer` typed in that
-- window, another plugin, a future caller of nav that forgets. The property is
-- that the dialog NOTICES and recovers, rather than insisting it is open while
-- displaying a code file and raising out of the next answer.
wt.open("tests/fixtures/two_files.tour")
local f1b_code_buf = vim.api.nvim_get_current_buf()
wt.ask()
local f1b_buf = dialog.bufnr()
vim.api.nvim_win_set_buf(dialog.winid(), f1b_code_buf)  -- something takes the window
T.ok(not dialog.is_open(),
  "a dialog window that has been retargeted at another buffer is not open")
wt.ask()
T.ok(dialog.is_open(), "...and <leader>aa brings the dialog back")
T.eq(vim.api.nvim_win_get_buf(dialog.winid()), f1b_buf,
  "...into a window that really is displaying the transcript")
T.eq(dialog.bufnr(), f1b_buf, "...and it is the same transcript")
dialog.issued["f1b"] = { step = "first", index = 1, answered = false }
local f1b_ok, f1b_err = pcall(wt._answer, "f1b", "delivered after the window was taken")
T.ok(f1b_ok, "an answer after a retargeted window still succeeds: " .. tostring(f1b_err))
T.ok(transcript():find("delivered after the window was taken", 1, true) ~= nil,
  "...and the reader can see it")
wt.close()

-- ---------------------------------------------------------------------------
-- F2 (Critical) — the dialog can be dismissed and reopened, repeatedly.
--
-- bufhidden=hide plus a fixed buffer name meant `:q` left the buffer alive with
-- its name claimed, so the NEXT <leader>aa raised E95 from
-- nvim_buf_set_name -- after the split had already been created, which left
-- S.win on the new window and S.buf on the old buffer: F1's corrupt state,
-- reached from the one key a reader actually reaches for.
--
-- Identical-if-broken: `pcall(wt.ask)` returning true is not enough on its own
-- (a version that silently built a second, empty transcript would pass), so the
-- buffer identity and the surviving text are asserted too.
-- ---------------------------------------------------------------------------
wt.open("tests/fixtures/two_files.tour")
wt.ask()
local f2_buf = dialog.bufnr()
dialog.append({ "you: asked before dismissing it" }, nil)
T.ok(vim.iter(vim.api.nvim_buf_get_keymap(f2_buf, "n")):any(function(m) return m.lhs == "q" end),
  "the dialog buffer carries a documented dismiss binding")

-- Pressed as a KEYSTROKE (`:normal` honours mappings), not by calling the
-- callback: the binding being reachable is half of what is being fixed.
vim.api.nvim_set_current_win(dialog.winid())
vim.cmd("normal q")
T.ok(not dialog.is_open(), "pressing it dismisses the dialog")
T.eq(vim.api.nvim_buf_is_valid(f2_buf), true, "...and keeps the transcript buffer alive")

local f2_reopened = pcall(wt.ask)
T.ok(f2_reopened, "the next <leader>aa reopens it (this raised E95)")
T.ok(dialog.is_open(), "...and the dialog really is open")
T.eq(dialog.bufnr(), f2_buf, "...it is the SAME transcript, not a fresh empty one")
T.eq(vim.api.nvim_win_get_buf(dialog.winid()), f2_buf,
  "...and its window is displaying it")
T.ok(transcript():find("asked before dismissing it", 1, true) ~= nil,
  "...with the conversation still in it")

-- The other spelling, and a second cycle: E95 only bit on a reopen, so once is
-- not a test of "repeatedly".
vim.api.nvim_set_current_win(dialog.winid())
vim.cmd("quit")
T.ok(not dialog.is_open(), ":q dismisses it too")
dialog.issued["f2"] = { step = "first", index = 1, answered = false }
T.ok(dialog.answer("f2", "answered while you were not looking"),
  "an answer that lands while it is dismissed is accepted")
local f2_again = pcall(wt.ask)
T.ok(f2_again, "...and it reopens a second time")
T.eq(dialog.bufnr(), f2_buf, "...still the same transcript")
T.ok(transcript():find("answered while you were not looking", 1, true) ~= nil,
  "...and the answer was kept, not dropped on the floor")
wt.close()

-- Configurable and disablable, like every other binding.
require("walkthrough").setup({ keys = { dialog_close = "" } })
wt.open("tests/fixtures/two_files.tour")
wt.ask()
T.ok(not vim.iter(vim.api.nvim_buf_get_keymap(dialog.bufnr(), "n")):any(function(m)
  return m.lhs == "q"
end), 'keys.dialog_close = "" disables it')
wt.close()
require("walkthrough").setup({ keys = { dialog_close = "Q" } })
wt.open("tests/fixtures/two_files.tour")
wt.ask()
T.ok(vim.iter(vim.api.nvim_buf_get_keymap(dialog.bufnr(), "n")):any(function(m)
  return m.lhs == "Q"
end), "...and it is configurable through setup{keys=...}")
-- Nothing of the dialog's leaks onto a code buffer: the default is a bare `q`.
wt.close()
require("walkthrough").setup({ keys = { dialog_close = "q" } })
wt.open("tests/fixtures/two_files.tour")
T.ok(not vim.iter(vim.api.nvim_buf_get_keymap(vim.api.nvim_get_current_buf(), "n")):any(
  function(m) return m.lhs == "q" end),
  "the dismiss key is never bound on a code buffer")
wt.close()

T.done()
