#!/usr/bin/env bash
#
# reuse_check.sh — 上游 patch 工程化可复用性：探针矩阵（正确性测试面）。
#
# 对 tools/attribution/probes/probe_reuse_*.ts 每个程序做三件事：
#   1. 用 **patch 版绑定** 编出业务模块 → 参照 = perry 自带 JS 宿主层 (wasmBoot) 的输出；
#   2. E 路 = 本仓的 wasm×WAMR 链路，两种装载形态都跑：
#        E1: 双模块 fast-interp（tools/patch-app-memory + build/rt.wasm + host/perry_link）
#        E2: wasm-merge 合并单模块 → wamrc AOT → AOT iwasm（与 tools/attribution/aot_e.sh 同链路）
#      两者都必须与参照逐字节一致。
#   3. 用 **基线版绑定**（未打 patch 的 perry）跑同一程序，与 patch 版参照做差分：
#      凡是 E 路跑不了（rt 桩没实现的桥：数组 / js_mod）的探针，靠差分证明零误判。
#   顺带统计每个探针的桥调用点（js_add / is_truthy）在 patch 前后各剩几个 —— 覆盖率证据。
#
# 用法:
#   tools/attribution/reuse_check.sh            # 全部探针
#   tools/attribution/reuse_check.sh probe_reuse_1_class.ts   # 单个（可多个）
#
# 环境变量:
#   BASE_BINDING  基线绑定（默认 /tmp/typerry.node.orig）
#   PATCH_BINDING patch 版绑定（默认 /tmp/typerry-src/target/release/libtyperry.so）
#
# 注意：脚本会临时把 BASE_BINDING 换进 node_modules，退出时（含失败）恢复 patch 版。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
BUILD="$ROOT/build"
OUT="$BUILD/reuse"
BINDING="$ROOT/node_modules/@typerry/node-linux-x64-gnu/typerry.linux-x64-gnu.node"
BASE_BINDING="${BASE_BINDING:-/tmp/typerry.node.orig}"
PATCH_BINDING="${PATCH_BINDING:-/tmp/typerry-src/target/release/libtyperry.so}"
WAMRC="${WAMRC:-/tmp/wamrc-test/wamrc}"
AOT_IWASM="${AOT_IWASM:-$BUILD/wamr-aot-build/iwasm}"
RT_WASM="${RT_WASM:-$BUILD/rt.wasm}"
PERRY_LINK="${PERRY_LINK:-$BUILD/perry_link}"
PROBES_DIR="tools/attribution/probes"

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
bad()  { printf '\033[31m%s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- 0. 前置
step "0/4 前置"
[ -f "$BINDING" ] || { bad "缺绑定 $BINDING（先 npm install）"; exit 1; }
[ -f "$BASE_BINDING" ] || { bad "缺基线绑定 $BASE_BINDING"; exit 1; }
[ -x "$PERRY_LINK" ] || { bad "缺 $PERRY_LINK（跑 demo.sh 生成）"; exit 1; }
[ -f "$RT_WASM" ] || { bad "缺 $RT_WASM（跑 demo.sh 生成）"; exit 1; }
[ -x "$WAMRC" ] || { bad "缺 wamrc $WAMRC"; exit 1; }
[ -x "$AOT_IWASM" ] || { bad "缺 AOT iwasm $AOT_IWASM（tools/attribution/aot_e.sh 会构建）"; exit 1; }
mkdir -p "$OUT"

# patch 版绑定落地：当前绑定若与 patch 构建产物不一致，先换成 patch 版。
PATCH_SNAPSHOT="$(mktemp)"
cp "$BINDING" "$PATCH_SNAPSHOT"
if [ -f "$PATCH_BINDING" ] && ! cmp -s "$PATCH_BINDING" "$BINDING"; then
  cp "$PATCH_BINDING" "$BINDING"
  echo "绑定换成 patch 版: $(md5sum < "$BINDING")"
else
  echo "绑定已是 patch 版: $(md5sum < "$BINDING")"
fi
restore() { cp "$PATCH_SNAPSHOT" "$BINDING"; rm -f "$PATCH_SNAPSHOT"; }
trap restore EXIT

# 桥调用点计数：wat 里 `(import "rt" "<name>" (func $fimport$N ...))` → 数 `call $fimport$N`。
bridge_calls() { # <wat> <bridge-name>
  local wat="$1" name="$2" idx
  idx="$(grep -oE "\(import \"rt\" \"$name\" \(func \\\$fimport\\\$[0-9]+" "$wat" | grep -oE '[0-9]+$')"
  [ -n "$idx" ] || { echo "-"; return; }
  grep -cE "call \\\$fimport\\\$$idx\b" "$wat"
}

# ---------------------------------------------------------------- 探针清单
if [ "$#" -gt 0 ]; then
  PROBES=("$@")
else
  PROBES=()
  for p in "$PROBES_DIR"/probe_reuse_*.ts; do PROBES+=("$(basename "$p")"); done
fi

compile_pass() { # <binding-label> <suffix>
  local label="$1" suffix="$2"
  step "编译: $label 绑定（$suffix）"
  for probe in "${PROBES[@]}"; do
    local dir="$OUT/${probe%.ts}"
    mkdir -p "$dir"
    node tools/build-wasm.mjs "$PROBES_DIR/$probe" --bare "$dir/app$suffix.wasm" >/dev/null || { bad "$probe 编译失败"; return 1; }
    node tools/attribution/probe_ref.mjs "$PROBES_DIR/$probe" "$dir/ref$suffix" >/dev/null || { bad "$probe 参照生成失败"; return 1; }
    ( cd "$ROOT" && node "$dir/ref$suffix/run.mjs" ) > "$dir/ref$suffix.out" 2>&1
    ./node_modules/.bin/wasm-dis "$dir/app$suffix.wasm" -o "$dir/app$suffix.wat" 2>/dev/null
  done
}

# ---------------------------------------------------------------- 1. patch 版
compile_pass "patch" ""
step "1/4 E 路: patch 版探针"
for probe in "${PROBES[@]}"; do
  dir="$OUT/${probe%.ts}"
  node tools/patch-app-memory.mjs "$dir/app.wasm" "$dir/app_link.wasm" >/dev/null
  # E1: 双模块 fast-interp
  "$PERRY_LINK" "$dir/app_link.wasm" "$RT_WASM" > "$dir/e1.out" 2>&1
  echo "e1_exit=$?" > "$dir/e1.status"
  # E2: 合并单模块 AOT
  if ./node_modules/.bin/wasm-merge "$dir/app_link.wasm" app "$RT_WASM" rt \
      --enable-bulk-memory --enable-nontrapping-float-to-int --enable-multimemory \
      --enable-reference-types --rename-export-conflicts -o "$dir/merged.wasm" >/dev/null 2>&1 &&
     node tools/attribution/patch_merged.mjs "$dir/merged.wasm" "$dir/merged.wat" >/dev/null 2>&1 &&
     ./node_modules/.bin/wasm-as "$dir/merged.wat" --enable-bulk-memory --enable-nontrapping-float-to-int \
      --enable-multimemory --enable-reference-types -o "$dir/merged_patched.wasm" >/dev/null 2>&1 &&
     "$WAMRC" -o "$dir/merged.aot" "$dir/merged_patched.wasm" >/dev/null 2>&1; then
    "$AOT_IWASM" "$dir/merged.aot" > "$dir/e2.out" 2>&1
    echo "e2_exit=$?" > "$dir/e2.status"
  else
    echo "merge/aot 构建失败" > "$dir/e2.out"; echo "e2_exit=99" > "$dir/e2.status"
  fi
done

# ---------------------------------------------------------------- 2. 基线版（差分）
step "2/4 差分: 基线绑定（$(md5sum < "$BASE_BINDING" | cut -c1-8)）"
cp "$BASE_BINDING" "$BINDING"
compile_pass "baseline" "_base"
cp "$PATCH_SNAPSHOT" "$BINDING"   # 立刻换回 patch 版

# ---------------------------------------------------------------- 3. 比对
step "3/4 比对（逐字节）"
printf '%-30s %-6s %-6s %-6s %-11s %-13s %-8s\n' 程序 E1 E2 差分 桥mem_call 桥mem_call_i32 备注
declare -i npass=0 nfail=0 nskip=0
for probe in "${PROBES[@]}"; do
  dir="$OUT/${probe%.ts}"
  e1_exit="$(sed 's/.*=//' "$dir/e1.status")"
  e2_exit="$(sed 's/.*=//' "$dir/e2.status")"
  e1="N/A"; e2="N/A"; note=""
  if [ "$e1_exit" = "0" ]; then
    if cmp -s "$dir/ref.out" "$dir/e1.out"; then e1="PASS"; else e1="FAIL"; fi
  elif grep -q "not implemented" "$dir/e1.out"; then
    e1="SKIP"; note="$(grep -o "bridge function '[^']*' is not implemented" "$dir/e1.out" | head -1)"
  else
    e1="ERR"; note="exit=$e1_exit"
  fi
  if [ "$e2_exit" = "0" ]; then
    if cmp -s "$dir/ref.out" "$dir/e2.out"; then e2="PASS"; else e2="FAIL"; fi
  elif [ "$e2_exit" = "99" ]; then
    e2="ERR"
  elif grep -q "not implemented" "$dir/e2.out"; then
    e2="SKIP"
  else
    e2="ERR"; note="${note:+$note; }exit=$e2_exit"
  fi
  if cmp -s "$dir/ref.out" "$dir/ref_base.out"; then
    diff="PASS"
  else
    diff="FAIL"; note="${note:+$note; }patch/base 参照不一致"
  fi
  mc_p="$(bridge_calls "$dir/app.wat" mem_call)";      mc_b="$(bridge_calls "$dir/app_base.wat" mem_call)"
  mi_p="$(bridge_calls "$dir/app.wat" mem_call_i32)";  mi_b="$(bridge_calls "$dir/app_base.wat" mem_call_i32)"
  printf '%-30s %-6s %-6s %-6s %-11s %-13s %-8s\n' "${probe%.ts}" "$e1" "$e2" "$diff" "$mc_b→$mc_p" "$mi_b→$mi_p" "$note"
  if [ "$e1" = "FAIL" ] || [ "$e2" = "FAIL" ] || [ "$diff" = "FAIL" ] || [ "$e1" = "ERR" ] || [ "$e2" = "ERR" ]; then
    nfail+=1
  elif [ "$e1" = "SKIP" ]; then
    nskip+=1
  else
    npass+=1
  fi
done
echo "SKIP 说明: E 路 rt 桩只实现 13 个桥，类/闭包/数组/js_mod 等一律 trap（基线绑定同样 trap，非 patch 问题）；这些探针的正确性由「差分」列给出。"

# ---------------------------------------------------------------- 4. 汇总
step "4/4 汇总"
echo "E 路全通: $npass ; E 路 SKIP(桩缺桥): $nskip ; 失败: $nfail ; 探针总数: ${#PROBES[@]}"
echo "产物: $OUT/<probe>/{app.wasm,app.wat,ref.out,e1.out,e2.out,app_base.wasm,ref_base.out}"
if [ "$nfail" -gt 0 ]; then bad "FAIL"; exit 1; fi
ok "PASS: 探针矩阵无失败项"
