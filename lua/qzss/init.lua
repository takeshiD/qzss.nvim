-- qzss.nvim: semantic outline (sidebar or float) for Rust, TypeScript/TSX,
-- JSON and YAML.
--
-- `require("qzss")` is the public facade: it re-exports the stable API of
-- `qzss.api` (see docs/api.md) and keeps the legacy helpers of the first
-- release working. Every other qzss.* module is private.
local api = require("qzss.api")
local config = require("qzss.config")
local render = require("qzss.render")
local model = require("qzss.model")
local view = require("qzss.view")
local tsb = require("qzss.backends.treesitter")

local M = {}
for k, v in pairs(api) do
  M[k] = v
end

-- `setup()` flag shared with plugin/qzss.lua (read through the api module)
setmetatable(M, {
  __index = function(_, k)
    if k == "_did_setup" then
      return api._did_setup
    end
  end,
})

---------------------------------------------------------------- legacy helpers (kept for compatibility)

--- Legacy: synchronous Tree-sitter symbols (internal tree with `lnum`
--- 0-based, `col` 0-based byte, `parent` links). A fresh tree on every call.
--- Prefer get_snapshot()/request_symbols() (they include LSP results).
function M.get_symbols(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local syms, err = tsb.get_symbols(bufnr, { max_detail = config.options.max_detail })
  if syms then
    render.assign_ids(syms)
  end
  return syms, err
end

--- Legacy: render symbols to plain lines (all expanded unless `collapsed`).
function M.outline_lines(bufnr, symbols, collapsed)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local m = model.peek(bufnr)
  local lines = render.build(symbols or M.get_symbols(bufnr) or {}, {
    collapsed = collapsed or {},
    bufnr = bufnr,
    filetype = vim.bo[bufnr].filetype,
    kind_set = m and m.kind_set,
  })
  return lines
end

--- Legacy: recompute and call `cb(model)` after each phase.
function M.compute(bufnr, cb)
  return model.compute(bufnr, cb and function(state)
    -- Keep the historical shape, without leaking internal request handles.
    local copy = {}
    for _, key in ipairs({ "symbols", "collapsed", "kind_set", "initialized", "tick", "source", "error", "lsp_error" }) do
      copy[key] = vim.deepcopy(state[key])
    end
    cb(copy)
  end)
end

--- Legacy: internal symbol at 0-based `line` (cache only).
function M.symbol_at(bufnr, line)
  return vim.deepcopy(model.symbol_at(bufnr, line))
end

--- Legacy: re-render the current tab's outline.
function M.render()
  return view.render()
end

--- Legacy: move the outline cursor to the source cursor's symbol.
function M.follow()
  return view.follow()
end

M._fit_width = view.fit_width
M._float_geometry = view.float_geometry
-- internal state for tests; `sidebars` is the historical name of the
-- per-tabpage view table (now sidebar or float)
M._state = { bufs = model.models, sidebars = view.views, views = view.views }

return M
