# MemTrust: A Zero-Trust Architecture for Unified AI Memory System

- **arXiv**: 2601.07004 (cs.CR) | 2026-01-11
- **作者**: Xing Zhou, Dmitrii Ustiugov, Haoxin Shang, Kisson Lin
- **本地原始资料**: 搜索结果摘要（无本地 HTML；arxiv.org/html/2601.07004）

## 核心思想
AI 记忆走向统一上下文层（跨 agent 协作、多工具工作流），但集中化带来信任危机：用户敏感记忆数据暴露给云服务商。核心张力 = 个性化需求 vs 数据主权。MemTrust 提出五层抽象 + TEE 硬件背书的零信任架构，实现"本地等价安全 + 云端协作能力"。

## 记忆架构（五层 + TEE）
- 五层抽象：Storage → Extraction → Learning → Retrieval → Governance。
- 每层用 TEE（Intel SGX、AMD SEV-SNP、Intel TDX、AWS Nitro Enclaves、ARM CCA）保护：加密存储、机密推理（NVIDIA H100 TEE）加速记忆巩固、OIDC + 远端证明的治理层。
- "Context from MemTrust" 协议：跨应用安全共享上下文；侧信道加固的检索（访问模式混淆）。

## 关键结果（论文口径）
企业工作负载性能开销 <20%，同时提供本地等价机密性，支持上下文集中而不牺牲数据主权。

## 创新点
1. 第一次把 AI 记忆的整个生命周期纳入 TEE 可信计算基。
2. 五层抽象 + 多 TEE 适配的模块化安全架构。

## 局限
- 工程/系统导向，无记忆质量基准。
- 依赖 TEE 生态，非 TEE 环境无法部署。

## 对 Memory 设计的意义
当我们的记忆体系涉及敏感用户数据时，MemTrust 提示"分层安全边界"设计：存储加密、提取/检索在隔离环境、治理层做鉴权审计，且跨 agent 共享需要显式协议。
