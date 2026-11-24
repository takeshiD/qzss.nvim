# Folding keeps kind/icon/name; ASCII icons + custom labels/highlights via setup().
Output docs/images/fold-custom.gif
Source demo/common.tape
Type `QZSS_SETUP='{"icons":"ascii","kind_labels":{"TraitImpl":"trait-impl","Impl":"inherent"},"highlights":{"TraitName":{"fg":"#fab387","bold":true},"SelfType":{"fg":"#89b4fa","bold":true}}}' nvim --clean -u tests/minimal_init.lua tests/fixtures/rust/src/lib.rs` Enter
Sleep 1.5s
Show
Type ":Qzss" Enter
Sleep 1.5s
Type "/impl<T> Shape" Enter
Sleep 600ms
Type "za"
Sleep 800ms
Type "/impl<T: Clone>" Enter
Sleep 600ms
Type "za"
Sleep 1.2s
Screenshot docs/images/fold-custom.png
Type "zR"
Sleep 1s
