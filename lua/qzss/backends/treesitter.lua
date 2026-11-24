-- Tree-sitter outline extraction for Rust, TypeScript/TSX, JSON and YAML.
-- Every symbol is a plain table:
--   { name, kind, detail, lnum, col, end_lnum, end_col, children,
--     segments?, trait?, self_type?, where_clause?, type_params? }
-- lnum/col are 0-based and point at the symbol's name (selection range);
-- range_lnum/range_end_lnum cover the whole declaration.
local M = {}

local LANG_BY_FT = {
  rust = "rust",
  typescript = "typescript",
  typescriptreact = "tsx",
  ["typescript.tsx"] = "tsx",
  json = "json",
  jsonc = "json",
  yaml = "yaml",
}

function M.lang_for(ft)
  return LANG_BY_FT[ft]
end

-- Collapse formatting whitespace (indentation, line breaks) to single spaces
-- while leaving the contents of string literals untouched: `"a  b"` and
-- `"a b"` are different values and must stay distinguishable. A line break
-- inside a literal is shown as `\n` because a sidebar row is a single line.
-- `'` only opens a literal outside Rust, where it also starts lifetimes.
local function squash(s, lang)
  if not s then
    return ""
  end
  if lang == "yaml" then
    -- YAML keys and scalars are content: interior spaces are significant even
    -- in plain (unquoted) scalars. Only fold line breaks (with the
    -- indentation around them) into one space, as YAML line folding does.
    s = s:gsub("[ \t]*\r?\n[ \t\r\n]*", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return s
  end
  local quotes = lang == "rust" and { ['"'] = true } or { ['"'] = true, ["'"] = true, ["`"] = true }
  local out, n, i = {}, #s, 1
  while i <= n do
    local c = s:sub(i, i)
    if quotes[c] then
      local j = i + 1
      while j <= n do
        local d = s:sub(j, j)
        if d == "\\" then
          j = j + 1
        elseif d == c then
          break
        end
        j = j + 1
      end
      local lit = s:sub(i, j):gsub("\r?\n", "\\n")
      out[#out + 1] = lit
      i = j + 1
    elseif c:match("%s") then
      while i <= n and s:sub(i, i):match("%s") do
        i = i + 1
      end
      out[#out + 1] = " "
    else
      local j = i
      while j <= n do
        local d = s:sub(j, j)
        if quotes[d] or d:match("%s") then
          break
        end
        j = j + 1
      end
      out[#out + 1] = s:sub(i, j - 1)
      i = j
    end
  end
  s = table.concat(out):gsub("^ ", ""):gsub(" $", "")
  return s
end
M._squash = squash

local function make(src, node, kind, name, name_node)
  local sr, sc, er, ec = node:range()
  local nr, nc = sr, sc
  if name_node then
    nr, nc = name_node:range()
  end
  return {
    name = name,
    kind = kind,
    detail = "",
    lnum = nr,
    col = nc,
    range_lnum = sr,
    range_col = sc,
    range_end_lnum = er,
    range_end_col = ec,
    children = {},
  }
end

local function field(node, name)
  local f = node:field(name)
  return f and f[1] or nil
end

---------------------------------------------------------------- Rust
local rust = {}

local function rtext(ctx, node)
  return node and squash(vim.treesitter.get_node_text(node, ctx.src), ctx.lang) or ""
end

local function rust_where(ctx, node)
  for child in node:iter_children() do
    if child:type() == "where_clause" then
      local w = rtext(ctx, child):gsub(",$", "")
      return w
    end
  end
  return nil
end

local function rust_fn_detail(ctx, node)
  local d = rtext(ctx, field(node, "type_parameters")) .. rtext(ctx, field(node, "parameters"))
  local ret = field(node, "return_type")
  if ret then
    d = d .. " -> " .. rtext(ctx, ret)
  end
  local w = rust_where(ctx, node)
  if w then
    d = d .. " " .. w
  end
  return d
end

local function rust_collect(ctx, node, scope, out) -- forward
  return rust.collect(ctx, node, scope, out)
end

rust.handlers = {
  function_item = function(ctx, node, scope)
    local name = field(node, "name")
    local kind = (scope == "impl" or scope == "trait") and "Method" or "Function"
    local s = make(ctx.src, node, kind, rtext(ctx, name), name)
    s.detail = rust_fn_detail(ctx, node)
    s.type_params = rtext(ctx, field(node, "type_parameters"))
    local body = field(node, "body")
    if body then
      rust_collect(ctx, body, "fn", s.children)
    end
    return s
  end,
  struct_item = function(ctx, node)
    local name = field(node, "name")
    local s = make(ctx.src, node, "Struct", rtext(ctx, name), name)
    local w = rust_where(ctx, node)
    s.detail = rtext(ctx, field(node, "type_parameters")) .. (w and (" " .. w) or "")
    local body = field(node, "body")
    if body and body:type() == "field_declaration_list" then
      for f in body:iter_children() do
        if f:type() == "field_declaration" then
          local fname = field(f, "name")
          local fs = make(ctx.src, f, "Field", rtext(ctx, fname), fname)
          fs.detail = ": " .. rtext(ctx, field(f, "type"))
          table.insert(s.children, fs)
        end
      end
    elseif body then
      s.detail = s.detail .. rtext(ctx, body)
    end
    return s
  end,
  union_item = function(ctx, node)
    local name = field(node, "name")
    local s = make(ctx.src, node, "Struct", rtext(ctx, name), name)
    s.detail = rtext(ctx, field(node, "type_parameters"))
    return s
  end,
  enum_item = function(ctx, node)
    local name = field(node, "name")
    local s = make(ctx.src, node, "Enum", rtext(ctx, name), name)
    local w = rust_where(ctx, node)
    s.detail = rtext(ctx, field(node, "type_parameters")) .. (w and (" " .. w) or "")
    local body = field(node, "body")
    if body then
      for v in body:iter_children() do
        if v:type() == "enum_variant" then
          local vname = field(v, "name")
          local vs = make(ctx.src, v, "EnumMember", rtext(ctx, vname), vname)
          local vb = field(v, "body")
          vs.detail = vb and rtext(ctx, vb) or ""
          table.insert(s.children, vs)
        end
      end
    end
    return s
  end,
  trait_item = function(ctx, node)
    local name = field(node, "name")
    local s = make(ctx.src, node, "Trait", rtext(ctx, name), name)
    local d = rtext(ctx, field(node, "type_parameters"))
    local bounds = field(node, "bounds")
    if bounds then
      d = d .. rtext(ctx, bounds)
    end
    local w = rust_where(ctx, node)
    s.detail = d .. (w and (" " .. w) or "")
    s.type_params = rtext(ctx, field(node, "type_parameters"))
    local body = field(node, "body")
    if body then
      rust_collect(ctx, body, "trait", s.children)
    end
    return s
  end,
  impl_item = function(ctx, node)
    local trait = field(node, "trait")
    local self_type = field(node, "type")
    local tp = rtext(ctx, field(node, "type_parameters"))
    local trait_s = trait and rtext(ctx, trait) or nil
    -- negative impls: `impl !Send for T`
    if trait then
      local prev = trait:prev_sibling()
      if prev and vim.treesitter.get_node_text(prev, ctx.src) == "!" then
        trait_s = "!" .. trait_s
      end
    end
    local self_s = rtext(ctx, self_type)
    local s = make(ctx.src, node, trait and "TraitImpl" or "Impl", "", node)
    s.segments = { { "impl" .. tp, "QzssKeyword" }, { " " } }
    if trait_s then
      s.name = string.format("impl%s %s for %s", tp, trait_s, self_s)
      table.insert(s.segments, { trait_s, "QzssTraitName" })
      table.insert(s.segments, { " for ", "QzssKeyword" })
    else
      s.name = string.format("impl%s %s", tp, self_s)
    end
    table.insert(s.segments, { self_s, "QzssSelfType" })
    s.trait = trait_s
    s.self_type = self_s
    s.type_params = tp
    s.where_clause = rust_where(ctx, node)
    s.detail = s.where_clause or ""
    local body = field(node, "body")
    if body then
      rust_collect(ctx, body, "impl", s.children)
    end
    return s
  end,
  const_item = function(ctx, node)
    local name = field(node, "name")
    local s = make(ctx.src, node, "Constant", rtext(ctx, name), name)
    s.detail = ": " .. rtext(ctx, field(node, "type"))
    return s
  end,
  static_item = function(ctx, node)
    local name = field(node, "name")
    local s = make(ctx.src, node, "Constant", rtext(ctx, name), name)
    s.detail = ": " .. rtext(ctx, field(node, "type"))
    return s
  end,
  type_item = function(ctx, node, scope)
    local name = field(node, "name")
    local kind = (scope == "impl" or scope == "trait") and "AssociatedType" or "TypeAlias"
    local s = make(ctx.src, node, kind, rtext(ctx, name), name)
    s.detail = rtext(ctx, field(node, "type_parameters")) .. " = " .. rtext(ctx, field(node, "type"))
    return s
  end,
  associated_type = function(ctx, node)
    local name = field(node, "name")
    local s = make(ctx.src, node, "AssociatedType", rtext(ctx, name), name)
    local bounds = field(node, "bounds")
    s.detail = rtext(ctx, field(node, "type_parameters")) .. (bounds and rtext(ctx, bounds) or "")
    return s
  end,
  mod_item = function(ctx, node)
    local name = field(node, "name")
    local s = make(ctx.src, node, "Module", rtext(ctx, name), name)
    local body = field(node, "body")
    if body then
      rust_collect(ctx, body, "mod", s.children)
    end
    return s
  end,
  macro_definition = function(ctx, node)
    local name = field(node, "name")
    return make(ctx.src, node, "Macro", rtext(ctx, name) .. "!", name)
  end,
}
rust.handlers.function_signature_item = rust.handlers.function_item

function rust.collect(ctx, node, scope, out)
  for child in node:iter_children() do
    if child:named() then
      local h = rust.handlers[child:type()]
      if h then
        local ok, sym = pcall(h, ctx, child, scope)
        if ok and sym and sym.name ~= "" then
          table.insert(out, sym)
        end
      elseif scope == "fn" or child:type() == "declaration_list" then
        -- look for items nested in blocks / statements
        rust.collect(ctx, child, scope, out)
      end
    end
  end
  return out
end

---------------------------------------------------------------- TypeScript / TSX
local ts = {}

local function tfn_detail(ctx, node)
  local d = rtext(ctx, field(node, "type_parameters")) .. rtext(ctx, field(node, "parameters"))
  local ret = field(node, "return_type")
  if ret then
    d = d .. rtext(ctx, ret)
  end
  return d
end

local function ts_heritage(ctx, node)
  local parts = {}
  for child in node:iter_children() do
    local t = child:type()
    if t == "class_heritage" or t == "extends_type_clause" or t == "extends_clause" then
      table.insert(parts, rtext(ctx, child))
    end
  end
  return table.concat(parts, " ")
end

local function ts_members(ctx, body, out)
  for m in body:iter_children() do
    local t = m:type()
    if t == "method_definition" or t == "method_signature" or t == "abstract_method_signature" then
      local name = field(m, "name")
      local n = rtext(ctx, name)
      local s = make(ctx.src, m, n == "constructor" and "Constructor" or "Method", n, name)
      s.detail = tfn_detail(ctx, m)
      local b = field(m, "body")
      if b then
        ts.collect(ctx, b, "fn", s.children)
      end
      table.insert(out, s)
    elseif t == "public_field_definition" or t == "property_signature" then
      local name = field(m, "name")
      local s = make(ctx.src, m, "Property", rtext(ctx, name), name)
      local ty = field(m, "type")
      s.detail = ty and rtext(ctx, ty) or ""
      local v = field(m, "value")
      if v and (v:type() == "arrow_function" or v:type() == "function_expression") then
        s.kind = "Method"
        s.detail = tfn_detail(ctx, v)
      end
      table.insert(out, s)
    end
  end
end

local function ts_class(ctx, node)
  local name = field(node, "name")
  local s = make(ctx.src, node, "Class", name and rtext(ctx, name) or "<anonymous>", name)
  local h = ts_heritage(ctx, node)
  s.detail = rtext(ctx, field(node, "type_parameters")) .. (h ~= "" and (" " .. h) or "")
  s.type_params = rtext(ctx, field(node, "type_parameters"))
  local body = field(node, "body")
  if body then
    ts_members(ctx, body, s.children)
  end
  return s
end

local function ts_function(ctx, node)
  local name = field(node, "name")
  local s = make(ctx.src, node, "Function", rtext(ctx, name), name)
  s.detail = tfn_detail(ctx, node)
  s.type_params = rtext(ctx, field(node, "type_parameters"))
  local body = field(node, "body")
  if body then
    ts.collect(ctx, body, "fn", s.children)
  end
  return s
end

ts.handlers = {
  class_declaration = ts_class,
  abstract_class_declaration = ts_class,
  interface_declaration = function(ctx, node)
    local name = field(node, "name")
    local s = make(ctx.src, node, "Interface", rtext(ctx, name), name)
    local h = ts_heritage(ctx, node)
    s.detail = rtext(ctx, field(node, "type_parameters")) .. (h ~= "" and (" " .. h) or "")
    s.type_params = rtext(ctx, field(node, "type_parameters"))
    local body = field(node, "body")
    if body then
      ts_members(ctx, body, s.children)
    end
    return s
  end,
  type_alias_declaration = function(ctx, node)
    local name = field(node, "name")
    local s = make(ctx.src, node, "TypeAlias", rtext(ctx, name), name)
    local value = field(node, "value")
    local vt = rtext(ctx, value)
    if #vt > ctx.max_detail then
      vt = vim.fn.strcharpart(vt, 0, ctx.max_detail - 1) .. "…"
    end
    s.detail = rtext(ctx, field(node, "type_parameters")) .. " = " .. vt
    s.type_params = rtext(ctx, field(node, "type_parameters"))
    if value and value:type() == "object_type" then
      ts_members(ctx, value, s.children)
    end
    return s
  end,
  enum_declaration = function(ctx, node)
    local name = field(node, "name")
    local s = make(ctx.src, node, "Enum", rtext(ctx, name), name)
    local body = field(node, "body")
    if body then
      for m in body:iter_children() do
        if m:type() == "property_identifier" then
          table.insert(s.children, make(ctx.src, m, "EnumMember", rtext(ctx, m), m))
        elseif m:type() == "enum_assignment" then
          local n = field(m, "name")
          local es = make(ctx.src, m, "EnumMember", rtext(ctx, n), n)
          es.detail = " = " .. rtext(ctx, field(m, "value"))
          table.insert(s.children, es)
        end
      end
    end
    return s
  end,
  function_declaration = ts_function,
  generator_function_declaration = ts_function,
  function_signature = ts_function,
  internal_module = function(ctx, node)
    local name = field(node, "name")
    local s = make(ctx.src, node, "Module", rtext(ctx, name), name)
    local body = field(node, "body")
    if body then
      ts.collect(ctx, body, "module", s.children)
    end
    return s
  end,
}
ts.handlers.module = ts.handlers.internal_module

local function ts_declarators(ctx, node, scope, out)
  local is_const = vim.treesitter.get_node_text(node, ctx.src):match("^const") ~= nil
  for d in node:iter_children() do
    if d:type() == "variable_declarator" then
      local name = field(d, "name")
      local value = field(d, "value")
      local vt = value and value:type()
      if vt == "arrow_function" or vt == "function_expression" or vt == "function" then
        local s = make(ctx.src, d, "Function", rtext(ctx, name), name)
        s.detail = tfn_detail(ctx, value)
        s.type_params = rtext(ctx, field(value, "type_parameters"))
        local body = field(value, "body")
        if body then
          ts.collect(ctx, body, "fn", s.children)
        end
        table.insert(out, s)
      elseif vt == "class" then
        local s = ts_class(ctx, value)
        s.name = rtext(ctx, name)
        s.lnum, s.col = name:range()
        table.insert(out, s)
      elseif scope ~= "fn" and name and name:type() == "identifier" then
        local s = make(ctx.src, d, is_const and "Constant" or "Variable", rtext(ctx, name), name)
        local ty = field(d, "type")
        s.detail = ty and rtext(ctx, ty) or ""
        table.insert(out, s)
      end
    end
  end
end

function ts.collect(ctx, node, scope, out)
  for child in node:iter_children() do
    if child:named() then
      local t = child:type()
      local h = ts.handlers[t]
      if h then
        local ok, sym = pcall(h, ctx, child, scope)
        if ok and sym and sym.name ~= "" then
          table.insert(out, sym)
        end
      elseif t == "lexical_declaration" or t == "variable_declaration" then
        ts_declarators(ctx, child, scope, out)
      elseif t == "export_statement" or t == "ambient_declaration" or t == "statement_block"
        or t == "expression_statement" or (scope == "fn" and not t:match("expression$")) then
        ts.collect(ctx, child, scope, out)
      end
    end
  end
  return out
end

---------------------------------------------------------------- JSON
local function preview(ctx, s)
  s = squash(s, ctx.lang)
  if vim.fn.strchars(s) > ctx.max_detail then
    s = vim.fn.strcharpart(s, 0, ctx.max_detail - 1) .. "…"
  end
  return s
end

local function display_key(raw)
  -- Bare keys are shown unquoted; anything needing quotes keeps its source form.
  local inner = raw:match('^"(.*)"$') or raw:match("^'(.*)'$")
  if inner and inner:match("^[%w_%-%.%$@]+$") then
    return inner
  end
  return raw
end

local json = {}

local JSON_SCALAR = { string = "String", number = "Number", ["true"] = "Boolean", ["false"] = "Boolean", null = "Null" }

function json.value(ctx, node, sym)
  local t = node:type()
  if t == "object" then
    sym.kind = "Object"
    local n = 0
    for pair in node:iter_children() do
      if pair:type() == "pair" then
        n = n + 1
        local key = field(pair, "key")
        local value = field(pair, "value")
        local child = make(ctx.src, pair, "Null", display_key(vim.treesitter.get_node_text(key, ctx.src)), key)
        child.raw_key = vim.treesitter.get_node_text(key, ctx.src)
        if value then
          json.value(ctx, value, child)
        end
        table.insert(sym.children, child)
      end
    end
    sym.detail = string.format("{%d}", n)
  elseif t == "array" then
    sym.kind = "Array"
    local i = 0
    for item in node:iter_children() do
      if item:named() and item:type() ~= "comment" then
        local child = make(ctx.src, item, "Null", string.format("[%d]", i), item)
        json.value(ctx, item, child)
        table.insert(sym.children, child)
        i = i + 1
      end
    end
    sym.detail = string.format("[%d]", i)
  else
    sym.kind = JSON_SCALAR[t] or "String"
    sym.detail = preview(ctx, vim.treesitter.get_node_text(node, ctx.src))
  end
end

function json.collect(ctx, root)
  local out = {}
  for child in root:iter_children() do
    if child:named() and child:type() ~= "comment" then
      local holder = { children = {} }
      json.value(ctx, child, holder)
      if child:type() == "object" or child:type() == "array" then
        return holder.children
      end
      local s = make(ctx.src, child, holder.kind, "(root)", child)
      s.detail = holder.detail
      table.insert(out, s)
    end
  end
  return out
end

---------------------------------------------------------------- YAML
local yaml = {}

local YAML_SCALAR = {
  string_scalar = "String", integer_scalar = "Number", float_scalar = "Number",
  boolean_scalar = "Boolean", null_scalar = "Null",
}

local function yaml_unwrap(node)
  -- block_node / flow_node may carry anchors and tags before the content
  while node and (node:type() == "block_node" or node:type() == "flow_node") do
    local content
    for c in node:iter_children() do
      local t = c:type()
      if c:named() and t ~= "anchor" and t ~= "tag" and t ~= "comment" then
        content = c
      end
    end
    if not content then
      return nil
    end
    node = content
  end
  return node
end

function yaml.value(ctx, node, sym)
  node = yaml_unwrap(node)
  if not node then
    sym.kind = "Null"
    sym.detail = ""
    return
  end
  local t = node:type()
  if t == "block_mapping" or t == "flow_mapping" then
    sym.kind = "Object"
    local n = 0
    for pair in node:iter_children() do
      local pt = pair:type()
      if pt == "block_mapping_pair" or pt == "flow_pair" then
        n = n + 1
        local key = field(pair, "key")
        local value = field(pair, "value")
        local raw = key and squash(vim.treesitter.get_node_text(key, ctx.src), "yaml") or "?"
        local child = make(ctx.src, pair, "Null", raw, key or pair)
        child.raw_key = raw
        if value then
          yaml.value(ctx, value, child)
        else
          child.kind = "Null"
        end
        table.insert(sym.children, child)
      end
    end
    sym.detail = string.format("{%d}", n)
  elseif t == "block_sequence" or t == "flow_sequence" then
    sym.kind = "Array"
    local i = 0
    for item in node:iter_children() do
      local it = item:type()
      if it == "block_sequence_item" or it == "flow_node" or it == "flow_pair" then
        local child = make(ctx.src, item, "Null", string.format("[%d]", i), item)
        if it == "block_sequence_item" then
          local inner
          for c in item:iter_children() do
            if c:named() and c:type() ~= "comment" then
              inner = c
            end
          end
          if inner then
            yaml.value(ctx, inner, child)
          end
        elseif it == "flow_pair" then
          child.kind = "Object"
          local fake = { children = {} }
          child.children = fake.children
          local key = field(item, "key")
          local k = make(ctx.src, item, "Null", key and squash(vim.treesitter.get_node_text(key, ctx.src), "yaml") or "?", key)
          local v = field(item, "value")
          if v then
            yaml.value(ctx, v, k)
          end
          table.insert(child.children, k)
          child.detail = "{1}"
        else
          yaml.value(ctx, item, child)
        end
        table.insert(sym.children, child)
        i = i + 1
      end
    end
    sym.detail = string.format("[%d]", i)
  elseif t == "plain_scalar" then
    local inner = node:named_child(0)
    sym.kind = inner and YAML_SCALAR[inner:type()] or "String"
    sym.detail = preview(ctx, vim.treesitter.get_node_text(node, ctx.src))
  elseif t == "alias" then
    sym.kind = "String"
    sym.detail = preview(ctx, vim.treesitter.get_node_text(node, ctx.src))
  else -- quoted / block scalars
    sym.kind = "String"
    sym.detail = preview(ctx, vim.treesitter.get_node_text(node, ctx.src))
  end
end

function yaml.collect(ctx, root)
  local docs = {}
  for doc in root:iter_children() do
    if doc:type() == "document" then
      table.insert(docs, doc)
    end
  end
  local function doc_children(doc)
    local holder = { children = {} }
    for c in doc:iter_children() do
      if c:named() and (c:type() == "block_node" or c:type() == "flow_node") then
        yaml.value(ctx, c, holder)
        if holder.kind ~= "Object" and holder.kind ~= "Array" then
          local s = make(ctx.src, c, holder.kind, "(root)", c)
          s.detail = holder.detail
          return { s }
        end
      end
    end
    return holder.children
  end
  if #docs == 1 then
    return doc_children(docs[1])
  end
  local out = {}
  for i, doc in ipairs(docs) do
    local s = make(ctx.src, doc, "Document", string.format("document %d", i - 1), doc)
    s.children = doc_children(doc)
    table.insert(out, s)
  end
  return out
end

---------------------------------------------------------------- entry point

--- Extract symbols from a buffer. Returns symbols or nil, err.
function M.get_symbols(bufnr, opts)
  opts = opts or {}
  local ft = vim.bo[bufnr].filetype
  local lang = LANG_BY_FT[ft]
  if not lang then
    return nil, "no Tree-sitter extractor for filetype '" .. ft .. "'"
  end
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang, { error = false })
  if not ok or not parser then
    return nil, "Tree-sitter parser for '" .. lang .. "' is not installed"
  end
  local tree = parser:parse()[1]
  if not tree then
    return nil, "Tree-sitter parse failed"
  end
  local root = tree:root()
  local ctx = { src = bufnr, lang = lang, max_detail = opts.max_detail or 48 }
  if lang == "rust" then
    return rust.collect(ctx, root, "top", {})
  elseif lang == "typescript" or lang == "tsx" then
    return ts.collect(ctx, root, "top", {})
  end
  local syms = lang == "json" and json.collect(ctx, root) or yaml.collect(ctx, root)
  local function mark(list)
    for _, s in ipairs(list) do
      s.data = true
      mark(s.children)
    end
  end
  mark(syms)
  return syms
end

return M
