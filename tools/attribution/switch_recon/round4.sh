#!/bin/bash
# round4.sh — interleaved A/B confirmation: default vs best combos
DEMO=/home/gem/project/perry_wasm_demo
WAMRC=/tmp/wamrc-test/wamrc
OUT=/tmp/rc_work
CLEAN=$DEMO/build/clean_bench.wasm
MERGED=$DEMO/build/bench_merged_patched.wasm

CANDS=(
  "default|"
  "best|--target=x86_64 --enable-segue --disable-llvm-jump-tables"
  "best_min|--target=x86_64 --size-level=2 --enable-segue --disable-llvm-jump-tables"
  "best_O2|--target=x86_64 --opt-level=2 --enable-segue --disable-llvm-jump-tables"
  "best_nobounds|--target=x86_64 --enable-segue --disable-llvm-jump-tables --bounds-checks=0 --stack-bounds-checks=0 --disable-aux-stack-check"
  "best_tailcall|--target=x86_64 --enable-segue --disable-llvm-jump-tables --enable-tail-call"
  "target_segue|--target=x86_64 --enable-segue"
  "target_nojt|--target=x86_64 --disable-llvm-jump-tables"
  "v3_best|--target=x86_64 --cpu=x86-64-v3 --enable-segue --disable-llvm-jump-tables"
)

echo "round|artifact|cand|size|median_ms|min_ms|samples|correct"
# pre-compile all
declare -A AOT
for SPEC in "clean|$CLEAN" "merged|$MERGED"; do
  NAME="${SPEC%%|*}"; SRC="${SPEC#*|}"
  for C in "${CANDS[@]}"; do
    LABEL="${C%%|*}"; O="${C#*|}"
    A="$OUT/r4_${NAME}_${LABEL}.aot"
    # shellcheck disable=SC2086
    $WAMRC $O -o "$A" "$SRC" >"$A.log" 2>&1 || echo "COMPILE-FAIL $NAME $LABEL"
    AOT["$NAME|$LABEL"]="$A"
  done
done

# interleave 3 repetitions of the whole set
for rep in 1 2 3; do
  for SPEC in "clean|$CLEAN" "merged|$MERGED"; do
    NAME="${SPEC%%|*}"
    for C in "${CANDS[@]}"; do
      LABEL="${C%%|*}"; A="${AOT["$NAME|$LABEL"]}"
      [ -f "$A" ] || continue
      SZ=$(stat -c %s "$A")
      if [ "$NAME" = clean ]; then RES=$(bash "$OUT/measure.sh" "$A" 12 1); else RES=$(bash "$OUT/measure.sh" "$A" 3 4); fi
      CORR=$("$DEMO/build/aot_time" "$A" 1 2>/dev/null | grep -c 'sum = 499999500000')
      echo "$rep|$NAME|$LABEL|$SZ|$(echo $RES|awk '{print $1}')|$(echo $RES|awk '{print $2}')|$(echo $RES|awk '{print $3}')|$CORR"
    done
  done
done
