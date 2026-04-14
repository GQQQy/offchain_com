package test

import (
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"purevm/core"
	"purevm/proof"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const (
	ethereumReferenceBlockGasLimit   uint64  = 60_000_000
	ethereumReferenceBlockTimeSecond float64 = 12.06

	snapshotThresholdGas uint64 = ethereumReferenceBlockGasLimit / 5
	targetTaskGasFloor   uint64 = ethereumReferenceBlockGasLimit * 5

	countdownSetupAndExitGas uint64 = 24
	countdownLoopGas         uint64 = 37
)

func TestFileBackedSnapshotsLongRun(t *testing.T) {
	if os.Getenv("PUREVM_GAS_SCALE_TEST") != "1" {
		t.Skip("set PUREVM_GAS_SCALE_TEST=1 to run the gas-weighted snapshot test")
	}

	task := buildGasWeightedTask()
	artifactDir := artifactDir(t)
	writeTaskArtifacts(t, artifactDir, task)
	indexPath := filepath.Join(artifactDir, "snapshot_index.json")
	index := core.NewSnapshotIndex(1337, task.TotalGas, snapshotThresholdGas)
	index.BytecodeHex = task.BytecodeHex
	index.Meta = map[string]string{
		"reference_block_time_seconds": fmt.Sprintf("%.2f", ethereumReferenceBlockTimeSecond),
		"equivalent_ethereum_seconds":  fmt.Sprintf("%.2f", task.EquivalentEthereumSeconds),
	}

	vm := core.NewVM(task.Code, task.TotalGas)
	vm.ChainID = 1337

	initialPath := filepath.Join(artifactDir, "snapshot_000_initial.json")
	initialSnap := core.NewStandardSnapshot(vm.State, vm.ChainID)
	initialSnap.Meta = map[string]string{
		"gas_used":      "0",
		"gas_threshold": fmt.Sprintf("%d", snapshotThresholdGas),
	}
	require.NoError(t, initialSnap.WriteFile(initialPath))
	index.AddSnapshot(filepath.Base(initialPath), initialSnap, 0)
	require.NoError(t, index.WriteFile(indexPath))

	snapshotPaths := []string{initialPath}
	snapshotGasUsed := []uint64{0}
	nextThreshold := snapshotThresholdGas

	start := time.Now()
	for !vm.Halted {
		require.NoError(t, vm.Step())

		gasUsed := task.TotalGas - vm.State.Gas
		for gasUsed >= nextThreshold && nextThreshold <= targetTaskGasFloor {
			path := filepath.Join(
				artifactDir,
				fmt.Sprintf("snapshot_%03d_step_%d_gas_%d.json", len(snapshotPaths), vm.State.StepCount, gasUsed),
			)
			snap := saveSnapshotAtGas(t, vm, gasUsed, nextThreshold, path)
			snapshotPaths = append(snapshotPaths, path)
			snapshotGasUsed = append(snapshotGasUsed, gasUsed)
			index.AddSnapshot(filepath.Base(path), snap, gasUsed)
			nextThreshold += snapshotThresholdGas
		}
	}
	runDuration := time.Since(start)

	finalGasUsed := task.TotalGas - vm.State.Gas
	finalPath := filepath.Join(
		artifactDir,
		fmt.Sprintf("snapshot_%03d_final_step_%d_gas_%d.json", len(snapshotPaths), vm.State.StepCount, finalGasUsed),
	)
	finalSnap := saveSnapshotAtGas(t, vm, finalGasUsed, 0, finalPath)
	snapshotPaths = append(snapshotPaths, finalPath)
	snapshotGasUsed = append(snapshotGasUsed, finalGasUsed)
	index.AddSnapshot(filepath.Base(finalPath), finalSnap, finalGasUsed)
	require.NoError(t, index.WriteFile(indexPath))

	t.Logf("generated task bytecode: 0x%s", hex.EncodeToString(task.Code))
	t.Logf(
		"gas-weighted run completed in %v, totalGas=%d, stepCount=%d, equivalentEthereumTime=%.2fs",
		runDuration,
		task.TotalGas,
		vm.State.StepCount,
		task.EquivalentEthereumSeconds,
	)
	for i, path := range snapshotPaths {
		t.Logf("snapshot[%d]: %s gasUsed=%d", i, path, snapshotGasUsed[i])
	}

	assert.GreaterOrEqual(t, task.TotalGas, targetTaskGasFloor)
	assert.GreaterOrEqual(t, len(snapshotPaths), int(targetTaskGasFloor/snapshotThresholdGas)+2)

	fullVerify := os.Getenv("PUREVM_GAS_SCALE_FULL_VERIFY") == "1"
	persistProofFiles := os.Getenv("PUREVM_KEEP_PROOFS") == "1" || fullVerify
	seq := core.SnapshotSequence{}
	firstSnap, err := core.ReadSnapshotFile(snapshotPaths[0])
	require.NoError(t, err)
	require.NoError(t, firstSnap.VerifyIntegrity())
	require.NoError(t, seq.AddSnapshot(firstSnap, nil))

	for i := 1; i < len(snapshotPaths); i++ {
		startSnap, err := core.ReadSnapshotFile(snapshotPaths[i-1])
		require.NoError(t, err)
		endSnap, err := core.ReadSnapshotFile(snapshotPaths[i])
		require.NoError(t, err)
		require.NoError(t, startSnap.VerifyIntegrity())
		require.NoError(t, endSnap.VerifyIntegrity())

		deltaSteps := endSnap.Header.StepNumber - startSnap.Header.StepNumber
		require.Greater(t, deltaSteps, uint64(0))
		if fullVerify {
			transitionProof, err := proof.VerifyAdjacentSnapshots(startSnap, endSnap, 0)
			require.NoError(t, err)

			if persistProofFiles {
				proofPath := filepath.Join(
					artifactDir,
					fmt.Sprintf("proof_%03d_from_%d_steps_%d.json", i, startSnap.Header.StepNumber, deltaSteps),
				)
				require.NoError(t, transitionProof.WriteFile(proofPath))
				require.NoError(t, index.SetAdjacentProof(i-1, filepath.Base(proofPath), deltaSteps, true))
			}

			assert.Equal(t, endSnap.Header.StateRoot, transitionProof.FinalHash)
			link := transitionProof.Link()
			require.NoError(t, seq.AddSnapshot(endSnap, &link))
			t.Logf(
				"adjacent snapshot verification: startOrdinal=%d endOrdinal=%d steps=%d gasUsedDelta=%d",
				i-1,
				i,
				deltaSteps,
				snapshotGasUsed[i]-snapshotGasUsed[i-1],
			)
		} else {
			require.NoError(t, seq.AddSnapshot(endSnap, nil))
		}
	}
	require.NoError(t, index.WriteFile(indexPath))

	for _, ordinal := range selectedOrdinals(len(index.Snapshots)) {
		verifiedProof, err := verifySnapshotIndexPair(indexPath, ordinal, 0, true)
		require.NoError(t, err)
		assert.NotNil(t, verifiedProof)
		t.Logf("index-selected recovery verification succeeded at ordinal=%d", ordinal)
	}

	assert.Equal(t, len(snapshotPaths), len(seq.Snapshots))
	if fullVerify {
		assert.Equal(t, len(snapshotPaths)-1, len(seq.Links))
	}
}

type gasWeightedTask struct {
	Code                      []byte  `json:"-"`
	BytecodeHex               string  `json:"bytecode_hex"`
	LoopIterations            uint32  `json:"loop_iterations"`
	TotalGas                  uint64  `json:"total_gas"`
	SnapshotThresholdGas      uint64  `json:"snapshot_threshold_gas"`
	ReferenceBlockGasLimit    uint64  `json:"reference_block_gas_limit"`
	ReferenceBlockTimeSeconds float64 `json:"reference_block_time_seconds"`
	EquivalentEthereumBlocks  float64 `json:"equivalent_ethereum_blocks"`
	EquivalentEthereumSeconds float64 `json:"equivalent_ethereum_seconds"`
	GasFormula                string  `json:"gas_formula"`
}

func buildGasWeightedTask() gasWeightedTask {
	return buildGasWeightedTaskForThreshold(targetTaskGasFloor, snapshotThresholdGas)
}

func buildGasWeightedTaskForThreshold(totalGasFloor, thresholdGas uint64) gasWeightedTask {
	iterations := countdownIterationsForGasFloor(totalGasFloor)
	totalGas := countdownGasForIterations(iterations)
	code := buildCountdownLoop(iterations)
	equivalentBlocks := float64(totalGas) / float64(ethereumReferenceBlockGasLimit)

	return gasWeightedTask{
		Code:                      code,
		BytecodeHex:               "0x" + hex.EncodeToString(code),
		LoopIterations:            iterations,
		TotalGas:                  totalGas,
		SnapshotThresholdGas:      thresholdGas,
		ReferenceBlockGasLimit:    ethereumReferenceBlockGasLimit,
		ReferenceBlockTimeSeconds: ethereumReferenceBlockTimeSecond,
		EquivalentEthereumBlocks:  equivalentBlocks,
		EquivalentEthereumSeconds: equivalentBlocks * ethereumReferenceBlockTimeSecond,
		GasFormula:                "totalGas = 24 + 37 * iterations",
	}
}

func countdownIterationsForGasFloor(gasFloor uint64) uint32 {
	if gasFloor <= countdownSetupAndExitGas {
		return 0
	}

	remaining := gasFloor - countdownSetupAndExitGas
	iterations := remaining / countdownLoopGas
	if remaining%countdownLoopGas != 0 {
		iterations++
	}
	return uint32(iterations)
}

func countdownGasForIterations(iterations uint32) uint64 {
	return countdownSetupAndExitGas + uint64(iterations)*countdownLoopGas
}

func buildCountdownLoop(iterations uint32) []byte {
	code := []byte{
		0x63, 0, 0, 0, 0,
		0x5b,
		0x80,
		0x15,
		0x60, 0x11,
		0x57,
		0x60, 0x01,
		0x03,
		0x60, 0x05,
		0x56,
		0x5b,
		0x00,
	}
	binary.BigEndian.PutUint32(code[1:5], iterations)
	return code
}

func writeTaskArtifacts(t *testing.T, dir string, task gasWeightedTask) {
	t.Helper()

	manifestPath := filepath.Join(dir, "task_manifest.json")
	data, err := json.MarshalIndent(task, "", "  ")
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(manifestPath, data, 0o644))

	bytecodePath := filepath.Join(dir, "task_bytecode.hex")
	require.NoError(t, os.WriteFile(bytecodePath, []byte(task.BytecodeHex+"\n"), 0o644))
}

func saveSnapshotAtGas(t *testing.T, vm *core.VM, gasUsed, threshold uint64, path string) *core.StandardSnapshot {
	t.Helper()

	snap := core.NewStandardSnapshot(vm.State, vm.ChainID)
	snap.Meta = map[string]string{
		"gas_used": fmt.Sprintf("%d", gasUsed),
	}
	if threshold > 0 {
		snap.Meta["gas_threshold"] = fmt.Sprintf("%d", threshold)
	}
	require.NoError(t, snap.WriteFile(path))
	return snap
}

func verifySnapshotIndexPair(indexPath string, ordinal int, proofSteps uint64, fullVerify bool) (*proof.TransitionProof, error) {
	idx, err := core.ReadSnapshotIndexFile(indexPath)
	if err != nil {
		return nil, err
	}

	startEntry, endEntry, err := idx.AdjacentEntries(ordinal)
	if err != nil {
		return nil, err
	}
	if err := idx.ValidateAdjacentThreshold(startEntry, endEntry); err != nil {
		return nil, err
	}

	startSnap, err := core.ReadSnapshotFile(idx.ResolvePath(indexPath, startEntry.SnapshotFile))
	if err != nil {
		return nil, err
	}
	endSnap, err := core.ReadSnapshotFile(idx.ResolvePath(indexPath, endEntry.SnapshotFile))
	if err != nil {
		return nil, err
	}

	if !fullVerify && startEntry.AdjacentProofSteps > 0 {
		proofSteps = startEntry.AdjacentProofSteps
	}

	return proof.VerifyAdjacentSnapshots(startSnap, endSnap, proofSteps)
}

func selectedOrdinals(snapshotCount int) []int {
	if snapshotCount < 2 {
		return nil
	}

	lastAdjacent := snapshotCount - 2
	candidates := []int{0, lastAdjacent / 2, lastAdjacent}
	seen := make(map[int]struct{})
	selected := make([]int, 0, len(candidates))
	for _, ordinal := range candidates {
		if ordinal < 0 || ordinal > lastAdjacent {
			continue
		}
		if _, ok := seen[ordinal]; ok {
			continue
		}
		seen[ordinal] = struct{}{}
		selected = append(selected, ordinal)
	}
	return selected
}

func artifactDir(t *testing.T) string {
	t.Helper()

	if os.Getenv("PUREVM_KEEP_FILES") != "1" {
		return t.TempDir()
	}

	root := filepath.Join("testdata", "long_run_artifacts")
	require.NoError(t, os.MkdirAll(root, 0o755))

	dir := filepath.Join(root, time.Now().Format("20060102_150405"))
	require.NoError(t, os.MkdirAll(dir, 0o755))
	t.Logf("preserving gas-weighted artifacts in %s", dir)
	return dir
}
