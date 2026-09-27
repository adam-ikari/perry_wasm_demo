#!/usr/bin/env node
/*
 * collect-bench.mjs — 把六路基准的原始样本汇总成 machine-readable 结果 + 回归判定。
 *
 * 输入（各路口径见对应脚本，全部落盘在 build/）：
 *   a_runs.txt       tools/bench.sh      A: wasm × WAMR FAST_INTERP（进程内 RUN 行, 已弃 warmup）
 *   b_runs.txt       tools/bench.sh      B: wasm × Node V8（real ms, 已扣 node 启动基线, 已弃 warmup）
 *   c_runs.txt       tools/bench.sh      C: 原生 gcc -O2（进程内 RUN 行, 已弃 warmup）
 *   d_runs.txt       tools/attribution/bench_d.sh    D: perry 原生（进程级 RUN 行, 首轮 warmup 未弃）
 *   e_runs.txt       tools/attribution/aot_e.sh      E: WAMR AOT 合并模块（每进程 1 轮, 首轮 warmup 未弃）
 *   eprime_runs.txt  tools/attribution/aot_e.sh      E': WAMR AOT 干净 wasm 对照（同上）
 *   f_runs.txt       tools/attribution/bench_f.sh    F: QuickJS（进程级 RUN 行, 首轮 warmup 未弃）
 *   bench_results.txt  tools/bench.sh 的 COLD 行（可选, 用于冷启动表）
 *
 * 产出：
 *   build/bench-results.json   machine-readable（artifact 主产物, 同时充当 CI 基线存档）
 *   build/bench_ci_table.txt   六路 + 比率汇总表（artifact）
 *   stdout                     同一张表 + 与文档基线的偏差提示
 *
 * 回归判定口径（重要）：
 *   CI runner 的 CPU 与本机（文档基线机）不同, **绝对毫秒不可跨机比较**。因此判定只比
 *   "各目标相对 C（原生）的倍数"——该比率已除掉了机器绝对速度因子, 剩下的差异才反映
 *   "某一路相对原生的形态变化"（如桥调用退化、AOT 配置失效）。阈值默认 ±50%, 只 warning
 *   不 fail（CI runner 共享 CPU, 噪声远大于本机 ±15%）。
 *   首次运行（不带 --baseline）只记录基线: 本次比率写入 JSON 的 ci_baseline 字段并随 artifact
 *   存档; 之后可用 `--baseline <上一次的 bench-results.json>` 做 CI-vs-CI 比较。
 *
 * 用法:
 *   node tools/ci/collect-bench.mjs [--out build/bench-results.json] [--baseline <json>] [--threshold 0.5]
 */
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { cpus, release, totalmem } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const buildDir = join(root, 'build');

// 文档基线（docs/paper/perry-wasm-paper.md §4.3「结果」六路总表 / 中文摘要「第二段」,
// 本机 AMD Ryzen 7 5800H, 2026-09-19/21 实测）: 各目标中位数 ÷ C 原生中位数。仅作提示性对照,
// 不作断言。
const DOC_BASELINE = {
  source: 'docs/paper/perry-wasm-paper.md §4.3 六路总表（本机 AMD Ryzen 7 5800H, 2026-09-21）',
  ratios: { a: 1757, b: 910, c: 1, d: 4.5, e: 104, eprime: 0.97, f: 61 },
};

// dropFirst: 该文件是否包含未弃的 warmup 首轮。a/b/c 由 tools/bench.sh 内的 `sed -i '1d'` 负责,
// 其余三路脚本各自在 `tail -n +2` / `awk` 里弃首轮, 文件里保留 → 这里补上。
const TARGETS = [
  { key: 'a', file: 'a_runs.txt', dropFirst: false, label: 'WAMR FAST_INTERP (perry wasm + rt.wasm 双模块)' },
  { key: 'b', file: 'b_runs.txt', dropFirst: false, label: 'perry JS 宿主层 (Node V8)' },
  { key: 'c', file: 'c_runs.txt', dropFirst: false, label: '原生 gcc -O2 (基线)' },
  { key: 'd', file: 'd_runs.txt', dropFirst: true, label: 'perry 原生 (进程级, 含 fork/exec)' },
  { key: 'e', file: 'e_runs.txt', dropFirst: true, label: 'WAMR AOT (wasm-merge 合并单模块)' },
  { key: 'eprime', file: 'eprime_runs.txt', dropFirst: true, label: "WAMR AOT 干净 wasm 对照 (E')" },
  { key: 'f', file: 'f_runs.txt', dropFirst: true, label: 'QuickJS 直跑 JS (Bellard qjs, 进程级)' },
];

// ---------------------------------------------------------------- 参数
const argv = process.argv.slice(2);
const argOf = (name, dflt) => {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : dflt;
};
const outPath = argOf('--out', join(buildDir, 'bench-results.json'));
const tablePath = join(buildDir, 'bench_ci_table.txt');
const baselinePath = argOf('--baseline', null);
const threshold = Number(argOf('--threshold', '0.5'));

// 文件里只有两种行: 裸数字（bench.sh 的 a/b/c）和计时包装的 `RUN <i> <ms>`。
function readSamples(file) {
  const path = join(buildDir, file);
  if (!existsSync(path)) return null;
  const rows = readFileSync(path, 'utf8')
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      if (line.startsWith('RUN ')) return Number(line.split(/\s+/)[2]);
      return /^[0-9.]+$/.test(line) ? Number(line) : NaN;
    })
    .filter((v) => Number.isFinite(v));
  return rows;
}

const median = (sorted) => {
  const n = sorted.length;
  if (n === 0) return null;
  return n % 2 ? sorted[(n - 1) / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
};
const round = (v, d = 3) => (v === null ? null : Number(v.toFixed(d)));

const measured = {};   // key -> { n, median, min, max }
const warnings = [];
for (const t of TARGETS) {
  let rows = readSamples(t.file);
  if (!rows || rows.length === 0) {
    warnings.push(`${t.key}: 缺样本文件 build/${t.file}（该路本次未产出结果）`);
    measured[t.key] = null;
    continue;
  }
  if (t.dropFirst) rows = rows.slice(1);
  const sorted = [...rows].sort((x, y) => x - y);
  measured[t.key] = {
    n: sorted.length,
    median: round(median(sorted)),
    min: round(sorted[0]),
    max: round(sorted[sorted.length - 1]),
  };
}

const cMedian = measured.c?.median ?? null;
const ratios = {};
for (const t of TARGETS) {
  const m = measured[t.key];
  if (!m) { ratios[t.key] = null; continue; }
  if (t.key === 'c') { ratios[t.key] = 1; continue; }
  if (!cMedian || cMedian <= 0) { ratios[t.key] = null; continue; }
  ratios[t.key] = round(m.median / cMedian, 2);
}

// ---------------------------------------------------------------- 冷启动（可选）
const cold = {};
const coldPath = join(buildDir, 'bench_results.txt');
if (existsSync(coldPath)) {
  for (const line of readFileSync(coldPath, 'utf8').split('\n')) {
    if (!line.startsWith('COLD ')) continue;
    const [, tag, med, min] = line.split(/\s+/);
    if (tag) cold[tag] = { median_ms: Number(med), min_ms: Number(min) };
  }
}

// ---------------------------------------------------------------- 基线对照
const baseline = baselinePath
  ? { source: baselinePath, ratios: JSON.parse(readFileSync(baselinePath, 'utf8')).ratios_vs_c ?? {} }
  : { source: DOC_BASELINE.source, ratios: DOC_BASELINE.ratios };

const comparison = [];
for (const t of TARGETS) {
  const ciRatio = ratios[t.key];
  const baseRatio = baseline.ratios?.[t.key];
  if (ciRatio === null || ciRatio === undefined || !baseRatio) {
    comparison.push({ target: t.key, ci_ratio: ciRatio ?? null, baseline_ratio: baseRatio ?? null, deviation_pct: null, verdict: 'no-data' });
    continue;
  }
  const dev = ciRatio / baseRatio - 1;
  comparison.push({
    target: t.key,
    ci_ratio: ciRatio,
    baseline_ratio: baseRatio,
    deviation_pct: round(dev * 100, 1),
    verdict: Math.abs(dev) > threshold ? 'warning' : 'ok',
  });
}

// ---------------------------------------------------------------- 环境快照
const gccVersion = (() => {
  try { return execFileSync('gcc', ['-dumpfullversion'], { encoding: 'utf8' }).trim(); }
  catch { return null; }
})();
const env = {
  ci: Boolean(process.env.CI),
  runner_os: process.env.RUNNER_OS ?? null,
  runner_arch: process.env.RUNNER_ARCH ?? null,
  runner_image: process.env.ImageOS ?? null,
  github: process.env.GITHUB_RUN_ID
    ? {
        repository: process.env.GITHUB_REPOSITORY ?? null,
        run_id: process.env.GITHUB_RUN_ID,
        run_attempt: process.env.GITHUB_RUN_ATTEMPT ?? null,
        sha: process.env.GITHUB_SHA ?? null,
        ref: process.env.GITHUB_REF ?? null,
        event_name: process.env.GITHUB_EVENT_NAME ?? null,
      }
    : null,
  cpu_model: (cpus()[0]?.model ?? null)?.trim() ?? null,
  cpu_logical_cores: cpus().length,
  mem_gib: round(totalmem() / 1024 ** 3, 1),
  kernel: release(),
  node: process.version,
  gcc: gccVersion,
  wamr_tag: process.env.WAMR_TAG ?? null,
  perry_version: process.env.PERRY_VER ?? null,
  llvm: process.env.LLVM_VERSION ?? null,
};

// ---------------------------------------------------------------- 输出
const results = {
  schema: 'perry-wasm-demo/bench-results/1',
  generated_at: new Date().toISOString(),
  units: 'ms',
  median_definition: '样本升序排序; 奇数取中位, 偶数取中间两个的均值（与各脚本打印的 P50 至多差一个样本）',
  env,
  targets: Object.fromEntries(TARGETS.map((t) => [t.key, {
    label: t.label,
    source_file: `build/${t.file}`,
    samples: measured[t.key],
    ratio_vs_c: ratios[t.key],
  }])),
  ratios_vs_c: ratios,
  cold_start_ms: cold,
  baseline: { ...baseline, threshold, mode: baselinePath ? 'ci-baseline' : 'first-run-record-only' },
  // 首次运行即 CI 基线候选: 相对比率（跨机可比）, 绝对 ms 只作本地参考。
  ci_baseline: { recorded_at: new Date().toISOString(), ratios_vs_c: ratios },
  comparison,
  warnings,
  notes: [
    'CI runner CPU 与本机（文档基线机 AMD Ryzen 7 5800H）不同, 绝对毫秒不可跨机比较; 回归判定只用 ratio_vs_c。',
    'CI runner 为共享虚拟机, 噪声大于本机 ±15%; ±50% 阈值外的偏差只 warning 不 fail。',
    '论文 docs/paper/perry-wasm-paper.md 附录 A 保留本机历史数值; 本文件是 CI 侧基线（首次运行即建立）。',
  ],
};

const table = [];
table.push(`环境: ${env.runner_os ?? 'local'} / ${env.runner_image ?? '-'} / ${env.cpu_model ?? '?'} (${env.cpu_logical_cores} 逻辑核) / node ${env.node} / gcc ${env.gcc ?? '?'}`);
table.push(`生成: ${results.generated_at}  样本定义: ${results.median_definition}`);
table.push('');
table.push(`${'目标'.padEnd(8)} ${'中位数'.padStart(12)} ${'最小'.padStart(12)} ${'最大'.padStart(12)} ${'n'.padStart(3)}  ${'÷C'.padStart(9)}  ${'÷C(基线)'.padStart(9)}  判定`);
table.push(`${'-'.repeat(8)} ${'-'.repeat(12)} ${'-'.repeat(12)} ${'-'.repeat(12)} ${'-'.repeat(3)}  ${'-'.repeat(9)}  ${'-'.repeat(9)}  ----`);
for (const t of TARGETS) {
  const m = measured[t.key];
  const cmp = comparison.find((x) => x.target === t.key);
  table.push([
    t.key.padEnd(8),
    (m ? m.median.toFixed(3) : 'n/a').padStart(12),
    (m ? m.min.toFixed(3) : 'n/a').padStart(12),
    (m ? m.max.toFixed(3) : 'n/a').padStart(12),
    (m ? String(m.n) : '0').padStart(3),
    (ratios[t.key] === null ? 'n/a' : `${ratios[t.key]}x`).padStart(9),
    (cmp?.baseline_ratio ? `${cmp.baseline_ratio}x` : 'n/a').padStart(9),
    cmp?.verdict === 'warning' ? `WARN ${cmp.deviation_pct > 0 ? '+' : ''}${cmp.deviation_pct}%` : (cmp?.verdict ?? '-'),
  ].join(' '));
}
if (Object.keys(cold).length) {
  table.push('');
  table.push('冷启动 (中位数/最小, ms):');
  for (const [tag, v] of Object.entries(cold)) table.push(`  ${tag.padEnd(28)} ${v.median_ms} / ${v.min_ms}`);
}
table.push('');
table.push(`基线来源: ${baseline.source} (阈值 ±${threshold * 100}%)`);
for (const w of warnings) table.push(`  样本缺失: ${w}`);

const tableText = table.join('\n');
writeFileSync(outPath, JSON.stringify(results, null, 2) + '\n');
writeFileSync(tablePath, tableText + '\n');
console.log(tableText);
console.log(`\nJSON: ${outPath}\n表:   ${tablePath}`);

if (process.env.GITHUB_ACTIONS) {
  for (const cmp of comparison.filter((x) => x.verdict === 'warning')) {
    console.log(`::warning::${cmp.target} ÷C = ${cmp.ci_ratio}x, 基线 ${cmp.baseline_ratio}x (偏差 ${cmp.deviation_pct}%) — 仅提示, 不 fail`);
  }
  for (const w of warnings) console.log(`::warning::${w}`);
}

process.exit(measured.c ? 0 : 2);
