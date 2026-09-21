// probe_mixed — 混合类型形态（泛化验证用，与 src/bench.ts 并列）。
//
// 目的：验证类型判定边界 —— 同一程序里 number 与 string 混用 `+` / `===`。
//   * `total + i`        → js_add(number,number)：可内联（热路径）
//   * `i === 199999`     → js_strict_eq 桥（number === number）：不在内联集合，保留
//   * `label + "!"`      → js_add(string,string)：必须保留（否则输出错）
let total = 0;
let label = "n";
for (let i = 0; i < 200000; i++) {
  total = total + i;
  if (i === 199999) {
    label = label + "!";
  }
}
console.log(label);
console.log(total);
