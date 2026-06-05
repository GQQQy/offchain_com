// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IPureVMVerifier} from "./interfaces/IPureVMVerifier.sol";

contract PureVMVerifierAdapter is IPureVMVerifier {
    uint256 public constant MAX_SNAPSHOT_BYTES = 262_144;
    uint256 public constant MAX_PROOF_BYTES = 1_048_576;

    address public immutable verifierTarget;

    error VerifierTargetRequired();
    error VerifierCallFailed();
    error InvalidVerifierResponse();
    error VerifierPayloadTooLarge(string field, uint256 size, uint256 limit);
    error VerifierFinalRootMismatch(bytes32 got, bytes32 want);
    error VerifierStepMismatch(uint64 got, uint64 want);
    error VerifierTraceRootMismatch(bytes32 got, bytes32 want);

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
    ) external view override returns (bool valid, bytes32 finalStateRoot, uint64 verifiedSteps, bytes32 traceRoot) {
        (valid,, finalStateRoot, verifiedSteps, traceRoot) =
            _verify(startSnapshotBytes, proofBytes, expectedFinalStateRoot, expectedVerifiedSteps, expectedTraceRoot);
    }

    function verifyTransitionDetailed(
        bytes calldata startSnapshotBytes,
        bytes calldata proofBytes,
        bytes32 expectedFinalStateRoot,
        uint64 expectedVerifiedSteps,
        bytes32 expectedTraceRoot
    )
        external
        view
        override
        returns (bool valid, bytes32 initialStateRoot, bytes32 finalStateRoot, uint64 verifiedSteps, bytes32 traceRoot)
    {
        return _verify(startSnapshotBytes, proofBytes, expectedFinalStateRoot, expectedVerifiedSteps, expectedTraceRoot);
    }

    function _verify(
        bytes calldata startSnapshotBytes,
        bytes calldata proofBytes,
        bytes32 expectedFinalStateRoot,
        uint64 expectedVerifiedSteps,
        bytes32 expectedTraceRoot
    )
        private
        view
        returns (bool valid, bytes32 initialStateRoot, bytes32 finalStateRoot, uint64 verifiedSteps, bytes32 traceRoot)
    {
        if (startSnapshotBytes.length > MAX_SNAPSHOT_BYTES) {
            revert VerifierPayloadTooLarge("startSnapshotBytes", startSnapshotBytes.length, MAX_SNAPSHOT_BYTES);
        }
        if (proofBytes.length > MAX_PROOF_BYTES) {
            revert VerifierPayloadTooLarge("proofBytes", proofBytes.length, MAX_PROOF_BYTES);
        }

        bytes memory input = abi.encodePacked(
            uint32(startSnapshotBytes.length), uint32(proofBytes.length), startSnapshotBytes, proofBytes
        );

        (bool ok, bytes memory returndata) = verifierTarget.staticcall(input);
        if (!ok) revert VerifierCallFailed();
        if (returndata.length != 128 && returndata.length != 160) revert InvalidVerifierResponse();

        uint256 actualVerifiedSteps;
        if (returndata.length == 160) {
            uint256 validWord;
            bytes32 actualInitialStateRoot;
            bytes32 actualFinalStateRoot;
            bytes32 actualTraceRoot;
            (validWord, actualInitialStateRoot, actualFinalStateRoot, actualVerifiedSteps, actualTraceRoot) =
                abi.decode(returndata, (uint256, bytes32, bytes32, uint256, bytes32));
            valid = validWord == 1;
            initialStateRoot = actualInitialStateRoot;
            finalStateRoot = actualFinalStateRoot;
            traceRoot = actualTraceRoot;
        } else {
            uint256 validWord;
            bytes32 actualFinalStateRoot;
            bytes32 actualTraceRoot;
            (validWord, actualFinalStateRoot, actualVerifiedSteps, actualTraceRoot) =
                abi.decode(returndata, (uint256, bytes32, uint256, bytes32));
            valid = validWord == 1;
            finalStateRoot = actualFinalStateRoot;
            traceRoot = actualTraceRoot;
        }

        if (!valid) {
            return (false, initialStateRoot, finalStateRoot, _toUint64(actualVerifiedSteps), traceRoot);
        }

        verifiedSteps = _toUint64(actualVerifiedSteps);
        if (expectedFinalStateRoot != bytes32(0) && finalStateRoot != expectedFinalStateRoot) {
            revert VerifierFinalRootMismatch(finalStateRoot, expectedFinalStateRoot);
        }
        if (verifiedSteps != expectedVerifiedSteps) {
            revert VerifierStepMismatch(verifiedSteps, expectedVerifiedSteps);
        }
        if (expectedTraceRoot != bytes32(0) && traceRoot != expectedTraceRoot) {
            revert VerifierTraceRootMismatch(traceRoot, expectedTraceRoot);
        }
    }

    function _toUint64(uint256 value) private pure returns (uint64) {
        if (value > type(uint64).max) revert InvalidVerifierResponse();
        return uint64(value);
    }
}
