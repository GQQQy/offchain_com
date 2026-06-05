# 新会话接力 Prompt

你是 Codex，在仓库 `/Users/gqy/Desktop/data/DR/毕业/毕业答辩/实验室验收材料/offchain_com` 中继续工作。请先阅读根目录 `README.md`、`DESIGN_HANDOFF.md`、`purevm/README.md`、`VerCom/README.md`，再检查 `git status` 和最近提交。用户希望你“重新完整地把整个项目写好”，不是只修单个小问题。

项目目标：把链下确定性计算 `purevm` 与链上乐观验证合约 `VerCom` 做成一个自洽的端到端原型。链下执行生成 checkpoint、snapshot index 和 transition proof；链上登记 PureVM task、绑定 optimistic task 的 checkpoint claim，并在 challenge 时用 verifier 验证相邻 checkpoint segment 或二次细分后的最小争议段。

当前已完成的主要能力：

- `purevm/`: Go 版 256 位栈式 VM、Gas 权重 opcode 子集、`StandardSnapshot`、hex bytes JSON、snapshot index、transition proof、Go precompile 协议、第一分歧段定位和 `vmcli`。
- `VerCom/`: `PureVMTaskManager`、`PureVMVerifierAdapter`、`PureVMChallengeResolver`、`PureVMSnapshotStore`、`OptimisticTaskCoordinator`、`ValidatorManager`、Foundry 测试和脚本。
- 关键文档在 `DESIGN_HANDOFF.md`，其中写明了协议不变量、端到端流程、DA、二次细分争议、接口上限、测试覆盖和后续建议。

上一轮已验证：

- `git diff --check` 通过。
- `cd purevm && GOCACHE=$PWD/.gocache GOMODCACHE=$PWD/.gomodcache GOPATH=$PWD/.gopath GOSUMDB=sum.golang.org GOPROXY=https://proxy.golang.org go test -v -mod=mod ./...` 通过；长任务测试默认按环境变量跳过。
- `cd VerCom && forge test` 通过，20 passed / 0 failed。Foundry 可能提示无法写 `~/.foundry/cache/signatures`，这是权限 warning，不影响测试结果。

开始工作时请重点做：

1. 重新通读 `DESIGN_HANDOFF.md`，对照代码确认文档与实现一致。
2. 检查 `purevm` 和 `VerCom` 的端到端脚本是否能用真实长任务产物跑通，尤其是 `RunPureVMChallengeE2E.s.sol`。
3. 继续完善真实 artifact 生成、proof 文件生成、`.env.example`、脚本路径和 README 使用说明。
4. 增强测试：dispute game timeout、executor/challenger/both-wrong 裁决、真实尺寸 payload、resolver 授权和部署脚本路径。
5. 保持协议不变量：`checkpointTaskSummaryHash`、`checkpointClaimHash`、snapshot hash、proof final root、verified steps、trace root 和 payload 上限必须同步。
6. 不要把 `.pdf_deps/`、本地缓存、大型二进制资料或测试产物提交进 Git，除非用户明确要求。

网络如果不通，按仓库指令使用代理：

```bash
export https_proxy=http://127.0.0.1:33210
export http_proxy=http://127.0.0.1:33210
export all_proxy=socks5://127.0.0.1:33211
```

推荐第一步命令：

```bash
git status --short
git log --oneline -5
sed -n '1,220p' DESIGN_HANDOFF.md
cd purevm && GOCACHE=$PWD/.gocache GOMODCACHE=$PWD/.gomodcache GOPATH=$PWD/.gopath GOSUMDB=sum.golang.org GOPROXY=https://proxy.golang.org go test -v -mod=mod ./...
cd ../VerCom && forge test
```

请用“先检查、再实现、最后验证”的方式推进；遇到用户已有改动不要 revert，除非用户明确要求。
