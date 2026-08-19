local M = {}

M.defaults = {
  next = "]w", prev = "[w", close = "<leader>aq",
  next_cmd = "<leader>an", prev_cmd = "<leader>ap",
  ask = "<leader>aa",
  -- On the DIALOG buffer, not on the code buffers: it dismisses the dialog
  -- split. `q` because that is the key a reader already presses to get rid of a
  -- panel, and because the alternative they will otherwise reach for is `:q` --
  -- which used to leave the transcript buffer alive with its name claimed, so
  -- the next `<leader>aa` died with E95. Both spellings work now; this one is
  -- the documented way.
  dialog_close = "q",
}

function M.attach(bufnr, keys)
  local wt = require("walkthrough")
  local o = function(d) return { buffer = bufnr, silent = true, desc = d } end
  local map = function(lhs, fn, desc)
    if lhs and lhs ~= "" then vim.keymap.set("n", lhs, fn, o(desc)) end
  end

  map(keys.next, function() wt.step(1) end, "walkthrough: next step")
  map(keys.prev, function() wt.step(-1) end, "walkthrough: prev step")
  map(keys.next_cmd, function() wt.step(1) end, "next step")
  map(keys.prev_cmd, function() wt.step(-1) end, "prev step")
  map(keys.close, function() wt.close() end, "end walkthrough")
  map(keys.ask, function() wt.ask() end, "ask about this step")
  -- Deliberately NOT bound here: keys.dialog_close belongs to the dialog buffer
  -- and is attached by M.attach_dialog. Binding it on a code buffer would take
  -- a plain `q` away from the reader everywhere the tour goes.

  -- The group is registered if EITHER binding still lives under <leader>a. It
  -- used to hang off keys.close alone, so a reader who rebound close — and kept
  -- ask where it was — silently lost the label for the group ask is in.
  local ok, wk = pcall(require, "which-key")
  local under_a = function(k) return type(k) == "string" and k:match("^<leader>a") ~= nil end
  if ok and wk.add and (under_a(keys.close) or under_a(keys.ask)) then
    wk.add({ { "<leader>a", group = "agent", buffer = bufnr } })
  end
end

-- The dialog's own buffer-local bindings. Separate from M.attach because the
-- dialog is not a tour buffer: it must never carry the step-navigation keys
-- (they would fight the prompt -- the owner was explicit that `]`/`[` are
-- motion prefixes while the reader is composing, so `next`/`prev`/`next_cmd`/
-- `prev_cmd` only fire when the dialog is NOT focused) and it must never
-- enter state.touched.
--
-- Three keys DO belong here, each for its own reason:
--   dialog_close -- dismisses the panel. Unchanged from before this revision.
--   close        -- ending the walkthrough is a global act (the owner's
--                    ruling, overturning the earlier "document, don't bind"
--                    call): the reader should not have to leave the dialog
--                    first just to find the key that works. Calls the same
--                    wt.close() a tour buffer's `close` calls.
--   ask          -- pressing it again while already IN the dialog is not a
--                    no-op: dialog.open's own reopen branch (M.is_open() ==
--                    true) refreshes S.ctx, focuses the window and starts
--                    insert -- a sensible "get me back to typing" action.
--
-- The binding is REPLACED on every open, not added to. The dialog's buffer
-- survives a dismissal and is reused by the next open (that is what keeps the
-- transcript), so setting without clearing accumulated every key the reader had
-- ever configured -- default `q`, then `Z`, and both still live -- and `""`,
-- which this key table documents as the way to disable any binding, disabled
-- nothing at all: the buffer it would have had no binding on was never built.
--
-- What was really bound is recorded ON the buffer rather than recomputed from
-- config, the same discipline `state.attached` keeps for tour buffers: config
-- can change between the bind and the unbind, and the unbind has to remove what
-- is actually there. Plural now (a table of name -> lhs, not one string),
-- since three keys can live here instead of one.
function M.attach_dialog(bufnr, keys)
  local wt = require("walkthrough")
  local dlg = require("walkthrough.dialog")

  local prior = vim.b[bufnr].walkthrough_dialog_keys
  if type(prior) == "table" then
    for _, lhs in pairs(prior) do
      if type(lhs) == "string" and lhs ~= "" then
        pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
      end
    end
  end
  vim.b[bufnr].walkthrough_dialog_keys = nil

  local bound = {}
  local map = function(name, lhs, fn, desc)
    if lhs and lhs ~= "" then
      vim.keymap.set("n", lhs, fn, { buffer = bufnr, silent = true, desc = desc })
      bound[name] = lhs
    end
  end

  map("dialog_close", keys.dialog_close, function() dlg.dismiss() end,
    "walkthrough: dismiss the dialog")
  map("close", keys.close, function() wt.close() end, "walkthrough: end the walkthrough")
  map("ask", keys.ask, function() wt.ask() end, "walkthrough: ask about this step")
  vim.b[bufnr].walkthrough_dialog_keys = bound

  -- Same coherence rule as M.attach's group registration below: register it
  -- if EITHER <leader>a-shaped key actually landed on this buffer.
  local ok, wk = pcall(require, "which-key")
  local under_a = function(k) return type(k) == "string" and k:match("^<leader>a") ~= nil end
  if ok and wk.add and (under_a(keys.close) or under_a(keys.ask)) then
    wk.add({ { "<leader>a", group = "agent", buffer = bufnr } })
  end
end

function M.detach(bufnr, keys)
  for name, lhs in pairs(keys) do
    -- Never on a code buffer: dialog_close is attached to the dialog's buffer
    -- alone, and its default is a bare `q`. Deleting it from a tour buffer would
    -- delete a `q` the READER had bound there themselves.
    if name ~= "dialog_close" and type(lhs) == "string" and lhs ~= "" then
      pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
    end
  end
end

return M
