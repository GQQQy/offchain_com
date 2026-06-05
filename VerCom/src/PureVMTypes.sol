// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

library PureVMTypes {
    struct TaskCreation {
        address verifier;
        bytes32 codeHash;
        uint64 totalGas;
        uint64 snapshotThresholdGas;
        uint64 pureVMChainId;
        bytes32 initialStateRoot;
        bytes32 initialSnapshotHash;
        string initialSnapshotURI;
    }

    struct TaskConfig {
        address owner;
        address verifier;
        bytes32 codeHash;
        uint64 totalGas;
        uint64 snapshotThresholdGas;
        uint64 pureVMChainId;
        bytes32 initialStateRoot;
        uint32 latestVerifiedOrdinal;
        uint32 checkpointCount;
        bool finalized;
        bool exists;
    }

    struct CheckpointInput {
        uint64 stepNumber;
        uint64 gasUsed;
        uint64 gasRemaining;
        bytes32 stateRoot;
        bytes32 snapshotBlobHash;
        string snapshotURI;
    }

    struct CheckpointMeta {
        uint32 ordinal;
        uint64 stepNumber;
        uint64 gasUsed;
        uint64 gasRemaining;
        bytes32 stateRoot;
        bytes32 snapshotBlobHash;
        string snapshotURI;
        bool exists;
        bool verified;
    }

    struct AdjacentProofMeta {
        uint32 fromOrdinal;
        uint32 toOrdinal;
        uint64 proofSteps;
        bool fullProof;
        bytes32 proofBlobHash;
        bytes32 traceRoot;
        string proofURI;
        uint64 verifiedAtBlock;
    }

    enum DisputeStatus {
        None,
        Resolved
    }

    struct DisputeMeta {
        bytes32 taskId;
        uint32 fromOrdinal;
        uint32 toOrdinal;
        bytes32 claimedResultHash;
        bytes32 actualResultHash;
        bytes32 claimedStateRoot;
        bytes32 actualStateRoot;
        bytes32 traceRoot;
        uint64 verifiedSteps;
        address challenger;
        bool challengerWon;
        DisputeStatus status;
        uint64 resolvedAtBlock;
    }

    enum DataKind {
        Unknown,
        Snapshot,
        Proof,
        Subdivision
    }

    struct DataAvailabilityMeta {
        bytes32 taskId;
        DataKind kind;
        uint32 ordinal;
        bytes32 dataHash;
        bytes32 semanticHash;
        uint64 size;
        string uri;
        address publisher;
        uint64 registeredAtBlock;
        bool available;
    }

    struct SubdivisionCommitment {
        uint32 index;
        uint64 stepNumber;
        uint64 gasUsed;
        bytes32 stateRoot;
        bytes32 snapshotBlobHash;
    }

    struct DisputeGameCreation {
        bytes32 taskId;
        uint32 fromOrdinal;
        uint32 toOrdinal;
        address executor;
        address challenger;
        bytes32 claimedResultHash;
        bytes32 claimedStateRoot;
        bytes32 claimedSnapshotBlobHash;
        bytes32 challengerStateRoot;
        bytes32 challengerSnapshotBlobHash;
        uint64 claimedStepNumber;
        uint64 claimedGasUsed;
        uint64 adjudicationThresholdGas;
        uint8 maxRounds;
        uint64 roundDuration;
        uint256 baseStake;
    }

    enum DisputeGameStatus {
        None,
        Open,
        Staking,
        ReadyForFinal,
        Resolved
    }

    enum DisputeWinner {
        None,
        Executor,
        Challenger,
        BothWrong
    }

    struct DisputeGame {
        bytes32 taskId;
        uint32 fromOrdinal;
        uint32 toOrdinal;
        address executor;
        address challenger;
        bytes32 claimedResultHash;
        bytes32 claimedStateRoot;
        bytes32 claimedSnapshotBlobHash;
        uint64 claimedStepNumber;
        uint64 claimedGasUsed;
        uint64 adjudicationThresholdGas;
        uint8 maxRounds;
        uint8 currentRound;
        uint64 roundDeadline;
        uint64 roundDuration;
        uint256 baseStake;
        uint256 executorStake;
        uint256 challengerStake;
        bytes32 executorSubdivisionRoot;
        bytes32 challengerSubdivisionRoot;
        uint32 divergenceIndex;
        bytes32 commonRoot;
        bytes32 executorRoot;
        bytes32 challengerRoot;
        bytes32 commonSnapshotBlobHash;
        bytes32 executorSnapshotBlobHash;
        bytes32 challengerSnapshotBlobHash;
        uint64 commonStep;
        uint64 targetStep;
        uint64 commonGasUsed;
        uint64 targetGasUsed;
        DisputeGameStatus status;
        DisputeWinner winner;
        uint64 resolvedAtBlock;
    }
}
