# VerCom

`VerCom` 是 `offchain_com` 的链上合约部分，使用 Foundry 开发。它不是“在链上执行 PureVM”的系统，而是围绕链下 PureVM 执行结果建立的链上裁判系统。

链上只负责：

- 记录 task、checkpoint、result、artifact manifest 等承诺
- 检查 optimistic task 和 PureVM checkpoint 的绑定关系
- 管理执行窗口、挑战窗口、背书门槛和取消路径
- 调用 verifier / precompile 裁决 PureVM checkpoint 事实
- 记录 DA 可用性状态和 DA challenge 结果
- 按任务创建时确定的经济规则结算 reward、bond 和 slash

链下仍然负责实际执行 PureVM、生成 snapshot、proof、subdivision schedule 和 artifact manifest。

## 相关文档

- [`../docs/QUICKSTART.md`](../docs/QUICKSTART.md): 本地测试、artifact 生成和文件驱动 E2E。
- [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md): VerCom 在整体系统里的分层和数据流。
- [`../docs/PROTOCOL.md`](../docs/PROTOCOL.md): checkpoint-bound task、challenge payload、DA 和 dispute game 的协议约束。
- [`../docs/ARTIFACTS.md`](../docs/ARTIFACTS.md): PureVM artifact 与 `.env` 变量映射。
- [`../docs/DEPLOYMENT_AND_OPERATIONS.md`](../docs/DEPLOYMENT_AND_OPERATIONS.md): 部署、脚本、监控和生产化注意事项。
- [`../README.md`](../README.md): 完整设计交接和协议总览。

## 合约分层

### `PureVMTaskManager`

PureVM 事实层。它负责创建 PureVM task、冻结 verifier 地址和版本、登记 checkpoint、验证相邻 checkpoint、记录 snapshot / proof / manifest / subdivision 的数据可用性元数据、处理 DA availability challenge、运行二次细分争议游戏，并把最终裁决结果写成链上事实。

### `PureVMVerifierAdapter`

Verifier 边界层。它只负责把 Solidity 侧的 `startSnapshotBytes` 和 `proofBytes` 编码成 Go precompile / verifier target 的输入格式，并解析 verifier 返回的事实。

当前输入格式为：

```text
[stateLen:4][proofLen:4][snapshotOrStateBytes][proofBytes]
```

当前接受两类返回：

```text
[valid:32][finalStateRoot:32][verifiedSteps:32][traceRoot:32]
[valid:32][initialStateRoot:32][finalStateRoot:32][verifiedSteps:32][traceRoot:32]
```

旧的 32 字节 bool-only 返回会被拒绝。adapter 会检查 final root、steps 和可选 trace root，并限制 snapshot/proof payload 大小。

### `PureVMChallengeResolver`

Optimistic challenge 和 PureVM checkpoint verification 之间的连接层。它解码 challenge payload，检查 optimistic task 的 `summaryHash` 是否绑定到 `payload.pureVMTaskId` 和 `payload.fromOrdinal + 1`，然后调用 `PureVMTaskManager.resolveDispute(...)` 进入真实 checkpoint 验证路径。

### `OptimisticTaskCoordinator`

经济和任务生命周期层。它负责发布 optimistic task、执行方认领、提交结果、记录 PureVM checkpoint 绑定、要求 PureVM-bound result 携带 artifact manifest、选验证者、接收背书、处理挑战、finalize、超时取消和按比例结算。

### `ValidatorManager`

验证者 stake / 选择层。验证者先 stake，满足 `minimumStake` 后进入候选集合，coordinator 在结果提交后按 stake 权重选出本任务的验证者。

### `PureVMSnapshotStore`

测试和演示用临时 bytes store。它可以把小型 snapshot bytes 暂存到链上，供 `verifyAndAppendCheckpointFromStore(...)` 读取。真实协议不应该依赖它作为长期 DA。

## PureVM Verifier 治理

`PureVMTaskManager` 对新建 PureVM task 启用 verifier 白名单：

- owner 调用 `setVerifierApproval(verifier, version, approved)`
- `createTask(...)` 只接受已批准且 version 非 0 的 verifier
- 每个 task 在创建时保存 `verifier` 和 `verifierVersion`
- 后续 verifier 升级或撤销白名单不会改变历史 task 的 verifier 语义

部署脚本会默认把新部署的 `PureVMVerifierAdapter` 以 version `1` 加入白名单。升级 verifier 时推荐部署新的 adapter / target，设置新版本，然后创建新的 PureVM task。

## PureVM Checkpoint Claim

PureVM 类 optimistic task 不提交任意业务字符串，而是提交某个 PureVM checkpoint 的 claim。

约定如下：

```text
summaryHash = checkpointTaskSummaryHash(pureVMTaskId, checkpointOrdinal)
resultHash = checkpointClaimHash(pureVMTaskId, checkpointOrdinal, checkpoint)
claimedStateRoot = checkpoint.stateRoot
```

`OptimisticTaskCoordinator.postPureVMCheckpointTask(...)` 会显式记录：

```text
optimisticTaskId -> pureVMTaskId, checkpointOrdinal
```

并触发 `PureVMCheckpointBound` event。浏览器、脚本和审计者可以直接查询 `pureVMCheckpointBindings(taskId)`，不必只从 hash 推断绑定关系。

PureVM-bound task 必须用 `submitPureVMCheckpointResult(...)` 提交结果，并提供：

- result URI
- checkpoint claim hash
- claimed state root
- artifact manifest hash
- artifact manifest URI

普通 `submitResult(...)` 会拒绝 PureVM-bound task，避免执行方绕过 artifact manifest 约束。

## Optimistic Task 生命周期

`OptimisticTaskCoordinator.TaskStatus` 包含：

```text
Open -> Claimed -> ResultSubmitted -> Finalized
Open -> Cancelled
Claimed -> Cancelled
ResultSubmitted -> Challenged
ResultSubmitted -> Cancelled
```

### `Open`

requester 调用 `postTask(...)` 或 `postPureVMCheckpointTask(...)` 发布任务并转入 `rewardPool`。

退出路径：

- executor 在 `executionDeadline` 前调用 `claimTask(...)`，进入 `Claimed`
- 如果长期没人 claim，requester 在 deadline 后调用 `cancelExpiredTask(...)`，任务进入 `Cancelled`，reward 退回 requester

### `Claimed`

executor 已认领任务并提交 `executorBond`。

退出路径：

- executor 在 `executionDeadline` 前提交结果，进入 `ResultSubmitted`
- 如果 executor 超时未提交，requester 调用 `cancelExpiredTask(...)`，任务进入 `Cancelled`，reward 和 executor bond 都给 requester

### `ResultSubmitted`

结果已提交，challenge window 开启，验证者被选择。

退出路径：

- 被选中的 validator 在 challenge window 内调用 `attestResult(...)`
- 被选中的 validator 在 challenge window 内调用 `challengeResult(...)`
- challenge 成功时任务进入 `Challenged`，coordinator 立刻结算 slash
- challenge 失败时 challenger 的 challenge bond 给 executor，任务保持 `ResultSubmitted`，challenge window 结束后仍可 finalize
- challenge window 结束后，如果 attestation 数量达到 `minAttestationsRequired`，任意人可调用 `finalizeTask(...)`
- 如果启用了最小背书数但未达到，requester 可调用 `cancelUnderAttestedTask(...)`，reward 退回 requester，executor bond 退回 executor，任务进入 `Cancelled`

默认 `postTask(...)` 的 `minAttestationsRequired` 为 0，保留原型的宽松 finalize 规则。需要强背书门槛时使用 `postTaskWithAttestationThreshold(...)` 或 `postPureVMCheckpointTask(...)` 的 `minAttestationsRequired` 参数。

### `Finalized`

任务成功结算。executor 拿回 bond 并获得 executor reward，已背书 validator 平分 validator reward，未分完的 validator reward 和未分配 reward 退回 requester。

### `Challenged`

挑战成功后的终态。executor bond 被 slash，challenger 拿 `challengerSlashRewardBps` 对应份额并拿回 challenge bond，requester 拿 `requesterSlashBps` 对应份额和 rewardPool 退款。

### `Cancelled`

取消终态。取消来源包括无人 claim、executor 超时未提交、以及启用背书门槛后背书不足。

## 数据可用性和 Artifact Manifest

`PureVMTaskManager` 会登记 `DataAvailabilityMeta`，类型包括：

- `Snapshot`
- `Proof`
- `Subdivision`
- `Manifest`

每条 DA 记录包含 task id、kind、ordinal、data hash、semantic hash、size、URI、publisher、registered block 和 available flag。

artifact manifest 用于绑定一组链下审计材料，而不是只靠单个 URI。`PureVMTaskManager` 会为初始 checkpoint 和追加 checkpoint 登记 manifest。追加 checkpoint 的默认 manifest hash 绑定：

```text
taskId
fromOrdinal
toOrdinal
startSnapshotBlobHash
endSnapshotBlobHash
proofBlobHash
traceRoot
snapshotURI
proofURI
```

外部也可以调用 `registerArtifactManifest(...)` 登记明确的 manifest hash / URI。`OptimisticTaskCoordinator` 的 PureVM-bound result 也会保存 executor 提交的 `artifactManifestHash` 和 `artifactManifestURI`。

## DA Availability Challenge

DA 是链下可审计性的承诺，不是链上存储证明。因此合约提供轻量 availability challenge：

1. 任意人对已登记 `dataId` 调用 `challengeDataAvailability(dataId)`
2. 该 DA 记录会被标记为 unavailable，并打开 `DATA_AVAILABILITY_CHALLENGE_WINDOW`
3. publisher 或 task owner 可在期限内调用 `resolveDataAvailabilityChallenge(challengeId, uri)` 补齐可访问 URI，challenge 记为 `ResolvedAvailable`
4. 如果超时未补齐，任何人可调用 `resolveDataAvailabilityChallengeTimeout(challengeId)`，challenge 记为 `ResolvedUnavailable`

这个 DA challenge 不直接替代 optimistic result challenge 的资金结算。它产出的是可被脚本、验证者和审计者引用的链上可用性事实。

## 二次细分争议游戏

复杂争议可以进入 `PureVMTaskManager.createDisputeGame(...)`。争议游戏记录执行方 claimed endpoint 和挑战者 replay endpoint，双方按同一 step/gas schedule 提交 subdivision commitments。

每轮双方都需要补足累计 stake：

```text
requiredStake(round) = baseStake * 2^round
```

双方提交 subdivision 后，链上检查 schedule、共同前缀、分歧点和 endpoint 绑定。如果分歧段 gas 已不超过 `adjudicationThresholdGas`，或达到最大轮次，游戏进入 `ReadyForFinal`。最终用 `resolveDisputeGameWithProof(...)` 对最小争议段调用 verifier，裁决 `Executor`、`Challenger` 或 `BothWrong`，并结算争议游戏质押池。

如果某一轮超时且双方没有都补足 stake，任何人可调用 `resolveDisputeTimeout(...)`：

- 只有 executor 补足，executor 胜
- 只有 challenger 补足，challenger 胜
- 双方都没补足或双方都补足但仍停在 staking 状态，记为 `BothWrong`

## 资金模型

### Requester

- 发布任务时转入 `rewardPool`
- executor 超时未提交时拿回 rewardPool，并获得 executor bond
- challenge 成功时拿回 rewardPool，并获得 executor bond 的 requester 份额
- finalize 时拿回未分配的 reward 余量
- 背书不足取消时拿回 rewardPool

### Executor

- claim 时提交 `executorBond`
- 正确完成且 finalize 后拿回 bond，并获得 executor reward
- challenge 失败时获得 challenger forfeited challenge bond
- challenge 成功时 bond 被 slash
- 背书不足取消时拿回 bond，但不获得执行奖励

### Validator / Challenger

- validator 先在 `ValidatorManager` stake
- 被选中后可以 attest 或 challenge
- attester 在 finalize 后平分 validator reward
- challenger 成功时拿回 challenge bond，并获得 executor bond 的 challenger 份额
- challenger 失败时 challenge bond 给 executor

### 任务创建时固定的参数

`OptimisticTaskCoordinator.PayoutConfig` 在任务发布时固定：

- `executorRewardBps`
- `validatorRewardBps`
- `challengerSlashRewardBps`
- `requesterSlashBps`
- `challengeBond`

此外，任务也固定：

- `executionDeadline`
- `validatorCount`
- `minAttestationsRequired`
- `executorBondRequired`
- 对 PureVM-bound task，固定 `pureVMTaskId` 和 `checkpointOrdinal`

## 接口上限

主要入口限制：

- URI: 2,048 bytes
- 直接传入 snapshot: 262,144 bytes
- proof: 1,048,576 bytes
- challenge payload: 1,320,000 bytes
- subdivision commitments: 128 条
- dispute rounds: 16
- dispute round duration: 最长 30 days

这些限制在 coordinator、resolver、task manager、snapshot store、verifier adapter 和 Go precompile 路径上保持一致。

## 测试

在 `VerCom` 目录下：

```bash
forge test
```

当前测试覆盖：

- PureVM task 创建和 verifier 白名单 / version 冻结
- checkpoint 追加、阈值拒绝和 finalization
- snapshot store 上传、读取、删除
- artifact manifest 登记
- DA 登记、状态更新、availability challenge 补齐和超时
- adapter precompile payload 编码、128/160 字节响应解析和旧响应拒绝
- optimistic task claim、submit、attest、challenge、finalize
- unclaimed / claimed 超时取消
- 最小背书门槛和背书不足取消
- PureVM checkpoint binding registry
- PureVM-bound task 强制 artifact manifest
- PureVM challenge resolver 联动
- 二次细分争议游戏、累计质押、timeout 和最终 proof 裁决
- 部署脚本连线、resolver 授权和 verifier 白名单
- 可选真实 artifact 文件驱动 E2E 脚本测试

## 脚本

### 部署

```bash
export PUREVM_VERIFIER_TARGET=0xYourVerifierTarget
forge script script/DeployVerCom.s.sol:DeployVerComScript --rpc-url <RPC_URL> --broadcast
```

可选部署参数：

- `VERCOM_VALIDATOR_MIN_STAKE`
- `VERCOM_VALIDATOR_EXIT_DELAY`
- `VERCOM_DEFAULT_CHALLENGE_WINDOW`

部署脚本会创建：

- `ValidatorManager`
- `PureVMSnapshotStore`
- `PureVMVerifierAdapter`
- `PureVMTaskManager`
- `PureVMChallengeResolver`
- `OptimisticTaskCoordinator`

并自动：

- 把 verifier adapter 以 version `1` 加入 `PureVMTaskManager` 白名单
- 授权 challenge resolver 调用 `PureVMTaskManager.resolveDispute(...)`

### 创建 PureVM Task

```bash
forge script script/CreatePureVMTask.s.sol:CreatePureVMTaskScript --rpc-url <RPC_URL> --broadcast
```

注意：`PUREVM_VERIFIER` 必须已经通过 `setVerifierApproval(...)` 加入白名单。

### 上传快照到临时 Store

```bash
forge script script/UploadSnapshotToStore.s.sol:UploadSnapshotToStoreScript --rpc-url <RPC_URL> --broadcast
```

### 从 Store 验证并追加 Checkpoint

```bash
forge script script/VerifyCheckpointFromStore.s.sol:VerifyCheckpointFromStoreScript --rpc-url <RPC_URL> --broadcast
```

### 删除已使用快照

```bash
forge script script/DeleteSnapshotFromStore.s.sol:DeleteSnapshotFromStoreScript --rpc-url <RPC_URL> --broadcast
```

### 真实文件驱动挑战流程

先在 `purevm` 目录生成测试友好规模的真实产物：

```bash
go run ./cmd/vmcli \
  -cmd generate-artifacts \
  -out test/testdata/e2e_artifacts/current \
  -gas 100000 \
  -threshold 500 \
  -chainid 1337 \
  -proofs=true
```

验证首段 proof：

```bash
go run ./cmd/vmcli \
  -cmd verify-precompile \
  -snap test/testdata/e2e_artifacts/current/snapshot_000_initial.json \
  -proof test/testdata/e2e_artifacts/current/proof_001_from_0_steps_122.json
```

在 `VerCom` 目录运行：

```bash
forge script script/RunPureVMChallengeE2E.s.sol:RunPureVMChallengeE2EScript --rpc-url <RPC_URL> --broadcast
```

该脚本会读取：

- `task_manifest.json`
- `snapshot_index.json`
- `snapshot_*.json`
- proof 文件

并串起：

- PureVM task 创建
- PureVM checkpoint-bound optimistic task 发布
- 验证者 stake
- executor claim
- executor 提交错误 checkpoint claim 和 artifact manifest
- validator challenge
- `OptimisticTaskCoordinator -> PureVMChallengeResolver -> PureVMTaskManager -> PureVMVerifierAdapter` 裁决
- `PureVMTaskManager` 记录 dispute 摘要

本地可打开可选 E2E 脚本测试：

```bash
PUREVM_E2E_SCRIPT_TEST=1 \
PUREVM_ARTIFACT_DIR=../purevm/test/testdata/e2e_artifacts/current \
forge test --match-contract RunPureVMChallengeE2EScriptTest
```

普通 `forge test` 不设置 `PUREVM_E2E_SCRIPT_TEST=1` 时不会要求本地产物存在。

## `.env.example`

[`VerCom/.env.example`](./.env.example) 已列出脚本变量，包括：

- 合约地址
- 三个参与方私钥
- PureVM task 元数据
- snapshot / proof 文件路径
- artifact directory
- optimistic task reward、bond、challenge bond、validator count 和 min attestations
- PureVM-bound result 的 artifact manifest URI

示例 artifact 参数来自：

```bash
go run ./cmd/vmcli -cmd generate-artifacts -out test/testdata/e2e_artifacts/current -gas 100000 -threshold 500 -chainid 1337 -proofs=true
```

示例首段：

- `PUREVM_FROM_ORDINAL=0`
- `PUREVM_NEXT_STEP_NUMBER=122`
- `PUREVM_NEXT_GAS_USED=494`
- `PUREVM_NEXT_GAS_REMAINING=99541`
- `PUREVM_NEXT_STATE_ROOT=0xb4d6e45ed4befffb8b6fe30405312598f9da9289b8af2591620c75ea5abf44a7`

完整运行顺序建议：

1. 部署 `DeployVerCom.s.sol`
2. 用部署返回地址填 `.env`
3. 确认 verifier target 响应协议
4. 生成并验证 PureVM artifacts
5. 运行 `RunPureVMChallengeE2E.s.sol`

## 注意事项

- `PUREVM_VERIFIER_TARGET` 必须指向正确的 verifier / precompile 地址。
- verifier target 必须至少实现 128 字节返回协议。
- 新 PureVM task 只能使用已白名单批准的 verifier。
- PureVM-bound optimistic task 应使用 `postPureVMCheckpointTask(...)` 和 `submitPureVMCheckpointResult(...)`。
- PureVM optimistic task 的 `summaryHash` / `resultHash` 必须使用 checkpoint 绑定哈希。
- DA challenge 只记录可用性事实，不直接做 reward / slash 结算。
- `cache/`、`out/`、`broadcast/` 等 Foundry 产物默认不应提交到 Git。
