#!/usr/bin/env node
/*
 * patch_merged.mjs — wasm-merge 合并模块的后处理（E 路专用）。
 *
 * 输入: wasm-merge 产出的合并模块（app+rt 单模块）反汇编的 .wat 由本脚本生成。
 * 处理:
 *   1. 织入 wrapper: _start 先 call rt 的 _initialize 再 call 原 _start
 *      （双模块下 WAMR 加载子模块时会调 _initialize，合并后没人调它）。
 *   2. 删除 rt 侧的 __data_end/__heap_base 导出：合并后它们（1129776）与 app
 *      栈指针 global（65536）被 WAMR loader 组合成非法 aux stack
 *      （aux_stack_bottom=65536、boundary=0），_start 一跑即
 *      "wasm auxiliary stack underflow"。删除后 loader 走 "unused" fallback，
 *      恢复双模块下 app 无 aux stack 检查的语义。
 *
 * 用法: node patch_merged.mjs <in.wasm> <out.wat>
 * 依赖: node_modules/binaryen 的 wasm-dis（本仓库 demo 链自带）。
 */
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";

const [inWasm, outWat] = process.argv.slice(2);
if (!inWasm || !outWat) {
  console.error("usage: node patch_merged.mjs <in.wasm> <out.wat>");
  process.exit(2);
}

// 1. 反汇编: 直接跑本仓库自带的 wasm-dis（node_modules/.bin，binaryen 壳脚本）
const here = new URL("../..", import.meta.url).pathname;
execFileSync(`${here}node_modules/.bin/wasm-dis`, [inWasm, "-o", outWat], {
  stdio: "inherit",
});

let wat = readFileSync(outWat, "utf8");
const before = wat.length;
wat = wat.replace(/\s*\(export "__(?:data_end|heap_base)" \(global \$global\$\d+\)\)/g, "");
if (wat.length === before) {
  console.error("patch_merged: no __data_end/__heap_base exports removed — unexpected input");
  process.exit(1);
}

// 3. 织入 _start wrapper（先 _initialize 后原 _start）
const startExport = wat.match(/\(export "_start" \(func (\$\w+|\d+)\)\)/);
const initExport = wat.match(/\(export "_initialize" \(func (\$\w+|\d+)\)\)/);
if (!startExport || !initExport) {
  console.error("patch_merged: missing _start/_initialize export");
  process.exit(1);
}
wat = wat.replace(
  startExport[0],
  `(export "_start" (func $__merged_start_wrapper))`
);
const wrapper = `
 (func $__merged_start_wrapper
  call ${initExport[1]}
  call ${startExport[1]}
 )
`;
const last = wat.lastIndexOf(")");
wat = wat.slice(0, last) + wrapper + wat.slice(last);

writeFileSync(outWat, wat);
console.log(`patch_merged: ${outWat} written (removed heap/data exports, added _start wrapper)`);
