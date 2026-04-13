package core

import (
	"encoding/json"
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

// VMState 标准VM状态（完全可序列化）
type VMState struct {
	// 执行上下文
	PC     uint64 `json:"pc"`
	Stack  []Word `json:"stack"`
	Memory []byte `json:"memory"`
	Gas    uint64 `json:"gas"`
	Refund uint64 `json:"refund"`

	// 代码与元数据
	Code     []byte      `json:"code"`
	CodeHash common.Hash `json:"code_hash"`

	// 执行统计
	StepCount uint64 `json:"step_count"`

	// 可选上下文（用于复杂场景）
	CallValue *big.Int `json:"call_value,omitempty"`
	CallData  []byte   `json:"call_data,omitempty"`
}

// NewState 创建初始状态
func NewState(code []byte, gasLimit uint64) *VMState {
	return &VMState{
		PC:        0,
		Stack:     make([]Word, 0),
		Memory:    make([]byte, 0),
		Gas:       gasLimit,
		Refund:    0,
		Code:      code,
		CodeHash:  crypto.Keccak256Hash(code),
		StepCount: 0,
	}
}

// SerializeCanonical 确定性序列化（保证跨平台哈希一致）
func (s *VMState) SerializeCanonical() []byte {
	// 使用canonical JSON：字段有序，无空格，16进制编码字节数组
	type CanonicalState struct {
		PC        uint64   `json:"pc"`
		Stack     []string `json:"stack"`  // 0x前缀的hex字符串
		Memory    string   `json:"memory"` // 0x前缀的hex
		Gas       uint64   `json:"gas"`
		Refund    uint64   `json:"refund"`
		CodeHash  string   `json:"code_hash"`
		StepCount uint64   `json:"step_count"`
	}

	cs := CanonicalState{
		PC:        s.PC,
		Stack:     make([]string, len(s.Stack)),
		Memory:    "0x" + common.Bytes2Hex(s.Memory),
		Gas:       s.Gas,
		Refund:    s.Refund,
		CodeHash:  s.CodeHash.Hex(),
		StepCount: s.StepCount,
	}

	for i, w := range s.Stack {
		cs.Stack[i] = w.Hex()
	}

	// 确保字段顺序一致（Go json默认按字段定义顺序）
	data, _ := json.Marshal(cs)
	return data
}

// Hash 计算状态哈希（Keccak256，与以太坊兼容）
func (s *VMState) Hash() common.Hash {
	return crypto.Keccak256Hash(s.SerializeCanonical())
}

// Clone 深拷贝状态（用于快照）
func (s *VMState) Clone() *VMState {
	newState := &VMState{
		PC:        s.PC,
		Stack:     make([]Word, len(s.Stack)),
		Memory:    make([]byte, len(s.Memory)),
		Gas:       s.Gas,
		Refund:    s.Refund,
		Code:      make([]byte, len(s.Code)),
		CodeHash:  s.CodeHash,
		StepCount: s.StepCount,
		CallValue: new(big.Int),
		CallData:  make([]byte, len(s.CallData)),
	}

	copy(newState.Stack, s.Stack)
	copy(newState.Memory, s.Memory)
	copy(newState.Code, s.Code)
	if s.CallValue != nil {
		newState.CallValue.Set(s.CallValue)
	}
	copy(newState.CallData, s.CallData)

	return newState
}

// MemoryExpansionCost 计算内存扩展成本（EIP-150公式）
func (s *VMState) MemoryExpansionCost(newSize uint64) uint64 {
	oldSize := uint64(len(s.Memory))
	if newSize <= oldSize {
		return 0
	}

	// EIP-150: memory_cost = (memory_size_words ^ 2) / 512 + (3 * memory_size_words)
	oldWords := (oldSize + 31) / 32
	newWords := (newSize + 31) / 32

	oldTotal := (oldWords*oldWords)/512 + 3*oldWords
	newTotal := (newWords*newWords)/512 + 3*newWords

	return newTotal - oldTotal
}

// ExpandMemory 扩展内存到指定大小
func (s *VMState) ExpandMemory(newSize uint64) {
	if newSize > uint64(len(s.Memory)) {
		newMem := make([]byte, newSize)
		copy(newMem, s.Memory)
		s.Memory = newMem
	}
}

// StackPush 压栈（自动检查溢出）
func (s *VMState) StackPush(w Word) error {
	if len(s.Stack) >= 1024 {
		return fmt.Errorf("stack overflow")
	}
	s.Stack = append(s.Stack, w)
	return nil
}

// StackPop 弹栈（自动检查下溢）
func (s *VMState) StackPop() (Word, error) {
	if len(s.Stack) == 0 {
		return Word{}, fmt.Errorf("stack underflow")
	}
	val := s.Stack[len(s.Stack)-1]
	s.Stack = s.Stack[:len(s.Stack)-1]
	return val, nil
}

// StackPeek 查看栈顶（不弹出）
func (s *VMState) StackPeek() (Word, error) {
	if len(s.Stack) == 0 {
		return Word{}, fmt.Errorf("stack underflow")
	}
	return s.Stack[len(s.Stack)-1], nil
}

// GetStackDepth 获取当前栈深度
func (s *VMState) GetStackDepth() int {
	return len(s.Stack)
}
