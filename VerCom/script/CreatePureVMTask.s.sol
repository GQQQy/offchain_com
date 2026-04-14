// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {PureVMTaskManager} from "../src/PureVMTaskManager.sol";
import {PureVMTypes} from "../src/PureVMTypes.sol";

interface Vm {
    function envAddress(string calldata) external returns (address);
    function envBytes32(string calldata) external returns (bytes32);
    function envUint(string calldata) external returns (uint256);
    function envString(string calldata) external returns (string memory);
    function startBroadcast() external;
    function stopBroadcast() external;
}

address constant HEVM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
Vm constant vm = Vm(HEVM_ADDRESS);

contract CreatePureVMTaskScript {
    function run() external returns (bytes32 taskId) {
        PureVMTaskManager manager = PureVMTaskManager(vm.envAddress("PUREVM_TASK_MANAGER"));

        PureVMTypes.TaskCreation memory creation = PureVMTypes.TaskCreation({
            verifier: vm.envAddress("PUREVM_VERIFIER"),
            codeHash: vm.envBytes32("PUREVM_CODE_HASH"),
            totalGas: uint64(vm.envUint("PUREVM_TOTAL_GAS")),
            snapshotThresholdGas: uint64(vm.envUint("PUREVM_SNAPSHOT_THRESHOLD_GAS")),
            pureVMChainId: uint64(vm.envUint("PUREVM_CHAIN_ID")),
            initialStateRoot: vm.envBytes32("PUREVM_INITIAL_STATE_ROOT"),
            initialSnapshotHash: vm.envBytes32("PUREVM_INITIAL_SNAPSHOT_HASH"),
            initialSnapshotURI: vm.envString("PUREVM_INITIAL_SNAPSHOT_URI")
        });

        vm.startBroadcast();
        taskId = manager.createTask(creation);
        vm.stopBroadcast();
    }
}
