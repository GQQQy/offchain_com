package proof

import (
	"bytes"
	"fmt"

	"purevm/core"

	"github.com/ethereum/go-ethereum/common"
)

// TransitionProof 状态转移证明（链下生成，链上验证）。
type TransitionProof struct {
	InitialHash common.Hash `json:"initial_hash"`
	FinalHash   common.Hash `json:"final_hash"`
	CodeHash    common.Hash `json:"code_hash"`
	StartStep   uint64      `json:"start_step"`
	EndStep     uint64      `json:"end_step"`
	Steps       []StepProof `json:"steps"`
	GasUsed     uint64      `json:"gas_used"`
	TraceRoot   common.Hash `json:"trace_root"`
}

// StepProof 记录单步执行前后可验证的信息。
type StepProof struct {
	Index           uint64        `json:"index"`
	PC              uint64        `json:"pc"`
	OpCode          byte          `json:"opcode"`
	GasBefore       uint64        `json:"gas_before"`
	GasCost         uint64        `json:"gas_cost"`
	GasAfter        uint64        `json:"gas_after"`
	StackBeforeSize int           `json:"stack_before_size"`
	StackAfterSize  int           `json:"stack_after_size"`
	StackPopped     []core.Word   `json:"stack_popped,omitempty"`
	StackPushed     []core.Word   `json:"stack_pushed,omitempty"`
	MemRead         []MemAccess   `json:"mem_read,omitempty"`
	MemWrite        []MemAccess   `json:"mem_write,omitempty"`
	StateHashBefore common.Hash   `json:"state_hash_before"`
	StateHashAfter  common.Hash   `json:"state_hash_after"`
}

type MemAccess struct {
	Offset uint64 `json:"offset"`
	Size   uint64 `json:"size"`
	Value  []byte `json:"value,omitempty"`
}

// GenerateTransitionProof 从VM执行生成证明。steps=0表示一直执行到停机。
func GenerateTransitionProof(vm *core.VM, steps uint64) (*TransitionProof, error) {
	initialHash := vm.State.Hash()
	startStep := vm.State.StepCount

	stepProofs := make([]StepProof, 0)
	totalGas := uint64(0)

	for i := uint64(0); !vm.Halted && (steps == 0 || i < steps); i++ {
		before := vm.State.Clone()
		step, err := recordStep(vm, before)
		if err != nil {
			return nil, err
		}

		if err := vm.Step(); err != nil {
			return nil, err
		}

		after := vm.State.Clone()
		finalizeStep(&step, before, after)

		stepProofs = append(stepProofs, step)
		totalGas += step.GasCost
	}

	return &TransitionProof{
		InitialHash: initialHash,
		FinalHash:   vm.State.Hash(),
		CodeHash:    vm.State.CodeHash,
		StartStep:   startStep,
		EndStep:     vm.State.StepCount,
		Steps:       stepProofs,
		GasUsed:     totalGas,
		TraceRoot:   CalculateTraceRoot(stepProofs),
	}, nil
}

func recordStep(vm *core.VM, before *core.VMState) (StepProof, error) {
	op := core.OpCode(before.Code[before.PC])
	gasCost, err := vm.GasCalc.CalcOpcodeCost(op, before)
	if err != nil {
		return StepProof{}, err
	}

	return StepProof{
		Index:           before.StepCount,
		PC:              before.PC,
		OpCode:          byte(op),
		GasBefore:       before.Gas,
		GasCost:         gasCost,
		StackBeforeSize: before.GetStackDepth(),
		MemRead:         inferMemoryReads(op, before),
		StateHashBefore: before.Hash(),
	}, nil
}

func finalizeStep(step *StepProof, before, after *core.VMState) {
	step.GasAfter = after.Gas
	step.StackAfterSize = after.GetStackDepth()
	step.StateHashAfter = after.Hash()
	step.StackPopped, step.StackPushed = diffStacks(before.Stack, after.Stack)
	step.MemWrite = diffMemory(before.Memory, after.Memory)
}

func inferMemoryReads(op core.OpCode, state *core.VMState) []MemAccess {
	switch op {
	case core.MLOAD:
		if len(state.Stack) == 0 {
			return nil
		}
		offset := state.Stack[len(state.Stack)-1].Uint64()
		return []MemAccess{{
			Offset: offset,
			Size:   32,
			Value:  readMemory(state.Memory, offset, 32),
		}}
	default:
		return nil
	}
}

func readMemory(memory []byte, offset, size uint64) []byte {
	buf := make([]byte, size)
	if offset >= uint64(len(memory)) {
		return buf
	}
	end := offset + size
	if end > uint64(len(memory)) {
		end = uint64(len(memory))
	}
	copy(buf, memory[int(offset):int(end)])
	return buf
}

func diffStacks(before, after []core.Word) ([]core.Word, []core.Word) {
	prefix := 0
	for prefix < len(before) && prefix < len(after) && before[prefix] == after[prefix] {
		prefix++
	}

	popped := append([]core.Word(nil), before[prefix:]...)
	pushed := append([]core.Word(nil), after[prefix:]...)
	return popped, pushed
}

func diffMemory(before, after []byte) []MemAccess {
	maxLen := len(before)
	if len(after) > maxLen {
		maxLen = len(after)
	}
	if maxLen == 0 {
		return nil
	}

	writes := make([]MemAccess, 0)
	start := -1

	for i := 0; i < maxLen; i++ {
		var bBefore, bAfter byte
		if i < len(before) {
			bBefore = before[i]
		}
		if i < len(after) {
			bAfter = after[i]
		}

		if bBefore != bAfter {
			if start == -1 {
				start = i
			}
			continue
		}

		if start != -1 {
			writes = append(writes, MemAccess{
				Offset: uint64(start),
				Size:   uint64(i - start),
				Value:  append([]byte(nil), after[start:i]...),
			})
			start = -1
		}
	}

	if start != -1 {
		writes = append(writes, MemAccess{
			Offset: uint64(start),
			Size:   uint64(maxLen - start),
			Value:  append([]byte(nil), after[start:maxLen]...),
		})
	}

	return writes
}

// Link 返回可挂在快照序列上的转移摘要。
func (p *TransitionProof) Link() core.TransitionLink {
	return core.TransitionLink{
		InitialRoot: p.InitialHash,
		FinalRoot:   p.FinalHash,
		StartStep:   p.StartStep,
		EndStep:     p.EndStep,
		TraceRoot:   p.TraceRoot,
	}
}

// Verify 从初始状态重放证明，并校验Gas、栈变化、内存变化和最终状态。
func (p *TransitionProof) Verify(initialState *core.VMState) error {
	if initialState.Hash() != p.InitialHash {
		return fmt.Errorf("initial state hash mismatch")
	}
	if initialState.CodeHash != p.CodeHash {
		return fmt.Errorf("code hash mismatch")
	}
	if CalculateTraceRoot(p.Steps) != p.TraceRoot {
		return fmt.Errorf("trace root mismatch")
	}

	vm := core.NewVM(initialState.Code, initialState.Gas)
	vm.State = initialState.Clone()

	totalGas := uint64(0)
	for i, step := range p.Steps {
		if vm.State.Hash() != step.StateHashBefore {
			return fmt.Errorf("pre-state hash mismatch at step %d", i)
		}
		if vm.State.PC != step.PC {
			return fmt.Errorf("pc mismatch at step %d: have %d, want %d", i, vm.State.PC, step.PC)
		}
		if vm.State.Code[vm.State.PC] != step.OpCode {
			return fmt.Errorf("opcode mismatch at step %d", i)
		}
		if vm.State.Gas != step.GasBefore {
			return fmt.Errorf("gas before mismatch at step %d", i)
		}
		if vm.State.GetStackDepth() != step.StackBeforeSize {
			return fmt.Errorf("stack size before mismatch at step %d", i)
		}

		for _, read := range step.MemRead {
			actual := readMemory(vm.State.Memory, read.Offset, read.Size)
			if !bytes.Equal(actual, read.Value) {
				return fmt.Errorf("memory read mismatch at step %d", i)
			}
		}

		before := vm.State.Clone()
		if err := vm.Step(); err != nil {
			return fmt.Errorf("execution failed at step %d: %v", i, err)
		}

		if before.Gas-vm.State.Gas != step.GasCost {
			return fmt.Errorf("gas cost mismatch at step %d", i)
		}
		if vm.State.Gas != step.GasAfter {
			return fmt.Errorf("gas after mismatch at step %d", i)
		}
		if vm.State.GetStackDepth() != step.StackAfterSize {
			return fmt.Errorf("stack size after mismatch at step %d", i)
		}

		popped, pushed := diffStacks(before.Stack, vm.State.Stack)
		if !equalWords(popped, step.StackPopped) {
			return fmt.Errorf("stack pop mismatch at step %d", i)
		}
		if !equalWords(pushed, step.StackPushed) {
			return fmt.Errorf("stack push mismatch at step %d", i)
		}

		writes := diffMemory(before.Memory, vm.State.Memory)
		if !equalMemAccesses(writes, step.MemWrite) {
			return fmt.Errorf("memory write mismatch at step %d", i)
		}

		if vm.State.Hash() != step.StateHashAfter {
			return fmt.Errorf("post-state hash mismatch at step %d", i)
		}
		totalGas += step.GasCost
	}

	if totalGas != p.GasUsed {
		return fmt.Errorf("proof gas mismatch")
	}
	if vm.State.Hash() != p.FinalHash {
		return fmt.Errorf("final hash mismatch after replay")
	}
	if vm.State.StepCount != p.EndStep {
		return fmt.Errorf("end step mismatch")
	}

	return nil
}

func equalWords(a, b []core.Word) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func equalMemAccesses(a, b []MemAccess) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i].Offset != b[i].Offset || a[i].Size != b[i].Size || !bytes.Equal(a[i].Value, b[i].Value) {
			return false
		}
	}
	return true
}
