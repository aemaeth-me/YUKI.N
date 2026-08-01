# YUKI.N

> 资讯统合思念体对有机生命体接触用人形界面

YUKI 本位的本地单用户 Agent runtime。YUKI.N 容纳一位位持续存在、各自记得、
各自成形的 YUKI；每位对应一个 Incarnation。task/thread 只是一次工作，transcript
只是执行投影；短期记忆、长期记忆与印象分别治理。运行边界仍使用 AG-UI：
`POST /agent` 返回 SSE 事件流。

## 本机运行

```console
export DEEPSEEK_API_KEY=...
./yuki
```

这一个入口检查 GHC/cabal、Node/npm、provider 配置与端口，完成必要构建，同时
启动 backend 与 frontend；访问 <http://127.0.0.1:15173>。`Ctrl-C` 会一并停止
两个服务及受管后台任务。只检查而不启动：`./yuki --check`；强制重建：
`./yuki --rebuild`。平时仅在源码较新时重建，只有首次缺少前端依赖时才访问
npm registry。

启动器默认将项目根目录设为 `YUKI_WORK_DIR`；新任务继承它，因此主代理与
子代理都有明确列出的本机文件、命令能力。能力页会显示当前任务的实际能力。

启动与打开配置页不会请求 provider 的模型列表；只有发送消息才会访问所选
provider。backend 默认使用 `18080`，frontend 默认使用 `15173`。两个服务
留在启动器的进程组内，启动器退出时随之停止，不在后台遗留监听进程。

默认使用 DeepSeek V4 Flash，并通过 DeepSeek Responses API 调用；也可设置 `YUKI_PROVIDER`、`YUKI_MODEL`、
`YUKI_BASE_URL`、`YUKI_API_KEY`。本机状态默认写入 `~/.yuki-n`；
`YUKI_DATA_DIR` 可改其位置。认知状态始终持久化于 `cognition-v2`；
`YUKI_MEMORY_DIR` 可另定其根目录，`YUKI_MEMORY_MODEL` 可为 Prompt、Sleep 与
Impression 的内部调用指定模型；未指定时沿用主模型。

### 单次运行的轮次保护

`YUKI_MAX_TURNS` 限制一次 run 内的模型调用轮数，默认 `32`。它是 YUKI.N
的本地防失控保护，不是 provider API 或上下文窗口的限制：模型若反复调用工具、
工具结果又令模型继续调用，理论上可以永不结束，同时持续消耗时间与 API 配额。
达到上限时，运行返回 `MAX_TURNS_EXCEEDED`，并保留已经产生的记录。

确属长任务时可在启动前提高，例如 `YUKI_MAX_TURNS=64 ./yuki`；若普通任务触发，
应先从运行审计中检查重复工具调用或未能收敛的计划。该值改变后须重启服务。

界面会区分本地轮次保护、provider、持久化、未分类运行时异常与浏览器传输错误，
同时保留错误码和原始详情；历史中的旧式
`AGENT_ERROR · maximum agent turns exceeded` 也按本地轮次保护解释。

HTTP 入口为 `POST /agent`，最小请求体：

```json
{"threadId": "t", "runId": "r",
 "messages": [{"id": "u", "role": "user", "content": "你好"}]}
```

## 审计

通过 `./yuki` 启动时，每次 run 的效应记入
`$YUKI_DATA_DIR/journal.jsonl`（默认 `~/.yuki-n/journal.jsonl`）；
`cabal run yuki-n -- replay <file> [RUN_ID]` 回放并对账（前提：hooks 确定）。

界面在每次模型调用前显示上下文估算与预算。达到边界或主动请求时，Yuki 进入
Sleep：冻结 ContextEpoch，先裁决遗忘项，再生成 WakePacket，于同一任务醒来继续。
原文仍在本机 Blob / Experience / Journal 中可审计，不再留在活跃短期记忆。

### 睡眠判定与上下文配置

自动 Sleep 不按轮数触发。每次模型调用前计算：

```text
触发线 = max(256, 模型上下文窗口 - 预留 token - 工具定义 token)
```

消息 token 估算严格大于触发线时压缩。多 provider 链取已知上下文窗口的最小值；
模型未声明窗口时，以 `max(1024, YUKI_SPLICE_CHARS / 3)` 回退。工具定义按其
JSON 字节数除以 3 估算；消息另计每条 4 token，非 ASCII 字符按 1 token、ASCII
按约 3 字符 1 token 保守估算。

能力页的上下文策略可为当前任务覆盖：

- `预留 token`：直接控制时机；越大越早，默认 `16384`。
- `保留轮组`：压缩后保留的最近因果轮组上限，默认 `12`；工具调用及其结果不可拆。
- `摘要上限`：旧上下文摘要的 token 上限，最小 `96`，默认 `2048`。

留空即继承全局。全局值仍可分别用 `YUKI_CONTEXT_RESERVE_TOKENS`、
`YUKI_CONTEXT_KEEP_UNITS`、`YUKI_CONTEXT_SUMMARY_TOKENS` 设置。当前源码固定
DeepSeek V4 Flash 与 GLM-5.2 为 `1000000`、Kimi K3 为 `1048576`；改模型时同步
改 `Providers.hs`。provider 明确返回 context overflow 时，系统只再做一次
半预算的紧急压缩与重试。

## 开发

```console
cabal build all && cabal test all
```

### 测试体系

测试按领域拆分为 `test/Yuki/N/*Test.hs`（+ `test/E2E.hs`、`test/Golden.hs`），
`test/Main.hs` 只负责注册各组；测试模块之间不互相 import（Golden 与 E2E 为历史例外）。

```console
cabal test yuki-n-test --test-show-details=direct   # 全量单元/属性/E2E/golden
cabal test yuki-n-test --enable-coverage --coverage-for=lib:yuki-n   # 仅统计库模块覆盖率
```

属性测试使用 tasty-quickcheck（默认 100 次/条，新增属性均控制在 200 次内、整套 <2 秒）。

#### 文档即测试门禁

每条 `testCase`/`testProperty` 必须引用本模块具名顶层实现，且紧邻声明前有 `-- |` 文档块，
包含行为规格、`背景：` 与 `变更记录：`（带 `- YYYY-MM-DD:` 日期条目）。静态检查器：

```console
python3 scripts/check-test-docs.py
```

检查器覆盖 `test/**/*.hs`：拒绝匿名 body、要求注册实现有相邻文档块、文档块必须含
`背景：`/`变更记录：`/日期条目；`testGroup` 与辅助函数豁免；Golden 的
`replayOf scenario`/`deterministicOf scenario` 分派会递归校验其 case 分支目标。
注册必须单行书写（`testCase "标题" body`），任何拆行注册都会报违规，防止静默漏检；
注释、字符串字面量与 import 行中的同名符号不会被误判。检查器自测：

```console
python3 -m unittest scripts/test_check_test_docs.py
```

CI 依次运行文档门禁、检查器自测与覆盖测试，任一步失败即红灯。

#### Haskell 架构边界

源码分层、Domain 纯度和 effect 所有权见
[`docs/haskell-architecture.md`](docs/haskell-architecture.md)。仓库级 `AGENTS.md` 规定 Domain
禁止 `IO`、`ST`、并发、系统资源、FFI 和 unsafe escape，并要求在代码审查中逐项检查边界。

#### Haskell 开发工具

项目使用显式 `hie.yaml` 将 `src/`、`app/`、`test/` 分别映射到 Cabal 的
library、executable、test-suite component。编辑器只需启动一个 HLS client。

Haskell 源码统一使用 Fourmolu `0.20.0.0`，配置见 `fourmolu.yaml`：

```console
fourmolu --mode inplace $(git ls-files '*.hs')
fourmolu --mode check $(git ls-files '*.hs')
```

HLint `3.10` 用于语义与惯用法检查，不承担格式化：

```console
hlint src app test
```

CI 会拒绝未格式化代码和 HLint error；HLint warning 暂作为代码审查提示，待现有
warning 基线逐步清理后再提升为强制门禁。
