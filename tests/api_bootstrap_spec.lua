-- A statusline-only consumer must work without setup() or any command.
vim.opt.rtp:prepend(vim.fn.getcwd());vim.opt.rtp:prepend(vim.fn.getcwd()..'/.deps/site')
local T=require('tests.helpers');local q=require('qzss.api');local a=vim.api
vim.cmd('edit tests/fixtures/ts/sample.ts')
vim.bo.filetype='typescript'
local b=a.nvim_get_current_buf()
q.current_symbol({row=1})
T.eq(q.is_open(),false,'current_symbol bootstrap opens no UI')
T.ok(#a.nvim_get_autocmds({group='qzss'})>0,'current_symbol initializes tracking without setup')
a.nvim_buf_set_lines(b,0,0,false,{'class Added {}'})
a.nvim_exec_autocmds('TextChanged',{buffer=b})
local refreshed=vim.wait(1000,function()
 local s=q.get_snapshot(b);return s and not s.stale and s.symbols[1].name=='Added'
end)
T.ok(refreshed,'statusline-only cache updates after edits')
T.finish()
