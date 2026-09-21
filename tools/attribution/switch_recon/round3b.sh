#!/bin/bash
# round3b.sh — cpu-features variants + binaryen wasm-opt preprocessing
DEMO=/home/gem/project/perry_wasm_demo
WAMRC=/tmp/wamrc-test/wamrc
WASMOPT=$DEMO/node_modules/.bin/wasm-opt
OUT=/tmp/rc_work
CLEAN=$DEMO/build/clean_bench.wasm
MERGED=$DEMO/build/bench_merged_patched.wasm
FEAT="--enable-bulk-memory --enable-nontrapping-float-to-int --enable-multimemory --enable-reference-types"

measure() { # $1 aot, $2 clean|merged
  if [ "$2" = clean ]; then RES=$(bash "$OUT/measure.sh" "$1" 24 1); else RES=$(bash "$OUT/measure.sh" "$1" 3 8); fi
  echo "$RES"
}

echo "artifact|label|size|median_ms|min_ms|samples|output_correct"

# --- cpu-features (needs explicit --target + --cpu) ---
for F in "" "+avx2" "-avx2" "+avx512f" "+prefer-256-bit" "-prefer-256-bit"; do
  for SPEC in "clean|$CLEAN" "merged|$MERGED"; do
    NAME="${SPEC%%|*}"; SRC="${SPEC#*|}"
    AOT="$OUT/r3b_cf_${NAME}_$(echo "$F" | tr -c 'A-Za-z0-9' '_').aot"
    OF=""
    [ -n "$F" ] && OF="--cpu-features=$F"
    # shellcheck disable=SC2086
    if ! $WAMRC --target=x86_64 --cpu=znver3 $OF -o "$AOT" "$SRC" >"$AOT.log" 2>&1; then
      echo "$NAME|cpu-features=${F:-<none>}|FAIL||||"; continue; fi
    SZ=$(stat -c %s "$AOT"); R=$(measure "$AOT" "$NAME")
    C=$("$DEMO/build/aot_time" "$AOT" 1 2>/dev/null | grep -c 'sum = 499999500000')
    echo "$NAME|cpu-features=${F:-<none>}|$SZ|$(echo $R|awk '{print $1}')|$(echo $R|awk '{print $2}')|$(echo $R|awk '{print $3}')|$C"
  done
done

# --- binaryen wasm-opt preprocessing of the merged module ---
for O in "-O2" "-O3" "-O4" "-O3 --flatten" "-O3 --inlining-optimizing" "-O3 --always-inline-max-function-size=200"; do
  TAG=$(echo "$O" | tr -c 'A-Za-z0-9' '_')
  PRE="$OUT/opt_${TAG}.wasm"
  # shellcheck disable=SC2086
  if ! $WASMOPT $FEAT $O "$MERGED" -o "$PRE" >"$OUT/opt_${TAG}.log" 2>&1; then
    echo "merged|wasm-opt $O|FAIL|$(tr '\n' ' ' < "$OUT/opt_${TAG}.log" | cut -c1-150)|||"; continue
  fi
  for W in "" "--enable-segue --disable-llvm-jump-tables"; do
    AOT="$OUT/r3b_wo_${TAG}_$(echo "$W" | tr -c 'A-Za-z0-9' '_').aot"
    # shellcheck disable=SC2086
    if ! $WAMRC $W -o "$AOT" "$PRE" >"$AOT.log" 2>&1; then
      echo "merged|wasm-opt $O + wamrc [${W:-<default>}]|FAIL||||"; continue; fi
    SZ=$(stat -c %s "$AOT"); R=$(measure "$AOT" merged)
    C=$("$DEMO/build/aot_time" "$AOT" 1 2>/dev/null | grep -c 'sum = 499999500000')
    echo "merged|wasm-opt $O (pre=$(stat -c %s "$PRE")) + wamrc [${W:-<default>}]|$SZ|$(echo $R|awk '{print $1}')|$(echo $R|awk '{print $2}')|$(echo $R|awk '{print $3}')|$C"
  done
done

# --- wasm-opt on clean control ---
for O in "-O3"; do
  TAG=$(echo "$O" | tr -c 'A-Za-z0-9' '_')
  PRE="$OUT/optc_${TAG}.wasm"
  # shellcheck disable=SC2086
  $WASMOPT $FEAT $O "$CLEAN" -o "$PRE" >"$OUT/optc_${TAG}.log" 2>&1
  AOT="$OUT/r3b_wo_clean_${TAG}.aot"
  $WAMRC -o "$AOT" "$PRE" >"$AOT.log" 2>&1
  SZ=$(stat -c %s "$AOT"); R=$(measure "$AOT" clean)
  C=$("$DEMO/build/aot_time" "$AOT" 1 2>/dev/null | grep -c 'sum = 499999500000')
  echo "clean|wasm-opt $O (pre=$(stat -c %s "$PRE"))|$SZ|$(echo $R|awk '{print $1}')|$(echo $R|awk '{print $2}')|$(echo $R|awk '{print $3}')|$C"
done
