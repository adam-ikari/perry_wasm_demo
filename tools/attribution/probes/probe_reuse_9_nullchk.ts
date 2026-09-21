// probe_reuse_9_nullchk — `x !== null` 之类的严格比较 + number 条件保守回退。
//
// 目的：
//   * `n !== 0` / `s !== null` 这类比较走桥（不在内联集合）——输出必须正确；
//   * `if (n)` / `if (z)` 是 number 条件，0 必须 falsy（特化只能接受二值盒布尔，
//     若误把 number 当布尔内联，`n = 0` 会变成 truthy）。
let n = 3;
let z = 0;
let s = "";
let out = 0;
if (n !== 0) {
  out = out + 1;
}
if (s !== null) {
  out = out + 10;
}
if (n) {
  out = out + 100;
}
if (z) {
  out = out + 1000;
}
console.log(out);
console.log(n !== 0);
