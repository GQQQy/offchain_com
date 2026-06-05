# 部署与运维手册

本文档说明 VerCom 合约部署、脚本变量、E2E 操作顺序和生产化注意事项。

## 1. 部署前检查

先确认本地测试通过：

```bash
cd purevm
go test ./...
```

```bash
cd VerCom
forge test
```

生成并验证 E2E artifact：

```bash
cd purevm
go run ./cmd/vmcli \
  -cmd generate-artifacts \
  -out test/testdata/e2e_artifacts/current \
  -gas 100000 \
  -threshold 500 \
  -chainid 1337 \
  -proofs=true

go run ./cmd/vmcli \
  -cmd verify-precompile \
  -snap test/testdata/e2e_artifacts/current/snapshot_000_initial.json \
  -proof test/testdata/e2e_artifacts/current/proof_001_from_0_steps_122.json
```

## 2. `.env` 准备

复制模板：

```bash
cd VerCom
cp .env.example .env
```

核心地址变量：

```text
PUREVM_VERIFIER_TARGET
PUREVM_VERIFIER
PUREVM_TASK_MANAGER
PUREVM_SNAPSHOT_STORE
PUREVM_CHALLENGE_RESOLVER
VALIDATOR_MANAGER
OPTIMISTIC_COORDINATOR
```

脚本私钥变量：

```text
REQUESTER_PRIVATE_KEY
EXECUTOR_PRIVATE_KEY
VALIDATOR_PRIVATE_KEY
```

PureVM task 变量：

```text
PUREVM_CODE_HASH
PUREVM_TOTAL_GAS
PUREVM_SNAPSHOT_THRESHOLD_GAS
PUREVM_CHAIN_ID
PUREVM_INITIAL_STATE_ROOT
PUREVM_INITIAL_SNAPSHOT_HASH
PUREVM_INITIAL_SNAPSHOT_URI
```

Optimistic task 变量：

```text
OPTIMISTIC_REWARD_POOL
OPTIMISTIC_EXECUTION_WINDOW
OPTIMISTIC_VALIDATOR_COUNT
OPTIMISTIC_MIN_ATTESTATIONS
OPTIMISTIC_EXECUTOR_BOND
OPTIMISTIC_CHALLENGE_BOND
VALIDATOR_STAKE
```

不要提交 `.env`，它已被 `.gitignore` 忽略。

## 3. 部署合约

部署脚本：

```bash
cd VerCom
PUREVM_VERIFIER_TARGET=0xYourVerifierTarget \
forge script script/DeployVerCom.s.sol:DeployVerComScript \
  --rpc-url <RPC_URL> \
  --broadcast
```

可选部署参数：

```text
VERCOM_VALIDATOR_MIN_STAKE
VERCOM_VALIDATOR_EXIT_DELAY
VERCOM_DEFAULT_CHALLENGE_WINDOW
```

脚本会部署：

- `ValidatorManager`
- `PureVMSnapshotStore`
- `PureVMVerifierAdapter`
- `PureVMTaskManager`
- `PureVMChallengeResolver`
- `OptimisticTaskCoordinator`

并自动执行：

- 把 verifier adapter 以 version `1` 加入 `PureVMTaskManager` 白名单。
- 授权 challenge resolver 调用 `PureVMTaskManager.resolveDispute(...)`。

部署后把输出地址写回 `.env`。

## 4. Verifier Target 要求

`PUREVM_VERIFIER_TARGET` 必须实现 adapter 期望的返回协议。

128 字节返回：

```text
[valid:32][finalStateRoot:32][verifiedSteps:32][traceRoot:32]
```

160 字节返回：

```text
[valid:32][initialStateRoot:32][finalStateRoot:32][verifiedSteps:32][traceRoot:32]
```

不接受旧的 32 字节 bool-only 返回。

生产部署前必须确认：

- verifier target 是不可变或治理明确的。
- verifier target 使用的 PureVM 语义与 `purevm/` 当前版本一致。
- snapshot/proof payload 上限与合约一致。
- 返回的 root、steps、trace root 与 Go CLI 验证结果一致。

## 5. 创建 PureVM Task

```bash
cd VerCom
forge script script/CreatePureVMTask.s.sol:CreatePureVMTaskScript \
  --rpc-url <RPC_URL> \
  --broadcast
```

要求：

- `PUREVM_VERIFIER` 已被 `PureVMTaskManager.setVerifierApproval(...)` 批准。
- 初始 snapshot hash 是实际 snapshot bytes 的 `keccak256`。
- `PUREVM_TOTAL_GAS` 和 `PUREVM_SNAPSHOT_THRESHOLD_GAS` 与链下 artifact 一致。

## 6. SnapshotStore 验证路径

上传起点 snapshot：

```bash
forge script script/UploadSnapshotToStore.s.sol:UploadSnapshotToStoreScript \
  --rpc-url <RPC_URL> \
  --broadcast
```

从 store 验证并追加 checkpoint：

```bash
forge script script/VerifyCheckpointFromStore.s.sol:VerifyCheckpointFromStoreScript \
  --rpc-url <RPC_URL> \
  --broadcast
```

删除临时 snapshot：

```bash
forge script script/DeleteSnapshotFromStore.s.sol:DeleteSnapshotFromStoreScript \
  --rpc-url <RPC_URL> \
  --broadcast
```

`PureVMSnapshotStore` 只适合测试和小 payload 演示。生产环境应使用链下 DA，并只在链上登记 hash/URI。

## 7. 文件驱动 Challenge E2E

先生成 artifact：

```bash
cd purevm
go run ./cmd/vmcli \
  -cmd generate-artifacts \
  -out test/testdata/e2e_artifacts/current \
  -gas 100000 \
  -threshold 500 \
  -chainid 1337 \
  -proofs=true
```

再运行脚本：

```bash
cd VerCom
forge script script/RunPureVMChallengeE2E.s.sol:RunPureVMChallengeE2EScript \
  --rpc-url <RPC_URL> \
  --broadcast
```

脚本读取：

- `PUREVM_ARTIFACT_DIR/task_manifest.json`
- `PUREVM_ARTIFACT_DIR/snapshot_index.json`
- 起点和下一个 snapshot 文件
- `PUREVM_PROOF_FILE` 或 index 中的 `adjacent_proof_file`

本地脚本测试：

```bash
cd VerCom
PUREVM_E2E_SCRIPT_TEST=1 \
PUREVM_ARTIFACT_DIR=../purevm/test/testdata/e2e_artifacts/current \
forge test --match-contract RunPureVMChallengeE2EScriptTest
```

## 8. 运行时监控建议

建议索引以下事件：

- `PureVMTaskManager.TaskCreated`
- `PureVMTaskManager.CheckpointRegistered`
- `PureVMTaskManager.AdjacentCheckpointVerified`
- `PureVMTaskManager.DisputeResolved`
- `PureVMTaskManager.DataAvailabilityRegistered`
- `PureVMTaskManager.DataAvailabilityChallenged`
- `PureVMTaskManager.DataAvailabilityChallengeResolved`
- `PureVMTaskManager.DisputeGameCreated`
- `PureVMTaskManager.DisputeGameResolved`
- `OptimisticTaskCoordinator.TaskPosted`
- `OptimisticTaskCoordinator.PureVMCheckpointBound`
- `OptimisticTaskCoordinator.ResultSubmitted`
- `OptimisticTaskCoordinator.TaskArtifactManifestSubmitted`
- `OptimisticTaskCoordinator.ChallengeSucceeded`
- `OptimisticTaskCoordinator.ChallengeRejected`
- `OptimisticTaskCoordinator.TaskFinalized`
- `OptimisticTaskCoordinator.TaskCancelled`

链下 watcher 应定期检查：

- artifact URI 是否可访问。
- 下载内容的 hash 是否等于链上登记 hash。
- checkpoint index 是否能定位分歧。
- verifier target 返回是否与本地 Go verifier 一致。
- challenge window、execution deadline、DA challenge deadline 是否临近。

## 9. 常见故障

### `VerifierPayloadTooLarge`

snapshot 或 proof 超过上限。降低 `-threshold` 让相邻段更小，或减少 E2E 示例 `-gas`，或进入二次细分争议流程。

### `InvalidCheckpointProgression`

next checkpoint 的 step/gas/ordinal 与起点不相邻，或 `gasUsed + gasRemaining != totalGas`。从 `snapshot_index.json` 重新读取 next entry。

### `InvalidSnapshot`

传入的 start snapshot bytes hash 不等于链上起点 checkpoint 的 `snapshotBlobHash`。检查文件路径、换行、是否读取了错误 snapshot。

### `UnexpectedVerifierResponse`

verifier target 返回长度不是 128 或 160 字节，或返回编码不符合 adapter 预期。检查 `PUREVM_VERIFIER_TARGET`。

### `ArtifactManifestRequired`

PureVM-bound optimistic task 必须使用 `submitPureVMCheckpointResult(...)`，并提交非零 `artifactManifestHash`。

### 文件驱动脚本读不到 artifact

确认：

- `PUREVM_ARTIFACT_DIR` 是相对 `VerCom/` 的路径，或使用绝对路径。
- `VerCom/foundry.toml` 的 `fs_permissions` 允许读取该目录。
- artifact 已经生成，不在清理后的空目录里。

## 10. 生产化边界

当前项目是研究和原型系统。进入真实资金环境前，建议补齐：

- verifier target 审计和版本治理。
- 合约权限治理、暂停和升级策略。
- 更稳健的随机源，替代当前原型中的 `block.prevrandao` 选择模型。
- DA watcher、artifact pinning、不可用报警。
- bond/reward/slash 参数仿真。
- 对长任务 proof 压缩或专用证明系统的评估。
- 完整安全审计和形式化/半形式化不变量测试。
