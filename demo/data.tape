# JSON and YAML hierarchy from Tree-sitter only (no language server).
Output docs/images/data.gif
Source demo/common.tape
Type "nvim --clean -u tests/minimal_init.lua -O tests/fixtures/sample.json" Enter
Sleep 1.5s
Show
Type ":Qzss" Enter
Sleep 1.5s
Screenshot docs/images/json.png
Ctrl+W
Type "h"
Type ":e tests/fixtures/sample.yaml" Enter
Sleep 1.5s
Screenshot docs/images/yaml.png
