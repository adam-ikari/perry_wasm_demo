import { readFileSync, writeFileSync } from 'node:fs';
import { wasmBare, wasmBoot, wasmHtml } from '/home/gem/project/perry_wasm_demo/node_modules/@typerry/node/index.js';
const src = readFileSync('/home/gem/project/perry_wasm_demo/src/bench.ts','utf8');
const bare = wasmBare(src);
writeFileSync('/tmp/rc_work/tp_bare.wasm', bare);
console.log('wasmBare:', bare.length);
for (const minify of [false, true]) {
  const b = wasmBoot(src, '', true, minify);
  writeFileSync(`/tmp/rc_work/tp_boot_m${minify?1:0}.wasm`, Buffer.from(b.wasm));
  writeFileSync(`/tmp/rc_work/tp_boot_m${minify?1:0}.mjs`, b.runtime);
  console.log(`wasmBoot minify=${minify}: wasm=${b.wasm.length} runtime=${b.runtime.length}`);
}
for (const minify of [false, true]) {
  const h = wasmHtml(src, '', minify);
  writeFileSync(`/tmp/rc_work/tp_html_m${minify?1:0}.html`, h);
  console.log(`wasmHtml minify=${minify}: html=${h.length}`);
}
