package core

import (
	"fmt"
	"math/big"
)

// Instruction 指令执行函数类型
type Instruction func(vm *VM, state *VMState) error

// InstructionSet 指令集映射
var InstructionSet = map[OpCode]Instruction{
	STOP:     opStop,
	ADD:      opAdd,
	MUL:      opMul,
	SUB:      opSub,
	DIV:      opDiv,
	MOD:      opMod,
	EXP:      opExp,
	LT:       opLt,
	GT:       opGt,
	EQ:       opEq,
	ISZERO:   opIszero,
	AND:      opAnd,
	OR:       opOr,
	XOR:      opXor,
	NOT:      opNot,
	SHL:      opShl,
	SHR:      opShr,
	SAR:      opSar,
	POP:      opPop,
	MLOAD:    opMload,
	MSTORE:   opMstore,
	MSTORE8:  opMstore8,
	MSIZE:    opMsize,
	JUMP:     opJump,
	JUMPI:    opJumpi,
	PC:       opPc,
	JUMPDEST: opJumpdest,
	SAVE:     opSave,
	SNAPSHOT: opSnapshot,
}

// 基础指令实现
func opStop(vm *VM, state *VMState) error {
	state.PC = uint64(len(state.Code)) // 超出范围即停机
	return nil
}

func opAdd(vm *VM, state *VMState) error {
	a, err := state.StackPop()
	if err != nil {
		return err
	}
	b, err := state.StackPop()
	if err != nil {
		return err
	}

	sum := new(big.Int).Add(b.BigInt(), a.BigInt())
	// 256位溢出自动截断（mod 2^256）
	sum.And(sum, new(big.Int).Lsh(big.NewInt(1), 256))
	sum.Sub(sum, big.NewInt(1))

	return state.StackPush(WordFromBigInt(sum))
}

func opMul(vm *VM, state *VMState) error {
	a, _ := state.StackPop()
	b, _ := state.StackPop()
	prod := new(big.Int).Mul(b.BigInt(), a.BigInt())
	prod.Mod(prod, new(big.Int).Lsh(big.NewInt(1), 256))
	return state.StackPush(WordFromBigInt(prod))
}

func opSub(vm *VM, state *VMState) error {
	a, _ := state.StackPop()
	b, _ := state.StackPop()
	sub := new(big.Int).Sub(b.BigInt(), a.BigInt())
	// 处理下溢（EVM语义：下溢为0，但这里用标准整数算术，Go的big.Int自动处理）
	if sub.Sign() < 0 {
		sub.Add(sub, new(big.Int).Lsh(big.NewInt(1), 256))
	}
	return state.StackPush(WordFromBigInt(sub))
}

func opDiv(vm *VM, state *VMState) error {
	a, _ := state.StackPop() // 除数
	b, _ := state.StackPop() // 被除数

	if a.IsZero() {
		return state.StackPush(Word{})
	}

	div := new(big.Int).Div(b.BigInt(), a.BigInt())
	return state.StackPush(WordFromBigInt(div))
}

func opMod(vm *VM, state *VMState) error {
	a, _ := state.StackPop()
	b, _ := state.StackPop()

	if a.IsZero() {
		return state.StackPush(Word{})
	}

	mod := new(big.Int).Mod(b.BigInt(), a.BigInt())
	return state.StackPush(WordFromBigInt(mod))
}

func opExp(vm *VM, state *VMState) error {
	exp, _ := state.StackPop()
	base, _ := state.StackPop()

	result := new(big.Int).Exp(base.BigInt(), exp.BigInt(), nil)
	result.Mod(result, new(big.Int).Lsh(big.NewInt(1), 256))
	return state.StackPush(WordFromBigInt(result))
}

func opLt(vm *VM, state *VMState) error {
	a, _ := state.StackPop()
	b, _ := state.StackPop()

	result := Word{}
	if b.BigInt().Cmp(a.BigInt()) < 0 {
		result[31] = 1
	}
	return state.StackPush(result)
}

func opGt(vm *VM, state *VMState) error {
	a, _ := state.StackPop()
	b, _ := state.StackPop()

	result := Word{}
	if b.BigInt().Cmp(a.BigInt()) > 0 {
		result[31] = 1
	}
	return state.StackPush(result)
}

func opEq(vm *VM, state *VMState) error {
	a, _ := state.StackPop()
	b, _ := state.StackPop()

	result := Word{}
	if a == b {
		result[31] = 1
	}
	return state.StackPush(result)
}

func opIszero(vm *VM, state *VMState) error {
	a, _ := state.StackPop()
	result := Word{}
	if a.IsZero() {
		result[31] = 1
	}
	return state.StackPush(result)
}

func opAnd(vm *VM, state *VMState) error {
	a, _ := state.StackPop()
	b, _ := state.StackPop()

	var result Word
	for i := 0; i < 32; i++ {
		result[i] = a[i] & b[i]
	}
	return state.StackPush(result)
}

func opOr(vm *VM, state *VMState) error {
	a, _ := state.StackPop()
	b, _ := state.StackPop()

	var result Word
	for i := 0; i < 32; i++ {
		result[i] = a[i] | b[i]
	}
	return state.StackPush(result)
}

func opXor(vm *VM, state *VMState) error {
	a, _ := state.StackPop()
	b, _ := state.StackPop()

	var result Word
	for i := 0; i < 32; i++ {
		result[i] = a[i] ^ b[i]
	}
	return state.StackPush(result)
}

func opNot(vm *VM, state *VMState) error {
	a, _ := state.StackPop()

	var result Word
	for i := 0; i < 32; i++ {
		result[i] = ^a[i]
	}
	return state.StackPush(result)
}

func opShl(vm *VM, state *VMState) error {
	shift, _ := state.StackPop()
	value, _ := state.StackPop()

	shiftNum := shift.Uint64()
	if shiftNum > 256 {
		return state.StackPush(Word{})
	}

	val := value.BigInt()
	val.Lsh(val, uint(shiftNum))
	val.Mod(val, new(big.Int).Lsh(big.NewInt(1), 256))
	return state.StackPush(WordFromBigInt(val))
}

func opShr(vm *VM, state *VMState) error {
	shift, _ := state.StackPop()
	value, _ := state.StackPop()

	shiftNum := shift.Uint64()
	if shiftNum > 256 {
		return state.StackPush(Word{})
	}

	val := value.BigInt()
	val.Rsh(val, uint(shiftNum))
	return state.StackPush(WordFromBigInt(val))
}

func opSar(vm *VM, state *VMState) error {
	// 算术右移（保留符号位）
	shift, _ := state.StackPop()
	value, _ := state.StackPop()

	shiftNum := shift.Uint64()
	if shiftNum > 256 {
		// 保留符号位，如果最高位为1则全1，否则全0
		if value[0]&0x80 != 0 {
			return state.StackPush(WordFromBigInt(new(big.Int).Sub(big.NewInt(0), big.NewInt(1))))
		}
		return state.StackPush(Word{})
	}

	val := new(big.Int).SetBytes(value[:])
	val.Rsh(val, uint(shiftNum))
	return state.StackPush(WordFromBigInt(val))
}

func opPop(vm *VM, state *VMState) error {
	_, err := state.StackPop()
	return err
}

func opMload(vm *VM, state *VMState) error {
	addr, _ := state.StackPop()
	offset := addr.Uint64()

	state.ExpandMemory(offset + 32)

	var value Word
	copy(value[:], state.Memory[offset:offset+32])
	return state.StackPush(value)
}

func opMstore(vm *VM, state *VMState) error {
	addr, _ := state.StackPop()
	value, _ := state.StackPop()
	offset := addr.Uint64()

	state.ExpandMemory(offset + 32)
	copy(state.Memory[offset:], value[:])
	return nil
}

func opMstore8(vm *VM, state *VMState) error {
	addr, _ := state.StackPop()
	value, _ := state.StackPop()
	offset := addr.Uint64()

	state.ExpandMemory(offset + 1)
	state.Memory[offset] = value[31] // 取最低字节
	return nil
}

func opMsize(vm *VM, state *VMState) error {
	return state.StackPush(WordFromUint64(uint64(len(state.Memory))))
}

func opJump(vm *VM, state *VMState) error {
	pos, _ := state.StackPop()
	dest := pos.Uint64()

	if dest >= uint64(len(state.Code)) {
		return fmt.Errorf("jump destination out of bounds: %d", dest)
	}
	if state.Code[dest] != byte(JUMPDEST) {
		return fmt.Errorf("invalid jump destination: %d (not JUMPDEST)", dest)
	}

	state.PC = dest
	return nil
}

func opJumpi(vm *VM, state *VMState) error {
	pos, _ := state.StackPop()
	cond, _ := state.StackPop()

	if !cond.IsZero() {
		dest := pos.Uint64()
		if dest >= uint64(len(state.Code)) {
			return fmt.Errorf("jumpi destination out of bounds: %d", dest)
		}
		if state.Code[dest] != byte(JUMPDEST) {
			return fmt.Errorf("invalid jumpi destination: %d", dest)
		}
		state.PC = dest
		return nil
	}
	return nil
}

func opPc(vm *VM, state *VMState) error {
	return state.StackPush(WordFromUint64(state.PC))
}

func opJumpdest(vm *VM, state *VMState) error {
	// JUMPDEST是无操作，仅作为标记
	return nil
}

func opSave(vm *VM, state *VMState) error {
	// 将当前状态哈希压栈（用于后续验证）
	hash := state.Hash()
	var hashWord Word
	copy(hashWord[:], hash[:])
	return state.StackPush(hashWord)
}

func opSnapshot(vm *VM, state *VMState) error {
	// 创建快照并返回哈希（快照数据应由上层管理）
	hash := state.Hash()
	var hashWord Word
	copy(hashWord[:], hash[:])
	return state.StackPush(hashWord)
}

// ExecutePush 执行PUSH指令（特殊处理，因为操作数在代码中）
func ExecutePush(vm *VM, state *VMState, op OpCode) error {
	size := op.PushSize()
	if state.PC+size >= uint64(len(state.Code)) {
		return fmt.Errorf("push overflow: need %d bytes at pc %d", size, state.PC)
	}

	var value Word
	start := state.PC + 1
	end := start + size
	copy(value[32-size:], state.Code[start:end])

	if err := state.StackPush(value); err != nil {
		return err
	}

	state.PC += size // PUSH指令消耗额外的PC步进
	return nil
}

// ExecuteDup 执行DUP指令
func ExecuteDup(vm *VM, state *VMState, op OpCode) error {
	idx := int(op - DUP1)
	if state.GetStackDepth() <= idx {
		return fmt.Errorf("dup underflow: need %d, have %d", idx+1, state.GetStackDepth())
	}

	val := state.Stack[state.GetStackDepth()-1-idx]
	return state.StackPush(val)
}

// ExecuteSwap 执行SWAP指令
func ExecuteSwap(vm *VM, state *VMState, op OpCode) error {
	idx := int(op-SWAP1) + 1
	if state.GetStackDepth() < idx+1 {
		return fmt.Errorf("swap underflow: need %d, have %d", idx+1, state.GetStackDepth())
	}

	top := state.GetStackDepth() - 1
	target := top - idx

	state.Stack[top], state.Stack[target] = state.Stack[target], state.Stack[top]
	return nil
}
