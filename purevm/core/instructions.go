package core

import (
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/common"
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
	SDIV:     opSdiv,
	MOD:      opMod,
	SMOD:     opSmod,
	ADDMOD:   opAddmod,
	MULMOD:   opMulmod,
	EXP:      opExp,
	SIGNEXTEND: opSignextend,
	LT:       opLt,
	GT:       opGt,
	SLT:      opSlt,
	SGT:      opSgt,
	EQ:       opEq,
	ISZERO:   opIszero,
	AND:      opAnd,
	OR:       opOr,
	XOR:      opXor,
	NOT:      opNot,
	BYTE:     opByte,
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
	GAS:      opGas,
	JUMPDEST: opJumpdest,
	SAVE:     opSave,
	SNAPSHOT: opSnapshot,
	RESTORE:  opRestore,
}

func pop1(state *VMState) (Word, error) {
	return state.StackPop()
}

func pop2(state *VMState) (Word, Word, error) {
	a, err := state.StackPop()
	if err != nil {
		return Word{}, Word{}, err
	}
	b, err := state.StackPop()
	if err != nil {
		return Word{}, Word{}, err
	}
	return a, b, nil
}

func pop3(state *VMState) (Word, Word, Word, error) {
	a, b, err := pop2(state)
	if err != nil {
		return Word{}, Word{}, Word{}, err
	}
	c, err := state.StackPop()
	if err != nil {
		return Word{}, Word{}, Word{}, err
	}
	return a, b, c, nil
}

// 基础指令实现
func opStop(vm *VM, state *VMState) error {
	state.PC = uint64(len(state.Code))
	vm.Halted = true
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
	sum.Mod(sum, wordModulus)
	return state.StackPush(WordFromBigInt(sum))
}

func opMul(vm *VM, state *VMState) error {
	a, b, err := pop2(state)
	if err != nil {
		return err
	}
	prod := new(big.Int).Mul(b.BigInt(), a.BigInt())
	prod.Mod(prod, wordModulus)
	return state.StackPush(WordFromBigInt(prod))
}

func opSub(vm *VM, state *VMState) error {
	a, b, err := pop2(state)
	if err != nil {
		return err
	}
	sub := new(big.Int).Sub(b.BigInt(), a.BigInt())
	sub.Mod(sub, wordModulus)
	return state.StackPush(WordFromBigInt(sub))
}

func opDiv(vm *VM, state *VMState) error {
	a, b, err := pop2(state)
	if err != nil {
		return err
	}

	if a.IsZero() {
		return state.StackPush(Word{})
	}

	div := new(big.Int).Div(b.BigInt(), a.BigInt())
	return state.StackPush(WordFromBigInt(div))
}

func opSdiv(vm *VM, state *VMState) error {
	a, b, err := pop2(state)
	if err != nil {
		return err
	}
	if a.IsZero() {
		return state.StackPush(Word{})
	}

	result := new(big.Int).Div(b.SignedBigInt(), a.SignedBigInt())
	return state.StackPush(WordFromSignedBigInt(result))
}

func opMod(vm *VM, state *VMState) error {
	a, b, err := pop2(state)
	if err != nil {
		return err
	}

	if a.IsZero() {
		return state.StackPush(Word{})
	}

	mod := new(big.Int).Mod(b.BigInt(), a.BigInt())
	return state.StackPush(WordFromBigInt(mod))
}

func opSmod(vm *VM, state *VMState) error {
	a, b, err := pop2(state)
	if err != nil {
		return err
	}
	if a.IsZero() {
		return state.StackPush(Word{})
	}

	dividend := b.SignedBigInt()
	divisor := a.SignedBigInt()
	absDividend := new(big.Int).Abs(new(big.Int).Set(dividend))
	absDivisor := new(big.Int).Abs(new(big.Int).Set(divisor))
	result := new(big.Int).Mod(absDividend, absDivisor)
	if dividend.Sign() < 0 {
		result.Neg(result)
	}
	return state.StackPush(WordFromSignedBigInt(result))
}

func opAddmod(vm *VM, state *VMState) error {
	modulus, b, a, err := pop3(state)
	if err != nil {
		return err
	}
	if modulus.IsZero() {
		return state.StackPush(Word{})
	}

	sum := new(big.Int).Add(a.BigInt(), b.BigInt())
	sum.Mod(sum, modulus.BigInt())
	return state.StackPush(WordFromBigInt(sum))
}

func opMulmod(vm *VM, state *VMState) error {
	modulus, b, a, err := pop3(state)
	if err != nil {
		return err
	}
	if modulus.IsZero() {
		return state.StackPush(Word{})
	}

	product := new(big.Int).Mul(a.BigInt(), b.BigInt())
	product.Mod(product, modulus.BigInt())
	return state.StackPush(WordFromBigInt(product))
}

func opExp(vm *VM, state *VMState) error {
	exp, base, err := pop2(state)
	if err != nil {
		return err
	}

	result := new(big.Int).Exp(base.BigInt(), exp.BigInt(), nil)
	result.Mod(result, wordModulus)
	return state.StackPush(WordFromBigInt(result))
}

func opLt(vm *VM, state *VMState) error {
	a, b, err := pop2(state)
	if err != nil {
		return err
	}

	result := Word{}
	if b.BigInt().Cmp(a.BigInt()) < 0 {
		result[31] = 1
	}
	return state.StackPush(result)
}

func opGt(vm *VM, state *VMState) error {
	a, b, err := pop2(state)
	if err != nil {
		return err
	}

	result := Word{}
	if b.BigInt().Cmp(a.BigInt()) > 0 {
		result[31] = 1
	}
	return state.StackPush(result)
}

func opSlt(vm *VM, state *VMState) error {
	a, b, err := pop2(state)
	if err != nil {
		return err
	}

	result := Word{}
	if b.SignedBigInt().Cmp(a.SignedBigInt()) < 0 {
		result[31] = 1
	}
	return state.StackPush(result)
}

func opSgt(vm *VM, state *VMState) error {
	a, b, err := pop2(state)
	if err != nil {
		return err
	}

	result := Word{}
	if b.SignedBigInt().Cmp(a.SignedBigInt()) > 0 {
		result[31] = 1
	}
	return state.StackPush(result)
}

func opEq(vm *VM, state *VMState) error {
	a, b, err := pop2(state)
	if err != nil {
		return err
	}

	result := Word{}
	if a == b {
		result[31] = 1
	}
	return state.StackPush(result)
}

func opIszero(vm *VM, state *VMState) error {
	a, err := pop1(state)
	if err != nil {
		return err
	}
	result := Word{}
	if a.IsZero() {
		result[31] = 1
	}
	return state.StackPush(result)
}

func opAnd(vm *VM, state *VMState) error {
	a, b, err := pop2(state)
	if err != nil {
		return err
	}

	var result Word
	for i := 0; i < 32; i++ {
		result[i] = a[i] & b[i]
	}
	return state.StackPush(result)
}

func opOr(vm *VM, state *VMState) error {
	a, b, err := pop2(state)
	if err != nil {
		return err
	}

	var result Word
	for i := 0; i < 32; i++ {
		result[i] = a[i] | b[i]
	}
	return state.StackPush(result)
}

func opXor(vm *VM, state *VMState) error {
	a, b, err := pop2(state)
	if err != nil {
		return err
	}

	var result Word
	for i := 0; i < 32; i++ {
		result[i] = a[i] ^ b[i]
	}
	return state.StackPush(result)
}

func opNot(vm *VM, state *VMState) error {
	a, err := pop1(state)
	if err != nil {
		return err
	}

	var result Word
	for i := 0; i < 32; i++ {
		result[i] = ^a[i]
	}
	return state.StackPush(result)
}

func opByte(vm *VM, state *VMState) error {
	index, value, err := pop2(state)
	if err != nil {
		return err
	}

	result := Word{}
	idx := index.Uint64()
	if idx < 32 {
		result[31] = value[idx]
	}
	return state.StackPush(result)
}

func opSignextend(vm *VM, state *VMState) error {
	back, value, err := pop2(state)
	if err != nil {
		return err
	}

	backIdx := back.Uint64()
	if backIdx >= 32 {
		return state.StackPush(value)
	}

	result := value
	signByte := 31 - int(backIdx)
	signBitSet := result[signByte]&0x80 != 0
	fill := byte(0x00)
	if signBitSet {
		fill = 0xff
	}

	for i := 0; i < signByte; i++ {
		result[i] = fill
	}
	return state.StackPush(result)
}

func opShl(vm *VM, state *VMState) error {
	shift, value, err := pop2(state)
	if err != nil {
		return err
	}

	shiftNum := shift.Uint64()
	if shiftNum >= 256 {
		return state.StackPush(Word{})
	}

	val := value.BigInt()
	val.Lsh(val, uint(shiftNum))
	val.Mod(val, wordModulus)
	return state.StackPush(WordFromBigInt(val))
}

func opShr(vm *VM, state *VMState) error {
	shift, value, err := pop2(state)
	if err != nil {
		return err
	}

	shiftNum := shift.Uint64()
	if shiftNum >= 256 {
		return state.StackPush(Word{})
	}

	val := value.BigInt()
	val.Rsh(val, uint(shiftNum))
	return state.StackPush(WordFromBigInt(val))
}

func opSar(vm *VM, state *VMState) error {
	shift, value, err := pop2(state)
	if err != nil {
		return err
	}

	shiftNum := shift.Uint64()
	if shiftNum >= 256 {
		if value[0]&0x80 != 0 {
			return state.StackPush(WordFromSignedBigInt(big.NewInt(-1)))
		}
		return state.StackPush(Word{})
	}

	val := value.SignedBigInt()
	val.Rsh(val, uint(shiftNum))
	return state.StackPush(WordFromSignedBigInt(val))
}

func opPop(vm *VM, state *VMState) error {
	_, err := state.StackPop()
	return err
}

func opMload(vm *VM, state *VMState) error {
	addr, err := pop1(state)
	if err != nil {
		return err
	}
	offset := addr.Uint64()

	state.ExpandMemory(offset + 32)

	var value Word
	copy(value[:], state.Memory[offset:offset+32])
	return state.StackPush(value)
}

func opMstore(vm *VM, state *VMState) error {
	addr, value, err := pop2(state)
	if err != nil {
		return err
	}
	offset := addr.Uint64()

	state.ExpandMemory(offset + 32)
	copy(state.Memory[offset:], value[:])
	return nil
}

func opMstore8(vm *VM, state *VMState) error {
	addr, value, err := pop2(state)
	if err != nil {
		return err
	}
	offset := addr.Uint64()

	state.ExpandMemory(offset + 1)
	state.Memory[offset] = value[31] // 取最低字节
	return nil
}

func opMsize(vm *VM, state *VMState) error {
	return state.StackPush(WordFromUint64(uint64(len(state.Memory))))
}

func opJump(vm *VM, state *VMState) error {
	pos, err := pop1(state)
	if err != nil {
		return err
	}
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
	pos, cond, err := pop2(state)
	if err != nil {
		return err
	}

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

func opGas(vm *VM, state *VMState) error {
	return state.StackPush(WordFromUint64(state.Gas))
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
	snap := NewStandardSnapshot(state.Clone(), vm.ChainID)
	hash := snap.Header.StateRoot
	vm.Snapshots[hash] = snap
	return state.StackPush(WordFromBytes(hash[:]))
}

func opRestore(vm *VM, state *VMState) error {
	hashWord, err := pop1(state)
	if err != nil {
		return err
	}

	hash := common.BytesToHash(hashWord[:])
	snap, ok := vm.Snapshots[hash]
	if !ok {
		return fmt.Errorf("snapshot not found: %s", hash.Hex())
	}
	return vm.LoadSnapshot(snap)
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
