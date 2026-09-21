;; nohost_triv.wat — triv 侧: 平凡实现 (注册名 triv)。
(module
  (memory (export "memory") 1)
  (func (export "add") (param i64 i64) (result i64) (i64.add (local.get 0) (local.get 1)))
  (func (export "ge2") (param i64) (result i32) (i64.ge_s (local.get 0) (i64.const 2))))
