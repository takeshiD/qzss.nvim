#!/usr/bin/env sh
# Build the Tree-sitter parsers used by tests/demos into .deps/site/parser.
# Runtime users normally get parsers from nvim-treesitter or their distro instead.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEPS="$ROOT/.deps"
SRC="$DEPS/src"
OUT="$DEPS/site/parser"
CC=${CC:-cc}
mkdir -p "$SRC" "$OUT"

fetch() { # name url rev
  if [ ! -d "$SRC/$1/.git" ]; then
    git clone --quiet --filter=blob:none "$2" "$SRC/$1"
  fi
  git -C "$SRC/$1" -c advice.detachedHead=false checkout --quiet "$3"
}

build() { # lang dir
  d="$2/src"
  files="$d/parser.c"
  [ -f "$d/scanner.c" ] && files="$files $d/scanner.c"
  # shellcheck disable=SC2086
  $CC -O2 -fPIC -shared -I"$d" $files -o "$OUT/$1.so"
  echo "built $OUT/$1.so"
}

fetch tree-sitter-rust https://github.com/tree-sitter/tree-sitter-rust v0.24.0
fetch tree-sitter-typescript https://github.com/tree-sitter/tree-sitter-typescript v0.23.2
fetch tree-sitter-json https://github.com/tree-sitter/tree-sitter-json v0.24.8
fetch tree-sitter-yaml https://github.com/tree-sitter-grammars/tree-sitter-yaml v0.7.0

build rust "$SRC/tree-sitter-rust"
build typescript "$SRC/tree-sitter-typescript/typescript"
build tsx "$SRC/tree-sitter-typescript/tsx"
build json "$SRC/tree-sitter-json"
build yaml "$SRC/tree-sitter-yaml"

# rust-analyzer for the real-LSP E2E test. A rustup proxy on PATH does not work
# in an isolated HOME, so fetch the pinned standalone release unless a working
# binary is provided through QZSS_RUST_ANALYZER.
RA_TAG=${QZSS_RA_TAG:-2026-11-23}
mkdir -p "$DEPS/bin"
if [ -n "${QZSS_RUST_ANALYZER:-}" ]; then
  echo "using QZSS_RUST_ANALYZER=$QZSS_RUST_ANALYZER"
elif [ -x "$DEPS/bin/rust-analyzer" ] && "$DEPS/bin/rust-analyzer" --version >/dev/null 2>&1; then
  echo "rust-analyzer present: $("$DEPS/bin/rust-analyzer" --version)"
else
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) RA_ASSET=rust-analyzer-x86_64-unknown-linux-gnu.gz ;;
    Linux-aarch64) RA_ASSET=rust-analyzer-aarch64-unknown-linux-gnu.gz ;;
    Darwin-arm64) RA_ASSET=rust-analyzer-aarch64-apple-darwin.gz ;;
    Darwin-x86_64) RA_ASSET=rust-analyzer-x86_64-apple-darwin.gz ;;
    *) echo "no rust-analyzer asset for this platform; set QZSS_RUST_ANALYZER" >&2; exit 1 ;;
  esac
  curl -fsSL "https://github.com/rust-lang/rust-analyzer/releases/download/$RA_TAG/$RA_ASSET" | gunzip > "$DEPS/bin/rust-analyzer"
  chmod +x "$DEPS/bin/rust-analyzer"
  echo "installed $("$DEPS/bin/rust-analyzer" --version)"
fi
