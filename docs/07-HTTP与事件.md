# 07 HTTP 与事件

后端默认 `127.0.0.1:18080`。除 SSE 流外全部为 JSON。

## 运行（Run）

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| POST | `/agent` | AG-UI SSE 流，执行一次 Run（见下文事件表） |
| POST | `/agent/steer` | `{runId, text}` 向运行中的 Run（含 Worker）注入引导，202 |
| POST | `/agent/cancel` | `{runId}` 取消 Run，202；其子 Worker 级联取消 |
| POST | `/agent/follow-up` | `{runId, text}` Run 收尾阶段追加输入 |
| POST | `/replay` | 回放 journal 审计 |

## 集群与遥测

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/fleet` | 集群快照：各 Yuki 状态 + 全局活跃 Run |
| GET | `/activity/stream` | 监控 SSE 流（见下文帧表） |
| GET | `/incarnations/:id/activity` | 单 Yuki 快照：home、活跃 Run、待确认草案、最近交付 |
| GET | `/incarnations/:id/deliveries?threadId&limit&before` | 交付台账分页 `{items, hasMore}` |
| GET | `/incarnations/:id/fs-changes?threadId&runId&limit&before` | 变更台账分页 |

## 派发（Dispatch）

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| POST | `/incarnations/:id/dispatches` | `{input}` 生成草案，202 |
| GET | `/incarnations/:id/dispatches?status=draft` | 待确认草案列表 |
| GET | `/dispatches/:id` | 单份草案 |
| PATCH | `/dispatches/:id` | `{title?, prompt?, config?}` 编辑（仅 draft） |
| POST | `/dispatches/:id/confirm` | 确认派发 → 201 `{threadId}` |
| POST | `/dispatches/:id/cancel` | 取消草案 |

## Yuki 与任务

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET/POST | `/incarnations` | 列出 / 创建 Yuki |
| GET/PATCH | `/incarnations/:id` | 读取 / 修改（名称、方向） |
| POST | `/incarnations/:id/(archive|restore|delete)` | 生命周期 |
| GET | `/incarnations/:id/home` | 幂等获取主对话 `{threadId, meta, config}` |
| GET | `/incarnations/:id/tasks` | 该 Yuki 的任务 |
| GET | `/threads?kind=task|home|all` | 任务列表（默认 all） |
| POST | `/threads` | 手动创建任务（高级路径，不经派发） |
| PATCH | `/threads/:id` | 重命名 |
| POST | `/threads/:id/(archive|restore|fork|compact|sleep)` | 生命周期与上下文操作（对 home 一律 400） |
| GET | `/threads/:id/(transcript|export)` | 对话投影 / 导出 |
| POST | `/threads/import` | 导入 |
| GET/PUT | `/config/threads/:id` | 任务级配置读写 |
| GET | `/config/threads/:id/capabilities` | 该任务解析后的实际工具列表 |

## 记忆（查询）

`/incarnations/:id/(impression|working-memory|sleep-cycles|experiences|task-records|memories)`、
`/incarnations/:id/(task-records/search|memories/search)`、`/threads/:tid/context-epochs` 等。
明细与参数见源码 `src/Yuki/N/Server.hs` 路由表。

## 审计

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/journal`, `/journal/runs` | Run 列表 |
| GET | `/journal/runs/:id/(summary|trace)` | 单 Run 摘要 / 聚合轨迹 |
| GET | `/artifacts`, `/artifacts/:id` | artifact 索引与正文 |

## `POST /agent` 事件流（AG-UI + 扩展）

标准帧：`RUN_STARTED / RUN_FINISHED / RUN_ERROR / STEP_STARTED /
STEP_FINISHED / TEXT_MESSAGE_* / TOOL_CALL_* / REASONING_*`。

自定义（`CUSTOM`）帧：`agent.sub`（同步子代理包装事件）、
`worker.notice`（异步 Worker 终局通告）、`dispatch.draft`（Yuki 提议的
派发草案）、`context.status`、`context.compact`、`context.sleep`、
`steering.inject`、`followup.inject`、`provider.retry/fallback`、`usage`、
`run.cancelled`、`plan`、`shell.output`。

## `/activity/stream` 帧

连接建立先发 `event: snapshot`（集群全量），随后增量：

| event | data | 含义 |
| --- | --- | --- |
| `status` | LiveStatus | 某 Run 状态（200ms 节流合并） |
| `run.end` | `{runId, outcome}` | Run 终局（completed/failed/cancelled） |
| `delivery` | DeliveryRecord | 新交付记录 |
| `fschange` | FsChangeRecord | 新文件系统变更 |
| `draft` | DispatchDraft | 新派发草案 |
| `draft.resolved` | `{dispatchId, status, threadId?}` | 草案已裁决 |
| `: ping` | — | 15s 心跳注释 |

LiveStatus 主要字段：`runId / threadId / incarnationId / parentRunId /
kind(home|task|worker) / phase(running|awaiting-tool|compacting|sleeping|
cancelling) / objective / startedAt / lastEventAt / turn / maxTurns / model /
usage{promptTokens,completionTokens} / context{estimatedTokens,budgetTokens,
windowTokens} / activeTools[{callId,name,startedAt}] / workers /
lastActivity`。
