#!/usr/bin/env node
/*
 * gen-rt-symbols.mjs — 从 typerry 产出的 wasm 导入段生成 `rt` 运行时的符号清单。
 *
 * 用法:
 *   node tools/gen-rt-symbols.mjs <app.wasm> \
 *     [--c    <runtime-c-src>    <out.inc>] \
 *     [--rust <runtime-rs-src>   <out.rs>]
 *
 * 每个目标各生成一份:
 *   - 源文件里已实现 (`rt_<名字>(`) 的导入 → 只登记符号, 不生成桩;
 *   - 其余 → 生成"调用即报错"的桩 (C 抛 wasm 异常 / Rust 写 stderr 后 trap)。
 *
 * 这样做的原因: wasm 链接是"声明级"的 —— 211 个导入必须全部有主, 哪怕只调用 3 个。
 */
import { readFileSync, writeFileSync } from 'node:fs';

const C_TYPE = { i32: 'uint32_t', i64: 'uint64_t', f32: 'float', f64: 'double' };
const SIG_CHAR = { i32: 'i', i64: 'I', f32: 'f', f64: 'F' };
const RUST_TYPE = { i32: 'i32', i64: 'i64', f32: 'f32', f64: 'f64' };
const VALTYPE = {
  0x7f: 'i32',
  0x7e: 'i64',
  0x7d: 'f32',
  0x7c: 'f64',
  0x7b: 'v128',
  0x70: 'funcref',
  0x6f: 'externref',
};

function uleb(buf, off) {
  let result = 0;
  let shift = 0;
  let cursor = off;
  for (;;) {
    const byte = buf[cursor++];
    result |= (byte & 0x7f) << shift;
    if ((byte & 0x80) === 0) break;
    shift += 7;
  }
  return [result >>> 0, cursor];
}

function name(buf, off) {
  const [len, start] = uleb(buf, off);
  return [buf.subarray(start, start + len).toString('utf8'), start + len];
}

function valType(buf, off) {
  const code = buf[off];
  const type = VALTYPE[code];
  if (!type) throw new Error(`未知的 value type 0x${code.toString(16)}`);
  return [type, off + 1];
}

function valTypeList(buf, off) {
  const [count, start] = uleb(buf, off);
  const types = [];
  let cursor = start;
  for (let i = 0; i < count; i++) {
    const [type, next] = valType(buf, cursor);
    types.push(type);
    cursor = next;
  }
  return [types, cursor];
}

function parseTypes(buf, off, end, types) {
  const [count, start] = uleb(buf, off);
  let cursor = start;
  for (let i = 0; i < count; i++) {
    if (buf[cursor++] !== 0x60) throw new Error('期望 functype (0x60)');
    let params;
    let results;
    [params, cursor] = valTypeList(buf, cursor);
    [results, cursor] = valTypeList(buf, cursor);
    types.push({ params, results });
  }
  if (cursor !== end) throw new Error('type 段解析长度不一致');
}

function parseImports(buf, off, end, imports, types) {
  const [count, start] = uleb(buf, off);
  let cursor = start;
  for (let i = 0; i < count; i++) {
    let module;
    let field;
    [module, cursor] = name(buf, cursor);
    [field, cursor] = name(buf, cursor);
    const kind = buf[cursor++];
    if (kind === 0) {
      const [typeIdx, next] = uleb(buf, cursor);
      cursor = next;
      imports.push({ module, field, type: types[typeIdx] });
    } else if (kind === 1) {
      cursor++; // elemtype
      const flags = buf[cursor++];
      const [min, next] = uleb(buf, cursor);
      cursor = next;
      if (flags & 1) [, cursor] = uleb(buf, cursor);
      void min;
    } else if (kind === 2) {
      const flags = buf[cursor++];
      const [, next] = uleb(buf, cursor);
      cursor = next;
      if (flags & 1) [, cursor] = uleb(buf, cursor);
    } else if (kind === 3) {
      cursor += 2; // valtype + mut
    } else {
      throw new Error(`未知的 import kind ${kind}`);
    }
  }
  if (cursor !== end) throw new Error('import 段解析长度不一致');
}

// ---------------------------------------------------------------- 收集导入

const args = process.argv.slice(2);
const wasmPath = args[0];
if (!wasmPath) {
  console.error('用法: gen-rt-symbols.mjs <app.wasm> [--c <src> <out>] [--rust <src> <out>]');
  process.exit(2);
}

const targets = [];
for (let i = 1; i < args.length; i++) {
  const flag = args[i];
  if (flag !== '--c' && flag !== '--rust') throw new Error(`未知参数 ${flag}`);
  targets.push({ kind: flag === '--c' ? 'c' : 'rust', src: args[++i], out: args[++i] });
}
if (targets.length === 0) throw new Error('至少需要一个 --c 或 --rust 目标');

const buf = readFileSync(wasmPath);
if (buf.readUInt32BE(0) !== 0x0061736d) throw new Error(`${wasmPath}: not a wasm module`);

const types = [];
const imports = [];
let off = 8;
while (off < buf.length) {
  const id = buf[off++];
  const [size, start] = uleb(buf, off);
  const end = start + size;
  if (id === 1) parseTypes(buf, start, end, types);
  else if (id === 2) parseImports(buf, start, end, imports, types);
  off = end;
}

const seen = new Map();
for (const entry of imports) {
  if (entry.module !== 'rt') {
    console.error(`跳过非 rt 导入: ${entry.module}.${entry.field}`);
    continue;
  }
  const previous = seen.get(entry.field);
  const signature = entry.type.params.join(',') + '->' + entry.type.results.join(',');
  if (previous && previous !== signature) {
    throw new Error(`${entry.field}: 同名导入签名不一致 (${previous} vs ${signature})`);
  }
  seen.set(entry.field, signature);
}

const fieldType = (field) => imports.find((i) => i.module === 'rt' && i.field === field).type;
const isImplemented = (src, field) => new RegExp(`\\brt_${field}\\s*\\(`).test(src);

// ---------------------------------------------------------------- 生成

for (const target of targets) {
  const src = readFileSync(target.src, 'utf8');
  const chunks = [];
  const symbols = [];
  let stubbed = 0;

  for (const field of seen.keys()) {
    const func = fieldType(field);
    const sig = `(${func.params.map((t) => SIG_CHAR[t]).join('')})${func.results
      .map((t) => SIG_CHAR[t])
      .join('')}`;
    const result = func.results[0];
    const implemented = isImplemented(src, field);

    if (target.kind === 'c') {
      if (implemented) {
        symbols.push(`    { "${field}", (void *)rt_${field}, "${sig}", NULL },`);
        continue;
      }
      const params = func.params.map((t, i) => `${C_TYPE[t]} p${i}`);
      const args = ['wasm_exec_env_t exec_env', ...params].join(', ');
      const unused = func.params.map((_, i) => `    (void)p${i};`).join('\n');
      const body =
        result === undefined
          ? `    (void)perry_rt_unimplemented(exec_env, "${field}");`
          : result === 'f64'
            ? `    return perry_double_of(perry_rt_unimplemented(exec_env, "${field}"));`
            : result === 'f32'
              ? `    return (float)perry_double_of(perry_rt_unimplemented(exec_env, "${field}"));`
              : `    return (${C_TYPE[result]})perry_rt_unimplemented(exec_env, "${field}");`;
      chunks.push(
        `/* 未实现 (签名 ${sig}): 调用即抛 wasm 异常 */\n` +
          `static ${result === undefined ? 'void' : C_TYPE[result]}\nstub_${field}(${args})\n{\n${unused ? unused + '\n' : ''}${body}\n}\n`,
      );
      symbols.push(`    { "${field}", (void *)stub_${field}, "${sig}", NULL },`);
      stubbed++;
      continue;
    }

    if (implemented) continue;
    const params = func.params.map((t, i) => `_p${i}: ${RUST_TYPE[t]}`).join(', ');
    const ret = result === undefined ? '' : ` -> ${RUST_TYPE[result]}`;
    chunks.push(
      `// 未实现 (签名 ${sig}): 调用即写 stderr 并 trap\n` +
        `#[export_name = "${field}"]\n` +
        `pub extern "C" fn stub_${field}(${params})${ret} {\n` +
        `    not_implemented!("${field}")\n}\n`,
    );
    stubbed++;
  }

  const prefix = target.kind === 'c' ? ' * ' : '// ';
  const open = target.kind === 'c' ? '/*' : '//';
  const close = target.kind === 'c' ? ' */' : '';
  const header =
    [
      `${open} rt_symbols.${target.kind === 'c' ? 'inc' : 'rs'} — 由 tools/gen-rt-symbols.mjs 生成, 请勿手改。`,
      `${prefix}来源: ${wasmPath}`,
      `${prefix}导入总数 ${seen.size} (已实现 ${seen.size - stubbed}, 桩 ${stubbed})`,
      close,
    ]
      .filter((line) => line !== '')
      .join('\n');

  const footer =
    target.kind === 'c'
      ? `\nstatic NativeSymbol perry_rt_symbols[] = {\n${symbols.join('\n')}\n};\n`
      : '';
  const pragma = target.kind === 'c' ? '#pragma GCC diagnostic ignored "-Wunused-parameter"\n\n' : '';

  writeFileSync(target.out, `${header}\n\n${pragma}${chunks.join('\n')}${footer}`);
  console.log(
    `${target.out}: ${seen.size} 个 rt 导入 (已实现 ${seen.size - stubbed}, 桩 ${stubbed})`,
  );
}
