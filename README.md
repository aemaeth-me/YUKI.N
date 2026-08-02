# YUKI.N

> 资讯统合思念体对有机生命体接触用人形界面

YUKI.N 是一个本地单用户的 Agent 集群工作台。你管理若干位持续存在、各自
记得、各自成形的 Yuki；每位 Yuki 有自己的主对话（主 Agent）、可派发持久
任务（任务 Agent），任务与对话都能再派出临时 Worker（Subagent）——三层
编排的实时状态、交付物与文件系统变更，全部在工作台上可见。

## 运行

```console
export DEEPSEEK_API_KEY=...
./yuki
```

启动器检查环境并同时拉起后端（`:18080`）与前端（<http://127.0.0.1:15173>）。
`Ctrl-C` 一并停止两者。其他选项：`./yuki --check`（只检查）、
`./yuki --rebuild`（强制重建）。

打开浏览器后进入**集群总览**：每位 Yuki 一张卡片，显示它此刻在跑什么、
等待什么、最近交付了什么。点卡片进入该 Yuki 的工作台。

## 工作台速览

| 视图 | 你会看到 |
| --- | --- |
| 现在 | 活跃 Run 树（主对话/任务/Worker 三层状态卡）、待确认事项、最近交付 |
| 主对话 | 与这位 Yuki 的默认对话；聊天、派发任务、确认 Yuki 的提议 |
| 任务 | 这位 Yuki 的全部持久任务；点进任意任务的对话 |
| 交付 | 答案 / 文件 / artifact 的交付流，可展开、可检索 |
| 变更 | 文件系统变更台账：路径、操作、diff、来源（工具或 git 补记） |
| Run 监控 | 任一 Run 的钻取视图：状态、Worker 子树、交付与变更、steer/取消 |

状态卡显示：阶段（运行/等待工具/压缩/睡眠/取消中）、轮次、模型、token
用量、上下文占用、进行中的工具与耗时——全部来自后端遥测，实时推送。

## 三层编排

```text
Yuki（持久主体：人格 + 记忆 + 默认能力）
├── 主对话 Run（主 Agent：聊天、判断、提议派发）
├── 任务 Run（任务 Agent：一项持久工作的 Orchestrator）
└── Worker Run（临时执行者：随父 Run 消亡，不可持久）
```

- **派发任务**：主对话里点「派发任务」→ 编辑自动生成的草案（标题、任务
  Prompt、能力快照）→ 确认 → 任务开始执行。Yuki 也会主动提议派发，同样
  必须经你确认。
- **Worker**：主 Agent 与任务 Agent 都能用 `sub_agent` 族工具派生临时
  Worker（默认最多并行 4 个、不可再委派、只读记忆）。你能在工作台上直接
  steer 或取消任何一个 Worker。

## 配置（常用）

| 环境变量 | 默认 | 说明 |
| --- | --- | --- |
| `DEEPSEEK_API_KEY` | — | 默认 provider 的密钥 |
| `YUKI_PROVIDER` / `YUKI_MODEL` / `YUKI_BASE_URL` / `YUKI_API_KEY` | DeepSeek V4 Flash | 主模型链 |
| `YUKI_DATA_DIR` | `~/.yuki-n` | 全部本地状态的位置 |
| `YUKI_MAX_TURNS` | 32 | 单次 Run 的轮次保护 |
| `YUKI_SUBAGENT_DEPTH` | 1 | 委派深度 |
| `YUKI_SUBAGENT_MAX_PARALLEL` | 4 | 单 Run 活跃 Worker 上限 |

完整配置表见 [docs/06-配置.md](docs/06-配置.md)。

## 文档

- [快速上手](docs/01-快速上手.md)
- [工作台各视图](docs/02-工作台.md)
- [派发任务](docs/03-派发任务.md)
- [Subagent 与编排](docs/04-Subagent与编排.md)
- [记忆与睡眠](docs/05-记忆与睡眠.md)
- [配置](docs/06-配置.md)
- [HTTP 与事件](docs/07-HTTP与事件.md)
- [数据与审计](docs/08-数据与审计.md)
- [开发](docs/09-开发.md)
- [已知限制](docs/10-已知限制.md)

## 开发

```console
cabal build all && cabal test all   # 后端：构建 + 367 项测试
cd frontend && npm run build        # 前端：Elm 构建
cd frontend && npm test             # 前端：JS 测试
```

代码风格与架构规则见仓库根目录 `AGENTS.md`。
