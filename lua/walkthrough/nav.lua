local tour   = require("walkthrough.tour")
local render = require("walkthrough.render")

local M = {}

-- What a dropped step's quickfix entry says once it is known to be unplayable,
-- appended to the title the entry already had. See mark_dropped_in_qflist.
local DROPPED = "— DROPPED: this step could not be played"

-- How a step titles its quickfix entry. Written once, because
-- mark_dropped_in_qflist finds an entry by this exact text: if the two
-- spellings drifted, a demoted step would quietly stop being marked.
local function entry_prefix(t, i)
  local s = t.steps[i]
  return string.format("[%d/%d] %s — ", i, #t.steps, s.title or ("step " .. i))
end

-- The quickfix list IS the narrative: ordered, crosses files, and gives
-- :cnext/:cprev/:copen for free.
--
-- A step located by `pattern` (the form the tour format prefers) has no
-- known line until a buffer is loaded, and we must not eagerly load every
-- file in a tour just to populate an overview list. Vim's quickfix format
-- already solves this: an item may carry a `pattern` field instead of
-- `lnum`, and vim searches for it lazily when the entry is jumped to.
--
-- `on_drop(i, why)` is how this reports a step it cannot list, and it is the
-- same hook `render.apply` takes, for the same reason. This was the one
-- step-field consumer with no pcall and no drop path, and being the last one
-- unguarded is exactly what made it the place the class kept resurfacing: a
-- `line` of 1e30 (integral, so it passed the guard below, but too big for
-- int64) and a NUL in `title` (a string, so it passed every type check we had,
-- but not one vimscript can hold) each raised out of here and took the whole
-- `open` down with them, banner already printed.
--
-- Entries are therefore added ONE AT A TIME, each under pcall. That is not
-- ceremony: the raise does not happen while the item table is built -- it
-- happens inside `setqflist`, when the item crosses into vimscript -- so a
-- pcall around the construction would have caught nothing. Whatever the field
-- and whatever the conversion, the step that carries it is demoted and named,
-- and the rest of the list is built.
function M.populate(t, on_drop)
  -- The title crosses the same boundary; a list we cannot title still has to
  -- exist, and its title still has to start with "walkthrough: " or
  -- mark_dropped_in_qflist will (correctly) refuse to touch it later.
  if not pcall(vim.fn.setqflist, {}, " ", { title = "walkthrough: " .. t.title, items = {} }) then
    vim.fn.setqflist({}, " ", { title = "walkthrough: ", items = {} })
  end

  -- The entries vim has actually accepted, kept in Lua so a failed append can
  -- be undone without asking vim for a list it has just half-written.
  local accepted = {}

  for i, s in ipairs(t.steps) do
    if s.playable then
      local item
      local added, why = pcall(function()
        local first = vim.split(s.description, "\n", { plain = true })[1] or ""
        item = {
          filename = s.abspath,
          col = 1,
          text = entry_prefix(t, i) .. first,
        }
        -- Only a whole number vim can hold can be an `lnum`: it raises E805 on
        -- a float and on anything past int64, and this list is built from the
        -- tour alone -- no file has been read yet, so nothing here can know the
        -- line is also within the file. A step whose `line` is not a real
        -- position gets neither field and is demoted by the lazy resolve when
        -- the reader reaches it.
        if type(s.line) == "number" then
          if not tour.line_problem(s.line) then item.lnum = s.line end
        elseif type(s.pattern) == "string" then
          item.pattern = s.pattern
        end
        vim.fn.setqflist({ item }, "a")
      end)
      if added then
        table.insert(accepted, item)
      else
        -- setqflist converts an item field by field and can fail PART WAY
        -- through one: a NUL in `text` raises after the entry, with its line
        -- and its file, is already in the list. Left there it is a quickfix
        -- entry with no text, pointing at a step the reader has just been told
        -- was dropped. So the list is put back to the entries vim accepted
        -- whole.
        vim.fn.setqflist({}, "r", { items = accepted })
        if on_drop then
          on_drop(i, string.format("this step cannot be listed: %s", tostring(why)))
        end
      end
    end
  end
end

-- Exact-path buffer lookup. `vim.fn.bufnr(path)` treats a string argument as
-- a pattern and can match an unrelated buffer whose name merely contains
-- `path` as a substring (e.g. "alpha.txt.bak") -- a single such match fails
-- open instead of failing closed. `bufadd` matches (or creates) a buffer for
-- exactly that name.
local function buffer_for(abspath)
  local bufnr = vim.fn.bufadd(abspath)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    vim.fn.bufload(bufnr)
  end
  return bufnr
end

-- Find the nearest playable step to `i`, expanding outward (forward first,
-- then backward, at each radius) so a request that lands on a non-playable
-- step still resolves to real content instead of crashing on a nil abspath.
-- Returns nil if the tour has no playable step at all.
local function nearest_playable(t, i)
  local n = #t.steps
  for d = 0, n - 1 do
    local hi, lo = i + d, i - d
    if hi <= n and t.steps[hi].playable then return hi end
    if lo >= 1 and t.steps[lo].playable then return lo end
  end
  return nil
end

-- A step that named a file and a location LOOKED playable at load time, and
-- that is all `tour.validate` can tell: whether the location is really there
-- is a question about the file's CONTENTS. Answering it early would mean
-- reading every file in the tour up front -- a fifty-file walkthrough loading
-- fifty buffers, which is exactly what populate() above was written to avoid.
--
-- So it is answered HERE, at the one moment it comes for free: we have just
-- loaded this step's buffer because we were about to show it. If the step does
-- not resolve against that buffer it is demoted to unplayable, joins the
-- skipped list, and gets the same treatment a missing file gets -- rather than
-- being displayed with the cursor left on line 1 and no narration, which is
-- what used to happen, in silence.
--
-- The quickfix list is the reader's OTHER view of the same narrative, and it
-- was built (above) before anyone could know this step was unplayable. Left
-- alone, its entry lies: `:cc 2` onto a dropped step finds no match for the
-- pattern, silently lands the cursor on line 1, and still announces
-- "(2 of 3): [2/3] rotted" -- the reader is told they are on the step they
-- asked for while sitting on a different one, with no error of any kind. So
-- the entry is retitled where it stands. In place, not by repopulating: a
-- fresh setqflist would throw away the reader's position in the list, which is
-- a worse thing to do to someone mid-tour than the stale title was.
local function mark_dropped_in_qflist(t, i)
  local qf = vim.fn.getqflist({ items = 0, title = 0, idx = 0 })
  -- Only ever edit OUR list. The reader may have replaced the quickfix list
  -- with their own (a grep, a build); rewriting an entry in that one would be
  -- vandalism.
  if type(qf.title) ~= "string" or qf.title:sub(1, 13) ~= "walkthrough: " then return end
  local prefix = entry_prefix(t, i)
  for _, item in ipairs(qf.items or {}) do
    if type(item.text) == "string" and item.text:sub(1, #prefix) == prefix
      and not item.text:find(DROPPED, 1, true) then
      item.text = item.text .. "  " .. DROPPED
      vim.fn.setqflist({}, "r", { items = qf.items, title = qf.title, idx = qf.idx })
      return
    end
  end
end

-- Why a step that named a location did not resolve to one. A `line` and a
-- `pattern` fail for different reasons and the reader has to be told which:
-- "pattern /nil/ matches nothing" is what a line step used to say here, which
-- names a field the step does not even have.
local function unresolved(t, i, bufnr)
  local s = t.steps[i]
  if type(s.line) == "number" then
    return string.format("%s in %s",
      tour.line_problem(s.line, vim.api.nvim_buf_line_count(bufnr)) or "line cannot be resolved",
      tostring(s.file))
  end
  return string.format("pattern /%s/ matches nothing in %s", tostring(s.pattern), tostring(s.file))
end

function M.demote(state, t, i, why)
  t.steps[i].playable = false
  if state and state.skipped then table.insert(state.skipped, tour.step_id(t, i)) end
  mark_dropped_in_qflist(t, i)
  vim.api.nvim_echo({ { string.format("walkthrough: skipping step %d (%s): %s",
    i, tour.step_id(t, i), why), "WarningMsg" } }, true, {})
end

function M.goto_index(state, i)
  local t = state.tour
  i = math.max(1, math.min(#t.steps, i))

  -- Loop rather than recurse: every pass either lands or demotes exactly one
  -- step, so it runs at most #steps times and cannot spin.
  while true do
    local target = nearest_playable(t, i)
    if not target then return state.index end
    local s = t.steps[target]

    -- Resolve BEFORE switching to the buffer. A step we are about to drop
    -- should not first be displayed: showing the file and then jumping
    -- elsewhere is how the reader loses track of where they are.
    local bufnr = buffer_for(s.abspath)
    local ok, line = pcall(tour.resolve, s, bufnr)
    if not ok then
      M.demote(state, t, target,
        string.format("pattern /%s/ is not a valid vim regex", tostring(s.pattern)))
    elseif not line then
      M.demote(state, t, target, unresolved(t, target, bufnr))
    else
      if vim.api.nvim_get_current_buf() ~= bufnr then
        vim.cmd("buffer " .. bufnr)
      end

      -- Drawing this buffer touches every OTHER step in it too, any of which
      -- may carry a pattern that is not a regex at all, or a field of a shape
      -- that cannot be drawn. Those are demoted through the same path as the
      -- one above rather than thrown.
      render.apply(bufnr, t, target, function(j, why) M.demote(state, t, j, why) end)

      -- ...including THIS step, whose own draw is what may have failed. A step
      -- demoted while being drawn has already been reported as dropped, so
      -- parking on it and announcing it would contradict the report the reader
      -- just saw. Keep looking instead; the loop terminates because every pass
      -- through it demotes at least one more step.
      if not s.playable then
        i = target
      else
        state.index = target
        render.park(0, bufnr, line)
        vim.bo[bufnr].modifiable = false

        vim.api.nvim_echo({ { string.format("  [%d/%d] %s", target, #t.steps,
          type(s.title) == "string" and s.title or ""), "ModeMsg" } }, false, {})
        return target
      end
    end
  end
end

return M
