# 归因分析复现指南 (tools/attribution/)

目的：把 A 路 2726× / B 路 842× 拆成乘性因子。全部命令在项目根目录执行。

## 文件

| 文件 | 作用 |
|---|---|
| `clean_bench.wat` | 干净对照 wasm：与 src/bench.ts 完全相同的算法 (fib(29)+10^6 循环)，纯 i64 指令、零 rt.* 导入 (仅 wasi fd_write 打印两行结果)。零优化，手工书写 |
| `clean_time.c` | 进程内计时 runner (无 rt 模块)，仿 tools/bench_time.c |
| `run_node.mjs` | 同一干净 wasm 在 node V8 下计时 (B 路对照)，含结果校验 |
| `nohost_app.wat` / `nohost_triv.wat` | 跨模块调用开销对照：与 perry fib 相同的调用图 (每层 2 次跨模块导入)，被调方是平凡 wasm 函数 |
| `bench_perry_wrap.c` | D 路计时包装: 进程级 fork/exec + waitpid (perry 产物无多轮入口) |
| `aot_time.c` | E 路计时 runner: 链接 AOT 构建 libiwasm.a, 加载 .aot (仿 bench_time.c) |
| `aot_e.sh` | E 路一键复现: 合并→补丁→wamrc→校验→计时 (E + E') |
| `patch_merged.mjs` | wasm-merge 产物后处理: 删 __data_end/__heap_base 导出 + 织入 _start wrapper |
| `bench_split.c` | 基线审计: fib 与循环拆开计时 (gcc -O2) |
| `fib_count.c` | 基线审计: fib 入口计数器, 实证 1,664,079 次逻辑调用执行了 |
| `bench_f64.c` | 基线审计: f64 版 C 基线 (与 perry NaN-box f64 位型同语义) |
| `fib_O2.asm` | gcc -O2 fib 反汇编存档: 161 条指令仅 1 个 call 点 (深度自内联) |
| `run_node_steady.mjs` | B' 复测: 阶梯预热观察 V8 tier-up 收敛 (默认/--no-liftoff/--liftoff-only) |
| `nohost_box_app.wat` | 桥机制+装箱税隔离: 与 perry fib 同调用图, call_indirect 防内联 + 最小 NaN-box 往返 |
| `nohost_triv_nomem.wat` | nohost_triv 无 memory 变体 (供 wasm-merge 单 memory 合并) |
| `bench_exec_wrap.c` | 通用 argv 进程级 fork/exec 计时 (bench_perry_wrap 不支持 argv, F 路用) |
| `bench_quickjs.js` | F 路基准: 与 src/bench.ts 同算法同输出 (QuickJS 解释执行 JS) |
| `exp_wasmopt.sh` | 实验 A: wasm-opt 后处理能否内联/折叠桥 (122.1→93.5 ms, 卡点=NAME_CACHE 内存 load) |
| `spec_patch.py` | 实验 B: B1/B2 等价手工类型特化生成器 (从 build/bench_merged_patched.wat) |
| `exp_specialize.sh` | 实验 B 一键复现: B1(+内联)=71.6 / B2(全内联)=17.2 / V3 纯 f64=3.3 ms |
| `specialized_bench_f64.wat` | V3: 纯 f64、无 NaN-box、无影子栈 ("全去盒"版天花板) |
| `switch_recon/` | 编译开关侦察: 逐项实测 perry CLI / 环境变量 / `@typerry/node` / wamrc 全部性能开关。结论 perry 侧无开关, wamrc 仅 `--enable-segue` 有效 (−18.3%)。见其 `README.md` + `REPORT.md` |
| `bridge_inline_pass.mjs` | **通用桥内联 pass**（零上游依赖）: wat→wat 抽象解释恢复类型（NUM/BOOLBOX/OTHER + 跨过程不动点），把可证 number 的 `js_add` 内联成 `f64.add`、可证二值盒布尔的 `is_truthy` 内联成 `i64.ne TAG_FALSE`，其余桥原样保留。`--closed-world` 视导出函数为模块内私有。自报覆盖率 JSON |
| `exp_postpass.sh` | 后处理 pass 一键复现 + 泛化验证: 完整 E 路链路 → pass → 7 变体 → 逐字节正确性 → 覆盖率 → P50。`tools/attribution/exp_postpass.sh all` |
| `probe_ref.mjs` | 生成 perry JS 宿主层参照（`wasmBoot` 的 `run.mjs`），供逐字节比对 |
| `probes/` | 泛化探针: `probe_str.ts`（字符串密集）/ `probe_mixed.ts`（混合类型）/ `probe_nested.ts`（跨函数） |

## 修复实验 (2026-09-21 增补)

```bash
tools/attribution/exp_wasmopt.sh 12      # 实验 A: wasm-opt 变体 → wamrc → 正确性 → P50
tools/attribution/exp_specialize.sh 12   # 实验 B: B1/B2/V3 → wamrc → 正确性 → P50
tools/attribution/exp_postpass.sh all    # 通用桥内联 pass: 4 程序 × 7 变体 → 正确性 → 覆盖率 → P50
```

结论速览 (详见 docs/performance.md「修复路径与天花板」节):
- A: 强制 always-inline 能内联整条桥, 但 NAME_CACHE 运行时内存 load 挡住 switch 折叠,
  P50 122.1→93.5 ms (-23%), 到不了特化量级
- B: 热路径 `+`/条件内联 (等价手工特化) → B1 71.6 ms, B2 17.2 ms (E×0.141, 快 7.1×)
- B2 是"保留 NaN-box + 影子栈"的 codegen 特化上限; B2→E'(1.2 ms) 的余量是影子栈
  内存纪律 (值走内存不走寄存器), 需 typed ABI 级改造

| `bench_f.sh` | F 路一键复现: 构建 qjs→正确性→进程级计时取 P50 |

## 步骤

```bash
WABT=~/.nvm/versions/node/v22.22.2/bin
WAMR_SRC=.deps/wamr
WAMR_BUILD=.deps/wamr-build

# 1. 编译干净对照 wasm
$WABT/wat2wasm --enable-all tools/attribution/clean_bench.wat -o build/clean_bench.wasm
$WABT/wat2wasm --enable-all tools/attribution/nohost_app.wat -o build/nohost_app.wasm
$WABT/wat2wasm --enable-all tools/attribution/nohost_triv.wat -o build/nohost_triv.wasm

# 2. 编译计时 runner
gcc -O2 -Wall -Wextra -I $WAMR_SRC/core/iwasm/include -o build/clean_time \
  tools/attribution/clean_time.c $WAMR_BUILD/libiwasm.a -lm -ldl -lpthread
gcc -O2 -Wall -Wextra -I $WAMR_SRC/core/iwasm/include -o build/xmod_time \
  tools/attribution/xmod_time.c $WAMR_BUILD/libiwasm.a -lm -ldl -lpthread


# 3. A' 干净 wasm × WAMR 解释器 (P50 取 11 次 RUN 的中位数)
./build/clean_time build/clean_bench.wasm 11 | grep RUN

# 4. B' 同一干净 wasm × node V8 (内部预热 2 次、10 次取中位数)
node tools/attribution/run_node.mjs

# 5. 跨模块调用开销 (同调用图、平凡被调方)
./build/xmod_time build/nohost_app.wasm build/nohost_triv.wasm 7 | grep RUN

# 6. E 路 (WAMR AOT): 一键 (E + E'; 构建 wamrc 见脚本头注释)
tools/attribution/aot_e.sh 12

# 7. 反汇编证据
$WABT/wasm2wat --enable-all build/bench.wasm -o /tmp/bench.wat
grep -c 'call 209\|call 210' /tmp/bench.wat   # perry 热路径 mem_call* 调用次数
```
# 8. B' 复测 (V8 tier-up 收敛观察, 2026-09-21)
node tools/attribution/run_node_steady.mjs        # 默认/--no-liftoff/--liftoff-only

# 9. F 路 (QuickJS 对照, 2026-09-21; qjs 构建见下)
make -C /tmp/quickjs-bellard qjs                  # Bellard 官方 quickjs
tools/attribution/bench_f.sh 11                   # P50 行即结果

# 10. E 路第一性原理隔离 (2026-09-21): nohost 系列 × wamrc O3
$WABT/wat2wasm --enable-all tools/attribution/nohost_app.wat -o build/nohost_app.wasm
$WABT/wat2wasm --enable-all tools/attribution/nohost_triv_nomem.wat -o build/nohost_triv_nomem.wasm
node node_modules/.bin/wasm-merge build/nohost_app.wasm app build/nohost_triv_nomem.wasm triv \
  --enable-bulk-memory --enable-nontrapping-float-to-int --enable-multimemory \
  --enable-reference-types --rename-export-conflicts -o build/nohost_merged.wasm
/tmp/wamrc-test/wamrc --opt-level=3 -o build/nohost_merged.aot build/nohost_merged.wasm
./build/aot_time build/nohost_merged.aot 5 | grep RUN      # 直接调用(内联吸收) ≈ 1.4 ms
$WABT/wat2wasm --enable-all tools/attribution/nohost_box_app.wat -o build/nohost_box_app.wasm
/tmp/wamrc-test/wamrc --opt-level=3 -o build/nohost_box_app.aot build/nohost_box_app.wasm
./build/aot_time build/nohost_box_app.aot 8 | grep RUN    # call_indirect+装箱 ≈ 5.9 ms
./build/aot_time build/fib_only.aot 5 | grep RUN          # 纯机 fib ≈ 1.3 ms (闭合用)
```

## 结果 (2026-09-19 实测，详见 docs/performance.md 归因分析节)

| 测量 | P50 | 说明 |
|---|---:|---:|
| 原生同形 (gcc -O2, i64) | 1.47 ms | fib 0.967 + 循环 0.50 |
| 干净 wasm × WAMR (A') | 50.8 ms | fib 43.0 + 循环 5.4 → 解释器因子 ~35× |
| 干净 wasm × node V8 (B') | 4.9 ms | fib 2.32 + 循环 0.36 → V8 因子 ~3.3× |
| perry wasm × WAMR (A) | 4010 ms | → codegen 因子 4010/50.8 ≈ 79×；35×79≈2730 闭合 2726 |
| perry wasm × node (B) | 1239 ms | → codegen+宿主因子 ≈ 253×；3.3×253≈835 闭合 842 |
| perry wasm × WAMR AOT (E) | 146.8 ms | 合并单模块 .aot → codegen 因子 ≈108×；0.97×108 闭合 104.4 |
| 干净 wasm × WAMR AOT (E') | 1.36 ms | ≈原生同速 → AOT 引擎因子 ~1×（解释器 35× 归零） |

## 2026-09-21 审计修正与新增（详见 docs/performance.md"审计"节）

| 测量 | 新值 | 说明 |
|---|---:|---|
| B' 复测 | 3.40 ms（--no-liftoff） | 默认 4.67 未充分 tier-up；V8 因子 3.3×→2.5×，B 路 253×→364×（闭合 910） |
| D 纯执行 | 1.6–2.6 ms | callgrind 19.44 M Ir 换算；D/C 纯执行 1.2–1.9×，E/D 纯执行 54–88× |
| 合并成本 | 无 | 解释器跑合并 2340–2390 vs 双模块 2372–2480 ms |
| wamrc 优化级 | 确认默认 O3 | O0 对照 E 390.8 vs O3 141.4 ms |
| E 每桥成本 | rt 25.4 ns + 装箱 1.4 ns | nohost_box 隔离；E 闭合 1.31+4.60+135.5=141.4 ✓ |
| F. QuickJS | 85.532 ms | fib 61.7 + loop 24.8；F 比 E 快 0.58×（旁证 E 慢在桥形态） |


未完成：minhost（JS 最小桩跑 perry wasm）实验因桩语义复杂超时放弃，B 路 364×
内 codegen 形态与 JS 宿主层的相对占比未拆分，文档中已标注。
