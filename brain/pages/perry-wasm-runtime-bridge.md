---
id: perry-wasm-runtime-bridge
title: "perry wasm 输出与宿主运行时的桥接约定 (rt.* ABI)"
category: concept
status: active
tags: [perry, wasm, wamr, abi]
created: "2026-09-15T05:11:48"
updated: "2026-09-28T06:04:44"
---

<!-- compiled_truth -->
perry 的 wasm 后端产出的模块声明 211 个 `rt.*` 导入，把"运行时语义"整个甩给了宿主——`crates/perry-codegen-wasm` 的模块注释写得很直白：*Runtime operations (strings, console, objects) are imported from JavaScript.*。而 native 后端不是这么做的：`crates/perry-runtime`（Rust，GC/JSValue/内置对象）由 `crates/perry-runtime-static` 打成 `libperry_runtime.a`，被 `perry compile` **静态链接进可执行文件**。

**当前架构（路线三，已实测）**：`rt.*` 运行时也用 Rust（`runtime-wasm/`，`#![no_std]`）编译成 wasm 模块；业务模块与运行时模块由 WAMR 多模块机制链接执行，宿主只剩 WASI（`wasi_snapshot_preview1.fd_write`）。

关键事实：

- 业务模块 `import rt.memory`（`tools/patch-app-memory.mjs` 把 memory 段改成 import，min=1）；运行时模块导出 memory，`.cargo/config.toml` 用 `--global-base=2097152` 把 data/bss/stack 放到 2 MiB 以上避开低地址区。
- 211 个导入 = 13 个真实实现 + 198 个编译期桩函数（`tools/gen-rt-symbols.mjs` 从导入段生成 `build/rt_symbols.rs`，`lib.rs` 用 `include!` 引入）；桩调用即写 stderr `bridge function 'xxx' is not implemented` 后 trap，不返回假数据。
- `host/perry_link.c` runner 只做 load rt → register "rt" → `wasm_runtime_set_wasi_args(rt)` → load app → instantiate → `wasm_application_execute_main`，没有任何 `rt.*` 实现。
- 实测：`./demo.sh` 6/6 步 PASS；正向（Rust 运行时模块 vs perry JS 宿主层）5 行逐字节一致；负向（数组程序）`array_new` 实名报错、退出码 1。产物：`app.wasm` 10650 B、`app_link.wasm` 10658 B、`rt.wasm` 16798 B。

## 路线四（已验证）：直接复用 perry-runtime 源码编译进 wasm

不再手写 `rt.*` 桩，而是把 `crates/perry-runtime` 作为 path 依赖，编成 `wasm32-wasip1` cdylib，用薄适配层把 `rt.*` 转发到 `js_*`。**已实测成立**（2026-09-27 入库 `tools/route4/`：一键 `build.sh` 五步构建 + `verify.mjs` 五组断言全绿；WAMR iwasm 2.4.3）：

- **链接可行**：`use perry_runtime::builtins::js_add; use perry_runtime::value::{js_is_truthy, JSValue};` 走 Rust 路径引用即可把 rlib 成员拉入；**仅用 `extern "C"` 块声明符号会被留在 wasm 导入段**（rlib 成员不拉入），这是第一个坑。
- **自包含**：模块 imports 从 39 降到 28，**28 个全部是 `wasi_snapshot_preview1.*`，零非 WASI 导入**。做法是适配层自实现 `setjmp`/`longjmp`/`perry_sjlj_try` + 8 个 `_Unwind_*`。
- **功能实证**（2026-09-27 复跑，`verify.mjs` 第 5 步同组探针；导出名是 `rt.*` 的字段名、无 `rt_` 前缀，i64 入参只接受整数或十六进制位型，十进制浮点会被 iwasm 的 strtoull 拒绝）：`iwasm -f is_truthy build/rt4.wasm 0` → `0x0:i32`；入参 `0x3FF0000000000000`（f64 1.0 的位型）→ `0x1:i32`；`iwasm -f js_add build/rt4.wasm 0x4000000000000000 0x4008000000000000`（2.0 与 3.0 的位型）→ `0x4014000000000000:i64`（=5.0）。perry 自家 Rust 运行时语义在 wasm 里真实执行。
- **EH 桩是链接期残留、非运行期需求**：perry `build.rs` 明写 *wasm32 has no C setjmp trampoline: the wasm backend routes try/catch through host imports, so the Rust-side transport never arms one*；wasm 下 try/catch 走 `rt.try_start`/`rt.try_end` 宿主导入，`_Unwind_*` 永不被调用。
- **ABI 天然对齐**：perry-runtime 与 `rt.*` 的 NaN-box tag 完全一致（`0x7FFC` singleton / `0x7FFD` pointer / `0x7FFE` int32）。**唯一差异**是 `0x7FFF` 字符串低 48 位：`rt.*` 是字符串表下标，perry-runtime 是内存指针 → 适配层需建 index↔pointer 双向表。
- **覆盖度**（`tools/route4/coverage.mjs` 名层三层可复算，2026-09-27）：198 个 `rt.*` 中，122 个同名直连（direct，`js_<桩名>` 精确命中）、27 个近名直连（near，去下划线归一或同词干，如 `closure_call_0`→`js_closure_call0`）、30 个有异名但存在的对应实现（alias，如 `array_new`→`js_array_alloc`、`js_typeof`→`js_value_typeof`、`class_call_method`→`js_native_call_method`、`searchparams_get`→`js_url_search_params_get`），合计 **179 / 198 ≈ 90%（名层口径：上游源码有对应符号 ≠ 适配层已接通）**。
- **无对应者 19 个**（名层），且都是"本就不该在运行时里"的：Math 内建 4（native codegen 内联为 wasm 指令，适配层已就地用 `f64::floor` 等改写）、Web API 7（`response_*` 6 个无专用取值符号、`fetch_url` 真身在 perry-stdlib/宿主网络）、Crypto 4（依赖 native 库）、try/catch 2（按设计走宿主导入）、零散 2（`string_includes`、`is_null_or_undefined`，后者已就地改写）。其中 5 个已就地改写，14 个仍待实现。
- **适配层端到端（2026-09-26 实测，2026-09-27 入库复跑）**：适配层共实现 29 个 `rt.*`（13 桥全部转成 perry-runtime 导出 + 16 个原桩补实现：11 个转发上游符号、5 个就地改写），其余 182 个仍是报错桩；demo 正向 5 行与参照逐字节一致、负向 `array_new` 实名报错退出码 1、导入段 28 项全 WASI。demo 在路线三下即已通过（彼时 198 桩全是 trap），故其执行路径只触及这 13 个桥——覆盖度是名层潜力、不是运行期已接通数。
- **代价**：体积 16,928 B → 7,298,105 B（约 430×；入库构建 7,314,044 B，源码在 `.deps/perry-src`，与 /tmp 路径产物差 15,939 B = Data 段 334 条 panic location 绝对路径，不是代码差异）；同一 `bench.wasm` 15 样本 P50 路线三 103.638 ms vs 路线四 112.489 ms = **1.09×**（成因归于 StringHeader 指针层与 `RuntimeHandleScope`/thread-local rooting，未逐项插桩）；另有一次性 INIT 段 252 ms（路线三无）。多模块共享下体积可摊薄。
- **边界**：性能矩阵全部仍只来自路线三；路线四只过了 13 个桥的值语义 + 单基准计时，AOT 形态、14 个名层无对应缺口的接法、非 fib 负载下的 1.09× 均未测。

结论：把 perry 的 JS 运行时"完整"放进 wasm 在链接与执行层面已无阻塞；剩余 182 个桩分两段——168 个上游有对应实现、接线是搬运（多数只差参数整形），14 个名层无对应才需要宿主侧实现或按 wasm 语义改写（该类共 19 个，已就地改写 5 个）；缺口是接线量问题，而非运行时复用问题。

## 测量修正：NAME_CACHE 缓存降幅（2026-09-26 复测）

9-19 记录的 nameId 缓存直查降幅 −43%（3959→2292 ms，322 ns/次）在 9-26 的同机交错复测中不可复现：同一 `bench.wasm` + 同一 runner，正式 `rt.wasm`（缓存直查）与按名扫描复刻版（`/tmp/rt_nocache`，16818 B）交错各 15 样本 P50 为 **110.893 vs 113.929 ms，交错降幅仅 2.7%**。两版正/负向行为一致。跨日绝对值差约 37×（当日 P50 107–113 ms vs 9-19 的 3959 ms），而代码只差 130 B 缓存表——归因当日环境（背景负载/宿主状态），非代码。**可外推结论只剩：缓存直查不慢于按名扫描，且两版行为等价**；−43%/−38%/322 ns 只作 9-19 当日环境读数。论文 §6.1 与附录 A.11 已写入该修正与四组 15 样本原始值。

## 历史：C 桥接宿主（路线一·探针）

用 `host/perry_rt.c` 实现 13 个纯原始值 `rt.*`，`build/rt_symbols.inc` 补齐 198 个桩，编成 `libperry_rt.so`，`iwasm --native-lib=…` dlopen 进 WAMR；宿主侧 `fwrite(stdout)` 输出、`wasm_runtime_set_exception` 抛异常。价值是测出宿主边界与 `rt.*` ABI，已被路线三取代。

### WAMR 宿主接入（探针形态）

`.so` 导出 `get_native_lib()` 返回模块名 `"rt"` 与 `NativeSymbol[]`；`iwasm --native-lib=…`。原生函数首参为公开类型 `wasm_exec_env_t`；iwasm 需用 `-Wl,--export-dynamic` 构建，否则宿主库解析不到 `wasm_runtime_*`。未实现的导入一律抛 `Exception: bridge function '<name>' is not implemented`（退出码 1），不返回假数据。产物 `app.wasm` 只有 11 个段、无 name 自定义段，函数名与局部变量名不泄漏。

论文 `docs/paper/perry-wasm-paper.md` 已完成四条实验 + 复测修正的整合，提交 `81d828b`；2026-09-27 追加修订：覆盖度改 179/198（名层口径，coverage.mjs 可复算）、语义命令改可复现形式（iwasm -f + 十六进制位型）、`tools/route4/` 入库与 F.13 改写，提交 `6536749`。


## Timeline

- time: 2026-09-15T05:11:48
  kind: decision
  summary: "Created this page: perry wasm 输出与宿主运行时的桥接约定 (rt.* ABI)"
  source: "本次 demo 实现与逆向验证"
  affects: [perry-wasm-runtime-bridge]

- time: 2026-09-15T05:12:35
  kind: decision
  summary: "固化 rt.* ABI 与 WAMR 宿主接入要求"
  source: "build/app.wasm 导入段 + wasmBoot 生成的 JS runtime 插桩验证"
  affects: [perry-wasm-runtime-bridge]

- time: 2026-09-15T07:07:58
  kind: note
  summary: "术语修正: perry 自带宿主层与 JS 引擎无关(它是 platform-independent ES module runtime, 用 JS 写成, Node/Bun/浏览器皆可运行), 文章/README/demo.sh/perry_rt.c 中 \"JS runtime\" 统一改为 \"JS 宿主层\", 避免与引擎混淆"
  source: "用户指正 + @typerry/node README"
  affects: [perry-wasm-runtime-bridge]

- time: 2026-09-15T07:10:02
  kind: note
  summary: "探索意义结论(写进文章 '想回答的问题' / '代价' 两节): 源码保护只有条件成立——wasm 可反编译, 导入名/字符串常量全在, 门槛只是从读源码抬到反编译; '一次分发到处运行'的成本从'每平台装引擎'变成'每平台实现 rt.* 宿主', 实测纯原始值 13 个实现够用, 用数组即报错, 完整 JS 语义等于重做 perry 运行时. 适用场景: 宿主可控且语言子集可裁剪(嵌入式规则脚本/插件/内部交付)"
  source: "docs/perry-wasm-wamr.md 与本次实测"
  affects: [perry-wasm-runtime-bridge]

- time: 2026-09-15T08:48:39
  kind: decision
  summary: "改立论: 正解是把 perry-runtime 编成 wasm 随产物分发, 而不是给每个宿主重写 rt.*"
  source: "perry 仓库结构 (crates/perry-runtime, perry-runtime-static, perry-codegen-wasm) + wasm 导入段实测 + 用户指正"
  affects: [perry-wasm-runtime-bridge]

- time: 2026-09-17T00:00:00
  kind: decision
  summary: "compiled_truth 改为路线三实测架构: rt.* 运行时用 Rust (runtime-wasm/ no_std) 编成 wasm 模块, 业务与运行时两模块由 WAMR 多模块链接, 宿主只剩 WASI fd_write; 业务模块 import rt.memory, 运行时导出 memory (--global-base=2097152), 211 导入 = 13 实现 + 198 编译期桩 trap. 实测 demo.sh 6/6 PASS, 正向逐字节一致, 负向 array_new 报错退出码 1. 旧 C 桥接 (libperry_rt.so) 降为历史"
  source: "runtime-wasm/src/lib.rs + host/perry_link.c + tools/gen-rt-symbols.mjs + tools/patch-app-memory.mjs + demo.sh 实测"
  affects: [perry-wasm-runtime-bridge]

- time: 2026-09-20T00:44:31
  kind: decision
  summary: "增补 WAMR AOT 事实: AOT 不支持 import memory(须 wasm-merge 合并单模块), AOT 下干净 wasm 与原生同速, perry wasm vs perry 原生 393×→23×"
  source: "tools/attribution/aot_e.sh + WAMR 源码 aot_emit_aot_file.c/aot_validator.c 实测"
  affects: [perry-wasm-runtime-bridge]

- time: 2026-09-21T03:23:36
  kind: note
  summary: "根因裁定: perry wasm 慢 100% 来自 codegen-wasm 类型擦除桥形态(非引擎/优化器)——干净 wasm×AOT 与原生同速 0.97×, perry wasm×AOT=104×原生, 141ms 里 95.8% 是 rt 桥函数体机器码(25.4ns/桥); QuickJS 纯解释器 85.5ms 竟快 0.58×; 修复: 路径3 类型特化→17.2ms, 路径4 typed ABI+去影子栈→3.3ms(同数量级), 方案见 docs/typed-abi-migration.md; perry 原生路纯执行仅 1.2-1.9× 手写 C"
  source: "docs/performance.md 审计节 + docs/typed-abi-migration.md + tools/attribution/nohost_box_app.wat 隔离实验"
  affects: [perry-wasm-runtime-bridge]

- time: 2026-09-21T03:23:54
  kind: decision
  summary: "compiled_truth 追加「性能根因与修复路径（2026-09-21）」节: 根因=codegen-wasm 类型擦除桥形态(非引擎/优化器), QuickJS 纯解释器 85.5ms 反超 AOT 桥形态 0.58×, 修复天花板 路径3→17.2ms / 路径4→3.3ms, 方案 docs/typed-abi-migration.md"
  source: "docs/performance.md 审计节 + docs/typed-abi-migration.md + tools/attribution/nohost_box_app.wat 隔离实验"
  affects: [perry-wasm-runtime-bridge]

- time: 2026-09-23T12:34:13
  kind: decision
  summary: "来源文档整合后更新方案文档指针: typed ABI 迁移规划并入论文"
  source: "docs 整合: 5 个来源 md 并入 docs/paper/perry-wasm-paper.md"
  affects: [perry-wasm-runtime-bridge]

- time: 2026-09-24T02:25:58
  kind: evidence
  summary: "复用 perry-runtime 编译进 wasm 已实测可行: 新建 cdylib 直接 use perry_runtime::builtins::js_add / value::js_is_truthy 等公开 re-export, cargo build --target wasm32-wasip1 链接成功 (6.85MB, 39 imports 全是 env._Unwind*/setjmp/longjmp + wasi_snapshot_preview1, 无任何 js_* 导入), js_add/js_is_truthy 成为模块内真实导出。关键: 必须走 Rust 路径引用符号, 仅 extern 块声明会被留在 wasm 导入段 (rlib 成员不拉入)。perry-runtime 的 NaN-box tag 与 rt.* ABI 完全一致 (0x7FFC singleton / 0x7FFD pointer / 0x7FFE int32), 唯一差异是 0x7FFF 字符串低 48 位: rt.* 是字符串表下标, perry-runtime 是内存指针, 适配层需建 index<->pointer 双向表。"
  source: "probe: /tmp/reuse-probe (perry-runtime path dep, wasm32-wasip1 cdylib)"
  affects: [perry-wasm-runtime-bridge]

- time: 2026-09-24T02:45:52
  kind: evidence
  summary: "复用可行性决定性验证通过: (1) 自包含性——适配层自实现 setjmp/longjmp/perry_sjlj_try/_Unwind_* 八个符号后, 模块 imports 从 39 降到 28, 且 28 个全部是 wasi_snapshot_preview1.*, 零非 WASI 导入; (2) 功能实证——iwasm 直接调用 rt_is_truthy(0)->0x0, rt_is_truthy(1.0)->0x1, rt_js_add(2.0,3.0)->0x4014000000000000(=5.0), 即 perry 自家 Rust 运行时语义在 wasm 里真实执行; (3) EH 桩是链接期残留而非运行期需求——perry build.rs 明确注释 'wasm32 has no C setjmp trampoline: the wasm backend routes try/catch through host imports, so the Rust-side transport never arms one', 即 wasm 下 try/catch 走 rt.try_start/rt.try_end 宿主导入, _Unwind_* 永不被调用。rt.* 覆盖度: 198 个中 150 个与 js_* 同名/近名直连, 另 16 个有不同名但存在的对应实现, 合计 166 (~84%); 剩余 31 个无对应: Math 内建 4(在 native codegen 里内联为 wasm 指令, 运行时不提供)、Web API 13(fetch/Response/URLSearchParams, 本就在宿主边界外)、Crypto 4(依赖 native 库)、try/catch 2(按设计走宿主导入)、零散 8。规模代价: 单模块 6.73MB(未 strip/未裁剪特性), 对多模块共享可摊薄。"
  source: "probe /tmp/reuse-probe: wasm32-wasip1 cdylib + WAMR iwasm 2.4.3 实测"
  affects: [perry-wasm-runtime-bridge]

- time: 2026-09-24T02:49:30
  kind: decision
  summary: "追加路线四(已验证): 直接复用 perry-runtime 源码编进 wasm32-wasip1 cdylib, imports 100% WASI, iwasm 实测 js_add/is_truthy 语义正确, rt.* 覆盖 166/198, 31 缺口均为本不该在运行时内的 Math/Web/Crypto/EH"
  source: "探针 /tmp/reuse-probe + WAMR 2.4.3 实测"
  affects: [perry-wasm-runtime-bridge]

- time: 2026-09-26T02:39:19
  kind: evidence
  summary: "适配层实验通过: /tmp/rt4 把 13 个真实桥的值语义全部换走 perry-runtime C 导出 (字符串表条目改存 StringHeader*, codegen index 载荷不变)。WAMR 实测 app.ts 正向逐字节一致、负向 array_new 实名报错、imports 28 全 WASI。代价 16.9KB->7.3MB(~430x)。坑: rust-lld fat-LTO 读 perry_runtime rlib bitcode 失败(magic/版本正常), 改 lto=thin 绕过; 并发 cargo 同 target 会写坏 fingerprint。"
  source: "/tmp/rt4 适配层 + WAMR iwasm 2.4.3 实测"
  affects: [perry-wasm-runtime-bridge]

- time: 2026-09-26T08:03:47
  kind: evidence
  summary: "route-4 性能实测: 同一 bench.wasm(fib29+1e6循环, 15样本P50), route-3 手写运行时 103.6ms vs route-4 perry-runtime 适配层 112.5ms = 1.09x 慢。桥路径为主 hot path (~533万次 mem_call), perry StringHeader 指针层与 perry 动态 add 的 RuntimeHandleScope/thread-local rooting 开销 (~322ns/桥量级的一部分) 抬高桥耗时; INIT 段 perry-runtime 一次性初始化 252ms (route-3 无)。结论: 计算密集场景 route-4 慢 ~9%, 语义正确性等价 (fib/sum 输出一致), 代价主要是体积 430x 与桥路径常数。"
  source: "build/bench_time 15样本 P50 实测 2026-09-26"
  affects: [perry-wasm-runtime-bridge]

- time: 2026-09-26T10:50:56
  kind: evidence
  summary: "NAME_CACHE 复测修正(2026-09-26): NAME_CACHE 缓存早已合入正式 runtime-wasm/src/lib.rs (9/19 采纳), 今日 demo.sh 重编 6/6 PASS。同机交错 A/B 重测 (同一 bench.wasm+runner, 各15样本P50): 缓存直查 110.9ms vs 按名扫描 113.9ms = 提速 2.7%, 远低于 9/19 实验记录的 -43%(3959→2292ms)。9/19 值在当前环境不可复现, 推断为当时环境因素 (现 P50 107-113ms vs 当时 3959ms, 差 37x, 非代码可解释)。以今日交错测量为准: memcmp 10 项短串在本机 ~0.1us/次量级, 并非主要瓶颈; 论文 §6.1 的 -43%/322ns 数字应标注当日环境, 不可外推。两版本正向/负向行为均一致。"
  source: "build/bench_time 交错 A/B, /tmp/rt_nocache 复现版"
  affects: [perry-wasm-runtime-bridge]

- time: 2026-09-26T18:16:02
  kind: note
  summary: "论文 docs/paper/perry-wasm-paper.md 已整合 2026-09-24/26 四条新实验：§3.2 三条路线改四条路线并写入路线四（rlib 路径引用、导入段 39→28 全 WASI、覆盖 166/198、体积 430×、单基准 1.09×、INIT 252 ms）；§6.1 新增 nameId 缓存复测修正（交错降幅 2.7%，−43% 降级为 2026-09-19 当日环境读数，不可外推）；同步摘要/§1.3/§2.3/§4.3/§5.3/§8/§9；新增附录 A.11（四组 15 样本原始值全量转录，已与 /tmp 原始记录逐个核对一致）与 F.13（路线四实施细节与坑，探针未入库声明）。行宽 ≤80 检查通过。未提交 git。"
  source: "2026-09-26 论文修订"
  affects: [perry-wasm-runtime-bridge]

- time: 2026-09-27T05:10:45
  kind: decision
  summary: "compiled_truth 增补: 路线四适配层端到端(13桥值语义全换, 正负向一致, 导入28全WASI)与代价(16,928→7,298,105 B≈430×, 单基准 103.638 vs 112.489=1.09×, INIT 252ms)及性能边界(矩阵仍只来自路线三); 新增「测量修正」节: nameId 缓存交错降幅 2.7%(110.893 vs 113.929, n=15), −43% 降级为 2026-09-19 当日环境读数不可外推; 论文整合已提交 81d828b"
  source: "2026-09-24/26 四条实验 + 论文整合提交 81d828b"
  affects: [perry-wasm-runtime-bridge]

- time: 2026-09-27T09:35:36
  kind: decision
  summary: "compiled_truth 修订(2026-09-27): 覆盖度 166/198(84%) 修正为 179/198(90% 名层三层口径, tools/route4/coverage.mjs 可复算, direct 122/near 27/alias 30), 无对应者 31→19(5 已就地改写/14 待实现), 写入 29 实现/182 桩的接线事实与名层≠已接通边界; 语义命令换可复现形式(iwasm -f is_truthy/js_add + 十六进制位型, 导出名无 rt_ 前缀); 探针入库 tools/route4/(build.sh+verify.mjs 全绿); 产物双口径 7,314,044 B(.deps) vs 7,298,105 B(/tmp); 论文对应修订提交 6536749"
  source: "tools/route4/{coverage,verify}.mjs + build.sh 实测 (2026-09-27) + 论文 6536749"
  affects: [perry-wasm-runtime-bridge]

- time: 2026-09-27T09:35:36
  kind: reversal
  summary: "推翻两条 2026-09-24/26 期间的结论: (1) 覆盖度 166/198≈84% 不成立——原脚本不可复现且算术 150+16+31≠198, 实际名层三层比对为 179/198≈90% (direct 122/near 27/alias 30, 异名表 22→30 条), 余 19 而非 31 (URLSearchParams 6 条有 js_url_search_params_* 对应, 从缺口移入 alias); (2) 语义探针命令 iwasm -f rt_is_truthy … 1.0 / rt_js_add 2.0 3.0 不可复现——rt4 导出名无 rt_ 前缀且 i64 入参不接受十进制浮点(strtoull 拒绝), 换成 is_truthy 0/0x3FF0000000000000 与 js_add 0x4000000000000000 0x4008000000000000 三条位型探针, verify.mjs 第 5 步 2026-09-27 复跑通过"
  source: "coverage.mjs 三层判定 + iwasm 2.4.3 实测 + 论文 6536749"
  affects: [perry-wasm-runtime-bridge]

- time: 2026-09-28T06:04:44
  kind: decision
  summary: "路线四 AOT 实测：rt4 AOT P50 = 5.121 ms vs rt3（E链）5.240 ms = 0.98×（同日交错 n=11），路线三/四 AOT 下速度完全对齐；解释器下 1.09× 差距被 AOT 消除。aot_rt3.aot=72652 B、aot_rt4.aot=19199376 B（19 MB）。patch_rt4_merged.mjs 改写了1处超 64-cell call_indirect（type $407, i32+f64×32→f64）为 unreachable（structural-assertion 等价：全模块无函数实现该签名，必 trap）。"
  source: "tools/route4/aot.sh 12 跑 12 轮交错 A/B，弃第1轮，build/route4_aot_runs.txt; PASS: rt3/rt4 AOT 输出均 == fib(29)=514229 + sum=499999500000"
  affects: [perry-wasm-runtime-bridge]
