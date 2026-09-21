// run_node.mjs — 干净对照 wasm 在 node V8 下的执行计时 (B 路对照)。
// 同一 wasm 也喂给 WAMR, 保证两路对照字节码相同。
import { readFileSync } from 'node:fs';

const bytes = readFileSync(new URL('../../build/clean_bench.wasm', import.meta.url));
const mod = new WebAssembly.Module(bytes);
const inst = new WebAssembly.Instance(mod, {
  wasi_snapshot_preview1: {
    fd_write: (fd, iov, iovcnt, pn) => 0, // 热路径外, 不真正输出
  },
});

// 校验输出内容 (手抄 fd_write 参数太绕——直接检查内存结果值)
inst.exports._start();
const mem = new DataView(inst.exports.memory.buffer);
const fib = Number(mem.getBigUint64(0, true));
const sum = Number(mem.getBigUint64(8, true));
console.log('fib(29) =', fib, ' sum =', sum);
if (fib !== 514229 || sum !== 499999500000) {
  console.error('RESULT MISMATCH');
  process.exit(1);
}

// 计时: 预热 2 次, 取 10 次中位数
const runs = [];
for (let w = 0; w < 2; w++) inst.exports._start();
for (let i = 0; i < 10; i++) {
  const t0 = process.hrtime.bigint();
  inst.exports._start();
  runs.push(Number(process.hrtime.bigint() - t0) / 1e6);
}
runs.sort((a, b) => a - b);
console.log('node V8 clean wasm: P50', runs[5].toFixed(3), 'ms  min', runs[0].toFixed(3), 'max', runs[9].toFixed(3));
