// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {PureVMTaskManager} from "../src/PureVMTaskManager.sol";
import {PureVMTypes} from "../src/PureVMTypes.sol";
import {OptimisticTaskCoordinator} from "../src/OptimisticTaskCoordinator.sol";
import {ValidatorManager} from "../src/ValidatorManager.sol";
import {PureVMChallengeResolver} from "../src/PureVMChallengeResolver.sol";

interface Vm {
    function envAddress(string calldata) external returns (address);
    function envUint(string calldata) external returns (uint256);
    function envString(string calldata) external returns (string memory);
    function envBytes32(string calldata) external returns (bytes32);
    function readFile(string calldata) external returns (string memory);
    function readFileBinary(string calldata) external returns (bytes memory);
    function parseJsonUint(string calldata, string calldata) external pure returns (uint256);
    function parseJsonString(string calldata, string calldata) external pure returns (string memory);
    function parseJsonBytes32(string calldata, string calldata) external pure returns (bytes32);
    function parseJsonBytes(string calldata, string calldata) external pure returns (bytes memory);
    function toString(uint256) external pure returns (string memory);
    function startBroadcast(uint256 privateKey) external;
    function stopBroadcast() external;
}

address constant HEVM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
Vm constant vm = Vm(HEVM_ADDRESS);

contract RunPureVMChallengeE2EScript {
    function run() external returns (bytes32 pureVMTaskId, bytes32 optimisticTaskId) {
        string memory artifactDir = vm.envString("PUREVM_ARTIFACT_DIR");
        uint256 fromOrdinalUint = vm.envUint("PUREVM_FROM_ORDINAL");
        uint32 fromOrdinal = uint32(fromOrdinalUint);

        string memory indexPath = string.concat(artifactDir, "\\snapshot_index.json");
        string memory manifestPath = string.concat(artifactDir, "\\task_manifest.json");

        string memory indexJson = vm.readFile(indexPath);
        string memory manifestJson = vm.readFile(manifestPath);

        string memory startSnapshotFile =
            string.concat(artifactDir, "\\", _indexString(indexJson, fromOrdinalUint, ".snapshot_file"));
        string memory nextSnapshotFile =
            string.concat(artifactDir, "\\", _indexString(indexJson, fromOrdinalUint + 1, ".snapshot_file"));
        string memory proofFile = vm.envString("PUREVM_PROOF_FILE");

        bytes memory startSnapshotBytes = vm.readFileBinary(startSnapshotFile);
        bytes memory nextSnapshotBytes = vm.readFileBinary(nextSnapshotFile);
        bytes memory proofBytes = vm.readFileBinary(proofFile);

        string memory startSnapshotJson = vm.readFile(startSnapshotFile);
        bytes memory codeBytes = vm.parseJsonBytes(startSnapshotJson, ".state.code");
        bytes32 codeHash = keccak256(codeBytes);

        PureVMTaskManager taskManager = PureVMTaskManager(vm.envAddress("PUREVM_TASK_MANAGER"));
        OptimisticTaskCoordinator coordinator = OptimisticTaskCoordinator(vm.envAddress("OPTIMISTIC_COORDINATOR"));
        ValidatorManager validatorManager = ValidatorManager(vm.envAddress("VALIDATOR_MANAGER"));
        PureVMChallengeResolver challengeResolver = PureVMChallengeResolver(vm.envAddress("PUREVM_CHALLENGE_RESOLVER"));

        uint256 requesterPk = vm.envUint("REQUESTER_PRIVATE_KEY");
        uint256 executorPk = vm.envUint("EXECUTOR_PRIVATE_KEY");
        uint256 validatorPk = vm.envUint("VALIDATOR_PRIVATE_KEY");

        vm.startBroadcast(requesterPk);
        pureVMTaskId = taskManager.createTask(
            PureVMTypes.TaskCreation({
                verifier: vm.envAddress("PUREVM_VERIFIER"),
                codeHash: codeHash,
                totalGas: uint64(vm.parseJsonUint(manifestJson, ".total_gas")),
                snapshotThresholdGas: uint64(vm.parseJsonUint(manifestJson, ".snapshot_threshold_gas")),
                pureVMChainId: uint64(vm.parseJsonUint(indexJson, ".chain_id")),
                initialStateRoot: vm.parseJsonBytes32(startSnapshotJson, ".header.state_root"),
                initialSnapshotHash: keccak256(startSnapshotBytes),
                initialSnapshotURI: string.concat("file://", startSnapshotFile)
            })
        );

        optimisticTaskId = coordinator.postTask{value: vm.envUint("OPTIMISTIC_REWARD_POOL")}(
            vm.envString("OPTIMISTIC_SUMMARY_URI"),
            keccak256(bytes(vm.envString("OPTIMISTIC_SUMMARY_URI"))),
            uint64(vm.envUint("OPTIMISTIC_EXECUTION_WINDOW")),
            uint32(vm.envUint("OPTIMISTIC_VALIDATOR_COUNT")),
            vm.envUint("OPTIMISTIC_EXECUTOR_BOND"),
            OptimisticTaskCoordinator.PayoutConfig({
                executorRewardBps: uint16(vm.envUint("OPTIMISTIC_EXECUTOR_REWARD_BPS")),
                validatorRewardBps: uint16(vm.envUint("OPTIMISTIC_VALIDATOR_REWARD_BPS")),
                challengerSlashRewardBps: uint16(vm.envUint("OPTIMISTIC_CHALLENGER_SLASH_BPS")),
                requesterSlashBps: uint16(vm.envUint("OPTIMISTIC_REQUESTER_SLASH_BPS")),
                challengeBond: vm.envUint("OPTIMISTIC_CHALLENGE_BOND")
            })
        );
        vm.stopBroadcast();

        vm.startBroadcast(validatorPk);
        validatorManager.stake{value: vm.envUint("VALIDATOR_STAKE")}();
        vm.stopBroadcast();

        vm.startBroadcast(executorPk);
        coordinator.claimTask{value: vm.envUint("OPTIMISTIC_EXECUTOR_BOND")}(optimisticTaskId);
        coordinator.submitResult(
            optimisticTaskId,
            vm.envString("OPTIMISTIC_RESULT_URI"),
            keccak256(bytes("bad-result")),
            bytes32(uint256(0xdead))
        );
        vm.stopBroadcast();

        PureVMTypes.CheckpointInput memory nextCheckpoint = PureVMTypes.CheckpointInput({
            stepNumber: uint64(_indexUint(indexJson, fromOrdinalUint + 1, ".step_number")),
            gasUsed: uint64(_indexUint(indexJson, fromOrdinalUint + 1, ".gas_used")),
            gasRemaining: uint64(_indexUint(indexJson, fromOrdinalUint + 1, ".gas_remaining")),
            stateRoot: _indexBytes32(indexJson, fromOrdinalUint + 1, ".state_root"),
            snapshotBlobHash: keccak256(nextSnapshotBytes),
            snapshotURI: string.concat("file://", nextSnapshotFile)
        });

        bytes memory challengeData = abi.encode(
            PureVMChallengeResolver.ChallengePayload({
                pureVMTaskId: pureVMTaskId,
                fromOrdinal: fromOrdinal,
                nextCheckpoint: nextCheckpoint,
                startSnapshotBytes: startSnapshotBytes,
                proofBytes: proofBytes
            })
        );

        vm.startBroadcast(validatorPk);
        coordinator.challengeResult{value: vm.envUint("OPTIMISTIC_CHALLENGE_BOND")}(optimisticTaskId, challengeData);
        vm.stopBroadcast();

        challengeResolver;
    }

    function _indexString(string memory indexJson, uint256 ordinal, string memory suffix) internal pure returns (string memory) {
        return vm.parseJsonString(indexJson, string.concat(".snapshots[", vm.toString(ordinal), "]", suffix));
    }

    function _indexUint(string memory indexJson, uint256 ordinal, string memory suffix) internal pure returns (uint256) {
        return vm.parseJsonUint(indexJson, string.concat(".snapshots[", vm.toString(ordinal), "]", suffix));
    }

    function _indexBytes32(string memory indexJson, uint256 ordinal, string memory suffix) internal pure returns (bytes32) {
        return vm.parseJsonBytes32(indexJson, string.concat(".snapshots[", vm.toString(ordinal), "]", suffix));
    }
}
