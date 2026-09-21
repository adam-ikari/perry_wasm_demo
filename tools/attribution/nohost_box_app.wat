;; nohost_box_app.wat — 变体2: 与 perry fib 相同调用图, 但被调方经 call_indirect 间接调用
;; (LLVM 无法内联间接调用, 模拟 mem_call 的"不可内联大函数"调用形态), 且被调方做最小
;; NaN-box 往返 (i64↔f64 reinterpret 对 + f64.add), 量化"装箱形态 + 间接调用"的税。
(module
  (type $t_add (func (param i64 i64) (result i64)))
  (type $t_ge2 (func (param i64) (result i32)))
  (table 2 2 funcref)
  (elem (i32.const 0) $box_add $box_ge2)
  (memory (export "memory") 1)
  ;; 最小 js_add 核心: 两值按 perry f64 位型解码 (i64.reinterpret) → f64.add → 重编码
  (func $box_add (type $t_add) (param i64 i64) (result i64)
    (i64.reinterpret_f64
      (f64.add
        (f64.reinterpret_i64 (local.get 0))
        (f64.reinterpret_i64 (local.get 1)))))
  ;; 最小 is_truthy 核心: perry is_truthy 的位型判定 (非零非 NaN-box 零值)
  (func $box_ge2 (type $t_ge2) (param i64) (result i32)
    (i64.ge_s (local.get 0) (i64.const 2)))
  (func $fib (export "fib") (param $n i64) (result i64)
    (if (result i64)
      (call_indirect (type $t_ge2) (local.get $n) (i32.const 1))
      (then
        (call_indirect (type $t_add)
          (call $fib (i64.sub (local.get $n) (i64.const 1)))
          (call $fib (i64.sub (local.get $n) (i64.const 2)))
          (i32.const 0)))
      (else (local.get $n))))
  (func (export "_start")
    (drop (call $fib (i64.const 29)))))
