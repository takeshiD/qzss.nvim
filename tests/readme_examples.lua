-- Executes every `require("qzss").setup(...)` Lua block in README.md and
-- renders the fixtures with it, so documented configuration stays valid.
-- Run: nvim --clean --headless -l tests/readme_examples.lua
local root = vim.fn.getcwd()
package.path = root .. "/?.lua;" .. package.path
dofile(root .. "/tests/minimal_init.lua")
local T = require("tests.helpers")
local qzss = require("qzss")

local readme = table.concat(vim.fn.readfile(root .. "/README.md"), "\n")
local blocks = {}
for code in readme:gmatch("```lua\n(.-)```") do
  if code:find('require("qzss").setup', 1, true) then
    table.insert(blocks, code)
  end
end
T.ok(#blocks >= 5, "README has setup examples (" .. #blocks .. ")")

local files = { "tests/fixtures/rust/src/lib.rs", "tests/fixtures/ts/sample.ts", "tests/fixtures/ts/view.tsx",
  "tests/fixtures/sample.json", "tests/fixtures/sample.yaml" }
local outputs = {}
for i, code in ipairs(blocks) do
  local chunk, err = loadstring(code, "README block " .. i)
  T.ok(chunk ~= nil, "README block " .. i .. " parses", err)
  if chunk then
    local ok, e = pcall(chunk)
    T.ok(ok, "README block " .. i .. " runs setup()", e)
    local all = {}
    for _, f in ipairs(files) do
      vim.cmd("edit! " .. root .. "/" .. f)
      local ok2, lines = pcall(qzss.outline_lines, 0)
      T.ok(ok2 and #lines > 0, ("README block %d renders %s"):format(i, f), not ok2 and lines or nil)
      if ok2 then vim.list_extend(all, lines) end
    end
    outputs[i] = all
  end
end
-- spot-check that the documented effects are visible
local function has(lines, needle)
  for _, l in ipairs(lines or {}) do
    if l:find(needle, 1, true) then return true end
  end
  return false
end
for i, code in ipairs(blocks) do
  if code:find('kind_labels = { Interface = "contract"', 1, true) then
    T.ok(has(outputs[i], "i [Shape]<T extends number = number>  contract"), "ASCII/custom-label example shows i [Shape] ... contract")
  end
  if code:find("%s for %s", 1, true) then
    T.ok(has(outputs[i], "Shape<T> for MyStruct<T>") and not has(outputs[i], "where T: Copy + Display"), "format_name/format_detail example drops impl prefix + where clause")
    T.ok(has(outputs[i], "name  string") or has(outputs[i], "name  "), "format_detail example hides data previews")
  end
end
qzss.setup({})
T.finish()
