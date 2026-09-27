# 算术过桥实验（rt_fast 快速分派 + codegen 形态取证）

对应 docs/paper/perry-wasm-paper.md §6.1「问题定位：可内联的算术被改写为桥接调用」。全部命令在项目根目录执行。

## 问题

用户主张：**算术不应该总是跨越运行时边界**。三个子问题：

1. perry wasm codegen 对纯算术过桥是设计使然还是缺陷（类型信息存在却未用）？
2. rt.wasm 桥侧按名线性扫描（10 项 memcmp）换成静态分派能吃掉多少 79×？
3. 正确修复在哪一层？

## 文件

| 文件 | 作用 |
|---|---|
| `rt_fast/lib.rs` | 实验版 rt 运行时：`runtime-wasm/src/lib.rs` 的拷贝，`invoke()` 加了 nameId→桥索引缓存表（首次按名扫描，之后直查 `NAME_CACHE[name]`，零 memcmp）。不改正式产物 |
| `rt_fast/rt_fast.wasm` | 实验版编译产物（16.9 KB，与正式 rt.wasm 16.8 KB 同量级） |
| `probe_nameid.md` | 反汇编 nameId 语义取证记录 |

## 实验 1：桥侧快速分派（A 路，WAMR 解释器）

```bash
# 1. 复制实验源码并编译（lib.rs 里 include 路径已改为实验版相对路径）
mkdir -p /tmp/rt_fast/src /tmp/rt_fast/.cargo /tmp/rt_fast/build
cp tools/attribution/rt_fast/lib.rs /tmp/rt_fast/src/
cp runtime-wasm/Cargo.toml /tmp/rt_fast/
cp runtime-wasm/.cargo/config.toml /tmp/rt_fast/.cargo/
cp build/rt_symbols.rs /tmp/rt_fast/build/
cd /tmp/rt_fast && cargo build --release --target wasm32-unknown-unknown

# 2. 链接 + 计时（与 A 路同一 bench.wasm、同一 runner）
node tools/patch-app-memory.mjs build/bench.wasm /tmp/bench_link_fast.wasm
cp /tmp/rt_fast/target/wasm32-unknown-unknown/release/perry_rt_wasm.wasm /tmp/rt_fast.wasm

# 3. 对照（各 5 轮 = 1 轮预热 + 4 计时，取中位 P50 = 第 3 小）
./build/bench_time build/bench_link.wasm build/rt_bench.wasm 5 | grep RUN
./build/bench_time /tmp/bench_link_fast.wasm /tmp/rt_fast.wasm 5 | grep RUN
```

结果（2026-09-19 实测，输出逐字节一致 fib(29)=514229 / sum=499999500000）：

| rt 版本 | P50 (ms) | codegen 因子（÷ A' 50.8 ms） |
|---|---:|---:|
| 正式 rt.wasm（按名扫描） | 3959–4010 | ~79× |
| rt_fast（nameId 缓存直查） | **2292** | **~45×** |

**降幅 1718 ms（−43%）**，按热路径 ~533 万次桥调用均摊 ≈ **322 ns/次**。
即：仅消除桥内 10 项 memcmp，79× 里就吃掉约 34×（79→45）。剩余 45× 来自
参数解码/编码、`V` 枚举 boxing、WAMR 跨模块调用本身（~30 ns/次 ×2/层）、
以及 codegen 的 NaN-box 指令形态。

## 实验 2：codegen 形态取证（GitHub PerryTS/perry main）

结论：**wasm 后端是独立简化发射器，未消费任何类型信息**。

- `crates/perry-codegen-wasm/Cargo.toml`：只依赖 `perry-hir` / `perry-codegen-js` / `perry-dispatch` / `wasm-encoder`——**不依赖 `perry-codegen`**。类型化 ABI（`typed_abi.rs`）、i32 快路径（`expr/i32_fast_path.rs`）、`Type::Int32` 消费全部在 `perry-codegen`（原生 LLVM 后端）里，wasm 后端一点也用不上。
- `perry-codegen-wasm/src/emit/expr/literals_vars.rs`：`BinaryOp::Add` → `emit_memcall("js_add")`（注释 "Use js_add for dynamic dispatch (handles string+number etc.)"）；但 **Sub/Mul/Div 是内联 `f64.sub/mul/div`**（同函数 `_ =>` 分支），Lt/Le/Gt/Ge 也是内联 `f64.lt`。
- `emit/stmt.rs`：所有 if/while/for 条件一律 `emit_memcall_i32("is_truthy", 1)`。
- `emit/function.rs` + `compile.rs`：所有用户函数/导入签名统一 `i64`（NaN-box 位型），无类型特化签名。
- HIR 侧类型信息**存在**：`perry-hir/src/types.rs` 有 `Type::Int32`（"Integer type (optimization for known integers)"），`lower_types.rs` 能推出 number 表达式，`analysis/value_types.rs` 是完整的 HIR 值类型推断——只是 wasm 后端不读。
- `PERRY_BOX_INT32` (0x7FFE)：`perry_abi.h`、`perry-runtime/src/value/jsvalue.rs`（`JSValue::int32`）、JS 宿主（`INT32_TAG`）三处都有**解码**路径，但 wasm codegen **从不发射**这个编码（emit 目录 grep 0x7FFE 零命中）——它只在原生后端由 runtime 内部使用。

## 结论定位（写入文档的判断）

- 过桥的不是"所有算术"，是 **`+`（js_add）与所有条件判定（is_truthy）**；Sub/Mul/Div/比较本来就已内联。
- `+` 过桥是**保守语义选择**（JS `+` 多态），但 perry 已有类型信息（TS 静态类型 + HIR 推断）足以特化，属**可修复缺陷**而非值模型必然——原生后端（perry-codegen）已实现同等特化（typed ABI + i32 fast path），wasm 后端是功能缺口。
- 桥侧线性扫描是**纯实现低效**（nameId 本来就是稳定的整数索引），实验证明值 34×。
- 修复路径优先级：① 桥侧 nameId 缓存/跳表（最小改动，demo 侧即可做，43% 实测）；② wasm codegen 消费 HIR 类型对 `+`/条件做内联特化（需上游 PerryTS/perry 改 crates/perry-codegen-wasm）；③ 长期：wasm 后端并入 perry-codegen 的类型化 ABI 体系。
