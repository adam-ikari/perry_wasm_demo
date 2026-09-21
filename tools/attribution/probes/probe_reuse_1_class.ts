// probe_reuse_1_class — 类 + 类方法内算术。
//
// 目的：类方法体是 type_facts 的已知缺口（方法体里的无注解局部不参与判定），
// 因此这里的 `s + this.step(i)` 与 `i < k` 应保守走桥；关键是**不得误判**。
class Acc {
  base: number;
  constructor(base: number) {
    this.base = base;
  }
  step(n: number): number {
    return this.base + n;
  }
  run(k: number): number {
    let s = 0;
    let i = 0;
    while (i < k) {
      s = s + this.step(i);
      i = i + 1;
    }
    return s;
  }
}

const acc = new Acc(3);
console.log(acc.run(1000));
console.log(acc.step(39));
