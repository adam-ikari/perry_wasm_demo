;; clean_bench.wat — 归因对照基准。
;; 与 src/bench.ts 完全相同的算法 (递归 fib(29) + 10^6 次累加)，但用纯 wasm 指令:
;;   - i64 算术，无 NaN-box，无 reinterpret
;;   - 不调任何 rt.* 导入，除 wasi fd_write (只在首尾各调一次, 不在热路径)
;;   - fib(29) 与 sum 的结果先在 wasm 里 itoa 成十进制, 拼进与三路基准一致的
;;     输出行 ("fib(29) = 514229" / "sum = 499999500000")，经 wasi fd_write 打出。
;;     这样同一份 wasm 可同时喂给 WAMR (A 路同款 perry_link 流程) 和 node (B 路对照)。
(module
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)

  ;; 内存布局:
  ;;   0..8    fib 结果 (校验用)
  ;;   8..16   sum 结果 (校验用)
  ;;   16..64  行缓冲 (拼接后的输出行)
  ;;   64..96  itoa 工作区 (20 位倒序)
  ;;   96..112 两个 iovec (fd_write 用): [ptr,len] x2

  ;; 把 u64 写成十进制到 $buf 起始处 (最多 20 位), 返回长度
  (func $utoa (param $buf i32) (param $v i64) (result i32)
    (local $p i32)
    (local $len i32)
    ;; 先倒序写进 64..84 的固定工作区
    (local.set $p (i32.const 84))
    (loop $digits
      (local.set $p (i32.sub (local.get $p) (i32.const 1)))
      (i32.store8 (local.get $p)
        (i32.add (i32.wrap_i64 (i64.rem_u (local.get $v) (i64.const 10))) (i32.const 48)))
      (local.set $v (i64.div_u (local.get $v) (i64.const 10)))
      (br_if $digits (i64.ne (local.get $v) (i64.const 0))))
    ;; 拷到 $buf
    (local.set $len (i32.sub (i32.const 84) (local.get $p)))
    (memory.copy (local.get $buf) (local.get $p) (local.get $len))
    (local.get $len))

  ;; 打印 "fib(29) = " + f
  (func $print_fib (param $f i64)
    (local $p i32)
    (local $l i32)
    (local.set $p (i32.const 16))
    ;; "fib(29) = " 10 字节
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
    (local.set $l (call $utoa (local.get $p) (local.get $f)))
    (local.set $p (i32.add (local.get $p) (local.get $l)))
    (i32.store8 (local.get $p) (i32.const 10)) ;; \n
    ;; iovec[0] = {ptr=16, len=p-16+1}
    (i32.store (i32.const 96) (i32.const 16))
    (i32.store (i32.const 100)
      (i32.add (i32.sub (local.get $p) (i32.const 16)) (i32.const 1)))
    (drop (call $fd_write (i32.const 1) (i32.const 96) (i32.const 1) (i32.const 104))))

  ;; 打印 "sum = " + s
  (func $print_sum (param $s i64)
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
    (local.set $l (call $utoa (local.get $p) (local.get $s)))
    (local.set $p (i32.add (local.get $p) (local.get $l)))
    (i32.store8 (local.get $p) (i32.const 10))
    (i32.store (i32.const 96) (i32.const 16))
    (i32.store (i32.const 100)
      (i32.add (i32.sub (local.get $p) (i32.const 16)) (i32.const 1)))
    (drop (call $fd_write (i32.const 1) (i32.const 96) (i32.const 1) (i32.const 104))))

  (func $fib (param $n i64) (result i64)
    (if (result i64) (i64.lt_s (local.get $n) (i64.const 2))
      (then (local.get $n))
      (else
        (i64.add (call $fib (i64.sub (local.get $n) (i64.const 1)))
                 (call $fib (i64.sub (local.get $n) (i64.const 2)))))))

  (func $_start (export "_start")
    (local $f i64)
    (local $sum i64)
    (local $i i64)
    (local.set $f (call $fib (i64.const 29)))
    (i64.store (i32.const 0) (local.get $f))
    (call $print_fib (local.get $f))
    (local.set $sum (i64.const 0))
    (local.set $i (i64.const 0))
    (block $done
      (loop $cont
        (br_if $done (i64.ge_u (local.get $i) (i64.const 1000000)))
        (local.set $sum (i64.add (local.get $sum) (local.get $i)))
        (local.set $i (i64.add (local.get $i) (i64.const 1)))
        (br $cont)))
    (i64.store (i32.const 8) (local.get $sum))
    (call $print_sum (local.get $sum)))

)
