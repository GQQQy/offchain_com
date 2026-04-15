# VerCom

`VerCom` 是 `offchain_com` 的链上部分，使用 Foundry 开发。它负责把链下 `purevm` 的计算结果、快照和挑战流程接入到以太坊风格合约里。

## 主要合约

### `PureVMTaskManager`

负责：

- 创建 PureVM task
- 记录 checkpoint
- 检查 checkpoint 的 Gas 约束
- 调用 verifier 验证相邻快照
- 追加下一个 checkpoint
- 标记任务完成

### `PureVMSnapshotStore`

负责：

- 临时把快照 bytes 上传到链上
- 在验证时读取这些快照
- 验证后删除它们

### `PureVMVerifierAdapter`

负责把 Solidity 调用转换成 Go 预编译格式。

当前已经按 `purevm/precompile/snapshot_validator.go` 的格式编码：

```text
[stateLen:4][proofLen:4][stateBytes][proofBytes]
```

### `PureVMChallengeResolver`

负责在乐观挑战时把挑战载荷导向 `PureVMTaskManager.previewCheckpointVerification(...)`，从而进入真实的 PureVM checkpoint 验证路径。

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
- 错误结果提交
- 验证者挑战
- 进入 PureVM challenge resolver

## 注意事项

- 当前合约和测试已经接上了 PureVM challenge 框架，但真正部署时仍需把 `PUREVM_VERIFIER_TARGET` 指向正确的 verifier / precompile 地址。
- `cache/`、`out/`、`broadcast/` 等 Foundry 产物默认不应提交到 Git。
