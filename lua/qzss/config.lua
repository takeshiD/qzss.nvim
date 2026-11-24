local M = {}

M.defaults = {
  -- Outline sources tried in order. "treesitter" gives structure and syntax
  -- signatures; "lsp" adds DocumentSymbol.detail or acts as fallback.
  backends = { "treesitter", "lsp" },
  -- How LSP DocumentSymbol.detail is combined with the Tree-sitter signature:
  -- "merge"      use the syntax signature, fall back to LSP detail when empty
  -- "treesitter" syntax signature only
  -- "lsp"        LSP detail when present, else syntax signature
  detail_source = "merge",
  -- Sidebar layout
  -- width grows with content up to max_width (set max_width = width to pin it)
  layout = { position = "right", width = 36, max_width = 64 },
  -- "unicode" | "ascii" | "nerd" or a table { Kind = "icon" } (merged with unicode)
  icons = "unicode",
  -- Per-kind label overrides, false hides the label column entirely
  kind_labels = {},
  show_kind = true,
  show_detail = true,
  -- Highlight overrides: { Class = "MyClassHl", Detail = { fg = "#888888" } }
  highlights = {},
  -- Callbacks. Each receives (symbol, ctx) where ctx = { bufnr, filetype, depth }.
  format_name = nil, -- return a string to replace the symbol name
  format_detail = nil, -- return a string (or "" to hide) for the detail part
  get_icon = nil, -- return a string icon (and optionally a highlight group)
  filter = nil, -- return false to hide a symbol
  -- Kinds shown per filetype ({ typescript = { "Class", "Interface" } }); nil = all
  filter_kinds = {},
  -- Collapse every node deeper than this on first render (nil = all open)
  collapse_level = nil,
  -- Follow the source cursor in the sidebar
  follow_cursor = true,
  -- Refresh delay after edits (ms)
  update_delay = 150,
  -- Close the sidebar after jumping with <CR>
  close_on_jump = false,
  -- Optional global mapping to toggle the sidebar, e.g. "<leader>o"
  toggle_key = nil,
  -- Sidebar mappings (set a key to false to disable it)
  keymaps = {
    jump = "<CR>",
    preview = "p",
    toggle_fold = { "o", "za", "<Tab>" },
    open_fold = { "zo", "l" },
    close_fold = { "zc", "h" },
    open_all = "zR",
    close_all = "zM",
    refresh = "r",
    close = "q",
    help = "?",
  },
  -- Max characters of a scalar / alias value preview
  max_detail = 48,
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  -- list-like values must be replaced, not merged index-wise
  if opts and opts.backends then
    M.options.backends = opts.backends
  end
  if opts and opts.keymaps then
    for k, v in pairs(opts.keymaps) do
      M.options.keymaps[k] = v
    end
  end
  return M.options
end

return M
