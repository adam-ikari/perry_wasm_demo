#!/usr/bin/env node
/*
 * build-wasm.mjs — 用 perry (typerry) 把 TypeScript 编译成 wasm。
 *
 * 用法:
 *   node tools/build-wasm.mjs                            # src/app.ts → build/app.wasm + build/ref/run.*
 *   node tools/build-wasm.mjs <src.ts> --bare <out.wasm> # 只出裸 wasm (负向验证用)
 */
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { wasmBare, wasmBoot } from '@typerry/node';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const argv = process.argv.slice(2);

let sourcePath = join(root, 'src/app.ts');
let barePath = join(root, 'build/app.wasm');
let withReference = true;

if (argv.length > 0) {
  sourcePath = resolve(argv[0]);
  const bareIndex = argv.indexOf('--bare');
  if (bareIndex < 0 || !argv[bareIndex + 1]) {
    console.error('用法: build-wasm.mjs [<src.ts> --bare <out.wasm>]');
    process.exit(2);
  }
  barePath = resolve(argv[bareIndex + 1]);
  withReference = false;
}

const source = readFileSync(sourcePath, 'utf8');
mkdirSync(dirname(barePath), { recursive: true });

const bare = wasmBare(source);
writeFileSync(barePath, Buffer.from(bare));
console.log(`${barePath}: ${bare.length} bytes`);

if (withReference) {
  // 参照实现: 同一份源码走 perry 自带的 JS 宿主层
  mkdirSync(join(root, 'build/ref'), { recursive: true });
  const ref = wasmBoot(source, '', true, false);
  writeFileSync(join(root, 'build/ref/run.mjs'), ref.runtime);
  writeFileSync(join(root, 'build/ref/run.wasm'), Buffer.from(ref.wasm));
  console.log(`build/ref/run.mjs: ${ref.runtime.length} chars`);
}
