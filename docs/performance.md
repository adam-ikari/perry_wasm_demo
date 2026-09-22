# perry wasm demo 性能基准

同一份 TS 基准程序（`src/bench.ts`）在五套宿主下的实测对照。

```bash
./tools/bench.sh   # 一键复现, 末尾打印下表 (数字与本文一致)
```

## 结论先行

| 目标 | 稳态中位数 | 相对原生 | 冷启动 (进程 real) |
|---|---:|---:|---:|
| A. WAMR 解释器 (FAST_INTERP) | 2470.678 ms（优化前 4009.746） | 1757× | 4879 ms (含预热) |
| B. perry JS 宿主层 (Node V8) | 1280.000 ms（优化前 1239.000） | 910× | 1224 ms |
| C. 原生 gcc -O2 | 1.406 ms | 1× | 3 ms |
| D. perry 原生 (TS → LLVM → 可执行文件) | 6.286 ms（进程级，含 fork/exec） | 4.5× | 6 ms |
| E. WAMR AOT（wasm-merge 合并单模块） | 146.829 ms（复测批 138.7 / 148.7） | 104× | 未测 |

另有 E' 对照：干净 wasm × WAMR AOT P50 = 1.362 ms（与原生 1.406 ms 同速，÷C = 0.97×）。

五路输出逐字节一致：`fib(29) = 514229`、`sum = 499999500000`。

定性结论：**解释器不是性能路线**。WAMR FAST_INTERP 比 V8 JIT 慢约 1.9 倍，比原生慢约
1757 倍（V8 自身距原生也有 ~910 倍，见"解读"）。这个总倍数应读作两个因子的乘积：
解释器引擎代差 ~35× × perry codegen 桥调用形态 ~49×（见"性能分析"），不应理解为
"wasm 比原生慢 1757 倍"的单一引擎差距。这条路的价值不在快，在于验证了
"运行时模块化 + 宿主只剩 WASI"的架构：业务模块 212 个导入全部由另一个 wasm 模块
（`rt.wasm`，Rust `#![no_std]`）提供，宿主进程只做 load/register/instantiate 三步。

**换 AOT 引擎重测后（E 路）**：干净 wasm 与原生同速（E'/C = 0.97×，引擎因子 35×→~1×），
而 perry codegen 桥调用形态因子反而显性放大到 ~108×（49× 里的解释器放大成分消失后
剩余的纯桥成本），总倍数 1757× → 104×。**wasm 在 WAMR 上的正确性能形态是 AOT**，
剩余差距几乎全部来自 perry codegen 的桥调用形态（见"E 路"小节）。

**perry 自己两条后端的差距**（用户最关心的问题）：wasm×WAMR 解释器路比 perry 原生路
慢 **~393×**（2470.678 / 6.286 ms）；换到 AOT 引擎后仍有 **~23×**（146.829 / 6.286 ms）——
同为 perry 编译，AOT 下剩下的 23× 基本全是 codegen 桥调用形态（引擎已与原生同速），
而原生路只比手写 C 基线慢 4.5×（fib 未自内联 + f64 累加链，见"D 路"小节）。

## 测量口径

- **环境**：AMD Ryzen 7 5800H（8C16T，max 4.47 GHz），24 GiB RAM，Linux 6.17.13-2-pve，
  gcc 11.4.0，Node v24.21.0，rustc 1.95.0，WAMR 2.4.3。
- **WAMR 解释器配置**（`.deps/wamr-build/CMakeCache.txt` 实测值）：
  `WAMR_BUILD_INTERP=1`、**`WAMR_BUILD_FAST_INTERP=1`**、`WAMR_BUILD_AOT=0`、
  `WAMR_BUILD_JIT=0`、`WAMR_BUILD_MULTI_MODULE=1`、`CMAKE_BUILD_TYPE=Release`。
  即：**FAST_INTERP 字节码翻译模式，无 AOT、无 JIT**。
- **WAMR AOT 配置**（E 路）：运行时 `build/wamr-aot-build/`（同上 + `WAMR_BUILD_AOT=1` +
  `WAMR_BUILD_WITH_CUSTOM_LLVM=1`，链接系统 LLVM 14 供 JIT 内联 stub，wasm→机器码
  编译由 `wamrc` 完成——wamrc 2.4.3 用系统 LLVM 14 构建（`llvm-config` 版本 14.0.0，
  x86_64 后端即可，无需 build_llvm.sh 自编 LLVM），wamrc 默认 O3/znver3）。
- **时钟**：A、C 用进程内 `clock_gettime(CLOCK_MONOTONIC)`（毫秒）；B 和所有冷启动用
  bash 内建 `time`（`TIMEFORMAT=%3R`，本机无 `/usr/bin/time`）。
- **样本**：稳态每目标 11 轮交错执行（A B C × 11），丢弃第 1 轮 warmup，取 10 个样本，
  报中位数（为准）与最小/最大值。冷启动各 5 次取中位数。
- **D 的一次执行**：perry 产物无多轮入口、单次执行 ~6 ms 低于 bash time 分辨率，
  用 `tools/attribution/bench_perry_wrap.c` 对整个进程 fork/exec + waitpid 计时
  （CLOCK_MONOTONIC）。数字含进程启动 ~0.6 ms（fork+exec+/bin/true 空载基线实测），
  口径对 D 偏保守（比 A/C 的进程内时钟多算启动）。样本同 11 轮，第 1 轮 warmup。
- **B 的扣除**：B 的计时含 node 进程启动，已减去 `node -e ''` 空跑基线
  （5 次中位数：优化前实测 23 ms，优化后重测 24 ms，各对应当批 B 的数字）。
- **E 的一次执行**：`tools/attribution/aot_time.c`（仿 bench_time.c，链接 AOT 构建的
  `libiwasm.a`），`wasm_application_execute_main` 计时行 `RUN i <ms>`。E 路模块因合并
  后 rt 字符串表在多轮 `execute_main` 间累积溢出（第 4 轮起 "string table overflow"，
  解释器下同样复现，是合并单模块形态的多轮限制），改用**每轮独立进程**：每进程
  runner 内 1 次预热 + 1 次计时，12 进程弃第 1 轮取 11 样本。E' 无状态，与 A 同口径
  进程内 11 轮。复现：`tools/attribution/aot_e.sh`。
- **A 的一次执行**：`bench_time`（`tools/bench_time.c`，perry_link 的计时包装，demo 正式
  产物 `host/perry_link.c` 未改动）里 `wasm_application_execute_main` 可重复执行，计时行
  `RUN i <ms>` 来自进程内时钟；实例化开销单独输出 `INIT_MS`。
- **CI 环境（2026-09-21 增补）**：`.github/workflows/bench.yml` 在 GitHub Actions
  （ubuntu-22.04，LLVM 14，与本文基线机同系）上复现六路基准，触发方式为手动
  `workflow_dispatch` 或 PR 打 `bench` 标签（不随 push 自动跑，理由见 workflow 头注释）。
  本文全部本机数值（PVE 虚拟机 / Ryzen 7 5800H / 噪声 ±15%）是**历史基线**；CI runner
  CPU 型号不同、是共享虚拟机（噪声远大于本机），**绝对毫秒不可跨机比较**。因此 CI 的
  回归判定只用「各目标 ÷ C 原生」的**倍数**与本文基线对照（±50% 提示性 warning、不
  fail），结果写入 `build/bench-results.json`（`tools/ci/collect-bench.mjs` 汇总）并上传
  artifact。**CI 首次运行即建立 CI 基线**（存档于 artifact 的 `ci_baseline` 字段，本文
  不覆盖本机数值）；后续可用 `node tools/ci/collect-bench.mjs --baseline <上一次 json>`
  做 CI-vs-CI 漂移比较。

## 复现命令

```bash
# A. WAMR 解释器 (完整链路构建后):
node tools/build-wasm.mjs src/bench.ts --bare build/bench.wasm
node tools/gen-rt-symbols.mjs build/bench.wasm --rust runtime-wasm/src/lib.rs build/rt_symbols.rs
cargo build --release --target wasm32-unknown-unknown --manifest-path runtime-wasm/Cargo.toml
cp runtime-wasm/target/wasm32-unknown-unknown/release/perry_rt_wasm.wasm build/rt_bench.wasm
node tools/patch-app-memory.mjs build/bench.wasm build/bench_link.wasm
gcc -O2 -I .deps/wamr/core/iwasm/include -o build/bench_time \
./build/bench_time build/bench_link.wasm build/rt_bench.wasm 1   # RUN 行即单次耗时

# B. perry JS 宿主层 (V8 参照; wasmBoot 直接出 run.mjs + run.wasm):
node build/ref/run.mjs

# C. 原生基线:
gcc -O2 -o build/bench_native tools/bench_native.c && ./build/bench_native 1

# D. perry 原生 (一键: 下载+校验+编译+计时):
tools/attribution/bench_d.sh 11   # P50 行即结果, 编译器装 /tmp/perry-dist

# D 手动步骤 (等价):
curl -sL -C - -o /tmp/perry-dl.tar.gz \
  https://github.com/PerryTS/perry/releases/download/v0.5.1520/perry-linux-x86_64.tar.gz
echo "3423d9fea9bce9b2011fa53b5788a5ca115c947352b5c67278147de30fd2f952  /tmp/perry-dl.tar.gz" | sha256sum -c -
mkdir -p /tmp/perry-dist && tar xzf /tmp/perry-dl.tar.gz -C /tmp/perry-dist
/tmp/perry-dist/perry compile src/bench.ts -o build/bench_perry_native
gcc -O2 -Wall -Wextra -o build/bench_perry_wrap tools/attribution/bench_perry_wrap.c
./build/bench_perry_wrap build/bench_perry_native 11   # RUN 行, 取中位数

# E. WAMR AOT（一键, E/E' 构建+校验+计时）:
tools/attribution/aot_e.sh 12   # P50 行即结果; wamrc 默认取 /tmp/wamrc-test/wamrc

# E 手动步骤 (等价):
node_modules/.bin/wasm-merge build/bench_link.wasm app build/rt_bench.wasm rt \
  --enable-bulk-memory --enable-nontrapping-float-to-int --enable-multimemory \
  --enable-reference-types --rename-export-conflicts -o build/bench_merged_aot_src.wasm
node tools/attribution/patch_merged.mjs build/bench_merged_aot_src.wasm build/bench_merged_patched.wat
node_modules/.bin/wasm-as build/bench_merged_patched.wat --enable-bulk-memory \
  --enable-nontrapping-float-to-int --enable-multimemory --enable-reference-types \
  -o build/bench_merged_patched.wasm
wamrc -o build/bench_merged.aot build/bench_merged_patched.wasm
build/aot_time build/bench_merged.aot 1          # RUN 行即单次耗时 (每进程 1 轮)
wat2wasm --enable-all tools/attribution/clean_bench.wat -o build/clean_bench.wasm
wamrc -o build/clean_bench.aot build/clean_bench.wasm
build/aot_time build/clean_bench.aot 11          # RUN 行, 进程内 11 轮
 ```

## 结果

稳态 10 样本（毫秒，交错采集，来源 `build/a_runs.txt` `b_runs.txt` `c_runs.txt`；
2026-09-19 第二次实测，rt 已采纳 nameId 缓存直查优化）：

D 路样本（同日采集，`build/d_runs.txt`，11 轮第 1 轮 warmup；同法复测四批
P50 = 6.651 / 6.558 / 6.428 / 6.286 ms，散布 ±6%）：

**D 路编译信息**：perry v0.5.1520 预编译 release（`perry-linux-x86_64.tar.gz`，
624,641,943 B 解压前 / 2.2 GiB 解压后，sha256 `3423d9fe…83d`）。编译命令
`perry compile src/bench.ts -o build/bench_perry_native`，耗时 **1.9 s**
（LLVM 22.1.8 in-process 后端），产物 `build/bench_perry_native` **16.3 MB**
（17,099,736 B，动态链接 libc/libm/libgcc_s；含全量 perry-runtime + stdlib，
编译器提示可用 PERRY_WORKSPACE_ROOT 源码重建瘦身，未做）。
CLI 无优化等级开关（`perry compile --help` 全量选项无 -O 系），LLVM O 系默认固定。

| 目标 | 中位数 P50 | 最小 | 最大 |
|---|---:|---:|---:|
| E. WAMR AOT (perry wasm, 合并单模块) | 146.829 | 143.097 | 158.074 |
| E'. WAMR AOT (干净 wasm 对照) | 1.362 | 1.317 | 1.409 |
| A. WAMR 解释器 | 2470.678 | 2378.375 | 2527.101 |
| B. Node V8 (扣除启动 24 ms) | 1280.000 | 1246.000 | 1311.000 |
| C. 原生 gcc -O2 | 1.406 | 1.357 | 3.092 |
| D. perry 原生 (进程级，含启动) | 6.286 | 5.946 | 7.306 |

倍数（以 C 为 1）：A = 1757.2×，B = 910.4×，D = 4.5×，E = 104.4×。
（本批 C 进程内复测 P50 1.479 ms，D/C = 4.3×，同量级。）
**E 路口径注意**：E 每轮独立进程（与 A/C 的同实例多轮略不同，原因见"测量口径"）；
E' 与 A' 同构（干净 wasm × 引擎 vs 原生基线），倍数换算可比。

优化前（同机同口径，2026-09-19 首次实测，rt 为按名扫描版）：

| 目标 | 中位数 P50 | 最小 | 最大 |
|---|---:|---:|---:|
| A. WAMR 解释器（优化前） | 4009.746 | 3866.041 | 4499.434 |
| B. Node V8 (扣除启动 23 ms) | 1239.000 | 1204.000 | 1387.000 |
| C. 原生 gcc -O2 | 1.471 | 1.322 | 1.692 |

倍数（以 C 为 1）：A = 2725.9×，B = 842.3×。

前后对比：**A 路 P50 4009.746 → 2470.678 ms（−38%）**，codegen 因子 79× → ~49×
（÷ A' 50.8 ms），总倍数 2726× → 1757×。

AOT 引擎下的对照（E/E'，2026-09-19 增补）：**A 2470.678 → E 146.829 ms（16.8×）**，
引擎因子 35× → **0.97×**（E' 1.362 ms ≈ 原生 C 1.406 ms），codegen 因子 49× →
**~108×**（E 146.829 ÷ E' 1.362）。见"性能分析"末的 E 路分解。

冷启动（进程启动到输出完成，中位数/最小，毫秒；2026-09-19 优化采纳后重测）：

| 目标 | real 中位数 | 说明 |
|---|---:|---|
| A. WAMR | 4879 / 4836 | `bench_time` 固定先跑 1 次预热再计时，real 含两次执行；单次 ≈ 4879 − 2471 − 7 ≈ 2401 ms |
| A. INIT_MS（进程内） | 6.883 / 8.042 | main 入口 → 双模块加载/注册/实例化完成，不含计算 |
| B. Node | 1224 / 1202 | 含 node 启动 24 ms + 读 2617 行 run.mjs + instantiate + 执行 |
| C. 原生 | 3 / 3 | 进程启动 + 执行 1.5 ms |
| D. perry 原生 | 6 / 6 | 进程启动 + 执行，与稳态进程级计时同口径 |
（优化前：A real 7836/7685，单次 ≈ 3819 ms；INIT_MS 6.728/6.344；B 1284/1241；C 3/3。）

## 基线可信度审计（2026-09-19 增补）

针对质疑"原生 1.471 ms 物理上可疑（每层递归 0.6–0.9 ns 不可能）"，用三条独立证据
核查。结论：**计时数字成立，怀疑的物理矛盾来自 gcc -O2 对 fib 的深度自内联展开**
——1,664,079 次"逻辑调用"只发生 **91,759 次真实 call**（两个独立实测互相印证：
gdb 断点 warmup+1 RUN 命中 183,519 ÷ 2 次顶层执行 = 91,759；callgrind 调用图上
fib 与内联克隆体 fib'2 的入口合计同为 183,519）。来源是 gcc 把自递归
部分内联克隆进 main 和 fib 自身——`tools/attribution/fib_O2.asm` 161 条指令内
4 个 call 点、2 个克隆体，平均一次真实 call 覆盖 ~18 层逻辑调用。按真实 call
折算：fib 部分 0.84 ms / 91,759 ≈ **9.2 ns/真实 call（≈27 cycles @3 GHz）**——
质疑者的物理直觉对"真实 call"完全正确，错在把逻辑调用数当成了真实调用数。
这同时意味着：**原生基线执行的动态指令量远少于
wasm 路径在同语义下的指令量，"1757×"里的一部分是这种代码形态差异，而非全部是
解释器/桥的运行时代价**——乘积分解已将其计入引擎因子（干净 wasm × WAMR 35×）的
分母一侧，无需改数，但呈现上必须按因子乘积读（见下）。

证据一：**多编译器交叉验证**。同一 `bench_native.c` 在 gcc -O1/-O2/-O3/-Ofast/-Os 与
clang -O2 下 P50 分别为 3.604 / 1.471 / 1.240 / 1.296 / 2.337 / 2.170 ms——五种独立
编译管线聚在 1.2–3.6 ms，同数量级；若有病态折叠，应出现离群值。

证据二：**指令计数闭合检验**（callgrind 实测）：

| 编译 | 单次执行指令数 | 静态 call 点 | P50 | IPC（指令/周期 @3.0 GHz） |
|---|---:|---:|---:|---:|
| gcc -O2（基线） | 16.71 M | 4（2 克隆体） | 1.471 ms | ~3.8 |
| gcc -O1（对照） | 28.13 M | 2 | 3.604 ms | ~2.6 |

IPC 3.8 对简单整数短依赖链合理（现代前端每周期取发 4–6 宏操作，无缓存/分支
缺失；O1 指令多 1.7 倍而耗时多 1.4 倍，IPC 相应更低）。若 gcc 跨 printf 合并了
两次 fib 调用，每轮指令增量会减半——实测每轮增量恒为 16.71 M；且 `fib(29)` 的
1,664,079 次逻辑调用由计数器实证（`tools/attribution/fib_count.c`，gcc -O2 下
count=1,664,079，输出不变）。
注：perf 未安装，改用 callgrind（指令数精确；周期数由 P50×实测频率 ~3.0 GHz
推算，机器为共享 PVE 虚拟机，±15% 噪声）。

证据三：**拆分计时**（`tools/attribution/bench_split.c`，gcc -O2）：fib 部分 P50 0.84 ms +
循环部分 0.30 ms ≈ 1.13 ms，与整体 1.47 ms 构成吻合（差额为两次 clock_gettime 与
printf）。同型 f64 变体（`bench_f64.c`，与 perry NaN-box 的 f64 位型同语义）P50
2.52 ms——C 基线用 i64 是公平下界，f64 版仅慢 ~1.8×，量级不变。

**结论：基线 1.471 ms 成立**（今日复测 1.683 ms，同量级；五编译器 1.2–3.6 ms）。
1757× 数字保留，但表述改为乘性分解优先：A = (干净 wasm × WAMR ÷ 原生 ≈ 35×) ×
(perry codegen+rt 桥 ÷ 干净 wasm ≈ 49×)。"与原生差异大"的主体（49×）确实不在
解释器，而在 perry codegen 的桥调用形态——这比"1757× 的引擎差距"更接近事实，
也已是对 perry 更公平的定位。

工具局限：valgrind 下 WAMR 宿主因 `touch_pages` 栈增长受限 SIGSEGV（8M/128M/512M
主栈同样），A/A' 路的动态指令数无法用 callgrind 直接测，未能给出"wasm 路每语义步
指令数 vs 原生"的直接比值 [INFERENCE：由 35× 与各自 IPC 估算，wasm 路指令量约为
原生的 10–20 倍]。

## 解读

**解释器 vs V8 JIT。** 同一份 wasm 字节码语义，FAST_INTERP（把 wasm 字节码翻译成内部
栈式指令再解释）与 V8 的 JIT 管线差约 3.2 倍。~~fib 循环本身不调用 `rt.*`，两路稳态
差距的直接来源是 wasm 执行引擎的代差~~ ——此句已被性能分析证伪（见下节）：fib 每层
递归 2 次、循环每迭代 2 次桥调用；3.2× 是 JS 宿主桥链 vs rt.wasm 桥链的成本比，
真正的引擎代差（干净代码下）是 ~10×。

**rt.wasm 在总耗时里的占比。** ~~本基准的热循环不经过 `rt.*` 导入，只有推断：占比应在
1% 以下~~ ——已证伪（见下节反汇编证据）：热路径每层/每迭代 2 次桥调用，
rt 桥链是两路耗时的主体。冷启动里 `INIT_MS`（7.2 / 6.9 / 6.7 ms 三次实测）含双模块
加载+链接+实例化，对 ~2.5–4 秒的总耗时同样可忽略（这一条实测成立）。

**对 demo 定位的意义。** 数字坐实了文档里已有的定性判断：这套架构交付的是"一次分发 +
到处运行 + 源码保护"，不是性能。性能分析进一步表明：A 路耗时的主因不是解释器而是
codegen 的桥调用形态（优化前 79× → 采纳 nameId 缓存直查后 ~49× vs 35×）；跨模块
链接本身的成本很小（~30 ns/次），架构层
（多模块、宿主只剩 WASI）没有让本已慢的执行雪上加霜，这一条正面验证成立。

## 性能分析（2026-09-19 增补，对照实验实测）

方法：手写一份与 `src/bench.ts` 完全同算法的**干净对照 wasm**（`tools/attribution/clean_bench.wat`，
纯 i64 指令、无 NaN-box、无 rt.* 导入），分别跑在同一 WAMR 解释器（A'，`tools/attribution/clean_time.c`，
复用同一 `libiwasm.a`）和 node V8（B'，`tools/attribution/run_node.mjs`）下，
把"解释器/引擎慢"与"perry codegen 产出差"拆开；再用两个平凡模块互调（`nohost_*.wat` +
`xmod_time.c`）单独量出 WAMR 跨模块调用本身的开销。fib/循环的占比用
`tools/attribution/fib_only.wat` / `loop_only.wat` 与原生同形拆分实测。
复现步骤见 `tools/attribution/README.md`。

**反汇编证据**（`wasm2wat build/bench.wasm`）：fib（func 212）每次调用含 **2 次 rt.* 动态
分派**——`n<2` 判定经 `mem_call_i32`(is_truthy)、加法经 `mem_call`(js_add)；`n-1/n-2`
减法和 f64.lt 比较反而是内联 wasm 指令。循环体每迭代 2 次（`mem_call_i32`(is_truthy) +
`mem_call`(js_add)）。合计热路径约 533 万次桥调用（fib 29 调用 1,664,079 次 × 2 +
循环 10^6 × 2）。rt 侧每次 `mem_call` 要做：参数位型解码 → **按名字线性扫描 10 项桥注册表**
（逐项 memcmp，`runtime-wasm/src/lib.rs` `invoke()`）→ 按 tag 分派 → `js_add` 内部再走一次
NaN-box 解码 → f64.add → 结果编码。perry codegen 还把所有数值装进 NaN-box（i64 位型 +
`f64.reinterpret`/`i64.reinterpret` 往返），干净的 `n-1` 变成 reinterpret 对 + 栈操作序列。

### A 路 1757× 的乘性分解（全部实测）

| 成分 | 倍数 | 证据命令/来源 |
|---|---:|---|
| WAMR FAST_INTERP vs 原生（干净代码下） | **~35×** | A' 干净 wasm 50.8 ms（fib 43.0 + 循环 5.4）÷ 原生同形 1.47 ms（fib 0.967 + 循环 0.50） |
| perry codegen 差 + rt 桥实现 vs 干净 wasm（同在 WAMR） | **~49×** | A 2470.678 ms（2026-09-19 优化后重测）÷ A' 50.8 ms |
| **乘积校验** | 35×49 ≈ **1703** vs 实测 1757（误差 3.1%） | 闭合 ✓ |

优化前矩阵（rt 为按名扫描版，2026-09-19 首测）：codegen 因子 ~79×（A 4010 ms ÷
A' 50.8 ms），35×79 ≈ 2730 vs 实测 2726（误差 0.2%）。nameId 缓存直查采纳后因子
降到 ~49×，两者差值即"桥实现低效"成分（线性扫描）的贡献。

79×→49× 的成分拆解（fib 部分，优化前口径）：干净 wasm fib 每层调用 ~26 ns
（43 ms / 166 万层），perry 版优化前每层 ~1.29 µs（2146 ms / 166 万层），其中——

| fib 每层的成本 | 量级 | 证据 |
|---|---:|---|
| WAMR 跨模块导入调用本身（平凡被调方） | ~0.1 µs/次 ×2 次 | `xmod_time` 实测：同调用图、被调方为平凡 wasm 函数时 fib(29) 全程 ~139 ms vs 干净版 ~43 ms，差值 ≈ 96 ms / 166 万层 ≈ 58 ns/层（每次跨模块调用 ~30 ns） |
| rt 桥分派 + NaN-box 解码/编码 ×2 | 大头 | 总差 1.29 µs − 0.1 µs ≈ 1.2 µs/层由 rt 侧分派 + 装箱构成 [INFERENCE，未逐项插桩]；其中线性扫描成分已实测消除（见"算术过桥问题"第 3 点）|
| perry 指令形态（NaN-box reinterpret 对、栈搬运、f64 而非 i64 算术） | 中等 | 干净版 fib 在 WAMR 上 26 ns/层已含解释器开销；perry 版多出每层 ~20 条辅助指令（见 wasm2wat）|

结论：**优化后 A 路 1757× 的主因是 perry codegen 的桥调用形态（每层递归 2 次动态分派 +
NaN-box 解码/编码），约 49×（含 rt 桥剩余实现成本）；解释器本身只贡献 ~35×。**
（rt 侧线性按名分派成分已通过 nameId 缓存直查消除，79× → 49×。）

### E 路 104× 的乘性分解（WAMR AOT 引擎，全部实测）

用户裁决"解释器不是 wasm 的性能形态，必须开 AOT 重测"后的 E 路矩阵（AOT 构建/合并
方案/口径见"测量口径"与 `tools/attribution/aot_e.sh`）：

| 成分 | 倍数 | 证据命令/来源 |
|---|---:|---|
| WAMR AOT vs 原生（干净代码下） | **~0.97×**（与原生同速） | E' 干净 wasm 1.362 ms ÷ 原生 1.406 ms |
| perry codegen 差 + rt 桥实现（同在 WAMR AOT，rt 代码也进机器码） | **~108×** | E 146.829 ms ÷ E' 1.362 ms |
| **乘积校验** | 0.97×108 ≈ **105** vs 实测 104.4（误差 <1%） | 闭合 ✓ |

与解释器矩阵（35× × 49× = 1757×）对照，AOT 揭示的事实：

1. **引擎因子归零**：A' 50.8 ms → E' 1.362 ms（37×），干净 wasm 在 WAMR AOT 下与
   gcc -O2 原生同速。解释器 35× 是纯引擎开销，与 perry 无关——用户"解释器不是 wasm
   的性能形态"的裁决成立。
2. **codegen 因子从 49× 变 ~108×，不是变差**：解释器下 49× 的分母（A' 50.8 ms）含
   解释器对**所有**代码的放大（干净代码也被解释拖慢 35×），桥调用的 rt 侧（wasm 解释
   执行）同样被解释拖慢；AOT 下分母与 rt 侧都是机器码，剩下的差距是"perry NaN-box/
   桥调用形态的机器码 vs 干净 i64 机器码"的纯 codegen 成本。fib 每层 ~20 条辅助指令 +
   2 次桥调用的真实代价在 AOT 下无处可藏。**49× 里"解释器放大"成分约占一半，
   另一半（机器码形态成本）在 AOT 下全部保留。** [INFERENCE：49×→108× 的因子变化
   是分母定义改变的结果，两个因子不可直接相除比较]
3. **B 路被反超**：E 146.8 ms 比 B（V8 + perry JS 宿主层）1280 ms 快 8.7×——
   同一份 perry wasm，WAMR AOT + wasm rt 桥 比 V8 + JS 宿主桥 快一个数量级。
   A 路慢是解释器的锅，不是"wasm 路线不行"。
4. **对 perry 的定位**：换到 AOT 后 perry wasm 路与 perry 原生路（D 6.286 ms）差
   **~23×**（解释器下 393×），且这 23× 几乎全是 codegen 桥调用形态（引擎已归零）——
   修复 wasm codegen 的类型特化/内联（见"算术过桥问题"第 2 点）后，wasm 路与原生路
   的差距有望收敛到与 D/C（4.5×）同量级。

E 路模块形态备注（对架构文档的重要事实）：**WAMR AOT 文件格式不支持 import memory**
——`core/iwasm/compilation/aot_emit_aot_file.c` 硬编码 `import_memory_count = 0`
（TODO 注释），加载时 `core/iwasm/aot/aot_validator.c` 直接拒绝
（"import memory is not supported"）。demo 的双模块结构（app import rt.memory）因此
**无法整体 AOT**：app.aot + rt.aot 运行即 "out of bounds memory access"。可行的
AOT 形态是 `wasm-merge`（binaryen）把 app+rt 合并成单模块再 wamrc（E 路）。混载
实测：iwasm CLI 下 app.wasm（解释）+ rt.aot 可以跑（AOT 子模块自身不 import memory，
合法），但业务代码仍被解释执行，对性能无意义。合并方案的两个坑（须后处理，见
`tools/attribution/patch_merged.mjs`）：合并产物导出 rt 的 `__data_end`/`__heap_base`
（1129776），与 app 栈指针 global（65536）被 WAMR loader 组合成非法 aux stack
（`auxiliary stack underflow`），须删这两个导出；且合并后 `_initialize` 无人调用
（原多模块由 WAMR 调用），须织入 `_start` wrapper 先调 `_initialize`。

### B 路 842× 的乘性分解（全部实测）

| 成分 | 倍数 | 证据命令/来源 |
|---|---:|---|
| node V8 wasm 引擎 vs 原生（干净代码下） | **~2.5×** | B' 干净 wasm 3.40 ms（`node --no-liftoff` 强制 TurboFan 全优，2026-09-21 复测；原 4.9 ms 是默认跑法，fib 单函数 tier-up 未充分，见"审计"节）÷ 原生 1.471 ms |
| perry codegen 差 + perry JS 宿主层（同在 node，同一份 wasm 字节码） | **~364×** | B 1239 ms ÷ B' 3.40 ms（原 253× 用 B' 4.9，随分母修正） |
| **乘积校验** | 2.5×364 ≈ **910** vs 实测 910.4（误差 <0.1%） | 闭合 ✓ |

364× 里 codegen 形态与 JS 宿主层的相对占比无法用现有干净对照分开（fib 每层的 2 次桥
调用是 codegen 决定的，而每次桥调用的 JS 成本——Proxy/wrapForI64/BigInt 转换/
`BigUint64Array` 视图分配/dispatch 字符串查表——是宿主层实现的；两者相乘起作用）。
可以确认的量级：干净 wasm 下 V8 每层 fib 调用 ~1.4 ns；B 路 fib 部分
1239×(2146/4010)≈664 ms / 166 万层 ≈ 0.40 µs/层，即每层 2 次桥调用合计 ~0.39 µs 全花在
"perry wasm 指令形态 + JS 桥调用链"上。**纯 JS 跑同算法实测 ~9 ms**（是 B 1239 ms 的
0.7%）——B 路慢不是"V8 跑 wasm 慢"，而是 perry 生成的 wasm 把所有算术变成跨边界桥调用。

### 对原"解读"的修正

1. 原推断"V8 慢的主因是宿主层编解码开销（未做逐导入插桩验证）"**需替换**：实测
   perry 同一份 wasm 在 WAMR（rt 桥，wasm 实现）与 node（JS 宿主桥）上差 3.2×，
   说明 JS 宿主层比 rt.wasm 桥慢 3.2×/层——但两者都远慢于干净 wasm（79×/253×）。
   主因不是"宿主层 vs rt.wasm"的选择，而是 **codegen 让每层算术都过桥**这一形态本身。
2. 原推断"热循环不经过 rt.*"**错误**：反汇编证明 fib 每层 2 次、循环每迭代 2 次桥调用
   （`mem_call`/`mem_call_i32`），热路径恰恰是 rt.* 的重度使用者。rt.wasm 占比不是 <1%，
   而是几乎全部（B 路的桥链）或与解释执行互相纠缠（A 路 79× 因子的一半以上）。
3. 原句"fib 循环本身不调用 rt.*，两路稳态差距的直接来源是 wasm 执行引擎的代差"中
   "3.2× = 引擎代差"的说法**不成立**：3.2× = JS 宿主桥链 vs rt.wasm 桥链的成本比；
   真正的引擎代差（干净代码下）是 50.8/4.9 ≈ 10×（WAMR 解释 vs V8 JIT）。

### 算术过桥问题（2026-09-19 增补，回答"算术不应该总是跨越运行时边界"）

针对质疑：perry codegen 让纯算术过桥，是设计使然还是可修复缺陷？三个子问题的
裁决（证据与复现见 `tools/attribution/rt_fast/README.md` 与 `probe_nameid.md`）。

**1. 过桥的范围先修正：不是"所有算术"。** wasm2wat 反汇编 + 上游 codegen 源码
（PerryTS/perry main，`crates/perry-codegen-wasm/src/emit/`）双重证实：

| 操作 | 路径 | 证据 |
|---|---|---|
| `+`（js_add） | **过桥**（mem_call） | literals_vars.rs：`BinaryOp::Add => emit_memcall("js_add")`，注释 "handles string+number etc."；bench.wasm fib 每层 1 次 nameId=8 |
| `-` `*` `/` | **内联** f64.sub/mul/div（含 reinterpret 对） | 同文件 `_ =>` 分支 |
| `<` `<=` `>` `>=` | **内联** f64.lt/le/gt/ge | `Expr::Compare` 数值分支 |
| if/while/for 条件 | **过桥**（mem_call_i32，is_truthy） | stmt.rs L66-69 等，bench.wasm nameId=12 |
| `===`/`==` | 过桥（js_strict_eq） | Compare 分支 |
| 字符串操作、console | 过桥（本来就必须） | calls.rs / strings_json.rs |

bench.ts 热路径的 2 次/层桥调用 = js_add（加法）+ is_truthy（条件判定），不是
全部算术。bench.ts 形态在 perry 生成的代码里是**普遍形态**（src/app.ts 反汇编
同构：fib 的 `+` 过桥、`n-1` 内联、条件过桥、msg.length 过桥）；唯一的基准选择
问题是它没覆盖字符串/对象等**本来就该过桥**的操作——那些负载的桥成本是必要
成本，分析结论中的"codegen 因子"（优化前 79×，采纳后 ~49×）只适用于"可内联算术被强制过桥"的负载
（fib/循环类），对字符串密集负载应理解为"必要跨边界成本 + 同样的实现低效"。

**2. 类型信息存在、未被 wasm 后端使用——属可修复缺陷，非值模型必然。** 证据链：

- `crates/perry-codegen-wasm/Cargo.toml` 只依赖 perry-hir / perry-codegen-js /
  perry-dispatch——**不依赖 perry-codegen**。类型化 ABI（`typed_abi.rs`）、
  i32 快路径（`expr/i32_fast_path.rs`）、`Type::Int32` 消费全部在 perry-codegen
  （原生 LLVM 后端），wasm 后端一点也用不上。
- HIR 有完整类型基础设施：`perry-hir/src/types.rs` 定义 `Int32`
  （"optimization for known integers"）、`lower_types.rs` 能把 number 表达式
  推成 `Type::Number`、`analysis/value_types.rs` 是完整值类型推断——TS 是静态
  类型语言，`let sum = 0; sum += i` 的类型可静态获知。
- `PERRY_BOX_INT32`（0x7FFE）快路径编码在 ABI（perry_abi.h）、runtime
  （`JSValue::int32`）、JS 宿主（INT32_TAG）三处都有**解码**路径，但 wasm emit
  全目录 grep `0x7FFE` 零命中——**codegen 从不发射该编码**。标签是给原生后端
  内部用的，wasm 后端没有接入。
- wasm 后端函数签名统一 `vec![ValType::I64; n]`（compile.rs L711-713），无任何
  类型特化签名。

裁决：**codegen 未做类型特化/内联是缺陷**（同一编译器家族的原生后端已实现同等
特化，wasm 后端是功能缺口），但**不是 wasm 后端独有的 bug**——它是 wasm 后端
落后于原生后端的整体状态，"统一设计"的部分只是"所有用户值一律 NaN-box f64 位型"
这一保守值模型。

**3. 桥侧线性扫描可消除，实测值 34×（79× 里的 43%）——已采纳进正式产物。** 正式 rt 的
`invoke()` 原本对 10 项 `BRIDGES` 逐项 memcmp（lib.rs L582-586），而 nameId 本来就是稳定
整数索引。实验版 `tools/attribution/rt_fast/lib.rs` 验证了 nameId→桥索引缓存表
（首次按名扫描，之后直查）后，该优化已于 2026-09-19 移植进 `runtime-wasm/src/lib.rs`
（`NAME_CACHE`，本节即"优化采纳"）。A 路同一 bench.wasm 对照（前两行是实验期数字；
末行是采纳进正式产物后 `./tools/bench.sh` 重测）：

| rt 版本 | A 路 P50 (ms) | codegen 因子（÷ A' 50.8 ms） |
|---|---:|---:|
| 正式 rt.wasm（按名扫描，优化前） | 3959–4010 | ~79× |
| rt_fast 实验（nameId 缓存直查） | **2292** | **~45×** |
| 正式 rt.wasm（nameId 缓存直查，已采纳） | **2470.678** | **~49×** |

实验期降幅 1718 ms（−43%），按 ~533 万次桥调用均摊 ≈ 322 ns/次，即每次桥调用从
~500 ns 降到 ~180 ns。正式产物重测值 2470.678 ms 与实验值 2292 ms 偏差 +7.8%
（机器噪声范围内），codegen 因子 ~49×。剩余 49× 来自参数解码/编码、NaN-box 指令形态、
WAMR 跨模块调用本身（~30 ns/次 × 2/层）。实测输出与基准各路逐字节一致
（fib(29)=514229 / sum=499999500000）。

**修复路径定位（工程判断）：**
1. **桥侧 nameId 缓存/跳表**——最小改动，本 demo 侧即可做，实测 −43%；
   属于纯实现低效的修复，无语义风险。**已于 2026-09-19 采纳进正式产物。**
2. **wasm codegen 消费 HIR 类型**——对类型可证的 `+` 与条件判定发内联
   f64.add / i32 比较，保留运行时回退（类型不证时仍走 js_add/is_truthy）。
   需上游 PerryTS/perry 改 `crates/perry-codegen-wasm`；基础设施（HIR 类型
   推断、INT32 编码、原生后端先例）都已存在，是"补齐"而非"新造"。
3. **长期**：wasm 后端并入 perry-codegen 的 typed ABI 体系（上游已有
   `--opt-report` 对特化拒绝原因的完整分类，说明该方向是既定路线）。

对分析结论的限定词：**优化前 79×/253× 的 codegen 因子 = "可内联而未内联的算术/条件
过桥（缺陷，可修复）" + "桥实现低效（nameId 线性扫描，实测值 34×）" + "NaN-box
指令形态"三者的乘积**。其中桥实现低效的 34× 已于 2026-09-19 通过 nameId 缓存直查
消除（79× → 49×），其余需要上游 codegen 改动。"必要跨边界"（字符串/console 等）的
成本不含在这三个因子里，基准未覆盖这类负载。

## 实测中发现的事实性结论

1. **编辑器事故记录**：基准开发中 `src/bench.ts` 曾丢失 `const f = fib(N_FIB)` 一行，
   导致 WAMR 路打印 `fib(29) = undefined`（f 未定义），字面量拼接探针则正常。排查中
   排除过 rt.wasm 桩表与 codegen 路径，确认是源码编辑问题。教训：A/B/C 输出一致性
   校验（bench.sh 第 2 步）必须先于计时。
2. **gcc -O2 会把整个基准常量折叠**：初版 `bench_native.c` 直接用 `#define` 常量，
   实测 0.002 ms（折叠后只剩 printf）；改经 `volatile` 指针读入 N_FIB/N_LOOP 后得到
   真实的 1.5 ms。**原生基线必须反折叠**，否则倍数会虚高 3 个数量级。
3. **WAMR 解释器单步开销 ~1.3–1.9 µs**：由探针与总耗时换算——循环 10^6 次累加单独
   ≈ 1864 ms（1.86 µs/迭代）；fib 部分 ≈ 4010 − 1864 = 2146 ms / 1664079 次调用
   ≈ 1.29 µs/调用。简单递归调用比循环体还便宜一点 [两者都来自探针测量 + 减法换算，
   探针程序未入库]。
4. `rt.wasm`（16.5 KB，优化前 16.8 KB）与 demo 的 app 参照构建一致——基准的运行时
   模块就是正式产物，未做任何基准特化。

## 诚实标注

- **推断 [INFERENCE]**：~~V8 慢的主因是宿主层编解码开销（未做逐导入插桩验证）~~
  已被性能分析（上一节）用对照实验**修正**——主因是 perry codegen 的桥调用形态；
  乘积分解中标注 [INFERENCE] 的条目（rt 分派/装箱占每层 1.2 µs 的大头、253× 内
  codegen 与 JS 宿主层各自占比、E 路 49×→108× 的分母定义说明）仍属推断，未逐项
  插桩。A 路单次冷执行 3819 ms（优化前）/ 2401 ms（优化后）是从 real 减去稳态
  中位数和 INIT_MS 的推算，非直接测量。性能分析的对照实验实测于 2026-09-19
  （`tools/attribution/`，结果见上一节表格）；优化采纳后的正式产物重测同日
  （`./tools/bench.sh`，rt 已含 nameId 缓存直查）。E 路同日增补：
  `tools/attribution/aot_e.sh`（样本 `build/e_runs.txt` / `build/eprime_runs.txt`）。
- ~~rt.wasm 占比 <1%~~（性能分析证伪：热路径每层/每迭代 2 次桥调用，rt 桥链是 B 路
  耗时的主体）；V8 慢的主因已修正为 perry codegen 桥调用形态（见性能分析节）。
- **噪声与口径限制**：机器为共享宿主上的 PVE 虚拟机，背景负载未做隔离；B 扣除的
  node 启动基线（优化前 23 ms / 优化后 24 ms）在 1.24–1.28 s 里占 ~2%，不确定度同
  量级；A 的冷启动 real 含 bench_time 的固定预热（两次执行），与 B/C 的"一次执行"
  口径不同，已在上表单独列出。同机重测的 A' 干净基线本身散布 50.8–58.8 ms
  （乘积分解统一按 50.8 口径换算因子），噪声约 ±15%。JIT 仍未测（WAMR LLVM JIT 需
  build_llvm.sh 自编全量 LLVM，收益与 AOT 同源，暂无必要）；rt.wasm 深度参与
  字符串密集型负载的占比仍未测（需要一个字符串密集基准）。
- **E 路口径限制**：E 每轮独立进程（合并单模块在多轮 `execute_main` 下 rt 字符串表
  累积溢出，第 4 轮起失败；解释器跑同一合并模块同样复现，属合并形态的多轮限制，
  双模块原形态无此问题），与 A/C 的同实例多轮口径略不同，对 E 略偏不利（每轮多了
  一次进程内预热执行，但无进程启动成本，EXECUTE 计时段不含）。E 冷启动未测。
  E 批间漂移：正式批 146.829，复测批 148.709 / 138.736（±7%，PVE VM 噪声内）；
  E' 复测批 1.522 / 1.494，正式批 1.362 偏低但在同一噪声带。

## D 路：perry 原生后端（2026-09-19 增补，回答"perry 自己两条后端差多少"）

用户指出 perry 的主打卖点就是 TS → LLVM → 原生可执行文件，基准必须纳入这一路。
编译命令 `perry compile src/bench.ts -o build/bench_perry_native`（版本/尺寸/耗时见
"结果"段），CLI 无优化等级开关（无 -O 系选项，LLVM 默认 O 系固定），复现脚本
`tools/attribution/bench_d.sh`。

### 六路对照总表（同一 `src/bench.ts`，输出逐字节一致）

| 路 | 宿主/引擎 | P50 | ÷ C 原生 | ÷ D perry 原生 |
|---|---|---:|---:|---:|
| A. wasm × WAMR 解释器 | WAMR FAST_INTERP（perry wasm 模块 + rt.wasm 双模块） | 2470.678 ms | 1757× | 393× |
| B. wasm × V8 | Node + perry JS 宿主层 | 1280.000 ms | 910× | 204× |
| C. 手写原生 | gcc -O2（`tools/bench_native.c`，i64） | 1.406 ms | 1× | — |
| D. perry 原生 | TS → LLVM → 可执行文件 | 6.286 ms（进程级，纯执行 ~1.6–2.6 ms） | 4.5×（纯执行 1.2–1.9×） | 1× |
| E. wasm × WAMR AOT | wamrc O3（wasm-merge 合并单模块，rt 代码也进机器码） | 146.829 ms（2026-09-21 复测批 138.7 / 141.4） | 104× | 23×（vs D 纯执行 54–88×） |
| F. QuickJS 直跑 JS | Bellard qjs 解释器（`tools/attribution/bench_quickjs.js`） | 85.532 ms（进程级，qjs 空载 ~0.95 ms） | 61× | 14×（进程级） |
**一句话结论：perry 自己两条后端的差距约 393×（wasm×WAMR 解释器 2470.7 ms vs
perry 原生 6.3 ms）；即使换成 V8 跑 wasm 也有 204×。perry 原生路本身只比手写
C 基线慢 4.5×，同一量级，卖点成立。** 增补 AOT 后修正：引擎不是瓶颈——干净 wasm
在 WAMR AOT 下与原生同速（E'/C = 0.97×），A 路的 1757× 里约 35× 是解释器代差
（E 路 16.8× 提速直接验证）；换 AOT 后 perry wasm 与 perry 原生仍差 23×（若按
D 的纯执行口径则 54–88×），几乎全是 codegen 桥调用形态（见"E 路"乘积分解与
"审计"节第一性原理分解）。**QuickJS 对照（F 路）给出决定性旁证：一个纯解释器
跑同一算法只要 85.5 ms，比 WAMR AOT 执行 perry 装箱字节码（E 146.8 ms）还快
0.58×——E 路的慢不是"解释器/引擎"的锅，100% 是喂给 wamrc 的字节码形态
（类型擦除 + 每层 2 次动态分派）。**

### 为什么 perry 原生比 gcc 慢 4.5×（反汇编 + callgrind 实测）

callgrind 单次执行指令数：C = 34.1 M，D = 21.7 M——D 的指令总量反而**少** 36%，
慢在指令构成与质量，不是数量：

- **fib 无自内联**：D 的 fib 是 16 条指令的独立函数（3 个静态 call 点：自递归 2 +
  main 1），1,664,079 次逻辑调用全是真实 call + 栈帧，16.64 M Ir ≈ 10 Ir/逻辑调用；
  C 的 gcc -O2 深度自内联（91,759 次真实 call，见"基线可信度审计"），每逻辑调用
  摊到的指令虽多（15 Ir，19.5 M+5.4 M Ir）但全部落在直寄存器依赖链上，无 call/ret
  与帧指针开销。fib 部分用时 [INFERENCE] ~4 ms（D 总 6.3 ms 减启动 0.6 减循环 ~1.5），
  即 fib 是 D/C 差距的主体。
- **sum 循环走 f64**：TS 语义下 perry 把 `number` 编成 f64（`vmovsd`/`vaddsd`/
  `vcvtsi2sd` 每 25 次展开一组），C 基线用 i64 整数累加。这属于语义公平（TS 的
  number 就是 IEEE double；审计节已实测同型 f64 变体仅慢 ~1.8×），不是 codegen 缺陷。
- **LLVM march=native 且 O 系默认**：无病态未优化迹象（若 O0，fib 走内存往返，
  应 >30 ms）。

### 口径限制

D 的 6.286 ms 含 fork/exec/动态链接/启动 ~0.6–1 ms（`bench_perry_wrap` 进程级计时，
空载基线 fork+exec+/bin/true P50 0.568 ms）；A/C 是进程内时钟、B 扣了 node 启动。
即 4.5× 是**对 D 偏保守**的上界读法；若同口径扣启动，D ≈ 5.3–5.7 ms，D/C ≈ 3.8–4.1×。
gdb 断点统计 D 的 fib 真实调用次数在本机不可行（PIE 断点 400 s 未达 1.66 M 命中且
gdb 12.1 内部错误），10 Ir/逻辑调用由 callgrind 总量 16,640,768 Ir ÷ 1,664,079 次闭合
推得，与反汇编的 16 条指令函数体吻合。

### 复测与诚实标注

- 四批 D P50：6.651 / 6.558 / 6.428 / 6.286 ms（散布 ±6%，PVE 共享 VM 噪声内）。
- perry 产物无多轮入口，无法像 bench_native 那样进程内多跑，包装法是当前唯一口径。
- [INFERENCE] fib/循环在 D 总耗时里的拆分（~4 ms / ~1.5 ms）由指令量比例推算，
  未做单独插桩；D 编译 1.9 s 的耗时构成（前端/LLVM/链接）未拆分。

## 审计：C/D/E 差距质疑取证（2026-09-21 增补）

针对"E 路 104× / D 4.5× / 23× 差距不对"与第一性原理质疑"perry 直接编译原生和
perry→wasm→AOT 都经 LLVM 级优化，差距不应如此大"的逐项取证。所有数字本次复现。

### 质疑 1a：E 路合并模块是否引入额外成本 → 证伪（合并不额外慢）

E 用 wasm-merge 合并单模块，而 A 路是双模块。对照：同一份合并模块
（`bench_merged_patched.wasm`）喂解释器 iwasm，进程级 real 三测 2390 / 2381 / 2340 ms；
双模块 `bench_link.wasm + rt_bench.wasm` 同口径 2480 / 2372 ms；`bench_time` 双模块
进程内 RUN 2501–2527 ms（2026-09-21 复测，原文档 2470.678 一致）。**合并版不慢于
双模块**（同量级，噪声内），E 未被合并高估。callgrind 无法直接核（解释器构建含
`wrgsbase`（fsgsbase）指令，VEX 3.18 未实现 → SIGILL，见下），但 wall-time 对照已足够。

### 质疑 1b：B'（干净 wasm × V8）的 4.9 ms 是否被启动/实例化污染 → 证伪，但发现 tier-up 修正

`run_node.mjs` 本就是进程内 hrtime 多轮（2 预热 + 10 计时），无启动污染。本次
`run_node_steady.mjs` 阶梯预热复测（node v24.21.0）：

| 跑法 | 稳态 P50 | 说明 |
|---|---:|---|
| node 默认 | 4.671 ms | 与文档 4.9 一致；fib 单函数 tier-up 预算未耗尽即结束 |
| `node --no-liftoff`（强制 TurboFan） | 3.400 ms | **V8 真优形态** |
| `node --liftoff-only`（纯 baseline） | 9.482 ms | 纯 Liftoff 上界 |

用户假设"稳态实际 ~1.3 ms"证伪（TurboFan 也不到 AOT 的 1.36 ms）。但 V8 引擎因子
修正：原 B'/E' = 4.9/1.362 = 3.6×，应为 **3.40/1.362 = 2.5×**（V8 默认跑法对
短递归 fib 未充分 tier-up，`--no-liftoff` 才是全优）。B 路分解 3.3×253 修正为
**2.5×364 ≈ 910**（闭合 910.4，误差 <0.1%）。解释：wamrc O3 全模块 LLVM+znver3
编译，连 fib 自递归都可内联（91,759 真实 call 同 gcc）；V8 TurboFan 为热路径
tier-up 保守编译、不做递归内联，短递归 fib 上确实不如 AOT 全模块 O3。

### 质疑 1c：wamrc 优化级 → 默认已是 O3，E 已最优

`wamrc --help` 确认 `--opt-level=n` "0 to 3, **default is 3**"（--cpu 默认 znver3）。
对照实测（同机同源）：E O0 = 390.8–439.7 ms vs O3 = 127.0–141.4 ms；E' O0 ≈ 4.0 ms
vs O3 ≈ 1.4 ms。文档 E 值（146.829）即 O3；本次复测批 138.704 / 141.382，在既有
批间漂移带（138.7–148.7）内。E 未高估。

### 质疑 1d/2：E 路桥调用成本与 D 纯执行（闭合计算）

**E 路闭合（本次 P50 141.382 ms，产物 `bench_merged_O3.aot`）：**

| 成分 | 实测 | 来源 |
|---|---:|---|
| fib 纯机器码基线 | 1.309 ms | `fib_only.aot`（纯 i64 递归 fib(29)） |
| loop 纯机器码基线 | ~0.002 ms | `loop_only.aot`（LLVM 常量折叠 10^6 循环） |
| 桥机制+装箱往返税（每层 2 次调用、被调方做最小 i64↔f64 往返） | 5.913 ms（税 4.604） | `nohost_box_app.wat`（call_indirect 防内联） |
| rt 侧 mem_call 函数体执行（NaN-box 解码 + nameId 直查 + tag 分派 + f64 算术 + 编码） | 135.5 ms | 余项 |
| **合计** | **141.4 ms** | 闭合 ✓（误差 <0.1%） |

每桥成本：rt 函数体 ≈ 135.5 ms / 5,328,158 桥 ≈ **25.4 ns/桥**；装箱往返税 ≈
4.604 ms / 3,328,158 桥（仅 fib）≈ **1.4 ns/桥**。用户"27.5 ns/桥 × 533 万 ≈ 147 ms"
的量级正确，但"剩余 ~37 ms 是应用侧代码"不成立——应用侧（fib 本体）仅 1.3 ms，
rt 侧代码在合并后也进机器码，是 E 的 **95.8%**。用户算的 92+55=147 是把 533 万
桥全算进 27.5 ns 的巧合闭合（实际 25.4+1.4=26.8 ns/桥 × 533 万 = 142.8 ms ≈ 141.4）。

对照解释器路：A 路 rt 桥 ~463 ns/次（1.2 µs/层 ÷ 2）vs AOT 25.4 ns——AOT 下 rt
侧也是机器码，18×，量级自洽（引擎代差 + 桥函数体从解释执行变直跑）。

**D 纯执行区间（callgrind 换算）：** D 总 21,729,513 Ir；动态链接/reloc/memset
≈ 2.29 M（11%），fib 16.64 M（10.0 Ir/层）、main 循环 3.04 M（3.04 Ir/迭代）。
纯执行 ≈ 19.44 M Ir。用 C 的 ns/Ir（16.71 M → 1.406 ms，IPC 3.8 @ 3 GHz）：
≈ **1.64 ms**；保守 IPC 2.5：≈ 2.59 ms。即 **D 纯执行 P50 ≈ 1.6–2.6 ms**，
6.286 ms 里 ~3.7–4.7 ms 是 fork/exec + 16.3 MB 二进制动态链接 + perry-runtime 初始化。
（用户"21.7 M Ir ÷ IPC 3.8 ≈ 5.7 ms"换算错误：应为 21.7e6/3.8/3e9 = 1.9 ms，
且还需先减 11% 非执行 Ir。）**D/C 纯执行比 ≈ 1.2–1.9×**（4.5× 是进程级口径）；
**E/D 纯执行比 ≈ 54–88×**（23× 是 E vs D 进程级的不公平口径）。

### 第一性原理：23× 不是"两个优化器的差距"，是"喂给优化器的输入形态"的差距（决定性实验）

`tools/attribution/nohost_app.wat`（与 perry fib 完全相同的调用图：每层 2 次
跨模块调用）+ `nohost_triv.wat`（平凡被调方）→ wasm-merge → wamrc O3：

- **nohost 直接调用版**（平凡被调方，LLVM 可内联）：P50 **1.371 ms** ≈ fib 纯机器码
  1.309 ms——调用图形态本身不是瓶颈，AOT 编译器把平凡被调方全部内联吸收。
- **nohost_box 版**（call_indirect 防内联 + 被调方做最简 NaN-box 往返）：
  P50 **5.913 ms**——强制"不可内联的间接调用 + 装箱往返"后也仅 ~5.9 ms
  （税 4.6 ms = 533 万桥 × 1.4 ns）。
- **E 的 141.4 ms − 5.9 ms = 135.5 ms 是 rt 侧 mem_call 函数体的机器码执行**——
  perry codegen-wasm 的类型擦除产物（所有值 NaN-box 成 i64 位型、`+` 编成
  `mem_call` 动态分派、条件编成 `mem_call_i32 is_truthy`）在 wamrc 眼里就是
  "装箱搬运 + 大 switch 分派"，LLVM O3 只能忠实编译，无法恢复已擦除的类型信息。

**最终表述：D/E 的差距不是优化器水平之差，而是优化器拿到的输入形态之差——**
D 路 perry-codegen 出**类型化 LLVM IR**（number → f64 直算，`vmovsd`/`vaddsd`）；
E 路 perry-codegen-wasm 先**类型擦除**成 NaN-box 字节码（每层递归 2 次动态分派 +
装箱往返），wamrc 只能优化"装箱搬运 + 分派"本身，无法找回类型。E'（干净 wasm ×
AOT = 0.97× 原生）已证明 wamrc 无问题。**唯一收敛路径是修 perry-codegen-wasm
的类型特化**（把 number 直接编成 f64/i64 算术、`<`/`+` 编成内联指令而非桥调用），
届时 wasm 路与原生路差距有望收敛到 D/C 同量级。

### F 路旁证：QuickJS 解释器比 E 路还快（QuickJS 对照，2026-09-21）

`tools/attribution/bench_quickjs.js`（与 bench.ts 同算法）跑 Bellard 官方
quickjs（/tmp/quickjs-bellard，make qjs）：
P50 **85.532 ms**（进程级，qjs 空载基线 0.95 ms → 纯执行 ≈ 84.6 ms），fib 部分
61.7 ms（37 ns/层）、loop 24.8 ms（24.8 ns/迭代）。对照：

| 对照 | 倍数 |
|---|---:|
| F/C 原生（1.406 ms） | ~61× |
| F/D perry 原生（6.286 进程级） | ~14× |
| F/E perry wasm × AOT（146.829） | **0.58×（F 更快）** |
| F/E' 干净 wasm × AOT（1.362） | ~62× |
| F/A WAMR 解释器（2470.678） | 0.035×（F 快 29×） |

**一个纯解释器（QuickJS 解释 JS，fib 每层 37 ns）比 WAMR AOT 执行 perry 装箱
字节码（每层 2 桥 × 26.8 ns + fib 本体 ≈ 55 ns）还快**——E 路的慢与引擎无关，
QuickJS 是"无桥的慢解释器" vs E 是"有桥的机器码"，桥税 25.4 ns/次 > QuickJS
解释一层 fib 的 37 ns 内除调用外的全部开销。这也解释了 B 路（V8 JS 宿主桥
0.39 µs/层）与 F 路的差距：JS 宿主桥比 wasm 桥再慢一个数量级。

### 本审计修正汇总

| 项 | 旧值 | 新值 | 依据 |
|---|---|---|---|
| B' 干净 wasm × V8 | 4.9 ms | **3.40 ms**（--no-liftoff）；默认 4.67 仍对 | run_node_steady.mjs 阶梯预热 |
| B 路 V8 引擎因子 | ~3.3× | **~2.5×** | 3.40 ÷ 1.471 |
| B 路 codegen+宿主层因子 | ~253× | **~364×** | 1239 ÷ 3.40 |
| B 路乘积校验 | 3.3×253≈835 | **2.5×364≈910**（误差 <0.1%） | 闭合 |
| B'/E' | 3.6× | **2.5×** | 3.40 ÷ 1.362 |
| D 纯执行 | 无（6.286 进程级） | **1.6–2.6 ms** | callgrind 19.44 M Ir 换算 |
| D/C（纯执行） | 4.5× | **1.2–1.9×** | 同左 |
| E/D | 23× | **54–88×**（按 D 纯执行） | 同左 |
| 合并模块成本 | 未测 | **无额外成本** | 解释器跑合并 2340–2390 vs 双模块 2372–2480 |
| wamrc 优化级 | 声明默认 O3 | **确认默认 O3**，O0 对照 390 vs 141 | wamrc --help + 实测 |
| F 路 QuickJS | 无 | **85.532 ms**（进程级） | bench_f.sh 11 轮 |
| E 路每桥成本 | ~27.5 ns | **rt 函数体 25.4 ns + 装箱税 1.4 ns** | nohost_box 隔离实验 |

**最终 C/D/E 一句话：C = 1.406 ms、D = 6.286 ms（纯执行 1.6–2.6 ms）、
E = 146.8 ms——perry 原生路只比手写 C 慢 4.5×（纯执行 1.2–1.9×），perry
wasm×AOT 比 perry 原生慢 23×（按 D 纯执行 54–88×），E 的 141.4 ms 里 135.5 ms
是 rt 侧 mem_call 函数体（每桥 25.4 ns），23× 的差距 100% 来自 perry-codegen-wasm
的类型擦除桥形态，与引擎/优化器无关；旁证：QuickJS 纯解释器跑同算法仅 85.5 ms，
比 E 还快 0.58×。**

### 本审计新增文件（tools/attribution/）

- `run_node_steady.mjs` — B' 阶梯预热复测（V8 tier-up 收敛观察）
- `nohost_box_app.wat` — call_indirect + 最小 NaN-box 往返（桥机制+装箱税隔离）
- `bench_exec_wrap.c` — 通用 argv 进程级 fork/exec 计时（F 路）
- `bench_quickjs.js` — F 路基准（与 bench.ts 同算法同输出）
- `bench_f.sh` — F 路一键复现

复现命令：`tools/attribution/bench_f.sh 11`；E 闭合用 `build/aot_time` 跑
`bench_merged_O3.aot`（wamrc --opt-level=3 产物）、`nohost_box_app.aot`、
`nohost_merged.aot`、`fib_only.aot` 各 5–12 轮取中位数。

## 修复路径与天花板（2026-09-21 增补）

审计已证 E 路的 ~108× codegen 因子 = "类型擦除装箱字节码形态"（每层递归 2 次
`mem_call` 动态分派 + NaN-box 往返）。本文用两个定量实验回答"怎么修、修到多少"：

- **实验 A**：wasm-opt 纯后处理能否把桥内联/折叠掉（廉价修复）
- **实验 B**：等价手工类型特化，量化"perry-codegen-wasm 修好类型特化后 E 的上限"

全部数字为 2026-09-21 实测（`build/aot_time` 同口径：12 轮进程内计时，弃第 1 轮取
11 样本中位数），**所有优化产物的输出与基准逐字节一致**（fib(29) = 514229、
sum = 499999500000）。复现：`tools/attribution/exp_wasmopt.sh 12`（实验 A）、
`tools/attribution/exp_specialize.sh 12`（实验 B）。

### 实验 A：wasm-opt 后处理 — 能内联，不能折叠分派（P50 122.1 → 93.5 ms，-23%）

关键事实（审计前置）：perry 的每个桥调用点都带字面 nameId（`f64.const 8` →
`mem_call` js_add；`f64.const 12` → `mem_call_i32` is_truthy），是"常量分派"。
对合并产物 `build/bench_merged_patched.wasm` 跑 binaryen wasm-opt 123：

| 变体 | 关键 flags | P50 (ms) | 相对 E |
|---|---|---:|---:|
| E（未优化基线） | — | 122.112 | 1× |
| A1 | `-O3`（默认内联阈值） | 135.4 / 123.7† | ≈1× |
| A2 | `-O3 --always-inline-max-function-size=10000` | 99.6 / 96.0† | 0.78–0.81× |
| A3 | `-O4 --always-inline-max-function-size=10000` | 101.4† | 0.82× |
| A4 | `--inlining-optimizing --always-inline-max-function-size=10000 --precompute-propagate --dce` | 101.3† | 0.82× |
| **A5** | `--inlining-optimizing --always-inline-max-function-size=5000 --precompute-propagate --dce` | **93.497**（min 92.5 max 94.5） | **0.766×** |

†A1/A3/A4 与 A2 同批（E 基线 131.232 ms，n=11）；A5 与 E/B1/B2 同批（E 基线
122.112 ms）。A2–A5 相互差 <8%，同量级；A5 代表"纯后处理"上限。

**能内联**：`wasm-dis` 确认 A2 中 `call $142/$143` 全部消失（模块 6714 行 →
277922 行 wat），整条 mem_call+invoke 被强制内联进 fib/loop；字面 nameId/argCount
常量传播成功（截断、参数拷贝循环展开、结果 unbox 的 tag 分派部分折叠）。

**不能折叠分派——卡点明确**：内联体里仍残留 11 路 `br_table`，其索引来自
NAME_CACHE 的**运行时内存 load**（`i32.load8_u offset=1051877+nameId`）；binaryen
无内存常量传播，内存内容运行时才确定（miss 路径会写缓存），所以 switch 无法消掉，
完整 miss 路径字符串查找代码也原样留在内联体里。`f64.const 8/12` 的"常量分派"只有
常量本身可折叠，分派表不可折叠。

**次优（nameId 折叠成直接调桥）不可用工具达成**：wasm-opt 没有把
"mem_call(nameId) → 直接 call 对应桥实现"的 pass——nameId→op 的映射活在 rt 的
数据表 + br_table 结构里，不是可识别的调用边。手工改 wat 可行（见实验 B 铺垫），
但收益被夹在 A5（93.5）与 B1（71.6）之间 [INFERENCE]：它只省 dispatch
（cache load + br_table + miss 路径），js_add/is_truthy 的通用实现（类型打标、
字符串分支、结果 unbox）仍在。不值得做；直接做实验 B 的语义内联。

结论：**纯后处理能把 E 从 122.1 压到 ~93.5 ms（-23%），但内联的是"大 switch 搬运
代码"，到不了特化量级；零上游改动的收益上限就是 ~93 ms。**

### 实验 B：等价手工类型特化 = 修复天花板（P50 122.1 → 17.2 ms，快 7.1×）

不真改上游，对 `build/bench_merged_patched.wat`（perry 原样字节码）做**等价手工
特化**——替换的正是 codegen 类型特化会发射的指令：

| 变体 | 改动 | P50 (ms) | 相对 E | 相对 E' |
|---|---|---:|---:|---:|
| E（perry 原样） | — | 122.112 | 1× | 100× |
| **B1** | 热路径 `+` 内联 `f64.add`（fib 的 `fib(n-1)+fib(n-2)`、循环 `sum += i`），is_truthy 桥保留 | 71.612 | 0.586× | 58.9× |
| **B2** | B1 + is_truthy 内联为 `i64.ne` 假盒比较（2 处条件全内联，NaN-box + 影子栈纪律保留） | **17.185**（min 16.5 max 21.0） | **0.141×（快 7.1×）** | 14.1× |
| V3 | 纯 f64：无盒、无影子栈、全内联（`specialized_bench_f64.wat`） | 3.325 | 0.027×（快 36.7×） | 2.7× |
| E' | clean_bench（纯 i64，同批） | 1.216 | 0.010×（快 100×） | 1× |

等价性论证（因此数字就是"codegen 特化后"的真实预期）：此程序里 js_add 两侧恒为
number（number+number 的 JS `+` = f64.add，perry 的 number 表示即裸 f64 位型）；
is_truthy 的输入恒为 `f64.lt` 产出的盒布尔（TAG_TRUE 0x7FF8000000000004 /
TAG_FALSE 0x7FF8000000000003），`is_truthy(盒布尔) ≡ i64.ne v TAG_FALSE`。替换保持
影子栈增减逐指令不变；打印路径的 string 拼接 js_add 与 console_log 桥原样保留。

**乘性分解（B2 是"保留 NaN-box + 影子栈纪律"的 codegen 特化上限）**：

- E − B2 ≈ 105 ms = 桥调用本体（2 桥/层 × ~2.08M 桥）——类型特化把这部分全部消灭。
- B2 − E' ≈ 16 ms = perry 的影子栈**内存纪律**（每值经 global sp 存/取内存，
  fib 每层 ~20 条辅助指令，1.66M 层 × ~10 ns）——这**不是 NaN-box 的税**：
  B2 的 i64↔f64 reinterpret 对是机器码空操作，LLVM O3 会消除 [INFERENCE]，box
  本身近零成本；16 ms 是"值走内存不走寄存器"的调用纪律成本。
- E' ≈ 1.2 ms = 纯机器码（LLVM 深度内联 fib）。

V3（3.3 ms）vs E'（1.2 ms）的差是 LLVM 对 f64 vs i64 fib 的内联/优化差异
[INFERENCE]（两版都是"无盒无纪律"），不代表 perry 可控项。

### 方案表（改动成本从低到高）

| # | 路径 | 做法 | 可动用文件（上游 file:line） | 成本 | 预期收益（实验锚定） | 风险 |
|---|---|---|---|---:|---|---|
| 1 | 桥侧剩余优化 | rt invoke 快路径：纯数值 js_add 直通 f64.add、省 arg 打标/结果 unbox 往返 | rt 桥实现（`wasm_runtime.js:155` js_add、`:168-176` is_truthy） | S | 余量小：nohost_box 已证纯桥机制税 1.4 ns/桥；dispatch+打标即便省一半也仅 122→~110 ms [INFERENCE] | 低；不改变发射形态，AOT 下 LLVM 已优化 rt 内部，收益有限 |
| 2 | wasm 后处理（实验 A） | 构建链加一步 wasm-opt（`--inlining-optimizing --always-inline-max-function-size=5000 --precompute-propagate --dce`）再 wamrc | 构建链（`tools/attribution/exp_wasmopt.sh`） | S | **实测 -23%**（122.1→93.5 ms） | 低（输出逐字节一致已验证）；体积 21→661 KB wasm / 74 KB→1.35 MB aot；上游特化落地后可撤 |
| 3 | **codegen 类型特化（推荐主线）** | wasm 后端装配 HIR 类型环境，发射点分支：`+` 两侧 number → 内联 f64.add（复用现有 `literals_vars.rs:139-151` 的 `++`/`--` 模式）；条件 Boolean → 内联 `i64.eq` 假盒比较；number 条件保守回退 is_truthy；类型不证全回退原桥 | `emit/expr/literals_vars.rs:176-184`（js_add）、`:249-285`（Eq/Ne）、`:286-308`（Lt 已内联）；`emit/stmt.rs:68-69,113-114,165-166,225-226`（is_truthy）；`emit/compile.rs:565-719`（装配 `HirTypeEnv::from_module`）；`perry-hir/src/analysis/value_types.rs:222,551,1649`（infer_expr_type/infer_binary_type，Add: string→String / number→Number / else Any） | M–L | **实测 B2 = 17.2 ms（快 7.1×）**；只修 `+` 为 B1 = 71.6 ms | 中：JS truthiness 边角（0/-0/NaN 不可裸 `i64.ne 0`）——第一版 number 条件回退桥即可绕开；回退路径保证行为不变 |
| 4 | 长期：wasm 后端并入 typed ABI 体系 | 仿原生 typed ABI：函数签名从全 I64 改 typed（Int32→I32、Number→F64、Boolean→I1），值表示对齐原生（可发 INT32_TAG 0x7FFE），去影子栈 | `codegen/typed_abi.rs:144-156`（typed_param_rep_for_type）、`i32_fast_path.rs`（证明制）；wasm 端 `emit/compile.rs:711-719`（全 I64 签名）、`function.rs:49`、`expr/calls.rs` | L | 17.2 → ~1.2–3.3 ms（E'/V3 锚；需同时去影子栈纪律，实验 B 的 16 ms 才可再省） | 高：调用点装箱约定、rt 桥 ABI、回归面全动；第二阶段 |

### 推荐

**路径 3（codegen 类型特化）是主线**：B2 实测 7.1×（122.1→17.2 ms），改动局部
（发射点分支 + 回退），HIR 类型信息现成（`value_types.rs` 的 `infer_expr_type`/
`infer_binary_type` 可直接调用，无需新推断），与审计结论"唯一收敛路径是修
perry-codegen-wasm 的类型特化"一致。**路径 2（wasm-opt 后处理）作可选过渡**：
零上游依赖、当天可上线、-23%，适合在上游 PR 合入前先缓解；代价是体积暴涨。
**路径 1 不优先**（余量小）。**路径 4 是终极形态**，等路径 3 落地、确认 16 ms
影子栈纪律成为新瓶颈后再评估。

落地顺序：**2（可选过渡）→ 3（主线）→ 4（远期）**。若团队能在一个迭代内合路径 3，
可直接跳过 2。

### 本增补新增文件（tools/attribution/）

- `exp_wasmopt.sh` — 实验 A 一键复现（wasm-opt 变体 → wamrc → 正确性 → P50）
- `spec_patch.py` — B1/B2 生成器（从 `build/bench_merged_patched.wat` 做等价手工特化）
- `exp_specialize.sh` — 实验 B 一键复现（B1/B2/V3 → wamrc → 正确性 → P50）
- `specialized_bench_f64.wat` — V3：纯 f64、无盒、无影子栈（"全去 NaN-box"版）

产物在 `build/wasmopt_exp/`（A）与 `build/spec_*.{wat,wasm,aot}`（B）。
上游行号以 `/tmp/perry-codegen-findings.md`（另一 worker 的克隆核对）为准。

## 零上游依赖后处理：通用桥内联 pass（2026-09-21 增补）

实验 A（wasm-opt）与实验 B（手工特化）留下一个未答问题：**B2 的成功依赖"人读了
`src/bench.ts` 才知道那里是 number"，这份类型知识在 perry 产物里已被 codegen 擦除**。
手工特化因此只是**上界估计器**，不是可用修复。本节回答"有没有可复用的修复"：
实现一个**通用后处理 pass**（`tools/attribution/bridge_inline_pass.mjs`），
让它自己从模块里恢复类型信息，并在 4 个不同形态的程序上量化覆盖率与误判。

### 结论先行

1. **可复用性成立**：pass 在**真实 perry 产物**（`build-wasm.mjs` 产物 → patch-app-memory
   → wasm-merge(+rt) → patch_merged）上自动恢复类型，bench 从 **123.1 → 16.9 ms
   （快 7.3×）**，与手工特化上界 B2 = 17.2 ms **同级**——而且全程没改一行上游代码。
2. **泛化成立且零误判**：4 个程序（纯 number 热循环 / 字符串密集 / 混合类型 / 跨函数）
   × 7 个变体 = **28 次输出逐字节比对全部 PASS，0 次误判**（字符串 `+` 一律正确拒绝内联）。
3. **代价**：约 800 行 JS（wat 解析 + 抽象解释 + 改写 + 覆盖率报告）。**~10 小时**
   [INFERENCE]（本 spike 的实际投入量级，含调试与 4 程序泛化验证）。
4. **固有缺陷**：pass 依赖 perry 产物的**指令形态**（`(drop (call $mem_call (f64.const <nameId>) …))`
   + 影子栈槽位约定）。perry 升级 codegen（路径 3 落地、或改桥发射形态）即可能失配——
   这是后处理相对上游改造的**永久劣势**，必须随 perry 版本回归。
5. **B2/V3 是上界估计，不是可用修复**：它们由人读源码得到的类型知识手工写入
   （`spec_patch.py` 按 fib 行号硬编码）。本节的 pass 才是可复用路径，且已够到该上界。

### 手段表（同一批实测，2026-09-21）

口径：`build/aot_time`，**6 进程 × 每进程 2 轮 = 12 样本，弃第 1 样本取 11 样本中位数**
（每进程 3 次执行 = 1 预热 + 2 计时，≤ rt 字符串表 1024 项上限；第 4 次执行必触发
`string table overflow`，故不用 12 轮单进程口径）。程序：`src/bench.ts`。

| 手段 | 实测 P50 (ms) | vs E | 零上游依赖 | 实现工作量 | 风险 |
|---|---:|---:|---|---:|---|
| E：perry 原样（未 pass 基线） | 123.098 | 1× | 是 | 0 | — |
| A5：wasm-opt 强内联（实验 A，既有实测） | 93.497 | 0.76× | 是 | ~1 h | 低（体积 74 KB→1.35 MB aot） |
| wamrc `--enable-segue`（开关侦察，既有实测） | 99.84 | 0.81× | 是 | ~0.5 h | 仅 linux x86-64（GS 基址每线程寄存器） |
| **本 pass（通用桥内联）** | **16.958** | **0.138×（快 7.3×）** | **是** | **~10 h** | **中：依赖 perry 产物指令形态；perry 升级 codegen 即失配** |
| 本 pass + wasm-opt(A5) | 16.034 | 0.130× | 是 | +0 | 低 |
| 本 pass + wasm-opt(强组合)† | 16.203 | 0.132× | 是 | +0 | 低 |
| 本 pass + segue | 17.315 | 0.141× | 是 | +0 | 低 |
| 本 pass + wasm-opt + segue | 17.661 | 0.143× | 是 | +0 | 低 |
| B2：等价手工特化（实验 B，既有实测） | 17.185 | 0.141× | 是（但不可复用） | ~4 h | 上界估计器，非修复 |
| V3：纯 f64 全去盒（既有实测） | 3.325 | 0.027× | 是（但不可复用） | ~8 h | 上界估计器，非修复 |
| E'：干净 i64 wasm（引擎同速锚） | 1.216 | 0.010× | 是 | — | — |

†强组合 = `-O4 --converge --precompute-propagate --inline-functions-with-loops`。
**叠加结论**：wasm-opt 叠在 pass 之上只剩 −5%（16.96→16.03），`--converge` 等强组合
没有额外收益；**segue 在桥被消灭后不再有用**（16.96→17.32，反向）——它的收益本来就
来自优化 AOT 里那条桥分派路径，而 pass 已把该路径删掉。三者叠加无意义。

**核心回答**：不改 perry 上游，**能把 122 ms 拉到 ≤20 ms 量级**（16.0–17.0 ms，
即 B2 上界水平）。最小手段 = 单个 wat→wat 后处理 pass，接在既有 E 路链路的
`patch_merged` 之后、`wasm-as` 之前，构建链只多一行命令；代价约 10 小时一次性投入
+ 随 perry 版本回归的风险。

### pass 的匹配规则（怎么判定"可证 number"）

值域三格：`NUM`（原始 f64 位型 = JS number）/ `BOOLBOX`（`TAG_TRUE`/`TAG_FALSE` 二值盒布尔）
/ `OTHER`。**NUM 的语义依据**：perry 的 number 表示就是裸 f64 位型（rt `encode(V::Num(n)) = n.to_bits()`，
其余值一律 NaN-box），所以"f64 域生产者 ⇒ number"；而 perry 自己的 codegen 对
`-`/`*`/`/` 就是**无条件**内联 `F64Sub/F64Mul/F64Div`（`literals_vars.rs` 的 `_ =>` 分支），
即 perry 本身已把 f64 域操作数当 number——pass 不引入 perry 未有的假设。

抽象解释（每个函数内按语句序，控制流合并取保守并）：

1. `(i64.reinterpret_f64 X)` → `NUM`（X 是 f64.const/load/算术；若是 `(f64.reinterpret_i64 Y)` 则取 Y 的 kind）。
2. `(local.get $l)` / `(global.get $g)` / `(i64.load (sp-K))` → 查环境；槽位按"相对 live sp 的偏移"建 key。
3. `(if (result i64) … (then (i64.const A)) (else (i64.const B)))` / `(select (i64.const A) (i64.const B) …)`
   → `BOOLBOX`；`A`/`B` 本身也**从模块自身推导**（多数表决 then/else 常量），不硬编码——
   实测本仓 `build/rt_bench.wasm` 的 `TAG_TRUE/FALSE = 0x7FF8000000000004/3`，与
   `runtime-wasm/src/lib.rs` 当前源码里的 `0x7FFC…` 不同（该 wasm 是旧版编译产物），
   硬编码就会错。pass 因此对 rt 版本漂移免疫。
4. 函数**参数**：若函数体把该参数喂进 f64 域运算（`(f64.* (f64.reinterpret_i64 (local.get $p)))`）
   → `NUM`（**模块内证据**：perry 自己已这么假设）；否则按内部调用点做不动点推断
   （乐观初值 + 单调上推）；**导出/表引用函数**在无自约束时判 `OTHER`（外部调用方未知）。
5. 函数**返回值**：对各 `return` 表达式做不动点（乐观初值，递归函数的基例即收敛锚点）。
6. 普通调用：perry 影子栈纪律——**实参在 live sp 之下（偏移 < 0），被调方帧在 live sp 之上（偏移 ≥ 0）**
   → 调用只失效 ≥0 的槽位，保留实参区（这是 `fib(n-1)+fib(n-2)` 两个实参之间夹着一次递归
   调用仍能证明的关键）。
7. 槽位/局部跨分支：`if`/`block`/`loop` 合并取"两边一致才保留"，否则 `OTHER`。

**改写**（只在 drop 位置、且两侧可证 number 时动手，保持影子栈增减逐指令不变）：

- `js_add`（nameId 8, argc 2）：`(drop (call $mem_call (f64.const 8) (f64.const 2) BASE))`
  → `(i64.store BASE (i64.reinterpret_f64 (f64.add (f64.reinterpret_i64 (i64.load BASE))
  (f64.reinterpret_i64 (i64.load (BASE+8))))))`。与 rt `js_add(Num,Num) = Num(a+b)` 逐位等价。
  结果仍写回 `BASE`，后续 `(i64.load BASE)` 照旧读到。
- `is_truthy`（nameId 12, argc 1）：`(call $mem_call_i32 (f64.const 12) (f64.const 1) BASE)`
  → `(i64.ne (i64.load BASE) (i64.const TAG_FALSE))`。与 rt `truthy(Bool(b)) = b` 逐位等价。
- **number 条件保守回退**：JS truthiness 里 `0`/`-0`/`NaN` 均 falsy，非二值，不内联（仍走桥）。
- 其余桥（`console_log`=4、`string_concat`、`string_len`=10、`js_strict_eq`=13 …）**一律不动**。
  nameId 语义来自 rt 固定桥表；与数据段字符串序一致（`id = 序 + 1`：`console_log`=4、
  `js_add`=8、`string_eq`=9、`string_len`=10、`is_truthy`=12、`js_strict_eq`=13），
  与 `probe_nameid.md` 的经验值互相印证。

### 泛化验证（4 程序 × 7 变体）

新增探针（`tools/attribution/probes/`，与 `src/bench.ts` 并列）：

| 程序 | 形态 | 用途 |
|---|---|---|
| `probe_str.ts` | 字符串密集：`s = s + "ab"`（×32）、`s.length`、`s === s`（×20 万）、`hits + 1`、`n > 8` | 验证**不误伤**本该走桥的字符串运算 |
| `probe_mixed.ts` | 混合类型：`total + i`（×20 万）、`i === 199999`、`label + "!"` | 验证类型判定边界 |
| `probe_nested.ts` | 跨函数：`dbl`/`acc_upto`/主循环，返回值就是 js_add 结果（无 f64 包络） | 验证**跨过程**类型推断 |

覆盖率 = 静态桥调用点（`call $mem_call*` 节点）改写比例，由 pass 自报：

| 程序 | 桥调用点 改写前→后 | 总覆盖率（保守 / `--closed-world`） | 明细 |
|---|---|---|---|
| bench | 10 → 6 | 4/10 = **40%** / 40% | `js_add` 2/6（另 4 处操作数是字符串，正确拒绝）、`is_truthy` 2/2、`console_log` 0/2（不在内联集合） |
| probe_str | 11 → 6 | 5/11 = **45%** / 45% | `is_truthy` 4/4、`js_add` 1/2（**拒绝的是 `s + "ab"`**）、`string_len`/`string_eq`/`console_log` 0/5（不该内联） |
| probe_mixed | 7 → 4 | 3/7 = **43%** / 43% | `is_truthy` 2/2、`js_add` 1/2（**拒绝的是 `label + "!"`**）、`js_strict_eq`/`console_log` 0/3 |
| probe_nested | 7 → 4 | 3/7 = **43%** / **6/7 = 86%** | `is_truthy` 2/2；`js_add` 1/4（保守）→ **4/4（closed-world）** |

正确性：**28/28 逐字节一致**（每个程序 7 个变体：base / pass / pass(cw) / pass+wasmopt /
pass+wasmopt(强) / pass+segue / pass+wasmopt+segue），参照物是 perry 自带 JS 宿主层
（`wasmBoot` 的 `run.mjs`），比对方式与 `demo.sh` 同（`aot_time` 输出去 `RUN` 行后逐字节）。

性能（P50 ms，同批同口径）：

| 程序 | base | pass | pass(cw) | pass+wasmopt | pass+wasmopt(强) | pass+segue | pass+wasmopt+segue |
|---|---:|---:|---:|---:|---:|---:|---:|
| bench | 123.098 | **16.958** | 16.822 | **16.034** | 16.203 | 17.315 | 17.661 |
| probe_str | 30.297 | **14.942** | 14.340 | **10.213** | 14.248 | 13.429 | 11.908 |
| probe_mixed | 21.261 | **5.918** | 5.861 | **4.421** | 5.629 | 5.058 | 4.690 |
| probe_nested | 0.521 | **0.280** | **0.044** | 0.236 | 0.282 | 0.233 | 0.226 |

三个非显然读数：

- **字符串密集程序也快 2.0×**（30.3→14.9）：该程序 20 万次循环里 `is_truthy` 4/4 全内联、
  `hits + 1` 的 js_add 内联；**字符串 `+` 与 `===` 一处没动**（正确性优先）。
- **probe_mixed 快 3.6×**（21.3→5.9）：纯 number 累加被内联，`===` 桥保留。
- **probe_nested 的保守/closed-world 差 6.4×**（0.280 vs 0.044 ms）：差距**全部**来自
  "导出函数参数是否可当 number"。perry 把每个用户函数都导出（`__wasm_func_N`），
  保守模式无法排除"宿主用字符串调它"，于是 `dbl(n) { return n + n }` 的参数不可证；
  合并后的 AOT 模块实际是封闭世界（只有 `_start` 一个入口），`--closed-world` 显式声明
  这一点后，跨函数推断全部打通（js_add 4/4）。**这是可复用性的真实边界，不是实现缺陷**：
  类型知识在模块里不可恢复时，pass 保守拒绝。

### 误判清单

**空**。28 次逐字节比对零失败；字符串/混合程序里所有"本该走桥"的调用点都被正确拒绝
（报告 `reasons` 字段给出拒绝原因：`arg_kind=OTHER/…`、`bridge_not_in_inline_set`）。
防护规则（保证误判不会静默发生）：

1. 只在**两侧都可证 number**（或输入可证是 `TAG_TRUE/FALSE` 二值盒布尔）时改写，其余一律原样保留；
2. `TAG_TRUE/TAG_FALSE` 从**被测模块自身**推导，不硬编码（已实测本仓 rt 产物与 rt 源码常量不一致）；
3. 影子栈增减逐指令不变（只替换 `drop(call)` / 调用表达式，不动 sp 调整）；
4. 每个变体产物都过**逐字节一致性**验收（`exp_postpass.sh` 内置），失配即 fail-fast。

### 开关路线（已排除，另一 worker 侦察实测）

perry CLI / `@typerry/node` / 环境变量（`--target wasm|web`、`--minify`、`--fast-math`、
`--march=*`、`--no-auto-optimize`、`PERRY_TARGET_CPU`、`PERRY_PRECOMPILE`）**产出字节完全
相同的 wasm**（md5 `af3e4dd7…`，9827 B）——**"调开关"这条路不存在**。wamrc 侧唯一有效的是
`--enable-segue`（配 `--target=x86_64 --disable-llvm-jump-tables`）：122.14 → **99.84 ms
（−18.3%）**，仍 71× 于原生，且被本 pass 覆盖（桥没了，segue 无收益）。其余开关无效或更差
（`--opt-level=0` 灾难 3.2×、`--enable-shared-heap` +29%、`--enable-llvm-pgo` 因缺
`WAMR_BUILD_STATIC_PGO=1` 无法闭环未验证）。

### 复用价值裁定

**有复用价值（作为过渡方案），但带永久性维护成本。**

- 覆盖率在 4 种形态下稳定在 **40–45%**（`--closed-world` 下 probe_nested 到 86%），
  拒绝项全部是"不该内联"的桥（字符串 `+`、`===`、`console_log`）——**零误判**；
- 收益不是边缘优化：bench **7.3×**、字符串程序 2.0×、混合程序 3.6×、跨函数程序 11.8×
  （closed-world），且与手工特化上界同级；
- 缺陷：**依赖 perry 产物指令形态**。路径 3（上游 codegen 类型特化）落地后本 pass
  应整体撤除；在此之前它是"零上游改动、一个迭代内可上线"的唯一手段。

### [INFERENCE] 清单

1. **perry codegen 不会把非 number 喂进 f64 域运算**——依据是它自己无条件内联
   `F64Sub/F64Mul/F64Div`（4 个程序的产物反汇编一致），非上游文档保证。
2. **影子栈帧约定**（实参 < live sp ≤ 被调方帧）由 4 个程序的产物归纳，未见于上游文档；
   若某函数入口 `sp -= K`（帧在 live sp 之下）会破坏该约定 → 该函数内的实参槽位可能被
   误判为存活。本仓 4 程序实测未出现（28/28 逐字节一致）。
3. **~10 小时实现量**为本次 spike 的实际投入量级估计，非受控工时测量。
4. `--closed-world` 的安全性依赖"宿主只调 `_start`"；对其它 embedder 需自行确认。
5. B2/V3 与 E' 之间的差（影子栈内存纪律）的分析沿用实验 B 的 [INFERENCE]，本节未新增证据。

### 本增补新增文件（tools/attribution/）

- `bridge_inline_pass.mjs` — 通用桥内联 pass（wat→wat + 覆盖率 JSON；`--closed-world` 可选）
- `exp_postpass.sh` — 一键复现：完整 E 路链路 + pass + 7 变体正确性/覆盖率/P50
- `probes/probe_str.ts`、`probes/probe_mixed.ts`、`probes/probe_nested.ts` — 泛化探针
- `probe_ref.mjs` — 生成 perry JS 宿主层参照（`wasmBoot`）用于逐字节比对

产物在 `build/postpass/<prog>/`（wat/wasm/aot/coverage*.json/ref.out），
P50 汇总在 `build/postpass/p50.txt`。

## 上游 patch：codegen 发射点特化（2026-09-21 增补）

前述"零上游依赖后处理"是 wat 层三格抽象修复；本节记录**直接改上游
`perry-codegen-wasm` 发射点**的实验结果——即"路径 3 的正解"。源码为 vendored
perry（typerry submodule，commit `87ecb02b`），patch 见
`tools/attribution/codegen_specialize.patch`，设计说明见
`tools/attribution/patch_notes.md`。

### patch 内容

在 `crates/perry-codegen-wasm` 增加保守类型事实（新文件 `emit/type_facts.rs`）：
声明类型（参数/let 注解）+ 轻量数据流（无注解 `let x = <init>` 的初始化传播 +
赋值敏感不动点，闭包捕获一律拒绝）。两个发射点特化：

- `+`（`emit/expr/literals_vars.rs`，`BinaryOp::Add`）：两侧可证 number →
  内联 `F64Add`（保持 NaN-box 语义：`I64ReinterpretF64 → F64Add → I64ReinterpretF64`）；
  否则原 `mem_call(js_add)`（字符串分支保留）。
- 条件（`emit/stmt.rs` 的 if/while/do-while/for 4 处）：条件可证二值盒布尔 →
  `I64Ne(TAG_FALSE)`；否则原 `mem_call_i32(is_truthy)`。**number 条件保守回退**
  （0/−0/NaN falsy 语义）。

辅助修复：`compile.rs` 的 globals init / class 注册循环补 `current_mod_idx`
（原缺，per-module 类型事实会取错索引）。

### 性能（同口径 `build/aot_time`，12 轮弃第 1 轮取 11 样本中位数）

| 变体 | P50 (ms) | 相对 E | 说明 |
|---|---:|---:|---|
| E（perry 原样） | 122.112 | 1× | — |
| **patch 后（codegen 特化）** | **3.891** | **0.0319×（快 31.4×）** | 本次新增 |
| B2（等价手工特化，保留影子栈纪律） | 17.185 | 0.141× | 实验 B 天花板 |
| V3（纯 f64，无盒无影子栈） | 3.325 | 0.027× | 全去盒上限 |
| E'（clean i64） | 1.216 | 0.010× | 硬件下限 |

patch 后 P50 = **3.891 ms**（min 3.673 / max 4.009，n=11），**达到并超过 17 ms
目标 4.4×**，且跨过 B2 天花板、逼近 V3。原因 `[INFERENCE]`：B2 的手工替换只动
`mem_call` 本身（原帧建立 + 影子栈内存槽往返的指令仍在），而 codegen 特化整条
帧建立 + 内存槽往返都不再发射，AOT 后端能更好优化。

### 正确性

- `fib(29) = 514229`、`sum = 499999500000`（E 路输出校验）；
- `./demo.sh` **6/6 PASS**（含负向 array_new 报错）；
- 3 个泛化探针 `probe_{str,mixed,nested}.ts`：patch 后产物经 E 路（rt 桩 + 链接 +
  WAMR）的输出与 perry JS 宿主层（`wasmBoot`）参照**逐字节一致**（`64/200000/long`、
  `n!/19999900000`、`323400`）。

### 反汇编证据

`--bare` 产物 `build/bench.wasm`（`wasm-dis` 反汇编）：

| 指标 | patch 前 | patch 后 |
|---|---:|---:|
| 文件大小 | 9780 B | 9561 B |
| `call $mem_call`（js_add 等） | 8 | 6 |
| `call $mem_call_i32`（is_truthy） | 2 | 0 |
| `f64.add` | 0 | 3 |
| `i64.ne` | 0 | 2 |

fib 热路径：`if (n < 2)` 由 `mem_call_i32(is_truthy)` → `i64.ne TAG_FALSE`；
`fib(n-1)+fib(n-2)` 与循环 `sum += i` 由 `mem_call(js_add)` → `f64.add`。
剩余 6 处 `mem_call` 全是字符串拼接（`"fib(" + … + ") = " + f`、`"sum = " + sum`）
——正符合"可证 number 才内联"的设计边界。

### 与后处理 pass 的关系

`tools/bridge_inline_pass.mjs`（零上游依赖的三格抽象后处理）与本 patch 目标重叠。
**本 patch 落地后后处理 pass 可退役**：codegen 发射点特化是"源头修"，产物更紧
（连影子栈存储都不再产生），且不依赖 wat 后处理基础设施。后处理 pass 的价值
降级为"不能改上游时的替代方案"。

### 遗留风险

- 字符串 `+`、number 条件、`Mod`/`Pow`、`Eq`/`Ne` 仍走桥（正确性所需或保守回退）；
- 类方法体/闭包体内无注解局部、跨 module 导入函数返回类型未纳入数据流 →
  保守回退（无收益但无误判）；
- 类型注解 `[ASSUME]`：沿用 perry 上游语义（与原生 typed ABI 同样信任声明类型）。

新增/改动文件：`tools/attribution/codegen_specialize.patch`、
`tools/attribution/patch_notes.md`（本仓新增）；上游源码实验区
`/tmp/typerry-src/perry`（未 commit）。

## 工程化可复用性评估（2026-09-21 增补）

回答"这个 patch 是一次性实验，还是能进生产、能跟随 perry 上游迭代、能被维护的正式修复"。
三个子问题逐一取证，全部数字来自本次实跑。

### 裁定

**有条件可复用。** 条件两条：① 落地前把 `emit/type_facts.rs`（419 行自写数据流）换成
消费 `perry-hir` 现成的 `HirTypeEnv`/`infer_expr_type`；② 发射点改法（`F64Add` /
`I64Ne(TAG_FALSE)`）照原样提 PR。不带条件 ① 直接提 PR，等于在 wasm 后端长期维护
**第二份**类型推断——上游 main 已经存在一份更完整、且被 `lower/type_widening.rs`
用来做健全性加宽的同类分析。

| 子问题 | 裁定 | 关键证据 |
|---|---|---|
| 1 跨版本移植性 | **档 (b)：有冲突，可手工解决**（5 处机械改动 ≈ 9 行，解决后 `cargo check` 通过） | `git apply --check` 4/6 文件干净、2/6 冲突；上游 main 仍走 `js_add`/`is_truthy`，**未被吸收** |
| 2 正确性测试面 | **零误判**：10 探针 × (E1 双模块 fast-interp / E2 合并 AOT / patch-vs-基线差分) = 无 FAIL | 5 探针 E 路逐字节 PASS；另 5 探针 E 路 SKIP（本仓 rt 桩缺数组/类/闭包/`js_mod` 桥，基线同样 trap），差分 10/10 PASS |
| 3 类型来源架构 | **正式 PR 应当用 HIR 类型环境**，删掉 `type_facts.rs` | HIR env 覆盖类方法体（`current_class`）、闭包（`collect_expr_declarations`）、跨 module 返回（`extern_function_return_type` 钩子）；且 `Stmt::Let.ty` 已由 `lower/type_widening.rs` 做健全加宽 |

### 1. 跨版本移植性：档 (b)

上游取 `main` = `6768ed6bb2c550922bb7bdbebe41429a58438139`（`git ls-remote` +
`git clone --depth 1 --filter=blob:none` 稀疏部分克隆，克隆到 `/tmp/perry-main`；
`/tmp/typerry-src/perry` 全程只读，评估后已移除临时 remote）。该 commit 上
`git apply --check codegen_specialize.patch`：

| 文件 | 结果 |
|---|---|
| `emit/expr/literals_vars.rs` | 干净 |
| `emit/stmt.rs` | 干净 |
| `emit/mod.rs` | 干净（hunk #2 偏移 1 行） |
| `emit/type_facts.rs`（新文件） | 干净 |
| `emit/compile.rs` | **冲突**：`patch failed: ...:1310` |
| `emit/module_emitter.rs` | **冲突**：`patch failed: ...:76` |

冲突全是**上下文漂移**，不是 API 变形；被改的那几行在上游 main 逐字存在
（`git apply -C0` 能过，但那会把 hunk 对到别处，**不可用**）。手工解决 4 处：

| # | 位置 | 改动 | 原因 |
|---|---|---|---|
| 1 | `compile.rs` 开头 | 保留（+4 行） | 构建 `type_facts` 的 hunk 本身干净 |
| 2 | `compile.rs` globals/class 两循环 | **丢弃** patch 的 2 个 hunk | 上游 main 早已自己加了 `current_mod_idx`（`compile.rs:1317-1318`、`1330-1331`，全文件 7 处），且是"保留 `func_map` 赋值 + 追加 `current_mod_idx`"的正确形态；patch 那两行是**替换**，会把 `self.func_map = self.module_func_maps[mod_idx].clone()` 删掉——对多 module 程序的 `FuncRef` 解析是潜在回归（本仓 demo/bench 都是单 module，故未暴露） |
| 3 | `module_emitter.rs` | 重新锚定（+3 行） | 上游 struct 多了 `imported_ns_funcs`/`imported_func_indices` 字段 |
| 4 | `type_facts.rs` | `use perry_types::Type;` → `use perry_hir::types::Type;` | 上游把 `perry-types` crate 并入了 `perry-hir`（base 的 `Cargo.toml` 有 `perry-types.workspace = true`，main 没有） |
| 5 | `type_facts.rs` | match 补 `Stmt::PreallocateTdzBoxes(_)` / `Stmt::ReleaseBoxes(_)` 两个空臂 | 上游 `Stmt` 新增 2 个变体，patch 自写的 **Stmt** 穷尽匹配炸了（`E0004`）。注：patch 的 **Expr** 侧走的是 `perry_hir::walker::walk_expr_children`（HIR 统一穷尽遍历），所以只有 Stmt 侧需要人工跟 |

解决后（`/tmp/perry-main`，裁剪 root manifest 只留 4 个成员的临时 workspace）：

```
$ cargo check -p perry-codegen-wasm
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.72s
```

**上游是否已自己做同样的特化？没有。** main 的 `BinaryOp::Add` 仍是
`emit_memcall(func, "js_add", 2)`（`literals_vars.rs:179-183`），条件仍是 4 处
`emit_memcall_i32(func, "is_truthy", 1)`（`stmt.rs:69/114/166/226`）；wasm 后端没有任何
`infer_expr_type` 消费者（main 上唯一消费者是 LLVM 侧 `perry-codegen/src/collectors/pointer_locals.rs`
与 `perry-hir/src/lower/type_widening.rs`）。所以本 patch 的价值**未被上游吸收**，
但也没人替它挡着——它需要主动提 PR。

移植成本量化：`git apply` 干净 4/6；冲突 2/6 文件、3 个 hunk；解决方式见上表 5 行（含丢弃 2 个 hunk），
净手工改动 ≈9 行。
**不构成本次评估的阻断项**（`cargo check` 已过），但注意：`cargo check` 只证明
"能编过"，**未**在 main 上重建绑定跑 E 路计时/输出（需要整个 perry workspace 构建，
本次网络条件不稳，见"诚实标注"）。

### 2. 正确性测试面：10 探针矩阵，零误判

新增 `tools/attribution/probes/probe_reuse_1..10_*.ts` + 复现脚本
`tools/attribution/reuse_check.sh`（编译探针 → E1/E2/差分 → 汇总 PASS/FAIL）。
E1 = 双模块 fast-interp（`patch-app-memory` + `build/rt.wasm` + `host/perry_link`）；
E2 = `wasm-merge` 合并单模块 → `patch_merged.mjs` → `wamrc` AOT → AOT `iwasm`
（与 `aot_e.sh` 同链路）。参照 = perry 自带 JS 宿主层（`wasmBoot`，`probe_ref.mjs`）。
"差分"= patch 绑定 vs 基线绑定（`/tmp/typerry.node.orig`）在同一探针上的参照输出比对。
"桥 mem_call / mem_call_i32"= 反汇编里 `call $fimport$<mem_call|mem_call_i32>` 计数
（基线 → patch），即静态桥调用点改写量。

| 探针 | 覆盖形态 | E1 | E2 | 差分 | 桥 mem_call | 桥 mem_call_i32 | 参照输出 |
|---|---|---|---|---|---|---|---|
| `probe_reuse_1_class` | 类 + 类方法内算术 | SKIP | SKIP | PASS | 13→13 | 1→0 | `502500 / 42` |
| `probe_reuse_2_closure` | 闭包捕获 | SKIP | SKIP | PASS | 10→9 | 1→0 | `5950 / 10` |
| `probe_reuse_3_nested` | 嵌套函数返回 number | SKIP | SKIP | PASS | 7→6 | 1→0 | `500500 / 0` |
| `probe_reuse_4_letrebind` | 无注解 `let` + 赋值重绑定 | PASS | PASS | PASS | 5→2 | 3→0 | `499500 / 501` |
| `probe_reuse_5_strmix` | 字符串 + number 混合 | PASS | PASS | PASS | 6→5 | 1→0 | `v0123…99 / 4950 / 191` |
| `probe_reuse_6_arrayidx` | 数组索引算术 | SKIP | SKIP | PASS | 17→15 | 1→0 | `24 / 6` |
| `probe_reuse_7_loopctl` | `for` + break/continue | PASS | PASS | PASS | 4→2 | 3→0 | `405447 / 898` |
| `probe_reuse_8_boolcond` | boolean 变量作条件 | PASS | PASS | PASS | 4→2 | 3→1 | `498501 / 999` |
| `probe_reuse_9_nullchk` | `x !== null` + number 条件回退 | PASS | PASS | PASS | 6→2 | 7→5 | `111 / true` |
| `probe_reuse_10_mod` | 模运算 `%` | SKIP | SKIP | PASS | 6→5 | 3→1 | `295 / 50` |

汇总：**E 路逐字节 PASS 5，E 路 SKIP 5，FAIL 0**；差分 **10/10 PASS**。

SKIP 的 5 个探针不是 patch 的问题，而是本仓 E 路 rt 桩只实现了 13 个桥
（`console_*`/`string_*`/`js_add`/`is_truthy`/`js_strict_eq`/`jsvalue_to_string`），
类/闭包/数组/`js_mod` 一律 trap。对照实验（同一探针、**基线**绑定走 E 路）：

```
$ ./build/perry_link <probe_reuse_1_class 基线产物> build/rt.wasm
Exception: bridge function 'class_set_method' is not implemented
```

——与 patch 版逐字相同，故与 patch 无关。这些探针的正确性由"差分"列承担
（patch 绑定与基线绑定在 JS 宿主层下输出逐字节一致 ⇒ 无类型误判）。

两条非显然读数：

- `probe_reuse_1_class` 的 `mem_call` **13→13，零改写**：类方法体里无注解局部的
  `s + this.step(i)` 全被保守拒绝——与 `patch_notes.md` 声明的缺口一致；但
  `mem_call_i32` 1→0 说明**条件特化仍生效**（`i < k` 是 `Compare`，二值布尔由构造保证，
  不依赖局部类型推断）。这正说明缺口是"少赚"，不是"错赚"。
- `probe_reuse_9_nullchk` 的 `mem_call_i32` 7→5：`if (n)`（number 条件）与
  `if (z)`（`z = 0`）**没有被内联**——`111` 而非 `1111` 的参照输出证明 0 仍按 falsy 走桥。
  这是"number 条件保守回退"的活证据。

复现：

```bash
tools/attribution/reuse_check.sh            # 全部 10 探针；退出码非 0 = 有 FAIL
tools/attribution/reuse_check.sh probe_reuse_4_letrebind.ts   # 单个
```

脚本会在差分阶段临时把基线绑定换进 `node_modules`，退出时（含失败路径，`trap EXIT`）
恢复 patch 版绑定；评估结束时仓库绑定状态 = patch 版
（`md5 faa62982e17c380da9a67ff61e773d6f`，与 `/tmp/typerry-src/target/release/libtyperry.so` 同）。

### 3. 类型来源：`type_facts.rs` vs `perry-hir::analysis::HirTypeEnv`

上游 main 的 `perry-hir/src/analysis/value_types.rs`（1860 行）导出了
`infer_expr_type(expr, env) -> Type`、`HirTypeEnv`、`HirTypeFacts` trait、
`infer_refinable_expr_type`；`HirTypeEnv::from_module(&Module)` 与 patch 的
`TypeFacts::from_module(&Module)` 形态一致。覆盖能力对比：

| 形态 | patch `type_facts.rs`（419 行，wasm 后端私有） | HIR `HirTypeEnv` + `infer_expr_type` |
|---|---|---|
| 声明类型（参数/注解 let/函数返回） | ✅ | ✅（`Stmt::Let.ty`、`Function::return_type`） |
| 无注解 `let` 初始化传播 | ✅ 自写数据流 | ✅ 由 `lower/type_widening.rs` 写回 `Stmt::Let.ty`（`var x = 2` → `Number`，有非数值赋值则加宽到 `Any`） |
| 赋值敏感（重绑定/闭包内赋值） | ✅ 自写不动点 + 闭包捕获一律拒绝 | ✅ 同一加宽 pass 覆盖"包括嵌套闭包体"的赋值 |
| 类方法体 / `this` | ❌ 声明缺口（探针 1 实测 0 改写） | ✅ `current_class` + `named_properties` + `static_field_type`/`static_method_returns` |
| 闭包体局部 | ❌ 保守拒绝 | ✅ `collect_expr_declarations` 走 `Expr::Closure` |
| 跨 module 导入返回类型 | ❌ 保守拒绝 | ⚠️ 钩子就位（`extern_function_return_type`），但 `from_module` 是 per-module 的，需后端实现 `HirTypeFacts` 喂多 module 事实 |
| `Stmt`/`Expr` 变体演化 | ⚠️ Expr 走 HIR `walk_expr_children`（自动跟）；**Stmt 自写穷尽匹配 → 上游加变体即编译失败**（本次已撞 2 个） | ✅ 单一来源，`perry-hir` 内维护 |
| `+` 判定精度 | 两侧可证 number 才内联 | `infer_binary_type`：任一 string-like → String；两侧 number-like → Number；BigInt 单独处理（更细） |

**替换改动量更小，且语义更可靠**：删掉 419 行的 `type_facts.rs` 与两处 `is_number_type`
重复定义，`module_emitter` 的 `type_facts: Vec<TypeFacts>` 换成 `Vec<HirTypeEnv>`（或一个
实现 `HirTypeFacts` 的多 module 视图），`expr_is_number` / `expr_is_boolean` 退化成
`matches!(infer_expr_type(expr, &envs[self.current_mod_idx]), Type::Number | Type::Int32)` /
`... == Type::Boolean` —— 净减约 390 行。代价是必须把"number 条件保守回退"写成
`Type::Number | Type::Int32` 的白名单（不能只判 `!= Type::Any`），这点 patch 已经做对。

**工程判断：正式 PR 用 HIR 类型环境。** 两份类型推断在同一个 codebase 里长期共存是
坏味道：上游刚把 `perry-types` 并进 `perry-hir`、又给 `Stmt` 加了两个变体——每次这类
变更都要提醒 wasm 后端"顺手改一下你的第二份推断"。更糟的是两份推断的**健全性论证**
也要维护两遍（patch 的"乐观初值单调递减 + 闭包捕获拒绝"与上游 `type_widening` 的
"任意赋值非数值即加宽到 Any"是同一件事的两种实现）。

### 复现与产物

```bash
# 上游移植性
git clone --depth 1 --filter=blob:none --sparse https://github.com/PerryTS/perry.git /tmp/perry-main
cd /tmp/perry-main && git sparse-checkout set crates/perry-codegen-wasm crates/perry-hir
git apply --check /path/to/tools/attribution/codegen_specialize.patch   # -> 2/6 冲突
# 探针矩阵
tools/attribution/reuse_check.sh
```

产物：`build/reuse/<probe>/{app.wasm,app.wat,app_base.wasm,ref.out,ref_base.out,e1.out,e2.out}`。

### 诚实标注（本节的未做项与假设）

- 上游 main 上只做了 `cargo check -p perry-codegen-wasm`（**编译**通过），**没有**在
  main 上重建 napi 绑定跑 E 路计时/输出——那需要整个 perry workspace（40+ 成员，
  含 swc/扩展）构建，本次网络（`git fetch` early EOF、codeload 无 range）不足以支撑。
  故"移植后性能/正确性不变"是 `[INFERENCE]`，依据是改动全在类型判定来源与 hunk 锚点，
  发射点代码逐字未动。
- patch 的 `compile.rs` 两处 `current_mod_idx` 替换（丢 `func_map` 赋值）对多 module
  程序的 `FuncRef` 解析是**潜在回归**——本仓 demo/bench 是单 module，未触发；
  上游 main 的写法（保留 `func_map` + 追加 `current_mod_idx`）是正确形态。
- 探针矩阵覆盖 10 种形态，仍**未**覆盖：`switch`、`try/catch`、generator/async、
  `bigint`、跨 module import 返回类型（E 路 rt 桩与 perry wasm 后端本身的限制所致）。
- E 路 rt 桩只实现 13 个桥，是**本仓探针装置**的限制，与 patch 质量无关；探针 1/2/3/6/10
  的 E 路证据因此为空，其正确性证据只有"差分"一列。
