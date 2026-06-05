# PureVM 语义说明

本文档记录当前 `purevm` 的执行语义、状态承诺、Gas 规则和 opcode 子集。PureVM 是确定性计算原型，不是完整 EVM 节点。

## 1. 执行模型

PureVM 使用 256 位栈式模型：

- `Word` 是 32 字节大端整数。
- 无符号算术按 `2^256` 取模。
- 有符号运算使用二补码解释。
- VM state 包含 PC、stack、memory、gas、refund、code、code hash、step count、call value、call data。

`VMState`：

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

## 2. State Root

State root 使用 `SerializeCanonical()` 后的 keccak256。

当前 canonical state 包含：

- `pc`
- `stack`
- `memory`
- `gas`
- `refund`
- `code_hash`
- `step_count`

`Code` 本体不直接进入 state root，而是通过 `code_hash` 绑定。snapshot 完整性会额外检查：

```text
keccak256(state.code) == state.code_hash
state.Hash() == header.state_root
```

## 3. Snapshot

标准快照：

```go
type StandardSnapshot struct {
    Header SnapshotHeaderV1  `json:"header"`
    State  VMState           `json:"state"`
    Meta   map[string]string `json:"meta,omitempty"`
}
```

Header：

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

新生成 snapshot JSON 中，`state.code`、`state.memory`、`state.call_data` 使用 `0x` hex 字符串。读取逻辑兼容旧版 Go 默认 base64 bytes JSON。

## 4. Checkpoint 切分

链下 checkpoint 按 Gas 阈值切分：

1. 维护当前窗口已用 Gas `windowGasUsed`。
2. 每步执行前调用 `PeekNextGasCost()`。
3. 如果窗口已有执行量，且 `windowGasUsed + nextGas > snapshotThresholdGas`，先保存当前状态为 checkpoint。
4. 保存后将 `windowGasUsed` 清零。
5. 执行下一条指令，并累计实际 Gas。
6. VM 停机后保存 final checkpoint。

这个规则保证相邻 checkpoint 的 Gas 差值不超过阈值，除 final checkpoint 的收尾语义外。

## 5. 当前支持的 Opcode

### 停止与算术

| Opcode | 名称 | 语义摘要 |
| --- | --- | --- |
| `0x00` | `STOP` | 停机 |
| `0x01` | `ADD` | `(b + a) mod 2^256` |
| `0x02` | `MUL` | `(b * a) mod 2^256` |
| `0x03` | `SUB` | `(b - a) mod 2^256` |
| `0x04` | `DIV` | 无符号除法，除 0 得 0 |
| `0x05` | `SDIV` | 有符号除法，除 0 得 0 |
| `0x06` | `MOD` | 无符号取模，模 0 得 0 |
| `0x07` | `SMOD` | 有符号取模，模 0 得 0 |
| `0x08` | `ADDMOD` | `(a + b) mod n`，`n == 0` 得 0 |
| `0x09` | `MULMOD` | `(a * b) mod n`，`n == 0` 得 0 |
| `0x0a` | `EXP` | 幂运算后按 `2^256` 取模 |
| `0x0b` | `SIGNEXTEND` | 符号扩展 |

### 比较与位运算

| Opcode | 名称 |
| --- | --- |
| `0x10` | `LT` |
| `0x11` | `GT` |
| `0x12` | `SLT` |
| `0x13` | `SGT` |
| `0x14` | `EQ` |
| `0x15` | `ISZERO` |
| `0x16` | `AND` |
| `0x17` | `OR` |
| `0x18` | `XOR` |
| `0x19` | `NOT` |
| `0x1a` | `BYTE` |
| `0x1b` | `SHL` |
| `0x1c` | `SHR` |
| `0x1d` | `SAR` |

### 内存、跳转和上下文

| Opcode | 名称 | 语义摘要 |
| --- | --- | --- |
| `0x50` | `POP` | 弹出栈顶 |
| `0x51` | `MLOAD` | 读取 32 字节 memory |
| `0x52` | `MSTORE` | 写入 32 字节 memory |
| `0x53` | `MSTORE8` | 写入 1 字节 memory |
| `0x56` | `JUMP` | 跳转到 `JUMPDEST` |
| `0x57` | `JUMPI` | 条件跳转到 `JUMPDEST` |
| `0x58` | `PC` | 压入当前 PC |
| `0x59` | `MSIZE` | 压入 memory size |
| `0x5a` | `GAS` | 压入当前剩余 Gas |
| `0x5b` | `JUMPDEST` | 有效跳转目标 |

### PUSH/DUP/SWAP

| 范围 | 名称 | Gas |
| --- | --- | --- |
| `0x60`-`0x7f` | `PUSH1`-`PUSH32` | 3 |
| `0x80`-`0x8f` | `DUP1`-`DUP16` | 3 |
| `0x90`-`0x9f` | `SWAP1`-`SWAP16` | 3 |

### 自定义扩展

| Opcode | 名称 | 说明 |
| --- | --- | --- |
| `0xfb` | `SAVE` | 自定义快照相关操作 |
| `0xfc` | `SNAPSHOT` | 自定义快照相关操作 |
| `0xfd` | `RESTORE` | 自定义恢复相关操作 |
| `0xfe` | `INVALID` | 非法操作 |

这些扩展不代表标准 EVM 语义，只服务本原型的快照实验。

## 6. 当前 Gas 表

| 类别 | Opcode | Gas |
| --- | --- | --- |
| 零成本 | `STOP`, `INVALID` | 0 |
| Quick | `PC`, `GAS`, `POP` | 2 |
| Fastest | `ADD`, `SUB`, 比较/位运算, `PUSH*`, `DUP*`, `SWAP*` | 3 |
| Fast | `MUL`, `DIV`, `SDIV`, `MOD`, `SMOD`, `SIGNEXTEND` | 5 |
| Mid | `ADDMOD`, `MULMOD` | 8 |
| EXP | `EXP` | `ExpGas + ExpByteGas * exponentByteLen` |
| Memory | `MLOAD`, `MSTORE`, `MSTORE8` | 3 + memory expansion |
| Memory size | `MSIZE` | 2 |
| Jump | `JUMP` | 8 |
| Conditional jump | `JUMPI` | 10 |
| Jump destination | `JUMPDEST` | `params.JumpdestGas` |
| Custom save | `SAVE` | 100 |
| Custom snapshot | `SNAPSHOT` | `20000 + stateSize * 10` |
| Custom restore | `RESTORE` | 5000 |

Gas 计算在执行前通过 `PeekNextGasCost()` 预估，用于 checkpoint 切分。指令执行后会扣除对应 Gas 并增加 step count。

## 7. 跳转规则

`JUMP` 和 `JUMPI` 目标必须是有效 `JUMPDEST`。跳转目标非法时执行失败。

`STOP` 和 `RESTORE` 保留指令实现设置的 PC；其他指令默认由 VM 推进 PC。

## 8. Proof Verification

`TransitionProof.Verify(initialState)` 会检查：

- initial state hash 等于 `InitialHash`。
- initial state code hash 等于 `CodeHash`。
- state 内 bytecode 与 code hash 一致。
- start/end step 区间合法。
- trace root 匹配 step proof。
- 每一步 opcode、PC、Gas、栈变化、内存读写和前后状态 hash。
- final state hash 等于 `FinalHash`。

## 9. 非目标

当前 PureVM 不支持完整 EVM 环境，包括但不限于：

- account/storage trie。
- CALL/CREATE/DELEGATECALL。
- LOG。
- BLOCKHASH、TIMESTAMP、CALLER 等链上下文 opcode。
- 预编译合约调用。
- 完整 EVM fork 兼容性。

PureVM 的目标是可审计、可快照、可重放的确定性计算内核。
