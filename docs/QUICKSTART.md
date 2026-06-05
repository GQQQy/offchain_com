# 快速启动

本文档用于把 `offchain_com` 在本地跑起来，并生成一套可以被 VerCom 脚本读取的真实 PureVM artifact。

## 1. 环境要求

需要安装：

- Go 1.22 或兼容版本。
- Foundry，包含 `forge` 和 `cast`。
- Git。

项目版本约束：

| 组件 | 版本/配置 |
| --- | --- |
| Go module | `go 1.22.0` |
| Solidity | `0.8.19` |
| Foundry optimizer | enabled, `optimizer_runs = 200`, `via_ir = true` |

如果本机网络访问模块代理不稳定，可在运行 Go 或 Forge 相关命令前设置代理：

```bash
export https_proxy=http://127.0.0.1:33210
export http_proxy=http://127.0.0.1:33210
export all_proxy=socks5://127.0.0.1:33211
```

## 2. 克隆和检查

```bash
git clone git@github.com:GQQQy/offchain_com.git
cd offchain_com
git status --short --branch
```

仓库主体：

```text
purevm/   # Go 链下确定性执行、snapshot、proof、precompile 模拟
VerCom/   # Foundry/Solidity 链上任务、验证、挑战、结算
docs/     # 项目手册
```

## 3. 运行 PureVM 测试

常规方式：

```bash
cd purevm
go test ./...
```

如果希望所有 Go 缓存都留在项目目录，使用：

```bash
cd purevm
GOCACHE="$PWD/.gocache" \
GOMODCACHE="$PWD/.gomodcache" \
GOPATH="$PWD/.gopath" \
GOSUMDB=sum.golang.org \
GOPROXY=https://proxy.golang.org \
go test -v -mod=mod ./...
```

这些缓存目录已被 `.gitignore` 忽略。

## 4. 运行 VerCom 测试

```bash
cd VerCom
forge test
```

`VerCom/foundry.toml` 已允许 Foundry 读取：

```text
../purevm/test/testdata
./testdata
```

默认 `forge test` 不要求本地 E2E artifact 存在。文件驱动 E2E 测试需要单独开启，见第 6 节。

## 5. 生成真实 E2E Artifact

在 `purevm` 下运行：

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

生成目录包含：

- `task_manifest.json`
- `task_bytecode.hex`
- `snapshot_index.json`
- `snapshot_*.json`
- `proof_*.json`

验证首段 proof：

```bash
go run ./cmd/vmcli \
  -cmd verify-precompile \
  -snap test/testdata/e2e_artifacts/current/snapshot_000_initial.json \
  -proof test/testdata/e2e_artifacts/current/proof_001_from_0_steps_122.json
```

如果看到 `Precompile verification PASSED`，说明 snapshot、proof 和 Go precompile 输入输出协议可以对上。

## 6. 运行文件驱动 E2E 脚本测试

先完成第 5 节生成 artifact，然后在 `VerCom` 目录运行：

```bash
cd VerCom
PUREVM_E2E_SCRIPT_TEST=1 \
PUREVM_ARTIFACT_DIR=../purevm/test/testdata/e2e_artifacts/current \
forge test --match-contract RunPureVMChallengeE2EScriptTest
```

该测试会读取真实文件，并验证脚本能串起：

```text
PureVM task 创建
-> PureVM checkpoint-bound optimistic task 发布
-> validator stake
-> executor claim
-> executor 提交错误 checkpoint claim
-> validator challenge
-> resolver / task manager / verifier adapter 裁决
```

## 7. 常用 CLI 命令

运行 bytecode：

```bash
cd purevm
go run ./cmd/vmcli -cmd run -code 600160020100 -gas 100000
```

生成 snapshot：

```bash
go run ./cmd/vmcli \
  -cmd snapshot \
  -code 600160020100 \
  -gas 100000 \
  -steps 1 \
  -snap /tmp/snapshot_step1.json
```

生成 proof：

```bash
go run ./cmd/vmcli \
  -cmd prove \
  -code 600160020100 \
  -gas 100000 \
  -steps 2 \
  -proof /tmp/proof.json
```

从 snapshot 恢复并生成 proof：

```bash
go run ./cmd/vmcli \
  -cmd prove-snapshot \
  -snap /tmp/snapshot_step1.json \
  -steps 2 \
  -proof /tmp/proof_from_snapshot.json
```

定位执行方和验证者 checkpoint 序列的第一分歧段：

```bash
go run ./cmd/vmcli \
  -cmd locate-dispute \
  -claimed-index executor_snapshot_index.json \
  -verified-index validator_snapshot_index.json
```

## 8. 本地文件和 Git 注意事项

已忽略的本地产物：

- `purevm/.gocache/`
- `purevm/.gomodcache/`
- `purevm/.gopath/`
- `purevm/test/testdata/e2e_artifacts/`
- `purevm/test/testdata/long_run_artifacts/`
- `VerCom/cache/`
- `VerCom/out/`
- `VerCom/broadcast/`

这些目录可以安全用于本地测试，不应提交。
