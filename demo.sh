#!/usr/bin/env bash
#
# demo.sh — perry 把 TypeScript 编译成 wasm；perry 的 rt.* 运行时也用 Rust 编成 wasm 模块；
#           两个模块由 WAMR 的多模块机制链接执行，宿主只剩 WASI。
#
# 流程:
#   1. 依赖: @typerry/node (napi 绑定)、wasm32-unknown-unknown target、WAMR iwasm(开 MULTI_MODULE)
#   2. TypeScript → build/app.wasm; 同一份源码走 perry 自带 JS 宿主层 → 参照输出
#   3. 从业务模块的导入段生成 198 个桩 → cargo build 出 build/rt.wasm (Rust 运行时模块)
#   4. 业务模块改成 import rt.memory, 编出宿主 runner build/perry_link
#   5. 跑: 与 JS 宿主层的输出逐字节比对
#   6. 负向: 用数组的 TS 程序应当报 "not implemented" 且退出码非 0
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

WAMR_TAG="${WAMR_TAG:-WAMR-2.4.3}"
WAMR_SRC="$ROOT/.deps/wamr"
WAMR_BUILD="$ROOT/.deps/wamr-build"
RUST_TARGET="wasm32-unknown-unknown"
BUILD="$ROOT/build"
JOBS="${JOBS:-$(nproc)}"
mkdir -p "$BUILD"

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

step "1/6 依赖: perry wasm 编译器 (@typerry/node)"
[ -d node_modules/@typerry/node ] || npm install --no-audit --no-fund
bindings=("$ROOT"/node_modules/@typerry/*/*.node)
if [ ! -e "${bindings[0]}" ]; then
  # 部分 npm 镜像没有同步平台包, 直接从 registry.npmjs.org 取 (linux x64 gnu)
  pkg_version="$(node -p "require('./node_modules/@typerry/node/package.json').version")"
  echo "npm 未装到平台绑定, 从 registry.npmjs.org 补装 @typerry/node-linux-x64-gnu@$pkg_version"
  mkdir -p node_modules/@typerry/node-linux-x64-gnu
  curl -fsSL "https://registry.npmjs.org/@typerry/node-linux-x64-gnu/-/node-linux-x64-gnu-$pkg_version.tgz" |
    tar xz -C node_modules/@typerry/node-linux-x64-gnu --strip-components=1
fi
bindings=("$ROOT"/node_modules/@typerry/*/*.node)
echo "绑定: ${bindings[0]}"

step "1/6 依赖: Rust $RUST_TARGET target"
rustup target list --installed | grep -qx "$RUST_TARGET" ||
  rustup target add "$RUST_TARGET"
echo "已安装: $(rustc --version)"

step "1/6 依赖: WAMR iwasm ($WAMR_TAG, 需要 MULTI_MODULE)"
if [ ! -x "$WAMR_BUILD/iwasm" ] || ! grep -q "WAMR_BUILD_MULTI_MODULE:UNINITIALIZED=1" "$WAMR_BUILD/CMakeCache.txt" 2>/dev/null; then
  [ -d "$WAMR_SRC/.git" ] || git clone --depth 1 --branch "$WAMR_TAG" \
    https://github.com/bytecodealliance/wasm-micro-runtime.git "$WAMR_SRC"
  cmake -S "$WAMR_SRC/product-mini/platforms/linux" -B "$WAMR_BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DWAMR_BUILD_INTERP=1 -DWAMR_BUILD_FAST_INTERP=1 \
    -DWAMR_BUILD_AOT=0 -DWAMR_BUILD_MULTI_MODULE=1 \
    -DCMAKE_EXE_LINKER_FLAGS="-Wl,--export-dynamic"
  cmake --build "$WAMR_BUILD" --target iwasm -j "$JOBS"
fi
echo "iwasm: $("$WAMR_BUILD/iwasm" --version 2>&1 | head -1)"

step "2/6 perry: TypeScript → build/app.wasm (+ JS 宿主层参照)"
node tools/build-wasm.mjs

step "3/6 运行时: rt.* 桩表 + cargo build → build/rt.wasm"
node tools/gen-rt-symbols.mjs build/app.wasm \
  --rust runtime-wasm/src/lib.rs build/rt_symbols.rs
cargo build --release --target "$RUST_TARGET" --manifest-path runtime-wasm/Cargo.toml
cp runtime-wasm/target/"$RUST_TARGET"/release/perry_rt_wasm.wasm build/rt.wasm
echo "build/rt.wasm: $(stat -c%s build/rt.wasm) bytes"

step "4/6 链接: 业务模块 import rt.memory + 编宿主 runner"
node tools/patch-app-memory.mjs build/app.wasm build/app_link.wasm
gcc -O2 -Wall -Wextra -I "$WAMR_SRC/core/iwasm/include" \
  -o build/perry_link host/perry_link.c "$WAMR_BUILD/libiwasm.a" -lm -ldl -lpthread

step "5/6 运行: Rust 运行时模块 (WAMR 多模块) vs perry JS 宿主层"
node build/ref/run.mjs > build/ref.out
./build/perry_link build/app_link.wasm build/rt.wasm > build/wamr.out
echo "--- perry JS 宿主层 (参照) ---"
cat build/ref.out
echo "--- rt.* 运行时模块 (本次) ---"
cat build/wamr.out
if diff -u build/ref.out build/wamr.out; then
  printf '\033[32mPASS: 两边输出完全一致\033[0m\n'
else
  printf '\033[31mFAIL: 输出不一致\033[0m\n'
  exit 1
fi

step "6/6 负向: 用数组的 TS 程序应当报未实现"
node tools/build-wasm.mjs src/arr.ts --bare build/arr.wasm
node tools/patch-app-memory.mjs build/arr.wasm build/arr_link.wasm
set +e
./build/perry_link build/arr_link.wasm build/rt.wasm > build/arr.out 2>&1
status=$?
set -e
cat build/arr.out
if [ "$status" -ne 0 ] && grep -q "bridge function 'array_new' is not implemented" build/arr.out; then
  printf '\033[32mPASS: 未实现的功能被立刻报错 (退出码 %d)\033[0m\n' "$status"
else
  printf '\033[31mFAIL: 期望报未实现并退出非 0, 实际退出码 %d\033[0m\n' "$status"
  exit 1
fi
