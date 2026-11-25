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
  -- Layout. mode = "sidebar" (default) or "float".
  -- Sidebar: position "right"|"left"; width grows with content up to
  -- max_width (set max_width = width to pin it).
  -- Float: see :help qzss-float. Sizes are cells (>= 1) or fractions (0 < x < 1).
  layout = {
    mode = "sidebar",
    position = "right",
    width = 36,
    max_width = 64,
    float = {
      relative = "editor", -- "editor" | "win" (the source window)
      width = 0.5,
      height = 0.8,
      position = "center", -- "center" | "top" | "bottom" | "left" | "right" | "top-left" | ...
      row = nil, -- explicit top row (cells or fraction); overrides position
      col = nil, -- explicit left column (cells or fraction); overrides position
      min_width = 20,
      max_width = nil,
      min_height = 5,
      max_height = nil,
      border = "rounded",
      winblend = 0,
      title = true, -- true: " qzss · <file> "; string: custom; false: none
      title_pos = "center", -- "left" | "center" | "right"
      zindex = 50,
      -- float-specific default: close after <CR> so the float never hides the
      -- code you jumped to. "global" = use the global close_on_jump.
      -- An explicitly configured global value is inherited unless overridden here.
      close_on_jump = true,
    },
  },
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
  -- Follow the source cursor in the outline
  follow_cursor = true,
  -- Refresh delay after edits (ms)
  update_delay = 150,
  -- Close the sidebar after jumping with <CR> (float: see layout.float.close_on_jump)
  close_on_jump = false,
  -- Optional global mapping to toggle the outline, e.g. "<leader>o"
  toggle_key = nil,
  -- Outline mappings (set a key to false to disable it)
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
    -- extra close key, mapped only in float mode
    float_close = "<Esc>",
  },
  -- Max characters of a scalar / alias value preview
  max_detail = 48,
}

M.options = vim.deepcopy(M.defaults)

local POSITIONS = {
  center = true, top = true, bottom = true, left = true, right = true,
  ["top-left"] = true, ["top-right"] = true, ["bottom-left"] = true, ["bottom-right"] = true,
}
M.float_positions = POSITIONS

local function size_ok(v, allow_nil)
  if v == nil then
    return allow_nil
  end
  return type(v) == "number" and v > 0 and v == v and v ~= math.huge
end

--- Validate layout options; raises "qzss: invalid option ..." on the first
--- invalid value.
function M.validate(o)
  local function fail(msg)
    error("qzss: invalid option " .. msg, 0)
  end
  local lay = o.layout
  if type(lay) ~= "table" then
    fail("layout: expected table")
  end
  if lay.mode ~= "sidebar" and lay.mode ~= "float" then
    fail(('layout.mode: expected "sidebar" or "float", got %s'):format(vim.inspect(lay.mode)))
  end
  if lay.position ~= "left" and lay.position ~= "right" then
    fail(('layout.position: expected "left" or "right", got %s'):format(vim.inspect(lay.position)))
  end
  if type(lay.width) ~= "number" or lay.width < 1 then
    fail("layout.width: expected a number >= 1")
  end
  local f = lay.float
  if type(f) ~= "table" then
    fail("layout.float: expected table")
  end
  if f.relative ~= "editor" and f.relative ~= "win" then
    fail(('layout.float.relative: expected "editor" or "win", got %s'):format(vim.inspect(f.relative)))
  end
  for _, k in ipairs({ "width", "height" }) do
    if not size_ok(f[k], false) then
      fail(("layout.float.%s: expected cells (>= 1) or a fraction (0 < x < 1), got %s"):format(k, vim.inspect(f[k])))
    end
  end
  for _, k in ipairs({ "min_width", "max_width", "min_height", "max_height" }) do
    if not size_ok(f[k], true) then
      fail(("layout.float.%s: expected a positive number or nil, got %s"):format(k, vim.inspect(f[k])))
    end
  end
  for _, k in ipairs({ "row", "col" }) do
    if f[k] ~= nil and (type(f[k]) ~= "number" or f[k] < 0) then
      fail(("layout.float.%s: expected a number >= 0 or nil, got %s"):format(k, vim.inspect(f[k])))
    end
  end
  if not POSITIONS[f.position] then
    fail(("layout.float.position: unknown position %s"):format(vim.inspect(f.position)))
  end
  if type(f.winblend) ~= "number" or f.winblend < 0 or f.winblend > 100 then
    fail("layout.float.winblend: expected 0..100")
  end
  if f.title ~= nil and type(f.title) ~= "boolean" and type(f.title) ~= "string" then
    fail("layout.float.title: expected boolean or string")
  end
  if type(o.close_on_jump) ~= "boolean" then
    fail("close_on_jump: expected boolean")
  end
  if type(f.close_on_jump) ~= "boolean" and f.close_on_jump ~= "global" then
    fail('layout.float.close_on_jump: expected boolean or "global"')
  end
  return o
end

function M.setup(opts)
  if opts ~= nil and type(opts) ~= "table" then
    error("qzss: setup() expects a table, got " .. type(opts), 0)
  end
  local new = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  local float_override
  if opts and type(opts.layout) == "table" and type(opts.layout.float) == "table" then
    float_override = opts.layout.float.close_on_jump
  end
  if opts and opts.close_on_jump ~= nil and float_override == nil
    and type(new.layout) == "table" and type(new.layout.float) == "table" then
    new.layout.float.close_on_jump = "global"
  end
  -- list-like values must be replaced, not merged index-wise
  if opts and opts.backends then
    new.backends = opts.backends
  end
  if opts and opts.keymaps then
    for k, v in pairs(opts.keymaps) do
      new.keymaps[k] = v
    end
  end
  M.validate(new) -- raises; previous options stay active on error
  M.options = new
  return M.options
end

return M
