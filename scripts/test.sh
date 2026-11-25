#!/usr/bin/env sh
# Run every qzss.nvim test suite. Prerequisites (once):
#   sh scripts/bootstrap.sh   # Tree-sitter parsers + rust-analyzer into .deps/
#   npm ci                    # typescript + typescript-language-server
# Usage: sh scripts/test.sh [unit|edge|readme|lsp|tui|help|images|api|docs|scenarios]...
# Default: every suite except `scenarios`, which needs the kenshu-loop terminal
# driver: KENSHU_CLI=/path/to/kenshu-loop/skills/kenshu-loop/scripts/kenshu-loop.mjs
set -eu
cd "$(dirname "$0")/.."
suites=${*:-unit edge readme lsp tui help images api docs}
status=0
for s in $suites; do
  echo "== $s"
  case $s in
    unit) nvim --clean --headless -l tests/run.lua || status=1 ;;
    edge) nvim --clean --headless -l tests/edge_cases.lua || status=1 ;;
    readme) nvim --clean --headless -l tests/readme_examples.lua || status=1 ;;
    lsp) nvim --clean --headless -l tests/lsp_e2e.lua || status=1 ;;
    tui) bash tests/tui_e2e.sh || status=1 ;;
    images) node scripts/check-readme-images.mjs || status=1 ;;
    api)
      nvim --clean --headless -l tests/api_spec.lua || status=1
      nvim --clean --headless -l tests/api_async_spec.lua || status=1
      nvim --clean --headless -l tests/api_lifecycle_spec.lua || status=1
      nvim --clean --headless -l tests/api_bootstrap_spec.lua || status=1
      ;;
    docs) nvim --clean --headless -l tests/docs_examples.lua || status=1 ;;
    scenarios)
      if [ -z "${KENSHU_CLI:-}" ] || [ ! -f "$KENSHU_CLI" ]; then
        echo "FAIL scenarios: set KENSHU_CLI to kenshu-loop.mjs (not run)"; status=1
      else
        out=$(mktemp -d)
        for f in tests/tui/*.json; do
          n=$(basename "$f" .json)
          if node "$KENSHU_CLI" term run-scenario "$f" --cwd . --out "$out/$n" > "$out/$n.log" 2>&1; then
            echo "ok   scenario $n"
          else
            echo "FAIL scenario $n (see $out/$n.log)"; status=1
          fi
        done
      fi
      ;;
    help)
      tmp=$(mktemp -d)
      cp -R doc "$tmp/doc"
      if nvim --clean --headless -c "helptags $tmp/doc" -c 'qa!' 2>&1 | grep -q .; then
        echo "FAIL helptags reported errors"; status=1
      elif ! grep -q '^qzss-commands' "$tmp/doc/tags"; then
        echo "FAIL qzss-commands tag missing"; status=1
      else
        echo "ok   doc/qzss.txt helptags"
        # `:help qzss` (named by the ? popup and README) must open the top of
        # the file; other documented tags must resolve too.
        for t in qzss qzss-commands :QzssFilter qzss-limitations qzss-api qzss-float :QzssFloat :QzssSidebar qzss.request_symbols\(\); do
          r=$(nvim --clean --headless --cmd "set rtp^=$tmp" -c "help $t" \
            -c 'lua io.stdout:write(vim.fn.expand("%:t")..":"..vim.fn.line("."))' -c 'qa!' 2>&1 | tail -1)
          case "$t:$r" in
            qzss:qzss.txt:[1-9]|qzss:qzss.txt:10) echo "ok   :help $t -> $r (top of file)" ;;
            qzss:*) echo "FAIL :help qzss -> $r (want qzss.txt line 1-10)"; status=1 ;;
            *:qzss.txt:*) echo "ok   :help $t -> $r" ;;
            *) echo "FAIL :help $t -> $r"; status=1 ;;
          esac
        done
      fi
      [ -e doc/tags ] && { echo "FAIL doc/tags written into the repo"; status=1; }
      rm -rf "$tmp"
      ;;
    *) echo "unknown suite: $s" >&2; exit 2 ;;
  esac
done
exit $status
