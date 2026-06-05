package precompile

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"

	"purevm/core"
	"purevm/proof"

	"github.com/ethereum/go-ethereum/common"
)

// SnapshotValidatorPrecompile 预编译合约实现。
// 建议地址：0x000000000000000000000000000000000000000d
type SnapshotValidatorPrecompile struct{}

const (
	MaxSnapshotBytes = 262_144
	MaxProofBytes    = 1_048_576
)

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

	initialState, err := decodeInitialState(stateBytes)
	if err != nil {
		return failure(), nil
	}

	var p proof.TransitionProof
	if err := json.Unmarshal(proofBytes, &p); err != nil {
		return failure(), nil
	}

	if err := p.Verify(initialState); err != nil {
		return failure(), nil
	}

	return encodeResult(true, p.FinalHash, p.EndStep-p.StartStep, p.TraceRoot), nil
}

func decodeInput(input []byte) ([]byte, []byte, error) {
	if len(input) < 8 {
		return nil, nil, errors.New("input too short")
	}

	stateLen := binary.BigEndian.Uint32(input[:4])
	proofLen := binary.BigEndian.Uint32(input[4:8])
	if stateLen > MaxSnapshotBytes {
		return nil, nil, fmt.Errorf("snapshot payload too large: %d > %d", stateLen, MaxSnapshotBytes)
	}
	if proofLen > MaxProofBytes {
		return nil, nil, fmt.Errorf("proof payload too large: %d > %d", proofLen, MaxProofBytes)
	}

	totalLen := 8 + int(stateLen) + int(proofLen)
	if len(input) < totalLen {
		return nil, nil, errors.New("input payload truncated")
	}
	if len(input) != totalLen {
		return nil, nil, errors.New("input payload has trailing bytes")
	}

	stateBytes := input[8 : 8+stateLen]
	proofBytes := input[8+stateLen : totalLen]
	return stateBytes, proofBytes, nil
}

func decodeInitialState(stateBytes []byte) (*core.VMState, error) {
	var envelope struct {
		Header json.RawMessage `json:"header"`
		State  json.RawMessage `json:"state"`
	}
	if err := json.Unmarshal(stateBytes, &envelope); err != nil {
		return nil, err
	}

	if len(envelope.Header) > 0 && len(envelope.State) > 0 && string(envelope.State) != "null" {
		var snap core.StandardSnapshot
		if err := json.Unmarshal(stateBytes, &snap); err != nil {
			return nil, err
		}
		if err := snap.VerifyIntegrity(); err != nil {
			return nil, err
		}
		return snap.State.Clone(), nil
	}

	var initialState core.VMState
	if err := json.Unmarshal(stateBytes, &initialState); err != nil {
		return nil, err
	}
	if err := initialState.VerifyCodeHash(); err != nil {
		return nil, err
	}
	return initialState.Clone(), nil
}

func failure() []byte {
	return encodeResult(false, common.Hash{}, 0, common.Hash{})
}

func encodeResult(valid bool, finalStateRoot common.Hash, verifiedSteps uint64, traceRoot common.Hash) []byte {
	out := make([]byte, 0, 128)
	if valid {
		out = append(out, common.BigToHash(common.Big1).Bytes()...)
	} else {
		out = append(out, common.BigToHash(big.NewInt(0)).Bytes()...)
	}
	out = append(out, finalStateRoot.Bytes()...)
	out = append(out, common.BigToHash(new(big.Int).SetUint64(verifiedSteps)).Bytes()...)
	out = append(out, traceRoot.Bytes()...)
	return out
}

// VerifyInSolidity 用于链下模拟合约侧的完整验证流程。
func VerifyInSolidity(proofBytes []byte, initialStateBytes []byte) bool {
	var p proof.TransitionProof
	if err := json.Unmarshal(proofBytes, &p); err != nil {
		return false
	}

	initialState, err := decodeInitialState(initialStateBytes)
	if err != nil {
		return false
	}

	return p.Verify(initialState) == nil
}
