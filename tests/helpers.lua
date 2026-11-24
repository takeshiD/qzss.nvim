local M = { passed = 0, failed = 0 }

local function out(s)
  io.stdout:write(s .. "\n")
end

function M.ok(cond, msg, extra)
  if cond then
    M.passed = M.passed + 1
    out("ok   " .. msg)
  else
    M.failed = M.failed + 1
    out("FAIL " .. msg .. (extra and ("  (" .. tostring(extra) .. ")") or ""))
  end
  return cond
end

function M.eq(a, b, msg)
  return M.ok(a == b, msg, "got " .. vim.inspect(a) .. ", want " .. vim.inspect(b))
end

function M.same(a, b, msg)
  return M.ok(vim.deep_equal(a, b), msg, "got " .. vim.inspect(a) .. ", want " .. vim.inspect(b))
end

-- some line contains the plain substring
function M.contains(lines, needle, msg)
  for _, l in ipairs(lines) do
    if l:find(needle, 1, true) then
      return M.ok(true, msg)
    end
  end
  return M.ok(false, msg, "not found: " .. needle .. "\n" .. table.concat(lines, "\n"))
end

function M.finish()
  out(string.format("\n%d passed, %d failed", M.passed, M.failed))
  vim.cmd((M.failed == 0) and "qa!" or "cq!")
end

return M
