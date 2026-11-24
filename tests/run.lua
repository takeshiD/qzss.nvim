-- Headless unit/integration tests (Tree-sitter path, rendering, sidebar).
-- Run: nvim --clean --headless -l tests/run.lua
local root = vim.fn.getcwd()
package.path = root .. "/?.lua;" .. package.path
dofile(root .. "/tests/minimal_init.lua")
local T = require("tests.helpers")
local qzss = require("qzss")
local config = require("qzss.config")
local lspb = require("qzss.backends.lsp")
local api = vim.api

local function lines_of(path)
  vim.cmd("edit! " .. root .. "/" .. path)
  return qzss.outline_lines(0), api.nvim_get_current_buf()
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

---------------------------------------------------------------- parsers
for _, lang in ipairs({ "rust", "typescript", "tsx", "json", "yaml" }) do
  local ok, r = pcall(vim.treesitter.language.add, lang)
  T.ok(ok and r, "parser available: " .. lang)
end

---------------------------------------------------------------- R1/R2 Rust
do
  local lines, buf = lines_of("tests/fixtures/rust/src/lib.rs")
  T.contains(lines, "⊃ impl Default for MyStruct<i32>  impl trait", "rust: impl Default for MyStruct (trait first, self type after for)")
  T.contains(lines, "impl<T> Shape<T> for MyStruct<T> where T: Copy + Display  impl trait", "rust: generic trait impl + where clause")
  T.contains(lines, "⊂ impl<T: Clone> MyStruct<T>  impl", "rust: inherent impl with bounds")
  for _, l in ipairs(lines) do
    T.ok(not l:find("MyStruct for Default", 1, true) and not l:find("impl MyStruct<i32> for", 1, true), "rust: never reversed order: " .. l)
  end
  T.contains(lines, "      ƒ helper<U: Copy>(u: U) -> U  fn", "rust: nested fn inside method shown at depth 3")
  T.contains(lines, "ⓜ map<U, F>(self, f: F) -> MyStruct<U> where F: FnOnce(T) -> U  method", "rust: method generics + where")
  T.contains(lines, "≔ Output = T  assoc type", "rust: associated type in impl")
  T.contains(lines, "π SIDES: usize  const", "rust: associated const")
  T.contains(lines, "ƒ largest<T: PartialOrd + Copy>(items: &[T]) -> T  fn", "rust: generic fn bounds")
  T.contains(lines, "◆ MyStruct<T>  struct", "rust: generic struct")
  T.contains(lines, "◈ Shape<T>  trait", "rust: generic trait")
  local syms = qzss.get_symbols(buf)
  local gi = find(syms, function(s) return s.kind == "TraitImpl" and s.self_type == "MyStruct<T>" end)
  T.eq(gi and gi.trait, "Shape<T>", "rust: symbol.trait field")
  T.eq(gi and gi.where_clause, "where T: Copy + Display", "rust: symbol.where_clause field")
  T.eq(gi and gi.lnum, 24, "rust: impl jump target row (0-based)")
end

-- parse_rust_impl (LSP name parsing, used when only LSP is available)
do
  local p = lspb.parse_rust_impl("impl Default for MyStruct")
  T.ok(p.trait == "Default" and p.self_type == "MyStruct", "lsp name parse: impl Default for MyStruct")
  p = lspb.parse_rust_impl("impl<T> Trait<T> for MyStruct<T>")
  T.ok(p.type_params == "<T>" and p.trait == "Trait<T>" and p.self_type == "MyStruct<T>", "lsp name parse: generic trait impl")
  p = lspb.parse_rust_impl("impl<F: Fn() -> u8> Wrap<F>")
  T.ok(p.trait == nil and p.self_type == "Wrap<F>" and p.type_params == "<F: Fn() -> u8>", "lsp name parse: inherent with arrow in bound")
  p = lspb.parse_rust_impl("impl Into<Box<dyn for<'a> Fn(&'a u8)>> for X")
  T.ok(p.trait == "Into<Box<dyn for<'a> Fn(&'a u8)>>" and p.self_type == "X", "lsp name parse: nested for<'a> inside trait args")
end

-- merge/duplicate handling with synthetic DocumentSymbol shaped like rust-analyzer
do
  vim.cmd("edit! " .. root .. "/tests/fixtures/rust/src/lib.rs")
  local syms = qzss.get_symbols(0)
  local lsyms = lspb.convert({
    { name = "largest", kind = 12, detail = "fn<T: PartialOrd + Copy>(items: &[T]) -> T",
      range = { start = { line = 52, character = 0 }, ["end"] = { line = 54, character = 1 } },
      selectionRange = { start = { line = 52, character = 7 }, ["end"] = { line = 52, character = 14 } } },
    { name = "LIMIT", kind = 14, detail = "u32 = 10",
      range = { start = { line = 57, character = 4 }, ["end"] = { line = 57, character = 26 } },
      selectionRange = { start = { line = 57, character = 14 }, ["end"] = { line = 57, character = 19 } } },
  }, "rust", {})
  local _, matched = lspb.merge(syms, lsyms, "merge")
  T.eq(matched, 2, "merge: matched by line + name")
  local largest = find(syms, function(s) return s.name == "largest" end)
  T.eq(largest.detail, "<T: PartialOrd + Copy>(items: &[T]) -> T", "merge: equal detail not duplicated")
  T.eq(largest.lsp_detail, "fn<T: PartialOrd + Copy>(items: &[T]) -> T", "merge: lsp_detail kept for callbacks")
  local limit = find(syms, function(s) return s.name == "LIMIT" end)
  T.eq(limit.detail, ": u32", "merge: syntax signature preferred in merge mode")
  T.eq(lspb.combine_detail(": u32", "u32 = 10", "lsp"), "u32 = 10", "detail_source=lsp prefers LSP detail")
  T.eq(lspb.combine_detail("", "u32 = 10", "merge"), "u32 = 10", "merge falls back to LSP detail when syntax is empty")
end

---------------------------------------------------------------- R2/R3 TypeScript & TSX
do
  local lines = lines_of("tests/fixtures/ts/sample.ts")
  T.contains(lines, "ⓘ Shape<T extends number = number>  interface", "ts: interface generics with constraint+default")
  T.contains(lines, "≡ Pair<K, V> = { key: K; value: V }  type", "ts: type alias kind distinct")
  T.contains(lines, "© Box<T> implements Shape<number>  class", "ts: class with heritage")
  T.contains(lines, "ⓜ map<U>(fn: (v: T) => U): Box<U>  method", "ts: generic method")
  T.contains(lines, "ƒ identity<T>(value: T): T  fn", "ts: generic function")
  T.contains(lines, "ƒ arrow<T,>(v: T): T  fn", "ts: generic arrow const")
  local tlines = lines_of("tests/fixtures/ts/view.tsx")
  T.contains(tlines, "ⓘ Props  interface", "tsx: interface")
  T.contains(tlines, "≡ Variant = \"primary\" | \"secondary\"  type", "tsx: type alias")
  T.contains(tlines, "© Panel extends React.Component<Props>  class", "tsx: class")
  T.contains(tlines, "ƒ Button<T>({ title }: Props & { data?: T })  fn", "tsx: generic component")
  -- filters
  qzss.set_filter({ "Interface" })
  local f = qzss.outline_lines(0)
  T.ok(#f == 1 and f[1]:find("Props", 1, true), "tsx: filter Interface shows only interface (other kinds hidden)", table.concat(f, "|"))
  qzss.set_filter({ "TypeAlias" })
  f = qzss.outline_lines(0)
  T.ok(#f == 1 and f[1]:find("Variant", 1, true), "tsx: filter TypeAlias shows only alias", table.concat(f, "|"))
  T.eq(qzss.set_filter({ "Bogus" }), false, "filter: unknown kind rejected")
  qzss.set_filter({})
  T.eq(#qzss.outline_lines(0), 6, "filter cleared")
end

---------------------------------------------------------------- R4 JSON / YAML (no LSP)
do
  local lines, buf = lines_of("tests/fixtures/sample.json")
  T.eq(#vim.lsp.get_clients({ bufnr = buf }), 0, "json: no LSP attached")
  T.contains(lines, "▾ {} nested {2}  object", "json: object with count")
  T.contains(lines, "  ▾ {} \"deep key\" {2}  object", "json: nested quoted key keeps quotes")
  T.contains(lines, "      ◐ enabled: true  bool", "json: boolean scalar nested")
  T.contains(lines, "  ▾ [] list [3]  array", "json: array")
  T.contains(lines, "      \" [1]: \"two\"  string", "json: array index")
  T.contains(lines, "    ▾ {} [2] {1}  object", "json: object inside array")
  T.contains(lines, "        ∅ three: null  null", "json: null")
  T.contains(lines, "\"with \\\"quotes\\\"\": \"yes\"", "json: escaped quoted key")
  local ylines = lines_of("tests/fixtures/sample.yaml")
  T.contains(ylines, "  ▾ {} \"deep key\" {2}  object", "yaml: quoted nested key")
  T.contains(ylines, "  \" 'quoted key': yes  string", "yaml: single-quoted key")
  T.contains(ylines, "    ▾ {} [2] {1}  object", "yaml: map in sequence")
  T.contains(ylines, "  ▾ [] b [2]  array", "yaml: flow sequence")
  T.contains(ylines, "      # ratio: 0.5  number", "yaml: float scalar")
end

---------------------------------------------------------------- R6 customization
do
  config.setup({
    icons = "ascii",
    kind_labels = { TraitImpl = "trait-impl" },
    format_name = function(sym)
      if sym.kind == "TraitImpl" then
        return sym.trait .. " => " .. sym.self_type
      end
    end,
    format_detail = function(sym)
      if sym.kind == "Method" then
        return ""
      end
    end,
  })
  local lines = lines_of("tests/fixtures/rust/src/lib.rs")
  T.contains(lines, "- I Default => MyStruct<i32>  trait-impl", "custom: ascii icon + format_name + kind label")
  T.contains(lines, "    m new  method", "custom: format_detail hides method detail")
  config.setup({ show_kind = false, icons = { Struct = "S>" } })
  lines = lines_of("tests/fixtures/rust/src/lib.rs")
  T.contains(lines, "▾ S> MyStruct<T>", "custom: icon table override")
  T.ok(not table.concat(lines, "\n"):find("  struct", 1, true), "custom: show_kind=false hides labels")
  config.setup({ get_icon = function(sym) return sym.kind:sub(1, 2), "ErrorMsg" end, filter = function(sym) return sym.kind ~= "Field" end })
  lines = lines_of("tests/fixtures/rust/src/lib.rs")
  T.contains(lines, "  St MyStruct<T>  struct", "custom: get_icon callback (fields filtered, so leaf)")
  T.ok(not table.concat(lines, "\n"):find("Fi value", 1, true), "custom: filter callback hides fields")
  config.setup({})
  require("qzss.kinds").setup_highlights({ Class = { fg = "#ff0000" } })
  T.eq(api.nvim_get_hl(0, { name = "QzssClass" }).fg, 0xff0000, "custom: highlight override")
  T.ok(api.nvim_get_hl(0, { name = "QzssInterface", link = true }).link ~= api.nvim_get_hl(0, { name = "QzssTypeAlias", link = true }).link, "hl: Interface and TypeAlias link to different groups")
  require("qzss.kinds").setup_highlights({})
end

---------------------------------------------------------------- R5/R7 sidebar behaviour
do
  vim.cmd("only | edit! " .. root .. "/tests/fixtures/rust/src/lib.rs")
  local src_win = api.nvim_get_current_win()
  vim.cmd("QzssOpen")
  local sb = qzss._state.sidebars[api.nvim_get_current_tabpage()]
  T.ok(sb and api.nvim_get_current_win() == sb.win, "sidebar opened and focused")
  T.eq(vim.bo[sb.buf].filetype, "qzss", "sidebar filetype")
  local function sl()
    return api.nvim_buf_get_lines(sb.buf, 0, -1, false)
  end
  local function goto_text(t)
    for i, l in ipairs(sl()) do
      if l:find(t, 1, true) then
        api.nvim_win_set_cursor(sb.win, { i, 0 })
        return i
      end
    end
  end
  -- jump
  goto_text("impl Default for MyStruct<i32>")
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  T.eq(api.nvim_get_current_win(), src_win, "jump focuses source")
  T.eq(api.nvim_win_get_cursor(src_win)[1], 19, "jump to impl Default line")
  api.nvim_set_current_win(sb.win)
  goto_text("helper<U")
  vim.api.nvim_feedkeys("p", "x", false)
  T.eq(api.nvim_get_current_win(), sb.win, "preview keeps sidebar focus")
  T.same(api.nvim_win_get_cursor(src_win), { 33, 11 }, "preview jumps to exact name column of nested fn")
  -- fold keeps kind/icon/name
  goto_text("impl<T> Shape<T> for MyStruct<T>")
  vim.api.nvim_feedkeys("za", "x", false)
  T.contains(sl(), "▸ ⊃ impl<T> Shape<T> for MyStruct<T> [+4] where T: Copy + Display  impl trait", "folded row keeps marker/icon/name/kind + count")
  T.ok(not table.concat(sl(), "\n"):find("helper", 1, true), "folded children hidden")
  -- edit update keeps fold & selection
  local sel_before = sl()[api.nvim_win_get_cursor(sb.win)[1]]
  api.nvim_buf_set_lines(sb.src, 0, 0, false, { "pub struct Added;", "" })
  api.nvim_exec_autocmds("TextChanged", { buffer = sb.src })
  vim.wait(1000, function()
    return table.concat(sl(), "\n"):find("Added", 1, true) ~= nil
  end)
  T.contains(sl(), "Added", "edit refresh shows new struct")
  T.contains(sl(), "▸ ⊃ impl<T> Shape<T> for MyStruct<T>", "fold state preserved after edit")
  T.eq(sl()[api.nvim_win_get_cursor(sb.win)[1]], sel_before, "selection preserved after edit")
  -- close parent from child with h
  vim.api.nvim_feedkeys("zR", "x", false)
  goto_text("ⓜ new(value: T)")
  vim.api.nvim_feedkeys("h", "x", false)
  T.ok(sl()[api.nvim_win_get_cursor(sb.win)[1]]:find("▸ ⊂ impl<T: Clone> MyStruct<T>", 1, true), "h on child folds parent and selects it")
  vim.api.nvim_feedkeys("zM", "x", false)
  T.eq(#sl(), 9, "zM collapses all top-level containers (8 + inserted struct)")
  vim.api.nvim_feedkeys("zR", "x", false)
  -- follow cursor
  api.nvim_set_current_win(src_win)
  api.nvim_win_set_cursor(src_win, { 50, 4 })
  vim.cmd("doautocmd CursorMoved")
  T.ok(sl()[api.nvim_win_get_cursor(sb.win)[1]]:find("map<U, F>", 1, true), "sidebar follows source cursor")
  -- undo the edit
  api.nvim_buf_set_lines(sb.src, 0, 2, false, {})
  api.nvim_exec_autocmds("TextChanged", { buffer = sb.src })
  vim.wait(1000, function()
    return not table.concat(sl(), "\n"):find("Added", 1, true)
  end)
  -- switch source buffer retargets
  vim.cmd("edit " .. root .. "/tests/fixtures/sample.yaml")
  T.contains(sl(), "▾ {} nested {2}  object", "sidebar retargets to new buffer")
  T.ok(vim.wo[sb.win].winbar:find("sample.yaml", 1, true), "winbar shows source file")
  -- unsupported filetype w/o LSP: message instead of error
  vim.cmd("enew")
  vim.bo.filetype = "text"
  vim.cmd("write! " .. vim.fn.tempname() .. ".txt")
  vim.cmd("doautocmd BufEnter")
  vim.wait(500)
  T.ok(sl()[1]:find("qzss: no Tree-sitter extractor for filetype 'text'", 1, true), "fallback message for unsupported filetype", sl()[1])
  -- missing parser handled (python has no parser here) without throwing
  local ok = pcall(function()
    vim.bo.filetype = "rust"
    local saved = vim.treesitter.language.add
    vim.treesitter.language.add = function() return nil, "no parser" end
    qzss.refresh()
    vim.treesitter.language.add = saved
  end)
  T.ok(ok, "refresh never throws")
  -- help window
  api.nvim_set_current_win(sb.win)
  vim.api.nvim_feedkeys("?", "x", false)
  local hb = api.nvim_get_current_buf()
  T.ok(api.nvim_buf_get_lines(hb, 0, 1, false)[1]:find("qzss keys", 1, true), "? opens help")
  vim.api.nvim_feedkeys("q", "x", false)
  vim.cmd("Qzss")
  T.eq(qzss.is_open(), false, ":Qzss toggles closed")
end

---------------------------------------------------------------- :edit from inside the sidebar
do
  vim.cmd("silent! %bwipeout!")
  vim.cmd("edit! " .. root .. "/tests/fixtures/ts/sample.ts")
  local src_win = api.nvim_get_current_win()
  qzss.open()
  local sb = qzss._state.sidebars[api.nvim_get_current_tabpage()]
  T.eq(api.nvim_get_current_win(), sb.win, "sidebar focused before :edit")
  local ok, err = pcall(vim.cmd, "edit " .. root .. "/tests/fixtures/ts/view.tsx")
  T.ok(ok, ":edit inside the sidebar does not raise", err)
  vim.wait(500, function() return qzss.is_open() end)
  local nsb = qzss._state.sidebars[api.nvim_get_current_tabpage()]
  T.ok(nsb and api.nvim_buf_is_valid(nsb.buf) and vim.bo[nsb.buf].filetype == "qzss", "sidebar rebuilt after :edit inside it")
  T.eq(api.nvim_win_get_buf(src_win), vim.fn.bufnr("view.tsx"), "file opened in the source window")
  T.eq(api.nvim_get_current_win(), src_win, "focus moves to the source window")
  local lines = nsb and api.nvim_buf_get_lines(nsb.buf, 0, -1, false) or {}
  T.contains(lines, "© Panel extends React.Component<Props>  class", "outline now shows the new file")
  T.eq(#api.nvim_tabpage_list_wins(0), 2, "still exactly source + sidebar windows")
  qzss.close()
end

---------------------------------------------------------------- sidebar width & lifecycle
do
  local cols = vim.o.columns
  vim.o.columns = 50
  T.eq(qzss._fit_width(36), 25, "50 columns: sidebar capped at half (source keeps 25)")
  vim.o.columns = 70
  T.eq(qzss._fit_width(36), 36, "70 columns: default width kept (source keeps 34)")
  vim.o.columns = 165
  T.eq(qzss._fit_width(86), 86, "wide terminal: configured width untouched")
  vim.o.columns = cols
  -- :q in the last source window of a second tab closes the tab, not leaving an orphan sidebar
  vim.cmd("silent! %bwipeout!")
  vim.cmd("edit! " .. root .. "/tests/fixtures/sample.json")
  vim.cmd("tabnew " .. root .. "/tests/fixtures/sample.yaml")
  qzss.open({ focus = false })
  T.eq(#api.nvim_tabpage_list_wins(0), 2, "tab 2 has source + sidebar")
  vim.cmd("quit")
  vim.wait(300)
  T.eq(#api.nvim_list_tabpages(), 1, ":q in tab 2's source closes the whole tab (sidebar auto-closed)")
  T.eq(vim.fn.expand("%:t"), "sample.json", "back in tab 1")
  -- :close of the source (not a quit) also must not leave the sidebar alone in a tab
  vim.cmd("tabnew " .. root .. "/tests/fixtures/sample.yaml")
  qzss.open({ focus = false })
  vim.cmd("close")
  vim.wait(300, function() return #api.nvim_list_tabpages() == 1 end)
  T.eq(#api.nvim_list_tabpages(), 1, ":close of the source closes the orphaned sidebar's tab")
end

---------------------------------------------------------------- literal whitespace
do
  local tsb = require("qzss.backends.treesitter")
  local sq = tsb._squash
  T.eq(sq('"a  b"\n  | "a b"', "typescript"), '"a  b" | "a b"', "squash keeps spaces inside \"…\" and collapses outside")
  T.eq(sq("'x  y'   |\t`p  q`", "typescript"), "'x  y' | `p  q`", "squash keeps spaces inside '…' and `…`")
  T.eq(sq("`line1\n  line2`", "typescript"), "`line1\\n  line2`", "squash shows newline inside a literal as \\n (single row)")
  T.eq(sq("fn f<'a>(x: &'a   str,\n   y: &'a str)", "rust"), "fn f<'a>(x: &'a str, y: &'a str)", "squash: Rust lifetimes are not string quotes")
  T.eq(sq('"esc \\"  q"   x', "json"), '"esc \\"  q" x', "squash handles escaped quotes")
  local function parse(ft, text)
    local b = api.nvim_create_buf(false, true)
    vim.bo[b].filetype = ft
    api.nvim_buf_set_lines(b, 0, -1, false, vim.split(text, "\n"))
    local s = qzss.get_symbols(b)
    api.nvim_buf_delete(b, { force = true })
    return s
  end
  local y = parse("yaml", "'single  q': 1\n\"two  spaces\": 2\n\"two spaces\": 3")
  T.eq(y[1].name, "'single  q'", "yaml single-quoted key keeps inner spaces")
  T.ok(y[2].name ~= y[3].name, "yaml: distinct quoted keys stay distinct")
  local yp = parse("yaml", "two  spaces: a  b\nk: first  line\n  second   part\n")
  T.eq(yp[1].name, "two  spaces", "yaml plain key keeps interior spaces")
  T.eq(yp[1].detail, "a  b", "yaml plain scalar keeps interior spaces")
  T.eq(yp[2].detail, "first  line second   part", "yaml multi-line plain scalar: line break folded, interior spaces kept")
  local t = parse("typescript", "type Multi =\n  | \"a  b\"\n  | \"a b\";")
  T.eq(t[1].detail, ' = | "a  b" | "a b"', "ts multi-line union collapses layout but keeps literal spaces")
  local j = parse("json", '{"k  k": "v  v", "n": [ "x  y" ]}')
  T.eq(j[1].name, '"k  k"', "json quoted key keeps inner spaces")
  T.eq(j[1].detail, '"v  v"', "json string preview keeps inner spaces")
  T.eq(j[2].children[1].detail, '"x  y"', "json array string preview keeps inner spaces")
end

---------------------------------------------------------------- kind label highlight
do
  local function hl(name)
    return api.nvim_get_hl(0, { name = name, link = false })
  end
  qzss.setup({})
  T.eq(hl("QzssKindLabel").fg, hl("Comment").fg, "kind label uses the theme's Comment color by default")
  T.ok(hl("QzssKindLabel").fg ~= hl("NonText").fg, "kind label is not the low-contrast NonText")
  T.eq(hl("QzssKindLabel").italic, true, "kind label italic to separate it from detail")
  vim.cmd("colorscheme habamax")
  T.eq(hl("QzssKindLabel").fg, hl("Comment").fg, "kind label follows a :colorscheme change")
  qzss.setup({ highlights = { KindLabel = { fg = "#ff00ff" } } })
  T.eq(hl("QzssKindLabel").fg, 0xff00ff, "user highlight override for KindLabel wins")
  vim.cmd("colorscheme default")
  T.eq(hl("QzssKindLabel").fg, 0xff00ff, "user override survives :colorscheme")
  qzss.setup({})
end

---------------------------------------------------------------- LSP position encodings
do
  local b = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(b, 0, -1, false, { "const text = 'あ😀'; function target() {}" })
  local line = api.nvim_buf_get_lines(b, 0, 1, false)[1]
  local want = line:find("target", 1, true) - 1
  -- character offsets the server would send in each encoding
  local u16 = vim.str_utfindex(line, "utf-16", want)
  local u32 = vim.str_utfindex(line, "utf-32", want)
  T.ok(u16 ~= want and u32 ~= want, "fixture really has multibyte prefix", vim.inspect({ want, u16, u32 }))
  T.eq(lspb.position_converter(b, "utf-16")(0, u16), want, "utf-16 character -> byte column")
  T.eq(lspb.position_converter(b, "utf-32")(0, u32), want, "utf-32 character -> byte column")
  T.eq(lspb.position_converter(b, "utf-8")(0, want), want, "utf-8 character is already a byte column")
  local syms = lspb.convert({
    { name = "target", kind = 12, detail = "",
      range = { start = { line = 0, character = u16 - 9 }, ["end"] = { line = 0, character = u16 + 11 } },
      selectionRange = { start = { line = 0, character = u16 }, ["end"] = { line = 0, character = u16 + 6 } } },
  }, "typescript", {}, nil, lspb.position_converter(b, "utf-16"))
  T.eq(syms[1].col, want, "convert() applies the client encoding to selection columns")
  T.eq(lspb.position_converter(b, "utf-16")(0, 999), #line, "out-of-range character clamps to line end")
  api.nvim_buf_delete(b, { force = true })
end

T.finish()
