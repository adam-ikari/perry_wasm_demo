#!/usr/bin/env bash
#
# build.sh — 路线四运行时 (tools/route4) 一键构建 + 校验。
#   1. 上游 perry 源码 checkout 到 pinned commit (默认 .deps/perry-src, PERRY_SRC 可覆盖)
#   2. 应用 wasm32 适配 patch (幂等: 已应用则跳过)
#   3. 从业务模块导入段生成 rt4 桩表 (211 导入, 29 实现, 182 桩)
#   4. cargo build --release --target wasm32-wasip1 → build/rt4.wasm
#   5. verify.mjs: 导入段全 WASI + rt.* 导出覆盖 + 正/负向端到端比对
#
# 前置 (第 5 步的端到端校验需要, 缺了会提示):
#   ./demo.sh          → build/perry_link, build/app_link.wasm, build/arr_link.wasm, build/ref.out
#   build/app.wasm     → r3 桩表 (coverage.mjs 的分母), 也由 demo.sh 产出
#
# 用法: tools/route4/build.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

PERRY_SRC="${PERRY_SRC:-$ROOT/.deps/perry-src}"
PERRY_REMOTE="https://github.com/PerryTS/perry.git"
PERRY_COMMIT="7ac11b099b5d48ffb62565ef9c470648a4ce2599"
PATCH="$ROOT/tools/route4/perry-wasm32.patch"
RUST_TARGET="wasm32-wasip1"

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

step "1/5 上游源码: perry @ ${PERRY_COMMIT:0:12}"
if [ ! -d "$PERRY_SRC/.git" ]; then
  if [ -e "$PERRY_SRC" ]; then
    echo "错误: $PERRY_SRC 存在但不是 git checkout" >&2
    exit 1
  fi
  git clone "$PERRY_REMOTE" "$PERRY_SRC"
fi
head="$(git -C "$PERRY_SRC" rev-parse HEAD)"
if [ "$head" != "$PERRY_COMMIT" ]; then
  if ! git -C "$PERRY_SRC" diff --quiet || ! git -C "$PERRY_SRC" diff --cached --quiet; then
    echo "错误: $PERRY_SRC 在 $head 且工作区不干净 (可能已打 patch), 与 pinned commit 不符" >&2
    echo "      清理该目录重跑, 或用 PERRY_SRC= 指向另一份 checkout" >&2
    exit 1
  fi
  git -C "$PERRY_SRC" checkout --quiet "$PERRY_COMMIT"
fi
echo "HEAD: $(git -C "$PERRY_SRC" rev-parse --short HEAD)  src: $PERRY_SRC"

step "2/5 wasm32 适配 patch (perry-wasm32.patch)"
if git -C "$PERRY_SRC" apply --reverse --check "$PATCH" >/dev/null 2>&1; then
  echo "已应用, 跳过"
elif git -C "$PERRY_SRC" apply --check "$PATCH" >/dev/null 2>&1; then
  git -C "$PERRY_SRC" apply "$PATCH"
  echo "已应用"
else
  echo "错误: patch 既不能正向也不能反向应用, 源码状态与 pinned commit 不匹配" >&2
  exit 1
fi

step "3/5 rt4 桩表 (gen-rt-symbols)"
if [ ! -f build/bench.wasm ]; then
  node tools/build-wasm.mjs src/bench.ts --bare build/bench.wasm
fi
node tools/gen-rt-symbols.mjs build/bench.wasm \
  --rust tools/route4/src/lib.rs tools/route4/build/rt_symbols.rs
# coverage.mjs 的分母是 r3 桩表 (demo.sh 从 app.wasm 生成); 缺了就地补
if [ -f build/app.wasm ] && [ ! -f build/rt_symbols.rs ]; then
  node tools/gen-rt-symbols.mjs build/app.wasm \
    --rust runtime-wasm/src/lib.rs build/rt_symbols.rs
fi

step "4/5 cargo build ($RUST_TARGET)"
rustup target list --installed | grep -qx "$RUST_TARGET" ||
  rustup target add "$RUST_TARGET"
cargo build --release --target "$RUST_TARGET" --manifest-path tools/route4/Cargo.toml
cp tools/route4/target/"$RUST_TARGET"/release/rt4.wasm build/rt4.wasm
echo "build/rt4.wasm: $(stat -c%s build/rt4.wasm) bytes"

step "5/5 校验"
if [ -f build/rt_symbols.rs ]; then
  node tools/route4/coverage.mjs | sed -n '1,3p'
else
  echo "(缺 build/rt_symbols.rs, 跳过覆盖度汇总; 有 build/app.wasm 后可手跑 tools/route4/coverage.mjs)"
fi
node tools/route4/verify.mjs
