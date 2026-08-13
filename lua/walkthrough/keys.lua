local M = {}

M.defaults = {
  next = "]w", prev = "[w", close = "<leader>aq",
  next_cmd = "<leader>an", prev_cmd = "<leader>ap",
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

  local ok, wk = pcall(require, "which-key")
  if ok and wk.add and keys.close and keys.close:match("^<leader>a") then
    wk.add({ { "<leader>a", group = "agent", buffer = bufnr } })
  end
end

function M.detach(bufnr, keys)
  for _, lhs in pairs(keys) do
    if type(lhs) == "string" and lhs ~= "" then
      pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
    end
  end
end

return M
