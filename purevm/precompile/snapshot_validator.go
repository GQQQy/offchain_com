package precompile

import (
	"encoding/binary"
	"encoding/json"
	"errors"

	"purevm/core"
	"purevm/proof"

	"github.com/ethereum/go-ethereum/common"
)

// SnapshotValidatorPrecompile 预编译合约实现。
// 建议地址：0x000000000000000000000000000000000000000d
type SnapshotValidatorPrecompile struct{}

func (s *SnapshotValidatorPrecompile) RequiredGas(input []byte) uint64 {
	const baseGas = 5000
	if len(input) < 8 {
		return baseGas
	}

	_, proofBytes, err := decodeInput(input)
	if err != nil {
		return baseGas + uint64(len(input))*8
	}

	var p proof.TransitionProof
	if err := json.Unmarshal(proofBytes, &p); err != nil {
		return baseGas + uint64(len(input))*8
	}
	return baseGas + uint64(len(p.Steps))*1000
}

func (s *SnapshotValidatorPrecompile) Run(input []byte) ([]byte, error) {
	stateBytes, proofBytes, err := decodeInput(input)
	if err != nil {
		return nil, err
	}

	var initialState core.VMState
	if err := json.Unmarshal(stateBytes, &initialState); err != nil {
		return failure(), nil
	}

	var p proof.TransitionProof
	if err := json.Unmarshal(proofBytes, &p); err != nil {
		return failure(), nil
	}

	if err := p.Verify(&initialState); err != nil {
		return failure(), nil
	}

	return success(), nil
}

func decodeInput(input []byte) ([]byte, []byte, error) {
	if len(input) < 8 {
		return nil, nil, errors.New("input too short")
	}

	stateLen := binary.BigEndian.Uint32(input[:4])
	proofLen := binary.BigEndian.Uint32(input[4:8])
	totalLen := 8 + int(stateLen) + int(proofLen)
	if len(input) < totalLen {
		return nil, nil, errors.New("input payload truncated")
	}

	stateBytes := input[8 : 8+stateLen]
	proofBytes := input[8+stateLen : totalLen]
	return stateBytes, proofBytes, nil
}

func success() []byte {
	return common.BigToHash(common.Big1).Bytes()
}

func failure() []byte {
	return common.BigToHash(common.Big0).Bytes()
}

// VerifyInSolidity 用于链下模拟合约侧的完整验证流程。
func VerifyInSolidity(proofBytes []byte, initialStateBytes []byte) bool {
	var p proof.TransitionProof
	if err := json.Unmarshal(proofBytes, &p); err != nil {
		return false
	}

	var initialState core.VMState
	if err := json.Unmarshal(initialStateBytes, &initialState); err != nil {
		return false
	}

	return p.Verify(&initialState) == nil
}
