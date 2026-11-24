-- Independent reproductions supplied during implementation review.
-- Requires the same parser + real language-server setup as lsp_e2e.lua.
local root = vim.fn.getcwd()
package.path = root .. '/?.lua;' .. package.path
vim.env.QZSS_LSP = '1'
dofile(root .. '/tests/minimal_init.lua')
local T = require('tests.helpers')
local q = require('qzss')
local api = vim.api

local function parse(ft, lines)
  local b = api.nvim_create_buf(false, true)
  vim.bo[b].filetype = ft
  api.nvim_buf_set_lines(b, 0, -1, false, lines)
  local symbols = q.get_symbols(b)
  api.nvim_buf_delete(b, { force = true })
  return symbols
end

local yaml = parse('yaml', { '"two  spaces": 1', '"two spaces": 2' })
T.eq(yaml[1].name, '"two  spaces"', 'quoted YAML key preserves meaningful spaces')
T.ok(yaml[1].name ~= yaml[2].name, 'distinct YAML keys keep distinct display identities')
local plain_yaml = parse('yaml', { 'two  spaces: value', 'scalar: two  spaces' })
T.eq(plain_yaml[1].name, 'two  spaces', 'plain YAML key also preserves meaningful spaces')
T.eq(plain_yaml[2].detail, 'two  spaces', 'plain YAML scalar preview preserves meaningful spaces')
local ts = parse('typescript', { 'type Spacing = "a  b" | "a b";' })
T.ok(ts[1].detail:find('"a  b"', 1, true), 'TypeScript string literal type preserves spaces', ts[1].detail)
local json = parse('json', { '{"key": "a  b"}' })
T.eq(json[1].detail, '"a  b"', 'JSON literal preview preserves spaces')

q.setup({ backends = { 'lsp' } })
vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/tests/fixtures/ts/unicode.ts'))
local b = api.nvim_get_current_buf()
local attached = vim.wait(20000, function()
  return require('qzss.backends.lsp').available(b)
end, 100)
T.ok(attached, 'real TypeScript server attaches for Unicode jump regression')
if attached then
  q.open()
  local ready = vim.wait(20000, function()
    local state = q._state.bufs[b]
    return state and state.source == 'lsp'
  end, 100)
  T.ok(ready, 'real LSP-only outline arrives')
  if ready then
    local sb = q._state.sidebars[api.nvim_get_current_tabpage()]
    local found = false
    for row, symbol in ipairs(sb.rows) do
      if symbol.name == 'target' then
        found = true
        api.nvim_win_set_cursor(sb.win, { row, 0 })
        q.jump()
        local expected = api.nvim_buf_get_lines(b, 0, 1, false)[1]:find('target', 1, true) - 1
        T.eq(api.nvim_get_current_buf(), b, 'Unicode jump returns to correct source buffer')
        T.eq(api.nvim_win_get_cursor(0)[2], expected, 'Unicode LSP jump lands at exact UTF-8 byte column')
        break
      end
    end
    T.ok(found, 'real server supplies target symbol')
  end
end
T.finish()
