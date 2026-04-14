// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IOptimisticChallengeResolver} from "./interfaces/IOptimisticChallengeResolver.sol";
import {PureVMTaskManager} from "./PureVMTaskManager.sol";
import {PureVMTypes} from "./PureVMTypes.sol";

contract PureVMChallengeResolver is IOptimisticChallengeResolver {
    struct ChallengePayload {
        bytes32 pureVMTaskId;
        uint32 fromOrdinal;
        PureVMTypes.CheckpointInput nextCheckpoint;
        bytes startSnapshotBytes;
        bytes proofBytes;
    }

    PureVMTaskManager public immutable taskManager;

    constructor(address taskManager_) {
        taskManager = PureVMTaskManager(taskManager_);
    }

    function validateChallenge(
        bytes32,
        bytes32,
        bytes32 claimedResultHash,
        bytes32 claimedStateRoot,
        bytes calldata challengeData
    ) external view override returns (bool success, bytes32 actualResultHash, bytes32 actualStateRoot) {
        ChallengePayload memory payload = abi.decode(challengeData, (ChallengePayload));

        (bytes32 finalStateRoot,,) = taskManager.previewCheckpointVerification(
            payload.pureVMTaskId,
            payload.fromOrdinal,
            payload.nextCheckpoint,
            payload.startSnapshotBytes,
            payload.proofBytes
        );

        actualStateRoot = finalStateRoot;
        actualResultHash = keccak256(
            abi.encode(
                payload.pureVMTaskId,
                payload.fromOrdinal + 1,
                payload.nextCheckpoint.stepNumber,
                payload.nextCheckpoint.gasUsed,
                payload.nextCheckpoint.gasRemaining,
                payload.nextCheckpoint.stateRoot,
                payload.nextCheckpoint.snapshotBlobHash,
                payload.nextCheckpoint.snapshotURI
            )
        );

        success = actualStateRoot != claimedStateRoot || actualResultHash != claimedResultHash;
    }
}
