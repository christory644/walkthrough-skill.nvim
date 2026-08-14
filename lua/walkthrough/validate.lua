-- Out-of-process tour inspection for bin/walkthrough.
--
--   nvim --headless --clean -l validate.lua check <tour.tour> [report-base]
--   nvim --headless --clean -l validate.lua files <tour.tour> [report-base]
--   nvim --headless --clean -l validate.lua skips <tour.tour> [report-base]
--
-- Three modes, three different questions, and the difference between the first
-- two matters:
--
--   check  — "is this tour whole?" The CI rot gate. ANY step that cannot be
--            played is a failure: exit 1, every problem named on stderr.
--   skips  — "what would playing this tour lose?" What `open` asks. The same
--            problems, on STDOUT, exit 0 — because the spec's error table says
--            a missing file or line means "skip that hunk, render the rest,
--            report which were dropped. Partial is better than nothing;
--            silence is not." Exit 1 only when NOTHING is left to play.
--   files  — the buffer list for the player, readable files only.
--
-- Why this is a FILE and not a `-c "lua ..."` chunk built by the shell:
--
--   * The tour path arrives in _G.arg, as one argv element. It is never
--     concatenated into source text, so a filename like
--     `t'..(os.execute("...") and "")..'.tour` is just a name that will not
--     be found -- it cannot close a Lua string and become code (C-1).
--
--   * `nvim -l` propagates the script's exit status, so this file's verdict
--     IS the process's verdict. The old form ran `-c "lua ..."` followed by
--     `-c 'qa!'`; if the chunk failed to COMPILE, the `qa!` still ran and
--     nvim exited 0, so `validate` said "playable" about a tour it had never
--     parsed (C-2). There is no trailing command here, and every exit below
--     is explicit: this fails CLOSED.
--
-- Validation logic lives in walkthrough.tour, so the CLI and the player can
-- never disagree about what a valid tour is. The one thing added here is the
-- on-disk check: a tour whose files have been deleted or moved is rot, and
-- catching that in CI is the entire reason `validate` exists.

-- Resolve the plugin root from THIS script's own location
-- ($ROOT/lua/walkthrough/validate.lua -> $ROOT) rather than taking it as an
-- argument or via `--cmd "set rtp+=..."`. One less value crossing a shell
-- boundary, and it is correct no matter where the CLI was invoked from.
local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(script)))
vim.opt.runtimepath:append(root)

local function fail(msg)
  io.stderr:write("walkthrough: ", msg, "\n")
  os.exit(1)
end

local argv = _G.arg or {}
local mode, path, base = argv[1], argv[2], argv[3]

-- `mode` is a constant chosen by the CLI, never by the tour; `path` and `base`
-- are untrusted halves and are only ever used as data.
local USAGE = "usage: validate.lua check|files|skips <tour.tour> [report-base]\n"
if mode ~= "check" and mode ~= "files" and mode ~= "skips" then
  io.stderr:write(USAGE)
  os.exit(2)
end
if type(path) ~= "string" or path == "" then
  io.stderr:write(USAGE)
  os.exit(2)
end

-- We run FROM the workspace root (the CLI cds there) because that is what a
-- step's `file` is relative to -- but we print to a shell whose cwd may be a
-- SUBDIRECTORY of it. A root-relative `src/app.txt` typed back at a reader
-- sitting in `sub/` names a different file, or none, and the `nvim -q -` pipe
-- this output advertises resolves it against the reader's cwd, not ours. So
-- every path we print is made usable from where the reader actually is:
-- relative when it is below them, absolute when it is not. `base` is the CLI's
-- invocation directory; with none given (a direct call) the tour's own
-- spelling is kept.
--
-- Two paths that name the same place can be spelled differently, and comparing
-- the spellings answers the wrong question. We run from the workspace root,
-- where nvim's cwd is the REAL directory (`/private/var/...`), while `base`
-- arrives as the shell's `$PWD`, which keeps whatever symlink the caller walked
-- through (`/var/...`, `/tmp/...`). Both name one directory; a prefix test on
-- the text says they are unrelated, and every path in the report came out
-- absolute — correct, and useless to read, on a clone that had done nothing
-- wrong (#10). macOS `$TMPDIR` and `/tmp` are both symlinks, so this is the
-- ordinary case, not an exotic one.
--
-- The literal comparison is tried FIRST and unchanged, so nothing that already
-- printed a relative path can start printing something else. The real-location
-- comparison is a second chance for the paths that would otherwise fall through
-- to absolute — in particular it does not resolve a path that already matches,
-- so a symlinked file or directory inside the workspace is still named where
-- the reader can see it rather than at its target.
local uv = vim.uv or vim.loop

-- The DIRECTORY is resolved and the name is left alone, deliberately. The hop
-- we are correcting for is a directory one -- `/tmp` -> `/private/tmp`, and
-- every parent above it -- so resolving the parent chain is enough to make the
-- two spellings comparable. Resolving the file as well would rewrite a step
-- whose `file` is itself a symlink into wherever it points: the tour says
-- `src/linked.txt`, the report would say `/elsewhere/real.txt`, and the reader
-- would be handed a path that appears nowhere in the document they are fixing.
--
-- It also means a file that does not EXIST still resolves, which matters --
-- "file not found" is half of what this report says, and that message names a
-- path too.
local function real_file(p)
  local dir = uv.fs_realpath(vim.fs.dirname(p))
  return dir and (dir .. "/" .. vim.fs.basename(p)) or nil
end

local base_real = (type(base) == "string" and base ~= "")
  and uv.fs_realpath(base) or nil

local function relative_to(dir, p)
  local prefix = dir:sub(-1) == "/" and dir or (dir .. "/")
  if p:sub(1, #prefix) == prefix then return p:sub(#prefix + 1) end
  return nil
end

local function shown(abs, rel)
  if type(base) ~= "string" or base == "" then return rel end
  local literal = relative_to(base, abs)
  if literal then return literal end
  if base_real then
    local abs_real = real_file(abs)
    local resolved = abs_real and relative_to(base_real, abs_real)
    if resolved then return resolved end
  end
  return abs
end

-- Where a `pattern` step actually lands is the one thing an author cannot see
-- by reading the tour: `pattern` is a vim regex, so `(`, `)` and `.` do not
-- mean what someone used to PCRE or Lua patterns expects, and a near-miss
-- captures the wrong line in silence. Every pattern is resolved here and
-- reported as `file:line:`, which reads by eye and feeds straight into
-- `nvim -q -`. Steps that name a line number report nothing: the author
-- already knows where those are, and noise is what makes a report unread.
local report = {}

-- Everything that makes a single step unplayable: a file that has moved, a
-- pattern that no longer matches, a pattern that is not a vim regex at all.
-- Collected rather than raised, because `check` and `skips` disagree about
-- what they mean -- rot to one, a dropped hunk to the other -- and only the
-- caller knows which question was asked. A tour that will not PARSE is
-- different in kind and still raises: there is no partial rendering of a
-- document we cannot read.
local problems = {}

local function label(i, s)
  if type(s.title) == "string" and s.title ~= "" then
    return ("step %d %q"):format(i, s.title)
  end
  return ("step %d"):format(i)
end

-- Why a step was unplayable before anything on disk was even consulted. The
-- alternative was to say nothing at all about these steps, which made `check`
-- and `skips` contradict each other: a CodeTour `directory` step (no `file`)
-- entered no `problems`, so `validate` exited 0 -- while `open` counted it as
-- unplayable and died telling the reader to run `validate`. The message named
-- the command that had just called the tour fine.
local function unplayable(s)
  -- A field vim cannot use at all -- a `title` that is an object, a NUL in a
  -- `description`, a `line` of 1e30 -- is judged once, in tour.validate, and
  -- reported here in its own words. It used to be judged nowhere: `validate`
  -- exited 0 and the player met the field as a raise from whichever consumer
  -- touched it first.
  if s.problem then return s.problem end
  if type(s.file) ~= "string" then
    return "no 'file': there is nothing to open (a CodeTour 'directory' step " ..
      "names no file, and is not supported)"
  end
  return ("no 'line' and no 'pattern': nothing to locate in %s"):format(s.file)
end

local ok, result = pcall(function()
  local tour_mod = require("walkthrough.tour")
  local resolve_in_lines = tour_mod.resolve_in_lines
  local t = tour_mod.load(path)
  for i, s in ipairs(t.steps) do
    if not s.playable then
      -- tour.validate has already judged this step unplayable from its fields
      -- alone. Say so, in both modes, so `check` and `skips` cannot disagree
      -- about which steps a reader would lose.
      table.insert(problems, ("%s: %s"):format(label(i, s), unplayable(s)))
    else
      local abs = vim.fn.fnamemodify(s.file, ":p")
      local where = shown(abs, s.file)
      if vim.fn.filereadable(abs) == 0 then
        s.playable = false
        table.insert(problems, ("%s: file not found: %s"):format(label(i, s), where))
      else
        -- A trailing CR is stripped because the player matches against a
        -- BUFFER, where 'fileformat' has already removed it. Without this a
        -- pattern anchored with $ would resolve in the player and "fail" here,
        -- on a file the tour is perfectly correct about.
        local lines = vim.fn.readfile(abs)
        for n, l in ipairs(lines) do lines[n] = (l:gsub("\r$", "")) end

        -- A `selection` we could not read is DECORATION that did not happen:
        -- the step still plays, parked and narrated, highlighting its own line.
        -- Mentioned rather than raised, because failing CI over a highlight
        -- would make the gate the thing people stop running.
        if s.range_note then
          table.insert(report, ("%s: %s: %s"):format(where, label(i, s), s.range_note))
        end

        if type(s.line) == "number" then
          -- `line` steps used to be exempt from every check but this file's
          -- existence, which left `line` rot -- a step that pointed at the
          -- right line before a refactor -- invisible to the CI gate whose
          -- whole purpose is catching rot, and invisible to the reader, who
          -- was parked on the last line of the file with no message. A line
          -- that is not a position in this file is rot of exactly the same
          -- kind as a pattern that matches nothing, and is reported the same
          -- way. (`line` wins over `pattern` in the player, so it is the only
          -- thing checked when a step carries both.)
          local problem = tour_mod.line_problem(s.line, #lines)
          if problem then
            s.playable = false
            table.insert(problems, ("%s: %s: %s"):format(label(i, s), problem, where))
          end
        elseif type(s.pattern) == "string" then
          local resolved, line, count = pcall(resolve_in_lines, s, lines)
          if not resolved then
            s.playable = false
            table.insert(problems, ("%s: pattern /%s/ is not a valid vim regex: %s")
              :format(label(i, s), s.pattern, tostring(line)))
          elseif not line then
            -- A pattern that no longer matches is rot of exactly the same kind
            -- as a file that was deleted -- and it gets exactly the same
            -- treatment as one, in both modes.
            s.playable = false
            table.insert(problems, ("%s: pattern /%s/ matches nothing in %s")
              :format(label(i, s), s.pattern, where))
          else
            table.insert(report, ("%s:%d: %s pattern /%s/%s"):format(
              where, line, label(i, s), s.pattern,
              count > 1 and (" (%d matches, first used)"):format(count) or ""))
          end
        end
      end
    end
  end
  return t
end)

if not ok then fail(tostring(result)) end

local function playable_count()
  local n = 0
  for _, s in ipairs(result.steps) do if s.playable then n = n + 1 end end
  return n
end

if mode == "check" then
  -- Strict, and deliberately so: this is what CI runs, and a tour that has
  -- rotted in any step has rotted. Every problem is named in one pass rather
  -- than only the first, so one run of `validate` is one round of fixing.
  if #problems > 0 then
    for _, p in ipairs(problems) do io.stderr:write("walkthrough: ", p, "\n") end
    os.exit(1)
  end
  for _, line in ipairs(report) do io.write(line, "\n") end
end

if mode == "skips" then
  if playable_count() == 0 then
    for _, p in ipairs(problems) do io.stderr:write("walkthrough: ", p, "\n") end
    io.stderr:write("walkthrough: no playable steps in this tour\n")
    os.exit(1)
  end
  for _, p in ipairs(problems) do io.write(p, "\n") end
end

if mode == "files" then
  -- NUL-separated, de-duplicated, in narrative order. NUL is the one byte a
  -- path cannot contain, so it is the only separator that cannot be forged by
  -- a hostile `file` field -- a newline here would otherwise split one path
  -- into two, and the shell would open two bogus buffers. The reader is
  -- `read -r -d ''`, which also never word-splits, so a path containing a
  -- space survives intact (I-2).
  --
  -- Unreadable files are left out: they are the steps `open` is dropping, and
  -- naming one on nvim's command line would open an empty buffer at that path
  -- -- a file that looks present and is not.
  local seen = {}
  for _, s in ipairs(result.steps) do
    if s.abspath and not seen[s.abspath] and vim.fn.filereadable(s.abspath) == 1 then
      seen[s.abspath] = true
      io.write(s.abspath, "\0")
    end
  end
end

os.exit(0)
