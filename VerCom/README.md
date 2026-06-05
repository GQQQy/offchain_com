# VerCom

`VerCom` 是 `offchain_com` 的链上部分，使用 Foundry 开发。它负责把链下 `purevm` 的 checkpoint 承诺、乐观提交和挑战裁决流程接入到以太坊风格合约里。

## 主要合约

### `PureVMTaskManager`

负责：

- 创建 PureVM task
- 记录 checkpoint
- 登记 snapshot / proof / subdivision 的数据可用性元数据
- 检查 checkpoint 的 Gas 约束
- 调用 verifier 验证相邻快照
- 追加下一个 checkpoint
- 计算 checkpoint-bound task summary / result claim hash
- 记录 PureVM 争议裁决摘要 `DisputeMeta`
- 运行二次细分争议游戏、累计质押和最小争议段裁决
- 标记任务完成

### `PureVMSnapshotStore`

负责：

- 临时把快照 bytes 上传到链上
- 在验证时读取这些快照
- 验证后删除它们
- 拒绝超过链上直接存储上限的快照 payload

### `PureVMVerifierAdapter`

负责把 Solidity 调用转换成 Go 预编译格式。

当前已经按 `purevm/precompile/snapshot_validator.go` 的格式编码：

```text
[stateLen:4][proofLen:4][snapshotOrStateBytes][proofBytes]
```

其中 `snapshotOrStateBytes` 推荐传完整 `StandardSnapshot` JSON。Go verifier target 当前返回固定 128 字节：

```text
[valid:32][finalStateRoot:32][verifiedSteps:32][traceRoot:32]
```

`PureVMVerifierAdapter` 会校验返回的真实 final root、steps 和可选 trace root；同时兼容带 `initialStateRoot` 的 160 字节 detailed 响应。旧的 32 字节 bool-only 响应会被拒绝。
adapter 会拒绝超过上限的 snapshot/proof payload，避免大输入绕过任务管理器的接口限制。

### `PureVMChallengeResolver`

负责在乐观挑战时检查 optimistic task 是否绑定到指定 PureVM checkpoint ordinal，然后把挑战载荷导向 `PureVMTaskManager.resolveDispute(...)`，从而进入真实的 PureVM checkpoint 验证路径并记录裁决摘要。
resolver 会在 ABI decode 前检查 challenge payload 总长度，并在 decode 后检查 snapshot/proof 子字段长度。

### `ValidatorManager`

负责：

- 验证者质押
- 退出延迟
- 按 stake 权重随机选举验证者

### `OptimisticTaskCoordinator`

负责：

- 用户发布任务并转入奖励池
- 执行方认领并质押 bond
- 执行方提交结果
- 被选中的验证者背书
- 验证者携带 challenge bond 发起挑战
- 按任务发布时确定的比例进行分润/罚没

## Checkpoint Claim 约定

PureVM 类 optimistic task 不是提交任意字符串结果，而是提交某个 PureVM checkpoint 的 claim。

- `summaryHash = PureVMTaskManager.checkpointTaskSummaryHash(pureVMTaskId, checkpointOrdinal)`
- `resultHash = PureVMTaskManager.checkpointClaimHash(pureVMTaskId, checkpointOrdinal, checkpoint)`
- `claimedStateRoot = checkpoint.stateRoot`

挑战时，`PureVMChallengeResolver` 会强制检查 optimistic task 的 `summaryHash` 是否绑定到 `payload.fromOrdinal + 1` 对应的 checkpoint。这样验证者不能拿一个有效的中间 checkpoint 去挑战另一个不相关的最终结果。

挑战成功或失败后，`PureVMTaskManager` 会写入 `DisputeMeta`，记录 claimed/actual result hash、claimed/actual state root、trace root、verified steps、challenger 和胜负结果。经济结算仍由 `OptimisticTaskCoordinator` 完成。

## 数据可用性与接口上限

`PureVMTaskManager` 会为初始 checkpoint、追加 checkpoint、challenge proof、二次细分承诺登记 `DataAvailabilityMeta`。每条记录绑定：

- task id
- 数据类型：snapshot、proof 或 subdivision
- ordinal / round
- 数据 hash
- 语义 hash，例如 state root、trace root 或 subdivision root
- URI、发布者、大小和可用状态

外部可以通过 `registerDataAvailability(...)` 显式登记 DA 元数据，也可以用 `setDataAvailabilityStatus(...)` 更新可用状态。任务 owner 和数据发布者都可以维护状态。

主要入口限制：

- URI: 2,048 bytes
- 直接传入 snapshot: 262,144 bytes
- proof: 1,048,576 bytes
- challenge payload: 1,320,000 bytes
- subdivision commitments: 128 条
- dispute rounds: 16

这些限制在 coordinator、resolver、task manager、snapshot store、verifier adapter 和 Go precompile 中保持一致。

## 二次细分与累计质押

复杂争议可以调用 `PureVMTaskManager.createDisputeGame(...)` 进入二次细分状态机。争议游戏记录双方 endpoint：执行方 claimed checkpoint 与挑战者重放 checkpoint。双方按相同 step/gas schedule 提交 subdivision commitment 序列，链上检查共同前缀、分歧点和 endpoint 绑定。

质押按轮次累计，当前规则为：

```text
requiredStake(round) = baseStake * 2^round
```

每轮双方都必须补足累计质押后才能提交细分承诺。链上定位分歧点后，如果段 Gas 已不超过 `adjudicationThresholdGas`，或者达到最大轮次，就进入 `ReadyForFinal`。最终调用 `resolveDisputeGameWithProof(...)`，用共同起点 snapshot 和最小争议段 proof 裁决赢家并结算双方质押池。

## 当前资金模型

### 用户

- 在 `postTask` 时转入 `rewardPool`
- 这笔钱作为执行成功时的奖励来源
- 若挑战成功，则整笔 `rewardPool` 会退还给用户

### 执行方

- 在 `claimTask` 时转入 `executorBond`
- 若执行正确：
  - bond 全额返还
  - 再获得 `rewardPool * executorRewardBps`
- 若被挑战成功：
  - bond 被罚没

### 验证者

- 先在 `ValidatorManager` 中 stake，参与 PoS 式选举
- 被选中的验证者可以：
  - `attestResult`
  - 或在 challenge window 内带 `challengeBond` 发起挑战
- 若挑战成功：
  - 挑战者拿回 challenge bond
  - 再获得执行方 bond 的一部分
- 若没有成功挑战且验证者完成背书：
  - 背书验证者平分验证者奖励份额

### 分润比例

分润比例不是全局固定，而是**在用户发布任务时就确定**。

由 `OptimisticTaskCoordinator.PayoutConfig` 指定：

- `executorRewardBps`
- `validatorRewardBps`
- `challengerSlashRewardBps`
- `requesterSlashBps`
- `challengeBond`

## 测试

在 `VerCom` 目录下：

```powershell
forge test
```

当前已经通过的测试有：

- `PureVMTaskManager.t.sol`
- `PureVMVerifierAdapter.t.sol`
- `OptimisticTaskCoordinator.t.sol`

这些测试覆盖了：

- 任务创建
- checkpoint 追加
- 阈值拒绝
- finalize
- 快照上传/读取/删除
- adapter 真实预编译载荷编码
- adapter 128 字节 verifier 响应解析和 160 字节 detailed 响应兼容
- adapter 拒绝旧 bool-only verifier 响应
- adapter、resolver、coordinator、snapshot store 和 Go precompile 的接口上限
- checkpoint claim hash 绑定
- 数据可用性登记和状态更新
- 二次细分争议游戏
- 累计质押轮次和最小争议段裁决
- challenge resolver 写入 dispute 记录
- 执行方认领
- 验证者背书
- 选中验证者挑战成功
- 未选中验证者挑战失败
- `OptimisticTaskCoordinator -> PureVMChallengeResolver -> PureVMTaskManager` 的挑战联动

## 脚本

### 部署

```powershell
$env:PUREVM_VERIFIER_TARGET="0xYourVerifierTarget"
forge script script/DeployVerCom.s.sol:DeployVerComScript --rpc-url <RPC_URL> --broadcast
```

### 创建 PureVM task

```powershell
forge script script/CreatePureVMTask.s.sol:CreatePureVMTaskScript --rpc-url <RPC_URL> --broadcast
```

### 上传快照到临时链上存储

```powershell
forge script script/UploadSnapshotToStore.s.sol:UploadSnapshotToStoreScript --rpc-url <RPC_URL> --broadcast
```

### 从 store 验证并追加 checkpoint

```powershell
forge script script/VerifyCheckpointFromStore.s.sol:VerifyCheckpointFromStoreScript --rpc-url <RPC_URL> --broadcast
```

### 删除已使用快照

```powershell
forge script script/DeleteSnapshotFromStore.s.sol:DeleteSnapshotFromStoreScript --rpc-url <RPC_URL> --broadcast
```

### 真实文件驱动的挑战流程

```powershell
forge script script/RunPureVMChallengeE2E.s.sol:RunPureVMChallengeE2EScript --rpc-url <RPC_URL> --broadcast
```

这个脚本设计目标是直接读取 `purevm/test/testdata/...` 下的真实：

- `task_manifest.json`
- `snapshot_index.json`
- `snapshot_*.json`
- proof 文件

然后串起：

- PureVM task 创建
- optimistic task 发布
- 执行方认领
- 错误 checkpoint claim 提交
- 验证者挑战
- 进入 PureVM challenge resolver

## `.env.example`

仓库里已经提供了：

- [`.env.example`](./.env.example)

它把这些脚本需要的环境变量都列出来了：

- 合约地址
- 三个参与方私钥
- PureVM task 元数据
- 快照 / proof 文件路径
- optimistic task 的奖励和 bond 配置

## 基于当前真实快照产物的示例

当前可以直接参考这批真实链下产物：

- [snapshot_index.json](../purevm/test/testdata/long_run_artifacts/20260414_165531/snapshot_index.json)
- [task_manifest.json](../purevm/test/testdata/long_run_artifacts/20260414_165531/task_manifest.json)
- [snapshot_000_initial.json](../purevm/test/testdata/long_run_artifacts/20260414_165531/snapshot_000_initial.json)
- [snapshot_001_step_2918921_gas_12000001.json](../purevm/test/testdata/long_run_artifacts/20260414_165531/snapshot_001_step_2918921_gas_12000001.json)
- `proof_001_from_0_steps_2918921.json`

如果本地还没有 proof 文件，可以先在 `purevm` 目录执行：

```powershell
$root=(Get-Location).Path
$env:GOCACHE=Join-Path $root '.gocache'
$env:GOMODCACHE=Join-Path $root '.gomodcache'
$env:GOPATH=Join-Path $root '.gopath'
$env:GOSUMDB='sum.golang.org'
$env:GOPROXY='https://proxy.golang.org'
go run ./cmd/vmcli -cmd prove -code 63007bb84c5b80156011576001036005565b00 -gas 300000020 -steps 2918921 -proof test\testdata\long_run_artifacts\20260414_165531\proof_001_from_0_steps_2918921.json
```

如果不是从 ordinal 0 生成 proof，请优先使用快照恢复入口：

```powershell
go run ./cmd/vmcli -cmd prove-snapshot -snap <start_snapshot.json> -steps <segment_steps> -proof <proof.json>
go run ./cmd/vmcli -cmd verify-precompile -snap <start_snapshot.json> -proof <proof.json>
```

然后把 `VerCom/.env.example` 复制成 `.env`，至少填好：

- `PUREVM_VERIFIER_TARGET`
- `PUREVM_VERIFIER`
- `PUREVM_TASK_MANAGER`
- `PUREVM_SNAPSHOT_STORE`
- `PUREVM_CHALLENGE_RESOLVER`
- `VALIDATOR_MANAGER`
- `OPTIMISTIC_COORDINATOR`
- `REQUESTER_PRIVATE_KEY`
- `EXECUTOR_PRIVATE_KEY`
- `VALIDATOR_PRIVATE_KEY`

再确认这些示例值：

- `PUREVM_ARTIFACT_DIR=E:/crosschain/offchain_com/purevm/test/testdata/long_run_artifacts/20260414_165531`
- `PUREVM_FROM_ORDINAL=0`
- `PUREVM_SNAPSHOT_FILE=...snapshot_000_initial.json`
- `PUREVM_PROOF_FILE=...proof_001_from_0_steps_2918921.json`
- `PUREVM_NEXT_STEP_NUMBER=2918921`
- `PUREVM_NEXT_GAS_USED=11999998`
- `PUREVM_NEXT_GAS_REMAINING=288000022`
- `PUREVM_NEXT_STATE_ROOT=0x87f7a67d174168bf022f2f292accbc7472779491c6961ba89a9b0abf68e6d227`

完整运行顺序建议是：

1. 部署

```powershell
forge script script/DeployVerCom.s.sol:DeployVerComScript --rpc-url <RPC_URL> --broadcast
```

2. 用部署返回的地址填 `.env`

3. 跑端到端脚本

```powershell
forge script script/RunPureVMChallengeE2E.s.sol:RunPureVMChallengeE2EScript --rpc-url <RPC_URL> --broadcast
```

这个脚本会完成：

- 创建 PureVM task
- 用 `checkpointTaskSummaryHash` 发布 optimistic task
- 验证者 stake
- 执行方 claim
- 执行方提交错误 checkpoint claim
- 选中验证者发起 challenge
- challenge 进入 `PureVMChallengeResolver -> PureVMTaskManager -> PureVMVerifierAdapter`
- `PureVMTaskManager` 记录 dispute 摘要

## 注意事项

- 部署时请把 `PUREVM_VERIFIER_TARGET` 指向正确的 verifier / precompile 地址。
- `PUREVM_VERIFIER_TARGET` 必须至少实现 128 字节返回协议；详见根目录 [`../DESIGN_HANDOFF.md`](../DESIGN_HANDOFF.md)。
- PureVM optimistic task 的 `summaryHash` / `resultHash` 必须使用 checkpoint 绑定哈希，不要用普通字符串哈希替代。
- `cache/`、`out/`、`broadcast/` 等 Foundry 产物默认不应提交到 Git。
