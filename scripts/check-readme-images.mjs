#!/usr/bin/env node
// Verifies that every image README.md embeds exists, is a real PNG, has the
// raw PTY capture (screen text + styles) next to it, and that the captured
// screen shows what the README claims. Also checks the kind-label contrast
// fix is visible in the published captures (labels not drawn in NonText grey).
// Usage: node scripts/check-readme-images.mjs
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const readme = readFileSync(join(root, 'README.md'), 'utf8');
let failed = 0;
const ok = (cond, msg) => {
  console.log(`${cond ? 'ok  ' : 'FAIL'} ${msg}`);
  if (!cond) failed++;
};

const images = [...readme.matchAll(/!\[[^\]]+\]\((docs\/images\/[^)]+\.png)\)/g)].map(m => m[1]);
ok(images.length >= 9, `README embeds ${images.length} PNG screenshots`);

const expected = {
  'terminal-rust-expanded': ['impl Default for MyStruct<i32>  impl trait', 'impl<T> Shape<T> for MyStruct<T> where T: Copy + Display', 'impl<T: Clone> MyStruct<T>  impl', 'helper<U: Copy>(u: U) -> U  fn'],
  'terminal-typescript': ['ⓘ Shape<T extends number = number>  interface', '≡ Pair<K, V> = { key: K; value: V }  type', '© Box<T> implements Shape<number>  class'],
  'terminal-tsx': ['ⓘ Props  interface', '© Panel extends React.Component<Props>  class'],
  'terminal-json': ['"deep key" {2}  object', '[1]: "two"  string'],
  'terminal-yaml': ["'quoted key': yes  string", '[] list [3]  array'],
  'terminal-rust-folded': ['▸ ⊃ impl<T> Shape<T> for MyStruct<T> [+4]', '▸ ◈ Shape [+3]'],
  'terminal-custom-ascii': ['[Shape]', 'contract', 'type alias'],
  'terminal-float': ['╭', '─ qzss · lib.rs ─', 'treesitter · ? help ╯', '│▸ ⊃ impl<T> Shape<T> for MyStruct<T> [+4]', '│▾ ⊃ impl Default for MyStruct<i32>  impl trait'],
  'terminal-float-to-sidebar': ['qzss · lib.rs · treesitter · ? help', '│▸ ⊃ impl<T> Shape<T> for MyStruct<T> [+4]'],
};
// text that must NOT be on a capture
const absent = {
  'terminal-float-to-sidebar': ['╭', '╯'],
  'terminal-rust-expanded': ['╭'],
};
const NONTEXT = '#4f5258';

for (const rel of images) {
  const png = join(root, rel);
  const base = rel.replace(/^docs\/images\//, '').replace(/\.png$/, '');
  ok(existsSync(png), `${rel} exists`);
  if (!existsSync(png)) continue;
  const head = readFileSync(png).subarray(0, 8).toString('hex');
  ok(head === '89504e470d0a1a0a', `${rel} is a PNG`);
  const raw = png.replace(/\.png$/, '.json');
  ok(existsSync(raw), `${base}.json raw PTY capture present`);
  ok(existsSync(png.replace(/\.png$/, '.svg')), `${base}.svg rendering present`);
  if (!existsSync(raw)) continue;
  const cap = JSON.parse(readFileSync(raw, 'utf8'));
  const text = cap.screen.lines.join('\n');
  ok(text.includes('qzss · '), `${base}: captured screen shows the qzss sidebar`);
  for (const needle of expected[base] || []) ok(text.includes(needle), `${base}: shows "${needle}"`);
  for (const needle of absent[base] || []) ok(!text.includes(needle), `${base}: does not show "${needle}"`);
  // outline area: right of the sidebar separator, or inside the float's left border
  const bars = cap.styled.filter(s => s.text.includes('│')).map(s => s.col + [...s.text].indexOf('│'));
  const sideCol = base === 'terminal-float' ? Math.min(...bars) : Math.max(...bars);
  const labels = cap.styled.filter(s => s.col > sideCol && /^(impl trait|interface|type|class|struct|object|array|string|contract|type alias)$/.test(s.text.trim()));
  ok(labels.length > 0 && labels.every(s => s.style.fg !== NONTEXT && s.style.italic),
    `${base}: kind labels are italic and not NonText grey (${labels.length} spans)`);
}
for (const name of Object.keys(expected)) ok(images.includes(`docs/images/${name}.png`), `README embeds ${name}.png`);
console.log(`\n${failed ? 'FAILED' : 'all checks passed'} (${failed} failed)`);
process.exit(failed ? 1 : 0);
