#!/bin/bash
# matrix.sh — sweep wamrc options over clean_bench.wasm and bench_merged_patched.wasm
DEMO=/home/gem/project/perry_wasm_demo
WAMRC=/tmp/wamrc-test/wamrc
OUT=/tmp/rc_work
CLEAN=$DEMO/build/clean_bench.wasm
MERGED=$DEMO/build/bench_merged_patched.wasm

OPTS=(
  ""
  "--opt-level=0"
  "--opt-level=1"
  "--opt-level=2"
  "--size-level=0"
  "--size-level=1"
  "--size-level=2"
  "--bounds-checks=0"
  "--stack-bounds-checks=0"
  "--disable-aux-stack-check"
  "--enable-tail-call"
  "--disable-llvm-intrinsics"
  "--enable-segue"
  "--enable-segue=i32.load,i32.store"
  "--enable-indirect-mode"
  "--xip"
  "--disable-llvm-lto"
  "--disable-llvm-jump-tables"
  "--enable-llvm-passes=default<O3>"
  "--disable-simd"
  "--enable-multi-thread"
  "--cpu=znver3"
  "--cpu=znver4"
  "--cpu=x86-64-v3"
  "--cpu-features=+avx2"
  "--enable-gc"
  "--enable-shared-heap"
  "--enable-shared-chain"
  "--invoke-c-api-import"
  "--bounds-checks=0 --stack-bounds-checks=0 --disable-aux-stack-check"
  "--opt-level=3 --bounds-checks=0 --stack-bounds-checks=0 --disable-aux-stack-check --enable-segue"
)

echo "artifact|options|compile|size|median_ms|min_ms|samples"
for SPEC in "clean|$CLEAN" "merged|$MERGED"; do
  NAME="${SPEC%%|*}"; SRC="${SPEC#*|}"
  for O in "${OPTS[@]}"; do
    TAG=$(echo "${NAME}_${O}" | tr -c 'A-Za-z0-9_.-' '_')
    AOT="$OUT/$TAG.aot"
    # shellcheck disable=SC2086
    if $WAMRC $O -o "$AOT" "$SRC" >"$OUT/$TAG.log" 2>&1; then
      OK=ok
    else
      OK=FAIL
    fi
    if [ "$OK" = ok ] && [ -f "$AOT" ]; then
      SZ=$(stat -c %s "$AOT")
      if [ "$NAME" = clean ]; then
        RES=$(bash "$OUT/measure.sh" "$AOT" 12 1)
      else
        RES=$(bash "$OUT/measure.sh" "$AOT" 3 4)
      fi
      MS=$(echo "$RES" | awk '{print $1}')
      MN=$(echo "$RES" | awk '{print $2}')
      NS=$(echo "$RES" | awk '{print $3}')
    else
      SZ=0; MS=NA; MN=NA; NS=0
    fi
    echo "$NAME|${O:-<default>}|$OK|$SZ|$MS|$MN|$NS"
  done
done
