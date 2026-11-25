-- Outline windows (sidebar and float). Private module.
--
-- One view per tabpage. A view is a window + outline buffer showing the
-- shared model of its source buffer; the mode only decides how the window is
-- placed. Switching modes moves the same outline buffer into a new window,
-- so the cursor row, folds and filter (stored in the model) are kept.
local config = require("qzss.config")
local render = require("qzss.render")
local model = require("qzss.model")
local events = require("qzss.events")

local M = {}
local api = vim.api
local ns = api.nvim_create_namespace("qzss")

---@type table<integer, table> tabpage -> view
local views = {}
M.views = views

function M.get(tab)
  tab = tab or api.nvim_get_current_tabpage()
  local v = views[tab]
  if v and v.win and api.nvim_win_is_valid(v.win) then
    return v
  end
  return nil
end

function M.is_source_buf(bufnr)
  return api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buftype == "" and vim.bo[bufnr].filetype ~= "qzss"
end

local function is_float(win)
  return api.nvim_win_get_config(win).relative ~= ""
end

local function float_opts()
  return config.options.layout.float
end

--- Clamp a sidebar width so the source window stays usable on narrow
--- terminals: the sidebar never takes more than max(columns - 30, columns / 2).
function M.fit_width(w)
  local cols = vim.o.columns
  local cap = math.max(cols - 30, math.floor(cols / 2))
  return math.max(1, math.min(w, cap))
end

---------------------------------------------------------------- float geometry

local function cells(v, total)
  if v < 1 then
    return math.floor(total * v)
  end
  return math.floor(v)
end

local function has_border(b)
  return b ~= nil and b ~= "none" and b ~= "" and not (type(b) == "table" and #b == 0)
end

--- Pure float geometry. `f` = layout.float options, `ref` = { width, height }
--- of the reference area. Returns content width/height and the top-left
--- row/col (relative to the reference) of the window including its border.
--- Sizes are clamped to [min, max] and then to what fits, so a terminal that
--- is smaller than min_width/min_height still gets a float that fits.
function M.float_geometry(f, ref)
  local b = has_border(f.border) and 2 or 0
  local avail_w = math.max(1, ref.width - b)
  local avail_h = math.max(1, ref.height - b)
  local function size(v, total, lo, hi, avail)
    local n = cells(v, total)
    if lo then
      n = math.max(n, cells(lo, total))
    end
    if hi then
      n = math.min(n, cells(hi, total))
    end
    return math.max(1, math.min(n, avail))
  end
  local w = size(f.width, ref.width, f.min_width, f.max_width, avail_w)
  local h = size(f.height, ref.height, f.min_height, f.max_height, avail_h)
  local free_w = math.max(0, ref.width - w - b)
  local free_h = math.max(0, ref.height - h - b)
  local p = f.position or "center"
  local col = math.floor(free_w / 2)
  local row = math.floor(free_h / 2)
  if p:find("left") then
    col = 0
  elseif p:find("right") then
    col = free_w
  end
  if p:find("top") then
    row = 0
  elseif p:find("bottom") then
    row = free_h
  end
  if f.row then
    row = math.min(cells(f.row, ref.height), free_h)
  end
  if f.col then
    col = math.min(cells(f.col, ref.width), free_w)
  end
  return { width = w, height = h, row = row, col = col }
end

-- reference area of a float: the editor grid minus tabline/statusline/cmdline,
-- or the source window
local function float_ref(v)
  local f = float_opts()
  if f.relative == "win" and v.src_win and api.nvim_win_is_valid(v.src_win) and not is_float(v.src_win) then
    return { width = api.nvim_win_get_width(v.src_win), height = api.nvim_win_get_height(v.src_win) },
      { relative = "win", win = v.src_win }, 0
  end
  local tabline = (vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #api.nvim_list_tabpages() > 1)) and 1 or 0
  local status = (vim.o.laststatus >= 2) and 1 or 0
  local h = vim.o.lines - vim.o.cmdheight - tabline - status
  return { width = vim.o.columns, height = math.max(1, h) }, { relative = "editor" }, tabline
end

local function truncate(s, width)
  if width < 1 then
    return ""
  end
  if vim.fn.strdisplaywidth(s) <= width then
    return s
  end
  local out = ""
  for _, ch in ipairs(vim.fn.split(s, "\\zs")) do
    if vim.fn.strdisplaywidth(out .. ch .. "…") > width then
      break
    end
    out = out .. ch
  end
  return out .. "…"
end

local function source_name(v)
  local name = v.src and api.nvim_buf_is_valid(v.src) and vim.fn.fnamemodify(api.nvim_buf_get_name(v.src), ":t") or ""
  return name == "" and "[No Name]" or name
end

local function status_parts(m)
  local parts = { m and m.source or "no source" }
  if m and m.kind_set then
    local ks = vim.tbl_keys(m.kind_set)
    table.sort(ks)
    table.insert(parts, "filter:" .. table.concat(ks, ","))
  end
  if m and m.lsp_error and m.source == "treesitter" then
    table.insert(parts, "lsp: error")
  end
  table.insert(parts, "? help")
  return parts
end

local function float_win_config(v)
  local f = float_opts()
  local ref, rel, row_off = float_ref(v)
  local g = M.float_geometry(f, ref)
  local cfg = vim.tbl_extend("force", rel, {
    row = g.row + row_off,
    col = g.col,
    width = g.width,
    height = g.height,
    zindex = f.zindex,
  })
  if has_border(f.border) then
    cfg.border = f.border
    if f.title ~= false then
      local title = type(f.title) == "string" and f.title or (" qzss · " .. source_name(v) .. " ")
      cfg.title = truncate(title, g.width)
      cfg.title_pos = f.title_pos or "center"
      local m = v.src and model.peek(v.src)
      cfg.footer = truncate(" " .. table.concat(status_parts(m), " · ") .. " ", g.width)
      cfg.footer_pos = "right"
    end
  else
    cfg.border = "none"
  end
  return cfg
end

--- Re-place a float after VimResized / WinResized / a title change.
function M.reposition(v)
  if v.mode ~= "float" or not api.nvim_win_is_valid(v.win) then
    return
  end
  local cfg = float_win_config(v)
  if cfg.relative == "win" and not api.nvim_win_is_valid(cfg.win) then
    return
  end
  pcall(api.nvim_win_set_config, v.win, cfg)
end

---------------------------------------------------------------- rendering

local function current_row_sym(v)
  if not (v and v.rows and api.nvim_win_is_valid(v.win)) then
    return nil
  end
  return v.rows[api.nvim_win_get_cursor(v.win)[1]]
end
M.current_row_sym = current_row_sym

local function row_of(v, sym)
  while sym do
    local r = v.row_by_id and v.row_by_id[sym.id]
    if r then
      return r
    end
    sym = sym.parent
  end
  return nil
end

local function set_title(v, m)
  if v.mode == "float" then
    vim.wo[v.win].winbar = has_border(float_opts().border) and float_opts().title ~= false and ""
      or (" qzss · " .. source_name(v):gsub("%%", "%%%%"))
    M.reposition(v)
    return
  end
  local esc = function(s)
    return (s:gsub("%%", "%%%%"))
  end
  -- `%<` makes a narrow sidebar truncate the tail (source, filter, help hint)
  -- instead of the "qzss · file" head.
  vim.wo[v.win].winbar = " qzss · " .. esc(source_name(v)) .. "%< · " .. esc(table.concat(status_parts(m), " · "))
end

function M.render(v)
  v = v or M.get()
  if not v or not api.nvim_win_is_valid(v.win) or not api.nvim_buf_is_valid(v.buf) then
    return
  end
  local lines, hls, rows, msg = {}, {}, {}, false
  local m = v.src and api.nvim_buf_is_valid(v.src) and model.get(v.src) or nil
  local keep = current_row_sym(v)
  if m then
    lines, hls, rows = render.build(m.symbols, {
      collapsed = m.collapsed,
      bufnr = v.src,
      filetype = vim.bo[v.src].filetype,
      kind_set = m.kind_set,
    })
  end
  if #lines == 0 then
    msg = true
    lines = { not m and "qzss: no source buffer" or (m.error and ("qzss: " .. m.error)) or "qzss: no symbols" }
  end
  v.rows = rows
  v.row_by_id = {}
  for r, s in pairs(rows) do
    v.row_by_id[s.id] = r
  end
  vim.bo[v.buf].modifiable = true
  api.nvim_buf_set_lines(v.buf, 0, -1, false, lines)
  vim.bo[v.buf].modifiable = false
  api.nvim_buf_clear_namespace(v.buf, ns, 0, -1)
  if msg then
    api.nvim_buf_set_extmark(v.buf, ns, 0, 0, { end_col = #lines[1], hl_group = "QzssMessage" })
  end
  for _, h in ipairs(hls) do
    pcall(api.nvim_buf_set_extmark, v.buf, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
  set_title(v, m)
  -- a message row (no symbols) wraps instead of being cut at the float edge
  vim.wo[v.win].wrap = msg
  if v.mode == "sidebar" then
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
    local normal = 0
    for _, win in ipairs(api.nvim_tabpage_list_wins(api.nvim_win_get_tabpage(v.win))) do
      if not is_float(win) then
        normal = normal + 1
      end
    end
    if normal > 1 then
      pcall(api.nvim_win_set_width, v.win, M.fit_width(w))
    end
  end
  -- keep the selected node (or its nearest visible ancestor) selected
  local want = keep or (v.pending_cursor_id and { id = v.pending_cursor_id })
  v.pending_cursor_id = nil
  if want then
    local r = v.row_by_id[want.id]
    local p = want.parent
    while not r and p do
      r = v.row_by_id[p.id]
      p = p.parent
    end
    if r then
      pcall(api.nvim_win_set_cursor, v.win, { r, 0 })
    end
  end
end

--- Render every view (in any tab) that shows `bufnr`.
function M.render_buf(bufnr)
  for tab, v in pairs(views) do
    if v.src == bufnr and M.get(tab) then
      M.render(v)
      if config.options.follow_cursor then
        M.follow(v)
      end
    end
  end
end

---------------------------------------------------------------- follow & jump

--- `force` also moves the cursor when the outline has focus (initial open).
function M.follow(v, force)
  v = v or M.get()
  if not v or not v.src then
    return
  end
  local win = v.src_win
  if not (win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == v.src) then
    return
  end
  local line = api.nvim_win_get_cursor(win)[1] - 1
  local sym = model.symbol_at(v.src, line)
  local r = sym and row_of(v, sym)
  if r and (force or api.nvim_get_current_win() ~= v.win) then
    pcall(api.nvim_win_set_cursor, v.win, { r, 0 })
  end
end

local function normal_wins(tab, except)
  local out = {}
  for _, w in ipairs(api.nvim_tabpage_list_wins(tab)) do
    if w ~= except and not is_float(w) then
      table.insert(out, w)
    end
  end
  return out
end

--- Window that shows (or will show) the view's source buffer.
local function source_window(v)
  local tab = api.nvim_win_get_tabpage(v.win)
  local w = v.src_win
  if w and api.nvim_win_is_valid(w) and api.nvim_win_get_tabpage(w) == tab and w ~= v.win
    and api.nvim_win_get_buf(w) == v.src then
    return w
  end
  for _, x in ipairs(normal_wins(tab, v.win)) do
    if api.nvim_win_get_buf(x) == v.src then
      return x
    end
  end
  if v.mode == "float" then
    -- reuse the window the float was opened from, else any normal window
    local target = (w and api.nvim_win_is_valid(w) and api.nvim_win_get_tabpage(w) == tab and not is_float(w)) and w
      or normal_wins(tab, v.win)[1]
    api.nvim_win_set_buf(target, v.src)
    return target
  end
  -- sidebar: source no longer visible, open it next to the sidebar
  api.nvim_set_current_win(v.win)
  vim.cmd(config.options.layout.position == "left" and "rightbelow vsplit" or "leftabove vsplit")
  local nw = api.nvim_get_current_win()
  api.nvim_win_set_buf(nw, v.src)
  api.nvim_win_set_width(v.win, M.fit_width(config.options.layout.width))
  return nw
end
M.source_window = source_window

--- Move `win` to (row 1-based, col 0-based byte), clamped to the buffer.
function M.set_cursor(win, row, col)
  local buf = api.nvim_win_get_buf(win)
  local lc = api.nvim_buf_line_count(buf)
  row = math.max(1, math.min(row, lc))
  local len = #(api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or "")
  col = math.max(0, math.min(col, math.max(0, len - 1)))
  pcall(api.nvim_win_set_cursor, win, { row, col })
  api.nvim_win_call(win, function()
    vim.cmd("normal! zv")
  end)
end

function M.close_on_jump(v)
  if v.mode == "float" then
    local f = float_opts().close_on_jump
    if f ~= nil and f ~= "global" then
      return f
    end
  end
  return config.options.close_on_jump
end

--- Jump to the symbol under the outline cursor. Returns the source window.
function M.jump_row(v, preview)
  local sym = current_row_sym(v)
  if not sym or not v.src or not api.nvim_buf_is_valid(v.src) then
    return nil
  end
  local win = source_window(v)
  v.src_win = win
  M.set_cursor(win, sym.lnum + 1, sym.col)
  if preview then
    api.nvim_set_current_win(v.win)
  else
    api.nvim_set_current_win(win)
  end
  return win, sym
end

---------------------------------------------------------------- open / close

local function set_win_opts(v)
  local wo = vim.wo[v.win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.wrap = false
  wo.list = false
  wo.spell = false
  wo.cursorline = true
  wo.winfixwidth = v.mode == "sidebar"
  wo.winblend = v.mode == "float" and float_opts().winblend or 0
  wo.winbar = ""
  wo.fillchars = "eob: "
end

local function open_window(v, enter)
  if v.mode == "float" then
    local cfg = float_win_config(v)
    if cfg.relative == "win" and not api.nvim_win_is_valid(cfg.win) then
      cfg = vim.tbl_extend("force", cfg, { relative = "editor", win = nil })
    end
    v.win = api.nvim_open_win(v.buf, enter, cfg)
  else
    local lay = config.options.layout
    -- :vsplit-style top-level split, run from a normal window (a float can
    -- be the current window when switching float -> sidebar)
    local anchor = api.nvim_get_current_win()
    if is_float(anchor) then
      anchor = (v.src_win and api.nvim_win_is_valid(v.src_win) and not is_float(v.src_win)) and v.src_win
        or normal_wins(api.nvim_get_current_tabpage())[1]
    end
    api.nvim_win_call(anchor, function()
      vim.cmd((lay.position == "left" and "topleft" or "botright") .. " vertical " .. M.fit_width(lay.width) .. "split")
      v.win = api.nvim_get_current_win()
    end)
    api.nvim_win_set_buf(v.win, v.buf)
    if enter then
      api.nvim_set_current_win(v.win)
    end
  end
  set_win_opts(v)
end

--- Create the view for the current tab. `map` installs buffer keymaps.
function M.create(mode, src, src_win, focus, map)
  local tab = api.nvim_get_current_tabpage()
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "qzss"
  pcall(api.nvim_buf_set_name, buf, "qzss://outline/" .. tab)
  local v = { mode = mode, buf = buf, src = src, src_win = src_win, tab = tab }
  open_window(v, focus ~= false)
  map(buf, mode)
  views[tab] = v
  if focus == false and api.nvim_win_is_valid(src_win) then
    api.nvim_set_current_win(src_win)
  end
  return v
end

--- Move an open view into the other mode, keeping buffer, cursor and focus.
function M.switch(v, mode, map)
  if v.mode == mode then
    return false
  end
  local old = v.win
  local focused = api.nvim_get_current_win() == old
  local cursor = api.nvim_win_get_cursor(old)
  local from = v.mode
  v.mode = mode
  v.switching = true
  local ok, err = pcall(open_window, v, focused)
  if not ok then
    v.mode, v.win, v.switching = from, old, nil
    error(err, 0)
  end
  pcall(api.nvim_win_close, old, true)
  v.switching = nil
  map(v.buf, mode)
  pcall(api.nvim_win_set_cursor, v.win, cursor)
  if not focused and v.src_win and api.nvim_win_is_valid(v.src_win) then
    api.nvim_set_current_win(v.src_win)
  end
  M.render(v)
  events.emit("mode", { tabpage = v.tab, from = from, to = mode, winid = v.win, source_bufnr = v.src })
  return true
end

--- Close the view of `tab`. Focus returns to the source window when the
--- outline had focus.
function M.close(tab, reason)
  tab = tab or api.nvim_get_current_tabpage()
  local v = views[tab]
  if not v then
    return false
  end
  views[tab] = nil
  local win = v.win
  if win and api.nvim_win_is_valid(win) then
    local was_cur = api.nvim_get_current_win() == win
    if v.mode == "float" or #normal_wins(tab, win) > 0 then
      pcall(api.nvim_win_close, win, true)
    else
      -- the sidebar is the only window of the tab: keep the window, drop the outline
      api.nvim_win_call(win, function()
        vim.cmd("enew")
        vim.cmd("setlocal number< relativenumber< signcolumn< foldcolumn< wrap< list< spell< cursorline< winfixwidth< winbar<")
      end)
    end
    if was_cur and v.src_win and api.nvim_win_is_valid(v.src_win) and api.nvim_win_get_tabpage(v.src_win) == tab then
      api.nvim_set_current_win(v.src_win)
    end
  end
  events.emit("close", { tabpage = tab, mode = v.mode, source_bufnr = v.src, reason = reason or "close" })
  return true
end

--- Forget views whose window or tab disappeared (WinClosed, TabClosed).
function M.forget(tab, reason)
  local v = views[tab]
  if v and not v.switching then
    views[tab] = nil
    events.emit("close", { tabpage = tab, mode = v.mode, source_bufnr = v.src, reason = reason })
  end
end

function M.retarget(v, src, src_win)
  v.src = src
  if src_win then
    v.src_win = src_win
  end
end

---------------------------------------------------------------- help

function M.help()
  local km = config.options.keymaps
  local function keys(x)
    if not x then
      return "-"
    end
    return type(x) == "table" and table.concat(x, " ") or x
  end
  local v = M.get()
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
    string.format(" %-12s close outline", keys(v and v.mode == "float" and km.float_close and { keys(km.close), keys(km.float_close) } or km.close)),
    "",
    " :QzssFloat / :QzssSidebar  switch layout",
    " :QzssFilter Class Interface  (no args: clear)",
    " :help qzss   full documentation",
    " press q / <Esc> / ? to close",
  }
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l) + 1)
  end
  width = math.max(1, math.min(width, vim.o.columns - 2))
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = 1,
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = math.max(1, math.min(#lines, vim.o.lines - 4)),
    style = "minimal",
    border = "single",
    zindex = 100,
  })
  for _, k in ipairs({ "q", "<Esc>", "?" }) do
    vim.keymap.set("n", k, function()
      pcall(api.nvim_win_close, win, true)
    end, { buffer = buf, nowait = true })
  end
  return win
end

-- model updates re-render every view showing the buffer
model.on_update = function(m)
  M.render_buf(m.bufnr)
end

return M
