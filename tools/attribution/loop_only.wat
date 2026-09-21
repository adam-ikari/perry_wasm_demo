;; loop_only.wat — 干净 1e6 循环累加, 无导入
(module
  (memory (export "memory") 1)
  (func (export "_start")
    (local $s i64) (local $i i64)
    (block $d (loop $c
      (br_if $d (i64.ge_u (local.get $i) (i64.const 1000000)))
      (local.set $s (i64.add (local.get $s) (local.get $i)))
      (local.set $i (i64.add (local.get $i) (i64.const 1)))
      (br $c)))))
