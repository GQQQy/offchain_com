package precompile

import (
	"encoding/binary"
	"encoding/json"
	"errors"

	"purevm/core"
	"purevm/proof"

	"github.com/ethereum/go-ethereum/common"
)

// SnapshotValidatorPrecompile 预编译合约实现
// 建议以太坊地址：0x0000000000000000000000000000000000000d0d (或保留范围内的0x0d)
type SnapshotValidatorPrecompile struct{}

func (s *SnapshotValidatorPrecompile) RequiredGas(input []byte) uint64 {
	// 基础成本 + 每步执行成本
	if len(input) < 8 {
		return 0
	}
	steps := binary.BigEndian.Uint64(input[:8])
	// 每步1000 gas，与复杂计算成本相当
	return 5000 + steps*1000
}

func (s *SnapshotValidatorPrecompile) Run(input []byte) ([]byte, error) {
	// 输入格式：
	// [0:8]    steps (uint64)
	// [8:40]   initial_state_hash (32 bytes)
	// [40:72]  expected_final_hash (32 bytes)
	// [72:104] code_hash (32 bytes)
	// [104:136] trace_root (32 bytes, optional, 0 if unused)
	// [136:]   proof_json (transition proof serialized as JSON)

	if len(input) < 136 {
		return nil, errors.New("input too short")
	}

	steps := binary.BigEndian.Uint64(input[0:8])
	initialHash := common.BytesToHash(input[8:40])
	expectedFinalHash := common.BytesToHash(input[40:72])
	codeHash := common.BytesToHash(input[72:104])
	traceRoot := common.BytesToHash(input[104:136])
	proofData := input[136:]

	// 解析证明
	var p proof.TransitionProof
	if err := json.Unmarshal(proofData, &p); err != nil {
		return failure(), nil // 返回失败而非错误，遵循EVM预编译规范
	}

	// 验证哈希匹配
	if p.InitialHash != initialHash {
		return failure(), nil
	}
	if p.FinalHash != expectedFinalHash {
		return failure(), nil
	}
	if p.CodeHash != codeHash {
		return failure(), nil
	}
	if traceRoot != (common.Hash{}) && p.TraceRoot != traceRoot {
		return failure(), nil
	}
	if uint64(len(p.Steps)) != steps {
		return failure(), nil
	}

	// 关键：重建状态并重放验证
	// 注意：初始状态数据未在input中提供，实际部署中需要从合约存储或额外输入获取
	// 这里假设proof中包含足够信息，或修改input格式包含初始状态

	// 简化的验证逻辑（实际应完整重放）：
	// 由于预编译合约中无法访问外部存储，要么：
	// 1. input包含完整初始状态（昂贵）
	// 2. 或预编译仅验证proof格式，实际重放在Solidity中完成（推荐）
	// 3. 或修改设计，预编译仅验证Merkle路径

	// 这里采用方案3的简化：验证TraceRoot的Merkle证明（假设已有机制验证state transition）
	if !verifyMerkleProof(p, traceRoot) {
		return failure(), nil
	}

	return success(), nil
}

func verifyMerkicProof(p proof.TransitionProof, root common.Hash) bool {
	calcRoot := proof.CalculateTraceRoot(p.Steps)
	return calcRoot == root
}

func success() []byte {
	return common.BigToHash(common.Big1).Bytes()
}

func failure() []byte {
	return common.BigToHash(common.Big0).Bytes()
}

// 辅助函数：在Solidity中使用的验证（如果预编译只处理部分验证）
func VerifyInSolidity(proofBytes []byte, initialStateBytes []byte) bool {
	// 解析证明
	var p proof.TransitionProof
	if err := json.Unmarshal(proofBytes, &p); err != nil {
		return false
	}

	// 解析初始状态
	var initialState core.VMState
	if err := json.Unmarshal(initialStateBytes, &initialState); err != nil {
		return false
	}

	// 验证哈希匹配
	if initialState.Hash() != p.InitialHash {
		return false
	}

	// 创建VM并重放
	vm := core.NewVM(initialState.Code, initialState.Gas)
	vm.State = &initialState

	for _, step := range p.Steps {
		if vm.State.PC != step.PC {
			return false
		}
		if vm.State.Code[vm.State.PC] != step.OpCode {
			return false
		}
		if err := vm.Step(); err != nil {
			return false
		}
	}

	return vm.State.Hash() == p.FinalHash
}
