-- Public API contract + float layout + lifecycle tests (headless).
-- Run: nvim --clean --headless -l tests/api_spec.lua
-- Async LSP timing (stale responses, coalescing, cancel, wipe while pending)
-- is in tests/api_async_spec.lua (deterministic in-process server) and, with
-- the real rust-analyzer / typescript-language-server, in tests/lsp_e2e.lua.
local root = vim.fn.getcwd()
package.path = root .. "/?.lua;" .. package.path
dofile(root .. "/tests/minimal_init.lua")
local T = require("tests.helpers")
local qzss = require("qzss")
local qapi = require("qzss.api")
local api = vim.api

-- Fixed editor size for geometry assertions. Set once: repeatedly resizing
-- the headless grid made Neovim 0.12.6 crash later in nvim__redraw.
vim.o.columns, vim.o.lines = 120, 40

local RS = root .. "/tests/fixtures/rust/src/lib.rs"
local TS = root .. "/tests/fixtures/ts/sample.ts"

local notes = {}
local real_notify = vim.notify
vim.notify = function(msg, level)
  table.insert(notes, { msg = msg, level = level })
end

local function reset(opts)
  pcall(qzss.close)
  for _, t in ipairs(api.nvim_list_tabpages()) do
    if t ~= api.nvim_list_tabpages()[1] then
      pcall(vim.cmd, "tabonly!")
      break
    end
  end
  vim.cmd("silent! only!")
  vim.cmd("silent! %bwipeout!")
  -- (the editor size is set once at the top: see below)
  qzss.setup(opts or {})
  notes = {}
end

local function edit(path)
  vim.cmd("edit! " .. path)
  return api.nvim_get_current_buf(), api.nvim_get_current_win()
end

local function errmsg(fn, ...)
  local ok, err = pcall(fn, ...)
  return not ok and tostring(err) or nil
end

local function win_lines(win)
  return api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false)
end

local function goto_row(win, text)
  for i, l in ipairs(win_lines(win)) do
    if l:find(text, 1, true) then
      api.nvim_win_set_cursor(win, { i, 0 })
      return i
    end
  end
end

---------------------------------------------------------------- facade & compatibility
do
  T.ok(require("qzss.api") == qapi, "qzss.api module loads")
  for _, name in ipairs({ "setup", "open", "close", "toggle", "is_open", "get_view", "refresh", "get_snapshot",
    "request_symbols", "find_symbol", "current_symbol", "jump_to", "set_filter", "get_filter", "get_folded",
    "set_folded", "open_all", "close_all", "toggle_fold", "open_fold", "close_fold", "jump", "help",
    "subscribe", "unsubscribe", "info" }) do
    T.ok(type(qapi[name]) == "function" and qzss[name] == qapi[name], "qzss." .. name .. " is the qzss.api function")
  end
  for _, name in ipairs({ "get_symbols", "outline_lines", "compute", "symbol_at", "render", "follow", "_fit_width" }) do
    T.ok(type(qzss[name]) == "function", "legacy qzss." .. name .. " kept")
  end
  T.eq(qzss.api_version, 1, "api_version = 1")
  T.ok(type(qzss._state.sidebars) == "table" and type(qzss._state.bufs) == "table", "legacy _state tables kept")
  local cmds = api.nvim_get_commands({})
  for _, c in ipairs({ "Qzss", "QzssOpen", "QzssFloat", "QzssSidebar", "QzssClose", "QzssRefresh", "QzssInfo", "QzssFilter" }) do
    T.ok(cmds[c] ~= nil, ":" .. c .. " exists")
  end
  T.eq(cmds.QzssFloat.bang, true, ":QzssFloat accepts !")
end

---------------------------------------------------------------- config validation
do
  reset()
  local function bad(opts, needle, label)
    local e = errmsg(qzss.setup, opts)
    T.ok(e and e:find(needle, 1, true), "setup rejects " .. label, e)
  end
  bad({ layout = { mode = "popup" } }, 'layout.mode: expected "sidebar" or "float"', "unknown mode")
  bad({ layout = { float = { relative = "cursor" } } }, "layout.float.relative", "relative=cursor")
  bad({ layout = { float = { width = -3 } } }, "layout.float.width", "negative width")
  bad({ layout = { float = { height = 0 } } }, "layout.float.height", "zero height")
  bad({ layout = { float = { position = "middle" } } }, "layout.float.position", "unknown position")
  bad({ layout = { float = { winblend = 200 } } }, "layout.float.winblend", "winblend > 100")
  bad({ layout = { float = { title = 3 } } }, "layout.float.title", "numeric title")
  bad("float", "setup() expects a table", "non-table opts")
  T.eq(require("qzss.config").options.layout.mode, "sidebar", "failed setup keeps the previous options")
  qzss.setup({ layout = { mode = "float", float = { width = 70, height = 0.5 } } })
  T.eq(require("qzss.config").options.layout.float.width, 70, "integer float width accepted")
  T.eq(require("qzss.config").options.layout.float.border, "rounded", "float defaults merged")
end

---------------------------------------------------------------- float geometry (pure)
do
  local g = qzss._float_geometry
  local d = require("qzss.config").defaults.layout.float
  local r = g(d, { width = 120, height = 38 })
  T.same(r, { width = 60, height = 30, row = 3, col = 29 }, "defaults: 0.5 x 0.8 centered (border counted)")
  r = g(vim.tbl_extend("force", d, { width = 40, height = 10 }), { width = 120, height = 38 })
  T.eq(r.width .. "x" .. r.height, "40x10", "integer sizes are cells")
  r = g(vim.tbl_extend("force", d, { position = "top-right" }), { width = 120, height = 38 })
  T.eq(r.row .. "," .. r.col, "0,58", "top-right: row 0, right aligned")
  r = g(vim.tbl_extend("force", d, { position = "bottom-left" }), { width = 120, height = 38 })
  T.eq(r.row .. "," .. r.col, "6,0", "bottom-left")
  r = g(vim.tbl_extend("force", d, { row = 2, col = 0.25 }), { width = 120, height = 38 })
  T.eq(r.row .. "," .. r.col, "2,30", "explicit row (cells) / col (fraction) override position")
  r = g(vim.tbl_extend("force", d, { row = 500, col = 500 }), { width = 120, height = 38 })
  T.eq(r.row .. "," .. r.col, "6,58", "explicit row/col clamped so the float stays on screen")
  r = g(vim.tbl_extend("force", d, { max_width = 30, max_height = 0.25 }), { width = 120, height = 40 })
  T.eq(r.width .. "x" .. r.height, "30x10", "max_width cells / max_height fraction")
  r = g(d, { width = 30, height = 8 })
  T.same(r, { width = 20, height = 6, row = 0, col = 4 }, "narrow 30x8: min_width (20) wins over 0.5 (15); height 0.8 -> 6 fits")
  r = g(d, { width = 30, height = 6 })
  T.same(r, { width = 20, height = 4, row = 0, col = 4 }, "30x6: min_height 5 clamped to the 4 rows inside the border")
  r = g(d, { width = 12, height = 4 })
  T.same(r, { width = 10, height = 2, row = 0, col = 0 }, "tiny 12x4: clamped to what fits inside the border")
  r = g(vim.tbl_extend("force", d, { border = "none" }), { width = 3, height = 1 })
  T.same(r, { width = 3, height = 1, row = 0, col = 0 }, "border none uses the whole area, never < 1")
end

---------------------------------------------------------------- float open / focus / keys
do
  reset()
  local src, src_win = edit(RS)
  local events = {}
  local sub = qzss.subscribe("*", function(ev)
    if ev.event ~= "symbols" then
      table.insert(events, ev.event .. ":" .. tostring(ev.mode or ev.to))
    end
  end)
  T.eq(qzss.get_view(), nil, "get_view() is nil when closed")
  T.eq(qzss.open({ mode = "float" }), true, "open({mode='float'}) returns true")
  local v = qzss.get_view()
  T.ok(v and v.mode == "float", "get_view().mode == float")
  local cfg = api.nvim_win_get_config(v.winid)
  T.eq(cfg.relative, "editor", "float relative=editor by default")
  T.eq(cfg.width .. "x" .. cfg.height, "60x30", "float 0.5 x 0.8 of a 120x40 editor (minus cmdline/statusline)")
  T.eq(vim.wo[v.winid].winblend, 0, "winblend 0")
  local title = cfg.title and cfg.title[1] and cfg.title[1][1]
  T.eq(title, " qzss · lib.rs ", "float title shows the file")
  T.ok(v.focused and api.nvim_get_current_win() == v.winid, "float focused by default")
  T.eq(v.source_bufnr, src, "source_bufnr")
  T.eq(v.source_winid, src_win, "source_winid")
  T.ok(qzss.is_open() and qzss.is_open({ mode = "float" }) and not qzss.is_open({ mode = "sidebar" }), "is_open with mode")
  T.ok(vim.fn.maparg("<Esc>", "n", false, true).buffer == 1, "<Esc> mapped in the float buffer")
  -- preview keeps focus, moves source cursor
  goto_row(v.winid, "helper<U")
  api.nvim_feedkeys("p", "x", false)
  T.eq(api.nvim_get_current_win(), v.winid, "float preview keeps outline focus")
  T.same(api.nvim_win_get_cursor(src_win), { 33, 11 }, "float preview moved source cursor to helper")
  -- <CR> with float default close_on_jump = true
  goto_row(v.winid, "impl Default for MyStruct")
  api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  T.eq(qzss.is_open(), false, "<CR> in float closes it (layout.float.close_on_jump default true)")
  T.eq(api.nvim_get_current_win(), src_win, "focus back in source after float jump")
  T.eq(api.nvim_win_get_cursor(src_win)[1], 19, "float jump landed on impl Default")
  -- Esc closes and returns focus
  qzss.open({ mode = "float" })
  api.nvim_feedkeys(vim.keycode("<Esc>"), "x", false)
  T.eq(qzss.is_open(), false, "<Esc> closes the float")
  T.eq(api.nvim_get_current_win(), src_win, "focus returns to the source window after <Esc>")
  -- non-focus open
  vim.cmd("QzssFloat!")
  T.eq(api.nvim_get_current_win(), src_win, ":QzssFloat! keeps focus in source")
  T.eq(qzss.get_view().focused, false, "get_view().focused false")
  -- follow cursor in float
  api.nvim_win_set_cursor(src_win, { 50, 4 })
  vim.cmd("doautocmd CursorMoved")
  local fl = win_lines(qzss.get_view().winid)
  T.ok(fl[api.nvim_win_get_cursor(qzss.get_view().winid)[1]]:find("map<U, F>", 1, true), "float follows the source cursor")
  qzss.close()
  T.same(events, { "open:float", "close:float", "open:float", "close:float", "open:float", "close:float" }, "open/close events", vim.inspect(events))
  qzss.unsubscribe(sub)
  -- close_on_jump overrides
  qzss.setup({ layout = { float = { close_on_jump = false } } })
  qzss.open({ mode = "float" })
  goto_row(qzss.get_view().winid, "impl Default for MyStruct")
  qzss.jump()
  T.ok(qzss.is_open() and api.nvim_get_current_win() == src_win, "float.close_on_jump=false keeps the float, focuses source")
  qzss.close()
  qzss.setup({ close_on_jump = true, layout = { float = { close_on_jump = nil } } })
  qzss.open({ mode = "float" })
  goto_row(qzss.get_view().winid, "impl Default for MyStruct")
  qzss.jump()
  T.eq(qzss.is_open(), false, "float inherits explicit global close_on_jump=true")
  qzss.setup({ close_on_jump = false })
  qzss.open({ mode = "sidebar" })
  goto_row(qzss.get_view().winid, "impl Default for MyStruct")
  qzss.jump()
  T.ok(qzss.is_open({ mode = "sidebar" }), "sidebar keeps close_on_jump=false default")
  qzss.close()
end

---------------------------------------------------------------- :Qzss / :QzssOpen / mode switch keeps state
do
  reset({ layout = { mode = "float" } })
  local src = edit(RS)
  vim.cmd("Qzss")
  T.ok(qzss.is_open({ mode = "float" }), ":Qzss opens layout.mode = float")
  vim.cmd("Qzss")
  T.eq(qzss.is_open(), false, ":Qzss toggles the float closed")
  vim.cmd("QzssOpen")
  T.ok(qzss.is_open({ mode = "float" }), ":QzssOpen uses layout.mode")
  local v = qzss.get_view()
  goto_row(v.winid, "impl<T> Shape<T> for MyStruct<T>")
  qzss.toggle_fold()
  qzss.set_filter({ "TraitImpl", "Impl", "Method" })
  local sel = qzss.get_view().cursor_symbol_id
  local modes = {}
  local sub = qzss.subscribe("mode", function(ev)
    table.insert(modes, ev.from .. ">" .. ev.to)
  end)
  vim.cmd("QzssSidebar")
  local s = qzss.get_view()
  T.eq(s.mode, "sidebar", ":QzssSidebar switches an open float to sidebar")
  T.ok(api.nvim_win_get_config(s.winid).relative == "", "sidebar is a split window")
  T.eq(s.bufnr, v.bufnr, "switch keeps the outline buffer")
  T.eq(s.cursor_symbol_id, sel, "switch keeps the selected symbol")
  T.same(s.filter, { "Impl", "Method", "TraitImpl" }, "switch keeps the filter")
  T.ok(vim.tbl_contains(s.folded, "/TraitImpl:impl<T> Shape<T> for MyStruct<T>"), "switch keeps folds")
  T.ok(s.focused, "focus stays in the outline across the switch")
  T.eq(vim.fn.maparg("<Esc>", "n", false, true).buffer, nil, "<Esc> unmapped in sidebar mode")
  T.eq(#api.nvim_tabpage_list_wins(0), 2, "old float window closed after switch")
  vim.cmd("QzssOpen")
  T.ok(qzss.is_open({ mode = "sidebar" }), ":QzssOpen on an open outline keeps its current mode")
  qzss.open({ mode = "float", focus = false })
  T.ok(qzss.is_open({ mode = "float" }) and api.nvim_get_current_win() ~= qzss.get_view().winid, "switch with focus=false leaves focus in the source")
  T.same(modes, { "float>sidebar", "sidebar>float" }, "mode events")
  qzss.unsubscribe(sub)
  T.eq(qzss._state.bufs[src].kind_set.Method, true, "fold/filter live in the shared per-buffer model")
  qzss.set_filter(nil)
  qzss.close()
  T.eq(errmsg(qzss.open, { mode = "popup" }):match("qzss%.open: mode must be"), "qzss.open: mode must be", "open() rejects unknown mode")
  T.ok(errmsg(qzss.open, "float") ~= nil, "open() rejects non-table opts")
end

---------------------------------------------------------------- resize / narrow terminal / relative=win
do
  reset({ layout = { mode = "float" } })
  edit(RS)
  qzss.open()
  local w = qzss.get_view().winid
  vim.o.columns, vim.o.lines = 30, 10
  vim.cmd("doautocmd VimResized")
  local c = api.nvim_win_get_config(w)
  T.ok(c.width + 2 <= 30 and c.col + c.width + 2 <= 30, "VimResized: float fits 30 columns", vim.inspect({ c.width, c.col }))
  T.ok(c.height + 2 <= 10, "VimResized: float fits 10 lines", c.height)
  vim.o.columns, vim.o.lines = 120, 40
  vim.cmd("doautocmd VimResized")
  T.eq(api.nvim_win_get_config(w).width, 60, "VimResized back: float grows to 0.5 again")
  qzss.close()
  qzss.setup({ layout = { mode = "float", float = { relative = "win", width = 0.5, height = 0.5, position = "top-left", title = " Outline " } } })
  vim.cmd("vsplit")
  local src_win = api.nvim_get_current_win()
  qzss.open({ focus = false })
  local fw = qzss.get_view().winid
  local fc = api.nvim_win_get_config(fw)
  T.ok(fc.relative == "win" and fc.win == src_win, "relative=win anchors to the source window")
  T.eq(fc.width, math.floor(api.nvim_win_get_width(src_win) * 0.5), "relative=win width is a fraction of the source window")
  T.eq(fc.title[1][1], " Outline ", "custom title string")
  vim.cmd("vertical resize 40")
  vim.cmd("doautocmd WinResized")
  T.eq(api.nvim_win_get_config(fw).width, 20, "WinResized: relative=win float follows the window size")
  vim.cmd("close") -- close the source window the float is anchored to
  vim.wait(200)
  T.ok(not api.nvim_win_is_valid(fw) or qzss.is_open(), "closing the anchor window leaves no stale view")
  T.ok(qzss.get_view() == nil or api.nvim_win_is_valid(qzss.get_view().winid), "view state consistent after anchor close")
  qzss.close()
end

---------------------------------------------------------------- lifecycle: WinClosed, tabs, source wipe, :edit inside float
do
  reset({ layout = { mode = "float" } })
  local src, src_win = edit(RS)
  local closes = {}
  local sub = qzss.subscribe("close", function(ev)
    table.insert(closes, ev.reason)
  end)
  qzss.open()
  api.nvim_win_close(qzss.get_view().winid, true)
  T.eq(qzss.is_open(), false, "external nvim_win_close of the float clears the view")
  T.eq(closes[#closes], "window_closed", "close event reason window_closed")
  -- tabs: each tab has its own view; actions never touch another tab's view
  qzss.open({ focus = false })
  local tab1, fw1 = api.nvim_get_current_tabpage(), qzss.get_view().winid
  vim.cmd("tabnew " .. TS)
  T.eq(qzss.is_open(), false, "new tab has no outline")
  qzss.open({ mode = "sidebar", focus = false })
  local tab2 = api.nvim_get_current_tabpage()
  T.ok(qzss.get_view().source_bufnr ~= src, "tab 2 outline shows its own buffer")
  qzss.close_all()
  T.eq(#qzss.get_folded(src), 0, "close_all in tab 2 does not fold tab 1's buffer")
  vim.cmd("tabprevious")
  T.ok(qzss.is_open({ mode = "float" }) and qzss.get_view().winid == fw1, "tab 1 still has its float")
  T.eq(qzss.get_view({ tabpage = tab2 }).mode, "sidebar", "get_view({tabpage}) reads another tab")
  vim.cmd("tabnext")
  vim.cmd("tabclose")
  T.eq(qzss._state.views[tab2], nil, "tabclose drops tab 2's view")
  T.eq(api.nvim_get_current_tabpage(), tab1, "back in tab 1")
  T.ok(qzss.is_open({ mode = "float" }), "tab 1's float unaffected by closing tab 2")
  -- source buffer wiped while the float shows it
  vim.cmd("edit " .. TS) -- the source window now shows sample.ts; lib.rs stays loaded? hidden off -> unloaded
  vim.wait(300)
  T.eq(qzss.get_view().source_bufnr, vim.fn.bufnr(TS), "float retargets to the new source buffer")
  local tsb = vim.fn.bufnr(TS)
  vim.cmd("enew")
  vim.cmd("bwipeout! " .. tsb)
  vim.wait(300)
  local v = qzss.get_view()
  T.ok(v == nil or (v.source_bufnr ~= tsb and api.nvim_buf_is_valid(v.source_bufnr)), "no view left pointing at a wiped buffer")
  T.eq(qzss._state.bufs[tsb], nil, "model of the wiped buffer dropped")
  qzss.close()
  -- :edit inside the float: file goes to the source window, float closes
  src, src_win = edit(RS)
  qzss.open()
  local fw = qzss.get_view().winid
  local ok, err = pcall(vim.cmd, "edit " .. TS)
  T.ok(ok, ":edit inside the float does not raise", err)
  vim.wait(300)
  T.eq(api.nvim_win_is_valid(fw), false, "float closed after :edit inside it")
  T.eq(api.nvim_win_get_buf(src_win), vim.fn.bufnr(TS), ":edit target shown in the source window")
  T.eq(api.nvim_get_current_win(), src_win, "focus in the source window")
  T.eq(qzss.is_open(), false, "no stale float view after :edit")
  T.eq(#api.nvim_tabpage_list_wins(0), 1, "no orphan windows after :edit in float")
  -- source window closed while a float is open: the outline follows the
  -- window that gets focus (its buffer becomes the source)
  local rs_buf = edit(RS)
  local rs_win = api.nvim_get_current_win()
  vim.cmd("split " .. TS)
  local ts_win = api.nvim_get_current_win()
  api.nvim_set_current_win(rs_win)
  qzss.open({ focus = false })
  T.eq(qzss.get_view().source_bufnr, rs_buf, "float targets lib.rs")
  vim.cmd("close")
  vim.wait(200)
  T.ok(qzss.is_open(), "float survives closing the source window while another window exists")
  T.eq(qzss.get_view().source_bufnr, vim.fn.bufnr(TS), "float retargets to the window that got focus")
  -- a plugin swaps the source window's buffer (nvim_win_set_buf) while the
  -- float has focus: the float follows, and <CR> targets that window
  api.nvim_set_current_win(ts_win)
  vim.cmd("edit " .. RS)
  T.eq(qzss.get_view().source_bufnr, rs_buf, "float back on lib.rs")
  api.nvim_set_current_win(qzss.get_view().winid)
  api.nvim_win_set_buf(ts_win, vim.fn.bufadd(TS))
  T.eq(qzss.get_view().source_bufnr, vim.fn.bufnr(TS), "float follows nvim_win_set_buf on its source window")
  goto_row(qzss.get_view().winid, "Box<T>")
  T.eq(qzss.jump(), true, "jump after the swap")
  T.eq(api.nvim_get_current_win(), ts_win, "jump focused the source window")
  T.eq(api.nvim_get_current_line():match("class Box") ~= nil, true, "cursor on class Box")
  qzss.unsubscribe(sub)
end

---------------------------------------------------------------- symbols API without UI
do
  reset()
  local buf = edit(RS)
  T.eq(select(2, qzss.get_snapshot(buf)), "not_ready", "get_snapshot before any request -> nil, not_ready")
  local got, sync = nil, true
  local h = qzss.request_symbols(buf, function(err, snap)
    got = { err, snap }
  end)
  sync = got ~= nil
  T.eq(sync, false, "request_symbols callback is never synchronous")
  T.ok(type(h.cancel) == "function", "request returns a handle with cancel()")
  vim.wait(1000, function() return got ~= nil end)
  local snap = got and got[2]
  T.ok(got and got[1] == nil and snap, "request_symbols resolves (err=nil, snapshot)")
  T.eq(h.cancel(), false, "cancel() after resolution returns false")
  T.eq(snap.bufnr, buf, "snapshot.bufnr")
  T.eq(snap.changedtick, vim.b[buf].changedtick, "snapshot.changedtick == b:changedtick")
  T.eq(snap.source, "treesitter", "snapshot.source")
  T.eq(snap.pending, false, "snapshot.pending false (no LSP)")
  T.eq(snap.stale, false, "snapshot.stale false")
  local helper
  local function find(list, name)
    for _, s in ipairs(list) do
      if s.name == name then return s end
      local c = find(s.children, name)
      if c then return c end
    end
  end
  helper = find(snap.symbols, "helper")
  T.same(helper.pos, { 33, 11 }, "pos = { row 1-based, col 0-based byte }")
  T.eq(api.nvim_buf_get_lines(buf, 32, 33, false)[1]:sub(helper.pos[2] + 1, helper.pos[2] + 6), "helper", "pos points at the name bytes")
  T.ok(helper.range.start[1] <= 33 and helper.range["end"][1] >= 33, "range contains pos")
  T.eq(helper.depth, 2, "depth")
  T.eq(helper.parent_id, "/TraitImpl:impl<T> Shape<T> for MyStruct<T>/Method:area", "parent_id")
  T.eq(helper.bufnr, buf, "symbol.bufnr")
  local ti = find(snap.symbols, "impl<T> Shape<T> for MyStruct<T>")
  T.ok(ti.trait == "Shape<T>" and ti.self_type == "MyStruct<T>" and ti.where_clause == "where T: Copy + Display", "rust impl extras on public symbols")
  T.eq(ti.parent, nil, "public symbols have no parent back-links (plain tree)")
  -- end is exclusive: text of the struct range ends with "}"
  local st = find(snap.symbols, "MyStruct")
  local text = api.nvim_buf_get_text(buf, st.range.start[1] - 1, st.range.start[2], st.range["end"][1] - 1, st.range["end"][2], {})
  T.eq(text[#text], "}", "range end is exclusive (nvim_buf_get_text over range ends with '}')")
  -- copies are independent
  snap.symbols[1].name = "MUTATED"
  table.remove(snap.symbols, 2)
  snap.symbols[1].children = {}
  local again = qzss.get_snapshot(buf)
  T.eq(again.symbols[1].name, "Shape", "mutating a snapshot does not change the model")
  T.ok(#again.symbols[1].children > 0 and #again.symbols > #snap.symbols, "removing nodes from a snapshot does not change the model")
  local fs = qzss.find_symbol(buf, helper.id)
  fs.pos[1] = 999
  T.same(qzss.find_symbol(buf, helper.id).pos, { 33, 11 }, "find_symbol returns a copy")
  local v0 = qzss.get_view()
  T.eq(v0, nil, "no UI opened by the symbols API")
  -- invalid inputs
  T.eq(select(2, qzss.get_snapshot(99999)), "invalid buffer", "get_snapshot(invalid) -> nil, invalid buffer")
  local e1
  qzss.request_symbols(99999, function(err) e1 = err end)
  vim.wait(200, function() return e1 ~= nil end)
  T.eq(e1, "invalid buffer", "request_symbols(invalid) -> callback err")
  local unl = vim.fn.bufadd(TS)
  local e2
  qzss.request_symbols(unl, function(err) e2 = err end)
  vim.wait(200, function() return e2 ~= nil end)
  T.eq(e2, "buffer not loaded", "request_symbols(unloaded) -> callback err")
  T.ok(errmsg(qzss.request_symbols, buf, "nope"):find("callback must be a function", 1, true), "request_symbols validates the callback")
  T.ok(errmsg(qzss.request_symbols, "x", function() end):find("bufnr must be a number", 1, true), "request_symbols validates bufnr")
  T.eq(select(2, qzss.find_symbol(buf, "/nope")), "unknown symbol id", "find_symbol unknown id")
  -- unsupported filetype: not an error, an empty result with a reason
  local txt = api.nvim_create_buf(true, true)
  vim.bo[txt].filetype = "text"
  local r3
  qzss.request_symbols(txt, function(err, s) r3 = { err, s } end)
  vim.wait(200, function() return r3 ~= nil end)
  T.ok(r3[1] == nil and #r3[2].symbols == 0 and r3[2].error:find("no Tree-sitter extractor", 1, true), "unsupported filetype: empty symbols + error reason")
  -- edits to a requested (tracked) buffer refresh the cache without UI
  local evs = {}
  local sub = qzss.subscribe("symbols", function(ev)
    table.insert(evs, ev)
  end)
  api.nvim_buf_set_lines(buf, 0, 0, false, { "pub struct Added;" })
  T.eq(qzss.get_snapshot(buf).stale, true, "snapshot.stale right after an edit")
  api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  vim.wait(1000, function() return #evs > 0 end)
  T.eq(evs[1] and evs[1].bufnr, buf, "symbols event after edit (no UI)")
  T.eq(evs[1] and evs[1].changedtick, vim.b[buf].changedtick, "event changedtick is the edited tick")
  T.eq(qzss.get_snapshot(buf).symbols[1].name, "Added", "cache updated after edit")
  qzss.unsubscribe(sub)
  -- current_symbol / breadcrumb path
  api.nvim_win_set_cursor(0, { 34, 8 })
  local cs, path = qzss.current_symbol()
  T.eq(cs and cs.name, "helper", "current_symbol at cursor")
  T.eq(table.concat(vim.tbl_map(function(s) return s.name end, path), " > "), "impl<T> Shape<T> for MyStruct<T> > area > helper", "current_symbol path root -> leaf")
  T.eq(qzss.current_symbol({ row = 1 }).name, "Added", "current_symbol({row})")
  T.eq(select(2, qzss.current_symbol({ row = 2 })), "no symbol", "current_symbol outside symbols -> nil, no symbol")
  local fresh = edit(TS)
  T.eq(select(2, qzss.current_symbol()), "pending", "current_symbol on an untracked buffer -> pending, starts a request")
  vim.wait(500, function() return qzss.get_snapshot(fresh) ~= nil end)
  api.nvim_win_set_cursor(0, { 1, 0 })
  T.ok(qzss.get_snapshot(fresh) ~= nil, "background request filled the cache")
  -- current_symbol from the outline window = selected row
  qzss.open()
  goto_row(qzss.get_view().winid, "Box<T>")
  T.eq(qzss.current_symbol().name, "Box", "current_symbol in the outline window = cursor row symbol")
  qzss.close()
end

---------------------------------------------------------------- jump_to
do
  reset()
  local buf, win = edit(RS)
  local snap
  qzss.request_symbols(buf, function(_, s) snap = s end)
  vim.wait(500, function() return snap end)
  local helper_id = "/TraitImpl:impl<T> Shape<T> for MyStruct<T>/Method:area/Function:helper"
  T.eq(qzss.jump_to(helper_id), true, "jump_to(id) -> true")
  T.same(api.nvim_win_get_cursor(win), { 33, 11 }, "jump_to(id) moves the cursor to pos")
  T.eq(qzss.jump_to(snap.symbols[1]), true, "jump_to(symbol table)")
  T.same(api.nvim_win_get_cursor(win), { 3, 10 }, "jump_to(symbol) cursor")
  local ok, err = qzss.jump_to("/Nope")
  T.ok(ok == false and err == "unknown symbol id", "jump_to unknown id -> false, err")
  ok, err = qzss.jump_to({ bufnr = 99999, pos = { 1, 0 } })
  T.ok(ok == false and err == "invalid buffer", "jump_to invalid buffer -> false, err")
  T.ok(errmsg(qzss.jump_to, 42):find("target must be", 1, true), "jump_to rejects a number")
  T.ok(errmsg(qzss.jump_to, { bufnr = buf }):find("needs numeric bufnr and pos", 1, true), "jump_to rejects a table without pos")
  T.eq(qzss.jump_to({ bufnr = buf, pos = { 9999, 9999 } }), true, "out-of-range pos is clamped")
  T.eq(api.nvim_win_get_cursor(win)[1], api.nvim_buf_line_count(buf), "clamped to the last line")
  -- buffer not shown anywhere: opened in the current window
  local other = edit(TS)
  ok = qzss.jump_to(snap.symbols[2])
  T.ok(ok and api.nvim_get_current_buf() == buf and api.nvim_win_get_cursor(0)[1] == 10, "jump_to a hidden buffer shows it in the current window")
  -- from the outline window: target goes to the source window, outline stays open
  vim.cmd("buffer " .. other)
  qzss.open()
  ok = qzss.jump_to(snap.symbols[2], { focus = false })
  T.ok(ok and qzss.is_open(), "jump_to from the outline keeps the outline open")
  T.eq(api.nvim_get_current_win(), qzss.get_view().winid, "focus=false keeps focus")
  T.eq(api.nvim_win_get_buf(qzss.get_view().source_winid), buf, "target shown in the source window, not in the outline")
  qzss.close()
end

---------------------------------------------------------------- filter & folds without UI
do
  reset()
  local buf = edit(RS)
  T.eq(qzss.get_filter(buf), nil, "no filter by default")
  T.eq(qzss.set_filter({ "Struct", "Enum" }, buf), true, "set_filter returns true")
  T.same(qzss.get_filter(buf), { "Enum", "Struct" }, "get_filter sorted")
  T.eq(qzss.set_filter({ "Bogus" }, buf), false, "unknown kind -> false")
  T.ok(notes[#notes] and notes[#notes].msg:find("unknown kind 'Bogus'", 1, true), "unknown kind notifies")
  T.same(qzss.get_filter(buf), { "Enum", "Struct" }, "rejected filter leaves the old one")
  T.ok(errmsg(qzss.set_filter, "Struct"):find("kinds must be a list", 1, true), "set_filter rejects a string")
  qzss.set_filter({}, buf)
  T.eq(qzss.get_filter(buf), nil, "{} clears")
  T.eq(select(2, qzss.set_folded("/Trait:Shape", true, { bufnr = buf })), "not_ready", "set_folded before symbols -> not_ready")
  local done
  qzss.request_symbols(buf, function() done = true end)
  vim.wait(500, function() return done end)
  local states = {}
  local sub = qzss.subscribe("state", function(ev) table.insert(states, ev.what) end)
  T.eq(qzss.set_folded("/Trait:Shape", true, { bufnr = buf }), true, "set_folded(id, true)")
  T.same(qzss.get_folded(buf), { "/Trait:Shape" }, "get_folded")
  T.same({ qzss.set_folded("/Trait:Shape/Method:area", true, { bufnr = buf }) }, { false, "symbol has no children" }, "leaf cannot fold")
  T.same({ qzss.set_folded("/Nope", true, { bufnr = buf }) }, { false, "unknown symbol id" }, "unknown id")
  qzss.close_all(buf)
  T.ok(#qzss.get_folded(buf) >= 7, "close_all(bufnr) folds every container")
  qzss.open_all(buf)
  T.same(qzss.get_folded(buf), {}, "open_all(bufnr)")
  T.same(states, { "fold", "fold", "fold" }, "state events for folds")
  qzss.unsubscribe(sub)
  -- the outline renders model state set through the API
  qzss.set_folded("/Trait:Shape", true, { bufnr = buf })
  qzss.open({ focus = false })
  T.contains(win_lines(qzss.get_view().winid), "▸ ◈ Shape [+3] <T>  trait", "outline shows a fold set via the API")
  T.eq(qzss.toggle_fold(), true, "row action works")
  T.eq(qzss.close(), true, "close() returns true when open")
  T.eq(qzss.close(), false, "close() returns false when closed")
  T.eq(qzss.toggle_fold(), false, "row actions are no-ops (false) when closed")
  T.eq(qzss.jump(), false, "jump() is a no-op (false) when closed")
end

---------------------------------------------------------------- events: re-entrancy, errors, unsubscribe
do
  reset()
  local order = {}
  local id2
  local id1 = qzss.subscribe("state", function(ev)
    table.insert(order, "a:" .. ev.what)
    if ev.what == "filter" then
      qzss.set_folded("/Trait:Shape", true) -- emits "state" from inside a callback
      table.insert(order, "a:after-nested-call")
    end
    ev.bufnr = -1 -- mutating the payload must not leak into other listeners
  end)
  local bad = qzss.subscribe("state", function()
    error("boom")
  end)
  id2 = qzss.subscribe("state", function(ev)
    table.insert(order, "b:" .. ev.what .. ":" .. tostring(ev.bufnr > 0))
  end)
  local buf = edit(RS)
  local done
  qzss.request_symbols(buf, function() done = true end)
  vim.wait(500, function() return done end)
  qzss.set_filter({ "Trait" })
  T.same(order, { "a:filter", "a:after-nested-call", "b:filter:true", "a:fold", "b:fold:true" },
    "nested emit is queued after the current dispatch; payload copies per listener", vim.inspect(order))
  vim.wait(100)
  local errs = vim.tbl_filter(function(n) return n.msg:find("subscriber for 'state' failed", 1, true) end, notes)
  T.ok(#errs >= 1 and errs[1].msg:find("boom", 1, true), "callback error reported via vim.notify")
  T.eq(qzss.unsubscribe(bad), true, "unsubscribe -> true")
  T.eq(qzss.unsubscribe(bad), false, "unsubscribe twice -> false")
  -- unsubscribe during dispatch: a later listener removed by an earlier one is not called
  order = {}
  qzss.unsubscribe(id1)
  local victim
  local killer = qzss.subscribe("state", function()
    table.insert(order, "killer")
    qzss.unsubscribe(victim)
  end)
  victim = qzss.subscribe("state", function()
    table.insert(order, "victim")
  end)
  qzss.set_filter(nil)
  T.same(order, { "b:filter:true", "killer" }, "listener removed during dispatch is skipped", vim.inspect(order))
  qzss.unsubscribe(killer)
  qzss.unsubscribe(id2)
  T.ok(errmsg(qzss.subscribe, "nope", function() end):find("unknown event", 1, true), "subscribe rejects unknown events")
  T.ok(errmsg(qzss.subscribe, "symbols", 1):find("callback must be a function", 1, true), "subscribe validates the callback")
  -- request callback errors are contained too
  notes = {}
  local fine
  qzss.request_symbols(buf, function() error("cb boom") end)
  qzss.request_symbols(buf, function() fine = true end)
  vim.wait(300, function() return fine end)
  vim.wait(50)
  T.ok(fine, "a failing request callback does not block others")
  T.ok(#vim.tbl_filter(function(n) return n.msg:find("cb boom", 1, true) end, notes) == 1, "request callback error notified")
end

---------------------------------------------------------------- request contract without LSP (round 2)
-- cancel() and deletion between resolution and delivery for requests that
-- resolve without any server: uncomputed buffers (Tree-sitter resolves
-- synchronously inside the request) and cache hits.
do
  reset()
  local buf = edit(RS)
  local ran = 0
  local h1 = qzss.request_symbols(buf, function() ran = ran + 1 end)
  T.eq(h1.cancel(), true, "contract: cancel() of an uncomputed (Tree-sitter-only) request before delivery -> true")
  T.eq(h1.cancel(), false, "contract: second cancel() -> false")
  vim.wait(200)
  T.eq(ran, 0, "contract: cancelled Tree-sitter-only callback never runs")
  T.ok(qzss.get_snapshot(buf) ~= nil, "contract: the computation still filled the cache")
  local h2 = qzss.request_symbols(buf, function() ran = ran + 1 end)
  T.eq(h2.cancel(), true, "contract: cancel() of a cache-hit request before delivery -> true")
  vim.wait(200)
  T.eq(ran, 0, "contract: cancelled cache-hit callback never runs")
  local h3 = qzss.request_symbols(buf, function() ran = ran + 1 end)
  vim.wait(200, function() return ran == 1 end)
  T.eq(ran, 1, "contract: an uncancelled request is delivered once")
  T.eq(h3.cancel(), false, "contract: cancel() after delivery -> false")
  -- deleted / unloaded between resolution and delivery
  local function probe(path, how)
    local b = vim.fn.bufadd(path)
    vim.fn.bufload(b)
    if how == "cached" then
      local d
      qzss.request_symbols(b, function() d = true end)
      vim.wait(500, function() return d end)
    end
    local r
    qzss.request_symbols(b, function(e, s) r = { e, s } end)
    if how == "unload" then
      vim.cmd("bunload! " .. b)
    else
      api.nvim_buf_delete(b, { force = true })
    end
    vim.wait(1000, function() return r ~= nil end)
    return r
  end
  local r = probe(TS, "delete")
  T.ok(r and r[2] == nil and (r[1] == "buffer deleted" or r[1] == "buffer unloaded"), "contract: delete before delivery (uncomputed) -> err, nil", r and tostring(r[1]))
  r = probe(root .. "/tests/fixtures/sample.json", "cached")
  T.ok(r and r[2] == nil and (r[1] == "buffer deleted" or r[1] == "buffer unloaded"), "contract: delete before delivery (cache hit) -> err, nil", r and tostring(r[1]))
  r = probe(root .. "/tests/fixtures/sample.yaml", "unload")
  T.ok(r and r[1] == "buffer unloaded" and r[2] == nil, "contract: :bunload before delivery -> 'buffer unloaded', nil", r and tostring(r[1]))
  local wb = vim.fn.bufadd(root .. "/tests/fixtures/ts/view.tsx")
  vim.fn.bufload(wb)
  local rw
  qzss.request_symbols(wb, function(e, s) rw = { e, s } end)
  vim.cmd("bwipeout! " .. wb)
  vim.wait(1000, function() return rw ~= nil end)
  T.ok(rw and rw[1] == "buffer deleted" and rw[2] == nil, "contract: bwipeout before delivery -> 'buffer deleted', nil", rw and tostring(rw[1]))
  -- Symbol.source on every public symbol (snapshot, find_symbol, current_symbol)
  local snap = qzss.get_snapshot(buf)
  local n, bad = 0, 0
  local function walk(list)
    for _, s in ipairs(list) do
      n = n + 1
      if s.source ~= "treesitter" then bad = bad + 1 end
      walk(s.children)
    end
  end
  walk(snap.symbols)
  T.ok(n == 22 and bad == 0, ("contract: every Tree-sitter symbol has source='treesitter' (%d symbols, %d without)"):format(n, bad))
  T.eq(qzss.find_symbol(buf, "/Trait:Shape").source, "treesitter", "contract: find_symbol carries source")
  api.nvim_win_set_cursor(0, { 34, 8 })
  local cs, path = qzss.current_symbol()
  T.ok(cs.source == "treesitter" and path[1].source == "treesitter", "contract: current_symbol and its path carry source")
end

---------------------------------------------------------------- follow-ups: focused float starts on the cursor symbol; messages wrap
do
  reset()
  local _, win = edit(RS)
  api.nvim_win_set_cursor(win, { 34, 8 })
  qzss.open({ mode = "float" })
  local v = qzss.get_view()
  T.ok(v.focused, "focused float")
  T.eq(v.cursor_symbol_id, "/TraitImpl:impl<T> Shape<T> for MyStruct<T>/Method:area/Function:helper", "focused float opens on the symbol under the source cursor")
  qzss.close()
  qzss.open({ mode = "sidebar" })
  T.eq(qzss.get_view().cursor_symbol_id, "/TraitImpl:impl<T> Shape<T> for MyStruct<T>/Method:area/Function:helper", "focused sidebar opens on the cursor symbol too")
  T.eq(vim.wo[qzss.get_view().winid].wrap, false, "symbol rows do not wrap")
  qzss.close()
  vim.cmd("enew")
  vim.bo.filetype = "text"
  qzss.open({ mode = "float" })
  T.eq(vim.wo[qzss.get_view().winid].wrap, true, "a message row wraps inside the float")
  qzss.close()
end

---------------------------------------------------------------- wrong-type errors (round 3)
-- Every public function that validates argument types must raise a message
-- that starts with "qzss.<function>:" with no file:line prefix.
do
  reset()
  edit(RS)
  local cases = {
    { "open", "x" }, { "toggle", 1 }, { "is_open", 1 }, { "get_view", 1 }, { "refresh", "x" },
    { "get_snapshot", "x" }, { "request_symbols", "x", function() end }, { "request_symbols", 0, "nope" },
    { "find_symbol", "x", "/Trait:Shape" }, { "find_symbol", 0, 1 }, { "current_symbol", 1 },
    { "jump_to", 42 }, { "jump_to", { bufnr = 0 } }, { "jump_to", "/Trait:Shape", 1 },
    { "set_filter", "Struct" }, { "set_filter", { "Struct" }, "x" }, { "get_filter", "x" }, { "get_folded", "x" },
    { "set_folded", 1, true }, { "set_folded", "/Trait:Shape", "yes" }, { "set_folded", "/Trait:Shape", true, 1 },
    { "open_all", "x" }, { "close_all", "x" }, { "jump", 1 },
    { "subscribe", "nope", function() end }, { "subscribe", "symbols", 1 },
  }
  for _, c in ipairs(cases) do
    local ok, e = pcall(qzss[c[1]], unpack(c, 2))
    local prefix = "qzss." .. c[1] .. ":"
    T.ok(not ok and tostring(e):sub(1, #prefix) == prefix,
      ("errors: %s(%s) raises '%s ...' without a file prefix"):format(c[1], vim.inspect(c[2]), prefix), tostring(e))
  end
  local ok, e = pcall(qapi.open, "x")
  T.ok(not ok and not tostring(e):find("api.lua", 1, true), "errors: message does not blame qzss's api.lua", tostring(e))
end

vim.notify = real_notify
T.finish()
