// run_node_steady.mjs — B' 稳态复核: 充分预热触发 V8 wasm tier-up (Liftoff→TurboFan)
// 后再计时, 排除 baseline 编译期的测量污染。
import { readFileSync } from 'node:fs';

const bytes = readFileSync(new URL('../../build/clean_bench.wasm', import.meta.url));
const mod = new WebAssembly.Module(bytes);
const inst = new WebAssembly.Instance(mod, {
  wasi_snapshot_preview1: { fd_write: () => 0 },
});

const run1 = () => inst.exports._start();

// 阶梯预热: 每 25 次测一次 P50(5 轮), 观察 tier-up 收敛点
function p50(n) {
  const runs = [];
  for (let i = 0; i < n; i++) {
    const t0 = process.hrtime.bigint();
    run1();
    runs.push(Number(process.hrtime.bigint() - t0) / 1e6);
  }
  runs.sort((a, b) => a - b);
  return runs[Math.floor(n / 2)];
}

for (const stage of [0, 25, 100, 500, 2000]) {
  for (let i = 0; i < stage; i++) run1();
  console.log(`after ${String(stage).padStart(5)} warmup: P50(5) =`, p50(5).toFixed(3), 'ms');
}
// 稳态正式采样
const runs = [];
for (let i = 0; i < 30; i++) {
  const t0 = process.hrtime.bigint();
  run1();
  runs.push(Number(process.hrtime.bigint() - t0) / 1e6);
}
runs.sort((a, b) => a - b);
console.log('steady P50(30):', runs[15].toFixed(3), 'ms  min', runs[0].toFixed(3), 'max', runs[29].toFixed(3));
// Liftoff-only 对照 (禁 tier-up)
console.log('--- rerun with --liftoff-only if invoked via node --liftoff-only ---');
