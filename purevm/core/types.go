package core

import (
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"math/big"
)

// Word 256位整数（与EVM一致的大端序表示）
type Word [32]byte

func (w Word) BigInt() *big.Int {
	return new(big.Int).SetBytes(w[:])
}

func (w Word) Uint64() uint64 {
	if w.IsZero() {
		return 0
	}
	return new(big.Int).SetBytes(w[:]).Uint64()
}

func (w Word) IsZero() bool {
	for _, b := range w {
		if b != 0 {
			return false
		}
	}
	return true
}

func (w Word) Hex() string {
	return "0x" + hex.EncodeToString(w[:])
}

func WordFromUint64(v uint64) Word {
	var w Word
	binary.BigEndian.PutUint64(w[24:], v)
	return w
}

func WordFromBigInt(z *big.Int) Word {
	var w Word
	if z == nil {
		return w
	}
	z.FillBytes(w[:])
	return w
}

func WordFromBytes(b []byte) Word {
	var w Word
	copy(w[32-len(b):], b)
	return w
}

// OpCode 操作码定义（兼容EVM Istanbul/London标准）
type OpCode byte

// 标准操作码（与EVM一致）
const (
	// 停止与算术
	STOP       OpCode = 0x00
	ADD        OpCode = 0x01
	MUL        OpCode = 0x02
	SUB        OpCode = 0x03
	DIV        OpCode = 0x04
	SDIV       OpCode = 0x05
	MOD        OpCode = 0x06
	SMOD       OpCode = 0x07
	ADDMOD     OpCode = 0x08
	MULMOD     OpCode = 0x09
	EXP        OpCode = 0x0a
	SIGNEXTEND OpCode = 0x0b

	// 比较与位运算
	LT     OpCode = 0x10
	GT     OpCode = 0x11
	SLT    OpCode = 0x12
	SGT    OpCode = 0x13
	EQ     OpCode = 0x14
	ISZERO OpCode = 0x15
	AND    OpCode = 0x16
	OR     OpCode = 0x17
	XOR    OpCode = 0x18
	NOT    OpCode = 0x19
	BYTE   OpCode = 0x1a
	SHL    OpCode = 0x1b // EIP-145
	SHR    OpCode = 0x1c // EIP-145
	SAR    OpCode = 0x1d // EIP-145

	// 内存与栈操作
	POP     OpCode = 0x50
	MLOAD   OpCode = 0x51
	MSTORE  OpCode = 0x52
	MSTORE8 OpCode = 0x53
	MSIZE   OpCode = 0x59

	// 跳转
	JUMP     OpCode = 0x56
	JUMPI    OpCode = 0x57
	PC       OpCode = 0x58
	JUMPDEST OpCode = 0x5b

	// 压栈操作（PUSH1-PUSH32）
	PUSH1 OpCode = 0x60 + iota
	// ...
	PUSH32 OpCode = 0x7f

	// 复制操作（DUP1-DUP16）
	DUP1 OpCode = 0x80 + iota
	// ...
	DUP16 OpCode = 0x8f

	// 交换操作（SWAP1-SWAP16）
	SWAP1 OpCode = 0x90 + iota
	// ...
	SWAP16 OpCode = 0x9f

	// 自定义扩展操作码（不影响标准EVM兼容区）
	SAVE     OpCode = 0xfb // 保存状态哈希到栈
	SNAPSHOT OpCode = 0xfc // 创建完整快照
	RESTORE  OpCode = 0xfd // 从快照恢复
	INVALID  OpCode = 0xfe // 无效操作
)

func (op OpCode) String() string {
	switch op {
	case STOP:
		return "STOP"
	case ADD:
		return "ADD"
	case MUL:
		return "MUL"
	case SUB:
		return "SUB"
	case DIV:
		return "DIV"
	case MOD:
		return "MOD"
	case EXP:
		return "EXP"
	case LT:
		return "LT"
	case GT:
		return "GT"
	case EQ:
		return "EQ"
	case ISZERO:
		return "ISZERO"
	case AND:
		return "AND"
	case OR:
		return "OR"
	case XOR:
		return "XOR"
	case NOT:
		return "NOT"
	case SHL:
		return "SHL"
	case SHR:
		return "SHR"
	case SAR:
		return "SAR"
	case MLOAD:
		return "MLOAD"
	case MSTORE:
		return "MSTORE"
	case MSTORE8:
		return "MSTORE8"
	case MSIZE:
		return "MSIZE"
	case POP:
		return "POP"
	case PUSH1:
		return "PUSH1"
	case PUSH32:
		return "PUSH32"
	case DUP1:
		return "DUP1"
	case SWAP1:
		return "SWAP1"
	case JUMP:
		return "JUMP"
	case JUMPI:
		return "JUMPI"
	case PC:
		return "PC"
	case JUMPDEST:
		return "JUMPDEST"
	case SAVE:
		return "SAVE"
	case SNAPSHOT:
		return "SNAPSHOT"
	case RESTORE:
		return "RESTORE"
	default:
		if op >= PUSH1 && op <= PUSH32 {
			return fmt.Sprintf("PUSH%d", int(op-PUSH1)+1)
		}
		if op >= DUP1 && op <= DUP16 {
			return fmt.Sprintf("DUP%d", int(op-DUP1)+1)
		}
		if op >= SWAP1 && op <= SWAP16 {
			return fmt.Sprintf("SWAP%d", int(op-SWAP1)+1)
		}
		return fmt.Sprintf("0x%x", byte(op))
	}
}

// IsPush 检查是否为PUSH操作
func (op OpCode) IsPush() bool {
	return op >= PUSH1 && op <= PUSH32
}

// PushSize 返回PUSH操作的字节数
func (op OpCode) PushSize() uint64 {
	if !op.IsPush() {
		return 0
	}
	return uint64(op - PUSH1 + 1)
}
