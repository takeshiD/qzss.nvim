--- qzss.nvim public Lua API (stable surface, API version 1).
---
--- This module is the single source of truth for every use case: the user
--- commands (plugin/qzss.lua), the outline keymaps and external plugins all
--- call these functions. `require("qzss")` re-exports everything here plus a
--- few legacy helpers. Modules other than `qzss` and `qzss.api` are private.
---
--- Reference: docs/api.md and `:help qzss-api`.
local config = require("qzss.config")
local kinds = require("qzss.kinds")
local model = require("qzss.model")
local view = require("qzss.view")
local events = require("qzss.events")
local lspb = require("qzss.backends.lsp")
local tsb = require("qzss.backends.treesitter")

local M = {}
local api = vim.api

--- Version of this API contract. Bumped only for incompatible changes.
M.api_version = 1

---@alias qzss.Mode "sidebar"|"float"

---@class qzss.Position
---@field [1] integer row, 1-based
---@field [2] integer col, 0-based byte column

---@class qzss.Symbol
---@field id string stable id: parent path + kind + name (unique per buffer)
---@field name string
---@field kind string see :help qzss-kinds
---@field detail string signature or value preview ("" when none)
---@field bufnr integer source buffer
---@field depth integer 0 for top-level symbols
---@field parent_id string|nil
---@field pos qzss.Position start of the symbol name (jump target)
---@field range { start: qzss.Position, end: qzss.Position } whole declaration; end is exclusive
---@field children qzss.Symbol[]
---@field source "treesitter"|"lsp"|"treesitter+lsp" always set
---@field trait string|nil Rust trait impls
---@field self_type string|nil Rust impls
---@field type_params string|nil Rust impls
---@field where_clause string|nil Rust impls
---@field lsp_detail string|nil DocumentSymbol.detail when an LSP matched
---@field lsp_kind integer|nil LSP SymbolKind when an LSP matched

---@class qzss.Snapshot
---@field bufnr integer
---@field changedtick integer b:changedtick the symbols were computed from
---@field stale boolean the buffer changed since (a refresh is scheduled for tracked buffers)
---@field pending boolean an LSP response is still expected for this changedtick
---@field source string|nil
---@field error string|nil why there are no symbols (no parser / no LSP)
---@field lsp_error string|nil last LSP error (Tree-sitter symbols may still be present)
---@field filter string[]|nil active kind filter of the buffer
---@field symbols qzss.Symbol[]

local function notify(msg, level)
  vim.notify("qzss: " .. msg, level or vim.log.levels.WARN)
end

local function argerr(fn, msg)
  -- level 0: the message is exactly "qzss.<fn>: ..." (no file:line prefix
  -- pointing into qzss), as documented in docs/api.md#conventions
  error(("qzss.%s: %s"):format(fn, msg), 0)
end

local function check_opts(fn, opts)
  if opts ~= nil and type(opts) ~= "table" then
    argerr(fn, "opts must be a table or nil, got " .. type(opts))
  end
  return opts or {}
end

local function check_mode(fn, mode)
  if mode ~= nil and mode ~= "sidebar" and mode ~= "float" then
    argerr(fn, 'mode must be "sidebar", "float" or nil, got ' .. vim.inspect(mode))
  end
end

local function resolve_buf(fn, bufnr)
  if bufnr == nil or bufnr == 0 then
    return api.nvim_get_current_buf()
  end
  if type(bufnr) ~= "number" then
    argerr(fn, "bufnr must be a number or nil, got " .. type(bufnr))
  end
  return bufnr
end

-- default target buffer: the open outline's source, else the current buffer
local function default_buf(bufnr, fn)
  if bufnr == nil then
    local v = view.get()
    if v and v.src and api.nvim_buf_is_valid(v.src) then
      return v.src
    end
  end
  return resolve_buf(fn, bufnr)
end

local function safe_call(what, fn, ...)
  local ok, err = xpcall(fn, debug.traceback, ...)
  if not ok then
    vim.schedule(function()
      notify(what .. " failed: " .. tostring(err), vim.log.levels.ERROR)
    end)
  end
end

---------------------------------------------------------------- keymaps (UI actions -> public API)

local function map_keys(buf, mode)
  local km = config.options.keymaps
  local actions = {
    jump = function() M.jump() end,
    preview = function() M.jump({ preview = true }) end,
    toggle_fold = function() M.toggle_fold() end,
    open_fold = function() M.open_fold() end,
    close_fold = function() M.close_fold() end,
    open_all = function() M.open_all() end,
    close_all = function() M.close_all() end,
    refresh = function() M.refresh() end,
    close = function() M.close() end,
    help = function() M.help() end,
    float_close = function() M.close() end,
  }
  for name, fn in pairs(actions) do
    local keys = km[name]
    if name == "float_close" and mode ~= "float" then
      -- only mapped in float mode; drop it after a float -> sidebar switch
      for _, k in ipairs(type(keys) == "table" and keys or { keys }) do
        if k then
          pcall(vim.keymap.del, "n", k, { buffer = buf })
        end
      end
      keys = nil
    end
    if keys then
      for _, k in ipairs(type(keys) == "table" and keys or { keys }) do
        vim.keymap.set("n", k, fn, { buffer = buf, nowait = true, silent = true, desc = "qzss " .. name })
      end
    end
  end
end

---------------------------------------------------------------- setup

local group = api.nvim_create_augroup("qzss", { clear = true })
local timers = {}

local function schedule_refresh(bufnr)
  local m = model.peek(bufnr)
  if not m or m.tick < 0 then
    return -- untracked buffer: never requested and not shown
  end
  -- debounce with a token instead of a libuv handle: nothing to close when
  -- the buffer goes away, and a superseded tick simply does nothing
  local token = {}
  timers[bufnr] = token
  vim.defer_fn(function()
    if timers[bufnr] ~= token then
      return
    end
    timers[bufnr] = nil
    if api.nvim_buf_is_valid(bufnr) and model.peek(bufnr) then
      model.compute(bufnr)
    end
  end, config.options.update_delay)
end

local function drop_timer(bufnr)
  timers[bufnr] = nil
end

-- A tracked buffer was (re)loaded with a file, renamed or got a new filetype
-- without becoming a different buffer (e.g. `:edit file` in the empty
-- [No Name] buffer reuses its bufnr, `:edit!`, `:file`, `:set ft=`).
-- BufEnter does not retarget then, so recompute right away (on the next
-- tick, once filetype detection has run) instead of waiting for an edit.
local function reload_refresh(bufnr)
  local m = model.peek(bufnr)
  local shown = false
  for tab, v in pairs(view.views) do
    if v.src == bufnr and view.get(tab) then
      shown = true
    end
  end
  if not shown and (not m or m.tick < 0) then
    return -- untracked buffer: never requested and not shown
  end
  local token = {}
  timers[bufnr] = token -- supersedes a pending debounced refresh
  vim.schedule(function()
    if timers[bufnr] ~= token then
      return
    end
    timers[bufnr] = nil
    if api.nvim_buf_is_valid(bufnr) and api.nvim_buf_is_loaded(bufnr) then
      model.compute(bufnr)
    end
  end)
end

-- true when closing window `closing` would leave only the outline (and other
-- floating windows) in the current tab.
local function only_outline_left(v, closing)
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if w ~= v.win and w ~= closing and api.nvim_win_get_config(w).relative == "" then
      return false
    end
  end
  return true
end

--- Close the sidebar's tab (or quit) when the sidebar is its last window.
function M._close_if_alone()
  local v = view.get()
  if not v or v.mode ~= "sidebar" or not only_outline_left(v, nil) then
    return
  end
  pcall(api.nvim_set_current_win, v.win)
  if #api.nvim_list_tabpages() > 1 then
    view.forget(api.nvim_get_current_tabpage(), "tab_closed")
    pcall(vim.cmd, "tabclose")
  else
    -- last window of the last tab: quit like :q would have
    local ok = pcall(vim.cmd, "quit")
    if not ok then
      -- unsaved buffers elsewhere: keep Neovim alive with an empty window
      view.close(nil, "source_closed")
    end
  end
end

local function on_buf_gone(bufnr, reason)
  -- decide after the command finished: some commands (e.g. `:write name` of
  -- an unnamed buffer) fire BufUnload for a buffer that stays loaded
  vim.schedule(function()
    if api.nvim_buf_is_valid(bufnr) and api.nvim_buf_is_loaded(bufnr) then
      return
    end
    drop_timer(bufnr)
    model.fail(bufnr, api.nvim_buf_is_valid(bufnr) and reason or "buffer deleted")
    for tab, v in pairs(view.views) do
      if v.src == bufnr and view.get(tab) then
        local w = v.src_win
        local nb = w and api.nvim_win_is_valid(w) and api.nvim_win_get_buf(w)
        if nb and nb ~= bufnr and view.is_source_buf(nb) then
          view.retarget(v, nb, w)
          M.refresh(nb)
        else
          view.close(tab, "source_deleted")
        end
      end
    end
  end)
end

local function create_autocmds()
  api.nvim_clear_autocmds({ group = group })
  local au = function(ev, fn)
    api.nvim_create_autocmd(ev, { group = group, callback = fn })
  end
  au({ "TextChanged", "TextChangedI", "BufWritePost", "LspAttach" }, function(ev)
    schedule_refresh(ev.buf)
  end)
  au("BufEnter", function(ev)
    local v = view.get()
    if not v or ev.buf == v.buf or not view.is_source_buf(ev.buf) then
      return
    end
    if api.nvim_get_current_win() == v.win then
      -- A file was opened inside the outline window (:edit, :b, ...): the
      -- outline buffer is gone. Show the file in the source window; rebuild
      -- a sidebar, close a float (it would cover the file just opened).
      local tab = api.nvim_get_current_tabpage()
      local mode = v.mode
      view.forget(tab, "edit_in_outline")
      vim.schedule(function()
        if not api.nvim_buf_is_valid(ev.buf) then
          return
        end
        local w = v.src_win
        if w and w ~= v.win and api.nvim_win_is_valid(w) and api.nvim_win_get_tabpage(w) == tab then
          pcall(api.nvim_win_set_buf, w, ev.buf)
          if api.nvim_win_is_valid(v.win) then
            pcall(api.nvim_win_close, v.win, true)
          end
          api.nvim_set_current_win(w)
        elseif api.nvim_win_is_valid(v.win) then
          if api.nvim_win_get_config(v.win).relative ~= "" then
            -- float with no source window left: move the file to a normal window
            local others = vim.tbl_filter(function(x)
              return api.nvim_win_get_config(x).relative == ""
            end, api.nvim_tabpage_list_wins(tab))
            if others[1] then
              pcall(api.nvim_win_set_buf, others[1], ev.buf)
              pcall(api.nvim_win_close, v.win, true)
              api.nvim_set_current_win(others[1])
            end
          else
            -- no other window: turn the sidebar window into a normal one
            api.nvim_win_call(v.win, function()
              vim.cmd("setlocal number< relativenumber< signcolumn< foldcolumn< wrap< list< spell< cursorline< winfixwidth< winbar<")
            end)
          end
        end
        if mode == "sidebar" then
          M.open({ focus = false, mode = "sidebar" })
        end
      end)
      return
    end
    if api.nvim_win_get_config(api.nvim_get_current_win()).relative ~= "" then
      return -- other floating windows (pickers, hovers) do not retarget
    end
    v.src_win = api.nvim_get_current_win()
    if ev.buf ~= v.src then
      view.retarget(v, ev.buf)
      M.refresh(ev.buf)
    end
  end)
  au({ "CursorMoved", "CursorMovedI" }, function(ev)
    local v = view.get()
    if v and ev.buf == v.src and config.options.follow_cursor and api.nvim_get_current_win() ~= v.win then
      if api.nvim_win_get_config(api.nvim_get_current_win()).relative == "" then
        v.src_win = api.nvim_get_current_win()
      end
      view.follow(v)
    end
  end)
  au("WinClosed", function(ev)
    local closed = tonumber(ev.match)
    for tab, v in pairs(view.views) do
      if v.win == closed then
        view.forget(tab, "window_closed")
      elseif v.mode == "float" and v.src_win == closed then
        vim.schedule(function()
          if view.get(tab) ~= v or v.src_win ~= closed then
            return
          end
          local target
          for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
            local buf = api.nvim_win_get_buf(win)
            if api.nvim_win_get_config(win).relative == "" and view.is_source_buf(buf) then
              target = target or win
              if buf == v.src then
                target = win
                break
              end
            end
          end
          if target then
            view.retarget(v, api.nvim_win_get_buf(target), target)
            M.refresh(v.src)
            view.reposition(v)
          else
            view.close(tab, "source_closed")
          end
        end)
      end
    end
    -- a source window closed by other means (:close, :q! on a modified
    -- buffer, ...): never leave the sidebar as the only window
    vim.schedule(M._close_if_alone)
  end)
  au("TabClosed", function()
    for tab in pairs(view.views) do
      if not api.nvim_tabpage_is_valid(tab) then
        view.forget(tab, "tab_closed")
      end
    end
  end)
  au("TabEnter", function()
    local v = view.get()
    if v then
      view.reposition(v)
    end
  end)
  au("QuitPre", function()
    -- `:q` in the last source window: close the outline first so the
    -- quit closes the tab / exits Neovim instead of leaving the outline
    local v = view.get()
    local cur = api.nvim_get_current_win()
    if not v or cur == v.win or not only_outline_left(v, cur) then
      return
    end
    local buf = api.nvim_get_current_buf()
    if vim.bo[buf].modified and #vim.fn.win_findbuf(buf) == 1 and not vim.o.hidden then
      return -- :q will fail with E37; keep the layout (WinClosed handles :q!)
    end
    view.close(nil, "quit")
  end)
  au("VimResized", function()
    for tab in pairs(view.views) do
      local v = view.get(tab)
      if v then
        if v.mode == "float" then
          view.reposition(v)
        elseif tab == api.nvim_get_current_tabpage() then
          view.render(v)
        end
      end
    end
  end)
  au("WinResized", function()
    local v = view.get()
    if v and v.mode == "float" and config.options.layout.float.relative == "win" then
      view.reposition(v)
    end
  end)
  au("BufWipeout", function(ev)
    on_buf_gone(ev.buf, "buffer deleted")
  end)
  au("BufUnload", function(ev)
    if model.peek(ev.buf) then
      on_buf_gone(ev.buf, "buffer unloaded")
    end
  end)
  au("ColorScheme", function()
    kinds.setup_highlights(config.options.highlights)
  end)
  au("FileType", function(ev)
    local fk = config.options.filter_kinds[ev.match]
    if fk and ev.match ~= "qzss" then
      model.set_filter(ev.buf, fk)
    end
    if ev.match ~= "qzss" then
      reload_refresh(ev.buf)
    end
  end)
  au({ "BufReadPost", "BufFilePost" }, function(ev)
    reload_refresh(ev.buf)
  end)
end

--- Configure qzss. Optional: every function works with the defaults.
--- Raises an error (message starts with "qzss: invalid option") for invalid
--- layout options; the previous configuration then stays active.
---@param opts table|nil see :help qzss-options
function M.setup(opts)
  config.setup(opts)
  kinds.setup_highlights(config.options.highlights)
  create_autocmds()
  if config.options.toggle_key then
    vim.keymap.set("n", config.options.toggle_key, function()
      M.toggle()
    end, { desc = "qzss: toggle outline" })
  end
  M._did_setup = true
end

local function ensure_setup()
  if not M._did_setup then
    M.setup()
  end
end

---------------------------------------------------------------- view lifecycle

--- Open the outline of the current buffer in the current tab.
--- Already open: switches to `opts.mode` when given (keeping cursor, folds,
--- filter) and focuses it unless `focus = false`.
---@param opts { focus?: boolean, mode?: qzss.Mode }|nil
---@return boolean ok, string|nil err
function M.open(opts)
  opts = check_opts("open", opts)
  check_mode("open", opts.mode)
  ensure_setup()
  local src = api.nvim_get_current_buf()
  local src_win = api.nvim_get_current_win()
  local v = view.get()
  if v then
    if opts.mode and opts.mode ~= v.mode then
      view.switch(v, opts.mode, map_keys)
      if view.get(v.tab) ~= v then
        return true -- a mode subscriber closed or replaced this view
      end
    end
    if src_win ~= v.win and view.is_source_buf(src) and api.nvim_win_get_config(src_win).relative == "" then
      v.src_win = src_win
      if src ~= v.src then
        view.retarget(v, src, src_win)
        M.refresh(src)
      end
    end
    if view.get(v.tab) ~= v then
      return true
    end
    if opts.focus ~= false then
      api.nvim_set_current_win(v.win)
    elseif api.nvim_get_current_win() == v.win and v.src_win and api.nvim_win_is_valid(v.src_win) then
      api.nvim_set_current_win(v.src_win) -- focus = false: leave the outline
    end
    return true
  end
  if not view.is_source_buf(src) then
    notify("current buffer is not a file buffer", vim.log.levels.ERROR)
    return false, "current buffer is not a file buffer"
  end
  if api.nvim_win_get_config(src_win).relative ~= "" then
    notify("cannot open the outline from a floating window", vim.log.levels.ERROR)
    return false, "current window is floating"
  end
  local mode = opts.mode or config.options.layout.mode
  v = view.create(mode, src, src_win, opts.focus, map_keys)
  events.emit("open", {
    tabpage = v.tab,
    mode = v.mode,
    winid = v.win,
    bufnr = v.buf,
    source_bufnr = src,
    focused = api.nvim_get_current_win() == v.win,
  })
  if view.get(v.tab) == v then
    M.refresh(src)
    if view.get(v.tab) == v and config.options.follow_cursor then
      view.follow(v, true) -- start on the symbol under the source cursor, focused or not
    end
  end
  return true
end

--- Close the outline of the current tab. Returns true when one was open.
---@return boolean
function M.close()
  return view.close(nil, "close")
end

--- Close when open (any mode), else open with `opts`.
---@param opts { focus?: boolean, mode?: qzss.Mode }|nil
function M.toggle(opts)
  opts = check_opts("toggle", opts)
  check_mode("toggle", opts.mode)
  if view.get() then
    M.close()
    return true
  end
  return M.open(opts)
end

--- Whether the current tab shows an outline. With `mode`, also require that mode.
---@param opts { mode?: qzss.Mode }|nil
function M.is_open(opts)
  opts = check_opts("is_open", opts)
  check_mode("is_open", opts.mode)
  local v = view.get()
  return v ~= nil and (opts.mode == nil or v.mode == opts.mode)
end

--- Copy of the current tab's outline view state, or nil when closed.
---@param opts { tabpage?: integer }|nil
---@return { tabpage: integer, mode: qzss.Mode, winid: integer, bufnr: integer, source_bufnr: integer, source_winid: integer|nil, focused: boolean, cursor_symbol_id: string|nil, filter: string[]|nil, folded: string[], width: integer, height: integer }|nil
function M.get_view(opts)
  opts = check_opts("get_view", opts)
  local v = view.get(opts.tabpage)
  if not v then
    return nil
  end
  local sym = view.current_row_sym(v)
  local src_win = v.src_win and api.nvim_win_is_valid(v.src_win) and v.src_win or nil
  return {
    tabpage = v.tab,
    mode = v.mode,
    winid = v.win,
    bufnr = v.buf,
    source_bufnr = v.src,
    source_winid = src_win,
    focused = api.nvim_get_current_win() == v.win,
    cursor_symbol_id = sym and sym.id or nil,
    filter = M.get_filter(v.src),
    folded = M.get_folded(v.src),
    width = api.nvim_win_get_width(v.win),
    height = api.nvim_win_get_height(v.win),
  }
end

---------------------------------------------------------------- symbols

--- Recompute the symbols of `bufnr` (default: the outline's source, else
--- the current buffer). Outlines showing it re-render; `symbols` events fire.
---@param bufnr integer|nil
function M.refresh(bufnr)
  ensure_setup()
  bufnr = default_buf(bufnr, "refresh")
  model.compute(bufnr)
end

--- Cached symbols of `bufnr`; never computes. Returns nil, "not_ready" when
--- nothing was computed yet (use request_symbols()).
---@param bufnr integer|nil 0/nil = current buffer
---@return qzss.Snapshot|nil, string|nil err
function M.get_snapshot(bufnr)
  bufnr = resolve_buf("get_snapshot", bufnr)
  local bad = model.unusable(bufnr)
  if bad then
    return nil, bad
  end
  local snap = model.snapshot(bufnr)
  if not snap then
    return nil, "not_ready"
  end
  return snap
end

--- Asynchronously get up-to-date symbols without opening any UI.
--- `callback(err, snapshot)` is always called later from the main loop
--- (never before this function returns) and exactly once, unless cancelled.
--- Requests for the same changedtick share one computation. When the buffer
--- changes before the LSP answers, the result is recomputed; you never get
--- symbols older than the text at request time.
---@param bufnr integer|nil 0/nil = current buffer
---@param callback fun(err: string|nil, snapshot: qzss.Snapshot|nil)
---@return { cancel: fun(): boolean } handle cancel() returns true when the callback was still pending
function M.request_symbols(bufnr, callback)
  bufnr = resolve_buf("request_symbols", bufnr)
  if type(callback) ~= "function" then
    argerr("request_symbols", "callback must be a function, got " .. type(callback))
  end
  ensure_setup()
  local w = model.request(bufnr, function(err, snap)
    safe_call("request_symbols callback", callback, err, snap)
  end)
  return {
    cancel = function()
      return model.cancel(w)
    end,
  }
end

local function public_index(bufnr, m)
  if not m.public_cache or m.public_cache.tick ~= m.tick then
    local idx = {}
    local tree = model.public_tree(bufnr, m.symbols, nil, 0, nil, model.default_source(m))
    local function walk(list)
      for _, s in ipairs(list) do
        idx[s.id] = s
        walk(s.children)
      end
    end
    walk(tree)
    m.public_cache = { tick = m.tick, index = idx }
  end
  return m.public_cache.index
end

--- Public copy of the symbol with `id` in `bufnr` (from the cache).
---@return qzss.Symbol|nil, string|nil err
function M.find_symbol(bufnr, id)
  bufnr = resolve_buf("find_symbol", bufnr)
  if type(id) ~= "string" then
    argerr("find_symbol", "id must be a string, got " .. type(id))
  end
  local m = model.peek(bufnr)
  if not m or m.tick < 0 then
    return nil, "not_ready"
  end
  local s = public_index(bufnr, m)[id]
  if not s then
    return nil, "unknown symbol id"
  end
  return vim.deepcopy(s)
end

--- Innermost symbol containing a position, from the cache.
--- Called from the outline window it returns the selected row's symbol.
--- When nothing is cached yet it starts a background request and returns
--- nil, "pending" (subscribe to `symbols` to redraw).
---@param opts { bufnr?: integer, winid?: integer, row?: integer }|nil row is 1-based
---@return qzss.Symbol|nil, qzss.Symbol[]|string path_or_err path from the top-level ancestor to the symbol
function M.current_symbol(opts)
  opts = check_opts("current_symbol", opts)
  ensure_setup()
  local win = opts.winid or api.nvim_get_current_win()
  if type(win) ~= "number" or not api.nvim_win_is_valid(win) then
    return nil, "invalid window"
  end
  local v = view.get()
  local bufnr, row
  if not opts.bufnr and v and win == v.win then
    local sym = view.current_row_sym(v)
    if not sym then
      return nil, "no symbol"
    end
    bufnr, row = v.src, nil
    local s, err = M.find_symbol(bufnr, sym.id)
    if not s then
      return nil, err
    end
    local path = { s }
    local p = s.parent_id
    while p do
      local a = M.find_symbol(bufnr, p)
      if not a then
        break
      end
      table.insert(path, 1, a)
      p = a.parent_id
    end
    return s, path
  end
  bufnr = resolve_buf("current_symbol", opts.bufnr or api.nvim_win_get_buf(win))
  local bad = model.unusable(bufnr)
  if bad then
    return nil, bad
  end
  row = opts.row
  if row == nil then
    if api.nvim_win_get_buf(win) ~= bufnr then
      return nil, "window does not show the buffer"
    end
    row = api.nvim_win_get_cursor(win)[1]
  end
  local m = model.peek(bufnr)
  if not m or m.tick < 0 then
    model.request(bufnr, function() end)
    return nil, "pending"
  end
  local sym = model.symbol_at(bufnr, row - 1)
  if not sym then
    return nil, "no symbol"
  end
  local idx = public_index(bufnr, m)
  local path = {}
  local s = sym
  while s do
    table.insert(path, 1, vim.deepcopy(idx[s.id]))
    s = s.parent
  end
  return path[#path], path
end

--- Move the cursor to a symbol. `target` is a qzss.Symbol (or any table with
--- `bufnr` and `pos`) or a symbol id string (needs opts.bufnr or the current
--- buffer). Uses opts.winid, else a window of the current tab showing the
--- buffer, else the outline's source window, else the current window.
--- The outline (if open) stays open; close_on_jump only applies to <CR>.
---@param target qzss.Symbol|string
---@param opts { bufnr?: integer, winid?: integer, focus?: boolean }|nil
---@return boolean ok, string|nil err
function M.jump_to(target, opts)
  opts = check_opts("jump_to", opts)
  local bufnr, row, col
  if type(target) == "string" then
    bufnr = default_buf(opts.bufnr, "jump_to")
    local s, err = M.find_symbol(bufnr, target)
    if not s then
      return false, err
    end
    row, col = s.pos[1], s.pos[2]
  elseif type(target) == "table" then
    bufnr = target.bufnr
    local pos = target.pos
    if type(bufnr) ~= "number" or type(pos) ~= "table" or type(pos[1]) ~= "number" or type(pos[2]) ~= "number" then
      argerr("jump_to", "target table needs numeric bufnr and pos = { row, col }")
    end
    row, col = pos[1], pos[2]
  else
    argerr("jump_to", "target must be a symbol table or an id string, got " .. type(target))
  end
  if not api.nvim_buf_is_valid(bufnr) then
    return false, "invalid buffer"
  end
  local win = opts.winid
  if win ~= nil and (type(win) ~= "number" or not api.nvim_win_is_valid(win)) then
    return false, "invalid window"
  end
  local v = view.get()
  if not win then
    if v and v.src == bufnr then
      win = view.source_window(v)
    else
      for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
        if api.nvim_win_get_buf(w) == bufnr and api.nvim_win_get_config(w).relative == "" then
          win = w
          break
        end
      end
    end
  end
  if not win then
    win = api.nvim_get_current_win()
    if (v and win == v.win) or api.nvim_win_get_config(win).relative ~= "" then
      win = v and v.src_win and api.nvim_win_is_valid(v.src_win) and v.src_win or nil
      if not win then
        return false, "no window to show the buffer"
      end
    end
  end
  if api.nvim_win_get_buf(win) ~= bufnr then
    local ok, err = pcall(api.nvim_win_set_buf, win, bufnr)
    if not ok then
      return false, tostring(err)
    end
  end
  view.set_cursor(win, row, col)
  if opts.focus ~= false then
    api.nvim_set_current_win(win)
  end
  return true
end

---------------------------------------------------------------- filter & folds

local function state_event(bufnr, what)
  events.emit("state", { bufnr = bufnr, what = what, filter = M.get_filter(bufnr), folded = M.get_folded(bufnr) })
end

--- Show only the given kinds for `bufnr` (default: outline source, else
--- current buffer). nil or {} clears. Unknown kinds: error notification,
--- filter unchanged, returns false.
---@param kind_list string[]|nil
---@param bufnr integer|nil
---@return boolean
function M.set_filter(kind_list, bufnr)
  if kind_list ~= nil and type(kind_list) ~= "table" then
    argerr("set_filter", "kinds must be a list of kind names or nil, got " .. type(kind_list))
  end
  bufnr = default_buf(bufnr, "set_filter")
  for _, k in ipairs(kind_list or {}) do
    if not vim.tbl_contains(kinds.list, k) then
      notify("unknown kind '" .. tostring(k) .. "' (see :help qzss-kinds)", vim.log.levels.ERROR)
      return false
    end
  end
  model.set_filter(bufnr, kind_list)
  view.render_buf(bufnr)
  state_event(bufnr, "filter")
  return true
end

--- Active kind filter of `bufnr` (sorted list) or nil.
---@return string[]|nil
function M.get_filter(bufnr)
  bufnr = default_buf(bufnr, "get_filter")
  local m = model.peek(bufnr)
  if not m or not m.kind_set then
    return nil
  end
  local ks = vim.tbl_keys(m.kind_set)
  table.sort(ks)
  return ks
end

--- Ids of folded (collapsed) symbols of `bufnr`, sorted.
---@return string[]
function M.get_folded(bufnr)
  bufnr = default_buf(bufnr, "get_folded")
  local m = model.peek(bufnr)
  local ids = {}
  for id, on in pairs(m and m.collapsed or {}) do
    if on then
      table.insert(ids, id)
    end
  end
  table.sort(ids)
  return ids
end

--- Fold (true) or unfold (false) the symbol `id` of opts.bufnr (default:
--- outline source, else current buffer). Only symbols with children fold.
---@return boolean ok, string|nil err
function M.set_folded(id, folded, opts)
  if type(id) ~= "string" then
    argerr("set_folded", "id must be a string, got " .. type(id))
  end
  if type(folded) ~= "boolean" then
    argerr("set_folded", "folded must be a boolean, got " .. type(folded))
  end
  opts = check_opts("set_folded", opts)
  local bufnr = default_buf(opts.bufnr, "set_folded")
  local m = model.peek(bufnr)
  if not m or m.tick < 0 then
    return false, "not_ready"
  end
  local s = model.find_internal(m, id)
  if not s then
    return false, "unknown symbol id"
  end
  if #s.children == 0 then
    return false, "symbol has no children"
  end
  m.collapsed[id] = folded or nil
  view.render_buf(bufnr)
  state_event(bufnr, "fold")
  return true
end

local function fold_all(action, bufnr)
  local v = view.get()
  local row_ctx = bufnr == nil and v ~= nil
  bufnr = default_buf(bufnr, action)
  local m = model.get(bufnr)
  local sym = row_ctx and v.src == bufnr and view.current_row_sym(v) or nil
  if action == "open_all" then
    m.collapsed = {}
  else
    model.close_all(m)
  end
  view.render_buf(bufnr)
  if action == "close_all" and row_ctx and v.src == bufnr then
    local top = sym
    while top and top.parent do
      top = top.parent
    end
    local r = top and v.row_by_id[top.id]
    if r then
      pcall(api.nvim_win_set_cursor, v.win, { r, 0 })
    end
  end
  state_event(bufnr, "fold")
  return true
end

--- Unfold every symbol of `bufnr` (default: outline source, else current buffer).
function M.open_all(bufnr)
  return fold_all("open_all", bufnr)
end

--- Fold every symbol with children of `bufnr`.
function M.close_all(bufnr)
  return fold_all("close_all", bufnr)
end

---------------------------------------------------------------- outline UI actions (cursor row based)

local function row_fold(action)
  local v = view.get()
  if not v then
    return false
  end
  local m = model.get(v.src)
  local sym = view.current_row_sym(v)
  if not sym then
    return false
  end
  local has_kids = #sym.children > 0
  if action == "toggle" and has_kids then
    m.collapsed[sym.id] = not m.collapsed[sym.id] or nil
  elseif action == "open" and has_kids then
    m.collapsed[sym.id] = nil
  elseif action == "close" then
    if has_kids and not m.collapsed[sym.id] then
      m.collapsed[sym.id] = true
    elseif sym.parent then
      m.collapsed[sym.parent.id] = true
      view.render_buf(v.src)
      local r = v.row_by_id[sym.parent.id]
      if r then
        pcall(api.nvim_win_set_cursor, v.win, { r, 0 })
      end
      state_event(v.src, "fold")
      return true
    end
  end
  view.render_buf(v.src)
  state_event(v.src, "fold")
  return true
end

--- Toggle the fold of the outline cursor row (no-op when closed).
function M.toggle_fold()
  return row_fold("toggle")
end
--- Open the fold of the outline cursor row.
function M.open_fold()
  return row_fold("open")
end
--- Close the fold of the cursor row, or its parent on a leaf/closed row.
function M.close_fold()
  return row_fold("close")
end

--- Jump to the symbol under the outline cursor (the <CR>/p keys).
--- `preview = true` moves the source cursor and keeps focus in the outline.
--- Otherwise focus moves to the source and close_on_jump applies.
---@param opts { preview?: boolean }|nil
---@return boolean
function M.jump(opts)
  opts = check_opts("jump", opts)
  local v = view.get()
  if not v then
    return false
  end
  local win = view.jump_row(v, opts.preview)
  if not win then
    return false
  end
  if not opts.preview and view.close_on_jump(v) then
    M.close()
    if api.nvim_win_is_valid(win) then
      api.nvim_set_current_win(win)
    end
  end
  return true
end

--- Show the key help float.
function M.help()
  return view.help()
end

---------------------------------------------------------------- events

--- Subscribe to an event: "symbols", "open", "close", "mode", "state" or "*".
--- Returns an id for unsubscribe(). See docs/api.md#events for payloads.
---@param event string
---@param callback fun(payload: table)
---@return integer id
function M.subscribe(event, callback)
  if type(event) ~= "string" or not events.is_event(event) then
    argerr("subscribe", "unknown event " .. vim.inspect(event) .. " (symbols, open, close, mode, state, *)")
  end
  if type(callback) ~= "function" then
    argerr("subscribe", "callback must be a function, got " .. type(callback))
  end
  ensure_setup()
  return events.subscribe(event, callback)
end

--- Remove a subscription. Returns false when the id is unknown.
---@param id integer
---@return boolean
function M.unsubscribe(id)
  return events.unsubscribe(id)
end

---------------------------------------------------------------- info

--- Echo and return diagnostic lines (source, LSP clients, errors).
---@return string[]
function M.info()
  local v = view.get()
  local bufnr = v and v.src or api.nvim_get_current_buf()
  local m = model.peek(bufnr) or {}
  local ft = vim.bo[bufnr].filetype
  local clients = vim.tbl_map(function(c)
    return c.name
  end, lspb.clients(bufnr))
  local lines = {
    "qzss info",
    "buffer: " .. api.nvim_buf_get_name(bufnr),
    "filetype: " .. ft .. "  tree-sitter language: " .. tostring(tsb.lang_for(ft)),
    "backends: " .. table.concat(config.options.backends, ", "),
    "source: " .. tostring(m.source),
    "lsp clients: " .. (#clients > 0 and table.concat(clients, ", ") or "none"),
    "layout: " .. (v and v.mode or "closed") .. " (default " .. config.options.layout.mode .. ")",
    "error: " .. tostring(m.error),
    "lsp error: " .. tostring(m.lsp_error),
  }
  api.nvim_echo({ { table.concat(lines, "\n") } }, true, {})
  return lines
end

return M
