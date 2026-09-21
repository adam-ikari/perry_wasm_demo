// probe_reuse_3_nested — 嵌套函数声明返回 number。
//
// 目的：内层函数体里的 `x + 1` 只有靠"返回类型声明为 number"才可证；
// 同时验证外层循环 `i < n` 的二值布尔条件路径。
function outer(n: number): number {
  function inner(x: number): number {
    return x + 1;
  }
  let s = 0;
  let i = 0;
  while (i < n) {
    s = s + inner(i);
    i = i + 1;
  }
  return s;
}

console.log(outer(1000));
console.log(outer(0));
