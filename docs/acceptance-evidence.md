# Acceptance evidence (contractor, round 1)

Environment: NixOS Linux, Neovim 0.12.6, Node 24.22.2, tmux. All runs below were done in a **fresh copy** of the deliverable. `.deps`, `node_modules` and `.git` were excluded and `HOME` was an empty temporary directory.

## Setup

```sh
sh scripts/bootstrap.sh   # builds rust/typescript/tsx/json/yaml parsers, downloads rust-analyzer 2026-11-23
npm ci                    # typescript 5.9.3, typescript-language-server 5.1.3
```

## Results

| Suite | Command | Result |
| --- | --- | --- |
| unit | `sh scripts/test.sh unit` | 139 passed, 0 failed |
| edge (review regressions) | `sh scripts/test.sh edge` | 11 passed, 0 failed (was 4 pass / 5 fail, then 9/2 after the plain-YAML additions) |
| readme examples | `sh scripts/test.sh readme` | 46 passed, 0 failed |
| real LSP | `sh scripts/test.sh lsp` | 24 passed, 0 failed (rust-analyzer + typescript-language-server) |
| tmux TUI | `sh scripts/test.sh tui` | 25 passed, 0 failed |
| help tags | `sh scripts/test.sh help` | ok |
| README images | `sh scripts/test.sh images` | all checks passed |
| PTY scenarios | `kenshu-loop term run-scenario tests/tui/<name>.json --cwd . --out <dir>` | customization, data-json-yaml, lsp-unicode-jump, rust-impl-fold-jump, typescript-kinds-filter: all pass |

## Review-note resolutions

1. **Whitespace inside literal content.** `squash()` in `lua/qzss/backends/treesitter.lua` now collapses only formatting whitespace outside string literals (`"`, plus `'` and `` ` `` outside Rust, where `'` starts a lifetime). For YAML, keys and scalars are content, so only line breaks are folded, as YAML line folding does. Interior spaces of plain scalars are kept. Regressions are in `tests/edge_cases.lua` and in the "literal whitespace" block of `tests/run.lua`.
2. **LSP UTF-16/UTF-32 offsets.** `backends/lsp.lua` converts every `character` with `vim.str_byteindex` against the source line, using the responding client's `offset_encoding`. Covered by unit tests for utf-8/16/32 and clamping, by the real-tsserver jump in `tests/edge_cases.lua`, and by the PTY scenario `tests/tui/lsp-unicode-jump.json` (cursor byte column 33 on `target`).
3. **Kind-label contrast.** `QzssKindLabel` now uses the colorscheme's `Comment` foreground in italics instead of `NonText`. It is re-derived on `:colorscheme`, and user overrides still win (tests in `tests/run.lua`). The images were regenerated and `scripts/check-readme-images.mjs` asserts that the labels are italic and not NonText grey.
4. **Found during PTY testing:** `:edit` with focus in the sidebar raised `Invalid buffer id` from a BufEnter handler. The file now opens in the source window and the sidebar is rebuilt (test in `tests/run.lua`, scenario `typescript-kinds-filter`).

## Images (real PTY captures)

`docs/images/terminal-{rust-expanded,typescript,tsx,json,yaml,rust-folded,custom-ascii}.png`. Next to each is the raw screen/style JSON and an SVG. Regenerate with:
`KENSHU_CLI=/path/to/kenshu-loop.mjs node scripts/capture-terminal.mjs` (about 7 s).

## Known limitations

- Rust macro-generated items are not shown.
- Only the first LSP client with documentSymbol is queried.
- Under the default Neovim colorscheme, `Type`/`Structure`/`Typedef` share one colour. Class, interface and type alias then differ by icon, label, highlight group and filter, but not by colour. Most colorschemes do colour them differently.
- On a narrow sidebar the winbar keeps `qzss · <file>` and cuts the tail (source, filter, help hint).
- The CI workflow has not been run on GitHub yet. Publishing is the parent's step.
- `order.json` and `docs/parent-review-notes.md` are process artifacts. The parent may drop them before publishing.

## Round 2 rework

| Inspector item | Fix | Evidence |
| --- | --- | --- |
| `:q` left an orphan sidebar | `QuitPre` closes the sidebar before the last source window quits. A `WinClosed` fallback closes the tab, or quits, when only the sidebar is left (`:close`, `:q!`). A modified buffer still gets E37 and the layout is kept. | REG1; `tests/tui/sidebar-lifecycle.json`; tab and `:close` tests in `tests/run.lua` |
| Narrow terminal crushed the source to 1 column | Sidebar width is clamped to `max(columns - 30, columns / 2)` on open and render, and re-applied on `VimResized`. The winbar truncates after the file name (`%<`) so `qzss · file` stays visible. | REG2; `sidebar-lifecycle` (50, 120 and 40 columns); `data-json-yaml` now asserts source width ≥ 30 at 70 columns; `_fit_width` unit tests |
| `:help qzss` opened mid-file | `*qzss*` tag on line 1. `tests/minimal_init.lua` builds tags for a temporary copy, so `:help` works in trials without writing `doc/tags`. The help suite asserts `:help qzss` lands on line 1–10, that other tags resolve, and that `doc/tags` is not created. | `sh scripts/test.sh help` |
| LSP-only TS kinds degraded to var/const | `lsp.refine_kinds` uses the TS/TSX parser (when installed) at each symbol name to restore TypeAlias, Interface and EnumMember. LSP-only results are sorted into source order. README and help document the behaviour without a parser. | `sh scripts/test.sh lsp` (34/0, new "ts LSP-only" assertions); `tests/tui/lsp-only-ts-kinds.json` |

Round-2 results in a fresh copy with an empty HOME, after bootstrap and npm ci: unit 146/0, edge 11/0, readme 46/0, lsp 34/0, tui 25/0, help ok (`:help qzss` → line 1), images ok. All 7 `tests/tui/*.json` scenarios pass, as do REG1 and REG2. The follow-ups (nearest-column cursor follow, `[+N]` position, rust-analyzer workspace log line) are not addressed this round.
