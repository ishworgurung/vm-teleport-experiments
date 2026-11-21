// check-mermaid.mjs -- parse every ```mermaid block in the given Markdown files
// with the real mermaid parser (the one GitHub and VS Code render with).
//
//   npm --prefix tools install                     # once
//   node tools/check-mermaid.mjs README.md docs/*.md
//
// Exit status 1 if any block fails to parse.  mermaid needs a DOM, so jsdom
// supplies window/document/Element as globals before mermaid is imported.
import { JSDOM } from 'jsdom';
import fs from 'fs';
const dom = new JSDOM('<!DOCTYPE html><body></body>');
globalThis.window = dom.window; globalThis.document = dom.window.document;
// `Option` is needed by a sequence diagram's `box` (mermaid builds `new Option()` to test a colour).
for (const k of ['Element','HTMLElement','SVGElement','Node','DOMParser','XMLSerializer','getComputedStyle','Option']) { if (dom.window[k]) globalThis[k] = dom.window[k]; }
Object.defineProperty(globalThis, 'navigator', { value: dom.window.navigator, configurable: true });
const mermaid = (await import('mermaid')).default;
mermaid.initialize({ startOnLoad: false });
let bad = 0, total = 0;
for (const f of process.argv.slice(2)) {
  const txt = fs.readFileSync(f, 'utf8');
  const re = /```mermaid\n([\s\S]*?)```/g; let m, n = 0;
  while ((m = re.exec(txt))) {
    n++; total++;
    try { await mermaid.parse(m[1]); }
    catch (e) { bad++; console.log(`FAIL ${f} block ${n}: ${String(e.message || e).split('\n').slice(0,4).join(' | ')}`); }
  }
}
console.log(`${total} blocks, ${bad} failed`);
process.exit(bad ? 1 : 0);
