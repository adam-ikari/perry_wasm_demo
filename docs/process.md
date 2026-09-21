# 从 C 桥接到 wasm 运行时：实施过程记录

本文记录 perry-wasm demo 从**路线一**（C 桥接宿主 `libperry_rt.so`）迁移到**路线三**
（运行时 wasm 模块 + WAMR 多模块链接）的完整过程：背景、决策、按时间的实施步骤、
踩坑实录、最终验证与现状。架构原理见 `docs/perry-wasm-wamr.md`，产物清单见 `README.md`。

## 背景

- **perry**（[PerryTS/perry](https://github.com/PerryTS/perry)）：Rust 写的 TS/JS 编译器，
  走 SWC 解析 + LLVM 后端，主要产物是原生可执行文件；`crates/perry-runtime` 是它自带的
  Rust 运行时（GC、JSValue、字符串、内置对象）。
- **typerry**：perry 的 wasm 后端抽出来发的 npm 包（`@typerry/node`，napi-rs 绑定，零运行时
  依赖）。产出的 wasm 不是裸算法模块，而是一个完整程序：导出 `_start` 和 `memory`，并声明
  211 个 `rt.*` 导入（字符串、console、Math、JSON、Date、Map/Set、Buffer、crypto……），
  **不管用不用，WAMR 实例化时全部要求可解析**。
- **WAMR**（WebAssembly Micro Runtime）：C 实现的嵌入式 wasm 运行时，本 demo 用 2.4.3，
  构建需 `WAMR_BUILD_MULTI_MODULE=1`、`WAMR_BUILD_LIBC_WASI=1`、`WAMR_BUILD_TARGET=X86_64`。

**初始设计（路线一）**：C 桥接宿主。用 `host/perry_rt.c` 实现"纯原始值"那一部分 `rt.*`
（13 个），其余 198 个由 `build/rt_symbols.inc` 生成"调用即报错"的桩，编成
`libperry_rt.so`，`iwasm --native-lib=…` dlopen 进 WAMR。输出由宿主侧 `fwrite(stdout)`
直接写，错误用 `wasm_runtime_set_exception` 抛 wasm 异常。它把 ABI 测了出来，但代价清晰：
**每个平台都要用别的语言把运行时重写一遍**，成本随程序用到的语言特性线性增长。

## 决策

用户原话：

> 当前的运行时也需要使用 wasm 编译，宿主应该只需要使用 wasi 提供日志。

据此确定路线三：不换语言重写运行时，而是把 perry 的 Rust 运行时源码按 wasm 目标编译成
独立模块，和业务模块一起由 WAMR 多模块机制链接执行；宿主不再提供任何 `rt.*`，只剩
WASI（`wasi_snapshot_preview1.fd_write`）写 stdout/stderr。三条路线的关系（一/二为历史或
未实施、三为当前实现）见 `docs/perry-wasm-wamr.md` 的"架构（实测）"节。

## 实施步骤（按时间）

### 1. 建 `runtime-wasm/`

```
runtime-wasm/
├── Cargo.toml          # cdylib, opt-level=s, lto=true, panic=abort, strip
├── src/lib.rs          # #![no_std], 620 行
└── .cargo/config.toml  # wasm32-unknown-unknown 链接参数
```

- `Cargo.toml`：`crate-type = ["cdylib"]`；release 用 `opt-level = "s"` + `lto = true` +
  `panic = "abort"` + `codegen-units = 1` + `strip`，压体积。
- `lib.rs` 顶部：`#![no_std]`，自定义 `panic_handler` → `trap()`（`unreachable`），
  `mem_ptr`/`mem_bytes` 用线性内存偏移当指针。
- `.cargo/config.toml`：`--global-base=2097152` 把运行时自己的 data/bss/stack 放到 2 MiB 以上，
  避免与业务模块在 0 附近的 data 段、以及向下生长的栈重叠；`--initial-memory=4194304`
  （64 页）预留内存；`--no-entry` + `--export-dynamic` 导出全部符号。

### 2. 实现 13 个真实 `rt.*`

值模型沿用 perry 的 **NaN-boxing**（事实来源：`perry-runtime/src/value.rs` + 业务 wasm 导入段），
i64 里装 f64 位模式，高 16 位是标签：

| 值 | 编码 |
| --- | --- |
| `undefined` / `null` / `false` / `true` | `0x7FFC…0001` ~ `0x7FFC…0004` |
| 字符串 | 高 16 位 `0x7FFF`，低 32 位是字符串表 id |
| 对象/数组/闭包（handle） | 高 16 位 `0x7FFD`，低 32 位是 handle id |
| int32 快路径 | 高 16 位 `0x7FFE` |
| 其他 | 普通 double 位模式 |

内部 `V` 枚举（`Undefined/Null/Bool/Num/Str/Handle`）只存在于 Rust 侧，`decode(bits)` /
`encode(v)` 负责与 i64 位模式互转——**i64 标签不是 `V::Str=1/Numb=2/Bool=3` 那种小整数**，
是 NaN-boxing 的高 16 位标签。

字符串 intern 表（`MAX_STRINGS=1024` 条、`ARENA_SIZE=64 KiB`）：

```rust
struct Entry { ptr: u32, len: u32, utf16: u32 }   // utf16 = JS length 的 UTF-16 码元数
```

- `intern_bytes(src, len)`：把业务模块线性内存里的字节拷进 arena 并登记，返回 id。
- `utf16_len`：UTF-8 字节 → UTF-16 码元数（非 BMP 码点算 2），供 `string_len` 用。
- 溢出（表满/arena 满）直接 `fatal`。

输出走 WASI，运行时模块自己不带 libc：

```rust
#[link(wasm_import_module = "wasi_snapshot_preview1")]
extern "C" { fn fd_write(fd: i32, iovs: *const Iovec, iovs_len: usize, nwritten: *mut usize) -> i32; }
```

- `write_fd(fd, bytes)` → `fd_write`；`fatal(msg)` 写 stderr `Exception: …` 后 trap。
- `perry_rt_unimplemented(name, len)`：写 `Exception: bridge function 'xxx' is not implemented`
  后 trap，供桩函数用（`not_implemented!` 宏）。

13 个导出（`#[export_name = "xxx"]` 裸名，直接对上业务模块的导入名）：

| 导出名 | 实现 | 用途 |
| --- | --- | --- |
| `string_new` | `rt_string_new(offset: u32, len: u32)` | 注册字符串字面量 |
| `console_log` / `console_warn` / `console_error` | `rt_console_*(value: i64)` | 打日志（fd 1/2） |
| `string_concat` | `rt_string_concat(lhs: i64, rhs: i64) -> i64` | 字符串拼接 |
| `js_add` | `rt_js_add(lhs: i64, rhs: i64) -> i64` | `+`（含字符串） |
| `string_eq` / `js_strict_eq` | `rt_*(lhs, rhs) -> i32` | 相等比较 |
| `is_truthy` | `rt_is_truthy(value: i64) -> i32` | 真值判断 |
| `string_len` | `rt_string_len(value: i64) -> i64` | `.length`（UTF-16 码元数） |
| `jsvalue_to_string` | `rt_jsvalue_to_string(value: i64) -> i64` | 转字符串 |
| `mem_call` | `rt_mem_call(name_id: f64, argc: f64, base: u32) -> f64` | 按名字动态分派 |
| `mem_call_i32` | `rt_mem_call_i32(...) -> i32` | 同上，结果直接 i32 返回 |

动态分派：`BRIDGES` 常量表（10 个名字）按下标匹配，参数以 u64 槽位写在业务线性内存
`base` 处（`mem_ptr::<u64>(base + i*8)` 读 `u64::from_le`），结果写回 `base`；查不到名字
就走 `perry_rt_unimplemented` 路径。另外导出 `_initialize`（reactor 入口，WAMR 把带 WASI
导入的模块分 command/reactor 两类，reactor 必须导出它，这里无事可做）。

### 3. `tools/gen-rt-symbols.mjs`

从 `build/app.wasm` 的导入段收集 `rt` 命名空间符号（uleb 手写解析 types/imports），
逐个判定：源文件（`runtime-wasm/src/lib.rs`）里已定义 `rt_<名字>(` 的实现只登记进符号表，
其余生成桩。当前产物：

```
build/rt_symbols.rs: 211 个 rt 导入 (已实现 13, 桩 198)
```

生成的桩长这样（`lib.rs` 末尾 `include!("../../build/rt_symbols.rs")` 引入）：

```rust
#[export_name = "array_new"]
pub extern "C" fn stub_array_new(_p0: i64) -> i64 {
    not_implemented!("array_new")
}
```

关键设计：**这是编译期就定死的桩函数，不是运行时查表**——wasm 链接是声明级的，211 个导入
必须全部有主；桩被调用时写 stderr 实名报错后 trap，绝不静默返回假数据。

### 4. `tools/patch-app-memory.mjs`

WASM 多模块链接里，同一块线性内存只能有一个定义者。perry 产出的业务模块自带
`memory`（2 页起），脚本把它改成"向运行时模块借内存"：

- import 段追加一条 `rt.memory`（kind=2，默认 min=1 页）；
- memory 段整个删掉（改由运行时模块提供）。

关键点：memory/table 的 import 不占函数索引空间，所以业务模块 code 段里的函数索引、
隐式 memory 0 引用全部不用动。输出 `build/app_link.wasm`。

### 5. `host/perry_link.c`

WAMR 多模块 runner（链接 `libiwasm.a`，编出 `build/perry_link`）。整个 main 只做四件事：

1. `wasm_runtime_load(rt.wasm)` → `wasm_runtime_register_module("rt", rt)`：
   业务模块的 212 个导入（211 函数 + memory）按这个名字解析；
2. `wasm_runtime_set_wasi_args(rt, …)`：rt 用 `fd_write` 打日志，WASI 落到 stdio；
3. `wasm_runtime_load(app_link.wasm)` → `wasm_runtime_instantiate`：
   WAMR 一并实例化它依赖的 `rt` 模块并完成符号/内存链接；
4. `wasm_application_execute_main` 跑 `_start`。

**没有任何一行 `rt.*` 的实现**——这是和路线一最本质的区别。

### 6. 集成 `demo.sh`（6 步）

| 步 | 内容 |
| --- | --- |
| 1/6 | 依赖：`@typerry/node`（napi 绑定）、`wasm32-unknown-unknown` target、WAMR iwasm 2.4.3（开 MULTI_MODULE） |
| 2/6 | TS → `build/app.wasm`；同一份源码走 perry 自带 JS 宿主层 → `build/ref.out` 参照输出 |
| 3/6 | `gen-rt-symbols.mjs` 生成桩表 → `cargo build` → `build/rt.wasm` |
| 4/6 | `patch-app-memory.mjs` → `build/app_link.wasm`；`gcc` 编 `build/perry_link` |
| 5/6 | 跑 `perry_link`，与 `ref.out` 逐字节比对 |
| 6/6 | 负向：数组程序应报未实现且退出码非 0 |

## 踩坑实录

### 坑 1：wasm-abis / u64 参数签名不匹配〔[INFERENCE]〕

- **现象**：早期实现里 `rt.string_new` 按 `u32,u32` 声明，但业务模块导入签名是
  `(i32,i32)`，跨边界参数对不上。
- **用户记录**：需要开 `wasm-abis=3` 让 u64/i64 按 i32 ABI 导出。
- **现状**：仓库里没有任何 `wasm-abis` 痕迹；`.cargo/config.toml` 只有
  `--global-base`/`--initial-memory`/`--no-entry`/`--export-dynamic`，当前构建 6/6 PASS。
  签名对齐靠 Rust 类型本身：`string_new` 用 `u32`，其余桥接函数用 `i64` 传 NaN-boxed 值。

### 坑 2：`#[no_mangle]` 符号从 cdylib 导出表消失

- **现象**：`perry_rt_unimplemented` 在产物里找不到，桩调用链接失败。
- **根因**：Rust ≥1.70 起 cdylib 只导出 `pub` 的 `#[no_mangle]` 符号；非 `pub` 的被排除。
- **修法**：`#[no_mangle] pub extern "C" fn perry_rt_unimplemented`（桩函数同理用
  `#[export_name] pub extern "C"`）。

### 坑 3：`failed to link import memory (rt, memory)`

- **现象**：实例化报 `failed to link import memory (rt, memory)`、退出码 1。
- **根因**：业务模块 import 的 memory `min` 页数超过 WAMR 对运行时模块记录的有效初始页数。
  `rt.wasm` 经 `--initial-memory=4194304` 声明 64 页，但 WAMR 收缩记录后只接受 min=1。
- **实测边界**：min=1 能过；min=2 ~ 100（含 17/18/64）**全部失败**。
- **修法**：`patch-app-memory.mjs` 默认 `min=1`，不再加大。

### 坑 4：`initializing thread failed!`〔条件性，未复现〕

- **现象**（用户记录）：报 `initializing thread failed!`。
- **根因**（用户记录）：`wasm_runtime_set_wasi_args` 在 `wasm_runtime_load` 之后调用。
- **现状**：`perry_link.c` 的顺序是 load rt → register → set_wasi_args → load app →
  instantiate（set 在 load 之后），6/6 PASS；实测把 set 移到 instantiate 之后、甚至去掉，
  当前构建都正常。此坑依赖 WASI 线程支持的构建路径，本 demo 的 WAMR 2.4.3 构建未开该选项，
  未复现。

### 坑 5：`_start` 双重初始化 / 尾部多余空行

- **现象**：跑完输出后尾部出现多余空行，或初始化动作执行了两遍。
- **根因**：`execute_func("_start")` 与 `wasm_application_execute_main` 的差异。
- **修法**：统一用 `wasm_application_execute_main(app_inst, 0, NULL)`（`perry_link.c` 现状）。

### 坑 6：lib.rs 调试清理残留两个孤立 `}`〔用户记录〕

- **现象**：编译报多余右花括号（用户记录约在第 430–431 行）。
- **修法**：删除残留。现文件该位置是分隔注释与 `string_new`，已无残留。

### 坑 7：sed 多行插入破坏结构

- **现象**：用 shell `sed` 做多行插入时 `\n` 转义被吃掉，插进去的内容把函数体拆散。
- **修法**：改用 python 脚本做精确字符串替换（`str.replace` + 断言锚点存在），
  之后所有对生成文件的机械修改都走脚本，不再手写 sed 多行。

## 最终验证

```
== 1/6 依赖 ==
== 2/6 perry: TypeScript → build/app.wasm (+ JS 宿主层参照) ==
== 3/6 运行时: rt.* 桩表 + cargo build → build/rt.wasm ==
== 4/6 链接: 业务模块 import rt.memory + 编宿主 runner ==
== 5/6 运行: Rust 运行时模块 (WAMR 多模块) vs perry JS 宿主层 ==
PASS: 两边输出完全一致
== 6/6 负向: 用数组的 TS 程序应当报未实现 ==
PASS: 未实现的功能被立刻报错 (退出码 1)
```

正向输出（5 行，逐字节一致）：

```
fib(0..19) sum = 10945
Hello, WAMR!
msg.length = 12
string compare ok
template: Hello, WAMR! (sum=10945)
```

负向输出（退出码 1）：

```
Exception: bridge function 'array_new' is not implemented
execute _start: Exception: unreachable
```

## 产物尺寸表

| 文件 | 字节 |
| --- | --- |
| `build/app.wasm` | 10650 |
| `build/app_link.wasm` | 10658 |
| `build/rt.wasm` | 16798 |
| `build/perry_link`（宿主 runner） | 531336 |
| `runtime-wasm/src/lib.rs` | 620 行 |

## 现状与限制

- **运行时是子集**：13 个导出覆盖 string（new/len/eq/concat/to_string）、number/bool
  （NaN-boxing 值）、plus、console（log/warn/error）、动态分派（mem_call/i32）。正向用例
  （fib、字符串、模板字符串）全部覆盖。
- **未实现即报错**：`array_*`/`json_*`/`fmt_*`/`object_*` 等 198 个导入由编译期生成的
  桩函数拦截，写 stderr `bridge function 'xxx' is not implemented` 后 trap，绝不静默。
- **这是 demo，不是生产运行时**：wasm 链接是声明级的，211 个导入必须全部有主；
  完整 JS 语义（对象、原型链、闭包、GC、异步）要补的量级仍是重写 `perry-runtime`。
- **环境约束**：WAMR 2.4.3，构建需 `WAMR_BUILD_MULTI_MODULE=1`（多模块链接）、
  `WAMR_BUILD_LIBC_WASI=1`（fd_write）、`WAMR_BUILD_TARGET=X86_64`。
- **扩展路径**：在 `runtime-wasm/src/lib.rs` 里实现新函数（如 `rt_array_new`），重跑
  `tools/gen-rt-symbols.mjs`，新函数自动从桩变成实现，无需手工登记。

## 优化采纳（2026-09-19）

归因分析（见 `docs/performance.md`）确认 A 路（WAMR 解释器）4010 ms 里约 79× 是
codegen 桥调用形态因子，其中桥实现低效——`invoke()` 对 10 项 `BRIDGES` 按名线性
memcmp——占 43%。实验版 `tools/attribution/rt_fast/lib.rs` 验证了 nameId→桥索引
缓存直查（A 路 4010 → 2292 ms，−43%），当日由用户裁决采纳进正式产物。

改动点（仅 `runtime-wasm/src/lib.rs`，最小 diff）：

- 新增 `static mut NAME_CACHE: [u8; 64]`（0xFF = 未缓存）。
- `invoke()` 在参数填充后加 nameId < 64 的缓存直查 fast path；按名扫描命中时回填缓存。
- 头注释加一行优化说明。产物尺寸 16798 → 16928 B（+130 B）。

实测前后对比（`./tools/bench.sh`，同机同口径）：

| 指标 | 优化前 | 优化后 |
|---|---:|---:|
| A 路 P50 | 4009.746 ms | 2470.678 ms（−38%） |
| A 路最小/最大 | 3866.041 / 4499.434 | 2378.375 / 2527.101 |
| codegen 因子（÷ A' 50.8 ms） | ~79× | ~49× |
| 总倍数（÷ 原生） | 2726× | 1757× |
| A 冷启动 real / INIT_MS | 7836 / 6.728 ms | 4879 / 6.883 ms |
| B 路 P50 / C 路 P50 | 1239 / 1.471 ms | 1280 / 1.406 ms（B/C 不变，对照价值） |

验收：`./demo.sh` 6/6 全 PASS（含负向 `array_new` 报错、三路/两路输出逐字节 diff），
`./tools/bench.sh` 三路输出一致校验 PASS。重测值与实验值 2292 ms 偏差 +7.8%，
在机器噪声内（同批 A' 干净基线也散布 50.8–58.8 ms）。

## 增补 D 路：perry 原生后端对照（2026-09-19）

用户指出 perry 的主打卖点就是编译成原生代码，"wasm 比 perry 原生慢多少"这一最关键
问题必须量化，基准从三路扩为四路。新增：

- `tools/attribution/bench_perry_wrap.c` — D 路计时包装（fork/exec + waitpid，
  CLOCK_MONOTONIC）。perry 产物无多轮入口且单次 ~6 ms 低于 bash time 分辨率，
  进程级计时是唯一口径；空载 fork+exec 基线 0.568 ms 已实测计入。
- `tools/attribution/bench_d.sh` — D 路一键复现（下载 → sha256 校验 → 编译 →
  正确性 → 计时取 P50）。perry 编译器 v0.5.1520 预编译包装在 /tmp/perry-dist，
  不入项目目录（.gitignore 已覆盖 .deps/，/tmp 天然在外）。

结果（详见 `docs/performance.md` "D 路"小节）：`perry compile src/bench.ts` 1.9 s
出 16.3 MB 原生可执行，P50 6.286 ms（进程级），为手写 C 基线的 4.5×——同一量级，
差距主因是 fib 无 gcc 式自内联（callgrind：D 21.7 M Ir vs C 34.1 M Ir，D 指令更少
但含 1,664,079 次真实 call/栈帧）与 TS number 的 f64 语义。四路对照：
A wasm×WAMR 2470.678 ms（÷D = 393×）、B node V8 1280.000 ms（÷D = 204×）、
C 原生 1.406 ms、D perry 原生 6.286 ms。perry 两条后端差 ~393×，原生卖点成立。

验收：D 路输出与 A/B/C 逐字节一致（`fib(29) = 514229`、`sum = 499999500000`）；
四批复测 P50 散布 ±6%。未动 A/B/C 任何代码与口径。

## 增补 E 路：WAMR AOT 对照（2026-09-19）

用户裁决：A 路数据（解释器 2470.7 ms vs perry 原生 6.3 ms）不公平——解释器不是
wasm 的性能形态，必须开 WAMR AOT 重测。增补内容：

- **运行时**：`build/wamr-aot-build/`（demo.sh 的 cmake 参数 + `WAMR_BUILD_AOT=1`
  + `WAMR_BUILD_WITH_CUSTOM_LLVM=1`，系统 LLVM 14）。wamrc（AOT 编译器）单独构建：
  `cmake -S .deps/wamr/wamr-compiler -B /tmp/wamrc-test -DWAMR_BUILD_WITH_CUSTOM_LLVM=1`
  + `cmake --build`——wamrc 只需 LLVM 的 x86_64 后端（wasm→机器码走 WAMR 自研后端），
  系统 `llvm-14-dev` 即可，无需 README 推荐的 build_llvm.sh 自编全量 LLVM。
- **关键发现：WAMR AOT 文件格式不支持 import memory**。`core/iwasm/compilation/
  aot_emit_aot_file.c` 硬编码 `import_memory_count = 0`（TODO 注释），加载时
  `aot_validator.c` 直接拒绝（"import memory is not supported"）。而 demo 双模块
  结构是 app import rt.memory，因此 **app.aot + rt.aot 双 AOT 不可行**（运行即
  "out of bounds memory access"）；iwasm CLI 下 app.wasm + rt.aot 混载能跑
  （AOT 子模块自身不 import memory），但业务代码仍被解释，无性能意义。可行方案：
  **wasm-merge（binaryen）合并 app+rt 成单模块再 wamrc**。合并后两个坑，由
  `tools/attribution/patch_merged.mjs` 后处理解决：删 rt 侧 `__data_end`/`__heap_base`
  导出（与 app 栈指针组合成非法 aux stack，"auxiliary stack underflow"）；织入
  `_start` wrapper 先调 `_initialize`（合并后无人调用）。
- **工具**：`tools/attribution/aot_time.c`（仿 bench_time.c，链接 AOT 构建的
  libiwasm.a）；`tools/attribution/aot_e.sh` 一键复现。

结果（详见 `docs/performance.md` "E 路"小节）：E P50 146.829 ms（16.8× 提速），
E' 干净 wasm × AOT 1.362 ms **与原生同速**（0.97×）。归因闭合：0.97× × 108×
= 104.4× ✓。引擎因子 35×→1×，codegen 桥因子 49×→108×（分母定义变化，见文档），
perry 两后端差距 393×→23×，且 23× 几乎全是 codegen 桥形态。

验收：E/E' 输出与各路逐字节一致（`fib(29) = 514229`、`sum = 499999500000`）；
aot_e.sh 端到端 PASS。未动 A–D 任何代码与口径；demo.sh、host/*、runtime-wasm/*、
tools/bench* 均未改动。

## 审计：C/D/E 差距取证 + 第一性原理分解 + QuickJS F 路（2026-09-21）

用户质疑三处：E 路（WAMR AOT）合并单模块是否引入成本、B'（V8）4.9 ms 是否被启动
污染、D 6.286 ms 口径；并追加第一性原理质疑"perry 原生与 perry→wasm→AOT 都经
LLVM 级优化，23× 不应如此大"；新增 QuickJS 对照需求。取证全部本次复现，详见
`docs/performance.md`"审计"节。过程要点：

1. **B' 复测**：`tools/attribution/run_node_steady.mjs` 阶梯预热（0/25/100/500/
   2000 次）发现 V8 默认跑法 tier-up 未充分（稳态 4.671 ms ≈ 文档 4.9）；强制
   TurboFan（`node --no-liftoff`）3.400 ms 是 V8 真优，纯 Liftoff 9.482 ms。
   "稳态 1.3 ms"假设证伪；V8 引擎因子修正 3.3×→2.5×，B 路分解 253×→364×，
   乘积校验 910 闭合（误差 <0.1%）。
2. **合并对照**：解释器跑同一合并模块（bench_merged_patched.wasm）进程级
   2340–2390 ms vs 双模块 2372–2480 ms——合并无额外成本，E 未被高估。
   callgrind 不可用于解释器构建（含 wrgsbase 指令，VEX 3.18 未实现 → SIGILL；
   也解释了 AOT 路 callgrind 崩溃），改用 wall-time 对照。
3. **wamrc 优化级**：`wamrc --help` 确认默认 opt-level=3；O0 对照 E 390.8 vs
   O3 141.4 ms、E' 4.0 vs 1.4 ms——E 已最优。
4. **第一性原理决定性实验**（tools/attribution/nohost_box_app.wat）：
   - nohost 直接调用（平凡被调方，LLVM 内联吸收）：1.371 ms ≈ fib 纯机 1.309 ms
   - nohost call_indirect + 最简装箱往返：5.913 ms（税 4.604 ms，1.4 ns/桥）
   - E 141.4 ms − 5.9 ms = 135.5 ms 是 rt 侧 mem_call 函数体（25.4 ns/桥），
     占 E 的 95.8% → **23× 是"类型化 IR vs 类型擦除装箱字节码"的差距，
     不是优化器差距；唯一收敛路径是 perry-codegen-wasm 类型特化**。
5. **D 纯执行**：callgrind 21.73 M Ir 减动态链接 2.29 M = 19.44 M 纯执行 Ir
   → 1.6–2.6 ms（IPC 3.8/2.5 两档）；D/C 纯执行 1.2–1.9×；E/D 纯执行 54–88×
   （23× 是 E vs D 进程级口径）。
6. **F 路 QuickJS**：Bellard quickjs（/tmp/quickjs-bellard，不入项目目录）跑
   `tools/attribution/bench_quickjs.js`（同算法同输出），`bench_exec_wrap.c`
   进程级计时（bench_perry_wrap 不支持 argv，新增通用版），P50 85.532 ms
   （fib 61.7 + loop 24.8 拆分闭合）。**F 比 E 快 0.58×**——纯解释器跑同算法
   比 AOT 执行 perry 装箱字节码还快，E 路慢与引擎无关的最强旁证。
   F/C ≈ 61×、F/D ≈ 14×、F/A ≈ 0.035×（快 29×）、F/B' ≈ 18×。

验收：E 闭合 1.309+4.604+135.5 ≈ 141.4 vs 实测 141.382（误差 <0.1%）；F 拆分
61.7+24.8 ≈ 86.5 ≈ 85.5 全量（含启动差 ~1 ms）；F 输出逐字节一致
（fib(29) = 514229 / sum = 499999500000）。未动 host/*、runtime-wasm/*、
tools/bench*、demo.sh、src/* 等禁区；docs/performance.md 修正 B' 相关数字并追加
审计小节，docs/process.md 仅追加本节；新增文件均在 tools/attribution/。

## 调查：perry-codegen-wasm 修复方案（2026-09-21）

**动机**：审计已证 E 路（wasm×WAMR AOT）与 E'（干净 wasm×AOT）差 ~108×，瓶颈是
perry-codegen-wasm 的桥调用形态（`+`→`mem_call js_add`、条件→`mem_call_i32
is_truthy`，每层 fib 2 次桥）。需要量化"怎么修、修到多少"。

**实验 A（wasm-opt 纯后处理）**：对 `build/bench_merged_patched.wasm` 跑
wasm-opt 123（`--inlining-optimizing --always-inline-max-function-size=5000
--precompute-propagate --dce`）。能内联（整条 mem_call+invoke 进 fib/loop，
wasm-dis 确认 call $142/$143 全消失），**不能折叠分派**——br_table 索引来自
NAME_CACHE 的运行时内存 load，binaryen 无内存常量传播，11 路 switch + miss 路径
留在内联体里。P50 122.1 → 93.5 ms（-23%，输出逐字节一致）。

**实验 B（等价手工类型特化）**：对 perry 原样 wat 只改热路径——`+` 内联
`f64.add`（B1，保留 is_truthy 桥）→ 71.6 ms；再内联 is_truthy 为 `i64.ne` 假盒
比较（B2，NaN-box + 影子栈纪律保留）→ **17.2 ms（快 7.1×）**；纯 f64 无盒无
影子栈（V3）→ 3.3 ms；E' 同批 1.2 ms。分解：E−B2 ≈ 105 ms 是桥本体，
B2−E' ≈ 16 ms 是影子栈内存纪律（非 NaN-box 税，reinterpret 对机器码空操作
[INFERENCE]）。B2 即"codegen 类型特化（保留现有值表示与调用纪律）"的上限。

**结论**：推荐 **codegen 类型特化**为主线（发射点分支 + HIR 类型环境
`value_types.rs:222,551,1649` 现成，类型不证回退原桥；实测 7.1×）；wasm-opt
后处理作零上游依赖过渡（-23%）；桥侧微优化余量小；typed ABI 化（去影子栈）为
远期。落地顺序 2→3→4。方案表全文见 docs/performance.md「修复路径与天花板」节。

新增文件（均在 tools/attribution/）：`exp_wasmopt.sh`、`spec_patch.py`、
`exp_specialize.sh`、`specialized_bench_f64.wat`；docs/performance.md 仅追加新节。
未动 host/*、runtime-wasm/*、tools/bench*、tools/build-wasm.mjs、demo.sh、
src/bench.ts 等禁区；未 commit。

## 规划：路径 4 typed ABI 化（2026-09-21）

**动机**：路径 3（codegen 类型特化，B2=17.2 ms、快 7.1×）已证桥本体可消灭，
但 B2→E' 的 16 ms 影子栈内存纪律（值经 global sp 存/取内存）仍在，wasm 路仍比
原生慢 14×。用户裁决路径 4：把 perry-codegen-wasm 并入 typed ABI 体系（仿原生
`codegen/typed_abi.rs`），让 wasm 路与 perry 原生同数量级（V3 锚 3.3 ms vs 原生
纯执行 1.6–2.6 ms，1.3–2.1×）。

**阶段表**：

| 阶段 | 改什么 | 验收 P50 | 人日 |
|---|---|---:|---|
| 0 装配 HIR 类型环境 | `HirTypeEnv::from_module` 挂 WasmModuleEmitter | ~122（无回归） | 0.5–1 |
| 1 发射点特化（`+`/条件内联）= 路径 3 完整 | 锚定 B2 | ~17.2 | 2–4 |
| 2 字面量/局部 typed | INT32_TAG 0x7FFE + 局部 widening | ~12–17 [INFERENCE] | 2–4 |
| 3 签名 typed + trampoline + 拒绝制 | 仿 typed_abi，本基准直接收益近零（基础设施） | ~12–17 [INFERENCE] | 4–7 |
| 4 去影子栈 | typed 函数溢出改 local | ~3.3–5.0（V3 锚） | 4–8 |
| 5 rt 桥 typed 重载双轨 | runtime-wasm/lib.rs + wasm_runtime.js 同步 | ~3.3 | 3–6 |

合计 ~16–30 人日（一人约 3–6 周）。里程碑：M1（阶段 1 后=B2，可发布）、M2（阶段 4
后=V3，可发布）。每阶段保留 i64/NaN-box 回退，任一阶段可独立合入、输出逐字节一致。
关键非显见结论：阶段 2/3 对本基准（fib 已注解 + 已直接 Call + 已内联算术）直接
收益近零，是阶段 4 的前置基础设施；14 ms 跃迁在阶段 4。风险 Top3：JS truthiness
边角（number 条件回退 is_truthy）、去影子栈横切改动面（停在阶段 3 仍 7.1× 可发布）、
trampoline 开销与 wamrc 内联不可控。

完整规划文档：`docs/typed-abi-migration.md`（目标/现状/阶段/验收/风险/工作量/上游
行号索引）。全部 file:line 已对 `/tmp/perry-src` HEAD `7ac11b09` 逐行复核。未动
host/*、runtime-wasm/*、tools/bench*.c/sh、tools/gen-rt-symbols.mjs、
tools/patch-app-memory.mjs、tools/build-wasm.mjs、demo.sh、src/*、docs/*.md（仅
新增 typed-abi-migration.md + 本节）；未 commit。

## 后处理 pass：通用桥内联（2026-09-21）

**动机**：路径 3（codegen 类型特化）与实验 B（手工特化 B2=17.2 ms）都证明"桥本体可
消灭"，但 B2 靠人读 `src/bench.ts` 才知道哪两侧是 number——**类型知识在 perry 产物里
已被擦除**，手工特化只是上界估计器。本轮验证"同一变换能否自动化成通用后处理器"。

**做了什么**：`tools/attribution/bridge_inline_pass.mjs`（wat→wat，零上游依赖）。
对 `patch_merged` 之后的合并 wat 做抽象解释恢复类型（值域 NUM/BOOLBOX/OTHER，含跨过程
参数/返回值不动点），把可证 number 的 `js_add` 桥内联成 `f64.add`、可证是二值盒布尔的
`is_truthy` 桥内联成 `i64.ne TAG_FALSE`，其余桥原样保留。接在既有 E 路链路的
`patch_merged` 与 `wasm-as` 之间，构建链只多一行。

**实测（同批，6 进程 × 2 轮 = 12 样本，弃首取中位）**：

| 程序 | 形态 | base | pass | pass(cw) | 桥内联率 |
|---|---|---:|---:|---:|---:|
| `src/bench.ts` | 纯 number 热循环 | 123.098 | **16.958** | 16.822 | 40% |
| `probe_str.ts` | 字符串密集 | 30.297 | 14.942 | 14.340 | 45% |
| `probe_mixed.ts` | number/string 混用 | 21.261 | 5.918 | 5.861 | 43% |
| `probe_nested.ts` | 跨函数 | 0.521 | 0.280 | **0.044** | 43% / 86%(cw) |

**28/28 逐字节一致**（4 程序 × 7 变体，参照 perry JS 宿主层 `wasmBoot`），**零误判**。
bench 达 **7.3×**，与手工特化上界 B2=17.2 ms 同级；wasm-opt 叠加仅再 −5%，
`--enable-segue` 在桥消失后无收益（反向）。结论：**不改 perry 上游可把 122 ms 拉到
≤20 ms 量级**，最小手段就是这个 pass，代价 ~10 h [INFERENCE] + 随 perry 版本回归的风险。

**边界（如实记录）**：① 覆盖率在混合/字符串程序上**不骤降但也不高**（40–45%）——
拒绝的正是"本该走桥"的字符串 `+`、`===`、`console_log`，这是设计而非缺陷；
② 跨函数程序在保守模式下只有 43%，因为 perry 导出每个用户函数、pass 无法排除"宿主
用字符串调它"；合并后的 AOT 模块实际封闭（只有 `_start` 入口），`--closed-world`
显式声明后升到 86%；③ **永久劣势**：pass 依赖 perry 产物指令形态，perry 升级 codegen
（路径 3 落地）即可能失配，需随版本回归。

**开关路线已排除**（另一 worker 侦察）：perry CLI / `@typerry/node` / 环境变量对
wasm codegen **零影响**（所有变体字节相同）；wamrc 唯一有效开关 `--enable-segue`
−18.3%（122.14→99.84 ms），仍 71× 于原生。

一键复现：`tools/attribution/exp_postpass.sh all`（产出 `build/postpass/`，
P50 汇总 `build/postpass/p50.txt`）。新增文件：`bridge_inline_pass.mjs`、
`exp_postpass.sh`、`probe_ref.mjs`、`probes/probe_{str,mixed,nested}.ts`；
docs/performance.md 仅追加新节。未动 host/*、runtime-wasm/*、tools/bench*.c/sh、
tools/gen-rt-symbols.mjs、tools/patch-app-memory.mjs、tools/build-wasm.mjs、demo.sh、
src/*、docs/perry-wasm-wamr.md、docs/typed-abi-migration.md；未 commit。

## 上游 patch：codegen 发射点特化（2026-09-21）

在 vendored perry 源码区（`/tmp/typerry-src/perry`，commit `87ecb02b`）直接
patch `crates/perry-codegen-wasm`，让可静态证明的 number `+` 与二值布尔条件
在**发射点**内联成原生 wasm 指令，不走动态分派桥。

### 步骤

1. 取得源码：直连 `git clone` / `git fetch` 该 commit 反复失败（网络断开、signal 9），
   改用 GitHub codeload tarball（`codeload.github.com/PerryTS/perry/tar.gz/<sha>`）
   解压到 `/tmp/typerry-src/perry`，`git init` 建基线 commit（`b4fef3e`）以便出 diff。
2. 写 patch（`tools/attribution/codegen_specialize.patch`，新文件
   `src/emit/type_facts.rs` + 5 处既有文件改动）：设计见
   `tools/attribution/patch_notes.md`。
3. `cargo check -p perry-codegen-wasm` 迭代修编译错误（Module 名冲突、借用冲突、
   漏 import）。
4. 构建绑定：`cd /tmp/typerry-src && cargo build --release --no-default-features
   --features napi`（前置 `node extract.js` 生成 `runtime.js`）→
   `target/release/libtyperry.so`。
5. 替换 `node_modules/@typerry/node-linux-x64-gnu/typerry.linux-x64-gnu.node`
   （原绑定备份 `/tmp/typerry.node.orig`，基线构建版备份
   `/tmp/typerry.node.baseline`）。
6. 正确性：`./demo.sh` 6/6（含负向 array_new）；3 探针输出与 perry JS 宿主层参照
   逐字节一致。
7. 性能：重建 E 路前置（`build-wasm.mjs src/bench.ts --bare` → `gen-rt-symbols.mjs`
   → `cargo build runtime-wasm` → `patch-app-memory.mjs`）→ `tools/attribution/aot_e.sh 12`。

### 结果

- P50：**122.1 ms → 3.891 ms（快 31.4×）**，超过 17 ms 目标 4.4×，逼近纯 f64 的
  V3（3.3 ms）。
- 反汇编：`--bare` 产物 `mem_call_i32`（is_truthy）2 → 0、`mem_call`（js_add）8 → 6
  （剩余全是字符串拼接）、`f64.add` 0 → 3、`i64.ne` 0 → 2。
- 后处理 pass（`bridge_inline_pass.mjs`）可退役（同一目标，源头修更优）。

### 约束遵守

只改 `/tmp/typerry-src/perry`（上游实验区，未 commit）与本仓新增
`tools/attribution/codegen_specialize.patch`、`tools/attribution/patch_notes.md`
及本节/`docs/performance.md` 追加；未动 host/、runtime-wasm/、src/、demo.sh、
tools/bench*、tools/bridge_inline_pass.mjs 等。

## 增补：性能测试迁移到 CI（2026-09-21）

**动机**：六路基准此前只在本机 PVE 虚拟机（Ryzen 7 5800H）复现，没有独立于个人机器的
可复现基线；每次跑要手工装 WAMR（解释器 + AOT 双构建）、wamrc、QuickJS、625 MB perry
下载。迁到 GitHub Actions 让基准可重放、结果可上传 artifact、并有跨机器不失效的回归判定。

**做了什么**：

1. 新增 `.github/workflows/bench.yml`（ubuntu-22.04，`timeout-minutes: 60`）。
2. 新增 `tools/ci/collect-bench.mjs`：把 `build/{a,b,c,d,e,eprime,f}_runs.txt` 汇总成
   `build/bench-results.json`（中位数/最小/最大 + ÷C 倍数 + 与文档基线比率的 ±50% 判定
   + 环境快照），同时写 `build/bench_ci_table.txt`。

**设计决策**：

- runner 选 ubuntu-22.04：基线机是 22.04 系（gcc 11.4.0）；LLVM 用 14（`llvm-14-dev`，
  `-DLLVM_DIR="$(llvm-config-14 --cmakedir)"` 消歧），与本机 wamrc 构建同版本。ubuntu-24.04
  默认 LLVM 18 虽在 WAMR 2.4.3 的 `#if LLVM_VERSION_MAJOR >= 19` 等守卫覆盖范围内，但
  `aot_e.sh` 硬编码 `-I/usr/lib/llvm-14/include`，22.04 是不改脚本的最小等价解。
- perry 下载用 `actions/cache` 缓存 625 MB 压缩包（key = 版本 + sha256）；缓存命中时
  先校验并解压成 `/tmp/perry-dist`，让 `bench_d.sh` 直接跳过下载分支（避免 `curl -C -`
  对已完整文件整包重下/416 空转重试，实测 GitHub 对续传完整文件返回 200 整包重下）。
- 回归判定用「÷C 倍数」而非绝对 ms（跨机不可比），±50% 内 ok、超出仅 `::warning::`
  不 fail（共享 runner 噪声大）；首次运行即把本次倍数写入 JSON 的 `ci_baseline` 字段
  作为 CI 基线存档，之后可 `--baseline` 做 CI-vs-CI。
- 触发默认手动 `workflow_dispatch` + PR 打 `bench` 标签；不随 push 自动跑（单次 15~30
  分钟且高频率只能得到噪声基线）；需要夜间基线时启用 `on:` 里注释掉的 `schedule` 段。

**workflow 步骤 ↔ 本地命令对应表**：

| workflow 步骤 | 本地等价命令/脚本 |
|---|---|
| setup Node 24 + `npm install` | `demo.sh` 第 30 行 `npm install --no-audit --no-fund`（锁文件不入库 → 不用 npm ci） |
| Rust wasm32 target | `demo.sh` 第 43-45 行 `rustup target add wasm32-unknown-unknown` |
| apt: llvm-14-dev + wabt | wamrc/`aot_e.sh` 第 38-40 行需要的 LLVM14 头库；`aot_e.sh` 第 18 行 WABT 指向的 `wat2wasm` |
| perry 缓存 + 解压 | `bench_d.sh` 第 28-38 行下载/校验/解压分支的命中短路 |
| `./demo.sh` | `demo.sh` 全链路（WAMR 2.4.3 克隆 + 解释器构建 + app/rt + 正负向测试） |
| wamrc 构建 | docs/performance.md「E 手动步骤」`cmake -S .deps/wamr/wamr-compiler … -DWAMR_BUILD_WITH_CUSTOM_LLVM=1` + `cmake --build`（仅多 `-DLLVM_DIR`） |
| QuickJS | attribution/README.md：克隆 bellard/quickjs → `make qjs`（只建解释器） |
| WABT 注入 | `echo "WABT=$(command -v wat2wasm)" >> "$GITHUB_ENV"` |
| A/B/C | `tools/bench.sh` |
| D | `tools/attribution/bench_d.sh 11` |
| E/E' | `tools/attribution/aot_e.sh 12` |
| F | `tools/attribution/bench_f.sh 11` |
| 汇总+判定 | `node tools/ci/collect-bench.mjs` |
| 上传 artifact | `actions/upload-artifact@v4`（`if: always()`） |

**验证**：workflow 过 `python yaml.safe_load` + `actionlint`（v1.7.12，0 告警）；
`tools/ci/collect-bench.mjs` 用本机 `build/*_runs.txt` 实测，六路中位数/倍数与本机
docs 数值吻合（A 1751× / B 911× / D 4.5× / E' 0.89× / F 63× 量级）。无法真跑 CI
（无远端 push 权限/runner），等价性靠上述静态对应 + 复用同一脚本保证；未 commit。
