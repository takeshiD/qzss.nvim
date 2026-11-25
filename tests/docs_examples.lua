-- Runs the code examples of docs/api.md, README.md and doc/qzss.txt and
-- checks that each one does what the documentation says it does.
-- Run: nvim --clean --headless -l tests/docs_examples.lua
--
-- docs/api.md: every ```lua block must be preceded by `<!-- example: NAME -->`
-- and NAME must have a check below (the test fails otherwise).
-- README.md: blocks marked the same way are run and checked too.
-- doc/qzss.txt: every `>lua` block of the qzss-api section must also appear
-- in docs/api.md (so it is covered by a check) and must run.
local root = vim.fn.getcwd()
package.path = root .. "/?.lua;" .. package.path
dofile(root .. "/tests/minimal_init.lua")
local T = require("tests.helpers")
local qzss = require("qzss")
local config = require("qzss.config")
local events = require("qzss.events")
local api = vim.api

-- Keep the headless default 80x24: changing 'columns' and then redrawing
-- after a split with a winbar was closed crashes Neovim 0.12.6 (double free in
-- grid_alloc; reproducer: tests/upstream/nvim-headless-winbar-crash.lua).
local RS = root .. "/tests/fixtures/rust/src/lib.rs"

local notes = {}
vim.notify = function(msg, level)
  table.insert(notes, { msg = msg, level = level })
end

local function read(path)
  return table.concat(vim.fn.readfile(root .. "/" .. path), "\n") .. "\n"
end

local function marked_blocks(text)
  local out = {}
  for name, code in text:gmatch("<!%-%- example: ([%w%-]+) %-%->\n```lua\n(.-)```") do
    table.insert(out, { name = name, code = code })
  end
  return out
end

local function feed(keys)
  api.nvim_feedkeys(vim.keycode(keys), "mx", false)
end

local function wait(fn, ms)
  return vim.wait(ms or 2000, fn, 10)
end

local function find(list, pred)
  for _, s in ipairs(list) do
    if pred(s) then
      return s
    end
    local c = find(s.children, pred)
    if c then
      return c
    end
  end
end

local function warm(buf)
  local done
  qzss.request_symbols(buf or 0, function() done = true end)
  wait(function() return done end)
end

local function fresh()
  pcall(qzss.close)
  vim.cmd("silent! tabonly!")
  vim.cmd("silent! only!")
  vim.cmd("silent! %bwipeout!")
  events._reset()
  qzss.setup({})
  vim.o.statusline = ""
  notes = {}
  vim.cmd("edit! " .. RS)
  return api.nvim_get_current_buf(), api.nvim_get_current_win()
end

local function helper_pos()
  return { 33, 11 }
end

-- checks: name -> { pre = fn(ctx)?, check = fn(ctx) }
local checks = {}

checks["layout-defaults"] = {
  check = function()
    T.same(config.options.layout, config.defaults.layout, "layout-defaults: the documented block equals the real defaults")
  end,
}

checks["choose-mode"] = {
  check = function()
    vim.cmd("Qzss")
    T.ok(qzss.is_open({ mode = "float" }), "choose-mode: :Qzss opens the float")
    feed("<C-w>p")
    feed("<leader>O")
    T.ok(qzss.is_open({ mode = "sidebar" }), "choose-mode: <leader>O switches to the sidebar")
    feed("<C-w>p")
    feed("<leader>o")
    T.eq(qzss.is_open(), false, "choose-mode: <leader>o (:Qzss) toggles closed")
  end,
}

checks["custom-float"] = {
  check = function(ctx)
    qzss.open()
    local v = qzss.get_view()
    local c = api.nvim_win_get_config(v.winid)
    T.eq(v.mode, "float", "custom-float: mode float")
    T.ok(c.relative == "win" and c.win == ctx.win, "custom-float: relative to the source window")
    T.eq(c.width, 50, "custom-float: width 50 cells")
    T.eq(c.height, math.min(30, math.floor(api.nvim_win_get_height(ctx.win) * 0.6)), "custom-float: height 0.6 of the window, max 30")
    T.eq(c.col, api.nvim_win_get_width(ctx.win) - 50 - 2, "custom-float: top-right column")
    T.eq(c.row, 0, "custom-float: top row")
    T.eq(c.title[1][1], " Outline ", "custom-float: title")
    T.eq(vim.wo[v.winid].winblend, 10, "custom-float: winblend 10")
    api.nvim_win_set_cursor(v.winid, { 2, 0 })
    qzss.jump()
    T.ok(qzss.is_open(), "custom-float: close_on_jump=false keeps it open after <CR>")
  end,
}

checks["keymaps"] = {
  check = function()
    feed("<leader>of")
    T.ok(qzss.is_open({ mode = "float" }), "keymaps: <leader>of opens the float")
    feed("<Esc>")
    T.ok(qzss.is_open(), "keymaps: float_close=false -> <Esc> does not close")
    feed("<C-c>")
    T.eq(qzss.is_open(), false, "keymaps: <C-c> (extra close key) closes")
    feed("<leader>os")
    T.ok(qzss.is_open({ mode = "sidebar" }) and not qzss.get_view().focused, "keymaps: <leader>os opens the sidebar without focus")
    feed("<leader>oz")
    T.ok(#qzss.get_folded() >= 7, "keymaps: <leader>oz folds everything")
  end,
}

checks["quickfix"] = {
  check = function()
    T.ok(wait(function() return vim.fn.getqflist({ title = 1 }).title == "qzss functions" end), "quickfix: list created")
    local items = vim.fn.getqflist()
    local helper
    for _, it in ipairs(items) do
      if it.text:find("Function helper", 1, true) then
        helper = it
      end
    end
    T.ok(#items >= 7, "quickfix: functions and methods collected (" .. #items .. ")")
    T.ok(helper and helper.lnum == 33 and helper.col == 12, "quickfix: nested fn helper at 33:12", helper and vim.inspect({ helper.lnum, helper.col }))
    T.ok(helper and helper.text:find("    Function helper<U: Copy>", 1, true), "quickfix: depth indentation + signature", helper and helper.text)
  end,
}

checks["picker"] = {
  check = function(ctx)
    local orig = vim.ui.select
    local seen
    vim.ui.select = function(items, opts, on_choice)
      seen = { items = items, opts = opts }
      for _, it in ipairs(items) do
        if it.label:match("area › helper$") then
          return on_choice(it)
        end
      end
      on_choice(nil)
    end
    api.nvim_win_set_cursor(0, { 1, 0 })
    feed("<leader>fs")
    wait(function() return seen ~= nil end)
    vim.ui.select = orig
    T.ok(seen and #seen.items >= 20, "picker: every symbol offered (" .. (seen and #seen.items or 0) .. ")")
    T.eq(seen and seen.opts.prompt, "Symbol", "picker: prompt")
    local label = seen and seen.opts.format_item(seen.items[#seen.items])
    T.ok(label and label:find("Constant   inner › LIMIT", 1, true), "picker: format_item shows kind + path", label)
    T.same(api.nvim_win_get_cursor(ctx.win), helper_pos(), "picker: choosing helper jumps to its name")
  end,
}

checks["breadcrumb"] = {
  pre = function()
    api.nvim_win_set_cursor(0, { 34, 8 })
  end,
  check = function()
    local want = "impl<T> Shape<T> for MyStruct<T> › area › helper"
    T.ok(wait(function() return _G.qzss_breadcrumb() == want end), "breadcrumb: function returns the path", _G.qzss_breadcrumb())
    local sl = api.nvim_eval_statusline(vim.o.statusline, {}).str
    T.ok(sl:find(want, 1, true), "breadcrumb: rendered in the statusline", sl)
    api.nvim_win_set_cursor(0, { 1, 0 })
    T.eq(_G.qzss_breadcrumb(), "", "breadcrumb: empty outside symbols")
  end,
}

checks["jump"] = {
  check = function()
    api.nvim_win_set_cursor(0, { 1, 0 })
    feed("]s") -- first use only warms the cache
    wait(function() return qzss.get_snapshot(0) ~= nil end)
    feed("]s")
    T.same(api.nvim_win_get_cursor(0), { 3, 10 }, "jump: ]s -> trait Shape name")
    feed("]s")
    T.same(api.nvim_win_get_cursor(0), { 10, 11 }, "jump: ]s -> struct MyStruct name")
    feed("[s")
    T.same(api.nvim_win_get_cursor(0), { 3, 10 }, "jump: [s -> back to Shape")
  end,
}

checks["custom-ui"] = {
  check = function(ctx)
    local lb = vim.fn.bufnr("qzss-symbols")
    local function text()
      return table.concat(api.nvim_buf_get_lines(lb, 0, -1, false), "\n")
    end
    T.ok(wait(function() return text():find("Struct     MyStruct", 1, true) ~= nil end), "custom-ui: list filled", text())
    T.eq(qzss.get_view(), nil, "custom-ui: no qzss outline opened")
    api.nvim_buf_set_lines(ctx.buf, 0, 0, false, { "pub struct AddedByEdit;" })
    api.nvim_exec_autocmds("TextChanged", { buffer = ctx.buf })
    T.ok(wait(function() return text():find("AddedByEdit", 1, true) ~= nil end), "custom-ui: an edit updates the list through the event", text())
    local before = events.count()
    vim.cmd("bwipeout " .. lb)
    T.eq(events.count(), before - 1, "custom-ui: wiping the list unsubscribes")
  end,
}

checks["filter"] = {
  check = function()
    qzss.open({ focus = false })
    feed("<leader>ot")
    T.same(qzss.get_filter(), { "Class", "Enum", "Interface", "Struct", "Trait", "TypeAlias" }, "filter: types-only on")
    local lines = api.nvim_buf_get_lines(qzss.get_view().bufnr, 0, -1, false)
    T.ok(not table.concat(lines, "\n"):find("helper", 1, true), "filter: outline hides functions", table.concat(lines, "\n"))
    feed("<leader>ot")
    T.eq(qzss.get_filter(), nil, "filter: toggled off")
  end,
}

checks["focus-fold"] = {
  pre = function(ctx)
    api.nvim_win_set_cursor(ctx.win, { 34, 8 })
    warm(ctx.buf)
  end,
  check = function()
    T.ok(qzss.is_open({ mode = "float" }), "focus-fold: float opened")
    local folded = qzss.get_folded()
    T.ok(vim.tbl_contains(folded, "/Trait:Shape"), "focus-fold: unrelated symbols folded")
    T.ok(not vim.tbl_contains(folded, "/TraitImpl:impl<T> Shape<T> for MyStruct<T>"), "focus-fold: ancestors unfolded")
    local lines = api.nvim_buf_get_lines(qzss.get_view().bufnr, 0, -1, false)
    T.contains(lines, "ƒ helper<U: Copy>(u: U) -> U", "focus-fold: cursor symbol visible")
  end,
}

checks["events"] = {
  check = function()
    qzss.open({ mode = "sidebar" })
    qzss.close()
    local msgs = vim.tbl_map(function(n) return n.msg end, notes)
    T.ok(vim.tbl_contains(msgs, "qzss: sidebar opened in tab 1"), "events: open notification", vim.inspect(msgs))
    T.ok(vim.tbl_contains(msgs, "qzss: sidebar closed (close)"), "events: close notification", vim.inspect(msgs))
  end,
}

checks["readme-float"] = checks["choose-mode"]
checks["readme-statusline"] = checks["breadcrumb"]
checks["readme-symbols"] = checks["quickfix"]

local function run(source, block)
  local ctx = {}
  ctx.buf, ctx.win = fresh()
  local c = checks[block.name]
  if not T.ok(c ~= nil, ("%s: example '%s' has a check"):format(source, block.name)) then
    return
  end
  if c.pre then
    c.pre(ctx)
  end
  local chunk, err = loadstring(block.code, source .. ":" .. block.name)
  if not T.ok(chunk ~= nil, ("%s: '%s' parses"):format(source, block.name), err) then
    return
  end
  local ok, e = pcall(chunk)
  if not T.ok(ok, ("%s: '%s' runs"):format(source, block.name), e) then
    return
  end
  c.check(ctx)
end

---------------------------------------------------------------- docs/api.md
local doc = read("docs/api.md")
local blocks = marked_blocks(doc)
local _, all_lua = doc:gsub("```lua\n", "")
T.eq(#blocks, all_lua, "docs/api.md: every lua block is a checked example")
T.ok(#blocks >= 12, "docs/api.md: " .. #blocks .. " examples")
local names = {}
for _, b in ipairs(blocks) do
  names[b.name] = true
  run("docs/api.md", b)
end
for _, need in ipairs({ "choose-mode", "custom-float", "keymaps", "quickfix", "picker", "breadcrumb", "jump", "custom-ui", "filter", "focus-fold", "events" }) do
  T.ok(names[need], "docs/api.md covers use case " .. need)
end

---------------------------------------------------------------- README.md
local readme_blocks = marked_blocks(read("README.md"))
T.ok(#readme_blocks >= 3, "README.md: " .. #readme_blocks .. " API quick examples")
for _, b in ipairs(readme_blocks) do
  run("README.md", b)
end
T.ok(read("README.md"):find("docs/api.md", 1, true), "README links docs/api.md")

---------------------------------------------------------------- doc/qzss.txt
local help = read("doc/qzss.txt")
local api_sec = help:match("%*qzss%-api%*(.-)\n==========")
T.ok(api_sec ~= nil, "help: qzss-api section found")
local hblocks = {}
for code in (api_sec or ""):gmatch(">lua\n(.-)\n<") do
  table.insert(hblocks, code)
end
T.ok(#hblocks >= 3, "help: qzss-api has " .. #hblocks .. " lua examples")
local function norm(s)
  return (s:gsub("\n%s+", "\n"):gsub("^%s+", ""):gsub("%s+$", ""))
end
local doc_norm = {}
for _, b in ipairs(blocks) do
  doc_norm[norm(b.code)] = b.name
end
for i, code in ipairs(hblocks) do
  local name = doc_norm[norm(code)]
  T.ok(name ~= nil, ("help example %d is identical to a checked docs/api.md example (%s)"):format(i, tostring(name)), code)
  if name then
    run("doc/qzss.txt", { name = name, code = code })
  end
end

T.finish()
