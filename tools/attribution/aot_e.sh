#!/usr/bin/env bash
#
# aot_e.sh — E 路（wasm × WAMR AOT）一键复现。
#
# 背景：WAMR AOT 文件格式不支持 import memory（aot_emit_aot_file.c 硬编码
# import_memory_count=0 + aot_validator.c 拒绝），demo 的双模块结构（app import
# rt.memory）无法整体 AOT。方案：wasm-merge（binaryen）把 app+rt 合并成单模块，
# wamrc 编译成 .aot，用 AOT 构建的 libiwasm.a 计时。详见 docs/performance.md E 路小节。
#
# 用法: tools/attribution/aot_e.sh [runs]   # 默认 12（第 1 轮 warmup 弃，取 11 样本中位数）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
BUILD="$ROOT/build"
WAMR_SRC="$ROOT/.deps/wamr"
AOT_BUILD="$BUILD/wamr-aot-build"
WABT="${WABT:-$HOME/.nvm/versions/node/v22.22.2/bin/wat2wasm}"   # 全局 wabt (npm -g)
WAMRC="${WAMRC:-/tmp/wamrc-test/wamrc}"   # wamrc-2.4.3（wamr-compiler 构建，见下）
RUNS="${1:-12}"

# ---------------------------------------------------------------- 0. 依赖
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
step "0/4 依赖"
# wamrc 只需 LLVM 含 x86 后端（wasm 走自研后端），系统 LLVM 14 即可，无需 build_llvm.sh：
#   cmake -S .deps/wamr/wamr-compiler -B /tmp/wamrc-test -DWAMR_BUILD_WITH_CUSTOM_LLVM=1 \
#     && cmake --build /tmp/wamrc-test -j
# 注意：CMakeLists 走 find_package(LLVM REQUIRED CONFIG)，默认路径能找到
# LLVMConfig.cmake 即可（/usr/lib/llvm-14/lib/cmake/llvm 在标准搜索路径；
# 传给 cmake 的 CUSTOM_LLVM_DIR 是无效变量，不用传）。
[ -x "$WAMRC" ] || { echo "缺 wamrc ($WAMRC) — 按上面命令构建"; exit 1; }
[ -x "$AOT_BUILD/iwasm" ] || {
  cmake -S "$WAMR_SRC/product-mini/platforms/linux" -B "$AOT_BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DWAMR_BUILD_INTERP=1 -DWAMR_BUILD_FAST_INTERP=1 \
    -DWAMR_BUILD_AOT=1 -DWAMR_BUILD_MULTI_MODULE=1 \
    -DWAMR_BUILD_WITH_CUSTOM_LLVM=1 \
    -DCMAKE_C_FLAGS="-I/usr/lib/llvm-14/include" \
    -DCMAKE_CXX_FLAGS="-I/usr/lib/llvm-14/include" \
    -DCMAKE_EXE_LINKER_FLAGS="-Wl,--export-dynamic"
  cmake --build "$AOT_BUILD" --target iwasm -j "$(nproc)"
}
[ -x "$BUILD/aot_time" ] || {
  gcc -O2 -Wall -Wextra -I "$WAMR_SRC/core/iwasm/include" \
    -o "$BUILD/aot_time" tools/attribution/aot_time.c \
    "$AOT_BUILD/libiwasm.a" -lm -ldl -lpthread
}

# ---------------------------------------------------------------- 1. 构建
step "构建 E: app+rt 合并单模块 -> wamrc AOT"
# 业务模块（patch-app-memory 产物）+ rt 模块合并；rt 的 memory 取代 app 的 import
"$ROOT/node_modules/.bin/wasm-merge" "$BUILD/bench_link.wasm" app \
  "$BUILD/rt_bench.wasm" rt \
  --enable-bulk-memory --enable-nontrapping-float-to-int \
  --enable-multimemory --enable-reference-types --rename-export-conflicts \
  -o "$BUILD/bench_merged_aot_src.wasm"
# 合并产物导出了 rt 的 __data_end/__heap_base（1129776），会与 app 栈指针（65536）
# 组合成非法 aux stack（WAMR loader 由此推 aux_stack_bottom=65536、boundary=0，
# _start 一跑即 "auxiliary stack underflow"）——织入 _initialize 调用并删掉这两个导出。
node tools/attribution/patch_merged.mjs \
  "$BUILD/bench_merged_aot_src.wasm" "$BUILD/bench_merged_patched.wat"
"$ROOT/node_modules/.bin/wasm-as" "$BUILD/bench_merged_patched.wat" \
  --enable-bulk-memory --enable-nontrapping-float-to-int \
  --enable-multimemory --enable-reference-types \
  -o "$BUILD/bench_merged_patched.wasm"
"$WAMRC" -o "$BUILD/bench_merged.aot" "$BUILD/bench_merged_patched.wasm"

step "构建 E': 干净对照 wasm -> wamrc AOT"
"$WABT" --enable-all tools/attribution/clean_bench.wat \
  -o "$BUILD/clean_bench.wasm"
"$WAMRC" -o "$BUILD/clean_bench.aot" "$BUILD/clean_bench.wasm"

# ---------------------------------------------------------------- 2. 正确性
step "校验: E/E' 输出与基准各路一致"
expect="fib(29) = 514229
sum = 499999500000"
out_e="$("$BUILD/aot_time" "$BUILD/bench_merged.aot" 1 2>/dev/null | grep -v '^RUN ' | sort -u)"
out_ep="$("$BUILD/aot_time" "$BUILD/clean_bench.aot" 1 2>/dev/null | grep -v '^RUN ' | sort -u)"
for name in e ep; do
  eval "out=\$out_$name"
  [ "$out" = "$expect" ] || { echo "输出不一致 ($name):"; echo "$out"; exit 1; }
done
echo "PASS: E/E' 输出一致 (fib(29) = 514229, sum = 499999500000)"

# ---------------------------------------------------------------- 3. 计时
step "计时: E（每轮独立进程，runner 内 1 次预热 + 1 次计时）"
vals=()
for i in $(seq 1 "$RUNS"); do
  out="$("$BUILD/aot_time" "$BUILD/bench_merged.aot" 1 | grep '^RUN ' | awk '{print $3}')"
  vals+=("$out")
done
for i in $(seq 1 "$RUNS"); do
  printf 'RUN %d %s\n' "$i" "${vals[$((i-1))]}"
done | tee "$BUILD/e_runs.txt"
printf '%s\n' "${vals[@]}" | tail -n +2 | sort -n | awk '{a[NR]=$1} END {printf "E  P50 = %.3f ms  min %.3f  max %.3f  (n=%d)\n", a[int((NR+1)/2)], a[1], a[NR], NR}'

step "计时: E'（runner 内 11 轮进程内循环）"
"$BUILD/aot_time" "$BUILD/clean_bench.aot" "$RUNS" | tee "$BUILD/eprime_runs.txt"
grep '^RUN ' "$BUILD/eprime_runs.txt" | awk '{print $3}' | tail -n +2 | sort -n |
  awk '{a[NR]=$1} END {printf "E\x27 P50 = %.3f ms  min %.3f  max %.3f  (n=%d)\n", a[int((NR+1)/2)], a[1], a[NR], NR}'
