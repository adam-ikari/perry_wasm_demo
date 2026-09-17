---
id: perry-wasm-runtime-bridge
title: "perry wasm 输出与宿主运行时的桥接约定 (rt.* ABI)"
category: concept
status: active
tags: [perry, wasm, wamr, abi]
created: "2026-09-15T05:11:48"
updated: "2026-09-17T00:00:00"
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
