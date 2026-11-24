#!/usr/bin/env bash
# Real terminal UI E2E: drives Neovim + qzss inside tmux and asserts on the
# visible screen after each interaction. No mocks; waits poll the screen.
# Usage: tests/tui_e2e.sh            (needs nvim, tmux and scripts/bootstrap.sh run)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
SOCK="qzss-e2e-$$"
export HOME=${QZSS_E2E_HOME:-$(mktemp -d)}
PASS=0
FAIL=0
T() { tmux -L "$SOCK" "$@"; }
cleanup() { T kill-server 2>/dev/null || true; }
trap cleanup EXIT

screen() { T capture-pane -p -t e2e; }

wait_for() { # text [timeout_s]
  local text=$1 deadline=$((SECONDS + ${2:-10}))
  while ((SECONDS < deadline)); do
    if screen | grep -qF -- "$text"; then return 0; fi
    sleep 0.1
  done
  return 1
}

check() { # description text [timeout]
  if wait_for "$2" "${3:-10}"; then
    PASS=$((PASS + 1)); echo "ok   $1"
  else
    FAIL=$((FAIL + 1)); echo "FAIL $1 (missing: $2)"; screen | sed 's/^/     | /'
  fi
}

check_absent() { # description text
  if screen | grep -qF -- "$2"; then
    FAIL=$((FAIL + 1)); echo "FAIL $1 (unexpected: $2)"; screen | sed 's/^/     | /'
  else
    PASS=$((PASS + 1)); echo "ok   $1"
  fi
}

keys() { T send-keys -t e2e "$@"; }
cmd() { keys Escape; keys ":$1" Enter; }

T new-session -d -s e2e -x 140 -y 36 \
  "env HOME='$HOME' nvim --clean -u tests/minimal_init.lua tests/fixtures/rust/src/lib.rs"
check "nvim started" "pub trait Shape"

# --- Rust outline in the sidebar -------------------------------------------
cmd "Qzss"
check "sidebar winbar" "qzss · lib.rs · treesitter · ? help"
check "trait impl reads 'impl Trait for Type'" "⊃ impl Default for MyStruct<i32>  impl trait"
check "generic trait impl with where clause" "impl<T> Shape<T> for MyStruct<T> where T: Copy + Display"
check "inherent impl" "⊂ impl<T: Clone> MyStruct<T>  impl"
check "nested fn under method" "ƒ helper<U: Copy>(u: U) -> U"
check_absent "no reversed impl wording" "MyStruct for Default"

# --- jump: search the row in the sidebar, press Enter ----------------------
keys "/impl Default" Enter
keys Enter
check "jump moved source cursor to line 19 col 1" "19,1 "

# --- fold a node and see it keep icon/name/kind ----------------------------
keys C-w l
keys "/impl<T> Shape" Enter
keys z a
check "folded row keeps marker/icon/name/kind and count" "▸ ⊃ impl<T> Shape<T> for MyStruct<T> [+4] where T: Copy"
check_absent "folded children hidden" "ƒ helper<U: Copy>"

# --- edit the source: outline refreshes, fold kept --------------------------
keys C-w h
keys g g O "pub struct Added {}" Escape
check "outline updated after edit" "◆ Added  struct"
check "fold state kept after edit" "▸ ⊃ impl<T> Shape<T> for MyStruct<T>"
keys u

# --- help -------------------------------------------------------------------
keys C-w l
keys "?"
check "help float lists keys" "toggle fold"
keys q
check_absent "help closed" "close fold / parent"

# --- TypeScript kinds + filter ------------------------------------------------
keys C-w h
cmd "edit tests/fixtures/ts/sample.ts"
check "ts interface" "ⓘ Shape<T extends number = number>  interface"
check "ts type alias" "≡ Pair<K, V> = { key: K; value: V }  type"
check "ts class" "© Box<T> implements Shape<number>  class"
cmd "QzssFilter TypeAlias"
check "filter winbar" "filter:TypeAlias"
check_absent "filter hides class" "© Box<T>"
cmd "QzssFilter"
check "filter cleared" "© Box<T>"

# --- JSON / YAML without LSP ----------------------------------------------------
cmd "edit tests/fixtures/sample.json"
check "json nested quoted key" "▾ {} \"deep key\" {2}  object"
check "json array index" "\" [1]: \"two\"  string"
cmd "edit tests/fixtures/sample.yaml"
check "yaml quoted key" "\" 'quoted key': yes  string"
check "yaml flow sequence" "▾ [] b [2]  array"

# --- narrow terminal ------------------------------------------------------------
T resize-window -t e2e -x 70 -y 20
check "still rendered at 70 columns" "▾ {} nested {2}"

cmd "qa!"
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
