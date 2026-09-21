// probe_reuse_10_mod — 模运算 `%`（`js_mod` 桥，patch 不碰）。
//
// 目的：确认 `%` 仍走桥且结果正确；同时验证 `i % 2 === 0` 这类"桥 + 比较"
// 组合不被误判成可内联。注意 E 路 rt 桩未实现 `js_mod`（trap），
// 因此本探针在 E 路上不可执行 —— 用差分（patch 绑定 vs 基线绑定）验证。
let total = 0;
let evens = 0;
for (let i = 0; i < 100; i++) {
  if (i % 2 === 0) {
    evens = evens + 1;
  }
  total = total + (i % 7);
}
console.log(total);
console.log(evens);
