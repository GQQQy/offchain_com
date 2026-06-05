# purevm

`purevm` 是一个链下计算与快照验证原型，用 Go 实现。它的目标不是做完整 EVM 节点，而是做一套可以：

- 执行纯计算任务
- 为执行过程生成 Gas 尺度的中间快照
- 生成和验证状态转移 proof
- 作为链上乐观挑战的链下执行基座

## 相关文档

- [`../docs/QUICKSTART.md`](../docs/QUICKSTART.md): 本地测试、生成 E2E artifact 和验证首段 proof。
- [`../docs/PUREVM_SEMANTICS.md`](../docs/PUREVM_SEMANTICS.md): 当前 opcode 子集、Gas 表、state root 和 snapshot 语义。
- [`../docs/ARTIFACTS.md`](../docs/ARTIFACTS.md): `generate-artifacts` 输出目录和 manifest 字段说明。
- [`../docs/PROTOCOL.md`](../docs/PROTOCOL.md): snapshot、transition proof、checkpoint 和 challenge 的协议绑定。
- [`../README.md`](../README.md): 完整系统设计和端到端流程。

## 主要能力

- 256 位栈式执行模型
- 已实现的一组 EVM 风格 opcode 子集
- 每条支持的指令都带明确 Gas 权重
- 按 `snapshotThresholdGas` 进行快照切分
- 快照索引 `snapshot_index.json`
- “按同样阈值规则推导下一个快照 hash”的恢复验证
- 状态转移 proof 生成与重放验证
- 执行方/验证者两条 checkpoint 承诺序列的第一分歧段定位
- Go 版预编译验证原型

## 核心目录

```text
purevm/
  cmd/vmcli/      # 命令行工具
  core/           # VM、状态、Gas、快照、索引
  proof/          # 证明生成、相邻快照验证、分歧段定位
  precompile/     # 预编译原型
  test/           # 集成测试和长任务测试
```

## 快照语义

当前快照切分规则是：

1. 先看下一步指令的 Gas。
2. 如果“当前窗口已用 Gas + 下一步 Gas > snapshotThresholdGas”，则先保存当前快照。
3. 保存后窗口 Gas 清零。
4. 然后再执行下一步。

验证时会从起始快照恢复，按同样规则推导“下一个快照”，并比较其 `stateRoot` 与承诺快照是否一致。

新生成的快照 JSON 中，`state.code`、`state.memory`、`state.call_data` 都使用 `0x` 前缀十六进制字符串，方便 Foundry 脚本用 `vm.parseJsonBytes` 读取。读取逻辑仍兼容旧版 Go 默认 base64 `[]byte` JSON。快照完整性会同时检查 `stateRoot` 和实际 bytecode 与 `codeHash` 的绑定。

## 分歧定位

验证者可以用本地重放得到的 `snapshot_index.json` 与执行方提交的 `snapshot_index.json` 做第一层定位：

```powershell
go run ./cmd/vmcli -cmd locate-dispute -claimed-index executor_snapshot_index.json -verified-index validator_snapshot_index.json
```

该命令会返回最早分歧的 `fromOrdinal` / `toOrdinal`、共同起始 root、双方 next root 和原因。链上 challenge payload 的 `fromOrdinal` 应优先使用这里定位出的最早分歧段。

## 命令行

在 `purevm` 目录下：

### 运行字节码

```powershell
go run ./cmd/vmcli -cmd run -code 600560030160020200
```

### 生成快照

```powershell
go run ./cmd/vmcli -cmd snapshot -code 6005600301 -steps 2 -snap snapshot.json
```

### 生成 proof

```powershell
go run ./cmd/vmcli -cmd prove -code 6005600301 -steps 2 -proof proof.json
```

### 从已有快照恢复并生成 proof

```powershell
go run ./cmd/vmcli -cmd prove-snapshot -snap snapshot.json -steps 2 -proof proof.json
```

### 检查快照完整性

```powershell
go run ./cmd/vmcli -cmd check-snapshot -snap snapshot.json
```

### 直接验证快照 + proof

```powershell
go run ./cmd/vmcli -cmd verify -snap snapshot.json -proof proof.json
```

### 按预编译输入格式验证快照 + proof

```powershell
go run ./cmd/vmcli -cmd verify-precompile -snap snapshot.json -proof proof.json
```

该命令会模拟 Solidity adapter 的 `[stateLen:4][proofLen:4][snapshotBytes][proofBytes]` 输入，并解析 128 字节 `[valid][finalStateRoot][verifiedSteps][traceRoot]` 响应。

### 按索引选择中间快照做相邻验证

```powershell
go run ./cmd/vmcli -cmd verify-index -index path\\to\\snapshot_index.json -ordinal 3
```

### 生成 VerCom E2E 产物

```bash
go run ./cmd/vmcli \
  -cmd generate-artifacts \
  -out test/testdata/e2e_artifacts/current \
  -gas 100000 \
  -threshold 500 \
  -chainid 1337 \
  -proofs=true
```

这个命令会生成：

- `task_manifest.json`
- `task_bytecode.hex`
- `snapshot_index.json`
- `snapshot_*.json`
- `proof_*.json`

默认示例规模会让相邻 proof 保持在 Go precompile / Solidity adapter 的 1MB proof payload 上限内，适合 `VerCom/script/RunPureVMChallengeE2E.s.sol` 和 `RunPureVMChallengeE2EScriptTest` 读取。完整长 Gas 任务适合做链下快照和索引压力测试；如果为几百万步相邻段生成逐步 JSON proof，通常会超过当前接口上限。

### 定位第一分歧段

```powershell
go run ./cmd/vmcli -cmd locate-dispute -claimed-index executor_snapshot_index.json -verified-index validator_snapshot_index.json
```

## 测试

### 常规测试

```powershell
$root=(Get-Location).Path
$env:GOCACHE=Join-Path $root '.gocache'
$env:GOMODCACHE=Join-Path $root '.gomodcache'
$env:GOPATH=Join-Path $root '.gopath'
$env:GOSUMDB='sum.golang.org'
$env:GOPROXY='https://proxy.golang.org'
go test -v -mod=mod ./...
```

### 完整 Gas 任务测试

```powershell
$env:PUREVM_GAS_SCALE_TEST='1'
$env:PUREVM_KEEP_FILES='1'
go test -v -mod=mod ./test -run TestFileBackedSnapshotsLongRun -timeout 10m
```

如果保留文件，测试产物会写到：

```text
purevm/test/testdata/long_run_artifacts/<timestamp>/
```

其中最重要的是：

- `task_manifest.json`
- `snapshot_index.json`
- `snapshot_*.json`
- 可选 `proof_*.json`

链上 E2E 脚本推荐使用 `generate-artifacts` 生成的小型真实产物：

```bash
go run ./cmd/vmcli -cmd generate-artifacts -out test/testdata/e2e_artifacts/current -gas 100000 -threshold 500 -proofs=true
go run ./cmd/vmcli -cmd verify-precompile -snap test/testdata/e2e_artifacts/current/snapshot_000_initial.json -proof test/testdata/e2e_artifacts/current/proof_001_from_0_steps_122.json
```

## 已有测试覆盖

- 基础算术执行
- 快照完整性
- proof 生成与重放验证
- Gas 一致性
- 内存扩展
- 快照序列拼接
- 快照索引恢复验证
- 快照阈值规则验证
- 第一分歧 checkpoint 段定位
- 快照 JSON 十六进制 bytes 格式
- 完整 snapshot 走 Go 预编译验证
- bytecode 篡改检测

## 当前边界

- 当前实现的是一组 PureVM 支持的 EVM 风格 opcode 子集，不是完整 EVM。
- 长任务测试默认不会全量生成所有 proof 文件，避免体积过大；需要时可显式打开。
- 更完整的设计说明、协议不变量和端到端流程见根目录 [`../README.md`](../README.md)。
