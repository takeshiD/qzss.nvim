-- qzss.nvim: semantic outline sidebar for Rust, TypeScript/TSX, JSON and YAML.
local config = require("qzss.config")
local kinds = require("qzss.kinds")
local render = require("qzss.render")
local tsb = require("qzss.backends.treesitter")
local lspb = require("qzss.backends.lsp")

local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("qzss")
local group = api.nvim_create_augroup("qzss", { clear = true })

-- per source buffer state
local bufs = {}
-- per tabpage sidebar state: { win, buf, src }
local sidebars = {}

local function notify(msg, level)
  vim.notify("qzss: " .. msg, level or vim.log.levels.WARN)
end

local function bstate(bufnr)
  bufs[bufnr] = bufs[bufnr] or { collapsed = {}, symbols = {}, initialized = false, tick = -1 }
  return bufs[bufnr]
end

--- Clamp a sidebar width so the source window stays usable on narrow
--- terminals: the sidebar never takes more than max(columns - 30, columns / 2).
function M._fit_width(w)
  local cols = vim.o.columns
  local cap = math.max(cols - 30, math.floor(cols / 2))
  return math.max(1, math.min(w, cap))
end

local function sidebar()
  local sb = sidebars[api.nvim_get_current_tabpage()]
  if sb and sb.win and api.nvim_win_is_valid(sb.win) then
    return sb
  end
  return nil
end

local function is_source_buf(bufnr)
  return api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buftype == "" and vim.bo[bufnr].filetype ~= "qzss"
end

local function has_backend(name)
  return vim.tbl_contains(config.options.backends, name)
end

---------------------------------------------------------------- outline data

local function apply_collapse_level(bs)
  local level = config.options.collapse_level
  if not level then
    return
  end
  local function walk(list, depth)
    for _, s in ipairs(list) do
      if depth >= level and #s.children > 0 then
        bs.collapsed[s.id] = true
      end
      walk(s.children, depth + 1)
    end
  end
  walk(bs.symbols, 0)
end

--- Compute symbols for a buffer. `cb` may be called twice: once with
--- Tree-sitter symbols (synchronously) and again after the LSP merge.
function M.compute(bufnr, cb)
  cb = cb or function() end
  local bs = bstate(bufnr)
  local o = config.options
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
  bs.tick = tick
  if ts_syms then
    bs.symbols = render.assign_ids(ts_syms)
    bs.source = "treesitter"
    bs.error = nil
    if not bs.initialized then
      apply_collapse_level(bs)
      bs.initialized = true
    end
    cb(bs)
  end
  if has_backend("lsp") and lspb.available(bufnr) then
    lspb.request(bufnr, function(lsyms, err)
      vim.schedule(function()
        if not api.nvim_buf_is_valid(bufnr) or bs.tick ~= tick then
          return -- a newer refresh superseded this response
        end
        if err then
          bs.lsp_error = err
          if not ts_syms then
            bs.symbols = {}
            bs.error = err
            cb(bs)
          end
          return
        end
        bs.lsp_error = nil
        if ts_syms then
          lspb.merge(ts_syms, lsyms, o.detail_source)
          bs.source = "treesitter+lsp"
        else
          bs.symbols = render.assign_ids(lspb.refine_kinds(bufnr, lspb.sort(lsyms)))
          bs.source = "lsp"
          bs.error = nil
          if not bs.initialized then
            apply_collapse_level(bs)
            bs.initialized = true
          end
        end
        cb(bs)
      end)
    end, 8000)
  elseif not ts_syms then
    bs.symbols = {}
    bs.source = nil
    bs.error = (ts_err or "no outline source") .. "; no LSP client with documentSymbol attached"
    cb(bs)
  end
end

--- Synchronous Tree-sitter symbols (API for scripts/tests).
function M.get_symbols(bufnr)
  bufnr = bufnr == 0 and api.nvim_get_current_buf() or (bufnr or api.nvim_get_current_buf())
  local syms, err = tsb.get_symbols(bufnr, { max_detail = config.options.max_detail })
  if syms then
    render.assign_ids(syms)
  end
  return syms, err
end

--- Render symbols to plain lines (all nodes expanded unless collapsed given).
function M.outline_lines(bufnr, symbols, collapsed)
  bufnr = (bufnr == nil or bufnr == 0) and api.nvim_get_current_buf() or bufnr
  local bs = bstate(bufnr)
  local lines = render.build(symbols or M.get_symbols(bufnr) or {}, {
    collapsed = collapsed or {},
    bufnr = bufnr,
    filetype = vim.bo[bufnr].filetype,
    kind_set = bs.kind_set,
  })
  return lines
end

---------------------------------------------------------------- sidebar rendering

local function current_row_sym(sb)
  if not (sb and sb.rows) then
    return nil
  end
  local row = api.nvim_win_get_cursor(sb.win)[1]
  return sb.rows[row]
end

local function row_of(sb, sym)
  while sym do
    local r = sb.row_by_id and sb.row_by_id[sym.id]
    if r then
      return r
    end
    sym = sym.parent
  end
  return nil
end

local function set_winbar(sb, bs)
  local name = vim.fn.fnamemodify(api.nvim_buf_get_name(sb.src), ":t")
  if name == "" then
    name = "[No Name]"
  end
  local esc = function(s)
    return (s:gsub("%%", "%%%%"))
  end
  local parts = { bs.source or "no source" }
  if bs.kind_set then
    table.insert(parts, "filter:" .. table.concat(vim.tbl_keys(bs.kind_set), ","))
  end
  if bs.lsp_error and bs.source == "treesitter" then
    table.insert(parts, "lsp: error")
  end
  table.insert(parts, "? help")
  -- `%<` makes a narrow sidebar truncate the tail (source, filter, help hint)
  -- instead of the "qzss · file" head.
  vim.wo[sb.win].winbar = " qzss · " .. esc(name) .. "%< · " .. esc(table.concat(parts, " · "))
end

function M.render()
  local sb = sidebar()
  if not sb or not api.nvim_buf_is_valid(sb.src) or not api.nvim_buf_is_valid(sb.buf) then
    return
  end
  local bs = bstate(sb.src)
  local keep = current_row_sym(sb)
  local lines, hls, rows = render.build(bs.symbols, {
    collapsed = bs.collapsed,
    bufnr = sb.src,
    filetype = vim.bo[sb.src].filetype,
    kind_set = bs.kind_set,
  })
  local msg = false
  if #lines == 0 then
    msg = true
    lines = { bs.error and ("qzss: " .. bs.error) or "qzss: no symbols" }
  end
  sb.rows = rows
  sb.row_by_id = {}
  for r, s in pairs(rows) do
    sb.row_by_id[s.id] = r
  end
  vim.bo[sb.buf].modifiable = true
  api.nvim_buf_set_lines(sb.buf, 0, -1, false, lines)
  vim.bo[sb.buf].modifiable = false
  api.nvim_buf_clear_namespace(sb.buf, ns, 0, -1)
  if msg then
    api.nvim_buf_set_extmark(sb.buf, ns, 0, 0, { end_col = #lines[1], hl_group = "QzssMessage" })
  end
  for _, h in ipairs(hls) do
    pcall(api.nvim_buf_set_extmark, sb.buf, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
  set_winbar(sb, bs)
  -- size the sidebar to its content within [width, max_width]
  local lay = config.options.layout
  local w = lay.width
  if lay.max_width and lay.max_width > lay.width then
    local longest = 0
    for _, l in ipairs(lines) do
      longest = math.max(longest, vim.fn.strdisplaywidth(l))
    end
    w = math.max(lay.width, math.min(lay.max_width, longest + 1))
    -- growing for long rows never takes more than half of the editor
    w = math.min(w, math.max(lay.width, math.floor(vim.o.columns / 2)))
  end
  if #api.nvim_tabpage_list_wins(0) > 1 then
    pcall(api.nvim_win_set_width, sb.win, M._fit_width(w))
  end
  -- keep the selected node (or its nearest visible ancestor) selected
  if keep then
    local r = sb.row_by_id[keep.id]
    if not r then
      -- the node may be a filter copy; look up by id through the original parent chain
      local p = keep.parent
      while p and not r do
        r = sb.row_by_id[p.id]
        p = p.parent
      end
    end
    if r then
      api.nvim_win_set_cursor(sb.win, { r, 0 })
    end
  end
end

function M.refresh(bufnr)
  local sb = sidebar()
  bufnr = bufnr or (sb and sb.src) or api.nvim_get_current_buf()
  M.compute(bufnr, function()
    local s = sidebar()
    if s and s.src == bufnr then
      M.render()
      if config.options.follow_cursor then
        M.follow()
      end
    end
  end)
end

---------------------------------------------------------------- cursor follow & jump

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

function M.symbol_at(bufnr, line)
  return deepest_at(bstate(bufnr).symbols, line)
end

function M.follow()
  local sb = sidebar()
  if not sb then
    return
  end
  local win = sb.src_win
  if not (win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == sb.src) then
    return
  end
  local line = api.nvim_win_get_cursor(win)[1] - 1
  local sym = M.symbol_at(sb.src, line)
  local r = sym and row_of(sb, sym)
  if r and api.nvim_get_current_win() ~= sb.win then
    api.nvim_win_set_cursor(sb.win, { r, 0 })
  end
end

local function source_window(sb)
  if sb.src_win and api.nvim_win_is_valid(sb.src_win) and api.nvim_win_get_buf(sb.src_win) == sb.src then
    return sb.src_win
  end
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if w ~= sb.win and api.nvim_win_get_buf(w) == sb.src then
      return w
    end
  end
  -- source no longer visible: open it next to the sidebar
  api.nvim_set_current_win(sb.win)
  vim.cmd(config.options.layout.position == "left" and "rightbelow vsplit" or "leftabove vsplit")
  local w = api.nvim_get_current_win()
  api.nvim_win_set_buf(w, sb.src)
  api.nvim_win_set_width(sb.win, M._fit_width(config.options.layout.width))
  return w
end

function M.jump(opts)
  opts = opts or {}
  local sb = sidebar()
  if not sb then
    return
  end
  local sym = current_row_sym(sb)
  if not sym then
    return
  end
  local win = source_window(sb)
  sb.src_win = win
  local lc = api.nvim_buf_line_count(sb.src)
  local lnum = math.min(sym.lnum + 1, lc)
  pcall(api.nvim_win_set_cursor, win, { lnum, sym.col })
  api.nvim_win_call(win, function()
    vim.cmd("normal! zv")
  end)
  if opts.preview then
    api.nvim_set_current_win(sb.win)
  else
    api.nvim_set_current_win(win)
    if config.options.close_on_jump then
      M.close()
    end
  end
end

---------------------------------------------------------------- folding

local function fold(action)
  local sb = sidebar()
  if not sb then
    return
  end
  local bs = bstate(sb.src)
  local sym = current_row_sym(sb)
  if action == "open_all" then
    bs.collapsed = {}
  elseif action == "close_all" then
    local function walk(list)
      for _, s in ipairs(list) do
        if #s.children > 0 then
          bs.collapsed[s.id] = true
        end
        walk(s.children)
      end
    end
    walk(bs.symbols)
  elseif sym then
    local has_kids = #sym.children > 0
    if action == "toggle" and has_kids then
      bs.collapsed[sym.id] = not bs.collapsed[sym.id] or nil
    elseif action == "open" and has_kids then
      bs.collapsed[sym.id] = nil
    elseif action == "close" then
      if has_kids and not bs.collapsed[sym.id] then
        bs.collapsed[sym.id] = true
      elseif sym.parent then
        bs.collapsed[sym.parent.id] = true
        M.render()
        local r = sb.row_by_id[sym.parent.id]
        if r then
          api.nvim_win_set_cursor(sb.win, { r, 0 })
        end
        return
      end
    end
  end
  M.render()
  if action == "close_all" then
    local top = sym
    while top and top.parent do
      top = top.parent
    end
    local r = top and sb.row_by_id[top.id]
    if r then
      api.nvim_win_set_cursor(sb.win, { r, 0 })
    end
  end
end

M.toggle_fold = function() fold("toggle") end
M.open_fold = function() fold("open") end
M.close_fold = function() fold("close") end
M.open_all = function() fold("open_all") end
M.close_all = function() fold("close_all") end

---------------------------------------------------------------- filter

function M.set_filter(kind_list, bufnr)
  local sb = sidebar()
  bufnr = bufnr or (sb and sb.src) or api.nvim_get_current_buf()
  local bs = bstate(bufnr)
  if not kind_list or #kind_list == 0 then
    bs.kind_set = nil
  else
    bs.kind_set = {}
    for _, k in ipairs(kind_list) do
      if not vim.tbl_contains(kinds.list, k) then
        notify("unknown kind '" .. k .. "' (see :help qzss-kinds)", vim.log.levels.ERROR)
        bs.kind_set = nil
        return false
      end
      bs.kind_set[k] = true
    end
  end
  M.render()
  return true
end

---------------------------------------------------------------- help

function M.help()
  local km = config.options.keymaps
  local function keys(v)
    if not v then
      return "-"
    end
    return type(v) == "table" and table.concat(v, " ") or v
  end
  local lines = {
    " qzss keys",
    "",
    string.format(" %-12s jump to symbol", keys(km.jump)),
    string.format(" %-12s preview (keep focus)", keys(km.preview)),
    string.format(" %-12s toggle fold", keys(km.toggle_fold)),
    string.format(" %-12s open fold", keys(km.open_fold)),
    string.format(" %-12s close fold / parent", keys(km.close_fold)),
    string.format(" %-12s open all", keys(km.open_all)),
    string.format(" %-12s close all", keys(km.close_all)),
    string.format(" %-12s refresh", keys(km.refresh)),
    string.format(" %-12s close sidebar", keys(km.close)),
    "",
    " :QzssFilter Class Interface  (no args: clear)",
    " :help qzss   full documentation",
    " press q / <Esc> / ? to close",
  }
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l) + 1)
  end
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = 1,
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = math.min(width, vim.o.columns - 2),
    height = #lines,
    style = "minimal",
    border = "single",
  })
  for _, k in ipairs({ "q", "<Esc>", "?" }) do
    vim.keymap.set("n", k, function()
      pcall(api.nvim_win_close, win, true)
    end, { buffer = buf, nowait = true })
  end
end

---------------------------------------------------------------- open/close

local function map_keys(buf)
  local km = config.options.keymaps
  local actions = {
    jump = function() M.jump() end,
    preview = function() M.jump({ preview = true }) end,
    toggle_fold = M.toggle_fold,
    open_fold = M.open_fold,
    close_fold = M.close_fold,
    open_all = M.open_all,
    close_all = M.close_all,
    refresh = function() M.refresh() end,
    close = function() M.close() end,
    help = M.help,
  }
  for name, fn in pairs(actions) do
    local keys = km[name]
    if keys then
      for _, k in ipairs(type(keys) == "table" and keys or { keys }) do
        vim.keymap.set("n", k, fn, { buffer = buf, nowait = true, silent = true, desc = "qzss " .. name })
      end
    end
  end
end

function M.is_open()
  return sidebar() ~= nil
end

function M.open(opts)
  opts = opts or {}
  local src = api.nvim_get_current_buf()
  local src_win = api.nvim_get_current_win()
  local sb = sidebar()
  if sb then
    if is_source_buf(src) and src ~= sb.src then
      sb.src, sb.src_win = src, src_win
      M.refresh(src)
    end
    if opts.focus ~= false then
      api.nvim_set_current_win(sb.win)
    end
    return
  end
  if not is_source_buf(src) then
    notify("current buffer is not a file buffer", vim.log.levels.ERROR)
    return
  end
  local lay = config.options.layout
  vim.cmd((lay.position == "left" and "topleft" or "botright") .. " vertical " .. M._fit_width(lay.width) .. "new")
  local win = api.nvim_get_current_win()
  local buf = api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "qzss"
  pcall(api.nvim_buf_set_name, buf, "qzss://outline/" .. api.nvim_get_current_tabpage())
  local wo = vim.wo[win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.wrap = false
  wo.list = false
  wo.spell = false
  wo.cursorline = true
  wo.winfixwidth = true
  map_keys(buf)
  sidebars[api.nvim_get_current_tabpage()] = { win = win, buf = buf, src = src, src_win = src_win }
  M.refresh(src)
  if opts.focus == false then
    api.nvim_set_current_win(src_win)
  end
end

function M.close()
  local sb = sidebar()
  if sb then
    sidebars[api.nvim_get_current_tabpage()] = nil
    if #api.nvim_tabpage_list_wins(0) > 1 then
      api.nvim_win_close(sb.win, true)
    else
      vim.cmd("enew")
    end
  end
end

function M.toggle(opts)
  if sidebar() then
    M.close()
  else
    M.open(opts)
  end
end

function M.info()
  local sb = sidebar()
  local bufnr = sb and sb.src or api.nvim_get_current_buf()
  local bs = bstate(bufnr)
  local ft = vim.bo[bufnr].filetype
  local clients = vim.tbl_map(function(c)
    return c.name
  end, lspb.clients(bufnr))
  local lines = {
    "qzss info",
    "buffer: " .. api.nvim_buf_get_name(bufnr),
    "filetype: " .. ft .. "  tree-sitter language: " .. tostring(tsb.lang_for(ft)),
    "backends: " .. table.concat(config.options.backends, ", "),
    "source: " .. tostring(bs.source),
    "lsp clients: " .. (#clients > 0 and table.concat(clients, ", ") or "none"),
    "error: " .. tostring(bs.error),
    "lsp error: " .. tostring(bs.lsp_error),
  }
  api.nvim_echo({ { table.concat(lines, "\n") } }, true, {})
  return lines
end

---------------------------------------------------------------- setup & autocmds

local timers = {}

local function schedule_refresh(bufnr)
  local sb = sidebar()
  if not sb or sb.src ~= bufnr then
    return
  end
  if timers[bufnr] then
    timers[bufnr]:stop()
  else
    timers[bufnr] = vim.uv.new_timer()
  end
  timers[bufnr]:start(config.options.update_delay, 0, vim.schedule_wrap(function()
    if api.nvim_buf_is_valid(bufnr) then
      M.refresh(bufnr)
    end
  end))
end

-- true when closing window `closing` would leave only the sidebar (floating
-- windows such as notifications do not count) in the current tab.
local function only_sidebar_left(sb, closing)
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if w ~= sb.win and w ~= closing and api.nvim_win_get_config(w).relative == "" then
      return false
    end
  end
  return true
end

function M._close_if_alone()
  local sb = sidebar()
  if not sb or not only_sidebar_left(sb, nil) then
    return
  end
  pcall(api.nvim_set_current_win, sb.win)
  if #api.nvim_list_tabpages() > 1 then
    sidebars[api.nvim_get_current_tabpage()] = nil
    pcall(vim.cmd, "tabclose")
  else
    -- last window of the last tab: quit like :q would have
    local ok = pcall(vim.cmd, "quit")
    if not ok then
      -- unsaved buffers elsewhere: keep Neovim alive with an empty window
      sidebars[api.nvim_get_current_tabpage()] = nil
      vim.cmd("enew")
    end
  end
end

local function create_autocmds()
  api.nvim_clear_autocmds({ group = group })
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost" }, {
    group = group,
    callback = function(ev)
      schedule_refresh(ev.buf)
    end,
  })
  api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(ev)
      schedule_refresh(ev.buf)
    end,
  })
  api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(ev)
      local sb = sidebar()
      if not sb or ev.buf == sb.buf or not is_source_buf(ev.buf) then
        return
      end
      if api.nvim_get_current_win() == sb.win then
        -- A file was opened inside the sidebar window (:edit, :b, ...): the
        -- outline buffer is gone. Show the file in the source window and
        -- rebuild the sidebar instead of rendering into a wiped buffer.
        local tab = api.nvim_get_current_tabpage()
        sidebars[tab] = nil
        vim.schedule(function()
          if not api.nvim_buf_is_valid(ev.buf) then
            return
          end
          local w = sb.src_win
          if w and w ~= sb.win and api.nvim_win_is_valid(w) and api.nvim_win_get_tabpage(w) == tab then
            api.nvim_win_set_buf(w, ev.buf)
            if api.nvim_win_is_valid(sb.win) then
              pcall(api.nvim_win_close, sb.win, true)
            end
            api.nvim_set_current_win(w)
          elseif api.nvim_win_is_valid(sb.win) then
            -- no other window: turn the sidebar window into a normal one
            api.nvim_win_call(sb.win, function()
              vim.cmd("setlocal number< relativenumber< signcolumn< foldcolumn< wrap< list< spell< cursorline< winfixwidth< winbar<")
            end)
          end
          M.open({ focus = false })
        end)
        return
      end
      sb.src_win = api.nvim_get_current_win()
      if ev.buf ~= sb.src then
        sb.src = ev.buf
        M.refresh(ev.buf)
      end
    end,
  })
  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    callback = function(ev)
      local sb = sidebar()
      if sb and ev.buf == sb.src and config.options.follow_cursor then
        sb.src_win = api.nvim_get_current_win()
        M.follow()
      end
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      for tab, sb in pairs(sidebars) do
        if tostring(sb.win) == ev.match then
          sidebars[tab] = nil
        end
      end
      -- a source window closed by other means (:close, :q! on a modified
      -- buffer, ...): never leave the outline as the only window
      vim.schedule(M._close_if_alone)
    end,
  })
  api.nvim_create_autocmd("QuitPre", {
    group = group,
    callback = function()
      -- `:q` in the last source window: close the outline first so the
      -- quit closes the tab / exits Neovim instead of leaving the sidebar
      local sb = sidebar()
      local cur = api.nvim_get_current_win()
      if not sb or cur == sb.win or only_sidebar_left(sb, cur) == false then
        return
      end
      local buf = api.nvim_get_current_buf()
      if vim.bo[buf].modified and #vim.fn.win_findbuf(buf) == 1 and not vim.o.hidden then
        return -- :q will fail with E37; keep the layout (WinClosed handles :q!)
      end
      sidebars[api.nvim_get_current_tabpage()] = nil
      pcall(api.nvim_win_close, sb.win, true)
    end,
  })
  api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      if sidebar() then
        M.render()
      end
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(ev)
      bufs[ev.buf] = nil
      if timers[ev.buf] then
        timers[ev.buf]:close()
        timers[ev.buf] = nil
      end
    end,
  })
  api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      kinds.setup_highlights(config.options.highlights)
    end,
  })
end

function M.setup(opts)
  config.setup(opts)
  kinds.setup_highlights(config.options.highlights)
  -- apply per-filetype default filters lazily via FileType
  create_autocmds()
  api.nvim_create_autocmd("FileType", {
    group = group,
    callback = function(ev)
      local fk = config.options.filter_kinds[ev.match]
      if fk then
        local bs = bstate(ev.buf)
        bs.kind_set = {}
        for _, k in ipairs(fk) do
          bs.kind_set[k] = true
        end
      end
    end,
  })
  if config.options.toggle_key then
    vim.keymap.set("n", config.options.toggle_key, function()
      M.toggle()
    end, { desc = "qzss: toggle outline" })
  end
  M._did_setup = true
end

M._state = { bufs = bufs, sidebars = sidebars }

return M
