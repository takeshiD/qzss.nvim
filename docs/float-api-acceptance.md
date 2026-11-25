# Float layout and public Lua API: acceptance record

Order: "qzss.nvim — floating outline and stable public Lua API" (kenshu-loop, requirement version 594e53a0c315871a). Base: `main` c533126b940179cf340a40ff6f84dc4931e87195. The previous round's record stays in [acceptance-evidence.md](acceptance-evidence.md).

This file records the contractor's decisions and test results. The independent acceptance verdict and the publish step (push to `main`, remote SHA, CI run) are the parent's steps. **They had not been run when this file was written.** The parent appends their results below.

## Architecture

```
plugin/qzss.lua ──► require("qzss")  (init.lua: facade = qzss.api + legacy helpers)
                          │
outline keymaps ─────► qzss.api  ◄── external plugins
                          │  (public use cases: open/close/toggle, symbols, jump_to, folds, filter, events)
                ┌─────────┼──────────┐
             qzss.view  qzss.model  qzss.events
          (sidebar/float (per-buffer symbols, (subscribe/emit,
           windows, one   folds, filter,      queue, error
           renderer)      async requests)     isolation)
                          │
                 qzss.render, qzss.backends.{treesitter,lsp}
```

- **No cycles.** `api` requires `view`, `model` and `events`. `view` requires `model`. `model` requires neither. `model` tells views to re-render through a hook (`model.on_update`) that `view` sets. The keymaps are installed by `api` (`map_keys`), so every key calls a public function, and the commands in `plugin/qzss.lua` call `require("qzss")`.
- **One model, one renderer.** Symbols, `collapsed` and `kind_set` live in `model.models[bufnr]`. The sidebar and the float are the same per-tab view object (`mode` = "sidebar" | "float") and are drawn by the same `view.render()`. Switching modes opens a new window on the **same outline buffer** and closes the old one. Buffer, keymaps, cursor row, folds and filter therefore carry over with no copying.

## Decisions and why

| Topic | Decision | Reason |
| --- | --- | --- |
| Float options | Nested in `layout.float`. Defaults follow the order: `relative="editor"`, `width=0.5`, `height=0.8`, `position="center"`, `border="rounded"`, `winblend=0`. Added `min_width=20`, `min_height=5`, `max_*`, `row`/`col`, `title`, `title_pos`, `zindex`. | `layout.width`/`position` already mean sidebar things, so nesting avoids reusing a name with a different meaning. |
| Size semantics | `>= 1` means cells (floored). `(0, 1)` is a fraction of the reference. The size is the content size without the border. The order is min/max, then fit inside the reference. Fitting wins over `min_*`. | Mirrors `nvim_open_win` (content size) and the usual float-plugin convention. A float must never go off screen on a narrow terminal (order R1). |
| `relative="win"` | The reference is the outline's source window. The float follows `WinResized`. If the window is gone it falls back to the editor. | Lets users put the outline in a corner of the code window. |
| Title/footer | The border title shows `qzss · file`. The footer shows source, filter and `? help`, truncated with `…`. With no border, a winbar is used. | The float has no winbar slot the way the sidebar does. The title keeps the file visible. |
| `close_on_jump` | Global `close_on_jump` (default `false`) applies to the sidebar as before. The float uses `layout.float.close_on_jump` (default **true**). `"global"` follows the global value. An explicitly supplied global value is inherited unless the float has an explicit override. | A centred float covers the code you jump to. Existing sidebar behaviour is unchanged. Documented in docs/api.md and `:help qzss-float`. |
| `<Esc>` | Closes only the float (`keymaps.float_close`, can be set to `false`). It is unmapped when switching back to the sidebar. | `<Esc>` is the usual way to dismiss a float. In the sidebar it keeps its normal meaning. |
| `:Qzss` | Toggles: closes an open outline in either mode, else opens `layout.mode`. `:QzssOpen` keeps the current mode when already open. `:QzssFloat` / `:QzssSidebar` open or switch, and `!` keeps focus. | Matches order R2. `:QzssOpen!` stays compatible. |
| `:edit` inside the outline | Sidebar: rebuilt as before. Float: closed, and the file opens in the source window. | Re-opening a float over the file you just opened would hide it. |
| Source buffer unloaded or wiped | The view retargets to the buffer now shown in its source window, or closes with reason `source_deleted`. Pending requests fail with `buffer deleted`/`buffer unloaded`. The decision is made after the command finishes. | `:write name` on an unnamed buffer fires `BufUnload` for a buffer that stays loaded. Deciding immediately would close the outline by mistake. |
| Public symbol shape | New, separate fields: `pos = {row1, col0}` and `range` with an exclusive end, plus `id`, `parent_id`, `depth`, `bufnr`, `children`. The legacy `get_symbols()` keeps its internal 0-based `lnum` and `parent` links. | Cursor-API compatible (`nvim_win_set_cursor(0, sym.pos)`). Separate names avoid two meanings for `lnum`. The tree is plain, with no back-links, so it can be copied and serialised. |
| Snapshot vs request | `get_snapshot()` reads the cache only and never computes. `request_symbols()` is always asynchronous and resolves exactly once (or never, after `cancel()`). | Statuslines need a cheap read. Pickers need fresh data. Callbacks that are sometimes synchronous are a classic re-entrancy bug. |
| Staleness | Each computation carries a generation number and the `changedtick`. An LSP answer for outdated text is dropped and the computation restarts. Requests at the same tick share one computation. | Order R7. Verified with a deterministic in-process server and with real rust-analyzer/tsserver. |
| Tracking | A buffer is tracked once it has been requested or shown. Tracked buffers refresh on edits, writes and `LspAttach`. | UI-less consumers stay current without paying for untracked buffers. |
| Errors | Wrong argument types raise `qzss.<fn>: …`. Runtime conditions return `nil/false, "reason"` or pass `err` to the callback. Invalid `setup()` layout raises and keeps the old configuration. | Programming errors should be loud. State (a deleted buffer, nothing cached yet) is normal and must not throw inside a statusline. |
| Events | `symbols`, `open`, `close`, `mode`, `state`, `*`. Emits from inside a callback are queued (FIFO). Errors go to `vim.notify` with a traceback. Payloads are deep-copied per subscriber. | Order R10. Callbacks never nest, and one bad subscriber cannot break the others. |
| Compatibility | `require("qzss")` keeps every old function. `_state.sidebars`/`_state.bufs` still exist, because existing tests use them. `api_version = 1`. Additions are allowed without a bump. | Order R2/R6/R11. |
| Sidebar creation | `botright vertical Nsplit` from a normal window, then set the outline buffer. | `nvim_open_win({split=..., win=-1})` was tried first. The resulting state made a later headless test crash inside Neovim. The `:vsplit` path is what the previous release used. |

## Test results (contractor)

Machine: NixOS, Neovim **0.12.6** and **0.11.5** (`.deps/nvim-compat`), Node 24.22.2, tmux, rust-analyzer 2026-11-23, typescript-language-server 5.1.3.

| Suite | 0.12.6 | 0.11.5 |
| --- | --- | --- |
| unit (`tests/run.lua`, unchanged legacy behaviour) | 146 / 0 | 146 / 0 |
| edge | 11 / 0 | 11 / 0 |
| readme (setup examples, incl. the new float/API blocks) | 60 / 0 | 60 / 0 |
| lsp (real rust-analyzer + tsserver, incl. 12 new API checks) | 47 / 0 | 47 / 0 |
| tui (tmux, incl. 13 new float checks) | 38 / 0 | 38 / 0 |
| help (incl. `qzss-api`, `qzss-float`, `:QzssFloat`, `:QzssSidebar`, `qzss.request_symbols()`) | ok | ok |
| images (9 PNGs + raw JSON + SVG) | all passed | n/a (static files) |
| api (`api_spec` + `api_async_spec`) | 280 / 0 + 20 / 0 | 280 / 0 + 20 / 0 |
| docs (all examples in docs/api.md, README, `:help qzss-api`) | 139 / 0 | 139 / 0 |
| scenarios (11 real-PTY `tests/tui/*.json`, kenshu-loop driver) | 11 / 11 pass | 11 / 11 pass |

Fresh-copy run: a copy of the deliverable (tracked + untracked, not ignored) with `HOME` set to an empty directory ran `sh scripts/bootstrap.sh`, `npm ci` and then every suite including `scenarios`. The result is listed in the delivery note's self-check.

## Known limitations

- The float has a fixed configured size. It does not shrink to its content like the sidebar does.
- One outline per tabpage. Only the first `documentSymbol` client is asked, with an 8 s timeout.
- `cancel()` drops the callback. The computation and its LSP request still finish and fill the cache.
- Under the default colorscheme some kinds share a colour (unchanged from round 1).
- The `scenarios` suite needs the kenshu-loop terminal driver, so it is not in GitHub CI. CI runs the tmux TUI suite, which now covers the float.
- **A Neovim bug found while testing, not in qzss:** in headless mode, changing `'columns'`, then closing a vertical split that had a winbar, then redrawing, aborts the local Neovim 0.12.6 and 0.11.5 builds with `double free or corruption` (`grid_alloc` ← `msg_grid_validate`). The reproducer is `tests/upstream/nvim-headless-winbar-crash.lua` and does not load qzss. As a result, `tests/docs_examples.lua` keeps the headless default 80x24, and the in-process-LSP tests run in their own process (`tests/api_async_spec.lua`). LSP detach handlers call `nvim__redraw`, which also hits this bug. The crash was not seen in any real-terminal (PTY/tmux) run.

## Round 2 rework (inspector findings of round 1)

| Finding | Fix | Evidence |
| --- | --- | --- |
| `cancel()` returned false and the callback still ran for cache hits and Tree-sitter-only results: `done` was set when the result was scheduled, not when it was delivered | `model.request` sets `done` only inside the scheduled delivery. Until then `cancel()` returns true and the callback is skipped. A second `cancel()`, or one after delivery, returns false. | REG1; `api_spec` "contract: cancel() ..." (uncomputed, cache hit, after delivery) |
| Buffer deleted between resolution and delivery gave `err=nil` and a snapshot of the dead buffer | Delivery re-checks the buffer: if it is invalid → `"buffer deleted"`, if unloaded → `"buffer unloaded"`, and the snapshot is `nil` | REG2; `api_spec` "contract: delete/bunload/bwipeout before delivery" |
| `Symbol.source` was nil on Tree-sitter symbols although documented | `public_tree` fills `source` for every symbol: `"treesitter+lsp"` when an LSP symbol matched, else `"treesitter"`, or `"lsp"` for LSP-only outlines. The docs, `:help` and the type annotation say "always set". | REG3; `api_spec` (22/22 symbols), `api_async_spec` (LSP-only → `"lsp"`), `lsp_e2e` (matched → `"treesitter+lsp"`) |
| Tests only covered the LSP-pending path | New contract section in `tests/api_spec.lua`, run by C1 | `sh scripts/test.sh api` |
| Follow-up: a focused float started on the top row | `open()` puts the outline cursor on the symbol under the source cursor in both modes, focused or not | `api_spec` "focused float opens on the symbol under the source cursor" |
| Follow-up: long messages were cut at the float edge | A message row (no symbols) wraps; symbol rows still do not | `api_spec` "a message row wraps inside the float" |

## Round 3 rework

| Finding | Fix | Evidence |
| --- | --- | --- |
| Wrong-type errors carried a `…/lua/qzss/api.lua:NNN:` prefix (error level 3 pointed into qzss's own validator), contradicting "starts with `qzss.<function>:`" | `argerr` raises with level 0, so the message is exactly `qzss.<function>: …`. The docs state "no `file:line:` prefix". | REG4; `api_spec` section "wrong-type errors (round 3)": 26 calls across 18 public functions plus a check that the message does not mention api.lua |
| Follow-up: sidebar winbar `%<` truncation marker | Not changed. The marker shows where Neovim truncated the narrow winbar; changing the layout would alter screen text that accepted criterion C6 asserts. Left as a known cosmetic limitation. | — |

## Independent acceptance and publication (parent)

_Not run yet at the time of writing. To be filled in by the parent process: acceptance verdict and findings, rework rounds, final test results, pushed commit SHA, remote URL and CI run result._

## Parent review after the first acceptance cycle

The first kenshu-loop cycle ended **accepted in round 3**, after two rework
rounds. Its final identity was order `594e53a0c315871a`, deliverable
`fa91439bc3e7eb2700fbcb79`, criteria `0bac946287f6bbd1`. The runner checked
C1–C10 and REG1–REG4 in an isolated checkout; C11/C12 received independent
review. The records are preserved locally under
`.research/float-api-cycle1/` (the earlier plugin acceptance remains separately
preserved under `.research/previous-acceptance/`). This verdict predates the
following parent fixes and is **not** a verdict for the changed files.

Additional reproduced boundary cases were fixed before publication:

- Legacy `compute()` callback models and `symbol_at()` results now contain
  independent copies. Historical field names/coordinates remain compatible;
  internal request handles are not exposed through the legacy model.
- An explicitly configured global `close_on_jump` is inherited by floats unless
  a float-specific override is supplied. `layout.float.close_on_jump = "global"`
  expresses inheritance explicitly; a Lua `nil` cannot remove a merged default.
  With neither setting supplied, the existing sidebar stays open and the new
  float closes on jump. This preserves existing explicit settings while keeping
  the float's documented dismissal default.
- Closing the source externally while a window-relative float has focus now
  retargets and reanchors within that tab, without stealing focus. A remaining
  window showing the same buffer is preferred; otherwise another normal source
  window is used. With no source left, the float closes.
- `open` precedes the initial `symbols` event. Callbacks can close/replace a
  view, including during a mode change, without later work using its dead window.
  A reentrant refresh cannot let an older generation finish a newer request.
- `current_symbol()` initializes tracking when it is the first API used, so a
  statusline-only consumer receives fresh data after edits without calling setup.
- Request snapshots recompute `stale` immediately before delivery. This also
  resolves the final inspector's follow-up from the first cycle.

The new regression suites are `tests/api_lifecycle_spec.lua` (25 assertions)
and `tests/api_bootstrap_spec.lua` (3 assertions), both in the `api` suite and CI.
`tests/tui/float-external-source-close.json` exercises the repaired anchor in a
real PTY (26 operations); the same path is also in the CI tmux suite.
A second real kenshu-loop cycle will inspect this exact updated implementation.
Its verdict and the final publication result are still pending at this point.

Parent validation before the final cycle (both Neovim 0.12.6 and 0.11.5):
unit 146, edge 11, README 60, real LSP 47, API 280 + async 20 + lifecycle 25 +
bootstrap 3, docs examples 139; help and image checks passed. The added tmux
case initially sent Escape through a generic command helper, closing its test
float before inspecting it; the driver was corrected to send commands directly
while the float has focus. The corrected tmux suite passed **42/42** on both
versions. All 12 kenshu PTY scenarios passed on 0.12.6; the 0.11.5 scenario run
is recorded in `.research/parent-scenarios-011.log`.

The final order version is `0a83997a581a5983`. Its runner state will be in the
fresh `.kenshu/` directory; no old verdict or regression file was edited.

## Final cycle — contractor self-check (order `0a83997a581a5983`, round 1)

The contractor changed no implementation files in this round. It ran the
complete deliverable again on the local machine (NixOS, Node 24.22.2, tmux):

| Suite | Neovim 0.12.6 | Neovim 0.11.5 (`.deps/nvim-compat`, first on PATH) |
| --- | --- | --- |
| unit | 146/146 | 146/146 |
| edge | 11/11 | 11/11 |
| readme | 60/60 | 60/60 |
| lsp (real rust-analyzer + typescript-language-server) | 47/47 | 47/47 |
| api (contract / async / lifecycle / bootstrap) | 280 + 20 + 25 + 3 | 280 + 20 + 25 + 3 |
| docs examples | 139/139 | 139/139 |
| help tags | pass | pass |
| README images | all checks passed | all checks passed |
| tui (tmux) | 42/42 | 42/42 |
| kenshu PTY scenarios | 12/12 | 12/12 |

An extra PTY scenario (the delivery's criterion C13) checks three things in one
session with `layout.mode = "float"`. First, `request_symbols()` returns symbols
while no UI is open. Then `:Qzss` toggles the float open and closed, and `q`
also closes it. Finally, no window is left behind. It passed. The logs are in
`.research/final-cycle-contractor-{012,011}.log` (local only; `.research/` is
not published).
The independent acceptance verdict and the parent's push/CI result for this
final cycle are **not** recorded here yet. They come after this point.

## Final cycle — round 2 rework (reload of the same buffer)

**Finding (inspector, round 2, R5/R3).** Start Neovim without a file, open the
outline, then `:edit file` in the source window. Neovim reuses the empty
`[No Name]` buffer under the same bufnr, so the `BufEnter` handler (which only
retargets when the buffer *number* changes) did nothing. The outline (sidebar
and float) kept showing `[No Name] · no source` until the next edit or
`:QzssRefresh`. Nothing refreshed a tracked buffer on `BufReadPost`,
`BufFilePost` or `FileType`.

**Fix.** `lua/qzss/api.lua` adds `reload_refresh()`. It runs on `BufReadPost`,
`BufFilePost` and `FileType` (except `qzss`). If an outline shows the buffer, or
the buffer is tracked by API use, it is recomputed on the next main-loop tick.
That tick comes after filetype detection, and there is no `update_delay`. A
pending debounced refresh is superseded rather than run twice. Untracked
buffers still cost nothing. This also covers `:edit!` after an outside change,
`:file newname`, and `:set filetype=`. Documented in `docs/api.md` (tracking
rules) and `:help :QzssRefresh`.

**Tests.**
- `tests/api_lifecycle_spec.lua` adds 21 assertions (25 → 46), for sidebar,
  float and API-only (no UI) use. Each checks that `:edit` reused the bufnr, that
  symbols are recomputed with no edit, that no stale error is left, that a
  `symbols` event fires, and that the outline buffer shows the file's symbols.
  It also checks recomputation when the filetype is cleared and set again.
  With the fix disabled, 12 of the new assertions fail.
- `tests/tui/reload-same-buffer.json` is a new real-PTY scenario (38 steps).
  It covers the inspector's flow (sidebar `[No Name]` → `:e lib.rs`, float →
  `:e sample.ts`) plus clearing and restoring the filetype. There are now 13
  PTY scenarios.

**Follow-up taken (docs only).** `:tabclose` of a tab with an outline reports
the close reason `"window_closed"`. The outline window's `WinClosed` fires
before `TabClosed`. `docs/api.md` now states this, and that exactly one `close`
event fires. This was checked headless for float and sidebar.

**Results (contractor, local).** On Neovim 0.12.6 and 0.11.5: unit 146, edge
11, readme 60, real LSP 47, api 280 + async 20 + lifecycle 46 + bootstrap 3,
docs 139, help and images pass, tmux 42/42, kenshu PTY scenarios 13/13. The
inspector's regression scenario (REG1) passes on both versions. The logs are in
`.research/final-cycle-r3-{012,011}.log` (local only). The independent verdict
and the parent's push/CI are still pending.

## Final independent verdict and release validation

**Accepted**, final cycle round 3. Across both actual kenshu-loop cycles there
were six rounds, including implementation rework, criteria correction and
independent reinspection. Final order: `0a83997a581a5983`; deliverable:
`494319f6dd299f1bf80b3e3f`; criteria: `b9b6c842df55cdc0`.
The final independent trial had 18 scenarios and no failures. C1–C17,
C21–C22 and REG1 passed in the fresh verification environment; C18–C20
received independent technical review. Raw local records: `.kenshu/DELIVERY.md`,
`.kenshu/rounds/003/{trial,verdict,verification}.json`.

The parent independently reran every suite, including all 13 real PTY scenarios,
on both Neovim 0.12.6 and 0.11.5: both full commands exited 0. Logs:
`.research/release-all-012.log` and `.research/release-all-011.log`.
No implementation changed after this verdict; this release record was appended.

Publication target: https://github.com/takeshiD/qzss.nvim (main). The parent
will use a normal push, verify the remote SHA, and report the exact commit
and GitHub CI result in the delivery response. Author and committer are
`takeshiD`, using the pre-existing repo-local email.

## Publication receipt

The accepted implementation was published to `origin/main` with a normal
(non-force) push as commit
[`75be428a2c9ea61d37e4a3231bbd3bc1b4bbd937`](https://github.com/takeshiD/qzss.nvim/commit/75be428a2c9ea61d37e4a3231bbd3bc1b4bbd937).
`git ls-remote origin refs/heads/main` returned that exact SHA. Both author and
committer are `takeshiD`, using the unchanged repo-local email.

[GitHub Actions run 45548870140](https://github.com/takeshiD/qzss.nvim/actions/runs/45548870140)
completed successfully for **v0.11.5, stable and nightly**. The published float
PNG was also fetched from GitHub at that commit (190831 bytes).
This receipt is a documentation-only follow-up commit; no implementation,
test, API contract or screenshot changed after acceptance.

Non-blocking limitations remain as documented: one outline per tab, the first
eligible LSP client only, an 8-second LSP timeout, and cancellation suppresses
the callback rather than stopping the shared computation. The independently
reproduced Neovim headless winbar/resize crash is isolated from the test suites;
real PTY runs passed. Cosmetic folded-count placement can still put `[+N]`
before a generic suffix. In event callbacks, pass the payload's source buffer
explicitly to `get_snapshot` (`ev.bufnr` for `symbols`, `ev.source_bufnr` for
view events), since its default is the current buffer.
