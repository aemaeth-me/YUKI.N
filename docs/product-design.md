# YUKI.N 产品化设计

> 状态：历史实现设计。三视图已经落地，但不再代表目标产品模型。
> 新领域模型见 `docs/incarnation-design.md`；新 UI/UX 基线见 `docs/frontend-redesign.md`。

实验台曾以三视图（工作 / 配置 / 审计）覆盖同一 runtime。以下内容仅用于理解现有实现与迁移来源；冲突时以新文档为准。

## 三视图

- **工作**：会话（绑定 cwd）、md 渲染模型正文、diff 渲染文件改动、CoT 折叠卡、目录树、上下文表（真实 token/ cache 命中）、tools 齐全（fs/shell）。
- **配置**：全局生效配置一览；会话级覆盖（cwd、system prompt、模型、tools 开关、memory 开关），resolve 序 = 会话 > 环境。
- **审计**：以 run 为单位的卡片（轮数、token、工具、状态、时间），可检索、过滤、钻取。AG-UI 事件流降级为钻取内的一个 facet；其余 facet：线级 API 请求、watcher 决策、工具调用、原始条目。

## 后端新增

### Tools 层（Yuki.N.Tools + Yuki.N.Diff）

- `fs_read / fs_write / fs_edit / fs_list / shell`，构造于 cwd；路径 canonicalize 后强制 cwd 前缀，越界即败。
- `fs_write/fs_edit`：outcome content = unified diff（行 LCS，上下文 3，纯函数零依赖）；全文入 artifact store（若配置）。
- `fs_read`/`shell` 输出超阈：全文入 artifact，返回头尾+引用（与落地外置同一律）。
- `shell`：`sh -c`，cwd 锁定，合并 stdout/stderr，带 exit code。

### 配置层（Yuki.N.ThreadConfig 或并入 Memory）

- 存贮：`<dir>/threads-config/<sanitized-id>.json`：`{cwd, systemPrompt?, model?, tools?: {fs?, shell?}, memory?}`。
- `resolveRuntime :: Runtime -> ThreadConfig -> Runtime`：cwd 决定 fs/shell 工具集（未设 cwd 不注册）；systemPrompt 覆盖；model 按名重建（同 provider 配置换名）；memory=false 时摘除 memoryHooks。
- 端点：`GET/PUT /config/threads/:id`、`GET /config`（全局生效值）。

### 审计层

- **usage**：provider 请求带 `include_usage`；流尾解析 usage（prompt/completion/cached tokens），新 `ModelEvent` 构造子 → ResponseState 收集 → agent 以 `Custom "usage"` 事件上流并入 journal。
- **线级 API**：OpenAIConfig 增可选 `openAISink :: Maybe (Value -> IO ())`；provider 在 POST 前以最终渲染的 `requestValue` 调用之。Yuki/N.hs 接线 → journal 新条目 `api.request`（Value）。

## 阶段

| 步 | 内容 | 验收 |
| --- | --- | --- |
| A | 工具层 + Diff（沙盒、diff 为 outcome、大输出入 artifact） | 沙盒逃逸拒、diff 正确性、shell 捕获、单测绿 |
| B | 会话配置层（存贮、resolveRuntime、端点） | 覆盖生效、端点读写、单测绿 |
| C | usage 捕获 + api.request 条目 | 假流含 usage 即收集并上事件；sink 得最终 JSON；单测绿 |
| D | 工作视图（tabs、cwd 新会话、md/diff/COT、树、上下文表） | 编译过、真实链验 |
| E | 配置视图（全局一览 + 会话编辑） | 编译过、PUT 生效 |
| F | 审计视图（run 卡片、过滤、钻取四 facet） | 编译过、真实链验 |

## 决策

- shell 裸命令 + cwd 锁（审计问责，无白名单）。
- diff 即 outcome content：模型与人同通道。
- 会话 > 环境的 resolve 序；未设 cwd 即无 fs/shell 工具（默认紧闭）。
- AG-UI 事件流在审计中仅为 facet 之一，不再是审计本身。
