package proof

import (
	"encoding/json"
	"os"
)

// WriteFile 将证明按缩进JSON写入本地文件。
func (p *TransitionProof) WriteFile(path string) error {
	data, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}

// ReadTransitionProofFile 从本地文件读取状态转移证明。
func ReadTransitionProofFile(path string) (*TransitionProof, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	var p TransitionProof
	if err := json.Unmarshal(data, &p); err != nil {
		return nil, err
	}
	return &p, nil
}
