local M = {}

-- The largest number vim will accept as a line. `linenr_T` is a 32-bit signed
-- int, so this is not a house rule: past it, `nvim_win_set_cursor` refuses
-- ("Invalid cursor line: out of range") and, well before that, a value too big
-- for int64 reaches `setqflist` as a Float and raises E805. A `line` beyond
-- this is not a position in any file, which is the only thing a `line` can be.
M.MAX_LINE = 2147483647

-- What is wrong with a string a step hands to vim -- or nil when nothing is.
--
-- Every drawable string crosses into VIMSCRIPT somewhere: `title` and
-- `description` become a quickfix entry's `text`, `pattern` becomes its
-- `pattern`, `file` goes through `fnamemodify` and `filereadable`. Vimscript
-- has no string type that can hold a NUL: the conversion produces a Blob and
-- the call raises E976. `vim.json.decode` will happily hand us one, because
-- `"\u0000"` is legal JSON -- so `type(x) == "string"` is NOT the whole
-- question, and asking only that is how a NUL in `title` used to kill an entire
-- `open` on a tour `validate` had just exited 0 on.
--
-- Nothing else in a string is refused. Newlines, tabs, C0 controls and
-- astral-plane unicode all survive every consumer we have (measured, not
-- assumed), and a rule that refused them would reject legitimate narration.
local function text_problem(field, v)
  if type(v) ~= "string" then
    return string.format("'%s' is %s, not a string", field, type(v))
  end
  if v:find("\0", 1, true) then
    return string.format("'%s' contains a NUL byte, which vim cannot hold", field)
  end
  return nil
end

-- Everything wrong with a step's own fields, judged from the document alone --
-- or nil when there is nothing wrong with them.
--
-- This is the single place that answers "can this step be handed to vim at
-- all?", and it exists because the answer had been discovered five times, one
-- consumer at a time: the renderer, the quickfix list, the cursor and the CLI
-- each learned to survive a different malformed field, and each time the next
-- consumer along was still unguarded. The consumers keep their guards -- they
-- are the net for a field nobody anticipated -- but a step whose fields cannot
-- be used is now unplayable HERE, before any of them see it, which is what
-- makes `validate` and `open` agree by construction: `validate` refuses the
-- document, `open` drops that one step and plays the rest.
--
-- `selection` is deliberately absent: it is decoration, and a malformed one
-- costs the step nothing. See M.validate.
function M.step_problem(s)
  if s.title ~= nil then
    local p = text_problem("title", s.title)
    if p then return p end
  end
  local p = text_problem("description", s.description)
  if p then return p end
  if s.file ~= nil then
    p = text_problem("file", s.file)
    if p then return p end
  end
  if s.pattern ~= nil then
    p = text_problem("pattern", s.pattern)
    if p then return p end
  end
  if s.line ~= nil then
    -- No file has been read yet, so this is the magnitude half only: whether
    -- the line is also INSIDE its file is answered against the buffer, later.
    p = M.line_problem(s.line)
    if p then return p end
  end
  return nil
end

-- Validate a CodeTour document. We validate shape only: whether a file exists
-- is a question about the world at render time, not about the document.
-- Unknown fields are preserved so tours written for newer CodeTour versions,
-- or for other players, survive a round trip through us.
--
-- Two kinds of verdict come out of here, and the difference is deliberate:
--
--   * the DOCUMENT is malformed (no title, no steps, a step that is not an
--     object, a step with no `description`) -- raised, so `validate` and `open`
--     refuse it identically. There is no partial rendering of a document we
--     cannot read.
--   * a STEP is malformed (`s.problem` below) -- recorded, not raised. The step
--     is unplayable, `validate` reports it and fails, `open` drops it and plays
--     the rest. "Partial is better than nothing; silence is not."
function M.validate(t)
  if type(t) ~= "table" then error("tour must be an object") end
  if type(t.title) ~= "string" or t.title == "" then
    error("tour is missing required field 'title'")
  end
  -- The document's own title is not a step and cannot be dropped: it names the
  -- quickfix list and comes back out through `state()`, so a document whose
  -- title vimscript cannot hold is refused whole -- by `validate` and by `open`
  -- alike, which is what makes a document-level refusal acceptable at all.
  if t.title:find("\0", 1, true) then
    error("tour title contains a NUL byte, which vim cannot hold")
  end
  if type(t.steps) ~= "table" or #t.steps == 0 then
    error("tour is missing a non-empty 'steps' array")
  end

  for i, s in ipairs(t.steps) do
    -- Said plainly, because everything below indexes `s`: a step that is a
    -- number refused the document with "attempt to index local 's'", which
    -- tells the author nothing about their tour.
    if type(s) ~= "table" then
      error(string.format("step %d: is not an object", i))
    end
    if type(s.description) ~= "string" then
      error(string.format("step %d: missing required field 'description'", i))
    end

    -- A field of a shape or a magnitude vim cannot use makes the step
    -- unplayable, exactly as a file that has been deleted does. Recorded on the
    -- step so `validate` can say which field and why, rather than the reader
    -- meeting it as a Lua traceback out of whichever consumer touched it first.
    s.problem = M.step_problem(s)

    -- A step is playable if its fields are usable, it names a file, and it can
    -- locate a line in it.
    s.playable = s.problem == nil
      and type(s.file) == "string"
      and (type(s.line) == "number" or type(s.pattern) == "string")
    -- Only a string vimscript can hold is a path: `fnamemodify` RAISES both on
    -- a non-string and on a string containing a NUL, and a raise here refuses
    -- the whole document -- so a `file` of the wrong shape would cost the reader
    -- every other step in the tour. Such a step already has `problem` set; that
    -- is the whole of its punishment.
    if s.problem == nil and type(s.file) == "string" then
      s.abspath = vim.fn.fnamemodify(s.file, ":p")
    end

    -- selection is CodeTour's range; collapse it to whole lines for
    -- highlighting.
    --
    -- It is DECORATION -- it moves a highlight and nothing else -- so a
    -- malformed one costs the step nothing. It used to cost half a step and all
    -- of another: `"selection": 5` fell through to the line below and played,
    -- while `{"start":{"character":1}}` yielded a range of nils, raised inside
    -- math.max at draw time and lost the reader the whole step. Two
    -- near-identical malformations, opposite treatments, and the harsher one
    -- went to the author whose selection looked MORE like a real one. Now
    -- neither is fatal: a range is taken only when both ends are usable line
    -- numbers, and anything else falls back to highlighting the step's own
    -- line, with `range_note` recorded so `validate` can mention it without
    -- failing over it.
    --
    -- `range` and `range_note` are DERIVED, and validate owns them outright --
    -- which is why they are cleared before they are computed. Unknown fields
    -- are preserved (a tour written for a newer CodeTour must survive a round
    -- trip through us), and `range` is not a CodeTour field, so a document
    -- carrying one used to have it survive straight into the renderer's own
    -- internal slot: `{"range": 1}` on a pattern step reached
    -- `math.max(r[1], 1)` in render.draw, raised, and cost the reader the step
    -- -- on a tour `validate` had just exited 0 on. That is this project's
    -- five-times-repeated bug class arriving through a field nobody consumes,
    -- and the general rule it teaches is the clearing below: a document may
    -- name a field, but it may never write a field we compute.
    s.range, s.range_note = nil, nil
    local from, to
    if type(s.selection) == "table" and type(s.selection.start) == "table"
      and type(s.selection["end"]) == "table" then
      from, to = s.selection.start.line, s.selection["end"].line
    end
    if from ~= nil and to ~= nil and not M.line_problem(from) and not M.line_problem(to) then
      s.range = { from, to }
    else
      if s.selection ~= nil then
        s.range_note = "'selection' is not a usable line range; highlighting the step's own line instead"
      end
      if type(s.line) == "number" and not M.line_problem(s.line) then
        s.range = { s.line, s.line }
      end
    end
  end
  return t
end

function M.load(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then error("cannot read tour: " .. path) end
  local decoded_ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decoded_ok then error("tour is not valid JSON: " .. tostring(decoded)) end
  return M.validate(decoded)
end

-- CodeTour has no step id. `title` is the closest stable, human-meaningful
-- handle; index is the fallback. This is what position is restored by.
function M.step_id(t, i)
  local s = t.steps[i]
  -- ...but only a title vim can actually hold. This id is what `state()`
  -- returns and what the CLI reads back over --remote-expr, where a NUL becomes
  -- a Blob and raises E976 -- so a step whose title carries one (already
  -- unplayable, and about to be reported BY this id) falls back to its index.
  if s and type(s.title) == "string" and s.title ~= ""
    and not s.title:find("\0", 1, true) then
    return s.title
  end
  return tostring(i)
end

-- What is wrong with `line` as a position in a file of `n` lines -- or nil when
-- there is nothing wrong with it. `n` is optional: with no file in hand (at
-- document-validation time, or for a `selection` end) the magnitude checks
-- still apply and the "past the end" one simply cannot be asked yet.
--
-- `line` is hand-written JSON and reaches nvim's API unchecked, so every one of
-- these matters. A line past the end of the file is rot of exactly the same
-- kind as a pattern that no longer matches, and used to be CLAMPED instead: the
-- reader was parked on the last line of the file, narration anchored there,
-- nothing reported, `validate` silent. A line that is not a whole number is not
-- a position at all -- nvim raises E805 ("Using a Float as a Number") the moment
-- it reaches an extmark or the cursor.
--
-- And integrality is NOT magnitude, which is the trap this last grew out of:
-- JSON numbers decode as doubles, so `1e30` and `1e308` are integral -- `% 1`
-- is 0 for both -- yet neither fits in an int64, so vim converts them as a
-- Float and `setqflist` raises E805 on a step the author merely fat-fingered.
-- The cliff is at 2^63; the bound below is far lower and is the real one,
-- because a line is a `linenr_T` and that is a 32-bit int.
--
-- One function so `validate` and the player can never disagree about which
-- lines are real.
function M.line_problem(line, n)
  if type(line) ~= "number" then return "line is not a number" end
  -- NaN first: it fails every comparison below, including against itself, so
  -- unstated it would fall out of the bottom as "no problem".
  if line ~= line then return "line nan is not a whole number" end
  if line % 1 ~= 0 then return string.format("line %s is not a whole number", tostring(line)) end
  if line < 1 then return string.format("line %s is before the first line", tostring(line)) end
  -- tostring, not %d: %d on a number past int64 prints 9223372036854775807 --
  -- a line that appears nowhere in the tour, reported to an author looking for
  -- the one they wrote.
  if line > M.MAX_LINE then
    return string.format("line %s is beyond the largest line vim can address (%d)",
      tostring(line), M.MAX_LINE)
  end
  if n and line > n then return string.format("line %d is past the end (%d lines)", line, n) end
  return nil
end

-- Resolve a step against a list of lines. An explicit line wins; otherwise the
-- first line matching `pattern`. Returns nil when it cannot be located, which
-- the caller must treat as "skip and report", never as line 1. The second
-- return is how many lines matched: one match is what the author meant, and
-- more than one is worth saying out loud, because `pattern` is a vim regex and
-- the extra matches are usually a near-miss the author cannot see.
--
-- The player has a buffer and the CLI has a file on disk; both resolve through
-- here so `validate` can never disagree with the player about which line a
-- step names.
function M.resolve_in_lines(step, lines)
  if type(step.line) == "number" then
    -- A line that is not a real position in THIS file resolves to nothing, so
    -- it travels the demote-and-report path a stale pattern already travels
    -- rather than being clamped into plausible-looking wrongness.
    if M.line_problem(step.line, #lines) then return nil, 0 end
    return step.line, 1
  end
  if type(step.pattern) ~= "string" then return nil, 0 end
  local re = vim.regex(step.pattern)
  local first, count = nil, 0
  for i, l in ipairs(lines) do
    if re:match_str(l) then
      count = count + 1
      if not first then first = i end
    end
  end
  return first, count
end

-- Resolve a step to a line in `bufnr`. Deliberately one return value: callers
-- pass this straight into other functions.
function M.resolve(step, bufnr)
  local line = M.resolve_in_lines(step, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  return line
end

return M
