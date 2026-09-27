;; nohost_triv_nomem.wat — triv 无 memory 变体 (供 wasm-merge 单 memory 合并)
(module
  (type (;0;) (func (param i64 i64) (result i64)))
  (type (;1;) (func (param i64) (result i32)))
  (func (;0;) (type 0) (param i64 i64) (result i64)
    local.get 0
    local.get 1
    i64.add)
  (func (;1;) (type 1) (param i64) (result i32)
    local.get 0
    i64.const 2
    i64.ge_s)
  (export "add" (func 0))
  (export "ge2" (func 1)))
