local tour = require("walkthrough.tour")

local M = {}
M.NS = vim.api.nvim_create_namespace("walkthrough")

local SIGN_GROUP, SIGN_NAME = "walkthrough", "WalkthroughStep"
vim.fn.sign_define(SIGN_NAME, { text = "▶", texthl = "DiagnosticInfo" })

function M.clear(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, M.NS, 0, -1)
  pcall(vim.fn.sign_unplace, SIGN_GROUP, { buffer = bufnr })
end

-- Draw one step: the narration above its line, and -- when it is the step the
-- reader is on -- the highlighted range and the sign.
--
-- Split out so it can be called under pcall as one unit. Every field it touches
-- (`title`, `description`, `range` from `selection`) is hand-written JSON.
-- `tour.validate` now type-checks all of them and a step that fails is never
-- drawn at all -- but that check is a list of the shapes we have thought of,
-- and this guard is what covers the one we have not. See M.apply for why a
-- throw here is not a local problem.
local function draw(bufnr, s, i, total, current_index, line, count)
  local cur = (i == current_index)
  local hl = cur and "DiagnosticInfo" or "Comment"
  local virt = { { { string.format("  %s step %d/%d%s", cur and "▶" or " ", i, total,
    s.title and ("  " .. s.title) or ""), cur and "DiagnosticInfo" or "NonText" } } }
  for _, l in ipairs(vim.split(s.description, "\n", { plain = true })) do
    table.insert(virt, { { "  │ " .. l, hl } })
  end

  local anchor = math.min(math.max(line, 1), count)
  vim.api.nvim_buf_set_extmark(bufnr, M.NS, anchor - 1, 0,
    { virt_lines = virt, virt_lines_above = true })

  if cur then
    local r = s.range or { line, line }
    for l = math.max(r[1], 1), math.min(r[2], count) do
      vim.api.nvim_buf_set_extmark(bufnr, M.NS, l - 1, 0, { line_hl_group = "Visual" })
    end
    vim.fn.sign_place(0, SIGN_GROUP, SIGN_NAME, bufnr, { lnum = anchor, priority = 100 })
  end
end

-- Every step for this buffer is drawn: all visible so the shape of the tour is
-- legible at a glance, the current one emphasised so there is a focus.
--
-- `on_drop(i, why)` is how this function reports a step it cannot draw at all.
-- It matters because rendering is NOT confined to the step the reader asked
-- for: every step that lives in this buffer is drawn, and this runs from a
-- BufEnter autocmd. `pattern` is a hand-written vim regex and `vim.regex`
-- THROWS on an invalid one, so an unprotected resolve here does not merely
-- spoil one annotation -- the throw escapes through the autocmd, past
-- nav.goto_index's own pcall (which only ever guards the step being navigated
-- TO), and out of `walkthrough.open`, taking a tour full of perfectly good
-- steps down with it. Callers that own the tour's state pass `on_drop` so the
-- bad step is demoted, recorded and reported rather than swallowed.
--
-- The DRAW is guarded for exactly the same reason, and it is not a hypothetical
-- one: `{"title": {"x": 1}}` (concatenating a table) and a `selection` whose
-- `start` has no `line` (math.max(nil, 1)) both threw out of this loop, through
-- the autocmd and out of `open`, on a tour `validate` had just exited 0 on --
-- the same failure as the uncompilable pattern, one layer further in. A tour
-- from a cloned repository is untrusted input by this project's own threat
-- model, so "the document is malformed in a way we did not anticipate" has to
-- degrade like everything else: drop that step, report it, draw the rest.
--
-- `tour.validate` now refuses both of those shapes up front, so neither reaches
-- here any more. This guard stays because it is the answer to the NEXT shape --
-- the one that is not on that list yet. Every layer of this bug was found by
-- someone who believed the list above them was complete.
function M.apply(bufnr, t, current_index, on_drop)
  M.clear(bufnr)
  local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")
  local total, count = #t.steps, vim.api.nvim_buf_line_count(bufnr)

  for i, s in ipairs(t.steps) do
    if s.playable and s.abspath == path then
      local resolved, line = pcall(tour.resolve, s, bufnr)
      if not resolved then
        -- Unlike a pattern that merely matches nothing HERE -- a fact about
        -- this buffer's contents, which is why resolvability is decided
        -- lazily in nav -- a pattern that is not a vim regex cannot resolve
        -- against any buffer, ever. Nothing is learned by waiting, so it is
        -- dropped on sight.
        line = nil
        if on_drop then
          on_drop(i, string.format("pattern /%s/ is not a valid vim regex", tostring(s.pattern)))
        end
      end
      if line then
        local drawn, why = pcall(draw, bufnr, s, i, total, current_index, line, count)
        if not drawn and on_drop then
          on_drop(i, string.format("this step cannot be drawn: %s", tostring(why)))
        end
      end
    end
  end
end

function M.park(winid, bufnr, line)
  local count = vim.api.nvim_buf_line_count(bufnr)
  vim.api.nvim_win_set_cursor(winid, { math.min(math.max(line, 1), count), 0 })
  vim.api.nvim_win_call(winid, function() vim.cmd("normal! zz") end)
end

return M
