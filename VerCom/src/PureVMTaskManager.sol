// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IPureVMVerifier} from "./interfaces/IPureVMVerifier.sol";
import {IPureVMSnapshotStore} from "./interfaces/IPureVMSnapshotStore.sol";
import {PureVMTypes} from "./PureVMTypes.sol";

contract PureVMTaskManager {
    mapping(bytes32 => PureVMTypes.TaskConfig) private tasks;
    mapping(bytes32 => mapping(uint32 => PureVMTypes.CheckpointMeta)) private checkpoints;
    mapping(bytes32 => mapping(uint32 => PureVMTypes.AdjacentProofMeta)) private adjacentProofs;
    mapping(bytes32 => mapping(bytes32 => bool)) private verifiedRoots;
    mapping(address => uint256) public taskNonces;

    error EmptyVerifier();
    error InvalidTask();
    error TaskAlreadyExists();
    error InvalidThreshold();
    error InvalidTotalGas();
    error CheckpointAlreadyExists();
    error InvalidOrdinal();
    error UnverifiedCheckpoint();
    error InvalidCheckpointProgression();
    error InvalidGasAccounting();
    error ThresholdBoundaryNotReached(uint64 gasUsed, uint64 expectedBoundary);
    error StartSnapshotHashMismatch();
    error VerificationFailed();
    error FinalRootMismatch(bytes32 got, bytes32 want);
    error VerifiedStepsMismatch(uint64 got, uint64 want);

    event TaskCreated(
        bytes32 indexed taskId,
        address indexed owner,
        address indexed verifier,
        bytes32 codeHash,
        uint64 totalGas,
        uint64 snapshotThresholdGas
    );
    event CheckpointRegistered(
        bytes32 indexed taskId,
        uint32 indexed ordinal,
        uint64 stepNumber,
        uint64 gasUsed,
        bytes32 stateRoot,
        bytes32 snapshotBlobHash
    );
    event AdjacentCheckpointVerified(
        bytes32 indexed taskId,
        uint32 indexed fromOrdinal,
        uint32 indexed toOrdinal,
        uint64 proofSteps,
        bytes32 finalStateRoot,
        bytes32 traceRoot
    );
    event TaskFinalized(bytes32 indexed taskId, uint32 indexed finalOrdinal, bytes32 finalStateRoot);

    function createTask(PureVMTypes.TaskCreation calldata creation) external returns (bytes32 taskId) {
        if (creation.verifier == address(0)) revert EmptyVerifier();
        if (creation.snapshotThresholdGas == 0) revert InvalidThreshold();
        if (creation.totalGas == 0) revert InvalidTotalGas();

        uint256 nonce = taskNonces[msg.sender]++;
        taskId = computeTaskId(msg.sender, nonce, creation.codeHash, creation.totalGas, creation.snapshotThresholdGas, creation.initialStateRoot);
        if (tasks[taskId].exists) revert TaskAlreadyExists();

        tasks[taskId] = PureVMTypes.TaskConfig({
            owner: msg.sender,
            verifier: creation.verifier,
            codeHash: creation.codeHash,
            totalGas: creation.totalGas,
            snapshotThresholdGas: creation.snapshotThresholdGas,
            pureVMChainId: creation.pureVMChainId,
            initialStateRoot: creation.initialStateRoot,
            latestVerifiedOrdinal: 0,
            checkpointCount: 1,
            finalized: false,
            exists: true
        });

        checkpoints[taskId][0] = PureVMTypes.CheckpointMeta({
            ordinal: 0,
            stepNumber: 0,
            gasUsed: 0,
            gasRemaining: creation.totalGas,
            stateRoot: creation.initialStateRoot,
            snapshotBlobHash: creation.initialSnapshotHash,
            snapshotURI: creation.initialSnapshotURI,
            verified: true
        });
        verifiedRoots[taskId][creation.initialStateRoot] = true;

        emit TaskCreated(
            taskId,
            msg.sender,
            creation.verifier,
            creation.codeHash,
            creation.totalGas,
            creation.snapshotThresholdGas
        );
        emit CheckpointRegistered(taskId, 0, 0, 0, creation.initialStateRoot, creation.initialSnapshotHash);
    }

    function verifyAndAppendCheckpoint(
        bytes32 taskId,
        uint32 fromOrdinal,
        PureVMTypes.CheckpointInput calldata nextCheckpoint,
        bytes calldata startSnapshotBytes,
        bytes calldata proofBytes,
        string calldata proofURI
    ) external returns (bool) {
        return _verifyAndAppendCheckpoint(taskId, fromOrdinal, nextCheckpoint, startSnapshotBytes, proofBytes, proofURI);
    }

    function previewCheckpointVerification(
        bytes32 taskId,
        uint32 fromOrdinal,
        PureVMTypes.CheckpointInput calldata nextCheckpoint,
        bytes calldata startSnapshotBytes,
        bytes calldata proofBytes
    ) external view returns (bytes32 finalStateRoot, uint64 verifiedSteps, bytes32 traceRoot) {
        return _previewCheckpointVerification(taskId, fromOrdinal, nextCheckpoint, startSnapshotBytes, proofBytes);
    }

    function verifyAndAppendCheckpointFromStore(
        bytes32 taskId,
        uint32 fromOrdinal,
        address snapshotStore,
        PureVMTypes.CheckpointInput calldata nextCheckpoint,
        bytes calldata proofBytes,
        string calldata proofURI
    ) external returns (bool) {
        bytes memory startSnapshotBytes = IPureVMSnapshotStore(snapshotStore).getSnapshot(taskId, fromOrdinal);
        return _verifyAndAppendCheckpoint(taskId, fromOrdinal, nextCheckpoint, startSnapshotBytes, proofBytes, proofURI);
    }

    function _verifyAndAppendCheckpoint(
        bytes32 taskId,
        uint32 fromOrdinal,
        PureVMTypes.CheckpointInput calldata nextCheckpoint,
        bytes memory startSnapshotBytes,
        bytes calldata proofBytes,
        string calldata proofURI
    ) internal returns (bool) {
        PureVMTypes.TaskConfig storage task = tasks[taskId];
        if (!task.exists || task.finalized) revert InvalidTask();
        if (fromOrdinal != task.latestVerifiedOrdinal) revert InvalidOrdinal();

        PureVMTypes.CheckpointMeta storage start = checkpoints[taskId][fromOrdinal];
        if (!start.verified) revert UnverifiedCheckpoint();

        uint32 nextOrdinal = fromOrdinal + 1;
        if (checkpoints[taskId][nextOrdinal].verified) revert CheckpointAlreadyExists();

        _validateCheckpointProgression(task, start, nextOrdinal, nextCheckpoint);

        if (keccak256(startSnapshotBytes) != start.snapshotBlobHash) revert StartSnapshotHashMismatch();

        (, uint64 verifiedSteps, bytes32 traceRoot) =
            _previewCheckpointVerification(taskId, fromOrdinal, nextCheckpoint, startSnapshotBytes, proofBytes);

        checkpoints[taskId][nextOrdinal] = PureVMTypes.CheckpointMeta({
            ordinal: nextOrdinal,
            stepNumber: nextCheckpoint.stepNumber,
            gasUsed: nextCheckpoint.gasUsed,
            gasRemaining: nextCheckpoint.gasRemaining,
            stateRoot: nextCheckpoint.stateRoot,
            snapshotBlobHash: nextCheckpoint.snapshotBlobHash,
            snapshotURI: nextCheckpoint.snapshotURI,
            verified: true
        });

        adjacentProofs[taskId][fromOrdinal] = PureVMTypes.AdjacentProofMeta({
            fromOrdinal: fromOrdinal,
            toOrdinal: nextOrdinal,
            proofSteps: verifiedSteps,
            fullProof: true,
            proofBlobHash: keccak256(proofBytes),
            traceRoot: traceRoot,
            proofURI: proofURI,
            verifiedAtBlock: uint64(block.number)
        });

        verifiedRoots[taskId][nextCheckpoint.stateRoot] = true;
        task.latestVerifiedOrdinal = nextOrdinal;
        task.checkpointCount = nextOrdinal + 1;

        emit CheckpointRegistered(
            taskId,
            nextOrdinal,
            nextCheckpoint.stepNumber,
            nextCheckpoint.gasUsed,
            nextCheckpoint.stateRoot,
            nextCheckpoint.snapshotBlobHash
        );
        emit AdjacentCheckpointVerified(
            taskId,
            fromOrdinal,
            nextOrdinal,
            verifiedSteps,
            nextCheckpoint.stateRoot,
            traceRoot
        );

        if (nextCheckpoint.gasUsed == task.totalGas) {
            task.finalized = true;
            emit TaskFinalized(taskId, nextOrdinal, nextCheckpoint.stateRoot);
        }

        return true;
    }

    function _previewCheckpointVerification(
        bytes32 taskId,
        uint32 fromOrdinal,
        PureVMTypes.CheckpointInput calldata nextCheckpoint,
        bytes memory startSnapshotBytes,
        bytes calldata proofBytes
    ) internal view returns (bytes32 finalStateRoot, uint64 verifiedSteps, bytes32 traceRoot) {
        PureVMTypes.TaskConfig storage task = tasks[taskId];
        if (!task.exists || task.finalized) revert InvalidTask();
        if (fromOrdinal > task.latestVerifiedOrdinal) revert InvalidOrdinal();

        PureVMTypes.CheckpointMeta storage start = checkpoints[taskId][fromOrdinal];
        if (!start.verified) revert UnverifiedCheckpoint();

        uint32 nextOrdinal = fromOrdinal + 1;
        _validateCheckpointProgression(task, start, nextOrdinal, nextCheckpoint);

        if (keccak256(startSnapshotBytes) != start.snapshotBlobHash) revert StartSnapshotHashMismatch();

        uint64 expectedSteps = nextCheckpoint.stepNumber - start.stepNumber;
        (bool valid, bytes32 verifiedFinalRoot, uint64 steps, bytes32 verifiedTraceRoot) = IPureVMVerifier(task.verifier)
            .verifyTransition(startSnapshotBytes, proofBytes, nextCheckpoint.stateRoot, expectedSteps, bytes32(0));
        if (!valid) revert VerificationFailed();
        if (steps != expectedSteps) revert VerifiedStepsMismatch(steps, expectedSteps);
        if (verifiedFinalRoot != nextCheckpoint.stateRoot) revert FinalRootMismatch(verifiedFinalRoot, nextCheckpoint.stateRoot);

        return (verifiedFinalRoot, steps, verifiedTraceRoot);
    }

    function getTask(bytes32 taskId) external view returns (PureVMTypes.TaskConfig memory) {
        return tasks[taskId];
    }

    function getCheckpoint(bytes32 taskId, uint32 ordinal) external view returns (PureVMTypes.CheckpointMeta memory) {
        return checkpoints[taskId][ordinal];
    }

    function getAdjacentProof(bytes32 taskId, uint32 fromOrdinal)
        external
        view
        returns (PureVMTypes.AdjacentProofMeta memory)
    {
        return adjacentProofs[taskId][fromOrdinal];
    }

    function getLatestVerifiedOrdinal(bytes32 taskId) external view returns (uint32) {
        return tasks[taskId].latestVerifiedOrdinal;
    }

    function isStateRootVerified(bytes32 taskId, bytes32 stateRoot) external view returns (bool) {
        return verifiedRoots[taskId][stateRoot];
    }

    function computeTaskId(
        address owner,
        uint256 nonce,
        bytes32 codeHash,
        uint64 totalGas,
        uint64 snapshotThresholdGas,
        bytes32 initialStateRoot
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(owner, nonce, codeHash, totalGas, snapshotThresholdGas, initialStateRoot));
    }

    function validateAdjacentThreshold(bytes32 taskId, uint32 fromOrdinal, PureVMTypes.CheckpointInput calldata nextCheckpoint)
        external
        view
        returns (bool)
    {
        PureVMTypes.TaskConfig storage task = tasks[taskId];
        if (!task.exists) revert InvalidTask();
        PureVMTypes.CheckpointMeta storage start = checkpoints[taskId][fromOrdinal];
        bool isFinal = nextCheckpoint.gasUsed == task.totalGas;
        _validateThreshold(task, start, nextCheckpoint.gasUsed, nextCheckpoint.stepNumber, isFinal);
        return true;
    }

    function _validateCheckpointProgression(
        PureVMTypes.TaskConfig storage task,
        PureVMTypes.CheckpointMeta storage start,
        uint32 nextOrdinal,
        PureVMTypes.CheckpointInput calldata nextCheckpoint
    ) internal view {
        if (nextCheckpoint.stepNumber <= start.stepNumber) revert InvalidCheckpointProgression();
        if (nextCheckpoint.gasUsed <= start.gasUsed) revert InvalidCheckpointProgression();
        if (nextCheckpoint.gasUsed + nextCheckpoint.gasRemaining != task.totalGas) revert InvalidGasAccounting();
        if (nextOrdinal != start.ordinal + 1) revert InvalidOrdinal();

        bool isFinal = nextCheckpoint.gasUsed == task.totalGas;
        _validateThreshold(task, start, nextCheckpoint.gasUsed, nextCheckpoint.stepNumber, isFinal);
    }

    function _validateThreshold(
        PureVMTypes.TaskConfig storage task,
        PureVMTypes.CheckpointMeta storage start,
        uint64 endGasUsed,
        uint64 endStepNumber,
        bool isFinal
    ) internal view {
        if (endStepNumber <= start.stepNumber) revert InvalidCheckpointProgression();
        if (endGasUsed <= start.gasUsed) revert InvalidCheckpointProgression();

        if (isFinal) {
            return;
        }

        uint64 expectedBoundary = ((start.gasUsed / task.snapshotThresholdGas) + 1) * task.snapshotThresholdGas;
        if (endGasUsed < expectedBoundary) {
            revert ThresholdBoundaryNotReached(endGasUsed, expectedBoundary);
        }
    }
}
