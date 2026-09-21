;; specialized_bench_f64.wat — 实验 B V3: "类型特化 + 全去 NaN-box" 的天花板对照。
;; 与 src/bench.ts 完全相同的算法 (递归 fib(29) + 10^6 次累加)，纯 f64 算术:
;;   - fib 的 `+` 与 `n<2` 全部内联 (f64.add / f64.lt)，零桥调用
;;   - 无 NaN-box (值就是 f64 位型，无 i64 reinterpret 往返)
;;   - 无影子栈纪律 (值走局部变量/寄存器，不经过 memory)
;;   - 与 clean_bench.wat 同打印机制 (wasi fd_write，仅首尾调用)
;; 用途: 量化 "codegen 类型特化 + 值表示改纯 f64" 的 AOT 上限
;; (对比 B2_spec_full: 特化但保留 NaN-box + 影子栈 = 17.9ms)。
(module
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)

  ;; 内存布局 (同 clean_bench.wat):
  ;;   0..8    fib 结果 (校验用)
  ;;   8..16   sum 结果 (校验用)
  ;;   16..64  行缓冲
  ;;   64..84  itoa 工作区 (20 位倒序)
  ;;   96..112 两个 iovec

  (func $utoa (param $buf i32) (param $v i64) (result i32)
    (local $p i32)
    (local $len i32)
    (local.set $p (i32.const 84))
    (loop $digits
      (local.set $p (i32.sub (local.get $p) (i32.const 1)))
      (i32.store8 (local.get $p)
        (i32.add (i32.wrap_i64 (i64.rem_u (local.get $v) (i64.const 10))) (i32.const 48)))
      (local.set $v (i64.div_u (local.get $v) (i64.const 10)))
      (br_if $digits (i64.ne (local.get $v) (i64.const 0))))
    (local.set $len (i32.sub (i32.const 84) (local.get $p)))
    (memory.copy (local.get $buf) (local.get $p) (local.get $len))
    (local.get $len))

  (func $print_fib (param $f f64)
    (local $p i32)
    (local $l i32)
    (local.set $p (i32.const 16))
    (i32.store8 (local.get $p) (i32.const 102)) ;; f
    (i32.store8 (i32.add (local.get $p) (i32.const 1)) (i32.const 105)) ;; i
    (i32.store8 (i32.add (local.get $p) (i32.const 2)) (i32.const 98))  ;; b
    (i32.store8 (i32.add (local.get $p) (i32.const 3)) (i32.const 40))  ;; (
    (i32.store8 (i32.add (local.get $p) (i32.const 4)) (i32.const 50))  ;; 2
    (i32.store8 (i32.add (local.get $p) (i32.const 5)) (i32.const 57))  ;; 9
    (i32.store8 (i32.add (local.get $p) (i32.const 6)) (i32.const 41))  ;; )
    (i32.store8 (i32.add (local.get $p) (i32.const 7)) (i32.const 32))  ;; space
    (i32.store8 (i32.add (local.get $p) (i32.const 8)) (i32.const 61))  ;; =
    (i32.store8 (i32.add (local.get $p) (i32.const 9)) (i32.const 32))  ;; space
    (local.set $p (i32.add (local.get $p) (i32.const 10)))
    (local.set $l (call $utoa (local.get $p) (i64.trunc_f64_u (local.get $f))))
    (local.set $p (i32.add (local.get $p) (local.get $l)))
    (i32.store8 (local.get $p) (i32.const 10)) ;; \n
    (i32.store (i32.const 96) (i32.const 16))
    (i32.store (i32.const 100)
      (i32.add (i32.sub (local.get $p) (i32.const 16)) (i32.const 1)))
    (drop (call $fd_write (i32.const 1) (i32.const 96) (i32.const 1) (i32.const 104))))

  (func $print_sum (param $s f64)
    (local $p i32)
    (local $l i32)
    (local.set $p (i32.const 16))
    (i32.store8 (local.get $p) (i32.const 115)) ;; s
    (i32.store8 (i32.add (local.get $p) (i32.const 1)) (i32.const 117)) ;; u
    (i32.store8 (i32.add (local.get $p) (i32.const 2)) (i32.const 109)) ;; m
    (i32.store8 (i32.add (local.get $p) (i32.const 3)) (i32.const 32))
    (i32.store8 (i32.add (local.get $p) (i32.const 4)) (i32.const 61))
    (i32.store8 (i32.add (local.get $p) (i32.const 5)) (i32.const 32))
    (local.set $p (i32.add (local.get $p) (i32.const 6)))
    (local.set $l (call $utoa (local.get $p) (i64.trunc_f64_u (local.get $s))))
    (local.set $p (i32.add (local.get $p) (local.get $l)))
    (i32.store8 (local.get $p) (i32.const 10))
    (i32.store (i32.const 96) (i32.const 16))
    (i32.store (i32.const 100)
      (i32.add (i32.sub (local.get $p) (i32.const 16)) (i32.const 1)))
    (drop (call $fd_write (i32.const 1) (i32.const 96) (i32.const 1) (i32.const 104))))

  ;; 与 src/bench.ts 完全同语义: fib 递归, `+` 内联 f64.add, `n<2` 内联 f64.lt
  (func $fib (param $n f64) (result f64)
    (if (result f64)
      (f64.lt (local.get $n) (f64.const 2))
      (then (local.get $n))
      (else
        (f64.add
          (call $fib (f64.sub (local.get $n) (f64.const 1)))
          (call $fib (f64.sub (local.get $n) (f64.const 2)))))))

  ;; 10^6 循环: 条件与累加全内联 f64 算术
  (func $loop_sum (param $n f64) (result f64)
    (local $i f64)
    (local $s f64)
    (loop $l
      (if (f64.lt (local.get $i) (local.get $n))
        (then
          (local.set $s (f64.add (local.get $s) (local.get $i)))
          (local.set $i (f64.add (local.get $i) (f64.const 1)))
          (br $l))))
    (local.get $s))

  (func (export "_start")
    (local $f f64)
    (local $s f64)
    (local.set $f (call $fib (f64.const 29)))
    (i64.store (i32.const 0) (i64.trunc_f64_u (local.get $f)))
    (call $print_fib (local.get $f))
    (local.set $s (call $loop_sum (f64.const 1e6)))
    (i64.store (i32.const 8) (i64.trunc_f64_u (local.get $s)))
    (call $print_sum (local.get $s)))
)
