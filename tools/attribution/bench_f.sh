#!/usr/bin/env bash
#
# bench_f.sh — F 路 (QuickJS 直接解释执行 JS) 一键复现。
#
# 依赖: /tmp/quickjs-bellard/qjs (Bellard 官方 quickjs, make qjs 构建; 不在项目目录)。
# 计时: qjs 单次执行需 argv (脚本路径), 用 bench_exec_wrap.c 进程级 fork/exec + waitpid
#       (CLOCK_MONOTONIC), qjs 空载基线 ~0.95ms 实测。样本 11 轮, 第 1 轮 warmup 弃,
#       取 10 样本中位数 (与 A/B/C/D/E 各路口径一致)。
#
# 用法: tools/attribution/bench_f.sh [runs]   # 默认 11
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
BUILD="$ROOT/build"
QJS="${QJS:-/tmp/quickjs-bellard/qjs}"
RUNS="${1:-11}"

[ -x "$QJS" ] || { echo "缺 qjs ($QJS) — 按 docs/paper/perry-wasm-paper.md 附录 B「F. QuickJS 对照」构建 Bellard quickjs"; exit 1; }
[ -x "$BUILD/bench_exec_wrap" ] || {
  gcc -O2 -Wall -Wextra -o "$BUILD/bench_exec_wrap" \
    "$ROOT/tools/attribution/bench_exec_wrap.c"; }

# 1. 正确性: 输出与基准各路径一致
expect="fib(29) = 514229
sum = 499999500000"
out="$("$QJS" "$ROOT/tools/attribution/bench_quickjs.js" 2>/dev/null)"
[ "$out" = "$expect" ] || { echo "输出不一致:"; echo "$out"; echo "期望:"; echo "$expect"; exit 1; }
echo "PASS: F 输出一致 (fib(29) = 514229, sum = 499999500000)"

# 2. 计时: 进程级 fork/exec + waitpid, RUNS 轮 (第 1 轮 warmup 弃)
"$BUILD/bench_exec_wrap" "$QJS" "$ROOT/tools/attribution/bench_quickjs.js" "$RUNS" 2>/dev/null \
  | tee build/f_runs.txt
p50=$(tail -n +2 build/f_runs.txt | awk '{print $3}' | sort -n \
      | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
echo "P50 $p50 (runs=$((RUNS-1)) 第1轮 warmup 弃)"
