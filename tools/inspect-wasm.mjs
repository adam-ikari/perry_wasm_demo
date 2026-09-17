#!/usr/bin/env node
/*
 * inspect-wasm.mjs — 打印 wasm 模块的 memory / imports / exports / globals / data 概览。
 * 用法: node tools/inspect-wasm.mjs <module.wasm>
 */
import { readFileSync } from 'node:fs';

const VALTYPE = {
  0x7f: 'i32',
  0x7e: 'i64',
  0x7d: 'f32',
  0x7c: 'f64',
  0x7b: 'v128',
  0x70: 'funcref',
  0x6f: 'externref',
};

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
const sleb = (buf, off) => {
  let result = 0;
  let shift = 0;
  let cursor = off;
  let byte;
  do {
    byte = buf[cursor++];
    result |= (byte & 0x7f) << shift;
    shift += 7;
  } while (byte & 0x80);
  if (shift < 32 && byte & 0x40) result |= -(1 << shift);
  return [result, cursor];
};
const str = (buf, off) => {
  const [len, start] = uleb(buf, off);
  return [buf.subarray(start, start + len).toString('utf8'), start + len];
};

const path = process.argv[2];
const buf = readFileSync(path);
const types = [];
const imports = [];
const exports = [];
let off = 8;
const seen = [];

while (off < buf.length) {
  const id = buf[off++];
  const [size, start] = uleb(buf, off);
  const end = start + size;
  seen.push(`${id}:${size}`);
  const p = buf.subarray(start, end);
  let j = 0;

  if (id === 1) {
    const [count, afterCount] = uleb(p, 0);
    j = afterCount;
    for (let i = 0; i < count; i++) {
      const form = p[j++];
      const [np, j1] = uleb(p, j);
      const params = [];
      j = j1;
      for (let k = 0; k < np; k++) params.push(VALTYPE[p[j++]]);
      const [nr, j2] = uleb(p, j);
      const results = [];
      j = j2;
      for (let k = 0; k < nr; k++) results.push(VALTYPE[p[j++]]);
      types.push({ form, params, results });
    }
  } else if (id === 2) {
    const [count, afterCount] = uleb(p, 0);
    j = afterCount;
    for (let i = 0; i < count; i++) {
      let module;
      let field;
      [module, j] = str(p, j);
      [field, j] = str(p, j);
      const kind = p[j++];
      if (kind === 0) {
        const [typeIdx, next] = uleb(p, j);
        j = next;
        const t = types[typeIdx];
        imports.push({
          module,
          field,
          type: `(${t.params.join(',')}) -> ${t.results.join(',') || 'void'}`,
        });
      } else if (kind === 1) {
        j++; // elemtype
        const flags = p[j++];
        [, j] = uleb(p, j);
        if (flags & 1) [, j] = uleb(p, j);
        imports.push({ module, field, type: 'table' });
      } else if (kind === 2) {
        const flags = p[j++];
        let min;
        let max = null;
        [min, j] = uleb(p, j);
        if (flags & 1) [max, j] = uleb(p, j);
        imports.push({
          module,
          field,
          type: `memory min=${min} pages (${min * 65536} B)${max !== null ? ` max=${max}` : ''}`,
        });
      } else if (kind === 3) {
        const vt = p[j++];
        const mut = p[j++];
        imports.push({ module, field, type: `global ${VALTYPE[vt]} mut=${mut}` });
      }
    }
  } else if (id === 5) {
    const [count, afterCount] = uleb(p, 0);
    j = afterCount;
    for (let i = 0; i < count; i++) {
      const flags = p[j++];
      let min;
      let max = null;
      [min, j] = uleb(p, j);
      if (flags & 1) [max, j] = uleb(p, j);
      exports.push({
        module: 'self',
        field: `memory[${i}]`,
        type: `min=${min} pages (${min * 65536} B)${max !== null ? ` max=${max}` : ''}`,
      });
    }
  } else if (id === 6) {
    const [count, afterCount] = uleb(p, 0);
    j = afterCount;
    for (let i = 0; i < count; i++) {
      const vt = p[j++];
      const mut = p[j++];
      const op = p[j++];
      let init = '?';
      if (op === 0x41) {
        const [v, next] = sleb(p, j);
        j = next;
        init = v;
      } else if (op === 0x42) {
        const [v, next] = sleb(p, j);
        j = next;
        init = v;
      } else if (op === 0x43) {
        j += 4;
        init = 'f32const';
      } else if (op === 0x44) {
        j += 8;
        init = 'f64const';
      } else if (op === 0x23) {
        const [, next] = uleb(p, j);
        j = next;
        init = 'global.get';
      } else if (op === 0x7c) {
        init = 'ref.null';
        j += 1;
      }
      j++; // end opcode
      exports.push({
        module: 'global',
        field: `global[${i}]`,
        type: `${VALTYPE[vt]} mut=${mut} init=${init}`,
      });
    }
  } else if (id === 7) {
    const [count, afterCount] = uleb(p, 0);
    j = afterCount;
    for (let i = 0; i < count; i++) {
      let name;
      [name, j] = str(p, j);
      const kind = p[j++];
      const [, next] = uleb(p, j);
      j = next;
      const kn = { 0: 'func', 1: 'table', 2: 'memory', 3: 'global' }[kind];
      const found = exports.find((e) => e.module === 'self' && e.field.startsWith('memory['));
      const entry = { module: 'export', field: name, type: kn };
      if (kn === 'memory' && found) entry.type = found.type;
      if (kn !== 'memory' || !found) exports.push(entry);
    }
  } else if (id === 11) {
    const [count, afterCount] = uleb(p, 0);
    j = afterCount;
    const segs = [];
    for (let i = 0; i < count; i++) {
      const flags = p[j++];
      if (flags === 0 || flags === 2) {
        if (flags === 2) [, j] = uleb(p, j);
        const op = p[j++];
        let addr = 0;
        if (op === 0x41) {
          let v;
          [v, j] = sleb(p, j);
          addr = v;
        }
        j++; // end
        let len;
        [len, j] = uleb(p, j);
        segs.push(`[${addr}, ${addr + len})`);
        j += len;
      } else {
        let len;
        [len, j] = uleb(p, j);
        segs.push(`passive ${len}B`);
        j += len;
      }
    }
    exports.push({ module: 'data', field: `segments(${count})`, type: segs.join(' ') });
  }

  off = end;
}

const pad = (s, n) => String(s).padEnd(n);
console.log(`== ${path} (${buf.length} bytes) ==`);
console.log(`sections: ${seen.join(' ')}`);
console.log(`\nmemory / globals:`);
console.log(`  ${exports.filter((e) => e.module === 'global' || e.module === 'data' || e.field.startsWith('memory[')).length} entries`);
for (const e of exports) {
  if (e.module === 'global' || e.module === 'data') console.log(`  ${pad(e.field, 14)} ${e.type}`);
}
console.log(`\nexported memory: ${exports.filter((e) => e.type?.startsWith?.('min=')).map((e) => e.type).join(', ') || '(none)'}`);
console.log(`\nimports (${imports.length}):`);
for (const i of imports) console.log(`  ${pad(`${i.module}.${i.field}`, 46)} ${i.type}`);
console.log(`\nexports (${exports.filter((e) => e.module === 'export').length}):`);
for (const e of exports) {
  if (e.module === 'export') console.log(`  ${pad(e.field, 40)} ${e.type}`);
}
