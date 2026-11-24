-- Minimal, isolated init used by tests, demos and the E2E scenarios.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(root .. "/.deps/site") -- parsers built by scripts/bootstrap.sh
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
vim.opt.termguicolors = true
vim.opt.laststatus = 2
vim.g.qzss_root = root
vim.cmd("filetype plugin indent on")
vim.cmd("syntax on")
-- Make `:help qzss` work in trials without writing doc/tags into the repo:
-- build the tags for a temporary copy of the help file.
do
  local tmp = vim.fn.tempname() .. "-qzss-help"
  vim.fn.mkdir(tmp .. "/doc", "p")
  vim.fn.writefile(vim.fn.readfile(root .. "/doc/qzss.txt", "b"), tmp .. "/doc/qzss.txt", "b")
  pcall(vim.cmd, "silent helptags " .. vim.fn.fnameescape(tmp .. "/doc"))
  vim.opt.runtimepath:append(tmp)
end
vim.cmd("runtime plugin/qzss.lua")
-- Optional user config for demos: QZSS_SETUP='{"icons":"ascii"}'
local setup = os.getenv("QZSS_SETUP")
require("qzss").setup(setup and vim.json.decode(setup) or {})
-- Optional: start real language servers when QZSS_LSP=1
if os.getenv("QZSS_LSP") == "1" then
  require("tests.lsp_setup").enable(root)
end
