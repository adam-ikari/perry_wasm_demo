// probe_nested — 跨函数形态（泛化验证用，与 src/bench.ts 并列）。
//
// 目的：验证跨过程类型推断（参数/返回值 kind 不动点）。
//   * `dbl` 的返回值就是 js_add 的结果（没有 f64 包络）→ 只有靠跨过程推断才知道它是 number
//   * `acc_upto` 的返回值是 js_add 结果 → 再跨一层
//   * `total + acc_upto(k)` → js_add(number, 跨函数返回 number)：可内联
//   * `i < n` → BOOLBOX 条件：is_truthy 可内联
function dbl(n: number): number {
  return n + n;
}

function acc_upto(n: number): number {
  let s = 0;
  let i = 0;
  while (i < n) {
    s = s + dbl(i);
    i = i + 1;
  }
  return s;
}

let total = 0;
for (let k = 0; k < 100; k++) {
  total = total + acc_upto(k);
}
console.log(total);
