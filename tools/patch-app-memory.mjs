#!/usr/bin/env node
/*
 * patch-app-memory.mjs — 把 perry 产出的业务模块改成"向运行时模块借内存"。
 *
 * WASM 多模块链接里，同一块线性内存只能有一个定义者。业务模块原本自带
 * `memory`(2 页起)，这里把它改成 import 运行时模块导出的 memory：
 *   - import 段追加一条 `rt.memory` (kind=2, flags=0, min=1)
 *   - memory 段整个删掉 (改由运行时模块提供)
 *
 * 关键点：memory/table 的 import 不占函数索引空间，所以业务模块 code 段里的
 * 函数索引、以及隐式的 memory 0 引用全部不用动。
 *
 * 用法: node tools/patch-app-memory.mjs <in.wasm> <out.wasm> [module] [field] [minPages]
 */
import { readFileSync, writeFileSync } from 'node:fs';

const [inPath, outPath, moduleName = 'rt', fieldName = 'memory', minPagesArg = '1'] = process.argv.slice(2);
const minPages = Number(minPagesArg);

if (!inPath || !outPath) {
  console.error('用法: patch-app-memory.mjs <in.wasm> <out.wasm> [module] [field] [minPages]');
  process.exit(2);
}

const uleb = (buf, off) => {
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
};
const readName = (buf, off) => {
  const [len, start] = uleb(buf, off);
  return [buf.subarray(start, start + len).toString('utf8'), start + len];
};

const writeUleb = (out, value) => {
  let v = value >>> 0;
  do {
    let byte = v & 0x7f;
    v >>>= 7;
    if (v !== 0) byte |= 0x80;
    out.push(byte);
  } while (v !== 0);
};
const writeName = (out, text) => {
  const raw = Buffer.from(text, 'utf8');
  writeUleb(out, raw.length);
  for (const byte of raw) out.push(byte);
};

const buf = readFileSync(inPath);
if (buf.readUInt32BE(0) !== 0x0061736d) throw new Error(`${inPath}: not a wasm module`);

const sections = [];
let off = 8;
while (off < buf.length) {
  const id = buf[off++];
  const [size, start] = uleb(buf, off);
  sections.push({ id, payload: buf.subarray(start, start + size), start, end: start + size });
  off = start + size;
}

let importCount = 0;
let addedImport = false;
let droppedMemorySection = false;

const out = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];

for (const section of sections) {
  if (section.id === 2) {
    const p = section.payload;
    const [count, afterCount] = uleb(p, 0);
    const payload = [];
    writeUleb(payload, count + 1);
    for (let i = afterCount; i < p.length; i++) payload.push(p[i]);
    // 追加 rt.memory: kind=2(memory), flags=0(无 max), min=minPages
    writeName(payload, moduleName);
    writeName(payload, fieldName);
    payload.push(0x02);
    payload.push(0x00);
    writeUleb(payload, minPages);
    importCount = count + 1;
    addedImport = true;
    emit(2, payload);
    continue;
  }
  if (section.id === 5) {
    droppedMemorySection = true;
    continue; // 内存改由运行时模块提供
  }
  emit(section.id, [...section.payload]);
}

function emit(id, payload) {
  out.push(id);
  writeUleb(out, payload.length);
  for (const byte of payload) out.push(byte);
}

writeFileSync(outPath, Buffer.from(out));
console.log(
  `${outPath}: import ${importCount} 条 (新增 ${moduleName}.${fieldName} min=${minPages} 页); ` +
    `memory 段${droppedMemorySection ? '已删除' : '不存在'} -> 由 ${moduleName} 模块提供`,
);
