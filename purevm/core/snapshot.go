package core

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"time"

	"github.com/ethereum/go-ethereum/common"
)

// SnapshotHeaderV1 快照头版本1（标准化格式）
type SnapshotHeaderV1 struct {
	Version     uint16      `json:"version"`
	ChainID     uint64      `json:"chain_id"`
	BlockHeight uint64      `json:"block_height"`
	Timestamp   uint64      `json:"timestamp"`
	StateRoot   common.Hash `json:"state_root"`  // Keccak256(state)
	CodeHash    common.Hash `json:"code_hash"`   // 代码哈希（防篡改）
	StepNumber  uint64      `json:"step_number"` // 执行到第几步
	GasRemaining uint64     `json:"gas_remaining"`
}

// StandardSnapshot 标准快照（链下保存/链上验证的统一格式）
type StandardSnapshot struct {
	Header SnapshotHeaderV1 `json:"header"`
	State  VMState          `json:"state"`

	// 额外元数据（不进入哈希计算）
	Meta map[string]string `json:"meta,omitempty"`
}

// NewStandardSnapshot 创建标准快照
func NewStandardSnapshot(state *VMState, chainID uint64) *StandardSnapshot {
	stateRoot := state.Hash()

	return &StandardSnapshot{
		Header: SnapshotHeaderV1{
			Version:     1,
			ChainID:     chainID,
			BlockHeight: 0, // 由调用者更新
			Timestamp:   uint64(time.Now().Unix()),
			StateRoot:   stateRoot,
			CodeHash:    state.CodeHash,
			StepNumber:  state.StepCount,
			GasRemaining: state.Gas,
		},
		State: *state.Clone(),
	}
}

// Serialize 完整序列化（用于存储和网络传输）
func (s *StandardSnapshot) Serialize() ([]byte, error) {
	return json.Marshal(s)
}

// Deserialize 反序列化
func DeserializeSnapshot(data []byte) (*StandardSnapshot, error) {
	var snap StandardSnapshot
	if err := json.Unmarshal(data, &snap); err != nil {
		return nil, err
	}
	return &snap, nil
}

// VerifyIntegrity 验证快照完整性（哈希匹配）
func (s *StandardSnapshot) VerifyIntegrity() error {
	calcHash := s.State.Hash()
	if calcHash != s.Header.StateRoot {
		return fmt.Errorf("integrity check failed: calculated %s, header claims %s",
			calcHash.Hex(), s.Header.StateRoot.Hex())
	}
	return nil
}

// EncodeForPrecompile 编码为预编译合约输入格式
func (s *StandardSnapshot) EncodeForPrecompile() []byte {
	// 格式: [version:2][chain_id:8][state_root:32][serialized_state:var]
	buf := make([]byte, 0, 42+len(s.State.SerializeCanonical()))

	ver := make([]byte, 2)
	binary.BigEndian.PutUint16(ver, s.Header.Version)
	buf = append(buf, ver...)

	chain := make([]byte, 8)
	binary.BigEndian.PutUint64(chain, s.Header.ChainID)
	buf = append(buf, chain...)

	buf = append(buf, s.Header.StateRoot[:]...)
	buf = append(buf, s.State.SerializeCanonical()...)

	return buf
}

// TransitionLink 描述两个快照之间已验证的状态转移。
type TransitionLink struct {
	InitialRoot common.Hash `json:"initial_root"`
	FinalRoot   common.Hash `json:"final_root"`
	StartStep   uint64      `json:"start_step"`
	EndStep     uint64      `json:"end_step"`
	TraceRoot   common.Hash `json:"trace_root"`
}

// SnapshotSequence 快照序列（用于分片验证）
type SnapshotSequence struct {
	Snapshots []*StandardSnapshot `json:"snapshots"`
	Links     []TransitionLink    `json:"links"` // 相邻快照间的转移摘要
}

// AddSnapshot 添加快照到序列（自动验证连续性）
func (seq *SnapshotSequence) AddSnapshot(snap *StandardSnapshot, link *TransitionLink) error {
	if len(seq.Snapshots) > 0 {
		last := seq.Snapshots[len(seq.Snapshots)-1]
		// 验证步骤连续性
		if snap.Header.StepNumber <= last.Header.StepNumber {
			return fmt.Errorf("non-increasing step number: last %d, new %d",
				last.Header.StepNumber, snap.Header.StepNumber)
		}
		// 如果有转移摘要，验证其能连接前后快照
		if link != nil {
			if link.InitialRoot != last.Header.StateRoot {
				return fmt.Errorf("proof initial hash mismatch")
			}
			if link.FinalRoot != snap.Header.StateRoot {
				return fmt.Errorf("proof final hash mismatch")
			}
		}
	}

	seq.Snapshots = append(seq.Snapshots, snap)
	if link != nil {
		seq.Links = append(seq.Links, *link)
	}
	return nil
}
