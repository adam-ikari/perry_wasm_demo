#!/usr/bin/env node
// verify.mjs — 路线四产物校验 (build.sh 第 5 步, 也可单独运行)。
// 断言五组事实:
//   1. 导入段: build/rt4.wasm 的全部导入都是 wasi_snapshot_preview1 (零非 WASI 导入)
//   2. 导出覆盖: build/app_link.wasm 的 211 个 rt.* 函数导入全部由 rt4 导出
//   3. 正向: perry_link(app_link, rt4) 输出与参照 build/ref.out 逐字节一致, 退出码 0
//   4. 负向: perry_link(arr_link, rt4) 退出码非 0 且实名报 array_new 未实现
//   5. 语义探针 (找到 iwasm 才跑, 否则记跳过): is_truthy/js_add 的 NaN-box 位语义
// 用法: node tools/route4/verify.mjs     (前置: ./demo.sh 产出链路构件)
import { readFileSync, existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "../..");
const abs = (p) => join(root, p);
let failed = 0;

const ok = (cond, passMsg, failMsg) => {
  if (cond) console.log(`✓ ${passMsg}`);
  else {
    console.log(`✗ ${failMsg}`);
    failed++;
  }
  return cond;
};
const need = (p) => {
  if (!existsSync(abs(p))) {
    console.error(`✗ 缺 ${p} —— 先跑 ./demo.sh (链路构件) 或 tools/route4/build.sh (rt4 产物)`);
    process.exit(1);
  }
};

// ---------------------------------------------------------------- 1+2 结构
need("build/rt4.wasm");
need("build/app_link.wasm");
const rt4 = new WebAssembly.Module(readFileSync(abs("build/rt4.wasm")));
const app = new WebAssembly.Module(readFileSync(abs("build/app_link.wasm")));

const rt4Imports = WebAssembly.Module.imports(rt4);
const nonWasi = rt4Imports.filter((i) => i.module !== "wasi_snapshot_preview1");
ok(
  nonWasi.length === 0,
  `导入段 ${rt4Imports.length} 项全部 wasi_snapshot_preview1 (零非 WASI)`,
  `导入段含 ${nonWasi.length} 项非 WASI: ` +
    nonWasi.slice(0, 5).map((i) => `${i.module}.${i.name}`).join(", "),
);

const rt4Exports = new Set(WebAssembly.Module.exports(rt4).map((e) => e.name));
const rtFuncImports = WebAssembly.Module.imports(app).filter(
  (i) => i.module === "rt" && i.kind === "function",
);
const missing = rtFuncImports.filter((i) => !rt4Exports.has(i.name));
ok(
  rtFuncImports.length > 0 && missing.length === 0,
  `rt.* 导出覆盖 ${rtFuncImports.length - missing.length}/${rtFuncImports.length} (业务模块全部导入有主)`,
  `rt.* 导出缺 ${missing.length} 个: ${missing.slice(0, 5).map((i) => i.name).join(", ")}`,
);

// ---------------------------------------------------------------- 3 正向 e2e
need("build/ref.wasm".replace(".wasm", ".out"));
const ref = readFileSync(abs("build/ref.out"));
const pos = spawnSync(abs("build/perry_link"), [abs("build/app_link.wasm"), abs("build/rt4.wasm")], {
  cwd: root,
  encoding: "buffer",
});
const posOut = pos.stdout ?? Buffer.alloc(0);
ok(
  pos.status === 0 && Buffer.compare(posOut, ref) === 0,
  `正向输出与 build/ref.out 逐字节一致 (exit=${pos.status}, ${ref.length} B)`,
  `正向不一致 (exit=${pos.status}, 产物 ${posOut.length} B vs 参照 ${ref.length} B): ` +
    (pos.stderr ? Buffer.from(pos.stderr).toString().split("\n")[0] : ""),
);

// ---------------------------------------------------------------- 4 负向 e2e
need("build/arr_link.wasm");
const neg = spawnSync(abs("build/perry_link"), [abs("build/arr_link.wasm"), abs("build/rt4.wasm")], {
  cwd: root,
  encoding: "utf8",
});
const negText = `${neg.stdout ?? ""}${neg.stderr ?? ""}`;
ok(
  neg.status !== 0 && negText.includes("bridge function 'array_new' is not implemented"),
  `负向 array_new 实名报错 (exit=${neg.status})`,
  `负向异常 (exit=${neg.status}): 首行 ${(negText.split("\n")[0] || "(空)").slice(0, 120)}`,
);

// ---------------------------------------------------------------- 5 语义探针
const iwasmCands = [
  process.env.IWASM,
  abs(".deps/wamr-build/iwasm"),
  abs(".deps/wamr-build/iwasm-2.4.3"),
  abs("build/wamr-aot-build/iwasm-2.4.3"),
].filter(Boolean);
const iwasm = iwasmCands.find((p) => existsSync(p));
if (!iwasm) {
  console.log("○ iwasm 未找到, 跳过语义探针 (可用 IWASM= 指定, ./demo.sh 第 1 步会构建)");
} else {
  // rt4 导出名是 is_truthy/js_add (rt.* 的导入名), 入参是 NaN-box 的 i64 位型:
  //   0                      → f64 0.0        → falsy
  //   0x3FF0000000000000     → f64 1.0        → truthy
  //   0x4000000000000000 + 0x4008000000000000 → 2.0 + 3.0 → 5.0
  const probes = [
    ["is_truthy", ["0"], "0x0:i32"],
    ["is_truthy", ["0x3FF0000000000000"], "0x1:i32"],
    ["js_add", ["0x4000000000000000", "0x4008000000000000"], "0x4014000000000000:i64"],
  ];
  const results = [];
  let probeOk = true;
  for (const [fn, args, expect] of probes) {
    const r = spawnSync(iwasm, ["-f", fn, abs("build/rt4.wasm"), ...args], { encoding: "utf8" });
    const got = (r.stdout ?? "").trim();
    if (got !== expect) probeOk = false;
    results.push(`${fn}(${args.join(",")})=${got || "(空)"}`);
  }
  ok(
    probeOk,
    `语义探针: ${results.join("; ")}`,
    `语义探针不符, 实际: ${results.join("; ")} (期望 0x0:i32 / 0x1:i32 / 0x4014000000000000:i64)`,
  );
}

if (failed) {
  console.log(`FAIL: 路线四产物校验 ${failed} 项未通过`);
  process.exit(1);
}
console.log("PASS: 路线四产物校验全部通过");
