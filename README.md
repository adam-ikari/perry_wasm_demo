# perry → wasm + Rust 运行时模块（WAMR 多模块）

perry（typerry）把 TypeScript 编译成 wasm 业务模块；perry 的 `rt.*` 运行时用 Rust
（`runtime-wasm/`，`#![no_std]`）编译成独立的 wasm 模块；两个模块由 WAMR 的多模块机制
链接执行，宿主只剩 WASI（`wasi_snapshot_preview1.fd_write`）写 stdout/stderr。

```
src/app.ts ──perry──► build/app.wasm ──import rt.memory + 211 个 rt.*──► build/rt.wasm
                                                                    (Rust 运行时, 13 实现 + 198 桩)
                                     │ WAMR 多模块
                                     ▼
                            host/perry_link.c runner ──WASI fd_write──► stdout/stderr
```

## 目录结构

| 路径 | 作用 |
|---|---|
| `runtime-wasm/` | Rust `#![no_std]` 运行时：`Cargo.toml` + `src/lib.rs` + `.cargo/config.toml`（`--global-base=2097152` 避开业务模块低地址区）。`lib.rs` 通过 `include!("../../build/rt_symbols.rs")` 引入生成桩 |
| `host/perry_link.c` | WAMR runner：把 rt 模块注册进全局模块表，配 WASI，不实现任何 `rt.*` |
| `tools/gen-rt-symbols.mjs` | 解析 `app.wasm` 导入段，生成 `build/rt_symbols.rs`：211 个导入 → 已实现的 13 个只登记，其余 198 个生成"调用即报错"的桩 |
| `tools/patch-app-memory.mjs` | 把业务模块的 memory 段改成 `import rt.memory`（同一块线性内存只有一个定义者） |
| `demo.sh` | 一键 6 步演示（依赖 → 编译 → 链接 → 运行 → 比对 → 负向） |
| `src/app.ts` | 正向用例源码（fib / 字符串 / 模板字符串） |
| `docs/perry-wasm-wamr.md` | 原理与实现细节 |

## 快速开始

```bash
./demo.sh   # 6 步, 全 PASS
```

① 装依赖（`@typerry/node`、`wasm32-unknown-unknown`、WAMR iwasm 2.4.3：
`WAMR_BUILD_MULTI_MODULE=1`、`WAMR_BUILD_LIBC_WASI=1`、`WAMR_BUILD_TARGET=X86_64`）→
② TS 编译成 `build/app.wasm`（同源码走 perry JS 宿主层出参照输出）→ ③ 生成桩表，
`cargo build` 出 `build/rt.wasm` → ④ 业务模块改 import `rt.memory`，编宿主 runner →
⑤ 运行并与 JS 宿主层逐字节比对 → ⑥ 负向：数组程序报未实现且退出码非 0。

## 实测输出

正向（Rust 运行时模块 vs perry JS 宿主层，逐字节一致，5 行）：

```
fib(0..19) sum = 10945
Hello, WAMR!
msg.length = 12
string compare ok
template: Hello, WAMR! (sum=10945)
```

负向（数组程序，退出码 1）：

```
Exception: bridge function 'array_new' is not implemented
execute _start: Exception: unreachable
```

产物：`build/app.wasm` 10650 B、`build/app_link.wasm` 10658 B、`build/rt.wasm` 16798 B。

## 互操作约定

- **值编码**：i64 携带 NaN-boxing tag（源自 `perry-runtime/src/value.rs`）：String（id）/
  Numb / Bool / Undefined / Null 等，运行时 `decode`/`encode` 双向转换。
- **字符串 intern 表**：字符串体拷入 64 KiB arena 并登记（上限 1024 条），`string_new`
  返回 id，之后只传 id，避免跨模块传字节。
- **共享线性内存**：内存只有一块——rt 模块导出、业务模块 import（`patch-app-memory.mjs`
  改写）。`rt.*` 通过这块内存交换数据。
- **未实现即报错**：桩函数写 stderr `bridge function 'xxx' is not implemented` 后
  `unreachable()` trap，绝不静默返回。

## 约束

- 已实现 13 个 `rt.*`：`string_new`、`console_log/warn/error`、`string_concat`、`js_add`、
  `string_eq`、`js_strict_eq`、`is_truthy`、`string_len`、`jsvalue_to_string`、`mem_call`、
  `mem_call_i32`。
- 未覆盖的 `array_*`、`json_*`、`fmt_*`、`object_*` 等 198 个导入由编译期桩函数拦截报错。
- 这是演示项目，不是生产运行时：wasm 链接是"声明级"的，211 个导入必须全部有主，
  哪怕只用 3 个。

## 文档导航

- `docs/perry-wasm-wamr.md` — 架构原理与实施细节。
