#!/usr/bin/env bash
#
# exp_wasmopt.sh — 实验 A: wasm-opt 后处理能否把桥内联/折叠掉 (廉价修复探针)。
#
# 结论 (2026-09-21 实测): 强制 always-inline 能把整条 mem_call+invoke 内联进
# fib/loop, 字面 nameId 常量传播成功, 但 NAME_CACHE 的运行时内存 load
# (i32.load8_u offset=1051877+nameId) 无法常量折叠 → 11 路 br_table 分派 +
# 完整 miss 路径字符串查找代码原样留在内联体里。P50 131.2 → 98.0 ms (-25%),
# 远达不到 B 实验的手工特化 (17.9 ms)。wasm-opt 无 "nameId→直接调桥" pass。
#
# 用法: tools/attribution/exp_wasmopt.sh [runs]   # 默认 12 (弃第 1 轮, 取 11 样本中位数)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
BUILD="$ROOT/build"
OUT="$BUILD/wasmopt_exp"
WOPT="$ROOT/node_modules/.bin/wasm-opt"
WAMRC="${WAMRC:-/tmp/wamrc-test/wamrc}"
RUNS="${1:-12}"
FEAT="--enable-bulk-memory --enable-nontrapping-float-to-int --enable-multimemory --enable-reference-types"
expect="fib(29) = 514229
sum = 499999500000"

[ -f "$BUILD/bench_merged_patched.wasm" ] || { echo "缺 $BUILD/bench_merged_patched.wasm — 先跑 tools/attribution/aot_e.sh"; exit 1; }
[ -x "$WOPT" ] || { echo "缺 wasm-opt (node_modules/.bin)"; exit 1; }
[ -x "$WAMRC" ] || { echo "缺 wamrc ($WAMRC)"; exit 1; }
[ -x "$BUILD/aot_time" ] || { echo "缺 $BUILD/aot_time"; exit 1; }
mkdir -p "$OUT"

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

p50() {  # p50 <aot> <label> : 12 轮计时, 弃第 1 轮取中位数
  local aot="$1" label="$2"
  local vals=() v
  for i in $(seq 1 "$RUNS"); do
    v="$("$BUILD/aot_time" "$aot" 1 2>/dev/null | grep '^RUN ' | awk '{print $3}')"
    [ -n "$v" ] && vals+=("$v")
  done
  printf '%s\n' "${vals[@]:1}" | sort -n | awk -v n="$label" \
    '{a[NR]=$1} END {printf "%s P50 = %.3f ms  min %.3f  max %.3f  (n=%d)\n", n, a[int((NR+1)/2)], a[1], a[NR], NR}'
}

verify() {  # verify <aot> <label> : 输出必须与基准逐字节一致
  local out
  out="$("$BUILD/aot_time" "$1" 1 2>/dev/null | grep -v '^RUN ' | sort -u)"
  [ "$out" = "$expect" ] || { echo "输出不一致 ($2):"; echo "$out"; exit 1; }
  echo "PASS 输出一致 ($2): fib(29) = 514229, sum = 499999500000"
}

step "1/3 基线 E (未优化)"
p50 "$BUILD/bench_merged.aot" "E_baseline"

step "2/3 wasm-opt 变体 (全部需先过正确性)"
for spec in \
  "A1_O3:-O3" \
  "A2_O3_ai10000:-O3 --always-inline-max-function-size=10000" \
  "A5_inl5000:--inlining-optimizing --always-inline-max-function-size=5000 --precompute-propagate --dce"; do
  name="${spec%%:*}"; flags="${spec#*:}"
  $WOPT $flags $FEAT "$BUILD/bench_merged_patched.wasm" -o "$OUT/$name.wasm"
  $WAMRC -o "$OUT/$name.aot" "$OUT/$name.wasm" 2>/dev/null
  verify "$OUT/$name.aot" "$name"
done

step "3/3 计时"
p50 "$OUT/A1_O3.aot" "A1_-O3"
p50 "$OUT/A2_O3_ai10000.aot" "A2_-O3_ai10000"
p50 "$OUT/A5_inl5000.aot" "A5_inl5000"
echo
echo "注: A3(-O4 ai10000)/A4(ai10000+precompute) 与 A2/A5 同量级 (101/101 ms), 已略。"
echo "产物在 $OUT/ (wasm/aot); wasm-dis 可查内联后残留的 br_table 分派。"
