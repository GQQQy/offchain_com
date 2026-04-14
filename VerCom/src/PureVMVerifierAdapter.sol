// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IPureVMVerifier} from "./interfaces/IPureVMVerifier.sol";

contract PureVMVerifierAdapter is IPureVMVerifier {
    address public immutable verifierTarget;

    error VerifierTargetRequired();
    error VerifierCallFailed();
    error InvalidVerifierResponse();

    constructor(address verifierTarget_) {
        if (verifierTarget_ == address(0)) revert VerifierTargetRequired();
        verifierTarget = verifierTarget_;
    }

    function verifyTransition(
        bytes calldata startSnapshotBytes,
        bytes calldata proofBytes,
        bytes32 expectedFinalStateRoot,
        uint64 expectedVerifiedSteps,
        bytes32 expectedTraceRoot
    )
        external
        view
        override
        returns (bool valid, bytes32 finalStateRoot, uint64 verifiedSteps, bytes32 traceRoot)
    {
        bytes memory input = abi.encodePacked(
            uint32(startSnapshotBytes.length),
            uint32(proofBytes.length),
            startSnapshotBytes,
            proofBytes
        );

        (bool ok, bytes memory returndata) = verifierTarget.staticcall(input);
        if (!ok) revert VerifierCallFailed();
        if (returndata.length != 32) revert InvalidVerifierResponse();

        valid = abi.decode(returndata, (uint256)) == 1;
        finalStateRoot = expectedFinalStateRoot;
        verifiedSteps = expectedVerifiedSteps;
        traceRoot = expectedTraceRoot;
    }
}
