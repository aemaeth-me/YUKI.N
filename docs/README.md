# YUKI.N 设计文档

> 2026-08-01 合并重组：原 `Mem/`（记忆设计）、`MemDesign/`（领域调查）、`docs/` 旧正式文档
> 统一为本目录。历史文档已归档至仓库外 `docs-archive/`（工作区根）。

## 文档地图

| 入口 | 内容 | 关系 |
|---|---|---|
| **[cognition-design.md](cognition-design.md)** | 认知体系设计（权威） | 记忆子系统是认知的一部分；睡眠/上下文编译/运行次序/Invocation/不变式 |
| **[incarnation-design.md](incarnation-design.md)** | 分身、记忆与 Prompt 治理（概念权威蓝图） | 领域级概念构思；Memory 只是分身治理的一部分 |
| **[memory/](memory/)** | 记忆子系统设计（源码提炼） | 印象 / 工作记忆 / 长期记忆 / 生命周期 / 演进方向 |
| **[research/](research/)** | Agent Memory 领域调查资料库（2026-08 综述） | 演进依据；262 份第一手原始资料 + 7 份精读笔记 |
| [frontend-redesign.md](frontend-redesign.md) | 前端重设计（YUKI 本位） | 界面基线 |
| [frontend-product-model.md](frontend-product-model.md) | 前端产品模型（design/v1） | 实现基线 |

## 概念层级（重要）

```
Incarnation 治理   → incarnation-design.md（概念权威：三种自我、Intent 路由、Prompt 即程序）
Cognition          → cognition-design.md（实现权威：睡眠、上下文编译、运行次序、Invocation）
├── Memory 子系统  → memory/（印象 / 工作记忆 / 长期记忆 / 生命周期）
│   └── 演进依据   → research/（领域综述）
├── 执行回路        → run / tools / journal / replay（见源码与 cognition-design）
└── 自知与自我管理  → self_inspect / self_update（见 cognition-design）
```

**Memory 不代表 cognition**：记忆只是认知体系中的一个子系统（印象线索、工作记忆、
长期记忆），不覆盖分身治理、执行回路与自知这些概念层。

## 阅读顺序建议

1. `cognition-design.md` 建立认知整体图景；
2. `memory/` 深入记忆子系统（印象 → 工作记忆 → 长期记忆 → 生命周期）；
3. `research/00-综述报告` 需要设计依据时查阅（回顾：长上下文≠记忆、向量≠记忆、证据/建议分离）；
4. `memory/05-演进方向.md` 了解已评审的后续演进路线（召回 / SQLite 三轨 / 评测）。

## 已归档（仓库外 docs-archive/）

- `memory-design-旧.md`：旧 Thread 本位 memory/cache 机制（artifact/rollup/briefing/watcher）
- `product-design-旧.md`：旧三视图产品设计
- `cognition-design-2026-07-28原版.md`：cognition-design.md 重写前的原版
