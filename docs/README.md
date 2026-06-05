# offchain_com 文档索引

这个目录是 `offchain_com` 的项目手册集合。根目录 [`README.md`](../README.md) 保留完整设计交接和协议总览；这里的文档面向日常使用、部署、审计和二次开发。

## 阅读路径

第一次接触项目时，推荐按下面顺序阅读：

1. [`QUICKSTART.md`](./QUICKSTART.md): 环境准备、快速测试、生成 E2E artifact、运行 Foundry 测试。
2. [`ARCHITECTURE.md`](./ARCHITECTURE.md): PureVM、VerCom、resolver、coordinator 和 verifier 的模块边界。
3. [`PROTOCOL.md`](./PROTOCOL.md): task、checkpoint、proof、challenge、DA 和 dispute game 的协议细节。
4. [`ARTIFACTS.md`](./ARTIFACTS.md): `vmcli generate-artifacts` 产物目录、manifest 字段和链上脚本变量映射。
5. [`DEPLOYMENT_AND_OPERATIONS.md`](./DEPLOYMENT_AND_OPERATIONS.md): 部署、环境变量、脚本运行、监控和生产边界。
6. [`PUREVM_SEMANTICS.md`](./PUREVM_SEMANTICS.md): 当前 PureVM opcode 子集、Gas 规则、状态 hash 和快照语义。

## 文档职责

| 文档 | 适合读者 | 解决的问题 |
| --- | --- | --- |
| [`../README.md`](../README.md) | 研究、答辩、交接、审计 | 项目为什么这样设计、完整协议不变量是什么 |
| [`../purevm/README.md`](../purevm/README.md) | 链下执行开发者 | 如何运行 VM、生成 snapshot/proof、定位分歧 |
| [`../VerCom/README.md`](../VerCom/README.md) | 合约开发者 | 合约职责、任务生命周期、脚本和资金模型 |
| [`QUICKSTART.md`](./QUICKSTART.md) | 新接手开发者 | 如何在本地快速跑通测试和真实 artifact |
| [`ARCHITECTURE.md`](./ARCHITECTURE.md) | 系统设计读者 | 模块之间如何协作，哪些边界不能混淆 |
| [`PROTOCOL.md`](./PROTOCOL.md) | 协议实现和审计者 | hash 绑定、challenge、DA、dispute game 的约束 |
| [`ARTIFACTS.md`](./ARTIFACTS.md) | 脚本和运维人员 | 链下文件和链上参数如何对应 |
| [`DEPLOYMENT_AND_OPERATIONS.md`](./DEPLOYMENT_AND_OPERATIONS.md) | 部署和测试网运维 | 如何部署、填 `.env`、跑 E2E、处理常见故障 |
| [`PUREVM_SEMANTICS.md`](./PUREVM_SEMANTICS.md) | VM/Verifier 开发者 | 当前 VM 执行语义和 Gas 语义是什么 |

## 当前项目状态

项目当前是端到端原型，不是生产主网系统。已经具备：

- Go 版 PureVM 确定性执行、snapshot、proof、precompile 模拟和分歧定位。
- Solidity 版 task manager、optimistic coordinator、challenge resolver、verifier adapter、snapshot store 和 dispute game。
- Foundry 脚本和测试覆盖部署、checkpoint 追加、challenge、DA challenge、二次细分争议和文件驱动 E2E。

需要特别注意：

- `PureVMSnapshotStore` 只适合测试和小 payload 演示，生产部署应使用链下或专用 DA 层保存大文件。
- 当前 verifier target 是协议边界，真实部署必须替换为可审计、稳定、返回格式兼容的 verifier/precompile。
- 普通 optimistic challenge 的 `resolveDispute(...)` 只记录裁决事实，不自动推进 PureVM task 的 verified checkpoint 序列。
