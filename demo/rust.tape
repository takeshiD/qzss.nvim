# Rust: trait impls vs inherent impls, generics, where clauses, nested fns, jump.
Output docs/images/rust.gif
Source demo/common.tape
Type "nvim --clean -u tests/minimal_init.lua tests/fixtures/rust/src/lib.rs" Enter
Sleep 1.5s
Show
Type ":Qzss" Enter
Sleep 1.5s
Screenshot docs/images/rust.png
Type "/impl<T> Shape" Enter
Sleep 700ms
Enter
Sleep 1.2s
Ctrl+W
Type "l"
Sleep 500ms
Type "/helper" Enter
Sleep 500ms
Type "p"
Sleep 1.5s
