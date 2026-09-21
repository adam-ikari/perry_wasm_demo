// bench.ts — 计算密集基准: 递归 fib + 大循环累加。
// 与 tools/bench_native.c 使用同一组常量 (N_FIB / N_LOOP), 结果跨目标必须一致。
// 打印结果: 防止死代码消除, 同时验证三路输出正确性。

function fib(n: number): number {
  if (n < 2) return n;
  return fib(n - 1) + fib(n - 2);
}

const N_FIB = 29;
const N_LOOP = 1000000;

const f = fib(N_FIB);
console.log("fib(" + N_FIB + ") = " + f);

let sum = 0;
for (let i = 0; i < N_LOOP; i++) {
  sum += i;
}
console.log("sum = " + sum);
