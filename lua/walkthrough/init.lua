local tour_mod = require("walkthrough.tour")
local render   = require("walkthrough.render")
local nav      = require("walkthrough.nav")
local keys_mod = require("walkthrough.keys")

local M = {}

local config = { keys = vim.deepcopy(keys_mod.defaults), close_surface = true }
-- state.attached[bufnr] records the exact keys table that was bound to that
-- buffer at attach time, so detach removes what was really bound rather than
-- whatever config.keys happens to hold later (config.keys can change under
-- setup() while a walkthrough is active).
local state  = { active = false, tour = nil, index = 0, touched = {}, skipped = {}, attached = {} }

function M.setup(opts)
  opts = opts or {}
  if opts.keys then config.keys = vim.tbl_extend("force", config.keys, opts.keys) end
  if opts.close_surface ~= nil then config.close_surface = opts.close_surface end
end

function M.state()
  return {
    active = state.active,
    index = state.index,
    count = state.tour and #state.tour.steps or 0,
    id = state.tour and tour_mod.step_id(state.tour, state.index) or nil,
    skipped = state.skipped,
    title = state.tour and state.tour.title or nil,
  }
end

local function remember(b) state.touched[b] = true end

-- Attach the current config.keys to buf and record exactly that table, so a
-- later detach (whenever it happens) removes what was really bound here,
-- independent of anything setup() does to config.keys in between.
local function attach_keys(buf)
  keys_mod.attach(buf, config.keys)
  state.attached[buf] = vim.deepcopy(config.keys)
  remember(buf)
end

local function detach_keys(buf)
  keys_mod.detach(buf, state.attached[buf] or config.keys)
  state.attached[buf] = nil
end

-- The files this nvim is responsible for, and the two moments it must remove
-- them (#30).
--
-- `walkthrough close` — the CLI path — already cleaned these up, but it is the
-- RARE path. The design intends the reader to quit from inside nvim, and that
-- path runs M.close(), which fires `_close_surface` and dies with its surface
-- without ever re-entering the CLI. So the leaking path was the common one, and
-- once the dialog lands the leak includes a FIFO with no reader — precisely the
-- object the dialog design is built to avoid.
--
-- Unlinking here rather than through a CLI verb is deliberate: VimLeavePre has
-- to work for `:qa!` and for a killed surface, and a jobstart fired there is not
-- guaranteed to outlive us. fs_unlink is synchronous and needs no process.
--
-- Only paths the CLI injected are touched. With no env, this does nothing at
-- all — it is not a delete-anything primitive.
local function session_cleanup()
  local uv = vim.uv or vim.loop
  for _, var in ipairs({ "WALKTHROUGH_STATE", "WALKTHROUGH_SOCKET" }) do
    local p = vim.env[var]
    if p and p ~= "" then pcall(uv.fs_unlink, p) end
  end
end

local function install_autocmd()
  state.augroup = vim.api.nvim_create_augroup("Walkthrough", { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = state.augroup,
    callback = function(ev)
      if not state.active then return end
      local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(ev.buf), ":p")
      for _, s in ipairs(state.tour.steps) do
        if s.abspath == path then
          -- The drop hook is not optional here. This callback runs inside an
          -- autocmd, and a step whose `pattern` will not compile would
          -- otherwise throw straight through it and out of open() itself --
          -- see render.apply. Demoting through nav puts it in state.skipped,
          -- where open()'s report below can find it.
          render.apply(ev.buf, state.tour, state.index,
            function(i, why) nav.demote(state, state.tour, i, why) end)
          attach_keys(ev.buf)
          vim.bo[ev.buf].modifiable = false
          return
        end
      end
    end,
  })
  -- The exit that never reaches M.close: `:qa!`, or the surface being killed
  -- out from under us. Unlinking is synchronous, so it completes before we go.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = state.augroup,
    callback = session_cleanup,
  })
end

local function any_playable(t)
  for _, s in ipairs(t.steps) do if s.playable then return true end end
  return false
end

-- Undo everything a walkthrough did to the editor, short of the surface it is
-- running in. Shared by close() and by the one abort path in open(), which
-- must not leave a half-open walkthrough behind.
local function teardown()
  for b in pairs(state.touched) do
    if vim.api.nvim_buf_is_valid(b) then
      render.clear(b)
      detach_keys(b)
    end
  end
  if state.augroup then pcall(vim.api.nvim_del_augroup_by_id, state.augroup) end
  state.augroup, state.active, state.tour, state.index, state.touched =
    nil, false, nil, 0, {}
  state.attached = {}
  -- Clear the list we built, and only that one. The quickfix list is a single
  -- global slot the reader can claim at any moment -- a `:grep` mid-tour makes
  -- it theirs -- and this call used to empty whatever was in it, so closing a
  -- walkthrough threw away results the reader had just gathered and could not
  -- get back. `nav.is_our_qflist` is the same question nav already asks before
  -- retitling a dropped step's entry; asking it in one place is what stops the
  -- two answers drifting apart.
  --
  -- Leaving a foreign list untouched is not a leak: every walkthrough entry
  -- went away with the list the reader replaced.
  if nav.is_our_qflist() then
    vim.fn.setqflist({}, "r", { title = "walkthrough", items = {} })
  end
end

function M.open(path_or_tour)
  local t = type(path_or_tour) == "string"
    and tour_mod.load(path_or_tour)
    or tour_mod.validate(path_or_tour)

  -- report steps we cannot play rather than silently shortening the tour
  local skipped, reasons = {}, {}
  local function drop(i, why)
    table.insert(skipped, tour_mod.step_id(t, i))
    -- A step dropped for a malformed FIELD may have no usable title, so its id
    -- is its index -- and "skipped 1 unplayable step(s): 2" tells the reader
    -- nothing at all. Say which field, where one is known.
    table.insert(reasons, why
      and string.format("%s (%s)", tour_mod.step_id(t, i), why)
      or tour_mod.step_id(t, i))
  end
  for i, s in ipairs(t.steps) do
    if not s.playable then
      drop(i, s.problem)
    elseif vim.fn.filereadable(s.abspath) == 0 then
      s.playable = false
      drop(i, "file not found: " .. tostring(s.file))
    end
  end
  if not any_playable(t) then error("no playable steps: every referenced file is missing") end

  state.tour, state.index, state.touched, state.skipped = t, 1, {}, skipped
  state.attached = {}

  -- `state.active` means "this walkthrough is fully installed", so it is set
  -- LAST -- after the quickfix list, the autocmd and the first jump have all
  -- succeeded. It used to be set here, before any of them, which was benign
  -- only for as long as nothing below could fail; a step that cannot be drawn
  -- now demotes itself mid-jump, so the window is real.
  --
  -- Setting it late also silences the BufEnter autocmd for the duration of that
  -- first jump (its callback returns early while inactive), which is exactly
  -- what we want: goto_index draws and parks that buffer itself, and the keys
  -- for it are attached below.
  local ok, err = pcall(function()
    -- The drop hook is not optional here either. Building the quickfix list is
    -- the first thing that hands a step's own fields to vim, so it is the first
    -- place a field of a shape nobody anticipated can raise -- and until it had
    -- this hook, that raise came out of open() itself, on a tour whose other
    -- steps were perfectly good. Demoting through nav puts the step in
    -- state.skipped, where the report below finds it.
    nav.populate(t, function(i, why) nav.demote(state, t, i, why) end)
    install_autocmd()
    local first = 1
    for i, s in ipairs(t.steps) do if s.playable then first = i break end end
    -- The real state table, not a copy: nav discovers unresolvable steps
    -- lazily, as it loads their buffers, and a step it drops has to reach
    -- state.skipped to be reported below.
    state.index = nav.goto_index(state, first)
  end)
  if not ok then
    -- Half a walkthrough is worse than none: the caller gets the failure, the
    -- editor gets its buffers, keymaps and quickfix list back.
    teardown()
    error(err, 0)
  end

  -- ...and a tour can therefore lose its last playable step DURING that first
  -- jump. Refuse it the way a tour whose files are all missing is refused,
  -- rather than sitting active on something that plays nothing.
  if not any_playable(t) then
    teardown()
    error("no playable steps: no step's location could be resolved")
  end

  state.active = true
  local buf = vim.api.nvim_get_current_buf()
  attach_keys(buf)

  if #skipped > 0 then
    vim.api.nvim_echo({ { string.format(
      "walkthrough: skipped %d unplayable step(s): %s",
      #skipped, table.concat(reasons, ", ")), "WarningMsg" } }, true, {})
  end
  return M.state()
end

function M.goto_step(n)
  -- Raise rather than return quietly. The CLI's `walkthrough step` is a
  -- --remote-expr call, so "returned quietly" reaches the shell as exit 0 --
  -- and SKILL.md tells the agent driving this to trust that status ("never
  -- claim the walkthrough is open without checking"). Stepping a walkthrough
  -- that is not there succeeded, so the agent narrated a step the reader was
  -- never taken to.
  if not state.active then error("no walkthrough is open: nothing to step", 0) end
  -- The real state table, so a step nav finds unresolvable is recorded in
  -- state.skipped and surfaces in state() rather than vanishing.
  state.index = nav.goto_index(state, n)
  local buf = vim.api.nvim_get_current_buf()
  attach_keys(buf)
end

function M.step(delta) M.goto_step(state.index + delta) end

-- Restore the reader's position by step id, which is what survives a tour being
-- rewritten under them: indices move, titles do not.
local function goto_id(id)
  for i = 1, #state.tour.steps do
    if tour_mod.step_id(state.tour, i) == id then M.goto_step(i) return end
  end
end

-- Files changed on disk. Extmarks do not survive a reload, so re-render from
-- the tour rather than patching. Position is restored by step id.
--
-- A reload either succeeds or leaves the reader where they were. It used to do
-- neither: it flipped inactive, detached every keymap and re-read every buffer
-- BEFORE calling open(), so an open() that failed left `active = false` while
-- state() still described the old tour, with no keymaps to close it and a raw
-- Lua traceback coming back through the CLI. The reader's only way out was a
-- shell command they had no way to know about.
function M.reload(path_or_tour)
  if not state.active then return M.open(path_or_tour) end

  -- Read and shape-check the new tour BEFORE dismantling the old one. A tour
  -- that will not parse is the ordinary way a reload fails -- the agent rewrote
  -- it and left it half-written -- and finding that out costs the running
  -- walkthrough nothing.
  local parsed, t = pcall(function()
    return type(path_or_tour) == "string"
      and tour_mod.load(path_or_tour)
      or tour_mod.validate(path_or_tour)
  end)
  if not parsed then
    error("reload failed: " .. tostring(t) .. " (the walkthrough is unchanged)", 0)
  end

  local previous_tour = state.tour
  local previous = tour_mod.step_id(state.tour, state.index)
  -- Flip inactive before touching any buffer below: `:edit!` on a buffer that
  -- is still current can re-trigger our own BufEnter autocmd, and while
  -- state.active stayed true that callback would re-attach the very keymaps
  -- this loop just detached (from the old tour/config, no less).
  state.active = false
  -- Detach every touched buffer's keymaps here, before M.open below resets
  -- state.touched: that reset discards the only record that these buffers
  -- were ever part of a walkthrough, so any that drop out of the new tour
  -- would otherwise keep their keymaps for the life of the process.
  for b in pairs(state.touched) do
    if vim.api.nvim_buf_is_valid(b) then
      render.clear(b)
      detach_keys(b)
      vim.bo[b].modifiable = true
      vim.api.nvim_buf_call(b, function() vim.cmd("silent! edit!") end)
    end
  end
  local opened, oerr = pcall(M.open, t)
  if not opened then
    -- open() has already torn itself down, so what is left is an editor with no
    -- walkthrough at all -- a worse place to leave the reader than where they
    -- were standing. Put the previous tour back, on the step they were on.
    teardown()
    if pcall(M.open, previous_tour) then
      goto_id(previous)
      error("reload failed: " .. tostring(oerr) ..
        " (the previous walkthrough was kept)", 0)
    end
    teardown()
    error("reload failed: " .. tostring(oerr) ..
      " (and the previous walkthrough could not be restored, so it is closed)", 0)
  end
  goto_id(previous)
  return M.state()
end

function M.close()
  if not state.active then return end
  teardown()
  session_cleanup()

  -- Close our own surface if a backend gave us one. The backend positioned it
  -- so that closing returns the user where they came from.
  --
  -- Prefer WALKTHROUGH_CLI (the absolute path the CLI injected when it opened
  -- this tour) over a PATH lookup: install.sh and the README both say putting
  -- bin/ on PATH is optional, so teardown cannot depend on it. Falling back to
  -- "walkthrough" on PATH keeps this working for anyone who did put it there
  -- (or launched some other way) without WALKTHROUGH_CLI set.
  if config.close_surface then
    local handle = vim.env.WALKTHROUGH_HANDLE
    local backend = vim.env.WALKTHROUGH_BACKEND
    if handle and backend then
      local cli = vim.env.WALKTHROUGH_CLI
      if not (cli and vim.fn.executable(cli) == 1) then
        cli = vim.fn.executable("walkthrough") == 1 and "walkthrough" or nil
      end
      if cli then
        vim.fn.jobstart({ cli, "_close_surface", backend, handle })
      end
    end
  end
end

return M
