# 系统架构

`offchain_com` 采用“链下完整执行、链上最小验证”的架构。系统默认计算发生在链下，链上只保存承诺、裁决事实和经济状态。

## 总体分层

```text
计算层 purevm
  确定性 VM、Gas 尺度 checkpoint、snapshot index、transition proof、分歧定位

裁决层 VerCom / PureVMTaskManager
  PureVM task、checkpoint metadata、DA metadata、相邻验证、普通争议、二次细分争议

经济层 OptimisticTaskCoordinator / ValidatorManager
  用户任务、executor bond、validator stake、背书、挑战、reward/slash/refund
```

这个分层刻意保持窄接口：

- `purevm` 输出 snapshot bytes、proof bytes、checkpoint metadata 和 trace root。
- `PureVMVerifierAdapter` 只负责把 Solidity 输入编码给 verifier target，并校验返回的 root、steps、trace root。
- `PureVMChallengeResolver` 只负责把 optimistic challenge 映射到 PureVM checkpoint challenge。
- `OptimisticTaskCoordinator` 只根据 resolver 返回的 challenge 成败做经济结算。

## 模块职责

### `purevm/core`

VM 执行内核，负责：

- 256 位 word 和栈式执行模型。
- VM state 序列化和 canonical hash。
- opcode 实现与 Gas 计算。
- `StandardSnapshot` 创建、读取和完整性校验。
- `snapshot_index.json` 的生成和相邻 checkpoint 解析。

### `purevm/proof`

证明和争议定位层，负责：

- 生成 `TransitionProof`。
- 重放并验证每一步状态转移。
- 从起点 snapshot 推导下一个 checkpoint。
- 对比执行方和验证者的 `snapshot_index.json`，定位第一分歧 segment。

### `purevm/precompile`

Go 版 verifier/precompile 原型，负责：

- 解析 `[stateLen:4][proofLen:4][snapshotBytes][proofBytes]`。
- 校验 snapshot/proof payload 上限。
- 调用 proof verifier。
- 返回 `[valid][finalStateRoot][verifiedSteps][traceRoot]`。

### `VerCom/src/PureVMTaskManager.sol`

PureVM 事实层，负责：

- 创建 PureVM task。
- 登记初始 checkpoint。
- 验证并追加相邻 checkpoint。
- 记录普通 optimistic challenge 的 `DisputeMeta`。
- 登记 snapshot、proof、manifest、subdivision 的 DA 元数据。
- 处理 DA availability challenge。
- 创建和结算二次细分争议游戏。
- 管理 verifier 白名单和 challenge resolver 授权。

### `VerCom/src/PureVMVerifierAdapter.sol`

Verifier 边界层，负责：

- 限制 snapshot/proof payload 大小。
- 按 Go precompile 格式编码输入。
- 对 verifier target 执行 `staticcall`。
- 接受 128 字节或 160 字节返回。
- 校验 final root、verified steps 和可选 trace root。

### `VerCom/src/PureVMChallengeResolver.sol`

Optimistic challenge 到 PureVM 裁决的连接层，负责：

- 解码 challenge payload。
- 检查 optimistic task 的 `summaryHash` 是否绑定到 `(pureVMTaskId, fromOrdinal + 1)`。
- 调用 `PureVMTaskManager.resolveDispute(...)`。
- 返回 challenge 是否成功、actual result hash 和 actual state root。

### `VerCom/src/OptimisticTaskCoordinator.sol`

经济和任务生命周期层，负责：

- 发布普通 task 和 PureVM checkpoint-bound task。
- 管理 executor claim、result submit、validator selection、attestation、challenge、finalize、cancel。
- 保存 PureVM checkpoint binding。
- 要求 PureVM-bound result 提交 artifact manifest。
- 按任务创建时固定的 payout config 结算资金。

### `VerCom/src/ValidatorManager.sol`

验证者集合层，负责：

- validator stake。
- 退出延迟。
- stake 加权选择验证者。

### `VerCom/src/PureVMSnapshotStore.sol`

测试和演示用 bytes store，负责临时保存小型 snapshot bytes。它不是生产 DA 方案。

## 关键数据流

### 正常路径

```text
requester/executor 链下运行 purevm
-> 生成 checkpoint 和 artifact
-> requester 创建 PureVM task
-> requester 发布 checkpoint-bound optimistic task
-> executor 提交 checkpoint claim
-> validator 链下检查并背书
-> challenge window 结束
-> coordinator finalize 并分配 reward/bond
```

### 普通 challenge 路径

```text
validator 链下重放并定位分歧
-> 构造 ChallengePayload
-> coordinator.challengeResult(...)
-> resolver 校验 summaryHash 绑定
-> task manager 调 verifier 验证局部 segment
-> task manager 记录 DisputeMeta
-> coordinator 根据 actual result 与 executor claim 是否一致结算
```

### verified checkpoint 追加路径

```text
调用方准备 start snapshot + next checkpoint + proof
-> taskManager.verifyAndAppendCheckpoint(...)
-> 校验起点 snapshot hash 和 checkpoint progression
-> verifier 验证 transition proof
-> 写入 next checkpoint 和 DA metadata
-> latestVerifiedOrdinal 前进
```

### 二次细分争议路径

```text
createDisputeGame
-> 双方补足当前轮累计 stake
-> 双方提交相同 step/gas schedule 的 subdivision commitments
-> declareDivergence 找到第一分歧点
-> 如果区间仍大，进入下一轮
-> ReadyForFinal 后用最小段 proof 裁决
-> 结算 dispute game stake pool
```

## 设计边界

### `resolveDispute` 和 `verifyAndAppendCheckpoint` 不同

`resolveDispute(...)` 服务 optimistic challenge，记录裁决事实，不推进 verified checkpoint 序列。

`verifyAndAppendCheckpoint(...)` 服务 PureVM task 的链上 verified checkpoint 进度，验证通过后会更新 `latestVerifiedOrdinal`。

这两个入口验证的是同一类状态转移，但服务不同协议目标，不能混用。

### DA availability 和 proof validity 不同

DA metadata 回答“数据承诺是什么、在哪里、是否被标记可访问”。Verifier 回答“这份数据描述的状态转移是否真实”。

URI 可访问不等于 proof 正确；proof 正确也不等于所有审计材料长期可用。两者都需要维护。

### Verifier target 是信任边界

Solidity adapter 只检查 verifier target 的返回是否与当前上下文一致。它不会重新实现 PureVM 语义。生产环境必须使用可审计、稳定、版本明确的 verifier/precompile。

## 目录地图

```text
offchain_com/
  README.md
  docs/
  purevm/
    cmd/vmcli/
    core/
    proof/
    precompile/
    test/
  VerCom/
    src/
    src/interfaces/
    script/
    test/
```
