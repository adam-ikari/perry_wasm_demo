// 被 perry (typerry) 编译为 wasm,再交给 WAMR 运行的 TypeScript 源码。
// 覆盖: 递归 / 循环 / 数字运算 / 字符串拼接 / 模板字符串 / 字符串长度 / 字符串比较 / console.log

function fib(n: number): number {
  if (n < 2) return n;
  return fib(n - 1) + fib(n - 2);
}

function sumFib(limit: number): number {
  let total = 0;
  for (let i = 0; i < limit; i++) {
    total += fib(i);
  }
  return total;
}

function greet(name: string): string {
  return "Hello, " + name + "!";
}

const total: number = sumFib(20);
console.log("fib(0..19) sum = " + total);

const msg: string = greet("WAMR");
console.log(msg);
console.log("msg.length = " + msg.length);

if (msg === "Hello, WAMR!") {
  console.log("string compare ok");
}

console.log(`template: ${msg} (sum=${total})`);
