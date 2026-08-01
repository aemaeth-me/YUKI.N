# MemOS: A Memory OS for AI System

- **arXiv**: 2507.03724 (v4) | 2025-07-04；短版 2505.22101（2025-05-28）
- **作者**: Zhiyu Li, Shichao Song, Hanyu Wang, Simin Niu, Ding Chen, ... Feiyu Xiong（上海 AI Lab 系）
- **本地原始资料**: `sources/papers/memos-memory-os-2507.03724.html`（arxiv HTML 全文）；GitHub: MemTensor/MemOS

## 核心思想
把记忆提升为一等可调度资源，构建 LLM 的记忆操作系统。统一三种记忆类型（parametric、activation、plaintext）的表示/调度/演化，通过 **MemCube** 作为统一封装单元，建立记忆生命周期管理（生成→激活→融合→归档→过期）与治理。

## 记忆架构
- **MemCube**：统一内存单元，封装语义负载 + 元数据（provenance、versioning、创建/访问时间、优先级、过期时间、访问控制）。可组合、可迁移、可融合，是检索式记忆与参数化学习之间的桥梁。
- **三类记忆**：
  - Plaintext Memory：明文，插入 prompt（时间敏感/会话知识）；
  - Activation Memory：KV-Cache，降低 prefill 延迟（高频稳定内容）；
  - Parameter Memory：蒸馏/adapter 编码进权重（可复用规则与模式）。
- **三层架构**：Interface Layer（MemReader 解析自然语言为 memory 操作链 + Memory API）；Operation Layer（MemScheduler 依据任务语义/调用频率/内容稳定性选择记忆类型与调用路径、MemLifecycle 状态机、MemOperator 建 tag/语义索引/图拓扑）；Infrastructure Layer（MemVault、MemGovernance 权限/审计、MemStore 发布订阅）。

## 创新点
1. 明确宣称"最早提出 Memory Operating System 概念"（2025-05-28 短版）。
2. MemCube 让异构记忆（参数/KV/明文）在一个抽象下可调度、可追溯、可迁移。
3. 显式治理层（权限、审计、版本回滚、冻结）——这是其它记忆系统普遍缺失的，与企业落地相关。

## 局限
- 系统/工程框架为主，缺少强基准实验（LoCoMo 类评测不充分，多为主观定性）。
- MemScheduler 的调度策略仍是启发式/可插拔，非端到端学习。
- 概念层级多，实际可复现性依赖 GitHub 实现的质量。

## 对 Memory 设计的意义
MemCube 是极好的"记忆单元"数据模型范本（内容+来源+版本+热度+过期+ACL）；三层架构（接口/调度/治理）可作为 agent 记忆基础设施的组织蓝图。
