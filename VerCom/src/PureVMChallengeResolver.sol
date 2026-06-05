// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IOptimisticChallengeResolver} from "./interfaces/IOptimisticChallengeResolver.sol";
import {PureVMTaskManager} from "./PureVMTaskManager.sol";
import {PureVMTypes} from "./PureVMTypes.sol";

contract PureVMChallengeResolver is IOptimisticChallengeResolver {
    uint256 public constant MAX_CHALLENGE_DATA_BYTES = 1_320_000;
    uint256 public constant MAX_DIRECT_SNAPSHOT_BYTES = 262_144;
    uint256 public constant MAX_PROOF_BYTES = 1_048_576;

    struct ChallengePayload {
        bytes32 pureVMTaskId;
        uint32 fromOrdinal;
        PureVMTypes.CheckpointInput nextCheckpoint;
        bytes startSnapshotBytes;
        bytes proofBytes;
    }

    PureVMTaskManager public immutable taskManager;

    error OptimisticTaskNotBoundToCheckpoint(bytes32 got, bytes32 want);
    error ChallengePayloadTooLarge(string field, uint256 size, uint256 limit);

    constructor(address taskManager_) {
        taskManager = PureVMTaskManager(taskManager_);
    }

    function validateChallenge(
        address challenger,
        bytes32 optimisticTaskId,
        bytes32 summaryHash,
        bytes32 claimedResultHash,
        bytes32 claimedStateRoot,
        bytes calldata challengeData
    ) external override returns (bool success, bytes32 actualResultHash, bytes32 actualStateRoot) {
        if (challengeData.length > MAX_CHALLENGE_DATA_BYTES) {
            revert ChallengePayloadTooLarge("challengeData", challengeData.length, MAX_CHALLENGE_DATA_BYTES);
        }

        ChallengePayload memory payload = abi.decode(challengeData, (ChallengePayload));
        if (payload.startSnapshotBytes.length > MAX_DIRECT_SNAPSHOT_BYTES) {
            revert ChallengePayloadTooLarge(
                "startSnapshotBytes", payload.startSnapshotBytes.length, MAX_DIRECT_SNAPSHOT_BYTES
            );
        }
        if (payload.proofBytes.length > MAX_PROOF_BYTES) {
            revert ChallengePayloadTooLarge("proofBytes", payload.proofBytes.length, MAX_PROOF_BYTES);
        }

        uint32 toOrdinal = payload.fromOrdinal + 1;

        bytes32 expectedSummaryHash = taskManager.checkpointTaskSummaryHash(payload.pureVMTaskId, toOrdinal);
        if (summaryHash != expectedSummaryHash) {
            revert OptimisticTaskNotBoundToCheckpoint(summaryHash, expectedSummaryHash);
        }

        bytes32 disputeId = keccak256(
            abi.encode(
                "PUREVM_DISPUTE",
                optimisticTaskId,
                challenger,
                payload.pureVMTaskId,
                payload.fromOrdinal,
                claimedResultHash,
                claimedStateRoot,
                keccak256(payload.startSnapshotBytes),
                keccak256(payload.proofBytes),
                block.number
            )
        );

        (success, actualResultHash, actualStateRoot) = taskManager.resolveDispute(
            disputeId,
            payload.pureVMTaskId,
            payload.fromOrdinal,
            payload.nextCheckpoint,
            payload.startSnapshotBytes,
            payload.proofBytes,
            claimedResultHash,
            claimedStateRoot,
            challenger
        );
    }
}
