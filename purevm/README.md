# purevm

`purevm` 是一个链下计算与快照验证原型，用 Go 实现。它的目标不是做完整 EVM 节点，而是做一套可以：

- 执行纯计算任务
- 为执行过程生成 Gas 尺度的中间快照
- 生成和验证状态转移 proof
- 作为链上乐观挑战的链下执行基座

## 主要能力

- 256 位栈式执行模型
- 已实现的一组 EVM 风格 opcode 子集
- 每条支持的指令都带明确 Gas 权重
- 按 `snapshotThresholdGas` 进行快照切分
- 快照索引 `snapshot_index.json`
- “按同样阈值规则推导下一个快照 hash”的恢复验证
- 状态转移 proof 生成与重放验证
- Go 版预编译验证原型

## 核心目录

```text
purevm/
  cmd/vmcli/      # 命令行工具
  core/           # VM、状态、Gas、快照、索引
  proof/          # 证明生成、相邻快照验证
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

### 直接验证快照 + proof

```powershell
go run ./cmd/vmcli -cmd verify -snap snapshot.json -proof proof.json
```

### 按索引选择中间快照做相邻验证

```powershell
go run ./cmd/vmcli -cmd verify-index -index path\\to\\snapshot_index.json -ordinal 3
```

## 测试

### 常规测试

```powershell
$root=(Get-Location).Path
$env:GOCACHE=Join-Path $root '.gocache'
$env:GOMODCACHE=Join-Path $root '.gomodcache'
$env:GOPATH=Join-Path $root '.gopath'
$env:GOSUMDB='off'
$env:GOPROXY='https://proxy.golang.org'
go test -v -mod=mod ./test
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

## 已有测试覆盖

- 基础算术执行
- 快照完整性
- proof 生成与重放验证
- Gas 一致性
- 内存扩展
- 快照序列拼接
- 快照索引恢复验证
- 快照阈值规则验证

## 当前边界

- 当前实现的是一组 PureVM 支持的 EVM 风格 opcode 子集，不是完整 EVM。
- 长任务测试默认不会全量生成所有 proof 文件，避免体积过大；需要时可显式打开。
