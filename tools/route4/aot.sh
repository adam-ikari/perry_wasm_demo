#!/usr/bin/env bash
#
# aot.sh — 路线四 AOT 形态复现，并与路线三同日 A/B（E 路同链路）。
#
# 背景: WAMR AOT 文件格式不支持 import memory（aot_emit_aot_file.c / aot_validator.c 硬编码），
# demo 的双模块结构（app import rt.memory）无法整体 AOT。与 tools/attribution/aot_e.sh 同链路:
#   wasm-merge(binaryen) 合并单模块 -> patch(织 _initialize wrapper) -> wasm-as -> wamrc -> aot_time
# 两份合并输入只差 rt 模块: 路线三 rt_bench.wasm（16,928 B） vs 路线四 rt4.wasm（~7.3 MB）。
# patch 用 tools/route4/patch_rt4_merged.mjs（宽容版: rt 侧无 __data_end/__heap_base 导出时跳过删除）。
#
# 计时口径与 aot_e.sh 一致: 每轮独立进程，进程内 1 次预热 + 1 次计时；A/B 每轮交错，
# 弃第 1 轮（机器预热），取余下 n-1 样本中位数。跨日数字不可比，A/B 必须同日成对读（论文 6.1）。
#
# 用法: tools/route4/aot.sh [runs]   # 默认 12（弃 1 取 11 样本中位数，与 aot_e.sh 同口径）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
BUILD="$ROOT/build"
WAMRC="${WAMRC:-/tmp/wamrc-test/wamrc}"
RUNS="${1:-12}"

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- 0. 依赖
step "0/4 依赖"
[ -x "$WAMRC" ] || { echo "缺 wamrc ($WAMRC) — 构建命令见 tools/attribution/aot_e.sh 头注"; exit 1; }
[ -x "$BUILD/aot_time" ] || { echo "缺 build/aot_time — 构建命令见 tools/attribution/aot_e.sh"; exit 1; }
[ -f "$BUILD/bench_link.wasm" ] || { echo "缺 build/bench_link.wasm — 先跑 ./demo.sh"; exit 1; }
[ -f "$BUILD/rt_bench.wasm" ] || { echo "缺 build/rt_bench.wasm — 先跑 ./demo.sh"; exit 1; }
[ -f "$BUILD/rt4.wasm" ] || { echo "缺 build/rt4.wasm — 先跑 tools/route4/build.sh"; exit 1; }
echo "wamrc: $WAMRC  aot_time: build/aot_time  runs: $RUNS"

MERGE="$ROOT/node_modules/.bin/wasm-merge"
AS="$ROOT/node_modules/.bin/wasm-as"

build_aot() {  # $1 = rt wasm 路径, $2 = tag (rt3|rt4)
  local rt="$1" tag="$2"
  "$MERGE" "$BUILD/bench_link.wasm" app "$rt" rt \
    --enable-bulk-memory --enable-nontrapping-float-to-int \
    --enable-multimemory --enable-reference-types --rename-export-conflicts \
    -o "$BUILD/aot_$tag.src.wasm"
  node "$ROOT/tools/route4/patch_rt4_merged.mjs" "$BUILD/aot_$tag.src.wasm" \
    "$BUILD/aot_$tag.patched.wat" | sed 's/^/  /'
  "$AS" "$BUILD/aot_$tag.patched.wat" \
    --enable-bulk-memory --enable-nontrapping-float-to-int \
    --enable-multimemory --enable-reference-types \
    -o "$BUILD/aot_$tag.patched.wasm"
  "$WAMRC" -o "$BUILD/aot_$tag.aot" "$BUILD/aot_$tag.patched.wasm"
  printf '  aot_%s.aot: %s B\n' "$tag" "$(stat -c %s "$BUILD/aot_$tag.aot")"
}

# ---------------------------------------------------------------- 1. 构建
step "1/4 构建: app+rt 合并单模块 -> wamrc AOT（rt3 / rt4 两份）"
build_aot "$BUILD/rt_bench.wasm" rt3
build_aot "$BUILD/rt4.wasm" rt4

# ---------------------------------------------------------------- 2. 正确性
step "2/4 校验: 两份 AOT 输出与基准一致"
expect="fib(29) = 514229
sum = 499999500000"
for tag in rt3 rt4; do
  out="$("$BUILD/aot_time" "$BUILD/aot_$tag.aot" 1 2>/dev/null | grep -v '^RUN ' | sort -u)"
  [ "$out" = "$expect" ] || { echo "输出不一致 ($tag):"; echo "$out"; exit 1; }
done
echo "PASS: rt3/rt4 AOT 输出均 == fib(29) = 514229, sum = 499999500000"

# ---------------------------------------------------------------- 3. 交错计时
step "3/4 交错计时: A=rt3（路线三 E 同链） B=rt4（路线四），每轮独立进程"
v3=(); v4=()
log="$BUILD/route4_aot_runs.txt"
: > "$log"
for i in $(seq 1 "$RUNS"); do
  a="$("$BUILD/aot_time" "$BUILD/aot_rt3.aot" 1 | grep '^RUN ' | awk '{print $3}')"
  b="$("$BUILD/aot_time" "$BUILD/aot_rt4.aot" 1 | grep '^RUN ' | awk '{print $3}')"
  v3+=("$a"); v4+=("$b")
  printf 'RUN %d rt3=%s rt4=%s\n' "$i" "$a" "$b" | tee -a "$log"
done

median() {  # 弃第 1 轮，取 n-1 样本中位数（与 aot_e.sh 同口径）
  printf '%s\n' "$@" | tail -n +2 | sort -n | awk '{a[NR]=$1} END {printf "%.3f", a[int((NR+1)/2)]}'
}
p3="$(median "${v3[@]}")"
p4="$(median "${v4[@]}")"

step "4/4 结果"
printf 'rt3（路线三 E 链） P50 = %s ms  (n=%d，弃第1轮)\n' "$p3" "$((RUNS - 1))"
printf 'rt4（路线四 AOT） P50 = %s ms  (n=%d，弃第1轮)\n' "$p4" "$((RUNS - 1))"
awk -v a="$p3" -v b="$p4" 'BEGIN {printf "rt4/rt3 = %.2f×  (同日交错，样本见 build/route4_aot_runs.txt)\n", b / a}'
