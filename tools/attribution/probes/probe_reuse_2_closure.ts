// probe_reuse_2_closure — 闭包捕获。
//
// 目的：被闭包捕获的 id 在 type_facts 里一律拒绝（跨函数流不可静态跟踪）。
// 本探针验证"拒绝"之后语义仍然逐位正确：累加器 total 跨闭包边界持续被改写。
function makeAdder(start: number): (n: number) => number {
  let total = start;
  return function (n: number): number {
    total = total + n;
    return total;
  };
}

const add = makeAdder(10);
let acc = 0;
let i = 0;
while (i < 100) {
  acc = acc + add(i);
  i = i + 1;
}
console.log(acc);
console.log(add(0));
