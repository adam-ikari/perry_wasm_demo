// probe_reuse_6_arrayidx — 数组索引算术。
//
// 目的：`a[i]`/`a[i + 1]` 是动态载入，expr_is_number 必须判 false（走桥）。
// 注意：本仓 E 路的 rt 桩没有实现数组桥（`array_new` 即 trap），
// 因此本探针在 E 路上不可执行 —— 用"patch 绑定 vs 基线绑定"的差分来验证零误判。
const a: number[] = [1, 2, 3, 4, 5];
let total = 0;
let i = 0;
while (i < 4) {
  total = total + a[i] + a[i + 1];
  i = i + 1;
}
console.log(total);
console.log(a[0] + a[4]);
