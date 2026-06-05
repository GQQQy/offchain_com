// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IOptimisticChallengeResolver {
    function validateChallenge(
        address challenger,
        bytes32 taskId,
        bytes32 summaryHash,
        bytes32 claimedResultHash,
        bytes32 claimedStateRoot,
        bytes calldata challengeData
    ) external returns (bool success, bytes32 actualResultHash, bytes32 actualStateRoot);
}
