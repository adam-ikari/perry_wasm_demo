# perry / typerry / wamrc 编译开关侦察报告

日期: 2026-09-21 · 纯侦察, 未改动项目任何文件 · 驱动脚本与原始数据见本目录 (`tools/attribution/switch_recon/`), 中间产物落在 `/tmp/rc_work/`

---

## 0. 结论（一句话）

**是——但只值约 18–21%。** 唯一的现成有效开关是 **`wamrc --enable-segue`**（配合 `--target=x86_64` + `--disable-llvm-jump-tables` 可到 -18~-21%）；
perry CLI / `@typerry/node` / 环境变量**没有任何**影响 wasm codegen 的开关（所有变体产出字节完全相同的 wasm）。
即便如此，合并产物仍 ~100 ms vs 手写原生 1.4 ms（**~71×**），根因（`+` 编译成动态分派桥调用）未被任何开关触及。

---

## 1. 实测环境与协议

| 项 | 值 |
|---|---|
| wamrc | `/tmp/wamrc-test/wamrc` → wamrc-2.4.3（host x86_64, 默认 target cpu **znver3**, opt 3, size 3） |
| perry CLI | `/tmp/perry-dist/perry`（103 MB, 2025-09-11） |
| typerry | `node_modules/@typerry/node@0.0.2` + `typerry.linux-x64-gnu.node` |
| 计时器 | `build/aot_time <aot> <runs>`（唯一使用的计时工具） |
| 干净对照 | `build/clean_bench.wasm`（589 B, 纯 i64 手写 wat） |
| perry 产物 | `build/bench_merged_patched.wasm`（20.7 KB, wasm-merge 合并 app+rt） |

**⚠ 关键测量约束（实测发现）：** `bench_merged_*.aot` 在 `aot_time` 下**第 4 轮必然崩**（`Exception: string table overflow` → `run 4 failed: unreachable`），
3 次独立复现完全一致；`clean_bench.aot` 跑 12 轮无问题。故协议为：

- merged：`measure.sh <aot> 3 4` = 每进程 3 轮 × 4 进程 = **12 样本**，取 P50
- clean：`measure.sh <aot> 12 1` = **12 样本**，取 P50

所有数字为 median of samples；轮次间的机器漂移见 §3，同轮内 A/B 比较才是有效的。

---

## 2. 表 A — `wamrc` 开关（对 merged 产物，P50 ms）

同轮对照（round4：交错 3 遍 × 12 样本，最可信）：

| 选项 | 是否有效 | 实测 P50 | 依据命令 |
|---|---|---|---|
| `<默认>` | 基准 | **122.14** (min 119.5) | `wamrc -o x.aot build/bench_merged_patched.wasm` |
| `--target=x86_64 --enable-segue --disable-llvm-jump-tables` | ✅ **最强 -18.3%** | **99.84** (min 97.4) | 同左加三开关 |
| `--target=x86_64 --size-level=2 --enable-segue --disable-llvm-jump-tables` | ✅ -18.0% | 100.10 | round4 |
| `--target=x86_64 --enable-segue --disable-llvm-jump-tables --bounds-checks=0 --stack-bounds-checks=0 --disable-aux-stack-check` | ✅ -18.5%（与上等价，无明显增量） | 99.50 | round4 |
| `--target=x86_64 --enable-segue --disable-llvm-jump-tables --enable-tail-call` | ✅ 同上，无增量 | 99.61 | round4 |
| `--target=x86_64 --cpu=x86-64-v3 --enable-segue --disable-llvm-jump-tables` | ✅ -17.6%（无增益） | 100.59 | round4 |
| `--target=x86_64 --enable-segue` | ✅ -15.8% | 102.90 | round4 |
| `--target=x86_64 --disable-llvm-jump-tables` | ✅ -8.4% | 111.87 | round4 |
| `--target=x86_64 --opt-level=2 --enable-segue --disable-llvm-jump-tables` | ➖ 反而更差 | 109.21 | round4 |
| `--enable-segue`（不带 --target） | ✅ -10.5% | 120.24 | round3（同轮 default 134.38） |
| `--target=x86_64`（单独） | ✅ -8.2% | 123.31 | round3（同轮 default 134.38） |
| `--enable-segue --disable-llvm-jump-tables` | ✅ -13.4% | 116.39 | round3 |
| `--opt-level=2` | ⚠ 同轮 -7.5%，跨轮不稳定 | 119.23 / 124.19 | round1 / round3 |
| `--opt-level=1` | ➖ 无 | 124.89 | round1（default 125.63） |
| `--opt-level=0` | ❌ 灾难 | 400.72 (**3.2×**) | round1 |
| `--size-level=2` | ➖ 无 | 121.48 | round1 |
| `--size-level=1` | ➖ 无 | 124.46 | round1 |
| `--size-level=0` | ➖ 无 | 124.22 | round1 |
| `--bounds-checks=0` | ➖ 无 | 121.56 | round1 |
| `--stack-bounds-checks=0` | ➖ 无 | 121.36 | round1 |
| `--disable-aux-stack-check` | ➖ 无 | 121.80 | round1 |
| `--enable-tail-call` | ➖ 无 | 121.68 | round1 |
| `--disable-llvm-intrinsics` | ➖ 无 | 122.44 | round1 |
| `--disable-llvm-jump-tables`（单独） | ✅ 弱 -4% / -8%（配合 target） | 120.53 / 111.87 | round1 / round4 |
| `--disable-llvm-lto` | ➖ 无 | 122.32 | round1 |
| `--disable-llvm-lto --enable-segue` | ⚠ 无增量且 clean 上**变慢 1.8×** | 111.13（clean 2.228） | round2 / round3 |
| `--enable-llvm-passes=default<O3>` | ➖ 无 | 124.51 | round1 |
| `--enable-llvm-passes=inline,loop-unroll` | ❌ 更差 | 126.29 | round2 |
| `--disable-simd` | ➖ 无 | 123.36 | round1 |
| `--invoke-c-api-import` | ➖ 无 | 122.34 | round1 |
| `--enable-shared-heap` | ❌ **更差 +29%** | 161.39 | round1 |
| `--enable-segue=i32.load,i32.store` | ✅ 弱 -3.9%（不如全量） | 120.75 | round1 |
| `--target=x86_64 --cpu=x86-64-v3` | ✅ -8.1% | 117.47 | round2 |
| `--target=x86_64 --cpu=x86-64-v2` | ✅ -7.3% | 118.58 | round2 |
| `--target=x86_64 --cpu=haswell` | ✅ -5.6% | 120.73 | round2 |
| `--target=x86_64 --cpu=skylake` | ✅ -4.0% | 122.76 | round2 |
| `--target=x86_64 --cpu=znver4` | ❌ 编译期 **abort**（本机 LLVM 14 不支持） | FAIL | round2 |
| `--cpu-features=+avx2/-avx2/+prefer-256-bit/-prefer-256-bit` | ➖ 全部无效（含 ±0.5%） | 125.8–129.5 | round3b（同轮 126.13） |
| `--cpu-features=+avx512f` | ❌ 编译成功但 AOT **无法加载** | NA | round3b |
| `--opt-level=4` / `--size-level=4` | ➖ 被钳位，与 3 完全相同 | 123.50 / 122.58 | round5 |
| `--disable-ref-types` | ➖ 无 | 122.41 | round5 |
| `--enable-linux-perf` | ➖ 无 | 122.65 | round5 |
| `--enable-memory-profiling` | ❌ 轻微更差 | 125.89 | round5 |
| `--enable-indirect-mode` / `--xip` | ❌ AOT **无法加载**（exit 1，无诊断） | NA | round1 |
| `--enable-multi-thread` / `--enable-gc` / `--enable-shared-chain` | ❌ AOT **无法加载**（exit 1） | NA | round1 |
| `--enable-dump-call-stack` / `--enable-perf-profiling` | ❌ AOT **无法加载** | NA | round5 |
| `--disable-bulk-memory` | ❌ 编译报错：`bulk memory instruction was found` | FAIL | round5 |
| `--mllvm=-inline-threshold=1000` | ❌ 更差 + 体积 3× | 128.05 | round2 |
| `--mllvm=-unroll-threshold=100000` | ➖ 无 | 124.59 | round2 |
| `--enable-llvm-pgo` | ⚠ 编译成功，但 AOT 报 `resolve symbol __llvm_prf_cnts0 failed` —— 需要 `WAMR_BUILD_STATIC_PGO=1` 的 iwasm 才能收profile，**本环境无法闭环** | NA | 见 §5 |
| `--use-prof-file=<f>` | ⚠ 需要上一步产出的 profile，**本环境无法产出** | 未验证 | — |

**不存在**（help 里没有，传了直接 usage 报错）：`-O0/-O3` 短选项、`--target-arch=...`、`--enable-fast-math`、`--enable-llvm-intrinsics`、`--enable-bounds-checks`（只有 `--bounds-checks=1/0`）。

**干净对照上的同向验证**（同轮 default 1.253）：`--target=x86_64 --enable-segue --disable-llvm-jump-tables` = **1.133（-9.6%）**。
即 segue 的收益在"perry 产物/手写干净产物"上都成立，不是某个模块的偶然。

---

## 3. 表 B — perry CLI 与环境变量（对 wasm codegen）

**方法**：`perry compile src/bench.ts --target wasm -o X` → 产出 `X.html`；从 HTML 里 base64 解出内嵌 wasm，比 md5。

| 开关 | 是否有效 | wasm bytes / md5 | 依据命令 |
|---|---|---|---|
| `<默认>` | 基准 | 9827 / `af3e4dd7dd4a2fbd1b24e8a9394bc198` | `perry compile src/bench.ts --target wasm -o pw` |
| `--target web` | ➖ 与 `--target wasm` **完全相同** | 9827 / `af3e4dd7…` | 同左改 `--target web` |
| `--minify` | ➖ 只压 JS runtime（HTML 245→182 KB），wasm 不变 | 9827 / `af3e4dd7…` | `… --minify` |
| `--fast-math` | ➖ 无 | 9827 / `af3e4dd7…` | 同上 |
| `--fp-contract fast` | ➖ 无 | 9827 / `af3e4dd7…` | 同上 |
| `--march=generic/native/x86-64-v3/znver2` | ➖ 4 个值全无影响 | 9827 / `af3e4dd7…` | 同上 |
| `--no-auto-optimize` | ➖ 无 | 9827 / `af3e4dd7…` | 同上 |
| `--type-check` / `--no-cache` / `--debug-symbols` / `--report-size` / `-v -v` | ➖ 无 | 9827 / `af3e4dd7…` | 同上 |
| `--disable-buffer-fast-path` | ➖ 无 | 9827 / `af3e4dd7…` | 同上 |
| `--output-type staticlib` | ➖ 无（仍出 html） | 9827 / `af3e4dd7…` | 同上 |
| env `PERRY_TARGET_CPU=generic/x86-64-v3` | ➖ 无（只作用于 native target） | 9827 / `af3e4dd7…` | `env PERRY_TARGET_CPU=… perry compile …` |
| env `PERRY_OPT=3` / `PERRY_WASM_OPT=1` | ➖ 无（**且这两个变量名在二进制 strings 里根本不存在**，是臆造名） | 9827 / `af3e4dd7…` | 同上 |
| env `PERRY_PRECOMPILE=1` / `PERRY_ALLOW_PARTIAL_CODEGEN=1` / `PERRY_GC_PROMOTE_IN_PLACE=1` | ➖ 无 | 9827 / `af3e4dd7…` | 同上 |

`perry --version` 无输出（该构建不打印版本）。

**环境变量普查**：`strings /tmp/perry-dist/perry | grep -oE 'PERRY_[A-Z0-9_]{2,}' | sort -u` 命中绝大多数是**运行时全局符号名**（如 `PERRY_AUDIO_BUSES`、`PERRY_ARRAY_PROTO_ITERATOR_PATCHED`），
不是 getenv 开关。真正的编译期 knob 只有：`PERRY_TARGET_CPU`(native only)、`PERRY_SKIP_CODEGEN`、`PERRY_ALLOW_PARTIAL_CODEGEN`、`PERRY_CODEGEN_PROGRESS`、
`PERRY_CODEGEN_UNIT_{TIMING,JOBS,SIZE,BYTES}`、`PERRY_SAVE_LL` / `PERRY_LLVM_KEEP_IR` / `PERRY_KEEP_SYMBOLS` / `PERRY_STATEPOINT_REPORT`。
**其中没有任何一个触及 wasm 代码生成**（上表已实测验证）。

---

## 4. 表 C — `@typerry/node` API 表面

`node_modules/@typerry/node/index.d.ts`（NAPI-RS 自动生成）**只有 3 个导出**，无其它 knob：

```ts
export declare function wasmBare(source: string): Buffer
export declare function wasmBoot(source: string, imports: string, autoBoot: boolean, minify: boolean): Bootput
export declare function wasmHtml(source: string, imports: string, minify: boolean): string
export interface Bootput { wasm: Buffer; runtime: string }
```

| 调用 | 是否有效 | 实测 | 依据命令 |
|---|---|---|---|
| `wasmBare(src)` | 基准 | **9780 B**, md5 `67a48e8a598629575e9136a1fc0a940f` — 与仓库里 `build/bench.wasm` **字节相同** | `node typerry_probe.mjs` |
| `wasmBoot(src,'',true,false)` | ➖ wasm 与 bare 相同 | wasm 9780 / runtime 112 747 chars | 同上 |
| `wasmBoot(src,'',true,true)` | ➖ **wasm 完全不变**，只压 runtime | wasm 9780 / runtime 77 206 chars | 同上 |
| `wasmHtml(src,'',false)` | ➖ | html 124 523 / 内嵌 wasm md5 `67a48e8a…` | 同上 |
| `wasmHtml(src,'',true)` | ➖ wasm 不变 | html 88 982 / 内嵌 wasm md5 `67a48e8a…` | 同上 |
| `imports` 参数 | 只影响宿主 import 对象，不改 codegen | — | 读 main.js / index.d.ts |

原生插件 `typerry.linux-x64-gnu.node` 里唯一的 `PERRY_*` 环境变量是 `PERRY_PRECOMPILE`（编译期预编译开关，与产物性能无关）。

**perry CLI `--target wasm` 与 typerry `wasmBare` 的差异**（9827 vs 9780 B）已定位清楚：wasm-dis 反汇编后逐行 diff，
唯一实质差别是 CLI 版在字符串表里多注册了一个 runtime 导入名 `array_constructor_single`（24 字符），导致后续所有字符串偏移整体 +15；
函数体代码完全相同。**纯导入名表差异，无性能含义。**

---

## 5. 未验证 / 无法闭环的项（如实报告）

| 项 | 状态 | 原因 |
|---|---|---|
| `--enable-llvm-pgo` → `--use-prof-file` 闭环 | **未验证** | `--enable-llvm-pgo` 能编译（182 KB 插桩产物），但运行时报 `AOT module load failed: resolve symbol __llvm_prf_cnts0 failed`。收 profile 需要 `cmake -DWAMR_BUILD_STATIC_PGO=1` 重编 iwasm（`.deps/wamr-build/CMakeCache.txt` 里 `WAMR_BUILD_AOT=0` 且无 STATIC_PGO）。`llvm-profdata-14` 与 `clang-14` 本机存在，但缺插桩运行时的构建。 |
| WASM 侧 `-msimd128` / SIMD 化 | 未验证 | perry codegen 不产 SIMD，源语言层无入口；`--disable-simd` 实测无差异。 |
| `--enable-indirect-mode` / `--xip` / `--enable-multi-thread` / `--enable-gc` / `--enable-shared-chain` / `--enable-dump-call-stack` / `--enable-perf-profiling` | 编译成功但 **AOT 无法加载** | `build/aot_time <aot> 1` → exit 1，无诊断输出；这些特性需要运行时同款构建开关。 |

---

## 6. 最强开关的机制证据（不是安慰剂）

`--enable-segue` 真在改机器码，不是计时噪声：

```
$ wamrc --target=x86_64 --format=object            -o clean_plain.o build/clean_bench.wasm
$ wamrc --target=x86_64 --enable-segue --format=object -o clean_segue.o build/clean_bench.wasm
$ objdump -d clean_plain.o | grep -c '%gs:'   →  0
$ objdump -d clean_segue.o | grep -c '%gs:'   → 27
$ objdump -d clean_segue.o | grep '%gs:' | head -1
   4c:  65 41 88 28   mov %bpl,%gs:(%r8)
```
AOT 体积同步变化：74296 → 72920 B（merged）、2136 → 2056 B（clean）。
运行结果正确（`fib(29) = 514229` / `sum = 499999500000`，每个变体都逐次校验过）。

**运行时可加载性**：WAMR 的 `core/iwasm/aot/aot_runtime.c:1800,2600` 在执行 AOT 前**无条件**把线性内存基址写进 GS
（`os_writegsbase(memory_inst->memory_data)`），条件仅为 `defined(os_writegsbase)`，而 `core/config.h:634` 默认 `WASM_DISABLE_WRITE_GS_BASE 0`。
所以 segue 产物在**本项目这套 WAMR 上开箱可用**——本次所有 segue AOT 都在 `build/aot_time` 下跑通并输出正确结果，已实证。

**限制**：`doc/perf_tune.md` 明示 segue 仅支持 **linux x86-64**；若宿主是多线程/多实例共享一个 rt 模块，GS 基址是**每线程寄存器**，需注意语义。

---

## 7. 复现命令

```bash
# 基准 / 最强组合（merged）
wamrc -o /tmp/a.aot build/bench_merged_patched.wasm
wamrc --target=x86_64 --enable-segue --disable-llvm-jump-tables -o /tmp/b.aot build/bench_merged_patched.wasm
build/aot_time /tmp/a.aot 3      # P50 ~121-134 ms   ← 注意: 第 4 轮必崩 (string table overflow)
build/aot_time /tmp/b.aot 3      # P50 ~99-105 ms

# 干净对照
wamrc -o /tmp/c.aot build/clean_bench.wasm
wamrc --target=x86_64 --enable-segue --disable-llvm-jump-tables -o /tmp/d.aot build/clean_bench.wasm
build/aot_time /tmp/c.aot 12     # ~1.25 ms
build/aot_time /tmp/d.aot 12     # ~1.13 ms

# perry CLI 开关等效性（wasm 字节恒定）
perry compile src/bench.ts --target wasm -o /tmp/pw
node -e 'const h=require("fs").readFileSync("/tmp/pw.html","utf8");const b=Buffer.from(h.match(/[A-Za-z0-9+/=]{2000,}/g)[0],"base64");console.log(b.length,require("crypto").createHash("md5").update(b).digest("hex"))'
# → 9827 af3e4dd7dd4a2fbd1b24e8a9394bc198（任何 flag/env 下都相同）

# 本轮全部驱动脚本 (脚本内 OUT=/tmp/rc_work, 故先落到那里)
mkdir -p /tmp/rc_work
cp tools/attribution/switch_recon/*.sh tools/attribution/switch_recon/*.mjs /tmp/rc_work/
bash /tmp/rc_work/matrix.sh        # 31 开关 × 2 产物
bash /tmp/rc_work/matrix2.sh       # cpu/target/mllvm/组合
bash /tmp/rc_work/round3.sh        # 24 样本复核
bash /tmp/rc_work/round3b.sh       # cpu-features + binaryen wasm-opt 预处理
bash /tmp/rc_work/round4.sh        # 交错 A/B ×3 遍（结论依据）
bash /tmp/rc_work/round5.sh        # 其余 feature/profiling 开关
bash /tmp/rc_work/perry_cli.sh     # perry CLI flag/env 扫描
```
原始数据（本轮实测输出, 随本目录固化）：`{matrix,matrix2,round3,round3b,round4,round5}_results.psv`、`cli_results.txt`。

---

## 8. 附：binaryen `wasm-opt` 预处理（外部步骤，非 perry/wamrc 开关）

对 `bench_merged_patched.wasm` 先过 `wasm-opt` 再喂 `wamrc`：

| 预处理 | 配默认 wamrc | 配 `--enable-segue --disable-llvm-jump-tables` | 结论 |
|---|---|---|---|
| `-O2` | 127.75 | 113.79 | ➖ 无增益（同轮 default 126.13 / segue 组合 ~113） |
| `-O3` | 129.14 | 113.42 | ➖ |
| `-O4` | 127.31 | 113.34 | ➖ |
| `-O3 --flatten` | 128.22 | 113.95 | ➖ |
| `-O3 --inlining-optimizing` | 128.37 | 113.04 | ➖ |
| `-O3 --always-inline-max-function-size=200` | **120.02**（-4.8%），但 AOT 膨胀到 258 KB | 112.45 | ⚠ 有微弱效果但代价大，仍远不如 segue 组合 |
| `-O3`（对 clean 对照） | 1.372 | — | ➖ |

`wasm-opt` 拿 `--enable-bulk-memory --enable-nontrapping-float-to-int --enable-multimemory --enable-reference-types` 才吃这份模块。
结论：**wasm-opt 预处理对 perry 产物没有实质收益**（与 `docs/paper/perry-wasm-paper.md` §4.4 审计中 wamrc O3 已最优的判断一致）。

---

## 9. 一句话给下一步

开关层面已经挖到底：**`--target=x86_64 --enable-segue --disable-llvm-jump-tables` 是天花板，只拿回 ~18–21%（122 → ~100 ms），离 1.4 ms 还差 71×**。
剩下 96% 的差距只能从 perry 的 wasm codegen（`+` → 动态分派桥调用）本身解决，编译开关无能为力。
