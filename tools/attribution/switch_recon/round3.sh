#!/bin/bash
# round3.sh — confirm top candidates with more samples + correctness check
DEMO=/home/gem/project/perry_wasm_demo
WAMRC=/tmp/wamrc-test/wamrc
OUT=/tmp/rc_work
CLEAN=$DEMO/build/clean_bench.wasm
MERGED=$DEMO/build/bench_merged_patched.wasm

CANDS=(
  "default|"
  "segue|--enable-segue"
  "segue_nojt|--enable-segue --disable-llvm-jump-tables"
  "tgt_segue_nojt|--target=x86_64 --enable-segue --disable-llvm-jump-tables"
  "tgt_only|--target=x86_64"
  "tgt_v3_segue_nojt|--target=x86_64 --cpu=x86-64-v3 --enable-segue --disable-llvm-jump-tables"
  "O2|--opt-level=2"
  "segue_nolto|--disable-llvm-lto --enable-segue"
)

echo "artifact|cand|options|size|median_ms|min_ms|samples|output_correct"
for SPEC in "clean|$CLEAN" "merged|$MERGED"; do
  NAME="${SPEC%%|*}"; SRC="${SPEC#*|}"
  for C in "${CANDS[@]}"; do
    LABEL="${C%%|*}"; O="${C#*|}"
    AOT="$OUT/r3_${NAME}_${LABEL}.aot"
    # shellcheck disable=SC2086
    if ! $WAMRC $O -o "$AOT" "$SRC" >"$OUT/r3_${NAME}_${LABEL}.log" 2>&1; then
      echo "$NAME|$LABEL|${O:-<default>}|FAIL|||0|"; continue
    fi
    SZ=$(stat -c %s "$AOT")
    if [ "$NAME" = clean ]; then RES=$(bash "$OUT/measure.sh" "$AOT" 24 1)
    else RES=$(bash "$OUT/measure.sh" "$AOT" 3 8); fi
    MS=$(echo "$RES" | awk '{print $1}'); MN=$(echo "$RES" | awk '{print $2}'); NS=$(echo "$RES" | awk '{print $3}')
    CORR=$("$DEMO/build/aot_time" "$AOT" 1 2>/dev/null | grep -c 'sum = 499999500000')
    echo "$NAME|$LABEL|${O:-<default>}|$SZ|$MS|$MN|$NS|$CORR"
  done
done
