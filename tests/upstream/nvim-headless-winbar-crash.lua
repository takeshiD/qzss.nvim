-- Reproducer for a Neovim 0.12.6 / 0.11.5 crash found while writing the qzss tests
-- (no qzss code involved): headless, change columns, vsplit with a winbar,
-- close it, redraw -> "double free or corruption" in grid_alloc via
-- msg_grid_validate. Run: nvim --clean --headless -l tests/upstream/nvim-headless-winbar-crash.lua
-- (V=wc reproduces; V=w does not). Tests that redraw therefore keep the
-- headless default 80x24.
local v = os.getenv("V") or "wc"
vim.o.columns = 120
vim.cmd("botright vertical 36split")
if v:find("w") then vim.wo.winbar = " qzss · x" end
if v:find("c") then vim.cmd("close") end
for i=1,3 do vim.cmd("redrawstatus") vim.cmd("redraw!") end
print("ok " .. v)
vim.cmd("qa!")
