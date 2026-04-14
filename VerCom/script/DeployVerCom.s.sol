// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {PureVMTaskManager} from "../src/PureVMTaskManager.sol";
import {PureVMSnapshotStore} from "../src/PureVMSnapshotStore.sol";
import {PureVMVerifierAdapter} from "../src/PureVMVerifierAdapter.sol";
import {PureVMChallengeResolver} from "../src/PureVMChallengeResolver.sol";
import {ValidatorManager} from "../src/ValidatorManager.sol";
import {OptimisticTaskCoordinator} from "../src/OptimisticTaskCoordinator.sol";

interface Vm {
    function envAddress(string calldata) external returns (address);
    function startBroadcast() external;
    function stopBroadcast() external;
}

address constant HEVM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
Vm constant vm = Vm(HEVM_ADDRESS);

contract DeployVerComScript {
    function run()
        external
        returns (
            ValidatorManager validatorManager,
            PureVMSnapshotStore snapshotStore,
            PureVMVerifierAdapter verifierAdapter,
            PureVMTaskManager taskManager,
            PureVMChallengeResolver challengeResolver,
            OptimisticTaskCoordinator coordinator
        )
    {
        address verifierTarget = vm.envAddress("PUREVM_VERIFIER_TARGET");

        vm.startBroadcast();
        validatorManager = new ValidatorManager(1 ether, 1 days);
        snapshotStore = new PureVMSnapshotStore();
        verifierAdapter = new PureVMVerifierAdapter(verifierTarget);
        taskManager = new PureVMTaskManager();
        challengeResolver = new PureVMChallengeResolver(address(taskManager));
        coordinator = new OptimisticTaskCoordinator(address(validatorManager), address(challengeResolver), 1 days);
        vm.stopBroadcast();
    }
}
