package proof

import (
	"fmt"

	"purevm/core"
)

// NextSnapshotResult 描述从某个快照恢复后，按阈值规则推导出的下一个快照。
type NextSnapshotResult struct {
	Snapshot      *core.StandardSnapshot
	Steps         uint64
	WindowGasUsed uint64
	IsFinal       bool
}

// PredictNextSnapshot 从起始快照恢复，并按“下一步若越阈值则先保存当前快照”的规则推导下一个快照。
func PredictNextSnapshot(startSnap *core.StandardSnapshot, thresholdGas uint64) (*NextSnapshotResult, error) {
	if err := startSnap.VerifyIntegrity(); err != nil {
		return nil, fmt.Errorf("start snapshot integrity check failed: %w", err)
	}
	if thresholdGas == 0 {
		return nil, fmt.Errorf("snapshot threshold gas must be greater than zero")
	}

	vm := core.NewVM(startSnap.State.Code, startSnap.State.Gas)
	vm.State = startSnap.State.Clone()
	vm.ChainID = startSnap.Header.ChainID

	windowGasUsed := uint64(0)
	for !vm.Halted {
		nextGas, err := vm.PeekNextGasCost()
		if err != nil {
			return nil, err
		}

		if windowGasUsed > 0 && windowGasUsed+nextGas > thresholdGas {
			return &NextSnapshotResult{
				Snapshot:      core.NewStandardSnapshot(vm.State, startSnap.Header.ChainID),
				Steps:         vm.State.StepCount - startSnap.Header.StepNumber,
				WindowGasUsed: windowGasUsed,
				IsFinal:       false,
			}, nil
		}

		if err := vm.Step(); err != nil {
			return nil, err
		}
		windowGasUsed += nextGas
	}

	return &NextSnapshotResult{
		Snapshot:      core.NewStandardSnapshot(vm.State, startSnap.Header.ChainID),
		Steps:         vm.State.StepCount - startSnap.Header.StepNumber,
		WindowGasUsed: windowGasUsed,
		IsFinal:       true,
	}, nil
}

// VerifyNextSnapshotHash 按阈值规则推导下一个快照，并比较其状态哈希是否与承诺快照一致。
func VerifyNextSnapshotHash(startSnap, committedNextSnap *core.StandardSnapshot, thresholdGas uint64) (*NextSnapshotResult, error) {
	if err := committedNextSnap.VerifyIntegrity(); err != nil {
		return nil, fmt.Errorf("committed snapshot integrity check failed: %w", err)
	}

	result, err := PredictNextSnapshot(startSnap, thresholdGas)
	if err != nil {
		return nil, err
	}

	if result.Snapshot.Header.StateRoot != committedNextSnap.Header.StateRoot {
		return nil, fmt.Errorf(
			"next snapshot hash mismatch: got %s want %s",
			result.Snapshot.Header.StateRoot.Hex(),
			committedNextSnap.Header.StateRoot.Hex(),
		)
	}

	return result, nil
}
