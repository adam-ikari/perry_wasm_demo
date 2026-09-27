#!/usr/bin/env node
// 路线四覆盖度分析：r3 的 198 个 rt.* 桩 vs 上游 perry-runtime 的 js_* 符号全集。
// 口径（名层三层，2026-09-27 复算）：
//   direct — js_<s> 或 js_<snake(s)> 精确命中 perry 源码符号；
//   near   — 去下划线归一后命中，或以 js_<s>/js_<snake(s)> 为前缀命中（取最短者）；
//   alias  — 下方显式异名表（人工判定语义等价，逐条注明上游定义处与 codegen 签名）；
//   rest   — 以上均未命中 = 名层无对应实现。
// 这是"接线是不是搬运工作"的名层判定，不是运行期功能覆盖：
//   - 适配层当前只接线 29 个 rt.*（13 桥 + 16 新增），其余仍是桩；
//   - perry-stdlib 才有的真身（fetch 等）名层虽有符号，wasm 下仍需宿主实现。
// 用法: node tools/route4/coverage.mjs [--json]
// 依赖: build/rt_symbols.rs（r3 桩表）与上游源码 js_* 符号全集；
//       后者由 --perry-src 指向的 checkout 现场提取（默认 .deps/perry-src）。
import { readFileSync, existsSync } from "node:fs";
import { execSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "../..");
const args = process.argv.slice(2);
const asJson = args.includes("--json");

// 异名映射：rt.* 桩名 → perry js_* 符号。均为语义等价（构造/取值/调用形态不同）。
// 异名映射：rt.* 桩名 → perry js_* 符号。均为语义等价（构造/取值/调用形态不同）。
// 逐条口径（上游签名可在 .deps/perry-src/crates/perry-runtime/src grep 验证）：
//   array_index_of → js_array_indexOf_jsvalue   Array.prototype.indexOf 分发点 (array/generic.rs)
//   class_call_method → js_native_call_method   按名对 receiver 分发并带参数数组 (native_call_method.rs:1219)
//   class_new → js_object_alloc_class_dynamic_parent
//     codegen 注释 class_new = (class_id, field_count) -> handle (emit/compile.rs:401)，
//     上游用户类实例化即按父类布局分配该对象
//   class_set_parent → js_register_class_parent  注册父子类关系 (class_registry/parent_static.rs:38)
//   object_get_dynamic → js_dynamic_object_get_property
//     rt 签名 (handle, key) -> value (emit/compile.rs:333)；上游按名取属性，key 由适配层
//     整形为 (ptr, len)（与适配层既有 index↔pointer 转换同一套机构）
//   object_set_dynamic → js_object_set_property_key
//     rt 签名 (handle, key, value) -> void (emit/compile.rs:334)；
//     上游注释 obj[ToPropertyKey(key)] = value (object/property_key.rs:145)
//   searchparams_* → js_url_search_params_*
//     rt 六个桩与上游 URLSearchParams 六个方法同名 (emit/compile.rs:475-480 vs url/search_params.rs)
const ALIAS = {
  js_typeof: "js_value_typeof",
  object_new: "js_object_alloc",
  array_new: "js_array_alloc",
  map_new: "js_map_alloc",
  closure_new: "js_closure_alloc",
  set_new_from_array: "js_set_from_array",
  class_new: "js_object_alloc_class_dynamic_parent",
  class_get_field: "js_object_get_field",
  class_set_field: "js_object_set_field",
  class_call_method: "js_native_call_method",
  class_set_method: "js_register_class_method",
  class_set_static: "js_class_register_static_symbol",
  class_get_static: "js_register_class_static_getter",
  class_set_parent: "js_register_class_parent",
  class_instanceof: "js_instanceof",
  closure_call_spread: "js_closure_call_apply_with_spread",
  await_promise: "js_await_any_promise",
  error_message: "js_error_get_message",
  console_log_multi: "js_console_log_dynamic",
  array_index_of: "js_array_indexOf_jsvalue",
  date_new_val: "js_date_new_from_value",
  uint8array_length: "js_typed_array_length",
  object_get_dynamic: "js_dynamic_object_get_property",
  object_set_dynamic: "js_object_set_property_key",
  searchparams_get: "js_url_search_params_get",
  searchparams_has: "js_url_search_params_has",
  searchparams_set: "js_url_search_params_set",
  searchparams_append: "js_url_search_params_append",
  searchparams_delete: "js_url_search_params_delete",
  searchparams_to_string: "js_url_search_params_to_string",
};

// 上游源码 js_* 符号全集（fn 定义名 + 字符串字面量引用名，去重）。
function perrySymbols(perrySrc) {
  const grep = (pat) =>
    execSync(`grep -rhoE '${pat}' crates/perry-runtime/src --include='*.rs'`, {
      cwd: perrySrc,
      encoding: "utf8",
    });
  // 注意字符类必须含大写：上游存在 camelCase 符号（js_array_indexOf_jsvalue、
  // js_array_forEach 等），只取 [a-z_0-9] 会把它们截断成不存在的名字。
  const syms = new Set();
  for (const line of grep("fn (js_[A-Za-z_0-9]+)").split("\n")) {
    const m = line.match(/fn (js_[A-Za-z_0-9]+)/);
    if (m) syms.add(m[1]);
  }
  for (const line of grep('"(js_[A-Za-z_0-9]+)"').split("\n")) {
    const m = line.match(/"(js_[A-Za-z_0-9]+)"/);
    if (m) syms.add(m[1]);
  }
  return syms;
}

const stubTable = join(root, "build/rt_symbols.rs");
if (!existsSync(stubTable)) {
  console.error("缺 build/rt_symbols.rs，先运行 tools/gen-rt-symbols.mjs");
  process.exit(1);
}
const perrySrc = process.env.PERRY_SRC || join(root, ".deps/perry-src");
if (!existsSync(perrySrc)) {
  console.error(`缺上游源码 ${perrySrc}，先运行 tools/route4/build.sh`);
  process.exit(1);
}

const perry = perrySymbols(perrySrc);
const snake = (s) => s.replace(/[A-Z]/g, (c) => "_" + c.toLowerCase());
const norm = (s) => s.replace(/^js_/, "").replace(/_/g, "").toLowerCase();
const byNorm = new Map();
for (const p of perry) {
  const k = norm(p);
  if (!byNorm.has(k)) byNorm.set(k, p);
}

const stubs = [...readFileSync(stubTable, "utf8").matchAll(/#\[export_name = "([^"]+)"\]/g)].map(
  (m) => m[1],
);

const direct = [],
  near = [],
  alias = [],
  rest = [];
for (const s of stubs) {
  const c1 = "js_" + s,
    c2 = "js_" + snake(s);
  if (perry.has(c1) || perry.has(c2)) {
    direct.push(s);
    continue;
  }
  if (byNorm.has(norm(s))) {
    near.push(`${s}→${byNorm.get(norm(s))}`);
    continue;
  }
  // 前缀命中时取最短的同词干符号（离词干最近的那个，避免随机撞上长名字）。
  const cands = [...perry]
    .filter((n) => n.startsWith(c1) || n.startsWith(c2))
    .sort((a, b) => a.length - b.length || (a < b ? -1 : 1));
  if (cands.length) {
    near.push(`${s}→${cands[0]}`);
    continue;
  }
  const a = ALIAS[s];
  if (a && perry.has(a)) {
    alias.push(`${s}→${a}`);
    continue;
  }
  rest.push(s);
}

const covered = direct.length + near.length + alias.length;
if (asJson) {
  console.log(
    JSON.stringify(
      {
        stubs: stubs.length,
        direct: direct.length,
        near: near.length,
        alias: alias.length,
        rest: rest.length,
        covered,
        coveredPct: +(covered / stubs.length * 100).toFixed(1),
        nearList: near,
        aliasList: alias,
        restList: rest,
      },
      null,
      2,
    ),
  );
} else {
  console.log(`桩总数 ${stubs.length}`);
  console.log(`direct ${direct.length}  near ${near.length}  alias ${alias.length}`);
  console.log(`覆盖 ${covered}/${stubs.length} = ${(covered / stubs.length * 100).toFixed(1)}%`);
  console.log(`\n[near ${near.length}]`);
  console.log(near.join("\n"));
  console.log(`\n[alias ${alias.length}]`);
  console.log(alias.join("\n"));
  console.log(`\n[rest ${rest.length}]`);
  console.log(rest.join(", "));
}
