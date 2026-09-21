#!/bin/bash
# round5.sh — remaining feature/profiling flags + opt/size-level overflow
DEMO=/home/gem/project/perry_wasm_demo
WAMRC=/tmp/wamrc-test/wamrc
OUT=/tmp/rc_work
MERGED=$DEMO/build/bench_merged_patched.wasm

CANDS=(
  "default|"
  "O4|--opt-level=4"
  "size4|--size-level=4"
  "noreftypes|--disable-ref-types"
  "dumpcallstack|--enable-dump-call-stack"
  "linuxperf|--enable-linux-perf"
  "perfprof|--enable-perf-profiling"
  "memprof|--enable-memory-profiling"
)

echo "cand|size|median_ms|min_ms|samples|correct"
for C in "${CANDS[@]}"; do
  LABEL="${C%%|*}"; O="${C#*|}"
  A="$OUT/r5_$LABEL.aot"
  # shellcheck disable=SC2086
  if ! $WAMRC $O -o "$A" "$MERGED" >"$A.log" 2>&1; then echo "$LABEL|FAIL: $(tr '\n' ' ' < "$A.log"|cut -c1-120)||||"; continue; fi
  SZ=$(stat -c %s "$A")
  R=$(bash "$OUT/measure.sh" "$A" 3 4)
  CORR=$("$DEMO/build/aot_time" "$A" 1 2>/dev/null | grep -c 'sum = 499999500000')
  echo "$LABEL|$SZ|$(echo $R|awk '{print $1}')|$(echo $R|awk '{print $2}')|$(echo $R|awk '{print $3}')|$CORR"
done
