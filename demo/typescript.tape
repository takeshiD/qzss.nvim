# TypeScript/TSX with the real typescript-language-server attached (treesitter+lsp).
Output docs/images/typescript.gif
Source demo/common.tape
Type "QZSS_LSP=1 nvim --clean -u tests/minimal_init.lua tests/fixtures/ts/sample.ts" Enter
Sleep 2s
Show
Type ":Qzss" Enter
Sleep 4s
Screenshot docs/images/typescript.png
Type ":QzssFilter Interface TypeAlias" Enter
Sleep 1.5s
Screenshot docs/images/typescript-filter.png
Type ":QzssFilter" Enter
Sleep 500ms
Type ":e tests/fixtures/ts/view.tsx" Enter
Sleep 4s
Screenshot docs/images/tsx.png
