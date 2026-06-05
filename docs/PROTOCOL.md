# 协议说明

本文档记录 `offchain_com` 的核心协议对象、不变量和链上链下交互流程。更完整的设计叙述见根目录 [`README.md`](../README.md)。

## 1. PureVM Task

PureVM task 描述一次确定性计算任务：

```text
task = (
  bytecode,
  initial VMState,
  totalGas,
  snapshotThresholdGas,
  pureVMChainId
)
```

链上 `taskId` 由以下字段绑定：

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

含义：

- 不同 owner/nonce 会得到不同 task。
- 不同 code hash、Gas 配置或 initial root 不能复用 task id。
- `verifier` 和 `verifierVersion` 在 task 创建时冻结。

## 2. Checkpoint

每个 checkpoint 绑定一段执行进度和状态：

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

相邻 checkpoint 定义链上最小默认验证单位：

```text
segment = checkpoint[fromOrdinal] -> checkpoint[fromOrdinal + 1]
```

必须满足：

- `next.stepNumber > start.stepNumber`
- `next.gasUsed > start.gasUsed`
- `next.gasUsed + next.gasRemaining == totalGas`
- `nextOrdinal == start.ordinal + 1`
- 非 final segment 的 `next.gasUsed - start.gasUsed <= snapshotThresholdGas`
- final checkpoint 允许 `next.gasUsed == totalGas`

链上 metadata 不能单独证明 checkpoint 是阈值切分下的真实下一点，真实语义由 verifier 重放 proof 后裁决。

## 3. Snapshot 绑定

链上 checkpoint 保存：

```text
snapshotBlobHash = keccak256(snapshotBytes)
```

验证相邻 segment 时：

- `keccak256(startSnapshotBytes)` 必须等于起点 checkpoint 的 `snapshotBlobHash`。
- start snapshot 必须通过 PureVM snapshot 完整性校验。
- snapshot 内 `state.code_hash` 必须等于 `keccak256(state.code)`。
- `state.Hash()` 必须等于 snapshot header 的 `state_root`。
- proof 的 `InitialHash` 必须等于 start state root。
- proof 的 `CodeHash` 必须等于 start state code hash。

## 4. Transition Proof

`TransitionProof` 描述从起点状态到终点状态的一段执行：

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

链上 verifier 返回：

```text
valid
finalStateRoot
verifiedSteps
traceRoot
```

调用方必须检查：

- `valid == true`
- `finalStateRoot == nextCheckpoint.stateRoot`
- `verifiedSteps == nextCheckpoint.stepNumber - start.stepNumber`
- 如果传入 expected trace root，则 `traceRoot` 必须一致。

## 5. Verifier / Precompile ABI

Solidity adapter 和 Go precompile 使用统一输入：

```text
[stateLen:4][proofLen:4][snapshotOrStateBytes][proofBytes]
```

编码规则：

- `stateLen` 是 big-endian `uint32`。
- `proofLen` 是 big-endian `uint32`。
- 推荐 `snapshotOrStateBytes` 使用完整 `StandardSnapshot` JSON。
- `proofBytes` 是 `TransitionProof` JSON。

Go precompile 当前返回 128 字节：

```text
[valid:32][finalStateRoot:32][verifiedSteps:32][traceRoot:32]
```

Solidity adapter 还兼容 160 字节 detailed 响应：

```text
[valid:32][initialStateRoot:32][finalStateRoot:32][verifiedSteps:32][traceRoot:32]
```

旧的 32 字节 bool-only 响应会被拒绝，因为它无法让 adapter 检查 final root、steps 和 trace root 是否绑定到当前上下文。

## 6. Checkpoint-bound Optimistic Task

PureVM 类 optimistic task 必须使用 checkpoint-bound hash。

```solidity
summaryHash = checkpointTaskSummaryHash(pureVMTaskId, checkpointOrdinal)
resultHash  = checkpointClaimHash(pureVMTaskId, checkpointOrdinal, checkpoint)
```

`checkpointTaskSummaryHash`：

```solidity
keccak256(abi.encode("PUREVM_CHECKPOINT_TASK", taskId, checkpointOrdinal))
```

`checkpointClaimHash`：

```solidity
keccak256(abi.encode(
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

`OptimisticTaskCoordinator.postPureVMCheckpointTask(...)` 会记录：

```text
optimisticTaskId -> pureVMTaskId, checkpointOrdinal
```

PureVM-bound task 必须用 `submitPureVMCheckpointResult(...)` 提交，并携带 artifact manifest。普通 `submitResult(...)` 会拒绝 PureVM-bound task。

## 7. Challenge Payload

`PureVMChallengeResolver.ChallengePayload` 包含：

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

1. coordinator 检查 `challengeData.length <= MAX_CHALLENGE_DATA_BYTES`。
2. resolver 解码 payload。
3. resolver 检查 snapshot/proof 子字段上限。
4. resolver 计算 `toOrdinal = fromOrdinal + 1`。
5. resolver 检查 optimistic task 的 `summaryHash` 等于 `checkpointTaskSummaryHash(pureVMTaskId, toOrdinal)`。
6. resolver 调 `PureVMTaskManager.resolveDispute(...)`。
7. task manager 调 verifier 并记录 `DisputeMeta`。
8. coordinator 根据 actual result hash 与 executor claim 是否一致结算 challenge。

## 8. Data Availability

DA 记录使用：

```solidity
dataAvailabilityId(taskId, kind, ordinal, dataHash, semanticHash)
```

`DataKind` 当前包括：

- `Snapshot`
- `Proof`
- `Subdivision`
- `Manifest`

语义约定：

- Snapshot 的 `semanticHash` 通常是 state root。
- Proof 的 `semanticHash` 通常是 trace root。
- Subdivision 的 `semanticHash` 绑定 game、提交方和 round。
- Manifest 的 `semanticHash` 是 manifest hash。

DA challenge 流程：

1. 任意人调用 `challengeDataAvailability(dataId)`。
2. DA 记录标记为 unavailable，并打开 1 天 challenge window。
3. publisher 或 task owner 调 `resolveDataAvailabilityChallenge(challengeId, uri)` 补齐 URI。
4. 超时未补齐时，任何人可调用 `resolveDataAvailabilityChallengeTimeout(challengeId)`。

DA challenge 只产出可用性事实，不直接替代 optimistic challenge 的 reward/slash 结算。

## 9. Artifact Manifest

artifact manifest 绑定一组链下审计材料，而不是只依赖单个 snapshot/proof URI。

checkpoint 追加时，默认 manifest hash 绑定：

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

外部可以用 `registerArtifactManifest(...)` 登记明确 manifest hash 和 URI。

## 10. 二次细分争议游戏

当相邻 checkpoint segment 仍然太大时，可进入 `DisputeGame`。

每轮双方都要补足累计 stake：

```text
requiredStake(round) = baseStake * 2^round
```

双方提交相同 step/gas schedule 的 subdivision commitments：

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

- commitment 数量在 `[2, 128]`。
- 第一个点等于当前共同起点。
- index 连续递增。
- stepNumber 和 gasUsed 严格递增。
- 双方 schedule 的 index、stepNumber、gasUsed 完全一致。
- endpoint 分别等于 executor 和 challenger 当前承诺 endpoint。

`declareDivergence(...)` 找到第一分歧点。如果分歧段 Gas 小于等于 `adjudicationThresholdGas`，或达到最大轮次，进入 `ReadyForFinal`。

最终 `resolveDisputeGameWithProof(...)` 用共同起点 snapshot 和最小争议段 proof 裁决：

- actual root 等于 executor root 且不等于 challenger root：executor 胜。
- actual root 等于 challenger root 且不等于 executor root：challenger 胜。
- 其他情况：双方都错，质押池平分退回。

## 11. 统一上限

| 字段 | 上限 |
| --- | --- |
| URI | 2,048 bytes |
| snapshot bytes | 262,144 bytes |
| proof bytes | 1,048,576 bytes |
| challenge data | 1,320,000 bytes |
| subdivision commitments | 128 |
| dispute rounds | 16 |
| dispute round duration | 30 days |
| DA challenge window | 1 day |

修改这些上限时，需要同步检查 Go precompile、Solidity adapter、resolver、task manager、coordinator、snapshot store 和测试。
