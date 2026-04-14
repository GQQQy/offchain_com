package core

import (
	"encoding/json"
	"os"
)

// WriteFile 将快照按缩进JSON写入本地文件。
func (s *StandardSnapshot) WriteFile(path string) error {
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}

// ReadSnapshotFile 从本地文件读取快照。
func ReadSnapshotFile(path string) (*StandardSnapshot, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return DeserializeSnapshot(data)
}
