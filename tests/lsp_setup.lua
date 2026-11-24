-- Real language server configuration for E2E tests (no mocks).
local M = {}

function M.enable(root)
  local tsls = root .. "/node_modules/.bin/typescript-language-server"
  local ra = os.getenv("QZSS_RUST_ANALYZER")
  if not ra or ra == "" then
    local local_ra = root .. "/.deps/bin/rust-analyzer"
    ra = vim.fn.executable(local_ra) == 1 and local_ra or "rust-analyzer"
  end
  vim.lsp.config("rust_analyzer", {
    cmd = { ra },
    filetypes = { "rust" },
    root_markers = { "Cargo.toml" },
  })
  vim.lsp.config("ts_ls", {
    cmd = { tsls, "--stdio" },
    filetypes = { "typescript", "typescriptreact" },
    root_markers = { "tsconfig.json", "package.json" },
    init_options = { hostInfo = "qzss-tests" },
  })
  vim.lsp.enable({ "rust_analyzer", "ts_ls" })
end

return M
