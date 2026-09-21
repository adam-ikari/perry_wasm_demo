// probe_reuse_8_boolcond — boolean 变量作条件（`expr_is_boolean` 的声明类型路径）。
//
// 目的：`while (run)` / `if (ok)` 的盒布尔必须与 rt.is_truthy 逐位等价；
// 同时 `i === 999` 的 Compare 也走二值布尔路径。
let run = true;
let ok = false;
let i = 0;
let total = 0;
while (run) {
  total = total + i;
  i = i + 1;
  ok = i === 999;
  if (ok) {
    run = false;
  }
}
console.log(total);
console.log(i);
