---
id: paper-citation-scope
title: "论文引用口径：外部文献仅限 2.3 定位与 4.2 测量纪律（推翻「本文不引外部文献」）"
category: decision
status: active
tags: [paper, methodology, citations]
created: "2026-09-28T15:23:22"
updated: "2026-09-28T15:23:35"
---

<!-- compiled_truth -->
原口径（论文 1.4 与 2.3 曾逐字写明"本文不引外部文献"）**已推翻**。理由：Swales CARS 的 Move 2（指出缺口）无法靠自述成立——"无 JS 引擎宿主上的端到端归因此前未被量过"这一主张，只有对照 Jangda'19（浏览器宿主）、WarpDiff'23（运行时之间）、WALL-E'26（托管语言外部链接）、Mäkitalo'21（WAMR 侧模块链接）才成为可被读者核查的缺口，而非作者一面之词。

现行口径（写死为约束）：

1. 外部文献**只用于两处**——2.3 的技术坐标与缺口、4.2 的测量纪律出处（Mytkowicz ASPLOS'09）。
2. 实测素材仍全部一手：来自本仓库实测记录与上游公开仓库，不经文献检索产生，不编造参考文献。
3. 引述他人数字必须标原始出处，且**不并入本文的乘积矩阵**（避免混口径）。
4. 只拿到摘要的文献（Mäkitalo SAC'21）只能引其摘要所述目标，不得引数字。
5. 未被正文引用的范文（Raft、Jin'12 除 6.1 一处判据外）不进参考文献表——本表只 7 条，保持"每一条目都承重"。

对标动作与范文清单见 [[paper-narrative-benchmarks]]；`perry` wasm 侧的实测口径见 [[perry-wasm-runtime-bridge]]。


## Timeline

- time: 2026-09-28T15:23:22
  kind: decision
  summary: "Created this page: 论文引用口径：外部文献仅限 2.3 定位与 4.2 测量纪律（推翻「本文不引外部文献」）"
  source: "2026-09-28 与用户确认的三项改稿之首项"
  affects: [paper-citation-scope]

- time: 2026-09-28T15:23:22
  kind: decision
  summary: Rewrote compiled_truth to the new best understanding
  source: "改写 1.4 与 2.3，新增「参考文献」节（7 条）"
  affects: [paper-citation-scope]

- time: 2026-09-28T15:23:35
  kind: note
  summary: "澄清第 5 条：参考文献表实有 7 条且每条都被正文引用；Raft 只作叙事技术参照（见 [[paper-narrative-benchmarks]]），不入表；Jin'12 在表内且仅承重于 6.1 裁决段"
  source: "自查参考文献表与正文引用标记的一致性"
  affects: [paper-citation-scope]
