// probe_reuse_4_letrebind — 无注解 `let` + 赋值重绑定（数据流补充的核心形态）。
//
// 目的：`sum`/`i`/`n` 都是无注解 let，靠"初始化可证 + 赋值敏感不动点"才能证明；
// `flag` 是 boolean 候选（`flag = false` 保持候选，`n = n + 1` 是 Update，不破坏 number）。
let sum = 0;
let i = 0;
while (i < 1000) {
  sum = sum + i;
  i = i + 1;
}

let flag = true;
let n = 0;
while (flag) {
  n = n + 1;
  if (n > 500) {
    flag = false;
  }
}

console.log(sum);
console.log(n);
