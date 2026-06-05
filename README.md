# offchain_com

`offchain_com` 是一个把链下计算和链上乐观验证串起来的实验仓库。系统在链下执行过程中持续生成 checkpoint，链上记录承诺，并在挑战时裁决具体的 checkpoint 段或细分后的最小争议段。

- [`purevm`](./purevm): 一个用 Go 实现的纯计算虚拟机，负责执行任务、按 Gas 阈值切分快照、生成和验证状态转移证明。
- [`VerCom`](./VerCom): 一个用 Foundry 编写的 Solidity 合约工程，负责任务发布、执行方/验证方质押、验证者选举、checkpoint claim 绑定、乐观挑战和 PureVM 快照验证接入。

详细交接设计说明见 [`DESIGN_HANDOFF.md`](./DESIGN_HANDOFF.md)。

## 仓库结构

```text
offchain_com/
  purevm/   # 链下执行、快照、proof、预编译验证原型
  VerCom/   # 链上任务管理、质押、挑战、结算合约
```

## 当前实现了什么

### purevm

- EVM 风格 256 位栈式执行环境
- 一组已实现且带 Gas 权重的指令子集
- 按 `snapshotThresholdGas` 进行快照切分
- 快照索引 `snapshot_index.json`
- “按同样阈值规则推导下一个快照 hash”的恢复验证
- 状态转移 proof 生成与重放验证
- 第一层分歧 checkpoint 段定位
- Go 版预编译验证原型，输入/输出格式与 Solidity adapter 已对齐

更详细说明见 [`purevm/README.md`](./purevm/README.md)。

### VerCom

- `PureVMTaskManager`: 管理 PureVM task、checkpoint、数据可用性、相邻验证、二次细分争议和裁决摘要
- `PureVMSnapshotStore`: 临时快照上链/删除
- `PureVMVerifierAdapter`: 适配 Go 预编译调用格式
- `PureVMChallengeResolver`: 将乐观挑战绑定到指定 PureVM checkpoint 并接入快照验证
- `ValidatorManager`: 验证者 PoS 质押和随机选举
- `OptimisticTaskCoordinator`: 用户发布任务、执行方认领、验证者背书、挑战和收益分配

更详细说明见 [`VerCom/README.md`](./VerCom/README.md)。

## 整体流程

### 链下

1. 在 `purevm` 中定义一个总 Gas 明确的计算任务。
2. 执行时，如果“下一步 Gas 会让当前窗口超过阈值”，就先保存当前快照。
3. 把这些快照保存为 `snapshot_*.json`，并生成 `snapshot_index.json`。
4. 验证时，从某个起始快照恢复 VM，按同样规则推导“下一个快照”，比较其 `stateRoot` 是否与承诺快照一致。
5. 如果执行方承诺序列和验证者本地序列不同，可用 `vmcli -cmd locate-dispute` 找到最早分歧段。

### 链上

1. 用户发布任务并转入奖励资金；PureVM 类任务的 `summaryHash` 绑定到 `(pureVMTaskId, checkpointOrdinal)`。
2. 执行方认领任务并质押 bond。
3. 执行方提交 `checkpointClaimHash(...)` 和 claimed state root。
4. 验证者先在 `ValidatorManager` 中质押，再被随机选中。
5. 被选中验证者可以背书，或带 challenge bond 发起挑战。
6. 挑战时 resolver 校验 optimistic task 与同一 checkpoint ordinal 绑定，然后进入 `PureVMTaskManager -> PureVMVerifierAdapter`。
7. verifier 返回真实 checkpoint 后，manager 记录 `DisputeMeta`；复杂争议可进入二次细分和累计质押状态机，最终由最小争议段 proof 裁决。

## 本地测试

### purevm

在 `purevm` 目录下：

```powershell
$root=(Get-Location).Path
$env:GOCACHE=Join-Path $root '.gocache'
$env:GOMODCACHE=Join-Path $root '.gomodcache'
$env:GOPATH=Join-Path $root '.gopath'
$env:GOSUMDB='sum.golang.org'
$env:GOPROXY='https://proxy.golang.org'
go test -v -mod=mod ./...
```

完整 Gas 任务测试：

```powershell
$env:PUREVM_GAS_SCALE_TEST='1'
go test -v -mod=mod ./test -run TestFileBackedSnapshotsLongRun -timeout 10m
```

定位两条 checkpoint 序列的最早分歧段：

```powershell
go run ./cmd/vmcli -cmd locate-dispute -claimed-index executor_snapshot_index.json -verified-index validator_snapshot_index.json
```

### VerCom

在 `VerCom` 目录下：

```powershell
forge test
```

## 端到端脚本

`VerCom/script` 里已经提供了这些脚本：

- `DeployVerCom.s.sol`
- `CreatePureVMTask.s.sol`
- `UploadSnapshotToStore.s.sol`
- `VerifyCheckpointFromStore.s.sol`
- `DeleteSnapshotFromStore.s.sol`
- `RunPureVMChallengeE2E.s.sol`

其中 `RunPureVMChallengeE2E.s.sol` 设计目标是直接读取 `purevm/test/testdata/...` 里的真实快照和 proof 文件，串起任务发布到挑战验证的流程。

## 注意事项

- `purevm/test/testdata/long_run_artifacts/` 是本地测试产物目录，默认不应提交到 Git。
- `VerCom/out/`、`VerCom/cache/`、`purevm/.gocache/` 等都属于本地构建缓存。
- 当前 PureVM 实现的是“带 Gas 权重的 EVM 风格子集”，不是完整 EVM。
- 当前链上适配器已经对齐 Go 预编译协议，但真正部署到链上时，你仍然需要把 `PUREVM_VERIFIER_TARGET` 指向实际 verifier / precompile 环境。
- PureVM 类 optimistic task 的 `summaryHash` / `resultHash` 应使用 `checkpointTaskSummaryHash(...)` 和 `checkpointClaimHash(...)`，不要退回普通字符串哈希。
- Go verifier target 当前返回 128 字节 `[valid][finalStateRoot][verifiedSteps][traceRoot]`；adapter 也兼容 160 字节的 detailed 响应 `[valid][initialStateRoot][finalStateRoot][verifiedSteps][traceRoot]`。旧的 32 字节 bool-only 响应会被拒绝。
