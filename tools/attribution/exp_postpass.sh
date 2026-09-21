#!/usr/bin/env bash
#
# exp_postpass.sh — 零上游依赖后处理 pass（bridge_inline_pass.mjs）一键复现 + 泛化验证。
#
# 对每个程序跑完整 E 路链路（与 aot_e.sh 同步骤，但多插一步 pass）：
#   perry 产物 → patch-app-memory → wasm-merge(+rt) → patch_merged → [pass] → wasm-as → wamrc → aot_time
# 三路对照：
#   a) 正确性：每个 .aot 的输出必须与 perry JS 宿主层（wasmBoot 的 run.mjs）逐字节一致
#   b) 覆盖率：pass 报告静态桥调用点改写数（改写前/后 `call $mem_call*` 计数）
#   c) 性能：P50（6 进程 × 每进程 2 轮 = 12 样本，弃第 1 样本取 11 样本中位数）
#
# 变体: base(未 pass) / pass / pass(cw=closed-world) / pass+wasm-opt(A5) / pass+wasm-opt(强组合)
#       / pass+segue / pass+wasm-opt+segue
#
# 用法: tools/attribution/exp_postpass.sh [bench|probe_str|probe_mixed|probe_nested|all]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
BUILD="$ROOT/build"
OUT="$BUILD/postpass"
WASM_AS="$ROOT/node_modules/.bin/wasm-as"
WOPT="$ROOT/node_modules/.bin/wasm-opt"
WAMRC="${WAMRC:-/tmp/wamrc-test/wamrc}"
FEAT="--enable-bulk-memory --enable-nontrapping-float-to-int --enable-multimemory --enable-reference-types"
A5="--inlining-optimizing --always-inline-max-function-size=5000 --precompute-propagate --dce"
STRONG="-O4 --converge --precompute-propagate --inline-functions-with-loops"
SEGUE="--target=x86_64 --enable-segue --disable-llvm-jump-tables"
PROCS=6
RUNS_PER_PROC=2

TARGET="${1:-all}"

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

for f in "$WASM_AS" "$WOPT" "$WAMRC" "$BUILD/aot_time" "$BUILD/rt_bench.wasm"; do
  [ -e "$f" ] || { echo "缺 $f"; exit 1; }
done

src_of() {
  case "$1" in
    bench) echo "src/bench.ts" ;;
    probe_*) echo "tools/attribution/probes/$1.ts" ;;
    *) echo "" ;;
  esac
}

# p50 <aot> <label> : 6 进程 × 每进程 2 轮 = 12 样本，弃第 1 样本，取 11 样本中位数
#   （每进程 3 次执行 = 1 预热 + 2 计时 ≤ rt 字符串表 1024 项上限，避免第 4 次执行 string table overflow）
p50() {
  local aot="$1" label="$2" vals=() v p
  for p in $(seq 1 "$PROCS"); do
    while read -r v; do [ -n "$v" ] && vals+=("$v"); done \
      < <("$BUILD/aot_time" "$aot" "$RUNS_PER_PROC" 2>/dev/null | grep '^RUN ' | awk '{print $3}')
  done
  printf '%s\n' "${vals[@]:1}" | sort -n | awk -v n="$label" \
    '{a[NR]=$1} END {printf "%-24s P50 = %9.3f ms  min %9.3f  max %9.3f  (n=%d)\n", n, a[int((NR+1)/2)], a[1], a[NR], NR}' | tee -a "$OUT/p50.txt"
}

# verify <aot> <label> <ref.out> : 输出必须与 JS 宿主层逐字节一致
verify() {
  local out
  out="$("$BUILD/aot_time" "$1" 1 2>/dev/null | grep -v '^RUN ' | sort -u)"
  if [ "$out" != "$(sort -u "$3")" ]; then
    echo "FAIL 输出不一致 ($2):"; echo "--- 期望 ---"; sort -u "$3"; echo "--- 实得 ---"; echo "$out"; exit 1
  fi
  echo "PASS 输出一致 ($2)"
}
run_one() {
  local p="$1" src d
  src="$(src_of "$p")"
  d="$OUT/$p"
  mkdir -p "$d"
  step "$p  ($src)"

  node tools/build-wasm.mjs "$src" --bare "$d/app.wasm" >/dev/null
  node tools/patch-app-memory.mjs "$d/app.wasm" "$d/app_link.wasm"
  "$ROOT/node_modules/.bin/wasm-merge" "$d/app_link.wasm" app "$BUILD/rt_bench.wasm" rt \
    $FEAT --rename-export-conflicts -o "$d/merged.wasm"
  node tools/attribution/patch_merged.mjs "$d/merged.wasm" "$d/merged.wat"

  node tools/attribution/probe_ref.mjs "$src" "$d/ref" >/dev/null
  node "$d/ref/run.mjs" > "$d/ref.out"

  node tools/attribution/bridge_inline_pass.mjs "$d/merged.wat" "$d/postpass.wat" --report "$d/coverage.json"
  node tools/attribution/bridge_inline_pass.mjs "$d/merged.wat" "$d/postpass_cw.wat" \
    --report "$d/coverage_cw.json" --closed-world

  "$WASM_AS" "$d/merged.wat" $FEAT -o "$d/base.wasm"
  "$WASM_AS" "$d/postpass.wat" $FEAT -o "$d/pass.wasm"
  "$WASM_AS" "$d/postpass_cw.wat" $FEAT -o "$d/pass_cw.wasm"
  "$WOPT" $A5 $FEAT "$d/pass.wasm" -o "$d/pass_opt.wasm"
  "$WOPT" $STRONG $FEAT "$d/pass.wasm" -o "$d/pass_strong.wasm"

  "$WAMRC" -o "$d/base.aot" "$d/base.wasm" >/dev/null 2>&1
  "$WAMRC" -o "$d/pass.aot" "$d/pass.wasm" >/dev/null 2>&1
  "$WAMRC" -o "$d/pass_cw.aot" "$d/pass_cw.wasm" >/dev/null 2>&1
  "$WAMRC" -o "$d/pass_opt.aot" "$d/pass_opt.wasm" >/dev/null 2>&1
  "$WAMRC" -o "$d/pass_strong.aot" "$d/pass_strong.wasm" >/dev/null 2>&1
  "$WAMRC" $SEGUE -o "$d/pass_segue.aot" "$d/pass.wasm" >/dev/null 2>&1
  "$WAMRC" $SEGUE -o "$d/pass_opt_segue.aot" "$d/pass_opt.wasm" >/dev/null 2>&1
  step "$p 正确性"
  verify "$d/base.aot" "$p/base" "$d/ref.out"
  verify "$d/pass.aot" "$p/pass" "$d/ref.out"
  verify "$d/pass_cw.aot" "$p/pass(closed-world)" "$d/ref.out"
  verify "$d/pass_opt.aot" "$p/pass+wasmopt" "$d/ref.out"
  verify "$d/pass_strong.aot" "$p/pass+wasmopt(强)" "$d/ref.out"
  verify "$d/pass_segue.aot" "$p/pass+segue" "$d/ref.out"
  verify "$d/pass_opt_segue.aot" "$p/pass+wasmopt+segue" "$d/ref.out"
  local n_before n_after
  n_before="$(python3 -c "import json;print(json.load(open('$d/coverage.json'))['totals']['sites'])")"
  n_after="$((n_before - $(python3 -c "import json;print(json.load(open('$d/coverage.json'))['totals']['inlined'])")))"

  echo
  echo "静态桥调用点(call mem_call*): 改写前 $n_before → 改写后 $n_after"
  python3 - "$d/coverage.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
for c in r["coverage"]:
    nm = c["name"] or "?"
    print(f'  nameId={c["nameId"]:<3} {nm:<14} argc={c["argc"]} 内联 {c["inlined"]}/{c["total"]} ({c["pct"]}%)' + (f' 未内联: {c["reasons"]}' if c["reasons"] else ""))
print(f'  合计: {r["totals"]["inlined"]}/{r["totals"]["sites"]} ({r["totals"]["pct"]}%)')
PY

  step "$p 计时 ($PROCS 进程 × $RUNS_PER_PROC 轮)"
  p50 "$d/base.aot" "$p/base"
  p50 "$d/pass.aot" "$p/pass"
  p50 "$d/pass_cw.aot" "$p/pass(cw)"
  p50 "$d/pass_opt.aot" "$p/pass+wasmopt"
  p50 "$d/pass_strong.aot" "$p/pass+wasmopt(强)"
  p50 "$d/pass_segue.aot" "$p/pass+segue"
  p50 "$d/pass_opt_segue.aot" "$p/pass+wasmopt+segue"
}
mkdir -p "$OUT"
: > "$OUT/p50.txt"

case "$TARGET" in
  all) for p in bench probe_str probe_mixed probe_nested; do run_one "$p"; done ;;
  bench|probe_str|probe_mixed|probe_nested) run_one "$TARGET" ;;
  *) echo "用法: exp_postpass.sh [bench|probe_str|probe_mixed|probe_nested|all] [--quick]"; exit 2 ;;
esac

step "汇总 (P50 ms)"
for p in bench probe_str probe_mixed probe_nested; do
  [ -f "$OUT/$p/base.aot" ] || continue
  printf '%-14s ' "$p"
  python3 - "$OUT/$p/coverage.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
print(f'桥内联 {r["totals"]["inlined"]}/{r["totals"]["sites"]} ({r["totals"]["pct"]}%)')
PY
done
echo "产物: $OUT/<prog>/{base,pass,pass_cw,pass_opt,pass_strong,pass_segue,pass_opt_segue}.aot + coverage*.json"
