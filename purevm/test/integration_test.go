package test

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"path/filepath"
	"testing"

	"purevm/core"
	"purevm/precompile"
	"purevm/proof"

	"github.com/ethereum/go-ethereum/common"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestArithmeticWithSnapshot 验证最基础的“执行 -> 生成快照 -> 快照序列化”闭环。
func TestArithmeticWithSnapshot(t *testing.T) {
	// 代码：PUSH1 5, PUSH1 3, ADD, PUSH1 2, MUL (结果：(5+3)*2 = 16)
	code := []byte{
		0x60, 0x05, // PUSH1 5
		0x60, 0x03, // PUSH1 3
		0x01,       // ADD (8)
		0x60, 0x02, // PUSH1 2
		0x02, // MUL (16)
		0x00, // STOP
	}

	// 执行
	vm := core.NewVM(code, 100000)
	err := vm.Run()
	assert.NoError(t, err)

	// 验证结果
	assert.Equal(t, 1, vm.State.GetStackDepth())
	assert.Equal(t, uint64(16), vm.State.Stack[0].Uint64())

	// 创建快照
	snap := core.NewStandardSnapshot(vm.State, 1337)
	assert.NoError(t, snap.VerifyIntegrity())

	// 序列化/反序列化测试
	data, _ := json.Marshal(snap)
	var snap2 core.StandardSnapshot
	json.Unmarshal(data, &snap2)
	assert.Equal(t, snap.Header.StateRoot, snap2.Header.StateRoot)
}

// TestSnapshotJSONUsesHexBytes 确认快照 JSON 中的 bytes 字段是 Foundry 可直接 parseJsonBytes 的 0x hex。
func TestSnapshotJSONUsesHexBytes(t *testing.T) {
	state := core.NewState([]byte{0x60, 0x01, 0x00}, 100000)
	state.Memory = []byte{0xab, 0xcd}
	snap := core.NewStandardSnapshot(state, 1337)

	data, err := json.Marshal(snap)
	assert.NoError(t, err)

	var raw map[string]any
	assert.NoError(t, json.Unmarshal(data, &raw))
	stateRaw := raw["state"].(map[string]any)
	assert.Equal(t, "0x600100", stateRaw["code"])
	assert.Equal(t, "0xabcd", stateRaw["memory"])

	var decoded core.StandardSnapshot
	assert.NoError(t, json.Unmarshal(data, &decoded))
	assert.Equal(t, snap.State.Code, decoded.State.Code)
	assert.Equal(t, snap.State.Memory, decoded.State.Memory)
	assert.NoError(t, decoded.VerifyIntegrity())
}

// TestSnapshotIntegrityRejectsCodeTamper 验证快照恢复会检查实际 code 和 code_hash 的绑定。
func TestSnapshotIntegrityRejectsCodeTamper(t *testing.T) {
	state := core.NewState([]byte{0x60, 0x01, 0x00}, 100000)
	snap := core.NewStandardSnapshot(state, 1337)
	assert.NoError(t, snap.VerifyIntegrity())

	snap.State.Code[1] = 0x02
	assert.Error(t, snap.VerifyIntegrity())
}

// TestPrecompileAcceptsFullSnapshot 验证本地预编译路径可以直接接收完整 StandardSnapshot JSON。
func TestPrecompileAcceptsFullSnapshot(t *testing.T) {
	code := []byte{0x60, 0x01, 0x60, 0x02, 0x01, 0x00}
	vm := core.NewVM(code, 100000)
	snap := core.NewStandardSnapshot(vm.State, 1337)

	p, err := proof.GenerateTransitionProof(vm, 3)
	assert.NoError(t, err)
	assert.NoError(t, p.Verify(&snap.State))

	snapshotBytes, err := json.Marshal(snap)
	assert.NoError(t, err)
	proofBytes, err := json.Marshal(p)
	assert.NoError(t, err)

	input := make([]byte, 8, 8+len(snapshotBytes)+len(proofBytes))
	binary.BigEndian.PutUint32(input[:4], uint32(len(snapshotBytes)))
	binary.BigEndian.PutUint32(input[4:8], uint32(len(proofBytes)))
	input = append(input, snapshotBytes...)
	input = append(input, proofBytes...)

	validator := precompile.SnapshotValidatorPrecompile{}
	out, err := validator.Run(input)
	assert.NoError(t, err)
	assert.Len(t, out, 128)
	assert.Equal(t, byte(1), out[31])
	assert.Equal(t, p.FinalHash, common.BytesToHash(out[32:64]))
	assert.Equal(t, uint64(3), binary.BigEndian.Uint64(out[88:96]))
	assert.Equal(t, p.TraceRoot, common.BytesToHash(out[96:128]))
}

// TestPrecompileRejectsOversizedPayloads 验证本地预编译和合约 adapter 使用相同的输入上限。
func TestPrecompileRejectsOversizedPayloads(t *testing.T) {
	validator := precompile.SnapshotValidatorPrecompile{}

	input := make([]byte, 8)
	binary.BigEndian.PutUint32(input[:4], uint32(precompile.MaxSnapshotBytes+1))
	binary.BigEndian.PutUint32(input[4:8], 0)
	_, err := validator.Run(input)
	assert.Error(t, err)

	input = make([]byte, 8)
	binary.BigEndian.PutUint32(input[:4], 0)
	binary.BigEndian.PutUint32(input[4:8], uint32(precompile.MaxProofBytes+1))
	_, err = validator.Run(input)
	assert.Error(t, err)
}

// TestTransitionProof 验证短区间状态转移证明能生成且能被重放验证。
func TestTransitionProof(t *testing.T) {
	// 斐波那契计算代码
	code := []byte{
		0x60, 0x01, // PUSH1 1 (a)
		0x60, 0x01, // PUSH1 1 (b)
		// 循环开始 (简化为线性执行)
		0x80, // DUP1 (复制b)
		0x81, // DUP2 (复制a)
		0x01, // ADD (a+b)
		// 栈现在: [b, new_a]
		0x00, // STOP
	}

	vm := core.NewVM(code, 100000)

	// 生成执行4步的证明
	p, err := proof.GenerateTransitionProof(vm, 4)
	assert.NoError(t, err)

	// 验证证明
	vm2 := core.NewVM(code, 100000)
	err = p.Verify(vm2.State)
	assert.NoError(t, err)
	assert.NotZero(t, p.TraceRoot)
}

// TestGasConsistency 检查基础指令的 Gas 计费是否和当前 gas table 一致。
func TestGasConsistency(t *testing.T) {
	code := []byte{0x60, 0x01, 0x60, 0x02, 0x01} // PUSH1 1, PUSH1 2, ADD
	vm := core.NewVM(code, 100000)

	initialGas := vm.State.Gas
	err := vm.Run()
	assert.NoError(t, err)

	// PUSH1 = 3 gas * 2 = 6
	// ADD = 3 gas
	// STOP = 0 gas
	expectedUsed := uint64(9)
	actualUsed := initialGas - vm.State.Gas
	assert.Equal(t, expectedUsed, actualUsed)
}

// TestMemoryExpansion 验证内存扩展大小和内存相关 Gas 计算。
func TestMemoryExpansion(t *testing.T) {
	// 代码：PUSH1 0x40 (64), MSTORE (写入64-95字节，扩展到96字节)
	code := []byte{
		0x60, 0x00, // PUSH1 0 (value)
		0x60, 0x40, // PUSH1 64 (offset)
		0x52, // MSTORE
		0x00, // STOP
	}

	vm := core.NewVM(code, 100000)
	err := vm.Run()
	assert.NoError(t, err)

	// 验证内存大小（64+32=96字节）
	assert.Equal(t, 96, len(vm.State.Memory))

	// 验证Gas消耗：2*PUSH(3) + MSTORE基础(3) + 内存扩展成本
	// 内存扩展：从0到96字节（3 words），成本 = 3*3 + (9-0) = 9 + 9 = 18?
	// 实际公式：(words^2)/512 + 3*words = (3^2)/512 + 9 = 0 + 9 = 9
	// 加上基础MSTORE 3 = 12，加上两个PUSH 6 = 18
	assert.Equal(t, uint64(18), 100000-vm.State.Gas)
}

// TestSnapshotSequence 验证快照序列能够按 step 单调递增地拼接。
func TestSnapshotSequence(t *testing.T) {
	seq := core.SnapshotSequence{}

	// 模拟执行并添加检查点
	code := []byte{0x60, 0x01, 0x60, 0x02, 0x01, 0x00} // PUSH1 1, PUSH1 2, ADD, STOP
	vm := core.NewVM(code, 100000)

	// 初始快照
	snap0 := core.NewStandardSnapshot(vm.State, 1337)
	seq.AddSnapshot(snap0, nil)

	// 执行2步后
	vm.RunSteps(2)
	snap1 := core.NewStandardSnapshot(vm.State, 1337)
	proof1, _ := proof.GenerateTransitionProof(core.NewVM(code, 100000), 2)
	link := proof1.Link()
	seq.AddSnapshot(snap1, &link)

	// 验证序列
	assert.Equal(t, 2, len(seq.Snapshots))
	assert.Equal(t, uint64(0), seq.Snapshots[0].Header.StepNumber)
	assert.Equal(t, uint64(2), seq.Snapshots[1].Header.StepNumber)
}

// TestSnapshotIndexAdjacentRecovery 用一个小号 Gas 任务构造索引，
// 然后逐个验证相邻快照能否通过索引恢复并重放到下一个快照。
func TestSnapshotIndexAdjacentRecovery(t *testing.T) {
	const (
		chainID        = 1337
		thresholdGas   = uint64(500)
		targetTotalGas = uint64(2500)
	)

	// 生成一个小号的 Gas 尺度任务，便于在单元测试里完整跑完。
	task := buildGasWeightedTaskForThreshold(targetTotalGas, thresholdGas)
	dir := t.TempDir()
	indexPath := filepath.Join(dir, "snapshot_index.json")

	vm := core.NewVM(task.Code, task.TotalGas)
	vm.ChainID = chainID

	index := core.NewSnapshotIndex(chainID, task.TotalGas, thresholdGas)
	index.BytecodeHex = task.BytecodeHex

	initialPath := filepath.Join(dir, "snapshot_000_initial.json")
	initialSnap := core.NewStandardSnapshot(vm.State, chainID)
	assert.NoError(t, initialSnap.WriteFile(initialPath))
	index.AddSnapshot(filepath.Base(initialPath), initialSnap, 0)

	snapPaths := []string{initialPath}
	windowGasUsed := uint64(0)
	// 模拟长任务里的阈值切分快照过程，只是把规模缩小到测试友好的量级。
	for !vm.Halted {
		nextGas, err := vm.PeekNextGasCost()
		assert.NoError(t, err)

		gasUsed := task.TotalGas - vm.State.Gas
		if windowGasUsed > 0 && windowGasUsed+nextGas > thresholdGas {
			path := filepath.Join(dir, fmt.Sprintf("snapshot_%03d.json", len(snapPaths)))
			snap := saveSnapshotAtGas(t, vm, gasUsed, thresholdGas, path)
			snapPaths = append(snapPaths, path)
			index.AddSnapshot(filepath.Base(path), snap, gasUsed)
			windowGasUsed = 0
		}

		err = vm.Step()
		assert.NoError(t, err)
		windowGasUsed += nextGas
	}

	finalPath := filepath.Join(dir, "snapshot_final.json")
	finalSnap := saveSnapshotAtGas(t, vm, task.TotalGas-vm.State.Gas, 0, finalPath)
	snapPaths = append(snapPaths, finalPath)
	index.AddSnapshot(filepath.Base(finalPath), finalSnap, task.TotalGas-vm.State.Gas)

	// 对索引里的每一对相邻快照执行“按阈值推导下一个快照 hash”的验证，并登记 proof 文件元数据。
	for ordinal := 0; ordinal < len(index.Snapshots)-1; ordinal++ {
		startEntry, endEntry, err := index.AdjacentEntries(ordinal)
		assert.NoError(t, err)

		startSnap, err := core.ReadSnapshotFile(index.ResolvePath(indexPath, startEntry.SnapshotFile))
		assert.NoError(t, err)
		endSnap, err := core.ReadSnapshotFile(index.ResolvePath(indexPath, endEntry.SnapshotFile))
		assert.NoError(t, err)

		result, err := proof.VerifyNextSnapshotHash(startSnap, endSnap, thresholdGas)
		assert.NoError(t, err)
		if err != nil {
			return
		}
		assert.Equal(t, endSnap.Header.StateRoot, result.Snapshot.Header.StateRoot)

		segmentVM := core.NewVM(startSnap.State.Code, startSnap.State.Gas)
		segmentVM.State = startSnap.State.Clone()
		p, err := proof.GenerateTransitionProof(segmentVM, result.Steps)
		assert.NoError(t, err)

		proofPath := filepath.Join(dir, fmt.Sprintf("proof_%03d.json", ordinal))
		assert.NoError(t, p.WriteFile(proofPath))
		assert.NoError(t, index.SetAdjacentProof(ordinal, filepath.Base(proofPath), uint64(len(p.Steps)), true))
	}

	assert.NoError(t, index.WriteFile(indexPath))

	// 再随机挑一个中间 ordinal，证明“按索引恢复并验证”这条路径也是通的。
	selectedOrdinal := len(index.Snapshots) / 2
	p, err := verifySnapshotIndexPair(indexPath, selectedOrdinal, 0, true)
	assert.NoError(t, err)
	assert.NotNil(t, p)
}

// TestSnapshotIndexThresholdValidation 只验证阈值规则本身：
// 相邻快照必须跨过下一档 snapshotThresholdGas。
func TestSnapshotIndexThresholdValidation(t *testing.T) {
	idx := core.NewSnapshotIndex(1337, 3000, 500)
	idx.Snapshots = []core.SnapshotIndexEntry{
		{Ordinal: 0, StepNumber: 0, GasUsed: 0},
		{Ordinal: 1, StepNumber: 10, GasUsed: 498},
		{Ordinal: 2, StepNumber: 20, GasUsed: 996},
	}

	err := idx.ValidateAdjacentThreshold(&idx.Snapshots[0], &idx.Snapshots[1])
	assert.NoError(t, err)

	err = idx.ValidateAdjacentThreshold(&idx.Snapshots[1], &idx.Snapshots[2])
	assert.NoError(t, err)

	bad := idx.Snapshots[1]
	bad.GasUsed = 501
	err = idx.ValidateAdjacentThreshold(&idx.Snapshots[0], &bad)
	assert.Error(t, err)
}

// TestFindFirstDivergentSegment 验证第一层承诺序列定位能找出最早分歧段。
func TestFindFirstDivergentSegment(t *testing.T) {
	claimed := core.NewSnapshotIndex(1337, 3000, 500)
	verified := core.NewSnapshotIndex(1337, 3000, 500)

	root0 := common.HexToHash("0x01")
	root1 := common.HexToHash("0x02")
	claimedBadRoot2 := common.HexToHash("0x03")
	verifiedRoot2 := common.HexToHash("0x04")

	claimed.Snapshots = []core.SnapshotIndexEntry{
		{Ordinal: 0, StepNumber: 0, GasUsed: 0, StateRoot: root0},
		{Ordinal: 1, StepNumber: 10, GasUsed: 500, StateRoot: root1},
		{Ordinal: 2, StepNumber: 20, GasUsed: 1000, StateRoot: claimedBadRoot2},
	}
	verified.Snapshots = []core.SnapshotIndexEntry{
		{Ordinal: 0, StepNumber: 0, GasUsed: 0, StateRoot: root0},
		{Ordinal: 1, StepNumber: 10, GasUsed: 500, StateRoot: root1},
		{Ordinal: 2, StepNumber: 20, GasUsed: 1000, StateRoot: verifiedRoot2},
	}

	divergence, err := proof.FindFirstDivergentSegment(claimed, verified)
	assert.NoError(t, err)
	require.NotNil(t, divergence)
	assert.True(t, divergence.Found)
	assert.Equal(t, 1, divergence.FromOrdinal)
	assert.Equal(t, 2, divergence.ToOrdinal)
	assert.Equal(t, root1, divergence.SharedStartRoot)
	assert.Equal(t, claimedBadRoot2, divergence.ClaimedNextRoot)
	assert.Equal(t, verifiedRoot2, divergence.VerifiedNextRoot)
}
