// probe_reuse_5_strmix — 字符串 + number 混合（必须走桥）。
//
// 目的：同一个循环里 `total + i`（number+number，可内联）与 `label + i`
// （string+number，必须走 js_add 桥）并存。若 patch 把后者也内联，输出立刻错。
let total = 0;
let label = "v";
for (let i = 0; i < 100; i++) {
  total = total + i;
  label = label + i;
}
console.log(label);
console.log(total);
console.log(label.length);
