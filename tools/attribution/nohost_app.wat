;; nohost_app.wat — app 侧: fib 每层 2 次跨模块导入 (与 perry fib 调用图相同)。
(module
  (import "triv" "add" (func $tadd (param i64 i64) (result i64)))
  (import "triv" "ge2" (func $tge2 (param i64) (result i32)))
  (memory (export "memory") 1)
  (func $fib (export "fib") (param $n i64) (result i64)
    (if (result i64) (call $tge2 (local.get $n))
      (then
        (call $tadd
          (call $fib (i64.sub (local.get $n) (i64.const 1)))
          (call $fib (i64.sub (local.get $n) (i64.const 2)))))
      (else (local.get $n))))
  (func (export "_start")
    (drop (call $fib (i64.const 29)))))
