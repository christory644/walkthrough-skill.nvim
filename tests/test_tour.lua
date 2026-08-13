local T = dofile("tests/harness.lua")
T.load_plugin()
local tour = require("walkthrough.tour")

local t = tour.load("tests/fixtures/two_files.tour")
T.eq(t.title, "Two-file tour", "title parsed")
T.eq(#t.steps, 3, "three steps")
T.eq(t.steps[2].file, "tests/fixtures/beta.txt", "narrative order crosses files")
T.ok(t.steps[1].abspath:sub(1, 1) == "/", "abspath resolved")

-- selection becomes the highlighted range
T.eq(t.steps[1].range, { 2, 3 }, "selection mapped to a line range")
-- a step with no selection highlights just its own line
T.eq(t.steps[2].range, { 1, 1 }, "range defaults to the single line")

-- ids come from titles, which is what survives a reload
T.eq(tour.step_id(t, 1), "first", "id from step title")

-- CodeTour requires description; a step without one is invalid
T.err(function() tour.validate({ title = "x", steps = { { file = "a", line = 1 } } }) end,
  "description", "step without description rejected")
-- a step that is not an object at all is refused by name, not by a raw Lua
-- indexing error about a local called 's'
T.err(function() tour.validate({ title = "x", steps = { 7 } }) end,
  "step 1: is not an object", "a step that is not an object is refused, saying so")
-- tour without title or steps is invalid
T.err(function() tour.validate({ steps = {} }) end, "title", "tour without title rejected")
T.err(function() tour.validate({ title = "x" }) end, "steps", "tour without steps rejected")

-- pattern resolution happens against buffer content
vim.cmd("edit tests/fixtures/alpha.txt")
local buf = vim.api.nvim_get_current_buf()
T.eq(tour.resolve(t.steps[3], buf), 5, "pattern located line 5")
T.eq(tour.resolve(t.steps[1], buf), 2, "explicit line used when present")
T.eq(tour.resolve({ pattern = "^nope$" }, buf), nil, "unmatched pattern returns nil")
-- resolve returns exactly ONE value: callers pass it straight into other
-- functions, where a second return would silently shift their arguments.
T.eq(select("#", tour.resolve(t.steps[3], buf)), 1, "resolve returns one value")

-- The CLI validates through resolve_in_lines, so it cannot disagree with the
-- player about which line a step names -- and it reports how many lines
-- matched, because a pattern that matches twice is a near-miss the author
-- cannot see by reading the tour.
T.eq({ tour.resolve_in_lines({ pattern = "^a" }, { "a1", "b", "a2" }) }, { 1, 2 },
  "first match wins, and the matches are counted")
local miss_line, miss_count = tour.resolve_in_lines({ pattern = "^z" }, { "a1", "b" })
T.eq(miss_line, nil, "no match resolves to nothing")
T.eq(miss_count, 0, "...and counts zero matches")
-- The lines here are chosen so the two answers differ: the pattern matches
-- line 2, the explicit line names line 1.
T.eq({ tour.resolve_in_lines({ line = 1, pattern = "^a" }, { "z", "a1" }) }, { 1, 1 },
  "an explicit line still wins over the pattern")

-- A `line` is a position in a FILE, and one that is not resolves to nothing --
-- the same answer a pattern that matches nothing gives, so it travels the same
-- demote-and-report path. It used to be returned as-is and then CLAMPED at the
-- other end: "line": 9999 in a five-line file parked the reader on line 5, with
-- the narration anchored there, nothing in state().skipped and no message.
T.eq(tour.resolve_in_lines({ line = 9999 }, { "a", "b" }), nil,
  "a line past the end of the file resolves to nothing, rather than to the last line")
T.eq(tour.resolve_in_lines({ line = 0 }, { "a", "b" }), nil, "...and so does line 0")
T.eq(tour.resolve_in_lines({ line = 2.7 }, { "a", "b", "c" }), nil,
  "...and so does a line that is not a whole number (nvim raises E805 on a float)")
T.eq(tour.resolve_in_lines({ line = 2 }, { "a", "b", "c" }), 2, "a line that IS in the file resolves")
T.eq(tour.line_problem(2, 3), nil, "line_problem: a real position has no problem")
T.ok(tour.line_problem(4, 3):match("past the end") ~= nil, "line_problem: past the end says so")
T.ok(tour.line_problem(2.7, 3):match("whole number") ~= nil, "line_problem: a float says so")
T.ok(tour.line_problem(0, 3):match("before the first line") ~= nil, "line_problem: line 0 says so")

-- Integrality is not magnitude, and conflating the two is what kept this bug
-- alive: JSON numbers decode as doubles, so 1e30 and 1e308 ARE whole numbers by
-- `% 1 == 0` -- and neither fits in an int64, so vim converts them as a Float
-- and raises E805 out of setqflist, out of sign_place and out of the cursor
-- move. A `line` is a `linenr_T`, which is a 32-bit int; past that it is not a
-- position in any file that could ever exist.
T.ok(tour.line_problem(1e30, 5):match("beyond the largest line") ~= nil,
  "line_problem: an integral double past int64 is refused for its MAGNITUDE")
T.ok(tour.line_problem(1e30, 5):match("1e%+30") ~= nil,
  "...reported as the number the author actually wrote, not as int64 max")
T.ok(tour.line_problem(1e308, 5) ~= nil, "line_problem: ...and so is 1e308")
T.ok(tour.line_problem(1e19, 5) ~= nil,
  "line_problem: ...and 1e19, just over the 2^63 cliff two fuzz runs sat below")
T.ok(tour.line_problem(math.huge, 5) ~= nil, "line_problem: inf is not a line")
T.ok(tour.line_problem(-math.huge, 5) ~= nil, "line_problem: ...nor -inf")
T.ok(tour.line_problem(0 / 0, 5) ~= nil,
  "line_problem: ...nor nan, which fails every comparison including with itself")
T.eq(tour.line_problem(tour.MAX_LINE), nil,
  "line_problem: the largest line vim can address is still a line")
T.ok(tour.line_problem(tour.MAX_LINE + 1) ~= nil, "line_problem: ...and one past it is not")
-- `n` is optional: at document-validation time there is no file to measure
-- against, and the magnitude half of the question still has an answer.
T.eq(tour.line_problem(9999), nil, "line_problem: with no file in hand, 9999 is a fine line")
T.ok(tour.line_problem(9999, 5) ~= nil, "line_problem: ...and against a 5-line file it is not")

-- Every field a step hands to vim is type- and range-checked ONCE, here, so
-- that `validate` and the player cannot disagree about which steps are
-- playable. This is the check that closes the class: each of these shapes used
-- to be discovered by a different consumer, one raise at a time.
local NUL = string.char(0)
local function problem(field, value)
  local s = { title = "t", file = "f", line = 1, description = "d" }
  s[field] = value
  return tour.step_problem(s)
end
T.eq(problem("line", 1), nil, "step_problem: a whole, small, positive line is fine")
T.ok(problem("line", 1e30) ~= nil, "step_problem: a line past int64 is not")
T.ok(problem("line", 2.7) ~= nil, "step_problem: ...nor a fractional one")
T.ok(problem("line", "3") ~= nil, "step_problem: ...nor a line that is a string")
T.ok(problem("line", { 3 }) ~= nil, "step_problem: ...nor one that is an object")
T.ok(problem("title", { x = 1 }):match("'title'") ~= nil,
  "step_problem: a title that is an object is named as such")
T.ok(problem("title", "a" .. NUL):match("NUL") ~= nil,
  "step_problem: a NUL in a title is refused -- vimscript has no string that holds one")
T.ok(problem("description", "a" .. NUL) ~= nil, "step_problem: ...and in a description")
T.ok(problem("file", "a" .. NUL) ~= nil, "step_problem: ...and in a file")
T.ok(problem("pattern", "a" .. NUL) ~= nil, "step_problem: ...and in a pattern")
T.eq(problem("title", "unicode: é 漢 \240\159\154\128"), nil,
  "step_problem: unicode, astral plane included, is ordinary text")
T.eq(problem("description", "two\nlines\tand a tab"), nil,
  "step_problem: ...and so are newlines and tabs, which narration is made of")
T.eq(problem("title", ""), nil, "step_problem: an empty title is not a malformation")

-- ...and a step that fails them is unplayable, which is what makes `validate`
-- refuse the tour and the player drop that one step and play the rest.
local malformed = tour.validate({ title = "x", steps = {
  { title = "bad", file = "tests/fixtures/alpha.txt", line = 1e30, description = "d" },
  { title = "good", file = "tests/fixtures/alpha.txt", line = 1, description = "d" },
} })
T.ok(not malformed.steps[1].playable, "a step with an unusable field is unplayable")
T.ok(malformed.steps[1].problem:match("beyond the largest line") ~= nil,
  "...and carries the reason, so validate can print it")
T.ok(malformed.steps[1].abspath == nil,
  "...and is never resolved to a path: fnamemodify is a vimscript call too")
T.ok(malformed.steps[2].playable, "...while the step beside it is untouched")
T.eq(malformed.steps[2].problem, nil, "...and carries no problem")

-- A document-level malformation is different in kind and still raises, so
-- `validate` and `open` refuse it identically -- there is no partial rendering
-- of a document we cannot read.
T.err(function() tour.validate({ title = "t" .. NUL, steps = {
  { file = "a", line = 1, description = "d" } } }) end,
  "NUL", "a tour TITLE that vim cannot hold is refused whole, not dropped")
-- A step id crosses back out through --remote-expr, where a NUL raises E976.
T.eq(tour.step_id({ steps = { { title = "a" .. NUL } } }, 1), "1",
  "a title vim cannot hold is not a usable step id either")

-- A selection of a shape we cannot read must not take the whole DOCUMENT down:
-- indexing a `start` that is not a table raises inside validate, which would
-- cost the reader every other step in the tour over one decorative field.
local odd_sel = tour.validate({ title = "x", steps = {
  { description = "d", file = "tests/fixtures/alpha.txt", line = 3, selection = 5 },
  { description = "d", file = "tests/fixtures/alpha.txt", line = 4, selection = { start = 5, ["end"] = 6 } },
} })
T.eq(odd_sel.steps[1].range, { 3, 3 }, "a selection that is not a table falls back to the step's own line")
T.eq(odd_sel.steps[2].range, { 4, 4 }, "...and so does one whose ends are not tables")

-- ...and so does one whose ends ARE tables but carry no usable `line`. That
-- shape used to yield a range of nils, raise inside math.max at draw time and
-- cost the reader the entire step -- while `"selection": 5` above played fine.
-- Two near-identical malformations, opposite treatments. `selection` is
-- decoration: neither is worth a step.
local sel_shapes = tour.validate({ title = "x", steps = {
  { description = "d", file = "tests/fixtures/alpha.txt", line = 1,
    selection = { start = { character = 1 }, ["end"] = { character = 4 } } },
  { description = "d", file = "tests/fixtures/alpha.txt", line = 2,
    selection = { start = { line = "1" }, ["end"] = { line = 2 } } },
  { description = "d", file = "tests/fixtures/alpha.txt", line = 3,
    selection = { start = { line = 1e30 }, ["end"] = { line = 2 } } },
  { description = "d", file = "tests/fixtures/alpha.txt", line = 4,
    selection = { start = { line = 0 }, ["end"] = { line = 2 } } },
  { description = "d", file = "tests/fixtures/alpha.txt", line = 5,
    selection = { start = { line = 1 }, ["end"] = { line = 2 } } },
} })
for i = 1, 4 do
  T.eq(sel_shapes.steps[i].range, { i, i },
    "a selection with an unusable end falls back to the step's own line (" .. i .. ")")
  T.ok(sel_shapes.steps[i].playable, "...and the step still plays (" .. i .. ")")
  T.ok(sel_shapes.steps[i].range_note ~= nil, "...and the fallback is noted (" .. i .. ")")
end
T.eq(sel_shapes.steps[5].range, { 1, 2 }, "...while a usable selection is still honoured")
T.eq(sel_shapes.steps[5].range_note, nil, "...with nothing to note")

-- A document may NAME a field we do not know; it may not WRITE one we compute.
-- `range` and `range_note` are derived from `selection`, and unknown fields are
-- preserved -- so a document carrying its own `range` used to have it survive
-- straight into the renderer's internal slot, where `math.max(r[1], 1)` raised
-- and cost the reader the step, on a tour `validate` had just exited 0 on. The
-- committed fuzz found this; it is the same class as the five layers before it,
-- arriving through a field nobody consumes.
local forged = tour.validate({ title = "x", steps = {
  { description = "d", file = "tests/fixtures/alpha.txt", pattern = "^two$", range = 1 },
  { description = "d", file = "tests/fixtures/alpha.txt", pattern = "^two$",
    range = { "a", "b" }, range_note = "forged" },
  { description = "d", file = "tests/fixtures/alpha.txt", line = 2, range = 1 },
} })
T.eq(forged.steps[1].range, nil,
  "a document's own 'range' does not survive into the renderer's computed range")
T.eq(forged.steps[2].range, nil, "...whatever shape it has")
T.eq(forged.steps[2].range_note, nil, "...and a forged 'range_note' does not survive either")
T.eq(forged.steps[3].range, { 2, 2 }, "...while the range we compute is unaffected")

-- unknown top-level fields survive (forward compatibility with CodeTour)
local kept = tour.validate({ title = "x", nextTour = "y", steps = {
  { description = "d", file = "tests/fixtures/alpha.txt", line = 1 } } })
T.eq(kept.nextTour, "y", "unknown fields preserved")

T.done()
