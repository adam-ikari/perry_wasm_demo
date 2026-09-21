;; fib_only.wat — 干净 fib(29), 无导入, 用于拆分 WAMR 下的 fib / 循环占比
(module
  (memory (export "memory") 1)
  (func $fib (export "fib") (param $n i64) (result i64)
    (if (result i64) (i64.lt_s (local.get $n) (i64.const 2))
      (then (local.get $n))
      (else (i64.add (call $fib (i64.sub (local.get $n) (i64.const 1)))
                     (call $fib (i64.sub (local.get $n) (i64.const 2)))))))
  (func (export "_start") (drop (call $fib (i64.const 29)))))
