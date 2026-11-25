-- Async symbol-request contract with an in-process documentSymbol server:
-- coalescing, stale responses, cancel, pending flag, wipe while pending.
-- Separate process from tests/api_spec.lua: Neovim 0.12.6 can crash in
-- nvim__redraw (LspDetach handlers) after the many window/float operations
-- of that file, which is unrelated to qzss.
-- Run: nvim --clean --headless -l tests/api_async_spec.lua
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

---------------------------------------------------------------- async LSP contract (in-process server)
do
  reset()
  local path = vim.fn.tempname() .. ".qz"
  vim.fn.writefile({ "alpha", "beta" }, path)
  vim.cmd("edit " .. path)
  local buf = api.nvim_get_current_buf()
  vim.bo[buf].filetype = "qzfake"
  local srv = { requests = 0, delay = 150, seen_ticks = {} }
  local next_id = 0
  local function cmd(dispatchers)
    local closing = false
    return {
      request = function(method, _, callback)
        next_id = next_id + 1
        if method == "initialize" then
          callback(nil, { capabilities = { documentSymbolProvider = true } })
        elseif method == "textDocument/documentSymbol" then
          srv.requests = srv.requests + 1
          local tick = vim.b[buf].changedtick
          local name = "sym_" .. tick
          table.insert(srv.seen_ticks, tick)
          vim.defer_fn(function()
            callback(nil, { {
              name = name, kind = 12, detail = "()",
              range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 5 } },
              selectionRange = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 5 } },
            } })
          end, srv.delay)
        elseif method == "shutdown" then
          callback(nil, nil)
        end
        return true, next_id
      end,
      notify = function(method)
        if method == "exit" then
          dispatchers.on_exit(0, 15)
        end
        return true
      end,
      is_closing = function() return closing end,
      terminate = function() closing = true end,
    }
  end
  local cid = vim.lsp.start({ name = "qzfake", cmd = cmd, root_dir = vim.fn.fnamemodify(path, ":h") }, { bufnr = buf })
  T.ok(vim.wait(2000, function() return #vim.lsp.get_clients({ bufnr = buf, method = "textDocument/documentSymbol" }) > 0 end), "in-process documentSymbol client attached")
  -- coalescing: two requests at one changedtick share one server request
  local r1, r2
  srv.requests = 0
  qzss.request_symbols(buf, function(err, s) r1 = { err, s } end)
  qzss.request_symbols(buf, function(err, s) r2 = { err, s } end)
  vim.wait(2000, function() return r1 and r2 end)
  T.eq(srv.requests, 1, "two requests at the same changedtick -> one LSP request")
  T.ok(r1 and r1[2].source == "lsp" and r1[2].symbols[1].name == "sym_" .. vim.b[buf].changedtick, "LSP-only result", r1 and vim.inspect(r1[2].symbols[1]))
  T.eq(r1[2].symbols[1].name, r2[2].symbols[1].name, "both callbacks got the same result")
  T.ok(r1[2].symbols[1].source == "lsp", "LSP-only symbols carry source = 'lsp'")
  -- cached + ready: answered without a new server request
  local r3
  qzss.request_symbols(buf, function(_, s) r3 = s end)
  vim.wait(500, function() return r3 end)
  T.eq(srv.requests, 1, "ready cache at the same changedtick -> no new LSP request")
  -- edit while the server is answering: the stale answer is dropped
  srv.requests = 0
  local r4, published = nil, {}
  local sub = qzss.subscribe("symbols", function(ev)
    if ev.bufnr == buf and not ev.pending then
      table.insert(published, ev.changedtick)
    end
  end)
  api.nvim_buf_set_lines(buf, 0, 0, false, { "beta2" }) -- new text: the request must ask the server
  qzss.request_symbols(buf, function(err, s) r4 = { err, s } end)
  local old_tick = vim.b[buf].changedtick
  vim.wait(30)
  T.eq(srv.requests, 1, "request in flight for the old text")
  api.nvim_buf_set_lines(buf, 0, 0, false, { "gamma" })
  local new_tick = vim.b[buf].changedtick
  vim.wait(2000, function() return r4 end)
  T.ok(r4 and r4[1] == nil, "request resolved after an edit during the LSP round trip")
  T.eq(r4 and r4[2].changedtick, new_tick, "result is for the edited text (changedtick)")
  T.eq(r4 and r4[2].symbols[1].name, "sym_" .. new_tick, "stale LSP answer (sym_" .. old_tick .. ") was not delivered")
  T.ok(not vim.tbl_contains(published, old_tick), "no completed symbols event for the stale changedtick")
  T.eq(srv.requests, 2, "the computation was restarted once for the new text")
  qzss.unsubscribe(sub)
  -- cancel
  local called = false
  api.nvim_buf_set_lines(buf, 0, 0, false, { "delta" })
  local h = qzss.request_symbols(buf, function() called = true end)
  T.eq(h.cancel(), true, "cancel() of a pending request -> true")
  T.eq(h.cancel(), false, "second cancel() -> false")
  vim.wait(500)
  T.eq(called, false, "cancelled callback never runs")
  -- pending snapshot flags
  api.nvim_buf_set_lines(buf, 0, 0, false, { "eps" })
  qzss.refresh(buf)
  local snap = qzss.get_snapshot(buf)
  T.ok(snap and snap.pending == true, "get_snapshot during an LSP round trip: pending = true")
  vim.wait(1000, function() return not qzss.get_snapshot(buf).pending end)
  -- buffer wiped while the server is still answering: the request fails with
  -- "buffer deleted" and the late answer is ignored
  srv.delay = 400
  api.nvim_buf_set_lines(buf, 0, 0, false, { "zeta" })
  local wiped
  qzss.request_symbols(buf, function(err, s) wiped = { err, s } end)
  vim.wait(50)
  T.eq(wiped, nil, "request pending while the server answers")
  vim.cmd("bwipeout! " .. buf)
  vim.wait(1000, function() return wiped end)
  T.ok(wiped and wiped[1] == "buffer deleted" and wiped[2] == nil, "wipe while pending -> err 'buffer deleted'", wiped and wiped[1])
  vim.wait(600) -- the late server answer arrives: must not raise or resurrect state
  T.eq(qzss._state.bufs[buf], nil, "no model left for the wiped buffer")
  local errs = vim.tbl_filter(function(n) return (n.level or 0) >= vim.log.levels.ERROR end, notes)
  T.eq(#errs, 0, "no error notifications from the late answer", vim.inspect(errs))
  pcall(function() vim.lsp.get_client_by_id(cid):stop(true) end)
end

vim.notify = real_notify
T.finish()
