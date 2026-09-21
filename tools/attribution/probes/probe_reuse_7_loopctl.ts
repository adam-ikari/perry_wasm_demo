// probe_reuse_7_loopctl — for 里 break/continue。
//
// 目的：stmt.rs 里 for 的条件发射点与 break/continue 的 br 深度耦合，
// 特化后 br 相对深度必须仍然正确（错一位就死循环或提前退出）。
let total = 0;
let hits = 0;
for (let i = 0; i < 1000; i++) {
  if (i < 3) {
    continue;
  }
  if (i > 900) {
    break;
  }
  total = total + i;
  hits = hits + 1;
}
console.log(total);
console.log(hits);
