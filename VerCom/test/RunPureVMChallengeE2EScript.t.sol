// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {RunPureVMChallengeE2EScript} from "../script/RunPureVMChallengeE2E.s.sol";
import {OptimisticTaskCoordinator} from "../src/OptimisticTaskCoordinator.sol";
import {PureVMChallengeResolver} from "../src/PureVMChallengeResolver.sol";
import {PureVMTaskManager} from "../src/PureVMTaskManager.sol";
import {PureVMTypes} from "../src/PureVMTypes.sol";
import {PureVMVerifierAdapter} from "../src/PureVMVerifierAdapter.sol";
import {ValidatorManager} from "../src/ValidatorManager.sol";

interface VmE2E {
    function addr(uint256 privateKey) external returns (address);
    function deal(address who, uint256 newBalance) external;
    function envOr(string calldata key, uint256 defaultValue) external returns (uint256);
    function envString(string calldata key) external returns (string memory);
    function parseJsonBytes32(string calldata json, string calldata key) external pure returns (bytes32);
    function parseJsonString(string calldata json, string calldata key) external pure returns (string memory);
    function parseJsonUint(string calldata json, string calldata key) external pure returns (uint256);
    function readFile(string calldata path) external returns (string memory);
    function readFileBinary(string calldata path) external returns (bytes memory);
    function setEnv(string calldata key, string calldata value) external;
    function toString(address value) external pure returns (string memory);
    function toString(uint256 value) external pure returns (string memory);
}

address constant HEVM_E2E_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
VmE2E constant vmE2E = VmE2E(HEVM_E2E_ADDRESS);

contract StrictSnapshotValidatorTarget {
    bytes32 internal immutable expectedSnapshotHash;
    bytes32 internal immutable expectedProofHash;
    bytes32 internal immutable finalRoot;
    uint64 internal immutable verifiedSteps;
    bytes32 internal immutable traceRoot;

    error PayloadMismatch();

    constructor(
        bytes32 expectedSnapshotHash_,
        bytes32 expectedProofHash_,
        bytes32 finalRoot_,
        uint64 verifiedSteps_,
        bytes32 traceRoot_
    ) {
        expectedSnapshotHash = expectedSnapshotHash_;
        expectedProofHash = expectedProofHash_;
        finalRoot = finalRoot_;
        verifiedSteps = verifiedSteps_;
        traceRoot = traceRoot_;
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        if (input.length < 8) revert PayloadMismatch();

        uint32 snapshotLen = uint32(bytes4(input[0:4]));
        uint32 proofLen = uint32(bytes4(input[4:8]));
        if (input.length != 8 + uint256(snapshotLen) + uint256(proofLen)) revert PayloadMismatch();

        bytes memory snapshotBytes = input[8:8 + snapshotLen];
        bytes memory proofBytes = input[8 + snapshotLen:input.length];
        if (keccak256(snapshotBytes) != expectedSnapshotHash) revert PayloadMismatch();
        if (keccak256(proofBytes) != expectedProofHash) revert PayloadMismatch();

        return abi.encode(uint256(1), finalRoot, uint256(verifiedSteps), traceRoot);
    }
}

contract RunPureVMChallengeE2EScriptTest {
    function testRunScriptAgainstGeneratedPureVMArtifacts() public {
        if (vmE2E.envOr("PUREVM_E2E_SCRIPT_TEST", uint256(0)) != 1) {
            return;
        }

        string memory artifactDir = vmE2E.envString("PUREVM_ARTIFACT_DIR");
        uint256 fromOrdinal = vmE2E.envOr("PUREVM_FROM_ORDINAL", uint256(0));
        string memory indexJson = vmE2E.readFile(_joinPath(artifactDir, "snapshot_index.json"));
        string memory startSnapshotFile = _joinPath(artifactDir, _indexString(indexJson, fromOrdinal, ".snapshot_file"));
        string memory proofFile = _joinPath(artifactDir, _indexString(indexJson, fromOrdinal, ".adjacent_proof_file"));

        bytes memory startSnapshotBytes = vmE2E.readFileBinary(startSnapshotFile);
        bytes memory proofBytes = vmE2E.readFileBinary(proofFile);
        string memory proofJson = vmE2E.readFile(proofFile);

        uint64 startStep = uint64(_indexUint(indexJson, fromOrdinal, ".step_number"));
        uint64 nextStep = uint64(_indexUint(indexJson, fromOrdinal + 1, ".step_number"));
        bytes32 nextRoot = _indexBytes32(indexJson, fromOrdinal + 1, ".state_root");
        bytes32 traceRoot = vmE2E.parseJsonBytes32(proofJson, ".trace_root");

        StrictSnapshotValidatorTarget verifierTarget = new StrictSnapshotValidatorTarget(
            keccak256(startSnapshotBytes), keccak256(proofBytes), nextRoot, nextStep - startStep, traceRoot
        );
        PureVMVerifierAdapter verifier = new PureVMVerifierAdapter(address(verifierTarget));
        PureVMTaskManager taskManager = new PureVMTaskManager();
        taskManager.setVerifierApproval(address(verifier), 1, true);
        PureVMChallengeResolver challengeResolver = new PureVMChallengeResolver(address(taskManager));
        taskManager.setChallengeResolverAuthorization(address(challengeResolver), true);
        ValidatorManager validatorManager = new ValidatorManager(1 ether, 1 days);
        OptimisticTaskCoordinator coordinator =
            new OptimisticTaskCoordinator(address(validatorManager), address(challengeResolver), 1 days);

        uint256 requesterPk = 0xA11CE;
        uint256 executorPk = 0xB0B;
        uint256 validatorPk = 0xCA11;
        vmE2E.deal(vmE2E.addr(requesterPk), 100 ether);
        vmE2E.deal(vmE2E.addr(executorPk), 100 ether);
        vmE2E.deal(vmE2E.addr(validatorPk), 100 ether);

        _setEnv("PUREVM_VERIFIER", vmE2E.toString(address(verifier)));
        _setEnv("PUREVM_TASK_MANAGER", vmE2E.toString(address(taskManager)));
        _setEnv("PUREVM_CHALLENGE_RESOLVER", vmE2E.toString(address(challengeResolver)));
        _setEnv("VALIDATOR_MANAGER", vmE2E.toString(address(validatorManager)));
        _setEnv("OPTIMISTIC_COORDINATOR", vmE2E.toString(address(coordinator)));
        _setEnv("PUREVM_FROM_ORDINAL", vmE2E.toString(fromOrdinal));
        _setEnv("PUREVM_PROOF_FILE", "");
        _setEnv("REQUESTER_PRIVATE_KEY", vmE2E.toString(requesterPk));
        _setEnv("EXECUTOR_PRIVATE_KEY", vmE2E.toString(executorPk));
        _setEnv("VALIDATOR_PRIVATE_KEY", vmE2E.toString(validatorPk));
        _setEnv("OPTIMISTIC_SUMMARY_URI", "ipfs://purevm-task-summary");
        _setEnv("OPTIMISTIC_RESULT_URI", "ipfs://executor-claimed-result");
        _setEnv("OPTIMISTIC_REWARD_POOL", vmE2E.toString(uint256(10 ether)));
        _setEnv("OPTIMISTIC_EXECUTION_WINDOW", vmE2E.toString(uint256(1 days)));
        _setEnv("OPTIMISTIC_VALIDATOR_COUNT", "1");
        _setEnv("OPTIMISTIC_MIN_ATTESTATIONS", "0");
        _setEnv("OPTIMISTIC_EXECUTOR_BOND", vmE2E.toString(uint256(2 ether)));
        _setEnv("OPTIMISTIC_ARTIFACT_MANIFEST_URI", "ipfs://purevm-artifact-manifest");
        _setEnv("OPTIMISTIC_EXECUTOR_REWARD_BPS", "7000");
        _setEnv("OPTIMISTIC_VALIDATOR_REWARD_BPS", "3000");
        _setEnv("OPTIMISTIC_CHALLENGER_SLASH_BPS", "4000");
        _setEnv("OPTIMISTIC_REQUESTER_SLASH_BPS", "6000");
        _setEnv("OPTIMISTIC_CHALLENGE_BOND", vmE2E.toString(uint256(0.5 ether)));
        _setEnv("VALIDATOR_STAKE", vmE2E.toString(uint256(5 ether)));

        RunPureVMChallengeE2EScript script = new RunPureVMChallengeE2EScript();
        (bytes32 pureVMTaskId,) = script.run();

        bytes32 disputeId = taskManager.getLatestDisputeForCheckpoint(pureVMTaskId, uint32(fromOrdinal));
        PureVMTypes.DisputeMeta memory dispute = taskManager.getDispute(disputeId);
        require(dispute.taskId == pureVMTaskId, "dispute task id");
        require(dispute.actualStateRoot == nextRoot, "actual state root");
        require(dispute.traceRoot == traceRoot, "trace root");
        require(dispute.verifiedSteps == nextStep - startStep, "verified steps");
        require(dispute.challengerWon, "challenge should win against bad claim");
    }

    function _setEnv(string memory key, string memory value) internal {
        vmE2E.setEnv(key, value);
    }

    function _joinPath(string memory dir, string memory file) internal pure returns (string memory) {
        bytes memory dirBytes = bytes(dir);
        if (dirBytes.length == 0) {
            return file;
        }
        bytes1 last = dirBytes[dirBytes.length - 1];
        if (last == "/" || last == "\\") {
            return string.concat(dir, file);
        }
        return string.concat(dir, "/", file);
    }

    function _indexString(string memory indexJson, uint256 ordinal, string memory suffix)
        internal
        pure
        returns (string memory)
    {
        return vmE2E.parseJsonString(indexJson, string.concat(".snapshots[", vmE2E.toString(ordinal), "]", suffix));
    }

    function _indexUint(string memory indexJson, uint256 ordinal, string memory suffix)
        internal
        pure
        returns (uint256)
    {
        return vmE2E.parseJsonUint(indexJson, string.concat(".snapshots[", vmE2E.toString(ordinal), "]", suffix));
    }

    function _indexBytes32(string memory indexJson, uint256 ordinal, string memory suffix)
        internal
        pure
        returns (bytes32)
    {
        return vmE2E.parseJsonBytes32(indexJson, string.concat(".snapshots[", vmE2E.toString(ordinal), "]", suffix));
    }
}
