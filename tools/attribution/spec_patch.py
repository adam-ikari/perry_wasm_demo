#!/usr/bin/env python3
"""
spec_patch.py — 实验 B 的"等价手工类型特化"生成器。

输入: build/bench_merged_patched.wat (aot_e.sh 的合并+补丁产物, perry 原样字节码)
输出:
  build/spec_B1_add.wat     只把两个热路径 js_add 桥 (`+`) 内联成 f64.add
                            (fib 的 fib(n-1)+fib(n-2) 与循环的 sum += i),
                            is_truthy 桥原样保留 → "codegen 只修 `+`" 的天花板
  build/spec_B2_full.wat    B1 + 把两个 is_truthy 桥内联成 i64.ne 假盒比较
                            → "codegen 修好类型特化 (保留 NaN-box + 影子栈)" 的天花板

等价性论证 (与 perry 语义逐位一致):
  * js_add 两侧在此程序里恒为 number (fib 递归值 / sum 与 i), number+number
    的 JS `+` = f64.add; perry 的 number 表示就是裸 f64 位型
    (i64.reinterpret_f64 往返), 所以 i64.load→reinterpret→f64.add→reinterpret→
    i64.store 与 rt 的 js_add 核心逐位等价。
  * is_truthy 的输入恒为 (f64.lt ...) 产出的盒布尔 (TAG_TRUE=0x7FF8000000000004
    / TAG_FALSE=0x7FF8000000000003), is_truthy(盒布尔) = (v != TAG_FALSE);
    f64.lt 比较结果用 i64.ne TAG_FALSE 逐位等价。
  * 打印路径 (string 拼接的 js_add) 与 console_log 桥原样保留 → 输出逐字节一致。
  * 每个替换保持影子栈 (global $global$0) 增减完全不变。

用法:
  python3 tools/attribution/spec_patch.py [input.wat]   # 默认 build/bench_merged_patched.wat
"""
import re
import sys

SRC = sys.argv[1] if len(sys.argv) > 1 else "build/bench_merged_patched.wat"
OUT1 = "build/spec_B1_add.wat"
OUT2 = "build/spec_B2_full.wat"

INLINE_ADD = """  (i64.store
   (i32.sub
    (global.get $global$0)
    (i32.const 16)
   )
   (i64.reinterpret_f64
    (f64.add
     (f64.reinterpret_i64
      (i64.load
       (i32.sub
        (global.get $global$0)
        (i32.const 16)
       )
      )
     )
     (f64.reinterpret_i64
      (i64.load
       (i32.sub
        (global.get $global$0)
        (i32.const 8)
       )
      )
     )
    )
   )
  )"""

# 两个热 js_add 调用块的行号 (在 aot_e.sh 的固定产物里):
#   1344: fib 的 fib(n-1)+fib(n-2)    1678: 循环的 sum += i
HOT_SITES = (1678, 1344)


def replace_site(lines, call_line):
    start = call_line - 2  # 0-indexed; 上一行是 (drop
    assert lines[start].strip() == "(drop", lines[start]
    assert lines[start + 1].strip() == "(call $142", lines[start + 1]
    assert lines[start + 2].strip() == "(f64.const 8)", lines[start + 2]
    assert lines[start + 3].strip() == "(f64.const 2)", lines[start + 3]
    assert lines[start + 6].strip() == "(i32.const 16)", lines[start + 6]
    end = start + 9
    assert lines[end].strip() == ")", lines[end]
    return lines[:start] + INLINE_ADD.split("\n") + lines[end + 1:]


def inline_is_truthy(text):
    # fib 的 is_truthy: (local.set $7 (call $143 (12,1,sp-8))) → i64.ne $2 TAG_FALSE
    pat1 = re.compile(
        r"\(local\.set \$7\n\s*\(call \$143\n\s*\(f64\.const 12\)\n\s*\(f64\.const 1\)\n"
        r"\s*\(i32\.sub\n\s*\(global\.get \$global\$0\)\n\s*\(i32\.const 8\)\n\s*\)\n\s*\)\n\s*\)\n"
        r"(\s*\(global\.set \$global\$0\n\s*\(i32\.sub\n\s*\(global\.get \$global\$0\)\n\s*\(i32\.const 8\)\n\s*\)\n\s*\)\n)"
        r"\s*\(if\n\s*\(local\.get \$7\)\n\s*\(then\n\s*\(return\n\s*\(local\.get \$0\)\n\s*\)\n\s*\)\n\s*\)",
        re.M)

    def repl1(m):
        return (m.group(1) +
                "    (if\n"
                "     (i64.ne\n"
                "      (local.get $2)\n"
                "      (i64.const 9222246136947933187)\n"
                "     )\n"
                "     (then\n"
                "      (return\n"
                "       (local.get $0)\n"
                "      )\n"
                "     )\n"
                "    )")

    text, n1 = pat1.subn(repl1, text)
    assert n1 == 1, f"fib is_truthy site: {n1}"

    # 循环的 is_truthy: (local.set $16 (call $143 (12,1,sp-8))) → br_if (i64.eq $6 TAG_FALSE)
    pat2 = re.compile(
        r"\(local\.set \$16\n\s*\(call \$143\n\s*\(f64\.const 12\)\n\s*\(f64\.const 1\)\n"
        r"\s*\(i32\.sub\n\s*\(global\.get \$global\$0\)\n\s*\(i32\.const 8\)\n\s*\)\n\s*\)\n\s*\)\n"
        r"(\s*\(global\.set \$global\$0\n\s*\(i32\.sub\n\s*\(global\.get \$global\$0\)\n\s*\(i32\.const 8\)\n\s*\)\n\s*\)\n)"
        r"\s*\(br_if \$block\n\s*\(i32\.eqz\n\s*\(local\.get \$16\)\n\s*\)\n\s*\)",
        re.M)

    def repl2(m):
        return (m.group(1) +
                "    (br_if $block\n"
                "     (i64.eq\n"
                "      (local.get $6)\n"
                "      (i64.const 9222246136947933187)\n"
                "     )\n"
                "    )")

    text, n2 = pat2.subn(repl2, text)
    assert n2 == 1, f"loop is_truthy site: {n2}"
    return text


def main():
    lines = open(SRC).read().split("\n")
    for ln in HOT_SITES:  # 先补高行号, 避免前次替换平移行号
        lines = replace_site(lines, ln)
    v1 = "\n".join(lines)
    open(OUT1, "w").write(v1)
    v2 = inline_is_truthy(v1)
    open(OUT2, "w").write(v2)
    left1 = sum("(call $142" in l or "(call $143" in l for l in lines)
    left2 = sum("(call $142" in l or "(call $143" in l for l in v2.split("\n"))
    print(f"{OUT1}: js_add 热路径内联完成, 剩余桥调用 {left1} (2×is_truthy + 2×console_log + 4×打印串接)")
    print(f"{OUT2}: is_truthy 内联完成, 剩余桥调用 {left2} (2×console_log + 4×打印串接)")


if __name__ == "__main__":
    main()
