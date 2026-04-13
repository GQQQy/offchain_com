package core

import (
	"fmt"

	"github.com/ethereum/go-ethereum/params"
)

// GasCalculator EIP-150/2028兼容的Gas计算器
type GasCalculator struct{}

// NewGasCalculator 创建计算器
func NewGasCalculator() *GasCalculator {
	return &GasCalculator{}
}

// CalcOpcodeCost 计算操作码基础成本（来自params/protocol_params.go）
func (gc *GasCalculator) CalcOpcodeCost(op OpCode, state *VMState) (uint64, error) {
	switch op {
	// 零成本
	case STOP, INVALID:
		return 0, nil

	// 快速操作（GasQuickStep = 2）
	case PC, GAS, POP:
		return params.GasQuickStep, nil

	// 最快操作（GasFastestStep = 3）
	case ADD, SUB, LT, GT, SLT, SGT, EQ, ISZERO, AND, OR, XOR, NOT, BYTE, SHL, SHR, SAR:
		return params.GasFastestStep, nil

	// 快速操作（GasFastStep = 5）
	case MUL, DIV, SDIV, MOD, SMOD, SIGNEXTEND:
		return params.GasFastStep, nil

	// 中等操作（GasMidStep = 8）
	case ADDMOD, MULMOD:
		return params.GasMidStep, nil

	// 慢速操作（GasSlowStep = 10）
	case EXP:
		return gc.calcExpGas(state)

	// 栈操作（统一GasFastestStep）
	case DUP1, DUP2, DUP3, DUP4, DUP5, DUP6, DUP7, DUP8, DUP9, DUP10, DUP11, DUP12, DUP13, DUP14, DUP15, DUP16:
		return params.GasFastestStep, nil
	case SWAP1, SWAP2, SWAP3, SWAP4, SWAP5, SWAP6, SWAP7, SWAP8, SWAP9, SWAP10, SWAP11, SWAP12, SWAP13, SWAP14, SWAP15, SWAP16:
		return params.GasFastestStep, nil
	case PUSH1, PUSH2, PUSH3, PUSH4, PUSH5, PUSH6, PUSH7, PUSH8, PUSH9, PUSH10,
		PUSH11, PUSH12, PUSH13, PUSH14, PUSH15, PUSH16, PUSH17, PUSH18, PUSH19, PUSH20,
		PUSH21, PUSH22, PUSH23, PUSH24, PUSH25, PUSH26, PUSH27, PUSH28, PUSH29, PUSH30, PUSH31, PUSH32:
		return params.GasFastestStep, nil

	// 内存操作（基础费用+动态扩展费用）
	case MLOAD, MSTORE:
		return gc.calcMemoryOpGas(op, state)
	case MSTORE8:
		return gc.calcMemoryOpGas(op, state)
	case MSIZE:
		return params.GasQuickStep, nil

	// 跳转
	case JUMP:
		return 8, nil // GasJump
	case JUMPI:
		return 10, nil // GasJumpDest（实际应为GasJump + 条件判断）

	// 快照操作（自定义，参考SSTORE定价）
	case SAVE:
		return 100, nil // 仅哈希计算
	case SNAPSHOT:
		// 类似SSTORE的冷存储写入（20000），但按状态大小线性增长
		stateSize := uint64(len(state.SerializeCanonical()))
		return 20000 + stateSize*10, nil
	case RESTORE:
		return 5000, nil // 类似热存储读取

	default:
		return 0, fmt.Errorf("undefined gas cost for opcode: %s", op.String())
	}
}

// calcExpGas EXP操作Gas（EIP-160）
func (gc *GasCalculator) calcExpGas(state *VMState) (uint64, error) {
	if state.GetStackDepth() < 2 {
		return 0, fmt.Errorf("stack underflow for EXP")
	}

	exp := state.Stack[len(state.Stack)-1] // 指数是栈顶（最后压入的）

	// 计算指数的字节长度
	expBytes := 0
	for i := 31; i >= 0; i-- {
		if exp[i] != 0 {
			expBytes = i + 1
			break
		}
	}

	// EIP-160: gas = 10 + 50 * byte_len(exponent)
	return params.ExpGas + uint64(expBytes)*params.ExpByteGas, nil
}

// calcMemoryOpGas 内存操作Gas（含扩展成本）
func (gc *GasCalculator) calcMemoryOpGas(op OpCode, state *VMState) (uint64, error) {
	if state.GetStackDepth() < 1 {
		return 0, fmt.Errorf("stack underflow for memory operation")
	}

	addr := state.Stack[len(state.Stack)-1].Uint64()
	var newSize uint64

	switch op {
	case MLOAD, MSTORE:
		newSize = addr + 32
	case MSTORE8:
		newSize = addr + 1
	}

	// 基础操作费用 + 内存扩展费用
	baseCost := params.GasFastestStep
	memCost := state.MemoryExpansionCost(newSize)

	return baseCost + memCost, nil
}

// RefundGas 计算可能的Gas退款（本VM主要用于SSTORE退款逻辑，但纯计算VM很少使用）
func (gc *GasCalculator) RefundGas(state *VMState) uint64 {
	return state.Refund
}
