package proof

import (
	"fmt"

	"purevm/core"
)

// VerifyAdjacentSnapshots 从起始快照恢复，生成并验证到下一个快照的相邻区间证明。
// proofSteps=0 时验证整个相邻区间；否则只验证前 proofSteps 步。
func VerifyAdjacentSnapshots(startSnap, endSnap *core.StandardSnapshot, proofSteps uint64) (*TransitionProof, error) {
	if err := startSnap.VerifyIntegrity(); err != nil {
		return nil, fmt.Errorf("start snapshot integrity check failed: %w", err)
	}
	if err := endSnap.VerifyIntegrity(); err != nil {
		return nil, fmt.Errorf("end snapshot integrity check failed: %w", err)
	}

	if endSnap.Header.StepNumber <= startSnap.Header.StepNumber {
		return nil, fmt.Errorf(
			"invalid adjacent snapshots: start step %d, end step %d",
			startSnap.Header.StepNumber,
			endSnap.Header.StepNumber,
		)
	}

	deltaSteps := endSnap.Header.StepNumber - startSnap.Header.StepNumber
	if proofSteps == 0 || proofSteps > deltaSteps {
		proofSteps = deltaSteps
	}

	vm := core.NewVM(startSnap.State.Code, startSnap.State.Gas)
	vm.State = startSnap.State.Clone()

	p, err := GenerateTransitionProof(vm, proofSteps)
	if err != nil {
		return nil, err
	}
	if err := p.Verify(&startSnap.State); err != nil {
		return nil, err
	}

	if proofSteps == deltaSteps && p.FinalHash != endSnap.Header.StateRoot {
		return nil, fmt.Errorf(
			"adjacent snapshot final root mismatch: got %s want %s",
			p.FinalHash.Hex(),
			endSnap.Header.StateRoot.Hex(),
		)
	}

	return p, nil
}
