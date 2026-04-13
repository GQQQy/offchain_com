package test

import (
	"encoding/json"
	"testing"

	"purevm/core"
	"purevm/proof"

	"github.com/stretchr/testify/assert"
)

// 测试：简单的算术执行和快照验证
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

// 测试：转移证明生成和验证
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

// 测试：Gas计算一致性
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

// 测试：内存扩展和Gas计算
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

// 测试：快照序列连续性
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
