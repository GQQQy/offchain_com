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

	// 这条测试模拟一个“总 Gas = 5 * 参考块 Gas，上报阈值 = 1/5 * 参考块 Gas”的完整任务。
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
	windowGasUsed := uint64(0)

	// 预判下一步若会越过阈值，则先保存当前快照，再开始下一段累计。
	start := time.Now()
	for !vm.Halted {
		nextGas, err := vm.PeekNextGasCost()
		require.NoError(t, err)

		gasUsed := task.TotalGas - vm.State.Gas
		if windowGasUsed > 0 && windowGasUsed+nextGas > snapshotThresholdGas {
			path := filepath.Join(
				artifactDir,
				fmt.Sprintf("snapshot_%03d_step_%d_gas_%d.json", len(snapshotPaths), vm.State.StepCount, gasUsed),
			)
			snap := saveSnapshotAtGas(t, vm, gasUsed, snapshotThresholdGas, path)
			snapshotPaths = append(snapshotPaths, path)
			snapshotGasUsed = append(snapshotGasUsed, gasUsed)
			index.AddSnapshot(filepath.Base(path), snap, gasUsed)
			windowGasUsed = 0
		}

		require.NoError(t, vm.Step())
		windowGasUsed += nextGas
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

	// fullVerify 打开时，除了快照 hash 验证外，还会额外为相邻区间生成完整 proof。
	fullVerify := os.Getenv("PUREVM_GAS_SCALE_FULL_VERIFY") == "1"
	persistProofFiles := os.Getenv("PUREVM_KEEP_PROOFS") == "1" || fullVerify
	seq := core.SnapshotSequence{}
	firstSnap, err := core.ReadSnapshotFile(snapshotPaths[0])
	require.NoError(t, err)
	require.NoError(t, firstSnap.VerifyIntegrity())
	require.NoError(t, seq.AddSnapshot(firstSnap, nil))

	// 验证每一对相邻快照都满足：按同样阈值规则重放时，得到的下一个快照 hash 与承诺快照一致。
	for i := 1; i < len(snapshotPaths); i++ {
		startSnap, err := core.ReadSnapshotFile(snapshotPaths[i-1])
		require.NoError(t, err)
		endSnap, err := core.ReadSnapshotFile(snapshotPaths[i])
		require.NoError(t, err)
		require.NoError(t, startSnap.VerifyIntegrity())
		require.NoError(t, endSnap.VerifyIntegrity())

		nextResult, err := proof.VerifyNextSnapshotHash(startSnap, endSnap, snapshotThresholdGas)
		require.NoError(t, err)
		require.NoError(t, seq.AddSnapshot(endSnap, nil))

		deltaSteps := endSnap.Header.StepNumber - startSnap.Header.StepNumber
		require.Equal(t, deltaSteps, nextResult.Steps)
		require.LessOrEqual(t, snapshotGasUsed[i]-snapshotGasUsed[i-1], snapshotThresholdGas)

		if fullVerify {
			segmentVM := core.NewVM(startSnap.State.Code, startSnap.State.Gas)
			segmentVM.State = startSnap.State.Clone()
			transitionProof, err := proof.GenerateTransitionProof(segmentVM, deltaSteps)
			require.NoError(t, err)
			if persistProofFiles {
				proofPath := filepath.Join(
					artifactDir,
					fmt.Sprintf("proof_%03d_from_%d_steps_%d.json", i, startSnap.Header.StepNumber, deltaSteps),
				)
				require.NoError(t, transitionProof.WriteFile(proofPath))
				require.NoError(t, index.SetAdjacentProof(i-1, filepath.Base(proofPath), deltaSteps, true))
			}
		}

		t.Logf(
			"adjacent snapshot hash verification: startOrdinal=%d endOrdinal=%d steps=%d gasUsedDelta=%d final=%t",
			i-1,
			i,
			deltaSteps,
			snapshotGasUsed[i]-snapshotGasUsed[i-1],
			nextResult.IsFinal,
		)
	}
	require.NoError(t, index.WriteFile(indexPath))

	// 默认模式下只抽样验证首段 / 中段 / 末段，避免长任务测试过慢。
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

// buildGasWeightedTaskForThreshold 按给定总 Gas 和快照阈值生成一个倒计数循环任务。
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

// countdownIterationsForGasFloor 反推需要多少次循环才能达到目标 Gas。
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

// countdownGasForIterations 给出该倒计数循环的总 Gas 模型。
func countdownGasForIterations(iterations uint32) uint64 {
	return countdownSetupAndExitGas + uint64(iterations)*countdownLoopGas
}

// buildCountdownLoop 构造一个简单但可长时间运行的纯 EVM 风格循环任务。
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

// writeTaskArtifacts 把任务说明和字节码落到磁盘，方便链下/链上脚本复用。
func writeTaskArtifacts(t *testing.T, dir string, task gasWeightedTask) {
	t.Helper()

	manifestPath := filepath.Join(dir, "task_manifest.json")
	data, err := json.MarshalIndent(task, "", "  ")
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(manifestPath, data, 0o644))

	bytecodePath := filepath.Join(dir, "task_bytecode.hex")
	require.NoError(t, os.WriteFile(bytecodePath, []byte(task.BytecodeHex+"\n"), 0o644))
}

// saveSnapshotAtGas 按当前 VM 状态生成快照，并把 gas 信息写进 Meta。
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

// verifySnapshotIndexPair 模拟“从索引中选一个中间快照，然后按阈值规则推导下一个快照 hash”的恢复流程。
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

	_, _ = proofSteps, fullVerify
	result, err := proof.VerifyNextSnapshotHash(startSnap, endSnap, idx.SnapshotThresholdGas)
	if err != nil {
		return nil, err
	}

	vm := core.NewVM(startSnap.State.Code, startSnap.State.Gas)
	vm.State = startSnap.State.Clone()
	p, err := proof.GenerateTransitionProof(vm, result.Steps)
	if err != nil {
		return nil, err
	}
	return p, nil
}

// selectedOrdinals 默认挑首段 / 中段 / 末段做抽样验证。
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

// artifactDir 决定长任务测试的产物写到临时目录还是 testdata。
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
