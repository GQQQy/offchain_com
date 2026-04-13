package core

import (
	"fmt"

	"github.com/ethereum/go-ethereum/common"
)

// VM 虚拟机实例
type VM struct {
	State          *VMState
	GasCalc        *GasCalculator
	InstructionSet map[OpCode]Instruction
	ChainID        uint64
	Snapshots      map[common.Hash]*StandardSnapshot

	// 执行控制
	Halted bool
	Err    error

	// 调试/追踪
	Tracer *ExecutionTracer
}

// ExecutionTracer 执行轨迹记录器
type ExecutionTracer struct {
	Steps []TraceStep
}

type TraceStep struct {
	PC        uint64 `json:"pc"`
	Op        string `json:"op"`
	GasCost   uint64 `json:"gas_cost"`
	GasLeft   uint64 `json:"gas_left"`
	StackSize int    `json:"stack_size"`
	OpCode    byte   `json:"opcode"`
}

// NewVM 创建新VM实例
func NewVM(code []byte, gasLimit uint64) *VM {
	return &VM{
		State:          NewState(code, gasLimit),
		GasCalc:        NewGasCalculator(),
		InstructionSet: InstructionSet,
		Snapshots:      make(map[common.Hash]*StandardSnapshot),
		Halted:         false,
		Tracer:         &ExecutionTracer{Steps: make([]TraceStep, 0)},
	}
}

// Step 单步执行
func (vm *VM) Step() error {
	if vm.Halted {
		return nil
	}

	if vm.State.PC >= uint64(len(vm.State.Code)) {
		vm.Halted = true
		return nil
	}

	prePC := vm.State.PC
	op := OpCode(vm.State.Code[vm.State.PC])

	// 计算Gas
	gasCost, err := vm.GasCalc.CalcOpcodeCost(op, vm.State)
	if err != nil {
		vm.Err = err
		return err
	}

	if vm.State.Gas < gasCost {
		vm.Err = fmt.Errorf("out of gas: have %d, need %d", vm.State.Gas, gasCost)
		return vm.Err
	}

	// 执行指令
	if op.IsPush() {
		err = ExecutePush(vm, vm.State, op)
	} else if op >= DUP1 && op <= DUP16 {
		err = ExecuteDup(vm, vm.State, op)
	} else if op >= SWAP1 && op <= SWAP16 {
		err = ExecuteSwap(vm, vm.State, op)
	} else {
		instr, ok := vm.InstructionSet[op]
		if !ok {
			err = fmt.Errorf("undefined opcode: 0x%x at pc %d", byte(op), vm.State.PC)
		} else {
			err = instr(vm, vm.State)
		}
	}

	if err != nil {
		vm.Err = err
		return err
	}

	switch op {
	case STOP, RESTORE:
		// STOP/RESTORE 保留指令实现设置的PC。
	case JUMP:
		// JUMP已在指令实现中设置目标PC。
	case JUMPI:
		if vm.State.PC == prePC {
			vm.State.PC++
		}
	default:
		vm.State.PC++
	}
	vm.State.Gas -= gasCost
	vm.State.StepCount++
	if vm.State.PC >= uint64(len(vm.State.Code)) {
		vm.Halted = true
	}

	// 记录轨迹
	if vm.Tracer != nil {
		vm.Tracer.Steps = append(vm.Tracer.Steps, TraceStep{
			PC:        prePC,
			Op:        op.String(),
			GasCost:   gasCost,
			GasLeft:   vm.State.Gas,
			StackSize: vm.State.GetStackDepth(),
			OpCode:    byte(op),
		})
	}

	return nil
}

// Run 执行直到停机
func (vm *VM) Run() error {
	for !vm.Halted && vm.Err == nil {
		if err := vm.Step(); err != nil {
			return err
		}
	}
	return vm.Err
}

// RunSteps 执行指定步数
func (vm *VM) RunSteps(n uint64) error {
	for i := uint64(0); i < n && !vm.Halted && vm.Err == nil; i++ {
		if err := vm.Step(); err != nil {
			return err
		}
	}
	return nil
}

// GetTrace 获取执行轨迹
func (vm *VM) GetTrace() []TraceStep {
	if vm.Tracer == nil {
		return nil
	}
	return vm.Tracer.Steps
}

// CreateSnapshot 创建当前状态的标准快照。
func (vm *VM) CreateSnapshot(chainID uint64) *StandardSnapshot {
	return NewStandardSnapshot(vm.State.Clone(), chainID)
}

// LoadSnapshot 从快照恢复（用于链上验证）
func (vm *VM) LoadSnapshot(snap *StandardSnapshot) error {
	// 验证哈希
	calcHash := snap.State.Hash()
	if calcHash != snap.Header.StateRoot {
		return fmt.Errorf("snapshot hash mismatch: calc %s, want %s", calcHash.Hex(), snap.Header.StateRoot.Hex())
	}

	vm.State = snap.State.Clone()
	vm.Halted = false
	vm.Err = nil
	return nil
}

// ValidateTransition 验证从当前状态执行指定步数后是否到达目标状态（用于链上重放）
func (vm *VM) ValidateTransition(steps uint64, expectedHash common.Hash) error {
	if err := vm.RunSteps(steps); err != nil {
		return err
	}

	finalHash := vm.State.Hash()
	if finalHash != expectedHash {
		return fmt.Errorf("transition hash mismatch: got %s, want %s", finalHash.Hex(), expectedHash.Hex())
	}
	return nil
}
