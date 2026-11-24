-- Pure rendering: symbols + state -> lines, highlights, row mapping.
local config = require("qzss.config")
local kinds = require("qzss.kinds")

local M = {}

local function preset_name()
  local icons = config.options.icons
  return type(icons) == "string" and icons or "unicode"
end

function M.icon_for(sym, ctx)
  local o = config.options
  if o.get_icon then
    local ok, icon, hl = pcall(o.get_icon, sym, ctx)
    if ok and icon then
      return icon, hl
    end
  end
  local icons = o.icons
  if type(icons) == "table" then
    return icons[sym.kind] or kinds.presets.unicode[sym.kind] or "?"
  end
  return (kinds.presets[icons] or kinds.presets.unicode)[sym.kind] or "?"
end

function M.label_for(kind)
  local o = config.options
  if o.kind_labels == false or not o.show_kind then
    return nil
  end
  local l = o.kind_labels[kind]
  if l == false then
    return nil
  end
  return l or kinds.labels[kind] or kind
end

function M.markers()
  local p = preset_name()
  return kinds.markers[p] or kinds.markers.unicode
end

-- Assign stable ids (parent path + kind + name, de-duplicated) and parents.
function M.assign_ids(symbols)
  local function walk(list, prefix, parent)
    local seen = {}
    for _, s in ipairs(list) do
      local key = s.kind .. ":" .. s.name
      seen[key] = (seen[key] or 0) + 1
      if seen[key] > 1 then
        key = key .. "#" .. seen[key]
      end
      s.id = prefix .. "/" .. key
      s.parent = parent
      walk(s.children, s.id, s)
    end
  end
  walk(symbols, "", nil)
  return symbols
end

local function visible(sym, ctx, kind_set)
  local o = config.options
  if o.filter then
    local ok, keep = pcall(o.filter, sym, ctx)
    if ok and keep == false then
      return false
    end
  end
  if kind_set and not kind_set[sym.kind] then
    return false
  end
  return true
end

-- Prune symbols by the active filters. A filtered-out parent stays when a
-- descendant matches, so context is not lost.
function M.filter(symbols, ctx, kind_set)
  local out = {}
  for _, s in ipairs(symbols) do
    local kids = M.filter(s.children, { bufnr = ctx.bufnr, filetype = ctx.filetype, depth = ctx.depth + 1 }, kind_set)
    if visible(s, ctx, kind_set) or #kids > 0 then
      local copy = setmetatable({ children = kids, matched = visible(s, ctx, kind_set) }, { __index = s })
      table.insert(out, copy)
    end
  end
  return out
end

--- Build display lines.
-- state: { collapsed = {id=true}, bufnr, filetype, kind_set }
-- returns lines, highlights {row, col_start, col_end, group}, rows {row -> sym}
function M.build(symbols, state)
  local o = config.options
  local lines, hls, rows = {}, {}, {}
  local mk = M.markers()
  local ctx0 = { bufnr = state.bufnr, filetype = state.filetype, depth = 0 }
  local list = M.filter(symbols, ctx0, state.kind_set)

  local function add_hl(row, s, e, group)
    if group and e > s then
      table.insert(hls, { row, s, e, group })
    end
  end

  local function walk(items, depth)
    for _, s in ipairs(items) do
      local ctx = { bufnr = state.bufnr, filetype = state.filetype, depth = depth }
      local row = #lines
      local has_kids = #s.children > 0
      local collapsed = has_kids and state.collapsed[s.id]
      local marker = has_kids and (collapsed and mk[2] or mk[1]) or mk[3]
      local line = string.rep("  ", depth)
      local p = #line
      line = line .. marker .. " "
      add_hl(row, p, p + #marker, "QzssFold")
      local icon, icon_hl = M.icon_for(s, ctx)
      p = #line
      line = line .. icon .. " "
      add_hl(row, p, p + #icon, icon_hl or ("Qzss" .. s.kind))

      -- name (custom formatter or semantic segments)
      local name_text
      if o.format_name then
        local ok, r = pcall(o.format_name, s, ctx)
        if ok and type(r) == "string" then
          name_text = r
        end
      end
      p = #line
      if name_text then
        line = line .. name_text
        add_hl(row, p, #line, "Qzss" .. s.kind)
      elseif s.segments then
        for _, seg in ipairs(s.segments) do
          local q = #line
          line = line .. seg[1]
          add_hl(row, q, #line, seg[2])
        end
      else
        line = line .. s.name
        add_hl(row, p, #line, "Qzss" .. s.kind)
      end

      if collapsed then
        local n = 0
        local function count(c)
          for _, k in ipairs(c) do
            n = n + 1
            count(k.children)
          end
        end
        count(s.children)
        p = #line
        line = line .. " [+" .. n .. "]"
        add_hl(row, p, #line, "QzssFoldCount")
      end
      -- detail
      if o.show_detail then
        local detail = s.detail or ""
        if o.format_detail then
          local ok, r = pcall(o.format_detail, s, ctx)
          if ok and type(r) == "string" then
            detail = r
          end
        end
        detail = detail:gsub("^%s+", "")
        if detail ~= "" then
          local sep
          if s.kind == "Object" or s.kind == "Array" then
            sep = " "
          elseif s.data then
            sep = ": "
          else
            sep = (not collapsed and detail:match("^[<(:]")) and "" or " "
          end
          p = #line
          line = line .. sep .. detail
          add_hl(row, p, #line, "QzssDetail")
        end
      end


      local label = M.label_for(s.kind)
      if label then
        p = #line
        line = line .. "  " .. label
        add_hl(row, p + 2, #line, "QzssKindLabel")
      end

      table.insert(lines, line)
      rows[row + 1] = s
      if has_kids and not collapsed then
        walk(s.children, depth + 1)
      end
    end
  end
  walk(list, 0)
  return lines, hls, rows
end

return M
