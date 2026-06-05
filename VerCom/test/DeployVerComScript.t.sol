// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {DeployVerComScript} from "../script/DeployVerCom.s.sol";
import {OptimisticTaskCoordinator} from "../src/OptimisticTaskCoordinator.sol";
import {PureVMChallengeResolver} from "../src/PureVMChallengeResolver.sol";
import {PureVMSnapshotStore} from "../src/PureVMSnapshotStore.sol";
import {PureVMTaskManager} from "../src/PureVMTaskManager.sol";
import {PureVMVerifierAdapter} from "../src/PureVMVerifierAdapter.sol";
import {ValidatorManager} from "../src/ValidatorManager.sol";

contract DeployVerComScriptTest {
    function testDeployWiresContractsAndAuthorizesResolver() public {
        DeployVerComScript deployer = new DeployVerComScript();

        (
            ValidatorManager validatorManager,
            PureVMSnapshotStore snapshotStore,
            PureVMVerifierAdapter verifierAdapter,
            PureVMTaskManager taskManager,
            PureVMChallengeResolver challengeResolver,
            OptimisticTaskCoordinator coordinator
        ) = deployer.deploy(address(0x000000000000000000000000000000000000000d), 2 ether, 2 days, 3 days);

        require(address(validatorManager) != address(0), "validator manager deployed");
        require(address(snapshotStore) != address(0), "snapshot store deployed");
        require(address(verifierAdapter) != address(0), "verifier adapter deployed");
        require(address(taskManager) != address(0), "task manager deployed");
        require(address(challengeResolver) != address(0), "challenge resolver deployed");
        require(address(coordinator) != address(0), "coordinator deployed");

        require(validatorManager.minimumStake() == 2 ether, "minimum stake configured");
        require(validatorManager.unstakeDelay() == 2 days, "exit delay configured");
        require(verifierAdapter.verifierTarget() == address(0x000000000000000000000000000000000000000d), "target");
        require(address(challengeResolver.taskManager()) == address(taskManager), "resolver manager");
        require(taskManager.authorizedChallengeResolvers(address(challengeResolver)), "resolver authorized");
        require(taskManager.approvedVerifiers(address(verifierAdapter)), "verifier approved");
        require(taskManager.verifierVersions(address(verifierAdapter)) == 1, "verifier version");
        require(address(coordinator.validatorManager()) == address(validatorManager), "coordinator validators");
        require(address(coordinator.challengeResolver()) == address(challengeResolver), "coordinator resolver");
        require(coordinator.defaultChallengeWindow() == 3 days, "challenge window configured");
    }
}
