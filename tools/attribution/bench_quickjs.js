// bench_quickjs.js — F 路: QuickJS 直接解释执行 JS (不经 wasm)。
// 与 src/bench.ts 同算法: fib(29) (递归 1,664,079 次逻辑调用) + 10^6 循环累加,
// 输出与基准各路径完全一致的两行。供 qjs 解释执行。
const N_FIB = 29;
const N_LOOP = 1000000;

function fib(n) {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}

const f = fib(N_FIB);
console.log('fib(' + N_FIB + ') = ' + f);

let s = 0;
for (let i = 0; i < N_LOOP; i++) {
    s += i;
}
console.log('sum = ' + s);
