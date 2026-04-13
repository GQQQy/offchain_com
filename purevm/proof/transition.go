package proof

import (
	"encoding/json"
	"fmt"

	"purevm/core"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

// TransitionProof 状态转移证明（链下生成，链上验证）
type TransitionProof struct {
	InitialHash common.Hash `json:"initial_hash"`
	FinalHash   common.Hash `json:"final_hash"`
	CodeHash    common.Hash `json:"code_hash"`
	StartStep   uint64      `json:"start_step"`
	EndStep     uint64      `json:"end_step"`
	Steps       []StepProof `json:"steps"`
	GasUsed     uint64      `json:"gas_used"`
	TraceRoot   common.Hash `json:"trace_root"` // 步骤的Merkle根
}

// StepProof 单步证明（包含足够信息重建执行）
type StepProof struct {
	Index     uint64      `json:"index"`
	PC        uint64      `json:"pc"`
	OpCode    byte        `json:"opcode"`
	GasCost   uint64      `json:"gas_cost"`
	StackPop  int         `json:"stack_pop"`
	StackPush []core.Word `json:"stack_push,omitempty"`
	MemRead   []MemAccess `json:"mem_read,omitempty"`
	MemWrite  []MemAccess `json:"mem_write,omitempty"`
}

type MemAccess struct {
	Offset uint64 `json:"offset"`
	Size   uint64 `json:"size"`
	Value  []byte `json:"value,omitempty"` // 写入时的值
}

// GenerateTransitionProof 从VM执行生成证明
func GenerateTransitionProof(vm *core.VM, steps uint64) (*TransitionProof, error) {
	initialHash := vm.State.Hash()
	startStep := vm.State.StepCount

	stepProofs := make([]StepProof, 0, steps)
	totalGas := uint64(0)

	for i := uint64(0); i < steps && !vm.Halted; i++ {
		step := recordStep(vm)

		if err := vm.Step(); err != nil {
			return nil, err
		}

		// 记录执行后的栈变更
		recordStackChanges(vm, &step)

		stepProofs = append(stepProofs, step)
		totalGas += step.GasCost
	}

	finalHash := vm.State.Hash()
	traceRoot := calculateTraceRoot(stepProofs)

	return &TransitionProof{
		InitialHash: initialHash,
		FinalHash:   finalHash,
		CodeHash:    vm.State.CodeHash,
		StartStep:   startStep,
		EndStep:     vm.State.StepCount,
		Steps:       stepProofs,
		GasUsed:     totalGas,
		TraceRoot:   traceRoot,
	}, nil
}

func recordStep(vm *core.VM) StepProof {
	state := vm.State
	op := core.OpCode(state.Code[state.PC])

	step := StepProof{
		Index:  state.StepCount,
		PC:     state.PC,
		OpCode: byte(op),
	}

	// 预计算Gas（实际扣除在Step()中完成）
	gasCalc := core.NewGasCalculator()
	gas, _ := gasCalc.CalcOpcodeCost(op, state)
	step.GasCost = gas

	// 记录栈操作预期
	switch op {
	case core.POP:
		step.StackPop = 1
	case core.ADD, core.MUL, core.SUB, core.DIV, core.MOD:
		step.StackPop = 2
	case core.PUSH1:
		step.StackPush = []core.Word{core.WordFromUint64(uint64(state.Code[state.PC+1]))}
	case core.MLOAD:
		step.StackPop = 1
		if len(state.Stack) > 0 {
			addr := state.Stack[len(state.Stack)-1].Uint64()
			step.MemRead = []MemAccess{{Offset: addr, Size: 32}}
		}
	case core.MSTORE:
		step.StackPop = 2
		if len(state.Stack) > 1 {
			addr := state.Stack[len(state.Stack)-1].Uint64()
			val := state.Stack[len(state.Stack)-2]
			step.MemWrite = []MemAccess{{Offset: addr, Size: 32, Value: val[:]}}
		}
	}

	return step
}

func recordStackChanges(vm *core.VM, step *StepProof) {
	// 根据操作码记录执行后的栈顶值（用于验证）
	switch core.OpCode(step.OpCode) {
	case core.ADD, core.MUL, core.SUB, core.DIV, core.MOD:
		if len(vm.State.Stack) > 0 {
			step.StackPush = []core.Word{vm.State.Stack[len(vm.State.Stack)-1]}
		}
	}
}

func calculateTraceRoot(steps []StepProof) common.Hash {
	if len(steps) == 0 {
		return common.Hash{}
	}

	leaves := make([][]byte, len(steps))
	for i, step := range steps {
		data, _ := json.Marshal(step)
		leaves[i] = crypto.Keccak256(data)
	}

	// 简单的Merkle树构建
	for len(leaves) > 1 {
		next := make([][]byte, (len(leaves)+1)/2)
		for i := 0; i < len(leaves); i += 2 {
			if i+1 < len(leaves) {
				combined := append(leaves[i], leaves[i+1]...)
				next[i/2] = crypto.Keccak256(combined)
			} else {
				next[i/2] = leaves[i]
			}
		}
		leaves = next
	}

	return common.BytesToHash(leaves[0])
}

// Verify 链上验证证明（可在预编译合约中使用）
func (p *TransitionProof) Verify(initialState *core.VMState) error {
	// 1. 验证初始哈希
	if initialState.Hash() != p.InitialHash {
		return fmt.Errorf("initial state hash mismatch")
	}

	// 2. 重建VM并重放
	vm := core.NewVM(initialState.Code, initialState.Gas)
	vm.State = initialState.Clone()

	for i, step := range p.Steps {
		// 验证PC
		if vm.State.PC != step.PC {
			return fmt.Errorf("pc mismatch at step %d: have %d, want %d", i, vm.State.PC, step.PC)
		}

		// 验证操作码
		if vm.State.Code[vm.State.PC] != step.OpCode {
			return fmt.Errorf("opcode mismatch at step %d", i)
		}

		// 执行
		if err := vm.Step(); err != nil {
			return fmt.Errorf("execution failed at step %d: %v", i, err)
		}

		// 验证Gas（可选，严格验证时打开）
		// if gasLeft := vm.State.Gas; gasLeft != step.GasLeft {
		//     return fmt.Errorf("gas mismatch at step %d", i)
		// }
	}

	// 3. 验证最终哈希
	if vm.State.Hash() != p.FinalHash {
		return fmt.Errorf("final hash mismatch after replay")
	}

	return nil
}
