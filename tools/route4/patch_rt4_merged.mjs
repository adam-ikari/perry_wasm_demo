#!/usr/bin/env node
/*
 * patch_rt4_merged.mjs — wasm-merge 合并模块的后处理（路线三/路线四通用，E 路 patch_merged.mjs 的宽容版）。
 *
 * 与 tools/attribution/patch_merged.mjs 的差异（仅此两点）：
 *   1. 删除 rt 侧 __data_end/__heap_base 导出这一步改为「有则删、无则过」——
 *      路线三 runtime-wasm 导出这两个（1129776），与 app 栈指针 global（65536）
 *      被 WAMR loader 组合成非法 aux stack（aux_stack_bottom=65536、boundary=0），
 *      _start 一跑即 "auxiliary stack underflow"；路线四 rt4（Rust cdylib）不导出
 *      它们（导出的 global 是 __wasm_global_0..3），本就走 loader 的 unused fallback。
 *   2. _start wrapper（先 call rt 的 _initialize 再 call 原 _start）两个形态都需要：
 *      双模块下 WAMR 加载子模块时调 _initialize，合并后没人调它，Rust 分配器不初始化。
 *
 * 用法: node tools/route4/patch_rt4_merged.mjs <in.wasm> <out.wat>
 * 依赖: node_modules/binaryen 的 wasm-dis（本仓库 demo 链自带）。
 */
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";

const [inWasm, outWat] = process.argv.slice(2);
if (!inWasm || !outWat) {
  console.error("usage: node tools/route4/patch_rt4_merged.mjs <in.wasm> <out.wat>");
  process.exit(2);
}

const here = new URL("../..", import.meta.url).pathname;
// feature 必须显式给：binaryen 123 的 wasm-dis 默认不打印 call_indirect 的表索引
// （多表模块里 1933 处 `call_indirect $1 (type $N)` 被降级成 `call_indirect (type $N)`），
// wasm-as 随即按表 0 重编，运行期全变 "undefined element"。加 --enable-reference-types
// 后 dis→as 与源二进制字节一致（已验证 cmp 无差异）。与 aot.sh 传给 wasm-as 的集合对齐。
const FEATURES = [
  "--enable-bulk-memory",
  "--enable-nontrapping-float-to-int",
  "--enable-multimemory",
  "--enable-reference-types",
];
execFileSync(`${here}node_modules/.bin/wasm-dis`, [inWasm, "-o", outWat, ...FEATURES], {
  stdio: "inherit",
});

let wat = readFileSync(outWat, "utf8");
const removed = wat.match(/\s*\(export "__(?:data_end|heap_base)" \(global \$global\$\d+\)\)/g);
if (removed) {
  wat = wat.replace(/\s*\(export "__(?:data_end|heap_base)" \(global \$global\$\d+\)\)/g, "");
  console.log(`patch: removed ${removed.length} __data_end/__heap_base export(s) (route-3 form)`);
} else {
  console.log("patch: no __data_end/__heap_base exports (route-4 form) — nothing to remove");
}

// ---------------------------------------------------------------------
// 3. wamrc 的 64-cell call_indirect 上限 -> 必 trap 的间接调用改写为 unreachable
//
// wamrc (aot_emit_function.c:1994) 拒绝 argv_cell_num = max(param, ret) > 64 的
// call_indirect；上限不是编译器洁癖：wasm_exec_env.c:44 的 exec_env->argv_buf
// 只有 malloc(sizeof(uint32) * 64)。抬高上限须同时改 pinned WAMR 运行时，不取。
//
// 路线四合并模块里恰有 1 处超限调用: type $407 = (i32, f64×32) -> f64 = 65 cells。
// 结构性断言（全模块 func/import 头 vs 该签名）证明 0 个函数实现它，
// 故该 call_indirect 一旦执行必 trap（表项类型恒不匹配或为 null）；
// 操作数须全为纯指令（local.get 等），替换为 unreachable 才等价。
// 任何一条断言不成立即中止，绝不静默改写。
const CELL = { i32: 1, f32: 1, funcref: 1, externref: 1, i64: 2, f64: 2, v128: 4 };
const cellOf = (t) => CELL[t] ?? 0;

const typeSig = (params, results) => `(${params.join(" ")}) -> ${results.join(" ")}`;
const types = new Map(); // idx -> { params, results, cells }
const typeLines = wat.match(/^\s*\(type \$/gm) ?? [];
for (const m of wat.matchAll(/^\s*\(type \$(\d+) \(func(.*)\)\)$/gm)) {
  const params = [], results = [];
  for (const p of m[2].matchAll(/\(param ([^)]*)\)/g))
    params.push(...p[1].trim().split(/\s+/).filter(Boolean));
  for (const r of m[2].matchAll(/\(result ([^)]*)\)/g))
    results.push(...r[1].trim().split(/\s+/).filter(Boolean));
  const pc = params.reduce((s, t) => s + cellOf(t), 0);
  const rc = results.reduce((s, t) => s + cellOf(t), 0);
  types.set(Number(m[1]), { params, results, cells: Math.max(pc, rc) });
}
if (typeLines.length !== types.size) {
  console.error(`patch: type 段解析不完整（行 ${typeLines.length} vs 解析 ${types.size}），中止`);
  process.exit(1);
}

// 所有函数定义 + 导入的结构签名（与 type 段同口径，去掉参数名）
const implSigs = new Map(); // sig -> 出现次数
for (const m of wat.matchAll(/^\s*\((?:func \S+[^\n]*|import [^\n]*)/gm)) {
  const head = m[0];
  const params = [], results = [];
  for (const p of head.matchAll(/\(param ([^)]*)\)/g))
    params.push(...p[1].trim().split(/\s+/).filter((t) => t && !t.startsWith("$")));
  for (const r of head.matchAll(/\(result ([^)]*)\)/g))
    results.push(...r[1].trim().split(/\s+/).filter(Boolean));
  const sig = typeSig(params, results);
  implSigs.set(sig, (implSigs.get(sig) ?? 0) + 1);
}

const PURE = /^\((?:local\.get|global\.get|i32\.const|i64\.const|f32\.const|f64\.const|ref\.null|memory\.size|table\.size)[^()]*\)$/;
// 折叠表达式: start 指向 '('，返回其匹配 ')' 之后的下标（跳过字符串字面量）
const exprEnd = (s, start) => {
  let depth = 0, inStr = false, esc = false;
  for (let i = start; i < s.length; i++) {
    const c = s[i];
    if (inStr) { if (esc) esc = false; else if (c === "\\") esc = true; else if (c === '"') inStr = false; continue; }
    if (c === '"') { inStr = true; continue; }
    if (c === "(") depth++;
    else if (c === ")") { depth--; if (depth === 0) return i + 1; }
  }
  return -1;
};
const topLevel = (s) => { // 折叠体 -> { header(首个 '(' 之前的指令名), children }
  const children = [];
  let header = "";
  let depth = 0, start = -1, inStr = false, esc = false;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (inStr) { if (esc) esc = false; else if (c === "\\") esc = true; else if (c === '"') inStr = false; continue; }
    if (c === '"') { inStr = true; continue; }
    if (c === "(") {
      if (depth === 0) { if (!children.length) header = s.slice(0, i); start = i; }
      depth++;
    } else if (c === ")") {
      depth--;
      if (depth === 0) children.push(s.slice(start, i + 1));
    }
  }
  return { header: header.replace(/\s+/g, " ").trim(), children };
};

const over = [...types].filter(([, t]) => t.cells > 64);
let rewritten = 0;
for (const [idx, t] of over) {
  const sig = typeSig(t.params, t.results);
  // 文本形态随表数而变：单表 `call_indirect (type $N)`，多表 `call_indirect $T (type $N)`
  const sites = [...wat.matchAll(new RegExp(`call_indirect( \\$\\d+)? \\(type \\$${idx}\\)`, "g"))];
  if (!sites.length) continue; // 超限类型但没人间接调用它 —— 与 wamrc 无关
  if (implSigs.get(sig)) {
    console.error(`patch: type $${idx} (${sig}) 超 64 cells 但被 ${implSigs.get(sig)} 个函数实现，`
      + "不可等价改写，中止");
    process.exit(1);
  }
  // 从后往前替换，避免下标失效
  for (let k = sites.length - 1; k >= 0; k--) {
    const at = sites[k].index;
    const open = wat.lastIndexOf("(", at);
    const end = exprEnd(wat, open);
    if (end < 0) { console.error("patch: 折叠表达式未闭合，中止"); process.exit(1); }
    const { header, children } = topLevel(wat.slice(open + 1, end - 1));
    // 头部可能是 `call_indirect` 或 `call_indirect $T`（多表，T=目标表下标）
    if (!/^call_indirect( \$\d+)?$/.test(header) || children[0] !== `(type $${idx})`) {
      console.error(`patch: 调用点头部解析不符（${header} / ${children[0]}），中止`);
      process.exit(1);
    }
    const args = children.slice(1);
    if (!args.every((a) => PURE.test(a.replace(/\s+/g, " ").trim()))) {
      console.error(`patch: type $${idx} 调用点含非纯操作数，拒绝改写：\n${args.slice(0, 5).join("\n")}`);
      process.exit(1);
    }
    wat = wat.slice(0, open) + "(unreachable)" + wat.slice(end);
    rewritten++;
    console.log(`patch: call_indirect (type $${idx}) [${sig} = ${t.cells} cells > 64, 无函数实现] `
      + `#${k + 1}/${sites.length} -> unreachable（等价: 必 trap）`);
  }
}
console.log(rewritten
  ? `patch: 共改写 ${rewritten} 处超 64-cell call_indirect（wamrc aot_emit_function.c:1994 上限，`
    + "依据 wasm_exec_env.c:44 argv_buf=64×u32）"
  : "patch: 无超 64-cell call_indirect（rt3 形态）");

// _start wrapper（先 _initialize 后原 _start）—— 两个形态都必须织入
const startExport = wat.match(/\(export "_start" \(func (\$\w+|\d+)\)\)/);
const initExport = wat.match(/\(export "_initialize" \(func (\$\w+|\d+)\)\)/);
if (!startExport || !initExport) {
  console.error("patch: missing _start/_initialize export");
  process.exit(1);
}
wat = wat.replace(
  startExport[0],
  `(export "_start" (func $__merged_start_wrapper))`,
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
console.log(`patch: _start wrapper woven (init=${initExport[1]}, start=${startExport[1]}) -> ${outWat}`);
