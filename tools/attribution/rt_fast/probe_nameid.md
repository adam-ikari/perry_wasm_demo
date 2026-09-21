# nameId 语义取证记录

`wasm2wat --enable-all build/bench.wasm`（2026-09-19）后逐 `call 209/210` 解析
nameId（mem_call 第 1 参数，f64 位型的字符串表索引）与 argc。
解析脚本逻辑：每个 call 前最后两个 `f64.const`，先压 nameId、后压 argc
（`emit_memcall`：`f64_const(name_id)` → `f64_const(arg_count)` → base → call）。

## build/bench.wasm（src/bench.ts）

数据段字符串序（前缀 Authorization/POST/GET 占 0/1/2）：js_add=8、is_truthy=12、
console_log=4。

| 行号 | 调用 | nameId | argc | 语义 |
|---|---|---:|---:|---|
| 974 | call 210 (mem_call_i32) | 12 | 1 | is_truthy（fib 的 `n<2` 条件）|
| 1020 | call 209 | 8 | 2 | js_add（`fib(n-1)+fib(n-2)`）|
| 1077/1103/1131 | call 209 | 8 | 2 | js_add（字符串拼接 / 循环外）|
| 1152 | call 209 | 4 | 1 | console_log |
| 1193 | call 210 | 12 | 1 | is_truthy（循环条件 `i<N`）|
| 1224 | call 209 | 8 | 2 | js_add（`sum += i`）|
| 1274 | call 209 | 8 | 2 | js_add（`"sum = "+sum`）|
| 1295 | call 209 | 4 | 1 | console_log |

静态调用点合计：js_add ×5、is_truthy ×2、console_log ×2。执行期计数：
fib(29) 1,664,079 次调用 × (1 js_add + 1 is_truthy) + 循环 10^6 × (1 js_add + 1 is_truthy)
≈ 533 万次桥调用。

## build/app_check.wat（src/app.ts，普遍性验证）

| nameId | argc | 语义 | 静态次数 |
|---|---:|---|---:|
| 4 | 1 | console_log | 5 |
| 8 | 2 | js_add | 10 |
| 10 | 1 | string_len | 1 |
| 12 | 1 | is_truthy | 3 |
| 13 | 2 | string_eq | 1 |

与 bench.ts 相同形态：**加法与条件过桥，减法（n-1/n-2）内联 f64.sub**，
msg.length → string_len 桥（本来就该过）。

## codegen 证据链（GitHub PerryTS/perry main）

- `crates/perry-codegen-wasm/src/emit/expr/literals_vars.rs`：
  `BinaryOp::Add => emit_memcall(func, "js_add", 2)`，注释 "Use js_add for
  dynamic dispatch (handles string+number etc.)"；同文件 `_ =>` 分支
  Sub/Mul/Div 内联 `F64Sub/F64Mul/F64Div`；`Expr::Compare` 的
  Lt/Le/Gt/Ge 内联 `F64Lt/F64Le/F64Gt/F64Ge`，Eq/Ne 走 js_strict_eq 桥。
- `emit/stmt.rs` L66-69/114/166/226：if/while/for 条件一律
  `emit_memcall_i32(func, "is_truthy", 1)`。
- `emit/function.rs` + `compile.rs` L711-713：函数签名 `vec![ValType::I64; param_count]`
  统一装箱，无类型特化签名。
- `crates/perry-codegen-wasm/Cargo.toml`：依赖只有 perry-hir / perry-codegen-js /
  perry-dispatch / wasm-encoder / base64 —— **不依赖 perry-codegen**。
- 类型信息存在但未被 wasm 后端消费：
  - `perry-hir/src/types.rs` L32：`Int32`（"Integer type (optimization for known integers)"）
  - `perry-hir/src/lower_types.rs` L421-435：Sub/Mul/Div/Mod/Exp 双 Number
    操作数 → `Type::Number`（含 Int32 归并）
  - `perry-hir/src/analysis/value_types.rs`：完整 HIR 值类型推断（HirTypeEnv/infer_expr_type）
  - `perry-codegen/src/expr/i32_fast_path.rs` + `codegen/typed_abi.rs`：原生 LLVM
    后端已有 i32/f64 特化 ABI——wasm 后端（独立 crate）完全没有。
- `PERRY_BOX_INT32` 0x7FFE：host/perry_abi.h、perry-runtime value/jsvalue.rs
  `JSValue::int32`、JS 宿主 INT32_TAG 均有解码路径；wasm emit 目录 grep 0x7FFE
  零命中——codegen 从不发射该编码。
