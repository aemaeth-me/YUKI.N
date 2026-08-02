# AGENTS.md

本文件补充父目录规则，适用于本仓库。工程边界的完整说明见
[`docs/haskell-architecture.md`](docs/haskell-architecture.md)。

## Haskell 架构

依赖方向固定为：

```text
Interface -> Application -> Domain
Infrastructure -> Application / Domain
Composition -> Interface / Infrastructure / Application / Domain
```

- `Yuki.N.Domain.*` 只包含纯领域类型、规则、不变量和状态转换。
- `Yuki.N.Application.*` 编排用例并定义 effectful ports；不得依赖 Interface 或具体 Infrastructure。
- `Yuki.N.Infrastructure.*` 实现文件、网络、模型、时间、并发和持久化适配器。
- `Yuki.N.Interface.*` 负责 HTTP、AG-UI、JSON DTO 和协议映射，不直接实现领域决策。
- `Yuki.N` 与 `app/Main.hs` 是 composition root，负责装配，不承载领域规则。
- 旧模块尚未完成分层时视为迁移区；新领域逻辑必须进入 `Yuki.N.Domain.*`，不得继续扩大混合模块。

## Domain 纯度

`Yuki.N.Domain.*` 中：

- 禁止 `IO`、`ST`、`MVar`、`IORef`、STM、线程、锁、异常、FFI 和 unsafe escape hatch。
- 禁止文件系统、网络、环境变量、系统时间、随机数、JSON/HTTP DTO 和具体存储实现。
- 时间、ID、配置与外部结果必须作为显式参数传入。
- 预期失败使用领域错误 ADT 或 `Either`，不抛异常，不用裸异常文本代替稳定错误类型。
- 状态转换优先采用 `Command -> State -> Either Error (State, [Event])` 一类纯签名。
- 禁止 `head`、`tail`、`!!`、`fromJust`、`error` 等可避免的部分函数。
- Domain import 必须在代码审查中逐项说明；不得用通配规则掩盖跨层依赖。

## Effects 与并发

- `MVar`、`IORef`、STM 等只能存在于 Infrastructure 或明确的 composition/runtime 边界，不得通过公开字段泄漏给 Domain。
- 一个可变状态必须有一个明确 owner；持锁期间不得执行网络、模型调用或其他无界外部操作。
- Infrastructure 负责把底层异常转换为 Application/Domain 可理解的失败。
- 内存 store 仍属于 Infrastructure；它是 adapter/test double，不因“不落盘”而成为 Domain。

## Applicative 与 Monad

- 计算相互独立、组合结构比执行步骤更重要时，优先 `Applicative`。
- 后一步依赖前一步结果，或顺序、短路、资源生命周期、事务语义重要时，使用 `Monad`。
- `Applicative IO` 不表示并行；并行必须显式使用 `Concurrently`、`async` 等受控机制。
- 禁止三层及以上连续 `>>= \x ->` 右漂移嵌套（bind 金字塔）：参数设计先行，
  函数直接接收其所需值；相互独立的取值用 `liftA2` / `liftA3` 一次取出；前后
  依赖的步骤用 `>=>` / `<=<` 组合或提名为具名函数；确需顺序取多值时，`>>=`
  至多连续两步取值，其余逻辑移入具名 where/顶层函数。
- 新增或迁移的模块不得增加 HLint warning；现有 warning 按模块逐步清理，不借机机械改写无关代码。

### 测试中的 do 记法

- 测试明确允许在「准备 → 动作 → 断言」的顺序流程中优先使用 `do` 记法。
- 存在多个依赖绑定、资源/setup 生命周期或嵌套续延缩进时，可读性优先于
  Applicative/组合子风格。
- 不要机械改写一、两步的简单表达式；相互独立的计算仍可保持 Applicative。
- 测试中避免 point-free/Kleisli 改写；具名中间值更清晰时优先具名绑定。

## 验证

架构改动至少运行 Fourmolu、HLint、`cabal build all`、完整测试和 HLS 三个 component 的 typecheck。迁移旧模块时保留已有持久化、并发、HTTP 与 golden 行为测试。
