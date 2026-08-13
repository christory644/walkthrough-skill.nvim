-- Minimal assert harness. No plugin deps: tests run under `nvim --clean`.
local T = { failures = 0, checks = 0 }

local function report(ok, msg)
  T.checks = T.checks + 1
  if not ok then
    T.failures = T.failures + 1
    io.write("  FAIL: ", msg or "(no message)", "\n")
  end
end

function T.ok(cond, msg) report(cond and true or false, msg) end

function T.eq(a, b, msg)
  report(vim.deep_equal(a, b), string.format("%s\n    expected: %s\n    actual:   %s",
    msg or "values differ", vim.inspect(b), vim.inspect(a)))
end

function T.err(fn, pat, msg)
  local ok, e = pcall(fn)
  if ok then
    report(false, (msg or "expected an error") .. " (none raised)")
  else
    report(tostring(e):match(pat) ~= nil,
      string.format("%s\n    error %q did not match %q", msg or "wrong error", tostring(e), pat))
  end
end

function T.done()
  io.write(string.format("  %d checks, %d failures\n", T.checks, T.failures))
  if T.failures > 0 then vim.cmd("cq") end
end

function T.load_plugin() vim.opt.runtimepath:append(vim.fn.getcwd()) end

return T
