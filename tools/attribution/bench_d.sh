#!/usr/bin/env bash
#
# bench_d.sh — D 路 (perry 原生后端) 单路复现脚本。
#
# 下载/校验 perry 预编译 release，把 src/bench.ts 编译成原生可执行，
# 用进程级包装计时 11 轮取中位数。编译器本体放 /tmp，不进项目目录。
#
# 用法: tools/attribution/bench_d.sh [runs]   (默认 11, 第 1 轮 warmup)
#
# 计时口径: tools/attribution/bench_perry_wrap.c 对整个进程 fork/exec + waitpid
# 计时 (CLOCK_MONOTONIC)。perry 产物无多轮入口且单次执行 <1ms 量级,
# bash time (10ms 粒度) 无法分辨, 故用此法; 空载 fork+exec+/bin/true
# 基线 P50 ≈ 0.6 ms, 已含在数字里 (对 A/B/C 口径保守, 对 D 不利)。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
BUILD="$ROOT/build"
mkdir -p "$BUILD"
RUNS="${1:-11}"

PERRY_VER="v0.5.1520"
PERRY_URL="https://github.com/PerryTS/perry/releases/download/${PERRY_VER}/perry-linux-x86_64.tar.gz"
PERRY_SHA256="3423d9fea9bce9b2011fa53b5788a5ca115c947352b5c67278147de30fd2f952"
PERRY_DIST="/tmp/perry-dist"
PERRY_TGZ="/tmp/perry-dl.tar.gz"

if [ ! -x "$PERRY_DIST/perry" ]; then
  echo "== 下载 perry ${PERRY_VER} (linux x86_64, ~625 MB, 断点续传) =="
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -sL --retry 5 -C - -o "$PERRY_TGZ" "$PERRY_URL" && break
    sleep 5
  done
  echo "$PERRY_SHA256  $PERRY_TGZ" | sha256sum -c -
  rm -rf "$PERRY_DIST"
  mkdir -p "$PERRY_DIST"
  tar xzf "$PERRY_TGZ" -C "$PERRY_DIST"
fi
"$PERRY_DIST/perry" --version

echo "== 编译 src/bench.ts -> build/bench_perry_native =="
if [ ! -x "$BUILD/bench_perry_native" ]; then
  "$PERRY_DIST/perry" compile src/bench.ts -o build/bench_perry_native
fi
ls -la "$BUILD/bench_perry_native"

echo "== 校验输出 =="
out="$("$BUILD/bench_perry_native")"
expect='fib(29) = 514229
sum = 499999500000'
[ "$out" = "$expect" ] || { echo "输出不一致:"; echo "$out"; exit 1; }
echo "PASS: D 路输出与 A/B/C 一致"

echo "== 编译计时包装 =="
gcc -O2 -Wall -Wextra -o build/bench_perry_wrap tools/attribution/bench_perry_wrap.c

echo "== 计时 ${RUNS} 轮 (第 1 轮 warmup) =="
"$BUILD/bench_perry_wrap" "$BUILD/bench_perry_native" "$RUNS" | tee "$BUILD/d_runs.txt" | \
  awk '$1=="RUN"{print $3}' | sort -n | awk -v n="$RUNS" '
    {a[NR]=$1} END {print "D 路 P50 = " a[int(NR/2)+1] " ms  min=" a[1] "  max=" a[NR]}'
