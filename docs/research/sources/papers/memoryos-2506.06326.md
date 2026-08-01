# Memory OS of AI Agent (MemoryOS)

- **arXiv**: 2506.06326 (cs.AI) | 2025-05-30 | EMNLP 2025 Oral | GitHub: BAI-LAB/MemoryOS
- **作者**: Jiazheng Kang, Mingming Ji, Zhe Zhao, Ting Bai（北航）
- **本地原始资料**: `sources/papers/memoryos-2506.06326.html`（arxiv HTML 全文）

## 核心思想
受操作系统内存管理启发，构建个人化 AI agent 的记忆操作系统。采用**分段分页（segment-paging）** 与 **热度驱动替换（heat-based eviction）** 组织对话历史，实现分层存储、动态更新、语义检索三位一体。

## 记忆架构（三层存储 + 四模块）
- **存储层级**：
  - STM（Short-Term Memory）：实时对话，单位是 dialogue page `{Q_i, R_i, T_i}`，按对话链组织，FIFO 队列。
  - MTM（Mid-Term Memory）：按主题聚类的 dialogue pages → segments（LLM 摘要段），保存高参与度话题的细节。
  - LPM（Long-term Personal Memory）：User Profile（静态）+ User KB（动态事实）+ User Traits（90 维个性特征，三大类）+ Agent Profile/Traits。KB 与 Traits 用固定容量（100）FIFO。
- **更新机制**：
  - STM→MTM：FIFO 满则最旧页升迁。
  - MTM→LPM：Heat 分数 = 检索次数×w₁ + 页数×w₂ + 时间衰减×w₃；heat 超过阈值(5)的 segment 升迁 LPM，低 heat 段被逐出。
  - 升迁后 heat 归零，保证 personae 持续演化不冗余。
- **检索**：STM 全量；MTM 两级（先语义匹配 segment，再段内取页）；LPM 取 top-10 语义相关 KB/Traits 条目。
- **生成**：三类检索结果合成 prompt。

## 创新点
1. 首次把 OS 的 segment-page 内存管理直接搬进对话 agent，heat-based eviction 平衡"近期/高频/深度参与"三要素。
2. 可插拔 memory modules（storage/update/retrieval），并提供 MemoryOS-MCP 注入任意 AI 应用。
3. 用 90 维 User Traits 做细粒度个性化画像演化。

## 实验结果（论文口径）
LoCoMo 上较基线平均提升 F1 49.11%、BLEU-1 46.18%（GPT-4o-mini）。

## 局限
- 面向长对话个人化场景；对 agentic/tool-use 环境（MemoryArena 类）未验证。
- heat 阈值、队列容量为手工超参，非学习得到（其后 RL memory agent 论文正批评这一点）。
- 多轮 QA 之外的复杂推理收益有限（Memora 基准中 reasoning 分数低）。

## 对 Memory 设计的意义
提供"对话页→主题段→用户画像"三级升迁的具体机制（FIFO + heat + 时间衰减），是 OS 式分层记忆最可工程化的实现之一；heat 策略可作默认 eviction 策略基线。
