# 编译开关侦察 (tools/attribution/switch_recon/)

目的：枚举 perry / typerry / wamrc 中所有可能影响 **wasm 产物性能**的开关，逐个实测，回答"有没有现成开关能改善 perry wasm 的性能"。

一键复现（脚本内 `OUT=/tmp/rc_work`，故先落到那里）：

```bash
mkdir -p /tmp/rc_work && cp tools/attribution/switch_recon/*.sh tools/attribution/switch_recon/*.mjs /tmp/rc_work/
bash /tmp/rc_work/round4.sh      # 结论依据: 交错 3 遍 × 12 样本 A/B
bash /tmp/rc_work/matrix.sh      # 31 个 wamrc 开关 × 2 产物全扫
```

结论：**perry 侧没有任何开关**——CLI flag（17 个）、环境变量、`@typerry/node` 的 `minify` 参数，全部产出**字节相同**的 wasm。
**wamrc 侧只有 `--enable-segue` 有效**，配 `--target=x86_64 --disable-llvm-jump-tables` 时 122.14 → 99.84 ms（**−18.3%**，交错复测稳定）；
仍 ~71× 慢于原生 1.4 ms，根因（`+` → 动态分派桥调用）未被任何编译开关触及。

⏱ 计时约束：`bench_merged_*.aot` 在 `build/aot_time` 下**第 4 轮必崩**（`Exception: string table overflow` → `run 4 failed: unreachable`，3 次复现一致），
故 merged 固定用「每进程 3 轮 × 4 进程」= 12 样本；`clean_bench.aot` 无此问题，可直接跑 12 轮。

详见 `REPORT.md`（逐开关表格 + 依据命令 + `%gs:` 反汇编证据 + 未验证项），原始实测输出为 `*_results.psv` / `cli_results.txt`。
