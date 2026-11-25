-- Parent review: public copies, global configuration, event re-entry and closed float anchors.
dofile(vim.fn.getcwd() .. '/tests/minimal_init.lua')
local T=require('tests.helpers')
local q=require('qzss')
local a=vim.api
local root=vim.fn.getcwd()
local function source(opts)
 q.close();vim.cmd('silent! only!');vim.cmd('edit! '..root..'/tests/fixtures/rust/src/lib.rs')
 q.setup(opts or {backends={'treesitter'}})
 a.nvim_win_set_cursor(0,{3,10})
 return a.nvim_get_current_buf(),a.nvim_get_current_win()
end
local b=source()
q.refresh(b)
local original=q.symbol_at(b,2).name
q.symbol_at(b,2).name='external mutation'
T.eq(q.symbol_at(b,2).name,original,'legacy symbol_at returns an independent tree')
q.compute(b,function(m) m.symbols[1].name='callback mutation';m.collapsed.fake=true end)
T.eq(q.get_snapshot(b).symbols[1].name,original,'legacy compute callback cannot mutate cached symbols')
T.eq(vim.tbl_contains(q.get_folded(b),'fake'),false,'legacy compute callback cannot mutate folds')
source({backends={'treesitter'},close_on_jump=false})
q.open({mode='float'});q.jump()
T.ok(q.is_open(),'explicit global close_on_jump=false keeps float open')
source({backends={'treesitter'}})
q.open({mode='float'});q.jump()
T.eq(q.is_open(),false,'unconfigured float still closes on jump')
source({backends={'treesitter'},close_on_jump=true,layout={float={close_on_jump=false}}})
q.open({mode='float'});q.jump()
T.ok(q.is_open(),'explicit float false overrides global true')
source({backends={'treesitter'},layout={float={close_on_jump='global'}}})
q.open({mode='float'});q.jump()
T.ok(q.is_open(),'global sentinel follows default global false')
source()
local order={}
local sub=q.subscribe('*',function(ev)
 table.insert(order,ev.event)
 if ev.event=='symbols' then q.close() end
end)
q.open({mode='float'});q.unsubscribe(sub)
T.same(order,{'open','symbols','close'},'reentrant close never precedes its open event')
T.eq(q.is_open(),false,'symbols listener can close the view')
local _,src=source({backends={'treesitter'},layout={mode='float',float={relative='win'}}})
vim.cmd('vsplit '..root..'/tests/fixtures/ts/sample.ts')
local other=a.nvim_get_current_win()
a.nvim_set_current_win(src);q.open()
local fw=q.get_view().winid
a.nvim_win_close(src,true)
vim.wait(500,function() local v=q.get_view();return not v or v.source_winid==other end)
local v=q.get_view()
T.ok(v~=nil,'float survives when another source window remains')
if v then
 T.eq(v.source_winid,other,'closed source window is replaced in view state')
 T.eq(v.source_bufnr,a.nvim_win_get_buf(other),'outline follows surviving source buffer')
 local cfg=a.nvim_win_get_config(fw)
 T.eq(cfg.win,other,'window-relative float is reanchored after external source close')
 T.eq(a.nvim_get_current_win(),fw,'repair preserves float focus')
end
q.close()
T.eq(a.nvim_get_current_win(),other,'close returns focus to surviving source')
source()
q.open({mode='sidebar'})
sub=q.subscribe('mode',function() q.close() end)
local ok=pcall(q.open,{mode='float'})
q.unsubscribe(sub)
T.ok(ok,'mode subscriber can close without an invalid-window error')
T.eq(q.is_open(),false,'mode subscriber close is respected')

source()
order={}
sub=q.subscribe('*',function(ev)
 table.insert(order,ev.event)
 if ev.event=='open' then q.close() end
end)
q.open({mode='float'});q.unsubscribe(sub)
T.same(order,{'open','close'},'open subscriber can close before computation starts')

b=source()
q.refresh(b)
local delivered
q.request_symbols(b,function(_,snap) delivered=snap end)
a.nvim_buf_set_lines(b,0,0,false,{'// added before callback delivery'})
T.ok(vim.wait(500,function() return delivered~=nil end),'cached request is delivered')
T.eq(delivered.stale,true,'stale reflects the buffer at callback delivery')

-- A symbols listener starts a newer asynchronous computation. The older
-- synchronous phase must not finish that request or mark its model ready.
b=source()
local lsp=require('qzss.backends.lsp')
local available,request=lsp.available,lsp.request
local respond
lsp.available=function() return true end
lsp.request=function(_,cb) respond=cb end
local restarted=false
sub=q.subscribe('symbols',function()
 if not restarted then
  restarted=true
  q.setup({backends={'lsp'}})
  q.refresh(b)
 end
end)
delivered=nil
q.request_symbols(b,function(_,snap) delivered=snap end)
vim.wait(30)
T.eq(delivered,nil,'reentrant refresh waits for the newest computation')
T.eq(q.get_snapshot(b).pending,true,'newer computation stays pending')
T.ok(type(respond)=='function','newer LSP request started')
respond({{name='Latest',kind='Function',detail='',lnum=0,col=0,children={},source='lsp'}})
T.ok(vim.wait(500,function() return delivered~=nil end),'newer response completes the waiting request')
T.eq(delivered.symbols[1].name,'Latest','only the newest generation is delivered')
q.unsubscribe(sub)
lsp.available,lsp.request=available,request

-- Round-2 acceptance: `:edit file` in the empty [No Name] buffer reuses its
-- bufnr, so BufEnter does not retarget. The outline (sidebar and float) and
-- API-only consumers must still recompute right away, without an edit.
local function reuse_noname(mode)
 q.close();vim.cmd('silent! only!');vim.cmd('enew!')
 q.setup({backends={'treesitter'}})
 local nb=a.nvim_get_current_buf()
 if mode then q.open({mode=mode,focus=false}) else q.request_symbols(nb,function() end) end
 vim.wait(200,function() return q.get_snapshot(nb)~=nil end)
 T.ok(q.get_snapshot(nb).error~=nil,(mode or 'api')..': empty buffer has no source yet')
 local events={}
 local s=q.subscribe('symbols',function(ev) if ev.bufnr==nb then table.insert(events,ev) end end)
 -- a fresh copy, so no other buffer already holds the file
 local f=vim.fn.tempname()..'.rs'
 vim.fn.writefile(vim.fn.readfile(root..'/tests/fixtures/rust/src/lib.rs'),f)
 vim.cmd('edit '..vim.fn.fnameescape(f))
 T.eq(a.nvim_get_current_buf(),nb,(mode or 'api')..': :edit reused the [No Name] bufnr')
 T.ok(vim.wait(500,function() local sn=q.get_snapshot(nb);return sn and #sn.symbols>0 end),(mode or 'api')..': symbols recomputed after :edit without any change')
 T.eq(q.get_snapshot(nb).error,nil,(mode or 'api')..': no stale "no source" error')
 T.ok(#events>0,(mode or 'api')..': symbols event fired for the reloaded buffer')
 if mode then
  local v=q.get_view()
  T.eq(v and v.source_bufnr,nb,mode..': view still follows the same buffer')
  local lines=table.concat(a.nvim_buf_get_lines(v.bufnr,0,-1,false),'\n')
  T.ok(lines:find('Shape<T>',1,true)~=nil,mode..': outline buffer shows the file symbols')
 end
 q.unsubscribe(s)
 return nb
end
reuse_noname('sidebar')
reuse_noname('float')
local nb=reuse_noname(nil)
vim.bo[nb].filetype=''
T.ok(vim.wait(500,function() return q.get_snapshot(nb).error~=nil end),'filetype cleared: recomputed (no extractor)')
vim.bo[nb].filetype='rust'
T.ok(vim.wait(500,function() return q.get_snapshot(nb).error==nil and #q.get_snapshot(nb).symbols>0 end),'filetype set again: recomputed with symbols')
T.finish()
