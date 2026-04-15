package core

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/ethereum/go-ethereum/common"
)

// SnapshotIndex 描述一组可恢复、可相邻验证的快照。
type SnapshotIndex struct {
	Version              uint16               `json:"version"`
	CreatedAtUnix        int64                `json:"created_at_unix"`
	ChainID              uint64               `json:"chain_id"`
	BytecodeHex          string               `json:"bytecode_hex,omitempty"`
	TotalGas             uint64               `json:"total_gas"`
	SnapshotThresholdGas uint64               `json:"snapshot_threshold_gas"`
	Meta                 map[string]string    `json:"meta,omitempty"`
	Snapshots            []SnapshotIndexEntry `json:"snapshots"`
}

// SnapshotIndexEntry 记录单个快照及其到下一个快照的验证信息。
type SnapshotIndexEntry struct {
	Ordinal             int         `json:"ordinal"`
	SnapshotFile        string      `json:"snapshot_file"`
	StepNumber          uint64      `json:"step_number"`
	GasUsed             uint64      `json:"gas_used"`
	GasRemaining        uint64      `json:"gas_remaining"`
	StateRoot           common.Hash `json:"state_root"`
	NextOrdinal         *int        `json:"next_ordinal,omitempty"`
	AdjacentProofFile   string      `json:"adjacent_proof_file,omitempty"`
	AdjacentProofSteps  uint64      `json:"adjacent_proof_steps,omitempty"`
	AdjacentProofIsFull bool        `json:"adjacent_proof_is_full,omitempty"`
}

// NewSnapshotIndex 创建新的快照索引。
func NewSnapshotIndex(chainID, totalGas, thresholdGas uint64) *SnapshotIndex {
	return &SnapshotIndex{
		Version:              1,
		CreatedAtUnix:        time.Now().Unix(),
		ChainID:              chainID,
		TotalGas:             totalGas,
		SnapshotThresholdGas: thresholdGas,
		Snapshots:            make([]SnapshotIndexEntry, 0),
	}
}

// AddSnapshot 添加快照条目。
func (idx *SnapshotIndex) AddSnapshot(snapshotFile string, snap *StandardSnapshot, gasUsed uint64) {
	entry := SnapshotIndexEntry{
		Ordinal:      len(idx.Snapshots),
		SnapshotFile: snapshotFile,
		StepNumber:   snap.Header.StepNumber,
		GasUsed:      gasUsed,
		GasRemaining: snap.State.Gas,
		StateRoot:    snap.Header.StateRoot,
	}

	if len(idx.Snapshots) > 0 {
		prev := &idx.Snapshots[len(idx.Snapshots)-1]
		nextOrdinal := entry.Ordinal
		prev.NextOrdinal = &nextOrdinal
	}

	idx.Snapshots = append(idx.Snapshots, entry)
}

// SetAdjacentProof 更新某个快照到下一个快照的证明元数据。
func (idx *SnapshotIndex) SetAdjacentProof(ordinal int, proofFile string, proofSteps uint64, full bool) error {
	entry, err := idx.Entry(ordinal)
	if err != nil {
		return err
	}
	entry.AdjacentProofFile = proofFile
	entry.AdjacentProofSteps = proofSteps
	entry.AdjacentProofIsFull = full
	return nil
}

// Entry 返回指定编号的快照条目。
func (idx *SnapshotIndex) Entry(ordinal int) (*SnapshotIndexEntry, error) {
	if ordinal < 0 || ordinal >= len(idx.Snapshots) {
		return nil, fmt.Errorf("snapshot ordinal out of range: %d", ordinal)
	}
	return &idx.Snapshots[ordinal], nil
}

// AdjacentEntries 返回某个快照及其相邻的下一个快照。
func (idx *SnapshotIndex) AdjacentEntries(ordinal int) (*SnapshotIndexEntry, *SnapshotIndexEntry, error) {
	current, err := idx.Entry(ordinal)
	if err != nil {
		return nil, nil, err
	}
	if current.NextOrdinal == nil {
		return nil, nil, fmt.Errorf("snapshot %d has no adjacent next snapshot", ordinal)
	}
	next, err := idx.Entry(*current.NextOrdinal)
	if err != nil {
		return nil, nil, err
	}
	return current, next, nil
}

// ValidateAdjacentThreshold 检查相邻快照是否满足“单段执行权重不超过阈值”的基础约束。
// 更严格的“下一步会越阈值所以在这里切快照”由重放时的快照 hash 比较来保证。
func (idx *SnapshotIndex) ValidateAdjacentThreshold(start, end *SnapshotIndexEntry) error {
	if idx.SnapshotThresholdGas == 0 {
		return nil
	}
	if end.GasUsed <= start.GasUsed {
		return fmt.Errorf("non-increasing gas used: start=%d end=%d", start.GasUsed, end.GasUsed)
	}
	if end.StepNumber <= start.StepNumber {
		return fmt.Errorf("non-increasing step number: start=%d end=%d", start.StepNumber, end.StepNumber)
	}

	segmentGasUsed := end.GasUsed - start.GasUsed
	if segmentGasUsed > idx.SnapshotThresholdGas {
		return fmt.Errorf(
			"adjacent snapshot segment exceeds threshold: segment=%d threshold=%d",
			segmentGasUsed,
			idx.SnapshotThresholdGas,
		)
	}

	return nil
}

// WriteFile 将快照索引写入本地文件。
func (idx *SnapshotIndex) WriteFile(path string) error {
	data, err := json.MarshalIndent(idx, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}

// ReadSnapshotIndexFile 从本地文件读取快照索引。
func ReadSnapshotIndexFile(path string) (*SnapshotIndex, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	var idx SnapshotIndex
	if err := json.Unmarshal(data, &idx); err != nil {
		return nil, err
	}
	return &idx, nil
}

// ResolvePath 将索引中的相对路径解析为实际文件路径。
func (idx *SnapshotIndex) ResolvePath(indexPath, relativeOrAbsolute string) string {
	if filepath.IsAbs(relativeOrAbsolute) {
		return relativeOrAbsolute
	}
	return filepath.Join(filepath.Dir(indexPath), relativeOrAbsolute)
}
