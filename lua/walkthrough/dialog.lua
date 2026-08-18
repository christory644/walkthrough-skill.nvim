-- The dialog surface. This file owns the split, the prompt buffer and the
-- transcript; walkthrough.channel owns the write.
local M = {}

-- Nonces issued this session, newest last: nonce -> { step = <label>, answered = false }
M.issued = {}

-- Control characters and NUL are stripped at the boundary, not deeper in.
--
-- NUL is not cosmetic: it crosses --remote-expr as a Blob and raises E976 — the
-- same fact that makes tour.step_id fall back to the index for a title
-- containing one. Everything else that is not a newline or a tab would corrupt
-- the buffer's rendering without saying so.
function M.sanitise(text)
  local clean = tostring(text)
    :gsub("\r\n", "\n")
    :gsub("[%z\1-\8\11\12\14-\31\127]", "")
  return vim.split(clean, "\n", { plain = true })
end

-- Stub receipt path: records the answer against the nonce it was issued
-- under. Task 7 replaces this with the real renderer/transcript.
function M.answer(nonce, text)
  local q = M.issued[nonce]
  if not q then
    return false, "no question is waiting on that nonce: " .. tostring(nonce)
  end
  q.lines = M.sanitise(text)
  q.answered = true
  return true
end

return M
