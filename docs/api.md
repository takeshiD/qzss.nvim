# qzss.nvim Lua API

`require("qzss")` is the public API. `require("qzss.api")` is the same table without the legacy helpers. Both are stable. Every other `qzss.*` module (`qzss.view`, `qzss.model`, `qzss.render`, `qzss.backends.*`, …) is private and can change in any release.

The user commands, the outline keymaps and your code all call these same functions. For example, `:QzssFloat` is `require("qzss").open({ mode = "float" })`, and `<CR>` in the outline is `require("qzss").jump()`.

Contents: [Conventions](#conventions) · [Layout](#layout-sidebar-and-float) · [Reference](#reference) · [Events](#events) · [Examples](#examples) · [Compatibility](#versioning-and-compatibility)

## Conventions

- **Positions** are `{ row, col }`: `row` is 1-based and `col` is a 0-based **byte** column. This is the format of `nvim_win_get_cursor()`/`nvim_win_set_cursor()`, so `vim.api.nvim_win_set_cursor(0, sym.pos)` works.
- **Ranges** are `{ start = pos, ["end"] = pos }`. The end is **exclusive**: `vim.api.nvim_buf_get_text(b, s[1]-1, s[2], e[1]-1, e[2], {})` returns exactly the declaration. LSP UTF-16/UTF-32 columns have already been converted to bytes with the client's `offset_encoding`.
- **Copies.** Everything returned is a fresh copy. Event payloads are also copied for each subscriber. You can change the tables you get, and qzss's state is not affected.
- **Scope.** Symbols, folds and the kind filter belong to a **source buffer**. Every window and tab that shows the buffer shares them. The outline view belongs to a **tabpage**: each tab has at most one outline. `open`, `close`, `toggle`, `is_open`, `jump` and the fold row actions work on the current tab.
- **`bufnr` arguments.** `nil` or `0` means the current buffer. Functions that also act on the outline (`refresh`, `set_filter`, `get_filter`, `get_folded`, `set_folded`, `open_all`, `close_all`, `jump_to` by id) use the outline's source buffer when the current tab has an outline and `bufnr` is `nil`.
- **Errors.** A wrong argument *type* (a programming error) raises a Lua error whose message starts with `qzss.<function>:` (no `file:line:` prefix), for every public function. A runtime condition (unknown id, deleted buffer, nothing cached yet) is returned as `nil, "reason"` / `false, "reason"`, or passed to the callback as `err`. These calls never raise.
- **Sync/async.** Everything is synchronous except `request_symbols()`, whose callback always runs later on the main loop.

### Symbol

```text
qzss.Symbol {
  id         string   stable id: parent path + kind + name, e.g. "/TraitImpl:impl<T> Shape<T> for MyStruct<T>/Method:area"
  name       string
  kind       string   one of :help qzss-kinds (Struct, TraitImpl, Interface, TypeAlias, Object, ...)
  detail     string   signature or value preview, "" when none
  bufnr      integer  source buffer
  depth      integer  0 for top-level symbols
  parent_id  string|nil
  pos        {row, col}             start of the name (the jump target)
  range      {start=pos, end=pos}   the whole declaration, end exclusive
  children   qzss.Symbol[]          in source order
  source     "treesitter" | "lsp" | "treesitter+lsp"   always set: "treesitter+lsp" when an LSP
                                                        symbol matched, else the backend that produced it
  -- optional
  trait, self_type, type_params, where_clause   Rust impls
  lsp_detail  string    DocumentSymbol.detail when an LSP symbol matched
  lsp_kind    integer   LSP SymbolKind when an LSP symbol matched
}
```

Ids are unique within a buffer. If siblings have the same kind and name, the later ones get `#2`, `#3`, …. An id stays the same across edits as long as the symbol's path stays the same, which is how folds and the selection survive refreshes.

### Snapshot

```text
qzss.Snapshot {
  bufnr        integer
  changedtick  integer        b:changedtick the symbols were computed from
  stale        boolean        the buffer changed since (tracked buffers refresh after update_delay ms)
  pending      boolean        an LSP answer for this changedtick is still expected
  source       string|nil     "treesitter" | "lsp" | "treesitter+lsp"
  error        string|nil     why there are no symbols (no parser and no LSP, ...)
  lsp_error    string|nil     last LSP error (Tree-sitter symbols may still be present)
  filter       string[]|nil   the buffer's kind filter
  symbols      qzss.Symbol[]  top-level symbols (unfiltered)
}
```

### When symbols are computed (Tree-sitter and LSP)

1. Tree-sitter runs synchronously. A `symbols` event with `pending = true` fires when a `documentSymbol` client is attached and its answer is still expected.
2. qzss sends the LSP request to the first attached client that supports `textDocument/documentSymbol`, with an 8 s timeout. When the answer arrives it is merged (or used alone when there is no parser). A `symbols` event with `pending = false` fires, and waiting `request_symbols()` callbacks run.
3. Each computation is tagged with the buffer's `changedtick`. If the buffer changed before the server answered, the answer is **discarded** and the computation restarts. You never receive symbols that are older than the text at the time you asked.
4. A buffer is **tracked** once its symbols have been requested, queried with `current_symbol()`, or shown. Setup is initialized automatically, including for a statusline-only consumer. `Snapshot.stale` is evaluated when reading a snapshot and again just before delivering a request callback; an already returned copy does not update itself. Tracked buffers are recomputed `update_delay` ms (default 150) after `TextChanged`, `TextChangedI` or `BufWritePost`, and on `LspAttach`. They are recomputed on the next tick (no delay) when the same buffer is loaded with a file or reloaded (`BufReadPost`, e.g. `:edit file` in the empty `[No Name]` buffer, which keeps its bufnr, or `:edit!`), renamed (`BufFilePost`) or given a new filetype (`FileType`). An outline showing that buffer re-renders with the new name and symbols. Untracked buffers cost nothing.
5. A tracked buffer that is unloaded or wiped is forgotten. Pending requests for it fail with `"buffer unloaded"` or `"buffer deleted"`.

## Layout: sidebar and float

`layout.mode` selects what `:Qzss`, `:QzssOpen` and `open()` without `mode` show. The default is `"sidebar"`. Both modes show the same outline buffer, with the same keys, folds, filter and selection. Switching modes while the outline is open (`:QzssFloat`, `:QzssSidebar`, `open({ mode = ... })`) moves the outline into a new window and keeps all of that state.

<!-- example: layout-defaults -->
```lua
require("qzss").setup({ layout = {   -- these are the defaults
  mode = "sidebar",            -- "sidebar" | "float"
  position = "right", width = 36, max_width = 64,   -- sidebar (unchanged)
  float = {
    relative = "editor",       -- "editor" | "win" (the source window)
    width = 0.5, height = 0.8, -- content size: cells (>= 1) or a fraction (0 < x < 1) of the reference
    position = "center",       -- center | top | bottom | left | right | top-left | top-right | bottom-left | bottom-right
    row = nil, col = nil,      -- explicit top-left (cells or fraction); overrides position
    min_width = 20, max_width = nil, min_height = 5, max_height = nil,
    border = "rounded",        -- any nvim_open_win() border
    winblend = 0,              -- 0..100
    title = true,              -- true: " qzss · <file> ", a string, or false
    title_pos = "center",
    zindex = 50,
    close_on_jump = true,      -- float default; "global" explicitly inherits close_on_jump
  },
} })
```

How the float is sized and placed:

- **Reference area.** With `relative = "editor"`, it is the editor grid without the tabline, the global/last statusline and the command line. With `relative = "win"`, it is the source window, and the float moves when that window is resized (`WinResized`). If that window closes, the view uses another normal window in the same tab (preferring the same buffer), or closes when none remains. A focused float keeps focus while it is reanchored.
- **Size.** `width`/`height` are the content size, without the border. A value `>= 1` is a number of cells (floored). A value in `(0, 1)` is a fraction of the reference. The size is first limited to `[min_*, max_*]`, which accept cells or fractions too. Then it is limited to what fits inside the reference with the border, and it is never less than 1. **On a narrow terminal, fitting wins over `min_*`.**
- **Position.** `position` aligns the float inside the reference. `row`/`col` override it and are clamped so the float stays on screen. The float is re-placed on `VimResized`, on `TabEnter` and whenever its title changes.
- **Title and footer.** With a border, the title shows `qzss · <file>` (or your string). The footer shows the source, the active filter and `? help`. With `border = "none"`, a winbar shows the file instead.
- **Validation.** `setup()` raises `qzss: invalid option layout...` for an unknown mode, relative, position, a non-positive size, or `winblend` outside 0..100. The previous configuration stays active.

An explicitly supplied global `close_on_jump` also applies to the float unless you supply a `layout.float.close_on_jump` override. The float-specific value accepts `true`, `false`, or `"global"`. With neither setting supplied, the sidebar stays open on jump and the float closes. Lua table fields set to `nil` are absent; use `"global"` when you need explicit inheritance.

Keys and behaviour specific to the float:

| | Sidebar | Float |
| --- | --- | --- |
| Close keys | `q` | `q` and `<Esc>` (`keymaps.float_close`, set it to `false` to disable) |
| `<CR>` | Jumps; closes only if `close_on_jump = true` (default `false`) | Jumps and closes (`layout.float.close_on_jump = true`), so the float never covers the code you jumped to. Set it to `false` to keep the float open; set it to `"global"` to follow the global `close_on_jump`. |
| `p` (preview) | Moves the source cursor; focus stays in the outline | Same |
| Open without focus | `:QzssOpen!`, `:QzssSidebar!`, `open({ focus = false })` | `:QzssFloat!`, `open({ mode = "float", focus = false })` |
| On close | Focus returns to the source window if the outline had focus | Same |
| `:edit` inside it | The file goes to the source window and the sidebar is rebuilt | The file goes to the source window and the float closes |
| Last window | `:q` in the last source window also closes the sidebar | Floats never block `:q` (no E5601) |

## Reference

### Setup and view

```text
setup(opts?)                         configure; optional (see :help qzss-options). Raises on invalid layout options.
open(opts?) -> ok, err?              opts = { mode?: "sidebar"|"float", focus?: boolean (default true) }
                                     Closed: opens for the current file buffer (mode defaults to layout.mode).
                                     Open: switches to opts.mode if it differs, retargets to the current
                                     buffer, focuses unless focus=false (focus=false also leaves the outline).
                                     false, "current buffer is not a file buffer" / "current window is floating".
close() -> boolean                   closes the current tab's outline; true when one was open
toggle(opts?) -> boolean             close when open (any mode), else open(opts)
is_open(opts?) -> boolean            opts = { mode? } also requires that mode
get_view(opts?) -> view|nil          opts = { tabpage? }; nil when that tab has no outline
    view = { tabpage, mode, winid, bufnr (outline buffer), source_bufnr, source_winid|nil,
             focused, cursor_symbol_id|nil, filter|nil, folded = {ids}, width, height }
info() -> string[]                   echo + return diagnostics (source, LSP clients, layout, errors)
api_version                          integer, currently 1
```

### Symbols (no UI needed)

```text
refresh(bufnr?)                      recompute now (outlines re-render, events fire)
get_snapshot(bufnr?) -> Snapshot|nil, err
                                     cached state, never computes. err: "not_ready" (never computed),
                                     "invalid buffer", "buffer not loaded", "buffer is a qzss outline"
request_symbols(bufnr?, callback) -> { cancel = fun(): boolean }
                                     callback(err, snapshot) runs later on the main loop, exactly once,
                                     unless cancelled. Answered from the cache when it is ready for the
                                     current changedtick; requests at one changedtick share one computation
                                     (one LSP request). err as for get_snapshot, plus "buffer deleted" /
                                     "buffer unloaded" when the buffer goes away at any point before the
                                     callback runs (even when the result was already computed or came
                                     from the cache; snapshot is then nil).
                                     An unsupported filetype is NOT an error: snapshot.symbols = {} and
                                     snapshot.error says why. cancel() returns true as long as the
                                     callback has not run yet (also for cache hits and Tree-sitter-only
                                     results waiting for delivery); the callback then never runs.
                                     cancel() after delivery, or a second cancel(), returns false. The
                                     computation itself keeps going and updates the cache.
find_symbol(bufnr?, id) -> Symbol|nil, err       err: "not_ready" | "unknown symbol id"
current_symbol(opts?) -> Symbol|nil, path|err
                                     opts = { bufnr?, winid?, row? (1-based) }. The innermost symbol whose
                                     range contains the row; path = { top-level ancestor, ..., symbol }.
                                     In the outline window: the symbol of the cursor row.
                                     err: "pending" (nothing cached yet; a background request was started,
                                     so subscribe to "symbols"), "no symbol", "invalid window",
                                     "window does not show the buffer"
jump_to(target, opts?) -> ok, err    target = Symbol (or any { bufnr, pos }) or an id string
                                     opts = { bufnr? (for ids), winid?, focus? (default true) }
                                     Window: opts.winid, else the outline's source window (for its buffer),
                                     else a normal window of this tab showing the buffer, else the current
                                     window (never the outline/floats). The position is clamped to the
                                     buffer. The outline stays open. err: "unknown symbol id",
                                     "invalid buffer", "invalid window", "no window to show the buffer"
```

### Filter and folds (per source buffer)

```text
set_filter(kinds|nil, bufnr?) -> boolean   show only these kinds (ancestors of matches stay); nil/{} clears.
                                           Unknown kind: error notification, filter unchanged, false.
get_filter(bufnr?) -> string[]|nil         sorted
set_folded(id, folded, opts?) -> ok, err   opts = { bufnr? }; err: "not_ready" | "unknown symbol id" |
                                           "symbol has no children"
get_folded(bufnr?) -> string[]             sorted ids of folded symbols
open_all(bufnr?) / close_all(bufnr?)       unfold / fold every symbol with children
```

### Outline actions (what the keys call)

These work on the cursor row of the current tab's outline. They return `false` and do nothing when the outline is closed or the row has no symbol.

```text
jump(opts?)       <CR> / p  (opts = { preview = true } keeps focus in the outline)
toggle_fold()     o za <Tab>
open_fold()       zo l
close_fold()      zc h   (on a leaf or folded row: folds the parent and selects it)
help()            ?
```

`open_all()`/`close_all()` without an argument are `zR`/`zM`. When the outline is open, `close_all()` also moves the cursor to the top-level ancestor.

### Legacy helpers (kept, not recommended for new code)

`get_symbols(bufnr)` (synchronous Tree-sitter tree with 0-based `lnum`, byte `col` and `parent` links), `outline_lines(bufnr, symbols?, collapsed?)`, `compute(bufnr, cb)`, `symbol_at(bufnr, line0)`, `render()`, `follow()`. These exist only in `require("qzss")`. Legacy positions and parent links are preserved, but `compute()` callback models and `symbol_at()` results are independent copies too. The legacy callback model contains `symbols`, `collapsed`, `kind_set`, `initialized`, `tick`, `source`, `error`, and `lsp_error`; request handles and other private fields are not exposed.

## Events

```text
subscribe(event, callback) -> id      event: "symbols" | "open" | "close" | "mode" | "state" | "*"
unsubscribe(id) -> boolean            false when the id is unknown (e.g. already removed)
```

| Event | When | Payload (plus `event` = the name) |
| --- | --- | --- |
| `symbols` | After each computation phase of any tracked buffer | `bufnr, changedtick, source, error, lsp_error, pending` |
| `open` | An outline was created | `tabpage, mode, winid, bufnr, source_bufnr, focused` |
| `close` | An outline went away | `tabpage, mode, source_bufnr, reason`: `"close"`, `"quit"`, `"window_closed"`, `"tab_closed"`, `"edit_in_outline"`, `"source_deleted"`, `"source_closed"`. On `:tabclose` Neovim closes the outline window (`WinClosed`) before the tab (`TabClosed`), so that close usually reports `"window_closed"`; `"tab_closed"` covers tabs that disappear without that event. Either way the view is gone and exactly one `close` fires. |
| `mode` | An open outline switched layout | `tabpage, from, to, winid, source_bufnr` |
| `state` | Folds or the filter changed | `bufnr, what = "fold" \| "filter", filter, folded` |

Rules:

- Callbacks run synchronously on the main loop, in subscription order. `vim.schedule()` heavy work yourself.
- `open` fires when the view has been created, before its initial `symbols` update. A callback may close or replace the view; subsequent work will not act on the obsolete window. A refresh started by a subscriber supersedes an older computation.
- **Re-entrancy.** If a callback causes another event (for example it calls `set_folded()`), that event is queued and dispatched after the current one has reached every subscriber. Callbacks never nest, and events keep their order.
- **Errors.** A callback that raises is reported with `vim.notify(..., ERROR)` (with a traceback). The other subscribers still run. The same applies to `request_symbols()` callbacks.
- **Unsubscribing** inside a callback is safe. A subscriber removed during a dispatch is not called for that event any more. A subscriber added during a dispatch only receives later events.
- Each subscriber gets its own copy of the payload.

## Examples

Every `lua` block in this section is run by `tests/docs_examples.lua`, which then checks what the block is supposed to do (`sh scripts/test.sh docs`). The examples use only Neovim's standard API. None needs Telescope, Snacks, fzf-lua or lualine.

### Choose sidebar or float

<!-- example: choose-mode -->
```lua
require("qzss").setup({ layout = { mode = "float" } })
-- :Qzss now toggles the float. Keep a key for the sidebar too:
vim.keymap.set("n", "<leader>o", "<cmd>Qzss<cr>", { desc = "Outline (float)" })
vim.keymap.set("n", "<leader>O", function()
  require("qzss").open({ mode = "sidebar" })
end, { desc = "Outline (sidebar)" })
```

### A custom float

A narrow float in the top-right corner of the source window, with a fixed title, some transparency, and `<CR>` keeping it open:

<!-- example: custom-float -->
```lua
require("qzss").setup({
  layout = {
    mode = "float",
    float = {
      relative = "win",
      position = "top-right",
      width = 50, -- cells
      height = 0.6, -- of the window
      max_height = 30,
      border = "single",
      title = " Outline ",
      winblend = 10,
      close_on_jump = false,
    },
  },
})
```

### Your own keymaps

Outline-buffer keys are set with `keymaps` (set a key to `false` to drop it). Global keys can call the API directly:

<!-- example: keymaps -->
```lua
require("qzss").setup({
  keymaps = { float_close = false, close = { "q", "<C-c>" } }, -- keep <Esc> for normal mode in the float
})
vim.keymap.set("n", "<leader>of", function() require("qzss").open({ mode = "float" }) end, { desc = "Outline float" })
vim.keymap.set("n", "<leader>os", function() require("qzss").open({ mode = "sidebar", focus = false }) end, { desc = "Outline sidebar (keep focus)" })
vim.keymap.set("n", "<leader>oz", function() require("qzss").close_all() end, { desc = "Outline: fold all" })
```

### Get symbols and walk the tree: functions into the quickfix list

<!-- example: quickfix -->
```lua
local qzss = require("qzss")
qzss.request_symbols(0, function(err, snap)
  if err then
    return vim.notify("qzss: " .. err, vim.log.levels.WARN)
  end
  local items = {}
  local function walk(list)
    for _, s in ipairs(list) do
      if s.kind == "Function" or s.kind == "Method" then
        table.insert(items, {
          bufnr = s.bufnr,
          lnum = s.pos[1],
          col = s.pos[2] + 1, -- quickfix columns are 1-based
          text = ("%s%s %s%s"):format(string.rep("  ", s.depth), s.kind, s.name, s.detail),
        })
      end
      walk(s.children)
    end
  end
  walk(snap.symbols)
  vim.fn.setqflist({}, " ", { title = "qzss functions", items = items })
end)
```

### A minimal picker with `vim.ui.select`

This works with the built-in `vim.ui.select`. It also works with any plugin that replaces it (dressing, Telescope's ui-select, Snacks, fzf-lua), but none of them is required.

<!-- example: picker -->
```lua
local function pick_symbol()
  local qzss = require("qzss")
  qzss.request_symbols(0, function(err, snap)
    if err then
      return
    end
    local items = {}
    local function walk(list, prefix)
      for _, s in ipairs(list) do
        table.insert(items, { sym = s, label = prefix .. s.name })
        walk(s.children, prefix .. s.name .. " › ")
      end
    end
    walk(snap.symbols, "")
    vim.ui.select(items, {
      prompt = "Symbol",
      format_item = function(it)
        return ("%-10s %s"):format(it.sym.kind, it.label)
      end,
    }, function(choice)
      if choice then
        qzss.jump_to(choice.sym)
      end
    end)
  end)
end
vim.keymap.set("n", "<leader>fs", pick_symbol, { desc = "Pick symbol (qzss)" })
```

### Statusline / winbar breadcrumb

`current_symbol()` reads only the cache, so it is cheap enough for a statusline. The first call on a buffer starts a background request. Redraw on `symbols` events so the breadcrumb appears as soon as the result is ready:

<!-- example: breadcrumb -->
```lua
function _G.qzss_breadcrumb()
  local _, path = require("qzss").current_symbol()
  if type(path) ~= "table" then
    return "" -- "pending", "no symbol", ...
  end
  local names = {}
  for _, s in ipairs(path) do
    table.insert(names, s.name)
  end
  return table.concat(names, " › ")
end
require("qzss").subscribe("symbols", function()
  vim.cmd.redrawstatus()
end)
vim.o.statusline = "%f %{v:lua.qzss_breadcrumb()}%=%l,%c"
```

The same function works in a winbar: `vim.o.winbar = "%{v:lua.qzss_breadcrumb()}"`.

### Jump: next/previous top-level symbol

<!-- example: jump -->
```lua
local function goto_sibling(dir)
  local qzss = require("qzss")
  local snap = qzss.get_snapshot(0)
  if not snap then
    return qzss.request_symbols(0, function() end) -- warm the cache, try again
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local list = snap.symbols
  local first, last = 1, #list
  if dir < 0 then
    first, last = #list, 1
  end
  for i = first, last, dir do
    local s = list[i]
    if (dir > 0 and s.pos[1] > row) or (dir < 0 and s.pos[1] < row) then
      return qzss.jump_to(s)
    end
  end
end
vim.keymap.set("n", "]s", function() goto_sibling(1) end, { desc = "Next symbol" })
vim.keymap.set("n", "[s", function() goto_sibling(-1) end, { desc = "Previous symbol" })
```

### A custom UI kept up to date by events

A scratch buffer that lists the top-level symbols of the last updated buffer. It never opens the qzss outline. Edits update it through the `symbols` event:

<!-- example: custom-ui -->
```lua
local qzss = require("qzss")
local list_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(list_buf, "qzss-symbols")

local function redraw(bufnr)
  local snap = qzss.get_snapshot(bufnr)
  if not snap or not vim.api.nvim_buf_is_valid(list_buf) then
    return
  end
  local lines = {}
  for _, s in ipairs(snap.symbols) do
    table.insert(lines, ("%-10s %s"):format(s.kind, s.name))
  end
  vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, lines)
end

local sub = qzss.subscribe("symbols", function(ev)
  if not ev.pending then
    redraw(ev.bufnr)
  end
end)
qzss.request_symbols(0, function(_, snap)
  if snap then
    redraw(snap.bufnr)
  end
end)
-- stop updating when the list buffer is wiped
vim.api.nvim_create_autocmd("BufWipeout", {
  buffer = list_buf,
  once = true,
  callback = function()
    qzss.unsubscribe(sub)
  end,
})
```

### Filter: a "types only" toggle

<!-- example: filter -->
```lua
vim.keymap.set("n", "<leader>ot", function()
  local qzss = require("qzss")
  if qzss.get_filter() then
    qzss.set_filter(nil)
  else
    qzss.set_filter({ "Class", "Interface", "TypeAlias", "Struct", "Enum", "Trait" })
  end
end, { desc = "qzss: toggle types-only filter" })
```

### Folds: open the outline focused on the cursor's symbol

<!-- example: focus-fold -->
```lua
local qzss = require("qzss")
local _, path = qzss.current_symbol()
qzss.close_all()
for _, s in ipairs(type(path) == "table" and path or {}) do
  if #s.children > 0 then
    qzss.set_folded(s.id, false)
  end
end
qzss.open({ mode = "float" })
```

### React to the outline opening or closing

<!-- example: events -->
```lua
local qzss = require("qzss")
qzss.subscribe("open", function(ev)
  vim.notify(("qzss: %s opened in tab %d"):format(ev.mode, ev.tabpage))
end)
qzss.subscribe("close", function(ev)
  vim.notify(("qzss: %s closed (%s)"):format(ev.mode, ev.reason))
end)
```

## Versioning and compatibility

- `require("qzss").api_version` is `1`. It changes only when the documented API changes incompatibly: a function, argument, field or event is removed, or its meaning changes. Such a change is listed in the release notes.
- New optional arguments, fields, events and functions can be added in any release, so do not reject unknown fields. Event payloads can grow too.
- Everything that existed before API version 1 still works. That includes the commands, `setup()` options, `open({ focus })`, `close`, `toggle`, `refresh`, `set_filter`, `info`, `is_open`, `get_symbols`, `outline_lines` and the row actions. The default layout is still the sidebar.
- Private modules, `_`-prefixed fields such as `_state`, the outline buffer's contents and its highlight extmarks are not part of the API.
- Requires Neovim 0.11 or newer. There are no runtime dependencies.
