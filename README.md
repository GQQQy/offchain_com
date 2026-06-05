# offchain_com

`offchain_com` 是一个把链下确定性计算和链上乐观验证连接起来的端到端原型。它的核心问题是：复杂计算不适合直接放到链上反复执行，但链下计算又天然缺少可信性。因此系统把“完整执行”放在链下，把“可审计承诺、争议定位和最小必要验证”放到链上。

这个 README 已整合原 `DESIGN_HANDOFF.md` 的全部交接内容。它不仅说明当前实现了什么，也说明为什么这样设计、每个模块解决什么问题、协议不变量如何一起保证端到端自洽。

## 文档导航

如果你是第一次接手项目，建议先读 [`docs/QUICKSTART.md`](./docs/QUICKSTART.md) 跑通本地测试和 E2E artifact，再回到本文理解完整协议设计。

常用入口：

- [`docs/README.md`](./docs/README.md): 文档索引和推荐阅读路径。
- [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md): 系统分层、模块职责和关键数据流。
- [`docs/PROTOCOL.md`](./docs/PROTOCOL.md): task、checkpoint、proof、challenge、DA 和 dispute game 协议细节。
- [`docs/ARTIFACTS.md`](./docs/ARTIFACTS.md): PureVM artifact 目录结构、manifest 字段和 `.env` 变量映射。
- [`docs/DEPLOYMENT_AND_OPERATIONS.md`](./docs/DEPLOYMENT_AND_OPERATIONS.md): 部署、脚本、监控和生产化边界。
- [`docs/PUREVM_SEMANTICS.md`](./docs/PUREVM_SEMANTICS.md): PureVM opcode 子集、Gas 表、状态承诺和快照语义。
- [`purevm/README.md`](./purevm/README.md): Go 版链下 VM 和 `vmcli` 手册。
- [`VerCom/README.md`](./VerCom/README.md): Foundry/Solidity 合约、脚本和资金模型手册。

## 项目定位

系统由两条互相配合的路径组成：

- 正常路径：执行方链下完整运行 PureVM 任务，按 Gas 阈值生成 checkpoint 序列；链上只登记任务、checkpoint claim 和数据可用性元数据；如果验证者认可结果，任务按 optimistic 流程结算。
- 争议路径：验证者链下独立重放，定位最早分歧 checkpoint segment；链上只验证这个相邻 segment，或在 segment 仍然过大时进入二次细分争议游戏，最终验证最小争议段。

设计目标不是把链下计算“搬到链上重算一遍”，而是把链下执行变成一组可验证的承诺，让链上在争议发生时只验证足够小、足够明确的一段事实。

## 设计理念

这套系统的设计不是从“写两个模块”开始的，而是从一个约束出发：链下计算便宜但不可直接信任，链上验证可信但昂贵。因此整个方案围绕三个问题组织：

- 如何让链下执行结果变成可审计、可定位、可复现的承诺。
- 如何让链上只验证争议相关的最小片段，而不是重算完整任务。
- 如何把事实裁决和经济激励连接起来，同时避免一个有效证明被挪用到另一个任务上下文。

### 1. 确定性优先

PureVM 的第一原则是确定性。相同 bytecode、初始状态、Gas 配置和链 ID 必须得到相同执行轨迹、相同 checkpoint 序列和相同 state root。只有这样，验证者才能独立重放，链上才能把争议收敛到“谁的某个状态转移是错的”。

因此 PureVM 不是追求完整 EVM 兼容性的节点实现，而是一个可审计、可快照、可重放的确定性计算内核。它用明确的 opcode 子集、明确的 Gas 表、canonical state hash 和 code hash 绑定来降低语义歧义。

### 2. Checkpoint 是链下和链上的共同语言

链下执行会产生完整状态，但链上不应该保存完整执行轨迹。系统选择 checkpoint 作为边界对象：它包含 ordinal、step、Gas 进度、state root、snapshot hash 和 URI。

checkpoint 的作用有三层：

- 进度承诺：说明任务执行到了哪一步、消耗了多少 Gas。
- 状态承诺：用 state root 和 snapshot hash 绑定实际 VM 状态。
- 争议边界：相邻 checkpoint 天然定义一个可局部验证的 segment。

这样链上不需要理解完整任务，只需要理解“从 checkpoint A 到 checkpoint B 的转移是否有效”。

### 3. 乐观执行，争议时局部验证

系统默认相信执行方提交的结果，但给验证者保留挑战窗口。验证者不需要在链上证明整条执行轨迹，只需要提供共同起点 snapshot、真实 next checkpoint 和 transition proof。

这是一种 optimistic verification 设计：大多数任务走低成本路径，只有出现争议时才付出验证成本。更重要的是，验证成本与争议 segment 大小相关，而不是与完整任务大小线性绑定。

### 4. 用 hash 绑定身份、进度、数据和经济结果

本项目最关键的安全思想是“不要让一个有效对象被挪用到另一个上下文”。因此协议里反复使用绑定 hash：

- PureVM task id 绑定 owner、nonce、code hash、total gas、threshold 和 initial root。
- optimistic task 的 `summaryHash` 绑定 `(pureVMTaskId, checkpointOrdinal)`。
- executor 的 `resultHash` 使用 `checkpointClaimHash(...)` 绑定 checkpoint 的 step、Gas、state root、snapshot hash 和 URI。
- snapshot/proof/subdivision 的数据可用性记录绑定 task、kind、ordinal、data hash 和 semantic hash。

这些绑定让系统可以接受“链下数据、链上承诺”的架构，同时避免跨任务、跨 ordinal、跨 payload 的重放或替换。

### 5. 事实裁决和经济结算分层

`PureVMTaskManager` 负责回答事实问题：某个 PureVM checkpoint segment 的真实转移结果是什么，某个最小争议段谁对谁错。`OptimisticTaskCoordinator` 负责回答经济问题：challenge 成功后 reward、executor bond、challenge bond 如何流转。

这个分层让 PureVM 验证逻辑可以被多个经济模型复用，也避免在 verifier 路径里混入过多奖励分配规则。普通 optimistic challenge 记录 `DisputeMeta`，但不自动推进 verified checkpoint 序列；推进链上 verified checkpoint 应走 `verifyAndAppendCheckpoint(...)`。

### 6. 可细分争议而不是一次性大证明

当相邻 checkpoint segment 仍然太大时，系统提供二次细分争议游戏。双方提交相同 step/Gas schedule 的 subdivision commitments，链上检查共同前缀和第一个分歧点，把争议区间逐轮缩小，直到达到 adjudication threshold 或最大轮次。

这套设计把“巨大计算争议”拆成“共同起点 + 最小分歧段 + 局部 proof”。它也是后续替换更紧凑证明系统或专用 precompile 的接口基础。

### 7. 数据可用性和语义正确性分开处理

链上登记 snapshot、proof 和 subdivision 的 hash、URI、size、publisher 与 available 状态，但不假装 URI 本身等于真实数据。数据可用性记录回答“这份数据在哪里、承诺是什么、谁发布、是否可访问”；verifier 回答“这份数据对应的状态转移是否真实”。这两个问题分开以后，系统既能用本地文件、对象存储、IPFS、blob/DA 层等不同数据载体，也能保持同一套链上验证语义。

## 设计方案总览

系统分成三层：

```text
计算层 purevm
  负责确定性执行、Gas 尺度 checkpoint、snapshot index、transition proof 和分歧定位

裁决层 VerCom / PureVMTaskManager
  负责 PureVM task、checkpoint metadata、DA metadata、相邻验证、普通争议和二次细分争议

经济层 OptimisticTaskCoordinator / ValidatorManager
  负责用户任务、执行方 bond、验证者 stake、背书、挑战和收益/罚没
```

三层之间的接口是有意收窄的：

- purevm 输出 snapshot bytes、proof bytes、checkpoint metadata 和 trace root。
- verifier adapter 只返回 `valid`、`finalStateRoot`、`verifiedSteps`、`traceRoot`。
- challenge resolver 只把 optimistic task 的 summary/result claim 映射到 PureVM checkpoint claim。
- coordinator 只根据 resolver 返回的 challenge 成败做经济结算。

这种分层的好处是：计算语义、链上裁决和经济激励可以分别演进，只要共同的不变量和 hash 绑定不被破坏。

从设计方案上看，系统实际采用的是“分层承诺 + 局部验证 + 乐观结算”：

1. 分层承诺：task id 绑定任务身份，checkpoint 绑定执行进度，snapshot hash 绑定完整状态，proof trace root 绑定局部执行轨迹，DA id 绑定数据发布事实。
2. 局部验证：链上验证的默认单位不是完整任务，而是 `fromOrdinal -> fromOrdinal + 1` 的相邻 checkpoint segment；复杂场景再通过 subdivision 缩小到最小争议段。
3. 乐观结算：coordinator 先按 optimistic task 管理 reward/bond/stake，只有 challenge 成功或失败后才触发经济分配。

这也是为什么项目里同时存在 `verifyAndAppendCheckpoint(...)` 和 `resolveDispute(...)` 两条路径：前者推进 PureVM task 的链上 verified checkpoint 序列，后者只为 optimistic challenge 记录一条裁决事实。它们验证的是同一类状态转移，但服务的是不同协议目的。

## 端到端方案

一次 PureVM optimistic task 的完整流程如下：

```text
链下确定性执行
-> 生成 checkpoint 序列、snapshot_index 和 transition proof
-> 链上登记 PureVM task 与初始 checkpoint
-> 用户发布绑定某个 checkpoint ordinal 的 optimistic task
-> 执行方提交 checkpoint claim
-> 验证者背书或发起 challenge
-> resolver 校验 optimistic task 与 PureVM checkpoint 的绑定
-> PureVMTaskManager 调 verifier 验证局部区间
-> 合约记录裁决事实
-> coordinator 或 dispute game 执行经济结算
```

正常情况下，执行方和验证者得到同一条 checkpoint 序列，验证者背书后任务结算。出现分歧时，验证者先用本地 `snapshot_index.json` 和执行方承诺 index 找到最早分歧 segment，再用该 segment 的起点 snapshot 和 transition proof 发起 challenge。

当前仓库由两部分组成：

- `purevm/`: Go 实现的确定性链下计算虚拟机，负责执行、Gas 尺度快照、快照索引、状态转移证明、分歧定位和 Go 版 verifier/precompile 原型。
- `VerCom/`: Foundry/Solidity 合约工程，负责任务发布、验证者质押、checkpoint claim 绑定、乐观挑战、数据可用性登记、二次细分争议、累计质押和裁决结算。

仓库结构：

```text
offchain_com/
  purevm/   # 链下执行、快照、proof、预编译验证原型
  VerCom/   # 链上任务管理、质押、挑战、结算合约
```

## 1. 当前完成状态

当前工作区不是只完成了文档草稿，代码侧也已经有一组配套改动。主要已完成能力如下。

### 1.1 purevm 已完成

- 256 位栈式 PureVM 执行模型。
- 带 Gas 权重的 EVM 风格 opcode 子集。
- 按 `snapshotThresholdGas` 的 checkpoint 切分规则。
- 标准快照 `StandardSnapshot` 与快照完整性校验。
- 快照 JSON bytes 字段采用 `0x` hex，同时兼容旧 base64 产物读取。
- 快照索引 `snapshot_index.json` 与相邻 checkpoint 阈值验证。
- transition proof 生成和重放验证。
- Go 版 verifier/precompile 输入输出协议。
- 执行方与验证者两条 checkpoint 序列的第一分歧段定位。
- `vmcli` 支持运行、快照、证明、验证、precompile 模拟和分歧定位。

### 1.2 VerCom 已完成

- `PureVMTaskManager` 管理 PureVM task、checkpoint、DA 元数据、相邻验证、普通争议记录、二次细分争议游戏和争议质押结算。
- `PureVMVerifierAdapter` 将 Solidity 调用打包为 Go precompile 输入协议，并解析 128/160 字节返回值。
- `PureVMChallengeResolver` 把 optimistic challenge 绑定到指定 PureVM checkpoint ordinal。
- `PureVMSnapshotStore` 提供实验性链上 snapshot bytes 临时存储。
- `OptimisticTaskCoordinator` 实现用户发布任务、执行方认领、结果提交、验证者选择、背书、挑战和资金结算。
- `ValidatorManager` 提供验证者 stake、退出延迟和按 stake 权重选择验证者。
- Foundry 脚本覆盖部署、创建任务、上传/删除快照、从 store 验证 checkpoint、文件驱动 challenge e2e。

### 1.3 仍需特别注意

- 当前 PureVM 是确定性计算原型，不是完整 EVM 节点。
- Go precompile 是本仓库内的 verifier 原型，真实部署时需要把 `PUREVM_VERIFIER_TARGET` 指向实际 verifier/precompile 环境。
- 普通 optimistic challenge 的 `resolveDispute(...)` 记录裁决摘要，但不会把 actual checkpoint 自动追加进任务的 verified checkpoint 序列。推进 verified checkpoint 序列应走 `verifyAndAppendCheckpoint(...)` 或 `verifyAndAppendCheckpointFromStore(...)`。
- 二次细分争议游戏结算的是争议双方在该 game 内的累计质押池；普通 optimistic task 的 reward/bond 结算仍由 `OptimisticTaskCoordinator` 负责。

## 2. 设计目标

系统目标是让链下计算保持高吞吐，同时让链上只在争议时验证足够小的局部执行区间。

核心思路：

1. 链下执行方完整运行 PureVM 任务，并按 Gas 阈值生成 checkpoint。
2. 链上只记录 checkpoint 元数据、hash、URI 和状态转移裁决结果。
3. 验证者独立重放任务，定位与执行方承诺不一致的最早 checkpoint segment。
4. challenge 只验证该相邻 segment 或进一步细分后的最小争议段，不重算完整任务。
5. optimistic task 的 `summaryHash` 与 `resultHash` 必须绑定 PureVM task 和 checkpoint ordinal，避免把一个有效中间结果挪用到另一个任务或另一个 ordinal。

系统需要满足的工程约束：

- 执行确定性：同一 bytecode、初始状态和 Gas 配置得到唯一 checkpoint 序列。
- 可局部验证：任意相邻 checkpoint 可以用 start snapshot + proof 独立验证。
- 可定位争议：执行方与验证者 checkpoint 序列不同，应能定位共同前缀后的第一段分歧。
- 数据可审计：snapshot、proof、subdivision commitment 的 hash、URI、语义 hash 在链上登记。
- 经济闭环：普通任务和争议游戏都有明确 stake、reward、slash 或 refund 规则。

## 3. 系统模型

PureVM task 被建模为确定性状态转移：

```text
task = (
  bytecode,
  initial VMState,
  totalGas,
  snapshotThresholdGas,
  pureVMChainId
)
```

执行过程中产生 checkpoint：

```text
checkpoint = (
  ordinal,
  stepNumber,
  gasUsed,
  gasRemaining,
  stateRoot,
  snapshotBlobHash,
  snapshotURI
)
```

链上验证的基本单位是相邻 checkpoint segment：

```text
segment = checkpoint[fromOrdinal] -> checkpoint[fromOrdinal + 1]
```

验证输入是：

```text
startSnapshotBytes = snapshot(checkpoint[fromOrdinal])
proofBytes         = TransitionProof(startState -> nextState)
nextCheckpoint     = claimed or actual checkpoint[fromOrdinal + 1]
```

验证输出是：

```text
valid
finalStateRoot
verifiedSteps
traceRoot
```

其中：

- `finalStateRoot` 必须等于 `nextCheckpoint.stateRoot`。
- `verifiedSteps` 必须等于 `nextCheckpoint.stepNumber - start.stepNumber`。
- `traceRoot` 作为 proof trace 的摘要写入链上元数据，便于后续审计。

## 4. 协议不变量

这套系统最关键的是 hash 绑定和进度绑定。后续改代码时应优先保护这些不变量。

### 4.1 任务绑定

PureVM task id 由以下字段计算：

```solidity
computeTaskId(
    owner,
    nonce,
    codeHash,
    totalGas,
    snapshotThresholdGas,
    initialStateRoot
)
```

这意味着不同代码、不同初始状态、不同 Gas 配置会得到不同 task id。

### 4.2 Checkpoint 进度绑定

每个 checkpoint 必须满足：

- `next.stepNumber > start.stepNumber`
- `next.gasUsed > start.gasUsed`
- `next.gasUsed + next.gasRemaining == totalGas`
- `nextOrdinal == start.ordinal + 1`
- 非 final segment 的 `next.gasUsed - start.gasUsed <= snapshotThresholdGas`
- final checkpoint 允许 `gasUsed == totalGas`

链下切片规则和链上阈值检查必须保持一致。链上无法仅凭 metadata 证明“这是第一个超过阈值前的状态”，所以真正语义校验依赖 verifier 从 start snapshot 重放 proof，并返回实际 final root 和 steps。

### 4.3 Checkpoint Claim 绑定

PureVM 类 optimistic task 不应使用普通字符串或任意结果 hash。它必须使用：

```solidity
summaryHash = checkpointTaskSummaryHash(pureVMTaskId, checkpointOrdinal)
resultHash  = checkpointClaimHash(pureVMTaskId, checkpointOrdinal, checkpoint)
```

其中：

```solidity
checkpointTaskSummaryHash(taskId, checkpointOrdinal)
  = keccak256(abi.encode("PUREVM_CHECKPOINT_TASK", taskId, checkpointOrdinal))
```

```solidity
checkpointClaimHash(taskId, ordinal, checkpoint)
  = keccak256(abi.encode(
      "PUREVM_CHECKPOINT_CLAIM",
      taskId,
      ordinal,
      checkpoint.stepNumber,
      checkpoint.gasUsed,
      checkpoint.gasRemaining,
      checkpoint.stateRoot,
      checkpoint.snapshotBlobHash,
      checkpoint.snapshotURI
    ))
```

`PureVMChallengeResolver` 会检查 optimistic task 的 `summaryHash` 是否等于 `checkpointTaskSummaryHash(payload.pureVMTaskId, payload.fromOrdinal + 1)`。因此验证者只能挑战同一个 PureVM task、同一个 checkpoint ordinal 的 claim。

### 4.4 Snapshot 绑定

链上 checkpoint 记录 `snapshotBlobHash = keccak256(snapshotBytes)`。

验证相邻 checkpoint 时：

- `keccak256(startSnapshotBytes)` 必须等于已验证起点 checkpoint 的 `snapshotBlobHash`。
- start snapshot 内部必须通过 Go verifier 的完整性校验。
- proof 的 `InitialHash` 必须等于 start snapshot state root。
- proof 的 `CodeHash` 必须等于 start state 的 code hash。

### 4.5 数据可用性绑定

所有 DA 记录使用：

```solidity
dataAvailabilityId(taskId, kind, ordinal, dataHash, semanticHash)
```

其中：

- Snapshot 的 `semanticHash` 通常是 state root。
- Proof 的 `semanticHash` 通常是 trace root。
- Subdivision 的 `semanticHash` 绑定 game、提交方和 round。

同一个 data id 重复登记时，如果已有 size 和新 size 都非零且冲突，则拒绝；否则合并 `available = old || new`，避免重复登记阻断验证流程。

## 5. 链下执行设计

### 5.1 VMState

`core.VMState` 是 PureVM 的完整可序列化状态：

```go
type VMState struct {
    PC        uint64
    Stack     []Word
    Memory    []byte
    Gas       uint64
    Refund    uint64
    Code      []byte
    CodeHash  common.Hash
    StepCount uint64
    CallValue *big.Int
    CallData  []byte
}
```

状态 hash 使用 `SerializeCanonical()` 后的 keccak256。canonical state 当前包含：

- `pc`
- `stack`
- `memory`
- `gas`
- `refund`
- `code_hash`
- `step_count`

注意：`Code` 本体不直接进入 state root，而通过 `CodeHash` 进入；snapshot 完整性会额外检查 `keccak256(Code) == CodeHash`，防止只有 code hash 没有可执行 bytecode 的伪造状态。

### 5.2 标准快照

标准快照格式是：

```go
type StandardSnapshot struct {
    Header SnapshotHeaderV1  `json:"header"`
    State  VMState           `json:"state"`
    Meta   map[string]string `json:"meta,omitempty"`
}
```

header 包含：

```go
type SnapshotHeaderV1 struct {
    Version      uint16
    ChainID      uint64
    BlockHeight  uint64
    Timestamp    uint64
    StateRoot    common.Hash
    CodeHash     common.Hash
    StepNumber   uint64
    GasRemaining uint64
}
```

快照完整性检查：

1. `header.code_hash == state.code_hash`
2. `keccak256(state.code) == state.code_hash`
3. `state.Hash() == header.state_root`

新快照 JSON 中 `state.code`、`state.memory`、`state.call_data` 使用 `0x` hex 字符串，便于 Foundry 脚本用 `vm.parseJsonBytes` 读取。读取逻辑兼容旧版 Go 默认 base64 `[]byte` JSON。

### 5.3 Gas 切片规则

链下快照切分按“执行下一步之前预估 Gas”进行：

1. 维护当前窗口已使用 Gas `windowGasUsed`。
2. 每一步执行前调用 `PeekNextGasCost()`。
3. 如果窗口已有执行量，且 `windowGasUsed + nextGas > snapshotThresholdGas`，先保存当前状态为 checkpoint。
4. 保存 checkpoint 后将 `windowGasUsed` 清零。
5. 执行下一条指令，并把实际 Gas cost 累加到窗口。
6. VM 停机或任务达到目标 Gas 后保存 final checkpoint。

验证时不信任 checkpoint metadata 自身，而是从 start snapshot 恢复 VM，按同一执行语义重放 proof，再比较得到的 state root。

### 5.4 TransitionProof

`proof.TransitionProof` 描述从起点状态到终点状态的一段执行：

```go
type TransitionProof struct {
    InitialHash common.Hash
    FinalHash   common.Hash
    CodeHash    common.Hash
    StartStep   uint64
    EndStep     uint64
    Steps       []StepProof
    GasUsed     uint64
    TraceRoot   common.Hash
}
```

`StepProof` 记录每一步的可重放信息：

- step index
- PC
- opcode
- gas before/cost/after
- stack before/after size
- stack popped/pushed diff
- memory read/write diff
- pre-state hash
- post-state hash

`TransitionProof.Verify(initialState)` 会检查：

- initial state hash 匹配 proof 的 `InitialHash`
- initial state code hash 与 proof 的 `CodeHash` 一致
- state 内 bytecode 与 code hash 一致
- start/end step 区间合法
- trace root 匹配 steps
- 每一步 opcode、PC、Gas、栈变化、内存读写和前后状态 hash
- 总 Gas 与最终 state hash

### 5.5 分歧定位

第一层争议定位基于两条 checkpoint index：

```text
claimed index  = 执行方提交或发布的 checkpoint 序列
verified index = 验证者本地独立重放得到的 checkpoint 序列
```

入口：

```go
proof.FindFirstDivergentSegment(claimedIndex, verifiedIndex)
```

CLI：

```bash
go run ./cmd/vmcli \
  -cmd locate-dispute \
  -claimed-index executor_snapshot_index.json \
  -verified-index validator_snapshot_index.json
```

返回字段：

- `found`
- `from_ordinal`
- `to_ordinal`
- `shared_start_root`
- `claimed_next_root`
- `verified_next_root`
- `claimed_next_missing`
- `verified_next_missing`
- `reason`

challenge payload 的 `fromOrdinal` 应使用这里定位到的最早分歧段。若 initial root 不一致，说明双方不是同一个任务起点，应直接拒绝作为同一 PureVM task 的争议。

## 6. Verifier / Precompile 协议

Solidity adapter 与 Go precompile 使用统一输入格式：

```text
[stateLen:4][proofLen:4][stateOrSnapshotBytes][proofBytes]
```

编码规则：

- `stateLen` 是 big-endian `uint32`。
- `proofLen` 是 big-endian `uint32`。
- `stateOrSnapshotBytes` 推荐使用完整 `StandardSnapshot` JSON。
- 兼容裸 `VMState` JSON，但生产流程应优先使用完整快照。
- `proofBytes` 是 `TransitionProof` JSON。

Go precompile 当前返回 128 字节：

```text
[valid:32][finalStateRoot:32][verifiedSteps:32][traceRoot:32]
```

Solidity adapter 也兼容 160 字节 detailed 响应：

```text
[valid:32][initialStateRoot:32][finalStateRoot:32][verifiedSteps:32][traceRoot:32]
```

旧 32 字节 bool-only 响应会被拒绝。这样做是为了避免 adapter 只能知道“验证通过”，却无法检查 final root、steps 和 trace root 是否与当前 challenge 上下文一致。

统一输入上限：

- snapshot: `262_144` bytes
- proof: `1_048_576` bytes

这些上限同时存在于：

- Go precompile
- `PureVMVerifierAdapter`
- `PureVMTaskManager`
- `PureVMChallengeResolver`
- `PureVMSnapshotStore`

## 7. 链上合约设计

### 7.1 PureVMTaskManager

`PureVMTaskManager` 是 PureVM 链上状态的核心合约。

主要职责：

- 创建 PureVM task。
- 注册初始 checkpoint。
- 验证并追加相邻 checkpoint。
- 从 `PureVMSnapshotStore` 读取 snapshot 后验证 checkpoint。
- 预览 checkpoint 验证结果。
- 管理 snapshot/proof/subdivision 的 DA 元数据。
- 计算 checkpoint-bound summary hash 和 claim hash。
- 记录普通 optimistic challenge 的 `DisputeMeta`。
- 授权 challenge resolver。
- 创建并驱动二次细分争议游戏。
- 管理每轮累计质押。
- 调 verifier 裁决最小争议段。
- 结算争议游戏质押池。
- 在 `gasUsed == totalGas` 时标记 PureVM task finalized。

关键入口：

```solidity
createTask(...)
verifyAndAppendCheckpoint(...)
previewCheckpointVerification(...)
verifyAndAppendCheckpointFromStore(...)
resolveDispute(...)
registerDataAvailability(...)
setDataAvailabilityStatus(...)
setChallengeResolverAuthorization(...)
createDisputeGame(...)
depositDisputeStake(...)
submitSubdivision(...)
declareDivergence(...)
resolveDisputeGameWithProof(...)
resolveDisputeTimeout(...)
```

需要区分两条路径：

- `verifyAndAppendCheckpoint(...)`: 验证通过后把 next checkpoint 写入 verified checkpoint 序列，并推进 `latestVerifiedOrdinal`。
- `resolveDispute(...)`: 为 optimistic challenge 计算 actual result，写入 `DisputeMeta`，但不推进 verified checkpoint 序列。

### 7.2 PureVMVerifierAdapter

`PureVMVerifierAdapter` 实现 `IPureVMVerifier`，负责把 Solidity 参数转换为 verifier target 可理解的 precompile 输入。

它会：

- 拒绝超过上限的 snapshot/proof。
- 用 `abi.encodePacked(uint32(snapshotLen), uint32(proofLen), snapshot, proof)` 构造输入。
- 对 `verifierTarget` 执行 `staticcall`。
- 只接受 128 字节或 160 字节响应。
- 解析 `valid`、`finalStateRoot`、`verifiedSteps`、`traceRoot`。
- 当 expected final root 非零时检查 final root。
- 检查 verified steps 必须等于 expected steps。
- 当 expected trace root 非零时检查 trace root。
- 在 detailed 响应中透出 `initialStateRoot`，供最小争议段裁决校验共同起点。

### 7.3 PureVMChallengeResolver

`PureVMChallengeResolver` 实现 `IOptimisticChallengeResolver`，用于连接普通 optimistic task 与 PureVM 局部验证。

challenge payload：

```solidity
struct ChallengePayload {
    bytes32 pureVMTaskId;
    uint32 fromOrdinal;
    PureVMTypes.CheckpointInput nextCheckpoint;
    bytes startSnapshotBytes;
    bytes proofBytes;
}
```

处理流程：

1. 在 ABI decode 前检查 `challengeData.length <= MAX_CHALLENGE_DATA_BYTES`。
2. Decode payload。
3. 检查 `startSnapshotBytes` 和 `proofBytes` 子字段上限。
4. 计算 `toOrdinal = fromOrdinal + 1`。
5. 检查 optimistic task 的 `summaryHash` 等于 `checkpointTaskSummaryHash(pureVMTaskId, toOrdinal)`。
6. 计算唯一 `disputeId`。
7. 调 `PureVMTaskManager.resolveDispute(...)`。
8. 返回 `success`、`actualResultHash`、`actualStateRoot` 给 coordinator。

### 7.4 OptimisticTaskCoordinator

`OptimisticTaskCoordinator` 管理普通乐观任务生命周期：

1. requester 调 `postTask(...)` 发布任务并转入 reward pool。
2. executor 调 `claimTask(...)` 并缴纳 executor bond。
3. executor 调 `submitResult(...)` 提交 result hash 和 claimed state root。
4. 合约通过 `ValidatorManager.selectValidators(...)` 选择验证者。
5. 被选中的验证者可以 `attestResult(...)` 背书。
6. 被选中的验证者也可以在 challenge window 内带 challenge bond 调 `challengeResult(...)`。
7. challenge 成功则罚没 executor bond，并退还 requester reward pool。
8. challenge 失败则 challenge bond 给 executor。
9. challenge window 关闭后，无成功 challenge 时 `finalizeTask(...)` 分配 executor、validator 和 requester 资金。

PureVM 任务的特殊点是：

- `summaryHash` 应使用 `checkpointTaskSummaryHash(...)`。
- `resultHash` 应使用 `checkpointClaimHash(...)`。
- `claimedStateRoot` 应等于 checkpoint 的 `stateRoot`。
- `challengeData` 应编码 `PureVMChallengeResolver.ChallengePayload`。

### 7.5 PureVMSnapshotStore

`PureVMSnapshotStore` 是实验性链上 bytes store，方便本地或测试网脚本把 snapshot bytes 临时放到链上。

入口：

```solidity
uploadSnapshot(taskId, ordinal, snapshotBytes)
getSnapshot(taskId, ordinal)
getSnapshotHash(taskId, ordinal)
deleteSnapshot(taskId, ordinal)
```

上传上限为 `262_144` bytes。生产环境不建议把大 snapshot 常驻链上，应使用 IPFS、对象存储、DA 层或 blob/rollup DA，再在链上登记 hash 和 URI。

### 7.6 ValidatorManager

`ValidatorManager` 提供：

- 验证者 stake。
- 退出延迟。
- stake 加权随机选择验证者。

`OptimisticTaskCoordinator` 在结果提交后调用它选择验证者。只有被选中的验证者可以背书或挑战该 task。

## 8. 数据可用性设计

`DataAvailabilityMeta` 结构：

```solidity
struct DataAvailabilityMeta {
    bytes32 taskId;
    DataKind kind;
    uint32 ordinal;
    bytes32 dataHash;
    bytes32 semanticHash;
    uint64 size;
    string uri;
    address publisher;
    uint64 registeredAtBlock;
    bool available;
}
```

`DataKind`：

- `Snapshot`
- `Proof`
- `Subdivision`

自动登记路径：

- 创建 PureVM task 时登记初始 snapshot。
- 追加 checkpoint 时登记 next snapshot 和 proof。
- 普通 challenge 裁决时登记 actual snapshot 和 proof。
- 提交 subdivision 时登记 subdivision root。
- 最小争议段裁决时登记 MDU proof。

显式入口：

```solidity
registerDataAvailability(...)
setDataAvailabilityStatus(...)
getDataAvailability(...)
getTaskDataAvailabilityIds(...)
```

权限规则：

- 任意调用者可以为已存在 task 登记 DA 元数据。
- `publisher` 或 task owner 可以更新该记录的 available 状态。

URI 上限为 `2_048` bytes。链上只保存 URI 字符串和 hash，不保证 URI 内容真实可访问；可访问性由 `available` 标记和链下审计共同维护。

## 9. 二次细分争议游戏

普通 challenge 可以直接验证相邻 checkpoint segment。当 segment 仍然过大或需要更细粒度交互时，可以进入 `DisputeGame`。

### 9.1 创建游戏

`createDisputeGame(...)` 绑定：

- `taskId`
- `fromOrdinal`
- `toOrdinal`
- executor
- challenger
- executor claimed result hash
- executor claimed state root
- executor claimed snapshot blob hash
- challenger replayed state root
- challenger replayed snapshot blob hash
- claimed step/gas endpoint
- `adjudicationThresholdGas`
- `maxRounds`
- `roundDuration`
- `baseStake`

约束：

- `toOrdinal == fromOrdinal + 1`
- 起点 checkpoint 必须存在且 verified
- 双方地址非零且不同
- claimed/challenger root 和 blob hash 非零
- `adjudicationThresholdGas > 0`
- `adjudicationThresholdGas <= snapshotThresholdGas`
- `maxRounds <= 16`
- `roundDuration <= 30 days`
- `baseStake << (maxRounds - 1)` 不溢出

游戏创建后进入 `Staking` 状态。

### 9.2 累计质押

每轮所需累计质押为：

```text
requiredStake(round) = baseStake * 2^round
```

实现上是：

```solidity
baseStake << currentRound
```

双方都达到当前轮 required stake 后，游戏进入 `Open` 状态并可提交 subdivision。

注意这里是累计质押，不是每轮新增同等金额。例如：

```text
round 0 required = 1x baseStake
round 1 required = 2x baseStake
round 2 required = 4x baseStake
```

若某方前一轮已经存入 1x，到 round 1 只需补足到 2x。

### 9.3 Subdivision 提交

双方提交同一 schedule 的 commitment 数组：

```solidity
struct SubdivisionCommitment {
    uint32 index;
    uint64 stepNumber;
    uint64 gasUsed;
    bytes32 stateRoot;
    bytes32 snapshotBlobHash;
}
```

链上检查：

- 数量在 `[2, 128]`。
- 第一个 commitment 必须等于当前共同起点。
- index 从 0 开始连续递增。
- stepNumber 严格递增。
- gasUsed 严格递增。
- 每个点不超过当前 target step/gas。
- 最后一个 commitment 必须等于该方当前 endpoint。
- 双方 schedule 的 index、stepNumber、gasUsed 完全一致。

`subdivisionRootHash(commitments)` 会写入游戏状态和 DA 记录。

### 9.4 声明分歧

任一争议方可调用 `declareDivergence(gameId, divergenceIndex)`。

链上检查：

- 双方都已提交 subdivision。
- `divergenceIndex != 0`
- `divergenceIndex < commitments.length`
- 在 `divergenceIndex` 之前，双方 state root 和 snapshot blob hash 都相同。
- 在 `divergenceIndex` 处，双方 state root 不同。

然后游戏更新：

```text
commonRoot              = exec[divergenceIndex - 1].stateRoot
executorRoot            = exec[divergenceIndex].stateRoot
challengerRoot          = chal[divergenceIndex].stateRoot
commonSnapshotBlobHash  = exec[divergenceIndex - 1].snapshotBlobHash
executorSnapshotBlobHash= exec[divergenceIndex].snapshotBlobHash
challengerSnapshotBlobHash = chal[divergenceIndex].snapshotBlobHash
commonStep              = previous.stepNumber
targetStep              = divergent.stepNumber
commonGasUsed           = previous.gasUsed
targetGasUsed           = divergent.gasUsed
```

如果：

```text
targetGasUsed - commonGasUsed <= adjudicationThresholdGas
```

或已经达到最大轮次，则状态变为 `ReadyForFinal`。否则进入下一轮 `Staking`，双方继续补足更高累计质押并细分。

### 9.5 最小争议段裁决

`resolveDisputeGameWithProof(...)` 在 `ReadyForFinal` 状态调用。

输入：

- `actualCheckpoint`
- `startSnapshotBytes`
- `proofBytes`

校验：

- `keccak256(startSnapshotBytes) == commonSnapshotBlobHash`
- `actualCheckpoint.stepNumber == targetStep`
- `actualCheckpoint.gasUsed == targetGasUsed`
- `actualCheckpoint.gasUsed + actualCheckpoint.gasRemaining == totalGas`
- verifier detailed response 的 `initialStateRoot` 如果非零，必须等于 `commonRoot`
- verifier final root 必须等于 `actualCheckpoint.stateRoot`
- verified steps 必须等于 `targetStep - commonStep`

胜负规则：

- actual root 等于 executor root 且不等于 challenger root：executor 胜。
- actual root 等于 challenger root 且不等于 executor root：challenger 胜。
- 其他情况：双方都错，质押池平分退回。

胜者获得双方在该 dispute game 中的全部累计质押。双方都错时，按整数除法拆分退回。

### 9.6 超时裁决

`resolveDisputeTimeout(...)` 只适用于 `Staking` 状态，且当前 round deadline 已过。

规则：

- 只有 executor 补足当前轮质押：executor 胜。
- 只有 challenger 补足当前轮质押：challenger 胜。
- 双方都补足或双方都未补足但仍停在 staking：双方都错。

## 10. 端到端流程

### 10.1 正常无争议路径

1. 链下生成初始 snapshot、checkpoint 序列和 `snapshot_index.json`。
2. requester 调 `PureVMTaskManager.createTask(...)` 创建 PureVM task。
3. requester 调 `OptimisticTaskCoordinator.postTask(...)`，其中 `summaryHash = checkpointTaskSummaryHash(pureVMTaskId, targetOrdinal)`。
4. executor 调 `claimTask(...)` 并缴纳 bond。
5. executor 提交 `resultHash = checkpointClaimHash(pureVMTaskId, targetOrdinal, checkpoint)` 和 `claimedStateRoot = checkpoint.stateRoot`。
6. coordinator 选择验证者。
7. 验证者链下获取 snapshot/proof/index 并独立检查。
8. 验证者背书。
9. challenge window 结束后，`finalizeTask(...)` 分配 reward/bond。

### 10.2 普通挑战路径

1. 验证者本地重放任务，得到 verified checkpoint index。
2. 用 `locate-dispute` 找到最早分歧段 `fromOrdinal -> fromOrdinal + 1`。
3. 验证者准备真实的 `nextCheckpoint`、`startSnapshotBytes`、`proofBytes`。
4. 构造 `PureVMChallengeResolver.ChallengePayload`。
5. 调 `OptimisticTaskCoordinator.challengeResult(...)` 并附带 challenge bond。
6. coordinator 检查调用者是被选中的验证者，且 challenge window 未关闭。
7. resolver 检查 optimistic task summary 是否绑定到该 PureVM checkpoint ordinal。
8. manager 调 verifier 验证相邻 segment。
9. manager 写入 `DisputeMeta`。
10. 如果 actual result/hash 与 claimed 不同，challenge 成功，coordinator 罚没 executor bond 并退还 requester reward pool。
11. 如果 actual result/hash 与 claimed 相同，challenge 失败，challenge bond 给 executor。

### 10.3 追加 checkpoint 路径

这是推进 PureVM task verified checkpoint 序列的路径，与普通 challenge 记录事实不同。

1. 调用方准备起点 snapshot、下一个 checkpoint 和 proof。
2. 调 `verifyAndAppendCheckpoint(...)`。
3. manager 检查起点 ordinal 必须等于 `latestVerifiedOrdinal`。
4. 检查起点 snapshot hash。
5. 检查 checkpoint 进度和 Gas 约束。
6. 调 verifier 验证 proof。
7. 写入 next checkpoint、adjacent proof metadata 和 DA 记录。
8. 更新 `latestVerifiedOrdinal`。
9. 如果 `next.gasUsed == totalGas`，标记 PureVM task finalized。

### 10.4 从 SnapshotStore 追加 checkpoint

适用于本地测试或测试网脚本：

1. 先调 `PureVMSnapshotStore.uploadSnapshot(taskId, fromOrdinal, snapshotBytes)`。
2. 调 `verifyAndAppendCheckpointFromStore(...)`。
3. manager 从 store 读取 start snapshot bytes。
4. 验证和追加流程与普通追加路径一致。
5. 可调 `deleteSnapshot(...)` 删除临时 snapshot bytes。

### 10.5 二次细分路径

1. 创建 `DisputeGame`，绑定相邻 checkpoint segment 的双方 endpoint。
2. 双方补足当前轮累计质押。
3. 双方提交相同 schedule 的 subdivision commitments。
4. 任一方声明第一分歧点。
5. 若分歧段仍大于阈值，则进入下一轮并重复。
6. 若分歧段达到 `adjudicationThresholdGas` 或最大轮次，则进入 `ReadyForFinal`。
7. 调 `resolveDisputeGameWithProof(...)`，用共同起点 snapshot 和最小争议段 proof 裁决。
8. 结算双方在 dispute game 中的质押池。

## 11. 接口上限

当前统一上限如下：

| 模块 | 字段 | 上限 |
| --- | --- | --- |
| `PureVMTaskManager` | URI | 2,048 bytes |
| `PureVMTaskManager` | direct snapshot | 262,144 bytes |
| `PureVMTaskManager` | proof | 1,048,576 bytes |
| `PureVMTaskManager` | subdivision commitments | 128 |
| `PureVMTaskManager` | dispute rounds | 16 |
| `PureVMTaskManager` | round duration | 30 days |
| `PureVMChallengeResolver` | challengeData | 1,320,000 bytes |
| `PureVMChallengeResolver` | startSnapshotBytes | 262,144 bytes |
| `PureVMChallengeResolver` | proofBytes | 1,048,576 bytes |
| `OptimisticTaskCoordinator` | summaryURI/resultURI | 2,048 bytes |
| `OptimisticTaskCoordinator` | challengeData | 1,320,000 bytes |
| `PureVMSnapshotStore` | snapshot bytes | 262,144 bytes |
| `PureVMVerifierAdapter` | snapshot/proof | 262,144 / 1,048,576 bytes |
| Go precompile | snapshot/proof | 262,144 / 1,048,576 bytes |

`MAX_CHALLENGE_DATA_BYTES = 1_320_000` 大致覆盖 ABI 编码后的 snapshot、proof 和 checkpoint metadata。后续如果提高 proof 上限，应同步调整 coordinator、resolver、task manager、adapter、Go precompile 和测试。

## 12. 常用命令

### 12.1 purevm 常规测试

```bash
cd purevm
go test ./...
```

如果本机 Go 缓存或模块缓存不希望写到系统目录，可使用：

```bash
cd purevm
GOCACHE="$PWD/.gocache" \
GOMODCACHE="$PWD/.gomodcache" \
GOPATH="$PWD/.gopath" \
GOSUMDB=sum.golang.org \
GOPROXY=https://proxy.golang.org \
go test -v -mod=mod ./...
```

如果网络不通，可按仓库约定使用代理：

```bash
export https_proxy=http://127.0.0.1:33210
export http_proxy=http://127.0.0.1:33210
export all_proxy=socks5://127.0.0.1:33211
```

### 12.2 完整 Gas 长任务测试

```bash
cd purevm
PUREVM_GAS_SCALE_TEST=1 go test -v -mod=mod ./test -run TestFileBackedSnapshotsLongRun -timeout 10m
```

保留测试产物：

```bash
PUREVM_GAS_SCALE_TEST=1 PUREVM_KEEP_FILES=1 \
go test -v -mod=mod ./test -run TestFileBackedSnapshotsLongRun -timeout 10m
```

产物目录：

```text
purevm/test/testdata/long_run_artifacts/<timestamp>/
```

重要文件：

- `task_manifest.json`
- `snapshot_index.json`
- `snapshot_*.json`
- 可选 `proof_*.json`

完整长 Gas 任务适合做链下快照、索引和分歧定位压力测试。当前 transition proof 是逐步 JSON 结构，几百万步相邻段的完整 proof 通常会超过 1MB verifier payload 上限，因此链上 E2E 演示推荐使用下面的 `generate-artifacts` 生成测试友好规模的真实产物。

### 12.3 VM CLI

运行 bytecode：

```bash
cd purevm
go run ./cmd/vmcli -cmd run -code 600160020100 -gas 100000
```

保存快照：

```bash
go run ./cmd/vmcli \
  -cmd snapshot \
  -code 600160020100 \
  -gas 100000 \
  -steps 1 \
  -snap /tmp/snapshot_step1.json
```

检查快照：

```bash
go run ./cmd/vmcli -cmd check-snapshot -snap /tmp/snapshot_step1.json
```

从 bytecode 生成 proof：

```bash
go run ./cmd/vmcli \
  -cmd prove \
  -code 600160020100 \
  -gas 100000 \
  -steps 2 \
  -proof /tmp/proof.json
```

从 snapshot 恢复并生成 proof：

```bash
go run ./cmd/vmcli \
  -cmd prove-snapshot \
  -snap /tmp/snapshot_step1.json \
  -steps 2 \
  -proof /tmp/proof_from_snapshot.json
```

验证 snapshot + proof：

```bash
go run ./cmd/vmcli \
  -cmd verify \
  -snap /tmp/snapshot_step1.json \
  -proof /tmp/proof_from_snapshot.json
```

模拟 precompile 验证：

```bash
go run ./cmd/vmcli \
  -cmd verify-precompile \
  -snap /tmp/snapshot_step1.json \
  -proof /tmp/proof_from_snapshot.json
```

按 snapshot index 验证相邻 checkpoint：

```bash
go run ./cmd/vmcli \
  -cmd verify-index \
  -index path/to/snapshot_index.json \
  -ordinal 3
```

生成 VerCom 文件驱动 E2E 产物：

```bash
go run ./cmd/vmcli \
  -cmd generate-artifacts \
  -out test/testdata/e2e_artifacts/current \
  -gas 100000 \
  -threshold 500 \
  -chainid 1337 \
  -proofs=true
```

该命令会生成 `task_manifest.json`、`snapshot_index.json`、`snapshot_*.json` 和相邻 `proof_*.json`。示例首段 proof 约 65KB，低于 Go precompile、Solidity adapter 和 resolver 的统一 proof 上限。

验证首段 precompile payload：

```bash
go run ./cmd/vmcli \
  -cmd verify-precompile \
  -snap test/testdata/e2e_artifacts/current/snapshot_000_initial.json \
  -proof test/testdata/e2e_artifacts/current/proof_001_from_0_steps_122.json
```

定位第一分歧段：

```bash
go run ./cmd/vmcli \
  -cmd locate-dispute \
  -claimed-index executor_snapshot_index.json \
  -verified-index validator_snapshot_index.json
```

### 12.4 Foundry 测试

```bash
cd VerCom
forge test
```

### 12.5 Foundry 脚本

部署：

```bash
cd VerCom
PUREVM_VERIFIER_TARGET=0xYourVerifierTarget \
forge script script/DeployVerCom.s.sol:DeployVerComScript --rpc-url <RPC_URL> --broadcast
```

创建 PureVM task：

```bash
forge script script/CreatePureVMTask.s.sol:CreatePureVMTaskScript --rpc-url <RPC_URL> --broadcast
```

上传 snapshot：

```bash
forge script script/UploadSnapshotToStore.s.sol:UploadSnapshotToStoreScript --rpc-url <RPC_URL> --broadcast
```

从 store 验证并追加 checkpoint：

```bash
forge script script/VerifyCheckpointFromStore.s.sol:VerifyCheckpointFromStoreScript --rpc-url <RPC_URL> --broadcast
```

删除 snapshot：

```bash
forge script script/DeleteSnapshotFromStore.s.sol:DeleteSnapshotFromStoreScript --rpc-url <RPC_URL> --broadcast
```

真实文件驱动 challenge e2e：

```bash
forge script script/RunPureVMChallengeE2E.s.sol:RunPureVMChallengeE2EScript --rpc-url <RPC_URL> --broadcast
```

`RunPureVMChallengeE2E.s.sol` 会读取：

- `PUREVM_ARTIFACT_DIR/snapshot_index.json`
- `PUREVM_ARTIFACT_DIR/task_manifest.json`
- index 指向的 start/next snapshot
- `PUREVM_PROOF_FILE`，若为空则读取 index 中的 `adjacent_proof_file`

并串起：

- PureVM task 创建
- optimistic task 发布
- validator stake
- executor claim
- executor 提交错误 checkpoint claim
- validator challenge
- resolver 调用 PureVM verifier 路径

本地可用可选测试验证真实文件读取和脚本链路：

```bash
cd VerCom
PUREVM_E2E_SCRIPT_TEST=1 \
PUREVM_ARTIFACT_DIR=../purevm/test/testdata/e2e_artifacts/current \
forge test --match-contract RunPureVMChallengeE2EScriptTest
```

`VerCom/foundry.toml` 已给 `../purevm/test/testdata` 和 `./testdata` 配置只读 `fs_permissions`。

## 13. 测试覆盖

当前 Go 测试覆盖：

- 基础算术执行。
- 快照完整性。
- snapshot JSON hex bytes。
- bytecode 篡改检测。
- Go precompile 接收完整 `StandardSnapshot`。
- Go precompile 输入上限。
- transition proof 生成与验证。
- Gas 一致性。
- 内存扩展。
- 快照序列。
- snapshot index 相邻恢复验证。
- threshold 边界验证。
- 执行方/验证者 checkpoint 序列第一分歧定位。
- 长任务文件快照生成和索引产物。

当前 Foundry 测试覆盖：

- PureVM task 创建和初始 checkpoint 登记。
- checkpoint 验证追加。
- checkpoint threshold 拒绝。
- `gasUsed == totalGas` 时 finalized。
- snapshot store 上传、读取、删除。
- DA 登记和状态更新。
- 统一接口上限拒绝。
- adapter precompile payload 编码。
- adapter 128 字节响应解析。
- adapter 160 字节 detailed 响应兼容。
- adapter 拒绝旧 bool-only 响应。
- adapter root、steps、trace root mismatch。
- coordinator post/claim/submit/attest/finalize。
- 被选中验证者 challenge 成功。
- 未选中验证者 challenge 失败。
- PureVM resolver 联动 challenge。
- resolver proof payload 上限。
- 二次细分争议游戏。
- 累计质押轮次。
- 最小争议段 proof 裁决和质押池结算。
- dispute game timeout。
- executor 胜、challenger 胜和双方都错结算。
- resolver 授权。
- 部署脚本合约连线和 challenge resolver 授权。
- 可选真实 PureVM artifact 文件驱动 E2E 脚本测试。

## 14. 关键文件索引

链下：

- `purevm/core/state.go`: VM state、canonical hash、code hash 校验。
- `purevm/core/vm.go`: VM step/run、Gas 预估、snapshot load/create。
- `purevm/core/snapshot.go`: 标准快照和完整性校验。
- `purevm/core/snapshot_index.go`: snapshot index 和相邻 entry 解析。
- `purevm/proof/transition.go`: transition proof 生成与验证。
- `purevm/proof/snapshot_verify.go`: 从快照恢复并验证下一 checkpoint。
- `purevm/proof/dispute.go`: 第一分歧 segment 定位。
- `purevm/precompile/snapshot_validator.go`: Go precompile 输入输出协议。
- `purevm/cmd/vmcli/main.go`: CLI 入口。

链上：

- `VerCom/src/PureVMTypes.sol`: 共享结构体和枚举。
- `VerCom/src/PureVMTaskManager.sol`: PureVM task、checkpoint、DA 和争议游戏核心。
- `VerCom/src/PureVMVerifierAdapter.sol`: Solidity verifier adapter。
- `VerCom/src/PureVMChallengeResolver.sol`: optimistic challenge 到 PureVM 的 resolver。
- `VerCom/src/OptimisticTaskCoordinator.sol`: 普通乐观任务和资金结算。
- `VerCom/src/ValidatorManager.sol`: 验证者 stake 和选择。
- `VerCom/src/PureVMSnapshotStore.sol`: 临时 snapshot bytes store。
- `VerCom/src/interfaces/IPureVMVerifier.sol`: verifier 接口。
- `VerCom/src/interfaces/IOptimisticChallengeResolver.sol`: challenge resolver 接口。

脚本与测试：

- `VerCom/script/RunPureVMChallengeE2E.s.sol`: 文件驱动 challenge e2e。
- `VerCom/.env.example`: 脚本环境变量模板。
- `VerCom/test/DeployVerComScript.t.sol`: 部署脚本连线测试。
- `VerCom/test/RunPureVMChallengeE2EScript.t.sol`: 可选真实文件驱动脚本测试。
- `VerCom/test/*.t.sol`: Foundry 测试。
- `purevm/test/integration_test.go`: Go 集成测试。
- `purevm/test/file_snapshot_long_test.go`: 长任务文件快照测试。

## 15. 维护建议

1. 不要把 PureVM optimistic task 退回普通 `summaryHash/resultHash` 语义。必须使用 checkpoint-bound hash。
2. 修改 verifier 协议时，同步更新 Go precompile、Solidity adapter、`IPureVMVerifier`、adapter 测试和 `vmcli -cmd verify-precompile`。
3. 修改 snapshot/state root 格式时，同步跑 Go 测试、Foundry 测试和脚本 JSON 解析流程。
4. 修改 proof 字段或 trace root 算法时，同步更新 `TransitionProof.Verify`、precompile、adapter 检查和 dispute metadata。
5. 修改 payload 上限时，同步修改 task manager、resolver、coordinator、snapshot store、adapter、Go precompile 和测试。
6. 修改 dispute game 质押规则时，重点检查 `requiredStakeForRound`、超时裁决、结算路径和溢出保护。
7. 生产部署应使用可审计的数据发布层保存 snapshot/proof/subdivision 文件，链上只保存 hash、URI 和可用状态。
8. `PureVMSnapshotStore` 适合测试和小 payload 演示，不应作为生产大规模 DA 方案。
9. `block.prevrandao` 加 task/result 作为验证者选择随机源适合原型，生产场景应评估可操纵性和替代随机源。
10. 合约当前未引入完整治理/升级/暂停机制；若进入真实资金环境，应补充权限、升级、应急暂停和审计。
