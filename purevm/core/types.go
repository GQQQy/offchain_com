package core

import (
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"strings"
)

var (
	wordModulus = new(big.Int).Lsh(big.NewInt(1), 256)
)

// Word 256位整数（与EVM一致的大端序表示）
type Word [32]byte

func (w Word) BigInt() *big.Int {
	return new(big.Int).SetBytes(w[:])
}

func (w Word) SignedBigInt() *big.Int {
	z := w.BigInt()
	if w[0]&0x80 != 0 {
		z.Sub(z, wordModulus)
	}
	return z
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

func (w Word) MarshalJSON() ([]byte, error) {
	return json.Marshal(w.Hex())
}

func (w *Word) UnmarshalJSON(data []byte) error {
	var raw string
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}

	raw = strings.TrimPrefix(strings.TrimPrefix(raw, "0x"), "0X")
	if len(raw) > 64 {
		return fmt.Errorf("word hex too long: %d", len(raw))
	}
	if len(raw)%2 == 1 {
		raw = "0" + raw
	}

	decoded, err := hex.DecodeString(raw)
	if err != nil {
		return err
	}

	*w = Word{}
	copy(w[32-len(decoded):], decoded)
	return nil
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
	mod := new(big.Int).Mod(new(big.Int).Set(z), wordModulus)
	if mod.Sign() < 0 {
		mod.Add(mod, wordModulus)
	}
	mod.FillBytes(w[:])
	return w
}

func WordFromSignedBigInt(z *big.Int) Word {
	return WordFromBigInt(z)
}

func WordFromBytes(b []byte) Word {
	var w Word
	if len(b) > len(w) {
		b = b[len(b)-len(w):]
	}
	copy(w[32-len(b):], b)
	return w
}

// OpCode 操作码定义（兼容EVM Istanbul/London标准）
type OpCode byte

// 标准操作码（与EVM一致的常用子集）
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
	SHL    OpCode = 0x1b
	SHR    OpCode = 0x1c
	SAR    OpCode = 0x1d

	// 内存与栈操作
	POP      OpCode = 0x50
	MLOAD    OpCode = 0x51
	MSTORE   OpCode = 0x52
	MSTORE8  OpCode = 0x53
	JUMP     OpCode = 0x56
	JUMPI    OpCode = 0x57
	PC       OpCode = 0x58
	MSIZE    OpCode = 0x59
	GAS      OpCode = 0x5a
	JUMPDEST OpCode = 0x5b

	// 压栈操作（PUSH1-PUSH32）
	PUSH1  OpCode = 0x60
	PUSH2  OpCode = 0x61
	PUSH3  OpCode = 0x62
	PUSH4  OpCode = 0x63
	PUSH5  OpCode = 0x64
	PUSH6  OpCode = 0x65
	PUSH7  OpCode = 0x66
	PUSH8  OpCode = 0x67
	PUSH9  OpCode = 0x68
	PUSH10 OpCode = 0x69
	PUSH11 OpCode = 0x6a
	PUSH12 OpCode = 0x6b
	PUSH13 OpCode = 0x6c
	PUSH14 OpCode = 0x6d
	PUSH15 OpCode = 0x6e
	PUSH16 OpCode = 0x6f
	PUSH17 OpCode = 0x70
	PUSH18 OpCode = 0x71
	PUSH19 OpCode = 0x72
	PUSH20 OpCode = 0x73
	PUSH21 OpCode = 0x74
	PUSH22 OpCode = 0x75
	PUSH23 OpCode = 0x76
	PUSH24 OpCode = 0x77
	PUSH25 OpCode = 0x78
	PUSH26 OpCode = 0x79
	PUSH27 OpCode = 0x7a
	PUSH28 OpCode = 0x7b
	PUSH29 OpCode = 0x7c
	PUSH30 OpCode = 0x7d
	PUSH31 OpCode = 0x7e
	PUSH32 OpCode = 0x7f

	// 复制操作（DUP1-DUP16）
	DUP1  OpCode = 0x80
	DUP2  OpCode = 0x81
	DUP3  OpCode = 0x82
	DUP4  OpCode = 0x83
	DUP5  OpCode = 0x84
	DUP6  OpCode = 0x85
	DUP7  OpCode = 0x86
	DUP8  OpCode = 0x87
	DUP9  OpCode = 0x88
	DUP10 OpCode = 0x89
	DUP11 OpCode = 0x8a
	DUP12 OpCode = 0x8b
	DUP13 OpCode = 0x8c
	DUP14 OpCode = 0x8d
	DUP15 OpCode = 0x8e
	DUP16 OpCode = 0x8f

	// 交换操作（SWAP1-SWAP16）
	SWAP1  OpCode = 0x90
	SWAP2  OpCode = 0x91
	SWAP3  OpCode = 0x92
	SWAP4  OpCode = 0x93
	SWAP5  OpCode = 0x94
	SWAP6  OpCode = 0x95
	SWAP7  OpCode = 0x96
	SWAP8  OpCode = 0x97
	SWAP9  OpCode = 0x98
	SWAP10 OpCode = 0x99
	SWAP11 OpCode = 0x9a
	SWAP12 OpCode = 0x9b
	SWAP13 OpCode = 0x9c
	SWAP14 OpCode = 0x9d
	SWAP15 OpCode = 0x9e
	SWAP16 OpCode = 0x9f

	// 自定义扩展操作码（不影响标准EVM兼容区）
	SAVE     OpCode = 0xfb
	SNAPSHOT OpCode = 0xfc
	RESTORE  OpCode = 0xfd
	INVALID  OpCode = 0xfe
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
	case SDIV:
		return "SDIV"
	case MOD:
		return "MOD"
	case SMOD:
		return "SMOD"
	case ADDMOD:
		return "ADDMOD"
	case MULMOD:
		return "MULMOD"
	case EXP:
		return "EXP"
	case SIGNEXTEND:
		return "SIGNEXTEND"
	case LT:
		return "LT"
	case GT:
		return "GT"
	case SLT:
		return "SLT"
	case SGT:
		return "SGT"
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
	case BYTE:
		return "BYTE"
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
	case GAS:
		return "GAS"
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
