---
id: perry-wasm-runtime-bridge
title: "perry wasm 输出与宿主运行时的桥接约定 (rt.* ABI)"
category: concept
status: active
tags: [perry, wasm, wamr, abi]
created: "2026-09-15T05:11:48"
updated: "2026-09-21T03:23:54"
---

<!-- compiled_truth -->
perry 的 wasm 后端产出的模块声明 211 个 `rt.*` 导入，把"运行时语义"整个甩给了宿主——`crates/perry-codegen-wasm` 的模块注释写得很直白：*Runtime operations (strings, console, objects) are imported from JavaScript.*。而 native 后端不是这么做的：`crates/perry-runtime`（Rust，GC/JSValue/内置对象）由 `crates/perry-runtime-static` 打成 `libperry_runtime.a`，被 `perry compile` **静态链接进可执行文件**。

**当前架构（路线三，已实测）**：`rt.*` 运行时也用 Rust（`runtime-wasm/`，`#![no_std]`）编译成 wasm 模块；业务模块与运行时模块由 WAMR 多模块机制链接执行，宿主只剩 WASI（`wasi_snapshot_preview1.fd_write`）。

关键事实：

- 业务模块 `import rt.memory`（`tools/patch-app-memory.mjs` 把 memory 段改成 import，min=1）；运行时模块导出 memory，`.cargo/config.toml` 用 `--global-base=2097152` 把 data/bss/stack 放到 2 MiB 以上避开低地址区。
- 211 个导入 = 13 个真实实现 + 198 个编译期桩函数（`tools/gen-rt-symbols.mjs` 从导入段生成 `build/rt_symbols.rs`，`lib.rs` 用 `include!` 引入）；桩调用即写 stderr `bridge function 'xxx' is not implemented` 后 trap，不返回假数据。
- `host/perry_link.c` runner 只做 load rt → register "rt" → `wasm_runtime_set_wasi_args(rt)` → load app → instantiate → `wasm_application_execute_main`，没有任何 `rt.*` 实现。
- 实测：`./demo.sh` 6/6 步 PASS；正向（Rust 运行时模块 vs perry JS 宿主层）5 行逐字节一致；负向（数组程序）`array_new` 实名报错、退出码 1。产物：`app.wasm` 10650 B、`app_link.wasm` 10658 B、`rt.wasm` 16798 B。

## 历史：C 桥接宿主（路线一·探针）

用 `host/perry_rt.c` 实现 13 个纯原始值 `rt.*`，`build/rt_symbols.inc` 补齐 198 个桩，编成 `libperry_rt.so`，`iwasm --native-lib=…` dlopen 进 WAMR；宿主侧 `fwrite(stdout)` 输出、`wasm_runtime_set_exception` 抛异常。价值是测出宿主边界与 `rt.*` ABI，已被路线三取代。

### WAMR 宿主接入（探针形态）

`.so` 导出 `get_native_lib()` 返回模块名 `"rt"` 与 `NativeSymbol[]`；`iwasm --native-lib=…`。原生函数首参为公开类型 `wasm_exec_env_t`；iwasm 需用 `-Wl,--export-dynamic` 构建，否则宿主库解析不到 `wasm_runtime_*`。未实现的导入一律抛 `Exception: bridge function '<name>' is not implemented`（退出码 1），不返回假数据。产物 `app.wasm` 只有 11 个段、无 name 自定义段，函数名与局部变量名不泄漏。

## 组装路线（按改动量排，路线三已实现）

1. **多模块共享内存（= 路线三，已实现）**：runtime 编成独立 wasm 模块，导出同名 `rt.*`，memory 从业务模块导入（`--import-memory`）；业务 wasm 零改动，宿主只把两模块接起来（WAMR 多模块 / wasmtime linker）。宿主侧只剩 WASI。
2. **静态链接成单模块（未实施）**：`wasm-ld` 把 runtime 的 wasm 静态库与 codegen 输出链成一个模块，与 native 路径同构；需要 codegen 产出可重定位对象，或让链接器把 import 解析为本地符号。
3. **Component Model（未实施）**：WIT 声明 `rt` 接口；接口最干净，但 canonical ABI 的 lift/lower 给每次调用加编解码，与"f64 位模式 + 线性内存槽位"的零拷贝约定冲突，WAMR 支持也弱。

## 阻碍（来自 perry 源码）

- `perry-runtime` 含 `fs` / `dns` / `dgram` / `child_process` / `cluster` / `net` / `atomics`+`futex` / `macos_bundle` 等 OS 强耦合模块，wasm 目标要么走 WASI（socket 仍在提案），要么不编入。这部分永远在宿主边界外。
- 分配器：默认 mimalloc 受 `#[cfg(target_pointer_width = "64")]` 限制，wasm32（ILP32）自动落回系统分配器。
- 体积：运行时进 wasm 后每份产物自带一份；多模块/component 可共享。
- 有利条件：perry 已有按程序实际特性裁剪运行时子集的机制（auto-optimize / `optimized_libs.rs`），wasm 化相当于给它加一个 wasm 目标预设。

## 本次实测固化的 ABI（业务模块与运行时模块共用，仍然有效）

值 = f64 位模式按 i64 过边界；`0x7FFC…0001..04` = undefined/null/false/true，高 16 位 `0x7FFF` = 字符串(低 32 位为字符串表下标)，`0x7FFD` = 对象/数组/闭包 handle，`0x7FFE` = int32 快路径。
211 个导入只用到 16 种类型，绝大多数是 `(i64…)->i64` 形态；`string_len` = `(i64)->i64`，`string_concat` = `(i64,i64)->i64`，`console_log` = `(i64)->()`，`string_new` = `(i32,i32)->()`。
`mem_call(nameId, argc, base)`：nameId 是桥接函数名在字符串表里的下标，参数以 u64 槽位写在线性内存 `base`，结果写回 `base`；`mem_call_i32` 结果直接 i32 返回。字符串表按启动时的 `rt.string_new` 调用顺序 append，下标即 id——错位则字符串全废。

## WAMR AOT 事实（2026-09-19 实测）

- **AOT 文件格式不支持 import memory**：`core/iwasm/compilation/aot_emit_aot_file.c` 硬编码 `import_memory_count = 0`（TODO 注释），加载时 `aot_validator.c` 直接拒绝（"import memory is not supported"）。因此双模块结构（业务模块 import rt.memory）**无法整体 AOT**：app.aot + rt.aot 运行即 "out of bounds memory access"。
- **可行方案**：用 binaryen 的 `wasm-merge` 把 app+rt 合并成单模块再 `wamrc`。系统 LLVM 14 即可构建 wamrc，无需自编全量 LLVM。合并后需后处理（`tools/attribution/patch_merged.mjs`）：删 rt 侧 `__data_end`/`__heap_base` 导出（与 app 栈指针组合成非法 aux stack）+ 织入 `_start` wrapper 先调 `_initialize`。
- **性能结论**：干净 wasm × WAMR AOT 与原生 gcc -O2 同速（E' 1.362 ms = 0.97× 原生，解释器 35× 引擎因子归零）；perry wasm × AOT E 146.829 ms = 原生的 104×，剩余差距几乎全是 perry codegen 桥调用形态。
- **perry 两条后端差距**（perry wasm vs perry 原生）：解释器下 393× → AOT 下 23×。
## 性能根因与修复路径（2026-09-21）

- **根因裁定（100%）**：perry wasm 慢的根因在 `perry-codegen-wasm` 的类型擦除桥形态，与引擎/优化器无关——干净 wasm × WAMR AOT 与原生 gcc -O2 同速（E' 1.362 ms = 0.97× 原生）；perry wasm × AOT E 146.829 ms = 原生 104×；nohost 隔离实验证明调用图形态本身只值 5.9 ms，E 的 141.4 ms 里 135.5 ms（95.8%）是 rt 侧 `mem_call` / `js_add` 桥函数体的机器码执行（每桥 25.4 ns + 装箱税 1.4 ns）。
- **QuickJS 旁证**：纯解释器跑同算法仅 85.5 ms，比 perry wasm × AOT（146.8 ms）还快 0.58×——无桥的解释器胜过有桥的机器码。
- **修复天花板（等价手工特化实测）**：路径 3（发射点类型特化）→ B2 = 17.2 ms（快 7.1×）；路径 4（typed ABI 化 + 去影子栈）→ V3 = 3.3 ms，即与 perry 原生纯执行（1.6–2.6 ms）同数量级。用户裁决路径 4 为正确路线。
- **方案文档**：`docs/typed-abi-migration.md`（6 阶段 16–30 人日，含上游 file:line 索引）；perry 原生路本身健康，纯执行仅比手写 C 慢 1.2–1.9×。


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
