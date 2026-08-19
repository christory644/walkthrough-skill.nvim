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

-- Re-review, regression 1 — the step must not be drawn into a window that is
-- not a code window. `code_window` returned the first window in tabpage order
-- that was not the dialog, and this plugin PUTS something at the top-left: the
-- quickfix list is the tour's own table of contents (`:copen` is in the README's
-- key table, and `nav.is_our_qflist` exists because readers have it open). With
-- the list open and the reader in the dialog, `walkthrough step +1` drew the
-- step over the LIST and parked the cursor in it, while the code window still
-- showed the previous step. A file-tree sidebar is the same shape.
--
-- Identical-if-broken: asserting only that the code window ends up on beta.txt
-- would pass on a build that ALSO scribbled on the quickfix window, so both
-- windows are asserted -- the one that must change, and the one that must not.
-- One window to start from: the blocks above deliberately leave orphaned
-- windows still showing tour buffers, and with two equally valid code windows
-- this assertion would be about which one nav happened to pick rather than
-- about the quickfix window it must not pick.
vim.cmd("only")
wt.open("tests/fixtures/two_files.tour")
local qf_code_win = vim.api.nvim_get_current_win()
vim.cmd("topleft copen")
local qf_win = vim.api.nvim_get_current_win()
local qf_buf = vim.api.nvim_win_get_buf(qf_win)
T.eq(vim.bo[qf_buf].buftype, "quickfix", "the tour's table of contents is open")
vim.api.nvim_set_current_win(qf_code_win)
wt.ask()                                  -- the reader is now in the dialog
T.eq(vim.api.nvim_get_current_win(), dialog.winid(), "...and the dialog has the focus")
wt.step(1)                                -- the agent's `walkthrough step +1`
T.eq(vim.api.nvim_win_get_buf(qf_win), qf_buf,
  "the quickfix window still holds the quickfix list, not the step")
T.eq(vim.bo[vim.api.nvim_win_get_buf(qf_win)].buftype, "quickfix",
  "...and it is still a quickfix window")
T.ok(win_file(qf_code_win):find("beta.txt", 1, true) ~= nil,
  "...the step landed in the code window")
T.eq(vim.api.nvim_win_get_buf(dialog.winid()), dialog.bufnr(),
  "...and the dialog still shows the transcript")
vim.cmd("cclose")
wt.close()

-- Re-review, regression 2 — `dialog_close` bindings must not accumulate.
--
-- The dialog's buffer is reused across a dismissal, and attach_dialog only ever
-- SET the binding: a default open then a rebind left both keys live, and `""`
-- (this key table's documented way to disable a binding) disabled nothing --
-- the old key still dismissed. Asserted on a REUSED buffer for exactly that
-- reason: a fresh buffer passes either way, so the fresh-buffer assertions
-- earlier in this file cannot catch it.
require("walkthrough").setup({ keys = { dialog_close = "q" } })
wt.open("tests/fixtures/two_files.tour")
wt.ask()
local reused = dialog.bufnr()
local dismiss_keys = function()
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(reused, "n")) do
    if tostring(m.desc or ""):find("dismiss the dialog", 1, true) then
      table.insert(out, m.lhs)
    end
  end
  table.sort(out)
  return out
end
local redismiss = function()
  vim.api.nvim_set_current_win(dialog.winid())
  vim.cmd("quit")
end
T.eq(dismiss_keys(), { "q" }, "the default binding is on the dialog buffer")
redismiss()
require("walkthrough").setup({ keys = { dialog_close = "Z" } })
wt.ask()
T.eq(dialog.bufnr(), reused, "the reopened dialog is the same, reused buffer")
T.eq(dismiss_keys(), { "Z" }, "rebinding REPLACES the old key rather than adding to it")
redismiss()
require("walkthrough").setup({ keys = { dialog_close = "" } })
wt.ask()
T.eq(dialog.bufnr(), reused, "...still the same buffer")
T.eq(dismiss_keys(), {}, '...and "" really leaves nothing bound')
wt.close()
require("walkthrough").setup({ keys = { dialog_close = "q" } })

-- ---------------------------------------------------------------------------
-- F3 (Important) — two questions in flight.
--
-- W was a single slot and mark_waiting stopped the previous watchdog, so the
-- FIRST question lost its clock the moment a second was sent: it reached no
-- terminal state ever, and its answer arrived under a bare "agent:" that the
-- reader reads as answering the question they asked LAST. Two in flight is
-- ordinary -- OQ-3 keeps a question that found no reader and auto-sends it when
-- one attaches, which is exactly when another has already been typed.
--
-- The questions are asked on DIFFERENT steps on purpose: with both on the same
-- step, "the answer names its own step" and "the answer names the step the
-- reader is on" are the same string, and the assertion could not fail.
-- ---------------------------------------------------------------------------
local function two_in_flight()
  local sent = {}
  local real = channel.send
  channel.send = function(_p, payload) table.insert(sent, vim.json.decode(payload)) return true end
  wt.ask()
  dialog.submit("Q1: why is this step here?")
  wt.step(1)
  wt.ask()  -- rescope to step 2, as the reader moving on does
  dialog.submit("Q2: and what about this one?")
  channel.send = real
  return sent
end

dialog.ANSWER_TIMEOUT_MS = 300000
wt.open("tests/fixtures/two_files.tour")
local sent = two_in_flight()
T.eq(#sent, 2, "both questions were sent")
T.eq(sent[1].index, 1, "Q1 was asked on step 1")
T.eq(sent[2].index, 2, "Q2 was asked on step 2")

dialog.answer(sent[1].nonce, "because it introduces the retry.")
local f3_body = transcript()
T.ok(f3_body:find(string.format('agent (step %s, "%s"):', sent[1].index, sent[1].step_id), 1, true) ~= nil,
  "Q1's answer names the step Q1 was asked on")
T.ok(f3_body:find(string.format('"%s"', sent[2].step_id), 1, true) == nil,
  "...and nothing in it points at the step the reader has moved on to")
wt.close()

-- Every issued question reaches a terminal state, including one that a later
-- question displaced from the spinner.
wt.open("tests/fixtures/two_files.tour")
sent = two_in_flight()
dialog.ANSWER_TIMEOUT_MS = 200
local q1, q2 = sent[1].nonce, sent[2].nonce
vim.wait(3000, function()
  return dialog.issued[q1].timed_out and dialog.issued[q2].timed_out
end, 50)
T.ok(dialog.issued[q1].timed_out, "the FIRST question times out (its watchdog was destroyed)")
T.ok(dialog.issued[q2].timed_out, "and so does the second")
local f3_timeouts = transcript()
T.ok(f3_timeouts:find(string.format('stopped waiting on step %s, "%s"', sent[1].index, sent[1].step_id),
  1, true) ~= nil, "the transcript says which question was abandoned, by step, for Q1")
T.ok(f3_timeouts:find(string.format('stopped waiting on step %s, "%s"', sent[2].index, sent[2].step_id),
  1, true) ~= nil, "...and for Q2")
T.ok(tostring(vim.wo[dialog.winid()].winbar):find("idle", 1, true) ~= nil,
  "with nothing left outstanding the winbar goes back to idle")

-- ...and an answer arriving after that is marked late AND names its own step,
-- which is OQ-4's binding ruling.
dialog.answer(q1, "an answer nobody was waiting for any more")
local f3_late = transcript()
T.ok(f3_late:find(string.format('late — this answers step %s, "%s"', sent[1].index, sent[1].step_id),
  1, true) ~= nil, "a late answer is marked late and names the step it answers")
dialog.ANSWER_TIMEOUT_MS = 300000
wt.close()

-- ---------------------------------------------------------------------------
-- D2 (implementation-plan report) — a dialog left open across a step
-- describes the step the reader IS on, not the one they opened it on.
--
-- dialog_ctx() used to be computed only at M.ask()/M.reload() time and never
-- again: state.index kept moving (M.goto_step, the ordinary path for `]w`,
-- `<leader>an/ap`, and the CLI's `walkthrough step`) while S.ctx froze at
-- whatever it was when the dialog was last opened or reloaded. A question
-- typed into an already-open dialog was then tagged with the WRONG step, and
-- the winbar told the same lie.
--
-- Identical-if-broken: `wt.state().index` moving is not what was ever in
-- doubt. Assert the OUTBOUND PAYLOAD (what the agent actually receives, via
-- the same channel.send stub P4/reload's `sent_tour` block above uses) and the
-- winbar (what the reader actually sees) -- the two places the stale value
-- above was read from.
-- ---------------------------------------------------------------------------
local function sent_payload(question)
  local real_send = channel.send
  local payload
  channel.send = function(_path, p) payload = p return true end
  dialog.submit(question)
  channel.send = real_send
  return payload and vim.json.decode(payload) or nil
end

wt.open("tests/fixtures/two_files.tour")
wt.ask()    -- dialog opens scoped to step 1, "first" -- and is never reopened below
wt.step(1)  -- step 2
wt.step(1)  -- step 3, "back again"
local d2 = sent_payload("where am I now?")
T.eq(wt.state().index, 3, "the walkthrough really is on step 3")
T.eq(d2.index, 3, "the question is tagged with the CURRENT step, not the one the dialog opened on")
T.eq(d2.step_id, wt.state().id, "...and the step_id agrees")
local d2_winbar = tostring(vim.wo[dialog.winid()].winbar)
T.ok(d2_winbar:find(wt.state().id, 1, true) ~= nil,
  "the winbar also tracks the current step, not a stale one")
T.ok(d2_winbar:find("3/3", 1, true) ~= nil, "...by position too")
wt.close()

-- ...and the same holds for the path SKILL.md § 8 actually tells the
-- answering agent to take: `walkthrough step +1` right after answering, with
-- the reader sitting in the dialog the whole time -- the ordinary case, not an
-- edge one.
wt.open("tests/fixtures/two_files.tour")
wt.ask()
dialog.issued["d2b"] = { step = wt.state().id, index = wt.state().index, answered = false }
wt._answer("d2b", "you're on step 1")
wt.step(1)  -- the agent's own `walkthrough step +1`
local d2b = sent_payload("and now?")
T.eq(d2b.index, 2, "after the agent's own step +1, a new question is tagged step 2")
wt.close()

-- ---------------------------------------------------------------------------
-- D3 (implementation-plan report) — a question typed at the prompt must not
-- be echoed twice.
--
-- buftype=prompt commits the just-typed line into the buffer as fixed history
-- the INSTANT Enter fires -- before prompt_setcallback's own function body
-- ever runs (measured) -- and M.send_now separately appends its own
-- "you: ..." line once the send is known to have gone through. Every
-- assertion above this one reaches M.submit by calling dialog.submit()
-- directly from Lua, which never passes through nvim's commit machinery at
-- all -- so none of them can see this defect; it only exists on the path a
-- REAL keystroke takes. This drives that path: nvim_feedkeys into the
-- dialog's own window, never dialog.submit(), or it proves nothing.
-- ---------------------------------------------------------------------------
-- <Esc> and "A<text><CR>" are fed as TWO separate nvim_feedkeys calls, not
-- one: fed together, nvim's terminal input parsing reads <Esc>A as a single
-- meta-keystroke (many terminals send Alt-A that way) rather than "leave
-- insert mode, then append" -- measured, the giveaway being the callback
-- receiving literal text "A" (or, with a real question after it, missing the
-- question's own first character to the same coalescing). A short vim.wait
-- between the two keeps them from being read as one.
local function type_and_enter(text)
  vim.api.nvim_set_current_win(dialog.winid())
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
  vim.wait(30)
  vim.api.nvim_feedkeys(
    vim.api.nvim_replace_termcodes("A" .. text .. "<CR>", true, false, true), "x", false)
  vim.wait(200)
end

local function count_lines_containing(buf, needle)
  local n = 0
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l:find(needle, 1, true) then n = n + 1 end
  end
  return n
end

wt.open("tests/fixtures/two_files.tour")
wt.ask()
local real_send3 = channel.send
channel.send = function(_p, _payload) return true end
type_and_enter("and what stops a hostile answer running as lua")
channel.send = real_send3

local NEEDLE = "hostile answer running as lua"
T.eq(count_lines_containing(dialog.bufnr(), NEEDLE), 1,
  "a typed question appears in the transcript exactly once, not twice")
T.ok(vim.iter(vim.api.nvim_buf_get_lines(dialog.bufnr(), 0, -1, false)):any(function(l)
  return l:match("^you: ") ~= nil and l:find(NEEDLE, 1, true) ~= nil
end), "...and the surviving line is OUR controlled echo, prefixed \"you: \"")
wt.close()

-- Refused-and-queued: the text is written back into the (now editable) prompt
-- line so the reader can cancel or edit it -- see M.on_refused -- and that
-- must be the ONLY place it appears while queued, not also sitting in
-- history.
wt.open("tests/fixtures/two_files.tour")
wt.ask()
local real_send4 = channel.send
channel.send = function(_p, _payload) return false, "no_reader", "no agent is listening" end
type_and_enter("does anyone answer this one")
channel.send = real_send4

T.eq(count_lines_containing(dialog.bufnr(), "does anyone answer this one"), 1,
  "a refused-and-queued question also appears exactly once (in the editable prompt line)")
dialog.cancel_pending(true)
wt.close()

-- A plain, empty Enter leaves no orphan history line of its own either.
wt.open("tests/fixtures/two_files.tour")
wt.ask()
local before_blank = vim.api.nvim_buf_line_count(dialog.bufnr())
type_and_enter("")
T.eq(vim.api.nvim_buf_line_count(dialog.bufnr()), before_blank,
  "an empty Enter changes nothing in the transcript")
wt.close()

-- ---------------------------------------------------------------------------
-- Review, Important — the control-character refusal must leave the reader's
-- text RECOVERABLE, matching the no-reader refusal's model (M.on_refused,
-- tested above), rather than a bare prompt line and a generic warning.
--
-- Real control bytes (SOH, ESC) cannot be produced by feeding ordinary
-- termcodes through nvim_feedkeys in insert mode: a raw \1 there is Ctrl-A,
-- an insert-mode COMMAND ("insert previously inserted text"), not a literal
-- character -- feeding it would test nvim's own keymap, not this code. A
-- paste bypasses that: the bytes land in the buffer as text, not as key
-- commands. So this sets the (still-editable) prompt line's content directly
-- -- exactly what a paste leaves behind -- and drives the ACTUAL Enter
-- keypress through nvim_feedkeys, which is what reaches M.submit(text, true)
-- for real. A test that called dialog.submit() with a Lua string containing
-- "\1" would prove nothing about this path: D3's history-deletion runs only
-- when from_keystroke is true, and that is exactly the interaction under
-- test here (the regression D3 introduced).
-- ---------------------------------------------------------------------------
local function paste_and_enter(raw_line)
  local buf = dialog.bufnr()
  local win = dialog.winid()
  local last = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_set_lines(buf, last - 1, last, false, { raw_line })
  vim.api.nvim_win_set_cursor(win, { last, #raw_line })
  vim.api.nvim_set_current_win(win)
  vim.cmd("startinsert!")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  vim.wait(200)
end

wt.open("tests/fixtures/two_files.tour")
wt.ask()
-- \1 (SOH) and \27 (ESC) are in the rejected class. No \n/\r here on purpose:
-- a single nvim buffer LINE cannot hold a raw \n at all (that byte is the
-- line separator itself -- nvim_buf_set_lines refuses one embedded in an
-- element, which is exactly why the fix cannot just restore raw text
-- verbatim), so a real paste landing in one prompt line structurally cannot
-- carry one either. That combination is tested separately below, the one way
-- it actually is reachable: the public M.submit API, called programmatically.
paste_and_enter("> bad\1question\27here")

local cc_lines = vim.api.nvim_buf_get_lines(dialog.bufnr(), 0, -1, false)
T.ok(vim.iter(cc_lines):any(function(l)
  return l:find("cannot contain control characters", 1, true) ~= nil
end), "the rejection is still announced")
T.eq(cc_lines[#cc_lines], "> badquestionhere",
  "...and the CLEANED text -- control bytes gone -- is back in the editable "
  .. "prompt line, not lost")
T.ok(not vim.iter(cc_lines):any(function(l) return l:find("\1", 1, true) ~= nil end),
  "...no raw control byte survives anywhere in the buffer")

-- One Enter away, as the message promises: pressing it again actually sends
-- the cleaned question, exactly once, with no leftover echo of the rejection.
local real_send5 = channel.send
local cc_payload
channel.send = function(_p, payload) cc_payload = payload return true end
vim.cmd("startinsert!")
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
vim.wait(200)
channel.send = real_send5

T.ok(cc_payload ~= nil, "the cleaned question sends successfully on the next Enter")
T.eq(cc_payload and vim.json.decode(cc_payload).question, "badquestionhere",
  "...carrying exactly the cleaned text")
T.eq(count_lines_containing(dialog.bufnr(), "badquestionhere"), 1,
  "...and lands in the transcript exactly once")
wt.close()

-- Consistency, in both directions: a no-reader refusal (existing coverage,
-- above) and a control-character refusal now share the same shape -- the
-- reader's text ends up back in the editable prompt line either way.
wt.open("tests/fixtures/two_files.tour")
wt.ask()
paste_and_enter("> another\1bad\27one")
local cc2_lines = vim.api.nvim_buf_get_lines(dialog.bufnr(), 0, -1, false)
T.eq(cc2_lines[#cc2_lines], "> anotherbadone",
  "a second control-character refusal restores its own cleaned text the same way")
dialog.cancel_pending(true)
wt.close()

-- The \n/\r-flattening branch: only reachable programmatically (a real
-- keystroke's `text` can never contain \n -- see above), but M.submit is a
-- public interface (Task 7's own doc comment says so) and must not raise
-- when a caller combines a rejected control byte with a legitimate embedded
-- newline. Asserted on the restored prompt line rather than on the message,
-- since a raise inside M.submit is exactly what nvim_buf_set_lines would do
-- if the restore tried to keep the newline verbatim.
wt.open("tests/fixtures/two_files.tour")
wt.ask()
local nl_ok = pcall(dialog.submit, "bad\1question\27with\nnewline\rhere")
T.ok(nl_ok, "a control-character question that also carries \\n does not raise")
local nl_lines = vim.api.nvim_buf_get_lines(dialog.bufnr(), 0, -1, false)
T.eq(nl_lines[#nl_lines], "> badquestionwith newline here",
  "...and the embedded newline and CR are each flattened to a space so the "
  .. "single-line prompt can hold the cleaned text")
wt.close()

T.done()
