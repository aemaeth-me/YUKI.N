# HippoRAG 2: From RAG to Memory — Non-Parametric Continual Learning for LLMs

- **arXiv**: 2502.14802 (cs.CL) | 2025-02-20 | ICML 2025（PMLR 267:21497-21515）
- **作者**: Bernal Jiménez Gutiérrez, Yiheng Shu, Weijian Qi, Sizhe Zhou, Yu Su（OSU-NLP-Group）
- **本地原始资料**: `sources/papers/hipporag2-2502.14802.html`（arxiv HTML 全文）

## 核心思想
HippoRAG（NeurIPS'24，神经科学启发的长期记忆，海马体索引理论：LLM=新皮层、开放 KG=人工海马体、PPR=模式补全）的升级版。修复原版"实体中心导致上下文丢失 + 语义匹配困难"的关键缺陷，把非参数 RAG 推向更接近人类长期记忆的"事实/意义建构/联想"三类记忆统一效果，为非参数持续学习铺路。

## 记忆架构
- **离线索引（记忆编码）**：LLM 以 OpenIE 提取 schemaless KG 三元组（phrase 为节点，relation 为边）→ 检索编码器识别同义词加同义边 → phrase-KG 与原文 passage 结合（概念+上下文信息，提升原子性）→ 形成开放 KG。
- **在线检索**：查询→三元组链接（识别记忆过滤掉不相关候选 seed）→ phrase 节点+passage 节点共同作为 seed → PPR 分配 reset 概率（phrase 按排名、passage 按嵌入相似度×权重因子0.05）→ 以 PageRank 排序 passage 供下游 QA。
- **三个改进**：(1) 概念+上下文信息整合；(2) 利用 KG 结构做上下文感知检索（不止孤立节点）；(3) recognition memory 过滤 seed 节点选择。

## 创新点
1. 首次在事实记忆（NaturalQuestions/PopQA）、意义建构（NarrativeQA）、联想记忆（MuSiQue/2Wiki/HotpotQA/LV-Eval）三轴上全面超过标准 RAG 与 embedding 模型。
2. 联想任务较 SOTA embedding 模型 +7%，同时保住事实与意义建构能力（此前 GraphRAG 类方法牺牲事实记忆）。
3. 在线检索保持 10-30x 更便宜、6-13x 更快（vs IRCoT），离线索引资源远低于 GraphRAG/RAPTOR/LightRAG。

## 局限
- 仍是检索式记忆，无显式遗忘/更新策略（持续学习需靠增量加图）。
- passage 权重因子 0.05 是手工调参。
- 图谱维护成本随语料增长上升。

## 对 Memory 设计的意义
"开放 KG + PPR + 同义边"是图记忆检索的黄金基线；其 recognition-memory 过滤（先召回再判别 seed）思路可直接移植到 agent 记忆的检索前置过滤。
