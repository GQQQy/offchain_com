// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {PureVMTaskManager} from "../src/PureVMTaskManager.sol";
import {PureVMTypes} from "../src/PureVMTypes.sol";

interface Vm {
    function envAddress(string calldata) external returns (address);
    function envBytes32(string calldata) external returns (bytes32);
    function envUint(string calldata) external returns (uint256);
    function envString(string calldata) external returns (string memory);
    function readFileBinary(string calldata) external returns (bytes memory);
    function startBroadcast() external;
    function stopBroadcast() external;
}

address constant HEVM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
Vm constant vm = Vm(HEVM_ADDRESS);

contract VerifyCheckpointFromStoreScript {
    function run() external returns (bool) {
        PureVMTaskManager manager = PureVMTaskManager(vm.envAddress("PUREVM_TASK_MANAGER"));

        bytes32 taskId = vm.envBytes32("PUREVM_TASK_ID");
        uint32 fromOrdinal = uint32(vm.envUint("PUREVM_FROM_ORDINAL"));
        address snapshotStore = vm.envAddress("PUREVM_SNAPSHOT_STORE");

        PureVMTypes.CheckpointInput memory nextCheckpoint = PureVMTypes.CheckpointInput({
            stepNumber: uint64(vm.envUint("PUREVM_NEXT_STEP_NUMBER")),
            gasUsed: uint64(vm.envUint("PUREVM_NEXT_GAS_USED")),
            gasRemaining: uint64(vm.envUint("PUREVM_NEXT_GAS_REMAINING")),
            stateRoot: vm.envBytes32("PUREVM_NEXT_STATE_ROOT"),
            snapshotBlobHash: vm.envBytes32("PUREVM_NEXT_SNAPSHOT_HASH"),
            snapshotURI: vm.envString("PUREVM_NEXT_SNAPSHOT_URI")
        });

        bytes memory proofBytes = vm.readFileBinary(vm.envString("PUREVM_PROOF_FILE"));
        string memory proofURI = vm.envString("PUREVM_PROOF_URI");

        vm.startBroadcast();
        bool ok = manager.verifyAndAppendCheckpointFromStore(
            taskId,
            fromOrdinal,
            snapshotStore,
            nextCheckpoint,
            proofBytes,
            proofURI
        );
        vm.stopBroadcast();
        return ok;
    }
}
