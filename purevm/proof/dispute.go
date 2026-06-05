package proof

import (
	"fmt"

	"purevm/core"

	"github.com/ethereum/go-ethereum/common"
)

// DivergentSegment describes the first segment where an executor checkpoint
// sequence disagrees with a validator's independently replayed sequence.
type DivergentSegment struct {
	Found               bool        `json:"found"`
	FromOrdinal         int         `json:"from_ordinal"`
	ToOrdinal           int         `json:"to_ordinal"`
	SharedStartRoot     common.Hash `json:"shared_start_root"`
	ClaimedNextRoot     common.Hash `json:"claimed_next_root"`
	VerifiedNextRoot    common.Hash `json:"verified_next_root"`
	ClaimedNextMissing  bool        `json:"claimed_next_missing,omitempty"`
	VerifiedNextMissing bool        `json:"verified_next_missing,omitempty"`
	Reason              string      `json:"reason,omitempty"`
}

// FindFirstDivergentSegment returns the earliest checkpoint segment whose
// next commitment differs after a common prefix.
func FindFirstDivergentSegment(claimed, verified *core.SnapshotIndex) (*DivergentSegment, error) {
	if claimed == nil || verified == nil {
		return nil, fmt.Errorf("snapshot indexes must not be nil")
	}
	if len(claimed.Snapshots) == 0 || len(verified.Snapshots) == 0 {
		return nil, fmt.Errorf("snapshot indexes must not be empty")
	}

	claimedInitial := claimed.Snapshots[0]
	verifiedInitial := verified.Snapshots[0]
	if claimedInitial.StateRoot != verifiedInitial.StateRoot {
		return nil, fmt.Errorf(
			"initial checkpoint root mismatch: claimed=%s verified=%s",
			claimedInitial.StateRoot.Hex(),
			verifiedInitial.StateRoot.Hex(),
		)
	}

	limit := len(claimed.Snapshots)
	if len(verified.Snapshots) < limit {
		limit = len(verified.Snapshots)
	}

	for i := 1; i < limit; i++ {
		claimedEntry := claimed.Snapshots[i]
		verifiedEntry := verified.Snapshots[i]
		if claimedEntry.Ordinal != i || verifiedEntry.Ordinal != i {
			return nil, fmt.Errorf("non-canonical ordinal at position %d", i)
		}
		if claimedEntry.StateRoot != verifiedEntry.StateRoot {
			startRoot := claimed.Snapshots[i-1].StateRoot
			if verified.Snapshots[i-1].StateRoot != startRoot {
				return nil, fmt.Errorf("internal error: common prefix broke before ordinal %d", i)
			}
			return &DivergentSegment{
				Found:            true,
				FromOrdinal:      i - 1,
				ToOrdinal:        i,
				SharedStartRoot:  startRoot,
				ClaimedNextRoot:  claimedEntry.StateRoot,
				VerifiedNextRoot: verifiedEntry.StateRoot,
				Reason:           "next checkpoint root mismatch",
			}, nil
		}
	}

	if len(claimed.Snapshots) != len(verified.Snapshots) {
		fromOrdinal := limit - 1
		result := &DivergentSegment{
			Found:           true,
			FromOrdinal:     fromOrdinal,
			ToOrdinal:       limit,
			SharedStartRoot: claimed.Snapshots[fromOrdinal].StateRoot,
			Reason:          "checkpoint sequence length mismatch after common prefix",
		}
		if len(claimed.Snapshots) > limit {
			result.ClaimedNextRoot = claimed.Snapshots[limit].StateRoot
			result.VerifiedNextMissing = true
		} else {
			result.VerifiedNextRoot = verified.Snapshots[limit].StateRoot
			result.ClaimedNextMissing = true
		}
		return result, nil
	}

	return &DivergentSegment{Found: false, Reason: "checkpoint roots match"}, nil
}
