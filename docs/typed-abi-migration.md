# 路径 4：perry-codegen-wasm typed ABI 化 + 去影子栈 — 实施规划

本文件是**设计/规划文档**，不含实现代码。目标是把 wasm×WAMR AOT 路（E 路）的性能
从 ~122 ms 压到 V3 量级（~3.3 ms），即 perry 原生纯执行（1.6–2.6 ms）的 1.3–2.1×、
与原生同数量级。用户已裁决路径 4 为正确路线。背景与全部实测锚点见
`docs/performance.md`「修复路径与天花板」节（:699–811）；上游事实表见
`/tmp/perry-codegen-findings.md`（HEAD `7ac11b09`，已逐行复核本文引用的 file:line）。

## 1. 目标与验收

**总目标**：wasm 路稳态 P50 从 E ≈ 122 ms → V3 量级 ≈ 3.3 ms（快 ~37×），与 perry
原生纯执行同数量级。每阶段验收必须满足两条硬约束：

1. **输出逐字节一致**：`fib(29) = 514229`、`sum = 499999500000`（与基准同源）。
2. **P50 锚点对照**（同口径：`build/aot_time` 12 轮进程内计时，弃第 1 轮取 11 样本
   中位数，WAMR AOT opt-level=3，复现脚本见 §4）。

| 阶段 | 目标 P50 (ms) | 相对 E | 锚点来源 | 可发布 |
|---|---:|---:|---|:-:|
| 现状 E | 122.1 | 1× | `aot_e.sh` | — |
| 0 装配类型环境 | ~122（不退化） | 1× | `aot_e.sh` 全量重放 | — |
| 1 发射点特化（B2） | 17.2（±20%） | 0.14× | `exp_specialize.sh` B2 黄金 | ✅ |
| 2 字面量/局部 typed | ~12–17 [INFERENCE] | — | `aot_e.sh` + 无回归 | — |
| 3 签名 typed + trampoline | ~12–17 [INFERENCE] | — | `aot_e.sh` + 无回归 | △ |
| 4 去影子栈 | ~3.3–5.0 | 0.03–0.04× | V3 锚 `exp_specialize.sh` | ✅ |
| 5 rt 桥 typed 重载双轨 | ~3.3（长尾收敛） | 0.027× | `aot_e.sh` 全量 | △ |

✅=里程碑可发布；△=基础设施/长尾，热路径已收敛。

**关键非显见结论（规划核心）**：阶段 2、3 对本基准（`src/bench.ts`）的**直接 P50
收益近零**——fib 已是 TS 注解函数（`n: number): number`，:5–8），当前 E/B2 路里其
递归调用已是直接 wasm `Call`（`emit/expr/calls.rs:166` `Instruction::Call(idx)`）、
签名已是 `(i64)->i64`、算术已内联 `f64.add`（B2）。typed 签名（I64→F64）在 AOT 下
是同位宽 reinterpret 空操作 [INFERENCE]，trampoline 经 wamrc 内联后近零开销
[INFERENCE]。**真正的 14 ms 跃迁在阶段 4（去影子栈）**，而阶段 2/3 是阶段 4 的
**前置基础设施**（只有静态已知值表示的函数才能安全地把溢出从 global-sp 内存改为
局部）。因此落地顺序不可跳过 2/3 直奔 4，但 2/3 的验收锚点以"无回归 + 正确性"为主、
不以 P50 跃迁为标准。

## 2. 现状与差距

五档实测（同一基准 fib(29)+10⁶ 循环，WAMR AOT，输出逐字节一致）：

| 档 | 含义 | P50 (ms) | 相对 E | 相对 E' |
|---|---|---:|---:|---:|
| E | perry 原样 wasm×AOT | 122.1 | 1× | 100× |
| B1 | `+` 内联 f64.add，is_truthy 桥保留 | 71.6 | 0.59× | 58.9× |
| B2 | B1 + is_truthy 内联假盒比较，NaN-box+影子栈保留 | 17.2 | 0.14×（快 7.1×） | 14.1× |
| V3 | 纯 f64、无盒、无影子栈、全内联 | 3.3 | 0.027×（快 36.7×） | 2.7× |
| E' | 干净 i64 wasm×AOT | 1.2 | 0.010× | 1× |
| D | perry 原生 LLVM（进程级 / 纯执行 1.6–2.6） | 6.286 | — | — |

**乘性分解**（`performance.md:769–779`）：

- **E − B2 ≈ 105 ms = 桥调用本体**（每层 2 桥 × ~2.08M 桥：js_add + is_truthy 的
  NAME_CACHE load + br_table 分派 + 类型打标 + 结果 unbox 往返）——阶段 1 类型特化
  全部消灭。
- **B2 − E' ≈ 16 ms = 影子栈内存纪律**（每值经 global sp 存/取内存，fib 每层 ~20 条
  辅助指令，1.66M 层 × ~10 ns）——阶段 4 消灭。
- **E' ≈ 1.2 ms = 纯机器码**（LLVM 深度内联 fib）。

**B2→V3 的 16 ms 全归影子栈纪律——核验**：B2 的 `build/spec_B2_full.wat` 中 fib
（`func $1 (param $0 i64) (result i64)`）体含大量 `(global.set $global$0 ...)` 帧
指针操作 + `(i64.store (global.get $global$0) ...)` / `(i64.load (global.get $global$0))`
溢出对（递归调用间结果暂存、参数暂存），算术 `f64.add` 已内联但两侧仍从影子栈 load。
V3（`specialized_bench_f64.wat`）无 global sp、无 i64.store/load，溢出用 local。故
16 ms 归因有 wat 级实证支撑。**子论断"reinterpret 对在 LLVM 是空操作、NaN-box 本身
近零成本"为 [INFERENCE]**（`performance.md:774` 标注同源推断；B2 保留 reinterpret 对
仍达 17.2 ms，间接佐证 reinterpret 非主要税）。

## 3. 阶段划分

每阶段给：改什么 / 上游 file:line / 本 demo 怎么验证 / 验收 P50 / 风险。

### 阶段 0：装配 HIR 类型环境

- **改什么**：在 `WasmModuleEmitter::compile`（`emit/compile.rs:9`）入口、遍历 modules
  前（约 `:560` `for (mod_idx, (_, module)) in modules.iter()` 处），对每个 module 调
  `HirTypeEnv::from_module(&module)`（`perry-hir/src/analysis/value_types.rs:222`），
  把 env 挂到 `WasmModuleEmitter`（`emit/module_emitter.rs:11` struct 加字段）；
  `FuncEmitCtx`（`emit/func_emit_ctx.rs:11,44`，持 `emitter: &WasmModuleEmitter`）透传
  env 引用给发射点。**纯装配，不改变任何发射指令。**
- **上游 file:line**：`emit/compile.rs:9,560`；`emit/module_emitter.rs:11`；
  `emit/func_emit_ctx.rs:11,44`；`perry-hir/src/analysis/value_types.rs:222`（from_module）、
  `:551`（infer_expr_type 签名）、`:1649–1689`（infer_binary_type，Add: number+number→Number）。
- **本 demo 验证**：`tools/attribution/aot_e.sh 12` 全量重放，输出逐字节一致，P50 不退化
  （≈122 ms 量级，±5%）。
- **验收 P50**：~122 ms（无回归）。
- **风险**：低。env 为 owned（from_module 返回 Self），FuncEmitCtx 借用引用即可，无
  生命周期陷阱（生命周期同 module 遍历作用域）。唯一注意：env 装配成本（from_module
  全模块扫描）在编译期一次性，不影响运行时。

### 阶段 1：发射点特化（`+`/条件内联，回退保留）= 路径 3 完整，锚定 B2

- **改什么**：
  1. **`+`（BinaryOp::Add）**：`emit/expr/literals_vars.rs:176–184`（当前无条件
     `emit_memcall(func,"js_add",2)`）前置分支——`infer_expr_type(left)` 与
     `infer_expr_type(right)` 均 number-like（`Type::Number|Int32`，依
     `value_types.rs:1665–1666`）→ 复用 `:219–240` 已存在的 pure-numeric 内联模式
     （`F64ReinterpretI64 → F64Add → I64ReinterpretF64`，与 `:139–151` `++`/`--` 同构）；
     否则原 `js_add` 桥。string+number 的 `+` 经 `infer_binary_type` 判 String→走桥
     （`value_types.rs:1657–1663`），行为不变。
  2. **条件 is_truthy**：`emit/stmt.rs:68–69`（if）、`:113–114`（while）、`:165–166`
     （do-while）、`:225–226`（for）——条件可证 `Type::Boolean`（如 `f64.lt` 产出盒
     布尔，TAG_TRUE `0x7FFC…0004`/TAG_FALSE `0x7FFC…0003`）→ 内联 `I64Eq` 假盒比较
     （`i64.ne v TAG_FALSE` 等价，见 `performance.md:766`）；**number 条件保守回退**
     `is_truthy`（JS truthiness：0/-0/NaN 均 falsy，NaN-box 位型中 -0.0=0x8000…、
     NaN 位型≠0，不能裸 `i64.ne 0`）。
  3. （可选子步）**Eq/Ne**：`literals_vars.rs:249–285`（当前无条件 `js_strict_eq`）——
     两侧可证 number → `F64Eq`/`F64Ne`；否则原桥。Lt/Le/Gt/Ge（`:286–308`）已内联，
     仅需补 i32 变体（两侧可证 Int32 → `I32LtS` 等，省 2 次 reinterpret）。
- **上游 file:line**：`emit/expr/literals_vars.rs:176–184,219–240,139–151,249–285,286–308`；
  `emit/stmt.rs:68–69,113–114,165–166,225–226`；`emit/compile.rs:56,306`（js_add 桥
  import `t_f64_f64_f64`，签名 `(i64,i64)->i64`）；`emit/runtime_imports.rs:16`、
  `emit/string_collection.rs:23`；`perry-hir/src/analysis/value_types.rs:551,1649–1689`。
- **本 demo 验证**：`tools/attribution/exp_specialize.sh 12` 复现 B1=71.6 / B2=17.2 ms
  作"黄金参照"（`spec_patch.py` 生成的 `spec_B2_full.wat` 即本阶段发射结果的等价手工
  特化）；上游改动落地后用 `aot_e.sh 12` 跑真实 perry 产物，P50 应落在 B2 量级。
  输出逐字节一致（`fib(29)=514229`/`sum=499999500000`）。
- **验收 P50**：~17.2 ms（±20%）。
- **风险**：中。JS truthiness 边角——number 条件回退 `is_truthy` 即绕开；string+number
  的 `+` 走桥。回退路径保证行为不变（类型不证→原桥）。

### 阶段 2：字面量与局部 typed（INT32_TAG 0x7FFE 对齐原生、Number 裸 F64 位型直存）

- **改什么**：
  1. **字面量**：`emit/expr/literals_vars.rs:15–18`——`Expr::Integer` 当前一律
     `f64_const + I64ReinterpretF64`（裸 f64 位型，不发 INT32 标记）。改为：**消费上下文
     可证 i32**（typed I32 参数/局部、数组索引、i32 比较）时发
     `I64Const(INT32_TAG<<48 | i32)`（INT32_TAG=0x7FFE，需在 `emit/constants.rs:27–31`
     补常量，与 `wasm_runtime.js:12` `INT32_TAG=0x7FFEn` 一致）；**number 算术上下文**
     保持裸 f64 位型（不发 tag，因 f64.add 内联路径假定裸 f64）。
  2. **局部 typed**：`emit/function.rs:49`——当前 `locals = vec![(extra_locals+3, I64),(1,I32)]`
     全 I64。改为：依 `HirTypeEnv.locals`（推断的局部类型，`value_types.rs:25–38`）+
     声明类型，可证 Int32→I32 槽、Number→F64 槽（同位宽但语义标记），其余 I64。牵动
     所有 `LocalGet/LocalSet` 点的类型一致性。
- **上游 file:line**：`emit/expr/literals_vars.rs:11–18`；`emit/constants.rs:27–31`；
  `emit/function.rs:49`；`perry-hir/src/analysis/value_types.rs:25–38`（HirTypeEnv.locals）；
  `perry-hir/src/types.rs:30,32`（Number/Int32，"optimization for known integers"）；
  原生参照 `crates/perry-runtime/src/header.rs:842`（INT32_TAG 0x7FFE 定义）。
- **本 demo 验证**：`aot_e.sh 12` 全量重放，输出逐字节一致，P50 不回归 vs B2。重点验证
  `let sum = 0; for(let i=0;...)` 的 loop 局部若被 typed 不破坏语义（`src/bench.ts:16–19`）。
- **验收 P50**：~12–17 ms [INFERENCE]（fib 是 f64，INT32_TAG 对其热路径贡献近零；loop
  的 i/sum 若 typed 有边际收益；主体价值是阶段 4 的前置证据）。
- **风险**：中。**跨桥编码连带**：若 INT32_TAG 值经 mem_call/js_add 跨桥，rt 桥 decode
  必须认 0x7FFE。当前 `runtime-wasm/src/lib.rs` decode 不认 0x7FFE（仅 STRING_TAG 0x7FFF
  + 特殊带）。**规避**：阶段 2 的 INT32_TAG 发射限定在"不跨桥"的 i32 上下文（typed
  局部/参数内联消费），或同步给 rt decode 加 0x7FFE 分支（小改，归阶段 5 前置项）。
  local typed 牵动 LocalGet/Set 全调用点，回归面中。

### 阶段 3：函数签名 typed + trampoline（typed ABI 化主体）

- **改什么**（仿原生 `codegen/typed_abi.rs`）：
  1. **签名**：`emit/compile.rs:711–719`（用户函数 `vec![ValType::I64; param_count]`）
     + 同构点 `:618`（async 桥）、`:658`（FFI）、`:752/:764`（构造器/方法）、`:826`
     （闭包）——按 `typed_param_rep_for_type`（`typed_abi.rs:144–156`：
     Int32→I32/Number→F64/Boolean→I1/String→StringRef，其余 None）选 typed 签名；
     任一参数不支持 → 整体回退 I64（`typed_abi.rs:158–165`）。
  2. **拒绝制**：照搬 `typed_f64_callable_rejection_reason`（`typed_abi.rs:1232–1273`）：
     async/generator/was_plain_async、captures 非空、return_type 非 f64、param 有
     default/rest/arguments_object、param.ty 不支持、body 扫描
     （`typed_f64_body_rejection_reason:1538+`）——任一命中即拒绝，记入 rejection
     records。决策消费仿 `codegen/mod.rs:1795–1838`（每函数跑 rejection，落入 typed 集合）。
  3. **生成**：typed 函数 = 内部 raw clone（typed 签名，`force_inline`）+ 公开 JSValue
     trampoline（guard/unbox→call raw→rebox）；模式见 `codegen/mod.rs:3384–3401` +
     `codegen/function.rs:64–103`（`compile_typed_f64_function`：`linkage=internal`、
     `force_inline=true`、param_reps→llvm_ty）。wasm 端：raw clone 用 typed 签名，
     公开 trampoline 保留原 I64 签名供未 typed 调用点 / 模块边界。
  4. **调用点**：`emit/expr/calls.rs`（`FuncRef` 分支 ~`:166` `Instruction::Call(idx)`）
     ——typed 调用点（callee 已 typed + 所有实参可证 typed）直接 call raw clone（参数已
     typed 不必装箱）；否则经 trampoline（I64 装箱 ABI）。
- **上游 file:line**：`emit/compile.rs:711–719,618,658,752,764,826,1035–1042`（type
  section 写出）；`emit/function.rs:49`；`emit/expr/calls.rs:140–210`（调用点装箱/补
  undefined/丢余 arg）；`perry-codegen/src/codegen/typed_abi.rs:1–6,144–156,158–165,
  1232–1273,1538+`；`codegen/mod.rs:1795–1838,3384–3401`；`codegen/function.rs:64–103`；
  `typed_abi_opt_report.rs:1–21`（`--opt-report` 渲染拒绝原因，可选）。
- **本 demo 验证**：`aot_e.sh 12`——fib 应落入 typed 集合（`n: number): number` 注解
  满足 return_type F64 + param Number + 无 captures/default/rest/async + body 直线
  number 操作）。输出逐字节一致。
- **验收 P50**：~12–17 ms [INFERENCE]——**对本基准直接收益近零**：fib 已是直接 `Call`
  + i64 签名 + 内联算术（B2），typed 签名（I64→F64）在 AOT 是同位宽空操作，trampoline
  经 wamrc 内联近零。阶段 3 的价值是**为阶段 4 提供静态已知值表示的前提**（typed 局部
  可安全去影子栈）。验收以"无回归 + fib 落入 typed 集合"为主。
- **风险**：高。trampoline codegen 在 wasm 端非平凡（guard/unbox/rebox 的指令序列、
  force_inline 在 wasm 无原生 inline 属性靠 wamrc 启发式）；call_indirect/闭包捕获/
  async/类方法的 typed 限制——照搬拒绝制即可（`typed_abi.rs:861–908` method/closure
  rejection、`:910–1031` closure with_types 可变捕获拒绝）。回归面全动。

### 阶段 4：去影子栈（值从 global sp 内存纪律改为寄存器/局部）

- **改什么**：B2 的 fib 体仍含 `(global.set $global$0 ...)` 帧指针操作 +
  `(i64.store/i64.load (global.get $global$0))` 溢出对（递归调用间结果暂存、参数暂存）。
  阶段 4 把**已 typed 函数**（阶段 3 落入 typed 集合的 raw clone）的值溢出约定从
  global-sp 内存改为 wasm local + operand stack：中间结果存 typed local（F64/I32），
  帧管理用 wasm 的局部而非自管 sp。通用 NaN-box 函数（未 typed）保留影子栈作 fallback。
- **上游 file:line**：影子栈发射点分散于 `emit/` 全域——`emit/expr/calls.rs`
  （`emit_frame_begin`/`emit_store_arg` 装箱 arg 暂存，`:55–94,120–138`）、
  `emit/expr/literals_vars.rs:176–184,249–285`（桥 arg store）、`emit/function.rs`
  （帧 setup/teardown）、`emit/compile.rs`（global sp 声明）。需系统定位所有
  `global.get/set $global$0` + `i64.store/load` 发射点。
- **本 demo 验证**：`exp_specialize.sh 12` 的 V3（`specialized_bench_f64.wat`）是"去
  影子栈"的黄金参照（无 global sp、无 i64.store/load）。上游改动后 `aot_e.sh 12` 跑
  真实产物，P50 应逼近 V3=3.3 ms。输出逐字节一致。
- **验收 P50**：~3.3–5.0 ms（V3 锚 3.3；与原生纯执行 1.6–2.6 同数量级，1.3–2.1×）。
- **风险**：高。这是 B2→V3 的 14 ms 主体来源，改动面最大（值溢出约定是 codegen 的
  横切关注点）。需保证：typed 函数的 local 数量不超 wasm 限制、递归深度下的局部复用、
  动态 arg 数（variadic/rest）的函数仍走影子栈。**依赖阶段 3**（只有 typed 函数能安全
  去：未 typed 的 JSValue 仍需泛型栈）。

### 阶段 5：rt.* 桥 ABI 同步（typed 重载双轨）

- **改什么**：业务 wasm 的 typed 调用点若直连 typed rt 桥（如 string+number 的 `+`
  仍走桥、console_log 的 typed 值打印），rt 桥需提供 typed 重载。**双轨**：旧 i64
  JSValue 桥保留作 fallback（未 typed 调用点 / 模块边界），新 typed 桥（如
  `js_add_f64(f64,f64)->f64`、`is_truthy_i1(i1)->i32`）供 typed 调用点直连。三处同步：
  1. **本项目 `runtime-wasm/src/lib.rs`**（Rust no_std 运行时，导出 211 个 rt.*，当前
     签名全 i64/f64 位型，见 `:461–462 rt_js_add(i64,i64)->i64`、`:471–472
     rt_js_strict_eq`、`:476–477 rt_is_truthy(i64)->i32`、`:611–612 rt_mem_call`、
     `:620–621 rt_mem_call_i32`）——加 typed 重载导出（与旧桥并存）。
  2. **上游 JS 宿主层 `wasm_runtime.js`**（`crates/perry-codegen-wasm/src/wasm_runtime.js`，
     `:12 INT32_TAG`、`:155 js_add`、`:168–176 is_truthy`、`:1619` 另一份）——同步加
     typed 重载（B 路 Node V8 宿主用）。
  3. **业务 wasm 导入段**：typed 调用点 import typed 桥名，未 typed import 旧桥名。
- **双轨过渡**：过渡期同一 rt 名字两份实现（i64 + typed），业务 wasm 按调用点类型
  import 对应版。输出逐字节一致因 typed 重载语义等价（`js_add_f64(a,b)=f64.add` ≡
  `js_add` 对 number+number 的 `toJsValue(a)+toJsValue(b)`）。`tools/gen-rt-symbols.mjs`
  生成桩表需认 typed 桥名（否则误报未实现）。
- **上游 file:line**：`runtime-wasm/src/lib.rs:461–462,471–472,476–477,611–612,620–621,
  495–580`（BRIDGES 表 + invoke 分派）；`wasm_runtime.js:12,155,168–176,1619`；
  `emit/compile.rs:56,306`（桥 import 声明 `t_f64_f64_f64` 等）；
  `emit/runtime_imports.rs:16`、`emit/string_collection.rs:23`。
- **本 demo 验证**：`aot_e.sh 12` 全量重放（合并→补丁→wamrc→校验→计时），输出逐字节
  一致。typed 桥直连后热路径（fib）已无桥调用，阶段 5 主要收益在 string/console 路径
  与混合类型 `+`（本基准触及少）。
- **验收 P50**：~3.3 ms（长尾收敛，热路径已由阶段 4 收敛）。
- **风险**：中。双轨兼容（同名两实现）、`gen-rt-symbols.mjs` 桩表识别、wasm-merge 合并
  typed 桥导入。本 demo 的 13 个实现桥 + 198 桩需同步加 typed 版（或仅对热桥加，余桩
  保持 i64 报错）。

## 4. 每阶段验收标准（工具复现 + P50 锚点）

复现工具（均在 `tools/attribution/`，项目根目录执行）：

| 工具 | 用途 | 产出 |
|---|---|---|
| `aot_e.sh [runs]` | E 路一键复现（合并→补丁→wamrc→校验→计时，E+E'） | P50 + 输出校验 |
| `exp_specialize.sh [runs]` | 实验 B：B1/B2/V3 等价手工特化 | B1=71.6/B2=17.2/V3=3.3 ms |
| `exp_wasmopt.sh [runs]` | 实验 A：wasm-opt 后处理上限 | A5=93.5 ms（可选过渡） |
| `bench.sh` | A/B/C/D/E 五路全量对照 | 全表 |

**逐字节一致校验**（每阶段强制）：`fib(29) = 514229`、`sum = 499999500000`。
`aot_e.sh`/`exp_specialize.sh` 内置校验（`verify()` 函数比对 `expect` 串）。

| 阶段 | 复现命令 | P50 锚点 | 一致性 |
|---|---|---:|:-:|
| 0 | `aot_e.sh 12` | ~122 | ✅ |
| 1 | `exp_specialize.sh 12`（黄金）+ `aot_e.sh 12`（上游产物） | ~17.2 | ✅ |
| 2 | `aot_e.sh 12` | ~12–17 [INFERENCE] | ✅ |
| 3 | `aot_e.sh 12` | ~12–17 [INFERENCE] | ✅ |
| 4 | `exp_specialize.sh 12`（V3 黄金）+ `aot_e.sh 12` | ~3.3–5.0 | ✅ |
| 5 | `aot_e.sh 12` | ~3.3 | ✅ |

注：阶段 1/4 的 `exp_specialize.sh` 是**等价手工特化黄金**（`spec_patch.py` 生成），
非上游真实产物；它锚定"codegen 特化后的预期"。上游改动落地后改用 `aot_e.sh` 跑真实
perry 产物对照同量级。

## 5. 风险与回退

**Top 3**：

1. **JS truthiness 边角（阶段 1）**：number 条件（0/-0/NaN 均 falsy）不可裸
   `i64.ne 0`——NaN-box 位型中 -0.0=0x8000_0000_0000_0000、NaN 位型≠0。**回退**：
   第一版 number 条件一律走 `is_truthy` 桥，仅 Boolean 条件内联。行为不变。
2. **去影子栈的横切改动面（阶段 4）**：值溢出约定是 codegen 全域关注点，回归面大。
   **回退**：typed 函数保留影子栈 fallback（即停在阶段 3，P50≈B2=17.2 ms 仍快 7.1×，
   可发布）；去影子栈仅在 typed raw clone 内做，通用函数不动。
3. **trampoline 开销与 wamrc 内联不可控（阶段 3）**：wasm 无原生 inline 属性，靠 wamrc
   启发式；若 trampoline 未被内联，typed 调用点反添开销。**回退**：trampoline 仅在模块
   边界/混合调用用，同模块 typed 互调直连 raw clone（不经 trampoline）[INFERENCE]。

**其余风险**：

- string+number 混合的 `+`（阶段 1）：`infer_binary_type` 判 String→走桥，不内联，安全。
- call_indirect/闭包捕获/async/类方法 typed 限制（阶段 3）：照搬 `typed_abi.rs:861–908,
  910–1031` 拒绝制，未证→回退通用 ABI。
- INT32_TAG 跨桥编码（阶段 2）：rt decode 不认 0x7FFE——限定 INT32_TAG 发射在不跨桥
  上下文，或同步 rt decode（归阶段 5 前置）。
- rt 桥双轨兼容（阶段 5）：`gen-rt-symbols.mjs` 桩表识别 typed 桥名；同名两实现过渡期
  并存，输出一致因语义等价。
- V3 vs E' 的 2.1 ms 差是 LLVM 对 f64 vs i64 fib 的内联/优化差异 [INFERENCE]，非 perry
  可控项——阶段 4 的目标是 V3=3.3 ms，非 E'=1.2 ms。

**回退总原则**：每阶段保留原 i64/NaN-box 回退路径（类型不证→原桥/原签名/影子栈），
任一阶段可独立回退到上一可发布里程碑（阶段 1 后=B2，阶段 4 后=V3）。

## 6. 工作量与顺序

| 阶段 | 人日估计 | 依赖 | 里程碑 |
|---|---|---|---|
| 0 装配类型环境 | 0.5–1 | 无 | — |
| 1 发射点特化 | 2–4 | 0 | **M1：B2=17.2 ms 可发布** |
| 2 字面量/局部 typed | 2–4（字面量 0.5–1 + 局部 1.5–3） | 0 | — |
| 3 签名 typed + trampoline | 4–7 | 0,2 | △ 基础设施 |
| 4 去影子栈 | 4–8 | 3 | **M2：V3≈3.3 ms 可发布** |
| 5 rt 桥 typed 重载双轨 | 3–6 | 4（可选） | △ 长尾 |
| **合计** | **~16–30（一人，约 3–6 周）** | | |

**落地顺序 0→5**，每阶段可独立合入、输出一致：

- **0→1**：低风险快赢，M1 后即可发布（7.1×，路径 3 主线）。
- **2**：可与 1 并行起步（字面量子步独立），局部 typed 子步需 0 的 env。
- **3**：依赖 0+2（typed 签名需 env + 局部 typed 证据），是 4 的硬前置。
- **4**：依赖 3（只有 typed 函数能安全去影子栈），M2 目标。
- **5**：4 后可选长尾（热路径已收敛）；若阶段 2 的 INT32_TAG 跨桥需 rt decode，则 5 的
  前置子项（rt decode 加 0x7FFE）需提前到阶段 2 之前。

**可回滚点**：M1（阶段 1 后）、M2（阶段 4 后）。阶段 2/3 是基础设施，不合入则停在 M1；
阶段 5 不合入则停在 M2（热路径已达标，长尾不影响基准）。

## 7. 附录：上游行号索引表

### 7.1 wasm 后端发射点（`crates/perry-codegen-wasm/src/emit/`）

| 发射点 | file:line | 现状 |
|---|---|---|
| 编译入口 compile | `compile.rs:9` | `WasmModuleEmitter::compile` |
| modules 遍历（env 装配点） | `compile.rs:560` | `for (mod_idx,(_, module)) in modules.iter()` |
| 用户函数签名 | `compile.rs:711–719` | `vec![ValType::I64; param_count]` |
| async 桥签名 | `compile.rs:617–620` | 全 I64 |
| FFI extern 签名 | `compile.rs:656–663` | 全 I64 |
| 构造器/方法/静态方法 | `compile.rs:750–753,762–766,776–780` | 带 this 槽，全 I64 |
| 闭包签名 | `compile.rs:826–829` | captures+params 全 I64 |
| type section 写出 | `compile.rs:1035–1042` | — |
| 桥 import 声明 | `compile.rs:56,306`（`t_f64_f64_f64`） | `(i64,i64)->i64` |
| 函数局部 | `function.rs:49` | `vec![(extra+3,I64),(1,I32)]` |
| `+`→js_add | `expr/literals_vars.rs:176–184` | 无条件 emit_memcall |
| pure-numeric 内联模式（复用） | `expr/literals_vars.rs:219–240` | Sub/Mul/Div/默认 F64Add |
| `++`/`--` 内联模式（复用） | `expr/literals_vars.rs:139–151` | F64Reinterpret+F64Add |
| Eq/Ne→js_strict_eq | `expr/literals_vars.rs:249–285` | 无条件桥 |
| Lt/Le/Gt/Ge 内联 | `expr/literals_vars.rs:286–308` | 已内联 F64Lt 等 |
| 数字字面量 | `expr/literals_vars.rs:11–18` | 一律 f64_const+reinterpret |
| NaN-box 常量 | `constants.rs:27–31` | STRING_TAG 0x7FFF + 特殊带，**无 INT32_TAG** |
| if 条件→is_truthy | `stmt.rs:68–69` | emit_memcall_i32 |
| while 条件 | `stmt.rs:113–114` | is_truthy+I32Eqz+BrIf |
| do-while 条件 | `stmt.rs:165–166` | is_truthy+BrIf |
| for 条件 | `stmt.rs:225–226` | is_truthy |
| 调用点装箱/补 undefined | `expr/calls.rs:140–210` | FuncRef→Call(idx) |
| console_log/method 调用 | `expr/calls.rs:55–94` | emit_store_arg+emit_memcall |
| 桥 import 注册 | `runtime_imports.rs:16`；`string_collection.rs:23` | — |

### 7.2 类型信息 API（`crates/perry-hir/src/`）

| API | file:line | 说明 |
|---|---|---|
| `Type` 枚举 | `types.rs:22–73` | Number:30、Int32:32、Boolean:28、String:36、Any:55 |
| `HirTypeEnv` | `analysis/value_types.rs:25–38` | locals/globals/function_returns |
| `HirTypeEnv::from_module` | `analysis/value_types.rs:222` | wasm 后端可现成调用 |
| `infer_expr_type` | `analysis/value_types.rs:551` | `pub fn infer_expr_type(expr, env) -> Type` |
| `infer_binary_type`（Add 规则） | `analysis/value_types.rs:1649–1689` | number+number→Number、string-like→String、else Any |
| HIR Function/Param 自带类型 | `ir/decl.rs:461–495,512–518` | `Param { ty: Type, ... }` |
| 参数类型提取（lower） | `lower/expr_function.rs:246–254`；`lower_patterns.rs:343–367` | 有注解→注解类型，无→Any |
| 消费者参照（原生） | `perry-codegen/src/type_analysis_facts.rs:4–5,130–141` | codegen-wasm **零引用** |

### 7.3 原生 typed ABI 参照（`crates/perry-codegen/src/`）

| 事实 | file:line |
|---|---|
| 设计原则（直线型 typed SSA，NaN-box 公共回退） | `codegen/typed_abi.rs:1–6` |
| `TypedParamRep`（F64/I32/I1/StringRef） | `codegen/typed_abi.rs:24–38` |
| `typed_param_rep_for_type` | `codegen/typed_abi.rs:144–156` |
| 任一不支持→整体 None | `codegen/typed_abi.rs:158–165` |
| f64 拒绝制 `typed_f64_callable_rejection_reason` | `codegen/typed_abi.rs:1232–1273` |
| body 扫描 `typed_f64_body_rejection_reason` | `codegen/typed_abi.rs:1538+` |
| method/closure rejection | `codegen/typed_abi.rs:861–908,910–1031` |
| 决策消费（每函数跑 rejection） | `codegen/mod.rs:1795–1838` |
| 生成（raw clone + trampoline，force_inline） | `codegen/mod.rs:3384–3401`；`codegen/function.rs:64–103` |
| `--opt-report` 渲染拒绝 | `codegen/typed_abi_opt_report.rs:1–21` |
| i32 快路径证明制 | `expr/i32_fast_path.rs:40–42,472–499` |
| 数值性证据 `is_numeric_expr` | `type_analysis/numeric.rs:127–165` |
| guarded 算术回退 | `expr/binary.rs:284–315` |

### 7.4 本项目侧连带（`runtime-wasm/src/lib.rs` + `wasm_runtime.js`）

| 事实 | file:line |
|---|---|
| rt_js_add | `runtime-wasm/src/lib.rs:461–462`（`(i64,i64)->i64`） |
| rt_js_strict_eq | `runtime-wasm/src/lib.rs:471–472` |
| rt_is_truthy | `runtime-wasm/src/lib.rs:476–477` |
| rt_mem_call / rt_mem_call_i32 | `runtime-wasm/src/lib.rs:611–612,620–621` |
| BRIDGES 表 + invoke 分派 | `runtime-wasm/src/lib.rs:495–580` |
| INT32_TAG 定义 | `wasm_runtime.js:12`（JS 桥认得但 wasm 后端从不发射） |
| js_add/is_truthy JS 实现 | `wasm_runtime.js:155,168–176`（`:1619` 另一份） |

---

*规划日期 2026-09-21。所有 file:line 已对 `/tmp/perry-src` HEAD `7ac11b09` 逐行复核。
[INFERENCE] 标注项为基于实测的推断，非逐行核实。*
