// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {PureVMSnapshotStore} from "../src/PureVMSnapshotStore.sol";

interface Vm {
    function envAddress(string calldata) external returns (address);
    function envBytes32(string calldata) external returns (bytes32);
    function envUint(string calldata) external returns (uint256);
    function startBroadcast() external;
    function stopBroadcast() external;
}

address constant HEVM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
Vm constant vm = Vm(HEVM_ADDRESS);

contract DeleteSnapshotFromStoreScript {
    function run() external {
        PureVMSnapshotStore store = PureVMSnapshotStore(vm.envAddress("PUREVM_SNAPSHOT_STORE"));
        bytes32 taskId = vm.envBytes32("PUREVM_TASK_ID");
        uint32 ordinal = uint32(vm.envUint("PUREVM_SNAPSHOT_ORDINAL"));

        vm.startBroadcast();
        store.deleteSnapshot(taskId, ordinal);
        vm.stopBroadcast();
    }
}
