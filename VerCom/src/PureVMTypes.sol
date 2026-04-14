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
}
