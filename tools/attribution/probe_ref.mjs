#!/usr/bin/env node
/*
 * probe_ref.mjs — 生成 perry 自带 JS 宿主层（wasmBoot）参照产物，用于逐字节一致性比对。
 *
 * 用法: node tools/attribution/probe_ref.mjs <src.ts> <out_dir>
 * 产出: <out_dir>/run.mjs + <out_dir>/run.wasm；`node <out_dir>/run.mjs` 即参照输出。
 * 与 tools/build-wasm.mjs 的非 --bare 分支同一调用（不改 build-wasm.mjs）。
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { wasmBoot } from "@typerry/node";

const [src, outDir] = process.argv.slice(2);
if (!src || !outDir) {
  console.error("usage: node probe_ref.mjs <src.ts> <out_dir>");
  process.exit(2);
}
const ref = wasmBoot(readFileSync(src, "utf8"), "", true, false);
mkdirSync(outDir, { recursive: true });
writeFileSync(`${outDir}/run.mjs`, ref.runtime);
writeFileSync(`${outDir}/run.wasm`, Buffer.from(ref.wasm));
console.log(`${outDir}/run.mjs + run.wasm`);
