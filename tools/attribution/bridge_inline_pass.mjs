#!/usr/bin/env node
/*
 * bridge_inline_pass.mjs — 通用"桥内联"后处理 pass（零上游依赖，跑在 perry 产物上）。
 *
 * 输入: 合并后反汇编的 .wat（aot_e.sh 的 patch_merged 产物：wasm-merge app+rt →
 *       patch_merged.mjs → 本 pass）。也可直接吃 wasm-dis 的任意 perry 产物 wat。
 * 输出: 改写后的 .wat + 覆盖率报告（--report <json>）。
 *
 * 做什么（把 spec_patch.py 的手工特化去特化、泛化到整个模块）：
 *   * js_add 桥（nameId=8, argc=2）：两个操作数均"可证 number"时，把
 *     `(drop (call $mem_call (f64.const 8) (f64.const 2) BASE))` 替换为
 *     `(i64.store BASE (i64.reinterpret_f64 (f64.add (reinterpret_i64 (i64.load BASE))
 *      (reinterpret_i64 (i64.load (BASE+8))))))` —— 与 rt::js_add(Num,Num)=f64.add 逐位等价，
 *     且保留影子栈纪律（sp 减量在调用后照旧执行）。
 *   * is_truthy 桥（nameId=12, argc=1）：操作数"可证是盒布尔"（TAG_TRUE/TAG_FALSE 二值）时，
 *     把 `(call $mem_call_i32 (f64.const 12) (f64.const 1) BASE)` 替换为
 *     `(i32.ne (i64.load BASE) (i64.const TAG_FALSE))` —— rt::truthy(Bool(b))=b，逐位等价。
 *     number 条件保守回退（JS truthiness 里 0/-0/NaN 均 falsy，非二值，不内联）。
 *
 * 类型恢复（数据流抽象解释，值域 NUM/BOOLBOX/OTHER）：
 *   * NUM  = 原始 f64 位型 = JS number。依据 perry codegen 不变量：f64 域运算
 *     （f64.const/load/算术，i64.reinterpret_f64 包络）只作用于 number —— perry 自己的
 *     Sub/Mul/Div 就是无条件内联 F64Sub，故"f64 域生产者 ⇒ number"与 perry 自身同样可信。
 *   * BOOLBOX = TAG_TRUE/TAG_FALSE 二值盒布尔。从模块自身推导（见下），不从外部硬编码。
 *   * 其它（字符串盒、指针盒、未定义/空、桥返回值未知）→ OTHER。
 *   * 函数参数/返回值跨过程推断：对全部直接 call 点做不动点迭代（paramKinds/retKinds）。
 *   * 影子栈槽位按"相对当前 sp 的偏移"建 key，`global.set $sp` 时清空（保守）。
 *
 * TAG_TRUE/TAG_FALSE 从模块自身推导（不硬编码，抗 rt 版本漂移）：
 *   扫描 `(if (result i64) <cond> (then (i64.const A)) (else (i64.const B)))` 与
 *   `(select (i64.const A) (i64.const B) <cond>)`，多数表决 then/else 常量。
 *
 * nameId 语义（js_add=8 / is_truthy=12）来自 perry rt 的固定桥表（见
 * tools/attribution/rt_fast/probe_nameid.md 与 runtime-wasm/src/lib.rs BRIDGES/intern 序）；
 * 它是 rt ABI 的一部分，与具体程序无关。pass 只对已知 (nameId,argc) 且类型可证的调用点动手，
 * 其余桥调用（console_log/string_concat/…）原样保留。若 perry 升级改变该序 → 本 pass 失配
 * （后处理相对上游改造的固有劣势，见 docs/performance.md 后处理节）。
 *
 * 用法:
 *   node tools/attribution/bridge_inline_pass.mjs <in.wat> <out.wat> [--report out.json]
 */
import { readFileSync, writeFileSync } from "node:fs";

// ---------------------------------------------------------------- 值域
const NUM = "NUM";
const BOOL = "BOOLBOX";
const OTHER = "OTHER";
const join = (a, b) => (a === b ? a : OTHER);

// nameId → (rt 桥名, argc)。perry rt ABI 固定（probe_nameid.md）。
const KNOWN = new Map([
  [8, { name: "js_add", argc: 2, inline: "num" }],
  [12, { name: "is_truthy", argc: 1, inline: "bool" }],
]);

// ---------------------------------------------------------------- wat 解析
function tokenize(src) {
  const toks = [];
  let i = 0;
  const n = src.length;
  while (i < n) {
    const c = src[i];
    if (c === ";" && src[i + 1] === ";") {
      while (i < n && src[i] !== "\n") i++;
    } else if (c === "(" && src[i + 1] === ";") {
      let depth = 1;
      i += 2;
      while (i < n && depth > 0) {
        if (src[i] === "(" && src[i + 1] === ";") depth++, i += 2;
        else if (src[i] === ";" && src[i + 1] === ")") depth--, i += 2;
        else i++;
      }
    } else if (c === "(" || c === ")") {
      toks.push(c);
      i++;
    } else if (c === '"') {
      let j = i + 1;
      while (j < n && src[j] !== '"') {
        if (src[j] === "\\") j++;
        j++;
      }
      toks.push(src.slice(i, j + 1));
      i = j + 1;
    } else if (c === " " || c === "\t" || c === "\r" || c === "\n") {
      i++;
    } else {
      let j = i;
      while (j < n && !"() \t\r\n\"".includes(src[j])) j++;
      toks.push(src.slice(i, j));
      i = j;
    }
  }
  return toks;
}

// node: {t:'a', s} | {t:'l', c:[node]}
function parse(toks) {
  let p = 0;
  function one() {
    const t = toks[p++];
    if (t === "(") {
      const c = [];
      while (toks[p] !== ")") c.push(one());
      p++; // consume ')'
      return { t: "l", c };
    }
    return { t: "a", s: t };
  }
  const top = [];
  while (p < toks.length) top.push(one());
  return top;
}

function atom(node) {
  return node.t === "a" ? node.s : null;
}
function head(node) {
  if (node.t !== "l" || node.c.length === 0) return null;
  return atom(node.c[0]);
}

function unquote(s) {
  if (s === null) return null;
  if (s.length >= 2 && s[0] === '"' && s[s.length - 1] === '"') return s.slice(1, -1);
  return s;
}
function kids(node) {
  return node.t === "l" ? node.c : [];
}
function clone(node) {
  if (node.t === "a") return { t: "a", s: node.s };
  return { t: "l", c: node.c.map(clone) };
}
function replaceInPlace(node, other) {
  // 原地改写 node 为 other 的内容（父节点持有同一引用）
  node.t = other.t;
  if (other.t === "a") node.s = other.s;
  else node.c = other.c;
}

function ser(node, ind) {
  if (node.t === "a") return node.s;
  if (node.c.length === 0) return "()";
  if (node.c.length === 1 && node.c[0].t === "a") return "(" + node.c[0].s + ")";
  // 短且无嵌套 → 单行
  let flat = "(";
  let nested = false;
  for (const ch of node.c) {
    if (ch.t === "l") {
      nested = true;
      break;
    }
    flat += " " + ch.s;
  }
  if (!nested && flat.length + 1 <= 72) return flat + ")";
  const pad = " ".repeat(ind);
  const body = node.c.map((x) => pad + " " + ser(x, ind + 1)).join("\n");
  return "(\n" + body + "\n" + pad + ")";
}

// ---------------------------------------------------------------- 工具
function constI32(node) {
  if (node.t !== "l") return null;
  const h = head(node);
  if (h !== "i32.const" && h !== "i64.const" && h !== "f64.const" && h !== "i32.const") return null;
  const v = atom(node.c[1]);
  if (v === null) return null;
  const num = Number(v);
  return Number.isFinite(num) ? num : null;
}
function constI64Big(node) {
  if (node.t !== "l") return null;
  const h = head(node);
  if (h !== "i64.const") return null;
  const v = atom(node.c[1]);
  if (v === null) return null;
  try {
    return BigInt(v);
  } catch {
    return null;
  }
}
function loadOffset(node) {
  // 取 (i64.load [offset=N] [align=M] addr) 的地址子节点 + 字节偏移
  if (node.t !== "l") return { addr: node, off: 0 };
  let off = 0;
  let addr = null;
  for (const ch of node.c.slice(1)) {
    const a = atom(ch);
    if (a !== null && a.startsWith("offset=")) off = Number(a.slice(7)) || 0;
    else if (a !== null && a.startsWith("align=")) continue;
    else addr = ch;
  }
  return { addr: addr ?? node, off };
}

// ---------------------------------------------------------------- 模块装配
function buildModule(top) {
  const mod = { funcs: [], globals: [], exports: {}, imports: [], types: {}, spGlobal: null, memCall: null, memCallI32: null };
  const types = {};
  for (const n of top) {
    const h = head(n);
    if (h === "type") {
      const name = atom(n.c[1]);
      types[name] = n;
    }
  }
  for (const n of top) {
    const h = head(n);
    if (h === "func") {
      mod.funcs.push(parseFunc(n, types));
    } else if (h === "global") {
      mod.globals.push(n);
    } else if (h === "export") {
      const en = unquote(atom(n.c[1]));
      const inner = n.c[2];
      // (export "name" (func $X)) / (global $X) — 取内层引用名
      if (en !== null && inner && inner.t === "l" && inner.c.length >= 2) {
        const ref = atom(inner.c[1]);
        if (ref) mod.exports[en] = ref;
      }
    } else if (h === "import") {
      const m = atom(n.c[1]);
      const f = atom(n.c[2]);
      if (m === "rt" && (f === "mem_call" || f === "mem_call_i32")) {
        mod.imports.push({ field: f, func: atom(n.c[3]) });
      }
    }
  }
  mod.types = types;
  return mod;
}

function parseFunc(n, types) {
  const f = { name: null, params: [], result: null, locals: [], body: [] };
  let i = 1;
  if (atom(n.c[i]) !== null && atom(n.c[i]).startsWith("$")) f.name = atom(n.c[i++]);
  let typeRef = null;
  for (; i < n.c.length; i++) {
    const ch = n.c[i];
    const h = head(ch);
    if (h === "param") {
      // (param $x i64) | (param i64) | (param $x i32 i32)
      if (atom(ch.c[1]) !== null && atom(ch.c[1]).startsWith("$")) {
        for (let j = 1; j < ch.c.length; j += 2) f.params.push({ name: atom(ch.c[j]), type: atom(ch.c[j + 1]) });
      } else {
        for (let j = 1; j < ch.c.length; j++) f.params.push({ name: null, type: atom(ch.c[j]) });
      }
    } else if (h === "result") {
      f.result = atom(ch.c[1]);
    } else if (h === "local") {
      if (atom(ch.c[1]) !== null && atom(ch.c[1]).startsWith("$")) {
        for (let j = 1; j < ch.c.length; j += 2) f.locals.push({ name: atom(ch.c[j]), type: atom(ch.c[j + 1]) });
      } else {
        for (let j = 1; j < ch.c.length; j++) f.locals.push({ name: null, type: atom(ch.c[j]) });
      }
    } else if (h === "type") {
      typeRef = atom(ch.c[1]);
    } else {
      f.body.push(ch);
    }
  }
  if (typeRef && f.params.length === 0 && types && types[typeRef]) {
    // 从类型定义补参数/结果（wasm-dis 偶发形态）
    const t = types[typeRef];
    for (const ch of kids(t)) {
      const h = head(ch);
      if (h === "param") for (let j = 1; j < ch.c.length; j++) f.params.push({ name: null, type: atom(ch.c[j]) });
      else if (h === "result") f.result = atom(ch.c[1]);
    }
  }
  return f;
}


// ---------------------------------------------------------------- 槽位/地址
function slotOff(e, spName) {
  // 返回相对当前 sp 的偏移（负数=sp 下方）；不可判 → null
  if (e.t !== "l") return null;
  const h = head(e);
  if (h === "global.get") return atom(e.c[1]) === spName ? 0 : null;
  if (h === "i32.sub" || h === "i32.add") {
    const a = slotOff(e.c[1], spName);
    const b = constI32(e.c[2]);
    if (a !== null && b !== null) return h === "i32.sub" ? a - b : a + b;
    const a2 = constI32(e.c[1]);
    const b2 = slotOff(e.c[2], spName);
    if (a2 !== null && b2 !== null) return h === "i32.sub" ? a2 - b2 : a2 + b2;
    return null;
  }
  return null;
}

// ---------------------------------------------------------------- 分析
function findBoolTags(top) {
  // 从模块推导 {TAG_TRUE, TAG_FALSE}：if(result i64)/select 的 then/else 常量多数表决
  const thenCnt = new Map();
  const elseCnt = new Map();
  function walk(n) {
    if (n.t !== "l") return;
    const h = head(n);
    if (h === "if") {
      let thenC = null;
      let elseC = null;
      for (const ch of n.c.slice(1)) {
        const hh = head(ch);
        if (hh === "then" && ch.c.length >= 2) thenC = constI64Big(ch.c[ch.c.length - 1]);
        if (hh === "else" && ch.c.length >= 2) elseC = constI64Big(ch.c[ch.c.length - 1]);
      }
      if (thenC !== null && elseC !== null) {
        thenCnt.set(thenC, (thenCnt.get(thenC) || 0) + 1);
        elseCnt.set(elseC, (elseCnt.get(elseC) || 0) + 1);
      }
    } else if (h === "select") {
      const a = constI64Big(n.c[1]);
      const b = constI64Big(n.c[2]);
      if (a !== null && b !== null) {
        thenCnt.set(a, (thenCnt.get(a) || 0) + 1);
        elseCnt.set(b, (elseCnt.get(b) || 0) + 1);
      }
    }
    for (const ch of n.c) walk(ch);
  }
  for (const n of top) walk(n);
  let bestThen = null;
  let bestElse = null;
  for (const [k, v] of thenCnt) if (!bestThen || v > thenCnt.get(bestThen)) bestThen = k;
  for (const [k, v] of elseCnt) if (!bestElse || v > elseCnt.get(bestElse)) bestElse = k;
  if (bestThen === null || bestElse === null) {
    throw new Error("bridge_inline_pass: 模块中未找到盒布尔模式（if/select + i64.const 二值），无法推导 TAG");
  }
  return { trueTag: bestThen, falseTag: bestElse, set: new Set([bestThen, bestElse]) };
}

function kindOf(e, env, boolTags, memCall, memCallI32, retKinds) {
  if (e.t === "a") return OTHER;
  const h = head(e);
  switch (h) {
    case "i64.const": {
      const v = constI64Big(e);
      return v !== null && boolTags.set.has(v) ? BOOL : OTHER;
    }
    case "i64.load": {
      const { addr, off } = loadOffset(e);
      const s = slotOff(addr, env.sp);
      if (s === null) return OTHER;
      return env.slot.get(s + off) || OTHER;
    }
    case "local.get":
      return env.loc.get(atom(e.c[1])) || OTHER;
    case "global.get":
      return env.glb.get(atom(e.c[1])) || OTHER;
    case "i64.reinterpret_f64": {
      const sub = e.c[1];
      if (sub.t !== "l") return OTHER;
      const sh = head(sub);
      if (sh === "f64.reinterpret_i64") return kindOf(sub.c[1], env, boolTags, memCall, memCallI32, retKinds);
      if (sh !== null && sh.startsWith("f64.")) return NUM; // f64.const/load/算术 → 原始 f64 位型
      return OTHER;
    }
    case "select":
      return join(kindOf(e.c[1], env, boolTags, memCall, memCallI32, retKinds), kindOf(e.c[2], env, boolTags, memCall, memCallI32, retKinds));
    case "if": {
      let thenV = null;
      let elseV = null;
      for (const ch of e.c.slice(1)) {
        const hh = head(ch);
        if (hh === "then" && ch.c.length >= 2) thenV = kindOf(ch.c[ch.c.length - 1], env, boolTags, memCall, memCallI32, retKinds);
        if (hh === "else" && ch.c.length >= 2) elseV = kindOf(ch.c[ch.c.length - 1], env, boolTags, memCall, memCallI32, retKinds);
      }
      if (thenV === null) return OTHER;
      return elseV === null ? OTHER : join(thenV, elseV);
    }
    case "call": {
      const c = atom(e.c[1]);
      if (c === memCall || c === memCallI32) return OTHER;
      return retKinds.get(c) || OTHER;
    }
    default:
      return OTHER;
  }
}

// 遍历语句序列；mode: 'collect' | 'rewrite'
function walkStmt(node, env, ctx, boolTags, memCall, memCallI32, retKinds, mode) {
  if (node.t !== "l") return;
  const h = head(node);
  switch (h) {
    case "if": {
      // (if [result] cond (then ...) (else ...))
      let i = 1;
      if (head(node.c[i]) === "result") i++;
      walkStmt(node.c[i], env, ctx, boolTags, memCall, memCallI32, retKinds, mode);
      const base = env.clone();
      const a = base.clone();
      const b = base.clone();
      let thenE = null;
      let elseE = null;
      for (const ch of node.c.slice(i + 1)) {
        if (head(ch) === "then") {
          thenE = ch;
          for (const s of ch.c.slice(1)) walkStmt(s, a, ctx, boolTags, memCall, memCallI32, retKinds, mode);
        } else if (head(ch) === "else") {
          elseE = ch;
          for (const s of ch.c.slice(1)) walkStmt(s, b, ctx, boolTags, memCall, memCallI32, retKinds, mode);
        }
      }
      if (thenE !== null) env.merge(a);
      if (elseE !== null) env.merge(b);
      return;
    }
    case "block":
    case "loop": {
      const base = env.clone();
      let i = 1;
      if (atom(node.c[i]) !== null && atom(node.c[i]).startsWith("$")) i++;
      for (; i < node.c.length; i++) walkStmt(node.c[i], env, ctx, boolTags, memCall, memCallI32, retKinds, mode);
      // 分支可跳过部分体 → 保守并入体前状态
      env.merge(base);
      return;
    }
    case "local.set":
    case "local.tee": {
      if (node.c.length < 3) return;
      walkStmt(node.c[2], env, ctx, boolTags, memCall, memCallI32, retKinds, mode);
      env.loc.set(atom(node.c[1]), kindOf(node.c[2], env, boolTags, memCall, memCallI32, retKinds));
      return;
    }
    case "global.set": {
      if (node.c.length < 3) return;
      walkStmt(node.c[2], env, ctx, boolTags, memCall, memCallI32, retKinds, mode);
      const g = atom(node.c[1]);
      if (g === env.sp) env.slot.clear();
      env.glb.set(g, kindOf(node.c[2], env, boolTags, memCall, memCallI32, retKinds));
      return;
    }
    case "i64.store": {
      const addrN = node.c[node.c.length - 2];
      const valN = node.c[node.c.length - 1];
      walkStmt(addrN, env, ctx, boolTags, memCall, memCallI32, retKinds, mode);
      walkStmt(valN, env, ctx, boolTags, memCall, memCallI32, retKinds, mode);
      const s = slotOff(addrN, env.sp);
      if (s !== null) env.slot.set(s, kindOf(valN, env, boolTags, memCall, memCallI32, retKinds));
      return;
    }
    case "i32.store":
    case "i32.store8":
    case "i32.store16":
    case "f64.store":
    case "f32.store": {
      for (const ch of node.c.slice(1)) walkStmt(ch, env, ctx, boolTags, memCall, memCallI32, retKinds, mode);
      const addrN = node.c[node.c.length - 2];
      const s = slotOff(addrN, env.sp);
      if (s !== null) env.slot.set(s, OTHER);
      return;
    }
    case "drop": {
      // perry 把 `+` 编成 `(drop (call $mem_call (f64.const 8) …))`：结果经 base 槽回传。
      // js_add 内联后的形态是一条 `i64.store`（语句），故必须替换整个 drop 节点。
      const c0 = node.c[1];
      if (c0 && c0.t === "l" && head(c0) === "call" && (atom(c0.c[1]) === memCall || atom(c0.c[1]) === memCallI32)) {
        for (const ch of c0.c.slice(2)) walkStmt(ch, env, ctx, boolTags, memCall, memCallI32, retKinds, mode);
        handleCall(c0, env, ctx, boolTags, memCall, memCallI32, retKinds, mode, node);
        return;
      }
      for (const ch of node.c.slice(1)) walkStmt(ch, env, ctx, boolTags, memCall, memCallI32, retKinds, mode);
      return;
    }
    case "call": {
      // 先走参数（参数表达式里可能有嵌套副作用/调用）
      for (const ch of node.c.slice(2)) walkStmt(ch, env, ctx, boolTags, memCall, memCallI32, retKinds, mode);
      handleCall(node, env, ctx, boolTags, memCall, memCallI32, retKinds, mode, null);
      return;
    }
    case "call_indirect":
      for (const ch of node.c.slice(1)) walkStmt(ch, env, ctx, boolTags, memCall, memCallI32, retKinds, mode);
      env.dropFrame();
      return;
    case "memory.copy":
    case "memory.fill":
    case "memory.init":
    case "table.copy":
    case "table.fill":
      for (const ch of node.c.slice(1)) walkStmt(ch, env, ctx, boolTags, memCall, memCallI32, retKinds, mode);
      env.slot.clear();
      return;
    case "return": {
      if (node.c.length > 1) {
        walkStmt(node.c[1], env, ctx, boolTags, memCall, memCallI32, retKinds, mode);
        if (ctx) ctx.returns.push(kindOf(node.c[1], env, boolTags, memCall, memCallI32, retKinds));
      }
      return;
    }
    default:
      for (const ch of node.c.slice(1)) walkStmt(ch, env, ctx, boolTags, memCall, memCallI32, retKinds, mode);
  }
}

function handleCall(node, env, ctx, boolTags, memCall, memCallI32, retKinds, mode, dropTarget) {
  const callee = atom(node.c[1]);
  const args = node.c.slice(2);
  const nameId = args.length >= 2 ? constI32(args[0]) : null;
  const argc = args.length >= 2 ? constI32(args[1]) : null;
  const base = args.length >= 3 ? args[2] : null;
  const off = base !== null ? slotOff(base, env.sp) : null;
  const site = { node, callee, nameId, argc, off, base, kind: OTHER, argKinds: [], name: null, inlined: false };

  if (callee === memCall || callee === memCallI32) {
    const spec = nameId !== null ? KNOWN.get(nameId) : null;
    if (spec) site.name = spec.name;
    let resultKind = OTHER;
    if (spec && argc === spec.argc && off !== null) {
      const a = env.slot.get(off) || OTHER;
      site.argKinds.push(a);
      if (spec.inline === "num" && callee === memCall) {
        const b = env.slot.get(off + 8) || OTHER;
        site.argKinds.push(b);
        site.kind = a === NUM && b === NUM ? NUM : OTHER;
        resultKind = site.kind;
        // 仅在 drop 位置内联（替换整条 drop）：结果经 base 槽回传，后续 load 照旧读到
        if (mode === "rewrite" && site.kind === NUM && dropTarget) {
          replaceInPlace(dropTarget, makeJsAddInline(base, env.sp));
          site.inlined = true;
        }
      } else if (spec.inline === "bool" && callee === memCallI32) {
        site.kind = a === BOOL ? BOOL : OTHER;
        if (mode === "rewrite" && site.kind === BOOL) {
          replaceInPlace(node, makeIsTruthyInline(base, boolTags.falseTag, env.sp));
          site.inlined = true;
        }
      }
    }
    ctx.sites.push(site);
    // mem_call 把结果写回 base 槽（js_add 结果 = 原始 f64 number；其余未知）
    if (callee === memCall && off !== null) env.slot.set(off, resultKind);
    return;
  }
  // 普通调用：perry 影子栈纪律——实参在 live sp 之下（偏移 < 0），被调方帧在 live sp 之上（偏移 ≥ 0）。
  // 故普通调用只可能踩掉 ≥0 的槽位，保留 <0（实参区）。见 docs/performance.md 后处理节。
  env.dropFrame();
  if (ctx) {
    const argKinds = args.map((a) => kindOf(a, env, boolTags, memCall, memCallI32, retKinds));
    ctx.calls.push({ callee, argKinds });
  }
}

function makeJsAddInline(base, sp) {
  const b0 = clone(base);
  const b1 = clone(base);
  const plus8 = { t: "l", c: [{ t: "a", s: "i32.add" }, b1, { t: "l", c: [{ t: "a", s: "i32.const" }, { t: "a", s: "8" }] }] };
  const load0 = { t: "l", c: [{ t: "a", s: "i64.load" }, b0] };
  const load1 = { t: "l", c: [{ t: "a", s: "i64.load" }, plus8] };
  const f0 = { t: "l", c: [{ t: "a", s: "f64.reinterpret_i64" }, load0] };
  const f1 = { t: "l", c: [{ t: "a", s: "f64.reinterpret_i64" }, load1] };
  const add = { t: "l", c: [{ t: "a", s: "f64.add" }, f0, f1] };
  const rf = { t: "l", c: [{ t: "a", s: "i64.reinterpret_f64" }, add] };
  return { t: "l", c: [{ t: "a", s: "i64.store" }, clone(base), rf] };
}

function makeIsTruthyInline(base, falseTag, sp) {
  const ld = { t: "l", c: [{ t: "a", s: "i64.load" }, clone(base)] };
  const tag = { t: "l", c: [{ t: "a", s: "i64.const" }, { t: "a", s: falseTag.toString() }] };
  return { t: "l", c: [{ t: "a", s: "i64.ne" }, ld, tag] };
}

// ---------------------------------------------------------------- 环境
function makeEnv(sp, glbInitKinds) {
  return {
    sp,
    loc: new Map(),
    glb: new Map(glbInitKinds),
    slot: new Map(),
    dropFrame() {
      // 被调方帧在 live sp 之上：只失效偏移 ≥ 0 的槽位，保留实参区（偏移 < 0）
      for (const k of [...this.slot.keys()]) if (k >= 0) this.slot.delete(k);
    },
    clone() {
      return {
        sp: this.sp,
        loc: new Map(this.loc),
        glb: new Map(this.glb),
        slot: new Map(this.slot),
        clone: this.clone,
        merge: this.merge,
        dropFrame: this.dropFrame,
      };
    },
    merge(other) {
      // 保守并集：仅保留两边一致的 kind
      const pick = (m1, m2, out) => {
        for (const [k, v] of m1) out.set(k, m2.has(k) ? join(v, m2.get(k)) : OTHER);
        for (const [k, v] of m2) if (!m1.has(k)) out.set(k, OTHER);
      };
      const loc = new Map();
      const glb = new Map();
      const slot = new Map();
      pick(this.loc, other.loc, loc);
      pick(this.glb, other.glb, glb);
      pick(this.slot, other.slot, slot);
      this.loc = loc;
      this.glb = glb;
      this.slot = slot;
    },
  };
}

// ---------------------------------------------------------------- main
function main() {
  const [inWat, outWat] = process.argv.slice(2);
  let reportPath = null;
  const ri = process.argv.indexOf("--report");
  if (ri >= 0) reportPath = process.argv[ri + 1];
  // --closed-world: 视导出函数为模块内私有（合并后的 AOT 模块只有 _start 一个入口，
  // 宿主不会用非 number 调导出函数）→ 导出函数的参数也走内部调用点推断。
  // 默认关（保守）：导出函数的参数无内部证据时判 OTHER。
  const closedWorld = process.argv.includes("--closed-world");
  if (!inWat || !outWat) {
    console.error("usage: node bridge_inline_pass.mjs <in.wat> <out.wat> [--report out.json] [--closed-world]");
    process.exit(2);
  }
  const src = readFileSync(inWat, "utf8");
  let top = parse(tokenize(src));
  // 展开顶层 (module ...) 包裹
  if (top.length === 1 && head(top[0]) === "module") top = top[0].c.slice(1);
  const mod = buildModule(top);

  // 识别 mem_call / mem_call_i32（rt 导出；未合并形态为 rt 导入）
  if (mod.exports.mem_call) mod.memCall = mod.exports.mem_call;
  if (mod.exports.mem_call_i32) mod.memCallI32 = mod.exports.mem_call_i32;
  if (!mod.memCall || !mod.memCallI32) {
    for (const im of mod.imports) {
      if (im.field === "mem_call" && !mod.memCall) mod.memCall = im.func;
      if (im.field === "mem_call_i32" && !mod.memCallI32) mod.memCallI32 = im.func;
    }
  }
  if (!mod.memCall || !mod.memCallI32) {
    throw new Error("bridge_inline_pass: 找不到 mem_call/mem_call_i32（导出或 rt 导入均无）");
  }

  // 找影子栈指针全局：init == 65536 的 i32 全局（(mut i32) 或 i32）
  const globalType = (g) => {
    const t = g.c[2];
    if (t && t.t === "l" && head(t) === "mut") return atom(t.c[1]);
    return atom(t);
  };
  const spCands = [];
  for (const g of mod.globals) {
    if (globalType(g) !== "i32") continue;
    if (constI32(g.c[g.c.length - 1]) === 65536) spCands.push(atom(g.c[1]));
  }
  if (spCands.length !== 1) {
    throw new Error(`bridge_inline_pass: 影子栈全局判定失败（init=65536 的 i32 全局 ${spCands.length} 个）`);
  }
  const sp = spCands[0];

  // 全局初始 kind
  const glbInitKinds = new Map();
  for (const g of mod.globals) {
    const name = atom(g.c[1]);
    const init = g.c[g.c.length - 1];
    glbInitKinds.set(name, kindOf(init, makeEnv(sp, glbInitKinds), { set: new Set(), trueTag: null, falseTag: null }, mod.memCall, mod.memCallI32, new Map()));
  }

  const boolTags = findBoolTags(top);

  // 外部可达函数（导出 / 表元素）：参数可能来自模块外
  const extReach = new Set(Object.values(mod.exports));
  for (const n of top) {
    if (head(n) !== "elem") continue;
    const collect = (node) => {
      if (node.t === "a") {
        if (node.s.startsWith("$")) extReach.add(node.s);
        return;
      }
      for (const ch of node.c) collect(ch);
    };
    for (const ch of n.c.slice(1)) collect(ch);
  }

  // 参数自约束：函数体把该参数喂进 f64 域运算 —— perry 的 codegen 自身已把参数当 number
  // （例如 fib 的 `f64.sub (f64.reinterpret_i64 $0) ...`），故这是"模块内可证"的证据，
  // 不依赖外部调用方，也不引入 perry 未有的假设。
  const selfConstrained = new Map();
  for (const f of mod.funcs) {
    const set = new Set();
    const scan = (node, inF64) => {
      if (node.t !== "l") return;
      const h = head(node);
      if (h === "local.get" && inF64) set.add(atom(node.c[1]));
      const childF64 = h !== null && h.startsWith("f64.");
      for (const ch of node.c.slice(1)) scan(ch, childF64 || inF64);
    };
    for (const s of f.body) scan(s, false);
    selfConstrained.set(f.name, set);
  }

  // 不动点（乐观初值 NUM + 单调上推 join）：
  //   * 参数：自约束 → NUM（模块内证据）；外部可达且无自约束 → OTHER；否则乐观初值，由调用点收敛。
  //   * 返回值：乐观初值 NUM，由各 return 表达式的 kind 收敛（递归函数的基例即收敛锚点）。
  const paramKinds = new Map();
  const retKinds = new Map();
  for (const f of mod.funcs) {
    const sc = selfConstrained.get(f.name) || new Set();
    paramKinds.set(
      f.name,
      f.params.map((p) => {
        if (p.name && sc.has(p.name)) return NUM;
        if (!closedWorld && extReach.has(f.name)) return OTHER;
        return NUM;
      }),
    );
    retKinds.set(f.name, NUM);
  }

  for (let iter = 0; iter < 10; iter++) {
    let changed = false;
    for (const f of mod.funcs) {
      const env = makeEnv(sp, glbInitKinds);
      f.params.forEach((p, i) => {
        if (p.name) env.loc.set(p.name, (paramKinds.get(f.name) || [])[i] || OTHER);
      });
      f.locals.forEach((l) => {
        if (l.name) env.loc.set(l.name, OTHER);
      });
      const ctx = { returns: [], calls: [], sites: [] };
      for (const stmt of f.body) walkStmt(stmt, env, ctx, boolTags, mod.memCall, mod.memCallI32, retKinds, "collect");
      if (ctx.returns.length > 0) {
        let r = null; // 从"无信息"起 join（不能用 OTHER 当累加初值，会毒化整个不动点）
        for (const k of ctx.returns) r = r === null ? k : join(r, k);
        const next = join(retKinds.get(f.name), r);
        if (next !== retKinds.get(f.name)) {
          retKinds.set(f.name, next);
          changed = true;
        }
      }
      for (const c of ctx.calls) {
        const pk = paramKinds.get(c.callee);
        if (!pk) continue;
        c.argKinds.forEach((k, i) => {
          if (i >= pk.length) return;
          const next = join(pk[i], k);
          if (next !== pk[i]) {
            pk[i] = next;
            changed = true;
          }
        });
      }
    }
    if (!changed) break;
  }
  if (process.env.PASS_DEBUG) {
    for (const f of mod.funcs) {
      const pk = paramKinds.get(f.name) || [];
      console.error(`  ${f.name}: params=[${pk}] ret=${retKinds.get(f.name)} selfConstrained=[${[...(selfConstrained.get(f.name) || [])]}] ext=${extReach.has(f.name)}`);
    }
   }

  // 重写（二次遍历，用收敛后的 retKinds）
  const report = { boolTags: { trueTag: boolTags.trueTag.toString(), falseTag: boolTags.falseTag.toString() }, funcs: {} };
  for (const f of mod.funcs) {
    const env = makeEnv(sp, glbInitKinds);
    f.params.forEach((p, i) => {
      if (p.name) env.loc.set(p.name, (paramKinds.get(f.name) || [])[i] || OTHER);
    });
    f.locals.forEach((l) => {
      if (l.name) env.loc.set(l.name, OTHER);
    });
    const ctx = { returns: [], calls: [], sites: [] };
    for (const stmt of f.body) walkStmt(stmt, env, ctx, boolTags, mod.memCall, mod.memCallI32, retKinds, "rewrite");
    report.funcs[f.name] = ctx.sites.map((s) => {
      let reason = "ok";
      if (!s.inlined) {
        if (!s.name) reason = "bridge_not_in_inline_set";
        else if (s.argc !== KNOWN.get(s.nameId).argc) reason = "argc_mismatch";
        else if (s.argKinds.length === 0) reason = "base_not_shadow_slot";
        else if (s.kind === OTHER) reason = `arg_kind=${s.argKinds.join("/")}`;
        else reason = "not_in_drop_position";
      }
      return {
        nameId: s.nameId,
        argc: s.argc,
        name: s.name,
        argKinds: s.argKinds,
        inlined: s.inlined,
        reason,
      };
    });
  }

  const byName = new Map();
  let tot = 0;
  let inl = 0;
  for (const sites of Object.values(report.funcs)) {
    for (const s of sites) {
      if (s.nameId === null) continue;
      tot++;
      const key = `${s.nameId}:${s.argc}`;
      const e = byName.get(key) || { nameId: s.nameId, argc: s.argc, name: s.name, total: 0, inlined: 0, reasons: {} };
      e.total++;
      if (s.inlined) {
        e.inlined++;
        inl++;
      } else {
        e.reasons[s.reason] = (e.reasons[s.reason] || 0) + 1;
      }
      byName.set(key, e);
    }
  }
  report.coverage = [...byName.values()].map((e) => ({ ...e, pct: e.total ? Math.round((100 * e.inlined) / e.total) : 0 }));
  report.totals = { sites: tot, inlined: inl, pct: tot ? Math.round((100 * inl) / tot) : 0 };

  writeFileSync(outWat, "(module\n" + top.map((n) => ser(n, 1)).join("\n") + "\n)\n");
  if (reportPath) writeFileSync(reportPath, JSON.stringify(report, null, 1));
  console.log(`bridge_inline_pass: ${inWat} -> ${outWat}`);
  console.log(`  TAG_TRUE=${report.boolTags.trueTag} TAG_FALSE=${report.boolTags.falseTag} sp=${sp} mem_call=${mod.memCall} mem_call_i32=${mod.memCallI32}`);
  for (const c of report.coverage) {
    console.log(`  桥 nameId=${c.nameId}(${c.name}) argc=${c.argc}: ${c.inlined}/${c.total} 内联 (${c.pct}%)${Object.keys(c.reasons).length ? " 未内联: " + JSON.stringify(c.reasons) : ""}`);
  }
  console.log(`  合计: ${report.totals.inlined}/${report.totals.sites} 桥调用点内联 (${report.totals.pct}%)`);
}

main();
