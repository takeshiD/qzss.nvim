-- Loads documented examples from docs/api.md by name and runs them, so the
-- real-PTY scenario tests/tui/api-picker-statusline.json drives exactly the
-- code users copy. Usage: nvim -u tests/minimal_init.lua -c "luafile tests/tui/docs_api_demo.lua"
-- Example names come from $QZSS_EXAMPLES (comma separated).
local root = vim.g.qzss_root
local doc = table.concat(vim.fn.readfile(root .. "/docs/api.md"), "\n") .. "\n"
for name in (os.getenv("QZSS_EXAMPLES") or "picker,breadcrumb"):gmatch("[^,]+") do
  local code = doc:match("<!%-%- example: " .. vim.pesc(name) .. " %-%->\n```lua\n(.-)```")
  assert(code, "example not found in docs/api.md: " .. name)
  assert(loadstring(code, "docs/api.md:" .. name))()
end
