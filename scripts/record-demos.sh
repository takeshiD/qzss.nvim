#!/usr/bin/env sh
# Re-record README images with VHS from a real Neovim session.
# Needs: vhs, ttyd, ffmpeg (on NixOS: nix shell nixpkgs#vhs nixpkgs#ttyd nixpkgs#ffmpeg),
# plus `sh scripts/bootstrap.sh` and `npm ci` for parsers and typescript-language-server.
set -eu
cd "$(dirname "$0")/.."
run() {
  if command -v ttyd >/dev/null 2>&1 && command -v ffmpeg >/dev/null 2>&1; then
    vhs "$1"
  else
    nix shell nixpkgs#ttyd nixpkgs#ffmpeg -c vhs "$1"
  fi
}
for tape in ${*:-demo/rust.tape demo/typescript.tape demo/data.tape demo/fold-custom.tape}; do
  echo "recording $tape"
  run "$tape"
done
