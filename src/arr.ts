// 负向验证用: 这段代码会调用 `array_new` 等运行时函数, 而 runtime-wasm 只实现了原始值。
const xs: number[] = [1, 2, 3];
console.log(xs.length);
