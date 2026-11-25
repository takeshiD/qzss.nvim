-- Shared semantic model: one per source buffer. Private module.
--
-- Both UI modes (sidebar, float) and the public API read the same model, so
-- symbols, fold state and the kind filter are stored here exactly once.
--
-- A model is computed in two phases: Tree-sitter synchronously, then (when a
-- documentSymbol client is attached) the LSP response asynchronously. Each
-- computation gets a generation number; a response whose generation or
-- changedtick is outdated is discarded, and if the buffer changed meanwhile
-- the computation is restarted so waiting requests resolve with fresh data.
local config = require("qzss.config")
local render = require("qzss.render")
local events = require("qzss.events")
local tsb = require("qzss.backends.treesitter")
local lspb = require("qzss.backends.lsp")

local M = {}
local api = vim.api

M.LSP_TIMEOUT = 8000

---@type table<integer, table>
local models = {}
M.models = models

local function has_backend(name)
  return vim.tbl_contains(config.options.backends, name)
end

function M.get(bufnr)
  models[bufnr] = models[bufnr]
    or { bufnr = bufnr, collapsed = {}, symbols = {}, initialized = false, tick = -1, gen = 0, waiters = {}, status = "new" }
  return models[bufnr]
end

function M.peek(bufnr)
  return models[bufnr]
end

--- Why a buffer cannot have an outline, or nil when it can.
function M.unusable(bufnr)
  if type(bufnr) ~= "number" or not api.nvim_buf_is_valid(bufnr) then
    return "invalid buffer"
  end
  if not api.nvim_buf_is_loaded(bufnr) then
    return "buffer not loaded"
  end
  if vim.bo[bufnr].filetype == "qzss" then
    return "buffer is a qzss outline"
  end
  return nil
end

local function apply_collapse_level(m)
  local level = config.options.collapse_level
  if not level then
    return
  end
  local function walk(list, depth)
    for _, s in ipairs(list) do
      if depth >= level and #s.children > 0 then
        m.collapsed[s.id] = true
      end
      walk(s.children, depth + 1)
    end
  end
  walk(m.symbols, 0)
end

---------------------------------------------------------------- public symbol copies

-- Fields copied verbatim into public symbols (strings/numbers only).
local EXTRA = { "trait", "self_type", "type_params", "where_clause", "lsp_detail", "lsp_kind", "source" }

--- Convert an internal symbol tree into an independent public tree.
--- Positions: row 1-based, col 0-based byte column; range end exclusive.
--- `default_source` fills `source` for symbols that do not carry one
--- (plain Tree-sitter symbols, or every symbol of an LSP-only outline).
function M.public_tree(bufnr, list, parent_id, depth, out_index, default_source)
  default_source = default_source or "treesitter"
  local res = {}
  for _, s in ipairs(list) do
    local p = {
      id = s.id,
      name = s.name,
      kind = s.kind,
      detail = s.detail or "",
      bufnr = bufnr,
      depth = depth,
      parent_id = parent_id,
      pos = { s.lnum + 1, s.col },
      range = {
        start = { (s.range_lnum or s.lnum) + 1, s.range_col or s.col },
        ["end"] = { (s.range_end_lnum or s.lnum) + 1, s.range_end_col or s.col },
      },
    }
    for _, k in ipairs(EXTRA) do
      if s[k] ~= nil and s[k] ~= "" then
        p[k] = s[k]
      end
    end
    p.source = p.source or default_source
    if out_index then
      out_index[s.id] = s
    end
    p.children = M.public_tree(bufnr, s.children, s.id, depth + 1, out_index, default_source)
    table.insert(res, p)
  end
  return res
end

function M.find_internal(m, id)
  local function walk(list)
    for _, s in ipairs(list) do
      if s.id == id then
        return s
      end
      local c = walk(s.children)
      if c then
        return c
      end
    end
  end
  return walk(m.symbols)
end

--- Per-symbol source when the symbol itself has none.
function M.default_source(m)
  return m.source == "lsp" and "lsp" or "treesitter"
end

--- Snapshot table returned by the public API (independent copy).
function M.snapshot(bufnr)
  local m = models[bufnr]
  if not m or m.tick < 0 then
    return nil
  end
  local cur = api.nvim_buf_is_valid(bufnr) and vim.b[bufnr].changedtick or nil
  local filter = nil
  if m.kind_set then
    filter = vim.tbl_keys(m.kind_set)
    table.sort(filter)
  end
  return {
    bufnr = bufnr,
    changedtick = m.tick,
    stale = cur ~= m.tick,
    pending = m.status == "pending",
    source = m.source,
    error = m.error,
    lsp_error = m.lsp_error,
    filter = filter,
    symbols = M.public_tree(bufnr, m.symbols, nil, 0, nil, M.default_source(m)),
  }
end

---------------------------------------------------------------- compute

local function finish(m)
  m.status = "ready"
  local waiters = m.waiters
  m.waiters = {}
  local snap = M.snapshot(m.bufnr)
  for _, w in ipairs(waiters) do
    if not w.cancelled then
      w.resolve(nil, snap and vim.deepcopy(snap))
    end
  end
end

local function updated(m, cb, complete)
  m.public_cache = nil
  if M.on_update then
    -- set by qzss.view: re-render outlines showing this buffer. A rendering
    -- failure must not stop events/requests from completing.
    local ok, err = pcall(M.on_update, m)
    if not ok then
      vim.schedule(function()
        vim.notify("qzss: render failed: " .. tostring(err), vim.log.levels.ERROR)
      end)
    end
  end
  events.emit("symbols", {
    bufnr = m.bufnr,
    changedtick = m.tick,
    source = m.source,
    error = m.error,
    lsp_error = m.lsp_error,
    pending = not complete,
  })
  if cb then
    cb(m)
  end
end

--- Recompute symbols for `bufnr`. `cb(model)` runs after the Tree-sitter phase
--- and again after the LSP phase (when there is one).
function M.compute(bufnr, cb)
  local bad = M.unusable(bufnr)
  if bad then
    local m = models[bufnr]
    if m then
      M.fail(bufnr, bad)
    end
    return
  end
  local m = M.get(bufnr)
  local o = config.options
  m.gen = m.gen + 1
  local gen = m.gen
  m.status = "pending"
  local ts_syms, ts_err
  if has_backend("treesitter") then
    local ok, res, err = pcall(tsb.get_symbols, bufnr, { max_detail = o.max_detail })
    if ok then
      ts_syms, ts_err = res, err
    else
      ts_err = tostring(res)
    end
  else
    ts_err = "treesitter backend disabled"
  end
  local tick = vim.b[bufnr].changedtick
  m.tick = tick
  local use_lsp = has_backend("lsp") and lspb.available(bufnr)
  if ts_syms then
    m.symbols = render.assign_ids(ts_syms)
    m.source = "treesitter"
    m.error = nil
    if not m.initialized then
      apply_collapse_level(m)
      m.initialized = true
    end
    if not use_lsp then
      m.lsp_error = nil
      m.status = "ready"
    end
    updated(m, cb, not use_lsp)
    if models[bufnr] ~= m or m.gen ~= gen then
      return -- a subscriber started a newer computation
    end
    if not use_lsp then
      finish(m)
    end
  end
  if use_lsp then
    lspb.request(bufnr, function(lsyms, err)
      vim.schedule(function()
        local cur = models[bufnr]
        if cur ~= m or m.gen ~= gen or not api.nvim_buf_is_valid(bufnr) then
          return -- superseded or buffer gone
        end
        if vim.b[bufnr].changedtick ~= tick then
          -- edited while the server was answering: never apply the stale
          -- result; recompute so waiting requests get the current text.
          M.compute(bufnr, cb)
          return
        end
        if err then
          m.lsp_error = err
          if not ts_syms then
            m.symbols = {}
            m.source = nil
            m.error = err
          end
        else
          m.lsp_error = nil
          if ts_syms then
            lspb.merge(ts_syms, lsyms, o.detail_source)
            m.source = "treesitter+lsp"
          else
            m.symbols = render.assign_ids(lspb.refine_kinds(bufnr, lspb.sort(lsyms)))
            m.source = "lsp"
            m.error = nil
            if not m.initialized then
              apply_collapse_level(m)
              m.initialized = true
            end
          end
        end
        m.status = "ready"
        updated(m, cb, true)
        if models[bufnr] == m and m.gen == gen then
          finish(m)
        end
      end)
    end, M.LSP_TIMEOUT)
  elseif not ts_syms then
    m.symbols = {}
    m.source = nil
    m.error = (ts_err or "no outline source") .. "; no LSP client with documentSymbol attached"
    m.status = "ready"
    updated(m, cb, true)
    if models[bufnr] == m and m.gen == gen then
      finish(m)
    end
  end
end

--- Fail every waiting request of `bufnr` and forget the model.
function M.fail(bufnr, reason)
  local m = models[bufnr]
  if not m then
    return
  end
  models[bufnr] = nil
  m.gen = m.gen + 1
  for _, w in ipairs(m.waiters) do
    if not w.cancelled then
      w.resolve(reason, nil)
    end
  end
  m.waiters = {}
end

--- Asynchronous request. resolve(err, snapshot) is always called later
--- (never synchronously) exactly once, unless cancelled.
function M.request(bufnr, resolve)
  local w = { resolve = nil, cancelled = false, done = false }
  -- `done` is set only at delivery: until the callback really runs,
  -- cancel() succeeds and the callback never runs.
  w.resolve = function(err, snap)
    vim.schedule(function()
      if w.cancelled or w.done then
        return
      end
      w.done = true
      if snap ~= nil then
        -- the buffer may have gone away between resolution and delivery
        if not api.nvim_buf_is_valid(bufnr) then
          err, snap = "buffer deleted", nil
        elseif not api.nvim_buf_is_loaded(bufnr) then
          err, snap = "buffer unloaded", nil
        else
          snap.stale = vim.b[bufnr].changedtick ~= snap.changedtick
        end
      end
      resolve(err, snap)
    end)
  end
  local bad = M.unusable(bufnr)
  if bad then
    w.resolve(bad, nil)
    return w
  end
  local m = M.get(bufnr)
  local tick = vim.b[bufnr].changedtick
  if m.status == "ready" and m.tick == tick then
    w.resolve(nil, M.snapshot(bufnr))
    return w
  end
  table.insert(m.waiters, w)
  if not (m.status == "pending" and m.tick == tick) then
    M.compute(bufnr) -- otherwise coalesce with the computation in flight
  end
  return w
end

function M.cancel(w)
  if w.done or w.cancelled then
    return false
  end
  w.cancelled = true
  for _, m in pairs(models) do
    for i, x in ipairs(m.waiters) do
      if x == w then
        table.remove(m.waiters, i)
        break
      end
    end
  end
  return true
end

---------------------------------------------------------------- queries

local function deepest_at(list, line)
  for _, s in ipairs(list) do
    local a = s.range_lnum or s.lnum
    local b = s.range_end_lnum or s.lnum
    if line >= a and line <= b then
      return deepest_at(s.children, line) or s
    end
  end
  return nil
end

--- Internal symbol at 0-based `line`.
function M.symbol_at(bufnr, line)
  local m = models[bufnr]
  return m and deepest_at(m.symbols, line) or nil
end

---------------------------------------------------------------- fold / filter

function M.set_filter(bufnr, kind_list)
  local m = M.get(bufnr)
  if not kind_list or #kind_list == 0 then
    m.kind_set = nil
  else
    m.kind_set = {}
    for _, k in ipairs(kind_list) do
      m.kind_set[k] = true
    end
  end
end

function M.close_all(m)
  local function walk(list)
    for _, s in ipairs(list) do
      if #s.children > 0 then
        m.collapsed[s.id] = true
      end
      walk(s.children)
    end
  end
  walk(m.symbols)
end

return M
