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
