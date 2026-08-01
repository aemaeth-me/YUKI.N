# Haskell 架构与 Effect 边界

> 状态：实施基线，2026-08-01。
> 本文规定源码依赖方向、Domain 纯度与渐进迁移方式；认知和记忆的业务语义仍分别以
> [cognition-design.md](cognition-design.md) 与 [memory/](memory/) 为准。

## 目标

YUKI.N 采用 functional core / imperative shell，但统一使用 `Domain` 作为源码层名称，
不再并列引入含义重叠的 `Core`。目标不是消灭 `IO`，而是让副作用的位置、所有者和事务
边界可见，使领域状态转换可以独立验证。

```text
Interface ------------> Application ------------> Domain
                              ^                      ^
                              |                      |
Infrastructure --------------+----------------------+

Composition root 装配所有层，但任何下层都不能反向依赖它。
```

| 层 | 职责 | 可包含的 effect |
|---|---|---|
| Domain | 领域类型、不变量、决策、纯状态转换 | 无 |
| Application | 用例编排、ports、跨 aggregate 流程 | 通过抽象 port 表达 |
| Infrastructure | 文件、网络、模型、时钟、ID、并发、store adapter | `IO`、锁、异常转换 |
| Interface | HTTP、AG-UI、CLI、JSON DTO、状态码映射 | 协议边界上的 `IO` |
| Composition | 构造并连接具体实现、启动和关闭资源 | 启动期 `IO` |

## 当前状态

当前只有一个 Cabal library，依赖方向靠模块划分与代码审查维持，没有编译器级强制。
已落地的源码边界：

- `Yuki.N.Domain.Diff`：纯 unified diff 算法。
- `Yuki.N.Domain.Context`：纯上下文压缩算法；工具规格以显式 token 代价标量传入，
  JSON 序列化与 provider 兼容启发式（如上下文溢出判定）留在 `Yuki.N.Context` 门面。
- `Yuki.N.Domain.Model`：Domain 实际消费的纯 chat 值类型（`ChatMessage`、
  `AssistantTurn`、`ModelToolCall`），不持有 JSON 实例；序列化实例以刻意保留的孤儿
  实例留在 `Yuki.N.Model`（journal/金样/provider wire 契约，逐字节兼容）。
  provider/运行时值类型（事件、终止原因、工具执行/结果、用量）保留在 `Yuki.N.Model`。
- `Yuki.N.Model` / `Yuki.N.Context` 是兼容门面，保持迁移前的公开签名与 JSON 行为。

尚未迁移的区域（`Experience`、`Incarnation`、`Memory.Working` 实体、store adapter、
`Agent`/`Cognition` 用例、`Server`/AG-UI DTO）按需逐步提取，不设时间表。

## Domain 契约

Domain 模块必须满足：

1. 所有结果仅由显式输入决定；时间、ID、随机值和配置由调用方提供。
2. 预期失败通过稳定错误类型或 `Either` 返回，异常只在外层 adapter 捕获和翻译。
3. 状态转换返回新状态与领域事件，不执行持久化：

```haskell
transition :: Command -> State -> Either DomainError (State, [DomainEvent])
```

4. 不依赖 `IO`、`ST`、锁、可变引用、线程、FFI、unsafe、文件、网络、环境或系统时间。
5. 不依赖 HTTP/AG-UI/JSON DTO；序列化实例若确有持久兼容需求，必须单独评审。
6. 尽量使用 total function，并通过 smart constructor 维护不可表示的非法状态。

Domain 纯度由本仓库的 `AGENTS.md`、本文档化规则和代码审查维护；不引入自定义词法/
领域检查器，也不新增串行 CI gate。若未来需要编译器级约束，优先拆 Cabal internal
library，而不是长期维护一套 Haskell 词法检查器。

## Application 与 Infrastructure

Application 可以定义含 `IO` 或抽象 `m` 的 port，但不能知道 `MVar`、文件路径布局、HTTP
client 或具体 provider。现有 `ExperienceStore`、`WorkingStore` 等 record-of-functions 是
可保留的 port 形态。

Infrastructure adapter 负责：

- 获取时间和 ID 后调用纯 transition；
- 在唯一 state owner 下原子提交新状态；
- 持久化并把底层异常转换为稳定失败；
- 保证锁内没有模型调用、网络调用或其他无界操作；
- 提供 file adapter 与 memory test double，但两者都不属于 Domain。

## 持久化与失败语义

- 每个 store 的 mutation 遵循「先持久化、成功后才安装新内存状态」；`Either Text ()`
  持久化的 store（Task Archive、LongTerm）在失败时保留旧状态并把 `Left` 上抛。
- 分身删除用例（`Cognition.deleteIncarnation`）按档案 → 派生存储 → 记录的顺序执行，
  任一环失败立即中止并返回 `Left`，不会在部分失败后误报成功。

## Applicative 规则

Applicative 表达“各计算互不依赖”，Monad 表达“下一步取决于上一步”。优先级依据语义而非
语法可改写性：

- 独立字段验证、独立读取和结构组装适合 Applicative。
- 依赖结果、短路、事务、资源生命周期和明确顺序适合 Monad。
- `Applicative IO` 默认仍按其实例执行，不自动并行；并发必须显式、受控。
- HLint 的 Applicative/point-free 建议不自动应用；若组合表达式比具名步骤更难审查，应保留
  清晰的 monadic 写法或明确忽略该规则。

## 迁移顺序

1. 建立 `Yuki.N.Domain.*` 与仓库规则。
2. 将纯 model/chat value 与 effectful provider function 分开，使 Context 可进入 Domain。
   （已完成，见「当前状态」。）
3. 提取 Experience append transition：adapter 只负责时钟、锁与追加文件。
4. 依次提取 Incarnation、LongTerm、Archive 的纯 mutation，并保留旧模块 facade。
5. 在测试覆盖下提取 Working sleep/wake 状态机。
6. 将 store 构造从 Cognition 移到 Infrastructure/Composition，并让 Application 只接收 ports。
7. 将 Server 收窄为 Interface adapter；最后解除 Application 对 AG-UI DTO 的反向依赖。
8. 当 Domain/Application 模块数量稳定后，再拆 Cabal internal libraries；`base` 内仍可访问
   effectful module，因此 Domain 纯度继续作为强制代码审查项。

## 验收

每次边界迁移必须同时通过：

```console
fourmolu --mode check $(git ls-files '*.hs')
hlint src app test
cabal build all
cabal test yuki-n-test --test-show-details=direct
haskell-language-server-wrapper --test src/Yuki/N.hs app/Main.hs test/Main.hs
```

持久化格式、HTTP contract 与 golden journal 均属于兼容边界，不能以“纯化”为由删除或
绕过现有测试。
