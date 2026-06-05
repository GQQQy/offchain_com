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
    function envOr(string calldata, uint256) external returns (uint256);
    function startBroadcast() external;
    function stopBroadcast() external;
}

address constant HEVM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
Vm constant vm = Vm(HEVM_ADDRESS);

contract DeployVerComScript {
    error EnvUint64TooLarge(string name, uint256 value);

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
        uint256 validatorMinStake = vm.envOr("VERCOM_VALIDATOR_MIN_STAKE", uint256(1 ether));
        uint64 validatorExitDelay = _envUint64("VERCOM_VALIDATOR_EXIT_DELAY", uint64(1 days));
        uint64 challengeWindow = _envUint64("VERCOM_DEFAULT_CHALLENGE_WINDOW", uint64(1 days));

        vm.startBroadcast();
        (validatorManager, snapshotStore, verifierAdapter, taskManager, challengeResolver, coordinator) =
            deploy(verifierTarget, validatorMinStake, validatorExitDelay, challengeWindow);
        vm.stopBroadcast();
    }

    function deploy(address verifierTarget)
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
        return deploy(verifierTarget, 1 ether, 1 days, 1 days);
    }

    function deploy(
        address verifierTarget,
        uint256 validatorMinStake,
        uint256 validatorExitDelay,
        uint256 challengeWindow
    )
        public
        returns (
            ValidatorManager validatorManager,
            PureVMSnapshotStore snapshotStore,
            PureVMVerifierAdapter verifierAdapter,
            PureVMTaskManager taskManager,
            PureVMChallengeResolver challengeResolver,
            OptimisticTaskCoordinator coordinator
        )
    {
        if (validatorExitDelay > type(uint64).max) revert EnvUint64TooLarge("validatorExitDelay", validatorExitDelay);
        if (challengeWindow > type(uint64).max) revert EnvUint64TooLarge("challengeWindow", challengeWindow);
        validatorManager = new ValidatorManager(validatorMinStake, uint64(validatorExitDelay));
        snapshotStore = new PureVMSnapshotStore();
        verifierAdapter = new PureVMVerifierAdapter(verifierTarget);
        taskManager = new PureVMTaskManager();
        taskManager.setVerifierApproval(address(verifierAdapter), 1, true);
        challengeResolver = new PureVMChallengeResolver(address(taskManager));
        taskManager.setChallengeResolverAuthorization(address(challengeResolver), true);
        coordinator = new OptimisticTaskCoordinator(
            address(validatorManager), address(challengeResolver), uint64(challengeWindow)
        );
    }

    function _envUint64(string memory name, uint64 fallbackValue) private returns (uint64) {
        uint256 value = vm.envOr(name, uint256(fallbackValue));
        if (value > type(uint64).max) revert EnvUint64TooLarge(name, value);
        return uint64(value);
    }
}
