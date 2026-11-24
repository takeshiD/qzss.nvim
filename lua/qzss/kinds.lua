-- Semantic kinds, default labels, icon presets and highlight links.
local M = {}

-- Ordered list of every kind qzss produces.
M.list = {
  "Module", "Struct", "Enum", "EnumMember", "Trait", "Impl", "TraitImpl",
  "Function", "Method", "Constructor", "Field", "Property", "Constant",
  "Variable", "TypeAlias", "AssociatedType", "Class", "Interface", "Macro",
  "Object", "Array", "String", "Number", "Boolean", "Null", "Document",
}

-- Short kind labels shown at the end of a row (configurable).
M.labels = {
  Module = "mod", Struct = "struct", Enum = "enum", EnumMember = "variant",
  Trait = "trait", Impl = "impl", TraitImpl = "impl trait", Function = "fn",
  Method = "method", Constructor = "ctor", Field = "field", Property = "prop",
  Constant = "const", Variable = "var", TypeAlias = "type",
  AssociatedType = "assoc type", Class = "class", Interface = "interface",
  Macro = "macro", Object = "object", Array = "array", String = "string",
  Number = "number", Boolean = "bool", Null = "null", Document = "doc",
}

-- Icon presets. "unicode" (default) needs no Nerd Font; "ascii" is pure ASCII.
M.presets = {
  nerd = {
    Module = "󰏗", Struct = "󰙅", Enum = "", EnumMember = "", Trait = "",
    Impl = "󰡱", TraitImpl = "󰡱", Function = "󰊕", Method = "󰆧", Constructor = "",
    Field = "󰜢", Property = "", Constant = "󰏿", Variable = "󰀫", TypeAlias = "",
    AssociatedType = "", Class = "󰠱", Interface = "", Macro = "",
    Object = "󰅩", Array = "󰅪", String = "󰀬", Number = "󰎠", Boolean = "◩",
    Null = "󰟢", Document = "󰈙",
  },
  unicode = {
    Module = "▣", Struct = "◆", Enum = "⋄", EnumMember = "·", Trait = "◈",
    Impl = "⊂", TraitImpl = "⊃", Function = "ƒ", Method = "ⓜ", Constructor = "⊕",
    Field = "▪", Property = "▫", Constant = "π", Variable = "ν", TypeAlias = "≡",
    AssociatedType = "≔", Class = "©", Interface = "ⓘ", Macro = "!",
    Object = "{}", Array = "[]", String = "\"", Number = "#", Boolean = "◐",
    Null = "∅", Document = "§",
  },
  ascii = {
    Module = "M", Struct = "S", Enum = "E", EnumMember = "e", Trait = "T",
    Impl = "I", TraitImpl = "I", Function = "f", Method = "m", Constructor = "c",
    Field = ".", Property = ".", Constant = "K", Variable = "v", TypeAlias = "=",
    AssociatedType = "=", Class = "C", Interface = "i", Macro = "!",
    Object = "{", Array = "[", String = "\"", Number = "#", Boolean = "b",
    Null = "0", Document = "D",
  },
}

-- Fold markers per preset: { expanded, collapsed, leaf }.
M.markers = {
  nerd = { "", "", " " },
  unicode = { "▾", "▸", " " },
  ascii = { "-", "+", " " },
}

-- Default highlight links. Classic groups keep the colors in harmony with
-- whatever colorscheme is active; every group can be overridden.
M.hl_links = {
  Module = "Include", Struct = "Structure", Enum = "Type", EnumMember = "Constant",
  Trait = "Special", Impl = "Statement", TraitImpl = "Statement",
  Function = "Function", Method = "Function", Constructor = "Special",
  Field = "Identifier", Property = "Identifier", Constant = "Constant",
  Variable = "Identifier", TypeAlias = "Typedef", AssociatedType = "Typedef",
  Class = "Type", Interface = "Structure", Macro = "Macro",
  Object = "Structure", Array = "Special", String = "String", Number = "Number",
  Boolean = "Boolean", Null = "Comment", Document = "Title",
}

function M.setup_highlights(overrides)
  local set = function(name, spec)
    if type(spec) == "string" then
      spec = { link = spec }
    end
    spec = vim.tbl_extend("force", { default = true }, spec)
    vim.api.nvim_set_hl(0, name, spec)
  end
  for kind, link in pairs(M.hl_links) do
    set("Qzss" .. kind, link)
  end
  set("QzssDetail", "Comment")
  -- Kind labels use the colorscheme's Comment color (readable in practically
  -- every theme, unlike NonText) in italics so they do not blend into the
  -- detail text. Re-derived on :colorscheme; override with highlights.KindLabel.
  local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
  if comment.fg or comment.ctermfg then
    set("QzssKindLabel", { fg = comment.fg, ctermfg = comment.ctermfg, italic = true })
  else
    set("QzssKindLabel", "Comment")
  end
  set("QzssFold", "Special")
  set("QzssFoldCount", "Comment")
  set("QzssKeyword", "Keyword")
  set("QzssTraitName", "Special")
  set("QzssSelfType", "Type")
  set("QzssCurrent", "CursorLine")
  set("QzssMessage", "WarningMsg")
  -- user overrides are applied without `default` so they win
  for name, spec in pairs(overrides or {}) do
    local group = name:match("^Qzss") and name or ("Qzss" .. name)
    if type(spec) == "string" then
      spec = { link = spec }
    end
    vim.api.nvim_set_hl(0, group, spec)
  end
end

return M
