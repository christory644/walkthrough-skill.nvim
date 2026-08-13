local T = dofile("tests/harness.lua")
T.load_plugin()
local tour   = require("walkthrough.tour")
local render = require("walkthrough.render")

local t = tour.load("tests/fixtures/two_files.tour")
vim.cmd("edit tests/fixtures/alpha.txt")
local buf = vim.api.nvim_get_current_buf()

render.apply(buf, t, 1)
local marks = vim.api.nvim_buf_get_extmarks(buf, render.NS, 0, -1, { details = true })
T.ok(#marks > 0, "extmarks placed")

local virt = 0
for _, m in ipairs(marks) do if m[4] and m[4].virt_lines then virt = virt + 1 end end
T.eq(virt, 2, "only alpha.txt steps render here (step 2 is in beta.txt)")

for _, m in ipairs(marks) do
  if m[4] and m[4].virt_lines then
    T.ok(m[4].virt_lines_above == true, "narration renders above the code")
    T.ok(m[4].virt_text == nil, "never end-of-line virtual text")
  end
end

-- the pattern-located step is anchored at the line the pattern matched (5)
local anchored_at_five = false
for _, m in ipairs(marks) do
  if m[4] and m[4].virt_lines and m[2] == 4 then anchored_at_five = true end
end
T.ok(anchored_at_five, "pattern step anchored at its resolved line")

render.clear(buf)
T.eq(#vim.api.nvim_buf_get_extmarks(buf, render.NS, 0, -1, {}), 0, "cleared")

render.park(0, buf, 5)
T.eq(vim.api.nvim_win_get_cursor(0)[1], 5, "parked")
render.park(0, buf, 999)
T.eq(vim.api.nvim_win_get_cursor(0)[1], 5, "clamped to last line, no error")

-- `pattern` is a hand-written vim regex, so it can fail to COMPILE, and
-- vim.regex raises when it does. apply() draws every step that lives in this
-- buffer, including ones the reader never asked for, so one uncompilable
-- pattern anywhere in the tour used to raise from here -- and because apply()
-- is called from a BufEnter autocmd, that throw came out of open() itself.
-- It must be reported through on_drop instead.
local badt = tour.validate({
  title = "Bad regex",
  steps = {
    { title = "good", file = "tests/fixtures/alpha.txt", line = 1, description = "d" },
    { title = "bad", file = "tests/fixtures/alpha.txt", pattern = "\\%(", description = "d" },
  },
})
local dropped = {}
local rendered = pcall(render.apply, buf, badt, 1,
  function(i, why) table.insert(dropped, { i = i, why = why }) end)
T.ok(rendered, "an uncompilable pattern does not raise out of render.apply")
T.eq(#dropped, 1, "...it is handed to on_drop instead")
T.eq(dropped[1] and dropped[1].i, 2, "...naming the step it could not draw")
T.ok(dropped[1] and dropped[1].why:match("not a valid vim regex") ~= nil,
  "...and saying why, rather than swallowing the error")
T.ok(#vim.api.nvim_buf_get_extmarks(buf, render.NS, 0, -1, {}) > 0,
  "...while the steps that DO resolve are still drawn")
render.clear(buf)

-- The DRAW itself is guarded for the same reason, and it needs to be even now
-- that `tour.validate` type-checks every drawable field. That check is a list
-- of the shapes we have thought of -- `title` an object, a NUL in
-- `description`, a `line` past int64 -- and this guard is the answer to the one
-- we have NOT: five times in a row, the layer that raised was the one whose
-- author believed the check above it was complete.
--
-- So the malformation here is applied AFTER validate has passed the step, which
-- is precisely what a shape validate does not know about looks like from
-- render's side: a playable step carrying a field it cannot draw.
local function drops(mutate, current, label)
  local t2 = tour.validate({ title = "malformed", steps = {
    { title = "good", file = "tests/fixtures/alpha.txt", line = 1, description = "d" },
    { title = "bad", file = "tests/fixtures/alpha.txt", line = 2, description = "d" },
  } })
  mutate(t2.steps[2])
  T.ok(t2.steps[2].playable, label .. ": the step is still believed playable")
  local dropped = {}
  local drew = pcall(render.apply, buf, t2, current,
    function(i, why) table.insert(dropped, { i = i, why = why }) end)
  T.ok(drew, label .. ": does not raise out of render.apply")
  T.eq(#dropped, 1, label .. ": ...it is handed to on_drop instead")
  T.eq(dropped[1] and dropped[1].i, 2, label .. ": ...naming the step it could not draw")
  T.ok(dropped[1] and dropped[1].why:match("cannot be drawn") ~= nil,
    label .. ": ...and saying why, rather than swallowing the error")
  T.ok(#vim.api.nvim_buf_get_extmarks(buf, render.NS, 0, -1, {}) > 0,
    label .. ": ...while the steps that DO draw are still drawn")
  render.clear(buf)
end

drops(function(s) s.title = { x = 1 } end, 1,
  "a title that is an object and got past validate")
drops(function(s) s.range = { nil, nil } end, 2,
  "a range that carries no numbers and got past validate")
drops(function(s) s.description = 7 end, 1,
  "a description that is a number and got past validate")

-- ...and a malformed `selection` is NOT one of those. It is decoration: it
-- moves a highlight and nothing else, so losing it must not lose the reader the
-- narration and the cursor park, which are the whole value of a step. This used
-- to be inconsistent with itself -- `"selection": 5` fell back to the step's own
-- line and played, while `{"start":{"character":1}}` raised inside math.max and
-- cost the whole step, punishing the author whose selection looked MORE like a
-- real one. Both now fall back.
local decor = tour.validate({ title = "decorative", steps = {
  { title = "scalar", file = "tests/fixtures/alpha.txt", line = 2, description = "d",
    selection = 5 },
  { title = "no line", file = "tests/fixtures/alpha.txt", line = 3, description = "d",
    selection = { start = { character = 1 }, ["end"] = { character = 4 } } },
  { title = "line is a string", file = "tests/fixtures/alpha.txt", line = 4, description = "d",
    selection = { start = { line = "2" }, ["end"] = { line = 3 } } },
} })
for i, want in ipairs({ 2, 3, 4 }) do
  T.ok(decor.steps[i].playable, "a malformed selection does not cost the step (" .. i .. ")")
  T.eq(decor.steps[i].range, { want, want },
    "...it falls back to highlighting the step's own line (" .. i .. ")")
  T.ok(decor.steps[i].range_note ~= nil, "...and says so (" .. i .. ")")
end
local decorated = {}
T.ok(pcall(render.apply, buf, decor, 1, function(j, why) table.insert(decorated, j) end),
  "...and every one of them draws")
T.eq(decorated, {}, "...dropping nothing")
render.clear(buf)

T.done()
