#!/bin/bash
# perry_cli.sh — does any perry compile flag change the emitted wasm bytes?
P=/tmp/perry-dist/perry
SRC=/home/gem/project/perry_wasm_demo/src/bench.ts
OUT=/tmp/rc_work/cli
mkdir -p "$OUT"

extract() { # $1 = html
  node -e '
    const fs=require("fs"),cp=require("crypto");
    const h=fs.readFileSync(process.argv[1],"utf8");
    const m=h.match(/[A-Za-z0-9+/=]{2000,}/g)||[];
    if(!m.length){console.log("NOBLOB");process.exit(0);}
    const b=Buffer.from(m[0],"base64");
    console.log(b.length+" "+cp.createHash("md5").update(b).digest("hex"));
  ' "$1"
}

run() { # $1 = label, rest = flags
  local label="$1"; shift
  local tag; tag=$(echo "$label" | tr -c 'A-Za-z0-9_.-' '_')
  local html="$OUT/$tag.html"
  if "$P" compile "$SRC" --target wasm "$@" -o "$OUT/$tag" >"$OUT/$tag.log" 2>&1; then
    if [ -f "$html" ]; then
      echo "$label | HTML=$(stat -c %s "$html") | WASM=$(extract "$html")"
    else
      echo "$label | COMPILED-NO-HTML | $(ls "$OUT/$tag"* 2>/dev/null | tr '\n' ' ')"
    fi
  else
    echo "$label | FAIL | $(tr '\n' ' ' < "$OUT/$tag.log" | cut -c1-200)"
  fi
}

run "<default>"
run "--minify" --minify
run "--fast-math" --fast-math
run "--fp-contract=fast" --fp-contract fast
run "--march=generic" --march generic
run "--march=native" --march native
run "--march=x86-64-v3" --march x86-64-v3
run "--march=znver2" --march znver2
run "--no-auto-optimize" --no-auto-optimize
run "--type-check" --type-check
run "--no-cache" --no-cache
run "--debug-symbols" --debug-symbols
run "--disable-buffer-fast-path" --disable-buffer-fast-path
run "--output-type=staticlib" --output-type staticlib
run "--report-size" --report-size
run "-v -v" -v -v
echo "--- env vars ---"
for e in "PERRY_TARGET_CPU=generic" "PERRY_TARGET_CPU=x86-64-v3" "PERRY_OPT=3" "PERRY_WASM_OPT=1" "PERRY_PRECOMPILE=1" "PERRY_ALLOW_PARTIAL_CODEGEN=1" "PERRY_GC_PROMOTE_IN_PLACE=1"; do
  k="${e%%=*}"; v="${e#*=}"
  tag="env_$(echo "$k" | tr -c 'A-Za-z0-9_.-' '_')_$v"
  html="$OUT/$tag.html"
  if env "$k=$v" "$P" compile "$SRC" --target wasm -o "$OUT/$tag" >"$OUT/$tag.log" 2>&1 && [ -f "$html" ]; then
    echo "$e | HTML=$(stat -c %s "$html") | WASM=$(extract "$html")"
  else
    echo "$e | FAIL | $(tr '\n' ' ' < "$OUT/$tag.log" | cut -c1-200)"
  fi
done
