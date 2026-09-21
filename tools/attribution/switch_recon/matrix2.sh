#!/bin/bash
# matrix2.sh — round 2: cpu/target, mllvm, combos, repeats
DEMO=/home/gem/project/perry_wasm_demo
WAMRC=/tmp/wamrc-test/wamrc
OUT=/tmp/rc_work
CLEAN=$DEMO/build/clean_bench.wasm
MERGED=$DEMO/build/bench_merged_patched.wasm

OPTS=(
  ""
  "--target=x86_64"
  "--target=x86_64 --cpu=x86-64-v3"
  "--target=x86_64 --cpu=x86-64-v2"
  "--target=x86_64 --cpu=znver4"
  "--target=x86_64 --cpu=skylake"
  "--target=x86_64 --cpu=haswell"
  "--target=x86_64 --cpu-features=+avx2"
  "--target=x86_64 --cpu-features=-avx2"
  "--target=x86_64 --cpu-features=+prefer-256-bit"
  "--enable-segue"
  "--enable-segue=all"
  "--opt-level=2 --enable-segue"
  "--opt-level=2"
  "--size-level=2 --enable-segue"
  "--enable-segue --disable-llvm-jump-tables"
  "--enable-segue --disable-llvm-intrinsics"
  "--enable-llvm-passes=inline,loop-unroll"
  "--mllvm=-inline-threshold=1000"
  "--mllvm=-unroll-threshold=100000"
  "--disable-llvm-lto --enable-segue"
)

echo "artifact|options|compile|size|median_ms|min_ms|samples"
for SPEC in "clean|$CLEAN" "merged|$MERGED"; do
  NAME="${SPEC%%|*}"; SRC="${SPEC#*|}"
  for O in "${OPTS[@]}"; do
    TAG="r2_$(echo "${NAME}_${O}" | tr -c 'A-Za-z0-9_.-' '_')"
    AOT="$OUT/$TAG.aot"
    # shellcheck disable=SC2086
    if $WAMRC $O -o "$AOT" "$SRC" >"$OUT/$TAG.log" 2>&1; then OK=ok; else OK=FAIL; fi
    if [ "$OK" = ok ] && [ -f "$AOT" ]; then
      SZ=$(stat -c %s "$AOT")
      if [ "$NAME" = clean ]; then
        RES=$(bash "$OUT/measure.sh" "$AOT" 12 1)
      else
        RES=$(bash "$OUT/measure.sh" "$AOT" 3 4)
      fi
      MS=$(echo "$RES" | awk '{print $1}'); MN=$(echo "$RES" | awk '{print $2}'); NS=$(echo "$RES" | awk '{print $3}')
    else
      SZ=0; MS=NA; MN=NA; NS=0
    fi
    echo "$NAME|${O:-<default>}|$OK|$SZ|$MS|$MN|$NS"
  done
done
