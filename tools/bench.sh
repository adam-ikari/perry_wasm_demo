#!/usr/bin/env bash
#
# bench.sh — perry wasm demo 性能基准, 一键可复现。
#
# 三路对照 (同一算法: 递归 fib(29) + 1e6 次循环累加):
#   A. WAMR 解释器 (FAST_INTERP)   build/bench_link.wasm + build/rt_bench.wasm
#                                  宿主: tools/bench_time.c (bench_time, 计时包装)
#   B. perry JS 宿主层 (V8)        node build/ref/run.mjs
#   C. 原生 gcc -O2                build/bench_native (tools/bench_native.c)
#
# 计时口径:
#   - 稳态: CLOCK_MONOTONIC。A/C 进程内 clock_gettime (RUN 行); B 用外层
#     bash time real (秒, TIMEFORMAT=%3R) 减去基线 node 启动 (node -e 空跑) 得纯执行时间。
#   - 每目标 11 次正式测, 前 1 次为 warmup; A 的单次执行含 warmup 打印 (execute_main 可重复跑)。
#   - 交错顺序 A B C × 11 轮, 避免热噪声系统性偏向某一个。
#   - 冷启动单独测: bash time real, 各 5 次。
#
# 输出: 三路表格 (中位数/最小值/最大值) + 冷启动表, 数字写入 build/bench_results.txt。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BUILD="$ROOT/build"
RUNS=11
COLD=5
mkdir -p "$BUILD"
RESULTS="$BUILD/bench_results.txt"
: > "$RESULTS"

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- 1. 构建

step "构建 A: bench.ts -> wasm -> rt 桩 -> 链接模块"
node tools/build-wasm.mjs src/bench.ts --bare build/bench.wasm
node tools/gen-rt-symbols.mjs build/bench.wasm \
  --rust runtime-wasm/src/lib.rs build/rt_symbols.rs
cargo build --release --target wasm32-unknown-unknown --manifest-path runtime-wasm/Cargo.toml -q
cp runtime-wasm/target/wasm32-unknown-unknown/release/perry_rt_wasm.wasm build/rt_bench.wasm
node tools/patch-app-memory.mjs build/bench.wasm build/bench_link.wasm

WAMR_SRC="$ROOT/.deps/wamr"
WAMR_BUILD="$ROOT/.deps/wamr-build"
[ -f "$WAMR_BUILD/libiwasm.a" ] || { echo "缺 $WAMR_BUILD/libiwasm.a — 先跑 ./demo.sh"; exit 1; }
step "构建宿主计时器 bench_time"
gcc -O2 -Wall -Wextra -I "$WAMR_SRC/core/iwasm/include" \
  -o build/bench_time tools/bench_time.c "$WAMR_BUILD/libiwasm.a" -lm -ldl -lpthread

step "构建 B: perry JS 宿主层参照 (wasmBoot)"
node -e '
import("@typerry/node").then(({ wasmBoot }) => {
  const { readFileSync, writeFileSync, mkdirSync } = require("node:fs");
  const source = require("node:fs").readFileSync("src/bench.ts", "utf8");
  mkdirSync("build/ref", { recursive: true });
  const ref = wasmBoot(source, "", true, false);
  writeFileSync("build/ref/run.mjs", ref.runtime);
  writeFileSync("build/ref/run.wasm", Buffer.from(ref.wasm));
  console.log("build/ref/run.mjs:", ref.runtime.length, "chars");
});'

step "构建 C: 原生基线 gcc -O2"
gcc -O2 -Wall -Wextra -o build/bench_native tools/bench_native.c

# ---------------------------------------------------------------- 2. 正确性校验

step "校验: 三路输出必须一致"
expect="fib(29) = 514229
sum = 499999500000"
out_a="$(./build/bench_time build/bench_link.wasm build/rt_bench.wasm 1 2>/dev/null | grep -vE '^(INIT_MS|RUN )' | sort -u)"
out_b="$(node build/ref/run.mjs)"
out_c="$(./build/bench_native 1 | grep -v '^RUN ' | sort -u)"
for name in a b c; do
  eval "out=\$out_$name"
  [ "$out" = "$expect" ] || { echo "输出不一致 ($name):"; echo "$out"; exit 1; }
done
echo "PASS: A/B/C 输出一致 (fib(29) = 514229, sum = 499999500000)"

# ---------------------------------------------------------------- 3. 基线: node 启动开销 (从 B 的 real 里扣除)

# real 时间 (毫秒): bash 内建 time + TIMEFORMAT=%3R (秒, 3 位精度)。本机无 /usr/bin/time。
real_ms() {
  local out
  out="$( { TIMEFORMAT='%3R'; time "$@" >/dev/null 2>&1; } 2>&1 1>/dev/null )"
  awk -v s="$out" 'BEGIN{printf "%.3f", s*1000}'
}

node_base_ms() {
  local vals=()
  for _ in 1 2 3 4 5; do
    vals+=("$(real_ms node -e '')")
  done
  printf '%s\n' "${vals[@]}" | sort -n | awk '{a[NR]=$1} END {printf "%.0f", a[int(NR/2)+1]}'
}
BASE_MS="$(node_base_ms)"
echo "node 进程启动基线 (中位数): ${BASE_MS} ms" | tee -a "$RESULTS"

# ---------------------------------------------------------------- 4. 交错测稳态

median() { sort -n | awk '{a[NR]=$1} END {printf "%.3f", a[int(NR/2)+1]}'; }
min()    { sort -n | head -1; }
max()    { sort -n | tail -1; }

step "稳态测量: 交错 A B C × $RUNS 轮 (前 1 轮为 warmup)"
a_runs="$BUILD/a_runs.txt"; b_runs="$BUILD/b_runs.txt"; c_runs="$BUILD/c_runs.txt"
: > "$a_runs"; : > "$b_runs"; : > "$c_runs"

for round in $(seq 1 "$RUNS"); do
  # A: 一次进程跑 1 次执行 (RUN 1 行), 进程级隔离避免实例状态残留
  ./build/bench_time build/bench_link.wasm build/rt_bench.wasm 1 2>/dev/null |
    awk '/^RUN /{print $3}' >> "$a_runs"
  # B: real (含 node 启动), 之后再扣除启动基线
  echo "$(real_ms node build/ref/run.mjs)" >> "$b_runs"
  # C
  ./build/bench_native 1 | awk '/^RUN /{print $3}' >> "$c_runs"
done
# warmup = 每文件第 1 行, 丢掉
for f in "$a_runs" "$b_runs" "$c_runs"; do
  sed -i '1d' "$f"
done
# B 扣除 node 启动基线
awk -v base="$BASE_MS" '{printf "%.3f\n", ($1 > base ? $1 - base : $1)}' "$b_runs" > "$b_runs.net"
mv "$b_runs.net" "$b_runs"

# ---------------------------------------------------------------- 5. 冷启动 (进程启动 -> 开始计算 -> 完成)

step "冷启动测量: bash time real × $COLD"
cold() { # $1=标签 $2...=命令; 输出 "标签 中位数 最小" (毫秒)
  local tag="$1"; shift
  local vals=()
  for _ in $(seq 1 "$COLD"); do
    vals+=("$(real_ms "$@")")
  done
  printf '%s\n' "${vals[@]}" | sort -n | awk -v t="$tag" \
    '{a[NR]=$1} END {printf "%s %.3f %.3f\n", t, a[int(NR/2)+1], a[1]}'
}
cold "A_WAMR" ./build/bench_time build/bench_link.wasm build/rt_bench.wasm 1 |
  awk '{print "COLD A_WAMR", $2, $3}' >> "$RESULTS"
# A 的进程内 INIT_MS (main 入口 -> 实例化完成) 更精确, 单独采 5 次
for _ in $(seq 1 5); do
  ./build/bench_time build/bench_link.wasm build/rt_bench.wasm 1 2>/dev/null |
    awk '/^INIT_MS/{print $2}'
done | awk '{s[NR]=$1} END {printf "COLD A_INIT_MS(in-process) %.3f %.3f\n", s[int(NR/2)+1], s[1]}' >> "$RESULTS"
cold "B_node" node build/ref/run.mjs |
  awk '{print "COLD B_node", $2, $3}' >> "$RESULTS"
cold "C_native" ./build/bench_native 1 |
  awk '{print "COLD C_native", $2, $3}' >> "$RESULTS"

# ---------------------------------------------------------------- 6. 汇总表格

step "结果汇总 (毫秒)"
{
  printf '文件: %s\n' "$a_runs $b_runs $c_runs"
  printf '样本: A/B/C 各 %d 次 (去掉 1 次 warmup)\n' $((RUNS - 1))
  printf 'B 已扣除 node 启动基线 %s ms (中位数, 5 次)\n' "$BASE_MS"
  printf '\n%-10s %12s %12s %12s\n' 目标 中位数 最小 最大
  printf '%-10s %12s %12s %12s\n' '----------' '-----------' '-----------' '-----------'
  for t in a b c; do
    eval "f=\$${t}_runs"
    printf '%-10s %12s %12s %12s\n' "$t" \
      "$(median < "$f")" "$(min < "$f")" "$(max < "$f")"
  done
  printf '\n倍数 (以 C 为 1):\n'
  c_med="$(median < "$c_runs")"
  for t in a b c; do
    eval "f=\$${t}_runs"
    m="$(median < "$f")"
    awk -v m="$m" -v c="$c_med" -v t="$t" 'BEGIN{printf "%s: %.1fx\n", t, m/c}'
  done
  printf '\n冷启动 (中位数/最小, 毫秒, bash time real):\n'
  cat "$RESULTS" | grep '^COLD'
} | tee "$BUILD/bench_table.txt"
echo
echo "明细: $a_runs $b_runs $c_runs"
echo "汇总: $BUILD/bench_table.txt"
