-- LSP DocumentSymbol backend and reconciliation with Tree-sitter symbols.
local M = {}

local SYMBOL_KIND = {
  [1] = "Document", [2] = "Module", [3] = "Module", [4] = "Module", [5] = "Class",
  [6] = "Method", [7] = "Property", [8] = "Field", [9] = "Constructor", [10] = "Enum",
  [11] = "Interface", [12] = "Function", [13] = "Variable", [14] = "Constant",
  [15] = "String", [16] = "Number", [17] = "Boolean", [18] = "Array", [19] = "Object",
  [20] = "String", [21] = "Null", [22] = "EnumMember", [23] = "Struct", [24] = "Variable",
  [25] = "Function", [26] = "TypeAlias",
}
M.SYMBOL_KIND = SYMBOL_KIND

local METHOD = "textDocument/documentSymbol"

function M.clients(bufnr)
  return vim.lsp.get_clients({ bufnr = bufnr, method = METHOD })
end

function M.available(bufnr)
  return #M.clients(bufnr) > 0
end

-- Parse `impl<T> Trait<T> for Type<T>` (rust-analyzer's naming) into parts.
-- Splits on the top-level " for " only, so `impl<F: Fn() -> X> ...` and
-- higher-ranked `for<'a>` bounds inside brackets do not confuse it.
function M.parse_rust_impl(name)
  local rest = name:match("^impl(.*)$")
  if not rest then
    return nil
  end
  local tp = ""
  if rest:sub(1, 1) == "<" then
    local depth = 0
    for i = 1, #rest do
      local c = rest:sub(i, i)
      if c == "<" then
        depth = depth + 1
      elseif c == ">" and rest:sub(i - 1, i - 1) ~= "-" then
        depth = depth - 1
        if depth == 0 then
          tp = rest:sub(1, i)
          rest = rest:sub(i + 1)
          break
        end
      end
    end
  end
  rest = vim.trim(rest)
  local depth = 0
  local i = 1
  while i <= #rest do
    local c = rest:sub(i, i)
    if c == "<" or c == "(" or c == "[" then
      depth = depth + 1
    elseif (c == ">" and rest:sub(i - 1, i - 1) ~= "-") or c == ")" or c == "]" then
      depth = depth - 1
    elseif depth == 0 and rest:sub(i, i + 4) == " for " then
      return { type_params = tp, trait = rest:sub(1, i - 1), self_type = vim.trim(rest:sub(i + 5)) }
    end
    i = i + 1
  end
  return { type_params = tp, self_type = rest }
end

-- Build a converter from LSP (line, character) positions to 0-based byte
-- columns. `character` is counted in the client's negotiated offset encoding
-- (UTF-16 by default), so it differs from the byte column as soon as a line
-- holds non-ASCII text before the symbol.
function M.position_converter(bufnr, encoding)
  encoding = encoding or "utf-16"
  if encoding == "utf-8" or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return function(_, character)
      return character
    end
  end
  local cache = {}
  return function(line, character)
    if character == 0 then
      return 0
    end
    local text = cache[line]
    if not text then
      text = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1] or ""
      cache[line] = text
    end
    local ok, col = pcall(vim.str_byteindex, text, encoding, character, false)
    if ok and col then
      return col
    end
    return math.min(character, #text)
  end
end

local function convert(items, ft, out, parent_kind, to_col)
  to_col = to_col or function(_, c)
    return c
  end
  for _, item in ipairs(items or {}) do
    local range = item.range or (item.location and item.location.range)
    local sel = item.selectionRange or range
    local kind = SYMBOL_KIND[item.kind] or "Variable"
    local s = {
      name = item.name,
      kind = kind,
      detail = item.detail or "",
      lsp_detail = item.detail,
      lsp_kind = item.kind,
      lnum = sel.start.line,
      col = to_col(sel.start.line, sel.start.character),
      range_lnum = range.start.line,
      range_col = to_col(range.start.line, range.start.character),
      range_end_lnum = range["end"].line,
      range_end_col = to_col(range["end"].line, range["end"].character),
      children = {},
      source = "lsp",
    }
    if ft == "rust" then
      local impl = M.parse_rust_impl(item.name)
      if impl and (item.kind == 19 or item.kind == 5 or item.name:match("^impl[%s<]")) then
        s.kind = impl.trait and "TraitImpl" or "Impl"
        s.trait = impl.trait
        s.self_type = impl.self_type
        s.type_params = impl.type_params
        s.segments = { { "impl" .. impl.type_params, "QzssKeyword" }, { " " } }
        if impl.trait then
          table.insert(s.segments, { impl.trait, "QzssTraitName" })
          table.insert(s.segments, { " for ", "QzssKeyword" })
        end
        table.insert(s.segments, { impl.self_type, "QzssSelfType" })
      elseif item.kind == 11 then
        s.kind = "Trait"
      elseif item.kind == 12 and (parent_kind == "Impl" or parent_kind == "TraitImpl" or parent_kind == "Trait") then
        s.kind = "Method"
      elseif item.kind == 26 and (parent_kind == "Impl" or parent_kind == "TraitImpl" or parent_kind == "Trait") then
        s.kind = "AssociatedType"
      end
    end
    if item.children then
      convert(item.children, ft, s.children, s.kind, to_col)
    end
    table.insert(out, s)
  end
  return out
end
M.convert = convert

-- Sort symbols (recursively) by source position. Some servers, e.g.
-- typescript-language-server, return DocumentSymbols alphabetically.
function M.sort(list)
  table.sort(list, function(a, b)
    local al, bl = a.range_lnum or a.lnum, b.range_lnum or b.lnum
    if al ~= bl then
      return al < bl
    end
    return (a.range_col or a.col or 0) < (b.range_col or b.col or 0)
  end)
  for _, s in ipairs(list) do
    M.sort(s.children)
  end
  return list
end

-- Syntax node types that pin down a semantic kind the LSP SymbolKind loses
-- (tsserver reports `type X = ...` as Variable and enum members as Constant).
local TS_KIND_BY_NODE = {
  type_alias_declaration = "TypeAlias",
  interface_declaration = "Interface",
  enum_assignment = "EnumMember",
  enum_body = "EnumMember", -- a bare `Red,` member's parent
}
local TS_LANG = { typescript = "typescript", typescriptreact = "tsx", ["typescript.tsx"] = "tsx" }

--- LSP-only outlines: when a Tree-sitter parser for the buffer happens to be
--- installed, use the syntax node at each symbol's name to correct kinds the
--- server collapses. Silently does nothing without a parser.
function M.refine_kinds(bufnr, syms)
  local lang = TS_LANG[vim.bo[bufnr].filetype]
  if not lang then
    return syms
  end
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang, { error = false })
  if not ok or not parser then
    return syms
  end
  local tree = parser:parse()[1]
  if not tree then
    return syms
  end
  local root = tree:root()
  local function walk(list)
    for _, s in ipairs(list) do
      local node = root:named_descendant_for_range(s.lnum, s.col, s.lnum, s.col)
      local hops = 0
      while node and hops < 3 do
        local t = node:type()
        local k = TS_KIND_BY_NODE[t]
        if k == "EnumMember" and t == "enum_body" and hops ~= 1 then
          k = nil -- only the direct parent of a member name counts
        end
        if k then
          s.kind = k
          break
        end
        if t:match("declaration$") or t == "variable_declarator" then
          break -- reached the symbol's own declaration: keep the server kind
        end
        node = node:parent()
        hops = hops + 1
      end
      walk(s.children)
    end
  end
  walk(syms)
  return syms
end

--- Request document symbols. cb(symbols|nil, err|nil, client_name)
function M.request(bufnr, cb, timeout_ms)
  local clients = M.clients(bufnr)
  if #clients == 0 then
    cb(nil, "no LSP client with documentSymbol support attached")
    return
  end
  local client = clients[1]
  local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
  local ft = vim.bo[bufnr].filetype
  local done = false
  local tick = vim.b[bufnr].changedtick
  local ok = client:request(METHOD, params, function(err, result)
    if done then
      return
    end
    done = true
    if err then
      cb(nil, "LSP " .. client.name .. ": " .. (err.message or vim.inspect(err)), client.name)
      return
    end
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    cb(convert(result or {}, ft, {}, nil, M.position_converter(bufnr, client.offset_encoding)), nil, client.name, tick)
  end, bufnr)
  if not ok then
    done = true
    cb(nil, "LSP request failed (" .. client.name .. ")", client.name)
    return
  end
  if timeout_ms then
    vim.defer_fn(function()
      if not done then
        done = true
        cb(nil, "LSP " .. client.name .. " timed out", client.name)
      end
    end, timeout_ms)
  end
end

---------------------------------------------------------------- merge

local function norm(s)
  s = (s or ""):gsub("^%s*fn%s*", ""):gsub("^%s*function%s*", ""):gsub("%s+", "")
  return s
end

-- Return the detail to display given syntax signature and LSP detail.
function M.combine_detail(ts_detail, lsp_detail, mode)
  ts_detail = ts_detail or ""
  lsp_detail = lsp_detail or ""
  if mode == "treesitter" then
    return ts_detail
  elseif mode == "lsp" then
    return lsp_detail ~= "" and lsp_detail or ts_detail
  end
  if ts_detail == "" then
    return lsp_detail
  end
  return ts_detail
end

local function base(name)
  return (name or ""):gsub("[%(<].*$", ""):gsub("!$", "")
end

-- Merge LSP info into Tree-sitter symbols, matching by name line and name.
-- Tree-sitter stays authoritative for structure; LSP detail is attached as
-- `lsp_detail` and used per `detail_source`. Duplicate/equal details are
-- displayed once.
function M.merge(ts_syms, lsp_syms, mode)
  local index = {}
  local function add(list)
    for _, s in ipairs(list) do
      index[s.lnum] = index[s.lnum] or {}
      table.insert(index[s.lnum], s)
      add(s.children)
    end
  end
  add(lsp_syms or {})
  local matched = 0
  local function walk(list)
    for _, s in ipairs(list) do
      local cands = index[s.lnum] or (s.range_lnum and index[s.range_lnum]) or {}
      local hit
      for _, c in ipairs(cands) do
        if c.name == s.name or base(c.name) == base(s.name) then
          hit = c
          break
        end
      end
      if not hit and #cands == 1 and (s.kind == "Impl" or s.kind == "TraitImpl") then
        hit = cands[1]
      end
      if hit then
        matched = matched + 1
        s.lsp_detail = hit.lsp_detail
        s.lsp_kind = hit.lsp_kind
        s.source = "treesitter+lsp"
        s.ts_detail = s.detail
        local lsp_d = hit.lsp_detail or ""
        if norm(lsp_d) == norm(s.detail) or norm(s.detail):find(norm(lsp_d), 1, true) then
          lsp_d = "" -- duplicate information
        end
        s.detail = M.combine_detail(s.detail, lsp_d, mode)
      end
      walk(s.children)
    end
  end
  walk(ts_syms)
  return ts_syms, matched
end

return M
