-- Real language-server E2E: rust-analyzer and typescript-language-server.
-- Run: nvim --clean --headless -l tests/lsp_e2e.lua
local root = vim.fn.getcwd()
package.path = root .. "/?.lua;" .. package.path
vim.env.QZSS_LSP = "1"
dofile(root .. "/tests/minimal_init.lua")
local T = require("tests.helpers")
local qzss = require("qzss")
local lspb = require("qzss.backends.lsp")

local function open(path)
  vim.cmd("edit " .. root .. "/" .. path)
  local buf = vim.api.nvim_get_current_buf()
  local ok = vim.wait(60000, function()
    return lspb.available(buf)
  end, 100)
  T.ok(ok, path .. ": LSP client attached")
  return buf
end

local function request(buf, label)
  local result, err, client
  -- servers may answer with an empty list while still indexing: retry
  local deadline = vim.uv.now() + 90000
  repeat
    result, err = nil, nil
    lspb.request(buf, function(r, e, c)
      result, err, client = r, e or false, c
    end, 30000)
    vim.wait(30000, function()
      return err ~= nil
    end, 50)
    if result and #result > 0 then
      break
    end
    vim.wait(1000)
  until vim.uv.now() > deadline
  T.ok(result and #result > 0, label .. ": real server returned document symbols (" .. tostring(client) .. ")", err)
  return result or {}, client
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

-- Rust via rust-analyzer -------------------------------------------------
do
  local buf = open("tests/fixtures/rust/src/lib.rs")
  local lsyms, client = request(buf, "rust")
  T.eq(client, "rust_analyzer", "rust client name")
  local ti = find(lsyms, function(s) return s.kind == "TraitImpl" and s.trait == "Default" end)
  T.ok(ti, "LSP-only: impl Default for MyStruct parsed as TraitImpl")
  T.eq(ti and ti.self_type, "MyStruct<i32>", "LSP-only: self type of Default impl")
  local gi = find(lsyms, function(s) return s.kind == "TraitImpl" and s.self_type == "MyStruct<T>" end)
  T.ok(gi and gi.trait == "Shape<T>", "LSP-only: generic trait impl keeps trait Shape<T> / self MyStruct<T>")
  local inh = find(lsyms, function(s) return s.kind == "Impl" end)
  T.ok(inh and inh.trait == nil and inh.self_type == "MyStruct<T>", "LSP-only: inherent impl has no trait")
  -- merged
  local ts = qzss.get_symbols(buf)
  local _, matched = lspb.merge(ts, lsyms, "merge")
  T.ok(matched >= 10, "rust merge matched " .. matched .. " symbols")
  local area = find(ts, function(s) return s.name == "area" and s.parent and s.parent.kind == "TraitImpl" end)
  T.ok(area and area.lsp_detail and area.lsp_detail ~= "", "rust: lsp detail attached to area (" .. tostring(area and area.lsp_detail) .. ")")
  T.eq(area and area.detail, "(&self) -> T", "rust: duplicate fn detail displayed once (syntax signature kept)")
  local lines = qzss.outline_lines(buf, ts)
  T.contains(lines, "impl<T> Shape<T> for MyStruct<T> where T: Copy + Display", "rust merged outline line")
  -- sidebar with real LSP reaches the merged state
  vim.cmd("QzssOpen!")
  local merged = vim.wait(60000, function()
    return qzss._state.bufs[buf].source == "treesitter+lsp"
  end, 100)
  T.ok(merged, "rust sidebar source becomes treesitter+lsp")
  -- LSP-only fallback when the Tree-sitter backend is unavailable
  require("qzss.config").options.backends = { "lsp" }
  vim.cmd("QzssRefresh")
  local fell_back = vim.wait(30000, function()
    return qzss._state.bufs[buf].source == "lsp"
  end, 100)
  T.ok(fell_back, "rust: LSP-only fallback renders")
  local sbuf = qzss._state.sidebars[vim.api.nvim_get_current_tabpage()].buf
  T.contains(vim.api.nvim_buf_get_lines(sbuf, 0, -1, false), "impl Default for MyStruct<i32>", "LSP-only sidebar shows impl Default for MyStruct<i32>")
  require("qzss.config").options.backends = { "treesitter", "lsp" }
  vim.cmd("QzssClose")
end

-- TypeScript / TSX via typescript-language-server -------------------------
for _, path in ipairs({ "tests/fixtures/ts/sample.ts", "tests/fixtures/ts/view.tsx" }) do
  local buf = open(path)
  local lsyms, client = request(buf, path)
  T.eq(client, "ts_ls", path .. " client name")
  local ts = qzss.get_symbols(buf)
  local _, matched = lspb.merge(ts, lsyms, "merge")
  T.ok(matched >= 4, path .. " merge matched " .. matched)
  -- the syntax backend keeps TypeAlias distinct even where LSP kinds collapse
  local alias = find(ts, function(s) return s.kind == "TypeAlias" end)
  local iface = find(ts, function(s) return s.kind == "Interface" end)
  local class = find(ts, function(s) return s.kind == "Class" end)
  T.ok(alias and iface and class, path .. ": TypeAlias/Interface/Class all present after merge")
  local lalias = find(lsyms, function(s) return alias and s.name == alias.name end)
  io.stdout:write(string.format("info LSP SymbolKind reported for type alias %s in %s: %s (qzss kind: TypeAlias)\n", alias and alias.name, path, lalias and lalias.lsp_kind))
end

-- LSP-only outline for TypeScript: tsserver reports a type alias as Variable,
-- enum members as Constant, in alphabetical order. qzss restores the kinds
-- from the syntax node at each name and the source order.
do
  local buf = open("tests/fixtures/ts/sample.ts")
  require("qzss.config").options.backends = { "lsp" }
  vim.cmd("QzssOpen!")
  local ok = vim.wait(30000, function()
    local st = qzss._state.bufs[buf]
    return st and st.source == "lsp" and #st.symbols > 0
  end, 100)
  T.ok(ok, "ts LSP-only outline renders")
  local syms = qzss._state.bufs[buf].symbols
  local function kind_of(name)
    local s = find(syms, function(x) return x.name == name end)
    return s and s.kind
  end
  local raw = find(request(buf, "ts raw"), function(x) return x.name == "Pair" end)
  io.stdout:write("info tsserver SymbolKind for Pair: " .. tostring(raw and raw.lsp_kind) .. "\n")
  T.eq(kind_of("Pair"), "TypeAlias", "ts LSP-only: type alias Pair shown as TypeAlias (not var)")
  T.eq(kind_of("Shape"), "Interface", "ts LSP-only: Shape is Interface")
  T.eq(kind_of("Box"), "Class", "ts LSP-only: Box is Class")
  T.eq(kind_of("Red"), "EnumMember", "ts LSP-only: enum member Red is EnumMember (not const)")
  local names = vim.tbl_map(function(s) return s.name end, syms)
  T.eq(names[1] .. "," .. names[2] .. "," .. names[3], "Shape,Pair,Box", "ts LSP-only: top-level symbols in source order")
  local sbuf = qzss._state.sidebars[vim.api.nvim_get_current_tabpage()].buf
  local lines = vim.api.nvim_buf_get_lines(sbuf, 0, -1, false)
  T.contains(lines, "≡ Pair", "ts LSP-only sidebar shows ≡ Pair")
  T.contains(lines, "· Red  variant", "ts LSP-only sidebar shows Red as variant")
  require("qzss.config").options.backends = { "treesitter", "lsp" }
  vim.cmd("QzssClose")
end

-- Public API with the real servers (no UI) ----------------------------------
do
  vim.cmd("silent! %bwipeout!")
  -- request before the server attached: Tree-sitter result first, then the
  -- LspAttach refresh of the (now tracked) buffer publishes the merged model
  vim.cmd("edit " .. root .. "/tests/fixtures/rust/src/lib.rs")
  local buf = vim.api.nvim_get_current_buf()
  local attached_at_request = lspb.available(buf)
  local first
  local sources = {}
  local sub = qzss.subscribe("symbols", function(ev)
    if ev.bufnr == buf then
      table.insert(sources, tostring(ev.source) .. (ev.pending and "(pending)" or ""))
    end
  end)
  qzss.request_symbols(buf, function(err, snap) first = { err, snap } end)
  vim.wait(60000, function() return first ~= nil end, 50)
  T.ok(first and first[1] == nil, "api: rust request resolved", first and first[1])
  if not attached_at_request then
    T.eq(first and first[2].source, "treesitter", "api: before LspAttach the request resolves with Tree-sitter symbols")
  end
  local merged = vim.wait(90000, function()
    local s = qzss.get_snapshot(buf)
    return s and s.source == "treesitter+lsp" and not s.pending
  end, 100)
  T.ok(merged, "api: rust-analyzer merge reaches the cache without UI (" .. table.concat(sources, ", ") .. ")")
  qzss.unsubscribe(sub)
  local snap = qzss.get_snapshot(buf)
  local area = find(snap.symbols, function(s) return s.name == "area" and s.parent_id and s.parent_id:find("TraitImpl", 1, true) end)
  T.ok(area and area.lsp_detail and area.lsp_kind == 6, "api: public symbol carries lsp_detail/lsp_kind from rust-analyzer", area and vim.inspect({ area.lsp_detail, area.lsp_kind }))
  T.eq(area and area.source, "treesitter+lsp", "api: matched symbol source = treesitter+lsp")
  T.eq(qzss.get_view(), nil, "api: no outline window was opened")
  -- request after an edit: the server is asked again and the result matches the new text
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "pub fn added_by_api_test() {}" })
  local second
  qzss.request_symbols(buf, function(err, s) second = { err, s } end)
  local pending_seen = qzss.get_snapshot(buf).pending
  vim.wait(60000, function() return second ~= nil end, 50)
  T.ok(pending_seen, "api: snapshot.pending while rust-analyzer answers")
  T.eq(second and second[2].changedtick, vim.b[buf].changedtick, "api: result for the edited changedtick")
  T.eq(second and second[2].symbols[1].name, "added_by_api_test", "api: new symbol present")
  T.eq(second and second[2].source, "treesitter+lsp", "api: merged with the real server after the edit")
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, {})
  vim.bo[buf].modified = false
end

-- wipe a TypeScript buffer while typescript-language-server is answering
do
  local buf = open("tests/fixtures/ts/sample.ts")
  require("qzss.config").options.backends = { "lsp" }
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "export const wipeMe = 1;" })
  local got
  qzss.request_symbols(buf, function(err, s) got = { err, s } end)
  T.ok(qzss.get_snapshot(buf) == nil or qzss.get_snapshot(buf).pending, "api: ts request in flight")
  vim.cmd("bwipeout! " .. buf)
  vim.wait(5000, function() return got ~= nil end, 20)
  T.ok(got and got[1] == "buffer deleted" and got[2] == nil, "api: wipe while tsserver answers -> 'buffer deleted'", got and got[1])
  vim.wait(1500)
  T.eq(qzss._state.bufs[buf], nil, "api: no model resurrected by the late tsserver answer")
  require("qzss.config").options.backends = { "treesitter", "lsp" }
end

T.finish()
