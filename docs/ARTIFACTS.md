# Artifact 规范

本文档说明 `purevm/cmd/vmcli -cmd generate-artifacts` 生成的文件，以及这些文件如何映射到 VerCom 脚本和链上字段。

## 1. 生成命令

推荐生成测试友好规模的真实 artifact：

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

输出目录：

```text
purevm/test/testdata/e2e_artifacts/current/
  task_manifest.json
  task_bytecode.hex
  snapshot_index.json
  snapshot_000_initial.json
  snapshot_001_step_122_gas_494.json
  proof_001_from_0_steps_122.json
  ...
```

生成的 `e2e_artifacts/` 默认被 Git 忽略。

## 2. `task_manifest.json`

字段来自 `artifactTaskManifest`：

| 字段 | 含义 |
| --- | --- |
| `bytecode_hex` | 任务 bytecode，带 `0x` 前缀 |
| `code_hash` | `keccak256(bytecode)` |
| `loop_iterations` | E2E countdown loop 迭代次数 |
| `total_gas` | 任务实际总 Gas |
| `snapshot_threshold_gas` | checkpoint 切分阈值 |
| `chain_id` | snapshot header 中使用的链 ID |
| `gas_formula` | E2E 示例 Gas 公式 |
| `artifact_kind` | 当前为 `e2e` |
| `proofs_generated` | 是否写入相邻 proof 文件 |
| `max_snapshot_bytes` | Go precompile snapshot 上限 |
| `max_proof_bytes` | Go precompile proof 上限 |
| `recommended_from_ordinal` | 推荐脚本首段起点 ordinal |
| `recommended_proof_file` | 推荐首段 proof 文件 |
| `recommended_proof_bytes` | 推荐 proof 大小 |
| `recommended_snapshot_file` | 推荐起点 snapshot 文件 |
| `recommended_next_checkpoint` | 推荐 next checkpoint 摘要 |

E2E 示例 bytecode 使用 countdown loop，Gas 公式为：

```text
totalGas = 24 + 37 * iterations
```

`-gas` 是目标下限，生成器会选择足够迭代次数，使实际 `total_gas` 不小于该值。

## 3. `snapshot_index.json`

`snapshot_index.json` 是执行方或验证者提交 checkpoint 序列的主要链下索引。

每个 snapshot entry 至少用于解析：

- ordinal
- step number
- gas used
- gas remaining
- state root
- snapshot file
- snapshot blob hash
- adjacent proof file
- adjacent proof steps

常用命令：

```bash
cd purevm
go run ./cmd/vmcli \
  -cmd verify-index \
  -index test/testdata/e2e_artifacts/current/snapshot_index.json \
  -ordinal 0
```

定位两条 checkpoint 序列的第一分歧段：

```bash
go run ./cmd/vmcli \
  -cmd locate-dispute \
  -claimed-index executor_snapshot_index.json \
  -verified-index validator_snapshot_index.json
```

## 4. Snapshot 文件

Snapshot 文件是 `StandardSnapshot` JSON：

```go
type StandardSnapshot struct {
    Header SnapshotHeaderV1  `json:"header"`
    State  VMState           `json:"state"`
    Meta   map[string]string `json:"meta,omitempty"`
}
```

完整性要求：

- `header.code_hash == state.code_hash`
- `keccak256(state.code) == state.code_hash`
- `state.Hash() == header.state_root`

新生成的 bytes 字段使用 `0x` hex：

- `state.code`
- `state.memory`
- `state.call_data`

读取逻辑兼容旧版 Go 默认 base64 `[]byte` JSON。

检查 snapshot：

```bash
cd purevm
go run ./cmd/vmcli \
  -cmd check-snapshot \
  -snap test/testdata/e2e_artifacts/current/snapshot_000_initial.json
```

## 5. Proof 文件

Proof 文件是 `TransitionProof` JSON。它描述从某个 snapshot state 到下一个 checkpoint state 的完整逐步转移。

验证 proof：

```bash
cd purevm
go run ./cmd/vmcli \
  -cmd verify \
  -snap test/testdata/e2e_artifacts/current/snapshot_000_initial.json \
  -proof test/testdata/e2e_artifacts/current/proof_001_from_0_steps_122.json
```

模拟 Solidity adapter 调用 Go precompile：

```bash
go run ./cmd/vmcli \
  -cmd verify-precompile \
  -snap test/testdata/e2e_artifacts/current/snapshot_000_initial.json \
  -proof test/testdata/e2e_artifacts/current/proof_001_from_0_steps_122.json
```

当前 proof payload 上限是 1,048,576 bytes。若生成器提示 proof 超上限，应降低 `-gas` 或 `-threshold`，或者使用更细分的争议流程。

## 6. 链上脚本变量映射

`VerCom/.env.example` 中的示例变量可由 artifact 填充。

| `.env` 变量 | 来源 |
| --- | --- |
| `PUREVM_CODE_HASH` | `task_manifest.json.code_hash` |
| `PUREVM_TOTAL_GAS` | `task_manifest.json.total_gas` |
| `PUREVM_SNAPSHOT_THRESHOLD_GAS` | `task_manifest.json.snapshot_threshold_gas` |
| `PUREVM_CHAIN_ID` | `task_manifest.json.chain_id` |
| `PUREVM_INITIAL_STATE_ROOT` | `snapshot_000_initial.json.header.state_root` |
| `PUREVM_INITIAL_SNAPSHOT_HASH` | `keccak256(snapshot_000_initial.json bytes)` |
| `PUREVM_INITIAL_SNAPSHOT_URI` | snapshot URI，例如 `file://.../snapshot_000_initial.json` |
| `PUREVM_FROM_ORDINAL` | `task_manifest.json.recommended_from_ordinal` 或 dispute locator 输出 |
| `PUREVM_SNAPSHOT_FILE` | 起点 snapshot 文件 |
| `PUREVM_NEXT_STEP_NUMBER` | next snapshot entry step number |
| `PUREVM_NEXT_GAS_USED` | next snapshot entry gas used |
| `PUREVM_NEXT_GAS_REMAINING` | next snapshot entry gas remaining |
| `PUREVM_NEXT_STATE_ROOT` | next snapshot entry state root |
| `PUREVM_NEXT_SNAPSHOT_HASH` | `keccak256(next snapshot bytes)` |
| `PUREVM_NEXT_SNAPSHOT_URI` | next snapshot URI |
| `PUREVM_PROOF_FILE` | adjacent proof 文件 |
| `PUREVM_PROOF_URI` | proof URI |
| `PUREVM_ARTIFACT_DIR` | artifact 目录 |

`RunPureVMChallengeE2E.s.sol` 可以从 `snapshot_index.json` 读取 adjacent proof 文件，因此该脚本允许 `PUREVM_PROOF_FILE` 为空。

## 7. Manifest URI 建议

测试网可以使用：

```text
file://../purevm/test/testdata/e2e_artifacts/current/task_manifest.json
```

更接近真实部署时，建议把整个 artifact 目录发布到稳定数据层，并使用：

- `ipfs://...`
- `https://...`
- blob/DA 层引用

链上只保存 URI 和 hash，审计者应根据 hash 校验实际下载内容。

## 8. 清理和复现

生成目录已被忽略，可以删除后重新生成：

```bash
rm -rf purevm/test/testdata/e2e_artifacts/current
```

重新生成时，只要 `-gas`、`-threshold`、`-chainid` 和代码生成逻辑一致，输出的 checkpoint 语义应保持确定性。文件时间戳或路径不应作为协议安全依据。
