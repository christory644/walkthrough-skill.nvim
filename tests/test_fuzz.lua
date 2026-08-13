-- Malformed-tour fuzz.
--
-- WHY THIS EXISTS. The same defect class -- "a step field of a shape or
-- magnitude vim cannot use" -- reappeared at FIVE successive layers of this
-- codebase: nav.goto_index, render.apply, render.draw, tour.resolve_in_lines
-- and finally nav.populate, each layer found only after the one above it had
-- been fixed and declared complete. Three fuzzes were written during review;
-- two came back clean and were both WRONG. The decisive one differed from a
-- clean one by a single order of magnitude in one parameter (its largest value
-- was 1e18, one below the 2^63 cliff where `setqflist` starts raising E805).
-- This file is that fuzz, committed, so a sixth layer is a red build rather
-- than a bug report.
--
-- WHAT IT ASSERTS. Two things, and the second is the one that matters:
--
--   1. nothing raises out of any surface, on any document -- and a REFUSAL is
--      not a raise: `open` is allowed to refuse a document, but the refusal
--      has to be ours (our own message) rather than `Vim:E805` or a Lua
--      traceback escaping from whichever consumer touched the field first.
--   2. `validate`'s verdict is SYMMETRIC with `open`'s behaviour, in both
--      directions: a document `validate` refuses must not silently play, and
--      one it accepts must not cost the reader a step or crash `open`. The
--      review that found the last two layers found them precisely because the
--      previous fuzz assumed this symmetry "by construction" (both call
--      `tour.load`) instead of measuring it.
--
-- WHY THE HARNESS SELF-CHECKS. One of the three review fuzzes silently
-- measured nothing: its fixtures lived under $TMPDIR, which on macOS is
-- `/var/...` while a buffer's name resolves to `/private/var/...`, so
-- `s.abspath == path` never matched, `render.apply` drew nothing, and every
-- document looked clean. It was caught by hand-checking a case the harness
-- called clean. So: every fixture path is resolved through `fs_realpath`
-- (SYMLINK_SAFETY below), and a document that is expected to render is
-- asserted to actually render -- once before the corpus, once after it, and
-- once per clean document. A fuzz that can pass by doing nothing is worse than
-- no fuzz, because it is believed.
--
-- TIERS.
--   default              in-process, one position per field x value  (~600 docs)
--   WALKTHROUGH_FUZZ=full  all three positions                       (~1700 docs)
--   WALKTHROUGH_FUZZ_OOP=N every Nth document ALSO gets a real
--                          out-of-process `nvim -l validate.lua`, and the
--                          in-process verdict must equal it. This is what
--                          keeps the fast tier honest: the fast tier runs the
--                          real validate.lua source with os.exit trapped, and
--                          this proves that trap reproduces the real gate.

local T = dofile("tests/harness.lua")
T.load_plugin()

local wt     = require("walkthrough")
local tour   = require("walkthrough.tour")
local render = require("walkthrough.render")

local uv = vim.uv or vim.loop
local CWD = vim.fn.getcwd()

local TIER   = vim.env.WALKTHROUGH_FUZZ or "fast"
local OOP    = tonumber(vim.env.WALKTHROUGH_FUZZ_OOP or "0") or 0
local t0     = uv.hrtime()

-- ---------------------------------------------------------------- fixtures --

-- SYMLINK_SAFETY. `fs_realpath`, not `tempname()` and not `:p`. A step matches
-- a buffer by plain string equality on `abspath` (nav.lua, render.apply), so a
-- fixture reached by a different symlink hop than the buffer name matches
-- NOTHING and the renderer draws nothing -- in silence, on every document. That
-- is not hypothetical: it is how one of the three review fuzzes came back clean
-- while exercising none of the render layer.
local scratch = assert(uv.fs_mkdtemp((uv.os_tmpdir() or "/tmp") .. "/wtfuzz.XXXXXX"))
scratch = uv.fs_realpath(scratch) or scratch

local function write(path, lines)
  local f = assert(io.open(path, "w"))
  f:write(table.concat(lines, "\n"), "\n")
  f:close()
end

local FILE_A = scratch .. "/alpha.txt"
local FILE_B = scratch .. "/beta.txt"
write(FILE_A, { "alpha1", "alpha2", "alpha3", "alpha4", "alpha5" })
write(FILE_B, { "beta1", "beta2", "beta3", "beta4", "beta5" })
-- The two paths as they will appear inside a JSON document.
local J_A, J_B = vim.json.encode(FILE_A), vim.json.encode(FILE_B)

local DOC = scratch .. "/fuzz.tour"
local function put(text)
  local f = assert(io.open(DOC, "w"))
  f:write(text)
  f:close()
  return DOC
end

-- ------------------------------------------------------- the real gate, in --

-- `validate check`, run IN PROCESS from validate.lua's own source, with
-- `os.exit` trapped. Not a reimplementation: reimplementing the gate is how a
-- harness comes to agree with itself about a tour neither of them can play.
-- The out-of-process tier below proves this trap reproduces the real process.
local VALIDATE = CWD .. "/lua/walkthrough/validate.lua"
local validate_chunk = assert(loadfile(VALIDATE))

local function validate_check(path)
  local saved_arg, saved_write, saved_stderr, saved_exit =
    _G.arg, io.write, io.stderr, os.exit
  local saved_rtp = vim.o.runtimepath
  local out, err = {}, {}
  _G.arg = { "check", path }
  io.write = function(...) for _, v in ipairs({ ... }) do out[#out + 1] = tostring(v) end end
  io.stderr = { write = function(_, ...)
    for _, v in ipairs({ ... }) do err[#err + 1] = tostring(v) end
  end }
  os.exit = function(c) error({ wt_exit = c or 0 }, 0) end
  local ok, e = pcall(validate_chunk)
  _G.arg, io.write, io.stderr, os.exit =
    saved_arg, saved_write, saved_stderr, saved_exit
  -- validate.lua appends the plugin root to rtp on every call.
  vim.o.runtimepath = saved_rtp
  if ok then return nil, "validate.lua returned without exiting" end
  if type(e) == "table" and e.wt_exit then
    return e.wt_exit, table.concat(err) .. table.concat(out)
  end
  return nil, "validate.lua raised: " .. tostring(e)
end

local function validate_oop(path)
  vim.fn.system({ "nvim", "--headless", "--clean", "-l", VALIDATE, "check", path })
  return vim.v.shell_error
end

-- ------------------------------------------------------------ the verdicts --

local V = {}          -- violations, by rule
local counts = { clean = 0, degraded = 0, refused = 0, drawn = 0, oop = 0 }
local function violation(rule, doc, detail)
  V[rule] = V[rule] or {}
  table.insert(V[rule], string.format("%s: %s", doc, detail))
end

-- A refusal is ours when it is a sentence we wrote. Anything carrying a vim
-- error code or a Lua traceback is the bug class wearing a refusal's hat --
-- which is exactly how a three-way "clean / degraded / refused" split hid N-1
-- for a whole review round.
local FORBIDDEN = { "Vim:E%d", "E5108", "stack traceback", "attempt to ", "bad argument" }
local function is_our_refusal(msg)
  msg = tostring(msg)
  -- The one legitimate wrapper: vim's JSON decoder reports its own failure and
  -- we quote it verbatim behind our own prefix.
  if msg:find("^tour is not valid JSON:") or msg:find("^cannot read tour:") then return true end
  if msg:find("^reload failed:") then return true end
  for _, p in ipairs(FORBIDDEN) do if msg:find(p) then return false end end
  return true
end

-- Errors that the quickfix list itself raises are not our business: `:cc` onto
-- an entry whose pattern no longer matches is E486, which is vim telling the
-- truth about a dropped step.
local QF_OK = { "E42", "E486", "E553", "E776", "E777" }
local function qf_error_ok(msg)
  msg = tostring(msg)
  for _, e in ipairs(QF_OK) do if msg:find(e, 1, true) then return true end end
  return false
end

-- ------------------------------------------------------------- the surfaces --

local function wipe_buffers()
  pcall(function() vim.cmd("silent! noautocmd %bwipeout!") end)
end

-- Run `fn` with vim's message output suppressed. The player narrates every step
-- and every drop through `nvim_echo`, which is the right thing for a reader and
-- ruins a test log at 1700 documents. `:silent` is the only thing that turns it
-- off (it sets msg_silent, which nvim_echo honours), and it does NOT touch
-- io.write, so a failing assertion still prints. Errors cannot escape: every
-- surface below is called under pcall.
local __quiet
local function quiet(fn)
  local r
  __quiet = function() r = fn() end
  _G.__wt_fuzz_quiet = function() __quiet() end
  vim.cmd("silent! lua _G.__wt_fuzz_quiet()")
  return r
end

-- Drive one document through every surface a reader touches, and return what
-- happened. `expect_render` marks the canary document, whose whole job is to
-- prove the harness is capable of drawing at all.
local function drive(name, path, expect_render)
  local raised = {}
  local function try(what, fn, ...)
    local ok, e = pcall(fn, ...)
    if not ok then table.insert(raised, what .. ": " .. tostring(e)) end
    return ok, e
  end

  local opened, oerr = pcall(wt.open, path)
  if not opened then
    counts.refused = counts.refused + 1
    if not is_our_refusal(oerr) then
      violation("open crashed instead of refusing", name, tostring(oerr))
    end
    if wt.state().active then
      violation("a refused document left a half-open walkthrough", name, "active")
    end
    pcall(wt.close)
    return { refused = true, message = tostring(oerr) }
  end

  local st = wt.state()
  local drops_at_open = #st.skipped

  -- The renderer really drew something. This is the assertion the /var vs
  -- /private/var bug would have failed, and the reason it is made per document
  -- rather than once: a fixture path that stops matching stops EVERYTHING, in
  -- silence.
  local marks = #vim.api.nvim_buf_get_extmarks(0, render.NS, 0, -1, {})
  if marks > 0 then counts.drawn = counts.drawn + 1 end
  if drops_at_open == 0 and marks == 0 then
    violation("a document that played every step drew nothing", name,
      "no extmark in the buffer open() parked in")
  end
  if expect_render then
    T.ok(marks > 0, "canary " .. name .. ": the renderer draws")
    T.eq(vim.api.nvim_win_get_cursor(0)[1], expect_render,
      "canary " .. name .. ": the cursor is parked on the step's line")
  end

  -- state() crossing into vimscript: the boundary the CLI reads back over
  -- --remote-expr, and the only place a NUL in a step id raises E976. No
  -- purely Lua-side surface reaches it.
  try("state()->vimscript", vim.fn.string, st)

  local n = st.count
  for i = 1, n do try("goto_step(" .. i .. ")", wt.goto_step, i) end
  for _, i in ipairs({ 0, -5, n + 1, 99999, -99999 }) do
    try("goto_step(" .. i .. ")", wt.goto_step, i)
  end
  try("step(+1)", wt.step, 1)
  try("step(+1)", wt.step, 1)
  try("step(-1)", wt.step, -1)
  try("step(-1)", wt.step, -1)

  -- BufEnter by hand on every loaded buffer: render.apply runs from inside an
  -- autocmd, where an unguarded throw escapes past open() entirely.
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      try("BufEnter", vim.api.nvim_exec_autocmds, "BufEnter", { buffer = b })
    end
  end

  local qf = vim.fn.getqflist()
  for i = 1, #qf do
    local ok, e = pcall(vim.cmd, "cc " .. i)
    if not ok and not qf_error_ok(e) then
      table.insert(raised, "cc " .. i .. ": " .. tostring(e))
    end
  end
  pcall(vim.cmd, "silent! cnext")
  pcall(vim.cmd, "silent! cprev")

  -- Read the drop set BEFORE the reload. A reload is a fresh `open`, and
  -- lazily-discovered drops (a line past the end of its own file, a pattern
  -- that no longer matches) are rediscovered only on navigation -- so reading
  -- `skipped` after a reload under-counts, and would make the symmetry rule
  -- below fire on the harness rather than on the player.
  local drops = #wt.state().skipped

  try("reload", wt.reload, path)
  local after = wt.state()
  try("state()->vimscript after reload", vim.fn.string, after)
  try("close", wt.close)

  if wt.state().active then
    violation("close left the walkthrough active", name, "active")
  end
  if #vim.fn.getqflist() ~= 0 then
    violation("close left entries in the quickfix list", name,
      tostring(#vim.fn.getqflist()))
  end

  for _, r in ipairs(raised) do
    violation("a surface raised on a document that opened", name, r)
  end

  if drops > 0 then counts.degraded = counts.degraded + 1
  else counts.clean = counts.clean + 1 end
  return { refused = false, drops = drops, raised = #raised > 0 }
end

-- One document: driven, and measured against the real gate in both directions.
local seq = 0
local function case(name, text)
  seq = seq + 1
  local path = put(text)

  local rc, report = validate_check(path)
  if rc == nil then
    violation("validate.lua did not reach a verdict", name, tostring(report))
    return
  end
  if OOP > 0 and seq % OOP == 0 then
    counts.oop = counts.oop + 1
    local rc2 = validate_oop(path)
    if rc2 ~= rc then
      violation("in-process validate disagreed with the real process", name,
        string.format("in-process rc %d, out-of-process rc %d", rc, rc2))
    end
  end

  local r = quiet(function() return drive(name, path) end)

  -- SYMMETRY, both directions. This is the assertion the last two layers were
  -- found by, and it is measured rather than assumed.
  if r.refused then
    if rc == 0 then
      violation("open refused a document validate accepted", name, r.message)
    end
  elseif r.drops > 0 then
    if rc == 0 then
      violation("open dropped a step but validate exited 0", name,
        string.format("%d dropped", r.drops))
    end
  else
    if rc ~= 0 then
      violation("validate refused a document that played whole", name,
        (report or ""):sub(1, 200))
    end
  end

  if seq % 40 == 0 then wipe_buffers() end
end

-- --------------------------------------------------------------- the corpus --

-- Raw JSON text, never a Lua table: a Lua-table generator cannot produce a NUL
-- inside a string, an integral double past int64, or inf -- which is where
-- every finding in this class has lived.
local VALUES = {
  -- magnitude, dense at the representational cliffs and on both sides of each.
  -- The fuzz that MISSED this class topped out at 1e18; the cliff is ~1e19.
  { "zero", "0" }, { "neg1", "-1" }, { "one", "1" }, { "frac", "2.7" },
  { "negfrac", "-2.5" }, { "negzero", "-0.0" }, { "past_eof", "9999" },
  { "i32-1", "2147483646" }, { "i32", "2147483647" }, { "i32+1", "2147483648" },
  { "-i32-1", "-2147483649" },
  { "2p53", "9007199254740992" }, { "2p53+1", "9007199254740993" },
  { "i64max", "9223372036854775807" }, { "i64max+1", "9223372036854775808" },
  { "i64min", "-9223372036854775808" }, { "u64", "1.8446744073709552e19" },
  { "e15", "1e15" }, { "e18", "1e18" }, { "e19", "1e19" }, { "e20", "1e20" },
  { "e30", "1e30" }, { "e100", "1e100" }, { "e308", "1e308" },
  { "inf", "1e309" }, { "neginf", "-1e309" }, { "subnormal", "4.9e-324" },

  -- strings vim may or may not be able to hold
  { "empty", '""' }, { "spaces", '"   "' },
  { "nul_alone", '"\\u0000"' }, { "nul_embedded", '"a\\u0000b"' },
  { "nul_trailing", '"ab\\u0000"' },
  { "controls", '"\\u0001\\u0002\\u001f\\u007f"' },
  { "newline", '"a\\nb"' }, { "tab", '"a\\tb"' }, { "cr", '"a\\rb"' },
  { "backslash", '"a\\\\b"' }, { "quote", '"a\\"b"' },
  { "accented", '"caf\\u00e9"' }, { "cjk", '"\\u65e5\\u672c\\u8a9e"' },
  { "astral", '"\\ud83d\\ude00"' },
  { "numeric_string", '"42"' },
  { "traversal", '"../../../nonexistent/etc/passwd"' },
  { "relative_real", '"tests/fixtures/alpha.txt"' },
  { "bad_regex", '"\\\\%("' }, { "bad_class", '"["' }, { "bad_verymagic", '"\\\\v("' },
  { "long", '"' .. string.rep("x", 5000) .. '"' },

  -- literals and containers where a scalar belongs
  { "true", "true" }, { "false", "false" }, { "null", "null" },
  { "obj_empty", "{}" }, { "arr_empty", "[]" }, { "arr_nums", "[1,2]" },
  { "arr_nested", "[[1],[2]]" }, { "obj_a", '{"a":1}' },
  { "obj_line", '{"line":1}' },
  { "nested4", '{"a":{"b":{"c":{"d":1}}}}' },
  { "obj_nul_key", '{"\\u0000":1}' },

  -- selection, in every shape review found -- injected into every field, not
  -- only into `selection`
  { "sel_scalar", "5" },
  { "sel_char_only", '{"start":{"character":1},"end":{"character":4}}' },
  { "sel_string_line", '{"start":{"line":"2"},"end":{"line":3}}' },
  { "sel_no_end", '{"start":{"line":1}}' },
  { "sel_no_start", '{"end":{"line":2}}' },
  { "sel_huge", '{"start":{"line":1e30},"end":{"line":2}}' },
  { "sel_arr", '{"start":[1],"end":[2]}' },
  { "sel_nulls", '{"start":null,"end":null}' },
  { "sel_backwards", '{"start":{"line":3},"end":{"line":1}}' },
  { "sel_zero", '{"start":{"line":-1},"end":{"line":0}}' },
}

local FIELDS = { "title", "file", "line", "pattern", "description", "selection", "range", "id" }

-- The base document: three good steps across two files, one located by `line`
-- and two by `pattern`, one carrying a well-formed `selection`.
local function step(i, field, raw)
  local kv = {
    { "title", vim.json.encode("s" .. i) },
    { "description", vim.json.encode("note " .. i) },
  }
  if i == 1 then
    kv[#kv + 1] = { "file", J_A }
    kv[#kv + 1] = { "line", "2" }
  elseif i == 2 then
    kv[#kv + 1] = { "file", J_B }
    kv[#kv + 1] = { "pattern", vim.json.encode("^beta2$") }
    kv[#kv + 1] = { "selection", '{"start":{"line":1,"character":0},"end":{"line":2,"character":0}}' }
  else
    kv[#kv + 1] = { "file", J_A }
    kv[#kv + 1] = { "pattern", vim.json.encode("^alpha4$") }
  end
  if field then
    local replaced = false
    for _, e in ipairs(kv) do
      if e[1] == field then e[2] = raw; replaced = true end
    end
    if not replaced then kv[#kv + 1] = { field, raw } end
  end
  local out = {}
  for _, e in ipairs(kv) do out[#out + 1] = vim.json.encode(e[1]) .. ":" .. e[2] end
  return "{" .. table.concat(out, ",") .. "}"
end

local function document(field, raw, pos)
  local steps = {}
  for i = 1, 3 do steps[i] = step(i, (i == pos) and field or nil, raw) end
  return '{"title":"fuzz","steps":[' .. table.concat(steps, ",") .. "]}"
end

-- The canary, first: a document that MUST render. If this stops drawing, every
-- "clean" result below is worthless -- which is precisely what happened to one
-- of the three review fuzzes.
T.eq((validate_check(put(document(nil, nil, 0)))), 0, "canary: validate accepts the good document")
quiet(function() return drive("canary(before)", put(document(nil, nil, 0)), 2) end)
pcall(wt.close)

-- field x value x position
local positions = (TIER == "full") and { 1, 2, 3 } or nil
local rot = 0
for _, f in ipairs(FIELDS) do
  for _, v in ipairs(VALUES) do
    if positions then
      for _, p in ipairs(positions) do
        case(string.format("%s=%s@%d", f, v[1], p), document(f, v[2], p))
      end
    else
      -- one position per field x value, rotating, so the fast tier still
      -- covers first / middle / last across the matrix
      rot = rot % 3 + 1
      case(string.format("%s=%s@%d", f, v[1], rot), document(f, v[2], rot))
    end
  end
end

-- Document-level shapes: the malformations that are not a step field at all.
local one = step(1, nil, nil)
local SHAPES = {
  { "steps_string", '{"title":"t","steps":"nope"}' },
  { "steps_number", '{"title":"t","steps":7}' },
  { "steps_object", '{"title":"t","steps":{"a":1}}' },
  { "steps_null", '{"title":"t","steps":null}' },
  { "steps_empty", '{"title":"t","steps":[]}' },
  { "steps_holds_string", '{"title":"t","steps":["x"]}' },
  { "steps_holds_number", '{"title":"t","steps":[7]}' },
  { "steps_holds_null", '{"title":"t","steps":[null]}' },
  { "steps_holds_array", '{"title":"t","steps":[[1,2]]}' },
  { "steps_holds_bool", '{"title":"t","steps":[true]}' },
  { "steps_holds_empty_obj", '{"title":"t","steps":[{}]}' },
  { "steps_mixed", '{"title":"t","steps":[' .. one .. ',7,' .. one .. "]}" },
  { "doc_array", "[1,2,3]" },
  { "doc_string", '"a tour"' },
  { "doc_number", "42" },
  { "doc_null", "null" },
  { "doc_bool", "true" },
  { "doc_unparseable", "{not json" },
  { "doc_empty", "" },
  { "doc_whitespace", "   \n\t  " },
  { "doc_truncated", '{"title":"t","steps":[' },
  { "doc_trailing_garbage", '{"title":"t","steps":[' .. one .. "]} trailing" },
  { "doc_bom", "\239\187\191" .. '{"title":"t","steps":[' .. one .. "]}" },
  { "title_missing", '{"steps":[' .. one .. "]}" },
  { "title_empty", '{"title":"","steps":[' .. one .. "]}" },
  { "title_object", '{"title":{"a":1},"steps":[' .. one .. "]}" },
  { "title_number", '{"title":9,"steps":[' .. one .. "]}" },
  { "title_nul", '{"title":"a\\u0000b","steps":[' .. one .. "]}" },
  { "title_astral", '{"title":"\\ud83d\\ude00","steps":[' .. one .. "]}" },
  { "title_null", '{"title":null,"steps":[' .. one .. "]}" },
  { "dup_titles", '{"title":"t","steps":[' .. one .. "," .. one .. "," .. one .. "]}" },
  { "dup_titles_one_rotted", '{"title":"t","steps":[' .. one .. "," ..
    step(1, "pattern", vim.json.encode("^nothing_matches_this$")) .. "," .. one .. "]}" },
  { "dup_nul_titles", '{"title":"t","steps":[' ..
    step(1, "title", '"a\\u0000b"') .. "," .. step(1, "title", '"a\\u0000b"') .. "]}" },
  { "all_rotted", '{"title":"t","steps":[' ..
    step(1, "pattern", '"^nope$"') .. "," .. step(2, "pattern", '"^nope$"') .. "]}" },
  { "all_malformed", '{"title":"t","steps":[' ..
    step(1, "line", "1e30") .. "," .. step(2, "title", '"\\u0000"') .. "]}" },
  { "directory_step", '{"title":"t","steps":[{"title":"d","description":"no file"}]}' },
  { "no_location", '{"title":"t","steps":[{"title":"d","description":"x","file":' .. J_A .. "}]}" },
  { "unknown_fields", '{"title":"t","isPrimary":true,"nextTour":"x","ref":"main","steps":[' ..
    step(1, "commands", '["a"]') .. "]}" },
  { "long_description", '{"title":"t","steps":[' ..
    step(1, "description", '"' .. string.rep("y", 5000) .. '"') .. "]}" },
  { "many_steps", nil },  -- built below
  { "deep_nesting", '{"title":"t","steps":[' ..
    step(1, "selection", string.rep('{"a":', 200) .. "1" .. string.rep("}", 200)) .. "]}" },
}
do
  local many = {}
  for i = 1, 200 do many[i] = step((i % 3) + 1, nil, nil) end
  for _, s in ipairs(SHAPES) do
    if s[1] == "many_steps" then s[2] = '{"title":"t","steps":[' .. table.concat(many, ",") .. "]}" end
  end
end
for _, s in ipairs(SHAPES) do case("doc:" .. s[1], s[2]) end

-- A tour path that does not exist at all: `open` must refuse it the way
-- `validate` does, not with a traceback.
do
  local missing = scratch .. "/does-not-exist.tour"
  local rc = validate_check(missing)
  local ok, e = pcall(wt.open, missing)
  T.ok(not ok, "a missing tour file is refused")
  T.ok(is_our_refusal(e), "...in our own words: " .. tostring(e))
  T.ok(rc ~= 0, "...and validate refuses it too")
  pcall(wt.close)
end

-- The Lua-table entry point, which the CLI does not use but `reload` and the
-- API do -- and which is the only way to express the values JSON cannot: nan,
-- inf built by arithmetic, and a table with no array part.
local nan, inf = 0 / 0, math.huge
local TABLES = {
  { "nan_line", { title = "t", steps = { { file = FILE_A, line = nan, description = "d" } } } },
  { "inf_line", { title = "t", steps = { { file = FILE_A, line = inf, description = "d" } } } },
  { "neginf_line", { title = "t", steps = { { file = FILE_A, line = -inf, description = "d" } } } },
  { "huge_line", { title = "t", steps = { { file = FILE_A, line = 2 ^ 70, description = "d" } } } },
  { "fn_title", { title = "t", steps = { { file = FILE_A, line = 1, title = print, description = "d" } } } },
  { "hash_steps", { title = "t", steps = { a = 1 } } },
  { "nan_selection", { title = "t", steps = { { file = FILE_A, line = 1, description = "d",
    selection = { start = { line = nan }, ["end"] = { line = nan } } } } } },
}
for _, tc in ipairs(TABLES) do
  local r = quiet(function()
    local ok, e = pcall(wt.open, tc[2])
    if not ok then return { ok = false, err = tostring(e) } end
    local sok, serr = pcall(vim.fn.string, wt.state())
    pcall(wt.goto_step, 1)
    pcall(wt.step, 1)
    return { ok = true, sok = sok, serr = tostring(serr) }
  end)
  if r.ok then
    T.ok(r.sok, "table:" .. tc[1] .. ": state() crosses into vimscript: " .. r.serr)
  else
    T.ok(is_our_refusal(r.err), "table:" .. tc[1] .. ": refused in our own words: " .. r.err)
  end
  quiet(function() pcall(wt.close) end)
  T.ok(not wt.state().active, "table:" .. tc[1] .. ": nothing left active")
end

-- The canary again, LAST: if the corpus above has left the editor in a state
-- where nothing renders any more, every clean verdict since the first canary
-- was measuring nothing.
wipe_buffers()
quiet(function() return drive("canary(after)", put(document(nil, nil, 0)), 2) end)
pcall(wt.close)

-- ---------------------------------------------------------------- verdicts --

local RULES = {
  "open crashed instead of refusing",
  "a refused document left a half-open walkthrough",
  "a surface raised on a document that opened",
  "a document that played every step drew nothing",
  "open refused a document validate accepted",
  "open dropped a step but validate exited 0",
  "validate refused a document that played whole",
  "close left the walkthrough active",
  "close left entries in the quickfix list",
  "validate.lua did not reach a verdict",
  "in-process validate disagreed with the real process",
}
for _, rule in ipairs(RULES) do
  local hits = V[rule] or {}
  local sample = {}
  for i = 1, math.min(#hits, 5) do sample[i] = hits[i] end
  T.eq(#hits, 0, string.format("%s\n      %s", rule, table.concat(sample, "\n      ")))
end

-- A harness that classified everything as one thing measured nothing. These
-- are the numbers that would have exposed the /var symlink bug immediately.
T.ok(counts.clean > 50, "the corpus contains documents that play whole (" .. counts.clean .. ")")
T.ok(counts.degraded > 50, "...documents that degrade (" .. counts.degraded .. ")")
T.ok(counts.refused > 10, "...and documents that are refused (" .. counts.refused .. ")")
T.ok(counts.drawn > 50, "...and the renderer really drew on " .. counts.drawn .. " of them")

io.write(string.format("  fuzz: %d documents, tier=%s, %.1fs — clean %d / degraded %d / refused %d / drew %d / oop %d\n",
  seq, TIER, (uv.hrtime() - t0) / 1e9,
  counts.clean, counts.degraded, counts.refused, counts.drawn, counts.oop))

wipe_buffers()
vim.fn.delete(scratch, "rf")
T.done()
