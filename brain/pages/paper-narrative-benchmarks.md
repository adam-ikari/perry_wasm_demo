---
id: paper-narrative-benchmarks
title: "论文叙事对标：可引范文与其叙事动作（含两篇不存在标题的警告）"
category: reference
status: active
tags: [paper, narrative, citations]
created: "2026-09-28T15:22:52"
updated: "2026-09-28T15:23:09"
---

<!-- compiled_truth -->
论文 `docs/paper/perry-wasm-paper.md` 的叙事骨架是「测量发现异常 → 归因 → 根因 → 修复验证 → 承认局限」。经全文核实的对标范文与各自动作：

| 范文 | 借用的动作 | 落地位置 |
|---|---|---|
| Jangda et al., *Not So Fast*, USENIX ATC'19 | 推翻前人口径开场；**rule out → quantify → therefore** 的自家脚手架排除；反例留正文 | 2.3 第一条线；4.4 基线自审 |
| Jiang et al., *WarpDiff*, ASE'23 | 比值型 oracle + 逐维留一（与本文乘积闭合校验同构）；"confirmed by the developers"；seven replicate experiments | 2.3 第二条线；5.2 |
| Jiang et al., *WALL-E*, FSE'26 (arXiv 2606.21919) | 能力缺口 → 第三条路 | 2.3 第三条线 |
| Shillaker & Pietzuch, *Faasm*, ATC'20 | "we do not use them" 式边界声明 | 8 章写法参照 |
| Mäkitalo et al., SAC'21 | 与路线三同题（wasm 模块划分与运行时链接）；**仅摘要可核，不得引其数字** | 2.3 |
| Mytkowicz et al., *Producing Wrong Data…*, ASPLOS'09 | 自我推翻的语域（"we may think we have a 7% slowdown when in fact we have a 8% speedup"）；重复 ⇒ 可复现行为而非异常值 | **4.2 三条测量纪律的出处**；6.1 |
| Jin et al., *Real-World Performance Bugs*, PLDI'12 | 排除法最强句；"性能由编译器照看"是错误认知 | 6.1 裁决段 |
| Ongaro & Ousterhout, *Raft*, ATC'14 | 「we set out to…」宣言句 + **一个贯穿实例反复回来** | **1.2 图 1** |

底层规则：Swales CARS 三移动（领地 → 缺口 → 占据缺口，缺口必须有外部文献才成立）；Hyland hedging/boosting（自己的直接测量用 boost，机制解释与外推用 hedge）；SPJ「one ping」与贡献可证伪。

**两篇标题不可引用**（多路检索无法证实存在，疑为记忆混淆）：*Firefly: An Optimized Implementation for Modular Linking of WASM modules*、*Understanding and Detecting Actual Memory Leaks in WebAssembly*。另：《The Tail at Scale》为 Dean + Barroso 两人，Mosh 是 USENIX ATC'12（非 NSDI'12）。


## Timeline

- time: 2026-09-28T15:22:52
  kind: decision
  summary: "Created this page: 论文叙事对标：可引范文与其叙事动作（含两篇不存在标题的警告）"
  source: "2026-09-28 三路网络调研（WebSearch/WebFetch 全文核实）"
  affects: [paper-narrative-benchmarks]

- time: 2026-09-28T15:23:09
  kind: decision
  summary: Rewrote compiled_truth to the new best understanding
  source: "2026-09-28 三路调研核实，已落地到 docs/paper/perry-wasm-paper.md（2.3 参考文献、图 1、4.2 纪律）"
  affects: [paper-narrative-benchmarks]
