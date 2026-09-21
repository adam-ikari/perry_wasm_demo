// probe_str — 字符串密集形态（泛化验证用，与 src/bench.ts 并列）。
//
// 目的：验证后处理 pass 不误伤"本来就该走桥"的字符串运算。
//   * `s + "ab"`            → js_add(string,string)：桥必须保留（不可内联成 f64.add）
//   * `s.length`            → string_len 桥
//   * `s === s`             → string_eq 桥，其结果喂 is_truthy：保守回退（不内联）
//   * `hits + 1`            → js_add(number,number)：可内联
//   * `n > 8 ? ... : ...`   → BOOLBOX 比较：is_truthy 可内联
let s = "";
for (let i = 0; i < 32; i++) {
  s = s + "ab";
}
let n = s.length;
console.log(n);

let hits = 0;
for (let i = 0; i < 200000; i++) {
  if (s === s) {
    hits = hits + 1;
  }
}
console.log(hits);

console.log(n > 8 ? "long" : "short");
