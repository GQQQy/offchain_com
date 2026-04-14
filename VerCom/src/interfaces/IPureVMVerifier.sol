// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IPureVMVerifier {
    function verifyTransition(
        bytes calldata startSnapshotBytes,
        bytes calldata proofBytes,
        bytes32 expectedFinalStateRoot,
        uint64 expectedVerifiedSteps,
        bytes32 expectedTraceRoot
    )
        external
        view
        returns (bool valid, bytes32 finalStateRoot, uint64 verifiedSteps, bytes32 traceRoot);
}
