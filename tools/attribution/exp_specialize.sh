#!/usr/bin/env bash
#
# exp_specialize.sh — 实验 B: 等价手工类型特化, 量化 "perry-codegen-wasm 修好
# 类型特化后 E 的上限"。
#
# 三档:
#   B1 (spec_B1_add.wat)   热路径 `+` 内联 f64.add, is_truthy 桥保留
#   B2 (spec_B2_full.wat)  `+` 与 is_truthy 全内联, NaN-box + 影子栈纪律保留
#   V3 (specialized_bench_f64.wat)  纯 f64, 无盒无影子栈 (全去 NaN-box 版)
#
# 结论 (2026-09-21 实测): B1=76.2ms, B2=17.9ms (E 的 13.7%, 快 7.3×),
# V3=3.7ms, E'(clean i64)=1.25ms。B2 即 "保留 NaN-box 与影子栈的 codegen
# 特化上限"; B2→E' 的余量是影子栈内存纪律, 需 typed ABI 级改造 (路径 4)。
#
# 用法: tools/attribution/exp_specialize.sh [runs]   # 默认 12
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
BUILD="$ROOT/build"
WASM_AS="$ROOT/node_modules/.bin/wasm-as"
WABT="${WABT:-$HOME/.nvm/versions/node/v22.22.2/bin/wat2wasm}"
WAMRC="${WAMRC:-/tmp/wamrc-test/wamrc}"
RUNS="${1:-12}"
FEAT="--enable-bulk-memory --enable-nontrapping-float-to-int --enable-multimemory --enable-reference-types"
expect="fib(29) = 514229
sum = 499999500000"

[ -f "$BUILD/bench_merged_patched.wat" ] || { echo "缺 $BUILD/bench_merged_patched.wat — 先跑 tools/attribution/aot_e.sh"; exit 1; }
[ -x "$BUILD/aot_time" ] || { echo "缺 $BUILD/aot_time"; exit 1; }

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

p50() {
  local aot="$1" label="$2"
  local vals=() v
  for i in $(seq 1 "$RUNS"); do
    v="$("$BUILD/aot_time" "$aot" 1 2>/dev/null | grep '^RUN ' | awk '{print $3}')"
    [ -n "$v" ] && vals+=("$v")
  done
  printf '%s\n' "${vals[@]:1}" | sort -n | awk -v n="$label" \
    '{a[NR]=$1} END {printf "%s P50 = %.3f ms  min %.3f  max %.3f  (n=%d)\n", n, a[int((NR+1)/2)], a[1], a[NR], NR}'
}

verify() {
  local out
  out="$("$BUILD/aot_time" "$1" 1 2>/dev/null | grep -v '^RUN ' | sort -u)"
  [ "$out" = "$expect" ] || { echo "输出不一致 ($2):"; echo "$out"; exit 1; }
  echo "PASS 输出一致 ($2): fib(29) = 514229, sum = 499999500000"
}

step "0/4 生成 B1/B2 (等价手工特化, 基于 aot_e.sh 的合并产物)"
python3 tools/attribution/spec_patch.py

step "1/4 装配 + wamrc"
"$WASM_AS" $FEAT "$BUILD/spec_B1_add.wat" -o "$BUILD/spec_B1_add.wasm"
"$WASM_AS" $FEAT "$BUILD/spec_B2_full.wat" -o "$BUILD/spec_B2_full.wasm"
"$WABT" --enable-all tools/attribution/specialized_bench_f64.wat -o "$BUILD/spec_V3_f64.wasm"
"$WAMRC" -o "$BUILD/spec_B1_add.aot" "$BUILD/spec_B1_add.wasm" 2>/dev/null
"$WAMRC" -o "$BUILD/spec_B2_full.aot" "$BUILD/spec_B2_full.wasm" 2>/dev/null
"$WAMRC" -o "$BUILD/spec_V3_f64.aot" "$BUILD/spec_V3_f64.wasm" 2>/dev/null

step "2/4 正确性 (输出必须与 E 路逐字节一致)"
verify "$BUILD/spec_B1_add.aot" B1_spec_add
verify "$BUILD/spec_B2_full.aot" B2_spec_full
verify "$BUILD/spec_V3_f64.aot" V3_f64

step "3/4 基线对照 (同口径)"
p50 "$BUILD/bench_merged.aot" "E_baseline"
p50 "$BUILD/clean_bench.aot" "Eprime_clean_i64"

step "4/4 计时"
p50 "$BUILD/spec_B1_add.aot" "B1_spec_add"
p50 "$BUILD/spec_B2_full.aot" "B2_spec_full"
p50 "$BUILD/spec_V3_f64.aot" "V3_f64_pure"
