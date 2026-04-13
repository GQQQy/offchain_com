package proof

import (
	"encoding/json"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

func hashStep(step StepProof) []byte {
	data, _ := json.Marshal(step)
	return crypto.Keccak256(data)
}

// CalculateTraceRoot 计算执行轨迹步骤的Merkle根。
func CalculateTraceRoot(steps []StepProof) common.Hash {
	if len(steps) == 0 {
		return common.Hash{}
	}

	leaves := make([][]byte, len(steps))
	for i, step := range steps {
		leaves[i] = hashStep(step)
	}

	for len(leaves) > 1 {
		next := make([][]byte, (len(leaves)+1)/2)
		for i := 0; i < len(leaves); i += 2 {
			if i+1 < len(leaves) {
				next[i/2] = crypto.Keccak256(append(leaves[i], leaves[i+1]...))
				continue
			}
			next[i/2] = leaves[i]
		}
		leaves = next
	}

	return common.BytesToHash(leaves[0])
}
