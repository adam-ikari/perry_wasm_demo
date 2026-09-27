# 上游 patch：perry-codegen-wasm 发射点特化（2026-09-21）

## 实验对象

- 源码：`/tmp/typerry-src/perry`（vendored perry，commit `87ecb02b`；typerry `d13b5769` 的 submodule）
- 目标 crate：`crates/perry-codegen-wasm`（wasm 后端，无 LLVM 依赖）
- patch 文件：`tools/attribution/codegen_specialize.patch`（`git -C /tmp/typerry-src/perry diff` 生成，6 文件 / +487 −20）
- 基线：`git -C /tmp/typerry-src/perry` 的 commit `b4fef3e`（tarball 解压后建立）

## 动机

wasm 后端把类型擦除：所有值 NaN-box 成 i64，`+` → `mem_call(js_add)` 动态分派、
if/while/for 条件 → `mem_call_i32(is_truthy)` 桥。bench（fib(29) + 10^6 循环）
每层递归 2 次桥调用，桥函数体占 E 路 95.8% 耗时（122 ms，见
`docs/paper/perry-wasm-paper.md` §6「两种修复与其验证」）。本 patch 在**发射点**做保守特化，
把可静态证明的 number `+` 与二值布尔条件直接内联成原生 wasm 指令。

## 改动清单（file:line，行号为 patch 后）

| 文件 | 位置 | 语义 |
|---|---|---|
| `src/emit/type_facts.rs`（**新文件**，419 行） | 全文 | 保守类型事实：收集声明类型 + 轻量数据流，提供 `expr_is_number`/`expr_is_boolean` |
| `src/emit/module_emitter.rs` | 字段 `type_facts` + `new()` 初始化 | `WasmModuleEmitter` 持有 per-module 类型事实表 |
| `src/emit/compile.rs` | `compile()` 开头 `:18-22` | 一次性构建 `type_facts`（`modules.iter().map(TypeFacts::from_module)`） |
| `src/emit/compile.rs` | globals init 循环 `:1319`、class 注册循环 `:1339` | 补 `self.current_mod_idx = mod_idx;`（原本缺，跨 module 会取错 TypeFacts） |
| `src/emit/expr/literals_vars.rs` | `BinaryOp::Add` 分支 `:178-196` | 两侧可证 number → 内联 `f64.add`；否则原桥 |
| `src/emit/stmt.rs` | if `:66-76`、while `:119-127`、do-while `:177-185`、for `:243-251` | 条件可证二值盒布尔 → `i64.ne TAG_FALSE`；否则原桥 |

## 逐处语义

### 1. `+`（`literals_vars.rs`）

```rust
if self.expr_is_number(left) && self.expr_is_number(right) {
    self.emit_expr(func, left);   F64ReinterpretI64;
    self.emit_expr(func, right);  F64ReinterpretI64;
    F64Add; I64ReinterpretF64;
} else { /* 原 emit_frame_begin(2)+store_arg×2+emit_memcall("js_add",2) */ }
```

**等价性**：perry 的 number 表示 = 裸 f64 位型（rt `encode(V::Num(n)) = n.to_bits()`）。
若运行时两侧确为 number，`js_add(Num(a), Num(b))` 返回 `Num(a+b)`；内联的
`i64.reinterpret_f64(f64.add(f64.reinterpret_i64(a), f64.reinterpret_i64(b)))`
逐位相同（含 NaN/±0/Inf 传播，f64 加法语义一致）。

**影子栈**：原路径 `emit_frame_begin(2)` 推 sp+16、`emit_memcall` 内收 sp−16，
净 0；特化路径完全不碰 sp（`emit_expr` 内若含调用，被调方自平衡）。净效果一致。

**字符串分支**：只有两侧**都可证** number 才内联，`string + anything` 恒走原桥，
JS `+` 的字符串拼接语义保留。

### 2. 条件（`stmt.rs` 4 处）

```rust
if self.expr_is_boolean(condition) {
    self.emit_expr(func, condition);          // 栈上盒布尔 i64
    I64Const(TAG_FALSE); I64Ne;               // → i32
} else { /* 原 emit_frame_begin(1)+store_arg+emit_memcall_i32("is_truthy",1) */ }
```

**等价性**：`expr_is_boolean` 只接受"恒产 TAG_TRUE/TAG_FALSE 二值盒布尔"的表达式
（`Expr::Bool`、`Expr::Compare`、`!x`、声明为 `Boolean` 的局部、返回布尔可证的调用）。
对这些值 `is_truthy(盒布尔) ≡ (v != TAG_FALSE)`（逐位等价；rt 的 truthy 对布尔即取标量）。
**number 条件保守回退**（0/−0/NaN 均 falsy，裸 i64 比较会误判）。

**影子栈**：同 Add，原路径 begin(1)+memcall 净 0，特化路径不碰 sp。

### 3. `type_facts.rs`（判据与数据流）

**number 判据**（`expr_is_number`）：`Number`/`Integer` 字面量；声明为
`Number`/`Int32` 的局部；`Update`（`++`/`--`）、`Unary Neg/Pos`、
`Binary Sub/Mul/Div`（这些 perry **无条件** f64 内联，产物恒 f64 位型，perry
自身已当 number 处理，不引入新假设）；返回类型声明为 number 的函数调用
（`FuncRef` callee，与原生后端 typed ABI 同样信任声明类型）；两侧都可证的 `+`（递归）。

**boolean 判据**（`expr_is_boolean`）：`Bool` 字面量；`Compare`（发射恒为
`If(Result I64)` 选 TAG_TRUE/TAG_FALSE）；`!x`；声明为 `Boolean` 的局部；返回布尔可证的调用。

**数据流补充**（关键：无注解 `let sum = 0` 才能证明）：无注解 `let x = <init>`
且 init 可证 number/boolean → x 进入候选；随后做**赋值敏感不动点**——x 的每个
赋值点 RHS 都必须可证同型才保留（`Update` 恒 number，不破坏 number 候选、
但会破坏 boolean 候选故拒绝）。从乐观初值单调递减，收敛后剩余候选在任意执行
路径上取值都可证同型。**被闭包捕获或函数 `captures` 捕获的 id 一律拒绝**
（跨函数流不可静态跟踪）；扫描用 perry-hir 的
`walker::walk_expr_children`（穷尽匹配，编译期强制覆盖所有 Expr 变体，不漏赋值点）。

## 安全性与回退

- **不误证的保证**：所有特化都经过保守静态证明；任何不可证处（字符串 `+`、
  number 条件、`&&`/`||` 结果、Mod/Pow 桥、不可证变量、闭包捕获、跨 module）**保留原桥**，行为与基线逐字节一致。
- **回退路径**：`expr_is_number`/`expr_is_boolean` 任一返回 false 即走原
  `emit_memcall("js_add")` / `emit_memcall_i32("is_truthy")`，影子栈增减逐指令不变。
- **trust-the-declaration**：沿用 perry 上游语义（原生 typed ABI 同样用
  `param.ty`/`return_type` 决定 typed clone）——类型注解视为程序员承诺。若源码
  绕过 TS 类型（`as any`），基线行为本身已不可靠，非本 patch 引入。
- **[INFERENCE]** `Integer` 字面量与 `Int32` 声明在 wasm 后端一律发射为 f64 位型
  （`f64_const` + `I64ReinterpretF64`），故可安全并入 number 判据——已从
  `literals_vars.rs` 的 `Expr::Integer` 发射路径确认。
- **[INFERENCE]** 影子栈净增减不变的论证基于 `emit_frame_begin`/`emit_memcall*`
  的 sp 配对（`memcall.rs` 的 save/advance/restore 注释），未逐指令仿真验证；
  但产物运行输出与参照逐字节一致（demo 6/6 + 3 探针）间接支持。

## 与后处理 pass 的关系

`tools/bridge_inline_pass.mjs`（零上游依赖的三格抽象后处理）与本 patch 目标重叠：
都内联 `js_add(number,number)` 与 `is_truthy(盒布尔)`。**本 patch 落地后后处理
pass 可退役**：codegen 发射点特化是"源头修"，指令序列更紧（消除了帧建立 +
内存槽往返，连影子栈纪律都不再产生），且不需要 wat 后处理的基础设施。

## 实测结果（同口径：`build/aot_time`，12 轮弃第 1 轮取 11 样本中位数）

| 变体 | P50 (ms) | 相对基线 E |
|---|---:|---:|
| E 基线（未 patch，perry 原样） | 122.112 | 1× |
| **本 patch（codegen 发射点特化）** | **3.891** | **0.0319×（快 31.4×）** |
| B2（手工等价特化，保留影子栈纪律） | 17.185 | 0.141× |
| V3（纯 f64，无盒无影子栈） | 3.325 | 0.027× |

本 patch 比手工 B2 快 4.4×、接近 V3 —— 因为 B2 只替换 `mem_call` 本身（保留
原帧建立/影子栈存取的指令），而 codegen 特化**整条帧建立 + 内存槽往返都不再发射**
（`[INFERENCE]`：这是 AOT 后端能更好优化的主因）。

正确性：`fib(29) = 514229`、`sum = 499999500000`；`./demo.sh` 6/6 PASS（含负向
array_new 报错）；3 个泛化探针（probe_str / probe_mixed / probe_nested）输出与
perry JS 宿主层参照**逐字节一致**。

## 反汇编证据

`--bare` 产物 `build/bench.wasm`（patch 前 vs 后，`wasm-dis`）：

| 指标 | 前 | 后 |
|---|---:|---:|
| 文件大小 | 9780 B | 9561 B |
| `call $mem_call`（js_add 等） | 8 | 6 |
| `call $mem_call_i32`（is_truthy） | 2 | 0 |
| `f64.add` | 0 | 3 |
| `i64.ne` | 0 | 2 |

fib 热路径：`if (n < 2)` 条件从 `mem_call_i32(is_truthy)` 变为 `i64.ne TAG_FALSE`；
`fib(n-1) + fib(n-2)` 与循环 `sum += i` 从 `mem_call(js_add)` 变为 `f64.add`。
剩余 6 处 `mem_call` 全是**字符串拼接**（`"fib(" + N_FIB + …`、`"sum = " + sum`）
——正符合"可证 number 才内联"的设计。

## 遗留风险

- 字符串 `+` 仍走桥（正确性所需；字符串密集程序无收益）。
- number 条件（`if (x)` x 是 number）保守回退（0/−0/NaN falsy 语义）。
- `Mod`/`Pow`（`js_mod`/`math_pow` 桥）、`Eq`/`Ne`（`js_strict_eq`/`js_loose_eq`）
  未特化。
- 类方法体/闭包体内的无注解局部不参与数据流补充（`TypeFacts::from_module` 只扫
  `module.functions` + `module.init`）→ 保守回退，无收益但无误判。
- 跨 module 函数返回值特化仅用本 module 声明（跨 module 导入函数的返回类型未接入）。
