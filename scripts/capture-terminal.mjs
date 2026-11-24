#!/usr/bin/env node
/**
 * Capture the actual Neovim PTY, not a mock of its sidebar.
 *
 * Prerequisites: Node.js >= 22.18 (kenshu-loop), Neovim, parsers from scripts/bootstrap.sh,
 * ImageMagick 7 with SVG support, DejaVu Sans Mono, and an installed
 * takeshiD/kenshu-loop checkout with its dependencies installed.
 *
 * KENSHU_CLI=/path/to/kenshu-loop/skills/kenshu-loop/scripts/kenshu-loop.mjs \
 *   node scripts/capture-terminal.mjs
 * Optional: pass capture names (e.g. rust-expanded typescript) to regenerate
 * only those images. NVIM and MAGICK override executable names.
 *
 * Captures use real Tree-sitter parsers, without an LSP. kenshu-loop retains
 * the PTY history and original captures under .research/terminal-captures/.
 * The published JSON is the unchanged terminal screen/style evidence.
 * SVG rendering places each captured character on its terminal cell because
 * some SVG renderers ignore textLength, making long terminal lines drift.
 * No screen content, foreground color, or background color is synthesized.
 */
import { spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const cli = process.env.KENSHU_CLI || [
  join(homedir(), '.agents/skills/kenshu-loop/scripts/kenshu-loop.mjs'),
  join(homedir(), '.codex/skills/kenshu-loop/scripts/kenshu-loop.mjs'),
].find(existsSync);
if (!cli || !existsSync(cli)) {
  throw new Error('Set KENSHU_CLI to the installed kenshu-loop.mjs path.');
}
const output = join(root, 'docs/images');
const state = join(root, '.research/terminal-captures', `run-${Date.now()}-${process.pid}`);
mkdirSync(output, { recursive: true });
mkdirSync(state, { recursive: true });

function run(command, args) {
  const result = spawnSync(command, args, {
    cwd: root, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    throw new Error(`${command} failed: ${result.error || result.stderr || result.stdout}`);
  }
  return result.stdout;
}
function term(...args) {
  const result = JSON.parse(run(process.execPath, [cli, 'term', '--root', state, ...args]));
  if (!result.ok) throw new Error(JSON.stringify(result));
  return result;
}

// The fixture captures contain only single-cell codepoints. Refuse unsupported
// content instead of silently changing terminal geometry for a future fixture.
function gridSvg(svg) {
  return svg
    .replace(/font-family="[^"]+"/, 'font-family="DejaVu Sans Mono"')
    .replace('font-size="17px"', 'font-size="16px"')
    .replace(/<text([^>]+textLength[^>]+)>(.*?)<\/text>/g, (_, attrs, content) => {
      const chars = content.match(/&[^;]+;|./gu) || [];
      const start = Number(attrs.match(/\bx="([\d.]+)"/)[1]);
      const width = Number(attrs.match(/textLength="([\d.]+)"/)[1]);
      if (chars.length && Math.abs(width / chars.length - 10) > 0.01) {
        throw new Error('Capture contains non-single-cell text; update the grid renderer.');
      }
      return chars.map((char, index) => {
        if (char === ' ') return '';
        const cellAttrs = attrs
          .replace(/\bx="[\d.]+"/, `x="${(start + index * 10).toFixed(2)}"`)
          .replace(/ textLength="[^"]+" lengthAdjust="[^"]+"/g, '');
        return `<text${cellAttrs}>${char}</text>`;
      }).join('');
    });
}

const cases = [
  { name: 'rust-expanded', file: 'rust/src/lib.rs', wait: 'impl Default for MyStruct', sourceLine: 19 },
  { name: 'typescript', file: 'ts/sample.ts', wait: 'interface' },
  { name: 'tsx', file: 'ts/view.tsx', wait: 'interface' },
  { name: 'json', file: 'sample.json', wait: 'deep key' },
  { name: 'yaml', file: 'sample.yaml', wait: 'quoted key' },
  { name: 'rust-folded', file: 'rust/src/lib.rs', wait: 'impl Default for MyStruct', fold: true, sourceLine: 19 },
  { name: 'custom-ascii', file: 'ts/sample.ts', wait: 'contract', custom: true },
];
const requested = process.argv.slice(2);
for (const name of requested) {
  if (!cases.some(item => item.name === name)) throw new Error(`Unknown capture: ${name}`);
}

for (const item of cases.filter(item => !requested.length || requested.includes(item.name))) {
  let started = false;
  try {
    const config = item.custom
      ? '{layout={width=86,max_width=86},icons="ascii",kind_labels={Interface="contract",TypeAlias="type alias",Class="class"},format_name=function(s) return "["..s.name.."]" end,highlights={Class={fg="#8be9fd"},Interface={fg="#50fa7b"},TypeAlias={fg="#ffb86c"}}}'
      : '{layout={width=86,max_width=86}}';
    term('start', '--name', item.name, '--cols', '165', '--rows', '35', '--cwd', root,
      '--', 'env', 'QZSS_LSP=0', 'QZSS_SETUP={}', process.env.NVIM || 'nvim',
      '-u', 'tests/minimal_init.lua', `tests/fixtures/${item.file}`,
      '+set number', `+lua require("qzss").setup(${config})`,
      ...(item.sourceLine ? [`+normal! ${item.sourceLine}Gzt`] : []), '+QzssOpen');
    started = true;
    term('wait', '--name', item.name, item.wait, '--timeout', '10000');
    if (item.fold) term('type', '--name', item.name, 'zM');
    const capture = term('capture', '--name', item.name, item.name);
    const artifacts = capture.record.artifacts;
    const sourceSvg = artifacts.find(path => path.endsWith('.svg'));
    const sourceJson = artifacts.find(path => path.endsWith('.json'));
    const target = join(output, `terminal-${item.name}`);
    copyFileSync(sourceJson, `${target}.json`);
    writeFileSync(`${target}.svg`, gridSvg(readFileSync(sourceSvg, 'utf8')));
    run(process.env.MAGICK || 'magick', [`${target}.svg`, `${target}.png`]);
    console.log(`Captured ${target}.png`);
  } finally {
    if (started) term('stop', '--name', item.name);
  }
}
console.log(`Original PTY history and captures: ${state}`);
